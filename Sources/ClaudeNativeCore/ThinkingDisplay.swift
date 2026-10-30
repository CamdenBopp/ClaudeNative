import Foundation
import Synchronization

/// Asks the CLI for summaries of Claude's thinking. By default the CLI
/// streams thinking blocks with empty text, so the transcript could only
/// say "Thinking". `--thinking-display summarized` streams a readable
/// summary instead. The flag is hidden from `--help` and the
/// `showThinkingSummaries` setting has no effect in stream-json mode
/// (both checked against 2.1.308), so the flag is only passed to a CLI
/// that says it knows it.
public enum ThinkingDisplay {
    public static let arguments = ["--thinking-display", "summarized"]

    /// A value no CLI accepts. `--version` ignores flags it doesn't know,
    /// so `--thinking-display <this> --version` exits cleanly on a CLI
    /// without the flag, and on one with it fails listing the choices.
    static let probeValue = "claude-native-probe"

    /// Whether probe output shows the CLI knows the flag and its summaries.
    static func probeShowsSupport(_ output: String) -> Bool {
        output.contains("--thinking-display") && output.contains("summarized")
    }

    /// Everything already written to `handle`, up to `maxProbeOutput`,
    /// without blocking for more.
    static func readAvailable(_ handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxProbeOutput {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static let cache = Mutex<[String: Bool]>([:])

    /// How long the probe may take. `--version` answers in well under a
    /// second; a CLI that hangs is treated as not knowing the flag rather
    /// than holding up the conversation.
    static let probeTimeout: TimeInterval = 5
    /// More than enough for the version line or the choices error.
    static let maxProbeOutput = 64 * 1024

    /// Whether `executable` takes the flag. Runs the CLI once per path and
    /// remembers the answer; any failure to run it, or no answer within
    /// the timeout, counts as no.
    ///
    /// `environment` should be the one the CLI itself runs with: a `claude`
    /// installed through npm is a script that needs `node` from the login
    /// shell's PATH, and without it the probe failed and the flag was
    /// never passed.
    public static func isSupported(by executable: URL, environment: [String: String]? = nil) -> Bool {
        if let known = cache.withLock({ $0[executable.path] }) { return known }
        let process = Process()
        process.executableURL = executable
        if let environment { process.environment = environment }
        process.arguments = ["--thinking-display", probeValue, "--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        var supported = false
        do {
            try process.run()
            if exited.wait(timeout: .now() + probeTimeout) == .success {
                // Read what's there without waiting for end of file: a
                // child the CLI left running could hold the pipe open.
                supported = probeShowsSupport(String(decoding: readAvailable(output.fileHandleForReading), as: UTF8.self))
            } else {
                // SIGKILL: a CLI stuck here may well ignore SIGTERM.
                kill(process.processIdentifier, SIGKILL)
            }
        } catch {
            supported = false
        }
        cache.withLock { $0[executable.path] = supported }
        return supported
    }
}
