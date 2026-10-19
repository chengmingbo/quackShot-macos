// Renders Resources/AppIcon.png (1024²) — the same duck-in-selection design
// as the Linux SVG icon, on Apple's 824-pt icon grid.
import AppKit

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// SVG space (0…256, tile 16…240, y down) → icon grid (tile 100…924).
let k: CGFloat = 824 / 224
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
ctx.translateBy(x: 100 - 16 * k, y: 100 - 16 * k)
ctx.scaleBy(x: k, y: k)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

// Tile with a soft drop shadow.
let tile = CGPath(roundedRect: CGRect(x: 16, y: 16, width: 224, height: 224), cornerWidth: 50, cornerHeight: 50, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(tile); ctx.setFillColor(rgb(0x2a3350)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x3b4a6b), rgb(0x232b40)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 16), end: CGPoint(x: 0, y: 240), options: [])
ctx.restoreGState()

// Duck.
ctx.setFillColor(rgb(0xffcc00))
ctx.fillEllipse(in: CGRect(x: 62, y: 126, width: 140, height: 88))
ctx.fillEllipse(in: CGRect(x: 64, y: 64, width: 80, height: 80))
ctx.setFillColor(rgb(0xff8c1a))
ctx.move(to: CGPoint(x: 136, y: 104)); ctx.addLine(to: CGPoint(x: 182, y: 96))
ctx.addQuadCurve(to: CGPoint(x: 178, y: 118), control: CGPoint(x: 190, y: 110))
ctx.addLine(to: CGPoint(x: 138, y: 118)); ctx.closePath(); ctx.fillPath()
ctx.setFillColor(rgb(0x232b40)); ctx.fillEllipse(in: CGRect(x: 101, y: 87, width: 14, height: 14))
ctx.setFillColor(.white); ctx.fillEllipse(in: CGRect(x: 107.5, y: 89.5, width: 5, height: 5))
ctx.setFillColor(rgb(0xf2b800))
ctx.move(to: CGPoint(x: 120, y: 160)); ctx.addQuadCurve(to: CGPoint(x: 168, y: 172), control: CGPoint(x: 148, y: 150))
ctx.addQuadCurve(to: CGPoint(x: 120, y: 176), control: CGPoint(x: 144, y: 186)); ctx.closePath(); ctx.fillPath()

// Selection corners.
ctx.setStrokeColor(rgb(0xff8c1a)); ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for pts in [[(44, 84), (44, 44), (84, 44)], [(172, 44), (212, 44), (212, 84)],
            [(212, 172), (212, 212), (172, 212)], [(84, 212), (44, 212), (44, 172)]] {
    ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.strokePath()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
