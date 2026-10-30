import AppKit
import ClaudeNativeCore
import CodeHighlighting
import Observation
import SwiftUI

private enum EditorLayout {
    /// Room for a screenful of code with its line numbers.
    static let minWidth: CGFloat = 480
    static let minHeight: CGFloat = 320
    static let textInset = NSSize(width: 8, height: 8)
    /// How far the side panel's content sits from its edge: SwiftUI's
    /// standard padding, which the diff reader and changes list use.
    static let contentEdge = Theme.Spacing.large
    /// The line-number column's width at 100 percent, the diff reader's
    /// (room for four digits), so a file and its changes number their lines
    /// alike. It scales with the text and widens when the file needs more
    /// digits.
    static let lineNumberMinWidth: CGFloat = 36
    /// The gap between a line's number and its text, the diff reader's
    /// gutter spacing.
    static let lineNumberSpacing = Theme.Spacing.small
    /// Pause in typing before the text is highlighted again.
    static let rehighlightDelay: Duration = .milliseconds(250)
    /// When to repeat the focus notice for VoiceOver after a layout change.
    static let focusRepostDelay: Duration = .milliseconds(500)
}

/// Asks what to do with edits not yet saved, as a Mac app does before
/// quitting: Save, Cancel, or Don't Save (Command-D).
@MainActor
enum UnsavedChanges {
    enum Choice { case save, cancel, discard }

