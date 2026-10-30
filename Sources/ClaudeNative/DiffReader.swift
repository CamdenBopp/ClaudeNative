import ClaudeNativeCore
import SwiftUI

private enum DiffLayout {
    /// The added/removed bar sits in the gutter, so syntax colors stay on
    /// the plain background their contrast was measured against.
    static let barWidth: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 1
    static let gutterSpacing: CGFloat = 8
    static let hunkSpacing: CGFloat = 12
    static let hunkTitleBottomPadding: CGFloat = 4
    /// The line-number column's width at 100 percent: room for four digits
    /// of body text. It grows with the text so every row's code starts at
    /// the same place.
    static let lineNumberMinWidth: CGFloat = 36

    /// A text style's font at View > Bigger Text's scale, keeping the
    /// style's own weight, so 100 percent looks as it always did.
    static func font(_ style: NSFont.TextStyle, scale: Double) -> Font {
        let system = NSFont.preferredFont(forTextStyle: style)
        let size = Theme.conversationTextSize(style, scale: scale)
        return Font(NSFont(descriptor: system.fontDescriptor, size: size) ?? system)
    }

    static func codeSize(scale: Double) -> CGFloat {
        Theme.conversationTextSize(.body, scale: scale)
    }
}

/// A file change, readable by sight and by VoiceOver.
///
/// Each change is a heading, so VoiceOver's heading navigation (VO-Command-H)
/// jumps from change to change. Each line is one element that reads its kind,
/// line number and text ("Added, line 12: let x = 1"). On screen a line shows
/// a + or − mark as well as a tint, so color is never the only cue.
struct DiffReaderView: View {
    let diff: FileDiff
    let base: URL?
    /// Move VoiceOver to the summary when the reader appears.
    var takesFocus = false
    /// Bumped by F6 to move focus back into the reader.
    var focusToken = 0
    @AccessibilityFocusState private var summaryFocused: Bool
    /// Keyboard focus on the reader, so arrows scroll it and VoiceOver (which
    /// follows keyboard focus) can leave the message field.
    @FocusState private var readerFocused: Bool
    /// View > Bigger Text and Smaller Text size the diff as they do the
    /// conversation.
    @AppStorage(TextScale.defaultsKey) private var textScale = TextScale.standard.factor

    private var language: String? {
        Highlighting.language(forPathExtension: URL(fileURLWithPath: diff.path).pathExtension)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DiffLayout.hunkSpacing) {
                Text(diff.summary(relativeTo: base))
                    .font(DiffLayout.font(.headline, scale: textScale))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($summaryFocused)
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hunk.title)
                            .font(DiffLayout.font(.subheadline, scale: textScale).weight(.semibold))
                            .foregroundStyle(Color(nsColor: Theme.quietLabel))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, DiffLayout.hunkTitleBottomPadding)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            DiffLineRow(line: line, language: language, textScale: textScale)
                        }
                    }
                }
            }
            .padding()
            .textSelection(.enabled)
        }
        .accessibilityLabel("Changes")
        .focusable()
        .focused($readerFocused)
        .task(id: focusToken) {
            // The summary must be in the accessibility tree before VoiceOver
            // can be moved to it; setting focus on appear was too early.
            guard takesFocus else { return }
            readerFocused = true
            try? await Task.sleep(for: Theme.accessibilityFocusDelay)
            summaryFocused = true
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let language: String?
    let textScale: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DiffLayout.gutterSpacing) {
            Text(line.number.map(String.init) ?? "")
                .foregroundStyle(Color(nsColor: Theme.quietLabel))
                .frame(minWidth: DiffLayout.lineNumberMinWidth * textScale, alignment: .trailing)
            Text(mark)
                .fontWeight(.bold)
            Text(code)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: DiffLayout.codeSize(scale: textScale), design: .monospaced))
        .padding(.leading, DiffLayout.barWidth + DiffLayout.gutterSpacing)
        .padding(.vertical, DiffLayout.rowVerticalPadding)
        // The bar is drawn behind the whole row, padding included. As a
        // child of the baseline-aligned row it stopped at the text baseline
        // and left the descenders' strip uncovered, at every text size.
        .background(alignment: .leading) {
            Rectangle()
                .fill(barColor)
                .frame(width: DiffLayout.barWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(line.spoken)
    }

    private var mark: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private var barColor: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .context: .clear
        }
    }

    /// One line, colored on its own; a line inside a multi-line string or
    /// comment may color differently from the file as a whole.
    private var code: AttributedString {
        let text = line.text.isEmpty ? " " : line.text
        let highlighted = Highlighting.highlight(text, language: language, fontSize: DiffLayout.codeSize(scale: textScale))
        return (try? AttributedString(highlighted, including: \.appKit)) ?? AttributedString(text)
    }
}

