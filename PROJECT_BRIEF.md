# DesktopHarvest · 项目简介（Agent 同步用）

> 最后更新：2026-11-07 · 状态：v1.0 + 安全审计修复，53 个单元测试全部通过，0 个 Swift 警告
> 给接手的人 / Agent：动手前请先读完本文的「核心不变量」和「工作约定」两节。

## 1. 项目是什么

**DesktopHarvest（桌面牧场）** 是一个原生 macOS 桌面农场 + 桌宠游戏，以菜单栏程序（`LSUIElement`）的形式运行，没有 Dock 图标。

- 所有游戏对象都是 `~/Desktop/DesktopFarm` 里的真实文件或文件夹，文件图标由程序实时绘制并写回磁盘。
- 桌面图标层之上覆盖一层全屏透明的 SpriteKit 窗口：动物在上面散步，菜园地块、加工机和各种特效也画在这一层。
- 技术栈：Swift 6（strict concurrency 设为 complete）、AppKit、SpriteKit、SwiftUI（`MenuBarExtra`）、CoreServices FSEvents、CryptoKit、ImageIO。不使用任何第三方依赖。
- 部署目标 macOS 14.0；开发环境是 Xcode 27.2 + macOS 27.2，Apple Silicon。

## 2. 构建 / 运行 / 测试

```bash
cd "/Users/furina231013/Project/Desktop Farm"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select 指向的是 CLT，必须加这一行

# 构建
xcodebuild -project DesktopFarm.xcodeproj -scheme DesktopFarm -configuration Debug -derivedDataPath .build/DerivedData build
# 测试（53 个）
xcodebuild -project DesktopFarm.xcodeproj -scheme DesktopFarm -configuration Debug -derivedDataPath .build/DerivedData test

# 安全试玩：用临时目录，不碰真实桌面
DESKTOP_HARVEST_ROOT=/tmp/dh_test/DesktopFarm DESKTOP_HARVEST_SUPPORT=/tmp/dh_test/Support \
  .build/DerivedData/Build/Products/Debug/DesktopHarvest.app/Contents/MacOS/DesktopHarvest
# 退出
pkill -f DesktopHarvest.app
```

- Xcode target / scheme 名仍然叫 `DesktopFarm`，产品名是 `DesktopHarvest.app`，Bundle ID 是 `com.desktopharvest.app`，测试中 `@testable import DesktopHarvest`。
- 工程使用文件夹同步组（`PBXFileSystemSynchronizedRootGroup`）：在 `DesktopFarm/` 或 `DesktopFarmTests/` 下新建 `.swift` 文件会自动加入工程，**不需要修改 pbxproj**。
- 游戏速度存放在 `UserDefaults`（`com.desktopharvest.app`，键名 `dh.speed`，可选 1 / 5 / 20），只在启动时读取。
- 测试宿主启动时会检测到 XCTest 环境并跳过 `bootstrap()`，所以测试永远不会访问真实桌面。

## 3. 目录与模块地图

```text
DesktopFarm/
├── App/          DesktopHarvestApp(@main, MenuBarExtra) · AppDelegate · GameCoordinator(组合根：串联引擎/AI/覆盖层/Finder桥/图标/音效)
├── Model/        ItemCatalog(ItemType 物品、Quality 品质) · PlantCatalog(PlantSpecies 作物与果树) · AnimalMachineCatalog(动物/工具/机器配方/升级)
│                 GameFile(磁盘 JSON 载荷、FolderMarker 文件夹标记) · GameState(SaveGame 存档及其子状态) · Progression(等级曲线、ShopProduct 商品)
├── Security/     ItemSigner — HMAC-SHA256，每台机器一个随机密钥
├── Persistence/  SaveManager — 原子写入 + 一份备份
├── FileSystem/   FarmSandbox(唯一的安全护栏) · FarmFileSystem(所有文件增删改) · FarmScanner(扫描磁盘) · DirectoryWatcher(FSEvents)
├── Engine/       GameEngine(调度与 1 秒 tick；扩展：+Files 文件原语 / +Actions 玩家操作 / +Economy 经济 / +Queries 只读投影)
│                 BotanyHusbandryEngine(植物/动物纯计算) · SmartCrateMonitor(AntiCheat 防作弊、木筐统计、机器配方规划)
│                 EconomyEngine(订单生成与核对) · PetDirector(动物 AI 状态机，15Hz)
├── Rendering/    IconSpec(图标描述，含 majorKey) · IconPainter(CoreGraphics 绘制) · ProceduralIconRenderer
│                 IconWriter(原地写 icns 资源分支) · IconUpdateScheduler(后台线程写入、节流、自愈)
├── Desktop/      DesktopOverlayWindow · DesktopOverlayController(鼠标穿透、拖放、特效分发) · FarmScene · SceneNodes
│                 EffectFactory(粒子/抛物线) · WorldLayout(网格坐标映射) · DesktopIconBridge(Finder AppleScript) · FinderHUDController
├── Audio/        SoundManager — 在内存中合成 WAV 音效
├── Support/      AppSettings(UserDefaults) · Formatters
└── UI/           ControlPanelView(HUD 头部 + 6 个标签页) · FarmTab · InventoryTab · OrdersTab · ShopTab · ShippingTab · SettingsTab · Theme
DesktopFarmTests/ TestSupport(FarmTestCase：每个测试用独立临时目录) · SecurityTests · SimulationTests · EconomyMachineTests · IconWriterTests
                  SandboxHardeningTests · AntiCheatHardeningTests · RecoveryTests · PerformanceGuardTests（审计回归）
Supporting/Info.plist  6 种 UTI(seed/crop/tree/item/pet/tool)、LSUIElement、Apple Events 与桌面文件夹权限说明
```

