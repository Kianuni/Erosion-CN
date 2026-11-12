//
//  AppGroupHubView.swift
//  Erosion
//
//  [Experimental / 测试特性] Cross-Container AppGroup Hub:
//  1. Proxy client AppGroup discovery + Apple Intelligence & CN Call Screening .sgmodule generator/injector.
//  2. Read-only APFS clonefile() Safari Bookmarks.db extractor (HTML & JSON export).
//

import SwiftUI
import SQLite3
import UIKit

struct DetectedAppGroupItem: Identifiable {
    let id: String
    let groupID: String
    let clientName: String
    let containerURL: URL
}

struct SafariBookmarkRecord: Identifiable, Codable {
    let id: Int
    let title: String
    let url: String
}

enum ProxyRuleFormat: String, CaseIterable, Identifiable {
    case surgeModule = "surge"
    case stashOverride = "stash"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .surgeModule: return L("Surge / Loon / 小火箭 (.sgmodule)")
        case .stashOverride: return L("Stash 覆写规则 (.stoverride / YAML)")
        }
    }
}

struct AppGroupHubView: View {
    @State private var isScanning = false
    @State private var scanSummary = L("点击右上角刷新扫描本机共享应用组 (AppGroup)")
    @State private var proxyGroups: [DetectedAppGroupItem] = []
    @State private var safariBookmarksDBPath: String?
    @State private var bookmarks: [SafariBookmarkRecord] = []
    @State private var proxyPolicyName: String = "PROXY"
    @State private var ruleFormat: ProxyRuleFormat = .surgeModule
    @State private var hasAutoSelectedFormat = false
    @State private var showRulePreview = false

    private static let knownProxyGroupMap: [String: String] = [
        "group.com.nssurge.inc.surge-ios": "Surge",
        "group.com.nssurge.inc.surge-ios-tf": "Surge (TestFlight)",
        "group.com.liguangming.Shadowrocket": "Shadowrocket (小火箭)",
        "group.com.luo.quantumult-x": "Quantumult X (圈 X)",
        "group.com.loon.loon": "Loon",
        "group.com.loon0x00.loon": "Loon",
        "group.ws.stash.app": "Stash"
    ]

