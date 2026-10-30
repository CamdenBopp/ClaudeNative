import Foundation
import Testing
@testable import ClaudeNativeCore

/// Against ask_user_question.jsonl (mock model) and real_ask_user_question.jsonl
/// (live model): a can_use_tool request from the CLI
/// and the answer it accepted (its tool_result echoes the answers back).
struct AskUserQuestionTests {
    /// One capture and the values it pins. The mock's wording was scripted;
    /// the real one is what claude-haiku-5-5 emitted.
    struct Capture: Sendable, CustomTestStringConvertible {
        let fixture: String
        let firstOptionDescription: String
        let answers: [String: [String]]
        var testDescription: String { fixture }
    }

    static let captures = [
        Capture(fixture: "ask_user_question", firstOptionDescription: "Matches the toolbar", answers: [
            "Which color should the button be?": ["Green"],
            "Which platforms?": ["macOS", "iOS"],
        ]),
        Capture(fixture: "real_ask_user_question", firstOptionDescription: "Blue button", answers: [
            "Which color should the button be?": ["Blue"],
            "Which platforms?": ["macOS", "iOS"],
        ]),
    ]

    func capturedRequest(_ fixture: String) throws -> PermissionRequest {
        let events = try FixtureReplayTests.events(fixture)
        let request = events.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }.first
        return try #require(request)
    }

    @Test(arguments: captures)
    func readsBothQuestionsWithTheirOptions(capture: Capture) throws {
        let questions = try #require(AskUserQuestion.questions(in: capturedRequest(capture.fixture)))
        #expect(questions.map(\.question) == ["Which color should the button be?", "Which platforms?"])
        #expect(questions.map(\.header) == ["Color", "Platforms"])
        #expect(questions.map(\.multiSelect) == [false, true])
        #expect(questions[0].options.map(\.label) == ["Blue", "Green"])
        #expect(questions[0].options[0].description == capture.firstOptionDescription)
    }

    @Test(arguments: captures)
    func answersMatchWhatTheCLIAccepted(capture: Capture) throws {
        let request = try capturedRequest(capture.fixture)
        let accepted = try #require(FixtureReplayTests.lines(capture.fixture).first {
            $0.dir == "stdin" && $0.msg["type"]?.string == "control_response"
                && $0.msg["response"]?["response"]?["behavior"] != nil
        }).msg["response"]?["response"]?["updatedInput"]

        let ours = AskUserQuestion.answering(request, with: capture.answers)
        #expect(ours == accepted)
    }

    @Test func aQuestionWithoutOptionsFallsBackToAllowDeny() {
        let request = PermissionRequest(requestID: "r", toolName: "AskUserQuestion", input: .object([
            "questions": .array([.object(["question": .string("Anything else?"), "options": .array([])])]),
        ]))
        #expect(AskUserQuestion.questions(in: request) == nil)
    }

    @Test func otherToolsAreNotQuestions() {
        let write = PermissionRequest(requestID: "r", toolName: "Write", input: .object(["questions": .array([])]))
        #expect(AskUserQuestion.questions(in: write) == nil)
    }
}

/// An option's description is shown under it and spoken after it, unless
/// it only repeats the label: a real request gave Red and Blue the
/// descriptions "Red" and "Blue", and VoiceOver read "Red, Red".
struct OptionDescriptionTests {
    @Test func aDescriptionThatRepeatsTheLabelIsDropped() {
        #expect(UserQuestion.Option(label: "Red", description: "Red").shownDescription == nil)
        #expect(UserQuestion.Option(label: "Red", description: " red. ").shownDescription == nil)
        #expect(UserQuestion.Option(label: "Red", description: "").shownDescription == nil)
        #expect(UserQuestion.Option(label: "Red", description: nil).shownDescription == nil)
        #expect(UserQuestion.Option(label: "Red", description: "Warm and loud").shownDescription == "Warm and loud")
    }
}
