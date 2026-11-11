//
//  GestaltStore.swift
//  Erosion
//
//  Created by lunginspector on 8/19/26.
//

import SwiftUI

import Combine

enum MGURL {
    static let fsGestaltURL = URL(fileURLWithPath: "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist")
    static let savedGestaltURL = URL.documentsDirectory.appendingPathComponent("OriginalGestalt.plist")
    static let savedGestaltSHA256URL = URL.documentsDirectory.appendingPathComponent("OriginalGestalt.sha256")
    static let preApplyGestaltURL = URL.documentsDirectory.appendingPathComponent("PreApplyGestalt.plist")
    // System-level vault inside mobilegestaltcache Caches: survives sideload app uninstall/reinstall while excluded from iCloud/Finder migration
    static let systemVaultGestaltURL = URL(fileURLWithPath: "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/.erosion_factory_vault.plist")
    static let systemVaultSHA256URL = URL(fileURLWithPath: "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/.erosion_factory_vault.sha256")
}

enum MGMsg {
    // warnings
    static let region = "开启后将自动把销售地区改为美版 (LL / LL/A) 并映射对应的美版监管型号 (Axxxx)，用于解锁国行/特定地区受限功能（如完整海外版 Apple 智能 + ChatGPT、快门静音等；注：台湾旗帜在简体中文系统字体下仍由 CoreText 拦截）。请遵守当地法律法规并自行承担使用风险。"
    static let ipadOS = "如果你当前设置了字母数字混合锁屏密码，请切勿开启此项！开启后也切勿关闭“在台前调度中显示程序坞”，否则会导致设备软砖（白苹果循环）。启用 iPadOS 界面后可能出现界面错位、部分应用不兼容等问题。"
    static let support = "请提前备份重要数据！如果某项修改未按预期生效，请勿向官方仓库提交支持请求。许多功能同时受限于设备硬件与 Apple 服务器策略，所有修改均需自行承担风险。"
    static let mgReset = "重置 MobileGestalt 将删除系统原始缓存文件并让系统在重启时重新生成。这有助于彻底清除无法还原的修改，但存在极低概率引发异常，请谨慎操作。"
    
