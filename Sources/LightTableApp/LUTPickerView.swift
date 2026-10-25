import AppKit
import LightTableKit
import Stabilize
import SwiftUI

/// Thumbnail wall for one profile group: the same frame from this group's footage graded with
/// every LUT in the library. The LUT used last time for this profile is marked, never preselected.
struct LUTPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: ColorProfile

    @StateObject private var state = PickerState()

    private var group: ProfileGroup? { model.groups.first { $0.profile == profile } }
    private var lastUsed: URL? { Preferences.lastLUT(for: profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("给「\(profile.displayName)」选一个色调").font(.title2.bold())
                    Text(profile.isLog ? "灰片要套一个色调才会恢复正常的颜色。点一个看着顺眼的。" : "可以保持原样，也可以套一个风格色调。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let group, group.videos.count > 1 {
                    Button("换一个样张") {
                        state.sampleIndex = (state.sampleIndex + 1) % group.videos.count
                        Task { await loadFrame() }
                    }
                }
                Button(state.library == nil ? "选择色调文件夹…" : "换色调文件夹…") { chooseLibrary() }
            }

            if state.library == nil {
                emptyLibrary
            } else {
                preview.frame(height: 300)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        tile(title: "不调色", image: state.frame.flatMap { NSImage(contentsOf: $0) }, selected: state.choice == .none, badge: nil) {
                            state.choice = .none
                        }
                        ForEach(state.luts, id: \.self) { lut in
                            tile(title: lut.deletingPathExtension().lastPathComponent, image: state.graded[lut],
                                 selected: state.choice == .lut(lut), badge: lut == lastUsed ? "上次用的" : nil,
                                 isFailed: state.failed.contains(lut)) {
                                state.choice = .lut(lut)
                            }
                        }
                    }
                }
                if state.luts.isEmpty {
                    Text("这个文件夹里没有 .cube 色调文件。").foregroundStyle(.orange)
                }
            }
            if let loadError = state.loadError { Text(loadError).foregroundStyle(.orange) }

            HStack {
                if profile.isLog && state.choice == .none {
                    Label("不调色的话，成片会保持灰蒙蒙的样子。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("用这个") {
                    model.setChoice(state.choice, for: profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.choice == .undecided)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 860, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if let current = group?.choice, current != .undecided { state.choice = current }
            reloadLibrary()
            await loadFrame()
        }
        .onDisappear { state.gradingTask?.cancel() }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("先选一个放色调文件（.cube）的文件夹").font(.headline)
            Text("子文件夹里的也会列出来。以后会记住这个文件夹，可以随时更换。").foregroundStyle(.secondary)
            Button("选择文件夹…") { chooseLibrary() }.controlSize(.large)
            Button("这次不调色") {
                model.setChoice(.none, for: profile)
                dismiss()
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Before/after split of the chosen look; drag to move the state.divider.
    private var preview: some View {
        GeometryReader { geometry in
            let original = state.frame.flatMap { NSImage(contentsOf: $0) }
            let after: NSImage? = state.choice.url.flatMap { state.graded[$0] } ?? original
            ZStack(alignment: .leading) {
                if let original {
                    Image(nsImage: original).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    if let after {
                        Image(nsImage: after).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: geometry.size.width * (1 - state.divider))
                            }
                    }
                    Rectangle().fill(.white).frame(width: 2)
                        .offset(x: geometry.size.width * state.divider - 1)
                        .shadow(radius: 2)
                    // Captions last so the graded half does not cover them; sized like the image.
                    Color.clear.aspectRatio(original.size, contentMode: .fit)
                        .overlay(alignment: .topLeading) { caption("原片") }
                        .overlay(alignment: .topTrailing) {
                            caption(state.choice.url?.deletingPathExtension().lastPathComponent ?? "不调色")
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                } else {
                    ProgressView("正在取样张…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                state.divider = min(1, max(0, value.location.x / max(1, geometry.size.width)))
            })
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55)).foregroundStyle(.white).padding(6)
    }

    private func tile(title: String, image: NSImage?, selected: Bool, badge: String?, isFailed: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else if isFailed {
                            Image(systemName: "xmark.octagon").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 150, height: 84)
                    .clipped()
                    .background(Color.black.opacity(0.8))
                    if let badge {
                        Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white).padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .disabled(isFailed)
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "选择放色调文件（.cube）的文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.lutFolder = url
        state.library = url
        reloadLibrary()
        startGrading()
    }

    private func reloadLibrary() {
        guard let library = state.library else { state.luts = []; return }
        state.luts = LUTPreview.listLUTs(in: library)
        // Last used first, so it is visible without scrolling.
        if let lastUsed, let index = state.luts.firstIndex(of: lastUsed) { state.luts.insert(state.luts.remove(at: index), at: 0) }
    }

    private func loadFrame() async {
        guard let group, !group.videos.isEmpty else { return }
        let video = group.videos[min(state.sampleIndex, group.videos.count - 1)]
        state.frame = nil
        state.graded = [:]
        state.failed = []
        do {
            state.frame = try await LUTPreview.extractFrame(from: video.url, at: video.duration / 3)
            state.loadError = nil
            startGrading()
        } catch {
            state.loadError = "取不到样张：\(AppModel.explain(error))"
        }
    }

    private func startGrading() {
        state.gradingTask?.cancel()
        guard let frame = state.frame else { return }
        let pending = state.luts.filter { state.graded[$0] == nil && !state.failed.contains($0) }
        state.gradingTask = Task {
            // A few at a time: each is a short ffmpeg run.
            await withTaskGroup(of: (URL, NSImage?).self) { group in
                var iterator = pending.makeIterator()
                func add() {
                    guard let lut = iterator.next() else { return }
                    group.addTask {
                        let url = try? await LUTPreview.grade(frame: frame, lut: lut)
                        return (lut, url.flatMap { NSImage(contentsOf: $0) })
                    }
                }
                for _ in 0..<3 { add() }
                for await (lut, image) in group {
                    if Task.isCancelled { break }
                    if let image { state.graded[lut] = image } else { state.failed.insert(lut) }
                    add()
                }
            }
        }
    }
}

@MainActor
private final class PickerState: ObservableObject {
    @Published var library: URL? = Preferences.lutFolder
    @Published var luts: [URL] = []
    @Published var sampleIndex = 0
    @Published var frame: URL?
    @Published var graded: [URL: NSImage] = [:]
    @Published var failed: Set<URL> = []
    @Published var choice: LUTChoice = .undecided
    @Published var divider: CGFloat = 0.5
    @Published var loadError: String?
    var gradingTask: Task<Void, Never>?
}
