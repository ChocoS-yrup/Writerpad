import Foundation

enum LocalDocumentOperation: String, Equatable, Sendable {
    case read = "읽기"
    case createTemporaryFile = "임시 파일 생성"
    case write = "쓰기"
    case flush = "디스크 반영"
    case replace = "원고 교체"
    case reconciliation = "메타데이터 복구 준비"
}

enum LocalDocumentStoreError: Error, Equatable, LocalizedError, Sendable {
    case textFileRequired(String)
    case fileNotFound(String)
    case invalidUTF8(String)
    case parentDirectoryMissing(String)
    case accessDenied(operation: LocalDocumentOperation, path: String)
    case storageFull(path: String)
    case operationFailed(operation: LocalDocumentOperation, path: String, code: Int32)
    case staleGeneration(documentID: DocumentID, requested: UInt64, latest: UInt64)
    case documentNoLongerWritable(DocumentID)
    case metadataUpdateFailed(receipt: DocumentSaveReceipt, markerPath: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .textFileRequired(path):
            "UTF-8 TXT 문서만 열거나 저장할 수 있습니다: \(path)"
        case let .fileNotFound(path):
            "원고 파일을 찾을 수 없습니다: \(path)"
        case let .invalidUTF8(path):
            "UTF-8이 아닌 TXT 파일입니다: \(path)"
        case let .parentDirectoryMissing(path):
            "원고를 저장할 폴더가 없습니다: \(path)"
        case let .accessDenied(operation, path):
            "\(operation.rawValue) 권한이 없습니다: \(path)"
        case let .storageFull(path):
            "저장 공간이 부족합니다: \(path)"
        case let .operationFailed(operation, path, code):
            "\(operation.rawValue) 중 오류가 발생했습니다(errno \(code)): \(path)"
        case let .staleGeneration(id, requested, latest):
            "오래된 저장 요청을 무시했습니다(\(id.rawValue), \(requested) < \(latest))."
        case let .documentNoLongerWritable(id):
            "휴지통으로 이동했거나 경로가 바뀐 문서의 늦은 저장을 무시했습니다(\(id.rawValue))."
        case let .metadataUpdateFailed(_, markerPath, reason):
            "원고는 저장됐지만 메타데이터 반영에 실패했습니다. 복구 기록: \(markerPath) (\(reason))"
        }
    }
}

enum AtomicWriteFaultPoint: Equatable, Sendable {
    case beforeTemporaryFileCreation
    case duringWrite
    case duringFlush
    case beforeReconciliationJournal
    case beforeReplacement
}

enum InjectedWriteFailure: Equatable, Sendable {
    case accessDenied
    case storageFull
    case generic(code: Int32)
}

struct AtomicWriteFaultPlan: Equatable, Sendable {
    let point: AtomicWriteFaultPoint
    let failure: InjectedWriteFailure
}
