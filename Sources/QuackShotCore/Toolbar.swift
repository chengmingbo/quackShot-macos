import CoreGraphics

/// The round buttons that float next to the selection.
public enum ToolbarButton: Equatable, Sendable {
    case tool(Tool), color, undo, redo, pin, copy, save, close

    public static let all: [ToolbarButton] =
        Tool.allCases.map { .tool($0) } + [.color, .undo, .redo, .pin, .copy, .save, .close]

    public var label: String {
        switch self {
        case .tool(let t): return t.label
        case .color: return "Colour (right-click)"
        case .undo: return "Undo (⌘Z)"
        case .redo: return "Redo (⇧⌘Z)"
        case .pin: return "Pin to screen (⌘P)"
        case .copy: return "Copy (⌘C / Return)"
        case .save: return "Save (⌘S)"
        case .close: return "Close (Esc)"
        }
    }

    /// SF Symbol drawn on the button (`color` is drawn as a swatch instead).
    public var symbol: String {
        switch self {
        case .tool(.pen): return "scribble"
        case .tool(.line): return "line.diagonal"
        case .tool(.arrow): return "arrow.up.right"
        case .tool(.rect): return "rectangle"
        case .tool(.ellipse): return "circle"
        case .tool(.marker): return "highlighter"
        case .tool(.text): return "textformat"
        case .tool(.pixelate): return "checkerboard.rectangle"
        case .tool(.counter): return "1.circle"
        case .color: return "circle.fill"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .pin: return "pin"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .close: return "xmark"
        }
    }
}

public enum ToolbarLayout {
    public static let radius: CGFloat = 15
    public static let pitch: CGFloat = 36
    static let margin: CGFloat = 10

    /// Button centres for `selection` on `screen`, both in view points
    /// (top-left origin): below the selection if it fits, else above, else
    /// inside. Rows wrap when the screen is narrower than the toolbar.
    public static func centres(selection sel: CGRect, screen: CGRect, count n: Int = ToolbarButton.all.count) -> [CGPoint] {
        let perRow = min(n, max(1, Int(((screen.width - 2 * margin) / pitch).rounded(.down))))
        let rows = (n + perRow - 1) / perRow
        let rowW = CGFloat(perRow) * pitch
        let blockH = CGFloat(rows) * pitch
        let below = sel.maxY + margin
        let above = sel.minY - margin - blockH
        let top: CGFloat
        if below + blockH <= screen.maxY {
            top = below
        } else if above >= screen.minY {
            top = above
        } else {
            top = max(screen.minY, sel.maxY - margin - blockH)
        }
        let left = min(max(sel.midX - rowW / 2, screen.minX), max(screen.minX, screen.maxX - rowW))
        return (0..<n).map { i in
            CGPoint(x: left + CGFloat(i % perRow) * pitch + pitch / 2, y: top + CGFloat(i / perRow) * pitch + pitch / 2)
        }
    }

    public static func hit(_ centres: [CGPoint], _ p: CGPoint) -> Int? {
        centres.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= radius + 2 }
    }
}
