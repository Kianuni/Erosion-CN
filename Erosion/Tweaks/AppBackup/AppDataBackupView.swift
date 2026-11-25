//
//  AppDataBackupView.swift
//  Erosion
//
//  Third-party App & Game save backup, restore, and direct Plist/JSON editor launcher.
//

import SwiftUI
import ZIPFoundation
import UniformTypeIdentifiers

enum AppContainerDirectoryHelper {
    static let knownAppNames: [String: String] = [
        "com.tencent.xin": "微信",
        "com.tencent.mqq": "QQ",
        "com.ss.iphone.ugc.Aweme": "抖音",
        "tv.danmaku.bilianime": "哔哩哔哩",
        "com.xingin.discover": "小红书",
        "com.taobao.taobao4iphone": "淘宝",
        "com.alipay.iphoneclient": "支付宝",
        "com.360buy.jdmobile": "京东",
        "com.jingdong.app.mall": "京东",
        "com.meituan.imeituan": "美团",
        "com.dianping.dpscope": "大众点评",
        "cn.10086.app": "中国移动",
        "com.tencent.live4iphone": "腾讯视频",
        "com.dragon.read": "番茄小说",
        "ctrip.com": "携程旅行",
        "ctrip.wireless": "携程旅行",
        "com.netease.cloudmusic": "网易云音乐",
        "com.tencent.QQMusic": "QQ音乐",
        "com.zhihu.ios": "知乎",
        "com.sina.weibo": "微博",
        "com.baidu.BaiduMobile": "百度",
        "com.autonavi.amap": "高德地图",
        "com.smzdm.client.ios": "什么值得买",
        "com.tencent.smoba": "王者荣耀",
        "com.tencent.tmgp.pubgmhd": "和平精英",
        "com.tencent.jkchess": "金铲铲之战",
        "com.miHoYo.Yuanshen": "原神",
        "com.miHoYo.GenshinImpact": "原神 (国际服)",
        "com.miHoYo.hkrpg": "崩坏：星穹铁道",
        "com.miHoYo.Nap": "绝区零",
        "com.hypergryph.arknights": "明日方舟",
        "com.chucklefish.stardewvalley": "星露谷物语",
        "com.and.games505.TerrariaPaid": "泰拉瑞亚",
        "com.mojang.minecraftpe": "我的世界 (Minecraft)",
        "com.popcap.ios.PvZ2": "植物大战僵尸 2",
        "com.SoulGame.SoulKnight": "元气骑士",
        "com.locojoy.balatro": "小丑牌 (Balatro)",
        "com.NSSurge.inc.surge-ios": "Surge",
        "com.luo.quantumult-x": "Quantumult X",
        "com.liguangming.Shadowrocket": "Shadowrocket",
        "org.telegram.Telegram-iOS": "Telegram",
        "com.burbn.instagram": "Instagram",
        "com.atebits.Tweetie2": "X (Twitter)",
        "com.google.ios.youtube": "YouTube",
        "com.openai.chat": "ChatGPT",
        "com.apple.mobilesafari": "Safari 浏览器",
        "com.apple.Music": "Apple 音乐",
        "com.apple.DocumentsApp": "文件"
    ]

    static func displayName(for bundleID: String) -> String {
        if let known = knownAppNames[bundleID]?.loc {
            return "\(known) (\(bundleID))"
        }
        if let csName = CSStoreEngine.shared.localizedName(forBundleID: bundleID),
           !csName.isEmpty, csName != bundleID {
            return "\(csName) (\(bundleID))"
        }
        return bundleID
    }

    static func directorySize(at url: URL, maxDepth: Int = 6, currentDepth: Int = 0) -> Int64 {
        guard currentDepth <= maxDepth else { return 0 }
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        for name in names {
            let childPath = (url.path as NSString).appendingPathComponent(name)
            var st = stat()
            if lstat(childPath, &st) == 0 {
                let mode = st.st_mode & S_IFMT
                if mode == S_IFREG {
                    total += Int64(st.st_size)
                } else if mode == S_IFDIR {
                    total += directorySize(at: URL(fileURLWithPath: childPath), maxDepth: maxDepth, currentDepth: currentDepth + 1)
                }
            }
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }
}

struct AppSaveContainerItem: Identifiable {
    let id: String
    let bundleID: String
    let displayTitle: String
    let containerURL: URL
    let saveDataSize: Int64
}

struct LocalSaveBackupItem: Identifiable {
    let id: String
    let fileURL: URL
    let bundleID: String
    let createdAt: Date
    let fileSize: Int64
}

struct AppDataBackupView: View {
    @ObservedObject private var stagingVault = APFSStagingVault.shared
    @State private var isScanning = false
    @State private var scanProgressText = L("正在扫描本机应用数据容器...")
    @State private var containers: [AppSaveContainerItem] = []
    @State private var backups: [LocalSaveBackupItem] = []
    @State private var searchText = ""
    @State private var includeSystemApps = false
    @State private var showBackupImporter = false
    @State private var showStagingSheet = false
    @State private var showVaultGuide = false
    @State private var quickStageAlert: QuickStageAlert?

