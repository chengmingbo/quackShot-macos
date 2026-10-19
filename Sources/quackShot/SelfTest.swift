import AppKit
import SwiftUI
import QuackShotCore

/// `quackShot selftest DIR`: drives the editor in an offscreen window with
/// synthetic events and writes renders to DIR. Needs no Screen Recording
/// permission and never shows anything on screen.
@MainActor
enum SelfTest {
    private final class Host: EditorHost {
        var finished: EditorAction?
        var cancelled = false
        var willSelect = 0
        func editorWillSelect(_ editor: EditorView) { willSelect += 1 }
        func editor(_ editor: EditorView, finish action: EditorAction) { finished = action }
        func editorCancel(_ editor: EditorView) { cancelled = true }
    }

    static func run(outputDirectory: String) -> Int32 {
        let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures.append(what) }
        }

        let size = CGSize(width: 800, height: 500)
        let base = backdrop(width: 1600, height: 1000) // a 2× "Retina" capture
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        let bounds = CGRect(origin: .zero, size: size)
        let container = NSView(frame: bounds)
        let baseView = BaseImageView(frame: bounds)
        var cfg = Config()
        cfg.notifications = false
        let editor = EditorView(frame: bounds, base: base, baseView: baseView, config: cfg, options: Options())
        let host = Host()
        editor.host = host
        container.addSubview(baseView)
        container.addSubview(editor)
        window.contentView = container
        window.makeFirstResponder(editor)

        func ev(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: size.height - p.y), modifierFlags: flags,
                               timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: clicks, pressure: 1)!
        }
        func drag(_ a: CGPoint, _ b: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            editor.mouseDown(with: ev(.leftMouseDown, a, flags))
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            editor.mouseDragged(with: ev(.leftMouseDragged, mid, flags))
            editor.mouseDragged(with: ev(.leftMouseDragged, b, flags))
            editor.mouseUp(with: ev(.leftMouseUp, b, flags))
        }
        func click(_ p: CGPoint) {
            editor.mouseDown(with: ev(.leftMouseDown, p))
            editor.mouseUp(with: ev(.leftMouseUp, p))
        }
        func move(_ p: CGPoint) { editor.mouseMoved(with: ev(.mouseMoved, p)) }
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], to responder: NSResponder? = nil) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            (responder ?? editor).keyDown(with: e)
        }
        func snap(_ name: String) {
            guard let rep = container.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            container.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }

        move(CGPoint(x: 600, y: 300))
        snap("1-start")
        drag(CGPoint(x: 100, y: 75), CGPoint(x: 350, y: 225))
        check(editor.selection == CGRect(x: 200, y: 150, width: 500, height: 300), "drag selects in image pixels (2×)")
        check(host.willSelect == 1, "host told about new selection")
        snap("2-selection")

        key("r", 15)
        check(editor.tool == .rect, "R picks rectangle")
        drag(CGPoint(x: 120, y: 95), CGPoint(x: 200, y: 160))
        key("a", 0)
        drag(CGPoint(x: 330, y: 210), CGPoint(x: 260, y: 120))
        key("m", 46)
        drag(CGPoint(x: 115, y: 190), CGPoint(x: 220, y: 192))
        key("b", 11)
        drag(CGPoint(x: 230, y: 85), CGPoint(x: 300, y: 115))
        key("n", 45)
        click(CGPoint(x: 320, y: 90))
        click(CGPoint(x: 335, y: 105))
        key("e", 14) // no tool: ignored
        key("t", 17)
        click(CGPoint(x: 230, y: 160))
        if let tv = editor.subviews.compactMap({ $0 as? AnnotationTextView }).first {
            tv.insertText("Quack 你好", replacementRange: NSRange(location: NSNotFound, length: 0))
            snap("3-typing")
            key("\u{1b}", 53, to: tv)
        }
        check(editor.subviews.allSatisfy { !($0 is AnnotationTextView) }, "Esc commits text box")
        check(editor.shapes.count == 7, "seven shapes committed (got \(editor.shapes.count))")
        if case .text(_, let t, _, _)? = editor.shapes.last { check(t == "Quack 你好", "text shape keeps CJK text") }

        key("z", 6, .command)
        check(editor.shapes.count == 6, "⌘Z undoes")
        key("z", 6, [.command, .shift])
        check(editor.shapes.count == 7, "⇧⌘Z redoes")

        // Shift constrains a line to 45°.
        key("l", 37)
        drag(CGPoint(x: 120, y: 215), CGPoint(x: 160, y: 219), .shift)
        if case .line(let a, let b, _, _)? = editor.shapes.last { check(abs(a.y - b.y) < 0.01, "Shift snaps line horizontal") }
        key("l", 37)
        check(editor.tool == nil, "pressing the tool again returns to move mode")

        // Hover a toolbar button for its tooltip.
        let centres = ToolbarLayout.centres(selection: editor.selection!.scaled(0.5), screen: bounds)
        move(centres[2])
        snap("4-annotated")

        // Scroll changes thickness.
        let before = editor.width
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0),
           let e = NSEvent(cgEvent: cg) {
            editor.scrollWheel(with: e)
        }
        check(editor.width == before + 2, "scroll up thickens (\(before) → \(editor.width))")

        editor.rightMouseDown(with: ev(.rightMouseDown, CGPoint(x: 600, y: 300)))
        snap("5-palette")
        // Top swatch sits straight above the centre.
        click(CGPoint(x: 600, y: 300 - 74))
        check(editor.color == cfg.paletteColors[0], "palette click picks colour")

        // Move the selection by dragging inside it, then nudge.
        drag(CGPoint(x: 300, y: 200), CGPoint(x: 310, y: 205))
        check(editor.selection?.origin == CGPoint(x: 220, y: 160), "drag inside moves selection")
        key("", 124)
        check(editor.selection?.origin.x == 221, "→ nudges by one pixel")

        key("\r", 36)
        check(host.finished == .accept, "Return accepts")
        key("c", 8, .command)
        check(host.finished == .copy, "⌘C copies")
        if let img = editor.exportImage() {
            check(img.width == 500 && img.height == 300, "export is selection size (\(img.width)×\(img.height))")
            try? writeImage(img, to: out.appendingPathComponent("6-export.png"))
        } else {
            check(false, "export produced an image")
        }
        key("\u{1b}", 53)
        check(host.cancelled, "Esc cancels")

        // Second editor-level scenario: help text and select-all.
        editor.clearSelection()
        snap("7-cleared")
        key("a", 0, .command)
        check(editor.selection == editor.imageBounds, "⌘A selects the whole screen")

        renderPermissions(to: out.appendingPathComponent("8-permissions.png"))
        renderSettings(to: out.appendingPathComponent("9-settings.png"))

        print(failures.isEmpty ? "selftest: all passed" : "selftest: \(failures.count) failed")
        return failures.isEmpty ? 0 : 1
    }

    private static func renderPermissions(to url: URL) {
        let model = PermissionModel()
        model.visitedSettings = true
        let view = NSHostingView(rootView: PermissionsView(model: model, hotkey: HotKey.default.display) {})
        render(view, to: url)
    }

    private static func renderSettings(to url: URL) {
        let view = NSHostingView(rootView: SettingsView(model: SettingsModel()) {})
        render(view, to: url)
    }

    private static func render(_ view: NSView, to url: URL) {
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        let w = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A stand-in desktop: gradient, title text and colour blocks.
    private static func backdrop(width: Int, height: Int) -> CGImage {
        let ctx = makeContext(width: width, height: height)!
        let colors = [RGBA(0.15, 0.35, 0.6).cgColor, RGBA(0.55, 0.2, 0.45).cgColor] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        for i in 0..<12 {
            ctx.setFillColor(RGBA(CGFloat(i % 3) / 2, CGFloat((i / 3) % 2), 0.3 + 0.05 * CGFloat(i)).cgColor)
            ctx.fill(CGRect(x: 120 + i * 115, y: 760, width: 95, height: 95))
        }
        withAppKitContext(ctx) {
            NSAttributedString(string: "Backdrop for quackShot selftest", attributes: textAttributes(size: 64, color: RGBA(1, 1, 1)))
                .draw(at: CGPoint(x: 260, y: 380))
            NSAttributedString(string: "The quick brown fox jumps over the lazy dog 0123456789",
                               attributes: textAttributes(size: 30, color: RGBA(1, 1, 1))).draw(at: CGPoint(x: 260, y: 480))
        }
        return ctx.makeImage()!
    }
}
