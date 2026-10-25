# LightTable 交接说明

修改代码前先读本文件和 `docs/plans/2026-10-25-lighttable-design.md`。设计文档的「决策」表是产品约束的唯一来源；本文件记录实现状态、代码地图、验证结果和待办。

## 1. 产品约束（摘要）

- 给不懂技术的人用：拖入文件夹 → 扫描汇总 → 按素材预勾 → 开始。技术细节只出现在「高级」和「详情」里
- 固定顺序：增稳调色 → 挑高光 → 拍摄习惯 → 照片分组
  - 不能先剪再增稳：passthrough 剪切会丢掉 Sony `rtmd` 陀螺仪轨（2026-10-25 用 C0835.MP4 实测）
  - 拍摄习惯必须在照片分组之前：照片分组会写入主题关键字
- LUT 按画面类型分组，每次都让使用者选；只标出该组「上次用的」，不自动套用
- 原片像素不动。照片分组会写 JPEG/HEIC 元数据和 RAW 的 `.xmp`（TravelCut 既有行为），关键字仍放在 `TravelCut|` 命名空间
- Gyroflow 不打包，App 检测并引导安装官网版；App Store 版不能用
- 只用 Apple Silicon，macOS 14+；临时签名

## 2. 代码地图

| 模块 | 内容 |
|---|---|
| `Sources/LightTableKit` | `SupervisedProcess`（子进程管理）、`ProcessRegistry`（残留进程）、`Tools`（ffmpeg/ffprobe/exiftool 定位）、`MediaScanner`（陀螺仪轨、机型、画面类型、带时区拍摄时间）、`AppPaths` |
| `Sources/TravelCutCore` | TravelCut 0.8.0 核心，视频高光与照片分组。迁入后只改了：模型和 Geo 目录（`AppPaths`）、exiftool 查找、资源包名、`JobConfiguration.inputFiles/captureDates/originalSources`、`HighlightRecovery.canResume/isUsed`、`ModelStatus`、`ZeroShotClassifier`（MobileCLIP 公开接口） |
| `Sources/Stabilize` | batch-gyroflow 的 Swift 改写：`Gyroflow.check`、`StabilizeEngine`、`StabilizeCommands`（无 I/O 的命令构建）、`LUTPreview`、`对照表.json` |
| `Sources/Habits` | photo-habits 的 Swift 改写：`HabitsEngine`、exiftool 扫描与缓存、统计、HTML 报告、MobileCLIP 题材分类 |
| `Sources/LightTableApp` | SwiftUI：`AppModel`（状态与流水线）、首页、方案页、选色调、进度、结果、菜单栏；`Snapshot`（开发用离屏快照与自动运行） |
| `Sources/LightTableCLI` | `lighttable-cli`：scan / tools / gyroflow / stabilize / highlights / photos / habits |
| `Sources/LightTableSelfTest` | 自测：kit / stabilize / habits，可单独跑 |
| `Sources/TravelCutSelfTest` | 迁入的 TravelCut 自测 |
| `reference/` | 三个旧工具的原始代码与 README，改写时的对照基准，不参与构建 |
| `scripts/` | `build-ffmpeg-lgpl.sh`、`build-app.sh` |

## 3. 关键实现事实

### 子进程

- 所有外部程序都经过 `SupervisedProcess`：`posix_spawn` 自成进程组，状态只认 `waitpid`
- 启动时重置信号处理（`SETSIGDEF` + 空信号掩码）。父进程忽略的信号会被子进程继承，不重置就只能靠 SIGKILL 结束
- 父进程退出 0.5 秒后管道仍被占用，就对整个进程组发 SIGKILL，防止孙进程继续写马上要校验的文件
- `stop()` 必定返回：SIGTERM → 5 秒 → SIGKILL → 3 秒 → 报告无法结束的 PID
- 子进程 PID 记在 `~/Library/Application Support/LightTable/running-processes.json`。启动时核对 PID 和可执行文件路径，防止 PID 复用导致误杀

### 增稳调色

- Gyroflow 退出码不可信：成功 = 文件存在且 ffprobe 时长与原片相差不到 1 秒
- 先写隐藏的临时文件，校验后改名；续跑只跳过校验过的正式文件，LUT 失败时复用完整的 ProRes 中间文件
- Gyroflow 1.6.3 实测：
  - 保留 UTC 创建时间，丢掉时区和 Sony XML
  - ProRes 中间文件把 full range 转成 limited 并标为 tv/bt709
  - 套 LUT 时优先读中间文件自己的标记，缺的才用原片标记（修掉了 batch-gyroflow README 记录的 200→188 电平偏移）
- 套 LUT 后成片标为 bt709 limited；10 位原片输出 HEVC Main10；只用 VideoToolbox
- 一次只处理一段（`settings.jobs` 被忽略），「跳过这段 / 再等等」永远指向唯一的当前片段
- 卡住判定：max(120 秒, 4 倍预计渲染时间)无输出且临时文件不增长
- 每段开始前检查空间（成片 + 中间文件 + 200 MB）和源盘、输出盘是否还在；不满足就暂停等 `resume()`

### 挑高光

