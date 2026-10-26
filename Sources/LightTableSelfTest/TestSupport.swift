import Foundation

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var passes = 0

/// Records a failed expectation without stopping, so one run reports every broken case.
func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition() { passes += 1 } else { failures.append("\(file):\(line) \(message)") }
}

/// Folder for one test's files, removed at exit by the OS temp cleanup.
func scratchFolder(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lighttable-selftest-\(ProcessInfo.processInfo.processIdentifier)/\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The real ZV-E10 clip used by scanner and stabilise tests: `LIGHTTABLE_SAMPLE_CLIP`, else the
/// copy that lived in the workspace when the tests were written. Tests skip when it is missing.
var sampleClip: URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIGHTTABLE_SAMPLE_CLIP"] ?? "/Users/mengz/WorkSpace/C0835.MP4")
}
