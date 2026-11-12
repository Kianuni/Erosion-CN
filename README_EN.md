<div align="center">
  <br>
  <a href="https://github.com/Kianuni/Erosion-CN/releases/latest"><img src="./PreviewIcon.png" alt="App Icon" width="150"></a>
  <br>
  <h1>Erosion-CN (Bilingual Edition)</h1>
  <p>An iOS / iPadOS System Customization, Cross-Container &amp; Bootloop-Hardened MobileGestalt Research Toolkit powered by <a href="https://github.com/forcequitOS/worse_query">worse_query</a></p>
  <p>Supports iOS / iPadOS 27.0 – 27.2.1 &amp; 27.3 beta 1 (Full Support) and iOS / iPadOS 26.x (Partial Support).</p>
  <p><a href="./README.md">简体中文文档</a> · <strong>English</strong></p>
  <a href="https://github.com/Kianuni/Erosion-CN/releases/latest"><img alt="GitHub Releases" src="https://img.shields.io/github/v/release/Kianuni/Erosion-CN?style=flat-square&color=CF7D46&label=Latest%20Release"></a>
  <a href="https://github.com/jailbreakdotparty/Erosion"><img alt="Upstream Repo" src="https://img.shields.io/badge/Upstream-jailbreakdotparty%2FErosion-3868DB?style=flat-square"></a>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue?style=flat-square"></a>
</div>

---

## Overview

