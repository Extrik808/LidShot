import AppKit
import Combine

final class CanvasView: NSView, NSTextFieldDelegate {
    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect?
    }

    private enum DragMode {
        case none
        case creating
        case moving(CGPoint)
        case handle(isStart: Bool)
    }

    let image: NSImage
    let state: EditorState
    var onStatus: ((String) -> Void)?

    private let renderer: Renderer
    private let baseImage: CGImage?
    private var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    private var crop: CGRect? { didSet { needsDisplay = true; layoutTextField() } }
    private var selectedID: UUID? { didSet { needsDisplay = true } }
    private var draft: Annotation? { didSet { needsDisplay = true } }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var coalesceKey: String?
    private var dragMode = DragMode.none
    private var dragUndoPushed = false
    private var textField: NSTextField?
    private var editingText: Annotation?
    private var cancellables: Set<AnyCancellable> = []

    init(image: NSImage, state: EditorState) {
        self.image = image
        self.state = state
        renderer = Renderer(image: image)
        baseImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: .zero)

        state.$tool.dropFirst().sink { [weak self] tool in self?.toolChanged(to: tool) }.store(in: &cancellables)
        state.$color.dropFirst().sink { [weak self] color in
            self?.restyleSelection(key: "color") { $0.color = color }
        }.store(in: &cancellables)
        state.$width.dropFirst().sink { [weak self] width in
            self?.restyleSelection(key: "width") { $0.width = width }
        }.store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hasEdits: Bool { !annotations.isEmpty || crop != nil }

    private var fullRect: CGRect { CGRect(origin: .zero, size: image.size) }

    private var viewport: CGRect { crop ?? fullRect }

    private var scale: CGFloat {
        let v = viewport
        guard v.width > 0, v.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / v.width, bounds.height / v.height, 1)
    }

    private var origin: CGPoint {
        let s = scale
        return CGPoint(x: (bounds.width - viewport.width * s) / 2, y: (bounds.height - viewport.height * s) / 2)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let s = scale, o = origin, v = viewport.origin
        return CGPoint(x: (p.x - o.x) / s + v.x, y: (p.y - o.y) / s + v.y)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let s = scale, o = origin, v = viewport.origin
        return CGPoint(x: (p.x - v.x) * s + o.x, y: (p.y - v.y) * s + o.y)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    private var selectedIndex: Int? {
        annotations.firstIndex { $0.id == selectedID }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.scale(by: scale)
        transform.translateX(by: -viewport.origin.x, yBy: -viewport.origin.y)
        transform.concat()
        NSBezierPath(rect: viewport).addClip()

        renderer.drawBase()
        for annotation in annotations where annotation.id != editingText?.id {
            renderer.draw(annotation)
        }
        if let draft {
            renderer.draw(draft)
        }
        if let index = selectedIndex {
            drawSelection(annotations[index])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelection(_ a: Annotation) {
        let s = scale
        if a.tool != .arrow && a.tool != .line {
            let outline = NSBezierPath(rect: a.bounds.insetBy(dx: -4 / s, dy: -4 / s))
            outline.lineWidth = 1 / s
            outline.setLineDash([4 / s, 3 / s], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
        guard a.tool.usesTwoPoints else { return }
        for p in [a.start, a.end] {
            let r = 5 / s
            let handle = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5 / s
            NSColor.controlAccentColor.setStroke()
            handle.stroke()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch state.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTextField()
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        let tolerance = 6 / scale

        switch state.tool {
        case .select:
            if let index = selectedIndex, annotations[index].tool.usesTwoPoints {
                let a = annotations[index]
                if p.distance(to: a.start) <= tolerance + 4 / scale {
                    beginDrag(.handle(isStart: true))
                    return
                }
                if p.distance(to: a.end) <= tolerance + 4 / scale {
                    beginDrag(.handle(isStart: false))
                    return
                }
            }
            guard let hit = annotations.last(where: { $0.hitTest(p, tolerance: tolerance) }) else {
                selectedID = nil
                return
            }
            selectedID = hit.id
            if event.clickCount == 2, hit.tool == .text {
                beginTextEditing(existing: hit, at: hit.start)
                return
            }
            beginDrag(.moving(p))
        case .text:
            if let hit = annotations.last(where: { $0.tool == .text && $0.hitTest(p, tolerance: tolerance) }) {
                beginTextEditing(existing: hit, at: hit.start)
            } else {
                beginTextEditing(existing: nil, at: p)
            }
        case .counter:
            let next = (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
            pushUndo()
            annotations.append(Annotation(tool: .counter, color: state.color, width: state.width, start: p, end: p, number: next))
        default:
            selectedID = nil
            draft = Annotation(tool: state.tool, color: state.color, width: state.width, start: p, end: p, points: [p])
            dragMode = .creating
        }
    }

    private func beginDrag(_ mode: DragMode) {
        dragMode = mode
        dragUndoPushed = false
    }

    private func pushUndoOnceForDrag() {
        guard !dragUndoPushed else { return }
        pushUndo()
        dragUndoPushed = true
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = imagePoint(event)
        let constrained = event.modifierFlags.contains(.shift)

        switch dragMode {
        case .creating:
            guard var d = draft else { return }
            if d.tool.isFreehand {
                d.points.append(raw)
                d.end = raw
            } else {
                d.end = constrained ? Geometry.constrain(from: d.start, to: raw, tool: d.tool) : raw
            }
            draft = d
        case .moving(let last):
            guard let index = selectedIndex else { return }
            pushUndoOnceForDrag()
            annotations[index].move(by: CGVector(dx: raw.x - last.x, dy: raw.y - last.y))
            dragMode = .moving(raw)
        case .handle(let isStart):
            guard let index = selectedIndex else { return }
            pushUndoOnceForDrag()
            let a = annotations[index]
            let anchor = isStart ? a.end : a.start
            let p = constrained ? Geometry.constrain(from: anchor, to: raw, tool: a.tool) : raw
            if isStart {
                annotations[index].start = p
            } else {
                annotations[index].end = p
            }
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draft = nil
            dragMode = .none
        }
        guard case .creating = dragMode, let d = draft else { return }
        if d.tool == .crop {
            applyCrop(d.rect)
            return
        }
        let meaningful = d.tool.isFreehand || d.start.distance(to: d.end) > 3 / scale
        guard meaningful else { return }
        pushUndo()
        annotations.append(d)
    }

    private func applyCrop(_ rect: CGRect) {
        let clipped = rect.intersection(fullRect).integral
        guard clipped.width >= 8, clipped.height >= 8 else { return }
        pushUndo()
        crop = clipped
        state.tool = .select
        onStatus?("Обрезано до \(Int(clipped.width))×\(Int(clipped.height)) — ⌘Z для отмены")
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            deleteSelection()
            return
        case 36, 76:
            finish()
            return
        case 53:
            if selectedID != nil {
                selectedID = nil
            } else if !hasEdits {
                window?.performClose(nil)
            }
            return
        default:
            break
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty,
           let character = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.key == character }) {
            state.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    private func toolChanged(to tool: Tool) {
        commitText()
        if tool != .select {
            selectedID = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.invalidateCursorRects(for: self)
            window?.makeFirstResponder(self)
        }
    }

    private func restyleSelection(key: String, _ change: (inout Annotation) -> Void) {
        if let field = textField, var a = editingText {
            change(&a)
            editingText = a
            field.textColor = a.color
            field.font = NSFont.systemFont(ofSize: a.fontSize * scale, weight: .bold)
            layoutTextField()
            return
        }
        guard let index = selectedIndex else { return }
        pushUndo(coalescing: "\(annotations[index].id)-\(key)")
        change(&annotations[index])
    }

    private func deleteSelection() {
        guard let index = selectedIndex else { return }
        pushUndo()
        annotations.remove(at: index)
        selectedID = nil
    }

    private func pushUndo(coalescing key: String? = nil) {
        if let key, key == coalesceKey { return }
        coalesceKey = key
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 200 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func restore(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        crop = snapshot.crop
        selectedID = nil
        coalesceKey = nil
    }

    private func beginTextEditing(existing: Annotation?, at p: CGPoint) {
        commitText()
        let a = existing ?? Annotation(
            tool: .text,
            color: state.color,
            width: state.width,
            start: CGPoint(x: p.x, y: p.y + (12 + state.width * 4) * 0.6),
            end: p
        )
        editingText = a
        selectedID = nil

        let field = NSTextField(string: a.text)
        field.font = NSFont.systemFont(ofSize: a.fontSize * scale, weight: .bold)
        field.textColor = a.color
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        textField = field
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let field = textField, let a = editingText, let font = field.font else { return }
        let top = toView(a.start)
        let textWidth = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        field.frame = CGRect(x: top.x - 2, y: top.y - height + 2, width: max(80, textWidth + 30), height: height)
    }

    func controlTextDidChange(_ obj: Notification) {
        layoutTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    private func commitText() {
        guard let field = textField, var a = editingText else { return }
        textField = nil
        editingText = nil
        field.delegate = nil
        let text = field.stringValue
        field.removeFromSuperview()
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        a.text = text

        if let index = annotations.firstIndex(where: { $0.id == a.id }) {
            pushUndo()
            if isEmpty {
                annotations.remove(at: index)
            } else {
                annotations[index] = a
            }
        } else if !isEmpty {
            pushUndo()
            annotations.append(a)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func renderPNG() -> Data? {
        commitText()
        guard let base = baseImage, image.size.width > 0, image.size.height > 0 else { return nil }
        let ratio = CGFloat(base.width) / image.size.width
        let area = viewport
        let pixelWidth = Int((area.width * ratio).rounded())
        let pixelHeight = Int((area.height * ratio).rounded())
        let colorSpace = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.scaleBy(x: ratio, y: ratio)
        context.translateBy(x: -area.origin.x, y: -area.origin.y)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        renderer.drawBase()
        annotations.forEach(renderer.draw)
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: output)
        rep.size = area.size
        return rep.representation(using: .png, properties: [:])
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(previous)
    }

    @objc func redo(_ sender: Any?) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(next)
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    @objc func copy(_ sender: Any?) {
        guard let png = renderPNG() else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        onStatus?("Скопировано в буфер обмена")
    }

    @objc func saveImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Settings.saveDirectory
        panel.nameFieldStringValue = Settings.screenshotFileName()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.saveDirectory = url.deletingLastPathComponent()
            self?.write(to: url)
        }
    }

    func finish() {
        copy(nil)
        window?.close()
    }

    private func write(to url: URL) {
        guard let png = renderPNG() else {
            NSSound.beep()
            return
        }
        do {
            try png.write(to: url)
            onStatus?("Сохранено: \(url.lastPathComponent)")
        } catch {
            onStatus?("Не удалось сохранить: \(error.localizedDescription)")
        }
    }
}
