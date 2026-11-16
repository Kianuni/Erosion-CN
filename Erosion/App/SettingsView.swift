//
//  SettingsView.swift
//  Erosion
//
//  Created by lunginspector on 8/20/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var langMgr = LocalizationManager.shared
    @AppStorage("autoRespring") var autoRespring = false
    @AppStorage(CSStoreEngine.fastScanDefaultsKey) var useCSStoreFastScan = true
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("界面语言", selection: $langMgr.languageModeRaw) {
                        Text("跟随系统").tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                    Toggle("应用修改后自动注销", isOn: $autoRespring)
                    PlainToggle(
                        "[测试特性] CSStore2 极速容器映射引擎",
                        subtitle: "通过 LaunchServices 二进制库毫秒级解析全机应用与共享组，替代慢速 Inode 遍历",
                        infoType: .info,
                        infoTitle: "CSStore2 极速容器引擎（测试特性）",
                        infoMessage: "从 InternalDaemon 只读解析 com.apple.LaunchServices-*.csstore 二进制库（魔数 bdsl），可在数十毫秒内完成全机应用容器、扩展插件与 AppGroup 映射并显示应用名称；若读取失败会自动无缝回退至传统 pathleak 遍历。",
                        isOn: $useCSStoreFastScan
                    )
                    if useCSStoreFastScan {
                        Button("刷新 CSStore2 容器图谱缓存") {
                            CSStoreEngine.shared.invalidate()
                            let summary = CSStoreEngine.shared.summaryText()
                            Alertinator.shared.alert(title: "CSStore2 图谱状态", body: summary)
                        }
                    }
                } header: {
                    HeaderLabel("应用设置", symbol: "gearshape")
                } footer: {
                    Text("在成功应用功能修改后自动触发设备注销 (Respring)。标记为 [测试特性] 的功能若遇系统兼容异常可随时在此关闭并回退。")
                }
                
                Section {
                    AppInfoCell(build: build)
                } header: {
                    HeaderLabel("关于", symbol: "info.circle")
                } footer: {
                    Text("基于 [jailbreak.party](https://jailbreak.party) 上游构建 · Kianuni 中英双语与防白苹果安全加固版")
                }

                Section {
                    LinkCreditCell(name: "AppleFlow", description: "零 MitM 的 Apple 智能、PCC 与中文 Siri 极简分流方案 & 在线配置体检台", url: "https://github.com/Kianuni/AppleFlow")
                    LinkCreditCell(name: "WQGuard", description: "100% 只读开源的 iOS 沙盒越权检测、侧载 IPA 审查与固件 CVE 防护工具", url: "https://github.com/Kianuni/WQGuard")
                    LinkCreditCell(name: "Camlo · 开幕", description: "免电脑一键换上滑动解锁变身、裸眼 3D 与动态锁屏壁纸", url: "https://github.com/Kianuni/Camlo")
                    LinkCreditCell(name: "Enkard", description: "纯离线、零云同步、绑定 Secure Enclave 的 iPhone 银行级加密卡包", url: "https://github.com/Kianuni/Enkard")
                } header: {
                    HeaderLabel("更多开源项目 (Kianuni)", symbol: "sparkles")
                }

                Section {
                    LinkCreditCell(image: Image("lunginspector"), name: "lunginspector", description: "主要开发者与项目维护者", url: "https://github.com/lunginspector")
                    LinkCreditCell(image: Image("forcequit"), name: "forcequit", description: "worse_query 沙盒逃逸漏洞作者", url: "https://github.com/forcequitOS")
                    LinkCreditCell(image: Image("0xjohnny"), name: "0xjohnny", description: "worse_query 沙盒逃逸漏洞作者", url: "https://github.com/0xjohnnydev")
                    LinkCreditCell(image: Image("skadz108"), name: "Skadz", description: "漏洞集成、后端核心功能与项目维护", url: "https://github.com/skadz108")
                    LinkCreditCell(image: Image("rooootdev"), name: "rooootdev", description: "多项后端组件支持", url: "https://github.com/rooootdev")
                    LinkCreditCell(image: Image("neonmodder123"), name: "neonmodder123", description: "WebView 免越狱注销方案作者", url: "https://github.com/neonmodder123")
                    LinkCreditCell(name: "huamidev — GestaltX", description: "本机系统库动态缓存偏移解析、变更对比预览、写后校验与重签 App Group 探测等优秀设计参考", url: "https://github.com/huamidev/GestaltX")
                    LinkCreditCell(name: "kolbicz — WQFiles", description: "LaunchServices CSStore2 (bdsl) 容器快速映射与跨容器只读遥测架构设计参考", url: "https://github.com/kolbicz/WQFiles")
                    LinkCreditCell(name: "KirbySD", description: "MobileGestalt CacheData 布尔槽位偏移研究思路分享", url: "https://www.v2ex.com/t/1246550")
                    LinkCreditCell(name: "PoomSmart — MGKeys", description: "MobileGestalt 混淆键值映射表维护与整理", url: "https://github.com/PoomSmart/MGKeys")
                } header: {
                    HeaderLabel("致谢与开源参考", symbol: "star")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("关闭", symbol: "xmark")
                    }
                }
            }
        }
        .id(langMgr.refreshID)
        .environment(\.locale, langMgr.effectiveLocale)
    }
}
