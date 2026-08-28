import Foundation

enum WorkspaceSyncStatusSeverity: Equatable, Sendable {
    case neutral
    case success
    case warning
    case failure
}

struct WorkspaceSyncStatusPresentation: Equatable, Sendable {
    let label: String
    let systemImage: String
    let detail: String
    let severity: WorkspaceSyncStatusSeverity
    let allowsRetry: Bool
}

enum WorkspaceSyncStatusReducer {
    static func presentation(
        saveState: SaveState,
        handoffState: SyncHandoffState,
        workspaceState: SyncV2WorkspaceState,
        leaseState: EditLeaseDisplayState
    ) -> WorkspaceSyncStatusPresentation {
        let isCloudConnected = workspaceState.lastResult != .localOnly
        switch saveState {
        case .editing:
            return value(
                "편집 중",
                isCloudConnected ? "icloud" : "pencil",
                "변경 사항이 아직 로컬 TXT에 저장되지 않았습니다."
            )
        case .saving:
            return value(
                "로컬 저장 중",
                isCloudConnected
                    ? "icloud.and.arrow.up"
                    : "arrow.triangle.2.circlepath",
                "변경 사항을 이 iPad의 TXT 파일에 저장하고 있습니다."
            )
        case let .failed(_, message):
            return value(
                "로컬 저장 실패",
                isCloudConnected
                    ? "exclamationmark.icloud"
                    : "exclamationmark.triangle.fill",
                message,
                severity: .failure,
                retry: true
            )
        case .idle, .saved:
            break
        }

        switch handoffState {
        case let .failed(_, message):
            return value(
                "동기화 기록 실패",
                "exclamationmark.icloud",
                message,
                severity: .failure,
                retry: true
            )
        default:
            break
        }

        switch leaseState {
        case .heldByOther:
            return value(
                "다른 기기 편집 중",
                "lock.fill",
                "다른 기기가 이 문서의 편집 잠금을 보유하고 있습니다. 로컬 TXT는 보존되며 잠금이 풀리면 자동으로 다시 시도합니다.",
                severity: .warning,
                retry: true
            )
        default:
            break
        }

        switch workspaceState.progress {
        case .pulling:
            return value(
                "서버 동기화 중",
                "arrow.triangle.2.circlepath.icloud",
                "서버 snapshot을 확인하고 안전한 변경을 적용하고 있습니다."
            )
        case .checkingAuthentication:
            return value(
                "로그인 확인 중",
                "person.crop.circle.badge.clock",
                "저장된 로그인 세션을 복원하고 있습니다."
            )
        case .idle:
            break
        }

        switch (
            workspaceState.connection,
            workspaceState.lastResult
        ) {
        case (_, .conflictRequired), (_, .structuralConflict),
             (_, .notApplied), (_, .notPublished), (_, .waiting),
             (_, .uploadPending), (_, .retryWaiting),
             (_, .actualConflict), (_, .blocked),
             (_, .automaticallyMerged):
            // 결과 축은 연결 수명주기와 독립적이다. 사용자 조치가 필요하거나
            // 아직 확인해야 할 pull 결과는 Realtime 전이로 가리지 않는다.
            break
        case (.unknown, .synced):
            // 성공한 pull 결과는 최초 Realtime 구독 완료를 기다리는 동안에도
            // 그대로 표시한다. 연결 축은 결과 축을 덮어쓰지 않는다.
            break
        case (.unknown, _):
            return value(
                "서버 연결 확인 중",
                "network",
                "Realtime 연결과 최신 서버 snapshot을 확인하고 있습니다."
            )
        case (.reconnecting, _):
            return value(
                "서버 재연결 중",
                "arrow.triangle.2.circlepath.icloud",
                "연결을 복구한 뒤 누락된 변경을 즉시 다시 확인합니다.",
                severity: .warning
            )
        case (.offline, _):
            return value(
                "오프라인 저장됨",
                "icloud.slash",
                "로컬 TXT에는 저장됐습니다. 연결이 돌아오면 snapshot으로 확인합니다.",
                severity: .warning,
                retry: true
            )
        case (.healthy, _):
            break
        }

        switch workspaceState.lastResult {
        case let .synced(at):
            let isOlderThanCurrentSave: Bool
            if case .queued = handoffState,
               case let .saved(_, savedAt, _) = saveState {
                isOlderThanCurrentSave = at < savedAt
            } else {
                isOlderThanCurrentSave = false
            }
            if !isOlderThanCurrentSave {
                return value(
                    "서버 동기화됨",
                    "checkmark.icloud",
                    "마지막 확인: \(at.formatted(date: .omitted, time: .shortened))",
                    severity: .success
                )
            }
        case let .conflictRequired(detail):
            return value(
                "충돌 해결 필요",
                "exclamationmark.arrow.triangle.2.circlepath",
                detail,
                severity: .failure,
                retry: true
            )
        case let .structuralConflict(detail):
            return value(
                "제목·경로 확인 필요",
                "exclamationmark.triangle.fill",
                detail,
                severity: .failure,
                retry: true
            )
        case let .notPublished(detail):
            // 이 기기가 한 조작이 서버에 없다. 실패로 부르되 재시도 버튼은
            // 달지 않는다 — 세워 둔 작업은 다시 claim되지 않아 눌러도 바뀌지
            // 않는다.
            return value(
                "서버에 못 올린 변경 있음",
                "exclamationmark.icloud",
                detail,
                severity: .warning
            )
        case let .notApplied(detail):
            // 실패가 아니라 덮어쓰지 않으려고 미룬 것이므로 정보성으로 둔다.
            // 재시도 버튼을 달지 않는다. 눌러도 바뀌지 않고, 아무 일도 하지
            // 않는 버튼은 사실을 감추는 또 하나의 거짓이 된다.
            return value(
                "적용하지 않은 항목 있음",
                "info.circle",
                detail
            )
        default:
            break
        }

        switch handoffState {
        case .queued:
            return value(
                "동기화 대기",
                "icloud.and.arrow.up",
                "로컬 저장은 끝났고 서버 전송 순서를 기다리고 있습니다."
            )
        default:
            break
        }

        switch workspaceState.lastResult {
        case let .uploadPending(count):
            return value(
                "전송 대기",
                "icloud.and.arrow.up",
                "이 iPad의 로컬 변경 \(count)건이 서버 전송 순서를 기다리고 있습니다."
            )
        case let .retryWaiting(count):
            return value(
                "재시도 대기",
                "clock.arrow.circlepath",
                "일시적인 전송 실패 \(count)건을 보존했습니다. 다음 재시도 전에는 서버 snapshot을 적용하지 않습니다.",
                severity: .warning,
                retry: true
            )
        case let .actualConflict(count):
            return value(
                "실제 충돌 \(count)건",
                "exclamationmark.arrow.triangle.2.circlepath",
                "서버 revision과 겹친 변경입니다. 충돌 해소용 읽기와 병합 절차가 필요합니다.",
                severity: .failure,
                retry: true
            )
        case let .blocked(count):
            return value(
                "적용 거부 \(count)건",
                "exclamationmark.icloud",
                "서버 계약 또는 권한에 의해 영구 거부된 로컬 변경입니다. 자동 반복하지 않습니다.",
                severity: .failure
            )
        case .waiting:
            return value(
                "동기화 대기",
                "clock.arrow.circlepath",
                "편집 또는 조합 중인 문서는 덮어쓰지 않고 다음 snapshot 확인을 기다립니다.",
                severity: .warning,
                retry: true
            )
        case .authenticationRequired:
            return value(
                "인증 필요",
                "person.crop.circle.badge.exclamationmark",
                "서버 동기화를 계속하려면 설정에서 다시 로그인하세요.",
                severity: .warning
            )
        default:
            break
        }

        switch handoffState {
        case let .serverSizeLimitExceeded(_, bytes, limit):
            return value(
                "서버 크기 제한 초과",
                "exclamationmark.icloud",
                "\(bytes.formatted())바이트 문서가 서버 제한 \(limit.formatted())바이트를 초과했습니다.",
                severity: .failure
            )
        default:
            break
        }

        switch workspaceState.lastResult {
        case .automaticallyMerged:
            return value(
                "자동 병합됨",
                "arrow.triangle.merge",
                "서로 겹치지 않는 변경을 자동으로 합쳤습니다.",
                severity: .success
            )
        case let .failed(detail):
            return value(
                "동기화 실패",
                "icloud.slash",
                detail,
                severity: .failure,
                retry: true
            )
        default:
            break
        }

        switch saveState {
        case .saved:
            return value(
                isCloudConnected ? "클라우드 전송 준비" : "로컬 저장됨",
                isCloudConnected
                    ? "icloud.and.arrow.up"
                    : "checkmark.circle",
                isCloudConnected
                    ? "로컬 TXT 저장을 마쳤고 서버 전송을 준비하고 있습니다."
                    : "이 iPad의 TXT 파일에 안전하게 저장됐습니다.",
                severity: isCloudConnected ? .neutral : .success
            )
        default:
            break
        }
        return value(
            isCloudConnected ? "클라우드 저장 준비" : "로컬 저장 준비",
            isCloudConnected ? "icloud" : "externaldrive",
            isCloudConnected
                ? "문서를 편집하면 로컬 저장 후 서버로 전송합니다."
                : "문서를 편집하면 먼저 이 iPad에 저장합니다."
        )
    }

    private static func value(
        _ label: String,
        _ systemImage: String,
        _ detail: String,
        severity: WorkspaceSyncStatusSeverity = .neutral,
        retry: Bool = false
    ) -> WorkspaceSyncStatusPresentation {
        WorkspaceSyncStatusPresentation(
            label: label,
            systemImage: systemImage,
            detail: detail,
            severity: severity,
            allowsRetry: retry
        )
    }
}
