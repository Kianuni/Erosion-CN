//
//  PosterBoardView.swift
//  Erosion
//
//  Created by lunginspector on 8/19/26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

let pbHandler = PBHandler()

private enum CamloURL {
    static let githubRepo = "https://github.com/Kianuni/Camlo"
    static let appsJSON = "https://raw.githubusercontent.com/Kianuni/Camlo/main/apps.json"
    static let addSideStore = "https://altdirect.app/?url=https://raw.githubusercontent.com/Kianuni/Camlo/main/apps.json&r=sidestore"
    static let addAltStore = "https://altdirect.app/?url=https://raw.githubusercontent.com/Kianuni/Camlo/main/apps.json&r=altstore"
    static let addFeather = "https://altdirect.app/?url=https://raw.githubusercontent.com/Kianuni/Camlo/main/apps.json&r=feather"
}

enum PBMsg {
    static var noTendies: String { L("点击此处或底部按钮导入 .tendies 壁纸包，即可开始应用自定义锁屏壁纸。") }
    static var tooManyTendies: String { L("单次最多只能同时启用 15 张壁纸，请先取消勾选其他壁纸包后再试！") }
    static var limitWarning: String { L("你当前勾选了超过 5 张壁纸，可能导致部分壁纸无法正常显示。确定仍要继续应用吗？") }
    static var corruption: String { L("请确认所选壁纸包未损坏后重试。") }
    static var finishApply: String { L("点击继续后将自动打开 PosterBoard，请在后台多任务切换器中将其上滑关闭以完成加载。如果壁纸未显示，请在右上角“壁纸设置”中尝试重置“壁纸合集”、“水星壁纸”或“视频壁纸”。") }
    static var applyInfo: String { L("如果打开锁屏编辑后未看到导入的壁纸，请前往右上角菜单的“壁纸设置”中点击“重置壁纸合集 (Collections)”后再试。") }
    static var imprtFailed: String { L("请确认所选文件为有效的 .tendies 壁纸包后重试。") }
}

