import Foundation

enum ProjectLifecycleState: Codable, Equatable, Sendable {
    case active
    case deletionRequested(at: Date)
    case deletedList(at: Date)
}

/// SwiftData의 작품 정체성과 로컬 작품 목록 정책을 합친 화면용 집합체다.
struct ManagedProject: Codable, Equatable, Identifiable, Sendable {
    let project: Project
    let userOrder: Int
    let lifecycleState: ProjectLifecycleState

    var id: ProjectID { project.id }
    var name: String { project.name }

    var isDeletionRequested: Bool {
        if case .deletionRequested = lifecycleState { return true }
        return false
    }

    var isInDeletedList: Bool {
        if case .deletedList = lifecycleState { return true }
        return false
    }

    var isActive: Bool {
        if case .active = lifecycleState { return true }
        return false
    }
}

/// 화면에서 명시적 확인을 받은 뒤에만 삭제 대기 상태로 전환하기 위한 값이다.
struct ProjectDeletionConfirmation: Equatable, Sendable {
    let projectID: ProjectID
    let expectedName: String
}

/// 삭제 대기 작품을 실제로 제거하기 전에 다시 받는 최종 확인 값이다.
struct ProjectPermanentDeletionConfirmation: Equatable, Sendable {
    let projectID: ProjectID
    let expectedName: String
}

/// 삭제 대기 작품을 복구 가능한 별도 삭제 목록으로 옮기기 위한 확인 값이다.
struct ProjectDeletedListConfirmation: Equatable, Sendable {
    let projectID: ProjectID
    let expectedName: String
}

/// 후속 내보내기 단계가 작품 전체를 안전하게 묶을 때 사용할 입력 경계다.
struct ProjectExportDescriptor: Equatable, Sendable {
    let projectID: ProjectID
    let projectName: String
    let projectContainerURL: URL
    let suggestedArchiveName: String
}