    // info
    static let liquidGlass = "开启后将使用 iOS 26/27 液态玻璃 (Liquid Glass) 的低性能开销渲染模式，可降低 GPU 负载、减少机身发热并节省电量（注销或重启后生效）。"
    static let chinaCacheUnlock = "通过从本机内存加载的系统库 (libMobileGestalt.dylib) 实时动态解析二进制 CacheData 槽位偏移，将国行底层限制标记 green-tea 设为 false、not-green-tea 设为 true。\n\n• 可在所有国行设备上解锁 FaceTime 音频（语音通话）与 AI 底层区域准入；\n• 在自带物理 eSIM 芯片的国行机型（如 iPhone Air 等内置 eUICC 芯片机型）上，可解除系统层针对境外 eSIM 的地理围栏拦截（注：常规双实体卡槽国行主板物理空焊 eUICC 芯片，无法通过纯软件写入虚拟卡）。\n\n安全策略：仅当本机 CacheUUID、总长度、有效位及填充字节 100% 匹配通过时才允许修改；应用后请手动重启手机生效。"
    static let wapiToWifi = "通过本机系统库实时动态解析 wapi 布尔槽位偏移并设为 false，将系统“设置”与控制中心里的“无线局域网”统一显示为国际版的“Wi-Fi”。\n\n⚠️ 重要提示：开启后将会【丢失国行特有的“不允许联网”功能】（即“使用无线局域网与蜂窝网络的 App”中的“关闭”选项）！国际版逻辑仅允许单独关闭“蜂窝数据”，无法禁止单个应用使用 Wi-Fi 联网（如第三方输入法或离线应用将无法彻底断网），同时“启用 WAPI”开关也会隐藏。\n\n如需保留应用“不允许联网”权限控制，请保持此项关闭；若已开启，关闭此开关重新应用并手动重启手机即可原样恢复。"
    static let intInstall = "此选项将启用部分遗留在正式版 iOS 中的 Apple 内部调试特性。注意：开启后可能会影响部分正常功能（如无法从 App Store 重新安装自带系统应用），且与 Apple 智能互斥。"
    static let intBuild = "此开关主要用于在“设置”应用中显示内部存储调试信息。在部分设备（尤其是 iPadOS）上可能引发兼容性问题。"
    static let appleIntellInfo = "为不支持 Apple 智能的旧机型开启端侧生成式 AI 总开关 (DeviceSupportsGenerativeModelSystems)，并自动同步解锁以下 2 项在旧芯片上默认关闭的子能力标记：\n\n• 相册“消除”功能 (Photos Clean Up)\n• 备忘录“手写体合成” (Handwriting Synthesis)\n\n注：旧机型若需实际下载端侧 AI 模型，通常还需配合下方的“机型伪装”与上方的“解除地区限制”使用（修改后请手动重启手机生效）。"
    static let advAppleIntell = "【测试特性】一键解锁 2 项进阶端侧 AI 二进制 CacheData 能力槽位：\n\n1. 个人实时翻译 (Personal Translator · M1n2sAqf33NAOgZRGxQYBA)：电话、FaceTime 与信息中的系统级实时同声传译及个人音色保留翻译能力；\n2. iOS 27 音频智能 (Audio Intelligence · rb2tKZxlj0Gm2tBmUQSLqQ)：语音备忘录与通话录音的端侧进阶流式摘要与环境人声理解增强。\n\n注：部分早期 iOS 27.0 初始固件尚未内置上述进阶键值槽位（通常需 iOS 27.1 / 27.2+），常规通话录音与语音备忘录转写已由上方 Apple 智能与地区准入完整解锁，不受影响（修改后请手动重启手机生效）。"
    static let audioMixInfo = "通过本机系统库实时动态解析 CameracinematicAudioTrackRendering (aVL5GE3tx0LSCI/ErfrJGA) 二进制 CacheData 布尔槽位并设为 true，解锁相册与相机视频编辑中的“混音 (Audio Mix)”功能，支持“标准 / 语音突显 / 录音棚 / 电影效果”四档人声与环境音分离混音（应用后请手动重启手机生效）。"
    static let spatialAudioInfo = "通过本机系统库实时动态解析 spatial-audio-recording 与 spatial-facetime-audio 二进制 CacheData 布尔槽位并同步设为 true，解锁相机视频录制时的 3D 空间音频拾音及 FaceTime 通话空间声场渲染能力（应用后请手动重启手机生效）。"
    static let responsiveShutterInfo = "通过本机系统库实时动态解析 ResponsiveShutter (gQDt76Te0SPw7N8oTLrBFw) 二进制 CacheData 布尔槽位并设为 true，降低相机按下快门至成像管线的触发延迟，实现手指按下瞬间零延迟抓拍（应用后请手动重启手机生效）。"
    static let hypertensionInfo = "通过本机系统库实时动态解析 HypertensionNotifications (4fh9efw4o1yaFqkXNCXoeA) 二进制 CacheData 布尔槽位并设为 true，开启“健康”App 中的血压偏高趋势评估、风险通知与测量记录向导页面（应用后请手动重启手机生效）。"
    static let callScreeningGuide = "【普通话“询问来电原因”与海外 Apple 智能黄金共存方案（测试特性）】\n\nApple 对来电筛选施加了基于系统“地区 (Locale)”的语音过滤：若系统地区设为“美国”会丢失中文普通话来电询问；若保持“中国大陆”则会阻断 Apple 智能。\n\n唯一实测完美共存四步配置：\n1. MobileGestalt：在本页开启“解除地区限制 (LL / LL/A)”并填写对应美版监管型号；\n2. 系统设置 -> 通用 -> 语言与地区：“地区”改为【台湾】，首选语言第一项保持【简体中文】；\n3. 系统设置 -> Apple 智能与 Siri：Siri 语言设为【中文（普通话 - 中国大陆）】；\n4. 分流规则：guzzoni.apple.com 与 *.siri.apple.com 必须走【DIRECT 直连 + 真实 IP (always-real-ip)】防 Siri 报错，仅将 apple-relay.apple.com、gspe1-ssl.ls.apple.com 与 OpenAI 走美区节点（可在“跨容器应用共享组中心”一键导出 Surge 模块）。"
    static let expNotice = "【测试特性提示】本分组所有开关均通过运行时从本机 libMobileGestalt.dylib 实时解析真实 CacheData 布尔槽位（QType=11）并在写前校验 CacheUUID、字节总长与槽位有效位。因不同机型的底层 ISP、传感器或地区守护进程（eligibilityd）支持程度存在差异，部分功能在缺乏物理硬件时仅解锁系统 UI 入口。应用后请【手动重启手机】验证效果，随时可关闭或还原备份。"
    static let expShutterMuteInfo = "【测试特性】传统 RegionalBehaviorShutterClick 为只读动态探针（slot = -1），直接写 CacheExtra 无效。本开关组合修改 3 个真实 CacheData 布尔槽位：\n• DeviceSupportsRegionalCameraShutterRelaxation = true\n• KeyboardMutePreservesRegionalShutterClickBehavior = false\n• ...ForLegacyDevices = false\n可在无需更改整机销售地区的前提下，尝试解除日版 (J/A) 与韩版 (KH/A) 机型的强制相机快门音（应用后请手动重启手机生效）。"
    static let expStudioMicsInfo = "【测试特性】开启高低功耗双阵列麦克风并发拾音槽位 DeviceSupportsConcurrentHPLPMics (dI30ovtFUIeLioNQKDMbGQ)，为语音备忘录录音棚伴奏叠录与多轨人声分离提供底层硬件能力标记（需麦克风 DSP 支持，重启生效）。"
    static let expPhotoToneInfo = "【测试特性】同步开启 PhotosLocalLight、ToneMapping 与 HDRDeferredProcessing 三个影像后期管线布尔槽位，增强相册局部光影重绘、新一代色调映射与深度 HDR 延迟渲染能力（重启生效）。"
    static let expSpatialStereoInfo = "【测试特性】同步开启 SpatialOverCapture、StereoAudioRecording 与 P3ColorspaceVideoRecording 三个视频捕获槽位，解锁超取景框空间视角重构、立体声拾音及 P3 广色域视频编码支持（重启生效）。"
    static let expCamControlInfo = "【测试特性】同步开启 CameraButtonCapability、TouchSensitiveCameraControl、HardwareDetents 与 CameraHaptics 四个交互槽位，解锁完整的“设置 -> 相机 -> 相机控制”电容轻按/滑动变焦配置面板（无物理按键机型仅展示设置面板，重启生效）。"
    static let expLegacyBatteryInfo = "【测试特性】开启 DeviceShowsBatteryModelInformationLegacyHW 与 DynamicEndOfChargeLegacyHW 槽位，在旧款 iPhone / iPad 的“设置 -> 电池 / 关于本机”中尝试展示电池生产日期、首次使用时间与精确充电循环次数（重启生效；亦可使用本工具“物理电池与温控遥测”模块直读底层数据）。"
    static let expHighLumAODInfo = "【测试特性】同步开启 HighLuminanceAlwaysOnDisplay 与 AlwaysOnDisplayFlipbook 槽位，解锁户外高亮全天候显示策略与低功耗翻页帧缓冲渲染（注：非 LTPO 屏幕开启 AOD 会增加待机耗电，重启生效）。"
    static let expCarPlay2Info = "【测试特性】开启 DeviceSupportsCarPlay2 (PR+xeEtTAiUN0R25+EYGfw) 槽位，启用新一代多屏全液晶仪表接管 CarPlay Ultra 车载协议支持（重启生效）。"
    static let expTouch120Info = "【测试特性】开启 TouchDelivery120Hz (2OK50OGmkXM1ospsh766WQ) 槽位，向系统启用 120Hz 触控采样事件投递管线（注：60Hz 物理屏幕面板无法突破 60fps 画面刷新率，仅作用于触控采样投递层，重启生效）。"
    static let expHearingAidInfo = "【测试特性】同步开启 hearingaid-audio-equalization、hearingaid-low-energy-audio 与 hearingaid-power-reduction 三个连续布尔槽位，配合 AirPods Pro 2 / 3 尝试解锁听力健康均衡与临床助听器辅助能力（部分地区仍受 eligibilityd 医疗围栏限制，重启生效）。"
    static let expSleepApneaInfo = "【测试特性】开启 DeviceSupportsBreathingDisturbancesMeasurements (e0HV2blYUDBk/MsMEQACNA) 槽位，解锁“健康 -> 呼吸 -> 呼吸紊乱”睡眠呼吸暂停风险趋势评估页面（需配合 Apple Watch 睡眠监测数据，重启生效）。"
    static let expUSBloodOxygenInfo = "【测试特性】将 DeviceSupportsUSLegallyCompliantBloodOxygen (E4vGMChwcVRKD8hMVxnRvg) 槽位设为 false，解除美版 (LL/A) 设备因专利禁令触发的软件层血氧测量屏蔽（国行机型原生已为 false 无需开启，重启生效）。"
    static let expWorkoutUltraInfo = "【测试特性】同步开启 WorkoutUltraMode 与 DeviceSupportsTimeInDaylight 槽位，解锁极限户外运动辅助模式与健康“日光下时间”环境光监测统计入口（重启生效）。"
    static let expSiriHubInfo = "【测试特性】同步开启 DeviceSupportsSiriHub、OnDeviceSiriCapability 与 InstructionFollowingPruningModels 槽位，启用离线端侧 Siri 意图枢纽路由与端侧大模型动态指令剪枝加速（重启生效）。"
    static let spoofUseless = "伪装设备型号可能会导致面容 ID (Face ID) 等硬件功能失效！你的设备硬件本身已原生支持 Apple 智能，无需修改此项（国行设备只需开启上方“解除地区限制”即可）。"
    static let spoofAI = "对于不支持 Apple 智能的旧机型，仅开启开关无法下载端侧 AI 模型，还需伪装为支持的机型；但伪装机型可能导致面容 ID 失效。取消机型伪装后，请勿再次进入“设置 -> Apple 智能与 Siri”页面。"
    static let subtype = "仅在你想调整灵动岛纵向位置或屏幕分辨率特征时才修改设备子类型 (Subtype)。如需在非灵动岛机型开启灵动岛，请配合下方的“启用灵动岛”开关使用！"
    static let mgResetComp = "已移除当前 MobileGestalt 缓存并将旧备份安全归档。请立即【手动重启你的设备】，系统将在开机时从硬件熔丝重新生成 100% 纯净的原厂参数。"
    static let revertComp = "已通过 SHA-256 与物理落盘校验恢复本机原厂备份，并已同步清空本地自定义开关残留。建议【手动重启一次手机】以确保所有底层参数彻底复原。"
    static let revertConfirm = "即将执行本机原厂参数恢复：\n\n1. 严格核对原厂备份的 SHA-256 摘要、系统版本、CacheUUID 与真实硬件型号；\n2. 通过无零字节窗口原位刷盘 (pwrite + F_FULLFSYNC) 恢复 MobileGestalt 并读回验证；\n3. 同步复位本地自定义键值、自定义机型名与越界门禁开关，杜绝残留回写。"
    static let globalFactoryRestoreConfirm = "即将执行全模块一键恢复原机出厂参数：\n\n1. 恢复并校验本机 MobileGestalt 原厂备份（含 SHA-256 与物理刷盘验证）；\n2. 清除锁屏底部文字、设备资产铭牌及第三方伪监管残留（自动保护真实企业 MDM）；\n3. 清理自定义拨号键盘缓存并复位所有本地偏好状态。"

