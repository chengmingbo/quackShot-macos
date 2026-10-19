import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encode `image` in the format implied by `url`'s extension (PNG by default).
public func writeImage(_ image: CGImage, to url: URL) throws {
    let type: UTType
    var props: [CFString: Any] = [:]
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": type = .jpeg; props[kCGImageDestinationLossyCompressionQuality] = 0.92
    case "tif", "tiff": type = .tiff
    case "bmp": type = .bmp
    case "heic": type = .heic; props[kCGImageDestinationLossyCompressionQuality] = 0.9
    case "gif": type = .gif
    default: type = .png
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw CLIError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CLIError("cannot encode \(url.path)") }
}

public func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

public func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Resolve a user-given `--path`: a directory gets a generated file name,
/// a name without extension gets `.png`.
public func resolveTarget(_ path: String, config: Config) -> URL {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if (exists && isDir.boolValue) || path.hasSuffix("/") {
        return uniqueURL(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(config.defaultFilename()))
    }
    let url = URL(fileURLWithPath: path)
    return url.pathExtension.isEmpty ? url.appendingPathExtension("png") : url
}

public func defaultTarget(_ config: Config) -> URL {
    uniqueURL(config.saveDirectory.appendingPathComponent(config.defaultFilename()))
}
