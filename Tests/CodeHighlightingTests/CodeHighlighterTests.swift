import AppKit
import Foundation
import Testing
@testable import CodeHighlighting

struct CodeHighlighterTests {
    static let fontSize: CGFloat = 13

    // MARK: Language selection

    @Test(arguments: [
        ("swift", "swift"), ("Swift", "swift"), ("SWIFT ", "swift"), (" swift", "swift"),
        ("swift title=x", "swift"), ("swift,linenos", "swift"), ("{.swift}", "swift"),
        ("py", "python"), ("Python3", "python"), ("js", "javascript"), ("jsx", "javascript"),
        ("ts", "typescript"), ("tsx", "tsx"), ("json", "json"), ("sh", "bash"), ("zsh", "bash"),
        ("bash", "bash"), ("md", "markdown"), ("markdown", "markdown"), ("html", "html"), ("css", "css"),
    ])
    func infoStringsMapLoosely(info: String, expected: String) {
        #expect(CodeLanguage(infoString: info)?.rawValue == expected)
    }

    @Test(arguments: [nil, "", "rust", "swiftui", "objective-c", "text", "console", "diff"] as [String?])
    func unknownLanguagesStayPlain(info: String?) {
        #expect(CodeLanguage(infoString: info) == nil)
        // Code that looks like Swift is not sniffed: without a known fence it stays plain.
        let code = "let x = 1 // comment\nfunc f() {}"
        let result = CodeHighlighter.highlight(code, language: info, fontSize: Self.fontSize)
        #expect(result.string == code)
        #expect(Self.distinctColors(in: result) == [CodePalette.plainText])
        Self.expectEveryRunHasMonospacedFont(result)
    }

    @Test func pathExtensions() {
        #expect(CodeHighlighter.language(forPathExtension: "swift") == "swift")
        #expect(CodeHighlighter.language(forPathExtension: ".py") == "python")
        #expect(CodeHighlighter.language(forPathExtension: "MJS") == "javascript")
        #expect(CodeHighlighter.language(forPathExtension: "tsx") == "tsx")
        #expect(CodeHighlighter.language(forPathExtension: "zsh") == "bash")
        #expect(CodeHighlighter.language(forPathExtension: "md") == "markdown")
        #expect(CodeHighlighter.language(forPathExtension: "htm") == "html")
        #expect(CodeHighlighter.language(forPathExtension: "rs") == nil)
        #expect(CodeHighlighter.language(forPathExtension: "") == nil)
        #expect(Set(CodeHighlighter.supportedLanguages) == Set(CodeLanguage.allCases.map(\.rawValue)))
        for name in CodeHighlighter.supportedLanguages {
            #expect(CodeLanguage(infoString: name)?.rawValue == name)
        }
    }

    @Test func plainAndHighlightedUseTheSameFont() {
        let swift = CodeHighlighter.highlight("let x = 1", language: "swift", fontSize: Self.fontSize)
        let plain = CodeHighlighter.highlight("let x = 1", language: "rust", fontSize: Self.fontSize)
        let swiftFont = swift.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let plainFont = plain.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(swiftFont != nil)
        #expect(swiftFont == plainFont)
        #expect(swiftFont?.pointSize == Self.fontSize)
    }

    // MARK: Every grammar and query loads

    @Test(arguments: CodeLanguage.allCases)
    func highlightQueryCompiles(language: CodeLanguage) throws {
        let compiled = try #require(HighlightEngine.compiled(.language(language)))
        #expect(compiled.query.patternCount > 0)
        for injection in language.injections {
            #expect(HighlightEngine.compiled(injection.grammar) != nil)
        }
    }

    // MARK: Tokens get the right colors

    struct ColorCase: Sendable, CustomTestStringConvertible {
        let language: String
        let code: String
        let expectations: [(substring: String, token: CodeToken?)]
        var testDescription: String { language }
    }

