//
//  StatusBarView.swift
//  Erosion
//
//  Status bar & carrier overlay customization module with automatic backup and in-place atomic write.
//

import SwiftUI

private enum SBURL {
    static let carrierOverlayDir = URL(fileURLWithPath: "/var/mobile/Library/Carrier Bundles/Overlay")
    static let sbPrefs = URL(fileURLWithPath: "/var/mobile/Library/Preferences/com.apple.springboard.plist")
    static let backupDir = URL.documentsDirectory.appendingPathComponent("StatusBarBackup")
    static let sbPrefsBackup = URL.documentsDirectory.appendingPathComponent("StatusBarBackup/Original_com.apple.springboard.plist")
    static let overlayBackupDir = URL.documentsDirectory.appendingPathComponent("StatusBarBackup/CarrierOverlay")
}

struct StatusBarView: View {
    @EnvironmentObject private var mgr: ErosionManager
    @AppStorage("autoRespring") private var autoRespring = false
    @State private var isReady = false
    @State private var overlayFileCount = 0

    @State private var enableCustomCarrier = false
    @State private var customCarrierText = ""

    @State private var enableFakeTime = false
    @State private var customTimeText = ""

    @State private var showRSSI = false
    @State private var showBatteryPercent = false
    @State private var disableBreadcrumb = false

