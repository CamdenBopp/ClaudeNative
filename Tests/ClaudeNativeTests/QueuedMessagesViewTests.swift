import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
import ClaudeNativeCore

@MainActor
struct QueuedMessagesViewTests {
    @Test func imageOnlyMessagesHaveDistinctEditAndRemoveNames() async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        for _ in 0..<500 where !model.isReady { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.isReady)
        model.send("active")
        for name in ["diagram.png", "screenshot.png"] {
            model.send("", images: [ImageAttachment(name: name, mediaType: "image/png", data: Data([1]))])
        }
        let (window, host) = AccessibilityHost.window(hosting: QueuedMessagesView(model: model), size: NSSize(width: 500, height: 250))
        defer { window.close() }
        func labels() -> [String] {
            AccessibilityHost.descendants(of: host).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }
        }
        #expect(labels().contains("1 attached image"))
        let header = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.label($0) == "2 queued messages" })
        try #require(header.accessibilityPerformPress?() == true)
        AccessibilityHost.settle(host)
        for name in ["diagram.png", "screenshot.png"] {
            #expect(labels().contains("Edit queued message: \(name)"))
            #expect(labels().contains("Remove queued message: \(name)"))
        }
        let remove = try #require(AccessibilityHost.descendants(of: host).first {
            AccessibilityHost.label($0) == "Remove queued message: screenshot.png"
        })
        try #require(remove.accessibilityPerformPress?() == true)
        #expect(model.queuedMessages.count == 1)
        #expect(model.queuedMessages.first?.images.map(\.name) == ["diagram.png"])
    }

    @Test func theStackExpandsAndExposesEditAndRemoveControls() async throws {
        let fixture = try MessageQueueTests.Fixture()
        let model = AppModel(cliExecutable: fixture.executable)
        defer { model.close(); try? FileManager.default.removeItem(at: fixture.directory) }
        model.start(in: fixture.directory)
        for _ in 0..<500 {
            if model.isReady { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.isReady)
        model.send("active")
        model.send("second")
        model.send("third")
        let view = QueuedMessagesView(model: model)
        let (window, host) = AccessibilityHost.window(hosting: view, size: NSSize(width: 420, height: 220))
        defer { window.close() }
        func element(_ label: String) throws -> AnyObject {
            try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.label($0) == label }, "Missing \(label): \(AccessibilityHost.descendants(of: host).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) })")
        }
        // A system disclosure triangle, so VoiceOver reads the name first
        // and then collapsed or expanded; a button with a custom value read
        // "Collapsed 2 queued messages button".
        func isOpen(_ element: AnyObject) -> Bool? {
            guard let object = element as? NSObject else { return nil }
            return (object.perform(#selector(NSAccessibilityProtocol.accessibilityValue))?.takeUnretainedValue() as? NSNumber)?.boolValue
        }
        let header = try element("2 queued messages")
        #expect(AccessibilityHost.role(header) == .disclosureTriangle)
        #expect(isOpen(header) == false)
        #expect((header as AnyObject).accessibilityPerformPress?() == true)
        AccessibilityHost.settle(host)
        #expect(isOpen(try element("2 queued messages")) == true)
        #expect((try element("Edit queued message: second") as AnyObject).accessibilityPerformPress?() == true)
        AccessibilityHost.settle(host)
        #expect(model.editingQueuedMessageID == model.queuedMessages.first?.id)
        #expect(AccessibilityHost.value(try element("Edit queued message")) == "second")
        #expect((try element("Cancel Edit") as AnyObject).accessibilityPerformPress?() == true)
        AccessibilityHost.settle(host)
        #expect(model.editingQueuedMessageID == nil)
        #expect((try element("Remove queued message: third") as AnyObject).accessibilityPerformPress?() == true)
        AccessibilityHost.settle(host)
        #expect(model.queuedMessages.map(\.text) == ["second"])
    }
}
