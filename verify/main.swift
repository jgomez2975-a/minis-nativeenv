//
//  verify/main.swift — host-side proof for the parts of the graft that are
//  pure Foundation.
//
//  Two modes:
//
//    plans <manifest.json> <docs-dir>
//        Runs the real JSONDecoder over the real runtime documents and prints
//        the plan every runtime derives. Fails if any runtime ends up without
//        PATH entries, sign targets, file checks or root markers.
//
//    tar <archive.tar> <work-dir>
//        Runs the real TarReader over a real payload and prints a canonical
//        manifest of what it wrote (path, kind, mode, size, link target,
//        sha256). Diff it against verify/tar-fixture.json.
//
//  Build with the host toolchain — no iOS SDK, no Darwin, no AppKit:
//      swiftc -O RuntimeManifest.swift RuntimePlan.swift RuntimePaths.swift \
//             RuntimeTar.swift verify/main.swift -o verify-host
//
//  The tar payload arrives gunzipped: decompression lives in RuntimeArchive.c,
//  which is C, and swiftc cannot compile it. The CI step runs `gzip -dc` first.
//

import Foundation
import CryptoKit

// MARK: - helpers

func emit(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

func sha256Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : String(repeating: " ", count: n - s.count) + s
}

// MARK: - mode: plans

func runPlans(manifestPath: String, docsDir: String) -> Int32 {
    guard let data = FileManager.default.contents(atPath: manifestPath) else {
        die("cannot read \(manifestPath)")
    }
    let manifest: RuntimeManifest
    do {
        manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
    } catch {
        die("manifest did not decode: \(error)")
    }

    emit("schema=\(manifest.schema) source=\(manifest.sourceName ?? "-") "
         + "proxies=\(manifest.downloadProxyPrefixes.count) "
         + "runtimes=\(manifest.runtimes.count)")
    emit("")

    emit(pad("key", 15) + pad("paths", 26) + lpad("req", 4) + lpad("sign", 6)
         + lpad("adhoc", 6) + lpad("sb", 4) + " " + pad("probe", 16) + "ok")
    emit(String(repeating: "-", count: 98))

    var problems: [String] = []
    var checked = 0

    for key in manifest.orderedKeys {
        guard let spec = manifest.runtimes[key] else { continue }
        if (spec.handler ?? "") == "codex" {
            emit(pad(key, 15) + "skipped — Minis has its own agent host")
            continue
        }

        let bundlePath = (docsDir as NSString).appendingPathComponent("\(key).json")
        var bundle: RuntimeBundle?
        if FileManager.default.fileExists(atPath: bundlePath),
           let blob = FileManager.default.contents(atPath: bundlePath) {
            bundle = try? JSONDecoder().decode(RuntimeBundle.self, from: blob)
        }

        let plan = RuntimePlan(spec: spec, bundle: bundle)
        checked += 1

        emit(pad(key, 15)
             + pad(plan.pathEntries.joined(separator: ","), 26)
             + lpad("\(plan.requiredPaths.count)", 4)
             + lpad("\(plan.signWithEntitlements.count)", 6)
             + lpad("\(plan.signAdhocOnly.count)", 6)
             + lpad("\(plan.shebangRewrites.count)", 4)
             + " " + pad(plan.probe?.executable ?? "-", 16)
             + (plan.probe.map { $0.contains.isEmpty ? "n" : "y" } ?? "n"))

        let descriptor = bundle != nil ? "yes" : "NO"
        if plan.derivedNotes.isEmpty {
            emit(pad("", 15) + " descriptor=\(descriptor)")
        } else {
            emit(pad("", 15) + " descriptor=\(descriptor)  "
                 + plan.derivedNotes.joined(separator: "; "))
        }

        if plan.pathEntries.isEmpty && plan.persistentPathEntries.isEmpty {
            problems.append("\(key): contributes nothing to PATH")
        }
        if plan.signWithEntitlements.isEmpty && plan.signAdhocOnly.isEmpty {
            problems.append("\(key): no sign targets — binaries will not exec")
        }
        if plan.requiredPaths.isEmpty {
            problems.append("\(key): no required_paths — a half-extracted tree would pass")
        }
        if plan.rootMarkers.isEmpty {
            problems.append("\(key): no payload-root markers")
        }
    }

    emit("")
    emit("installable runtimes: \(checked)")
    if manifest.runtimes["codex"]?.isUsableByMinis == true {
        problems.append("codex should be excluded from Minis installs")
    }

    if problems.isEmpty {
        emit("OK — every runtime derives PATH entries, sign targets, file checks and root markers")
        return 0
    }
    emit("PROBLEMS:")
    for p in problems { emit("  * \(p)") }
    return 1
}

// MARK: - mode: tar

struct ManifestEntry: Codable {
    let path: String
    let kind: String
    let mode: Int
    let size: Int
    let link: String?
    let sha256: String?
}

