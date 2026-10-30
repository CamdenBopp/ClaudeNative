# Performance contract

Targets for ChatMarkdownKit on a physical iPhone (mid-range, not just Pro
hardware). The demo app (`Demo/`) is the profiling fixture.

## Run 5 — finger-driven VoiceOver session, 2026-07-03

4-minute trace while the user drove the demo under VoiceOver: three-finger
paging through the 10k dump (post focus-fix build), scroll-back through
history, Replay (signposts show exactly two full script runs), pace changes.
Trace: `Demo/artifacts/device-run-voiceover.trace`.

- **Zero hangs.** 19 hitches, every one a single frame (12.5/16.7 ms) —
  **1.09 ms/s** under live assistive-tech interaction + streaming +
  scrolling (Apple "good" bar: 5 ms/s).
- Accessibility projection stayed cheap with VoiceOver attached: 1,426
  invocations, p95 0.19 ms, max 0.43 ms.
- The rebind path finally got exercised: 59 cell binds (max 0.06 ms) and
  134 cache hits — scroll-back replays from the warm cache as designed.
- height.measure remains the dominant aggregate (745 calls, 1.44 s total,
  p95 8.7 ms): incremental per-block height tracking is now clearly the
  next optimization.
- Remaining unmeasured: Dynamic Type response (theme doesn't resync from
  system text size yet — feature gap, not measurement gap).

## Runs 3–4 — async block rendering, 2026-07-02

`TextBlockView` no longer implements `draw(_:)`: commits kick a background
`BlockBitmapRenderer` pass (pure CoreGraphics, generation-gated) and the
main thread only assigns `layer.contents`. Verified on device: **all 388
`prose.render` intervals ran on background threads** (p50 0.60 ms, p95
1.97 ms); the `CABackingStoreUpdate` hitch class is gone from commits.

Run 4 (60 s, Release, the ~3× longer VoiceOver-ready script): **2 hitches
× 12.5 ms = 0.42 ms/s** (run 1: 0.92, run 2: 0.66), zero hangs. Both
survivors are single 80 Hz frames of ordinary `_updateVisibleCellsNow`
collection-view bookkeeping — the ambient floor for a live list.

Run 3 additionally caught the demo itself blocking a frame: `wordChunks`
chunking a 1,300-word script on the main actor at message kickoff. Scripts
are now pre-chunked off-main. (Lesson generalizes: token *producers* must
not do O(document) work on the main actor.)

Still open: finger-driven session (fling/scroll-back/VoiceOver/Dynamic
Type), incremental height tracking (`height.measure` remains the largest
aggregate), and bitmap prewarming for the display range if scroll-in ever
shows a blank first frame.

## Second run — Release build + hitch fixes, 2026-07-02

Same device/scenario as run 1, Release configuration, after three fixes:
witness-free freeze-boundary scan, visibility-gated code viewport redraws,
and 100-line-bucketed accessibility refreshes for streaming code blocks.
Trace: `Demo/artifacts/device-run-release.trace`.

| Interval | count | p50 ms | p95 ms | max ms | run-1 max |
|---|---:|---:|---:|---:|---:|
| height.measure | 135 | 1.04 | 7.48 | 12.81 | 16.34 |
| prose.layout | 38 | 0.76 | 2.28 | 3.16 | 4.91 |
| stream.flush | 125 | 0.25 | 0.57 | **3.20** | **45.93** |
| stream.tailReparse | 36 | 0.23 | 0.68 | **3.18** | **45.90** |
| scroll.anchorAdjust | 54 | 0.15 | 0.68 | 3.31 | 2.30 |
| code.viewportDraw | 23 | 0.26 | 1.03 | 2.02 | n/a |
| accessibility.project | 181 | 0.03 | 0.13 | 0.22 | 0.42 |
| prose.draw | 39 | 0.09 | 0.19 | 0.25 | n/a |

- **Flush outlier eliminated**: the 45.9 ms spike was the freeze-boundary
  scan iterating `bytes.indices` through Collection witnesses (-Onone
  pathology, confirmed by profiler stacks); a plain while-loop plus the
  Release build brings worst-case flush to 3.2 ms.
