import Foundation
import OSLog

/// Finds the `claude` executable to drive.
public enum CLILocator {
    public static let environmentOverride = "CLAUDE_NATIVE_CLI"

    public static func locate(fileManager: FileManager = .default) -> URL? {
        if let override = ProcessInfo.processInfo.environment[environmentOverride] {
            return URL(fileURLWithPath: override)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = desktopBundledCLIs(home: home, fileManager: fileManager) + [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return found }
        // Then wherever the user's own terminal finds it: an npm, nvm, bun
        // or volta install wasn't found from the Finder, though Terminal ran it.
        return firstExecutable(named: "claude", in: ShellPath.cachedLoginPath, fileManager: fileManager)
    }

    /// The first `name` that's executable in a PATH's folders, in order.
    static func firstExecutable(named name: String, in path: String?, fileManager: FileManager = .default) -> URL? {
        (path ?? "").split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0)).appending(path: name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// The CLI builds the desktop app keeps under Application Support, newest
    /// version first.
    static func desktopBundledCLIs(home: URL, fileManager: FileManager) -> [URL] {
        let root = home.appending(path: "Library/Application Support/Claude/claude-code")
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .flatMap { version -> [URL] in
                let versionDir = root.appending(path: version)
                let builds = (try? fileManager.contentsOfDirectory(atPath: versionDir.path)) ?? []
                return builds.map { versionDir.appending(path: "\($0)/claude.app/Contents/MacOS/claude") }
            }
    }
}

public enum ClaudeCLIError: Error, LocalizedError {
    case notRunning
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Claude isn't running."
        case .launchFailed(let reason): "Couldn't start Claude: \(reason)"
        }
    }
}

final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process?) {
        lock.withLock { self.process = process }
    }

    /// SIGTERM, then SIGKILL if the process is still alive after `grace`.
    /// Blocks for at most `grace`; used while the app quits.
    func terminate(grace: TimeInterval = ClaudeCLI.killGrace) {
        guard let process = lock.withLock({ process }), process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            usleep(ClaudeCLI.killPollMicroseconds)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// An image sent with a message.
public struct ImageAttachment: Sendable, Equatable, Identifiable {
    public let id = UUID()
    /// What the user sees and hears for it, usually the file name.
    public let name: String
    public let mediaType: String
    public let data: Data

    /// The image types the Messages API accepts, by file extension.
    public static let mediaTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]

    public init(name: String, mediaType: String, data: Data) {
        self.name = name
        self.mediaType = mediaType
        self.data = data
    }

    /// Reads an image file, or nil when it isn't a type the API accepts.
    public init?(fileURL: URL) {
        guard let mediaType = Self.mediaTypes[fileURL.pathExtension.lowercased()],
              let data = try? Data(contentsOf: fileURL)
        else { return nil }
        self.init(name: fileURL.lastPathComponent, mediaType: mediaType, data: data)
    }
}

private enum PipeEvent: Sendable {
    case output(Data)
    case closed
    case exited(Int32)
    /// The process exited a while ago and its output hasn't closed.
    case outputOutlived
}

