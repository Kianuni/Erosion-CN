//
//  AdCacheBlockerView.swift
//  Erosion
//
//  Accurate per-app & AppGroup splash/ad-SDK cache detector, custom watch list,
//  one-tap locator/preview, and anti-recreate read-only POSIX chmod (0555 + 0444 sentinel / 0444 file).
//

import SwiftUI
import Darwin
import UIKit

nonisolated struct CustomAdWatchRule: Codable, Identifiable, Hashable, Sendable {
    var id: String { fullPath }
    let fullPath: String
    let note: String
    let addedAt: Date
}

/// Thread-safe persistent store for user-selected custom ad folders and ad config files.
nonisolated final class AdCustomWatchStore: @unchecked Sendable {
    static let shared = AdCustomWatchStore()
    static let didChangeNotification = Notification.Name("erosion.adCustomWatchDidChange")

    private static let defaultsKey = "erosion.adBlocker.customPaths.v1"
    private let lock = NSLock()
    private var cachedRules: [CustomAdWatchRule]

    private static let forbiddenCustomNames: Set<String> = [
        "documents", "library", "caches", "tmp", "preferences", "application support",
        "splashboard", "webkit", "fscacheddata", "com.apple.nsurlsessiond",
        "cookies", "httpstorages", "saved application state", "cloudkit",
        "snapshots", "flutter_assets", "downloads", "download",
        "uploads", "upload", "databases", "database", "system", "bundle"
    ]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([CustomAdWatchRule].self, from: data) {
            self.cachedRules = decoded
        } else {
            self.cachedRules = []
        }
    }

    static func canonicalVarPath(_ rawPath: String) -> String {
        var p = (rawPath as NSString).standardizingPath
        if p.hasPrefix("/private/var/") {
            p = String(p.dropFirst("/private".count))
        } else if p == "/private/var" {
            p = "/var"
        }
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    static func containerRootPath(forCanonicalPath path: String) -> String? {
        for base in [
            "/var/mobile/Containers/Data/Application/",
            "/var/mobile/Containers/Shared/AppGroup/"
        ] where path.hasPrefix(base) {
            let rel = String(path.dropFirst(base.count))
            let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            return base + String(parts[0])
        }
        return nil
    }

    func canAddAsCustomTarget(url: URL, owner: String) -> Bool {
        guard canSafelyModifyPermissions(url: url, owner: owner) else {
            return false
        }
        let canon = Self.canonicalVarPath(url.standardizedFileURL.path)
        var st = stat()
        guard lstat(canon, &st) == 0 else { return false }
        let fmt = st.st_mode & S_IFMT
        guard fmt == S_IFDIR || fmt == S_IFREG else { return false }

        let nameLower = URL(fileURLWithPath: canon).lastPathComponent.lowercased()
        if Self.forbiddenCustomNames.contains(nameLower) || nameLower.hasPrefix(".com.apple.") {
            return false
        }

        // Protect main App NSUserDefaults / system preferences inside Library/Preferences
        let parentLower = URL(fileURLWithPath: canon).deletingLastPathComponent().lastPathComponent.lowercased()
        if fmt == S_IFREG && parentLower == "preferences" {
            let looksAdRelated = nameLower.contains("ad") || nameLower.contains("splash") || nameLower.contains("launch")
            if !looksAdRelated {
                return false
            }
        }
        return true
    }

    func rulesSnapshot() -> [CustomAdWatchRule] {
        lock.lock()
        let copy = cachedRules
        lock.unlock()
        return copy
    }

    func contains(url: URL) -> Bool {
        let canon = Self.canonicalVarPath(url.standardizedFileURL.path)
        lock.lock()
        let hit = cachedRules.contains { $0.fullPath == canon }
        lock.unlock()
        return hit
    }

    @discardableResult
    func addValidatedRule(canonicalPath: String, note: String = "") -> CustomAdWatchRule {
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = CustomAdWatchRule(fullPath: canonicalPath, note: cleanNote, addedAt: Date())

        lock.lock()
        if let idx = cachedRules.firstIndex(where: { $0.fullPath == canonicalPath }) {
            cachedRules[idx] = rule
        } else {
            cachedRules.insert(rule, at: 0)
        }
        persistLocked()
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return rule
    }

    func remove(fullPath: String) {
        let canon = Self.canonicalVarPath(fullPath)
        lock.lock()
        let oldCount = cachedRules.count
        cachedRules.removeAll { $0.fullPath == canon }
        let changed = cachedRules.count != oldCount
        if changed {
            persistLocked()
        }
        lock.unlock()

        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(cachedRules) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

nonisolated enum AdWhitelistKind: String, Codable, Hashable, Sendable {
    case bundleID
    case exactPath
}

nonisolated struct AdWhitelistRule: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(target.lowercased())" }
    let kind: AdWhitelistKind
    let target: String
    let note: String
    let addedAt: Date
}

/// Thread-safe persistent store for App/AppGroup and exact-path whitelists skipped by batch ad locking.
nonisolated final class AdWhitelistStore: @unchecked Sendable {
    static let shared = AdWhitelistStore()
    static let didChangeNotification = Notification.Name("erosion.adWhitelistDidChange")

    private static let defaultsKey = "erosion.adBlocker.whitelistRules.v1"
    private static let seededKey = "erosion.adBlocker.whitelistSeeded.v1"
    private let lock = NSLock()
    private var cachedRules: [AdWhitelistRule]

    private init() {
        var loaded: [AdWhitelistRule] = []
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([AdWhitelistRule].self, from: data) {
            loaded = decoded
        }
        if !UserDefaults.standard.bool(forKey: Self.seededKey) {
            UserDefaults.standard.set(true, forKey: Self.seededKey)
            if !loaded.contains(where: { $0.kind == .bundleID && $0.target.caseInsensitiveCompare("com.smzdm.client.ios") == .orderedSame }) {
                loaded.append(
                    AdWhitelistRule(
                        kind: .bundleID,
                        target: "com.smzdm.client.ios",
                        note: "已知锁死开屏目录会触发启动闪退 / Known splash lock crash",
                        addedAt: Date()
                    )
                )
                if let data = try? JSONEncoder().encode(loaded) {
                    UserDefaults.standard.set(data, forKey: Self.defaultsKey)
                }
            }
        }
        self.cachedRules = loaded
    }

    func rulesSnapshot() -> [AdWhitelistRule] {
        lock.lock()
        let copy = cachedRules
        lock.unlock()
        return copy
    }

    func isContainerWhitelisted(id: String, isAppGroup: Bool) -> Bool {
        let idLower = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !idLower.isEmpty else { return false }
        lock.lock()
        let hit = cachedRules.contains { rule in
            guard rule.kind == .bundleID else { return false }
            let ruleLower = rule.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !ruleLower.isEmpty else { return false }
            if ruleLower == idLower {
                return true
            }
            if isAppGroup && (idLower == "group." + ruleLower || idLower.hasPrefix("group." + ruleLower + ".")) {
                return true
            }
            return false
        }
        lock.unlock()
        return hit
    }

    func containsExactBundleRule(_ rawID: String) -> Bool {
        let idLower = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !idLower.isEmpty else { return false }
        lock.lock()
        let hit = cachedRules.contains { $0.kind == .bundleID && $0.target.lowercased() == idLower }
        lock.unlock()
        return hit
    }

    func isPathWhitelisted(_ rawPath: String) -> Bool {
        let canon = AdCustomWatchStore.canonicalVarPath(rawPath)
        guard !canon.isEmpty else { return false }
        lock.lock()
        let hit = cachedRules.contains { rule in
            guard rule.kind == .exactPath else { return false }
            let ruleCanon = AdCustomWatchStore.canonicalVarPath(rule.target)
            return canon == ruleCanon || canon.hasPrefix(ruleCanon + "/")
        }
        lock.unlock()
        return hit
    }

    func containsExactPath(_ url: URL) -> Bool {
        isPathWhitelisted(url.standardizedFileURL.path)
    }

    func canWhitelistPath(url: URL, owner: String) -> Bool {
        guard canSafelyModifyPermissions(url: url, owner: owner) else {
            return false
        }
        let canon = AdCustomWatchStore.canonicalVarPath(url.standardizedFileURL.path)
        var st = stat()
        guard lstat(canon, &st) == 0 else { return false }
        let fmt = st.st_mode & S_IFMT
        return fmt == S_IFDIR || fmt == S_IFREG
    }

    @discardableResult
    func addBundleRule(bundleOrGroupID: String, note: String = "") -> AdWhitelistRule? {
        let cleanID = bundleOrGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty,
              !cleanID.contains("/"),
              cleanID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = AdWhitelistRule(kind: .bundleID, target: cleanID, note: cleanNote, addedAt: Date())

        lock.lock()
        if let idx = cachedRules.firstIndex(where: { $0.id == rule.id }) {
            cachedRules[idx] = rule
        } else {
            cachedRules.insert(rule, at: 0)
        }
        persistLocked()
        lock.unlock()

        notifyChanged()
        return rule
    }

    @discardableResult
    func addPathRule(rawPath: String, note: String = "") -> AdWhitelistRule? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canon = AdCustomWatchStore.canonicalVarPath(trimmed)
        guard AdCustomWatchStore.containerRootPath(forCanonicalPath: canon) != nil else {
            return nil
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = AdWhitelistRule(kind: .exactPath, target: canon, note: cleanNote, addedAt: Date())

        lock.lock()
        if let idx = cachedRules.firstIndex(where: { $0.id == rule.id }) {
            cachedRules[idx] = rule
        } else {
            cachedRules.insert(rule, at: 0)
        }
        persistLocked()
        lock.unlock()

        notifyChanged()
        return rule
    }

    func remove(ruleID: String) {
        lock.lock()
        let oldCount = cachedRules.count
        cachedRules.removeAll { $0.id == ruleID }
        let changed = cachedRules.count != oldCount
        if changed {
            persistLocked()
        }
        lock.unlock()

        if changed {
            notifyChanged()
        }
    }

    func removeMatchingContainer(id: String, isAppGroup: Bool) {
        let idLower = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !idLower.isEmpty else { return }
        lock.lock()
        let oldCount = cachedRules.count
        cachedRules.removeAll { rule in
            guard rule.kind == .bundleID else { return false }
            let ruleLower = rule.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ruleLower == idLower {
                return true
            }
            if isAppGroup && (idLower == "group." + ruleLower || idLower.hasPrefix("group." + ruleLower + ".")) {
                return true
            }
            return false
        }
        let changed = cachedRules.count != oldCount
        if changed {
            persistLocked()
        }
        lock.unlock()

        if changed {
            notifyChanged()
        }
    }

    func removeExactPath(_ rawPath: String) {
        let canon = AdCustomWatchStore.canonicalVarPath(rawPath)
        lock.lock()
        let oldCount = cachedRules.count
        cachedRules.removeAll { rule in
            guard rule.kind == .exactPath else { return false }
            let ruleCanon = AdCustomWatchStore.canonicalVarPath(rule.target)
            return canon == ruleCanon || canon.hasPrefix(ruleCanon + "/")
        }
        let changed = cachedRules.count != oldCount
        if changed {
            persistLocked()
        }
        lock.unlock()

        if changed {
            notifyChanged()
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(cachedRules) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}

nonisolated struct AdCacheFolderItem: Identifiable, Hashable, Sendable {
    let id: String
    let fullPath: String
    let relativePath: String
    let sdkNameZH: String
    let sdkNameEN: String
    let isDirectory: Bool
    var isCustomRule: Bool
    var isContainerWhitelisted: Bool
    var isPathWhitelisted: Bool
    var cachedBytes: Int64
    var posixMode: Int
    var hasSentinelLock: Bool

    var url: URL { URL(fileURLWithPath: fullPath) }
    var parentURL: URL { url.deletingLastPathComponent() }
    var folderName: String { url.lastPathComponent }
    var isWhitelisted: Bool { isContainerWhitelisted || isPathWhitelisted }
    var isLockedReadOnly: Bool { (posixMode & 0o222) == 0 }
    var needsActionToLock: Bool { !isWhitelisted && (!isLockedReadOnly || (isDirectory && !hasSentinelLock)) }
}

nonisolated struct AppAdCacheEntry: Identifiable, Sendable {
    let id: String
    let bundleID: String
    let displayTitle: String
    let containerURL: URL
    let isAppGroup: Bool
    var isAppWhitelisted: Bool
    var items: [AdCacheFolderItem]
}

private nonisolated final class AdScanCancellationFlag: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let val = cancelled
        lock.unlock()
        return val
    }
}

private struct LocateAdTarget: Identifiable, Hashable {
    let id = UUID()
    let containerURL: URL
    let folderURL: URL?
}

private struct AdFilePreviewTarget: Identifiable {
    let id = UUID()
    let fileURL: URL
    let isPlist: Bool
}

struct AdFolderLocateBrowserView: View {
    let containerURL: URL
    let targetFolderURL: URL

    @State private var parentReadyURL: URL?
    @State private var errorMsg: String?

    var body: some View {
        Group {
            if let parentReadyURL {
                FileBrowserView(path: parentReadyURL, shouldGrant: true, highlightTargetURL: targetFolderURL)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "scope")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizationManager.isEnglish
                                     ? "Target Ad Item: \(targetFolderURL.lastPathComponent)"
                                     : "已定位目标广告位置：\(targetFolderURL.lastPathComponent)")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(LocalizationManager.isEnglish
                                     ? "Find \"\(targetFolderURL.lastPathComponent)\" below, tap (i) for chmod info or long-press for actions."
                                     : "在下方列表找到「\(targetFolderURL.lastPathComponent)」，点右侧 ⓘ 可看权限详情，或长按加入收藏。")
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
                        title: LocalizationManager.isEnglish ? "Unable to Locate Path" : "无法定位广告位置",
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
                    Text(LocalizationManager.isEnglish ? "Authorizing & locating path..." : "正在授权并定位位置...")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            guard parentReadyURL == nil && errorMsg == nil else { return }
            let parentURL = targetFolderURL.deletingLastPathComponent()
            let rootGrant = wq.grantAccess(path: containerURL.path, requireWrite: false)
            guard rootGrant.0 || rootGrant.1 >= 0 else {
                errorMsg = LocalizationManager.isEnglish
                    ? "Container access denied: \(rootGrant.2)"
                    : "无法获取应用容器权限：\(rootGrant.2)"
                return
            }
            let parentGrant = wq.grantAccess(path: parentURL.path, requireWrite: false)
            guard parentGrant.0 || parentGrant.1 >= 0 else {
                errorMsg = LocalizationManager.isEnglish
                    ? "Parent directory access denied: \(parentGrant.2)"
                    : "无法访问上级目录：\(parentGrant.2)"
                return
            }
            _ = wq.grantAccess(path: targetFolderURL.path, requireWrite: false)
            parentReadyURL = parentURL
        }
    }
}

