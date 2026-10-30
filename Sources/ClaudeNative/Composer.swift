import AppKit
import ClaudeNativeCore
import SwiftUI

/// The message composer: one rounded card holding the attachments, the
/// message field and its buttons, with the usage sentence underneath.
/// Every control is an ordinary SwiftUI control inside the card, so
/// VoiceOver reads them in visual order and none appear only on hover.
struct Composer: View {
    @Binding var draft: String
    @Binding var attachments: [ImageAttachment]
    var focus: FocusState<Bool>.Binding
    let isReady: Bool
    let isWorking: Bool
    let usageLimits: UsageLimits?
    let contextUsage: ContextUsage?
    let send: () -> Void
    let stop: () -> Void
    let attachImages: () -> Void
    /// The CLI's slash commands, offered while a "/" command is typed.
    var commands: [SlashCommand] = []
    /// The folder "@" lists files from; nil offers no file list.
    var mentionRoot: URL? = nil
    /// The permission mode menu at the bar's start and the model menu at
    /// its end, as the Claude app places them; absent in tests.
    var modeMenu: ModeMenu? = nil
    /// The folder menu after the mode, as the Claude app puts its folder
    /// beside the mode; absent in side chats and tests.
    var folderMenu: FolderMenu? = nil
    var modelMenu: ModelMenu? = nil
    /// What the empty field says, and so what VoiceOver calls it: the
    /// Claude app's words, which differ before and after the first message.
    var placeholder = ComposerPlaceholder.inConversation
    /// Which match the arrow keys have highlighted.
    @State private var highlighted = 0
    /// The draft Escape closed the command list for; typing reopens it.
    @State private var dismissedDraft: String?
    /// The files matching the "@" mention being typed, once looked up:
    /// the walk runs off the main thread, so it lags the typing a little.
    @State private var mentionResults: (key: MentionSearchKey, paths: [String])?
    /// Command-Plus and Command-Minus size what you type along with the
    /// conversation, and the card stays as wide as its column.
    @AppStorage(TextScale.defaultsKey) private var textScale = TextScale.standard.factor

    /// The commands matching what's typed, while a command is being typed.
    private var slashMatches: [SlashCommand]? {
        // Not before the CLI is ready: a command chosen then replaced the
        // draft, and sending it failed silently.
        guard isReady, !commands.isEmpty, draft != dismissedDraft, let query = SlashCommandSearch.query(in: draft) else { return nil }
        return SlashCommandSearch.matches(query, in: commands)
    }

    /// The mention being typed, while a file list can be offered for it.
    private var mentionQuery: String? {
        guard mentionRoot != nil, slashMatches == nil, draft != dismissedDraft else { return nil }
        return FileMentionSearch.query(in: draft)
    }

    private struct MentionSearchKey: Equatable {
        let query: String
        let root: URL
    }

    private var mentionSearchKey: MentionSearchKey? {
        guard let query = mentionQuery, let root = mentionRoot else { return nil }
        return MentionSearchKey(query: query, root: root)
    }

    /// The files for the mention being typed, once they're looked up.
    private var mentionMatches: [String]? {
        guard let key = mentionSearchKey, let results = mentionResults, results.key == key else { return nil }
        return results.paths
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        if let paths = mentionMatches {
            guard !paths.isEmpty else { return .ignored }
            highlighted = (highlighted + step + paths.count) % paths.count
            Announcer.announce(FileMentionSearch.spoken(paths[highlighted]), urgency: .urgent)
            return .handled
        }
        guard let matches = slashMatches, !matches.isEmpty else { return .ignored }
        // Wraps around, as Clarc's picker does.
        highlighted = (highlighted + step + matches.count) % matches.count
        // Urgent: it answers the key just pressed, as VoiceOver reading the
        // next row of a list would. At routine priority VoiceOver let its
        // own text field hint win (heard live).
        Announcer.announce(SlashCommandSearch.spoken(matches[highlighted]), urgency: .urgent)
        return .handled
    }

    /// Puts the file's path in the message in place of what was typed after
    /// "@"; the message isn't sent.
    private func choose(path: String) {
        draft = FileMentionSearch.completed(draft, with: path)
        // After VoiceOver's echo of the changed text: posted at once, it
        // was never heard, only the space after the path (live).
        Announcer.announceAfterFocusMove("Added \(FileMentionSearch.spoken(path)).", urgency: .urgent)
    }

