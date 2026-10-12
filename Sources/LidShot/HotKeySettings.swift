import AppKit
import Carbon
import SwiftUI

final class HotKeySettings: ObservableObject {
    @Published private(set) var keys: [HotKeyAction: HotKey] = [:]
    @Published private(set) var recording: HotKeyAction?
    @Published private(set) var failed: Set<HotKeyAction> = []

    var onSuspend: (() -> Void)?
    var onResume: (() -> Set<HotKeyAction>)?

    private var monitor: Any?

    init() {
        reload()
    }

    func startRecording(_ action: HotKeyAction) {
        stopRecording()
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

            HStack {
                Spacer()
                Button("По умолчанию") { settings.resetDefaults() }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { settings.stopRecording() }
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
    }
}
