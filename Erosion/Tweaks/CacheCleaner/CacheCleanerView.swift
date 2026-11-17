//
//  CacheCleanerView.swift
//  Erosion
//
//  Safe container-level cache & temporary file cleaner for reclaiming bloated iOS "System Data" storage.
//

import SwiftUI
import Darwin

struct ContainerCacheEntry: Identifiable, Hashable, Sendable {
    let id: String
    let bundleID: String
    let displayTitle: String
    let containerURL: URL
    var cachesBytes: Int64
    var tmpBytes: Int64
    var isSelected: Bool

    nonisolated var totalCleanableBytes: Int64 {
        cachesBytes + tmpBytes
    }
}

private final class ScanCancellationFlag: @unchecked Sendable {
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
        let value = cancelled
        lock.unlock()
        return value
    }
}

struct CacheCleanerView: View {
    @ObservedObject private var langMgr = LocalizationManager.shared
    @State private var isScanning = false
    @State private var isStopping = false
    @State private var isCleaning = false
    @State private var entries: [ContainerCacheEntry] = []
    @State private var inspectEntry: ContainerCacheEntry?
    @State private var searchText = ""
    @State private var includeSystemContainers = false
    @State private var scanCompletedCount = 0
    @State private var scanTotalCount = 0
    @State private var activeScanToken: ScanCancellationFlag?
    @AppStorage("totalFreedBytesHistory") private var totalFreedBytesHistory: Int = 0

    nonisolated private static var isEn: Bool { LocalizationManager.isEnglish }
    nonisolated private static let autoSelectThresholdBytes: Int64 = 1024 * 1024

    nonisolated private static let protectedBundleIDs: Set<String> = [
        "com.jbdotparty.Erosion",
        "com.apple.PosterBoard",
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone"
    ]

    private var scanProgressText: String {
        if scanTotalCount > 0 {
            if isStopping {
                return LocalizationManager.isEnglish
                    ? "Stopping (\(scanCompletedCount) / \(scanTotalCount))..."
                    : "正在停止 (\(scanCompletedCount) / \(scanTotalCount))..."
            }
            return LocalizationManager.isEnglish
                ? "Scanning \(scanCompletedCount) / \(scanTotalCount)"
                : "已扫描 \(scanCompletedCount) / \(scanTotalCount)"
        }
        return L("正在扫描各应用容器缓存体积...")
    }

