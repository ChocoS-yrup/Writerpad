import Foundation
import Darwin
import SyntheticInitialReceive

// Host-only subprocess probe. No app, credentials, network or general-purpose execution mode.
struct FailureRecord: Encodable {
    let kind = "synthetic-host-failure"
    let checkpoint: String
    let reason: String
}
var lastCheckpoint = "input-validation"
do {
    guard CommandLine.arguments.count == 5 else { throw ReceiveError.schema }
    let workspace = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let input = try SyntheticInput.load(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    let stop = CommandLine.arguments[3], mode = CommandLine.arguments[4]
    guard ["apply", "crash", "hold"].contains(mode) else { throw ReceiveError.schema }
    let adapter = try SyntheticAdapter(workspace: workspace) { stage in
        lastCheckpoint = stage
        guard stage == stop else { return }
        if mode == "crash" {
            FileHandle.standardError.write(try canonical(FailureRecord(checkpoint: stage, reason: "injected-process-exit-73")))
            _exit(73)
        }
        if mode == "hold" {
            FileHandle.standardOutput.write(Data("LOCKED\n".utf8))
            var byte: UInt8 = 0
            _ = Darwin.read(STDIN_FILENO, &byte, 1)
        }
    }
    let receipt = try adapter.apply(input)
    FileHandle.standardOutput.write(try canonical(receipt))
} catch {
    // The invoking test harness preserves this separate error report; no store repair on failure.
    let record = FailureRecord(checkpoint: lastCheckpoint, reason: String(describing: error))
    if let data = try? canonical(record) { FileHandle.standardError.write(data) }
    exit(1)
}
