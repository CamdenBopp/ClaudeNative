import AppKit
import ClaudeNativeCore
import SwiftUI

/// The side panel's Terminal: a shell in the session's folder, line-based
/// so VoiceOver can read it. Output is text with escape codes removed;
/// commands go in a field; new output is said once it settles. Programs
/// that draw a full screen (an editor, top) aren't rendered.
@MainActor
@Observable
final class TerminalModel {
    private(set) var output = TerminalText()
    private(set) var isRunning = false
    private var session: TerminalSession?
    /// Which shell the callbacks are for: output an earlier shell had
    /// already sent, arriving after a switch of folders, landed in the new
    /// shell's panel.
    private var shellID = UUID()
    private(set) var folder: URL?
    /// What VoiceOver has been told of, so each announcement is only new.
    /// How much of everything written has been spoken, counted from the
    /// start of the output, not of what's shown: the cap drops old lines
    /// from the front, and a count from the front of `shown` then pointed
    /// past the new output, which went unheard.
    private var announcedEnd = 0
    private var settle: Task<Void, Never>?
    /// Whether the panel is on screen, so new output is announced.
    var isShown = false

    /// How long output must pause before it's announced.
    static let announcementDelay: Duration = .milliseconds(700)
    /// The longest new output waits to be said while more keeps coming:
    /// output steadier than announcementDelay (ping, tail -f, a long build)
    /// restarted the pause with every chunk and was never said.
    static let maxAnnouncementWait: Duration = .seconds(3)
    /// When output not yet said first arrived.
    private var unannouncedSince: ContinuousClock.Instant?
    /// The most of new output said at once; the rest is in the panel.
    static let maxSpokenLength = 400

    func start(in folder: URL, shell: String = TerminalSession.loginShell, arguments: [String] = TerminalSession.loginArguments) {
        guard session == nil || self.folder != folder else { return }
        stop()
        self.folder = folder
        output = TerminalText()
        announcedEnd = 0
        unannouncedSince = nil
        let id = UUID()
        shellID = id
        let pending = PendingOutput()
        do {
            session = try TerminalSession(in: folder, shell: shell, arguments: arguments, output: { [weak self] chunk in
                // Collected, with one delivery to the main thread at a time:
                // a task per read buried it under a flood of output (300 ms
                // of `yes` took 138 s to clear).
                guard pending.add(chunk) else { return }
                Task { @MainActor in
                    let text = pending.take()
                    guard let self, self.shellID == id else { return }
                    self.received(text)
                }
            }, ended: { [weak self] in
                Task { @MainActor in
                    guard let self, self.shellID == id else { return }
                    self.ended()
                }
            })
            isRunning = true
            watchForSilence()
        } catch {
            output.append("Couldn't start the shell: \(error)\n")
            isRunning = false
        }
    }

    /// The last command sent, whose echo isn't announced again.
    private var lastSent: String?

    func send(_ line: String) {
        guard let session else { return }
        // A password isn't kept to be matched against output.
        lastSent = readsSecretly ? nil : line
        // A carriage return, as a terminal sends for Return: zsh echoed a
        // newline-ended command and never ran it.
        session.send(line + "\r")
    }

    func interrupt() { session?.interrupt() }

    /// The control keys a terminal sends besides Control-C: D ends input
    /// (`cat > notes` waits for it), Z suspends the job, Backslash quits it.
    static let controlKeys: [Character] = ["d", "z", "\\"]

    /// Sends what's typed, without a newline, then Control-`letter`, as a
    /// terminal does when it's pressed mid-line.
    func sendControl(_ letter: Character, after typed: String = "") {
        guard let session, let code = letter.asciiValue else { return }
        session.send(typed + String(UnicodeScalar(code & 0x1F)))
    }

    func clear() {
        output = TerminalText()
        announcedEnd = 0
    }

    func stop() {
        session?.terminate()
        session = nil
        isRunning = false
    }

    /// Whether the panel shows any text. Asked when it matters, not
    /// latched: zsh's padding can arrive split, so its "%" shows for a
    /// moment before the return that erases it.
    var hasOutput: Bool { output.shown.contains { !$0.isWhitespace } }
    /// Said and shown when a new shell writes nothing for a while.
    private(set) var waitingNote: String?

