import CoreGraphics
import Foundation
import Testing
@testable import QuackShotCore

// MARK: - Geometry

@Test func rectFromCornersNormalises() {
    #expect(CGRect(corner: CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 2)) == CGRect(x: 4, y: 2, width: 6, height: 18))
}

@Test func resizeFlipsPastOppositeEdge() {
    let r = CGRect(x: 10, y: 10, width: 20, height: 20)
    #expect(r.resized(.e, dx: -30, dy: 0) == CGRect(x: 0, y: 10, width: 10, height: 20))
    #expect(r.resized(.nw, dx: 5, dy: 5) == CGRect(x: 15, y: 15, width: 15, height: 15))
    #expect(r.resized(.s, dx: 0, dy: 7) == CGRect(x: 10, y: 10, width: 20, height: 27))
}

@Test func hitHandlePrefersCornersThenEdges() {
    let r = CGRect(x: 100, y: 100, width: 200, height: 100)
    #expect(r.hitHandle(CGPoint(x: 102, y: 98), radius: 6) == .nw)
    #expect(r.hitHandle(CGPoint(x: 150, y: 103), radius: 6) == .n)
    #expect(r.hitHandle(CGPoint(x: 299, y: 150), radius: 6) == .e)
    #expect(r.hitHandle(CGPoint(x: 200, y: 150), radius: 6) == nil)
}

@Test func clampAndKeepInside() {
    let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
    let r = CGRect(x: -10, y: 90, width: 30, height: 30)
    #expect(r.clamped(to: screen) == CGRect(x: 0, y: 90, width: 20, height: 10))
    #expect(r.kept(inside: screen) == CGRect(x: 0, y: 70, width: 30, height: 30))
    #expect(CGRect(x: 200, y: 200, width: 5, height: 5).clamped(to: screen).isTiny)
    #expect(CGRect(x: 1.4, y: 2.6, width: 10.2, height: 3.3).pixelAligned == CGRect(x: 1, y: 3, width: 11, height: 3))
}

@Test func snapping() {
    let p = snap45(.zero, CGPoint(x: 10, y: 1))
    #expect(abs(p.y) < 1e-9)
    #expect(snapSquare(.zero, CGPoint(x: 5, y: -2)) == CGPoint(x: 5, y: -5))
}

// MARK: - Colours and shapes

@Test func colourParsing() {
    #expect(RGBA(hex: "#ff3b30")?.hex == "#ff3b30")
    #expect(RGBA(hex: "#fff")?.hex == "#ffffff")
    #expect(abs((RGBA(hex: "#00000080")?.a ?? 0) - 0.502) < 0.01)
    #expect(RGBA(hex: "red") == nil)
    #expect(RGBA(hex: "#12345") == nil)
    #expect(RGBA(hex: "#gggggg") == nil)
}

@Test func degenerateShapes() {
    let c = RGBA(0, 0, 0)
    #expect(Shape.line(a: .zero, b: CGPoint(x: 0.5, y: 0), color: c, width: 2).isDegenerate)
    #expect(!Shape.line(a: .zero, b: CGPoint(x: 9, y: 0), color: c, width: 2).isDegenerate)
    #expect(Shape.text(pos: .zero, text: " \n", color: c, size: 12).isDegenerate)
}

@Test func arrowHeadPointsBackFromTip() {
    let (shaft, l, r) = arrowHead(.zero, CGPoint(x: 100, y: 0), width: 2)
    #expect(shaft.x < 100 && shaft.x > 80)
    #expect(l.x < 100 && abs(l.y + r.y) < 1e-9 && l.y > 0)
}

private func solid(_ w: Int, _ h: Int, _ c: RGBA) -> CGImage {
    let ctx = makeContext(width: w, height: h)!
    ctx.setFillColor(c.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// RGBA bytes of pixel (x, y), top-left origin.
private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let ctx = makeContext(width: img.width, height: img.height)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * img.height)
    // Bitmap memory is top-row first.
    let i = y * ctx.bytesPerRow + x * 4
    return [p[i], p[i + 1], p[i + 2], p[i + 3]]
}

@Test func exportCropsAndDrawsTopLeftOrigin() {
    let base = solid(100, 80, RGBA(1, 1, 1))
    let shapes: [Shape] = [.rect(a: CGPoint(x: 20, y: 20), b: CGPoint(x: 60, y: 30), color: RGBA(1, 0, 0), width: 4)]
    let out = export(base: base, shapes: shapes, selection: CGRect(x: 10, y: 10, width: 60, height: 60))!
    #expect(out.width == 60 && out.height == 60)
    // Top edge of the rect is at image y=20 → crop y=10, near the top.
    #expect(pixel(out, 30, 10) == [255, 0, 0, 255])
    #expect(pixel(out, 30, 50) == [255, 255, 255, 255])
}

@Test func exportKeepsBaseOrientation() {
    // Top half red, bottom half blue in top-left terms.
    let ctx = makeContext(width: 20, height: 20)!
    ctx.setFillColor(RGBA(0, 0, 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10)) // bottom (CG origin)
    ctx.setFillColor(RGBA(1, 0, 0).cgColor); ctx.fill(CGRect(x: 0, y: 10, width: 20, height: 10)) // top
    let base = ctx.makeImage()!
    let out = export(base: base, shapes: [], selection: CGRect(x: 0, y: 0, width: 20, height: 5))!
    #expect(pixel(out, 5, 2) == [255, 0, 0, 255])
}

