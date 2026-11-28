//
//  FileSafetyHelpers.swift
//  Erosion
//
//  Container-root protection, SQLite companion-set (-wal/-shm/-journal) safety,
//  friendly POSIX error translation, scoped write-grant orchestration, and async folder sizing.
//

import Foundation
import Darwin

nonisolated public enum ProtectedFileOperation: Sendable, Equatable {
    case delete
    case rename
    case overwrite
}

nonisolated public enum ImportCollisionPolicy: Sendable, Equatable {
    case keepBoth
    case replace
}

nonisolated public struct BatchOperationFailure: Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

nonisolated public struct BatchOperationReport: Sendable {
    public let succeededCount: Int
    public let skippedCount: Int
    public let failures: [BatchOperationFailure]
    public let createdURLs: [URL]

    public var hasFailures: Bool { !failures.isEmpty }

    public func formattedFailureSummary(maxItems: Int = 6) -> String {
        let shown = failures.prefix(maxItems).map { "• \($0.name)：\($0.reason)" }
        var lines = shown
        if failures.count > maxItems {
            let more = failures.count - maxItems
            lines.append(
                LocalizationManager.isEnglish
                    ? "• ...and \(more) more error(s)"
                    : "• ……其余还有 \(more) 项失败"
            )
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated public enum FileManagerOpError: LocalizedError, Sendable {
    case protectedPath(String)
    case sqliteInUse(String)
    case sqliteCompanionBlocked(String)
    case invalidName(String)
    case targetAlreadyExists(String)
    case writeAccessDenied(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let msg),
             .sqliteInUse(let msg),
             .sqliteCompanionBlocked(let msg),
             .invalidName(let msg),
             .targetAlreadyExists(let msg),
             .writeAccessDenied(let msg),
             .operationFailed(let msg):
            return msg
        }
    }
}

public enum FileSafetyGuard {
    nonisolated static let containerParentBases: [String] = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/mobile/Containers/Data/PluginKitPlugin",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/containers/Bundle/Application",
        "/var/containers/Shared/SystemGroup",
        "/var/containers/Data/System"
    ]

    private nonisolated static let immutableSystemRoots: Set<String> = [
        "/",
        "/var",
        "/var/mobile",
        "/var/mobile/Containers",
        "/var/mobile/Containers/Data",
        "/var/mobile/Containers/Shared",
        "/var/containers",
        "/var/containers/Bundle",
        "/var/containers/Data",
        "/var/containers/Shared",
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/Library"
    ]

    private nonisolated static let protectedVaultFileNames: Set<String> = [
        "originalgestalt.plist",
        "preapplygestalt.plist",
        ".erosion_factory_vault.plist",
        ".erosion_factory_vault.sha256"
    ]

    private nonisolated static let protectedMetadataNames: Set<String> = [
        ".com.apple.mobile_container_manager.metadata.plist",
        "com.apple.mobile_container_manager.metadata.plist"
    ]

    public nonisolated static func canonicalPath(_ url: URL) -> String {
        FMNavigationStore.canonicalPath(url.standardizedFileURL.path)
    }

    public nonisolated static func isSymlink(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Returns the immediate container root directory (e.g. `/var/mobile/Containers/Data/Application/<UUID>`) if `url` resides inside one.
    public nonisolated static func containingContainerRoot(for url: URL) -> URL? {
        let canon = canonicalPath(url)
        for base in containerParentBases {
            let prefix = base + "/"
            if canon.hasPrefix(prefix) {
                let rel = String(canon.dropFirst(prefix.count))
                if let firstComp = rel.split(separator: "/", omittingEmptySubsequences: true).first {
                    return URL(fileURLWithPath: prefix + String(firstComp))
                }
            }
        }
        return nil
    }

    /// Returns true if the URL is a protected root or container root directory itself.
    public nonisolated static func isContainerRootOrSystemRoot(_ url: URL) -> Bool {
        let canon = canonicalPath(url)
        if immutableSystemRoots.contains(canon) {
            return true
        }
        if containerParentBases.contains(canon) {
            return true
        }
        for base in containerParentBases {
            let prefix = base + "/"
            if canon.hasPrefix(prefix) {
                let rel = String(canon.dropFirst(prefix.count))
                let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
                if parts.count == 1 {
                    return true
                }
            }
        }
        return false
    }

    /// Checks whether a filename itself is reserved/protected when creating, renaming, importing, or extracting.
    public nonisolated static func protectedFilenameReason(_ filename: String) -> String? {
        let lower = filename.lowercased()
        if lower == "com.apple.mobilegestalt.plist" {
            return LocalizationManager.isEnglish
                ? "Blocked: Direct editing, renaming, importing, or deleting com.apple.MobileGestalt.plist is disabled. Use the dedicated MobileGestalt module."
                : "已拦截：禁止在文件浏览器中直接修改、重命名、导入或删除 com.apple.MobileGestalt.plist，请使用 MobileGestalt 专用模块。"
        }
        if lower == ".erosion_adlock" {
            return LocalizationManager.isEnglish
                ? "Blocked: .erosion_adlock is a Splash Ad Blocker anti-recreate sentinel. Restore write permissions in Splash Ad Blocker or the folder's Info sheet instead."
                : "已拦截：.erosion_adlock 是开屏广告防重建占位锁文件。如需解除，请前往「开屏广告缓存精准锁死」或文件夹「简介」恢复读写。"
        }
        if protectedMetadataNames.contains(lower) {
            return LocalizationManager.isEnglish
                ? "Blocked: Modifying or deleting container metadata (\(filename)) can break app registration."
                : "已拦截：禁止修改或删除容器核心元数据文件（\(filename)），以免破坏系统应用容器注册。"
        }
        return nil
    }

    /// Returns a bilingual reason if mutating `url` is blocked for safety, or `nil` when allowed.
    public nonisolated static func protectionReason(for url: URL, operation: ProtectedFileOperation) -> String? {
        let symlink = isSymlink(at: url)
        let stdPath = canonicalPath(url)
        let resolvedPath = symlink && operation != .overwrite
            ? stdPath
            : FMNavigationStore.canonicalPath(url.resolvingSymlinksInPath().path)

        let pathsToCheck = stdPath == resolvedPath ? [stdPath] : [stdPath, resolvedPath]
        let gestaltCanon = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
        let docsCanon = canonicalPath(URL.documentsDirectory)

        for p in pathsToCheck {
            let pURL = URL(fileURLWithPath: p)
            let nameLower = pURL.lastPathComponent.lowercased()

            if p == gestaltCanon || nameLower == "com.apple.mobilegestalt.plist" {
                return protectedFilenameReason("com.apple.MobileGestalt.plist")
            }

            if nameLower == ".erosion_adlock" {
                return protectedFilenameReason(".erosion_adlock")
            }

            if protectedMetadataNames.contains(nameLower) {
                return protectedFilenameReason(pURL.lastPathComponent)
            }

            if protectedVaultFileNames.contains(nameLower) {
                if p.hasPrefix(docsCanon + "/") || p.contains("/SystemGroup/") || p.contains("/AppGroup/") {
                    return LocalizationManager.isEnglish
                        ? "Blocked: \"\(pURL.lastPathComponent)\" belongs to Erosion's factory backup vault and cannot be deleted or altered here."
                        : "已拦截：「\(pURL.lastPathComponent)」属于 Erosion 原厂安全备份金库，禁止在文件浏览器中直接删除或篡改。"
                }
            }

            if isContainerRootOrSystemRoot(pURL) {
                return LocalizationManager.isEnglish
                    ? "Blocked: Deleting, renaming, or overwriting an app/system container root directory is disabled to prevent app crashes or data loss."
                    : "已拦截：禁止删除、重命名或覆盖应用/系统容器根目录，否则可能导致对应 App 闪退或数据损坏。"
            }

            // Read-only / immutable system root subtrees
            let immutableSubtrees = ["/System/", "/usr/", "/bin/", "/sbin/", "/var/containers/Bundle/"]
            for prefix in immutableSubtrees {
                if p.hasPrefix(prefix) {
                    return LocalizationManager.isEnglish
                        ? "Blocked: System or read-only app bundle paths cannot be modified."
                        : "已拦截：系统目录或只读应用包路径不可修改或删除。"
                }
            }
        }

        // Extra folder inspection on delete: warn clearly if an ad-lock sentinel or critical file sits inside
        if operation == .delete && !symlink {
            var st = stat()
            if lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                let directSentinel = url.appendingPathComponent(".erosion_adlock")
                if FileManager.default.fileExists(atPath: directSentinel.path) {
                    return LocalizationManager.isEnglish
                        ? "This folder is locked by Splash Ad Blocker (.erosion_adlock). Restore write permission in Splash Ad Blocker or Info before deleting."
                        : "该文件夹已被「开屏广告缓存精准锁死」锁定（含 .erosion_adlock）。如需删除，请先在去广告页或简介中恢复读写权限。"
                }
            }
        }

        return nil
    }

    /// Ensures write permission is active on `directoryURL` via `worse_query` when needed, runs `work`, and cleans up any freshly acquired handle.
    public nonisolated static func withWriteAccess<T>(for directoryURL: URL, _ work: () throws -> T) async throws -> T {
        let path = directoryURL.standardizedFileURL.path
        let docsCanon = canonicalPath(URL.documentsDirectory)
        let tmpCanon = canonicalPath(URL.temporaryDirectory)
        let dirCanon = canonicalPath(directoryURL)

        let isOwnSandbox = dirCanon == docsCanon || dirCanon.hasPrefix(docsCanon + "/") || dirCanon == tmpCanon || dirCanon.hasPrefix(tmpCanon + "/")

        var grantedPath: String? = nil
        if !isOwnSandbox && !FileManager.default.isWritableFile(atPath: path) {
            let containerRootPath = containingContainerRoot(for: directoryURL)?.path
            let grantOutcome: (grantedPath: String?, errorMessage: String?) = await MainActor.run {
                let wasActive = wq.hasActiveAccess(path: path)
                let directRes = wq.grantAccess(path: path, requireWrite: true)
                if directRes.0 {
                    return (wasActive ? nil : path, nil)
                }
                if let rootPath = containerRootPath {
                    let rootWasActive = wq.hasActiveAccess(path: rootPath)
                    let rootRes = wq.grantAccess(path: rootPath, requireWrite: true)
                    if rootRes.0 {
                        return (rootWasActive ? nil : rootPath, nil)
                    }
                    if !FileManager.default.isWritableFile(atPath: path) {
                        let detail = rootRes.2.isEmpty ? directRes.2 : rootRes.2
                        return (nil, detail)
                    }
                    return (nil, nil)
                }
                if !FileManager.default.isWritableFile(atPath: path) {
                    return (nil, directRes.2)
                }
                return (nil, nil)
            }

            if let errorMessage = grantOutcome.errorMessage {
                throw FileManagerOpError.writeAccessDenied(
                    LocalizationManager.isEnglish
                        ? "Could not obtain write access for this directory (\(errorMessage))."
                        : "未能获取该目录的写入授权（\(errorMessage)）。"
                )
            }
            grantedPath = grantOutcome.grantedPath
        }

        do {
            let result = try work()
            if let grantedPath {
                await MainActor.run { wq.releaseAccess(path: grantedPath) }
            }
            return result
        } catch {
            if let grantedPath {
                await MainActor.run { wq.releaseAccess(path: grantedPath) }
            }
            throw error
        }
    }

    /// Translates low-level POSIX/Cocoa errors (especially EAGAIN/EBUSY/EACCES/ENOSPC) into clear bilingual guidance.
    public nonisolated static func friendlyErrorDescription(_ error: Error) -> String {
        if let opErr = error as? FileManagerOpError, let desc = opErr.errorDescription {
            return desc
        }

        let nsErr = error as NSError
        var posixCode: Int32? = nil

        if nsErr.domain == NSPOSIXErrorDomain {
            posixCode = Int32(nsErr.code)
        } else if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            posixCode = Int32(underlying.code)
        }

        if let code = posixCode {
            switch code {
            case EAGAIN, EBUSY, ETXTBSY:
                return LocalizationManager.isEnglish
                    ? "Target file is currently locked or in use by its app (or a widget/background extension, errno \(code)). Swipe-close the app from the App Switcher and try again."
                    : "目标文件正在被对应 App（或其小组件/后台扩展）占用（errno \(code)）。请先在多任务界面彻底上滑关闭对应 App 后重试。"
            case EACCES, EPERM:
                return LocalizationManager.isEnglish
                    ? "Permission denied (errno \(code)). The target may be system-protected or read-only locked (0555/0444); restore write permission in Info or Splash Ad Blocker first."
                    : "权限不足（errno \(code)）。目标可能受系统保护或处于只读锁死状态（0555/0444），请先在简介或去广告页恢复读写权限。"
            case ENOSPC:
                return LocalizationManager.isEnglish
                    ? "Not enough free storage space on this device to complete the operation."
                    : "设备可用存储空间不足，无法完成此操作。"
            case EROFS:
                return LocalizationManager.isEnglish
                    ? "Target resides on a read-only filesystem volume and cannot be modified."
                    : "目标位于只读文件系统卷，无法写入或删除。"
            default:
                break
            }
        }

        if nsErr.domain == NSCocoaErrorDomain {
            switch nsErr.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return LocalizationManager.isEnglish
                    ? "Permission denied (\(nsErr.localizedDescription)). Check if the item is read-only locked or protected."
                    : "没有操作权限（\(nsErr.localizedDescription)）。请检查目标是否处于只读锁死状态或受系统保护。"
            case NSFileWriteOutOfSpaceError:
                return LocalizationManager.isEnglish
                    ? "Not enough free storage space on this device to complete the operation."
                    : "设备可用存储空间不足，无法完成此操作。"
            case NSFileWriteFileExistsError:
                return LocalizationManager.isEnglish
                    ? "A file or folder with the same name already exists at the destination."
                    : "目标位置已存在同名文件或文件夹。"
            default:
                break
            }
        }

        return error.localizedDescription
    }
}

