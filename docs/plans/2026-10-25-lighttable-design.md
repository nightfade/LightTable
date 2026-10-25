# LightTable 设计

LightTable（看片台）是一个 Mac 原生 App，合并 TravelCut、batch-gyroflow、photo-habits 三个工具，让不懂技术的人拖入一个文件夹就能完成拍摄后的整理。

## 决策

| 项 | 决定 |
|---|---|
| 使用者 | 先给自己和家人用（临时签名、首次右键打开），架构上为公开发布留余地 |
| 代码 | 新仓库 `nightfade/LightTable`，TravelCut 的 Swift 代码迁入，两个 Python 工具改写成 Swift；三个旧仓库在功能覆盖后归档 |
| 平台 | Apple Silicon，macOS 14+ |
| 首页 | 从文件夹出发：拖入 → 扫描汇总 → 按素材预勾可做的事 → 开始；另有单独使用某个工具的入口 |
| 视频顺序 | 先增稳调色，再从成片里挑高光。不先剪：passthrough 剪切会丢掉陀螺仪轨（见备查） |
| Gyroflow | 不打包。App 检测、识别 App Store 版、引导安装官网版 |
| LUT | 按画面类型分组，每组各自选；每次都让使用者选，只标出该组上次用的，不自动套用；LUT 文件夹第一次使用时自己选 |
| 拍摄习惯报告 | 自包含 HTML，用浏览器打开 |
| 开发位置 | `~/Github/LightTable` |

## 1. 结构与首页

### 模块（一个 Swift Package）

| 模块 | 内容 | 来源 |
|---|---|---|
| `LightTableKit` | 素材扫描、外部工具调用与进程管理、任务进度、取消与断点、空间预检、模型下载 | 从 TravelCut 抽出 |
| `Highlights` | 视频高光 | TravelCut 视频模式 |
| `PhotoGroups` | 照片整理 | TravelCut 照片模式 |
| `Stabilize` | 增稳调色 | batch-gyroflow 改写 |
| `Habits` | 拍摄习惯 | photo-habits 改写 |
| `LightTableApp` | SwiftUI 界面 | 新写 |
| `lighttable-cli` | 命令行入口，调试与测试用 | 合并现有 CLI |

### 首页流程

1. 拖入文件夹
2. 扫描汇总，例如：
   - ZV-E10 视频 32 段（可增稳，其中 S-Log2 28 段）
   - iPhone 视频 15 段
   - 照片 1,840 张
3. 列出可做的事，按素材预勾，使用者可改：
   - 有陀螺仪轨的视频：预勾增稳调色
   - 有 Log 视频：增稳调色里默认带上调色
   - 有视频：预勾挑高光
   - 有照片：预勾照片分组
   - 拍摄习惯：默认不勾
4. 点开始，按固定顺序执行：增稳调色 → 挑高光 → 照片分组 → 拍摄习惯
5. 每项结束给「打开结果」：
   - 增稳成片、高光片段：打开文件夹
   - 照片分组：提示去 Bridge 看
   - 拍摄习惯：浏览器打开报告

### 结果位置

都在所选文件夹下，原片不动：

- `LightTable 增稳/`
- `LightTable 高光/`
- `LightTable 拍摄习惯.html`
- `LightTable 日志/`

## 2. 外部工具与模型

| 依赖 | 用途 | 处理 |
|---|---|---|
| ffmpeg / ffprobe | 识别陀螺仪轨和画面类型、套 LUT、预览帧 | 打包进 `Contents/Helpers/`，用 LGPL 编译版，编码走 VideoToolbox |
| exiftool | 照片写元数据、读 Sony XML | 打包，用系统 Perl 运行 |
| llama.cpp | Qwen 推理 | 沿用 TravelCut 打包方式 |
| Gyroflow | 增稳 | 使用者安装，App 检测与引导 |
| Qwen3-VL-4B（约 2.95 GB） | 高光深度判断、照片标签（可选） | 首次用到时下载，断点续传 |
| MobileCLIP-S2（约 199 MB） | 高光初筛、照片主题、拍摄习惯题材 | 同上，三功能共用 |
| GeoNames（约 14 MB） | 照片地点 | 同上 |

- 模型放 `~/Library/Application Support/LightTable/Models/`。TravelCut 已下载过的同名模型直接搬过来，不重新下载
- 拍摄习惯读 EXIF 优先用 ImageIO（含 RAW），读不到的层级关键词、`.xmp` 星级交给 exiftool

### Gyroflow 检测（每次增稳前）

