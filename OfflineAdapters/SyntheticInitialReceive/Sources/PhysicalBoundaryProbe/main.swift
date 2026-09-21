import Foundation
import Darwin
import SyntheticInitialReceive

// Host subprocess tests only. The only storage route is a disposable physical boundary.
struct Failure: Encodable { let checkpoint: String; let reason: String }
var last = "input"
do {
    guard CommandLine.arguments.count == 5 else { throw ReceiveError.schema }
    let workspace = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let input = try SyntheticInput.load(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    let stop = CommandLine.arguments[3], mode = CommandLine.arguments[4]
    guard ["apply", "snapshot", "crash", "hold"].contains(mode) else { throw ReceiveError.schema }
    let context = LocalBoundaryContext(declaredBundle: LocalBoundaryContext.expectedBundle,
        syntheticLocalIdentity: input.manifest.localIdentity, workspace: workspace)
    let session = try LocalBoundary.preparePhysical(context: context, input: .synthetic(input)) { stage in
        last = stage
        guard stage == stop else { return }
        if mode == "crash" {
            FileHandle.standardError.write(try canonical(Failure(checkpoint: stage, reason: "synthetic-exit-73")))
            _exit(73)
        }
        if mode == "hold" {
            FileHandle.standardOutput.write(Data("LOCKED\n".utf8))
            var byte: UInt8 = 0
            _ = Darwin.read(STDIN_FILENO, &byte, 1)
        }
    }
    if mode == "snapshot" {
        let snapshot = try session.snapshot()
        FileHandle.standardOutput.write(try canonical(Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.rawValue, byteHash($0.value)) })))
    } else { FileHandle.standardOutput.write(try canonical(session.apply())) }
} catch {
    if let data = try? canonical(Failure(checkpoint: last, reason: String(describing: error))) { FileHandle.standardError.write(data) }
    exit(1)
}
