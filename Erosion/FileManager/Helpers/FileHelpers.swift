//
//  FileHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import Darwin
import ZIPFoundation
import UniformTypeIdentifiers

extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        if !self.fileExists(atPath: url.path) {
            try self.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

func getFileDict(_ url: URL) -> [String : Any]? {
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] {
        return dict
    }
    
    return nil
}

func getFileText(_ url: URL) -> String {
    do {
        let data = try Data(contentsOf: url)
        
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        
        return String(decoding: data, as: UTF8.self)
    } catch {
        print("(fm) failed to get text! path: \(error.localizedDescription)")
        return ""
    }
}

func makeTemp(_ fileURL: URL) -> URL? {
    do {
        let neededAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if neededAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(fileURL.lastPathComponent)")
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: fileURL, to: tempURL)
        return tempURL
    } catch {
        print("(fm) failed to make temp: \(error.localizedDescription)")
    }
    return nil
}

/// Copies one or more items into a unique temporary staging directory for batch Share Sheet export.
nonisolated func makeTempItems(_ fileURLs: [URL]) -> Result<[URL], Error> {
    do {
        let stagingDir = URL.temporaryDirectory.appendingPathComponent("erosion-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var staged: [URL] = []
        for url in fileURLs {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let dest = uniqueDestinationURL(in: stagingDir, preferredName: url.lastPathComponent)
            try copyItemSafely(from: url, to: dest)
            staged.append(dest)
        }
        return .success(staged)
    } catch {
        return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
    }
}

func generateNavPath(path: String) -> String {
    if !path.contains("/") || path.isEmpty {
        return ""
    }
    
    let file = getFileItem(at: URL(fileURLWithPath: path))
    
    if file.type == .folder || file.type == .symlink {
        return path
    }
    
    if file.type == .file {
        let navPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return navPath
    }
    return ""
}

// MARK: - Unique Collision Naming

/// Generates a non-colliding URL inside `directory` (e.g. `foo 2.txt`, `folder 2`, `archive 2.zip`).
nonisolated func uniqueDestinationURL(in directory: URL, preferredName: String, reservedNames: Set<String> = []) -> URL {
    func isTaken(_ candidateName: String) -> Bool {
        if reservedNames.contains(candidateName.lowercased()) { return true }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidateName).path)
    }

    if !isTaken(preferredName) {
        return directory.appendingPathComponent(preferredName)
    }

    let ns = preferredName as NSString
    let ext = ns.pathExtension
    let hasExt = !ext.isEmpty && !preferredName.hasPrefix(".")
    let stem = hasExt ? ns.deletingPathExtension : preferredName

    var index = 2
    while index < 10_000 {
        let candidate = hasExt ? "\(stem) \(index).\(ext)" : "\(stem) \(index)"
        if !isTaken(candidate) {
            return directory.appendingPathComponent(candidate)
        }
        index += 1
    }
    let fallback = hasExt ? "\(stem)_\(UUID().uuidString.prefix(6)).\(ext)" : "\(stem)_\(UUID().uuidString.prefix(6))"
    return directory.appendingPathComponent(fallback)
}

/// Safe recursive copy skipping non-regular special files (sockets, FIFOs, devices) without loading files into RAM.
nonisolated func copyItemSafely(from sourceURL: URL, to destURL: URL) throws {
    var st = stat()
    guard lstat(sourceURL.path, &st) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    let fileType = st.st_mode & S_IFMT
    switch fileType {
    case S_IFREG:
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
    case S_IFLNK:
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: sourceURL.path)
        try FileManager.default.createSymbolicLink(atPath: destURL.path, withDestinationPath: target)
    case S_IFDIR:
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
        for child in children {
            var childSt = stat()
            guard lstat(child.path, &childSt) == 0 else { continue }
            let childType = childSt.st_mode & S_IFMT
            // Skip sockets / FIFOs / device nodes that can exist inside app containers
            guard childType == S_IFREG || childType == S_IFDIR || childType == S_IFLNK else { continue }
            try copyItemSafely(from: child, to: destURL.appendingPathComponent(child.lastPathComponent))
        }
    default:
        break
    }
}

