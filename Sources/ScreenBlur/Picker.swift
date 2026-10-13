import AppKit
import ApplicationServices

// MARK: - Accessibility lookups (needs Accessibility permission)

/// Finds on-screen UI elements through the Accessibility API, which covers native
/// apps, desktop icons, menu bars and web page content alike.
enum AX {
    private static let systemWide = AXUIElementCreateSystemWide()
    private static var prepared: Set<pid_t> = []

    /// Height used to flip between AX (top-left origin) and Cocoa (bottom-left) coordinates.
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// The deepest element under a Cocoa screen point, ignoring our own overlays.
    static func element(at point: NSPoint) -> AXUIElement? {
        let x = Float(point.x), y = Float(primaryHeight - point.y)
        var found: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, x, y, &found) == .success,
           let found, pid(of: found) != getpid() {
            prepare(pid(of: found))
            return found
        }
        // One of our overlays was hit: ask the first normal window underneath instead.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[CFString: Any]] ?? []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID] as? pid_t, owner != getpid(),
                  window[kCGWindowLayer] as? Int == 0,
                  let bounds = window[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) else { continue }
            prepare(owner)
            var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(owner), x, y, &hit)
            return hit
        }
        return nil
    }

    /// Chromium and Electron apps only build their accessibility tree for page
    /// content once a client asks for it.
    private static func prepare(_ pid: pid_t) {
        guard prepared.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(app, 0.15)
    }

    /// Frame in Cocoa screen coordinates. `gone` is true once the element no longer exists.
    static func frame(of element: AXUIElement) -> (rect: CGRect?, gone: Bool) {
        var position: CFTypeRef?, size: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        guard error == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return (nil, error == .invalidUIElement)
        }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return (CGRect(x: origin.x, y: primaryHeight - origin.y - extent.height,
                       width: extent.width, height: extent.height), false)
    }

    static func window(of element: AXUIElement) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }
}

// MARK: - Click capture

/// Swallows left clicks and Esc system-wide while pick mode is on, so clicking an
/// item selects it for blurring instead of activating it.
final class ClickTap {
    var onClick: (() -> Void)?
    var onEscape: (() -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask, callback: { _, type, event, refcon in
            let tap = Unmanaged<ClickTap>.fromOpaque(refcon!).takeUnretainedValue()
            return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let port else { return false }
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .leftMouseDown:
            onClick?()
            return true
        case .leftMouseUp:
            return true
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 53:   // Esc
            onEscape?()
            return true
        default:
            return false
        }
    }
}
