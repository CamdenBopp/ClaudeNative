import AppKit

/// Where Copy message, Copy code and Copy Output put their text: the
/// system clipboard, or a private one a test names so a run doesn't
/// replace what the person had copied.
@MainActor
enum Clipboard {
    static var board = NSPasteboard.general

    static func copy(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
