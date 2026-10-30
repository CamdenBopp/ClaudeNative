import Darwin
import Foundation

/// A shell on a pseudo-terminal of its own, its controlling terminal, as
/// Terminal runs one: job control works and Control-C reaches what runs. Output arrives as text chunks;
/// `TerminalText` cleans them for reading.
public final class TerminalSession: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case spawnFailed(Int32)
    }

    /// The size the shell is told its terminal is. The panel wraps lines
    /// itself, so this is only what programs format their output for.
    static let columns: UInt16 = 120
    static let rows: UInt16 = 40

    private let master: Int32
    public let processIdentifier: pid_t
    /// Reads the terminal. The descriptor is closed only in its cancel
    /// handler: closing it right after clearing a FileHandle's handler let
    /// a new terminal reuse the number while the old source still read it.
    private let reader: DispatchSourceRead
    /// Typed text goes out on this queue, through a descriptor of its own
    /// that it alone closes. Written from the main thread, a program not
    /// reading its input filled the terminal's buffer and the write waited
    /// for it, hanging the app.
    private let writeQueue = DispatchQueue(label: "ClaudeNative.terminal.write")
    private let writer: Int32
    /// How long a write waits for room before checking the shell is still there.
    static let writeWait: Int32 = 100
    private let lock = NSLock()
    private var exited = false

    /// Starts `shell` (the user's login shell by default) in `folder`.
    /// `output` is called on a background queue with each chunk; `ended`
    /// once the shell exits.
    public init(
        in folder: URL,
        shell: String = TerminalSession.loginShell,
        arguments: [String] = TerminalSession.loginArguments,
        output: @escaping @Sendable (String) -> Void,
        ended: @escaping @Sendable () -> Void = {}
    ) throws {
        let environment = Self.environment(from: ProcessInfo.processInfo.environment, shell: shell)

        // Everything the child needs, made before the fork: between fork and
        // exec only async-signal-safe calls are allowed, so nothing is
        // allocated there.
        let argv = CStringArray([shell] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let path = strdup(shell)
        let directory = strdup(folder.path)
        defer { free(path); free(directory) }
        // Past the highest descriptor the process can have open.
        let descriptorLimit = getdtablesize()

        // forkpty makes the terminal the child's controlling terminal (it
        // runs login_tty), as Terminal's shells have, so Control-C typed
        // into it reaches whatever runs in the foreground.
        var size = winsize(ws_row: Self.rows, ws_col: Self.columns, ws_xpixel: 0, ws_ypixel: 0)
        var masterDescriptor: Int32 = -1
        let pid = forkpty(&masterDescriptor, nil, nil, &size)
        if pid == 0 {
            // The child: default signal handling and nothing blocked (a
            // spawned process inherits ignored signals and the mask), then
            // the shell.
            var none = sigset_t()
            sigemptyset(&none)
            sigprocmask(SIG_SETMASK, &none, nil)
            // One call each, not a loop over an array literal: building the
            // array would allocate, which a forked child of a threaded
            // process mustn't do before exec.
            Darwin.signal(SIGINT, SIG_DFL)
            Darwin.signal(SIGQUIT, SIG_DFL)
            Darwin.signal(SIGTSTP, SIG_DFL)
            Darwin.signal(SIGTTIN, SIG_DFL)
            Darwin.signal(SIGTTOU, SIG_DFL)
            Darwin.signal(SIGCHLD, SIG_DFL)
            Darwin.signal(SIGPIPE, SIG_DFL)
            Darwin.signal(SIGHUP, SIG_DFL)
            Darwin.signal(SIGTERM, SIG_DFL)
            Darwin.signal(SIGALRM, SIG_DFL)
            // Only the terminal (0, 1 and 2) goes to the shell. Inherited,
            // a git pipe open at that moment never reached end of file and
            // the Changes panel read until the shell quit. Every number,
            // not a list made before the fork: another thread may have
            // opened one since.
            var descriptor: Int32 = 3
            while descriptor < descriptorLimit {
                close(descriptor)
                descriptor += 1
            }
            _ = chdir(directory)
            execve(path, argv.pointers, envp.pointers)
            _exit(127)
        }
        guard pid > 0 else { throw Failure.spawnFailed(errno) }
        self.master = masterDescriptor
        processIdentifier = pid
        // Its own descriptor, not blocking: a full buffer waits on poll, on
        // the write queue, where ending the shell can stop it.
        writer = dup(masterDescriptor)
        _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: masterDescriptor, queue: Self.readQueue)
        reader = source
        // Reads end wherever they end; a character split between two was
        // two replacement characters, read aloud by VoiceOver. Only the
        // serial read queue touches it.
        nonisolated(unsafe) var decoder = UTF8Chunks()
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: Self.readSize)
            let count = buffer.withUnsafeMutableBytes { read(masterDescriptor, $0.baseAddress, Self.readSize) }
            if count > 0 {
                let text = decoder.decode(buffer.prefix(count))
                if !text.isEmpty { output(text) }
                return
            }
            // Interrupted or nothing there yet: not the end.
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            // End of file, or EIO once the shell's side has closed.
            source.cancel()
            guard let self else { return }
            self.markExited()
            // Reaped, so an exited shell doesn't linger as a zombie.
            var status: Int32 = 0
            if waitpid(self.processIdentifier, &status, 0) == self.processIdentifier {
                self.markReaped()
                self.lock.lock(); self.status = status; self.lock.unlock()
            }
            ended()
        }
        source.setCancelHandler { close(masterDescriptor) }
        source.resume()
    }

    /// The shell's environment: the app's, for plain output.
    static func environment(from base: [String: String], shell: String, locale: Locale = .current) -> [String: String] {
        var environment = base
        // Plain output: the panel shows text, not a drawn screen.
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        environment["NO_COLOR"] = "1"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["SHELL"] = shell
        // An app opened from the Finder has no LANG, and with none the
        // shell's ls showed café.txt as "caf??.txt", read so by VoiceOver.
        // Terminal sets one from the user's region; so does this.
        if (environment["LANG"] ?? "").isEmpty {
            environment["LANG"] = utf8Language(for: locale)
        }
        return environment
    }

    /// "en_US.UTF-8" for a US English locale, if the system has it; that
    /// one otherwise.
    static func utf8Language(for locale: Locale) -> String {
        let fallback = "en_US.UTF-8"
        guard let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier else { return fallback }
        let name = "\(language)_\(region).UTF-8"
        return FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") ? name : fallback
    }

    static let readQueue = DispatchQueue(label: "ClaudeNative.terminal.read")
    static let readSize = 16_384

    /// A login shell, interactive, as Terminal starts one: /etc/zprofile's
    /// path_helper and ~/.zprofile run, so PATH has what a Terminal window
    /// has. With -i alone it lacked /usr/local/bin and Homebrew's folders.
    public static let loginArguments = ["-l", "-i"]

    /// The account's login shell, as Terminal starts it. An app opened from
    /// the Finder can carry another SHELL (the panel came up in bash 3.2).
    public static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Writes `text` to the shell, as if typed.
    public func send(_ text: String) {
        let bytes = Array(text.utf8)
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count, !isExited {
                let written = bytes.withUnsafeBytes { buffer in
                    write(writer, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    // No room until the program reads; look again shortly.
                    var ready = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&ready, 1, Self.writeWait)
                } else {
                    return
                }
            }
        }
    }

    private var isExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }

    /// Whether a program is reading a password: echo off with the terminal
    /// still in line mode, as sudo's and ssh's prompts set it. zsh's line
    /// editor turns echo off at every prompt too, but leaves line mode, so
    /// echo alone took each prompt for a password one.
    public var readsPassword: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !writerClosed else { return false }
        var settings = termios()
        guard tcgetattr(writer, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ECHO) == 0 && settings.c_lflag & tcflag_t(ICANON) != 0
    }

    /// Control-C, as typed in a terminal: the terminal driver sends SIGINT
    /// to whatever is in the foreground (a command, or the shell itself at
    /// its prompt, which clears the line).
    /// Sent at once, not behind typed text that's waiting for room: queued,
    /// it never went while a program wasn't reading. With the terminal's
    /// input full the byte can't go either, so the foreground process group
    /// gets SIGINT directly, as the terminal driver would send it.
    public func interrupt() {
        // Under the lock the descriptor is closed with, so it's never one
        // a newer file has taken.
        lock.lock(); defer { lock.unlock() }
        guard !exited, !writerClosed else { return }
        var byte: UInt8 = 0x03
        if write(writer, &byte, 1) == 1 { return }
        let group = tcgetpgrp(writer)
        if group > 0 { _ = Self.sendSignal(-group, SIGINT) }
    }

    /// Ends the shell and everything it started.
    ///
    /// Once only, and no signal once the shell has been reaped: its id can
    /// be another process's by then (seen in the test suite, a stale
    /// session's terminate killed a new session's shell).
    public func terminate() {
        lock.lock()
        let first = !terminated
        terminated = true
        let wasReaped = reaped
        exited = true
        lock.unlock()
        guard first else { return }
        if !wasReaped {
            _ = Self.sendSignal(-processIdentifier, SIGHUP)
            _ = Self.sendSignal(processIdentifier, SIGHUP)
            var status: Int32 = 0
            if waitpid(processIdentifier, &status, WNOHANG) == processIdentifier {
                markReaped()
            } else {
                reapOnExit()
            }
        }
        // The cancel handler closes the descriptor, once nothing reads it;
        // the writer's goes once queued writes have seen the end.
        reader.cancel()
        writeQueue.async { [self] in
            lock.lock(); close(writer); writerClosed = true; lock.unlock()
        }
    }

    /// How long the shell has to exit after SIGHUP before it's killed.
    static let hangUpGrace: Duration = .seconds(5)
    static let reapPoll: Duration = .milliseconds(50)

    /// Reaps the shell once it exits. The reader that would have is
    /// cancelled when the session ends, which left every closed or
    /// replaced shell a zombie until the app quit. One that ignores the
    /// hang-up is killed after hangUpGrace.
    private func reapOnExit() {
        let pid = processIdentifier
        Task.detached { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now + Self.hangUpGrace
            var status: Int32 = 0
            // Our own child: its id can't be another process's until reaped.
            while clock.now < deadline {
                if waitpid(pid, &status, WNOHANG) == pid { self?.markReaped(); return }
                try? await Task.sleep(for: Self.reapPoll)
            }
            _ = Self.sendSignal(pid, SIGKILL)
            if waitpid(pid, &status, 0) == pid { self?.markReaped() }
        }
    }

    /// Sends a signal; a test sees what would be sent instead.
    nonisolated(unsafe) static var sendSignal: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }

    /// How the shell ended, as waitpid reports it, once it has.
    public var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }
    private var status: Int32?

    private var terminated = false
    private var writerClosed = false
    private var reaped = false

    private func markReaped() {
        lock.lock(); reaped = true; lock.unlock()
    }

    private func markExited() {
        lock.lock(); exited = true; lock.unlock()
    }

    deinit { terminate() }
}

/// A NULL-terminated array of C strings, owned until it's freed.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() { pointers[index] = strdup(string) }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
