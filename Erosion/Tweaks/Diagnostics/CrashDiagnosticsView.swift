//
//  CrashDiagnosticsView.swift
//  Erosion
//
//  [Experimental / 测试特性] System Crash, Kernel Watchdog & Jetsam OOM Kill Analyzer
//  and safe diagnostic log cleaner backed by systemgroup.com.apple.osanalytics.
//

import SwiftUI

enum DiagnosticEventKind: String, CaseIterable {
    case all = "全部"
    case jetsam = "Jetsam 杀后台"
    case crash = "进程崩溃"
    case system = "系统/看门狗"
}

struct DiagnosticReportItem: Identifiable {
    let id: String
    let fileURL: URL
    let fileName: String
    let kind: DiagnosticEventKind
    let bugType: String
    let processName: String
    let subtitle: String
    let modifiedDate: Date
    let fileSize: Int64
}

struct CrashDiagnosticsView: View {
    @State private var isScanning = false
    @State private var canRead = false
    @State private var canWrite = false
    @State private var statusMessage = "正在扫描系统诊断报告容器..."
    @State private var reports: [DiagnosticReportItem] = []
    @State private var filterKind: DiagnosticEventKind = .all
    @State private var searchText = ""
    @State private var selectedReport: DiagnosticReportItem?

    private static let diagRoot = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/DiagnosticReports"
    private static let diagQueue = DispatchQueue(label: "com.erosion.diagnostics.osanalytics", qos: .userInitiated)

    private var filteredReports: [DiagnosticReportItem] {
        let base = (filterKind == .all) ? reports : reports.filter { $0.kind == filterKind }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter {
            $0.processName.localizedCaseInsensitiveContains(trimmed) ||
            $0.subtitle.localizedCaseInsensitiveContains(trimmed) ||
            $0.fileName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var totalSizeBytes: Int64 {
        reports.reduce(0) { $0 + $1.fileSize }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(Color.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("测试特性 · 崩溃与 Jetsam 内存强杀分析器")
                            .font(.subheadline.weight(.semibold))
                        Text("解析 systemgroup.com.apple.osanalytics 中的 .ips 诊断报告，直观定位近期被内核 Jetsam 内存保护机制查杀的应用、吃满运存的最大进程（如开启端侧 AI 后的内存压力）以及后台守护进程崩溃原因。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                Picker("类型筛选", selection: $filterKind) {
                    ForEach(DiagnosticEventKind.allCases, id: \.self) { k in
                        Text(k.rawValue).tag(k)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("共扫描到 \(reports.count) 份诊断日志")
                            .font(.subheadline.weight(.medium))
                        Text("总占用空间：\(AppContainerDirectoryHelper.formatBytes(totalSizeBytes)) · \(statusMessage)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isScanning {
                        ProgressView()
                    }
                }

                if canWrite && !reports.isEmpty {
                    Button(role: .destructive) {
                        Alertinator.shared.alert(
                            title: "清理历史诊断报告？",
                            body: "将安全删除 DiagnosticReports 下已归档的 \(reports.count) 份崩溃与 Jetsam 日志文件（约 \(AppContainerDirectoryHelper.formatBytes(totalSizeBytes))），完整保留系统目录结构。",
                            actionLabel: "确认清理",
                            action: { cleanAllReports() }
                        )
                    } label: {
                        Label("一键安全清理历史诊断日志", systemImage: "trash")
                    }
                }
            } header: {
                HeaderLabel("概览与空间清理 [测试]", symbol: "stethoscope")
            }

            Section {
                if filteredReports.isEmpty && !isScanning {
                    Text(canRead ? "暂无符合筛选条件的崩溃或 Jetsam 报告" : "当前系统版本未授权访问 osanalytics 容器")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredReports) { item in
                        Button {
                            selectedReport = item
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: iconName(for: item.kind))
                                    .foregroundStyle(iconColor(for: item.kind))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.processName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(item.kind.rawValue)
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(iconColor(for: item.kind).opacity(0.15), in: Capsule())
                                            .foregroundStyle(iconColor(for: item.kind))
                                    }
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text("\(formatTime(item.modifiedDate)) · bug_type \(item.bugType) · \(AppContainerDirectoryHelper.formatBytes(item.fileSize))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HeaderLabel("诊断事件列表 (\(filteredReports.count))", symbol: "list.bullet.rectangle")
            }
        }
        .searchable(text: $searchText, prompt: "搜索进程名、异常信号或文件名")
        .navigationTitle("崩溃与杀后台分析 [测试]")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scanReports()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isScanning)
            }
        }
        .sheet(item: $selectedReport) { item in
            DiagnosticDetailSheet(item: item)
        }
        .onAppear {
            if reports.isEmpty && !isScanning {
                scanReports()
            }
        }
    }

