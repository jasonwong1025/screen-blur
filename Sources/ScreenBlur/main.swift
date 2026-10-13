import AppKit
import Carbon.HIToolbox

// MARK: - Model

struct Region: Codable {
    var id = UUID()
    var rect: CGRect          // global Cocoa screen coordinates
    var enabled = true

    init(rect: CGRect) { self.rect = rect }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        rect = try values.decode(CGRect.self, forKey: .rect)
        enabled = try values.decode(Bool.self, forKey: .enabled)
    }
}

struct Preset: Codable {
    var name: String
    var regions: [Region]
}

struct AppState: Codable {
    var regions: [Region] = []
    var presets: [String: Preset] = [:]   // keyed by slot "1"..."9"
    var solid = false                     // blackout instead of frosted blur
    var autoDetect = false
    var customTerms: [String] = []

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenBlur")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    static func load() -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

// MARK: - Global hotkeys (Carbon, so no Accessibility permission is needed)

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]

    /// Returns false when the combination is already taken by another app.
    @discardableResult
    static func register(_ keyCode: Int, _ modifiers: Int, _ action: @escaping () -> Void) -> Bool {
        if handlers.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                HotKeys.handlers[id.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                   EventHotKeyID(signature: 0x5342_4C52, id: id),
                                   GetEventDispatcherTarget(), 0, &ref) == noErr
    }
}

// MARK: - Overlay space (private SkyLight API)

/// Windows on a normal Space drop out for a moment while macOS animates a swipe
/// between Spaces or full-screen apps, which exposes what the blur was hiding.
/// Putting them in our own always-visible space keeps them fixed on the display
/// through the whole transition. Falls back to ordinary windows if the API is gone.
enum OverlaySpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let space: (connection: Int32, id: UInt64)? = {
        guard let main: MainConnection = symbol("SLSMainConnectionID"),
              let create: SpaceCreate = symbol("SLSSpaceCreate"),
              let setLevel: SpaceSetLevel = symbol("SLSSpaceSetAbsoluteLevel"),
              let show: ShowSpaces = symbol("SLSShowSpaces") else { return nil }
        let connection = main()
        let id = create(connection, 1, 0)
        guard id != 0 else { return nil }
        _ = setLevel(connection, id, 400)
        _ = show(connection, [id] as CFArray)
        return (connection, id)
    }()

    static var isAvailable: Bool { space != nil }

    static func pin(_ window: NSWindow) {
        guard let space, let add: AddWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces") else { return }
        _ = add(space.connection, space.id, [window.windowNumber] as CFArray, 7)
    }
}

// MARK: - Blur windows

final class BlurView: NSView {
    var onChange: ((CGRect) -> Void)?
    var onDelete: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private let badge = NSTextField(labelWithString: "")
    private let handle = CALayer()
    private var editing = false
    private var dragStart = NSPoint.zero
    private var frameStart = NSRect.zero
    private var resizing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        tint.wantsLayer = true
        for view in [effect, tint] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        badge.font = .boldSystemFont(ofSize: 10)
        badge.textColor = NSColor.white.withAlphaComponent(0.75)
        addSubview(badge)
        handle.backgroundColor = NSColor.systemYellow.cgColor
        layer?.addSublayer(handle)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `active` false draws only the edit outline (a region that is toggled off).
    func configure(number: Int?, solid: Bool, active: Bool, editing: Bool) {
        self.editing = editing
        effect.isHidden = solid || !active
        tint.isHidden = !active
        tint.layer?.backgroundColor = solid ? NSColor.black.cgColor
                                            : NSColor(white: 0.35, alpha: 0.45).cgColor
        badge.stringValue = number.map(String.init) ?? ""
        badge.sizeToFit()
        layer?.borderWidth = editing ? 2 : 0
        layer?.borderColor = NSColor.systemYellow.withAlphaComponent(active ? 1 : 0.5).cgColor
        handle.isHidden = !editing
        needsLayout = true
    }

