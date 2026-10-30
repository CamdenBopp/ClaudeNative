import AppKit
import ClaudeNativeCore
import Observation
import SwiftUI

/// Whether the CLI can talk to Claude, and the sign-in flow when it can't.
@MainActor
@Observable
final class SignInModel {
    enum Phase: Equatable {
        case checking
        case signedOut
        /// Waiting on the browser. `manualURL` is the fallback page that shows
        /// a code to paste; `codeRejected` is the CLI's complaint about one.
        case signingIn(manualURL: URL?, codeRejected: String?)
        case signedIn
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var status: AuthStatus?
    private var auth: ClaudeAuth?
    private var signInTask: Task<Void, Never>?

    var isSignedIn: Bool { phase == .signedIn }

    /// `announcingFailure` is false for background re-checks, so coming
    /// back to the app doesn't repeat a failure the screen already shows.
    func check(announcingFailure: Bool = true) async {
        guard let executable = CLILocator.locate() else {
            fail("Couldn't find the claude command. Set \(CLILocator.environmentOverride) to its path.", announcing: announcingFailure)
            return
        }
        let auth = ClaudeAuth(executable: executable)
        self.auth = auth
        phase = .checking
        do {
            apply(try await auth.status())
        } catch {
            fail(error.localizedDescription, announcing: announcingFailure)
        }
    }

    /// Reads the status again without showing "Checking", for when the user
    /// may have signed in somewhere else, such as `claude auth login` in a
    /// terminal. Leaves a sign-in in progress alone.
    func refresh() async {
        switch phase {
        case .signedOut, .failed:
            break
        case .checking, .signingIn, .signedIn:
            return
        }
        guard let auth else { return await check(announcingFailure: false) }
        if let status = try? await auth.status(), status.loggedIn || status.apiKeySource != nil {
            apply(status)
        }
    }

    func signIn(console: Bool) {
        guard let auth else { return }
        signInTask?.cancel()
        phase = .signingIn(manualURL: nil, codeRejected: nil)
        Announcer.announce("Opening your browser to sign in.")
        signInTask = Task {
            do {
                for try await event in auth.signIn(console: console) {
                    handle(event)
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let auth else { return }
        Task {
            do {
                try await auth.submitCode(trimmed)
            } catch {
                // The sign-in had already ended (the browser finished it, or
                // this was a second press); how it ended arrives on its own.
                // Shown as a failure, it hid a sign-in that had worked.
                guard !Self.isLateCode(error) else { return }
                fail(error.localizedDescription)
            }
        }
    }

    /// A code sent after the sign-in it was for had ended.
    static func isLateCode(_ error: Error) -> Bool {
        (error as? ClaudeAuthError) == .notSigningIn
    }

    func cancel() {
        guard let auth else { return }
        Task { await auth.cancelSignIn() }
    }

    func signOut() {
        guard let auth else { return }
        Task {
            do {
                try await auth.signOut()
                apply(try await auth.status())
            } catch {
                signOutFailed(error.localizedDescription)
            }
        }
    }

    func handle(_ event: SignInEvent) {
        switch event {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .manualURL(let url):
            if case .signingIn(_, let rejected) = phase {
                phase = .signingIn(manualURL: url, codeRejected: rejected)
            }
        case .codeRejected(let message):
            if case .signingIn(let url, _) = phase {
                phase = .signingIn(manualURL: url, codeRejected: message)
            }
            Announcer.announce(message, urgency: .urgent)
        case .finished(.failed(_, let message)):
            fail(message ?? "Sign-in didn't finish.")
        case .finished(.cancelled):
            phase = .signedOut
        case .status(let status):
            // Signed in wins over a failure shown earlier in the same
            // sign-in; otherwise the failure stays on screen.
            if case .failed = phase, !Self.canTalk(status) {
                self.status = status
            } else {
                apply(status)
            }
        case .codePrompt, .output, .finished(.succeeded):
            break
        }
    }

    /// Shows a failure and speaks it, so a VoiceOver user hears why sign-in
    /// stopped instead of a silent change of screen.
    /// Sign-out didn't go through (a timeout, no network).
    /// Still signed in, so the conversations stay: showing the failure
    /// put the sign-in screen up, which closed every one, mid-reply too.
    func signOutFailed(_ message: String) {
        Announcer.announce("Couldn't sign out: \(message)", urgency: .urgent)
    }

    private func fail(_ message: String, announcing: Bool = true) {
        phase = .failed(message)
        if announcing { Announcer.announce(message, urgency: .urgent) }
    }

    /// An API key in the environment works without a claude.ai login.
    static func canTalk(_ status: AuthStatus) -> Bool {
        status.loggedIn || status.apiKeySource != nil
    }

    private func apply(_ status: AuthStatus) {
        self.status = status
        let wasSignedIn = phase == .signedIn
        phase = Self.canTalk(status) ? .signedIn : .signedOut
        // The window turns into the sign-in screen; said, so it isn't silent.
        if wasSignedIn, phase == .signedOut { Announcer.announce("Signed out.") }
        if Self.canTalk(status) {
            Announcer.announce(status.email.map { "Signed in as \($0)." } ?? "Signed in.")
        }
    }
}

enum SignInLayout {
    /// Keeps the sign-in text to a readable line length in a wide window.
    static let maxContentWidth: CGFloat = 520
    /// Lets VoiceOver start on the newly focused code field before the
    /// announcement explaining it, so the explanation isn't cut off by the
    /// focus change.
    static let codeAnnouncementDelay: Duration = .milliseconds(300)
    static let codeFieldAnnouncement = "Paste the sign-in code here. If the browser didn't open, open the sign-in page to get it."
}

struct SignInView: View {
    let model: SignInModel
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Text("Sign in to Claude")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .checking:
                ProgressView("Checking your sign-in…")
            case .signedOut, .signedIn:
                Text("Claude Native uses your Claude account through the claude command. Sign in once and every window can use it.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sign In with Claude.ai") { model.signIn(console: false) }
                        .keyboardShortcut(.defaultAction)
                    Button("Use a Console Account") { model.signIn(console: true) }
                    Button("Check Again") { Task { await model.refresh() } }
                }
                Text("Signed in from a terminal? This window picks it up when you come back to the app, or choose Check Again.")
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
                    .fixedSize(horizontal: false, vertical: true)
            case .signingIn(let manualURL, let rejected):
                Text("Finish signing in in your browser. This window continues on its own when you're done.")
                    .fixedSize(horizontal: false, vertical: true)
                if let manualURL {
                    Text("If the browser didn't open, open the sign-in page, then paste the code it shows here.")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Open the sign-in page", destination: manualURL)
                    HStack {
                        TextField("Code", text: $code)
                            .accessibilityLabel("Code")
                            .focused($codeFocused)
                            .onSubmit(submit)
                            .task {
                                // Runs once, when the CLI first offers the
                                // paste-a-code fallback.
                                codeFocused = true
                                // Cancelled means sign-in moved on; stay quiet.
                                guard (try? await Task.sleep(for: SignInLayout.codeAnnouncementDelay)) != nil else { return }
                                Announcer.announce(SignInLayout.codeFieldAnnouncement)
                            }
                        Button("Submit Code", action: submit)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let rejected {
                    Text(rejected).foregroundStyle(Color(nsColor: Theme.errorText))
                }
                Button("Cancel", role: .cancel, action: model.cancel)
                    .keyboardShortcut(.cancelAction)
            case .failed(let message):
                Text(message).foregroundStyle(Color(nsColor: Theme.errorText))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.check() } }
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: SignInLayout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
    }

    private func submit() {
        model.submitCode(code)
        code = ""
    }
}