/// One `claude` process speaking stream-json over stdin and stdout.
public actor ClaudeCLI {
    /// How long output may stay open after the process exits before the
    /// exit is reported anyway.
    static let exitOutputGrace: Duration = .seconds(1)

    public nonisolated let events: AsyncStream<StreamEvent>
    private let eventSink: AsyncStream<StreamEvent>.Continuation
    private let executable: URL
    private let workingDirectory: URL
    /// Changed by setModel/setPermissionMode before the process starts.
    private var model: String?
    private var permissionMode: String
    /// Passed as --effort; nil leaves it to the CLI.
    private let effort: String?
    private var process: Process? {
        didSet { running.set(process) }
    }
    /// The live process, readable from any thread so it can be ended
    /// synchronously while the app quits.
    private nonisolated let running = RunningProcess()
    private var stdin: FileHandle?
    private var pendingOutput = Data()
    private var sessionID = ""

    public init(
        executable: URL,
        workingDirectory: URL,
        model: String? = nil,
        permissionMode: String = "default",
        effort: String? = nil
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// The claude command's arguments, before the thinking-display flags
    /// that depend on its version.
    /// `fork` continues from a copy: the CLI gives the resumed session a
    /// new id and leaves the original's file as it was.
    static func launchArguments(permissionMode: String, model: String?, effort: String?, resumeSessionID: String?, fork: Bool = false) -> [String] {
        var arguments = [
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool=stdio",
            "--permission-mode=\(permissionMode)",
            // Makes Bypass permissions a mode the Mode menu can switch to
            // mid-conversation; without it the CLI refuses the switch
            // ("bypass_not_launched"). It bypasses nothing by itself.
            "--allow-dangerously-skip-permissions",
            "--setting-sources=user,project,local",
        ]
        if let model { arguments.append("--model=\(model)") }
        if let effort { arguments.append("--effort=\(effort)") }
        if let resumeSessionID {
            arguments += ["--resume", resumeSessionID]
            if fork { arguments.append("--fork-session") }
        }
        return arguments
    }

    public func start(resumeSessionID: String? = nil, fork: Bool = false) throws {
        var arguments = Self.launchArguments(permissionMode: permissionMode, model: model, effort: effort, resumeSessionID: resumeSessionID, fork: fork)
        let environment = Self.sessionEnvironment(ProcessInfo.processInfo.environment, loginPath: ShellPath.cachedLoginPath)
        if ThinkingDisplay.isSupported(by: executable, environment: environment) { arguments += ThinkingDisplay.arguments }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Output and exit travel through one ordered stream, so lines are
        // parsed in the order the CLI wrote them and the exit comes last.
        let (pipeEvents, pipeSink) = AsyncStream<PipeEvent>.makeStream(bufferingPolicy: .unbounded)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                pipeSink.yield(.closed)
            } else {
                pipeSink.yield(.output(chunk))
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { finished in
            pipeSink.yield(.exited(finished.terminationStatus))
            // Something it started may still hold the output open (a
            // background job): its exit then went unreported for as long,
            // with no "Claude stopped running" and no Reconnect.
            Task {
                try? await Task.sleep(for: Self.exitOutputGrace)
                pipeSink.yield(.outputOutlived)
            }
        }
        Task { [weak self] in
            var status: Int32?
            var closed = false
            for await event in pipeEvents {
                switch event {
                case .output(let chunk): await self?.receive(chunk)
                case .closed: closed = true
                case .exited(let code): status = code
                case .outputOutlived:
                    // What it wrote before exiting has been read by now.
                    output.fileHandleForReading.readabilityHandler = nil
                    closed = true
                }
                if closed, let status {
                    await self?.finish(status: status)
                    pipeSink.finish()
                }
            }
        }
        do {
            try process.run()
        } catch {
            throw ClaudeCLIError.launchFailed(error.localizedDescription)
        }
        self.process = process
        // A write to a CLI that has closed its input fails with EPIPE
        // instead of raising SIGPIPE, which ends a process that hasn't
        // chosen to ignore it (the app does; a test runner doesn't).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.stdin = input.fileHandleForWriting
        try write(.object([
            "type": .string("control_request"),
            "request_id": .string("initialize"),
            "request": .object(["subtype": .string("initialize")]),
        ]))
    }

    /// The parent's environment minus what a host Claude process sets for its
    /// own children: launched from inside another Claude session, those would
    /// point this CLI at that session's endpoint and credentials.
    public static func childEnvironment(_ parent: [String: String]) -> [String: String] {
        parent.filter { key, _ in
            key == CLILocator.environmentOverride
                || (!key.hasPrefix("CLAUDE") && !inheritedHostKeys.contains(key))
        }
    }

    /// The environment for a conversation's process: the scrubbed parent
    /// environment with the user's login-shell PATH in front, so the tools
    /// Claude runs find what the user's terminal would.
    public static func sessionEnvironment(_ parent: [String: String], loginPath: String?) -> [String: String] {
        var environment = childEnvironment(parent)
        let home = parent["HOME"] ?? NSHomeDirectory()
        environment["PATH"] = ShellPath.merged(login: loginPath, inherited: parent["PATH"], home: home)
        return environment
    }

    static let inheritedHostKeys: Set<String> = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
    ]

    /// `uuid` is what the CLI saves the message under, so the app's row and
    /// the one read back from the file share an id.
    public func send(_ text: String, images: [ImageAttachment] = [], uuid: String? = nil) throws {
        try write(Self.userMessage(text, images: images, sessionID: sessionID, uuid: uuid))
        turnsRunning += 1
    }

    /// Messages sent whose turns haven't ended, so stopping knows whether a
    /// reply is underway.
    private var turnsRunning = 0

    /// A stdin user line: images first, then the text, as the API expects.
    public static func userMessage(_ text: String, images: [ImageAttachment], sessionID: String, uuid: String? = nil) -> JSONValue {
        let imageBlocks: [JSONValue] = images.map { image in
            .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(image.mediaType),
                    "data": .string(image.data.base64EncodedString()),
                ]),
            ])
        }
        let textBlock: [JSONValue] = text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        var line: [String: JSONValue] = [
            "type": .string("user"),
            "session_id": .string(sessionID),
            "parent_tool_use_id": .null,
            "message": .object([
                "role": .string("user"),
                "content": .array(imageBlocks + textBlock),
            ]),
        ]
        if let uuid { line["uuid"] = .string(uuid) }
        return .object(line)
    }

    public func answer(
        _ request: PermissionRequest,
        allow: Bool,
        updatedInput: JSONValue? = nil,
        remember: PermissionSuggestion? = nil,
        denialMessage: String? = nil
    ) throws {
        try write(Self.permissionResponse(to: request, allow: allow, updatedInput: updatedInput, remember: remember, denialMessage: denialMessage))
    }

    /// The control_response that answers a can_use_tool request. A plain deny
    /// lets the model carry on without the tool, as the desktop app does.
    /// `denialMessage` is what Claude reads instead, as when a plan is sent
    /// back with what should change.
    public static func permissionResponse(
        to request: PermissionRequest,
        allow: Bool,
        updatedInput: JSONValue? = nil,
        remember: PermissionSuggestion? = nil,
        denialMessage: String? = nil
    ) -> JSONValue {
        var decision: [String: JSONValue] = allow
            ? ["behavior": .string("allow"), "updatedInput": updatedInput ?? request.input]
            : ["behavior": .string("deny"), "message": .string(denialMessage ?? "The user denied this.")]
        // The CLI saves the rule itself (session, or the settings file the
        // suggestion names).
        if allow, let remember {
            decision["updatedPermissions"] = .array([remember.raw])
        }
        if let toolUseID = request.toolUseID {
            decision["toolUseID"] = .string(toolUseID)
        }
        return .object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(request.requestID),
                "response": .object(decision),
            ]),
        ])
    }

    public func interrupt() throws {
        try write(.object([
            "type": .string("control_request"),
            "request_id": .string(UUID().uuidString),
            "request": .object(["subtype": .string("interrupt")]),
        ]))
    }

    /// Switches model for the following turns; `value` is a `ModelOption.value`.
    public func setModel(_ value: String) throws {
        // Chosen before the process has started (a saved session still
        // loading): it starts with it. Sent as a control it failed with
        // "Claude isn't running" and the process started with the old one.
        guard process != nil else {
            model = value == "default" ? nil : value
            return
        }
        try control("set_model", ["model": .string(value)])
    }

    /// "default" asks before tools run, "acceptEdits" lets file edits through,
    /// "plan" only plans.
    public func setPermissionMode(_ mode: String) throws {
        // As setModel: a mode chosen while starting (Plan, say) is the one
        // the process starts in, not lost.
        guard process != nil else {
            permissionMode = mode
            return
        }
        try control("set_permission_mode", ["mode": .string(mode)])
    }

    private func control(_ subtype: String, _ fields: [String: JSONValue]) throws {
        var request = fields
        request["subtype"] = .string(subtype)
        try write(.object([
            "type": .string("control_request"),
            "request_id": .string(UUID().uuidString),
            "request": .object(request),
        ]))
    }

    /// The running process's id, for tests.
    public var processIdentifier: Int32? { process?.processIdentifier }

    /// How long a stopped process gets to exit before it is killed.
    public static let killGrace: TimeInterval = 2
    static let killPollMicroseconds: UInt32 = 20_000

    /// Ends the process: SIGTERM, then SIGKILL if it hasn't exited after
    /// `killGrace`. A hung CLI can't outlive its conversation.
    public func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(for: .seconds(Self.killGrace))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Stops the CLI as `stop()` does and returns once it has exited, so
    /// nothing it writes can land after: deleting its conversation needs
    /// the file to stay gone.
    public func stopAndWait() async {
        guard let process else { return }
        await interruptRunningTurn()
        stop()
        // stop() kills after killGrace; a little longer covers the reaping.
        let deadline = Date().addingTimeInterval(Self.killGrace + Self.exitWaitSlack)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: Self.exitPollInterval)
        }
    }
    static let exitWaitSlack: TimeInterval = 1

    /// Mid-reply, interrupts the turn, as Stop does, and returns once it has
    /// ended or `interruptGrace` has passed. The CLI then saves the reply so
    /// far; terminated outright it saved none of it.
    public func interruptRunningTurn() async {
        guard let process, turnsRunning > 0, (try? interrupt()) != nil else { return }
        let deadline = Date().addingTimeInterval(Self.interruptGrace)
        while turnsRunning > 0, process.isRunning, Date() < deadline {
            try? await Task.sleep(for: Self.exitPollInterval)
        }
    }
    /// How long an interrupted turn may take to end before the CLI is
    /// stopped anyway.
    static let interruptGrace: TimeInterval = 3
    static let exitPollInterval: Duration = .milliseconds(50)

    /// Ends the process right away, from any thread. For app termination,
    /// when an async `stop()` would never get to run.
    public nonisolated func terminateNow() {
        running.terminate()
    }

    private func write(_ value: JSONValue) throws {
        guard let stdin, process?.isRunning == true else { throw ClaudeCLIError.notRunning }
        try stdin.write(contentsOf: value.line())
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        pendingOutput.append(chunk)
        while let newline = pendingOutput.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pendingOutput[pendingOutput.startIndex..<newline]
            pendingOutput.removeSubrange(pendingOutput.startIndex...newline)
            guard !line.isEmpty else { continue }
            emit(line: Data(line))
        }
    }

    private func emit(line: Data) {
        do {
            let value = try JSONValue.parse(line)
            mainModel.observe(value)
            for event in try StreamEvent.readAll(value) {
                switch event {
                case .sessionStarted(let id, _): sessionID = id
                case .turnFinished: turnsRunning = max(0, turnsRunning - 1)
                case .turnStopped: turnsRunning = 0
                case .contextUsage(let usage):
                    // A subagent on a bigger model put its window in the
                    // result too; the conversation's own is what fills.
                    eventSink.yield(.contextUsage(usage.measured(against: mainModel.model)))
                    continue
                default: break
                }
                eventSink.yield(event)
            }
        } catch {
            let preview = String(decoding: line.prefix(200), as: UTF8.self)
            // Kept in the transcript's diagnostics, which nothing shows, so
            // also logged: a line that mattered failing is otherwise silent.
            Self.logger.error("Unreadable stream line (\(String(describing: error), privacy: .public)): \(preview, privacy: .private)")
            eventSink.yield(.unrecognized(type: "malformed: \(error)", raw: .string(preview)))
        }
    }

    private static let logger = Logger(subsystem: "net.bopp.ClaudeNative", category: "Stream")
    /// The main conversation's model, for measuring its context.
    private var mainModel = MainModelTracker()

    private func finish(status: Int32) {
        turnsRunning = 0
        eventSink.yield(.processExited(status: status))
        eventSink.finish()
        process = nil
        stdin = nil
    }
}