    // settings
    static let mgResetSavWarn = "重新生成原始备份前，请确保当前已还原所有修改，否则当前处于开启状态的修改会被写入新的原始备份中！"
    static let hidTweakWarn = "显示被隐藏的修改项后，你将能看到当前机型本已原生支持或不兼容的底层开关。盲目改动可能导致功能异常甚至数据丢失！"
}

enum MGKey {
    // bindings
    static let ipadosCacheEx = [
        "uKc7FPnEO++lVhHWHFlGbQ", // ipad
        "mG0AnH/Vy1veoqoLRAIgTA", // MedusaFloatingLiveAppCapability
        "UCG5MkVahJxG1YULbbd5Bg", // MedusaOverlayAppCapability
        "ZYqko/XM5zD3XBfN5RmaXA", // MedusaPinnedAppCapability
        "nVh/gwNpy7Jv1NOk00CMrw", // MedusaPIPCapability,
        "qeaj75wk3HF4DwQ8qbIi7g", // DeviceSupportsEnhancedMultitasking
    ]
    
    // hardware features
    static let island = "YlEtTtHlNesRBMal1CqRaA" // DeviceSupportsDynamicIsland
    static let AOTime = "j8/Omm6s1lsmTDFsXjsBfA" // DeviceSupportsAlwaysOnTime
    static let AOD = "2OOJf1VhaM7NxfRok3HbWQ" // DeviceSupportsAlwaysOnDisplay
    static let AODVibrancy = "ykpu7qyhqFweVMKtxNylWA" // DeviceSupportsAODVibrancy
    static let liquidGlassLowPower = "SAGvsp6O6kAQ4fEfDJpC4Q" // Liquid Glass Low-Power Rendering
    static let chargeLim = "37NVydb//GP/GrhuTN+exg" // DeviceSupports80ChargeLimit
    static let bootChime = "QHxt+hGLaBPbQJbXiUJX3w" // DeviceSupportsBootChime
    
    // internal
    static let intInstall = "EqrsVvjcYDdxHBiQmGhAWw" // apple-internal-install
    static let intBuild = "LBJfwOEzExRxzlAnSuI7eg" // InternalBuild
    
