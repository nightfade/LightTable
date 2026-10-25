import AppKit
import LightTableKit
import SwiftUI

/// Development aid: `LIGHTTABLE_SNAPSHOT=<out dir> LIGHTTABLE_SNAPSHOT_FOLDER=<footage>` renders
/// each screen to PNG offscreen and exits, so layouts can be checked without a window or
/// screen-recording permission.
enum Snapshot {
    @MainActor
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let out = environment["LIGHTTABLE_SNAPSHOT"], let footage = environment["LIGHTTABLE_SNAPSHOT_FOLDER"] else { return }
        let outFolder = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: footage, isDirectory: true)

        let box = ScanBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = try? await MediaScanner.scan(folder)
            done.signal()
        }
        done.wait()

        let model = AppModel()
        model.leftovers = []
        render(RootView().environmentObject(model), "1-home", outFolder)
        model.folder = folder
        if let result = box.result { model.applyScan(result) }
        render(RootView().environmentObject(model), "2-plan", outFolder)
        if let luts = environment["LIGHTTABLE_SNAPSHOT_LUTS"] { Preferences.lutFolder = URL(fileURLWithPath: luts) }
        if let group = model.groups.first {
            // Thumbnails are graded asynchronously by ffmpeg; give them time.
            render(LUTPickerView(profile: group.profile).environmentObject(model), "3-lut-picker", outFolder,
                   size: CGSize(width: 860, height: 720), settle: 12)
        }
        model.stage = .running
        model.currentTask = .stabilize
        model.overallProgress = 0.37
        model.detail = "增稳调色 12/32：C0835.MP4"
        model.quiet = ("C0835.MP4", 245)
        render(RootView().environmentObject(model), "4-running", outFolder)
        model.quiet = nil
        model.stage = .finished
        model.reports = [
            TaskReport(kind: .stabilize, status: .partial, lines: ["完成 31 段", "Day2/C0901.MP4：失败：Gyroflow 处理超时，已跳过"], openURL: folder, openLabel: "打开增稳后的视频"),
            TaskReport(kind: .highlights, status: .success, lines: ["从 47 段视频中挑出 18 段高光"], openURL: folder, openLabel: "打开高光片段"),
            TaskReport(kind: .photos, status: .success, lines: ["1840 张照片分成 612 组", "在 Bridge 里按创建日期排序，一组一组看"], openURL: folder, openLabel: "打开照片文件夹"),
        ]
        render(RootView().environmentObject(model), "5-results", outFolder)
        exit(0)
    }

    @MainActor
    private static func render<V: View>(_ view: V, _ name: String, _ folder: URL, size: CGSize = CGSize(width: 760, height: 700), settle: TimeInterval = 0.4) {
        // NSHostingView draws real AppKit controls; ImageRenderer shows placeholders for them.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}

private final class ScanBox: @unchecked Sendable {
    var result: ScanResult?
}
