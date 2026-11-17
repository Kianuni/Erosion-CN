//
//  WiFiShareServer.swift
//  Erosion
//
//  Lightweight NWListener HTTP file server with Basic Auth, 64 KB chunked streaming,
//  ZIPFoundation folder downloads (2 GB cap), and non-destructive uploads.
//

import Foundation
import Combine
import Network
import UIKit
import ZIPFoundation
import Darwin
import Security

struct WiFiShareEvent: Identifiable, Sendable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let isError: Bool
}

enum WiFiShareState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)
}

@MainActor
final class WiFiShareServer: ObservableObject {
    @Published private(set) var state: WiFiShareState = .stopped
    @Published private(set) var wifiIP: String?
    @Published private(set) var pin: String = ""
    @Published private(set) var activeConnectionsCount: Int = 0
    @Published private(set) var events: [WiFiShareEvent] = []
    @Published private(set) var rootURL: URL?

    let username = "erosion"

    private var engine: WiFiShareEngine?
    private var backgroundObserver: NSObjectProtocol?
    private var grantedPaths: Set<String> = []

    var shareURLString: String? {
        guard case .running(let port) = state, let wifiIP, !wifiIP.isEmpty else {
            return nil
        }
        return "http://\(wifiIP):\(port)"
    }

    func start(rootURL: URL) {
        stop()

        let ip = WiFiShareEngine.wifiIPv4Address()
        let newPIN = WiFiShareEngine.generatePIN()

        self.rootURL = rootURL
        self.wifiIP = ip
        self.pin = newPIN
        self.state = .starting
        self.events.removeAll()

        if !fm.isReadableFile(atPath: rootURL.path) && !wq.hasActiveAccess(path: rootURL.path) {
            let grant = wq.grantAccess(path: rootURL.path, requireWrite: false)
            if grant.0 {
                grantedPaths.insert(rootURL.path)
            } else {
                appendEvent(
                    LocalizationManager.isEnglish
                        ? "Read access grant failed: \(grant.2)"
                        : "获取目录读取权限失败：\(grant.2)",
                    isError: true
                )
            }
        }

        UIApplication.shared.isIdleTimerDisabled = true

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let server = self
            Task { @MainActor in
                server?.stop()
            }
        }

        let isEnglish = LocalizationManager.isEnglish
        let newEngine = WiFiShareEngine(
            rootURL: rootURL,
            pin: newPIN,
            isEnglish: isEnglish,
            callbacks: WiFiShareCallbacks(
                onStateChange: { [weak self] newState in
                    let server = self
                    Task { @MainActor in
                        guard let server, server.engine != nil else { return }
                        server.state = newState
                        if case .failed(let msg) = newState {
                            server.appendEvent(msg, isError: true)
                            UIApplication.shared.isIdleTimerDisabled = false
                        } else if case .running(let port) = newState {
                            let label = isEnglish
                                ? "Server listening on port \(port)"
                                : "HTTP 服务已启动，监听端口 \(port)"
                            server.appendEvent(label, isError: false)
                        }
                    }
                },
                onConnectionCountChange: { [weak self] count in
                    let server = self
                    Task { @MainActor in
                        server?.activeConnectionsCount = count
                    }
                },
                onEvent: { [weak self] msg, isErr in
                    let server = self
                    Task { @MainActor in
                        server?.appendEvent(msg, isError: isErr)
                    }
                },
                onUploadFinished: {
                    Task { @MainActor in
                        ErosionManager.shared.refreshFiles.toggle()
                    }
                },
                ensureWriteAccess: { [weak self] dirPath in
                    let server = self
                    return await MainActor.run {
                        guard let server else { return false }
                        if fm.isWritableFile(atPath: dirPath) {
                            return true
                        }
                        let hadAccess = wq.hasActiveAccess(path: dirPath)
                        let grant = wq.grantAccess(path: dirPath, requireWrite: true)
                        if grant.0 && !hadAccess {
                            server.grantedPaths.insert(dirPath)
                        }
                        return grant.0 || fm.isWritableFile(atPath: dirPath)
                    }
                }
            )
        )
        self.engine = newEngine
        newEngine.start()
    }

    func stop() {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }

        UIApplication.shared.isIdleTimerDisabled = false

        if let activeEngine = engine {
            engine = nil
            activeEngine.stop()
        }

        for path in grantedPaths {
            wq.releaseAccess(path: path)
        }
        grantedPaths.removeAll()

        activeConnectionsCount = 0
        if state != .stopped {
            state = .stopped
        }
    }

    func refreshIPAddress() {
        wifiIP = WiFiShareEngine.wifiIPv4Address()
    }

    private func appendEvent(_ message: String, isError: Bool) {
        events.insert(WiFiShareEvent(message: message, isError: isError), at: 0)
        if events.count > 40 {
            events = Array(events.prefix(40))
        }
    }
}

// MARK: - Nonisolated Networking & Streaming Engine

private struct WiFiShareCallbacks: Sendable {
    let onStateChange: @Sendable (WiFiShareState) -> Void
    let onConnectionCountChange: @Sendable (Int) -> Void
    let onEvent: @Sendable (String, Bool) -> Void
    let onUploadFinished: @Sendable () -> Void
    let ensureWriteAccess: @Sendable (String) async -> Bool
}

