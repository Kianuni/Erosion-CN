# Erosion-CN 改进详情与版本历史

> 本文档收录 Erosion-CN 相对上游的完整技术改进说明（原 README「项目简介与核心改进」章节）。各版本发布说明另见 [Releases](https://github.com/Kianuni/Erosion-CN/releases)。

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

