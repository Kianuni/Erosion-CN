//
//  VoiceMemosAIView.swift
//  Erosion
//
//  [Experimental / 测试特性]
//  1. Lossless Voice Memos & Call Recording audio extractor (CloudRecordings.db APFS snapshot + batch ZIP).
//  2. On-device AI / Offline Translation & Speech Model cache readiness inspector.
//

import SwiftUI
import SQLite3
import ZIPFoundation

struct VoiceMemoRecordingItem: Identifiable {
    let id: String
    let fileURL: URL
    let displayTitle: String
    let originalFileName: String
    let durationSeconds: Double?
    let createdAt: Date
    let fileSizeBytes: Int64
}

struct AIModelCacheProbeItem: Identifiable {
    let id: String
    let title: String
    let identifier: String
    let accessible: Bool
    let fileCount: Int
    let totalBytes: Int64
    let statusNote: String
}

struct VoiceMemosAIView: View {
    @State private var isScanning = false
    @State private var isZipping = false
    @State private var statusText = "点击右上角刷新扫描录音库与端侧 AI 模型缓存"
    @State private var recordings: [VoiceMemoRecordingItem] = []
    @State private var modelProbes: [AIModelCacheProbeItem] = []

    private var totalRecordingBytes: Int64 {
        recordings.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(Color.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("测试特性 · 语音备忘录提取与端侧模型体检")
                            .font(.subheadline.weight(.semibold))
                        Text("全程以纯只读快照方式解析语音备忘录与通话录音（保留自定义标题与无损 .m4a 音轨），并探测本机离线翻译、语音转写与端侧 AI 模型资产缓存体积。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已发现 \(recordings.count) 段无损录音音频")
                            .font(.subheadline.weight(.medium))
                        Text("总音频体积：\(AppContainerDirectoryHelper.formatBytes(totalRecordingBytes)) · \(statusText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isScanning || isZipping {
                        ProgressView()
                    }
                }

                if !recordings.isEmpty {
                    Button {
                        exportAllRecordingsAsZip()
                    } label: {
                        Label("一键无损打包全部录音导出 (.zip)", systemImage: "archivebox.fill")
                    }
                    .disabled(isZipping)
                }
            } header: {
                HeaderLabel("[测试特性] 语音备忘录与通话录音概览", symbol: "waveform")
            }