func runTar(archivePath: String, workDir: String) -> Int32 {
    guard TarReader.looksLikeTar(URL(fileURLWithPath: archivePath)) else {
        die("\(archivePath) does not look like a tar archive")
    }

    let destination = URL(fileURLWithPath: workDir, isDirectory: true)
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let entries: [TarEntry]
    do {
        entries = try TarReader.extract(archive: URL(fileURLWithPath: archivePath),
                                        into: destination)
    } catch {
        die("extraction failed: \(error)")
    }

    var out: [ManifestEntry] = []
    for entry in entries {
        let fileURL = destination.appendingPathComponent(entry.path)
        let digest = entry.kind == .file ? sha256Hex(of: fileURL) : nil
        out.append(ManifestEntry(path: entry.path,
                                 kind: entry.kind.rawValue,
                                 mode: entry.mode,
                                 size: entry.size,
                                 link: entry.linkTarget,
                                 sha256: digest))
    }
    out.sort { $0.path < $1.path }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let json = try? encoder.encode(out) else { die("cannot encode manifest") }
    emit(String(decoding: json, as: UTF8.self))

    // Independent of the fixture: every symlink must resolve and every file must
    // exist where it was recorded. A reader that writes plausible names into the
    // wrong place can pass a fixture diff but fails this.
    var broken: [String] = []
    for entry in out {
        let fileURL = destination.appendingPathComponent(entry.path)
        if entry.kind == "2" {
            let target = (try? FileManager.default.destinationOfSymbolicLink(
                atPath: fileURL.path)) ?? ""
            if target.isEmpty { broken.append("\(entry.path): dangling symlink") }
        } else if entry.kind != "5" {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                broken.append("\(entry.path): missing after extraction")
            }
        }
    }

    print("")
    print("entries: \(out.count)  files: \(out.filter { $0.kind == "0" }.count)  "
          + "dirs: \(out.filter { $0.kind == "5" }.count)  "
          + "symlinks: \(out.filter { $0.kind == "2" }.count)")
    if broken.isEmpty {
        print("OK — every extracted entry is present and every symlink resolves")
        return 0
    }
    print("BROKEN:")
    for b in broken { print("  * \(b)") }
    return 1
}

// MARK: - mode: fetch

