//
//  RuntimeCatalog.swift
//  Minis / RuntimeHost
//
//  The model behind 开发能力 — one row per runtime the manifest offers, with the
//  state the row shows and the action it runs.
//
//  Deliberately thin: every fact it displays comes out of documents the app
//  already has to parse for installation (the manifest index, the per-runtime
//  descriptor, the persisted RuntimeState). Nothing here invents a version, a
//  size or a capability, so the panel cannot drift from what the installer
//  would actually do.
//

import Foundation
import SwiftUI

@MainActor
final class RuntimeCatalog: ObservableObject {

    // MARK: - Row types

    enum Group: String, CaseIterable, Identifiable {
        case core
        case tools

        var id: String { rawValue }

        var title: String {
            switch self {
            case .core: return AppLocalized("核心能力")
            case .tools: return AppLocalized("扩展工具")
            }
        }
    }

    enum Status: Equatable {
        case notInstalled
        case ready(bytes: Int64)
        case updateAvailable(installed: String, latest: String)
        case needsRepair(String)

        var label: String {
            switch self {
            case .notInstalled:
                return AppLocalized("未安装")
            case .ready(let bytes):
                return AppLocalized("已就绪") + " · " + Self.format(bytes)
            case .updateAvailable(_, let latest):
                return AppLocalized("有新版") + " v" + latest + " · " + AppLocalized("点击更新")
            case .needsRepair(let why):
                return AppLocalized("需要修复") + " · " + why
            }
        }

        var isActionable: Bool {
            switch self {
            case .notInstalled, .updateAvailable, .needsRepair: return true
            case .ready: return false
            }
        }

        static func format(_ bytes: Int64) -> String {
            guard bytes > 0 else { return "" }
            let mb = Double(bytes) / 1_048_576
            return mb >= 1024 ? String(format: "%.1f GB", mb / 1024)
                              : String(format: "%.1f MB", mb)
        }
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let summary: String
        let symbol: String
        let tint: Color
        let group: Group
        let status: Status
    }

    // MARK: - Published state

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    @Published private(set) var busyKey: String?
    @Published private(set) var busyProgress: Double = 0
    @Published private(set) var busyStage: String = ""
    @Published private(set) var lastError: String?

    /// Whether this binary can exec real processes at all. When false the whole
    /// panel is informational: installs still work, but the shell keeps using
    /// iSH and the panel says so rather than pretending otherwise.
    @Published private(set) var nativeExecAvailable = false
    @Published private(set) var nativeExecReason = ""

    private let paths = RuntimePaths.resolve()
    private lazy var installer = RuntimeInstaller(paths: paths)

    // MARK: - Loading

    func reload() async {
        loading = true
        defer { loading = false }

        nativeExecAvailable = NativeShellExecutor.shared.isNativeExecAvailable
        nativeExecReason = nativeExecAvailable
            ? ""
            : AppLocalized("缺少 platform-application 权限,原生执行不可用")

        var manifest: RuntimeManifest?
        var source = "network"
        do {
            manifest = try await installer.loadManifest()
        } catch {
            lastError = AppLocalized("清单加载失败") + ": " + error.localizedDescription
            items = []
            diagnostics = Self.describe(available: nativeExecAvailable,
                                        source: "unavailable", count: 0)
            return
        }
        guard let manifest else { return }

        let states = Dictionary(uniqueKeysWithValues: await installer.installedStates().map { ($0.key, $0) })
        var built: [Item] = []
        for key in manifest.orderedKeys {
            guard let spec = manifest.runtimes[key], spec.isUsableByMinis else { continue }
            let bundle = await installer.descriptor(for: key)
            let plan = RuntimePlan(spec: spec, bundle: bundle)
            let record = states[plan.key] ?? states[key]

            built.append(Item(
                id: key,
                title: spec.displayName,
                summary: spec.summary ?? "",
                symbol: spec.ui?.symbol ?? "shippingbox.fill",
                tint: Self.color(spec.ui?.tint),
                group: Self.group(for: spec),
                status: Self.status(spec: spec, record: record)))
        }
        items = built

        diagnostics = Self.describe(available: nativeExecAvailable,
                                    source: source, count: built.count)

        // Republish the model-facing environment description. Without this the
        // shell tool keeps describing whatever was installed the last time an
        // install ran — including "nothing installed" for a device that adopted
        // runtimes it never installed itself.
        await installer.refreshPublishedEnvironment()
    }

    // MARK: - Actions

    /// One line that a screenshot can carry. Answers the three questions that
    /// otherwise cost a round trip: is exec actually available, where is the
    /// installer writing, and did the manifest come from the network.
    private static func describe(available: Bool, source: String, count: Int) -> String {
        var parts: [String] = []
        parts.append("exec:" + (available ? "native" : "iSH(\(NativeShellExecutor.shared.probeErrno))"))
        parts.append("manifest:" + source)
        parts.append("runtimes:" + "\(count)")
        parts.append("root:" + (RuntimePaths.resolve().isShared ? "shared" : "container"))
        return parts.joined(separator: " · ")
    }

    func install(_ key: String) async {
        guard busyKey == nil else { return }
        busyKey = key
        busyProgress = 0
        busyStage = AppLocalized("准备中")
        lastError = nil
        defer { busyKey = nil; busyProgress = 0; busyStage = "" }

        do {
            _ = try await installer.install(key: key) { [weak self] fraction, stage in
                Task { @MainActor in
                    self?.busyProgress = fraction
                    self?.busyStage = stage
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
    }

    /// Re-probe every installed runtime. Cheap; runs on appear.
    func verifyAll() async {
        for item in items where item.status != .notInstalled {
            _ = await installer.verifyInstalled(key: item.id)
        }
        await reload()
    }

    // MARK: - Derivation

    private static func group(for spec: RuntimeSpec) -> Group {
        switch spec.group ?? "" {
        case "core", "compiler": return .core
        default: return .tools
        }
    }

    private static func status(spec: RuntimeSpec, record: RuntimeState?) -> Status {
        guard let record else { return .notInstalled }
        if let failure = record.failure, !record.lastProbeOK {
            return .needsRepair(failure)
        }
        if !record.lastProbeOK { return .needsRepair(AppLocalized("校验未通过")) }
        if record.version != spec.version {
            return .updateAvailable(installed: record.version, latest: spec.version)
        }
        return .ready(bytes: spec.unpackedSize ?? 0)
    }

    private static func color(_ name: String?) -> Color {
        switch (name ?? "").lowercased() {
        case "blue": return .blue
        case "teal": return .teal
        case "green": return .green
        case "indigo": return .indigo
        case "purple": return .purple
        case "orange": return .orange
        case "pink": return .pink
        case "red": return .red
        case "yellow": return .yellow
        default: return .gray
        }
    }
}
