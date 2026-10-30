import ClaudeNativeCore
import SwiftUI

/// Claude's multiple-choice questions, answered with native radio groups and
/// checkboxes. Each question is a heading inside a group named by it, so
/// VoiceOver reads the question before the choices. The sheet starts on the
/// first question's first control.
struct QuestionsSheet: View {
    let questions: [UserQuestion]
    let onAnswer: ([String: [String]]) -> Void
    let onSkip: () -> Void
    /// Return or Escape sooner than this after the questions appear is
    /// ignored, as on the permission sheet: Return meant for the message
    /// field sent every multiple-choice question unanswered.
    var answerDelay: Duration = PermissionSheet.answerDelay
    @State private var shownAt = ContinuousClock.now
    private var hasSettled: Bool { ContinuousClock.now - shownAt >= answerDelay }

    /// Single-choice picks, keyed by question text.
    @State private var picked: [String: String] = [:]
    /// Multiple-choice picks, keyed by question text.
    @State private var checked: [String: Set<String>] = [:]
    @FocusState private var focus: Control?
    /// VoiceOver's cursor, moved onto the first question once the sheet is
    /// up. Keyboard focus alone left it on an unnamed "group".
    @AccessibilityFocusState private var focusedQuestion: UserQuestion.ID?

    /// A focusable control in the sheet.
    private enum Control: Hashable {
        case picker(question: String)
        case option(question: String, label: String)
    }

    /// The first question's first control, where the sheet starts.
    private var firstControl: Control? {
        guard let question = questions.first else { return nil }
        guard question.multiSelect else { return .picker(question: question.question) }
        return question.options.first.map { .option(question: question.question, label: $0.label) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ForEach(questions) { question in
                    Section {
                        // Each question is a group named by it, with the
                        // question as a heading (VO-Command-H), so VoiceOver
                        // says it on entering the choices. A radio group is
                        // already that group; checkboxes get a container.
                        if question.multiSelect {
                            VStack(alignment: .leading, spacing: QuestionsLayout.rowSpacing) {
                                QuestionHeading(text: question.question)
                                ForEach(question.options) { option in
                                    Toggle(isOn: binding(question, option)) {
                                        OptionLabel(option: option)
                                    }
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel(option.spokenLabel)
                                    .focused($focus, equals: .option(question: question.question, label: option.label))
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(question.question)
                            .accessibilityFocused($focusedQuestion, equals: question.id)
                        } else {
                            Picker(selection: binding(question)) {
                                ForEach(question.options) { option in
                                    OptionLabel(option: option).tag(Optional(option.label))
                                }
                            } label: {
                                QuestionHeading(text: question.question)
                            }
                            .pickerStyle(.radioGroup)
                            .accessibilityLabel(question.question)
                            .focused($focus, equals: .picker(question: question.question))
                            .accessibilityFocused($focusedQuestion, equals: question.id)
                        }
                    } header: {
                        if let header = question.header {
                            Text(header)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // The form scrolls. Unnamed, stepping out of it to reach the
            // buttons, VoiceOver said only "scroll area".
            .accessibilityLabel(questions.count == 1 ? "Question" : "Questions")
            .defaultFocus($focus, firstControl)
            HStack {
                Spacer()
                Button("Skip", role: .cancel) { if hasSettled { onSkip() } }
                    .keyboardShortcut(.cancelAction)
                Button("Send Answers", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding()
        }
        .frame(minWidth: QuestionsLayout.minWidth, minHeight: QuestionsLayout.minHeight)
        .task {
            // The sheet's hosting view takes first responder as it presents,
            // which overrides a focus set on appear.
            guard (try? await Task.sleep(for: Theme.accessibilityFocusDelay)) != nil else { return }
            focus = firstControl
            // VoiceOver follows only once the keyboard is in the sheet and
            // the question is in the tree, as in the changes list.
            guard (try? await Task.sleep(for: Theme.accessibilityFocusDelay)) != nil else { return }
            focusedQuestion = questions.first?.id
        }
    }

    private var isComplete: Bool { Self.isComplete(questions, picked: picked, checked: checked) }

    /// Whether every question has an answer to send: a choice, or at least
    /// one box checked. With none checked, Submit sent an empty answer,
    /// which Claude read as "none of these". Skip is there to decline.
    static func isComplete(_ questions: [UserQuestion], picked: [String: String], checked: [String: Set<String>]) -> Bool {
        questions.allSatisfy { question in
            question.multiSelect ? !(checked[question.question] ?? []).isEmpty : picked[question.question] != nil
        }
    }

    private func send() {
        guard hasSettled else { return }
        var answers: [String: [String]] = [:]
        for question in questions {
            if question.multiSelect {
                let chosen = checked[question.question] ?? []
                // Keep the order the options were offered in.
                answers[question.question] = question.options.map(\.label).filter(chosen.contains)
            } else if let choice = picked[question.question] {
                answers[question.question] = [choice]
            }
        }
        onAnswer(answers)
    }

    private func binding(_ question: UserQuestion) -> Binding<String?> {
        Binding(get: { picked[question.question] }, set: { picked[question.question] = $0 })
    }

    private func binding(_ question: UserQuestion, _ option: UserQuestion.Option) -> Binding<Bool> {
        Binding(
            get: { checked[question.question, default: []].contains(option.label) },
            set: { isOn in
                if isOn {
                    checked[question.question, default: []].insert(option.label)
                } else {
                    checked[question.question, default: []].remove(option.label)
                }
            }
        )
    }
}

private enum QuestionsLayout {
    /// Room for a question and its choices without the sheet looking cramped.
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 320
    static let rowSpacing: CGFloat = 8
}

private extension UserQuestion.Option {
    var spokenLabel: String {
        shownDescription.map { "\(label), \($0)" } ?? label
    }
}

private struct QuestionHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct OptionLabel: View {
    let option: UserQuestion.Option

    var body: some View {
        VStack(alignment: .leading) {
            Text(option.label)
            if let description = option.shownDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
            }
        }
    }
}