/// Builds a diff off the main thread; large files take a few hundred
/// milliseconds.
enum DiffLoader {
    static func load(request: PermissionRequest) async -> FileDiff? {
        await make(toolName: request.toolName, input: request.input, moment: .beforeTool)
    }

    static func load(entry: TranscriptEntry) async -> FileDiff? {
        guard case .tool(let name, let status) = entry.kind, let input = entry.toolInput else { return nil }
        return await make(toolName: name, input: input, moment: status == .succeeded ? .afterTool : .beforeTool)
    }

    private static func make(toolName: String, input: JSONValue, moment: ToolDiff.Moment) async -> FileDiff? {
        await Task.detached {
            // ToolDiff reads nil as "no such file". One that exists but isn't
            // UTF-8 text gets no diff instead: shown as a new file, writing
            // over it looked harmless.
            var unreadable = false
            let diff = ToolDiff.make(toolName: toolName, input: input, moment: moment) { path in
                if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
                if FileManager.default.fileExists(atPath: path) { unreadable = true }
                return nil
            }
            return unreadable ? nil : diff
        }.value
    }
}

/// The permission prompt for any tool: what it will do (a diff for a file
/// change, the command or summary otherwise), then Deny or Allow.
///
/// No button answers Return. A VoiceOver user pressing Return to send a
/// message as the prompt appears would otherwise approve a command they
/// never heard. Escape denies; allowing takes a press or Command-Return.
struct PermissionSheet: View {
    let request: PermissionRequest
    /// The change a file tool would make, when it could be diffed.
    let diff: FileDiff?
    let base: URL?
    /// Sends a plan back with what should change; nil offers no Revise.
    var revise: ((String) -> Void)? = nil
    /// Answers given sooner than this after the sheet appears are ignored:
    /// a double-click, a key pressed twice or held, meant for the request
    /// before, answered this one before it was read out.
    var answerDelay: Duration = PermissionSheet.answerDelay
    static let answerDelay: Duration = .milliseconds(500)
    let answer: (Bool, PermissionSuggestion?) -> Void
    @State private var shownAt = ContinuousClock.now
    private var hasSettled: Bool { ContinuousClock.now - shownAt >= answerDelay }
    private func give(_ allow: Bool, _ suggestion: PermissionSuggestion?) {
        if hasSettled { answer(allow, suggestion) }
    }
    @AppStorage(TextScale.defaultsKey) private var textScale = TextScale.standard.factor
    /// Revise… shows a field for what should change, in place of the buttons.
    @State private var revising = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    /// Deny, then each suggestion, then Allow Once, every title in full.
    /// With `splitsSuggestions`, a suggestion shows what it allows as text
    /// beside a short button instead.
    @ViewBuilder private func buttons(splitsSuggestions: Bool = false) -> some View {
        if revising, let revise {
            Button("Cancel", role: .cancel) {
                revising = false
                note = ""
            }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            Button("Send Revision") { if hasSettled { revise(note) } }
                .keyboardShortcut(.return, modifiers: .command)
                .fixedSize()
        } else {
            answerButtons(splitsSuggestions: splitsSuggestions)
        }
    }

