import AppKit
import CoreGraphics

public enum Tool: String, CaseIterable, Sendable {
    case pen, line, arrow, rect, ellipse, marker, text, pixelate, counter

    public var label: String {
        switch self {
        case .pen: return "Pencil (P)"
        case .line: return "Line (L)"
        case .arrow: return "Arrow (A)"
        case .rect: return "Rectangle (R)"
        case .ellipse: return "Ellipse (C)"
        case .marker: return "Marker (M)"
        case .text: return "Text (T)"
        case .pixelate: return "Pixelate (B)"
        case .counter: return "Counter (N)"
        }
    }

    /// Single-letter shortcut, the same as Flameshot and the Linux version.
    public static func forKey(_ c: Character) -> Tool? {
        switch c {
        case "p": return .pen
        case "l": return .line
        case "a": return .arrow
        case "r": return .rect
        case "c": return .ellipse
        case "m": return .marker
        case "t": return .text
        case "b": return .pixelate
        case "n": return .counter
        default: return nil
        }
    }
}

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: CGFloat

    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#rgb`, `#rrggbb` or `#rrggbbaa`.
    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.allSatisfy(\.isHexDigit) else { return nil }
        func byte(_ i: Int, _ n: Int) -> CGFloat {
            let s = h.index(h.startIndex, offsetBy: i)
            let v = CGFloat(Int(h[s..<h.index(s, offsetBy: n)], radix: 16)!)
            return n == 1 ? v * 17 / 255 : v / 255
        }
        switch h.count {
        case 3: self.init(byte(0, 1), byte(1, 1), byte(2, 1))
        case 6: self.init(byte(0, 2), byte(2, 2), byte(4, 2))
        case 8: self.init(byte(0, 2), byte(2, 2), byte(4, 2), byte(6, 2))
        default: return nil
        }
    }

    public var hex: String {
        func q(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", q(r), q(g), q(b))
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public func withAlpha(_ a: CGFloat) -> RGBA { RGBA(r, g, b, a) }
    public var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.6 }

    public static let accent = RGBA(1, 0x8c / 255.0, 0x1a / 255.0)
}

/// One annotation. Coordinates are pixels of the captured image with a
/// top-left origin, so the same value paints on screen and in the export.
public enum Shape: Equatable, Sendable {
    case pen(points: [CGPoint], color: RGBA, width: CGFloat)
    case marker(points: [CGPoint], color: RGBA, width: CGFloat)
    case line(a: CGPoint, b: CGPoint, color: RGBA, width: CGFloat)
    case arrow(a: CGPoint, b: CGPoint, color: RGBA, width: CGFloat)
    case rect(a: CGPoint, b: CGPoint, color: RGBA, width: CGFloat)
    case ellipse(a: CGPoint, b: CGPoint, color: RGBA, width: CGFloat)
    case pixelate(a: CGPoint, b: CGPoint, block: CGFloat)
    case text(pos: CGPoint, text: String, color: RGBA, size: CGFloat)
    case counter(center: CGPoint, n: Int, color: RGBA, radius: CGFloat)

    public static func new(_ tool: Tool, at p: CGPoint, color: RGBA, width: CGFloat, counter: Int) -> Shape {
        switch tool {
        case .pen: return .pen(points: [p], color: color, width: width)
        case .marker: return .marker(points: [p], color: color, width: width)
        case .line: return .line(a: p, b: p, color: color, width: width)
        case .arrow: return .arrow(a: p, b: p, color: color, width: width)
        case .rect: return .rect(a: p, b: p, color: color, width: width)
        case .ellipse: return .ellipse(a: p, b: p, color: color, width: width)
        case .pixelate: return .pixelate(a: p, b: p, block: Metrics.pixelBlock(width))
        case .text: return .text(pos: p, text: "", color: color, size: Metrics.textSize(width))
        case .counter: return .counter(center: p, n: counter, color: color, radius: Metrics.counterRadius(width))
        }
    }

    /// A click without a drag produces nothing worth keeping on the undo stack.
    public var isDegenerate: Bool {
        switch self {
        case .pen(let pts, _, _), .marker(let pts, _, _): return pts.isEmpty
        case .line(let a, let b, _, _), .arrow(let a, let b, _, _): return hypot(a.x - b.x, a.y - b.y) < 2
        case .rect(let a, let b, _, _), .ellipse(let a, let b, _, _), .pixelate(let a, let b, _):
            return CGRect(corner: a, b).isTiny
        case .text(_, let t, _, _): return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: return false
        }
    }

    /// The start point of a dragged two-point shape (for Shift-constraining).
    public var anchor: CGPoint? {
        switch self {
        case .line(let a, _, _, _), .arrow(let a, _, _, _), .rect(let a, _, _, _),
             .ellipse(let a, _, _, _), .pixelate(let a, _, _):
            return a
        default: return nil
        }
    }

    public var isSegment: Bool {
        switch self {
        case .line, .arrow: return true
        default: return false
        }
    }

    /// Moves the end point of a two-point shape, or appends to a stroke.
    public mutating func extend(to p: CGPoint) {
        switch self {
        case .pen(var pts, let c, let w):
            if let l = pts.last, hypot(l.x - p.x, l.y - p.y) < 0.5 { return }
            pts.append(p); self = .pen(points: pts, color: c, width: w)
        case .marker(var pts, let c, let w):
            if let l = pts.last, hypot(l.x - p.x, l.y - p.y) < 0.5 { return }
            pts.append(p); self = .marker(points: pts, color: c, width: w)
        case .line(let a, _, let c, let w): self = .line(a: a, b: p, color: c, width: w)
        case .arrow(let a, _, let c, let w): self = .arrow(a: a, b: p, color: c, width: w)
        case .rect(let a, _, let c, let w): self = .rect(a: a, b: p, color: c, width: w)
        case .ellipse(let a, _, let c, let w): self = .ellipse(a: a, b: p, color: c, width: w)
        case .pixelate(let a, _, let bl): self = .pixelate(a: a, b: p, block: bl)
        case .text, .counter: break
        }
    }

