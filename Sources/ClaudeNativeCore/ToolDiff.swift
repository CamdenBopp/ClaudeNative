import Foundation

/// How a line ended in the file.
public enum LineEnding: Sendable, Equatable, Hashable {
    case lf
    case crlf
}

/// The line-ending convention of a whole text.
public enum LineEndingStyle: Sendable, Equatable {
    /// The text has no line breaks at all.
    case none
    case lf
    case crlf
    case mixed

    var spokenName: String {
        switch self {
        case .none: "none"
        case .lf: "LF"
        case .crlf: "CRLF"
        case .mixed: "mixed"
        }
    }
}

/// One line of a diff. `text` is the line exactly as it is in the file,
/// minus its line break; the break is in `ending`.
public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case added
        case removed
        case context
    }

    public let kind: Kind
    /// The line's number in the file before the change; nil for added lines.
    public let oldNumber: Int?
    /// The line's number in the file after the change; nil for removed lines.
    public let newNumber: Int?
    public let text: String
    /// nil when this is the last line and the file doesn't end with a newline.
    public let ending: LineEnding?
    /// True when VoiceOver should say how this line ends, because the diff
    /// mixes or changes line endings and two lines can otherwise read the same.
    public let speaksEnding: Bool

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String, ending: LineEnding?, speaksEnding: Bool = false) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.ending = ending
        self.speaksEnding = speaksEnding
    }

    /// The number a reader goes by: the old number for a removed line, the
    /// new number otherwise.
    public var number: Int? {
        kind == .removed ? oldNumber : newNumber
    }

    /// "Added, line 12: let x = 1". An empty line reads "blank line".
    public var spoken: String {
        let label = switch kind {
        case .added: "Added"
        case .removed: "Removed"
        case .context: "Unchanged"
        }
        var result = label
        if let number { result += ", line \(number)" }
        result += ": " + Self.speakable(text)
        if ending == nil {
            result += ", no newline at end of file"
        } else if speaksEnding, let ending {
            result += ending == .crlf ? ", CRLF line ending" : ", LF line ending"
        }
        return result
    }

    static func speakable(_ text: String) -> String {
        if text.isEmpty { return "blank line" }
        if text.allSatisfy({ $0 == " " || $0 == "\t" }) { return "only whitespace" }
        return text
    }
}

/// A run of changed lines with up to `ToolDiff.contextLines` unchanged lines
/// on each side.
public struct Hunk: Sendable, Equatable {
    /// First old line number in the hunk. When the hunk has no old lines,
    /// the number of the old line it follows (0 at the start of the file).
    public let oldStart: Int
    public let oldCount: Int
    /// First new line number in the hunk, with the same rule as `oldStart`.
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]
    /// This hunk's position, counting from 1, and how many hunks the diff has.
    public let number: Int
    public let total: Int
    /// False when the numbers count from the start of the edited text rather
    /// than the file (an approximate diff).
    public let numbersAreFileLines: Bool

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine], number: Int, total: Int, numbersAreFileLines: Bool) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        self.number = number
        self.total = total
        self.numbersAreFileLines = numbersAreFileLines
    }

    public var addedCount: Int { lines.count { $0.kind == .added } }
    public var removedCount: Int { lines.count { $0.kind == .removed } }

    /// "Change 1 of 2, lines 10 to 14", using the new file's numbers. A hunk
    /// that leaves no lines behind uses the old numbers instead.
    public var title: String {
        var result = "Change \(number) of \(total), "
        if newCount > 0 {
            result += Self.range(newStart, newCount)
        } else {
            result += "old " + Self.range(oldStart, oldCount)
        }
        if !numbersAreFileLines { result += " of the edited text" }
        return result
    }

    static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "line \(start)" : "lines \(start) to \(start + count - 1)"
    }
}

/// What one tool call changes in one file.
public struct FileDiff: Sendable, Equatable {
    public let toolName: String
    public let path: String
    /// For NotebookEdit: the cell being changed. Line numbers then count
    /// within the cell.
    public let cellID: String?
    public let hunks: [Hunk]
    public let isNewFile: Bool
    /// True when line numbers or the old text are a best guess; see
    /// `approximateReason`.
    public let isApproximate: Bool
    public let approximateReason: String?
    public let addedCount: Int
    public let removedCount: Int
    /// Whether the text before and after the change ends without a newline.
    /// Only known for exact diffs; false when approximate.
    public let oldMissingFinalNewline: Bool
    public let newMissingFinalNewline: Bool
    public let oldLineEndings: LineEndingStyle
    public let newLineEndings: LineEndingStyle