    @ViewBuilder private func answerButtons(splitsSuggestions: Bool) -> some View {
        Button(PermissionWording.answerTitles(toolName: request.toolName).deny, role: .cancel) { give(false, nil) }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
        // The Claude app's plan card: send the plan back with a note.
        if request.isPlanApproval, revise != nil {
            Button("Revise\u{2026}") {
                revising = true
                noteFocused = true
            }
            .fixedSize()
        }
        ForEach(request.suggestions) { suggestion in
            if splitsSuggestions, let subject = suggestion.subject {
                // What the rule allows wraps beside a short button: a push
                // button never wraps, and a whole title wider than the
                // sheet pushed everything past its edges.
                HStack(alignment: .firstTextBaseline) {
                    Text(subject)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        // The button says it all to VoiceOver.
                        .accessibilityHidden(true)
                    Button(suggestion.action) { give(true, suggestion) }
                        .accessibilityLabel(suggestion.title)
                        .fixedSize()
                }
            } else {
                Button(suggestion.title) { give(true, suggestion) }
                    .fixedSize()
            }
        }
        Button(PermissionWording.answerTitles(toolName: request.toolName).allow) { give(true, nil) }
            .keyboardShortcut(.return, modifiers: .command)
            .fixedSize()
    }

    /// "Allow Claude to run git status?", as the Claude app asks.
    private var question: String {
        PermissionWording.question(toolName: request.toolName, input: request.input)
    }

    /// What the tool will do, in one line.
    private var summary: String {
        ToolSummary.shorten(ToolSummary.describe(name: request.toolName, input: request.input), relativeTo: base)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(question)
                    .font(.title2)
                    // In a short window the sheet squeezed this to one
                    // line, cutting the question off mid-command.
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                // Only when the question can't say what the tool does.
                if !PermissionWording.questionSaysTheAction(toolName: request.toolName, input: request.input) {
                    Text(PermissionWording.explanation(toolName: request.toolName))
                        .foregroundStyle(Color(nsColor: Theme.quietLabel))
                }
            }
            .padding([.top, .horizontal])
            if let diff {
                DiffReaderView(diff: diff, base: base)
            } else if request.isPlanApproval, let plan = PermissionWording.detail(toolName: request.toolName, input: request.input) {
                PlanText(markdown: plan, bodySize: Theme.conversationTextSize(.body, scale: textScale))
            } else if let detail = PermissionWording.detail(toolName: request.toolName, input: request.input) {
                // The command or path alone, on a card like a reply's code:
                // the title already names the tool.
                ScrollView {
                    Text(detail)
                        .font(.system(size: Theme.conversationTextSize(.body, scale: textScale), design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.medium)
                        .background(Color(nsColor: Theme.cardFill), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.card)
                                .strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: Theme.hairlineWidth)
                        )
                        .padding()
                }
                .frame(maxHeight: PermissionLayout.maxDetailHeight)
                .fixedSize(horizontal: false, vertical: true)
                // Named by the command, so VoiceOver reads it on arrival.
                // Unnamed it only said "scroll area", with the command one
                // level down.
                .accessibilityLabel(detail)
            } else {
                Spacer(minLength: Theme.Spacing.medium).fixedSize()
            }
            Divider()
            if revising, let revise {
                TextField("What should change? (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .onSubmit { if hasSettled { revise(note) } }
                    .padding([.top, .horizontal])
            }
            // A row when every title fits whole, then a column. Cut to
            // "Always Allow to...", a suggestion hides what it allows, so
            // when even the column is too narrow the rule moves out of the
            // button into text that wraps.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer()
                    buttons()
                }
                VStack(alignment: .trailing) {
                    buttons()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .trailing) {
                    buttons(splitsSuggestions: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding()
        }
        // VoiceOver starts on the safe Deny button; say what's being asked,
        // once per request, so the question isn't skipped.
        .task(id: request.requestID) {
            Announcer.announce("\(question) \(summary)", urgency: .urgent)
        }
        .frame(
            minWidth: PermissionLayout.minWidth, idealWidth: PermissionLayout.idealWidth,
            // A diff or a plan gets room to read.
            minHeight: diff == nil && !request.isPlanApproval ? nil : PermissionLayout.diffMinHeight,
            idealHeight: diff == nil && !request.isPlanApproval ? nil : PermissionLayout.diffIdealHeight
        )
    }
}

private enum PermissionLayout {
    static let minWidth: CGFloat = 560
    static let idealWidth: CGFloat = 720
    /// A diff gets room to read; a command sheet fits its content.
    static let diffMinHeight: CGFloat = 360
    static let diffIdealHeight: CGFloat = 520
    /// A long command scrolls past this instead of growing the sheet.
    static let maxDetailHeight: CGFloat = 320
}