    /// How long a new shell may stay silent before the panel says why it
    /// might be. A shell whose PATH holds a folder in Desktop, Documents or
    /// Downloads waits on macOS asking for access, with nothing on screen
    /// here (seen live: zsh blocked hashing ~/Desktop/platform-tools).
    static let silenceLimit: Duration = .seconds(5)
    static let silenceNote = "The shell hasn't started yet. If macOS is asking whether ClaudeNative may access a folder, answer it and the shell carries on."

    private func watchForSilence() {
        waitingNote = nil
        Task { [weak self] in
            try? await Task.sleep(for: Self.silenceLimit)
            guard let self, self.isRunning, !self.hasOutput else { return }
            self.waitingNote = Self.silenceNote
            Announcer.announce(Self.silenceNote, urgency: .urgent)
        }
    }

    private func received(_ chunk: String) {
        output.append(chunk)
        // Checked as output arrives: a password prompt comes after echo
        // goes off, and the next output after it comes back on.
        let secret = session?.readsPassword ?? false
        if secret != readsSecretly { readsSecretly = secret }
        // Visible text, not just bytes: zsh writes its prompt's padding
        // (spaces and returns) before the hook that waits on macOS.
        if waitingNote != nil, hasOutput { waitingNote = nil }
        settle?.cancel()
        let now = ContinuousClock.now
        let since = unannouncedSince ?? now
        if now - since >= Self.maxAnnouncementWait {
            announceNew()
            return
        }
        unannouncedSince = since
        settle = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.announcementDelay)) != nil else { return }
            self?.announceNew()
        }
    }

    /// Set while the terminal doesn't echo input, as when sudo asks for a
    /// password: the command field then hides what's typed.
    private(set) var readsSecretly = false

    /// How the last shell ended, as waitpid reports it.
    private(set) var exitStatus: Int32?

    private func ended() {
        exitStatus = session?.exitStatus
        isRunning = false
        session = nil
        output.append("\n[The shell ended.]\n")
        Announcer.announce("The shell ended.")
    }

    private func announceNew() {
        unannouncedSince = nil
        let (since, announced) = output.since(announcedEnd)
        defer { announcedEnd = output.endPosition }
        guard isShown, !since.isEmpty else { return }
        var new = since.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousLine = announced.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init)
        new = TerminalAnnouncement.newOutput(new, after: lastSent, previousLine: previousLine)
        lastSent = nil
        guard !new.isEmpty else { return }
        Announcer.announce(String(new.suffix(Self.maxSpokenLength)))
    }
}

struct TerminalPanelView: View {
    let terminal: TerminalModel
    let folder: URL?
    var focusToken = 0
    /// Bumped each time the panel opens on the terminal (Command-J); the
    /// view stays alive between opens, so onAppear runs only once.
    var openRequest = 0
    @State private var command = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let note = terminal.waitingNote {
                Text(note)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .padding(Theme.Spacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.noticeFill)
            }
            TerminalOutputView(text: terminal.output.shown, dropped: terminal.output.droppedCount)
            Divider()
            HStack(spacing: Theme.Spacing.small) {
                Group {
                    // While the program has echo off (sudo asking for a
                    // password), what's typed is hidden and not spoken: in
                    // the plain field it showed and VoiceOver read it out.
                    if terminal.readsSecretly {
                        SecureField("Password", text: $command)
                            .accessibilityLabel("Password")
                    } else {
                        TextField("Command", text: $command)
                            .accessibilityLabel("Command")
                    }
                }
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($fieldFocused)
                    .onSubmit {
                        terminal.send(command)
                        command = ""
                    }
                    // Control-C in the field, as in a terminal. The Interrupt
                    // button's shortcut never fired while the field had focus
                    // (live: sleep kept running).
                    .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
                        guard press.modifiers == .control else { return .ignored }
                        terminal.interrupt()
                        return .handled
                    }
                    // Control-D, Control-Z and Control-Backslash as well, after
                    // whatever is typed: only Control-C reached the shell, so
                    // `cat > notes` couldn't be ended or a job suspended.
                    .onKeyPress(keys: Set(TerminalModel.controlKeys.map { KeyEquivalent($0) }), phases: .down) { press in
                        guard press.modifiers == .control else { return .ignored }
                        terminal.sendControl(press.key.character, after: command)
                        command = ""
                        Announcer.announce("Sent Control-\(press.key.character == "\\" ? "Backslash" : press.key.character.uppercased()).")
                        return .handled
                    }
                Button("Interrupt") { terminal.interrupt() }
                    .disabled(!terminal.isRunning)
                    .help("Interrupt (Control-C)")
                Button("Clear") { terminal.clear() }
                    .help("Clear the output")
            }
            .padding(Theme.Spacing.small)
        }
        .onAppear {
            if let folder { terminal.start(in: folder) }
            terminal.isShown = true
            // Once the view is on screen, as the side chat does: focused
            // straight away, the keyboard moved but VoiceOver's cursor
            // stayed behind (live).
            Task { @MainActor in
                try? await Task.sleep(for: SidePanelLayout.appearanceDuration)
                fieldFocused = true
            }
        }
        .onDisappear { terminal.isShown = false }
        .onChange(of: folder) { _, folder in if let folder { terminal.start(in: folder) } }
        .onChange(of: focusToken) { fieldFocused = true }
        .onChange(of: openRequest) { fieldFocused = true }
        // The secure field replaces the plain one, and focus went with it.
        // Already true, setting it again moved nothing; it's cleared, then
        // set once the new field is in the accessibility tree. Set on the
        // next turn, it was too soon with VoiceOver running: focus fell to
        // the window and the password typed went nowhere (live).
        .onChange(of: terminal.readsSecretly) {
            fieldFocused = false
            Task { @MainActor in
                try? await Task.sleep(for: Theme.accessibilityFocusDelay)
                fieldFocused = true
            }
        }
    }
}

