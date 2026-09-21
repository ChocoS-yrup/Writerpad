import copy
import os
import json
import stat
import sys
import threading
import unicodedata
import uuid
from types import SimpleNamespace
from PyQt6.QtCore import QObject, QThread, pyqtSignal, QMutex, QMutexLocker, QTimer

from datetime import datetime

from runtime_profile import is_forced_offline
from project_paths import LocalProjectPathError, validate_local_project_name
from sync_diagnostics import SyncDiagnosticLog, format_diagnostic_report
from sync_v2_store import SyncV2Store
from three_way_merge import three_way_merge


TREE_ORDER_DOCUMENT_PATH = "__antigravity__/tree-order.json"
TRASH_PURGE_DOCUMENT_PATH = "__antigravity__/trash-purge.json"
LEASE_CONFLICT_RETRY_DELAYS_MS = (3000, 5000, 10000, 30000)
NETWORK_RETRY_DELAYS_MS = (5000, 15000, 30000, 60000)
MAX_WINDOWS_COMPONENT_UTF16_UNITS = 255
MAX_WINDOWS_DIRECTORY_PATH = 247
TREE_ROOT_STORAGE_NAMES = {
    "📚 원고": "원고",
    "원고": "원고",
    "👤 캐릭터": "캐릭터",
    "캐릭터": "캐릭터",
    "📖 설정집": "설정집",
    "설정집": "설정집",
    "📝 메모장": "메모장",
    "메모장": "메모장",
    "🗺️ 스토리 플롯": "플롯",
    "🗺️ 메인 스토리 틀": "플롯",
    "스토리 플롯": "플롯",
    "플롯": "플롯",
    "🌊 흐름 정리": "흐름정리",
    "흐름 정리": "흐름정리",
    "흐름정리": "흐름정리",
    "🔍 복선": "복선",
    "복선": "복선",
    "📌 장소": "장소",
    "장소": "장소",
    "🗑️ 휴지통": "휴지통",
    "휴지통": "휴지통",
}


def supabase_config_dir():
    """Return the directory that holds public Supabase client settings."""
    return getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))


def load_or_create_device_id():
    from runtime_profile import app_data_dir

    data_dir = app_data_dir()
    os.makedirs(data_dir, exist_ok=True)
    device_id_path = os.path.join(data_dir, ".device_id")
    device_id = ""
    try:
        with open(device_id_path, "r", encoding="utf-8") as device_file:
            device_id = str(uuid.UUID(device_file.read().strip()))
    except (FileNotFoundError, OSError, TypeError, ValueError):
        device_id = str(uuid.uuid4())
        temp_path = device_id_path + ".tmp"
        with open(temp_path, "w", encoding="utf-8") as device_file:
            device_file.write(device_id)
            device_file.flush()
            os.fsync(device_file.fileno())
        os.replace(temp_path, device_id_path)
    return device_id


def is_internal_sync_path(relative_path):
    path = str(relative_path or "").replace("\\", "/").strip("/")
    return path == TREE_ORDER_DOCUMENT_PATH or path.startswith("__antigravity__/")


def is_live_document_path(relative_path):
    """Return whether a local text path represents a live cloud document."""
    path = str(relative_path or "").replace("\\", "/").strip("/")
    if not path:
        return False
    if is_internal_sync_path(path):
        return False
    return not (
        path == "백업"
        or path.startswith("백업/")
        or path == "메인/휴지통"
        or path.startswith("메인/휴지통/")
        or path == "휴지통"
        or path.startswith("휴지통/")
    )


class LockWorker(QThread):
    # Keep QThread.finished intact. Emitting a custom signal with the same name
    # before run() actually returns can schedule deleteLater() while the native
    # thread is still running, which makes Qt terminate the whole process.
    resultReady = pyqtSignal(bool, str, object) # success, msg, server_updated_at
    
    def __init__(self, sync_manager, project_name, relative_path, session_id):
        super().__init__()
        self.sync_manager = sync_manager
        self.project_name = project_name
        self.relative_path = relative_path
        self.session_id = session_id
    def run(self):
        owns_client = False
        try:
            # v2 must reuse the profile's one authenticated client. Creating a
            # client per file-open can rotate the same refresh token concurrently.
            owns_client = not self.sync_manager.is_v2_enabled
            self.supabase = (
                SyncManager.create_supabase_client()
                if owns_client else self.sync_manager.supabase
            )
            success, msg = self.sync_manager.check_and_acquire_lock(self.project_name, self.relative_path, self.session_id, client=self.supabase)
            server_updated_at = None
            if success:
                server_updated_at = self.sync_manager.get_file_updated_at(self.project_name, self.relative_path, client=self.supabase)
            self.resultReady.emit(success, msg, server_updated_at)
        except Exception as e:
            self.resultReady.emit(False, str(e), None)
        finally:
            if owns_client:
                SyncManager._close_supabase_client(
                    getattr(self, "supabase", None)
                )

class SaveWorker(QThread):
    resultReady = pyqtSignal(bool, str, str, object) # success(bool), error_msg(str), rel_path(str), new_updated_at(str|None)
    conflict_detected = pyqtSignal(str, str, str, str) # project, rel_path, local_content, server_content
    
    def __init__(self, supabase_client, wpm, project_name, relative_path, content, local_updated_at=None, force_overwrite=False):
        super().__init__()
        self.supabase = supabase_client
        self.wpm = wpm
        self.project_name = project_name
        self.relative_path = relative_path
        self.content = content
        self.local_updated_at = local_updated_at
        self.force_overwrite = force_overwrite

    def run(self):
        try:
            self.supabase = SyncManager.create_supabase_client()
            new_updated_at = None
            # 1. 로컬 저장 (백그라운드 스레드에서 I/O)
            if self.wpm and self.relative_path:
                if not self.wpm.write_text_file(self.relative_path, self.content):
                    raise OSError("로컬 파일 저장에 실패했습니다.")
                
            # 2. 클라우드 동기화
            if not self.supabase:
                self.resultReady.emit(False, "서버 연결 없음", self.relative_path, None)
                return

            if not self.force_overwrite:
                # 충돌 확인
                resp = self.supabase.table("writing_contents").select("updated_at, content").eq("project_name", self.project_name).eq("relative_path", self.relative_path).execute()
                if resp.data:
                    server_updated_at = resp.data[0].get("updated_at")
                    if self.local_updated_at is None or server_updated_at != self.local_updated_at:
                        server_content = resp.data[0].get("content", "")
                        self.conflict_detected.emit(self.project_name, self.relative_path, self.content, server_content)
                        self.resultReady.emit(True, "충돌 감지", self.relative_path, server_updated_at)
                        return

            resp = self.supabase.table("writing_contents").upsert({
                "project_name": self.project_name,
                "relative_path": self.relative_path,
                "content": self.content
            }).execute()
            new_updated_at = resp.data[0].get("updated_at") if resp.data else None
            
            self.resultReady.emit(True, "", self.relative_path, new_updated_at)
        except Exception as e:
            self.resultReady.emit(False, str(e), self.relative_path, None)
        finally:
            SyncManager._close_supabase_client(getattr(self, "supabase", None))

class BulkSaveWorker(QThread):
    resultReady = pyqtSignal(bool, str) # success, error_msg
    
    def __init__(self, supabase_client, wpm, project_name):
        super().__init__()
        self.supabase = supabase_client
        self.wpm = wpm
        self.project_name = project_name

    def run(self):
        try:
            self.supabase = SyncManager.create_supabase_client()
            if not self.wpm or not self.wpm.writing_root_path:
                self.resultReady.emit(False, "집필모드 경로를 찾을 수 없습니다.")
                return

            if not self.supabase:
                self.resultReady.emit(True, "")
                return
                
            data_list = []
            import os
            for root, _, files in os.walk(self.wpm.writing_root_path):
                if "백업" in root.replace("\\", "/"):
                    continue
                for file in files:
                    if file.endswith(".txt"):
                        full_path = os.path.join(root, file)
                        rel_path = os.path.relpath(full_path, self.wpm.writing_root_path).replace("\\", "/")
                        try:
                            with open(full_path, "r", encoding="utf-8") as f:
                                content = f.read()
                            data_list.append({
                                "project_name": self.project_name,
                                "relative_path": rel_path,
                                "content": content
                            })
                        except Exception as e:
                            print(f"BulkSaveWorker file read error ({rel_path}): {e}")

            if data_list:
                # 100개씩 나눠서 업로드 (Supabase payload limit 대비)
                chunk_size = 100
                for i in range(0, len(data_list), chunk_size):
                    chunk = data_list[i:i+chunk_size]
                    self.supabase.table("writing_contents").upsert(chunk).execute()
                    
            self.resultReady.emit(True, "")
        except Exception as e:
            self.resultReady.emit(False, str(e))
        finally:
            SyncManager._close_supabase_client(getattr(self, "supabase", None))

