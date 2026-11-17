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
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizationManager.isEnglish ? "Browser URL" : "访问地址")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(urlStr)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                copyToPasteboard(urlStr, tag: "url")
                            } label: {
                                Label(
                                    copiedTag == "url"
                                        ? (LocalizationManager.isEnglish ? "Copied" : "已复制")
                                        : (LocalizationManager.isEnglish ? "Copy" : "复制"),
                                    systemImage: copiedTag == "url" ? "checkmark" : "doc.on.doc"
                                )
                                .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        HStack {
                            Text(LocalizationManager.isEnglish ? "Browser URL" : "访问地址")
                            Spacer()
                            Text(LocalizationManager.isEnglish ? "Waiting for Wi-Fi & port..." : "等待服务与 Wi-Fi 地址就绪...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text(LocalizationManager.isEnglish ? "Username" : "用户名")
                        Spacer()
                        Text(server.username)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizationManager.isEnglish ? "Session PIN (6-digit)" : "一次性随机密码 (6位)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(server.pin.isEmpty ? "------" : server.pin)
                                .font(.system(.title3, design: .monospaced).weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            copyToPasteboard(server.pin, tag: "pin")
                        } label: {
                            Label(
                                copiedTag == "pin"
                                    ? (LocalizationManager.isEnglish ? "Copied" : "已复制")
                                    : (LocalizationManager.isEnglish ? "Copy PIN" : "复制密码"),
                                systemImage: copiedTag == "pin" ? "checkmark" : "key.fill"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
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
                } footer: {
                    Text(
                        LocalizationManager.isEnglish
                            ? "Open the URL above in any browser on the same Wi-Fi and enter username 'erosion' with the 6-digit PIN. The screen stays awake while running, and stops automatically if dismissed or backgrounded."
                            : "在同局域网电脑或手机浏览器打开上述地址，输入用户名 erosion 与 6 位随机密码即可浏览、打包下载或拖入上传。运行期间屏幕保持常亮，关闭页面或退回后台将自动停止服务。"
                    )
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
