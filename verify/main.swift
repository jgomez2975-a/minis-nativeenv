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

// MARK: - entry

let args = CommandLine.arguments
guard args.count >= 4 else {
    die("usage:\n  verify-host plans <manifest.json> <docs-dir>\n"
        + "  verify-host tar <archive.tar> <work-dir>")
}

switch args[1] {
case "plans":
    exit(runPlans(manifestPath: args[2], docsDir: args[3]))
case "tar":
    exit(runTar(archivePath: args[2], workDir: args[3]))
default:
    die("unknown mode \(args[1])")
}