    public var isCounter: Bool {
        if case .counter = self { return true }
        return false
    }
}

public enum Metrics {
    public static func markerWidth(_ w: CGFloat) -> CGFloat { w * 3 + 10 }
    public static func textSize(_ w: CGFloat) -> CGFloat { 14 + w * 2 }
    public static func counterRadius(_ w: CGFloat) -> CGFloat { 10 + w * 1.5 }
    public static func pixelBlock(_ w: CGFloat) -> CGFloat { (w * 2.5 + 6).rounded() }
}

/// Head geometry of an arrow from `a` to `b`: (shaft end, left, right).
public func arrowHead(_ a: CGPoint, _ b: CGPoint, width: CGFloat) -> (CGPoint, CGPoint, CGPoint) {
    let len = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
    let head = min(width * 3.5 + 8, len)
    let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
    let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
    let half = head * 0.55
    let left = CGPoint(x: base.x - uy * half, y: base.y + ux * half)
    let right = CGPoint(x: base.x + uy * half, y: base.y - ux * half)
    // Stop the shaft inside the head so its end does not poke out of the tip.
    let shaft = CGPoint(x: b.x - ux * head * 0.6, y: b.y - uy * head * 0.6)
    return (shaft, left, right)
}

public func textFont(size: CGFloat) -> NSFont { .boldSystemFont(ofSize: size) }

public func textAttributes(size: CGFloat, color: RGBA) -> [NSAttributedString.Key: Any] {
    [.font: textFont(size: size), .foregroundColor: color.nsColor]
}

/// Draws `image` into `rect` of a top-left-origin context. CGContext.draw
/// assumes a bottom-left origin, so flip locally around the rect.
public func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, interpolation: CGInterpolationQuality = .default) {
    ctx.saveGState()
    ctx.interpolationQuality = interpolation
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

/// Run `body` with AppKit text drawing routed into `ctx` (top-left origin).
public func withAppKitContext(_ ctx: CGContext, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Average `r` of `base` down to one pixel per block, then draw it back with
/// nearest-neighbour scaling.
func pixelate(_ ctx: CGContext, base: CGImage, rect: CGRect, block: CGFloat) {
    let r = rect.pixelAligned.clamped(to: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    guard !r.isTiny, let crop = base.cropping(to: r) else { return }
    let sw = max(1, Int((r.width / block).rounded(.up)))
    let sh = max(1, Int((r.height / block).rounded(.up)))
    guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    small.interpolationQuality = .high
    small.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    guard let tiny = small.makeImage() else { return }
    drawImage(ctx, tiny, in: r, interpolation: .none)
}

private func strokePoints(_ ctx: CGContext, _ pts: [CGPoint]) {
    guard let first = pts.first else { return }
    ctx.move(to: first)
    if pts.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
    for p in pts.dropFirst() { ctx.addLine(to: p) }
    ctx.strokePath()
}

/// Paints one shape into a top-left-origin context. `base` is the untouched
/// screenshot, which the pixelate tool samples from.
public func render(_ shape: Shape, in ctx: CGContext, base: CGImage) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    switch shape {
    case .pen(let pts, let c, let w):
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); strokePoints(ctx, pts)
    case .marker(let pts, let c, let w):
        ctx.setStrokeColor(c.withAlpha(0.38).cgColor); ctx.setLineWidth(Metrics.markerWidth(w)); strokePoints(ctx, pts)
    case .line(let a, let b, let c, let w):
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    case .arrow(let a, let b, let c, let w):
        let (shaft, l, r) = arrowHead(a, b, width: w)
        ctx.setStrokeColor(c.cgColor); ctx.setFillColor(c.cgColor); ctx.setLineWidth(w)
        ctx.move(to: a); ctx.addLine(to: shaft); ctx.strokePath()
        ctx.move(to: b); ctx.addLine(to: l); ctx.addLine(to: r); ctx.closePath(); ctx.fillPath()
    case .rect(let a, let b, let c, let w):
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
        ctx.setLineCap(.square); ctx.setLineJoin(.miter)
        ctx.stroke(CGRect(corner: a, b))
    case .ellipse(let a, let b, let c, let w):
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
        ctx.strokeEllipse(in: CGRect(corner: a, b))
    case .pixelate(let a, let b, let block):
        pixelate(ctx, base: base, rect: CGRect(corner: a, b), block: block)
    case .text(let pos, let text, let c, let size):
        withAppKitContext(ctx) {
            NSAttributedString(string: text, attributes: textAttributes(size: size, color: c)).draw(at: pos)
        }
    case .counter(let center, let n, let c, let radius):
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let fg: RGBA = c.isLight ? RGBA(0.1, 0.1, 0.1) : RGBA(1, 1, 1)
        let s = NSAttributedString(string: "\(n)", attributes: textAttributes(size: radius * 1.1, color: fg))
        let sz = s.size()
        withAppKitContext(ctx) { s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2)) }
    }
}

public func makeContext(width: Int, height: Int) -> CGContext? {
    CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// `base` with `shapes` painted on, cropped to `selection` (image pixels).
public func export(base: CGImage, shapes: [Shape], selection: CGRect) -> CGImage? {
    let sel = selection.pixelAligned
    guard let ctx = makeContext(width: Int(sel.width), height: Int(sel.height)) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(ctx.height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: -sel.minX, y: -sel.minY)
    drawImage(ctx, base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    for s in shapes { render(s, in: ctx, base: base) }
    return ctx.makeImage()
}
