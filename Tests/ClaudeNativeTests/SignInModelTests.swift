import Foundation
import Testing
@testable import ClaudeNative
@testable import ClaudeNativeCore

/// Sign-in can fail on screen and then turn out to have worked: a code
/// pasted as the browser finished, or sent twice, met a sign-in that had
/// already ended. Signed in wins.
@MainActor
struct SignInModelTests {
    static func status(loggedIn: Bool) throws -> AuthStatus {
        try JSONDecoder().decode(AuthStatus.self, from: Data(#"{"loggedIn":\#(loggedIn),"authMethod":"claude.ai"}"#.utf8))
    }

    @Test func aSignedInStatusReplacesAFailureShownEarlier() throws {
        let model = SignInModel()
        model.handle(.finished(.failed(exitStatus: 1, message: "No sign-in is waiting for a code.")))
        #expect(model.phase == .failed("No sign-in is waiting for a code."))
        model.handle(.status(try Self.status(loggedIn: true)))
        #expect(model.phase == .signedIn)
    }

    @Test func aSignedOutStatusLeavesTheFailureShowing() throws {
        let model = SignInModel()
        model.handle(.finished(.failed(exitStatus: 1, message: "Sign-in didn't finish.")))
        model.handle(.status(try Self.status(loggedIn: false)))
        #expect(model.phase == .failed("Sign-in didn't finish."))
    }

    @Test func aCodeSentAfterTheSignInEndedIsNotAFailure() {
        #expect(SignInModel.isLateCode(ClaudeAuthError.notSigningIn))
        #expect(!SignInModel.isLateCode(ClaudeAuthError.timedOut))
    }

    /// A sign-out that failed showed the sign-in screen, which closed every
    /// conversation, one mid-reply too, while still signed in.
    @Test func aFailedSignOutStaysSignedIn() throws {
        let model = SignInModel()
        model.handle(.status(try Self.status(loggedIn: true)))
        var heard: [String] = []
        let listener = Announcer.listen { text, _ in if text.hasPrefix("Couldn't sign out") { heard.append(text) } }
        defer { Announcer.stopListening(listener) }
        model.signOutFailed("The request timed out.")
        #expect(model.phase == .signedIn)
        #expect(heard == ["Couldn't sign out: The request timed out."])
    }
}
