//
//  MGInspectorView.swift
//  Erosion
//
//  Read-only live MobileGestalt MGCopyAnswer verifier, dynamic CacheData slot inspector,
//  and Apple Intelligence 4-Factor readiness checkup panel.
//

import SwiftUI

// MARK: - Feature 2: Apple Intelligence 4-Factor Readiness Checkup Card

struct AppleIntelligenceCheckupCard: View {
    @ObservedObject var store: GestaltStore
    var hasWriteAccess: Bool = true
    var onOpenInspector: () -> Void

    private struct FactorItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isReady: Bool
        let isLiveActive: Bool
    }

    private var expectedUSModel: String {
        let hwProd = originalHardwareProductType()
        let ogReg = (store.originalCacheExtraValue(forKey: MGKey.regModelNumber) as? String) ?? ""
        return usRegulatoryModelNumber(productType: hwProd, originalRegModel: ogReg) ?? "A3473"
    }

    private var factors: [FactorItem] {
        // 1. RegionCode & RegionInfoFromSysconfig
        let stagedRegCode = (store.cacheExtra[MGKey.regionCode] as? String) ?? ""
        let stagedSysconfig = (store.cacheExtra[MGKey.regionSysconfig] as? String) ?? ""
        let ogRegCode = (store.originalCacheExtraValue(forKey: MGKey.regionCode) as? String) ?? stagedRegCode
        let isNativeNonRestrictedRegion = !ogRegCode.isEmpty && ogRegCode != "CH" && ogRegCode != "ZA"
        let isLLOnlyMode = (stagedRegCode == "LL" && stagedSysconfig != "LL/A")
        let regionReady = (stagedRegCode == "LL") || (isNativeNonRestrictedRegion && stagedRegCode != "CH")
        let liveRegion = mgQueryLiveString(forKey: MGKey.regionCode) ?? ""
        let regionLiveOK = !liveRegion.isEmpty && liveRegion != "CH" && liveRegion != "ZA"

        // 2. US RegulatoryModelNumber (97JDvERpVwO+GHtthIh7hA) or Kept Factory Model in LL-Only Mode
        let stagedRegModel = (store.cacheExtra[MGKey.regModelNumber] as? String) ?? ""
        let ogRegModel = (store.originalCacheExtraValue(forKey: MGKey.regModelNumber) as? String) ?? ""
        let usTarget = expectedUSModel
        let regModelReady = isLLOnlyMode
            ? !stagedRegModel.isEmpty
            : ((!stagedRegModel.isEmpty && (stagedRegModel == usTarget || (stagedRegModel.hasPrefix("A") && stagedRegModel != ogRegModel))) || (isNativeNonRestrictedRegion && !stagedRegModel.isEmpty))
        let liveRegModel = mgQueryLiveString(forKey: MGKey.regModelNumber) ?? ""
        let regModelLiveOK = !liveRegModel.isEmpty && (liveRegModel == stagedRegModel || isNativeNonRestrictedRegion)

        // 3. China CacheData Gate (green-tea == 0) & InternalInstall / SiriHub / AdvAI Mutual Exclusion
        let intInstallConflict = store.isEnabled([MGKey.intInstall]) || store.isEnabled([MGKey.intBuild])
        let siriHubConflict = store.isSiriHubConflictActive()
        let advAIConflict = store.isAdvAppleIntellConflictActive()
        var greenTeaCleared = true
        if case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: store.mgCurrentDict) {
            greenTeaCleared = (data[layout.greenTeaOffset] == 0 && data[layout.notGreenTeaOffset] == 1)
        }
        let gateReady = !intInstallConflict && !siriHubConflict && !advAIConflict && greenTeaCleared
        let liveGreenTea = mgQueryLiveBool(forKey: MGCacheDataLayout.greenTeaKey) ?? false
        let liveIntInstall = mgQueryLiveBool(forKey: MGKey.intInstall) ?? false
        let liveSiriHub = mgQueryLiveBool(forKey: MGKey.siriHub) ?? false
        let liveAdvAIConflict = !isAdvAppleIntellHD() && (
            (mgQueryLiveBool(forKey: MGKey.personalTranslator) ?? false) ||
            (mgQueryLiveBool(forKey: MGKey.audioIntell) ?? false)
        )
        let gateLiveOK = !liveGreenTea && !liveIntInstall && !liveSiriHub && !liveAdvAIConflict

        var gateDetail: String
        if intInstallConflict {
            gateDetail = "⚠️ 检测到已开启 InternalInstall 内部模式（与 AI 互斥）"
        } else if siriHubConflict {
            gateDetail = "⚠️ 检测到已开启 SiriHub 路由（会卡死“正在添加 Siri 支持内容”，可一键修复）"
        } else if advAIConflict {
            gateDetail = "⚠️ 检测到已开启进阶 AI 实验槽位（会导致照片“高质量”消除报错，可一键修复）"
        } else if !greenTeaCleared {
            gateDetail = "国行 green-tea 限制槽位未解除（建议开启下方底层解除）"
        } else {
            gateDetail = "green-tea=false · 无内部调试、SiriHub 与消除冲突"
        }

        // 4. Hardware AI Eligibility & Sub-capabilities
        let nativeAI = isAppleIntellHD()
        let nativeAdvAI = isAdvAppleIntellHD()
        let stagedAI = nativeAI || store.mgKeyBinding(MGKey.appIntellAllKeys).wrappedValue
        let aiReady = stagedAI
        let liveAI = mgQueryLiveBool(forKey: MGKey.appIntell) ?? nativeAI

        let aiDetail: String
        if nativeAdvAI {
            aiDetail = "本机 (\(originalHardwareProductType())) 原生支持全部 AI 与 iOS 27 进阶能力"
        } else if nativeAI {
            aiDetail = "本机 (\(originalHardwareProductType())) 硬件原生支持 Apple 智能（含照片消除、通话录音与转写）"
        } else {
            aiDetail = stagedAI
                ? "已开启旧机型 AI 总开关与消除/手写子能力（需配合机型伪装）"
                : "旧机型未开启 AI 开关（需开启并配合机型伪装）"
        }

        return [
            FactorItem(
                id: "region",
                title: isLLOnlyMode ? "1. 区域代码标识 (仅 LL 兼容模式)" : "1. 销售地区标识 (LL / LL/A)",
                detail: "配置：\(stagedRegCode.isEmpty ? "未设置" : stagedRegCode) / \(stagedSysconfig.isEmpty ? "未设置" : stagedSysconfig) · 真机实时：\(liveRegion.isEmpty ? "未知" : liveRegion)",
                isReady: regionReady,
                isLiveActive: regionLiveOK
            ),
            FactorItem(
                id: "regmodel",
                title: isLLOnlyMode ? "2. 监管型号（保留原厂 \(stagedRegModel.isEmpty ? "默认" : stagedRegModel)）" : "2. 美版监管型号 (\(usTarget))",
                detail: "配置：\(stagedRegModel.isEmpty ? "未设置" : stagedRegModel) · 真机实时：\(liveRegModel.isEmpty ? "未知" : liveRegModel)",
                isReady: regModelReady,
                isLiveActive: regModelLiveOK
            ),
            FactorItem(
                id: "gate",
                title: "3. 国行门控与互斥锁检查",
                detail: gateDetail,
                isReady: gateReady,
                isLiveActive: gateLiveOK
            ),
            FactorItem(
                id: "ai",
                title: "4. 端侧 AI 准入与子能力",
                detail: aiDetail,
                isReady: aiReady,
                isLiveActive: liveAI
            )
        ]
    }

    var body: some View {
        let items = factors
        let readyCount = items.filter(\.isReady).count
        let allReady = (readyCount == items.count)
        let allLive = items.allSatisfy(\.isLiveActive)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: allReady ? "sparkles" : "wand.and.stars")
                    .foregroundStyle(allReady ? Color.green : Color.orange)
                    .font(.subheadline.weight(.semibold))
                Text("Apple 智能激活四要素体检")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(allLive ? "真机已生效" : (allReady ? "已配齐 · 待应用重启" : "已配齐 \(readyCount)/\(items.count)"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(allLive ? Color.green.opacity(0.18) : (allReady ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18)))
                    )
                    .foregroundStyle(allLive ? Color.green : (allReady ? Color.blue : Color.orange))
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(item.isReady ? Color.green : Color.orange)
                            .font(.caption)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(item.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 10) {
                if !allReady {
                    Button {
                        Haptic.shared.play(.soft)
                        store.applyAppleIntelligenceOneClickFix()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                            Text("一键配齐 / 修复")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasWriteAccess && !weOnADebugBuild)
                }

                Button {
                    onOpenInspector()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                        Text("真机生效核验探针")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemFill), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Button {
                    Alertinator.shared.alert(title: "普通话来电询问共存指南（测试特性）", body: MGMsg.callScreeningGuide)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.badge.waveform.fill")
                        Text("来电询问共存指南 [测试]")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Feature 1: Read-Only Live MGCopyAnswer Verifier & Dynamic Slot Inspector

struct MGInspectorView: View {
    @ObservedObject var store: GestaltStore
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var filterModifiedOnly = false
    @State private var customProbeKey = ""
    @State private var customProbeResult: String? = nil
    @State private var selectedSlotLiveCache: [String: String] = [:]
    @State private var refreshToken = UUID()

    private struct CuratedProbeItem: Identifiable {
        var id: String { key }
        let title: String
        let key: String
        let category: String
    }

    private let curatedItems: [CuratedProbeItem] = [
        // Region & Regulatory
        CuratedProbeItem(title: "销售地区代码 (RegionCode)", key: MGKey.regionCode, category: "国行解锁与地区准入"),
        CuratedProbeItem(title: "系统销售地区 (RegionInfoFromSysconfig)", key: MGKey.regionSysconfig, category: "国行解锁与地区准入"),
        CuratedProbeItem(title: "监管型号 (RegulatoryModelNumber)", key: MGKey.regModelNumber, category: "国行解锁与地区准入"),
        CuratedProbeItem(title: "机型硬件标识 (ProductType)", key: MGKey.prodType, category: "国行解锁与地区准入"),
        CuratedProbeItem(title: "国行限制标记 (green-tea)", key: MGCacheDataLayout.greenTeaKey, category: "国行解锁与地区准入"),
        CuratedProbeItem(title: "非国行设备标记 (not-green-tea)", key: MGCacheDataLayout.notGreenTeaKey, category: "国行解锁与地区准入"),
        CuratedProbeItem(title: "无线局域网显示标记 (wapi)", key: MGCacheDataLayout.wapiKey, category: "国行解锁与地区准入"),
        // Apple Intelligence & iOS 27 AI
        CuratedProbeItem(title: "Apple 智能总开关 (GenerativeModelSystems)", key: MGKey.appIntell, category: "Apple 智能与 iOS 27 AI"),
        CuratedProbeItem(title: "相册“消除”功能 (Photos Clean Up)", key: MGKey.photosCleanUp, category: "Apple 智能与 iOS 27 AI"),
        CuratedProbeItem(title: "备忘录手写体合成 (Handwriting Synthesis)", key: MGKey.handwritingSynth, category: "Apple 智能与 iOS 27 AI"),
        CuratedProbeItem(title: "个人实时翻译 (Personal Translator)", key: MGKey.personalTranslator, category: "Apple 智能与 iOS 27 AI"),
        CuratedProbeItem(title: "iOS 27 音频智能 (Audio Intelligence)", key: MGKey.audioIntell, category: "Apple 智能与 iOS 27 AI"),
        // Media, Camera & Health
        CuratedProbeItem(title: "相册与相机混音 (Audio Mix)", key: MGKey.audioMix, category: "影像与健康进阶能力"),
        CuratedProbeItem(title: "空间音频录制 (spatial-audio-recording)", key: MGKey.spatialAudioRec, category: "影像与健康进阶能力"),
        CuratedProbeItem(title: "FaceTime 空间音频 (spatial-facetime-audio)", key: MGKey.spatialFaceTimeAudio, category: "影像与健康进阶能力"),
        CuratedProbeItem(title: "按下快门瞬间抓拍 (ResponsiveShutter)", key: MGKey.responsiveShutter, category: "影像与健康进阶能力"),
        CuratedProbeItem(title: "健康高血压趋势评估 (HypertensionNotifications)", key: MGKey.hypertensionNotif, category: "影像与健康进阶能力"),
        // Display & System
        CuratedProbeItem(title: "液态玻璃低功耗渲染", key: MGKey.liquidGlassLowPower, category: "显示与硬件特征"),
        CuratedProbeItem(title: "灵动岛特性 (DynamicIsland)", key: MGKey.island, category: "显示与硬件特征"),
        CuratedProbeItem(title: "全天候显示 (AOD)", key: MGKey.AOD, category: "显示与硬件特征"),
        CuratedProbeItem(title: "80% 充电上限 (80ChargeLimit)", key: MGKey.chargeLim, category: "显示与硬件特征"),
        CuratedProbeItem(title: "开关机提示音 (BootChime)", key: MGKey.bootChime, category: "显示与硬件特征"),
        CuratedProbeItem(title: "操作按钮 (ActionButton)", key: MGKey.actButton, category: "显示与硬件特征"),
        CuratedProbeItem(title: "Apple 内部安装模式 (InternalInstall)", key: MGKey.intInstall, category: "显示与硬件特征"),
        // [测试特性] Experimental Slots
        CuratedProbeItem(title: "[测试] 地区相机快门音豁免", key: MGKey.shutterRelaxation, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 高低功耗双麦并发拾音", key: MGKey.concurrentHPLPMics, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 相册局部光影重绘", key: MGKey.photosLocalLight, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 超取景框空间捕获", key: MGKey.spatialOverCapture, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 立体声视频拾音", key: MGKey.stereoAudioRec, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 旧机型显示电池循环与日期", key: MGKey.legacyBatteryInfo, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 户外高亮全天候显示", key: MGKey.highLuminanceAOD, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] CarPlay Ultra 多屏车载", key: MGKey.carPlay2, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 120Hz 触控采样投递", key: MGKey.touchDelivery120Hz, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 临床助听器音频均衡", key: MGKey.hearingAidEQ, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 睡眠呼吸暂停风险检测", key: MGKey.breathingDisturbances, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 美版血氧软件限制开关", key: MGKey.usBloodOxygen, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 户外极限运动模式", key: MGKey.workoutUltra, category: "测试特性 (CacheData 实验项)"),
        CuratedProbeItem(title: "[测试] 端侧 Siri Hub 意图路由", key: MGKey.siriHub, category: "测试特性 (CacheData 实验项)")
    ]

    var body: some View {
        List {
            Section {
                Picker("查看模式", selection: $selectedTab) {
                    Text("核心核验").tag(0)
                    Text("全量槽位表").tag(1)
                    Text("自由探针").tag(2)
                }
                .pickerStyle(.segmented)
            }

            if selectedTab == 0 {
                curatedVerificationSections
            } else if selectedTab == 1 {
                allSlotsSections
            } else {
                customProbeSections
            }
        }
        .id(refreshToken)
        .searchable(text: $searchText, prompt: "搜索键名、槽位号或功能名称")
        .navigationTitle("真机生效核验与槽位探针")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selectedSlotLiveCache.removeAll()
                    refreshToken = UUID()
                    Haptic.shared.play(.soft)
                } label: {
                    Label("刷新实时状态", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Tab 0: Curated Live Verification

    @ViewBuilder
    private var curatedVerificationSections: some View {
        let layoutResult = MGCacheDataCoordinator.shared.resolveValidated(for: store.mgCurrentDict)
        let ogDict = NSDictionary(contentsOf: MGURL.savedGestaltURL)

        if case .success((let layout, _)) = layoutResult {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "cpu.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("本机 libMobileGestalt.dylib 实时镜像")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(layout.slotCount) 槽位 · \(layout.byteCount) B")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("CacheUUID：\(layout.uuid)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }

        let categories = ["国行解锁与地区准入", "Apple 智能与 iOS 27 AI", "影像与健康进阶能力", "显示与硬件特征"]
        ForEach(categories, id: \.self) { cat in
            let filtered = curatedItems.filter { item in
                guard item.category == cat else { return false }
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                let q = searchText.lowercased()
                return item.title.lowercased().contains(q) || item.key.lowercased().contains(q)
            }
            if !filtered.isEmpty {
                Section {
                    ForEach(filtered) { item in
                        curatedRow(for: item, layoutResult: layoutResult, ogDict: ogDict)
                    }
                } header: {
                    Text(cat)
                }
            }
        }
    }

    @ViewBuilder
    private func curatedRow(
        for item: CuratedProbeItem,
        layoutResult: Result<(MGCacheDataLayout, Data), MGCacheResolutionError>,
        ogDict: NSDictionary?
    ) -> some View {
        let info = evaluateKeyState(key: item.key, layoutResult: layoutResult, ogDict: ogDict)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(info.badgeText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(info.badgeColor.opacity(0.16)))
                    .foregroundStyle(info.badgeColor)
            }

            HStack(spacing: 6) {
                Text(item.key)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let slotBadge = info.slotLocationText {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(slotBadge)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("原机备份")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(info.originalText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("当前配置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(info.stagedText)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                }
                Divider().frame(height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MGCopyAnswer 真机值")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(info.liveText)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(info.badgeColor)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 3)
    }

    private struct KeyEvaluation {
        let slotLocationText: String?
        let originalText: String
        let stagedText: String
        let liveText: String
        let badgeText: String
        let badgeColor: Color
    }

    private func evaluateKeyState(
        key: String,
        layoutResult: Result<(MGCacheDataLayout, Data), MGCacheResolutionError>,
        ogDict: NSDictionary?
    ) -> KeyEvaluation {
        let liveText = mgQueryLiveFormatted(forKey: key)
        let ogExtra = ogDict?["CacheExtra"] as? NSDictionary
        let ogData = ogDict?["CacheData"] as? Data

        var slotLoc: String? = nil
        var origValText = "未设置"
        var stagedValText = "未设置"

        if case .success((let layout, let curData)) = layoutResult,
           let slotIdx = layout.slotIndex(forKey: key),
           layout.validateSingleBooleanSlot(slotIdx, in: curData) {
            let off = slotIdx * 8
            slotLoc = String(format: "CacheData 槽位 #%d (0x%X)", slotIdx, off)
            let curBit = curData[off] == 1
            stagedValText = curBit ? "true (0x01)" : "false (0x00)"

            if let ogData, ogData.count == layout.byteCount, layout.validateSingleBooleanSlot(slotIdx, in: ogData) {
                let ogBit = ogData[off] == 1
                origValText = ogBit ? "true (0x01)" : "false (0x00)"
            } else if let recorded = MGCacheDataCoordinator.shared.originalSlotValue(forKey: key, layout: layout, savedOriginalDict: ogDict) {
                origValText = recorded ? "true (0x01)" : "false (0x00)"
            }
        } else {
            slotLoc = "CacheExtra 字典键"
            if let ogVal = ogExtra?[key] {
                origValText = mgFormatValue(ogVal)
            }
            if let curVal = store.cacheExtra[key] {
                stagedValText = mgFormatValue(curVal)
            }
        }

        let liveNorm = normalizeComparison(liveText)
        let stagedNorm = normalizeComparison(stagedValText)
        let origNorm = normalizeComparison(origValText)

        let badgeText: String
        let badgeColor: Color
        if stagedNorm != origNorm && stagedValText != "未设置" {
            if liveNorm == stagedNorm {
                badgeText = "✅ 已修改并真机生效"
                badgeColor = .green
            } else {
                badgeText = "⏳ 待应用并重启生效"
                badgeColor = .orange
            }
        } else if liveNorm == "true" {
            badgeText = "本机原生开启"
            badgeColor = .blue
        } else {
            badgeText = "原厂默认"
            badgeColor = .secondary
        }

        return KeyEvaluation(
            slotLocationText: slotLoc,
            originalText: origValText,
            stagedText: stagedValText,
            liveText: liveText,
            badgeText: badgeText,
            badgeColor: badgeColor
        )
    }

    private func normalizeComparison(_ text: String) -> String {
        if text.hasPrefix("true") || text == "1 (Int)" || text == "1" { return "true" }
        if text.hasPrefix("false") || text == "0 (Int)" || text == "0" || text.hasPrefix("nil") { return "false" }
        return text
    }

    // MARK: - Tab 1: Full Dynamic Slot Table (0..<slotCount)

    @ViewBuilder
    private var allSlotsSections: some View {
        let layoutResult = MGCacheDataCoordinator.shared.resolveValidated(for: store.mgCurrentDict)
        switch layoutResult {
        case .failure(let err):
            Section {
                Text("当前环境无法解析动态槽位表：\(err.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success((let layout, let curData)):
            let ogDict = NSDictionary(contentsOf: MGURL.savedGestaltURL)
            let ogData = (ogDict?["CacheData"] as? Data)
            let descriptors = MGCacheDataCoordinator.shared.allDescriptors()
            let descBySlot: [Int: [MGSlotDescriptorInfo]] = Dictionary(grouping: descriptors.filter { $0.slotIndex >= 0 }, by: \.slotIndex)

            Section {
                Toggle("仅显示与原厂备份不同的槽位", isOn: $filterModifiedOnly)
            }

            let matchingSlots = (0..<layout.slotCount).filter { slotIdx in
                let off = slotIdx * 8
                if filterModifiedOnly {
                    guard let ogData, ogData.count == curData.count else { return false }
                    let sliceA = curData[off..<(off + 8)]
                    let sliceB = ogData[off..<(off + 8)]
                    let validA = curData[layout.validityOffset(for: slotIdx)]
                    let validB = ogData[layout.validityOffset(for: slotIdx)]
                    if sliceA == sliceB && validA == validB { return false }
                }
                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !q.isEmpty else { return true }
                if "\(slotIdx)".contains(q) || String(format: "0x%x", off).contains(q) {
                    return true
                }
                if let list = descBySlot[slotIdx] {
                    return list.contains { d in
                        d.obfuscatedKey.lowercased().contains(q) ||
                        mgKeyDisplayName(d.obfuscatedKey).lowercased().contains(q)
                    }
                }
                return false
            }

            Section {
                ForEach(matchingSlots, id: \.self) { slotIdx in
                    slotRow(
                        slotIdx: slotIdx,
                        layout: layout,
                        curData: curData,
                        ogData: ogData,
                        descriptors: descBySlot[slotIdx] ?? []
                    )
                }
            } header: {
                Text("动态解析共 \(matchingSlots.count) / \(layout.slotCount) 个槽位（点击行可实时调用 MGCopyAnswer）")
            }
        }
    }

    @ViewBuilder
    private func slotRow(
        slotIdx: Int,
        layout: MGCacheDataLayout,
        curData: Data,
        ogData: Data?,
        descriptors: [MGSlotDescriptorInfo]
    ) -> some View {
        let valOff = slotIdx * 8
        let validOff = layout.validityOffset(for: slotIdx)
        let isValid = curData[validOff] == 1
        let firstByte = curData[valOff]
        let isChanged: Bool = {
            guard let ogData, ogData.count == curData.count else { return false }
            return curData[valOff..<(valOff + 8)] != ogData[valOff..<(valOff + 8)] || curData[validOff] != ogData[validOff]
        }()
        let primaryDesc = descriptors.first
        let keyStr = primaryDesc?.obfuscatedKey ?? "（保留空洞槽位 / 未绑定描述符）"
        let displayTitle = primaryDesc.map { mgKeyDisplayName($0.obfuscatedKey) } ?? "保留槽位 #\(slotIdx)"

        Button {
            if let key = primaryDesc?.obfuscatedKey {
                selectedSlotLiveCache[key] = mgQueryLiveFormatted(forKey: key)
                Haptic.shared.play(.soft)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(format: "槽位 #%d (0x%04X)", slotIdx, valOff))
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(isChanged ? Color.orange : Color.accentColor)
                    if let qType = primaryDesc?.queryType {
                        Text(qType == 11 ? "Bool (qtype=11)" : "qtype=\(qType)")
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(isValid ? (firstByte == 1 ? "0x01 (Valid)" : String(format: "0x%02X (Valid)", firstByte)) : "Invalid (0x00)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(isValid ? (firstByte == 1 ? Color.green : Color.primary) : Color.secondary)
                }

                if displayTitle != keyStr {
                    Text(displayTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }

                Text(keyStr)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let key = primaryDesc?.obfuscatedKey, let liveVal = selectedSlotLiveCache[key] {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundStyle(Color.green)
                        Text("MGCopyAnswer 实时返回：\(liveVal)")
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.green)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 2: Free-Form Key Probe

    @ViewBuilder
    private var customProbeSections: some View {
        Section {
            TextField("输入 22 位混淆键或明文键（如 RegionCode / ProductType）", text: $customProbeKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                let trimmed = customProbeKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let live = mgQueryLiveFormatted(forKey: trimmed)
                var lines: [String] = [
                    "查询键名：\(trimmed)",
                    "MGCopyAnswer 实时返回值：\(live)"
                ]
                if let extraVal = store.cacheExtra[trimmed] {
                    lines.append("当前 CacheExtra 值：\(mgFormatValue(extraVal))")
                } else {
                    lines.append("当前 CacheExtra 值：（不存在）")
                }
                if let ogVal = store.originalCacheExtraValue(forKey: trimmed) {
                    lines.append("原厂 CacheExtra 备份：\(mgFormatValue(ogVal))")
                }
                let allDescs = MGCacheDataCoordinator.shared.allDescriptors()
                if let desc = allDescs.first(where: { $0.obfuscatedKey == trimmed }) {
                    lines.append("系统库描述符：slot = \(desc.slotIndex)，queryType = \(desc.queryType)")
                    if desc.slotIndex >= 0,
                       case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: store.mgCurrentDict),
                       desc.slotIndex < layout.slotCount {
                        let vOff = desc.slotIndex * 8
                        let valOff = layout.validityOffset(for: desc.slotIndex)
                        lines.append(String(format: "CacheData 偏移：0x%X (值=0x%02X)，有效位偏移：0x%X (validity=%d)",
                                            vOff, data[vOff], valOff, data[valOff]))
                    }
                }
                customProbeResult = lines.joined(separator: "\n")
                Haptic.shared.play(.soft)
            } label: {
                Label("立即执行只读探测", systemImage: "magnifyingglass")
            }
        } header: {
            Text("自由键名实时探针（纯只读 · 零写入）")
        } footer: {
            Text("支持直接输入混淆 Base64 键名（如 aVL5GE3tx0LSCI/ErfrJGA）或系统支持的标准明文键名（如 ProductType、RegionCode、BuildVersion），实时对比进程内 MGCopyAnswer 返回值与磁盘缓存状态。")
        }

        if let customProbeResult {
            Section {
                Text(customProbeResult)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            } header: {
                Text("探测结果")
            }
        }
    }
}
