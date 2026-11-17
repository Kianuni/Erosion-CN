//
//  APFSStagingVault.swift
//  Erosion
//
//  Feature #7: APFS clonefile() Zero-Space App Swap Vault with 5-Layer Foolproofing.
//

import Foundation
import UIKit
import Darwin
import Combine

@_silgen_name("clonefile")
nonisolated private func vault_clonefile(_ src: UnsafePointer<CChar>, _ dst: UnsafePointer<CChar>, _ flags: UInt32) -> Int32

nonisolated private let kCloneNoFollowFlag: UInt32 = 0x0001

nonisolated func apfsVaultText(_ en: String, _ zh: String) -> String {
    LocalizationManager.isEnglish ? en : zh
}

// MARK: - Layer 1: Embedded MobileProvision Certificate Status

nonisolated struct ProvisioningCertInfo: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case valid
        case expiringSoon   // < 24 hours remaining
        case expired        // <= 0 seconds remaining
        case notEmbedded    // e.g. TrollStore / permanent signing / simulator
        case parseFailed
    }

    let status: Status
    let profileName: String
    let teamName: String?
    let expirationDate: Date?
    let remainingSeconds: TimeInterval?

    var requiresUrgentResignWarning: Bool {
        status == .expiringSoon || status == .expired
    }

    var remainingDisplayText: String {
        switch status {
        case .notEmbedded:
            return apfsVaultText("No embedded profile (TrollStore / Ad-Hoc)", "未检测到描述文件 (TrollStore 永久签或自签免描述)")
        case .parseFailed:
            return apfsVaultText("Unable to parse embedded.mobileprovision", "无法解析 embedded.mobileprovision 证书载荷")
        case .expired:
            return apfsVaultText("Signing certificate EXPIRED", "签名证书已过期")
        case .expiringSoon, .valid:
            guard let remaining = remainingSeconds else {
                return apfsVaultText("Unknown", "未知")
            }
            let totalMinutes = max(0, Int(remaining / 60))
            let totalHours = totalMinutes / 60
            let days = totalHours / 24
            let hours = totalHours % 24
            let mins = totalMinutes % 60
            if days > 0 {
                return apfsVaultText("\(days)d \(hours)h remaining", "剩余 \(days) 天 \(hours) 小时")
            } else if totalHours > 0 {
                return apfsVaultText("\(totalHours)h \(mins)m remaining", "剩余 \(totalHours) 小时 \(mins) 分钟")
            } else {
                return apfsVaultText("\(mins)m remaining", "剩余 \(mins) 分钟")
            }
        }
    }

    var expirationDateFormatted: String? {
        guard let expirationDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.locale = LocalizationManager.effectiveLocale
        return fmt.string(from: expirationDate)
    }
}

// MARK: - Layer 2: Active SQLite WAL Lock Info

nonisolated struct WALLockHit: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let modifiedSecondsAgo: TimeInterval
}

// MARK: - Layer 4: Manifest & Staged Record Models

nonisolated struct APFSStagingManifest: Codable, Equatable, Sendable {
    let id: String
    let sourceBundleID: String
    let displayTitle: String
    let sourceContainerUUID: String
    let createdAt: Date
    let stagedSubdirectories: [String]
    let expectedItemCount: Int
    let verifiedItemCount: Int
    let fileCount: Int
    let logicalByteSize: Int64
    let weChatAccountCount: Int?
    let isVerified: Bool
    var lastRestoredAt: Date?
    var lastRestoredTargetBundleID: String?
}

nonisolated struct APFSStagingRecord: Identifiable, Equatable, Sendable {
    let id: String
    var manifest: APFSStagingManifest
    let vaultDirectoryURL: URL
    let payloadURL: URL

    var bundleID: String { manifest.sourceBundleID }
    var displayTitle: String { manifest.displayTitle }
    var createdAt: Date { manifest.createdAt }
    var stagedSubdirectories: [String] { manifest.stagedSubdirectories }
    var expectedItemCount: Int { manifest.expectedItemCount }
    var verifiedItemCount: Int { manifest.verifiedItemCount }
    var fileCount: Int { manifest.fileCount }
    var logicalByteSize: Int64 { manifest.logicalByteSize }
    var weChatAccountCount: Int? { manifest.weChatAccountCount }
    var isVerified: Bool { manifest.isVerified }
    var lastRestoredAt: Date? { manifest.lastRestoredAt }
    var lastRestoredTargetBundleID: String? { manifest.lastRestoredTargetBundleID }
}

nonisolated struct APFSStageOutcome: Sendable {
    let record: APFSStagingRecord
    let weChatAccountCount: Int?
}

nonisolated struct APFSRestoreOutcome: Identifiable, Equatable, Sendable {
    let id: UUID
    let recordID: String
    let sourceBundleID: String
    let targetBundleID: String
    let targetContainerUUID: String
    let restoredItemCount: Int
    let restoredFileCount: Int
    let restoredBytes: Int64
    let adaptedPreferencesPlist: Bool
    let weChatAccountCount: Int?
}

