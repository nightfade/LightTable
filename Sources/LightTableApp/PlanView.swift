import LightTableKit
import Stabilize
import SwiftUI
import TravelCutCore

struct PlanView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    summary
                    ForEach(TaskKind.allCases) { kind in
                        if isAvailable(kind) { TaskCard(kind: kind) }
                    }
                }
                .padding(24)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .sheet(item: Binding(
            get: { model.lutPickerGroup.map(PickerTarget.init) },
            set: { model.lutPickerGroup = $0?.profile }
        )) { target in
            LUTPickerView(profile: target.profile).environmentObject(model)
        }
    }

    private var header: some View {
        HStack {
            Button { model.backToHome() } label: { Label("换一个文件夹", systemImage: "chevron.left") }
                .buttonStyle(.link)
            Spacer()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.folder?.lastPathComponent ?? "").font(.title.bold())
            if let scan = model.scan {
                ForEach(cameraLines(scan), id: \.self) { line in
                    Label(line, systemImage: "video").foregroundStyle(.secondary)
                }
                if !scan.photos.isEmpty {
                    Label("照片 \(scan.photos.count) 张", systemImage: "photo").foregroundStyle(.secondary)
                }
                if !scan.unreadable.isEmpty {
                    Label("\(scan.unreadable.count) 个视频读不出来，会跳过", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                if let blocker = model.blocker {
                    Text(blocker).foregroundStyle(.orange)
                } else {
                    Text("会按顺序做：\(TaskKind.allCases.filter(model.selected.contains).map(\.title).joined(separator: " → "))")
                        .foregroundStyle(.secondary)
                }
                if let note = model.downloadNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.start() } label: {
                Label("开始", systemImage: "play.fill").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.blocker != nil)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func isAvailable(_ kind: TaskKind) -> Bool {
        guard let scan = model.scan else { return false }
        switch kind {
        case .stabilize, .highlights: return !scan.videos.isEmpty
        case .habits, .photos: return !scan.photos.isEmpty
        }
    }

    /// "ZV-E10 视频 32 段（可增稳，S-Log2 28 段）"
    private func cameraLines(_ scan: ScanResult) -> [String] {
        let byCamera = Dictionary(grouping: scan.videos) { $0.cameraModel ?? "其他相机" }
        return byCamera.sorted { $0.value.count > $1.value.count }.map { camera, videos in
            var notes: [String] = []
            let gyro = videos.filter(\.canStabilize).count
            if gyro == videos.count { notes.append("可增稳") } else if gyro > 0 { notes.append("\(gyro) 段可增稳") }
            for (profile, count) in Dictionary(grouping: videos, by: model.effectiveProfile).mapValues(\.count)
                .sorted(by: { $0.value > $1.value }) where profile != .rec709 {
                notes.append("\(profile.displayName) \(count) 段")
            }
            return "\(camera) 视频 \(videos.count) 段" + (notes.isEmpty ? "" : "（\(notes.joined(separator: "，"))）")
        }
    }
}

private struct PickerTarget: Identifiable {
    let profile: ColorProfile
    var id: String { profile.rawValue }
}

struct TaskCard: View {
    @EnvironmentObject var model: AppModel
    let kind: TaskKind

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.selected.contains(kind) },
                    set: { if $0 { model.selected.insert(kind) } else { model.selected.remove(kind) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(kind.title, systemImage: kind.systemImage).font(.headline)
                        Text(kind.summary).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if model.selected.contains(kind) {
                    switch kind {
                    case .stabilize: StabilizeOptions()
                    case .highlights: HighlightOptions()
                    case .habits: EmptyView()
                    case .photos: PhotoOptions()
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StabilizeOptions: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var disclosure = DisclosureState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if (model.scan?.stabilizableCount ?? 0) > 0 {
                Toggle("增稳（\(model.scan?.stabilizableCount ?? 0) 段带陀螺仪数据）", isOn: $model.stabilizeOn)
                if model.stabilizeOn && !model.gyroflowReady { GyroflowGuide() }
            } else {
                Text("这些视频没有陀螺仪数据，只能调色。").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("调色（给每种画面选一个色调）", isOn: $model.gradeOn)
            if model.gradeOn {
                VStack(spacing: 8) {
                    ForEach(model.groups) { group in GroupRow(group: group) }
                }
                .padding(.leading, 20)
            }
            DisclosureGroup("高级", isExpanded: $disclosure.expanded) {
                Form {
                    OptionalNumberField(title: "最大裁切（缩放百分比，117.6 ≈ 裁 15%）", value: $model.maxZoom, placeholder: "Gyroflow 默认")
                    OptionalNumberField(title: "果冻效应校正：读出时间（毫秒）", value: $model.readoutTime, placeholder: "关闭")
                    Text("读出时间填错会让画面更歪；不确定就留空。").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
        .padding(.leading, 22)
    }
}

struct GroupRow: View {
    @EnvironmentObject var model: AppModel
    let group: ProfileGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.profile.displayName) · \(group.videos.count) 段").fontWeight(.medium)
                if group.profile == .unknown {
                    ForEach(group.models, id: \.self) { model in UnknownAssignRow(model: model) }
                }
            }
            Spacer()
            Text(choiceText)
                .foregroundStyle(group.choice == .undecided ? .orange : .secondary)
                .lineLimit(1).truncationMode(.middle)
            Button("选择色调…") { model.lutPickerGroup = group.profile }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private var choiceText: String {
        switch group.choice {
        case .undecided: "还没选"
        case .none: group.profile.isLog ? "不调色（画面会发灰）" : "不调色"
        case .lut(let url): url.deletingPathExtension().lastPathComponent
        }
    }
}

struct UnknownAssignRow: View {
    @EnvironmentObject var app: AppModel
    let model: String

    var body: some View {
        HStack {
            Text("\(model) 拍的是：").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { ColorProfile.unknown },
                set: { app.assign(model: model, to: $0) }
            )) {
                Text("请选择").tag(ColorProfile.unknown)
                ForEach(ColorProfile.allCases.filter { $0 != .unknown }) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .controlSize(.small)
        }
    }
}

struct GyroflowGuide: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.gyroflow {
            case .appStore:
                Label("你装的是 App Store 版 Gyroflow，它不能被其他程序调用。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("请先删掉它，再从官网下载安装。")
            case .broken(_, let detail):
                Label("Gyroflow 打不开：\(detail)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("请从官网重新下载安装。")
            default:
                Label("增稳需要免费软件 Gyroflow，还没有安装。", systemImage: "info.circle.fill").foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("1. 点下面的按钮打开官网，下载 macOS 版（.dmg）")
                Text("2. 打开下载的文件，把 Gyroflow 拖进「应用程序」")
                Text("3. 回到这里点「重新检测」")
            }
            .font(.callout)
            HStack {
                Button("打开 Gyroflow 官网") { NSWorkspace.shared.open(URL(string: "https://gyroflow.xyz/download")!) }
                Button("重新检测") { model.refreshGyroflow() }
            }
            Text("不装也可以：取消「增稳」，只调色或只挑高光。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}

struct HighlightOptions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("想保留的内容").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.themes.count == HighlightTheme.allCases.count ? "全不选" : "全选") {
                    model.themes = model.themes.count == HighlightTheme.allCases.count ? [] : HighlightTheme.defaultSelection
                }
                .buttonStyle(.link)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(HighlightTheme.allCases) { theme in
                    ThemeChip(title: theme.rawValue, selected: model.themes.contains(theme)) {
                        if model.themes.contains(theme) { model.themes.remove(theme) } else { model.themes.insert(theme) }
                    }
                }
            }
            if model.selected.contains(.stabilize) {
                Text("会从增稳调色后的视频里挑；没增稳的视频用原片。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 22)
    }
}

/// A selectable chip whose state is visible at a glance: filled check and tint when chosen.
struct ThemeChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PhotoOptions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("会把分组和关键字写进照片：RAW 写旁边的 .xmp，JPEG/HEIC 写进文件元数据，像素不动，不动你已有的星级。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("用 Qwen 给每组写一句内容标签（照片多时要好几个小时）", isOn: $model.photoUseQwen)
            Toggle("同时写入星级（每组代表 3 星，不代表好坏）", isOn: $model.photoWriteStars)
            Toggle("在线查询更精确的地点（会把照片坐标发送给 Apple）", isOn: $model.photoOnlinePlaces)
            Toggle("试运行：只生成报告，不写入照片", isOn: $model.photoDryRun)
        }
        .font(.callout)
        .padding(.leading, 22)
    }
}

struct OptionalNumberField: View {
    let title: String
    @Binding var value: Double?
    let placeholder: String

    var body: some View {
        TextField(title, text: Binding(
            get: { value.map { String(format: "%g", $0) } ?? "" },
            set: { value = Double($0.trimmingCharacters(in: .whitespaces)) }
        ), prompt: Text(placeholder))
    }
}

@MainActor
private final class DisclosureState: ObservableObject {
    @Published var expanded = false
}