- **Redraw gate works**: 94 code appends produced only 23 viewport draws
  (previously 1:1) — appends below the capped viewport no longer repaint
  or rebroadcast accessibility labels every flush.
- **Hitches**: 2 genuine single-frame misses in 44 s (16.7 ms + 12.5 ms ≈
  0.66 ms/s; Apple's "good" bar is < 5 ms/s), plus one teardown artifact
  at the recording limit. Attribution: one CABackingStoreUpdate
  rasterization of a growing prose block during commit, one UIKit trait
  propagation when a subview joined mid-stream. Eliminating the first
  class entirely means async block rendering — draw block bitmaps
  off-main and commit `layer.contents` (the full Telegram pattern the
  immutable-snapshot architecture was designed to allow). Roadmapped.
- height.measure improved (total 675 → 319 ms) but remains the largest
  aggregate; incremental per-block height tracking is still queued.

## First measured results (Debug build) — 2026-07-02

Device: iPhone 14 Pro Max (A16), iOS 27.0, Debug build, hands-free scripted
run (full conversation incl. the 10,000-line dump), 45 s trace: Time
Profiler + os_signpost + Hangs + Hitches. Trace:
`Demo/artifacts/device-run.trace`; analyzer:
`Demo/artifacts/analyze_signposts.py`.

| Interval | count | p50 ms | p95 ms | max ms |
|---|---:|---:|---:|---:|
| height.measure (off-main) | 130 | 1.34 | 15.29 | 16.34 |
| stream.flush (off-main) | 120 | 0.39 | 1.65 | 45.93 |
| stream.tailReparse | 37 | 0.50 | 2.98 | 45.90 |
| prose.layout (off-main) | 40 | 0.96 | 3.78 | 4.91 |
| accessibility.project (main) | 178 | 0.05 | 0.27 | 0.42 |
| scroll.anchorAdjust (main) | 54 | 0.16 | 0.53 | 2.30 |
| stream.fullReparse | 5 | 0.29 | 4.59 | 4.59 |
| code.visibleLineLayout | 89 | 0.03 | 0.12 | 0.16 |
| cell.bind (main) | 6 | 0.03 | 0.29 | 0.29 |

Events: 89 code.append, 83 stream.fastPath, 40 cache.miss, 1 cache.hit.
**Zero hang-risks; 3 hitches × 12.5 ms** across 40.8 s of continuous
streaming with bottom-follow scrolling.

Contract verdicts from this run:
- Main-thread ≤ 8 ms: **met** — worst main-thread phase 2.3 ms
  (scroll.anchorAdjust); no hangs detected.
- Zero parses while streaming code: **met** — the 10k dump moved entirely
  through the fast path (83 byte-appends; the 42 parses belong to the
  prose messages).
- Bounded code-line work: **met** — 89 CTLines ever created against a
  10,001-line document (viewport-only, as designed).
- p95 flush ≤ 100 ms: **met** (1.65 ms); one 45.9 ms outlier at t≈8.9 s
  (single tail reparse, off-main, mid-stream — not first-parse warmup).
  Open item: identify and shave it.
- Known gaps in this run: hands-free means no fling, no history
  scroll-back (hence 1 cache hit — the hit path only pays off on rebind),
  no VoiceOver interaction, no Dynamic Type change. Those need a
  finger-driven session.
- height.measure p95 of 15 ms serializes the scheduler actor while
  streaming; incremental height deltas (reuse unchanged block heights
  across revisions) are the obvious next optimization if traces show
  commits queuing behind it.

## Targets

Streaming (while a message receives tokens):
- p50 token-to-draw latency (ingest → visible pixel change): **< 16 ms**
  plus the coalescing window (default 48 ms ceiling).
- p95 token-to-draw latency: **< 100 ms**.
- No single main-thread task over **8 ms** during ordinary streaming.
- Zero Markdown parses during code-block body streaming (fast path;
  enforced today by `StreamingPerformanceTests`).

Scrolling (1,000-message conversation):
- No layout computation for off-screen prose during a fling (scheduler
  work is delta- and bind-driven only).
- No synchronous highlighting or parsing in scroll callbacks.
- Frame hitch rate: measure first, then set the threshold from the trace.

Memory:
- Retained-window release is observable (signpost + scheduler cache size)
  and bounded: cold messages retain heights and documents only.
- A 10,000-line code block keeps a bounded CTLine cache
  (`CodeBlockLayoutEngine` LRU, ~400 KB budget) regardless of scroll depth.
- Repeated scroll cycles over a full conversation do not grow the resident
  set (LRU churn only).

Accessibility:
- VoiceOver element navigation never synchronously lays out prose
  (projection reads committed layouts only).
- A 10,000-line code block exposes O(visible chunks) accessibility
  elements, never O(lines).

## Signpost phases

Subsystem `net.bopp.ChatMarkdownKit`; profile with the os_signpost
Instruments template. Categories and phases:

| Category | Phase | Kind | Where |
|---|---|---|---|
| streaming | `stream.flush` | interval | coalesced chunk append (`MessageStreamRenderer`) |
| streaming | `stream.fastPath` | event | open-fence byte append, zero parses |
| streaming | `stream.tailReparse` | interval | frozen-prefix tail parse |
| streaming | `stream.fullReparse` | interval | full-source parse (finish, or link-ref mode) |
| layout | `prose.layout` | interval | one block laid out off-main |
| layout | `cache.hit` / `cache.miss` | event | scheduler cache outcome per request |
| layout | `commit.staleDropped` | event | stale gate rejected a finished layout |
| layout | `height.measure` | interval | off-screen message height calculation |
| code | `code.visibleLineLayout` | interval | CTLine creation for one code row (cache miss) |
| code | `code.append` | event | code document append applied to the engine |
| list | `cell.bind` | interval | cell reuse + fresh subscription |
| list | `scroll.anchorAdjust` | interval | geometry rebuild + offset compensation |
| list | `accessibility.project` | interval | container accessibility tree rebuild |
| layout | `prose.render` | interval | block bitmap rasterization (background) |
| list | `code.viewportDraw` | interval | code viewport rasterization (main thread) |

Planned (not yet emitted): `code.highlight` (tree-sitter milestone),
`cache.evict`, `accessibility.materializeCodeChunk`.

Profile Release builds (`-configuration Release`): -Onone exaggerates
generic-heavy Swift by an order of magnitude (measured: the same scan was
46 ms Debug, ≤ 3 ms Release).

## Method

1. Build the demo for a physical device (signed; `Demo/project.yml`).
2. Instruments → os_signpost + Time Profiler + Hangs, filter subsystem.
3. Run the scripted conversation; capture during: initial stream, fling
   through history, return-to-bottom, VoiceOver pass.
4. MetricKit adoption (hang rate, hitch rate in production) once a host
   app ships this — not applicable to the demo.


## Shared package audit October 7 2026

The shared APIs and semantic model remain source-compatible. Cursor-based
identity matching removes repeated array copies for duplicate document blocks;
in-place inline merging removes growing-string copies at soft line breaks;
code snapshot suffix extraction uses exact UTF-8 offsets while retaining
String.hasPrefix and canonical-equivalent fallback semantics. AppKit caches
attributes within larger projections and bypasses that cache for small leaf
blocks. These changes add no runtime dependencies.

Warm Release medians on Apple M2 Pro (12 cores, 16 GB), macOS 27.0.1,
Apple Swift 6.4. Current parser dependencies are swift-markdown/cmark 0.8.0.
Measurements exclude UI layout, rendering frames, and network or disk work.

| Operation | Before | After |
| --- | ---: | ---: |
| Session edit retaining 8,000 duplicate paragraph identities | 255.52 ms | 10.54 ms |
| Parse one 20,000-line paragraph with soft breaks | 298.68 ms | 10.26 ms |
| Apply 3,000 growing code snapshots | 1,181.44 ms | 594.76 ms |
| AppKit projection of 5,000 rich paragraphs with repeated links | 57.03 ms | 40.62 ms |
| AppKit projection of 5,000 independent rich blocks | 66.57 ms | 66.59 ms |

The code benchmark runs both algorithms on identical snapshots in the same
process. Core fixtures use seven samples; code fixtures use five. The AppKit
baseline is an archived 71d93e8 build with dependencies 0.9.0; its fixture
constructs semantic blocks directly and performs no parser work.

The full shared suite passes with dependencies 0.8.0 (149 tests) and 0.9.0
(150 tests, including an additional historical oracle). The optimized AppKit
renderer exactly matches the original attributed strings for 804 fixture/style
combinations. A deliberate nested-list indentation correction is checked by
its own regression. Unicode suffix behavior matches the previous algorithm in
2,500 seeded cases plus scalar-boundary, combining-mark, emoji, CRLF, and NUL
fixtures. Duplicate tests retain snapshots and check FIFO IDs and UTF-8 source
ranges. The UIKit demo also builds in Release for iOS Simulator.

The normal suites check semantics and work counts. Enable diagnostic timings:

```sh
CHAT_MARKDOWN_BENCHMARKS=1 swift test -c release --filter CorePerformanceBenchmarks
CHAT_MARKDOWN_BENCHMARKS=1 swift test -c release --filter CodePerformanceBenchmarks
MARKDOWN_PERF=1 swift test -c release --filter AppKitMarkdownRendererTests
swift test -c release
```

Neon's adapter measurements and source-editor changes are documented in the
sibling checkout's `Neon/docs/MarkdownPerformance.md`.

### Historical source comparison

The October 6 performance commit 4a06b13 improves the following workloads
against 6909553. The subsequent 71d93e8 retains these improvements; its measured
streaming source is unchanged. The duplicate-document queue was introduced
with the new full-document session in 71d93e8 and is fixed by this audit.

| Workload | 6909553 | 4a06b13 | 71d93e8 |
| --- | ---: | ---: | ---: |
| Stream 3,200 rich paragraphs | 354.33 ms | 53.91 ms | 54.86 ms |
| Stream 2,000 words into one paragraph | 606.75 ms | 25.30 ms | 26.61 ms |
| Stream 8,000 code lines | 40.57 ms | 30.55 ms | 31.24 ms |
| Warm 800-item list layout | 27.67 ms | 1.57 ms | Same implementation |
| Warm 800-child quote layout | 17.25 ms | 0.64 ms | Same implementation |
| Warm 400-row table layout | 20.81 ms | 0.86 ms | Same implementation |

Direct conversion of 800 rich paragraphs measures 1.634 ms versus 12.995 ms
through the independent swift-markdown oracle, about eight times faster.
Historical snapshots all use the current compiler and the retained 0.9.0
parser pins. This compares source versions under one environment, rather than
reconstructing their original release environments. Stream fixtures use three
whole-stream samples; parse fixtures use nine; warm layouts use five samples
of twenty layouts.

Historical fixtures and pins live in `Tools/Performance`, outside the normal
test targets. To repeat the historical streaming/layout comparison, run from
this package checkout, replacing the revision as needed:

```sh
audit_checkout=$(mktemp -d /tmp/chatmarkdown-history.XXXXXX)
git archive 6909553 | tar -x -C "$audit_checkout"
cp Tools/Performance/HistoricalBenchmarkTests.swift "$audit_checkout/Tests/ChatMarkdownCoreTests/"
cp Tools/Performance/HistoricalLayoutBenchmarkTests.swift "$audit_checkout/Tests/ChatTextLayoutTests/"
cp Tools/Performance/historical-dependencies.json "$audit_checkout/Package.resolved"
cd "$audit_checkout"
CHAT_MARKDOWN_HISTORY_BENCHMARKS=1 swift test -c release --filter historicalCommonWorkloads
CHAT_MARKDOWN_HISTORY_BENCHMARKS=1 swift test -c release --skip-build --filter historicalLayoutWorkloads
```

For 4a06b13 and 71d93e8, add `-Xswiftc -DCHAT_MARKDOWN_DIRECT_PARSER` to the
first command to include the direct-parser comparison. Run timings serially
with builds finished. An unchanged parser-call counter does not establish
linear total cost: immutable source/body/block snapshots still copy growing
values, and complete code snapshots still validate their entire prior prefix.