// MARK: - Rename (Files, Folders & SQLite Companion Sets)

nonisolated func renameItemDetailed(_ url: URL, to newName: String) async -> Result<URL, Error> {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
        return .failure(FileManagerOpError.invalidName(
            LocalizationManager.isEnglish
                ? "Invalid name. The name cannot be empty, '.', '..', or contain '/'."
                : "名称无效：不能为空、不能为 '.' 或 '..'，且不能包含斜杠 '/'。"
        ))
    }

    if let reason = FileSafetyGuard.protectionReason(for: url, operation: .rename) {
        return .failure(FileManagerOpError.protectedPath(reason))
    }
    if let nameReason = FileSafetyGuard.protectedFilenameReason(trimmed) {
        return .failure(FileManagerOpError.protectedPath(nameReason))
    }

    let parentDir = url.deletingLastPathComponent()
    let targetURL = parentDir.appendingPathComponent(trimmed)
    if targetURL.standardizedFileURL.path == url.standardizedFileURL.path {
        return .success(url)
    }

    do {
        try SQLiteCompanionGuard.guardMutation(on: url, operation: .rename)

        let isSQLite = SQLiteCompanionGuard.isSQLiteDatabase(url)
        let companions = isSQLite ? SQLiteCompanionGuard.companionURLs(for: url) : []

        return try await FileSafetyGuard.withWriteAccess(for: parentDir) {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                throw FileManagerOpError.targetAlreadyExists(
                    LocalizationManager.isEnglish
                        ? "An item named \"\(trimmed)\" already exists in this folder."
                        : "当前目录已存在名为「\(trimmed)」的文件或文件夹。"
                )
            }
            for comp in companions {
                if let split = SQLiteCompanionGuard.splitCompanion(filename: comp.lastPathComponent) {
                    let targetComp = parentDir.appendingPathComponent(trimmed + split.suffix)
                    if FileManager.default.fileExists(atPath: targetComp.path) {
                        throw FileManagerOpError.targetAlreadyExists(
                            LocalizationManager.isEnglish
                                ? "Companion file \"\(targetComp.lastPathComponent)\" already exists."
                                : "伴随文件「\(targetComp.lastPathComponent)」已存在，无法同步重命名。"
                        )
                    }
                }
            }

            // Atomic POSIX rename() via moveItem, moving SQLite companions together with rollback on failure
            var movedPairs: [(from: URL, to: URL)] = []
            do {
                try FileManager.default.moveItem(at: url, to: targetURL)
                movedPairs.append((url, targetURL))
                for comp in companions {
                    if let split = SQLiteCompanionGuard.splitCompanion(filename: comp.lastPathComponent) {
                        let targetComp = parentDir.appendingPathComponent(trimmed + split.suffix)
                        try FileManager.default.moveItem(at: comp, to: targetComp)
                        movedPairs.append((comp, targetComp))
                    }
                }
                return .success(targetURL)
            } catch {
                for pair in movedPairs.reversed() {
                    try? FileManager.default.moveItem(at: pair.to, to: pair.from)
                }
                throw error
            }
        }
    } catch {
        print("(fm) failed to rename \(url.lastPathComponent): \(error.localizedDescription)")
        return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
    }
}

// MARK: - Delete (Single & Batch with Protection + SQLite Set Guard)

