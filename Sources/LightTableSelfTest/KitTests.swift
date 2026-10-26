import Foundation
import LightTableKit

func runKitTests() async {
    testClassify()
    await testSupervisedProcess()
    testRegistry()
    await testScanner()
}

private func testClassify() {
    expect(MediaScanner.classify(gamma: "s-log2", transfer: nil, brand: "Sony") == .sLog2, "Sony XML s-log2")
    expect(MediaScanner.classify(gamma: "s-log3-cine", transfer: nil, brand: "Sony") == .sLog3, "Sony XML s-log3")
    expect(MediaScanner.classify(gamma: "rec709", transfer: nil, brand: "Sony") == .rec709, "Sony XML 709")
    expect(MediaScanner.classify(gamma: "hlg3", transfer: nil, brand: "Sony") == .hlg, "Sony XML HLG")
    expect(MediaScanner.classify(gamma: nil, transfer: "arib-std-b67", brand: "Apple") == .hlg, "iPhone HLG from stream tag")
    expect(MediaScanner.classify(gamma: nil, transfer: "smpte2084", brand: nil) == .pq, "PQ from stream tag")
    expect(MediaScanner.classify(gamma: nil, transfer: "bt709", brand: "Apple") == .rec709, "iPhone SDR")
    expect(MediaScanner.classify(gamma: nil, transfer: nil, brand: "Panasonic") == .unknown, "Panasonic without marker is unknown")
    expect(MediaScanner.classify(gamma: nil, transfer: nil, brand: "ZV-E10") == .unknown, "Sony clip without XML is unknown")
    expect(MediaScanner.classify(gamma: nil, transfer: nil, brand: nil) == .rec709, "unbranded defaults to 709")
    expect(MediaScanner.isOwnOutput("LightTable 高光 2"), "numbered highlight folders are skipped")
    expect(MediaScanner.isOwnOutput("TravelCut 高光片段 3"), "numbered TravelCut folders are skipped")
    expect(!MediaScanner.isOwnOutput("LightTable 高光片段素材"), "only exact or numbered names count")
}

private func script(_ name: String, _ body: String) -> URL {
    let url = scratchFolder("scripts-\(name)").appendingPathComponent("\(name).sh")
    try? "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    chmod(url.path, 0o755)
    return url
}

private func elapsed(_ work: () async -> Void) async -> TimeInterval {
    let start = Date()
    await work()
    return Date().timeIntervalSince(start)
}

private func testSupervisedProcess() async {
    // Normal exit with output and exit code.
    do {
        let process = SupervisedProcess(executable: script("ok", "echo hello; echo oops >&2; exit 3"), arguments: [])
        try process.start()
        let result = await process.wait()
        expect(result.ending == .finished(.exited(3)), "exit code is reported: \(result.ending)")
        expect(result.stdout == "hello\n", "stdout captured")
        expect(result.stderrTail == "oops", "stderr tail captured")
    } catch { expect(false, "start ok: \(error)") }

    // Silent hang → stalled and killed.
    do {
        var options = SupervisedProcess.Options(stallTimeout: 1.5)
        options.heartbeatInterval = 0.2
        let process = SupervisedProcess(executable: script("hang", "sleep 60"), arguments: [], options: options)
        try process.start()
        var result: SupervisedProcess.Result?
        let seconds = await elapsed { result = await process.wait() }
        if case .stalled? = result?.ending {} else { expect(false, "silent hang ends as stalled: \(String(describing: result?.ending))") }
        // SIGTERM must work (no wait for the 5 s SIGKILL fallback): stall 1.5 s + heartbeat + exit.
        expect(seconds < 4, "stall detected and SIGTERM honoured promptly (\(seconds) s)")
    } catch { expect(false, "start hang: \(error)") }

    // Ignores SIGTERM → SIGKILL after the grace period.
    do {
        var options = SupervisedProcess.Options()
        options.terminationGrace = 0.5
        options.heartbeatInterval = 0.2
        let process = SupervisedProcess(executable: script("stubborn", "trap '' TERM; while true; do sleep 1; done"), arguments: [], options: options)
        try process.start()
        try? await Task.sleep(nanoseconds: 300_000_000)
        process.stop()
        var result: SupervisedProcess.Result?
        let seconds = await elapsed { result = await process.wait() }
        if case .stopped(.signaled(SIGKILL)?) = result?.ending {} else { expect(false, "stubborn child is SIGKILLed: \(String(describing: result?.ending))") }
        expect(seconds < 4, "stop resolves quickly (\(seconds) s)")
    } catch { expect(false, "start stubborn: \(error)") }

    // Grandchild keeps stdout open after the parent exits: must not hang, and stop() reaches it.
    do {
        let marker = scratchFolder("grandchild").appendingPathComponent("pid")
        let process = SupervisedProcess(
            executable: script("grandchild", "sleep 30 & echo $! > '\(marker.path)'; echo parent-done; exit 0"), arguments: [])
        try process.start()
        var result: SupervisedProcess.Result?
        let seconds = await elapsed { result = await process.wait() }
        expect(result?.ending == .finished(.exited(0)), "parent exit is reported despite open pipe: \(String(describing: result?.ending))")
        expect(seconds < 3, "no wait for grandchild EOF (\(seconds) s)")
        if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(-process.processID, SIGKILL)
            kill(pid, SIGKILL)
        }
    } catch { expect(false, "start grandchild: \(error)") }

    // Killed from outside mid-run → reported, not left "running".
    do {
        let process = SupervisedProcess(executable: script("victim", "sleep 30"), arguments: [])
        try process.start()
        try? await Task.sleep(nanoseconds: 300_000_000)
        kill(process.processID, SIGKILL)
        let result = await process.wait()
        expect(result.ending == .finished(.signaled(SIGKILL)), "external kill is reported: \(result.ending)")
    } catch { expect(false, "start victim: \(error)") }

    // Stop also ends children of the child (whole process group).
    do {
        let marker = scratchFolder("group").appendingPathComponent("pid")
        var options = SupervisedProcess.Options()
        options.terminationGrace = 0.5
        let process = SupervisedProcess(
            executable: script("group", "sleep 30 & echo $! > '\(marker.path)'; wait"), arguments: [], options: options)
        try process.start()
        try? await Task.sleep(nanoseconds: 400_000_000)
        process.stop()
        _ = await process.wait()
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            expect(kill(pid, 0) != 0, "grandchild in the group was stopped too")
        } else {
            expect(false, "group test wrote its child pid")
        }
    } catch { expect(false, "start group: \(error)") }

    // Progress probe keeps a quiet process alive.
    do {
        let file = scratchFolder("probe").appendingPathComponent("out.bin")
        var options = SupervisedProcess.Options(stallTimeout: 1.0, progressProbe: {
            (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        })
        options.heartbeatInterval = 0.2
        let process = SupervisedProcess(
            executable: script("grow", "for i in 1 2 3 4 5 6 7 8 9 10; do head -c 1000 /dev/zero >> '\(file.path)'; sleep 0.3; done"),
            arguments: [], options: options)
        try process.start()
        let result = await process.wait()
        expect(result.ending == .finished(.exited(0)), "growing output counts as progress: \(result.ending)")
    } catch { expect(false, "start grow: \(error)") }

    // Hard timeout.
    do {
        var options = SupervisedProcess.Options(hardTimeout: 1)
        options.heartbeatInterval = 0.2
        let process = SupervisedProcess(executable: script("busy", "while true; do echo tick; sleep 0.1; done"), arguments: [], options: options)
        try process.start()
        let result = await process.wait()
        if case .timedOut = result.ending {} else { expect(false, "hard timeout applies even with output: \(result.ending)") }
    } catch { expect(false, "start busy: \(error)") }

    // Line callback splits on \r like Gyroflow and ffmpeg progress.
    do {
        let lines = LineBox()
        let process = SupervisedProcess(executable: script("cr", "printf 'a\\rb\\rc\\n'"), arguments: [])
        process.onLine = { _, line in lines.append(line) }
        try process.start()
        _ = await process.wait()
        expect(lines.all == ["a", "b", "c"], "lines split on CR: \(lines.all)")
    } catch { expect(false, "start cr: \(error)") }
}

