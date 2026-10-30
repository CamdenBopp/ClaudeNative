import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

/// The questions sheet's form scrolls; VoiceOver stepping out of it to
/// reach Skip and Send Answers said only "scroll area". It's named.
@MainActor
struct QuestionsSheetAccessibilityTests {
    @Test func theQuestionsAreaIsNamed() throws {
        let request = try #require(try Fixtures.permissionRequests("real_ask_user_question").first)
        let questions = try #require(AskUserQuestion.questions(in: request))
        let sheet = QuestionsSheet(questions: questions, onAnswer: { _ in }, onSkip: {})
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 520, height: 420))
        let host = try #require(window.contentView)
        AccessibilityHost.settle(host)
        let areas = AccessibilityHost.descendants(of: host).filter { AccessibilityHost.role($0) == .scrollArea }
        #expect(!areas.isEmpty)
        #expect(areas.allSatisfy { !(AccessibilityHost.label($0) ?? "").isEmpty }, "\(areas.map { AccessibilityHost.label($0) ?? "nil" })")
    }

    /// A key pressed as the questions appear doesn't answer them: Return
    /// meant for the message field sent them unanswered.
    @Test func aKeyAsTheQuestionsAppearIsIgnored() async throws {
        let request = try #require(try Fixtures.permissionRequests("real_ask_user_question").first)
        let questions = try #require(AskUserQuestion.questions(in: request))
        var skipped = 0
        let sheet = QuestionsSheet(questions: questions, onAnswer: { _ in }, onSkip: { skipped += 1 })
        let (window, _) = AccessibilityHost.window(hosting: sheet, size: NSSize(width: 520, height: 420))
        defer { window.close() }
        let escape = PermissionSheetKeyboardTests.escapeKey
        _ = AccessibilityHost.pressKey(escape.0, keyCode: escape.1, in: window)
        #expect(skipped == 0)
        try await Task.sleep(for: PermissionSheet.answerDelay + .milliseconds(100))
        _ = AccessibilityHost.pressKey(escape.0, keyCode: escape.1, in: window)
        #expect(skipped == 1)
    }

    /// A multi-select question counted as answered with nothing checked,
    /// so Submit sent an empty answer, which Claude read as "none of these".
    @Test func aMultiSelectQuestionNeedsAChoice() throws {
        let request = try #require(try Fixtures.permissionRequests("real_ask_user_question").first)
        let questions = try #require(AskUserQuestion.questions(in: request))
        let multi = try #require(questions.first { $0.multiSelect })
        var picked: [String: String] = [:]
        for question in questions where !question.multiSelect { picked[question.question] = question.options.first?.label }
        #expect(!QuestionsSheet.isComplete(questions, picked: picked, checked: [:]))
        let checked = [multi.question: Set([multi.options[0].label])]
        #expect(QuestionsSheet.isComplete(questions, picked: picked, checked: checked))
    }
}
