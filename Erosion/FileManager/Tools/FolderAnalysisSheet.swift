//
//  FolderAnalysisSheet.swift
//  Erosion
//
//  Deep subfolder search (capped at 500 matches) and Top 100 largest files analyzer.
//

import SwiftUI
import Darwin
import UIKit

enum FolderAnalysisTab: Int, CaseIterable, Identifiable {
    case search = 0
    case topLargest = 1

    var id: Int { rawValue }
}

struct AnalyzedFileEntry: Identifiable, Hashable, Sendable {
    var id: String { fullPath }
    let name: String
    let fullPath: String
    let relativePath: String
    let size: Int64
    let isDirectory: Bool
    let isSymlink: Bool

    var url: URL { URL(fileURLWithPath: fullPath) }
    var parentURL: URL { url.deletingLastPathComponent() }
}

private struct InfoFileWrapper: Identifiable {
    let id = UUID()
    let item: FileItem
}

struct FolderAnalysisSheet: View {
    let rootURL: URL
    var onNavigateToFolder: ((URL) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: FolderAnalysisTab = .search

    // Deep search state
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchScannedCount = 0
    @State private var searchResults: [AnalyzedFileEntry] = []
    @State private var searchHitCap = false
    @State private var searchCompleted = false
    @State private var searchTask: Task<Void, Never>?

    // Top 100 largest state
    @State private var isScanningLargest = false
    @State private var largestScannedFiles = 0
    @State private var largestTotalBytes: Int64 = 0
    @State private var topLargestFiles: [AnalyzedFileEntry] = []
    @State private var largestCompleted = false
    @State private var largestTask: Task<Void, Never>?

    // Sheet presentation & sandbox token tracking
    @State private var infoWrapper: InfoFileWrapper?
    @State private var didGrantRootAccess = false
    @State private var accessError: String?

    private static let maxSearchMatches = 500
    private static let maxLargestFiles = 100

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(
                        LocalizationManager.isEnglish ? "Analysis Mode" : "分析模式",
                        selection: $selectedTab
                    ) {
                        Text(LocalizationManager.isEnglish ? "Deep Search" : "深度搜索")
                            .tag(FolderAnalysisTab.search)
                        Text(LocalizationManager.isEnglish ? "Top 100 Largest" : "最大 100 文件")
                            .tag(FolderAnalysisTab.topLargest)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(rootURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let accessError {
                    CompactAlert(
                        title: LocalizationManager.isEnglish ? "Directory Inaccessible" : "无法读取目录",
                        symbol: "lock.trianglebadge.exclamationmark",
                        text: accessError,
                        color: .orange
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } else if selectedTab == .search {
                    deepSearchSections
                } else {
                    topLargestSections
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LocalizationManager.isEnglish ? "Folder Analysis" : "目录深度分析")
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
                ensureRootAccess()
            }
            .onChange(of: selectedTab) { _, newTab in
                if newTab == .topLargest && !largestCompleted && !isScanningLargest && accessError == nil {
                    startLargestScan()
                }
            }
            .onDisappear {
                searchTask?.cancel()
                largestTask?.cancel()
                searchTask = nil
                largestTask = nil
                if didGrantRootAccess {
                    wq.releaseAccess(path: rootURL.path)
                    didGrantRootAccess = false
                }
            }
            .sheet(item: $infoWrapper) { wrapper in
                InfoViewer(wrapper.item)
            }
        }
    }

    // MARK: - Deep Search UI

    @ViewBuilder
    private var deepSearchSections: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    LocalizationManager.isEnglish ? "Filename keyword (recursive)..." : "输入文件名关键词（递归子目录）...",
                    text: $searchQuery
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    startDeepSearch()
                }

