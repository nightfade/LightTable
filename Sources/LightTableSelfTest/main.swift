import Foundation

// Core logic checks that need no camera footage. Tests that need real tools (ffmpeg, exiftool,
// Gyroflow, python3) skip themselves with a note when the tool is missing.
let only = CommandLine.arguments.dropFirst().first

if only == nil || only == "kit" { await runKitTests() }
if only == nil || only == "stabilize" { await runStabilizeTests() }
if only == nil || only == "habits" { await runHabitsTests() }

if failures.isEmpty {
    print("All LightTable self-tests passed (\(passes) checks).")
} else {
    print("\(failures.count) failed, \(passes) passed:")
    failures.forEach { print("  ✗ \($0)") }
    exit(1)
}
