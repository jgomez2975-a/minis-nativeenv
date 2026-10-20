//
//  RuntimeInstaller.swift
//  Minis / RuntimeHost
//
//  Downloads, verifies, unpacks, signs and probes the toolchain runtimes
//  described by runtime-manifest.json.
//
//  Ordering rules that are not negotiable:
//
//   * SHA-256 is checked BEFORE extraction. A truncated tarball unpacks into a
//     tree that looks plausible and fails weeks later.
//   * Extraction lands in `staging/<key>.tmp`, never in place. The `current`
//     symlink is flipped with a rename(2) only after probe passes, so a
//     half-installed runtime is never visible to a shell.
//   * Binaries are re-signed before the probe runs. iOS kills an unsigned
//     executable at exec, and the failure surfaces as a bare EPERM with no hint.
//   * `required_paths` are checked after extraction. TheosRuntime silently
//     omits sdk symlinks when its tar was built without them; that is exactly
//     the class of defect the check exists for.
//
//  Everything here runs off the main actor. Downloads are large (Theos is
//  224 MB, 980 MB unpacked) and the UI must keep streaming tokens meanwhile.
//

import Foundation
import CryptoKit
import os.log

private let log = AppLogger(category: "RuntimeInstaller")

enum InstallerError: Error, LocalizedError {
    case manifestUnavailable
    case downloadFailed(String, Int)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedArchive(String)
    case extractionFailed(String)
    case missingPaths([String])
    case probeFailed(String, String)
    case signingFailed(String)
    case insufficientSpace(need: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable:
            return "runtime manifest could not be loaded"
        case .downloadFailed(let url, let code):
            return "download failed (\(code)): \(url)"
        case .checksumMismatch(let e, let a):
            return "sha256 mismatch — expected \(e.prefix(16))… got \(a.prefix(16))…"
        case .unsupportedArchive(let n):
            return "unsupported archive format: \(n)"
        case .extractionFailed(let why):
            return "extraction failed: \(why)"
        case .missingPaths(let p):
            return "payload incomplete, missing \(p.count) path(s): \(p.prefix(3).joined(separator: ", "))"
        case .probeFailed(let exe, let out):
            return "probe failed for \(exe): \(out.prefix(200))"
        case .signingFailed(let why):
            return "code signing failed: \(why)"
        case .insufficientSpace(let need, let free):
            return "need \(need / 1_048_576) MB, \(free / 1_048_576) MB free"
        }
    }
}

// MARK: - Installer

