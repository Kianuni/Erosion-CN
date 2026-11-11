//
//  GestaltView.swift
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

import SwiftUI

import UniformTypeIdentifiers

struct GestaltView: View {
    @EnvironmentObject private var mgr: ErosionManager
    @StateObject private var store = GestaltStore.shared
    @AppStorage("mgOverrideGates") private var mgOverrideGates = false
    @AppStorage("mgWriteAtomically") private var mgWriteAtomically = true
    @AppStorage("autoRespring") var autoRespring = false
    @AppStorage("hasShownSheet") private var hasShownSheet = false
    @Environment(\.dismiss) private var dismiss
    
    @State private var mgSubtype = 0
    @State private var mgOgSubtype = 0
    @State private var mgOgDeviceName = ""
    @State private var mgEnableDeviceName = false
    @AppStorage("mgDeviceName") private var mgDeviceName = ""
    @AppStorage("ogMachineName") private var ogMachineName = ""
    @AppStorage("showRegionTweak") private var showRegionTweak = false
    @AppStorage("showCustomKeys") private var showCustomKeys = false
    @AppStorage("mgCustKeyArray") var customKeys: [MGCustomKey] = []
    @State private var mgProductType = ""
    
    @State private var showInfoSheet = false
    @State private var pendingPreviewAfterInfoSheet = false
    @State private var idiotButtonTimerComplete = false
    @State private var mgBaselineDict: NSDictionary = [:]
    @State private var diffPreviewPayload: MGDiffPreviewPayload? = nil
    @State private var showInspectorSheet = false
    @State private var hasLoadedInitialData = false
    @State private var hasPromptedBuildMismatch = false
    @State private var hasWriteAccess = false
    @State private var showBackupImporter = false
    @State private var dualVaultReady = false

    private struct MGDiffPreviewPayload: Identifiable {
        let id = UUID()
        let diffs: [MGDiffItem]
        let candidate: NSMutableDictionary
    }
    
