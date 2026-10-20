//
//  RuntimeManifest.swift
//  Minis / RuntimeHost
//
//  Codable mirror of CodexApp-Runtime's runtime-manifest.json (schema 3).
//
//  Only the fields the installer acts on are modelled. Everything else in the
//  document — UI hints, ollvm pass descriptions, theos refs — is deliberately
//  left undecoded: Swift's Decodable ignores unknown keys, so the schema can
//  grow upstream without breaking this build. That tolerance is the point; a
//  strict mirror would have to be re-released every time the runtime repo adds
//  a knob.
//
//  The one field that is NOT optional in practice is `install`. A runtime
//  without it (the `codex` handler) is skipped by design — see
//  `RuntimeInstaller.installableRuntimes`.
//

import Foundation

// MARK: - Root

struct RuntimeManifest: Decodable {
    let schema: Int
    let sourceName: String?
    let downloadProxyPrefixes: [String]
    let runtimes: [String: RuntimeSpec]

    enum CodingKeys: String, CodingKey {
        case schema
        case sourceName = "source_name"
        case downloadProxyPrefixes = "download_proxy_prefixes"
        case runtimes
    }

    /// Stable display order: `order` first, then key, so two devices show the
    /// toolchain list the same way regardless of JSON key order.
    var orderedKeys: [String] {
        runtimes.keys.sorted { a, b in
            let oa = runtimes[a]?.order ?? Int.max
            let ob = runtimes[b]?.order ?? Int.max
            return oa == ob ? a < b : oa < ob
        }
    }
}

// MARK: - Runtime

struct RuntimeSpec: Decodable {
    let displayName: String
    let version: String
    let revision: String?
    let summary: String?
    let group: String?
    let handler: String?
    let minimumIOS: String?
    /// Named `isOptional` rather than `optional`: the latter is a Swift
    /// declaration modifier, and an identifier that doubles as a keyword is a
    /// parse hazard in exactly the positions that are hard to debug.
    let isOptional: Bool
    let order: Int?
    let runtimeFormat: Int?

    let archiveURL: String
    let archiveSHA256: String
    let downloadSize: Int64?
    let unpackedSize: Int64?
    let assetName: String?
    let metadataURL: String?

    let components: Components?

    /// Icon hint for the capabilities panel: `{"symbol": "shippingbox.fill",
    /// "tint": "teal"}`. Present on every runtime; used only for display.
    let ui: UIBadge?

    // NOTE: `components` is display-only and its shape is not uniform across
    // runtimes — core_tools and node carry `{"git": "2.39.1"}`, reverse_tools
    // and theos carry `{"go-macho": {"version": "v1.1.292"}}`. Declaring it
    // `[String: String]` therefore threw a typeMismatch and took the entire
    // manifest down: synthesised decoding treats an Optional as "may be absent",
    // never as "may be a different shape". It is modelled as the union below so
    // no future runtime can break decoding by nesting one level deeper.
    enum Components: Decodable {
        case versionStrings([String: String])
        case objects([String: [String: String]])

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flat = try? single.decode([String: String].self) {
                self = .versionStrings(flat)
                return
            }
            if let nested = try? single.decode([String: [String: String]].self) {
                self = .objects(nested)
                return
            }
            // Anything else is a display concern, not a reason to fail an install.
            self = .versionStrings([:])
        }

        /// Flattened `name -> version` view for the UI.
        var versionMap: [String: String] {
            switch self {
            case .versionStrings(let flat):
                return flat
            case .objects(let nested):
                return nested.compactMapValues { $0["version"] ?? $0["commit"] }
            }
        }
    }
    let install: InstallInstructions?

    // Toolchain-specific version stamps — shown in the UI, never used for logic.
    let nodeVersion: String?
    let npmVersion: String?
    let pythonVersion: String?
    let llvmVersion: String?
    let radare2Version: String?
    let sdk: String?

    // NOTE: `runtime_id`, `format`, `sign_paths`, `executables`, `libraries` and
    // `portable_shebangs` are deliberately NOT modelled here. They exist only in
    // the per-runtime descriptor (`RuntimeBundle`); the manifest index never
    // carries them. Declaring them on both shapes produced six fields that were
    // permanently nil, which reads like the index is authoritative when it is
    // not — and the whole point of `RuntimePlan` is to be honest about which
    // document said what.

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case version, revision, summary, group, handler, order, components, install, sdk
        case isOptional = "optional"
        case minimumIOS = "minimum_ios"
        case runtimeFormat = "runtime_format"
        case ui
        case archiveURL = "archive_url"
        case archiveSHA256 = "archive_sha256"
        case downloadSize = "download_size"
        case unpackedSize = "unpacked_size"
        case assetName = "asset_name"
        case metadataURL = "metadata_url"
        case nodeVersion = "node_version"
        case npmVersion = "npm_version"
        case pythonVersion = "python_version"
        case llvmVersion = "llvm_version"
        case radare2Version = "radare2_version"
    }

    /// The `handler` tells the host how to unpack and where the payload's root
    /// sits. `portable-v1` and `python` are plain tarballs; `theos` carries its
    /// own sdks/ tree; `codex` is the on-device Codex host, which Minis does not
    /// use because Minis has its own agent loop and provider layer.
    var isUsableByMinis: Bool {
        guard let handler else { return false }
        return handler != "codex"
    }

    var revisionKey: String { revision ?? version }
}