nonisolated enum APFSStagingError: LocalizedError, Sendable {
    case operationBusy
    case protectedContainer(String)
    case sandboxAccessDenied(String)
    case activeWALLock([WALLockHit])
    case noStageableData
    case cloneFailed(String)
    case manifestVerificationFailed(expected: Int, actual: Int)
    case vaultCorrupted(String)
    case interruptedPreRestoreBackupExists
    case restoreFailedWithRollback(reason: String, rolledBack: Bool)

    var errorDescription: String? {
        switch self {
        case .operationBusy:
            return apfsVaultText(
                "Another staging or restore task is currently running. Please wait.",
                "当前已有暂存或还原任务正在执行，请稍候完成后再试。"
            )
        case .protectedContainer(let bid):
            return apfsVaultText(
                "Safety block: cannot stage or overwrite protected system/app container (\(bid)).",
                "安全拦截：禁止暂存或覆盖受保护的系统/自身容器 (\(bid))。"
            )
        case .sandboxAccessDenied(let detail):
            return apfsVaultText(
                "Unable to acquire container sandbox access: \(detail)",
                "无法获取目标应用容器的沙盒访问权限：\(detail)"
            )
        case .activeWALLock(let hits):
            let preview = hits.prefix(3).map {
                "\($0.relativePath) (\(String(format: "%.1fs", $0.modifiedSecondsAgo)))"
            }.joined(separator: "\n• ")
            return apfsVaultText(
                "Active SQLite WAL lock detected! Target app is still running or just wrote data within 10s.\n\nSwipe-close the target app from the iOS App Switcher first, wait 10 seconds, then retry:\n• \(preview)",
                "检测到活跃 SQLite WAL 写入锁！目标应用仍在运行或 10 秒内刚写入过数据库。\n\n请先从 iOS 后台多任务界面上滑彻底关闭目标应用，等待 10 秒后再试：\n• \(preview)"
            )
        case .noStageableData:
            return apfsVaultText(
                "No Documents, Library/Application Support, or Library/Preferences directories were found in this container.",
                "未在该应用容器内找到可暂存的 Documents、Library/Application Support 或 Library/Preferences 目录。"
            )
        case .cloneFailed(let detail):
            return apfsVaultText(
                "APFS clonefile() staging failed: \(detail)",
                "APFS clonefile() 零空间克隆失败：\(detail)"
            )
        case .manifestVerificationFailed(let expected, let actual):
            return apfsVaultText(
                "Integrity verification failed (manifest.json): expected \(expected) items, cloned \(actual) items. Partial snapshot discarded; source app data is untouched.",
                "manifest.json 完整性校验失败：源目录共 \(expected) 项，实际克隆 \(actual) 项。已自动清理残缺快照，源应用数据毫发无损。"
            )
        case .vaultCorrupted(let detail):
            return apfsVaultText(
                "Staged vault record failed integrity check: \(detail)",
                "暂存舱快照未能通过完整性校验：\(detail)"
            )
        case .interruptedPreRestoreBackupExists:
            return apfsVaultText(
                "Found an existing .erosion_pre_restore_bak without a live Documents folder in target container. Inspect the container manually before retrying.",
                "检测到目标容器存在未完成恢复残留的 .erosion_pre_restore_bak 且缺少 Documents 目录。为防数据覆盖，已中止操作，请先用文件管理器检查该容器。"
            )
        case .restoreFailedWithRollback(let reason, let rolledBack):
            if rolledBack {
                return apfsVaultText(
                    "Restore failed and automatically rolled back original target container from .erosion_pre_restore_bak (Staging Vault copy remains intact):\n\(reason)",
                    "还原失败，已自动从 .erosion_pre_restore_bak 完整回滚目标容器原数据（暂存舱快照依然完好保留）：\n\(reason)"
                )
            } else {
                return apfsVaultText(
                    "Restore failed (\(reason)). Backup remains at .erosion_pre_restore_bak inside the target container and Staging Vault copy remains intact.",
                    "还原失败（\(reason)）。原容器数据保留在目标容器的 .erosion_pre_restore_bak 中，暂存舱快照依然完好保留。"
                )
            }
        }
    }
}

// MARK: - Low-Level Nonisolated APFS / POSIX Engine

