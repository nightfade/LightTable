# LightTable App 层审查（2026-10-25）

范围：`Sources/LightTableApp/*.swift`、`Sources/LightTableCLI/main.swift`。已对照 Stabilize / TravelCutCore / LightTableKit 引擎代码核实。`swift build --product LightTable` 能通过，没有报错。按严重程度排序。

## 高

1. **停止对高光、拍摄习惯、照片分组三步不起作用**（AppModel.swift:462、505、533）
   - 三步都用 `Task.detached { … }.value` 执行。取消 `pipeline` 不会传进 detached task，所以引擎里的 `Task.checkCancellation()` 永远不会抛错，`QwenVideoAnalyzer`、`ModelInstaller` 里的 `withTaskCancellationHandler` 也永远不会触发。
   - 后果：用户点「停止」后，按钮变灰显示「正在停止…」，但 Qwen 分析或 3 GB 模型下载会一直跑完；照片分组也会继续往照片里写元数据。界面一直停在 `.running`，可能长达数小时。
   - 退出 App（LightTableApp.swift:47）时只等 6 秒就退出。llama / curl 子进程不在 `ProcessRegistry` 里，退出后会变成孤儿进程。
   - 修法：用 `withTaskCancellationHandler { try await t.value } onCancel: { t.cancel() }` 包住 detached task；或者改用非 detached 的子任务，让取消能自动传下去。

2. **改了 LUT 或开关以后「重新处理」仍复用旧成片**（StabilizeEngine.swift:256，StabilizeCommands.uniqueOutputs）
   - 成片路径只由相对路径和编码决定。判断「已完成」只看文件存在、时长对得上。
   - 场景：第一次给 S-Log3 套了 A.cube，看完不满意，点「重新处理」改成 B.cube。所有片段都报「上次已完成」，成片还是 A 的色调。关掉调色、改最大裁切也一样。
   - 中间文件 staging 也会被复用，所以改了 `maxZoom` / `readoutTime` 后只会重跑调色。
   - 修法：把 LUT 路径、增稳开关、preset 写进 `对照表.json`，或写成旁边的小签名文件；判定「已完成」和复用 staging 前先比对，不一致就重做。

3. **换文件夹后，上一个文件夹的 LUT 选择被自动套用**（AppModel.swift:207 / 188）
   - `applyScan` → `rebuildGroups` 时，`groups` 里还是上一个文件夹的分组，`previous[profile]` 会把旧选择带过来。
   - 场景：文件夹 A 给 S-Log3 选了 X.cube，回首页拖入文件夹 B。B 的 S-Log3 组直接是 X.cube，不再处于 `.undecided`，也不会拦住开始。这违反设计「每次都让使用者选，不自动套用」。
   - 修法：`applyScan`（或 `backToHome` / `open`）里先 `groups = []` 再重建。

4. **过期的「卡住」提示会跳过错误的片段**（AppModel.swift:420、340；SupervisedProcess.swift:305-318）
   - 心跳线程先在锁内判断进程没结束，再在锁外调用 `onQuiet`。进程可能恰好在这中间退出，于是 `.quiet` 晚于 `.clipFinished`，甚至晚于下一段的 `.clipStarted` 才发出。
   - 每个事件又各自 `Task { @MainActor }` 投递，主线程上的执行顺序也没有保证。
   - 后果一：横幅显示上一段的名字，用户点「跳过这段」，`skipCurrent()` 杀掉的是正在跑的下一段。
   - 后果二：如果是最后一段，横幅会留到高光、拍摄习惯步骤，那时按钮调用的是 `nil` 引擎，没有任何作用。迟到的 `.progress` 同理，会把总进度拉回增稳那一段，覆盖 `detail`。
   - 修法：事件带上片段 index，只接受当前片段的 `.quiet`；`runStabilize` 返回后递增一个 step token，丢弃旧 token 的事件；`clipFinished` 记下已结束的 index。引擎侧在锁内发 `onQuiet`，或回调前再检查一次 `done`。

## 中

