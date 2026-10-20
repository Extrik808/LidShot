import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let lid = LidController()
    private var editors: [EditorWindowController] = []
    private let hotKeySettings = HotKeySettings()
    private var hotKeyWindow: HotKeySettingsWindowController?
    private let holdSelector = HoldTextSelector()
    private let copyTwice = CopyTwiceWatcher()
    private let inPlace = InPlaceTranslator()
    private lazy var inputButton = InputButtonController(translator: inPlace)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        holdSelector.onTranslate = { TranslationWindowController.shared.show($0) }
        holdSelector.start()
        copyTwice.onTrigger = { TranslationWindowController.shared.translateClipboard() }
        copyTwice.start()
        inputButton.start()
        hotKeySettings.onHoldRecording = { [weak self] isRecording in self?.holdSelector.isPaused = isRecording }

        lid.onChange = { [weak self] in self?.updateIcon() }
        lid.syncWithSystem()
        updateIcon()

        hotKeySettings.onSuspend = { HotKeyCenter.shared.unregisterAll() }
        hotKeySettings.onResume = { [weak self] in self?.registerHotKeys() ?? [] }
        let failed = registerHotKeys()
        if !failed.isEmpty {
            showHotKeys()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.lid.disable(interactive: false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lid.disable()
    }

    @discardableResult
    private func registerHotKeys() -> Set<HotKeyAction> {
        HotKeyCenter.shared.unregisterAll()
        var failed: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let hotKey = action.hotKey else { continue }
            let registered = HotKeyCenter.shared.register(hotKey) { [weak self] in self?.perform(action) }
            if !registered {
                failed.insert(action)
            }
        }
        return failed
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: captureArea()
        case .translateArea: translateArea()
        case .translateInPlace: inPlace.run()
        case .toggleLid: toggleLid()
        }
    }

    private func updateIcon() {
        let name = lid.isOn ? "cup.and.saucer.fill" : "camera.viewfinder"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "LidShot")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = lid.statusText
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: lid.statusText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if lid.isOn {
            menu.addItem(item("Выключить режим закрытой крышки", #selector(toggleLid), hotKey: HotKeyAction.toggleLid.hotKey))
        } else {
            menu.addItem(item("Не спать с закрытой крышкой", #selector(toggleLid), hotKey: HotKeyAction.toggleLid.hotKey))
            let timed = NSMenuItem(title: "Не спать в течение", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, minutes) in [("30 минут", 30), ("1 час", 60), ("2 часа", 120), ("4 часа", 240), ("8 часов", 480)] {
                let entry = item(title, #selector(enableFor(_:)))
                entry.tag = minutes
                entry.isEnabled = lid.helperInstalled
                submenu.addItem(entry)
            }
            if !lid.helperInstalled {
                submenu.addItem(.separator())
                let hint = NSMenuItem(title: "Нужно переключение без пароля", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                submenu.addItem(hint)
            }
            submenu.autoenablesItems = false
            timed.submenu = submenu
            menu.addItem(timed)
        }

        let battery = item("Выключать при заряде \(LidController.batteryThreshold)%", #selector(toggleBatteryGuard))
        battery.state = lid.batteryGuard ? .on : .off
        menu.addItem(battery)

        menu.addItem(item(
            lid.helperInstalled ? "Отключить переключение без пароля" : "Включить переключение без пароля…",
            #selector(toggleHelper)
        ))

        menu.addItem(.separator())
        menu.addItem(item("Снимок области", #selector(captureArea), hotKey: HotKeyAction.captureArea.hotKey))
        menu.addItem(item("Распознать текст из буфера", #selector(textFromClipboard)))
        let hold = item("Выделять текст удержанием \(HoldKeys.display(HoldKeys.current ?? HoldKeys.defaultFlags))", #selector(toggleHold))
        hold.state = HoldKeys.current == nil ? .off : .on
        menu.addItem(hold)

        menu.addItem(.separator())
        menu.addItem(item("Перевести текст с экрана", #selector(translateArea), hotKey: HotKeyAction.translateArea.hotKey))
        menu.addItem(item("Перевести из буфера", #selector(translateClipboard)))
        menu.addItem(item("Перевести текст в поле ввода", #selector(translateInPlace), hotKey: HotKeyAction.translateInPlace.hotKey))
        let button = item("Кнопка перевода в полях ввода", #selector(toggleInputButton))
        button.state = InputButtonController.isEnabled && AXIsProcessTrusted() ? .on : .off
        menu.addItem(button)
        let style = NSMenuItem(title: "Стиль английского: \(EnglishStyle.current.title)", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        styleMenu.autoenablesItems = false
        for option in EnglishStyle.allCases {
            let entry = item(option.title, #selector(pickEnglishStyle(_:)))
            entry.representedObject = option.rawValue
            entry.state = EnglishStyle.current == option ? .on : .off
            styleMenu.addItem(entry)
        }
        styleMenu.addItem(.separator())
        let modelState = NSMenuItem(title: EnglishStyle.modelStatus, action: nil, keyEquivalent: "")
        modelState.isEnabled = false
        styleMenu.addItem(modelState)
        style.submenu = styleMenu
        menu.addItem(style)
        let twice = item("Переводить по двойному ⌘C", #selector(toggleCopyTwice))
        twice.state = CopyTwiceWatcher.isEnabled ? .on : .off
        menu.addItem(twice)

        menu.addItem(.separator())
        menu.addItem(item("Открыть картинку…", #selector(openImage)))
        menu.addItem(item("Горячие клавиши…", #selector(showHotKeys)))

        menu.addItem(.separator())
        let login = item("Запускать при входе", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Выйти из LidShot", #selector(quit), key: "q", modifiers: [.command]))
    }

    private func item(_ title: String, _ action: Selector, hotKey: HotKey?) -> NSMenuItem {
        item(title, action, key: hotKey?.menuKeyEquivalent ?? "", modifiers: hotKey?.menuModifiers ?? [])
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = self
        return entry
    }

    @objc private func toggleLid() {
        if lid.isOn {
            lid.disable()
        } else {
            lid.enable()
        }
    }

    @objc private func enableFor(_ sender: NSMenuItem) {
        lid.enable(for: TimeInterval(sender.tag * 60))
    }

    @objc private func toggleBatteryGuard() {
        lid.batteryGuard.toggle()
    }

    @objc private func toggleHelper() {
        let ok = lid.helperInstalled ? lid.uninstallHelper() : lid.installHelper()
        if !ok {
            NSSound.beep()
        }
    }

    @objc private func captureArea() {
        Capture.area { [weak self] image in self?.openEditor(image) }
    }

    @objc private func toggleHold() {
        HoldKeys.current = HoldKeys.current == nil ? HoldKeys.defaultFlags : nil
        hotKeySettings.reloadHold()
    }

    @objc private func translateArea() {
        Capture.area { TranslationWindowController.shared.translateImage($0) }
    }

    @objc private func translateClipboard() {
        TranslationWindowController.shared.translateClipboard()
    }

    @objc private func toggleInputButton() {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if InputButtonController.isEnabled, trusted, InputButtonController.hiddenApps.isEmpty {
            InputButtonController.isEnabled = false
            return
        }
        InputButtonController.isEnabled = true
        InputButtonController.hiddenApps = []
        if !trusted {
            Toast.show("Включите LidShot в «Универсальном доступе»", detail: "Системные настройки → Конфиденциальность и безопасность → Универсальный доступ")
        }
    }

    @objc private func translateInPlace() {
        inPlace.run()
    }

    @objc private func pickEnglishStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = EnglishStyle(rawValue: raw) else { return }
        EnglishStyle.current = style
    }

    @objc private func toggleCopyTwice() {
        CopyTwiceWatcher.isEnabled.toggle()
        hotKeySettings.objectWillChange.send()
    }

    @objc private func textFromClipboard() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else {
            Toast.show("В буфере нет картинки", detail: "Скопируйте изображение и повторите")
            return
        }
        recognizeAndCopy(image)
    }

    @objc private func openImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) {
                openEditor(image)
            } else {
                Toast.show("Не удалось открыть", detail: url.lastPathComponent)
            }
        }
    }

    private func recognizeAndCopy(_ image: NSImage) {
        Toast.show("Распознаю текст…")
        TextRecognizer.recognize(image) { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                NSSound.beep()
                Toast.show("Текст не найден")
                return
            }
            Clipboard.copy(trimmed)
            let lines = trimmed.split(separator: "\n").count
            Toast.show("Текст скопирован · строк: \(lines)", detail: trimmed)
        }
    }

    @objc private func showHotKeys() {
        if hotKeyWindow == nil {
            hotKeyWindow = HotKeySettingsWindowController(settings: hotKeySettings)
        }
        hotKeyWindow?.present()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openEditor(_ image: NSImage) {
        let editor = EditorWindowController(image: image)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.present()
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти из LidShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(appMenu))

        let fileMenu = NSMenu(title: "Файл")
        fileMenu.addItem(withTitle: "Сохранить…", action: #selector(CanvasView.saveImage(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenuItem(fileMenu))

        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: #selector(CanvasView.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(CanvasView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(editMenu))

        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem()
        entry.submenu = menu
        return entry
    }
}