class BackupWorker(QThread):
    resultReady = pyqtSignal(bool, str) # success, error_msg
    
    def __init__(self, supabase_client, wpm, project_name, relative_path, content):
        super().__init__()
        self.supabase = supabase_client
        self.wpm = wpm
        self.project_name = project_name
        self.relative_path = relative_path
        self.content = content

    def run(self):
        try:
            self.supabase = SyncManager.create_supabase_client()
            # 1. 로컬 정기 백업 저장
            if self.wpm and self.relative_path:
                now = datetime.now()
                bucket_minute = (now.minute // 5) * 5
                timestamp = f"{now.strftime('%Y%m%d_%H')}{bucket_minute:02d}"
                base_name = os.path.basename(self.relative_path).replace(".txt", "")
                
                # 화별 폴더(base_name) 분리
                abs_backup_path = os.path.join(self.wpm.workspace_dir, self.wpm.current_project, "집필모드", "백업", "자동저장", base_name, f"{base_name}_{timestamp}.txt")
                os.makedirs(os.path.dirname(abs_backup_path), exist_ok=True)
                with open(abs_backup_path, "w", encoding="utf-8") as f:
                    f.write(self.content)
            
            # 2. 클라우드 히스토리 백업
            if self.supabase:
                self.supabase.table("writing_history").insert({
                    "project_name": self.project_name,
                    "relative_path": self.relative_path,
                    "content": self.content
                }).execute()
            
            self.resultReady.emit(True, "")
        except Exception as e:
            self.resultReady.emit(False, str(e))
        finally:
            SyncManager._close_supabase_client(getattr(self, "supabase", None))

class AutoSaveWorker(QThread):
    resultReady = pyqtSignal(bool, str)
    
    def __init__(self, wpm, relative_path, content):
        super().__init__()
        self.wpm = wpm
        self.relative_path = relative_path
        self.content = content

    def run(self):
        try:
            if self.wpm and self.relative_path:
                from datetime import datetime
                now = datetime.now()
                bucket_minute = (now.minute // 5) * 5
                timestamp = f"{now.strftime('%Y%m%d_%H')}{bucket_minute:02d}"
                base_name = os.path.basename(self.relative_path).replace(".txt", "")
                
                # 화별 폴더(base_name) 분리
                abs_backup_path = os.path.join(self.wpm.workspace_dir, self.wpm.current_project, "집필모드", "백업", "자동저장", base_name, f"{base_name}_{timestamp}.txt")
                os.makedirs(os.path.dirname(abs_backup_path), exist_ok=True)
                with open(abs_backup_path, "w", encoding="utf-8") as f:
                    f.write(self.content)
            self.resultReady.emit(True, "")
        except Exception as e:
            self.resultReady.emit(False, str(e))

class RenameWorker(QThread):
    resultReady = pyqtSignal(bool, str)
    
    def __init__(self, supabase_client, project_name, old_rel_path, new_rel_path):
        super().__init__()
        self.supabase = supabase_client
        self.project_name = project_name
        self.old_rel_path = old_rel_path
        self.new_rel_path = new_rel_path

    def run(self):
        try:
            self.supabase = SyncManager.create_supabase_client()
            if self.supabase:
                self.supabase.table("writing_contents") \
                    .update({"relative_path": self.new_rel_path}) \
                    .eq("project_name", self.project_name) \
                    .eq("relative_path", self.old_rel_path) \
                    .execute()
                
            self.resultReady.emit(True, "")
        except Exception as e:
            self.resultReady.emit(False, str(e))
        finally:
            SyncManager._close_supabase_client(getattr(self, "supabase", None))


class V2QueueWorker(QThread):
    resultReady = pyqtSignal(bool, str, object)

    def __init__(self, sync_manager, operation_id):
        super().__init__()
        self.sync_manager = sync_manager
        self.operation_id = operation_id
        self.supabase = sync_manager.supabase

    def run(self):
        try:
            result = self.sync_manager._process_v2_operation(self.operation_id)
            kind = result.get("kind")
            self.resultReady.emit(
                kind in {"committed", "auto_merged", "conflict"},
                result.get("error", ""),
                result,
            )
        except Exception as e:
            self.resultReady.emit(False, str(e), {"kind": "retry", "error": str(e)})


class V2PullWorker(QThread):
    resultReady = pyqtSignal(bool, object)

    def __init__(self, sync_manager):
        super().__init__()
        self.sync_manager = sync_manager

    def run(self):
        try:
            self.resultReady.emit(True, self.sync_manager._fetch_v2_project_documents())
        except Exception as error:
            self.resultReady.emit(False, str(error))


class ServerActionWorker(QThread):
    """Run a small server-only callable without blocking the editor thread."""

    resultReady = pyqtSignal(bool, object)

    def __init__(self, action):
        super().__init__()
        self.action = action

    def run(self):
        try:
            self.resultReady.emit(True, self.action())
        except Exception as error:
            self.resultReady.emit(False, error)

class SyncManager(QObject):
    syncStateChanged = pyqtSignal(str, str, int)  # state, detail, pending retry count
    conflictDetected = pyqtSignal(object)
    autoMergeApplied = pyqtSignal(object)
    remoteDocumentsApplied = pyqtSignal(object)

    _instance = None
    _mutex = QMutex()

    def __new__(cls, *args, **kwargs):
        with QMutexLocker(cls._mutex):
            if cls._instance is None:
                cls._instance = super(SyncManager, cls).__new__(cls)
                cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        super().__init__()
        self._initialized = True
        self.active_workers = set()
        self._retry_queue = {}
        self._retry_active_key = None
        self._active_server_syncs = 0
        self._active_backups = 0
        self._last_sync_error = ""
        self._last_failure_offline = False
        self.current_sync_state = "saved"
        self._v2_store = None
        self._v2_context = None
        self._v2_wpm = None
        self._v2_device_id = None
        self._v2_worker = None
        self._v2_workers = []
        self._v2_callbacks = {}
        self._v2_conflict_callbacks = {}
        self._v2_leases = {}
        self._v2_pull_worker = None
        self._v2_protected_paths_provider = None
        self._v2_active_paths_provider = None
        self._v2_retry_timer = QTimer(self)
        self._v2_retry_timer.setSingleShot(True)
        self._v2_retry_timer.timeout.connect(self._run_scheduled_v2_retry)
        self._v2_retry_context = None
        self._v2_lease_retry_operation_id = None
        self._v2_lease_retry_attempt = 0
        self._v2_network_retry_attempts = {}
        self._server_action_workers = []
        self._heartbeat_worker = None
        self._workers = []
        self._bulk_workers = []
        self._history_workers = []
        self._autosave_workers = []
        self._autosave_workers_by_path = {}
        self._autosave_followups = {}
        self._retention_workers = []
        self._rename_workers = []
        self._retention_worker = None
        self._session_refresh_lock = threading.Lock()
        self._auth_refresh_generation = 0
        self._auth_retry_blocked = False
        self._shutting_down = False
        self._diagnostics = SyncDiagnosticLog()
        self._last_diagnostic_state_signature = None
        
        self.supabase = None
        self.init_supabase()

    def configure_v2(
        self,
        wpm,
        project_name,
        device_id,
        store=None,
        project_id=None,
        recover_local_changes=True,
    ):
        """Attach the current Windows writing project to the durable v2 store."""
        from runtime_profile import forced_project_id
        self._cancel_scheduled_v2_retry(reset_backoff=True)
        self._v2_store = store or self._v2_store or SyncV2Store()
        self._v2_wpm = wpm
        self._v2_device_id = str(device_id)
        local_key = self._v2_store.local_key_for(wpm.writing_root_path)
        project_was_configured = self._v2_store.get_project(local_key) is not None
        selected_project_id = project_id or forced_project_id() or None
        self._v2_context = self._v2_store.configure_project(
            wpm.writing_root_path, project_name, selected_project_id
        )
        deterministic_ids = bool(forced_project_id() and not project_id)
        root = getattr(wpm, "writing_root_path", None)
        if recover_local_changes and root and os.path.isdir(root):
            for current_root, dirs, files in os.walk(root):
                relative_root = os.path.relpath(current_root, root).replace("\\", "/")
                if relative_root != "." and not is_live_document_path(relative_root):
                    dirs[:] = []
                    continue
                dirs[:] = [
                    name for name in dirs
                    if is_live_document_path(
                        name if relative_root == "." else f"{relative_root}/{name}"
                    )
                ]
                for filename in files:
                    if filename.endswith(".txt"):
                        full_path = os.path.join(current_root, filename)
                        relative_path = os.path.relpath(full_path, root).replace("\\", "/")
                        try:
                            with open(full_path, "r", encoding="utf-8") as source:
                                content = source.read()
                        except OSError:
                            content = ""
                        document_id = None
                        if deterministic_ids:
                            document_id = str(uuid.uuid5(
                                uuid.UUID(self._v2_context["project_id"]), relative_path
                            ))
                        existing = self._v2_store.get_document(
                            self._v2_context["local_key"], relative_path
                        )
                        self._v2_store.ensure_document(
                            self._v2_context["local_key"], relative_path, content, document_id
                        )
                        # A file created just before a forced shutdown can exist on disk
                        # without ever reaching the queue. On an already configured project,
                        # newly discovered files are creation recovery work, not initial import.
                        if project_was_configured and existing is None:
                            self._v2_store.enqueue(
                                self._v2_context,
                                relative_path,
                                content,
                                relative_path=relative_path,
                            )

        tree_order = getattr(wpm, "project_settings", {}).get("tree_order")
        tree_document = self._v2_store.get_document(
            self._v2_context["local_key"], TREE_ORDER_DOCUMENT_PATH
        )
        if (
            recover_local_changes
            and project_was_configured
            and isinstance(tree_order, dict)
            and tree_order
            and tree_document is None
        ):
            self.record_tree_order(tree_order, retry=False)
        purge_state = getattr(wpm, "project_settings", {}).get(
            "trash_purged_revisions"
        )
        if (
            recover_local_changes
            and project_was_configured
            and isinstance(purge_state, dict)
            and purge_state
            and self._v2_store.get_document(
                self._v2_context["local_key"], TRASH_PURGE_DOCUMENT_PATH
            ) is None
        ):
            self.record_trash_purge([], retry=False)
        self._publish_sync_state()
        return dict(self._v2_context)

    @staticmethod
    def _normalized_tree_order(tree_order):
        if not isinstance(tree_order, dict):
            return {}
        normalized = {}
        for parent_path, child_names in tree_order.items():
            parent_path = str(parent_path or "").replace("\\", "/")
            if (
                parent_path == "메인/휴지통"
                or parent_path.startswith("메인/휴지통/")
                or not isinstance(child_names, list)
            ):
                continue
            clean_names = [str(name) for name in child_names if str(name)]
            normalized[parent_path] = clean_names
        return normalized

    @classmethod
    def _tree_order_content(cls, tree_order):
        return json.dumps(
            {"version": 1, "tree_order": cls._normalized_tree_order(tree_order)},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )

    @staticmethod
    def _normalized_trash_purges(value):
        if not isinstance(value, dict):
            return {}
        normalized = {}
        for document_id, revision in value.items():
            try:
                normalized[str(uuid.UUID(str(document_id)))] = max(0, int(revision))
            except (TypeError, ValueError):
                continue
        return normalized

    @classmethod
    def _trash_purge_content(cls, purges, empty_generation=None):
        return json.dumps(
            {
                "version": 1,
                "purged_revisions": cls._normalized_trash_purges(purges),
                "empty_generation": str(empty_generation or ""),
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )

    def record_trash_purge(self, trash_items, empty_all=False, retry=True):
        """Synchronize permanent trash removal without deleting server history."""
        if not self.is_v2_enabled:
            return None
        purges = self._normalized_trash_purges(
            self._v2_wpm.project_settings.get("trash_purged_revisions", {})
        )
        affected_ids = set()
        for item in trash_items or []:
            document = None
            document_id = item.get("document_id") if isinstance(item, dict) else None
            if document_id:
                document = self._v2_store.get_document_by_id(document_id)
            if document is None and isinstance(item, dict) and item.get("trash_path"):
                document = self._v2_store.get_document(
                    self._v2_context["local_key"], item["trash_path"]
                )
            if not document or not document.get("is_deleted"):
                continue
            document_id = document["document_id"]
            revision = int(document.get("revision") or 0)
            if revision <= 0:
                continue
            purges[document_id] = max(purges.get(document_id, 0), revision)
            affected_ids.add(document_id)

        generation = self._v2_wpm.project_settings.get("trash_empty_generation", "")
        if empty_all:
            generation = str(uuid.uuid4())
            self._v2_wpm.project_settings["trash_empty_generation"] = generation
        self._v2_wpm.project_settings["trash_purged_revisions"] = purges
        self._v2_wpm.save_settings()

        for document_id in affected_ids:
            self._v2_store.relocate_deleted_document(
                document_id, f"__antigravity__/purged/{document_id}"
            )

        document_id = str(uuid.uuid5(
            uuid.UUID(self._v2_context["project_id"]), TRASH_PURGE_DOCUMENT_PATH
        ))
        if self._v2_store.get_document(
            self._v2_context["local_key"], TRASH_PURGE_DOCUMENT_PATH
        ) is None:
            self._v2_store.ensure_document(
                self._v2_context["local_key"],
                TRASH_PURGE_DOCUMENT_PATH,
                "",
                document_id,
            )
        operation = self._v2_store.enqueue(
            self._v2_context,
            TRASH_PURGE_DOCUMENT_PATH,
            self._trash_purge_content(purges, generation),
            relative_path=TRASH_PURGE_DOCUMENT_PATH,
        )
        self._publish_sync_state()
        if retry:
            self.retry_pending_syncs()
        return operation

    def record_tree_order(self, tree_order, retry=True):
        """Persist project binder order as one hidden revisioned v2 document."""
        if not self.is_v2_enabled:
            return None
        content = self._tree_order_content(tree_order)
        document_id = str(uuid.uuid5(
            uuid.UUID(self._v2_context["project_id"]), TREE_ORDER_DOCUMENT_PATH
        ))
        document = self._v2_store.get_document(
            self._v2_context["local_key"], TREE_ORDER_DOCUMENT_PATH
        )
        if document is None:
            document = self._v2_store.ensure_document(
                self._v2_context["local_key"],
                TREE_ORDER_DOCUMENT_PATH,
                "",
                document_id,
            )
        if (
            document.get("base_content") == content
            and not self._v2_store.has_active_operations(document["document_id"])
        ):
            return None
        operation = self._v2_store.enqueue(
            self._v2_context,
            TREE_ORDER_DOCUMENT_PATH,
            content,
            relative_path=TREE_ORDER_DOCUMENT_PATH,
        )
        self._publish_sync_state()
        if retry:
            self.retry_pending_syncs()
        return operation

    @property
    def is_v2_enabled(self):
        return bool(self._v2_store and self._v2_context and self._v2_device_id)

    def can_save_path(self, relative_path):
        """Reject late editor saves for a path that has already been tombstoned."""
        if not self.is_v2_enabled:
            return True
        if not is_live_document_path(relative_path):
            return False
        existing = self._v2_store.get_document(
            self._v2_context["local_key"], relative_path
        )
        if existing is not None:
            return True
        return not self._v2_store.has_tombstone_for_server_path(
            self._v2_context["local_key"], relative_path
        )

    def would_erase_nonempty_document(self, relative_path, content):
        """Return whether an empty save would erase a non-empty synced base."""
        if content != "" or not self.is_v2_enabled or not relative_path:
            return False
        document = self._v2_store.get_document(
            self._v2_context["local_key"], relative_path
        )
        return bool(
            document
            and not document.get("is_deleted")
            and (
                document.get("base_content")
                or self._v2_store.has_nonempty_active_content(
                    document["document_id"]
                )
            )
        )

    def report_empty_content_guard(self, relative_path):
        detail = (
            f"{relative_path}: 기존 내용이 있는 문서가 빈 상태가 되어 "
            "자동저장을 중단했습니다. Ctrl+S로 전체 삭제 여부를 확인해주세요."
        )
        self._set_sync_state("empty_guard", detail)
        return detail

    def report_server_queue_failure(self, relative_path, error):
        """Report a cloud-queue failure without treating the local save as lost."""
        detail = (
            f"{relative_path}: 로컬 원고는 저장됐지만 서버 전송 대기열에 "
            f"등록하지 못했습니다. ({error})"
        )
        self._last_sync_error = detail
        self._last_failure_offline = self._is_connectivity_error(str(error))
        self._set_sync_state(
            "offline" if self._last_failure_offline else "failed", detail
        )
        return detail
        
    def _start_worker(self, worker):
        self.active_workers.add(worker)
        worker.finished.connect(lambda *args, w=worker: self.active_workers.discard(w))
        worker.start()
        return worker

    def _start_server_action(self, action, callback=None):
        if self._shutting_down:
            return None
        worker = ServerActionWorker(action)
        self._server_action_workers.append(worker)
        if callback:
            worker.resultReady.connect(callback)

        def cleanup_worker():
            if worker in self._server_action_workers:
                self._server_action_workers.remove(worker)
            if self._heartbeat_worker is worker:
                self._heartbeat_worker = None
            worker.deleteLater()

        worker.finished.connect(cleanup_worker)
        return self._start_worker(worker)

    def heartbeat_locks_async(
        self, project_name, relative_paths, session_id, client=None
    ):
        """Renew all active leases in one background worker per heartbeat tick."""
        if self._heartbeat_worker is not None:
            try:
                if self._heartbeat_worker.isRunning():
                    return self._heartbeat_worker
            except RuntimeError:
                self._heartbeat_worker = None
        paths = tuple(dict.fromkeys(path for path in relative_paths if path))
        if not paths:
            return None

        def heartbeat_all():
            for path in paths:
                self.heartbeat_lock(project_name, path, session_id, client=client)
            return len(paths)

        worker = self._start_server_action(heartbeat_all)
        self._heartbeat_worker = worker
        return worker

    def release_lock_async(
        self, project_name, relative_path, session_id, client=None
    ):
        if not relative_path:
            return None
        return self._start_server_action(
            lambda: self.release_lock(
                project_name, relative_path, session_id, client=client
            )
        )

    @property
    def pending_retry_count(self):
        persistent = 0
        if self.is_v2_enabled:
            counts = self._v2_store.counts(self._v2_context["local_key"])
            persistent = counts.get("documents", counts["total"])
        return len(self._retry_queue) + persistent

    def _current_project_server_state(self):
        if not self.is_v2_enabled:
            return "active"
        return str(
            self._v2_context.get("server_state") or "active"
        )

    def mark_project_server_state(self, project_id, state):
        if state not in {"active", "trashed", "purged"}:
            return False
        if self._v2_store is not None:
            setter = getattr(
                self._v2_store, "set_project_server_state", None
            )
            if callable(setter):
                setter(project_id, state)
        if (
            self._v2_context
            and self._v2_context.get("project_id") == str(project_id)
        ):
            self._v2_context["server_state"] = state
            if state in {"trashed", "purged"}:
                # Project trash removes leases on the server. Do not issue
                # release RPCs after access has already been revoked.
                self._v2_leases.clear()
                self._cancel_scheduled_v2_retry(reset_backoff=True)
            self._publish_sync_state()
        return True

    def _set_sync_state(self, state, detail="", pending_count=None):
        self.current_sync_state = state
        if pending_count is None:
            pending_count = self.pending_retry_count
        pending_count = max(0, int(pending_count or 0))
        signature = (str(state), str(detail), int(pending_count))
        if signature != self._last_diagnostic_state_signature:
            self._last_diagnostic_state_signature = signature
            if state in {"offline", "failed", "auth_required", "conflict", "lease"}:
                self._diagnostics.record(
                    "sync_failure",
                    detail=detail or state,
                    state=state,
                    pending_count=pending_count,
                )
            else:
                self._diagnostics.record(
                    "sync_state", state=state, pending_count=pending_count
                )
        self.syncStateChanged.emit(state, detail, pending_count)

    def _record_sync_success(self):
        self._diagnostics.record(
            "sync_success",
            state="saved",
            pending_count=self.pending_retry_count,
        )

    def diagnostic_snapshot(self):
        """Return a local-only, non-sensitive snapshot for the settings panel."""
        summary = self._diagnostics.summary()
        if self.authenticated_email():
            login_state = "로그인됨"
        elif self._auth_retry_blocked:
            login_state = "로그인 필요"
        else:
            login_state = "로그아웃"
        return {
            **summary,
            "login_state": login_state,
            "pending_count": self.pending_retry_count,
            "sync_state": self.current_sync_state,
        }

    def diagnostic_report(self):
        return format_diagnostic_report(self.diagnostic_snapshot())

    def _publish_sync_state(self):
        v2_counts = None
        if self.is_v2_enabled:
            v2_counts = self._v2_store.counts(
                self._v2_context["local_key"]
            )
        persistent_count = (
            v2_counts.get("documents", v2_counts["total"])
            if v2_counts is not None else 0
        )
        pending_count = len(self._retry_queue) + persistent_count

        def publish(state, detail):
            self._set_sync_state(
                state, detail, pending_count=pending_count
            )

        server_state = self._current_project_server_state()
        if server_state == "trashed":
            publish(
                "project_trashed",
                "서버 휴지통에 있는 작품입니다. 동기화를 중지하고 로컬 원고만 보존합니다.",
            )
        elif server_state == "purged":
            publish(
                "project_purged",
                "서버에서 영구 삭제된 작품입니다. 기존 UUID의 동기화를 영구 중지합니다.",
            )
        elif self._auth_retry_blocked:
            publish(
                "auth_required",
                self._last_sync_error or (
                    "클라우드 로그인이 필요합니다. 로컬 저장은 계속되며, "
                    "다시 로그인하면 대기 작업이 이어서 전송됩니다."
                ),
            )
        elif self._active_server_syncs > 0:
            publish("syncing", "서버에 변경 내용을 올리는 중입니다.")
        elif v2_counts is not None and v2_counts["conflict"]:
            count = v2_counts["conflict"]
            publish("conflict", f"자동 병합할 수 없는 문서 충돌이 {count}건 있습니다.")
        elif v2_counts is not None and v2_counts["total"]:
            detail = self._v2_store.latest_error(self._v2_context["local_key"])
            if "LEASE_CONFLICT" in detail:
                publish(
                    "lease",
                    "다른 기기에서 이 문서를 편집 중입니다. 그 기기에서 문서를 닫은 뒤 다시 시도하세요.",
                )
                return
            offline = not detail or self._is_connectivity_error(detail) or "AUTH_REQUIRED" in detail
            publish(
                "offline" if offline else "failed",
                detail or "서버 전송을 기다리는 로컬 변경 사항이 있습니다.",
            )
        elif self._retry_queue:
            pending = list(self._retry_queue.values())
            state = "offline" if any(item.get("_retry_offline", False) for item in pending) else "failed"
            detail = next((item.get("_retry_error") for item in pending if item.get("_retry_error")), self._last_sync_error)
            publish(state, detail)
        elif self._active_backups > 0:
            publish("backup", "로컬 자동백업을 만드는 중입니다.")
        else:
            publish("saved", "현재 로컬 변경 사항이 저장되어 있습니다.")

    @staticmethod
    def _is_connectivity_error(error_msg):
        message = (error_msg or "").lower()
        markers = (
            "서버 연결 없음", "offline", "network", "connection", "disconnected",
            "테스트 오프라인",
            "timeout", "timed out", "dns", "unreachable", "refused", "winerror",
            "temporarily unavailable", "name or service",
        )
        return any(marker in message for marker in markers)

    @staticmethod
    def _v2_follow_up_delay_ms(
        kind, error_message="", lease_attempt=1, network_attempt=1
    ):
        if kind in {"committed", "auto_merged", "conflict"}:
            return 0
        if kind == "retry" and "LEASE_CONFLICT" in (error_message or ""):
            attempt_index = max(0, int(lease_attempt or 1) - 1)
            return LEASE_CONFLICT_RETRY_DELAYS_MS[
                min(attempt_index, len(LEASE_CONFLICT_RETRY_DELAYS_MS) - 1)
            ]
        if kind == "retry" and SyncManager._is_connectivity_error(error_message):
            attempt_index = max(0, int(network_attempt or 1) - 1)
            return NETWORK_RETRY_DELAYS_MS[
                min(attempt_index, len(NETWORK_RETRY_DELAYS_MS) - 1)
            ]
        return None

    def _cancel_scheduled_v2_retry(self, reset_backoff=False):
        self._v2_retry_timer.stop()
        self._v2_retry_context = None
        if reset_backoff:
            self._v2_lease_retry_operation_id = None
            self._v2_lease_retry_attempt = 0
            self._v2_network_retry_attempts.clear()

    def _next_lease_retry_attempt(self, operation_id):
        operation_id = str(operation_id or "")
        if operation_id != self._v2_lease_retry_operation_id:
            self._v2_lease_retry_operation_id = operation_id
            self._v2_lease_retry_attempt = 0
        self._v2_lease_retry_attempt += 1
        return self._v2_lease_retry_attempt

    def _reset_lease_retry_backoff(self, operation_id=None):
        if (
            operation_id is not None
            and str(operation_id) != self._v2_lease_retry_operation_id
        ):
            return
        self._v2_lease_retry_operation_id = None
        self._v2_lease_retry_attempt = 0

    def _schedule_v2_retry(self, delay_ms):
        context = self._v2_context or {}
        local_key = context.get("local_key")
        project_id = context.get("project_id")
        if (
            not local_key
            or not project_id
            or self._current_project_server_state() != "active"
        ):
            return False

        retry_context = (str(local_key), str(project_id))
        delay_ms = max(0, int(delay_ms))
        if (
            self._v2_retry_timer.isActive()
            and self._v2_retry_context == retry_context
        ):
            remaining_ms = self._v2_retry_timer.remainingTime()
            if 0 <= remaining_ms <= delay_ms:
                return False

        self._v2_retry_timer.stop()
        self._v2_retry_context = retry_context
        self._v2_retry_timer.start(delay_ms)
        return True

    def _run_scheduled_v2_retry(self):
        expected_context = self._v2_retry_context
        self._v2_retry_context = None
        current_context = self._v2_context or {}
        current_identity = (
            str(current_context.get("local_key") or ""),
            str(current_context.get("project_id") or ""),
        )
        if not expected_context or current_identity != expected_context:
            return False
        if (
            self._current_project_server_state() != "active"
            or is_forced_offline()
            or not self.supabase
        ):
            return False
        return self.retry_pending_syncs()

    def _queue_retry(self, key, payload, error_msg, offline=False):
        # 같은 파일은 가장 최신 내용 하나만 보관해 오래된 원고가 재전송되지 않게 한다.
        payload["_retry_error"] = error_msg or "서버 동기화에 실패했습니다."
        payload["_retry_offline"] = bool(offline)
        self._retry_queue[key] = payload
        self._last_sync_error = payload["_retry_error"]
        self._last_failure_offline = bool(offline)

    def retry_pending_syncs(self, manual=False):
        """다른 서버 요청이 성공한 뒤 대기 중인 항목을 한 건씩 다시 전송한다."""
        if self._auth_retry_blocked or self._shutting_down:
            self._publish_sync_state()
            return False
        if self._v2_retry_timer.isActive():
            if not manual:
                return False
            self._cancel_scheduled_v2_retry(reset_backoff=False)
        if self.is_v2_enabled:
            if self._current_project_server_state() != "active":
                self._publish_sync_state()
                return False
            if self._v2_worker is not None or self._active_server_syncs > 0:
                return False
            operation = self._v2_store.next_ready_operation(self._v2_context["local_key"])
            if operation:
                self._launch_v2_operation(operation)
                return True
        if self._retry_active_key is not None or self._active_server_syncs > 0 or not self._retry_queue:
            return False

        key, payload = next(iter(self._retry_queue.items()))
        self._retry_active_key = key
        kind = payload["kind"]
        if kind == "content":
            self._launch_content_upload(payload, key, is_retry=True)
        elif kind == "bulk":
            self._launch_bulk_upload(payload, key, is_retry=True)
        elif kind == "history":
            self._launch_history_upload(payload, key, is_retry=True)
        else:
            self._retry_queue.pop(key, None)
            self._retry_active_key = None
            self._publish_sync_state()
            return False
        return True

    def flush_pending_syncs(self, timeout_ms=8000):
        """Give durable Sync V2 operations a bounded chance to finish before exit."""
        if not self.is_v2_enabled:
            return True
        server_state = str(
            (getattr(self, "_v2_context", None) or {}).get(
                "server_state", "active"
            )
        )
        if server_state != "active":
            return True
        local_key = self._v2_context["local_key"]

        def current_counts():
            return self._v2_store.counts(local_key)

        counts = current_counts()
        if counts["conflict"]:
            return False
        if not counts["pending"] and not counts["inflight"]:
            return True
        if is_forced_offline() or not self.supabase:
            return False

        from PyQt6.QtCore import QEventLoop, QTimer

        loop = QEventLoop()
        poll_timer = QTimer()
        poll_timer.setInterval(100)
        timeout_timer = QTimer()
        timeout_timer.setSingleShot(True)
        completed = {"value": False}

        def check_state():
            counts_now = current_counts()
            if counts_now["conflict"]:
                loop.quit()
                return
            v2_worker_running = any(
                worker.isRunning()
                for worker in list(getattr(self, "_v2_workers", []))
            )
            if (
                not counts_now["pending"]
                and not counts_now["inflight"]
                and not v2_worker_running
            ):
                completed["value"] = True
                loop.quit()
                return
            if self._v2_worker is None and self._active_server_syncs == 0:
                self.retry_pending_syncs()

        poll_timer.timeout.connect(check_state)
        timeout_timer.timeout.connect(loop.quit)
        poll_timer.start()
        timeout_timer.start(max(1, int(timeout_ms)))
        check_state()
        if not completed["value"]:
            loop.exec()
        poll_timer.stop()
        timeout_timer.stop()
        return completed["value"]

    def _complete_server_attempt(self, key, payload, success, error_msg, worker, is_retry):
        self._active_server_syncs = max(0, self._active_server_syncs - 1)
        server_success = bool(success and getattr(worker, "supabase", None) is not None)
        effective_error = error_msg or ("" if server_success else "서버 연결 없음")

        if server_success:
            self._retry_queue.pop(key, None)
            self._last_sync_error = ""
            self._last_failure_offline = False
            self._record_sync_success()
        else:
            self._queue_retry(
                key,
                payload,
                effective_error,
                offline=getattr(worker, "supabase", None) is None or self._is_connectivity_error(effective_error),
            )

        if is_retry and self._retry_active_key == key:
            self._retry_active_key = None
        self._publish_sync_state()
        return server_success, effective_error
        
    @staticmethod
    def create_supabase_client():
        try:
            from supabase import create_client, Client, ClientOptions
            import httpx
            import os
            
            # PyInstaller exposes bundled data from _MEIPASS. Source runs use
            # this module's directory, so both paths load the same public
            # Supabase URL/publishable-key configuration.
            env_path = os.path.join(supabase_config_dir(), ".env")
            if os.path.exists(env_path):
                with open(env_path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            key, val = line.split("=", 1)
                            os.environ[key.strip()] = val.strip()
            
            url: str = os.environ.get("SUPABASE_URL", "https://dummy.supabase.co")
            key: str = os.environ.get("SUPABASE_KEY", "dummy-key")
            
            if url != "https://dummy.supabase.co":
                custom_httpx_client = httpx.Client(
                    timeout=5.0,
                    limits=httpx.Limits(max_keepalive_connections=5)
                )
                options = ClientOptions(httpx_client=custom_httpx_client)
                client = create_client(url, key, options=options)
                try:
                    client._antigravity_httpx_client = custom_httpx_client
                except Exception:
                    pass
                access_token = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
                refresh_token = os.environ.get("SUPABASE_REFRESH_TOKEN", "")
                if not (access_token and refresh_token):
                    try:
                        from security_manager import SecurityManager
                        access_token, refresh_token = SecurityManager.get_supabase_session()
                    except Exception:
                        access_token, refresh_token = "", ""
                authenticated = False
                try:
                    if access_token and refresh_token:
                        auth_response = client.auth.set_session(access_token, refresh_token)
                    else:
                        email = os.environ.get("SUPABASE_EMAIL", "").strip()
                        password = os.environ.get("SUPABASE_PASSWORD", "")
                        auth_response = None
                        if email and password:
                            auth_response = client.auth.sign_in_with_password({
                                "email": email,
                                "password": password,
                            })
                    session = getattr(auth_response, "session", None) if auth_response else None
                    if session:
                        SyncManager._persist_supabase_session(session)
                        authenticated = True
                        user = getattr(session, "user", None)
                        client._antigravity_email = getattr(user, "email", "") or ""
                except Exception as auth_error:
                    print(f"Supabase authentication unavailable: {auth_error}")
                    message = str(auth_error).lower()
                    if "refresh token" in message or "refresh_token" in message:
                        try:
                            from security_manager import SecurityManager
                            SecurityManager.clear_supabase_session()
                        except Exception:
                            pass
                try:
                    client._antigravity_authenticated = authenticated
                except Exception:
                    pass
                try:
                    def persist_auth_event(event, session):
                        event_name = str(getattr(event, "value", event) or "").upper()
                        if session and event_name in {
                            "SIGNED_IN", "TOKEN_REFRESHED", "USER_UPDATED"
                        }:
                            SyncManager._persist_supabase_session(session)
                            client._antigravity_authenticated = True
                            user = getattr(session, "user", None)
                            client._antigravity_email = (
                                getattr(user, "email", "") or ""
                            )

                    client.auth.on_auth_state_change(persist_auth_event)
                    client._antigravity_auth_callback = persist_auth_event
                except Exception as callback_error:
                    print(f"Supabase auth callback unavailable: {callback_error}")
                return client
            else:
                return None
        except Exception as e:
            print(f"Failed to create Supabase client: {e}")
            return None

    @staticmethod
    def _persist_supabase_session(session):
        access_token = getattr(session, "access_token", "")
        refresh_token = getattr(session, "refresh_token", "")
        if not (access_token and refresh_token):
            return False
        try:
            from security_manager import SecurityManager
            SecurityManager.save_supabase_session(access_token, refresh_token)
            return True
        except Exception as error:
            # Keep the valid in-memory session alive even if Windows Credential
            # Manager is temporarily unavailable. The next auth event retries it.
            print(f"Supabase session persistence unavailable: {error}")
            return False

    @staticmethod
    def _session_from_response(response):
        return getattr(response, "session", None) or response

    def _mark_auth_required(self, error=None):
        self._auth_retry_blocked = True
        self._last_failure_offline = True
        self._last_sync_error = (
            "AUTH_REQUIRED: 클라우드 로그인 세션을 갱신하지 못했습니다. "
            "설정 탭에서 다시 로그인하면 로컬 대기 작업이 이어서 전송됩니다."
        )
        if self.supabase:
            try:
                self.supabase._antigravity_authenticated = False
            except Exception:
                pass
        if error:
            print(f"Supabase session recovery paused: {error}")

    def ensure_session_valid(self, client=None, force_refresh=False):
        """Validate one shared session and serialize token refresh attempts."""
        client = client or self.supabase
        if not client:
            raise RuntimeError("AUTH_REQUIRED")
        auth = getattr(client, "auth", None)
        if auth is None:
            return True
        if self._auth_retry_blocked and not force_refresh:
            raise RuntimeError("AUTH_REQUIRED")

        observed_generation = self._auth_refresh_generation
        with self._session_refresh_lock:
            try:
                if force_refresh and observed_generation == self._auth_refresh_generation:
                    response = auth.refresh_session()
                    self._auth_refresh_generation += 1
                else:
                    response = auth.get_session()
                session = self._session_from_response(response)
                if not getattr(session, "access_token", "") or not getattr(
                    session, "refresh_token", ""
                ):
                    raise RuntimeError("AUTH_REQUIRED")
                self._persist_supabase_session(session)
                client._antigravity_authenticated = True
                self._auth_retry_blocked = False
                return True
            except Exception as error:
                self._mark_auth_required(error)
                raise RuntimeError("AUTH_REQUIRED") from error

    def _call_with_session(self, action, client=None):
        """Execute one server action with at most one token recovery retry."""
        client = client or self.supabase
        self.ensure_session_valid(client)
        try:
            return action()
        except Exception as error:
            if self._stable_error_code(error) != "AUTH_EXPIRED":
                raise
        self.ensure_session_valid(client, force_refresh=True)
        try:
            return action()
        except Exception as error:
            if self._stable_error_code(error) in {"AUTH_EXPIRED", "AUTH_REQUIRED"}:
                self._mark_auth_required(error)
                raise RuntimeError("AUTH_REQUIRED") from error
            raise

    @staticmethod
    def _close_supabase_client(client):
        http_client = getattr(client, "_antigravity_httpx_client", None)
        if http_client is not None:
            try:
                http_client.close()
            except Exception:
                pass

    def init_supabase(self):
        old_client = self.supabase
        self.supabase = self.create_supabase_client()
        if old_client is not None and old_client is not self.supabase:
            self._close_supabase_client(old_client)
        if not self.supabase:
            print("Warning: Supabase credentials not found in env. Running in mock mode.")

    def sign_in(self, email, password):
        if not email or not password:
            return False, "이메일과 비밀번호를 입력해주세요."
        if not self.supabase:
            self.init_supabase()
        if not self.supabase:
            return False, "Supabase 주소와 publishable key를 먼저 설정해주세요."
        try:
            response = self.supabase.auth.sign_in_with_password({
                "email": email.strip(),
                "password": password,
            })
            session = getattr(response, "session", None)
            if not session:
                return False, "로그인 세션을 받지 못했습니다."
            self._persist_supabase_session(session)
            try:
                self.supabase._antigravity_authenticated = True
            except Exception:
                pass
            self._auth_retry_blocked = False
            self._last_sync_error = ""
            self._last_failure_offline = False
            self._publish_sync_state()
            QTimer.singleShot(0, self.retry_pending_syncs)
            user = getattr(response, "user", None)
            signed_in_email = getattr(user, "email", None) or email.strip()
            self.supabase._antigravity_email = signed_in_email
            return True, signed_in_email
        except Exception as error:
            return False, str(error)

    def sign_out(self):
        try:
            if self.supabase:
                self.supabase.auth.sign_out()
        except Exception:
            pass
        from security_manager import SecurityManager
        SecurityManager.clear_supabase_session()
        try:
            if self.supabase:
                self.supabase._antigravity_authenticated = False
                self.supabase._antigravity_email = ""
        except Exception:
            pass
        self._auth_retry_blocked = True
        self._publish_sync_state()

    def authenticated_email(self):
        if not self.supabase or not getattr(
            self.supabase, "_antigravity_authenticated", True
        ):
            return ""
        return getattr(self.supabase, "_antigravity_email", "") or ""

    @staticmethod
    def _response_data(response):
        data = getattr(response, "data", response)
        if isinstance(data, list) and len(data) == 1:
            return data[0]
        return data

    @staticmethod
    def _stable_error_code(error):
        message = str(error)
        lowered = message.lower()
        if any(marker in lowered for marker in (
            "jwt expired", "pgrst303", "invalid jwt", "token has expired",
            "refresh token", "refresh_token", "authsessionmissing",
        )):
            return "AUTH_EXPIRED"
        if "permission denied for function" in lowered:
            return "SERVER_RPC_PERMISSION_DENIED"
        for code in (
            "AUTH_REQUIRED", "FORBIDDEN", "INVALID_ARGUMENT",
            "PROJECT_TRASHED", "PROJECT_PURGED", "PROJECT_NOT_FOUND",
            "DOCUMENT_NOT_FOUND", "DOCUMENT_ALREADY_EXISTS",
            "REVISION_CONFLICT", "OPERATION_ID_REUSED", "LEASE_REQUIRED",
            "LEASE_CONFLICT", "LEASE_EXPIRED", "PATH_CONFLICT",
        ):
            if code in message:
                return code
        return ""

    def _ensure_remote_project(self, client):
        response = client.rpc("ensure_project", {
            "p_project_id": self._v2_context["project_id"],
            "p_name": (
                self._v2_context.get("server_name")
                or self._v2_context["project_name"]
            ),
        }).execute()
        return self._response_data(response)

    def _fetch_v2_project_status(self, require_connection=False):
        if not self.is_v2_enabled or is_forced_offline() or not self.supabase:
            if require_connection:
                raise RuntimeError("NETWORK_UNAVAILABLE")
            return self._current_project_server_state()
        project_id = self._v2_context["project_id"]
        try:
            response = self._call_with_session(
                lambda: self.supabase.rpc(
                    "get_project_status",
                    {"p_project_id": project_id},
                ).execute(),
                self.supabase,
            )
            data = self._response_data(response) or {}
        except Exception as status_error:
            if self._stable_error_code(status_error) in {
                "AUTH_EXPIRED", "AUTH_REQUIRED"
            }:
                raise
            # Compatibility path for a server that has the project-trash
            # migration but has not deployed get_project_status yet.
            trashed_response = self._call_with_session(
                lambda: self.supabase.rpc(
                    "list_trashed_projects", {}
                ).execute(),
                self.supabase,
            )
            trashed_rows = getattr(trashed_response, "data", None)
            if not isinstance(trashed_rows, list):
                raise RuntimeError("INVALID_RESPONSE") from None
            if any(
                str(row.get("project_id") or "") == project_id
                for row in trashed_rows if isinstance(row, dict)
            ):
                data = {"state": "trashed"}
            else:
                active_response = self._call_with_session(
                    lambda: self.supabase.table("projects")
                    .select("project_id")
                    .eq("project_id", project_id)
                    .limit(1)
                    .execute(),
                    self.supabase,
                )
                active_rows = getattr(active_response, "data", None)
                if not isinstance(active_rows, list):
                    raise RuntimeError("INVALID_RESPONSE") from None
                data = {
                    "state": "active" if active_rows else "purged"
                }
        state = str(data.get("state") or "")
        if state not in {"active", "trashed", "purged"}:
            raise RuntimeError("INVALID_RESPONSE")
        self.mark_project_server_state(
            self._v2_context["project_id"], state
        )
        return state

    def _acquire_v2_lease(
        self, document_id, client=None, session_checked=False
    ):
        client = client or self.supabase
        if not client:
            raise RuntimeError("서버 연결 없음")
        action = lambda: client.rpc("acquire_edit_lease", {
                "p_document_id": document_id,
                "p_device_id": self._v2_device_id,
                "p_ttl_seconds": 90,
            }).execute()
        response = action() if session_checked else self._call_with_session(
            action, client
        )
        data = self._response_data(response) or {}
        token = data.get("lease_token")
        if not token:
            raise RuntimeError("LEASE_REQUIRED")
        self._v2_leases[document_id] = token
        return data

    def _fetch_remote_document(self, document_id, client=None):
        client = client or self.supabase
        response = (
            client.table("documents")
            .select(
                "document_id,relative_path,content,revision,is_deleted,deleted_at,updated_at"
            )
            .eq("document_id", document_id)
            .limit(1)
            .execute()
        )
        rows = getattr(response, "data", None) or []
        return rows[0] if rows else None

    def set_remote_protected_paths_provider(self, provider):
        self._v2_protected_paths_provider = provider

    def set_active_document_paths_provider(self, provider):
        self._v2_active_paths_provider = provider

    def _active_v2_paths(self):
        if not self._v2_active_paths_provider:
            return set()
        try:
            return {
                str(path or "").replace("\\", "/")
                for path in self._v2_active_paths_provider()
                if path
            }
        except (AttributeError, RuntimeError, TypeError):
            return set()

    def _release_v2_lease(self, document_id, client=None):
        token = self._v2_leases.get(document_id)
        if not token:
            return True
        if is_forced_offline():
            self._v2_leases.pop(document_id, None)
            return True
        supabase = client or self.supabase
        if not supabase:
            if self._v2_leases.get(document_id) == token:
                self._v2_leases.pop(document_id, None)
            return True
        try:
            self._call_with_session(
                lambda: supabase.rpc("release_edit_lease", {
                    "p_document_id": document_id,
                    "p_device_id": self._v2_device_id,
                    "p_lease_token": token,
                }).execute(),
                supabase,
            )
            if self._v2_leases.get(document_id) == token:
                self._v2_leases.pop(document_id, None)
            return True
        except Exception as error:
            print(f"Failed to release v2 edit lease: {error}")
            # Do not keep heartbeating a lease that we failed to release.
            # The server-side TTL can then expire naturally and another device
            # can continue editing instead of being blocked indefinitely.
            if self._v2_leases.get(document_id) == token:
                self._v2_leases.pop(document_id, None)
            return False

    def _acquire_v2_lease_async(self, document_id, client=None):
        return self._start_server_action(
            lambda: self._acquire_v2_lease(document_id, client=client)
        )

    def _release_v2_lease_async(self, document_id, client=None):
        return self._start_server_action(
            lambda: self._release_v2_lease(document_id, client=client)
        )

    def _finalize_v2_operation_lease(self, kind, operation):
        if not operation or kind == "auto_merged":
            return
        document_id = operation.get("document_id")
        if not document_id:
            return
        local_path = str(operation.get("local_path") or "").replace("\\", "/")
        is_active = local_path in self._active_v2_paths()

        # 새 문서는 첫 commit 때 lease_token 없이 생성된다. 생성 직후에도
        # 사용자가 편집 중이면 즉시 lease를 획득해 기존 문서와 동일하게
        # heartbeat를 유지하고 다른 기기의 덮어쓰기를 막는다.
        if (
            kind == "committed"
            and not operation.get("is_deleted")
            and is_active
            and document_id not in self._v2_leases
        ):
            self._acquire_v2_lease_async(document_id)
            return

        if document_id not in self._v2_leases:
            return

        # 활성 편집 문서는 저장이 끝나도 lease를 유지한다. 문서를 닫거나
        # 다른 문서로 이동했거나 삭제/충돌이 발생한 경우에만 해제한다.
        must_release = (
            kind in {"conflict", "project_disabled"}
            or bool(operation.get("is_deleted"))
            or not is_active
        )
        if must_release:
            self._release_v2_lease_async(document_id)

    def _fetch_v2_project_documents(
        self, require_connection=False, check_project_status=True
    ):
        if not self.is_v2_enabled or is_forced_offline() or not self.supabase:
            if require_connection:
                raise RuntimeError("NETWORK_UNAVAILABLE")
            return []
        if check_project_status:
            state = self._fetch_v2_project_status(
                require_connection=require_connection
            )
            if state == "trashed":
                raise RuntimeError("PROJECT_TRASHED")
            if state == "purged":
                raise RuntimeError("PROJECT_PURGED")
        response = self._call_with_session(
            lambda: self.supabase.table("documents")
            .select(
                "document_id,relative_path,content,revision,is_deleted,deleted_at,updated_at"
            )
            .eq("project_id", self._v2_context["project_id"])
            .execute(),
            self.supabase,
        )
        data = getattr(response, "data", None)
        if data is None:
            if require_connection:
                raise RuntimeError("INVALID_RESPONSE")
            return []
        if not isinstance(data, list):
            raise RuntimeError("INVALID_RESPONSE")
        return data

    @staticmethod
    def _safe_relative_path(path):
        normalized = unicodedata.normalize(
            "NFC", (path or "").replace("\\", "/").strip("/")
        )
        parts = [part for part in normalized.split("/") if part]
        if not parts or any(part in {".", ".."} for part in parts):
            raise ValueError("INVALID_REMOTE_PATH")
        return "/".join(parts)

    @staticmethod
    def _tree_path_comparison_key(path):
        return "/".join(
            unicodedata.normalize("NFC", part).casefold()
            for part in str(path or "").replace("\\", "/").split("/")
        )

    @staticmethod
    def _is_reparse_path(path):
        if os.path.islink(path):
            return True
        is_junction = getattr(os.path, "isjunction", None)
        if callable(is_junction) and is_junction(path):
            return True
        try:
            attributes = getattr(os.lstat(path), "st_file_attributes", 0)
        except OSError:
            return False
        return bool(
            attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
        )

    @staticmethod
    def _validate_tree_order_component(name):
        if not isinstance(name, str):
            raise ValueError("INVALID_REMOTE_PATH")
        name = unicodedata.normalize("NFC", name)
        try:
            validate_local_project_name(name)
        except LocalProjectPathError as error:
            raise ValueError("INVALID_REMOTE_PATH") from error
        if name == "__antigravity__":
            raise ValueError("INVALID_REMOTE_PATH")
        if len(name.encode("utf-16-le")) // 2 > MAX_WINDOWS_COMPONENT_UTF16_UNITS:
            raise ValueError("INVALID_REMOTE_PATH")
        return name

    @classmethod
    def _validate_tree_order_parent(cls, parent_path):
        if not isinstance(parent_path, str):
            raise ValueError("INVALID_REMOTE_PATH")
        if parent_path == "<root>":
            return parent_path
        normalized = unicodedata.normalize("NFC", parent_path.replace("\\", "/"))
        if (
            not normalized
            or normalized.startswith("/")
            or normalized.endswith("/")
            or "//" in normalized
        ):
            raise ValueError("INVALID_REMOTE_PATH")
        parts = normalized.split("/")
        if parts[0] != "메인":
            raise ValueError("INVALID_REMOTE_PATH")
        return "/".join(cls._validate_tree_order_component(part) for part in parts)

    @classmethod
    def _validated_remote_tree_order(cls, tree_order):
        validated = {}
        parent_keys = set()
        for raw_parent, raw_children in tree_order.items():
            parent = cls._validate_tree_order_parent(raw_parent)
            parent_key = cls._tree_path_comparison_key(parent)
            if parent_key in parent_keys:
                raise FileExistsError("REMOTE_PATH_CONFLICT")
            parent_keys.add(parent_key)
            if not isinstance(raw_children, list):
                raise ValueError("INVALID_REMOTE_PATH")

            children = []
            child_keys = set()
            for raw_child in raw_children:
                child = cls._validate_tree_order_component(raw_child)
                storage_name = (
                    TREE_ROOT_STORAGE_NAMES.get(child, child)
                    if parent == "<root>"
                    else child
                )
                child_key = unicodedata.normalize("NFC", storage_name).casefold()
                if child_key in child_keys:
                    raise FileExistsError("REMOTE_PATH_CONFLICT")
                child_keys.add(child_key)
                children.append(child)
            validated[parent] = children
        return validated

    @classmethod
    def _tree_order_child_path(cls, parent_path, child_name):
        storage_name = (
            TREE_ROOT_STORAGE_NAMES.get(child_name, child_name)
            if parent_path == "<root>"
            else child_name
        )
        if parent_path == "<root>":
            return f"메인/{storage_name}"
        return f"{parent_path}/{storage_name}"

    @classmethod
    def _safe_existing_tree_directory(cls, root, relative_path):
        full_path = os.path.abspath(os.path.join(root, relative_path))
        if not os.path.lexists(full_path):
            return False
        if cls._is_reparse_path(full_path) or not os.path.isdir(full_path):
            raise FileExistsError("REMOTE_PATH_CONFLICT")
        real_root = os.path.realpath(root)
        real_path = os.path.realpath(full_path)
        try:
            if os.path.commonpath([real_root, real_path]) != real_root:
                raise FileExistsError("REMOTE_PATH_CONFLICT")
        except ValueError as error:
            raise FileExistsError("REMOTE_PATH_CONFLICT") from error
        return True

    @classmethod
    def _build_remote_tree_folder_plan(
        cls, writing_root, tree_order, remote_live_document_paths
    ):
        root = os.path.abspath(writing_root)
        if not cls._safe_existing_tree_directory(root, ""):
            raise ValueError("INVALID_REMOTE_PATH")

        live_path_keys = {
            cls._tree_path_comparison_key(cls._safe_relative_path(path))
            for path in (remote_live_document_paths or set())
        }
        candidate_paths = {}
        document_paths = {}

        def add_candidate(relative_path):
            relative_path = cls._validate_tree_order_parent(relative_path)
            if relative_path == "<root>":
                return
            parts = relative_path.split("/")
            for depth in range(1, len(parts) + 1):
                candidate = "/".join(parts[:depth])
                if candidate == "메인/휴지통" or candidate.startswith(
                    "메인/휴지통/"
                ):
                    return
                key = cls._tree_path_comparison_key(candidate)
                previous = candidate_paths.get(key)
                if previous is not None and previous != candidate:
                    raise FileExistsError("REMOTE_PATH_CONFLICT")
                candidate_paths[key] = candidate

        for parent_path in tree_order:
            if parent_path != "<root>":
                add_candidate(parent_path)
            else:
                add_candidate("메인")
        for parent_path, child_names in tree_order.items():
            for child_name in child_names:
                child_path = cls._tree_order_child_path(parent_path, child_name)
                child_key = cls._tree_path_comparison_key(child_path)
                if child_key in live_path_keys:
                    document_paths[child_key] = child_path
                    continue
                add_candidate(child_path)

        if set(candidate_paths).intersection(live_path_keys):
            raise FileExistsError("REMOTE_PATH_CONFLICT")

        plan = []
        planned_keys = set(candidate_paths)
        for relative_path in sorted(
            candidate_paths.values(), key=lambda path: (path.count("/"), path.casefold())
        ):
            full_path = os.path.abspath(os.path.join(root, relative_path))
            try:
                if os.path.commonpath([root, full_path]) != root:
                    raise ValueError("INVALID_REMOTE_PATH")
            except ValueError as error:
                raise ValueError("INVALID_REMOTE_PATH") from error
            if (
                len(full_path.encode("utf-16-le")) // 2
                > MAX_WINDOWS_DIRECTORY_PATH
            ):
                raise ValueError("INVALID_REMOTE_PATH")

            parent_relative = relative_path.rpartition("/")[0]
            parent_full = root if not parent_relative else os.path.join(root, parent_relative)
            parent_key = cls._tree_path_comparison_key(parent_relative)
            parent_exists = cls._safe_existing_tree_directory(root, parent_relative)
            if not parent_exists and parent_key not in planned_keys:
                raise FileExistsError("REMOTE_PATH_CONFLICT")

            existing_name = None
            if parent_exists:
                requested_name = relative_path.rpartition("/")[2]
                requested_key = unicodedata.normalize("NFC", requested_name).casefold()
                matches = [
                    entry
                    for entry in os.listdir(parent_full)
                    if unicodedata.normalize("NFC", entry).casefold() == requested_key
                ]
                if len(matches) > 1 or (matches and matches[0] != requested_name):
                    raise FileExistsError("REMOTE_PATH_CONFLICT")
                existing_name = matches[0] if matches else None

            exists = existing_name is not None or os.path.lexists(full_path)
            if exists:
                cls._safe_existing_tree_directory(root, relative_path)
            plan.append({
                "relative_path": relative_path,
                "full_path": full_path,
                "exists": exists,
            })

        for relative_path in document_paths.values():
            full_path = os.path.abspath(os.path.join(root, relative_path))
            if (
                len(full_path.encode("utf-16-le")) // 2
                > MAX_WINDOWS_DIRECTORY_PATH
            ):
                raise ValueError("INVALID_REMOTE_PATH")
            parent_relative = relative_path.rpartition("/")[0]
            parent_full = os.path.join(root, parent_relative)
            if not os.path.lexists(parent_full):
                continue
            cls._safe_existing_tree_directory(root, parent_relative)
            requested_name = relative_path.rpartition("/")[2]
            requested_key = unicodedata.normalize("NFC", requested_name).casefold()
            matches = [
                entry
                for entry in os.listdir(parent_full)
                if unicodedata.normalize("NFC", entry).casefold() == requested_key
            ]
            if len(matches) > 1 or (matches and matches[0] != requested_name):
                raise FileExistsError("REMOTE_PATH_CONFLICT")
            if matches:
                existing_path = os.path.join(parent_full, matches[0])
                if cls._is_reparse_path(existing_path) or not os.path.isfile(
                    existing_path
                ):
                    raise FileExistsError("REMOTE_PATH_CONFLICT")
        return plan

    @classmethod
    def _rollback_remote_tree_folders(cls, root, created_paths):
        root = os.path.abspath(root)
        for full_path in reversed(created_paths):
            try:
                if (
                    os.path.commonpath([root, os.path.abspath(full_path)]) == root
                    and os.path.isdir(full_path)
                    and not cls._is_reparse_path(full_path)
                ):
                    os.rmdir(full_path)
            except (OSError, ValueError):
                pass

    def _save_remote_tree_order_settings(self, tree_order):
        self._v2_wpm.project_settings["tree_order"] = tree_order
        if self._v2_wpm.save_settings() is False:
            raise OSError("REMOTE_DOCUMENT_WRITE_FAILED")

    def _apply_remote_tree_order_document(
        self,
        document_id,
        content,
        revision,
        is_deleted=False,
        remote_live_document_paths=None,
    ):
        if is_deleted:
            return None
        try:
            payload = json.loads(content or "{}")
        except (TypeError, json.JSONDecodeError):
            return None
        if payload.get("version") != 1:
            return None
        raw_order = payload.get("tree_order")
        if not isinstance(raw_order, dict) or not raw_order:
            return None
        remote_order = self._validated_remote_tree_order(raw_order)
        remote_order = {
            key: value
            for key, value in remote_order.items()
            if key != "메인/휴지통" and not key.startswith("메인/휴지통/")
        }
        if not remote_order:
            return None
        folder_plan = self._build_remote_tree_folder_plan(
            self._v2_wpm.writing_root_path,
            remote_order,
            remote_live_document_paths,
        )

        existing = self._v2_store.get_document_by_id(document_id)
        existing_revision = int((existing or {}).get("revision") or 0)
        baseline_already_applied = bool(
            existing
            and revision == existing_revision
            and existing.get("base_content") == content
            and not self._v2_store.has_active_operations(document_id)
        )
        if existing and revision <= existing_revision and not baseline_already_applied:
            return None

        local_order = getattr(self._v2_wpm, "project_settings", {}).get(
            "tree_order", {}
        )
        merged_order = dict(remote_order)
        if isinstance(local_order, dict):
            merged_order.update({
                key: copy.deepcopy(value)
                for key, value in local_order.items()
                if key == "메인/휴지통" or key.startswith("메인/휴지통/")
            })
        if (
            baseline_already_applied
            and local_order == merged_order
            and all(item["exists"] for item in folder_plan)
        ):
            return None

        had_tree_order = "tree_order" in self._v2_wpm.project_settings
        previous_tree_order = copy.deepcopy(local_order)
        created_paths = []
        settings_were_saved = False
        try:
            for item in folder_plan:
                if item["exists"]:
                    continue
                try:
                    os.mkdir(item["full_path"])
                    created_paths.append(item["full_path"])
                except FileExistsError:
                    if not self._safe_existing_tree_directory(
                        self._v2_wpm.writing_root_path, item["relative_path"]
                    ):
                        raise

            self._save_remote_tree_order_settings(merged_order)
            settings_were_saved = True
            if not baseline_already_applied:
                applied = self._v2_store.apply_remote_snapshot(
                    self._v2_context,
                    document_id,
                    TREE_ORDER_DOCUMENT_PATH,
                    content,
                    revision,
                    is_deleted=False,
                    local_path=TREE_ORDER_DOCUMENT_PATH,
                )
                if not applied.get("applied"):
                    raise RuntimeError(
                        "REMOTE_SNAPSHOT_APPLY_FAILED:"
                        + str(applied.get("reason") or "unknown")
                    )
        except Exception:
            if settings_were_saved:
                if had_tree_order:
                    self._v2_wpm.project_settings["tree_order"] = previous_tree_order
                else:
                    self._v2_wpm.project_settings.pop("tree_order", None)
                try:
                    self._v2_wpm.save_settings()
                except Exception:
                    pass
            else:
                if had_tree_order:
                    self._v2_wpm.project_settings["tree_order"] = previous_tree_order
                else:
                    self._v2_wpm.project_settings.pop("tree_order", None)
            self._rollback_remote_tree_folders(
                self._v2_wpm.writing_root_path, created_paths
            )
            raise

        return {
            "kind": "tree_order",
            "document_id": document_id,
            "old_local_path": TREE_ORDER_DOCUMENT_PATH,
            "new_local_path": TREE_ORDER_DOCUMENT_PATH,
            "remote_path": TREE_ORDER_DOCUMENT_PATH,
            "content": content,
            "revision": revision,
            "is_deleted": False,
        }

    def _apply_remote_trash_purge_document(
        self, document_id, content, revision, is_deleted=False
    ):
        if is_deleted:
            return None
        try:
            payload = json.loads(content or "{}")
        except (TypeError, json.JSONDecodeError):
            return None
        remote_purges = self._normalized_trash_purges(
            payload.get("purged_revisions")
        )
        empty_generation = str(payload.get("empty_generation") or "")
        applied = self._v2_store.apply_remote_snapshot(
            self._v2_context,
            document_id,
            TRASH_PURGE_DOCUMENT_PATH,
            content,
            revision,
            is_deleted=False,
            local_path=TRASH_PURGE_DOCUMENT_PATH,
        )
        if not applied.get("applied"):
            return None

        local_purges = self._normalized_trash_purges(
            self._v2_wpm.project_settings.get("trash_purged_revisions", {})
        )
        for purged_id, purged_revision in remote_purges.items():
            local_purges[purged_id] = max(
                local_purges.get(purged_id, 0), purged_revision
            )

        previous_generation = str(
            self._v2_wpm.project_settings.get("trash_empty_generation", "")
        )
        if empty_generation and empty_generation != previous_generation:
            self._v2_wpm.empty_trash()
            self._v2_wpm.project_settings["trash_empty_generation"] = empty_generation

        self._v2_wpm.project_settings["trash_purged_revisions"] = local_purges
        self._v2_wpm.save_settings()

        for document in self._v2_store.list_documents(
            self._v2_context["local_key"]
        ):
            purged_revision = local_purges.get(document["document_id"], 0)
            if not document.get("is_deleted") or purged_revision < int(
                document.get("revision") or 0
            ):
                continue
            local_path = str(document.get("local_path") or "")
            if local_path.startswith("메인/휴지통/"):
                self._v2_wpm.delete_from_trash(local_path)
            self._v2_store.relocate_deleted_document(
                document["document_id"],
                f"__antigravity__/purged/{document['document_id']}",
            )

        return {
            "kind": "trash_purge",
            "document_id": document_id,
            "old_local_path": TRASH_PURGE_DOCUMENT_PATH,
            "new_local_path": TRASH_PURGE_DOCUMENT_PATH,
            "remote_path": TRASH_PURGE_DOCUMENT_PATH,
            "content": content,
            "revision": revision,
            "is_deleted": False,
        }

    def _apply_v2_remote_documents(self, remote_documents, strict=False):
        if not self.is_v2_enabled or not self._v2_wpm:
            return []
        try:
            protected = set(
                (self._v2_protected_paths_provider or (lambda: set()))() or set()
            )
        except Exception:
            protected = set()
        protected = {
            unicodedata.normalize("NFC", path.replace("\\", "/"))
            for path in protected
            if path
        }
        active_paths = {
            unicodedata.normalize("NFC", path)
            for path in self._active_v2_paths()
            if path
        }
        changes = []
        root = os.path.abspath(self._v2_wpm.writing_root_path)

        remote_live_document_paths = set()
        for remote in remote_documents or []:
            if bool(remote.get("is_deleted")):
                continue
            try:
                remote_path = self._safe_relative_path(remote.get("relative_path"))
            except ValueError:
                continue
            if is_live_document_path(remote_path):
                remote_live_document_paths.add(remote_path)

        def full_path(relative_path):
            candidate = os.path.abspath(os.path.join(root, relative_path))
            if os.path.commonpath([root, candidate]) != root:
                raise ValueError("INVALID_REMOTE_PATH")
            return candidate

        # Tombstones vacate reused paths first. Live documents then create their
        # parent paths before tree-order materializes entries with no document row.
        ordered_remote_documents = sorted(
            remote_documents or [],
            key=lambda item: (
                0
                if str(item.get("relative_path") or "").replace("\\", "/")
                == TRASH_PURGE_DOCUMENT_PATH
                else (
                    1
                    if bool(item.get("is_deleted"))
                    else (
                        3
                        if str(item.get("relative_path") or "").replace("\\", "/")
                        == TREE_ORDER_DOCUMENT_PATH
                        else 2
                    )
                ),
                int(item.get("revision") or 0),
            ),
        )
        for remote in ordered_remote_documents:
            try:
                document_id = str(uuid.UUID(str(remote.get("document_id"))))
                remote_path = self._safe_relative_path(remote.get("relative_path"))
                revision = int(remote.get("revision") or 0)
                content = remote.get("content") or ""
                is_deleted = bool(remote.get("is_deleted"))
                deleted_at = remote.get("deleted_at") or remote.get("updated_at")
                if remote_path == TREE_ORDER_DOCUMENT_PATH:
                    change = self._apply_remote_tree_order_document(
                        document_id,
                        content,
                        revision,
                        is_deleted,
                        remote_live_document_paths,
                    )
                    if change:
                        changes.append(change)
                    continue
                if remote_path == TRASH_PURGE_DOCUMENT_PATH:
                    change = self._apply_remote_trash_purge_document(
                        document_id, content, revision, is_deleted
                    )
                    if change:
                        changes.append(change)
                    continue
                if not is_deleted and not is_live_document_path(remote_path):
                    continue
                document = self._v2_store.get_document_by_id(document_id)
                old_path = document.get("local_path") if document else None
                canonical_old_path = (
                    self._safe_relative_path(old_path) if old_path else None
                )
                repair_unicode_path = bool(
                    document
                    and not is_deleted
                    and old_path != remote_path
                    and canonical_old_path == remote_path
                    and revision == int(document.get("revision") or 0)
                )
                purged_revision = self._normalized_trash_purges(
                    self._v2_wpm.project_settings.get(
                        "trash_purged_revisions", {}
                    )
                ).get(document_id, 0)
                if is_deleted and purged_revision >= revision:
                    if self._v2_store.has_active_operations(document_id):
                        continue
                    if old_path and str(old_path).startswith("메인/휴지통/"):
                        self._v2_wpm.delete_from_trash(old_path)
                    virtual_path = f"__antigravity__/purged/{document_id}"
                    if document and revision <= int(document.get("revision") or 0):
                        applied = self._v2_store.relocate_deleted_document(
                            document_id, virtual_path
                        )
                    else:
                        applied = self._v2_store.apply_remote_snapshot(
                            self._v2_context,
                            document_id,
                            remote_path,
                            content,
                            revision,
                            is_deleted=True,
                            local_path=virtual_path,
                        )
                    if applied.get("applied"):
                        changes.append({
                            "kind": "purged_tombstone",
                            "document_id": document_id,
                            "old_local_path": old_path,
                            "new_local_path": virtual_path,
                            "remote_path": remote_path,
                            "content": content,
                            "revision": revision,
                            "is_deleted": True,
                        })
                    continue

                tombstone_copy_missing = bool(
                    document
                    and is_deleted
                    and document.get("is_deleted")
                    and str(old_path or "").startswith("메인/휴지통/")
                    and not os.path.exists(full_path(old_path))
                )
                repair_tombstone_location = bool(
                    document
                    and is_deleted
                    and document.get("is_deleted")
                    and (
                        not str(old_path or "").startswith("메인/휴지통/")
                        or tombstone_copy_missing
                    )
                )
                repair_live_copy = bool(
                    document
                    and not is_deleted
                    and not document.get("is_deleted")
                    and revision == int(document.get("revision") or 0)
                    and old_path == remote_path
                    and not os.path.exists(full_path(old_path))
                )

                # Another Windows instance can update the shared durable store
                # and disk before this visible instance handles the same pull.
                # In that case the revision is equal, but the clean open editor
                # still needs a refresh notification.
                equal_revision_active_refresh = bool(
                    document
                    and not is_deleted
                    and revision == int(document.get("revision") or 0)
                    and old_path == remote_path
                    and remote_path in active_paths
                )
                if equal_revision_active_refresh:
                    if self._v2_store.has_active_operations(document_id):
                        continue
                    if remote_path in protected:
                        continue
                    if self._v2_wpm.read_text_file(remote_path) != content:
                        if not self._v2_wpm.write_text_file(remote_path, content):
                            if strict:
                                raise OSError("REMOTE_DOCUMENT_WRITE_FAILED")
                            continue
                    changes.append({
                        "kind": "remote_refresh",
                        "document_id": document_id,
                        "old_local_path": old_path,
                        "new_local_path": remote_path,
                        "remote_path": remote_path,
                        "content": content,
                        "revision": revision,
                        "is_deleted": False,
                    })
                    continue

                if revision <= 0 or (
                    document
                    and revision <= document["revision"]
                    and not repair_tombstone_location
                    and not repair_live_copy
                    and not repair_unicode_path
                ):
                    if strict and revision <= 0:
                        raise ValueError("INVALID_REMOTE_REVISION")
                    continue
                if self._v2_store.has_active_operations(document_id):
                    if strict:
                        raise RuntimeError("REMOTE_DOCUMENT_HAS_LOCAL_OPERATIONS")
                    continue
                if remote_path in protected or (old_path and old_path in protected):
                    if strict:
                        raise RuntimeError("REMOTE_DOCUMENT_PATH_IS_PROTECTED")
                    continue

                local_path = old_path or remote_path
                renamed_from = None
                renamed_to = None
                created_tombstone_path = None
                duplicate_unicode_path = None

                if is_deleted:
                    if repair_tombstone_location:
                        # The live path may already belong to a replacement UUID.
                        # Preserve the old tombstone separately without moving it.
                        local_path = self._v2_wpm.materialize_remote_tombstone(
                            remote_path, content, deleted_at, document_id
                        )
                        created_tombstone_path = local_path
                        renamed_from, renamed_to = old_path, local_path
                    elif old_path and not old_path.startswith("메인/휴지통/"):
                        old_full = full_path(old_path)
                        if os.path.exists(old_full):
                            os.makedirs(full_path("메인/휴지통"), exist_ok=True)
                            local_path = self._v2_wpm.move_to_trash(
                                old_path, deleted_at, document_id
                            )
                            renamed_from, renamed_to = old_path, local_path
                        else:
                            local_path = self._v2_wpm.materialize_remote_tombstone(
                                remote_path, content, deleted_at, document_id
                            )
                            created_tombstone_path = local_path
                            renamed_from, renamed_to = old_path, local_path
                    elif old_path and old_path.startswith("메인/휴지통/"):
                        local_path = old_path
                        if not os.path.exists(full_path(local_path)):
                            local_path = self._v2_wpm.materialize_remote_tombstone(
                                remote_path, content, deleted_at, document_id
                            )
                            created_tombstone_path = local_path
                        elif not self._v2_wpm.write_text_file(local_path, content):
                            if strict:
                                raise OSError("REMOTE_DOCUMENT_WRITE_FAILED")
                            continue
                    else:
                        local_path = self._v2_wpm.materialize_remote_tombstone(
                            remote_path, content, deleted_at, document_id
                        )
                        created_tombstone_path = local_path
                    if not self._v2_wpm.write_text_file(local_path, content):
                        if created_tombstone_path:
                            self._v2_wpm.delete_from_trash(created_tombstone_path)
                        if strict:
                            raise OSError("REMOTE_DOCUMENT_WRITE_FAILED")
                        continue
                else:
                    local_path = remote_path
                    old_full = full_path(old_path) if old_path else None
                    new_full = full_path(local_path)
                    if old_path and old_path != local_path and old_full and os.path.exists(old_full):
                        if os.path.exists(new_full):
                            if not repair_unicode_path:
                                if strict:
                                    raise FileExistsError("REMOTE_PATH_CONFLICT")
                                continue
                            try:
                                with open(old_full, "r", encoding="utf-8") as source:
                                    old_content = source.read()
                                with open(new_full, "r", encoding="utf-8") as source:
                                    new_content = source.read()
                            except OSError:
                                if strict:
                                    raise
                                continue
                            if old_content != content or new_content != content:
                                if strict:
                                    raise FileExistsError("REMOTE_PATH_CONFLICT")
                                continue
                            duplicate_unicode_path = old_path
                        else:
                            os.makedirs(os.path.dirname(new_full), exist_ok=True)
                            os.rename(old_full, new_full)
                            renamed_from, renamed_to = old_path, local_path
                    elif repair_unicode_path and os.path.exists(new_full):
                        try:
                            with open(new_full, "r", encoding="utf-8") as source:
                                new_content = source.read()
                        except OSError:
                            if strict:
                                raise
                            continue
                        if new_content != content:
                            if strict:
                                raise FileExistsError("REMOTE_PATH_CONFLICT")
                            continue
                    elif not old_path and os.path.exists(new_full):
                        try:
                            with open(new_full, "r", encoding="utf-8") as source:
                                if source.read() != content:
                                    if strict:
                                        raise FileExistsError(
                                            "REMOTE_PATH_CONFLICT"
                                        )
                                    continue
                        except OSError:
                            if strict:
                                raise
                            continue

                    if not self._v2_wpm.write_text_file(local_path, content):
                        if renamed_from and renamed_to:
                            try:
                                os.rename(full_path(renamed_to), full_path(renamed_from))
                            except OSError:
                                pass
                        if strict:
                            raise OSError("REMOTE_DOCUMENT_WRITE_FAILED")
                        continue

                if repair_unicode_path:
                    applied = self._v2_store.repair_clean_document_path(
                        document_id, local_path, remote_path
                    )
                elif repair_live_copy:
                    applied = {
                        "applied": True,
                        "reason": "restored_missing_local_copy",
                    }
                elif (
                    repair_tombstone_location
                    and revision <= int(document.get("revision") or 0)
                ):
                    applied = self._v2_store.relocate_deleted_document(
                        document_id, local_path
                    )
                else:
                    applied = self._v2_store.apply_remote_snapshot(
                        self._v2_context,
                        document_id,
                        remote_path,
                        content,
                        revision,
                        is_deleted=is_deleted,
                        local_path=local_path,
                    )
                if not applied.get("applied"):
                    if created_tombstone_path:
                        try:
                            self._v2_wpm.delete_from_trash(created_tombstone_path)
                        except Exception:
                            pass
                    if renamed_from and renamed_to:
                        try:
                            os.rename(full_path(renamed_to), full_path(renamed_from))
                        except OSError:
                            pass
                    if strict:
                        raise RuntimeError(
                            "REMOTE_SNAPSHOT_APPLY_FAILED:"
                            + str(applied.get("reason") or "unknown")
                        )
                    continue
                if duplicate_unicode_path:
                    try:
                        os.remove(full_path(duplicate_unicode_path))
                    except OSError:
                        pass
                if repair_unicode_path:
                    self._prune_empty_unicode_path_parents(
                        root, full_path(old_path)
                    )
                if is_deleted:
                    self._v2_wpm.update_trash_metadata(
                        local_path, deleted_at, document_id
                    )
                changes.append({
                    "document_id": document_id,
                    "old_local_path": old_path,
                    "new_local_path": local_path,
                    "remote_path": remote_path,
                    "content": content,
                    "revision": revision,
                    "is_deleted": is_deleted,
                })
            except Exception as error:
                if strict:
                    raise
                print(f"Failed to apply remote v2 document: {error}")
        return changes

    @staticmethod
    def _prune_empty_unicode_path_parents(root, old_file_path):
        """Remove only empty legacy NFD directories left by a path repair."""
        root = os.path.abspath(root)
        current = os.path.dirname(os.path.abspath(old_file_path))
        while current != root:
            try:
                if os.path.commonpath([root, current]) != root:
                    break
                os.rmdir(current)
            except OSError:
                break
            current = os.path.dirname(current)

    def pull_remote_changes_async(self):
        if not self.is_v2_enabled or is_forced_offline() or not self.supabase:
            return False
        if self._v2_pull_worker is not None:
            try:
                if self._v2_pull_worker.isRunning():
                    return False
            except RuntimeError:
                self._v2_pull_worker = None

        worker = V2PullWorker(self)
        self._v2_pull_worker = worker

        def handle_result(success, payload):
            if success:
                changes = self._apply_v2_remote_documents(payload)
                self._record_sync_success()
                if changes:
                    self.remoteDocumentsApplied.emit(changes)
            else:
                code = self._stable_error_code(payload)
                if code == "PROJECT_TRASHED":
                    self.mark_project_server_state(
                        self._v2_context["project_id"], "trashed"
                    )
                elif code in {"PROJECT_PURGED", "PROJECT_NOT_FOUND"}:
                    self.mark_project_server_state(
                        self._v2_context["project_id"], "purged"
                    )
                print(f"Failed to pull v2 documents: {payload}")

        def handle_finished():
            if self._v2_pull_worker is worker:
                self._v2_pull_worker = None

        worker.resultReady.connect(handle_result)
        worker.finished.connect(handle_finished)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)
        return True

    def _process_v2_operation(self, operation_id):
        operation = self._v2_store.operation(operation_id)
        if not operation:
            return {"kind": "retry", "error": "대기 작업을 찾을 수 없습니다."}
        if is_forced_offline():
            error = "테스트 오프라인 모드"
            self._v2_store.mark_retry(operation_id, error)
            return {"kind": "retry", "error": error, "operation": operation}
        client = self.supabase
        if not client:
            error = "서버 연결 없음"
            self._v2_store.mark_retry(operation_id, error)
            return {"kind": "retry", "error": error, "operation": operation}

        try:
            for auth_attempt in range(2):
                try:
                    self.ensure_session_valid(
                        client, force_refresh=bool(auth_attempt)
                    )
                    self._ensure_remote_project(client)
                    lease_token = None
                    if operation["base_revision"] > 0:
                        lease_token = self._acquire_v2_lease(
                            operation["document_id"], client, session_checked=True
                        ).get("lease_token")

                    response = client.rpc("commit_document", {
                        "p_document_id": operation["document_id"],
                        "p_project_id": operation["project_id"],
                        "p_base_revision": operation["base_revision"],
                        "p_operation_id": operation["operation_id"],
                        "p_device_id": self._v2_device_id,
                        "p_relative_path": operation["relative_path"],
                        "p_content": operation["content"],
                        "p_is_deleted": bool(operation["is_deleted"]),
                        "p_lease_token": lease_token,
                    }).execute()
                    result = self._response_data(response) or {}
                    if "revision" not in result:
                        raise RuntimeError(
                            "commit_document 응답에 revision이 없습니다."
                        )
                    return {
                        "kind": "committed",
                        "result": result,
                        "operation": operation,
                    }
                except Exception as auth_error:
                    if (
                        auth_attempt == 0
                        and self._stable_error_code(auth_error) in {
                            "AUTH_EXPIRED", "AUTH_REQUIRED"
                        }
                    ):
                        continue
                    raise
        except Exception as error:
            code = self._stable_error_code(error)
            if code in {"AUTH_EXPIRED", "AUTH_REQUIRED"}:
                self._mark_auth_required(error)
                message = self._last_sync_error
                self._v2_store.mark_retry(operation_id, message)
                return {
                    "kind": "auth_required",
                    "error": message,
                    "operation": operation,
                }
            if code in {
                "PROJECT_TRASHED", "PROJECT_PURGED", "PROJECT_NOT_FOUND"
            }:
                state = (
                    "trashed" if code == "PROJECT_TRASHED" else "purged"
                )
                self.mark_project_server_state(
                    operation["project_id"], state
                )
                self._v2_store.mark_retry(operation_id, code)
                return {
                    "kind": "project_disabled",
                    "error": code,
                    "operation": operation,
                }
            if code in {"REVISION_CONFLICT", "DOCUMENT_ALREADY_EXISTS"}:
                remote = self._fetch_remote_document(operation["document_id"], client)
                if not remote:
                    message = "REVISION_CONFLICT: 서버 문서를 읽을 수 없습니다."
                    self._v2_store.mark_retry(operation_id, message)
                    return {"kind": "retry", "error": message, "operation": operation}
                if operation["relative_path"] == TREE_ORDER_DOCUMENT_PATH:
                    # Binder order is one project preference snapshot. A later local
                    # reorder rebases onto the newest server revision and becomes the
                    # next atomic update instead of creating a manuscript conflict.
                    self._v2_store.rebase_clean_merge(
                        operation_id,
                        remote["revision"],
                        remote.get("content", ""),
                        operation["content"],
                    )
                    return {
                        "kind": "auto_merged",
                        "operation": operation,
                        "remote": remote,
                        "merged_content": operation["content"],
                        "old_local_path": TREE_ORDER_DOCUMENT_PATH,
                        "new_local_path": TREE_ORDER_DOCUMENT_PATH,
                    }
                if operation["relative_path"] == TRASH_PURGE_DOCUMENT_PATH:
                    try:
                        local_payload = json.loads(operation.get("content") or "{}")
                    except (TypeError, json.JSONDecodeError):
                        local_payload = {}
                    try:
                        remote_payload = json.loads(remote.get("content") or "{}")
                    except (TypeError, json.JSONDecodeError):
                        remote_payload = {}
                    merged_purges = self._normalized_trash_purges(
                        remote_payload.get("purged_revisions")
                    )
                    for purged_id, purged_revision in self._normalized_trash_purges(
                        local_payload.get("purged_revisions")
                    ).items():
                        merged_purges[purged_id] = max(
                            merged_purges.get(purged_id, 0), purged_revision
                        )
                    generation = (
                        local_payload.get("empty_generation")
                        or remote_payload.get("empty_generation")
                        or ""
                    )
                    merged_content = self._trash_purge_content(
                        merged_purges, generation
                    )
                    self._v2_store.rebase_clean_merge(
                        operation_id,
                        remote["revision"],
                        remote.get("content", ""),
                        merged_content,
                    )
                    return {
                        "kind": "auto_merged",
                        "operation": operation,
                        "remote": remote,
                        "merged_content": merged_content,
                        "old_local_path": TRASH_PURGE_DOCUMENT_PATH,
                        "new_local_path": TRASH_PURGE_DOCUMENT_PATH,
                    }
                latest_local_content = operation["content"]
                if self._v2_wpm:
                    disk_content = self._v2_wpm.read_text_file(operation["local_path"])
                    if disk_content is not None:
                        latest_local_content = disk_content
                merge = three_way_merge(
                    operation["base_content"], latest_local_content, remote.get("content", "")
                )
                if not merge.has_conflicts:
                    old_local_path = operation["local_path"]
                    new_local_path = old_local_path
                    document = self._v2_store.get_document_by_id(operation["document_id"])
                    remote_path = remote.get("relative_path", operation["relative_path"])
                    local_path_was_changed = bool(
                        document and operation["relative_path"] != document.get("server_path")
                    )
                    if remote_path != operation["relative_path"] and not local_path_was_changed:
                        new_local_path = remote_path
                        if self._v2_wpm and old_local_path != new_local_path:
                            old_full = os.path.join(self._v2_wpm.writing_root_path, old_local_path)
                            new_full = os.path.join(self._v2_wpm.writing_root_path, new_local_path)
                            os.makedirs(os.path.dirname(new_full), exist_ok=True)
                            if os.path.exists(new_full):
                                raise RuntimeError("PATH_CONFLICT: 원격 이름을 적용할 위치에 파일이 이미 있습니다.")
                            if os.path.exists(old_full):
                                os.rename(old_full, new_full)
                        self._v2_store.move_local_path(
                            self._v2_context["local_key"], old_local_path, new_local_path
                        )
                    self._v2_store.rebase_clean_merge(
                        operation_id, remote["revision"], remote.get("content", ""), merge.content,
                        remote_path=new_local_path if new_local_path != old_local_path else None,
                    )
                    if self._v2_wpm:
                        self._v2_wpm.write_text_file(new_local_path, merge.content)
                    return {
                        "kind": "auto_merged",
                        "operation": operation,
                        "remote": remote,
                        "merged_content": merge.content,
                        "old_local_path": old_local_path,
                        "new_local_path": new_local_path,
                    }
                self._v2_store.mark_conflict(
                    operation_id,
                    remote["revision"],
                    remote.get("relative_path", operation["relative_path"]),
                    remote.get("content", ""),
                    merge.content,
                    latest_local_content,
                )
                return {
                    "kind": "conflict",
                    "operation": operation,
                    "remote": remote,
                    "base_content": operation["base_content"],
                    "local_content": latest_local_content,
                    "merged_content": merge.content,
                    "conflict_count": merge.conflict_count,
                    "error": "REVISION_CONFLICT",
                }

            message = code or str(error)
            self._v2_store.mark_retry(operation_id, message)
            return {"kind": "retry", "error": message, "operation": operation}

    def _launch_v2_operation(self, operation):
        # A manual retry or another successful operation may start before a
        # scheduled lease retry fires. Cancel that reservation so only one
        # retry chain can exist at a time.
        self._cancel_scheduled_v2_retry(reset_backoff=False)
        self._v2_store.mark_attempt(operation["operation_id"])
        worker = V2QueueWorker(self, operation["operation_id"])
        self._v2_worker = worker
        self._v2_workers.append(worker)
        self._active_server_syncs += 1
        self._publish_sync_state()

        def handle_finished(success, error_message, payload):
            self._active_server_syncs = max(0, self._active_server_syncs - 1)
            self._v2_worker = None
            kind = (payload or {}).get("kind", "retry")
            original = (payload or {}).get("operation") or operation
            callback = self._v2_callbacks.pop(operation["operation_id"], None)
            conflict_callback = self._v2_conflict_callbacks.pop(operation["operation_id"], None)

            if kind == "committed":
                result = payload["result"]
                self._v2_store.mark_success(operation["operation_id"], result)
                if original.get("is_deleted"):
                    if self._v2_wpm:
                        self._v2_wpm.update_trash_metadata(
                            original.get("local_path"),
                            result.get("committed_at"),
                            original.get("document_id"),
                        )
                self._last_sync_error = ""
                self._last_failure_offline = False
                self._record_sync_success()
                if callback:
                    callback(True, "", original["local_path"], result["revision"])
            elif kind == "auto_merged":
                self.autoMergeApplied.emit(payload)
                if conflict_callback:
                    conflict_callback(payload)
            elif kind == "conflict":
                self.conflictDetected.emit(payload)
                if conflict_callback:
                    conflict_callback(payload)
                if callback:
                    callback(False, "REVISION_CONFLICT", original["local_path"], None)
            elif kind == "project_disabled":
                self._last_sync_error = payload.get("error", "")
                if callback:
                    callback(
                        False,
                        self._last_sync_error,
                        original["local_path"],
                        None,
                    )
            else:
                self._last_sync_error = error_message or payload.get("error", "")
                self._last_failure_offline = self._is_connectivity_error(self._last_sync_error)
                self._v2_store.mark_retry(operation["operation_id"], self._last_sync_error)
                if callback:
                    callback(False, self._last_sync_error, original["local_path"], None)

            self._finalize_v2_operation_lease(kind, original)
            self._publish_sync_state()
            operation_id = original.get("operation_id") or operation["operation_id"]
            if kind == "retry" and "LEASE_CONFLICT" in self._last_sync_error:
                lease_attempt = self._next_lease_retry_attempt(operation_id)
            else:
                self._reset_lease_retry_backoff(operation_id)
                lease_attempt = 1
            if kind == "retry" and self._is_connectivity_error(
                self._last_sync_error
            ):
                network_attempt = self._v2_network_retry_attempts.get(
                    operation_id, 0
                ) + 1
                self._v2_network_retry_attempts[operation_id] = network_attempt
            else:
                self._v2_network_retry_attempts.pop(operation_id, None)
                network_attempt = 1
            follow_up_delay = self._v2_follow_up_delay_ms(
                kind,
                self._last_sync_error,
                lease_attempt,
                network_attempt,
            )
            if follow_up_delay is not None:
                self._schedule_v2_retry(follow_up_delay)

        # resultReady can arrive just before QThread.run() returns. Keep the worker
        # alive until QThread's native finished signal confirms the thread stopped.
        worker.resultReady.connect(handle_finished)

        def cleanup_worker():
            if worker in self._v2_workers:
                self._v2_workers.remove(worker)
            worker.deleteLater()

        worker.finished.connect(cleanup_worker)
        self._start_worker(worker)
        return worker

    def check_and_acquire_lock(self, project_name, relative_path, session_id, client=None):
        """
        Check if the file is locked by another session.
        If not, acquire the lock for the current session.
        Returns: (success(bool), message(str))
        """
        if self.is_v2_enabled:
            server_state = self._current_project_server_state()
            if server_state in {"trashed", "purged"}:
                return (
                    True,
                    "서버 동기화가 중지된 작품입니다. 변경 내용은 로컬에만 저장됩니다.",
                )
            if not is_live_document_path(relative_path):
                return False, "휴지통 문서는 읽기 전용입니다. 복원한 뒤 편집해주세요."
            if not self.can_save_path(relative_path):
                return False, "이미 삭제된 문서입니다. 새 문서를 만들어 이름을 지정해주세요."
            document = self._v2_store.ensure_document(
                self._v2_context["local_key"], relative_path
            )
            if is_forced_offline():
                return True, "테스트 오프라인 상태로 편집합니다. 저장 내용은 재시도 큐에 보관됩니다."
            if document["revision"] == 0:
                return True, "새 로컬 문서입니다. 첫 저장 때 서버에 등록됩니다."
            supabase = client or self.supabase
            if not supabase:
                return True, "오프라인 상태로 편집합니다. 저장 내용은 재시도 큐에 보관됩니다."
            if getattr(supabase, "_antigravity_authenticated", None) is False:
                return (
                    False,
                    "클라우드 동기화 계정에 로그인이 되어있지 않습니다.\n"
                    "설정탭 / 클라우드 계정 로그인을 확인해주세요.",
                )
            try:
                self._acquire_v2_lease(document["document_id"], supabase)
                return True, "Lock acquired."
            except Exception as error:
                code = self._stable_error_code(error)
                if code == "LEASE_CONFLICT":
                    return False, "다른 기기에서 이미 편집 중인 문서입니다."
                if code == "SERVER_RPC_PERMISSION_DENIED":
                    return (
                        False,
                        "서버 동기화 권한 설정이 완료되지 않았습니다. "
                        "Supabase V2 RPC 권한을 적용한 뒤 문서를 다시 열어주세요.",
                    )
                if self._is_connectivity_error(str(error)):
                    return True, "오프라인 상태로 편집합니다. 저장 내용은 재시도 큐에 보관됩니다."
                return False, code or str(error)

        supabase = client or self.supabase
        if not supabase:
            return True, "Mock mode: Lock acquired."
            
        for attempt in range(2):
            try:
                # Query the editor_locks table
                resp = supabase.table("editor_locks").select("*").eq("project_name", project_name).eq("relative_path", relative_path).execute()
                
                if resp.data:
                    lock_info = resp.data[0]
                    locked_by = lock_info.get("locked_by")
                    locked_at_str = lock_info.get("locked_at")
                    
                    if locked_by and locked_by != session_id:
                        import datetime as dt
                        is_dead = False
                        if locked_at_str:
                            try:
                                locked_at = dt.datetime.fromisoformat(locked_at_str.replace("Z", "+00:00"))
                                now = dt.datetime.now(dt.timezone.utc)
                                if (now - locked_at).total_seconds() > 60:
                                    is_dead = True
                            except Exception as e:
                                print(f"Error parsing lock locked_at: {e}")
                        
                        if not is_dead:
                            return False, "다른 기기에서 이미 편집 중인 파일입니다."
                        else:
                            print(f"Dead lock 감지됨 ({relative_path}). 강제로 락을 뺏어옵니다.")
                
                # Acquire lock
                import datetime as dt
                supabase.table("editor_locks").upsert({
                    "project_name": project_name,
                    "relative_path": relative_path,
                    "locked_by": session_id,
                    "locked_at": dt.datetime.now(dt.timezone.utc).isoformat()
                }).execute()
                
                if attempt == 1:
                    print("✅ 서버 통신선 자동 재연결 및 복구 성공!")
                
                return True, "Lock acquired."
                
            except Exception as e:
                if attempt == 0:
                    # 유휴 커넥션(Keep-Alive) 만료로 인한 연결 끊김일 수 있으므로 클라이언트 재초기화 후 재시도
                    print(f"⚠️ 서버 유휴 만료 감지됨 (에러: {e}). 즉시 통신선 재연결을 시도합니다...")
                    self.init_supabase()
                else:
                    # 두 번째에도 실패하면 조용히 오프라인 모드로 넘김 (콘솔 도배 방지)
                    print(f"❌ 오프라인 모드 전환 (서버 통신 완전 실패): {e}")
                    return True, "오프라인 상태로 편집을 허용합니다."

    def heartbeat_lock(self, project_name, relative_path, session_id, client=None):
        if self.is_v2_enabled:
            if is_forced_offline():
                return
            document = self._v2_store.get_document(self._v2_context["local_key"], relative_path)
            if not document or document["revision"] == 0:
                return
            token = self._v2_leases.get(document["document_id"])
            supabase = client or self.supabase
            if not token or not supabase:
                return
            try:
                self._call_with_session(
                    lambda: supabase.rpc("renew_edit_lease", {
                        "p_document_id": document["document_id"],
                        "p_device_id": self._v2_device_id,
                        "p_lease_token": token,
                        "p_ttl_seconds": 90,
                    }).execute(),
                    supabase,
                )
            except Exception as error:
                print(f"Failed to renew v2 edit lease: {error}")
            return

        supabase = client or self.supabase
        if not supabase:
            return
        try:
            # Trigger updates updated_at automatically, but we explicitly update locked_at
            import datetime as dt
            supabase.table("editor_locks").upsert({
                "project_name": project_name,
                "relative_path": relative_path,
                "locked_by": session_id,
                "locked_at": dt.datetime.now(dt.timezone.utc).isoformat()
            }).execute()
        except Exception as e:
            print(f"Failed to heartbeat lock: {e}")

    def release_lock(self, project_name, relative_path, session_id, client=None):
        if self.is_v2_enabled:
            document = self._v2_store.get_document(self._v2_context["local_key"], relative_path)
            if not document:
                return True
            return self._release_v2_lease(document["document_id"], client=client)

        supabase = client or self.supabase
        if not supabase:
            return True
            
        try:
            supabase.table("editor_locks").delete().eq("project_name", project_name).eq("relative_path", relative_path).eq("locked_by", session_id).execute()
            return True
        except Exception as e:
            print(f"Failed to release lock: {e}")
            return False

    def get_file_updated_at(self, project_name, relative_path, client=None):
        if self.is_v2_enabled:
            if not is_live_document_path(relative_path):
                return 0
            document = self._v2_store.get_document(self._v2_context["local_key"], relative_path)
            return document["revision"] if document else 0

        supabase = client or self.supabase
        if not supabase:
            return None
        try:
            resp = supabase.table("writing_contents").select("updated_at").eq("project_name", project_name).eq("relative_path", relative_path).execute()
            if resp.data:
                return resp.data[0].get("updated_at")
        except Exception as e:
            print(f"Failed to fetch updated_at for {relative_path}: {e}")
        return None

    def upload_content_async(self, wpm, project_name, relative_path, content, callback=None, local_updated_at=None, force_overwrite=False, conflict_callback=None):
        if self.is_v2_enabled:
            if not is_live_document_path(relative_path):
                if callback:
                    callback(
                        True,
                        "휴지통 문서는 클라우드 저장 대상에서 제외됩니다.",
                        relative_path,
                        None,
                    )
                return None
            if not self.can_save_path(relative_path):
                if callback:
                    callback(
                        True,
                        "삭제된 문서의 늦은 저장을 무시했습니다.",
                        relative_path,
                        None,
                    )
                return None
            if (
                not force_overwrite
                and self.would_erase_nonempty_document(relative_path, content)
            ):
                error = self.report_empty_content_guard(relative_path)
                if callback:
                    callback(False, error, relative_path, None)
                return None
            if wpm and relative_path and not wpm.write_text_file(relative_path, content):
                if callback:
                    callback(False, "로컬 파일 저장에 실패했습니다.", relative_path, None)
                return None
            document = self._v2_store.get_document(
                self._v2_context["local_key"], relative_path
            )
            if (
                document
                and int(document.get("revision") or 0) > 0
                and not document.get("is_deleted")
                and document.get("server_path") == relative_path
                and document.get("base_content") == content
                and not self._v2_store.has_active_operations(document["document_id"])
            ):
                if callback:
                    callback(True, "", relative_path, document["revision"])
                self._publish_sync_state()
                return None
            operation = self._v2_store.enqueue(
                self._v2_context, relative_path, content, relative_path=relative_path
            )
            if callback:
                self._v2_callbacks[operation["operation_id"]] = callback
            if conflict_callback:
                self._v2_conflict_callbacks[operation["operation_id"]] = conflict_callback
            self._publish_sync_state()
            self.retry_pending_syncs()
            return self._v2_worker

        key = ("content", project_name, relative_path)
        payload = {
            "kind": "content",
            "wpm": wpm,
            "project_name": project_name,
            "relative_path": relative_path,
            "content": content,
            "callback": callback,
            "local_updated_at": local_updated_at,
            "force_overwrite": force_overwrite,
            "conflict_callback": conflict_callback,
        }
        return self._launch_content_upload(payload, key, is_retry=False)

    def _launch_content_upload(self, payload, key, is_retry=False):
        worker = SaveWorker(
            self.supabase,
            None if is_retry else payload["wpm"],
            payload["project_name"],
            payload["relative_path"],
            payload["content"],
            payload["local_updated_at"],
            payload["force_overwrite"],
        )
        self._workers.append(worker)

        def cleanup_worker():
            if worker in self._workers:
                self._workers.remove(worker)

        def handle_finished(success, error_msg, rel_path, new_updated_at):
            server_success, effective_error = self._complete_server_attempt(
                key, payload, success, error_msg, worker, is_retry
            )
            callback = payload.get("callback")
            if callback:
                callback(server_success, effective_error, rel_path, new_updated_at)
            if server_success:
                from PyQt6.QtCore import QTimer
                QTimer.singleShot(0, self.retry_pending_syncs)

        conflict_callback = payload.get("conflict_callback")
        if conflict_callback:
            worker.conflict_detected.connect(conflict_callback)

        self._active_server_syncs += 1
        self._publish_sync_state()
        worker.resultReady.connect(handle_finished)
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)

        return worker

    def upload_all_content_async(self, wpm, project_name, callback=None):
        if self.is_v2_enabled:
            queued = 0
            root = getattr(wpm, "writing_root_path", None)
            if root and os.path.isdir(root):
                for current_root, dirs, files in os.walk(root):
                    relative_root = os.path.relpath(current_root, root).replace("\\", "/")
                    if relative_root != "." and not is_live_document_path(relative_root):
                        dirs[:] = []
                        continue
                    dirs[:] = [
                        name for name in dirs
                        if is_live_document_path(
                            name if relative_root == "." else f"{relative_root}/{name}"
                        )
                    ]
                    for filename in files:
                        if not filename.endswith(".txt"):
                            continue
                        full_path = os.path.join(current_root, filename)
                        relative_path = os.path.relpath(full_path, root).replace("\\", "/")
                        try:
                            with open(full_path, "r", encoding="utf-8") as file:
                                content = file.read()
                            self._v2_store.enqueue(
                                self._v2_context, relative_path, content, relative_path
                            )
                            queued += 1
                        except OSError as error:
                            print(f"v2 bulk queue error ({relative_path}): {error}")
            self._publish_sync_state()
            self.retry_pending_syncs()
            if callback:
                callback(True, "" if queued else "저장할 문서가 없습니다.")
            return self._v2_worker

        key = ("bulk", project_name)
        payload = {
            "kind": "bulk",
            "wpm": wpm,
            "writing_root_path": getattr(wpm, "writing_root_path", None),
            "project_name": project_name,
            "callback": callback,
        }
        return self._launch_bulk_upload(payload, key, is_retry=False)

    def _launch_bulk_upload(self, payload, key, is_retry=False):
        bulk_source = SimpleNamespace(writing_root_path=payload["writing_root_path"])
        worker = BulkSaveWorker(self.supabase, bulk_source, payload["project_name"])
        self._bulk_workers.append(worker)

        def cleanup_worker():
            if worker in self._bulk_workers:
                self._bulk_workers.remove(worker)

        def handle_finished(success, error_msg):
            server_success, effective_error = self._complete_server_attempt(
                key, payload, success, error_msg, worker, is_retry
            )
            callback = payload.get("callback")
            if callback:
                callback(server_success, effective_error)
            if server_success:
                from PyQt6.QtCore import QTimer
                QTimer.singleShot(0, self.retry_pending_syncs)

        self._active_server_syncs += 1
        self._publish_sync_state()
        worker.resultReady.connect(handle_finished)
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)

        return worker

    def upload_history_async(self, wpm, project_name, relative_path, content, callback=None):
        if self.is_v2_enabled:
            return self.upload_autosave_async(wpm, relative_path, content, callback)

        key = ("history", project_name, relative_path)
        payload = {
            "kind": "history",
            "wpm": wpm,
            "project_name": project_name,
            "relative_path": relative_path,
            "content": content,
            "callback": callback,
        }
        return self._launch_history_upload(payload, key, is_retry=False)

    def _launch_history_upload(self, payload, key, is_retry=False):
        worker = BackupWorker(
            self.supabase,
            None if is_retry else payload["wpm"],
            payload["project_name"],
            payload["relative_path"],
            payload["content"],
        )
        self._history_workers.append(worker)

        def cleanup_worker():
            if worker in self._history_workers:
                self._history_workers.remove(worker)

        def handle_finished(success, error_msg):
            if is_retry:
                server_success, effective_error = self._complete_server_attempt(
                    key, payload, success, error_msg, worker, is_retry=True
                )
            else:
                self._active_backups = max(0, self._active_backups - 1)
                server_success = bool(success and getattr(worker, "supabase", None) is not None)
                effective_error = error_msg or ("" if server_success else "서버 연결 없음")
                if server_success:
                    self._retry_queue.pop(key, None)
                    self._last_sync_error = ""
                    self._last_failure_offline = False
                else:
                    self._queue_retry(
                        key,
                        payload,
                        effective_error,
                        offline=getattr(worker, "supabase", None) is None or self._is_connectivity_error(effective_error),
                    )
                self._publish_sync_state()

            callback = payload.get("callback")
            if callback:
                callback(server_success, effective_error)
            if server_success:
                from PyQt6.QtCore import QTimer
                QTimer.singleShot(0, self.retry_pending_syncs)

        if is_retry:
            self._active_server_syncs += 1
        else:
            self._active_backups += 1
        self._publish_sync_state()
        worker.resultReady.connect(handle_finished)
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)

        return worker

    def upload_autosave_async(self, wpm, relative_path, content, callback=None):
        if self._shutting_down:
            return None
        worker_key = (id(wpm), str(relative_path or ""))
        existing = self._autosave_workers_by_path.get(worker_key)
        if existing is not None:
            pending = self._autosave_followups.get(worker_key)
            callbacks = list(pending[3]) if pending else []
            if callback:
                callbacks.append(callback)
            self._autosave_followups[worker_key] = (
                wpm, relative_path, content, callbacks
            )
            return existing

        worker = AutoSaveWorker(wpm, relative_path, content)
        self._autosave_workers.append(worker)
        self._autosave_workers_by_path[worker_key] = worker
        
        def cleanup_worker():
            if worker in self._autosave_workers:
                self._autosave_workers.remove(worker)
            if self._autosave_workers_by_path.get(worker_key) is worker:
                self._autosave_workers_by_path.pop(worker_key, None)
            followup = self._autosave_followups.pop(worker_key, None)
            if followup and not self._shutting_down:
                next_wpm, next_path, next_content, callbacks = followup

                def notify_callbacks(success, error_msg):
                    for pending_callback in callbacks:
                        pending_callback(success, error_msg)

                QTimer.singleShot(
                    0,
                    lambda: self.upload_autosave_async(
                        next_wpm,
                        next_path,
                        next_content,
                        notify_callbacks if callbacks else None,
                    ),
                )
                
        def handle_finished(success, error_msg):
            self._active_backups = max(0, self._active_backups - 1)
            if success:
                self._publish_sync_state()
            else:
                self._set_sync_state("failed", f"자동백업 실패: {error_msg}")
            if callback:
                callback(success, error_msg)

        self._active_backups += 1
        self._publish_sync_state()
        worker.resultReady.connect(handle_finished)
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)
        
        return worker

    def rename_item_async(self, project_name, old_rel_path, new_rel_path, callback=None):
        if self.is_v2_enabled:
            try:
                self.record_path_change(old_rel_path, new_rel_path)
                if callback:
                    callback(True, "")
            except Exception as error:
                if callback:
                    callback(False, str(error))
            return self._v2_worker

        worker = RenameWorker(self.supabase, project_name, old_rel_path, new_rel_path)
        self._rename_workers.append(worker)

        def cleanup_worker():
            if worker in self._rename_workers:
                self._rename_workers.remove(worker)

        if callback:
            worker.resultReady.connect(callback)
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)
        return worker

    def record_path_change(self, old_rel_path, new_rel_path):
        if not self.is_v2_enabled:
            return []
        if not is_live_document_path(old_rel_path) or not is_live_document_path(new_rel_path):
            return []
        moved = self._v2_store.move_local_path(
            self._v2_context["local_key"], old_rel_path, new_rel_path
        )
        root = self._v2_wpm.writing_root_path
        new_full_path = os.path.join(root, new_rel_path)
        if os.path.isfile(new_full_path) and new_full_path.endswith(".txt") and not moved:
            self._v2_store.ensure_document(self._v2_context["local_key"], new_rel_path)
            document = self._v2_store.get_document(self._v2_context["local_key"], new_rel_path)
            moved = [{**document, "local_path": new_rel_path}]
        elif os.path.isdir(new_full_path):
            for current_root, dirs, files in os.walk(new_full_path):
                relative_root = os.path.relpath(current_root, root).replace("\\", "/")
                if not is_live_document_path(relative_root):
                    dirs[:] = []
                    continue
                dirs[:] = [
                    name for name in dirs
                    if is_live_document_path(f"{relative_root}/{name}")
                ]
                for filename in files:
                    if filename.endswith(".txt"):
                        local_path = os.path.relpath(
                            os.path.join(current_root, filename), root
                        ).replace("\\", "/")
                        if not self._v2_store.get_document(self._v2_context["local_key"], local_path):
                            document = self._v2_store.ensure_document(
                                self._v2_context["local_key"], local_path
                            )
                            moved.append({**document, "local_path": local_path})

        for document in moved:
            local_path = document["local_path"]
            content = self._v2_wpm.read_text_file(local_path)
            if content is not None:
                self._v2_store.enqueue(
                    self._v2_context, local_path, content, relative_path=local_path
                )
        self._publish_sync_state()
        self.retry_pending_syncs()
        return moved

    def record_tombstone(self, old_rel_path, trash_rel_path):
        if not self.is_v2_enabled:
            return []
        # A previously deleted UUID may still reserve the same local trash path
        # even when its physical copy was removed. Relocate the new copy before
        # updating SQLite so repeated delete/restore cycles cannot violate the
        # UNIQUE(local_key, local_path) constraint.
        for _ in range(100):
            conflicts = self._v2_store.move_destination_conflicts(
                self._v2_context["local_key"], old_rel_path, trash_rel_path
            )
            if not conflicts:
                break
            trash_rel_path = self._v2_wpm.relocate_trash_item(trash_rel_path)
        else:
            raise RuntimeError("휴지통 문서 경로를 안전하게 확보하지 못했습니다.")
        moved = self._v2_store.move_local_path(
            self._v2_context["local_key"], old_rel_path, trash_rel_path
        )
        if moved:
            self._v2_wpm.update_trash_metadata(
                trash_rel_path,
                document_id=min(
                    str(document.get("document_id") or "") for document in moved
                ),
            )
        for document in moved:
            # A just-created file can be deleted before its create RPC finishes.
            # Keep a dependent tombstone behind that create instead of dropping
            # the deletion and allowing another device to resurrect the file.
            if (
                document["revision"] == 0
                and not self._v2_store.has_active_operations(document["document_id"])
            ):
                continue
            content = self._v2_wpm.read_text_file(document["local_path"])
            if content is not None:
                self._v2_store.enqueue(
                    self._v2_context,
                    document["local_path"],
                    content,
                    relative_path=document["server_path"],
                    is_deleted=True,
                )
        self._publish_sync_state()
        self.retry_pending_syncs()
        return moved

    def record_restore(self, trash_rel_path, restored_rel_path):
        if not self.is_v2_enabled:
            return []
        moved = self._v2_store.move_local_path(
            self._v2_context["local_key"], trash_rel_path, restored_rel_path
        )
        for document in moved:
            content = self._v2_wpm.read_text_file(document["local_path"])
            if content is not None:
                self._v2_store.enqueue(
                    self._v2_context,
                    document["local_path"],
                    content,
                    relative_path=document["local_path"],
                    is_deleted=False,
                )
        self._publish_sync_state()
        self.retry_pending_syncs()
        return moved

    def run_retention_async(self, wpm, callback=None):
        if self._retention_worker is not None:
            try:
                if self._retention_worker.isRunning():
                    return self._retention_worker
            except RuntimeError:
                self._retention_worker = None

        worker = RetentionWorker(wpm)
        self._retention_workers.append(worker)
        self._retention_worker = worker
        
        def cleanup_worker():
            if worker in self._retention_workers:
                self._retention_workers.remove(worker)
            if self._retention_worker is worker:
                self._retention_worker = None
                
        if callback:
            worker.resultReady.connect(callback)
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        self._start_worker(worker)
        
        return worker

    def wait_all_workers(self):
        lists = [
            getattr(self, '_workers', []),
            getattr(self, '_bulk_workers', []),
            getattr(self, '_history_workers', []),
            getattr(self, '_autosave_workers', []),
            getattr(self, '_retention_workers', []),
            getattr(self, '_rename_workers', []),
            getattr(self, '_lock_workers', []),
            getattr(self, '_v2_workers', []),
            getattr(self, '_server_action_workers', []),
            list(getattr(self, 'active_workers', set())),
        ]
        for worker_list in lists:
            for worker in list(worker_list):
                try:
                    if worker.isRunning():
                        worker.wait()
                except RuntimeError:
                    pass

    def shutdown(self):
        """Stop retries, drain bounded background work, and close HTTP pools."""
        self._shutting_down = True
        self._v2_retry_timer.stop()
        self._v2_retry_context = None
        self._autosave_followups.clear()
        self.wait_all_workers()
        self._diagnostics.flush()
        if self.supabase is not None:
            self._close_supabase_client(self.supabase)