- App 传入明确的文件清单：增稳过的用成片，其余用原片
- 拍摄时间取扫描阶段读到的带时区值（Sony XML `CreationDateValue`），原片和成片都用它分天
- `selection.json` 的 `originalSourceFile` 记录成片对应的原片
- 输出文件夹 `LightTable 高光`；有可续跑的检查点就续跑，否则用第一个未被占用的 `LightTable 高光 N`
- 资源包名是 `LightTable_TravelCutCore.bundle`；名字不对时 MobileCLIP 文字提示词会失效，主题判断悄悄退化

### 拍摄习惯

- 关闭看图分类（`--content meta`）时与 `reference/photo_habits.py` 逐项一致：3,709 个表格单元格、55 行带数字的句子、4,498 个单张字段，覆盖全部和 6 个题材视图
- 忽略 `TravelCut|` 关键字及其末级（照片分组写的「自然景观」里的「自然」会被算成风景）
- MobileCLIP 替换 open_clip；「其他」阈值 0.45（photo-habits 是 0.40），只在 115 张 macOS 示例图上校准过
- 缓存在 `<文件夹>/.lighttable-cache/`，文件夹只读时放 `~/Library/Caches/LightTable/Habits/`

### 打包

- `Contents/Helpers/` 只放 Mach-O：`llama/`、`ffmpeg/`、`lighttable-cli`
- `Contents/Resources/exiftool/`：exiftool 脚本 + Perl 库，用系统 `/usr/bin/perl` 运行
- `Contents/Resources/Licenses/`：llama.cpp 与 ffmpeg 的许可和版本说明
- 先逐个签内层二进制，再签 App；不用 `--deep`
- ffmpeg 7.1.1 静态 LGPL 版：源码 SHA-256 已对照 FFmpeg 发布密钥签名核实；只依赖系统框架
- 只有 Command Line Tools 时 SwiftUI 的 `@State` 宏不可用，界面状态一律用 `@StateObject` 小对象
- `swift build --show-bin-path` 在输出重定向到文件时会报 I/O 错误；看构建日志用 `| cat > log`

## 4. 构建与测试

```bash
swift build --disable-sandbox
swift run --disable-sandbox lighttable-selftest              # 全部；可加 kit / stabilize / habits
LIGHTTABLE_SKIP_REAL=1 swift run --disable-sandbox lighttable-selftest stabilize   # 跳过真实片段
swift run --disable-sandbox travelcut-selftest
./scripts/build-ffmpeg-lgpl.sh                               # 一次性，产出 vendor/ffmpeg
./scripts/build-app.sh 2>&1 | cat > /tmp/build.log           # dist/LightTable.app
dist/LightTable.app/Contents/Helpers/lighttable-cli tools    # 确认用的是打包的工具
```

并行开发时每人用自己的 `--scratch-path .build-<名字>`，避免抢同一个构建目录。

界面检查（不需要窗口和截屏权限）：

```bash
LIGHTTABLE_SNAPSHOT=/tmp/snap LIGHTTABLE_SNAPSHOT_FOLDER=<素材文件夹> \
LIGHTTABLE_SNAPSHOT_LUTS=<LUT 文件夹> [LIGHTTABLE_SNAPSHOT_AUTORUN=1] .build/debug/LightTable
```

`AUTORUN` 会用 App 自己的流水线代码把四项任务全跑一遍（照片分组默认试运行），打印每项结果。

## 5. 验证状态（2026-10-25）

| 项 | 结果 |
|---|---|
| LightTable 自测 | 6,129 项全过（kit 32、stabilize 128、habits 5,969） |
| TravelCut 自测 | 全过 |
| 子进程异常 | 正常退出、静默卡死、忽略 SIGTERM、孙进程占管道、外部杀掉、整组停止、硬超时，都有测试 |
| C0835.MP4 扫描 | ZV-E10、S-Log2、`rtmd`、`-08:00` 均识别正确，打包的 ffprobe/exiftool 也一致 |
| C0835.MP4 增稳 + LUT | HEVC 4K，bt709 tv，AAC，时区写回 `-08:00`，无残留临时文件；沙盒里 Gyroflow 只能用 CPU，约 25–30 秒 |
| 增稳 → 挑高光 | 成片进入挑高光，按相机时区分到 `D1_1026_周日/001_1410_…`，`selection.json` 记录原片；MobileCLIP 与 Qwen 从 App 包内正常运行 |
| App 流水线 | 自动运行四项：增稳、挑高光、照片分组成功；拍摄习惯在没有相机照片时显示跳过原因 |
| 界面 | 离屏快照检查了首页、方案、选色调（含真实缩略图）、进度（含卡住提示）、结果 |
| 打包 | `codesign --verify --strict` 通过；arm64；macOS 14.0 |

## 6. 未验证与待办

- 真窗口里的交互（拖放、弹窗、菜单栏、关窗后继续）还没人手动点过；沙盒里不能启动图形界面
- 真实照片上的拍摄习惯报告和 MobileCLIP 阈值（本机能访问的位置没有相机照片）
- 10 位、带陀螺仪数据的原片只增稳不调色时，Gyroflow 是否保留 10 位
- 时间估算按 CPU 粗估（Gyroflow 2 倍实时、LUT 1.5 倍），需在正常 App（GPU）里校准
- 松下 V-Log 的识别：读不到时归「未识别」，由使用者按机型归组
- 公开发布：Developer ID 签名与公证、MobileCLIP 权重许可（仅研究用途）复核、随附 LGPL 源码声明
- GitHub：仓库 `nightfade/LightTable` 尚未创建；三个旧仓库的归档说明尚未添加（都要先问使用者）