                if !searchQuery.isEmpty && !isSearching {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                if isSearching {
                    Button(role: .destructive) {
                        stopDeepSearch()
                    } label: {
                        Text(LocalizationManager.isEnglish ? "Stop" : "停止")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        startDeepSearch()
                    } label: {
                        Text(LocalizationManager.isEnglish ? "Search" : "搜索")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if isSearching || searchCompleted {
                HStack {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        LocalizationManager.isEnglish
                            ? "Scanned \(searchScannedCount) items · \(searchResults.count) matches"
                            : "已扫描 \(searchScannedCount) 项 · 命中 \(searchResults.count) 项"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if searchHitCap {
                        Text(LocalizationManager.isEnglish ? "Cap: 500" : "已达 500 上限")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            HeaderLabel(LocalizationManager.isEnglish ? "Deep Subfolder Search" : "全子目录深度搜索", symbol: "doc.text.magnifyingglass")
        }

        if !searchResults.isEmpty {
            Section {
                ForEach(searchResults) { entry in
                    resultRow(entry)
                }
            } header: {
                HeaderLabel(
                    LocalizationManager.isEnglish
                        ? "Matches (\(searchResults.count)\(searchHitCap ? "+" : ""))"
                        : "匹配结果 (\(searchResults.count)\(searchHitCap ? "+" : ""))",
                    symbol: "list.bullet"
                )
            }
        } else if searchCompleted && !isSearching {
            Section {
                Text(LocalizationManager.isEnglish ? "No matching files or folders found." : "未找到匹配的文件或文件夹。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Top 100 Largest UI

    @ViewBuilder
    private var topLargestSections: some View {
        Section {
            HStack {
                if isScanningLargest {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        LocalizationManager.isEnglish
                            ? "Scanning \(largestScannedFiles) files (\(formatBytes(largestTotalBytes)))..."
                            : "已扫描 \(largestScannedFiles) 个文件（\(formatBytes(largestTotalBytes))）..."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        stopLargestScan()
                    } label: {
                        Text(LocalizationManager.isEnglish ? "Stop" : "停止")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            LocalizationManager.isEnglish
                                ? "Scanned \(largestScannedFiles) regular files"
                                : "共扫描 \(largestScannedFiles) 个常规文件"
                        )
                        .font(.subheadline)
                        Text(
                            LocalizationManager.isEnglish
                                ? "Total size: \(formatBytes(largestTotalBytes))"
                                : "累计文件体积：\(formatBytes(largestTotalBytes))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        startLargestScan()
                    } label: {
                        Label(LocalizationManager.isEnglish ? "Rescan" : "重新扫描", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            HeaderLabel(LocalizationManager.isEnglish ? "Top 100 Largest Files" : "体积最大前 100 个文件", symbol: "chart.bar.doc.horizontal")
        } footer: {
            Text(
                LocalizationManager.isEnglish
                    ? "Uses POSIX fstatat (without following symlinks) to rank regular files by byte size. Tap a row for Info, or tap the folder icon to jump to its parent directory."
                    : "采用 POSIX fstatat（不穿透符号链接）极速统计常规文件体积。点击行可查看简介，点击右侧文件夹图标可直达所在目录。"
            )
        }

        if !topLargestFiles.isEmpty {
            Section {
                ForEach(Array(topLargestFiles.enumerated()), id: \.element.id) { index, entry in
                    resultRow(entry, rank: index + 1)
                }
            }
        } else if largestCompleted && !isScanningLargest {
            Section {
                Text(LocalizationManager.isEnglish ? "No regular files found inside this directory." : "该目录下未发现常规文件。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ entry: AnalyzedFileEntry, rank: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Button {
                openInfo(for: entry)
            } label: {
                HStack(spacing: 10) {
                    if let rank {
                        Text("#\(rank)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                    } else {
                        Image(systemName: entry.isSymlink ? "arrow.up.right.circle" : (entry.isDirectory ? "folder" : "doc"))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                            .frame(width: 20, alignment: .center)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.relativePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !entry.isDirectory {
                        Text(formatBytes(entry.size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if onNavigateToFolder != nil {
                Button {
                    onNavigateToFolder?(entry.parentURL)
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LocalizationManager.isEnglish ? "Open Parent Folder" : "打开所在目录")
            }
        }
        .contextMenu {
            Button {
                openInfo(for: entry)
            } label: {
                Label(LocalizationManager.isEnglish ? "Get Info" : "显示简介", systemImage: "info.circle")
            }

            if let onNavigateToFolder {
                Button {
                    onNavigateToFolder(entry.parentURL)
                } label: {
                    Label(LocalizationManager.isEnglish ? "Open Parent Folder" : "打开所在目录", systemImage: "folder")
                }

                if entry.isDirectory {
                    Button {
                        onNavigateToFolder(entry.url)
                    } label: {
                        Label(LocalizationManager.isEnglish ? "Open This Folder" : "进入此文件夹", systemImage: "arrow.right.circle")
                    }
                }
            }

            Button {
                UIPasteboard.general.string = entry.fullPath
            } label: {
                Label(LocalizationManager.isEnglish ? "Copy Path" : "复制路径", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Actions & Traversal

    private func ensureRootAccess() {
        let p = rootURL.path
        if fm.isReadableFile(atPath: p) {
            accessError = nil
            return
        }
        if !wq.hasActiveAccess(path: p) {
            let res = wq.grantAccess(path: p, requireWrite: false)
            if res.0 {
                didGrantRootAccess = true
                accessError = nil
            } else {
                accessError = res.2
            }
        }
    }

    private func openInfo(for entry: AnalyzedFileEntry) {
        let item = getFileItem(at: entry.url)
        infoWrapper = InfoFileWrapper(item: item)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func stopDeepSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        searchCompleted = true
    }

    private func startDeepSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        searchTask?.cancel()
        isSearching = true
        searchScannedCount = 0
        searchResults = []
        searchHitCap = false
        searchCompleted = false

        let rootPath = rootURL.standardizedFileURL.path
        let maxCap = Self.maxSearchMatches

        searchTask = Task.detached(priority: .userInitiated) {
            let outcome = await Self.performDeepSearch(
                rootPath: rootPath,
                query: trimmed,
                maxMatches: maxCap
            ) { scanned in
                await MainActor.run {
                    searchScannedCount = scanned
                }
            }

            await MainActor.run {
                searchScannedCount = outcome.scannedCount
                searchResults = outcome.matches
                searchHitCap = outcome.hitCap
                isSearching = false
                searchCompleted = true
            }
        }
    }

    private func stopLargestScan() {
        largestTask?.cancel()
        largestTask = nil
        isScanningLargest = false
        largestCompleted = true
    }

    private func startLargestScan() {
        largestTask?.cancel()
        isScanningLargest = true
        largestScannedFiles = 0
        largestTotalBytes = 0
        topLargestFiles = []
        largestCompleted = false

        let rootPath = rootURL.standardizedFileURL.path
        let limit = Self.maxLargestFiles

        largestTask = Task.detached(priority: .userInitiated) {
            let outcome = await Self.performTopLargestScan(
                rootPath: rootPath,
                limit: limit
            ) { scanned, totalBytes in
                await MainActor.run {
                    largestScannedFiles = scanned
                    largestTotalBytes = totalBytes
                }
            }

            await MainActor.run {
                largestScannedFiles = outcome.scannedFiles
                largestTotalBytes = outcome.totalBytes
                topLargestFiles = outcome.topFiles
                isScanningLargest = false
                largestCompleted = true
            }
        }
    }

    // MARK: - Nonisolated POSIX Scanners

    private nonisolated static func performDeepSearch(
        rootPath: String,
        query: String,
        maxMatches: Int,
        onProgress: @escaping @Sendable (Int) async -> Void
    ) async -> (matches: [AnalyzedFileEntry], scannedCount: Int, hitCap: Bool) {
        var matches: [AnalyzedFileEntry] = []
        matches.reserveCapacity(min(maxMatches, 128))
        var scanned = 0
        var hitCap = false

        let cleanRoot = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
        var stack: [(dirPath: String, relPrefix: String)] = [(cleanRoot, "")]

        while let current = stack.popLast() {
            if Task.isCancelled { break }
            guard let dir = opendir(current.dirPath) else { continue }
            defer { closedir(dir) }

            let dfd = dirfd(dir)
            while let entryPtr = readdir(dir) {
                if Task.isCancelled { break }

                let name: String = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if name == "." || name == ".." { continue }

                scanned += 1
                if scanned % 250 == 0 {
                    await onProgress(scanned)
                }

                var st = stat()
                guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }

                let kind = st.st_mode & S_IFMT
                let isDir = (kind == S_IFDIR)
                let isLink = (kind == S_IFLNK)
                let relPath = current.relPrefix.isEmpty ? name : "\(current.relPrefix)/\(name)"
                let fullPath = current.dirPath == "/" ? "/\(name)" : "\(current.dirPath)/\(name)"

                if name.localizedCaseInsensitiveContains(query) {
                    let size: Int64 = (kind == S_IFREG) ? Int64(st.st_size) : 0
                    matches.append(
                        AnalyzedFileEntry(
                            name: name,
                            fullPath: fullPath,
                            relativePath: relPath,
                            size: size,
                            isDirectory: isDir,
                            isSymlink: isLink
                        )
                    )
                    if matches.count >= maxMatches {
                        hitCap = true
                        break
                    }
                }

                if isDir {
                    stack.append((fullPath, relPath))
                }
            }

            if hitCap || Task.isCancelled {
                break
            }
        }

        return (matches, scanned, hitCap)
    }

    private nonisolated static func performTopLargestScan(
        rootPath: String,
        limit: Int,
        onProgress: @escaping @Sendable (Int, Int64) async -> Void
    ) async -> (topFiles: [AnalyzedFileEntry], scannedFiles: Int, totalBytes: Int64) {
        var topEntries: [AnalyzedFileEntry] = []
        topEntries.reserveCapacity(limit + 1)
        var minIncludedSize: Int64 = 0
        var scannedFiles = 0
        var totalBytes: Int64 = 0

        let cleanRoot = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
        var stack: [(dirPath: String, relPrefix: String)] = [(cleanRoot, "")]

        while let current = stack.popLast() {
            if Task.isCancelled { break }
            guard let dir = opendir(current.dirPath) else { continue }
            defer { closedir(dir) }

            let dfd = dirfd(dir)
            while let entryPtr = readdir(dir) {
                if Task.isCancelled { break }

                let name: String = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if name == "." || name == ".." { continue }

                var st = stat()
                guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }

                let kind = st.st_mode & S_IFMT
                if kind == S_IFDIR {
                    let relPath = current.relPrefix.isEmpty ? name : "\(current.relPrefix)/\(name)"
                    let fullPath = current.dirPath == "/" ? "/\(name)" : "\(current.dirPath)/\(name)"
                    stack.append((fullPath, relPath))
                    continue
                }

                guard kind == S_IFREG else { continue }

                let fileSize = Int64(st.st_size)
                scannedFiles += 1
                totalBytes += max(fileSize, 0)

                if scannedFiles % 400 == 0 {
                    await onProgress(scannedFiles, totalBytes)
                }

                if topEntries.count < limit || fileSize > minIncludedSize {
                    let relPath = current.relPrefix.isEmpty ? name : "\(current.relPrefix)/\(name)"
                    let fullPath = current.dirPath == "/" ? "/\(name)" : "\(current.dirPath)/\(name)"
                    let entry = AnalyzedFileEntry(
                        name: name,
                        fullPath: fullPath,
                        relativePath: relPath,
                        size: fileSize,
                        isDirectory: false,
                        isSymlink: false
                    )
                    topEntries.append(entry)
                    topEntries.sort { $0.size > $1.size }
                    if topEntries.count > limit {
                        topEntries.removeLast(topEntries.count - limit)
                    }
                    if topEntries.count == limit {
                        minIncludedSize = topEntries.last?.size ?? 0
                    }
                }
            }
        }

        return (topEntries, scannedFiles, totalBytes)
    }
}
