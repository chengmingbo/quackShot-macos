import AppKit
import QuackShotCore

/// Borderless full-screen window that can take keyboard focus.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One capture from frozen screens to a finished action: an overlay
/// window per display, sharing one selection between them.
@MainActor
final class CaptureSession: EditorHost {
    private static var active: CaptureSession?

    private let options: Options
    private var config: Config
    private var windows: [OverlayWindow] = []
    private var editors: [EditorView] = []
    private let completion: (Int32) -> Void

    private init(options: Options, config: Config, completion: @escaping (Int32) -> Void) {
        self.options = options
        self.config = config
        self.completion = completion
    }

    static var isRunning: Bool { active != nil }

    /// Capture after `options.delayMs`, then open the editor. `completion`
    /// gets the exit status: 0 done, 1 cancelled, 2 failed.
    static func start(options: Options, onPermissionMissing: @escaping () -> Void, completion: @escaping (Int32) -> Void) {
        guard active == nil else { return }
        let session = CaptureSession(options: options, config: Config.load(), completion: completion)
        active = session
        Task { @MainActor in
            if options.delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(options.delayMs) * 1_000_000) }
            do {
                let shots = try await Capture.screens()
                session.open(shots)
            } catch CaptureError.permission {
                active = nil
                onPermissionMissing()
                completion(2)
            } catch {
                active = nil
                Output.reportError("\(error)", config: session.config)
                completion(2)
            }
        }
    }

    private func open(_ shots: [ScreenShot]) {
        for shot in shots {
            let frame = shot.screen.frame
            let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.acceptsMouseMovedEvents = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none

            let bounds = CGRect(origin: .zero, size: frame.size)
            let container = NSView(frame: bounds)
            let baseView = BaseImageView(frame: bounds)
            baseView.autoresizingMask = [.width, .height]
            let editor = EditorView(frame: bounds, base: shot.image, baseView: baseView, config: config, options: options)
            editor.autoresizingMask = [.width, .height]
            editor.host = self
            container.addSubview(baseView)
            container.addSubview(editor)
            w.contentView = container
            windows.append(w)
            editors.append(editor)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Start with the screen under the pointer focused.
        let mouse = NSEvent.mouseLocation
        let first = windows.firstIndex { $0.frame.contains(mouse) } ?? 0
        for (i, w) in windows.enumerated() where i != first { w.orderFrontRegardless() }
        windows[first].makeKeyAndOrderFront(nil)
        windows[first].makeFirstResponder(editors[first])
    }

    private func setVisible(_ visible: Bool) {
        for w in windows {
            if visible { w.orderFrontRegardless() } else { w.orderOut(nil) }
        }
        if visible, let key = editors.first(where: { $0.selection != nil }) ?? editors.first {
            NSApp.activate(ignoringOtherApps: true)
            key.window?.makeKeyAndOrderFront(nil)
            key.window?.makeFirstResponder(key)
        }
    }

    private func end(_ code: Int32, style editor: EditorView?) {
        if let editor {
            var cfg = Config.load()
            if cfg.color != editor.color.hex || cfg.width != Double(editor.width) {
                cfg.color = editor.color.hex
                cfg.width = Double(editor.width)
                cfg.save()
            }
        }
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        editors.removeAll()
        CaptureSession.active = nil
        completion(code)
    }

    // MARK: EditorHost

    func editorWillSelect(_ editor: EditorView) {
        for e in editors where e !== editor { e.clearSelection() }
    }

    func editorCancel(_ editor: EditorView) {
        end(1, style: editor)
    }

    func editor(_ editor: EditorView, finish action: EditorAction) {
        guard let image = editor.exportImage() else { return }
        let onScreen = editor.selectionOnScreen
        let pointSize = onScreen?.size
        setVisible(false)

        var failure: String?
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { failure = failure ?? "\(error)" }
        }
        func save(to url: URL) {
            attempt {
                try writeImage(image, to: url)
                let line = url.path + "\n"
                (options.raw ? FileHandle.standardError : FileHandle.standardOutput).write(Data(line.utf8))
                if config.copyOnSave { Output.copy(image, pointSize: pointSize) }
                Output.notify(config: config, title: "Screenshot saved", body: url.lastPathComponent, file: url)
            }
        }
        func copy() {
            Output.copy(image, pointSize: pointSize)
            Output.notify(config: config, title: "Screenshot copied", body: "The capture is on the clipboard.")
        }

        switch action {
        case .copy:
            copy()
        case .pin:
            PinWindow.open(image, frame: onScreen)
        case .save:
            let target: URL?
            if let p = options.path {
                target = resolveTarget(p, config: config)
            } else if config.saveWithoutDialog {
                target = defaultTarget(config)
            } else {
                target = Output.runSavePanel(config: config)
            }
            guard let target else {
                setVisible(true) // dialog cancelled: back to editing
                return
            }
            save(to: target)
        case .accept where !options.hasExplicitAction:
            copy()
        case .accept:
            if let p = options.path { save(to: resolveTarget(p, config: config)) }
            if options.clipboard { copy() }
            if options.raw { attempt { try Output.writeStdout(image) } }
            if options.pin { PinWindow.open(image, frame: onScreen) }
        }
        Output.playShutter(config: config)
        if let failure { Output.reportError(failure, config: config) }
        end(failure == nil ? 0 : 2, style: editor)
    }
}