private struct AddCustomAdPathSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void

    @State private var rawPath = ""
    @State private var note = ""
    @State private var errorMsg: String?

    private static var isEn: Bool { LocalizationManager.isEnglish }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.isEn ? "Target Folder or File Path" : "目标文件夹或配置文件路径")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("/var/mobile/Containers/.../SplashAd", text: $rawPath, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .lineLimit(2...5)
                    }
                    .padding(.vertical, 2)

                    TextField(
                        Self.isEn ? "Optional label (e.g. Custom Splash Folder)" : "可选备注（例如：某某开屏广告缓存）",
                        text: $note
                    )
                    .font(.subheadline)

                    if let errorMsg {
                        Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    HeaderLabel(Self.isEn ? "Custom Ad Watch Rule" : "添加自定义广告目录 / 文件", symbol: "plus.circle")
                } footer: {
                    Text(Self.isEn
                         ? "Tip: You can also long-press any folder or file inside File Browser and choose 'Add to Ad Blocker'. System containers, container roots, Downloads, symlinks, and main app preference plists are blocked for safety."
                         : "提示：除了手动粘贴 `/var/mobile/...` 路径，你也可以直接在「文件浏览」中长按任意应用内文件夹或配置文件 →「加入广告锁死列表」。系统容器、容器根目录、Downloads、符号链接与主偏好配置已受安全拦截。")
                }

                Section {
                    Button {
                        if let clip = UIPasteboard.general.string {
                            rawPath = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Label(Self.isEn ? "Paste from Clipboard" : "从剪贴板粘贴路径", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        validateAndSave()
                    } label: {
                        Label(Self.isEn ? "Verify & Add to Watch List" : "校验并加入锁死列表", systemImage: "checkmark.shield.fill")
                            .fontWeight(.semibold)
                    }
                    .disabled(rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Self.isEn ? "Add Custom Path" : "添加自定义路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("关闭", symbol: "xmark")
                    }
                }
            }
            .onAppear {
                if rawPath.isEmpty,
                   let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   clip.hasPrefix("/var/") || clip.hasPrefix("/private/var/") {
                    rawPath = clip
                }
            }
        }
    }

    private func validateAndSave() {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let canon = AdCustomWatchStore.canonicalVarPath(trimmed)

        if let containerRoot = AdCustomWatchStore.containerRootPath(forCanonicalPath: canon) {
            _ = wq.grantAccess(path: containerRoot, requireWrite: false)
        }
        _ = wq.grantAccess(path: canon, requireWrite: false)

        let url = URL(fileURLWithPath: canon)
        var st = stat()
        guard lstat(canon, &st) == 0 else {
            errorMsg = Self.isEn
                ? "Path does not exist or cannot be accessed: \(canon)"
                : "路径不存在或暂无法读取：\(canon)"
            return
        }
        let fmt = st.st_mode & S_IFMT
        guard fmt == S_IFDIR || fmt == S_IFREG else {
            errorMsg = Self.isEn
                ? "Only regular folders or files are supported (symlinks rejected)."
                : "仅支持常规文件夹或文件（不支持符号链接或特殊设备文件）。"
            return
        }

        let ownerName = (try? fm.attributesOfItem(atPath: canon)[.ownerAccountName] as? String) ?? ""
        guard AdCustomWatchStore.shared.canAddAsCustomTarget(url: url, owner: ownerName) else {
            errorMsg = Self.isEn
                ? "Blocked by safety policy (protected directory, container root, or core app plist)."
                : "已被安全策略拦截（属于受保护系统路径、容器根目录或核心偏好配置）。"
            return
        }

        AdCustomWatchStore.shared.addValidatedRule(canonicalPath: canon, note: note)
        Haptic.shared.notify(.success)
        onAdded()
        dismiss()
    }
}

fileprivate struct AdWhitelistContainerOption: Identifiable, Hashable {
    var id: String { "\(isAppGroup ? "g" : "a"):\(bundleID.lowercased())" }
    let bundleID: String
    let displayTitle: String
    let isAppGroup: Bool
}

