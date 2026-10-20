//
//  NativeShellExecutor.swift
//  Minis / RuntimeHost
//
//  Real arm64 process execution. The replacement for iSH's emulated guest when
//  a native runtime is present.
//
//  Why this exists: iSH runs a whole Linux kernel in userspace and translates
//  every guest instruction. That is correct and hermetic, and it is also why
//  nothing compiled for the device ever runs inside it — no clang, no node, no
//  radare2, and every `fork` costs real translation work. posix_spawn hands the
//  binary to the kernel instead, which is ~200x faster to start and is the only
//  way the toolchains the runtime manifest ships can work at all.
//
//  PRECONDITION, not a detail: the host process must carry
//  `platform-application` (plus no-sandbox/no-container to reach the shared
//  runtime root). Without it the sandbox rejects the exec at the
//  `process-exec` check and every spawn returns EPERM. `isNativeExecAvailable`
//  probes this once and the router falls back to iSH, so a stock-signed build
//  degrades to the old behaviour instead of failing.
//
//  Concurrency: one call = one process = one pgroup. Two reader threads drain
//  stdout and stderr so a command that fills one pipe cannot deadlock on the
//  other. waitpid runs on a dedicated thread; the timeout path kills the whole
//  group and lets the normal wait path finalise, so there is exactly one
//  completion.
//

import Foundation
import Darwin
import os.log

private let log = AppLogger(category: "NativeShell")

enum NativeShellError: Error, LocalizedError {
    case execUnavailable(String)
    case spawnFailed(Int32)
    case chdirFailed(Int32)
    case cancelled
    case timedOut(partialOutput: String, err: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .execUnavailable(let why): return "native exec unavailable: \(why)"
        case .spawnFailed(let e): return "posix_spawn failed: \(String(cString: strerror(e)))"
        case .chdirFailed(let e): return "chdir failed: \(String(cString: strerror(e)))"
        case .cancelled: return "cancelled"
        case .timedOut(_, _, let s): return "timed out after \(Int(s))s"
        }
    }
}

struct NativeShellResult {
    let pid: pid_t
    let exitCode: Int32
    let signal: Int32
    let output: String
    let errorOutput: String
    let duration: TimeInterval
    let timedOut: Bool

    var succeeded: Bool { exitCode == 0 && signal == 0 }
}

/// One in-flight child, so the coordinator can kill it by pid the same way it
/// kills an iSH guest task.
private struct LiveChild {
    let pid: pid_t
    let startedAt: Date
}

final class NativeShellExecutor {

    static let shared = NativeShellExecutor()

    // MARK: - Capability probe

    /// Set once, on first use.
    ///
    /// This is a real exec, not an entitlement lookup: the sandbox's decision to
    /// allow `process-exec` is the thing that matters, and the only way to know
    /// it is to try. Reading our own entitlements would answer a different
    /// question (do we carry the key?) and would need `csops`, a private API
    /// whose availability differs per OS build. Spawning `bash -c "exit 0"`
    /// answers the actual question in ~20 ms and returns a concrete errno when
    /// the answer is no.
    private(set) lazy var isNativeExecAvailable: Bool = Self.probeNativeExec()

    /// Last errno seen by the probe, for the diagnostics panel.
    private(set) static var lastProbeErrno: Int32 = 0