5. **`LightTable 高光 2…N` 会被下次扫描当成素材**（MediaScanner.swift:69）
   - `excludedFolderNames` 是精确匹配，只排除了 `LightTable 高光`。App 会生成 `LightTable 高光 2` 等文件夹（AppModel.swift:488）。
   - 后果：下次打开同一文件夹时，导出的高光片段会被重新增稳、调色（Log 片段会再套一次 LUT），也会被重新挑高光。
   - 修法：按前缀 `LightTable 高光` 排除，或者检查目录里有没有 `selection.json` / 检查点文件。

6. **高光步骤做完以后，「重新处理（已完成的会跳过）」会整段重做**（AppModel.swift:487-497）
   - 成功完成后检查点已删除，只剩 `selection.json`，`isUsed` 为真。所以重新处理会新建 `高光 2`，从头跑 Qwen 分析。这和按钮上写的「已完成的会跳过」矛盾。
   - 修法：配置相同（素材签名、主题一致）且已完成时，直接报告「上次已完成」；或者结果页只对未完成或失败的步骤提供重做。

7. **`stop()` 可能在增稳开始的瞬间丢失**（AppModel.swift:408 → StabilizeEngine.swift:159）
   - 先执行 `stabilizeEngine = engine`，再 `await engine.run`。`run` 一开始会把 `stopRequested` 重置为 false。
   - 如果 stop 落在这两者之间（`run` 已切到后台执行器），停止请求被清掉。引擎不检查 `Task.isCancelled`，所以整批增稳会继续跑完。
   - 修法：`run` 里不要重置 `stopRequested`（每个引擎实例只用一次），或者在循环里同时检查 `Task.isCancelled`。

8. **「换一个样张」后缩略图混着旧样张**（LUTPickerView.swift:196-209）
   - `loadFrame` 清空 `graded` 以后，在 `extractFrame` 上等待。旧的 `gradingTask` 这时还没取消，会继续把旧帧的调色结果写进 `graded`。
   - 新的 `startGrading` 会跳过已有结果的 LUT，于是这部分缩略图和预览一直是上一个样张。快速连点时，旧的 `extractFrame` 还可能后返回，覆盖新帧。
   - 修法：`loadFrame` 开头先 `gradingTask?.cancel()`；用 sampleIndex 作为 token，丢弃过期结果。

9. **只勾挑高光也会抹掉「上次用的」LUT**（AppModel.swift:299）
   - 这一行对所有分组执行 `setLastLUT(choice.url)`，不管有没有勾选增稳调色。`.undecided` 和 `.none` 都会写入 nil。
   - 场景：一次只挑高光，以后选 LUT 时「上次用的」标记全部消失。
   - 修法：只在 `selected.contains(.stabilize)` 且选择是 `.lut` 时写入。

10. **CLI 不认识的选项被静默当成开关**（main.swift:47-53）
    - `--dryrun`（少写一个连字符）或 `--output=/x`（等号写法）都会进 `flags` 被忽略。
    - 后果：命令直接开始真实增稳，结果写回素材文件夹，可能是存储卡。`--max-zoom abc` 也会被 `flatMap(Double.init)` 静默丢掉，改用默认裁切。
    - 修法：每个命令声明自己允许的开关集合，遇到未知开关或非数字值就 `fail`；多余的位置参数也报错。

## 低

11. **CLI 的 `--lut` 会套到所有视频上**（main.swift:135）
    - 包括普通 709 和 HLG 片段。另外 `--lut-for` 只看 `detectedProfile`，不读 App 里给未识别机型指定的画面类型。
    - 建议：`--lut` 只作用于 `isLog` 的分组，或在用法说明里写清楚。

12. **输出位置判断**（AppModel.swift:373-377）
    - `a && b && c || d` 里，`d`（卷根目录有 DCIM）单独成立就算存储卡，所以把相机目录整个拷到外置 SSD 根目录也会每次弹窗。
    - 选出来的输出位置没有记住，也没有检查能否写入。重新处理时选了另一个文件夹，增稳和高光都无法续做；选到只读文件夹时，日志静默写入失败，每段都失败。
    - 修法：给 `||` 两侧加括号并要求可移除；记住每个素材文件夹对应的输出位置；校验 `isWritableFile`。

13. **导出诊断失败没有任何提示**（AppModel.swift:576-578）
    - `ditto` 失败时，仍然在 Finder 里定位一个不存在的 zip。
    - 修法：检查退出码，失败时设置 `errorMessage`。
