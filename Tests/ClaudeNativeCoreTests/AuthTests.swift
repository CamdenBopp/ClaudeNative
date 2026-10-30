import Foundation
import Testing
@testable import ClaudeNativeCore

/// Output captured from `claude auth login --claudeai` (CLI 2.1.308) with a
/// pipe for stdin and `$BROWSER` pointed at a recorder; see docs/auth.md.
/// Only `code_challenge` and `state` are redacted.
enum CapturedLogin {
    static let manualURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload+user%3Aplugins&code_challenge=REDACTED&code_challenge_method=S256&state=REDACTED"

    static let browserURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A53813%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload+user%3Aplugins&code_challenge=REDACTED&code_challenge_method=S256&state=REDACTED"

    /// stdout, byte for byte: the prompt has no trailing newline.
    static let stdout = "Opening browser to sign in\u{2026}\nIf the browser didn't open, visit: \(manualURL)\nPaste code here if prompted > "

    /// What the CLI passed to `$BROWSER`, as the recorder script wrote it.
    static let recorded = "\(browserURL)\n"

    /// `claude auth status` while signed out (exit status 1).
    static let signedOutStatus = """
    {
      "loggedIn": false,
      "authMethod": "none",
      "apiProvider": "firstParty",
      "analyticsDisabled": false,
      "projectsDirectory": "/Users/me/.claude/projects",
      "configDirectory": "/Users/me/.claude"
    }
    """

    /// Not captured (signing in is the user's job): built from the fields the
    /// CLI 2.1.308 status code adds for a claude.ai login, with placeholders.
    static let signedInStatus = """
    {
      "loggedIn": true,
      "authMethod": "claude.ai",
      "apiProvider": "firstParty",
      "analyticsDisabled": false,
      "projectsDirectory": "/Users/someone/.claude/projects",
      "configDirectory": "/Users/someone/.claude",
      "email": "someone@example.com",
      "orgId": "00000000-0000-0000-0000-000000000000",
      "orgName": "Example Org",
      "subscriptionType": "max"
    }
    """
}

struct SignInParsingTests {
    @Test func capturedOutputInOneChunk() throws {
        var parser = SignInOutputParser()
        let lines = parser.consume(Data(CapturedLogin.stdout.utf8))
        let url = try #require(URL(string: CapturedLogin.manualURL))
        #expect(lines == [.text("Opening browser to sign in\u{2026}"), .manualURL(url), .codePrompt])
        #expect(parser.flush().isEmpty)
    }

    @Test func capturedOutputByteByByte() throws {
        var parser = SignInOutputParser()
        var lines: [SignInLine] = []
        for byte in Data(CapturedLogin.stdout.utf8) { lines += parser.consume(Data([byte])) }
        let url = try #require(URL(string: CapturedLogin.manualURL))
        #expect(lines == [.text("Opening browser to sign in\u{2026}"), .manualURL(url), .codePrompt])
    }

    @Test func manualURLKeepsItsQuery() throws {
        let url = try #require(SignInOutputParser.firstURL(in: "If the browser didn't open, visit: \(CapturedLogin.manualURL)"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host() == "claude.com")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "https://platform.claude.com/oauth/code/callback")
    }

    @Test func browserURLRedirectsToLocalhost() throws {
        let url = try #require(SignInOutputParser.browserURL(fromRecorded: CapturedLogin.recorded))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "redirect_uri" }?.value == "http://localhost:53813/callback")
        #expect(SignInOutputParser.browserURL(fromRecorded: "") == nil)
    }

    @Test func hyperlinkEscapesAreStripped() throws {
        let wrapped = "If the browser didn't open, visit: \u{1B}]8;;\(CapturedLogin.manualURL)\u{07}\(CapturedLogin.manualURL)\u{1B}]8;;\u{07}\n"
        var parser = SignInOutputParser()
        let url = try #require(URL(string: CapturedLogin.manualURL))
        #expect(parser.consume(Data(wrapped.utf8)) == [.manualURL(url)])
    }

