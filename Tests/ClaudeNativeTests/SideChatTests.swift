import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Side chats are left out of the sidebar and the Command-K palette.
@MainActor
struct SideChatTests {
    @Test func sideChatsAreLeftOutOfTheList() throws {
        let defaults = try #require(UserDefaults(suiteName: "SideChatTests-\(UUID().uuidString)"))
        SideChats.remember("g2", in: defaults)
        SideChats.remember("g2", in: defaults)
        #expect(SideChats.ids(in: defaults) == ["g2"])
        let projects = [ProjectSidebarTests.garden, ProjectSidebarTests.kitchen]
        let hidden = SideChats.hiding(projects, ids: [ProjectSidebarTests.garden.sessions[1].id])
        #expect(hidden.map(\.sessions.count) == [1, 1])
        #expect(hidden.map(\.name) == ["garden", "kitchen · ~/Code"])
    }
}