    static func ask(about documents: [EditorDocument], closing: Bool = false) -> Choice {
        let alert = NSAlert()
        let names = documents.map(\.title)
        let when = closing ? "closing" : "quitting"
        alert.messageText = names.count == 1
            ? "Save changes to \(names[0]) before \(when)?"
            : "Save changes to \(names.count) files before \(when)?"
        alert.informativeText = names.count == 1
            ? "Your changes are lost if you don't save them."
            : "\(names.joined(separator: ", ")). Your changes are lost if you don't save them."
        alert.addButton(withTitle: names.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

/// Asks before a window closes on edits not yet saved: closing dropped
/// them without a word. SwiftUI owns the window's delegate, so this stands
/// in front of it, answers windowShouldClose, and passes the rest on.
struct CloseGuard: NSViewRepresentable {
    let unsaved: @MainActor () -> [EditorDocument]

    func makeNSView(context: Context) -> Probe { Probe(unsaved: unsaved) }
    func updateNSView(_ view: Probe, context: Context) { view.proxy.unsaved = unsaved }

    final class Probe: NSView {
        let proxy: Proxy
        init(unsaved: @escaping @MainActor () -> [EditorDocument]) {
            proxy = Proxy(unsaved: unsaved)
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== proxy else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }

    @MainActor
    final class Proxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        var unsaved: @MainActor () -> [EditorDocument]

        init(unsaved: @escaping @MainActor () -> [EditorDocument]) { self.unsaved = unsaved }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let documents = unsaved()
            if !documents.isEmpty {
                switch UnsavedChanges.ask(about: documents, closing: true) {
                case .cancel:
                    return false
                case .discard:
                    break
                case .save:
                    documents.forEach { $0.save() }
                    // One that stopped has said why; closing would lose it.
                    guard documents.allSatisfy({ !$0.isDirty }) else { return false }
                }
            }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}

/// One open file: its text, where it lives, and whether it has unsaved edits.
@MainActor
@Observable
final class EditorDocument {
    let url: URL
    private(set) var text = ""
    private(set) var isDirty = false
    private(set) var loadError: String?
    /// Set when the file changed on disk while there were unsaved edits.
    private(set) var changedOnDisk = false
    /// Set when Save found the file changed since it was opened; nothing
    /// was written.
    private(set) var saveConflict = false
    /// Bumped when the text is replaced from disk, so the view reloads.
    private(set) var reloadToken = 0
    /// Where the caret was, so an editor built again (Back, Expand Panel)
    /// or reloaded after Claude's edit puts it back instead of on line 1.
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    /// The file's contents as last read or written, to tell our edits from
    /// someone else's (Claude's, usually).
    private var diskText: String?
    /// The file began with a UTF-8 byte order mark, which reading drops
    /// and saving puts back.
    private var hasByteOrderMark = false
    /// The file's lines end in CRLF, as a Windows-style file's do. Return
    /// types a bare newline, so saving puts CRLF back on every line; a
    /// line added to such a file was saved LF among CRLF lines.
    private var usesCRLF = false
    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
    private var watcher: FileWatcher?

    /// Every document still open, in the panel or an editor window.
    private static let open = NSHashTable<EditorDocument>.weakObjects()

    /// Open documents with edits not yet saved, for quitting to ask about.
    static var unsaved: [EditorDocument] { open.allObjects.filter(\.isDirty) }

    init(url: URL) {
        self.url = url
        load()
        Self.open.add(self)
        watcher = FileWatcher(file: url) { [weak self] in
            self?.checkDisk()
        }
    }

    var title: String { url.lastPathComponent }

    func load() {
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            usesCRLF = Self.endsLinesWithCRLF(text)
            hasByteOrderMark = (try? FileHandle(forReadingFrom: url).read(upToCount: Self.byteOrderMark.count)) == Self.byteOrderMark
            diskText = text
            isDirty = false
            changedOnDisk = false
            saveConflict = false
            loadError = nil
            reloadToken += 1
        } catch {
            loadError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// The view reports each edit here. Undoing back to the text on disk
    /// leaves nothing to save.
    func edited(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = newText != diskText
    }

    /// Writes the text, unless the file changed since it was opened; then it
    /// stops and says so, so Claude's edits are never silently overwritten.
    func save() {
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        if !Self.sameText(onDisk, diskText), !(onDisk == nil && diskText == nil) {
            saveConflict = true
            Announcer.announce("\(title) changed on disk since you opened it. Nothing was saved.", urgency: .urgent)
            return
        }
        write()
    }

    /// Saves over whatever is on disk, after the user chose to.
    func saveAnyway() {
        write()
    }

    private func write() {
        // A file that exists but wasn't read as text holds something the
        // editor never showed; written over, it was replaced by whatever
        // had been typed into the empty view.
        guard diskText != nil || !FileManager.default.fileExists(atPath: url.path) else {
            loadError = "Couldn't save \(title): it isn't UTF-8 text, so saving would replace what's in it."
            Announcer.announce(loadError ?? "", urgency: .urgent)
            return
        }
        // A locked file stays as it is: the atomic write swaps in a new
        // file, which its permissions don't stop.
        let target = url.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: target.path), !FileManager.default.isWritableFile(atPath: target.path) {
            loadError = "Couldn't save \(title): it's read-only."
            Announcer.announce(loadError ?? "", urgency: .urgent)
            return
        }
        do {
            // To where a link points: written atomically to the link's own
            // path, the link became a copy and the real file stayed as it was.
            let written = usesCRLF ? Self.withCRLF(text) : text
            let data = (hasByteOrderMark ? Self.byteOrderMark : Data()) + Data(written.utf8)
            // A file with other hard links is written in place: the atomic
            // write swaps in a new file, and the other links kept the old text.
            let links = (try? FileManager.default.attributesOfItem(atPath: target.path)[.referenceCount] as? Int) ?? 1
            try data.write(to: target, options: links > 1 ? [] : .atomic)
            diskText = text
            isDirty = false
            changedOnDisk = false
            saveConflict = false
            Announcer.announce("Saved \(title).")
        } catch {
            loadError = "Couldn't save \(title): \(error.localizedDescription)"
            Announcer.announce(loadError ?? "", urgency: .urgent)
        }
    }

    /// Whether most of the file's line breaks are CRLF.
    static func endsLinesWithCRLF(_ text: String) -> Bool {
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let all = text.components(separatedBy: "\n").count - 1
        return crlf > 0 && crlf * 2 >= all
    }

    static func withCRLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// The same text whatever its line endings: a CRLF file saved from text
    /// typed with bare newlines is still what the editor shows.
    static func sameText(_ a: String?, _ b: String?) -> Bool {
        a?.replacingOccurrences(of: "\r\n", with: "\n") == b?.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Picks up edits Claude made to the file. Unsaved edits are never
    /// overwritten; the editor says the file changed instead.
    func checkDisk() {
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8), !Self.sameText(onDisk, diskText) else { return }
        if isDirty {
            if !changedOnDisk { Announcer.announce("\(title) changed on disk while you were editing it.", urgency: .urgent) }
            changedOnDisk = true
        } else {
            load()
            Announcer.announce("\(title) changed on disk and was reloaded.")
        }
    }
}

/// Calls back on the main actor shortly after a file changes, whether it is
/// written in place or replaced by a rename (as atomic saves do).
@MainActor
final class FileWatcher {
    /// Edits come in bursts (write, rename, attribute change); one check
    /// after they settle is enough.
    private static let settleDelay: Duration = .milliseconds(150)
    private let file: URL
    private let onChange: @MainActor () -> Void
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        self.file = file
        self.onChange = onChange
        // The folder sees renames and new files; the file itself sees
        // writes made in place.
        folderSource = watch(file.deletingLastPathComponent(), events: [.write]) { [weak self] in
            self?.reattachFile()
            self?.changed()
        }
        reattachFile()
    }

    deinit {
        folderSource?.cancel()
        fileSource?.cancel()
    }

    /// The file may be a new one after a rename; watch whatever is at the path now.
    private func reattachFile() {
        fileSource?.cancel()
        fileSource = watch(file, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.changed()
        }
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.reattachFile()
            self.onChange()
        }
    }

    private func watch(
        _ url: URL,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

/// A window for one file. Opened with `openWindow(value: url)`.
/// A document the side panel hands to the editor window it opens, edits
/// and all, which the window takes as it starts.
@MainActor
enum EditorHandoff {
    static var pending: [URL: EditorDocument] = [:]

    static func take(_ url: URL) -> EditorDocument? { pending.removeValue(forKey: url) }
}

struct EditorWindow: View {
    let url: URL
    @State private var document: EditorDocument?

    var body: some View {
        Group {
            if let document {
                EditorPane(document: document)
                    .background(CloseGuard { document.isDirty ? [document] : [] })
                    .navigationTitle(document.title)
                    .navigationSubtitle(document.isDirty ? "Edited" : "")
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                        document.checkDisk()
                    }
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: EditorLayout.minWidth, minHeight: EditorLayout.minHeight)
        .task(id: url) { document = EditorHandoff.take(url) ?? EditorDocument(url: url) }
    }
}

/// One file being edited: the text, a notice when it changed on disk, and a
/// status line. Shown in an editor window or in the side panel.
struct EditorPane: View {
    let document: EditorDocument
    /// Move keyboard focus into the text when the pane appears.
    var takesFocus = false
    /// Each change moves keyboard focus into the text again.
    var focusToken = 0
    /// In the side panel, Save sits in the panel's header instead: a
    /// toolbar item there joins the window's toolbar and stays after the
    /// panel closes.
    var savesFromToolbar = true
    @State private var position = "Line 1, column 1"
    /// View > Bigger Text and Smaller Text size the code as they do the
    /// conversation.
    @AppStorage(TextScale.defaultsKey) private var textScale = TextScale.standard.factor

    var body: some View {
        VStack(spacing: 0) {
            if document.saveConflict {
                HStack {
                    Text("This file changed on disk since you opened it, so it wasn't saved.")
                    Spacer()
                    Button("Use the Version on Disk", action: document.load)
                    Button("Save Anyway", action: document.saveAnyway)
                }
                .padding(Theme.Spacing.small)
                .background(Theme.noticeFill)
            } else if document.changedOnDisk {
                HStack {
                    Text("This file changed on disk while you were editing it.")
                    Spacer()
                    Button("Use the Version on Disk", action: document.load)
                }
                .padding(Theme.Spacing.small)
                .background(Theme.noticeFill)
            }
            if let error = document.loadError {
                Text(error)
                    .foregroundStyle(Color(nsColor: Theme.errorText))
                    .padding(Theme.Spacing.small)
            }
            CodeTextView(
                document: document, position: $position, takesFocus: takesFocus, focusToken: focusToken,
                textScale: textScale
            )
            Divider()
            HStack {
                Text(position)
                Spacer()
                Text(document.isDirty ? "Edited" : "Saved")
            }
            .font(.callout)
            .foregroundStyle(Color(nsColor: Theme.quietLabel))
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xSmall)
            .accessibilityElement(children: .combine)
        }
        .toolbar {
            if savesFromToolbar {
                SaveButton(document: document)
            }
        }
    }
}

/// Saves the file with Command-S; dimmed while there's nothing to save.
struct SaveButton: View {
    let document: EditorDocument

    var body: some View {
        Button("Save", systemImage: "square.and.arrow.down", action: document.save)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!document.isDirty)
    }
}

/// NSTextView as a plain-text code editor. It keeps AppKit's own text
/// accessibility, so VoiceOver reads and moves through it by character,
/// word and line as in any Mac text editor.
struct CodeTextView: NSViewRepresentable {
    let document: EditorDocument
    @Binding var position: String
    var takesFocus = false
    var focusToken = 0
    var textScale = TextScale.standard.factor

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = FocusableTextView(usingTextLayoutManager: true)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        // VoiceOver should land on the text, not on a scroll area around it.
        scrollView.setAccessibilityElement(false)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // The line numbers start where the panel's other content does (the
        // diff summary, the changes list), at the content edge; the text
        // follows them after the diff reader's gap, less the padding the
        // text container adds itself.
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        textView.textContainerInset = NSSize(
            width: EditorLayout.lineNumberSpacing - padding, height: EditorLayout.textInset.height
        )
        let font = Self.font(scale: textScale)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        textView.setAccessibilityLabel(document.title)
        textView.delegate = context.coordinator
        // Every change to the characters, typed or set through
        // accessibility, reaches the storage; the view's own text-change
        // callback misses the latter.
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.textScale = textScale
        let gutter = LineNumberGutter(textView: textView, scrollView: scrollView, font: font, scale: textScale)
        let container = EditorContainerView(gutter: gutter, scrollView: scrollView)
        context.coordinator.gutter = gutter
        context.coordinator.focusToken = focusToken
        context.coordinator.load()
        // The view isn't in a window yet; it takes focus when it joins one.
        textView.wantsFocusInWindow = takesFocus
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedToken != document.reloadToken {
            context.coordinator.load()
        }
        context.coordinator.rescale(to: textScale)
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            if let textView = context.coordinator.textView as? FocusableTextView, let window = textView.window {
                textView.takeFocus(in: window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The code's font: the body size at View > Bigger Text's scale, so 100
    /// percent is the system body size it always was.
    static func font(scale: Double) -> NSFont {
        .monospacedSystemFont(ofSize: Theme.conversationTextSize(.body, scale: scale), weight: .regular)
    }

    /// A highlighted copy made off the main thread and handed to it once,
    /// never changed after: NSAttributedString isn't Sendable.
    struct Handoff: @unchecked Sendable {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    /// Past this many UTF-16 units a file is shown plain: highlighting one
    /// is seconds of work per edit for colors no one reads at that size.
    static let maxHighlightedLength = 1_000_000

    /// Lays colors worked out off the main thread onto the text, if it's
    /// still the text they were worked out for. The characters aren't
    /// replaced, so the caret, selection, undo history and VoiceOver's
    /// position stay where they are.
    static func apply(_ highlighted: NSAttributedString, to storage: NSTextStorage, font: NSFont) {
        guard highlighted.string == storage.string else { return }
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: whole)
        storage.addAttribute(.font, value: font, range: whole)
        highlighted.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
            storage.addAttribute(.foregroundColor, value: color ?? NSColor.textColor, range: range)
        }
        storage.endEditing()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CodeTextView
        weak var textView: NSTextView?
        weak var gutter: LineNumberGutter?
        var loadedToken = -1
        var focusToken = 0
        /// The scale the text is drawn at.
        var textScale = TextScale.standard.factor
        var font: NSFont { CodeTextView.font(scale: textScale) }
        /// True while the editor itself replaces the text or recolors it.
        private var isApplyingOwnChange = false
        private var highlightTask: Task<Void, Never>?

        init(parent: CodeTextView) {
            self.parent = parent
        }

        var language: String? {
            Highlighting.language(forPathExtension: parent.document.url.pathExtension)
        }

        func load() {
            guard let textView else { return }
            loadedToken = parent.document.reloadToken
            isApplyingOwnChange = true
            textView.string = parent.document.text
            if let storage = textView.textStorage {
                // Plain at once, colored once worked out off the main thread:
                // highlighting a 5 MB file here froze the app for 10 s.
                let whole = NSRange(location: 0, length: storage.length)
                storage.addAttributes([.font: font, .foregroundColor: NSColor.textColor], range: whole)
            }
            isApplyingOwnChange = false
            highlight(after: .zero)
            // Where the caret last was, within the text as it is now: a file
            // reopened or reloaded after Claude's edit kept the user's
            // place, where it went to line 1 before. New files start at 0.
            let length = (textView.string as NSString).length
            let kept = parent.document.selection
            let location = min(kept.location, length)
            let caret = NSRange(location: location, length: min(kept.length, length - location))
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)
            // The old history undoes a text that's been replaced.
            textView.undoManager?.removeAllActions()
            report(textView)
        }

        /// Sets the text's font for a new scale in place: only the font
        /// attribute changes, so the characters, colors, caret, selection and
        /// undo history are the ones the user had.
        func rescale(to scale: Double) {
            guard scale != textScale, let textView else { return }
            textScale = scale
            let font = self.font
            textView.typingAttributes[.font] = font
            guard let storage = textView.textStorage else { return }
            isApplyingOwnChange = true
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            isApplyingOwnChange = false
            gutter?.setFont(font, scale: scale)
        }

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                gutter?.textDidChange()
                charactersChanged()
            }
        }

        private func charactersChanged() {
            guard !isApplyingOwnChange, let textView else { return }
            parent.document.edited(textView.string)
            highlight(after: EditorLayout.rehighlightDelay)
        }

        /// Colors the text after `delay`, working the colors out off the
        /// main thread; an edit meanwhile starts it again. A file past
        /// maxHighlightedLength stays plain.
        private func highlight(after delay: Duration) {
            highlightTask?.cancel()
            guard let storage = textView?.textStorage, storage.length <= CodeTextView.maxHighlightedLength else { return }
            highlightTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let storage = self.textView?.textStorage else { return }
                let (text, language, size) = (storage.string, self.language, self.font.pointSize)
                let colored = await Task.detached(priority: .userInitiated) {
                    Handoff(Highlighting.highlight(text, language: language, fontSize: size))
                }.value
                guard !Task.isCancelled, let storage = self.textView?.textStorage else { return }
                CodeTextView.apply(colored.value, to: storage, font: self.font)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            if !isApplyingOwnChange { parent.document.selection = textView.selectedRange() }
            report(textView)
            // The caret's line number is drawn in the label color.
            gutter?.needsDisplay = true
        }

        private func report(_ textView: NSTextView) {
            let position = CaretPosition.lineAndColumn(in: textView.string, utf16Offset: textView.selectedRange().location)
            parent.position = "Line \(position.line), column \(position.column)"
        }
    }
}

