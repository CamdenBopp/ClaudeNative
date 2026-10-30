import Foundation

/// One multiple-choice question Claude asks through its AskUserQuestion tool.
public struct UserQuestion: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let label: String
        public let description: String?
        public var id: String { label }

        /// The description to show and speak after the label, or nil when
        /// it is empty or only repeats the label ("Red" for Red), which
        /// VoiceOver read twice.
        public var shownDescription: String? {
            guard let description else { return nil }
            func plain(_ text: String) -> String {
                text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            }
            let kept = plain(description)
            return kept.isEmpty || kept == plain(label) ? nil : description
        }
    }

    public let question: String
    /// A short tag for the question, such as "Color".
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool
    /// The CLI keys answers by question text, so it is unique within a request.
    public var id: String { question }
}

/// Reads AskUserQuestion permission requests and writes the user's answers
/// back in the shape the CLI accepts: `answers` maps each question's text to
/// the chosen label, with several labels joined by ", ".
public enum AskUserQuestion {
    public static let toolName = "AskUserQuestion"

    /// The questions in a request, or nil when the input isn't a well-formed
    /// AskUserQuestion call (the app then falls back to a plain Allow/Deny).
    public static func questions(in request: PermissionRequest) -> [UserQuestion]? {
        guard request.toolName == toolName, let items = request.input["questions"]?.array else { return nil }
        let questions = items.compactMap { item -> UserQuestion? in
            guard let question = item["question"]?.string, let options = item["options"]?.array else { return nil }
            return UserQuestion(
                question: question,
                header: item["header"]?.string,
                options: options.compactMap { option in
                    option["label"]?.string.map {
                        UserQuestion.Option(label: $0, description: option["description"]?.string)
                    }
                },
                multiSelect: item["multiSelect"]?.bool ?? false
            )
        }
        // A question with no options could never be answered in the sheet.
        guard questions.count == items.count, !questions.isEmpty,
              questions.allSatisfy({ !$0.options.isEmpty })
        else { return nil }
        return questions
    }

    /// The request's input with `answers` added. `answers` maps question text
    /// to the labels picked, in the order shown.
    public static func answering(_ request: PermissionRequest, with answers: [String: [String]]) -> JSONValue {
        var input = request.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
        return .object(input)
    }
}
