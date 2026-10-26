import Darwin
import Foundation
import LightTableKit
@testable import Stabilize

// Stabilize module checks. The command-construction cases are ports of batch-gyroflow's
// tests/test_batch_gyroflow.py; the supervision cases drive a fake gyroflow shell script; the
// end-to-end cases need ffmpeg (synthetic clip) and Gyroflow plus the real ZV-E10 clip.

func runStabilizeTests() async {
    print("stabilize: commands")
    testOutputNaming()
    testGyroflowCommand()
    testPresetMerging()
    testLUTCommand()
    testColorTags()
    testProgressParsing()
    testSizesAndTimeouts()
    testGyroflowStatus()
    testMapFile()

    guard let ffmpeg = Tools.find(.ffmpeg), Tools.find(.ffprobe) != nil else {
        print("stabilize: ffmpeg/ffprobe missing, skipping supervision and end-to-end tests")
        return
    }
    print("stabilize: supervision with a fake gyroflow")
    await testSupervisionFaults(ffmpeg: ffmpeg)
    await testStopAndPause(ffmpeg: ffmpeg)
    print("stabilize: LUT-only end to end")
    await testLUTOnlyEndToEnd(ffmpeg: ffmpeg)
    await testLUTPreview(ffmpeg: ffmpeg)

    if ProcessInfo.processInfo.environment["LIGHTTABLE_SKIP_REAL"] == nil {
        await testRealClip()
    }
}

// MARK: Fixtures

/// `ScannedVideo` has no public memberwise init; build one through its Codable form.
func makeVideo(url: URL, relativePath: String, duration: Double = 1, width: Int = 320, height: Int = 240,
               frameRate: Double = 24, gyro: String? = "rtmd", profile: ColorProfile = .sLog2,
               creationDate: String? = nil, colorRange: String? = "tv", colorSpace: String? = nil,
               cameraModel: String? = "ZV-E10") -> ScannedVideo {
    var object: [String: Any] = [
        "url": url.absoluteString, "relativePath": relativePath, "duration": duration,
        "width": width, "height": height, "frameRate": frameRate, "codec": "h264",
        "detectedProfile": profile.rawValue, "size": 1000,
    ]
    object["gyroFormat"] = gyro
    object["cameraModel"] = cameraModel
    object["creationDate"] = creationDate
    object["colorRange"] = colorRange
    object["colorSpace"] = colorSpace
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(ScannedVideo.self, from: data)
}

/// 2×2×2 `.cube`; `transform` maps an (r, g, b) lattice point to its output.
func writeCube(_ url: URL, transform: (Double, Double, Double) -> (Double, Double, Double)) {
    var text = "TITLE \"test\"\nLUT_3D_SIZE 2\n"
    for b in [0.0, 1.0] { for g in [0.0, 1.0] { for r in [0.0, 1.0] {
        let (outR, outG, outB) = transform(r, g, b)
        text += String(format: "%.6f %.6f %.6f\n", outR, outG, outB)
    } } }
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

@discardableResult
func shell(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 120) -> SupervisedProcess.Result? {
    try? SupervisedProcess.runToCompletion(executable: executable, arguments: arguments, timeout: timeout)
}

/// One second of flat colour plus audio, small enough to encode in a fraction of a second.
func makeClip(_ url: URL, ffmpeg: URL, color: String = "0xC8C8C8", tenBit: Bool = false, duration: Double = 1) -> Bool {
    var arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=\(color):s=320x240:r=24:d=\(duration)",
                     "-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration)"]
    arguments += tenBit
        ? ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-b:v", "4M", "-tag:v", "hvc1"]
        : ["-c:v", "mpeg4", "-q:v", "2", "-pix_fmt", "yuv420p"]
    arguments += ["-color_range", "tv", "-colorspace", "bt709", "-c:a", "aac", "-shortest", url.path]
    return shell(ffmpeg, arguments)?.ending == .finished(.exited(0))
}

func probeJSON(_ url: URL) -> [String: Any] {
    guard let ffprobe = Tools.find(.ffprobe),
          let result = shell(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]),
          let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    else { return [:] }
    return json
}

func streams(_ json: [String: Any], _ type: String) -> [[String: Any]] {
    (json["streams"] as? [[String: Any]] ?? []).filter { $0["codec_type"] as? String == type }
}

func duration(_ json: [String: Any]) -> Double {
    Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
}

/// Raw bytes of the centre patch, read through a file so binary data survives.
func centerRGBFile(_ url: URL, ffmpeg: URL, folder: URL) -> (Double, Double, Double)? {
    let raw = folder.appendingPathComponent("center-\(UUID().uuidString).rgb")
    guard shell(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-frames:v", "1",
                         "-vf", "crop=32:32:(iw-32)/2:(ih-32)/2,format=rgb24", "-f", "rawvideo", raw.path])?.ending == .finished(.exited(0)),
          let data = try? Data(contentsOf: raw), data.count >= 3 else { return nil }
    var sums = (0.0, 0.0, 0.0)
    let pixels = data.count / 3
    for index in 0..<pixels {
        sums.0 += Double(data[index * 3])
        sums.1 += Double(data[index * 3 + 1])
        sums.2 += Double(data[index * 3 + 2])
    }
    return (sums.0 / Double(pixels), sums.1 / Double(pixels), sums.2 / Double(pixels))
}

func near(_ value: Double, _ target: Double, _ tolerance: Double) -> Bool { abs(value - target) <= tolerance }

/// Collects events from the engine's callback threads.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StabilizeEvent] = []
    var onEvent: (@Sendable (StabilizeEvent) -> Void)?

    func record(_ event: StabilizeEvent) {
        lock.withLock { items.append(event) }
        onEvent?(event)
    }

    var events: [StabilizeEvent] { lock.withLock { items } }

    var quietCount: Int { events.filter { if case .quiet = $0 { true } else { false } }.count }
    var pausedCount: Int { events.filter { if case .paused = $0 { true } else { false } }.count }
    var resumedCount: Int { events.filter { if case .resumed = $0 { true } else { false } }.count }
    var progressValues: [Double] {
        events.compactMap { if case .progress(let overall, _, _) = $0 { overall } else { nil } }
    }
}