nonisolated enum APFSStagingEngine {
    static let targetSubdirectories = [
        "Documents",
        "Library/Application Support",
        "Library/Preferences"
    ]

    static let protectedBundleIDs: Set<String> = [
        "com.jbdotparty.Erosion",
        "com.apple.springboard",
        "com.apple.PosterBoard",
        "com.apple.Preferences",
        "com.apple.mobilephone"
    ]

    private struct TreeMetrics: Sendable {
        var itemCount: Int = 0
        var fileCount: Int = 0
        var byteSize: Int64 = 0
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: Layer 1: Provisioning Profile CMS/Plist Parser

    static func inspectEmbeddedProvisioningProfile(now: Date = Date()) -> ProvisioningCertInfo {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return ProvisioningCertInfo(
                status: .notEmbedded,
                profileName: apfsVaultText("None", "无"),
                teamName: nil,
                expirationDate: nil,
                remainingSeconds: nil
            )
        }
        guard let rawData = try? Data(contentsOf: url) else {
            return ProvisioningCertInfo(
                status: .parseFailed,
                profileName: apfsVaultText("Unreadable", "无法读取"),
                teamName: nil,
                expirationDate: nil,
                remainingSeconds: nil
            )
        }
        return parseMobileProvisionData(rawData, now: now)
    }

    static func parseMobileProvisionData(_ rawData: Data, now: Date = Date()) -> ProvisioningCertInfo {
        let xmlStart = rawData.range(of: Data("<?xml".utf8)) ?? rawData.range(of: Data("<plist".utf8))
        let plistEnd = rawData.range(of: Data("</plist>".utf8))
        guard let startRange = xmlStart,
              let endRange = plistEnd,
              endRange.upperBound > startRange.lowerBound else {
            return ProvisioningCertInfo(
                status: .parseFailed,
                profileName: apfsVaultText("Invalid CMS payload", "CMS 载荷格式异常"),
                teamName: nil,
                expirationDate: nil,
                remainingSeconds: nil
            )
        }

        let plistSlice = rawData[startRange.lowerBound..<endRange.upperBound]
        guard let dict = (try? PropertyListSerialization.propertyList(from: Data(plistSlice), options: [], format: nil)) as? [String: Any] else {
            return ProvisioningCertInfo(
                status: .parseFailed,
                profileName: apfsVaultText("Plist decode failed", "Plist 解析失败"),
                teamName: nil,
                expirationDate: nil,
                remainingSeconds: nil
            )
        }

        let name = (dict["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = (name?.isEmpty == false) ? name! : "embedded.mobileprovision"
        let teamName = dict["TeamName"] as? String
        guard let expirationDate = dict["ExpirationDate"] as? Date else {
            return ProvisioningCertInfo(
                status: .parseFailed,
                profileName: profileName,
                teamName: teamName,
                expirationDate: nil,
                remainingSeconds: nil
            )
        }

        let remaining = expirationDate.timeIntervalSince(now)
        let status: ProvisioningCertInfo.Status
        if remaining <= 0 {
            status = .expired
        } else if remaining < 24 * 3600 {
            status = .expiringSoon
        } else {
            status = .valid
        }

        return ProvisioningCertInfo(
            status: status,
            profileName: profileName,
            teamName: teamName,
            expirationDate: expirationDate,
            remainingSeconds: remaining
        )
    }

    // MARK: Layer 2: Active SQLite WAL Lock Scanner (depth <= 4, <= 10s)

    static func scanActiveWALLocks(
        in containerURL: URL,
        now: Date = Date(),
        thresholdSeconds: TimeInterval = 10.0,
        maxDepth: Int = 4
    ) -> [WALLockHit] {
        var hits: [WALLockHit] = []
        let nowSec = now.timeIntervalSince1970

        for rootName in ["Documents", "Library"] {
            let rootURL = containerURL.appendingPathComponent(rootName)
            var rootSt = stat()
            guard lstat(rootURL.path, &rootSt) == 0,
                  (rootSt.st_mode & S_IFMT) == S_IFDIR else { continue }
            scanWALRecursive(
                dirPath: rootURL.path,
                relPrefix: rootName,
                currentDepth: 0,
                maxDepth: maxDepth,
                nowSec: nowSec,
                thresholdSeconds: thresholdSeconds,
                hits: &hits
            )
        }
        return hits.sorted { $0.modifiedSecondsAgo < $1.modifiedSecondsAgo }
    }

    private static func scanWALRecursive(
        dirPath: String,
        relPrefix: String,
        currentDepth: Int,
        maxDepth: Int,
        nowSec: TimeInterval,
        thresholdSeconds: TimeInterval,
        hits: inout [WALLockHit]
    ) {
        guard currentDepth <= maxDepth else { return }
        guard let dir = opendir(dirPath) else { return }
        defer { closedir(dir) }

        let dfd = dirfd(dir)
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT

            if mode == S_IFDIR {
                if currentDepth < maxDepth {
                    let childPath = (dirPath as NSString).appendingPathComponent(name)
                    let childRel = "\(relPrefix)/\(name)"
                    scanWALRecursive(
                        dirPath: childPath,
                        relPrefix: childRel,
                        currentDepth: currentDepth + 1,
                        maxDepth: maxDepth,
                        nowSec: nowSec,
                        thresholdSeconds: thresholdSeconds,
                        hits: &hits
                    )
                }
            } else if mode == S_IFREG {
                let lower = name.lowercased()
                if lower.hasSuffix("-wal") || lower.hasSuffix(".sqlite-wal") || lower.hasSuffix(".db-wal") {
                    let mtimeSec = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
                    let age = nowSec - mtimeSec
                    if age <= thresholdSeconds && age >= -60.0 {
                        let rel = "\(relPrefix)/\(name)"
                        hits.append(WALLockHit(id: rel, relativePath: rel, modifiedSecondsAgo: max(0, age)))
                    }
                }
            }
        }
    }

    // MARK: Layer 3: WeChat 32-Hex MD5 Account Scanner

    static func detectWeChatAccountCount(in containerURL: URL, bundleID: String) -> Int? {
        let docsURL = containerURL.appendingPathComponent("Documents")
        let isWeChatBID = bundleID.lowercased().hasPrefix("com.tencent.xin")
        let loginInfoPath = docsURL.appendingPathComponent("LoginInfo2.dat").path
        var infoSt = stat()
        let hasLoginInfo = (lstat(loginInfoPath, &infoSt) == 0)

        guard isWeChatBID || hasLoginInfo else { return nil }
        guard let dir = opendir(docsURL.path) else { return 0 }
        defer { closedir(dir) }

        let dfd = dirfd(dir)
        var count = 0
        let allZeroHex = String(repeating: "0", count: 32)
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name.count == 32,
                  name != allZeroHex,
                  name.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
            var st = stat()
            if fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
               (st.st_mode & S_IFMT) == S_IFDIR {
                count += 1
            }
        }
        return count
    }

    // MARK: Tree Metrics & CoW clonefile()

    private static func countTreeMetrics(at rootPath: String) -> TreeMetrics {
        var rootSt = stat()
        guard lstat(rootPath, &rootSt) == 0 else { return TreeMetrics() }
        let rootMode = rootSt.st_mode & S_IFMT
        if rootMode == S_IFREG {
            return TreeMetrics(itemCount: 1, fileCount: 1, byteSize: Int64(rootSt.st_size))
        }
        if rootMode == S_IFLNK {
            return TreeMetrics(itemCount: 1, fileCount: 0, byteSize: 0)
        }
        guard rootMode == S_IFDIR else { return TreeMetrics() }

        var metrics = TreeMetrics(itemCount: 1, fileCount: 0, byteSize: 0)
        accumulateMetrics(in: rootPath, into: &metrics)
        return metrics
    }

    private static func accumulateMetrics(in dirPath: String, into metrics: inout TreeMetrics) {
        guard let dir = opendir(dirPath) else { return }
        defer { closedir(dir) }

        let dfd = dirfd(dir)
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            switch mode {
            case S_IFDIR:
                metrics.itemCount += 1
                let child = (dirPath as NSString).appendingPathComponent(name)
                accumulateMetrics(in: child, into: &metrics)
            case S_IFREG:
                metrics.itemCount += 1
                metrics.fileCount += 1
                metrics.byteSize += Int64(st.st_size)
            case S_IFLNK:
                metrics.itemCount += 1
            default:
                break
            }
        }
    }

    static func cloneDirectoryCoW(from srcPath: String, to dstPath: String) async throws {
        let localFM = FileManager.default
        var dstCheck = stat()
        if lstat(dstPath, &dstCheck) == 0 {
            try forceRemoveItem(at: URL(fileURLWithPath: dstPath))
        }

        let parentDir = (dstPath as NSString).deletingLastPathComponent
        if !localFM.fileExists(atPath: parentDir) {
            try localFM.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        if vault_clonefile(srcPath, dstPath, 0) == 0 {
            return
        }
        let wholeErr = errno

        // Clean any partial directory left by failed whole-tree clonefile before per-entry fallback
        if lstat(dstPath, &dstCheck) == 0 {
            try? forceRemoveItem(at: URL(fileURLWithPath: dstPath))
        }

        do {
            try await cloneDirectoryPerEntry(from: srcPath, to: dstPath)
        } catch {
            let errStr = String(cString: strerror(wholeErr))
            throw APFSStagingError.cloneFailed("\(error.localizedDescription) (subtree errno=\(wholeErr): \(errStr))")
        }
    }

    private static func cloneDirectoryPerEntry(from srcPath: String, to dstPath: String) async throws {
        let localFM = FileManager.default
        var srcStat = stat()
        guard lstat(srcPath, &srcStat) == 0 else {
            throw APFSStagingError.cloneFailed("lstat failed at \(srcPath) (errno=\(errno))")
        }

        // Create writable first so children can always be cloned even if source dir is 0555
        try localFM.createDirectory(atPath: dstPath, withIntermediateDirectories: true)

        var grantedTemp = false
        if opendir(srcPath) == nil && (errno == EACCES || errno == EPERM) {
            grantedTemp = await MainActor.run {
                if !wq.hasActiveAccess(path: srcPath) {
                    return wq.grantAccess(path: srcPath, requireWrite: false).0
                }
                return false
            }
        }

        guard let dir = opendir(srcPath) else {
            let e = errno
            if grantedTemp {
                await MainActor.run { wq.releaseAccess(path: srcPath) }
            }
            throw APFSStagingError.cloneFailed("opendir failed at \(srcPath) (errno=\(e): \(String(cString: strerror(e))))")
        }

        var entries: [(name: String, mode: mode_t)] = []
        let dfd = dirfd(dir)
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            entries.append((name: name, mode: st.st_mode))
        }
        closedir(dir)

        do {
            for entry in entries {
                let kind = entry.mode & S_IFMT
                let srcChild = (srcPath as NSString).appendingPathComponent(entry.name)
                let dstChild = (dstPath as NSString).appendingPathComponent(entry.name)

                switch kind {
                case S_IFDIR:
                    try await cloneDirectoryCoW(from: srcChild, to: dstChild)
                case S_IFREG:
                    try await cloneRegularFileCoW(from: srcChild, to: dstChild, mode: entry.mode & 0o777)
                case S_IFLNK:
                    try cloneSymlinkCoW(from: srcChild, to: dstChild)
                default:
                    // Skip sockets/FIFOs/devices which cannot be clonefile()'d
                    break
                }
            }
        } catch {
            if grantedTemp {
                await MainActor.run { wq.releaseAccess(path: srcPath) }
            }
            throw error
        }

        if grantedTemp {
            await MainActor.run { wq.releaseAccess(path: srcPath) }
        }

        let targetPerm = srcStat.st_mode & 0o777
        if targetPerm != 0 {
            _ = chmod(dstPath, targetPerm)
        }
    }

    private static func cloneRegularFileCoW(from srcPath: String, to dstPath: String, mode: mode_t) async throws {
        if vault_clonefile(srcPath, dstPath, 0) == 0 {
            return
        }
        let firstErr = errno
        var st = stat()
        if lstat(dstPath, &st) == 0 {
            _ = unlink(dstPath)
        }

        var grantedTemp = false
        if firstErr == EPERM || firstErr == EACCES {
            grantedTemp = await MainActor.run {
                if !wq.hasActiveAccess(path: srcPath) {
                    return wq.grantAccess(path: srcPath, requireWrite: false).0
                }
                return false
            }
            if grantedTemp && vault_clonefile(srcPath, dstPath, 0) == 0 {
                await MainActor.run { wq.releaseAccess(path: srcPath) }
                return
            }
        }

        do {
            if lstat(dstPath, &st) == 0 {
                _ = unlink(dstPath)
            }
            // Fallback read-copy if clonefile cannot clone a specific file attribute/cross-fs item
            try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
            if mode != 0 {
                _ = chmod(dstPath, mode)
            }
            if grantedTemp {
                await MainActor.run { wq.releaseAccess(path: srcPath) }
            }
        } catch {
            if grantedTemp {
                await MainActor.run { wq.releaseAccess(path: srcPath) }
            }
            throw error
        }
    }

    private static func cloneSymlinkCoW(from srcPath: String, to dstPath: String) throws {
        if vault_clonefile(srcPath, dstPath, kCloneNoFollowFlag) == 0 {
            return
        }
        var st = stat()
        if lstat(dstPath, &st) == 0 {
            _ = unlink(dstPath)
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let len = readlink(srcPath, &buf, Int(PATH_MAX))
        guard len >= 0 else {
            let e = errno
            throw APFSStagingError.cloneFailed("readlink failed at \(srcPath) (errno=\(e))")
        }
        buf[len] = 0
        let target = String(cString: buf)
        if symlink(target, dstPath) != 0 {
            let e = errno
            throw APFSStagingError.cloneFailed("symlink failed at \(dstPath) (errno=\(e))")
        }
    }

    static func forceRemoveItem(at url: URL) throws {
        let localFM = FileManager.default
        do {
            try localFM.removeItem(at: url)
        } catch {
            // Handle 0555/0444 locked subtrees inside .bak or staging leftovers
            unlockDirectoryTreeWritable(atPath: url.path)
            try localFM.removeItem(at: url)
        }
    }

    private static func unlockDirectoryTreeWritable(atPath path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        _ = chmod(path, 0o755)
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }
        let dfd = dirfd(dir)
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            var childSt = stat()
            guard fstatat(dfd, name, &childSt, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (childSt.st_mode & S_IFMT) == S_IFDIR {
                unlockDirectoryTreeWritable(atPath: (path as NSString).appendingPathComponent(name))
            }
        }
    }

    // MARK: Container Access Helpers

    private static func acquireReadTokens(for containerURL: URL) async -> [String] {
        var candidatePaths = [containerURL.path]
        for sub in ["Documents", "Library", "Library/Application Support", "Library/Preferences"] {
            let p = containerURL.appendingPathComponent(sub).path
            var st = stat()
            if lstat(p, &st) == 0 {
                candidatePaths.append(p)
            }
        }
        let pathsToGrant = candidatePaths
        return await MainActor.run {
            var acquired: [String] = []
            for p in pathsToGrant {
                if !wq.hasActiveAccess(path: p), wq.grantAccess(path: p, requireWrite: false).0 {
                    acquired.append(p)
                }
            }
            return acquired
        }
    }

    private static func acquireWriteTokens(for containerURL: URL) async throws -> [String] {
        var extraPaths: [String] = []
        for sub in ["Documents", "Library", "Library/Application Support", "Library/Preferences"] {
            let p = containerURL.appendingPathComponent(sub).path
            var st = stat()
            if lstat(p, &st) == 0 {
                extraPaths.append(p)
            }
        }
        let pathsToWriteGrant = extraPaths

        let result: Result<[String], APFSStagingError> = await MainActor.run {
            var acquired: [String] = []
            let wasRootActive = wq.hasActiveAccess(path: containerURL.path)
            let rootGrant = wq.grantAccess(path: containerURL.path, requireWrite: true)
            guard rootGrant.0 else {
                return .failure(.sandboxAccessDenied(rootGrant.2))
            }
            if !wasRootActive {
                acquired.append(containerURL.path)
            }
            for p in pathsToWriteGrant {
                if !wq.hasActiveAccess(path: p), wq.grantAccess(path: p, requireWrite: true).0 {
                    acquired.append(p)
                }
            }
            return .success(acquired)
        }
        return try result.get()
    }

    private static func releaseTokens(_ tokens: [String]) async {
        guard !tokens.isEmpty else { return }
        await MainActor.run {
            for p in tokens.reversed() {
                wq.releaseAccess(path: p)
            }
        }
    }

    // MARK: Stage Workflow

    static func performStage(
        sourceBundleID: String,
        displayTitle: String,
        sourceContainerURL: URL,
        vaultRootURL: URL
    ) async throws -> APFSStageOutcome {
        let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
        if sourceBundleID == selfBID || protectedBundleIDs.contains(sourceBundleID) {
            throw APFSStagingError.protectedContainer(sourceBundleID)
        }

        let localFM = FileManager.default
        try localFM.createDirectory(at: vaultRootURL, withIntermediateDirectories: true)
        excludeFromBackup(vaultRootURL)

        let tokens = await acquireReadTokens(for: sourceContainerURL)
        do {
            guard localFM.isReadableFile(atPath: sourceContainerURL.path) else {
                throw APFSStagingError.sandboxAccessDenied(sourceContainerURL.path)
            }

            // Layer 2: Active SQLite WAL Lock Check (depth <= 4, modified within 10s)
            let walHits = scanActiveWALLocks(in: sourceContainerURL)
            if !walHits.isEmpty {
                throw APFSStagingError.activeWALLock(walHits)
            }

            // Layer 3 pre-scan: WeChat MD5 account count + existing source subdirs
            let weChatCount = detectWeChatAccountCount(in: sourceContainerURL, bundleID: sourceBundleID)

            var existingSubdirs: [String] = []
            var expectedMetrics = TreeMetrics()
            for sub in targetSubdirectories {
                let srcSub = sourceContainerURL.appendingPathComponent(sub)
                var st = stat()
                if lstat(srcSub.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    existingSubdirs.append(sub)
                    let m = countTreeMetrics(at: srcSub.path)
                    expectedMetrics.itemCount += m.itemCount
                    expectedMetrics.fileCount += m.fileCount
                    expectedMetrics.byteSize += m.byteSize
                }
            }

            guard !existingSubdirs.isEmpty else {
                throw APFSStagingError.noStageableData
            }

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyyMMdd_HHmmss"
            let safeBID = sourceBundleID.replacingOccurrences(of: "/", with: "_")
            let shortID = String(UUID().uuidString.prefix(8))
            let recordID = "\(safeBID)__\(dateFmt.string(from: Date()))__\(shortID)"

            let recordDirURL = vaultRootURL.appendingPathComponent(recordID, isDirectory: true)
            let payloadURL = recordDirURL.appendingPathComponent("payload", isDirectory: true)

            var committed = false
            do {
                try localFM.createDirectory(at: payloadURL, withIntermediateDirectories: true)
                excludeFromBackup(recordDirURL)

                // Layer 3: Kernel CoW clonefile(src, dst, 0) (Copy-Never-Move, source untouched)
                for sub in existingSubdirs {
                    let srcSub = sourceContainerURL.appendingPathComponent(sub)
                    let dstSub = payloadURL.appendingPathComponent(sub)
                    try await cloneDirectoryCoW(from: srcSub.path, to: dstSub.path)
                }

                // Layer 4: Verify cloned item count matches before marking Ready
                var verifiedMetrics = TreeMetrics()
                for sub in existingSubdirs {
                    let dstSub = payloadURL.appendingPathComponent(sub)
                    let m = countTreeMetrics(at: dstSub.path)
                    verifiedMetrics.itemCount += m.itemCount
                    verifiedMetrics.fileCount += m.fileCount
                    verifiedMetrics.byteSize += m.byteSize
                }

                guard verifiedMetrics.itemCount == expectedMetrics.itemCount,
                      verifiedMetrics.fileCount == expectedMetrics.fileCount else {
                    throw APFSStagingError.manifestVerificationFailed(
                        expected: expectedMetrics.itemCount,
                        actual: verifiedMetrics.itemCount
                    )
                }

                let manifest = APFSStagingManifest(
                    id: recordID,
                    sourceBundleID: sourceBundleID,
                    displayTitle: displayTitle,
                    sourceContainerUUID: sourceContainerURL.lastPathComponent,
                    createdAt: Date(),
                    stagedSubdirectories: existingSubdirs,
                    expectedItemCount: expectedMetrics.itemCount,
                    verifiedItemCount: verifiedMetrics.itemCount,
                    fileCount: verifiedMetrics.fileCount,
                    logicalByteSize: verifiedMetrics.byteSize,
                    weChatAccountCount: weChatCount,
                    isVerified: true,
                    lastRestoredAt: nil,
                    lastRestoredTargetBundleID: nil
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let manifestData = try encoder.encode(manifest)
                let manifestURL = recordDirURL.appendingPathComponent("manifest.json")
                try manifestData.write(to: manifestURL, options: .atomic)
                excludeFromBackup(recordDirURL)

                committed = true
                await releaseTokens(tokens)
                let record = APFSStagingRecord(
                    id: recordID,
                    manifest: manifest,
                    vaultDirectoryURL: recordDirURL,
                    payloadURL: payloadURL
                )
                return APFSStageOutcome(record: record, weChatAccountCount: weChatCount)
            } catch {
                if !committed {
                    try? forceRemoveItem(at: recordDirURL)
                }
                throw error
            }
        } catch {
            await releaseTokens(tokens)
            throw error
        }
    }

    // MARK: Restore Workflow (Layer 5 Atomic .bak Swap + BundleID Plist Mapping)

    static func performRestore(
        record: APFSStagingRecord,
        targetContainerURL: URL,
        targetBundleID: String
    ) async throws -> APFSRestoreOutcome {
        let selfBID = Bundle.main.bundleIdentifier ?? "com.jbdotparty.Erosion"
        if targetBundleID == selfBID || protectedBundleIDs.contains(targetBundleID) {
            throw APFSStagingError.protectedContainer(targetBundleID)
        }

        let localFM = FileManager.default
        guard record.isVerified, !record.stagedSubdirectories.isEmpty else {
            throw APFSStagingError.vaultCorrupted(apfsVaultText("Record is not verified", "快照未处于就绪校验状态"))
        }

        // Pre-restore vault integrity check
        var vaultMetrics = TreeMetrics()
        for sub in record.stagedSubdirectories {
            let vaultSub = record.payloadURL.appendingPathComponent(sub)
            var st = stat()
            guard lstat(vaultSub.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
                throw APFSStagingError.vaultCorrupted(apfsVaultText("Missing staged directory: \(sub)", "暂存目录缺失：\(sub)"))
            }
            let m = countTreeMetrics(at: vaultSub.path)
            vaultMetrics.itemCount += m.itemCount
            vaultMetrics.fileCount += m.fileCount
            vaultMetrics.byteSize += m.byteSize
        }
        guard vaultMetrics.itemCount == record.verifiedItemCount else {
            throw APFSStagingError.vaultCorrupted(
                apfsVaultText(
                    "Vault item count changed (\(vaultMetrics.itemCount) vs \(record.verifiedItemCount))",
                    "暂存舱文件计数与 manifest.json 不符（当前 \(vaultMetrics.itemCount)，记录 \(record.verifiedItemCount)）"
                )
            )
        }

        let tokens = try await acquireWriteTokens(for: targetContainerURL)
        do {
            // Layer 2: Active SQLite WAL Lock Check on Target before modifying anything
            let walHits = scanActiveWALLocks(in: targetContainerURL)
            if !walHits.isEmpty {
                throw APFSStagingError.activeWALLock(walHits)
            }

            let bakRoot = targetContainerURL.appendingPathComponent(".erosion_pre_restore_bak", isDirectory: true)
            if localFM.fileExists(atPath: bakRoot.path) {
                let targetDocs = targetContainerURL.appendingPathComponent("Documents")
                let bakDocs = bakRoot.appendingPathComponent("Documents")
                if !localFM.fileExists(atPath: targetDocs.path) && localFM.fileExists(atPath: bakDocs.path) {
                    throw APFSStagingError.interruptedPreRestoreBackupExists
                }
                try forceRemoveItem(at: bakRoot)
            }
            try localFM.createDirectory(at: bakRoot, withIntermediateDirectories: true)

            var movedToBak: [String] = []
            var createdInTarget: [String] = []

            do {
                // 1. Move existing target subdirectories to .erosion_pre_restore_bak
                for sub in targetSubdirectories {
                    let targetSub = targetContainerURL.appendingPathComponent(sub)
                    var st = stat()
                    if lstat(targetSub.path, &st) == 0 {
                        let bakSub = bakRoot.appendingPathComponent(sub)
                        let bakParent = bakSub.deletingLastPathComponent()
                        if !localFM.fileExists(atPath: bakParent.path) {
                            try localFM.createDirectory(at: bakParent, withIntermediateDirectories: true)
                        }
                        try localFM.moveItem(at: targetSub, to: bakSub)
                        movedToBak.append(sub)
                    }
                }

                // 2. clonefile() from Staging Vault into Target (KEEPING Staging Vault copy intact!)
                for sub in record.stagedSubdirectories {
                    let vaultSub = record.payloadURL.appendingPathComponent(sub)
                    let targetSub = targetContainerURL.appendingPathComponent(sub)
                    let targetParent = targetSub.deletingLastPathComponent()
                    if !localFM.fileExists(atPath: targetParent.path) {
                        try localFM.createDirectory(at: targetParent, withIntermediateDirectories: true)
                    }
                    createdInTarget.append(sub)
                    try await cloneDirectoryCoW(from: vaultSub.path, to: targetSub.path)
                }

                // 3. Verify target restored item count matches Vault manifest before removing .bak
                var targetMetrics = TreeMetrics()
                for sub in record.stagedSubdirectories {
                    let targetSub = targetContainerURL.appendingPathComponent(sub)
                    let m = countTreeMetrics(at: targetSub.path)
                    targetMetrics.itemCount += m.itemCount
                    targetMetrics.fileCount += m.fileCount
                    targetMetrics.byteSize += m.byteSize
                }
                guard targetMetrics.itemCount == record.verifiedItemCount else {
                    throw APFSStagingError.cloneFailed(
                        apfsVaultText(
                            "Post-restore count mismatch: expected \(record.verifiedItemCount), restored \(targetMetrics.itemCount)",
                            "写回后文件总数校验不一致：预期 \(record.verifiedItemCount)，实际 \(targetMetrics.itemCount)"
                        )
                    )
                }

                // 4. BundleID .plist adaptation when source and target Bundle IDs differ
                var adaptedPlist = false
                if record.bundleID.caseInsensitiveCompare(targetBundleID) != .orderedSame {
                    let prefsDir = targetContainerURL.appendingPathComponent("Library/Preferences", isDirectory: true)
                    let srcPlist = prefsDir.appendingPathComponent("\(record.bundleID).plist")
                    let dstPlist = prefsDir.appendingPathComponent("\(targetBundleID).plist")
                    var srcSt = stat()
                    if lstat(srcPlist.path, &srcSt) == 0, (srcSt.st_mode & S_IFMT) == S_IFREG {
                        if localFM.fileExists(atPath: dstPlist.path) {
                            try localFM.removeItem(at: dstPlist)
                        }
                        try localFM.copyItem(at: srcPlist, to: dstPlist)
                        adaptedPlist = true
                    }
                }

                // 5. Commit: remove .erosion_pre_restore_bak on success (Vault snapshot remains intact!)
                try? forceRemoveItem(at: bakRoot)

                // Update manifest restore metadata
                var updatedManifest = record.manifest
                updatedManifest.lastRestoredAt = Date()
                updatedManifest.lastRestoredTargetBundleID = targetBundleID
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(updatedManifest) {
                    try? data.write(to: record.vaultDirectoryURL.appendingPathComponent("manifest.json"), options: .atomic)
                }

                await releaseTokens(tokens)
                return APFSRestoreOutcome(
                    id: UUID(),
                    recordID: record.id,
                    sourceBundleID: record.bundleID,
                    targetBundleID: targetBundleID,
                    targetContainerUUID: targetContainerURL.lastPathComponent,
                    restoredItemCount: targetMetrics.itemCount,
                    restoredFileCount: targetMetrics.fileCount,
                    restoredBytes: targetMetrics.byteSize,
                    adaptedPreferencesPlist: adaptedPlist,
                    weChatAccountCount: record.weChatAccountCount
                )
            } catch {
                // Rollback from .erosion_pre_restore_bak on any error
                for sub in createdInTarget {
                    let targetSub = targetContainerURL.appendingPathComponent(sub)
                    if localFM.fileExists(atPath: targetSub.path) {
                        try? forceRemoveItem(at: targetSub)
                    }
                }
                var rollbackClean = true
                for sub in movedToBak {
                    let bakSub = bakRoot.appendingPathComponent(sub)
                    let targetSub = targetContainerURL.appendingPathComponent(sub)
                    let targetParent = targetSub.deletingLastPathComponent()
                    if !localFM.fileExists(atPath: targetParent.path) {
                        try? localFM.createDirectory(at: targetParent, withIntermediateDirectories: true)
                    }
                    do {
                        try localFM.moveItem(at: bakSub, to: targetSub)
                    } catch {
                        rollbackClean = false
                    }
                }
                if rollbackClean {
                    try? forceRemoveItem(at: bakRoot)
                }
                throw APFSStagingError.restoreFailedWithRollback(
                    reason: error.localizedDescription,
                    rolledBack: rollbackClean
                )
            }
        } catch {
            await releaseTokens(tokens)
            throw error
        }
    }

    // MARK: Disk Loading

    static func loadRecordsFromDisk(vaultRootURL: URL) -> [APFSStagingRecord] {
        let localFM = FileManager.default
        if !localFM.fileExists(atPath: vaultRootURL.path) {
            try? localFM.createDirectory(at: vaultRootURL, withIntermediateDirectories: true)
        }
        excludeFromBackup(vaultRootURL)

        guard let entries = try? localFM.contentsOfDirectory(
            at: vaultRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [APFSStagingRecord] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let manifestURL = entry.appendingPathComponent("manifest.json")
            let payloadURL = entry.appendingPathComponent("payload", isDirectory: true)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(APFSStagingManifest.self, from: data),
                  manifest.isVerified,
                  !manifest.stagedSubdirectories.isEmpty else {
                continue
            }

            let hasPayloadSubdir = manifest.stagedSubdirectories.contains { sub in
                localFM.fileExists(atPath: payloadURL.appendingPathComponent(sub).path)
            }
            guard hasPayloadSubdir else { continue }

            excludeFromBackup(entry)
            records.append(APFSStagingRecord(
                id: manifest.id,
                manifest: manifest,
                vaultDirectoryURL: entry,
                payloadURL: payloadURL
            ))
        }
        records.sort { $0.createdAt > $1.createdAt }
        return records
    }
}

