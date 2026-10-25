VERDICT: NEEDS_REVISION

## Summary Assessment

The overall shape holds up: one Swift package, external Gyroflow, bundled helpers, a fixed pipeline order. It is a reasonable way to merge the three tools. Several claims do not match what the source repos actually do, though. The most serious are the TravelCut naming migration, Habits "same numbers" parity, colour-tag copying, resume safety and process supervision. If these go in unchanged they will cause wrong output or broken reruns, not just rough edges.

## Critical Issues (must fix)

### C1. TravelCut name/namespace migration is unspecified and breaks reruns and "新旧结果一致"
TravelCut identifies its own artefacts by hard-coded names:
- `MediaDiscovery.discoverVideos` skips only dirs prefixed `travelcut 高光片段` or containing `selection.json`.
- `PhotoDiscovery` skips dirs prefixed `travelcut `.
- Photos get `TravelCut|…` keywords plus the ownership marker `TravelCut|写入星级|N` (`EmbeddedMetadataWriter.markerPrefix`), along with a `travelcut:` XMP namespace and a `.travelcut-cache/` directory.

The design renames outputs to `LightTable 增稳/`, `LightTable 高光/` and `.lighttable-cache/` but says nothing about these rules. Consequences:
- Second run on the same folder: the `LightTable 增稳/` outputs are rediscovered as inputs. They have no `rtmd` track and no Sony XML, so they land in the 未识别 LUT group. Highlights then get picked from both the original and the stabilised copy, producing duplicates.
- If the keyword prefix changes, folders TravelCut already processed get a second keyword tree. Old TravelCut star ratings are no longer recognised as owned, so they can never be cleared. Both contradict the "behaviour unchanged" promise in §4.

Fix: decide explicitly. Either keep the `TravelCut|` namespace and marker, or recognise both old and new markers. Exclude every `LightTable *` output dir (and the old TravelCut ones) in all discovery paths. Add a selftest for rerun-on-own-output.

### C2. The fixed pipeline order contaminates Habits, and "原片不动" is false
- §1 says "原片不动". But photo grouping (the TravelCut 0.8.0 behaviour kept by §4) writes title and keywords **into** JPEG/HEIC/TIFF/DNG with `exiftool -overwrite_original`. That is an in-place edit of originals, and dry-run is off by default. The promise needs rewording, and the home screen should say that photo grouping writes metadata into the photos.
- The run order is 照片分组 → 拍摄习惯. photo-habits classifies by **keywords first**, using Chinese substring matching over Subject/HierarchicalSubject (`classify_by_tags`). TravelCut writes `TravelCut|主题|<theme>`, and its theme names hit photo-habits aliases:
  - 自然景观 and 沿途风景 → 风景
  - 城市街景 → 城市建筑 (via 城市)
  - 地标建筑 → 城市建筑 (via 建筑)
  - 活动人文 → 街头 (via 人文)
  - 当地美食 → 静物 (via 美食)

  Qwen tags under `TravelCut|标签|…` can also hit (e.g. 家人, 孩子). So after one grouping run, Habits categories come from TravelCut's travel-theme MobileCLIP labels, not from user keywords or the Habits classifier. The numbers change depending on whether grouping ran. Fix: Habits must ignore the app's own keyword namespace.

### C3. The Habits "统计口径不变 / 数字逐项一致" acceptance criterion cannot be met as designed
- **Categories:** photo-habits uses open_clip `ViT-B-32 / laion2b_s34b_b79k` with a calibrated `CLIP_MIN_PROB = 0.4` "其他" cutoff. MobileCLIP-S2 gives different probabilities, so the category counts and every per-category table will differ, and the 0.4 threshold is no longer calibrated. TravelCut's `MobileCLIPAnalyzer` also only carries travel themes, so the 7-category prompt set (including 其他) has to be ported and the threshold re-calibrated.
- **EXIF:** photo-habits reads exiftool tags that ImageIO cannot provide:
  - Composites: `LensID`, `FocalLength35efl#`, `ScaleFactor35efl#`
  - Sony MakerNote fields: `SceneMode`, `FacesDetected`
  - XMP: `CreatorTool`, `PersonInImage`, `RegionType`

  Lens fallback (`LensModel` "----" on adapted lenses → `LensID`), 35mm-equivalent focal length (which drives both special-topic sections) and the 场景模式/人脸检测 fallback step will all diverge. The design also drops the face-detection step from the classification order.
- Fix: since exiftool is bundled anyway, make it the single EXIF source for Habits (`-stay_open` for speed) and drop the ImageIO path. Define parity as "all non-category sections identical, and category sections identical under `--content meta`". Treat MobileCLIP categories as a deliberate, documented change.

