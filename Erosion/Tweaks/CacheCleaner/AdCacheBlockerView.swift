//
//  AdCacheBlockerView.swift
//  Erosion
//
//  Accurate per-app splash & ad-SDK cache folder detector, one-tap locator,
//  and read-only POSIX chmod (0555 / 0755) blocker.
//

import SwiftUI
import Darwin

struct AdCacheFolderItem: Identifiable, Hashable, Sendable {
    let id: String
    let fullPath: String
    let relativePath: String
    let sdkNameZH: String
    let sdkNameEN: String
    var cachedBytes: Int64
    var posixMode: Int

    nonisolated var url: URL { URL(fileURLWithPath: fullPath) }
    nonisolated var parentURL: URL { url.deletingLastPathComponent() }
    nonisolated var folderName: String { url.lastPathComponent }
    nonisolated var isLockedReadOnly: Bool { (posixMode & 0o222) == 0 }
}

struct AppAdCacheEntry: Identifiable, Sendable {
    let id: String
    let bundleID: String
    let displayTitle: String
    let containerURL: URL
    var items: [AdCacheFolderItem]
}

private final class AdScanCancellationFlag: @unchecked Sendable {
    nonisolated let id = UUID()
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var cancelled = false

    nonisolated init() {}

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    nonisolated var isCancelled: Bool {
        lock.lock()
        let val = cancelled
        lock.unlock()
        return val
    }
}

struct AdFolderLocateBrowserView: View {
    let containerURL: URL
    let targetFolderURL: URL

    @State private var parentReadyURL: URL?
    @State private var errorMsg: String?

    var body: some View {
        Group {
            if let parentReadyURL {
                FileBrowserView(path: parentReadyURL, shouldGrant: true)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "scope")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizationManager.isEnglish
                                     ? "Target Ad Folder: \(targetFolderURL.lastPathComponent)"
                                     : "已定位广告目录所在位置：\(targetFolderURL.lastPathComponent)")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(LocalizationManager.isEnglish
                                     ? "Find \"\(targetFolderURL.lastPathComponent)\" below, tap (i) for chmod info or long-press for actions."
                                     : "在下方列表找到「\(targetFolderURL.lastPathComponent)」，点右侧 ⓘ 可看权限详情，或点进查看内部缓存。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .bottom) {
                            Divider()
                        }
                    }
            } else if let errorMsg {
                List {
                    CompactAlert(
                        title: LocalizationManager.isEnglish ? "Unable to Locate Folder" : "无法定位广告目录",
                        symbol: "folder.badge.questionmark",
                        text: errorMsg,
                        color: .orange
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(LocalizationManager.isEnglish ? "Authorizing & locating folder..." : "正在授权并定位目录...")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            guard parentReadyURL == nil && errorMsg == nil else { return }
            let parentURL = targetFolderURL.deletingLastPathComponent()
            let rootGrant = wq.grantAccess(path: containerURL.path)
            guard rootGrant.0 else {
                errorMsg = LocalizationManager.isEnglish
                    ? "Container access denied: \(rootGrant.2)"
                    : "无法获取应用容器权限：\(rootGrant.2)"
                return
            }
            let parentGrant = wq.grantAccess(path: parentURL.path)
            guard parentGrant.0 else {
                errorMsg = LocalizationManager.isEnglish
                    ? "Parent directory access denied: \(parentGrant.2)"
                    : "无法访问上级目录：\(parentGrant.2)"
                return
            }
            _ = wq.grantAccess(path: targetFolderURL.path)
            parentReadyURL = parentURL
        }
    }
}

private struct LocateAdTarget: Identifiable, Hashable {
    let id = UUID()
    let containerURL: URL
    let folderURL: URL?
}

struct AdCacheBlockerView: View {
    @State private var isScanning = false
    @State private var isStopping = false
    @State private var isOperating = false
    @State private var allEntries: [AppAdCacheEntry] = []
    @State private var searchText = ""
    @State private var showEmptyApps = false
    @State private var scanCompletedCount = 0
    @State private var scanTotalCount = 0
    @State private var activeScanToken: AdScanCancellationFlag?
    @State private var busyFolderID: String?
    @State private var locateTarget: LocateAdTarget?

    private static var isEn: Bool { LocalizationManager.isEnglish }

    nonisolated private static let protectedBundleIDs: Set<String> = [
        "com.jbdotparty.Erosion",
        "com.apple.PosterBoard",
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone"
    ]

