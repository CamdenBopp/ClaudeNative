# ChatMarkdownKit

A high-performance streaming Markdown/chat renderer for UIKit. Built for LLM
responses: token-by-token streaming, long prose, and very large syntax-
highlighted code blocks, without main-thread layout spikes — and with
VoiceOver as a first-class citizen, not an overlay.

## Architecture in one paragraph

Messages parse (swift-markdown) into a semantic block model with **stable
block identity across streaming appends** — an unchanged block is never
re-laid-out because the tail grew. Non-code text lays out off-main via
CoreText into **immutable, cached line snapshots** that the main thread only
draws (the Telegram `TextNode.asyncLayout` pattern). Code blocks are a
separate **line-oriented subsystem** (the Runestone pattern): per-line
storage, visible-range-only layout, incremental highlighting — a 10,000-line
block costs what the viewport costs. The same block model that drives drawing
drives the accessibility projection, so VoiceOver never depends on what is
visually realized.

## Modules

| Target | Role | Frameworks |
|---|---|---|
| `ChatMarkdownCore` | Semantic block model, block identity/revisions, streaming assembler + delta reconciliation | Foundation, swift-markdown |
| `ChatTextLayout` | CoreText line layout for non-code text; immutable `TextLayoutResult` snapshots; attributed-string builder | CoreText, CoreGraphics |
| `ChatCodeBlocks` | Append-only line storage for code blocks (`CodeBlockDocument`), line deltas; later: viewport layout + tree-sitter highlighting | Foundation |
| `ChatMarkdownUI` | UIKit drawing views, chat list integration, accessibility projection | UIKit (iOS-only via `canImport`) |

macOS is in the platform list only so the non-UIKit targets build and test on
a Mac host with plain `swift build` / `swift test`.

## Status

Done:
- [x] Block model with stable `BlockID` (birth-order identity) + revisions
- [x] `StreamingMessageAssembler` v2 — three-tier incremental updates:
      open-fence **fast path** (no parse at all while streaming into a code
      block), **tail-only reparse** behind an advancing frozen prefix, and a
      full-reparse fallback when link-reference definitions appear.
      CommonMark-faithful fence scanner (character/length matching, info
      strings). Enforced by a differential fuzzer against full reparses —
      which caught a real fence-matching bug before it shipped.
- [x] CoreText `TextLayoutEngine`: attributed string → immutable
      `TextLayoutResult` (line snapshots), tight widths, deterministic
- [x] `BlockLayoutEngine`: semantic blocks → positioned draw commands +
      link-region geometry + accessibility labels/roles in one pass
      (headings, quotes, lists, auto-fit tables, rules, HTML-as-literal)
- [x] `BlockLayoutScheduler` actor: off-main layout, LRU cache keyed by
      `RenderCacheKey`, cancellation, stale-commit gate, per-message release
- [x] `MessageStreamRenderer` actor: token coalescing (~48 ms window) +
      unified document/layout event stream — the per-message public API
- [x] Code blocks: `CodeBlockDocument` (append-only line storage) +
      `CodeBlockLayoutEngine` (uniform metrics, viewport row ranges, lazy
      CTLine LRU) + `CodeBlockView` (offset-riding viewport, no full-height
      backing store)
- [x] `TextBlockView`: draw-only commit, heading traits, link hit-testing
- [x] **Multicast subscription model**: `scheduler.commits(for:)` and
      `renderer.subscribe()` return independent streams with snapshot
      catch-up (full document delta + cached layout replay) — cell reuse
      and late attach are safe by construction
- [x] **Accessibility projection layer**: `AccessibilityProjector` maps the
      same blocks + layouts that drive drawing into element models —
      paragraph-level prose bodies, individually focusable/activatable link
      elements (visible text as label, destination as hint), heading traits
      for the rotor. Element *instances* are cached by stable ID so
      VoiceOver focus survives streaming updates.
- [x] **Chunked code-block accessibility**: `CodeAccessibilityChunker` +
      `CodeBlockView` as a container — header element (language, line
      count, "still receiving", copy action) plus dozen-line chunk elements
      materialized only near the viewport; three-finger scroll pages and
      announces "Lines X to Y of N". A 10k-line block is navigable without
      10k elements.
- [x] **UIKit message layer**: `MessageBlockContainerView` (delta apply,
      revision/width-gated commits, vertical stacking, code snapshot
      reconciliation via `CodeStreamReconciler`, link taps),
      `ChatMessageCell` + `MessageRenderBinding` (reuse-safe rebinding)
- [x] `SafeLinkPolicy`: scheme allow-listing (`javascript:`/`data:`/`file:`
      rejected; partial mid-stream URLs rejected)
- [x] **Conversation list**: `ChatConversationViewController` +
      `ChatListLayout` over exact precomputed heights (never UIKit
      self-sizing estimates). Per-message height watchers measure documents
      off-main through `scheduler.measuredContentHeight`, which warms the
      shared layout cache so the eventual cell bind is pure cache hits.
      `MessageLayoutMetrics`/`MessageStacking` is the single stacking-math
      authority (cross-checked by test against the container and the code
      engine), so measured height ≡ rendered height and geometry never
      jumps when a cell appears.