    public init(toolName: String, path: String, cellID: String?, hunks: [Hunk], isNewFile: Bool, isApproximate: Bool, approximateReason: String?, addedCount: Int, removedCount: Int, oldMissingFinalNewline: Bool, newMissingFinalNewline: Bool, oldLineEndings: LineEndingStyle, newLineEndings: LineEndingStyle) {
        self.toolName = toolName
        self.path = path
        self.cellID = cellID
        self.hunks = hunks
        self.isNewFile = isNewFile
        self.isApproximate = isApproximate
        self.approximateReason = approximateReason
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.oldMissingFinalNewline = oldMissingFinalNewline
        self.newMissingFinalNewline = newMissingFinalNewline
        self.oldLineEndings = oldLineEndings
        self.newLineEndings = newLineEndings
    }

    /// "Edit Sources/App.swift: 3 lines added, 1 removed, in 2 places", with
    /// the full path. Use `summary(relativeTo:)` to shorten it.
    public var summary: String { summary(relativeTo: nil) }

    public func summary(relativeTo base: URL?) -> String {
        let shownPath = ToolSummary.shorten(path, relativeTo: base)
        var subject = "\(toolName) \(shownPath)"
        if let cellID { subject = "\(toolName) cell \(cellID) in \(shownPath)" }
        var sentences: [String] = []
        var first = subject + (isNewFile ? ", new file: " : ": ")
        first += Self.counts(added: addedCount, removed: removedCount)
        if hunks.count > 1 { first += ", in \(hunks.count) places" }
        sentences.append(first)
        if !isApproximate {
            if isNewFile {
                if newMissingFinalNewline && addedCount > 0 { sentences.append("No newline at end of file") }
            } else if newMissingFinalNewline && !oldMissingFinalNewline && addedCount + removedCount > 0 {
                sentences.append("Removes the newline at end of file")
            } else if !newMissingFinalNewline && oldMissingFinalNewline {
                sentences.append("Adds a newline at end of file")
            }
            if !isNewFile, Self.isRealEnding(oldLineEndings), Self.isRealEnding(newLineEndings), oldLineEndings != newLineEndings {
                sentences.append("Line endings change from \(oldLineEndings.spokenName) to \(newLineEndings.spokenName)")
            }
        }
        if isApproximate, let approximateReason { sentences.append("Approximate: " + approximateReason) }
        return sentences.joined(separator: ". ")
    }

    private static func isRealEnding(_ style: LineEndingStyle) -> Bool { style != .none }

    static func counts(added: Int, removed: Int) -> String {
        switch (added, removed) {
        case (0, 0): "no changes"
        case (_, 0): "\(lines(added)) added"
        case (0, _): "\(lines(removed)) removed"
        default: "\(lines(added)) added, \(removed) removed"
        }
    }

    static func lines(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }
}

/// Builds the diff a file tool call makes, for the permission prompt and for
/// a finished tool row.
public enum ToolDiff {
    /// Unchanged lines shown on each side of a change.
    public static let contextLines = 3

    /// When the diff is being made relative to the tool running.
    public enum Moment: Sendable {
        /// The tool hasn't run (the permission prompt): the current file is
        /// the old text.
        case beforeTool
        /// The tool ran and succeeded (a finished row): the current file
        /// probably already holds the new text.
        case afterTool
    }

    static let editNotFoundReason = "The text to replace isn't in the file as it is now, so line numbers count from the start of the edit, not the file"
    static let unreadableReason = "The file couldn't be read, so line numbers count from the start of the edit, not the file"
    static let notebookReason = "The notebook cell couldn't be found, so this shows only the new cell text"

    /// The diff for a file tool call, or nil for any other tool (or a file
    /// tool whose input is missing its fields). `currentFile` returns a
    /// path's current text, or nil if it doesn't exist or can't be read.
    public static func make(toolName: String, input: JSONValue, currentFile: (String) -> String?) -> FileDiff? {
        make(toolName: toolName, input: input, moment: .beforeTool, currentFile: currentFile)
    }

