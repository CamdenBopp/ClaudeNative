import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// A saved conversation reopens where you were reading it, at the same
/// place within the message after a change of width, and at its end when
/// you'd read to the end or the place isn't on the page it opens with.
@MainActor
struct TranscriptPositionTests {
    static let sessionID = "position-test"

    static func store() -> TranscriptPositionStore {
        TranscriptPositionStore(defaults: UserDefaults(suiteName: "TranscriptPositionTests.\(UUID().uuidString)")!)
    }

    @MainActor final class Hosted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let entries: [TranscriptEntry]
        let store: TranscriptPositionStore

        init(_ entries: [TranscriptEntry], store: TranscriptPositionStore, sessionID: String = TranscriptPositionTests.sessionID, width: CGFloat = 600) {
            self.entries = entries
            self.store = store
            (window, host) = AccessibilityHost.window(hosting: AnyView(TranscriptView(
                transcript: Transcript(restoring: entries), revision: 0, workingDirectory: nil, isWorking: false,
                sessionID: sessionID, positionStore: store
            )), size: NSSize(width: width, height: 300))
        }

        var scrollView: NSScrollView {
            get throws { try #require(MessageNavigationHostedTests.Hosted.views(NSScrollView.self, in: window.contentView).first { $0.accessibilityLabel() == "Conversation" }) }
        }

        func row(_ id: String) throws -> MessageRowView {
            try #require(MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: window.contentView).first { $0.entry?.id == id })
        }

        /// Where `row` starts relative to the top of what's shown.
        func onScreenY(of row: NSView) throws -> CGFloat {
            let scrollView = try scrollView
            let document = try #require(scrollView.documentView)
            return document.convert(row.bounds, from: row).minY - scrollView.contentView.bounds.minY
        }

        func scroll(toTopOf id: String, fraction: CGFloat = 0) throws {
            let scrollView = try scrollView
            let row = try row(id)
            let document = try #require(scrollView.documentView)
            let frame = document.convert(row.bounds, from: row)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: frame.minY + frame.height * fraction))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// Takes the conversation out of the window, as a session switch does.
        func close() {
            host.rootView = AnyView(EmptyView())
            AccessibilityHost.settle(host)
            window.close()
        }
    }

    /// Long enough replies that a row spans several lines.
    static let entries = (0..<40).map {
        TranscriptEntry(id: "e\($0)", kind: $0.isMultiple(of: 2) ? .user : .assistant,
                        text: "Message \($0). " + String(repeating: "Some words to wrap. ", count: 12))
    }

    /// A wider window rewraps every row above the place being read, and the
    /// view kept its scroll offset, so other text slid into view (the side
    /// panel opening did it). The row being read stays at the top.
    @Test func aWidthChangeKeepsTheRowBeingRead() throws {
        let hosted = Hosted(Self.entries, store: Self.store())
        defer { hosted.close() }
        try hosted.scroll(toTopOf: "e11", fraction: 0.5)
        AccessibilityHost.settle(hosted.host)
        hosted.window.setContentSize(NSSize(width: 900, height: 300))
        AccessibilityHost.settle(hosted.host)
        let row = try hosted.row("e11")
        let y = try hosted.onScreenY(of: row)
        #expect(abs(y + row.frame.height * 0.5) <= 2, "row starts \(y), height \(row.frame.height)")
    }

    /// Bigger Text rewraps every row too; the row being read stays put.
    @Test func aTextSizeChangeKeepsTheRowBeingRead() throws {
        let store = Self.store()
        let hosted = Hosted(Self.entries, store: store)
        defer { hosted.close() }
        try hosted.scroll(toTopOf: "e11", fraction: 0.5)
        AccessibilityHost.settle(hosted.host)
        hosted.host.rootView = AnyView(TranscriptView(
            transcript: Transcript(restoring: Self.entries), revision: 0, workingDirectory: nil, isWorking: false,
            sessionID: Self.sessionID, positionStore: store, textScale: 1.5
        ))
        AccessibilityHost.settle(hosted.host)
        let row = try hosted.row("e11")
        let y = try hosted.onScreenY(of: row)
        #expect(abs(y + row.frame.height * 0.5) <= 2, "row starts \(y), height \(row.frame.height)")
    }

    @Test func aSavedConversationOpensWhereYouWereReading() throws {
        let store = Self.store()
        store.save(TranscriptPosition(entryID: "e11", fraction: 0.5), for: Self.sessionID)
        let hosted = Hosted(Self.entries, store: store)
        defer { hosted.close() }
        let row = try hosted.row("e11")
        #expect(abs(try hosted.onScreenY(of: row) + row.frame.height * 0.5) <= 1)
        #expect(!(try hosted.scrollView.isNearBottom))
    }

    @Test func thePlaceWithinTheMessageSurvivesANarrowerWindow() throws {
        let store = Self.store()
        let wide = Hosted(Self.entries, store: store, width: 700)
        try wide.scroll(toTopOf: "e11", fraction: 0.5)
        wide.close()
        let narrow = Hosted(Self.entries, store: store, width: 420)
        defer { narrow.close() }
        let row = try narrow.row("e11")
        #expect(abs(try narrow.onScreenY(of: row) + row.frame.height * 0.5) <= 1)
    }

    @Test func leavingAConversationSavesTheRowAtTheTopOfTheView() throws {
        let store = Self.store()
        let hosted = Hosted(Self.entries, store: store)
        try hosted.scroll(toTopOf: "e20", fraction: 0.25)
        hosted.close()
        let saved = try #require(store.position(for: Self.sessionID))
        #expect(saved.entryID == "e20")
        #expect(abs(saved.fraction - 0.25) < 0.02)
    }

    @Test func aConversationReadToItsEndReopensAtItsEnd() throws {
        let store = Self.store()
        store.save(TranscriptPosition(entryID: "e3", fraction: 0), for: Self.sessionID)
        let hosted = Hosted(Self.entries, store: store)
        try hosted.scrollView.scrollToBottom()
        hosted.close()
        #expect(store.position(for: Self.sessionID) == nil)
        let reopened = Hosted(Self.entries, store: store)
        defer { reopened.close() }
        #expect(try reopened.scrollView.isNearBottom)
    }

    /// Only the latest page is built; a place before it opens at the end
    /// rather than building every page in between.
    @Test func aPlaceBeforeTheOpeningPageOpensAtTheEnd() throws {
        let store = Self.store()
        store.save(TranscriptPosition(entryID: "e5", fraction: 0), for: Self.sessionID)
        let many = (0..<(TranscriptLayout.pageSize + 20)).map { TranscriptEntry(id: "e\($0)", kind: $0.isMultiple(of: 2) ? .user : .assistant, text: "Message \($0)") }
        let hosted = Hosted(many, store: store)
        #expect(try hosted.scrollView.isNearBottom)
        #expect(MessageNavigationHostedTests.Hosted.views(MessageRowView.self, in: hosted.window.contentView).count == TranscriptLayout.pageSize)
        // Leaving from the end it opened at keeps the place it couldn't
        // reach, rather than saving "at the end" over it.
        hosted.close()
        #expect(store.position(for: Self.sessionID)?.entryID == "e5")
    }

    @Test func anotherSessionDoesNotUseThePlace() throws {
        let store = Self.store()
        store.save(TranscriptPosition(entryID: "e11", fraction: 0), for: "someone-else")
        let hosted = Hosted(Self.entries, store: store)
        defer { hosted.close() }
        #expect(try hosted.scrollView.isNearBottom)
    }

    @Test func theStoreKeepsTheMostRecentSessions() {
        let defaults = UserDefaults(suiteName: "TranscriptPositionTests.\(UUID().uuidString)")!
        let store = TranscriptPositionStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 0)
        for index in 0...TranscriptPositionStore.capacity {
            store.save(TranscriptPosition(entryID: "e", fraction: 0, updatedAt: start.addingTimeInterval(Double(index))), for: "s\(index)")
        }
        #expect(store.position(for: "s0") == nil)
        #expect(store.position(for: "s\(TranscriptPositionStore.capacity)") != nil)
        // A new store reads what this one saved.
        #expect(TranscriptPositionStore(defaults: defaults).position(for: "s1") != nil)
    }
}
