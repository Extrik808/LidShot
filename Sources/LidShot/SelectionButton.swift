import AppKit
import ApplicationServices

final class SelectionButtonController {
    private static let skippedApps: Set<String> = ["com.apple.keychainaccess", "com.1password.1password"]
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXWebArea", "AXLink", "AXHeading"]
    private static let dragDistance: CGFloat = 6
    private static let lifetime: TimeInterval = 6

    private var monitors: [Any] = []
    private var panel: InputButtonPanel?
    private var mouseDownPoint = CGPoint.zero
    private var selectedText: String?
    private var hideTimer: Timer?
    private var pending: DispatchWorkItem?
    private let translator: InPlaceTranslator

    init(translator: InPlaceTranslator) {
        self.translator = translator
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "selectionButton") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "selectionButton") }
    }

    static var hiddenApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "selectionButtonHiddenApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "selectionButtonHiddenApps") }
    }

    func start() {
        guard monitors.isEmpty else { return }
        let handlers: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] _ in self?.mouseDown() }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
            ([.rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel], { [weak self] _ in self?.hide() })
        ]
        for (mask, handler) in handlers {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
                monitors.append(monitor)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.hide() }
    }

    private func mouseDown() {
        mouseDownPoint = NSEvent.mouseLocation
        pending?.cancel()
        if panel?.isMouseInside != true {
            hide()
        }
    }

    private func mouseUp(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let dragged = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= Self.dragDistance
        guard dragged || event.clickCount >= 2 else { return }
        guard Self.isEnabled, AXIsProcessTrusted(),
              NSEvent.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.evaluate(at: point) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func evaluate(at point: CGPoint) {
        guard !translator.isBusy,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let bundleID = app.bundleIdentifier ?? ""
        guard !Self.skippedApps.contains(bundleID), !Self.hiddenApps.contains(bundleID) else { return }
        InputButtonController.enableAccessibility(app)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let focused: AXUIElement = InputButtonController.attribute(appElement, kAXFocusedUIElementAttribute) {
            let role: String = InputButtonController.attribute(focused, kAXRoleAttribute) ?? ""
            let subrole: String = InputButtonController.attribute(focused, kAXSubroleAttribute) ?? ""
            if subrole == "AXSecureTextField" { return }
            let editable = InputButtonController.isEditable(focused, role: role)
            if let text = Self.selectedText(of: focused) {
                show(at: point, text: text, editable: editable, bundleID: bundleID)
                return
            }
            if editable {
                let selection: String? = InputButtonController.attribute(focused, kAXSelectedTextAttribute)
                if selection == nil {
                    show(at: point, text: nil, editable: true, bundleID: bundleID)
                }
                return
            }
        }
        guard let element = Self.element(at: point) else { return }
        if let text = Self.selectedTextAround(element) {
            show(at: point, text: text, editable: false, bundleID: bundleID)
            return
        }
        guard Self.hasText(element) else { return }
        show(at: point, text: nil, editable: false, bundleID: bundleID)
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        guard let text: String = InputButtonController.attribute(element, kAXSelectedTextAttribute) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(primaryHeight - point.y), &element
        ) == .success else { return nil }
        return element
    }

    private static func ancestors(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var chain = [element]
        var current = element
        while chain.count <= limit, let parent: AXUIElement = InputButtonController.attribute(current, kAXParentAttribute) {
            let role: String = InputButtonController.attribute(parent, kAXRoleAttribute) ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    private static func selectedTextAround(_ element: AXUIElement) -> String? {
        for candidate in ancestors(of: element, limit: 12) {
            if let text = selectedText(of: candidate) { return text }
        }
        return nil
    }

    private static func hasText(_ element: AXUIElement) -> Bool {
        for candidate in ancestors(of: element, limit: 3) {
            let role: String = InputButtonController.attribute(candidate, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) { return true }
            if role == "AXGroup" || role == "AXCell" || role == "AXRow" {
                let children: [AXUIElement] = InputButtonController.attribute(candidate, kAXChildrenAttribute) ?? []
                let hasStaticText = children.prefix(20).contains {
                    (InputButtonController.attribute($0, kAXRoleAttribute) as String?) == "AXStaticText"
                }
                if hasStaticText { return true }
            }
        }
        return false
    }

    private func show(at point: CGPoint, text: String?, editable: Bool, bundleID: String) {
        selectedText = text
        let panel = panel ?? makePanel()
        panel.bundleID = bundleID
        panel.setReplaceVisible(editable)
        panel.setWorking(false)
        let size = panel.frame.size
        var origin = CGPoint(x: point.x + 6, y: point.y - size.height - 6)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            guard let self else { return }
            if panel?.isMouseInside == true {
                scheduleHide()
            } else {
                hide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> InputButtonPanel {
        let panel = InputButtonPanel(
            toolTip: "Перевести выделенный текст (правый клик — скрыть для приложения)",
            replaceToolTip: "Перевести и заменить выделенный текст (русский ↔ английский)"
        )
        panel.onClick = { [weak self] in self?.translate() }
        panel.onReplace = { [weak self] in self?.translateAndReplace() }
        panel.onHideForApp = { [weak self] bundleID in
            Self.hiddenApps.insert(bundleID)
            self?.hide()
            Toast.show("Кнопка скрыта для этого приложения", detail: "Вернуть: меню LidShot → «Кнопка перевода выделенного текста»")
        }
        self.panel = panel
        return panel
    }

    private func translate() {
        if let text = selectedText {
            hide()
            TranslationWindowController.shared.show(text)
            return
        }
        panel?.setWorking(true)
        copySelection { [weak self] text in
            self?.hide()
            guard let text else {
                NSSound.beep()
                Toast.show("Не удалось взять выделенный текст")
                return
            }
            TranslationWindowController.shared.show(text)
        }
    }

    private func translateAndReplace() {
        guard !translator.isBusy else { return }
        panel?.setWorking(true)
        translator.run(waitForModifiers: false) { [weak self] in self?.hide() }
    }

    private func copySelection(_ completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        CopyTwiceWatcher.suppress(for: 3)
        let before = pasteboard.changeCount
        Keyboard.press(8, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let copied = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
            saved.restore()
            let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(trimmed.isEmpty ? nil : trimmed)
        }
    }
}
