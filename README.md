# Claude Native

A native macOS app for Claude Code, built for people who use VoiceOver.

Claude Native puts the `claude` command-line tool in an AppKit and SwiftUI window. The agent, its tools, permissions, settings, MCP servers and saved sessions all belong to the CLI. This app is the window around them, and it puts the screen reader first.

This is an independent project. Anthropic doesn't make or support it.

## Why it exists

Chat apps tend to fall apart under a screen reader. Messages split into dozens of fragments, and focus jumps while a reply streams in. Markdown comes out as asterisks and pound signs. A stray Return can approve a permission prompt. Claude Native treats each of those as a bug:

- Every message is one accessibility element that lasts as long as the conversation. A reply is a group named "Claude". Inside it, each heading, paragraph, list, code block, quote, table and link is its own stop.
- Nothing you're reading moves or changes identity while Claude is still writing.
- Markdown is read as text. Lists say "1 of 3", and a code block says its language and length ("Swift code, 3 lines").
- Rotors (VO-U) cover messages, your messages, tool calls, marked messages, code blocks, headings and links.
- VoiceOver hot spots follow a message wherever it scrolls. To come back to a message after relaunching, mark it, then use the Marked Messages rotor.
- The permission sheet can't be answered by Return. Escape denies and Command-Return allows.
- VoiceOver announces when Claude finishes. Spoken progress lines ("Compacting conversation.") and sound cues for tool activity are optional.
- Text scales to 300 percent, and the message bar's controls wrap rather than run off the window.

It also has what you'd expect from the Claude desktop app's Code section. There's a projects sidebar with Command-K search, and menus for the model, effort and mode. You can attach images and queue messages while Claude works. A side panel holds a code editor, a diff reader and a terminal, and the keyboard shortcuts match the desktop app's. The [feature reference](docs/features.md) covers every control, its keys and what VoiceOver says.

## Status

An early preview that hasn't had wide testing.

- macOS only. The app needs macOS 15 or later.
- The test fixtures were recorded from Claude Code 2.1.310. A newer CLI may change the protocol in ways the app doesn't expect yet.
- Accessibility claims are checked under VoiceOver against a written script, and the results are recorded in `docs/`. Some checks still need a person, and the records say which.

## Requirements

- macOS 15 or later
- Xcode with the macOS 27 SDK. It's developed with Swift 6.4, and older toolchains are untested.
- Claude Code installed, signed in or with an `ANTHROPIC_API_KEY`

The app looks for `claude` in the copy the Claude desktop app keeps under `~/Library/Application Support/Claude/claude-code`, then in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. Set `CLAUDE_NATIVE_CLI` to point at another one.

## Build and run

```bash
./Scripts/bundle.sh
```

```bash
open build/ClaudeNative.app
```

`bundle.sh` builds a debug copy and signs it ad hoc. Set `CONFIG=release` for an optimized build.

## Signing in

If the CLI has no account, the first window asks you to sign in. Sign In with Claude.ai opens claude.ai in your browser, and the window carries on once you approve. If the browser doesn't open, use the link in the window and paste the code that page shows. Sign Out is in the app menu.

## Permissions

The app starts every conversation with the CLI's `--allow-dangerously-skip-permissions` flag. Without it, the CLI refuses to switch into Bypass permissions mode partway through a conversation, so the Mode menu couldn't offer it. The flag only makes that mode available. Conversations start in the mode you chose, Manual by default, and every tool still asks first until you pick Bypass permissions yourself.

## Repository layout

- `Sources/ClaudeNativeCore`: the CLI protocol, transcript, sign-in and saved-session code, with no UI.
- `Sources/ClaudeNative`: the SwiftUI and AppKit app.
- `Sources/CodeHighlighting`: tree-sitter highlighting for code blocks and the editor.
- `Packages/ChatMarkdownKit`: the Markdown parser and renderer, a Swift package of its own. Its [README](Packages/ChatMarkdownKit/README.md) explains its design.
- `Tests`: Swift Testing suites, many replaying output captured from the real CLI (`Tests/Fixtures`).
- `Tools/axcheck`: reads another app's accessibility tree, checks an element stays the same over time, and presses or sets elements without sending keystrokes.
- `Scripts/qa.sh`: builds a separate offline QA copy of the app.
- `docs/`: the [stream-json protocol](docs/protocol.md) and [login flow](docs/auth.md) as captured, the [VoiceOver QA script](docs/voiceover-qa.md), an [accessibility comparison](docs/accessibility-comparison.md) with other chat apps, and dated QA records.

## Tests

```bash
swift test
```

```bash
swift test --package-path Packages/ChatMarkdownKit
```

The app's tests host its real views with the accessibility tree turned on and check what an assistive app is handed. Each message must be one element with its author first. Rows must keep their identity while a reply streams and the text size changes. Rotors must stop at the end, and Return must not answer the permission sheet. They can't check what VoiceOver actually says.

For that, `./Scripts/qa.sh` builds **Claude Native QA**, a copy of the app with an offline stand-in for the CLI and its own empty session folder. It never contacts Claude or runs a tool. Its `/qa-` commands replay Markdown, streaming, permission and question sheets, long replies, progress lines and the CLI exiting unexpectedly. The [VoiceOver QA script](docs/voiceover-qa.md) walks through every check, and you should run it before a release.

## Prior art

Ideas came from several projects, but the code here is written from scratch. The four studied in source form below were checked with a line-by-line scan of this repository, which found nothing in common with them beyond Apple API signatures.

ChatMarkdownKit's design:

- [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) (GPL). Its text node lays text out off the main thread into immutable line snapshots and reuses a cached layout when nothing changed. ChatMarkdownKit's text layout follows that approach with its own code. Telegram's source was studied only, never copied or linked.
- [Runestone](https://github.com/simonbs/Runestone) (MIT). Code stored line by line, with layout for the visible lines only. ChatMarkdownKit simplifies this to append-only lines, because a streaming reply only grows.
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) (MIT). A cross-check for laying out only the viewport, with estimated heights everywhere else.
- [Neon](https://github.com/ChimeHQ/Neon) (BSD-3-Clause). How to manage highlight queries and invalidated ranges as a document changes.

The app's behaviour:

- The Claude desktop app sets the wording and keys: the permission questions, the composer's menus, the keyboard shortcuts.
- [Clarc](https://github.com/ttnear/Clarc)'s slash-command picker, where the keyboard stays in the message field while the arrow keys move through the list.
- Seven open-source chat apps audited for accessibility in October 2026: conduck, Modelo, nativ, Perspective Studio, scarf, hermex and OpenGlasses. The [comparison](docs/accessibility-comparison.md) lists what each did well and which ideas came from where. Copy message as a row action, text zoom, sound cues and the split between routine and urgent announcements all started there.

## Dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown) and [swift-cmark](https://github.com/swiftlang/swift-cmark) (Apache-2.0) parse Markdown.
- [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) (BSD-3-Clause) and tree-sitter grammars for Swift, Python, JavaScript, TypeScript, JSON, Bash, Markdown, HTML and CSS (MIT) highlight code.

## License

MIT. See [LICENSE](LICENSE).
