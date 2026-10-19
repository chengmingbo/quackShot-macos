import AppKit
import UserNotifications
import QuackShotCore

/// Where a finished capture goes: the pasteboard, files, stdout,
/// notifications and the shutter sound.
@MainActor
enum Output {
    /// Put the image on the pasteboard as PNG plus an NSImage sized in
    /// points, so Retina captures paste at their on-screen size.
    static func copy(_ image: CGImage, pointSize: CGSize? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let size = pointSize ?? CGSize(width: image.width, height: image.height)
        let ns = NSImage(cgImage: image, size: size)
        pb.writeObjects([ns])
        if let png = pngData(image) { pb.setData(png, forType: .png) }
    }

    static func writeStdout(_ image: CGImage) throws {
        guard let png = pngData(image) else { throw CLIError("cannot encode PNG") }
        FileHandle.standardOutput.write(png)
    }

    /// Ask where to save. Returns nil when cancelled.
    static func runSavePanel(config: Config) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        try? FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true)
        panel.directoryURL = config.saveDirectory
        panel.nameFieldStringValue = config.defaultFilename()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func playShutter(config: Config) {
        guard config.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: path) {
            NSSound(contentsOfFile: path, byReference: true)?.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }

    static func notify(config: Config, title: String, body: String, file: URL? = nil) {
        guard config.notifications, Permissions.canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file {
            content.userInfo = ["file": file.path]
            if let att = try? UNNotificationAttachment(identifier: "shot", url: file, options: nil) {
                content.attachments = [att]
            }
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static func reportError(_ message: String, config: Config) {
        FileHandle.standardError.write(Data("quackShot: \(message)\n".utf8))
        notify(config: config, title: "quackShot failed", body: message)
    }
}

/// Click a "saved" notification to reveal the file in Finder.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["file"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