    private func chooseHighlighted(sending: Bool) -> KeyPress.Result {
        if let paths = mentionMatches {
            guard paths.indices.contains(highlighted) else { return .ignored }
            choose(path: paths[highlighted])
            return .handled
        }
        guard let matches = slashMatches, matches.indices.contains(highlighted) else { return .ignored }
        choose(matches[highlighted], sending: sending)
        return .handled
    }

    /// A command that takes something after it goes in the field with a
    /// space, ready for that; one that doesn't is sent, unless Tab only
    /// completed it.
    private func choose(_ command: SlashCommand) { choose(command, sending: true) }

    private func choose(_ command: SlashCommand, sending: Bool) {
        if command.takesArgument || !sending {
            draft = command.invocation + " "
        } else {
            draft = command.invocation
            send()
        }
    }

    private var canSend: Bool {
        isReady && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    var body: some View {
        // No spacing here: the TimelineView is present even when it has no
        // sentence to show, and would otherwise add a gap under the card.
        VStack(spacing: 0) {
            card
            // Limits and context, as one sentence; reset times count down.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let status = UsageWording.sentence(limits: usageLimits, context: contextUsage, now: context.date) {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: Theme.quietLabel))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Spacing.small)
                }
            }
        }
        // The card runs no wider than a line of conversation text, centered.
        .frame(maxWidth: Theme.readingWidth(scale: textScale))
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments) { image in
                    // The pressed Remove button is gone; without this focus
                    // fell to the toolbar.
                    focus.wrappedValue = true
                    Announcer.announceAfterFocusMove("Removed \(image.name).")
                }
            }
            if let matches = slashMatches {
                SlashCommandList(matches: matches, highlighted: highlighted,
                                 query: SlashCommandSearch.query(in: draft) ?? "", choose: choose)
            } else if let paths = mentionMatches {
                FileMentionList(paths: paths, highlighted: highlighted, query: mentionQuery ?? "", choose: choose(path:))
            }
            // Draw the placeholder in the quiet label color: the system's
            // placeholder color is well under 4.5:1 in both appearances.
            TextField(
                placeholder,
                text: $draft,
                prompt: Text(""),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(.system(size: Theme.conversationTextSize(.body, scale: textScale)))
                // Keep the field named even after its placeholder goes.
                .accessibilityLabel(Text(placeholder))
                // VoiceOver uses the field's explicit label. Both a native
                // prompt and a Text overlay created another reading stop.
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        ComposerPlaceholderView(text: placeholder, fontSize: Theme.conversationTextSize(.body, scale: textScale))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .lineLimit(1...8)
                .focused(focus)
                .onSubmit(send)
                // While a command is typed the keyboard stays here, as in
                // Clarc: the arrows move the list's highlight, Tab completes,
                // Return chooses and Escape closes the list.
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.tab) { chooseHighlighted(sending: false) }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    // Return on a highlighted file puts it in the message;
                    // with no files listed it sends as usual.
                    if let paths = mentionMatches, !paths.isEmpty { return chooseHighlighted(sending: false) }
                    // Return never swaps the typed text for a command found
                    // only by its description; that sends what was typed.
                    // Tab still completes one on purpose.
                    guard let query = SlashCommandSearch.query(in: draft),
                          let matches = slashMatches, matches.indices.contains(highlighted),
                          SlashCommandSearch.nameMatches(matches[highlighted], query: query)
                    else { return .ignored }
                    return chooseHighlighted(sending: true)
                }
                .onKeyPress(.escape) {
                    if mentionMatches != nil {
                        dismissedDraft = draft
                        Announcer.announce("Files closed.")
                        return .handled
                    }
                    guard slashMatches != nil else {
                        // Escape stops Claude's response, as in the Claude
                        // app, once there's no command list to close.
                        guard isWorking else { return .ignored }
                        stop()
                        return .handled
                    }
                    dismissedDraft = draft
                    Announcer.announce("Commands closed.")
                    return .handled
                }
                .onChange(of: SlashCommandSearch.query(in: draft)) { highlighted = 0 }
                .onChange(of: mentionSearchKey) { highlighted = 0 }
                // Looks the files up, then says how many and the first,
                // as the command list does once typing pauses.
                .task(id: mentionSearchKey) {
                    guard let key = mentionSearchKey else { return }
                    let paths = await Task.detached { FileMentionSearch.matches(key.query, under: key.root) }.value
                    guard !Task.isCancelled else { return }
                    mentionResults = (key, paths)
                    guard (try? await Task.sleep(for: SlashCommandSearch.announcementDelay)) != nil, highlighted == 0 else { return }
                    let first = paths.first.map { " " + FileMentionSearch.spoken($0) } ?? ""
                    Announcer.announce(FileMentionSearch.countWording(paths.count) + first, urgency: .urgent)
                }
                // The list going and coming back for the same draft (the CLI
                // restarting) starts at the top again.
                .onChange(of: slashMatches == nil) { highlighted = 0 }
                // Escape closed the list for one draft; any change forgets it.
                .onChange(of: draft) { if draft != dismissedDraft { dismissedDraft = nil } }
                // Once typing pauses: how many match and which is first.
                // Moving the highlight cancels it: the count would cut in
                // and name the first match, not the highlighted one.
                .task(id: slashMatches == nil || highlighted != 0 ? nil : SlashCommandSearch.query(in: draft)) {
                    guard let matches = slashMatches, highlighted == 0 else { return }
                    guard (try? await Task.sleep(for: SlashCommandSearch.announcementDelay)) != nil else { return }
                    let first = matches.first.map { " " + SlashCommandSearch.spoken($0) } ?? ""
                    // Urgent for the same reason; at routine priority it went
                    // unheard behind VoiceOver's echo of the typing.
                    Announcer.announce(SlashCommandSearch.countWording(matches.count) + first, urgency: .urgent)
                }
            ComposerBarLayout {
                // The Claude app's "+": a menu of what can go with the
                // message. Images are all the CLI takes, so it says so.
                PopUpMenuButton(title: "Add", systemImage: "plus", items: [
                    ("Add Image…", attachImages),
                    ("Slash Commands", {
                        // It replaced a typed message with "/", unrecoverably.
                        if let started = SlashCommandSearch.starting(in: draft) {
                            draft = started
                        } else {
                            Announcer.announceAfterFocusMove(SlashCommandSearch.keptMessageNotice)
                        }
                        focus.wrappedValue = true
                    }),
                ] + (mentionRoot == nil ? [] : [
                    ("Mention a File", {
                        draft = FileMentionSearch.starting(in: draft)
                        focus.wrappedValue = true
                    }),
                ]))
                if let modeMenu { modeMenu }
                if let folderMenu { folderMenu }
                if let modelMenu { modelMenu.layoutValue(key: ComposerBarTrailingControl.self, value: true) }
                // After the model, as the Claude app orders them.
                if let contextUsage {
                    ContextRing(usage: contextUsage, help: UsageWording.sentence(limits: usageLimits, context: contextUsage))
                        .layoutValue(key: ComposerBarTrailingControl.self, value: true)
                }
                if isWorking {
                    Button("Stop", action: stop)
                        .fixedSize()
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop (Escape or Command-Period)")
                        .layoutValue(key: ComposerBarTrailingControl.self, value: true)
                }
                // The Claude app's borderless return arrow. A symbol rather
                // than a bordered button, which keeps its control size
                // whatever the font.
                Button("Send", systemImage: "return", action: send)
                    .labelStyle(.iconTarget(.trailing))
                    .buttonStyle(.borderless)
                    // An explicit style overrides the dimming of a disabled
                    // button, so the color says it instead: the label color
                    // when there's something to send, which reads on the card
                    // where the accent color may not.
                    .foregroundStyle(canSend ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Send (Command-Return)")
                    .layoutValue(key: ComposerBarTrailingControl.self, value: true)
            }
            // Sized with the text, so Bigger Text doesn't leave small
            // icons beside large writing. At 1x this is the buttons' own size.
            .font(.system(size: Theme.conversationTextSize(.body, scale: textScale)))
        }
        .padding(Theme.Spacing.medium)
        .background(
            Color(nsColor: Theme.composerFill),
            in: RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
        )
        .overlay(ComposerBorder(isFocused: focus.wrappedValue))
    }
}

