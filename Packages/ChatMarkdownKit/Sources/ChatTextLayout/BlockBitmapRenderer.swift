import CoreGraphics
import Foundation
import ChatMarkdownCore

/// Renders one block's layout snapshot into a bitmap, off the main thread —
/// the final step of the Telegram-style pipeline this architecture was built
/// around. The main thread's remaining role is assigning the finished image
/// to `layer.contents`; `CABackingStoreUpdate` rasterization (the last
/// measured hitch class) disappears from commits entirely.
///
/// Pure CoreGraphics + CoreText: callable from any thread, testable on the
/// macOS host. Inputs are immutable snapshots (`BlockLayoutResult`) and
/// immutable CF colors (`DrawPalette`).
public enum BlockBitmapRenderer {
    /// Renders at `scale` pixels per point. Returns nil for degenerate sizes.
    public static func render(
        result: BlockLayoutResult,
        palette: DrawPalette,
        scale: CGFloat
    ) -> CGImage? {
        let pixelWidth = Int((result.size.width * scale).rounded(.up))
        let pixelHeight = Int((result.size.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0, scale > 0 else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        // Draw commands assume a UIKit-style context (top-left origin,
        // y-down); CG bitmap contexts are bottom-left y-up. Scale to point
        // units, then flip once.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: result.size.height)
        context.scaleBy(x: 1, y: -1)

        return RenderSignposts.layout.withIntervalSignpost("prose.render") {
            result.draw(in: context, palette: palette)
            return context.makeImage()
        }
    }
}
