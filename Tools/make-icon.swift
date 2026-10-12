import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let outer = NSShadow()
outer.shadowColor = NSColor.black.withAlphaComponent(0.35)
outer.shadowBlurRadius = 28
outer.shadowOffset = NSSize(width: 0, height: -12)
outer.set()
color(0x1B1F4B).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [color(0x2A1B6E), color(0x4F46E5), color(0x8B5CF6)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: 60)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(fromCenter: CGPoint(x: 360, y: 860), radius: 0, toCenter: CGPoint(x: 360, y: 860), radius: 620, options: [])
NSGraphicsContext.restoreGraphicsState()

let bracketColor = NSColor.white.withAlphaComponent(0.92)
let frame = CGRect(x: 215, y: 250, width: 594, height: 520)
let arm: CGFloat = 120
let lw: CGFloat = 38
for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
                         (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0)] {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    p.line(to: corner)
    p.line(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    p.lineWidth = lw
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    bracketColor.setStroke()
    p.stroke()
}

NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = NSColor.black.withAlphaComponent(0.3)
glow.shadowBlurRadius = 18
glow.shadowOffset = NSSize(width: 0, height: -8)
glow.set()
let lid = CGRect(x: 340, y: 430, width: 344, height: 230)
let lidPath = NSBezierPath(roundedRect: lid, xRadius: 26, yRadius: 26)
NSColor.white.setFill()
lidPath.fill()
let base = NSBezierPath(roundedRect: CGRect(x: 300, y: 392, width: 424, height: 34), xRadius: 17, yRadius: 17)
base.fill()
NSGraphicsContext.restoreGraphicsState()

let screen = lid.insetBy(dx: 22, dy: 22)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 10, yRadius: 10)
NSGradient(colors: [color(0x111433), color(0x2B2F77)])!.draw(in: screenPath, angle: 90)

let moonCenter = CGPoint(x: screen.midX, y: screen.midY)
let moon = NSBezierPath(ovalIn: CGRect(x: moonCenter.x - 52, y: moonCenter.y - 52, width: 104, height: 104))
let bite = NSBezierPath(ovalIn: CGRect(x: moonCenter.x - 22, y: moonCenter.y - 18, width: 104, height: 104))
NSGraphicsContext.saveGraphicsState()
let clip = NSBezierPath(rect: screen)
clip.append(bite.reversed)
clip.addClip()
color(0xFDE68A).setFill()
moon.fill()
NSGraphicsContext.restoreGraphicsState()

func arrow(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> NSBezierPath {
    let dx = e.x - s.x, dy = e.y - s.y
    let len = hypot(dx, dy)
    let ux = dx / len, uy = dy / len, px = -uy, py = ux
    let headLen = w * 3.2, headHalf = w * 1.9, neck = w * 0.5, tail = w * 0.28
    let b = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)
    let path = NSBezierPath()
    path.move(to: CGPoint(x: s.x + px * tail, y: s.y + py * tail))
    path.line(to: CGPoint(x: b.x + px * neck, y: b.y + py * neck))
    path.line(to: CGPoint(x: b.x + px * headHalf, y: b.y + py * headHalf))
    path.line(to: e)
    path.line(to: CGPoint(x: b.x - px * headHalf, y: b.y - py * headHalf))
    path.line(to: CGPoint(x: b.x - px * neck, y: b.y - py * neck))
    path.line(to: CGPoint(x: s.x - px * tail, y: s.y - py * tail))
    path.close()
    path.lineJoinStyle = .round
    return path
}

NSGraphicsContext.saveGraphicsState()
let arrowShadow = NSShadow()
arrowShadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
arrowShadow.shadowBlurRadius = 14
arrowShadow.shadowOffset = NSSize(width: 0, height: -6)
arrowShadow.set()
let a = arrow(from: CGPoint(x: 820, y: 230), to: CGPoint(x: 640, y: 420), width: 46)
NSGradient(colors: [color(0xFF5A36), color(0xFF2D55)])!.draw(in: a, angle: 135)
NSGraphicsContext.restoreGraphicsState()
let outline = arrow(from: CGPoint(x: 820, y: 230), to: CGPoint(x: 640, y: 420), width: 46)
outline.lineWidth = 6
NSColor.white.withAlphaComponent(0.9).setStroke()
outline.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
_ = ctx
