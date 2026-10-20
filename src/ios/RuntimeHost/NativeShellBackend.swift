//
//  NativeShellBackend.swift
//  Minis / RuntimeHost
//
//  The seam. Everything the agent's shell tool does today goes through
//  `ISHExecutionCoordinator.execute(sessionId:command:timeout:lineCallback:pidCallback:)`.
//  That actor is the single choke point for mounts, fs_context routing,
//  preemption, the ring buffer and partial-output-on-timeout, which is exactly
//  why the native path plugs in there and nowhere else.
//
//  Differences from the iSH path that this backend owns:
//
//   * No fs_context. iSH needs a routing token to fake per-session mounts
//     inside one emulated kernel. Here a session IS a real directory, so the
//     mount illusion is replaced by `cwd` plus a small set of real symlinks
//     created once per session by `prepareSession`.
//   * No /bin/sh. iSH resolves the guest path; we point at the bundled bash
//     from MT-Agent (`Helpers/bash` -> ca-filetool -> bash.real) because
//     /bin/sh does not exist on iOS and the system bash predates everything
//     the model writes.
//   * Outcomes are near-instant, so the preempt/timeout bookkeeping that iSH
//     needs for a 600-second translated build is mostly dead weight here; the
//     same contract is kept anyway so callers need no special-casing.
//
//  The backend refuses to run — and the coordinator falls back to iSH — when
//  `NativeShellExecutor.isNativeExecAvailable` is false. That is the whole
//  safety story: a stock-signed build behaves exactly like upstream Minis.
//

import Foundation
import os.log

private let log = AppLogger(category: "NativeShell")

struct NativeShellOutcome {
    let output: String
    let exitCode: Int
    let truncated: Bool

    var ishResult: ISHCommandResult {
        ISHCommandResult(output: output, exitCode: exitCode)
    }
}

