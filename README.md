<div align="center">
  <br>
  <a href="https://github.com/Kianuni/Erosion-CN/releases/latest"><img src="./PreviewIcon.png" alt="App Icon" width="150"></a>
  <br>
  <h1>Erosion-CN</h1>
  <p>基于 <a href="https://github.com/forcequitOS/worse_query">worse_query</a> 的 iOS / iPadOS 系统配置与 MobileGestalt 研究工具箱（中英双语 · 防白苹果安全加固版）</p>
  <p>支持 iOS / iPadOS 27.0 – 27.2 / 27.3 beta 1（完整支持）以及 iOS / iPadOS 26.x（部分支持）。</p>
  <p><strong>简体中文</strong> · <a href="./README_EN.md">English Documentation</a></p>
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
   - **Apple 智能子能力打包与进阶槽位冲突保护**：「启用 Apple 智能开关」自动联动解锁旧机型缺失的相册「消除」(Clean Up) 与备忘录「手写体合成」能力；针对实验性 `Personal Translator` / `Audio Intelligence` 槽位在 iPhone / iPad 上强开会导致 `ModelCatalog` 资产校验断路、使照片「高质量」消除报错的问题，内置自动防呆锁定与一键修复；
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
12. **地区解锁细化、脏环境一键直关、`SiriHub` / 照片「高质量消除」/ 空间音频硬件防呆、`iOS 26/27` 极速容器适配与 `Surge / Stash` 双格式分流（`v0.8.1 – v0.8.6`）**
    - **新增地区修改细化子选项**：在「解除地区限制（国行 AI / 美版 LL/A）」下方提供双模式切换——默认 **「完整美版 LL + LL/A」**（同步映射美版监管型号 `Axxxx`，跨区域受限特性最完整）；可选 **「仅改区域代码 LL（保留 CH/A 后缀与双卡兼容）」**（仅将 `RegionCode` 改为 `LL`，完整保留原机 `CH/A` 销售地区后缀与原厂监管型号，满足基础 Apple 智能准入的同时避免国行双实体卡槽 + eSIM 机型的美版无卡槽型号映射冲突）；
    - **污染基线布尔开关直关加固与多重硬件冲突防呆护栏（`v0.8.2 – v0.8.6`）**：若安装本应用前设备已被其他工具开启 `InternalInstall` / `InternalBuild` 等互斥项（导致 `OriginalGestalt.plist` 记录了脏值 `1`），直接关闭对应开关即可一键从 `CacheExtra` 彻底剥离残留键；针对在 iPhone / iPad 上开启会导致 Siri 无限卡死的 `DeviceSupportsSiriHub` 以及强开会导致**照片「高质量」消除报错**的非原生 `Audio Intelligence` 实验槽位，均已加入自动防呆锁定与一键自愈修复（同时精确保留原生 AI 机型的 `Personal Translator = true` 基线）；同时将 **「FaceTime 空间音频」** 与 **「空间音频录制」** 解耦独立，对非四麦克风旧机型（如 `iPhone 15 Pro` 及更早机型）自动防呆锁定空间音频录制，避免语音备忘录出现无效「录音室」档位；
    - **修复高 Inode 主力机容器扫描卡死与 `iOS 26.3.x` `CSStore2` 秒开适配（`v0.8.6`）**：修复长期使用设备（累计 APFS Inode 破 2 亿）回退 `pathleak` 时扫描上限保护失效导致耗时 5–6 分钟的问题，并新增不依赖结构体偏移的 `CSStore2` 书签 TLV 极速兜底提取，使 `iOS 26.3.x` 与 `iOS 27.x` 均可秒级加载容器列表；
    - **`Surge (.sgmodule)` + `Stash (.stoverride / YAML)` 双格式完整分流导出**：共享组中心支持切换导出 Surge 模块与 Stash 覆写文件（内置 `always-real-ip` / `fake-ip-filter`、Siri 主网关直连、PCC 隐私计算中继、`mask-api.icloud.com` 匿名令牌签发、`app.apple.com` 相册消除网关、OpenAI 及 Google 视觉智能全套置顶规则）。