    static let colorCases: [ColorCase] = [
        ColorCase(language: "swift", code: "func greet(name: String) -> Int {\n    let n = 42 // note\n    return \"hi\\(name)\".count\n}", expectations: [
            ("func", .keyword), ("greet", .function), ("String", .type), ("let", .keyword),
            ("42", .number), ("// note", .comment), ("return", .keyword), ("\"hi", .string), ("count", .property),
        ]),
        ColorCase(language: "python", code: "def f(x):\n    # note\n    return \"s\" + str(1.5) if True else None\n", expectations: [
            ("def", .keyword), ("f(", .function), ("# note", .comment), ("\"s\"", .string),
            ("str", .function), ("1.5", .number), ("True", .number),
        ]),
        ColorCase(language: "javascript", code: "const a = `x${b}y`; // c\nfunction g() { return this.p(1) }", expectations: [
            ("const", .keyword), ("`x", .string), ("b}", nil), ("// c", .comment), ("function", .keyword),
            ("g()", .function), ("this", .keyword), ("1)", .number),
        ]),
        ColorCase(language: "typescript", code: "interface P { n: number }\nconst x: P = { n: 1 } as P;", expectations: [
            ("interface", .keyword), ("P {", .type), ("number", .type), ("1 }", .number),
        ]),
        // Keys are strings too: the later `(string) @string` pattern wins over
        // `key: (_) @string.special.key` for the same node, as in tree-sitter's own highlighter.
        ColorCase(language: "json", code: "{\"k\": [1, true, null, \"v\"]}", expectations: [
            ("\"k\"", .string), ("1,", .number), ("true", .number), ("\"v\"", .string),
        ]),
        ColorCase(language: "bash", code: "# c\nfor f in *.txt; do echo \"$f\"; done", expectations: [
            ("# c", .comment), ("for", .keyword), ("echo", .function), ("\"$", .string),
        ]),
        ColorCase(language: "markdown", code: "# Title\n\nSome `code` and [link](https://x.y).\n\n- item\n", expectations: [
            ("Title", .keyword), ("code`", .string), ("link", .function), ("https://x.y", .function), ("Some", nil),
        ]),
        ColorCase(language: "html", code: "<p class=\"a\">hi</p>\n<!-- c -->\n<script>let v = 1;</script>\n<style>p { color: red; }</style>", expectations: [
            ("p class", .keyword), ("class", .property), ("a\">", .string), ("hi", nil), ("<!-- c -->", .comment),
            ("let", .keyword), ("1;", .number), ("color", .property),
        ]),
        ColorCase(language: "css", code: "/* c */\n.a > #b { margin: 4px; color: #fff; }\n@media print { }", expectations: [
            ("/* c */", .comment), ("margin", .property), ("4", .number), ("@media", .keyword),
        ]),
    ]

    @Test(arguments: colorCases)
    func tokensGetTheirColors(colorCase: ColorCase) {
        let result = CodeHighlighter.highlight(colorCase.code, language: colorCase.language, fontSize: Self.fontSize)
        #expect(result.string == colorCase.code)
        for (substring, token) in colorCase.expectations {
            let range = (colorCase.code as NSString).range(of: substring)
            #expect(range.location != NSNotFound, "\(substring) missing from sample")
            guard range.location != NSNotFound else { continue }
            let color = result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            let expected = token.map(CodePalette.color(for:)) ?? CodePalette.plainText
            #expect(color == expected, "\(colorCase.language) '\(substring)': got \(Self.tokenName(color)), want \(token.map { "\($0)" } ?? "plain")")
        }
    }

    // MARK: Text is never changed

    static let trickyInputs: [String] = [
        "",
        " ",
        "\n",
        "\tlet x = 1\n\t\tlet y = 2\t// trailing tab\t\n",
        "let s = \"héllo 👩‍👩‍👧 日本語 e\u{0301}\"\nlet 🐶 = \"dog\" // 💥\n",
        "let a = 1\r\nlet b = \"two\"\r\n// crlf comment\r\n",
        "let a = 1\rlet b = 2\r",
        "let broken = \"never closed\nlet next = 2\n",
        "let multi = \"\"\"\nopen multiline with no close\n",
        "/* unterminated block comment\nlet x = 1\n",
        "#if DEBUG\nprint(\"x\")\n#endif",
        "   leading spaces and trailing   ",
        "\u{00A0}nbsp\u{2028}line sep\u{FEFF}bom \"x\"",
        "\u{FEFF}let leadingBOM = 1",
        "}}}{{{ ))) \"\"\" ''' ``` <<< >>> /* */ -->",
        String(repeating: "let value = foo.bar(baz: \"q\", 42) + 3.14 ", count: 2_000),
    ]

