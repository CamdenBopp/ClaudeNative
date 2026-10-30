import AppKit
import ChatMarkdownAppKit
import ChatMarkdownCore
import ClaudeNativeCore
import SwiftUI

enum TranscriptLayout {
    /// Space between rows within a turn.
    static let rowSpacing = Theme.Spacing.small
    /// How late a running tool's time may move, so the timer can share a
    /// wakeup with other work.
    static let elapsedTickTolerance: TimeInterval = 0.1
    /// Space before your message, which starts a new turn.
    static let turnSpacing = Theme.Spacing.xLarge
    /// The least space between the column and the window's edges, and above
    /// and below the conversation.
    static let columnInset = Theme.Spacing.large
    /// How close to the bottom counts as "following along" for autoscroll.
    static let followThreshold: CGFloat = 40
    /// The space inside a code block's card, around its text.
    static let codePadding = Theme.Spacing.medium
    /// The space between a code block's card and the text above and below.
    static let codeMargin = Theme.Spacing.small
    /// The space between a code card's language caption and its code.
    static let codeCaptionGap = Theme.Spacing.xSmall
    /// How many rows a saved conversation opens with, and how many more
    /// Show Earlier Messages adds. Rows cost about 0.35 MB and their build
    /// time grows faster than their number: 250 took 1.7 seconds and 1,000
    /// took 11, and a 5,642-row conversation grew the app past 3.7 GB until
    /// macOS killed it.
    static let pageSize = 200
}

/// The conversation as AppKit views. Each shown entry gets one
/// `MessageRowView` that lives as long as the conversation: rows are never
/// recycled or rebuilt, so the accessibility element VoiceOver holds (for a
/// hot spot, say) stays valid while the conversation grows and scrolls. A
/// long saved conversation shows its latest page; earlier pages are added
/// above it on request.
struct TranscriptView: NSViewRepresentable {
    let transcript: Transcript
    let revision: Int
    /// Tool rows name paths relative to this folder.
    let workingDirectory: URL?
    /// While a turn runs, its last reply may still grow.
    let isWorking: Bool
    /// Opens a file a tool row names, in the editor.
    var openFile: (URL) -> Void = { _ in }
    /// The conversation's id, which keys its saved marks and where it was
    /// being read.
    var sessionID: String? = nil
    var positionStore = TranscriptPositionStore.shared
    /// Opens a file in its own editor window.
    var openInNewWindow: (URL) -> Void = { _ in }
    /// Shows what a file tool row changed.
    var showChanges: (TranscriptEntry) -> Void = { _ in }
    /// The Command-Plus/Command-Minus scale for the conversation's text.
    var textScale: Double = TextScale.standard.factor
    /// Where the Go menu's message moves arrive.
    var navigator: MessageNavigator? = nil
    /// View > Show Tool Output: each tool's output under its summary.
    var showsToolOutput = false

