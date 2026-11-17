//
//  APFSStagingSheet.swift
//  Erosion
//
//  Interactive UI for the 5-Layer Foolproof APFS clonefile() Zero-Space App Swap Vault.
//

import SwiftUI

struct APFSStagingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vault = APFSStagingVault.shared

    @Binding var containers: [AppSaveContainerItem]
    var onRequestRescan: (() -> Void)?

    @State private var selectedSourceID: String = ""
    @State private var sourceWeChatPreview: Int?
    @State private var isLoadingWeChatPreview = false
    @State private var showTargetPickerForRecord: APFSStagingRecord?
    @State private var postRestoreOutcome: APFSRestoreOutcome?
    @State private var didShowInitialCertAlert = false
    @State private var showGuide = false

    @State private var activeAlert: StagingAlertType?

    private enum StagingAlertType: Identifiable {
        case certGateWarning(ProvisioningCertInfo, AppSaveContainerItem?)
        case confirmStage(AppSaveContainerItem, Int?)
        case confirmRestore(APFSStagingRecord, AppSaveContainerItem)
        case confirmRelease(APFSStagingRecord)
        case info(title: String, message: String)

        var id: String {
            switch self {
            case .certGateWarning(_, let item): return "certGate_\(item?.id ?? "open")"
            case .confirmStage(let item, _): return "stage_\(item.id)"
            case .confirmRestore(let rec, let tgt): return "restore_\(rec.id)_\(tgt.id)"
            case .confirmRelease(let rec): return "release_\(rec.id)"
            case .info(let title, let msg): return "info_\(title)_\(msg.prefix(24))"
            }
        }
    }

    private var stageableContainers: [AppSaveContainerItem] {
        let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
        return containers.filter {
            $0.bundleID != selfBID && !APFSStagingEngine.protectedBundleIDs.contains($0.bundleID)
        }
    }

    private var selectedSourceItem: AppSaveContainerItem? {
        if let hit = stageableContainers.first(where: { $0.id == selectedSourceID }) {
            return hit
        }
        return stageableContainers.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    certGateSection
                    stagedRecordsSection
                    stageNewContainerSection
                    foolproofLayersSection
                }
                .disabled(vault.isBusy)

                if vault.isBusy {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(vault.busyMessage)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                        Text(apfsVaultText(
                            "Screen awake lock active. Do not leave Erosion.",
                            "已自动锁定屏幕常亮，请勿切出或关闭 Erosion。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(22)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 28)
                }
            }
            .navigationTitle(apfsVaultText("APFS Swap Vault", "APFS 零空间暂存舱"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(apfsVaultText("Close", "关闭")) {
                        dismiss()
                    }
                    .disabled(vault.isBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            showGuide = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .disabled(vault.isBusy)

                        Button {
                            vault.refreshCertificateStatus()
                            vault.reloadRecords()
                            onRequestRescan?()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(vault.isBusy)
                    }
                }
            }
            .onAppear {
                let info = vault.refreshCertificateStatus()
                vault.reloadRecords()
                if selectedSourceID.isEmpty, let first = stageableContainers.first {
                    selectedSourceID = first.id
                }
                refreshWeChatPreviewIfNeeded()
                if info.requiresUrgentResignWarning && !didShowInitialCertAlert {
                    didShowInitialCertAlert = true
                    activeAlert = .certGateWarning(info, nil)
                }
            }
            .onChange(of: selectedSourceID) {
                refreshWeChatPreviewIfNeeded()
            }
            .onChange(of: containers.count) {
                if selectedSourceItem == nil, let first = stageableContainers.first {
                    selectedSourceID = first.id
                }
            }
            .sheet(item: $showTargetPickerForRecord) { record in
                TargetContainerPickerSheet(
                    record: record,
                    containers: $containers,
                    onRequestRescan: onRequestRescan,
                    onSelectTarget: { chosen in
                        showTargetPickerForRecord = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            activeAlert = .confirmRestore(record, chosen)
                        }
                    }
                )
            }
            .sheet(item: $postRestoreOutcome) { outcome in
                APFSPostRestoreGuideSheet(outcome: outcome)
            }
            .sheet(isPresented: $showGuide) {
                APFSVaultGuideSheet()
            }
            .alert(
                alertTitle(for: activeAlert),
                isPresented: Binding(
                    get: { activeAlert != nil },
                    set: { if !$0 { activeAlert = nil } }
                ),
                presenting: activeAlert
            ) { alertItem in
                alertActions(for: alertItem)
            } message: { alertItem in
                Text(alertMessage(for: alertItem))
            }
        }
        .interactiveDismissDisabled(vault.isBusy)
    }

    // MARK: - Section 1: Layer 1 Certificate Expiry Gate

    private var certGateSection: some View {
        let cert = vault.certInfo
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: cert.requiresUrgentResignWarning ? "exclamationmark.shield.fill" : "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(certStatusColor(cert.status))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(apfsVaultText("Layer 1 · Signing Certificate Gate", "第 1 层防呆 · 签名证书有效期门禁"))
                            .font(.subheadline.weight(.semibold))
                        Text(cert.remainingDisplayText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(certStatusColor(cert.status))
                    }
                    Spacer()
                }

                if cert.status != .notEmbedded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(apfsVaultText("Profile", "描述文件")): \(cert.profileName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let expText = cert.expirationDateFormatted {
                            Text("\(apfsVaultText("Expires", "到期时间")): \(expText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if cert.requiresUrgentResignWarning {
                    Text(apfsVaultText(
                        "WARNING: Less than 24 hours remain (or certificate expired). Refresh/re-sign Erosion in SideStore or AltStore BEFORE staging and uninstalling your target app — otherwise Erosion may fail to launch for restore!",
                        "高危预警：当前 Erosion 签名剩余不足 24 小时（或已过期）！请务必先前往 SideStore / AltStore 刷新续签 Erosion，再暂存并卸载旧应用，避免无法打开本工具还原数据！"
                    ))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.vertical, 3)
        } header: {
            HeaderLabel(
                apfsVaultText("Certificate Expiry Status", "证书有效期检查"),
                symbol: "signature"
            )
        }
    }

    // MARK: - Section 2: Active Staged Snapshots

    private var stagedRecordsSection: some View {
        Section {
            if vault.stagedRecords.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(apfsVaultText("Vault is empty", "暂存舱当前为空"))
                        .font(.subheadline.weight(.medium))
                    Text(apfsVaultText(
                        "Stage an app below using APFS clonefile(). Data stays zero-space on the same APFS volume while you uninstall/reinstall or switch Bundle IDs.",
                        "可在下方选择应用进行 APFS clonefile() 零空间暂存。暂存期间不会额外占用双倍存储空间，可安全卸载重装或跨多开包名还原。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(vault.stagedRecords) { record in
                    stagedRecordCard(record)
                }
            }
        } header: {
            HeaderLabel(
                apfsVaultText(
                    "Staged Snapshots (\(vault.stagedRecords.count))",
                    "已暂存快照 (\(vault.stagedRecords.count))"
                ),
                symbol: "lock.doc.fill"
            )
        } footer: {
            if !vault.stagedRecords.isEmpty {
                Text(apfsVaultText(
                    "Vault retention active: restoring uses clonefile() and keeps snapshots intact until you verify the target app and tap Release Vault.",
                    "暂存保护机制已开启：还原过程同样采用 clonefile() 克隆写回，不会自动删毁暂存舱备份；请先打开目标应用核对无误后再手动释放。"
                ))
            }
        }
    }

    private func stagedRecordCard(_ record: APFSStagingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(record.bundleID) · UUID: \(String(record.manifest.sourceContainerUUID.prefix(8)))…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    apfsVaultText("Verified", "已校验"),
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 10) {
                Text(AppContainerDirectoryHelper.formatBytes(record.logicalByteSize))
                    .font(.caption.weight(.semibold))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(apfsVaultText(
                    "\(record.fileCount) files / \(record.verifiedItemCount) items",
                    "\(record.fileCount) 个文件 / 共 \(record.verifiedItemCount) 项"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let wcCount = record.weChatAccountCount {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.badge.key.fill")
                    Text(wcCount > 0
                        ? apfsVaultText(
                            "Detected \(wcCount) WeChat MD5 account folder(s)",
                            "已识别 \(wcCount) 个微信账号数据目录 (32位MD5)"
                        )
                        : apfsVaultText(
                            "WeChat container detected (0 MD5 account folders)",
                            "微信容器已识别（暂未检测到已登录 32 位 MD5 账号目录）"
                        )
                    )
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(wcCount > 0 ? Color.teal : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((wcCount > 0 ? Color.teal : Color.orange).opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                ForEach(record.stagedSubdirectories, id: \.self) { sub in
                    Text(shortSubdirName(sub))
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }

            Text("\(apfsVaultText("Staged at", "暂存时间")): \(formatTimestamp(record.createdAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let restoredAt = record.lastRestoredAt {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text(apfsVaultText(
                        "Last restored to \(record.lastRestoredTargetBundleID ?? record.bundleID) at \(formatTimestamp(restoredAt)). Open app to verify before tapping Release Vault.",
                        "最近已还原至 \(record.lastRestoredTargetBundleID ?? record.bundleID) (\(formatTimestamp(restoredAt)))，请打开应用核验无误后再释放暂存舱。"
                    ))
                }
                .font(.caption2)
                .foregroundStyle(.blue)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    triggerRestoreToSameBundleID(record)
                } label: {
                    Label(
                        apfsVaultText("Restore Same ID", "还原至原包名"),
                        systemImage: "arrow.uturn.backward.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)

                Button {
                    showTargetPickerForRecord = record
                } label: {
                    Label(
                        apfsVaultText("Chosen Target...", "指定容器/多开"),
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(role: .destructive) {
                    activeAlert = .confirmRelease(record)
                } label: {
                    Label(
                        apfsVaultText("Release Vault", "释放暂存舱"),
                        systemImage: "trash.circle"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Section 3: Stage New App Container

    private var stageNewContainerSection: some View {
        Section {
            if stageableContainers.isEmpty {
                HStack(spacing: 8) {
                    Text(apfsVaultText("No eligible app containers loaded.", "暂无可暂存的应用容器列表"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(apfsVaultText("Scan", "扫描")) {
                        onRequestRescan?()
                    }
                    .font(.subheadline)
                }
            } else {
                Picker(apfsVaultText("Source App", "选择源应用"), selection: $selectedSourceID) {
                    ForEach(stageableContainers) { item in
                        Text("\(item.displayTitle) · \(AppContainerDirectoryHelper.formatBytes(item.saveDataSize))")
                            .tag(item.id)
                    }
                }

                if let selected = selectedSourceItem {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(apfsVaultText("Bundle ID", "应用包名")): \(selected.bundleID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(apfsVaultText("Container UUID", "容器 UUID")): \(selected.containerURL.lastPathComponent)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        if isLoadingWeChatPreview {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(apfsVaultText("Checking WeChat account folders...", "正在检测微信账号目录..."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let wcCount = sourceWeChatPreview {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2.badge.key.fill")
                                Text(wcCount > 0
                                    ? apfsVaultText(
                                        "Detected \(wcCount) WeChat MD5 account folder(s) ready to clone",
                                        "已检测到 \(wcCount) 个微信 32 位 MD5 账号数据目录"
                                    )
                                    : apfsVaultText(
                                        "WeChat container detected (0 MD5 account folders)",
                                        "检测到微信容器（暂未发现 32 位 MD5 账号目录）"
                                    )
                                )
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(wcCount > 0 ? .teal : .orange)
                        }
                    }
                    .padding(.vertical, 2)

                    Button {
                        initiateStaging(for: selected, weChatCount: sourceWeChatPreview)
                    } label: {
                        Label(
                            apfsVaultText(
                                "Stage Now via APFS clonefile()",
                                "立即执行 APFS 零空间暂存 (CoW)"
                            ),
                            systemImage: "bolt.shield.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
        } header: {
            HeaderLabel(
                apfsVaultText("Stage New App Container", "新建应用暂存快照"),
                symbol: "externaldrive.fill.badge.plus"
            )
        } footer: {
            Text(apfsVaultText(
                "Stages Documents, Library/Application Support, and Library/Preferences via kernel clonefile(src, dst, 0). Source app files are NEVER deleted or modified.",
                "通过内核级 clonefile(src, dst, 0) 克隆 Documents、Library/Application Support 与 Library/Preferences，绝不修改或删除源容器任何文件。"
            ))
        }
    }

    // MARK: - Section 4: 5-Layer Architecture Summary

    private var foolproofLayersSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                layerRow("1", apfsVaultText("Certificate Expiry Gate (<24h warning)", "签名证书门禁（不足 24h 强提醒先在 SideStore/AltStore 续签）"))
                layerRow("2", apfsVaultText("Active SQLite WAL Lock Check (<=10s)", "活跃 SQLite WAL 写入锁拦截（检测 10 秒内修改的 -wal 文件）"))
                layerRow("3", apfsVaultText("Copy-Never-Move CoW clonefile()", "只克隆不移动（clonefile 写时复制，绝不破坏源容器）"))
                layerRow("4", apfsVaultText("manifest.json Item Count Verification", "manifest.json 清单校验（逐项核对文件总数与逻辑大小）"))
                layerRow("5", apfsVaultText("Atomic .bak Swap, Plist Adaptation & Retention", ".erosion_pre_restore_bak 原子回滚 + 跨包名 .plist 映射 + 手动释放防呆"))
            }
            .padding(.vertical, 2)
        } header: {
            HeaderLabel(
                apfsVaultText("5-Layer Foolproof Safeguards", "五重防呆保护机制"),
                symbol: "shield.lefthalf.filled"
            )
        }
    }

    private func layerRow(_ index: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions & Workflows

    private func refreshWeChatPreviewIfNeeded() {
        guard let selected = selectedSourceItem else {
            sourceWeChatPreview = nil
            return
        }
        isLoadingWeChatPreview = true
        let targetID = selected.id
        Task {
            let count = await vault.inspectWeChatAccounts(in: selected)
            if selectedSourceItem?.id == targetID {
                sourceWeChatPreview = count
                isLoadingWeChatPreview = false
            }
        }
    }

    private func initiateStaging(for item: AppSaveContainerItem, weChatCount: Int?) {
        let cert = vault.refreshCertificateStatus()
        if cert.requiresUrgentResignWarning {
            activeAlert = .certGateWarning(cert, item)
        } else {
            activeAlert = .confirmStage(item, weChatCount)
        }
    }

    private func executeStage(_ item: AppSaveContainerItem) {
        Task {
            do {
                let outcome = try await vault.stageContainer(item)
                let wcNote: String
                if let wc = outcome.weChatAccountCount {
                    wcNote = apfsVaultText(
                        "\nWeChat MD5 account folders detected: \(wc)",
                        "\n已检测到微信 MD5 账号目录：\(wc) 个"
                    )
                } else {
                    wcNote = ""
                }
                activeAlert = .info(
                    title: apfsVaultText("Staged Successfully", "零空间暂存成功！"),
                    message: apfsVaultText(
                        "Verified \(outcome.record.verifiedItemCount) items (\(outcome.record.fileCount) files, \(AppContainerDirectoryHelper.formatBytes(outcome.record.logicalByteSize))) in manifest.json.\(wcNote)\n\nYou may now safely uninstall/reinstall the app, then return here to restore.",
                        "已通过 manifest.json 核验 \(outcome.record.verifiedItemCount) 项（\(outcome.record.fileCount) 个文件，逻辑体积 \(AppContainerDirectoryHelper.formatBytes(outcome.record.logicalByteSize))）。\(wcNote)\n\n现在可以安全卸载并重装目标应用（重装后请先打开一次），再回到此处还原。"
                    )
                )
            } catch {
                activeAlert = .info(
                    title: apfsVaultText("Staging Blocked / Failed", "暂存已拦截或失败"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func triggerRestoreToSameBundleID(_ record: APFSStagingRecord) {
        Task {
            let resolved = await vault.resolveLatestTargetContainer(forBundleID: record.bundleID)
            guard let target = resolved else {
                activeAlert = .info(
                    title: apfsVaultText("Target Container Not Found", "未找到目标应用容器"),
                    message: apfsVaultText(
                        "No installed container was found for \"\(record.bundleID)\". Install the app and launch it once so iOS initializes its new Data container, then tap Restore again (or choose a different Target Container).",
                        "未检测到「\(record.bundleID)」的数据容器。请确认已安装新应用并至少启动过一次以初始化容器目录，然后再点还原（或选择“指定容器/多开”恢复至其他包名）。"
                    )
                )
                return
            }
            activeAlert = .confirmRestore(record, target)
        }
    }

    private func executeRestore(record: APFSStagingRecord, target: AppSaveContainerItem) {
        Task {
            do {
                let outcome = try await vault.restoreRecord(
                    record,
                    toTargetContainerURL: target.containerURL,
                    targetBundleID: target.bundleID
                )
                postRestoreOutcome = outcome
            } catch {
                activeAlert = .info(
                    title: apfsVaultText("Restore Blocked / Failed", "还原已拦截或失败"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func executeRelease(_ record: APFSStagingRecord) {
        do {
            try vault.releaseRecord(record)
        } catch {
            activeAlert = .info(
                title: apfsVaultText("Release Failed", "释放暂存舱失败"),
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Alert Builders

    private func alertTitle(for alert: StagingAlertType?) -> String {
        guard let alert else { return "" }
        switch alert {
        case .certGateWarning:
            return apfsVaultText(
                "Certificate Expiring Soon — Re-sign First!",
                "高危预警：签名剩余不足 24 小时！"
            )
        case .confirmStage(let item, _):
            return apfsVaultText("Stage \(item.displayTitle)?", "确认零空间暂存「\(item.displayTitle)」？")
        case .confirmRestore(_, let target):
            return apfsVaultText("Restore to \(target.bundleID)?", "确认还原至「\(target.bundleID)」？")
        case .confirmRelease(let record):
            return apfsVaultText("Release Vault for \(record.bundleID)?", "确认释放「\(record.bundleID)」暂存舱？")
        case .info(let title, _):
            return title
        }
    }

    private func alertMessage(for alert: StagingAlertType) -> String {
        switch alert {
        case .certGateWarning(let info, _):
            return apfsVaultText(
                "Profile \"\(info.profileName)\" status: \(info.remainingDisplayText).\n\nIf Erosion's sideload certificate expires while your app data is staged inside Erosion, you will NOT be able to open Erosion to restore it!\n\nStrongly recommended: refresh/re-sign Erosion in SideStore or AltStore BEFORE staging and uninstalling the old app.",
                "当前签名描述文件「\(info.profileName)」状态：\(info.remainingDisplayText)。\n\n如果在数据暂存期间 Erosion 签名到期，系统将无法打开 Erosion 来还原你的应用数据！\n\n强烈建议：先前往 SideStore / AltStore 为 Erosion 续签，然后再执行暂存与卸载旧应用操作。"
            )
        case .confirmStage(let item, let wcCount):
            let wcStr = wcCount.map {
                apfsVaultText("\n• Detected \($0) WeChat account folder(s)", "\n• 已识别 \($0) 个微信 MD5 账号目录")
            } ?? ""
            return apfsVaultText(
                "Swipe-close \"\(item.bundleID)\" from the iOS App Switcher before continuing (Layer 2 will block if SQLite WAL was modified in the last 10s).\n• Zero-space CoW clonefile() only — source container is untouched\(wcStr)",
                "继续前请先从 iOS 后台多任务上滑彻底关闭「\(item.bundleID)」（第 2 层防呆将拦截 10 秒内活跃写入的 WAL 数据库）。\n• 全程仅执行零空间只读 CoW clonefile()，绝不改动或删除源应用数据\(wcStr)"
            )
        case .confirmRestore(let record, let target):
            let plistHint = record.bundleID.caseInsensitiveCompare(target.bundleID) != .orderedSame
                ? apfsVaultText(
                    "\n• Bundle IDs differ: Preferences/\(record.bundleID).plist will be adapted to \(target.bundleID).plist",
                    "\n• 检测到跨包名还原：将自动复制适配 \(record.bundleID).plist → \(target.bundleID).plist"
                )
                : ""
            return apfsVaultText(
                "Swipe-close \"\(target.bundleID)\" from the iOS App Switcher first!\n• Existing target Documents, Application Support & Preferences will be safely backed up to .erosion_pre_restore_bak during atomic swap (auto-rollback on error)\n• Staging Vault copy stays intact after restore\(plistHint)",
                "还原前请务必先从后台上滑彻底关闭「\(target.bundleID)」！\n• 将先把目标容器现有目录安全移至 .erosion_pre_restore_bak 暂避，异常时自动回滚\n• 还原后暂存舱内的备份依然保留，直到你验证后手动释放\(plistHint)"
            )
        case .confirmRelease(let record):
            if record.lastRestoredAt == nil {
                return apfsVaultText(
                    "WARNING: This snapshot has NOT been restored yet! Releasing it will permanently delete the staged snapshot from Erosion's APFSStagingVault.",
                    "警告：该暂存快照尚未执行过还原操作！释放暂存舱将永久删除 Erosion 内的该快照副本（若原应用已被卸载将无法恢复）。"
                )
            }
            return apfsVaultText(
                "Have you already opened the restored app and verified all chats, saves, and settings?\n\nOnce released, the staged snapshot in APFSStagingVault will be removed.",
                "请确认你已经打开目标应用并核对聊天记录、游戏存档与配置均已正常生效。\n\n确认释放后，暂存舱中的该快照将被清除。"
            )
        case .info(_, let message):
            return message
        }
    }

    @ViewBuilder
    private func alertActions(for alert: StagingAlertType) -> some View {
        switch alert {
        case .certGateWarning(_, let item):
            Button(apfsVaultText("Cancel & Refresh First (Recommended)", "取消并先去续签 (推荐)"), role: .cancel) {}
            if let item {
                Button(apfsVaultText("I Understand Risk, Stage Anyway", "已知风险，仍要继续暂存"), role: .destructive) {
                    let previewCount = sourceWeChatPreview
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        activeAlert = .confirmStage(item, previewCount)
                    }
                }
            }
        case .confirmStage(let item, _):
            Button(apfsVaultText("Cancel", "取消"), role: .cancel) {}
            Button(apfsVaultText("Stage Now", "确认暂存")) {
                executeStage(item)
            }
        case .confirmRestore(let record, let target):
            Button(apfsVaultText("Cancel", "取消"), role: .cancel) {}
            Button(apfsVaultText("Restore Now", "确认原子还原")) {
                executeRestore(record: record, target: target)
            }
        case .confirmRelease(let record):
            Button(apfsVaultText("Keep Snapshot", "暂不释放"), role: .cancel) {}
            Button(apfsVaultText("Release Vault", "确认释放暂存舱"), role: .destructive) {
                executeRelease(record)
            }
        case .info:
            Button(apfsVaultText("OK", "确定"), role: .cancel) {}
        }
    }

    // MARK: - Formatting Helpers

    private func certStatusColor(_ status: ProvisioningCertInfo.Status) -> Color {
        switch status {
        case .valid: return .green
        case .expiringSoon, .expired: return .red
        case .notEmbedded, .parseFailed: return .secondary
        }
    }

    private func shortSubdirName(_ sub: String) -> String {
        switch sub {
        case "Library/Application Support": return "App Support"
        case "Library/Preferences": return "Preferences"
        default: return sub
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        fmt.locale = LocalizationManager.effectiveLocale
        return fmt.string(from: date)
    }
}

// MARK: - Target Container Picker (Same or Different Bundle ID / Multi-Instance)

private struct TargetContainerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let record: APFSStagingRecord
    @Binding var containers: [AppSaveContainerItem]
    var onRequestRescan: (() -> Void)?
    let onSelectTarget: (AppSaveContainerItem) -> Void

    @State private var searchText = ""
    @State private var includeAppleApps = false
    @State private var isRefreshing = false

    private var filteredTargets: [AppSaveContainerItem] {
        let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
        let eligible = containers.filter { item in
            guard item.bundleID != selfBID,
                  !APFSStagingEngine.protectedBundleIDs.contains(item.bundleID) else {
                return false
            }
            if !includeAppleApps && item.bundleID.hasPrefix("com.apple.") {
                return false
            }
            return true
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return eligible }
        return eligible.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            $0.bundleID.localizedCaseInsensitiveContains(trimmed) ||
            $0.containerURL.lastPathComponent.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PlainToggle(
                        apfsVaultText("Include System Apps (com.apple.*)", "显示系统应用容器 (com.apple.*)"),
                        subtitle: apfsVaultText("Usually only third-party / clone apps should be targeted", "通常仅应向第三方应用或多开分身容器还原"),
                        isOn: $includeAppleApps
                    )
                }

                Section {
                    if isRefreshing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(apfsVaultText("Refreshing installed containers...", "正在重新扫描本机应用容器..."))
                                .foregroundStyle(.secondary)
                        }
                    } else if filteredTargets.isEmpty {
                        Text(apfsVaultText("No matching target containers found.", "未找到符合条件的目标容器"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredTargets) { item in
                            Button {
                                onSelectTarget(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.displayTitle)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        if item.bundleID.caseInsensitiveCompare(record.bundleID) == .orderedSame {
                                            Text(apfsVaultText("Same ID", "同包名"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.green)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.14), in: Capsule())
                                        } else {
                                            Text(apfsVaultText("Cross-ID", "跨包名适配"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.blue)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.14), in: Capsule())
                                        }
                                    }
                                    Text("UUID: \(item.containerURL.lastPathComponent)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } header: {
                    HeaderLabel(
                        apfsVaultText("Choose Target Container", "选择目标还原容器"),
                        symbol: "app.badge.checkmark"
                    )
                } footer: {
                    Text(apfsVaultText(
                        "If you just installed a new version or multi-instance clone, open it once first, then tap Refresh in the top right. Selecting a different Bundle ID automatically copies \(record.bundleID).plist to <targetBundleID>.plist.",
                        "如果是刚重装或新装的多开分身应用，请先打开一次再点右上角刷新扫描。若选择不同包名，将自动适配复制 \(record.bundleID).plist → <目标包名>.plist。"
                    ))
                }
            }
            .searchable(
                text: $searchText,
                prompt: apfsVaultText("Search app name, Bundle ID, or UUID", "搜索应用名、Bundle ID 或容器 UUID")
            )
            .navigationTitle(apfsVaultText("Target Container", "选择目标容器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(apfsVaultText("Cancel", "取消")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshFreshContainers()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
        }
    }

    private func refreshFreshContainers() {
        isRefreshing = true
        let wantSystem = includeAppleApps
        DispatchQueue.global(qos: .userInitiated).async {
            CSStoreEngine.shared.invalidate()
            let rawPaths = fsHandlers.getDirPaths(FSURL.appContainers.path, forceRefresh: true)
            let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
            var discovered: [AppSaveContainerItem] = []

            for rawPath in rawPaths {
                let url = URL(fileURLWithPath: rawPath)
                guard let bid = getBIDFromXattr(url),
                      !bid.isEmpty,
                      bid != selfBID,
                      !APFSStagingEngine.protectedBundleIDs.contains(bid) else { continue }
                if !wantSystem && bid.hasPrefix("com.apple.") { continue }

                discovered.append(AppSaveContainerItem(
                    id: url.lastPathComponent,
                    bundleID: bid,
                    displayTitle: AppContainerDirectoryHelper.displayName(for: bid),
                    containerURL: url,
                    saveDataSize: 0
                ))
            }
            discovered.sort { $0.bundleID.localizedStandardCompare($1.bundleID) == .orderedAscending }
            DispatchQueue.main.async {
                if !discovered.isEmpty {
                    containers = discovered
                }
                onRequestRescan?()
                isRefreshing = false
            }
        }
    }
}

// MARK: - Layer 5 Post-Restore Guide Sheet

private struct APFSPostRestoreGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    let outcome: APFSRestoreOutcome

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(apfsVaultText("Atomic Restore Completed", "原子写回还原成功！"))
                                .font(.headline)
                            Text(apfsVaultText(
                                "Restored \(outcome.restoredItemCount) items (\(outcome.restoredFileCount) files, \(AppContainerDirectoryHelper.formatBytes(outcome.restoredBytes))) into \(outcome.targetBundleID).",
                                "已通过 APFS clonefile() 成功将 \(outcome.restoredItemCount) 项（\(outcome.restoredFileCount) 个文件，\(AppContainerDirectoryHelper.formatBytes(outcome.restoredBytes))）还原至 \(outcome.targetBundleID)。"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if outcome.adaptedPreferencesPlist {
                        Label(
                            apfsVaultText(
                                "Preferences adapted: \(outcome.sourceBundleID).plist → \(outcome.targetBundleID).plist",
                                "已自动适配跨包名配置：\(outcome.sourceBundleID).plist → \(outcome.targetBundleID).plist"
                            ),
                            systemImage: "doc.badge.gearshape"
                        )
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }

                    if let wc = outcome.weChatAccountCount {
                        Label(
                            apfsVaultText(
                                "WeChat MD5 account folders restored: \(wc)",
                                "微信 32 位 MD5 账号数据目录已还原：\(wc) 个"
                            ),
                            systemImage: "person.2.badge.key.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.teal)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            apfsVaultText("1. Keychain Re-Login Required", "1. 关于钥匙串 (Keychain) 重新登录"),
                            systemImage: "key.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                        Text(apfsVaultText(
                            "iOS Keychain credentials are cryptographically bound to the app's signing Team ID / Bundle ID and cannot be migrated via container files. Re-logging in on first launch is normal — your local chat history, game saves, and files are preserved.",
                            "由于 iOS Keychain 凭据绑定了原签名团队/包名，换签重装或跨多开还原后首次启动通常需要重新输入账号密码登录（登录态无法迁移，但本地聊天记录、游戏存档与本地数据均已完整保留）。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            apfsVaultText("2. Verify Before Tapping \"Release Vault\"", "2. 验证数据后再手动“释放暂存舱”"),
                            systemImage: "lock.open.trianglebadge.exclamationmark"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)

                        Text(apfsVaultText(
                            "Your snapshot is still safely kept inside Erosion's APFSStagingVault (and temporary .erosion_pre_restore_bak was cleaned up). Please launch the target app, verify all data is intact, and ONLY THEN return here to manually tap \"Release Vault\".",
                            "暂存舱内的快照副本仍为您保留（目标容器中的 .erosion_pre_restore_bak 临时目录已清理）。请先打开目标应用确认所有聊天记录/存档完好无损后，再回到暂存舱界面手动点击「释放暂存舱」。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    HeaderLabel(
                        apfsVaultText("Important Post-Restore Steps", "还原后必读指引"),
                        symbol: "info.circle.fill"
                    )
                }

                Section {
                    Button {
                        openApp(withBID: outcome.targetBundleID)
                    } label: {
                        Label(
                            apfsVaultText("Open Target App to Verify", "立即打开目标应用核验数据"),
                            systemImage: "arrow.up.forward.app.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .navigationTitle(apfsVaultText("Restore Complete", "还原完成指引"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(apfsVaultText("Done", "完成")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
