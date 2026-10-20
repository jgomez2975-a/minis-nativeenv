//
//  RuntimePlan.swift
//  Minis / RuntimeHost
//
//  Turns a `RuntimeSpec` into the exact actions the installer should take.
//
//  Why this exists: runtime-manifest.json does not describe its runtimes
//  uniformly. Three shapes appear in the wild and only one of them carries an
//  `install` block:
//
//    format 1 + install      core_tools, node, ollvm        — fully declared
//    format 1, no install    reverse_tools                  — only top-level sign_paths
//    format 3, no install    python                         — top-level sign_paths,
//                                                             payload root is not bin/
//    format 11, no install   theos                          — executables/libraries
//                                                             lists + portable_shebangs
//
//  Reading only `install` therefore installs python and reverse_tools into a
//  directory nothing references: PATH gets no entry, the binaries never get
//  re-signed, and the probe (absent) still reports success. That is the worst
//  failure mode available — an install that looks complete and does nothing.
//  `RuntimePlan` derives the missing pieces from what each format does declare.
//

import Foundation

/// One `#!/usr/bin/env perl` style line that must be repointed at the runtime's
/// own interpreter. Theos ships ~300 scripts written against a normal Unix
/// where `env` finds perl; on iOS `env` finds nothing.
struct ShebangRewrite: Decodable {
    let path: String
    let interpreter: String
    let arguments: [String]
    let original: String
}

struct RuntimePlan {

    let key: String
    let displayName: String
    let version: String

    /// Directory names that identify the payload root after extraction.
    let rootMarkers: Set<String>

    /// Prefixes prepended to PATH, relative to the installed root. `"."` means
    /// the root itself.
    let pathEntries: [String]

    /// Entries that live outside the runtime root. These are container-relative
    /// today (`Library/Application Support/…/prefix/bin`) and must resolve
    /// against the app's Library, not against the runtime.
    let persistentPathEntries: [String]

    let environment: [String: String]
    let requiredPaths: [String]

    /// Re-signed with the full entitlement blob (platform-application).
    let signWithEntitlements: [String]

    /// Re-signed ad-hoc only — nested frameworks that iOS loads but which must
    /// not themselves claim platform entitlements.
    let signAdhocOnly: [String]

    let probe: InstallProbe?
    let shebangRewrites: [ShebangRewrite]

    /// Human-readable reasons this plan is a reconstruction rather than a
    /// transcription. Surfaced in the runtime panel so a broken install is
    /// diagnosable from the device instead of from a manifest diff.
    let derivedNotes: [String]

    // MARK: - Derivation

    /// `bundle` is the runtime's own descriptor, fetched from its `metadata_url`.
    /// Where the index and the descriptor disagree the descriptor wins: it is
    /// the document that was produced alongside the archive.
    init(spec: RuntimeSpec, bundle: RuntimeBundle? = nil) {
        self.key = bundle?.runtimeID ?? spec.displayName.lowercased()
        self.displayName = spec.displayName
        self.version = spec.version

        var notes: [String] = []
        var markers: Set<String> = ["bin", "lib", "Frameworks"]
        var paths: [String] = ["bin"]
        var env: [String: String] = [:]
        var reqPaths: [String] = []
        var signed: [String] = []
        var adhoc: [String] = []
        var probe: InstallProbe?

        let install = bundle?.install ?? spec.install

        // 1. Anything the descriptor declares wins outright.
        if let install {
            markers.formUnion(install.requiredPaths.compactMap {
                $0.split(separator: "/").first.map(String.init)
            })
            if !install.pathEntries.isEmpty { paths = install.pathEntries }
            env = install.environment
            reqPaths = install.requiredPaths
            signed = install.signPaths
            adhoc = install.signPathsWithoutEntitlements
            probe = install.probe
            if reqPaths.isEmpty {
                notes.append("descriptor declares no required_paths — file checks will be skipped")
            }
        }

        // 2. The formats with no install block declare their sign set flat, and
        //    only in the descriptor. The manifest index never carries one.
        if signed.isEmpty, let fromBundle = bundle?.signPaths, !fromBundle.isEmpty {
            signed = fromBundle
            notes.append("sign_paths from the runtime descriptor")
        }

        // 3. Format-specific layout. Each branch states what it is reconstructing.
        if install == nil {
            switch spec.handler ?? "" {
            case "python":
                // Payload is python3 + Python.framework + Frameworks at the root,
                // so the root itself is the PATH entry — there is no bin/.
                markers = ["python3", "Python.framework", "Frameworks", "lib"]
                paths = ["."]
                reqPaths = ["python3"]
                notes.append("python layout reconstructed: root is the PATH entry")

            case "reverse_tools":
                markers = ["bin"]
                paths = ["bin"]
                reqPaths = ["bin/radare2", "bin/rabin2"]
                notes.append("reverse_tools layout reconstructed from its sign_paths prefix")

            case "theos":
                // Theos payload is a rootfs-shaped tree: theos/, usr/bin, bin, sbin.
                markers = ["theos", "usr", "sdk"]
                paths = ["theos/bin", "usr/bin", "usr/local/bin", "bin"]
                reqPaths = ["theos/bin", "theos/makefiles"]
                if signed.isEmpty {
                    signed = (bundle?.executables ?? []) + (bundle?.libraries ?? [])
                }
                notes.append("theos layout reconstructed from its rootfs tree and sdks/")
                if let sdk = spec.sdk ?? bundle?.sdk {
                    notes.append("bundled SDK: \(sdk)")
                }

            default:
                let handlerName = spec.handler ?? "nil"
                notes.append("unknown handler `\(handlerName)` — using portable-v1 defaults")
            }
        }

        self.rootMarkers = markers
        self.pathEntries = paths
        self.persistentPathEntries = install?.persistentPathEntries ?? []
        self.environment = env
        self.requiredPaths = reqPaths
        self.signWithEntitlements = signed
        self.signAdhocOnly = adhoc
        self.probe = probe
        self.shebangRewrites = bundle?.portableShebangs ?? []
        self.derivedNotes = notes
    }

    // MARK: - Path resolution

    /// Resolves a plan entry against the installed root.
    ///
    /// `Library/Application Support/CodexApp/Node/prefix/bin` is container
    /// relative — resolving it against the runtime root would produce
    /// `<runtime>/Library/Application Support/…`, a directory nothing writes to.
    func resolvePathEntry(_ entry: String, root: URL, containerLibrary: URL) -> URL {
        if entry.hasPrefix("Library/") || entry.hasPrefix("Documents/") || entry.hasPrefix("tmp/") {
            return containerLibrary.appendingPathComponent(
                entry.hasPrefix("Library/") ? String(entry.dropFirst("Library/".count)) : entry)
        }
        if entry == "." { return root }
        return root.appendingPathComponent(entry)
    }

    /// True when this runtime contributes anything to PATH at all.
    var contributesToPath: Bool {
        !pathEntries.isEmpty || !persistentPathEntries.isEmpty
    }
}

// MARK: - Chunking

extension Array {
    /// posix_spawn takes argv inline; a theos sign run can be 30 000 paths, and
    /// a single argv that large exceeds ARG_MAX and fails before exec. Chunking
    /// keeps every invocation small enough to actually run.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