/// Shell output read but not yet delivered to the main thread.
final class PendingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var delivering = false

    /// Adds `chunk`; true when a delivery should be scheduled, false when
    /// one already is and will take this too.
    /// The most kept waiting, in bytes: the panel shows at most
    /// TerminalText.maxLength characters, so older output waiting here
    /// would only be parsed to be dropped.
    static let keptBytes = TerminalText.maxLength * 4

    func add(_ chunk: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        text += chunk
        let utf8 = text.utf8
        if utf8.count > Self.keptBytes * 2 {
            // From a line's start, so a partial line isn't shown.
            let from = utf8.index(utf8.endIndex, offsetBy: -Self.keptBytes)
            let cut = utf8[from...].firstIndex(of: UInt8(ascii: "\n")).map { utf8.index(after: $0) } ?? from
            text = String(text[cut...])
        }
        guard !delivering else { return false }
        delivering = true
        return true
    }

    /// Everything collected so far; the next chunk schedules a new delivery.
    func take() -> String {
        lock.lock(); defer { lock.unlock() }
        let taken = text
        text = ""
        delivering = false
        return taken
    }
}

/// The output as read-only, selectable text that stays scrolled to its end
/// while you're reading the end.
struct TerminalOutputView: NSViewRepresentable {
    let text: String
    /// How many characters the output has dropped from its front in all.
    var dropped = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Theme.Spacing.small, height: Theme.Spacing.small)
        textView.setAccessibilityLabel("Terminal output")
        scrollView.drawsBackground = false
        context.coordinator.dropped = dropped
        return scrollView
    }

    final class Coordinator {
        /// The dropped count the view's text reflects.
        var dropped = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let atEnd = scrollView.isNearBottom
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if let storage = textView.textStorage {
            // Lines dropped from the front first, removed on their own: past
            // the kept length every new line drops one, the old and new text
            // then shared no start, and all of it was replaced each time.
            let gone = dropped - context.coordinator.dropped
            context.coordinator.dropped = dropped
            if gone > 0 {
                let shown = textView.string
                let cut = shown.index(shown.startIndex, offsetBy: min(gone, shown.count))
                storage.deleteCharacters(in: NSRange(location: 0, length: shown.utf16.distance(from: shown.utf16.startIndex, to: cut)))
            }
            // Only from where the text changed: new output at the end, or a
            // line rewritten in place (a progress count). Replacing all of
            // it reset the selection, and VoiceOver's place in the earlier
            // output went with it.
            let old = textView.string as NSString, new = text as NSString
            let same = Self.commonPrefixLength(old, new)
            storage.replaceCharacters(in: NSRange(location: same, length: old.length - same),
                                      with: NSAttributedString(string: new.substring(from: same), attributes: attributes))
        } else {
            textView.string = text
            textView.font = font
            textView.textColor = .labelColor
        }
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    /// How many UTF-16 units `a` and `b` share at the start, not splitting a
    /// surrogate pair.
    static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let limit = min(a.length, b.length)
        var index = 0
        while index < limit, a.character(at: index) == b.character(at: index) { index += 1 }
        if index > 0, index < limit, UTF16.isLeadSurrogate(a.character(at: index - 1)) { index -= 1 }
        return index
    }
}
