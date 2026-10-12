import AppKit

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, pen, highlighter, text, counter, pixelate, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "square.grid.3x3.fill"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Select & Move"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Step Number"
        case .pixelate: "Pixelate"
        case .crop: "Crop"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rect: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .pixelate: "b"
        case .crop: "c"
        }
    }

    var usesTwoPoints: Bool {
        [.arrow, .line, .rect, .ellipse, .pixelate, .crop].contains(self)
    }

    var isFreehand: Bool {
        self == .pen || self == .highlighter
    }
}

struct Annotation: Identifiable {
    var id = UUID()
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var fontSize: CGFloat { 12 + width * 4 }

    var counterRadius: CGFloat { 9 + width * 1.8 }

    var strokeWidth: CGFloat { tool == .highlighter ? width * 4 : width }

    var bounds: CGRect {
        switch tool {
        case .arrow, .line:
            rect.insetBy(dx: -width * 3, dy: -width * 3)
        case .rect, .ellipse, .pixelate, .crop:
            rect.insetBy(dx: -width / 2, dy: -width / 2)
        case .pen, .highlighter:
            Geometry.boundingBox(points).insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        case .text:
            Renderer.textRect(self)
        case .counter:
            CGRect(x: start.x - counterRadius, y: start.y - counterRadius, width: counterRadius * 2, height: counterRadius * 2)
        case .select:
            .zero
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .arrow:
            Geometry.distance(p, start, end) <= width * 2 + tolerance
        case .line:
            Geometry.distance(p, start, end) <= width / 2 + tolerance
        case .pen, .highlighter:
            points.count == 1
                ? hypot(p.x - points[0].x, p.y - points[0].y) <= strokeWidth / 2 + tolerance
                : zip(points, points.dropFirst()).contains { Geometry.distance(p, $0, $1) <= strokeWidth / 2 + tolerance }
        default:
            bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    mutating func move(by delta: CGVector) {
        start = start.offset(by: delta)
        end = end.offset(by: delta)
        points = points.map { $0.offset(by: delta) }
    }
}

extension CGPoint {
    func offset(by delta: CGVector) -> CGPoint {
        CGPoint(x: x + delta.dx, y: y + delta.dy)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

enum Geometry {
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func constrain(from anchor: CGPoint, to p: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - anchor.x
        let dy = p.y - anchor.y
        switch tool {
        case .arrow, .line:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
        case .rect, .ellipse, .pixelate, .crop:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        default:
            return p
        }
    }
}