**Erosion-CN** started as a Simplified Chinese fork of **[jailbreakdotparty/Erosion](https://github.com/jailbreakdotparty/Erosion)** and evolved into a heavily hardened, feature-packed toolkit. Starting with **v0.9.0**, a single IPA includes **full English + Simplified Chinese bilingual support**:
- Automatically matches your device's system language out of the box (English for all non-Chinese system locales, Simplified Chinese for `zh*`).
- Includes an instant **Language Switcher** in **Settings → App Language** (`Follow System` / `简体中文` / `English`).

---

## Key Improvements Over Upstream

1. **Persistent In-Place MobileGestalt Writes & Bootloop Hardening**
   - Replaces temp-file swaps (`replaceItemAt`) with a zero-byte-window in-place write protocol (`pwrite` at offset `0` + tail `ftruncate` + `fcntl(fd, F_FULLFSYNC)`), preserving original inode and `_mobilegestalt` ownership so tweaks survive reboots without reverting.
   - Avoids injecting non-cached keys (such as `RegionInfo` on iOS 27) that trigger boot-time cache invalidation, and strips brick-prone toggles (regex-sliced iPadOS mode on iPhone, fake retail supervision).
   - **Pre-Apply Diff Preview + Post-Write Readback Verification**: Previews every key/hex change before writing, saves a `PreApplyGestalt.plist` snapshot, and automatically rolls back on any readback mismatch.

2. **Lossless CoreFoundation Plist Serialization (No Camera Black Screen)**
   - Preserves exact `CFBoolean` (`<true/>` / `<false/>`) and floating-point `CFNumber` (`1.0`, `2.0`, `5.0` camera zoom factors) types via `CFBooleanGetTypeID()` and `CFNumberIsFloatType()`, passing unmodified entries through losslessly.

3. **Zero-Hardcoded Runtime `libMobileGestalt.dylib` Binary `CacheData` Engine**
   - Dynamically scans loaded `libMobileGestalt.dylib` query descriptors in memory to resolve exact `CacheUUID`, slot count, and boolean `CacheData` slot offsets for your exact device and iOS build.
   - Promotes Dynamic Island, Always-On Display, Liquid Glass Low-Power Rendering, 80% Charge Limit, Boot Chime, Crash Detection, PWM Dimming, Camera Control, Action Button, Tap to Wake, Stage Manager, Audio Mix, Spatial Audio, Responsive Shutter, Hypertension Notifications, and 14 experimental hardware capability slots to dual `CacheData + CacheExtra` writes with native hardware anti-downgrade locks.
   - **Live `MGCopyAnswer` Inspector (`MGInspectorView`)**: Compares factory backup values, staged `CacheData / CacheExtra` values, and live `MGCopyAnswer` answers side by side across all `720+` dynamic slots.

4. **Dual-Vault Factory Backup & One-Tap Factory Restore**
   - Mirrors your clean `OriginalGestalt.plist` + `SHA-256` digest into both app storage and a persistent shared system vault so your clean factory backup survives app uninstalls/reinstalls.
   - **One-Tap Factory Restore** verifies `SHA-256`, `CacheVersion`, `CacheUUID`, `CacheData` byte length, and kernel `ProductType`, restoring factory state and cleaning up Lock Screen footnote, asset tag, fake supervision leftovers, and keypad caches in one step.

5. **`CSStore2` Millisecond Container Mapper & Cross-Container Modules (`v0.8.x – v0.9.0`)**
   - **`CSStore2` (`bdsl`) Fast Container Engine**: Parses LaunchServices `.csstore` databases (with iOS 26.3.x bookmark TLV fallback and bounded `pathleak` fallback for high-inode devices) to map all app, plugin, and App Group containers in milliseconds.
   - **App & Game Save Manager (`AppDataBackupView`)**: Back up, export, and restore `Documents` + `Library/Preferences` `.zip` archives across app reinstalls (auto-resolving new container UUIDs), or jump straight into the lossless Plist/Text editor.
   - **Container Cache Cleaner (`CacheCleanerView`)**: Rank and clean `Library/Caches` and `tmp` across app containers while protecting user documents and databases.
   - **Battery Health & Thermal Telemetry (`PowerTelemetryView`)**: Zero-lock APFS `clonefile()` snapshot reader for `CurrentPowerlog.PLSQL` (`RawMaxCapacity`, cycle count, real-time wattage, cell temperature, thermal throttling history).
   - **Crash & Jetsam Analyzer (`CrashDiagnosticsView`)**: Inspect and clean `osanalytics` `.ips` crash, Jetsam (`298`), and watchdog (`210`) reports.
   - **App Group Hub & Safari Bookmarks Exporter (`AppGroupHubView`)**: Export Safari bookmarks (HTML / JSON) and generate Surge `.sgmodule` / Stash `.stoverride` routing rules.
   - **Voice Memos & Call Recording Extractor (`VoiceMemosAIView`)**: Batch-export lossless `.m4a` recordings titled via `CloudRecordings.db` and inspect on-device AI/speech model caches.

---

## Compatibility

> [!IMPORTANT]
> Always create a full computer backup before modifying system files. Use at your own risk on devices you own.

- **iOS / iPadOS 27.0 – 27.2.1 & 27.3 beta 1**: Full support (including `MobileGestalt` read/write and `CacheData` slot unlocks).
- **iOS / iPadOS 26.0 – 26.7.2**: Partial support (PosterBoard wallpapers, Keypad themes, Lock Screen footnote, container browser, and read-only diagnostics; iOS 26 sandbox blocks writing to `com.apple.MobileGestalt.plist`).

---

## Installation & Sideloading

> [!WARNING]
> Erosion requires at least one valid `App Group` entitlement injected by your signing tool. Sign and install using **SideStore, AltStore, Feather, Sideloadly, Impactor, iLoader**, or a paid Apple Developer certificate with an App Group enabled.

1. Download the latest `Erosion_v0.9.1_Bilingual.ipa` from [Releases](https://github.com/Kianuni/Erosion-CN/releases/latest).
2. Sideload with any signing tool that preserves/injects an `App Group` entitlement (check the Home log on first launch to confirm `(wq) Active App Group:` is non-empty).
3. If your device is not already in English, Erosion will automatically switch to English; you can also toggle languages manually at any time under **Settings (gear icon) → App Language**.

---

## Credits & License

- Upstream project: **[jailbreakdotparty/Erosion](https://github.com/jailbreakdotparty/Erosion)** (`lunginspector`, `forcequit`, `0xjohnny`, `Skadz`, `rooootdev`, `neonmodder123`)
- Exploit: **[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)**
- References & Special Thanks: `huamidev (GestaltX)`, `kolbicz (WQFiles)`, `KirbySD`, `PoomSmart (MGKeys)`
- Licensed under **[GPLv3](./LICENSE)**.