13. **单包完整中英双语支持与 `Personal Translator (#266)` 基线双向自愈（`v0.9.0 – v0.9.1`）**
    - 单一 IPA 同时内置完整 **简体中文 (`zh-Hans`)** 与 **英文 (`en`)** 语言包：中文系统默认显示简体中文，非中文系统自动切换为英文界面，「设置 → 界面语言」支持 **跟随系统 / 简体中文 / English** 三档实时热切换；
    - **`v0.9.1` 修复原生 AI 机型 `Personal Translator` 槽位 `#266` 误关导致相册云端工具与相机 Siri 0 秒瞬间报错的问题**：锁定 `iPhone 15 Pro` 至 `iPhone 18 Pro Max` 全系原生 AI iPhone 的 `#266 = true`、`#178 = false` 原厂基线（免疫跨版本 OTA 与污染缓存），并新增双向异常检测与「一键配齐 / 修复」自愈还原。

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

1. 前往 [Releases 页面](https://github.com/Kianuni/Erosion-CN/releases/latest) 下载最新的 `Erosion_v0.9.1_Bilingual.ipa`。
2. 使用上述签名工具安装至设备；首次运行可在「主页」日志确认已成功识别 `App Group`。
3. 详细使用说明与原厂状态恢复教程请查阅：
   - 📘 [USAGE_GUIDE.md（安装与使用指南）](./USAGE_GUIDE.md)
   - 🔄 [RESTORE_CHA.md（无损恢复出厂状态指南）](./RESTORE_CHA.md)

---

## 常见问题与排障指南 (FAQ / Q&A)

### Q1：为什么打开了开关，eSIM 还是没生效？或者国行 18 Pro / 18 Pro Max 改完后「添加 eSIM」反而消失了？
请按以下 6 种情况逐一排查：
1. **国行 iPhone 18 Pro / 18 Pro Max（`A3715` / `A3718`）插着双实体卡（或背面副卡）触发基带卡槽冲突（18 系列最常见！）**  
   国行 18 Pro / Pro Max 为特殊的**「正反双实体 SIM 卡槽 + 内置 eSIM」三通道复用硬件**，而美版 `LL/A`（`A3472` / `A3473`）为无卡槽纯 eSIM 机型（国际版也仅正面单卡槽）。若卡托内插着两张实体卡（或插在卡托背面副卡槽）重启，基带检测到卡槽占用冲突会临时隐藏「添加 eSIM」与 `EID`（或导致背面副卡不工作）。  
   ✅ **真机实测 100% 解决与双实体卡共存步骤（「空卡写卡法」）**：
   - ① **先拔出 SIM 卡托（不插任何实体卡，保持空卡状态）**，在 Erosion-CN 开启「解除地区限制」+「解除国行底层限制」点击应用后 **空卡关机冷重启**（注：若在 `27.3 beta 1` 空卡下仍隐藏入口，可先关闭上方地区限制、**仅单开「解除国行底层限制」空卡重启**，「添加 eSIM」必出）；
   - ② 空卡开机连 Wi-Fi（挂外区节点 + 开启飞行模式），扫码把需要的海外 eSIM 全部添加完毕；
   - ③ **插回实体卡策略**：若平时只需 **1 张实体卡 + 多张海外/国内 eSIM**，将实体卡装在卡托**正面（主卡槽）**即可直接共存；若平时还需使用**卡托背面第 2 张实体卡**，写完海外 eSIM 后进 Erosion-CN **单独关闭「解除国行底层限制」（保留上方「解除地区限制」开启，且自 `v0.8.1` 起还可在下方修改模式切换为「仅改区域代码 LL（保留 CH/A 后缀与双卡兼容）」以保留原厂 `CH/A` 与监管型号）**，应用重启后再插回正反双实体卡——背面实体卡即可恢复工作，且已写入芯片的海外 eSIM 依然完整保留、可随时在设置中切换启用！
2. **只点了「注销 (Respring)」，没有「手动关机重启」**  
   「解除国行底层限制」修改的是二进制 `CacheData`（`green-tea` 槽位）。负责蜂窝基带与 eUICC 芯片的守护进程（`CommCenter`、`ctkd`）在注销桌面时**不会重载缓存**，甚至会因新旧区域参数半同步导致「添加 eSIM」入口临时隐藏。**写入后必须手动滑动关机、等待黑屏后再按电源键开机（冷重启）** 才会生效。
3. **只改了 `LL/A`，漏开了「解除国行底层限制 (eSIM / FaceTime 音频)」**  
   常规解锁必须将 **「解除地区限制（国行 AI / 美版 LL/A）」** 与下方的 **「解除国行底层限制 (eSIM / FaceTime 音频)」** **两个开关同时打开**并冷重启；若只改了上方的 `LL/A` 而未解开下方的 `green-tea` 硬件锁，系统校验区域冲突同样会屏蔽 eSIM 菜单。
4. **误开了「机型伪装 (`ProductType`)」或曾用其他改机工具盲改过缓存**  
   原生 AI 机型**严禁修改机型标识符**（如把国行主板 `iPhone19,7` 强改成美版 `iPhone19,3`），否则基带校验失配会导致整个 eSIM 菜单消失。若之前被其他工具改坏，请点击 `MobileGestalt` 右上角 **`⋯` →「清除并重建缓存」** 并重启恢复纯净原厂基线，再重新按需开启开关。
5. **在中国大陆境内扫码添加海外 eSIM 时提示“不支持 / 无法激活”**  
   若「添加 eSIM」按钮已出现，但扫码瞬间被拦截，是系统激活时通过境内基站/定位触发了位置校验。扫码写卡时请开启 **飞行模式 + 连接 Wi-Fi（挂全局海外代理）**（必要时临时关闭 `设置 → 隐私与安全性 → 定位服务 → 系统服务` 中的「蜂窝网络搜索 / 无线局域网与蓝牙」），写卡成功后再恢复正常即可长期双待使用。
6. **老款纯双实体卡槽国行机型的物理硬件限制**  
   仅自带物理 `eUICC` 安全芯片的国行机型（如 **国行 iPhone Air、内置物理 eSIM 的 iPhone 18 系列** 等）支持解锁海外 eSIM 自由扫码；早期**纯双实体 nano-SIM 卡槽且主板物理空焊 `eUICC` 芯片**的常规国行机型属于硬件缺失，开启该开关仅用于解锁 **FaceTime 音频（语音通话）** 与 AI 区域准入，无法凭空生成物理 eSIM 芯片。

### Q2：需要开启「监管模式 (Supervision)」吗？以前别的工具留下的伪监管怎么清理？
* **完全不需要，且严禁在个人零售设备上开启伪监管！** Erosion-CN 的所有解锁均直接安全作用于 `MobileGestalt` 缓存，零监管依赖。
* 许多早期改机工具注入的伪造 `CloudConfigurationDetails.plist` 缺失合法的 MDM 证书链，一旦后续 OTA 升级系统，极易在开机激活向导卡死 **403「远程管理」白屏死锁**。你可随时进入本应用 `功能修改 → 系统配置与监管` 一键体检并安全清除伪监管残留（真实企业/教育 MDM 会被自动识别保护）。

### Q3：满血使用 Apple Intelligence + ChatGPT（同时保留国行普通话「询问来电原因」）怎么设地区和代理规则？
* **系统语言与地区黄金组合**（⚠️ **切勿将系统地区设为「美国」**，否则会丢失中文普通话「询问来电原因」来电筛选！）：
  1. 在 Erosion-CN 开启 **「解除地区限制 (LL / LL/A)」+「解除国行底层限制」** 并冷重启；
  2. `设置 → 通用 → 语言与地区`：**地区改为「台湾」**，首选语言第一项保持 **「简体中文」**；
  3. `设置 → Apple 智能与 Siri`：Siri 语言设为 **「中文（普通话 - 中国大陆）」**（若 ChatGPT 扩展偶发回复繁体，在 `扩展 → ChatGPT` 登录并在自定义指令写一句“始终使用简体中文回答”即可）；
  4. `设置 → [你的名字] → 媒体与购买项目`：**App Store 登录外区账户**（iCloud 主账户可保留国区），否则 Apple 智能菜单可能不出现或无法激活。
* **代理分流规则（Surge / Stash / Loon / Shadowrocket 通用铁律）**：
  1. **Siri 核心域名必须 `DIRECT` 直连 + 真实 IP（严禁走代理或 Fake-IP）**：将 `guzzoni.apple.com`、`*.siri.apple.com`、`dejavu.apple.com`、`sequoia.apple.com`、`*.smoot.apple.com` 设为 `DIRECT`，并在 Surge `[General]` 中把 `guzzoni.apple.com, *.guzzoni.apple.com, *.siri.apple.com` 加入 `skip-proxy` 与 `always-real-ip`（否则 Siri 必报「碰到了一点问题」）；
  2. **仅将 AI 准入、匿名令牌签发与隐私计算中继走低并发干净美区节点**：将 `gspe1-ssl.ls.apple.com`、`mask-api.icloud.com`、`mask.icloud.com`、`mask-h2.icloud.com`、`*.app.apple.com`、`apple-relay.apple.com`、`apple-relay.cloudflare.com`、`apple-relay.fastly-edge.com`、`apple-relay.akamaized.net`、`cp4.cloudflare.com` 及 OpenAI / Google 域名分流至低延迟、低共享并发的**美国节点**（切勿屏蔽 `apple-relay.*` 的 UDP 443 QUIC 流量）；
  3. **关闭冲突重写模块**：硬件级改好 `LL/A` 后，请**关闭** `iRingo / NSRingo` 的「定位」与「Siri」模块，防止 MitM 劫持导致断连；
  4. 💡 **一键导出模块**：可直接在 App 内打开 `功能修改 → [测试特性] 共享组分流规则与书签导出`，一键生成并导出完整配好的 `.sgmodule` 分流模块。

### Q4：Siri 聊天已经正常了，为什么「跑马灯视觉智能 (Visual Intelligence)」、「相机内嵌 SIRI 档位」或图乐园提示不可用？
首先注意 iOS 27 中两套视觉入口的底层架构完全不同：
* **一、机身按键唤起的「跑马灯视觉智能」（日常推荐，支持中文与国区主 iCloud）**：
  1. **系统地区不能停留在「中国大陆」**：前往 `设置 → 通用 → 语言与地区`，将 **「地区」改为「台湾」**（海外版视觉智能绑定 ChatGPT 与 Google 识图，在「中国大陆」地区下会被直接锁死；改「台湾」既能解锁视觉智能，又能保留普通话来电询问）。
  2. **定位准入与 Google / Relay 分流**：每次唤起都会实时请求 `gspe1-ssl.ls.apple.com` 校验所在地，并调用 `apple-relay.*` + OpenAI（左下角提问）以及 **`*.google.com`（右下角 Google 识图）**。请确认上述域名均已分流至**美国节点**，且已**关闭 `iRingo / NSRingo` 的定位与 Siri 模块**。
  3. **端侧模型下载与唤醒方式**：连接 Wi-Fi 充电静置等待端侧视觉模型下载完成（若曾开过国行千问缓存，先关总开关重启后再开）；锁屏或亮屏时**长按**右侧「相机控制」按键（或在控制中心添加「视觉智能」按钮）唤起。
* **二、iOS 27 系统「相机」App 底部轮盘内嵌的 `SIRI` 档位**：
  - 该档位属于新一代对话式 Siri AI (Beta) 的实时多模态会话，**不走 OpenAI/Google，而是强制调用 Apple `GenerativeModels` + `Private Cloud Compute (PCC)`**：
    1. 需主 iCloud 登录**美区 Apple Account** 通过 `Try Siri AI` 候补审核，且在当前 Beta 阶段将系统与 Siri 语言设为 **美式英语 (`en-US`)** 并在 Wi-Fi 下下载完 `INTELLIGENCEFLOW` 模型资产；
    2. 若轮盘已出现 `SIRI` 但切过去 **0 秒瞬间弹窗报错**，请升级至 **`v0.9.1+`** 点击顶部 **「一键配齐 / 修复」** 还原原生 AI 机型的 `Personal Translator (#266) = true` 槽位基线，并确保 PCC 流量走干净美区节点或开启 iCloud 专用代理（Private Relay）。

### Q5：为什么解锁国行限制或开启「将“无线局域网”显示为“Wi-Fi”」后，单应用「不允许联网」不见了？
在 iOS 26/27 中，国行独有的单应用三态联网菜单（`关闭 / 无线局域网 / 无线局域网与蜂窝数据`）同时受底层 `green-tea`（国行硬件门控）与 `wapi`（无线局域网命名与 WAPI 开关）共同控制——因此无论是开启「解除国行底层限制」（解锁 Apple 智能与 FaceTime 音频必需）还是开启「将“无线局域网”显示为“Wi-Fi”」，系统网络权限都会切换为国际版逻辑（仅允许单独关闭单个 App 的「蜂窝数据」，不再提供禁止单应用使用 Wi-Fi 的入口）。如需恢复国行「不允许联网」菜单，关闭对应开关重新应用并重启即可恢复。

### Q6：为什么照片「快速消除」正常，但「高质量消除 / 扩图延伸 / 重构」报错？另外要不要升新测试版？
可根据**报错弹出的速度** 1 秒区分是本地槽位问题还是网络限流问题：
* **情况 A — 点下去「0 秒瞬间报错」（连加载转圈都没有）**：
  - **原因**：原生支持 Apple 智能的 iPhone（`iPhone 15 Pro` 至 `iPhone 18 Pro Max`）原厂 `CacheData` 要求 `Personal Translator`（槽位 `#266`）为 `true`、`Audio Intelligence`（槽位 `#178`）为 `false`。若此前使用 `v0.8.3 – v0.8.5` 误将 `#266` 写成 `false`（或强开了非原生 `#178`），系统 `GenerativeModels / ModelCatalog` 会在本地预检阶段 **0 毫秒直接熔断报错**。
  - **解决**：升级至 **`v0.9.1+`**，进入 `MobileGestalt` 点击顶部体检卡片亮起的 **「一键配齐 / 修复」→「应用」→ 手动关机冷重启** 即可自愈恢复。
* **情况 B — 转圈加载几秒后报错“消除此照片时出错 / 请稍后再试”**：
  - **原因**：「高质量消除 / 扩图 / 重构」需向苹果私有云计算（PCC）申请 RFC 9577 匿名令牌（`mask-api.icloud.com` / `mask.icloud.com` / `mask-h2.icloud.com`）并建立 OHTTP QUIC 连接（`*.app.apple.com`、`apple-relay.*`）。万人共用的机场出口 IP 极易触发苹果令牌端 `429 (Code=1009)` 限流，且开启第三方 VPN 隧道若拦截 QUIC 或漏分流 `mask*.icloud.com` 会导致系统自动挂起 iCloud 专用代理（Private Relay）。
  - **解决**：确保上述域名全部置顶同走支持 UDP/QUIC 的**干净低并发美国节点**（或直接使用系统级 iCloud Private Relay 干净美区出口），等待限流冷却后重试即可。
  - ⚠️ **冷却期内请停止反复重试**：苹果令牌端返回 `retry-after` 后，手机会在本地缓存冷却期，期间每次点击都会被 `privatecloudcomputed` 本地秒拒（日志为 `Code=1009 "Rate-limited for token issuer based on retry-after header"` / `privacyProxyRateLimited`），连续重试或频繁切换节点/出口 IP 反而可能延长冷却。建议停用几小时（或隔天）、重启手机后再只试一次。
* **切勿盲目升级新测试版**：底层 `worse_query` 写入漏洞目前仅确认支持至 **`iOS 27.0 – 27.2.1` 及 `iOS 27.3 beta 1`**（若准备降级/刷机，请务必先在 Erosion 内执行「一键恢复原厂」或「清除并重建缓存」后再刷机）。请关闭系统自动更新，**切勿升级至 `27.3 beta 2` 及后续新测试版**。

### Q7：自签证书 7 天过期、卸载重装 App 会导致修改失效或丢失原厂备份吗？
* **都不会。** 所有修改均以原位覆盖方式持久化保存在系统缓存中，无需后台常驻，证书过期打不开或删除 App **完全不影响已生效的功能**。
* `v0.8.0+` 内置了**应用沙盒 + 系统安全金库 `SHA-256` 双重备份冗余**，即便因证书掉签卸载重装 App，重新打开时也会自动从系统金库无损找回你最初未修改的原厂备份。

### Q8：还有哪些特性属于纯物理硬件或非缓存 (`slot = -1`) 限制，改 `MobileGestalt` 也无法解锁？
* **纯物理硬件限制**：包括 **卫星离网通信与紧急求救**（射频/基带固件锁 + 境内无地面站授权）、**5G 毫米波 (mmWave)**（无毫米波天线模组）、**纯双实体卡槽老机型的 eSIM**（主板空焊 `eUICC` 芯片）、**三麦克风旧机型（`iPhone 15 Pro` 及更早）的空间音频录制 / 语音备忘录「录音室」档位**（物理依赖 iPhone 16 系列起的四麦克风声学阵列，`v0.8.6+` 已自动防呆锁定，仅保留纯软件的 FaceTime 空间音频）以及 **60Hz 屏幕强开 120Hz 刷新率**。
* **非缓存硬件直读键（`slot = -1`）限制 — 旗帜 Emoji 系统原生显示**：国行设备系统字体引擎（`CoreText`）检查的 `RegionalBehaviorGB18030` / `RegionalBehaviorChinaBrick` 在 `libMobileGestalt.dylib` 中均为 **`slot = -1`（非缓存键）**，运行时直接读取只读主板 `SysCfg`（`IODeviceTree:/chosen/software-behavior`）并替换为 `☒`，因此单靠修改 `MobileGestalt.plist` 无法解除系统级原生字体遮罩（⚠️ 切勿将 `slot = -1` 键强行注入 `CacheExtra`，否则会触发开机重置）。但改完 `LL/A` + 非中国大陆地区后，**自带 Emoji 键盘隐藏输入槽位（旗帜第 1 行第 6 列 / 搜索「台湾」）已解锁可打出真实编码**，且内置独立表情图集的 App（如 **X / Twitter、Discord、Telegram 自定义表情包**）可在本机直接彩色显示。

### Q9：点击应用时报 `result: -1` 写入失败，或者「关于本机」已变 `LL/A` 但 AI 菜单仍未出现怎么办？
* **点击应用提示 `worse_query` 授权失败（`result: -1`）**：
  - 说明安装时使用的签名工具（如部分电脑端一键安装器普通模式）**剥离了 `App Group` 共享容器权限**（可在主页日志看到 `Active App Group` 为空）。请改用 **SideStore / AltStore / Feather / Sideloadly / Impactor / iLoader** 等保留或自动注入 `App Group` 权限的工具重新签名安装即可。
* **「关于本机」型号末尾已变 `LL/A`，但设置里还没有海外版 Apple 智能菜单**：
  1. 打开 `MobileGestalt → 真机生效核验探针`，确认第 5 行 **`green-tea` 真机值为 `false (Bool)`**（若仍为 `true`，勾选下方「解除国行底层限制」应用后**手动滑动关机冷重启**）；
  2. 前往 `设置 → 通用 → 语言与地区`，确认 **「地区」已从「中国大陆」改为「台湾」（或「美国」）**（停留在「中国大陆」时，即便是真美版设备也会隐藏海外 AI 入口）；
  3. 连接美国代理节点（确保 `gspe1-ssl.ls.apple.com` 走美区代理），划掉「设置」后台重开（或连着代理重启一次手机）以触发 `eligibilityd` 首次准入刷新（首次激活推荐先用默认「完整美版 `LL + LL/A`」，激活成功后再按需切回「仅改区域代码 `LL`」）；
  4. **App Store（媒体与购买项目）需登录外区账户**：国行设备的 Apple 智能资格还会参考 Apple 账户的国家/地区，App Store 停留在国区账户时 AI 菜单可能不出现或无法完成激活（`设置 → [你的名字] → 媒体与购买项目` 切换为外区账户即可，iCloud 主账户可保留国区；感谢 [#20](https://github.com/Kianuni/Erosion-CN/issues/20) @Chinsin 实测反馈）。

### Q10：万一改出异常，或者之前被别的工具改出「相机黑屏 / eSIM 消失」，怎么一键救回？
* **一直使用 Erosion-CN 修改的用户**：直接点击主页或 `MobileGestalt` 页顶的 **「一键恢复原厂」**，校验 `SHA-256` 后一键还原原厂参数并清空锁屏铭牌/伪监管/拨号盘残留，手动重启即 100% 恢复出厂状态。
* **安装本工具前已被其他工具改坏缓存的用户**：点击 `MobileGestalt` 右上角 **`⋯` →「清除并重建缓存」**，随后立即**手动关机重启手机**——iOS 将在开机时直接从主板硬件熔丝重新生成 100% 纯净的原厂缓存，相机黑屏、eSIM 消失等软故障均可彻底自愈。

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
