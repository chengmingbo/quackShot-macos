import AppKit
import QuackShotCore

/// A capture floating above other windows. Drag to move, scroll to zoom,
/// ⌥-scroll for opacity, double-click or Esc to close, right-click for more.
final class PinWindow: NSPanel {
    @MainActor private static var open: [PinWindow] = []
    /// Called when the last pin closes (one-shot CLI mode exits then).
    @MainActor static var onAllClosed: (() -> Void)?
    @MainActor static var count: Int { open.count }

    private let image: CGImage
    private let pixelsPerPoint: CGFloat
    private var zoom: CGFloat = 1

    @MainActor
    static func open(_ image: CGImage, frame: CGRect?) {
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2
        let size = frame?.size ?? CGSize(width: CGFloat(image.width) / screenScale, height: CGFloat(image.height) / screenScale)
        let origin = frame?.origin ?? CGPoint(x: 120, y: 120)
        let pin = PinWindow(image: image, frame: CGRect(origin: origin, size: size))
        open.append(pin)
        pin.orderFrontRegardless()
        pin.makeKey()
    }

    @MainActor
    private init(image: CGImage, frame: CGRect) {
        self.image = image
        self.pixelsPerPoint = CGFloat(image.width) / max(frame.width, 1)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = true
        contentAspectRatio = frame.size
        contentView = PinView(frame: CGRect(origin: .zero, size: frame.size), image: image)
    }

    override var canBecomeKey: Bool { true }

    @MainActor
    fileprivate func setZoom(_ z: CGFloat) {
        zoom = min(max(z, 0.1), 8)
        let w = CGFloat(image.width) / pixelsPerPoint * zoom
        let h = CGFloat(image.height) / pixelsPerPoint * zoom
        // Keep the top-left corner where it is.
        let top = frame.maxY
        setFrame(CGRect(x: frame.minX, y: top - h, width: w, height: h), display: true, animate: false)
    }

    @MainActor
    fileprivate func zoomBy(_ factor: CGFloat) {
        let current = frame.width * pixelsPerPoint / CGFloat(image.width)
        zoom = current
        setZoom(current * factor)
    }

    override func close() {
        super.close()
        MainActor.assumeIsolated {
            PinWindow.open.removeAll { $0 === self }
            if PinWindow.open.isEmpty { PinWindow.onAllClosed?() }
        }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, _): close()
        case (_, "c") where cmd: copy(nil)
        case (_, "s") where cmd: saveAs(nil)
        case (_, "w") where cmd: close()
        case (_, "0") where cmd: actualSize(nil)
        case (_, "=") where cmd, (_, "+") where cmd: MainActor.assumeIsolated { zoomBy(1.1) }
        case (_, "-") where cmd: MainActor.assumeIsolated { zoomBy(1 / 1.1) }
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated { Output.copy(image, pointSize: CGSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint)) }
    }

    @objc func saveAs(_ sender: Any?) {
        MainActor.assumeIsolated {
            let cfg = Config.load()
            guard let url = Output.runSavePanel(config: cfg) else { return }
            do {
                try writeImage(image, to: url)
                Output.notify(config: cfg, title: "Screenshot saved", body: url.lastPathComponent, file: url)
            } catch {
                Output.reportError("\(error)", config: cfg)
            }
        }
    }

    @objc func actualSize(_ sender: Any?) {
        MainActor.assumeIsolated { setZoom(1) }
    }

    @objc func closePin(_ sender: Any?) { close() }
}

private final class PinView: NSView {
    let image: CGImage

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = bounds.width / CGFloat(image.width)
        drawImage(ctx, image, in: bounds, interpolation: z >= 2 ? .none : .high)
        ctx.setStrokeColor(RGBA.accent.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    private var pin: PinWindow? { window as? PinWindow }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pin?.close()
            return
        }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        guard dy != 0, let pin else { return }
        if event.modifierFlags.contains(.option) {
            pin.alphaValue = min(max(pin.alphaValue + dy * 0.05, 0.2), 1)
        } else {
            pin.zoomBy(pow(1.05, dy))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(PinWindow.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Save As…", action: #selector(PinWindow.saveAs(_:)), keyEquivalent: "s")
        m.addItem(withTitle: "Actual Size", action: #selector(PinWindow.actualSize(_:)), keyEquivalent: "0")
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(PinWindow.closePin(_:)), keyEquivalent: "w")
        for item in m.items { item.target = pin }
        return m
    }
}
