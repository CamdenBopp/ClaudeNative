import AppKit
import OSLog
import Synchronization
import SwiftTreeSitter

/// Colors code blocks with tree-sitter grammars. A language without a grammar
/// comes back as plain monospaced text in the same font, so callers never branch.
public enum CodeHighlighter {
    /// Highlights `code` for display in a text view. Safe to call from any thread.
    ///
    /// - Parameters:
    ///   - code: The block's text. The result's `.string` is exactly this.
    ///   - language: A fence info string as written ("swift", "Python ",
    ///     "ts title=x") or a name from `supportedLanguages`. The code itself
    ///     is never sniffed.
    ///   - fontSize: Point size of the monospaced system font.
    public static func highlight(_ code: String, language: String?, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: CodePalette.plainText,
        ])
        guard let codeLanguage = CodeLanguage(infoString: language) else { return result }

        let utf16Length = result.length
        var styles = [CodeToken?](repeating: nil, count: utf16Length)
        for span in HighlightEngine.spans(in: code, language: codeLanguage) {
            let lower = max(span.range.location, 0)
            let upper = min(span.range.location + span.range.length, utf16Length)
            guard lower < upper else { continue }
            for index in lower..<upper {
                styles[index] = span.token
            }
        }

        // One attribute run per stretch of equal style.
        var runStart = 0
        while runStart < utf16Length {
            let style = styles[runStart]
            var runEnd = runStart + 1
            while runEnd < utf16Length, styles[runEnd] == style {
                runEnd += 1
            }
            if let style {
                result.addAttribute(.foregroundColor, value: CodePalette.color(for: style),
                                    range: NSRange(location: runStart, length: runEnd - runStart))
            }
            runStart = runEnd
        }
        return result
    }

    /// The canonical name of the language a file extension (`"py"`, `".tsx"`,
    /// `"MD"`) is written in, or nil when there's no grammar for it.
    public static func language(forPathExtension pathExtension: String) -> String? {
        let trimmed = pathExtension.hasPrefix(".") ? String(pathExtension.dropFirst()) : pathExtension
        return CodeLanguage(alias: trimmed)?.rawValue
    }

    /// Compiles every grammar's queries now, so the first code block shown
    /// doesn't: Swift's alone took 0.39 s on the main thread, all of them
    /// 0.55 s (debug build). Safe to call from any thread; returns how many
    /// grammars are ready.
    @discardableResult
    public static func prepare() -> Int {
        HighlightEngine.prepareAll()
    }

    /// The canonical names of every language with a grammar, each of which
    /// `highlight(_:language:fontSize:)` accepts.
    public static let supportedLanguages: [String] = CodeLanguage.allCases.map(\.rawValue)
}

/// A UTF-16 range painted with one style; `token` nil means plain text.
struct HighlightSpan: Equatable {
    let range: NSRange
    let token: CodeToken?
}

enum HighlightEngine {
    private static let logger = Logger(subsystem: "net.bopp.ClaudeNative", category: "CodeHighlighting")

    /// A grammar's compiled highlight query and its capture styles by capture index.
    struct Compiled: Sendable {
        let language: Language
        let query: Query
        let styles: [CaptureStyle]
    }

    private static let cache = Mutex<[Injection.Grammar: Compiled]>([:])
    private static let injectionQueries = Mutex<[String: Query]>([:])

    /// Compiles (once) the highlight query for `grammar`. A query that doesn't
    /// compile against its grammar is logged and the language stays plain.
    static func compiled(_ grammar: Injection.Grammar) -> Compiled? {
        if let hit = cache.withLock({ $0[grammar] }) { return hit }
        let language = grammar.treeSitterLanguage
        let query: Query
        do {
            query = try Query(language: language, data: Data(grammar.highlightQuery.utf8))
        } catch {
            logger.fault("Highlight query for \(String(describing: grammar), privacy: .public) failed to compile: \(String(describing: error), privacy: .public)")
            return nil
        }
        let styles = (0..<query.captureCount).map { index in
            query.captureName(for: index).map(CaptureStyle.init(captureName:)) ?? .ignored
        }
        let compiled = Compiled(language: language, query: query, styles: styles)
        cache.withLock { $0[grammar] = compiled }
        return compiled
    }

