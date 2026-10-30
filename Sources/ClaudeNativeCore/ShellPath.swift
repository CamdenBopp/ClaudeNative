import Foundation

/// The PATH the user's own terminal has. An app opened from the Finder gets
/// launchd's short PATH, so without this Claude's Bash tool can't find
/// Homebrew, gh, node or anything installed under the home folder.
public enum ShellPath {
    static let startMarker = "__CLAUDE_NATIVE_PATH_START__"
    static let endMarker = "__CLAUDE_NATIVE_PATH_END__"
    /// How long an interactive login shell gets to start before we give up.
    static let timeout: TimeInterval = 4

    /// Places tools commonly live, added after the shell's own PATH.
    static func fallbacks(home: String) -> [String] {
        ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// The login shell's PATH, or nil when it couldn't be read in time.
    public static func loginShellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Markers around the value, so whatever the shell's startup files
        // print doesn't matter.
        process.arguments = ["-ilc", "printf '%s%s%s' '\(startMarker)' \"$PATH\" '\(endMarker)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // Read while the shell runs, so a chatty startup can't fill the pipe
        // and stall it.
        let collected = OutputBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Done once the end marker has arrived, within the time limit as a
        // whole. Reading to end of file after the shell exited waited for
        // anything its startup left running that still held the output
        // (a daemon, `(sleep 12 &)`), past the limit; every conversation
        // start waited with it.
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        var path: String?
        while Date() < deadline {
            path = extract(from: String(decoding: collected.data, as: UTF8.self))
            if path != nil { break }
            if !process.isRunning {
                // What it wrote just before exiting may still be arriving.
                exitedAt = exitedAt ?? Date()
                if let exitedAt, Date().timeIntervalSince(exitedAt) > exitGrace { break }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        output.fileHandleForReading.readabilityHandler = nil
        // An interactive zsh ignores SIGTERM; a shell still there is killed.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return path
    }

    /// How often the read looks for the marker, and how long it waits for
    /// output after the shell has exited.
    static let pollInterval: TimeInterval = 0.02
    static let exitGrace: TimeInterval = 0.2

    static func extract(from output: String) -> String? {
        guard let start = output.range(of: startMarker),
              let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// The shell's entries first, then the app's own, then the fallbacks;
    /// each directory once, in that order.
    public static func merged(login: String?, inherited: String?, home: String) -> String {
        var seen = Set<String>()
        let entries = [login, inherited].compactMap { $0 }.flatMap { $0.split(separator: ":").map(String.init) }
            + fallbacks(home: home)
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Read once per app run; starting a login shell takes a moment.
    public static let cachedLoginPath: String? = loginShellPath()
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }
}