// MARK: Commands (ported from batch-gyroflow)

func testOutputNaming() {
    let root = URL(fileURLWithPath: "/output/LightTable 增稳")
    let url = StabilizeCommands.outputURL(for: "day1/C0835.MP4", outputRoot: root, codec: .hevc)
    expect(url.path == "/output/LightTable 增稳/day1/C0835.mp4", "output mirrors the tree and keeps the stem: \(url.path)")
    let mov = StabilizeCommands.outputURL(for: "clip.MOV", outputRoot: root, codec: .hevc)
    expect(mov.lastPathComponent == "clip.mp4", "extension follows the codec, not the input")
    let unique = StabilizeCommands.uniqueOutputs(for: ["a/C0001.MP4", "a/C0001.MOV", "b/C0001.MP4"], outputRoot: root, codec: .hevc)
    expect(unique.map(\.lastPathComponent) == ["C0001.mp4", "C0001_MOV.mp4", "C0001.mp4"], "same stem in one folder does not collide: \(unique.map(\.lastPathComponent))")
    let partial = StabilizeCommands.partialURL(for: url)
    expect(partial.lastPathComponent.hasPrefix(".") && partial.pathExtension == "mp4"
           && partial.deletingLastPathComponent() == url.deletingLastPathComponent(),
           "temp output is hidden, beside the final file, same container: \(partial.lastPathComponent)")
    expect(StabilizeCommands.stagingURL(for: url).pathExtension == "mov", "staging is a .mov")
    expect(StabilizeCommands.gyroflowTemp(for: partial).lastPathComponent == partial.lastPathComponent + ".tmp", "Gyroflow's .tmp name")
}

func gyroflowParams(_ arguments: [String]) -> [String: Any] {
    guard let index = arguments.firstIndex(of: "--out-params"),
          let object = try? JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any]
    else { return [:] }
    return object
}

func testGyroflowCommand() {
    let source = URL(fileURLWithPath: "/input/clip.MP4")
    let target = URL(fileURLWithPath: "/output/.clip.lighttable-partial.mp4")
    let direct = StabilizeCommands.gyroflowArguments(source: source, target: target, staging: false, codec: .hevc, bitrateMbps: 100, preset: nil)
    let params = gyroflowParams(direct)
    expect(direct.first == source.path, "source is the first argument")
    expect(params["output_path"] as? String == target.path, "explicit output_path")
    expect(direct[direct.firstIndex(of: "--out-params")! + 1].contains("\"/output/"), "slashes are not escaped in the JSON")
    expect(params["codec"] as? String == "H.265/HEVC" && params["bitrate"] as? Int == 100, "delivery codec and bitrate")
    expect(params["audio"] as? Bool == true, "audio kept")
    expect(!direct.contains("--gyro-file") && !direct.contains("--preset"), "embedded metadata, no lens or gyro arguments")
    expect(direct.contains("--stdout-progress"), "progress on stdout")

    let staging = StabilizeCommands.gyroflowArguments(source: source, target: URL(fileURLWithPath: "/output/.clip.lighttable-staging.mov"),
                                                      staging: true, codec: .hevc, bitrateMbps: 100, preset: nil)
    let stagingParams = gyroflowParams(staging)
    expect(stagingParams["codec"] as? String == "ProRes" && stagingParams["bitrate"] == nil, "ProRes staging, no bitrate, when a LUT follows")
    expect((stagingParams["output_path"] as? String)?.hasSuffix(".mov") == true, "staging written as .mov")

    let preset = StabilizeCommands.gyroflowArguments(source: source, target: target, staging: false, codec: .h264, bitrateMbps: 50, preset: "{\"version\":2}")
    expect(preset.filter { $0 == "--preset" }.count == 1, "preset passed once")
    expect(gyroflowParams(preset)["codec"] as? String == "H.264/AVC", "H.264 codec name")
}

func testPresetMerging() {
    expect(StabilizeCommands.presetValue(maxZoom: nil, readoutTime: nil) == nil, "no overrides → no --preset")
    func parse(_ value: String?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((value ?? "").utf8)) as? [String: Any]) ?? [:]
    }
    let zoom = parse(StabilizeCommands.presetValue(maxZoom: 117.6, zoomWindow: -1, readoutTime: nil))
    let stabilization = zoom["stabilization"] as? [String: Any] ?? [:]
    expect(zoom["version"] as? Int == 2, "preset version 2")
    expect(stabilization["max_zoom"] as? Double == 117.6, "max_zoom")
    expect(stabilization["adaptive_zoom_window"] as? Int == -1 && stabilization["adaptive_zoom"] == nil,
           "adaptive_zoom_window is the key Gyroflow reads; adaptive_zoom is silently ignored")
    let readout = parse(StabilizeCommands.presetValue(maxZoom: nil, readoutTime: 15.6, readoutDirection: "BottomToTop"))
    let readoutStab = readout["stabilization"] as? [String: Any] ?? [:]
    expect(readoutStab["frame_readout_time"] as? Double == 15.6 && readoutStab["frame_readout_direction"] as? String == "BottomToTop",
           "rolling-shutter keys")
    let merged = parse(StabilizeCommands.presetValue(
        maxZoom: 117.6, readoutTime: nil,
        base: ["version": 2, "stabilization": ["fov": 1.2, "max_zoom": 200], "output": ["codec": "ProRes"]]))
    let mergedStab = merged["stabilization"] as? [String: Any] ?? [:]
    expect(mergedStab["max_zoom"] as? Double == 117.6 && mergedStab["fov"] as? Double == 1.2
           && (merged["output"] as? [String: Any])?["codec"] as? String == "ProRes",
           "overrides merge into an existing preset without dropping keys")
}