    private func iconName(for kind: DiagnosticEventKind) -> String {
        switch kind {
        case .jetsam: return "memorychip.fill"
        case .crash: return "exclamationmark.octagon.fill"
        case .system: return "bolt.trianglebadge.exclamationmark.fill"
        case .all: return "doc.text.fill"
        }
    }

    private func iconColor(for kind: DiagnosticEventKind) -> Color {
        switch kind {
        case .jetsam: return .orange
        case .crash: return .red
        case .system: return .purple
        case .all: return .accentColor
        }
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    private func scanReports() {
        isScanning = true
        Self.diagQueue.async {
            // Try read-write first (mobile:mobile 0755), fallback to read-only
            var granted = wq.grantAccess(path: Self.diagRoot, requireWrite: true)
            if !granted.0 {
                granted = wq.grantAccess(path: Self.diagRoot, requireWrite: false)
            }

            guard granted.0 && fm.isReadableFile(atPath: Self.diagRoot) else {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.canRead = false
                    self.canWrite = false
                    self.statusMessage = "访问受限（\(granted.2)）"
                }
                return
            }

            let writable = fm.isWritableFile(atPath: Self.diagRoot)
            var candidateURLs: [URL] = []
            let subDirs = [
                URL(fileURLWithPath: Self.diagRoot),
                URL(fileURLWithPath: Self.diagRoot).appendingPathComponent("Retired")
            ]
            for dirURL in subDirs {
                guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }
                for name in names {
                    let lower = name.lowercased()
                    guard lower.contains(".ips") || lower.hasSuffix(".crash") || lower.hasSuffix(".panic") else { continue }
                    let fullURL = dirURL.appendingPathComponent(name)
                    var st = stat()
                    if lstat(fullURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                        candidateURLs.append(fullURL)
                    }
                }
            }

            var parsedItems: [DiagnosticReportItem] = []
            for url in candidateURLs {
                if let item = Self.parseIPSFile(at: url) {
                    parsedItems.append(item)
                }
            }
            parsedItems.sort { $0.modifiedDate > $1.modifiedDate }

            DispatchQueue.main.async {
                self.isScanning = false
                self.canRead = true
                self.canWrite = writable
                self.reports = parsedItems
                self.statusMessage = writable ? "支持读取与清理" : "纯只读模式"
            }
        }
    }

    private func cleanAllReports() {
        isScanning = true
        let urlsToDelete = reports.map(\.fileURL)
        DispatchQueue.global(qos: .userInitiated).async {
            var deletedCount = 0
            var freedBytes: Int64 = 0
            for url in urlsToDelete {
                var st = stat()
                if lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                    let sz = Int64(st.st_size)
                    if (try? fm.removeItem(at: url)) != nil {
                        deletedCount += 1
                        freedBytes += sz
                    }
                }
            }
            DispatchQueue.main.async {
                self.isScanning = false
                Haptic.shared.play(.soft)
                Alertinator.shared.alert(
                    title: "清理完成！",
                    body: "已安全清除 \(deletedCount) 份历史崩溃与 Jetsam 报告，释放 \(AppContainerDirectoryHelper.formatBytes(freedBytes)) 存储空间。"
                )
                self.scanReports()
            }
        }
    }

    private static func parseIPSFile(at url: URL) -> DiagnosticReportItem? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let fileSize = Int64(st.st_size)
        let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let fileName = url.lastPathComponent

        // Read at most 256 KB for fast header + summary parsing
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let headData = (try? fh.read(upToCount: 262_144)) ?? Data()
        let text = String(decoding: headData, as: UTF8.self)

        var bugType = "未知"
        var appName = fileName
        var summary = fileName
        var kind: DiagnosticEventKind = .system

        if let newlineIdx = text.firstIndex(of: "\n") {
            let headerLine = String(text[..<newlineIdx])
            let bodyPart = String(text[text.index(after: newlineIdx)...])

            if let headerData = headerLine.data(using: .utf8),
               let headerJSON = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] {
                bugType = (headerJSON["bug_type"] as? String) ?? bugType
                if let nm = headerJSON["app_name"] as? String, !nm.isEmpty {
                    appName = nm
                } else if let nm = headerJSON["name"] as? String, !nm.isEmpty {
                    appName = nm
                }
            }

            if bugType == "298" || fileName.localizedCaseInsensitiveContains("JetsamEvent") {
                kind = .jetsam
                appName = "Jetsam 内存保护事件"
                if let bodyData = bodyPart.data(using: .utf8),
                   let bodyJSON = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    let largest = (bodyJSON["largestProcess"] as? String) ?? "未知进程"
                    var killedNames: [String] = []
                    if let procs = bodyJSON["processes"] as? [[String: Any]] {
                        for p in procs {
                            if let reason = p["reason"] as? String, !reason.isEmpty,
                               let pname = p["name"] as? String {
                                killedNames.append("\(pname) (\(reason))")
                            }
                        }
                    }
                    if killedNames.isEmpty {
                        summary = "最高内存占用进程：\(largest)"
                    } else {
                        summary = "最高占用：\(largest) · 被强杀：\(killedNames.prefix(3).joined(separator: ", "))"
                    }
                } else {
                    summary = "系统物理内存耗尽触发内核 Jetsam 后台清理"
                }
            } else if bugType == "309" || bugType == "109" {
                kind = .crash
                if let bodyData = bodyPart.data(using: .utf8),
                   let bodyJSON = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    if let proc = bodyJSON["procName"] as? String, !proc.isEmpty {
                        appName = proc
                    }
                    let exc = bodyJSON["exception"] as? [String: Any]
                    let excType = (exc?["type"] as? String) ?? "异常退出"
                    let excSig = (exc?["signal"] as? String) ?? ""
                    let term = bodyJSON["termination"] as? [String: Any]
                    let indicator = (term?["indicator"] as? String) ?? ""
                    let parts = [excType, excSig, indicator].filter { !$0.isEmpty }
                    summary = parts.isEmpty ? "应用或守护进程异常崩溃" : parts.joined(separator: " · ")
                } else {
                    summary = "进程崩溃报告 (\(fileName))"
                }
            } else if bugType == "210" || fileName.localizedCaseInsensitiveContains("panic") {
                kind = .system
                appName = "内核 Panic / 看门狗重启"
                summary = "检测到系统级重启记录 (\(fileName))"
            } else {
                kind = .system
                summary = "系统诊断事件 (\(fileName))"
            }
        }

        if let cn = CSStoreEngine.shared.localizedName(forBundleID: appName) {
            appName = "\(cn) (\(appName))"
        }

        return DiagnosticReportItem(
            id: url.path,
            fileURL: url,
            fileName: fileName,
            kind: kind,
            bugType: bugType,
            processName: appName,
            subtitle: summary,
            modifiedDate: modDate,
            fileSize: fileSize
        )
    }
}

private struct DiagnosticDetailSheet: View {
    let item: DiagnosticReportItem
    @Environment(\.dismiss) private var dismiss
    @State private var rawPreview: String = "正在读取报告内容..."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.processName)
                            .font(.headline)
                        Text(item.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("文件名：\(item.fileName) · bug_type：\(item.bugType)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    Text(rawPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("报告详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let tmp = makeTemp(item.fileURL) {
                            presentShareSheet(with: tmp)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                DispatchQueue.global(qos: .userInitiated).async {
                    var content = "无法读取原文件"
                    if let fh = try? FileHandle(forReadingFrom: item.fileURL) {
                        let d = (try? fh.read(upToCount: 128 * 1024)) ?? Data()
                        try? fh.close()
                        content = String(decoding: d, as: UTF8.self)
                        if Int64(d.count) < item.fileSize {
                            content += "\n\n... [预览已截断前 128 KB，点击右上角可导出完整原文件]"
                        }
                    }
                    DispatchQueue.main.async {
                        self.rawPreview = content
                    }
                }
            }
        }
    }
}
