import Foundation
import Testing
@testable import ClaudeNativeCore

/// Against real_permission_allow.jsonl: a real rate_limit_event and result.
struct UsageTests {
    func events() throws -> [StreamEvent] {
        try FixtureReplayTests.lines("real_permission_allow").filter { $0.dir == "stdout" }.flatMap {
            try StreamEvent.readAll(JSONValue.parse($0.msg.line()))
        }
    }

    @Test func readsBothLimitWindowsFromTheRealEvent() throws {
        let limits = try #require(events().compactMap { event -> UsageLimits? in
            if case .usageLimits(let limits) = event { return limits }
            return nil
        }.last)
        #expect(limits.fiveHour?.utilization == 0.06)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_792_745_400))
        #expect(limits.weekly?.utilization == 0.01)
    }

    @Test func contextIsTheLastCallAgainstTheModelsWindow() throws {
        let context = try #require(events().compactMap { event -> ContextUsage? in
            if case .contextUsage(let usage) = event { return usage }
            return nil
        }.last)
        // Last iteration: 2 input + 31,684 cache read + 2,307 cache write.
        #expect(context.usedTokens == 33_993)
        #expect(context.windowTokens == 1_000_000)
    }

    @Test func theResultStillEndsTheTurn() throws {
        let events = try events()
        let finishIndex = try #require(events.lastIndex { if case .turnFinished = $0 { return true } else { return false } })
        let contextIndex = try #require(events.lastIndex { if case .contextUsage = $0 { return true } else { return false } })
        #expect(contextIndex == finishIndex + 1)
    }

    @Test func wordsTheStatusAsOneSentence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let limits = UsageLimits(
            fiveHour: .init(utilization: 0.08, resetsAt: now.addingTimeInterval(3 * 3600 + 26 * 60)),
            weekly: .init(utilization: 0.02, resetsAt: now.addingTimeInterval(6 * 86_400 + 23 * 3600))
        )
        let context = ContextUsage(usedTokens: 34_000, windowTokens: 1_000_000)
        #expect(UsageWording.sentence(limits: limits, context: context, now: now)
            == "5-hour limit 8% used, resets in 3 hours 26 minutes. Weekly limit 2% used, resets in 6 days 23 hours. Context 3% full.")
    }
}