数据流：磁盘 → `FarmScanner.scan()` → `GameEngine.reconcile()`（防作弊校验 + 登记新文件 + 处理丢失文件 + 同步机器）→ `@Published game/scan/crates` → `onWorldChanged` → 图标调度器 / 覆盖层 / Finder HUD 刷新。
玩法事件走 `engine.events`（类型为 `PassthroughSubject<FarmEvent>`），由 `GameCoordinator` 分发给音效、覆盖层特效和 HUD。

## 4. 核心不变量（不要破坏）

1. **文件安全**：所有删除、改写、重命名、移动操作都必须经过 `FarmSandbox.validateGameFile` / `validateFolder`。要求：解析符号链接后路径严格位于农场根目录内、不是符号链接、后缀属于 `seed|crop|tree|item|pet|tool`、JSON 带 `format == "DesktopHarvest/1"`。**绝不触碰用户自己的文件。** 重置只删除合法的游戏文件和清理后变空的游戏文件夹（有测试覆盖）。
2. **文件表示身份，存档保存状态**：游戏文件里只有 `{format,id,kind,itemType,quality,timestamp,hmacSignature,displayName?}`。水分、生长、饱食度等动态状态都在 `SaveGame` 里，以文件的 UUID 为键。不要频繁改写游戏文件。
3. **签名**：签名内容见 `GameFilePayload.signingMessage`，是 `format|id|kind|itemType|quality|timestamp(%.3f)` 的拼接（`displayName` 不参与签名）。文件夹的 `.desktopharvest` 标记文件同样签名。密钥在 `Application Support/DesktopHarvest/signing.key`。**删除密钥会让所有已有物品失效**（它们会被判为克隆）。
4. **防作弊（`AntiCheat.resolve`）**：签名无效、UUID 已在 `spentIDs` 中、或同一 UUID 有多个副本时，账本里 inode 匹配的那个算真品，其余全部改写为 `WitheredClone_xxxx.item`（价值 0）。Finder 移动文件不改变 inode，所以仍是真品；复制（⌘C/⌘V）会产生新 inode，判为克隆。
5. **图标只能用 `IconWriter` 写**：禁止使用 `NSWorkspace.setIcon`。原因是它会清除自定义图标标记、对文件夹删除并重建 `Icon\r`，导致闪烁和回退到默认文件夹图标（已复现并修复）。`IconWriter` 一次性原地替换 `com.apple.ResourceFork`，只设置、从不清除自定义图标标记；文件夹写完后用 `utimes` 刷新系统图标缓存。
6. **FSEvents 使用 `IgnoreSelf`**：程序自己产生的写入不会触发重新扫描。因此引擎在自己做完文件操作后，必须主动调用 `rescan()` 或 `reconcile()`。
7. **加工机**：原料放进机器文件夹后，凑齐配方就自动开工，原料被移入机器内的隐藏子目录 `.processing/` 锁定；完成后销毁原料，在机器文件夹里生成成品。状态保存在 `MachineState.job`（详见第 10 条）。
8. **文件读取与删除必须有界、锁定身份**：读文件只能用 `SafeFileReader`（`O_NOFOLLOW|O_NONBLOCK` + `fstat` + 大小上限：游戏文件 64KB、文件夹标记 16KB）。删除和重命名只能用 `FarmSandbox.unlinkValidated` / `renameValidated`：先比对 dev+ino，再调用 `unlink(2)` / `renamex_np(RENAME_EXCL)`。清理文件夹只能 `unlink` 文件、`rmdir` 目录。**禁止**对游戏路径使用 `FileManager.removeItem`（它会递归删除目录）。
9. **防复活**：存档里有 `lastSavedAt`。签名合法、但未登记且时间戳落在 `[createdAt, lastSavedAt-5s]` 内的文件判为复活克隆。账本中丢失条目保留 30 天。`rescan()` 只跟随 inode 相同的移动，从不改写 inode。
10. **加工机幂等**：开工时生成 `outputID` 并立即存档。完工顺序：先建成品（已存在就跳过）→ 删除原料并标记为已消费 → 清空任务 → 存档。`recoverMachines()` 在每次 reconcile 时运行，负责归还孤儿或杂散原料、取消原料被拿走的任务、补完已完成但未收尾的任务。
11. **并发**：所有 UI、引擎、AppKit 代码都在 `@MainActor` 上。Timer / FSEvents 回调运行在主线程，用 `MainActor.assumeIsolated` 进入。只有图标的渲染、编码和写入放在后台串行队列（`nonisolated static` 函数，传递的都是 `Sendable` 值）。

