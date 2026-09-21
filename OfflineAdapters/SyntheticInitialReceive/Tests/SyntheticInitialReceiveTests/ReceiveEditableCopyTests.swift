import XCTest
import Darwin
@testable import SyntheticInitialReceive

final class ReceiveEditableCopyTests: XCTestCase {
    private var homes: [URL] = []
    override func tearDownWithError() throws { for home in homes { try FileManager.default.removeItem(at: home) } }
    private func home() throws -> URL {
        let value = URL(fileURLWithPath: try SafeFiles.temporaryPath()).appendingPathComponent("editable-copy-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false); homes.append(value); return value
    }
    func testCreatesAndValidatesIsolatedCopy() throws {
        let root = try home(), local = UUID(), run = UUID().uuidString.lowercased()
        let snapshot = ReceiveStoredSnapshot(runID: run, folderName: "작품", documents: [.init(id: UUID(), name: "본문.txt", text: "보존", byteCount: 6)])
        let copy = try ReceiveEditableCopy.create(home: root, local: local, snapshot: snapshot, check: {})
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("identity.json").path))
        let opened = try ReceiveEditableCopy.open(home: root, local: local, snapshot: snapshot, check: {})
        XCTAssertEqual(opened.documents.first?.text, "보존")
    }
    func testRejectsSecondCreateWithoutChangingFirstCopy() throws {
        let root = try home(), local = UUID(), run = UUID().uuidString.lowercased(), id = UUID()
        let text = "첫 저장"
        let snapshot = ReceiveStoredSnapshot(runID: run, folderName: "작품", documents: [.init(id: id, name: "본문.txt", text: text, byteCount: Data(text.utf8).count)])
        let copy = try ReceiveEditableCopy.create(home: root, local: local, snapshot: snapshot, check: {})
        let before = try SafeFiles.read(copy.appendingPathComponent("workspace.json"))
        XCTAssertThrowsError(try ReceiveEditableCopy.create(home: root, local: local, snapshot: snapshot, check: {}))
        XCTAssertEqual(try SafeFiles.read(copy.appendingPathComponent("workspace.json")), before)
    }
    func testAtomicSaveAdvancesRevisionAndRejectsStaleWriter() throws {
        let root=try home(),local=UUID(),run=UUID().uuidString.lowercased(),id=UUID(),text="초기"
        let source=ReceiveStoredSnapshot(runID:run,folderName:"작품",documents:[.init(id:id,name:"본문.txt",text:text,byteCount:Data(text.utf8).count)])
        _=try ReceiveEditableCopy.create(home:root,local:local,snapshot:source,check:{})
        let saved=try ReceiveEditableCopy.save(home:root,local:local,snapshot:source,documentID:id,expectedRevision:0,text:"수정\n",check:{})
        XCTAssertEqual(saved.documents.first?.revision,1);XCTAssertEqual(saved.documents.first?.text,"수정\n")
        XCTAssertThrowsError(try ReceiveEditableCopy.save(home:root,local:local,snapshot:source,documentID:id,expectedRevision:0,text:"오래된 저장",check:{}))
        XCTAssertEqual(try ReceiveEditableCopy.open(home:root,local:local,snapshot:source,check:{}).documents.first?.text,"수정\n")
    }
    func testEmptyKoreanAndFinalLineFeedRoundTrip() throws {
        let root=try home(),local=UUID(),run=UUID().uuidString.lowercased(),empty=UUID(),body=UUID()
        let initial=ReceiveStoredSnapshot(runID:run,folderName:"작품",documents:[
            .init(id:empty,name:"빈문서.txt",text:"",byteCount:0),
            .init(id:body,name:"저장경계.txt",text:"격리 저장 경계 기준",byteCount:Data("격리 저장 경계 기준".utf8).count)
        ])
        _=try ReceiveEditableCopy.create(home:root,local:local,snapshot:initial,check:{})
        let saved=try ReceiveEditableCopy.save(home:root,local:local,snapshot:initial,documentID:body,expectedRevision:0,text:"한글\n마지막 LF\n",check:{})
        XCTAssertEqual(saved.documents.first{$0.id==empty}?.text,"")
        XCTAssertEqual(saved.documents.first{$0.id==body}?.text,"한글\n마지막 LF\n")
    }
    func testOversizeOrRevokedSaveKeepsLastCompletedWorkspace() throws {
        let root=try home(),local=UUID(),run=UUID().uuidString.lowercased(),id=UUID(),text="원본"
        let initial=ReceiveStoredSnapshot(runID:run,folderName:"작품",documents:[.init(id:id,name:"본문.txt",text:text,byteCount:Data(text.utf8).count)])
        let copy=try ReceiveEditableCopy.create(home:root,local:local,snapshot:initial,check:{})
        let workspace=copy.appendingPathComponent("workspace.json"),before=try SafeFiles.read(workspace,limit:20*1024*1024)
        XCTAssertThrowsError(try ReceiveEditableCopy.save(home:root,local:local,snapshot:initial,documentID:id,expectedRevision:0,text:String(repeating:"x",count:4*1024*1024+1),check:{}))
        XCTAssertEqual(try SafeFiles.read(workspace,limit:20*1024*1024),before)
        let lifecycle=BoundaryLifecycle();lifecycle.update(active:true,protectedDataAvailable:true);let lease=try lifecycle.begin();lifecycle.update(active:false,protectedDataAvailable:true)
        XCTAssertThrowsError(try ReceiveEditableCopy.save(home:root,local:local,snapshot:initial,documentID:id,expectedRevision:0,text:"취소됨",check:{try lease.check()}))
        XCTAssertEqual(try SafeFiles.read(workspace,limit:20*1024*1024),before)
    }
    func testCorruptWorkspaceIsBlockedWithoutRepair() throws {
        let root=try home(),local=UUID(),run=UUID().uuidString.lowercased(),id=UUID(),text="원본"
        let initial=ReceiveStoredSnapshot(runID:run,folderName:"작품",documents:[.init(id:id,name:"본문.txt",text:text,byteCount:Data(text.utf8).count)])
        let copy=try ReceiveEditableCopy.create(home:root,local:local,snapshot:initial,check:{})
        let workspace=copy.appendingPathComponent("workspace.json")
        try SafeFiles.write(Data("{}\n".utf8),to:workspace,checkpoint:{_ in})
        let damaged=try SafeFiles.read(workspace)
        XCTAssertThrowsError(try ReceiveEditableCopy.open(home:root,local:local,snapshot:initial,check:{}))
        XCTAssertEqual(try SafeFiles.read(workspace),damaged)
    }
    func testSourceIdentityMismatchAndHeldLockBlockWithoutWrite() throws {
        let root=try home(),local=UUID(),run=UUID().uuidString.lowercased(),id=UUID(),text="원본"
        let source=ReceiveStoredSnapshot(runID:run,folderName:"작품",documents:[.init(id:id,name:"본문.txt",text:text,byteCount:Data(text.utf8).count)])
        let copy=try ReceiveEditableCopy.create(home:root,local:local,snapshot:source,check:{})
        let workspace=copy.appendingPathComponent("workspace.json"),before=try SafeFiles.read(workspace)
        let changed=ReceiveStoredSnapshot(runID:run,folderName:"다른 작품",documents:source.documents)
        XCTAssertThrowsError(try ReceiveEditableCopy.open(home:root,local:local,snapshot:changed,check:{}))
        let lock=copy.appendingPathComponent("operation.lock"),fd=Darwin.open(lock.path,O_RDWR|O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd,0);defer{if fd>=0{flock(fd,LOCK_UN);close(fd)}}
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        XCTAssertThrowsError(try ReceiveEditableCopy.save(home:root,local:local,snapshot:source,documentID:id,expectedRevision:0,text:"경쟁 저장",check:{}))
        XCTAssertEqual(try SafeFiles.read(workspace),before)
    }
    func testDocumentDraftsSurviveSelectionAndTrackSavedBaseline() {
        let first=UUID(),second=UUID(),run=UUID().uuidString.lowercased()
        let initial=ReceiveEditableSnapshot(sourceRun:run,folderName:"작품",documents:[
            .init(id:first,name:"첫째.txt",text:"원본 1",revision:0),
            .init(id:second,name:"둘째.txt",text:"원본 2",revision:0)
        ])
        var drafts=ReceiveEditableDrafts(snapshot:initial)
        drafts.set("초안 1",for:first);drafts.set("초안 2",for:second)
        XCTAssertEqual(drafts.text(for:initial.documents[0]),"초안 1")
        XCTAssertEqual(drafts.text(for:initial.documents[1]),"초안 2")
        XCTAssertEqual(drafts.dirtyCount(in:initial),2)

        let firstSaved=ReceiveEditableSnapshot(sourceRun:run,folderName:"작품",documents:[
            .init(id:first,name:"첫째.txt",text:"초안 1",revision:1),
            .init(id:second,name:"둘째.txt",text:"원본 2",revision:0)
        ])
        XCTAssertFalse(drafts.isDirty(firstSaved.documents[0]))
        XCTAssertTrue(drafts.isDirty(firstSaved.documents[1]))
        XCTAssertEqual(drafts.dirtyCount(in:firstSaved),1)
    }
    func testSaveFailureMessagesDistinguishActionableCauses() {
        XCTAssertEqual(ReceiveEditableStatus.saveFailure(ReceiveError.busy),"로컬 저장 차단 · 다른 저장이 진행 중이거나 revision이 변경됐습니다")
        XCTAssertEqual(ReceiveEditableStatus.saveFailure(ReceiveError.body),"로컬 저장 차단 · 본문 크기 또는 UTF-8을 확인하세요")
        XCTAssertEqual(ReceiveEditableStatus.saveFailure(ReceiveError.identity),"로컬 저장 차단 · 원본 결합 정보를 다시 확인하세요")
        XCTAssertEqual(ReceiveEditableStatus.saveFailure(ReceiveError.corrupt),"로컬 저장 차단 · 작업 사본 검증에 실패했습니다")
        XCTAssertEqual(ReceiveEditableStatus.saveFailure(ReceiveError.io),"로컬 저장 차단 · 파일 저장을 완료하지 못했습니다")
    }
}