    override func layout() {
        super.layout()
        badge.setFrameOrigin(NSPoint(x: 5, y: bounds.maxY - badge.frame.height - 3))
        badge.isHidden = bounds.width < 28 || bounds.height < 20
        handle.frame = CGRect(x: bounds.maxX - 12, y: 0, width: 12, height: 12)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard editing, let window else { return }
        dragStart = NSEvent.mouseLocation
        frameStart = window.frame
        let point = convert(event.locationInWindow, from: nil)
        resizing = point.x > bounds.maxX - 18 && point.y < 18
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStart.x, dy = mouse.y - dragStart.y
        var frame = frameStart
        if resizing {   // bottom-right corner: keep the top-left fixed
            frame.size.width = max(24, frameStart.width + dx)
            frame.size.height = max(24, frameStart.height - dy)
            frame.origin.y = frameStart.maxY - frame.height
        } else {
            frame.origin.x += dx
            frame.origin.y += dy
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard editing, let window else { return }
        onChange?(window.frame)
    }

    override func rightMouseDown(with event: NSEvent) {
        if editing { onDelete?() }
    }
}

/// Click-through overlay that sits above everything, so it is part of whatever
/// the meeting app captures when the whole screen is shared.
final class BlurWindow: NSPanel {
    let blur = BlurView(frame: .zero)

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = blur
        OverlaySpace.pin(self)
    }

    override var canBecomeKey: Bool { false }
}

// MARK: - Draw mode overlay

final class DrawWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class DrawView: NSView {
    var onRect: ((CGRect) -> Void)?    // screen coordinates
    var onFinish: (() -> Void)?
    private var start: NSPoint?
    private var current = NSRect.zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if !current.isEmpty {
            NSColor.clear.setFill()
            current.fill(using: .copy)
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: current)
            path.lineWidth = 2
            path.stroke()
        }
        let hint = NSAttributedString(
            string: "Drag over each area to blur  ·  Esc when done",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
        hint.draw(at: NSPoint(x: bounds.midX - hint.size().width / 2, y: bounds.maxY - 80))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                         width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if current.width > 8, current.height > 8, let window {
            onRect?(window.convertToScreen(convert(current, to: nil)))
        }
        start = nil
        current = .zero
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if [kVK_Escape, kVK_Return].contains(Int(event.keyCode)) { onFinish?() }
    }
}

// MARK: - App

struct Shortcut {
    let keyCode: Int
    let modifiers: Int
    let keys: String
    let title: String
    let action: () -> Void
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let main = controlKey | shiftKey
    private static let presetMods = controlKey | optionKey | shiftKey
    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private var state = AppState()
    private var blurOn = true
    private var editing = false
    private var panic = false

    private var statusItem: NSStatusItem!
    private var regionWindows: [BlurWindow] = []
    private var autoWindows: [BlurWindow] = []
    private var panicWindows: [BlurWindow] = []
    private var drawWindows: [DrawWindow] = []
    private var previousApp: NSRunningApplication?
    private var detector: AutoDetector?
    private var autoRects: [CGRect] = []
    private var lastScan: [CGRect] = []
    private var shortcutsWindow: NSWindow?
    private var toastWindow: NSPanel?
    private var toastHide: DispatchWorkItem?
    private var unavailableKeys: [String] = []

