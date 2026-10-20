import AppKit
import Combine
import NaturalLanguage
import SwiftUI
import Translation

struct TargetLanguage: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [TargetLanguage] = [
        TargetLanguage(id: "ru", title: "Русский"),
        TargetLanguage(id: "en", title: "English"),
        TargetLanguage(id: "uk", title: "Українська"),
        TargetLanguage(id: "de", title: "Deutsch"),
        TargetLanguage(id: "fr", title: "Français"),
        TargetLanguage(id: "es", title: "Español"),
        TargetLanguage(id: "it", title: "Italiano"),
        TargetLanguage(id: "pl", title: "Polski"),
        TargetLanguage(id: "pt-BR", title: "Português"),
        TargetLanguage(id: "tr", title: "Türkçe"),
        TargetLanguage(id: "zh-Hans", title: "中文"),
        TargetLanguage(id: "ja", title: "日本語"),
        TargetLanguage(id: "ko", title: "한국어")
    ]

    static func find(_ id: String) -> TargetLanguage? {
        all.first { $0.id == id } ?? all.first { $0.id.hasPrefix(id + "-") }
    }

    static var home: TargetLanguage {
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.split(separator: "-").first ?? "")
            if code != "en", let match = find(code) {
                return match
            }
        }
        return all[0]
    }

    static var english: TargetLanguage { all[1] }
}

final class TranslationModel: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var target: TargetLanguage = .home
    @Published var status = ""
    @Published var isWorking = false
    @Published private(set) var appleRequest = 0
    @Published private(set) var detectedSource: String?

    private var cancellables: Set<AnyCancellable> = []
    private var targetChosenByUser = false

    init() {
        $sourceText.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.translate() }
            .store(in: &cancellables)
    }

    var appleAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    func load(_ text: String) {
        targetChosenByUser = false
        translatedText = ""
        sourceText = text
        translate()
    }

    func pickTarget(_ language: TargetLanguage) {
        targetChosenByUser = true
        target = language
        translate()
    }

    func swapLanguages() {
        guard !translatedText.isEmpty, let detectedSource, let source = TargetLanguage.find(detectedSource) else { return }
        let previous = translatedText
        targetChosenByUser = true
        target = source
        sourceText = previous
        translate()
    }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            translatedText = ""
            status = ""
            isWorking = false
            return
        }
        detectedSource = Self.detect(text)
        if !targetChosenByUser {
            target = detectedSource == TargetLanguage.home.id ? .english : .home
        }
        if detectedSource == target.id {
            translatedText = text
            status = "Текст уже на этом языке"
            return
        }

        guard appleAvailable else {
            status = "Перевод работает на macOS 15 и новее"
            return
        }
        isWorking = true
        status = "Перевожу…"
        appleRequest += 1
    }

    @available(macOS 15.0, *)
    var appleConfiguration: TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: detectedSource.map { Locale.Language(identifier: $0) },
            target: Locale.Language(identifier: target.id)
        )
    }

    @available(macOS 15.0, *)
    @MainActor
    func runApple(_ session: TranslationSession) async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let response = try await session.translate(text)
            guard text == sourceText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            translatedText = response.targetText
            finished(nil)
        } catch {
            finished(error)
        }
    }

    private func finished(_ error: Error?) {
        isWorking = false
        if let error {
            status = "Не удалось перевести: \(error.localizedDescription)"
        } else {
            let name = detectedSource.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? ""
            status = name.isEmpty ? "" : "С языка: \(name)"
        }
    }

    private static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        if language == .simplifiedChinese || language == .traditionalChinese {
            return "zh-Hans"
        }
        return TargetLanguage.find(language.rawValue)?.id ?? language.rawValue
    }
}

struct TranslationView: View {
    @ObservedObject var model: TranslationModel
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $model.sourceText)
                .font(.system(size: 13))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 8) {
                Button { model.swapLanguages() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help("Поменять языки местами")
                Picker("", selection: Binding(get: { model.target }, set: { model.pickTarget($0) })) {
                    ForEach(TargetLanguage.all) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            ScrollView {
                Text(model.translatedText.isEmpty ? " " : model.translatedText)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 90)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))

            HStack {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Скопировать перевод") { onCopy() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.translatedText.isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 300)
        .background {
            if #available(macOS 15.0, *) {
                AppleTranslationHost(model: model)
            }
        }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationHost: View {
    @ObservedObject var model: TranslationModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                await model.runApple(session)
            }
            .onChange(of: model.appleRequest) { _ in
                let next = model.appleConfiguration
                if configuration?.source == next.source, configuration?.target == next.target {
                    configuration?.invalidate()
                } else {
                    configuration = next
                }
            }
    }
}

final class TranslationWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TranslationWindowController()

    private let model = TranslationModel()

    private init() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Перевод"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        let view = TranslationView(model: model) { [weak self] in self?.copyAndClose() }
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ text: String) {
        model.load(text)
        guard let window else { return }
        if !window.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let size = window.frame.size
            let x = min(max(mouse.x - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
            let y = min(max(mouse.y - size.height - 20, area.minY + 8), area.maxY - size.height - 8)
            window.setFrameOrigin(CGPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func translateImage(_ image: NSImage) {
        Toast.show("Распознаю текст…")
        TextRecognizer.recognize(image) { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                NSSound.beep()
                Toast.show("Текст не найден")
                return
            }
            self?.show(trimmed)
        }
    }

    func translateClipboard() {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            show(text)
        } else if let image = NSImage(pasteboard: pasteboard) {
            translateImage(image)
        } else {
            Toast.show("В буфере нет текста или картинки")
        }
    }

    private func copyAndClose() {
        guard !model.translatedText.isEmpty else { return }
        Clipboard.copy(model.translatedText)
        window?.close()
        Toast.show("Перевод скопирован", detail: model.translatedText)
    }
}

final class CopyTwiceWatcher {
    private static let window: TimeInterval = 0.6
    private static let minimumGap: TimeInterval = 0.08

    var onTrigger: (() -> Void)?

    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastCopy: Date?

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "copyTwiceTranslate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "copyTwiceTranslate") }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard Self.isEnabled, count != Clipboard.ownChangeCount, NSEvent.modifierFlags.contains(.command) else {
            lastCopy = nil
            return
        }
        let now = Date()
        if let lastCopy {
            let gap = now.timeIntervalSince(lastCopy)
            if gap < Self.minimumGap { return }
            if gap <= Self.window {
                self.lastCopy = nil
                onTrigger?()
                return
            }
        }
        lastCopy = now
    }
}
