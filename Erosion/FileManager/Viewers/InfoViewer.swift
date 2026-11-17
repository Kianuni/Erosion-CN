//
//  FileInfoSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import Darwin
import UIKit
import UniformTypeIdentifiers

private nonisolated func canonicalizeVarPrefix(_ rawPath: String) -> String {
    var p = (rawPath as NSString).standardizingPath
    if p.hasPrefix("/private/var/") {
        p = String(p.dropFirst("/private".count))
    } else if p == "/private/var" {
        p = "/var"
    }
    return p
}

nonisolated func canSafelyModifyPermissions(url: URL, owner: String) -> Bool {
    guard owner == "mobile" else { return false }

    var st = stat()
    if lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
        return false
    }

    let stdPath = canonicalizeVarPrefix(url.standardizedFileURL.path)
    let resolvedPath = canonicalizeVarPrefix(url.resolvingSymlinksInPath().path)
    let docsStd = canonicalizeVarPrefix(URL.documentsDirectory.standardizedFileURL.path)
    let docsResolved = canonicalizeVarPrefix(URL.documentsDirectory.resolvingSymlinksInPath().path)

    func isSafeCanonicalPath(_ path: String) -> Bool {
        // Explicit safety blocklist for system & privileged containers
        let forbiddenPrefixes = [
            "/var/containers/Shared/SystemGroup",
            "/var/containers/Bundle",
            "/var/mobile/Containers/Data/InternalDaemon",
            "/var/mobile/Containers/Data/PluginKitPlugin",
            "/var/containers/Data/System",
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/Library",
            "/etc"
        ]
        for forbidden in forbiddenPrefixes {
            if path == forbidden || path.hasPrefix(forbidden + "/") {
                return false
            }
        }

        let allowedContainerRoots = [
            "/var/mobile/Containers/Data/Application/",
            "/var/mobile/Containers/Shared/AppGroup/"
        ]
        for base in allowedContainerRoots {
            if path.hasPrefix(base) {
                let rel = String(path.dropFirst(base.count))
                let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
                // Require at least <UUID>/<subitem>, never the <UUID> container root itself
                guard parts.count >= 2,
                      !parts[0].isEmpty,
                      parts[0] != ".",
                      parts[0] != ".." else {
                    return false
                }
                return true
            }
        }

        if path.hasPrefix(docsStd + "/") || path.hasPrefix(docsResolved + "/") {
            return true
        }

        return false
    }

    return isSafeCanonicalPath(stdPath) && isSafeCanonicalPath(resolvedPath)
}

struct InfoViewer: View {
    @Environment(\.dismiss) var dismiss
    var file: FileItem

    @State private var currentMode: Int
    @State private var draftMode: Int
    @State private var currentOwner: String
    @State private var currentGroup: String
    @State private var currentReadable: Bool
    @State private var currentWritable: Bool
    @State private var currentExecutable: Bool
    @State private var hasAdSentinel = false
    @State private var applyNotice: String?
    @State private var applyIsError = false
    @State private var didGrantTempWrite = false

    init(_ file: FileItem) {
        self.file = file
        let parsedMode = Int(file.posixPerms, radix: 8) ?? (file.type == .folder ? 0o755 : 0o644)
        _currentMode = State(initialValue: parsedMode)
        _draftMode = State(initialValue: parsedMode & 0o777)
        _currentOwner = State(initialValue: file.owner)
        _currentGroup = State(initialValue: file.group)
        _currentReadable = State(initialValue: file.readable)
        _currentWritable = State(initialValue: file.writable)
        _currentExecutable = State(initialValue: file.executable)
    }

    private var isDirectoryItem: Bool {
        file.type == .folder
    }

    private var canEditPermissions: Bool {
        file.type != .symlink && canSafelyModifyPermissions(url: file.fileURL, owner: currentOwner)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    StringInfoCell(file.name, label: "名称")
                    StringInfoCell(file.fileURL.path, label: "路径")
                    if file.type == .symlink {
                        StringInfoCell(file.destURL.path, label: "目标路径")
                    }
                    if file.type == .file {
                        StringInfoCell("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))", label: "大小")
                    }
                }
                
