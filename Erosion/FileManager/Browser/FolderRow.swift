//
//  FolderRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import QuickLook
import ZIPFoundation

struct FolderRow: View {
    @EnvironmentObject var mgr: ErosionManager
    var file: FileItem
    var shouldGrant: Bool
    var isContainer: Bool = false
    
    @State private var previewURL: URL?
    @State private var folderType: FolderType = .normal
    
    @State private var showInfo = false
    @State private var showWiFiShare = false
    
    var body: some View {
        NavigationLink(destination: FileBrowserView(path: file.destURL, shouldGrant: shouldGrant)) {
            HStack(spacing: isSolariumUI() ? 12 : 10) {
                Group {
                    Image(systemName: "folder")
                        .frame(width: 20, alignment: .center)
                        .foregroundStyle(file.hidden ? .secondary : .primary)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(file.hidden ? .secondary : .primary)
                }
                
                Spacer()
                
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(file.hidden ? .secondary : .primary)
            }
        }
        .foregroundStyle(Color(.label))
        .onAppear {
            folderType = getFolderType(url: file.fileURL)
        }
        .sheet(isPresented: $showInfo) {
            InfoViewer(file)
        }
        .sheet(isPresented: $showWiFiShare) {
            WiFiShareSheet(rootURL: file.destURL)
        }
        .quickLookPreview($previewURL)
        .contextMenu {
            if !isContainer {
                Button {
                    previewURL = file.fileURL
                } label: {
                    Label("快速查看", systemImage: "eye")
                }
                
                Divider()
                
                Button {
                    showInfo.toggle()
                } label: {
                    Label("显示简介", systemImage: "info.circle")
                }
                
                Button {
                    let res = zipFile(file.fileURL)
                    if res {
                        mgr.refreshFiles.toggle()
                    } else {
                        Alertinator.shared.alert(title: L("压缩文件夹失败！"), body: Errors.checkLogs)
                    }
                } label: {
                    Label("压缩为 ZIP", systemImage: "archivebox")
                }
                
                Divider()
                
                Button {
                    if let url = makeTemp(file.fileURL) {
                        presentShareSheet(with: url)
                    }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }

                Button {
                    showWiFiShare = true
                } label: {
                    Label(
                        LocalizationManager.isEnglish ? "Wi-Fi File Sharing" : "Wi-Fi 无线传输",
                        systemImage: "wifi"
                    )
                }

                if AdCustomWatchStore.shared.canAddAsCustomTarget(url: file.fileURL, owner: file.owner) {
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
                                    ? "Manage or lock \"\(file.name)\" anytime in Splash Ad Blocker."
                                    : "已收藏目录「\(file.name)」，可在「开屏广告缓存精准锁死」页直接管理或一键锁死。"
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
                                    : "目录「\(file.name)」已加入广告锁定白名单，执行一键全锁时会自动跳过。"
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
                    try? fm.removeItem(at: file.fileURL)
                    mgr.refreshFiles.toggle()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }
}