    @Test func ttyPromptAndOtherLines() {
        #expect(SignInOutputParser.isCodePrompt("Paste code here > "))
        #expect(SignInOutputParser.isCodePrompt("Paste code here if prompted > "))
        #expect(!SignInOutputParser.isCodePrompt("Paste code here if prompted"))
        var parser = SignInOutputParser()
        #expect(parser.consume(Data("Login successful.\n".utf8)) == [.loginSucceeded])
        #expect(parser.consume(Data("Invalid code. Please make sure the full code was copied.\n".utf8))
            == [.codeRejected("Invalid code. Please make sure the full code was copied.")])
    }

    @Test func promptIsReportedOnce() {
        var parser = SignInOutputParser()
        #expect(parser.consume(Data("Paste code here if prompted > ".utf8)) == [.codePrompt])
        #expect(parser.consume(Data("\n".utf8)).isEmpty)
    }
}

struct AuthStatusTests {
    @Test func signedOut() throws {
        let status = try AuthStatus.decode(Data(CapturedLogin.signedOutStatus.utf8))
        #expect(!status.loggedIn)
        #expect(status.authMethod == .none)
        #expect(status.apiProvider == "firstParty")
        #expect(status.email == nil)
    }

    @Test func signedInWithClaudeAI() throws {
        let status = try AuthStatus.decode(Data(CapturedLogin.signedInStatus.utf8))
        #expect(status.loggedIn)
        #expect(status.authMethod == .claudeAI)
        #expect(status.email == "someone@example.com")
        #expect(status.orgName == "Example Org")
        #expect(status.subscriptionType == "max")
    }