nonisolated func deleteItemsDetailed(_ urls: [URL]) async -> BatchOperationReport {
    // Sort shallowest paths first and deduplicate descendants of already-selected folders
    let sorted = urls.sorted {
        FileSafetyGuard.canonicalPath($0).count < FileSafetyGuard.canonicalPath($1).count
    }
    var deduped: [URL] = []
    var acceptedFolderPrefixes: [String] = []
    for url in sorted {
        let canon = FileSafetyGuard.canonicalPath(url)
        if acceptedFolderPrefixes.contains(where: { canon.hasPrefix($0) }) {
            continue
        }
        deduped.append(url)
        var st = stat()
        if lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
            acceptedFolderPrefixes.append(canon.hasSuffix("/") ? canon : canon + "/")
        }
    }

    var succeeded = 0
    var skipped = 0
    var failures: [BatchOperationFailure] = []
    var alreadyRemovedCanon: Set<String> = []

    for url in deduped {
        let canon = FileSafetyGuard.canonicalPath(url)
        if alreadyRemovedCanon.contains(canon) {
            skipped += 1
            continue
        }

        let name = url.lastPathComponent
        if let reason = FileSafetyGuard.protectionReason(for: url, operation: .delete) {
            failures.append(BatchOperationFailure(name: name, reason: reason))
            continue
        }

        let parentDir = url.deletingLastPathComponent()
        do {
            var st = stat()
            guard lstat(url.path, &st) == 0 else {
                if errno == ENOENT {
                    skipped += 1
                    continue
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if isDir {
                try SQLiteCompanionGuard.guardFolderNotHoldingActiveSQLite(at: url)
            } else {
                try SQLiteCompanionGuard.guardMutation(on: url, operation: .delete)
            }

            let isSQLite = !isDir && SQLiteCompanionGuard.isSQLiteDatabase(url)
            let companions = isSQLite ? SQLiteCompanionGuard.companionURLs(for: url) : []

            try await FileSafetyGuard.withWriteAccess(for: parentDir) {
                try FileManager.default.removeItem(at: url)
                alreadyRemovedCanon.insert(canon)
                for comp in companions {
                    if FileManager.default.fileExists(atPath: comp.path) {
                        try? FileManager.default.removeItem(at: comp)
                        alreadyRemovedCanon.insert(FileSafetyGuard.canonicalPath(comp))
                    }
                }
            }
            succeeded += 1
        } catch {
            print("(fm) failed to delete \(name): \(error.localizedDescription)")
            failures.append(BatchOperationFailure(name: name, reason: FileSafetyGuard.friendlyErrorDescription(error)))
        }
    }

    return BatchOperationReport(succeededCount: succeeded, skippedCount: skipped, failures: failures, createdURLs: [])
}

// MARK: - Zip (Single & Batch)

nonisolated func zipItemsDetailed(_ urls: [URL], in directory: URL, archiveBaseName: String? = nil) async -> Result<URL, Error> {
    guard !urls.isEmpty else {
        return .failure(FileManagerOpError.operationFailed(
            LocalizationManager.isEnglish ? "No items selected to compress." : "未选择需要压缩的项目。"
        ))
    }

    let baseName: String
    if let custom = archiveBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
        baseName = custom.lowercased().hasSuffix(".zip") ? custom : (custom + ".zip")
    } else if urls.count == 1 {
        baseName = urls[0].lastPathComponent + ".zip"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        baseName = "Archive_\(formatter.string(from: Date())).zip"
    }

    do {
        return try await FileSafetyGuard.withWriteAccess(for: directory) {
            let zipDest = uniqueDestinationURL(in: directory, preferredName: baseName)

            if urls.count == 1, !FileSafetyGuard.isSymlink(at: urls[0]) {
                var st = stat()
                if lstat(urls[0].path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                    try FileManager.default.zipItem(at: urls[0], to: zipDest, shouldKeepParent: true)
                    return .success(zipDest)
                }
            }

            let archive = try Archive(url: zipDest, accessMode: .create)
            var addedEntries = 0
            do {
                for itemURL in urls {
                    let parent = itemURL.deletingLastPathComponent()
                    let rootName = itemURL.lastPathComponent
                    var st = stat()
                    guard lstat(itemURL.path, &st) == 0 else { continue }
                    let modeType = st.st_mode & S_IFMT

                    if modeType == S_IFREG || modeType == S_IFLNK {
                        try archive.addEntry(with: rootName, relativeTo: parent)
                        addedEntries += 1
                    } else if modeType == S_IFDIR {
                        try archive.addEntry(with: rootName, relativeTo: parent)
                        addedEntries += 1
                        if let enumerator = FileManager.default.enumerator(
                            at: itemURL,
                            includingPropertiesForKeys: nil,
                            options: []
                        ) {
                            let basePrefix = itemURL.standardizedFileURL.path.hasSuffix("/")
                                ? itemURL.standardizedFileURL.path
                                : itemURL.standardizedFileURL.path + "/"
                            for case let childURL as URL in enumerator {
                                var childSt = stat()
                                guard lstat(childURL.path, &childSt) == 0 else { continue }
                                let cType = childSt.st_mode & S_IFMT
                                guard cType == S_IFREG || cType == S_IFDIR || cType == S_IFLNK else { continue }

                                let childStd = childURL.standardizedFileURL.path
                                guard childStd.hasPrefix(basePrefix) else { continue }
                                let relSub = String(childStd.dropFirst(basePrefix.count))
                                guard !relSub.isEmpty else { continue }
                                try archive.addEntry(with: "\(rootName)/\(relSub)", relativeTo: parent)
                                addedEntries += 1
                            }
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: zipDest)
                throw error
            }

            guard addedEntries > 0 else {
                try? FileManager.default.removeItem(at: zipDest)
                throw FileManagerOpError.operationFailed(
                    LocalizationManager.isEnglish ? "No readable files were found to compress." : "未找到可压缩的有效文件。"
                )
            }
            return .success(zipDest)
        }
    } catch {
        print("(fm) failed to zip items: \(error.localizedDescription)")
        return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
    }
}

// MARK: - Unzip (Pre-flight Validated + Detailed Error + Optional Subfolder)

nonisolated func unzipFileDetailed(_ url: URL, toSubfolder: Bool = false) async -> Result<(destination: URL, entryCount: Int), Error> {
    do {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            let reason = FileSafetyGuard.friendlyErrorDescription(error)
            throw FileManagerOpError.operationFailed(
                LocalizationManager.isEnglish
                    ? "Cannot open ZIP archive \"\(url.lastPathComponent)\": \(reason)"
                    : "无法读取 ZIP 压缩包「\(url.lastPathComponent)」：\(reason)"
            )
        }

        let parentDir = url.deletingLastPathComponent().standardizedFileURL
        let targetDest: URL
        if toSubfolder {
            let stem = url.deletingPathExtension().lastPathComponent
            let preferredFolder = stem.isEmpty ? "Extracted" : stem
            targetDest = uniqueDestinationURL(in: parentDir, preferredName: preferredFolder).standardizedFileURL
        } else {
            targetDest = parentDir
        }

        let destPrefix = targetDest.path.hasSuffix("/") ? targetDest.path : targetDest.path + "/"
        var entryCount = 0
        var existingConflicts: [String] = []
        var checkedTopLevel: Set<String> = []

        for entry in archive {
            entryCount += 1
            let entryPath = entry.path
            let slashComponents = entryPath.split(separator: "/")
            let backslashComponents = entryPath.split(separator: "\\")

            if entryPath.hasPrefix("/") || slashComponents.contains("..") || backslashComponents.contains("..") {
                throw FileManagerOpError.protectedPath(
                    LocalizationManager.isEnglish
                        ? "Blocked: Archive contains an unsafe path traversal entry (\(entryPath))."
                        : "已拦截：检测到压缩包包含非法路径穿越条目（\(entryPath)），已拒绝解压。"
                )
            }

            let resolvedURL = targetDest.appendingPathComponent(entryPath).standardizedFileURL
            let resolvedPath = resolvedURL.path
            if resolvedPath != targetDest.path && !resolvedPath.hasPrefix(destPrefix) {
                throw FileManagerOpError.protectedPath(
                    LocalizationManager.isEnglish
                        ? "Blocked: Archive entry escapes destination directory (\(entryPath))."
                        : "已拦截：检测到压缩包条目越界（\(entryPath)），已拒绝解压。"
                )
            }

            if let protectedName = FileSafetyGuard.protectedFilenameReason(resolvedURL.lastPathComponent) {
                throw FileManagerOpError.protectedPath(protectedName)
            }

            // Validate symlink payload inside archive so it cannot escape targetDest
            if entry.type == .symlink {
                var linkData = Data()
                if entry.uncompressedSize <= 4096 {
                    _ = try archive.extract(entry) { chunk in
                        linkData.append(chunk)
                    }
                    if let linkTarget = String(data: linkData, encoding: .utf8) {
                        let resolvedLink = URL(
                            fileURLWithPath: linkTarget,
                            relativeTo: resolvedURL.deletingLastPathComponent()
                        ).standardizedFileURL.path
                        if resolvedLink != targetDest.path && !resolvedLink.hasPrefix(destPrefix) {
                            throw FileManagerOpError.protectedPath(
                                LocalizationManager.isEnglish
                                    ? "Blocked: Archive symlink \"\(entryPath)\" points outside the destination directory."
                                    : "已拦截：压缩包内符号链接「\(entryPath)」指向目标目录之外，已拒绝解压。"
                            )
                        }
                    }
                }
            }

            // Pre-check collision & SQLite locks when extracting directly into current directory
            if !toSubfolder {
                if let topComp = slashComponents.first.map(String.init),
                   !topComp.isEmpty,
                   topComp != "__MACOSX",
                   !checkedTopLevel.contains(topComp) {
                    checkedTopLevel.insert(topComp)
                    let topURL = targetDest.appendingPathComponent(topComp)
                    if FileManager.default.fileExists(atPath: topURL.path) {
                        existingConflicts.append(topComp)
                    }
                }
                if FileManager.default.fileExists(atPath: resolvedPath) {
                    try SQLiteCompanionGuard.guardMutation(on: resolvedURL, operation: .overwrite)
                }
            }
        }

        guard entryCount > 0 else {
            throw FileManagerOpError.operationFailed(
                LocalizationManager.isEnglish
                    ? "The ZIP archive \"\(url.lastPathComponent)\" is empty."
                    : "压缩包「\(url.lastPathComponent)」为空，没有可解压的内容。"
            )
        }

        if !toSubfolder && !existingConflicts.isEmpty {
            let preview = existingConflicts.prefix(3).joined(separator: ", ")
            let suffix = existingConflicts.count > 3 ? "…" : ""
            throw FileManagerOpError.targetAlreadyExists(
                LocalizationManager.isEnglish
                    ? "Destination already contains \(preview)\(suffix). Choose \"Extract to Subfolder\" or remove existing item(s) first."
                    : "当前目录已存在同名项目（\(preview)\(suffix)），无法直接覆盖解压。请选择「解压到同名文件夹」或先移除同名项目。"
            )
        }

        return try await FileSafetyGuard.withWriteAccess(for: parentDir) {
            if toSubfolder {
                try FileManager.default.createDirectory(at: targetDest, withIntermediateDirectories: true)
            }
            do {
                try FileManager.default.unzipItem(at: url, to: targetDest)
            } catch {
                if toSubfolder {
                    try? FileManager.default.removeItem(at: targetDest)
                }
                throw error
            }
            return .success((targetDest, entryCount))
        }
    } catch {
        print("(fm) failed to uncompress file \(url.lastPathComponent): \(error.localizedDescription)")
        return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
    }
}

// MARK: - Duplicate (Streaming + Non-Colliding Name)

nonisolated func duplicateItemDetailed(_ url: URL) async -> Result<URL, Error> {
    let parentDir = url.deletingLastPathComponent()
    let preferredName: String = {
        let ext = url.pathExtension
        if ext.isEmpty || url.lastPathComponent.hasPrefix(".") {
            return "\(url.lastPathComponent)_copy"
        }
        return "\(url.deletingPathExtension().lastPathComponent)_copy.\(ext)"
    }()

    do {
        return try await FileSafetyGuard.withWriteAccess(for: parentDir) {
            let targetURL = uniqueDestinationURL(in: parentDir, preferredName: preferredName)
            try copyItemSafely(from: url, to: targetURL)
            return .success(targetURL)
        }
    } catch {
        print("(fm) failed to duplicate \(url.lastPathComponent): \(error.localizedDescription)")
        return .failure(FileManagerOpError.operationFailed(FileSafetyGuard.friendlyErrorDescription(error)))
    }
}

// MARK: - Import Files & Folders (Streaming, Security-Scoped, SQLite-Safe)

/// Scans incoming URLs to determine which item names already exist in `destDir`.
nonisolated func detectImportCollisions(sourceURLs: [URL], destDir: URL) -> [String] {
    var collisions: [String] = []
    for src in sourceURLs {
        let name = src.lastPathComponent
        let dest = destDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            collisions.append(name)
        }
    }
    return collisions
}

