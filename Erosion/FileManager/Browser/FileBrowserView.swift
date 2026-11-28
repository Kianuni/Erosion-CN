//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI
import QuickLook
import Combine
import UniformTypeIdentifiers

enum FileSortMode: String, CaseIterable, Codable, Hashable {
    case system, name, date, type, size
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .system: return L("默认")
        case .name: return L("名称")
        case .date: return L("日期")
        case .type: return L("类型")
        case .size: return L("大小")
        }
    }
}

nonisolated private struct ScopedImportItem: @unchecked Sendable {
    let url: URL
    let hasScope: Bool

    func release() {
        if hasScope {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

struct FileBrowserView: View {
    @EnvironmentObject var mgr: ErosionManager
    var path: URL = URL(fileURLWithPath: "/")
    var isContainer = false
    var shouldGrant = false
    var highlightTargetURL: URL? = nil
    
    @State private var dirFiles: [FileItem] = []
    @State private var unfilteredFiles: [FileItem] = []
    @State private var rawFiles: [FileItem] = []
    @State private var searchText = ""
    @AppStorage("maxInode") var maxInode = 15000000
    @AppStorage("chosenSort") var chosenSort: FileSortMode = .system
    @AppStorage("filesAscend") var filesAscend = true
    @AppStorage("listStyle") var listStyle = 1
    @AppStorage("hideDates") var hideDates = false
    @AppStorage("showFolderSizes") var showFolderSizes = false
    @AppStorage("textViewerSize") var textViewerSize = 10
    @AppStorage("useMonospaced") var useMonospaced = true
    
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var showWiFiShare = false
    @State private var showFolderAnalysis = false
    @State private var pendingAnalysisNavURL: URL?
    @State private var analysisNavigateURL: URL?
    @State private var showFailure = false
    @State private var failMsg = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var didAutoScrollToHighlight = false

    // Multi-select & async progress state
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var busyStatusMessage: String? = nil

    // Async folder sizing cache
    @State private var folderSizes: [String: Int64] = [:]
    @State private var folderSizeTask: Task<Void, Never>?

    private var allVisibleSelected: Bool {
        !dirFiles.isEmpty && dirFiles.allSatisfy { selectedIDs.contains($0.id) }
    }

    private var selectedItemsForBatch: [FileItem] {
        unfilteredFiles.filter { selectedIDs.contains($0.id) }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                if let busyStatusMessage {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(busyStatusMessage)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                        }
                    }
                }

                if isLoading {
                    Section {
                        VStack(alignment: .leading) {
                            HStack {
                                ProgressView()
                                    .offset(y: 0.5)
                                Text("正在加载文件...")
                                    .fontWeight(.medium)
                            }
                            if isContainer {
                                Text("由于容器路径扫描耗时较长，首次加载可能需要 30 秒以上，请耐心等待。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if showFailure {
                    CompactAlert(title: "无法加载目录文件！", symbol: "folder.badge.questionmark", text: failMsg)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else if dirFiles.isEmpty {
                    emptyStatePlaceholder
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(dirFiles) { file in
                        Group {
                            if file.type == .folder {
                                FolderRow(
                                    file: file,
                                    shouldGrant: isContainer ? true : false,
                                    isContainer: isContainer,
                                    isSelecting: isSelecting,
                                    isSelected: selectedIDs.contains(file.id),
                                    measuredSize: showFolderSizes && !isContainer ? folderSizes[file.id] : nil,
                                    onToggleSelect: { toggleSelection(file.id) },
                                    onBusyChange: { msg in busyStatusMessage = msg }
                                )
                            } else {
                                FileRow(
                                    file: file,
                                    isSelecting: isSelecting,
                                    isSelected: selectedIDs.contains(file.id),
                                    onToggleSelect: { toggleSelection(file.id) },
                                    onBusyChange: { msg in busyStatusMessage = msg }
                                )
                            }
                        }
                        .id(file.id)
                        .listRowBackground(rowBackground(for: file))
                    }
                }
            }
            .onChange(of: dirFiles.map(\.id)) {
                scrollToHighlightedIfNeeded(using: scrollProxy)
            }
            .onAppear {
                scrollToHighlightedIfNeeded(using: scrollProxy)
            }
        }
        .navigationTitle(path.lastPathComponent.isEmpty ? path.path : path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .searchable(text: $searchText, prompt: "搜索文件或 Bundle ID")
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                batchActionBar
            }
        }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleSelectAllVisible()
                    } label: {
                        Text(
                            allVisibleSelected
                                ? (LocalizationManager.isEnglish ? "Deselect All" : "取消全选")
                                : (LocalizationManager.isEnglish ? "Select All" : "全选")
                        )
                    }
                    .disabled(dirFiles.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exitSelectionMode()
                    } label: {
                        Text(LocalizationManager.isEnglish ? "Done" : "完成")
                            .fontWeight(.semibold)
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(FileSortMode.allCases, id: \.self) { option in
                            Button {
                                chosenSort = option
                            } label: {
                                if chosenSort == option {
                                    Label(option.label, systemImage: "checkmark")
                                        .tag(option)
                                } else {
                                    Text(option.label)
                                        .tag(option)
                                }
                            }
                        }
                        Divider()
                        Button {
                            filesAscend.toggle()
                        } label: {
                            if filesAscend {
                                Label("升序", systemImage: "chevron.up")
                            } else {
                                Label("降序", systemImage: "chevron.down")
                            }
                        }
                        .disabled(chosenSort == .system)
                    } label: {
                        Label("排序", systemImage: "line.3.horizontal.decrease")
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !isContainer {
                            Button {
                                enterSelectionMode()
                            } label: {
                                Label(
                                    LocalizationManager.isEnglish ? "Select Items..." : "选择文件…",
                                    systemImage: "checkmark.circle"
                                )
                            }
                            .disabled(dirFiles.isEmpty)

                            Divider()

                            Menu {
                                Button {
                                    promptNewFile()
                                } label: {
                                    Label("文件", systemImage: "doc")
                                }
                                
                                Button {
                                    promptNewPlist()
                                } label: {
                                    Label("属性列表 (Plist)", systemImage: "tablecells")
                                }
                                
                                Button {
                                    promptNewFolder()
                                } label: {
                                    Label("文件夹", systemImage: "folder")
                                }
                                
                                Button {
                                    promptNewSymlink()
                                } label: {
                                    Label("符号链接 (Symlink)", systemImage: "arrow.up.right.circle")
                                }
                            } label: {
                                Label("新建...", systemImage: "plus")
                            }
                            
                            Button {
                                showFileImporter = true
                            } label: {
                                Label(
                                    LocalizationManager.isEnglish ? "Import Files" : "导入文件",
                                    systemImage: "arrow.down.doc"
                                )
                            }

                            Button {
                                showFolderImporter = true
                            } label: {
                                Label(
                                    LocalizationManager.isEnglish ? "Import Folder" : "导入文件夹",
                                    systemImage: "folder.badge.plus"
                                )
                            }

                            Divider()

                            Button {
                                showFolderAnalysis = true
                            } label: {
                                Label(
                                    LocalizationManager.isEnglish ? "Deep Search & Large Files" : "深度搜索与大文件",
                                    systemImage: "magnifyingglass.circle"
                                )
                            }

                            Button {
                                showWiFiShare = true
                            } label: {
                                Label(
                                    LocalizationManager.isEnglish ? "Wi-Fi File Sharing" : "Wi-Fi 无线传输",
                                    systemImage: "wifi"
                                )
                            }
                            Divider()
                        }
                        NavigationLink {
                            FileBrowserView(path: URL.documentsDirectory)
                        } label: {
                            Label("打开应用文档目录", systemImage: "folder")
                        }
                        NavigationLink {
                            browserSettingsView
                        } label: {
                            Label("浏览设置", systemImage: "gearshape")
                        }
                    } label: {
                        Label("操作", systemImage: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        // Attach the two fileImporters on separate background hosts so iOS always presents both reliably
        .background {
            Color.clear
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.item],
                    allowsMultipleSelection: true
                ) { result in
                    handleMultiImport(result)
                }
        }
        .background {
            Color.clear
                .fileImporter(
                    isPresented: $showFolderImporter,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    handleMultiImport(result)
                }
        }
        .sheet(isPresented: $showWiFiShare) {
            WiFiShareSheet(rootURL: path)
        }
        .sheet(isPresented: $showFolderAnalysis, onDismiss: {
            if let target = pendingAnalysisNavURL {
                pendingAnalysisNavURL = nil
                analysisNavigateURL = target
            }
        }) {
            FolderAnalysisSheet(rootURL: path) { targetURL in
                let targetCanon = FMNavigationStore.canonicalPath(targetURL.path)
                let currentCanon = FMNavigationStore.canonicalPath(path.path)
                if targetCanon != currentCanon {
                    pendingAnalysisNavURL = targetURL
                }
                showFolderAnalysis = false
            }
        }
        .navigationDestination(item: $analysisNavigateURL) { targetURL in
            FileBrowserView(path: targetURL, shouldGrant: true)
        }
        .refreshable {
            mgr.refreshFiles.toggle()
        }
        .onAppear {
            if !mgr.storedFiles.isEmpty && mgr.storedURL == path {
                rawFiles = mgr.storedFiles
                let sorted = sortFiles(files: mgr.storedFiles)
                unfilteredFiles = sorted
                dirFiles = filterFiles(sorted, query: searchText)
                if !isContainer {
                    FMNavigationStore.shared.record(url: path)
                    scheduleFolderSizeCalculationIfNeeded()
                }
            } else if isContainer && hasLoaded {
                // do nothing as it's already being stored in the variable
            } else {
                if shouldGrant {
                    let res = wq.grantAccess(path: path.path, requireWrite: false)
                    if res.0 {
                        if !isContainer {
                            FMNavigationStore.shared.record(url: path)
                        }
                        loadFilesFromPath()
                    } else {
                        showFailure = true
                        failMsg = L("无权访问该目录。")
                    }
                } else {
                    if !isContainer {
                        FMNavigationStore.shared.record(url: path)
                    }
                    loadFilesFromPath()
                }
            }
        }
        .onDisappear {
            folderSizeTask?.cancel()
            folderSizeTask = nil
        }
        .onChange(of: searchText) { _, newSearch in
            dirFiles = filterFiles(unfilteredFiles, query: newSearch)
        }
        .onChange(of: chosenSort) {
            reapplySortAndFilter()
        }
        .onChange(of: filesAscend) {
            reapplySortAndFilter()
        }
        .onChange(of: showFolderSizes) { _, enabled in
            if enabled {
                scheduleFolderSizeCalculationIfNeeded()
            } else {
                folderSizeTask?.cancel()
                folderSizeTask = nil
                folderSizes = [:]
                if chosenSort == .size {
                    reapplySortAndFilter()
                }
            }
        }
        .onChange(of: mgr.refreshFiles) {
            loadFilesFromPath()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyStatePlaceholder: some View {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView {
                Label(
                    LocalizationManager.isEnglish ? "Empty Folder" : "空文件夹",
                    systemImage: "folder"
                )
            } description: {
                Text(
                    isContainer
                        ? (LocalizationManager.isEnglish
                            ? "No accessible containers were found in this directory."
                            : "当前目录下未扫描到可访问的容器。")
                        : (LocalizationManager.isEnglish
                            ? "Use the top-right menu to create or import files and folders."
                            : "可通过右上角操作菜单新建或导入文件与文件夹。")
                )
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private var batchActionBar: some View {
        let count = selectedItemsForBatch.count
        let hasSelection = count > 0
        let isBusy = busyStatusMessage != nil

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(
                    LocalizationManager.isEnglish
                        ? "\(count) selected"
                        : "已选 \(count) 项"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                Button {
                    runBatchShare()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.medium))
                        Text(LocalizationManager.isEnglish ? "Share" : "分享")
                            .font(.caption2)
                    }
                    .frame(minWidth: 48)
                }
                .disabled(!hasSelection || isBusy)

                Button {
                    runBatchZip()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "archivebox")
                            .font(.body.weight(.medium))
                        Text(LocalizationManager.isEnglish ? "Zip" : "打包")
                            .font(.caption2)
                    }
                    .frame(minWidth: 48)
                }
                .disabled(!hasSelection || isBusy)

                Button(role: .destructive) {
                    promptBatchDelete()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.body.weight(.medium))
                        Text(LocalizationManager.isEnglish ? "Delete" : "删除")
                            .font(.caption2)
                    }
                    .frame(minWidth: 48)
                }
                .tint(.red)
                .disabled(!hasSelection || isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var browserSettingsView: some View {
        List {
            Section {
                HStack {
                    Text("最大 Inode 扫描上限")
                    TextField("15000000", value: $maxInode, format: .number)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                HeaderLabel("容器路径扫描", symbol: "externaldrive")
            } footer: {
                Text("控制扫描容器目录时的最大 Inode 范围。数值越小扫描越快，但可能遗漏高 Inode 容器（建议设为 15000000）。")
            }
            
            Section {
                Picker("列表样式", selection: $listStyle) {
                    Text("默认").tag(1)
                    Text("平铺").tag(2)
                    Text("分组").tag(3)
                }
                Toggle("隐藏修改日期", isOn: $hideDates)
                Toggle(
                    LocalizationManager.isEnglish ? "Show Folder Sizes" : "显示文件夹大小",
                    isOn: $showFolderSizes
                )
            } header: {
                HeaderLabel("显示选项", symbol: "eye")
            } footer: {
                Text(
                    LocalizationManager.isEnglish
                        ? "When enabled, folder sizes inside non-root directories are calculated asynchronously in the background."
                        : "开启后将在后台异步统计普通子目录中的文件夹体积，并参与「按大小排序」。"
                )
            }
            
            Section {
                Stepper(value: $textViewerSize) {
                    HStack {
                        Text("字号大小")
                        Spacer()
                        Text(textViewerSize.description)
                    }
                }
                Toggle("等宽字体", isOn: $useMonospaced)
            } header: {
                HeaderLabel("文本查看器", symbol: "doc.plaintext")
            }
        }
        .navigationTitle("文件浏览设置")
    }

    // MARK: - Selection Helpers

    private func rowBackground(for file: FileItem) -> Color? {
        if isSelecting && selectedIDs.contains(file.id) {
            return Color.accentColor.opacity(0.14)
        }
        if matchesHighlight(file) {
            return Color.orange.opacity(0.16)
        }
        return nil
    }

    private func enterSelectionMode() {
        withAnimation(.snappy(duration: 0.2)) {
            isSelecting = true
            selectedIDs.removeAll()
        }
    }

    private func exitSelectionMode() {
        withAnimation(.snappy(duration: 0.2)) {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    private func toggleSelection(_ id: String) {
        Haptic.shared.play(.soft)
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleSelectAllVisible() {
        Haptic.shared.play(.soft)
        if allVisibleSelected {
            for item in dirFiles {
                selectedIDs.remove(item.id)
            }
        } else {
            for item in dirFiles {
                selectedIDs.insert(item.id)
            }
        }
    }

    // MARK: - Batch Operations

    private func runBatchShare() {
        let targets = selectedItemsForBatch.map(\.fileURL)
        guard !targets.isEmpty else { return }
        busyStatusMessage = LocalizationManager.isEnglish
            ? "Preparing \(targets.count) item(s) to share..."
            : "正在准备分享 \(targets.count) 个项目…"

        Task.detached(priority: .userInitiated) {
            let res = makeTempItems(targets)
            await MainActor.run {
                busyStatusMessage = nil
                switch res {
                case .success(let stagedURLs):
                    presentShareSheet(with: stagedURLs)
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(
                        title: LocalizationManager.isEnglish ? "Batch Share Failed" : "批量分享失败",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func runBatchZip() {
        let targets = selectedItemsForBatch.map(\.fileURL)
        guard !targets.isEmpty else { return }
        let destDir = path
        busyStatusMessage = LocalizationManager.isEnglish
            ? "Compressing \(targets.count) item(s) into ZIP..."
            : "正在将 \(targets.count) 个项目打包为 ZIP…"

        Task.detached(priority: .userInitiated) {
            let res = await zipItemsDetailed(targets, in: destDir)
            await MainActor.run {
                busyStatusMessage = nil
                switch res {
                case .success(let zipURL):
                    Haptic.shared.notify(.success)
                    exitSelectionMode()
                    mgr.refreshFiles.toggle()
                    Alertinator.shared.alert(
                        title: LocalizationManager.isEnglish ? "Archive Created" : "打包完成",
                        body: LocalizationManager.isEnglish
                            ? "Saved as \"\(zipURL.lastPathComponent)\"."
                            : "已生成压缩包「\(zipURL.lastPathComponent)」。"
                    )
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(
                        title: LocalizationManager.isEnglish ? "Batch Compress Failed" : "批量打包失败",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func promptBatchDelete() {
        let items = selectedItemsForBatch
        guard !items.isEmpty else { return }

        let previewNames = items.prefix(3).map(\.name).joined(separator: "、")
        let moreSuffix = items.count > 3
            ? (LocalizationManager.isEnglish ? " and \(items.count - 3) more" : " 等共 \(items.count) 项")
            : ""

        let hasFolder = items.contains { $0.type == .folder }
        let folderNote = hasFolder
            ? (LocalizationManager.isEnglish
                ? "\n\nSelected folders and all contents inside them will also be permanently deleted."
                : "\n\n所选文件夹及其内部全部内容也将一并永久删除。")
            : ""

        let title = LocalizationManager.isEnglish
            ? "Delete \(items.count) Item(s)?"
            : "确认批量删除 \(items.count) 个项目？"

        let body = (LocalizationManager.isEnglish
            ? "Permanently delete \(previewNames)\(moreSuffix)? This action cannot be undone."
            : "确定要永久删除「\(previewNames)」\(moreSuffix)吗？此操作无法撤销。") + folderNote

        let targetURLs = items.map(\.fileURL)
        Alertinator.shared.confirmDestructive(
            title: title,
            body: body,
            destructiveLabel: LocalizationManager.isEnglish ? "Delete (\(items.count))" : "删除（\(items.count)）"
        ) {
            busyStatusMessage = LocalizationManager.isEnglish
                ? "Deleting \(targetURLs.count) item(s)..."
                : "正在删除 \(targetURLs.count) 个项目…"
            Task.detached(priority: .userInitiated) {
                let report = await deleteItemsDetailed(targetURLs)
                await MainActor.run {
                    busyStatusMessage = nil
                    mgr.refreshFiles.toggle()
                    if report.hasFailures {
                        Haptic.shared.notify(.error)
                        let header = LocalizationManager.isEnglish
                            ? "Deleted \(report.succeededCount) item(s), \(report.failures.count) failed:\n\n"
                            : "已删除 \(report.succeededCount) 项，以下 \(report.failures.count) 项删除失败：\n\n"
                        Alertinator.shared.alert(
                            title: LocalizationManager.isEnglish ? "Partial Delete Failure" : "部分项目删除失败",
                            body: header + report.formattedFailureSummary()
                        )
                        // Keep only still-existing failed items selected
                        let failedNames = Set(report.failures.map(\.name))
                        selectedIDs = Set(items.filter { failedNames.contains($0.name) }.map(\.id))
                    } else {
                        Haptic.shared.notify(.success)
                        exitSelectionMode()
                    }
                }
            }
        }
    }

    // MARK: - Create New Items (With Write Access & Detailed Errors)

    private func promptNewFile() {
        let destDir = path
        Alertinator.shared.prompt(title: L("请输入新文件名称（请附带文件扩展名）："), placeholder: "new.txt") { raw in
            guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    guard !name.contains("/"), name != ".", name != ".." else {
                        throw FileManagerOpError.invalidName(
                            LocalizationManager.isEnglish ? "Filename cannot contain '/' or be '.' / '..'." : "文件名不能包含 '/'，也不能为 '.' 或 '..'。"
                        )
                    }
                    if let reason = FileSafetyGuard.protectedFilenameReason(name) {
                        throw FileManagerOpError.protectedPath(reason)
                    }
                    try await FileSafetyGuard.withWriteAccess(for: destDir) {
                        let fileURL = destDir.appendingPathComponent(name)
                        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                            throw FileManagerOpError.targetAlreadyExists(
                                LocalizationManager.isEnglish
                                    ? "An item named \"\(name)\" already exists."
                                    : "当前目录已存在名为「\(name)」的项目。"
                            )
                        }
                        try Data().write(to: fileURL)
                    }
                    return .success(())
                } catch {
                    return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
                }
            }.value

            await MainActor.run {
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("新建文件失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func promptNewPlist() {
        let destDir = path
        Alertinator.shared.prompt(title: L("请输入新建 Plist 属性列表名称："), placeholder: L("配置名称")) { raw in
            guard let rawName = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { return }
            let finalName = rawName.lowercased().hasSuffix(".plist") ? rawName : (rawName + ".plist")
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    guard !finalName.contains("/") else {
                        throw FileManagerOpError.invalidName(
                            LocalizationManager.isEnglish ? "Filename cannot contain '/'." : "文件名不能包含 '/'。"
                        )
                    }
                    if let reason = FileSafetyGuard.protectedFilenameReason(finalName) {
                        throw FileManagerOpError.protectedPath(reason)
                    }
                    try await FileSafetyGuard.withWriteAccess(for: destDir) {
                        let fileURL = destDir.appendingPathComponent(finalName)
                        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                            throw FileManagerOpError.targetAlreadyExists(
                                LocalizationManager.isEnglish
                                    ? "An item named \"\(finalName)\" already exists."
                                    : "当前目录已存在名为「\(finalName)」的项目。"
                            )
                        }
                        let data = try PropertyListSerialization.data(fromPropertyList: NSMutableDictionary(), format: .xml, options: 0)
                        try data.write(to: fileURL)
                    }
                    return .success(())
                } catch {
                    return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
                }
            }.value

            await MainActor.run {
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("新建 Plist 失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func promptNewFolder() {
        let destDir = path
        Alertinator.shared.prompt(title: L("请输入新建文件夹名称："), placeholder: L("新建文件夹")) { raw in
            guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    guard !name.contains("/"), name != ".", name != ".." else {
                        throw FileManagerOpError.invalidName(
                            LocalizationManager.isEnglish ? "Folder name cannot contain '/' or be '.' / '..'." : "文件夹名称不能包含 '/'，也不能为 '.' 或 '..'。"
                        )
                    }
                    try await FileSafetyGuard.withWriteAccess(for: destDir) {
                        let folderURL = destDir.appendingPathComponent(name)
                        guard !FileManager.default.fileExists(atPath: folderURL.path) else {
                            throw FileManagerOpError.targetAlreadyExists(
                                LocalizationManager.isEnglish
                                    ? "An item named \"\(name)\" already exists."
                                    : "当前目录已存在名为「\(name)」的项目。"
                            )
                        }
                        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    }
                    return .success(())
                } catch {
                    return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
                }
            }.value

            await MainActor.run {
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("新建文件夹失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func promptNewSymlink() {
        let destDir = path
        Alertinator.shared.prompt(title: L("请输入符号链接指向的目标路径："), placeholder: "/path/to/dir") { raw in
            guard let symPath = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !symPath.isEmpty else { return }
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let linkName = URL(fileURLWithPath: symPath).lastPathComponent
                    guard !linkName.isEmpty, linkName != "/" else {
                        throw FileManagerOpError.invalidName(
                            LocalizationManager.isEnglish ? "Invalid target path for symlink." : "符号链接目标路径无效。"
                        )
                    }
                    try await FileSafetyGuard.withWriteAccess(for: destDir) {
                        try FileManager.default.createSymbolicLink(
                            atPath: destDir.appendingPathComponent(linkName).path,
                            withDestinationPath: symPath
                        )
                    }
                    return .success(())
                } catch {
                    return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
                }
            }.value

            await MainActor.run {
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("创建符号链接失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Highlight & Search

    private func matchesHighlight(_ item: FileItem) -> Bool {
        guard let highlightTargetURL else { return false }
        let targetCanon = FMNavigationStore.canonicalPath(highlightTargetURL.standardizedFileURL.path)
        let itemCanon = FMNavigationStore.canonicalPath(item.fileURL.standardizedFileURL.path)
        return itemCanon == targetCanon
    }

    private func scrollToHighlightedIfNeeded(using proxy: ScrollViewProxy) {
        guard !didAutoScrollToHighlight,
              highlightTargetURL != nil,
              let matched = dirFiles.first(where: { matchesHighlight($0) }) else {
            return
        }
        didAutoScrollToHighlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(matched.id, anchor: .center)
            }
        }
    }

    private func filterFiles(_ files: [FileItem], query: String) -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.fileURL.lastPathComponent.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func reapplySortAndFilter() {
        let source = rawFiles.isEmpty ? unfilteredFiles : rawFiles
        let sorted = sortFiles(files: source)
        unfilteredFiles = sorted
        dirFiles = filterFiles(sorted, query: searchText)
    }
    
    // MARK: - Load & Async Folder Sizing

    private func loadFilesFromPath() {
        isLoading = true
        folderSizeTask?.cancel()
        folderSizeTask = nil
        folderSizes = [:]

        let currentMaxInode = Int64(maxInode)
        let currentPath = path
        let containerMode = isContainer
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var unsortedFiles: [FileItem] = []
                if containerMode {
                    let paths = fsHandlers.getDirPaths(currentPath.path, maxInode: currentMaxInode)
                    for p in paths {
                        unsortedFiles.append(getFileItem(at: URL(fileURLWithPath: p), isContainer: true))
                    }
                } else {
                    let pathFiles = try fm.contentsOfDirectory(at: currentPath, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    
                    unsortedFiles = pathFiles.map { fileURL in
                        if currentPath == FSURL.appGroup || currentPath == FSURL.systemData {
                            return getFileItem(at: fileURL, isContainer: true)
                        } else {
                            return getFileItem(at: fileURL)
                        }
                    }
                }
                DispatchQueue.main.async {
                    showFailure = false
                    rawFiles = unsortedFiles
                    let sorted = sortFiles(files: unsortedFiles)
                    unfilteredFiles = sorted
                    dirFiles = filterFiles(sorted, query: searchText)
                    if isSelecting {
                        let validIDs = Set(unsortedFiles.map(\.id))
                        selectedIDs = selectedIDs.intersection(validIDs)
                    }
                    if containerMode {
                        mgr.storedFiles = unsortedFiles
                        mgr.storedURL = currentPath
                    }
                    hasLoaded = true
                    isLoading = false
                    scheduleFolderSizeCalculationIfNeeded()
                }
            } catch {
                print("(fm) failed to load files from \(currentPath): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    showFailure = true
                    failMsg = FileSafetyGuard.friendlyErrorDescription(error)
                    isLoading = false
                }
            }
        }
    }

    private func scheduleFolderSizeCalculationIfNeeded() {
        folderSizeTask?.cancel()
        folderSizeTask = nil
        guard showFolderSizes, !isContainer else { return }

        let folders: [(id: String, url: URL)] = rawFiles
            .filter { $0.type == .folder }
            .map { ($0.id, $0.fileURL) }
        guard !folders.isEmpty else { return }

        folderSizeTask = Task.detached(priority: .utility) {
            for folder in folders {
                if Task.isCancelled { return }
                if let size = FolderSizeCalculator.computeSize(of: folder.url) {
                    let id = folder.id
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        folderSizes[id] = size
                        if chosenSort == .size {
                            reapplySortAndFilter()
                        }
                    }
                }
            }
        }
    }
    
    private func sortFiles(files: [FileItem]) -> [FileItem] {
        var sortedFiles: [FileItem]
        
        switch chosenSort {
        case .system:
            sortedFiles = files
        case .name:
            sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            sortedFiles = files.sorted { $0.modifiedDate > $1.modifiedDate }
        case .type:
            sortedFiles = files.sorted { $0.type.sortOrder < $1.type.sortOrder }
        case .size:
            sortedFiles = files.sorted { lhs, rhs in
                let lSize = lhs.type == .folder ? (folderSizes[lhs.id] ?? Int64(lhs.size)) : Int64(lhs.size)
                let rSize = rhs.type == .folder ? (folderSizes[rhs.id] ?? Int64(rhs.size)) : Int64(rhs.size)
                return lSize < rSize
            }
        }

        sortedFiles = filesAscend ? sortedFiles : sortedFiles.reversed()
        sortedFiles = sortedFiles.sorted { a, b in
            a.hidden && !b.hidden
        }
        return sortedFiles
    }
    
    // MARK: - Import Files & Folders

    private func handleMultiImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            // Acquire security-scoped access synchronously inside callback so iOS File Providers keep access valid across alerts
            let scopedItems = urls.map { ScopedImportItem(url: $0, hasScope: $0.startAccessingSecurityScopedResource()) }
            let collisions = detectImportCollisions(sourceURLs: urls, destDir: path)

            if collisions.isEmpty {
                executeImport(scopedItems: scopedItems, policy: .keepBoth)
            } else {
                let preview = collisions.prefix(3).joined(separator: "、")
                let more = collisions.count > 3 ? "…" : ""
                let title = LocalizationManager.isEnglish ? "Item Already Exists" : "检测到同名项目"
                let body = LocalizationManager.isEnglish
                    ? "Destination already contains \"\(preview)\"\(more). Keep both (auto-rename) or replace existing item(s)?"
                    : "当前目录已存在同名项目「\(preview)」\(more)。要保留两者（自动编号重命名）还是覆盖替换？"

                Alertinator.shared.choose(
                    title: title,
                    body: body,
                    actions: [
                        (LocalizationManager.isEnglish ? "Keep Both" : "保留两者", .default, {
                            executeImport(scopedItems: scopedItems, policy: .keepBoth)
                        }),
                        (LocalizationManager.isEnglish ? "Replace" : "覆盖替换", .destructive, {
                            executeImport(scopedItems: scopedItems, policy: .replace)
                        })
                    ],
                    onCancel: {
                        for item in scopedItems { item.release() }
                    }
                )
            }

        case .failure(let error):
            print("(fm) failed to import item(s): \(error.localizedDescription)")
            Alertinator.shared.alert(
                title: L("导入文件失败！"),
                body: FileSafetyGuard.friendlyErrorDescription(error)
            )
        }
    }

    private func executeImport(scopedItems: [ScopedImportItem], policy: ImportCollisionPolicy) {
        let destDir = path
        let total = scopedItems.count
        busyStatusMessage = LocalizationManager.isEnglish
            ? "Importing \(total) item(s)..."
            : "正在导入 \(total) 个项目…"

        Task.detached(priority: .userInitiated) {
            defer {
                for item in scopedItems { item.release() }
            }
            let report = await importItemsDetailed(
                from: scopedItems.map(\.url),
                to: destDir,
                collisionPolicy: policy
            )
            await MainActor.run {
                busyStatusMessage = nil
                mgr.refreshFiles.toggle()
                if report.hasFailures {
                    Haptic.shared.notify(.error)
                    let header = report.succeededCount > 0
                        ? (LocalizationManager.isEnglish
                            ? "Imported \(report.succeededCount) item(s), \(report.failures.count) failed:\n\n"
                            : "已成功导入 \(report.succeededCount) 项，以下 \(report.failures.count) 项失败：\n\n")
                        : ""
                    Alertinator.shared.alert(
                        title: LocalizationManager.isEnglish ? "Import Failed" : "导入失败",
                        body: header + report.formattedFailureSummary()
                    )
                } else {
                    Haptic.shared.notify(.success)
                }
            }
        }
    }
}

// MARK: user interface
extension View {
    @ViewBuilder
    func customListStyle(_ selection: Int) -> some View {
        switch selection {
        case 2: self.listStyle(.inset)
        case 3: self.listStyle(.grouped)
        default: self.listStyle(.insetGrouped)
        }
    }
    
    @ViewBuilder
    func adaptiveListMargin() -> some View {
        if #available(iOS 26.0, *) {
            self.contentMargins(.top, 1)
        }
    }
}

struct KeyboardDismissObserver: ViewModifier {
    var action: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onReceive(Publishers.keyboardDismissed) { _ in
                action()
            }
    }
}

extension Publishers {
    static var keyboardDismissed: AnyPublisher<Void, Never> {
        NotificationCenter.default
            .publisher(for: UIResponder.keyboardDidHideNotification)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
