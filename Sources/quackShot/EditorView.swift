import AppKit
import QuackShotCore

/// What the user chose to do with the selection.
enum EditorAction {
    case accept, copy, save, pin
}

@MainActor
protocol EditorHost: AnyObject {
    /// A new selection is starting here; other screens should drop theirs.
    func editorWillSelect(_ editor: EditorView)
    func editor(_ editor: EditorView, finish action: EditorAction)
    func editorCancel(_ editor: EditorView)
}

/// The frozen screenshot plus committed annotations. Kept in its own view so
/// it only repaints when the annotations change, not on every mouse move.
final class BaseImageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        drawImage(ctx, image, in: bounds, interpolation: .high)
    }
}

/// Text entry for the text tool: a bare NSTextView, so input methods
/// (Chinese, Japanese, emoji picker…) work exactly as everywhere else.
final class AnnotationTextView: NSTextView {
    var onFinish: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]
        if event.keyCode == 53 || (returnKeys.contains(event.keyCode) && event.modifierFlags.contains(.command)) {
            if !hasMarkedText() {
                onFinish?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class EditorView: NSView {
    private enum Drag {
        case none
        case selecting(start: CGPoint)
        case moving(start: CGPoint, orig: CGRect)
        case resizing(handle: Handle, start: CGPoint, orig: CGRect)
        case drawing
    }

    private static let handleHit: CGFloat = 8
    private static let paletteRing: CGFloat = 74
    private static let swatch: CGFloat = 13

    let base: CGImage
    let baseView: BaseImageView
    var config: Config
    var options: Options
    weak var host: EditorHost?

    private(set) var selection: CGRect?
    private var drag: Drag = .none
    private(set) var tool: Tool?
    private(set) var color: RGBA
    private(set) var width: CGFloat
    private(set) var shapes: [Shape] = [] { didSet { refreshBase() } }
    private var redoStack: [Shape] = []
    private var current: Shape?
    private var textView: AnnotationTextView?
    private var textOrigin: CGPoint = .zero
    private var paletteAt: CGPoint?
    private var mouse = CGPoint(x: -1000, y: -1000)
    private var hover: Int?
    private var widthHintUntil: Date?
    private var scrollAccumulator: CGFloat = 0
    private var symbolCache: [String: NSImage] = [:]

    init(frame: NSRect, base: CGImage, baseView: BaseImageView, config: Config, options: Options) {
        self.base = base
        self.baseView = baseView
        self.config = config
        self.options = options
        self.color = config.rgba
        self.width = CGFloat(config.width)
        super.init(frame: frame)
        wantsLayer = true
        baseView.image = base
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Coordinates

    /// Image pixels per view point (the display's backing scale).
    var k: CGFloat { CGFloat(base.width) / max(bounds.width, 1) }
    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    private func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
    private var selectionInView: CGRect? { selection.map { $0.scaled(1 / k) } }
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    /// The selection in screen coordinates (Cocoa, bottom-left origin).
    var selectionOnScreen: CGRect? {
        guard let r = selectionInView ?? Optional(bounds), let window else { return nil }
        return window.convertToScreen(convert(r, to: nil))
    }

    private var toolbarCentres: [CGPoint] {
        guard let s = selectionInView else { return [] }
        switch drag {
        case .none, .drawing: return ToolbarLayout.centres(selection: s, screen: bounds)
        default: return []
        }
    }

    // MARK: - Model

    private func refreshBase() {
        guard !shapes.isEmpty, let ctx = makeContext(width: base.width, height: base.height) else {
            baseView.image = base
            return
        }
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: 1, y: -1)
        drawImage(ctx, base, in: imageBounds)
        for s in shapes { render(s, in: ctx, base: base) }
        baseView.image = ctx.makeImage() ?? base
    }

    private func push(_ s: Shape) {
        guard !s.isDegenerate else { return }
        shapes.append(s)
        redoStack.removeAll()
    }

    func undo() {
        if textView != nil { cancelText(); return }
        if let s = shapes.popLast() { redoStack.append(s) }
        needsDisplay = true
    }

    func redo() {
        if let s = redoStack.popLast() { shapes.append(s) }
        needsDisplay = true
    }

    func selectTool(_ t: Tool) {
        commitText()
        tool = (tool == t) ? nil : t
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func clearSelection() {
        commitText()
        selection = nil
        paletteAt = nil
        needsDisplay = true
    }

    func selectAll() {
        selection = imageBounds
        needsDisplay = true
    }

    /// The selection (or whole screen) with annotations, ready to output.
    func exportImage() -> CGImage? {
        commitText()
        let sel = selection.flatMap { $0.isTiny ? nil : $0 } ?? imageBounds
        return export(base: base, shapes: shapes, selection: sel)
    }

    // MARK: - Text tool

    private func beginText(at p: CGPoint) {
        let tv = AnnotationTextView(frame: CGRect(origin: p, size: CGSize(width: 40, height: 20)))
        let size = Metrics.textSize(width) / k
        tv.font = textFont(size: size)
        tv.textColor = color.nsColor
        tv.insertionPointColor = color.nsColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 1e6, height: 1e6)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.minSize = CGSize(width: size, height: size * 1.25)
        tv.maxSize = CGSize(width: 1e6, height: 1e6)
        tv.onFinish = { [weak self] in self?.commitText() }
        tv.delegate = self
        addSubview(tv)
        textView = tv
        textOrigin = toImage(p)
        window?.makeFirstResponder(tv)
        resizeTextView()
    }

    private func resizeTextView() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let font = tv.font ?? textFont(size: 14)
        tv.setFrameSize(CGSize(width: max(used.width + 2, font.pointSize), height: max(used.height, font.pointSize * 1.25)))
        needsDisplay = true
    }

    /// Turn the open text box into a shape. Safe to call when none is open.
    func commitText() {
        guard let tv = textView else { return }
        let text = tv.string
        tv.removeFromSuperview()
        textView = nil
        push(.text(pos: textOrigin, text: text, color: color, size: Metrics.textSize(width)))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancelText() {
        textView?.removeFromSuperview()
        textView = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        mouse = p
        if let c = paletteAt {
            if let picked = paletteHit(p, centre: c) { setColor(picked) }
            paletteAt = nil
            needsDisplay = true
            return
        }
        if let i = ToolbarLayout.hit(toolbarCentres, p) {
            press(ToolbarButton.all[i], at: p)
            return
        }
        let wasEditing = textView.map { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        commitText()
        let pi = toImage(p)
        if let sv = selectionInView, let sel = selection {
            if let h = sv.hitHandle(p, radius: Self.handleHit) {
                drag = .resizing(handle: h, start: pi, orig: sel)
            } else if let tool {
                switch tool {
                case .text:
                    // A click while text was open only finishes that text.
                    if !wasEditing { beginText(at: p) }
                case .counter:
                    push(.new(.counter, at: pi, color: color, width: width, counter: shapes.filter(\.isCounter).count + 1))
                default:
                    current = .new(tool, at: pi, color: color, width: width, counter: 0)
                    drag = .drawing
                }
            } else if sv.contains(p) {
                drag = .moving(start: pi, orig: sel)
            } else {
                startSelecting(at: pi)
            }
        } else {
            startSelecting(at: pi)
        }
        updateCursor()
        needsDisplay = true
    }

    private func startSelecting(at pi: CGPoint) {
        host?.editorWillSelect(self)
        selection = nil
        drag = .selecting(start: pi)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        mouse = p
        let pi = toImage(p)
        switch drag {
        case .selecting(let start):
            selection = CGRect(corner: start, pi).clamped(to: imageBounds)
        case .moving(let start, let orig):
            selection = orig.offsetBy(dx: pi.x - start.x, dy: pi.y - start.y).kept(inside: imageBounds)
        case .resizing(let h, let start, let orig):
            selection = orig.resized(h, dx: pi.x - start.x, dy: pi.y - start.y).clamped(to: imageBounds)
        case .drawing:
            if var cur = current {
                var target = pi
                if event.modifierFlags.contains(.shift), let a = cur.anchor {
                    target = cur.isSegment ? snap45(a, pi) : snapSquare(a, pi)
                }
                cur.extend(to: target)
                current = cur
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        var accept = false
        switch finished {
        case .selecting:
            if let s = selection, s.isTiny { selection = nil }
            accept = options.acceptOnSelect && selection != nil
        case .drawing:
            if let c = current { push(c) }
            current = nil
        default:
            break
        }
        updateCursor()
        needsDisplay = true
        if accept { host?.editor(self, finish: .accept) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let w = window, !w.isKeyWindow {
            w.makeKey()
            if textView == nil { w.makeFirstResponder(self) }
        }
        mouse = point(event)
        hover = ToolbarLayout.hit(toolbarCentres, mouse)
        updateCursor()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        commitText()
        let p = point(event)
        paletteAt = paletteAt == nil ? p : nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        scrollAccumulator += d
        guard abs(scrollAccumulator) >= 1 else { return }
        let steps = scrollAccumulator.rounded(.towardZero)
        scrollAccumulator -= steps
        width = min(max(width + steps, 1), 40)
        widthHintUntil = Date().addingTimeInterval(0.9)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in self?.needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        cursor().set()
    }

    private func cursor() -> NSCursor {
        switch drag {
        case .resizing(let h, _, _): return resizeCursor(h)
        case .moving: return .closedHand
        case .selecting, .drawing: return .crosshair
        case .none: break
        }
        if paletteAt != nil || hover != nil { return .arrow }
        if let sv = selectionInView {
            if let h = sv.hitHandle(mouse, radius: Self.handleHit) { return resizeCursor(h) }
            if tool == .text { return .iBeam }
            if tool == nil && sv.contains(mouse) { return .openHand }
        }
        return .crosshair
    }

    private func resizeCursor(_ h: Handle) -> NSCursor {
        switch h {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        // AppKit has no public diagonal resize cursors before macOS 15.
        default: return .crosshair
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            switch chars {
            case "c": host?.editor(self, finish: .copy)
            case "s": host?.editor(self, finish: .save)
            case "p": host?.editor(self, finish: .pin)
            case "z": flags.contains(.shift) ? redo() : undo()
            case "y": redo()
            case "a": selectAll()
            default: super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 53: // Escape
            if paletteAt != nil {
                paletteAt = nil
                needsDisplay = true
            } else {
                host?.editorCancel(self)
            }
        case 36, 76: // Return, Enter
            host?.editor(self, finish: .accept)
        case 123, 124, 125, 126:
            nudge(event.keyCode, resize: flags.contains(.shift))
        default:
            if let c = chars.first, let t = Tool.forKey(c) { selectTool(t) }
        }
        updateCursor()
    }

    private func nudge(_ code: UInt16, resize: Bool) {
        guard let s = selection else { return }
        let (dx, dy): (CGFloat, CGFloat) = switch code {
        case 123: (-1, 0)
        case 124: (1, 0)
        case 126: (0, -1)
        default: (0, 1)
        }
        selection = resize ? s.resized(.se, dx: dx, dy: dy).clamped(to: imageBounds)
            : s.offsetBy(dx: dx, dy: dy).kept(inside: imageBounds)
        needsDisplay = true
    }

    // MARK: - Toolbar and palette

    private func press(_ b: ToolbarButton, at p: CGPoint) {
        switch b {
        case .tool(let t): selectTool(t)
        case .color: paletteAt = p
        case .undo: undo()
        case .redo: redo()
        case .pin: host?.editor(self, finish: .pin); return
        case .copy: host?.editor(self, finish: .copy); return
        case .save: host?.editor(self, finish: .save); return
        case .close: host?.editorCancel(self); return
        }
        needsDisplay = true
    }

    private func setColor(_ c: RGBA) {
        color = c
        textView?.textColor = c.nsColor
        textView?.insertionPointColor = c.nsColor
    }

    private func swatchPosition(_ centre: CGPoint, _ i: Int, _ n: Int) -> CGPoint {
        let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(max(n, 1))
        return CGPoint(x: centre.x + Self.paletteRing * cos(a), y: centre.y + Self.paletteRing * sin(a))
    }

    private func paletteHit(_ p: CGPoint, centre: CGPoint) -> RGBA? {
        let pal = config.paletteColors
        for (i, c) in pal.enumerated() {
            let s = swatchPosition(centre, i, pal.count)
            if hypot(s.x - p.x, s.y - p.y) <= Self.swatch + 2 { return c }
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sv = selectionInView

        // Dim everything outside the selection.
        ctx.saveGState()
        ctx.addRect(bounds)
        if let sv { ctx.addRect(sv) }
        ctx.setFillColor(CGColor(gray: 0, alpha: config.dimOpacity))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // The shape being drawn, in image space, clipped to the selection.
        if let cur = current {
            ctx.saveGState()
            if let sv { ctx.clip(to: sv) }
            ctx.scaleBy(x: 1 / k, y: 1 / k)
            render(cur, in: ctx, base: base)
            ctx.restoreGState()
        }
        if let tv = textView {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(tv.frame.insetBy(dx: -4, dy: -2))
            ctx.restoreGState()
        }

        if let sv, let sel = selection { drawSelection(ctx, sv, sel) }

        let centres = toolbarCentres
        for (i, c) in centres.enumerated() {
            let b = ToolbarButton.all[i]
            let active: Bool = if case .tool(let t) = b { t == tool } else { false }
            drawButton(ctx, b, at: c, active: active, hovered: hover == i)
        }
        if let i = hover, case .none = drag, i < centres.count {
            drawTooltip(ToolbarButton.all[i].label, at: centres[i])
        }

        let selecting: Bool = switch drag {
        case .selecting, .resizing: true
        default: false
        }
        if selection == nil && config.showHelp && !selecting { drawHelp() }
        if config.showMagnifier && (selection == nil || selecting) { drawMagnifier(ctx) }
        if let until = widthHintUntil, Date() < until { drawWidthHint(ctx) }
        if let c = paletteAt { drawPalette(ctx, centre: c) }
    }

    @discardableResult
    private func labelBox(_ text: String, at p: CGPoint, size: CGFloat = 12, measureOnly: Bool = false) -> CGSize {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let ts = s.boundingRect(with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin]).size
        let box = CGSize(width: ceil(ts.width) + 14, height: ceil(ts.height) + 8)
        if measureOnly { return box }
        let r = CGRect(origin: p, size: box)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(with: CGRect(x: p.x + 7, y: p.y + 4, width: ts.width + 1, height: ts.height),
               options: [.usesLineFragmentOrigin])
        return box
    }

    private func drawSelection(_ ctx: CGContext, _ sv: CGRect, _ sel: CGRect) {
        ctx.setStrokeColor(RGBA.accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(sv)
        let quiet = tool != nil
        for h in Handle.allCases {
            let c = sv.position(of: h)
            let r: CGFloat = quiet ? 3 : 4.5
            let dot = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: dot)
            ctx.strokeEllipse(in: dot)
        }
        let text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let size = labelBox(text, at: .zero, measureOnly: true)
        let y = sv.minY - size.height - 6 >= 0 ? sv.minY - size.height - 6 : sv.minY + 6
        labelBox(text, at: CGPoint(x: sv.minX, y: y))
    }

    private func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        let key = name + color.description
        if let img = symbolCache[key] { return img }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        symbolCache[key] = img
        return img
    }

    private func drawButton(_ ctx: CGContext, _ b: ToolbarButton, at c: CGPoint, active: Bool, hovered: Bool) {
        let r = ToolbarLayout.radius
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(active ? RGBA.accent.cgColor : (hovered ? CGColor(gray: 0.92, alpha: 1) : .white))
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        if b == .color {
            let sw = disc.insetBy(dx: 7, dy: 7)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: sw)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.3))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: sw)
            return
        }
        let fg = active ? NSColor.white : NSColor(white: 0.2, alpha: 1)
        guard let img = symbolImage(b.symbol, color: fg) else { return }
        let s = img.size
        img.draw(in: CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawTooltip(_ text: String, at c: CGPoint) {
        let size = labelBox(text, at: .zero, measureOnly: true)
        let x = min(max(4, c.x - size.width / 2), max(4, bounds.width - size.width - 4))
        var y = c.y + ToolbarLayout.radius + 8
        if y + size.height > bounds.height { y = c.y - ToolbarLayout.radius - 8 - size.height }
        labelBox(text, at: CGPoint(x: x, y: y))
    }

    private func drawHelp() {
        let text = """
        Drag to select an area
        Return / ⌘C  copy      ⌘S  save      ⌘P  pin
        Right-click  colour       Scroll  thickness      Esc  quit
        P L A R C M T B N  tools      ⌘Z / ⇧⌘Z  undo / redo
        Shift  constrain shapes      Arrows  nudge (Shift: resize)
        """
        let size = labelBox(text, at: .zero, size: 14, measureOnly: true)
        labelBox(text, at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), size: 14)
    }

    private func drawMagnifier(_ ctx: CGContext) {
        guard bounds.contains(mouse) else { return }
        let size: CGFloat = 128, zoom: CGFloat = 8
        var x = mouse.x + 24, y = mouse.y + 24
        if x + size > bounds.width { x = mouse.x - 24 - size }
        if y + size + 24 > bounds.height { y = mouse.y - 24 - size - 24 }
        let lens = CGRect(x: x, y: y, width: size, height: size)
        let ix = floor(mouse.x * k), iy = floor(mouse.y * k)
        let half = size / zoom / 2
        // The pixels shown, which may hang off the image near its edges.
        let want = CGRect(x: ix + 0.5 - half, y: iy + 0.5 - half, width: size / zoom, height: size / zoom)
        let have = want.integral.clamped(to: imageBounds)

        ctx.saveGState()
        let clip = CGPath(roundedRect: lens, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(lens)
        if !have.isTiny, let crop = base.cropping(to: have) {
            let dest = CGRect(x: lens.minX + (have.minX - want.minX) * zoom, y: lens.minY + (have.minY - want.minY) * zoom,
                              width: have.width * zoom, height: have.height * zoom)
            drawImage(ctx, crop, in: dest, interpolation: .none)
        }
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: lens.midX - zoom / 2, y: lens.midY - zoom / 2, width: zoom, height: zoom))
        ctx.setStrokeColor(RGBA.accent.cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(clip)
        ctx.strokePath()
        labelBox("\(Int(ix)), \(Int(iy))", at: CGPoint(x: x, y: y + size + 4), size: 11)
    }

    private func drawWidthHint(_ ctx: CGContext) {
        let d = max(width / k, 2)
        let r = CGRect(x: mouse.x - d / 2, y: mouse.y - d / 2, width: d, height: d)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: r)
        labelBox("\(Int(width)) px", at: CGPoint(x: mouse.x + d / 2 + 8, y: mouse.y - 10), size: 11)
    }

    private func drawPalette(_ ctx: CGContext, centre c: CGPoint) {
        let outer = Self.paletteRing + Self.swatch + 8
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.55))
        ctx.fillEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        let pal = config.paletteColors
        for (i, col) in pal.enumerated() {
            let p = swatchPosition(c, i, pal.count)
            let hovered = hypot(p.x - mouse.x, p.y - mouse.y) <= Self.swatch + 2
            let r = hovered ? Self.swatch + 3 : Self.swatch
            let dot = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(col.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(col == color ? 3 : 1.5)
            ctx.strokeEllipse(in: dot)
        }
        let mid = CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: mid)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: mid)
    }
}

extension EditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        resizeTextView()
    }
}
