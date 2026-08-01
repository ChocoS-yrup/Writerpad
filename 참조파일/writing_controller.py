from PyQt6.QtCore import QObject, QTimer
from datetime import datetime, timedelta

AUTOSAVE_IDLE_INTERVAL_MS = 1500


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
        self.last_snapshot_contents = {}
        self.locked_paths = set()
        self.locking_paths = set()
        
        # 1.5초 유휴 타이머 (자동저장)
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
        self.schedule_next_history_backup()
        self.heartbeat_timer.start()
        
        # 앱 시작 시 보존 정책 1회 즉시 실행 후 타이머 가동
        self.execute_retention_cleanup()
        self.retention_timer.start()
        
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
                    # 첫 입력 직후 다른 문서로 이동했다면 늦게 얻은 lease를
                    # 열린 문서의 잠금으로 남기지 않는다.
                    self.sync_manager.release_lock(
                        self.pm.current_project,
                        path,
                        self.session_id,
                    )
                    callback(
                        True,
                        "Inactive document lease released.",
                        server_updated_at,
                    )
                    return
                self.locked_paths.add(path)
            callback(success, msg, server_updated_at)
            
        worker.finished.connect(on_finished)
        worker.finished.connect(worker.deleteLater)
        
        if not hasattr(self, '_lock_workers'):
            self._lock_workers = []
        self._lock_workers.append(worker)
        
        def cleanup_worker(*args):
            from PyQt6.QtCore import QTimer
            def _remove():
                if worker in self._lock_workers:
                    self._lock_workers.remove(worker)
            QTimer.singleShot(2000, _remove)
                
        worker.finished.connect(cleanup_worker)
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
        if path in self.locked_paths:
            self.sync_manager.release_lock(self.pm.current_project, path, self.session_id)
            self.locked_paths.discard(path)

    def release_all_locks(self):
        """현재 쥐고 있는 모든 락을 해제합니다. (앱 종료 시 등)"""
        for path in list(self.locked_paths):
            self.release_lock(path)
            
    def wait_all_workers(self):
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
            
    def notify_file_opened(self, path, content):
        """파일이 에디터에 로드되었을 때 UI에서 호출하여 초기 스냅샷을 저장합니다."""
        if path is not None and content is not None:
            self.last_snapshot_contents[path] = content
            
    def notify_text_changed(self, path):
        """에디터 내용이 변경될 때 UI에서 호출하여 유휴 타이머를 재시작합니다."""
        if not path: return
        # 단순 열람은 다른 기기의 편집을 막지 않는다. 실제 첫 입력이 발생한
        # 시점에만 lease를 요청하고, 결과를 기다리는 동안에도 로컬 입력과
        # 자동저장 대기열은 그대로 보존한다.
        if path not in self.locked_paths and path not in self.locking_paths:
            self.acquire_lock_async(
                path,
                lambda success, message, _revision: self._edit_lease_checked(
                    path,
                    success,
                    message,
                ),
            )
        self.pending_autosave_paths.add(path)
        self.idle_timer.start()

    def _edit_lease_checked(self, path, success, message):
        if success:
            return
        # 서버 queue가 같은 operation으로 계속 재시도하며, lease가 풀리기
        # 전에는 commit_document가 서버 본문을 덮어쓰지 못한다.
        print(f"편집 lease 대기 ({path}): {message}")
        
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
                continue
            try:
                # Preserve the existing timestamped recovery copy independently
                # from the current manuscript and cloud revision.
                self.sync_manager.upload_autosave_async(self.wpm, path, content)
                if not self.sync_manager.can_save_path(path):
                    self.pending_autosave_paths.discard(path)
                    continue
                if not self.wpm.write_text_file(path, content):
                    raise OSError("현재 원고 자동저장에 실패했습니다.")
                self.sync_manager.upload_content_async(
                    self.wpm,
                    self.pm.current_project,
                    path,
                    content,
                )
                self.last_snapshot_contents[path] = content
                self.pending_autosave_paths.discard(path)
                if self.autosave_persisted_callback:
                    self.autosave_persisted_callback(path, content, True)
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
        for path in list(self.locked_paths):
            self.sync_manager.heartbeat_lock(self.pm.current_project, path, self.session_id)
