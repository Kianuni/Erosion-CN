//
//  FMRootView.swift
//  Erosion
//
//  Created by lunginspector on 8/26/26.
//

import SwiftUI
import Darwin
import UIKit

enum FSPaths {
    static let appContainers = "/var/mobile/Containers/Data/Application"
    static var appBundles = "/var/containers/Bundle/Application"
}

enum FSURL {
    static let appContainers = URL(fileURLWithPath: FSPaths.appContainers)
    static var sysGroup = URL(fileURLWithPath: "/var/containers/Shared/SystemGroup")
    static var configProfiles = FSURL.sysGroup.appendingPathComponent("systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles")
    static var internalDaemons = URL(fileURLWithPath: "/var/mobile/Containers/Data/InternalDaemon")
    static var appPlugins = URL(fileURLWithPath: "/var/mobile/Containers/Data/PluginKitPlugin")
    static var appGroup = URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup")
    static var systemData = URL(fileURLWithPath: "/var/containers/Data/System")
}

private struct GoToPathTarget: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isContainer: Bool
    let shouldGrant: Bool
}

struct FMRootView: View {
    @StateObject private var navStore = FMNavigationStore.shared
    @State private var showGoToPath = false
    @State private var goToTarget: GoToPathTarget?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showGoToPath = true
                    } label: {
                        Label(
                            LocalizationManager.isEnglish ? "Go to Path..." : "路径直达…",
                            systemImage: "arrow.forward.circle"
                        )
                    }
                    NavigationLink {
                        AdCacheBlockerView()
                    } label: {
                        Label(
                            LocalizationManager.isEnglish ? "Splash Ad Cache Blocker" : "开屏广告缓存精准锁死",
                            systemImage: "lock.shield"
                        )
                    }
                    NavigationLink("MobileGestalt 缓存目录", destination: FileBrowserView(path: MGURL.fsGestaltURL.deletingLastPathComponent(), shouldGrant: true))
                    NavigationLink("系统配置描述文件目录", destination: FileBrowserView(path: FSURL.configProfiles, shouldGrant: true))
                    NavigationLink("本应用文档目录 (Documents)", destination: FileBrowserView(path: URL.documentsDirectory))
                } header: {
                    HeaderLabel("快捷访问", symbol: "bolt")
                }

                if !navStore.recentFolders.isEmpty {
                    Section {
                        ForEach(navStore.recentFolders) { entry in
                            NavigationLink {
                                FileBrowserView(path: URL(fileURLWithPath: entry.path), shouldGrant: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(entry.title, systemImage: "clock.arrow.circlepath")
                                        .lineLimit(1)
                                    Text(entry.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .onDelete { offsets in
                            navStore.remove(at: offsets)
                        }
                    } header: {
                        HStack {
                            HeaderLabel(LocalizationManager.isEnglish ? "Recent" : "最近访问", symbol: "clock")
                            Spacer()
                            Button(LocalizationManager.isEnglish ? "Clear" : "清空") {
                                navStore.clear()
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }
                
                Section {
                    NavigationLink("应用数据容器 (Data)", destination: FileBrowserView(path: FSURL.appContainers, isContainer: true))
                    NavigationLink("插件数据容器 (Plugin)", destination: FileBrowserView(path: FSURL.appPlugins, isContainer: true))
                    NavigationLink("共享应用组 (App Groups)", destination: FileBrowserView(path: FSURL.appGroup, isContainer: true))
                } header: {
                    HeaderLabel("应用程序", symbol: "square.grid.2x2")
                }
                
                Section {
                    NavigationLink("守护进程容器 (Daemon)", destination: FileBrowserView(path: FSURL.internalDaemons, isContainer: true))
                    NavigationLink("系统数据容器 (System)", destination: FileBrowserView(path: FSURL.systemData, isContainer: true))
                    NavigationLink("系统共享组容器 (SystemGroup)", destination: FileBrowserView(path: FSURL.sysGroup, isContainer: true))
                } header: {
                    HeaderLabel("系统容器", symbol: "gear")
                }
            }
            .navigationTitle("文件浏览")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showGoToPath = true
                    } label: {
                        Label(
                            LocalizationManager.isEnglish ? "Go to Path..." : "路径直达…",
                            systemImage: "arrow.forward.circle"
                        )
                    }
                }
            }
            .sheet(isPresented: $showGoToPath) {
                GoToPathSheet { target in
                    goToTarget = target
                }
            }
            .navigationDestination(item: $goToTarget) { target in
                FileBrowserView(
                    path: target.url,
                    isContainer: target.isContainer,
                    shouldGrant: target.shouldGrant
                )
            }
        }
    }
}