// MARK: - Install instructions

struct InstallInstructions: Decodable {
    let pathEntries: [String]
    let persistentPathEntries: [String]
    let environment: [String: String]
    let probe: InstallProbe?
    let requiredPaths: [String]
    let signPaths: [String]
    let signPathsWithoutEntitlements: [String]

    enum CodingKeys: String, CodingKey {
        case pathEntries = "path_entries"
        case persistentPathEntries = "persistent_path_entries"
        case environment, probe
        case requiredPaths = "required_paths"
        case signPaths = "sign_paths"
        case signPathsWithoutEntitlements = "sign_paths_without_entitlements"
    }

    /// Hand-written so every list defaults to empty instead of throwing.
    ///
    /// This is not defensive style, it is a correctness requirement: the
    /// published install blocks disagree about which keys they carry.
    /// `sign_paths_without_entitlements` appears in two of six documents and
    /// `persistent_path_entries` in one. With synthesised decoding, one such
    /// omission throws — and because `RuntimeSpec.install` is part of a document
    /// that is decoded for *every* runtime at once, that single missing key
    /// failed the entire manifest, leaving the runtime subsystem with nothing.
    ///
    /// An absent list now means "this runtime contributes none of these", which
    /// is what the documents actually intend.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pathEntries = try c.decodeIfPresent([String].self, forKey: .pathEntries) ?? []
        persistentPathEntries = try c.decodeIfPresent([String].self,
                                                      forKey: .persistentPathEntries) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        probe = try c.decodeIfPresent(InstallProbe.self, forKey: .probe)
        requiredPaths = try c.decodeIfPresent([String].self, forKey: .requiredPaths) ?? []
        signPaths = try c.decodeIfPresent([String].self, forKey: .signPaths) ?? []
        signPathsWithoutEntitlements = try c.decodeIfPresent(
            [String].self, forKey: .signPathsWithoutEntitlements) ?? []
    }

    /// Used by `RuntimePlan` when a runtime declares no install block at all.
    init(pathEntries: [String] = [],
         persistentPathEntries: [String] = [],
         environment: [String: String] = [:],
         probe: InstallProbe? = nil,
         requiredPaths: [String] = [],
         signPaths: [String] = [],
         signPathsWithoutEntitlements: [String] = []) {
        self.pathEntries = pathEntries
        self.persistentPathEntries = persistentPathEntries
        self.environment = environment
        self.probe = probe
        self.requiredPaths = requiredPaths
        self.signPaths = signPaths
        self.signPathsWithoutEntitlements = signPathsWithoutEntitlements
    }
}

/// A runtime is "installed" when its probe exits 0 AND stdout contains the
/// sentinel. Presence of files alone is not enough: a half-extracted tree looks
/// complete on disk and fails only when the model calls it.
///
/// No hand-written init: Swift synthesises the memberwise one, and an explicit
/// copy of it is just a second thing to keep in step.
struct InstallProbe: Decodable {
    let executable: String
    let arguments: [String]
    let contains: String
}

/// Icon hint attached to every runtime entry.
struct UIBadge: Decodable {
    let symbol: String?
    let tint: String?
}

// MARK: - Per-runtime descriptor
/// The document behind a runtime's `metadata_url`.
///
/// runtime-manifest.json is an *index*, not the full description. Three of the
/// six useful runtimes — python, reverse_tools, theos — carry no `install` and
/// no `sign_paths` in the index at all; their sign targets and layout live only
/// here. Reading the index alone therefore produces an install that puts files
/// on disk and never re-signs them, which on iOS means every one of those
/// binaries fails at exec with a bare EPERM.
struct RuntimeBundle: Decodable {
    let format: Int?
    let runtimeID: String?
    let install: InstallInstructions?
    let signPaths: [String]?
    let executables: [String]?
    let libraries: [String]?
    let portableShebangs: [ShebangRewrite]?
    let sdk: String?

    enum CodingKeys: String, CodingKey {
        case format
        case runtimeID = "runtime_id"
        case install
        case signPaths = "sign_paths"
        case executables, libraries, sdk
        case portableShebangs = "portable_shebangs"
    }
}

// MARK: - Install state

/// Persisted per runtime so a restart does not re-download or re-probe.
struct RuntimeState: Codable {
    let key: String
    let revision: String
    let version: String
    let installedAt: Date
    let installedRoot: String
    var lastProbeOK: Bool
    var lastProbeOutput: String?
    var failure: String?
}