    var body: some View {
        List {
            if !isReady {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取状态栏与运营商配置...")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    PlainToggle(
                        "启用自定义运营商文字",
                        subtitle: overlayFileCount > 0
                            ? "已检测到 \(overlayFileCount) 个本机运营商覆盖配置文件"
                            : "未检测到 Carrier Overlay 文件，仅写入 SpringBoard 运营商覆盖项",
                        infoType: .info,
                        infoTitle: "自定义运营商文字说明",
                        infoMessage: "通过修改 /var/mobile/Library/Carrier Bundles/Overlay 下的 StatusBarCarrierName 键值及 SpringBoard 状态栏配置，自定义锁屏与控制中心左上角显示的运营商名称（支持中文、英文或 Emoji）。首次应用前会自动备份原厂文件，随时可一键还原。",
                        isOn: $enableCustomCarrier
                    )
                    if enableCustomCarrier {
                        TextField("输入自定义运营商文字（如：5G+ / 中国移动 / 🚀）", text: $customCarrierText)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                } header: {
                    HeaderLabel("运营商名称自定义", symbol: "antenna.radiowaves.left.and.right")
                } footer: {
                    Text("应用后需注销（Respring）或开关一次飞行模式刷新状态栏文字。")
                }

                Section {
                    PlainToggle(
                        "自定义状态栏时间处文字",
                        subtitle: "在状态栏左上角时间位置显示自定义短语",
                        infoType: .info,
                        infoTitle: "自定义状态栏时间说明",
                        infoMessage: "向 com.apple.springboard.plist 写入 SBFakeTime 与 SBFakeTimeString，可在状态栏时间区域显示短签名或自定义格式（注：开启后状态栏时间将固定显示为你设定的文字，关闭即可恢复实时时钟）。",
                        isOn: $enableFakeTime
                    )
                    if enableFakeTime {
                        TextField("输入时间处显示文字（建议 6 个字符以内）", text: $customTimeText)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                } header: {
                    HeaderLabel("状态栏时间区域", symbol: "clock")
                }

                Section {
                    PlainToggle(
                        "强制开启电池百分比显示",
                        subtitle: "对应 SBShowBatteryPercentage",
                        isOn: $showBatteryPercent
                    )
                    PlainToggle(
                        "显示数字信号强度 (RSSI)",
                        subtitle: "对应 SBShowRSSI（部分 iOS 版本支持）",
                        isOn: $showRSSI
                    )
                    PlainToggle(
                        "隐藏左上角“返回上个应用”面包屑",
                        subtitle: "屏蔽跳转应用后左上角的小字返回按钮",
                        isOn: $disableBreadcrumb
                    )
                } header: {
                    HeaderLabel("状态栏图标与细节", symbol: "menubar.rectangle")
                } footer: {
                    Text("所有修改均在首次写入前自动创建原厂备份，并采用保留 Inode 的原位原子写入。")
                }
            }
        }
        .navigationTitle("状态栏自定义")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Alertinator.shared.alert(
                        title: "确定恢复状态栏默认设置吗？",
                        body: "将从首次修改前保存的原厂备份完整还原运营商覆盖配置与 SpringBoard 状态栏设置。",
                        actionLabel: "确认还原",
                        action: {
                            restoreDefaults()
                        }
                    )
                } label: {
                    Label("恢复默认", systemImage: "gobackward")
                        .labelStyle(.iconOnly)
                }
                .disabled(!isReady)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("应用", role: .adaptiveConfirm) {
                    applyChanges()
                }
                .disabled(!isReady)
            }
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                loadCurrentState()
            }
        }
    }

    private func ensureBackupDir() {
        try? fm.createDirectory(at: SBURL.backupDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: SBURL.overlayBackupDir, withIntermediateDirectories: true)
        mgExcludeFromCloudBackup(SBURL.backupDir)
    }

    private func loadCurrentState() {
        ensureBackupDir()

        _ = wq.grantAccess(path: SBURL.sbPrefs.deletingLastPathComponent().path)
        _ = wq.grantAccess(path: SBURL.sbPrefs.path)
        _ = wq.grantAccess(path: SBURL.carrierOverlayDir.path)

        var detectedOverlays = 0
        var detectedCarrier = ""

        if let items = try? fm.contentsOfDirectory(at: SBURL.carrierOverlayDir, includingPropertiesForKeys: nil) {
            let plistURLs = items.filter { $0.pathExtension.lowercased() == "plist" }
            detectedOverlays = plistURLs.count
            for url in plistURLs {
                _ = wq.grantAccess(path: url.path)
                if detectedCarrier.isEmpty,
                   let data = try? Data(contentsOf: url),
                   let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let images = dict["StatusBarImages"] as? [[String: Any]],
                   let first = images.first,
                   let name = first["StatusBarCarrierName"] as? String,
                   !name.isEmpty {
                    detectedCarrier = name
                }
            }
        }

        var fakeTimeOn = false
        var fakeTimeStr = ""
        var rssiOn = false
        var batteryOn = false
        var noBreadcrumb = false

        if let data = try? Data(contentsOf: SBURL.sbPrefs),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            fakeTimeOn = (dict["SBFakeTime"] as? Bool) ?? false
            fakeTimeStr = (dict["SBFakeTimeString"] as? String) ?? ""
            rssiOn = (dict["SBShowRSSI"] as? Bool) ?? false
            batteryOn = (dict["SBShowBatteryPercentage"] as? Bool) ?? false
            if let bc = dict["SBShowBreadcrumb"] as? Bool {
                noBreadcrumb = !bc
            }
            if detectedCarrier.isEmpty, let sbCarrier = dict["SBFakeCarrier"] as? String, !sbCarrier.isEmpty {
                detectedCarrier = sbCarrier
            }
        }

        let savedCarrierEnabled = UserDefaults.standard.bool(forKey: "sb_custom_carrier_enabled")
        let savedCarrierText = UserDefaults.standard.string(forKey: "sb_custom_carrier_text") ?? detectedCarrier

        DispatchQueue.main.async {
            self.overlayFileCount = detectedOverlays
            self.enableCustomCarrier = savedCarrierEnabled
            self.customCarrierText = savedCarrierText
            self.enableFakeTime = fakeTimeOn
            self.customTimeText = fakeTimeStr
            self.showRSSI = rssiOn
            self.showBatteryPercent = batteryOn
            self.disableBreadcrumb = noBreadcrumb
            self.isReady = true
        }
    }

    private func applyChanges() {
        ensureBackupDir()

        // 1. Update com.apple.springboard.plist
        _ = wq.grantAccess(path: SBURL.sbPrefs.deletingLastPathComponent().path)
        _ = wq.grantAccess(path: SBURL.sbPrefs.path)

        if fm.fileExists(atPath: SBURL.sbPrefs.path) && !fm.fileExists(atPath: SBURL.sbPrefsBackup.path) {
            try? fm.copyItem(at: SBURL.sbPrefs, to: SBURL.sbPrefsBackup)
            mgExcludeFromCloudBackup(SBURL.sbPrefsBackup)
        }

        var sbFormat: PropertyListSerialization.PropertyListFormat = .binary
        let sbDict: NSMutableDictionary
        if let data = try? Data(contentsOf: SBURL.sbPrefs),
           let parsed = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &sbFormat) as? NSMutableDictionary {
            sbDict = parsed
        } else {
            sbDict = NSMutableDictionary()
        }

        let trimmedTime = customTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if enableFakeTime && !trimmedTime.isEmpty {
            sbDict["SBFakeTime"] = true
            sbDict["SBFakeTimeString"] = trimmedTime
        } else {
            sbDict.removeObject(forKey: "SBFakeTime")
            sbDict.removeObject(forKey: "SBFakeTimeString")
        }

        let trimmedCarrier = customCarrierText.trimmingCharacters(in: .whitespacesAndNewlines)
        if enableCustomCarrier && !trimmedCarrier.isEmpty {
            sbDict["SBFakeCarrier"] = trimmedCarrier
        } else {
            sbDict.removeObject(forKey: "SBFakeCarrier")
        }

        if showRSSI {
            sbDict["SBShowRSSI"] = true
        } else {
            sbDict.removeObject(forKey: "SBShowRSSI")
        }

        if showBatteryPercent {
            sbDict["SBShowBatteryPercentage"] = true
        } else {
            sbDict.removeObject(forKey: "SBShowBatteryPercentage")
        }

        if disableBreadcrumb {
            sbDict["SBShowBreadcrumb"] = false
        } else {
            sbDict.removeObject(forKey: "SBShowBreadcrumb")
        }

        do {
            let newData = try PropertyListSerialization.data(fromPropertyList: sbDict, format: sbFormat, options: 0)
            let writeRes: (Bool, String)
            if fm.fileExists(atPath: SBURL.sbPrefs.path) {
                writeRes = writeFileAtomically(newData, to: SBURL.sbPrefs)
            } else {
                writeRes = writeFileTemp(newData, to: SBURL.sbPrefs)
            }
            if !writeRes.0 {
                Alertinator.shared.alert(title: "写入 SpringBoard 状态栏配置失败！", body: writeRes.1)
                return
            }
        } catch {
            Alertinator.shared.alert(title: "序列化状态栏配置失败！", body: error.localizedDescription)
            return
        }

        // 2. Update Carrier Overlay plists if enabled
        if enableCustomCarrier && !trimmedCarrier.isEmpty {
            _ = updateCarrierOverlayFiles(carrierName: trimmedCarrier)
            UserDefaults.standard.set(true, forKey: "sb_custom_carrier_enabled")
            UserDefaults.standard.set(trimmedCarrier, forKey: "sb_custom_carrier_text")
        } else {
            restoreCarrierOverlayFilesOnly()
            UserDefaults.standard.set(false, forKey: "sb_custom_carrier_enabled")
        }

        Haptic.shared.play(.soft)
        if autoRespring {
            mgr.shouldRespring = true
        } else {
            Alertinator.shared.alert(
                title: "状态栏配置已成功写入！",
                body: "注销设备（Respring）后即可生效。是否立即注销？",
                actionLabel: "立即注销",
                action: {
                    mgr.shouldRespring = true
                }
            )
        }
    }

    private func updateCarrierOverlayFiles(carrierName: String) -> Int {
        _ = wq.grantAccess(path: SBURL.carrierOverlayDir.path)
        guard let items = try? fm.contentsOfDirectory(at: SBURL.carrierOverlayDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        var updatedCount = 0
        for url in items where url.pathExtension.lowercased() == "plist" {
            _ = wq.grantAccess(path: url.path)
            let backupURL = SBURL.overlayBackupDir.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: backupURL.path) {
                try? fm.copyItem(at: url, to: backupURL)
                mgExcludeFromCloudBackup(backupURL)
            }

            var format: PropertyListSerialization.PropertyListFormat = .binary
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? NSMutableDictionary else {
                continue
            }

            var modified = false
            if let images = dict["StatusBarImages"] as? NSMutableArray {
                for i in 0..<images.count {
                    if let entry = images[i] as? NSMutableDictionary {
                        entry["StatusBarCarrierName"] = carrierName
                        entry["CarrierName"] = carrierName
                        modified = true
                    }
                }
            }
            if dict["StatusBarCarrierName"] != nil {
                dict["StatusBarCarrierName"] = carrierName
                modified = true
            }

            if modified,
               let outData = try? PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0) {
                let res = writeFileAtomically(outData, to: url)
                if res.0 {
                    updatedCount += 1
                }
            }
        }
        return updatedCount
    }

    private func restoreCarrierOverlayFilesOnly() {
        guard let backups = try? fm.contentsOfDirectory(at: SBURL.overlayBackupDir, includingPropertiesForKeys: nil) else {
            return
        }
        _ = wq.grantAccess(path: SBURL.carrierOverlayDir.path)
        for backupURL in backups where backupURL.pathExtension.lowercased() == "plist" {
            let destURL = SBURL.carrierOverlayDir.appendingPathComponent(backupURL.lastPathComponent)
            _ = wq.grantAccess(path: destURL.path)
            if fm.fileExists(atPath: destURL.path),
               let ogData = try? Data(contentsOf: backupURL) {
                _ = writeFileAtomically(ogData, to: destURL)
            }
        }
    }

    private func restoreDefaults() {
        restoreCarrierOverlayFilesOnly()
        UserDefaults.standard.set(false, forKey: "sb_custom_carrier_enabled")

        if fm.fileExists(atPath: SBURL.sbPrefsBackup.path),
           let ogData = try? Data(contentsOf: SBURL.sbPrefsBackup) {
            _ = wq.grantAccess(path: SBURL.sbPrefs.path)
            _ = writeFileAtomically(ogData, to: SBURL.sbPrefs)
        } else if fm.fileExists(atPath: SBURL.sbPrefs.path) {
            _ = wq.grantAccess(path: SBURL.sbPrefs.path)
            var format: PropertyListSerialization.PropertyListFormat = .binary
            if let data = try? Data(contentsOf: SBURL.sbPrefs),
               let dict = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? NSMutableDictionary {
                for key in ["SBFakeTime", "SBFakeTimeString", "SBFakeCarrier", "SBShowRSSI", "SBShowBatteryPercentage", "SBShowBreadcrumb"] {
                    dict.removeObject(forKey: key)
                }
                if let outData = try? PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0) {
                    _ = writeFileAtomically(outData, to: SBURL.sbPrefs)
                }
            }
        }

        enableCustomCarrier = false
        enableFakeTime = false
        customTimeText = ""
        showRSSI = false
        showBatteryPercent = false
        disableBreadcrumb = false

        Haptic.shared.play(.soft)
        Alertinator.shared.alert(
            title: "已恢复状态栏默认配置！",
            body: "是否立即注销（Respring）使恢复生效？",
            actionLabel: "立即注销",
            action: {
                mgr.shouldRespring = true
            }
        )
    }
}
