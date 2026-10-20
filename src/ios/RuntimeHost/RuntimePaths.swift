//
//  RuntimePaths.swift
//  Minis / RuntimeHost
//
//  Where the native tool environment lives on disk.
//
//  Two roots exist and the order matters:
//
//   1. sharedRoot  /var/mobile/Library/MinisRuntime
//      The device-wide root. Only reachable because the app carries
//      com.apple.private.security.no-sandbox / no-container. MT-Agent
//      (wiki.qaq.codexapp) installs its runtimes under the same layout, so a
//      device that already ran MT-Agent gets every toolchain for free instead
//      of re-downloading 400 MB. First writer wins; whoever installs second
//      just probes and adopts.
//
//   2. containerRoot  <home>/Library/Application Support/MinisRuntime
//      The fallback. Used when the shared root is not writable (no
//      platform-application entitlement, or a sandboxed install).
//
//  Nothing here creates directories at init time; RuntimeInstaller does that
//  so a failed bootstrap leaves no half-built tree behind.
//

import Foundation

struct RuntimePaths {

    /// Entitlement that unlocks the shared root and process-exec.
    static let platformEntitlement = "platform-application"

    let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: - Candidate roots

    /// Device-wide root. `/var/mobile/Library` is writable for a
    /// platform-application binary; for anything else this path resolves but
    /// every write fails with EPERM, which `isUsable` detects.
    static var sharedRoot: URL {
        URL(fileURLWithPath: "/var/mobile/Library/MinisRuntime", isDirectory: true)
    }

    /// Per-install root, always writable inside our own container.
    static var containerRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("MinisRuntime", isDirectory: true)
    }

    /// Pick a root by actually writing to it. Cheap, idempotent, called once.
    static func resolve() -> RuntimePaths {
        let fm = FileManager.default
        for candidate in [sharedRoot, containerRoot] {
            do {
                try fm.createDirectory(at: candidate.appendingPathComponent(".probe"),
                                       withIntermediateDirectories: true)
                try fm.removeItem(at: candidate.appendingPathComponent(".probe"))
                return RuntimePaths(root: candidate)
            } catch {
                continue
            }
        }
        // Neither worked — hand back the container root anyway; the installer
        // will surface the real error with a path attached.
        return RuntimePaths(root: containerRoot)
    }

    var isShared: Bool { root.standardizedFileURL == Self.sharedRoot.standardizedFileURL }

    // MARK: - Layout

    /// One directory per runtime key, exactly as named in runtime-manifest.json
    /// (`core_tools`, `node`, `python`, `theos`, …). Inside each:
    ///   <key>/<revision>/            unpacked payload
    ///   <key>/current -> <revision>  symlink flipped atomically on update
    var runtimesDir: URL { root.appendingPathComponent("runtimes", isDirectory: true) }

    func runtimeDir(_ key: String) -> URL { runtimesDir.appendingPathComponent(key, isDirectory: true) }

    func runtimeVersionDir(_ key: String, revision: String) -> URL {
        runtimeDir(key).appendingPathComponent(revision, isDirectory: true)
    }

    func runtimeCurrentLink(_ key: String) -> URL {
        runtimeDir(key).appendingPathComponent("current")
    }

    /// Resolved payload root for an installed runtime, or nil when absent.
    func installedRuntimeRoot(_ key: String) -> URL? {
        let link = runtimeCurrentLink(key)
        let resolved = link.resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// Download cache — hashed archives are kept so a retried install does not
    /// re-fetch 220 MB of Theos.
    var cacheDir: URL { root.appendingPathComponent("cache", isDirectory: true) }

    /// Scratch space for in-flight extraction. Wiped on every install start.
    var stagingDir: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// Device-wide bin shim directory. Prepended to PATH so `bash`, `rg`, `git`
    /// resolve without the model having to know absolute paths.
    var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }

    /// Persistent PATH entries contributed by runtimes (`install.persistent_path_entries`),
    /// e.g. the Node global prefix. Stored as a newline-delimited manifest so a
    /// shell spawned before a runtime finished installing still gets a coherent PATH.
    var pathManifestURL: URL { root.appendingPathComponent("path-entries.txt") }

    /// Per-runtime install bookkeeping: revision, install date, probe result.
    var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }

    func stateURL(_ key: String) -> URL { stateDir.appendingPathComponent("\(key).json") }

    /// HOME for spawned shells. Kept out of the app container on purpose: a
    /// jailbroken/TrollStore user expects `~` to be the same place every other
    /// root-run tool uses, and `.npmrc`/`.gitconfig` land there once.
    var homeDir: URL {
        isShared
            ? URL(fileURLWithPath: "/var/mobile", isDirectory: true)
            : Self.containerRoot.appendingPathComponent("home", isDirectory: true)
    }

    /// The app container's `Library` directory.
    ///
    /// Some runtimes declare path entries relative to *this* rather than to the
    /// runtime root — node's `Library/Application Support/CodexApp/Node/prefix/bin`
    /// is where `npm i -g` puts global binaries, and resolving it against the
    /// runtime root would point at a directory nothing ever writes to.
    var containerLibrary: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    var tmpDir: URL { root.appendingPathComponent("tmp", isDirectory: true) }
}