/// A new conversation's heading, as the Claude app words it: "What's up
/// next, Sam?" by the first word of the Mac account's name. The window's
/// title already names the folder.
enum EmptyConversationWording {
    static func heading(fullName: String) -> String {
        let first = fullName.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return first.map { "What's up next, \($0)?" } ?? "What's up next?"
    }
}

/// The message field's placeholder, as the Claude app words it.
enum ComposerPlaceholder {
    /// A conversation with nothing in it yet.
    static let newConversation = "Describe a task or ask a question"
    /// Once there's a conversation, the field's other use.
    static let inConversation = "Type / for commands"
}

/// The message card's edge. The field's plain style has no focus ring, so
/// while it has keyboard focus the edge turns the accent color and
/// thickens, showing where typing goes.
/// Like a focus ring, it shows only in the active window.
struct ComposerBorder: View {
    let isFocused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let showsFocus = isFocused && activeState != .inactive
        RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
            .strokeBorder(
                showsFocus ? Color.accentColor : Color(nsColor: Theme.cardBorder),
                lineWidth: showsFocus ? Theme.focusBorderWidth : Theme.hairlineWidth
            )
    }
}

/// Images waiting to go with the next message, each removable on its own.
struct AttachmentStrip: View {
    @Binding var attachments: [ImageAttachment]
    /// Called after an image is removed, to put focus somewhere useful.
    var removed: (ImageAttachment) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(attachments) { image in
                    HStack(spacing: Theme.Spacing.xSmall) {
                        AttachmentThumbnail(attachment: image)
                        Text(image.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: AttachmentThumbnail.nameMaxWidth)
                        Button("Remove \(image.name)", systemImage: "xmark.circle.fill") {
                            attachments.removeAll { $0.id == image.id }
                            removed(image)
                        }
                        .labelStyle(.iconTarget)
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.xSmall)
                    .background(Color(nsColor: Theme.cardFill), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: Theme.hairlineWidth))
                }
            }
        }
        .scrollIndicators(.never)
        .accessibilityLabel("Attachments")
    }
}