struct PosterBoardView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var langMgr = LocalizationManager.shared
    @AppStorage("pbContainerPath") private var pbContainerPath = ""
    @State private var isResolvingContainer = false
    @State private var hasContainerAccess = false
    @State private var containerLookupAttempted = false
    @State private var copiedCamloRepo = false
    @AppStorage("tendiesArray") private var tendiesArray: [TendiesObject] = []
    @AppStorage("hasShownFirstRunMsg") private var hasShownFirstRunMsg = false
    
    @State private var showImporter = false
    let columns = Array(repeating: GridItem(.flexible()), count: device.userInterfaceIdiom == .pad ? 4 : 2)

    private var isEn: Bool { langMgr.isEnglish }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                camloGuideCard
                    .padding(.horizontal, 15)
                    .padding(.top, 8)

                containerStatusBanner
                    .padding(.horizontal, 15)

                if tendiesArray.isEmpty {
                    Button {
                        ensureLocalPBDirs()
                        showImporter = true
                    } label: {
                        VStack(alignment: .leading) {
                            CompactAlert(title: L("尚未导入壁纸包"), symbol: "exclamationmark.triangle.fill", text: PBMsg.noTendies)
                                .padding(.horizontal, 15)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    }
                }

                LazyVGrid(columns: columns) {
                    ForEach($tendiesArray) { $tendies in
                        Button {
                            if !tendies.isOn && tendiesArray.filter({ $0.isOn }).flatMap({ $0.descrNames }).count > 15 {
                                Alertinator.shared.alert(title: L("已达壁纸数量上限！"), body: PBMsg.tooManyTendies)
                            } else {
                                tendies.isOn.toggle()
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: tendies.targetDescr == .photos ? "play.rectangle" : "photo")
                                    .imageScale(.large)
                                    .foregroundStyle(Color.accentColor)
                                VStack {
                                    Text(tendies.name)
                                        .lineLimit(1)
                                        .fontWeight(.medium)
                                    Text("共 \(tendies.descrNames.count) 张壁纸")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                            .padding(.vertical, 10)
                            .background {
                                if tendies.targetDescr == .mercury {
                                    VStack {
                                        Text("M")
                                            .font(.footnote)
                                            .padding(6)
                                            .background(Color.accentColor)
                                            .clipShape(.circle)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .frame(maxHeight: .infinity)
                                    .padding(12)
                                }
                            }
                            .background {
                                RoundedRectangle(cornerRadius: 26)
                                    .fill(Color(.secondarySystemBackground))
                                    .overlay {
                                        if tendies.isOn {
                                            RoundedRectangle(cornerRadius: 26)
                                                .fill(Color.clear)
                                                .strokeBorder(lineWidth: 2)
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                            }
                            .contextMenu {
                                Button {
                                    let url = AppURL.pbFolders.appendingPathComponent(tendies.folderName)
                                    fsHandlers.openInFilesApp(url)
                                } label: {
                                    Label("在“文件”中查看目录", systemImage: "folder")
                                }
                                
                                Button(role: .destructive) {
                                    withAnimation {
                                        let url = AppURL.pbFolders.appendingPathComponent(tendies.folderName)
                                        try? fm.removeItem(at: url)
                                        tendiesArray.removeAll { $0.id == tendies.id }
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 15)
                .foregroundStyle(Color(.label))
            }
            .padding(.bottom, 8)
        }
        .navigationTitle("自定义锁屏壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureLocalPBDirs()
            if !hasContainerAccess || pbContainerPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvePosterBoardContainer(forceRefresh: false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button {
                    ensureLocalPBDirs()
                    showImporter = true
                } label: {
                    ButtonLabel(L("导入 .tendies 壁纸包"), symbol: "arrow.down.doc")
                }
            }
            .buttonStyle(ActionButtonStyle())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        ensureLocalPBDirs()
                        showImporter = true
                    } label: {
                        Label("导入 .tendies 壁纸包", systemImage: "arrow.down.doc")
                    }
                    
                    Button {
                        openApp(withBID: SysBID.poster)
                    } label: {
                        Label("打开 PosterBoard", systemImage: "arrow.up.right.square")
                    }
                    
                    Divider()
                    
                    NavigationLink {
                        List {
                            Section {
                                TextField("PosterBoard 容器路径", text: $pbContainerPath, axis: .vertical)
                                    .onChange(of: pbContainerPath) { _, newPath in
                                        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
                                        hasContainerAccess = !trimmed.isEmpty && wq.grantAccess(path: trimmed).0 && fm.fileExists(atPath: trimmed)
                                        containerLookupAttempted = true
                                    }
                                Button {
                                    resolvePosterBoardContainer(forceRefresh: true)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(isResolvingContainer
                                             ? (isEn ? "Locating Container..." : "正在重新获取路径...")
                                             : L("重新获取路径"))
                                        if isResolvingContainer {
                                            Spacer()
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                }
                                .disabled(isResolvingContainer)
                            } header: {
                                HeaderLabel("PosterBoard", symbol: "photo")
                            }
                            
                            Section {
                                Button("清空已导入列表") {
                                    for object in tendiesArray {
                                        let url = AppURL.pbFolders.appendingPathComponent(object.folderName)
                                        try? fm.removeItem(at: url)
                                    }
                                    tendiesArray.removeAll()
                                }
                                Button("重置壁纸合集 (Collections)", role: .destructive) {
                                    let res = resetWallpapers(for: PBPath.wpKit)
                                    if res {
                                        Haptic.shared.play(.soft)
                                    }
                                }
                                .disabled(!hasContainerAccess || pbContainerPath.isEmpty || isResolvingContainer)
                                Button("重置水星壁纸 (MercuryPoster)", role: .destructive) {
                                    let res = resetWallpapers(for: PBPath.mercury)
                                    if res {
                                        Haptic.shared.play(.soft)
                                    }
                                }
                                .disabled(!hasContainerAccess || pbContainerPath.isEmpty || isResolvingContainer)
                                Button("重置视频壁纸 (Videos)", role: .destructive) {
                                    let res = resetWallpapers(for: PBPath.photos)
                                    if res {
                                        Haptic.shared.play(.soft)
                                    }
                                }
                                .disabled(!hasContainerAccess || pbContainerPath.isEmpty || isResolvingContainer)
                            } header: {
                                HeaderLabel(L("数据管理"), symbol: "loupe")
                            } footer: {
                                Text("如果应用自定义壁纸后无法正常显示，可尝试重置上方任意对应类型的壁纸扩展缓存。")
                            }
                        }
                        .navigationTitle("壁纸设置")
                    } label: {
                        Label("壁纸设置", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button("应用", role: .adaptiveConfirm) {
                    ensureLocalPBDirs()
                    if isResolvingContainer {
                        Alertinator.shared.alert(
                            title: isEn ? "Locating PosterBoard Container" : "正在定位系统容器",
                            body: isEn
                                ? "PosterBoard container lookup is still running in the background. Please try again once locating finishes."
                                : "系统正在后台定位 PosterBoard 容器路径，请稍候待定位完成后再点击「应用」。",
                            showCancel: false
                        )
                        return
                    }
                    let trimmedPath = pbContainerPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard hasContainerAccess, !trimmedPath.isEmpty else {
                        Alertinator.shared.alert(
                            title: L("无法访问 PosterBoard 容器！"),
                            body: isEn
                                ? "Could not locate or authorize com.apple.PosterBoard yet. Tap Retry Lookup or configure the path in top-right Wallpaper Settings."
                                : "未能定位或授权 com.apple.PosterBoard 容器。请点击“重新定位”，或前往右上角“壁纸设置”检查路径与权限。",
                            actionLabel: isEn ? "Retry Lookup" : "重新定位",
                            action: {
                                resolvePosterBoardContainer(forceRefresh: true)
                            }
                        )
                        return
                    }

                    if !hasShownFirstRunMsg {
                        Alertinator.shared.alert(title: L("操作提示"), body: PBMsg.applyInfo, actionLabel: L("继续"), action: {
                            hasShownFirstRunMsg = true
                            proceed()
                        })
                    } else if tendiesArray.filter({ $0.isOn }).flatMap({ $0.descrNames }).count > 5 {
                        Alertinator.shared.alert(title: L("操作提示"), body: PBMsg.limitWarning, actionLabel: L("确认"), action: {
                            proceed()
                        })
                    } else {
                        proceed()
                    }
                    
                    @MainActor
                    func proceed() {
                        let res = applyObjects(tendiesArray.filter { $0.isOn })
                        if !res.0 {
                            if res.1.contains("an item with the same name already exists") || res.1.contains("已经存在") {
                                Alertinator.shared.alert(title: L("应用壁纸失败！"), body: L("所选的部分壁纸此前已添加过，请勿重复添加。"))
                            } else {
                                Alertinator.shared.alert(title: L("应用壁纸失败！"), body: res.1.isEmpty ? PBMsg.corruption : res.1)
                            }
                        } else {
                            Haptic.shared.play(.soft)
                            Alertinator.shared.alert(title: L("请重启 PosterBoard 以完成应用！"), body: PBMsg.finishApply, showCancel: false, actionLabel: L("继续"), action: { openApp(withBID: SysBID.poster) })
                        }
                    }
                }
                .disabled(tendiesArray.filter({ $0.isOn }).isEmpty)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            ensureLocalPBDirs()
            let res = handleImport(result)
            if !res {
                Alertinator.shared.alert(title: L("导入 .tendies 壁纸包失败！"), body: PBMsg.imprtFailed)
            }
        }
    }

    private var camloGuideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles.tv.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isEn ? "Want Live Video, Reveal & 3D Depth Lock Screens? Try Camlo" : "想要实况动态 / 3D 景深锁屏？试试 Camlo · 开幕")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(isEn
                         ? "Companion open-source lock-screen studio (~9 MB): turn Live Photos & videos into swipe-reveal and 3D depth dynamic wallpapers on-device, browse 385+ free cloud & museum wallpapers, and apply directly or export .tendies packages."
                         : "同系列开源动态锁屏工坊（~9 MB）：免电脑将相册视频、实况照片一键制作为上滑揭幕变身与裸眼 3D 景深动态壁纸，免费直连 385+ 款云端与馆藏壁纸，支持直接写入锁屏或导出 .tendies 包。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    camloGitHubButton
                    camloRepoMenu
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    camloGitHubButton
                    camloRepoMenu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var camloGitHubButton: some View {
        Button {
            if let url = URL(string: CamloURL.githubRepo) {
                openURL(url)
            }
        } label: {
            Label(isEn ? "Get on GitHub" : "前往 GitHub", systemImage: "arrow.up.right.square.fill")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var camloRepoMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = CamloURL.appsJSON
                Haptic.shared.play(.soft)
                copiedCamloRepo = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    copiedCamloRepo = false
                }
            } label: {
                Label(isEn ? "Copy Repo Source URL" : "复制软件源地址 (apps.json)", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                if let url = URL(string: CamloURL.addSideStore) {
                    openURL(url)
                }
            } label: {
                Label(isEn ? "Add to SideStore" : "一键添加至 SideStore", systemImage: "plus.circle")
            }

            Button {
                if let url = URL(string: CamloURL.addAltStore) {
                    openURL(url)
                }
            } label: {
                Label(isEn ? "Add to AltStore" : "一键添加至 AltStore", systemImage: "plus.circle")
            }

            Button {
                if let url = URL(string: CamloURL.addFeather) {
                    openURL(url)
                }
            } label: {
                Label(isEn ? "Add to Feather" : "一键添加至 Feather", systemImage: "plus.circle")
            }
        } label: {
            Label(
                copiedCamloRepo
                    ? (isEn ? "Source Copied" : "已复制源地址")
                    : (isEn ? "Add Repo Source" : "订阅软件源"),
                systemImage: copiedCamloRepo ? "checkmark" : "plus.app"
            )
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var containerStatusBanner: some View {
        if isResolvingContainer {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(isEn
                     ? "Locating PosterBoard container in background (you can import .tendies packages right away)…"
                     : "正在后台定位 PosterBoard 系统容器（可先直接导入壁纸包）…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
            )
        } else if containerLookupAttempted && !hasContainerAccess {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(isEn
                     ? "PosterBoard container not located yet. You can still import .tendies packages; tap Retry before applying to Lock Screen."
                     : "暂未定位到 PosterBoard 容器，仍可先导入管理壁纸包；应用到锁屏前请点击重试，或在「壁纸设置」中配置路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(isEn ? "Retry" : "重试") {
                    resolvePosterBoardContainer(forceRefresh: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }
    
    private func ensureLocalPBDirs() {
        if !fm.fileExists(atPath: AppURL.pb.path) || !fm.fileExists(atPath: AppURL.pbFolders.path) {
            do {
                try fm.createDirIfNeeded(at: AppURL.pb)
                try fm.createDirIfNeeded(at: AppURL.pbFolders)
            } catch {
                Alertinator.shared.alert(title: L("初始化壁纸目录失败！"), body: AppMsg.opFailed)
            }
        }
    }

    private func resolvePosterBoardContainer(forceRefresh: Bool = false) {
        guard !isResolvingContainer else { return }
        let initialCachedPath = forceRefresh ? "" : pbContainerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        isResolvingContainer = true

        DispatchQueue.global(qos: .userInitiated).async {
            if forceRefresh {
                CSStoreEngine.shared.invalidate()
                fsHandlers.invalidateCache()
            }

            var resolvedPath = initialCachedPath
            var accessOK = false
            if !resolvedPath.isEmpty {
                let grant = wq.grantAccess(path: resolvedPath)
                if grant.0 && fm.fileExists(atPath: resolvedPath) {
                    accessOK = true
                } else {
                    resolvedPath = ""
                }
            }
            if resolvedPath.isEmpty {
                let fetched = fsHandlers.getContainerPath(forMatch: "com.apple.PosterBoard")
                if !fetched.isEmpty {
                    resolvedPath = fetched
                    let grant = wq.grantAccess(path: resolvedPath)
                    accessOK = grant.0 && fm.fileExists(atPath: resolvedPath)
                }
            }

            DispatchQueue.main.async {
                if !resolvedPath.isEmpty {
                    pbContainerPath = resolvedPath
                } else if forceRefresh {
                    pbContainerPath = ""
                }
                hasContainerAccess = accessOK
                containerLookupAttempted = true
                isResolvingContainer = false
            }
        }
    }
    
    private func applyObjects(_ objects: [TendiesObject]) -> (Bool, String) {
        let containerPath = pbContainerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerPath.isEmpty else {
            return (false, L("未找到 PosterBoard 容器路径。"))
        }
        let rootGrant = wq.grantAccess(path: containerPath)
        if !rootGrant.0 {
            print("(pb) failed to grant access to container root \(containerPath): \(rootGrant.2)")
            return (false, rootGrant.2)
        }
        
        let descrTargets = Set(objects.map(\.targetDescr))
        var resolvedTargetDirs: [PBPath: URL] = [:]
        for descrTarget in descrTargets {
            let relPath = descrTarget.resolvedPath(in: containerPath)
            let targetURL = URL(fileURLWithPath: containerPath).appendingPathComponent(relPath)
            do {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } catch {
                print("(pb) failed to create target directory \(targetURL.path): \(error.localizedDescription)")
                return (false, error.localizedDescription)
            }
            if fm.fileExists(atPath: targetURL.path) {
                let res = wq.grantAccess(path: targetURL.path)
                if !res.0 {
                    print("(pb) failed to grant access at \(targetURL.path): \(res.2)")
                    return (false, res.2)
                }
            }
            resolvedTargetDirs[descrTarget] = targetURL
        }
        
        for object in objects {
            guard let containerURL = resolvedTargetDirs[object.targetDescr] else { continue }
            for descr in object.descrNames {
                let descrURL = AppURL.pbFolders.appendingPathComponent(object.folderName).appendingPathComponent(descr)
                let target = object.targetDescr == .mercury ? containerURL.appendingPathComponent(descrURL.lastPathComponent) : containerURL.appendingPathComponent(UUID().uuidString)
                do {
                    try fm.copyItem(at: descrURL, to: target)
                } catch {
                    print("(pb) failed to copy descriptor (folder: \(object.folderName)): \(error.localizedDescription)")
                    return (false, error.localizedDescription)
                }
            }
        }
        return (true, "")
    }
    
    private func resetWallpapers(for item: PBPath) -> Bool {
        let containerPath = pbContainerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerPath.isEmpty else {
            Alertinator.shared.alert(title: L("重置壁纸失败！"), body: L("未找到 PosterBoard 容器路径。"))
            return false
        }
        let rootGrant = wq.grantAccess(path: containerPath)
        if !rootGrant.0 {
            Alertinator.shared.alert(title: L("重置壁纸失败！"), body: L("无法获取 PosterBoard 容器权限：\(rootGrant.2)"))
            return false
        }
        let relPath = item.resolvedPath(in: containerPath)
        let target = URL(fileURLWithPath: containerPath).appendingPathComponent(relPath)
        if !fm.fileExists(atPath: target.path) {
            return true
        }
        let targetGrant = wq.grantAccess(path: target.path)
        if !targetGrant.0 {
            Alertinator.shared.alert(title: L("重置壁纸失败！"), body: L("无法获取目标壁纸目录权限：\(targetGrant.2)"))
            return false
        }
        do {
            let contents = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            
            for url in contents {
                try fm.removeItem(at: url)
            }
            return true
        } catch {
            print("(pb) failed to reset \(item.rawValue): \(error.localizedDescription)")
            Alertinator.shared.alert(title: L("重置壁纸失败！"), body: error.localizedDescription)
            return false
        }
    }
    
    private func handleImport(_ result: Result<URL, Error>) -> Bool {
        switch result {
        case .success(let fileURL):
            let stopAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            if let tendies = pbHandler.makeObjectFromTendies(at: fileURL) {
                withAnimation {
                    tendiesArray.append(tendies)
                }
                return true
            }
            return false
        case .failure(let error):
            print("(pb) failed to import file: \(error.localizedDescription)")
            return false
        }
    }
}