    func makeNSView(context: Context) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = TranscriptLayout.rowSpacing
        // Hidden views stay attached: detaching them had the stack watch
        // every row and re-solve more on each change, 70 ms against 46 per
        // streaming update with 200 rows. Show Earlier collapses instead.
        stack.detachesHiddenViews = false
        // The column's sides come from the constraints below, so the stack
        // only pads its top and bottom.
        stack.edgeInsets = NSEdgeInsets(
            top: TranscriptLayout.columnInset, left: 0,
            bottom: TranscriptLayout.columnInset, right: 0
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = FollowingScrollView()
        scrollView.hasVerticalScroller = true
        // With keyboard navigation on, Tab otherwise stops on the bare
        // scroll bar between the sidebar and the message field.
        scrollView.verticalScroller?.refusesFirstResponder = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.setAccessibilityLabel("Conversation")
        // VO-U lists these: jump between messages, your own messages, or
        // tool calls without stepping through every row.
        scrollView.setAccessibilityCustomRotors(context.coordinator.rotors)

        // A centered reading column: as wide as the window allows, less an
        // inset on each side, up to the reading width. Constraints keep it
        // centered as the window resizes.
        let fillWidth = stack.widthAnchor.constraint(
            equalTo: document.widthAnchor, constant: -2 * TranscriptLayout.columnInset
        )
        fillWidth.priority = .defaultHigh
        let columnLimit = stack.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.readingWidth(scale: textScale))
        context.coordinator.columnLimit = columnLimit
        context.coordinator.textScale = textScale
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: TranscriptLayout.columnInset),
            columnLimit,
            fillWidth,
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        context.coordinator.stack = stack
        context.coordinator.scrollView = scrollView
        context.coordinator.installEarlierButton()
        scrollView.didLayout = { [weak coordinator = context.coordinator] in coordinator?.restoreReadingPosition() }
        scrollView.keepingPlace = { [weak coordinator = context.coordinator] scrollView, change in
            guard let coordinator else { return change() }
            coordinator.keepingPlace(in: scrollView, change)
        }
        scrollView.installLatestButton { [weak coordinator = context.coordinator] in coordinator?.goToLatestFromButton() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.openFile = openFile
        navigator?.coordinator = context.coordinator
        context.coordinator.loadMarks(for: sessionID)
        context.coordinator.prepareReadingPosition(for: sessionID, store: positionStore)
        context.coordinator.showChanges = showChanges
        context.coordinator.openInNewWindow = openInNewWindow
        context.coordinator.rescale(to: textScale, in: scrollView)
        context.coordinator.setShowsToolOutput(showsToolOutput)
        context.coordinator.sync(transcript, base: workingDirectory, isWorking: isWorking, in: scrollView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The conversation left the window, as it does on every session
    /// switch. VoiceOver may still hold its elements, by its cursor or a
    /// hot spot; left alive they went on reading a conversation no longer
    /// shown, so they're emptied and reported gone.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown(scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
        weak var stack: NSStackView?
        weak var scrollView: NSScrollView?
        /// The row the Go menu last moved to, by entry id.
        private var lastVisitedID: String?
        var openFile: (URL) -> Void = { _ in }
        var showChanges: (TranscriptEntry) -> Void = { _ in }
        var openInNewWindow: (URL) -> Void = { _ in }
        /// Entry ids the user marked, for the Marked Messages rotor.
        private var marked: Set<String> = []
        private var marksKey: String?
        private var rows: [String: MessageRowView] = [:]
        private var rowOrder: [String] = []
        /// Where the shown rows start among the transcript's entries.
        private var shownFrom = 0
        /// The entries and folder the last sync showed, for adding
        /// earlier rows later.
        private var entries: [TranscriptEntry] = []
        private var base: URL?
        /// Above the rows while earlier entries aren't shown.
        private(set) var earlierButton: NSButton?
        /// Caps the column at the reading width for the current text scale.
        var columnLimit: NSLayoutConstraint?
        var textScale = TextScale.standard.factor
        private var positionStore = TranscriptPositionStore.shared
        /// The session whose reading position this view saves.
        private var positionSessionID: String?
        /// A saved position not yet scrolled to; while it's set, nothing is
        /// saved over it.
        private var pendingPosition: TranscriptPosition?
        /// The saved place isn't among the rows built, so the view opened at
        /// the end; leaving from the end keeps that place saved.
        private var savedPlaceUnreached = false

        override init() {
            super.init()
            // Quitting doesn't take the conversation out of the window.
            NotificationCenter.default.addObserver(
                self, selector: #selector(saveReadingPosition),
                name: NSApplication.willTerminateNotification, object: nil
            )
        }

        /// Looks up where `sessionID` was being read, saving the place in the
        /// session it shows instead, if any.
        func prepareReadingPosition(for sessionID: String?, store: TranscriptPositionStore) {
            positionStore = store
            guard sessionID != positionSessionID else { return }
            saveReadingPosition()
            positionSessionID = sessionID
            pendingPosition = sessionID.flatMap { store.position(for: $0) }
            savedPlaceUnreached = false
        }

        /// Saves the row at the top of the view and how far into it the view
        /// starts; at the end, saves nothing, so it reopens at the end.
        @objc func saveReadingPosition() {
            guard pendingPosition == nil, let sessionID = positionSessionID, let scrollView,
                  scrollView.documentView != nil, scrollView.contentView.bounds.height > 0,
                  !rowOrder.isEmpty else { return }
            if scrollView.isNearBottom {
                if !savedPlaceUnreached { positionStore.save(nil, for: sessionID) }
                return
            }
            if let place = currentPlace() { positionStore.save(place, for: sessionID) }
        }

        /// The row at the top of the view and how far into it the view
        /// starts, as a share of its height, so it survives rewrapping.
        func currentPlace() -> TranscriptPosition? {
            guard let scrollView, let document = scrollView.documentView else { return nil }
            let top = scrollView.contentView.bounds.minY
            for id in rowOrder {
                guard let row = rows[id] else { continue }
                let frame = document.convert(row.bounds, from: row)
                guard frame.maxY > top, frame.height > 0 else { continue }
                return TranscriptPosition(entryID: id, fraction: Double((top - frame.minY) / frame.height))
            }
            return nil
        }

        /// Scrolls so `place` is at the top again, after rows have rewrapped.
        func scroll(to place: TranscriptPosition) {
            guard let row = rows[place.entryID], let scrollView, let document = scrollView.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let frame = document.convert(row.bounds, from: row)
            let lowest = max(0, document.bounds.height - scrollView.contentView.bounds.height)
            let y = min(lowest, max(0, frame.minY + frame.height * place.fraction))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// Makes a change that rewraps or resizes rows (text size, tool
        /// output, width) keeping the row being read at the top: the view
        /// kept its offset, and other text slid in under the reader.
        func keepingPlace(in scrollView: NSScrollView, _ change: () -> Void) {
            let wasFollowing = scrollView.isNearBottom
            let place = wasFollowing ? nil : currentPlace()
            change()
            if wasFollowing {
                scrollView.scrollToBottom()
            } else if let place {
                scroll(to: place)
            }
        }

        /// Scrolls to the saved position once the view is in a window with
        /// room; the scroll view asks again after each layout until then.
        /// Keyboard focus stays where it is. A place that isn't among the
        /// rows built opens at the end, as before.
        func restoreReadingPosition() {
            guard let position = pendingPosition, !rows.isEmpty else { return }
            guard let row = rows[position.entryID], let scrollView, let document = scrollView.documentView else {
                pendingPosition = nil
                savedPlaceUnreached = true
                return
            }
            guard scrollView.window != nil, scrollView.contentView.bounds.height > 0 else { return }
            pendingPosition = nil
            document.layoutSubtreeIfNeeded()
            let frame = document.convert(row.bounds, from: row)
            let lowest = max(0, document.bounds.height - scrollView.contentView.bounds.height)
            let y = min(lowest, max(0, frame.minY + frame.height * position.fraction))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// Redraws every row at a new text scale. Rows keep their identity,
        /// so VoiceOver's cursor and hot spots stay on the same messages.
        func rescale(to scale: Double, in scrollView: NSScrollView) {
            guard scale != textScale else { return }
            keepingPlace(in: scrollView) {
                textScale = scale
                columnLimit?.constant = Theme.readingWidth(scale: scale)
                for row in rows.values { row.textScale = scale }
            }
        }

        var showsToolOutput = false

        /// Shows or hides every tool's output; rows keep their identity, as
        /// they do for a new text size.
        func setShowsToolOutput(_ shows: Bool) {
            guard shows != showsToolOutput else { return }
            let apply = {
                self.showsToolOutput = shows
                for row in self.rows.values { row.showsToolOutput = shows }
            }
            if let scrollView { keepingPlace(in: scrollView, apply) } else { apply() }
        }

        /// Marks are kept per conversation, so they survive relaunching.
        func loadMarks(for sessionID: String?) {
            let key = sessionID.map { "marks.\($0)" }
            guard key != marksKey else { return }
            marksKey = key
            marked = Set(key.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? [])
            for (id, row) in rows { row.isMarked = marked.contains(id) }
        }

        func toggleMark(_ id: String) {
            if marked.remove(id) == nil { marked.insert(id) }
            rows[id]?.isMarked = marked.contains(id)
            if let marksKey { UserDefaults.standard.set(Array(marked), forKey: marksKey) }
            Announcer.announce(marked.contains(id) ? "Marked." : "Mark removed.")
        }

        lazy var rotors: [NSAccessibilityCustomRotor] = TranscriptNavigation.Kind.allCases.map {
            NSAccessibilityCustomRotor(label: $0.rawValue, itemSearchDelegate: self)
        } + [
            NSAccessibilityCustomRotor(label: TranscriptNavigation.codeBlocksRotor, itemSearchDelegate: self),
            // VoiceOver offers no Headings rotor of its own for a native
            // app's AXHeading elements (checked live: VO-U listed only
            // Content Chooser, Misspelled, Window Spots and ours), so the
            // conversation supplies one, typed so VoiceOver names it.
            NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self),
            // Links, for the same reason: the reply's links are their own
            // elements, but VoiceOver lists no Links rotor for them.
            NSAccessibilityCustomRotor(rotorType: .link, itemSearchDelegate: self),
        ]

        /// Where an element VoiceOver is on sits: a row, or a block inside a
        /// reply (an item or a link inside a block counts as that block).
        private func position(of element: Any?, in ordered: [MessageRowView]) -> TranscriptNavigation.Position? {
            if let row = element as? MessageRowView {
                return ordered.firstIndex { $0 === row }.map { TranscriptNavigation.Position(row: $0) }
            }
            guard let element = element as? ReplyElement, let row = element.row,
                  let rowIndex = ordered.firstIndex(where: { $0 === row }) else { return nil }
            var block = element
            while let parent = block.parentElement as? ReplyElement { block = parent }
            let blockIndex = row.replyElements.firstIndex { $0 === block }
            // Something inside a block (an item, or a link inside a list)
            // also has its place among the block's items.
            let item = block === element ? nil : block.items.firstIndex { $0 === element }
            return TranscriptNavigation.Position(row: rowIndex, block: blockIndex, item: item)
        }

        /// The next or previous row of the rotor's kind from the current one,
        /// narrowed by any text typed into the rotor.
        func rotor(
            _ rotor: NSAccessibilityCustomRotor,
            resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
        ) -> NSAccessibilityCustomRotor.ItemResult? {
            let ordered = rowOrder.compactMap { rows[$0] }
            let current = position(of: searchParameters.currentItem?.targetElement, in: ordered)
            let direction: TranscriptNavigation.Direction = searchParameters.searchDirection == .previous ? .previous : .next
            if rotor.label == TranscriptNavigation.codeBlocksRotor || rotor.type == .heading || rotor.type == .link {
                return blockSearch(rotor, from: searchParameters.currentItem?.targetElement, direction: direction,
                                   filter: searchParameters.filterString)
            }
            guard let kind = TranscriptNavigation.Kind(rawValue: rotor.label) else { return nil }
            // Searched through the whole conversation, not only the rows
            // built: a long one opens on its latest page, and a mark on an
            // earlier page wasn't in Marked Messages. The pages up to the
            // match are built as they're needed.
            // From inside a reply, the reply's own row is where it starts.
            let target = TranscriptNavigation.step(
                in: entries, kind: kind, from: current.map { shownFrom + $0.row }, direction: direction,
                filter: searchParameters.filterString, marked: marked
            )
            guard let target else { return nil }
            while target < shownFrom {
                let before = shownFrom
                showEarlier(movingFocus: false)
                guard shownFrom < before else { return nil }
            }
            guard let next = rows[entries[target].id] else { return nil }
            next.scrollToVisible(next.bounds)
            let result = NSAccessibilityCustomRotor.ItemResult(targetElement: next)
            result.customLabel = next.spokenText
            return result
        }

        /// Headings, links and code blocks are only known once a reply is
        /// drawn, so going back past the first built row builds the page
        /// before it and looks again, until there's nothing earlier.
        private func blockSearch(
            _ rotor: NSAccessibilityCustomRotor, from currentElement: Any?,
            direction: TranscriptNavigation.Direction, filter: String
        ) -> NSAccessibilityCustomRotor.ItemResult? {
            let matches: (ReplyElement) -> Bool =
                rotor.label == TranscriptNavigation.codeBlocksRotor ? { $0.isCode }
                : rotor.type == .heading ? { $0.role == ReplyElement.headingRole }
                : { $0.role == .link }
            while true {
                let ordered = rowOrder.compactMap { rows[$0] }
                let current = position(of: currentElement, in: ordered)
                if let found = block(in: ordered, from: current, direction: direction, filter: filter, matches: matches) {
                    return found
                }
                guard direction == .previous, shownFrom > 0 else { return nil }
                showEarlier(movingFocus: false)
            }
        }

        /// The next or previous block in any reply that `matches`, narrowed
        /// by text typed into the rotor. Nil past the end, never wrapping.
        private func block(
            in ordered: [MessageRowView], from current: TranscriptNavigation.Position?,
            direction: TranscriptNavigation.Direction, filter: String, matches: (ReplyElement) -> Bool
        ) -> NSAccessibilityCustomRotor.ItemResult? {
            var targets: [TranscriptNavigation.Position] = []
            var elements: [ReplyElement] = []
            for (rowIndex, row) in ordered.enumerated() {
                for (blockIndex, block) in row.replyElements.enumerated() {
                    // A block, then whatever inside it matches (links inside
                    // a list or table), in reading order.
                    let candidates = [(block, nil as Int?)] + block.items.enumerated().map { ($1, Optional($0)) }
                    for (element, item) in candidates where matches(element) {
                        let words = [element.label, element.value].compactMap { $0 }.joined(separator: " ")
                        guard filter.isEmpty || words.localizedCaseInsensitiveContains(filter) else { continue }
                        targets.append(TranscriptNavigation.Position(row: rowIndex, block: blockIndex, item: item))
                        elements.append(element)
                    }
                }
            }
            guard let index = TranscriptNavigation.step(through: targets, from: current, direction: direction) else { return nil }
            let element = elements[index]
            element.row?.scrollTextToVisible(element.range, shape: element.shape)
            let result = NSAccessibilityCustomRotor.ItemResult(targetElement: element)
            result.customLabel = element.codeName ?? element.label
            return result
        }

        /// Go > Previous Message, Next Message or Go to Latest Message:
        /// scrolls the message to the top of the conversation and moves
        /// VoiceOver to it. At either end it stays put and says so.
        func moveMessage(_ move: TranscriptNavigation.MessageMove) {
            guard let scrollView, let document = scrollView.documentView else { return }
            let ordered = rowOrder.compactMap { rows[$0] }
            let entries = ordered.compactMap(\.entry)
            guard entries.count == ordered.count else { return }
            let visible = scrollView.contentView.documentVisibleRect
            let frames = ordered.map { document.convert($0.bounds, from: $0) }
            let onScreen = frames.indices.filter { frames[$0].intersects(visible) }
            // The first row whose top shows; failing that (one reply taller
            // than the view), the row the view is inside.
            let topOfView = onScreen.first { frames[$0].minY >= visible.minY } ?? onScreen.first
            let start = TranscriptNavigation.startingRow(
                lastVisited: lastVisitedID.flatMap { rowOrder.firstIndex(of: $0) },
                onScreen: (onScreen.first ?? 0)..<((onScreen.last ?? -1) + 1),
                topOfView: topOfView
            )
            switch TranscriptNavigation.move(move, in: entries, from: start) {
            case .none where (move == .previous || move == .previousPrompt) && shownFrom > 0:
                // The first shown message isn't the conversation's first:
                // the earlier page comes in and Go carries on into it.
                lastVisitedID = start.flatMap { rowOrder.indices.contains($0) ? rowOrder[$0] : nil } ?? rowOrder.first
                showEarlier(movingFocus: false)
                moveMessage(move)
            case .none(let spoken):
                Announcer.announce(spoken)
            case .row(let index):
                let row = ordered[index]
                lastVisitedID = rowOrder[index]
                scrollToTop(frames[index], in: scrollView)
                // VoiceOver follows keyboard focus, so the row takes it.
                row.takeNavigationFocus()
            }
        }

        /// The Latest Message button: to the end of the conversation, as in
        /// the Claude app, with keyboard focus (and VoiceOver) on what's
        /// there, the last row whatever its kind. Go to Latest Message shows
        /// a long reply's start instead, which left the button up; and
        /// counting messages only, it did nothing with only tool rows shown.
        func goToLatestFromButton() {
            guard let scrollView, let id = rowOrder.last, let row = rows[id] else { return }
            lastVisitedID = id
            scrollView.scrollToBottom()
            row.takeNavigationFocus()
        }

        /// Scrolls so `frame` (in the conversation's coordinates) starts at
        /// the top of the view, below the same space the conversation has
        /// above its first row, as far as the conversation can scroll.
        private func scrollToTop(_ frame: NSRect, in scrollView: NSScrollView) {
            guard let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let lowest = max(0, document.bounds.height - clip.bounds.height)
            let y = min(max(0, frame.minY - TranscriptLayout.columnInset), lowest)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
        }

        /// Whether a reply has appeared in `ids` since the last message (or
        /// notice) among them.
        private func turnHasShownAReply(_ ids: some BidirectionalCollection<String>) -> Bool {
            for id in ids.reversed() {
                switch rows[id]?.shownKind {
                case .assistant?: return true
                case .user?, .notice?: return false
                default: continue
                }
            }
            return false
        }

        private func makeRow(_ entry: TranscriptEntry, base: URL?) -> MessageRowView {
            let row = MessageRowView(entry: entry, base: base, textScale: textScale)
            row.showsToolOutput = showsToolOutput
            row.openFile = { [weak self] url in self?.openFile(url) }
            row.showChanges = { [weak self] entry in self?.showChanges(entry) }
            row.openInNewWindow = { [weak self] url in self?.openInNewWindow(url) }
            row.toggleMark = { [weak self] id in self?.toggleMark(id) }
            row.isMarked = marked.contains(entry.id)
            return row
        }

        func sync(_ transcript: Transcript, base: URL?, isWorking: Bool, in scrollView: NSScrollView) {
            guard let stack else { return }
            // A new conversation starts over; within one, rows only grow.
            let shownIDs = transcript.entries.dropFirst(shownFrom).prefix(rowOrder.count).map(\.id)
            if transcript.entries.count < shownFrom + rowOrder.count || !rowOrder.elementsEqual(shownIDs) {
                rows.values.forEach { $0.removeFromSuperview() }
                rows = [:]
                rowOrder = []
                lastVisitedID = nil
            }
            // A conversation with nothing shown yet opens on its latest page.
            // One that grows while it's open keeps every row it showed.
            if rowOrder.isEmpty {
                shownFrom = max(0, transcript.entries.count - TranscriptLayout.pageSize)
            }
            entries = transcript.entries
            self.base = base
            let wasFollowing = (scrollView as? FollowingScrollView)?.isFollowing ?? scrollView.isNearBottom
            var inserted = false
            for entry in transcript.entries.dropFirst(shownFrom) {
                if let row = rows[entry.id] {
                    row.show(entry, base: base)
                } else {
                    let row = makeRow(entry, base: base)
                    // A reply carries on the turn when an earlier reply in it
                    // already showed "Claude"; a turn that opens with a tool
                    // still shows the label once.
                    row.continuesTurn = turnHasShownAReply(rowOrder)
                    // Your message starts a turn, so it gets more room above.
                    if entry.kind == .user, let previous = rowOrder.last.flatMap({ rows[$0] }) {
                        stack.setCustomSpacing(TranscriptLayout.turnSpacing, after: previous)
                    }
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    rows[entry.id] = row
                    rowOrder.append(entry.id)
                    inserted = true
                }
            }
            setEarlierButtonShown(shownFrom > 0)
            // Replies that can no longer grow get ChatMarkdownKit's final parse.
            let growingID = isWorking ? transcript.entries.last?.id : nil
            for entry in transcript.entries where entry.kind == .assistant && entry.id != growingID {
                rows[entry.id]?.finishMarkdown()
            }
            if wasFollowing, inserted || transcript.entries.last.map({ rows[$0.id] != nil }) == true {
                scrollView.scrollToBottom()
            }
            restoreReadingPosition()
            scheduleElapsedTick()
        }

        /// Empties the conversation for VoiceOver once it's out of the window.
        func tearDown(_ scrollView: NSScrollView) {
            saveReadingPosition()
            for row in rows.values {
                row.tearDownAccessibility()
                row.removeFromSuperview()
            }
            rows = [:]
            rowOrder = []
            lastVisitedID = nil
            NSAccessibility.post(element: scrollView, notification: .uiElementDestroyed)
        }

        /// Puts Show Earlier Messages above where the rows go, hidden until
        /// a conversation has earlier entries than it shows.
        func installEarlierButton() {
            guard let stack, earlierButton == nil else { return }
            let button = NSButton(title: "Show Earlier Messages", target: self, action: #selector(showEarlierPressed))
            stack.insertArrangedSubview(button, at: 0)
            earlierCollapsed = button.heightAnchor.constraint(equalToConstant: 0)
            earlierButton = button
            setEarlierButtonShown(false)
        }

        /// The stack keeps hidden views in its layout, so a hidden Show
        /// Earlier takes no height and no spacing after it.
        private var earlierCollapsed: NSLayoutConstraint?

        func setEarlierButtonShown(_ shown: Bool) {
            guard let button = earlierButton, let stack else { return }
            button.isHidden = !shown
            earlierCollapsed?.isActive = !shown
            stack.setCustomSpacing(shown ? stack.spacing : 0, after: button)
        }

        @objc private func showEarlierPressed() { showEarlier(movingFocus: true) }

        /// Adds the page of entries before the first shown row above it.
        /// What you were reading stays where it was on screen, and keyboard
        /// focus moves to the message just before it, so reading carries on
        /// backward from there.
        func showEarlier(movingFocus: Bool) {
            guard shownFrom > 0, let stack, let scrollView, let document = scrollView.documentView else { return }
            let from = max(0, shownFrom - TranscriptLayout.pageSize)
            let added = entries[from..<shownFrom]
            let firstShown = rowOrder.first.flatMap { rows[$0] }
            document.layoutSubtreeIfNeeded()
            let anchorY = firstShown.map { document.convert($0.bounds, from: $0).minY }
            var addedIDs: [String] = []
            for entry in added {
                let row = makeRow(entry, base: base)
                row.continuesTurn = turnHasShownAReply(addedIDs)
                if entry.kind == .user, let previous = addedIDs.last.flatMap({ rows[$0] }) {
                    stack.setCustomSpacing(TranscriptLayout.turnSpacing, after: previous)
                }
                // Below the button and the rows added before it.
                stack.insertArrangedSubview(row, at: 1 + addedIDs.count)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rows[entry.id] = row
                addedIDs.append(entry.id)
            }
            if let firstShown {
                // The row that was first now follows the added ones.
                firstShown.continuesTurn = turnHasShownAReply(addedIDs)
                if firstShown.entry?.kind == .user, let previous = addedIDs.last.flatMap({ rows[$0] }) {
                    stack.setCustomSpacing(TranscriptLayout.turnSpacing, after: previous)
                }
            }
            rowOrder.insert(contentsOf: addedIDs, at: 0)
            shownFrom = from
            setEarlierButtonShown(shownFrom > 0)
            document.layoutSubtreeIfNeeded()
            if let firstShown, let anchorY {
                let moved = document.convert(firstShown.bounds, from: firstShown).minY - anchorY
                let clip = scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + moved))
                scrollView.reflectScrolledClipView(clip)
            }
            guard movingFocus, let previous = addedIDs.last.flatMap({ rows[$0] }) else { return }
            // Into view first, as the Go menu's moves do: focused where it
            // was, just above the view, nobody could see the focus ring.
            // The row you were reading moves down by about this one.
            previous.scrollToVisible(previous.bounds)
            previous.takeNavigationFocus()
        }

        /// Wakes when a running tool's shown time next moves; nil while
        /// nothing runs.
        private var elapsedTimer: Timer?

        /// Rows whose tool is running, with when each started.
        private var runningRows: [(row: MessageRowView, since: Date)] {
            rowOrder.compactMap { id in
                guard let row = rows[id], let since = row.runningSince else { return nil }
                return (row, since)
            }
        }

        /// Sets the timer for the soonest moment a running row's time moves,
        /// or stops it when nothing runs. A sync during streaming leaves a
        /// timer alone unless a newer row needs it sooner.
        private func scheduleElapsedTick() {
            let now = Date()
            guard let wait = ElapsedWording.nextTick(startedAt: runningRows.map(\.since), now: now) else {
                elapsedTimer?.invalidate()
                elapsedTimer = nil
                return
            }
            let due = now.addingTimeInterval(wait)
            if let elapsedTimer, elapsedTimer.isValid, elapsedTimer.fireDate <= due { return }
            elapsedTimer?.invalidate()
            let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickElapsed() }
            }
            timer.tolerance = TranscriptLayout.elapsedTickTolerance
            // Common modes, so the time keeps moving while the user scrolls.
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
        }

        /// Updates only the running rows; no row is rebuilt or reordered.
        private func tickElapsed() {
            elapsedTimer = nil
            let now = Date()
            for (row, _) in runningRows { row.showElapsed(at: now) }
            scheduleElapsedTick()
        }

    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The conversation's scroll view. Reading the end, a change of width
