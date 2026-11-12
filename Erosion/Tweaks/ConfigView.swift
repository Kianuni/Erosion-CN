//
//  ConfigView.swift
//  Erosion
//
//  Created by lunginspector on 8/21/26.
//

import SwiftUI


enum CNURL {
    static var sharedDevConfig = FSURL.configProfiles.appendingPathComponent("SharedDeviceConfiguration.plist")
    static var cloudConfig = FSURL.configProfiles.appendingPathComponent("CloudConfigurationDetails.plist")
    static var cloudConfigBackup = URL.documentsDirectory.appendingPathComponent("OriginalCloudConfigurationDetails.plist")
}

enum CNMsg {
    static var supWarning: String { L("在个人零售版 iOS 设备上强行写入 IsSupervised=true 极易触发 Setup.app 远程管理向导无限循环锁死（Setup Assistant Loop / 403 死锁）甚至无法进入桌面！防白苹果护栏已永久禁用开启监管模式；如曾通过旧版或其他工具误开启过，可在下方“伪监管残留死锁体检”中一键单独清理。") }
    static var resetInfo: String { L("点击“确认”后，将安全清除锁屏底部文字与设备资产铭牌，并恢复或清理残留的监管配置文件。") }
    static var assetTagInfo: String { L("[测试特性] AssetTagInformation 是系统配置描述文件中的原生资产铭牌字段，可在锁屏界面底部或关于本机中展示防丢联系方式或设备编号，不修改任何系统二进制或监管标记。") }
}

private enum CloudConfigAuditState {
    case clean
    case genuineMDM(org: String)
    case fakeSupervisionResidue(org: String)
}

struct ConfigView: View {
    @EnvironmentObject private var mgr: ErosionManager
    @AppStorage("autoRespring") var autoRespring = false
    @State private var ftCurrentDict = NSMutableDictionary()
    @State private var ccCurrentDict = NSMutableDictionary()
    @State private var footnoteText = ""
    @State private var assetTagText = ""
    @State private var supervised = false
    @State private var orgName = ""
    @State private var hasAccess = false
    @State private var auditState: CloudConfigAuditState = .clean
    