    @Test(arguments: trickyInputs)
    func highlightingNeverChangesTheText(code: String) {
        for language in CodeHighlighter.supportedLanguages + ["rust"] {
            let result = CodeHighlighter.highlight(code, language: language, fontSize: Self.fontSize)
            #expect(result.string == code, "language \(language)")
            #expect(result.length == (code as NSString).length, "language \(language)")
            Self.expectEveryRunHasMonospacedFont(result)
        }
    }

    /// Colors land on the right characters after astral-plane characters,
    /// which take two UTF-16 units: the comment after the emoji is all comment.
    @Test func rangesStayAlignedAfterSurrogatePairs() {
        let code = "let 🐶👩‍👩‍👧 = \"😀\" // tail"
        let result = CodeHighlighter.highlight(code, language: "swift", fontSize: Self.fontSize)
        let range = (code as NSString).range(of: "// tail")
        var effective = NSRange()
        let color = result.attribute(.foregroundColor, at: range.location, effectiveRange: &effective) as? NSColor
        #expect(color == CodePalette.color(for: .comment))
        #expect(NSIntersectionRange(effective, range) == range)
        let stringRange = (code as NSString).range(of: "\"😀\"")
        let stringColor = result.attribute(.foregroundColor, at: stringRange.location, effectiveRange: &effective) as? NSColor
        #expect(stringColor == CodePalette.color(for: .string))
        #expect(NSIntersectionRange(effective, stringRange) == stringRange)
    }

    // MARK: Contrast

    struct ContrastCase: Sendable, CustomTestStringConvertible {
        let appearance: NSAppearance.Name
        var testDescription: String { appearance.rawValue }
    }

    static let appearances: [ContrastCase] = [
        .init(appearance: .aqua),
        .init(appearance: .darkAqua),
        .init(appearance: .accessibilityHighContrastAqua),
        .init(appearance: .accessibilityHighContrastDarkAqua),
    ]

    /// Every token color, and plain text, clears WCAG AA (4.5:1) against
    /// textBackgroundColor resolved in the same appearance. The luminance math
    /// here is written out independently of CodePalette's.
    @Test(arguments: appearances)
    func everyTokenMeetsAAContrast(contrastCase: ContrastCase) throws {
        let appearance = try #require(NSAppearance(named: contrastCase.appearance))
        let background = try #require(Self.resolve(.textBackgroundColor, in: appearance))
        var colors: [(String, NSColor, NSColor)] = CodeToken.allCases.map { token in
            ("\(token)", CodePalette.color(for: token), token.baseColor)
        }
        colors.append(("plainText", CodePalette.plainText, .labelColor))

        var report: [String] = []
        for (name, color, base) in colors {
            let foreground = try #require(Self.resolve(color, in: appearance))
            #expect(foreground.alpha == 1, "\(name) should resolve opaque")
            let ratio = Self.contrast(foreground, background)
            let raw = Self.resolve(base, in: appearance).map { Self.contrast($0.over(background), background) } ?? 0
            report.append(String(format: "contrast %@ %@: %.2f (system color alone %.2f) %@ on %@",
                                 contrastCase.appearance.rawValue, name, ratio, raw, foreground.hex, background.hex))
            #expect(ratio >= 4.5, "\(name) in \(contrastCase.appearance.rawValue): \(ratio)")
        }
        print(report.joined(separator: "\n"))
    }