### C4. "色彩标记照抄到成片" is wrong whenever the LUT changes the transfer or gamut
batch-gyroflow copies the source `color_transfer/primaries/space/range` onto the LUT output and forces `format=yuv420p` (8-bit). That works for Sony S-Log2, which is tagged bt709 in the VUI. It breaks for the HLG group the design explicitly supports (ZV-E10 PP10 HLG, iPhone HLG): the output is a Rec.709-graded image still tagged `arib-std-b67`/bt2020, so players will display it wrong. 10-bit sources are also truncated to 8-bit, and Dolby Vision metadata is dropped silently.

Fix: when a LUT is applied, output tags come from the LUT's target space (default bt709). Copy source tags only for the "不调色" path. Keep 10-bit (`p010`/`main10`) when the source is 10-bit and the LUT target is HDR. Add "Gyroflow H.265 output tags for HLG/10-bit input" to 待实测.

### C5. Resume trusts file existence, but ffmpeg writes the final file in place
batch-gyroflow skips a job when `destination.exists()`. Gyroflow is safe because it renders to `.tmp` and renames. The ffmpeg LUT pass, however, writes straight to the destination (`-y … destination`). batch-gyroflow only deletes partial outputs in-process. If the App crashes, is force-quit, loses power or has its drive unplugged, a truncated mp4 is left behind, and the next run reports it as "已完整生成" and skips it.

The same gap applies to "LUT 失败时保留 ProRes 中间文件，只重跑套 LUT": nothing records why an intermediate exists.

Fix: have ffmpeg write to `*.partial` and rename. Keep a per-job completion manifest (source fingerprint, settings hash, output size and duration). Verify duration with ffprobe before skipping. Write the CreationDate back as part of the atomic step rather than as a later in-place exiftool rewrite of a multi-GB file.

### C6. Process supervision is described as "从 TravelCut 抽出", but TravelCut has nothing reusable for long-running jobs
TravelCut's subprocess handling is ad-hoc and has these gaps:
- `QwenVideoAnalyzer.run` and `EmbeddedMetadataWriter.run` read stdout/stderr only **after** the process exits. That works for short llama/exiftool calls but deadlocks once a child fills the ~64 KB pipe buffer, which Gyroflow `--stdout-progress` and ffmpeg logs will do.
- Neither call uses process groups.
- `EmbeddedMetadataWriter.run` has no timeout and ignores the exit code.

Needed in LightTableKit, all new work:
- Continuous asynchronous pipe draining with a bounded log ring.
- `posix_spawn` with `POSIX_SPAWN_SETPGROUP`. Foundation `Process` cannot set a process group.
- ffmpeg run with `-progress pipe:1 -nostats`. batch-gyroflow uses `-loglevel error`, so there is no progress output for the heartbeat to read.
- A heartbeat that watches the ffmpeg `.partial` file, not just Gyroflow's `.tmp`.
- Handling for orphans. Children in their own process group survive an App crash and keep the GPU busy until the next launch. Kill them in `applicationWillTerminate`, and consider a tiny watchdog that uses kqueue `NOTE_EXIT` on the App's PID.
- Before killing PIDs from the run file on relaunch, verify the process's executable path and start time. PIDs get reused, and blindly killing one can hit an unrelated process.

### C7. Output location, staging space and unplugged drives
- Every result is forced under the selected folder. Typical non-technical inputs are an SD card's DCIM (small, exFAT, slow, sometimes write-locked) or an external drive that is nearly full. Allow choosing the output and staging location, and handle a read-only volume up front.
- ProRes staging is large. 4K 24p 422 HQ is about 700 Mbps, roughly 5 GB per minute, so one 10-minute clip needs about 50 GB. The estimate has to model peak usage:
  - Staging for the concurrent jobs
  - All final outputs
  - Intermediates kept after LUT failures, which accumulate across a batch

  Re-check free space before every clip rather than once at the start. "按总时长估算" alone over-blocks or under-blocks.
- Unplugged source or output volume: per-file failure handling would mark the rest of the batch failed in seconds, or let Gyroflow hang until the heartbeat timeout. Watch `NSWorkspace.didUnmountNotification` and check that the volume is still present before each job. Pause the whole run with a "重新连接后继续" state.

### C8. Day-folder timezones become inconsistent between stabilised and unstabilised clips
`ClipOrganizer.captureTimeZone` only reads `com.apple.quicktime.creationdate`, and otherwise falls back to `TimeZone.current`. TravelCut has no Sony XML parsing (grep confirms). After stabilisation the design writes the camera timezone back, but unstabilised ZV-E10 originals in the same batch still fall back to the Mac's timezone. On a trip away from home, clips from the same day split across different `D<n>` folders.