private nonisolated final class WiFiShareEngine: @unchecked Sendable {
    static let preferredPort: UInt16 = 8080
    static let chunkSize = 65_536
    static let maxHeaderBytes = 65_536
    static let maxZipBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB

    let rootURL: URL
    let rootStdPath: String
    let rootResolvedPath: String
    let pin: String
    let expectedBasicToken: String
    let isEnglish: Bool
    let callbacks: WiFiShareCallbacks
    let queue = DispatchQueue(label: "com.jbdotparty.Erosion.wifishare", qos: .userInitiated)

    private let stateLock = NSLock()
    private let uploadLock = NSLock()
    private var listener: NWListener?
    private var usedFallbackPort = false
    private var stopped = false
    private var sessions: [ObjectIdentifier: ConnectionSession] = [:]
    private var activePartFiles: Set<URL> = []
    private var activeTempZipFiles: Set<URL> = []

    init(rootURL: URL, pin: String, isEnglish: Bool, callbacks: WiFiShareCallbacks) {
        self.rootURL = rootURL.standardizedFileURL
        self.rootStdPath = Self.canonicalVarPath(rootURL.standardizedFileURL.path)
        self.rootResolvedPath = Self.canonicalVarPath(rootURL.resolvingSymlinksInPath().path)
        self.pin = pin
        self.expectedBasicToken = Data("erosion:\(pin)".utf8).base64EncodedString()
        self.isEnglish = isEnglish
        self.callbacks = callbacks
    }

    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.startListener(port: NWEndpoint.Port(rawValue: Self.preferredPort))
        }
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let currentListener = listener
        listener = nil
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        let partsToDelete = activePartFiles
        activePartFiles.removeAll()
        let zipsToDelete = activeTempZipFiles
        activeTempZipFiles.removeAll()
        stateLock.unlock()

        currentListener?.cancel()
        for session in activeSessions {
            session.forceCancel()
        }
        for partURL in partsToDelete {
            try? FileManager.default.removeItem(at: partURL)
        }
        for zipURL in zipsToDelete {
            try? FileManager.default.removeItem(at: zipURL)
        }
    }

    private func startListener(port: NWEndpoint.Port?) {
        guard !isStopped else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            let newListener: NWListener
            if let port {
                newListener = try NWListener(using: params, on: port)
            } else {
                newListener = try NWListener(using: params)
            }

            stateLock.lock()
            listener = newListener
            stateLock.unlock()

            newListener.stateUpdateHandler = { [weak self, weak newListener] newState in
                guard let self, let newListener else { return }
                guard !self.isStopped else {
                    newListener.cancel()
                    return
                }
                switch newState {
                case .ready:
                    let boundPort = newListener.port?.rawValue ?? Self.preferredPort
                    self.callbacks.onStateChange(.running(port: boundPort))
                case .failed(let error):
                    newListener.cancel()
                    if port != nil && !self.usedFallbackPort {
                        self.usedFallbackPort = true
                        self.startListener(port: nil)
                    } else {
                        self.callbacks.onStateChange(.failed(error.localizedDescription))
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.isStopped else {
                    connection.cancel()
                    return
                }
                let session = ConnectionSession(connection: connection, engine: self)
                self.registerSession(session)
                session.start()
            }

            newListener.start(queue: queue)
        } catch {
            if port != nil && !usedFallbackPort {
                usedFallbackPort = true
                startListener(port: nil)
            } else {
                callbacks.onStateChange(.failed(error.localizedDescription))
            }
        }
    }

    private func registerSession(_ session: ConnectionSession) {
        stateLock.lock()
        sessions[ObjectIdentifier(session)] = session
        let count = sessions.count
        stateLock.unlock()
        callbacks.onConnectionCountChange(count)
    }

    func unregisterSession(_ session: ConnectionSession) {
        stateLock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        let count = sessions.count
        stateLock.unlock()
        callbacks.onConnectionCountChange(count)
    }

    func registerPartFile(_ url: URL) {
        stateLock.lock()
        activePartFiles.insert(url)
        stateLock.unlock()
    }

    func unregisterPartFile(_ url: URL) {
        stateLock.lock()
        activePartFiles.remove(url)
        stateLock.unlock()
    }

    func registerTempZip(_ url: URL) {
        stateLock.lock()
        activeTempZipFiles.insert(url)
        stateLock.unlock()
    }

    func unregisterTempZip(_ url: URL) {
        stateLock.lock()
        activeTempZipFiles.remove(url)
        stateLock.unlock()
    }

    func finalizePartFile(_ partURL: URL, in directory: URL, desiredName: String) throws -> URL {
        uploadLock.lock()
        defer { uploadLock.unlock() }

        let finalURL = Self.nonCollidingDestinationURL(in: directory, desiredName: desiredName)
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        unregisterPartFile(partURL)
        return finalURL
    }

    // MARK: - Auth & Path Helpers

    func isAuthorized(headerValue: String?) -> Bool {
        guard let headerValue, !pin.isEmpty else { return false }
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("basic ") else { return false }
        let provided = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        if Self.constantTimeEqual(provided, expectedBasicToken) {
            return true
        }
        guard let decodedData = Data(base64Encoded: provided),
              let decoded = String(data: decodedData, encoding: .utf8),
              let colonIdx = decoded.firstIndex(of: ":") else {
            return false
        }
        let rawUser = String(decoded[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let rawPass = String(decoded[decoded.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let userOK = rawUser.isEmpty || rawUser.lowercased() == "erosion"
        return userOK && Self.constantTimeEqual(rawPass, pin)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= (aBytes[i] ^ bBytes[i])
        }
        return diff == 0
    }

    func resolveSafeURL(relativePath: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSegments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        var candidate = rootURL
        for seg in rawSegments {
            let s = String(seg)
            if s == "." || s == ".." || s.contains("\0") || s.contains("\\") {
                return nil
            }
            candidate.appendPathComponent(s)
        }

        let candStd = Self.canonicalVarPath(candidate.standardizedFileURL.path)
        let candRes = Self.canonicalVarPath(candidate.resolvingSymlinksInPath().path)

        let stdAllowed = (candStd == rootStdPath || candStd.hasPrefix(rootStdPath + "/"))
        let resAllowed = (candRes == rootResolvedPath || candRes.hasPrefix(rootResolvedPath + "/"))
        guard stdAllowed && resAllowed else {
            return nil
        }
        return candidate.standardizedFileURL
    }

    static func sanitizeUploadFileName(_ rawName: String) -> String? {
        let cleaned = rawName
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\\", with: "/")
        let leaf = (cleaned as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            return nil
        }
        return leaf
    }

    static func nonCollidingDestinationURL(in directory: URL, desiredName: String) -> URL {
        let initial = directory.appendingPathComponent(desiredName)
        if !pathExistsEvenIfSymlink(initial.path) {
            return initial
        }
        let ext = (desiredName as NSString).pathExtension
        let stem = ext.isEmpty ? desiredName : (desiredName as NSString).deletingPathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !pathExistsEvenIfSymlink(candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private static func pathExistsEvenIfSymlink(_ path: String) -> Bool {
        var st = stat()
        if lstat(path, &st) == 0 {
            return true
        }
        return FileManager.default.fileExists(atPath: path)
    }

    static func canonicalVarPath(_ rawPath: String) -> String {
        var p = (rawPath as NSString).standardizingPath
        if p.hasPrefix("/private/var/") {
            p = String(p.dropFirst("/private".count))
        } else if p == "/private/var" {
            p = "/var"
        }
        return p
    }

    // MARK: - Network & Random Helpers

    static func wifiIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var en0IP: String?
        var fallbackIP: String?

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = ptr?.pointee {
            defer { ptr = interface.ifa_next }
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback,
                  let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: interface.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            let ip = String(cString: hostBuffer)
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }
            if name == "en0" {
                en0IP = ip
                break
            } else if fallbackIP == nil && (name.hasPrefix("en") || name.hasPrefix("bridge")) {
                fallbackIP = ip
            }
        }
        return en0IP ?? fallbackIP
    }

    static func generatePIN() -> String {
        var bytes: UInt32 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &bytes)
        let val: UInt32
        if status == errSecSuccess {
            val = 100_000 + (bytes % 900_000)
        } else {
            val = UInt32.random(in: 100_000...999_999)
        }
        return String(val)
    }

    static func directoryByteSize(at path: String, limit: Int64, stopCheck: () -> Bool) -> Int64? {
        var total: Int64 = 0
        var stack = [path]
        while let current = stack.popLast() {
            if stopCheck() { return nil }
            guard let dir = opendir(current) else { continue }
            defer { closedir(dir) }
            let dfd = dirfd(dir)
            while let entryPtr = readdir(dir) {
                if stopCheck() { return nil }
                let name: String = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if name == "." || name == ".." { continue }
                var st = stat()
                guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFDIR {
                    let sub = current == "/" ? "/\(name)" : "\(current)/\(name)"
                    stack.append(sub)
                } else if kind == S_IFREG {
                    total += max(Int64(st.st_size), 0)
                    if total > limit {
                        return total
                    }
                }
            }
        }
        return total
    }

    // MARK: - Embedded Dark-Mode Web UI

    func webUIHTML() -> String {
        let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        let escapedRoot = Self.escapeHTML(rootName)
        let titleText = isEnglish ? "Erosion Wi-Fi Share" : "Erosion Wi-Fi 文件传输"
        let dropText = isEnglish ? "Drag & drop files here or tap Select Files" : "拖拽文件到此处，或点击下方按钮选择多个文件上传"
        let pickBtnText = isEnglish ? "Select Files to Upload" : "选择文件上传"
        let refreshBtnText = isEnglish ? "Refresh" : "刷新"
        let noteText = isEnglish
            ? "Non-destructive mode: uploads stream directly to disk and never overwrite or delete existing files (collisions auto-rename to name 2.ext). Folder ZIP downloads cap at 2 GB."
            : "无损安全机制：上传流式写入磁盘，绝不覆盖或删除现有文件（同名自动重命名为 name 2.ext）；文件夹打包下载上限为 2 GB。"

        return """
        <!DOCTYPE html>
        <html lang="\(isEnglish ? "en" : "zh-Hans")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(titleText) — \(escapedRoot)</title>
        <style>
        :root {
          color-scheme: dark;
          --bg: #0b0f17;
          --card: #131a26;
          --card-2: #1a2333;
          --border: #263248;
          --text: #e6edf7;
          --muted: #8ea0b8;
          --accent: #3b82f6;
          --accent-hover: #2563eb;
          --ok: #22c55e;
          --warn: #f59e0b;
          --err: #ef4444;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
          background: var(--bg);
          color: var(--text);
          line-height: 1.45;
        }
        .wrap { max-width: 960px; margin: 0 auto; padding: 18px 14px 48px; }
        header {
          display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between;
          background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 14px 16px;
        }
        .title { font-size: 18px; font-weight: 700; }
        .sub { font-size: 12px; color: var(--muted); word-break: break-all; }
        .btn {
          display: inline-flex; align-items: center; gap: 6px; padding: 8px 13px; border-radius: 9px;
          border: 1px solid var(--border); background: var(--card-2); color: var(--text);
          font-size: 13px; font-weight: 600; cursor: pointer; text-decoration: none;
        }
        .btn:hover { border-color: var(--accent); }
        .btn-primary { background: var(--accent); border-color: var(--accent); color: #fff; }
        .btn-primary:hover { background: var(--accent-hover); }
        .crumbs {
          display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin: 14px 0;
          padding: 10px 14px; background: var(--card); border: 1px solid var(--border); border-radius: 12px;
          font-size: 13px;
        }
        .crumb { color: var(--accent); cursor: pointer; background: none; border: none; padding: 0; font-size: 13px; }
        .crumb:hover { text-decoration: underline; }
        .dropzone {
          border: 2px dashed var(--border); border-radius: 14px; padding: 20px 16px; text-align: center;
          background: var(--card); margin-bottom: 14px; transition: border-color .15s, background .15s;
        }
        .dropzone.drag { border-color: var(--accent); background: rgba(59,130,246,.08); }
        .dropzone p { margin: 0 0 12px; color: var(--muted); font-size: 14px; }
        .uploads { display: flex; flex-direction: column; gap: 8px; margin-bottom: 14px; }
        .u-item {
          background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px;
          font-size: 13px;
        }
        .u-top { display: flex; justify-content: space-between; gap: 8px; margin-bottom: 6px; }
        .bar { height: 6px; border-radius: 99px; background: var(--card-2); overflow: hidden; }
        .bar > div { height: 100%; background: var(--accent); width: 0%; transition: width .1s linear; }
        .bar.done > div { background: var(--ok); }
        .bar.err > div { background: var(--err); }
        .list {
          background: var(--card); border: 1px solid var(--border); border-radius: 14px; overflow: hidden;
        }
        .row {
          display: flex; align-items: center; justify-content: space-between; gap: 10px;
          padding: 12px 14px; border-bottom: 1px solid var(--border);
        }
        .row:last-child { border-bottom: none; }
        .row:hover { background: rgba(255,255,255,.02); }
        .left { display: flex; align-items: center; gap: 10px; min-width: 0; flex: 1; }
        .icon { width: 26px; text-align: center; font-size: 17px; flex-shrink: 0; }
        .name { font-size: 14px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .name.link { color: var(--accent); cursor: pointer; }
        .meta { font-size: 12px; color: var(--muted); }
        .actions { display: flex; gap: 6px; flex-shrink: 0; }
        .empty { padding: 28px; text-align: center; color: var(--muted); font-size: 14px; }
        .note { margin-top: 14px; font-size: 12px; color: var(--muted); padding: 0 4px; }
        </style>
        </head>
        <body>
        <div class="wrap">
          <header>
            <div>
              <div class="title">\(titleText)</div>
              <div class="sub" id="rootLabel">\(escapedRoot)</div>
            </div>
            <button class="btn" onclick="loadDir(currentPath)">\(refreshBtnText)</button>
          </header>

          <div class="crumbs" id="crumbs"></div>

          <div class="dropzone" id="dropzone">
            <p>\(dropText)</p>
            <input type="file" id="fileInput" multiple style="display:none">
            <button class="btn btn-primary" onclick="document.getElementById('fileInput').click()">\(pickBtnText)</button>
          </div>

          <div class="uploads" id="uploads"></div>
          <div class="list" id="fileList"></div>
          <div class="note">\(noteText)</div>
        </div>

        <script>
        const IS_EN = \(isEnglish ? "true" : "false");
        let currentPath = "/";

        function fmtBytes(n) {
          if (n < 1024) return n + " B";
          const u = ["KB","MB","GB","TB"];
          let i = -1;
          do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
          return n.toFixed(n >= 100 ? 0 : 1) + " " + u[i];
        }

        function renderCrumbs() {
          const el = document.getElementById("crumbs");
          el.innerHTML = "";
          const rootBtn = document.createElement("button");
          rootBtn.className = "crumb";
          rootBtn.textContent = "\(escapedRoot)";
          rootBtn.onclick = () => loadDir("/");
          el.appendChild(rootBtn);

          const parts = currentPath.split("/").filter(Boolean);
          let acc = "";
          for (const part of parts) {
            const sep = document.createElement("span");
            sep.textContent = " / ";
            sep.style.color = "var(--muted)";
            el.appendChild(sep);

            acc += "/" + part;
            const target = acc;
            const btn = document.createElement("button");
            btn.className = "crumb";
            btn.textContent = part;
            btn.onclick = () => loadDir(target);
            el.appendChild(btn);
          }
        }

        async function loadDir(path) {
          currentPath = path || "/";
          renderCrumbs();
          const list = document.getElementById("fileList");
          list.innerHTML = '<div class="empty">' + (IS_EN ? "Loading..." : "正在加载...") + '</div>';
          try {
            const res = await fetch("/api/list?path=" + encodeURIComponent(currentPath), { credentials: "same-origin" });
            if (!res.ok) throw new Error("HTTP " + res.status);
            const data = await res.json();
            list.innerHTML = "";
            if (!data.items || data.items.length === 0) {
              list.innerHTML = '<div class="empty">' + (IS_EN ? "Empty folder" : "空目录") + '</div>';
              return;
            }
            for (const item of data.items) {
              const row = document.createElement("div");
              row.className = "row";

              const left = document.createElement("div");
              left.className = "left";

              const icon = document.createElement("div");
              icon.className = "icon";
              icon.textContent = item.isDir ? "📁" : (item.isSymlink ? "🔗" : "📄");
              left.appendChild(icon);

              const info = document.createElement("div");
              info.style.minWidth = "0";
              const nameEl = document.createElement("div");
              nameEl.className = "name" + (item.isDir ? " link" : "");
              nameEl.textContent = item.name;
              if (item.isDir) {
                nameEl.onclick = () => loadDir(item.relPath);
              }
              info.appendChild(nameEl);

              const meta = document.createElement("div");
              meta.className = "meta";
              meta.textContent = (item.isDir ? (IS_EN ? "Folder" : "文件夹") : fmtBytes(item.size)) + (item.modified ? " · " + item.modified : "");
              info.appendChild(meta);
              left.appendChild(info);
              row.appendChild(left);

              const actions = document.createElement("div");
              actions.className = "actions";
              if (item.isDir) {
                const zipA = document.createElement("a");
                zipA.className = "btn";
                zipA.href = "/api/zip?path=" + encodeURIComponent(item.relPath);
                zipA.textContent = IS_EN ? "Download .zip" : "打包下载 .zip";
                actions.appendChild(zipA);
              } else if (!item.isSymlink) {
                const dlA = document.createElement("a");
                dlA.className = "btn";
                dlA.href = "/api/download?path=" + encodeURIComponent(item.relPath);
                dlA.setAttribute("download", item.name);
                dlA.textContent = IS_EN ? "Download" : "下载";
                actions.appendChild(dlA);
              }
              row.appendChild(actions);
              list.appendChild(row);
            }
          } catch (err) {
            list.innerHTML = '<div class="empty">' + (IS_EN ? "Failed to load: " : "加载失败：") + err.message + '</div>';
          }
        }

        function uploadFiles(files) {
          const arr = Array.from(files || []);
          for (const file of arr) {
            uploadSingle(file, currentPath);
          }
        }

        function uploadSingle(file, targetDir) {
          const box = document.getElementById("uploads");
          const item = document.createElement("div");
          item.className = "u-item";
          const top = document.createElement("div");
          top.className = "u-top";
          const fname = document.createElement("span");
          fname.textContent = file.name + " (" + fmtBytes(file.size) + ")";
          const status = document.createElement("span");
          status.textContent = "0%";
          top.appendChild(fname);
          top.appendChild(status);

          const bar = document.createElement("div");
          bar.className = "bar";
          const fill = document.createElement("div");
          bar.appendChild(fill);

          item.appendChild(top);
          item.appendChild(bar);
          box.prepend(item);

          const xhr = new XMLHttpRequest();
          const url = "/api/upload?path=" + encodeURIComponent(targetDir) + "&name=" + encodeURIComponent(file.name);
          xhr.open("PUT", url, true);
          xhr.withCredentials = true;

          xhr.upload.onprogress = (e) => {
            if (e.lengthComputable && e.total > 0) {
              const pct = Math.round((e.loaded / e.total) * 100);
              fill.style.width = pct + "%";
              status.textContent = pct + "%";
            }
          };

          xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
              fill.style.width = "100%";
              bar.classList.add("done");
              try {
                const resp = JSON.parse(xhr.responseText);
                status.textContent = (IS_EN ? "Saved: " : "已保存: ") + (resp.savedName || file.name);
              } catch {
                status.textContent = IS_EN ? "Done" : "完成";
              }
              if (targetDir === currentPath) loadDir(currentPath);
            } else {
              bar.classList.add("err");
              status.textContent = "HTTP " + xhr.status;
            }
          };

          xhr.onerror = () => {
            bar.classList.add("err");
            status.textContent = IS_EN ? "Network error" : "网络错误";
          };

          xhr.send(file);
        }

        const dz = document.getElementById("dropzone");
        dz.addEventListener("dragover", (e) => { e.preventDefault(); dz.classList.add("drag"); });
        dz.addEventListener("dragleave", () => dz.classList.remove("drag"));
        dz.addEventListener("drop", (e) => {
          e.preventDefault();
          dz.classList.remove("drag");
          uploadFiles(e.dataTransfer.files);
        });

        document.getElementById("fileInput").addEventListener("change", (e) => {
          uploadFiles(e.target.files);
          e.target.value = "";
        });

        loadDir("/");
        </script>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Per-Connection HTTP/1.1 State Machine

private nonisolated final class ConnectionSession: @unchecked Sendable {
    private let connection: NWConnection
    private let engine: WiFiShareEngine

    private var headerBuffer = Data()
    private var closed = false

    // Upload streaming state
    private var uploadHandle: FileHandle?
    private var uploadPartURL: URL?
    private var uploadTargetDir: URL?
    private var uploadDesiredName: String = ""
    private var uploadBytesWritten: Int64 = 0
    private var uploadRemainingFixed: Int64 = 0
    private var isChunkedUpload = false
    private var chunkedDecoder = ChunkedBodyDecoder()

    init(connection: NWConnection, engine: WiFiShareEngine) {
        self.connection = connection
        self.engine = engine
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveHeaderChunk()
            case .failed, .cancelled:
                self.cleanupAndClose()
            default:
                break
            }
        }
        connection.start(queue: engine.queue)
    }

    func forceCancel() {
        guard !closed else { return }
        closed = true
        abortActiveUpload()
        connection.cancel()
    }

    private func cleanupAndClose() {
        guard !closed else { return }
        closed = true
        abortActiveUpload()
        connection.cancel()
        engine.unregisterSession(self)
    }

    private func receiveHeaderChunk() {
        guard !closed, !engine.isStopped else {
            cleanupAndClose()
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: WiFiShareEngine.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, !self.engine.isStopped else { return }

            if let error {
                _ = error
                self.cleanupAndClose()
                return
            }

            if let data, !data.isEmpty {
                self.headerBuffer.append(data)
            }

            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            if let range = self.headerBuffer.range(of: separator) {
                let headerData = self.headerBuffer.subdata(in: 0..<range.lowerBound)
                let bodyRemainder = Data(self.headerBuffer.subdata(in: range.upperBound..<self.headerBuffer.count))
                self.headerBuffer.removeAll(keepingCapacity: false)
                self.handleParsedHeader(headerData: headerData, initialBody: bodyRemainder)
                return
            }

            if self.headerBuffer.count > WiFiShareEngine.maxHeaderBytes {
                self.sendTextError(status: 431, reason: "Request Header Fields Too Large", body: "Headers too large")
                return
            }

            if isComplete {
                self.cleanupAndClose()
                return
            }

            self.receiveHeaderChunk()
        }
    }

    private func handleParsedHeader(headerData: Data, initialBody: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1) else {
            sendTextError(status: 400, reason: "Bad Request", body: "Invalid header encoding")
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendTextError(status: 400, reason: "Bad Request", body: "Empty request")
            return
        }

        let reqParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard reqParts.count >= 2 else {
            sendTextError(status: 400, reason: "Bad Request", body: "Malformed request line")
            return
        }

        let method = String(reqParts[0]).uppercased()
        let rawTarget = String(reqParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        // Enforce HTTP Basic Auth on every route
        guard engine.isAuthorized(headerValue: headers["authorization"]) else {
            sendUnauthorized()
            return
        }

        guard let components = URLComponents(string: "http://localhost" + (rawTarget.hasPrefix("/") ? rawTarget : "/" + rawTarget)) else {
            sendTextError(status: 400, reason: "Bad Request", body: "Invalid URL target")
            return
        }

        let routePath = components.path
        let queryMap: [String: String] = (components.queryItems ?? []).reduce(into: [:]) { acc, item in
            acc[item.name] = item.value ?? ""
        }

        switch (method, routePath) {
        case ("GET", "/"):
            sendHTML(engine.webUIHTML())
        case ("GET", "/api/list"):
            handleList(relPath: queryMap["path"] ?? "/")
        case ("GET", "/api/download"):
            handleDownload(relPath: queryMap["path"] ?? "")
        case ("GET", "/api/zip"):
            handleZipDownload(relPath: queryMap["path"] ?? "")
        case ("PUT", "/api/upload"), ("POST", "/api/upload"):
            handleUploadStart(
                relPath: queryMap["path"] ?? "/",
                rawName: queryMap["name"] ?? "",
                headers: headers,
                initialBody: initialBody
            )
        default:
            sendTextError(status: 404, reason: "Not Found", body: "Not found")
        }
    }

    // MARK: - GET /api/list

    private func handleList(relPath: String) {
        guard let dirURL = engine.resolveSafeURL(relativePath: relPath) else {
            sendJSON(status: 403, reason: "Forbidden", payload: ["error": "Invalid path"])
            return
        }

        var st = stat()
        guard lstat(dirURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            sendJSON(status: 404, reason: "Not Found", payload: ["error": "Directory not found"])
            return
        }

        let cleanRel = relPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            )

            var items: [[String: Any]] = []
            items.reserveCapacity(children.count)

            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".erosion_upload_") && name.hasSuffix(".part") {
                    continue
                }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                let isSymlink = values?.isSymbolicLink ?? false
                let isDir = !isSymlink && (values?.isDirectory ?? false)
                let size = isDir ? 0 : (values?.fileSize ?? 0)
                let modStr = values?.contentModificationDate.map { formatter.string(from: $0) } ?? ""
                let childRel = cleanRel.isEmpty ? "/\(name)" : "/\(cleanRel)/\(name)"

                items.append([
                    "name": name,
                    "relPath": childRel,
                    "isDir": isDir,
                    "isSymlink": isSymlink,
                    "size": size,
                    "modified": modStr
                ])
            }

            items.sort { lhs, rhs in
                let lDir = (lhs["isDir"] as? Bool) ?? false
                let rDir = (rhs["isDir"] as? Bool) ?? false
                if lDir != rDir { return lDir && !rDir }
                let lName = (lhs["name"] as? String) ?? ""
                let rName = (rhs["name"] as? String) ?? ""
                return lName.localizedStandardCompare(rName) == .orderedAscending
            }

            sendJSON(status: 200, reason: "OK", payload: ["path": relPath, "items": items])
        } catch {
            sendJSON(status: 500, reason: "Internal Server Error", payload: ["error": error.localizedDescription])
        }
    }

    // MARK: - GET /api/download (Chunked Streaming)

    private func handleDownload(relPath: String) {
        guard let fileURL = engine.resolveSafeURL(relativePath: relPath) else {
            sendTextError(status: 403, reason: "Forbidden", body: "Invalid path")
            return
        }

        var st = stat()
        guard lstat(fileURL.path, &st) == 0 else {
            sendTextError(status: 404, reason: "Not Found", body: "File not found")
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            sendTextError(status: 400, reason: "Bad Request", body: "Not a regular file")
            return
        }

        streamFileResponse(
            fileURL: fileURL,
            downloadName: fileURL.lastPathComponent,
            contentType: "application/octet-stream",
            fileSize: Int64(st.st_size),
            onCleanup: nil
        )
    }

    // MARK: - GET /api/zip (2 GB Cap + Chunked Streaming)

    private func handleZipDownload(relPath: String) {
        guard let dirURL = engine.resolveSafeURL(relativePath: relPath) else {
            sendTextError(status: 403, reason: "Forbidden", body: "Invalid path")
            return
        }

        var st = stat()
        guard lstat(dirURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            sendTextError(status: 404, reason: "Not Found", body: "Directory not found")
            return
        }

        let tempZipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion-share-\(UUID().uuidString).zip")
        engine.registerTempZip(tempZipURL)

        let engineRef = engine
        let archiveName = (dirURL.lastPathComponent.isEmpty ? "archive" : dirURL.lastPathComponent) + ".zip"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                engineRef.unregisterTempZip(tempZipURL)
                try? FileManager.default.removeItem(at: tempZipURL)
                return
            }
            guard !self.closed, !engineRef.isStopped else {
                engineRef.unregisterTempZip(tempZipURL)
                try? FileManager.default.removeItem(at: tempZipURL)
                return
            }

            guard let measuredBytes = WiFiShareEngine.directoryByteSize(
                at: dirURL.path,
                limit: WiFiShareEngine.maxZipBytes,
                stopCheck: { [weak self] in
                    (self?.closed ?? true) || engineRef.isStopped
                }
            ) else {
                engineRef.unregisterTempZip(tempZipURL)
                try? FileManager.default.removeItem(at: tempZipURL)
                engineRef.queue.async { self.cleanupAndClose() }
                return
            }

            if measuredBytes > WiFiShareEngine.maxZipBytes {
                engineRef.unregisterTempZip(tempZipURL)
                try? FileManager.default.removeItem(at: tempZipURL)
                let msg = engineRef.isEnglish
                    ? "Folder exceeds the 2 GB ZIP limit."
                    : "文件夹体积超过 2 GB 打包限制，请分批下载内部子目录或单文件。"
                engineRef.queue.async {
                    self.sendTextError(status: 413, reason: "Payload Too Large", body: msg)
                }
                return
            }

            do {
                try FileManager.default.zipItem(at: dirURL, to: tempZipURL, shouldKeepParent: true)

                var zipStat = stat()
                guard lstat(tempZipURL.path, &zipStat) == 0 else {
                    engineRef.unregisterTempZip(tempZipURL)
                    try? FileManager.default.removeItem(at: tempZipURL)
                    engineRef.queue.async {
                        self.sendTextError(status: 500, reason: "Internal Server Error", body: "ZIP archive missing")
                    }
                    return
                }

                let zipSize = Int64(zipStat.st_size)
                if zipSize > WiFiShareEngine.maxZipBytes {
                    engineRef.unregisterTempZip(tempZipURL)
                    try? FileManager.default.removeItem(at: tempZipURL)
                    let msg = engineRef.isEnglish ? "Archive exceeds 2 GB limit." : "生成的 ZIP 压缩包超过 2 GB 上限。"
                    engineRef.queue.async {
                        self.sendTextError(status: 413, reason: "Payload Too Large", body: msg)
                    }
                    return
                }

                engineRef.queue.async {
                    guard !self.closed, !engineRef.isStopped else {
                        engineRef.unregisterTempZip(tempZipURL)
                        try? FileManager.default.removeItem(at: tempZipURL)
                        self.cleanupAndClose()
                        return
                    }
                    self.streamFileResponse(
                        fileURL: tempZipURL,
                        downloadName: archiveName,
                        contentType: "application/zip",
                        fileSize: zipSize,
                        onCleanup: {
                            engineRef.unregisterTempZip(tempZipURL)
                            try? FileManager.default.removeItem(at: tempZipURL)
                        }
                    )
                }
            } catch {
                engineRef.unregisterTempZip(tempZipURL)
                try? FileManager.default.removeItem(at: tempZipURL)
                engineRef.queue.async {
                    self.sendTextError(status: 500, reason: "Internal Server Error", body: "ZIP failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func streamFileResponse(
        fileURL: URL,
        downloadName: String,
        contentType: String,
        fileSize: Int64,
        onCleanup: (() -> Void)?
    ) {
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: fileURL)
        } catch {
            onCleanup?()
            sendTextError(status: 500, reason: "Internal Server Error", body: error.localizedDescription)
            return
        }

        let asciiSafe = downloadName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let encodedName = downloadName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "download"

        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(fileSize)\r
        Content-Disposition: attachment; filename="\(asciiSafe)"; filename*=UTF-8''\(encodedName)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """

        guard let headerData = header.data(using: .utf8) else {
            try? fh.close()
            onCleanup?()
            cleanupAndClose()
            return
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard let self else {
                try? fh.close()
                onCleanup?()
                return
            }
            if error != nil || self.closed || self.engine.isStopped {
                try? fh.close()
                onCleanup?()
                self.cleanupAndClose()
                return
            }
            self.pumpFileChunk(fileHandle: fh, onCleanup: onCleanup)
        })
    }

    private func pumpFileChunk(fileHandle: FileHandle, onCleanup: (() -> Void)?) {
        guard !closed, !engine.isStopped else {
            try? fileHandle.close()
            onCleanup?()
            cleanupAndClose()
            return
        }

        let chunk: Data? = autoreleasepool {
            try? fileHandle.read(upToCount: WiFiShareEngine.chunkSize)
        }

        guard let data = chunk, !data.isEmpty else {
            try? fileHandle.close()
            onCleanup?()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.cleanupAndClose()
            })
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else {
                try? fileHandle.close()
                onCleanup?()
                return
            }
            if error != nil || self.closed || self.engine.isStopped {
                try? fileHandle.close()
                onCleanup?()
                self.cleanupAndClose()
                return
            }
            self.pumpFileChunk(fileHandle: fileHandle, onCleanup: onCleanup)
        })
    }

    // MARK: - PUT /api/upload (64 KB Streaming to .part FileHandle, Never Overwrites)

    private func handleUploadStart(
        relPath: String,
        rawName: String,
        headers: [String: String],
        initialBody: Data
    ) {
        guard let targetDir = engine.resolveSafeURL(relativePath: relPath) else {
            sendJSON(status: 403, reason: "Forbidden", payload: ["error": "Invalid target folder"])
            return
        }

        var st = stat()
        guard lstat(targetDir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            sendJSON(status: 404, reason: "Not Found", payload: ["error": "Target folder not found"])
            return
        }

        guard let cleanName = WiFiShareEngine.sanitizeUploadFileName(rawName) else {
            sendJSON(status: 400, reason: "Bad Request", payload: ["error": "Invalid upload filename"])
            return
        }

        let transferEncoding = headers["transfer-encoding"]?.lowercased() ?? ""
        let useChunked = transferEncoding.contains("chunked")

        var fixedLength: Int64 = 0
        if !useChunked {
            guard let lenStr = headers["content-length"],
                  let parsed = Int64(lenStr.trimmingCharacters(in: .whitespaces)),
                  parsed >= 0 else {
                sendJSON(status: 411, reason: "Length Required", payload: ["error": "Valid Content-Length required"])
                return
            }
            fixedLength = parsed
        }

        let needsContinue = (headers["expect"]?.lowercased().contains("100-continue") ?? false)

        if FileManager.default.isWritableFile(atPath: targetDir.path) {
            beginUploadWrite(
                targetDir: targetDir,
                desiredName: cleanName,
                useChunked: useChunked,
                contentLength: fixedLength,
                sendContinue: needsContinue,
                initialBody: initialBody
            )
        } else {
            let ensureAccess = engine.callbacks.ensureWriteAccess
            let queue = engine.queue
            Task { [weak self] in
                let ok = await ensureAccess(targetDir.path)
                let session = self
                queue.async { [weak session] in
                    guard let session, !session.closed, !session.engine.isStopped else { return }
                    guard ok else {
                        session.sendJSON(status: 403, reason: "Forbidden", payload: ["error": "Target folder is not writable"])
                        return
                    }
                    session.beginUploadWrite(
                        targetDir: targetDir,
                        desiredName: cleanName,
                        useChunked: useChunked,
                        contentLength: fixedLength,
                        sendContinue: needsContinue,
                        initialBody: initialBody
                    )
                }
            }
        }
    }

    private func beginUploadWrite(
        targetDir: URL,
        desiredName: String,
        useChunked: Bool,
        contentLength: Int64,
        sendContinue: Bool,
        initialBody: Data
    ) {
        let partURL = targetDir.appendingPathComponent(".erosion_upload_\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: partURL.path, contents: nil),
              let fh = try? FileHandle(forWritingTo: partURL) else {
            sendJSON(status: 500, reason: "Internal Server Error", payload: ["error": "Failed to open .part file"])
            return
        }

        engine.registerPartFile(partURL)
        self.uploadHandle = fh
        self.uploadPartURL = partURL
        self.uploadTargetDir = targetDir
        self.uploadDesiredName = desiredName
        self.uploadBytesWritten = 0
        self.isChunkedUpload = useChunked
        self.uploadRemainingFixed = contentLength
        self.chunkedDecoder = ChunkedBodyDecoder()

        let startBodyTransfer = { [weak self] in
            guard let self, !self.closed, !self.engine.isStopped else { return }
            if !initialBody.isEmpty {
                self.consumeUploadSlice(initialBody)
            } else if !self.isChunkedUpload && self.uploadRemainingFixed == 0 {
                self.completeUpload()
            } else {
                self.receiveNextUploadChunk()
            }
        }

        if sendContinue, let contData = "HTTP/1.1 100 Continue\r\n\r\n".data(using: .ascii) {
            connection.send(content: contData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || self.closed || self.engine.isStopped {
                    self.cleanupAndClose()
                    return
                }
                startBodyTransfer()
            })
        } else {
            startBodyTransfer()
        }
    }

    private func receiveNextUploadChunk() {
        guard !closed, !engine.isStopped else {
            cleanupAndClose()
            return
        }

        let maxLen: Int
        if isChunkedUpload {
            maxLen = WiFiShareEngine.chunkSize
        } else {
            if uploadRemainingFixed <= 0 {
                completeUpload()
                return
            }
            maxLen = Int(min(Int64(WiFiShareEngine.chunkSize), uploadRemainingFixed))
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLen) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, !self.engine.isStopped else { return }

            if error != nil {
                self.cleanupAndClose()
                return
            }

            if let data, !data.isEmpty {
                self.consumeUploadSlice(data)
                return
            }

            if isComplete {
                if !self.isChunkedUpload && self.uploadRemainingFixed == 0 {
                    self.completeUpload()
                } else {
                    // Client disconnected before upload completed: delete partial .part file
                    self.cleanupAndClose()
                }
            } else {
                self.receiveNextUploadChunk()
            }
        }
    }

    private func consumeUploadSlice(_ slice: Data) {
        guard let fh = uploadHandle else {
            cleanupAndClose()
            return
        }

        if isChunkedUpload {
            do {
                let finished = try chunkedDecoder.feed(slice) { payloadChunk in
                    try fh.write(contentsOf: payloadChunk)
                    uploadBytesWritten += Int64(payloadChunk.count)
                }
                if finished {
                    completeUpload()
                } else {
                    receiveNextUploadChunk()
                }
            } catch {
                abortActiveUpload()
                sendJSON(status: 400, reason: "Bad Request", payload: ["error": "Upload stream failed"])
            }
        } else {
            let takeCount = Int(min(Int64(slice.count), uploadRemainingFixed))
            if takeCount > 0 {
                do {
                    try autoreleasepool {
                        if takeCount == slice.count {
                            try fh.write(contentsOf: slice)
                        } else {
                            try fh.write(contentsOf: slice.prefix(takeCount))
                        }
                    }
                    uploadBytesWritten += Int64(takeCount)
                    uploadRemainingFixed -= Int64(takeCount)
                } catch {
                    abortActiveUpload()
                    sendJSON(status: 500, reason: "Internal Server Error", payload: ["error": "Disk write error"])
                    return
                }
            }

            if uploadRemainingFixed <= 0 {
                completeUpload()
            } else {
                receiveNextUploadChunk()
            }
        }
    }

    private func completeUpload() {
        guard let fh = uploadHandle,
              let partURL = uploadPartURL,
              let targetDir = uploadTargetDir else {
            cleanupAndClose()
            return
        }

        uploadHandle = nil
        uploadPartURL = nil

        do {
            try fh.synchronize()
            try fh.close()
            let finalURL = try engine.finalizePartFile(partURL, in: targetDir, desiredName: uploadDesiredName)
            let savedName = finalURL.lastPathComponent
            let renamed = (savedName != uploadDesiredName)

            let eventText: String
            if engine.isEnglish {
                eventText = renamed
                    ? "Uploaded \(uploadDesiredName) -> \(savedName) (auto-renamed)"
                    : "Uploaded \(savedName)"
            } else {
                eventText = renamed
                    ? "已接收上传：\(uploadDesiredName) -> \(savedName)（重名自动重命名）"
                    : "已接收上传：\(savedName)"
            }
            engine.callbacks.onEvent(eventText, false)
            engine.callbacks.onUploadFinished()

            sendJSON(
                status: 201,
                reason: "Created",
                payload: [
                    "ok": true,
                    "savedName": savedName,
                    "bytes": uploadBytesWritten
                ]
            )
        } catch {
            engine.unregisterPartFile(partURL)
            try? FileManager.default.removeItem(at: partURL)
            engine.callbacks.onEvent(
                engine.isEnglish
                    ? "Upload failed: \(error.localizedDescription)"
                    : "保存上传文件失败：\(error.localizedDescription)",
                true
            )
            sendJSON(status: 500, reason: "Internal Server Error", payload: ["error": error.localizedDescription])
        }
    }

    private func abortActiveUpload() {
        if let fh = uploadHandle {
            uploadHandle = nil
            try? fh.close()
        }
        if let partURL = uploadPartURL {
            uploadPartURL = nil
            engine.unregisterPartFile(partURL)
            try? FileManager.default.removeItem(at: partURL)
        }
    }

    // MARK: - HTTP Response Senders

    private func sendUnauthorized() {
        let bodyData = Data("401 Unauthorized\n".utf8)
        let header = """
        HTTP/1.1 401 Unauthorized\r
        WWW-Authenticate: Basic realm="Erosion Wi-Fi Share", charset="UTF-8"\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        sendRawResponse(header: header, body: bodyData)
    }

    private func sendHTML(_ html: String) {
        let bodyData = Data(html.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        sendRawResponse(header: header, body: bodyData)
    }

    private func sendJSON(status: Int, reason: String, payload: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        sendRawResponse(header: header, body: bodyData)
    }

    private func sendTextError(status: Int, reason: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        sendRawResponse(header: header, body: bodyData)
    }

    private func sendRawResponse(header: String, body: Data) {
        var combined = Data(header.utf8)
        combined.append(body)
        connection.send(content: combined, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cleanupAndClose()
        })
    }
}

private nonisolated struct ChunkedBodyDecoder {
    private enum State {
        case readingSize
        case readingData(remaining: Int)
        case readingDataCRLF
        case readingTrailers
        case finished
    }

    private var buffer = Data()
    private var state: State = .readingSize

    mutating func feed(_ input: Data, onData: (Data) throws -> Void) throws -> Bool {
        buffer.append(input)
        let crlf = Data([0x0D, 0x0A])

        while true {
            switch state {
            case .readingSize:
                guard let lineEnd = buffer.range(of: crlf) else {
                    if buffer.count > 4096 {
                        throw NSError(domain: "ChunkedBodyDecoder", code: 1)
                    }
                    return false
                }
                let lineData = buffer.subdata(in: 0..<lineEnd.lowerBound)
                buffer.removeSubrange(0..<lineEnd.upperBound)
                guard let line = String(data: lineData, encoding: .ascii) else {
                    throw NSError(domain: "ChunkedBodyDecoder", code: 2)
                }
                let sizeToken = line.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let chunkSize = Int(sizeToken, radix: 16), chunkSize >= 0 else {
                    throw NSError(domain: "ChunkedBodyDecoder", code: 3)
                }
                if chunkSize == 0 {
                    state = .readingTrailers
                } else {
                    state = .readingData(remaining: chunkSize)
                }

            case .readingData(let remaining):
                guard !buffer.isEmpty else { return false }
                let take = min(remaining, buffer.count)
                let slice = buffer.subdata(in: 0..<take)
                buffer.removeSubrange(0..<take)
                try onData(slice)
                let nextRemaining = remaining - take
                state = nextRemaining == 0 ? .readingDataCRLF : .readingData(remaining: nextRemaining)

            case .readingDataCRLF:
                guard buffer.count >= 2 else { return false }
                guard buffer[buffer.startIndex] == 0x0D, buffer[buffer.startIndex + 1] == 0x0A else {
                    throw NSError(domain: "ChunkedBodyDecoder", code: 4)
                }
                buffer.removeSubrange(0..<2)
                state = .readingSize

            case .readingTrailers:
                if buffer.starts(with: crlf) {
                    buffer.removeSubrange(0..<2)
                    state = .finished
                    return true
                }
                if let end = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                    buffer.removeSubrange(0..<end.upperBound)
                    state = .finished
                    return true
                }
                if buffer.count > 16_384 {
                    throw NSError(domain: "ChunkedBodyDecoder", code: 5)
                }
                return false

            case .finished:
                return true
            }
        }
    }
}
