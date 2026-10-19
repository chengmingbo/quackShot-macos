import AppKit
import ScreenCaptureKit
import QuackShotCore

/// One display's frozen image.
struct ScreenShot {
    let screen: NSScreen
    /// Pixels of `screen`, top row first.
    let image: CGImage
}

enum CaptureError: Error, CustomStringConvertible {
    case permission
    case failed(String)

    var description: String {
        switch self {
        case .permission:
            return "quackShot needs Screen Recording permission (System Settings → Privacy & Security → Screen Recording)."
        case .failed(let s): return "screen capture failed: \(s)"
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum Capture {
    /// Capture every screen. `QUACKSHOT_FAKE_CAPTURE=/path/to/image` swaps in
    /// a file instead, which tests use to avoid needing permission.
    @MainActor
    static func screens() async throws -> [ScreenShot] {
        if let fake = ProcessInfo.processInfo.environment["QUACKSHOT_FAKE_CAPTURE"] {
            guard let img = loadImage(URL(fileURLWithPath: fake)) else { throw CaptureError.failed("cannot read \(fake)") }
            return NSScreen.screens.map { ScreenShot(screen: $0, image: fit(img, to: $0)) }
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Permissions.screenRecordingPreflight ? CaptureError.failed(error.localizedDescription) : CaptureError.permission
        }
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            do {
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                shots.append(ScreenShot(screen: screen, image: img))
            } catch {
                if (error as NSError).code == SCStreamError.userDeclined.rawValue { throw CaptureError.permission }
                throw CaptureError.failed(error.localizedDescription)
            }
        }
        if shots.isEmpty { throw CaptureError.failed("no displays found") }
        return shots
    }

    /// Scale `img` to the pixel size of `screen` (fake captures only).
    private static func fit(_ img: CGImage, to screen: NSScreen) -> CGImage {
        let w = Int(screen.frame.width * screen.backingScaleFactor)
        let h = Int(screen.frame.height * screen.backingScaleFactor)
        guard let ctx = makeContext(width: w, height: h) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// All screens stitched into one image in global coordinates (top-left
    /// of the union), at the highest backing scale. Returns the image and
    /// its scale in pixels per point.
    static func stitch(_ shots: [ScreenShot]) -> (CGImage, CGFloat)? {
        guard !shots.isEmpty else { return nil }
        let union = shots.map(\.screen.frame).reduce(CGRect.null) { $0.union($1) }
        let scale = shots.map(\.screen.backingScaleFactor).max() ?? 1
        guard let ctx = makeContext(width: Int(union.width * scale), height: Int(union.height * scale)) else { return nil }
        ctx.interpolationQuality = .high
        for s in shots {
            // Cocoa frames are bottom-left origin, as is the bitmap context.
            let f = s.screen.frame
            ctx.draw(s.image, in: CGRect(x: (f.minX - union.minX) * scale, y: (f.minY - union.minY) * scale,
                                         width: f.width * scale, height: f.height * scale))
        }
        guard let img = ctx.makeImage() else { return nil }
        return (img, scale)
    }
}
