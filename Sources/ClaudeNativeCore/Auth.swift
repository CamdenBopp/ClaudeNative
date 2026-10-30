import Foundation

// MARK: - Status

/// How the CLI is authenticated, from `claude auth status`. The CLI's own
/// values as of 2.1.308; anything newer lands in `.other` so it stays visible.
public enum AuthMethod: Sendable, Equatable {
    case none
    case claudeAI
    case apiKey
    case apiKeyHelper
    case oauthToken
    case thirdParty
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "claude.ai": self = .claudeAI
        case "api_key": self = .apiKey
        case "api_key_helper": self = .apiKeyHelper
        case "oauth_token": self = .oauthToken
        case "third_party": self = .thirdParty
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .none: "none"
        case .claudeAI: "claude.ai"
        case .apiKey: "api_key"
        case .apiKeyHelper: "api_key_helper"
        case .oauthToken: "oauth_token"
        case .thirdParty: "third_party"
        case .other(let value): value
        }
    }
}

/// The JSON `claude auth status` prints. `loggedIn` and `authMethod` are
/// always present; the rest depend on how the CLI is signed in (the account
/// fields only appear for claude.ai and console logins), so they're optional.
public struct AuthStatus: Sendable, Equatable, Decodable {
    public var loggedIn: Bool
    public var authMethodName: String
    public var apiProvider: String?
    public var analyticsDisabled: Bool?
    public var projectsDirectory: String?
    public var configDirectory: String?
    public var forcedLoginMethod: String?
    public var allowedProviders: [String]?
    public var apiKeySource: String?
    public var email: String?
    public var orgID: String?
    public var orgName: String?
    public var subscriptionType: String?

    public var authMethod: AuthMethod { AuthMethod(rawValue: authMethodName) }

    enum CodingKeys: String, CodingKey {
        case loggedIn, apiProvider, analyticsDisabled, projectsDirectory, configDirectory
        case forcedLoginMethod, allowedProviders, apiKeySource, email, orgName, subscriptionType
        case authMethodName = "authMethod"
        case orgID = "orgId"
    }

    public init(
        loggedIn: Bool, authMethod: AuthMethod, apiProvider: String? = nil,
        email: String? = nil, orgName: String? = nil, subscriptionType: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethodName = authMethod.rawValue
        self.apiProvider = apiProvider
        self.email = email
        self.orgName = orgName
        self.subscriptionType = subscriptionType
    }

    /// Decodes the CLI's stdout. It exits 1 when signed out but still prints
    /// the JSON, so callers decode regardless of the exit status.
    public static func decode(_ output: Data) throws -> AuthStatus {
        do {
            return try JSONDecoder().decode(AuthStatus.self, from: output)
        } catch {
            let preview = String(decoding: output.prefix(previewLength), as: UTF8.self)
            throw ClaudeAuthError.unreadableStatus("\(error.localizedDescription) Output: \(preview)")
        }
    }

    static let previewLength = 300
}

// MARK: - Sign-in events

public enum SignInEvent: Sendable, Equatable {
    /// The URL the CLI asked the system browser to open. Its redirect is the
    /// CLI's own localhost listener, so finishing sign-in there completes the
    /// flow with no code to paste. Open this one.
    case openURL(URL)
    /// The fallback URL the CLI prints. Its redirect shows a code on
    /// platform.claude.com that the user pastes back with `submitCode(_:)`.
    case manualURL(URL)
    /// The CLI is waiting for a pasted code (it always asks, alongside the
    /// browser flow; whichever finishes first wins).
    case codePrompt
    /// The CLI rejected a pasted code. Sign-in is still running.
    case codeRejected(String)
    /// Any other line the CLI printed.
    case output(String, isError: Bool)
    /// The CLI exited.
    case finished(SignInOutcome)
    /// `claude auth status` read right after the CLI exited.
    case status(AuthStatus)
}

public enum SignInOutcome: Sendable, Equatable {
    case succeeded
    /// `message` is the CLI's last error line, if it printed one.
    case failed(exitStatus: Int32, message: String?)
    case cancelled
}

public enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case unreadableStatus(String)
    case commandFailed(String)
    case timedOut
    case notSigningIn

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "Couldn't start Claude: \(reason)"
        case .unreadableStatus(let reason): "Couldn't read the sign-in status. \(reason)"
        case .commandFailed(let message): message
        case .timedOut: "Claude didn't answer in time."
        case .notSigningIn: "No sign-in is waiting for a code."
        }
    }
}

