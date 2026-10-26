import AppKit
import ApplicationServices

final class InputButtonController {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let skippedApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.jetbrains.pycharm", "com.todesktop.230313mzl4w4u92",
        "dev.warp.Warp-Stable", "com.apple.keychainaccess", "com.1password.1password"
    ]

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium"
    ]

    private let translator: InPlaceTranslator
    private var timer: Timer?
    private var panel: InputButtonPanel?
    private static var preparedPids: Set<pid_t> = []

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
        Self.enableAccessibility(app)
        guard let anchor = Self.anchor(in: app.processIdentifier) else {
            hide()
            return
        }
        show(at: anchor, bundleID: bundleID)
    }

    static func enableAccessibility(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !preparedPids.contains(pid) else { return }
        preparedPids.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if Self.chromiumBrowsers.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
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
        let panel = InputButtonPanel(toolTip: "Перевести текст в поле (правый клик — скрыть для приложения)")
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
        guard subrole != "AXSecureTextField", isEditable(element, role: role) else { return nil }
        let value: String = attribute(element, kAXValueAttribute) ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !looksLikeAddress(trimmed) else { return nil }
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

    static func isEditable(_ element: AXUIElement, role: String) -> Bool {
        if textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
            && role != "AXSlider" && role != "AXCheckBox" && role != "AXRadioButton"
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        if text.contains("://") || text.hasPrefix("www.") { return true }
        let parts = text.split(separator: "/").first?.split(separator: ".") ?? []
        return parts.count >= 2 && (parts.last?.count ?? 0) >= 2 && parts.last!.allSatisfy(\.isLetter)
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

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
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
    var onReplace: (() -> Void)?
    var onHideForApp: ((String) -> Void)?
    var bundleID = ""

    private static let side: CGFloat = 28
    private let background = NSVisualEffectView()
    private let button = HoverButton()
    private let replaceButton = HoverButton()
    private let spinner = NSProgressIndicator()
    private var showsReplace = false

    var isMouseInside: Bool { NSMouseInRect(NSEvent.mouseLocation, frame, false) }

    init(toolTip: String, replaceToolTip: String? = nil) {
        let size = CGSize(width: Self.side, height: Self.side)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        background.frame = CGRect(origin: .zero, size: size)
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.side / 2
        background.layer?.masksToBounds = true

        configure(button, symbol: "character.bubble", description: "Перевести", toolTip: toolTip, action: #selector(clicked))
        button.frame = CGRect(origin: .zero, size: size)
        background.addSubview(button)

        if let replaceToolTip {
            configure(replaceButton, symbol: "character.cursor.ibeam", description: "Перевести и заменить", toolTip: replaceToolTip, action: #selector(replaceClicked))
            replaceButton.frame = CGRect(x: Self.side, y: 0, width: Self.side, height: Self.side)
            replaceButton.isHidden = true
            background.addSubview(replaceButton)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = background.bounds.insetBy(dx: 6, dy: 6)
        spinner.isHidden = true

        background.addSubview(spinner)
        contentView = background
    }

    private func configure(_ target: HoverButton, symbol: String, description: String, toolTip: String, action: Selector) {
        target.isBordered = false
        target.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        target.contentTintColor = .controlAccentColor
        target.imageScaling = .scaleProportionallyDown
        target.toolTip = toolTip
        target.target = self
        target.action = action
        target.onRightClick = { [weak self] in self?.showMenu() }
    }

    func setReplaceVisible(_ visible: Bool) {
        showsReplace = visible && onReplace != nil
        replaceButton.isHidden = !showsReplace
        let width = showsReplace ? Self.side * 2 : Self.side
        setContentSize(CGSize(width: width, height: Self.side))
        background.frame = CGRect(x: 0, y: 0, width: width, height: Self.side)
        spinner.frame = CGRect(x: (width - Self.side) / 2, y: 0, width: Self.side, height: Self.side).insetBy(dx: 6, dy: 6)
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func setWorking(_ working: Bool) {
        button.isHidden = working
        replaceButton.isHidden = working || !showsReplace
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

    @objc private func replaceClicked() {
        onReplace?()
    }

    private func showMenu() {
        let menu = NSMenu()
        let translate = NSMenuItem(title: "Перевести", action: #selector(clicked), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)
        if showsReplace {
            let replace = NSMenuItem(title: "Перевести и заменить", action: #selector(replaceClicked), keyEquivalent: "")
            replace.target = self
            menu.addItem(replace)
        }
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
