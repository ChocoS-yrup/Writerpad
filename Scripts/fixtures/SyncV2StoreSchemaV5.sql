-- 작업의 상태를 칸이 아니라 사건 기록에서 계산하기 위한 표다.
--
-- 지금은 sync_operations.status를 직접 고쳐 쓴다. 그러면 고쳐 쓰는 곳을 하나만
-- 빠뜨려도 끝난 작업이 pending으로 남고, 화면의 대기 건수가 영원히 줄지 않는다.
-- Windows가 실제로 그렇게 당했다. 사건 기록 자체만으로 어긋남이 사라지지는
-- 않는다. 모든 집계가 사건에서 파생되고, status 칸과의 divergence 검사가 계속
-- 돌아야 같은 우회를 다시 잡을 수 있다.
--
-- 이 단계에서는 표를 만들고 지금 상태를 기록으로 옮기기만 한다. 읽는 쪽은
-- 아직 status 칸을 그대로 본다. 두 값이 같은지 확인할 수 있게 된 다음에
-- 읽는 쪽을 옮긴다.
--
-- 기록은 지우지 않는다. 성공했다고 해서 앞선 실패를 없애면, 무엇 때문에
-- 몇 번을 다시 시도했는지 되짚을 길이 사라진다.

BEGIN IMMEDIATE;

CREATE TABLE sync_operation_events (
    event_row_id INTEGER PRIMARY KEY AUTOINCREMENT,
    -- 사건마다 고유한 식별자다. 같은 식별자로 다시 들어온 요청은 기록을
    -- 늘리지 않고 그대로 흘려보내야 해서 필요하다.
    event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
    operation_id TEXT NOT NULL
        REFERENCES sync_operations(operation_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    -- 1부터 빈틈없이 이어져야 한다. 중간이 비면 우리가 못 본 사건이 있다는
    -- 뜻이라 계산 결과를 믿을 수 없다.
    event_sequence INTEGER NOT NULL CHECK (event_sequence >= 1),
    event_type TEXT NOT NULL CHECK (
        event_type IN (
            'enqueued',
            'dispatch_started',
            'retry_scheduled',
            'blocked',
            'conflict_detected',
            'committed',
            'replayed',
            'cancel_requested',
            'superseded'
        )
    ),
    recorded_at TEXT NOT NULL,
    error_code TEXT,
    -- superseded처럼 다른 작업을 가리키는 사건이 쓴다.
    related_operation_id TEXT CHECK (
        related_operation_id IS NULL OR length(related_operation_id) = 36
    ),
    detail_json TEXT NOT NULL DEFAULT '{}',
    UNIQUE (operation_id, event_sequence)
) STRICT;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    5,
    'SyncV2StoreSchemaV5',
    'design-fixture-v5',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 5;

COMMIT;