## 5. 磁盘布局

```text
~/Desktop/DesktopFarm/                     (DESKTOP_HARVEST_ROOT 可覆盖)
├── AppleTree_XXXX.tree  Chicken_XXXX.pet  WheatSeed_XXXX.seed  💧水壶.tool  Apple_XXXX.item ...
├── 📦果蔬收集筐/  📦牧场副产品筐/        木筐(role=crate)；名字含「筐」或 "crate" 的普通文件夹会自动加上标记
├── 💰出货箱/  📋订单交付箱/  🥣动物食槽/
├── ⚙️果酱加工机/                          机器(role=machine)；内部有 .processing/ 锁定原料
└── 每个受管文件夹内：.desktopharvest(签名的 FolderMarker) + Icon\r(自定义图标)
~/Library/Application Support/DesktopHarvest/   (DESKTOP_HARVEST_SUPPORT 可覆盖)
├── savegame.json  savegame.backup.json  signing.key
```

## 6. 玩法数值在哪里改

- 作物与果树的生长时长、产量、种子价格、解锁等级：`PlantSpecies`（PlantCatalog.swift）
- 物品价格、XP、所属木筐类别：`ItemType`（ItemCatalog.swift）
- 动物食谱、生产周期、饥饿速度：`AnimalSpecies`；机器配方：`MachineType.recipes`（AnimalMachineCatalog.swift）
- 水分阈值、浇水量：`PlantState`（GameState.swift）；洒水器补水速率：`BotanyEngine.sprinklerRate`
- 等级曲线：`Progression`；商店商品：`ShopProduct`；订单：`EconomyEngine`（3 个槽位、6 小时有效期、补单间隔 45 秒、奖励为市价 1.5~1.9 倍）
- 初始金币 120（`SaveGame.startingCoins`）；离线结算上限 72 小时，固定按 1× 速度（`settleOffline`）；生产者（果树、动物）在所在目录散落物品达到 24 个时暂停产出（`GameEngine.looseItemCap`）
- 图标节流：普通外观变化每 3 秒最多刷新一次，运转中的机器每 1 秒刷新一次（`IconUpdateScheduler`）

## 7. 已验证 / 未验证

**已验证**：Debug 与 Release 构建通过；27 个测试全部通过；在临时目录做过启动冒烟测试，确认了以下行为：
- 新手农场正常生成；
- 实时克隆检测生效；
- 重启后离线结算正常；
- 20× 速度下文件夹的 `Icon\r` inode 始终不变、自定义图标从不丢失；
- 加工机能完整跑完一个任务。

验证文件图标是否生效，用的是系统图标接口 `NSWorkspace.icon(forFile:)` 读取后检查像素颜色。

**未验证（当前环境没有屏幕录制权限，看不到画面）**：
- 桌面 SpriteKit 层的实际观感；
- 鼠标穿透是否准确；
- 从 Finder 拖放文件到精灵上；
- Finder 图标坐标对齐（`DesktopIconBridge` 中的标题栏高度 52/28、侧边栏宽度是估算值）；
- 多显示器；
- 音效是否真的能听到。

## 8. 已知问题 / 待办

- 完整的安全/一致性/性能审计（14 项）见 Agent 产出的 `audit_report.md`，已全部修复。

- 用户反馈过「树图标闪烁」：已经针对 Finder 文件图标做了修复（第 4 节第 5 条），**等待用户确认**。如果仍然闪烁，需要区分是 Finder 窗口里的文件图标在闪，还是桌面菜园里的 `PlotNode` 在闪。
- Finder 窗口滚动后，HUD 叠加层的坐标会偏移。
- 桌面菜园固定排在主屏幕左下角，最多 9 列（`WorldLayout`）。
- 程序是 ad-hoc 签名，没有 App Sandbox，没有公证。
- 用户的旧农场里有几个文件夹曾丢失图标，新版本启动时会自动补画（调度器每一轮都会检查磁盘上的图标）。

## 9. 工作约定

- **禁止**留下 stub、`TODO` 或省略号式的代码；修改后必须跑完整的 `xcodebuild test`，并保持 0 个 Swift 警告。
- 新测试继承 `FarmTestCase`（自带临时根目录和固定签名密钥），用 `makeEngine()` 创建引擎（不启动 Timer 和 Watcher）。
- 在 Agent 环境里访问 `~/Desktop` 会触发系统权限弹窗而卡住，**请用 `DESKTOP_HARVEST_ROOT` 指向 `/tmp`** 来复现问题。
- 运行后台进程前先 `pkill -f DesktopHarvest.app`，避免两个实例同时操作同一个目录。
- 调试脚本放在 Agent 的 scratch 目录：`monitor.py`（采样图标重写次数和丢失情况）、`seticon_probe.swift`（观察 setIcon 行为）、`iconwriter_probe.swift`（验证 IconWriter 写入）。
- 旧版 v0.1 的完整备份：`~/.gemini/antigravity/brain/eaa58a64-ce21-45ef-b071-b8b736592a15/scratch/backup_original/`
