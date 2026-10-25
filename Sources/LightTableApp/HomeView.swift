import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var drop = DropState()

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("LightTable").font(.largeTitle.bold())
                Text("看片台：拍完回来，把素材整理好").foregroundStyle(.secondary)
            }
            .padding(.top, 36)

            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(drop.targeted ? Color.accentColor : .secondary)
                Text("把这次拍的文件夹拖到这里").font(.title2.weight(.medium))
                Text("视频、照片放在一起也没关系，子文件夹都会看").foregroundStyle(.secondary)
                Button("选择文件夹…") { model.chooseFolder() }
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(drop.targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
            .background(RoundedRectangle(cornerRadius: 18).fill(drop.targeted ? Color.accentColor.opacity(0.06) : .clear))
            .onDrop(of: [.fileURL], isTargeted: $drop.targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.open(url) }
                }
                return true
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack(spacing: 18) {
                ForEach(TaskKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(kind.summary)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(28)
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.scanProgress.total == 0 ? nil : Double(model.scanProgress.done),
                         total: Double(max(1, model.scanProgress.total)))
                .frame(maxWidth: 360)
            Text("正在看看「\(model.folder?.lastPathComponent ?? "")」里有什么…")
            if model.scanProgress.total > 0 {
                Text("视频 \(model.scanProgress.done)/\(model.scanProgress.total)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class DropState: ObservableObject {
    @Published var targeted = false
}
