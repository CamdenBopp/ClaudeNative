import Foundation
import Testing
@testable import ClaudeNativeCore

/// Diffs for the CLI's file tools. Tool inputs come from
/// Tests/Fixtures/diff/tool_uses.jsonl, which copies the field shapes of real
/// Edit, MultiEdit and Write calls with made-up content.
struct ToolDiffTests {
    /// How many times each timing is taken; the fastest counts.
    static let timingRuns = 3

    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/diff/tool_uses.jsonl")

    static let garden = "/Users/example/Garden/Sources/Garden/"

    /// The tool_use block with this id from the fixture.
    static func toolUse(_ id: String) throws -> (name: String, input: JSONValue) {
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        for line in lines {
            let block = try JSONValue.parse(Data(line.utf8))
            if block["id"]?.string == id, let name = block["name"]?.string, let input = block["input"] {
                return (name, input)
            }
        }
        throw FixtureMissing(id: id)
    }

    struct FixtureMissing: Error { let id: String }

    static func files(_ files: [String: String]) -> (String) -> String? {
        { files[$0] }
    }

    /// Lines "line 1\n" through "line N\n".
    static func numbered(_ count: Int, ending: String = "\n") -> String {
        (1...count).map { "line \($0)" + ending }.joined()
    }

    // MARK: - Edit