    // Regions picked by clicking an item follow that item while it still exists.
    private struct Tracked {
        var element: AXUIElement?       // nil once the item itself has been replaced
        let window: AXUIElement?
        let windowID: CGWindowID?
        let webArea: AXUIElement?       // the browser tab's page, when the item is on one
        let pid: pid_t
        var otherTab = false
    }
    private var tracked: [UUID: Tracked] = [:]
    private var followTicks = 0
    private var offscreen: Set<UUID> = []
    private var trackTimer: Timer?
    private var clickTap: ClickTap?
    private var pickTimer: Timer?
    private var hovered: (element: AXUIElement, rect: CGRect)?
    private lazy var highlight: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2)
        panel.hasShadow = false
        panel.level = .screenSaver + 1
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.borderColor = NSColor.systemYellow.cgColor
        panel.contentView?.layer?.borderWidth = 2
        OverlaySpace.pin(panel)
        return panel
    }()

    // Single source of truth for the global hotkeys and the cheat sheet.
    private lazy var shortcuts: [Shortcut] = [
        Shortcut(keyCode: kVK_ANSI_B, modifiers: Self.main, keys: "⌃⇧B", title: "Blur on / off (all regions)") { [weak self] in self?.toggleBlur() },
        Shortcut(keyCode: kVK_ANSI_F, modifiers: Self.main, keys: "⌃⇧F", title: "Panic: blur the full screen") { [weak self] in self?.togglePanic() },
        Shortcut(keyCode: kVK_ANSI_N, modifiers: Self.main, keys: "⌃⇧N", title: "New region (drag to draw)") { [weak self] in self?.toggleDraw() },
        Shortcut(keyCode: kVK_ANSI_C, modifiers: Self.main, keys: "⌃⇧C", title: "Click an item to blur it") { [weak self] in self?.togglePick() },
        Shortcut(keyCode: kVK_ANSI_E, modifiers: Self.main, keys: "⌃⇧E", title: "Edit regions (move, resize, delete)") { [weak self] in self?.toggleEdit() },
        Shortcut(keyCode: kVK_ANSI_A, modifiers: Self.main, keys: "⌃⇧A", title: "Auto-detect sensitive text on / off") { [weak self] in self?.toggleAuto() },
        Shortcut(keyCode: kVK_ANSI_S, modifiers: Self.main, keys: "⌃⇧S", title: "Save regions as a preset") { [weak self] in self?.savePreset() },
        Shortcut(keyCode: kVK_Delete, modifiers: Self.main, keys: "⌃⇧⌫", title: "Remove all regions") { [weak self] in self?.removeAll() },
        Shortcut(keyCode: kVK_ANSI_Slash, modifiers: Self.main, keys: "⌃⇧/", title: "Show this list") { [weak self] in self?.showShortcuts() },
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstLaunch = AppState.load() == nil
        state = AppState.load() ?? AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()
        registerHotKeys()

        if state.autoDetect { startDetector() }
        refresh()
        if firstLaunch { showShortcuts() }
    }

    private func registerHotKeys() {
        for shortcut in shortcuts where !HotKeys.register(shortcut.keyCode, shortcut.modifiers, shortcut.action) {
            unavailableKeys.append(shortcut.keys)
        }
        for (index, key) in Self.digitKeys.enumerated() {
            if !HotKeys.register(key, Self.main, { [weak self] in self?.toggleRegion(index) }) {
                unavailableKeys.append("⌃⇧\(index + 1)")
            }
            if !HotKeys.register(key, Self.presetMods, { [weak self] in self?.loadPreset(index + 1) }) {
                unavailableKeys.append("⌃⌥⇧\(index + 1)")
            }
        }
    }

    // Text fields in our dialogs need an Edit menu for ⌘C / ⌘V to work.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(item)
        NSApp.mainMenu = mainMenu
    }

    // MARK: Window sync

    private func refresh() {
        while regionWindows.count < state.regions.count { regionWindows.append(BlurWindow(frame: .zero)) }
        while regionWindows.count > state.regions.count { regionWindows.removeLast().orderOut(nil) }
        for (index, region) in state.regions.enumerated() {
            let window = regionWindows[index]
            if window.frame != region.rect { window.setFrame(region.rect, display: true) }
            window.ignoresMouseEvents = !editing
            window.blur.configure(number: index + 1, solid: state.solid,
                                  active: blurOn && region.enabled, editing: editing)
            window.blur.onChange = { [weak self] frame in
                guard let self, self.state.regions.indices.contains(index) else { return }
                self.state.regions[index].rect = frame
                self.tracked[self.state.regions[index].id] = nil   // moved by hand: stop following
                self.state.save()
            }
            window.blur.onDelete = { [weak self] in self?.removeRegion(index) }
            let visible = blurOn && region.enabled && !offscreen.contains(region.id)
            if visible || editing { window.orderFrontRegardless() } else { window.orderOut(nil) }
        }

        let rects = blurOn && state.autoDetect ? autoRects : []
        while autoWindows.count < rects.count { autoWindows.append(BlurWindow(frame: .zero)) }
        for (index, window) in autoWindows.enumerated() {
            guard index < rects.count else { window.orderOut(nil); continue }
            window.setFrame(rects[index], display: true)
            window.blur.configure(number: nil, solid: state.solid, active: true, editing: false)
            window.orderFrontRegardless()
        }

        for window in panicWindows {
            window.blur.configure(number: nil, solid: state.solid, active: true, editing: false)
        }

        let symbol = panic ? "eye.slash.circle.fill" : (blurOn ? "eye.slash.fill" : "eye")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenBlur")
    }

    // MARK: Actions

    @objc private func toggleBlur() {
        blurOn.toggle()
        refresh()
        toast(blurOn ? "Blur ON" : "Blur OFF")
    }

    @objc private func togglePanic() {
        panic.toggle()
        panicWindows.forEach { $0.orderOut(nil) }
        panicWindows = panic ? NSScreen.screens.map { BlurWindow(frame: $0.frame) } : []
        refresh()
        panicWindows.forEach { $0.orderFrontRegardless() }
    }

    private func toggleRegion(_ index: Int) {
        guard state.regions.indices.contains(index) else { return }
        state.regions[index].enabled.toggle()
        state.save()
        refresh()
        toast("Region \(index + 1) " + (state.regions[index].enabled ? "blurred" : "revealed"))
    }

    @objc private func toggleRegionItem(_ sender: NSMenuItem) {
        toggleRegion(sender.tag)
    }

    private func removeRegion(_ index: Int) {
        guard state.regions.indices.contains(index) else { return }
        state.regions.remove(at: index)
        state.save()
        refresh()
    }

    @objc private func removeAll() {
        state.regions = []
        tracked = [:]
        offscreen = []
        state.save()
        refresh()
        toast("All regions removed")
    }

    @objc private func toggleEdit() {
        editing.toggle()
        refresh()
        toast(editing ? "Edit: drag to move · yellow corner to resize · right-click to delete · ⌃⇧E when done"
                      : "Edit finished", seconds: editing ? 4 : 1.2)
    }

    @objc private func toggleDraw() {
        guard drawWindows.isEmpty else { endDraw(); return }
        endPick()
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let window = DrawWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver + 1
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = DrawView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onRect = { [weak self] rect in self?.addRegion(rect) }
            view.onFinish = { [weak self] in self?.endDraw() }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            drawWindows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (drawWindows.first { $0.frame.contains(mouse) } ?? drawWindows.first)?.makeKey()
    }

    private func endDraw() {
        drawWindows.forEach { $0.orderOut(nil) }
        drawWindows = []
        previousApp?.activate()
        previousApp = nil
    }

    private func addRegion(_ rect: CGRect) {
        state.regions.append(Region(rect: rect))
        state.save()
        blurOn = true
        refresh()
    }

    // MARK: Pick mode (click an item to blur it)

    @objc private func togglePick() {
        guard clickTap == nil else { endPick(); return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            let alert = NSAlert()
            alert.messageText = "Click-to-blur needs Accessibility permission"
            alert.informativeText = "ScreenBlur asks macOS which button, text or icon is under the pointer so it can cover exactly that item.\n\nAllow ScreenBlur under System Settings → Privacy & Security → Accessibility, then press ⌃⇧C again."
            present(alert)
            return
        }
        if !drawWindows.isEmpty { endDraw() }
        let tap = ClickTap()
        tap.onClick = { [weak self] in self?.pickHovered() }
        tap.onEscape = { [weak self] in self?.endPick() }
        guard tap.start() else { toast("Could not capture clicks"); return }
        clickTap = tap
        pickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateHover() }
        RunLoop.main.add(pickTimer!, forMode: .common)
        toast("Click any item to blur it  ·  Esc when done", seconds: 4)
    }

    private func endPick() {
        guard clickTap != nil else { return }
        clickTap?.stop()
        clickTap = nil
        pickTimer?.invalidate()
        pickTimer = nil
        hovered = nil
        highlight.orderOut(nil)
    }

    private func updateHover() {
        guard let element = AX.element(at: NSEvent.mouseLocation),
              let rect = AX.frame(of: element).rect, rect.width > 1, rect.height > 1 else {
            hovered = nil
            highlight.orderOut(nil)
            return
        }
        hovered = (element, rect)
        highlight.setFrame(rect.insetBy(dx: -3, dy: -3), display: true)
        highlight.orderFrontRegardless()
    }

    private func pickHovered() {
        updateHover()
        guard let hovered else { return }
        let region = Region(rect: hovered.rect.insetBy(dx: -6, dy: -4))
        let window = AX.window(of: hovered.element)
        tracked[region.id] = Tracked(element: hovered.element, window: window, windowID: window.flatMap(AX.windowID),
                                     webArea: AX.webArea(of: hovered.element), pid: AX.pid(of: hovered.element))
        state.regions.append(region)
        state.save()
        blurOn = true
        refresh()
        if trackTimer == nil {
            trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.followTracked() }
            RunLoop.main.add(trackTimer!, forMode: .common)
        }
    }

    /// Whether a window is on the current Space and not hiding `rect` (Cocoa
    /// coordinates) behind another window. `stack` is the on-screen list, front first.
    private func isShowing(_ windowID: CGWindowID, _ rect: CGRect, in stack: [[CFString: Any]]) -> Bool {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        for window in stack {
            if window[kCGWindowNumber] as? CGWindowID == windowID { return true }
            guard window[kCGWindowOwnerPID] as? pid_t != getpid(), window[kCGWindowLayer] as? Int == 0,
                  window[kCGWindowAlpha] as? Double ?? 1 > 0.01,
                  let bounds = window[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            if frame.contains(flipped) { return false }   // covered by a window in front
        }
        return false   // minimised, hidden, or on another Space
    }

    /// Moves picked regions with their items (scrolling, window moves), clipped to the
    /// item's window so a scrolled-away item doesn't leave a box floating elsewhere.
    /// A region shows only while its window is on screen, uncovered, and on the same tab.
    private func followTracked() {
        guard blurOn, !editing else { return }
        let stack = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[CFString: Any]] ?? []
        for (index, region) in state.regions.enumerated() where region.enabled {
            guard var target = tracked[region.id] else { continue }
            var rect = region.rect
            if let element = target.element {
                let found = AX.frame(of: element)
                if let frame = found.rect {
                    rect = frame.insetBy(dx: -6, dy: -4)
                    if let window = target.window, let bounds = AX.frame(of: window).rect {
                        rect = rect.intersection(bounds)
                    }
                } else if found.gone {
                    target.element = nil   // stays blurred at its last position
                }
            }
            var hidden = rect.isNull || rect.width < 2 || rect.height < 2
            if !hidden, let windowID = target.windowID { hidden = !isShowing(windowID, rect, in: stack) }
            // Asking the app what is at the spot costs more, so it runs less often,
            // except while hidden so the blur is back the moment its tab is.
            if !hidden, let area = target.webArea, followTicks % 6 == 0 || offscreen.contains(region.id) {
                let shown = AX.webArea(at: NSPoint(x: rect.midX, y: rect.midY), pid: target.pid)
                target.otherTab = shown.map { !CFEqual($0, area) } ?? false
            }
            hidden = hidden || target.otherTab
            // With neither the item nor its window left to watch, it is a plain fixed box.
            tracked[region.id] = target.element == nil && target.windowID == nil ? nil : target
            if hidden != offscreen.contains(region.id) {
                if hidden { offscreen.insert(region.id) } else { offscreen.remove(region.id) }
                if hidden { regionWindows[index].orderOut(nil) } else { regionWindows[index].orderFrontRegardless() }
            }
            if !hidden, rect != region.rect {
                state.regions[index].rect = rect
                regionWindows[index].setFrame(rect, display: true)
            }
        }
        followTicks += 1
        if tracked.isEmpty {
            trackTimer?.invalidate()
            trackTimer = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.save()
    }

    @objc private func toggleStyle() {
        state.solid.toggle()
        state.save()
        refresh()
    }

    // MARK: Auto-detect

    @objc private func toggleAuto() {
        if !state.autoDetect && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Auto-detect needs Screen Recording permission"
            alert.informativeText = "ScreenBlur reads the screen on this Mac to find emails, keys and other sensitive text. Nothing leaves the machine.\n\nAllow ScreenBlur under System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch it and turn auto-detect on again."
            present(alert)
            return
        }
        state.autoDetect.toggle()
        state.save()
        if state.autoDetect { startDetector() } else { stopDetector() }
        refresh()
        toast(state.autoDetect ? "Auto-detect ON" : "Auto-detect OFF")
    }

    private func startDetector() {
        stopDetector()
        detector = AutoDetector(customTerms: state.customTerms) { [weak self] rects in
            guard let self, self.state.autoDetect else { return }
            // Keep the previous scan's boxes too, so one missed OCR pass doesn't flash the text.
            self.autoRects = rects + self.lastScan
            self.lastScan = rects
            self.refresh()
        }
        detector?.start()
    }

    private func stopDetector() {
        detector?.stop()
        detector = nil
        autoRects = []
        lastScan = []
    }

    @objc private func editCustomTerms() {
        let alert = NSAlert()
        alert.messageText = "Custom terms to auto-blur"
        alert.informativeText = "Comma-separated words or phrases (client name, account number…). Used when auto-detect is on."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = state.customTerms.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard present(alert) == .alertFirstButtonReturn else { return }
        state.customTerms = field.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        state.save()
        if state.autoDetect { startDetector() }
    }

    // MARK: Presets

    @objc private func savePreset() {
        guard !state.regions.isEmpty else { toast("No regions to save"); return }
        let alert = NSAlert()
        alert.messageText = "Save regions as a preset"
        alert.informativeText = "Load it later with ⌃⌥⇧ + the slot number."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 280, height: 26))
        for slot in 1...9 {
            popup.addItem(withTitle: "Slot \(slot)" + (state.presets["\(slot)"].map { " — replaces “\($0.name)”" } ?? ""))
        }
        popup.selectItem(at: (1...9).first { state.presets["\($0)"] == nil }.map { $0 - 1 } ?? 0)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Name, e.g. the client or system"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        box.addSubview(popup)
        box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard present(alert) == .alertFirstButtonReturn else { return }
        let slot = popup.indexOfSelectedItem + 1
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        state.presets["\(slot)"] = Preset(name: name.isEmpty ? "Preset \(slot)" : name, regions: state.regions)
        state.save()
        toast("Saved preset \(slot)")
    }

    private func loadPreset(_ slot: Int) {
        guard let preset = state.presets["\(slot)"] else { toast("Preset \(slot) is empty"); return }
        state.regions = preset.regions
        state.save()
        blurOn = true
        refresh()
        toast("Preset \(slot): \(preset.name)")
    }

    @objc private func loadPresetItem(_ sender: NSMenuItem) {
        loadPreset(sender.tag)
    }

    @objc private func deletePresetItem(_ sender: NSMenuItem) {
        state.presets["\(sender.tag)"] = nil
        state.save()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func add(_ title: String, _ action: Selector, key: String = "", on: Bool = false,
                 mods: NSEvent.ModifierFlags = [.control, .shift], tag: Int = 0, to target: NSMenu = menu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.state = on ? .on : .off
            item.tag = tag
            target.addItem(item)
        }

        add("Blur On", #selector(toggleBlur), key: "b", on: blurOn)
        add("Panic: Blur Full Screen", #selector(togglePanic), key: "f", on: panic)
        add("Auto-detect Sensitive Text", #selector(toggleAuto), key: "a", on: state.autoDetect)
        menu.addItem(.separator())
        add("New Region", #selector(toggleDraw), key: "n")
        add("Click an Item to Blur It", #selector(togglePick), key: "c", on: clickTap != nil)
        add("Edit Regions", #selector(toggleEdit), key: "e", on: editing)
        for (index, region) in state.regions.enumerated() {
            add("Region \(index + 1)", #selector(toggleRegionItem), key: index < 9 ? "\(index + 1)" : "",
                on: region.enabled, tag: index)
        }
        add("Remove All Regions", #selector(removeAll), key: "\u{8}")
        menu.addItem(.separator())

        let presets = NSMenu()
        for slot in 1...9 {
            guard let preset = state.presets["\(slot)"] else { continue }
            add("\(slot). \(preset.name)", #selector(loadPresetItem), key: "\(slot)",
                mods: [.control, .option, .shift], tag: slot, to: presets)
        }
        if !state.presets.isEmpty { presets.addItem(.separator()) }
        add("Save Current Regions…", #selector(savePreset), key: "s", to: presets)
        let delete = NSMenu()
        for slot in 1...9 {
            guard let preset = state.presets["\(slot)"] else { continue }
            add("\(slot). \(preset.name)", #selector(deletePresetItem), tag: slot, to: delete)
        }
        if !state.presets.isEmpty {
            let item = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            item.submenu = delete
            presets.addItem(item)
        }
        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsItem.submenu = presets
        menu.addItem(presetsItem)

        add("Blackout Instead of Blur", #selector(toggleStyle), on: state.solid)
        add("Custom Terms to Auto-blur…", #selector(editCustomTerms))
        menu.addItem(.separator())
        add("Keyboard Shortcuts", #selector(showShortcuts), key: "/")
        let quit = NSMenuItem(title: "Quit ScreenBlur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Dialogs, cheat sheet, toast

    /// Our overlays sit at screen-saver level, so dialogs have to go above them.
    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .screenSaver + 2
        return alert.runModal()
    }

    @objc private func showShortcuts() {
        if shortcutsWindow == nil {
            var rows = shortcuts.map { ($0.keys, $0.title) }
            rows.insert(("⌃⇧1–9", "Blur / reveal one region"), at: 2)
            rows.insert(("⌃⌥⇧1–9", "Load preset 1–9"), at: rows.count - 2)

            let text = NSMutableAttributedString()
            for (keys, title) in rows {
                text.append(NSAttributedString(string: keys.padding(toLength: 10, withPad: " ", startingAt: 0),
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor]))
                text.append(NSAttributedString(string: title + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            }
            var note = "\nShare your entire screen in the meeting app. Sharing a single window or browser tab leaves the blur out."
            if !unavailableKeys.isEmpty {
                note += "\n\nAlready taken by another app, use the menu instead: " + unavailableKeys.joined(separator: " ")
            }
            text.append(NSAttributedString(string: note,
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))

            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = text
            label.preferredMaxLayoutWidth = 380
            label.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: label.sizeThatFits(NSSize(width: 380, height: 2000)))

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: label.frame.height + 40),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ScreenBlur Shortcuts"
            window.isReleasedWhenClosed = false
            window.level = .screenSaver + 2
            window.contentView?.addSubview(label)
            window.center()
            shortcutsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Brief on-screen confirmation, since everything is driven from the keyboard.
    private func toast(_ message: String, seconds: Double = 1.2) {
        let label = NSTextField(labelWithString: message)
        label.font = .boldSystemFont(ofSize: 14)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 36, height: label.frame.height + 20)
        label.setFrameOrigin(NSPoint(x: 18, y: 10))

        let panel = toastWindow ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver + 3
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            toastWindow = panel
            return panel
        }()
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        content.layer?.cornerRadius = 10
        content.addSubview(label)
        panel.contentView = content

        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.frame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - 120,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        toastHide?.cancel()
        let hide = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        toastHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
