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
    let optional: Bool
    let order: Int?
    let runtimeFormat: Int?

    let archiveURL: String
    let archiveSHA256: String
    let downloadSize: Int64?
    let unpackedSize: Int64?
    let assetName: String?
    let metadataURL: String?

    let components: [String: String]?
    let install: InstallInstructions?

    // Toolchain-specific version stamps — shown in the UI, never used for logic.
    let nodeVersion: String?
    let npmVersion: String?
    let pythonVersion: String?
    let llvmVersion: String?
    let radare2Version: String?
    let sdk: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case version, revision, summary, group, handler, optional, order, components, install, sdk
        case minimumIOS = "minimum_ios"
        case runtimeFormat = "runtime_format"
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
    let persistentPathEntries: [String]?
    let environment: [String: String]?
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
}

/// A runtime is "installed" when its probe exits 0 AND stdout contains the
/// sentinel. Presence of files alone is not enough: a half-extracted tree looks
/// complete on disk and fails only when the model calls it.
struct InstallProbe: Decodable {
    let executable: String
    let arguments: [String]
    let contains: String
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