    private var surgeGroup: DetectedAppGroupItem? {
        proxyGroups.first { $0.groupID.hasPrefix("group.com.nssurge.inc.surge-ios") }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(Color.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("测试特性 · 跨容器 AppGroup 共享组枢纽")
                            .font(.subheadline.weight(.semibold))
                        Text("突破单应用沙盒隔离：支持一键生成或向代理工具共享组写入“国行普通话来电询问 + 海外 Apple 智能”共存分流模块，并通过 APFS clonefile() 零锁快照无损导出 Safari 书签。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                HStack {
                    Text("扫描状态")
                    Spacer()
                    if isScanning {
                        ProgressView()
                    } else {
                        Text("已识别 \(proxyGroups.count) 个网络工具组")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(scanSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                HeaderLabel(L("共享组探测状态 [测试]"), symbol: "square.stack.3d.up")
            }

            Section {
                Picker("规则格式", selection: $ruleFormat) {
                    ForEach(ProxyRuleFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("海外 AI 节点策略组名称")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("例如 PROXY / AI / 🇺🇸 美国节点", text: $proxyPolicyName)
                        .font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                .padding(.vertical, 2)

                Button {
                    exportRuleFileViaShareSheet()
                } label: {
                    Label(
                        ruleFormat == .stashOverride
                            ? L("导出 .stoverride 覆写文件 (导入 Stash)")
                            : L("导出 .sgmodule 分流模块文件 (通用分享)"),
                        systemImage: "square.and.arrow.up"
                    )
                }

                Button {
                    UIPasteboard.general.string = currentRuleContent()
                    Haptic.shared.play(.soft)
                    Alertinator.shared.alert(
                        title: L("已拷贝分流规则！"),
                        body: ruleFormat == .stashOverride
                            ? L("Stash 覆写规则 (YAML) 已复制到剪贴板，可在 Stash「覆写」中新建或粘贴使用（请确保所选美区节点已开启 udp: true）。")
                            : L("Surge 模块规则已复制到系统剪贴板，可直接粘贴至 Surge / Loon / Shadowrocket 模块配置中。")
                    )
                } label: {
                    Label(
                        ruleFormat == .stashOverride ? L("拷贝 Stash YAML 覆写源码至剪贴板") : L("拷贝模块规则源码至剪贴板"),
                        systemImage: "doc.on.doc"
                    )
                }

                if let surge = surgeGroup, ruleFormat == .surgeModule {
                    Button {
                        Alertinator.shared.alert(
                            title: L("写入 Surge 共享组目录？ [测试特性]"),
                            body: L("请先在后台上滑关闭 Surge 主程序，再点击“确认写入”。写入完成后打开 Surge -> 模块 -> 启用「Erosion 国行 Apple 智能与来电询问分流」即可。"),
                            actionLabel: L("确认写入"),
                            action: { injectModuleIntoSurge(surge) }
                        )
                    } label: {
                        Label("一键注入至本机 \(surge.clientName) 模块目录 [测试]", systemImage: "bolt.horizontal.circle.fill")
                    }
                }

                DisclosureGroup(
                    ruleFormat == .stashOverride ? L("预览生成的 Stash .stoverride (YAML) 内容") : L("预览生成的 Surge .sgmodule 规则内容"),
                    isExpanded: $showRulePreview
                ) {
                    Text(currentRuleContent())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            } header: {
                HeaderLabel(L("[测试特性] Apple 智能与普通话来电询问共存分流"), symbol: "network.badge.shield.half.filled")
            } footer: {
                Text("核心原理：将 guzzoni.apple.com / siri.apple.com / smoot.apple.com 设为 DIRECT 并加入真实 IP 白名单（always-real-ip / fake-ip-filter），保障国行 Siri 与普通话来电筛选秒通；同时将 gspe1-ssl、apple-relay.*、OpenAI 与 Google 视觉智能置顶分流至美区策略组（注意：所选美区节点需支持 UDP/QUIC）。")
            }

            if !proxyGroups.isEmpty {
                Section {
                    ForEach(proxyGroups) { item in
                        NavigationLink {
                            ContainerSubdirBrowserView(containerURL: item.containerURL, relativeSubpath: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.clientName)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.groupID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HeaderLabel(L("本机已安装代理工具共享组 [测试]"), symbol: "folder.badge.gearshape")
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Safari 书签数据库快照")
                            .font(.subheadline.weight(.medium))
                        if safariBookmarksDBPath != nil {
                            Text("已无损解析 \(bookmarks.count) 条网址书签（APFS 只读快照）")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Text("暂未定位到可读的 Bookmarks.db 或书签为空")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if !bookmarks.isEmpty {
                    Button {
                        exportBookmarksHTML()
                    } label: {
                        Label("导出标准 HTML 书签文件 (兼容全平台浏览器)", systemImage: "globe")
                    }

                    Button {
                        exportBookmarksJSON()
                    } label: {
                        Label("导出 JSON 结构化书签备份", systemImage: "curlybraces")
                    }

                    ForEach(bookmarks.prefix(8)) { bm in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bm.title.isEmpty ? L("(无标题书签)") : bm.title)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                            Text(bm.url)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 1)
                    }
                    if bookmarks.count > 8 {
                        Text("… 其余 \(bookmarks.count - 8) 条书签将在导出文件中完整包含")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HeaderLabel(L("[测试特性] Safari 书签无损跨容器导出"), symbol: "book.fill")
            }
        }
        .navigationTitle("共享组分流与书签")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scanAppGroups()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
            }
        }
        .onAppear {
            if proxyGroups.isEmpty && safariBookmarksDBPath == nil && !isScanning {
                scanAppGroups()
            }
        }
    }

    private var sanitizedPolicy: String {
        let trimmed = proxyPolicyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "PROXY" : trimmed
    }

    private func currentRuleContent() -> String {
        switch ruleFormat {
        case .surgeModule:
            return buildSGModuleContent()
        case .stashOverride:
            return buildStashOverrideContent()
        }
    }

    private func buildSGModuleContent() -> String {
        let policy = sanitizedPolicy
        let modName = L("Erosion 国行 Apple 智能与来电询问分流 [测试特性]")
        let modDesc = L("由 Erosion 生成：保持国行 Siri 与普通话询问来电原因 (guzzoni) 真实 IP 直连，同时将 Apple Intelligence 隐私云计算、区域定位校验与视觉智能置顶分流至 \(policy)。")
        let c1 = L("# 1. 国行 Siri 语音主网关与普通话来电询问必须真实 IP 直连（严禁走代理）")
        let c2 = L("# 2. Apple Intelligence 区域定位校验、PCC 隐私计算中继与匿名令牌签发（请使用支持 UDP/QUIC 的低并发干净美区节点）")
        let c3 = L("# 3. Siri ChatGPT 扩展与视觉智能（提问 + Google 识图）")
        return """
        #!name=\(modName)
        #!desc=\(modDesc)
        #!category=Erosion

        [General]
        skip-proxy = %APPEND% guzzoni.apple.com
        always-real-ip = %APPEND% guzzoni.apple.com, *.guzzoni.apple.com, *.siri.apple.com

        [Rule]
        \(c1)
        DOMAIN-SUFFIX,guzzoni.apple.com,DIRECT
        DOMAIN-SUFFIX,siri.apple.com,DIRECT
        DOMAIN,dejavu.apple.com,DIRECT
        DOMAIN,sequoia.apple.com,DIRECT
        DOMAIN-SUFFIX,smoot.apple.com,DIRECT

        \(c2)
        DOMAIN,gspe1-ssl.ls.apple.com,\(policy)
        DOMAIN,mask-api.icloud.com,\(policy)
        DOMAIN,mask.icloud.com,\(policy)
        DOMAIN,mask-h2.icloud.com,\(policy)
        DOMAIN-SUFFIX,app.apple.com,\(policy)
        DOMAIN-SUFFIX,apple-relay.apple.com,\(policy)
        DOMAIN-SUFFIX,apple-relay.cloudflare.com,\(policy)
        DOMAIN-SUFFIX,apple-relay.fastly-edge.com,\(policy)
        DOMAIN-SUFFIX,apple-relay.akamaized.net,\(policy)
        DOMAIN-SUFFIX,cp4.cloudflare.com,\(policy)

        \(c3)
        DOMAIN-SUFFIX,openai.com,\(policy)
        DOMAIN-SUFFIX,chatgpt.com,\(policy)
        DOMAIN-SUFFIX,oaistatic.com,\(policy)
        DOMAIN-SUFFIX,oaiusercontent.com,\(policy)
        DOMAIN-SUFFIX,google.com,\(policy)
        DOMAIN-SUFFIX,googleapis.com,\(policy)
        DOMAIN-SUFFIX,gstatic.com,\(policy)
        """
    }

    private func buildStashOverrideContent() -> String {
        let policy = sanitizedPolicy
        let ovrName = L("Erosion 国行 Apple 智能与来电询问分流")
        let ovrDesc = L("保持国行 Siri 与普通话询问来电原因 (guzzoni) 真实 IP 直连，同时将 Apple Intelligence 隐私云计算、定位准入与视觉智能置顶分流至 \(policy)（请确保所选美区节点已开启 udp: true）。")
        let sc1 = L("# 1. 国行 Siri 语音主网关与普通话来电询问必须真实 IP 直连（严禁走代理）")
        let sc2 = L("# 2. Apple Intelligence 区域定位校验、PCC 隐私计算中继与匿名令牌签发（置顶防 GEOSITE,apple,DIRECT 抢行）")
        let sc3 = L("# 3. Siri ChatGPT 扩展与视觉智能（提问 + Google 识图）")
        return """
        name: "\(ovrName)"
        desc: "\(ovrDesc)"

        dns:
          fake-ip-filter:
            - "guzzoni.apple.com"
            - "+.guzzoni.apple.com"
            - "+.siri.apple.com"
            - "dejavu.apple.com"
            - "sequoia.apple.com"
            - "+.smoot.apple.com"
            - "+.push.apple.com"
            - "gspe1-ssl.ls.apple.com"
            - "mask-api.icloud.com"
            - "mask.icloud.com"
            - "mask-h2.icloud.com"
            - "+.app.apple.com"
            - "+.apple-relay.apple.com"
            - "+.apple-relay.cloudflare.com"
            - "+.apple-relay.fastly-edge.com"
            - "+.apple-relay.akamaized.net"

        rules:
          \(sc1)
          - DOMAIN-SUFFIX,guzzoni.apple.com,DIRECT
          - DOMAIN-SUFFIX,siri.apple.com,DIRECT
          - DOMAIN,dejavu.apple.com,DIRECT
          - DOMAIN,sequoia.apple.com,DIRECT
          - DOMAIN-SUFFIX,smoot.apple.com,DIRECT

          \(sc2)
          - DOMAIN,gspe1-ssl.ls.apple.com,\(policy)
          - DOMAIN,mask-api.icloud.com,\(policy)
          - DOMAIN,mask.icloud.com,\(policy)
          - DOMAIN,mask-h2.icloud.com,\(policy)
          - DOMAIN-SUFFIX,app.apple.com,\(policy)
          - DOMAIN-SUFFIX,apple-relay.apple.com,\(policy)
          - DOMAIN-SUFFIX,apple-relay.cloudflare.com,\(policy)
          - DOMAIN-SUFFIX,apple-relay.fastly-edge.com,\(policy)
          - DOMAIN-SUFFIX,apple-relay.akamaized.net,\(policy)
          - DOMAIN-SUFFIX,cp4.cloudflare.com,\(policy)

          \(sc3)
          - DOMAIN-SUFFIX,openai.com,\(policy)
          - DOMAIN-SUFFIX,chatgpt.com,\(policy)
          - DOMAIN-SUFFIX,oaistatic.com,\(policy)
          - DOMAIN-SUFFIX,oaiusercontent.com,\(policy)
          - DOMAIN-SUFFIX,google.com,\(policy)
          - DOMAIN-SUFFIX,googleapis.com,\(policy)
          - DOMAIN-SUFFIX,gstatic.com,\(policy)
        """
    }

    private func exportRuleFileViaShareSheet() {
        let fileName = (ruleFormat == .stashOverride)
            ? "Erosion-AppleIntelligence-CN.stoverride"
            : "Erosion-AppleIntelligence-CN.sgmodule"
        let outURL = fm.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try? fm.removeItem(at: outURL)
            try currentRuleContent().write(to: outURL, atomically: true, encoding: .utf8)
            Haptic.shared.play(.soft)
            presentShareSheet(with: outURL)
        } catch {
            Alertinator.shared.alert(title: L("导出分流文件失败！"), body: error.localizedDescription)
        }
    }

    private func injectModuleIntoSurge(_ surge: DetectedAppGroupItem) {
        let content = buildSGModuleContent()
        guard let data = content.data(using: .utf8), !data.isEmpty else { return }

        let rootGrant = wq.grantAccess(path: surge.containerURL.path, requireWrite: true)
        guard rootGrant.0 else {
            Alertinator.shared.alert(title: L("获取 Surge 共享组写入权限失败！"), body: rootGrant.2)
            return
        }

        // Probe standard Surge AppGroup module directories cleanly
        let candidateSubpaths = [
            "Documents/Profiles/Modules",
            "Profiles/Modules",
            "Modules",
            "Documents"
        ]
        var targetDir = surge.containerURL.appendingPathComponent("Documents")
        for sub in candidateSubpaths {
            let candidate = surge.containerURL.appendingPathComponent(sub)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                targetDir = candidate
                break
            }
        }

        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            _ = wq.grantAccess(path: targetDir.path, requireWrite: true)
            let targetFile = targetDir.appendingPathComponent("Erosion-AppleIntelligence-CN.sgmodule")
            if fm.fileExists(atPath: targetFile.path) {
                let res = writeFileAtomically(data, to: targetFile)
                if !res.0 {
                    throw res.1
                }
            } else {
                try data.write(to: targetFile, options: .atomic)
            }
            Haptic.shared.play(.soft)
            Alertinator.shared.alert(
                title: L("已注入 Surge 分流模块！"),
                body: L("模块文件已写入：\n\(targetFile.lastPathComponent)\n请打开 Surge 并在「模块」列表中勾选启用。")
            )
        } catch {
            Alertinator.shared.alert(title: L("写入 Surge 模块失败！"), body: error.localizedDescription)
        }
    }

    private func scanAppGroups() {
        isScanning = true
        scanSummary = L("正在定位 Safari 书签与共享应用组...")
        DispatchQueue.global(qos: .utility).async {
            // 1. Fast-path: check com.apple.mobilesafari data container first (<20ms via CSStore2)
            var foundSafariDB: String?
            let safariContainer = fsHandlers.getContainerPath(at: FSURL.appContainers, forMatch: "com.apple.mobilesafari")
            if !safariContainer.isEmpty {
                _ = wq.grantAccess(path: safariContainer, requireWrite: false)
                let dbCandidate = (safariContainer as NSString).appendingPathComponent("Library/Safari/Bookmarks.db")
                _ = wq.grantAccess(path: (dbCandidate as NSString).deletingLastPathComponent, requireWrite: false)
                if fm.isReadableFile(atPath: dbCandidate) {
                    foundSafariDB = dbCandidate
                }
            }

            if let earlyDB = foundSafariDB {
                let earlyBookmarks = Self.readSafariBookmarks(at: earlyDB)
                DispatchQueue.main.async {
                    self.safariBookmarksDBPath = earlyDB
                    self.bookmarks = earlyBookmarks
                    self.scanSummary = L("已加载 \(earlyBookmarks.count) 条 Safari 书签 · 正在枚举共享组...")
                }
            }

            // 2. Enumerate Shared/AppGroup containers with real-time progress
            let groupPaths = fsHandlers.getDirPaths(FSURL.appGroup.path)
            var foundProxies: [DetectedAppGroupItem] = []

            for (idx, path) in groupPaths.enumerated() {
                if idx % 25 == 0 {
                    DispatchQueue.main.async {
                        self.scanSummary = L("正在识别共享应用组 (\(idx) / \(groupPaths.count))...")
                    }
                }
                let url = URL(fileURLWithPath: path)
                guard let gid = getBIDFromXattr(url), !gid.isEmpty else { continue }

                if let client = Self.knownProxyGroupMap[gid]?.loc {
                    foundProxies.append(DetectedAppGroupItem(
                        id: url.lastPathComponent,
                        groupID: gid,
                        clientName: client,
                        containerURL: url
                    ))
                } else if foundSafariDB == nil && (gid.lowercased() == "group.com.apple.safari" || gid.lowercased() == "group.com.apple.mobilesafari") {
                    _ = wq.grantAccess(path: url.path, requireWrite: false)
                    let dbCandidate = url.appendingPathComponent("Library/Safari/Bookmarks.db")
                    _ = wq.grantAccess(path: dbCandidate.deletingLastPathComponent().path, requireWrite: false)
                    if fm.isReadableFile(atPath: dbCandidate.path) {
                        foundSafariDB = dbCandidate.path
                    }
                }
            }

            foundProxies.sort { $0.clientName < $1.clientName }

            var extractedBookmarks: [SafariBookmarkRecord] = []
            if let dbPath = foundSafariDB {
                extractedBookmarks = Self.readSafariBookmarks(at: dbPath)
            }

            DispatchQueue.main.async {
                self.proxyGroups = foundProxies
                if !self.hasAutoSelectedFormat {
                    self.hasAutoSelectedFormat = true
                    let hasSurge = foundProxies.contains { $0.groupID.hasPrefix("group.com.nssurge.inc.surge-ios") }
                    let hasStash = foundProxies.contains { $0.groupID == "group.ws.stash.app" }
                    if hasStash && !hasSurge {
                        self.ruleFormat = .stashOverride
                    }
                }
                self.safariBookmarksDBPath = foundSafariDB
                self.bookmarks = extractedBookmarks
                self.scanSummary = L("共扫描 \(groupPaths.count) 个共享组容器 · 识别 \(foundProxies.count) 个代理工具与 \(extractedBookmarks.count) 条 Safari 书签")
                self.isScanning = false
            }
        }
    }

    private static func readSafariBookmarks(at dbPath: String) -> [SafariBookmarkRecord] {
        do {
            return try SQLiteSnapshotHelper.withClonedDatabase(at: dbPath) { db in
                let cols = SQLiteSnapshotHelper.columnNames(in: "bookmarks", db: db)
                guard cols.contains("url") else { return [] }
                let titleCol = cols.contains("title") ? "title" : "''"
                let sql = "SELECT rowid, \(titleCol), url FROM bookmarks WHERE url IS NOT NULL AND url != '' ORDER BY rowid ASC LIMIT 5000;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                      let validStmt = stmt else {
                    return []
                }
                defer { sqlite3_finalize(validStmt) }

                var rows: [SafariBookmarkRecord] = []
                while sqlite3_step(validStmt) == SQLITE_ROW {
                    let rowID = SQLiteSnapshotHelper.intCol(validStmt, 0) ?? rows.count
                    let title = SQLiteSnapshotHelper.stringCol(validStmt, 1) ?? ""
                    let url = SQLiteSnapshotHelper.stringCol(validStmt, 2) ?? ""
                    if !url.isEmpty {
                        rows.append(SafariBookmarkRecord(id: rowID, title: title, url: url))
                    }
                }
                return rows
            }
        } catch {
            print("(appgroup) Safari Bookmarks snapshot read failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func exportBookmarksHTML() {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Safari Bookmarks (Erosion Export)</TITLE>",
            "<H1>Safari Bookmarks</H1>",
            "<DL><p>"
        ]
        for bm in bookmarks {
            let safeURL = Self.escapeHTML(bm.url)
            let safeTitle = Self.escapeHTML(bm.title.isEmpty ? bm.url : bm.title)
            lines.append("    <DT><A HREF=\"\(safeURL)\">\(safeTitle)</A>")
        }
        lines.append("</DL><p>")

        let outURL = fm.temporaryDirectory.appendingPathComponent("SafariBookmarks_Erosion.html")
        do {
            try? fm.removeItem(at: outURL)
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            Haptic.shared.play(.soft)
            presentShareSheet(with: outURL)
        } catch {
            Alertinator.shared.alert(title: L("导出 HTML 书签失败！"), body: error.localizedDescription)
        }
    }

    private func exportBookmarksJSON() {
        let outURL = fm.temporaryDirectory.appendingPathComponent("SafariBookmarks_Erosion.json")
        do {
            try? fm.removeItem(at: outURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(bookmarks)
            try data.write(to: outURL, options: .atomic)
            Haptic.shared.play(.soft)
            presentShareSheet(with: outURL)
        } catch {
            Alertinator.shared.alert(title: L("导出 JSON 书签失败！"), body: error.localizedDescription)
        }
    }
}
