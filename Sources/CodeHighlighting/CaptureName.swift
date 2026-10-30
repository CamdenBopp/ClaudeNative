/// What a highlight query capture name (`@keyword.function`, `@string.escape`)
/// means for color.
enum CaptureStyle: Equatable, Sendable {
    /// Paint this token's color.
    case token(CodeToken)
    /// Paint plain text, undoing any outer capture (`@variable` inside `@string`).
    case plain
    /// Leave the color alone (`@spell`, `@text.emphasis`).
    case ignored

    /// The most specific rule wins: `string.escape` before `string`.
    init(captureName: String) {
        var components = captureName.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let style = Self.table[components.joined(separator: ".")] {
                self = style
                return
            }
            components.removeLast()
        }
        self = .ignored
    }

    private static let table: [String: CaptureStyle] = [
        // Keywords, and the names that read as keywords.
        "keyword": .token(.keyword),
        "keyword.directive": .token(.preprocessor),
        "conditional": .token(.keyword),
        "repeat": .token(.keyword),
        "include": .token(.keyword),
        "exception": .token(.keyword),
        "storageclass": .token(.keyword),
        "variable.builtin": .token(.keyword),
        "tag": .token(.keyword),
        "text.title": .token(.keyword),
        "markup.heading": .token(.keyword),
        "punctuation.special": .token(.keyword),
        // CSS at-rules.
        "import": .token(.keyword),
        "media": .token(.keyword),
        "charset": .token(.keyword),
        "keyframes": .token(.keyword),
        "supports": .token(.keyword),
        "namespace": .token(.type),

        "string": .token(.string),
        "character": .token(.string),
        "text.literal": .token(.string),
        "markup.raw": .token(.string),
        "string.escape": .token(.escape),
        "string.special.key": .token(.property),
        "escape": .token(.escape),
        "character.special": .token(.escape),

        "type": .token(.type),
        "constructor": .token(.type),
        "module": .token(.type),

        "function": .token(.function),
        "method": .token(.function),
        "function.macro": .token(.preprocessor),
        "text.uri": .token(.function),
        "markup.link": .token(.function),
        "text.reference": .token(.function),

        "number": .token(.number),
        "float": .token(.number),
        "boolean": .token(.number),
        "constant": .token(.number),
        "constant.macro": .token(.preprocessor),

        "comment": .token(.comment),

        "property": .token(.property),
        "field": .token(.property),
        "attribute": .token(.property),
        "label": .token(.property),
        "variable.member": .token(.property),

        "variable": .plain,
        "variable.parameter": .plain,
        "operator": .plain,
        "punctuation": .plain,
        "embedded": .plain,
        "none": .plain,

        "spell": .ignored,
        "text.emphasis": .ignored,
        "text.strong": .ignored,
    ]
}
