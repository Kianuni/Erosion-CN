#!/usr/bin/env python3
"""Generate or update official AltStore / SideStore / Feather apps.json from GitHub Releases."""

from __future__ import annotations

import hashlib
import io
import json
import os
import plistlib
import urllib.request
import zipfile
from pathlib import Path

REPO = os.environ.get("GITHUB_REPOSITORY", "Kianuni/Erosion-CN")
MAX_VERSIONS = 8
ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = ROOT / "apps.json"

LOCALIZED_DESC = (
    "Erosion-CN 是面向 iOS / iPadOS 27.0–27.2.1 & 27.3 beta 1（及 26.x 部分功能）的中英双语系统配置与 MobileGestalt 研究工具箱（防白苹果安全加固版）。\n\n"
    "• 原位覆盖写入（pwrite + F_FULLFSYNC）与写后全量读回校验，杜绝重启反弹与 0 字节白苹果\n"
    "• 无损 CoreFoundation 类型直通，根治相机取景黑屏\n"
    "• 运行时动态解析 libMobileGestalt.dylib 槽位 + 双金库 SHA-256 备份一键恢复原厂\n"
    "• 支持国行 Apple 智能解锁、海外 eSIM 与 FaceTime 音频开启、应用存档备份、缓存清理与电池/崩溃诊断\n\n"
    "⚠️ 签名要求：安装时请务必保留 App Group 权限（SideStore / AltStore / Feather 默认支持）。\n\n"
    "Bilingual (English + Simplified Chinese) bootloop-hardened MobileGestalt & cross-container research toolkit for iOS/iPadOS 27.x. "
    "Requires at least one App Group entitlement when signing."
)


def http_get_bytes(url: str) -> bytes:
    headers = {
        "User-Agent": "Erosion-CN-AltStore-Sync/1.0",
        "Accept": "application/vnd.github+json",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token and ("api.github.com" in url or "github.com" in url):
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def inspect_ipa_bytes(ipa_bytes: bytes) -> dict:
    meta: dict = {}
    with zipfile.ZipFile(io.BytesIO(ipa_bytes), "r") as zf:
        info_names = [
            n for n in zf.namelist()
            if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2
        ]
        if info_names:
            info = plistlib.loads(zf.read(info_names[0]))
            if info.get("CFBundleVersion"):
                meta["buildVersion"] = str(info["CFBundleVersion"])
            if info.get("MinimumOSVersion"):
                meta["minOSVersion"] = str(info["MinimumOSVersion"])
            if info.get("CFBundleIdentifier"):
                meta["bundleIdentifier"] = str(info["CFBundleIdentifier"])
    return meta


def load_existing_versions() -> dict[str, dict]:
    if not OUTPUT_PATH.exists():
        return {}
    try:
        existing = json.loads(OUTPUT_PATH.read_text(encoding="utf-8"))
        versions = existing.get("apps", [{}])[0].get("versions", [])
        return {v["version"]: v for v in versions if isinstance(v, dict) and "version" in v}
    except Exception:
        return {}


def main() -> None:
    existing_by_ver = load_existing_versions()
    api_url = f"https://api.github.com/repos/{REPO}/releases?per_page=20"
    releases = json.loads(http_get_bytes(api_url).decode("utf-8"))

    versions_out: list[dict] = []
    bundle_id = "com.jbdotparty.Erosion"

    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        assets = [a for a in rel.get("assets", []) if a.get("name", "").endswith(".ipa")]
        if not assets:
            continue
        asset = assets[0]
        tag = str(rel.get("tag_name") or "").strip()
        version = tag.lstrip("vV")
        if not version:
            continue

        prev = existing_by_ver.get(version, {})
        digest_raw = str(asset.get("digest") or "")
        sha256 = digest_raw.split("sha256:", 1)[1].lower() if digest_raw.startswith("sha256:") else prev.get("sha256")
        build_ver = prev.get("buildVersion")
        min_os = prev.get("minOSVersion", "26.0")

        # Always inspect the newest IPA (or if sha256 is missing) to capture exact CFBundleVersion & MinimumOSVersion
        if (len(versions_out) == 0 and not build_ver) or not sha256:
            local_ipa = ROOT / asset["name"]
            if local_ipa.exists() and local_ipa.stat().st_size == asset.get("size"):
                ipa_bytes = local_ipa.read_bytes()
            else:
                dl_headers = {"User-Agent": "Erosion-CN-AltStore-Sync/1.0"}
                req = urllib.request.Request(asset["browser_download_url"], headers=dl_headers)
                with urllib.request.urlopen(req, timeout=60) as resp:
                    ipa_bytes = resp.read()
            if not sha256:
                sha256 = hashlib.sha256(ipa_bytes).hexdigest()
            ipa_meta = inspect_ipa_bytes(ipa_bytes)
            build_ver = ipa_meta.get("buildVersion") or build_ver
            min_os = ipa_meta.get("minOSVersion") or min_os
            bundle_id = ipa_meta.get("bundleIdentifier") or bundle_id

        entry: dict = {
            "version": version,
        }
        if build_ver:
            entry["buildVersion"] = build_ver
        entry.update({
            "date": rel.get("published_at") or rel.get("created_at"),
            "localizedDescription": (rel.get("body") or f"Erosion-CN v{version}").strip(),
            "downloadURL": asset["browser_download_url"],
            "size": int(asset["size"]),
            "sha256": sha256,
            "minOSVersion": min_os,
        })
        versions_out.append(entry)
        if len(versions_out) >= MAX_VERSIONS:
            break

    if not versions_out:
        raise RuntimeError("No eligible IPA releases found on GitHub.")

    latest = versions_out[0]
    icon_url = f"https://raw.githubusercontent.com/{REPO}/main/PreviewIcon.png"

    app_obj: dict = {
        "name": "Erosion-CN",
        "bundleIdentifier": bundle_id,
        "developerName": "Kianuni",
        "subtitle": "iOS / iPadOS 系统配置与 MobileGestalt 研究工具箱（中英双语）",
        "localizedDescription": LOCALIZED_DESC,
        "iconURL": icon_url,
        "tintColor": "#CF7D46",
        "category": "utilities",
        "screenshots": [],
        "appPermissions": {
            "entitlements": [
                "com.apple.security.application-groups"
            ],
            "privacy": {},
        },
        "version": latest["version"],
    }
    if "buildVersion" in latest:
        app_obj["buildVersion"] = latest["buildVersion"]
    app_obj.update({
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
        "versions": versions_out,
    })

    source_doc = {
        "name": "Erosion-CN Official",
        "identifier": "com.kianuni.erosion-cn.source",
        "subtitle": "Erosion-CN 官方自动更新源 (SideStore / AltStore / Feather)",
        "description": "Kianuni/Erosion-CN 官方软件源：基于 worse_query 的 iOS / iPadOS 系统配置与 MobileGestalt 研究工具箱（中英双语 · 防白苹果安全加固版）。每次 GitHub Release 发布自动同步。",
        "iconURL": icon_url,
        "website": f"https://github.com/{REPO}",
        "tintColor": "#CF7D46",
        "featuredApps": [bundle_id],
        "apps": [app_obj],
        "news": [],
    }

    OUTPUT_PATH.write_text(
        json.dumps(source_doc, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"[OK] Wrote {OUTPUT_PATH} with {len(versions_out)} versions (latest: v{latest['version']}, build {latest.get('buildVersion')}).")


if __name__ == "__main__":
    main()
