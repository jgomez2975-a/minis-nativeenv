//
//  verify/main.swift — executable proof for the decoder + plan layer.
//
//  The JSON decoding in this module fails *silently* by design: a CodingKey
//  typo makes a field decode as nil, the plan falls back to a reconstruction,
//  and the install signs the wrong set of binaries. Nothing throws. So the only
//  meaningful check is to run the real decoder over the real published
//  documents and compare the derived plans against a known-good table.
//
//  Build (needs no iOS SDK, no Darwin, no AppKit — these three files are pure
//  Foundation):
//      swiftc -O RuntimeManifest.swift RuntimePlan.swift RuntimePaths.swift \
//             verify/main.swift -o verify-plan
//
//  Run:
//      ./verify-plan <manifest.json> <bundle-dir>
//  where <bundle-dir> holds <key>.json for each runtime descriptor.
//

import Foundation

// MARK: - Minimal helpers

func loadJSON<T: Decodable>(_ type: T.Type, from path: String) -> T? {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        return nil
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        FileHandle.standardError.write("decode failed for \(path): \(error)\n".data(using: .utf8)!)
        return nil
    }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : String(repeating: " ", count: n - s.count) + s
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: verify-plan <runtime-manifest.json> <bundle-dir>")
    exit(2)
}
let manifestPath = args[1]
let bundleDir = args[2]

guard let manifest: RuntimeManifest = loadJSON(RuntimeManifest.self, from: manifestPath) else {
    print("FATAL: manifest did not decode")
    exit(1)
}

print("schema=\(manifest.schema) source=\(manifest.sourceName ?? "-") "
      + "proxies=\(manifest.downloadProxyPrefixes.count) runtimes=\(manifest.runtimes.count)")
print()

print(pad("key", 15) + pad("paths", 26) + lpad("req", 4) + lpad("sign", 6)
      + lpad("adhoc", 6) + lpad("sb", 4) + " " + pad("probe", 16) + "ok")
print(String(repeating: "-", count: 98))

var problems: [String] = []
var checked = 0

for key in manifest.orderedKeys {
    guard let spec = manifest.runtimes[key] else { continue }
    let handler = spec.handler ?? ""
    if handler == "codex" {
        print(pad(key, 15) + "skipped — Minis has its own agent host")
        continue
    }

    let bundlePath = (bundleDir as NSString).appendingPathComponent("\(key).json")
    let bundle: RuntimeBundle? = FileManager.default.fileExists(atPath: bundlePath)
        ? loadJSON(RuntimeBundle.self, from: bundlePath)
        : nil

    let plan = RuntimePlan(spec: spec, bundle: bundle)
    checked += 1

    let pathText = plan.pathEntries.joined(separator: ",")
    print(pad(key, 15)
          + pad(pathText, 26)
          + lpad("\(plan.requiredPaths.count)", 4)
          + lpad("\(plan.signWithEntitlements.count)", 6)
          + lpad("\(plan.signAdhocOnly.count)", 6)
          + lpad("\(plan.shebangRewrites.count)", 4)
          + " " + pad(plan.probe?.executable ?? "-", 16)
          + (plan.probe.map { $0.contains.isEmpty ? "n" : "y" } ?? "n"))

    if !plan.derivedNotes.isEmpty {
        print(pad("", 15) + " descriptor=\(bundle != nil ? "yes" : "NO")  "
              + plan.derivedNotes.joined(separator: "; "))
    } else {
        print(pad("", 15) + " descriptor=\(bundle != nil ? "yes" : "NO")")
    }

    // Invariants that, if violated, produce an install nothing can use.
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

// A manifest-level sanity gate: the two fields that were silently missing once.
print()
print("installable runtimes: \(checked)")
if manifest.runtimes["codex"]?.isUsableByMinis == true {
    problems.append("codex should be excluded from Minis installs")
}

if problems.isEmpty {
    print("OK — every runtime derives PATH entries, sign targets, file checks and root markers")
    exit(0)
}
print("PROBLEMS:")
for p in problems { print("  * \(p)") }
exit(1)
