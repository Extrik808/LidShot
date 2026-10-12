import AppKit
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let lid = LidController()
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        lid.onChange = { [weak self] in self?.updateIcon() }
        lid.syncWithSystem()
        updateIcon()

        let optionShift = optionKey | shiftKey
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_4, modifiers: optionShift) { [weak self] in self?.captureArea() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_3, modifiers: optionShift) { [weak self] in self?.captureScreen() }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_L, modifiers: optionShift) { [weak self] in self?.toggleLid() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.lid.disable(interactive: false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lid.disable()
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
            menu.addItem(item("Выключить режим закрытой крышки", #selector(toggleLid), key: "l", modifiers: [.option, .shift]))
        } else {
            menu.addItem(item("Не спать с закрытой крышкой", #selector(toggleLid), key: "l", modifiers: [.option, .shift]))
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
        menu.addItem(item("Снимок области / окна", #selector(captureArea), key: "4", modifiers: [.option, .shift]))
        menu.addItem(item("Снимок экрана", #selector(captureScreen), key: "3", modifiers: [.option, .shift]))
        menu.addItem(item("Снимок экрана через 5 секунд", #selector(captureTimed)))
        menu.addItem(item("Редактировать картинку из буфера", #selector(annotateClipboard)))
        menu.addItem(item("Открыть изображение…", #selector(openImage)))
        menu.addItem(item("Папка для снимков: \(Settings.saveDirectory.lastPathComponent)…", #selector(chooseSaveFolder)))

        menu.addItem(.separator())
        let login = item("Запускать при входе", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Выйти из LidShot", #selector(quit), key: "q", modifiers: [.command]))
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
        Capture.take(.area) { [weak self] image in self?.openEditor(image) }
    }

    @objc private func captureScreen() {
        Capture.take(.screen) { [weak self] image in self?.openEditor(image) }
    }

    @objc private func captureTimed() {
        Capture.take(.timed) { [weak self] image in self?.openEditor(image) }
    }

    @objc private func annotateClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            NSSound.beep()
            return
        }
        openEditor(image)
    }

    @objc private func openImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
        openEditor(image)
    }

    @objc private func chooseSaveFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveDirectory
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            Settings.saveDirectory = url
        }
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
        fileMenu.addItem(withTitle: "Сохранить", action: #selector(CanvasView.saveImage(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Сохранить как…", action: #selector(CanvasView.saveImageAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
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
