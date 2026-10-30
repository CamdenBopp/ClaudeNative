import AppKit
import ImageIO
import Testing
@testable import ClaudeNative

@MainActor
struct AttachmentThumbnailTests {
    @Test func largeImagesProduceBoundedPreviewsWithTheirAspectRatio() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1200,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let preview = try #require(AttachmentThumbnail.make(data: data))
        #expect(preview.width <= AttachmentThumbnail.maxPixelSize && preview.height <= AttachmentThumbnail.maxPixelSize)
        #expect(preview.width == 2 * preview.height)
        #expect(AttachmentThumbnail.make(data: Data([0, 1, 2])) == nil)
    }

    @Test func orientationMetadataRotatesThePreview() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 80,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let original = try #require(bitmap.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let preview = try #require(AttachmentThumbnail.make(data: data as Data))
        #expect(preview.height == preview.width * 2)
        #expect(preview.height <= AttachmentThumbnail.maxPixelSize)
    }
}