    private enum QuickStageAlert: Identifiable {
        case certGate(ProvisioningCertInfo, AppSaveContainerItem, Int?)
        case confirmStage(AppSaveContainerItem, Int?)
        case stageSucceeded(APFSStageOutcome)
        case stageError(String)

        var id: String {
            switch self {
            case .certGate(_, let item, _): return "qcert_\(item.id)"
            case .confirmStage(let item, _): return "qconfirm_\(item.id)"
            case .stageSucceeded(let out): return "qok_\(out.record.id)"
            case .stageError(let msg): return "qerr_\(msg.prefix(24))"
            }
        }
    }

    private static let backupsRootURL = URL.documentsDirectory.appendingPathComponent("AppDataBackups")

    private var filteredContainers: [AppSaveContainerItem] {
        let base = includeSystemApps
            ? containers
            : containers.filter { !$0.bundleID.hasPrefix("com.apple.") }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "externaldrive.badge.timemachine")
                                .font(.title2)
                                .foregroundStyle(stagingVault.activeStagedItemsCount > 0 ? Color.orange : Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(apfsVaultText(
                                    "APFS Zero-Space App Swap Vault",
                                    "APFS 零空间极速暂存舱 (换签/重装专享)"
                                ))
                                .font(.headline)
                                Text(apfsVaultText(
                                    "Clone Documents, Application Support & Preferences via kernel CoW clonefile() with 5-layer foolproofing — zero double storage cost.",
                                    "通过内核级 CoW clonefile() 五重防呆瞬间暂存应用全部核心目录，无需翻倍磁盘空间即可安全重装、换签或多开搬家。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        if stagingVault.activeStagedItemsCount > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(apfsVaultText(
                                    "\(stagingVault.activeStagedItemsCount) staged snapshot(s) active — Do NOT uninstall Erosion until restored & verified!",
                                    "当前有 \(stagingVault.activeStagedItemsCount) 个快照在暂存舱等待还原，释放前切勿卸载 Erosion！"
                                ))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                        }

                        HStack(spacing: 8) {
                            Image(systemName: stagingVault.certInfo.requiresUrgentResignWarning ? "exclamationmark.shield.fill" : "signature")
                                .foregroundStyle(stagingVault.certInfo.requiresUrgentResignWarning ? .red : .secondary)
                            Text(stagingVault.certInfo.remainingDisplayText)
                                .font(.caption)
                                .foregroundStyle(stagingVault.certInfo.requiresUrgentResignWarning ? .red : .secondary)
                        }

