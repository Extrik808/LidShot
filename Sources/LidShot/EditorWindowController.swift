import AppKit
import SwiftUI

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static let toolbarHeight: CGFloat = 46
    private static let minContentSize = CGSize(width: 1080, height: 320)

    let state = EditorState()
    let canvas: CanvasView
    var onClose: (() -> Void)?

    init(image: NSImage) {
        canvas = CanvasView(image: image, state: state)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = screen.width * 0.9
        let maxHeight = screen.height * 0.9 - Self.toolbarHeight
        let fit = min(1, maxWidth / max(image.size.width, 1), maxHeight / max(image.size.height, 1))
        let contentSize = CGSize(
            width: max(image.size.width * fit, Self.minContentSize.width),
            height: max(image.size.height * fit + Self.toolbarHeight, Self.minContentSize.height)
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LidShot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minContentSize

        let toolbar = NSHostingView(rootView: ToolbarView(state: state, canvas: canvas))
        toolbar.sizingOptions = []
        let container = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container

        super.init(window: window)
        window.delegate = self
        window.center()
        canvas.onStatus = { [weak window] message in window?.subtitle = message }
        window.subtitle = "\(Int(image.size.width))×\(Int(image.size.height)) — Return: скопировать и закрыть"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