    @Test func unknownMethodStaysVisible() throws {
        let status = try AuthStatus.decode(Data(#"{"loggedIn": true, "authMethod": "carrier_pigeon", "email": null}"#.utf8))
        #expect(status.authMethod == .other("carrier_pigeon"))
    }

    @Test func garbageIsAnError() {
        #expect(throws: ClaudeAuthError.self) { try AuthStatus.decode(Data("Not logged in.".utf8)) }
    }
}

/// Drives `ClaudeAuth` against a shell script standing in for the CLI. It
/// replays the captured login output, calls `$BROWSER` the way the CLI does,
/// and reads the pasted code from stdin.
struct ClaudeAuthProcessTests {
    /// The stub gives up waiting for a code after this long, so a broken
    /// test fails instead of leaving it (and `swift test`) hanging.
    static let stubIdleSeconds = 5

    /// Whether `pid` is a live process: not gone and not a zombie.
    static func isRunning(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    /// What `ps` says about a process, for a failure message.
    static func processState(_ pid: pid_t) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "pid,ppid,stat,etime,command", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return "ps failed" }
        ps.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func fakeCLI(pidFile: URL? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClaudeAuthTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stdout = directory.appending(path: "stdout")
        try Data(CapturedLogin.stdout.utf8).write(to: stdout)
        let script = """
        #!/bin/bash
        # Like the real CLI, exit 143 on SIGTERM rather than dying of it.
        trap 'exit 143' TERM
        if [ "$2" = "status" ]; then
          if [ -f '\(directory.path)/in' ]; then
            printf '%s\\n' '\(CapturedLogin.signedInStatus.replacingOccurrences(of: "\n", with: " "))'
            exit 0
          fi
          printf '%s\\n' '\(CapturedLogin.signedOutStatus.replacingOccurrences(of: "\n", with: " "))'
          exit 1
        fi
        \(pidFile.map { "echo $$ > '\($0.path)'" } ?? "")
        "$BROWSER" '\(CapturedLogin.browserURL)'
        cat '\(stdout.path)'
        # Read in one-second slices: bash 3.2 can leave a TERM that lands
        # around a command as a pending trap, which a blocked read only
        # runs once it returns. Gives up after stubIdleSeconds idle.
        idle=0
        while [ $idle -lt \(stubIdleSeconds) ]; do
          if read -r -t 1 line; then
            idle=0
            case "$line" in
              *'#'*) touch '\(directory.path)/in'; echo 'Login successful.'; exit 0 ;;
              *) echo 'Invalid code. Please make sure the full code was copied.' >&2 ;;
            esac
          elif [ $? -gt 128 ]; then
            idle=$((idle + 1))
          else
            break
          fi
        done
        echo 'Login failed: input closed' >&2
        exit 1
        """
        let url = directory.appending(path: "claude")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test func pastedCodeSignsIn() async throws {
        let auth = ClaudeAuth(executable: try Self.fakeCLI())
        var events: [SignInEvent] = []
        for try await event in auth.signIn() {
            events.append(event)
            if event == .codePrompt {
                try await auth.submitCode("not-a-code")
            }
            if case .codeRejected = event {
                try await auth.submitCode("abc#def\n")
            }
        }
        let browser = try #require(URL(string: CapturedLogin.browserURL))
        let manual = try #require(URL(string: CapturedLogin.manualURL))
        #expect(events.contains(.openURL(browser)))
        #expect(events.contains(.manualURL(manual)))
        #expect(events.contains(.codeRejected("Invalid code. Please make sure the full code was copied.")))
        #expect(events.suffix(2).first == .finished(.succeeded))
        guard case .status(let status) = events.last else {
            Issue.record("No status after sign-in: \(events)")
            return
        }
        #expect(status.loggedIn && status.authMethod == .claudeAI)
    }

    @Test func cancelKillsTheCLI() async throws {
        let auth = ClaudeAuth(executable: try Self.fakeCLI())
        var events: [SignInEvent] = []
        for try await event in auth.signIn() {
            events.append(event)
            if event == .codePrompt { await auth.cancelSignIn() }
        }
        #expect(events.contains(.finished(.cancelled)))
        #expect(events.last.map { if case .status(let s) = $0 { !s.loggedIn } else { false } } == true)
    }

    @Test func droppingTheStreamKillsTheCLI() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "ClaudeAuthTests-pid-\(UUID().uuidString)")
        let auth = ClaudeAuth(executable: try Self.fakeCLI(pidFile: pidFile))
        let consumer = Task {
            for try await event in auth.signIn() where event == .codePrompt {
                return true
            }
            return false
        }
        #expect(try await consumer.value)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(text))
        // Leaving the loop ended the stream; the child should die promptly.
        // An exited child stays in the process table as a zombie until it's
        // reaped, which under a loaded parallel test run took over a second
        // and failed this test now and then; a zombie isn't running. The
        // fake CLI exits by itself after stubIdleSeconds, so a 3 s window
        // still fails if dropping the stream doesn't end it.
        let start = ContinuousClock.now
        var alive = true
        for _ in 0..<150 where alive {
            try await Task.sleep(for: .milliseconds(20))
            alive = Self.isRunning(pid)
        }
        #expect(!alive, "pid \(pid) still running after \(ContinuousClock.now - start): \(Self.processState(pid))")
    }

    @Test func submitWithoutSignInThrows() async throws {
        let auth = ClaudeAuth(executable: try Self.fakeCLI())
        await #expect(throws: ClaudeAuthError.notSigningIn) { try await auth.submitCode("abc#def") }
    }

    @Test func statusDecodesDespiteExitStatusOne() async throws {
        let status = try await ClaudeAuth(executable: try Self.fakeCLI()).status()
        #expect(!status.loggedIn)
    }

    /// The installed CLI, when there is one. Only checks that its status
    /// decodes; whether this machine is signed in isn't the test's business.
    @Test(.enabled(if: CLILocator.locate() != nil))
    func realCLIStatusDecodes() async throws {
        let executable = try #require(CLILocator.locate())
        let status = try await ClaudeAuth(executable: executable).status()
        #expect(status.apiProvider != nil)
    }
}

/// Sign-in commands run with the login PATH, as conversations do: from the
/// Finder, an npm-installed `claude` couldn't find node and `auth status`
/// printed nothing.
struct AuthEnvironmentTests {
    @Test func signInCommandsGetTheLoginPath() {
        let environment = ClaudeAuth.commandEnvironment(["PATH": "/usr/bin:/bin", "HOME": "/Users/me"], loginPath: "/Users/me/.nvm/versions/node/v22/bin:/usr/bin")
        let entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(entries.first == "/Users/me/.nvm/versions/node/v22/bin")
        #expect(entries.contains("/opt/homebrew/bin"))
    }
}

/// `claude` is found where the user's terminal finds it too.
struct CLILocatorPathTests {
    @Test func theFirstExecutableOnThePathIsFound() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "locate-\(UUID().uuidString)")
        let empty = root.appending(path: "empty"), npm = root.appending(path: "npm/bin")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = npm.appending(path: "claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        #expect(CLILocator.firstExecutable(named: "claude", in: "\(empty.path):\(npm.path)")?.path == claude.path)
        #expect(CLILocator.firstExecutable(named: "claude", in: empty.path) == nil)
    }
}
