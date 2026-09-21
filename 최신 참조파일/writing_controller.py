from PyQt6.QtCore import QObject, QTimer
from datetime import datetime, timedelta

AUTOSAVE_IDLE_INTERVAL_MS = 800


class WritingController(QObject):
    """
    글쓰기 모드의 비즈니스 로직과 타이머(자동저장, 히스토리 백업, 락 하트비트 등)를 관리하는 컨트롤러.
    UI 종속성을 최소화하기 위해 콜백을 통해 에디터 상태를 조회합니다.
    """
    def __init__(
        self,
        wpm,
        sync_manager,
        project_manager,
        session_id,
        active_paths_provider,
        content_provider,
        autosave_persisted_callback=None,
    ):
        super().__init__()
        self.wpm = wpm
        self.sync_manager = sync_manager
        self.pm = project_manager
        self.session_id = session_id
        
        self.get_active_paths = active_paths_provider
        self.get_editor_content = content_provider
        self.autosave_persisted_callback = autosave_persisted_callback
        
        self.pending_autosave_paths = set()
        # Only QTextEdit/IME user-edit signals add paths here. This lets an
        # intentional select-all deletion win over the stale-empty guard while
        # programmatic loads and layout changes remain protected.
        self.user_edited_paths = set()
        self.last_snapshot_contents = {}
        self.locked_paths = set()
        self.locking_paths = set()
        self._timers_started = False
        
        # 입력이 멈춘 뒤 약 0.8초 후 자동저장한다. 매 입력마다 다시
        # 시작되는 단발 타이머라 연속 입력 중에는 중복 저장하지 않는다.
        self.idle_timer = QTimer(self)
        self.idle_timer.setInterval(AUTOSAVE_IDLE_INTERVAL_MS)
        self.idle_timer.setSingleShot(True)
        self.idle_timer.timeout.connect(self.sync_file)
        
        # 5분 백업 스케줄러 타이머
        self.history_timer = QTimer(self)
        self.history_timer.setSingleShot(True)
        self.history_timer.timeout.connect(self.execute_history_backup)
        
        # 30초 락 하트비트 타이머
        self.heartbeat_timer = QTimer(self)
        self.heartbeat_timer.setInterval(30000)
        self.heartbeat_timer.timeout.connect(self.on_heartbeat_timeout)
        
        # 1시간 주기 보존 정책(Retention) 정리 타이머
        self.retention_timer = QTimer(self)
        self.retention_timer.setInterval(3600000) # 1 hour
        self.retention_timer.timeout.connect(self.execute_retention_cleanup)
        
    def start_timers(self):
        """컨트롤러 시작 시 호출하여 타이머를 가동합니다."""
        if self._timers_started:
            return False
        self._timers_started = True
        self.schedule_next_history_backup()
        self.heartbeat_timer.start()
        
        # 앱 시작 시 보존 정책 1회 즉시 실행 후 타이머 가동
        self.execute_retention_cleanup()
        self.retention_timer.start()
        return True
        
    def execute_retention_cleanup(self):
        """백그라운드에서 오랫동안 쌓인 자동저장 파일을 정리합니다."""
        if self.pm.current_project:
            self.sync_manager.run_retention_async(self.wpm)

    def acquire_lock_async(self, path, callback):
        """특정 경로의 파일에 대해 비동기적으로 락을 획득합니다."""
        if not self.pm.current_project or not path: 
            callback(False, "Invalid path", None)
            return
        if path in self.locked_paths:
            callback(True, "Lock acquired.", None)
            return
        if path in self.locking_paths:
            return
        self.locking_paths.add(path)

        from sync_manager import LockWorker
        worker = LockWorker(self.sync_manager, self.pm.current_project, path, self.session_id)
        
        def on_finished(success, msg, server_updated_at):
            self.locking_paths.discard(path)
            if success:
                active_paths = set(self.get_active_paths() or [])
                if path not in active_paths:
                    # 사용자가 첫 입력 직후 다른 문서로 이동했다면 늦게
                    # 획득한 lease를 열린 문서의 잠금으로 남기지 않는다.
                    self.release_lock(path)
                    callback(
                        True,
                        "Inactive document lease released.",
                        server_updated_at,
                    )
                    return
                self.locked_paths.add(path)
            callback(success, msg, server_updated_at)
            
        worker.resultReady.connect(on_finished)
        
        if not hasattr(self, '_lock_workers'):
            self._lock_workers = []
        self._lock_workers.append(worker)
        
        def cleanup_worker():
            if worker in self._lock_workers:
                self._lock_workers.remove(worker)

        # QThread.finished is emitted only after run() has returned. Cleanup
        # and deletion are therefore safe even when the result arrives while
        # the main event loop is busy processing editor input.
        worker.finished.connect(cleanup_worker)
        worker.finished.connect(worker.deleteLater)
        worker.start()

    def acquire_lock(self, path):
        """특정 경로의 파일에 대해 락을 획득합니다."""
        if not self.pm.current_project or not path: return False, "Invalid path"
        success, msg = self.sync_manager.check_and_acquire_lock(self.pm.current_project, path, self.session_id)
        if success:
            self.locked_paths.add(path)
        return success, msg

    def release_lock(self, path):
        """특정 경로의 파일에 대한 락을 해제합니다."""
        if not self.pm.current_project or not path: return
        # V2 저장 재시도 큐가 컨트롤러의 비동기 검사보다 나중에 lease를
        # 얻었을 수도 있다. V2 release는 lease가 없으면 무해한 no-op이므로
        # 문서를 닫을 때 항상 서버 관리자에도 해제를 요청한다.
        if (
            path in self.locked_paths
            or bool(getattr(self.sync_manager, "is_v2_enabled", False))
        ):
            self.sync_manager.release_lock_async(
                self.pm.current_project, path, self.session_id
            )
            self.locked_paths.discard(path)

    def release_all_locks(self):
        """현재 쥐고 있는 모든 락을 해제합니다. (앱 종료 시 등)"""
        paths = set(self.locked_paths)
        if bool(getattr(self.sync_manager, "is_v2_enabled", False)):
            paths.update(self.get_active_paths() or [])
        for path in list(paths):
            self.release_lock(path)
            
    def wait_all_workers(self):
        self.stop_timers()
        lists = [
            getattr(self, '_lock_workers', [])
        ]
        for worker_list in lists:
            for worker in list(worker_list):
                try:
                    if worker.isRunning():
                        worker.wait()
                except RuntimeError:
                    pass

    def stop_timers(self):
        for timer in (
            self.idle_timer,
            self.history_timer,
            self.heartbeat_timer,
            self.retention_timer,
        ):
            timer.stop()
        self._timers_started = False
            
    def notify_file_opened(self, path, content):
        """파일이 에디터에 로드되었을 때 UI에서 호출하여 초기 스냅샷을 저장합니다."""
        if path is not None and content is not None:
            self.last_snapshot_contents[path] = content
            self._prune_snapshot_cache({path})

    def _prune_snapshot_cache(self, extra_paths=None):
        """Keep full manuscript snapshots only while a document is in use."""
        keep_paths = set(extra_paths or ())
        try:
            keep_paths.update(self.get_active_paths() or ())
        except (AttributeError, RuntimeError):
            pass
        keep_paths.update(self.pending_autosave_paths)
        keep_paths.update(self.user_edited_paths)
        keep_paths.update(self.locked_paths)
        keep_paths.update(self.locking_paths)
        self.last_snapshot_contents = {
            path: content
            for path, content in self.last_snapshot_contents.items()
            if path in keep_paths
        }

    def accept_remote_snapshot(self, path, content):
        """Replace clean editor bookkeeping with an accepted remote snapshot."""
        self.accept_persisted_snapshot(path, content)

    def accept_persisted_snapshot(self, path, content):
        """Mark a local or remote snapshot as durable and no longer pending."""
        if path is None or content is None:
            return
        self.pending_autosave_paths.discard(path)
        self.user_edited_paths.discard(path)
        self.last_snapshot_contents[path] = content
        self._prune_snapshot_cache({path})
        if not self.pending_autosave_paths:
            self.idle_timer.stop()
            
    def notify_text_changed(self, path, user_initiated=True):
        """에디터 내용이 변경될 때 UI에서 호출하여 유휴 타이머를 재시작합니다."""
        if not path: return
        # 단순 열람은 다른 기기의 편집을 막지 않는다. 첫 실제 입력 때만
        # lease를 요청하며, 결과를 기다리는 동안에도 로컬 입력과 자동저장
        # 대기열은 그대로 보존한다.
        if (
            user_initiated
            and path not in self.locked_paths
            and path not in self.locking_paths
        ):
            self.acquire_lock_async(
                path,
                lambda success, message, _revision: self._edit_lease_checked(
                    path,
                    success,
                    message,
                ),
            )
        self.pending_autosave_paths.add(path)
        if user_initiated:
            self.user_edited_paths.add(path)
        self.idle_timer.start()

    @staticmethod
    def _edit_lease_checked(path, success, message):
        if success:
            return
        # 서버 큐가 같은 operation을 재시도하고, lease가 풀리기 전에는
        # commit_document가 서버 본문을 덮어쓰지 못한다.
        print(f"편집 lease 대기 ({path}): {message}")

    def has_user_edit_intent(self, path):
        return bool(path and path in self.user_edited_paths)

    def allows_intentional_empty_save(self, path, content):
        """Trust an empty user edit only after a known non-empty snapshot."""
        return bool(
            content == ""
            and self.has_user_edit_intent(path)
            and self.last_snapshot_contents.get(path)
        )
        
    def rename_path(self, old_path, new_path):
        """파일 이름이 변경되었을 때 내부 관리 중인 경로들을 업데이트합니다."""
        def moved(path):
            if path == old_path:
                return new_path
            if path.startswith(old_path + "/"):
                return new_path + path[len(old_path):]
            return path

        self.locked_paths = {moved(path) for path in self.locked_paths}
        self.locking_paths = {moved(path) for path in self.locking_paths}
        self.pending_autosave_paths = {moved(path) for path in self.pending_autosave_paths}
        self.user_edited_paths = {
            moved(path) for path in self.user_edited_paths
        }
        self.last_snapshot_contents = {
            moved(path): content for path, content in self.last_snapshot_contents.items()
        }

    def forget_path(self, deleted_path):
        """Discard editor bookkeeping for a deleted file or folder."""
        def remains(path):
            return not (
                path == deleted_path or path.startswith(deleted_path + "/")
            )

        self.locked_paths = {path for path in self.locked_paths if remains(path)}
        self.locking_paths = {
            path for path in self.locking_paths if remains(path)
        }
        self.pending_autosave_paths = {
            path for path in self.pending_autosave_paths if remains(path)
        }
        self.user_edited_paths = {
            path for path in self.user_edited_paths if remains(path)
        }
        self.last_snapshot_contents = {
            path: content
            for path, content in self.last_snapshot_contents.items()
            if remains(path)
        }
        
    def sync_file(self):
        """Persist idle editor contents locally, queue Sync V2, and keep a backup."""
        if not self.pm.current_project:
            return

        retry_needed = False
        for path in list(self.pending_autosave_paths):
            content = self.get_editor_content(path)
            if content is None:
                self.pending_autosave_paths.discard(path)
                self.user_edited_paths.discard(path)
                continue
            try:
                intentional_empty = self.allows_intentional_empty_save(
                    path, content
                )
                if (
                    not intentional_empty
                    and self.sync_manager.would_erase_nonempty_document(
                        path, content
                    ) is True
                ):
                    self.sync_manager.report_empty_content_guard(path)
                    if self.autosave_persisted_callback:
                        self.autosave_persisted_callback(
                            path, content, False
                        )
                    continue
                if not self.sync_manager.can_save_path(path):
                    self.pending_autosave_paths.discard(path)
                    self.user_edited_paths.discard(path)
                    continue
                if not self.wpm.write_text_file(path, content):
                    raise OSError("현재 원고 자동저장에 실패했습니다.")

                # A successful current-file write is the durability boundary.
                # Backup creation and cloud queueing are independent follow-up
                # work and must never put already-saved text back into the editor
                # dirty queue.
                previous_content = self.last_snapshot_contents.get(path)
                self.last_snapshot_contents[path] = content
                self.pending_autosave_paths.discard(path)
                self.user_edited_paths.discard(path)
                if self.autosave_persisted_callback:
                    self.autosave_persisted_callback(path, content, True)

                backup_content = content
                if intentional_empty and previous_content:
                    backup_content = previous_content
                try:
                    self.sync_manager.upload_autosave_async(
                        self.wpm, path, backup_content
                    )
                except Exception as backup_error:
                    print(f"자동 백업 시작 실패 ({path}): {backup_error}")

                upload_kwargs = (
                    {"force_overwrite": True} if intentional_empty else {}
                )
                try:
                    self.sync_manager.upload_content_async(
                        self.wpm,
                        self.pm.current_project,
                        path,
                        content,
                        **upload_kwargs,
                    )
                except Exception as queue_error:
                    print(f"서버 전송 대기열 등록 실패 ({path}): {queue_error}")
                    reporter = getattr(
                        self.sync_manager, "report_server_queue_failure", None
                    )
                    if reporter:
                        reporter(path, queue_error)
            except Exception as error:
                print(f"자동저장 실패 ({path}): {error}")
                retry_needed = True
                if self.autosave_persisted_callback:
                    self.autosave_persisted_callback(path, content, False)
        if retry_needed and self.pending_autosave_paths:
            self.idle_timer.start()
            
    def schedule_next_history_backup(self):
        """정각 기준 5분마다 실행되도록 다음 타이머를 계산하여 스케줄링합니다."""
        now = datetime.now()
        minutes_to_add = 5 - (now.minute % 5)
        
        if minutes_to_add == 5 and now.second == 0 and now.microsecond == 0:
            pass

        next_time = now.replace(second=0, microsecond=0)
        next_time += timedelta(minutes=minutes_to_add)
        
        ms_until_next = int((next_time - now).total_seconds() * 1000)
        if ms_until_next <= 0:
            ms_until_next = 300000 # 5분
            
        self.history_timer.setInterval(ms_until_next)
        self.history_timer.start()

    def execute_history_backup(self):
        """5분 주기 백업을 실행합니다."""
        if not self.pm.current_project:
            self.schedule_next_history_backup()
            return
            
        active_paths = self.get_active_paths()
        for path in active_paths:
            content = self.get_editor_content(path)
            if content is not None:
                last_content = self.last_snapshot_contents.get(path)
                if content != last_content:
                    self.sync_manager.upload_history_async(
                        self.wpm, self.pm.current_project, path, content
                    )
                    self.last_snapshot_contents[path] = content
                    
        self.schedule_next_history_backup()
        
    def on_heartbeat_timeout(self):
        """30초 주기로 현재 획득한 모든 락을 연장합니다."""
        if not self.pm.current_project: return
        paths = set(self.locked_paths)
        if bool(getattr(self.sync_manager, "is_v2_enabled", False)):
            # 저장 재시도 큐가 뒤늦게 얻은 V2 lease도 활성 문서라면 갱신한다.
            # lease가 없는 단순 열람 문서는 heartbeat_lock 내부에서 no-op이다.
            paths.update(self.get_active_paths() or [])
        self.sync_manager.heartbeat_locks_async(
            self.pm.current_project, paths, self.session_id
        )
