//
//  TweaksView.swift
//  Erosion
//
//  Created by lunginspector on 8/26/26.
//

import SwiftUI


struct TweaksView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("自定义锁屏壁纸", destination: PosterBoardView())
                    NavigationLink("拨号键盘美化", destination: KeypadView())
                } header: {
                    HeaderLabel("外观与桌面定制", symbol: "paintbrush")
                }

                Section {
                    NavigationLink("应用与游戏存档管理", destination: AppDataBackupView())
                    NavigationLink("容器缓存扫描与清理", destination: CacheCleanerView())
                } header: {
                    HeaderLabel("应用存档与空间清理", symbol: "externaldrive.badge.checkmark")
                }
                
                Section {
                    if raveSupported() || weOnADebugBuild {
                        NavigationLink("MobileGestalt 修改", destination: GestaltView())
                    }
                    NavigationLink("系统配置与监管", destination: ConfigView())
                    NavigationLink("任意文件替换", destination: OperationsView())
                } header: {
                    HeaderLabel("系统底层", symbol: "gear")
                }

                Section {
                    NavigationLink("[测试特性] 物理电池寿命与温控遥测", destination: PowerTelemetryView())
                    NavigationLink("[测试特性] 崩溃与 Jetsam 杀后台分析", destination: CrashDiagnosticsView())
                    NavigationLink("[测试特性] 共享组分流规则与书签导出", destination: AppGroupHubView())
                    NavigationLink("[测试特性] 语音备忘录提取与 AI 模型体检", destination: VoiceMemosAIView())
                } header: {
                    HeaderLabel("跨容器实验特性（测试特性）", symbol: "flask")
                } footer: {
                    Text("以上实验模块与设置页中的「CSStore2 极速容器映射引擎」均为 v0.8.0 测试特性：所有系统数据库均采用 APFS clonefile() 零锁只读快照读取，不修改原始守护进程文件。")
                }
            }
            .navigationTitle("功能修改")
        }
    }
}
