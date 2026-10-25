# LightTable 看片台

拍完回来，把这次的文件夹拖进 LightTable，它会看看里面有什么，然后帮你做这几件事：

| 功能 | 做什么 |
|---|---|
| 增稳调色 | 用相机记录的陀螺仪数据让画面更稳（Sony ZV-E10 等），给 S-Log 灰片套上你选的色调 |
| 挑视频高光 | 挑出值得保留的片段，按天分好文件夹，按拍摄时间编号，直接拖进剪映 |
| 看拍摄习惯 | 统计常用的焦段、光圈、ISO、拍摄时段，按题材对比，生成一页网页报告 |
| 照片分组 | 把连拍和相似照片分组，写上组号、主题、地点关键字，在 Adobe Bridge 里一组一组看 |

所有分析都在这台 Mac 上完成，不上传照片和视频。原片的像素不会被改动。

LightTable 合并了三个工具：[TravelCut](https://github.com/nightfade/TravelCut)（视频高光、照片分组）、[batch-gyroflow](https://github.com/nightfade/batch-gyroflow)（增稳调色）、[photo-habits](https://github.com/nightfade/photo-habits)（拍摄习惯）。

## 安装

1. 把 `LightTable.app` 拖进「应用程序」。
2. 第一次打开时 macOS 会拦下来。到「系统设置 → 隐私与安全性」，在下面找到 LightTable，点「仍要打开」。以后就能正常双击打开了。
3. 要用增稳的话，还需要装免费软件 [Gyroflow](https://gyroflow.xyz/download)。LightTable 发现没装时会一步步告诉你怎么装。注意 Mac App Store 里的 Gyroflow 不能用，要从官网下载。

需要 Apple 芯片的 Mac（M1 及以后），macOS 14 或更新。推荐 24 GB 以上内存。

## 使用

1. 把这次拍的文件夹拖进窗口（视频、照片混在一起、有子文件夹都没关系）。
2. LightTable 列出里面有什么，例如「ZV-E10 视频 32 段（可增稳，S-Log2 28 段）、照片 1,840 张」，并按素材预先勾好能做的事。
3. 按需要改一下勾选。增稳调色要给每种画面选一个色调：
   - 第一次会让你选一个放 `.cube` 色调文件的文件夹，以后会记住。
   - 同一帧画面套上每个色调排成一面墙，点一个顺眼的。上次用的会标出来，但不会自动替你选。
   - 普通画面默认不调色。
4. 点「开始」。可以关掉窗口去做别的事，菜单栏会显示进度，电脑不会自动睡眠。

几件事做完后，结果在你拖进来的文件夹里：

```text
你的文件夹/
├─ LightTable 增稳/          增稳调色后的视频，子文件夹结构和原来一样，另有「对照表.json」
├─ LightTable 高光/          高光片段，每天一个文件夹，selection.json 记录每段来自哪个原片
├─ LightTable 拍摄习惯.html   拍摄习惯报告，会自动在浏览器里打开
└─ LightTable 日志/           每次运行的记录
```

素材在存储卡上，或者文件夹不能写入时，LightTable 会请你另选一个存放结果的文件夹。

## 几个要知道的地方

- **先增稳，再挑高光。** 剪切会丢掉陀螺仪数据，所以两项都选时，LightTable 先做增稳调色，再从增稳后的视频里挑高光。没增稳的视频直接用原片。
- **第一次挑高光要下载约 3 GB 的本地模型**，之后可以离线使用。模型存放在 `~/Library/Application Support/LightTable/`。装过 TravelCut 的话会直接沿用它下载好的模型。
- **照片分组会写照片的元数据**：RAW 写在旁边的 `.xmp`，JPEG、HEIC 写进文件本身。不改像素，不动你已经打的星级和颜色标签。关键字放在 `TravelCut` 名下，和以前用 TravelCut 整理过的照片保持一致。
- **可以随时停。** 已经做完的部分会保留，下次用同样的设置开始，会从停下的地方接着做。
- **卡住了会提示你。** 某段视频长时间没有进展时，可以选「跳过这段」或「再等等」；没人管的话会自动跳过，继续后面的。
- **出问题时**，在结果页点「导出诊断信息」，把生成的 zip 发给帮你看的人。

## 命令行

App 里附带了命令行工具 `LightTable.app/Contents/Helpers/lighttable-cli`，功能和 App 一样，方便调试：

```bash
lighttable-cli scan "/path/to/folder"
lighttable-cli stabilize "/path/to/folder" --lut-for sLog2=look.cube
lighttable-cli highlights "/path/to/folder" --themes 自然景观,人物互动
lighttable-cli habits "/path/to/folder"
lighttable-cli photos "/path/to/folder" --dry-run
```

## 开发

修改代码前请先读 [`AGENTS.md`](AGENTS.md)，设计文档在 [`docs/plans/`](docs/plans/)。

```bash
swift build --disable-sandbox
swift run --disable-sandbox lighttable-selftest     # LightTable 自测
swift run --disable-sandbox travelcut-selftest      # 迁入的 TravelCut 自测
./scripts/build-ffmpeg-lgpl.sh                      # 一次性：编译要打包进 App 的 LGPL ffmpeg
./scripts/build-app.sh                              # 生成 dist/LightTable.app
```
