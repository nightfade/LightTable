import Foundation
import TravelCutCore

@main
struct TravelCutSelfTest {
    static func main() {
        var failures: [String] = []

        let short = EventSegmenter.plans(sourceIndex: 0, duration: 2.3, sceneBoundaries: [])
        check(short.count == 1, "short source remains one event", failures: &failures)
        check(abs((short.first?.duration ?? 0) - 2.3) < 0.001, "short event keeps natural duration", failures: &failures)

        let sceneBased = EventSegmenter.plans(
            sourceIndex: 1,
            duration: 31,
            sceneBoundaries: [4.5, 13, 28.5]
        )
        check(sceneBased.map { rounded($0.duration) } == [4.5, 8.5, 15.5, 2.5], "scene boundaries create variable durations", failures: &failures)

        let long = EventSegmenter.plans(sourceIndex: 2, duration: 100, sceneBoundaries: [])
        check(long.count == 3, "long continuous event is divided only for analysis", failures: &failures)
        check(long.first?.start == 0, "long analysis begins at source start", failures: &failures)
        check(abs((long.last?.end ?? 0) - 100) < 0.001, "long analysis reaches source end", failures: &failures)

        let empty = EventSegmenter.plans(sourceIndex: 0, duration: 0.05, sceneBoundaries: [])
        check(empty.isEmpty, "unusable source produces no event", failures: &failures)

        check(
            HighlightTheme.defaultSelection == Set(HighlightTheme.allCases),
            "all content themes are selected by default",
            failures: &failures
        )
        check(
            HighlightTheme.defaultSelection.contains(.roadScenery),
            "road scenery is a first-class selectable theme",
            failures: &failures
        )
        let themedConfiguration = JobConfiguration(
            inputFolder: URL(fileURLWithPath: "/tmp/input"),
            outputFolder: URL(fileURLWithPath: "/tmp/output"),
            selectedThemes: [.roadScenery, .nature]
        )
        check(
            themedConfiguration.selectedThemes == [.roadScenery, .nature],
            "selected content themes reach the analysis configuration",
            failures: &failures
        )

        // Names from TravelCut 0.8.0 still load from checkpoints, caches and saved choices.
        let legacy = try? JSONDecoder().decode([HighlightTheme].self, from: Data(#"["自然景观","城市街景","地标建筑","人物互动","当地美食","活动人文","沿途风景"]"#.utf8))
        check(
            legacy == [.nature, .city, .city, .people, .food, .cultureActivity, .roadScenery],
            "legacy theme names decode to the unified themes, got \(String(describing: legacy))",
            failures: &failures
        )
        check(HighlightTheme(named: "地标建筑") == .city && HighlightTheme(named: "花卉植物") == .flowers
              && HighlightTheme(named: "静物与微距") == nil,
              "theme lookup by current or legacy name", failures: &failures)
        check(HighlightTheme.allCases.count == 12, "twelve selectable themes", failures: &failures)

        failures.append(contentsOf: TravelCutDiagnostics.recoverySelfTest())
        failures.append(contentsOf: TravelCutDiagnostics.organizationSelfTest())
        failures.append(contentsOf: TravelCutDiagnostics.photoCullingSelfTest())
        if let sample = ProcessInfo.processInfo.environment["TRAVELCUT_EXPORT_SAMPLE"] {
            // Optional: a real AVFoundation export, only when a sample clip is supplied.
            let semaphore = DispatchSemaphore(value: 0)
            let box = FailureBox()
            Task.detached {
                box.failures = await TravelCutDiagnostics.exportSelfTest(sample: URL(fileURLWithPath: sample))
                semaphore.signal()
            }
            semaphore.wait()
            failures.append(contentsOf: box.failures)
        }

        if failures.isEmpty {
            print("All TravelCut self-tests passed.")
        } else {
            failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
            Foundation.exit(1)
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func check(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition { failures.append(message) }
    }
}

private final class FailureBox: @unchecked Sendable {
    var failures: [String] = []
}
