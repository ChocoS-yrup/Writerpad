import Foundation
import SyntheticInitialReceive

do {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    try SyntheticABJournalProbe.run(workspace:URL(fileURLWithPath:CommandLine.arguments[1]),checkpoint:CommandLine.arguments[2],mode:CommandLine.arguments[3])
} catch {
    // No path, body or external input is printed on failure.
    FileHandle.standardError.write(Data("synthetic-journal-blocked\n".utf8))
    exit(1)
}