/// (the side panel opening, the window resizing) rewraps every message and
/// grows the conversation below the view; this keeps the end in view.
private final class FollowingScrollView: NSScrollView {
    /// Whether new output scrolls into view: on while the view was last left
    /// at the end. Within the 40-point threshold it followed, so a slow
    /// scroll up was pulled back by each streamed word.
    fileprivate(set) var isFollowing = true
    /// Set while the view scrolls itself, which isn't the user leaving the end.
    fileprivate var isScrollingItself = false
    /// How close to the end counts as at it, for rounding.
    static let endTolerance: CGFloat = 2

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard !isScrollingItself, let document = documentView else { return }
        isFollowing = document.bounds.maxY - clipView.documentVisibleRect.maxY <= Self.endTolerance
    }

    /// Runs after each layout, for work that needs the final size.
    var didLayout: (() -> Void)?
    /// Over the end of the conversation while earlier messages are showing,
    /// as in the Claude app; it does what Go to Latest Message does. Its
    /// title is also its name, so Voice Control can say what's drawn.
    private let latestButton = NSButton(title: "Latest Message", target: nil, action: nil)
    private var goToLatest: () -> Void = {}

    func installLatestButton(goToLatest: @escaping () -> Void) {
        self.goToLatest = goToLatest
        latestButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        latestButton.imagePosition = .imageLeading
        latestButton.bezelStyle = .push
        latestButton.target = self
        latestButton.action = #selector(latestPressed)
        addSubview(latestButton)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateLatestButton), name: NSView.boundsDidChangeNotification, object: contentView)
        if let documentView {
            documentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(updateLatestButton), name: NSView.frameDidChangeNotification, object: documentView)
        }
        updateLatestButton()
    }

    /// Hidden at the end. The scroll view still lists a hidden button to
    /// assistive apps, so it also stops being an element then.
    @objc private func updateLatestButton() {
        latestButton.isHidden = isNearBottom
        latestButton.cell?.setAccessibilityElement(!latestButton.isHidden)
    }

    @objc private func latestPressed() {
        goToLatest()
        updateLatestButton()
    }

    override func layout() {
        super.layout()
        // A first layout or a resize can end the conversation in view
        // without a scroll.
        if latestButton.superview != nil {
            // NSScrollView tiles its subviews itself. Constraints on this
            // overlay left it at the top-left with a clipped title. Place
            // it after tiling, using the button's full measured size.
            latestButton.sizeToFit()
            let size = latestButton.frame.size
            latestButton.setFrameOrigin(NSPoint(
                x: bounds.midX - size.width / 2,
                y: isFlipped
                    ? bounds.maxY - Theme.Spacing.medium - size.height
                    : bounds.minY + Theme.Spacing.medium
            ))
            updateLatestButton()
        }
        didLayout?()
    }

    /// Keeps the row being read in place across a change of width.
    var keepingPlace: ((NSScrollView, () -> Void) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width != frame.width, let keepingPlace else {
            super.setFrameSize(newSize)
            return
        }
        keepingPlace(self) { super.setFrameSize(newSize) }
    }

    /// VoiceOver moves in this order. Left to AppKit it was sorted by
    /// position, which put your right-aligned message after the tool row
    /// below it; the children are already in conversation order.
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? {
        accessibilityChildren() as? [NSAccessibilityElementProtocol]
    }

    /// NSScrollView answers the attribute itself, without asking the
    /// method above, so an assistive app's request is answered here too.
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard attribute == Self.navigationOrder else { return super.accessibilityAttributeValue(attribute) }
        // AppKit asks on the main thread.
        nonisolated(unsafe) var children: [Any]?
        MainActor.assumeIsolated { children = accessibilityChildren() }
        return children
    }

    private nonisolated static let navigationOrder = NSAccessibility.Attribute(rawValue: "AXChildrenInNavigationOrder")
}

extension NSScrollView {
    /// Within the follow threshold of the conversation's end.
    var isNearBottom: Bool {
        guard let document = documentView else { return true }
        return document.bounds.maxY - contentView.documentVisibleRect.maxY <= TranscriptLayout.followThreshold
    }

    func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let following = self as? FollowingScrollView
        following?.isScrollingItself = true
        documentView?.scroll(NSPoint(x: 0, y: documentView?.bounds.maxY ?? 0))
        following?.isScrollingItself = false
        following?.isFollowing = true
    }
}