/// Imports one or more files and/or folders recursively into `destDir` with collision handling and safety guards.
nonisolated func importItemsDetailed(
    from sourceURLs: [URL],
    to destDir: URL,
    collisionPolicy: ImportCollisionPolicy
) async -> BatchOperationReport {
    var succeeded = 0
    var failures: [BatchOperationFailure] = []
    var createdURLs: [URL] = []

    // Process base SQLite files before companion (-wal/-shm/-journal) files so Keep Both keeps companion stems in sync
    let orderedSources = sourceURLs.sorted { lhs, rhs in
        let lIsComp = SQLiteCompanionGuard.splitCompanion(filename: lhs.lastPathComponent) != nil
        let rIsComp = SQLiteCompanionGuard.splitCompanion(filename: rhs.lastPathComponent) != nil
        if lIsComp != rIsComp { return !lIsComp }
        return lhs.lastPathComponent < rhs.lastPathComponent
    }

    let destCanon = FileSafetyGuard.canonicalPath(destDir)
    var renamedBaseMap: [String: String] = [:] // original base filename -> new renamed filename (for SQLite companions)
    var reservedNames: Set<String> = []
    let incomingNamesLower = Set(orderedSources.map { $0.lastPathComponent.lowercased() })

    do {
        try await FileSafetyGuard.withWriteAccess(for: destDir) {
            for srcURL in orderedSources {
                let name = srcURL.lastPathComponent
                let accessed = srcURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed { srcURL.stopAccessingSecurityScopedResource() }
                }

                do {
                    if let protectedReason = FileSafetyGuard.protectedFilenameReason(name) {
                        throw FileManagerOpError.protectedPath(protectedReason)
                    }

                    let srcCanon = FileSafetyGuard.canonicalPath(srcURL)
                    var srcStat = stat()
                    guard lstat(srcURL.path, &srcStat) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    let srcIsDir = (srcStat.st_mode & S_IFMT) == S_IFDIR

                    // Prevent importing a folder into itself or its own subdirectory
                    if srcIsDir {
                        if destCanon == srcCanon || destCanon.hasPrefix(srcCanon + "/") {
                            throw FileManagerOpError.protectedPath(
                                LocalizationManager.isEnglish
                                    ? "Cannot import folder \"\(name)\" into itself or one of its subfolders."
                                    : "无法将文件夹「\(name)」导入到其自身或子目录内。"
                            )
                        }
                        if let blockedInside = findProtectedFilenameInsideFolder(srcURL) {
                            throw FileManagerOpError.protectedPath(blockedInside)
                        }
                    }

                    let rawDestURL = destDir.appendingPathComponent(name)
                    let destExists = FileManager.default.fileExists(atPath: rawDestURL.path)

                    // Guard against dropping a standalone SQLite companion (-wal/-shm/-journal) next to an existing DB
                    if let split = SQLiteCompanionGuard.splitCompanion(filename: name) {
                        let baseInBatch = incomingNamesLower.contains(split.baseName.lowercased())
                        let existingBase = destDir.appendingPathComponent(split.baseName)
                        if !baseInBatch && FileManager.default.fileExists(atPath: existingBase.path) {
                            if let busy = SQLiteCompanionGuard.activeUseReason(forBaseDB: existingBase) {
                                throw FileManagerOpError.sqliteInUse(busy)
                            }
                            throw FileManagerOpError.sqliteCompanionBlocked(
                                LocalizationManager.isEnglish
                                    ? "Blocked importing standalone SQLite companion \"\(name)\" next to existing database \"\(split.baseName)\". Import the main database together with its companions to avoid corruption."
                                    : "已拦截：禁止在已有数据库「\(split.baseName)」旁单独导入伴随文件「\(name)」，否则可能导致数据库损坏。请连同主数据库一并导入。"
                            )
                        }
                    }

                    // Determine final destination URL
                    let finalDestURL: URL
                    if collisionPolicy == .keepBoth {
                        if let split = SQLiteCompanionGuard.splitCompanion(filename: name),
                           let mappedBase = renamedBaseMap[split.baseName] {
                            finalDestURL = destDir.appendingPathComponent(mappedBase + split.suffix)
                        } else if destExists || reservedNames.contains(name.lowercased()) {
                            finalDestURL = uniqueDestinationURL(in: destDir, preferredName: name, reservedNames: reservedNames)
                            renamedBaseMap[name] = finalDestURL.lastPathComponent
                        } else {
                            finalDestURL = rawDestURL
                        }
                        reservedNames.insert(finalDestURL.lastPathComponent.lowercased())

                        if FileSafetyGuard.canonicalPath(finalDestURL) == srcCanon {
                            let dupDest = uniqueDestinationURL(in: destDir, preferredName: name, reservedNames: reservedNames)
                            try copyItemSafely(from: srcURL, to: dupDest)
                            createdURLs.append(dupDest)
                        } else {
                            try copyItemSafely(from: srcURL, to: finalDestURL)
                            createdURLs.append(finalDestURL)
                        }
                        succeeded += 1
                    } else {
                        // Replace policy
                        if FileSafetyGuard.canonicalPath(rawDestURL) == srcCanon {
                            succeeded += 1
                            continue
                        }

                        if destExists {
                            if let reason = FileSafetyGuard.protectionReason(for: rawDestURL, operation: .overwrite) {
                                throw FileManagerOpError.protectedPath(reason)
                            }
                            var destStat = stat()
                            let destIsDir = (lstat(rawDestURL.path, &destStat) == 0) && ((destStat.st_mode & S_IFMT) == S_IFDIR)
                            if destIsDir {
                                try SQLiteCompanionGuard.guardFolderNotHoldingActiveSQLite(at: rawDestURL)
                            } else if let split = SQLiteCompanionGuard.splitCompanion(filename: name),
                                      incomingNamesLower.contains(split.baseName.lowercased()) {
                                // Companion replaced together with its base DB in the same import batch: only verify not busy
                                let baseURL = destDir.appendingPathComponent(split.baseName)
                                if let busy = SQLiteCompanionGuard.activeUseReason(forBaseDB: baseURL) {
                                    throw FileManagerOpError.sqliteInUse(busy)
                                }
                            } else {
                                try SQLiteCompanionGuard.guardMutation(on: rawDestURL, operation: .overwrite)
                            }

                            if !srcIsDir && !destIsDir {
                                let srcSize = Int64(srcStat.st_size)
                                let replacingSQLite = SQLiteCompanionGuard.isSQLiteDatabase(rawDestURL) || SQLiteCompanionGuard.isSQLiteDatabase(srcURL)

                                if srcSize > 0 && srcSize <= 32 * 1024 * 1024 {
                                    // Preserve inode & POSIX metadata via atomic in-place write for files <= 32 MB
                                    let data = try Data(contentsOf: srcURL)
                                    let atomicRes = writeFileAtomically(data, to: rawDestURL, allowEmpty: true)
                                    guard atomicRes.0 else {
                                        throw FileManagerOpError.operationFailed(atomicRes.1)
                                    }
                                } else {
                                    // Stream large files via temp sibling + replaceItemAt (zero RAM spike)
                                    let stageURL = destDir.appendingPathComponent(".\(name).erosion-import-\(UUID().uuidString).tmp")
                                    defer { try? FileManager.default.removeItem(at: stageURL) }
                                    try copyItemSafely(from: srcURL, to: stageURL)
                                    _ = try FileManager.default.replaceItemAt(rawDestURL, withItemAt: stageURL)
                                }

                                // Clean stale SQLite companions on disk if caller replaced the DB without importing matching companions
                                if replacingSQLite {
                                    for suffix in SQLiteCompanionGuard.companionSuffixes {
                                        let compName = name + suffix
                                        if !incomingNamesLower.contains(compName.lowercased()) {
                                            let staleComp = destDir.appendingPathComponent(compName)
                                            if FileManager.default.fileExists(atPath: staleComp.path) {
                                                try? FileManager.default.removeItem(at: staleComp)
                                            }
                                        }
                                    }
                                }
                            } else {
                                // Replacing a directory (or swapping file <-> directory): stage first, backup old, swap with rollback
                                let stageURL = destDir.appendingPathComponent(".\(name).erosion-import-\(UUID().uuidString).tmp")
                                let backupURL = destDir.appendingPathComponent(".\(name).erosion-backup-\(UUID().uuidString).tmp")
                                defer { try? FileManager.default.removeItem(at: stageURL) }
                                try copyItemSafely(from: srcURL, to: stageURL)
                                try FileManager.default.moveItem(at: rawDestURL, to: backupURL)
                                do {
                                    try FileManager.default.moveItem(at: stageURL, to: rawDestURL)
                                    try? FileManager.default.removeItem(at: backupURL)
                                } catch {
                                    try? FileManager.default.moveItem(at: backupURL, to: rawDestURL)
                                    throw error
                                }
                            }
                        } else {
                            try copyItemSafely(from: srcURL, to: rawDestURL)
                        }

                        createdURLs.append(rawDestURL)
                        succeeded += 1
                    }
                } catch {
                    print("(fm) failed to import \(name): \(error.localizedDescription)")
                    failures.append(BatchOperationFailure(name: name, reason: FileSafetyGuard.friendlyErrorDescription(error)))
                }
            }
        }
    } catch {
        let reason = FileSafetyGuard.friendlyErrorDescription(error)
        for srcURL in orderedSources {
            failures.append(BatchOperationFailure(name: srcURL.lastPathComponent, reason: reason))
        }
    }

    return BatchOperationReport(succeededCount: succeeded, skippedCount: 0, failures: failures, createdURLs: createdURLs)
}

