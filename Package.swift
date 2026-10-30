// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeNative",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeNative", targets: ["ClaudeNative"]),
        .library(name: "ClaudeNativeCore", targets: ["ClaudeNativeCore"]),
    ],
    dependencies: [
        // The Markdown library, kept in this repository as its own package.
        .package(path: "Packages/ChatMarkdownKit"),
        // Syntax highlighting for code blocks: tree-sitter (BSD-3 Swift
        // bindings) and official MIT grammars, each pinned to its latest tag,
        // except Python, JavaScript and CSS: their 0.25 manifests look for
        // src/scanner.c relative to the working directory, so SwiftPM drops the
        // external scanner and linking fails. 0.23 lists it unconditionally.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
    ],
    targets: [
        .target(name: "ClaudeNativeCore"),
        .target(name: "CodeHighlighting", dependencies: [
            .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
            .product(name: "TreeSitterPython", package: "tree-sitter-python"),
            .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
            .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
            .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
            .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
            .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
        ]),
        .executableTarget(name: "ClaudeNative", dependencies: [
            "ClaudeNativeCore",
            "CodeHighlighting",
            .product(name: "ChatMarkdownAppKit", package: "ChatMarkdownKit"),
            .product(name: "ChatMarkdownCore", package: "ChatMarkdownKit"),
        ]),
        .testTarget(name: "ClaudeNativeCoreTests", dependencies: ["ClaudeNativeCore"]),
        .testTarget(name: "CodeHighlightingTests", dependencies: ["CodeHighlighting"]),
        // Hosts the app's real views and walks their accessibility tree.
        .testTarget(name: "ClaudeNativeTests", dependencies: ["ClaudeNative", "ClaudeNativeCore"]),
    ]
)
