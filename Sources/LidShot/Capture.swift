import AppKit

enum Capture {
    static func area(completion: @escaping (NSImage) -> Void) {
        guard ensurePermission() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lidshot-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-i", url.path]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
                completion(image)
            }
        }
        do {
            try process.run()
        } catch {
            NSSound.beep()
        }
    }

    private static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Нужен доступ к записи экрана"
        alert.informativeText = "Разрешите LidShot в Системных настройках → Конфиденциальность и безопасность → Запись экрана и системного звука, затем перезапустите LidShot."
        alert.addButton(withTitle: "Открыть Системные настройки")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
