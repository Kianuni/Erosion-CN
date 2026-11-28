//
//  FileRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import QuickLook
import ZIPFoundation

struct FileRow: View {
    @EnvironmentObject var mgr: ErosionManager
    @AppStorage("hideDates") var hideDates = false
    var file: FileItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onBusyChange: ((String?) -> Void)? = nil
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    @State private var conformsZip = false
    @State private var symlinkIsDir = true
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    @State private var previewURL: URL?
    
    private var resolvedFileURL: URL {
        file.type == .symlink ? file.destURL : file.fileURL
    }
    
    var body: some View {
        Group {
            if isSelecting {
                Button {
                    onToggleSelect?()
                } label: {
                    selectionRowContent
                }
            } else if file.type == .file || (file.type == .symlink && !symlinkIsDir) {
                Button {
                    let target = resolvedFileURL
                    if conformsZip && file.type == .file {
                        promptUnzip()
                    } else {
                        if conformsPlist {
                            showPlistViewer.toggle()
                        } else if conformsText {
                            showTextViewer.toggle()
                        } else {
                            previewURL = target
                        }
                    }
                } label: {
                    normalFileRowContent
                }
            } else {
                NavigationLink(destination: FileBrowserView(path: file.destURL, shouldGrant: true)) {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "arrow.up.right.circle")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                        
                        Text(file.name)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(Color(.label))
        .onAppear {
            let target = resolvedFileURL
            if file.type == .symlink {
                if !fm.isReadableFile(atPath: target.path) {
                    _ = wq.grantAccess(path: target.path, requireWrite: false)
                }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
                    symlinkIsDir = isDir.boolValue
                } else {
                    symlinkIsDir = false
                }
            }
            conformsText = conformsToTextViewer(target)
            conformsPlist = conformsToPlistViewer(target)
            conformsZip = file.uttype.conforms(to: .zip) || file.fileURL.pathExtension.lowercased() == "zip"
        }
        .sheet(isPresented: $showInfo) {
            InfoViewer(file)
        }
        .sheet(isPresented: $showPlistViewer) {
            PlistViewer(resolvedFileURL)
        }
        .sheet(isPresented: $showTextViewer) {
            TextViewer(resolvedFileURL)
        }
        .quickLookPreview($previewURL)
        // MARK: cell actions
        .contextMenu {
            if !isSelecting {
                if conformsText || conformsPlist {
                    Menu {
                        Button {
                            previewURL = resolvedFileURL
                        } label: {
                            Label("快速查看", systemImage: "eye")
                        }
                        
                        if conformsPlist {
                            Button {
                                showPlistViewer.toggle()
                            } label: {
                                Label("Plist 查看器", systemImage: "tablecells")
                            }
                        }
                        
                        if conformsText {
                            Button {
                                showTextViewer.toggle()
                            } label: {
                                Label("文本查看器", systemImage: "doc.plaintext")
                            }
                        }
                    } label: {
                        Label("打开方式...", systemImage: "doc.text.magnifyingglass")
                    }
                } else {
                    Button {
                        previewURL = resolvedFileURL
                    } label: {
                        Label("快速查看", systemImage: "eye")
                    }
                }
                
                Divider()
                
                Button {
                    showInfo.toggle()
                } label: {
                    Label("显示简介", systemImage: "info.circle")
                }
                
                if file.type == .file || file.type == .symlink {
                    Button {
                        promptRename()
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                }
                
                if file.type == .file {
                    if conformsZip {
                        Button {
                            promptUnzip()
                        } label: {
                            Label("解压缩", systemImage: "archivebox")
                        }
                    } else {
                        Button {
                            runZip()
                        } label: {
                            Label("压缩为 ZIP", systemImage: "archivebox")
                        }
                    }
                }
                
                if file.type == .file {
                    Button {
                        runDuplicate()
                    } label: {
                        Label("创建副本", systemImage: "plus.square.on.square")
                    }
                }
                
                Divider()
                
                Button {
                    let res = copyFileToClipboard(file.fileURL)
                    if !res {
                        Alertinator.shared.alert(
                            title: L("复制文件失败！"),
                            body: LocalizationManager.isEnglish
                                ? "Could not read \"\(file.name)\" into the clipboard."
                                : "无法读取「\(file.name)」并写入剪贴板。"
                        )
                    } else {
                        Haptic.shared.play(.soft)
                    }
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                
                Button {
                    runShare()
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }

                if file.type == .file && AdCustomWatchStore.shared.canAddAsCustomTarget(url: file.fileURL, owner: file.owner) {
                    let isWatched = AdCustomWatchStore.shared.contains(url: file.fileURL)
                    Button {
                        if isWatched {
                            AdCustomWatchStore.shared.remove(fullPath: file.fileURL.path)
                            Haptic.shared.play(.soft)
                        } else {
                            let canon = AdCustomWatchStore.canonicalVarPath(file.fileURL.standardizedFileURL.path)
                            AdCustomWatchStore.shared.addValidatedRule(canonicalPath: canon)
                            Haptic.shared.notify(.success)
                            Alertinator.shared.alert(
                                title: LocalizationManager.isEnglish ? "Added to Ad Blocker" : "已加入广告锁死列表",
                                body: LocalizationManager.isEnglish
                                    ? "Manage, preview or lock \"\(file.name)\" anytime in Splash Ad Blocker."
                                    : "已收藏文件「\(file.name)」，可在「开屏广告缓存精准锁死」页预览内容或一键锁死。"
                            )
                        }
                    } label: {
                        Label(
                            isWatched
                                ? (LocalizationManager.isEnglish ? "Remove from Ad Blocker" : "移出广告锁死列表")
                                : (LocalizationManager.isEnglish ? "Add to Ad Blocker" : "加入广告锁死列表"),
                            systemImage: isWatched ? "lock.slash" : "lock.shield"
                        )
                    }
                }

                if AdWhitelistStore.shared.canWhitelistPath(url: file.fileURL, owner: file.owner) {
                    let isWhitelisted = AdWhitelistStore.shared.containsExactPath(file.fileURL)
                    Button {
                        if isWhitelisted {
                            AdWhitelistStore.shared.removeExactPath(file.fileURL.path)
                            Haptic.shared.play(.soft)
                        } else {
                            let canon = AdCustomWatchStore.canonicalVarPath(file.fileURL.standardizedFileURL.path)
                            AdWhitelistStore.shared.addPathRule(rawPath: canon)
                            Haptic.shared.notify(.success)
                            Alertinator.shared.alert(
                                title: LocalizationManager.isEnglish ? "Added to Ad Whitelist" : "已加入广告白名单",
                                body: LocalizationManager.isEnglish
                                    ? "\"\(file.name)\" will be skipped by global Lock All in Splash Ad Blocker."
                                    : "路径「\(file.name)」已加入广告锁定白名单，执行一键全锁时会自动跳过。"
                            )
                        }
                    } label: {
                        Label(
                            isWhitelisted
                                ? (LocalizationManager.isEnglish ? "Remove from Ad Whitelist" : "移出广告白名单")
                                : (LocalizationManager.isEnglish ? "Add to Ad Whitelist" : "加入广告白名单"),
                            systemImage: isWhitelisted ? "shield.slash" : "checkmark.shield"
                        )
                    }
                }
                
                Divider()
                
                Button(role: .destructive) {
                    promptDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var normalFileRowContent: some View {
        HStack(spacing: isSolariumUI() ? 12 : 10) {
            Image(systemName: file.type == .symlink ? "arrow.up.right.circle" : (conformsZip ? "doc.zipper" : "doc"))
                .frame(width: 20, alignment: .center)
                .foregroundStyle(file.hidden ? .secondary : .primary)
            
            VStack(alignment: .leading) {
                Text(file.name)
                    .foregroundStyle(file.hidden ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file {
                    Text(file.modifiedDateStr)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if file.type == .file {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
    }

    private var selectionRowContent: some View {
        HStack(spacing: isSolariumUI() ? 12 : 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 24, alignment: .center)

            Image(systemName: file.type == .symlink ? "arrow.up.right.circle" : (conformsZip ? "doc.zipper" : "doc"))
                .frame(width: 20, alignment: .center)
                .foregroundStyle(file.hidden ? .secondary : .primary)
            
            VStack(alignment: .leading) {
                Text(file.name)
                    .foregroundStyle(file.hidden ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file {
                    Text(file.modifiedDateStr)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if file.type == .file {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
    }

    // MARK: - Actions

    private func promptRename() {
        if let reason = FileSafetyGuard.protectionReason(for: file.fileURL, operation: .rename) {
            Alertinator.shared.alert(
                title: LocalizationManager.isEnglish ? "Protected Item" : "受保护项目",
                body: reason
            )
            return
        }
        let targetURL = file.fileURL
        Alertinator.shared.prompt(
            title: L("请输入新的文件名："),
            placeholder: file.name,
            text: file.name
        ) { result in
            guard let name = result?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            await MainActor.run {
                onBusyChange?(LocalizationManager.isEnglish ? "Renaming..." : "正在重命名…")
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await renameItemDetailed(targetURL, to: name)
            }.value
            await MainActor.run {
                onBusyChange?(nil)
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("重命名文件失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func promptUnzip() {
        let archiveURL = file.fileURL
        let archiveName = file.name
        let extractHereTitle = LocalizationManager.isEnglish ? "Extract to Current Folder" : "解压到当前目录"
        let extractSubfolderTitle = LocalizationManager.isEnglish ? "Extract to Subfolder" : "解压到同名文件夹"

        Alertinator.shared.choose(
            title: LocalizationManager.isEnglish ? "Extract Archive?" : "确认解压缩？",
            body: LocalizationManager.isEnglish
                ? "Extract \"\(archiveName)\" into the current folder or a new subfolder?"
                : "确认要解压「\(archiveName)」吗？可选择直接解压到当前目录，或新建同名文件夹避免重名冲突。",
            actions: [
                (extractHereTitle, .default, {
                    runUnzip(archiveURL, toSubfolder: false)
                }),
                (extractSubfolderTitle, .default, {
                    runUnzip(archiveURL, toSubfolder: true)
                })
            ]
        )
    }

    private func runUnzip(_ archiveURL: URL, toSubfolder: Bool) {
        onBusyChange?(LocalizationManager.isEnglish ? "Extracting \(archiveURL.lastPathComponent)..." : "正在解压 \(archiveURL.lastPathComponent)…")
        Task.detached(priority: .userInitiated) {
            let outcome = await unzipFileDetailed(archiveURL, toSubfolder: toSubfolder)
            await MainActor.run {
                onBusyChange?(nil)
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(
                        title: L("解压缩文件失败！"),
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func runZip() {
        let sourceURL = file.fileURL
        let parentDir = sourceURL.deletingLastPathComponent()
        onBusyChange?(LocalizationManager.isEnglish ? "Compressing \(file.name)..." : "正在压缩 \(file.name)…")
        Task.detached(priority: .userInitiated) {
            let outcome = await zipItemsDetailed([sourceURL], in: parentDir)
            await MainActor.run {
                onBusyChange?(nil)
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("压缩文件失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func runDuplicate() {
        let sourceURL = file.fileURL
        onBusyChange?(LocalizationManager.isEnglish ? "Duplicating \(file.name)..." : "正在创建副本…")
        Task.detached(priority: .userInitiated) {
            let outcome = await duplicateItemDetailed(sourceURL)
            await MainActor.run {
                onBusyChange?(nil)
                switch outcome {
                case .success:
                    Haptic.shared.notify(.success)
                    mgr.refreshFiles.toggle()
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: L("创建文件副本失败！"), body: error.localizedDescription)
                }
            }
        }
    }

    private func runShare() {
        let sourceURL = file.fileURL
        onBusyChange?(LocalizationManager.isEnglish ? "Preparing share..." : "正在准备分享…")
        Task.detached(priority: .userInitiated) {
            let res = makeTempItems([sourceURL])
            await MainActor.run {
                onBusyChange?(nil)
                switch res {
                case .success(let urls):
                    presentShareSheet(with: urls)
                case .failure(let error):
                    Alertinator.shared.alert(
                        title: LocalizationManager.isEnglish ? "Share Failed" : "分享失败",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func promptDelete() {
        let targetURL = file.fileURL
        if let reason = FileSafetyGuard.protectionReason(for: targetURL, operation: .delete) {
            Alertinator.shared.alert(
                title: LocalizationManager.isEnglish ? "Protected Item" : "受保护项目",
                body: reason
            )
            return
        }

        let companionCount = (file.type == .file && SQLiteCompanionGuard.isSQLiteDatabase(targetURL))
            ? SQLiteCompanionGuard.companionURLs(for: targetURL).count
            : 0

        let title = file.type == .symlink
            ? (LocalizationManager.isEnglish ? "Delete Symlink?" : "确认删除符号链接？")
            : (LocalizationManager.isEnglish ? "Delete File?" : "确认删除文件？")

        let baseBody = LocalizationManager.isEnglish
            ? "Permanently delete \"\(file.name)\"? This action cannot be undone."
            : "确定要永久删除「\(file.name)」吗？此操作无法撤销。"

        let body: String
        if companionCount > 0 {
            let extra = LocalizationManager.isEnglish
                ? "\n\nPaired SQLite journal/WAL companion files (\(companionCount)) will also be removed together."
                : "\n\n检测到 SQLite 伴随日志/WAL 文件（\(companionCount) 个），将同步安全清理。"
            body = baseBody + extra
        } else {
            body = baseBody
        }

        Alertinator.shared.confirmDestructive(
            title: title,
            body: body,
            destructiveLabel: LocalizationManager.isEnglish ? "Delete" : "删除"
        ) {
            onBusyChange?(LocalizationManager.isEnglish ? "Deleting \(file.name)..." : "正在删除 \(file.name)…")
            Task.detached(priority: .userInitiated) {
                let report = await deleteItemsDetailed([targetURL])
                await MainActor.run {
                    onBusyChange?(nil)
                    if report.hasFailures {
                        Haptic.shared.notify(.error)
                        Alertinator.shared.alert(
                            title: L("删除文件失败！"),
                            body: report.failures.first?.reason ?? Errors.checkLogs
                        )
                    } else {
                        Haptic.shared.notify(.success)
                        mgr.refreshFiles.toggle()
                    }
                }
            }
        }
    }
}
