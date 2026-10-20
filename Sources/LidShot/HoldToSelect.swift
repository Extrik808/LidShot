import AppKit
import ScreenCaptureKit
import VisionKit

enum HoldModifiers: Int, CaseIterable {
    case off = 0
    case optionCommand = 1
    case controlOption = 2
    case controlCommand = 3

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .off: []
        case .optionCommand: [.option, .command]
        case .controlOption: [.control, .option]
        case .controlCommand: [.control, .command]
        }
    }

    var title: String {
        switch self {
        case .off: "Выключено"
        case .optionCommand: "⌥⌘"
        case .controlOption: "⌃⌥"
        case .controlCommand: "⌃⌘"
        }
    }

    static var current: HoldModifiers {
        get {
            guard UserDefaults.standard.object(forKey: "holdModifiers") != nil else { return .optionCommand }
            return HoldModifiers(rawValue: UserDefaults.standard.integer(forKey: "holdModifiers")) ?? .optionCommand
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "holdModifiers") }
    }
}

final class HoldTextSelector {
    private static let holdDelay: TimeInterval = 0.35
    private static let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private var timer: Timer?
    private var heldSince: Date?
    private var firedThisHold = false
    private var isCapturing = false
    private var panel: FrozenScreenPanel?
    private var warnedAboutPermission = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let target = HoldModifiers.current.flags
        let pressed = NSEvent.modifierFlags.intersection(Self.watched)
        let isHeld = !target.isEmpty && pressed == target

        if isHeld {
            if heldSince == nil {
                heldSince = Date()
            }
            if !firedThisHold, panel == nil, !isCapturing,
               NSEvent.pressedMouseButtons == 0,
               let since = heldSince, Date().timeIntervalSince(since) >= Self.holdDelay {
                firedThisHold = true
                activate()
            }
            return
        }

        heldSince = nil
        firedThisHold = false
        if panel != nil, NSEvent.pressedMouseButtons == 0 {
            finish(copy: true)
        }
    }

    private func activate() {
        guard CGPreflightScreenCaptureAccess() else {
            if !warnedAboutPermission {
                warnedAboutPermission = true
                Toast.show("Нужен доступ к записи экрана", detail: "Системные настройки → Конфиденциальность и безопасность → Запись экрана")
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        isCapturing = true
        ScreenGrabber.capture(screen) { [weak self] image in
            guard let self else { return }
            isCapturing = false
            guard let image else {
                NSSound.beep()
                return
            }
            guard heldSince != nil else { return }
            show(image, on: screen)
        }
    }

    private func show(_ image: CGImage, on screen: NSScreen) {
        let panel = FrozenScreenPanel(image: image, screen: screen)
        panel.onCancel = { [weak self] in self?.finish(copy: false) }
        self.panel = panel
        panel.present()
    }

    private func finish(copy: Bool) {
        guard let panel else { return }
        self.panel = nil
        if copy, let text = panel.takeSelectedText(), !text.isEmpty {
            Clipboard.copy(text)
            Toast.show("Текст скопирован", detail: text)
        }
        panel.orderOut(nil)
    }
}

final class FrozenScreenPanel: NSPanel, ImageAnalysisOverlayViewDelegate {
    var onCancel: (() -> Void)?

    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let hint = NSTextField(labelWithString: "Распознаю текст…")
    private var task: Task<Void, Never>?

    init(image: CGImage, screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        let nsImage = NSImage(cgImage: image, size: screen.frame.size)
        imageView.image = nsImage
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = CGRect(origin: .zero, size: screen.frame.size)
        imageView.autoresizingMask = [.width, .height]

        overlay.frame = imageView.frame
        overlay.autoresizingMask = [.width, .height]
        overlay.delegate = self
        overlay.preferredInteractionTypes = .textSelection
        overlay.trackingImageView = imageView

        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.drawsBackground = true
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        hint.alignment = .center
        hint.sizeToFit()
        hint.frame = CGRect(
            x: (screen.frame.width - hint.frame.width - 24) / 2,
            y: screen.frame.height - hint.frame.height - 60,
            width: hint.frame.width + 24,
            height: hint.frame.height + 8
        )
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 8
        hint.layer?.masksToBounds = true

        let root = NSView(frame: imageView.frame)
        root.addSubview(imageView)
        root.addSubview(overlay)
        root.addSubview(hint)
        contentView = root

        task = Task { @MainActor [weak self] in
            do {
                let analysis = try await ImageAnalyzer().analyze(
                    image,
                    orientation: .up,
                    configuration: ImageAnalyzer.Configuration([.text])
                )
                guard let self, !Task.isCancelled else { return }
                overlay.analysis = analysis
                setHint(analysis.hasResults(for: .text)
                    ? "Выделите текст мышью и отпустите клавиши — он скопируется"
                    : "Текст не найден")
            } catch {
                self?.setHint("Не удалось распознать текст")
            }
        }
    }

    override var canBecomeKey: Bool { true }

    func present() {
        alphaValue = 1
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(overlay)
    }

    func takeSelectedText() -> String? {
        task?.cancel()
        guard overlay.hasActiveTextSelection else { return nil }
        if #available(macOS 14.0, *) {
            return overlay.selectedText
        }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        return pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            task?.cancel()
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func setHint(_ text: String) {
        let center = hint.frame.midX
        hint.stringValue = text
        hint.sizeToFit()
        let width = hint.frame.width + 24
        hint.frame = CGRect(x: center - width / 2, y: hint.frame.minY, width: width, height: hint.frame.height + 8)
    }
}

enum ScreenGrabber {
    static func capture(_ screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        if #available(macOS 14.0, *) {
            Task { @MainActor in
                completion(try? await captureWithScreenCaptureKit(screen))
            }
        } else {
            captureWithTool(screen, completion: completion)
        }
    }

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit(_ screen: NSScreen) async throws -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func captureWithTool(_ screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        let index = (NSScreen.screens.firstIndex(of: screen) ?? 0) + 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lidshot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-D", "\(index)", url.path]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: url) }
                let image = (try? Data(contentsOf: url))
                    .flatMap { NSImage(data: $0) }?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
                completion(image)
            }
        }
        do {
            try process.run()
        } catch {
            completion(nil)
        }
    }
}