    private static func probeNativeExec() -> Bool {
        let candidates = ["Helpers/bash", "Helpers/bash.real"]
        guard let bash = candidates
            .map({ Bundle.main.bundleURL.appendingPathComponent($0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            lastProbeErrno = ENOENT
            return false
        }

        var pid: pid_t = 0
        let argv: [String] = [bash.path, "-c", "exit 0"]
        guard let argvC = cStringArray(argv) else { return false }
        defer { freeCStringArray(argvC, count: argv.count) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        let rc = posix_spawn(&pid, bash.path, nil, &attr, argvC, environ)
        lastProbeErrno = rc
        guard rc == 0 else {
            log.error("native exec probe refused: \(String(cString: strerror(rc))) (\(rc))")
            return false
        }
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return true
    }

    // MARK: - State

    private let stateLock = NSLock()
    private var live: [pid_t: LiveChild] = [:]
    private var cancelledPids = Set<pid_t>()

    private init() {}

    // MARK: - Public API

    /// Synchronous spawn. Call from a background queue or a detached Task — this
    /// blocks the caller until the child exits or the timeout fires.
    func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        currentDirectory: String? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        onLine: ((String, Bool) -> Void)? = nil,
        onPID: ((pid_t) -> Void)? = nil
    ) throws -> NativeShellResult {

        guard isNativeExecAvailable else {
            throw NativeShellError.execUnavailable(
                "missing \(RuntimePaths.platformEntitlement) entitlement")
        }

        let started = Date()

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw NativeShellError.spawnFailed(errno)
        }
        let needStdin = stdinData != nil
        if needStdin, pipe(&inPipe) != 0 {
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            throw NativeShellError.spawnFailed(errno)
        }

        // Keep the pipe ends out of every other child we spawn later.
        for fd in outPipe + errPipe + (needStdin ? inPipe : []) {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        if needStdin {
            posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        if let cwd = currentDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // New process group: kill(-pid, SIGKILL) then reaches the entire tree,
        // which is what makes the stop button actually stop a `make -j8`.
        var flags: Int16 = POSIX_SPAWN_SETPGROUP
        posix_spawnattr_setpgroup(&attr, 0)
        // Close every inherited descriptor at exec. Without this the child gets
        // a copy of every socket and DB handle the app holds — a file-lock and
        // fd-exhaustion source, and a correctness hazard for anything that
        // walks /dev/fd.
        #if os(iOS)
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        #endif
        posix_spawnattr_setflags(&attr, flags)

        let argv = [executable] + arguments
        guard let argvC = Self.cStringArray(argv),
              let envC = Self.cStringArray(Self.flatten(environment)) else {
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            if needStdin { close(inPipe[0]); close(inPipe[1]) }
            throw NativeShellError.spawnFailed(ENOMEM)
        }
        defer {
            Self.freeCStringArray(argvC, count: argv.count)
            Self.freeCStringArray(envC, count: environment.count)
        }

        var pid: pid_t = 0
        let spawnRet = posix_spawn(&pid, executable, &fileActions, &attr, argvC, envC)

        // Parent side: the child owns the write ends / read end now.
        close(outPipe[1])
        close(errPipe[1])
        if needStdin { close(inPipe[0]) }

        guard spawnRet == 0 else {
            close(outPipe[0]); close(errPipe[0])
            if needStdin { close(inPipe[1]) }
            log.error("posix_spawn \(executable) -> \(String(cString: strerror(spawnRet)))")
            throw NativeShellError.spawnFailed(spawnRet)
        }

        stateLock.lock()
        live[pid] = LiveChild(pid: pid, startedAt: started)
        stateLock.unlock()
        onPID?(pid)

        // Feed stdin then close it, so programs that read to EOF proceed.
        if let data = stdinData {
            let fd = inPipe[1]
            DispatchQueue.global(qos: .userInitiated).async {
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var written = 0
                    while written < raw.count {
                        let n = write(fd, base.advanced(by: written), raw.count - written)
                        if n <= 0 { break }
                        written += n
                    }
                }
                close(fd)
            }
        }

        // Two readers, two threads. A single-threaded select loop would need a
        // restructure for partial lines; threads keep the line assembler dumb.
        let collector = LineCollector(onLine: onLine)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(fd: outPipe[0]) { chunk in collector.append(chunk, isStdErr: false) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(fd: errPipe[0]) { chunk in collector.append(chunk, isStdErr: true) }
            group.leave()
        }

        // Timeout: kill the group, let waitpid below produce the single result.
        var timerWork: DispatchWorkItem?
        var didTimeOut = false
        let timeoutLock = NSLock()
        if let timeout, timeout > 0 {
            let work = DispatchWorkItem {
                timeoutLock.lock(); didTimeOut = true; timeoutLock.unlock()
                Self.signalGroup(pid, SIGKILL)
            }
            timerWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR { continue }
        timerWork?.cancel()

        group.wait()   // both readers hit EOF now that every writer is gone
        collector.flush()

        stateLock.lock()
        live.removeValue(forKey: pid)
        let wasCancelled = cancelledPids.remove(pid) != nil
        stateLock.unlock()

        let duration = Date().timeIntervalSince(started)
        let exitCode: Int32 = (status & 0x7F) == 0 ? ((status >> 8) & 0xFF) : -1
        let termSignal: Int32 = (status & 0x7F) == 0 ? 0 : (status & 0x7F)

        timeoutLock.lock(); let timedOut = didTimeOut; timeoutLock.unlock()

        if wasCancelled && !timedOut {
            throw NativeShellError.cancelled
        }

        return NativeShellResult(
            pid: pid,
            exitCode: exitCode,
            signal: termSignal,
            output: collector.stdout,
            errorOutput: collector.stderr,
            duration: duration,
            timedOut: timedOut
        )
    }

    /// Fire-and-forget shell: `sh -c <command>` against the bundled bash.
    func runShell(
        command: String,
        bashPath: String,
        environment: [String: String],
        currentDirectory: String?,
        timeout: TimeInterval?,
        onLine: ((String, Bool) -> Void)?,
        onPID: ((pid_t) -> Void)?
    ) throws -> NativeShellResult {
        try run(executable: bashPath,
                arguments: ["-lc", command],
                environment: environment,
                currentDirectory: currentDirectory,
                stdinData: nil,
                timeout: timeout,
                onLine: onLine,
                onPID: onPID)
    }

    // MARK: - Kill

    /// Kill a whole process group. SIGTERM first gives `make`/`npm` a chance to
    /// remove their temp state; the SIGKILL that follows is unconditional
    /// because a wedged child must never survive the stop button.
    func killGroup(_ pid: pid_t, grace: TimeInterval = 0.15) {
        stateLock.lock()
        cancelledPids.insert(pid)
        stateLock.unlock()

        Self.signalGroup(pid, SIGTERM)
        if grace > 0 {
            Thread.sleep(forTimeInterval: grace)
        }
        Self.signalGroup(pid, SIGKILL)
    }

    private static func signalGroup(_ pid: pid_t, _ sig: Int32) {
        // Negative pid targets the group we created with SETPGROUP. Fall back to
        // the bare pid for a child that somehow lost its group.
        if kill(-pid, sig) != 0 && kill(pid, sig) != 0 {
            // ESRCH means it already exited — not an error worth logging.
            if errno != ESRCH {
                log.debug("kill(\(pid), \(sig)) errno=\(errno)")
            }
        }
    }

    /// Snapshot for the diagnostics panel: how many children are live right now.
    var liveChildCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return live.count
    }

    // MARK: - Plumbing

    private static func drain(fd: Int32, onChunk: @escaping (UnsafePointer<UInt8>, Int) -> Void) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if n > 0 {
                buf.withUnsafeBufferPointer { p in
                    if let base = p.baseAddress { onChunk(base, n) }
                }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(fd)
    }

    private static func flatten(_ env: [String: String]) -> [String] {
        env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private static func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
        let arr = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() {
            arr[i] = strdup(s)
        }
        arr[strings.count] = nil
        return arr
    }

    private static func freeCStringArray(_ arr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for i in 0..<count { free(arr[i]) }
        arr.deallocate()
    }
}

// MARK: - Line assembly

/// Turns raw chunks into lines, preserving order per stream and flushing a
/// trailing partial line at EOF. `\r\n` is collapsed so progress bars from
/// npm/git do not double-space the transcript.
private final class LineCollector {
    private let lock = NSLock()
    private var outBuf = Data()
    private var errBuf = Data()
    private var outDone = ""
    private var errDone = ""
    private let onLine: ((String, Bool) -> Void)?

    init(onLine: ((String, Bool) -> Void)?) { self.onLine = onLine }

    func append(_ ptr: UnsafePointer<UInt8>, count: Int, isStdErr: Bool) {
        let chunk = Data(bytes: ptr, count: count)
        lock.lock()
        if isStdErr { errBuf.append(chunk) } else { outBuf.append(chunk) }
        let lines = extract(isStdErr: isStdErr)
        lock.unlock()
        for line in lines { onLine?(line, isStdErr) }
    }

    private func extract(isStdErr: Bool) -> [String] {
        var found: [String] = []
        var buffer = isStdErr ? errBuf : outBuf
        let nl = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: nl) {
            var lineData = buffer[buffer.startIndex..<idx]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            if let s = String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1) {
                found.append(s)
            }
            buffer = Data(buffer[buffer.index(after: idx)...])
        }
        if isStdErr { errBuf = buffer } else { outBuf = buffer }
        return found
    }

    func flush() {
        lock.lock()
        var pending: [(String, Bool)] = []
        if !outBuf.isEmpty, let s = String(data: outBuf, encoding: .utf8) ?? String(data: outBuf, encoding: .isoLatin1) {
            pending.append((s, false)); outBuf = Data()
        }
        if !errBuf.isEmpty, let s = String(data: errBuf, encoding: .utf8) ?? String(data: errBuf, encoding: .isoLatin1) {
            pending.append((s, true)); errBuf = Data()
        }
        lock.unlock()
        for (s, isErr) in pending { onLine?(s, isErr) }
    }

    var stdout: String {
        lock.lock(); defer { lock.unlock() }
        return outDone + (String(data: outBuf, encoding: .utf8) ?? "")
    }

    var stderr: String {
        lock.lock(); defer { lock.unlock() }
        return errDone + (String(data: errBuf, encoding: .utf8) ?? "")
    }
}