    public static func make(toolName: String, input: JSONValue, moment: Moment, currentFile: (String) -> String?) -> FileDiff? {
        switch toolName {
        case "Edit":
            guard let path = input["file_path"]?.string,
                  let edit = TextEdit(input) else { return nil }
            return editDiff(toolName: toolName, path: path, edits: [edit], moment: moment, current: currentFile(path))
        case "MultiEdit":
            guard let path = input["file_path"]?.string,
                  let items = input["edits"]?.array else { return nil }
            let edits = items.compactMap(TextEdit.init)
            guard !edits.isEmpty, edits.count == items.count else { return nil }
            return editDiff(toolName: toolName, path: path, edits: edits, moment: moment, current: currentFile(path))
        case "Write":
            guard let path = input["file_path"]?.string,
                  let content = input["content"]?.string else { return nil }
            return writeDiff(path: path, content: content, moment: moment, current: currentFile(path))
        case "NotebookEdit":
            guard let path = input["notebook_path"]?.string else { return nil }
            return notebookDiff(path: path, input: input, current: currentFile(path))
        default:
            return nil
        }
    }

    // MARK: - Tools

    struct TextEdit {
        let old: [UInt8]
        let new: [UInt8]
        let replaceAll: Bool

        init?(_ value: JSONValue) {
            guard let old = value["old_string"]?.string,
                  let new = value["new_string"]?.string else { return nil }
            self.old = Array(old.utf8)
            self.new = Array(new.utf8)
            replaceAll = value["replace_all"]?.bool ?? false
        }

        init(old: [UInt8], new: [UInt8], replaceAll: Bool) {
            self.old = old
            self.new = new
            self.replaceAll = replaceAll
        }
    }

    static func editDiff(toolName: String, path: String, edits: [TextEdit], moment: Moment, current: String?) -> FileDiff {
        // An Edit with an empty old_string creates the file.
        if current == nil, edits.count == 1, edits[0].old.isEmpty {
            return exact(toolName: toolName, path: path, old: nil, new: edits[0].new)
        }
        if let current {
            let text = Array(current.utf8)
            switch moment {
            case .beforeTool:
                if let applied = apply(edits, to: text) {
                    return exact(toolName: toolName, path: path, old: text, new: applied)
                }
            case .afterTool:
                if let original = unapply(edits, from: text) {
                    return exact(toolName: toolName, path: path, old: original, new: text)
                }
                if let applied = apply(edits, to: text) {
                    return exact(toolName: toolName, path: path, old: text, new: applied)
                }
            }
        }
        return approximate(toolName: toolName, path: path, edits: edits,
                           reason: current == nil ? unreadableReason : editNotFoundReason)
    }

    static func writeDiff(path: String, content: String, moment: Moment, current: String?) -> FileDiff {
        let new = Array(content.utf8)
        // After the tool ran, the file holds `content`, so the old text is gone.
        if moment == .afterTool, let current, Array(current.utf8) == new {
            return exact(toolName: "Write", path: path, old: nil, new: new, isNewFile: false,
                         approximateReason: "The file already holds this text, so the earlier version isn't known and every line shows as added")
        }
        return exact(toolName: "Write", path: path, old: current.map { Array($0.utf8) }, new: new)
    }

    static func notebookDiff(path: String, input: JSONValue, current: String?) -> FileDiff? {
        let mode = input["edit_mode"]?.string ?? "replace"
        let cellID = input["cell_id"]?.string
        let newSource = Array((input["new_source"]?.string ?? "").utf8)
        var oldSource: [UInt8]?
        if let current, let cellID,
           let notebook = try? JSONValue.parse(Data(current.utf8)),
           let cells = notebook["cells"]?.array,
           let cell = cells.first(where: { $0["id"]?.string == cellID }) {
            if let text = cell["source"]?.string {
                oldSource = Array(text.utf8)
            } else if let parts = cell["source"]?.array {
                oldSource = Array(parts.compactMap(\.string).joined().utf8)
            }
        }
        switch mode {
        case "insert":
            return exact(toolName: "NotebookEdit", path: path, cellID: cellID, old: nil, new: newSource, isNewFile: false)
        case "delete":
            guard let oldSource else {
                return exact(toolName: "NotebookEdit", path: path, cellID: cellID, old: [], new: [], isNewFile: false, approximateReason: notebookReason)
            }
            return exact(toolName: "NotebookEdit", path: path, cellID: cellID, old: oldSource, new: [])
        default:
            guard let oldSource else {
                return exact(toolName: "NotebookEdit", path: path, cellID: cellID, old: nil, new: newSource, isNewFile: false, approximateReason: notebookReason)
            }
            return exact(toolName: "NotebookEdit", path: path, cellID: cellID, old: oldSource, new: newSource)
        }
    }