/// The line-number gutter and the scrolling text, side by side.
///
/// The gutter is a sibling of the scroll view rather than its vertical
/// ruler. NSScrollView builds its accessibility children through AppKit's
/// legacy path, which inserts each ruler's first accessible descendant. A
/// gutter hidden from VoiceOver has none, and AppKit throws on the nil:
/// walking the editor's accessibility tree crashed the hosted tests. A
/// plain view's children skip a hidden subview, so the tree stays what it
/// was: the text and its scroll bar.
final class EditorContainerView: NSView {
    let gutter: LineNumberGutter
    let scrollView: NSScrollView

    init(gutter: LineNumberGutter, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        gutter.onThicknessChange = { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let thickness = gutter.thickness
        gutter.frame = NSRect(x: 0, y: 0, width: thickness, height: bounds.height)
        scrollView.frame = NSRect(x: thickness, y: 0, width: max(bounds.width - thickness, 0), height: bounds.height)
    }
}

/// The editor's line numbers, drawn beside the text. Each logical line gets
/// one number, right-aligned on the baseline of the line's first line
/// fragment, so a wrapped line is numbered once. The numbers are quiet; the
/// caret's line is in the label color.
///
/// The gutter is only a picture of the text's layout. VoiceOver never sees
/// it: the status line below the editor speaks the line and column.
final class LineNumberGutter: NSView {
    /// One number as drawn, with its baseline in the gutter's coordinates.
    struct Mark: Equatable {
        let number: Int
        let baseline: CGFloat
        let isCurrent: Bool
    }

