// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatMarkdownKit",
    platforms: [
        .iOS(.v16),
        // macOS is included so the non-UIKit targets (document model, CoreText
        // layout, code-line storage) can be built and unit-tested on a Mac host
        // with plain `swift build` / `swift test`. The UIKit layer compiles to
        // an empty module on macOS via `#if canImport(UIKit)`.
        .macOS(.v13),
    ],
    products: [
        .library(name: "ChatMarkdownKit", targets: ["ChatMarkdownUI"]),
        .library(name: "ChatMarkdownCore", targets: ["ChatMarkdownCore"]),
        .library(name: "ChatMarkdownAppKit", targets: ["ChatMarkdownAppKit"]),
    ],
    dependencies: [
        // Apache-2.0. Semantic Markdown AST (cmark-gfm underneath). Kept as the
        // correctness ORACLE the fast cmark-direct parser is differential-tested
        // against.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
        // The reference CommonMark/GFM parser itself. Same package swift-markdown
        // builds on; pinned identically so it co-resolves. We walk its C node tree
        // straight into our value model, skipping swift-markdown's class AST.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.8.0"),
    ],
    targets: [
        // Semantic document model, block identity, streaming reconciliation.
        // No UIKit, no CoreText — pure value types plus the swift-markdown parse.
        .target(
            name: "ChatMarkdownCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        // CoreText line layout for non-code rich text (Telegram TextNode pattern:
        // layout off-main, immutable cached result, cheap main-thread draw).
        .target(name: "ChatTextLayout", dependencies: ["ChatMarkdownCore"]),
        // Line-oriented code block storage + (later) incremental highlighting
        // (Runestone pattern: per-line storage, visible-range-only layout).
        .target(name: "ChatCodeBlocks", dependencies: ["ChatMarkdownCore"]),
        // UIKit drawing views, chat list integration, accessibility projection.
        .target(
            name: "ChatMarkdownUI",
            dependencies: ["ChatMarkdownCore", "ChatTextLayout", "ChatCodeBlocks"]
        ),
        // AppKit attributed-string projection: whole message → NSAttributedString
        // for a plain NSTextField/NSTextView. Low-fidelity by design (no custom
        // drawing, no viewport code layout). Empty module off-macOS via
        // `#if canImport(AppKit)`.
        .target(
            name: "ChatMarkdownAppKit",
            dependencies: ["ChatMarkdownCore"]
        ),
        .testTarget(name: "ChatMarkdownCoreTests", dependencies: ["ChatMarkdownCore"]),
        .testTarget(name: "ChatTextLayoutTests", dependencies: ["ChatTextLayout", "ChatMarkdownCore"]),
        .testTarget(name: "ChatCodeBlocksTests", dependencies: ["ChatCodeBlocks"]),
        .testTarget(name: "ChatMarkdownAppKitTests", dependencies: ["ChatMarkdownAppKit", "ChatMarkdownCore"]),
    ]
)