// MARK: - APFSStagingVault ObservableObject

@MainActor
final class APFSStagingVault: ObservableObject {
    static let shared = APFSStagingVault()

    static var vaultRootURL: URL {
        URL.documentsDirectory.appendingPathComponent("APFSStagingVault", isDirectory: true)
    }

    @Published private(set) var activeStagedItemsCount: Int = 0
    @Published private(set) var stagedRecords: [APFSStagingRecord] = []
    @Published private(set) var certInfo: ProvisioningCertInfo
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var busyMessage: String = ""

    private init() {
        self.certInfo = APFSStagingEngine.inspectEmbeddedProvisioningProfile()
        reloadRecords()
    }

    @discardableResult
    func refreshCertificateStatus() -> ProvisioningCertInfo {
        let latest = APFSStagingEngine.inspectEmbeddedProvisioningProfile()
        self.certInfo = latest
        return latest
    }

    func reloadRecords() {
        let loaded = APFSStagingEngine.loadRecordsFromDisk(vaultRootURL: Self.vaultRootURL)
        self.stagedRecords = loaded
        self.activeStagedItemsCount = loaded.filter(\.isVerified).count
    }

    func inspectWeChatAccounts(in item: AppSaveContainerItem) async -> Int? {
        let url = item.containerURL
        let bid = item.bundleID
        let wasActive = wq.hasActiveAccess(path: url.path)
        let granted = wq.grantAccess(path: url.path, requireWrite: false).0
        let count = await Task.detached(priority: .userInitiated) {
            APFSStagingEngine.detectWeChatAccountCount(in: url, bundleID: bid)
        }.value
        if granted && !wasActive {
            wq.releaseAccess(path: url.path)
        }
        return count
    }

