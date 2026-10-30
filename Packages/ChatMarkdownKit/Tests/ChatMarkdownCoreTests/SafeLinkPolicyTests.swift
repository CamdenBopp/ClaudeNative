import Foundation
import Testing
@testable import ChatMarkdownCore

struct SafeLinkPolicyTests {
    @Test func allowsHTTPSAndMailto() {
        #expect(SafeLinkPolicy.validatedURL(from: "https://example.com/docs") != nil)
        #expect(SafeLinkPolicy.validatedURL(from: "http://example.com") != nil)
        #expect(SafeLinkPolicy.validatedURL(from: "mailto:someone@example.com") != nil)
        #expect(SafeLinkPolicy.validatedURL(from: "  https://example.com  ") != nil)
    }

    @Test func rejectsScriptAndDataSchemes() {
        #expect(SafeLinkPolicy.validatedURL(from: "javascript:alert(1)") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "JavaScript:alert(1)") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "data:text/html;base64,PGgxPg==") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "file:///etc/passwd") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "tel:+15555550100") == nil) // not in default list
    }

    @Test func rejectsRelativeSchemelessAndPartialDestinations() {
        #expect(SafeLinkPolicy.validatedURL(from: "/relative/path") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "example.com") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "") == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "htt") == nil) // mid-stream fragment
    }

    @Test func customAllowListIsRespected() {
        let schemes: Set<String> = ["https", "myapp"]
        #expect(SafeLinkPolicy.validatedURL(from: "myapp://route", allowedSchemes: schemes) != nil)
        #expect(SafeLinkPolicy.validatedURL(from: "http://example.com", allowedSchemes: schemes) == nil)
    }

    @Test func permissivePolicyAllowsAppSchemes() {
        let policy = SafeLinkPolicy.SchemePolicy.anyExceptDangerous
        #expect(SafeLinkPolicy.validatedURL(from: "music://", policy: policy) != nil)
        #expect(SafeLinkPolicy.validatedURL(
            from: "shortcuts://x-callback-url/run-shortcut?name=Example%20Shortcut",
            policy: policy
        ) != nil)
        #expect(SafeLinkPolicy.validatedURL(from: "enchanted://x-callback-url/message?text=hi", policy: policy) != nil)
        #expect(SafeLinkPolicy.validatedURL(from: "https://example.com", policy: policy) != nil)
    }

    @Test func permissivePolicyStillRejectsDangerousSchemes() {
        let policy = SafeLinkPolicy.SchemePolicy.anyExceptDangerous
        #expect(SafeLinkPolicy.validatedURL(from: "javascript:alert(1)", policy: policy) == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "DATA:text/html;base64,PGgxPg==", policy: policy) == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "file:///etc/passwd", policy: policy) == nil)
        #expect(SafeLinkPolicy.validatedURL(from: "blob:https://example.com/x", policy: policy) == nil)
        // Schemeless fragments are still rejected — no base URL to resolve against.
        #expect(SafeLinkPolicy.validatedURL(from: "example.com", policy: policy) == nil)
    }

    @Test func dangerousSchemesTrumpExplicitAllowList() {
        // Defense in depth: even a host that lists a dangerous scheme
        // explicitly does not get it opened.
        #expect(SafeLinkPolicy.validatedURL(from: "javascript:alert(1)", allowedSchemes: ["javascript"]) == nil)
    }
}