    // MARK: - Applying edits

    /// Applies the edits in order the way the CLI does: the first match, or
    /// every non-overlapping match for replace_all. nil if any edit's old
    /// text is missing.
    static func apply(_ edits: [TextEdit], to text: [UInt8]) -> [UInt8]? {
        var text = text
        for edit in edits {
            if edit.old.isEmpty {
                guard text.isEmpty else { return nil }
                text = edit.new
                continue
            }
            guard let replaced = replace(edit.old, with: edit.new, in: text, all: edit.replaceAll) else { return nil }
            text = replaced
        }
        return text
    }

    /// Undoes edits that have already been applied, to recover the text the
    /// tool started from. Only trusted when each new text is found exactly
    /// once (or replace_all) and redoing the edits gives back `text` exactly.
    static func unapply(_ edits: [TextEdit], from text: [UInt8]) -> [UInt8]? {
        var original = text
        for edit in edits.reversed() {
            guard !edit.new.isEmpty else { return nil }
            if !edit.replaceAll, occurrences(of: edit.new, in: original).count != 1 { return nil }
            guard let reverted = replace(edit.new, with: edit.old, in: original, all: edit.replaceAll) else { return nil }
            original = reverted
        }
        guard original != text, apply(edits, to: original) == text else { return nil }
        return original
    }

    static func replace(_ target: [UInt8], with replacement: [UInt8], in text: [UInt8], all: Bool) -> [UInt8]? {
        let found = all ? occurrences(of: target, in: text) : firstOccurrence(of: target, in: text).map { [$0] } ?? []
        guard !found.isEmpty else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(text.count + found.count * (replacement.count - target.count))
        var cursor = 0
        for start in found {
            result.append(contentsOf: text[cursor..<start])
            result.append(contentsOf: replacement)
            cursor = start + target.count
        }
        result.append(contentsOf: text[cursor...])
        return result
    }