// MARK: - SQLite Companion Set (-wal / -shm / -journal) Guard

public enum SQLiteCompanionGuard {
    public nonisolated static let companionSuffixes = ["-wal", "-shm", "-journal"]
    private nonisolated static let sqliteExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "sqlitedb", "plsql", "storedata"
    ]
    private nonisolated static let sqliteMagicBytes: [UInt8] = Array("SQLite format 3\0".utf8)
    private nonisolated static let activeWriteWindowSeconds: TimeInterval = 10.0

    public nonisolated static func splitCompanion(filename: String) -> (baseName: String, suffix: String)? {
        let lower = filename.lowercased()
        for suffix in companionSuffixes {
            if lower.hasSuffix(suffix), filename.count > suffix.count {
                let endIdx = filename.index(filename.endIndex, offsetBy: -suffix.count)
                let base = String(filename[..<endIdx])
                let originalSuffix = String(filename[endIdx...])
                return (base, originalSuffix)
            }
        }
        return nil
    }

    public nonisolated static func companionURLs(for baseURL: URL) -> [URL] {
        let dir = baseURL.deletingLastPathComponent()
        let baseName = baseURL.lastPathComponent
        return companionSuffixes.compactMap { suffix in
            let candidate = dir.appendingPathComponent(baseName + suffix)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Detects whether `url` is a SQLite database file (by extension, companion presence, or 16-byte header magic).
    public nonisolated static func isSQLiteDatabase(_ url: URL) -> Bool {
        guard splitCompanion(filename: url.lastPathComponent) == nil else { return false }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }

        if sqliteExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        if !companionURLs(for: url).isEmpty {
            return true
        }
        guard st.st_size >= 16 else { return false }

        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var header = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &header, 16)
        return n == 16 && header == sqliteMagicBytes
    }

    /// Non-invasive check whether a SQLite database (or its WAL/journal) is actively locked or written right now.
    public nonisolated static func activeUseReason(forBaseDB baseURL: URL) -> String? {
        let dbName = baseURL.lastPathComponent
        let now = Date().timeIntervalSince1970

        // 1. Check recent non-empty WAL/journal writes within active window
        for suffix in ["-wal", "-journal"] {
            let comp = baseURL.deletingLastPathComponent().appendingPathComponent(dbName + suffix)
            var st = stat()
            if lstat(comp.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 {
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
                let age = now - mtime
                if age >= -5 && age <= activeWriteWindowSeconds {
                    return LocalizationManager.isEnglish
                        ? "SQLite database \"\(dbName)\" has active recent WAL writes (\(dbName)\(suffix)). Swipe-close the target app (widgets/extensions may also hold the database) and wait a few seconds before trying again."
                        : "检测到 SQLite 数据库「\(dbName)」刚刚有活跃写入（\(dbName)\(suffix)）。请先在多任务界面彻底上滑关闭对应 App（注意小组件/后台扩展也可能占用），稍等几秒后重试。"
                }
            }
        }

        // 2. Non-invasive read-only POSIX fcntl(F_GETLK) probe on base DB and -shm/-wal
        let probeTargets = [baseURL] + companionURLs(for: baseURL)
        for target in probeTargets {
            let fd = open(target.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == EAGAIN || errno == EBUSY {
                    return LocalizationManager.isEnglish
                        ? "SQLite database \"\(dbName)\" is currently locked by its app (errno \(errno)). Swipe-close the target app and try again."
                        : "SQLite 数据库「\(dbName)」当前正被对应 App 锁定占用（errno \(errno)）。请先上滑关闭对应 App 后重试。"
                }
                continue
            }
            defer { close(fd) }

            var fl = flock()
            fl.l_start = 0
            fl.l_len = 0
            fl.l_type = Int16(F_WRLCK)
            fl.l_whence = Int16(SEEK_SET)
            if fcntl(fd, F_GETLK, &fl) == 0 && fl.l_type != Int16(F_UNLCK) {
                return LocalizationManager.isEnglish
                    ? "SQLite database \"\(dbName)\" is actively locked by another process (PID \(fl.l_pid)). Swipe-close the target app (or its widget/extension) before modifying it."
                    : "SQLite 数据库「\(dbName)」当前正被进程（PID \(fl.l_pid)）锁定占用。请先上滑关闭对应 App（及其小组件/后台扩展）后再操作。"
            }
        }

        return nil
    }

    /// Checks whether a standalone `-wal`/`-shm`/`-journal` file has an active parent DB, or blocks raw overwrite next to an existing DB.
    public nonisolated static func guardMutation(on url: URL, operation: ProtectedFileOperation) throws {
        let name = url.lastPathComponent
        let dir = url.deletingLastPathComponent()

        if let split = splitCompanion(filename: name) {
            let baseURL = dir.appendingPathComponent(split.baseName)
            if FileManager.default.fileExists(atPath: baseURL.path) {
                if let busy = activeUseReason(forBaseDB: baseURL) {
                    throw FileManagerOpError.sqliteInUse(busy)
                }
                if operation == .overwrite {
                    throw FileManagerOpError.sqliteCompanionBlocked(
                        LocalizationManager.isEnglish
                            ? "Blocked overwriting standalone SQLite companion \"\(name)\" next to existing database \"\(split.baseName)\". Import or replace the main database together with its companions to avoid corruption."
                            : "已拦截：禁止在已有数据库「\(split.baseName)」旁单独覆盖写入伴随文件「\(name)」，否则极易导致数据库损坏。请连同主数据库一并导入或替换。"
                    )
                }
            }
            return
        }

        if isSQLiteDatabase(url) {
            if let busy = activeUseReason(forBaseDB: url) {
                throw FileManagerOpError.sqliteInUse(busy)
            }
        }
    }

    /// Bounded pre-flight scan of a folder before deleting or replacing it to abort early if any active SQLite database is locked inside.
    public nonisolated static func guardFolderNotHoldingActiveSQLite(at folderURL: URL, maxDepth: Int = 4, maxEntries: Int = 2000) throws {
        guard !FileSafetyGuard.isSymlink(at: folderURL) else { return }

        var scanned = 0
        func scan(_ dirPath: String, depth: Int) throws {
            guard depth <= maxDepth, scanned < maxEntries else { return }
            guard let dir = opendir(dirPath) else { return }
            defer { closedir(dir) }

            let dirFD = dirfd(dir)
            while let entryPtr = readdir(dir) {
                scanned += 1
                if scanned > maxEntries { return }

                let name = withUnsafePointer(to: entryPtr.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                var st = stat()
                guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let modeType = st.st_mode & S_IFMT
                let childPath = dirPath.hasSuffix("/") ? (dirPath + name) : (dirPath + "/" + name)

                if modeType == S_IFDIR {
                    if name == ".erosion_adlock" { continue }
                    try scan(childPath, depth: depth + 1)
                } else if modeType == S_IFREG {
                    if name == ".erosion_adlock" {
                        throw FileManagerOpError.protectedPath(
                            LocalizationManager.isEnglish
                                ? "This folder contains a Splash Ad Blocker sentinel (.erosion_adlock). Unlock it in Splash Ad Blocker or Info before deleting."
                                : "该文件夹内含「开屏广告缓存精准锁死」占位锁（.erosion_adlock），请先恢复读写权限后再删除。"
                        )
                    }
                    if let split = splitCompanion(filename: name) {
                        let baseURL = URL(fileURLWithPath: dirPath).appendingPathComponent(split.baseName)
                        if FileManager.default.fileExists(atPath: baseURL.path),
                           let busy = activeUseReason(forBaseDB: baseURL) {
                            throw FileManagerOpError.sqliteInUse(busy)
                        }
                    } else if sqliteExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        let dbURL = URL(fileURLWithPath: childPath)
                        if let busy = activeUseReason(forBaseDB: dbURL) {
                            throw FileManagerOpError.sqliteInUse(busy)
                        }
                    }
                }
            }
        }

        try scan(folderURL.path, depth: 0)
    }
}

