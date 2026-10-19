import CoreGraphics
import Foundation

public struct Options: Equatable, Sendable {
    public var delayMs: Int = 0
    public var path: String?
    public var clipboard = false
    public var raw = false
    public var pin = false
    public var acceptOnSelect = false
    public var region: CGRect?

    public init() {}

    /// Whether the user chose what Return does in the editor.
    public var hasExplicitAction: Bool { path != nil || clipboard || raw || pin }
}

public enum Command: Equatable, Sendable {
    /// No arguments: run as a menu bar app with a global hot key.
    case agent
    case gui(Options)
    case full(Options)
    case config
    case help
    case version
    /// Hidden: drive the editor offscreen and write renders to a directory.
    case selfTest(String)
}

public let usage = """
Usage: quackShot [COMMAND] [OPTIONS]

With no command quackShot runs in the menu bar and listens for its hot key.

Commands:
  gui       Select a region and annotate it, then exit
  full      Capture the whole screen without the editor
  config    Create the config file if needed and print its path

Options:
  -d, --delay MS         Wait MS milliseconds before capturing
  -p, --path PATH        Save to PATH (a file, or a directory for a generated name)
  -c, --clipboard        Copy the capture to the clipboard
  -r, --raw              Write the capture as PNG to stdout
      --pin              (gui) Pin the capture on screen when accepted
  -s, --accept-on-select (gui) Finish as soon as the mouse is released
  -g, --region WxH+X+Y   (full) Capture only this region, in screen points
  -h, --help             Show this help
  -V, --version          Show the version

In the editor, Return copies to the clipboard unless -p/-c/-r/--pin say otherwise.
Exit status is 1 if the capture was cancelled, 2 on errors.
"""

public struct CLIError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ s: String) { description = s }
}

/// Parses `WxH+X+Y` (X11 geometry syntax).
public func parseRegion(_ s: String) -> CGRect? {
    let parts = s.split(separator: "+", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let size = parts[0].split(whereSeparator: { $0 == "x" || $0 == "X" })
    guard size.count == 2, let w = Double(size[0]), let h = Double(size[1]),
          let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
    let r = CGRect(x: x, y: y, width: w, height: h)
    return r.isTiny ? nil : r
}

public func parseCommand(_ arguments: [String]) -> Result<Command, CLIError> {
    var args = arguments[...]
    // LaunchServices may pass -psn_… or AppKit defaults (-NSFoo YES); a
    // bare launch with only those is the menu bar app.
    if args.allSatisfy({ $0.hasPrefix("-psn_") || $0.hasPrefix("-NS") || $0.hasPrefix("-Apple") }) {
        return .success(.agent)
    }
    var command = "gui"
    if let first = args.first, !first.hasPrefix("-") {
        command = first
        args = args.dropFirst()
    }
    if command == "selftest" {
        return .success(.selfTest(args.first ?? "selftest-out"))
    }
    var o = Options()
    while let a = args.popFirst() {
        var flag = a
        var inline: String?
        if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
            flag = String(a[..<eq])
            inline = String(a[a.index(after: eq)...])
        }
        func value() -> Result<String, CLIError> {
            if let inline { return .success(inline) }
            if let v = args.popFirst() { return .success(v) }
            return .failure(CLIError("\(flag) needs a value"))
        }
        switch flag {
        case "-h", "--help": return .success(.help)
        case "-V", "--version": return .success(.version)
        case "-d", "--delay":
            switch value() {
            case .success(let v):
                guard let n = Int(v), n >= 0 else { return .failure(CLIError("invalid delay '\(v)'")) }
                o.delayMs = n
            case .failure(let e): return .failure(e)
            }
        case "-p", "--path":
            switch value() {
            case .success(let v): o.path = expandTilde(v)
            case .failure(let e): return .failure(e)
            }
        case "-c", "--clipboard": o.clipboard = true
        case "-r", "--raw": o.raw = true
        case "--pin": o.pin = true
        case "-s", "--accept-on-select": o.acceptOnSelect = true
        case "-g", "--region":
            switch value() {
            case .success(let v):
                guard let r = parseRegion(v) else { return .failure(CLIError("invalid region '\(v)', expected WxH+X+Y")) }
                o.region = r
            case .failure(let e): return .failure(e)
            }
        default:
            if a.hasPrefix("-NS") || a.hasPrefix("-psn_") { continue }
            return .failure(CLIError("unknown option '\(a)'"))
        }
    }
    switch command {
    case "gui":
        if o.region != nil { return .failure(CLIError("--region is only for 'full'")) }
        return .success(.gui(o))
    case "full":
        if o.pin || o.acceptOnSelect { return .failure(CLIError("--pin and --accept-on-select are only for 'gui'")) }
        return .success(.full(o))
    case "config": return .success(.config)
    case "help": return .success(.help)
    case "version": return .success(.version)
    default: return .failure(CLIError("unknown command '\(command)'"))
    }
}