/// What a conversation with no messages shows: a question and the next
/// steps to start from, as the Claude app's are: resuming the folder's
/// latest session, carrying on uncommitted work, or a prompt.
struct EmptyConversation: View {
    let isReady: Bool
    var steps: [NextStep] = Self.steps(latest: nil, hasChanges: false)
    let send: (String) -> Void
    var resume: (SessionHistory.SessionSummary) -> Void = { _ in }

    /// One button: a prompt to send, or a session to open again.
    enum NextStep: Equatable {
        case prompt(String, symbol: String)
        case resume(SessionHistory.SessionSummary)

        /// The longest title shown on a Resume button; VoiceOver hears it all.
        static let shownTitleLength = 40

        var title: String {
            switch self {
            case .prompt(let prompt, _): prompt
            case .resume(let session): "Resume \"\(Self.shortened(session.title))\""
            }
        }

        /// Cut at the last whole word that fits, so a word isn't left half.
        static func shortened(_ title: String) -> String {
            guard title.count > shownTitleLength else { return title }
            let cut = title.prefix(shownTitleLength)
            let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            return words + "\u{2026}"
        }

        var spokenTitle: String {
            if case .resume(let session) = self { return "Resume \"\(session.title)\"" }
            return title
        }

        var symbol: String {
            switch self {
            case .prompt(_, let symbol): symbol
            case .resume: "arrow.uturn.backward"
            }
        }
    }

    static let continueWorkPrompt = "Continue the uncommitted work in this folder: look at what's changed and carry on."

    /// Up to three: the folder's latest session to resume, uncommitted
    /// work to continue, then prompts to fill the row.
    static func steps(latest: SessionHistory.SessionSummary?, hasChanges: Bool) -> [NextStep] {
        var steps: [NextStep] = []
        if let latest { steps.append(.resume(latest)) }
        if hasChanges { steps.append(.prompt("Continue uncommitted work", symbol: "arrow.triangle.branch")) }
        for fallback in suggestions.map({ NextStep.prompt($0.prompt, symbol: $0.symbol) }) where steps.count < maxSteps {
            // Review is covered by Continue when there are changes.
            if hasChanges, case .prompt(let prompt, _) = fallback, prompt == "Review uncommitted changes" { continue }
            steps.append(fallback)
        }
        return steps
    }

    static let maxSteps = 3

    /// A starting prompt and the symbol drawn beside it. VoiceOver reads the
    /// prompt alone; the symbol only helps tell the buttons apart by eye.
    struct Suggestion {
        let prompt: String
        let symbol: String
    }