    private weak var textView: NSTextView?
    private(set) var font: NSFont
    private var scale: Double
    /// Where each logical line starts, as UTF-16 offsets, split the way
    /// TextKit splits paragraphs. A text ending in a line break has an empty
    /// last line.
    private var lineStarts: [Int] = [0]
    private weak var scrollView: NSScrollView?
    /// The width the gutter was last laid out for.
    private var laidOutThickness: CGFloat = 0
    /// Tells the container to lay the gutter and text out again.
    var onThicknessChange: () -> Void = {}

    init(textView: NSTextView, scrollView: NSScrollView, font: NSFont, scale: Double) {
        self.textView = textView
        self.scrollView = scrollView
        self.font = font
        self.scale = scale
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(false)
        recountLines()
        laidOutThickness = thickness
        // Redraw as the text scrolls or rewraps.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutMoved), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutMoved), name: NSView.frameDidChangeNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // Visual only: the text view carries the lines for VoiceOver.
    override func isAccessibilityElement() -> Bool { false }

    /// A scroll over the numbers scrolls the text, as it would over a ruler.
    override func scrollWheel(with event: NSEvent) {
        scrollView?.scrollWheel(with: event)
    }

    @objc private func layoutMoved() { needsDisplay = true }

    /// View > Bigger Text and Smaller Text: the numbers at the code's new size.
    func setFont(_ font: NSFont, scale: Double) {
        self.font = font
        self.scale = scale
        updateThickness()
        needsDisplay = true
    }

    /// The characters changed. Recount the lines now; widen or narrow the
    /// gutter after the edit finishes, if the count gained or lost a digit.
    func textDidChange() {
        recountLines()
        needsDisplay = true
        // On the next run loop pass, once the storage has finished this
        // edit, so the text view isn't resized in the middle of it. (A
        // task would wait for the main actor, which a hosted test holds.)
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.updateThickness() }
        }
    }