// MARK: - Fast Non-Blocking POSIX Folder Size Calculator

public enum FolderSizeCalculator {
    /// Recursively sums regular file sizes under `folderURL` using low-overhead POSIX `opendir`/`fstatat`, skipping symlinks.
    public nonisolated static func computeSize(of folderURL: URL, maxEntries: Int = 50_000) -> Int64? {
        guard !FileSafetyGuard.isSymlink(at: folderURL) else { return nil }
        var total: Int64 = 0
        var visited = 0

        func walk(_ path: String) -> Bool {
            if Task.isCancelled { return false }
            guard visited < maxEntries else { return true }
            guard let dir = opendir(path) else { return true }
            defer { closedir(dir) }

            let dirFD = dirfd(dir)
            while let entryPtr = readdir(dir) {
                if Task.isCancelled { return false }
                visited += 1
                if visited > maxEntries { return true }

                let name = withUnsafePointer(to: entryPtr.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                var st = stat()
                guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let modeType = st.st_mode & S_IFMT
                if modeType == S_IFREG {
                    total += Int64(st.st_size)
                } else if modeType == S_IFDIR {
                    let childPath = path.hasSuffix("/") ? (path + name) : (path + "/" + name)
                    if !walk(childPath) { return false }
                }
            }
            return true
        }

        return walk(folderURL.path) ? total : nil
    }
}
