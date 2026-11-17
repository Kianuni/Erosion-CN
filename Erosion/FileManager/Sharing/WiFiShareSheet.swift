//
//  WiFiShareSheet.swift
//  Erosion
//
//  SwiftUI sheet for Wi-Fi HTTP File Sharing with URL/PIN copy and lifecycle guardrails.
//

import SwiftUI
import UIKit

struct WiFiShareSheet: View {
    let rootURL: URL

    @StateObject private var server = WiFiShareServer()
    @Environment(\.dismiss) private var dismiss

    @State private var copiedTag: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle)
                                .font(.subheadline.weight(.semibold))
                            Text(rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            if case .running = server.state {
                                server.stop()
                            } else if case .starting = server.state {
                                server.stop()
                            } else {
                                server.start(rootURL: rootURL)
                            }
                        } label: {
                            Text(isServerActive
                                 ? (LocalizationManager.isEnglish ? "Stop" : "停止")
                                 : (LocalizationManager.isEnglish ? "Start" : "启动"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(isServerActive ? .red : .accentColor)
                    }

                    Text(rootURL.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } header: {
                    HeaderLabel(LocalizationManager.isEnglish ? "Share Target" : "共享目录", symbol: "wifi")
                }

                if server.wifiIP == nil {
                    Section {
                        CompactAlert(
                            title: LocalizationManager.isEnglish ? "Wi-Fi IP Unavailable" : "未检测到 Wi-Fi 局域网 IP",
                            symbol: "wifi.exclamationmark",
                            text: LocalizationManager.isEnglish
                                ? "Connect to Wi-Fi (en0) on the same LAN as your computer or phone, then tap Refresh IP."
                                : "请确认设备已连接至同一局域网 Wi-Fi (en0)，然后点击下方刷新 IP。",
                            color: .orange
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                        Button {
                            server.refreshIPAddress()
                        } label: {
                            Label(
                                LocalizationManager.isEnglish ? "Refresh Wi-Fi IP" : "刷新 Wi-Fi IP 地址",
                                systemImage: "arrow.clockwise"
                            )
                        }
                    }
                }

                Section {
                    if let urlStr = server.shareURLString {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizationManager.isEnglish ? "Browser URL" : "访问地址")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(urlStr)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Button {
                                copyToPasteboard(urlStr, tag: "url")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedTag == "url" ? "checkmark" : "doc.on.doc")
                                    Text(copiedTag == "url"
                                         ? (LocalizationManager.isEnglish ? "Copied" : "已复制")
                                         : (LocalizationManager.isEnglish ? "Copy" : "复制"))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .fixedSize()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .fixedSize()
                        }
                    } else {
                        HStack {
                            Text(LocalizationManager.isEnglish ? "Browser URL" : "访问地址")
                            Spacer()
                            Text(LocalizationManager.isEnglish ? "Waiting for Wi-Fi & port..." : "等待服务与 Wi-Fi 地址就绪...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizationManager.isEnglish ? "Username (optional)" : "用户名（可留空）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(server.username)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button {
                            copyToPasteboard(server.username, tag: "user")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedTag == "user" ? "checkmark" : "doc.on.doc")
                                Text(copiedTag == "user"
                                     ? (LocalizationManager.isEnglish ? "Copied" : "已复制")
                                     : (LocalizationManager.isEnglish ? "Copy" : "复制"))
                            }
                            .font(.caption.weight(.semibold))
                            .fixedSize()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizationManager.isEnglish ? "Session PIN (6-digit)" : "一次性随机密码 (6位)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(server.pin.isEmpty ? "------" : server.pin)
                                .font(.system(.title3, design: .monospaced).weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button {
                            copyToPasteboard(server.pin, tag: "pin")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedTag == "pin" ? "checkmark" : "key.fill")
                                Text(copiedTag == "pin"
                                     ? (LocalizationManager.isEnglish ? "Copied" : "已复制")
                                     : (LocalizationManager.isEnglish ? "Copy PIN" : "复制密码"))
                            }
                            .font(.caption.weight(.semibold))
                            .fixedSize()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(server.pin.isEmpty)
                    }

                    if let urlStr = server.shareURLString, !server.pin.isEmpty {
                        Button {
                            let combined = "\(urlStr)\n\(LocalizationManager.isEnglish ? "Username" : "用户名"): \(server.username)\n\(LocalizationManager.isEnglish ? "PIN" : "密码"): \(server.pin)"
                            copyToPasteboard(combined, tag: "all")
                        } label: {
                            Label(
                                copiedTag == "all"
                                    ? (LocalizationManager.isEnglish ? "Copied URL & PIN" : "已复制地址与密码")
                                    : (LocalizationManager.isEnglish ? "Copy URL & PIN" : "一键复制访问地址与密码"),
                                systemImage: copiedTag == "all" ? "checkmark.circle.fill" : "square.on.square"
                            )
                        }
                    }
                } header: {
                    HeaderLabel(LocalizationManager.isEnglish ? "Connection & Basic Auth" : "连接信息与认证凭据", symbol: "lock.shield")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(
                                LocalizationManager.isEnglish
                                    ? "Safari recommended: Open the address in Safari first. If Chrome, Edge, or Arc cannot connect on macOS, enable it in System Settings -> Privacy & Security -> Local Network (toggle off and on again if needed), or try another browser."
                                    : "优先推荐 Safari 打开：建议优先使用电脑或手机自带的 Safari 浏览器；若 Chrome / Edge / Arc 打不开，请检查 Mac「系统设置 ➔ 隐私与安全性 ➔ 本地网络」中对应浏览器的权限（已开启可先关闭再重开），或换其他浏览器重试。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "safari.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.caption)
                        }

                        Label {
                            Text(
                                LocalizationManager.isEnglish
                                    ? "Protocol & Login: Keep the URL starting with http:// (not https://). At the prompt, enter the 6-digit PIN above (username 'erosion' or blank)."
                                    : "协议与登录：网址必须以 http:// 开头（不要用 https://）；弹出登录框时输入上方 6 位随机密码即可（用户名填 erosion 或留空均可）。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "key.viewfinder")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }

                        Label {
                            Text(
                                LocalizationManager.isEnglish
                                    ? "Stay on this page: The screen stays awake while active. Dismissing or switching apps stops the server and rotates the PIN."
                                    : "保活提示：传输期间请保持停留在当前页面（屏幕自动常亮）；关闭页面或切出到微信等其他 App 会自动停服并刷新密码。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    HeaderLabel(LocalizationManager.isEnglish ? "Browser & Connection Tips" : "浏览器打开说明", symbol: "safari")
                }

                if !server.events.isEmpty {
                    Section {
                        ForEach(server.events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: event.isError ? "exclamationmark.triangle.fill" : "arrow.up.arrow.down.circle.fill")
                                    .foregroundStyle(event.isError ? .red : .green)
                                    .font(.caption)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.message)
                                        .font(.caption)
                                    Text(event.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        HeaderLabel(LocalizationManager.isEnglish ? "Transfer Activity" : "传输动态", symbol: "list.bullet.rectangle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LocalizationManager.isEnglish ? "Wi-Fi File Sharing" : "Wi-Fi 无线文件传输")
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
                server.start(rootURL: rootURL)
            }
            .onDisappear {
                server.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                server.stop()
            }
        }
    }

    private var isServerActive: Bool {
        switch server.state {
        case .running, .starting:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private var statusColor: Color {
        switch server.state {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private var statusTitle: String {
        switch server.state {
        case .running(let port):
            return LocalizationManager.isEnglish
                ? "Running on port \(port) (\(server.activeConnectionsCount) active)"
                : "服务运行中 · 端口 \(port)（活跃连接 \(server.activeConnectionsCount)）"
        case .starting:
            return LocalizationManager.isEnglish ? "Starting HTTP listener..." : "正在启动 HTTP 服务..."
        case .stopped:
            return LocalizationManager.isEnglish ? "Stopped" : "已停止"
        case .failed(let msg):
            return LocalizationManager.isEnglish ? "Failed: \(msg)" : "启动失败：\(msg)"
        }
    }

    private func copyToPasteboard(_ value: String, tag: String) {
        UIPasteboard.general.string = value
        Haptic.shared.play(.light)
        copiedTag = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if copiedTag == tag {
                copiedTag = nil
            }
        }
    }
}
