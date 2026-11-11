<div align="center">
  <br>
  <a href="https://github.com/Kianuni/Erosion-CN/releases/latest"><img src="./PreviewIcon.png" alt="App Icon" width="150"></a>
  <br>
  <h1>Erosion-CN</h1>
  <p>基于 <a href="https://github.com/forcequitOS/worse_query">worse_query</a> 的 iOS / iPadOS 系统配置与 MobileGestalt 研究工具箱（简体中文防白苹果安全加固版）</p>
  <p>支持 iOS / iPadOS 27.0 – 27.2 / 27.3 beta 1（完整支持）以及 iOS / iPadOS 26.x（部分支持）。</p>
  <a href="https://github.com/Kianuni/Erosion-CN/releases/latest"><img alt="GitHub Releases" src="https://img.shields.io/github/v/release/Kianuni/Erosion-CN?style=flat-square&color=CF7D46&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC"></a>
  <a href="https://github.com/jailbreakdotparty/Erosion"><img alt="Upstream Repo" src="https://img.shields.io/badge/%E4%B8%8A%E6%B8%B8%E4%BB%93%E5%BA%93-jailbreakdotparty%2FErosion-3868DB?style=flat-square"></a>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue?style=flat-square"></a>
</div>

---

## 项目简介与核心改进

