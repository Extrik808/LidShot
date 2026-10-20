import AppKit
import Carbon
import SwiftUI

final class HotKeySettings: ObservableObject {
    @Published private(set) var keys: [HotKeyAction: HotKey] = [:]
    @Published private(set) var recording: HotKeyAction?
    @Published private(set) var failed: Set<HotKeyAction> = []
    @Published private(set) var holdKeys: NSEvent.ModifierFlags? = HoldKeys.current
    @Published private(set) var recordingHold = false
    @Published private(set) var holdPreview: NSEvent.ModifierFlags = []
    @Published private(set) var holdError: String?

    var onHoldRecording: ((Bool) -> Void)?
    private var holdMonitor: Any?

    var onSuspend: (() -> Void)?
    var onResume: (() -> Set<HotKeyAction>)?

    private var monitor: Any?

    init() {
        reload()
    }

    var copyTwiceEnabled: Bool {
        get { CopyTwiceWatcher.isEnabled }
        set {
            CopyTwiceWatcher.isEnabled = newValue
            objectWillChange.send()
        }
    }

    func reloadHold() {
        holdKeys = HoldKeys.current
    }

    func startHoldRecording() {
        stopRecording()
        stopHoldRecording()
        recordingHold = true
        holdPreview = []
        holdError = nil
        onHoldRecording?(true)
        holdMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleHold(event)
            return nil
        }
    }

    func stopHoldRecording() {
        if let holdMonitor {
            NSEvent.removeMonitor(holdMonitor)
        }
        holdMonitor = nil
        guard recordingHold else { return }
        recordingHold = false
        holdPreview = []
        onHoldRecording?(false)
    }

    func clearHold() {
        stopHoldRecording()
        HoldKeys.current = nil
        reloadHold()
    }

    private func handleHold(_ event: NSEvent) {
        if event.type == .keyDown {
            if Int(event.keyCode) == kVK_Escape {
                stopHoldRecording()
            } else {
                NSSound.beep()
                holdError = "Только модификаторы: ⌘ ⌥ ⌃ ⇧, без обычных клавиш"
            }
            return
        }
        let pressed = event.modifierFlags.intersection(HoldKeys.allowed)
        if !pressed.isEmpty {
            holdPreview.formUnion(pressed)
            return
        }
        let chosen = holdPreview
        holdPreview = []
        guard !chosen.isEmpty else { return }
        guard chosen.rawValue.nonzeroBitCount >= 2 else {
            NSSound.beep()
            holdError = "Нужно минимум два модификатора, иначе будет срабатывать случайно"
            return
        }
        HoldKeys.current = chosen
        holdError = nil
        reloadHold()
        stopHoldRecording()
    }

    func startRecording(_ action: HotKeyAction) {
        stopRecording()
        stopHoldRecording()
        recording = action
        onSuspend?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        resume()
    }

    func clear(_ action: HotKeyAction) {
        stopRecording()
        action.hotKey = nil
        onSuspend?()
        resume()
    }

    func resetDefaults() {
        stopRecording()
        stopHoldRecording()
        HoldKeys.current = HoldKeys.defaultFlags
        CopyTwiceWatcher.isEnabled = true
        reloadHold()
        HotKeyAction.allCases.forEach { $0.hotKey = $0.defaultKey }
        onSuspend?()
        resume()
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape {
            stopRecording()
            return
        }
        if keyCode == kVK_Delete {
            stopRecording()
            clear(action)
            return
        }
        let modifiers = HotKey.carbonModifiers(event.modifierFlags)
        let hasMainModifier = modifiers & (cmdKey | optionKey | controlKey) != 0
        guard hasMainModifier || HotKey.functionKeys[keyCode] != nil else {
            NSSound.beep()
            return
        }
        let hotKey = HotKey(keyCode: keyCode, modifiers: modifiers)
        for other in HotKeyAction.allCases where other != action && other.hotKey == hotKey {
            other.hotKey = nil
        }
        action.hotKey = hotKey
        stopRecording()
    }

    private func resume() {
        failed = onResume?() ?? []
        reload()
    }

    private func reload() {
        var result: [HotKeyAction: HotKey] = [:]
        for action in HotKeyAction.allCases {
            result[action] = action.hotKey
        }
        keys = result
    }
}

struct HotKeySettingsView: View {
    @ObservedObject var settings: HotKeySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(HotKeyAction.allCases) { action in
                    GridRow {
                        Text(action.title)
                        recorderButton(for: action)
                        Button {
                            settings.clear(action)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Отключить")
                        .opacity(settings.keys[action] == nil ? 0 : 1)
                    }
                    if settings.failed.contains(action) {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Text("Сочетание занято системой или другим приложением")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .gridCellColumns(2)
                        }
                    }
                }
            }

            Text("Нажмите на поле и введите сочетание. Нужен ⌘, ⌥ или ⌃ (F-клавиши можно без них). Esc — отмена, ⌫ — отключить.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Выделение текста (удерживать)")
                    holdRecorderButton
                    Button {
                        settings.clearHold()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Отключить")
                    .opacity(settings.holdKeys == nil ? 0 : 1)
                }
                if let error = settings.holdError {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .gridCellColumns(2)
                    }
                }
            }

            Text(holdHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Переводить скопированное двойным ⌘C", isOn: Binding(
                get: { settings.copyTwiceEnabled },
                set: { settings.copyTwiceEnabled = $0 }
            ))

            HStack {
                Spacer()
                Button("По умолчанию") { settings.resetDefaults() }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear {
            settings.stopRecording()
            settings.stopHoldRecording()
        }
    }

    private var holdHint: String {
        let base = "Удерживайте сочетание — экран замрёт, выделите текст мышью и отпустите клавиши: текст скопируется."
        let translate = (settings.holdKeys ?? []).contains(.shift) ? "" : " Нажмите ⇧ во время выделения — текст переведётся."
        return base + translate + " Для записи нажмите поле, зажмите модификаторы и отпустите."
    }

    private var holdRecorderButton: some View {
        let title: String
        if settings.recordingHold {
            title = settings.holdPreview.isEmpty ? "Зажмите модификаторы…" : HoldKeys.display(settings.holdPreview)
        } else {
            title = HoldKeys.display(settings.holdKeys)
        }
        return Button {
            if settings.recordingHold {
                settings.stopHoldRecording()
            } else {
                settings.startHoldRecording()
            }
        } label: {
            Text(title)
                .frame(minWidth: 150)
                .foregroundStyle(settings.recordingHold ? Color.accentColor : (settings.holdKeys == nil ? .secondary : .primary))
        }
    }

    private func recorderButton(for action: HotKeyAction) -> some View {
        let isRecording = settings.recording == action
        let title = isRecording ? "Нажмите сочетание…" : (settings.keys[action]?.display ?? "Не задано")
        return Button {
            if isRecording {
                settings.stopRecording()
            } else {
                settings.startRecording(action)
            }
        } label: {
            Text(title)
                .frame(minWidth: 150)
                .foregroundStyle(isRecording ? Color.accentColor : (settings.keys[action] == nil ? .secondary : .primary))
        }
    }
}

final class HotKeySettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: HotKeySettings

    init(settings: HotKeySettings) {
        self.settings = settings
        let hosting = NSHostingController(rootView: HotKeySettingsView(settings: settings))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Горячие клавиши"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settings.stopRecording()
        settings.stopHoldRecording()
    }
}