func testLUTCommand() {
    let lut = URL(fileURLWithPath: "/luts/my grade:v2.cube")
    var pass = StabilizeCommands.LUTPass(
        input: URL(fileURLWithPath: "/output/.clip.lighttable-staging.mov"),
        output: URL(fileURLWithPath: "/output/.clip.lighttable-partial.mp4"),
        lut: lut, codec: .hevc, tenBit: false, bitrateMbps: 100,
        inputTags: .init(range: "tv", space: "bt709"), sourceTags: .init(range: "pc"), height: 2160, audioCodec: "aac")
    var arguments = StabilizeCommands.lutArguments(pass)
    let filter = arguments[arguments.firstIndex(of: "-vf")! + 1]
    expect(arguments[arguments.firstIndex(of: "-i")! + 1] == pass.input.path, "LUT pass reads the staging file")
    expect(arguments.last == pass.output.path, "LUT pass writes the temp output")
    expect(arguments[arguments.firstIndex(of: "-c:a")! + 1] == "copy", "AAC audio copied")
    expect(filter.contains("format=yuv444p16le,lut3d=file="), "16-bit 4:4:4 before lut3d: \(filter)")
    expect(filter.contains("my grade\\:v2.cube"), "filter path escaped")
    expect(filter.hasPrefix("setparams=range=limited:colorspace=bt709"), "staging's own tags interpret the input (Gyroflow converts to limited)")
    expect(filter.contains("scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"), "8-bit source → 8-bit 4:2:0 limited BT.709")
    expect(arguments.contains("hevc_videotoolbox") && arguments[arguments.firstIndex(of: "-profile:v")! + 1] == "main", "VideoToolbox HEVC Main")
    expect(!arguments.contains("libx264") && !arguments.contains("libx265"), "no GPL encoders")
    expect(arguments[arguments.firstIndex(of: "-b:v")! + 1] == "100M", "bitrate")
    expect(arguments[arguments.firstIndex(of: "-color_range")! + 1] == "tv"
           && arguments[arguments.firstIndex(of: "-colorspace")! + 1] == "bt709"
           && arguments[arguments.firstIndex(of: "-color_primaries")! + 1] == "bt709"
           && arguments[arguments.firstIndex(of: "-color_trc")! + 1] == "bt709",
           "graded output tagged Rec.709 limited regardless of the source")
    expect(arguments.contains("-map") && arguments.contains("0:v:0") && arguments.contains("0:a?"), "data tracks (rtmd, tmcd) not mapped")

    pass.tenBit = true
    pass.audioCodec = "pcm_s16be"
    pass.input = URL(fileURLWithPath: "/input/clip.MP4")
    pass.inputTags = .init(range: "pc")
    arguments = StabilizeCommands.lutArguments(pass)
    let tenBitFilter = arguments[arguments.firstIndex(of: "-vf")! + 1]
    expect(arguments[arguments.firstIndex(of: "-i")! + 1] == "/input/clip.MP4", "LUT-only reads the source")
    expect(arguments[arguments.firstIndex(of: "-profile:v")! + 1] == "main10" && arguments[arguments.firstIndex(of: "-pix_fmt")! + 1] == "p010le",
           "10-bit source → HEVC Main10 p010")
    expect(tenBitFilter.contains("format=p010le"), "10-bit filter output")
    expect(tenBitFilter.hasPrefix("setparams=range=full:colorspace=bt709"), "full-range source read as full; missing matrix → BT.709 for UHD")
    expect(arguments[arguments.firstIndex(of: "-c:a")! + 1] == "aac", "camera PCM becomes AAC in MP4")

    pass.audioCodec = nil
    expect(!StabilizeCommands.lutArguments(pass).contains("-c:a"), "no audio flags without audio")
    pass.codec = .h264
    pass.tenBit = false
    arguments = StabilizeCommands.lutArguments(pass)
    expect(arguments.contains("h264_videotoolbox"), "H.264 via VideoToolbox")

    expect(StabilizeCommands.isTenBit(pixelFormat: "yuv420p10le", bitsPerRawSample: nil), "yuv420p10le is 10-bit")
    expect(StabilizeCommands.isTenBit(pixelFormat: "yuv422p10le", bitsPerRawSample: "10"), "422 10-bit")
    expect(!StabilizeCommands.isTenBit(pixelFormat: "yuvj420p", bitsPerRawSample: "8"), "ZV-E10 8-bit")
    expect(!StabilizeCommands.isTenBit(pixelFormat: "yuv420p", bitsPerRawSample: nil), "yuv420p is 8-bit")
}

func testColorTags() {
    let tags = StabilizeCommands.ColorTags(range: "tv", space: "unknown", primaries: "", transfer: "reserved")
    expect(tags == .init(range: "tv"), "unknown/empty/reserved values dropped")
    expect(tags.outputFlags == ["-color_range", "tv"], "only known tags become flags")
    let sd = StabilizeCommands.inputInterpretation(input: .init(), source: .init(), height: 480)
    expect(sd == "setparams=range=limited:colorspace=smpte170m", "untagged SD: limited BT.601")
    let fromSource = StabilizeCommands.inputInterpretation(input: .init(), source: .init(range: "pc", space: "bt470bg"), height: 1080)
    expect(fromSource == "setparams=range=full:colorspace=bt470bg", "gaps filled from the original's tags")
    let inputWins = StabilizeCommands.inputInterpretation(input: .init(range: "tv"), source: .init(range: "pc"), height: 2160)
    expect(inputWins.contains("range=limited"), "the LUT input's own tag wins over the original")
}