    /// The width the numbers need: the diff reader's column at this scale,
    /// or the file's widest number if that is wider. Whole points, so the
    /// text's edge lands on a pixel: at 130 percent the column was 46.8
    /// points and the half-covered pixel column showed as a light seam.
    var numberColumnWidth: CGFloat {
        let widest = String(repeating: "8", count: String(lineStarts.count).count) as NSString
        let measured = widest.size(withAttributes: [.font: font]).width
        return ceil(max(EditorLayout.lineNumberMinWidth * scale, measured))
    }

    /// The gutter's whole width: the panel's content edge, then the numbers.
    var thickness: CGFloat { EditorLayout.contentEdge + numberColumnWidth }

    private func updateThickness() {
        guard laidOutThickness != thickness else { return }
        laidOutThickness = thickness
        onThicknessChange()
    }

    private func recountLines() {
        let text = (textView?.string ?? "") as NSString
        var starts = [0]
        var location = 0
        while location < text.length {
            location = NSMaxRange(text.paragraphRange(for: NSRange(location: location, length: 0)))
            if location < text.length { starts.append(location) }
        }
        if text.length > 0, let last = Unicode.Scalar(text.character(at: text.length - 1)),
           CharacterSet.newlines.contains(last) {
            starts.append(text.length)
        }
        lineStarts = starts
    }