    // eligibility
    static let srd = "XYlJKKkj2hztRP1NWWnhlw" // ResearchFuse
    static let appIntell = "A62OafQ85EJAiiqKn4agtg" // DeviceSupportsGenerativeModelSystems
    static let photosCleanUp = "XNCjqOupLM/S8fNyxRNQTA" // Photos Clean Up
    static let handwritingSynth = "YgYIIViDt1kgzyIsIV61vA" // Handwriting Synthesis
    static let appIntellAllKeys = [
        "A62OafQ85EJAiiqKn4agtg", // DeviceSupportsGenerativeModelSystems
        "XNCjqOupLM/S8fNyxRNQTA", // Photos Clean Up
        "YgYIIViDt1kgzyIsIV61vA", // Handwriting Synthesis
    ]
    static let audioIntell = "rb2tKZxlj0Gm2tBmUQSLqQ" // supports-audio-intelligence
    static let personalTranslator = "M1n2sAqf33NAOgZRGxQYBA" // supports-personal-translator
    static let advAppIntellKeys = [
        "rb2tKZxlj0Gm2tBmUQSLqQ", // Audio Intelligence
        "M1n2sAqf33NAOgZRGxQYBA", // Personal Translator
    ]
    static let advAppIntellRules: [MGSlotRule] = [
        MGSlotRule(key: "rb2tKZxlj0Gm2tBmUQSLqQ", targetValue: true, required: false),
        MGSlotRule(key: "M1n2sAqf33NAOgZRGxQYBA", targetValue: true, required: false),
    ]
    static let regionCode = "h63QSdBCiT/z0WU6rdQv6Q" // RegionCode
    static let regionInfo = "zHeENZu+wbg7PUprwNwBWg" // RegionInfo
    static let regionSysconfig = "yK+xavymRGZ3xWc1tb8XDg" // RegionInfoFromSysconfig
    static let regModelNumber = "97JDvERpVwO+GHtthIh7hA" // RegulatoryModelNumber

    // media, camera & health (CacheData boolean slots)
    static let audioMix = "aVL5GE3tx0LSCI/ErfrJGA"            // CameracinematicAudioTrackRendering (Audio Mix)
    static let spatialAudioRec = "X6NGcYcvHmbqlR8hLXASJA"     // spatial-audio-recording
    static let spatialFaceTimeAudio = "/EVOCjM/Nmb2roP5ebtEFA"// spatial-facetime-audio
    static let spatialAudioAllKeys = [
        "X6NGcYcvHmbqlR8hLXASJA",
        "/EVOCjM/Nmb2roP5ebtEFA",
    ]
    static let responsiveShutter = "gQDt76Te0SPw7N8oTLrBFw"   // ResponsiveShutter
    static let hypertensionNotif = "4fh9efw4o1yaFqkXNCXoeA"   // HypertensionNotifications
    static let mediaHealthAllKeys = [
        "aVL5GE3tx0LSCI/ErfrJGA",
        "X6NGcYcvHmbqlR8hLXASJA",
        "/EVOCjM/Nmb2roP5ebtEFA",
        "gQDt76Te0SPw7N8oTLrBFw",
        "4fh9efw4o1yaFqkXNCXoeA",
    ]
    
    // prefs
    static let crashDet = "HCzWusHQwZDea6nNhaKndw" // DeviceSupportsCollisionSOS
    static let pwm = "6IejgN+1Fmu5/QrZFOIeNw" // DeviceSupportsPulseWidthMaximization
    static let appPencil = "yhHcB0iH0d1XzPO/CFd3ow" // DeviceSupportsApplePencil
    static let camButton = "CwvKxM2cEogD3p+HYgaW0Q" // CameraButtonCapability
    static let grapPefr = "oOV1jhJbdV3AddkcCg0AEA" // apple-graphics-performance-tier
    static let actButton = "cT44WE1EohiwRzhsZ8xEsw" // RingerButtonCapability
    static let tapToWake = "yZf3GTRMGTuwSV/lD7Cagw" // DeviceSupportsTapToWake
    
    // ipados
    static let stageMgr = "qeaj75wk3HF4DwQ8qbIi7g" // DeviceSupportsEnhancedMultitasking
    
    // lookup
    static let deviceClass = "+3Uf0Pm5F8Xy7Onyvko0vA" // DeviceClass
    static let artwork = "oPeik/9e8lQWMszEjbPzng" // ArtworkTraits
    static let prodType = "h9jDsbgj7xIVeIQ8S3/X3Q" // ProductType
    static let modelNameOuter1 = "Z/dqyWS6OZTRy10UcmUAhw" // DeviceProductDescription
    static let modelNameOuter2 = "bbtR9jQx50Fv5Af/affNtA" // MarketingNameString

    // [测试特性] Experimental CacheData Boolean Slot Keys
    static let shutterRelaxation = "P4ZJVy/zYuLy4ejRKP+0DA"
    static let shutterKeyboardMutePreserve = "bGUN8lS6sYzy3xhePubp8A"
    static let shutterLegacyMutePreserve = "Bim3FC83Te8QX1kfSpqYKQ"
    static let concurrentHPLPMics = "dI30ovtFUIeLioNQKDMbGQ"
    static let photosLocalLight = "m9ORTKMgu9A+zF+A61Zz5A"
    static let toneMapping = "Lcu6Zck+C/+AMO8qULacDw"
    static let hdrDeferredProcessing = "JkZlE8z9YwHjE1hnbMhcgA"
    static let spatialOverCapture = "SjQQ07G8UacM7E69G7dPbg"
    static let stereoAudioRec = "YlK+0xmxNWhNn/+r8SM8kA"
    static let p3VideoRec = "1eBwtCIwbIDdC80wiyzfow"
    static let touchSensitiveCamControl = "lyJZrSDc8J8eQ5Zb7A1Rvw"
    static let hardwareDetents = "V9pLLbPQhyb75bbdTioZVw"
    static let cameraHaptics = "XriAxQ+JY1z5nt5f3ftXVw"
    static let legacyBatteryInfo = "Rq0MF/w+gXM66Ii4fkWOzg"
    static let legacyDynamicEndOfCharge = "nfR1IphTGCaoFNu3NrCtWQ"
    static let highLuminanceAOD = "7brdL5xrEUWnlF9C0kdg5A"
    static let aodFlipbook = "aoJSd/MXk7M40NgXTM6x+g"
    static let carPlay2 = "PR+xeEtTAiUN0R25+EYGfw"
    static let touchDelivery120Hz = "2OK50OGmkXM1ospsh766WQ"
    static let hearingAidEQ = "SMgTCc2v9AU2ziIHRX8qww"
    static let hearingAidLE = "RyXm3yMC4ejlFvwlEI509w"
    static let hearingAidPowerRed = "u3c0R+31Df4SUTHrICQkTg"
    static let breathingDisturbances = "e0HV2blYUDBk/MsMEQACNA"
    static let usBloodOxygen = "E4vGMChwcVRKD8hMVxnRvg"
    static let workoutUltra = "fu+4kyf8VcMBtgbMyJlLtg"
    static let timeInDaylight = "8gVfz9/8R1OtWBBtI0o/+Q"
    static let siriHub = "waGD2UTpntjbDXD1r3oALQ"
    static let onDeviceSiri = "O/7gbXWA5X2IRPVtDRU+bw"
    static let modelPruning = "m4xs4mhvxnAopYrApoLDMw"

