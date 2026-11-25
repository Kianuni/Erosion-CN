# Erosion-CN 改进详情与版本历史 / Changelog & Technical Improvements

> **[简体中文](#简体中文) · [English](#english)**  
> 各版本安装包与发布说明另见 [Releases](https://github.com/Kianuni/Erosion-CN/releases)。

---

## 简体中文

> 本文档收录 **Erosion-CN** 相对上游 **[jailbreakdotparty/Erosion](https://github.com/jailbreakdotparty/Erosion)** 的完整技术改进与版本演进历史：

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
14. **设置页生态推荐与内置分流规则同步（`v0.9.2`）**
    - **设置页重构与生态联动**：移除「特别致谢与特性参考」分组，将上游作者与特性参考统一合并至「致谢与开源参考」；同时新增「更多开源项目 (Kianuni)」推荐卡片，集中展示 `AppleFlow`、`WQGuard`、`Camlo`、`Enkard` 四个同系列开源项目（同步完整中英双语翻译）；
    - **内置分流导出同步 `AppleFlow v1.0.1`**：补齐 PCC 盲签名关键域名 `*.issuer.apple.com` 与 `ropes.apple.com`（消除内置导出规则下相册高质量消除报 `Code=32033`），并收窄过宽的 `google.com` / `googleapis.com` / `gstatic.com` 后缀，替换为 `lens.google.com`、`gemini.google.com`、`chatgpt.livekit.cloud`、`sora.com` 与 `claudeusercontent.com` 等精准生产域名。
15. **文件管理全能增强、APFS 零空间暂存舱、缓存极速清理与 `iOS 27.3` / `LiveContainer` 环境守卫（`v1.0.0`）**
    - **APFS `clonefile()` 零空间应用换签 / 重装暂存舱 (`APFSStagingVault` / `APFSStagingSheet`)**：参考 `yangokok886 / WCMigrate`（GPLv3）思路重构内核级写时复制（CoW）暂存与五重防呆护栏：
      1. **签名证书到期门控**：解析 `embedded.mobileprovision` 剩余有效期，不足 24 小时或已过期时发出高优预警，提示先在 SideStore / AltStore 刷新签名后再暂存卸载；
      2. **10 秒活跃 SQLite WAL 写入锁检测**：暂存与还原前扫描 `Documents` / `Library`（深度 ≤ 4）中最近 10 秒写入的 `*-wal` / `*.sqlite-wal` / `*.db-wal` 文件并拦截提示先上滑关闭目标应用；
      3. **只克隆不移动协议**：调用 `Darwin` `clonefile()` 暂存 `Documents`、`Library/Application Support` 与 `Library/Preferences`（绝不删除或改动源容器），并自动探测微信 32 位十六进制 MD5 账号目录数量；
      4. **`manifest.json` 完整性校验**：记录子目录、文件数、逻辑字节数与来源 Bundle ID，写后核验克隆项数一致才标记为就绪；
      5. **原子 `.erosion_pre_restore_bak` 交换回滚 + 跨 Bundle ID 适配 + 暂存舱保留**：还原时先迁移目标旧目录至 `.erosion_pre_restore_bak` 再从暂存舱 `clonefile()` 写入（保持暂存舱副本不删除），跨 Bundle ID 自动复制适配 `Library/Preferences/<sourceBID>.plist` → `<targetBID>.plist`，异常自动回滚，完成后展示 Keychain 重新登录与验证后手动点击「释放暂存舱」引导（主页同步常驻防误删横幅），全过程保持屏幕常亮。
    - **Wi-Fi 局域网 HTTP 文件传输 (`WiFiShareServer` / `WiFiShareSheet`)**：基于 `Network.framework` (`NWListener`) 构建轻量局域网服务（优先 8080 端口，支持随机可用端口回退与 `en0` IPv4 自动获取），默认开启 HTTP Basic Auth（用户名 `erosion` + 每轮随机 6 位 PIN）、暗黑响应式网页端、64 KB 分块下载、文件夹 `.zip` 打包下载（上限 2 GB）、`PUT /api/upload` 64 KB 流式直写 `.part` 零内存堆积上传及重名非破坏性自动顺延（`name 2.ext`），关闭弹窗或切入后台自动停服并释放防息屏锁。
    - **文件夹深度递归搜索、最大 100 文件分析、最近访问与路径直达 (`FolderAnalysisSheet` / `FMNavigationStore`)**：支持可取消异步深层搜索（实时扫描计数、最多 500 条结果，支持点击打开详情或跳转父目录）、`fstatat` 极速统计 Top 100 最大常规文件、记录最近打开的 15 个非根目录（带一键清空）以及自动识别剪贴板 `/var/` / `/private/var/` 路径的「路径直达」。
    - **POSIX 文件权限编辑器 (`InfoViewer`)**：仅对用户应用容器内部子路径与 App Group 数据子路径（严格封锁容器根目录、`SystemGroup`、`Bundle`、`Daemon`、`System` 与非 `mobile` 属主路径）开放可视化 `chmod` 修改，提供一键「设为只读（0555/0444 锁死本地开屏缓存广告）」、一键「恢复默认读写（0755/0644）」与 `r/w/x` 独立开关及 `lstat` 写后核验。
    - **容器缓存清理提速与选择菜单升级 (`CacheCleanerView`)**：切换扫描队列至 `.userInitiated` QoS，加入单轮 `deniedContainers` 拒绝缓存、POSIX `opendir` / `readdir` / `fstatat` 无桥接高速字节统计、实时进度与「停止」按钮；全选栏升级为「选择」菜单（`全选当前` / `反选当前` / `清空已选`，其中清空覆盖搜索过滤隐藏项）。
    - **`iOS 27.3 beta 2+` 漏洞封堵哨兵、`27.3 beta 1` 国行策略提醒与 `LiveContainer` 环境只读诊断 (`DeviceInfoHelpers` / `WorseQuerySwift` / `ContentView` / `ErosionApp` / `GestaltView`)**：
      - 保持应用正常启动不强退，精确识别 `iOS 27.3 beta 1`（`24C503*`）与已封堵 `worse_query` 的 `iOS 27.3 beta 2+`（`24C504*`+ / `26.7.3+`），在主页顶部与授权报错中给出中英双语提示（最高支持 `27.3 beta 1`，推荐 `27.2.1`），并在 `27.3 beta 1` 的 `MobileGestalt` 准入区新增 `eligibilityd` 国行策略本地拦截只读提醒；
      - 新增只读 `LiveContainer`（`LC_HOME_PATH` 环境变量）环境识别：当运行于 `LiveContainer` 内且遭遇容器授权失败时，在主页卡片、启动日志与授权错误中明确提示用户在 LiveContainer 应用设置中检查宿主 App Group 配置或改为独立侧载安装。
    - **开源致谢增补**：新增感谢 `kolbicz / WQFiles` 与 `yangokok886 / WCMigrate`（GPLv3）。
16. **APFS 换包内置分步使用说明、存档卡片单行排版优化与指南同步（`v1.0.1`）**
    - **内置交互式双语换包指南 (`APFSVaultGuideSheet`)**：在「应用与游戏存档管理」顶部栏、APFS 暂存舱简介卡片下方以及暂存舱管理台右上角同步加入 `? 使用说明` 入口，清晰拆解「APFS 极速暂存 vs `.zip` 存档备份」适用场景、同应用掉签重装标准 6 步、官微 ↔ 多开微信跨包搬家 4 步以及三条防翻车红线；
    - **修复存档卡片快捷按钮三行折行问题 (`AppDataBackupView`)**：将每条容器卡片底部的目录跳转按钮精简为单行防截断标签（「文档目录 / `Documents`」、「偏好配置 / `Preferences`」、「完整目录 / `Full Container`」），彻底消除 `修改 Docume / nts` 异常折行；
    - **同步扩充 [`USAGE_GUIDE.md`](./USAGE_GUIDE.md)**：补齐 `iOS 27.3 beta 2` 封堵说明及 `v1.0.0 – v1.0.1` 全新模块（APFS 换包、Wi-Fi 互传、POSIX 权限修改、深层搜索/百大文件与缓存清理）图文操作说明。
17. **开屏广告缓存精准定位锁死与 Wi-Fi 互传认证/浏览器体验优化（`v1.0.2`）**
    - **开屏广告缓存精准锁死 (`AdCacheBlockerView` / `AdFolderLocateBrowserView`)**：在 `功能修改 → 应用存档与空间清理` 与 `文件浏览 → 快捷访问` 同步加入 **「开屏广告缓存精准锁死」** 专页，结合主流 App 已知开屏路径与 `Documents` / `Library/Caches` / `Library/Application Support` / `tmp` 浅层 POSIX 扫描精准匹配 `KSAdSDK`、`BUAdSDK`/`Pangle`、`GDTMobSDK`/`TADCache`、`BaiduMobAd`、`SplashAd`、`LaunchAd` 等广告目录（严格排除 `SplashBoard`、WebKit、Cookies、`Downloads`、容器根目录与符号链接），提供一键 **`定位目录`**、清空物料后 **`一键锁死 (0555)`**、**`恢复读写 (0755)`**、单应用/全局批量操作及未命中容器人工排查开关；
    - **Wi-Fi 无线互传认证兼容、浏览器排查指引与按钮排版修复 (`WiFiShareServer` / `WiFiShareSheet`)**：
      - `WiFiShareEngine.isAuthorized` 放宽用户名校验为大小写不敏感的 `erosion` 或直接留空（仍严格要求 6 位随机 PIN 恒定时间校验），解决浏览器输完密码仍反复弹窗的问题；
      - 优化 `WiFiShareSheet` 中「复制 / 复制密码」按钮为紧凑胶囊排版（不再拉伸过长，并新增用户名一键复制），同时加入 **「浏览器打开说明」** 卡片，推荐优先使用 **Safari**、说明 Mac 上 Chrome/Edge/Arc **「本地网络」** 权限开启步骤、`http://` 协议提醒及前台保活规则。
18. **开屏广告锁死能力全面加固、AppGroup/配置文件扫描、自定义收藏与边界指引（`v1.0.3`）**
    - **防重建占位锁 (`.erosion_adlock` `0444` + 目录 `0555`)**：锁死广告目录清空物料后，自动在目录内写入 0 字节 `0444` 只读占位文件 `.erosion_adlock` 再将目录锁死为 `0555`，防止部分 SDK 在可写父目录下通过 `removeItem` 删空目录并重建；恢复读写 (`0755`) 时自动清除占位文件，且兼容识别旧版空 `0555` 目录一键 **「加固防重建」**；
    - **`AppGroup` 共享容器扫描与单文件广告配置锁死**：拓展扫描 `/var/mobile/Containers/Shared/AppGroup`（自动屏蔽系统组与代理工具共享组），同时精准匹配 `splash_ad.json`、`splash_ad.plist`、`launch_ad.*` 等常见广告配置文件，支持页面内直连 `PlistViewer`/`TextViewer` **预览内容**，并支持原地写入最小合法空 JSON/Plist 后锁定为 `0444`；
    - **自定义广告路径收藏 (`AdCustomWatchStore`)**：支持在「开屏广告缓存精准锁死」右上角 **`+`** 手动校验添加路径，或在 `文件浏览` 长按任意合规目录/配置文件点击 **「加入广告锁死列表」**（严格拦截系统目录、容器根目录、`Downloads`、符号链接与主偏好 plist）；
    - **新增「生效边界与搭配建议」独立卡片**：在去广告页面明确提示本地锁死只拦截素材落盘而广告网络请求仍在，推荐搭配代理工具（Surge / Quantumult X / Loon / Stash / Shadowrocket 等）去广告规则屏蔽网络请求，双管齐下实现精准拦截。
19. **「自定义锁屏壁纸」冷启动零阻塞与 Camlo 引导、去广告概览卡片排版修复（`v1.0.4`）**
    - **修复 iPad / 新装设备打开「自定义锁屏壁纸」白屏卡死的问题（`PosterBoardView`，感谢 [@iiichika](https://github.com/iiichika) 在 #51 的详细排查）**：取消 `isReady` 对整页内容、`.tendies` 壁纸包列表及底部/菜单导入按钮的阻塞，页面打开即刻可用；`com.apple.PosterBoard` 容器定位改为后台异步执行，顶部仅展示非阻塞进度/重试状态条，点击「应用」或前往「壁纸设置」时均可随时触发「重新定位」；
    - **加入同系列动态锁屏工坊「Camlo · 开幕」引导卡片 (`PosterBoardView`)**：在「自定义锁屏壁纸」页顶展示 `Camlo · 开幕` 中英双语推荐卡片，支持免电脑将相册视频与实况照片制作成上滑揭幕变身、裸眼 3D 景深动态锁屏（含 385+ 款云端与馆藏壁纸及 `.tendies` 导出），并提供 GitHub 直达与 SideStore / AltStore / Feather 一键订阅/复制软件源入口；
    - **修复去广告「防重建精准锁死概览」卡片水平溢出显示不全（`AdCacheBlockerView`，感谢 [@wvcq6xxvkj-star](https://github.com/wvcq6xxvkj-star) 在 #52 的反馈）**：重构概览卡片与条目操作栏布局，移除导致宽度撑破的 `.fixedSize()` 按钮约束，将 `一键全锁 (N)` 升级为卡片内全宽醒目按钮，并在单条广告路径操作栏引入 `ViewThatFits` 自适应换行，彻底解决小屏、放大显示或大字体模式下卡片左右裁切的问题。
20. **修复容器缓存「一键清理已选」不生效、详情页只读状态提示与定位高亮（`v1.0.5`）**
    - **修复「容器缓存清理」页面点击「一键清理已选」不生效（`CacheCleanerView`，感谢 [@KindLin99](https://github.com/KindLin99) 在 #53 反馈）**：由于 SwiftUI `List` 同一单元格内未显式指定 `.buttonStyle` 的多个按钮会触发点击串台，点「一键清理已选」时会先执行前面的「重新扫描」把已选列表清空导致无响应。现已将「重新扫描」明确限定为 `.borderless`，将「一键清理已选」升级为独立全宽 `.borderedProminent` 按钮并在弹窗前锁定目标快照；同时移除列表行内嵌 `NavigationLink` 避免抢占行内按钮热区；
    - **缓存清理防重建锁保护与写后实测刷新（`CacheCleanerView`）**：扫描与清理时统一扫描深度（`Library/Caches` 深 7 层、`tmp` 深 6 层），显式跳过包含 `.erosion_adlock` 的防重建锁死目录避免干扰去广告锁定，并在清理后按磁盘剩余实际体积保留残留项或移除已清空项、明确报告容器写授权失败原因；
    - **文件详情页 `InfoViewer` 只读/防重建状态直观提示与安全联动**：当目录/文件已处于 `0555` / `0444` 只读状态时，属性区新增 `.erosion_adlock` 防重建保护标识，并将「设为只读」按钮自动置灰显示「✓ 当前已是只读锁死 / 防重建锁死状态」（同理「恢复默认读写」与「应用权限」也会在无变更时置灰，且在详情页恢复可写时同步清理 `.erosion_adlock`）；
    - **去广告「定位」高亮自动居中滚动（`FileBrowserView` / `AdCacheBlockerView`）**：从「开屏广告缓存精准锁死」点击「定位」打开上级目录时，自动将目标广告目录/文件高亮显示并滚动居中止步定位，并优化锁死前内核属性探测授权顺序。
21. **去广告应用/路径通用白名单、淘宝开屏目录内置识别与 iPhone 15+ 电池循环原生提示（`v1.0.6`）**
    - **通用「应用 / 路径白名单」与手动管理面板（`AdWhitelistStore` / `AdWhitelistManagerSheet`，感谢 [@appleoner](https://github.com/appleoner) 在 #56 提出）**：在「开屏广告缓存精准锁死」新增顶部/概览卡白名单管理入口，支持按 `Bundle ID` / `AppGroup ID`（可从本机已装容器快速点选或手动输入）及具体目录/文件路径添加白名单（亦可在页面内按容器菜单 / 单条「加白」或「文件浏览」长按添加/移出）；白名单目标自动跳过顶部「一键全锁 / 全部锁死」，并在新加入白名单时自动恢复原可读写权限与清除 `.erosion_adlock`；首次初始化默认内置 `什么值得买` (`com.smzdm.client.ios`) 防闪退保护规则且支持随时手动移出；
    - **内置手机淘宝开屏启动图与配置路径识别（`AdCacheBlockerView`，感谢 [@guestwrt](https://github.com/guestwrt) 在 #56 实测反馈）**：新增 `com.taobao.taobao4iphone` 专属 `Documents/TBDocuments/bootImagebiz` 与 `Documents/TBDocuments/bootImageDoc` 扫描词条，支持一键防重建锁死（`0555`/`0444`）或随时恢复；
    - **iPhone 15 系列及以上电池循环与生产日期原生支持提示（`GestaltHelpers` / `GestaltView`，感谢 [@guestwrt](https://github.com/guestwrt) 在 #55 反馈）**：在 `MobileGestalt` 实验开关中识别原生已在系统「设置 → 电池 → 电池健康」显示电池循环次数与生产日期的 iPhone 15 全系列及更新机型与新款 M2/M4+ iPad，自动标注无需开启并锁定防误改（若先前曾开启则会提示建议关闭）。
22. **扩充主流应用内置开屏广告路径与 iOS Bundle ID 精准适配（`v1.0.7`）**
    - 感谢 [@oooasis](https://github.com/oooasis) 与 [@itmubai](https://github.com/itmubai) 在 [#58](https://github.com/Kianuni/Erosion-CN/issues/58) 实测分享，在 `AdCacheBlockerView` 内置词典新增 7 款常用 App 的精准开屏/广告缓存路径（均仅针对对应应用容器生效，不包含通用 WebView/网络框架缓存，随时支持一键恢复读写或加白）：
      - **淘宝 (`com.taobao.taobao4iphone`)**：补充 `Documents/TBDocuments/bootImagesDoc`（同时兼容 `bootImageDoc` 与 `bootImagesDoc`）；
      - **京东 (`com.360buy.jdmobile`)**：修正 iOS App Store 官方 Bundle ID 识别并新增 `Library/Caches/startADImage`；
      - **大众点评 (`com.dianping.dpscope`)**：新增 `Documents/splashes_new`；
      - **中国移动 (`cn.10086.app`)**：新增 `Library/DownloadCenter`；
      - **腾讯视频 (`com.tencent.live4iphone`)**：新增 `Library/Caches/QAD/PreloadImageAdOrderCache`、`QADWatchHistoryAdCache`、`maxViewAdCacheFolderName`、`Library/Caches/TAD/PushAdPendantCache` 与 `TADCache`；
      - **番茄小说 (`com.dragon.read`)**：新增 `Documents/TTAdSplashSimpleCache`；
      - **携程旅行 (`ctrip.com` / `ctrip.wireless`)**：新增 `Library/Caches/LoadingImages`。
    - 同步在 `CSStoreEngine` 与 `AppDataBackupView` 补全上述应用的官方 iOS Bundle ID 中英文友好名称映射。

---

## English

> Complete technical improvements and version history of **Erosion-CN** over upstream **[jailbreakdotparty/Erosion](https://github.com/jailbreakdotparty/Erosion)**:

1. **Fixed Persistent Reboot Reversion (Tweaks Reverting to Stock After Reboot)**
   - Upstream returned `false` by default for `mgWriteAtomically`, causing writes to go through temporary file replacement (`replaceItemAt`) that broke the system cache file's Inode and `_mobilegestalt` POSIX ownership; upstream also injected non-cached key `RegionInfo` (`zHeENZu+wbg7PUprwNwBWg`) on iOS 27, triggering full boot-time cache invalidation.
   - This fork enforces atomic in-place writes, strictly follows the iOS 27 stock cache schema, and maps matching hardware `RegulatoryModelNumber` automatically so edits survive cold reboots.
2. **Fixed Lossy Plist Serialization Causing Camera Black Screen**
   - Upstream `PlistManager` misclassified `CFBoolean` (`<true/>` / `<false/>`) and integral floats (camera zoom factors `1.0`, `2.0`, `5.0`) as `<integer>`, breaking camera preview after editing `MobileGestalt`.
   - Replaced with `CFBooleanGetTypeID()` and `CFNumberIsFloatType()` for exact CoreFoundation type fidelity and **100% lossless pass-through** of unmodified entries.
3. **Zero-Byte-Window In-Place Write Protocol (`pwrite` + Tail `ftruncate` + `F_FULLFSYNC`)**
   - Eliminates `ftruncate(fd, 0)` before writing; overwrites from offset `0` in-place, trims trailing bytes if shorter, and flushes APFS + NAND buffers via `fcntl(fd, F_FULLFSYNC)`.
4. **Pre-Apply Diff Preview + Post-Write Readback Verification & Auto-Rollback**
   - Previews every pending key/hex slot diff (`Before → After`) prior to commit, snapshots `PreApplyGestalt.plist`, reads back and validates binary plist integrity immediately after writing, and rolls back automatically on any mismatch.
5. **Runtime `libMobileGestalt.dylib` Slot Resolution (Zero Hardcoded Offsets)**
   - Scans the live in-memory `/usr/lib/libMobileGestalt.dylib` descriptor table on device to resolve `CacheUUID`, total slot count, and boolean `CacheData` offsets (`green-tea`, `not-green-tea`, `wapi`) dynamically.
   - Enforces strict pre-write gates (`CacheUUID` match, exact `slotCount * 9` byte length, `validity == 1`, zeroed 8-byte padding, zero unrelated byte diffs), locking writes whenever verification fails.
6. **Dual-Vault SHA-256 Factory Backup & One-Tap Factory Restore**
   - Mirrors the unmodified `OriginalGestalt.plist` + `SHA-256` digest across both app sandbox and the system-level vault (`isExcludedFromBackup = true`) so factory backups survive app reinstallation/resigning, alongside external `.plist` import/export and dirty-state detection.
   - **One-Tap Factory Restore** verifies `SHA-256`, `CacheVersion`, `CacheUUID`, `CacheData` length, and kernel `ProductType` while cleaning lock-screen text, asset tags, fake supervision plists, and keypad caches (with OTA Clean Cache Rebuild integration).
7. **Automatic Resigned App Group Detection & High-Risk Soft-Brick Removal**
   - Dynamically discovers resigned `group.*` entitlements via `SecTaskCopyValueForEntitlement` and pure-Swift Mach-O `LC_CODE_SIGNATURE` parsing, and removes/blocks bootloop-prone legacy toggles (regex-sliced iPadOS mode on iPhone, retail fake supervision, non-cached keys).
8. **Hardware Model Tables, iOS 27 AI Guardrails & Browser Fixes**
   - Completed regulatory model tables across iPhone 15 / 16 / 17 / Air / 18 / Duo and M-series iPads; fixed upstream `80%` Charge Limit vs Boot Chime hardware checks and hardcoded `true` custom writes; bundled Clean Up & Handwriting synthesis under Apple Intelligence while guarding `Personal Translator` / `Audio Intelligence` slot conflicts; added Liquid Glass low-power rendering and dynamic `stat()` max-Inode scanning.
9. **App & Game Save Manager + Container Cache Cleaner (`v0.6.0`)**
   - **`AppDataBackupView`**: Scans third-party containers to archive `Documents` and `Library/Preferences` into `.zip` backups, exports/imports via Share Sheet, restores to matching reinstalled Bundle IDs (new container UUIDs), and jumps straight into lossless Plist/text editing.
   - **`CacheCleanerView`**: Reclaims bloated iOS "System Data" by scanning `Library/Caches` and `tmp` across containers for safe single or batch purging while strictly protecting `Documents`, chat databases, and login states.
10. **Live `MGCopyAnswer` Inspector, Apple Intelligence 4-Factor Checkup, Camera/Health Slots & Security Audit (`v0.7.2`)**
    - **`MGInspectorView`**: Read-only 3-way comparison (`MGCopyAnswer` live kernel state vs `OriginalGestalt.plist` vs staged edits) across all `720+` binary `CacheData` slots.
    - **`AppleIntelligenceCheckupCard`**: 1-tap verification and auto-fix for `LL/LL/A` region, matching US regulatory model `Axxxx`, on-device AI eligibility, and live readback (locking conflicting `InternalInstall` toggles on native AI devices).
    - **Binary `CacheData` Hardware Slots**: Added Audio Mix, Spatial Audio Recording, FaceTime Spatial Audio, Responsive Shutter, and Health Hypertension Notifications with native hardware downgrade locks.
    - **24-File Sandbox & File-Handling Hardening**: Fixed `@Binding` mutation bug in `PlistManager`, added read-only `requireWrite: false` tokens, Zip Slip validation, symlink typing, and xattr verification.
11. **Dual-Write Slot Promotion, 14 Hardware Experiments & 6 Cross-Container Modules (`v0.8.0`)**
    - Promoted 14 existing features (Dynamic Island, AOD, Charge Limit, Boot Chime, Crash Detection, PWM, Camera Control, Action Button, Tap to Wake, Stage Manager, etc.) to dual `CacheData + CacheExtra` writes.
    - Added 14 experimental `CacheData` hardware toggles (JP/KR 3-slot Shutter Silence, Dual-Mic Studio Audio, Photographic Styles/Tone Mapping, P3 Stereo Video, Camera Control Capacitance, Battery Cycle/Manufacture Info, Outdoor AOD Brightness, CarPlay Ultra, 120Hz Touch Delivery, AirPods Hearing Health/Aid, Sleep Apnea, Blood Oxygen, Extreme Sports/Daylight, Siri Hub guardrails).
    - Added 6 read-only/cross-container modules: **`CSStore2`** `<50ms` app mapping (`CSStoreEngine`), APFS snapshot **Battery & Thermal Telemetry** (`PowerTelemetryView`), **Jetsam & Crash Log Diagnostics** (`CrashDiagnosticsView`), **Lock-Screen Asset Tag & Fake Supervision Scanner** (`ConfigView`), **AppGroup Routing Export** (`AppGroupHubView`), and **Voice Memos Lossless Extractor + On-Device AI Probe** (`VoiceMemosAIView`).
12. **Region Mode Split (`LL+LL/A` vs `LL` Only), Dirty Baseline Stripping, `iOS 26.3.x` CSStore2 & Surge/Stash Sync (`v0.8.1 – v0.8.6`)**
    - Split region unlock into **Full US (`LL + LL/A`)** vs **`RegionCode LL` Only (preserves `CH/A` & Dual Physical SIM compatibility)**; added clean stripping of leftover `InternalInstall` / `InternalBuild` keys, decoupled FaceTime Spatial Audio vs 4-mic Spatial Recording, fixed high-Inode (>200M) `pathleak` hangs + added TLV `CSStore2` fallback for `iOS 26.3.x`, and supported both Surge `.sgmodule` and Stash `.stoverride` exports.
13. **Single-IPA Full EN/ZH Localization & `Personal Translator (#266)` Auto-Heal (`v0.9.0 – v0.9.1`)**
    - Built complete English + Simplified Chinese localization into one IPA with instant switching in **Settings → App Language** (`Follow System` / `简体中文` / `English`).
    - Fixed `v0.9.1` `#266 = true` / `#178 = false` factory baseline preservation and bidirectional auto-heal on native AI iPhones (iPhone 15 Pro – 18 Pro Max) preventing instant 0-second Clean Up & Camera Siri errors.
14. **Settings Ecosystem Links & `AppleFlow v1.0.1` Routing Sync (`v0.9.2`)**
    - Unified in-app Credits and added a **More Open-Source Projects (Kianuni)** section linking `AppleFlow`, `WQGuard`, `Camlo`, and `Enkard`.
    - Synced built-in routing exports with `AppleFlow v1.0.1` (added `*.issuer.apple.com` and `ropes.apple.com` to prevent PCC `Code=32033`; narrowed broad Google suffixes to targeted production endpoints).
15. **All-in-One File Manager Upgrade, APFS Zero-Space Swap Vault, Fast Cache Cleaner & `iOS 27.3` / `LiveContainer` Guards (`v1.0.0`)**
    - **APFS `clonefile()` Zero-Space App Swap Vault (`APFSStagingVault` / `APFSStagingSheet`)**: Inspired by `yangokok886 / WCMigrate` (GPLv3), delivers CoW staging + 5-layer foolproofing:
      1. `embedded.mobileprovision` signing expiry gate (< 24h/expired high-priority warning before uninstalling);
      2. Active 10-second SQLite WAL lock scan across `Documents` and `Library` (`*-wal` / `*.sqlite-wal` / `*.db-wal`);
      3. Copy-never-move `Darwin.clonefile()` staging for `Documents`, `Library/Application Support`, and `Library/Preferences` + WeChat 32-hex MD5 account folder count detection;
      4. `manifest.json` file-count & byte-size integrity verification;
      5. Atomic `.erosion_pre_restore_bak` swap with auto-rollback, cross-Bundle-ID `.plist` adaptation, Vault retention until verified, `isIdleTimerDisabled = true` while running, and persistent Home uninstall-warning banner.
    - **Wi-Fi HTTP File Sharing (`WiFiShareServer` / `WiFiShareSheet`)**: `NWListener` LAN HTTP server (port `8080` with ephemeral fallback, `en0` IPv4 detection) featuring random 6-digit PIN Basic Auth (`erosion`), dark-mode Web UI, 64 KB chunked downloads, folder `.zip` downloads (2 GB cap), `PUT /api/upload` 64 KB chunked `.part` streaming uploads, collision auto-renaming (`name 2.ext`, never overwrites/deletes), and auto-stop on dismiss or background.
    - **Deep Subfolder Search, Top 100 Largest Files, Recent & Go to Path (`FolderAnalysisSheet` / `FMNavigationStore`)**: Cancellable async recursive search (500-match cap), fast `fstatat` Top 100 regular-file analyzer, 15-entry `Recent` folder history with Clear, and `/var/` / `/private/var/` clipboard-aware `Go to Path…`.
    - **POSIX File/Folder Permission Editor (`InfoViewer`)**: Safe scoped `chmod` UI for user app data and App Group subpaths (strictly blocks container roots, `SystemGroup`, `Bundle`, `Daemon`, `System`, symlinks, and non-`mobile` owners) with one-tap **Read-Only (`0555`/`0444`)**, **Restore Read-Write (`0755`/`0644`)**, custom `u/g/o` toggles, and `lstat` verification.
    - **Fast Cache Cleaner & Selection Menu (`CacheCleanerView`)**: Switched to `.userInitiated` QoS, added per-scan `deniedContainers` skip cache, fast POSIX `opendir`/`readdir`/`fstatat` sizing, live scan progress + **Stop** button, and **Select (`Select All` / `Invert Selection` / `Select None`)** menu (clearing hidden search-filtered rows as well).
    - **`iOS 27.3 beta 2+` Patched Sentinel, `27.3 beta 1` Notice & Read-Only `LiveContainer` Diagnostics (`DeviceInfoHelpers` / `WorseQuerySwift` / `ContentView` / `ErosionApp` / `GestaltView`)**:
      - Distinguishes `27.3 beta 1` (`24C503*`) from `worse_query`-patched `27.3 beta 2+` (`24C504*+` / `26.7.3+`), surfaces clear EN/ZH Home & error diagnostics without force-quitting, and shows a read-only `eligibilityd` CH/A notice on `27.3 beta 1`;
      - Detects read-only `LiveContainer` execution (`LC_HOME_PATH` env var) and displays clear EN/ZH guidance in startup logs, Home alert card, and container authorization failures advising users to check host App Group settings in LiveContainer or install standalone.
    - **Additional Open-Source Credits**: Added GPLv3 acknowledgments for **[kolbicz / WQFiles](https://github.com/kolbicz/WQFiles)** and **[yangokok886 / WCMigrate](https://github.com/yangokok886/WCMigrate)**.
16. **In-App APFS Swap Guide, Card Layout Polish & Updated `USAGE_GUIDE.md` (`v1.0.1`)**
    - **Built-in Bilingual Usage Guide (`APFSVaultGuideSheet`)**: Added `? Guide` / `使用说明` entry points in the Save Manager toolbar, APFS Swap Vault overview card, and `APFSStagingSheet` toolbar covering when to pick APFS Stage vs `.zip` Save Backup, the 6-step same-app re-sign/reinstall workflow, official-to-clone cross-Bundle-ID migration (`com.tencent.xin` → `com.tencent.wx`), and 3 critical safety rules.
    - **Fixed 3-Line Button Text Wrapping (`AppDataBackupView`)**: Refined container card link labels to single-line bilingual buttons (`Documents`, `Preferences`, `Full Container`) with `.lineLimit(1)` and `.minimumScaleFactor(0.85)`.
    - **Expanded [`USAGE_GUIDE.md`](./USAGE_GUIDE.md)**: Added the `iOS 27.3 beta 2` patched alert and complete walkthroughs for all `v1.0.0 – v1.0.1` file management, Wi-Fi sharing, POSIX `chmod`, Cache Cleaner, and APFS Swap Vault features.
17. **Per-App Splash Ad Cache Blocker (`chmod`) & Wi-Fi Sharing Auth / Browser UX Polish (`v1.0.2`)**
    - **Splash Ad Cache Blocker (`AdCacheBlockerView` / `AdFolderLocateBrowserView`)**: Added dedicated entry points in both `Tweaks → App Saves & Cleanup` and `File Browser → Quick Access` (`Splash Ad Cache Blocker`). Combines curated per-app splash ad paths with a shallow POSIX ad-SDK scan across `Documents`, `Library/Caches`, `Library/Application Support`, and `tmp` (`KSAdSDK`, `BUAdSDK`/`Pangle`, `GDTMobSDK`/`TADCache`, `BaiduMobAd`, `SplashAd`, `LaunchAd`, etc.) while strictly excluding `SplashBoard`, WebKit, Cookies, `Downloads`, container roots, and symlinks — offering one-tap **Locate** in File Browser, wipe + **`0555` Read-Only Lock**, **`0755` Restore**, per-app/global batch controls, and a manual inspection toggle for unmatched apps;
    - **Wi-Fi File Sharing Auth Flexibility, Browser Guide & Compact Buttons (`WiFiShareServer` / `WiFiShareSheet`)**:
      - Updated `WiFiShareEngine.isAuthorized` to accept case-insensitive `'erosion'` or a blank username when the 6-digit random PIN matches in constant time, eliminating browser password-prompt loops;
      - Replaced stretched Copy / Copy PIN row buttons with compact `.small` pill buttons (plus a Copy Username button) and added a bilingual **Browser & Connection Tips** section recommending **Safari** first, detailing macOS **Privacy & Security → Local Network** steps for Chrome/Edge/Arc, `http://` usage, and foreground keep-awake behavior.
18. **Splash Ad Blocker Anti-Recreate Hardening, AppGroup & Config File Scan, Custom Watch List & Boundary Guide (`v1.0.3`)**
    - **Anti-Recreate Sentinel Lock (`0555` + `0444` `.erosion_adlock`)**: Locking an ad folder now wipes cached assets, places a 0-byte `0444` sentinel file (`.erosion_adlock`) inside, and sets `0555` on the directory so SDKs cannot wipe and recreate an empty `0555` folder under a writable parent; unlocking cleanly removes the sentinel, and legacy weak `0555` folders show a one-tap **Harden** action;
    - **`Shared/AppGroup` Scanning & Single-File Config Wipe (`0444`) + Inline Preview**: Extends scanning to `/var/mobile/Containers/Shared/AppGroup` (excluding system/proxy tool groups) and recognizes standalone splash ad config files (`splash_ad.json`, `splash_ad.plist`, `launch_ad.*`, etc.) with inline `PlistViewer` / `TextViewer` **Preview** and safe in-place minimal empty overwrite + `0444` locking;
    - **Custom Watch List (`AdCustomWatchStore`)**: Add custom folders/files via the top-right **`+`** button or by long-pressing any eligible item in File Browser → **Add to Ad Blocker** (enforcing strict safety checks against system paths, container roots, `Downloads`, symlinks, and core app preference plists);
    - **In-App Boundary & Network Pairing Card**: Clearly explains that local locking stops disk caching while live ad requests still fire, recommending pairing with proxy ad-blocking rules (Surge / Quantumult X / Loon / Stash / Shadowrocket, etc.) for complete ad blocking.
19. **Non-Blocking Lock-Screen Tweaks Cold Start + Camlo Guide & Ad Blocker Overflow Fix (`v1.0.4`)**
    - **Fixed Blank UI Freeze in Custom Lock Screen Wallpapers on iPad / Fresh Installs (`PosterBoardView`, special thanks to [@iiichika](https://github.com/iiichika) for the root-cause analysis in #51)**: Removed the full-view `isReady` gate so the `.tendies` library and import buttons load instantaneously; `com.apple.PosterBoard` container discovery now runs non-blockingly in the background with an inline status/retry banner and an actionable `Retry Lookup` alert on **Apply**;
    - **Added Built-In `Camlo · 开幕` Dynamic Lock-Screen Companion Card (`PosterBoardView`)**: Introduces our companion on-device dynamic wallpaper studio (~9 MB, swipe-reveal, Live Photo/video & 3D depth lock screens, 385+ free cloud/museum wallpapers, `.tendies` export) with direct GitHub link and one-tap SideStore / AltStore / Feather repo source copy & subscribe menu;
    - **Fixed Horizontal Card Clipping in Splash Ad Blocker Overview & Rows (`AdCacheBlockerView`, thanks to [@wvcq6xxvkj-star](https://github.com/wvcq6xxvkj-star) for reporting #52)**: Removed intrinsic `.fixedSize()` button constraints inside inset-grouped cards, moved `Lock All Pending` to a full-width prominent row button, and added `ViewThatFits` responsive wrapping for per-item action bars across Display Zoom and Larger Text sizes.
20. **Fixed Container Cache Cleaner Batch Button, `InfoViewer` Read-Only State & Ad Locate Highlighting (`v1.0.5`)**
    - **Fixed Unresponsive "Clean Selected" in Container Cache Cleaner (`CacheCleanerView`, thanks to [@KindLin99](https://github.com/KindLin99) for reporting #53)**: SwiftUI `List` cells containing multiple unstyled `.automatic` buttons fire earlier buttons first on tap, causing **Clean Selected** to trigger **Rescan** first and wipe the selection before checking `selectedCount > 0`. Styled **Rescan** as `.borderless`, promoted **Clean Selected** to a full-width `.borderedProminent` button snapshotting targets before prompting, and replaced inline row `NavigationLink` with `.navigationDestination(item:)` to prevent hit-box hijacking;
    - **Ad-Sentinel Protection & Post-Clean Re-Sizing (`CacheCleanerView`)**: Unified scan/clean traversal depths (`Library/Caches` depth `7`, `tmp` depth `6`), skipped `.erosion_adlock` anti-recreate ad folders during cleaning, requested explicit `requireWrite: true` grants, and refreshed remaining bytes cleanly after purge;
    - **Explicit Read-Only & Sentinel State in `InfoViewer`**: Displays an `Anti-Recreate Lock` row when `.erosion_adlock` is present, disables redundant **Set Read-Only** / **Restore Read-Write** / **Apply** buttons when permissions already match (showing `Already Read-Only` / `Read-Only & Sentinel Active`), and removes `.erosion_adlock` cleanly when restoring owner write bits;
    - **Auto-Scroll & Highlight on Ad Locator (`FileBrowserView` / `AdCacheBlockerView`)**: Tapping **Locate** (`定位`) in Splash Ad Blocker highlights the target item in its parent folder and scrolls to center it automatically, with read-only locator grants and container authorization ordered before `lstat` checks.
21. **General Splash Ad Blocker Whitelist, Built-In Taobao `bootImage*` Detection & iPhone 15+ Native Battery Cycle Hint (`v1.0.6`)**
    - **General App/AppGroup & Exact-Path Whitelist (`AdWhitelistStore` / `AdWhitelistManagerSheet`, thanks to [@appleoner](https://github.com/appleoner) for suggesting #56)**: Added a dedicated **Whitelist** manager inside Splash Ad Blocker supporting manual `Bundle ID` / `AppGroup ID` input, quick-picking from installed third-party containers, manual container subpath input, per-app/per-row quick toggle buttons, and File Browser context-menu actions (`Add/Remove Ad Whitelist`). Whitelisted targets are skipped by global **Lock All** and automatically restored to writable permissions (clearing `.erosion_adlock`) when added; includes a removable first-run crash-guard entry for `com.smzdm.client.ios` (`SMZDM`);
    - **Built-In Taobao Splash Boot Paths (`AdCacheBlockerView`, thanks to [@guestwrt](https://github.com/guestwrt) in #56)**: Added `Documents/TBDocuments/bootImagebiz` and `Documents/TBDocuments/bootImageDoc` for `com.taobao.taobao4iphone` (`Taobao`) for one-tap `0555`/`0444` anti-recreate locking and restoration;
    - **Native Battery Cycle & Manufacture Date Guard on iPhone 15+ & Modern iPads (`GestaltHelpers` / `GestaltView`, thanks to [@guestwrt](https://github.com/guestwrt) in #55)**: Detects models that natively show Battery Cycle Count and Manufacture Date in iOS/iPadOS 17.4+ Settings (iPhone 15 series+ and M2/M4+ iPads), locking the legacy-hardware toggle when disabled or advising to turn it off if previously enabled.
22. **Expanded Built-In Splash Ad Blocker Paths & Official iOS Bundle ID Mappings (`v1.0.7`)**
    - **Curated Per-App Splash & Ad Paths (`AdCacheBlockerView`, thanks to [@oooasis](https://github.com/oooasis) and [@itmubai](https://github.com/itmubai) for testing and sharing in [#58](https://github.com/Kianuni/Erosion-CN/issues/58))**: Added verified splash/ad paths strictly scoped to 7 popular app containers (excluding generic WebView/networking caches, with full restore and whitelist support):
      - **Taobao (`com.taobao.taobao4iphone`)**: Added `Documents/TBDocuments/bootImagesDoc` alongside `bootImageDoc` and `bootImagebiz`;
      - **JD (`com.360buy.jdmobile`)**: Corrected the official iOS App Store Bundle ID mapping and added `Library/Caches/startADImage`;
      - **Dianping (`com.dianping.dpscope`)**: Added `Documents/splashes_new`;
      - **China Mobile (`cn.10086.app`)**: Added `Library/DownloadCenter`;
      - **Tencent Video (`com.tencent.live4iphone`)**: Added `Library/Caches/QAD/PreloadImageAdOrderCache`, `QADWatchHistoryAdCache`, `maxViewAdCacheFolderName`, `Library/Caches/TAD/PushAdPendantCache`, and `TADCache`;
      - **Fanqie Novel (`com.dragon.read`)**: Added `Documents/TTAdSplashSimpleCache`;
      - **Trip.com / Ctrip (`ctrip.com` / `ctrip.wireless`)**: Added `Library/Caches/LoadingImages`.
    - **Localized Bundle ID Display Names (`CSStoreEngine` & `AppDataBackupView`)**: Added English and Simplified Chinese display-name mappings for the corrected/new official iOS Bundle IDs above.