    /// The 1-based line holding a UTF-16 offset.
    private func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(low, 1)
    }

    /// The numbers for the lines in view, top to bottom, read from the
    /// text's own layout: a line fragment that starts a logical line gets
    /// that line's number on its baseline.
    func marks() -> [Mark] {
        guard let textView, let layout = textView.textLayoutManager,
              let content = layout.textContentManager else { return [] }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let documentStart = layout.documentRange.location
        let top = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let start = layout.textLayoutFragment(for: top)?.rangeInElement.location ?? documentStart
        let currentLine = line(containing: textView.selectedRange().location)
        var marks: [Mark] = []
        let options: NSTextLayoutFragment.EnumerationOptions = [.ensuresLayout, .ensuresExtraLineFragment]
        layout.enumerateTextLayoutFragments(from: start, options: options) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY + origin.y < visible.maxY else { return false }
            let fragmentOffset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            for lineFragment in fragment.textLineFragments {
                let offset = fragmentOffset + lineFragment.characterRange.location
                let number = line(containing: offset)
                // A wrapped line's later fragments don't start a line.
                guard lineStarts[number - 1] == offset, marks.last?.number != number else { continue }
                let bounds = lineFragment.typographicBounds
                let baseline = origin.y + frame.minY + bounds.minY + lineFragment.glyphOrigin.y
                // Only lines at least partly in view.
                let lineTop = origin.y + frame.minY + bounds.minY
                guard lineTop < visible.maxY, lineTop + bounds.height > visible.minY else { continue }
                let inGutter = convert(NSPoint(x: 0, y: baseline), from: textView).y
                marks.append(Mark(number: number, baseline: inGutter, isCurrent: number == currentLine))
            }
            return true
        }
        return marks
    }

    override func draw(_ dirtyRect: NSRect) {
        // One surface with the text: no background or edge line of its own.
        // Views don't clip to their bounds by default, and the dirty rect
        // can reach past them; filling all of it painted over the editor's
        // header.
        (textView?.backgroundColor ?? .textBackgroundColor).setFill()
        dirtyRect.intersection(bounds).fill()
        let right = EditorLayout.contentEdge + numberColumnWidth
        for mark in marks() {
            let label = NSAttributedString(string: String(mark.number), attributes: [
                .font: font,
                .foregroundColor: mark.isCurrent ? NSColor.labelColor : Theme.quietLabel,
            ])
            let width = label.size().width
            // Without .usesLineFragmentOrigin, the rect's origin is the
            // baseline's start.
            label.draw(with: NSRect(x: right - width, y: mark.baseline, width: width, height: 0), options: [])
        }
    }
}

