import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A long conversation opens on its latest page. VO-U's lists searched
/// only the rows built, so a message marked on an earlier page wasn't in
/// Marked Messages, and moving back through Your Messages stopped at the
/// page's top as if it were the start.
@MainActor
struct RotorPagingTests {
    static let sessionID = "rotor-paging-\(UUID().uuidString)"

    @Test func theMarkedRotorFindsAMarkOnAnEarlierPage() throws {
        let entries = TranscriptPagingTests.entries(450)
        UserDefaults.standard.set(["e2"], forKey: "marks.\(Self.sessionID)")
        defer { UserDefaults.standard.removeObject(forKey: "marks.\(Self.sessionID)") }
        let (window, host) = AccessibilityHost.window(hosting: TranscriptView(
            transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil, isWorking: false, sessionID: Self.sessionID
        ), size: NSSize(width: 600, height: 400))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let conversation = try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: host).first { $0.accessibilityLabel() == "Conversation" })
        let rotors = AccessibilityHost.customRotors(conversation)
        func search(_ label: String, from current: NSAccessibilityCustomRotor.ItemResult?, _ direction: NSAccessibilityCustomRotor.SearchDirection) throws -> MessageRowView? {
            let rotor = try #require(rotors.first { $0.label == label })
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = direction
            return try #require(rotor.itemSearchDelegate).rotor(rotor, resultFor: parameters)?.targetElement as? MessageRowView
        }
        #expect(try search("Marked Messages", from: nil, .next)?.entry?.id == "e2")
        // Back from the top of the latest page, into the one before it.
        let first = try #require(MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: host).first { $0.entry?.id == "e250" })
        let earlier = try search("Your Messages", from: NSAccessibilityCustomRotor.ItemResult(targetElement: first), .previous)
        #expect(earlier?.entry?.id == "e248")
    }

    /// Headings are only known once a reply is drawn: going back past the
    /// first drawn row draws the page before it and keeps looking.
    @Test func theHeadingsRotorGoesBackIntoEarlierPages() throws {
        var entries = TranscriptPagingTests.entries(450)
        entries[1] = TranscriptEntry(id: "e1", kind: .assistant, text: "## Early heading\n\nText.")
        let (window, host) = AccessibilityHost.window(hosting: TranscriptView(
            transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil, isWorking: false
        ), size: NSSize(width: 600, height: 400))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let conversation = try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: host).first { $0.accessibilityLabel() == "Conversation" })
        let rotor = try #require(AccessibilityHost.customRotors(conversation).first { $0.type == .heading })
        let start = try #require(MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: host).first { $0.entry?.id == "e251" })
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.currentItem = NSAccessibilityCustomRotor.ItemResult(targetElement: start)
        parameters.searchDirection = .previous
        let found = try #require(rotor.itemSearchDelegate).rotor(rotor, resultFor: parameters)
        #expect(found?.customLabel == "Early heading")
    }
}