    // Curated per-app splash & ad cache candidate subpaths (only reported when verified present on disk)
    nonisolated private static let appSpecificAdPaths: [String: [(relPath: String, zh: String, en: String)]] = [
        "com.sina.weibo": [
            ("Documents/wb_ad_cache", "微博开屏广告缓存", "Weibo Splash Ad Cache"),
            ("Library/Caches/wb_ad_cache", "微博开屏广告缓存", "Weibo Splash Ad Cache"),
            ("Documents/WBAdCache", "微博广告素材缓存", "Weibo Ad Asset Cache"),
            ("Library/Caches/WBAdCache", "微博广告素材缓存", "Weibo Ad Asset Cache"),
            ("Library/Caches/wbad_splash", "微博开屏素材", "Weibo Splash Assets")
        ],
        "com.sina.weibolite": [
            ("Documents/wb_ad_cache", "微博轻享版广告缓存", "Weibo Lite Ad Cache"),
            ("Library/Caches/wb_ad_cache", "微博轻享版广告缓存", "Weibo Lite Ad Cache"),
            ("Library/Caches/WBAdCache", "微博广告缓存", "Weibo Ad Cache")
        ],
        "com.zhihu.ios": [
            ("Library/Caches/ZHAdCache", "知乎开屏广告缓存", "Zhihu Splash Ad Cache"),
            ("Library/Caches/ZHSplashAd", "知乎开屏广告", "Zhihu Splash Ad"),
            ("Documents/ZHAdCache", "知乎广告缓存", "Zhihu Ad Cache"),
            ("Library/Caches/LaunchAdCache", "知乎启动广告缓存", "Zhihu Launch Ad Cache")
        ],
        "com.netease.cloudmusic": [
            ("Library/Caches/NEAdCache", "网易云开屏广告缓存", "NetEase Music Ad Cache"),
            ("Library/Caches/AdCache", "网易云广告缓存", "NetEase Ad Cache"),
            ("Documents/AdCache", "网易云广告缓存", "NetEase Ad Cache")
        ],
        "com.tencent.QQMusic": [
            ("Library/Caches/QMAdCache", "QQ音乐开屏广告缓存", "QQ Music Ad Cache"),
            ("Documents/QMAdCache", "QQ音乐广告缓存", "QQ Music Ad Cache"),
            ("Library/Caches/TADCache", "腾讯广告缓存 (TAD)", "Tencent Ad Cache (TAD)")
        ],
        "tv.danmaku.bilianime": [
            ("Library/Caches/SplashAd", "B站开屏广告缓存", "Bilibili Splash Ad"),
            ("Library/Caches/BiliSplashAd", "B站开屏广告", "Bilibili Splash Ad"),
            ("Documents/SplashAd", "B站开屏广告", "Bilibili Splash Ad")
        ],
        "com.bilibili.app.in": [
            ("Library/Caches/SplashAd", "B站国际版开屏广告", "Bilibili Intl Splash Ad")
        ],
        "com.xingin.discover": [
            ("Library/Caches/XYAdCache", "小红书广告缓存", "Rednote Ad Cache"),
            ("Library/Caches/XHSSplashAd", "小红书开屏广告", "Rednote Splash Ad")
        ],
        "com.taobao.taobao4iphone": [
            ("Library/Caches/TanxAd", "阿里妈妈 Tanx 广告", "Alimama Tanx Ad"),
            ("Library/Caches/TanxSDK", "阿里妈妈 Tanx SDK", "Alimama Tanx SDK"),
            ("Documents/SplashAd", "淘宝开屏广告", "Taobao Splash Ad")
        ],
        "com.taobao.fleamarket": [
            ("Library/Caches/TanxAd", "闲鱼 Tanx 广告缓存", "Idlefish Tanx Ad"),
            ("Library/Caches/SplashAd", "闲鱼开屏广告", "Idlefish Splash Ad")
        ],
        "com.jingdong.app.mall": [
            ("Library/Caches/JADYun", "京东直投广告 SDK", "JD JADYun Ad SDK"),
            ("Library/Caches/JDAdSDK", "京东广告 SDK", "JD Ad SDK")
        ],
        "com.meituan.imeituan": [
            ("Library/Caches/MTSplashAd", "美团开屏广告", "Meituan Splash Ad"),
            ("Library/Caches/SplashAd", "美团开屏广告缓存", "Meituan Splash Cache")
        ],
        "com.dianping.dpscope": [
            ("Library/Caches/DPSplashAd", "大众点评开屏广告", "Dianping Splash Ad"),
            ("Library/Caches/SplashAd", "大众点评广告缓存", "Dianping Splash Cache")
        ],
        "com.autonavi.amap": [
            ("Library/Caches/AmapSplashAd", "高德开屏广告", "Amap Splash Ad"),
            ("Library/Caches/SplashAd", "高德广告缓存", "Amap Splash Cache")
        ],
        "com.baidu.BaiduMobile": [
            ("Library/Caches/BaiduMobAd", "百度百青藤广告", "Baidu MobAd"),
            ("Library/Caches/BDAdCache", "百度开屏广告缓存", "Baidu Ad Cache")
        ],
        "com.baidu.tieba": [
            ("Library/Caches/BaiduMobAd", "贴吧百青藤广告", "Tieba BaiduMobAd"),
            ("Library/Caches/TBAdCache", "贴吧广告缓存", "Tieba Ad Cache")
        ],
        "com.baidu.netdisk": [
            ("Library/Caches/BaiduMobAd", "网盘百青藤广告", "Netdisk BaiduMobAd"),
            ("Library/Caches/BDSplashAd", "网盘开屏广告", "Netdisk Splash Ad")
        ],
        "com.gemd.iting": [
            ("Library/Caches/XMLYAdCache", "喜马拉雅广告缓存", "Ximalaya Ad Cache"),
            ("Documents/XMLYAdCache", "喜马拉雅广告缓存", "Ximalaya Ad Cache")
        ],
        "com.hupu.games": [
            ("Library/Caches/HupuAdCache", "虎扑开屏广告", "Hupu Ad Cache")
        ],
        "com.douban.frodo": [
            ("Library/Caches/DoubanAdCache", "豆瓣开屏广告", "Douban Ad Cache")
        ]
    ]

    // Critical guard: never touch or descend into iOS launch snapshots, WebKit, cookies, or user downloads
    nonisolated private static let neverTouchOrDescend: Set<String> = [
        "splashboard",
        "webkit",
        "fscacheddata",
        "com.apple.nsurlsessiond",
        "cookies",
        "httpstorages",
        "preferences",
        "saved application state",
        "cloudkit",
        "snapshots",
        "flutter_assets",
        "downloads",
        "download",
        "uploads",
        "upload",
        "preload",
        "shaders",
        "shadercache",
        "metadata",
        "payload",
        "avatars",
        "database",
        "databases"
    ]