    static let experimentalCacheSlotKeys: [String] = [
        shutterRelaxation,
        shutterKeyboardMutePreserve,
        shutterLegacyMutePreserve,
        concurrentHPLPMics,
        photosLocalLight,
        toneMapping,
        hdrDeferredProcessing,
        spatialOverCapture,
        stereoAudioRec,
        p3VideoRec,
        touchSensitiveCamControl,
        hardwareDetents,
        cameraHaptics,
        legacyBatteryInfo,
        legacyDynamicEndOfCharge,
        highLuminanceAOD,
        aodFlipbook,
        carPlay2,
        touchDelivery120Hz,
        hearingAidEQ,
        hearingAidLE,
        hearingAidPowerRed,
        breathingDisturbances,
        usBloodOxygen,
        workoutUltra,
        timeInDaylight,
        siriHub,
        onDeviceSiri,
        modelPruning
    ]
}

struct MGSlotRule: Equatable {
    let key: String
    let targetValue: Bool
    var required: Bool = true
}

final class GestaltStore: ObservableObject {
    static let shared = GestaltStore()
    
    @Published var mgCurrentDict = NSMutableDictionary()
    var cacheExtra: NSMutableDictionary {
        return mgCurrentDict["CacheExtra"] as? NSMutableDictionary ?? NSMutableDictionary()
    }
    
    init() {}
    
    // MARK: helpers
    func originalCacheExtraValue(forKey key: String) -> Any? {
        guard let ogDict = NSDictionary(contentsOf: MGURL.savedGestaltURL),
              let ogCacheExtra = ogDict["CacheExtra"] as? NSDictionary else {
            return nil
        }
        return ogCacheExtra[key]
    }
    
    func restoreOrRemoveKey(_ key: String) {
        if let ogVal = originalCacheExtraValue(forKey: key) {
            self.cacheExtra[key] = ogVal
        } else {
            self.cacheExtra.removeObject(forKey: key)
        }
    }
    
    // MARK: actions
    func mgPullKeys(_ keys: [String]) {
        for key in keys {
            restoreOrRemoveKey(key)
        }
    }
    