    var body: some View {
        List {
                Section {
                    VStack(spacing: 14) {
                        HStack {
                            Image(systemName: "flashlight.off.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                                .padding()
                                .modifier(QuickActionBackground())
                            Spacer()
                            Image(systemName: "camera.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                                .padding()
                                .modifier(QuickActionBackground())
                        }
                        .padding(.horizontal, 35)
                        
                        VStack(spacing: 2) {
                            if !assetTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(assetTagText)
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(footnoteText)
                                .font(.system(size: 9))
                                .frame(height: 10)
                            Capsule()
                                .frame(width: 145, height: 4)
                        }
                    }
                    .padding(.top, 25)
                    .padding(.bottom, 10)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(
                        Group {
                            Image("solarium")
                                .resizable()
                                .scaledToFill()
                                .offset(y: 10)
                        }
                    )
                    
                    TextField("自定义锁屏底部文字 (LockScreenFootnote)", text: $footnoteText)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("[测试特性] 锁屏设备资产铭牌")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button {
                                Alertinator.shared.alert(title: L("锁屏设备资产铭牌 [测试特性]"), body: CNMsg.assetTagInfo)
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("输入防丢电话/邮箱或资产编号 (AssetTagInformation)", text: $assetTagText)
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Button("填入防丢模板") {
                                assetTagText = L("拾获请致电机主 · 感谢归还")
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)

                            Button("填入设备标识") {
                                assetTagText = "\(UIDevice.current.name) · iOS \(UIDevice.current.systemVersion)"
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)

                            if !assetTagText.isEmpty {
                                Button("清空", role: .destructive) {
                                    assetTagText = ""
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    HeaderLabel(L("防丢铭牌扩展（测试特性）"), symbol: "tag")
                } footer: {
                    Text("写入 SharedDeviceConfiguration.plist 的 AssetTagInformation 字段，留空并点击右上角“应用”即可移除。")
                }
                
                Section {
                    PlainToggle(L("开启监管模式（防设置向导死循环护栏已锁定）"), infoType: .warning, infoTitle: L("监管模式保护说明"), infoMessage: CNMsg.supWarning, isOn: $supervised)
                        .disabled(true)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: auditIconName)
                                .foregroundStyle(auditAccentColor)
                            Text("[测试特性] 伪监管残留死锁体检")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(auditBadgeText)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(auditAccentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(auditAccentColor)
                        }
                        Text(auditDetailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if case .fakeSupervisionResidue = auditState {
                            Button(role: .destructive) {
                                cleanFakeSupervisionOnly()
                            } label: {
                                Label("一键安全清除伪监管残留 (保留锁屏文字)", systemImage: "shield.lefthalf.filled.badge.checkmark")
                                    .font(.footnote.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 3)
                } header: {
                    HeaderLabel(L("监管设置与安全体检（测试特性）"), symbol: "eye")
                }
            }
            .navigationTitle("系统配置与监管")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Alertinator.shared.alert(title: L("确定要重置配置修改吗？"), body: CNMsg.resetInfo, actionLabel: L("确认"), action: {
                            reset()
                        })
                    } label: {
                        Label("恢复默认", systemImage: "gobackward")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!hasAccess)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用", role: .adaptiveConfirm) {
                        apply()
                    }
                    .disabled(!hasAccess)
                }
            }
            .onAppear {
                doSetup()
            }
    }
    
    private static func isGenuineMDMCloudConfig(_ dict: NSDictionary) -> Bool {
        let mdmKeys = [
            "ConfigurationSource",
            "PostSetupProfileWasInstalled",
            "AwaitDeviceConfigured",
            "CloudConfigurationUIComplete",
            "ConfigurationURL",
            "AnchorCertificates",
            "SupervisorHostCertificates"
        ]
        for key in mdmKeys where dict[key] != nil {
            return true
        }
        let allKeys = Set(dict.allKeys.compactMap { $0 as? String })
        let fakeOnlyKeys: Set<String> = ["IsSupervised", "OrganizationName"]
        return !allKeys.subtracting(fakeOnlyKeys).isEmpty
    }
    
    private func doSetup() {
        if fm.isWritableFile(atPath: FSURL.configProfiles.path) {
            hasAccess = true
        } else {
            let res = wq.grantAccess(path: FSURL.configProfiles.path)
            hasAccess = res.0
            if !res.0 {
                Alertinator.shared.alert(title: L("获取写入权限失败！"), body: AppMsg.opFailed)
                return
            }
        }
        if UserDefaults.standard.object(forKey: "cn_cloud_config_originally_existed") == nil {
            var genuineExisted = false
            if fm.fileExists(atPath: CNURL.cloudConfig.path),
               let existingDict = NSDictionary(contentsOf: CNURL.cloudConfig),
               Self.isGenuineMDMCloudConfig(existingDict) {
                genuineExisted = true
            }
            UserDefaults.standard.set(genuineExisted, forKey: "cn_cloud_config_originally_existed")
            if genuineExisted && !fm.fileExists(atPath: CNURL.cloudConfigBackup.path) {
                try? fm.copyItem(at: CNURL.cloudConfig, to: CNURL.cloudConfigBackup)
                mgExcludeFromCloudBackup(CNURL.cloudConfigBackup)
            }
        }
        loadData()
    }
    
    private var auditIconName: String {
        switch auditState {
        case .clean: return "checkmark.shield.fill"
        case .genuineMDM: return "building.2.crop.circle.fill"
        case .fakeSupervisionResidue: return "exclamationmark.triangle.fill"
        }
    }

    private var auditAccentColor: Color {
        switch auditState {
        case .clean: return .green
        case .genuineMDM: return .blue
        case .fakeSupervisionResidue: return .red
        }
    }

    private var auditBadgeText: String {
        switch auditState {
        case .clean: return L("安全无残留")
        case .genuineMDM: return L("合法企业 MDM")
        case .fakeSupervisionResidue: return L("高危伪监管残留")
        }
    }

    private var auditDetailText: String {
        switch auditState {
        case .clean:
            return L("未检测到伪造的 CloudConfigurationDetails.plist 文件，系统升级或重启后不会触发 Setup Assistant 403 远程管理向导死循环。")
        case .genuineMDM(let org):
            let displayOrg = org.isEmpty ? L("企业/教育机构") : org
            return L("检测到包含完整证书锚点的合法 MDM 配置（\(displayOrg)），防白苹果护栏已自动保护该原始文件不被误删。")
        case .fakeSupervisionResidue(let org):
            let suffix = org.isEmpty ? "" : L("（残留组织名：\(org)）")
            return L("检测到仅含 IsSupervised/OrganizationName 而缺失 MDM 证书链的第三方伪监管文件\(suffix)！在 OTA 升级后极易触发激活向导 403 死锁，建议立即点击下方按钮清除。")
        }
    }

    private func loadData() {
        if fm.fileExists(atPath: CNURL.sharedDevConfig.path),
           let ftDict = NSMutableDictionary(contentsOf: CNURL.sharedDevConfig) {
            ftCurrentDict = ftDict
            footnoteText = ftDict["LockScreenFootnote"] as? String ?? ""
            assetTagText = ftDict["AssetTagInformation"] as? String ?? ""
        } else {
            ftCurrentDict = NSMutableDictionary()
            footnoteText = ""
            assetTagText = ""
        }
        if fm.fileExists(atPath: CNURL.cloudConfig.path),
           let ccDict = NSMutableDictionary(contentsOf: CNURL.cloudConfig) {
            ccCurrentDict = ccDict
            supervised = ccDict["IsSupervised"] as? Bool ?? false
            orgName = ccDict["OrganizationName"] as? String ?? ""
            if Self.isGenuineMDMCloudConfig(ccDict) {
                auditState = .genuineMDM(org: orgName)
            } else {
                auditState = .fakeSupervisionResidue(org: orgName)
            }
        } else {
            ccCurrentDict = NSMutableDictionary()
            supervised = false
            orgName = ""
            auditState = .clean
        }
    }

    private func cleanFakeSupervisionOnly() {
        do {
            guard fm.fileExists(atPath: CNURL.cloudConfig.path),
                  let currentDict = NSDictionary(contentsOf: CNURL.cloudConfig),
                  !Self.isGenuineMDMCloudConfig(currentDict) else {
                loadData()
                return
            }
            try fm.removeItem(at: CNURL.cloudConfig)
            try? fm.removeItem(at: CNURL.cloudConfigBackup)
            UserDefaults.standard.set(false, forKey: "cn_cloud_config_originally_existed")
            Haptic.shared.play(.soft)
            loadData()
            Alertinator.shared.alert(
                title: L("已清除伪监管残留！"),
                body: L("已安全移除伪造的 CloudConfigurationDetails.plist 并保留你的锁屏底部文字与资产铭牌配置。\n\(AppMsg.applied)"),
                actionLabel: L("立即注销"),
                action: { mgr.shouldRespring = true }
            )
        } catch {
            Alertinator.shared.alert(title: L("清理伪监管残留失败！"), body: error.localizedDescription)
        }
    }
    
    private func apply() {
        let ftDict = NSMutableDictionary(dictionary: ftCurrentDict)
        let trimmedFootnote = footnoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssetTag = assetTagText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedFootnote.isEmpty {
            ftDict.removeObject(forKey: "LockScreenFootnote")
        } else {
            ftDict["LockScreenFootnote"] = footnoteText
        }

        if trimmedAssetTag.isEmpty {
            ftDict.removeObject(forKey: "AssetTagInformation")
        } else {
            ftDict["AssetTagInformation"] = trimmedAssetTag
        }

        do {
            try fm.createDirectory(at: FSURL.configProfiles, withIntermediateDirectories: true)
            if ftDict.count == 0 {
                if fm.fileExists(atPath: CNURL.sharedDevConfig.path) {
                    try fm.removeItem(at: CNURL.sharedDevConfig)
                }
            } else {
                let ftData = try PropertyListSerialization.data(fromPropertyList: ftDict, format: .binary, options: 0)
                if fm.fileExists(atPath: CNURL.sharedDevConfig.path) {
                    let res = writeFileAtomically(ftData, to: CNURL.sharedDevConfig)
                    if !res.0 {
                        throw res.1
                    }
                } else {
                    try ftData.write(to: CNURL.sharedDevConfig, options: .atomic)
                }
            }
            ftCurrentDict = ftDict
            print("(cn) successfully applied footnote & asset tag tweak safely!")
            Haptic.shared.play(.soft)
            if autoRespring {
                mgr.shouldRespring = true
            } else {
                Alertinator.shared.alert(title: L("系统配置修改已成功应用！"), body: AppMsg.applied, actionLabel: L("立即注销"), action: { mgr.shouldRespring = true })
            }
        } catch {
            print("(cn) failed to write config files: \(error.localizedDescription)")
            Alertinator.shared.alert(title: L("应用修改失败！"), body: "\(error.localizedDescription)")
        }
    }
    
    static func resetSystemConfigSafely() throws {
        if !fm.isWritableFile(atPath: FSURL.configProfiles.path) {
            _ = wq.grantAccess(path: FSURL.configProfiles.path)
        }
        if fm.fileExists(atPath: CNURL.sharedDevConfig.path) {
            try fm.removeItem(at: CNURL.sharedDevConfig)
        }
        let originallyExisted = UserDefaults.standard.bool(forKey: "cn_cloud_config_originally_existed")
        if originallyExisted,
           fm.fileExists(atPath: CNURL.cloudConfigBackup.path),
           let backupDict = NSDictionary(contentsOf: CNURL.cloudConfigBackup),
           Self.isGenuineMDMCloudConfig(backupDict) {
            let backupData = try Data(contentsOf: CNURL.cloudConfigBackup)
            if fm.fileExists(atPath: CNURL.cloudConfig.path) {
                let res = writeFileAtomically(backupData, to: CNURL.cloudConfig)
                if !res.0 { throw res.1 }
            } else {
                try backupData.write(to: CNURL.cloudConfig, options: .atomic)
            }
        } else if fm.fileExists(atPath: CNURL.cloudConfig.path) {
            if let currentDict = NSDictionary(contentsOf: CNURL.cloudConfig),
               !Self.isGenuineMDMCloudConfig(currentDict) {
                // Remove fake supervision plist left by older Erosion versions (SEC-M4-01)
                try fm.removeItem(at: CNURL.cloudConfig)
                try? fm.removeItem(at: CNURL.cloudConfigBackup)
                UserDefaults.standard.set(false, forKey: "cn_cloud_config_originally_existed")
            } else if !originallyExisted {
                try fm.removeItem(at: CNURL.cloudConfig)
            }
        }
    }

    private func reset() {
        do {
            try Self.resetSystemConfigSafely()
            print("(cn) successfully reset config tweaks!")
            Haptic.shared.play(.soft)
            loadData()
            footnoteText = ""
            assetTagText = ""
            Alertinator.shared.alert(title: L("系统配置修改已成功重置！"), body: AppMsg.applied, actionLabel: L("立即注销"), action: { mgr.shouldRespring = true })
        } catch {
            print("(cn) failed to reset config files: \(error.localizedDescription)")
            Alertinator.shared.alert(title: L("重置修改失败！"), body: "\(error.localizedDescription)")
        }
    }
}

// MARK: ui
struct QuickActionBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 19.0, *) {
            content
                .glassEffect(.clear.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: .circle)
        }
    }
}
