//
//  DevCapabilitiesView.swift
//  Minis / RuntimeHost
//
//  The 开发能力 page. Two sections — 核心能力 and 扩展工具 — with one row per
//  runtime, because that is the only place a user can see *whether the
//  environment is actually there*. Without it the shell silently falls back to
//  the emulated iSH sandbox and nothing in the app explains why `clang` is
//  missing.
//
//  Every string shown is derived from the manifest and the persisted install
//  state; this view never guesses a version, a size or a capability.
//

import SwiftUI

struct DevCapabilitiesView: View {
    @StateObject private var model = RuntimeCatalog()

    var body: some View {
        Form {
            if !model.nativeExecAvailable {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalized("原生执行不可用"))
                                .font(.callout.weight(.medium))
                            Text(model.nativeExecReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text(AppLocalized("工具链仍然可以安装,但 shell 会退回 iSH 模拟环境:慢,而且跑不了 arm64 二进制。需要用 platform-application 权限重新签名后才能用上。"))
                }
            }

            ForEach(RuntimeCatalog.Group.allCases) { group in
                let rows = model.items.filter { $0.group == group }
                if !rows.isEmpty {
                    Section(group.title) {
                        ForEach(rows) { item in
                            row(item)
                        }
                    }
                }
            }

            if let error = model.lastError {
                Section {
                    Label {
                        Text(error).font(.caption)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalized("工具链装在设备上,装一次长期可用。全部装完约 1.3 GB;Theos 最大,约 980 MB。"))
                    if !model.diagnostics.isEmpty {
                        Text(model.diagnostics)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(AppLocalized("开发能力"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.loading || model.busyKey != nil)
            }
        }
        .task {
            await model.reload()
            await model.verifyAll()
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: RuntimeCatalog.Item) -> some View {
        let busy = model.busyKey == item.id

        Button {
            guard item.status.isActionable || item.status == .notInstalled else { return }
            Task { await model.install(item.id) }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(item.tint.gradient)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(busy ? "\(model.busyStage) \(Int(model.busyProgress * 100))%"
                              : item.status.label)
                        .font(.caption)
                        .foregroundStyle(statusColor(item.status))
                }

                Spacer(minLength: 8)

                if busy {
                    ProgressView(value: model.busyProgress)
                        .progressViewStyle(.circular)
                        .frame(width: 18, height: 18)
                } else if item.status.isActionable {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busyKey != nil)
    }

    private func statusColor(_ status: RuntimeCatalog.Status) -> Color {
        switch status {
        case .notInstalled: return .secondary
        case .ready: return .green
        case .updateAvailable: return .accentColor
        case .needsRepair: return .orange
        }
    }
}