    func isKeyEnabled(_ key: String, enableValue: Int = 1) -> Bool {
        if let value = self.cacheExtra[key] as? Int, value == enableValue {
            return true
        }
        if case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict),
           let slotIdx = layout.slotIndex(forKey: key),
           layout.validateSingleBooleanSlot(slotIdx, in: data),
           data[slotIdx * 8] == 1 {
            let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
            let origVal = MGCacheDataCoordinator.shared.originalSlotValue(forKey: key, layout: layout, savedOriginalDict: savedOrig) ?? false
            if !origVal {
                return true
            }
        }
        return false
    }

    func isEnabled(_ keys: [String], enableValue: Int = 1) -> Bool {
        guard !keys.isEmpty else { return false }
        return keys.allSatisfy { self.isKeyEnabled($0, enableValue: enableValue) }
    }
    
    func strVal(forKey key: String) -> String {
        let value = self.cacheExtra[key] as? String ?? ""
        return value
    }
    
    // MARK: bindings
    func mgKeyBinding(_ keys: [String], defaultValue: Int = 0, enableValue: Int = 1) -> Binding<Bool> {
        return Binding(get: {
            guard !keys.isEmpty else {
                return false
            }
            return keys.allSatisfy { self.isKeyEnabled($0, enableValue: enableValue) }
        }, set: { enabled in
            self.objectWillChange.send()
            for key in keys {
                if enabled {
                    self.cacheExtra[key] = enableValue
                } else {
                    self.restoreOrRemoveKey(key)
                }
            }
            // Dual-write CacheData slot if this key also has a valid boolean slot in CacheData
            // (bypasses libMobileGestalt's _MGCacheSetValueForKey tbnz validity short-circuit)
            if case .success((let layout, var data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) {
                let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
                var touchedSlot = false
                for key in keys {
                    if let slotIdx = layout.featureSlotIndices[key],
                       layout.validateSingleBooleanSlot(slotIdx, in: data) {
                        if enabled {
                            data[slotIdx * 8] = (enableValue != 0) ? 1 : 0
                        } else {
                            let origVal = MGCacheDataCoordinator.shared.originalSlotValue(forKey: key, layout: layout, savedOriginalDict: savedOrig) ?? false
                            data[slotIdx * 8] = origVal ? 1 : 0
                        }
                        touchedSlot = true
                    }
                }
                if touchedSlot {
                    let testDict = NSMutableDictionary(dictionary: self.mgCurrentDict)
                    testDict["CacheData"] = data
                    if case .success = layout.validatePlist(testDict) {
                        self.mgCurrentDict["CacheData"] = data
                    }
                }
            }
        })
    }
    
    func mgTrollPadBinding() -> Binding<Bool> {
        return Binding(get: {
            guard let firstKey = MGKey.ipadosCacheEx.first,
                  let value = self.cacheExtra[firstKey] as? Int else {
                return false
            }
            return value == 1
        }, set: { enabled in
            if enabled {
                Alertinator.shared.alert(
                    title: "安全护栏已拦截高危操作！",
                    body: "在 iPhone 上强制启用 iPadOS 界面需篡改未经验证的 CacheData 偏移，在锁屏密码或横竖屏切换时极易引发无限白苹果重启与触控冻结，防白苹果护栏已永久禁用该功能。"
                )
            } else {
                self.objectWillChange.send()
                for key in MGKey.ipadosCacheEx {
                    self.restoreOrRemoveKey(key)
                }
            }
        })
    }
    
    func mgRegionRestrictionsBinding() -> Binding<Bool> {
        return Binding<Bool>(
            get: {
                return self.cacheExtra[MGKey.regionCode] as? String == "LL" &&
                    self.cacheExtra[MGKey.regionSysconfig] as? String == "LL/A"
            },
            set: { enabled in
                self.objectWillChange.send()
                if enabled {
                    Alertinator.shared.alert(title: "解除地区限制提示", body: MGMsg.region)
                    self.applyUSRegionAndRegulatoryModel()
                } else {
                    self.restoreOrRemoveKey(MGKey.regionCode)
                    if raveSupported() {
                        self.cacheExtra.removeObject(forKey: MGKey.regionInfo)
                    } else {
                        self.restoreOrRemoveKey(MGKey.regionInfo)
                    }
                    self.restoreOrRemoveKey(MGKey.regionSysconfig)
                    self.restoreOrRemoveKey(MGKey.regModelNumber)
                }
            }
        )
    }

    func applyUSRegionAndRegulatoryModel() {
        self.cacheExtra[MGKey.regionCode] = "LL"
        self.cacheExtra[MGKey.regionSysconfig] = "LL/A"
        // Only write MGKey.regionInfo (zHeENZu+wbg7PUprwNwBWg) on iOS < 27 if present in factory CacheExtra.
        // On iOS 27 (raveSupported()), zHeENZu+wbg7PUprwNwBWg has slot == -1 (non-cached);
        // even if a previous third-party tool polluted OriginalGestalt.plist with it, always strip it on iOS 27
        // so boot-time mobilegestaltd validation never invalidates or resets the cache.
        if !raveSupported(), self.originalCacheExtraValue(forKey: MGKey.regionInfo) != nil {
            self.cacheExtra[MGKey.regionInfo] = "LL/A"
        } else {
            self.cacheExtra.removeObject(forKey: MGKey.regionInfo)
        }
        
        // Always prefer true factory hardware ProductType so model spoofing never mismatches US A-model number
        let prodType = originalHardwareProductType()
        let ogRegModel = (self.originalCacheExtraValue(forKey: MGKey.regModelNumber) as? String) ?? (self.cacheExtra[MGKey.regModelNumber] as? String) ?? ""
        if let usModel = usRegulatoryModelNumber(productType: prodType, originalRegModel: ogRegModel) {
            self.cacheExtra[MGKey.regModelNumber] = usModel
        }
    }
    
    func mgRegModelBinding() -> Binding<String> {
        return Binding<String>(
            get: {
                return self.cacheExtra[MGKey.regModelNumber] as? String ?? ""
            },
            set: { newValue in
                self.objectWillChange.send()
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.restoreOrRemoveKey(MGKey.regModelNumber)
                } else {
                    self.cacheExtra[MGKey.regModelNumber] = trimmed
                }
            }
        )
    }

    // MARK: - Dynamic CacheData Resolution & Strictly Gated Bindings

    func canModifyGreenTeaCache() -> Bool {
        if case .success = MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict) {
            return true
        }
        return false
    }

    func canModifyWapiCache() -> Bool {
        if case .success((let layout, _)) = MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict, checkWapiSlot: true),
           layout.wapiOffset != nil {
            return true
        }
        return false
    }

    func canModifyFeatureSlot(_ keys: [String]) -> Bool {
        guard !keys.isEmpty,
              case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict) else {
            return false
        }
        return keys.allSatisfy { key in
            guard let slotIdx = layout.featureSlotIndices[key] else { return false }
            return layout.validateSingleBooleanSlot(slotIdx, in: data)
        }
    }

    func isFeatureSlotNativeEnabled(_ keys: [String]) -> Bool {
        guard !keys.isEmpty,
              case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict) else {
            return false
        }
        let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
        return keys.allSatisfy { key in
            guard let slotIdx = layout.featureSlotIndices[key],
                  layout.validateSingleBooleanSlot(slotIdx, in: data) else {
                return false
            }
            return MGCacheDataCoordinator.shared.originalSlotValue(forKey: key, layout: layout, savedOriginalDict: savedOrig) == true
        }
    }

    func mgFeatureSlotBinding(_ keys: [String], infoTitle: String? = nil, infoMessage: String? = nil) -> Binding<Bool> {
        return Binding<Bool>(
            get: {
                guard !keys.isEmpty,
                      case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) else {
                    return false
                }
                return keys.allSatisfy { key in
                    guard let slotIdx = layout.featureSlotIndices[key],
                          layout.validateSingleBooleanSlot(slotIdx, in: data) else {
                        return false
                    }
                    return data[slotIdx * 8] == 1
                }
            },
            set: { enabled in
                switch MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) {
                case .failure(let err):
                    Alertinator.shared.alert(title: "动态解析失败，已拒绝修改！", body: err.localizedDescription)
                case .success((let layout, var data)):
                    let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
                    for key in keys {
                        guard let slotIdx = layout.featureSlotIndices[key],
                              layout.validateSingleBooleanSlot(slotIdx, in: data) else {
                            Alertinator.shared.alert(title: "当前系统不支持该槽位！", body: "未能在当前系统库与缓存中验证槽位 \(key) 的有效性，已拒绝修改。")
                            return
                        }
                        if enabled {
                            data[slotIdx * 8] = 1
                        } else {
                            let origVal = MGCacheDataCoordinator.shared.originalSlotValue(forKey: key, layout: layout, savedOriginalDict: savedOrig) ?? false
                            data[slotIdx * 8] = origVal ? 1 : 0
                        }
                    }

                    let testDict = NSMutableDictionary(dictionary: self.mgCurrentDict)
                    if let testExtra = testDict["CacheExtra"] as? NSMutableDictionary {
                        for key in keys {
                            testExtra.removeObject(forKey: key)
                        }
                    }
                    testDict["CacheData"] = data
                    switch layout.validatePlist(testDict) {
                    case .failure(let err):
                        Alertinator.shared.alert(title: "缓存数据校验未通过，已拒绝修改！", body: err.localizedDescription)
                    case .success:
                        self.objectWillChange.send()
                        for key in keys {
                            self.cacheExtra.removeObject(forKey: key)
                        }
                        self.mgCurrentDict["CacheData"] = data
                    }
                }
            }
        )
    }

    func canModifySlotRules(_ rules: [MGSlotRule]) -> Bool {
        guard !rules.isEmpty,
              case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict) else {
            return false
        }
        var matchedCount = 0
        for rule in rules {
            if let slotIdx = layout.featureSlotIndices[rule.key],
               layout.validateSingleBooleanSlot(slotIdx, in: data) {
                matchedCount += 1
            } else if rule.required {
                return false
            }
        }
        return matchedCount > 0
    }

    func isSlotRulesNativeSatisfied(_ rules: [MGSlotRule]) -> Bool {
        guard !rules.isEmpty,
              case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict) else {
            return false
        }
        let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
        var resolvedAny = false
        for rule in rules {
            guard let slotIdx = layout.featureSlotIndices[rule.key],
                  layout.validateSingleBooleanSlot(slotIdx, in: data) else {
                if rule.required { return false }
                continue
            }
            resolvedAny = true
            guard let origVal = MGCacheDataCoordinator.shared.originalSlotValue(forKey: rule.key, layout: layout, savedOriginalDict: savedOrig),
                  origVal == rule.targetValue else {
                return false
            }
        }
        return resolvedAny
    }

    func mgSlotRulesBinding(_ rules: [MGSlotRule]) -> Binding<Bool> {
        return Binding<Bool>(
            get: {
                guard !rules.isEmpty,
                      case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) else {
                    return false
                }
                var resolvedAny = false
                for rule in rules {
                    guard let slotIdx = layout.featureSlotIndices[rule.key],
                          layout.validateSingleBooleanSlot(slotIdx, in: data) else {
                        if rule.required { return false }
                        continue
                    }
                    resolvedAny = true
                    let currentBit = (data[slotIdx * 8] == 1)
                    if currentBit != rule.targetValue {
                        return false
                    }
                }
                return resolvedAny
            },
            set: { enabled in
                switch MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) {
                case .failure(let err):
                    Alertinator.shared.alert(title: "动态解析失败，已拒绝修改！", body: err.localizedDescription)
                case .success((let layout, var data)):
                    let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
                    var touchedKeys: [String] = []
                    for rule in rules {
                        guard let slotIdx = layout.featureSlotIndices[rule.key],
                              layout.validateSingleBooleanSlot(slotIdx, in: data) else {
                            if rule.required {
                                Alertinator.shared.alert(title: "当前系统不支持该实验性槽位！", body: "未能在当前系统库与缓存中验证槽位 \(rule.key) 的有效性，已拒绝修改。")
                                return
                            }
                            continue
                        }
                        if enabled {
                            data[slotIdx * 8] = rule.targetValue ? 1 : 0
                        } else {
                            let origVal = MGCacheDataCoordinator.shared.originalSlotValue(forKey: rule.key, layout: layout, savedOriginalDict: savedOrig) ?? (!rule.targetValue)
                            data[slotIdx * 8] = origVal ? 1 : 0
                        }
                        touchedKeys.append(rule.key)
                    }
                    guard !touchedKeys.isEmpty else { return }

                    let testDict = NSMutableDictionary(dictionary: self.mgCurrentDict)
                    if let testExtra = testDict["CacheExtra"] as? NSMutableDictionary {
                        for key in touchedKeys {
                            testExtra.removeObject(forKey: key)
                        }
                    }
                    testDict["CacheData"] = data
                    switch layout.validatePlist(testDict) {
                    case .failure(let err):
                        Alertinator.shared.alert(title: "缓存数据校验未通过，已拒绝修改！", body: err.localizedDescription)
                    case .success:
                        self.objectWillChange.send()
                        for key in touchedKeys {
                            self.cacheExtra.removeObject(forKey: key)
                        }
                        self.mgCurrentDict["CacheData"] = data
                    }
                }
            }
        )
    }

    func applyAppleIntelligenceOneClickFix() {
        self.objectWillChange.send()
        // 1. Set US LL / LL/A region and matching US RegulatoryModelNumber (Axxxx)
        self.applyUSRegionAndRegulatoryModel()
        // 2. Clear conflicting InternalInstall / InternalBuild flags
        self.mgPullKeys([MGKey.intInstall, MGKey.intBuild])
        // 3. Unlock Mainland China green-tea / not-green-tea slots if originally restricted
        if case .success((let layout, var data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) {
            let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
            let origFlags = MGCacheDataCoordinator.shared.originalFlags(for: layout, savedOriginalDict: savedOrig)
            let ogRegion = (self.originalCacheExtraValue(forKey: MGKey.regionCode) as? String) ?? ""
            if ogRegion == "CH" || ogRegion == "ZA" || origFlags?.greenTea == true || data[layout.greenTeaOffset] == 1 {
                data[layout.greenTeaOffset] = 0
                data[layout.notGreenTeaOffset] = 1
            }
            // 4. For non-native AI hardware, enable AI keys in both CacheExtra & CacheData slots
            if !isAppleIntellHD() {
                for key in MGKey.appIntellAllKeys {
                    self.cacheExtra[key] = 1
                    if let slotIdx = layout.featureSlotIndices[key], layout.validateSingleBooleanSlot(slotIdx, in: data) {
                        data[slotIdx * 8] = 1
                    }
                }
            }
            // 5. For iOS 27 devices whose firmware includes Personal Translator / Audio Intelligence slots and aren't natively enabled, unlock those CacheData slots cleanly
            if raveSupported() && !isAdvAppleIntellHD() {
                for key in MGKey.advAppIntellKeys {
                    if let slotIdx = layout.featureSlotIndices[key], layout.validateSingleBooleanSlot(slotIdx, in: data) {
                        data[slotIdx * 8] = 1
                        self.cacheExtra.removeObject(forKey: key)
                    }
                }
            }
            let testDict = NSMutableDictionary(dictionary: self.mgCurrentDict)
            testDict["CacheData"] = data
            if case .success = layout.validatePlist(testDict) {
                self.mgCurrentDict["CacheData"] = data
            }
        } else if !isAppleIntellHD() {
            for key in MGKey.appIntellAllKeys {
                self.cacheExtra[key] = 1
            }
        }
    }

    func isAdvAppleIntellStagedOrActive() -> Bool {
        if self.mgSlotRulesBinding(MGKey.advAppIntellRules).wrappedValue {
            return true
        }
        return MGKey.advAppIntellKeys.contains { self.isKeyEnabled($0) }
    }

    func cacheResolutionFailureReason() -> String? {
        switch MGCacheDataCoordinator.shared.resolveValidated(for: mgCurrentDict) {
        case .success:
            return nil
        case .failure(let err):
            return err.localizedDescription
        }
    }

    func mgChinaRestrictionCacheBinding() -> Binding<Bool> {
        return Binding<Bool>(
            get: {
                guard case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) else {
                    return false
                }
                return data[layout.greenTeaOffset] == 0 && data[layout.notGreenTeaOffset] == 1
            },
            set: { enabled in
                switch MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict) {
                case .failure(let err):
                    print("[!] (mg-cache) 拒绝修改 green-tea：\(err.localizedDescription)")
                    Alertinator.shared.alert(title: "动态解析失败，已拒绝修改！", body: err.localizedDescription)
                case .success((let layout, var data)):
                    let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
                    if enabled {
                        data[layout.greenTeaOffset] = 0
                        data[layout.notGreenTeaOffset] = 1
                    } else {
                        if let orig = MGCacheDataCoordinator.shared.originalFlags(for: layout, savedOriginalDict: savedOrig),
                           !(orig.greenTea == false && orig.notGreenTea == true) {
                            data[layout.greenTeaOffset] = orig.greenTea ? 1 : 0
                            data[layout.notGreenTeaOffset] = orig.notGreenTea ? 1 : 0
                        } else {
                            data[layout.greenTeaOffset] = 1
                            data[layout.notGreenTeaOffset] = 0
                        }
                    }

                    let testDict = NSMutableDictionary(dictionary: self.mgCurrentDict)
                    testDict["CacheData"] = data
                    switch layout.validatePlist(testDict) {
                    case .failure(let err):
                        print("[!] (mg-cache) 修改后自检未通过，拒绝修改：\(err.localizedDescription)")
                        Alertinator.shared.alert(title: "缓存数据校验未通过，已拒绝修改！", body: err.localizedDescription)
                    case .success:
                        self.objectWillChange.send()
                        self.mgCurrentDict["CacheData"] = data
                    }
                }
            }
        )
    }

    func mgWapiWifiBinding() -> Binding<Bool> {
        return Binding<Bool>(
            get: {
                guard case .success((let layout, let data)) = MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict, checkWapiSlot: true),
                      let wOff = layout.wapiOffset else {
                    return false
                }
                return data[wOff] == 0
            },
            set: { enabled in
                switch MGCacheDataCoordinator.shared.resolveValidated(for: self.mgCurrentDict, checkWapiSlot: true) {
                case .failure(let err):
                    print("[!] (mg-cache) 拒绝修改 wapi：\(err.localizedDescription)")
                    Alertinator.shared.alert(title: "动态解析失败，已拒绝修改！", body: err.localizedDescription)
                case .success((let layout, var data)):
                    guard let wOff = layout.wapiOffset else {
                        Alertinator.shared.alert(title: "动态解析失败，已拒绝修改！", body: "当前系统库未能唯一解析 wapi 槽位偏移。")
                        return
                    }
                    let savedOrig = NSDictionary(contentsOf: MGURL.savedGestaltURL)
                    if enabled {
                        data[wOff] = 0
                    } else {
                        if let orig = MGCacheDataCoordinator.shared.originalFlags(for: layout, savedOriginalDict: savedOrig),
                           let origWapi = orig.wapi,
                           origWapi == true {
                            data[wOff] = 1
                        } else {
                            data[wOff] = 1
                        }
                    }

                    let testDict = NSMutableDictionary(dictionary: self.mgCurrentDict)
                    testDict["CacheData"] = data
                    switch layout.validatePlist(testDict, checkWapiSlot: true) {
                    case .failure(let err):
                        print("[!] (mg-cache) 修改后自检未通过，拒绝修改：\(err.localizedDescription)")
                        Alertinator.shared.alert(title: "缓存数据校验未通过，已拒绝修改！", body: err.localizedDescription)
                    case .success:
                        self.objectWillChange.send()
                        self.mgCurrentDict["CacheData"] = data
                        if enabled {
                            Alertinator.shared.alert(title: "无线局域网改 Wi-Fi 重要提示", body: MGMsg.wapiToWifi)
                        }
                    }
                }
            }
        )
    }
    
    // MARK: particular non-binded modifications
    // Disabled permanently by anti-bootloop security audit (SEC-M3-01): blind regex CacheData slicing causes soft-bricks.
    func mgSetiPadOS(enable: Bool) -> Bool {
        print("[!] (mg) blocked unsafe mgSetiPadOS regex CacheData mutation")
        return false
    }
}
