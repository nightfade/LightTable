import AppKit
import SwiftUI

struct RunView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.folder?.lastPathComponent ?? "").font(.title.bold())

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("总进度").fontWeight(.medium)
                    Spacer()
                    Text("\(Int(model.overallProgress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: model.overallProgress)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(TaskKind.allCases.filter(model.selected.contains)) { kind in
                    HStack(spacing: 10) {
                        stateIcon(kind).frame(width: 18)
                        Text(kind.title).fontWeight(kind == model.currentTask ? .semibold : .regular)
                        if kind == model.currentTask {
                            Text(model.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        } else if let report = model.reports.first(where: { $0.kind == kind }) {
                            Text(report.lines.first ?? "").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }

            if let quiet = model.quiet {
                VStack(alignment: .leading, spacing: 8) {
                    Label("「\(quiet.name)」似乎卡住了，已经 \(quiet.seconds / 60) 分 \(quiet.seconds % 60) 秒没有进展。",
                          systemImage: "hourglass")
                    Text("没人管的话，到时间会自动跳过这段，继续后面的。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("跳过这段") { model.skipCurrentClip() }
                        Button("再等等") { model.waitLonger() }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            if let reason = model.pausedReason {
                VStack(alignment: .leading, spacing: 8) {
                    Label("已暂停：\(reason)", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                    HStack {
                        Button("继续") { model.resume() }.buttonStyle(.borderedProminent)
                        Button("停止") { model.stop() }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            Spacer()
            HStack {
                Text("可以关掉这个窗口，处理会在后台继续，菜单栏有进度。处理期间电脑不会自动睡眠。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.stopping ? "正在停止…" : "停止") { model.stop() }
                    .disabled(model.stopping)
                    .controlSize(.large)
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private func stateIcon(_ kind: TaskKind) -> some View {
        if kind == model.currentTask {
            ProgressView().controlSize(.small)
        } else if let report = model.reports.first(where: { $0.kind == kind }) {
            ReportIcon(status: report.status)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

struct ReportIcon: View {
    let status: TaskReport.Status

    var body: some View {
        switch status {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct ResultView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(headline).font(.title.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.reports) { report in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    ReportIcon(status: report.status)
                                    Text(report.kind.title).font(.headline)
                                    Spacer()
                                    if let url = report.openURL, let label = report.openLabel,
                                       FileManager.default.fileExists(atPath: url.path) {
                                        Button(label) { NSWorkspace.shared.open(url) }
                                    }
                                }
                                ForEach(report.lines, id: \.self) { line in
                                    Text(line).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack {
                Button("导出诊断信息…") { model.exportDiagnostics() }
                    .help("把这次的运行记录打包成一个 zip，出问题时发给帮你看的人")
                if let log = model.log {
                    Button("查看运行记录") { NSWorkspace.shared.open(log.file) }
                }
                Spacer()
                Button("重新处理（已完成的会跳过）") { model.stage = .plan }
                Button("换一个文件夹") { model.backToHome() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }

    private var headline: String {
        if model.reports.contains(where: { $0.status == .stopped }) { return "已停止" }
        if model.reports.contains(where: { $0.status == .failed || $0.status == .partial }) { return "做完了，有一些问题" }
        return "全部完成"
    }
}
