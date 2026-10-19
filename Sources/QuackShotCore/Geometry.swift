import CoreGraphics

/// Selection handles, clockwise from the top-left corner. Coordinates here
/// are top-left-origin (flipped), like the editor view and exported images.
public enum Handle: CaseIterable, Sendable {
    case nw, n, ne, e, se, s, sw, w
}

public extension CGRect {
    /// The rectangle spanned by two corner points, in either order.
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Too small to be a real selection or shape.
    var isTiny: Bool { width < 1 || height < 1 }

    func scaled(_ k: CGFloat) -> CGRect {
        CGRect(x: minX * k, y: minY * k, width: width * k, height: height * k)
    }

    /// Snap outwards to whole pixels so exports have no half-covered edges.
    var pixelAligned: CGRect {
        let x = minX.rounded(), y = minY.rounded()
        return CGRect(x: x, y: y, width: max(0, maxX.rounded() - x), height: max(0, maxY.rounded() - y))
    }

    /// Intersection with `bounds`, or a zero-size rect when they do not overlap.
    func clamped(to bounds: CGRect) -> CGRect {
        let x = Swift.max(minX, bounds.minX), y = Swift.max(minY, bounds.minY)
        let r = Swift.min(maxX, bounds.maxX), b = Swift.min(maxY, bounds.maxY)
        return CGRect(x: x, y: y, width: Swift.max(0, r - x), height: Swift.max(0, b - y))
    }

    /// Translate so the rectangle stays fully inside `bounds`, keeping its size.
    func kept(inside bounds: CGRect) -> CGRect {
        let x = Swift.max(bounds.minX, Swift.min(minX, bounds.maxX - width))
        let y = Swift.max(bounds.minY, Swift.min(minY, bounds.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func position(of h: Handle) -> CGPoint {
        switch h {
        case .nw: return CGPoint(x: minX, y: minY)
        case .n: return CGPoint(x: midX, y: minY)
        case .ne: return CGPoint(x: maxX, y: minY)
        case .e: return CGPoint(x: maxX, y: midY)
        case .se: return CGPoint(x: maxX, y: maxY)
        case .s: return CGPoint(x: midX, y: maxY)
        case .sw: return CGPoint(x: minX, y: maxY)
        case .w: return CGPoint(x: minX, y: midY)
        }
    }

    /// The handle within `radius` of `p`, preferring corners. Edges are
    /// grabbable along their whole length, not only at the midpoint.
    func hitHandle(_ p: CGPoint, radius: CGFloat) -> Handle? {
        for h in [Handle.nw, .ne, .se, .sw] {
            let c = position(of: h)
            if abs(c.x - p.x) <= radius && abs(c.y - p.y) <= radius { return h }
        }
        let inX = p.x >= minX && p.x <= maxX
        let inY = p.y >= minY && p.y <= maxY
        if inX && abs(p.y - minY) <= radius { return .n }
        if inX && abs(p.y - maxY) <= radius { return .s }
        if inY && abs(p.x - minX) <= radius { return .w }
        if inY && abs(p.x - maxX) <= radius { return .e }
        return nil
    }

    /// Drag handle `h` by (dx, dy). Dragging past the opposite edge flips the
    /// rectangle instead of producing a negative size.
    func resized(_ h: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var l = minX, t = minY, r = maxX, b = maxY
        switch h {
        case .nw: l += dx; t += dy
        case .n: t += dy
        case .ne: r += dx; t += dy
        case .e: r += dx
        case .se: r += dx; b += dy
        case .s: b += dy
        case .sw: l += dx; b += dy
        case .w: l += dx
        }
        return CGRect(corner: CGPoint(x: l, y: t), CGPoint(x: r, y: b))
    }
}

/// Snap `b` relative to `a` so the segment is a multiple of 45 degrees.
public func snap45(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = hypot(dx, dy)
    guard len > 0 else { return b }
    let step = CGFloat.pi / 4
    let ang = (atan2(dy, dx) / step).rounded() * step
    return CGPoint(x: a.x + len * cos(ang), y: a.y + len * sin(ang))
}

/// Snap `b` so the box from `a` is square (Shift-constrained shapes).
public func snapSquare(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let side = max(abs(dx), abs(dy))
    func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : (v > 0 ? 1 : 0) }
    return CGPoint(x: a.x + side * sign(dx), y: a.y + side * sign(dy))
}
