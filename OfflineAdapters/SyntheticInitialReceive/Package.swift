// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyntheticInitialReceive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "SyntheticABJournalProbe", targets: ["SyntheticABJournalProbe"]),
               .executable(name: "WindowsReaderProbe", targets: ["WindowsReaderProbe"]),
               .library(name: "SyntheticInitialReceive", targets: ["SyntheticInitialReceive"]),
               .executable(name: "SyntheticReceiveProbe", targets: ["SyntheticReceiveProbe"]),
               .executable(name: "PhysicalBoundaryProbe", targets: ["PhysicalBoundaryProbe"])],
    targets: [.executableTarget(name: "SyntheticABJournalProbe", dependencies: ["SyntheticInitialReceive"]),
              .executableTarget(name: "WindowsReaderProbe", dependencies: ["SyntheticInitialReceive"]),
              .target(name: "SyntheticInitialReceive", resources: [.process("MigrationResources")], linkerSettings: [.linkedLibrary("sqlite3")]),
              .executableTarget(name: "SyntheticReceiveProbe", dependencies: ["SyntheticInitialReceive"]),
              .executableTarget(name: "PhysicalBoundaryProbe", dependencies: ["SyntheticInitialReceive"]),
              .testTarget(name: "SyntheticInitialReceiveTests", dependencies: ["SyntheticInitialReceive"], resources: [.process("Fixtures")])]
)
