//
//  APFSVaultGuideSheet.swift
//  Erosion
//
//  Bilingual interactive step-by-step guide for APFS Zero-Space Swap Vault & ZIP Save Backups.
//

import SwiftUI

struct APFSVaultGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                comparisonSection
                sameAppSwapSection
                crossBundleMigrationSection
                safetyRulesSection
            }
            .navigationTitle(apfsVaultText("Usage Guide", "换包与搬家使用说明"))
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

    // MARK: - Section 1: Mode Comparison

    private var comparisonSection: some View {
        Section {
            modeRow(
                symbol: "bolt.shield.fill",
                tint: .orange,
                title: apfsVaultText(
                    "APFS Zero-Space Stage (Same-Device Re-sign / Swap)",
                    "APFS 极速暂存（本机掉签重装 / 换包搬家首选）"
                ),
                detail: apfsVaultText(
                    "Uses kernel CoW clonefile() to snapshot tens of GBs (Documents, Application Support, Preferences) in seconds with near-zero extra disk space. Ideal for WeChat or huge games when switching certificates/Bundle IDs on the same iPhone.",
                    "利用 APFS 内核级写时复制（CoW）秒级克隆几十 GB 数据（文档、Application Support 与 Preferences），额外占用存储接近 0 MB。最适合本机微信或大型手游换签重装、官微 ↔ 多开跨包搬家。"
                )
            )
            modeRow(
                symbol: "externaldrive.badge.plus",
                tint: .blue,
                title: apfsVaultText(
                    "ZIP Save Backup (Export & Cross-Device Archive)",
                    "备份存档 .zip（跨手机导出 / 电脑长期留底）"
                ),
                detail: apfsVaultText(
                    "Compresses Documents & Preferences into a portable .zip file you can save to Files, AirDrop, or a computer. Best for small/medium offline game saves (requires enough free space for compression).",
                    "将 Documents 与 Preferences 打包为标准 .zip 文件，可直接分享到「文件」或电脑长期留档。适合体积不大的单机游戏存档或跨设备迁移。"
                )
            )
        } header: {
            HeaderLabel(
                apfsVaultText("Which Mode Should I Choose?", "一、我该选「APFS 极速暂存」还是「备份存档」？"),
                symbol: "rectangle.on.rectangle.angled"
            )
        }
    }

    // MARK: - Section 2: Same-App Re-sign / Reinstall

    private var sameAppSwapSection: some View {
        Section {
            stepRow(
                step: "1",
                title: apfsVaultText("Force-close the target app first", "先在后台划掉目标应用（防数据库锁）"),
                detail: apfsVaultText(
                    "Swipe up the target app (e.g. WeChat) from the iOS App Switcher so SQLite WAL files flush cleanly.",
                    "上滑退出目标应用（例如微信），确保聊天数据库与 WAL 日志不再写入。若仍在后台运行，安全门禁会自动拦截。"
                )
            )
            stepRow(
                step: "2",
                title: apfsVaultText("Tap \"APFS Stage\" on the app card", "点击目标应用卡片上的「APFS 极速暂存」"),
                detail: apfsVaultText(
                    "Erosion clones the data without touching or deleting the original app container. Make sure Erosion's own signing cert has > 24h left.",
                    "采用「只克隆不删源」协议，原应用数据丝毫不动。暂存前请确认上方显示 Erosion 自身签名剩余有效期充足（> 24 小时）。"
                )
            )
            stepRow(
                step: "3",
                title: apfsVaultText("Uninstall old IPA & install re-signed IPA", "卸载旧版应用，安装新签名的安装包"),
                detail: apfsVaultText(
                    "Remove the expired/old app, then sideload your freshly signed IPA (keep Erosion installed!).",
                    "放心地卸载旧应用并重新安装新签名版本（切记：此时千万不要卸载 Erosion 自己！）。"
                )
            )
            stepRow(
                step: "4",
                title: apfsVaultText("Launch new app once, then swipe-close it", "打开新装的应用一次（停在登录页即可），再划掉后台"),
                detail: apfsVaultText(
                    "Opening the new app once makes iOS create its fresh Data Container UUID. Do not log in yet — just swipe it closed from the App Switcher.",
                    "必须先点开一次新应用，让 iOS 系统为它生成全新的沙盒容器目录（停在登录界面即可，不用登录），然后再次上滑彻底关闭新应用。"
                )
            )
            stepRow(
                step: "5",
                title: apfsVaultText("Open APFS Swap Vault → Restore to Same Bundle ID", "进入「APFS 零空间暂存舱」→ 点击「还原至原应用」"),
                detail: apfsVaultText(
                    "The vault clones data into the new container while still keeping a safety backup inside the vault.",
                    "系统会自动按原包名定位新容器并通过 .bak 原子保护写回数据，且暂存舱里的备份副本此时依然保留作后悔药。"
                )
            )
            stepRow(
                step: "6",
                title: apfsVaultText("Open app, re-login once, verify, then Release Vault", "打开新应用重新登录验证数据，确认无误再释放暂存舱"),
                detail: apfsVaultText(
                    "Apple Keychain tokens are hardware/signature bound and cannot migrate, so log in once to load your restored local data. Once verified, tap \"Release Vault\" to reclaim space.",
                    "受 iOS Keychain 签名隔离限制，首次打开需重新登录一次账号以挂载本地恢复的聊天记录/存档；进入界面确认数据完整后，再回暂存舱点「释放暂存舱」。"
                )
            )
        } header: {
            HeaderLabel(
                apfsVaultText("Same-App Re-sign / Reinstall (6 Steps)", "二、同应用掉签重装 / 换证续签（标准 6 步）"),
                symbol: "arrow.triangle.2.circlepath"
            )
        }
    }

    // MARK: - Section 3: Cross-Bundle Migration

    private var crossBundleMigrationSection: some View {
        Section {
            stepRow(
                step: "A",
                title: apfsVaultText("Prepare target multi-instance app container", "安装并点开目标多开应用，生成容器后划掉双端后台"),
                detail: apfsVaultText(
                    "Example: migrating official WeChat (com.tencent.xin) to clone (com.tencent.wx). Open the target app once until the login screen, then swipe-close BOTH source and target apps.",
                    "例如将官微 (com.tencent.xin) 搬家到多开微信 (com.tencent.wx)：先点开一次目标多开应用停在登录页，然后把源应用和目标应用全部划掉退出。"
                )
            )
            stepRow(
                step: "B",
                title: apfsVaultText("Stage source app with APFS Stage", "在列表中对「源应用」执行「APFS 极速暂存」"),
                detail: apfsVaultText(
                    "For WeChat, Erosion automatically scans and shows the count of detected 32-hex MD5 account folders before staging.",
                    "暂存微信时，系统会自动探测 Documents 内检测到的 32 位 MD5 账号目录数量供核对。"
                )
            )
            stepRow(
                step: "C",
                title: apfsVaultText("Choose \"Restore to Chosen Container\"", "在暂存舱点击「还原至指定应用」并选中目标容器"),
                detail: apfsVaultText(
                    "Erosion automatically clones Documents & Support and adapts Library/Preferences/<sourceBID>.plist to <targetBID>.plist.",
                    "系统会自动克隆核心数据并将原包名对应的 Preferences/<源包名>.plist 适配映射为 <目标包名>.plist。"
                )
            )
            stepRow(
                step: "D",
                title: apfsVaultText("Log in target app & release vault after check", "打开目标应用登录验证聊天记录，确认后释放暂存舱"),
                detail: apfsVaultText(
                    "Just like same-app restores, log in once so the target app unlocks the restored local database, then safely tap \"Release Vault\".",
                    "与同包重装一致，首次需登录一次账号读取本地数据；确认全部聊天记录完好后再手动释放暂存舱。"
                )
            )
        } header: {
            HeaderLabel(
                apfsVaultText("Official ↔ Multi-Instance Migration", "三、跨包名搬家（官微 ↔ 多开分身）"),
                symbol: "arrow.left.arrow.right.square"
            )
        }
    }

    // MARK: - Section 4: Critical Safety Rules

    private var safetyRulesSection: some View {
        Section {
            warningBullet(
                symbol: "exclamationmark.triangle.fill",
                color: .red,
                text: apfsVaultText(
                    "NEVER uninstall Erosion while snapshots are inside the APFS Swap Vault. If SideStore cert is under 24h, refresh Erosion first!",
                    "暂存舱内有未释放数据时，严禁卸载 Erosion！若发现顶部提示签名不足 24 小时，请务必先续签本应用再开始。"
                )
            )
            warningBullet(
                symbol: "lock.shield.fill",
                color: .orange,
                text: apfsVaultText(
                    "Always swipe-close the target app before staging or restoring to avoid SQLite WAL corruption.",
                    "暂存与写回前务必划掉目标应用后台，避免微信等软件在写入 SQLite WAL 时触发数据库锁。"
                )
            )
            warningBullet(
                symbol: "key.fill",
                color: .accentColor,
                text: apfsVaultText(
                    "Keychain login credentials do not transfer across signatures or Bundle IDs — re-login once after restore is normal.",
                    "Keychain 登录凭证受系统硬件与签名校验保护，恢复后首次打开要求重新输入密码/扫码属正常现象。"
                )
            )
        } header: {
            HeaderLabel(
                apfsVaultText("3 Critical Safety Rules", "四、三条防翻车红线"),
                symbol: "hand.raised.fill"
            )
        }
    }

    // MARK: - Row Builders

    private func modeRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func stepRow(step: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func warningBullet(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
