import AppKit
import ApplicationServices

final class InputButtonController {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let skippedApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.jetbrains.pycharm", "com.todesktop.230313mzl4w4u92",
        "dev.warp.Warp-Stable", "com.apple.keychainaccess", "com.1password.1password"
    ]

    private let translator: InPlaceTranslator
    private var timer: Timer?
    private var panel: InputButtonPanel?
    private var electronPids: Set<pid_t> = []

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "inputButton") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "inputButton") }
    }

    static var hiddenApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "inputButtonHiddenApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "inputButtonHiddenApps") }
    }

    init(translator: InPlaceTranslator) {
        self.translator = translator
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard Self.isEnabled, AXIsProcessTrusted(), !translator.isBusy else {
            if !translator.isBusy { hide() }
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if panel?.isMouseInside != true { hide() }
            return
        }
        let bundleID = app.bundleIdentifier ?? ""
        guard !Self.skippedApps.contains(bundleID), !Self.hiddenApps.contains(bundleID) else {
            hide()
            return
        }
        enableElectronAccessibility(app)
        guard let anchor = Self.anchor(in: app.processIdentifier) else {
            hide()
            return
        }
        show(at: anchor, bundleID: bundleID)
    }

    private func enableElectronAccessibility(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !electronPids.contains(pid) else { return }
        electronPids.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func show(at anchor: CGPoint, bundleID: String) {
        let panel = panel ?? makePanel()
        panel.bundleID = bundleID
        let size = panel.frame.size
        var origin = CGPoint(x: anchor.x - size.width, y: anchor.y)
        if let screen = NSScreen.screens.first(where: { NSPointInRect(anchor, $0.frame) }) {
            origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - size.width)
            origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - size.height)
        }
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> InputButtonPanel {
        let panel = InputButtonPanel()
        panel.onClick = { [weak self] in
            guard let self else { return }
            panel.setWorking(true)
            translator.run(waitForModifiers: false) { [weak panel] in panel?.setWorking(false) }
        }
        panel.onHideForApp = { [weak self] bundleID in
            Self.hiddenApps.insert(bundleID)
            self?.hide()
            Toast.show("Кнопка скрыта для этого приложения", detail: "Вернуть: меню LidShot → «Кнопка перевода в полях ввода»")
        }
        self.panel = panel
        return panel
    }

    private static func anchor(in pid: pid_t) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        guard let element: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        let subrole: String = attribute(element, kAXSubroleAttribute) ?? ""
        guard subrole != "AXSecureTextField" else { return nil }
        var editable = textRoles.contains(role)
        if !editable {
            var settable: DarwinBoolean = false
            editable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                && settable.boolValue
                && role != "AXSlider" && role != "AXCheckBox" && role != "AXRadioButton"
        }
        guard editable else { return nil }
        let value: String = attribute(element, kAXValueAttribute) ?? ""
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return nil }
        guard let frame = frame(of: element), frame.width > 30, frame.height > 10 else { return nil }

        let cocoa = toCocoa(frame)
        if frame.height <= 300 {
            return CGPoint(x: cocoa.maxX - 4, y: cocoa.minY + 4)
        }
        if let caret = caretFrame(of: element) {
            let point = toCocoa(caret)
            return CGPoint(x: min(point.maxX + 34, cocoa.maxX - 4), y: point.minY - 30)
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func caretFrame(of element: AXUIElement) -> CGRect? {
        guard let range: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var bounds: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds
        ) == .success, let value = bounds else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(value as! AXValue, .cgRect, &rect)
        return rect.width >= 0 && rect.height > 0 ? rect : nil
    }

    private static func toCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self {
            return value as! T?
        }
        return value as? T
    }
}

final class InputButtonPanel: NSPanel {
    var onClick: (() -> Void)?
    var onHideForApp: ((String) -> Void)?
    var bundleID = ""

    private let button = HoverButton()
    private let spinner = NSProgressIndicator()

    var isMouseInside: Bool { NSMouseInRect(NSEvent.mouseLocation, frame, false) }

    init() {
        let size = CGSize(width: 28, height: 28)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.width / 2
        background.layer?.masksToBounds = true

        button.frame = background.bounds
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Перевести")
        button.contentTintColor = .controlAccentColor
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Перевести текст в поле (правый клик — скрыть для приложения)"
        button.target = self
        button.action = #selector(clicked)
        button.onRightClick = { [weak self] in self?.showMenu() }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = background.bounds.insetBy(dx: 6, dy: 6)
        spinner.isHidden = true

        background.addSubview(button)
        background.addSubview(spinner)
        contentView = background
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func setWorking(_ working: Bool) {
        button.isHidden = working
        spinner.isHidden = !working
        if working {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc private func clicked() {
        onClick?()
    }

    private func showMenu() {
        let menu = NSMenu()
        let translate = NSMenuItem(title: "Перевести", action: #selector(clicked), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)
        let hideItem = NSMenuItem(title: "Не показывать в этом приложении", action: #selector(hideForApp), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func hideForApp() {
        onHideForApp?(bundleID)
    }
}

final class HoverButton: NSButton {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