                        Button {
                            showStagingSheet = true
                        } label: {
                            HStack {
                                Label(
                                    stagingVault.activeStagedItemsCount > 0
                                        ? apfsVaultText(
                                            "Open APFS Swap Vault (\(stagingVault.activeStagedItemsCount) Active)",
                                            "打开 APFS 暂存舱管理台 (\(stagingVault.activeStagedItemsCount) 个待还原)"
                                        )
                                        : apfsVaultText(
                                            "Open APFS Swap Vault",
                                            "打开 APFS 零空间暂存舱"
                                        ),
                                    systemImage: "bolt.shield.fill"
                                )
                                .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }

                        Divider()

                        Button {
                            showVaultGuide = true
                        } label: {
                            HStack {
                                Label(
                                    apfsVaultText(
                                        "Usage Guide: 6-Step Swap & Cross-App Migration",
                                        "使用说明：无损重装换签与多开搬家步骤"
                                    ),
                                    systemImage: "book.pages.fill"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                } header: {
                    HeaderLabel(
                        apfsVaultText("APFS Zero-Space Swap Vault", "APFS 零空间暂存舱"),
                        symbol: "bolt.shield.fill"
                    )
                }

                Section {
                    HStack {
                        Button {
                            showBackupImporter = true
                        } label: {
                            Label("导入外部备份包 (.zip)", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                        Button {
                            scanAllContainers(forceRefresh: true)
                        } label: {
                            Label("刷新列表", systemImage: "arrow.clockwise")
                        }
                        .disabled(isScanning)
                    }
                    PlainToggle(
                        L("显示系统内置应用容器 (com.apple.*)"),
                        subtitle: L("默认仅展示第三方应用与游戏容器"),
                        isOn: $includeSystemApps
                    )
                } header: {
                    HeaderLabel(L("备份与筛选控制"), symbol: "slider.horizontal.3")
                }

                if !backups.isEmpty {
                    Section {
                        ForEach(backups) { backup in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(AppContainerDirectoryHelper.displayName(for: backup.bundleID))
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(AppContainerDirectoryHelper.formatBytes(backup.fileSize))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(backup.fileURL.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 14) {
                                    Button {
                                        Alertinator.shared.alert(
                                            title: L("确定还原此存档备份吗？"),
                                            body: L("将把 \(backup.fileURL.lastPathComponent) 中的 Documents 与 Preferences 存档还原至「\(backup.bundleID)」当前容器（自动匹配重装后的最新容器 UUID）。还原前请先在后台关闭目标应用！"),
                                            actionLabel: L("确认还原"),
                                            action: {
                                                restoreBackup(backup)
                                            }
                                        )
                                    } label: {
                                        Label("一键还原", systemImage: "arrow.uturn.backward.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)

                                    Button {
                                        presentShareSheet(with: backup.fileURL)
                                    } label: {
                                        Label("导出分享", systemImage: "square.and.arrow.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)

                                    Spacer()

                                    Button(role: .destructive) {
                                        deleteBackup(backup)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        HeaderLabel(L("本地已保存的存档备份 (\(backups.count))"), symbol: "archivebox.fill")
                    } footer: {
                        Text("即使卸载重装了游戏或应用导致容器 UUID 改变，点击“一键还原”也会按 Bundle ID 自动定位当前最新容器并原位写回存档。")
                    }
                }

                Section {
                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(scanProgressText)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if filteredContainers.isEmpty {
                        Text("未找到匹配的应用数据容器")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredContainers) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.displayTitle)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(AppContainerDirectoryHelper.formatBytes(item.saveDataSize))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("容器 UUID: \(item.containerURL.lastPathComponent)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 14) {
                                    Button {
                                        startQuickStage(for: item)
                                    } label: {
                                        Label(
                                            apfsVaultText("APFS Stage", "APFS 极速暂存"),
                                            systemImage: "bolt.shield.fill"
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(stagingVault.isBusy)

                                    Button {
                                        backupContainer(item)
                                    } label: {
                                        Label("备份存档", systemImage: "externaldrive.badge.plus")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.top, 2)

                                HStack(spacing: 10) {
                                    NavigationLink {
                                        ContainerSubdirBrowserView(containerURL: item.containerURL, relativeSubpath: "Documents")
                                    } label: {
                                        Label(
                                            apfsVaultText("Documents", "文档目录"),
                                            systemImage: "folder.badge.gearshape"
                                        )
                                        .font(.caption)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    }
                                    .buttonStyle(.borderless)

                                    NavigationLink {
                                        ContainerSubdirBrowserView(containerURL: item.containerURL, relativeSubpath: "Library/Preferences")
                                    } label: {
                                        Label(
                                            apfsVaultText("Preferences", "偏好配置"),
                                            systemImage: "doc.text.magnifyingglass"
                                        )
                                        .font(.caption)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    }
                                    .buttonStyle(.borderless)

                                    NavigationLink {
                                        ContainerSubdirBrowserView(containerURL: item.containerURL, relativeSubpath: nil)
                                    } label: {
                                        Label(
                                            apfsVaultText("Full Container", "完整目录"),
                                            systemImage: "folder"
                                        )
                                        .font(.caption)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.top, 1)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    HeaderLabel(L("应用与游戏存档列表 (\(filteredContainers.count))"), symbol: "gamecontroller.fill")
                } footer: {
                    Text(apfsVaultText(
                        "Tap \"APFS Stage\" for zero-space same-device app swap; tap \"Backup Save\" to archive Documents & Preferences as ZIP; tap \"Documents\" or \"Preferences\" to edit game saves or configs.",
                        "点击“APFS 极速暂存”适合本机换签重装与微信/大应用搬家；点击“备份存档”将打包为 ZIP；点击“文档目录”或“偏好配置”可调用内置无损 Plist/文本编辑器修改存档数值或配置。"
                    ))
                }
            }

            if stagingVault.isBusy && !showStagingSheet {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(stagingVault.busyMessage)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 32)
            }
        }
        .navigationTitle("应用与游戏存档管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showVaultGuide = true
                } label: {
                    Label(apfsVaultText("Guide", "使用说明"), systemImage: "questionmark.circle")
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索应用名称或 Bundle ID")
        .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.zip, .item]) { result in
            handleImportBackup(result)
        }
        .sheet(isPresented: $showVaultGuide) {
            APFSVaultGuideSheet()
        }
        .sheet(isPresented: $showStagingSheet, onDismiss: {
            stagingVault.reloadRecords()
        }) {
            APFSStagingSheet(
                containers: $containers,
                onRequestRescan: {
                    scanAllContainers(forceRefresh: true)
                }
            )
        }
        .alert(
            quickStageAlertTitle(for: quickStageAlert),
            isPresented: Binding(
                get: { quickStageAlert != nil },
                set: { if !$0 { quickStageAlert = nil } }
            ),
            presenting: quickStageAlert
        ) { alertItem in
            quickStageAlertActions(for: alertItem)
        } message: { alertItem in
            Text(quickStageAlertMessage(for: alertItem))
        }
        .onChange(of: includeSystemApps) {
            if includeSystemApps && !containers.contains(where: { $0.bundleID.hasPrefix("com.apple.") }) && !isScanning {
                scanAllContainers()
            }
        }
        .onAppear {
            loadLocalBackups()
            stagingVault.refreshCertificateStatus()
            stagingVault.reloadRecords()
            if containers.isEmpty && !isScanning {
                scanAllContainers()
            }
        }
    }

    private func startQuickStage(for item: AppSaveContainerItem) {
        let cert = stagingVault.refreshCertificateStatus()
        Task {
            let wcCount = await stagingVault.inspectWeChatAccounts(in: item)
            if cert.requiresUrgentResignWarning {
                quickStageAlert = .certGate(cert, item, wcCount)
            } else {
                quickStageAlert = .confirmStage(item, wcCount)
            }
        }
    }

    private func executeQuickStage(_ item: AppSaveContainerItem) {
        Task {
            do {
                let outcome = try await stagingVault.stageContainer(item)
                quickStageAlert = .stageSucceeded(outcome)
            } catch {
                quickStageAlert = .stageError(error.localizedDescription)
            }
        }
    }

    private func quickStageAlertTitle(for alert: QuickStageAlert?) -> String {
        guard let alert else { return "" }
        switch alert {
        case .certGate:
            return apfsVaultText(
                "Certificate Expiring Soon — Re-sign First!",
                "高危预警：签名剩余不足 24 小时！"
            )
        case .confirmStage(let item, _):
            return apfsVaultText("APFS Stage \(item.displayTitle)?", "确认 APFS 零空间暂存「\(item.displayTitle)」？")
        case .stageSucceeded:
            return apfsVaultText("Staged to APFS Vault!", "APFS 零空间暂存成功！")
        case .stageError:
            return apfsVaultText("Staging Blocked / Failed", "APFS 暂存已拦截或失败")
        }
    }

    private func quickStageAlertMessage(for alert: QuickStageAlert) -> String {
        switch alert {
        case .certGate(let cert, let item, _):
            return apfsVaultText(
                "Profile \"\(cert.profileName)\" status: \(cert.remainingDisplayText).\n\nRefresh/re-sign Erosion in SideStore or AltStore BEFORE staging \"\(item.bundleID)\" and uninstalling the old app!",
                "描述文件「\(cert.profileName)」状态：\(cert.remainingDisplayText)。\n\n强烈建议先前往 SideStore / AltStore 续签 Erosion，再暂存「\(item.bundleID)」并卸载旧应用，避免无法打开 Erosion 还原数据！"
            )
        case .confirmStage(let item, let wcCount):
            let wcNote = wcCount.map {
                apfsVaultText("\n• Detected \($0) WeChat MD5 account folder(s)", "\n• 已识别 \($0) 个微信 MD5 账号数据目录")
            } ?? ""
            return apfsVaultText(
                "Swipe-close \"\(item.bundleID)\" from the iOS App Switcher first (Layer 2 blocks if SQLite WAL was modified in the last 10s).\n• Clones Documents, Application Support & Preferences via CoW clonefile() without modifying source files\(wcNote)",
                "请先从 iOS 后台上滑彻底关闭「\(item.bundleID)」（第 2 层防呆将拦截 10 秒内活跃写入的 WAL 数据库）。\n• 仅执行 CoW clonefile() 零空间克隆，绝不修改源容器\(wcNote)"
            )
        case .stageSucceeded(let outcome):
            let wcNote = outcome.weChatAccountCount.map {
                apfsVaultText("\nWeChat MD5 account folders detected: \($0)", "\n已识别微信 MD5 账号目录：\($0) 个")
            } ?? ""
            return apfsVaultText(
                "Verified \(outcome.record.verifiedItemCount) items (\(outcome.record.fileCount) files, \(AppContainerDirectoryHelper.formatBytes(outcome.record.logicalByteSize))).\(wcNote)\n\nOpen the APFS Swap Vault to restore after reinstalling or switching Bundle IDs.",
                "已通过 manifest.json 核验 \(outcome.record.verifiedItemCount) 项（\(outcome.record.fileCount) 个文件，\(AppContainerDirectoryHelper.formatBytes(outcome.record.logicalByteSize))）。\(wcNote)\n\n重装或更换多开包名后，点击顶部「打开 APFS 暂存舱」即可还原。"
            )
        case .stageError(let msg):
            return msg
        }
    }

    @ViewBuilder
    private func quickStageAlertActions(for alert: QuickStageAlert) -> some View {
        switch alert {
        case .certGate(_, let item, let wcCount):
            Button(apfsVaultText("Cancel & Refresh First (Recommended)", "取消并先去续签 (推荐)"), role: .cancel) {}
            Button(apfsVaultText("I Understand Risk, Continue", "已知风险，继续暂存"), role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    quickStageAlert = .confirmStage(item, wcCount)
                }
            }
        case .confirmStage(let item, _):
            Button(apfsVaultText("Cancel", "取消"), role: .cancel) {}
            Button(apfsVaultText("Stage Now", "确认暂存")) {
                executeQuickStage(item)
            }
        case .stageSucceeded:
            Button(apfsVaultText("Open Vault", "打开暂存舱")) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    showStagingSheet = true
                }
            }
            Button(apfsVaultText("OK", "确定"), role: .cancel) {}
        case .stageError:
            Button(apfsVaultText("OK", "确定"), role: .cancel) {}
        }
    }

    private func ensureBackupDir() {
        try? fm.createDirectory(at: Self.backupsRootURL, withIntermediateDirectories: true)
        mgExcludeFromCloudBackup(Self.backupsRootURL)
    }

    private func loadLocalBackups() {
        ensureBackupDir()
        guard let urls = try? fm.contentsOfDirectory(
            at: Self.backupsRootURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        ) else {
            return
        }
        var items: [LocalSaveBackupItem] = []
        for url in urls where url.pathExtension.lowercased() == "zip" {
            let baseName = url.deletingPathExtension().lastPathComponent
            let bundleID: String
            if let range = baseName.range(of: "__", options: .backwards) {
                bundleID = String(baseName[..<range.lowerBound])
            } else {
                bundleID = baseName
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? Date()
            items.append(LocalSaveBackupItem(
                id: url.lastPathComponent,
                fileURL: url,
                bundleID: bundleID,
                createdAt: date,
                fileSize: size
            ))
        }
        items.sort { $0.createdAt > $1.createdAt }
        backups = items
    }

    private static let protectedSystemBundleIDs: Set<String> = [
        "com.jbdotparty.Erosion",
        "com.apple.springboard",
        "com.apple.PosterBoard",
        "com.apple.Preferences"
    ]

    private func scanAllContainers(forceRefresh: Bool = false) {
        let wantSystem = includeSystemApps
        isScanning = true
        scanProgressText = L("正在扫描本机应用数据容器...")
        DispatchQueue.global(qos: forceRefresh ? .userInitiated : .utility).async {
            if forceRefresh {
                CSStoreEngine.shared.invalidate()
            }
            let rawPaths = fsHandlers.getDirPaths(FSURL.appContainers.path, forceRefresh: forceRefresh)
            var discovered: [AppSaveContainerItem] = []
            for rawPath in rawPaths {
                let url = URL(fileURLWithPath: rawPath)

                if let fastBID = CSStoreEngine.shared.bundleID(forContainerPath: url.path, allowDiscovery: false) {
                    if Self.protectedSystemBundleIDs.contains(fastBID) { continue }
                    if !wantSystem && fastBID.hasPrefix("com.apple.") { continue }
                }

                guard let bid = getBIDFromXattr(url),
                      !bid.isEmpty,
                      !Self.protectedSystemBundleIDs.contains(bid) else { continue }
                if !wantSystem && bid.hasPrefix("com.apple.") { continue }

                let wasActive = wq.hasActiveAccess(path: url.path)
                guard wq.grantAccess(path: url.path, requireWrite: false).0 else { continue }
                defer {
                    if !wasActive {
                        wq.releaseAccess(path: url.path)
                    }
                }

                let docsURL = url.appendingPathComponent("Documents")
                let prefsURL = url.appendingPathComponent("Library/Preferences")
                let docsSize = AppContainerDirectoryHelper.directorySize(at: docsURL, maxDepth: 4)
                let prefsSize = AppContainerDirectoryHelper.directorySize(at: prefsURL, maxDepth: 2)

                discovered.append(AppSaveContainerItem(
                    id: url.lastPathComponent,
                    bundleID: bid,
                    displayTitle: AppContainerDirectoryHelper.displayName(for: bid),
                    containerURL: url,
                    saveDataSize: docsSize + prefsSize
                ))
            }

            discovered.sort {
                if $0.saveDataSize != $1.saveDataSize {
                    return $0.saveDataSize > $1.saveDataSize
                }
                return $0.bundleID.localizedStandardCompare($1.bundleID) == .orderedAscending
            }

            DispatchQueue.main.async {
                self.containers = discovered
                self.isScanning = false
            }
        }
    }

    private func backupContainer(_ item: AppSaveContainerItem) {
        ensureBackupDir()
        DispatchQueue.global(qos: .userInitiated).async {
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("SaveBackup_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: stagingDir) }

            do {
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                let wasActive = wq.hasActiveAccess(path: item.containerURL.path)
                guard wq.grantAccess(path: item.containerURL.path, requireWrite: false).0 else {
                    throw L("无法获取该应用容器的读取权限")
                }
                defer {
                    if !wasActive {
                        wq.releaseAccess(path: item.containerURL.path)
                    }
                }

                let docsSrc = item.containerURL.appendingPathComponent("Documents")
                let prefsSrc = item.containerURL.appendingPathComponent("Library/Preferences")
                var copiedAny = false

                if fm.fileExists(atPath: docsSrc.path) {
                    _ = wq.grantAccess(path: docsSrc.path, requireWrite: false)
                    try fm.copyItem(at: docsSrc, to: stagingDir.appendingPathComponent("Documents"))
                    copiedAny = true
                }
                if fm.fileExists(atPath: prefsSrc.path) {
                    _ = wq.grantAccess(path: prefsSrc.path, requireWrite: false)
                    let libDest = stagingDir.appendingPathComponent("Library")
                    try fm.createDirectory(at: libDest, withIntermediateDirectories: true)
                    try fm.copyItem(at: prefsSrc, to: libDest.appendingPathComponent("Preferences"))
                    copiedAny = true
                }

                guard copiedAny else {
                    throw L("未在该应用容器中找到可备份的 Documents 或 Preferences 目录数据。")
                }

                let meta: [String: String] = [
                    "bundleID": item.bundleID,
                    "createdAt": ISO8601DateFormatter().string(from: Date())
                ]
                let metaData = try PropertyListSerialization.data(fromPropertyList: meta, format: .xml, options: 0)
                try metaData.write(to: stagingDir.appendingPathComponent("BackupManifest.plist"), options: .atomic)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let zipName = "\(item.bundleID)__\(formatter.string(from: Date())).zip"
                let zipURL = Self.backupsRootURL.appendingPathComponent(zipName)
                if fm.fileExists(atPath: zipURL.path) {
                    try fm.removeItem(at: zipURL)
                }

                try fm.zipItem(at: stagingDir, to: zipURL, shouldKeepParent: false)
                mgExcludeFromCloudBackup(zipURL)

                DispatchQueue.main.async {
                    loadLocalBackups()
                    Haptic.shared.play(.soft)
                    Alertinator.shared.alert(
                        title: L("存档备份成功！"),
                        body: L("已生成备份文件：\(zipName)\n你可在上方“本地已保存的存档备份”中随时一键还原或导出分享。")
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    Alertinator.shared.alert(title: L("备份存档失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func restoreBackup(_ backup: LocalSaveBackupItem) {
        DispatchQueue.global(qos: .userInitiated).async {
            let extractDir = fm.temporaryDirectory.appendingPathComponent("RestoreSave_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: extractDir) }

            do {
                guard let archive = try? Archive(url: backup.fileURL, accessMode: .read) else {
                    throw L("无法读取备份压缩包，文件可能已损坏！")
                }
                let destStd = extractDir.standardizedFileURL
                let destPrefix = destStd.path.hasSuffix("/") ? destStd.path : destStd.path + "/"
                for entry in archive {
                    let entryPath = entry.path
                    if entryPath.hasPrefix("/") || entryPath.split(separator: "/").contains("..") || entryPath.split(separator: "\\").contains("..") {
                        throw L("检测到备份包包含非法路径穿越条目 (\(entryPath))，已拒绝还原！")
                    }
                    let resolvedPath = destStd.appendingPathComponent(entryPath).standardizedFileURL.path
                    if resolvedPath != destStd.path && !resolvedPath.hasPrefix(destPrefix) {
                        throw L("检测到备份包条目越界 (\(entryPath))，已拒绝还原！")
                    }
                }

                try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
                try fm.unzipItem(at: backup.fileURL, to: extractDir)

                var resolvedBundleID = backup.bundleID
                let manifestURL = extractDir.appendingPathComponent("BackupManifest.plist")
                if let mData = try? Data(contentsOf: manifestURL),
                   let mDict = try? PropertyListSerialization.propertyList(from: mData, options: [], format: nil) as? [String: Any],
                   let mBID = mDict["bundleID"] as? String, !mBID.isEmpty {
                    resolvedBundleID = mBID
                }

                guard !Self.protectedSystemBundleIDs.contains(resolvedBundleID) else {
                    DispatchQueue.main.async {
                        Alertinator.shared.alert(title: L("安全护栏拦截！"), body: L("禁止向受保护的核心系统容器还原外部备份包。"))
                    }
                    return
                }

                var targetContainerPath = ""
                var preGrantedCached = false
                if let matched = containers.first(where: { $0.bundleID == resolvedBundleID }) {
                    let cachedPath = matched.containerURL.path
                    let wasCachedActive = wq.hasActiveAccess(path: cachedPath)
                    if wq.grantAccess(path: cachedPath).0 && fm.fileExists(atPath: cachedPath) && getBIDFromXattr(URL(fileURLWithPath: cachedPath)) == resolvedBundleID {
                        targetContainerPath = cachedPath
                        preGrantedCached = !wasCachedActive
                    } else if !wasCachedActive {
                        wq.releaseAccess(path: cachedPath)
                    }
                }
                if targetContainerPath.isEmpty {
                    targetContainerPath = fsHandlers.getContainerPath(forMatch: resolvedBundleID)
                }

                guard !targetContainerPath.isEmpty else {
                    DispatchQueue.main.async {
                        Alertinator.shared.alert(
                            title: L("未找到目标应用容器！"),
                            body: L("本机当前未检测到「\(resolvedBundleID)」的数据容器，请先安装并至少打开一次该应用后再试。")
                        )
                    }
                    return
                }

                let containerURL = URL(fileURLWithPath: targetContainerPath)
                let wasActive = preGrantedCached ? false : wq.hasActiveAccess(path: containerURL.path)
                guard wq.grantAccess(path: containerURL.path).0 else {
                    throw L("无法获取目标容器的写入权限")
                }
                defer {
                    if !wasActive {
                        wq.releaseAccess(path: containerURL.path)
                    }
                }

                var restoredFiles = 0
                var restoredPrefs = false
                let docsExtract = extractDir.appendingPathComponent("Documents")
                if fm.fileExists(atPath: docsExtract.path) {
                    let docsTarget = containerURL.appendingPathComponent("Documents")
                    try? fm.createDirectory(at: docsTarget, withIntermediateDirectories: true)
                    _ = wq.grantAccess(path: docsTarget.path)
                    restoredFiles += Self.mergeDirectoryInPlace(from: docsExtract, to: docsTarget)
                }

                let prefsExtract = extractDir.appendingPathComponent("Library/Preferences")
                if fm.fileExists(atPath: prefsExtract.path) {
                    let prefsTarget = containerURL.appendingPathComponent("Library/Preferences")
                    try? fm.createDirectory(at: prefsTarget, withIntermediateDirectories: true)
                    _ = wq.grantAccess(path: prefsTarget.path)
                    let pCount = Self.mergeDirectoryInPlace(from: prefsExtract, to: prefsTarget)
                    if pCount > 0 {
                        restoredPrefs = true
                    }
                    restoredFiles += pCount
                }

                let cfprefsHint = restoredPrefs ? L("\n\n提示：本次还原包含 Preferences 偏好设置，建议在后台多任务中彻底关闭目标应用或注销设备（Respring），以便系统 cfprefsd 重新加载配置。") : ""
                DispatchQueue.main.async {
                    Haptic.shared.play(.soft)
                    Alertinator.shared.alert(
                        title: L("存档还原完成！"),
                        body: L("已成功将 \(restoredFiles) 个存档/配置文件原位还原至「\(resolvedBundleID)」容器。") + cfprefsHint
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    Alertinator.shared.alert(title: L("还原存档失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private static func mergeDirectoryInPlace(from srcDir: URL, to dstDir: URL) -> Int {
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: srcDir.path) else { return 0 }
        var count = 0
        for name in names {
            guard !name.contains("/"), name != ".", name != ".." else { continue }
            let srcURL = srcDir.appendingPathComponent(name)
            let dstURL = dstDir.appendingPathComponent(name)
            var st = stat()
            guard lstat(srcURL.path, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFDIR {
                count += mergeDirectoryInPlace(from: srcURL, to: dstURL)
            } else if mode == S_IFREG, let data = try? Data(contentsOf: srcURL) {
                var dstSt = stat()
                if lstat(dstURL.path, &dstSt) == 0 {
                    // Never overwrite a symlink in destination
                    guard (dstSt.st_mode & S_IFMT) == S_IFREG else { continue }
                    if writeFileAtomically(data, to: dstURL, allowEmpty: true).0 {
                        count += 1
                    }
                } else {
                    if data.isEmpty {
                        if (try? data.write(to: dstURL, options: .atomic)) != nil {
                            count += 1
                        }
                    } else if writeFileTemp(data, to: dstURL).0 {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private func deleteBackup(_ backup: LocalSaveBackupItem) {
        try? fm.removeItem(at: backup.fileURL)
        loadLocalBackups()
    }

    private func handleImportBackup(_ result: Result<URL, Error>) {
        ensureBackupDir()
        switch result {
        case .success(let url):
            let stopAccess = url.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let destURL = Self.backupsRootURL.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: destURL)
            do {
                try fm.copyItem(at: url, to: destURL)
                mgExcludeFromCloudBackup(destURL)
                loadLocalBackups()
                Haptic.shared.play(.soft)
            } catch {
                Alertinator.shared.alert(title: L("导入备份包失败！"), body: error.localizedDescription)
            }
        case .failure(let error):
            Alertinator.shared.alert(title: L("导入备份包失败！"), body: error.localizedDescription)
        }
    }
}

struct ContainerSubdirBrowserView: View {
    let containerURL: URL
    let relativeSubpath: String?
    @State private var targetURL: URL?
    @State private var errorMsg: String?

    var body: some View {
        Group {
            if let targetURL {
                FileBrowserView(path: targetURL, shouldGrant: true)
            } else if let errorMsg {
                List {
                    CompactAlert(title: L("无法打开容器目录！"), symbol: "folder.badge.questionmark", text: errorMsg)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在授权并打开容器目录...")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            guard targetURL == nil && errorMsg == nil else { return }
            let rootGrant = wq.grantAccess(path: containerURL.path)
            guard rootGrant.0 else {
                errorMsg = L("无法获取应用容器根目录权限：\(rootGrant.2)")
                return
            }
            if let relativeSubpath, !relativeSubpath.isEmpty {
                let subURL = containerURL.appendingPathComponent(relativeSubpath)
                try? fm.createDirectory(at: subURL, withIntermediateDirectories: true)
                _ = wq.grantAccess(path: subURL.path)
                targetURL = subURL
            } else {
                targetURL = containerURL
            }
        }
    }
}
