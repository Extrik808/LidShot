import AppKit
import CoreImage

struct Renderer {
    let image: NSImage
    let pixelated: NSImage?
    let blurred: NSImage?

    init(image: NSImage) {
        self.image = image
        pixelated = Renderer.makePixelated(image)
        blurred = Renderer.makeBlurred(image)
    }

    func drawBase() {
        image.draw(in: CGRect(origin: .zero, size: image.size))
    }

    func draw(_ a: Annotation) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch a.tool {
        case .arrow:
            Self.applyShadow()
            a.color.setFill()
            Self.arrowPath(from: a.start, to: a.end, width: a.width).fill()
        case .line:
            Self.applyShadow()
            stroke(Self.segment(a.start, a.end), color: a.color, width: a.width)
        case .rect:
            Self.applyShadow()
            stroke(NSBezierPath(roundedRect: a.rect, xRadius: a.width, yRadius: a.width), color: a.color, width: a.width)
        case .ellipse:
            Self.applyShadow()
            stroke(NSBezierPath(ovalIn: a.rect), color: a.color, width: a.width)
        case .pen:
            Self.applyShadow()
            stroke(Self.smoothPath(a.points), color: a.color, width: a.width)
        case .highlighter:
            NSGraphicsContext.current?.compositingOperation = .multiply
            stroke(Self.smoothPath(a.points), color: a.color.withAlphaComponent(0.45), width: a.strokeWidth)
        case .text:
            drawText(a)
        case .counter:
            drawCounter(a)
        case .pixelate:
            drawMasked(pixelated, in: a.rect)
        case .blur:
            drawMasked(blurred, in: a.rect)
        case .crop:
            drawCropOverlay(a.rect)
        case .select:
            break
        }
    }

    private func drawMasked(_ filtered: NSImage?, in rect: CGRect) {
        NSBezierPath(rect: rect).addClip()
        if let filtered {
            filtered.draw(in: CGRect(origin: .zero, size: image.size))
        } else {
            NSColor.gray.setFill()
            rect.fill()
        }
    }

    private func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawText(_ a: Annotation) {
        let origin = Self.textRect(a).origin
        var outline = Self.textAttributes(a)
        outline[.strokeColor] = Self.contrastColor(for: a.color)
        outline[.strokeWidth] = 16
        (a.text as NSString).draw(at: origin, withAttributes: outline)
        (a.text as NSString).draw(at: origin, withAttributes: Self.textAttributes(a))
    }

    private func drawCounter(_ a: Annotation) {
        let r = a.counterRadius
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        NSGraphicsContext.saveGraphicsState()
        Self.applyShadow()
        a.color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(ovalIn: circle)
        border.lineWidth = max(2, r * 0.14)
        NSColor.white.setStroke()
        border.stroke()

        let label = "\(a.number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r * 1.1, weight: .heavy),
            .foregroundColor: Self.isLight(a.color) ? NSColor.black : NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attributes)
    }

    private func drawCropOverlay(_ rect: CGRect) {
        let full = CGRect(origin: .zero, size: image.size)
        let shade = NSBezierPath(rect: full)
        shade.append(NSBezierPath(rect: rect).reversed)
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
    }

    static func textAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold), .foregroundColor: a.color]
    }

    static func textRect(_ a: Annotation) -> CGRect {
        let size = (a.text as NSString).size(withAttributes: textAttributes(a))
        return CGRect(x: a.start.x, y: a.start.y - size.height, width: size.width, height: size.height)
    }

    static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.65
    }

    static func contrastColor(for color: NSColor) -> NSColor {
        isLight(color) ? NSColor.black.withAlphaComponent(0.85) : NSColor.white
    }

    static func applyShadow() {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
    }

    static func segment(_ a: CGPoint, _ b: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        return path
    }

    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> NSBezierPath {
        let dx = e.x - s.x
        let dy = e.y - s.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux
        let headLength = min(max(w * 4.5, 14), length)
        let headHalf = max(w * 2.6, 8)
        let neckHalf = w * 0.65
        let tailHalf = w * 0.3
        let base = CGPoint(x: e.x - ux * headLength, y: e.y - uy * headLength)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: s.x + px * tailHalf, y: s.y + py * tailHalf))
        path.line(to: CGPoint(x: base.x + px * neckHalf, y: base.y + py * neckHalf))
        path.line(to: CGPoint(x: base.x + px * headHalf, y: base.y + py * headHalf))
        path.line(to: e)
        path.line(to: CGPoint(x: base.x - px * headHalf, y: base.y - py * headHalf))
        path.line(to: CGPoint(x: base.x - px * neckHalf, y: base.y - py * neckHalf))
        path.line(to: CGPoint(x: s.x - px * tailHalf, y: s.y - py * tailHalf))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.line(to: points.last ?? first)
            return path
        }
        for i in 1..<(points.count - 1) {
            let control = points[i]
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            let current = path.currentPoint
            path.curve(
                to: mid,
                controlPoint1: CGPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y)),
                controlPoint2: CGPoint(x: mid.x + 2 / 3 * (control.x - mid.x), y: mid.y + 2 / 3 * (control.y - mid.y))
            )
        }
        path.line(to: points[points.count - 1])
        return path
    }

    static func makeBlurred(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        let input = CIImage(cgImage: cg)
        let pixelsPerPoint = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(pixelsPerPoint, 1) * 9, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }

    static func makePixelated(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: cg)
        let pixelsPerPoint = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(pixelsPerPoint, 1) * 10, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}