**Erosion-CN** 分支衍生自官方上游项目 **[jailbreakdotparty/Erosion](https://github.com/jailbreakdotparty/Erosion)**，完成了 **100% 简体中文界面本地化**，修复了原版多项严重真机 Bug，并进行了系统级防白苹果安全加固与底层能力扩展：

1. **修复重启后修改自动失效还原（反弹回原厂状态）的严重 Bug**
   - 原版在未手动切换过设置开关时，`mgWriteAtomically` 默认返回 `false`，导致实际走了临时文件替换（`replaceItemAt`），破坏了系统缓存文件的 Inode 与 `_mobilegestalt` POSIX 属主权限，设备一重启即被系统丢弃重建；同时原版在 iOS 27 上额外注入了非缓存键 `RegionInfo`（`zHeENZu+wbg7PUprwNwBWg`），触发开机缓存合法性校验整包重置。
   - 本分支已默认强制锁定原位覆盖写入，严格遵循 iOS 27 原厂缓存键结构，并自动匹配写入对应机型的监管型号（`RegulatoryModelNumber`），**真正做到持久化生效、重启不反弹**。
2. **修复内置 Plist 编辑器破坏布尔值与相机浮点参数导致「相机黑屏」的严重 Bug**
   - 原版 `PlistManager` 将 `CFBoolean`（`<true/>` / `<false/>`）以及整数值 `Double`（如相机变焦倍率 `1.0`、`2.0`、`5.0` 等）误判转换为了 `<integer>` 整型，导致编辑保存 `MobileGestalt` 后系统相机取景直接黑屏。
   - 本分支改用 `CFBooleanGetTypeID()` 与 `CFNumberIsFloatType()` 精确识别底层 CoreFoundation 类型，保留原始 Plist 根类型与编码格式，并对未修改项执行 **100% 原样无损直通（Lossless Pass-through）**，彻底解决相机黑屏问题。
3. **零 0 字节窗口原位写入协议（`pwrite` + 按需尾截断 + `F_FULLFSYNC`）**
   - 重构底层文件 I/O：不再先执行 `ftruncate(fd, 0)` 清空系统文件，而是直接从偏移 `0` 原位覆盖写入、写完后按需裁剪尾部，并调用 `fcntl(fd, F_FULLFSYNC)` 强制刷新 APFS 与物理闪存缓存，断电或异常中断绝不留空文件。
4. **写入前变更对比预览（Diff Preview）+ 写后全量读回校验与自动回滚**
   - 点击「应用」时逐条展示所有待修改键值与十六进制槽位对比（`修改前 → 修改后`）；
   - 写入前自动保存 `PreApplyGestalt.plist` 快照，写入后立即从磁盘读回并做二进制 Plist 反序列化与严格类型校验，一旦出现任何不一致立即自动原位回滚。
5. **本机 `libMobileGestalt.dylib` 运行时动态偏移解析（零硬编码）**
   - 在设备运行时只读扫描内存中加载的 `/usr/lib/libMobileGestalt.dylib` 查询描述符表，实时计算当前机型与当前系统版本的 `CacheUUID`、总槽位数及布尔槽位偏移（`green-tea`、`not-green-tea`、`wapi`）；
   - **严格多重校验门控**：仅当本机 `CacheUUID` 唯一匹配、总长度精确等于 `槽位数 × 9`、有效位 `validity == 1`、8 字节槽位填充全为 `0` 且无任何无关字节变动时才允许修改；解析未通过时自动锁定开关并拦截写入。
6. **双重原厂金库备份（跨卸载重装不丢备份）、四重指纹防呆与一键恢复原机出厂参数**
   - **沙盒 + 系统安全金库双冗余备份**：生成原始备份 `OriginalGestalt.plist` 时同步计算 `SHA-256` 摘要并镜像锁定至系统级共享容器安全金库（标记 `isExcludedFromBackup = true` 防换机污染）——**即使侧载证书过期卸载重装应用，也能自动无损找回最初未修改的原厂备份**，并支持手动导入/导出外部 `.plist` 备份及首次备份脏状态检测；
   - **全模块一键恢复原机出厂参数**：主页与 `MobileGestalt` 页顶均内置「一键恢复原机出厂参数」，强制核对 `SHA-256`、`CacheVersion`、`CacheUUID`、`CacheData` 长度与真实内核硬件 `ProductType`，同步清空本地自定义开关残留、锁屏文字/铭牌、伪监管文件与拨号盘缓存；跨 iOS 版本 OTA 升级拦截时可直接一键联动「重建系统纯净原厂缓存」。
7. **重签证书 `App Group` 自动探测与高危软砖项拆除**
   - 运行时通过 `SecTaskCopyValueForEntitlement` 与纯 Swift Mach-O `LC_CODE_SIGNATURE` 签名段解析自动匹配任意重签工具注入的可用 `group.*` 容器；
   - 默认移除并拦截上游版本中存在软砖/无限设置向导隐患的高危功能（如 iPhone 正则盲改切片的 iPadOS 模式、个人零售设备的监管模式开关、非缓存键注入等）。
8. **完善机型适配、iOS 27 进阶 AI 能力解锁与实用工具优化**
   - 补全 iPhone 15 / 16 / 17 / Air / 18 / Duo 全系列及 M 系列 iPad 监管型号映射与硬件特征表，修复原版“80% 充电上限”与“开机提示音”硬件判断互换笔误及自定义键值恒写入 `true` 的 Bug；
   - **Apple 智能子能力打包与 iOS 27 进阶 AI 解锁**：「启用 Apple 智能开关」自动联动解锁旧机型缺失的相册「消除」(Clean Up) 与备忘录「手写体合成」能力；常驻展示 **「解锁 iOS 27 进阶 AI 能力 [测试特性]」** 开关，实时检测本机系统库与原厂 `CacheData` 槽位状态，按需解锁**个人实时翻译 (`Personal Translator`)** 与 **iOS 27 音频智能 (`Audio Intelligence`)**（原厂已开启机型自动显示原生锁定保护，早期 `27.0` 未内置槽位的固件也会明确标注）；
   - 新增 iOS 26/27「液态玻璃低功耗渲染（省电模式）」开关与机型外层描述同步；
   - 修复文件浏览器搜索栏失效与失焦清空问题，采用 `stat()` 动态探测本机实时最大 Inode 基线配合 `pathleak` 加速容器扫描（并为动态壁纸与拨号盘页面加入异步加载进度动画），同时新增核心缓存目录 0 秒一键直达入口；
9. **新增应用存档管理与容器缓存清理模块（`v0.6.0`）**
   - **应用与游戏存档备份、还原与修改器 (`AppDataBackupView`)**：自动扫描本机第三方应用与单机游戏容器，支持一键将 `Documents` 与 `Library/Preferences` 打包备份为 `.zip`、导出分享、跨重装自动匹配最新容器 UUID 原位还原存档，并支持一键跳入存档目录调用内置无损 Plist/文本编辑器修改；
   - **容器级缓存扫描与清理 (`CacheCleanerView`)**：专治 iOS「系统数据（其他）」暴涨，按体积排行展示各应用容器的 `Library/Caches` 与 `tmp` 可释放空间，支持单应用或批量一键清理（严格保护 `Documents`、聊天记录数据库与登录态）。
10. **新增真机底层生效核验探针、Apple 智能四要素一键体检、影像/健康硬件槽位解锁与全链路沙盒审计加固（`v0.7.2`）**
    - **真机 `MobileGestalt` 底层生效核验与动态槽位实时探针 (`MGInspectorView`)**：纯只读调用系统库 `MGCopyAnswer` 实时读取当前真机生效值，并与 `OriginalGestalt.plist` 原厂备份、当前 `CacheData / CacheExtra` 待写配置进行三源同屏对比；同时提供本机全量 `720+` 个二进制 `CacheData` 槽位的动态解析检索与自由键名实时探针；
    - **Apple 智能 (Apple Intelligence) 激活四要素一键体检面板 (`AppleIntelligenceCheckupCard`)**：实时聚合核验「销售地区 `LL/LL/A`」、「美版监管型号 `Axxxx`（基于真实主板型号防伪装误判）」、「端侧 AI 芯片准入」及「系统实时生效回读」，并在原生 AI 机型上自动锁定 `InternalInstall` 互斥开关，支持一键自动配齐全部缺失项；
    - **影像与健康进阶能力解锁（`CacheData` 二进制硬件槽位直写）**：针对 `libMobileGestalt.dylib` 中 `_MGCacheSetValueForKey` 的 `validity` 短路机制（仅写 `CacheExtra` 会被系统直接忽略的硬件设备树属性），通过运行时动态槽位解析直接写入 `CacheData`，新增 **相册与相机「混音 (Audio Mix)」**、**空间音频录制与 FaceTime 空间音频**、**按下快门瞬间抓拍 (Responsive Shutter)** 与 **健康「高血压趋势评估模式」** 4 项开关，并内置本机原生硬件防降级保护锁；
    - **全链路沙盒逃逸与文件编辑安全加固（`v0.7.2`）**：修复内置 Plist 编辑器因 `@Binding` 原地变异导致保存回旧值的 Bug；重构 `WorseQuerySwift` 支持只读容器令牌保留（`requireWrite: false`），修复 `System` / `AppGroup` 容器浏览、容器排序重复扫描、符号链接类型识别、壁纸与拨号盘父容器授权、存档备份还原 xattr 核验与 Zip Slip 防护等 24 个文件的边界缺陷。
11. **全量 `MobileGestalt` 槽位双写晋升、14 项底层硬件实验开关与 6 大跨容器系统模块（`v0.8.0` 测试特性）**
    - **14 项既有功能晋升 `CacheData + CacheExtra` 全量双写**：将灵动岛、全天候显示、液态玻璃低功耗渲染、80% 充电上限、开机提示音、车祸检测、PWM 防频闪、相机控制键、操作按钮、轻点唤醒、台前调度等 14 项既有功能全面纳入运行时 `CacheData` 槽位双写表，彻底突破 `_MGCacheSetValueForKey` 槽位短路；
    - **新增 14 项 `[测试特性]` 二进制 `CacheData` 硬件特性包**（均经真机 `libMobileGestalt.dylib` 校验 `slot >= 0, queryType == 11` 且带原生硬件防降级锁）：日韩版真·相机快门静音（3 槽联动）、高低功耗双麦并发拾音（录音棚叠录底座）、相册局部光影重绘与新一代色调映射、超取景框捕获与 P3 广色域立体声视频、相机控制电容滑动变焦与触觉阻尼完整面板、旧机型显示电池循环次数与生产日期、户外高亮全天候显示与 Flipbook 帧缓冲、CarPlay Ultra 多屏车载协议、120Hz 触控采样事件投递、AirPods 临床听力均衡与低功耗助听器模式（3 槽联动）、睡眠呼吸暂停风险趋势检测、解除美版血氧软件专利限制、户外极限运动模式与日光照射监测、端侧 Siri Hub 路由与指令模型动态剪枝，并附「国行普通话来电询问 + 海外 Apple 智能」共存配置指南；
    - **6 大跳出 `MobileGestalt` 的跨容器实验模块（`[测试特性]`）**：
      1. **`CSStore2` 极速容器与中文应用名映射引擎 (`CSStoreResolver` / `CSStoreEngine`)**：解析 LaunchServices `"bdsl"` 二进制数据库，`<50ms` 秒级映射全部应用容器与 AppGroup UUID（自动降级回退 `pathleak`）；
      2. **物理电池真实寿命与芯片温控遥测 (`PowerTelemetryView`)**：基于 APFS `clonefile()` 零锁只读快照解析 `CurrentPowerlog.PLSQL`，查看原始毫安时容量 (`RawMaxCapacity`)、精确循环次数、实时充放电瓦数、电芯温度及历史热节流事件；
      3. **系统崩溃与 Jetsam 杀后台分析器 (`CrashDiagnosticsView`)**：解析 `osanalytics` `.ips` 诊断日志，分类统计内存强杀 (`298`)、进程崩溃 (`309`) 与看门狗重置 (`210`)，支持安全清理日志释放空间；
      4. **锁屏防丢资产铭牌与伪监管死锁体检 (`ConfigView`)**：支持 `AssetTagInformation` 锁屏铭牌定制，并实时体检第三方伪监管残留（防 OTA 升级后触发 Setup Assistant 403 激活死锁，支持保留锁屏文字单独清理）；
      5. **跨容器 `AppGroup` 分流规则注入与 Safari 书签导出 (`AppGroupHubView`)**：一键生成或向 Surge 共享组注入国行普通话来电询问直连 + 海外 AI 分流 `.sgmodule`，并支持通过零锁快照无损导出 Safari 书签（HTML / JSON）；
      6. **语音备忘录与通话录音无损提取 + 端侧 AI 模型体检 (`VoiceMemosAIView`)**：跨容器关联 `CloudRecordings.db` 标题批量打包导出无损 `.m4a` 音轨，并只读探测离线翻译与语音模型缓存。

---

## 系统兼容性

> [!IMPORTANT]
> 操作前请务必通过电脑完整备份设备重要数据！修改系统底层配置存在潜在风险，仅供安全研究与学习交流，请仅在本人持有的设备上使用并自行承担风险。

- **iOS / iPadOS 27.0 – 27.2.1**、**27.3 beta 1**（完整支持所有功能，包括 `MobileGestalt` 读取与安全写入）
- **iOS / iPadOS 26.0 – 26.7.2**（部分支持：可使用锁屏壁纸、拨号键盘美化、锁屏底部签名文字与部分容器浏览；受底层沙盒限制，iOS 26 不支持写入系统 `MobileGestalt`）

---

## 安装与签名要求

> [!WARNING]
> 本项目底层依赖至少一个有效的 `App Group` 容器权限。请使用支持保留或注入 App Group 的个人 Apple ID 自签工具（如 **SideStore / AltStore / Feather / Sideloadly / Impactor / iLoader**）或带 App Group 权限的开发者证书签名安装。

1. 前往 [Releases 页面](https://github.com/Kianuni/Erosion-CN/releases/latest) 下载最新的 `Erosion_v0.8.0_zh-Hans.ipa`。
2. 使用上述签名工具安装至设备；首次运行可在「主页」日志确认已成功识别 `App Group`。
3. 详细使用说明与原厂状态恢复教程请查阅：
   - 📘 [USAGE_GUIDE.md（安装与使用指南）](./USAGE_GUIDE.md)
   - 🔄 [RESTORE_CHA.md（无损恢复出厂状态指南）](./RESTORE_CHA.md)

---

## 自行编译

在安装有 Xcode 26 / 27 的 macOS 环境中克隆本仓库并执行构建脚本即可生成未签名 `.ipa`（已自动内嵌标准 entitlements）：

```bash
git clone https://github.com/Kianuni/Erosion-CN.git
cd Erosion-CN
chmod +x ipabuild.sh
./ipabuild.sh
```

---

## 致谢与开源许可 (Credits & License)

本项目基于 **[GNU General Public License v3.0 (GPLv3)](./LICENSE)** 开源，谨向上游作者与社区研究者致以诚挚感谢：

### 特别致谢（特性借鉴与研究参考）
- **[huamidev / GestaltX](https://github.com/huamidev/GestaltX)** — 特别感谢 `GestaltX` 项目的优秀工程设计与思路启发，本分支的本机 `libMobileGestalt.dylib` 查询描述符动态偏移解析、变更对比预览（Diff Preview）、写后磁盘读回校验、运行时重签 `App Group` 自动探测以及液态玻璃低功耗渲染键值等改进均借鉴并参考了 `GestaltX` 的设计。
- **[KirbySD](https://www.v2ex.com/t/1246550)** — 感谢分享 `MobileGestalt` 二进制 `CacheData` 中 `green-tea` / `not-green-tea` 布尔槽位的原始研究思路。
- **[PoomSmart / MGKeys](https://github.com/PoomSmart/MGKeys)** — 感谢长期维护与整理 `MobileGestalt` 混淆键值映射表。
- **[kolbicz / WQFiles](https://github.com/kolbicz/WQFiles)** — 感谢分享 LaunchServices `.csstore` (`"bdsl"`) 容器图谱解析研究思路（GPLv3）。

### 上游主项目与漏洞研究致谢
- **[jailbreakdotparty / Erosion](https://github.com/jailbreakdotparty/Erosion)** & **[lunginspector](https://github.com/lunginspector)** — 上游主仓库与核心架构作者
- **[forcequitOS](https://github.com/forcequitOS)** & **[0xjohnnydev](https://github.com/0xjohnnydev)** — `worse_query` 沙盒研究作者
- **[skadz108](https://github.com/skadz108)** & **[rooootdev](https://github.com/rooootdev)** — 后端功能组件维护者
- **[neonmodder123](https://github.com/neonmodder123)** — 免越狱注销方案作者

---

## 免责声明

本项目仅供 iOS 系统安全研究、逆向工程学习与技术交流使用。请严格遵守所在地法律法规与电信合规要求，切勿用于任何非法用途；开发者不对因使用本软件造成的任何数据丢失、功能异常或售后问题承担责任。