    var body: some View {
        List {
                Section {
                    NavigationLink {
                        MGInspectorView(store: store)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.path.ecg.rectangle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("真机生效核验与动态槽位实时探针")
                                    .font(.subheadline.weight(.semibold))
                                Text("对比原厂备份、当前配置与 MGCopyAnswer 真机返回值（纯只读）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: dualVaultReady ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                            .font(.title3)
                            .foregroundStyle(dualVaultReady ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dualVaultReady ? "双重原厂安全备份已锁定" : "本地原厂备份已就绪")
                                .font(.subheadline.weight(.semibold))
                            Text(dualVaultReady ? "沙盒备份 + 系统金库双冗余 · SHA-256 已校验（卸载重装不丢失）" : "已启用 SHA-256 完整性校验与防零字节原位回滚")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            promptFactoryRestore()
                        } label: {
                            Text("一键恢复原厂")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.16), in: Capsule())
                                .foregroundStyle(Color.orange)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasWriteAccess && !weOnADebugBuild)
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    if mgOverrideGates {
                        HStack {
                            Picker("屏幕子类型", selection: $mgSubtype) {
                                Text("原始默认 (\(mgOgSubtype))").tag(mgOgSubtype)
                                if isDynamIslandHD() && doubleSysVrs() < 19.0 {
                                    Text("禁用灵动岛").tag(2436)
                                }
                                Text("iPhone 14 Pro").tag(2436)
                                Text("iPhone 14 Pro Max").tag(2796)
                                Text("iPhone 15 Pro Max").tag(2976)
                                if doubleSysVrs() >= 18.0 {
                                    Text("iPhone 16 Pro").tag(2622)
                                    Text("iPhone 16 Pro Max").tag(2868)
                                }
                                if doubleSysVrs() >= 26.0 {
                                    Text("iPhone Air").tag(2736)
                                }
                                if doubleSysVrs() >= 27.0 {
                                    Text("iPhone 18 Pro Max").tag(2670)
                                }
                                if isHomeButtonHD() {
                                    Text("iPhone X 全面屏手势").tag(2436)
                                }
                            }
                            Spacer()
                            Button {
                                Alertinator.shared.alert(title: "屏幕子类型说明", body: MGMsg.subtype)
                            } label: {
                                Image(systemName: "info.circle")
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Toggle("自定义机型名称", isOn: $mgEnableDeviceName)
                    if mgEnableDeviceName {
                        TextField("输入自定义机型名称", text: $mgDeviceName)
                    }
                    PlainToggle("液态玻璃低功耗渲染（省电模式）", infoType: .info, infoMessage: MGMsg.liquidGlass, minVrs: 26.0, isOn: store.mgKeyBinding([MGKey.liquidGlassLowPower]))
                } header: {
                    HeaderLabel("外观与显示特征", symbol: "paintbrush.pointed")
                }
                
                if !isDynamIslandHD() || !isAODHD() || !isBootChimeHD() || !isChargeLimitHD() || mgOverrideGates {
                    Section {
                        if !isDynamIslandHD() || mgOverrideGates {
                            PlainToggle("启用灵动岛", minVrs: 19.0, isOn: store.mgKeyBinding([MGKey.island]))
                        }
                        if !isAODHD() || mgOverrideGates {
                            PlainToggle("启用全天候显示 (AOD)", minVrs: 18.0, isOn: store.mgKeyBinding([MGKey.AOD, MGKey.AOTime]))
                            if store.isEnabled([MGKey.AOD]) {
                                PlainToggle("启用全天候显示鲜艳度", minVrs: 18.0, isOn: store.mgKeyBinding([MGKey.AODVibrancy]))
                            }
                        }
                        if !isChargeLimitHD() || mgOverrideGates {
                            PlainToggle("启用 80% 充电上限", minVrs: 17.0, isOn: store.mgKeyBinding([MGKey.chargeLim]))
                        }
                        if !isBootChimeHD() || mgOverrideGates {
                            PlainToggle("启用开机提示音", isOn: store.mgKeyBinding([MGKey.bootChime]))
                        }
                    } header: {
                        HeaderLabel("硬件特性解锁", symbol: "gearshape")
                    }
                }
                
                Section {
                    let internalGateLocked = store.isEnabled([MGKey.appIntell]) || (isAppleIntellHD() && !mgOverrideGates)
                    PlainToggle("启用 Apple 内部安装模式", infoType: .info, infoMessage: MGMsg.intInstall, isOn: store.mgKeyBinding([MGKey.intInstall]))
                        .disabled(internalGateLocked && !store.isKeyEnabled(MGKey.intInstall))
                    PlainToggle("启用内部版本标识 (Internal Build)", infoType: .info, infoMessage: MGMsg.intBuild, isOn: store.mgKeyBinding([MGKey.intBuild]))
                        .disabled(internalGateLocked && !store.isKeyEnabled(MGKey.intBuild))
                } header: {
                    HeaderLabel("内部调试选项", symbol: "ant")
                } footer: {
                    if isAppleIntellHD() && !mgOverrideGates {
                        Text("已自动锁定：Apple 内部安装模式与 Apple 智能互斥，开启会导致原生 AI 机型无法激活 Apple 智能。")
                    }
                }
                
                Section {
                    AppleIntelligenceCheckupCard(store: store, hasWriteAccess: hasWriteAccess) {
                        Alertinator.shared.runWhenPresentationIdle {
                            showInspectorSheet = true
                        }
                    }

                    PlainToggle("启用安全研究设备界面 (SRD UI)", minVrs: 26.0, isOn: store.mgKeyBinding([MGKey.srd]))
                    if showRegionTweak || mgOverrideGates || store.mgRegionRestrictionsBinding().wrappedValue {
                        PlainToggle("解除地区限制（国行 AI / 美版 LL/A）", isOn: store.mgRegionRestrictionsBinding())
                        if store.mgRegionRestrictionsBinding().wrappedValue {
                            HStack(spacing: 10) {
                                Picker("修改模式", selection: store.mgRegionUnlockModeBinding()) {
                                    Text("完整美版 LL + LL/A").tag(MGRegionUnlockMode.fullUS)
                                    Text("仅改区域代码 LL（保留 CH/A 后缀与双卡兼容）").tag(MGRegionUnlockMode.regionCodeOnly)
                                }
                                Button {
                                    Alertinator.shared.alert(title: "地区修改模式说明", body: MGMsg.regionModeInfo)
                                } label: {
                                    Image(systemName: "info.circle")
                                        .frame(width: 24, height: 22)
                                }
                                .buttonStyle(.plain)
                            }
                            if store.currentRegionUnlockMode == .fullUS {
                                HStack {
                                    Text("美版监管型号")
                                    Spacer()
                                    TextField("如 A3473", text: store.mgRegModelBinding())
                                        .multilineTextAlignment(.trailing)
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                }
                            } else {
                                let keptSuffix = store.strVal(forKey: MGKey.regionSysconfig)
                                let keptModel = store.strVal(forKey: MGKey.regModelNumber)
                                HStack {
                                    Text("保留销售后缀与型号")
                                    Spacer()
                                    Text("\(keptSuffix.isEmpty ? "原厂" : keptSuffix) · \(keptModel.isEmpty ? "原厂" : keptModel)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !isAppleIntellHD() || mgOverrideGates {
                        PlainToggle(
                            "启用 Apple 智能开关",
                            subtitle: "自动同步解锁相册“消除”与备忘录“手写体合成”",
                            infoType: .info,
                            infoTitle: "启用 Apple 智能说明",
                            infoMessage: MGMsg.appleIntellInfo,
                            minVrs: 18.1,
                            isOn: store.mgKeyBinding(MGKey.appIntellAllKeys)
                        )
                        .onChange(of: store.mgKeyBinding(MGKey.appIntellAllKeys).wrappedValue) { (_, newVal) in
                            if newVal {
                                store.mgPullKeys([MGKey.intBuild, MGKey.intInstall])
                            }
                        }
                    }
                    if raveSupported() || mgOverrideGates {
                        let advNativeOn = isAdvAppleIntellHD()
                        let advConflictOn = store.isAdvAppleIntellConflictActive()
                        if advNativeOn && !mgOverrideGates {
                            PlainToggle(
                                "解锁 iOS 27 进阶 AI 能力 [测试特性]",
                                subtitle: "✅ 本机硬件已原生开启（无需额外修改，已锁定防误关）",
                                infoType: .info,
                                infoTitle: "iOS 27 进阶 AI 能力说明",
                                infoMessage: MGMsg.advAppleIntell,
                                isOn: .constant(true)
                            )
                            .disabled(true)
                        } else {
                            PlainToggle(
                                "解锁 iOS 27 进阶 AI 能力 [测试特性]",
                                subtitle: advConflictOn
                                    ? "⚠️ 检测到已开启非原生实验槽位（会导致照片“高质量”消除报错），请直接关闭并应用恢复"
                                    : (isNativePersonalTranslatorHD()
                                        ? "✅ 本机已原生开启个人实时翻译；实验性音频智能槽位已锁定关闭（强开会导致照片高质量消除报错）"
                                        : "已由防呆护栏自动锁定：iPhone/iPad 强开会导致照片“高质量”消除报错"),
                                infoType: .warning,
                                infoTitle: "iOS 27 进阶 AI 防呆锁定说明",
                                infoMessage: MGMsg.advAppleIntell,
                                isOn: store.mgSafeAdvAppleIntellGuardrailBinding()
                            )
                            .disabled(!advConflictOn)
                        }
                    }
                    if !isAppleIntellHD() || mgOverrideGates {
                        HStack(spacing: 10) {
                            Picker("机型伪装", selection: $mgProductType) {
                                Text("保持默认").tag(ogMachineName)
                                if ogMachineName.contains("Pad") {
                                    if doubleSysVrs() >= 17.4 {
                                        Text("iPad Pro 11 英寸 (M4)").tag("iPad16,3")
                                        Text("iPad Pro 11 英寸 (M4, 蜂窝网络)").tag("iPad16,4")
                                    }
                                    Text("iPad Pro 11 英寸 (第 4 代)").tag("iPad14,3")
                                    Text("iPad Pro 11 英寸 (第 4 代, 蜂窝网络)").tag("iPad14,4")
                                } else {
                                    Text("iPhone 15 Pro").tag("iPhone16,1")
                                    Text("iPhone 15 Pro Max").tag("iPhone16,2")
                                    if doubleSysVrs() >= 18.0 {
                                        Text("iPhone 16").tag("iPhone17,3")
                                        Text("iPhone 16 Plus").tag("iPhone17,4")
                                        Text("iPhone 16 Pro").tag("iPhone17,1")
                                        Text("iPhone 16 Pro Max").tag("iPhone17,2")
                                    }
                                    if doubleSysVrs() >= 19.0 {
                                        Text("iPhone 17").tag("iPhone18,3")
                                        Text("iPhone 17 Pro").tag("iPhone18,1")
                                        Text("iPhone 17 Pro Max").tag("iPhone18,2")
                                        Text("iPhone Air").tag("iPhone18,4")
                                    }
                                    if doubleSysVrs() >= 27.0 {
                                        Text("iPhone 18 Pro").tag("iPhone19,2")
                                        Text("iPhone 18 Pro Max").tag("iPhone19,3")
                                        Text("iPhone Duo").tag("iPhone19,4")
                                    }
                                }
                            }
                            Button {
                                Alertinator.shared.alert(title: "机型伪装说明", body: isAppleIntellHD() ? MGMsg.spoofUseless : MGMsg.spoofAI)
                            } label: {
                                Image(systemName: "info.circle")
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HeaderLabel("地区与功能准入 (Eligibility)", symbol: "flag")
                } footer: {
                    Text("注：原生支持 Apple 智能的机型默认隐藏旧机型专用的“Apple 智能总开关”与“机型伪装”（国行机型仅需开启“解除地区限制”与下方“green-tea 底层限制”即可激活）；“解锁 iOS 27 进阶 AI 能力”将根据当前机型与固件版本实时展示开关或原生状态。")
                }

                Section {
                    let greenTeaReady = store.canModifyGreenTeaCache()
                    let wapiReady = store.canModifyWapiCache()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: greenTeaReady ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundStyle(greenTeaReady ? Color.green : Color.red)
                            Text(greenTeaReady ? "已精确匹配本机缓存布局" : "动态解析未通过（已拒绝修改）")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(greenTeaReady ? Color.primary : Color.red)
                            Spacer()
                            Button {
                                let report = MGCacheDataCoordinator.shared.diagnosticReport(for: store.mgCurrentDict)
                                Alertinator.shared.alert(title: "本机 CacheData 动态解析详情", body: report)
                            } label: {
                                HStack(spacing: 3) {
                                    Text("查看偏移")
                                        .font(.caption)
                                    Image(systemName: "info.circle")
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        if let failReason = store.cacheResolutionFailureReason() {
                            Text(failReason)
                                .font(.caption)
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(.vertical, 2)

                    PlainToggle(
                        "解除国行底层限制（eSIM / FaceTime 音频）",
                        infoType: .info,
                        infoTitle: "解除国行底层限制说明",
                        infoMessage: MGMsg.chinaCacheUnlock,
                        isOn: store.mgChinaRestrictionCacheBinding()
                    )
                    .disabled(!greenTeaReady)

                    PlainToggle(
                        "将“无线局域网”显示为“Wi-Fi”",
                        subtitle: "⚠️ 开启后会丢失国行特有的单应用“不允许联网”功能",
                        infoType: .warning,
                        infoTitle: "无线局域网改 Wi-Fi 重要提示",
                        infoMessage: MGMsg.wapiToWifi,
                        isOn: store.mgWapiWifiBinding()
                    )
                    .disabled(!wapiReady)
                } header: {
                    HeaderLabel("国行底层缓存限制 (CacheData 动态解析)", symbol: "antenna.radiowaves.left.and.right")
                } footer: {
                    Text("运行时从本机内存中的 libMobileGestalt.dylib 实时解析偏移并严格核对 CacheUUID、长度与有效位；解析失败时严禁修改任何字节。注意：将“无线局域网”改为“Wi-Fi”会丢失国行的“不允许联网”功能（仅保留蜂窝数据开关）。应用本组开关后请手动重启手机生效。")
                }

                Section {
                    featureSlotRow(
                        title: "相册与相机“混音 (Audio Mix)”",
                        subtitle: "视频编辑支持标准 / 语音突显 / 录音棚 / 电影效果四档人声混音",
                        infoTitle: "混音 (Audio Mix) 说明",
                        infoMessage: MGMsg.audioMixInfo,
                        keys: [MGKey.audioMix]
                    )
                    featureSlotRow(
                        title: "空间音频录制与 FaceTime 空间音频",
                        subtitle: "解锁相机视频 3D 空间音频拾音及 FaceTime 空间声场渲染",
                        infoTitle: "空间音频录制说明",
                        infoMessage: MGMsg.spatialAudioInfo,
                        keys: MGKey.spatialAudioAllKeys
                    )
                    featureSlotRow(
                        title: "按下快门瞬间抓拍 (Responsive Shutter)",
                        subtitle: "降低相机按下快门至成像管线的触发延迟，实现零延迟抓拍",
                        infoTitle: "按下快门瞬间抓拍说明",
                        infoMessage: MGMsg.responsiveShutterInfo,
                        keys: [MGKey.responsiveShutter]
                    )
                    featureSlotRow(
                        title: "健康“高血压趋势评估与通知模式”",
                        subtitle: "开启健康 App 血压偏高趋势分析、风险评估与测量记录向导",
                        infoTitle: "高血压趋势评估说明",
                        infoMessage: MGMsg.hypertensionInfo,
                        keys: [MGKey.hypertensionNotif]
                    )
                } header: {
                    HeaderLabel("影像与健康进阶能力 (CacheData 硬件槽位)", symbol: "waveform.badge.mic")
                } footer: {
                    Text("本组能力由设备树 (IODeviceTree) 映射至二进制 CacheData 布尔槽位，必须通过动态槽位偏移直接写入 CacheData 才能绕过系统 _MGCacheSetValueForKey 有效性短路检查。本机已原生开启的硬件能力会自动锁定以防误关降级；应用后请手动重启手机生效。")
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "flask.fill")
                            .foregroundStyle(Color.orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("测试特性专区（Experimental · CacheData 动态槽位）")
                                .font(.subheadline.weight(.semibold))
                            Text("以下能力全部通过本机 libMobileGestalt.dylib 实时解析二进制布尔槽位偏移并执行零白苹果写前校验。受各机型物理传感器与 eligibilityd 策略差异影响，实际表现可能因设备而异，修改后请重启设备测试。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            Alertinator.shared.alert(title: "测试特性说明", body: MGMsg.expNotice)
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)

                    experimentalSlotRuleRow(
                        title: "[测试特性] 日版/韩版真·相机快门静音",
                        subtitle: "组合修改 3 个真实 CacheData 快门音豁免槽位，无需改美版即可尝试静音快门",
                        infoTitle: "日韩版相机快门静音（测试特性）",
                        infoMessage: MGMsg.expShutterMuteInfo,
                        rules: [
                            MGSlotRule(key: MGKey.shutterRelaxation, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.shutterKeyboardMutePreserve, targetValue: false, required: false),
                            MGSlotRule(key: MGKey.shutterLegacyMutePreserve, targetValue: false, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 高低功耗双麦并发拾音 (录音棚叠录底座)",
                        subtitle: "解锁语音备忘录伴奏叠录与多轨人声分离所需的双麦并发硬件标记",
                        infoTitle: "高低功耗双麦并发（测试特性）",
                        infoMessage: MGMsg.expStudioMicsInfo,
                        rules: [MGSlotRule(key: MGKey.concurrentHPLPMics, targetValue: true)]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 相册局部光影重绘与新一代色调映射",
                        subtitle: "开启 PhotosLocalLight + ToneMapping + HDR 深度延迟渲染管线",
                        infoTitle: "相册光影与色调映射增强（测试特性）",
                        infoMessage: MGMsg.expPhotoToneInfo,
                        rules: [
                            MGSlotRule(key: MGKey.photosLocalLight, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.toneMapping, targetValue: true, required: false),
                            MGSlotRule(key: MGKey.hdrDeferredProcessing, targetValue: true, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 超取景框捕获与 P3 广色域立体声视频",
                        subtitle: "同步开启 SpatialOverCapture、立体声视频拾音与 P3 广色域录制",
                        infoTitle: "空间超取景与立体声视频（测试特性）",
                        infoMessage: MGMsg.expSpatialStereoInfo,
                        rules: [
                            MGSlotRule(key: MGKey.spatialOverCapture, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.stereoAudioRec, targetValue: true, required: false),
                            MGSlotRule(key: MGKey.p3VideoRec, targetValue: true, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 相机控制电容滑动变焦与触觉阻尼完整面板",
                        subtitle: "补齐电容触敏相机控制、物理档位阻尼与微幅触觉反馈 4 项槽位",
                        infoTitle: "相机控制完整交互包（测试特性）",
                        infoMessage: MGMsg.expCamControlInfo,
                        rules: [
                            MGSlotRule(key: MGKey.camButton, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.touchSensitiveCamControl, targetValue: true, required: false),
                            MGSlotRule(key: MGKey.hardwareDetents, targetValue: true, required: false),
                            MGSlotRule(key: MGKey.cameraHaptics, targetValue: true, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 旧机型显示电池循环次数与生产日期",
                        subtitle: "在旧款机型“关于本机 / 电池健康”中展示循环计数与首次使用日期",
                        infoTitle: "旧机型电池健康详情（测试特性）",
                        infoMessage: MGMsg.expLegacyBatteryInfo,
                        rules: [
                            MGSlotRule(key: MGKey.legacyBatteryInfo, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.legacyDynamicEndOfCharge, targetValue: true, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 户外高亮全天候显示与翻页帧缓冲",
                        subtitle: "解锁 HighLuminanceAOD 与低功耗 Flipbook 息屏显示管线（非 LTPO 屏耗电较高）",
                        infoTitle: "户外高亮 AOD（测试特性）",
                        infoMessage: MGMsg.expHighLumAODInfo,
                        rules: [
                            MGSlotRule(key: MGKey.highLuminanceAOD, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.aodFlipbook, targetValue: true, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] CarPlay Ultra (新一代多屏全液晶车载)",
                        subtitle: "启用新一代多仪表盘接管 CarPlay 2.0 车载协议栈标记",
                        infoTitle: "CarPlay Ultra（测试特性）",
                        infoMessage: MGMsg.expCarPlay2Info,
                        rules: [MGSlotRule(key: MGKey.carPlay2, targetValue: true)]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 120Hz 触控采样事件投递管线",
                        subtitle: "开启 TouchDelivery120Hz 触控上报（注：60Hz 屏幕无法突破物理显示刷新率）",
                        infoTitle: "120Hz 触控采样投递（测试特性）",
                        infoMessage: MGMsg.expTouch120Info,
                        rules: [MGSlotRule(key: MGKey.touchDelivery120Hz, targetValue: true)]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] AirPods 临床听力均衡与低功耗助听器模式",
                        subtitle: "开启 hearingaid 均衡、低功耗音频与降功耗 3 个连续硬件槽位",
                        infoTitle: "临床听力与助听器模式（测试特性）",
                        infoMessage: MGMsg.expHearingAidInfo,
                        rules: [
                            MGSlotRule(key: MGKey.hearingAidEQ, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.hearingAidLE, targetValue: true, required: false),
                            MGSlotRule(key: MGKey.hearingAidPowerRed, targetValue: true, required: false)
                        ]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 睡眠呼吸暂停风险趋势检测",
                        subtitle: "开启“健康 -> 呼吸紊乱”睡眠呼吸暂停评估页面支持",
                        infoTitle: "睡眠呼吸暂停检测（测试特性）",
                        infoMessage: MGMsg.expSleepApneaInfo,
                        rules: [MGSlotRule(key: MGKey.breathingDisturbances, targetValue: true)]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 解除美版血氧软件专利限制",
                        subtitle: "将 USLegallyCompliantBloodOxygen 设为 false（国行机型原生未受限无需开启）",
                        infoTitle: "解除美版血氧限制（测试特性）",
                        infoMessage: MGMsg.expUSBloodOxygenInfo,
                        rules: [MGSlotRule(key: MGKey.usBloodOxygen, targetValue: false)]
                    )

                    experimentalSlotRuleRow(
                        title: "[测试特性] 户外极限运动模式与日光照射时长监测",
                        subtitle: "同步解锁 WorkoutUltraMode 与环境日光照射统计槽位",
                        infoTitle: "极限运动与日光监测（测试特性）",
                        infoMessage: MGMsg.expWorkoutUltraInfo,
                        rules: [
                            MGSlotRule(key: MGKey.workoutUltra, targetValue: true, required: true),
                            MGSlotRule(key: MGKey.timeInDaylight, targetValue: true, required: false)
                        ]
                    )

                    PlainToggle(
                        "[测试特性] 端侧 Siri Hub 路由与指令模型动态剪枝",
                        subtitle: store.isSiriHubConflictActive()
                            ? "⚠️ 检测到已开启（会卡死“正在添加 Siri 支持内容”），请直接关闭并重启恢复"
                            : "已由防呆护栏自动锁定：SiriHub 属家居中枢专属路由，iPhone/iPad 开启会卡死 Siri",
                        infoType: .warning,
                        infoTitle: "端侧 Siri Hub 防呆锁定说明",
                        infoMessage: MGMsg.expSiriHubInfo,
                        isOn: store.mgSafeSiriHubGuardrailBinding()
                    )
                    .disabled(!store.isSiriHubConflictActive())
                } header: {
                    HeaderLabel("实验性底层特性挖掘（测试特性）", symbol: "flask")
                } footer: {
                    Text("所有标记 [测试特性] 的开关均严格运行在已校验的 8 字节布尔 CacheData 槽位内（零白苹果风险），但实际功能效果取决于本机协处理器与系统版本；修改后需手动重启手机生效。")
                }
                
                Section {
                    if !isCrashDectHD() || mgOverrideGates {
                        PlainToggle("车祸检测设置项", isOn: store.mgKeyBinding([MGKey.crashDet]))
                    }
                    if !isPWMHD() || mgOverrideGates {
                        PlainToggle("PWM 调光开关", minVrs: 19.0, isOn: store.mgKeyBinding([MGKey.pwm]))
                    }
                    if ogMachineName.contains("iPhone") || mgOverrideGates {
                        PlainToggle("Apple Pencil 设置项", isOn: store.mgKeyBinding([MGKey.appPencil]))
                    }
                    if !isCamControlHD() || mgOverrideGates {
                        PlainToggle("相机控制按键设置项", minVrs: 18.0, isOn: store.mgKeyBinding([MGKey.camButton, MGKey.grapPefr]))
                    }
                    if !isActionButtonHD() || mgOverrideGates {
                        PlainToggle("操作按钮 (Action Button)", minVrs: 17.0, isOn: store.mgKeyBinding([MGKey.actButton]))
                    }
                    if isHomeButtonHD() || mgOverrideGates {
                        PlainToggle("轻点唤醒 (Tap to Wake)", isOn: store.mgKeyBinding([MGKey.tapToWake]))
                    }
                } header: {
                    HeaderLabel("系统设置偏好面板", symbol: "gear")
                }
                
                if machineName().contains("iPad") || mgOverrideGates {
                    Section {
                        PlainToggle("启用台前调度 (Stage Manager)", isOn: store.mgKeyBinding([MGKey.stageMgr]))
                        if !machineName().contains("iPad") {
                            PlainToggle("启用 iPadOS 界面与分屏（已由防白苹果护栏永久禁用）", infoType: .warning, infoMessage: MGMsg.ipadOS, isOn: store.mgTrollPadBinding())
                                .disabled(!store.mgTrollPadBinding().wrappedValue)
                        }
                    } header: {
                        HeaderLabel("iPadOS 多任务特性", symbol: "ipad")
                    }
                }
            }
            .navigationTitle("MobileGestalt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            store.mgCurrentDict = mgLoadData()
                            Haptic.shared.play(.soft)
                        } label: {
                            Label("放弃未保存修改", systemImage: "arrow.counterclockwise")
                        }
                        
                        Button {
                            promptFactoryRestore()
                        } label: {
                            Label("还原原始备份", systemImage: "xmark")
                        }
                        .disabled(!hasWriteAccess && !weOnADebugBuild)
                        
                        Button(role: .destructive) {
                            Alertinator.shared.alert(title: "确定要彻底重建原厂 MobileGestalt 缓存吗？", body: MGMsg.mgReset, actionLabel: "确认重建", action: {
                                switch mgExecuteCleanCacheRebuild() {
                                case .success:
                                    Alertinator.shared.alert(title: "已准备原厂缓存重建！", body: MGMsg.mgResetComp, showCancel: false, actionLabel: "退出并手动重启", action: { exitinator() })
                                case .failure(let err):
                                    print("(mg) failed to reset mobilegestalt: \(err.localizedDescription)")
                                    Alertinator.shared.alert(title: "重建缓存失败！", body: err.localizedDescription)
                                }
                            })
                        } label: {
                            Label("清除并重建缓存", systemImage: "trash")
                        }
                        .disabled(!hasWriteAccess && !weOnADebugBuild)
                        
                        Divider()
                        
                        if showCustomKeys {
                            NavigationLink(destination: CustomKeyView()) {
                                Label("自定义键值", systemImage: "pencil")
                            }
                        }
                        
                        // tweak-specific settings
                        NavigationLink {
                            List {
                                Section {
                                    Button("导出当前 MobileGestalt") {
                                        if let tempURL = makeTemp(MGURL.fsGestaltURL) {
                                            presentShareSheet(with: tempURL)
                                        }
                                    }
                                    Button("导出原始备份 (OriginalGestalt)") {
                                        presentShareSheet(with: MGURL.savedGestaltURL)
                                    }
                                    Button("导入外部原始备份 (.plist)") {
                                        showBackupImporter = true
                                    }
                                    if fm.fileExists(atPath: MGURL.preApplyGestaltURL.path) {
                                        Button("导出上次写入前快照 (PreApply)") {
                                            presentShareSheet(with: MGURL.preApplyGestaltURL)
                                        }
                                    }
                                    Button("重新生成原始备份", role: .destructive) {
                                        Alertinator.shared.alert(title: "警告！", body: MGMsg.mgResetSavWarn, actionLabel: "确认覆盖", action: {
                                            try? fm.removeItem(at: MGURL.savedGestaltURL)
                                            try? fm.removeItem(at: MGURL.savedGestaltSHA256URL)
                                            try? fm.removeItem(at: MGURL.systemVaultGestaltURL)
                                            try? fm.removeItem(at: MGURL.systemVaultSHA256URL)
                                            store.mgCurrentDict = mgLoadData()
                                        })
                                    }
                                } header: {
                                    HeaderLabel("数据备份与导出", symbol: "loupe")
                                }
                                
                                Section {
                                    PlainToggle("显示被隐藏的修改项", infoType: .warning, infoMessage: MGMsg.hidTweakWarn, isOn: $mgOverrideGates)
                                    Toggle("启用自定义键值功能", isOn: $showCustomKeys)
                                    HStack {
                                        Text("安全原位写入 + 物理刷盘 (F_FULLFSYNC)")
                                        Spacer()
                                        Text("已强制锁定")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack {
                                        Text("跨卸载系统金库冗余备份")
                                        Spacer()
                                        Text(dualVaultReady ? "已同步锁定" : "待同步")
                                            .font(.caption)
                                            .foregroundStyle(dualVaultReady ? Color.green : .secondary)
                                    }
                                } footer: {
                                    Text("防白苹果安全协议已永久锁定无零字节窗口原位覆盖（pwrite + F_FULLFSYNC）与系统级安全金库双备份冗余，即使侧载掉签卸载重装应用也不会丢失原厂初始备份。")
                                }
                            }
                            .navigationTitle("Gestalt 设置")
                            .fileImporter(
                                isPresented: $showBackupImporter,
                                allowedContentTypes: [.propertyList],
                                allowsMultipleSelection: false
                            ) { result in
                                switch result {
                                case .success(let urls):
                                    guard let first = urls.first else { return }
                                    switch mgImportExternalOriginalBackup(from: first) {
                                    case .success(let msg):
                                        Haptic.shared.play(.soft)
                                        store.mgCurrentDict = mgLoadData()
                                        Alertinator.shared.alert(title: "导入原始备份成功！", body: msg)
                                    case .failure(let err):
                                        Alertinator.shared.alert(title: "导入原始备份失败！", body: err.localizedDescription)
                                    }
                                case .failure(let err):
                                    Alertinator.shared.alert(title: "选择文件失败", body: err.localizedDescription)
                                }
                            }
                        } label: {
                            Label("高级设置", systemImage: "gear")
                        }
                    } label: {
                        Label("菜单", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用", role: .adaptiveConfirm) {
                        if !hasShownSheet {
                            Alertinator.shared.runWhenPresentationIdle {
                                showInfoSheet = true
                            }
                        } else {
                            prepareApplyPreview()
                        }
                    }
                    .disabled(!hasWriteAccess && !weOnADebugBuild)
                }
            }
            .sheet(isPresented: $showInfoSheet, onDismiss: {
                if pendingPreviewAfterInfoSheet {
                    pendingPreviewAfterInfoSheet = false
                    prepareApplyPreview(isFromSheet: true)
                }
            }) {
                NavigationStack {
                    VStack {
                        InfoSheet(title: "使用前必读") {
                            InfoSheetCell(title: "重要风险提示！", symbol: "exclamationmark.triangle.fill", context: MGMsg.support)
                                .modifier(SectionPlatter())
                            InfoSheetCell(title: "Apple 智能与机型伪装", symbol: "apple.intelligence", context: MGMsg.spoofAI)
                            InfoSheetCell(title: "iPadOS 界面模式", symbol: "ipad", context: MGMsg.ipadOS)
                            InfoSheetCell(title: "解除地区限制（国行解锁）", symbol: "map", context: MGMsg.region)
                        } button: {
                            Button(idiotButtonTimerComplete ? "我已知晓，查看变更预览" : "请阅读上方提示（4 秒）...") {
                                hasShownSheet = true
                                idiotButtonTimerComplete = false
                                pendingPreviewAfterInfoSheet = true
                                showInfoSheet = false
                            }
                            .buttonStyle(ConfirmButtonStyle())
                            .padding(.horizontal, 30)
                            .padding(.bottom, device.userInterfaceIdiom == .pad ? 25 : 0)
                            .disabled(!idiotButtonTimerComplete)
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            idiotButtonTimerComplete = true
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("取消") {
                                pendingPreviewAfterInfoSheet = false
                                showInfoSheet = false
                                idiotButtonTimerComplete = false
                            }
                        }
                    }
                }
            }
            .sheet(item: $diffPreviewPayload) { payload in
                NavigationStack {
                    List {
                        Section {
                            ForEach(payload.diffs) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.label)
                                        .font(.subheadline.weight(.semibold))
                                    Text(item.keyPath)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("修改前：")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(item.beforeText)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("修改后：")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Color.accentColor)
                                        Text(item.afterText)
                                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            Text("共 \(payload.diffs.count) 项键值变更")
                        } footer: {
                            Text("点击“确认写入”后将自动备份当前缓存、执行原位写入并进行完整读回校验；若校验异常将自动回滚原文件。")
                        }
                    }
                    .navigationTitle("变更对比预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") {
                                diffPreviewPayload = nil
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("确认写入") {
                                let candidate = payload.candidate
                                diffPreviewPayload = nil
                                mgCommit(candidate)
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }
            }
            .sheet(isPresented: $showInspectorSheet) {
                NavigationStack {
                    MGInspectorView(store: store)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") {
                                    showInspectorSheet = false
                                }
                            }
                        }
                }
            }
            .onAppear {
                if ogMachineName.isEmpty {
                    ogMachineName = machineName()
                }
                let isWritable = fm.isWritableFile(atPath: MGURL.fsGestaltURL.path)
                if isWritable {
                    hasWriteAccess = true
                } else {
                    let res = wq.grantAccess(path: MGURL.fsGestaltURL.deletingLastPathComponent().path)
                    hasWriteAccess = res.0 || fm.isWritableFile(atPath: MGURL.fsGestaltURL.path)
                    if !hasWriteAccess {
                        Alertinator.shared.alert(title: "获取 MobileGestalt 写入权限失败！", body: "修改将无法保存生效，请尝试重启本应用后再试。")
                    }
                }
                if !hasLoadedInitialData {
                    hasLoadedInitialData = true
                    store.mgCurrentDict = mgLoadData()
                } else {
                    dualVaultReady = mgHasSyncedSystemVault()
                }
            }
    }

    @ViewBuilder
    private func featureSlotRow(
        title: String,
        subtitle: String,
        infoTitle: String,
        infoMessage: String,
        keys: [String]
    ) -> some View {
        let canModify = store.canModifyFeatureSlot(keys)
        let isNativeOn = store.isFeatureSlotNativeEnabled(keys)
        if isNativeOn && !mgOverrideGates {
            PlainToggle(
                title,
                subtitle: "✅ 本机硬件已原生开启（无需额外修改，已锁定防误关）",
                infoType: .info,
                infoTitle: infoTitle,
                infoMessage: infoMessage,
                isOn: .constant(true)
            )
            .disabled(true)
        } else {
            PlainToggle(
                title,
                subtitle: canModify ? subtitle : "当前系统版本未包含或无法解析此二进制槽位",
                infoType: .info,
                infoTitle: infoTitle,
                infoMessage: infoMessage,
                isOn: store.mgFeatureSlotBinding(keys)
            )
            .disabled(!canModify)
        }
    }

    @ViewBuilder
    private func experimentalSlotRuleRow(
        title: String,
        subtitle: String,
        infoTitle: String,
        infoMessage: String,
        rules: [MGSlotRule]
    ) -> some View {
        let canModify = store.canModifySlotRules(rules)
        let isNativeSatisfied = store.isSlotRulesNativeSatisfied(rules)
        if isNativeSatisfied && !mgOverrideGates {
            PlainToggle(
                title,
                subtitle: "✅ 本机原厂默认已满足目标状态（无需额外修改，已锁定防误改）",
                infoType: .info,
                infoTitle: infoTitle,
                infoMessage: infoMessage,
                isOn: .constant(true)
            )
            .disabled(true)
        } else {
            PlainToggle(
                title,
                subtitle: canModify ? subtitle : "当前系统版本未包含或无法解析此实验性二进制槽位",
                infoType: .info,
                infoTitle: infoTitle,
                infoMessage: infoMessage,
                isOn: store.mgSlotRulesBinding(rules)
            )
            .disabled(!canModify)
        }
    }

    private func isCurrentGestaltUnmodifiedComparedToOriginal(currentDict: NSDictionary, ogDict: NSDictionary) -> Bool {
        let curExtra = currentDict["CacheExtra"] as? NSDictionary ?? [:]
        let ogExtra = ogDict["CacheExtra"] as? NSDictionary ?? [:]
        let curProd = curExtra[MGKey.prodType] as? String ?? ""
        let ogProd = ogExtra[MGKey.prodType] as? String ?? currentOriginalMachineName()
        if !curProd.isEmpty && curProd != ogProd && curProd != currentOriginalMachineName() {
            return false
        }
        let knownTweakKeys: [String] = [
            MGKey.regionCode,
            MGKey.regionInfo,
            MGKey.regionSysconfig,
            MGKey.regModelNumber,
            MGKey.liquidGlassLowPower,
            MGKey.island,
            MGKey.AOTime,
            MGKey.AOD,
            MGKey.AODVibrancy,
            MGKey.chargeLim,
            MGKey.bootChime,
            MGKey.intInstall,
            MGKey.intBuild,
            MGKey.srd,
            MGKey.crashDet,
            MGKey.pwm,
            MGKey.appPencil,
            MGKey.camButton,
            MGKey.grapPefr,
            MGKey.actButton,
            MGKey.tapToWake,
            MGKey.stageMgr,
            MGKey.modelNameOuter1,
            MGKey.modelNameOuter2
        ] + MGKey.appIntellAllKeys + MGKey.advAppIntellKeys + MGKey.mediaHealthAllKeys + MGKey.experimentalCacheSlotKeys + MGKey.ipadosCacheEx
        for key in knownTweakKeys {
            if !mgPlistValuesEqual(curExtra[key], ogExtra[key]) {
                return false
            }
        }
        if let curArt = curExtra[MGKey.artwork] as? NSDictionary,
           let ogArt = ogExtra[MGKey.artwork] as? NSDictionary {
            if !mgPlistValuesEqual(curArt["ArtworkDeviceSubType"], ogArt["ArtworkDeviceSubType"]) ||
               !mgPlistValuesEqual(curArt["ArtworkDeviceProductDescription"], ogArt["ArtworkDeviceProductDescription"]) {
                return false
            }
        }
        if case .success((let layout, let curData)) = MGCacheDataCoordinator.shared.resolveValidated(for: currentDict),
           let origFlags = MGCacheDataCoordinator.shared.originalFlags(for: layout, savedOriginalDict: ogDict) {
            let curGT = curData[layout.greenTeaOffset] == 1
            let curNGT = curData[layout.notGreenTeaOffset] == 1
            if curGT != origFlags.greenTea || curNGT != origFlags.notGreenTea {
                return false
            }
            if let wOff = layout.wapiOffset, let origWapi = origFlags.wapi {
                if (curData[wOff] == 1) != origWapi {
                    return false
                }
            }
            for (fKey, fSlot) in layout.featureSlotIndices where layout.validateSingleBooleanSlot(fSlot, in: curData) {
                if let origVal = origFlags.extraSlots?[fKey], (curData[fSlot * 8] == 1) != origVal {
                    return false
                }
            }
        }
        return true
    }
    
    private func mgLoadData() -> NSMutableDictionary {
        do {
            let mgData = try Data(contentsOf: MGURL.fsGestaltURL)
            let preCheck = mgValidatePlistData(mgData)
            guard preCheck.0 else {
                throw preCheck.1
            }
            let vaultOutcome = try mgEnsureOriginalBackupWithVault(liveData: mgData)
            dualVaultReady = mgHasSyncedSystemVault()
            if vaultOutcome.recoveredFromVault {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    Alertinator.shared.alert(
                        title: "已自动找回原厂初始备份！",
                        body: "检测到应用曾卸载重装，已从系统安全金库无损恢复你最初未修改的原厂 MobileGestalt 备份（SHA-256 校验通过）。"
                    )
                }
            } else if let dirtyWarn = vaultOutcome.suspectedDirtyWarning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    Alertinator.shared.alert(
                        title: "首次备份异常状态提示",
                        body: "\(dirtyWarn)\n\n当前系统状态已被保存为初始备份。若希望获取 100% 纯净原厂基线，可在右上角菜单选择「清除并重建缓存」并重启，或在「高级设置」导入你之前保存的原厂备份。"
                    )
                }
            }
            
            guard let ogDict = NSDictionary(contentsOf: MGURL.savedGestaltURL),
                  let ogCacheExtra = ogDict["CacheExtra"] as? NSDictionary,
                  let ogArtwork = ogCacheExtra[MGKey.artwork] as? NSDictionary else {
                throw "无法从 MobileGestalt 读取原始硬件配置"
            }
            
            mgOgSubtype = ogArtwork["ArtworkDeviceSubType"] as? Int ?? 0
            mgOgDeviceName = ogArtwork["ArtworkDeviceProductDescription"] as? String ?? ""
            
            let ogRegionCode = ogCacheExtra[MGKey.regionCode] as? String ?? ""
            let ogRegionSysconfig = ogCacheExtra[MGKey.regionSysconfig] as? String ?? ""
            let localeRegion = Locale.current.region?.identifier ?? ""
            if ogRegionCode != "LL" || ogRegionSysconfig != "LL/A" || localeRegion != "US" {
                showRegionTweak = true
            }
            
            guard let parsedBaseline = try PropertyListSerialization.propertyList(from: mgData, options: [], format: nil) as? NSDictionary,
                  let currentDict = try PropertyListSerialization.propertyList(from: mgData, options: [.mutableContainersAndLeaves], format: nil) as? NSMutableDictionary else {
                throw "无法解析 MobileGestalt 字典数据"
            }
            mgBaselineDict = parsedBaseline
            MGCacheDataCoordinator.shared.recordBaselineIfNeeded(liveDict: currentDict, savedOriginalDict: ogDict)
            if !showRegionTweak,
               case .success((let layout, let curData)) = MGCacheDataCoordinator.shared.resolveValidated(for: currentDict, checkWapiSlot: true) {
                let origFlags = MGCacheDataCoordinator.shared.originalFlags(for: layout, savedOriginalDict: ogDict)
                if origFlags?.greenTea == true || origFlags?.wapi == true || (layout.wapiOffset.map { curData[$0] == 1 } ?? false) {
                    showRegionTweak = true
                }
            }
            switch MGCacheDataCoordinator.shared.resolveValidated(for: currentDict) {
            case .success((let layout, _)):
                let wapiDesc = layout.wapiOffset.map { String(format: "0x%X", $0) } ?? "N/A"
                print(String(format: "[*] (mg-cache) 本机动态解析成功：UUID=%@, 槽位=%d (%d字节), green-tea=0x%X, not-green-tea=0x%X, wapi=%@",
                             layout.uuid, layout.slotCount, layout.byteCount, layout.greenTeaOffset, layout.notGreenTeaOffset, wapiDesc))
            case .failure(let err):
                print("[!] (mg-cache) 本机动态解析未通过，已锁定二进制缓存修改：\(err.localizedDescription)")
            }
            
            if let cacheExtra = currentDict["CacheExtra"] as? NSDictionary,
               let artwork = cacheExtra[MGKey.artwork] as? NSDictionary {
                mgSubtype = artwork["ArtworkDeviceSubType"] as? Int ?? 0
                mgDeviceName = artwork["ArtworkDeviceProductDescription"] as? String ?? ""
                mgEnableDeviceName = (!mgDeviceName.isEmpty && mgDeviceName != mgOgDeviceName)
                mgProductType = cacheExtra[MGKey.prodType] as? String ?? currentOriginalMachineName()
                
                // Detect OS upgrade build mismatch between OriginalGestalt.plist and live MobileGestalt
                let ogBuild = ogDict["CacheVersion"] as? String ?? ""
                let curBuild = currentDict["CacheVersion"] as? String ?? ""
                if !hasPromptedBuildMismatch && !ogBuild.isEmpty && !curBuild.isEmpty && ogBuild != curBuild {
                    hasPromptedBuildMismatch = true
                    if isCurrentGestaltUnmodifiedComparedToOriginal(currentDict: currentDict, ogDict: ogDict) {
                        Alertinator.shared.alert(
                            title: "检测到系统版本已更新",
                            body: "原始备份文件来自旧版系统 (\(ogBuild))，而当前系统已更新至 \(curBuild)（当前缓存处于原厂未修改状态）。\n\n建议立即将原始备份同步更新为 \(curBuild) 的原厂文件，以免后续误用旧版备份覆盖。",
                            actionLabel: "更新原始备份",
                            action: {
                                try? mgSaveOriginalBackupWithDigest(mgData)
                                store.mgCurrentDict = mgLoadData()
                            }
                        )
                    } else {
                        print("(mg) notice: savedGestalt CacheVersion (\(ogBuild)) differs from current (\(curBuild))")
                    }
                }
            }
            
            return currentDict
        } catch {
            print("(mg) failed to get mobilegestalt: \(error.localizedDescription)")
            Haptic.shared.play(.heavy)
            Alertinator.shared.alert(title: "读取 MobileGestalt 失败！", body: "当前无法正常加载配置文件，请返回上一页并检查日志。", showCancel: false, actionLabel: "返回", action: { dismiss() })
        }
        
        return [:]
    }
    
    private func buildCandidateDict() throws -> NSMutableDictionary {
        let snapshotData = try PropertyListSerialization.data(fromPropertyList: store.mgCurrentDict, format: .binary, options: 0)
        guard let candidate = try PropertyListSerialization.propertyList(from: snapshotData, options: [.mutableContainersAndLeaves], format: nil) as? NSMutableDictionary,
              let cacheExtra = candidate["CacheExtra"] as? NSMutableDictionary else {
            throw "无法构建待写入的 CacheExtra 字典！"
        }
        guard let artwork = cacheExtra[MGKey.artwork] as? NSMutableDictionary else {
            throw "检测到 ArtworkTraits (\(MGKey.artwork)) 字段缺失或非有效字典结构，为防止丢失屏幕特征已拦截写入！"
        }
        
        let targetSubtype = mgOverrideGates ? mgSubtype : mgOgSubtype
        if targetSubtype > 0 {
            artwork["ArtworkDeviceSubType"] = targetSubtype
        }
        let trimmedName = mgDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if mgEnableDeviceName {
            guard !trimmedName.isEmpty else {
                throw "开启“自定义机型名称”时名称不能为空！"
            }
            artwork["ArtworkDeviceProductDescription"] = trimmedName
            cacheExtra[MGKey.modelNameOuter1] = trimmedName
            cacheExtra[MGKey.modelNameOuter2] = trimmedName
        } else {
            if !mgOgDeviceName.isEmpty {
                artwork["ArtworkDeviceProductDescription"] = mgOgDeviceName
            }
            for outerKey in [MGKey.modelNameOuter1, MGKey.modelNameOuter2] {
                if let ogVal = store.originalCacheExtraValue(forKey: outerKey) {
                    cacheExtra[outerKey] = ogVal
                } else {
                    cacheExtra.removeObject(forKey: outerKey)
                }
            }
        }
        
        let safeProdType = (!isAppleIntellHD() || mgOverrideGates) ? mgProductType : currentOriginalMachineName()
        if !safeProdType.isEmpty {
            cacheExtra[MGKey.prodType] = safeProdType
        }
        for item in customKeys {
            if let blockedReason = mgIsDangerousCacheExtraKey(item.key) {
                if item.isOn {
                    throw "自定义键 \(item.key) 已被防白苹果护栏拦截：\(blockedReason)"
                }
                continue
            }
            if item.isOn {
                cacheExtra[item.key] = item.plistValue
            } else if let ogVal = store.originalCacheExtraValue(forKey: item.key) {
                cacheExtra[item.key] = ogVal
            } else {
                cacheExtra.removeObject(forKey: item.key)
            }
        }

        // Self-healing sanitizer: strip non-cached iOS 27 keys and binary CacheData slot keys from CacheExtra
        // in case the device was previously polluted by an older third-party tool before installing Erosion-CN.
        if raveSupported() {
            cacheExtra.removeObject(forKey: MGKey.regionInfo)
            cacheExtra.removeObject(forKey: "0L5PkT61qoH1b/B1USWqjQ")
        }
        for conflictKey in ["iyfxmLogGVIaH7aEgqwcIA", "4snMZS8LJkSctKypt2m+xA", "hiHut/WR+B9Lx/vd0WyeNg", "green-tea", "not-green-tea", "wapi"] + MGKey.advAppIntellKeys + MGKey.mediaHealthAllKeys + MGKey.experimentalCacheSlotKeys {
            cacheExtra.removeObject(forKey: conflictKey)
        }
        return candidate
    }
    
    private func prepareApplyPreview(isFromSheet: Bool = false) {
        do {
            let candidate = try buildCandidateDict()
            if case .failure(let cacheErr) = MGCacheDataCoordinator.shared.validateTransition(from: mgBaselineDict, to: candidate) {
                throw cacheErr.localizedDescription
            }
            let diffs = mgComputeDiff(from: mgBaselineDict, to: candidate)
            if diffs.isEmpty {
                Alertinator.shared.alert(title: "没有待应用的更改", body: "当前各项配置与系统缓存文件中的内容完全一致，无需重复写入。", showCancel: true)
                return
            }
            let payload = MGDiffPreviewPayload(diffs: diffs, candidate: candidate)
            if diffPreviewPayload != nil {
                diffPreviewPayload = nil
            }
            Alertinator.shared.runWhenPresentationIdle {
                diffPreviewPayload = payload
            }
        } catch {
            Alertinator.shared.alert(title: "无法生成变更预览", body: "\(error.localizedDescription)")
        }
    }

    private func mgCommit(_ mgDictToApply: NSMutableDictionary) {
        do {
            let cacheDataChanged = (mgBaselineDict["CacheData"] as? Data) != (mgDictToApply["CacheData"] as? Data)
            let data = try PropertyListSerialization.data(fromPropertyList: mgDictToApply, format: .binary, options: 0)
            let res = mgWriteDetailed(data)
            
            if res.0 {
                print("[*] successfully overwrote and verified mobilegestalt!")
                Haptic.shared.play(.soft)
                store.mgCurrentDict = mgLoadData()
                if autoRespring && !cacheDataChanged {
                    mgr.shouldRespring = true
                } else {
                    let needsRebootHint = store.isEnabled([MGKey.appIntell]) || store.mgRegionRestrictionsBinding().wrappedValue
                    var extraHint = ""
                    if cacheDataChanged {
                        extraHint = "\n\n⚠️ 本次修改了底层二进制缓存（国行底层限制 / Wi-Fi 显示 / 影像与健康硬件槽位），仅注销无法完全刷新系统守护进程，请务必【手动重启一次手机】使其生效！"
                    } else if needsRebootHint {
                        extraHint = "\n\n若修改了地区限制或 Apple 智能，注销后建议手动重启一次设备以使 eligibilityd 完全刷新。"
                    }
                    Alertinator.shared.alert(
                        title: "写入并读回校验成功！",
                        body: AppMsg.applied + extraHint,
                        actionLabel: "立即注销",
                        action: { mgr.shouldRespring = true }
                    )
                }
            } else {
                throw res.1
            }
        } catch {
            print("(mg) failed to apply mobilegestalt: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "应用 MobileGestalt 失败！", body: "\(error.localizedDescription)")
        }
    }
    
    private func promptFactoryRestore() {
        Alertinator.shared.alert(
            title: "确认一键恢复本机原厂参数？",
            body: MGMsg.revertConfirm,
            actionLabel: "确认恢复原厂",
            action: {
                mgRevert()
            }
        )
    }

    private func mgRevert() {
        switch mgExecuteFactoryRestore(alsoResetConfigAndKeypad: false) {
        case .restoredSuccessfully(let details):
            print("[*] successfully reverted and verified mobilegestalt!")
            Haptic.shared.play(.soft)
            mgEnableDeviceName = false
            store.mgCurrentDict = mgLoadData()
            Alertinator.shared.alert(
                title: "已恢复并校验原厂参数！",
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
                    switch mgExecuteCleanCacheRebuild(alsoResetConfigAndKeypad: false) {
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
            print("(mg) failed to revert mobilegestalt: \(reason)")
            Alertinator.shared.alert(title: "还原 MobileGestalt 失败！", body: reason)
        }
    }
}

#Preview {
    ContentView()
}