    // Curated lowercased folder names of mainstream iOS Splash & Ad SDKs
    nonisolated private static let exactAdSDKMap: [String: (zh: String, en: String)] = [
        // Kwai / 快手联盟
        "ksadsdk": ("快手广告 SDK (KSAdSDK)", "Kwai Ad SDK (KSAdSDK)"),
        "ksadcache": ("快手广告缓存", "Kwai Ad Cache"),
        "ksad_cache": ("快手广告缓存", "Kwai Ad Cache"),
        "com.kwad.sdk": ("快手联盟 (Kwad)", "Kwai Ad SDK"),
        "kwadsdk": ("快手联盟 SDK", "Kwad SDK"),
        // ByteDance CSJ / Pangle / 穿山甲 / GroMore
        "buadsdk": ("穿山甲广告 (BUAdSDK)", "Pangle / CSJ (BUAdSDK)"),
        "csjadsdk": ("穿山甲广告 SDK", "CSJ Ad SDK"),
        "csjadcache": ("穿山甲广告缓存", "CSJ Ad Cache"),
        "pangle_sdk": ("穿山甲 Pangle SDK", "Pangle Ad SDK"),
        "panglesdk": ("穿山甲 Pangle SDK", "Pangle Ad SDK"),
        "bytedancead": ("字节广告缓存", "ByteDance Ad Cache"),
        "ttadsdk": ("字节穿山甲 (TTAdSDK)", "ByteDance TTAdSDK"),
        "pangolinad": ("穿山甲广告 (Pangolin)", "Pangolin Ad Cache"),
        "gromoread": ("GroMore 聚合广告", "GroMore Ad SDK"),
        // Tencent YLH / GDT / 优量汇 (广点通)
        "gdtmobsdk": ("腾讯优量汇 (GDTMobSDK)", "Tencent YLH (GDTMobSDK)"),
        "gdt_splash": ("优量汇开屏缓存", "GDT Splash Cache"),
        "gdtsplash": ("优量汇开屏缓存", "GDT Splash Cache"),
        "gdtadcache": ("优量汇广告缓存", "GDT Ad Cache"),
        "gdtnetcache": ("优量汇网络缓存", "GDT Net Cache"),
        "tadcache": ("腾讯广告缓存 (TADCache)", "Tencent Ad Cache (TAD)"),
        "tencentad": ("腾讯广告缓存", "Tencent Ad Cache"),
        "qq_ad_cache": ("腾讯广告缓存", "QQ Ad Cache"),
        "ylhadsdk": ("优量汇广告 SDK", "YLH Ad SDK"),
        // Baidu / 百青藤
        "baidumobad": ("百度百青藤广告", "Baidu MobAd SDK"),
        "bd_ad_cache": ("百度广告缓存", "Baidu Ad Cache"),
        "baidusplashad": ("百度开屏广告", "Baidu Splash Ad"),
        "bdsplashad": ("开屏广告缓存 (BDSplashAd)", "Splash Ad Cache (BDSplashAd)"),
        // Other common CN / Global Ad SDKs
        "beizisdk": ("倍孜开屏广告 (BeiZi)", "BeiZi Ad SDK"),
        "beiziad": ("倍孜广告缓存 (BeiZi)", "BeiZi Ad Cache"),
        "octopusad": ("章鱼广告 (OctopusAd)", "Octopus Ad SDK"),
        "jadyun": ("京东直投广告 (JADYun)", "JD JADYun Ad SDK"),
        "jdadsdk": ("京东广告 SDK", "JD Ad SDK"),
        "sigmob": ("Sigmob 广告 SDK", "Sigmob Ad SDK"),
        "windadsdk": ("Sigmob / WindAd", "WindAd SDK"),
        "windad": ("WindAd 广告缓存", "WindAd Cache"),
        "anythinksdk": ("TopOn 聚合广告 (AnyThink)", "TopOn / AnyThink SDK"),
        "toponsdk": ("TopOn 聚合广告 SDK", "TopOn Ad SDK"),
        "tradplus": ("TradPlus 聚合广告", "TradPlus Ad SDK"),
        "mintegral": ("Mintegral 广告 SDK", "Mintegral Ad SDK"),
        "mtgadcache": ("Mintegral 广告缓存", "Mintegral Ad Cache"),
        "tanxad": ("阿里妈妈 Tanx 广告", "Alimama Tanx Ad"),
        "tanxsdk": ("阿里妈妈 Tanx SDK", "Alimama Tanx SDK"),
        "sakuraad": ("樱花广告 SDK", "SakuraAd SDK"),
        "ubixad": ("优比客思广告 (UbixAd)", "UbixAd SDK"),
        "qumengad": ("趣盟广告 (QuMeng)", "QuMeng Ad SDK"),
        "googlemobileads": ("Google Mobile Ads", "Google Mobile Ads"),
        "gadcache": ("Google AdMob 缓存", "Google AdMob Cache"),
        "unityads": ("Unity Ads 缓存", "Unity Ads Cache"),
        "unityadscache": ("Unity Ads 缓存", "Unity Ads Cache"),
        "vunglecache": ("Vungle 广告缓存", "Vungle Ad Cache"),
        "vungle_cache": ("Vungle 广告缓存", "Vungle Ad Cache"),
        "applovin": ("AppLovin 广告缓存", "AppLovin Ad Cache"),
        "chartboost": ("Chartboost 广告缓存", "Chartboost Ad Cache"),
        "inmobicache": ("InMobi 广告缓存", "InMobi Ad Cache"),
        "ironsource": ("ironSource 广告缓存", "ironSource Ad Cache"),
        // Generic splash / launch ad folders
        "splashad": ("开屏广告缓存", "Splash Ad Cache"),
        "splashads": ("开屏广告缓存", "Splash Ads Cache"),
        "splashadcache": ("开屏广告缓存", "Splash Ad Cache"),
        "splash_ad": ("开屏广告缓存", "Splash Ad Cache"),
        "splash_ads": ("开屏广告缓存", "Splash Ads Cache"),
        "splashscreenad": ("开屏广告缓存", "Splash Screen Ad"),
        "launchad": ("启动开屏广告", "Launch Ad Cache"),
        "launchads": ("启动开屏广告", "Launch Ads Cache"),
        "launchadcache": ("启动广告缓存", "Launch Ad Cache"),
        "launch_ad": ("启动广告缓存", "Launch Ad Cache"),
        "xhlaunchadcache": ("XHLaunchAd 开屏广告", "XHLaunchAd Cache"),
        "xhlaunchad": ("XHLaunchAd 开屏广告", "XHLaunchAd Cache"),
        "jwlaunchad": ("JWLaunchAd 开屏广告", "JWLaunchAd Cache"),
        "openscreenad": ("开屏广告目录", "Open Screen Ad"),
        "open_screen_ad": ("开屏广告目录", "Open Screen Ad"),
        "adsplash": ("开屏广告目录", "Ad Splash Cache"),
        "adcache": ("应用内广告缓存", "App Ad Cache"),
        "adscache": ("应用内广告缓存", "App Ads Cache"),
        "ad_cache": ("应用内广告缓存", "App Ad Cache"),
        "ads_cache": ("应用内广告缓存", "App Ads Cache"),
        "advertisingcache": ("广告缓存目录", "Advertising Cache"),
        "startupad": ("启动广告缓存", "Startup Ad Cache"),
        "startupads": ("启动广告缓存", "Startup Ads Cache"),
        "bootad": ("开机广告缓存", "Boot Ad Cache"),
        "wb_ad_cache": ("微博开屏广告缓存", "Weibo Ad Cache"),
        "wbadcache": ("微博广告缓存", "Weibo Ad Cache"),
        "zhadcache": ("知乎广告缓存", "Zhihu Ad Cache"),
        "xyadcache": ("小红书广告缓存", "Rednote Ad Cache"),
        "qmadcache": ("QQ音乐广告缓存", "QQ Music Ad Cache"),
        "xmlyadcache": ("喜马拉雅广告缓存", "Ximalaya Ad Cache")
    ]

    private var detectedEntries: [AppAdCacheEntry] {
        allEntries.filter { !$0.items.isEmpty }
    }

