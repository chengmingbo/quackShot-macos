import Foundation

/// A global keyboard shortcut. `keyCode` is a virtual key code
/// (kVK_* from Carbon), independent of keyboard layout.
public struct HotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(keyCode: UInt32, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode; self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    /// ⇧⌘2 — next to the system's ⇧⌘3/4/5 screenshot chords, and free by default.
    public static let `default` = HotKey(keyCode: 0x13, command: true, shift: true)

    public var hasModifier: Bool { command || option || control }

    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + HotKey.keyName(keyCode)
    }

    public static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
            0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
            0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
            0x1D: "0", 0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
            0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x31: "Space", 0x24: "↩",
        ]
        return names[code] ?? "key \(code)"
    }
}

/// Settings in `~/Library/Application Support/quackShot/config.json`. The keys
/// match the Linux version's config so the two can share documentation.
/// Missing or invalid values fall back to defaults.
public struct Config: Codable, Equatable, Sendable {
    public var saveDir: String = ""
    public var filenamePattern: String = "quackshot_%Y-%m-%d_%H-%M-%S"
    public var saveWithoutDialog: Bool = false
    public var copyOnSave: Bool = false
    public var notifications: Bool = true
    public var playSound: Bool = true
    public var color: String = "#ff3b30"
    public var width: Double = 4
    public var palette: [String] = [
        "#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7be", "#007aff",
        "#5856d6", "#af52de", "#ff2d55", "#ffffff", "#8e8e93", "#000000",
    ]
    public var dimOpacity: Double = 0.45
    public var showHelp: Bool = true
    public var showMagnifier: Bool = true
    public var hotkey: HotKey = .default
    /// Set once the first-launch permission guide has been dismissed.
    public var onboardingDone: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case saveDir = "save_dir", filenamePattern = "filename_pattern", saveWithoutDialog = "save_without_dialog"
        case copyOnSave = "copy_on_save", notifications, playSound = "play_sound", color, width, palette
        case dimOpacity = "dim_opacity", showHelp = "show_help", showMagnifier = "show_magnifier", hotkey
        case onboardingDone = "onboarding_done"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func get<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback
        }
        saveDir = get(.saveDir, d.saveDir)
        filenamePattern = get(.filenamePattern, d.filenamePattern)
        saveWithoutDialog = get(.saveWithoutDialog, d.saveWithoutDialog)
        copyOnSave = get(.copyOnSave, d.copyOnSave)
        notifications = get(.notifications, d.notifications)
        playSound = get(.playSound, d.playSound)
        color = get(.color, d.color)
        width = get(.width, d.width)
        palette = get(.palette, d.palette)
        dimOpacity = get(.dimOpacity, d.dimOpacity)
        showHelp = get(.showHelp, d.showHelp)
        showMagnifier = get(.showMagnifier, d.showMagnifier)
        hotkey = get(.hotkey, d.hotkey)
        onboardingDone = get(.onboardingDone, d.onboardingDone)
        self = sanitized()
    }

    public func sanitized() -> Config {
        var c = self
        let d = Config()
        c.width = c.width.isFinite ? min(max(c.width, 1), 40) : d.width
        c.dimOpacity = c.dimOpacity.isFinite ? min(max(c.dimOpacity, 0), 1) : d.dimOpacity
        c.palette = c.palette.filter { RGBA(hex: $0) != nil }
        if c.palette.isEmpty { c.palette = d.palette }
        if RGBA(hex: c.color) == nil { c.color = d.color }
        if c.filenamePattern.trimmingCharacters(in: .whitespaces).isEmpty { c.filenamePattern = d.filenamePattern }
        return c
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quackShot", isDirectory: true)
    }

    public static var path: URL { directory.appendingPathComponent("config.json") }

    public static func load(from url: URL = Config.path) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("quackShot: ignoring invalid config: \(error)\n".utf8))
            return Config()
        }
    }

    public func save(to url: URL = Config.path) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (enc.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("quackShot: cannot write \(url.path): \(error)\n".utf8))
        }
    }

    public var rgba: RGBA { RGBA(hex: color) ?? RGBA(1, 0.23, 0.19) }
    public var paletteColors: [RGBA] { palette.compactMap { RGBA(hex: $0) } }

    public var saveDirectory: URL {
        let trimmed = saveDir.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return URL(fileURLWithPath: expandTilde(trimmed), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Screenshots", isDirectory: true)
    }

    /// A file name built from `filenamePattern` (strftime syntax) and the clock.
    public func defaultFilename(date: Date = Date()) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 256)
        let n = strftime(&buf, buf.count, filenamePattern, &tmv)
        let stem = n > 0 ? String(cString: buf) : "quackshot"
        return stem.replacingOccurrences(of: "/", with: "-") + ".png"
    }
}

public func expandTilde(_ p: String) -> String {
    (p as NSString).expandingTildeInPath
}

/// `url` itself, or `url` with `-1`, `-2`… appended when it already exists.
public func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    for i in 1... {
        let name = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
        let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return url
}