    func resolveLatestTargetContainer(forBundleID bundleID: String) async -> AppSaveContainerItem? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                CSStoreEngine.shared.invalidate()

                let directPath = fsHandlers.getContainerPath(forMatch: bundleID)
                if !directPath.isEmpty, FileManager.default.fileExists(atPath: directPath) {
                    let url = URL(fileURLWithPath: directPath)
                    if let verifiedBID = getBIDFromXattr(url),
                       verifiedBID.caseInsensitiveCompare(bundleID) == .orderedSame {
                        let item = AppSaveContainerItem(
                            id: url.lastPathComponent,
                            bundleID: verifiedBID,
                            displayTitle: AppContainerDirectoryHelper.displayName(for: verifiedBID),
                            containerURL: url,
                            saveDataSize: 0
                        )
                        continuation.resume(returning: item)
                        return
                    }
                }

                // Fallback: force full container scan in case LaunchServices .csstore has not indexed a fresh install yet
                let rawPaths = fsHandlers.getDirPaths(FSURL.appContainers.path, forceRefresh: true)
                for rawPath in rawPaths {
                    let url = URL(fileURLWithPath: rawPath)
                    if let bid = getBIDFromXattr(url),
                       bid.caseInsensitiveCompare(bundleID) == .orderedSame {
                        let item = AppSaveContainerItem(
                            id: url.lastPathComponent,
                            bundleID: bid,
                            displayTitle: AppContainerDirectoryHelper.displayName(for: bid),
                            containerURL: url,
                            saveDataSize: 0
                        )
                        continuation.resume(returning: item)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func stageContainer(_ item: AppSaveContainerItem) async throws -> APFSStageOutcome {
        guard !isBusy else { throw APFSStagingError.operationBusy }
        isBusy = true
        busyMessage = apfsVaultText(
            "Staging \(item.bundleID) via APFS clonefile()...",
            "正在通过 APFS clonefile() 零空间暂存 \(item.bundleID)..."
        )
        let prevIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = prevIdle
            isBusy = false
            busyMessage = ""
        }

        let vaultRoot = Self.vaultRootURL
        let bundleID = item.bundleID
        let title = item.displayTitle
        let containerURL = item.containerURL

        let outcome = try await Task.detached(priority: .userInitiated) {
            try await APFSStagingEngine.performStage(
                sourceBundleID: bundleID,
                displayTitle: title,
                sourceContainerURL: containerURL,
                vaultRootURL: vaultRoot
            )
        }.value

        reloadRecords()
        Haptic.shared.play(.soft)
        return outcome
    }

    func restoreRecord(
        _ record: APFSStagingRecord,
        toTargetContainerURL targetURL: URL,
        targetBundleID: String
    ) async throws -> APFSRestoreOutcome {
        guard !isBusy else { throw APFSStagingError.operationBusy }
        isBusy = true
        busyMessage = apfsVaultText(
            "Atomically restoring snapshot to \(targetBundleID)...",
            "正在执行原子备份与 APFS clonefile() 还原至 \(targetBundleID)..."
        )
        let prevIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = prevIdle
            isBusy = false
            busyMessage = ""
        }

        let outcome = try await Task.detached(priority: .userInitiated) {
            try await APFSStagingEngine.performRestore(
                record: record,
                targetContainerURL: targetURL,
                targetBundleID: targetBundleID
            )
        }.value

        reloadRecords()
        Haptic.shared.play(.soft)
        return outcome
    }

    func releaseRecord(_ record: APFSStagingRecord) throws {
        guard !isBusy else { throw APFSStagingError.operationBusy }
        try APFSStagingEngine.forceRemoveItem(at: record.vaultDirectoryURL)
        reloadRecords()
        Haptic.shared.play(.soft)
    }
}