                Section {
                    StringInfoCell(file.uttype.identifier, label: "类型标识符 (UTType)")
                    StringInfoCell(file.creationDateStr, label: "创建时间")
                    StringInfoCell(file.modifiedDateStr, label: "修改时间")
                    BoolInfoCell(file.type == .symlink, label: "符号链接")
                } header: {
                    HeaderLabel("文件属性", symbol: "doc")
                }
                
                Section {
                    StringInfoCell(String(format: "%04o", currentMode & 0o7777), label: "POSIX 权限")
                    StringInfoCell(currentOwner, label: "所有者")
                    StringInfoCell(currentGroup, label: "所属组")
                    BoolInfoCell(currentReadable, label: "可读")
                    BoolInfoCell(currentWritable, label: "可写")
                    BoolInfoCell(currentExecutable, label: "可执行")
                    if hasAdSentinel {
                        StringInfoCell(
                            LocalizationManager.isEnglish ? "Active (.erosion_adlock)" : "已生效 (.erosion_adlock)",
                            label: LocalizationManager.isEnglish ? "Anti-Recreate Lock" : "防重建保护"
                        )
                    }
                } header: {
                    HeaderLabel("权限信息", symbol: "shield")
                } footer: {
                    if !canEditPermissions {
                        Text(
                            LocalizationManager.isEnglish
                                ? "Read-only protection: POSIX chmod editing is disabled for system paths, container roots, symlinks, and non-mobile owners."
                                : "安全保护：当前路径属于系统目录、容器根目录、符号链接或非 mobile 所有者，已锁定为只读，禁止修改 POSIX 权限。"
                        )
                    }
                }

