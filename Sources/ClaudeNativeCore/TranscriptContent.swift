import Foundation

/// Readable history for Claude and MCP content blocks. Binary attachments
/// keep their kind and metadata without decoding data or fetching a URL.
/// Text inside documents and resources remains available for reading and
/// copying, and unfamiliar blocks leave a visible description.
enum TranscriptContent {
    private static let maximumNesting = 8
    private static let maximumMetadataLength = 256

    static func text(of content: JSONValue?, depth: Int = 0) -> String {
        guard depth <= maximumNesting else { return "Nested content omitted" }
        switch content {
        case .string(let text): return text
        case .array(let blocks): return joined(blocks.map { blockText($0, depth: depth) })
        case .object: return content.map { blockText($0, depth: depth) } ?? ""
        default: return ""
        }
    }

    static func blockText(_ block: JSONValue, depth: Int = 0) -> String {
        guard depth <= maximumNesting else { return "Nested content omitted" }
        switch block["type"]?.string {
        case "text":
            return block["text"]?.string ?? "Unsupported content: text"
        case "image":
            return label("Image attachment", block: block)
        case "audio":
            return label("Audio attachment", block: block)
        case "document":
            let source = block["source"]
            let body = source?["type"]?.string == "text"
                ? source?["data"]?.string ?? ""
                : text(of: source?["content"], depth: depth + 1)
            return joined([label("Document", block: block), body])
        case "tool_reference":
            return named("Tool reference", metadata(block["tool_name"]))
        case "resource":
            guard let resource = block["resource"] else { return "Unsupported content: resource" }
            return joined([label("Resource", block: resource, fallbackName: uri(resource["uri"])), resource["text"]?.string ?? ""])
        case "resource_link":
            let name = metadata(block["title"]) ?? metadata(block["name"])
            let address = uri(block["uri"])
            return joined([label("Resource link", block: block, fallbackName: address), name != nil && address != name ? address ?? "" : ""])
        case "search_result":
            return joined([label("Search result", block: block), text(of: block["content"], depth: depth + 1)])
        default:
            return named("Unsupported content", metadata(block["type"]))
        }
    }

    private static func label(_ kind: String, block: JSONValue, fallbackName: String? = nil) -> String {
        let name = metadata(block["title"]) ?? metadata(block["name"]) ?? fallbackName
        let mediaType = metadata(block["source"]?["media_type"]) ?? metadata(block["mimeType"])
        return named(kind, name) + (mediaType.map { " (\($0))" } ?? "")
    }

    private static func named(_ kind: String, _ name: String?) -> String {
        name.map { "\(kind): \($0)" } ?? kind
    }

    private static func joined(_ pieces: [String]) -> String {
        pieces.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func metadata(_ value: JSONValue?) -> String? {
        guard let string = value?.string else { return nil }
        let name = string.prefix(maximumMetadataLength).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func uri(_ value: JSONValue?) -> String? {
        guard let address = metadata(value), !address.lowercased().hasPrefix("data:") else { return nil }
        return address
    }
}
