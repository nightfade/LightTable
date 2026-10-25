import AppKit
import SwiftUI

@main
struct LightTableApplication: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        Window("LightTable", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 640)
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentMinSize)

        // Closing the window does not stop a run; the menu bar shows progress and reopens it.
        MenuBarExtra(isInserted: .constant(model.isRunning)) {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: "camera.aperture")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(model?.isRunning ?? false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, MainActor.assumeIsolated({ model.isRunning }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还在处理，确定退出吗？"
        alert.informativeText = "退出会停止当前任务。已完成的部分会保留，下次开始时接着做。"
        alert.addButton(withTitle: "停止并退出")
        alert.addButton(withTitle: "继续处理")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated { model.stop() }
        // Give the children their SIGTERM → SIGKILL window before the process goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.currentTask?.title ?? "处理中") \(Int(model.overallProgress * 100))%")
        Text(model.detail).lineLimit(1)
        Divider()
        Button("打开 LightTable") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("停止") { model.stop() }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.stage {
            case .home: HomeView()
            case .scanning: ScanningView()
            case .plan: PlanView()
            case .running: RunView()
            case .finished: ResultView()
            }
        }
        .alert("上次的任务还有残留进程", isPresented: Binding(
            get: { !model.leftovers.isEmpty }, set: { if !$0 { model.leftovers = [] } }
        )) {
            Button("结束它们") { model.endLeftovers() }
            Button("不用管", role: .cancel) { model.leftovers = [] }
        } message: {
            Text("LightTable 上次退出时，有 \(model.leftovers.count) 个处理进程没有结束（\(model.leftovers.map { URL(fileURLWithPath: $0.executable).lastPathComponent }.joined(separator: "、"))），它们还在占用电脑。已完成的结果不受影响。")
        }
    }
}