                if canEditPermissions {
                    chmodSection
                }
            }
            .navigationTitle("\(file.type.label)简介")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
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
                refreshLivePermissions()
            }
            .onDisappear {
                if didGrantTempWrite {
                    wq.releaseAccess(path: file.fileURL.path)
                    didGrantTempWrite = false
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var chmodSection: some View {
        let readOnlyMode = isDirectoryItem ? 0o555 : 0o444
        let readWriteMode = isDirectoryItem ? 0o755 : 0o644
        let liveLowBits = currentMode & 0o777
        let isAlreadyReadOnly = (liveLowBits == readOnlyMode)
        let isAlreadyReadWrite = (liveLowBits == readWriteMode) && !hasAdSentinel

        Section {
            Button {
                draftMode = readOnlyMode
                applyPermissions(readOnlyMode)
            } label: {
                if isAlreadyReadOnly {
                    Label(
                        hasAdSentinel
                            ? (LocalizationManager.isEnglish
                                ? "Read-Only & Sentinel Active (\(String(format: "%04o", readOnlyMode)))"
                                : "当前已是只读防重建锁死状态 (\(String(format: "%04o", readOnlyMode)))")
                            : (LocalizationManager.isEnglish
                                ? "Already Read-Only (\(String(format: "%04o", readOnlyMode)))"
                                : "当前已是只读锁死状态 (\(String(format: "%04o", readOnlyMode)))"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Label(
                        LocalizationManager.isEnglish
                            ? "Set Read-Only (\(String(format: "%04o", readOnlyMode)))"
                            : "设为只读 (锁死广告缓存 \(String(format: "%04o", readOnlyMode)))",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .disabled(isAlreadyReadOnly)

            Button {
                draftMode = readWriteMode
                applyPermissions(readWriteMode)
            } label: {
                if isAlreadyReadWrite {
                    Label(
                        LocalizationManager.isEnglish
                            ? "Already Default Read-Write (\(String(format: "%04o", readWriteMode)))"
                            : "当前已是默认可读写状态 (\(String(format: "%04o", readWriteMode)))",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        LocalizationManager.isEnglish
                            ? "Restore Read-Write (\(String(format: "%04o", readWriteMode)))"
                            : "恢复默认读写 (\(String(format: "%04o", readWriteMode)))",
                        systemImage: "lock.open.fill"
                    )
                }
            }
            .disabled(isAlreadyReadWrite)

            PermissionBitRow(
                title: LocalizationManager.isEnglish ? "Owner (u)" : "所有者 (u)",
                shift: 6,
                mode: $draftMode
            )
            PermissionBitRow(
                title: LocalizationManager.isEnglish ? "Group (g)" : "所属组 (g)",
                shift: 3,
                mode: $draftMode
            )
            PermissionBitRow(
                title: LocalizationManager.isEnglish ? "Others (o)" : "其他人 (o)",
                shift: 0,
                mode: $draftMode
            )

            HStack {
                Text(LocalizationManager.isEnglish ? "Octal Mode" : "八进制权限")
                Spacer()
                Text(String(format: "%04o", draftMode & 0o777))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())

                Button {
                    applyPermissions(draftMode)
                } label: {
                    Text(LocalizationManager.isEnglish ? "Apply" : "应用权限")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled((draftMode & 0o777) == liveLowBits)
            }

            if let applyNotice {
                Label(
                    applyNotice,
                    systemImage: applyIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(applyIsError ? .red : .green)
            }
        } header: {
            HeaderLabel(
                LocalizationManager.isEnglish ? "Modify Permissions (chmod)" : "权限修改 (POSIX chmod)",
                symbol: "lock.shield"
            )
        } footer: {
            Text(
                LocalizationManager.isEnglish
                    ? "Note: Read-only mode (0555/0444) only blocks splash ads cached to local disk directories. Server-fetched or in-memory ads are unaffected."
                    : "客观提示：只读模式（0555/0444）仅能拦截写入本地缓存目录的开屏广告；对于服务端实时下发或直接走内存加载的广告无效。"
            )
        }
    }

    private func checkHasAdSentinel(atPath path: String) -> Bool {
        guard isDirectoryItem else { return false }
        let sentinelPath = (path as NSString).appendingPathComponent(".erosion_adlock")
        var sSt = stat()
        return lstat(sentinelPath, &sSt) == 0 && ((sSt.st_mode & S_IFMT) == S_IFREG)
    }

    private func refreshLivePermissions() {
        let targetPath = file.fileURL.path
        var st = stat()
        if lstat(targetPath, &st) == 0 {
            let liveMode = Int(st.st_mode) & 0o7777
            currentMode = liveMode
            draftMode = liveMode & 0o777
        }
        if let attrs = try? fm.attributesOfItem(atPath: targetPath) {
            if let owner = attrs[.ownerAccountName] as? String {
                currentOwner = owner
            }
            if let group = attrs[.groupOwnerAccountName] as? String {
                currentGroup = group
            }
        }
        currentReadable = fm.isReadableFile(atPath: targetPath)
        currentWritable = fm.isWritableFile(atPath: targetPath)
        currentExecutable = fm.isExecutableFile(atPath: targetPath)
        hasAdSentinel = checkHasAdSentinel(atPath: targetPath)
    }

    private func applyPermissions(_ targetMode: Int) {
        guard canEditPermissions else {
            applyIsError = true
            applyNotice = LocalizationManager.isEnglish
                ? "Blocked: path is outside editable app containers."
                : "已拦截：目标路径不在允许修改权限的安全容器范围内。"
            Haptic.shared.notify(.error)
            return
        }

        let targetPath = file.fileURL.path
        let desired = targetMode & 0o777

        let stdPath = canonicalizeVarPrefix(file.fileURL.standardizedFileURL.path)
        let docsStd = canonicalizeVarPrefix(URL.documentsDirectory.standardizedFileURL.path)
        let isInOwnDocuments = stdPath.hasPrefix(docsStd + "/")

        let wasActive = wq.hasActiveAccess(path: targetPath)
        let grantRes = wq.grantAccess(path: targetPath, requireWrite: true)
        if !wasActive && grantRes.1 >= 0 {
            didGrantTempWrite = true
        }

        // Note: on 0444/0555 files, worse_query issues the write sandbox token (res >= 0)
        // even though fm.isWritableFile returns false due to the read-only POSIX mode bits.
        guard grantRes.0 || grantRes.1 >= 0 || isInOwnDocuments else {
            applyIsError = true
            applyNotice = LocalizationManager.isEnglish
                ? "Sandbox grant failed: \(grantRes.2)"
                : "沙盒授权失败：\(grantRes.2)"
            Haptic.shared.notify(.error)
            return
        }

        let rc = Darwin.chmod(targetPath, mode_t(desired))
        guard rc == 0 else {
            let errText = String(cString: strerror(errno))
            applyIsError = true
            applyNotice = LocalizationManager.isEnglish
                ? "chmod failed: \(errText)"
                : "chmod 修改失败：\(errText)"
            Haptic.shared.notify(.error)
            return
        }

        if isDirectoryItem && (desired & 0o200) != 0 && checkHasAdSentinel(atPath: targetPath) {
            let sentinelPath = (targetPath as NSString).appendingPathComponent(".erosion_adlock")
            _ = Darwin.chmod(sentinelPath, 0o644)
            _ = Darwin.unlink(sentinelPath)
        }

        var st = stat()
        guard lstat(targetPath, &st) == 0 else {
            applyIsError = true
            applyNotice = LocalizationManager.isEnglish
                ? "Failed to verify permissions via lstat."
                : "lstat 校验新权限失败。"
            Haptic.shared.notify(.error)
            return
        }

        let verifiedMode = Int(st.st_mode) & 0o7777
        currentMode = verifiedMode
        draftMode = verifiedMode & 0o777
        currentReadable = fm.isReadableFile(atPath: targetPath)
        currentWritable = fm.isWritableFile(atPath: targetPath)
        currentExecutable = fm.isExecutableFile(atPath: targetPath)
        hasAdSentinel = checkHasAdSentinel(atPath: targetPath)

        guard (verifiedMode & 0o777) == desired else {
            applyIsError = true
            applyNotice = LocalizationManager.isEnglish
                ? "Mode mismatch after chmod: got \(String(format: "%04o", verifiedMode))."
                : "权限校验不一致：实际为 \(String(format: "%04o", verifiedMode))。"
            Haptic.shared.notify(.warning)
            return
        }

        applyIsError = false
        applyNotice = LocalizationManager.isEnglish
            ? "Permissions updated to \(String(format: "%04o", verifiedMode))."
            : "已成功更新权限为 \(String(format: "%04o", verifiedMode))"
        Haptic.shared.notify(.success)
        print("(chmod) updated \(targetPath) -> \(String(format: "%04o", verifiedMode))")
        ErosionManager.shared.refreshFiles.toggle()
    }

    private struct PermissionBitRow: View {
        let title: String
        let shift: Int
        @Binding var mode: Int

        var body: some View {
            HStack {
                Text(title)
                Spacer()
                HStack(spacing: 8) {
                    bitButton("r", bit: 0o4 << shift)
                    bitButton("w", bit: 0o2 << shift)
                    bitButton("x", bit: 0o1 << shift)
                }
            }
        }

        @ViewBuilder
        private func bitButton(_ label: String, bit: Int) -> some View {
            let isSet = (mode & bit) != 0
            Button {
                mode ^= bit
            } label: {
                Text(label)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .frame(width: 32, height: 28)
                    .background(
                        isSet ? Color.accentColor : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .foregroundStyle(isSet ? Color.white : Color.primary)
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(isSet ? .isSelected : [])
        }
    }
    
    private struct StringInfoCell: View {
        var string: String
        var label: String
        
        init(_ string: String, label: String) {
            self.string = string
            self.label = label
        }
        
        var body: some View {
            HStack {
                Text(label.loc)
                Spacer()
                Text(string)
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = string
                } label: {
                    Label("复制内容", systemImage: "doc.on.doc")
                }
            }
        }
    }
    
    private struct BoolInfoCell: View {
        var bool: Bool
        var label: String
        
        init(_ bool: Bool, label: String) {
            self.bool = bool
            self.label = label
        }
        
        var body: some View {
            HStack {
                Text(label.loc)
                Spacer()
                Image(systemName: bool ? "checkmark" : "xmark")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