private struct AdWhitelistManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialContainers: [AdWhitelistContainerOption]

    @State private var rules: [AdWhitelistRule] = AdWhitelistStore.shared.rulesSnapshot()
    @State private var addMode: AdWhitelistKind = .bundleID
    @State private var inputTarget = ""
    @State private var inputNote = ""
    @State private var errorMsg: String?
    @State private var containerOptions: [AdWhitelistContainerOption] = []
    @State private var containerSearch = ""
    @State private var showContainerPicker = false
    @State private var isLoadingContainers = false

    private static var isEn: Bool { LocalizationManager.isEnglish }

    private var filteredContainerOptions: [AdWhitelistContainerOption] {
        let q = containerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return containerOptions }
        return containerOptions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q) ||
            $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $addMode) {
                        Text(Self.isEn ? "App / AppGroup" : "按应用 / 共享组")
                            .tag(AdWhitelistKind.bundleID)
                        Text(Self.isEn ? "Folder / File Path" : "按指定目录 / 文件")
                            .tag(AdWhitelistKind.exactPath)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: addMode) { _, _ in
                        inputTarget = ""
                        errorMsg = nil
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(addMode == .bundleID
                             ? (Self.isEn ? "Bundle ID or AppGroup ID" : "应用 Bundle ID 或 AppGroup ID")
                             : (Self.isEn ? "Container Subpath (/var/mobile/Containers/...)" : "容器内路径（/var/mobile/Containers/...）"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(
                            addMode == .bundleID
                                ? "com.smzdm.client.ios / group.com.example"
                                : "/var/mobile/Containers/.../SplashAd",
                            text: $inputTarget,
                            axis: addMode == .exactPath ? .vertical : .horizontal
                        )
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .lineLimit(addMode == .exactPath ? 2...4 : 1...1)
                    }
                    .padding(.vertical, 2)

                    TextField(
                        Self.isEn ? "Optional note (e.g. Crashes on splash lock)" : "可选备注（例如：锁死会闪退 / 保留广告配置）",
                        text: $inputNote
                    )
                    .font(.subheadline)

                    if let errorMsg {
                        Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let clip = UIPasteboard.general.string {
                                inputTarget = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                errorMsg = nil
                            }
                        } label: {
                            Label(Self.isEn ? "Paste" : "粘贴", systemImage: "doc.on.clipboard")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 8)

                        Button {
                            submitManualRule()
                        } label: {
                            Label(Self.isEn ? "Add to Whitelist" : "加入白名单", systemImage: "checkmark.shield.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.teal)
                        .disabled(inputTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if addMode == .bundleID {
                        DisclosureGroup(isExpanded: $showContainerPicker) {
                            TextField(
                                Self.isEn ? "Filter by app name or Bundle ID" : "筛选应用名或 Bundle ID",
                                text: $containerSearch
                            )
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                            if isLoadingContainers && containerOptions.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(Self.isEn ? "Loading installed containers..." : "正在读取本机已装容器...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if filteredContainerOptions.isEmpty {
                                Text(Self.isEn ? "No matching installed containers." : "未找到匹配的第三方应用或共享组。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let slice = Array(filteredContainerOptions.prefix(80))
                                ForEach(slice) { opt in
                                    let isAdded = AdWhitelistStore.shared.isContainerWhitelisted(id: opt.bundleID, isAppGroup: opt.isAppGroup)
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(opt.displayTitle)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                            Text(opt.bundleID)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Button {
                                            if isAdded {
                                                AdWhitelistStore.shared.removeMatchingContainer(id: opt.bundleID, isAppGroup: opt.isAppGroup)
                                                Haptic.shared.play(.soft)
                                            } else {
                                                AdWhitelistStore.shared.addBundleRule(bundleOrGroupID: opt.bundleID, note: opt.displayTitle)
                                                Haptic.shared.notify(.success)
                                            }
                                            rules = AdWhitelistStore.shared.rulesSnapshot()
                                        } label: {
                                            Label(
                                                isAdded ? (Self.isEn ? "Added" : "已加白") : (Self.isEn ? "Whitelist" : "加白"),
                                                systemImage: isAdded ? "checkmark" : "plus"
                                            )
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(isAdded ? .teal : .accentColor)
                                    }
                                    .padding(.vertical, 2)
                                }
                                if filteredContainerOptions.count > 80 {
                                    Text(Self.isEn
                                         ? "Showing first 80 of \(filteredContainerOptions.count) matches; filter above to narrow down."
                                         : "仅展示前 80 项（共 \(filteredContainerOptions.count) 项），请输入关键词精准筛选。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            Label(
                                Self.isEn
                                    ? "Quick-Pick Installed App / AppGroup (\(containerOptions.count))"
                                    : "从本机应用 / 共享组列表快速点选 (\(containerOptions.count))",
                                systemImage: "square.grid.2x2"
                            )
                            .font(.subheadline)
                        }
                    }
                } header: {
                    HeaderLabel(Self.isEn ? "Manually Add Whitelist" : "手动添加白名单", symbol: "plus.circle")
                } footer: {
                    Text(Self.isEn
                         ? "Whitelisting an App Bundle ID also covers its matching group.<bundleID> AppGroups. Whitelisted targets automatically skip 'Lock All' and restore writable permissions if previously locked."
                         : "按 Bundle ID 加白会同时跳过对应的 `group.<Bundle ID>` 共享组；按路径加白仅跳过该目录/文件及子项。新加白目标若此前已锁死，会自动恢复默认可读写权限。")
                }

                Section {
                    if rules.isEmpty {
                        Text(Self.isEn
                             ? "No active whitelist rules yet."
                             : "当前暂无生效中的白名单规则。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rules) { rule in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(rule.kind == .bundleID
                                             ? (Self.isEn ? "App/Group" : "应用/组")
                                             : (Self.isEn ? "Path" : "路径"))
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background((rule.kind == .bundleID ? Color.teal : Color.blue).opacity(0.15), in: Capsule())
                                            .foregroundStyle(rule.kind == .bundleID ? .teal : .blue)
                                            .fixedSize()

                                        Text(displayRuleTitle(for: rule))
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Text(rule.target)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)

                                    if !rule.note.isEmpty {
                                        Text(rule.note)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button(role: .destructive) {
                                    AdWhitelistStore.shared.remove(ruleID: rule.id)
                                    rules = AdWhitelistStore.shared.rulesSnapshot()
                                    Haptic.shared.play(.soft)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HeaderLabel(
                        Self.isEn ? "Active Whitelist Rules (\(rules.count))" : "已生效白名单规则 (\(rules.count))",
                        symbol: "checkmark.shield"
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Self.isEn ? "Ad Blocker Whitelist" : "去广告锁定白名单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("关闭", symbol: "xmark")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AdWhitelistStore.didChangeNotification)) { _ in
                rules = AdWhitelistStore.shared.rulesSnapshot()
            }
            .onAppear {
                rules = AdWhitelistStore.shared.rulesSnapshot()
                if containerOptions.isEmpty {
                    containerOptions = initialContainers
                }
                loadAllInstalledContainers()
            }
        }
    }

    private func displayRuleTitle(for rule: AdWhitelistRule) -> String {
        switch rule.kind {
        case .bundleID:
            if rule.target.lowercased().hasPrefix("group.") {
                return AdCacheBlockerView.formatGroupDisplayTitle(groupID: rule.target)
            }
            return AppContainerDirectoryHelper.displayName(for: rule.target)
        case .exactPath:
            return URL(fileURLWithPath: rule.target).lastPathComponent
        }
    }

    private func submitManualRule() {
        let trimmed = inputTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch addMode {
        case .bundleID:
            guard !trimmed.contains("/"),
                  trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                errorMsg = Self.isEn
                    ? "Enter a valid Bundle ID or AppGroup ID (no spaces or slashes)."
                    : "请输入合法的应用 Bundle ID 或 AppGroup ID（不能包含空格或斜杠）。"
                return
            }
            if AdWhitelistStore.shared.addBundleRule(bundleOrGroupID: trimmed, note: inputNote) != nil {
                errorMsg = nil
                inputTarget = ""
                inputNote = ""
                rules = AdWhitelistStore.shared.rulesSnapshot()
                Haptic.shared.notify(.success)
            }
        case .exactPath:
            let canon = AdCustomWatchStore.canonicalVarPath(trimmed)
            guard AdCustomWatchStore.containerRootPath(forCanonicalPath: canon) != nil else {
                errorMsg = Self.isEn
                    ? "Path must be a subfolder or file inside /var/mobile/Containers/Data/Application/ or /Shared/AppGroup/ (not the container root)."
                    : "路径必须位于 `/var/mobile/Containers/Data/Application/` 或 `/Shared/AppGroup/` 内部（不能是容器根目录）。"
                return
            }
            if AdWhitelistStore.shared.addPathRule(rawPath: canon, note: inputNote) != nil {
                errorMsg = nil
                inputTarget = ""
                inputNote = ""
                rules = AdWhitelistStore.shared.rulesSnapshot()
                Haptic.shared.notify(.success)
            }
        }
    }

    private func loadAllInstalledContainers() {
        guard !isLoadingContainers else { return }
        isLoadingContainers = true
        let seed = initialContainers
        let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"

        DispatchQueue.global(qos: .userInitiated).async {
            let appRaw = fsHandlers.getDirPaths(FSURL.appContainers.path)
            let groupRaw = fsHandlers.getDirPaths(FSURL.appGroup.path)
            var discovered: [(bundleID: String, isGroup: Bool)] = []
            var seenKeys = Set<String>()

            for raw in appRaw {
                let norm = CSStoreEngine.normalizeVarPath(raw)
                if let bid = CSStoreEngine.shared.bundleID(forContainerPath: norm, allowDiscovery: false),
                   !AdCacheBlockerView.shouldIgnoreContainerID(bid, isAppGroup: false, selfBID: selfBID) {
                    let key = "a:\(bid.lowercased())"
                    if seenKeys.insert(key).inserted {
                        discovered.append((bid, false))
                    }
                }
            }
            for raw in groupRaw {
                let norm = CSStoreEngine.normalizeVarPath(raw)
                if let bid = CSStoreEngine.shared.bundleID(forContainerPath: norm, allowDiscovery: false),
                   !AdCacheBlockerView.shouldIgnoreContainerID(bid, isAppGroup: true, selfBID: selfBID) {
                    let key = "g:\(bid.lowercased())"
                    if seenKeys.insert(key).inserted {
                        discovered.append((bid, true))
                    }
                }
            }

            DispatchQueue.main.async {
                var mergedByID: [String: AdWhitelistContainerOption] = [:]
                for opt in seed {
                    mergedByID[opt.id] = opt
                }
                for item in discovered {
                    let title = item.isGroup
                        ? AdCacheBlockerView.formatGroupDisplayTitle(groupID: item.bundleID)
                        : AppContainerDirectoryHelper.displayName(for: item.bundleID)
                    let opt = AdWhitelistContainerOption(
                        bundleID: item.bundleID,
                        displayTitle: title,
                        isAppGroup: item.isGroup
                    )
                    mergedByID[opt.id] = opt
                }
                self.containerOptions = mergedByID.values.sorted {
                    if $0.isAppGroup != $1.isAppGroup { return !$0.isAppGroup }
                    return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
                }
                self.isLoadingContainers = false
            }
        }
    }
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
    @State private var previewTarget: AdFilePreviewTarget?
    @State private var showAddCustomSheet = false
    @State private var showWhitelistSheet = false
    @State private var whitelistRulesCount = AdWhitelistStore.shared.rulesSnapshot().count

    private static var isEn: Bool { LocalizationManager.isEnglish }
    nonisolated private static let sentinelFileName = ".erosion_adlock"

    nonisolated fileprivate static let protectedBundleIDs: Set<String> = [
        "com.jbdotparty.Erosion",
        "com.apple.PosterBoard",
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone"
    ]

    nonisolated fileprivate static let ignoredAppGroupPrefixes: [String] = [
        "group.com.apple.",
        "systemgroup.",
        "group.com.jbdotparty.",
        "group.com.nssurge.",
        "group.com.liguangming.",
        "group.com.luo.",
        "group.com.loon",
        "group.ws.stash."
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
            ("Documents/TBDocuments/bootImagebiz", "淘宝开屏启动配置 (bootImagebiz)", "Taobao Boot Splash Config (bootImagebiz)"),
            ("Documents/TBDocuments/bootImageDoc", "淘宝开屏启动缓存 (bootImageDoc)", "Taobao Boot Splash Assets (bootImageDoc)"),
            ("Documents/TBDocuments/bootImagesDoc", "淘宝开屏启动缓存 (bootImagesDoc)", "Taobao Boot Splash Assets (bootImagesDoc)"),
            ("Library/Caches/TanxAd", "阿里妈妈 Tanx 广告", "Alimama Tanx Ad"),
            ("Library/Caches/TanxSDK", "阿里妈妈 Tanx SDK", "Alimama Tanx SDK"),
            ("Documents/SplashAd", "淘宝开屏广告", "Taobao Splash Ad")
        ],
        "com.taobao.fleamarket": [
            ("Library/Caches/TanxAd", "闲鱼 Tanx 广告缓存", "Idlefish Tanx Ad"),
            ("Library/Caches/SplashAd", "闲鱼开屏广告", "Idlefish Splash Ad")
        ],
        "com.360buy.jdmobile": [
            ("Library/Caches/startADImage", "京东开屏广告图片 (startADImage)", "JD Splash Ad Images (startADImage)"),
            ("Library/Caches/JADYun", "京东直投广告 SDK", "JD JADYun Ad SDK"),
            ("Library/Caches/JDAdSDK", "京东广告 SDK", "JD Ad SDK")
        ],
        "com.jingdong.app.mall": [
            ("Library/Caches/startADImage", "京东开屏广告图片 (startADImage)", "JD Splash Ad Images (startADImage)"),
            ("Library/Caches/JADYun", "京东直投广告 SDK", "JD JADYun Ad SDK"),
            ("Library/Caches/JDAdSDK", "京东广告 SDK", "JD Ad SDK")
        ],
        "com.meituan.imeituan": [
            ("Library/Caches/MTSplashAd", "美团开屏广告", "Meituan Splash Ad"),
            ("Library/Caches/SplashAd", "美团开屏广告缓存", "Meituan Splash Cache")
        ],
        "com.dianping.dpscope": [
            ("Documents/splashes_new", "大众点评开屏广告 (splashes_new)", "Dianping Splash Ads (splashes_new)"),
            ("Library/Caches/DPSplashAd", "大众点评开屏广告", "Dianping Splash Ad"),
            ("Library/Caches/SplashAd", "大众点评广告缓存", "Dianping Splash Cache")
        ],
        "cn.10086.app": [
            ("Library/DownloadCenter", "中国移动开屏与推广素材 (DownloadCenter)", "China Mobile Splash & Promo Cache (DownloadCenter)")
        ],
        "com.tencent.live4iphone": [
            ("Library/Caches/QAD/PreloadImageAdOrderCache", "腾讯视频 QAD 预加载广告", "Tencent Video QAD Preload Ads"),
            ("Library/Caches/QAD/QADWatchHistoryAdCache", "腾讯视频 QAD 历史广告缓存", "Tencent Video QAD History Ad Cache"),
            ("Library/Caches/QAD/maxViewAdCacheFolderName", "腾讯视频 QAD 开屏闪屏广告", "Tencent Video QAD MaxView Splash Ads"),
            ("Library/Caches/TAD/PushAdPendantCache", "腾讯视频 TAD 挂件推送广告", "Tencent Video TAD Pendant Ads"),
            ("Library/Caches/TADCache", "腾讯视频 TAD 广告缓存", "Tencent Video TAD Cache"),
            ("Documents/TADCache", "腾讯视频 TAD 文档广告缓存", "Tencent Video TAD Documents Cache")
        ],
        "com.dragon.read": [
            ("Documents/TTAdSplashSimpleCache", "番茄小说开屏广告缓存 (TTAdSplashSimpleCache)", "Fanqie Novel Splash Ad Cache (TTAdSplashSimpleCache)")
        ],
        "ctrip.com": [
            ("Library/Caches/LoadingImages", "携程开屏启动图缓存 (LoadingImages)", "Ctrip Splash LoadingImages Cache")
        ],
        "ctrip.wireless": [
            ("Library/Caches/LoadingImages", "携程开屏启动图缓存 (LoadingImages)", "Ctrip Splash LoadingImages Cache")
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
        "ksadsdk": ("快手广告 SDK (KSAdSDK)", "Kwai Ad SDK (KSAdSDK)"),
        "ksadcache": ("快手广告缓存", "Kwai Ad Cache"),
        "ksad_cache": ("快手广告缓存", "Kwai Ad Cache"),
        "com.kwad.sdk": ("快手联盟 (Kwad)", "Kwai Ad SDK"),
        "kwadsdk": ("快手联盟 SDK", "Kwad SDK"),
        "buadsdk": ("穿山甲广告 (BUAdSDK)", "Pangle / CSJ (BUAdSDK)"),
        "csjadsdk": ("穿山甲广告 SDK", "CSJ Ad SDK"),
        "csjadcache": ("穿山甲广告缓存", "CSJ Ad Cache"),
        "pangle_sdk": ("穿山甲 Pangle SDK", "Pangle Ad SDK"),
        "panglesdk": ("穿山甲 Pangle SDK", "Pangle Ad SDK"),
        "bytedancead": ("字节广告缓存", "ByteDance Ad Cache"),
        "ttadsdk": ("字节穿山甲 (TTAdSDK)", "ByteDance TTAdSDK"),
        "pangolinad": ("穿山甲广告 (Pangolin)", "Pangolin Ad Cache"),
        "gromoread": ("GroMore 聚合广告", "GroMore Ad SDK"),
        "gdtmobsdk": ("腾讯优量汇 (GDTMobSDK)", "Tencent YLH (GDTMobSDK)"),
        "gdt_splash": ("优量汇开屏缓存", "GDT Splash Cache"),
        "gdtsplash": ("优量汇开屏缓存", "GDT Splash Cache"),
        "gdtadcache": ("优量汇广告缓存", "GDT Ad Cache"),
        "gdtnetcache": ("优量汇网络缓存", "GDT Net Cache"),
        "tadcache": ("腾讯广告缓存 (TADCache)", "Tencent Ad Cache (TAD)"),
        "tencentad": ("腾讯广告缓存", "Tencent Ad Cache"),
        "qq_ad_cache": ("腾讯广告缓存", "QQ Ad Cache"),
        "ylhadsdk": ("优量汇广告 SDK", "YLH Ad SDK"),
        "baidumobad": ("百度百青藤广告", "Baidu MobAd SDK"),
        "bd_ad_cache": ("百度广告缓存", "Baidu Ad Cache"),
        "baidusplashad": ("百度开屏广告", "Baidu Splash Ad"),
        "bdsplashad": ("开屏广告缓存 (BDSplashAd)", "Splash Ad Cache (BDSplashAd)"),
        "beizisdk": ("倍孜开屏广告 (BeiZi)", "BeiZi Ad SDK"),
        "beiziad": ("倍孜广告缓存 (BeiZi)", "BeiZi Ad Cache"),
        "octopusad": ("章鱼广告 (OctopusAd)", "Octopus Ad SDK"),
        "jadyun": ("京东直投广告 (JADYun)", "JD JADYun Ad SDK"),
        "jdadsdk": ("京东广告 SDK", "JD Ad SDK"),
        "startadimage": ("开屏广告图片缓存 (startADImage)", "Splash Ad Image Cache (startADImage)"),
        "ttadsplashsimplecache": ("穿山甲开屏广告缓存 (TTAdSplashSimpleCache)", "Pangle Splash Ad Cache (TTAdSplashSimpleCache)"),
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

    // Curated lowercased single splash/ad config filenames
    nonisolated private static let exactAdConfigFiles: [String: (zh: String, en: String)] = [
        "splash_ad.json": ("开屏广告配置 (JSON)", "Splash Ad Config (JSON)"),
        "splashad.json": ("开屏广告配置 (JSON)", "Splash Ad Config (JSON)"),
        "splash_ads.json": ("开屏广告配置 (JSON)", "Splash Ads Config (JSON)"),
        "splash_cache.json": ("开屏广告索引 (JSON)", "Splash Cache Index (JSON)"),
        "launch_ad.json": ("启动广告配置 (JSON)", "Launch Ad Config (JSON)"),
        "launchad.json": ("启动广告配置 (JSON)", "Launch Ad Config (JSON)"),
        "open_screen_ad.json": ("开屏广告配置 (JSON)", "Open Screen Ad Config (JSON)"),
        "ad_splash.json": ("开屏广告配置 (JSON)", "Ad Splash Config (JSON)"),
        "wb_splash_ad.json": ("微博开屏配置 (JSON)", "Weibo Splash Config (JSON)"),
        "splash_ad.plist": ("开屏广告配置 (Plist)", "Splash Ad Config (Plist)"),
        "splashad.plist": ("开屏广告配置 (Plist)", "Splash Ad Config (Plist)"),
        "launch_ad.plist": ("启动广告配置 (Plist)", "Launch Ad Config (Plist)"),
        "xhlaunchad.plist": ("XHLaunchAd 配置 (Plist)", "XHLaunchAd Config (Plist)"),
        "ad_splash.plist": ("开屏广告配置 (Plist)", "Ad Splash Config (Plist)"),
        "wb_ad_cache.plist": ("微博广告配置 (Plist)", "Weibo Ad Config (Plist)")
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

    private var whitelistedTargetCount: Int {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter { $0.isWhitelisted }.count
        }
    }

    private var activeTargetCount: Int {
        totalAdFoldersCount - whitelistedTargetCount
    }

    private var fullyLockedCount: Int {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter { !$0.isWhitelisted && !$0.needsActionToLock }.count
        }
    }

    private var pendingLockOrHardenCount: Int {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter { $0.needsActionToLock }.count
        }
    }

    private var unlockedOnlyCount: Int {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter { $0.isLockedReadOnly }.count
        }
    }

    private var totalReclaimableAdBytes: Int64 {
        detectedEntries.reduce(0) { acc, entry in
            acc + entry.items.filter { !$0.isWhitelisted && !$0.isLockedReadOnly }.reduce(0) { $0 + $1.cachedBytes }
        }
    }

    private var discoveredContainerOptions: [AdWhitelistContainerOption] {
        var byID: [String: AdWhitelistContainerOption] = [:]
        for entry in allEntries {
            let opt = AdWhitelistContainerOption(
                bundleID: entry.bundleID,
                displayTitle: entry.displayTitle,
                isAppGroup: entry.isAppGroup
            )
            byID[opt.id] = opt
        }
        return byID.values.sorted {
            if $0.isAppGroup != $1.isAppGroup { return !$0.isAppGroup }
            return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    private var scanProgressText: String {
        if scanTotalCount > 0 {
            if isStopping {
                return Self.isEn
                    ? "Stopping (\(scanCompletedCount) / \(scanTotalCount))..."
                    : "正在停止 (\(scanCompletedCount) / \(scanTotalCount))..."
            }
            return Self.isEn
                ? "Scanning \(scanCompletedCount) / \(scanTotalCount) containers..."
                : "正在检索应用与共享组 (\(scanCompletedCount) / \(scanTotalCount))..."
        }
        return Self.isEn ? "Scanning app & AppGroup containers..." : "正在扫描应用与 AppGroup 广告目录/配置..."
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.isEn ? "Detected Ad Caches & Configs" : "已定位开屏广告目录与配置")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(totalAdFoldersCount)")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(totalAdFoldersCount > 0 ? Color.accentColor : Color.secondary)
                                Text(Self.isEn
                                     ? "targets across \(detectedEntries.count) containers"
                                     : "项目标 · 涉及 \(detectedEntries.count) 个容器")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Self.isEn ? "Sentinel Protected" : "防重建锁就绪")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text("\(fullyLockedCount) / \(activeTargetCount)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(fullyLockedCount > 0 ? .green : .secondary)
                        }
                        .layoutPriority(1)
                    }

                    if whitelistedTargetCount > 0 {
                        Text(Self.isEn
                             ? "Skipping \(whitelistedTargetCount) whitelisted target(s)"
                             : "已按白名单自动跳过 \(whitelistedTargetCount) 项")
                            .font(.caption)
                            .foregroundStyle(.teal)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if totalReclaimableAdBytes > 0 {
                        Text(Self.isEn
                             ? "Pending ad cache to wipe & lock: \(AppContainerDirectoryHelper.formatBytes(totalReclaimableAdBytes))"
                             : "未锁目标待清空广告体积：\(AppContainerDirectoryHelper.formatBytes(totalReclaimableAdBytes))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                overviewSecondaryActions
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    overviewRescanButton
                                    Spacer(minLength: 8)
                                    overviewWhitelistButton
                                }
                                if totalAdFoldersCount > 0 {
                                    HStack {
                                        Spacer(minLength: 0)
                                        overviewBatchMenu
                                    }
                                }
                            }
                        }

                        if pendingLockOrHardenCount > 0 {
                            Button {
                                confirmBatchLockAll()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.shield.fill")
                                    Text(Self.isEn
                                         ? "Lock All Pending (\(pendingLockOrHardenCount))"
                                         : "一键全锁 (\(pendingLockOrHardenCount))")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.orange)
                            .disabled(isScanning || isOperating)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

                PlainToggle(
                    Self.isEn ? "Show Containers Without Hits" : "显示暂未检出广告目录的容器",
                    subtitle: Self.isEn
                        ? "Includes third-party Apps & AppGroups for manual container inspection"
                        : "开启后可查看所有第三方应用与共享组，手动浏览排查或长按加入收藏",
                    isOn: $showEmptyApps
                )
            } header: {
                HeaderLabel(Self.isEn ? "Anti-Recreate Lock & Coverage" : "防重建精准锁死概览", symbol: "lock.shield")
            } footer: {
                Text(Self.isEn
                     ? "Directory lock wipes cached ad files, drops a 0-byte 0444 sentinel (.erosion_adlock) inside, and sets POSIX 0555 to resist removeItem() directory recreation. Config files are emptied to valid empty JSON/Plist and locked to 0444. Covers Apps, AppGroups & your custom watch rules."
                     : "「一键锁死」对文件夹会先清空物料、写入 0 字节 0444 防重建占位符 (.erosion_adlock) 并锁死 0555，防 SDK 删空目录重建；对广告配置文件会清空为合法空 JSON/Plist 并锁死 0444。已涵盖第三方应用、AppGroup 共享组及你收藏的自定义路径。")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(Self.isEn
                             ? "Local Lock Boundary: Locking local ad folders & configs (0555 sentinel / 0444 read-only) stops ads from caching to disk, but live ad network requests still fire and real-time in-memory ads may still appear."
                             : "本地锁死边界：本功能仅清空并锁死本地广告缓存目录与配置文件（0555 防重建锁 / 0444 只读），阻止广告素材落盘，但应用自身的广告网络请求依然存在，纯联网实时加载的广告仍可能出现。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    Label {
                        Text(Self.isEn
                             ? "Recommended Pairing: Combine with ad-blocking rules in your proxy client (Surge / Quantumult X / Loon / Stash / Shadowrocket, etc.) to block ad network requests alongside local cache locking for complete ad blocking."
                             : "最佳搭配建议：建议配合代理工具（如 Surge / Quantumult X / Loon / Stash / Shadowrocket 等）的去广告规则屏蔽广告网络请求，「网络拦截请求 + 本地锁死残留缓存」双管齐下即可实现精准屏蔽。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                HeaderLabel(Self.isEn ? "Boundary & Network Pairing Tip" : "生效边界与搭配建议", symbol: "network.badge.shield.half.filled")
            }

            if isScanning || isOperating {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isOperating
                             ? (Self.isEn ? "Updating permissions & sentinel..." : "正在安全清理并写入防重建权限锁...")
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
                             ? "No matching ad caches or config files found."
                             : "暂未检出符合特征的开屏广告目录或配置文件")
                            .font(.subheadline.weight(.medium))
                        Text(Self.isEn
                             ? "Tap '+' in the top right to paste a path, or turn on 'Show Containers Without Hits' above and long-press any folder/file in File Browser -> 'Add to Ad Blocker'."
                             : "可点击右上角「+」手动添加路径，或在「文件浏览」中进入目标应用/AppGroup 长按任意目录或配置文件 ➔「加入广告锁死列表」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ForEach(displayedEntries) { entry in
                    Section {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(entry.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    if entry.isAppWhitelisted {
                                        Text(Self.isEn ? "Whitelist" : "白名单")
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.teal.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.teal)
                                            .fixedSize()
                                    }
                                }
                                Text(appStatusSubtitle(for: entry))
                                    .font(.caption2)
                                    .foregroundStyle(appStatusColor(for: entry))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Menu {
                                Button {
                                    locateTarget = LocateAdTarget(containerURL: entry.containerURL, folderURL: nil)
                                } label: {
                                    Label(Self.isEn ? "Browse Container" : "浏览容器目录", systemImage: "folder")
                                }

                                if entry.isAppWhitelisted {
                                    Button {
                                        AdWhitelistStore.shared.removeMatchingContainer(id: entry.bundleID, isAppGroup: entry.isAppGroup)
                                        Haptic.shared.play(.soft)
                                    } label: {
                                        Label(Self.isEn ? "Remove App from Whitelist" : "移出应用白名单", systemImage: "shield.slash")
                                    }
                                } else {
                                    Button {
                                        whitelistApp(entry)
                                    } label: {
                                        Label(Self.isEn ? "Whitelist App (Skip Lock All)" : "加入应用白名单（防误锁）", systemImage: "checkmark.shield")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 2)
                            }
                            .buttonStyle(.borderless)
                            .layoutPriority(1)

                            if entry.isAppWhitelisted {
                                if entry.items.contains(where: { $0.isLockedReadOnly }) {
                                    Button {
                                        toggleAllForApp(entry, lock: false)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "lock.open.fill")
                                            Text(Self.isEn ? "Unlock All" : "全部恢复")
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.green)
                                    .layoutPriority(1)
                                    .disabled(isScanning || isOperating)
                                } else {
                                    Button {
                                        AdWhitelistStore.shared.removeMatchingContainer(id: entry.bundleID, isAppGroup: entry.isAppGroup)
                                        Haptic.shared.play(.soft)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "shield.slash")
                                            Text(Self.isEn ? "Unwhitelist" : "移出白名单")
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.teal)
                                    .layoutPriority(1)
                                    .disabled(isScanning || isOperating)
                                }
                            } else if !entry.items.isEmpty {
                                let hasPending = entry.items.contains { $0.needsActionToLock }
                                let hasLocked = entry.items.contains { $0.isLockedReadOnly }
                                if hasPending || hasLocked {
                                    Button {
                                        toggleAllForApp(entry, lock: hasPending)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: hasPending ? "lock.fill" : "lock.open.fill")
                                            Text(hasPending
                                                 ? (Self.isEn ? "Lock All" : "全锁该组")
                                                 : (Self.isEn ? "Unlock All" : "全部恢复"))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(hasPending ? .orange : .green)
                                    .layoutPriority(1)
                                    .disabled(isScanning || isOperating)
                                }
                            }
                        }

                        ForEach(entry.items) { item in
                            AdFolderRowView(
                                item: item,
                                isBusy: isOperating || (busyFolderID == item.id),
                                onLocate: {
                                    locateTarget = LocateAdTarget(containerURL: entry.containerURL, folderURL: item.url)
                                },
                                onPreview: canPreviewItem(item) ? {
                                    openPreview(for: item)
                                } : nil,
                                onToggleLock: {
                                    toggleSingleFolder(item, in: entry)
                                },
                                onTogglePathWhitelist: (!item.isContainerWhitelisted || item.isPathWhitelisted) ? {
                                    togglePathWhitelist(item, in: entry)
                                } : nil,
                                onRemoveCustom: item.isCustomRule ? {
                                    removeCustomItem(item, in: entry)
                                } : nil
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Self.isEn ? "Splash Ad Blocker" : "开屏广告缓存精准锁死")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            prompt: Self.isEn ? "Search app, AppGroup, Bundle ID or SDK" : "搜索应用名、AppGroup 或广告特征"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showWhitelistSheet = true
                } label: {
                    ToolbarLabel(Self.isEn ? "Whitelist" : "白名单", symbol: "checkmark.shield")
                }
                .disabled(isOperating)

                Button {
                    showAddCustomSheet = true
                } label: {
                    ToolbarLabel(Self.isEn ? "Add Custom" : "添加", symbol: "plus")
                }
                .disabled(isOperating)
            }
        }
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
        .sheet(item: $previewTarget) { target in
            if target.isPlist {
                PlistViewer(target.fileURL)
            } else {
                TextViewer(target.fileURL)
                    .environmentObject(ErosionManager.shared)
            }
        }
        .sheet(isPresented: $showAddCustomSheet) {
            AddCustomAdPathSheet {
                scanAdFolders()
            }
        }
        .sheet(isPresented: $showWhitelistSheet) {
            AdWhitelistManagerSheet(initialContainers: discoveredContainerOptions)
        }
        .onReceive(NotificationCenter.default.publisher(for: AdCustomWatchStore.didChangeNotification)) { _ in
            if !isScanning && !isOperating {
                scanAdFolders()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AdWhitelistStore.didChangeNotification)) { _ in
            refreshWhitelistFlagsAndAutoUnlockIfNeeded()
        }
        .onAppear {
            whitelistRulesCount = AdWhitelistStore.shared.rulesSnapshot().count
            if allEntries.isEmpty && !isScanning && !isOperating {
                scanAdFolders()
            }
        }
    }

    @ViewBuilder
    private var overviewSecondaryActions: some View {
        overviewRescanButton
        Spacer(minLength: 8)
        overviewWhitelistButton
        if totalAdFoldersCount > 0 {
            overviewBatchMenu
        }
    }

    private var overviewRescanButton: some View {
        Button {
            scanAdFolders()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                Text(Self.isEn ? "Rescan" : "重新扫描")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .disabled(isScanning || isOperating)
    }

    private var overviewWhitelistButton: some View {
        Button {
            showWhitelistSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                Text(Self.isEn ? "Whitelist (\(whitelistRulesCount))" : "白名单 (\(whitelistRulesCount))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.subheadline)
            .foregroundStyle(.teal)
        }
        .buttonStyle(.borderless)
        .disabled(isOperating)
    }

    private var overviewBatchMenu: some View {
        Menu {
            Button {
                confirmBatchLockAll()
            } label: {
                Label(
                    Self.isEn ? "Lock / Harden All (Sentinel)" : "一键锁死 / 加固全部",
                    systemImage: "lock.fill"
                )
            }
            .disabled(pendingLockOrHardenCount == 0)

            Button {
                batchUnlockAll()
            } label: {
                Label(
                    Self.isEn ? "Restore All Read-Write" : "全部恢复默认读写",
                    systemImage: "lock.open.fill"
                )
            }
            .disabled(unlockedOnlyCount == 0)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                Text(Self.isEn ? "Batch" : "批量操作")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .disabled(isScanning || isOperating)
    }

    private func canPreviewItem(_ item: AdCacheFolderItem) -> Bool {
        guard !item.isDirectory else { return false }
        let ext = item.url.pathExtension.lowercased()
        return ["plist", "json", "txt", "xml", "cfg", "conf", "log", "yaml", "yml"].contains(ext)
    }

    private func openPreview(for item: AdCacheFolderItem) {
        _ = wq.grantAccess(path: item.parentURL.path, requireWrite: false)
        _ = wq.grantAccess(path: item.fullPath, requireWrite: false)
        let isPlist = item.url.pathExtension.lowercased() == "plist" && conformsToPlistViewer(item.url)
        previewTarget = AdFilePreviewTarget(fileURL: item.url, isPlist: isPlist)
    }

    private func appStatusSubtitle(for entry: AppAdCacheEntry) -> String {
        if entry.isAppWhitelisted {
            let lockedCount = entry.items.filter { $0.isLockedReadOnly }.count
            if lockedCount > 0 {
                return Self.isEn
                    ? "Whitelisted · \(lockedCount) locked item(s) can be restored"
                    : "已加入白名单 · 有 \(lockedCount) 项当前处于锁定状态可恢复"
            }
            return Self.isEn
                ? "Whitelisted · Skipped by Lock All"
                : "已加入白名单 · 自动跳过一键全锁"
        }
        if entry.items.isEmpty {
            return Self.isEn
                ? "0 auto-matched · tap Browse to inspect"
                : "未匹配已知目录 · 可在菜单「浏览容器」长按添加"
        }
        let skippedCount = entry.items.filter { $0.isWhitelisted }.count
        let lockableItems = entry.items.filter { !$0.isWhitelisted }
        if lockableItems.isEmpty {
            return Self.isEn
                ? "All \(skippedCount) item(s) whitelisted"
                : "全部 \(skippedCount) 项已按路径白名单跳过"
        }
        let fullyProtected = lockableItems.filter { !$0.needsActionToLock }.count
        let total = lockableItems.count
        if fullyProtected == total {
            return Self.isEn
                ? "All \(total) protected" + (skippedCount > 0 ? " · \(skippedCount) whitelisted" : " (sentinel / 0444)")
                : "已全防重建锁死 (\(fullyProtected)/\(total))" + (skippedCount > 0 ? " · \(skippedCount) 项已加白" : "")
        }
        return Self.isEn
            ? "\(total - fullyProtected) need lock · \(fullyProtected) locked" + (skippedCount > 0 ? " · \(skippedCount) whitelisted" : "")
            : "发现 \(entry.items.count) 项（\(total - fullyProtected) 项待锁 · \(fullyProtected) 项已锁" + (skippedCount > 0 ? " · \(skippedCount) 项加白）" : "）")
    }

    private func appStatusColor(for entry: AppAdCacheEntry) -> Color {
        if entry.isAppWhitelisted {
            return entry.items.contains(where: { $0.isLockedReadOnly }) ? .orange : .teal
        }
        if entry.items.isEmpty { return .secondary }
        let lockableItems = entry.items.filter { !$0.isWhitelisted }
        if lockableItems.isEmpty { return .teal }
        let fullyProtected = lockableItems.filter { !$0.needsActionToLock }.count
        return fullyProtected == lockableItems.count ? .green : .orange
    }

    private func whitelistApp(_ entry: AppAdCacheEntry) {
        AdWhitelistStore.shared.addBundleRule(bundleOrGroupID: entry.bundleID, note: entry.displayTitle)
        Haptic.shared.notify(.success)
    }

    private func togglePathWhitelist(_ item: AdCacheFolderItem, in entry: AppAdCacheEntry) {
        if item.isPathWhitelisted {
            AdWhitelistStore.shared.removeExactPath(item.fullPath)
            Haptic.shared.play(.soft)
        } else {
            let note = "\(entry.displayTitle) · \(item.relativePath)"
            AdWhitelistStore.shared.addPathRule(rawPath: item.fullPath, note: note)
            Haptic.shared.notify(.success)
        }
    }

    private func refreshWhitelistFlagsAndAutoUnlockIfNeeded() {
        whitelistRulesCount = AdWhitelistStore.shared.rulesSnapshot().count
        guard !allEntries.isEmpty else { return }

        var unlockTargets: [(AppAdCacheEntry, AdCacheFolderItem)] = []
        for i in allEntries.indices {
            let appW = AdWhitelistStore.shared.isContainerWhitelisted(
                id: allEntries[i].bundleID,
                isAppGroup: allEntries[i].isAppGroup
            )
            allEntries[i].isAppWhitelisted = appW
            for j in allEntries[i].items.indices {
                let pathW = AdWhitelistStore.shared.isPathWhitelisted(allEntries[i].items[j].fullPath)
                allEntries[i].items[j].isContainerWhitelisted = appW
                allEntries[i].items[j].isPathWhitelisted = pathW
                let item = allEntries[i].items[j]
                if (appW || pathW) && (item.isLockedReadOnly || (item.isDirectory && item.hasSentinelLock)) {
                    unlockTargets.append((allEntries[i], item))
                }
            }
            allEntries[i].items.sort {
                if $0.isCustomRule != $1.isCustomRule { return $0.isCustomRule }
                if $0.needsActionToLock != $1.needsActionToLock { return $0.needsActionToLock }
                if $0.cachedBytes != $1.cachedBytes { return $0.cachedBytes > $1.cachedBytes }
                return $0.relativePath < $1.relativePath
            }
        }
        allEntries = Self.sortedEntries(allEntries)

        guard !unlockTargets.isEmpty, !isScanning, !isOperating else { return }
        isOperating = true
        DispatchQueue.global(qos: .userInitiated).async {
            var updates: [(appID: String, folderID: String, mode: Int, bytes: Int64, hasSentinel: Bool)] = []
            for (entry, item) in unlockTargets {
                let res = Self.setAdTargetLocked(item: item, containerURL: entry.containerURL, locked: false)
                if res.ok {
                    updates.append((entry.id, item.id, res.mode, res.bytes, res.hasSentinel))
                }
            }
            DispatchQueue.main.async {
                self.isOperating = false
                for u in updates {
                    self.updateFolderState(
                        appID: u.appID,
                        folderID: u.folderID,
                        mode: u.mode,
                        bytes: u.bytes,
                        hasSentinel: u.hasSentinel
                    )
                }
                if !updates.isEmpty {
                    ErosionManager.shared.refreshFiles.toggle()
                }
            }
        }
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

        let customRules = AdCustomWatchStore.shared.rulesSnapshot()

        DispatchQueue.global(qos: .userInitiated).async {
            let appRaw = fsHandlers.getDirPaths(FSURL.appContainers.path)
            let groupRaw = fsHandlers.getDirPaths(FSURL.appGroup.path)

            var seenContainerPaths = Set<String>()
            var containerTargets: [(rawPath: String, isGroup: Bool)] = []
            containerTargets.reserveCapacity(appRaw.count + groupRaw.count)

            for rawPath in appRaw {
                let norm = CSStoreEngine.normalizeVarPath(rawPath)
                if seenContainerPaths.insert(norm).inserted {
                    containerTargets.append((rawPath, false))
                }
            }
            for rawPath in groupRaw {
                let norm = CSStoreEngine.normalizeVarPath(rawPath)
                if seenContainerPaths.insert(norm).inserted {
                    containerTargets.append((rawPath, true))
                }
            }

            let totalCount = containerTargets.count
            DispatchQueue.main.async {
                guard self.activeScanToken?.id == token.id else { return }
                self.scanTotalCount = totalCount
            }

            var deniedContainers: Set<String> = []
            var collected: [AppAdCacheEntry] = []
            let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
            var completed = 0
            var lastUIUpdate = CFAbsoluteTimeGetCurrent()

            for target in containerTargets {
                if token.isCancelled { break }
                let entry = Self.scanContainerForAdTargets(
                    rawPath: target.rawPath,
                    isAppGroup: target.isGroup,
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
                    var interim = collected
                    Self.mergeCustomRules(customRules, into: &interim, cancelFlag: token)
                    let snap = Self.sortedEntries(interim)
                    DispatchQueue.main.async {
                        guard self.activeScanToken?.id == token.id else { return }
                        self.scanCompletedCount = prog
                        self.allEntries = snap
                    }
                }
            }

            Self.mergeCustomRules(customRules, into: &collected, cancelFlag: token)
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
        let lockTarget = item.needsActionToLock
        busyFolderID = item.id
        isOperating = true

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.setAdTargetLocked(item: item, containerURL: entry.containerURL, locked: lockTarget)
            DispatchQueue.main.async {
                busyFolderID = nil
                isOperating = false
                if outcome.ok {
                    updateFolderState(
                        appID: entry.id,
                        folderID: item.id,
                        mode: outcome.mode,
                        bytes: outcome.bytes,
                        hasSentinel: outcome.hasSentinel
                    )
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

    private func removeCustomItem(_ item: AdCacheFolderItem, in entry: AppAdCacheEntry) {
        guard !isScanning && !isOperating else { return }
        if item.isLockedReadOnly {
            isOperating = true
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.setAdTargetLocked(item: item, containerURL: entry.containerURL, locked: false)
                AdCustomWatchStore.shared.remove(fullPath: item.fullPath)
                DispatchQueue.main.async {
                    isOperating = false
                    Haptic.shared.notify(.success)
                    scanAdFolders()
                }
            }
        } else {
            AdCustomWatchStore.shared.remove(fullPath: item.fullPath)
            Haptic.shared.play(.soft)
        }
    }

    private func toggleAllForApp(_ entry: AppAdCacheEntry, lock: Bool) {
        guard !isScanning && !isOperating else { return }
        let targets = lock
            ? entry.items.filter { $0.needsActionToLock }
            : entry.items.filter { $0.isLockedReadOnly }
        guard !targets.isEmpty else { return }

        if lock {
            let totalBytes = targets.reduce(Int64(0)) { $0 + $1.cachedBytes }
            Alertinator.shared.alert(
                title: Self.isEn ? "Lock & Harden Container?" : "确认锁死并加固该容器广告项？",
                body: Self.isEn
                    ? "Will clear \(targets.count) ad folders/configs in \(entry.displayTitle) (\(AppContainerDirectoryHelper.formatBytes(totalBytes))) and apply anti-recreate 0555/0444 locks."
                    : "将处理「\(entry.displayTitle)」中 \(targets.count) 个广告目录/配置（约 \(AppContainerDirectoryHelper.formatBytes(totalBytes))），写入防重建占位符并锁定为 0555 / 0444 只读状态。",
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
            entry.items.filter { $0.needsActionToLock }.map { (entry, $0) }
        }
        guard !targets.isEmpty else { return }
        let bytes = targets.reduce(Int64(0)) { $0 + $1.1.cachedBytes }
        Alertinator.shared.alert(
            title: Self.isEn ? "Lock & Harden All Targets?" : "确认一键锁死/加固全部目标？",
            body: Self.isEn
                ? "Will clear \(targets.count) detected ad folders/configs (\(AppContainerDirectoryHelper.formatBytes(bytes))) and apply anti-recreate 0555+sentinel / 0444 locks. Restorable anytime."
                : "将处理共 \(targets.count) 个广告目录与配置（约 \(AppContainerDirectoryHelper.formatBytes(bytes))），写入防重建占位符并锁死为只读状态。随时可一键恢复读写。",
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
            var updates: [(appID: String, folderID: String, mode: Int, bytes: Int64, hasSentinel: Bool)] = []

            for (entry, item) in pairs {
                let res = Self.setAdTargetLocked(item: item, containerURL: entry.containerURL, locked: lock)
                if res.ok {
                    successCount += 1
                    updates.append((entry.id, item.id, res.mode, res.bytes, res.hasSentinel))
                } else {
                    failCount += 1
                    lastError = res.error
                }
            }

            DispatchQueue.main.async {
                isOperating = false
                for u in updates {
                    updateFolderState(
                        appID: u.appID,
                        folderID: u.folderID,
                        mode: u.mode,
                        bytes: u.bytes,
                        hasSentinel: u.hasSentinel
                    )
                }
                if successCount > 0 {
                    ErosionManager.shared.refreshFiles.toggle()
                }
                if failCount == 0 {
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(
                        title: lock
                            ? (Self.isEn ? "Locked with Sentinel" : "已成功锁死并加固")
                            : (Self.isEn ? "Restored Read-Write" : "已恢复默认读写"),
                        body: lock
                            ? (Self.isEn ? "Protected \(successCount) ad targets against recreation." : "已成功锁死并防重建加固 \(successCount) 项广告目录/配置。")
                            : (Self.isEn ? "Restored \(successCount) targets to writable permissions." : "已将 \(successCount) 项恢复为默认可读写权限并清除占位符。")
                    )
                } else {
                    Haptic.shared.notify(.warning)
                    Alertinator.shared.alert(
                        title: Self.isEn ? "Completed with Errors" : "部分目标处理失败",
                        body: (Self.isEn
                               ? "Succeeded: \(successCount), Failed: \(failCount)."
                               : "成功 \(successCount) 项，失败 \(failCount) 项。")
                            + (lastError.map { "\n\($0)" } ?? "")
                    )
                }
            }
        }
    }

    private func updateFolderState(appID: String, folderID: String, mode: Int, bytes: Int64, hasSentinel: Bool) {
        guard let appIdx = allEntries.firstIndex(where: { $0.id == appID }),
              let itemIdx = allEntries[appIdx].items.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        allEntries[appIdx].items[itemIdx].posixMode = mode
        allEntries[appIdx].items[itemIdx].cachedBytes = bytes
        allEntries[appIdx].items[itemIdx].hasSentinelLock = hasSentinel
    }

    // MARK: - Container Scan Helpers

    private static func sortedEntries(_ list: [AppAdCacheEntry]) -> [AppAdCacheEntry] {
        list.sorted { lhs, rhs in
            if lhs.items.isEmpty != rhs.items.isEmpty {
                return !lhs.items.isEmpty
            }
            if lhs.isAppWhitelisted != rhs.isAppWhitelisted {
                return !lhs.isAppWhitelisted
            }
            let lhsHasCustom = lhs.items.contains { $0.isCustomRule }
            let rhsHasCustom = rhs.items.contains { $0.isCustomRule }
            if lhsHasCustom != rhsHasCustom {
                return lhsHasCustom
            }
            if lhs.items.count != rhs.items.count {
                return lhs.items.count > rhs.items.count
            }
            if lhs.isAppGroup != rhs.isAppGroup {
                return !lhs.isAppGroup
            }
            return lhs.displayTitle < rhs.displayTitle
        }
    }

    fileprivate static func formatGroupDisplayTitle(groupID: String) -> String {
        let candidateBID = groupID.hasPrefix("group.") ? String(groupID.dropFirst("group.".count)) : groupID
        let appDisplay = AppContainerDirectoryHelper.displayName(for: candidateBID)
        let prefix = isEn ? "[AppGroup]" : "[共享组]"
        if appDisplay != candidateBID {
            let shortApp = appDisplay.components(separatedBy: " (").first ?? appDisplay
            return "\(prefix) \(shortApp) (\(groupID))"
        }
        return "\(prefix) \(groupID)"
    }

    nonisolated fileprivate static func shouldIgnoreContainerID(_ id: String, isAppGroup: Bool, selfBID: String) -> Bool {
        guard !id.isEmpty, id != selfBID, !protectedBundleIDs.contains(id) else {
            return true
        }
        let lower = id.lowercased()
        if isAppGroup {
            return ignoredAppGroupPrefixes.contains { lower.hasPrefix($0) }
        }
        return lower.hasPrefix("com.apple.")
    }

    private static func scanContainerForAdTargets(
        rawPath: String,
        isAppGroup: Bool,
        selfBID: String,
        deniedContainers: inout Set<String>,
        cancelFlag: AdScanCancellationFlag
    ) -> AppAdCacheEntry? {
        let url = URL(fileURLWithPath: rawPath)
        let normPath = CSStoreEngine.normalizeVarPath(url.path)
        if deniedContainers.contains(normPath) { return nil }

        let knownID = CSStoreEngine.shared.bundleID(forContainerPath: normPath, allowDiscovery: false)
        if let knownID, !knownID.isEmpty, shouldIgnoreContainerID(knownID, isAppGroup: isAppGroup, selfBID: selfBID) {
            return nil
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

        let resolvedID: String?
        if let knownID, !knownID.isEmpty {
            resolvedID = knownID
        } else {
            resolvedID = getBIDFromXattr(url)
        }

        guard let bid = resolvedID, !shouldIgnoreContainerID(bid, isAppGroup: isAppGroup, selfBID: selfBID) else {
            if resolvedID == nil {
                deniedContainers.insert(normPath)
            }
            return nil
        }

        var items: [AdCacheFolderItem] = []
        var seenCanonicalItems: Set<String> = []
        let stdContainerRoot = CSStoreEngine.normalizeVarPath(url.standardizedFileURL.path)
        let appWhitelisted = AdWhitelistStore.shared.isContainerWhitelisted(id: bid, isAppGroup: isAppGroup)

        // Pass A: Curated per-app known ad paths (Data/Application)
        if !isAppGroup, let specificSpecs = appSpecificAdPaths[bid] {
            for spec in specificSpecs {
                if cancelFlag.isCancelled { return nil }
                let candidateURL = url.appendingPathComponent(spec.relPath)
                let canon = CSStoreEngine.normalizeVarPath(candidateURL.standardizedFileURL.path)
                guard !seenCanonicalItems.contains(canon),
                      let item = inspectMatchedAdTarget(
                        targetURL: candidateURL,
                        containerRootStd: stdContainerRoot,
                        sdkZH: spec.zh,
                        sdkEN: spec.en,
                        isCustomRule: false,
                        isContainerWhitelisted: appWhitelisted,
                        cancelFlag: cancelFlag
                      ) else {
                    continue
                }
                seenCanonicalItems.insert(canon)
                items.append(item)
            }
        }

        // Pass B: Shallow POSIX scan across standard subdirectories (+ container root shallow scan for AppGroup)
        if isAppGroup {
            var rootSt = stat()
            if lstat(url.path, &rootSt) == 0 && (rootSt.st_mode & S_IFMT) == S_IFDIR {
                scanDirectoryShallow(
                    dirURL: url,
                    containerRootStd: stdContainerRoot,
                    currentDepth: 1,
                    maxDepth: 2,
                    skipStandardTopSubdirs: true,
                    isContainerWhitelisted: appWhitelisted,
                    seenCanonicalItems: &seenCanonicalItems,
                    results: &items,
                    cancelFlag: cancelFlag
                )
            }
        }

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
                skipStandardTopSubdirs: false,
                isContainerWhitelisted: appWhitelisted,
                seenCanonicalItems: &seenCanonicalItems,
                results: &items,
                cancelFlag: cancelFlag
            )
        }

        items.sort {
            if $0.isCustomRule != $1.isCustomRule { return $0.isCustomRule }
            if $0.needsActionToLock != $1.needsActionToLock { return $0.needsActionToLock }
            if $0.cachedBytes != $1.cachedBytes { return $0.cachedBytes > $1.cachedBytes }
            return $0.relativePath < $1.relativePath
        }

        let title = isAppGroup ? formatGroupDisplayTitle(groupID: bid) : AppContainerDirectoryHelper.displayName(for: bid)
        return AppAdCacheEntry(
            id: url.lastPathComponent,
            bundleID: bid,
            displayTitle: title,
            containerURL: url,
            isAppGroup: isAppGroup,
            isAppWhitelisted: appWhitelisted,
            items: items
        )
    }

    private static func mergeCustomRules(
        _ rules: [CustomAdWatchRule],
        into entries: inout [AppAdCacheEntry],
        cancelFlag: AdScanCancellationFlag
    ) {
        for rule in rules {
            if cancelFlag.isCancelled { return }
            let canonPath = AdCustomWatchStore.canonicalVarPath(rule.fullPath)
            guard let containerRoot = AdCustomWatchStore.containerRootPath(forCanonicalPath: canonPath) else {
                continue
            }
            let containerURL = URL(fileURLWithPath: containerRoot)
            let isGroup = containerRoot.hasPrefix("/var/mobile/Containers/Shared/AppGroup/")

            let wasContainerActive = wq.hasActiveAccess(path: containerRoot)
            guard wq.grantAccess(path: containerRoot, requireWrite: false).0 else { continue }
            defer {
                if !wasContainerActive {
                    wq.releaseAccess(path: containerRoot)
                }
            }

            let targetURL = URL(fileURLWithPath: canonPath)
            let noteZH = rule.note.isEmpty ? "自定义广告路径" : rule.note
            let noteEN = rule.note.isEmpty ? "Custom Ad Watch Rule" : rule.note

            let containerID = containerURL.lastPathComponent
            if let entryIdx = entries.firstIndex(where: { $0.id == containerID }) {
                if let existingIdx = entries[entryIdx].items.firstIndex(where: { $0.id == canonPath }) {
                    entries[entryIdx].items[existingIdx].isCustomRule = true
                    continue
                }
                if let item = inspectMatchedAdTarget(
                    targetURL: targetURL,
                    containerRootStd: containerRoot,
                    sdkZH: noteZH,
                    sdkEN: noteEN,
                    isCustomRule: true,
                    isContainerWhitelisted: entries[entryIdx].isAppWhitelisted,
                    cancelFlag: cancelFlag
                ) {
                    entries[entryIdx].items.insert(item, at: 0)
                }
            } else {
                let bid = CSStoreEngine.shared.bundleID(forContainerPath: containerRoot, allowDiscovery: false)
                    ?? getBIDFromXattr(containerURL)
                    ?? containerID
                let appWhitelisted = AdWhitelistStore.shared.isContainerWhitelisted(id: bid, isAppGroup: isGroup)
                if let item = inspectMatchedAdTarget(
                    targetURL: targetURL,
                    containerRootStd: containerRoot,
                    sdkZH: noteZH,
                    sdkEN: noteEN,
                    isCustomRule: true,
                    isContainerWhitelisted: appWhitelisted,
                    cancelFlag: cancelFlag
                ) {
                    let title = isGroup ? formatGroupDisplayTitle(groupID: bid) : AppContainerDirectoryHelper.displayName(for: bid)
                    entries.append(AppAdCacheEntry(
                        id: containerID,
                        bundleID: bid,
                        displayTitle: title,
                        containerURL: containerURL,
                        isAppGroup: isGroup,
                        isAppWhitelisted: appWhitelisted,
                        items: [item]
                    ))
                }
            }
        }
    }

    private static func scanDirectoryShallow(
        dirURL: URL,
        containerRootStd: String,
        currentDepth: Int,
        maxDepth: Int,
        skipStandardTopSubdirs: Bool,
        isContainerWhitelisted: Bool,
        seenCanonicalItems: inout Set<String>,
        results: inout [AdCacheFolderItem],
        cancelFlag: AdScanCancellationFlag
    ) {
        guard currentDepth <= maxDepth, !cancelFlag.isCancelled else { return }

        guard let dir = opendir(dirURL.path) else { return }
        defer { closedir(dir) }

        while let entryPtr = readdir(dir) {
            if cancelFlag.isCancelled { return }
            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0,
                  let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else {
                continue
            }
            let namePtr = UnsafeRawPointer(entryPtr).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if namePtr[0] == 0x2E { // skip ., .., and hidden dotfiles
                continue
            }
            let dType = Int32(entryPtr.pointee.d_type)
            guard dType == DT_DIR || dType == DT_REG || dType == DT_UNKNOWN else {
                continue
            }

            let childName = String(cString: namePtr)
            let lower = childName.lowercased()
            if skipStandardTopSubdirs && currentDepth == 1 &&
                ["library", "documents", "tmp", "systemdata"].contains(lower) {
                continue
            }
            if neverTouchOrDescend.contains(lower) {
                continue
            }

            let childURL = dirURL.appendingPathComponent(childName)
            var st = stat()
            guard lstat(childURL.path, &st) == 0 else { continue }
            let fmt = st.st_mode & S_IFMT

            let canon = CSStoreEngine.normalizeVarPath(childURL.standardizedFileURL.path)
            if seenCanonicalItems.contains(canon) { continue }

            if fmt == S_IFREG {
                if let fileMatch = exactAdConfigFiles[lower],
                   let item = inspectMatchedAdTarget(
                    targetURL: childURL,
                    containerRootStd: containerRootStd,
                    sdkZH: fileMatch.zh,
                    sdkEN: fileMatch.en,
                    isCustomRule: false,
                    isContainerWhitelisted: isContainerWhitelisted,
                    cancelFlag: cancelFlag
                   ) {
                    seenCanonicalItems.insert(canon)
                    results.append(item)
                }
                continue
            }

            guard fmt == S_IFDIR else { continue }

            if let match = classifyAdFolder(name: childName) {
                if let item = inspectMatchedAdTarget(
                    targetURL: childURL,
                    containerRootStd: containerRootStd,
                    sdkZH: match.zh,
                    sdkEN: match.en,
                    isCustomRule: false,
                    isContainerWhitelisted: isContainerWhitelisted,
                    cancelFlag: cancelFlag
                ) {
                    seenCanonicalItems.insert(canon)
                    results.append(item)
                }
                continue
            }

            if currentDepth < maxDepth {
                scanDirectoryShallow(
                    dirURL: childURL,
                    containerRootStd: containerRootStd,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth,
                    skipStandardTopSubdirs: false,
                    isContainerWhitelisted: isContainerWhitelisted,
                    seenCanonicalItems: &seenCanonicalItems,
                    results: &results,
                    cancelFlag: cancelFlag
                )
            }
        }
    }

    private static func inspectMatchedAdTarget(
        targetURL: URL,
        containerRootStd: String,
        sdkZH: String,
        sdkEN: String,
        isCustomRule: Bool,
        isContainerWhitelisted: Bool,
        cancelFlag: AdScanCancellationFlag
    ) -> AdCacheFolderItem? {
        var st = stat()
        guard lstat(targetURL.path, &st) == 0 else {
            return nil
        }
        let fmt = st.st_mode & S_IFMT
        guard fmt == S_IFDIR || fmt == S_IFREG else {
            return nil
        }

        let ownerName = (try? fm.attributesOfItem(atPath: targetURL.path)[.ownerAccountName] as? String) ?? ""
        guard ownerName == "mobile",
              canSafelyModifyPermissions(url: targetURL, owner: ownerName) else {
            return nil
        }

        let isDir = (fmt == S_IFDIR)
        let mode = Int(st.st_mode) & 0o777
        let targetStd = CSStoreEngine.normalizeVarPath(targetURL.standardizedFileURL.path)
        let prefix = containerRootStd + "/"
        let relPath = targetStd.hasPrefix(prefix) ? String(targetStd.dropFirst(prefix.count)) : targetURL.lastPathComponent
        let pathWhitelisted = AdWhitelistStore.shared.isPathWhitelisted(targetStd)

        let sizeBytes: Int64
        let hasSentinel: Bool
        if isDir {
            sizeBytes = fastAdFolderSize(atPath: targetURL.path, maxDepth: 6, cancelFlag: cancelFlag)
            var sSt = stat()
            let sentinelPath = (targetURL.path as NSString).appendingPathComponent(sentinelFileName)
            hasSentinel = (lstat(sentinelPath, &sSt) == 0) && ((sSt.st_mode & S_IFMT) == S_IFREG)
        } else {
            sizeBytes = max(0, Int64(st.st_size))
            hasSentinel = false
        }

        return AdCacheFolderItem(
            id: targetStd,
            fullPath: targetURL.path,
            relativePath: relPath,
            sdkNameZH: sdkZH,
            sdkNameEN: sdkEN,
            isDirectory: isDir,
            isCustomRule: isCustomRule,
            isContainerWhitelisted: isContainerWhitelisted,
            isPathWhitelisted: pathWhitelisted,
            cachedBytes: sizeBytes,
            posixMode: mode,
            hasSentinelLock: hasSentinel
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

    // MARK: - Anti-Recreate Lock (0555 + 0444 Sentinel / 0444 File) & Unlock

    private static func setAdTargetLocked(
        item: AdCacheFolderItem,
        containerURL: URL,
        locked: Bool
    ) -> (ok: Bool, mode: Int, bytes: Int64, hasSentinel: Bool, error: String?) {
        let targetURL = item.url
        let targetPath = targetURL.path

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
            return (false, item.posixMode, item.cachedBytes, item.hasSentinelLock,
                    isEn ? "Sandbox grant failed: \(tGrant.2)" : "沙盒写权限授权失败：\(tGrant.2)")
        }

        var st = stat()
        guard lstat(targetPath, &st) == 0 else {
            return (false, item.posixMode, item.cachedBytes, item.hasSentinelLock,
                    isEn ? "Target no longer exists." : "目标目录或文件已不存在。")
        }
        let fmt = st.st_mode & S_IFMT
        guard fmt == S_IFDIR || fmt == S_IFREG else {
            return (false, item.posixMode, item.cachedBytes, item.hasSentinelLock,
                    isEn ? "Unsupported file type (symlinks blocked)." : "不支持的条目类型（已拦截符号链接）。")
        }
        let isDir = (fmt == S_IFDIR)

        let ownerName = (try? fm.attributesOfItem(atPath: targetPath)[.ownerAccountName] as? String) ?? ""
        guard canSafelyModifyPermissions(url: targetURL, owner: ownerName) else {
            return (false, item.posixMode, item.cachedBytes, item.hasSentinelLock,
                    isEn ? "Blocked by system container safety policy." : "已被系统安全策略拦截，禁止修改该路径。")
        }

        if isDir {
            return applyDirectorySentinelLock(targetPath: targetPath, locked: locked, fallbackItem: item)
        } else {
            return applySingleFileReadOnlyLock(targetURL: targetURL, locked: locked, fallbackItem: item)
        }
    }

    nonisolated private static func applyDirectorySentinelLock(
        targetPath: String,
        locked: Bool,
        fallbackItem: AdCacheFolderItem
    ) -> (ok: Bool, mode: Int, bytes: Int64, hasSentinel: Bool, error: String?) {
        let sentinelPath = (targetPath as NSString).appendingPathComponent(sentinelFileName)

        if locked {
            guard Darwin.chmod(targetPath, 0o755) == 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, fallbackItem.hasSentinelLock,
                        LocalizationManager.isEnglish ? "chmod 0755 failed: \(err)" : "准备清理目录权限失败：\(err)")
            }
            purgeDirectoryContentsSafely(atPath: targetPath)

            // Create 0-byte 0444 sentinel file inside directory so parent-level rmdir/removeItem fails with ENOTEMPTY/EACCES
            let fd = Darwin.open(sentinelPath, O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW, mode_t(0o644))
            var sentinelCreated = false
            if fd >= 0 {
                Darwin.close(fd)
                _ = Darwin.chmod(sentinelPath, 0o444)
                var sSt = stat()
                sentinelCreated = (lstat(sentinelPath, &sSt) == 0) && ((sSt.st_mode & S_IFMT) == S_IFREG)
            }

            guard Darwin.chmod(targetPath, 0o555) == 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, sentinelCreated,
                        LocalizationManager.isEnglish ? "chmod 0555 failed: \(err)" : "锁定 0555 失败：\(err)")
            }

            var verifySt = stat()
            guard lstat(targetPath, &verifySt) == 0 else {
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, sentinelCreated,
                        LocalizationManager.isEnglish ? "Failed to verify permissions via lstat." : "lstat 校验权限失败。")
            }
            let verifiedMode = Int(verifySt.st_mode) & 0o777
            guard verifiedMode == 0o555 else {
                return (false, verifiedMode, fallbackItem.cachedBytes, sentinelCreated,
                        LocalizationManager.isEnglish
                            ? "Mode mismatch: got \(String(format: "%04o", verifiedMode))."
                            : "权限校验不一致：实际为 \(String(format: "%04o", verifiedMode))。")
            }
            let remaining = fastAdFolderSize(atPath: targetPath, maxDepth: 6, cancelFlag: nil)
            return (true, verifiedMode, remaining, sentinelCreated, nil)
        } else {
            guard Darwin.chmod(targetPath, 0o755) == 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, fallbackItem.hasSentinelLock,
                        LocalizationManager.isEnglish ? "chmod 0755 failed: \(err)" : "恢复读写 0755 失败：\(err)")
            }

            var sSt = stat()
            if lstat(sentinelPath, &sSt) == 0 && (sSt.st_mode & S_IFMT) == S_IFREG {
                _ = Darwin.chmod(sentinelPath, 0o644)
                _ = Darwin.unlink(sentinelPath)
            }

            var verifySt = stat()
            guard lstat(targetPath, &verifySt) == 0 else {
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, false,
                        LocalizationManager.isEnglish ? "Failed to verify permissions via lstat." : "lstat 校验权限失败。")
            }
            let verifiedMode = Int(verifySt.st_mode) & 0o777
            let remaining = fastAdFolderSize(atPath: targetPath, maxDepth: 6, cancelFlag: nil)
            return (true, verifiedMode, remaining, false, nil)
        }
    }

    nonisolated private static func applySingleFileReadOnlyLock(
        targetURL: URL,
        locked: Bool,
        fallbackItem: AdCacheFolderItem
    ) -> (ok: Bool, mode: Int, bytes: Int64, hasSentinel: Bool, error: String?) {
        let targetPath = targetURL.path

        if locked {
            guard Darwin.chmod(targetPath, 0o644) == 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, false,
                        LocalizationManager.isEnglish ? "chmod 0644 failed: \(err)" : "准备修改文件权限失败：\(err)")
            }

            // Overwrite in-place with minimal valid empty payload (0444 afterward)
            let emptyData = emptyPayloadData(for: targetURL)
            let fd = Darwin.open(targetPath, O_WRONLY | O_TRUNC | O_NOFOLLOW)
            guard fd >= 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, false,
                        LocalizationManager.isEnglish ? "Failed to truncate config file: \(err)" : "打开配置文件清空失败：\(err)")
            }
            if !emptyData.isEmpty {
                _ = emptyData.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return 0 }
                    return Darwin.write(fd, base, emptyData.count)
                }
            }
            _ = Darwin.fcntl(fd, F_FULLFSYNC)
            Darwin.close(fd)

            guard Darwin.chmod(targetPath, 0o444) == 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, false,
                        LocalizationManager.isEnglish ? "chmod 0444 failed: \(err)" : "锁定 0444 失败：\(err)")
            }

            var verifySt = stat()
            guard lstat(targetPath, &verifySt) == 0 else {
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, false,
                        LocalizationManager.isEnglish ? "Failed to verify permissions via lstat." : "lstat 校验权限失败。")
            }
            let verifiedMode = Int(verifySt.st_mode) & 0o777
            return (verifiedMode == 0o444, verifiedMode, max(0, Int64(verifySt.st_size)), false,
                    verifiedMode == 0o444 ? nil : (LocalizationManager.isEnglish ? "Mode verification mismatch." : "权限校验不一致。"))
        } else {
            guard Darwin.chmod(targetPath, 0o644) == 0 else {
                let err = String(cString: strerror(errno))
                return (false, fallbackItem.posixMode, fallbackItem.cachedBytes, false,
                        LocalizationManager.isEnglish ? "chmod 0644 failed: \(err)" : "恢复 0644 失败：\(err)")
            }
            var verifySt = stat()
            let verifiedMode = (lstat(targetPath, &verifySt) == 0) ? (Int(verifySt.st_mode) & 0o777) : 0o644
            let fileBytes = (lstat(targetPath, &verifySt) == 0) ? max(0, Int64(verifySt.st_size)) : fallbackItem.cachedBytes
            return (true, verifiedMode, fileBytes, false, nil)
        }
    }

    nonisolated private static func emptyPayloadData(for url: URL) -> Data {
        switch url.pathExtension.lowercased() {
        case "json":
            return Data("{}".utf8)
        case "plist":
            if let data = try? PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0) {
                return data
            }
            return Data()
        default:
            return Data()
        }
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
                if name == sentinelFileName {
                    _ = Darwin.chmod(childPath, 0o644)
                }
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
    let onPreview: (() -> Void)?
    let onToggleLock: () -> Void
    let onTogglePathWhitelist: (() -> Void)?
    let onRemoveCustom: (() -> Void)?

    private static var isEn: Bool { LocalizationManager.isEnglish }

    private var statusBadgeText: String {
        if item.isDirectory {
            if item.isLockedReadOnly {
                if item.hasSentinelLock {
                    return Self.isEn
                        ? String(format: "%04o Sentinel", item.posixMode)
                        : String(format: "%04o 防重建已锁", item.posixMode)
                }
                return Self.isEn
                    ? String(format: "%04o Weak Lock", item.posixMode)
                    : String(format: "%04o 只读(可加固)", item.posixMode)
            }
            return Self.isEn
                ? String(format: "%04o Writable", item.posixMode)
                : String(format: "%04o 可写", item.posixMode)
        } else {
            return item.isLockedReadOnly
                ? (Self.isEn ? String(format: "%04o File Locked", item.posixMode) : String(format: "%04o 文件已锁", item.posixMode))
                : (Self.isEn ? String(format: "%04o Writable", item.posixMode) : String(format: "%04o 可写", item.posixMode))
        }
    }

    private var statusBadgeColor: Color {
        if item.isWhitelisted && !item.isLockedReadOnly { return .teal }
        if !item.needsActionToLock { return .green }
        if item.isLockedReadOnly && item.isDirectory && !item.hasSentinelLock { return .yellow }
        return .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                    .font(.caption2)
                    .foregroundStyle(item.isDirectory ? Color.accentColor : .blue)

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
                if item.isCustomRule {
                    Text(Self.isEn ? "Custom" : "自定义")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                        .fixedSize()
                }

                if item.isWhitelisted {
                    Text(Self.isEn ? "Whitelisted" : "白名单")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.15), in: Capsule())
                        .foregroundStyle(.teal)
                        .fixedSize()
                }

                Text(Self.isEn ? item.sdkNameEN : item.sdkNameZH)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(statusBadgeText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusBadgeColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(statusBadgeColor == .yellow ? .orange : statusBadgeColor)
                    .fixedSize()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    leftActionButtons
                    Spacer(minLength: 4)
                    lockActionButton
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        leftActionButtons
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        lockActionButton
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var leftActionButtons: some View {
        Button(action: onLocate) {
            HStack(spacing: 3) {
                Image(systemName: "scope")
                Text(Self.isEn ? "Locate" : "定位")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        if let onPreview {
            Button(action: onPreview) {
                HStack(spacing: 3) {
                    Image(systemName: "eye")
                    Text(Self.isEn ? "Preview" : "预览")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }

        if let onTogglePathWhitelist {
            Button(action: onTogglePathWhitelist) {
                HStack(spacing: 3) {
                    Image(systemName: item.isPathWhitelisted ? "shield.slash" : "checkmark.shield")
                    Text(item.isPathWhitelisted
                         ? (Self.isEn ? "Unignore" : "取消加白")
                         : (Self.isEn ? "Ignore" : "加白"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(item.isPathWhitelisted ? .teal : .secondary)
            .disabled(isBusy)
        }

        if let onRemoveCustom {
            Button(role: .destructive, action: onRemoveCustom) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var lockActionButton: some View {
        if !item.needsActionToLock {
            if item.isLockedReadOnly {
                Button(action: onToggleLock) {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.open.fill")
                        Text(Self.isEn
                             ? (item.isDirectory ? "Unlock 0755" : "Unlock 0644")
                             : "恢复读写")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(isBusy)
            } else {
                Text(Self.isEn ? "Skipped" : "自动跳过")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.12), in: Capsule())
            }
        } else {
            let isHardenOnly = item.isDirectory && item.isLockedReadOnly && !item.hasSentinelLock
            Button(action: onToggleLock) {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    Text(isHardenOnly
                         ? (Self.isEn ? "Harden" : "加固防重建")
                         : (Self.isEn
                            ? (item.isDirectory ? "Lock 0555" : "Lock 0444")
                            : "一键锁死"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
            .disabled(isBusy)
        }
    }
}
