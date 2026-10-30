import AppKit
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// What Command-V in the message field attaches: images on the clipboard
/// (a screenshot, a copied image file) when it holds no text. Anything with
/// text pastes as text, as before.
@MainActor
struct PastedImagesTests {
    static func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("PastedImagesTests.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    static func pngData() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func aScreenshotOnTheClipboardBecomesAPNGAttachment() throws {
        let board = Self.board()
        board.setData(try Self.pngData(), forType: .png)
        let images = try #require(PastedImages.attachments(from: board))
        #expect(images.map(\.mediaType) == ["image/png"])
        #expect(images.first?.name == PastedImages.fileName)
    }

    /// Screenshots from some apps arrive as TIFF only; the API takes PNG.
    @Test func aTIFFOnlyImageIsSentAsPNG() throws {
        let board = Self.board()
        let tiff = try #require(NSImage(data: try Self.pngData())?.tiffRepresentation)
        board.setData(tiff, forType: .tiff)
        let image = try #require(PastedImages.attachments(from: board)?.first)
        #expect(image.mediaType == "image/png")
        #expect(NSBitmapImageRep(data: image.data) != nil)
    }

    @Test func aCopiedImageFileIsAttachedByItsName() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "chart.png")
        try Self.pngData().write(to: file)
        let board = Self.board()
        // Finder puts the name on the clipboard as text too.
        board.writeObjects([file as NSURL])
        board.setString("chart.png", forType: .string)
        #expect(try #require(PastedImages.attachments(from: board)).map(\.name) == ["chart.png"])
    }

    @Test func textPastesAsText() throws {
        let board = Self.board()
        board.setString("hello", forType: .string)
        #expect(PastedImages.attachments(from: board) == nil)
        // Text alongside an image, as some apps copy, still pastes as text.
        board.setData(try Self.pngData(), forType: .png)
        #expect(PastedImages.attachments(from: board) == nil)
    }

    @Test func aCopiedFileThatIsntAnImagePastesAsBefore() throws {
        let board = Self.board()
        board.writeObjects([URL(fileURLWithPath: "/tmp/notes.txt") as NSURL])
        board.setString("notes.txt", forType: .string)
        #expect(PastedImages.attachments(from: board) == nil)
    }

    /// Copied files that aren't all images pasted Finder's bare names as
    /// text ("report.pdf"), which Claude can't find, and lost any images
    /// in the selection. They're handled as a drop is now.
    @Test func copiedFilesOfAnyKindPasteAsFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "paste-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "shot.png"), report = folder.appending(path: "report.pdf")
        try Self.pngData().write(to: image)
        try Data("%PDF".utf8).write(to: report)
        let board = Self.board()
        board.writeObjects([report as NSURL, image as NSURL])
        board.setString("report.pdf\nshot.png", forType: .string)
        #expect(PastedImages.pasted(from: board) == .files([report, image]))
    }

    @Test func aScreenshotStillPastesAsAnImage() throws {
        let board = Self.board()
        board.setData(try Self.pngData(), forType: .png)
        guard case .images(let images)? = PastedImages.pasted(from: board) else {
            Issue.record("not pasted as an image"); return
        }
        #expect(images.map(\.name) == [PastedImages.fileName])
    }
}
