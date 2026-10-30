import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// A language the highlighter has a grammar for.
enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, python, javascript, typescript, tsx, json, bash, markdown, html, css

    /// Fence info words and file extensions that name this language, lowercased.
    var aliases: [String] {
        switch self {
        case .swift: ["swift"]
        case .python: ["python", "py", "python3", "pyw", "pyi"]
        case .javascript: ["javascript", "js", "jsx", "mjs", "cjs", "node"]
        case .typescript: ["typescript", "ts", "mts", "cts"]
        case .tsx: ["tsx"]
        case .json: ["json", "jsonc", "json5", "jsonl"]
        case .bash: ["bash", "sh", "zsh", "shell", "ksh"]
        case .markdown: ["markdown", "md", "mdown", "mkd"]
        case .html: ["html", "htm", "xhtml"]
        case .css: ["css"]
        }
    }

    private static let byAlias: [String: CodeLanguage] = {
        var table: [String: CodeLanguage] = [:]
        for language in allCases {
            for alias in language.aliases {
                table[alias] = language
            }
        }
        return table
    }()

    init?(alias: String) {
        guard let language = Self.byAlias[alias.lowercased()] else { return nil }
        self = language
    }

    /// Reads a fence info string loosely: the language is its first word, so
    /// "Swift", " swift ", "swift title=x", "{.python}" and "js,linenos" all work.
    init?(infoString: String?) {
        let firstWord = (infoString ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "{" || $0 == "}" })
            .first
            .map { String($0.drop(while: { $0 == "." })) }
        guard let firstWord, let language = CodeLanguage(alias: firstWord) else { return nil }
        self = language
    }

    var treeSitterLanguage: Language {
        switch self {
        case .swift: Language(tree_sitter_swift())
        case .python: Language(tree_sitter_python())
        case .javascript: Language(tree_sitter_javascript())
        case .typescript: Language(tree_sitter_typescript())
        case .tsx: Language(tree_sitter_tsx())
        case .json: Language(tree_sitter_json())
        case .bash: Language(tree_sitter_bash())
        case .markdown: Language(tree_sitter_markdown())
        case .html: Language(tree_sitter_html())
        case .css: Language(tree_sitter_css())
        }
    }

    /// The highlight query, in precedence order: later patterns win, the
    /// convention every one of these grammars' queries is written for.
    /// TypeScript's query only adds to JavaScript's, so it goes after it.
    var highlightQuery: String {
        switch self {
        case .swift: HighlightQuerySource.swift
        case .python: HighlightQuerySource.python
        case .javascript: HighlightQuerySource.javascript + "\n" + HighlightQuerySource.javascriptJSX
        case .typescript: HighlightQuerySource.javascript + "\n" + HighlightQuerySource.typescript
        case .tsx: HighlightQuerySource.javascript + "\n" + HighlightQuerySource.javascriptJSX + "\n" + HighlightQuerySource.typescript
        case .json: HighlightQuerySource.json
        case .bash: HighlightQuerySource.bash
        case .markdown: HighlightQuerySource.markdown
        case .html: HighlightQuerySource.html
        case .css: HighlightQuerySource.css
        }
    }

    /// Other grammars that color parts of this one: Markdown's inline syntax,
    /// and the scripts and style sheets inside HTML.
    var injections: [Injection] {
        switch self {
        case .markdown:
            [Injection(nodesQuery: "(inline) @content", grammar: .markdownInline)]
        case .html:
            [
                Injection(nodesQuery: "(script_element (raw_text) @content)", grammar: .language(.javascript)),
                Injection(nodesQuery: "(style_element (raw_text) @content)", grammar: .language(.css)),
            ]
        default:
            []
        }
    }
}

/// A second grammar run over ranges of the host document, all parsed as one
/// combined document the way tree-sitter's own injections do.
struct Injection: Sendable {
    enum Grammar: Sendable, Hashable {
        case language(CodeLanguage)
        case markdownInline

        var treeSitterLanguage: Language {
            switch self {
            case .language(let language): language.treeSitterLanguage
            case .markdownInline: Language(tree_sitter_markdown_inline())
            }
        }

        var highlightQuery: String {
            switch self {
            case .language(let language): language.highlightQuery
            case .markdownInline: HighlightQuerySource.markdownInline
            }
        }
    }

    /// A query over the host tree whose `@content` captures are the ranges to inject into.
    let nodesQuery: String
    let grammar: Grammar
}