class RetentionWorker(QThread):
    resultReady = pyqtSignal(bool, str)
    
    def __init__(self, wpm):
        super().__init__()
        self.wpm = wpm

    def run(self):
        try:
            import os, re
            from datetime import datetime, timedelta
            
            if not self.wpm or not self.wpm.current_project:
                self.resultReady.emit(False, "No project")
                return
                
            backup_dir = os.path.join(self.wpm.workspace_dir, self.wpm.current_project, "집필모드", "백업", "자동저장")
            if not os.path.exists(backup_dir):
                self.resultReady.emit(True, "No backup dir")
                return
                
            now = datetime.now()
            cutoff_1h = now - timedelta(hours=1)
            cutoff_24h = now - timedelta(hours=24)
            
            deleted_count = 0
            
            for doc_dir in os.listdir(backup_dir):
                doc_path = os.path.join(backup_dir, doc_dir)
                if not os.path.isdir(doc_path): continue
                
                files = []
                pattern = re.compile(r'.*?_(\d{8}_\d{4})\.txt$')
                for f in os.listdir(doc_path):
                    if not f.endswith('.txt'): continue
                    m = pattern.match(f)
                    if m:
                        try:
                            dt = datetime.strptime(m.group(1), '%Y%m%d_%H%M')
                            files.append((f, dt, os.path.join(doc_path, f)))
                        except:
                            pass
                            
                keep_files = set()
                group_1h_24h = {}
                group_over_24h = {}
                
                for f, dt, path in files:
                    if dt > cutoff_1h:
                        keep_files.add(f)
                    elif dt > cutoff_24h:
                        key = dt.strftime('%Y%m%d_%H')
                        if key not in group_1h_24h or dt > group_1h_24h[key][1]:
                            group_1h_24h[key] = (f, dt)
                    else:
                        key = dt.strftime('%Y%m%d')
                        if key not in group_over_24h or dt > group_over_24h[key][1]:
                            group_over_24h[key] = (f, dt)
                            
                for f, dt in group_1h_24h.values():
                    keep_files.add(f)
                for f, dt in group_over_24h.values():
                    keep_files.add(f)
                    
                for f, dt, path in files:
                    if f not in keep_files:
                        try:
                            os.remove(path)
                            deleted_count += 1
                        except:
                            pass
                            
            print(f"[RetentionWorker] Deleted {deleted_count} old auto-save files.")
            self.resultReady.emit(True, str(deleted_count))
        except Exception as e:
            print(f"[RetentionWorker] Error: {e}")
            self.resultReady.emit(False, str(e))