/// A text view that can take keyboard focus as soon as it is in a window;
/// asking before then does nothing.
final class FocusableTextView: NSTextView {
    var wantsFocusInWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocusInWindow, let window else { return }
        wantsFocusInWindow = false
        takeFocus(in: window)
    }

    /// Becomes first responder and tells VoiceOver, which otherwise stops
    /// on the enclosing scroll area instead of the text.
    func takeFocus(in window: NSWindow) {
        guard window.makeFirstResponder(self) else { return }
        announceFocus()
        // The first time the side panel opens, its views are new to
        // VoiceOver, which ignores a focus change it can't place yet. Tell it
        // the layout changed, then say it again once the panel has settled.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: EditorLayout.focusRepostDelay)
            guard let self, self.window?.firstResponder === self else { return }
            self.announceFocus()
        }
    }

    private func announceFocus() {
        if let window { NSAccessibility.post(element: window, notification: .layoutChanged) }
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
}

/// The one place the app turns code into colored text, so the editor, the
/// diff reader and code blocks in replies all look the same.
enum Highlighting {
    static func highlight(_ code: String, language: String?, fontSize: CGFloat) -> NSAttributedString {
        CodeHighlighter.highlight(code, language: language, fontSize: fontSize)
    }

    static func language(forPathExtension ext: String) -> String? {
        CodeHighlighter.language(forPathExtension: ext)
    }
}