// MARK: - Output parsing

/// What one piece of `claude auth login` output means.
enum SignInLine: Equatable {
    case manualURL(URL)
    case codePrompt
    case codeRejected(String)
    case loginSucceeded
    case text(String)
}

/// Turns the CLI's login output into events. Stateless helpers plus a line
/// splitter, so tests can feed it the exact bytes the CLI wrote.
struct SignInOutputParser {
    static let manualURLMarker = "If the browser didn't open, visit:"
    static let ttyManualURLMarker = "Sign in at:"
    static let codePromptMarker = "Paste code here"
    static let invalidCodeMarker = "Invalid code."
    static let successMarker = "Login successful."

    private var pending = Data()
    private var promptSeen = false

    /// Feeds a stdout chunk. Complete lines are classified; an unterminated
    /// tail is checked for the code prompt, which the CLI writes without a
    /// newline and then waits.
    mutating func consume(_ chunk: Data) -> [SignInLine] {
        pending.append(chunk)
        var lines: [SignInLine] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            lines += classify(line)
        }
        if !promptSeen, Self.isCodePrompt(String(decoding: pending, as: UTF8.self)) {
            promptSeen = true
            pending.removeAll()
            lines.append(.codePrompt)
        }
        return lines
    }

    /// Whatever was left unterminated when the stream closed.
    mutating func flush() -> [SignInLine] {
        defer { pending.removeAll() }
        let rest = String(decoding: pending, as: UTF8.self)
        return rest.isEmpty ? [] : classify(rest)
    }

    private mutating func classify(_ raw: String) -> [SignInLine] {
        let line = Self.stripEscapes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        if line.contains(Self.manualURLMarker) || line.hasPrefix(Self.ttyManualURLMarker),
           let url = Self.firstURL(in: line) {
            return [.manualURL(url)]
        }
        if Self.isCodePrompt(line) {
            if promptSeen { return [] }
            promptSeen = true
            return [.codePrompt]
        }
        if line.hasPrefix(Self.invalidCodeMarker) { return [.codeRejected(line)] }
        if line == Self.successMarker { return [.loginSucceeded] }
        return [.text(line)]
    }

    static func isCodePrompt(_ text: String) -> Bool {
        let trimmed = stripEscapes(text).trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(codePromptMarker) && trimmed.hasSuffix(">")
    }

    /// The first http(s) URL in `text`, ending at whitespace or a control
    /// character (an OSC 8 hyperlink wrapper ends in ESC or BEL).
    static func firstURL(in text: String) -> URL? {
        guard let start = text.range(of: "https://") ?? text.range(of: "http://") else { return nil }
        let candidate = text[start.lowerBound...].prefix { character in
            !character.isWhitespace && !(character.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false)
        }
        guard let url = URL(string: String(candidate)), url.host() != nil else { return nil }
        return url
    }

    /// The URL the CLI handed to `$BROWSER`, as the helper script recorded it.
    static func browserURL(fromRecorded text: String) -> URL? {
        text.split(whereSeparator: \.isNewline).lazy.compactMap { firstURL(in: String($0)) }.first
    }

    /// Drops ANSI CSI sequences and OSC sequences (terminal hyperlinks).
    static func stripEscapes(_ text: String) -> String {
        var result = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else { result.unicodeScalars.append(scalar); continue }
            guard let kind = iterator.next() else { break }
            if kind == "[" {
                while let next = iterator.next(), !(0x40...0x7E).contains(next.value) {}
            } else if kind == "]" {
                // OSC runs to BEL or ESC \.
                while let next = iterator.next() {
                    if next == "\u{07}" { break }
                    if next == "\u{1B}" { _ = iterator.next(); break }
                }
            }
        }
        return result
    }
}

// MARK: - Driver

private enum LoginPipeEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case browserURL(URL)
    case stdoutClosed
    case stderrClosed
    case exited(Int32)
}