1. 查找 `/Applications/Gyroflow.app` 及常见位置
2. 读签名权限，含 App Store 沙盒则提示换官网版
3. 运行 `--version` 确认可调用
4. 未安装时增稳选项显示「需要先装 Gyroflow」，点开是图示安装说明和官网链接；回到 App 自动重新检测

### 风险

- macOS 自带 Perl 被标记为将来移除；移除时需连 Perl 一起打包
- LGPL 版 ffmpeg 需自行编译或找可信预编译版本，一次性工作

## 3. 增稳调色

### 单段流程

| 情况 | 流程 |
|---|---|
| 只增稳 | Gyroflow → 成片 |
| 增稳 + 调色 | Gyroflow → ProRes 中间文件 → ffmpeg 套 LUT → 成片 |
| 只调色 | ffmpeg 套 LUT → 成片 |

- 套 LUT 前转 `yuv444p16le`，避免色带
- 原片的色彩范围、色彩空间、原色、传输特性标记照抄到成片
- LUT 失败时保留 ProRes 中间文件，只重跑套 LUT

### 沿用 batch-gyroflow 已验证的 Gyroflow 命令行处理

- 退出码不可信，只认成片文件是否存在
- 渲染写到 `.tmp`，失败、超时、停止时清理
- preset 合并成一个参数传入；新增 preset 键须导出工程文件核对是否生效
- 显式指定输出路径（输出扩展名跟编码走，不跟输入）

### LUT 分组

| 分组 | 识别依据 | 默认 |
|---|---|---|
| S-Log2 / S-Log3 | Sony XML `CaptureGammaEquation`（已验证） | 必须选 LUT |
| V-Log | 未验证；读不到时归「未识别」，按机型记住归组 | 必须选 LUT |
| HLG | ffprobe 传输特性 `arib-std-b67` | 选 LUT 或不调色 |
| 普通 709 | 无特殊标记 | 不调色，可选风格 LUT |
| 未识别 | 读不出 | 使用者归组 |

- 每组缩略图墙用本组的一帧画面预览，沿用 batch-gyroflow 的前后对比分割视图
- 每组标出上次用的 LUT，不自动套用；每组都有「不调色」
- 增稳和调色是两个独立开关；没有陀螺仪轨的视频可以只调色

### 界面

- 露出：增稳开关、调色开关、每组 LUT、最大裁切
- 收进「高级」：编码、码率、并发数、超时、果冻效应校正（默认关，readout time 填错反而更糟）

### 输出与续跑

- `LightTable 增稳/` 下保持原子文件夹结构，文件名不变
- 成片写回原片的带时区创建时间（Gyroflow 只保留 UTC，已实测）；机型与伽马记入 `LightTable 增稳/对照表.json`
- 已完整生成的成片跳过
- 开始前按总时长和分辨率估算耗时和空间，不足则拦截并说明差多少

### 衔接挑高光

- 挑高光的输入：处理过的视频用成片，其余用原片，不重复分析
- `selection.json` 每段记录成片路径和原片路径
- 挑高光沿用 TravelCut 的内容标签、按天分文件夹和命名规则

## 4. 照片的两个功能

### 照片整理

整块沿用 TravelCut 0.8.0 照片模式，行为不变：

- 按连拍分组
- 写组号、主题、地点关键字
- 默认不写星级
- 不改像素，不动使用者的星级和颜色标签

| 开关 | 默认 |
|---|---|
| 用 Qwen 写标签 | 关 |
| 同时写入星级 | 关 |
| 在线查询更精确的地点 | 关，提示会把坐标发给 Apple |
| 试运行 | 关 |

### 拍摄习惯

改写 photo-habits，统计口径不变：

- 去重：RAW + JPEG、多处备份只算一张，优先 RAW
- 默认排除软件导出 JPEG 和手机照片
- 合并 `.xmp` 星级
- 6 类题材：人像、街头、风景、城市建筑、动物、静物；依据依次为关键词 → 目录名 → MobileCLIP → 场景模式
- 长焦、35mm 两个专题

输出：

- 自包含 `LightTable 拍摄习惯.html`，不依赖网络，生成后自动打开
- 页面顶部按题材筛选（对应原 `--category`）
- EXIF 与看图结果缓存在 `.lighttable-cache/`

## 5. 进程管理、出错与进度

### 进程管理

旧版 batch-gyroflow 由网页生成脚本、在终端运行，界面与进程无联系，出现过后台已停但界面不知道、也停不下来。新 App 直接持有每个子进程：