func testProgressParsing() {
    expect(StabilizeCommands.gyroflowProgress("[41738b21] Rendering progress: 21/84 frames (25.0%) ETA 20.1s") == 0.25, "Gyroflow progress line")
    expect(StabilizeCommands.gyroflowProgress("[INFO] Done in 23s") == nil, "other Gyroflow lines ignored")
    expect(StabilizeCommands.ffmpegProgress("out_time_us=500000", duration: 2) == 0.25, "ffmpeg -progress line")
    expect(StabilizeCommands.ffmpegProgress("progress=continue", duration: 2) == nil, "other ffmpeg lines ignored")
    expect(StabilizeCommands.ffmpegProgress("out_time_us=9000000", duration: 2) == 1, "clamped to 1")
}

func testSizesAndTimeouts() {
    expect(StabilizeCommands.defaultBitrate(width: 3840, height: 2160, frameRate: 23.976) == 100, "UHD default 100 Mbps")
    expect(StabilizeCommands.defaultBitrate(width: 1920, height: 1080, frameRate: 60) == 50, "1080p60 default 50 Mbps")
    let staging = StabilizeCommands.stagingBytes(duration: 60, width: 3840, height: 2160, frameRate: 25)
    expect(near(Double(staging), 5e9, 1e8), "UHD ProRes staging ≈ 5 GB/min")
    let expected = StabilizeCommands.expectedSeconds(duration: 60, width: 3840, height: 2160, frameRate: 24, stabilize: true, lut: true)
    expect(StabilizeCommands.stallTimeout(expectedSeconds: expected) == max(120, 4 * expected), "stall timeout scales with the clip")
    expect(StabilizeCommands.stallTimeout(expectedSeconds: 1) == 120, "stall timeout at least two minutes")

    let root = scratchFolder("stabilize-estimate")
    var settings = StabilizeSettings(sourceRoot: root, outputRoot: root.appendingPathComponent("out"))
    settings.freeSpaceProbe = { _ in 123 }
    let engine = StabilizeEngine(settings: settings)
    let video = makeVideo(url: root.appendingPathComponent("a.MP4"), relativePath: "a.MP4", duration: 60, width: 3840, height: 2160)
    let estimate = engine.estimate([
        StabilizeJob(source: video, profile: .sLog2, stabilize: true, lut: URL(fileURLWithPath: "/x.cube")),
        StabilizeJob(source: video, profile: .sLog2, stabilize: false, lut: nil),
    ])
    expect(estimate.finalBytes > 700_000_000 && estimate.finalBytes < 900_000_000, "estimate: one minute of 100 Mbps ≈ 790 MB (\(estimate.finalBytes))")
    expect(estimate.peakBytes > estimate.finalBytes + 4_000_000_000, "estimate: peak includes ProRes staging")
    expect(estimate.availableBytes == 123, "estimate uses the free-space probe")
    expect(estimate.seconds > 0, "estimate has a duration")
}

