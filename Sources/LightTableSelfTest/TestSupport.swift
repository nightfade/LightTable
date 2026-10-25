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
