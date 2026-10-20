import AppKit
import ApplicationServices
import Translation

final class InPlaceTranslator {
    private(set) var isBusy = false
    private var completion: (() -> Void)?

    func run(waitForModifiers: Bool = true, completion: (() -> Void)? = nil) {
        guard !isBusy else { return }
        guard ensureAccessibility() else {
            completion?()
            return
        }
        isBusy = true
        self.completion = completion
        if waitForModifiers {
            waitForModifiersRelease { [weak self] in self?.grabText() }
        } else {
            grabText()
        }
    }

    private func done() {
        isBusy = false
        let completion = completion
        self.completion = nil
        completion?()
    }

    private func ensureAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return true
        }
        Toast.show(
            "Нужен доступ «Универсальный доступ»",
            detail: "Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → включите LidShot"
        )
        return false
    }

    private func waitForModifiersRelease(attempt: Int = 0, then action: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        if held.isEmpty || attempt > 30 {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForModifiersRelease(attempt: attempt + 1, then: action)
        }
    }

    private func grabText() {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        CopyTwiceWatcher.suppress(for: 3)

        let selection = Self.focusedSelectedText()
        if let selection, selection.isEmpty {
            Keyboard.press(0, flags: .maskCommand)
        }
        let before = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Keyboard.press(8, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                let copied = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
                if let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translate(copied, saved: saved)
                } else if selection == nil {
                    selectAllAndCopy(saved: saved)
                } else {
                    fail("Не нашёл текста в поле", saved: saved)
                }
            }
        }
    }

    private func selectAllAndCopy(saved: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        Keyboard.press(0, flags: .maskCommand)
        let before = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Keyboard.press(8, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                let copied = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
                if let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translate(copied, saved: saved)
                } else {
                    fail("Не нашёл текста в поле", saved: saved)
                }
            }
        }
    }

    private func translate(_ text: String, saved: PasteboardSnapshot) {
        let source = LanguageDetector.detect(text)
        let target: TargetLanguage = source == TargetLanguage.home.id ? .english : .home
        guard source != target.id else {
            fail("Текст уже на нужном языке", saved: saved)
            return
        }
        Toast.show("Перевожу…")
        guard #available(macOS 26.0, *) else {
            saved.restore()
            done()
            TranslationWindowController.shared.show(text)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: source ?? "ru"),
                target: Locale.Language(identifier: target.id)
            )
            do {
                var result = try await session.translate(text).targetText
                if target == .english {
                    result = await EnglishStyle.current.polish(result, original: text)
                }
                paste(Self.keepEdges(of: text, around: result), saved: saved)
            } catch {
                saved.restore()
                done()
                Toast.show("Сначала скачайте языковой пакет", detail: "Откроется окно перевода: согласитесь на загрузку, дальше всё офлайн")
                TranslationWindowController.shared.show(text)
            }
        }
    }

    private func paste(_ text: String, saved: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Clipboard.ownChangeCount = pasteboard.changeCount
        Keyboard.press(9, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            saved.restore()
            self?.done()
            Toast.show("Переведено", detail: text)
        }
    }

    private func fail(_ message: String, saved: PasteboardSnapshot) {
        saved.restore()
        done()
        NSSound.beep()
        Toast.show(message)
    }

    private static func keepEdges(of original: String, around translated: String) -> String {
        let leading = original.prefix { $0.isWhitespace }
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + translated.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }

    private static func focusedSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else {
            return nil
        }
        return selected as? String
    }
}

enum Keyboard {
    static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                data[type] = item.data(forType: type)
            }
            return data
        }
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
        Clipboard.ownChangeCount = pasteboard.changeCount
    }
}