private nonisolated func findProtectedFilenameInsideFolder(_ folderURL: URL, maxEntries: Int = 5000) -> String? {
    guard let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
        return nil
    }
    var count = 0
    for case let itemURL as URL in enumerator {
        count += 1
        if count > maxEntries { break }
        if let reason = FileSafetyGuard.protectedFilenameReason(itemURL.lastPathComponent) {
            return reason
        }
    }
    return nil
}

// MARK: - Clipboard & Viewer Type Checks

func copyFileToClipboard(_ url: URL) -> Bool {
    do {
        guard let tempURL = makeTemp(url) else {
            throw "failed to make temp!"
        }
        let data = try Data(contentsOf: tempURL)
        let utType = UTType(filenameExtension: tempURL.pathExtension) ?? .data
        
        UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
        return true
    } catch {
        print("(fm) failed to copy file: \(error.localizedDescription)")
    }
    return false
}

private nonisolated func regularFileSizeIfSmall(_ url: URL, limitBytes: Int64 = 8 * 1024 * 1024) -> Bool {
    var st = stat()
    guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
    return Int64(st.st_size) <= limitBytes
}

func conformsToPlistViewer(_ url: URL) -> Bool {
    guard regularFileSizeIfSmall(url) else { return false }
    do {
        guard let data = try? Data(contentsOf: url) else { return false }
        let _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any]
        return true
    } catch {
        return false
    }
}

func conformsToTextViewer(_ url: URL) -> Bool {
    guard regularFileSizeIfSmall(url) else { return false }
    do {
        let _ = try String(contentsOf: url, encoding: .utf8)
        return true
    } catch {
        return false
    }
}