func testGyroflowStatus() {
    let folder = scratchFolder("stabilize-gyroflow-status")
    expect(Gyroflow.check(override: folder.appendingPathComponent("nothing.app"), timeout: 5) == .missing, "missing")

    let mas = folder.appendingPathComponent("Store/Gyroflow.app")
    try? FileManager.default.createDirectory(at: mas.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
    expect(Gyroflow.check(override: mas, timeout: 5) == .appStore(app: mas), "_MASReceipt → App Store build")

    func script(_ name: String, _ body: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try? "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
    let good = script("good", "echo '12:00 [DEBUG] noise'; echo 'Gyroflow v1.6.3'")
    expect(Gyroflow.check(override: good, timeout: 5) == .ready(executable: good, version: "v1.6.3"), "version parsed")
    let trap = script("trap", "kill -TRAP $$")
    expect(Gyroflow.check(override: trap, timeout: 5) == .appStore(app: trap), "SIGTRAP → App Store build")
    let fails = script("fails", "echo boom >&2; exit 3")
    if case .broken(_, let detail) = Gyroflow.check(override: fails, timeout: 5) {
        expect(detail.contains("3"), "broken names the exit: \(detail)")
    } else { expect(false, "non-zero exit → broken") }
    let hangs = script("hangs", "sleep 30")
    let start = Date()
    if case .broken = Gyroflow.check(override: hangs, timeout: 1) {} else { expect(false, "hanging --version → broken") }
    expect(Date().timeIntervalSince(start) < 15, "hanging --version is cut off by the timeout")
    expect(GyroflowStatus.missing.problem?.contains("gyroflow.xyz") == true, "missing status explains what to do")
}

func testMapFile() {
    let root = scratchFolder("stabilize-map")
    var map = StabilizeMap(outputRoot: root)
    let video = makeVideo(url: root.appendingPathComponent("C0835.MP4"), relativePath: "C0835.MP4",
                          creationDate: "2025:10:26 14:10:41-08:00")
    let job = StabilizeJob(source: video, profile: .sLog3, stabilize: true, lut: URL(fileURLWithPath: "/l.cube"))
    map.record(ClipResult(job: job, output: nil, status: .failed("x")), stabilized: true)
    map.record(ClipResult(job: job, output: root.appendingPathComponent("C0835.mp4"), status: .done), stabilized: true)
    try? map.write()
    let reread = StabilizeMap(outputRoot: root)
    expect(reread.entries.count == 1, "one entry per original")
    let entry = reread.entries.first
    expect(entry?.status == "done" && entry?.creationDate == "2025:10:26 14:10:41-08:00"
           && entry?.detectedProfile == "sLog2" && entry?.usedProfile == "sLog3" && entry?.cameraModel == "ZV-E10"
           && entry?.lut == "/l.cube", "map keeps model, profiles, LUT and zoned date")
}

// MARK: Supervision

/// A shell script standing in for Gyroflow. What it does depends on the source file's name.
func writeFakeGyroflow(in folder: URL, sample: URL) -> URL {
    let script = folder.appendingPathComponent("gyroflow")
    let pidFile = folder.appendingPathComponent("killed.pid").path
    let grandchildPID = folder.appendingPathComponent("grandchild.pid").path
    let text = """
    #!/bin/bash
    if [ "$1" = "--version" ]; then echo "Gyroflow v9.9.9"; exit 0; fi
    src="$1"; params="$3"
    out=$(printf '%s' "$params" | sed -E 's/.*"output_path":"([^"]*)".*/\\1/')
    render() { cp '\(sample.path)' "$out.tmp"; echo "[x] Rendering progress: 24/24 frames (100%)"; mv "$out.tmp" "$out"; }
    case "$(basename "$src")" in
      exit0*) echo "[ERROR] something"; exit 0 ;;
      hang*) sleep 600 ;;
      noterm*) trap '' TERM; while :; do echo "[x] Rendering progress: 1/24 frames"; sleep 0.2; done ;;
      grandchild*) (trap '' TERM; exec sleep 30) & echo $! > '\(grandchildPID)'; render; exit 0 ;;
      killed*) echo $$ > '\(pidFile)'; echo "[x] Rendering progress: 1/24 frames"; sleep 600 ;;
      *) echo "[x] Rendering progress: 12/24 frames (50%)"; render; exit 0 ;;
    esac
    """
    try? text.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return script
}

func fastTiming() -> StabilizeTiming {
    var timing = StabilizeTiming()
    timing.stallTimeout = 2
    timing.quietAfter = 0.5
    timing.heartbeatInterval = 0.25
    timing.terminationGrace = 1
    timing.killGrace = 1
    timing.probeTimeout = 10
    return timing
}

func testSupervisionFaults(ffmpeg: URL) async {
    let folder = scratchFolder("stabilize-supervision")
    let sourceRoot = folder.appendingPathComponent("src")
    try? FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let sample = folder.appendingPathComponent("sample.mp4")
    guard makeClip(sample, ffmpeg: ffmpeg) else { expect(false, "could not make a synthetic clip"); return }
    let gyroflow = writeFakeGyroflow(in: folder, sample: sample)

    let names = ["exit0.MP4", "hang.MP4", "noterm.MP4", "grandchild.MP4", "killed.MP4", "ok.MP4"]
    let jobs = names.map { name -> StabilizeJob in
        let url = sourceRoot.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: sample, to: url)
        return StabilizeJob(source: makeVideo(url: url, relativePath: name, creationDate: "2025:10:26 14:10:41-08:00"),
                            profile: .sLog2, stabilize: true, lut: nil)
    }
    var settings = StabilizeSettings(sourceRoot: sourceRoot, outputRoot: folder.appendingPathComponent("out"))
    settings.gyroflow = gyroflow
    settings.timing = fastTiming()
    let engine = StabilizeEngine(settings: settings)
    let log = EventLog()
    let finishedAt = TimesBox()
    let pidFile = folder.appendingPathComponent("killed.pid")
    log.onEvent = { event in
        switch event {
        case .clipStarted(_, _, let name):
            finishedAt.mark("start-\(name)")
            if name == "noterm" {
                // Busy but ignoring SIGTERM: 跳过这段 must still end it via SIGKILL.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { engine.skipCurrent() }
            }
            if name == "killed" {
                // Killed by someone else mid-render.
                DispatchQueue.global().async {
                    for _ in 0..<100 {
                        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Thread.sleep(forTimeInterval: 0.3)
                            kill(pid, SIGKILL)
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
            }
        case .clipFinished(let result):
            finishedAt.mark("end-\(result.job.source.url.deletingPathExtension().lastPathComponent)")
        default: break
        }
    }
    let start = Date()
    let summary = await engine.run(jobs) { log.record($0) }
    let elapsed = Date().timeIntervalSince(start)
    let byName = Dictionary(uniqueKeysWithValues: summary.results.map { ($0.job.source.url.deletingPathExtension().lastPathComponent, $0) })

    expect(summary.results.count == names.count && !summary.stopped, "every clip has a result, batch not stopped")
    if case .failed(let why)? = byName["exit0"]?.status {
        expect(why.contains("没有生成"), "exit 0 without output is a failure: \(why)")
    } else { expect(false, "exit 0 without output → failed, got \(String(describing: byName["exit0"]?.status))") }
    if case .skipped(let why)? = byName["hang"]?.status {
        expect(why.contains("卡住"), "silent hang → skipped as stuck: \(why)")
    } else { expect(false, "silent hang → skipped, got \(String(describing: byName["hang"]?.status))") }
    expect(finishedAt.span("hang") < 8, "stall detected within the shortened timeout (\(finishedAt.span("hang")) s)")
    if case .skipped(let why)? = byName["noterm"]?.status {
        expect(why.contains("跳过"), "skipCurrent marks it skipped: \(why)")
    } else { expect(false, "SIGTERM-ignoring child → skipped, got \(String(describing: byName["noterm"]?.status))") }
    let noterm = finishedAt.span("noterm")
    expect(noterm >= 1.9 && noterm < 8, "SIGTERM ignored, SIGKILL after the grace period (\(noterm) s)")
    expect(byName["grandchild"]?.status == .done, "grandchild holding stdout does not block a finished render: \(String(describing: byName["grandchild"]?.status))")
    expect(finishedAt.span("grandchild") < 6, "grandchild case finishes promptly (\(finishedAt.span("grandchild")) s)")
    if let text = try? String(contentsOf: folder.appendingPathComponent("grandchild.pid"), encoding: .utf8),
       let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        expect(kill(pid, 0) != 0, "lingering grandchild was killed with its group")
    } else { expect(false, "fake grandchild recorded its PID") }
    if case .failed(let why)? = byName["killed"]?.status {
        expect(why.contains("信号 9"), "externally killed → failed, naming the signal: \(why)")
    } else { expect(false, "externally killed → failed, got \(String(describing: byName["killed"]?.status))") }
    expect(byName["ok"]?.status == .done, "a later clip still succeeds after failures")
    expect(elapsed < 40, "whole fault batch runs in seconds (\(Int(elapsed)) s)")
    expect(log.quietCount > 0, "quiet events emitted while the child was silent")
    expect(log.progressValues.contains { $0 > 0 && $0 < 1 }, "fractional progress reported")

    let out = settings.outputRoot
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
    expect(!leftovers.contains { $0.hasPrefix(".") && $0.contains("lighttable") }, "no temp files left: \(leftovers)")
    expect(leftovers.contains("ok.mp4") && !leftovers.contains("exit0.mp4"), "only good outputs are final: \(leftovers)")

    // 对照表 lists every clip.
    let map = StabilizeMap(outputRoot: out)
    expect(map.entries.count == names.count, "对照表 has every clip (\(map.entries.count))")
    expect(map.entries.first { $0.original.hasSuffix("ok.MP4") }?.status == "done", "对照表 marks the good clip done")

    // Creation date written back.
    if let exiftool = Tools.find(.exiftool),
       let result = shell(exiftool, ["-s", "-s", "-s", "-QuickTime:CreationDate", out.appendingPathComponent("ok.mp4").path]) {
        expect(result.stdout.contains("2025:10:26 14:10:41-08:00"), "zoned creation date written: \(result.stdout)")
    }

    // Resume: the finished clip is not redone; a hand-made bad final is redone.
    try? Data("junk".utf8).write(to: out.appendingPathComponent("grandchild.mp4"))
    let again = await engine.run([jobs[5], jobs[3]]) { _ in }
    expect(again.results.first?.status == .alreadyDone, "validated final is skipped on resume")
    expect(again.results.last?.status == .done, "an invalid final is rendered again")
}

final class TimesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: Date] = [:]
    func mark(_ key: String) { lock.withLock { marks[key] = Date() } }
    func span(_ name: String) -> TimeInterval {
        lock.withLock {
            guard let start = marks["start-\(name)"], let end = marks["end-\(name)"] else { return .infinity }
            return end.timeIntervalSince(start)
        }
    }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var flag: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

func testStopAndPause(ffmpeg: URL) async {
    let folder = scratchFolder("stabilize-stop")
    let sourceRoot = folder.appendingPathComponent("src")
    try? FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let sample = folder.appendingPathComponent("sample.mp4")
    guard makeClip(sample, ffmpeg: ffmpeg) else { return }
    let gyroflow = writeFakeGyroflow(in: folder, sample: sample)
    func job(_ name: String) -> StabilizeJob {
        let url = sourceRoot.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: sample, to: url)
        return StabilizeJob(source: makeVideo(url: url, relativePath: name), profile: .sLog2, stabilize: true, lut: nil)
    }

    // stop() while a child hangs: the batch ends, stopped, temp files gone.
    var settings = StabilizeSettings(sourceRoot: sourceRoot, outputRoot: folder.appendingPathComponent("out"))
    settings.gyroflow = gyroflow
    settings.timing = fastTiming()
    settings.timing.stallTimeout = 60
    let engine = StabilizeEngine(settings: settings)
    let log = EventLog()
    log.onEvent = { event in
        if case .clipStarted(_, _, "hang2") = event {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { engine.stop() }
        }
    }
    let start = Date()
    let summary = await engine.run([job("ok1.MP4"), job("hang2.MP4"), job("ok3.MP4")]) { log.record($0) }
    expect(summary.stopped, "stop() ends the batch with stopped: true")
    expect(Date().timeIntervalSince(start) < 10, "stop resolves quickly")
    expect(summary.results.count == 2 && summary.results[0].status == .done, "clips before the stop keep their result")
    expect(!FileManager.default.fileExists(atPath: settings.outputRoot.appendingPathComponent("ok3.mp4").path), "clips after the stop are not started")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: settings.outputRoot.path)) ?? []
    expect(!leftovers.contains { $0.contains("lighttable-partial") }, "stop cleans temp files: \(leftovers)")

    // Too little space: pause, then resume once space is back.
    let roomy = FlagBox()
    var pauseSettings = settings
    pauseSettings.outputRoot = folder.appendingPathComponent("out-pause")
    pauseSettings.freeSpaceProbe = { _ in roomy.flag ? 1 << 40 : 1 << 20 }
    let pausing = StabilizeEngine(settings: pauseSettings)
    let pauseLog = EventLog()
    pauseLog.onEvent = { event in
        if case .paused = event {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                roomy.flag = true
                pausing.resume()
            }
        }
    }
    let paused = await pausing.run([job("ok4.MP4")]) { pauseLog.record($0) }
    expect(pauseLog.pausedCount == 1 && pauseLog.resumedCount == 1, "short space pauses once and resumes (\(pauseLog.pausedCount)/\(pauseLog.resumedCount))")
    if case .paused(let reason)? = pauseLog.events.first(where: { if case .paused = $0 { true } else { false } }) {
        expect(reason.contains("空间不够"), "pause reason explains space: \(reason)")
    }
    expect(paused.results.first?.status == .done, "clip completes after resume")

    // stop() while paused ends the batch.
    var stuckSettings = pauseSettings
    stuckSettings.outputRoot = folder.appendingPathComponent("out-stuck")
    stuckSettings.freeSpaceProbe = { _ in 0 }
    let stuck = StabilizeEngine(settings: stuckSettings)
    let stuckLog = EventLog()
    stuckLog.onEvent = { event in
        if case .paused = event { DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { stuck.stop() } }
    }
    let stuckSummary = await stuck.run([job("ok5.MP4"), job("ok6.MP4")]) { stuckLog.record($0) }
    expect(stuckSummary.stopped && stuckSummary.results.count == 1, "stop() while paused ends the batch")

    // Skip reasons for jobs with nothing to do.
    let noGyro = makeVideo(url: sourceRoot.appendingPathComponent("ok1.MP4"), relativePath: "ok1.MP4", gyro: nil)
    let skipping = StabilizeEngine(settings: settings)
    let skipped = await skipping.run([
        StabilizeJob(source: noGyro, profile: .rec709, stabilize: true, lut: nil),
        StabilizeJob(source: noGyro, profile: .rec709, stabilize: false, lut: nil),
    ]) { _ in }
    if case .skipped(let why)? = skipped.results.first?.status { expect(why.contains("陀螺仪"), "no gyro + no LUT explains why: \(why)") } else { expect(false, "no gyro, no LUT → skipped") }
    if case .skipped(let why)? = skipped.results.last?.status { expect(why.contains("没有选增稳"), "nothing selected explains why: \(why)") } else { expect(false, "nothing selected → skipped") }
}

