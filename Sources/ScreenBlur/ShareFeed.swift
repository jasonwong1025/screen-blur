import AppKit
import CoreImage
import CVirtualDisplay
import ScreenCaptureKit

// MARK: - Shared copy of the screen (needs Screen Recording permission)

/// A meeting app records exactly what a display shows, so a blur cannot be in the
/// recording without being on the display. This adds a second, software-only display
/// that shows a live copy of the real one with the blur painted in. Sharing that
/// display gives viewers the blur while the real screen stays clear.
final class ShareFeed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let displayName = "ScreenBlur"
    /// The software display's ID while it exists, so the rest of the app leaves it alone.
    static var displayID: CGDirectDisplayID?

    /// Called on the main thread if the capture ends on its own.
    var onStop: (() -> Void)?

    private let sourceID: CGDirectDisplayID
    private let sourceFrame: CGRect     // Cocoa screen coordinates
    private let scale: CGFloat
    private var display: CGVirtualDisplay?
    private var stream: SCStream?
    private var window: NSWindow?
    private let frameLayer = CALayer()
    private var shown: CVPixelBuffer?   // keeps the frame on screen from being recycled
    private var applied: (rects: [CGRect], solid: Bool)?

    private let queue = DispatchQueue(label: "ScreenBlur.share", qos: .userInteractive)
    private let compositor = FrameCompositor()
    private let lock = NSLock()
    private var mask: CIImage?
    private var solid = false
    private var latest: CVPixelBuffer?  // last captured frame, repainted when the regions change
    private var pool: CVPixelBufferPool?

    init?(screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        sourceID = id
        sourceFrame = screen.frame
        scale = screen.backingScaleFactor
    }

    // MARK: Lifecycle (main thread)

    @MainActor func start() async throws {
        guard addDisplay() else { throw CocoaError(.featureUnsupported) }
        makeWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(placeWindow),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        placeWindow()

        // Every window of ours is left out of the copy, including ones opened later:
        // the outlines in edit mode are for this screen only.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let source = content.displays.first(where: { $0.displayID == sourceID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let config = SCStreamConfiguration()
        config.width = Int(sourceFrame.width * scale)
        config.height = Int(sourceFrame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 5
        let stream = SCStream(filter: SCContentFilter(display: source, excludingApplications: me, exceptingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        stream?.stopCapture { _ in }
        stream = nil
        window?.orderOut(nil)
        window = nil
        display = nil               // releasing it removes the display
        Self.displayID = nil
    }

    /// What to cover in the copy. `rects` are in Cocoa screen coordinates.
    func update(rects: [CGRect], solid: Bool, full: Bool) {
        let bounds = CGRect(origin: .zero, size: sourceFrame.size)
        let local = full ? [bounds] : rects
            .map { $0.offsetBy(dx: -sourceFrame.minX, dy: -sourceFrame.minY).intersection(bounds) }
            .filter { !$0.isNull && !$0.isEmpty }
        if let applied, applied.rects == local, applied.solid == solid { return }
        applied = (local, solid)
        let mask = FrameCompositor.mask(rects: local, size: bounds.size, scale: scale)
        lock.lock()
        self.mask = mask
        self.solid = solid
        lock.unlock()
        queue.async { self.paint() }   // the screen may be still, so don't wait for a new frame
    }

    private func addDisplay() -> Bool {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = Self.displayName
        descriptor.maxPixelsWide = UInt32(sourceFrame.width * scale)
        descriptor.maxPixelsHigh = UInt32(sourceFrame.height * scale)
        descriptor.sizeInMillimeters = CGDisplayScreenSize(sourceID)
        descriptor.vendorID = 0x5342    // arbitrary, just has to be stable
        descriptor.productID = 0x4C52
        descriptor.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = scale > 1 ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(sourceFrame.width), height: UInt(sourceFrame.height), refreshRate: 60)]
        guard display.apply(settings) else { return false }
        self.display = display
        Self.displayID = display.displayID

        // Park it corner to corner with the real display, where the pointer cannot
        // slide onto it by accident.
        var change: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&change) == .success {
            let real = CGDisplayBounds(sourceID)
            CGConfigureDisplayOrigin(change, display.displayID, Int32(real.maxX), Int32(real.minY - sourceFrame.height))
            CGCompleteDisplayConfiguration(change, .forSession)
        }
        return true
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        frameLayer.contentsGravity = .resize
        frameLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        frameLayer.frame = view.bounds
        view.layer?.addSublayer(frameLayer)
        window.contentView = view
        self.window = window
    }

    /// Fills the software display once macOS reports it as a screen.
    @objc private func placeWindow() {
        guard let window, let id = Self.displayID,
              let screen = NSScreen.screens.first(where: {
                  $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
              }) else { return }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        window.orderFrontRegardless()
    }

    // MARK: Frames (capture queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        latest = buffer
        paint()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop?() }
    }

    private func paint() {
        guard let frame = latest else { return }
        lock.lock()
        let mask = self.mask, solid = self.solid
        lock.unlock()
        var output = frame
        if let mask {
            guard let target = makeBuffer(like: frame) else { return }   // never show the frame uncovered
            let image = CIImage(cvPixelBuffer: frame)
            compositor.context.render(compositor.compose(image, mask: mask, solid: solid, scale: scale),
                                      to: target, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            output = target
        }
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frameLayer.contents = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue()
            CATransaction.commit()
            self.shown = output
        }
    }

    private func makeBuffer(like frame: CVPixelBuffer) -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(frame),
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(frame),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        return buffer
    }
}
