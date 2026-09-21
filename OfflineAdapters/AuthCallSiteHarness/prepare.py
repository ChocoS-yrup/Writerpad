import pathlib,json,hashlib,sys
root=pathlib.Path.cwd();stage=root/'build/ipad-target-context-auth-offline-20260915';dest=stage/'auth-host'
for p in [dest/'Sources/AuthHost',dest/'Tests/AuthHostTests']:p.mkdir(parents=True,exist_ok=True)
(dest/'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package=Package(name:"AuthHost",platforms:[.macOS(.v13)],targets:[.target(name:"AuthHost"),.testTarget(name:"AuthHostTests",dependencies:["AuthHost"])])\n')
inputs={}
for name in ['WriterPad/Sync/SupabaseAuthService.swift','WriterPad/Sync/SyncV2Timing.swift','OfflineAdapters/SyntheticInitialReceive/Sources/SyntheticInitialReceive/ReceiveAuthObservation.swift','OfflineAdapters/AuthCallSiteHarness/Dependencies.swift']:
 p=root/name;data=p.read_bytes();(dest/'Sources/AuthHost'/p.name).write_bytes(data);inputs[name]=hashlib.sha256(data).hexdigest()
race=root/'WriterPad/Sync/SyncV2SnapshotPull.swift';body=race.read_text();body=body[body.index('actor SyncV2OneShotRace'):body.index('typealias SyncV2GateTimeoutSleep')];(dest/'Sources/AuthHost/Race.swift').write_text('import Foundation\n'+body)
inputs[str(race.relative_to(root))]={'whole_file_sha256':hashlib.sha256(race.read_bytes()).hexdigest(),'selected_declaration':'SyncV2OneShotRace, unchanged text','declaration_sha256':hashlib.sha256(body.encode()).hexdigest()}
p=root/'OfflineAdapters/AuthCallSiteHarness/CallSiteTests.swift';(dest/'Tests/AuthHostTests/CallSiteTests.swift').write_bytes(p.read_bytes());inputs[str(p.relative_to(root))]=hashlib.sha256(p.read_bytes()).hexdigest()
(stage/'auth-host-source-manifest.json').write_text(json.dumps(inputs,indent=2)+'\n')