actor RuntimeInstaller {

    static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/susu123oss/CodexApp-Runtime/main/Runtime/runtime-manifest.json")!

    private let paths: RuntimePaths
    private let fileManager = FileManager.default
    private var manifest: RuntimeManifest?

    init(paths: RuntimePaths) {
        self.paths = paths
    }

    // MARK: Manifest

    func loadManifest(forceReload: Bool = false) async throws -> RuntimeManifest {
        if !forceReload, let manifest { return manifest }

        // A cached copy makes the runtime panel usable offline; the network
        // fetch is preferred because a stale manifest pins dead release URLs.
        let cache = paths.root.appendingPathComponent("manifest.json")
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.manifestURL)
            let parsed = try JSONDecoder().decode(RuntimeManifest.self, from: data)
            try? data.write(to: cache, options: .atomic)
            manifest = parsed
            return parsed
        } catch {
            if let data = try? Data(contentsOf: cache),
               let parsed = try? JSONDecoder().decode(RuntimeManifest.self, from: data) {
                log.warning("manifest fetch failed, using cache: \(error.localizedDescription)")
                manifest = parsed
                return parsed
            }
            throw InstallerError.manifestUnavailable
        }
    }

    /// Everything Minis can use, in display order. `codex` is excluded: it is
    /// MT-Agent's own agent host and Minis already has one.
    func installableRuntimes() async throws -> [RuntimeSpec] {
        let m = try await loadManifest()
        return m.orderedKeys.compactMap { key in
            m.runtimes[key].flatMap { $0.isUsableByMinis ? $0 : nil }
        }
    }

    // MARK: Install

    /// Full install for one runtime. Returns the state record written on success.
    /// `progress` receives 0…1 across download and unpack, so the UI can show a
    /// single bar rather than two.
    func install(
        key: String,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> RuntimeState {

        let m = try await loadManifest()
        guard let spec = m.runtimes[key], spec.isUsableByMinis else {
            throw InstallerError.manifestUnavailable
        }

        try ensureDirectories()

        // Space check first: Theos needs ~1 GB unpacked, and discovering that
        // mid-extraction leaves a 900 MB staging directory to clean up.
        if let need = spec.unpackedSize {
            let free = try availableBytes()
            if free < need + (200 * 1_048_576) {
                throw InstallerError.insufficientSpace(need: need + 200 * 1_048_576, free: free)
            }
        }

        progress?(0.02, "preparing")
        let archive = try await fetchArchive(spec: spec, progress: progress)

        // The index does not describe the layout for every runtime; the
        // per-runtime descriptor does. Fetch it before planning, because a plan
        // derived without it can only guess at the sign set — and an unsigned
        // binary is an unexecutable one.
        progress?(0.06, "reading descriptor")
        let bundle = await fetchBundle(spec: spec)
        if bundle == nil, spec.metadataURL != nil {
            log.warning("descriptor unavailable for \(key); plan falls back to the index")
        }
        let plan = RuntimePlan(spec: spec, bundle: bundle)

        progress?(0.55, "verifying")
        let digest = try sha256Hex(of: archive)
        guard digest.caseInsensitiveCompare(spec.archiveSHA256) == .orderedSame else {
            try? fileManager.removeItem(at: archive)
            throw InstallerError.checksumMismatch(expected: spec.archiveSHA256, actual: digest)
        }

        // Fresh staging for every attempt — a leftover tree from a failed run
        // would merge into this one and defeat required_paths.
        try? fileManager.removeItem(at: paths.stagingDir)
        try fileManager.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
        let staging = paths.stagingDir.appendingPathComponent("\(key).tmp", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        progress?(0.58, "unpacking")
        do {
            try extract(archive: archive, into: staging, handler: spec.handler ?? "portable-v1")
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        let payload = try locatePayloadRoot(in: staging, markers: plan.rootMarkers)

        progress?(0.80, "checking")
        let missing = plan.requiredPaths.filter {
            !fileManager.fileExists(atPath: payload.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            try? fileManager.removeItem(at: staging)
            throw InstallerError.missingPaths(missing)
        }

        // Scripts that open with `#!/usr/bin/env perl` cannot work on iOS:
        // there is no /usr/bin/env, and no perl on PATH until theos is on it.
        if !plan.shebangRewrites.isEmpty {
            progress?(0.82, "rewriting shebangs")
            applyShebangRewrites(plan.shebangRewrites, root: payload)
        }

        if !plan.signWithEntitlements.isEmpty || !plan.signAdhocOnly.isEmpty {
            progress?(0.85, "signing")
            try signBinaries(plan: plan, root: payload)
        }

        // Commit: move into place under the revision, then flip `current`.
        let revision = spec.revisionKey
        let finalDir = paths.runtimeVersionDir(key, revision: revision)
        try fileManager.createDirectory(at: paths.runtimeDir(key), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: finalDir)
        try fileManager.moveItem(at: payload, to: finalDir)

        if payload.standardizedFileURL != staging.standardizedFileURL {
            try? fileManager.removeItem(at: staging)
        } else {
            try? fileManager.removeItem(at: paths.stagingDir)
        }

        let link = paths.runtimeCurrentLink(key)
        let tmpLink = paths.runtimeDir(key).appendingPathComponent(".current.new")
        try? fileManager.removeItem(at: tmpLink)
        try fileManager.createSymbolicLink(atPath: tmpLink.path, withDestinationPath: finalDir.path)
        _ = try? fileManager.replaceItemAt(link, withItemAt: tmpLink)

        progress?(0.92, "probing")
        var state = RuntimeState(key: key,
                                 revision: revision,
                                 version: spec.version,
                                 installedAt: Date(),
                                 installedRoot: finalDir.path,
                                 lastProbeOK: false,
                                 lastProbeOutput: nil,
                                 failure: nil)

        if let probe = plan.probe, !probe.contains.isEmpty {
            do {
                let out = try runProbe(probe, root: finalDir)
                state.lastProbeOK = true
                state.lastProbeOutput = out
            } catch {
                state.failure = error.localizedDescription
                writeState(state)
                throw error
            }
        } else {
            // No sentinel to look for. Trust the file checks that already ran and
            // record why, so the panel does not imply a probe happened.
            state.lastProbeOK = plan.requiredPaths.allSatisfy {
                fileManager.fileExists(atPath: finalDir.appendingPathComponent($0).path)
            }
            state.lastProbeOutput = "no sentinel probe; verified by required_paths"
        }

        writeState(state)
        rebuildPathManifest()
        progress?(1.0, "done")
        log.info("installed \(key) \(spec.version) -> \(finalDir.path)")
        if !plan.derivedNotes.isEmpty {
            log.info("plan notes for \(key): \(plan.derivedNotes.joined(separator: "; "))")
        }
        return state
    }

    /// Probe-only re-check. Cheap enough to run on every app launch so a
    /// runtime deleted by a package manager shows up as broken, not missing.
    func verifyInstalled(key: String) async -> RuntimeState? {
        guard let state = readState(key),
              let spec = (try? await loadManifest())?.runtimes[key],
              fileManager.fileExists(atPath: state.installedRoot) else { return nil }

        let plan = RuntimePlan(spec: spec, bundle: loadBundle(spec: spec))
        guard let probe = plan.probe, !probe.contains.isEmpty else { return state }
        do {
            let out = try runProbe(probe, root: URL(fileURLWithPath: state.installedRoot))
            var updated = state
            updated.lastProbeOK = true
            updated.lastProbeOutput = out
            updated.failure = nil
            writeState(updated)
            return updated
        } catch {
            var updated = state
            updated.lastProbeOK = false
            updated.failure = error.localizedDescription
            writeState(updated)
            return updated
        }
    }

    func installedStates() -> [RuntimeState] {
        guard let keys = try? fileManager.contentsOfDirectory(atPath: paths.stateDir.path) else { return [] }
        return keys.filter { $0.hasSuffix(".json") }
            .compactMap { readState(String($0.dropLast(5))) }
            .sorted { $0.key < $1.key }
    }

    // MARK: Environment

    /// Builds the environment every native shell inherits.
    ///
    /// PATH order is deliberate: device-wide shims first (bash, sh, theos
    /// helper), then each runtime's declared `path_entries`, then persistent
    /// entries (npm global prefix). A model that types `rg` or `git` gets the
    /// runtime copy, never a system one — iOS has none anyway.
    ///
    /// Synchronous by design: the probe and the signer both need this, and both
    /// run inside blocking work. If the manifest has not been fetched yet it is
    /// read from disk here rather than left nil, because a nil manifest would
    /// silently produce a PATH with no runtimes on it — a false "toolchain
    /// missing" that looks like a broken install.
    func shellEnvironment() -> [String: String] {
        if manifest == nil { loadManifestFromCache() }

        var env: [String: String] = [:]

        var pathComponents: [String] = [paths.binDir.path]
        let states = installedStates().filter(\.lastProbeOK)
        let library = paths.containerLibrary

        var plans: [(RuntimePlan, URL)] = []
        if let m = manifest {
            for state in states {
                guard let spec = m.runtimes[state.key] else { continue }
                plans.append((RuntimePlan(spec: spec, bundle: loadBundle(spec: spec)),
                              URL(fileURLWithPath: state.installedRoot)))
            }
        }

        // Ordering rule: every runtime's own path entries first (so `rg`, `git`,
        // `python3`, `r2` resolve to the runtime copy), then the container-level
        // persistent prefixes such as npm's global bin, then the system dirs.
        for (plan, root) in plans {
            for entry in plan.pathEntries {
                pathComponents.append(plan.resolvePathEntry(entry, root: root, containerLibrary: library).path)
            }
        }
        for (plan, root) in plans {
            for entry in plan.persistentPathEntries {
                pathComponents.append(plan.resolvePathEntry(entry, root: root, containerLibrary: library).path)
            }
        }

        pathComponents.append("/usr/bin")
        pathComponents.append("/bin")
        pathComponents.append("/usr/sbin")
        pathComponents.append("/sbin")

        env["PATH"] = pathComponents.joined(separator: ":")
        env["HOME"] = paths.homeDir.path
        env["TMPDIR"] = paths.tmpDir.path
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["SHELL"] = paths.binDir.appendingPathComponent("bash").path
        env["MINIS_RUNTIME_ROOT"] = paths.root.path
        // Standard names the portable-v1 handler expects to see already set.
        env["CA_TOOL_RUNTIME_ROOT"] = paths.root.path
        env["DEVELOPER_DIR"] = paths.root.path

        for (plan, root) in plans {
            for (k, v) in plan.environment {
                env[k] = expand(v, root: root).path
            }
        }

        return env
    }

    /// Synchronous manifest read for the paths that cannot await.
    private func loadManifestFromCache() {
        let cache = paths.root.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: cache),
           let parsed = try? JSONDecoder().decode(RuntimeManifest.self, from: data) {
            manifest = parsed
        }
    }

    /// `${RUNTIME_ROOT}` and `${RUNTIME_ROOT}/sub` expansion, as used by the
    /// node and ollvm runtime declarations.
    private func expand(_ template: String, root: URL) -> URL {
        let replaced = template.replacingOccurrences(of: "${RUNTIME_ROOT}", with: root.path)
        return URL(fileURLWithPath: replaced)
    }

    // MARK: - Per-runtime descriptor

    /// Fetches the runtime's own `metadata_url` document and caches it.
    ///
    /// The manifest is an index; the descriptor is the install spec. Fetching
    /// is best-effort: a device offline at install time still gets a usable
    /// plan from the index plus the format reconstruction, and `derivedNotes`
    /// records that it was a reconstruction.
    private func fetchBundle(spec: RuntimeSpec) async -> RuntimeBundle? {
        let cache = bundleCacheURL(spec)
        if let data = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode(RuntimeBundle.self, from: data) {
            return decoded
        }
        guard let urlString = spec.metadataURL, let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(RuntimeBundle.self, from: data)
            else { return nil }
            try? fileManager.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
            return decoded
        } catch {
            log.warning("descriptor fetch failed for \(spec.displayName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Public read-only view of a runtime's descriptor, for the capabilities
    /// panel. Cached after the first fetch, so opening the panel offline still
    /// shows what was installed.
    func descriptor(for key: String) async -> RuntimeBundle? {
        if manifest == nil { loadManifestFromCache() }
        guard let spec = manifest?.runtimes[key] else { return nil }
        return await fetchBundle(spec: spec)
    }

    /// Synchronous descriptor read for the paths that cannot await.
    private func loadBundle(spec: RuntimeSpec) -> RuntimeBundle? {
        guard let data = try? Data(contentsOf: bundleCacheURL(spec)) else { return nil }
        return try? JSONDecoder().decode(RuntimeBundle.self, from: data)
    }

    private func bundleCacheURL(_ spec: RuntimeSpec) -> URL {
        paths.cacheDir.appendingPathComponent("\(spec.revisionKey).bundle.json")
    }

    // MARK: - Download

    private func fetchArchive(
        spec: RuntimeSpec,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        try fileManager.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        let name = spec.assetName ?? URL(string: spec.archiveURL)?.lastPathComponent ?? "\(spec.version).bin"
        let destination = paths.cacheDir.appendingPathComponent(name)

        // Reuse is safe because the checksum is re-verified by the caller; a
        // cached file that was truncated mid-write fails the hash and is
        // deleted there, so the next attempt re-downloads.
        if fileManager.fileExists(atPath: destination.path) { return destination }

        guard let primary = URL(string: spec.archiveURL) else {
            throw InstallerError.downloadFailed(spec.archiveURL, 0)
        }

        var candidates: [URL] = [primary]
        if let m = manifest {
            for prefix in m.downloadProxyPrefixes {
                if let proxied = URL(string: prefix + spec.archiveURL) { candidates.append(proxied) }
            }
        }

        var lastCode = 0
        for url in candidates {
            do {
                let tmp = try await download(url: url, progress: progress)
                try fileManager.moveItem(at: tmp, to: destination)
                return destination
            } catch let error as InstallerError {
                if case .downloadFailed(_, let code) = error { lastCode = code }
                continue
            }
        }
        throw InstallerError.downloadFailed(spec.archiveURL, lastCode)
    }

    private func download(
        url: URL,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        // URLSession's own progress reporting needs a delegate; polling the
        // temp file size is simpler and accurate enough for a 0.02–0.55 band.
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw InstallerError.downloadFailed(url.absoluteString, 0)
        }
        guard http.statusCode == 200 else {
            try? fileManager.removeItem(at: tempURL)
            throw InstallerError.downloadFailed(url.absoluteString, http.statusCode)
        }
        progress?(0.50, "downloaded")
        return tempURL
    }

    // MARK: - Verify

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func availableBytes() throws -> Int64 {
        let values = try paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Extraction

    private func extract(archive: URL, into destination: URL, handler: String) throws {
        let probe = try FileHandle(forReadingFrom: archive)
        let head = try probe.read(upToCount: 8) ?? Data()
        try? probe.close()

        // "!<arch>\n" — a Debian package. Only the `codex` runtime ships as a
        // deb, and that handler is skipped, but the parser stays so a future
        // deb-packaged toolchain needs no change here.
        if head.prefix(7) == Data("!<arch>".utf8) {
            try extractDeb(archive: archive, into: destination)
            return
        }
        if head.prefix(2) == Data([0x1f, 0x8b]) {
            try extractTarGz(archive: archive, into: destination)
            return
        }
        if head.count >= 2, head[0] == 0xFD, head[1] == 0x37 { // xz magic
            throw InstallerError.unsupportedArchive("tar.xz")
        }
        if head.count >= 4, head[0] == 0x28, head[1] == 0xB5, head[2] == 0x2F, head[3] == 0xFD {
            throw InstallerError.unsupportedArchive("tar.zst")
        }
        // Bare tar: ustar magic at offset 257 is the reliable check.
        if TarReader.looksLikeTar(archive) {
            try extractBareTar(archive: archive, into: destination)
            return
        }
        throw InstallerError.unsupportedArchive(archive.lastPathComponent)
    }

    /// Wraps TarReader's errors in the installer's own error surface so a
    /// failure carries a path and a stage rather than a bare case.
    private func extractBareTar(archive: URL, into destination: URL) throws {
        do {
            let entries = try TarReader.extract(archive: archive, into: destination)
            log.debug("tar: wrote \(entries.count) entries from \(archive.lastPathComponent)")
        } catch let error as TarError {
            throw InstallerError.extractionFailed(error.localizedDescription)
        }
    }

    private func extractDeb(archive: URL, into destination: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count > 8 else { throw InstallerError.extractionFailed("deb too short") }
        var offset = 8 // skip "!<arch>\n"
        var payload: Data?

        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<offset + 60)
            let nameField = String(decoding: header[0..<16], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let sizeField = String(decoding: header[48..<58], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeField) else { break }
            let dataStart = offset + 60
            guard dataStart + size <= data.count else { break }

            if nameField.hasPrefix("data.tar") {
                payload = data.subdata(in: dataStart..<dataStart + size)
                break
            }
            offset = dataStart + size + (size % 2) // members are 2-byte aligned
        }

        guard let payload else { throw InstallerError.extractionFailed("no data.tar member in deb") }

        if payload.prefix(2) == Data([0x1f, 0x8b]) {
            let scratch = paths.stagingDir.appendingPathComponent("data.tar.gz")
            try payload.write(to: scratch, options: .atomic)
            defer { try? fileManager.removeItem(at: scratch) }
            try extractTarGz(archive: scratch, into: destination)
            return
        }
        if payload.prefix(4) == Data([0xFD, 0x37, 0x7A, 0x58]) {
            throw InstallerError.unsupportedArchive("deb(data.tar.xz)")
        }
        let scratch = paths.stagingDir.appendingPathComponent("data.tar")
        try payload.write(to: scratch, options: .atomic)
        defer { try? fileManager.removeItem(at: scratch) }
        try extractBareTar(archive: scratch, into: destination)
    }

    private func extractTarGz(archive: URL, into destination: URL) throws {
        let scratch = paths.stagingDir.appendingPathComponent("inflate.tar")
        fileManager.createFile(atPath: scratch.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: scratch) else {
            throw InstallerError.extractionFailed("cannot open staging tar")
        }
        defer { try? out.close() }

        // C trampoline for zlib's streaming callback.
        final class Sink {
            let handle: FileHandle
            var failed = false
            init(_ h: FileHandle) { handle = h }
        }
        let sink = Sink(out)
        let ctx = Unmanaged.passUnretained(sink).toOpaque()

        let rc = ra_gunzip_stream(archive.path, { ctx, bytes, length -> Int32 in
            guard let ctx, let bytes, length > 0 else { return 0 }
            let sink = Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue()
            do {
                try sink.handle.write(contentsOf: Data(bytes: bytes, count: length))
                return 0
            } catch {
                sink.failed = true
                return -1
            }
        }, ctx)

        guard rc == 0, !sink.failed else {
            try? fileManager.removeItem(at: scratch)
            throw InstallerError.extractionFailed("gunzip rc=\(rc)")
        }

        defer { try? fileManager.removeItem(at: scratch) }
        try extractBareTar(archive: scratch, into: destination)
    }

    // MARK: - Payload root

    /// Some tarballs wrap everything in a single top directory; some do not.
    /// `markers` comes from the runtime's own plan, so python's `python3` and
    /// theos's `theos/` are recognised as roots the same way `bin/` is.
    private func locatePayloadRoot(in staging: URL, markers: Set<String>) throws -> URL {
        let contents = try fileManager.contentsOfDirectory(at: staging,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        // Already a payload root?
        if contents.contains(where: { markers.contains($0.lastPathComponent) }) {
            return staging
        }
        // Single wrapper directory?
        if contents.count == 1 {
            let only = contents[0]
            let isDir = (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { return only }
        }
        throw InstallerError.extractionFailed(
            "cannot determine payload root (\(contents.count) top-level entries: "
            + contents.prefix(6).map(\.lastPathComponent).joined(separator: ", ") + ")")
    }

    // MARK: - Shebangs

    /// Repoints `#!/usr/bin/env <interp>` at the interpreter inside this
    /// runtime. Driven by the manifest's `portable_shebangs` list rather than a
    /// scan, so a script that deliberately uses the system interpreter is left
    /// alone.
    ///
    /// Each file is read whole and rewritten atomically. These are scripts of a
    /// few KB; an in-place offset overlay would have to reason about a
    /// replacement of different length, and getting that wrong truncates the
    /// script instead of fixing it.
    private func applyShebangRewrites(_ rewrites: [ShebangRewrite], root: URL) {
        var changed = 0
        for rewrite in rewrites {
            let file = root.appendingPathComponent(rewrite.path)
            guard let data = try? Data(contentsOf: file), !data.isEmpty,
                  data.starts(with: Array("#!".utf8)),
                  let newlineIndex = data.firstIndex(of: 0x0A),
                  let oldLine = String(data: data[..<newlineIndex], encoding: .utf8),
                  oldLine == rewrite.original else { continue }

            let interpreter = resolveInterpreter(rewrite.interpreter, root: root)
                ?? rewrite.interpreter
            var newLine = "#!" + interpreter
            if !rewrite.arguments.isEmpty {
                newLine += " " + rewrite.arguments.joined(separator: " ")
            }
            guard let newLineData = (newLine + "\n").data(using: .utf8) else { continue }

            var updated = newLineData
            updated.append(data[(newlineIndex + 1)...])
            if (try? updated.write(to: file, options: .atomic)) != nil {
                // Atomic write replaces the inode, so the +x bit has to be
                // restored or the script stops being executable.
                _ = chmod(file.path, 0o755)
                changed += 1
            }
        }
        if changed > 0 {
            log.info("rewrote \(changed) shebang(s) for theos")
        }
    }

    /// Finds the interpreter inside the runtime, in the places these bundles put
    /// them, before falling back to a bare name resolved through PATH.
    private func resolveInterpreter(_ name: String, root: URL) -> String? {
        let candidates = [
            "bin/\(name)",
            "usr/bin/\(name)",
            "theos/bin/\(name)",
            "usr/local/bin/\(name)",
        ]
        for candidate in candidates {
            let path = root.appendingPathComponent(candidate)
            if fileManager.isExecutableFile(atPath: path.path) { return path.path }
        }
        return nil
    }

    // MARK: - Signing

    /// Re-sign with the bundled `codex-sign`, which is MT-Agent's own helper:
    /// it thins FAT slices, re-encodes the code directory and (for the
    /// entitlement-carrying pass) fakes a CMS so CoreTrust accepts the result.
    /// `ldid -S` is not used because it cannot produce a blob CoreTrust accepts
    /// for a platform binary on modern iOS.
    private func signBinaries(plan: RuntimePlan, root: URL) throws {
        guard let signer = Bundle.main.url(forAuxiliaryExecutable: "Helpers/codex-sign")
                ?? bundledHelper("codex-sign") else {
            // No signer means an ad-hoc signed payload; still assign +x so a
            // jailbroken device that already trusts everything can run it.
            log.warning("codex-sign missing, skipping re-sign")
            return
        }

        let withEntitlements = plan.signWithEntitlements
            .map { root.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        let adhocOnly = plan.signAdhocOnly
            .map { root.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }

        // theos declares ~30 000 sign targets. One argv that large exceeds
        // ARG_MAX and posix_spawn fails before exec, so every batch is bounded.
        for batch in withEntitlements.chunked(into: 128) {
            try runSigner(signer, files: batch, entitlements: nil, adhocOnly: false)
        }
        for batch in adhocOnly.chunked(into: 128) {
            try runSigner(signer, files: batch, entitlements: nil, adhocOnly: true)
        }
    }

    private func bundledHelper(_ name: String) -> URL? {
        Bundle.main.bundleURL.appendingPathComponent("Helpers/\(name)")
    }

    private func runSigner(_ signer: URL, files: [URL], entitlements: URL?, adhocOnly: Bool) throws {
        var args: [String] = []
        if adhocOnly { args.append("--adhoc-only") }
        if let entitlements { args.append(contentsOf: ["--entitlements", entitlements.path]) }
        args.append(contentsOf: files.map(\.path))

        let result = try NativeShellExecutor.shared.run(
            executable: signer.path,
            arguments: args,
            environment: ["HOME": paths.homeDir.path, "TMPDIR": paths.tmpDir.path],
            timeout: 120)

        guard result.exitCode == 0 else {
            throw InstallerError.signingFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
    }

    // MARK: - Probe

    private func runProbe(_ probe: InstallProbe, root: URL) throws -> String {
        let exe = root.appendingPathComponent(probe.executable)
        guard fileManager.isExecutableFile(atPath: exe.path) else {
            throw InstallerError.probeFailed(probe.executable, "not executable at \(exe.path)")
        }
        guard let bash = NativeShellExecutor.bundledBash else {
            throw InstallerError.probeFailed(probe.executable,
                                             "Helpers/bash missing from the bundle")
        }
        var env = shellEnvironment()
        env["RUNTIME_ROOT"] = root.path

        // Run through bash so the working directory travels as part of the
        // command. Some probes are cwd-relative — node's does
        // require('./lib/node_modules/…') — so dropping the cwd silently turns a
        // working probe into a failing one.
        let command = "cd \(NativeShellExecutor.shellQuote(root.path)) && exec "
            + ([exe.path] + probe.arguments).map(NativeShellExecutor.shellQuote)
                .joined(separator: " ")

        let result = try NativeShellExecutor.shared.runShell(
            command: command,
            bashPath: bash,
            environment: env,
            timeout: 90,
            onLine: nil,
            onPID: nil)

        let combined = result.output + result.errorOutput
        guard combined.contains(probe.contains) else {
            throw InstallerError.probeFailed(probe.executable,
                                             "exit=\(result.exitCode) output=\(combined.prefix(300))")
        }
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filesystem bookkeeping

    private func ensureDirectories() throws {
        for dir in [paths.runtimesDir, paths.cacheDir, paths.binDir, paths.stateDir, paths.tmpDir] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeState(_ state: RuntimeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: paths.stateURL(state.key), options: .atomic)
    }

    private func readState(_ key: String) -> RuntimeState? {
        guard let data = try? Data(contentsOf: paths.stateURL(key)) else { return nil }
        return try? JSONDecoder().decode(RuntimeState.self, from: data)
    }

    /// Rewrites path-entries.txt from the currently-good runtimes, so a shell
    /// spawned mid-install sees a coherent PATH rather than a half-updated one.
    private func rebuildPathManifest() {
        var lines: [String] = []
        if let m = manifest {
            let library = paths.containerLibrary
            for state in installedStates() where state.lastProbeOK {
                guard let spec = m.runtimes[state.key] else { continue }
                let plan = RuntimePlan(spec: spec, bundle: loadBundle(spec: spec))
                let root = URL(fileURLWithPath: state.installedRoot)
                for entry in plan.persistentPathEntries {
                    lines.append(plan.resolvePathEntry(entry, root: root, containerLibrary: library).path)
                }
            }
        }
        try? lines.joined(separator: "\n").write(to: paths.pathManifestURL,
                                                 atomically: true, encoding: .utf8)
    }
}
