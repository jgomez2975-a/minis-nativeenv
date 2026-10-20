//
//  RuntimeEnvironmentBrief.swift
//  Minis / RuntimeHost
//
//  What the model is told about the shell it is about to use.
//
//  Upstream's shell tool says, unconditionally:
//
//      "Execute a command in an isolated Linux process (iSH/Alpine Linux).
//       The command runs via /bin/sh -c ..."
//
//  Three false statements once the native backend is active: it is not iSH, it
//  is not Alpine, and /bin/sh does not exist on iOS at all — commands run
//  through the bundled bash. A model told it is in Alpine will reach for apk,
//  for /bin/sh, for /etc/passwd, and spend its turns debugging an environment
//  that was described wrongly. The description has to describe the shell that
//  will actually run the command.
//
//  The installed-toolchain list comes from `environment.txt`, written by the
//  installer after every change. It is read synchronously because the tool
//  schema is built synchronously, and cached because it is consulted on every
//  turn.
//

import Foundation

enum RuntimeEnvironmentBrief {

    private static let lock = NSLock()
    private static var cache: (stamp: Date?, body: String)?

    /// One line per installed runtime, or empty when nothing is installed.
    static var installedSummary: String {
        let file = RuntimePaths.resolve().root.appendingPathComponent("environment.txt")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date

        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.stamp == stamp { return cache.body }

        let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        cache = (stamp, body)
        return body
    }

    static var nativeExecAvailable: Bool {
        NativeShellExecutor.shared.isNativeExecAvailable
    }

    /// The `shell_execute` description. Long on purpose: everything in it is a
    /// fact the model would otherwise have to discover by failing.
    static var shellToolDescription: String {
        var text: String

        if nativeExecAvailable {
            text = """
            Execute a command in this device's native shell — real arm64 processes, \
            not an emulator, with the device filesystem mounted normally.

            There is no /bin/sh and no `apk`/`apt` on iOS. Commands run through the \
            bundled GNU bash (`"bash" -lc <command>`), so POSIX shell, pipelines, \
            redirections, `&&`, globbing and `$()` all behave as expected; anything \
            you would reach for from coreutils must come from an installed toolchain \
            (see below) or fail. Each invocation is a fresh process — no shared \
            session, no persistent `cd`, no exported variables between calls.

            Working directory defaults to the current session's workspace. Long builds \
            are fine: default timeout is 15 minutes.
            """
        } else {
            text = """
            Execute a command in an isolated Linux process (iSH/Alpine Linux). The \
            command runs via /bin/sh -c with stdout and stderr captured separately via \
            pipes. Each invocation spawns a fresh process — there is no shared terminal \
            session. Default timeout is 15 minutes.
            """
        }

        let summary = installedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            text += "\n\nInstalled toolchains (already on PATH):\n" + summary
        } else if nativeExecAvailable {
            text += "\n\nNo toolchain is installed yet — only bash and its builtins are "
                + "available. Ask the user to install them from Settings › Agent Runtime › "
                + "开发能力."
        }

        return text
    }
}
