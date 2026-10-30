import CoreGraphics
import CoreText
import Foundation

/// One laid-out line.
///
/// `@unchecked Sendable`: CTLine is immutable after creation, and CoreText
/// object creation/drawing is thread-safe (documented since iOS 6). Snapshots
/// are produced on background queues and drawn on the main thread; nothing
/// mutates them in between.
public struct LineSnapshot: @unchecked Sendable {
    public let line: CTLine
    /// Origin in CoreText frame coordinates (bottom-left origin, y-up).
    public let origin: CGPoint
}

/// Immutable result of laying out one block's text at one width. This is the
/// unit that layout caches store and that crosses from background layout to
/// the main-thread draw — the Telegram TextNode "asyncLayout" shape.
public struct TextLayoutResult: @unchecked Sendable {
    public let size: CGSize
    public let lines: [LineSnapshot]

    /// Draws into a UIKit-style context (top-left origin, y-down). The caller
    /// sets the context fill color first; runs use foreground-from-context.
    public func draw(in context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        for snapshot in lines {
            context.textPosition = snapshot.origin
            CTLineDraw(snapshot.line, context)
        }
        context.restoreGState()
    }

    /// Draws with distinct text and link colors, both resolved at draw time
    /// (colors are never baked into attributed strings or cached geometry).
    ///
    /// Lines without link runs keep the fast whole-line `CTLineDraw` path;
    /// lines containing at least one link run fall back to per-run drawing so
    /// each run can pick its fill color from the context before `CTRunDraw`.
    public func draw(in context: CGContext, textColor: CGColor, linkColor: CGColor) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        for snapshot in lines {
            let runs = (CTLineGetGlyphRuns(snapshot.line) as? [CTRun]) ?? []
            let containsLink = runs.contains { run in
                (CTRunGetAttributes(run) as NSDictionary)[CMKAttribute.linkDestination.rawValue] != nil
            }
            if containsLink {
                for run in runs {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let isLink = attributes[CMKAttribute.linkDestination.rawValue] != nil
                    context.setFillColor(isLink ? linkColor : textColor)
                    context.textPosition = snapshot.origin
                    CTRunDraw(run, context, CFRange(location: 0, length: 0))
                }
            } else {
                context.setFillColor(textColor)
                context.textPosition = snapshot.origin
                CTLineDraw(snapshot.line, context)
            }
        }
        context.restoreGState()
    }
}

public enum TextLayoutEngine {
    /// Pure function, callable from any queue — the layout scheduler owns
    /// threading, cancellation, and caching above this level.
    public static func layout(attributedString: NSAttributedString, width: CGFloat) -> TextLayoutResult {
        precondition(width > 0 && width.isFinite, "layout width must be finite and positive")

        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var fitRange = CFRange()
        let constraints = CGSize(width: width, height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraints,
            &fitRange
        )
        let height = ceil(suggested.height)
        guard height > 0 else {
            return TextLayoutResult(size: CGSize(width: width, height: 0), lines: [])
        }

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        let snapshots = zip(ctLines, origins).map { LineSnapshot(line: $0, origin: $1) }
        // Tight width (chat bubbles size to content); the frame path keeps the
        // full constraint so wrapping is unaffected. Line x-origins are
        // path-relative — fine for natural/leading alignment; RTL alignment
        // will need the path width carried alongside.
        let tightWidth = min(width, ceil(suggested.width))
        return TextLayoutResult(size: CGSize(width: tightWidth, height: height), lines: snapshots)
    }
}