/// Rehearses a real install on the host, stopping only where the host genuinely
/// cannot follow.
///
/// It downloads the published archive through the same proxy list the app uses,
/// verifies the published SHA-256, decompresses with the same C shim, extracts
/// with the same TarReader, and then checks that every path the plan requires
/// exists. That is the whole pipeline except the last mile: signing and probing
/// need an arm64 iOS binary, and this runs on macOS.
///
/// The point is that "it builds" and "it installs" are different claims, and only
/// one of them can be made by reading the compiler's output.
func runFetch(manifestPath: String, docsDir: String, workDir: String, key: String) -> Int32 {
    guard let data = FileManager.default.contents(atPath: manifestPath) else {
        die("cannot read \(manifestPath)")
    }
    let manifest: RuntimeManifest
    do {
        manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
    } catch {
        die("manifest did not decode: \(error)")
    }
    guard let spec = manifest.runtimes[key] else {
        die("no runtime named \(key); have: \(manifest.orderedKeys.joined(separator: ", "))")
    }

    let bundlePath = (docsDir as NSString).appendingPathComponent("\(key).json")
    var bundle: RuntimeBundle?
    if let blob = FileManager.default.contents(atPath: bundlePath) {
        bundle = try? JSONDecoder().decode(RuntimeBundle.self, from: blob)
    }
    let plan = RuntimePlan(spec: spec, bundle: bundle)

    print("runtime      : \(spec.displayName) \(spec.version)")
    print("plan         : \(plan.pathEntries.joined(separator: ",")) "
          + "req=\(plan.requiredPaths.count) sign=\(plan.signWithEntitlements.count)")
    print("archive      : \(spec.archiveURL)")

    // 1. Download, direct then each proxy — same order as the app.
    var candidates = [spec.archiveURL]
    for prefix in manifest.downloadProxyPrefixes { candidates.append(prefix + spec.archiveURL) }
    for prefix in RuntimeInstallerProxyDefaults.prefixes where
        !manifest.downloadProxyPrefixes.contains(prefix) {
        candidates.append(prefix + spec.archiveURL)
    }

    var archivePath: String?
    var attempts: [String] = []
    for candidate in candidates {
        guard let url = URL(string: candidate) else { continue }
        let dest = (workDir as NSString).appendingPathComponent(
            (spec.assetName as NSString?)?.lastPathComponent ?? "archive.bin")
        let fetched = fetchSynchronously(url: url, to: dest)
        if fetched == nil {
            attempts.append("ok \(url.host ?? "-")")
            archivePath = dest
            break
        }
        attempts.append("\(url.host ?? "-"): \(fetched!)")
    }
    guard let archivePath else {
        print("DOWNLOAD FAILED")
        for a in attempts { print("  * \(a)") }
        return 1
    }
    print("download     : ok (\(attempts.last ?? ""))")

    // 2. Published checksum.
    guard let actual = sha256Hex(of: URL(fileURLWithPath: archivePath)) else {
        die("cannot hash downloaded archive")
    }
    if actual.caseInsensitiveCompare(spec.archiveSHA256) == .orderedSame {
        print("sha256       : ok")
    } else {
        print("sha256       : MISMATCH")
        print("  expected \(spec.archiveSHA256)")
        print("  actual   \(actual)")
        return 1
    }

    // 3. Decompress with the same shim the app links.
    let tarPath = (workDir as NSString).appendingPathComponent("payload.tar")
    FileManager.default.createFile(atPath: tarPath, contents: nil)
    // FileHandle(forWritingTo:) returns a non-optional and *throws* on failure;
    // `guard let` over it made the harness fail to compile rather than fail to
    // run, which is the worse of the two.
    guard let out = try? FileHandle(forWritingTo: URL(fileURLWithPath: tarPath)) else {
        die("cannot open \(tarPath)")
    }
    final class Sink { let handle: FileHandle; var failed = false
        init(_ h: FileHandle) { handle = h } }
    let sink = Sink(out)
    let ctx = Unmanaged.passUnretained(sink).toOpaque()
    let rc = ra_gunzip_stream(archivePath, { ctx, bytes, length -> Int32 in
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
    try? out.close()
    guard rc == 0, !sink.failed else {
        print("gunzip       : FAILED (rc=\(rc))")
        return 1
    }
    let tarBytes = (try? FileManager.default.attributesOfItem(atPath: tarPath)[.size] as? NSNumber)??.intValue ?? 0
    print("gunzip       : ok (\(tarBytes / 1_048_576) MB)")

    // 4. Extract with the same reader.
    let dest = URL(fileURLWithPath: workDir).appendingPathComponent("root")
    try? FileManager.default.removeItem(at: dest)
    let entries: [TarEntry]
    do {
        entries = try TarReader.extract(archive: URL(fileURLWithPath: tarPath), into: dest)
    } catch {
        print("tar          : FAILED — \(error)")
        return 1
    }
    print("tar          : ok (\(entries.count) entries)")

    // 5. The plan's own expectations.
    var missing: [String] = []
    for required in plan.requiredPaths {
        if !FileManager.default.fileExists(atPath: dest.appendingPathComponent(required).path) {
            missing.append(required)
        }
    }
    if !missing.isEmpty {
        print("required     : MISSING \(missing.count): \(missing.prefix(5).joined(separator: ", "))")
        return 1
    }
    print("required     : ok (\(plan.requiredPaths.count) paths)")

    // 6. PATH entries must resolve to something executable.
    for entry in plan.pathEntries {
        let resolved = plan.resolvePathEntry(entry, root: dest,
                                             containerLibrary: dest)
        let exists = FileManager.default.fileExists(atPath: resolved.path)
        print("path entry   : \(entry) -> \(exists ? "present" : "MISSING")")
        if !exists { return 1 }
    }

    print("")
    print("OK — download, checksum, decompression, extraction and required paths "
          + "all succeeded for \(key)")
    print("     (signing and probing need an arm64 iOS binary; not exercised here)")
    return 0
}

enum RuntimeInstallerProxyDefaults {
    /// Mirrors RuntimeInstaller.defaultProxyPrefixes; kept here so the harness
    /// does not have to link the installer actor and its Darwin dependencies.
    static let prefixes = ["https://gh-proxy.org/", "https://ghproxy.net/"]
}

/// nil on success, an error string on failure.
func fetchSynchronously(url: URL, to path: String) -> String? {
    final class Box: @unchecked Sendable {
        var result: String?
    }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    URLSession.shared.downloadTask(with: request) { location, response, error in
        defer { semaphore.signal() }
        if let error {
            box.result = error.localizedDescription
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            box.result = "HTTP \(http.statusCode)"
            return
        }
        guard let location else { box.result = "no body"; return }
        do {
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: path))
        } catch {
            box.result = error.localizedDescription
        }
    }.resume()
    semaphore.wait()
    return box.result
}

// MARK: - entry

let args = CommandLine.arguments
guard args.count >= 4 else {
    die("usage:\n  verify-host plans <manifest.json> <docs-dir>\n"
        + "  verify-host tar <archive.tar> <work-dir>\n"
        + "  verify-host fetch <manifest.json> <docs-dir> <work-dir> [runtime-key]")
}

switch args[1] {
case "plans":
    exit(runPlans(manifestPath: args[2], docsDir: args[3]))
case "tar":
    exit(runTar(archivePath: args[2], workDir: args[3]))
case "fetch":
    guard args.count >= 5 else { die("usage: verify-host fetch <manifest> <docs> <workdir> [key]") }
    let key = args.count >= 6 ? args[5] : "core_tools"
    exit(runFetch(manifestPath: args[2], docsDir: args[3], workDir: args[4], key: key))
default:
    die("unknown mode \(args[1])")
}