private func testRegistry() {
    let file = scratchFolder("registry").appendingPathComponent("running.json")
    let registry = ProcessRegistry(file: file)
    // A dead PID with our executable recorded must not be reported.
    let stale = ProcessRegistry.Entry(pid: 999_999, executable: "/bin/sleep", startedAt: Date())
    try? JSONEncoder().encode([stale]).write(to: file)
    expect(registry.leftovers().isEmpty, "dead PIDs are dropped")
    // A live PID running a different program than recorded must not be reported (PID reuse).
    let reused = ProcessRegistry.Entry(pid: getpid(), executable: "/Applications/Gyroflow.app/Contents/MacOS/gyroflow", startedAt: Date())
    try? JSONEncoder().encode([reused]).write(to: file)
    expect(registry.leftovers().isEmpty, "reused PID running another program is ignored")
}

private func testScanner() async {
    let sample = sampleClip
    guard FileManager.default.fileExists(atPath: sample.path), Tools.find(.ffprobe) != nil else {
        print("kit: skipped scanner test (needs the sample clip, see LIGHTTABLE_SAMPLE_CLIP, and ffprobe)")
        return
    }
    let root = scratchFolder("scan")
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("Day1"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("LightTable 增稳"), withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: sample, to: root.appendingPathComponent("Day1/C0835.MP4"))
    try? FileManager.default.copyItem(at: sample, to: root.appendingPathComponent("LightTable 增稳/C0835.MP4"))
    try? Data().write(to: root.appendingPathComponent("Day1/DSC0001.ARW"))
    guard let result = try? await MediaScanner.scan(root) else { expect(false, "scan runs"); return }
    expect(result.videos.count == 1, "own output folder is skipped: \(result.videos.map(\.relativePath))")
    expect(result.photos.count == 1, "RAW counted as photo")
    if let video = result.videos.first {
        expect(video.relativePath == "Day1/C0835.MP4", "relative path")
        expect(video.gyroFormat == "rtmd", "Sony gyro track detected")
        expect(video.cameraModel == "ZV-E10", "model from XML: \(String(describing: video.cameraModel))")
        expect(video.detectedProfile == .sLog2, "S-Log2 from XML: \(video.detectedProfile)")
        expect(video.creationDate?.hasSuffix("-08:00") == true, "zoned creation date: \(String(describing: video.creationDate))")
        expect(video.width == 3840 && video.height == 2160, "size")
        expect(abs(video.frameRate - 23.976) < 0.01, "frame rate")
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