    /// Code blocks in replies sit on ChatMarkdownKit's code background,
    /// 8% label color over the text background. Tokens must still pass there.
    @Test(arguments: appearances)
    func everyTokenMeetsAAContrastOnTheCodeBlockBackground(contrastCase: ContrastCase) throws {
        let appearance = try #require(NSAppearance(named: contrastCase.appearance))
        let page = try #require(Self.resolve(.textBackgroundColor, in: appearance))
        let tint = try #require(Self.resolve(NSColor.labelColor.withAlphaComponent(0.08), in: appearance))
        let background = tint.over(page)
        for token in CodeToken.allCases {
            let foreground = try #require(Self.resolve(CodePalette.color(for: token), in: appearance))
            let ratio = Self.contrast(foreground, background)
            #expect(ratio >= 4.5, "\(token) on code background in \(contrastCase.appearance.rawValue): \(ratio)")
        }
    }

    // MARK: Performance

    static let timingSamples: [(language: String, block: String)] = [
        ("swift", """
        /// A documented type.
        struct Item<Value: Equatable>: Identifiable {
            let id: UUID = UUID()
            var name: String = "item \\(42)"
            #if DEBUG
            static let limit = 0x1F + 3.5e2
            #endif
            func render(_ value: Value) -> String {
                guard name.isEmpty == false else { return "" } // trailing
                return [name, String(describing: value)].joined(separator: ", ")
            }
        }

        """),
        ("python", """
        class Item:
            \"\"\"A documented type.\"\"\"
            limit = 0x1F + 3.5e2

            def __init__(self, name: str = "item"):
                self.name = name  # trailing

            def render(self, value):
                if not self.name:
                    return ""
                return ", ".join([self.name, str(value)])

        """),
        ("javascript", """
        // A documented type.
        export class Item {
          static limit = 0x1F + 3.5e2;
          constructor(name = `item ${42}`) {
            this.name = name; // trailing
          }
          render(value) {
            if (!this.name) return "";
            return [this.name, String(value)].join(", ");
          }
        }

        """),
        ("typescript", """
        // A documented type.
        export class Item<T> implements Named {
          static readonly limit: number = 0x1F + 3.5e2;
          constructor(private name: string = `item ${42}`) {}
          render(value: T): string {
            if (!this.name) return "";
            return [this.name, String(value)].join(", ");
          }
        }
        interface Named { name?: string }

        """),
        ("json", """
          {"id": 1, "name": "item", "tags": ["a", "b"], "ok": true, "n": null, "x": 3.5e2},

        """),
        ("bash", """
        # A comment
        for f in "$@"; do
          if [[ -f "$f" ]]; then
            echo "file: ${f##*/}" | tr a-z A-Z > /dev/null
          fi
        done

        """),
        ("markdown", """
        ## Heading with `code`

        Some *emphasis*, **strong**, and a [link](https://example.com).

        - item one
        - item two

        """),
        ("html", """
        <div class="item" id="a1">
          <!-- comment -->
          <a href="https://example.com">link</a>
          <script>const n = 42; console.log(n);</script>
          <style>.item { color: red; margin: 4px; }</style>
        </div>

        """),
        ("css", """
        /* comment */
        .item > #a1:hover, a[href^="https"] {
          color: #fff;
          margin: 4px calc(100% - 2em);
        }

        """),
    ]

    @Test(arguments: timingSamples.map(\.language))
    func twoThousandLineFileHighlightsQuickly(language: String) throws {
        let block = try #require(Self.timingSamples.first { $0.language == language }?.block)
        let code = Self.file(lines: 2_000, repeating: block)
        _ = CodeHighlighter.highlight(code, language: language, fontSize: Self.fontSize)
        var best = Duration.seconds(1_000)
        for _ in 0..<3 {
            let clock = ContinuousClock()
            var result: NSAttributedString?
            let elapsed = clock.measure {
                result = CodeHighlighter.highlight(code, language: language, fontSize: Self.fontSize)
            }
            #expect(result?.string == code)
            #expect((result.map(Self.distinctColors(in:))?.count ?? 0) > 2)
            best = min(best, elapsed)
        }
        let ms = Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1e3
        print(String(format: "timing %@: 2,000 lines (%d UTF-16 units) in %.1f ms", language, code.utf16.count, ms))
        // Debug builds run several times slower than release; release is the
        // 250 ms budget. This bound catches a quadratic blowup in either.
        #expect(best < .seconds(1))
    }