/// Signs the CLI in and out through `claude auth`. Credentials never pass
/// through this type: the CLI runs the OAuth flow and stores the result.
public actor ClaudeAuth {
    /// How long `auth status` and `auth logout` get before they're killed.
    public static let commandTimeout: Duration = .seconds(30)
    static let browserPollInterval: Duration = .milliseconds(100)

    private let executable: URL
    private var login: Process?
    private var loginInput: FileHandle?
    private var loginGeneration = 0
    private var cancelRequested = false

    public init(executable: URL) {
        self.executable = executable
    }

    // MARK: Status and sign-out

    public func status() async throws -> AuthStatus {
        let result = try await run(["auth", "status", "--json"])
        return try AuthStatus.decode(result.stdout)
    }

    public func signOut() async throws {
        let result = try await run(["auth", "logout"])
        guard result.status == 0 else {
            let message = Self.lastLine(result.stderr) ?? "Signing out failed (status \(result.status))."
            throw ClaudeAuthError.commandFailed(message)
        }
    }

    // MARK: Sign-in

    /// Starts `claude auth login`. The stream ends after `.finished` and
    /// `.status`; it throws only if the CLI can't be started. Ending the
    /// stream early (cancelling the consuming task) kills the CLI.
    public nonisolated func signIn(console: Bool = false) -> AsyncThrowingStream<SignInEvent, Error> {
        let (stream, sink) = AsyncThrowingStream<SignInEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { await self.runSignIn(console: console, sink: sink) }
        sink.onTermination = { _ in
            task.cancel()
            Task { await self.cancelSignIn() }
        }
        return stream
    }

    /// Sends a code copied from the browser. The CLI expects the whole
    /// `code#state` string the callback page shows.
    public func submitCode(_ code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let loginInput, login?.isRunning == true else { throw ClaudeAuthError.notSigningIn }
        try loginInput.write(contentsOf: Data((trimmed + "\n").utf8))
    }

    /// Kills a running sign-in. Its stream then reports `.finished(.cancelled)`.
    public func cancelSignIn() {
        guard let login, login.isRunning else { return }
        cancelRequested = true
        login.terminate()
    }

    private func runSignIn(console: Bool, sink: AsyncThrowingStream<SignInEvent, Error>.Continuation) async {
        cancelSignIn()
        cancelRequested = false
        loginGeneration += 1
        let generation = loginGeneration

        let browserDirectory: URL
        let helper: URL
        do {
            (browserDirectory, helper) = try Self.makeBrowserHelper()
        } catch {
            sink.finish(throwing: ClaudeAuthError.launchFailed(error.localizedDescription))
            return
        }
        defer { try? FileManager.default.removeItem(at: browserDirectory) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "login", console ? "--console" : "--claudeai"]
        var environment = Self.commandEnvironment(ProcessInfo.processInfo.environment, loginPath: ShellPath.cachedLoginPath)
        // The CLI opens its sign-in URL with $BROWSER. Pointing that at a
        // script that only records the URL hands the URL to the app instead.
        environment["BROWSER"] = helper.path
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let (pipeEvents, pipeSink) = AsyncStream<LoginPipeEvent>.makeStream(bufferingPolicy: .unbounded)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                pipeSink.yield(.stdoutClosed)
            } else {
                pipeSink.yield(.stdout(chunk))
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                pipeSink.yield(.stderrClosed)
            } else {
                pipeSink.yield(.stderr(chunk))
            }
        }
        process.terminationHandler = { finished in
            pipeSink.yield(.exited(finished.terminationStatus))
        }

        do {
            try process.run()
        } catch {
            sink.finish(throwing: ClaudeAuthError.launchFailed(error.localizedDescription))
            return
        }
        login = process
        loginInput = input.fileHandleForWriting
        // The stream may have been dropped before the process existed.
        if Task.isCancelled { process.terminate() }

        let recorded = browserDirectory.appending(path: Self.recordedURLFile)
        let watcher = Task {
            while !Task.isCancelled {
                if let text = try? String(contentsOf: recorded, encoding: .utf8),
                   let url = SignInOutputParser.browserURL(fromRecorded: text) {
                    pipeSink.yield(.browserURL(url))
                    return
                }
                try? await Task.sleep(for: Self.browserPollInterval)
            }
        }

        var parser = SignInOutputParser()
        var stderrLines = LineSplitter()
        var lastError: String?
        var stdoutOpen = true, stderrOpen = true
        var exitStatus: Int32?
        var browserReported = false

        func forward(_ lines: [SignInLine]) {
            for line in lines {
                switch line {
                case .manualURL(let url): sink.yield(.manualURL(url))
                case .codePrompt: sink.yield(.codePrompt)
                case .codeRejected(let message): sink.yield(.codeRejected(message))
                case .loginSucceeded: sink.yield(.output(SignInOutputParser.successMarker, isError: false))
                case .text(let text): sink.yield(.output(text, isError: false))
                }
            }
        }
        func forwardErrors(_ lines: [String]) {
            for raw in lines {
                let line = SignInOutputParser.stripEscapes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if line.hasPrefix(SignInOutputParser.invalidCodeMarker) {
                    sink.yield(.codeRejected(line))
                } else {
                    lastError = line
                    sink.yield(.output(line, isError: true))
                }
            }
        }

        for await event in pipeEvents {
            switch event {
            case .stdout(let chunk): forward(parser.consume(chunk))
            case .stderr(let chunk): forwardErrors(stderrLines.consume(chunk))
            case .browserURL(let url):
                guard !browserReported else { break }
                browserReported = true
                sink.yield(.openURL(url))
            case .stdoutClosed: stdoutOpen = false
            case .stderrClosed: stderrOpen = false
            case .exited(let status): exitStatus = status
            }
            if let exitStatus, !stdoutOpen, !stderrOpen {
                watcher.cancel()
                // A CLI that exits fast can beat the poll; read the file once more.
                if !browserReported, let text = try? String(contentsOf: recorded, encoding: .utf8),
                   let url = SignInOutputParser.browserURL(fromRecorded: text) {
                    browserReported = true
                    sink.yield(.openURL(url))
                }
                forward(parser.flush())
                forwardErrors(stderrLines.flush())
                pipeSink.finish()
                let outcome: SignInOutcome = if cancelRequested || process.terminationReason == .uncaughtSignal {
                    // The real CLI traps SIGTERM and exits 143, so the request
                    // is what marks a cancel, not the termination reason.
                    .cancelled
                } else if exitStatus == 0 {
                    .succeeded
                } else {
                    .failed(exitStatus: exitStatus, message: lastError)
                }
                sink.yield(.finished(outcome))
                break
            }
        }
        watcher.cancel()
        // The loop also ends when the consumer drops the stream, which cancels
        // this task while the CLI may still be running.
        if process.isRunning { process.terminate() }
        if loginGeneration == generation {
            login = nil
            loginInput = nil
        }

        guard !Task.isCancelled else {
            sink.finish()
            return
        }
        do {
            sink.yield(.status(try await status()))
            sink.finish()
        } catch {
            sink.finish(throwing: error)
        }
    }

    // MARK: Helpers

    static let recordedURLFile = "url"
    static let helperFile = "open-url"

    /// A private temp directory holding a `$BROWSER` stand-in that appends
    /// its argument to `url` in the same directory.
    static func makeBrowserHelper(fileManager: FileManager = .default) throws -> (directory: URL, helper: URL) {
        let directory = fileManager.temporaryDirectory.appending(path: "ClaudeNative-signin-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let helper = directory.appending(path: helperFile)
        let recorded = directory.appending(path: recordedURLFile)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \(shellQuoted(recorded.path))\n"
        try Data(script.utf8).write(to: helper)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (directory, helper)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    struct CommandResult {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// The environment sign-in commands run with: a conversation's, the
    /// login PATH included. Opened from the Finder, the app has launchd's
    /// short PATH, and a `claude` installed with npm (`#!/usr/bin/env
    /// node`) couldn't find node: `auth status` printed nothing and sign-in
    /// failed with no reason shown.
    static func commandEnvironment(_ parent: [String: String], loginPath: String?) -> [String: String] {
        ClaudeCLI.sessionEnvironment(parent, loginPath: loginPath)
    }

    /// Runs a short `claude` command to completion with the scrubbed env.
    private func run(_ arguments: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.commandEnvironment(ProcessInfo.processInfo.environment, loginPath: ShellPath.cachedLoginPath)
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        let (exits, exitSink) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exitSink.yield($0.terminationStatus); exitSink.finish() }
        do {
            try process.run()
        } catch {
            throw ClaudeAuthError.launchFailed(error.localizedDescription)
        }
        // Drain both pipes concurrently so a full pipe can't stall the child.
        async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let pid = process.processIdentifier
        let timeout = Task { () -> Bool in
            do { try await Task.sleep(for: Self.commandTimeout) } catch { return false }
            kill(pid, SIGTERM)
            return true
        }
        let status = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await code in exits { status = code }
            return status
        } onCancel: {
            kill(pid, SIGTERM)
        }
        timeout.cancel()
        let timedOut = await timeout.value
        let result = CommandResult(status: status, stdout: await stdout, stderr: await stderr)
        if timedOut { throw ClaudeAuthError.timedOut }
        try Task.checkCancellation()
        return result
    }
}

/// Splits a byte stream into UTF-8 lines.
struct LineSplitter {
    private var pending = Data()

    mutating func consume(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    mutating func flush() -> [String] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}