    /// Every grammar compiled, with each language's injection queries.
    static func prepareAll() -> Int {
        var ready = Set<Injection.Grammar>()
        for language in CodeLanguage.allCases {
            guard let host = compiled(.language(language)) else { continue }
            ready.insert(.language(language))
            for injection in language.injections {
                _ = injectionQuery(injection.nodesQuery, host: host.language)
                if compiled(injection.grammar) != nil { ready.insert(injection.grammar) }
            }
        }
        return ready.count
    }

    private static func injectionQuery(_ source: String, host: Language) -> Query? {
        if let hit = injectionQueries.withLock({ $0[source] }) { return hit }
        do {
            let query = try Query(language: host, data: Data(source.utf8))
            injectionQueries.withLock { $0[source] = query }
            return query
        } catch {
            logger.fault("Injection query \(source, privacy: .public) failed to compile: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Spans in application order: paint each over the ones before it.
    static func spans(in code: String, language: CodeLanguage) -> [HighlightSpan] {
        guard let host = compiled(.language(language)) else { return [] }
        let parser = Parser()
        do {
            try parser.setLanguage(host.language)
        } catch {
            logger.fault("Grammar for \(language.rawValue, privacy: .public) was rejected: \(String(describing: error), privacy: .public)")
            return []
        }
        guard let tree = parser.parse(code) else { return [] }
        var spans = spans(of: host, in: tree, code: code)

        for injection in language.injections {
            guard let nodesQuery = injectionQuery(injection.nodesQuery, host: host.language),
                  let injected = compiled(injection.grammar) else { continue }
            let ranges = nodesQuery.execute(in: tree)
                .resolve(with: .init(string: code))
                .flatMap { $0.captures(named: "content").map(\.node.tsRange) }
                .sorted { $0.bytes.lowerBound < $1.bytes.lowerBound }
            guard !ranges.isEmpty else { continue }
            let injectedParser = Parser()
            do {
                try injectedParser.setLanguage(injected.language)
            } catch {
                logger.fault("Injected grammar \(String(describing: injection.grammar), privacy: .public) was rejected: \(String(describing: error), privacy: .public)")
                continue
            }
            injectedParser.includedRanges = ranges
            guard let injectedTree = injectedParser.parse(code) else { continue }
            // Injected spans sit inside host nodes, so they paint last.
            spans += Self.spans(of: injected, in: injectedTree, code: code)
        }
        return spans
    }

    /// One grammar's captures, ordered so that painting in sequence gives
    /// inner nodes precedence over outer ones and, for the same node, later
    /// query patterns precedence over earlier ones.
    private static func spans(of compiled: Compiled, in tree: MutableTree, code: String) -> [HighlightSpan] {
        struct Capture {
            let range: NSRange
            let patternIndex: Int
            let style: CaptureStyle
        }
        var captures: [Capture] = []
        for match in compiled.query.execute(in: tree).resolve(with: .init(string: code)) {
            for capture in match.captures {
                let style = compiled.styles.indices.contains(capture.index) ? compiled.styles[capture.index] : .ignored
                guard style != .ignored, capture.range.length > 0 else { continue }
                captures.append(Capture(range: capture.range, patternIndex: match.patternIndex, style: style))
            }
        }
        captures.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return a.patternIndex < b.patternIndex
        }
        return captures.map { capture in
            switch capture.style {
            case .token(let token): HighlightSpan(range: capture.range, token: token)
            case .plain, .ignored: HighlightSpan(range: capture.range, token: nil)
            }
        }
    }
}