    // MARK: Helpers

    static func file(lines: Int, repeating block: String) -> String {
        let blockLines = max(block.split(separator: "\n", omittingEmptySubsequences: false).count - 1, 1)
        return String(repeating: block, count: (lines + blockLines - 1) / blockLines)
    }

    static func distinctColors(in string: NSAttributedString) -> Set<NSColor> {
        var colors = Set<NSColor>()
        string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        return colors
    }

    static func tokenName(_ color: NSColor?) -> String {
        if color == CodePalette.plainText { return "plain" }
        return CodeToken.allCases.first { CodePalette.color(for: $0) == color }.map { "\($0)" } ?? String(describing: color)
    }

    static func expectEveryRunHasMonospacedFont(_ string: NSAttributedString) {
        let full = NSRange(location: 0, length: string.length)
        string.enumerateAttributes(in: full) { attributes, range, _ in
            let font = attributes[.font] as? NSFont
            #expect(font?.isFixedPitch == true, "run \(range) font \(String(describing: font))")
            #expect(font?.pointSize == fontSize)
            #expect(attributes[.foregroundColor] is NSColor, "run \(range) has no color")
        }
    }

    struct RGBA {
        var red, green, blue, alpha: CGFloat
        func over(_ bg: RGBA) -> RGBA {
            RGBA(red: red * alpha + bg.red * (1 - alpha),
                 green: green * alpha + bg.green * (1 - alpha),
                 blue: blue * alpha + bg.blue * (1 - alpha), alpha: 1)
        }
        var hex: String {
            String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
    }

    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> RGBA? {
        var result: RGBA?
        appearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                result = RGBA(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
            }
        }
        return result
    }

    /// WCAG 2.x: L = 0.2126 R + 0.7152 G + 0.0722 B on linearized sRGB channels.
    static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// The compiled-in queries must match the grammar packages they were copied
/// from, so a version bump in Package.swift can't leave stale queries behind.
struct HighlightQueryDriftTests {
    static let checkouts = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/checkouts")

    static let sources: [(String, String, String)] = [
        ("swift", HighlightQuerySource.swift, "tree-sitter-swift/queries/highlights.scm"),
        ("python", HighlightQuerySource.python, "tree-sitter-python/queries/highlights.scm"),
        ("javascript", HighlightQuerySource.javascript, "tree-sitter-javascript/queries/highlights.scm"),
        ("javascriptJSX", HighlightQuerySource.javascriptJSX, "tree-sitter-javascript/queries/highlights-jsx.scm"),
        ("typescript", HighlightQuerySource.typescript, "tree-sitter-typescript/queries/highlights.scm"),
        ("json", HighlightQuerySource.json, "tree-sitter-json/queries/highlights.scm"),
        ("bash", HighlightQuerySource.bash, "tree-sitter-bash/queries/highlights.scm"),
        ("markdown", HighlightQuerySource.markdown, "tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm"),
        ("markdownInline", HighlightQuerySource.markdownInline, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/highlights.scm"),
        ("html", HighlightQuerySource.html, "tree-sitter-html/queries/highlights.scm"),
        ("css", HighlightQuerySource.css, "tree-sitter-css/queries/highlights.scm"),
    ]

    @Test(arguments: sources.map(\.0))
    func embeddedQueryMatchesPackage(name: String) throws {
        let (_, embedded, path) = try #require(Self.sources.first { $0.0 == name })
        let url = Self.checkouts.appending(path: path)
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else {
            // No checkout (an Xcode build keeps them elsewhere): nothing to compare.
            return
        }
        #expect(embedded == onDisk.trimmingCharacters(in: .newlines), "\(path) changed; rerun the query generator")
    }
}