            if !recordings.isEmpty {
                Section {
                    ForEach(recordings) { rec in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rec.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if let dur = rec.durationSeconds, dur > 0 {
                                        Text(Self.formatDuration(dur))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.blue)
                                    }
                                    Text(AppContainerDirectoryHelper.formatBytes(rec.fileSizeBytes))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("· \(Self.dateFormatter.string(from: rec.createdAt))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(rec.originalFileName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                exportSingleRecording(rec)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HeaderLabel("无损录音音轨列表 (\(recordings.count)) [测试]", symbol: "mic.fill")
                }
            }

            Section {
                liveAIRow(
                    title: "Apple 智能总准入 (含通话录音与转写)",
                    active: mgQueryLiveBool(forKey: MGKey.appIntell) ?? false
                )
                liveAIRow(
                    title: "国行 green-tea 底层门禁已解除",
                    active: !(mgQueryLiveBool(forKey: MGCacheDataLayout.greenTeaKey) ?? false)
                )
                audioIntellStatusRow()

                ForEach(modelProbes) { probe in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(probe.title)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(probe.accessible ? AppContainerDirectoryHelper.formatBytes(probe.totalBytes) : "沙盒隔离")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(probe.accessible ? (probe.totalBytes > 0 ? Color.green : Color.secondary) : Color.orange)
                        }
                        Text("\(probe.identifier) · \(probe.statusNote)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HeaderLabel("[测试特性] 端侧 AI 与离线语音/视觉模型体检", symbol: "brain.head.profile")
            } footer: {
                Text("注：Apple Intelligence 核心大模型权重由系统受保护守护进程托管于 MobileAsset 只读卷中，此处统计可读的系统翻译、语音备忘录转写与视觉分析容器资产缓存。")
            }
        }
        .navigationTitle("录音提取与模型体检")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scanAll()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning || isZipping)
            }
        }
        .onAppear {
            if recordings.isEmpty && modelProbes.isEmpty && !isScanning {
                scanAll()
            }
        }
    }

    @ViewBuilder
    private func liveAIRow(title: String, active: Bool, inactiveLabel: String = "未激活") -> some View {
        HStack {
            Text(title)
                .font(.footnote)
            Spacer()
            Text(active ? "✅ 已就绪" : inactiveLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.green : Color.secondary)
        }
    }

    @ViewBuilder
    private func audioIntellStatusRow() -> some View {
        let nativeAudio = isNativeAudioIntellHD()
        let liveConflict = !isAdvAppleIntellHD() && (
            (mgQueryLiveBool(forKey: MGKey.personalTranslator) ?? false) ||
            (!nativeAudio && (mgQueryLiveBool(forKey: MGKey.audioIntell) ?? false))
        )
        let stagedConflict = GestaltStore.shared.isAdvAppleIntellConflictActive()

        if isAdvAppleIntellHD() || (nativeAudio && !stagedConflict && !liveConflict) {
            liveAIRow(title: "iOS 27 音频智能 (本机硬件原生支持)", active: true)
        } else if stagedConflict || liveConflict {
            NavigationLink(destination: GestaltView()) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("iOS 27 进阶 AI 实验槽位")
                            .font(.footnote)
                        Spacer()
                        Text(stagedConflict ? "⚠️ 已开启 · 去关闭修复" : "⏳ 已关闭 · 待重启生效")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }
                    Text("提示：iPhone/iPad 强开此实验槽位会导致照片“高质量”消除报错，建议保持关闭（不影响常规通话录音与转写）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("常规通话录音与语音备忘录转写")
                        .font(.footnote)
                    Spacer()
                    Text((mgQueryLiveBool(forKey: MGKey.appIntell) ?? false) ? "✅ 已完整就绪" : "待激活主开关")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle((mgQueryLiveBool(forKey: MGKey.appIntell) ?? false) ? Color.green : Color.secondary)
                }
                Text("已由主 Apple 智能开关原生驱动；实验性 AudioIntelligence 槽位已保持关闭以保障照片“高质量”消除正常")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    private static func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recording" : cleaned
    }

    private func exportSingleRecording(_ rec: VoiceMemoRecordingItem) {
        let ext = rec.fileURL.pathExtension.isEmpty ? "m4a" : rec.fileURL.pathExtension
        let safeTitle = Self.sanitizeFileName(rec.displayTitle)
        let outURL = fm.temporaryDirectory.appendingPathComponent("\(safeTitle).\(ext)")
        do {
            _ = wq.grantAccess(path: rec.fileURL.deletingLastPathComponent().path, requireWrite: false)
            try? fm.removeItem(at: outURL)
            try fm.copyItem(at: rec.fileURL, to: outURL)
            Haptic.shared.play(.soft)
            presentShareSheet(with: outURL)
        } catch {
            Alertinator.shared.alert(title: "导出录音失败！", body: error.localizedDescription)
        }
    }

    private func exportAllRecordingsAsZip() {
        guard !recordings.isEmpty else { return }
        isZipping = true
        DispatchQueue.global(qos: .userInitiated).async {
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("VoiceMemosExport_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: stagingDir) }

            do {
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                var usedNames = Set<String>()
                var copiedCount = 0

                for rec in recordings {
                    _ = wq.grantAccess(path: rec.fileURL.deletingLastPathComponent().path, requireWrite: false)
                    let ext = rec.fileURL.pathExtension.isEmpty ? "m4a" : rec.fileURL.pathExtension
                    let base = Self.sanitizeFileName(rec.displayTitle)
                    var candidate = "\(base).\(ext)"
                    var suffix = 2
                    while usedNames.contains(candidate.lowercased()) {
                        candidate = "\(base)_\(suffix).\(ext)"
                        suffix += 1
                    }
                    usedNames.insert(candidate.lowercased())
                    let dst = stagingDir.appendingPathComponent(candidate)
                    if (try? fm.copyItem(at: rec.fileURL, to: dst)) != nil {
                        copiedCount += 1
                    }
                }

                guard copiedCount > 0 else {
                    throw "未能读取任何录音音频文件。"
                }

                let stamp = DateFormatter()
                stamp.dateFormat = "yyyyMMdd_HHmmss"
                let zipURL = fm.temporaryDirectory.appendingPathComponent("Erosion_VoiceMemos_\(stamp.string(from: Date())).zip")
                try? fm.removeItem(at: zipURL)
                try fm.zipItem(at: stagingDir, to: zipURL, shouldKeepParent: false)

                DispatchQueue.main.async {
                    self.isZipping = false
                    Haptic.shared.play(.soft)
                    presentShareSheet(with: zipURL)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    Alertinator.shared.alert(title: "打包录音失败！", body: error.localizedDescription)
                }
            }
        }
    }

    private func scanAll() {
        isScanning = true
        statusText = "正在秒级探测模型缓存与语音备忘录容器..."
        DispatchQueue.global(qos: .utility).async {
            // 1. Instant probe of AI/Translation containers via CSStore2 + fixed SystemGroup paths (<50ms)
            let probes = Self.probeAIModelCaches()
            DispatchQueue.main.async {
                self.modelProbes = probes
                self.statusText = "正在扫描语音备忘录录音库..."
            }

            // 2. Discover Voice Memos (App Container first, then AppGroup with progress)
            let foundRecordings = Self.discoverVoiceMemos { progressMsg in
                DispatchQueue.main.async {
                    self.statusText = progressMsg
                }
            }

            DispatchQueue.main.async {
                self.recordings = foundRecordings
                self.statusText = foundRecordings.isEmpty
                    ? "未发现本地语音备忘录音频（或尚未录制音频）"
                    : "已完成 CloudRecordings 元数据映射"
                self.isScanning = false
            }
        }
    }

    private struct RecordingDBMeta {
        let title: String
        let duration: Double?
    }

    private static func discoverVoiceMemos(onProgress: @escaping (String) -> Void) -> [VoiceMemoRecordingItem] {
        var candidateRoots: [URL] = []

        // 1. App Data Container: com.apple.VoiceMemos (instant via CSStore2)
        let vmContainer = fsHandlers.getContainerPath(at: FSURL.appContainers, forMatch: "com.apple.VoiceMemos")
        if !vmContainer.isEmpty {
            let url = URL(fileURLWithPath: vmContainer)
            _ = wq.grantAccess(path: url.path, requireWrite: false)
            candidateRoots.append(url)
        }

        // 2. AppGroup: group.com.apple.VoiceMemos.shared
        let groupPaths = fsHandlers.getDirPaths(FSURL.appGroup.path)
        for (idx, p) in groupPaths.enumerated() {
            if idx % 30 == 0 {
                onProgress("正在检索录音共享组 (\(idx) / \(groupPaths.count))...")
            }
            let url = URL(fileURLWithPath: p)
            if let gid = getBIDFromXattr(url),
               gid.localizedCaseInsensitiveContains("VoiceMemos") {
                _ = wq.grantAccess(path: url.path, requireWrite: false)
                candidateRoots.append(url)
            }
        }

        // 3. Direct readability check (never call worse_query on non-container /var/mobile/Media)
        let mediaRec = URL(fileURLWithPath: "/private/var/mobile/Media/Recordings")
        if fm.isReadableFile(atPath: mediaRec.path) {
            candidateRoots.append(mediaRec)
        }

        var metadataByFileName: [String: RecordingDBMeta] = [:]
        var audioFiles: [URL] = []
        var seenCanonicalPaths = Set<String>()
        let audioExts: Set<String> = ["m4a", "qta", "wav", "caf"]

        for root in candidateRoots {
            let subdirs = [
                root,
                root.appendingPathComponent("Recordings"),
                root.appendingPathComponent("Documents"),
                root.appendingPathComponent("Documents/Recordings"),
                root.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings")
            ]

            for dir in subdirs {
                _ = wq.grantAccess(path: dir.path, requireWrite: false)
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names {
                    let fullURL = dir.appendingPathComponent(name)
                    let lower = name.lowercased()
                    if lower.hasSuffix(".db") && (lower.contains("recording") || lower.contains("voicememo")) {
                        let parsed = parseCloudRecordingsDB(at: fullURL.path)
                        for (k, v) in parsed where metadataByFileName[k] == nil {
                            metadataByFileName[k] = v
                        }
                    } else {
                        let ext = fullURL.pathExtension.lowercased()
                        if audioExts.contains(ext) {
                            let canonical = fullURL.standardizedFileURL.path
                            if seenCanonicalPaths.insert(canonical).inserted {
                                audioFiles.append(fullURL)
                            }
                        }
                    }
                }
            }
        }

        var items: [VoiceMemoRecordingItem] = []
        for url in audioFiles {
            var st = stat()
            guard stat(url.path, &st) == 0, st.st_size > 0 else { continue }
            let fileName = url.lastPathComponent
            let baseName = url.deletingPathExtension().lastPathComponent
            let meta = metadataByFileName[fileName] ?? metadataByFileName[baseName]
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            let title = (meta?.title.isEmpty == false) ? meta!.title : baseName

            items.append(VoiceMemoRecordingItem(
                id: url.path,
                fileURL: url,
                displayTitle: title,
                originalFileName: fileName,
                durationSeconds: meta?.duration,
                createdAt: mtime,
                fileSizeBytes: Int64(st.st_size)
            ))
        }

        items.sort { $0.createdAt > $1.createdAt }
        return items
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private static let isoFracFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func normalizeRecordingLabel(sortingLabel: String, customLabel: String) -> String {
        let candidates = [sortingLabel, customLabel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            if isoFormatter.date(from: candidate) == nil && isoFracFormatter.date(from: candidate) == nil {
                return candidate
            }
        }

        if let first = candidates.first,
           let parsedDate = isoFormatter.date(from: first) ?? isoFracFormatter.date(from: first) {
            return "录音 \(dateFormatter.string(from: parsedDate))"
        }

        return candidates.first ?? ""
    }

    private static func parseCloudRecordingsDB(at dbPath: String) -> [String: RecordingDBMeta] {
        guard let map = try? SQLiteSnapshotHelper.withClonedDatabase(at: dbPath, body: { db -> [String: RecordingDBMeta] in
            let tables = SQLiteSnapshotHelper.allTables(in: db)
            guard let targetTable = tables.first(where: { $0.uppercased().contains("CLOUDRECORDING") || $0.uppercased() == "ZRECORDING" }) else {
                return [:]
            }
            let cols = SQLiteSnapshotHelper.columnNames(in: targetTable, db: db)
            let pathCol = cols.contains("ZPATH") ? "ZPATH" : (cols.contains("ZFILENAME") ? "ZFILENAME" : nil)
            guard let validPathCol = pathCol else { return [:] }

            let sortLabelExpr = cols.contains("ZCUSTOMLABELFORSORTING") ? "ZCUSTOMLABELFORSORTING" : "''"
            let customLabelExpr = cols.contains("ZCUSTOMLABEL") ? "ZCUSTOMLABEL" : "''"
            let durCol = cols.contains("ZDURATION") ? "ZDURATION" : "NULL"

            let sql = "SELECT \(validPathCol), \(sortLabelExpr), \(customLabelExpr), \(durCol) FROM \"\(targetTable)\" WHERE \(validPathCol) IS NOT NULL;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  let validStmt = stmt else {
                return [:]
            }
            defer { sqlite3_finalize(validStmt) }

            var out: [String: RecordingDBMeta] = [:]
            while sqlite3_step(validStmt) == SQLITE_ROW {
                guard let rawPath = SQLiteSnapshotHelper.stringCol(validStmt, 0), !rawPath.isEmpty else { continue }
                let sortLabel = SQLiteSnapshotHelper.stringCol(validStmt, 1) ?? ""
                let customLabel = SQLiteSnapshotHelper.stringCol(validStmt, 2) ?? ""
                let label = normalizeRecordingLabel(sortingLabel: sortLabel, customLabel: customLabel)
                let dur = SQLiteSnapshotHelper.doubleCol(validStmt, 3)
                let lastComp = (rawPath as NSString).lastPathComponent
                let stem = (lastComp as NSString).deletingPathExtension
                let meta = RecordingDBMeta(title: label, duration: dur)
                out[lastComp] = meta
                out[stem] = meta
            }
            return out
        }) else {
            return [:]
        }
        return map
    }

    private static func probeAIModelCaches() -> [AIModelCacheProbeItem] {
        var results: [AIModelCacheProbeItem] = []

        // 1. App containers relevant to offline AI / translation / voice memos
        let appTargets: [(title: String, bid: String)] = [
            ("系统翻译离线语言包容器", "com.apple.Translate"),
            ("语音备忘录与转写缓存容器", "com.apple.VoiceMemos"),
            ("快捷指令与智能自动化容器", "com.apple.shortcuts")
        ]

        for target in appTargets {
            let path = fsHandlers.getContainerPath(at: FSURL.appContainers, forMatch: target.bid)
            if path.isEmpty {
                results.append(AIModelCacheProbeItem(
                    id: target.bid,
                    title: target.title,
                    identifier: target.bid,
                    accessible: false,
                    fileCount: 0,
                    totalBytes: 0,
                    statusNote: "未找到容器（应用可能未安装或首次未启动）"
                ))
            } else {
                let grant = wq.grantAccess(path: path, requireWrite: false)
                if grant.0 {
                    let (count, bytes) = countFilesAndSize(at: URL(fileURLWithPath: path), maxDepth: 4)
                    results.append(AIModelCacheProbeItem(
                        id: target.bid,
                        title: target.title,
                        identifier: target.bid,
                        accessible: true,
                        fileCount: count,
                        totalBytes: bytes,
                        statusNote: "只读探测正常 · 共 \(count) 个缓存/数据文件"
                    ))
                } else {
                    results.append(AIModelCacheProbeItem(
                        id: target.bid,
                        title: target.title,
                        identifier: target.bid,
                        accessible: false,
                        fileCount: 0,
                        totalBytes: 0,
                        statusNote: "当前系统限制沙盒读取"
                    ))
                }
            }
        }

        // 2. SystemGroup / MobileAsset read-only probes
        let sysTargets: [(title: String, id: String, path: String)] = [
            ("离线翻译引擎共享组", "systemgroup.com.apple.translationd", "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.translationd"),
            ("视觉图像智能分析组", "systemgroup.com.apple.mediaanalysisd", "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mediaanalysisd")
        ]

        for sys in sysTargets {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sys.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let grant = wq.grantAccess(path: sys.path, requireWrite: false)
            if grant.0 {
                let (count, bytes) = countFilesAndSize(at: URL(fileURLWithPath: sys.path), maxDepth: 4)
                results.append(AIModelCacheProbeItem(
                    id: sys.id,
                    title: sys.title,
                    identifier: sys.id,
                    accessible: true,
                    fileCount: count,
                    totalBytes: bytes,
                    statusNote: "只读探测成功 · \(count) 个模型/索引文件"
                ))
            } else {
                results.append(AIModelCacheProbeItem(
                    id: sys.id,
                    title: sys.title,
                    identifier: sys.id,
                    accessible: false,
                    fileCount: 0,
                    totalBytes: 0,
                    statusNote: "受系统沙盒扩展保护（仅守护进程可读）"
                ))
            }
        }

        return results
    }

    private static func countFilesAndSize(at url: URL, maxDepth: Int, currentDepth: Int = 0) -> (Int, Int64) {
        guard currentDepth <= maxDepth,
              let names = try? fm.contentsOfDirectory(atPath: url.path) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for name in names {
            let child = (url.path as NSString).appendingPathComponent(name)
            var st = stat()
            if lstat(child, &st) == 0 {
                let mode = st.st_mode & S_IFMT
                if mode == S_IFREG {
                    count += 1
                    bytes += Int64(st.st_size)
                } else if mode == S_IFDIR {
                    let sub = countFilesAndSize(at: URL(fileURLWithPath: child), maxDepth: maxDepth, currentDepth: currentDepth + 1)
                    count += sub.0
                    bytes += sub.1
                }
            }
        }
        return (count, bytes)
    }
}