// MARK: End to end

func testLUTOnlyEndToEnd(ffmpeg: URL) async {
    let folder = scratchFolder("stabilize-lut-only")
    let sourceRoot = folder.appendingPathComponent("src/day1")
    try? FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let clip8 = sourceRoot.appendingPathComponent("flat.MOV")
    let clip10 = sourceRoot.appendingPathComponent("flat10.MP4")
    guard makeClip(clip8, ffmpeg: ffmpeg), makeClip(clip10, ffmpeg: ffmpeg, tenBit: true) else {
        expect(false, "could not make synthetic clips"); return
    }
    let halveGreen = folder.appendingPathComponent("halve green.cube")
    writeCube(halveGreen) { r, g, _ in (r, g / 2, 0) }
    let identity = folder.appendingPathComponent("identity.cube")
    writeCube(identity) { ($0, $1, $2) }

    let root = folder.appendingPathComponent("src")
    var settings = StabilizeSettings(sourceRoot: root, outputRoot: folder.appendingPathComponent("LightTable 增稳"))
    settings.bitrateMbps = 8
    settings.gyroflow = folder.appendingPathComponent("no-gyroflow")
    let engine = StabilizeEngine(settings: settings)
    let video8 = makeVideo(url: clip8, relativePath: "day1/flat.MOV", gyro: nil, profile: .rec709)
    let video10 = makeVideo(url: clip10, relativePath: "day1/flat10.MP4", gyro: nil, profile: .rec709)
    let summary = await engine.run([
        StabilizeJob(source: video8, profile: .rec709, stabilize: true, lut: halveGreen),
        StabilizeJob(source: video10, profile: .rec709, stabilize: false, lut: identity),
    ]) { _ in }
    let out8 = settings.outputRoot.appendingPathComponent("day1/flat.mp4")
    let out10 = settings.outputRoot.appendingPathComponent("day1/flat10.mp4")
    expect(summary.results.map(\.status) == [.done, .done], "LUT-only runs without Gyroflow: \(summary.results.map(\.status))")
    expect(summary.outputsByOriginal[clip8] == out8, "output path mirrors the source tree")

    let json8 = probeJSON(out8)
    let video = streams(json8, "video").first ?? [:]
    expect(video["codec_name"] as? String == "hevc" && video["pix_fmt"] as? String == "yuv420p", "8-bit source → 8-bit HEVC")
    expect(video["color_primaries"] as? String == "bt709" && video["color_transfer"] as? String == "bt709"
           && video["color_space"] as? String == "bt709" && video["color_range"] as? String == "tv", "graded output tagged BT.709 limited: \(video)")
    expect(!streams(json8, "audio").isEmpty, "audio kept")
    expect(abs(duration(json8) - 1) < 0.2, "duration kept")
    if let (r, g, b) = centerRGBFile(out8, ffmpeg: ffmpeg, folder: folder) {
        // README: flat (200,200,200) through halve-green / zero-blue gives (200,100,0).
        expect(near(r, 200, 4) && near(g, 100, 4) && near(b, 0, 4), "halve-green LUT gives ≈(200,100,0): (\(r), \(g), \(b))")
    } else { expect(false, "could not read graded pixels") }

    let json10 = probeJSON(out10)
    let video10Stream = streams(json10, "video").first ?? [:]
    expect(video10Stream["profile"] as? String == "Main 10" && (video10Stream["pix_fmt"] as? String)?.contains("10") == true,
           "10-bit source → HEVC Main10: \(video10Stream)")
    if let (r, g, b) = centerRGBFile(out10, ffmpeg: ffmpeg, folder: folder) {
        expect(near(r, 200, 4) && near(g, 200, 4) && near(b, 200, 4), "identity LUT keeps levels: (\(r), \(g), \(b))")
    }

    // Same settings again → already done; another LUT → redone with the new look.
    let again = await StabilizeEngine(settings: settings).run([
        StabilizeJob(source: video8, profile: .rec709, stabilize: true, lut: halveGreen),
    ]) { _ in }
    expect(again.results.map(\.status) == [.alreadyDone], "unchanged settings reuse the final: \(again.results.map(\.status))")
    let changed = await StabilizeEngine(settings: settings).run([
        StabilizeJob(source: video8, profile: .rec709, stabilize: true, lut: identity),
    ]) { _ in }
    expect(changed.results.map(\.status) == [.done], "a different LUT re-renders: \(changed.results.map(\.status))")
    if let (r, g, b) = centerRGBFile(out8, ffmpeg: ffmpeg, folder: folder) {
        expect(near(r, 200, 4) && near(g, 200, 4) && near(b, 200, 4), "re-render uses the new LUT: (\(r), \(g), \(b))")
    }

    // A stop() that lands before run() starts still stops the batch.
    let early = StabilizeEngine(settings: settings)
    early.stop()
    let stoppedEarly = await early.run([StabilizeJob(source: video10, profile: .rec709, stabilize: false, lut: halveGreen)]) { _ in }
    expect(stoppedEarly.stopped, "stop before run is honoured")
}

