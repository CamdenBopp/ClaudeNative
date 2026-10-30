import Foundation

/// Validation for link destinations coming out of untrusted Markdown.
///
/// Destinations are carried through the pipeline as raw strings (streaming
/// can surface half-written URLs); nothing may open one without passing it
/// through here first. Scheme allow-listing kills `javascript:`, `data:`,
/// `file:` and friends; relative and schemeless destinations are rejected
/// because a chat renderer has no document base URL to resolve them against.
public enum SafeLinkPolicy {
    public static let defaultAllowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Schemes that must never be openable regardless of policy: script and
    /// data injection (`javascript:`, `data:`, `blob:`, `vbscript:`) and local
    /// file access (`file:`). `about:` is included as a browser-internal
    /// scheme with no legitimate use in chat content.
    public static let dangerousSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "vbscript", "about",
    ]

    /// Which link schemes a host permits in tapped message content.
    public enum SchemePolicy: Equatable, Sendable {
        /// Only the given schemes. `.standard` (http/https/mailto) is the
        /// safe default for untrusted markdown.
        case allow(Set<String>)
        /// Any scheme except `dangerousSchemes` — opt-in for hosts that want
        /// arbitrary app deep links (`music://`, `shortcuts://`, x-callback
        /// URLs) tappable. The system still no-ops schemes with no installed
        /// handler, but anything with a handler WILL be invoked from
        /// untrusted content: hosts choosing this accept that their users'
        /// taps can trigger third-party app actions.
        case anyExceptDangerous

        public static let standard = SchemePolicy.allow(SafeLinkPolicy.defaultAllowedSchemes)

        public func permits(_ scheme: String) -> Bool {
            let scheme = scheme.lowercased()
            switch self {
            case .allow(let schemes):
                return schemes.contains(scheme) && !SafeLinkPolicy.dangerousSchemes.contains(scheme)
            case .anyExceptDangerous:
                return !SafeLinkPolicy.dangerousSchemes.contains(scheme)
            }
        }
    }

    /// Returns an openable URL, or nil if the destination must not be opened.
    public static func validatedURL(
        from destination: String,
        policy: SchemePolicy = .standard
    ) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme,
              policy.permits(scheme)
        else { return nil }
        return url
    }

    /// Returns an openable URL, or nil if the destination must not be opened.
    public static func validatedURL(
        from destination: String,
        allowedSchemes: Set<String>
    ) -> URL? {
        validatedURL(from: destination, policy: .allow(allowedSchemes))
    }
}