private struct GoToPathSheet: View {
    var onNavigate: (GoToPathTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pathText = ""
    @State private var clipboardSuggestion: String?
    @State private var errorMessage: String?

    private static let containerRoots: Set<String> = [
        FMNavigationStore.canonicalPath(FSURL.appContainers.path),
        FMNavigationStore.canonicalPath(FSURL.appPlugins.path),
        FMNavigationStore.canonicalPath(FSURL.appGroup.path),
        FMNavigationStore.canonicalPath(FSURL.internalDaemons.path),
        FMNavigationStore.canonicalPath(FSURL.systemData.path),
        FMNavigationStore.canonicalPath(FSURL.sysGroup.path)
    ]

    var body: some View {
        NavigationStack {
            List {
                if let suggestion = clipboardSuggestion {
                    Section {
                        Button {
                            pathText = suggestion
                            navigate(to: suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(
                                    LocalizationManager.isEnglish ? "Open Clipboard Path" : "使用剪贴板路径直达",
                                    systemImage: "doc.on.clipboard"
                                )
                                .font(.subheadline.weight(.semibold))
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                    } header: {
                        HeaderLabel(
                            LocalizationManager.isEnglish ? "Clipboard Suggestion" : "剪贴板路径建议",
                            symbol: "sparkles"
                        )
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("/var/mobile/Containers/...", text: $pathText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit {
                                navigate(to: pathText)
                            }

                        if !pathText.isEmpty {
                            Button {
                                pathText = ""
                                errorMessage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        navigate(to: pathText)
                    } label: {
                        Label(
                            LocalizationManager.isEnglish ? "Open Directory" : "打开目录",
                            systemImage: "arrow.right.circle.fill"
                        )
                        .fontWeight(.semibold)
                    }
                    .disabled(pathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    HeaderLabel(
                        LocalizationManager.isEnglish ? "Target Path" : "输入目标路径",
                        symbol: "folder"
                    )
                } footer: {
                    Text(
                        LocalizationManager.isEnglish
                            ? "Enter an absolute folder path (or file path to jump to its parent folder). Automatically requests sandbox access via worse_query."
                            : "输入绝对文件夹路径（若输入文件路径则自动定位到其父目录），将自动通过 worse_query 申请沙盒访问令牌。"
                    )
                }

                if let errorMessage {
                    CompactAlert(
                        title: LocalizationManager.isEnglish ? "Cannot Open Path" : "无法打开该路径",
                        symbol: "exclamationmark.triangle",
                        text: errorMessage,
                        color: .red
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LocalizationManager.isEnglish ? "Go to Path" : "路径直达")
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
                detectClipboardPath()
            }
        }
    }

    private func detectClipboardPath() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            clipboardSuggestion = nil
            return
        }
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if unquoted.hasPrefix("/var/") || unquoted.hasPrefix("/private/var/") {
            clipboardSuggestion = unquoted
            if pathText.isEmpty {
                pathText = unquoted
            }
        } else {
            clipboardSuggestion = nil
        }
    }

    private func navigate(to rawInput: String) {
        errorMessage = nil
        let cleaned = rawInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard cleaned.hasPrefix("/") else {
            errorMessage = LocalizationManager.isEnglish
                ? "Please enter an absolute path starting with '/'."
                : "请输入以 / 开头的绝对路径。"
            return
        }

        let canonical = FMNavigationStore.canonicalPath(cleaned)
        if Self.containerRoots.contains(canonical) {
            dismiss()
            onNavigate(GoToPathTarget(
                url: URL(fileURLWithPath: canonical),
                isContainer: true,
                shouldGrant: false
            ))
            return
        }

        var targetPath = canonical
        var grantedByUs = false
        let wasActive = wq.hasActiveAccess(path: targetPath)
        if !fm.isReadableFile(atPath: targetPath) {
            let grant = wq.grantAccess(path: targetPath, requireWrite: false)
            if grant.0 && !wasActive {
                grantedByUs = true
            }
        }

        var st = stat()
        if stat(targetPath, &st) != 0 {
            if grantedByUs {
                wq.releaseAccess(path: targetPath)
            }
            errorMessage = LocalizationManager.isEnglish
                ? "Path does not exist or sandbox access was denied: \(targetPath)"
                : "目标路径不存在或无沙盒访问权限：\(targetPath)"
            return
        }

        if (st.st_mode & S_IFMT) != S_IFDIR {
            if grantedByUs {
                wq.releaseAccess(path: targetPath)
                grantedByUs = false
            }
            targetPath = URL(fileURLWithPath: targetPath).deletingLastPathComponent().path
            let parentWasActive = wq.hasActiveAccess(path: targetPath)
            if !fm.isReadableFile(atPath: targetPath) {
                let parentGrant = wq.grantAccess(path: targetPath, requireWrite: false)
                if !parentGrant.0 && !fm.isReadableFile(atPath: targetPath) {
                    errorMessage = parentGrant.2
                    return
                }
                if parentGrant.0 && !parentWasActive {
                    grantedByUs = true
                }
            }
        } else if !fm.isReadableFile(atPath: targetPath) {
            if grantedByUs {
                wq.releaseAccess(path: targetPath)
            }
            errorMessage = LocalizationManager.isEnglish
                ? "Directory cannot be read inside current sandbox."
                : "当前沙盒无权读取该目录。"
            return
        }

        let finalURL = URL(fileURLWithPath: targetPath)
        dismiss()
        onNavigate(GoToPathTarget(
            url: finalURL,
            isContainer: false,
            shouldGrant: true
        ))
    }
}