@Test func pixelateMakesUniformBlocks() {
    let ctx = makeContext(width: 40, height: 40)!
    for y in 0..<40 { for x in 0..<40 {
        let v: CGFloat = (x + y) % 2 == 0 ? 0 : 1
        ctx.setFillColor(RGBA(v, v, v).cgColor)
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    } }
    let base = ctx.makeImage()!
    let out = export(base: base, shapes: [.pixelate(a: .zero, b: CGPoint(x: 40, y: 40), block: 10)],
                     selection: CGRect(x: 0, y: 0, width: 40, height: 40))!
    let a = pixel(out, 1, 1), b = pixel(out, 2, 1)
    #expect(a == b)
    #expect(a[0] > 60 && a[0] < 200)
}

@Test func counterAndTextRender() {
    let base = solid(80, 80, RGBA(1, 1, 1))
    let out = export(base: base, shapes: [
        .counter(center: CGPoint(x: 40, y: 40), n: 7, color: RGBA(0, 0, 1), radius: 16),
        .text(pos: CGPoint(x: 2, y: 2), text: "Hi 你好", color: RGBA(0, 0, 1), size: 14),
    ], selection: CGRect(x: 0, y: 0, width: 80, height: 80))!
    #expect(pixel(out, 40, 26) == [0, 0, 255, 255])
    // Some text ink lands in the top-left corner.
    let inked = (0..<20).contains { x in (2..<18).contains { y in pixel(out, x, y)[0] < 128 } }
    #expect(inked)
}

// MARK: - Toolbar

@Test func toolbarGoesBelowThenAboveThenInside() {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    #expect(ToolbarLayout.centres(selection: CGRect(x: 500, y: 100, width: 600, height: 300), screen: screen).allSatisfy { $0.y > 400 })
    #expect(ToolbarLayout.centres(selection: CGRect(x: 500, y: 700, width: 600, height: 370), screen: screen).allSatisfy { $0.y < 700 })
    #expect(ToolbarLayout.centres(selection: screen, screen: screen).allSatisfy { $0.y > 900 && $0.y < 1080 })
}

@Test func toolbarWrapsAndHits() {
    let narrow = CGRect(x: 0, y: 0, width: 300, height: 800)
    let c = ToolbarLayout.centres(selection: CGRect(x: 0, y: 100, width: 50, height: 50), screen: narrow)
    #expect(c.allSatisfy { $0.x - ToolbarLayout.radius >= 0 && $0.x + ToolbarLayout.radius <= 300 })
    #expect(Set(c.map { Int($0.y) }).count > 1)
    #expect(ToolbarLayout.hit(c, c[3]) == 3)
    #expect(ToolbarLayout.hit(c, CGPoint(x: -100, y: -100)) == nil)
}

// MARK: - CLI

@Test func cliDefaultsAndAgent() throws {
    #expect(try parseCommand([]).get() == .agent)
    #expect(try parseCommand(["-psn_0_12345"]).get() == .agent)
    var o = Options(); o.clipboard = true
    #expect(try parseCommand(["-c"]).get() == .gui(o))
}

@Test func cliFullOptions() throws {
    guard case .full(let o) = try parseCommand(["full", "--delay=500", "-p", "/tmp/x.png", "-g", "100x50+10+20"]).get() else {
        Issue.record("expected full"); return
    }
    #expect(o.delayMs == 500)
    #expect(o.path == "/tmp/x.png")
    #expect(o.region == CGRect(x: 10, y: 20, width: 100, height: 50))
}

@Test func cliErrors() {
    for args in [["gui", "--region", "1x1+0+0"], ["full", "--pin"], ["-d"], ["-d", "soon"], ["bogus"], ["--nope"]] {
        if case .success = parseCommand(args) { Issue.record("expected failure for \(args)") }
    }
    #expect(parseRegion("10X20+3+4") == CGRect(x: 3, y: 4, width: 10, height: 20))
    #expect(parseRegion("0x20+3+4") == nil)
    #expect(parseRegion("10x20") == nil)
}

// MARK: - Config

@Test func configFallsBackOnBadValues() throws {
    let json = ##"{"width": 900, "color": "nope", "palette": ["#zzz"], "notifications": "yes"}"##
    let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(c.width == 40)
    #expect(c.color == Config().color)
    #expect(c.palette == Config().palette)
    #expect(c.notifications == true)
    #expect(c.hotkey == .default)
}

@Test func configRoundTripsAndNamesFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
    var c = Config()
    c.width = 7; c.hotkey = HotKey(keyCode: 0x00, command: true, option: true)
    c.save(to: dir.appendingPathComponent("c.json"))
    #expect(Config.load(from: dir.appendingPathComponent("c.json")) == c)
    c.filenamePattern = "shot_%Y"
    #expect(c.defaultFilename(date: Date(timeIntervalSince1970: 1_700_000_000)) == "shot_2023.png")
    #expect(HotKey.default.display == "⇧⌘2")

    let f = dir.appendingPathComponent("a.png")
    #expect(uniqueURL(f) == f)
    try Data("x".utf8).write(to: f)
    #expect(uniqueURL(f).lastPathComponent == "a-1.png")
    #expect(resolveTarget(dir.path, config: c).deletingLastPathComponent().path == dir.path)
    #expect(resolveTarget(dir.appendingPathComponent("b").path, config: c).pathExtension == "png")
    try FileManager.default.removeItem(at: dir)
}

@Test func writesFormatsByExtension() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
    let img = solid(10, 6, RGBA(0, 1, 0))
    for ext in ["png", "jpg", "tiff"] {
        let u = dir.appendingPathComponent("x.\(ext)")
        try writeImage(img, to: u)
        let back = loadImage(u)
        #expect(back?.width == 10 && back?.height == 6)
    }
    #expect(pngData(img)?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    try FileManager.default.removeItem(at: dir)
}
