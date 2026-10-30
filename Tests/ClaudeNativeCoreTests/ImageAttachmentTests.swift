import Foundation
import Testing
@testable import ClaudeNativeCore

struct ImageAttachmentTests {
    @Test func imagesComeBeforeTextAsBase64Blocks() {
        let png = ImageAttachment(name: "shot.png", mediaType: "image/png", data: Data([1, 2, 3]))
        let line = ClaudeCLI.userMessage("What is this?", images: [png], sessionID: "s")
        let content = line["message"]?["content"]?.array ?? []
        #expect(content.count == 2)
        #expect(content.first?["type"] == .string("image"))
        #expect(content.first?["source"]?["media_type"] == .string("image/png"))
        #expect(content.first?["source"]?["data"] == .string(Data([1, 2, 3]).base64EncodedString()))
        #expect(content.last?["text"] == .string("What is this?"))
    }

    @Test func anImageCanBeSentWithoutText() {
        let gif = ImageAttachment(name: "a.gif", mediaType: "image/gif", data: Data([0]))
        let content = ClaudeCLI.userMessage("", images: [gif], sessionID: "s")["message"]?["content"]?.array
        #expect(content?.count == 1)
    }

    @Test func onlyAPIImageTypesAreAccepted() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = folder.appending(path: "Photo.JPG")
        let tiff = folder.appending(path: "scan.tiff")
        try Data([9]).write(to: jpeg)
        try Data([9]).write(to: tiff)
        #expect(ImageAttachment(fileURL: jpeg)?.mediaType == "image/jpeg")
        #expect(ImageAttachment(fileURL: tiff) == nil)
    }
}