    static func firstOccurrence(of target: [UInt8], in text: [UInt8], from start: Int = 0) -> Int? {
        guard !target.isEmpty, text.count - start >= target.count else { return nil }
        let first = target[0]
        var index = start
        let last = text.count - target.count
        while index <= last {
            if text[index] == first, text[index..<(index + target.count)].elementsEqual(target) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Non-overlapping matches, left to right.
    static func occurrences(of target: [UInt8], in text: [UInt8]) -> [Int] {
        var result: [Int] = []
        var from = 0
        while let index = firstOccurrence(of: target, in: text, from: from) {
            result.append(index)
            from = index + target.count
        }
        return result
    }

    // MARK: - Building diffs

    static func exact(toolName: String, path: String, cellID: String? = nil, old: [UInt8]?, new: [UInt8], isNewFile: Bool? = nil, approximateReason: String? = nil) -> FileDiff {
        let oldLines = old.map(splitLines) ?? []
        let newLines = splitLines(new)
        let isApproximate = approximateReason != nil
        let hunks = makeHunks(old: oldLines, new: newLines, numbersAreFileLines: true)
        return FileDiff(
            toolName: toolName,
            path: path,
            cellID: cellID,
            hunks: hunks,
            isNewFile: isNewFile ?? (old == nil),
            isApproximate: isApproximate,
            approximateReason: approximateReason,
            addedCount: hunks.reduce(0) { $0 + $1.addedCount },
            removedCount: hunks.reduce(0) { $0 + $1.removedCount },
            oldMissingFinalNewline: old.map(missingFinalNewline) ?? false,
            newMissingFinalNewline: missingFinalNewline(new),
            oldLineEndings: style(oldLines),
            newLineEndings: style(newLines)
        )
    }

    /// Diffs each edit's old text against its new text on its own, numbering
    /// lines from the start of the edit.
    static func approximate(toolName: String, path: String, edits: [TextEdit], reason: String) -> FileDiff {
        var pieces: [[DiffLineDraft]] = []
        for edit in edits {
            let drafts = diffLines(old: splitLines(edit.old), new: splitLines(edit.new), dropMissingEnding: true)
            pieces.append(contentsOf: groupHunks(drafts))
        }
        let hunks = finish(pieces, numbersAreFileLines: false)
        return FileDiff(
            toolName: toolName,
            path: path,
            cellID: nil,
            hunks: hunks,
            isNewFile: false,
            isApproximate: true,
            approximateReason: reason,
            addedCount: hunks.reduce(0) { $0 + $1.addedCount },
            removedCount: hunks.reduce(0) { $0 + $1.removedCount },
            oldMissingFinalNewline: false,
            newMissingFinalNewline: false,
            oldLineEndings: .none,
            newLineEndings: .none
        )
    }

    struct RawLine {
        /// The line's bytes including its line break, for comparing.
        let bytes: ArraySlice<UInt8>
        let ending: LineEnding?

        var text: String {
            let dropped = switch ending {
            case .crlf: 2
            case .lf: 1
            case nil: 0
            }
            return String(decoding: bytes.dropLast(dropped), as: UTF8.self)
        }
    }

    /// Splits on "\n" bytes, so "\r\n" stays with its line (Swift treats
    /// "\r\n" as one Character, which a String split would miss).
    static func splitLines(_ text: [UInt8]) -> [RawLine] {
        var lines: [RawLine] = []
        var start = 0
        for index in text.indices where text[index] == UInt8(ascii: "\n") {
            let isCRLF = index > start && text[index - 1] == UInt8(ascii: "\r")
            lines.append(RawLine(bytes: text[start...index], ending: isCRLF ? .crlf : .lf))
            start = index + 1
        }
        if start < text.count {
            lines.append(RawLine(bytes: text[start...], ending: nil))
        }
        return lines
    }

    static func missingFinalNewline(_ text: [UInt8]) -> Bool {
        guard let last = text.last else { return false }
        return last != UInt8(ascii: "\n")
    }

    static func style(_ lines: [RawLine]) -> LineEndingStyle {
        var sawLF = false
        var sawCRLF = false
        for line in lines {
            switch line.ending {
            case .lf: sawLF = true
            case .crlf: sawCRLF = true
            case nil: break
            }
        }
        switch (sawLF, sawCRLF) {
        case (false, false): return .none
        case (true, false): return .lf
        case (false, true): return .crlf
        case (true, true): return .mixed
        }
    }

    struct DiffLineDraft {
        let line: DiffLine
        /// Old and new lines seen before this one, for numbering hunks.
        let oldBefore: Int
        let newBefore: Int
    }

    static func makeHunks(old: [RawLine], new: [RawLine], numbersAreFileLines: Bool) -> [Hunk] {
        finish(groupHunks(diffLines(old: old, new: new, dropMissingEnding: false)), numbersAreFileLines: numbersAreFileLines)
    }

    /// Every line of both texts in order, marked added, removed or unchanged.
    /// Within a change, removed lines come before added ones.
    static func diffLines(old: [RawLine], new: [RawLine], dropMissingEnding: Bool) -> [DiffLineDraft] {
        var ids: [ArraySlice<UInt8>: Int] = [:]
        func id(_ line: RawLine) -> Int {
            // A snippet's last line has no break of its own; compare it as if
            // it did, so "a" and "a\n" in an approximate diff aren't a change.
            let key = dropMissingEnding && line.ending == nil ? line.bytes + [UInt8(ascii: "\n")] : line.bytes
            if let existing = ids[key] { return existing }
            let next = ids.count
            ids[key] = next
            return next
        }
        let a = old.map(id)
        let b = new.map(id)
        var removed = [Bool](repeating: false, count: a.count)
        var added = [Bool](repeating: false, count: b.count)
        Myers.diff(a, b, removed: &removed, added: &added)

        let speaksEnding = style(old + new) == .mixed
        var drafts: [DiffLineDraft] = []
        drafts.reserveCapacity(max(a.count, b.count))
        var i = 0
        var j = 0
        func ending(_ line: RawLine) -> LineEnding? {
            dropMissingEnding && line.ending == nil ? .lf : line.ending
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, !removed[i], !added[j] {
                drafts.append(DiffLineDraft(line: DiffLine(kind: .context, oldNumber: i + 1, newNumber: j + 1, text: new[j].text, ending: ending(new[j]), speaksEnding: speaksEnding), oldBefore: i, newBefore: j))
                i += 1
                j += 1
                continue
            }
            while i < a.count, removed[i] {
                drafts.append(DiffLineDraft(line: DiffLine(kind: .removed, oldNumber: i + 1, newNumber: nil, text: old[i].text, ending: ending(old[i]), speaksEnding: speaksEnding), oldBefore: i, newBefore: j))
                i += 1
            }
            while j < b.count, added[j] {
                drafts.append(DiffLineDraft(line: DiffLine(kind: .added, oldNumber: nil, newNumber: j + 1, text: new[j].text, ending: ending(new[j]), speaksEnding: speaksEnding), oldBefore: i, newBefore: j))
                j += 1
            }
        }
        return drafts
    }

    /// Cuts the full line list into hunks with `contextLines` of context,
    /// merging changes whose context would touch or overlap.
    static func groupHunks(_ drafts: [DiffLineDraft]) -> [[DiffLineDraft]] {
        let changed = drafts.indices.filter { drafts[$0].line.kind != .context }
        guard let firstChange = changed.first else { return [] }
        var groups: [[DiffLineDraft]] = []
        var start = max(0, firstChange - contextLines)
        var lastChange = firstChange
        for index in changed.dropFirst() {
            if index - lastChange - 1 > 2 * contextLines {
                groups.append(Array(drafts[start...min(drafts.count - 1, lastChange + contextLines)]))
                start = index - contextLines
            }
            lastChange = index
        }
        groups.append(Array(drafts[start...min(drafts.count - 1, lastChange + contextLines)]))
        return groups
    }

    static func finish(_ groups: [[DiffLineDraft]], numbersAreFileLines: Bool) -> [Hunk] {
        groups.enumerated().map { offset, group in
            let lines = group.map(\.line)
            let oldCount = lines.count { $0.kind != .added }
            let newCount = lines.count { $0.kind != .removed }
            let first = group[0]
            return Hunk(
                oldStart: first.oldBefore + (oldCount > 0 ? 1 : 0),
                oldCount: oldCount,
                newStart: first.newBefore + (newCount > 0 ? 1 : 0),
                newCount: newCount,
                lines: lines,
                number: offset + 1,
                total: groups.count,
                numbersAreFileLines: numbersAreFileLines
            )
        }
    }
}

/// Myers' O(ND) diff in linear space (the middle-snake bisection), over
/// integer line ids. Marks which old lines are removed and which new lines
/// are added; everything unmarked is the longest common subsequence.
enum Myers {
    /// Above this many steps (total lines times the least possible edit
    /// distance), lines found on only one side are set aside before diffing.
    /// 2,000,000 keeps a full run under about 50 ms in a debug build.
    static let discardThreshold = 2_000_000

    static func diff(_ a: [Int], _ b: [Int], removed: inout [Bool], added: inout [Bool]) {
        // A line that appears on only one side can't be in the common
        // subsequence, so it can be marked now and Myers run on the rest. That
        // turns a big rewrite from O(N * D) into near linear time. Dropping
        // those lines can pair repeated lines differently ("a a" to "b a"
        // reads as a change to line 2, not line 1), so it's only done when
        // the full run would be slow: each unique line adds at least 1 to D.
        let inB = Set(b)
        let inA = Set(a)
        removed = a.map { !inB.contains($0) }
        added = b.map { !inA.contains($0) }
        let uniqueCount = removed.count { $0 } + added.count { $0 }
        if (a.count + b.count) * uniqueCount <= discardThreshold {
            for index in removed.indices { removed[index] = false }
            for index in added.indices { added[index] = false }
        }
        let keptA = a.indices.filter { !removed[$0] }
        let keptB = b.indices.filter { !added[$0] }
        let reducedA = keptA.map { a[$0] }
        let reducedB = keptB.map { b[$0] }
        reducedA.withUnsafeBufferPointer { ra in
            reducedB.withUnsafeBufferPointer { rb in
                var work = Work(a: ra, b: rb)
                work.compare(aLo: 0, aHi: ra.count, bLo: 0, bHi: rb.count)
                for (index, isRemoved) in work.removed.enumerated() where isRemoved { removed[keptA[index]] = true }
                for (index, isAdded) in work.added.enumerated() where isAdded { added[keptB[index]] = true }
            }
        }
    }

    struct Work {
        let a: UnsafeBufferPointer<Int>
        let b: UnsafeBufferPointer<Int>
        var removed: [Bool]
        var added: [Bool]
        var forward: [Int] = []
        var backward: [Int] = []

        init(a: UnsafeBufferPointer<Int>, b: UnsafeBufferPointer<Int>) {
            self.a = a
            self.b = b
            removed = [Bool](repeating: false, count: a.count)
            added = [Bool](repeating: false, count: b.count)
        }

        mutating func compare(aLo: Int, aHi: Int, bLo: Int, bHi: Int) {
            var aLo = aLo, aHi = aHi, bLo = bLo, bHi = bHi
            while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
                aLo += 1
                bLo += 1
            }
            while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] {
                aHi -= 1
                bHi -= 1
            }
            if aLo == aHi {
                for j in bLo..<bHi { added[j] = true }
                return
            }
            if bLo == bHi {
                for i in aLo..<aHi { removed[i] = true }
                return
            }
            let (x, y) = middleSnake(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi)
            compare(aLo: aLo, aHi: x, bLo: bLo, bHi: y)
            compare(aLo: x, aHi: aHi, bLo: y, bHi: bHi)
        }

        /// A split point (x, y) on an optimal path through the edit graph of
        /// a[aLo..<aHi] and b[bLo..<bHi], both non-empty and with no common
        /// prefix or suffix, so the split always makes progress.
        mutating func middleSnake(aLo: Int, aHi: Int, bLo: Int, bHi: Int) -> (Int, Int) {
            let n = aHi - aLo
            let m = bHi - bLo
            let maxD = (n + m + 1) / 2
            let offset = maxD + 1
            let size = 2 * maxD + 3
            if forward.count < size {
                forward = [Int](repeating: -1, count: size)
                backward = [Int](repeating: -1, count: size)
            } else {
                for k in 0..<size {
                    forward[k] = -1
                    backward[k] = -1
                }
            }
            forward[offset + 1] = 0
            backward[offset + 1] = 0
            let delta = n - m
            let deltaIsOdd = delta & 1 != 0
            var k1Start = 0, k1End = 0, k2Start = 0, k2End = 0
            for d in 0..<maxD + 1 {
                var k1 = -d + k1Start
                while k1 <= d - k1End {
                    let index = offset + k1
                    var x = (k1 == -d || (k1 != d && forward[index - 1] < forward[index + 1]))
                        ? forward[index + 1] : forward[index - 1] + 1
                    var y = x - k1
                    while x < n, y < m, a[aLo + x] == b[bLo + y] {
                        x += 1
                        y += 1
                    }
                    forward[index] = x
                    if x > n {
                        k1End += 2
                    } else if y > m {
                        k1Start += 2
                    } else if deltaIsOdd {
                        let k2Index = offset + delta - k1
                        if k2Index >= 0, k2Index < size, backward[k2Index] != -1, x >= n - backward[k2Index] {
                            return (aLo + x, bLo + y)
                        }
                    }
                    k1 += 2
                }
                var k2 = -d + k2Start
                while k2 <= d - k2End {
                    let index = offset + k2
                    var x = (k2 == -d || (k2 != d && backward[index - 1] < backward[index + 1]))
                        ? backward[index + 1] : backward[index - 1] + 1
                    var y = x - k2
                    while x < n, y < m, a[aHi - x - 1] == b[bHi - y - 1] {
                        x += 1
                        y += 1
                    }
                    backward[index] = x
                    if x > n {
                        k2End += 2
                    } else if y > m {
                        k2Start += 2
                    } else if !deltaIsOdd {
                        let k1Index = offset + delta - k2
                        if k1Index >= 0, k1Index < size, forward[k1Index] != -1 {
                            let x1 = forward[k1Index]
                            let y1 = x1 - (k1Index - offset)
                            if x1 >= n - x {
                                return (aLo + x1, bLo + y1)
                            }
                        }
                    }
                    k2 += 2
                }
            }
            // Unreachable for valid input: the paths always meet by maxD.
            // Splitting after the first old line still terminates correctly.
            return (aLo + 1, bLo)
        }
    }
}
