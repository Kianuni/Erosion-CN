//
//  FMNavigationStore.swift
//  Erosion
//
//  Persists recently visited non-root folders and path canonicalization helpers.
//

import Foundation
import Combine
import Darwin

struct RecentFolderEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let title: String
    let visitedAt: Date
}

@MainActor
final class FMNavigationStore: ObservableObject {
    static let shared = FMNavigationStore()
    static let maxRecentCount = 15

    @Published private(set) var recentFolders: [RecentFolderEntry] = []

    private let defaultsKey = "erosion_fm_recent_folders_v1"

    private nonisolated static let excludedRoots: Set<String> = [
        "/",
        "/var/mobile/Containers/Data/Application",
        "/var/containers/Bundle/Application",
        "/var/containers/Shared/SystemGroup",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/mobile/Containers/Data/PluginKitPlugin",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/containers/Data/System"
    ]

    private init() {
        load()
    }

    nonisolated static func canonicalPath(_ rawPath: String) -> String {
        var p = (rawPath as NSString).standardizingPath
        if p.hasPrefix("/private/var/") {
            p = String(p.dropFirst("/private".count))
        } else if p == "/private/var" {
            p = "/var"
        }
        return p
    }

    nonisolated static func isExcludedRoot(_ path: String) -> Bool {
        let canon = canonicalPath(path)
        return canon.isEmpty || excludedRoots.contains(canon)
    }

    func record(url: URL, customTitle: String? = nil) {
        let canon = Self.canonicalPath(url.standardizedFileURL.path)
        guard !Self.isExcludedRoot(canon) else { return }

        var st = stat()
        guard stat(canon, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }

        let resolvedTitle: String
        if let customTitle, !customTitle.isEmpty {
            resolvedTitle = customTitle
        } else {
            let parent = Self.canonicalPath(URL(fileURLWithPath: canon).deletingLastPathComponent().path)
            if Self.excludedRoots.contains(parent),
               let labeled = folderLabel(url: URL(fileURLWithPath: canon)),
               !labeled.isEmpty {
                resolvedTitle = labeled
            } else {
                let last = URL(fileURLWithPath: canon).lastPathComponent
                resolvedTitle = last.isEmpty ? canon : last
            }
        }

        var updated = recentFolders.filter { Self.canonicalPath($0.path) != canon }
        updated.insert(
            RecentFolderEntry(path: canon, title: resolvedTitle, visitedAt: Date()),
            at: 0
        )
        if updated.count > Self.maxRecentCount {
            updated = Array(updated.prefix(Self.maxRecentCount))
        }
        recentFolders = updated
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard recentFolders.indices.contains(index) else { continue }
            recentFolders.remove(at: index)
        }
        save()
    }

    func remove(path: String) {
        let canon = Self.canonicalPath(path)
        recentFolders.removeAll { Self.canonicalPath($0.path) == canon }
        save()
    }

    func clear() {
        recentFolders.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RecentFolderEntry].self, from: data) else {
            recentFolders = []
            return
        }
        recentFolders = Array(decoded.prefix(Self.maxRecentCount))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recentFolders) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
