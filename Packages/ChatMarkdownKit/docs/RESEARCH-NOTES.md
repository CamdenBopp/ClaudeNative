# Research notes — reference repos

Cloned shallow into `research/` (gitignored, never committed). Verified
2026-07-01 from the actual source, not from blog posts.

## License and reuse rules

| Repo | License (verified) | Reuse policy |
|---|---|---|
| `Telegram-iOS` | **No LICENSE file at repo root**; README requires derivative code publication (copyleft, historically GPL-2.0) | **Study only. Never copy code, never depend on.** Patterns (asyncLayout shape, cached-layout compare) are reimplemented from scratch. |
| `Runestone` | MIT (LICENSE at root) | May adapt code with attribution; primarily an architecture reference. |
| `swift-markdown` | Apache-2.0 | SPM dependency (already in Package.swift). |
| `SwiftTreeSitter` | BSD-3-Clause (Chime) | Candidate SPM dependency for code highlighting (milestone 6). |
| `Neon` | BSD-3-Clause (Chime) | Reference for highlight-query lifecycle and invalidation-range handling; possible dependency later. |
| `CodeEditTextView` | MIT | Reference for a from-scratch CoreText text view (macOS/NSView, lazy layout on large documents). |

## Key study entry points (verified paths)

### Telegram TextNode — the async layout pattern
- `research/Telegram-iOS/submodules/Display/Source/TextNode.swift`
  - `TextNode.asyncLayout(_:)` at **line 2784** — the load-bearing pattern:
    1. Capture `cachedLayout` from the (optional) existing node.
    2. Return a closure safe to call on a background queue. It compares the
       new arguments (constrained size, attributed string equality, line
       limits, cutouts…) against the cached layout and either reuses it or
       calls `calculateLayout` (CoreText: CTFramesetter → CTLine array with
       per-line origins/bounds).
    3. The closure returns `(TextNodeLayout, () -> TextNode)` — an immutable
       layout value plus a **commit closure** the caller applies on main.
  - `calculateLayout` shows the line-based layout storage: an array of
    line records (CTLine + frame), not a live layout manager. Heights for
    list cells come from these background-computed values, so the list
    never measures text on main.
  - Our simplified equivalent: `TextLayoutEngine.layout` (pure function) +
    revision-checked commit; the cached-compare front door arrives with the
    layout scheduler (next milestone).

### Runestone — line-oriented code documents
- `research/Runestone/Sources/Runestone/LineManager/LineManager.swift` —
  lines live in a red-black tree keyed by position with aggregated
  `yPosition`/`lineHeight` and `nodeTotalCount`, giving O(log n) line lookup
  by y-offset and O(log n) edits. Uses `estimatedLineHeight` until a line is
  actually laid out.
- `research/Runestone/Sources/Runestone/TextView/LineController/LineController.swift`
  (+ `LineControllerStorage.swift`) — per-line lazy layout/render objects,
  created for the visible range only and recycled.
- `research/Runestone/Sources/Runestone/TreeSitter/` — incremental parsing
  integration (edits fed as ranges, captures → highlight spans).
- Deliberate divergence for chat: LLM code blocks are **append-only**, so
  `CodeBlockDocument` uses a plain line array (O(1) append, exact) instead
  of a red-black tree. The tree becomes necessary only if in-place editing
  ever appears. Variable line heights are also mostly moot (monospace, no
  wrapping by default → uniform line height → direct index math instead of
  y-position tree search).

### swift-markdown
- Parses GFM (tables, strikethrough) via cmark-gfm; AST is walkable and
  cheap for message-sized inputs. It is **not incremental** — our streaming
  strategy (stable-identity reconciliation now, tail-only reparse next) is
  layered on top in `StreamingMessageAssembler`, not inside the parser.

### SwiftTreeSitter / Neon
- SwiftTreeSitter wraps tree-sitter's C runtime (parser lifecycle,
  `InputEdit`, queries). Neon shows how to manage highlight queries and
  invalidation ranges over an evolving document. Grammar packaging (per-
  language dylibs/SPM targets) is the main integration cost to evaluate at
  milestone 6.

### CodeEditTextView
- A from-scratch CoreText NSView text view by the CodeEdit team, built
  because TextKit 2 could not be made fast enough on very large documents.
  Useful cross-check for our lazy-line-layout approach (their `TextLayoutManager`
  does viewport-only layout with estimated heights elsewhere).

## Standing conclusions

1. **CoreText + background layout + immutable cached line snapshots** is the
   rendering foundation (Telegram-validated). TextKit 2 stays out of the
   hot path (unstable height estimates / `ensureLayout` cost on large
   documents — the failure mode is documented in the wild, including by the
   STTextView author).
2. **Line-oriented code blocks** are a separate subsystem from prose layout
   (Runestone-validated), simplified to append-only storage.
3. **swift-markdown parses; identity lives in our reconciler.** The parser
   is treated as a pure function from source text to AST; streaming
   efficiency comes from what we re-parse and what identity we preserve,
   not from parser internals.
