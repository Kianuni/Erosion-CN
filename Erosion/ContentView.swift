//
//  ContentView.swift
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

import SwiftUI


struct ContentView: View {
    @AppStorage("ogMachineName") var ogMachineName = ""
    @EnvironmentObject var mgr: ErosionManager
    @ObservedObject private var stagingVault = APFSStagingVault.shared
    @State private var showSettings = false
    
    var body: some View {
        NavigationStack {
            List {
                if isWorseQueryPatchedOS() {
                    Section {
                        CompactAlert(
                            title: LocalizationManager.isEnglish
                                ? "worse_query Patched on This iOS Build"
                                : "当前系统版本已封堵 worse_query 漏洞",
                            symbol: "exclamationmark.octagon.fill",
                            text: LocalizationManager.isEnglish
                                ? "Apple patched worse_query in iOS 27.3 beta 2+ (and 26.7.3+). System/MobileGestalt writes are unavailable on this OS build. Highest supported version is iOS 27.3 beta 1, and iOS 27.2.1 is recommended."
                                : "Apple 已于 iOS 27.3 beta 2+（及 26.7.3+）封堵 worse_query 沙盒漏洞，当前系统无法写入 MobileGestalt 或跨容器修改文件。最高仅支持至 iOS 27.3 beta 1，强烈建议停留在 iOS 27.2.1。",
                            color: .red
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                if isRunningInLiveContainer() {
                    Section {
                        CompactAlert(
                            title: LocalizationManager.isEnglish
                                ? "Running Inside LiveContainer"
                                : "检测到当前运行在 LiveContainer 内",
                            symbol: "shippingbox.circle.fill",
                            text: LocalizationManager.isEnglish
                                ? "Currently running inside LiveContainer: if container authorization fails, please check host App Group configuration in LiveContainer's app settings, or install as a standalone sideloaded app."
                                : "当前运行在 LiveContainer 内，若遇到容器授权失败，请在 LiveContainer 应用设置中检查宿主 App Group 配置，或使用独立侧载安装。",
                            color: .orange
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                if stagingVault.activeStagedItemsCount > 0 {
                    Section {
                        CompactAlert(
                            title: LocalizationManager.isEnglish
                                ? "Do NOT Uninstall Erosion (\(stagingVault.activeStagedItemsCount) Staged)"
                                : "切勿卸载 Erosion（暂存舱有 \(stagingVault.activeStagedItemsCount) 份待还原数据）",
                            symbol: "externaldrive.badge.exclamationmark",
                            text: LocalizationManager.isEnglish
                                ? "APFS Swap Vault holds \(stagingVault.activeStagedItemsCount) staged app snapshot(s) awaiting restore. Do NOT delete Erosion until you restore and release the vault in Tweaks → App & Game Save Manager."
                                : "APFS 零空间暂存舱当前保存着 \(stagingVault.activeStagedItemsCount) 份应用数据等待还原。请前往「功能修改 → 应用与游戏存档管理」完成还原并释放暂存舱前，切勿卸载本应用！",
                            color: .orange
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                        NavigationLink(destination: AppDataBackupView()) {
                            Label(
                                LocalizationManager.isEnglish
                                    ? "Open App & Game Save Manager (APFS Vault)"
                                    : "前往：应用与游戏存档管理 (APFS 暂存舱)",
                                systemImage: "bolt.shield.fill"
                            )
                            .foregroundStyle(.orange)
                            .fontWeight(.semibold)
                        }
                    }
                }

                Section {
                    LogView()
                        .modifier(TerminalPlatter())
                } header: {
                    HeaderLabel("运行日志", symbol: "apple.terminal")
                } footer: {
                    Text("v\(AppInfo.appVersion) (Build \(AppInfo.appBuild)) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) (\(buildNumber())) · \(machineName())")
                }
                
                Section {
                    Button("注销设备 (Respring)") {
                        mgr.shouldRespring = true
                    }
                    Button {
                        promptGlobalFactoryRestore()
                    } label: {
                        Label("一键恢复原机出厂参数", systemImage: "arrow.counterclockwise.shield.fill")
                    }
                } header: {
                    HeaderLabel("快捷操作", symbol: "gearshape")
                } footer: {
                    Text("「一键恢复原机出厂参数」将校验并原位还原 MobileGestalt 原厂备份（含跨重装系统金库冗余与 SHA-256 核验），同时自动清除锁屏底部文字、资产铭牌、伪监管残留与拨号键盘缓存。")
                }
            }
            .navigationTitle("Erosion")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gear")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                if ogMachineName.isEmpty {
                    ogMachineName = machineName()
                }
            }
        }
    }

    private func promptGlobalFactoryRestore() {
        Alertinator.shared.alert(
            title: "确认一键恢复原机出厂参数？",
            body: MGMsg.globalFactoryRestoreConfirm,
            actionLabel: "确认恢复出厂参数",
            action: {
                switch mgExecuteFactoryRestore(alsoResetConfigAndKeypad: true) {
                case .restoredSuccessfully(let details):
                    Haptic.shared.play(.soft)
                    Alertinator.shared.alert(
                        title: "已恢复原机出厂参数！",
                        body: details,
                        actionLabel: "立即注销",
                        action: { mgr.shouldRespring = true }
                    )
                case .blockedNeedsCleanRebuild(let title, let reason):
                    Alertinator.shared.alert(
                        title: title,
                        body: reason,
                        actionLabel: "重建系统纯净原厂缓存",
                        action: {
                            switch mgExecuteCleanCacheRebuild(alsoResetConfigAndKeypad: true) {
                            case .success:
                                Alertinator.shared.alert(
                                    title: "已准备原厂缓存重建！",
                                    body: MGMsg.mgResetComp,
                                    showCancel: false,
                                    actionLabel: "退出并手动重启",
                                    action: { exitinator() }
                                )
                            case .failure(let err):
                                Alertinator.shared.alert(title: "重建缓存失败！", body: err.localizedDescription)
                            }
                        }
                    )
                case .failed(let reason):
                    Alertinator.shared.alert(title: "恢复原机出厂参数失败！", body: reason)
                }
            }
        )
    }
}

#Preview {
    ContentView()
}