- [x] **Scroll anchoring + auto-follow** as pure policy
      (`ChatListGeometry` prefix-sum frames + binary-search anchors,
      `ChatScrollPolicy` follow/reading regimes with anchor compensation
      and inset-aware clamping) — fully unit-tested off-device.
- [x] **Viewport-relative range states** (`MessageRangePolicy`): every
      message classified visible / display-ready / preload / cold by
      viewport-multiple distance, biased toward fling velocity — never by
      message count (one message can be 24 pt, the next 12,000). Cold
      messages release their layout caches; released messages re-entering
      the preload band rewarm off-main before they can reach the screen.
- [x] **Signpost instrumentation + performance contract**
      (docs/PERFORMANCE.md): OSSignposter intervals/events across parse
      tiers, layout, cache outcomes, stale drops, height measurement, code
      line layout, cell binding, anchor adjustment, and accessibility
      projection — subsystem `net.bopp.ChatMarkdownKit`.
- [x] **Scalar-boundary streaming fuzzer**: every document streamed one
      Unicode scalar at a time (splits CRLF pairs, ZWJ emoji, escapes,
      fence markers) with full-reparse equality after every append. It
      immediately caught two real grapheme-semantics bugs — Character-level
      "\n" splitting/contains never fire inside a "\r\n" grapheme, so the
      fence scanner saw CRLF documents as one line and the code fast path
      byte-appended \r that cmark normalizes away. All stream-boundary
      scanning is now scalar-level.
- [x] 85 tests on the macOS host + iOS Simulator compile check for the
      UIKit layer; differential fuzz corpus extended with adversarial
      fences (info-string closers, mixed ```/~~~, length matching)

- [x] **Working demo app** (`Demo/`): xcodegen project, UIKit app streaming
      a scripted conversation — rich Markdown (headings, lists, table,
      links, quote, inline styles), a 40-line Swift block, and a
      10,000-line disassembly dump streamed into one fenced block. Built,
      launched, and screenshot-verified on the iPhone 15 Pro simulator
      (`Demo/artifacts/`). Regenerate with `xcodegen generate` in `Demo/`.
- [x] **Adversarial review pass** (multi-agent): 7 findings, all confirmed
      by 3-refuter panels, all fixed — pre-viewload `append()` crash
      (`loadViewIfNeeded`), stale container width after rotation (visible
      cells now receive `updateWidth`, layouts cleared to accept new-bucket
      commits), estimate-height restacks clobbering measured heights
      (authoritative-height gating on `onContentHeightChange`), forwarding
      task + scheduler subscriber leak for discarded renderers (renderer
      `deinit` cancels; `releaseMessage` reclaims subscribers;
      re-registration after window release), watcher generation tags,
      empty-complete-document snapshot replay, and post-await width-bucket
      recheck in `measureAndStore`. 91 tests.
- [x] Streaming-table geometry invariant test: cell text rects never
      overlap in any intermediate parse state at any width (the "corrupted
      table" flagged by simulator verification is partial-markdown
      rendering that self-heals — cosmetic, not a gate violation).

Known cosmetic items (deliberate, minor):
- Table column widths reflow while a table streams (re-fit per revision);
  a monotonic-growth policy would steady them.
- Long code lines clip at the panel edge; the block scrolls horizontally
  but shows no affordance until touched (a trailing fade would help).

- [x] **Async block rendering**: `TextBlockView` has no `draw(_:)` — commits
      render block bitmaps off-main (`BlockBitmapRenderer`, pure CoreGraphics,
      generation-gated against stale results, palette resolved from traits at
      request time) and the main thread only assigns `layer.contents`. Device-
      verified: all prose rasterization on background threads; hitch rate
      0.42 ms/s over the heaviest scripted run (docs/PERFORMANCE.md runs 3–4).
- [x] **VoiceOver-driveable demo**: Pace button (slow/normal/fast, announced),
      Replay button, and a ~3× longer script (essay + mixed code/prose
      messages) so there's always live streaming to interact with; scripts
      pre-chunked off-main (a device trace caught main-actor chunking
      blocking a frame at message kickoff).

Next (in order — profiling deliberately precedes tree-sitter: highlighting
is not yet proven to be the bottleneck):
1. Incremental per-block height tracking — measured as the dominant
   aggregate across every device run including the live VoiceOver session
   (docs/PERFORMANCE.md run 5); Dynamic Type: resync TextTheme from the
   system content size category (feature gap found in run 5)
2. Tree-sitter incremental highlighting (SwiftTreeSitter, BSD-3-Clause):
   InputEdit-driven, changed-ranges-only, visibility-prioritized, with its
   own cancellation generation — never parse-whole-block-per-token
3. Image/attachment pipeline: dimensions reserve layout before pixels
   decode (anchor-preserving late corrections); generalized provisional
   completion-state on blocks once images/math consume it
4. Text selection/copy for prose; history pagination (prepend with offset
   preservation); streaming table column-width stabilization;
   horizontal-scroll affordance for code

## Reference material (`research/`, not in this repository)

Cloned for architecture study — see `docs/RESEARCH-NOTES.md` for the exact
files, findings, and license rules. **Telegram-iOS is GPL: study only, never
copy code into this package.**

## Build & test

```sh
swift build
swift test
```