func testLUTPreview(ffmpeg: URL) async {
    let folder = scratchFolder("stabilize-preview")
    let luts = folder.appendingPathComponent("luts/sub")
    try? FileManager.default.createDirectory(at: luts, withIntermediateDirectories: true)
    let halve = luts.appendingPathComponent("b halve.cube")
    writeCube(halve) { r, g, _ in (r, g / 2, 0) }
    writeCube(folder.appendingPathComponent("luts/a.CUBE")) { ($0, $1, $2) }
    try? Data().write(to: folder.appendingPathComponent("luts/readme.txt"))
    let listed = LUTPreview.listLUTs(in: folder.appendingPathComponent("luts"))
    expect(listed.map(\.lastPathComponent) == ["a.CUBE", "b halve.cube"], "LUTs listed recursively and sorted: \(listed.map(\.lastPathComponent))")

    let clip = folder.appendingPathComponent("clip.mp4")
    guard makeClip(clip, ffmpeg: ffmpeg) else { return }
    do {
        let frame = try await LUTPreview.extractFrame(from: clip, at: 0.5)
        let again = try await LUTPreview.extractFrame(from: clip, at: 0.5)
        expect(frame == again, "frame cached")
        let info = streams(probeJSON(frame), "video").first ?? [:]
        expect(info["width"] as? Int == LUTPreview.frameWidth, "preview frame is \(LUTPreview.frameWidth) px wide")
        let graded = try await LUTPreview.grade(frame: frame, lut: halve)
        if let (r, g, b) = centerRGBFile(graded, ffmpeg: ffmpeg, folder: folder) {
            expect(near(r, 200, 4) && near(g, 100, 4) && near(b, 0, 4), "preview grade matches the render: (\(r), \(g), \(b))")
        } else { expect(false, "could not read preview pixels") }
    } catch {
        expect(false, "preview failed: \(error.localizedDescription)")
    }
}

