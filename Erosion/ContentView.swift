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
    @State private var showSettings = false
    
    var body: some View {
        NavigationStack {
            List {
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