    static let suggestions = [
        Suggestion(prompt: "Explain this project", symbol: "book"),
        Suggestion(prompt: "Review uncommitted changes", symbol: "arrow.triangle.branch"),
        Suggestion(prompt: "Find likely bugs", symbol: "ladybug"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                Text(EmptyConversationWording.heading(fullName: NSFullUserName()))
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.small) { buttons }
                    VStack(spacing: Theme.Spacing.small) { buttons }
                }
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity)
        }
        // Stay centered when there is room; scroll when a large composer
        // needs the space in a short window.
        .defaultScrollAnchor(.center, for: .alignment)
        .accessibilityLabel("Session suggestions")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buttons: some View {
        ForEach(steps, id: \.title) { step in
            Button(step.title, systemImage: step.symbol) { run(step) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .fixedSize()
                .accessibilityLabel(step.spokenTitle)
                // Resuming needs no CLI; a prompt waits for it.
                .disabled(!isReady && !Self.isResume(step))
        }
    }

    private static func isResume(_ step: NextStep) -> Bool {
        if case .resume = step { return true }
        return false
    }

    private func run(_ step: NextStep) {
        switch step {
        case .resume(let session): resume(session)
        case .prompt(let prompt, _):
            send(prompt == "Continue uncommitted work" ? Self.continueWorkPrompt : prompt)
        }
    }
}


/// The commands matching what's typed, above the message field. Each row is
/// a button that reads the command and its description; the highlighted
/// one is marked selected.
struct SlashCommandList: View {
    let matches: [SlashCommand]
    let highlighted: Int
    var query = ""
    let choose: (SlashCommand) -> Void

    var body: some View {
        if matches.isEmpty {
            Text("No commands match.")
                .foregroundStyle(Color(nsColor: Theme.quietLabel))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            Button { choose(command) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                                    Text(command.invocation).fontWeight(.semibold)
                                    Text(command.description)
                                        .foregroundStyle(Color(nsColor: Theme.quietLabel))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.small)
                                .padding(.vertical, Theme.Spacing.xSmall)
                                .pickerRowHighlight(index == highlighted)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // The keyboard stays in the message field.
                            .focusable(false)
                            .accessibilityLabel(SlashCommandSearch.spoken(command))
                            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                            .id(command.id)
                        }
                    }
                }
                .frame(maxHeight: SlashListLayout.maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlighted) {
                    if matches.indices.contains(highlighted) { proxy.scrollTo(matches[highlighted].id) }
                }
                .onChange(of: query) {
                    if let first = matches.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
            .accessibilityLabel("Commands")
        }
    }
}

/// The files matching the "@" mention being typed, above the message
/// field, built as the command list is: the keyboard stays in the field.
struct FileMentionList: View {
    let paths: [String]
    let highlighted: Int
    var query = ""
    let choose: (String) -> Void

    var body: some View {
        if paths.isEmpty {
            Text(FileMentionSearch.countWording(0))
                .foregroundStyle(Color(nsColor: Theme.quietLabel))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                            Button { choose(path) } label: {
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.Spacing.small)
                                    .padding(.vertical, Theme.Spacing.xSmall)
                                    .pickerRowHighlight(index == highlighted)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .accessibilityLabel(FileMentionSearch.spoken(path))
                            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                            .id(path)
                        }
                    }
                }
                .frame(maxHeight: SlashListLayout.maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlighted) {
                    if paths.indices.contains(highlighted) { proxy.scrollTo(paths[highlighted]) }
                }
                .onChange(of: query) {
                    if let first = paths.first { proxy.scrollTo(first, anchor: .top) }
                }
            }
            .accessibilityLabel("Files")
        }
    }
}

enum SlashListLayout {
    /// About six rows at the standard size; the rest scroll.
    static let maxHeight: CGFloat = 180
}

/// A picker row the keyboard drives from the message field or a search
/// field: when highlighted, an accent tint with a label-colored edge, so the
/// row Return picks stands out by more than color.
struct PickerRowHighlight: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content.background {
            if isOn { PickerRowHighlight.shape }
        }
    }

    static var shape: some View {
        let row = RoundedRectangle(cornerRadius: Theme.Radius.card)
        return row.fill(Theme.pickerHighlight)
            .overlay(row.strokeBorder(Color(nsColor: Theme.pickerHighlightEdge), lineWidth: Theme.focusBorderWidth))
    }
}

extension View {
    func pickerRowHighlight(_ isOn: Bool) -> some View {
        modifier(PickerRowHighlight(isOn: isOn))
    }
}