    private var displayedEntries: [AppAdCacheEntry] {
        let base = showEmptyApps ? allEntries : detectedEntries
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter { entry in
            entry.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            entry.bundleID.localizedCaseInsensitiveContains(trimmed) ||
            entry.items.contains {
                $0.relativePath.localizedCaseInsensitiveContains(trimmed) ||
                $0.sdkNameZH.localizedCaseInsensitiveContains(trimmed) ||
                $0.sdkNameEN.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    private var totalAdFoldersCount: Int {
        detectedEntries.reduce(0) { $0 + $1.items.count }
    }

    private var lockedFoldersCount: Int {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter(\.isLockedReadOnly).count
        }
    }

    private var totalReclaimableAdBytes: Int64 {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter { !$0.isLockedReadOnly }.reduce(0) { $0 + $1.cachedBytes }
        }
    }

    private var unlockedFolderCount: Int {
        totalAdFoldersCount - lockedFoldersCount
    }

    private var scanProgressText: String {
        if scanTotalCount > 0 {
            if isStopping {
                return Self.isEn
                    ? "Stopping (\(scanCompletedCount) / \(scanTotalCount))..."
                    : "正在停止 (\(scanCompletedCount) / \(scanTotalCount))..."
            }
            return Self.isEn
                ? "Scanning \(scanCompletedCount) / \(scanTotalCount) apps..."
                : "正在检索开屏广告目录 (\(scanCompletedCount) / \(scanTotalCount))..."
        }
        return Self.isEn ? "Scanning app containers for ad caches..." : "正在扫描各应用开屏广告缓存目录..."
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.isEn ? "Detected Ad Cache Folders" : "已精准定位开屏与广告目录")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(totalAdFoldersCount)")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(totalAdFoldersCount > 0 ? Color.accentColor : Color.secondary)
                                Text(Self.isEn
                                     ? "folders across \(detectedEntries.count) apps"
                                     : "个目录 · 涉及 \(detectedEntries.count) 个应用")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Self.isEn ? "Locked Read-Only" : "已锁死只读")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(lockedFoldersCount) / \(totalAdFoldersCount)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(lockedFoldersCount > 0 ? .green : .secondary)
                        }
                    }

                    if totalReclaimableAdBytes > 0 {
                        Text(Self.isEn
                             ? "Pending ad cache to wipe & lock: \(AppContainerDirectoryHelper.formatBytes(totalReclaimableAdBytes))"
                             : "未锁目录待清空广告体积：\(AppContainerDirectoryHelper.formatBytes(totalReclaimableAdBytes))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Button {
                            scanAdFolders()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text(Self.isEn ? "Rescan" : "重新扫描")
                            }
                            .font(.subheadline)
                            .fixedSize()
                        }
                        .disabled(isScanning || isOperating)

                        Spacer()

                        if totalAdFoldersCount > 0 {
                            Menu {
                                Button {
                                    confirmBatchLockAll()
                                } label: {
                                    Label(
                                        Self.isEn ? "Lock All Detected (0555)" : "一键锁死全部检出项 (0555)",
                                        systemImage: "lock.fill"
                                    )
                                }
                                .disabled(unlockedFolderCount == 0)

                                Button {
                                    batchUnlockAll()
                                } label: {
                                    Label(
                                        Self.isEn ? "Restore All Read-Write (0755)" : "全部恢复默认读写 (0755)",
                                        systemImage: "lock.open.fill"
                                    )
                                }
                                .disabled(lockedFoldersCount == 0)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "ellipsis.circle")
                                    Text(Self.isEn ? "Batch" : "批量操作")
                                }
                                .font(.subheadline)
                                .fixedSize()
                            }
                            .disabled(isScanning || isOperating)
                        }

                        if unlockedFolderCount > 0 {
                            Button {
                                confirmBatchLockAll()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "lock.shield.fill")
                                    Text(Self.isEn ? "Lock All (\(unlockedFolderCount))" : "一键全锁 (\(unlockedFolderCount))")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .fixedSize()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.orange)
                            .fixedSize()
                            .disabled(isScanning || isOperating)
                        }
                    }
                }
                .padding(.vertical, 4)

                PlainToggle(
                    Self.isEn ? "Show Apps Without Detected Ad Folders" : "显示暂未检出广告目录的应用",
                    subtitle: Self.isEn
                        ? "Turn on to manually browse any third-party app container"
                        : "开启后可查看所有扫描到的第三方应用，手动点进容器排查",
                    isOn: $showEmptyApps
                )
            } header: {
                HeaderLabel(Self.isEn ? "Ad Cache Lock Overview" : "精准定位与一键锁死概览", symbol: "lock.shield")
            } footer: {
                Text(Self.isEn
                     ? "Wipes existing assets inside each matched ad cache folder and locks it to POSIX 0555 read-only without needing Filza. System paths, container roots, and user Downloads are strictly excluded. Note: server-streamed or in-memory ads cannot be blocked via disk chmod."
                     : "「一键锁死」会先清空该广告目录内已下载的物料，再将目录锁死为 0555 只读权限（免装 Filza），防止 SDK 反复拉取开屏广告。内置系统白名单与严格命名过滤，绝不误伤 Downloads 等正常目录；点击「定位目录」可直达文件管理器人工确认。\n提示：仅拦截写入本地磁盘的开屏广告，纯服务端实时下发或内存直出广告无效。")
            }

            if isScanning || isOperating {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isOperating
                             ? (Self.isEn ? "Applying chmod permissions..." : "正在安全清理并修改目录权限...")
                             : scanProgressText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if isScanning {
                            Spacer()
                            Button(role: .destructive) {
                                stopScan()
                            } label: {
                                Text(Self.isEn ? "Stop" : "停止")
                                    .font(.subheadline.weight(.medium))
                                    .fixedSize()
                            }
                            .buttonStyle(.borderless)
                            .disabled(isStopping)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if displayedEntries.isEmpty && !isScanning {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.isEn
                             ? "No matching splash ad cache folders found."
                             : "暂未检出符合特征的开屏广告缓存目录")
                            .font(.subheadline.weight(.medium))
                        Text(Self.isEn
                             ? "Some apps store splash ads in custom folders or haven't generated ad caches yet. Turn on 'Show Apps Without Detected Ad Folders' above to browse containers manually."
                             : "部分应用刚安装还未生成广告缓存，或使用了非常规自定义目录；可打开上方「显示暂未检出广告目录的应用」开关后直接浏览其容器目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ForEach(displayedEntries) { entry in
                    Section {
                        // App summary & per-app quick controls
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(appStatusSubtitle(for: entry))
                                    .font(.caption2)
                                    .foregroundStyle(appStatusColor(for: entry))
                            }

                            Spacer(minLength: 8)

                            Button {
                                locateTarget = LocateAdTarget(containerURL: entry.containerURL, folderURL: nil)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                    Text(Self.isEn ? "Container" : "看容器")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            }
                            .buttonStyle(.borderless)
                            .fixedSize()

                            if !entry.items.isEmpty {
                                let hasUnlocked = entry.items.contains { !$0.isLockedReadOnly }
                                Button {
                                    toggleAllForApp(entry, lock: hasUnlocked)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: hasUnlocked ? "lock.fill" : "lock.open.fill")
                                        Text(hasUnlocked
                                             ? (Self.isEn ? "Lock App" : "全锁该应用")
                                             : (Self.isEn ? "Unlock App" : "全部恢复"))
                                    }
                                    .font(.caption.weight(.semibold))
                                    .fixedSize()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(hasUnlocked ? .orange : .green)
                                .fixedSize()
                                .disabled(isScanning || isOperating)
                            }
                        }

                        // Detected ad folders list
                        ForEach(entry.items) { item in
                            AdFolderRowView(
                                item: item,
                                isBusy: isOperating || (busyFolderID == item.id),
                                onLocate: {
                                    locateTarget = LocateAdTarget(containerURL: entry.containerURL, folderURL: item.url)
                                },
                                onToggleLock: {
                                    toggleSingleFolder(item, in: entry)
                                }
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.isEn ? "Splash Ad Blocker" : "开屏广告缓存精准锁死")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $locateTarget) { target in
            if let folderURL = target.folderURL {
                AdFolderLocateBrowserView(
                    containerURL: target.containerURL,
                    targetFolderURL: folderURL
                )
            } else {
                ContainerSubdirBrowserView(containerURL: target.containerURL, relativeSubpath: nil)
            }
        }
        .searchable(
            text: $searchText,
            prompt: Self.isEn ? "Search app, Bundle ID or SDK" : "搜索应用名、Bundle ID 或广告 SDK"
        )
        .onAppear {
            if allEntries.isEmpty && !isScanning && !isOperating {
                scanAdFolders()
            }
        }
    }

    private func appStatusSubtitle(for entry: AppAdCacheEntry) -> String {
        if entry.items.isEmpty {
            return Self.isEn
                ? "0 known ad folders · tap Container to inspect"
                : "未匹配已知广告目录 · 可点「看容器」手动排查"
        }
        let locked = entry.items.filter(\.isLockedReadOnly).count
        let total = entry.items.count
        if locked == total {
            return Self.isEn
                ? "All \(total) ad folders locked (0555)"
                : "已全部锁死只读 (\(locked)/\(total))"
        }
        return Self.isEn
            ? "\(total - locked) unlocked · \(locked) locked"
            : "发现 \(total) 个目录（\(total - locked) 个待锁 · \(locked) 个已锁）"
    }

    private func appStatusColor(for entry: AppAdCacheEntry) -> Color {
        if entry.items.isEmpty { return .secondary }
        let locked = entry.items.filter(\.isLockedReadOnly).count
        return locked == entry.items.count ? .green : .orange
    }

    private func stopScan() {
        guard isScanning, !isStopping else { return }
        isStopping = true
        activeScanToken?.cancel()
    }

    private func scanAdFolders() {
        guard !isScanning && !isOperating else { return }
        let token = AdScanCancellationFlag()
        activeScanToken = token
        isScanning = true
        isStopping = false
        scanCompletedCount = 0
        scanTotalCount = 0
        allEntries = []

        DispatchQueue.global(qos: .userInitiated).async {
            let rawPaths = fsHandlers.getDirPaths(FSURL.appContainers.path)
            var seenPaths = Set<String>()
            var uniquePaths: [String] = []
            uniquePaths.reserveCapacity(rawPaths.count)
            for rawPath in rawPaths {
                let norm = CSStoreEngine.normalizeVarPath(rawPath)
                if seenPaths.insert(norm).inserted {
                    uniquePaths.append(rawPath)
                }
            }

            let totalCount = uniquePaths.count
            DispatchQueue.main.async {
                guard self.activeScanToken?.id == token.id else { return }
                self.scanTotalCount = totalCount
            }

            var deniedContainers: Set<String> = []
            var collected: [AppAdCacheEntry] = []
            let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
            var completed = 0
            var lastUIUpdate = CFAbsoluteTimeGetCurrent()

            for rawPath in uniquePaths {
                if token.isCancelled { break }
                let entry = Self.scanContainerForAdFolders(
                    rawPath: rawPath,
                    selfBID: selfBID,
                    deniedContainers: &deniedContainers,
                    cancelFlag: token
                )
                if token.isCancelled { break }
                completed += 1
                if let entry {
                    collected.append(entry)
                }

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastUIUpdate >= 0.08 || completed == totalCount {
                    lastUIUpdate = now
                    let prog = completed
                    let snap = Self.sortedEntries(collected)
                    DispatchQueue.main.async {
                        guard self.activeScanToken?.id == token.id else { return }
                        self.scanCompletedCount = prog
                        self.allEntries = snap
                    }
                }
            }

            let finalEntries = Self.sortedEntries(collected)
            let finalCompleted = completed
            DispatchQueue.main.async {
                guard self.activeScanToken?.id == token.id else { return }
                self.allEntries = finalEntries
                self.scanCompletedCount = finalCompleted
                self.isScanning = false
                self.isStopping = false
            }
        }
    }

    private func toggleSingleFolder(_ item: AdCacheFolderItem, in entry: AppAdCacheEntry) {
        guard !isScanning && !isOperating else { return }
        let lockTarget = !item.isLockedReadOnly
        busyFolderID = item.id
        isOperating = true

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.setAdFolderLocked(item: item, containerURL: entry.containerURL, locked: lockTarget)
            DispatchQueue.main.async {
                busyFolderID = nil
                isOperating = false
                if outcome.ok {
                    updateFolderState(appID: entry.id, folderID: item.id, mode: outcome.mode, bytes: outcome.bytes)
                    Haptic.shared.notify(.success)
                    ErosionManager.shared.refreshFiles.toggle()
                } else {
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(
                        title: Self.isEn ? "Operation Failed" : "修改权限失败",
                        body: outcome.error ?? (Self.isEn ? "Unknown error" : "未知错误")
                    )
                }
            }
        }
    }

    private func toggleAllForApp(_ entry: AppAdCacheEntry, lock: Bool) {
        guard !isScanning && !isOperating else { return }
        let targets = entry.items.filter { $0.isLockedReadOnly != lock }
        guard !targets.isEmpty else { return }

        if lock {
            let totalBytes = targets.reduce(0) { $0 + $1.cachedBytes }
            Alertinator.shared.alert(
                title: Self.isEn ? "Lock App Ad Folders?" : "确认锁死该应用广告目录？",
                body: Self.isEn
                    ? "Will wipe \(targets.count) detected ad folders in \(entry.displayTitle) (\(AppContainerDirectoryHelper.formatBytes(totalBytes))) and lock them read-only (0555). Restorable anytime."
                    : "将清空「\(entry.displayTitle)」中检出的 \(targets.count) 个广告缓存目录（当前占用 \(AppContainerDirectoryHelper.formatBytes(totalBytes))）并设为 0555 只读锁死，可随时恢复读写。",
                actionLabel: Self.isEn ? "Lock Now" : "立即锁死",
                action: {
                    executeBatch(pairs: targets.map { (entry, $0) }, lock: true)
                }
            )
        } else {
            executeBatch(pairs: targets.map { (entry, $0) }, lock: false)
        }
    }

    private func confirmBatchLockAll() {
        let targets: [(AppAdCacheEntry, AdCacheFolderItem)] = displayedEntries.flatMap { entry in
            entry.items.filter { !$0.isLockedReadOnly }.map { (entry, $0) }
        }
        guard !targets.isEmpty else { return }
        let bytes = targets.reduce(Int64(0)) { $0 + $1.1.cachedBytes }
        Alertinator.shared.alert(
            title: Self.isEn ? "Lock All Detected Ad Folders?" : "确认一键锁死全部检出广告目录？",
            body: Self.isEn
                ? "Will clear \(targets.count) ad cache folders (\(AppContainerDirectoryHelper.formatBytes(bytes))) and set them read-only (0555). Restorable anytime."
                : "将清空共 \(targets.count) 个检出的开屏/广告缓存目录（约 \(AppContainerDirectoryHelper.formatBytes(bytes))）并锁定为 0555 只读状态。需要时可一键恢复默认读写权限。",
            actionLabel: Self.isEn ? "Lock All" : "立即锁死",
            action: {
                executeBatch(pairs: targets, lock: true)
            }
        )
    }

    private func batchUnlockAll() {
        let targets: [(AppAdCacheEntry, AdCacheFolderItem)] = displayedEntries.flatMap { entry in
            entry.items.filter { $0.isLockedReadOnly }.map { (entry, $0) }
        }
        guard !targets.isEmpty else { return }
        executeBatch(pairs: targets, lock: false)
    }

    private func executeBatch(pairs: [(AppAdCacheEntry, AdCacheFolderItem)], lock: Bool) {
        guard !pairs.isEmpty, !isScanning && !isOperating else { return }
        isOperating = true

        DispatchQueue.global(qos: .userInitiated).async {
            var successCount = 0
            var failCount = 0
            var lastError: String?
            var updates: [(appID: String, folderID: String, mode: Int, bytes: Int64)] = []

            for (entry, item) in pairs {
                let res = Self.setAdFolderLocked(item: item, containerURL: entry.containerURL, locked: lock)
                if res.ok {
                    successCount += 1
                    updates.append((entry.id, item.id, res.mode, res.bytes))
                } else {
                    failCount += 1
                    lastError = res.error
                }
            }

            DispatchQueue.main.async {
                isOperating = false
                for u in updates {
                    updateFolderState(appID: u.appID, folderID: u.folderID, mode: u.mode, bytes: u.bytes)
                }
                if successCount > 0 {
                    ErosionManager.shared.refreshFiles.toggle()
                }
                if failCount == 0 {
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(
                        title: lock
                            ? (Self.isEn ? "Locked Read-Only" : "已成功锁死只读")
                            : (Self.isEn ? "Restored Read-Write" : "已恢复默认读写"),
                        body: lock
                            ? (Self.isEn ? "Locked \(successCount) ad cache folders to 0555." : "已成功清理并锁死 \(successCount) 个广告缓存目录 (0555)。")
                            : (Self.isEn ? "Restored \(successCount) ad folders to 0755." : "已将 \(successCount) 个目录恢复为默认 0755 可读写权限。")
                    )
                } else {
                    Haptic.shared.notify(.warning)
                    Alertinator.shared.alert(
                        title: Self.isEn ? "Completed with Errors" : "部分目录处理失败",
                        body: (Self.isEn
                               ? "Succeeded: \(successCount), Failed: \(failCount)."
                               : "成功 \(successCount) 个，失败 \(failCount) 个。")
                            + (lastError.map { "\n\($0)" } ?? "")
                    )
                }
            }
        }
    }

    private func updateFolderState(appID: String, folderID: String, mode: Int, bytes: Int64) {
        guard let appIdx = allEntries.firstIndex(where: { $0.id == appID }),
              let itemIdx = allEntries[appIdx].items.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        allEntries[appIdx].items[itemIdx].posixMode = mode
        allEntries[appIdx].items[itemIdx].cachedBytes = bytes
    }

    // MARK: - Container Scan Helpers

    private static func sortedEntries(_ list: [AppAdCacheEntry]) -> [AppAdCacheEntry] {
        list.sorted { lhs, rhs in
            if lhs.items.isEmpty != rhs.items.isEmpty {
                return !lhs.items.isEmpty
            }
            if lhs.items.count != rhs.items.count {
                return lhs.items.count > rhs.items.count
            }
            return lhs.displayTitle < rhs.displayTitle
        }
    }

    private static func scanContainerForAdFolders(
        rawPath: String,
        selfBID: String,
        deniedContainers: inout Set<String>,
        cancelFlag: AdScanCancellationFlag
    ) -> AppAdCacheEntry? {
        let url = URL(fileURLWithPath: rawPath)
        let normPath = CSStoreEngine.normalizeVarPath(url.path)
        if deniedContainers.contains(normPath) { return nil }

        let knownBID = CSStoreEngine.shared.bundleID(forContainerPath: normPath, allowDiscovery: false)
        if let knownBID, !knownBID.isEmpty {
            if knownBID == selfBID || protectedBundleIDs.contains(knownBID) || knownBID.hasPrefix("com.apple.") {
                return nil
            }
        }

        let wasActive = wq.hasActiveAccess(path: url.path)
        guard wq.grantAccess(path: url.path, requireWrite: false).0 else {
            deniedContainers.insert(normPath)
            return nil
        }
        defer {
            if !wasActive {
                wq.releaseAccess(path: url.path)
            }
        }

        let resolvedBID: String?
        if let knownBID, !knownBID.isEmpty {
            resolvedBID = knownBID
        } else {
            resolvedBID = getBIDFromXattr(url)
        }

        guard let bid = resolvedBID,
              !bid.isEmpty,
              bid != selfBID,
              !protectedBundleIDs.contains(bid),
              !bid.hasPrefix("com.apple.") else {
            if resolvedBID == nil {
                deniedContainers.insert(normPath)
            }
            return nil
        }

        var items: [AdCacheFolderItem] = []
        var seenCanonicalFolders: Set<String> = []
        let stdContainerRoot = CSStoreEngine.normalizeVarPath(url.standardizedFileURL.path)

        // Pass A: Curated per-app known ad paths
        if let specificSpecs = appSpecificAdPaths[bid] {
            for spec in specificSpecs {
                if cancelFlag.isCancelled { return nil }
                let candidateURL = url.appendingPathComponent(spec.relPath)
                let canon = CSStoreEngine.normalizeVarPath(candidateURL.standardizedFileURL.path)
                guard !seenCanonicalFolders.contains(canon),
                      let item = inspectMatchedAdDirectory(
                        dirURL: candidateURL,
                        containerRootStd: stdContainerRoot,
                        sdkZH: spec.zh,
                        sdkEN: spec.en,
                        cancelFlag: cancelFlag
                      ) else {
                    continue
                }
                seenCanonicalFolders.insert(canon)
                items.append(item)
            }
        }

        // Pass B: Shallow scan (depth 1...3) across standard app data subdirectories
        let rootsToScan = ["Documents", "Library/Caches", "Library/Application Support", "tmp"]
        for rootRel in rootsToScan {
            if cancelFlag.isCancelled { return nil }
            let rootURL = url.appendingPathComponent(rootRel)
            var rootSt = stat()
            guard lstat(rootURL.path, &rootSt) == 0,
                  (rootSt.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }

            scanDirectoryShallow(
                dirURL: rootURL,
                containerRootStd: stdContainerRoot,
                currentDepth: 1,
                maxDepth: 3,
                seenCanonicalFolders: &seenCanonicalFolders,
                results: &items,
                cancelFlag: cancelFlag
            )
        }

        items.sort {
            if $0.isLockedReadOnly != $1.isLockedReadOnly {
                return !$0.isLockedReadOnly
            }
            if $0.cachedBytes != $1.cachedBytes {
                return $0.cachedBytes > $1.cachedBytes
            }
            return $0.relativePath < $1.relativePath
        }

        return AppAdCacheEntry(
            id: url.lastPathComponent,
            bundleID: bid,
            displayTitle: AppContainerDirectoryHelper.displayName(for: bid),
            containerURL: url,
            items: items
        )
    }

    private static func scanDirectoryShallow(
        dirURL: URL,
        containerRootStd: String,
        currentDepth: Int,
        maxDepth: Int,
        seenCanonicalFolders: inout Set<String>,
        results: inout [AdCacheFolderItem],
        cancelFlag: AdScanCancellationFlag
    ) {
        guard currentDepth <= maxDepth, !cancelFlag.isCancelled else { return }

        guard let dir = opendir(dirURL.path) else { return }
        defer { closedir(dir) }

        while let entryPtr = readdir(dir) {
            if cancelFlag.isCancelled { return }
            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0 else { continue }

            guard let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else { return }
            let namePtr = UnsafeRawPointer(entryPtr).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if namePtr[0] == 0x2E { // skip ., .., and hidden dotfiles like .com.apple.*
                continue
            }
            let dType = Int32(entryPtr.pointee.d_type)
            if dType != DT_DIR && dType != DT_UNKNOWN {
                continue
            }

            let childName = String(cString: namePtr)
            let lower = childName.lowercased()
            if neverTouchOrDescend.contains(lower) {
                continue
            }

            let childURL = dirURL.appendingPathComponent(childName)
            var st = stat()
            guard lstat(childURL.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }

            let canon = CSStoreEngine.normalizeVarPath(childURL.standardizedFileURL.path)
            if seenCanonicalFolders.contains(canon) {
                continue
            }

            if let match = classifyAdFolder(name: childName) {
                if let item = inspectMatchedAdDirectory(
                    dirURL: childURL,
                    containerRootStd: containerRootStd,
                    sdkZH: match.zh,
                    sdkEN: match.en,
                    cancelFlag: cancelFlag
                ) {
                    seenCanonicalFolders.insert(canon)
                    results.append(item)
                }
                // Do not descend into an already-matched ad SDK directory
                continue
            }

            if currentDepth < maxDepth {
                scanDirectoryShallow(
                    dirURL: childURL,
                    containerRootStd: containerRootStd,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth,
                    seenCanonicalFolders: &seenCanonicalFolders,
                    results: &results,
                    cancelFlag: cancelFlag
                )
            }
        }
    }

    private static func inspectMatchedAdDirectory(
        dirURL: URL,
        containerRootStd: String,
        sdkZH: String,
        sdkEN: String,
        cancelFlag: AdScanCancellationFlag
    ) -> AdCacheFolderItem? {
        var st = stat()
        guard lstat(dirURL.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }

        let ownerName = (try? fm.attributesOfItem(atPath: dirURL.path)[.ownerAccountName] as? String) ?? ""
        guard ownerName == "mobile",
              canSafelyModifyPermissions(url: dirURL, owner: ownerName) else {
            return nil
        }

        let mode = Int(st.st_mode) & 0o777
        let dirStd = CSStoreEngine.normalizeVarPath(dirURL.standardizedFileURL.path)
        let prefix = containerRootStd + "/"
        let relPath = dirStd.hasPrefix(prefix) ? String(dirStd.dropFirst(prefix.count)) : dirURL.lastPathComponent
        let sizeBytes = fastAdFolderSize(atPath: dirURL.path, maxDepth: 6, cancelFlag: cancelFlag)

        return AdCacheFolderItem(
            id: dirStd,
            fullPath: dirURL.path,
            relativePath: relPath,
            sdkNameZH: sdkZH,
            sdkNameEN: sdkEN,
            cachedBytes: sizeBytes,
            posixMode: mode
        )
    }

    // MARK: - Classification & Safety Rules

    nonisolated static func classifyAdFolder(name: String) -> (zh: String, en: String)? {
        let lower = name.lowercased()
        if neverTouchOrDescend.contains(lower) {
            return nil
        }
        if let exact = exactAdSDKMap[lower] {
            return exact
        }

        let tokens = splitBoundaryTokens(name)
        guard tokens.contains("ad") || tokens.contains("ads") else {
            return nil
        }
        let modifiers: Set<String> = ["sdk", "splash", "launch", "cache", "banner", "interstitial", "mob"]
        if tokens.contains(where: { modifiers.contains($0) }) {
            return ("广告缓存目录 (\(name))", "Ad Cache (\(name))")
        }
        return nil
    }

    /// Splits a folder name on `_`, `-`, `.`, spaces, and ASCII camelCase boundaries without substring ambiguity.
    nonisolated static func splitBoundaryTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let scalars = Array(raw.unicodeScalars)

        for i in scalars.indices {
            let s = scalars[i]
            if s == "_" || s == "-" || s == "." || s == " " {
                if !current.isEmpty {
                    tokens.append(current.lowercased())
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            let isUpper = s.value >= 65 && s.value <= 90
            if isUpper && !current.isEmpty {
                let prev = scalars[i - 1]
                let prevIsLower = prev.value >= 97 && prev.value <= 122
                let nextIsLower = (i + 1 < scalars.count) && (scalars[i + 1].value >= 97 && scalars[i + 1].value <= 122)
                if prevIsLower || nextIsLower {
                    tokens.append(current.lowercased())
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.unicodeScalars.append(s)
        }

        if !current.isEmpty {
            tokens.append(current.lowercased())
        }
        return tokens
    }

    // MARK: - Wipe + Lock (0555) & Unlock (0755)

    private static func setAdFolderLocked(
        item: AdCacheFolderItem,
        containerURL: URL,
        locked: Bool
    ) -> (ok: Bool, mode: Int, bytes: Int64, error: String?) {
        let targetURL = item.url
        let targetPath = targetURL.path

        var st = stat()
        guard lstat(targetPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return (false, item.posixMode, item.cachedBytes,
                    isEn ? "Directory no longer exists or is not a folder." : "目标广告目录已不存在。")
        }

        let ownerName = (try? fm.attributesOfItem(atPath: targetPath)[.ownerAccountName] as? String) ?? ""
        guard canSafelyModifyPermissions(url: targetURL, owner: ownerName) else {
            return (false, item.posixMode, item.cachedBytes,
                    isEn ? "Blocked by system container safety policy." : "已被系统安全策略拦截，禁止修改该路径。")
        }

        let containerWasActive = wq.hasActiveAccess(path: containerURL.path)
        let cGrant = wq.grantAccess(path: containerURL.path, requireWrite: true)
        defer {
            if !containerWasActive && cGrant.1 >= 0 {
                wq.releaseAccess(path: containerURL.path)
            }
        }

        let targetWasActive = wq.hasActiveAccess(path: targetPath)
        let tGrant = wq.grantAccess(path: targetPath, requireWrite: true)
        defer {
            if !targetWasActive && tGrant.1 >= 0 {
                wq.releaseAccess(path: targetPath)
            }
        }

        guard tGrant.0 || tGrant.1 >= 0 || cGrant.0 || cGrant.1 >= 0 else {
            return (false, item.posixMode, item.cachedBytes,
                    isEn ? "Sandbox grant failed: \(tGrant.2)" : "沙盒写权限授权失败：\(tGrant.2)")
        }

        if locked {
            // Temporarily ensure 0755 so existing ad assets can be wiped cleanly before locking to 0555
            if Darwin.chmod(targetPath, 0o755) != 0 {
                let err = String(cString: strerror(errno))
                return (false, item.posixMode, item.cachedBytes,
                        isEn ? "chmod 0755 failed: \(err)" : "准备清理目录权限失败：\(err)")
            }
            purgeDirectoryContentsSafely(atPath: targetPath)
        }

        let desiredMode: mode_t = locked ? 0o555 : 0o755
        guard Darwin.chmod(targetPath, desiredMode) == 0 else {
            let err = String(cString: strerror(errno))
            return (false, item.posixMode, item.cachedBytes,
                    isEn ? "chmod failed: \(err)" : "修改权限失败：\(err)")
        }

        var verifySt = stat()
        guard lstat(targetPath, &verifySt) == 0 else {
            return (false, item.posixMode, item.cachedBytes,
                    isEn ? "Failed to verify permissions with lstat." : "lstat 校验权限失败。")
        }

        let verifiedMode = Int(verifySt.st_mode) & 0o777
        let expectedMode = Int(desiredMode)
        guard verifiedMode == expectedMode else {
            return (false, verifiedMode, item.cachedBytes,
                    isEn
                        ? "Mode mismatch: expected \(String(format: "%04o", expectedMode)), got \(String(format: "%04o", verifiedMode))."
                        : "权限校验不一致：预期 \(String(format: "%04o", expectedMode))，实际 \(String(format: "%04o", verifiedMode))。")
        }

        let remainingBytes = fastAdFolderSize(atPath: targetPath, maxDepth: 6, cancelFlag: nil)
        return (true, verifiedMode, remainingBytes, nil)
    }

    /// Empties all entries inside `dirPath` via POSIX lstat/unlink/rmdir without removing `dirPath` itself or following symlinks.
    nonisolated private static func purgeDirectoryContentsSafely(atPath dirPath: String) {
        guard let dir = opendir(dirPath) else { return }
        var childNames: [String] = []
        while let entryPtr = readdir(dir) {
            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0,
                  let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else {
                continue
            }
            let namePtr = UnsafeRawPointer(entryPtr).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if namePtr[0] == 0x2E {
                if nameLen == 1 { continue }
                if nameLen == 2 && namePtr[1] == 0x2E { continue }
            }
            childNames.append(String(cString: namePtr))
        }
        closedir(dir)

        for name in childNames {
            let childPath = (dirPath as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(childPath, &st) == 0 else { continue }
            let fmt = st.st_mode & S_IFMT
            if fmt == S_IFDIR {
                _ = Darwin.chmod(childPath, 0o755)
                purgeDirectoryContentsSafely(atPath: childPath)
                _ = Darwin.rmdir(childPath)
            } else {
                // Unlink symlinks, regular files, sockets, FIFOs directly (never follows symlinks)
                _ = Darwin.unlink(childPath)
            }
        }
    }

    // MARK: - POSIX Fast Folder Size

    nonisolated private static func fastAdFolderSize(
        atPath path: String,
        maxDepth: Int,
        cancelFlag: AdScanCancellationFlag?
    ) -> Int64 {
        var rootSt = stat()
        guard lstat(path, &rootSt) == 0, (rootSt.st_mode & S_IFMT) == S_IFDIR else {
            return 0
        }
        var pathBuf = Array(path.utf8CString)
        var len = pathBuf.count - 1
        while len > 1 && pathBuf[len - 1] == 0x2F {
            len -= 1
        }
        pathBuf[len] = 0
        pathBuf.reserveCapacity(max(Int(PATH_MAX), len + 256))
        return fastSizeRecursive(
            pathBuf: &pathBuf,
            pathLen: len,
            maxDepth: maxDepth,
            currentDepth: 0,
            cancelFlag: cancelFlag
        )
    }

    nonisolated private static func fastSizeRecursive(
        pathBuf: inout [CChar],
        pathLen: Int,
        maxDepth: Int,
        currentDepth: Int,
        cancelFlag: AdScanCancellationFlag?
    ) -> Int64 {
        guard currentDepth <= maxDepth else { return 0 }
        if cancelFlag?.isCancelled == true { return 0 }

        let dir: UnsafeMutablePointer<DIR>? = pathBuf.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return opendir(base)
        }
        guard let dir else { return 0 }
        defer { closedir(dir) }

        let fd = dirfd(dir)
        guard fd >= 0,
              let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else {
            return 0
        }

        var total: Int64 = 0
        while let entryPtr = readdir(dir) {
            if cancelFlag?.isCancelled == true { break }
            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0, nameLen < Int(MAXPATHLEN) else { continue }
            let namePtr = UnsafeRawPointer(entryPtr).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if namePtr[0] == 0x2E {
                if nameLen == 1 { continue }
                if nameLen == 2 && namePtr[1] == 0x2E { continue }
            }

            let dType = Int32(entryPtr.pointee.d_type)
            if dType == DT_LNK || dType == DT_FIFO || dType == DT_SOCK || dType == DT_CHR || dType == DT_BLK {
                continue
            }

            if dType == DT_DIR {
                if currentDepth < maxDepth {
                    total += descendSize(
                        namePtr: namePtr,
                        nameLen: nameLen,
                        pathBuf: &pathBuf,
                        pathLen: pathLen,
                        maxDepth: maxDepth,
                        currentDepth: currentDepth,
                        cancelFlag: cancelFlag
                    )
                }
                continue
            }

            var st = stat()
            guard fstatat(fd, namePtr, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFREG, st.st_size > 0 {
                total += Int64(st.st_size)
            } else if mode == S_IFDIR && currentDepth < maxDepth {
                total += descendSize(
                    namePtr: namePtr,
                    nameLen: nameLen,
                    pathBuf: &pathBuf,
                    pathLen: pathLen,
                    maxDepth: maxDepth,
                    currentDepth: currentDepth,
                    cancelFlag: cancelFlag
                )
            }
        }
        return total
    }

    nonisolated private static func descendSize(
        namePtr: UnsafePointer<CChar>,
        nameLen: Int,
        pathBuf: inout [CChar],
        pathLen: Int,
        maxDepth: Int,
        currentDepth: Int,
        cancelFlag: AdScanCancellationFlag?
    ) -> Int64 {
        let sepLen = (pathLen == 1 && pathBuf[0] == 0x2F) ? 0 : 1
        let subLen = pathLen + sepLen + nameLen
        let needed = subLen + 1
        if pathBuf.count < needed {
            pathBuf.append(contentsOf: repeatElement(0, count: needed - pathBuf.count))
        }
        if sepLen == 1 {
            pathBuf[pathLen] = 0x2F
        }
        pathBuf.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            memcpy(base.advanced(by: pathLen + sepLen), namePtr, nameLen)
            base[subLen] = 0
        }
        let bytes = fastSizeRecursive(
            pathBuf: &pathBuf,
            pathLen: subLen,
            maxDepth: maxDepth,
            currentDepth: currentDepth + 1,
            cancelFlag: cancelFlag
        )
        pathBuf[pathLen] = 0
        return bytes
    }
}

private struct AdFolderRowView: View {
    let item: AdCacheFolderItem
    let isBusy: Bool
    let onLocate: () -> Void
    let onToggleLock: () -> Void

    private static var isEn: Bool { LocalizationManager.isEnglish }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.relativePath)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                Text(AppContainerDirectoryHelper.formatBytes(item.cachedBytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(Self.isEn ? item.sdkNameEN : item.sdkNameZH)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.isLockedReadOnly
                     ? (Self.isEn
                        ? String(format: "%04o Read-Only", item.posixMode)
                        : String(format: "%04o 只读已锁", item.posixMode))
                     : (Self.isEn
                        ? String(format: "%04o Writable", item.posixMode)
                        : String(format: "%04o 可写", item.posixMode)))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (item.isLockedReadOnly ? Color.green : Color.orange).opacity(0.16),
                        in: Capsule()
                    )
                    .foregroundStyle(item.isLockedReadOnly ? Color.green : Color.orange)
                    .fixedSize()
            }

            HStack(spacing: 8) {
                Button(action: onLocate) {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                        Text(Self.isEn ? "Locate" : "定位目录")
                    }
                    .font(.caption.weight(.medium))
                    .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 8)

                if item.isLockedReadOnly {
                    Button(action: onToggleLock) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.open.fill")
                            Text(Self.isEn ? "Unlock 0755" : "恢复读写")
                        }
                        .font(.caption.weight(.semibold))
                        .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                    .fixedSize()
                    .disabled(isBusy)
                } else {
                    Button(action: onToggleLock) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                            Text(Self.isEn ? "Lock 0555" : "一键锁死")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .fixedSize()
                    .disabled(isBusy)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 3)
    }
}