Fix: put a shared capture-time resolver in LightTableKit that reads the Sony XML `TimeZone` for all ZV-E10 clips, and use it in Highlights, Stabilize and the scan summary. Also specify the exact exiftool tag (`-Keys:CreationDate`, which maps to `com.apple.quicktime.creationdate`) and check that AVFoundation reads it back.

## Suggestions

- **LGPL ffmpeg:** the VideoToolbox h264/hevc encoders, `prores_ks`, `lut3d` and `format` are all LGPL-compatible. Drop batch-gyroflow's `libx264`/`libx265` fallback, which needs a GPL build. Ship the LGPL source/offer notice. Sign the binary with hardened runtime now so notarisation later is not a rebuild.
- **Gatekeeper:** "首次右键打开" no longer works on macOS 15+, where Control-click Open was removed. Document System Settings → Privacy & Security → "Open Anyway". Also expect TCC prompts for removable volumes and for Desktop/Documents. With ad-hoc signing those grants reset on every rebuild because they are keyed to the cdhash. Subprocesses are attributed to LightTable.
- **S-Log groups:** "必须选 LUT" conflicts with "每组都有不调色", and family users will have no LUT folder. Either bundle one default S-Log2/3→709 LUT (check the licence) or make 不调色 always allowed with a warning.
- **HTML filter:** the "按题材筛选" page filter needs either per-photo data embedded with the statistics recomputed in JS, or pre-rendering per category. The original allows multi-select, which is 2^6 combinations. Decide which. It is the largest piece of genuinely new code in Habits.
- **Scan speed:** the home-screen scan needs ffprobe plus Sony XML for every clip and EXIF for every photo. Use one `exiftool -stay_open` process and batched ffprobe, or the scan of a 2,000-file folder will be slow.
- **MobileCLIP licence:** the weights are licensed for research use only (TravelCut AGENTS §5). Downloading them on demand avoids redistribution, but using them in a public product needs a licence review before the notarised release.
- **Model migration:** "直接搬过来" breaks TravelCut while it is still installed. Use an APFS clone (`clonefile`) or hard links instead of a move.
- **Pipelining (optional):** highlights could start on each clip as soon as it is stabilised, instead of waiting for the whole stabilise batch. Not required for v1.
- **Phase-1 acceptance:** the "TravelCut 自测全过" bar is weak, because TravelCutSelfTest is only 83 lines. Add rerun-on-output, the TravelCut-namespace cases and the C8 timezone cases.
- **Gyroflow checks:** batch-gyroflow already detects the App Store build via `_MASReceipt` and exit -5 (SIGTRAP). Reuse that instead of reading entitlements. Add `~/Applications` to the search paths.

## Verified Claims

- Gyroflow exits 0 on failure and the produced output is the only success signal; Gyroflow renders to `.tmp` then renames; `--preset` must be merged into a single value; unknown preset keys are silently ignored. All match the batch-gyroflow docstring and `render_job`/`build_preset_value`.
- Stabilise+LUT goes Gyroflow → ProRes staging → ffmpeg `format=yuv444p16le,lut3d` → `yuv420p`. The LUT preview uses the same path. Both confirmed in `build_lut_command` and the README.
- The App Store Gyroflow build is unusable (sandbox abort, exit -5). Confirmed by `probe_gyroflow_cli` and the README.
- Gyro detection uses ffprobe stream markers (`rtmd`/`gpmd`/`camm`), not AVFoundation, which is consistent with the C0835 test notes.
- TravelCut photo mode does burst grouping, writes keywords, writes no stars by default and leaves user ratings alone (0.8.0 notes, `EmbeddedMetadataWriter.decide`). RAW+JPEG is treated as one photo in both TravelCut and photo-habits.
- photo-habits does RAW-preferred dedup by body + time + subsec + stem, excludes exports and phones by default, merges `.xmp` ratings, has 6 categories plus 其他/未分类, and has the long-lens and 35mm special topics. All present. Note it outputs `report.md`, not HTML, so the HTML report is new work, not a port.
- TravelCut does **not** bundle exiftool or ffmpeg today. `findExiftool` searches PATH and Homebrew, and the App tells users to `brew install exiftool`. Bundling both is new work. Running a bundled exiftool with `/usr/bin/perl` is workable for now, and the design already flags the removal risk.
- llama.cpp is bundled under `Resources/llama` (b11105), and MobileCLIP/Qwen are downloaded with resume support via `ModelInstaller`. Reusable as claimed.
