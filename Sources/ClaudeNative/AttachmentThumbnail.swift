import ClaudeNativeCore
import ImageIO
import SwiftUI

/// Decode a small, orientation-correct preview rather than displaying a
/// full-resolution image inside every attachment chip.
struct AttachmentThumbnail: View {
    /// The preview's side in points, about two lines of chip text.
    static let side: CGFloat = 32
    /// Pixels decoded for the longer edge: the side at 2x.
    static let maxPixelSize = 2 * Int(side)
    /// The widest a chip's file name draws before truncating in the middle;
    /// VoiceOver still reads the whole name.
    static let nameMaxWidth: CGFloat = 160

    let attachment: ImageAttachment
    @State private var preview: CGImage?

    var body: some View {
        Group {
            if let preview {
                Image(decorative: preview, scale: 2)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
        .accessibilityHidden(true)
        .task(id: attachment.id) {
            let data = attachment.data
            let image = await Task.detached(priority: .utility) { Self.make(data: data) }.value
            guard !Task.isCancelled else { return }
            preview = image
        }
    }

    nonisolated static func make(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