- 运行状态由子进程退出事件驱动，不靠推断
- 每个 Gyroflow、ffmpeg 子进程放进独立进程组，停止时整组结束
- 心跳：进程仍在但 `.tmp` 不增长、也没有新进度输出，超过按时长和分辨率计算的阈值，判定卡住；界面提示并给「跳过这段」「再等等」，无人值守时到阈值自动跳过
- 停止：先 SIGTERM，5 秒后 SIGKILL，再清理 `.tmp`；无论结果，界面都回到「已停止」；杀不掉的进程写明 PID 并提供在活动监视器中查看
- 残局：子进程 PID 记入运行文件；App 崩溃或强退后重开，检查残留并询问是否结束

### 出错

- 每个错误给「发生了什么」和「怎么办」，技术细节放进可展开的详情
- 单个文件失败不中断整批，结果页列出失败项并提供「重试失败的」
- 随时可停，下次从断点继续
- 每次运行写日志到 `LightTable 日志/`；结果页可「导出诊断信息」
- 长任务期间保持唤醒

### 进度

- 总进度：第几项任务、整体百分比、预计剩余时间
- 当前任务：正在处理的文件，例如「增稳 12/32：C0835」
- 关窗口不中断，菜单栏图标显示进度

## 6. 分阶段实施

| 阶段 | 内容 | 完成标志 |
|---|---|---|
| 1. 底座 + 搬家 | 建仓库；抽出 `LightTableKit`；视频高光与照片整理在新 App 跑通；首页扫描汇总（陀螺仪轨、机型、画面类型） | TravelCut 自测全过；同批素材新旧结果一致 |
| 2. 增稳调色 | 改写 batch-gyroflow；进程管理与心跳；Gyroflow 检测引导；分组选 LUT；打包 LGPL ffmpeg | `C0835.MP4` 增稳加调色跑通；四种异常场景界面反应正确；时间与音轨问题有结论 |
| 3. 拍摄习惯 | 改写 photo-habits，HTML 报告 | 同一文件夹新旧统计数字一致 |
| 4. 串联与收尾 | 自动串联、菜单栏进度、导出诊断、打包发布 | 真实旅行文件夹从拖入到出结果不碰终端 |

## 7. 测试

- 自测程序：沿用 TravelCut selftest，核心逻辑不依赖真实素材；batch-gyroflow 的 Python 单元测试逐条改写为 Swift 测试
- 新旧对照：
  - 增稳调色：同一输入，新 App 生成的 Gyroflow、ffmpeg 命令与 `batch_gyroflow.py` 等价
  - 拍摄习惯：同一文件夹，报告数字逐项一致
- 进程异常场景：子进程被外部杀掉、卡死无输出、不响应 SIGTERM、App 强退后重开；损坏输入用 5 KB 垃圾 `.MP4` 复现
- 真实素材：ZV-E10 `C0835.MP4`、一次真实旅行的照片文件夹；松下 V-Log 待补

## 待实测

- 松下 V-Log 的伽马信息能否读取
- Gyroflow 命令行裁切参数（若将来需要只渲染部分时间段）

## 备查：2026-10-25 对 `C0835.MP4` 的实测

- 原片：ZV-E10，3.5 秒，4K 23.976p H.264，PCM 音频，第三条轨为 `rtmd`（Timed Metadata）；exiftool 读出 84 组 Accelerometer 和 84 组 PitchRollYaw
- XML：`DeviceModelName = ZV-E10`，`CaptureGammaEquation = s-log2`，`TimeZone = -08:00`；未找到 SteadyShot 状态
- AVFoundation 只列出视频和音频两条轨，看不到 `rtmd`
- `AVAssetExportPresetPassthrough` 剪 2 秒：输出只有视频和音频，传感器数据 0 条
- Gyroflow 1.6.3 增稳（batch_gyroflow 默认参数，H.265）：
  - 音轨保留，PCM 转成 AAC
  - 容器 `creation_time` 为正确的 UTC（2025-10-26T22:10:41Z）
  - 时区、Sony XML（机型、`CaptureGammaEquation`）全部丢失，另多一条 `tmcd` 时间码轨
  - 在 Claude Code 沙盒里 GPU 初始化失败，退回 CPU（3.5 秒 4K 用 24 秒）；正常 App 进程不受此限
- 结论：
  - 不能先剪再增稳
  - 成片的时区、机型、伽马须从原片取：写回 `QuickTime:CreationDate`（带时区），机型与伽马记入增稳对照表
  - 识别陀螺仪轨须用 ffprobe 或自行解析 MP4，不能用 AVFoundation
  - 防抖开关状态读不到，相关提示不做