    @Test func singleEditUsesRealFileLineNumbers() throws {
        let call = try Self.toolUse("toolu_edit_single")
        var lines = (1...20).map { "    // note \($0)\n" }
        lines[9] = "    var water = 1\n"
        let file = lines.joined()
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: Self.files([Self.garden + "Planter.swift": file])))

        #expect(!diff.isApproximate)
        #expect(!diff.isNewFile)
        #expect(diff.addedCount == 2)
        #expect(diff.removedCount == 1)
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        try #require(hunk.lines.count == 9)
        #expect(hunk.oldStart == 7)
        #expect(hunk.newStart == 7)
        #expect(hunk.lines.map(\.kind) == [.context, .context, .context, .removed, .added, .added, .context, .context, .context])
        #expect(hunk.lines[3] == DiffLine(kind: .removed, oldNumber: 10, newNumber: nil, text: "    var water = 1", ending: .lf))
        #expect(hunk.lines[4].newNumber == 10)
        #expect(hunk.lines[5].newNumber == 11)
        #expect(hunk.lines[6].oldNumber == 11)
        #expect(hunk.lines[6].newNumber == 12)
        #expect(hunk.title == "Change 1 of 1, lines 7 to 14")
        #expect(hunk.lines[3].spoken == "Removed, line 10:     var water = 1")
        #expect(hunk.lines[5].spoken == "Added, line 11:     var sunlight = 3")
        #expect(hunk.lines[6].spoken == "Unchanged, line 12:     // note 11")
        #expect(diff.summary(relativeTo: URL(fileURLWithPath: "/Users/example/Garden")) == "Edit Sources/Garden/Planter.swift: 2 lines added, 1 removed")
    }

    @Test func editWithoutReplaceAllFieldStillWorks() throws {
        let call = try Self.toolUse("toolu_edit_no_flag")
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: Self.files([Self.garden + "Planter.swift": "a\n    var water = 1\nb\n"])))
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)
        #expect(diff.summary == "Edit \(Self.garden)Planter.swift: 1 line added, 1 removed")
    }

    @Test func replaceAllChangesEveryMatchInSeparatePlaces() throws {
        let call = try Self.toolUse("toolu_edit_replace_all")
        var lines = (1...30).map { "filler \($0)\n" }
        lines[1] = "let a = \"tulip\"\n"
        lines[14] = "let b = \"tulip tulip\"\n"
        lines[27] = "// tulip\n"
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: Self.files([Self.garden + "Seeds.swift": lines.joined()])))

        #expect(!diff.isApproximate)
        #expect(diff.hunks.count == 3)
        #expect(diff.addedCount == 3)
        #expect(diff.removedCount == 3)
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .added }
        #expect(added.map(\.text) == ["let a = \"crocus\"", "let b = \"crocus crocus\"", "// crocus"])
        #expect(added.map(\.newNumber) == [2, 15, 28])
        #expect(diff.hunks.map(\.title) == ["Change 1 of 3, lines 1 to 5", "Change 2 of 3, lines 12 to 18", "Change 3 of 3, lines 25 to 30"])
        #expect(diff.summary.hasSuffix("3 lines added, 3 removed, in 3 places"))
    }

    @Test func withoutReplaceAllOnlyTheFirstMatchChanges() throws {
        let input = JSONValue.object([
            "file_path": .string("/x/a.txt"), "old_string": .string("a"), "new_string": .string("b"), "replace_all": .bool(false),
        ])
        let diff = try #require(ToolDiff.make(toolName: "Edit", input: input, currentFile: { _ in "a\na\n" }))
        #expect(diff.hunks.flatMap(\.lines).map(\.spoken) == ["Removed, line 1: a", "Added, line 1: b", "Unchanged, line 2: a"])
    }

    // MARK: - MultiEdit

    @Test func multiEditAppliesEditsInOrder() throws {
        // The second edit's old_string only exists after the first edit runs.
        let call = try Self.toolUse("toolu_multiedit")
        let file = "let rake = 1\nlet hoe = 1\n" + (1...10).map { "// \($0)\n" }.joined() + "// end\n"
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: Self.files([Self.garden + "Shed.swift": file])))

        #expect(!diff.isApproximate)
        #expect(diff.hunks.count == 2)
        let all = diff.hunks.flatMap(\.lines)
        #expect(all.filter { $0.kind == .removed }.map(\.text) == ["let rake = 1", "// end"])
        #expect(all.filter { $0.kind == .added }.map(\.text) == ["let rake = 3", "let trowel = 1", "// end of shed"])
        #expect(all.filter { $0.kind == .added }.map(\.newNumber) == [1, 3, 14])
        #expect(diff.summary == "MultiEdit \(Self.garden)Shed.swift: 3 lines added, 2 removed, in 2 places")
    }

    @Test func multiEditInReverseOrderFallsBackToApproximate() throws {
        let call = try Self.toolUse("toolu_multiedit")
        guard case .object(var input) = call.input, var edits = input["edits"]?.array else {
            Issue.record("fixture shape changed")
            return
        }
        edits.reverse()
        input["edits"] = .array(edits)
        let file = "let rake = 1\nlet hoe = 1\n// end\n"
        let diff = try #require(ToolDiff.make(toolName: "MultiEdit", input: .object(input), currentFile: { _ in file }))
        #expect(diff.isApproximate)
    }

    // MARK: - Write

    @Test func writeToNewFileIsAllAdded() throws {
        let call = try Self.toolUse("toolu_write_new")
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: { _ in nil }))
        #expect(diff.isNewFile)
        #expect(!diff.isApproximate)
        #expect(diff.addedCount == 3)
        #expect(diff.removedCount == 0)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].oldStart == 0)
        #expect(diff.hunks[0].oldCount == 0)
        #expect(diff.hunks[0].lines.map(\.spoken) == ["Added, line 1: # Garden notes", "Added, line 2: blank line", "Added, line 3: Water on Tuesdays."])
        #expect(diff.summary == "Write \(Self.garden)Notes.md, new file: 3 lines added")
    }

    @Test func writeToExistingFileDiffsAgainstIt() throws {
        let call = try Self.toolUse("toolu_write_existing")
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: Self.files([Self.garden + "Plan.txt": "Beds: 2\nPaths: 2\nGate: 1\n"])))
        #expect(!diff.isNewFile)
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)
        #expect(diff.hunks[0].lines.map(\.spoken) == ["Removed, line 1: Beds: 2", "Added, line 1: Beds: 3", "Unchanged, line 2: Paths: 2", "Unchanged, line 3: Gate: 1"])
    }

    @Test func finishedWriteWithUnknownOldTextIsApproximate() throws {
        let call = try Self.toolUse("toolu_write_existing")
        let content = try #require(call.input["content"]?.string)
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, moment: .afterTool, currentFile: { _ in content }))
        #expect(diff.isApproximate)
        #expect(!diff.isNewFile)
        #expect(diff.addedCount == 3)
        #expect(diff.hunks[0].title == "Change 1 of 1, lines 1 to 3")
    }

    // MARK: - Approximate

    @Test func missingOldStringFallsBackToApproximate() throws {
        let call = try Self.toolUse("toolu_edit_single")
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: { _ in "something else entirely\n" }))
        #expect(diff.isApproximate)
        #expect(diff.approximateReason == ToolDiff.editNotFoundReason)
        #expect(diff.addedCount == 2)
        #expect(diff.removedCount == 1)
        #expect(diff.hunks[0].lines.map(\.spoken) == ["Removed, line 1:     var water = 1", "Added, line 1:     var water = 2", "Added, line 2:     var sunlight = 3"])
        #expect(diff.hunks[0].title == "Change 1 of 1, lines 1 to 2 of the edited text")
        #expect(diff.summary.hasSuffix(". Approximate: " + ToolDiff.editNotFoundReason))
    }

    @Test func unreadableFileIsApproximate() throws {
        let call = try Self.toolUse("toolu_edit_single")
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: { _ in nil }))
        #expect(diff.isApproximate)
        #expect(diff.approximateReason == ToolDiff.unreadableReason)
    }

    @Test func finishedEditIsRecoveredFromTheFileWithRealNumbers() throws {
        // After the tool ran, the file holds new_string. "x = 1" -> "x = 1 + y"
        // would apply again if diffed forward, so a finished row unapplies it.
        let input = JSONValue.object([
            "file_path": .string("/x/a.swift"), "old_string": .string("x = 1"), "new_string": .string("x = 1 + y"), "replace_all": .bool(false),
        ])
        let after = "a\nb\nc\nd\nx = 1 + y\ne\n"
        let diff = try #require(ToolDiff.make(toolName: "Edit", input: input, moment: .afterTool, currentFile: { _ in after }))
        #expect(!diff.isApproximate)
        let changed = diff.hunks.flatMap(\.lines).filter { $0.kind != .context }
        #expect(changed.map(\.spoken) == ["Removed, line 5: x = 1", "Added, line 5: x = 1 + y"])

        // The same edit before the tool runs diffs forward.
        let before = try #require(ToolDiff.make(toolName: "Edit", input: input, currentFile: { _ in "x = 1\n" }))
        #expect(before.hunks[0].lines.map(\.text) == ["x = 1", "x = 1 + y"])
    }

    @Test func finishedDeletionEditIsApproximate() throws {
        // An empty new_string can't be found in the file afterwards.
        let input = JSONValue.object([
            "file_path": .string("/x/a.swift"), "old_string": .string("gone\n"), "new_string": .string(""), "replace_all": .bool(false),
        ])
        let diff = try #require(ToolDiff.make(toolName: "Edit", input: input, moment: .afterTool, currentFile: { _ in "a\nb\n" }))
        #expect(diff.isApproximate)
        #expect(diff.hunks[0].lines.map(\.spoken) == ["Removed, line 1: gone"])
        #expect(diff.summary.hasPrefix("Edit /x/a.swift: 1 line removed. Approximate: "))
    }

    // MARK: - Exact text

    @Test func crlfLinesKeepTheirTextAndEndings() throws {
        let input = JSONValue.object([
            "file_path": .string("/x/win.txt"), "old_string": .string("two\r\n"), "new_string": .string("TWO\r\n"), "replace_all": .bool(false),
        ])
        let diff = try #require(ToolDiff.make(toolName: "Edit", input: input, currentFile: { _ in "one\r\ntwo\r\nthree\r\n" }))
        #expect(!diff.isApproximate)
        #expect(diff.oldLineEndings == .crlf)
        #expect(diff.newLineEndings == .crlf)
        #expect(diff.hunks[0].lines == [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "one", ending: .crlf),
            DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "two", ending: .crlf),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "TWO", ending: .crlf),
            DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "three", ending: .crlf),
        ])
        #expect(diff.hunks[0].lines[1].spoken == "Removed, line 2: two")
    }

    @Test func changingOnlyLineEndingsIsSpokenAsSuch() throws {
        let input = JSONValue.object(["file_path": .string("/x/win.txt"), "content": .string("one\ntwo\n")])
        let diff = try #require(ToolDiff.make(toolName: "Write", input: input, currentFile: { _ in "one\r\ntwo\r\n" }))
        #expect(diff.addedCount == 2)
        #expect(diff.removedCount == 2)
        #expect(diff.hunks[0].lines[0].spoken == "Removed, line 1: one, CRLF line ending")
        #expect(diff.hunks[0].lines[2].spoken == "Added, line 1: one, LF line ending")
        #expect(diff.summary == "Write /x/win.txt: 2 lines added, 2 removed. Line endings change from CRLF to LF")
    }

    @Test func missingFinalNewlineIsItsOwnFlag() throws {
        let input = JSONValue.object(["file_path": .string("/x/a.txt"), "content": .string("a\nb")])
        let diff = try #require(ToolDiff.make(toolName: "Write", input: input, currentFile: { _ in "a\nb\n" }))
        #expect(diff.newMissingFinalNewline)
        #expect(!diff.oldMissingFinalNewline)
        #expect(diff.hunks[0].lines.map(\.spoken) == ["Unchanged, line 1: a", "Removed, line 2: b", "Added, line 2: b, no newline at end of file"])
        #expect(diff.summary == "Write /x/a.txt: 1 line added, 1 removed. Removes the newline at end of file")

        let created = try #require(ToolDiff.make(toolName: "Write", input: input, currentFile: { _ in nil }))
        #expect(created.summary == "Write /x/a.txt, new file: 2 lines added. No newline at end of file")
    }

    @Test func emptyFiles() throws {
        let empty = JSONValue.object(["file_path": .string("/x/empty.txt"), "content": .string("")])
        let createdEmpty = try #require(ToolDiff.make(toolName: "Write", input: empty, currentFile: { _ in nil }))
        #expect(createdEmpty.hunks.isEmpty)
        #expect(createdEmpty.isNewFile)
        #expect(createdEmpty.summary == "Write /x/empty.txt, new file: no changes")

        let emptied = try #require(ToolDiff.make(toolName: "Write", input: empty, currentFile: { _ in "a\nb\n" }))
        #expect(emptied.removedCount == 2)
        #expect(emptied.hunks[0].newCount == 0)
        #expect(emptied.hunks[0].title == "Change 1 of 1, old lines 1 to 2")

        let filled = JSONValue.object(["file_path": .string("/x/empty.txt"), "content": .string("hello\n")])
        let fromEmpty = try #require(ToolDiff.make(toolName: "Write", input: filled, currentFile: { _ in "" }))
        #expect(!fromEmpty.isNewFile)
        #expect(fromEmpty.hunks[0].lines.map(\.spoken) == ["Added, line 1: hello"])

        // An Edit with an empty old_string creates the file.
        let create = JSONValue.object(["file_path": .string("/x/new.txt"), "old_string": .string(""), "new_string": .string("hi\n")])
        let createdByEdit = try #require(ToolDiff.make(toolName: "Edit", input: create, currentFile: { _ in nil }))
        #expect(createdByEdit.isNewFile)
        #expect(!createdByEdit.isApproximate)
        #expect(createdByEdit.addedCount == 1)
    }

    @Test func tabsUnicodeAndWhitespaceArePreserved() throws {
        let input = JSONValue.object(["file_path": .string("/x/u.txt"), "content": .string("\tcafé ☕️ 👩🏽‍💻\n  \n")])
        let diff = try #require(ToolDiff.make(toolName: "Write", input: input, currentFile: { _ in nil }))
        #expect(diff.hunks[0].lines[0].text == "\tcafé ☕️ 👩🏽‍💻")
        #expect(diff.hunks[0].lines[1].text == "  ")
        #expect(diff.hunks[0].lines[1].spoken == "Added, line 2: only whitespace")
    }

    @Test func otherToolsHaveNoDiff() {
        #expect(ToolDiff.make(toolName: "Bash", input: .object(["command": .string("ls")]), currentFile: { _ in nil }) == nil)
        #expect(ToolDiff.make(toolName: "Read", input: .object(["file_path": .string("/x")]), currentFile: { _ in "" }) == nil)
        #expect(ToolDiff.make(toolName: "Edit", input: .object(["file_path": .string("/x")]), currentFile: { _ in "" }) == nil)
    }

    @Test func notebookCellReplaceDiffsTheCell() throws {
        let call = try Self.toolUse("toolu_notebook")
        let notebook = ##"{"cells":[{"id":"c1","cell_type":"markdown","source":["# Yield"]},{"id":"c2","cell_type":"code","source":["total = beds * 3\n","print(total)"]}],"nbformat":4}"##
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: { _ in notebook }))
        #expect(!diff.isApproximate)
        #expect(diff.cellID == "c2")
        #expect(diff.hunks[0].lines.map(\.spoken) == ["Removed, line 1: total = beds * 3", "Added, line 1: total = beds * 4", "Unchanged, line 2: print(total), no newline at end of file"])
        #expect(diff.summary == "NotebookEdit cell c2 in \(Self.garden)Yield.ipynb: 1 line added, 1 removed")
    }

    // MARK: - Spoken counting

    @Test func countingWords() {
        #expect(FileDiff.counts(added: 1, removed: 0) == "1 line added")
        #expect(FileDiff.counts(added: 2, removed: 1) == "2 lines added, 1 removed")
        #expect(FileDiff.counts(added: 0, removed: 1) == "1 line removed")
        #expect(FileDiff.counts(added: 0, removed: 0) == "no changes")
        #expect(Hunk.range(4, 1) == "line 4")
        #expect(Hunk.range(4, 3) == "lines 4 to 6")
    }

    @Test func noEmDashesInSpokenText() throws {
        let call = try Self.toolUse("toolu_edit_single")
        let diff = try #require(ToolDiff.make(toolName: call.name, input: call.input, currentFile: { _ in "x\n" }))
        let spoken = [diff.summary] + diff.hunks.map(\.title) + diff.hunks.flatMap(\.lines).map(\.spoken)
        #expect(!spoken.contains { $0.contains("\u{2014}") || $0.contains("\u{2013}") })
    }

    // MARK: - Algorithm

    /// Length of the longest common subsequence, by plain dynamic programming.
    static func lcsLength(_ a: [Int], _ b: [Int]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    @Test func myersIsMinimalOnRandomInputs() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let a = (0..<Int.random(in: 0...25, using: &generator)).map { _ in Int.random(in: 0...4, using: &generator) }
            let b = (0..<Int.random(in: 0...25, using: &generator)).map { _ in Int.random(in: 0...4, using: &generator) }
            var removed = [Bool](repeating: false, count: a.count)
            var added = [Bool](repeating: false, count: b.count)
            Myers.diff(a, b, removed: &removed, added: &added)
            let keptA = zip(a, removed).filter { !$0.1 }.map(\.0)
            let keptB = zip(b, added).filter { !$0.1 }.map(\.0)
            #expect(keptA == keptB, "kept lines must match: \(a) vs \(b)")
            #expect(keptA.count == Self.lcsLength(a, b), "not minimal: \(a) vs \(b)")
        }
    }

    @Test func fiveThousandLineFileDiffsFast() throws {
        let lineCount = 5000
        let old = Self.numbered(lineCount)
        // 50 changed lines, 25 inserted and 25 deleted, spread through the file.
        var newLines: [String] = []
        for index in 0..<lineCount {
            switch index % 200 {
            case 10:
                newLines.append("line \(index + 1)\n")
                newLines.append("inserted \(index)\n")
            case 110:
                continue
            case 50, 150:
                newLines.append("changed \(index)\n")
            default:
                newLines.append("line \(index + 1)\n")
            }
        }
        let input = JSONValue.object(["file_path": .string("/x/big.txt"), "content": .string(newLines.joined())])

        // Best of three runs: under a busy parallel test run one run could
        // take 250 ms where its usual is a few, and fail a 200 ms limit
        // without the diff being slow.
        func fastest(_ work: () -> Void) -> Duration {
            (0..<Self.timingRuns).map { _ in ContinuousClock().measure(work) }.min() ?? .zero
        }
        var diff: FileDiff?
        let scattered = fastest {
            diff = ToolDiff.make(toolName: "Write", input: input, currentFile: { _ in old })
        }
        let result = try #require(diff)
        #expect(result.addedCount == 75)
        #expect(result.removedCount == 75)

        // Worst case: no line in common, so D = 10,000.
        let other = JSONValue.object(["file_path": .string("/x/big.txt"), "content": .string(Self.numbered(lineCount, ending: " changed\n"))])
        let disjoint = fastest {
            diff = ToolDiff.make(toolName: "Write", input: other, currentFile: { _ in old })
        }
        #expect(diff?.removedCount == lineCount)
        #expect(diff?.addedCount == lineCount)

        // Hard case: every other line changed, so D = 5,000 with matches
        // spread all through the file.
        let alternating = (1...lineCount).map { $0 % 2 == 0 ? "line \($0)\n" : "other \($0)\n" }.joined()
        let halfInput = JSONValue.object(["file_path": .string("/x/big.txt"), "content": .string(alternating)])
        let half = fastest {
            diff = ToolDiff.make(toolName: "Write", input: halfInput, currentFile: { _ in old })
        }
        #expect(diff?.removedCount == lineCount / 2)
        #expect(diff?.addedCount == lineCount / 2)

        // Worst case for Myers: only 3 distinct lines, shuffled with a fixed
        // pattern, so nothing is set aside and D is in the thousands.
        let shapes = ["}\n", "\n", "x\n"]
        let shuffledOld = (0..<lineCount).map { shapes[($0 * 7 + $0 / 3) % 3] }.joined()
        let shuffledNew = (0..<lineCount).map { shapes[($0 * 5 + $0 / 4) % 3] }.joined()
        let shuffledInput = JSONValue.object(["file_path": .string("/x/big.txt"), "content": .string(shuffledNew)])
        let shuffled = fastest {
            diff = ToolDiff.make(toolName: "Write", input: shuffledInput, currentFile: { _ in shuffledOld })
        }
        #expect(diff != nil)

        print("ToolDiff timing (5000 lines): 100 changes \(scattered), every line changed \(disjoint), every other line changed \(half), 3 shuffled line shapes \(shuffled) with \((diff?.addedCount ?? 0) + (diff?.removedCount ?? 0)) changed lines")
        #expect(scattered < .milliseconds(200))
        #expect(disjoint < .milliseconds(200))
        #expect(half < .seconds(1))
        #expect(shuffled < .seconds(3))
    }
}