    private var filteredEntries: [ContainerCacheEntry] {
        let base = includeSystemContainers
            ? entries
            : entries.filter { !$0.bundleID.hasPrefix("com.apple.") || $0.bundleID == "com.apple.mobilesafari" }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var totalReclaimableBytes: Int64 {
        filteredEntries.reduce(0) { $0 + $1.totalCleanableBytes }
    }

    private var selectedEntriesCount: Int {
        filteredEntries.filter(\.isSelected).count
    }

    private var selectedReclaimableBytes: Int64 {
        filteredEntries.filter(\.isSelected).reduce(0) { $0 + $1.totalCleanableBytes }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前可安全释放缓存")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(AppContainerDirectoryHelper.formatBytes(totalReclaimableBytes))
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(totalReclaimableBytes > 0 ? Color.accentColor : Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if totalFreedBytesHistory > 0 {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("累计已释放")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(AppContainerDirectoryHelper.formatBytes(Int64(totalFreedBytesHistory)))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            .layoutPriority(1)
                        }
                    }

                    Divider()

                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Button {
                                scanCaches()
                            } label: {
                                Label("重新扫描", systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .buttonStyle(.borderless)
                            .disabled(isScanning || isCleaning)

                            Spacer(minLength: 8)

                            Text(Self.isEn
                                 ? "\(selectedEntriesCount) selected"
                                 : "已选 \(selectedEntriesCount) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Button(role: .destructive) {
                            confirmCleanSelected()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                Text(Self.isEn
                                     ? "Clean Selected (\(AppContainerDirectoryHelper.formatBytes(selectedReclaimableBytes)))"
                                     : "一键清理已选 (\(AppContainerDirectoryHelper.formatBytes(selectedReclaimableBytes)))")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                        .disabled(isScanning || isCleaning || selectedEntriesCount == 0 || selectedReclaimableBytes <= 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

                PlainToggle(
                    L("显示系统组件容器 (com.apple.*)"),
                    subtitle: L("默认包含第三方应用及 Safari 浏览器缓存"),
                    isOn: $includeSystemContainers
                )
            } header: {
                HeaderLabel(L("空间释放概览"), symbol: "chart.pie.fill")
            } footer: {
                Text("本工具仅清理各容器下的 Library/Caches、tmp 与 WebKit 网页缓存，保留目录本身与权限，100% 不影响应用聊天记录、账号登录态与用户文档。")
            }

            Section {
                if isScanning || isCleaning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isCleaning ? L("正在安全清理所选容器缓存...") : scanProgressText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if isScanning {
                            Spacer()
                            Button(role: .destructive) {
                                stopScan()
                            } label: {
                                Label(
                                    LocalizationManager.isEnglish ? "Stop" : "停止",
                                    systemImage: "stop.circle.fill"
                                )
                                .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                            .disabled(isStopping)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if filteredEntries.isEmpty {
                    if !isScanning && !isCleaning {
                        Text("未发现可清理的应用缓存")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(filteredEntries) { entry in
                        HStack(spacing: 12) {
                            Button {
                                toggleSelection(for: entry.id)
                            } label: {
                                Image(systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(entry.isSelected ? Color.accentColor : Color.secondary)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            .disabled(isScanning || isCleaning)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.displayTitle)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text("Caches: \(AppContainerDirectoryHelper.formatBytes(entry.cachesBytes)) · tmp: \(AppContainerDirectoryHelper.formatBytes(entry.tmpBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .trailing, spacing: 6) {
                                Text(AppContainerDirectoryHelper.formatBytes(entry.totalCleanableBytes))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(entry.totalCleanableBytes > 50 * 1024 * 1024 ? Color.orange : Color.primary)

                                HStack(spacing: 10) {
                                    Button {
                                        inspectEntry = entry
                                    } label: {
                                        Text("查看")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isScanning || isCleaning)

                                    Button(role: .destructive) {
                                        cleanSingleEntry(entry)
                                    } label: {
                                        Text("清理")
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isScanning || isCleaning)
                                }
                            }
                            .layoutPriority(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    HeaderLabel(L("容器缓存体积排行 (\(filteredEntries.count))"), symbol: "trash.slash.fill")
                    Spacer()
                    Menu {
                        Button {
                            selectAllVisible()
                        } label: {
                            Label(
                                LocalizationManager.isEnglish ? "Select All" : "全选当前",
                                systemImage: "checkmark.circle"
                            )
                        }
                        .disabled(filteredEntries.isEmpty)

                        Button {
                            invertVisibleSelection()
                        } label: {
                            Label(
                                LocalizationManager.isEnglish ? "Invert Selection" : "反选当前",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .disabled(filteredEntries.isEmpty)

                        Divider()

                        Button {
                            clearAllSelections()
                        } label: {
                            Label(
                                LocalizationManager.isEnglish ? "Select None" : "清空已选",
                                systemImage: "xmark.circle"
                            )
                        }
                        .disabled(entries.isEmpty)
                    } label: {
                        HStack(spacing: 4) {
                            Text(LocalizationManager.isEnglish ? "Select" : "选择")
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                    }
                    .disabled(isScanning || isCleaning || entries.isEmpty)
                }
            }
        }
        .navigationTitle("容器缓存清理")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索应用名称或 Bundle ID")
        .navigationDestination(item: $inspectEntry) { entry in
            ContainerSubdirBrowserView(containerURL: entry.containerURL, relativeSubpath: "Library/Caches")
        }
        .onChange(of: includeSystemContainers) {
            if includeSystemContainers && !entries.contains(where: { $0.bundleID.hasPrefix("com.apple.") && $0.bundleID != "com.apple.mobilesafari" }) && !isScanning && !isCleaning {
                scanCaches()
            }
        }
        .onAppear {
            if entries.isEmpty && !isScanning && !isCleaning {
                scanCaches()
            }
        }
    }

    private func confirmCleanSelected() {
        guard !isScanning && !isCleaning else { return }
        let targets = filteredEntries.filter(\.isSelected)
        guard !targets.isEmpty else { return }
        let bytes = targets.reduce(Int64(0)) { $0 + $1.totalCleanableBytes }
        guard bytes > 0 else { return }
        Alertinator.shared.alert(
            title: L("确认清理所选应用缓存吗？"),
            body: L("将清理 \(targets.count) 个应用容器内的 Library/Caches 与 tmp 临时碎片（预计释放 \(AppContainerDirectoryHelper.formatBytes(bytes))）。\n\n安全承诺：绝不触碰 Documents、聊天记录数据库或登录配置。"),
            actionLabel: L("立即清理"),
            action: {
                cleanEntries(targets)
            }
        )
    }

    private func toggleSelection(for id: String) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].isSelected.toggle()
        }
    }

    private func selectAllVisible() {
        let visibleIDs = Set(filteredEntries.map(\.id))
        for idx in entries.indices where visibleIDs.contains(entries[idx].id) {
            entries[idx].isSelected = true
        }
    }

    private func invertVisibleSelection() {
        let visibleIDs = Set(filteredEntries.map(\.id))
        for idx in entries.indices where visibleIDs.contains(entries[idx].id) {
            entries[idx].isSelected.toggle()
        }
    }

    private func clearAllSelections() {
        for idx in entries.indices {
            entries[idx].isSelected = false
        }
    }

    private func stopScan() {
        guard isScanning, !isStopping else { return }
        isStopping = true
        activeScanToken?.cancel()
    }

    private func scanCaches() {
        guard !isScanning && !isCleaning else { return }
        let wantSystem = includeSystemContainers
        let token = ScanCancellationFlag()
        activeScanToken = token
        isScanning = true
        isStopping = false
        scanCompletedCount = 0
        scanTotalCount = 0
        entries = []

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
            var result: [ContainerCacheEntry] = []
            let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
            var completedCount = 0
            var lastUIUpdate = CFAbsoluteTimeGetCurrent()

            for rawPath in uniquePaths {
                if token.isCancelled { break }
                let entry = Self.scanSingleContainer(
                    rawPath: rawPath,
                    wantSystem: wantSystem,
                    selfBID: selfBID,
                    deniedContainers: &deniedContainers,
                    cancelFlag: token
                )
                if token.isCancelled { break }
                completedCount += 1
                if let entry {
                    result.append(entry)
                }

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastUIUpdate >= 0.08 || completedCount == totalCount {
                    lastUIUpdate = now
                    let progressSnapshot = completedCount
                    let sortedSnapshot = Self.sortedEntries(result)
                    DispatchQueue.main.async {
                        guard self.activeScanToken?.id == token.id else { return }
                        self.scanCompletedCount = progressSnapshot
                        self.entries = sortedSnapshot
                    }
                }
            }

            let finalEntries = Self.finalizeEntries(result)
            let finalCompleted = completedCount

            DispatchQueue.main.async {
                guard self.activeScanToken?.id == token.id else { return }
                self.entries = finalEntries
                self.scanCompletedCount = finalCompleted
                self.isScanning = false
                self.isStopping = false
                self.activeScanToken = nil
            }
        }
    }

    nonisolated private static func sortedEntries(_ items: [ContainerCacheEntry]) -> [ContainerCacheEntry] {
        items.sorted {
            if $0.totalCleanableBytes != $1.totalCleanableBytes {
                return $0.totalCleanableBytes > $1.totalCleanableBytes
            }
            return $0.bundleID < $1.bundleID
        }
    }

    nonisolated private static func finalizeEntries(_ items: [ContainerCacheEntry]) -> [ContainerCacheEntry] {
        sortedEntries(items).map { item in
            var copy = item
            copy.isSelected = shouldAutoSelect(bundleID: item.bundleID, totalBytes: item.totalCleanableBytes)
            return copy
        }
    }

    nonisolated private static func shouldAutoSelect(bundleID: String, totalBytes: Int64) -> Bool {
        !bundleID.hasPrefix("com.apple.") && totalBytes >= autoSelectThresholdBytes
    }

    private static func scanSingleContainer(
        rawPath: String,
        wantSystem: Bool,
        selfBID: String,
        deniedContainers: inout Set<String>,
        cancelFlag: ScanCancellationFlag
    ) -> ContainerCacheEntry? {
        let url = URL(fileURLWithPath: rawPath)
        let normPath = CSStoreEngine.normalizeVarPath(url.path)
        if deniedContainers.contains(normPath) {
            return nil
        }

        // Fast pre-filter via CSStore2 without touching containermanagerd IPC!
        let knownBID = CSStoreEngine.shared.bundleID(forContainerPath: normPath, allowDiscovery: false)
        if let knownBID, !knownBID.isEmpty {
            if knownBID == selfBID || protectedBundleIDs.contains(knownBID) {
                return nil
            }
            if !wantSystem && knownBID.hasPrefix("com.apple.") && knownBID != "com.apple.mobilesafari" {
                return nil
            }
        }

        // Grant read access once per container and cache failures in deniedContainers
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
              !protectedBundleIDs.contains(bid) else {
            if resolvedBID == nil {
                deniedContainers.insert(normPath)
            }
            return nil
        }

        if !wantSystem && bid.hasPrefix("com.apple.") && bid != "com.apple.mobilesafari" {
            return nil
        }

        let cachesPath = url.appendingPathComponent("Library/Caches").path
        let tmpPath = url.appendingPathComponent("tmp").path

        let cBytes = fastDirectorySize(atPath: cachesPath, maxDepth: 7, cancelFlag: cancelFlag)
        if cancelFlag.isCancelled { return nil }
        let tBytes = fastDirectorySize(atPath: tmpPath, maxDepth: 6, cancelFlag: cancelFlag)
        if cancelFlag.isCancelled { return nil }

        let total = cBytes + tBytes
        guard total > 4096 else { return nil }

        return ContainerCacheEntry(
            id: url.lastPathComponent,
            bundleID: bid,
            displayTitle: AppContainerDirectoryHelper.displayName(for: bid),
            containerURL: url,
            cachesBytes: cBytes,
            tmpBytes: tBytes,
            isSelected: shouldAutoSelect(bundleID: bid, totalBytes: total)
        )
    }

    nonisolated private static func fastDirectorySize(
        atPath path: String,
        maxDepth: Int,
        cancelFlag: ScanCancellationFlag? = nil
    ) -> Int64 {
        var rootSt = stat()
        guard lstat(path, &rootSt) == 0, (rootSt.st_mode & S_IFMT) == S_IFDIR else {
            return 0
        }
        var pathBuf = Array(path.utf8CString)
        var len = pathBuf.count - 1
        while len > 1 && pathBuf[len - 1] == 0x2F { // '/'
            len -= 1
        }
        pathBuf[len] = 0
        pathBuf.reserveCapacity(max(Int(PATH_MAX), len + 256))
        return fastDirectorySizeRecursive(
            pathBuf: &pathBuf,
            pathLen: len,
            maxDepth: maxDepth,
            currentDepth: 0,
            cancelFlag: cancelFlag
        )
    }

    nonisolated private static func fastDirectorySizeRecursive(
        pathBuf: inout [CChar],
        pathLen: Int,
        maxDepth: Int,
        currentDepth: Int,
        cancelFlag: ScanCancellationFlag?
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
        var seenEntries = 0

        while let entryPtr = readdir(dir) {
            seenEntries += 1
            if (seenEntries & 0xFF) == 0, cancelFlag?.isCancelled == true {
                break
            }

            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0, nameLen < Int(MAXPATHLEN) else { continue }
            let namePtr = UnsafeRawPointer(entryPtr).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)

            if namePtr[0] == 0x2E { // '.'
                if nameLen == 1 { continue }
                if nameLen == 2 && namePtr[1] == 0x2E { continue }
            }

            let dType = Int32(entryPtr.pointee.d_type)
            if dType == DT_LNK || dType == DT_FIFO || dType == DT_SOCK || dType == DT_CHR || dType == DT_BLK {
                continue
            }

            if dType == DT_DIR {
                if currentDepth < maxDepth {
                    total += descendSubdirectory(
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
            if mode == S_IFREG {
                if st.st_size > 0 {
                    total += Int64(st.st_size)
                }
            } else if mode == S_IFDIR && currentDepth < maxDepth {
                total += descendSubdirectory(
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

    nonisolated private static func descendSubdirectory(
        namePtr: UnsafePointer<CChar>,
        nameLen: Int,
        pathBuf: inout [CChar],
        pathLen: Int,
        maxDepth: Int,
        currentDepth: Int,
        cancelFlag: ScanCancellationFlag?
    ) -> Int64 {
        let sepLen = (pathLen == 1 && pathBuf[0] == 0x2F) ? 0 : 1
        let subLen = pathLen + sepLen + nameLen
        let needed = subLen + 1
        if pathBuf.count < needed {
            pathBuf.append(contentsOf: repeatElement(0, count: needed - pathBuf.count))
        }
        if sepLen == 1 {
            pathBuf[pathLen] = 0x2F // '/'
        }
        pathBuf.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            memcpy(base.advanced(by: pathLen + sepLen), namePtr, nameLen)
            base[subLen] = 0
        }
        let bytes = fastDirectorySizeRecursive(
            pathBuf: &pathBuf,
            pathLen: subLen,
            maxDepth: maxDepth,
            currentDepth: currentDepth + 1,
            cancelFlag: cancelFlag
        )
        pathBuf[pathLen] = 0
        return bytes
    }

    private func cleanSingleEntry(_ entry: ContainerCacheEntry) {
        guard !isScanning && !isCleaning else { return }
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.purgeCacheContents(for: entry)
            DispatchQueue.main.async {
                if outcome.authorized {
                    if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                        if outcome.remainingCaches + outcome.remainingTmp <= 4096 {
                            entries.remove(at: idx)
                        } else {
                            entries[idx].cachesBytes = outcome.remainingCaches
                            entries[idx].tmpBytes = outcome.remainingTmp
                        }
                    }
                    totalFreedBytesHistory += Int(max(outcome.freed, 0))
                    isCleaning = false
                    Haptic.shared.play(.soft)
                    ErosionManager.shared.refreshFiles.toggle()
                    Alertinator.shared.alert(
                        title: L("清理完成！"),
                        body: L("已安全清理「\(entry.displayTitle)」缓存，释放空间 \(AppContainerDirectoryHelper.formatBytes(outcome.freed))。")
                    )
                } else {
                    isCleaning = false
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(
                        title: Self.isEn ? "Clean Failed" : "清理失败",
                        body: Self.isEn
                            ? "Could not obtain write access to \"\(entry.displayTitle)\" container."
                            : "未能获取「\(entry.displayTitle)」容器写入权限，清理未执行。"
                    )
                }
            }
        }
    }

    private func cleanEntries(_ targets: [ContainerCacheEntry]) {
        guard !isScanning && !isCleaning else { return }
        guard !targets.isEmpty else { return }
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var totalFreed: Int64 = 0
            var authorizedCount = 0
            var unauthorizedCount = 0
            var outcomes: [String: (remainingCaches: Int64, remainingTmp: Int64)] = [:]

            for target in targets {
                let res = Self.purgeCacheContents(for: target)
                if res.authorized {
                    authorizedCount += 1
                    totalFreed += res.freed
                    outcomes[target.id] = (res.remainingCaches, res.remainingTmp)
                } else {
                    unauthorizedCount += 1
                }
            }

            DispatchQueue.main.async {
                if !outcomes.isEmpty {
                    entries = entries.compactMap { entry in
                        guard let out = outcomes[entry.id] else {
                            return entry
                        }
                        if out.remainingCaches + out.remainingTmp <= 4096 {
                            return nil
                        }
                        var updated = entry
                        updated.cachesBytes = out.remainingCaches
                        updated.tmpBytes = out.remainingTmp
                        return updated
                    }
                }
                totalFreedBytesHistory += Int(max(totalFreed, 0))
                isCleaning = false
                if authorizedCount > 0 {
                    Haptic.shared.play(.soft)
                    ErosionManager.shared.refreshFiles.toggle()
                } else {
                    Haptic.shared.notify(.error)
                }

                if unauthorizedCount == 0 {
                    Alertinator.shared.alert(
                        title: L("批量清理完成！"),
                        body: L("已成功清理 \(authorizedCount) 个应用的冗余缓存与临时文件，共释放 \(AppContainerDirectoryHelper.formatBytes(totalFreed)) 存储空间！")
                    )
                } else {
                    Alertinator.shared.alert(
                        title: Self.isEn ? "Completed with Errors" : "部分容器清理受限",
                        body: Self.isEn
                            ? "Cleaned \(authorizedCount) containers (freed \(AppContainerDirectoryHelper.formatBytes(totalFreed))); \(unauthorizedCount) containers could not obtain write access."
                            : "已清理 \(authorizedCount) 个容器（释放 \(AppContainerDirectoryHelper.formatBytes(totalFreed))），另有 \(unauthorizedCount) 个容器未能获取写入权限。"
                    )
                }
            }
        }
    }

    nonisolated private static func isAdSentinelLockedDir(atPath path: String) -> Bool {
        let sentinel = (path as NSString).appendingPathComponent(".erosion_adlock")
        var st = stat()
        return lstat(sentinel, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func purgeCacheContents(for entry: ContainerCacheEntry) -> (authorized: Bool, freed: Int64, remainingCaches: Int64, remainingTmp: Int64) {
        let wasActive = wq.hasActiveAccess(path: entry.containerURL.path)
        let rootGrant = wq.grantAccess(path: entry.containerURL.path, requireWrite: true)
        guard rootGrant.0 || rootGrant.1 >= 0 else {
            return (false, 0, entry.cachesBytes, entry.tmpBytes)
        }
        defer {
            if !wasActive && rootGrant.1 >= 0 {
                wq.releaseAccess(path: entry.containerURL.path)
            }
        }

        let cacheDir = entry.containerURL.appendingPathComponent("Library/Caches")
        let tmpDir = entry.containerURL.appendingPathComponent("tmp")
        let webkitCacheDir = entry.containerURL.appendingPathComponent("Library/WebKit/WebsiteData/CacheStorage")
        let targets: [(url: URL, depth: Int)] = [(cacheDir, 7), (tmpDir, 6), (webkitCacheDir, 7)]

        var totalFreed: Int64 = 0
        for (dir, depth) in targets {
            var dirSt = stat()
            guard lstat(dir.path, &dirSt) == 0, (dirSt.st_mode & S_IFMT) == S_IFDIR else { continue }
            let subWasActive = wq.hasActiveAccess(path: dir.path)
            let subGrant = wq.grantAccess(path: dir.path, requireWrite: true)
            defer {
                if !subWasActive && subGrant.1 >= 0 {
                    wq.releaseAccess(path: dir.path)
                }
            }
            let before = fastDirectorySize(atPath: dir.path, maxDepth: depth)
            guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for child in children {
                guard !child.contains("/"), child != ".", child != "..", child != ".erosion_adlock" else { continue }
                if entry.bundleID == "com.apple.mobilephone" && child == "TelephonyUI-10" {
                    continue
                }
                let childURL = dir.appendingPathComponent(child)
                var childSt = stat()
                guard lstat(childURL.path, &childSt) == 0 else { continue }
                let mode = childSt.st_mode & S_IFMT
                if mode == S_IFDIR && isAdSentinelLockedDir(atPath: childURL.path) {
                    continue
                }
                // Only remove regular files and regular subdirectories; skip sockets/FIFOs/symlinks
                if mode == S_IFREG || mode == S_IFDIR {
                    try? fm.removeItem(at: childURL)
                }
            }
            let after = fastDirectorySize(atPath: dir.path, maxDepth: depth)
            totalFreed += max(0, before - after)
        }
        let remainingCaches = fastDirectorySize(atPath: cacheDir.path, maxDepth: 7)
        let remainingTmp = fastDirectorySize(atPath: tmpDir.path, maxDepth: 6)
        return (true, totalFreed, remainingCaches, remainingTmp)
    }
}
