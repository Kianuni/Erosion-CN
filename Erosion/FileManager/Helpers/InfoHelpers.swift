//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI

enum FolderType {
    case normal, bundle, container
}

func getFolderType(url: URL) -> FolderType {
    let parent = url.deletingLastPathComponent().path
    
    if parent == FSPaths.appBundles {
        return .bundle
    } else if parent == FSPaths.appContainers {
        return .container
    }
    return .normal
}

private let xattrBIDCacheLock = NSLock()
private var xattrBIDCache: [String: String] = [:]

func clearXattrBIDCache() {
    xattrBIDCacheLock.lock()
    xattrBIDCache.removeAll()
    xattrBIDCacheLock.unlock()
}

// this is awful
func getBIDFromXattr(_ url: URL) -> String? {
    let normKey = CSStoreEngine.normalizeVarPath(url.path)

    if let fastBID = CSStoreEngine.shared.bundleID(forContainerPath: normKey, allowDiscovery: false),
       !fastBID.isEmpty {
        return fastBID
    }

    xattrBIDCacheLock.lock()
    if let cached = xattrBIDCache[normKey] {
        xattrBIDCacheLock.unlock()
        return cached.isEmpty ? nil : cached
    }
    xattrBIDCacheLock.unlock()

    let wasAlreadyActive = wq.hasActiveAccess(path: url.path)
    let grantRes = wq.grantAccess(path: url.path, requireWrite: false)
    guard grantRes.0 else {
        return nil
    }
    defer {
        if !wasAlreadyActive {
            wq.releaseAccess(path: url.path)
        }
    }

    var buf = [CChar](repeating: 0, count: 512)
    let len = getxattr(url.path, "com.apple.containermanager.identifier", &buf, 511, 0, XATTR_NOFOLLOW)
    if len >= 0 {
        let bid = String(cString: buf)
        if !bid.isEmpty {
            xattrBIDCacheLock.lock()
            xattrBIDCache[normKey] = bid
            xattrBIDCacheLock.unlock()
            return bid
        }
    }

    // Fallback to container metadata plist (useful for iOS 27.2 / AppGroup containers)
    for metaName in [".com.apple.mobile_container_manager.metadata.plist", "com.apple.mobile_container_manager.metadata.plist"] {
        let metaURL = url.appendingPathComponent(metaName)
        if let data = try? Data(contentsOf: metaURL),
           let id = metadataID(from: data), !id.isEmpty {
            xattrBIDCacheLock.lock()
            xattrBIDCache[normKey] = id
            xattrBIDCacheLock.unlock()
            return id
        }
    }
    return nil
}

// i don't know why root's works and mine doesn't, but i'm stealing it.
func folderLabel(url: URL) -> String? {
    guard let bid = getBIDFromXattr(url) else { return nil }
    if let cnName = CSStoreEngine.shared.localizedName(forBundleID: bid),
       cnName != bid {
        return "\(cnName) (\(bid))"
    }
    return bid
}

func metadataID(from data: Data) -> String? {
    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    return plist?["MCMMetadataIdentifier"] as? String
}

func readMetaKey(at url: URL, key: String) -> String? {
    if url.path.contains("/var/mobile/Containers/Shared/AppGroup") && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
        let handle = worse_query(url.path, group, true, false)
        guard handle >= 0 else { return nil }
        do { worse_query_release(handle) }
    } else {
        let handle = worse_query(url.path, group, false, false)
        guard handle >= 0 else { return nil }
        do { worse_query_release(handle) }
    }
     
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        return nil
    }

    return plist[key] as? String
}

enum SysBID {
    static var phone = "com.apple.mobilephone"
    static var poster = "com.apple.PosterBoard"
}