/// One stabilise + LUT run on a copy of the real ZV-E10 clip. About a minute: Gyroflow falls
/// back to the CPU inside the sandbox.
func testRealClip() async {
    let original = sampleClip
    guard FileManager.default.fileExists(atPath: original.path), case .ready = Gyroflow.check() else {
        print("stabilize: real clip or Gyroflow missing, skipping the real-clip run")
        return
    }
    print("stabilize: real ZV-E10 clip, stabilise + LUT (about a minute)")
    let folder = scratchFolder("stabilize-real")
    let sourceRoot = folder.appendingPathComponent("card")
    try? FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let copy = sourceRoot.appendingPathComponent("C0835.MP4")
    try? FileManager.default.copyItem(at: original, to: copy)
    guard let scan = try? await MediaScanner.scan(sourceRoot), let video = scan.videos.first else {
        expect(false, "scan of the real clip failed"); return
    }
    expect(video.canStabilize && video.detectedProfile == .sLog2, "real clip: rtmd track and S-Log2 detected")
    // A gentle lift so the LUT is visibly applied but simple to reason about.
    let lut = folder.appendingPathComponent("lift.cube")
    writeCube(lut) { r, g, b in (0.1 + 0.9 * r, 0.1 + 0.9 * g, 0.1 + 0.9 * b) }

    let settings = StabilizeSettings(sourceRoot: sourceRoot, outputRoot: sourceRoot.appendingPathComponent("LightTable 增稳"))
    let engine = StabilizeEngine(settings: settings)
    let log = EventLog()
    let start = Date()
    let summary = await engine.run([StabilizeJob(source: video, profile: .sLog2, stabilize: true, lut: lut)]) { log.record($0) }
    let elapsed = Date().timeIntervalSince(start)
    let result = summary.results.first
    expect(result?.status == .done, "real clip done: \(String(describing: result?.status))")
    guard let output = result?.output else { return }
    let json = probeJSON(output)
    let videoStream = streams(json, "video").first ?? [:]
    let audio = streams(json, "audio")
    print("  real clip: \(String(format: "%.1f", elapsed)) s, \(output.lastPathComponent) \(String(format: "%.3f", duration(json))) s (source \(video.duration) s), "
          + "\(videoStream["codec_name"] ?? "?") \(videoStream["profile"] ?? "?") \(videoStream["pix_fmt"] ?? "?") \(videoStream["width"] ?? "?")x\(videoStream["height"] ?? "?"), "
          + "tags \(videoStream["color_range"] ?? "?")/\(videoStream["color_space"] ?? "?")/\(videoStream["color_primaries"] ?? "?")/\(videoStream["color_transfer"] ?? "?"), "
          + "audio \(audio.first?["codec_name"] ?? "none"), \((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes")
    expect(abs(duration(json) - video.duration) < 1, "real clip duration within 1 s")
    expect(!audio.isEmpty, "real clip keeps audio")
    expect(videoStream["color_primaries"] as? String == "bt709" && videoStream["color_transfer"] as? String == "bt709"
           && videoStream["color_space"] as? String == "bt709" && videoStream["color_range"] as? String == "tv", "real clip tagged BT.709 limited")
    expect(videoStream["pix_fmt"] as? String == "yuv420p", "8-bit ZV-E10 → 8-bit output")
    expect(log.progressValues.contains { $0 > 0.1 && $0 < 0.9 }, "real clip reports intermediate progress")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)) ?? []
    // The hidden recipe records which settings made the result; staging and temp files must be gone.
    expect(Set(leftovers) == [".C0835.mp4.recipe", "C0835.mp4", "对照表.json"], "only the result, its recipe and the map remain: \(leftovers)")
    if let exiftool = Tools.find(.exiftool), let date = video.creationDate,
       let read = shell(exiftool, ["-s", "-s", "-s", "-QuickTime:CreationDate", output.path]) {
        print("  creation date: source \(date), output \(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        expect(read.stdout.contains(date), "real clip creation date written back (\(date))")
    }
}
