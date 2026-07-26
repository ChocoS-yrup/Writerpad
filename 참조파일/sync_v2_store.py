import hashlib
import os
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone


ACTIVE_OPERATION_STATES = ("pending", "inflight", "conflict")


def _utc_now():
    return datetime.now(timezone.utc).isoformat()


def _normalize_path(path):
    return (path or "").replace("\\", "/").strip("/")


class SyncV2Store:
    """SQLite-backed identity, revision and durable operation queue for sync v2."""

    def __init__(self, db_path=None):
        if db_path is None:
            from runtime_profile import app_data_dir
            app_data = app_data_dir()
            os.makedirs(app_data, exist_ok=True)
            db_path = os.path.join(app_data, "sync_v2.sqlite3")
        self.db_path = os.path.abspath(db_path)
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        self._schema_lock = threading.Lock()
        self._initialize()

    def _connect(self):
        connection = sqlite3.connect(self.db_path, timeout=10, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    @contextmanager
    def _transaction(self):
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    @contextmanager
    def _reader(self):
        connection = self._connect()
        try:
            yield connection
        finally:
            connection.close()

    def _initialize(self):
        with self._schema_lock, self._transaction() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS sync_projects (
                    local_key TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL UNIQUE,
                    project_name TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS sync_documents (
                    document_id TEXT PRIMARY KEY,
                    local_key TEXT NOT NULL REFERENCES sync_projects(local_key) ON DELETE CASCADE,
                    local_path TEXT NOT NULL,
                    server_path TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                    base_content TEXT NOT NULL DEFAULT '',
                    base_hash TEXT NOT NULL DEFAULT '',
                    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
                    sync_state TEXT NOT NULL DEFAULT 'local',
                    last_error TEXT NOT NULL DEFAULT '',
                    conflict_base TEXT,
                    conflict_local TEXT,
                    conflict_remote TEXT,
                    conflict_merged TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(local_key, local_path)
                );

                CREATE INDEX IF NOT EXISTS sync_documents_project_idx
                    ON sync_documents(local_key, document_id);

                CREATE TABLE IF NOT EXISTS sync_operations (
                    queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL UNIQUE,
                    local_key TEXT NOT NULL REFERENCES sync_projects(local_key) ON DELETE CASCADE,
                    project_id TEXT NOT NULL,
                    document_id TEXT NOT NULL REFERENCES sync_documents(document_id) ON DELETE CASCADE,
                    local_path TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    base_revision INTEGER,
                    base_content TEXT NOT NULL,
                    content TEXT NOT NULL,
                    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
                    status TEXT NOT NULL DEFAULT 'pending',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS sync_operations_ready_idx
                    ON sync_operations(status, base_revision, queue_id);
                CREATE INDEX IF NOT EXISTS sync_operations_document_idx
                    ON sync_operations(document_id, queue_id);
                """
            )
            connection.execute(
                "UPDATE sync_operations SET status = 'pending' WHERE status = 'inflight'"
            )

    @staticmethod
    def local_key_for(writing_root_path):
        return os.path.normcase(os.path.abspath(writing_root_path or ""))

    def configure_project(self, writing_root_path, project_name, project_id=None):
        local_key = self.local_key_for(writing_root_path)
        now = _utc_now()
        if project_id:
            project_id = str(uuid.UUID(str(project_id)))
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT * FROM sync_projects WHERE local_key = ?", (local_key,)
            ).fetchone()
            if row is None:
                project_id = project_id or str(uuid.uuid4())
                connection.execute(
                    """
                    INSERT INTO sync_projects
                        (local_key, project_id, project_name, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (local_key, project_id, project_name, now, now),
                )
            else:
                if project_id and project_id != row["project_id"]:
                    raise ValueError("이 로컬 프로젝트는 이미 다른 Supabase project_id에 연결되어 있습니다.")
                project_id = row["project_id"]
                connection.execute(
                    "UPDATE sync_projects SET project_name = ?, updated_at = ? WHERE local_key = ?",
                    (project_name, now, local_key),
                )
        return {
            "local_key": local_key,
            "project_id": project_id,
            "project_name": project_name,
        }

    def get_project(self, local_key):
        with self._reader() as connection:
            row = connection.execute(
                "SELECT * FROM sync_projects WHERE local_key = ?", (local_key,)
            ).fetchone()
            return dict(row) if row else None

    def ensure_document(self, local_key, local_path, content="", document_id=None):
        local_path = _normalize_path(local_path)
        now = _utc_now()
        if document_id:
            document_id = str(uuid.UUID(str(document_id)))
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT * FROM sync_documents WHERE local_key = ? AND local_path = ?",
                (local_key, local_path),
            ).fetchone()
            if row is None:
                document_id = document_id or str(uuid.uuid4())
                base_hash = hashlib.sha256(content.encode("utf-8")).hexdigest() if content else ""
                connection.execute(
                    """
                    INSERT INTO sync_documents (
                        document_id, local_key, local_path, server_path, revision,
                        base_content, base_hash, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)
                    """,
                    (document_id, local_key, local_path, local_path, content, base_hash, now, now),
                )
                row = connection.execute(
                    "SELECT * FROM sync_documents WHERE document_id = ?", (document_id,)
                ).fetchone()
            return dict(row)

    def get_document(self, local_key, local_path):
        local_path = _normalize_path(local_path)
        with self._reader() as connection:
            row = connection.execute(
                "SELECT * FROM sync_documents WHERE local_key = ? AND local_path = ?",
                (local_key, local_path),
            ).fetchone()
            return dict(row) if row else None

    def get_document_by_id(self, document_id):
        with self._reader() as connection:
            row = connection.execute(
                "SELECT * FROM sync_documents WHERE document_id = ?", (document_id,)
            ).fetchone()
            return dict(row) if row else None

    def list_documents(self, local_key):
        with self._reader() as connection:
            rows = connection.execute(
                "SELECT * FROM sync_documents WHERE local_key = ? ORDER BY document_id",
                (local_key,),
            ).fetchall()
            return [dict(row) for row in rows]

    def has_active_operations(self, document_id):
        with self._reader() as connection:
            row = connection.execute(
                """
                SELECT 1 FROM sync_operations
                WHERE document_id = ? AND status IN ('pending', 'inflight', 'conflict')
                LIMIT 1
                """,
                (document_id,),
            ).fetchone()
            return row is not None

    def has_tombstone_for_server_path(self, local_key, server_path):
        """Return whether a path is deleted or has a queued deletion."""
        server_path = _normalize_path(server_path)
        with self._reader() as connection:
            row = connection.execute(
                """
                SELECT 1
                FROM sync_documents AS document
                WHERE document.local_key = ?
                  AND document.server_path = ?
                  AND (
                    document.is_deleted = 1
                    OR EXISTS (
                        SELECT 1 FROM sync_operations AS operation
                        WHERE operation.document_id = document.document_id
                          AND operation.is_deleted = 1
                          AND operation.status IN ('pending', 'inflight', 'conflict')
                    )
                  )
                LIMIT 1
                """,
                (local_key, server_path),
            ).fetchone()
            return row is not None

    def apply_remote_snapshot(
        self,
        context,
        document_id,
        remote_path,
        content,
        revision,
        is_deleted=False,
        local_path=None,
    ):
        """Record a newer clean server snapshot without disturbing queued local work."""
        document_id = str(uuid.UUID(str(document_id)))
        remote_path = _normalize_path(remote_path)
        local_path = _normalize_path(local_path or remote_path)
        content = content or ""
        revision = int(revision or 0)
        now = _utc_now()
        content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()

        with self._transaction() as connection:
            existing = connection.execute(
                "SELECT * FROM sync_documents WHERE document_id = ?", (document_id,)
            ).fetchone()
            active = connection.execute(
                """
                SELECT 1 FROM sync_operations
                WHERE document_id = ? AND status IN ('pending', 'inflight', 'conflict')
                LIMIT 1
                """,
                (document_id,),
            ).fetchone()
            if active:
                return {"applied": False, "reason": "active_operations"}
            if existing and revision <= existing["revision"]:
                return {"applied": False, "reason": "not_newer", "document": dict(existing)}

            collision = connection.execute(
                """
                SELECT document_id FROM sync_documents
                WHERE local_key = ? AND local_path = ? AND document_id <> ?
                """,
                (context["local_key"], local_path, document_id),
            ).fetchone()
            if collision:
                return {"applied": False, "reason": "path_conflict"}

            if existing is None:
                connection.execute(
                    """
                    INSERT INTO sync_documents (
                        document_id, local_key, local_path, server_path, revision,
                        base_content, base_hash, is_deleted, sync_state, last_error,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'synced', '', ?, ?)
                    """,
                    (
                        document_id,
                        context["local_key"],
                        local_path,
                        remote_path,
                        revision,
                        content,
                        content_hash,
                        int(bool(is_deleted)),
                        now,
                        now,
                    ),
                )
                previous_path = None
            else:
                previous_path = existing["local_path"]
                connection.execute(
                    """
                    UPDATE sync_documents
                    SET local_path = ?, server_path = ?, revision = ?,
                        base_content = ?, base_hash = ?, is_deleted = ?,
                        sync_state = 'synced', last_error = '',
                        conflict_base = NULL, conflict_local = NULL,
                        conflict_remote = NULL, conflict_merged = NULL,
                        updated_at = ?
                    WHERE document_id = ?
                    """,
                    (
                        local_path,
                        remote_path,
                        revision,
                        content,
                        content_hash,
                        int(bool(is_deleted)),
                        now,
                        document_id,
                    ),
                )

            document = connection.execute(
                "SELECT * FROM sync_documents WHERE document_id = ?", (document_id,)
            ).fetchone()
            return {
                "applied": True,
                "reason": "applied",
                "previous_path": previous_path,
                "document": dict(document),
            }

    def relocate_deleted_document(self, document_id, local_path):
        """Repair an already-synced tombstone that still occupies its live path."""
        document_id = str(uuid.UUID(str(document_id)))
        local_path = _normalize_path(local_path)
        now = _utc_now()
        with self._transaction() as connection:
            document = connection.execute(
                "SELECT * FROM sync_documents WHERE document_id = ?", (document_id,)
            ).fetchone()
            if document is None or not document["is_deleted"]:
                return {"applied": False, "reason": "not_deleted"}
            active = connection.execute(
                """
                SELECT 1 FROM sync_operations
                WHERE document_id = ? AND status IN ('pending', 'inflight', 'conflict')
                LIMIT 1
                """,
                (document_id,),
            ).fetchone()
            if active:
                return {"applied": False, "reason": "active_operations"}
            collision = connection.execute(
                """
                SELECT 1 FROM sync_documents
                WHERE local_key = ? AND local_path = ? AND document_id <> ?
                LIMIT 1
                """,
                (document["local_key"], local_path, document_id),
            ).fetchone()
            if collision:
                return {"applied": False, "reason": "path_conflict"}
            previous_path = document["local_path"]
            connection.execute(
                "UPDATE sync_documents SET local_path = ?, updated_at = ? WHERE document_id = ?",
                (local_path, now, document_id),
            )
            repaired = connection.execute(
                "SELECT * FROM sync_documents WHERE document_id = ?", (document_id,)
            ).fetchone()
            return {
                "applied": True,
                "reason": "relocated",
                "previous_path": previous_path,
                "document": dict(repaired),
            }

    def enqueue(
        self,
        context,
        local_path,
        content,
        relative_path=None,
        is_deleted=False,
    ):
        local_path = _normalize_path(local_path)
        relative_path = _normalize_path(relative_path or local_path)
        document = self.ensure_document(context["local_key"], local_path, content)
        now = _utc_now()

        with self._transaction() as connection:
            # A new explicit save is the user's resolution of a previously surfaced conflict.
            connection.execute(
                """
                UPDATE sync_operations
                SET status = 'cancelled', updated_at = ?
                WHERE document_id = ? AND status = 'conflict'
                """,
                (now, document["document_id"]),
            )
            latest = connection.execute(
                """
                SELECT * FROM sync_operations
                WHERE document_id = ? AND status IN ('pending', 'inflight')
                ORDER BY queue_id DESC LIMIT 1
                """,
                (document["document_id"],),
            ).fetchone()

            if (
                latest
                and latest["content"] == content
                and latest["relative_path"] == relative_path
                and bool(latest["is_deleted"]) == bool(is_deleted)
            ):
                return dict(latest)

            if latest:
                base_revision = None
                base_content = latest["content"]
            else:
                current = connection.execute(
                    "SELECT * FROM sync_documents WHERE document_id = ?",
                    (document["document_id"],),
                ).fetchone()
                base_revision = current["revision"]
                base_content = current["base_content"]

            operation_id = str(uuid.uuid4())
            cursor = connection.execute(
                """
                INSERT INTO sync_operations (
                    operation_id, local_key, project_id, document_id, local_path,
                    relative_path, base_revision, base_content, content, is_deleted,
                    status, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                """,
                (
                    operation_id,
                    context["local_key"],
                    context["project_id"],
                    document["document_id"],
                    local_path,
                    relative_path,
                    base_revision,
                    base_content,
                    content,
                    int(bool(is_deleted)),
                    now,
                    now,
                ),
            )
            connection.execute(
                """
                UPDATE sync_documents
                SET sync_state = 'pending', last_error = '',
                    conflict_base = NULL, conflict_local = NULL,
                    conflict_remote = NULL, conflict_merged = NULL,
                    updated_at = ?
                WHERE document_id = ?
                """,
                (now, document["document_id"]),
            )
            row = connection.execute(
                "SELECT * FROM sync_operations WHERE queue_id = ?", (cursor.lastrowid,)
            ).fetchone()
            return dict(row)

    def next_ready_operation(self, local_key=None):
        params = []
        where = "status = 'pending' AND base_revision IS NOT NULL"
        if local_key:
            where += " AND local_key = ?"
            params.append(local_key)
        with self._reader() as connection:
            row = connection.execute(
                f"SELECT * FROM sync_operations WHERE {where} ORDER BY queue_id LIMIT 1",
                params,
            ).fetchone()
            return dict(row) if row else None

    def mark_attempt(self, operation_id):
        now = _utc_now()
        with self._transaction() as connection:
            connection.execute(
                """
                UPDATE sync_operations
                SET status = 'inflight', attempts = attempts + 1, updated_at = ?
                WHERE operation_id = ? AND status = 'pending'
                """,
                (now, operation_id),
            )

    def mark_retry(self, operation_id, error_message):
        now = _utc_now()
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT document_id FROM sync_operations WHERE operation_id = ?",
                (operation_id,),
            ).fetchone()
            if not row:
                return
            connection.execute(
                """
                UPDATE sync_operations
                SET status = 'pending', last_error = ?, updated_at = ?
                WHERE operation_id = ?
                """,
                (error_message, now, operation_id),
            )
            connection.execute(
                """
                UPDATE sync_documents
                SET sync_state = 'pending', last_error = ?, updated_at = ?
                WHERE document_id = ?
                """,
                (error_message, now, row["document_id"]),
            )

    def mark_success(self, operation_id, result):
        now = _utc_now()
        with self._transaction() as connection:
            operation = connection.execute(
                "SELECT * FROM sync_operations WHERE operation_id = ?",
                (operation_id,),
            ).fetchone()
            if not operation:
                return None
            connection.execute(
                """
                UPDATE sync_operations
                SET status = 'completed', last_error = '', updated_at = ?
                WHERE operation_id = ?
                """,
                (now, operation_id),
            )
            next_operation = connection.execute(
                """
                SELECT * FROM sync_operations
                WHERE document_id = ? AND status = 'pending'
                ORDER BY queue_id LIMIT 1
                """,
                (operation["document_id"],),
            ).fetchone()
            if next_operation and next_operation["base_revision"] is None:
                connection.execute(
                    """
                    UPDATE sync_operations
                    SET base_revision = ?, base_content = ?, updated_at = ?
                    WHERE queue_id = ?
                    """,
                    (result["revision"], operation["content"], now, next_operation["queue_id"]),
                )
            still_pending = connection.execute(
                """
                SELECT 1 FROM sync_operations
                WHERE document_id = ? AND status IN ('pending', 'inflight') LIMIT 1
                """,
                (operation["document_id"],),
            ).fetchone()
            connection.execute(
                """
                UPDATE sync_documents
                SET server_path = ?, revision = ?, base_content = ?, base_hash = ?,
                    is_deleted = ?, sync_state = ?, last_error = '', updated_at = ?
                WHERE document_id = ?
                """,
                (
                    operation["relative_path"],
                    result["revision"],
                    operation["content"],
                    result.get("content_hash", hashlib.sha256(operation["content"].encode("utf-8")).hexdigest()),
                    operation["is_deleted"],
                    "pending" if still_pending else "synced",
                    now,
                    operation["document_id"],
                ),
            )
            return dict(operation)

    def rebase_clean_merge(
        self, operation_id, remote_revision, remote_content, merged_content,
        remote_path=None,
    ):
        now = _utc_now()
        with self._transaction() as connection:
            operation = connection.execute(
                "SELECT * FROM sync_operations WHERE operation_id = ?", (operation_id,)
            ).fetchone()
            if not operation:
                return
            connection.execute(
                """
                UPDATE sync_operations
                SET status = 'cancelled', updated_at = ?
                WHERE document_id = ? AND operation_id <> ?
                  AND status IN ('pending', 'inflight', 'conflict')
                """,
                (now, operation["document_id"], operation_id),
            )
            connection.execute(
                """
                UPDATE sync_operations
                SET base_revision = ?, base_content = ?, content = ?,
                    relative_path = COALESCE(?, relative_path),
                    status = 'pending', last_error = '', updated_at = ?
                WHERE operation_id = ?
                """,
                (remote_revision, remote_content, merged_content, remote_path, now, operation_id),
            )
            connection.execute(
                """
                UPDATE sync_documents
                SET revision = ?, base_content = ?, base_hash = ?,
                    server_path = COALESCE(?, server_path),
                    sync_state = 'pending', last_error = '', updated_at = ?
                WHERE document_id = ?
                """,
                (
                    remote_revision,
                    remote_content,
                    hashlib.sha256(remote_content.encode("utf-8")).hexdigest(),
                    remote_path,
                    now,
                    operation["document_id"],
                ),
            )

    def mark_conflict(
        self,
        operation_id,
        remote_revision,
        remote_path,
        remote_content,
        merged_content,
        local_content=None,
        error_message="REVISION_CONFLICT",
    ):
        now = _utc_now()
        with self._transaction() as connection:
            operation = connection.execute(
                "SELECT * FROM sync_operations WHERE operation_id = ?", (operation_id,)
            ).fetchone()
            if not operation:
                return None
            connection.execute(
                """
                UPDATE sync_operations
                SET status = CASE WHEN operation_id = ? THEN 'conflict' ELSE 'cancelled' END,
                    last_error = ?, updated_at = ?
                WHERE document_id = ? AND status IN ('pending', 'inflight', 'conflict')
                """,
                (operation_id, error_message, now, operation["document_id"]),
            )
            connection.execute(
                """
                UPDATE sync_documents
                SET server_path = ?, revision = ?, base_content = ?, base_hash = ?,
                    sync_state = 'conflict', last_error = ?,
                    conflict_base = ?, conflict_local = ?, conflict_remote = ?,
                    conflict_merged = ?, updated_at = ?
                WHERE document_id = ?
                """,
                (
                    remote_path,
                    remote_revision,
                    remote_content,
                    hashlib.sha256(remote_content.encode("utf-8")).hexdigest(),
                    error_message,
                    operation["base_content"],
                    operation["content"] if local_content is None else local_content,
                    remote_content,
                    merged_content,
                    now,
                    operation["document_id"],
                ),
            )
            return dict(operation)

    def move_local_path(self, local_key, old_path, new_path):
        old_path = _normalize_path(old_path)
        new_path = _normalize_path(new_path)
        now = _utc_now()
        moved = []
        with self._transaction() as connection:
            rows = connection.execute(
                """
                SELECT * FROM sync_documents
                WHERE local_key = ? AND (local_path = ? OR local_path LIKE ?)
                ORDER BY length(local_path)
                """,
                (local_key, old_path, old_path + "/%"),
            ).fetchall()
            for row in rows:
                suffix = row["local_path"][len(old_path):]
                updated_path = new_path + suffix
                connection.execute(
                    "UPDATE sync_documents SET local_path = ?, updated_at = ? WHERE document_id = ?",
                    (updated_path, now, row["document_id"]),
                )
                connection.execute(
                    """
                    UPDATE sync_operations SET local_path = ?, updated_at = ?
                    WHERE document_id = ? AND status IN ('pending', 'inflight', 'conflict')
                    """,
                    (updated_path, now, row["document_id"]),
                )
                moved.append({**dict(row), "old_local_path": row["local_path"], "local_path": updated_path})
        return moved

    def move_destination_conflicts(self, local_key, old_path, new_path):
        """Return documents that already reserve a destination of a prefix move."""
        old_path = _normalize_path(old_path)
        new_path = _normalize_path(new_path)
        with self._reader() as connection:
            moving = connection.execute(
                """
                SELECT document_id, local_path
                FROM sync_documents
                WHERE local_key = ? AND (local_path = ? OR local_path LIKE ?)
                """,
                (local_key, old_path, old_path + "/%"),
            ).fetchall()
            if not moving:
                return []
            moving_ids = {row["document_id"] for row in moving}
            conflicts = []
            for row in moving:
                suffix = row["local_path"][len(old_path):]
                destination = new_path + suffix
                occupant = connection.execute(
                    """
                    SELECT * FROM sync_documents
                    WHERE local_key = ? AND local_path = ?
                    """,
                    (local_key, destination),
                ).fetchone()
                if occupant and occupant["document_id"] not in moving_ids:
                    conflicts.append(dict(occupant))
            return conflicts

    def counts(self, local_key=None):
        params = []
        where = "status IN ('pending', 'inflight', 'conflict')"
        if local_key:
            where += " AND local_key = ?"
            params.append(local_key)
        with self._reader() as connection:
            rows = connection.execute(
                f"SELECT status, COUNT(*) AS count FROM sync_operations WHERE {where} GROUP BY status",
                params,
            ).fetchall()
        result = {"pending": 0, "inflight": 0, "conflict": 0}
        result.update({row["status"]: row["count"] for row in rows})
        result["total"] = sum(result.values())
        return result

    def latest_error(self, local_key=None):
        params = []
        where = "status IN ('pending', 'conflict') AND last_error <> ''"
        if local_key:
            where += " AND local_key = ?"
            params.append(local_key)
        with self._reader() as connection:
            row = connection.execute(
                f"SELECT last_error FROM sync_operations WHERE {where} ORDER BY updated_at DESC LIMIT 1",
                params,
            ).fetchone()
            return row["last_error"] if row else ""

    def operation(self, operation_id):
        with self._reader() as connection:
            row = connection.execute(
                "SELECT * FROM sync_operations WHERE operation_id = ?", (operation_id,)
            ).fetchone()
            return dict(row) if row else None
