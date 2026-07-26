import os
import json
import sys
import difflib
import shutil
from datetime import datetime
from PyQt6.QtCore import QMutex, QMutexLocker

class WritingProjectManager:
    _instance = None
    _mutex = QMutex()

    def __new__(cls, *args, **kwargs):
        # Thread-safe Singleton
        with QMutexLocker(cls._mutex):
            if cls._instance is None:
                cls._instance = super(WritingProjectManager, cls).__new__(cls)
                cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        # 싱글톤이 여러 번 __init__ 호출하는 것을 방지
        if self._initialized:
            return
            
        if getattr(sys, 'frozen', False):
            self.root_dir = os.path.dirname(sys.executable)
        else:
            # main.py 가 있는 최상위 경로
            self.root_dir = os.path.abspath(os.path.dirname(__file__))
        from runtime_profile import root_dir
        self.root_dir = root_dir(self.root_dir)
            
        self.workspace_dir = os.path.join(self.root_dir, "작품목록")
        
        self.current_project = None
        self.writing_root_path = None
        self.settings_path = None
        self.project_settings = {}
        
        self._initialized = True

    def initialize_project(self, project_name):
        """
        프로젝트 진입 시, 해당 프로젝트의 '집필모드' 전용 샌드박스 영역을 초기화합니다.
        """
        self.current_project = project_name
        
        # 작품목록/[프로젝트명]/집필모드/ 를 최상위 루트로 설정
        self.writing_root_path = os.path.join(self.workspace_dir, project_name, "집필모드")
        self.settings_path = os.path.join(self.writing_root_path, "설정.json")
        
        self._create_folder_structure()
        self._load_settings()

    def _create_folder_structure(self):
        """
        PRD에 명시된 한글 폴더 구조가 없으면 생성합니다. (기존 어시스턴트 경로는 건드리지 않음)
        """
        if not self.writing_root_path:
            return

        directories = [
            "메인/원고",
            "메인/캐릭터",
            "메인/설정집",
            "메인/메모장",
            "메인/플롯",
            "메인/흐름정리",
            "메인/복선",
            "메인/장소",
            "메인/휴지통",
            "백업/자동저장",
            "백업/전환직전",
            "백업/충돌",
            "백업/복원전"
        ]
        
        for directory in directories:
            target_path = os.path.join(self.writing_root_path, directory)
            os.makedirs(target_path, exist_ok=True)

    def _load_settings(self):
        """설정.json을 로드합니다. 없으면 빈 딕셔너리로 초기화합니다."""
        if not os.path.exists(self.settings_path):
            self.project_settings = {}
            self.save_settings()
            return

        try:
            with open(self.settings_path, "r", encoding="utf-8") as f:
                self.project_settings = json.load(f)
        except Exception as e:
            print(f"집필 모드 설정 로드 실패: {e}")
            self.project_settings = {}

    def save_settings(self):
        """현재 설정을 설정.json에 저장합니다."""
        if not self.settings_path:
            return
            
        try:
            with open(self.settings_path, "w", encoding="utf-8") as f:
                json.dump(self.project_settings, f, ensure_ascii=False, indent=4)
        except Exception as e:
            print(f"집필 모드 설정 저장 실패: {e}")

    def read_text_file(self, relative_path):
        """
        파일을 읽을 때 utf-8을 강제합니다.
        relative_path: 집필모드/ 하위의 상대 경로 (예: "메인/원고/001.txt")
        """
        if not self.writing_root_path:
            return None
            
        target_path = os.path.join(self.writing_root_path, relative_path)
        if not os.path.exists(target_path):
            return ""
            
        locker = QMutexLocker(self._mutex)
        try:
            with open(target_path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception as e:
            print(f"파일 읽기 실패 ({target_path}): {e}")
            return None

    def write_text_file(self, relative_path, content):
        """
        파일을 저장할 때 utf-8을 강제합니다. (원자적 쓰기 + fsync)
        relative_path: 집필모드/ 하위의 상대 경로
        """
        if not self.writing_root_path:
            return False

        target_path = os.path.join(self.writing_root_path, relative_path)

        # 파일이 저장될 폴더가 없을 경우 대비
        os.makedirs(os.path.dirname(target_path), exist_ok=True)

        locker = QMutexLocker(self._mutex)
        temp_path = target_path + ".tmp"
        try:
            with open(temp_path, "w", encoding="utf-8") as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())   # .tmp 내용을 디스크에 확정
            os.replace(temp_path, target_path)   # 같은 볼륨 내 원자적 교체
            return True
        except Exception as e:
            print(f"파일 쓰기 실패 ({target_path}): {e}")
            try:
                if os.path.exists(temp_path):
                    os.remove(temp_path)
            except Exception:
                pass
            return False

    def create_physical_item(self, parent_rel_path, base_name, is_folder):
        """새로운 폴더나 파일을 실제 파일 시스템에 생성하고, 최종 생성된 상대 경로를 반환합니다."""
        if not self.writing_root_path: return None
        full_parent_path = os.path.join(self.writing_root_path, parent_rel_path) if parent_rel_path else self.writing_root_path
        ext = "" if is_folder else ".txt"
        new_name = base_name + ext
        counter = 1
        while os.path.exists(os.path.join(full_parent_path, new_name)):
            new_name = f"{base_name} ({counter}){ext}"
            counter += 1
        full_new_path = os.path.join(full_parent_path, new_name)
        if is_folder:
            os.makedirs(full_new_path, exist_ok=True)
        else:
            with open(full_new_path, "w", encoding="utf-8") as f:
                f.write("")
        return new_name

    def rename_item(self, old_rel_path, new_rel_path):
        """파일 또는 폴더의 이름을 변경합니다."""
        if not self.writing_root_path: return False
        old_full_path = os.path.join(self.writing_root_path, old_rel_path)
        new_full_path = os.path.join(self.writing_root_path, new_rel_path)
        if os.path.exists(new_full_path):
            raise Exception("이미 같은 이름의 항목이 존재합니다.")
        os.rename(old_full_path, new_full_path)
        return True

    def move_to_trash(self, rel_path, deleted_at=None, document_id=None):
        """항목을 휴지통으로 이동하고 원래 위치를 기록합니다."""
        if not self.writing_root_path: return False
        full_path = self._resolve_inside_root(rel_path)
        if not os.path.exists(full_path):
            raise FileNotFoundError("삭제할 항목을 찾을 수 없습니다.")

        base_name = os.path.basename(rel_path)
        trash_dir = os.path.join(self.writing_root_path, "메인", "휴지통")
        os.makedirs(trash_dir, exist_ok=True)
        trash_path = os.path.join(trash_dir, base_name)
        if os.path.exists(trash_path):
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            trash_path = os.path.join(self.writing_root_path, "메인", "휴지통", f"{timestamp}_{base_name}")
            counter = 1
            while os.path.exists(trash_path):
                trash_path = os.path.join(
                    self.writing_root_path, "메인", "휴지통", f"{timestamp}_{counter}_{base_name}"
                )
                counter += 1

        index = self._load_trash_index()
        updated_index = dict(index)
        updated_index[os.path.basename(trash_path)] = {
            "original_path": rel_path.replace("\\", "/"),
            "deleted_at": deleted_at or datetime.now().isoformat(timespec="seconds"),
            "document_id": str(document_id) if document_id else None,
        }
        self._save_trash_index(updated_index)
        try:
            shutil.move(full_path, trash_path)
        except Exception:
            self._save_trash_index(index)
            raise
        return os.path.relpath(trash_path, self.writing_root_path).replace("\\", "/")

    def list_trash_items(self):
        """휴지통 항목과 기록된 원래 위치를 반환합니다."""
        if not self.writing_root_path:
            return []
        trash_dir = os.path.join(self.writing_root_path, "메인", "휴지통")
        index = self._load_trash_index()
        items = []
        if not os.path.isdir(trash_dir):
            return items
        for name in os.listdir(trash_dir):
            info = index.get(name, {})
            items.append({
                "name": name,
                "trash_path": f"메인/휴지통/{name}",
                "original_path": info.get("original_path"),
                "deleted_at": info.get("deleted_at"),
                "document_id": info.get("document_id"),
            })
        return items

    def update_trash_metadata(self, trash_rel_path, deleted_at=None, document_id=None):
        """Persist server-stable deletion metadata for deterministic ordering."""
        if not trash_rel_path:
            return False
        name = os.path.basename(trash_rel_path.replace("\\", "/"))
        index = self._load_trash_index()
        info = dict(index.get(name, {}))
        if deleted_at:
            info["deleted_at"] = deleted_at
        if document_id:
            info["document_id"] = str(document_id)
        if not info:
            return False
        index[name] = info
        self._save_trash_index(index)
        return True

    def relocate_trash_item(self, trash_rel_path):
        """Move a trash entry to a fresh local name while preserving its metadata."""
        source_path = self._resolve_inside_root(trash_rel_path)
        trash_dir = os.path.abspath(
            os.path.join(self.writing_root_path, "메인", "휴지통")
        )
        if (
            os.path.commonpath([source_path, trash_dir]) != trash_dir
            or source_path == trash_dir
        ):
            raise ValueError("휴지통 안의 항목만 이름을 바꿀 수 있습니다.")
        if not os.path.exists(source_path):
            raise FileNotFoundError("이동할 휴지통 항목을 찾을 수 없습니다.")

        source_name = os.path.basename(source_path)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        target_name = f"{timestamp}_{source_name}"
        target_path = os.path.join(trash_dir, target_name)
        counter = 1
        while os.path.exists(target_path):
            target_name = f"{timestamp}_{counter}_{source_name}"
            target_path = os.path.join(trash_dir, target_name)
            counter += 1

        index = self._load_trash_index()
        updated_index = dict(index)
        info = updated_index.pop(source_name, None)
        if info is not None:
            updated_index[target_name] = info
        shutil.move(source_path, target_path)
        try:
            self._save_trash_index(updated_index)
        except Exception:
            shutil.move(target_path, source_path)
            raise
        return os.path.relpath(target_path, self.writing_root_path).replace("\\", "/")

    def materialize_remote_tombstone(
        self, original_rel_path, content, deleted_at=None, document_id=None
    ):
        """Create a preserved trash copy when this device never saw the live file."""
        original_rel_path = original_rel_path.replace("\\", "/")
        base_name = os.path.basename(original_rel_path)
        trash_dir = os.path.join(self.writing_root_path, "메인", "휴지통")
        os.makedirs(trash_dir, exist_ok=True)
        trash_path = os.path.join(trash_dir, base_name)
        if os.path.exists(trash_path):
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            trash_path = os.path.join(trash_dir, f"{timestamp}_{base_name}")
            counter = 1
            while os.path.exists(trash_path):
                trash_path = os.path.join(
                    trash_dir, f"{timestamp}_{counter}_{base_name}"
                )
                counter += 1

        trash_rel_path = os.path.relpath(
            trash_path, self.writing_root_path
        ).replace("\\", "/")
        if not self.write_text_file(trash_rel_path, content or ""):
            raise OSError("휴지통 보관본을 생성하지 못했습니다.")

        index = self._load_trash_index()
        index[os.path.basename(trash_path)] = {
            "original_path": original_rel_path,
            "deleted_at": deleted_at or datetime.now().isoformat(timespec="seconds"),
            "document_id": str(document_id) if document_id else None,
        }
        try:
            self._save_trash_index(index)
        except Exception:
            try:
                os.remove(trash_path)
            except OSError:
                pass
            raise
        return trash_rel_path

    def restore_from_trash(self, trash_rel_path, destination_parent=None):
        """휴지통 항목을 원래 위치 또는 지정 폴더로 복원합니다."""
        if not self.writing_root_path:
            raise RuntimeError("집필 프로젝트가 열려 있지 않습니다.")

        source_path = self._resolve_inside_root(trash_rel_path)
        trash_dir = os.path.abspath(os.path.join(self.writing_root_path, "메인", "휴지통"))
        if os.path.commonpath([source_path, trash_dir]) != trash_dir or source_path == trash_dir:
            raise ValueError("휴지통 안의 항목만 복원할 수 있습니다.")
        if not os.path.exists(source_path):
            raise FileNotFoundError("복원할 항목을 찾을 수 없습니다.")

        name = os.path.basename(source_path)
        index = self._load_trash_index()
        original_path = index.get(name, {}).get("original_path")
        if destination_parent is None:
            if not original_path:
                raise ValueError("원래 위치 기록이 없습니다. '선택 위치로 복원'을 사용해주세요.")
            target_rel_path = original_path
        else:
            original_name = os.path.basename(original_path) if original_path else name
            target_rel_path = os.path.join(destination_parent, original_name).replace("\\", "/")

        target_path = self._resolve_inside_root(target_rel_path)
        if os.path.commonpath([target_path, trash_dir]) == trash_dir:
            raise ValueError("휴지통 내부로는 복원할 수 없습니다.")
        if os.path.exists(target_path):
            raise FileExistsError("복원할 위치에 같은 이름의 항목이 이미 있습니다.")

        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        shutil.move(source_path, target_path)
        index.pop(name, None)
        self._save_trash_index(index)
        return os.path.relpath(target_path, self.writing_root_path).replace("\\", "/")

    def delete_from_trash(self, trash_rel_path):
        """휴지통 항목 하나를 영구 삭제하고 위치 기록도 제거합니다."""
        source_path = self._resolve_inside_root(trash_rel_path)
        trash_dir = os.path.abspath(os.path.join(self.writing_root_path, "메인", "휴지통"))
        if os.path.commonpath([source_path, trash_dir]) != trash_dir or source_path == trash_dir:
            raise ValueError("휴지통 안의 항목만 삭제할 수 있습니다.")
        if os.path.isdir(source_path):
            shutil.rmtree(source_path)
        elif os.path.exists(source_path):
            os.remove(source_path)
        index = self._load_trash_index()
        index.pop(os.path.basename(source_path), None)
        self._save_trash_index(index)
        return True

    def empty_trash(self):
        """휴지통을 비웁니다."""
        if not self.writing_root_path: return False
        trash_dir = os.path.join(self.writing_root_path, "메인", "휴지통")
        if not os.path.exists(trash_dir): return False
        for filename in os.listdir(trash_dir):
            file_path = os.path.join(trash_dir, filename)
            if os.path.isdir(file_path):
                shutil.rmtree(file_path)
            else:
                os.remove(file_path)
        self._save_trash_index({})
        return True

    def list_backup_history(self, rel_path):
        """원고의 자동저장 이력을 최신순으로 반환합니다."""
        if not self.writing_root_path:
            return []
        base_name = os.path.splitext(os.path.basename(rel_path))[0]
        backup_root = os.path.join(self.writing_root_path, "백업", "자동저장")
        candidates = []
        document_dir = os.path.join(backup_root, base_name)
        if os.path.isdir(document_dir):
            candidates.extend(os.path.join(document_dir, name) for name in os.listdir(document_dir))
        if os.path.isdir(backup_root):
            candidates.extend(os.path.join(backup_root, name) for name in os.listdir(backup_root))

        prefix = base_name + "_"
        history = []
        seen = set()
        for path in candidates:
            path = os.path.abspath(path)
            if path in seen or not os.path.isfile(path):
                continue
            seen.add(path)
            filename = os.path.basename(path)
            if not (filename.startswith(prefix) and filename.endswith(".txt")):
                continue
            timestamp_text = filename[len(prefix):-4]
            timestamp = self._parse_backup_timestamp(timestamp_text)
            modified_at = datetime.fromtimestamp(os.path.getmtime(path))
            shown_at = timestamp or modified_at
            history.append({
                "path": path,
                "timestamp": shown_at,
                "display_time": shown_at.strftime("%Y-%m-%d %H:%M:%S"),
                "size": os.path.getsize(path),
            })
        history.sort(key=lambda item: item["timestamp"], reverse=True)
        return history

    def read_backup_file(self, backup_path):
        """백업 영역 안의 텍스트 파일만 읽습니다."""
        safe_path = self._resolve_inside_backup(backup_path)
        with open(safe_path, "r", encoding="utf-8") as file:
            return file.read()

    def compare_with_backup(self, rel_path, backup_path):
        """현재본과 백업본의 통합 diff와 변경 줄 수를 반환합니다."""
        current_content = self.read_text_file(rel_path)
        if current_content is None:
            raise OSError("현재 원고를 읽을 수 없습니다.")
        backup_content = self.read_backup_file(backup_path)
        diff_lines = list(difflib.unified_diff(
            current_content.splitlines(),
            backup_content.splitlines(),
            fromfile="현재본",
            tofile="선택한 백업",
            lineterm="",
        ))
        additions = sum(1 for line in diff_lines if line.startswith("+") and not line.startswith("+++"))
        deletions = sum(1 for line in diff_lines if line.startswith("-") and not line.startswith("---"))
        return {
            "current_content": current_content,
            "backup_content": backup_content,
            "diff": "\n".join(diff_lines) if diff_lines else "변경 사항이 없습니다.",
            "additions": additions,
            "deletions": deletions,
        }

    def restore_backup(self, rel_path, backup_path):
        """현재본을 별도 보관한 뒤 선택한 자동저장본으로 복원합니다."""
        target_path = self._resolve_inside_root(rel_path)
        restored_content = self.read_backup_file(backup_path)
        pre_restore_path = None
        if os.path.isfile(target_path):
            current_content = self.read_text_file(rel_path)
            if current_content is None:
                raise OSError("복원 전 현재 원고를 읽을 수 없습니다.")
            base_name = os.path.splitext(os.path.basename(rel_path))[0]
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            pre_restore_rel = f"백업/복원전/{base_name}/{base_name}_복원전_{stamp}.txt"
            counter = 1
            while os.path.exists(os.path.join(self.writing_root_path, pre_restore_rel)):
                pre_restore_rel = f"백업/복원전/{base_name}/{base_name}_복원전_{stamp}_{counter}.txt"
                counter += 1
            if not self.write_text_file(pre_restore_rel, current_content):
                raise OSError("복원 전 안전 백업을 만들지 못했습니다.")
            pre_restore_path = os.path.normpath(os.path.join(self.writing_root_path, pre_restore_rel))

        if not self.write_text_file(rel_path, restored_content):
            raise OSError("선택한 백업을 현재 원고에 적용하지 못했습니다.")
        return {"content": restored_content, "pre_restore_path": pre_restore_path}

    def _resolve_inside_root(self, relative_path):
        root = os.path.abspath(self.writing_root_path)
        candidate = os.path.abspath(os.path.join(root, relative_path))
        if os.path.commonpath([candidate, root]) != root:
            raise ValueError("집필 프로젝트 바깥의 경로는 사용할 수 없습니다.")
        return candidate

    def _resolve_inside_backup(self, backup_path):
        backup_root = os.path.abspath(os.path.join(self.writing_root_path, "백업"))
        candidate = os.path.abspath(backup_path)
        if os.path.commonpath([candidate, backup_root]) != backup_root:
            raise ValueError("백업 폴더 바깥의 파일은 사용할 수 없습니다.")
        if not os.path.isfile(candidate):
            raise FileNotFoundError("백업 파일을 찾을 수 없습니다.")
        return candidate

    def _trash_index_path(self):
        return os.path.join(self.writing_root_path, "백업", "휴지통_원위치.json")

    def _load_trash_index(self):
        path = self._trash_index_path()
        try:
            with open(path, "r", encoding="utf-8") as file:
                data = json.load(file)
                return data if isinstance(data, dict) else {}
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}

    def _save_trash_index(self, index):
        path = self._trash_index_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temp_path = path + ".tmp"
        with open(temp_path, "w", encoding="utf-8") as file:
            json.dump(index, file, ensure_ascii=False, indent=2)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp_path, path)

    @staticmethod
    def _parse_backup_timestamp(value):
        for format_text in ("%Y%m%d_%H%M%S", "%Y%m%d_%H%M"):
            try:
                return datetime.strptime(value, format_text)
            except ValueError:
                continue
        return None

    def move_item(self, old_rel_path, new_parent_rel_path):
        """항목을 다른 폴더로 이동합니다."""
        if not self.writing_root_path: return None
        basename = os.path.basename(old_rel_path)
        new_rel_path = os.path.join(new_parent_rel_path, basename).replace("\\", "/")
        old_full_path = os.path.join(self.writing_root_path, old_rel_path)
        new_full_path = os.path.join(self.writing_root_path, new_rel_path)
        
        if os.path.exists(new_full_path):
            raise Exception("대상 폴더에 이미 같은 이름의 항목이 존재합니다.")
            
        import shutil
        shutil.move(old_full_path, new_full_path)
        return new_rel_path

    def add_volume(self):
        """새로운 'N권' 폴더를 생성하고 하위에 25개의 챕터를 생성합니다."""
        import re
        if not self.writing_root_path: return None
        manuscript_path = os.path.join(self.writing_root_path, "메인", "원고")
        os.makedirs(manuscript_path, exist_ok=True)
        
        dirs = [d for d in os.listdir(manuscript_path) if os.path.isdir(os.path.join(manuscript_path, d))]
        max_vol = 0
        for d in dirs:
            match = re.match(r'(\d+)권', d)
            if match:
                max_vol = max(max_vol, int(match.group(1)))
                
        new_vol_num = max_vol + 1
        new_vol_name = f"{new_vol_num}권"
        new_vol_path = os.path.join(manuscript_path, new_vol_name)
        os.makedirs(new_vol_path, exist_ok=True)
        
        start_chapter = (new_vol_num - 1) * 25 + 1
        end_chapter = new_vol_num * 25
        
        for i in range(start_chapter, end_chapter + 1):
            chapter_name = f"{i:03d}화.txt"
            chapter_path = os.path.join(new_vol_path, chapter_name)
            with open(chapter_path, "w", encoding="utf-8") as f:
                f.write("")
        
        return new_vol_name