actor NativeShellBackend {

    static let shared = NativeShellBackend()

    private var paths: RuntimePaths
    private var installer: RuntimeInstaller
    private var preparedSessions = Set<String>()
    private var liveByPid: [String: Set<Int32>] = [:]

    /// Hard cap on what a single command may hand back to the model. Mirrors the
    /// coordinator's own mirror limit so the native path does not become the
    /// one place a runaway `yes` can blow up the transcript.
    private let maxOutputChars = 256_000

    private init() {
        let resolved = RuntimePaths.resolve()
        self.paths = resolved
        self.installer = RuntimeInstaller(paths: resolved)
    }

    // MARK: - Availability

    /// True when the device can exec real binaries AND at least the shell
    /// helpers are present. Both halves are required: entitlements without
    /// helpers gives EPERM, helpers without entitlements gives EPERM.
    var isAvailable: Bool {
        NativeShellExecutor.shared.isNativeExecAvailable && bashPath != nil
    }

    var bashPath: String? {
        for candidate in ["Helpers/bash", "Helpers/bash.real"] {
            let url = Bundle.main.bundleURL.appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
        }
        return nil
    }

    /// Human-readable reason the native path is off, for the diagnostics panel.
    var unavailableReason: String {
        if !NativeShellExecutor.shared.isNativeExecAvailable {
            return "platform-application entitlement missing (stock signature)"
        }
        if bashPath == nil {
            return "Helpers/bash not present in the bundle"
        }
        return "available"
    }

    // MARK: - Session preparation

    /// Creates the real directories the agent's paths map onto.
    ///
    /// Upstream Minis exposes `/var/minis/{memory,skills,shared,external}` and a
    /// per-session bucket via iSH's fakefs hook. Native mode cannot intercept
    /// path translation, so the same layout is built once per session as real
    /// symlinks into the app's own container — same paths visible to the model,
    /// same files, no emulation.
    func prepareSession(sessionId: String, hostPaths: [String: String]) throws -> String {
        let fm = FileManager.default
        let root = paths.root.appendingPathComponent("sessions/\(sanitize(sessionId))", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // /var/minis/... does not exist on iOS and cannot be created at the
        // filesystem root without no-container; with it, we can. Fall back to a
        // workspace-local shim if the root is read-only.
        let minisRoot = URL(fileURLWithPath: "/var/minis", isDirectory: true)
        var useSystemRoot = true
        do {
            try fm.createDirectory(at: minisRoot, withIntermediateDirectories: true)
        } catch {
            useSystemRoot = false
        }

        for (logical, host) in hostPaths {
            // host is a filesystem path, not a URL string: URL(string:) returns
            // nil for any path containing a space, and silently dropping the
            // mount would be worse than failing.
            guard logical.hasPrefix("/") else { continue }
            let hostPath = host.hasPrefix("file://")
                ? (URL(string: host)?.path ?? String(host.dropFirst(7)))
                : host
            let link = useSystemRoot
                ? URL(fileURLWithPath: logical)
                : root.appendingPathComponent("mnt" + logical)
            let parent = link.deletingLastPathComponent()

            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: hostPath)
        }

        preparedSessions.insert(sessionId)
        return root.path
    }

    private func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    // MARK: - Execute

    /// Contract-compatible with `ISHExecutionCoordinator.execute`, so the patch
    /// at the call site is a single guard + one branch.
    func execute(
        sessionId: String,
        command: String,
        timeout: TimeInterval?,
        lineCallback: @escaping (String) -> Void,
        pidCallback: @escaping (Int32) -> Void
    ) async throws -> NativeShellOutcome {

        guard isAvailable, let bash = bashPath else {
            throw NativeShellError.execUnavailable(unavailableReason)
        }

        let env = await installer.shellEnvironment()
        let sessionRoot = paths.root.appendingPathComponent("sessions/\(sanitize(sessionId))")
        let cwd = FileManager.default.fileExists(atPath: sessionRoot.path) ? sessionRoot.path : paths.homeDir.path

        let mirror = StringBuilder(limit: maxOutputChars)

        let result: NativeShellResult
        do {
            result = try NativeShellExecutor.shared.run(
                executable: bash,
                arguments: ["-lc", command],
                environment: env,
                currentDirectory: cwd,
                stdinData: nil,
                timeout: timeout ?? 600,
                onLine: { line, isStdErr in
                    // The agent's transcript is stdout-only upstream; stderr is
                    // still merged into the mirror so a failing build explains
                    // itself, and prefixed so the model can tell them apart.
                    lineCallback(isStdErr ? "stderr: \(line)" : line)
                    mirror.append(line + "\n")
                },
                onPID: { pid in
                    pidCallback(Int32(pid))
                    Task { await self.record(pid: pid, sessionId: sessionId) }
                })

        } catch NativeShellError.cancelled {
            return NativeShellOutcome(output: mirror.value, exitCode: 130, truncated: mirror.truncated)
        }

        forget(sessionId: sessionId)

        if result.timedOut {
            let partial = mirror.value
            throw NativeShellError.timedOut(partialOutput: partial,
                                            err: result.errorOutput,
                                            seconds: timeout ?? 600)
        }

        return NativeShellOutcome(output: mirror.value,
                                  exitCode: Int(result.exitCode),
                                  truncated: mirror.truncated)
    }

    // MARK: - Stop button

    /// Kills every child this session started. Called by the coordinator's stop
    /// path in place of `killProcessGroup`.
    func killAll(sessionId: String) {
        let pids = liveByPid[sessionId] ?? []
        for pid in pids {
            NativeShellExecutor.shared.killGroup(pid)
        }
        liveByPid.removeValue(forKey: sessionId)
    }

    private func record(pid: Int32, sessionId: String) {
        liveByPid[sessionId, default: []].insert(pid)
    }

    private func forget(sessionId: String) {
        liveByPid.removeValue(forKey: sessionId)
    }
}

// MARK: - Output mirror

/// Bounded accumulator. `truncated` lets the caller tell the model that the
/// tail was cut instead of silently returning a short result.
private final class StringBuilder {
    let limit: Int
    private var buffer = ""
    private let lock = NSLock()
    private(set) var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        guard buffer.count + s.count <= limit else {
            if !truncated {
                let room = max(0, limit - buffer.count)
                if room > 0 { buffer += String(s.prefix(room)) }
                truncated = true
            }
            return
        }
        buffer += s
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
