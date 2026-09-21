import os
import re
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QSplitter, QTreeWidget, QTreeWidgetItem, QTextEdit, QLabel,
    QComboBox, QToolButton, QFrame, QMenu, QMessageBox,
    QLineEdit, QDialog, QListWidget, QListWidgetItem,
    QToolBar, QSizePolicy, QTextBrowser, QTabWidget, QFileDialog
)
from PyQt6.QtGui import QAction, QShortcut, QKeySequence, QPixmap, QPainter, QIcon, QFont
from PyQt6.QtCore import Qt, pyqtSignal, QTimer, QThread, QSize
from ui_components import SmartTextEdit
from datetime import datetime

from project_manager_writing import WritingProjectManager
from sync_manager import SyncManager, is_live_document_path
from three_way_merge import build_conflict_report
from writing_backup import HistoryViewerDialog
from writing_search import GlobalSearchDialog, LocalSearchDialog
from writing_extraction import PartialExtractionDialog, WritingExtractionMixin
from writing_tree import WritingTreeMixin

class PrefixLineEdit(QLineEdit):
    def __init__(self, prefix, parent=None):
        super().__init__(parent)
        self.prefix = prefix
        self.textChanged.connect(self.check_prefix)

    def check_prefix(self, text):
        if not text.startswith(self.prefix):
            # 복원
            self.blockSignals(True)
            # 만약 prefix보다 짧아졌다면 prefix로 초기화
            if len(text) < len(self.prefix):
                self.setText(self.prefix)
            else:
                # 사용자가 prefix 중간을 지웠다면 다시 채워넣음
                rest = text.replace(self.prefix.strip(), "")
                self.setText(self.prefix + rest.lstrip())
            self.setCursorPosition(len(self.prefix))
            self.blockSignals(False)

    def focusInEvent(self, event):
        super().focusInEvent(event)
        # 포커스를 받을 때 전체 선택(파란 박스)을 해제하고 커서를 맨 끝으로 이동
        self.deselect()
        self.setCursorPosition(len(self.text()))

from PyQt6.QtWidgets import QTreeWidget
class BinderTreeWidget(QTreeWidget):
    itemMoved = pyqtSignal(QTreeWidgetItem, str, str) # item, old_rel_path, new_parent_rel_path
    orderChanged = pyqtSignal()
    _BOTTOM_SPACER_ROLE = Qt.ItemDataRole.UserRole + 99
    _BOTTOM_SPACER_HEIGHT = 220
    _TRASH_ROOT_PATH = "메인/휴지통"

    def __init__(self, parent=None):
        super().__init__(parent)
        from PyQt6.QtWidgets import QAbstractItemView
        self.setDragEnabled(True)
        self.setAcceptDrops(True)
        self.setDropIndicatorShown(True)
        self.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove)
        self.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)

    def add_bottom_spacer(self):
        """Keep a scrollable, clickable blank area below the binder contents."""
        spacer = QTreeWidgetItem([""])
        spacer.setData(0, self._BOTTOM_SPACER_ROLE, True)
        spacer.setFlags(Qt.ItemFlag.NoItemFlags)
        spacer.setSizeHint(0, QSize(0, self._BOTTOM_SPACER_HEIGHT))
        spacer.setFirstColumnSpanned(True)
        self.addTopLevelItem(spacer)

    def is_bottom_spacer(self, item):
        return bool(item and item.data(0, self._BOTTOM_SPACER_ROLE))

    def is_trash_root(self, item):
        return bool(
            item
            and item.parent() is None
            and item.data(0, Qt.ItemDataRole.UserRole) == self._TRASH_ROOT_PATH
        )

    def _trash_root_index(self):
        for index in range(self.topLevelItemCount()):
            if self.is_trash_root(self.topLevelItem(index)):
                return index
        return -1

    def ensure_trash_at_bottom(self):
        """Keep the trash as the final real root, immediately above the spacer."""
        trash_index = self._trash_root_index()
        if trash_index < 0:
            return False

        content_count = self.topLevelItemCount()
        if (
            content_count
            and self.is_bottom_spacer(self.topLevelItem(content_count - 1))
        ):
            content_count -= 1
        desired_index = content_count - 1
        if trash_index == desired_index:
            return False

        trash_item = self.takeTopLevelItem(trash_index)
        insert_index = self.topLevelItemCount()
        if (
            insert_index
            and self.is_bottom_spacer(self.topLevelItem(insert_index - 1))
        ):
            insert_index -= 1
        self.insertTopLevelItem(insert_index, trash_item)
        return True

    def insert_root_item(self, item):
        """Insert user-created roots before the fixed trash and bottom spacer."""
        index = self.topLevelItemCount()
        if index and self.is_bottom_spacer(self.topLevelItem(index - 1)):
            index -= 1
        trash_index = self._trash_root_index()
        if 0 <= trash_index < index:
            index = trash_index
        self.insertTopLevelItem(index, item)

    def dropEvent(self, event):
        source_item = self.currentItem()
        if not source_item:
            event.ignore()
            return
            
        # '📚 원고' 폴더 및 그 하위 항목들은 어떠한 형태의 드래그 앤 드롭(순서 변경 포함)도 전면 차단
        source_top = source_item
        while source_top.parent():
            source_top = source_top.parent()
        if source_top.text(0) == "📚 원고":
            event.ignore()
            return
        if self.is_trash_root(source_item):
            event.ignore()
            return
            
        target_item = self.itemAt(event.position().toPoint())
        if not target_item or self.is_bottom_spacer(target_item):
            event.ignore()
            return
            
        from PyQt6.QtWidgets import QAbstractItemView
        drop_indicator = self.dropIndicatorPosition()

        # A document is a leaf. Qt otherwise allows an OnItem drop and makes the
        # document look and behave like a folder even though the disk is flat.
        if (
            drop_indicator == QAbstractItemView.DropIndicatorPosition.OnItem
            and target_item.data(0, Qt.ItemDataRole.UserRole + 1) is False
        ):
            event.ignore()
            return
        
        # 1. 루트 노드를 드래그 하는 경우
        if source_item.parent() is None:
            # 루트 노드는 무조건 다른 루트 노드들의 사이(위/아래)로만 드롭 가능
            if target_item.parent() is not None or drop_indicator == QAbstractItemView.DropIndicatorPosition.OnItem:
                event.ignore()
                return
            # '📚 원고' 폴더 위로(최상단으로) 다른 폴더를 드롭하는 것 차단 (원고는 항상 1빠따 유지)
            if target_item.text(0) == "📚 원고" and drop_indicator == QAbstractItemView.DropIndicatorPosition.AboveItem:
                event.ignore()
                return
            # Other roots may be placed above trash, never below it.
            if (
                self.is_trash_root(target_item)
                and drop_indicator == QAbstractItemView.DropIndicatorPosition.BelowItem
            ):
                event.ignore()
                return
        else:
            # 2. 일반 항목(루트 하위)을 드래그 하는 경우
            # 타겟이 루트 노드인데 그 "위"나 "아래"에 드롭하려는 경우 (루트 밖으로 벗어나는 것 방지)
            if target_item.parent() is None and drop_indicator != QAbstractItemView.DropIndicatorPosition.OnItem:
                event.ignore()
                return
            
        # '📚 원고' 외부에서 '📚 원고' 내부로 들어가는 것을 차단
        target_top = target_item
        while target_top.parent():
            target_top = target_top.parent()
            
        if target_top.text(0) == "📚 원고":
            event.ignore()
            return
            
        old_rel_path = source_item.data(0, Qt.ItemDataRole.UserRole)
        old_parent_rel_path = source_item.parent().data(0, Qt.ItemDataRole.UserRole) if source_item.parent() else ""
        
        super().dropEvent(event)
        self.ensure_trash_at_bottom()
        
        # QTreeWidget의 dropEvent는 아이템을 복제/삭제할 수 있으므로, 새로 선택된 아이템을 추적합니다.
        dropped_items = self.selectedItems()
        if not dropped_items:
            self.orderChanged.emit()
            return
            
        new_item = dropped_items[0]
        new_parent = new_item.parent()
        if new_parent is None:
            # 루트 노드끼리 순서가 바뀐 경우
            self.orderChanged.emit()
            return
            
        new_parent_rel_path = new_parent.data(0, Qt.ItemDataRole.UserRole)
        
        if old_parent_rel_path != new_parent_rel_path:
            self.itemMoved.emit(new_item, old_rel_path, new_parent_rel_path)
        else:
            self.orderChanged.emit()

from PyQt6.QtWidgets import QStyledItemDelegate
class RenameDelegate(QStyledItemDelegate):
    def __init__(self, tree, parent=None):
        super().__init__(parent)
        self.tree = tree

    def paint(self, painter, option, index):
        # The bottom spacer is only scrollable blank space; it must not react
        # visually when the pointer passes over it.
        if self.tree.is_bottom_spacer(self.tree.itemFromIndex(index)):
            return
        super().paint(painter, option, index)

    def createEditor(self, parent, option, index):
        item = self.tree.itemFromIndex(index)
        if item:
            top_parent = item
            while top_parent.parent():
                top_parent = top_parent.parent()
            if top_parent.text(0) == "📚 원고":
                is_folder = item.data(0, Qt.ItemDataRole.UserRole + 1)
                if not is_folder:
                    old_rel_path = item.data(0, Qt.ItemDataRole.UserRole)
                    if old_rel_path:
                        old_base = os.path.basename(old_rel_path).replace(".txt", "")
                        match = re.match(r'^(\d+화)', old_base)
                        if match:
                            prefix = match.group(1) + " "
                            editor = PrefixLineEdit(prefix, parent)
                            return editor
        return super().createEditor(parent, option, index)

    def setEditorData(self, editor, index):
        if isinstance(editor, PrefixLineEdit):
            item = self.tree.itemFromIndex(index)
            text = item.text(0)
            if not text.startswith(editor.prefix):
                match = re.match(r'^(\d+화)', text)
                if match:
                    text = editor.prefix + text[len(match.group(1)):].lstrip()
            editor.setText(text)
        else:
            super().setEditorData(editor, index)

class WritingModeWidget(WritingTreeMixin, WritingExtractionMixin, QWidget):
    switchModeRequested = pyqtSignal()
    sendToAssistantRequested = pyqtSignal(str)
    _EDITOR_VIEW_STATE_KEY = "writing_editor_view_states_v1"
    _EDITOR_VIEW_STATE_LIMIT = 100
    _SPLIT_MODE_STATE_KEY = "writing_split_mode_enabled"

    def __init__(self, pm):
        super().__init__()
        # pm: 기존 어시스턴트의 ProjectManager
        self.pm = pm
        self._initial_last_active = self.pm.global_config.get("writing_last_active_editor", "left")
        self._initial_split_mode_enabled = self._saved_split_mode(self.pm)
        self.wpm = WritingProjectManager()
        
        # 프로젝트 초기화 (폴더 구조 생성)
        if self.pm.current_project:
            self.wpm.initialize_project(self.pm.current_project)
            print(f"[DEBUG INIT] self.wpm initialized. id = {id(self.wpm)}")
        else:
            print(f"[DEBUG INIT] self.pm.current_project is empty. wpm id = {id(self.wpm)}")
            
        self.sync_manager = SyncManager()
        from sync_manager import load_or_create_device_id
        self.session_id = load_or_create_device_id()

        if self.pm.current_project:
            self.sync_manager.configure_v2(
                self.wpm, self.pm.current_project, self.session_id
            )
        
        self.is_dirty_left = False
        self.is_dirty_right = False
        self.current_loaded_file_left = None
        self.current_loaded_file_right = None
        
        self.loaded_versions = {} # {rel_path: server revision}
        
        from writing_controller import WritingController
        self.controller = WritingController(
            self.wpm, self.sync_manager, self.pm, self.session_id,
            self.get_active_paths, self.get_editor_content,
            self.on_idle_autosave_persisted,
        )
        self.controller.start_timers()
        
        from PyQt6.QtWidgets import QApplication
        app = QApplication.instance()
        if app:
            app.aboutToQuit.connect(self.controller.release_all_locks)
            app.aboutToQuit.connect(self.controller.wait_all_workers)
            app.aboutToQuit.connect(self.sync_manager.shutdown)
        
        self.init_ui()
        self.sync_manager.syncStateChanged.connect(self.update_storage_status)
        self.sync_manager.conflictDetected.connect(self.on_conflict_detected)
        self.sync_manager.autoMergeApplied.connect(self.on_auto_merge_applied)
        self.sync_manager.remoteDocumentsApplied.connect(self.on_remote_documents_applied)
        self.sync_manager.set_remote_protected_paths_provider(
            self.get_remote_sync_protected_paths
        )
        self.sync_manager.set_active_document_paths_provider(self.get_active_paths)
        self.update_storage_status(
            self.sync_manager.current_sync_state,
            "",
            self.sync_manager.pending_retry_count,
        )
        self.load_tree_data()
        QTimer.singleShot(250, self.sync_manager.retry_pending_syncs)
        self.remote_pull_timer = QTimer(self)
        self.remote_pull_timer.setInterval(5000)
        self.remote_pull_timer.timeout.connect(self.request_remote_sync)
        self.remote_pull_timer.start()
        QTimer.singleShot(900, self.request_remote_sync)
        
        self.active_editor = None
        
        QTimer.singleShot(100, self.load_saved_files)
        
    def get_active_paths(self):
        paths = []
        if self.current_loaded_file_left: paths.append(self.current_loaded_file_left)
        if self.right_editor_container.isVisible() and self.current_loaded_file_right:
            paths.append(self.current_loaded_file_right)
        return paths

    def _remember_editor_view_state(self, editor, rel_path=None):
        if editor is getattr(self, "left_editor", None):
            side = "left"
            rel_path = rel_path or getattr(self, "current_loaded_file_left", None)
        elif editor is getattr(self, "right_editor", None):
            side = "right"
            rel_path = rel_path or getattr(self, "current_loaded_file_right", None)
        else:
            return False
        project_name = str(getattr(self.pm, "current_project", "") or "")
        if not project_name or not rel_path:
            return False

        rel_path = str(rel_path).replace("\\", "/")
        all_states = self.pm.global_config.get(self._EDITOR_VIEW_STATE_KEY)
        if not isinstance(all_states, dict):
            all_states = {}
        project_states = all_states.get(project_name)
        if not isinstance(project_states, dict):
            project_states = {}
            all_states[project_name] = project_states
        side_states = project_states.get(side)
        if not isinstance(side_states, dict):
            side_states = {}
            project_states[side] = side_states

        # Reinsert the path so dictionary order acts as a small LRU list.
        side_states.pop(rel_path, None)
        side_states[rel_path] = {
            "cursor": editor.textCursor().position(),
            "vertical_scroll": editor.verticalScrollBar().value(),
            "horizontal_scroll": editor.horizontalScrollBar().value(),
        }
        while len(side_states) > self._EDITOR_VIEW_STATE_LIMIT:
            side_states.pop(next(iter(side_states)))
        self.pm.global_config[self._EDITOR_VIEW_STATE_KEY] = all_states
        return True

    def _saved_editor_view_state(self, editor, rel_path):
        if editor is getattr(self, "left_editor", None):
            side = "left"
        elif editor is getattr(self, "right_editor", None):
            side = "right"
        else:
            return None
        project_name = str(getattr(self.pm, "current_project", "") or "")
        all_states = self.pm.global_config.get(self._EDITOR_VIEW_STATE_KEY, {})
        if not isinstance(all_states, dict):
            return None
        project_states = all_states.get(project_name, {})
        if not isinstance(project_states, dict):
            return None
        side_states = project_states.get(side, {})
        if not isinstance(side_states, dict):
            return None
        state = side_states.get(str(rel_path).replace("\\", "/"))
        return state if isinstance(state, dict) else None

    def _restore_editor_view_state(self, editor, rel_path):
        state = self._saved_editor_view_state(editor, rel_path)
        if not state:
            return False
        try:
            cursor_position = int(state.get("cursor", 0))
            vertical_scroll = int(state.get("vertical_scroll", 0))
            horizontal_scroll = int(state.get("horizontal_scroll", 0))
        except (TypeError, ValueError):
            return False

        from PyQt6.QtGui import QTextCursor

        cursor = QTextCursor(editor.document())
        cursor.setPosition(max(0, min(cursor_position, len(editor.toPlainText()))))
        editor.setTextCursor(cursor)

        def restore_scrollbars():
            if editor is getattr(self, "left_editor", None):
                current_path = getattr(self, "current_loaded_file_left", None)
            else:
                current_path = getattr(self, "current_loaded_file_right", None)
            if current_path != rel_path:
                return
            editor.verticalScrollBar().setValue(vertical_scroll)
            editor.horizontalScrollBar().setValue(horizontal_scroll)

        # QTextDocument layout and scrollbar ranges settle on the next event turn.
        QTimer.singleShot(0, restore_scrollbars)
        return True

    def persist_editor_view_states(self):
        remembered = False
        for editor in (
            getattr(self, "left_editor", None),
            getattr(self, "right_editor", None),
        ):
            if editor is not None:
                remembered = self._remember_editor_view_state(editor) or remembered
        if remembered:
            self.pm.save_global_config()

    def closeEvent(self, event):
        self.persist_editor_view_states()
        super().closeEvent(event)

    @staticmethod
    def _editor_text_for_save(editor):
        """Make an active IME preedit part of the document before reading it."""
        commit_input = getattr(editor, "commit_pending_input_method", None)
        if callable(commit_input):
            commit_input()
        return editor.toPlainText()

    def get_editor_content(self, path):
        if path == self.current_loaded_file_left and getattr(self, 'left_editor', None) and not self.left_editor.isReadOnly():
            return WritingModeWidget._editor_text_for_save(self.left_editor)
        if path == self.current_loaded_file_right and getattr(self, 'right_editor', None) and not self.right_editor.isReadOnly():
            return WritingModeWidget._editor_text_for_save(self.right_editor)

    def get_remote_sync_protected_paths(self):
        protected = set()
        if self.current_loaded_file_left and (
            self.is_dirty_left or self.left_editor.document().isModified()
        ):
            protected.add(self.current_loaded_file_left)
        if self.current_loaded_file_right and (
            self.is_dirty_right or self.right_editor.document().isModified()
        ):
            protected.add(self.current_loaded_file_right)
        return protected

    def request_remote_sync(self):
        if getattr(self, "_tree_item_creation_active", False):
            return
        try:
            from PyQt6.QtWidgets import QAbstractItemView
            if self.binder_tree.state() == QAbstractItemView.State.EditingState:
                return
        except (AttributeError, RuntimeError):
            return
        self.sync_manager.pull_remote_changes_async()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        
        # QToolBar의 위젯들이 아직 생성되지 않았을 수 있으므로 예외 처리
        if not hasattr(self, 'bottom_toolbar'):
            return
            
        width = self.width()
        
        # 단계 A: 폭 > 1300px (충분히 넓을 때 - 간격 넉넉, 폰트 콤보 넓음)
        if width > 1300:
            self.font_combo.setFixedWidth(110)
            self.size_combo.setFixedWidth(110)
            
            self.spacer_search.setFixedWidth(20)
            self.spacer_format.setFixedWidth(20)
            self.spacer_padding.setFixedWidth(20)
            
            self.toggle_btn.setText("AI 어시스턴트로 전환")
            self.btn_toggle_split.setText("좌우분할모드")
            
            self.btn_global_search.setText("전체 검색")
            self.btn_padding.setText("여백 설정")
            self.btn_open_backup.setText("백업 폴더")
            self.btn_open_conflict.setText("충돌 폴더")
            self.btn_send_to_assistant.setText("어시스턴트로")
            
        # 단계 B: 폭 > 1050px (좁아지기 시작 - 폰트 설정부터 축소)
        elif width > 1050:
            self.font_combo.setFixedWidth(90)
            self.size_combo.setFixedWidth(90)
            
            self.spacer_search.setFixedWidth(10)
            self.spacer_format.setFixedWidth(5)
            self.spacer_padding.setFixedWidth(10)
            
            self.toggle_btn.setText("AI 어시스턴트로 전환")
            self.btn_toggle_split.setText("좌우분할모드")
            
            self.btn_global_search.setText("전체 검색")
            self.btn_padding.setText("여백 설정")
            self.btn_open_backup.setText("백업 폴더")
            self.btn_open_conflict.setText("충돌 폴더")
            self.btn_send_to_assistant.setText("어시스턴트로")
            
        # 단계 C/D: 폭 <= 1050px (버튼 텍스트 약어로 축소)
        else:
            self.font_combo.setFixedWidth(80)
            self.size_combo.setFixedWidth(80)
            
            self.spacer_search.setFixedWidth(5)
            self.spacer_format.setFixedWidth(2)
            self.spacer_padding.setFixedWidth(5)
            
            self.toggle_btn.setText("AI 전환")
            self.btn_toggle_split.setText("분할")
            
            self.btn_global_search.setText("검색")
            self.btn_padding.setText("여백")
            self.btn_open_backup.setText("백업")
            self.btn_open_conflict.setText("충돌")
            self.btn_send_to_assistant.setText("전송")
            
            # 툴팁 설정
            self.toggle_btn.setToolTip("AI 어시스턴트로 전환")
            self.btn_toggle_split.setToolTip("좌우분할모드")
            self.btn_global_search.setToolTip("전체 검색")
            self.btn_padding.setToolTip("여백 설정")
            self.btn_open_backup.setToolTip("백업폴더")
            self.btn_open_conflict.setToolTip("충돌폴더")
            self.btn_send_to_assistant.setToolTip("어시스턴트로")

    def init_ui(self):
        from PyQt6.QtCore import QSettings
        self.settings = QSettings("HitomiKkeora", "WebNovelAssistant")
        self.pad_h = self.settings.value("editor_pad_h", 40, type=int)
        self.pad_v = self.settings.value("editor_pad_v", 20, type=int)
        
        font = QFont("Malgun Gothic")
        font.setBold(True)
        self.setFont(font)
        
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(5, 5, 5, 5)
        main_layout.setSpacing(5)
        
        # 단축키 설정
        QShortcut(QKeySequence("Ctrl+F"), self).activated.connect(self.show_local_search)
        QShortcut(QKeySequence("Ctrl+Shift+F"), self).activated.connect(self.show_global_search)
        
        # --- 상단 2줄 반응형 툴바 ---
        self.top_toolbar = QToolBar("상단 툴바", self)
        self.top_toolbar.setMovable(False)
        self.top_toolbar.setStyleSheet("QToolBar { background-color: #2b2d36; border: none; padding: 2px; }")
        
        self.bottom_toolbar = QToolBar("하단 툴바", self)
        self.bottom_toolbar.setMovable(False)
        self.bottom_toolbar.setStyleSheet("QToolBar { background-color: #2b2d36; border: none; padding: 2px; }")
        
        btn_style = """
            QPushButton {
                background-color: #3b82f6;
                color: white;
                font-weight: bold;
                border: none;
                border-radius: 4px;
                padding: 5px 15px;
            }
            QPushButton:hover { background-color: #2563eb; }
        """
        
        self.toggle_btn = QPushButton("AI 어시스턴트로 전환")
        self.toggle_btn.setMinimumHeight(30)
        self.toggle_btn.setStyleSheet(btn_style)
        self.toggle_btn.clicked.connect(self.switchModeRequested.emit)
        
        self.btn_toggle_split = QPushButton("좌우분할모드")
        self.btn_toggle_split.setCheckable(True)
        self.btn_toggle_split.setChecked(self._initial_split_mode_enabled)
        self.btn_toggle_split.setMinimumHeight(30)
        self.btn_toggle_split.setStyleSheet(btn_style)
        self.btn_toggle_split.clicked.connect(self.toggle_split_mode)
        
        self.btn_global_search = QPushButton("전체 검색")
        self.btn_global_search.setMinimumHeight(30)
        self.btn_global_search.setStyleSheet(btn_style)
        self.btn_global_search.clicked.connect(self.show_global_search)
        
        combo_style = """
            QComboBox {
                background-color: transparent; color: white; border: 1px solid #5a5f73; border-radius: 4px; padding: 2px 5px;
            }
            QComboBox::drop-down { border: none; }
            QComboBox QAbstractItemView { background-color: #2b2d36; color: white; selection-background-color: #3b82f6; }
        """
        self.font_combo = QComboBox()
        self.font_combo.setStyleSheet(combo_style)
        self.font_combo.setFixedWidth(110)
        self.font_combo.addItems(["맑은 고딕", "나눔고딕", "바탕", "돋움"])
        self.font_combo.currentTextChanged.connect(self.apply_font)
        
        self.size_combo = QComboBox()
        self.size_combo.setStyleSheet(combo_style)
        self.size_combo.setFixedWidth(110)
        self.size_combo.addItems(["10", "12", "14", "16", "18", "24"])
        self.size_combo.setCurrentText("14")
        self.size_combo.currentTextChanged.connect(self.apply_size)
        self.format_btns = {}
        base_btn_style = "QToolButton { background-color: transparent; border: none; padding: 4px 10px; border-radius: 4px; color: white; }"
        active_btn_style = "QToolButton:checked { background-color: #3b82f6; font-weight: bold; }"
        hover_style = "QToolButton:hover:!checked { background-color: #4a4f5f; }"
        
        for text in ["B", "I", "U", "S"]:
            btn = QToolButton()
            btn.setText(text)
            btn.setCheckable(True)
            style = base_btn_style + active_btn_style + hover_style
            if text == "B": style += " font-weight: 900;"
            elif text == "I": style += " font-style: italic;"
            elif text == "U": style += " text-decoration: underline;"
            elif text == "S": style += " text-decoration: line-through;"
            btn.setStyleSheet(style)
            btn.clicked.connect(lambda checked, t=text: self.apply_format(t, checked))
            self.format_btns[text] = btn
            
        self.btn_padding = QPushButton("여백 설정")
        self.btn_padding.setMinimumHeight(35)
        self.btn_padding.setStyleSheet("background-color: #4a4f5f; color: white; border-radius: 4px; padding: 5px 15px;")
        self.btn_padding.clicked.connect(self.show_padding_dialog)
        
        self.btn_open_backup = QPushButton("백업 폴더")
        self.btn_open_backup.setMinimumHeight(35)
        self.btn_open_backup.setStyleSheet("background-color: #2ea043; color: white; border-radius: 4px; padding: 5px 15px; font-weight: bold;")
        self.btn_open_backup.clicked.connect(self.open_backup_folder)
        
        self.btn_open_conflict = QPushButton("충돌 폴더")
        self.btn_open_conflict.setMinimumHeight(35)
        self.btn_open_conflict.setStyleSheet("background-color: #d73a49; color: white; border-radius: 4px; padding: 5px 15px; font-weight: bold;")
        self.btn_open_conflict.clicked.connect(self.open_conflict_folder)
        
        self.btn_send_to_assistant = QPushButton("어시스턴트로")
        self.btn_send_to_assistant.setMinimumHeight(35)
        self.btn_send_to_assistant.setStyleSheet("""
            QPushButton { background-color: #8b5cf6; color: #ffffff; font-weight: bold; border: none; border-radius: 4px; padding: 5px 15px; }
            QPushButton:hover { background-color: #7c3aed; }
        """)
        self.btn_send_to_assistant.clicked.connect(self.send_to_assistant)

        # -----------------------------------------------------
        # 1. Top Toolbar 조립
        # -----------------------------------------------------
        self.top_toolbar.addWidget(self.toggle_btn)
        
        top_stretch = QWidget()
        top_stretch.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        self.top_toolbar.addWidget(top_stretch)

        self.lbl_storage_status = QPushButton("● 저장됨")
        self.lbl_storage_status.setFixedHeight(24)
        self.lbl_storage_status.setMinimumWidth(76)
        self.lbl_storage_status.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.lbl_storage_status.clicked.connect(self._show_storage_status_details)
        self.top_toolbar.addWidget(self.lbl_storage_status)

        status_spacer = QWidget()
        status_spacer.setFixedWidth(6)
        self.top_toolbar.addWidget(status_spacer)
        
        self.top_toolbar.addWidget(self.btn_toggle_split)
        
        # -----------------------------------------------------
        # 2. Bottom Toolbar 조립
        # -----------------------------------------------------
        self.bottom_toolbar.addWidget(self.btn_global_search)
        
        self.spacer_search = QWidget(); self.spacer_search.setFixedWidth(20)
        self.bottom_toolbar.addWidget(self.spacer_search)
        
        self.bottom_toolbar.addWidget(self.font_combo)
        self.bottom_toolbar.addWidget(self.size_combo)
        
        self.spacer_format = QWidget(); self.spacer_format.setFixedWidth(20)
        self.bottom_toolbar.addWidget(self.spacer_format)
        
        for text in ["B", "I", "U", "S"]:
            self.bottom_toolbar.addWidget(self.format_btns[text])
            
        self.spacer_padding = QWidget(); self.spacer_padding.setFixedWidth(20)
        self.bottom_toolbar.addWidget(self.spacer_padding)
        self.bottom_toolbar.addWidget(self.btn_padding)
        
        bottom_stretch = QWidget()
        bottom_stretch.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        self.bottom_toolbar.addWidget(bottom_stretch)
        
        self.bottom_toolbar.addWidget(self.btn_open_backup)
        spacer_b1 = QWidget(); spacer_b1.setFixedWidth(10)
        self.bottom_toolbar.addWidget(spacer_b1)
        
        self.bottom_toolbar.addWidget(self.btn_open_conflict)
        spacer_b2 = QWidget(); spacer_b2.setFixedWidth(10)
        self.bottom_toolbar.addWidget(spacer_b2)
        
        self.bottom_toolbar.addWidget(self.btn_send_to_assistant)
        
        main_layout.addWidget(self.top_toolbar)
        main_layout.addWidget(self.bottom_toolbar)

        # --- 중앙 스플리터 (좌측 바인더, 우측 에디터 영역) ---
        self.main_splitter = QSplitter(Qt.Orientation.Horizontal)
        self.main_splitter.setChildrenCollapsible(False)
        
        # 1. 좌측 바인더 (BinderTreeWidget)
        self.binder_tree = BinderTreeWidget()
        self.binder_tree.setHeaderHidden(True)
        self.binder_tree.setMinimumWidth(140)
        self.binder_tree.setStyleSheet("font-size: 14px; font-weight: bold;")
        
        # 드래그 앤 드롭 시그널 연결
        self.binder_tree.itemMoved.connect(self.handle_item_moved)
        from PyQt6.QtCore import QTimer
        self.binder_tree.orderChanged.connect(lambda: QTimer.singleShot(0, self.save_tree_order))
        
        # 컨텍스트 메뉴 설정
        self.binder_tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.binder_tree.customContextMenuRequested.connect(self.show_tree_context_menu)
        
        # 이름 변경 시 앞부분 고정 델리게이트
        self.rename_delegate = RenameDelegate(self.binder_tree, self)
        self.binder_tree.setItemDelegate(self.rename_delegate)
        self.rename_delegate.closeEditor.connect(self.on_tree_editor_closed)
        
        # 이름 변경 이벤트 감지
        self.binder_tree.itemChanged.connect(self.on_tree_item_changed)
        
        # 트리 펼침 이벤트 감지 (게으른 로딩)
        self.binder_tree.itemExpanded.connect(self.on_tree_item_expanded)
        
        # 트리 폴더 펼침/접힘 상태 저장
        self.binder_tree.itemExpanded.connect(self.save_tree_state)
        self.binder_tree.itemCollapsed.connect(self.save_tree_state)
        
        # F2 이름 변경 단축키
        self.rename_shortcut = QShortcut(QKeySequence(Qt.Key.Key_F2), self.binder_tree)
        self.rename_shortcut.activated.connect(self.start_rename_item)
        
        # 항목 선택 변경 시 파일 열기 (클릭, 키보드 방향키, 코드 등에 의한 선택 모두 포함)
        self.binder_tree.currentItemChanged.connect(self.on_tree_current_item_changed)
        
        # 2. 우측 에디터 영역 (좌우 2분할)
        self.editor_splitter = QSplitter(Qt.Orientation.Horizontal)
        
        # 왼쪽 메인 에디터 컨테이너
        self.left_editor_container = QWidget()
        left_ed_layout = QVBoxLayout(self.left_editor_container)
        left_ed_layout.setContentsMargins(0, 0, 0, 0)
        left_ed_layout.setSpacing(0)
        
        left_nav_frame = QFrame()
        left_nav_frame.setStyleSheet("QFrame { background-color: #212529; } QToolButton { color: white; border: none; padding: 4px 8px; } QToolButton:hover { background-color: #343a40; }")
        left_nav_layout = QHBoxLayout(left_nav_frame)
        left_nav_layout.setContentsMargins(5, 5, 5, 5)
        
        btn_prev = QToolButton(); btn_prev.setText("<")
        btn_next = QToolButton(); btn_next.setText(">")
        self.btn_save_left = QToolButton(); self.btn_save_left.setText("💾 저장")
        self.btn_save_left.clicked.connect(self.manual_save)
        
        self.lbl_current_doc = QLabel("선택된 파일 없음")
        self.lbl_current_doc.setStyleSheet("font-weight: bold; color: #00e5ff; border: none;")
        
        left_nav_layout.addWidget(btn_prev)
        left_nav_layout.addWidget(btn_next)
        left_nav_layout.addWidget(self.lbl_current_doc)
        left_nav_layout.addStretch()
        left_nav_layout.addWidget(self.btn_save_left)
        
        self.left_editor = SmartTextEdit()
        self.left_editor.setPlaceholderText("바인더에서 문서를 선택해주세요")
        self.left_editor.setReadOnly(True)
        self.left_editor.textChanged.connect(self.on_editor_text_changed)
        self.left_editor.compositionChanged.connect(
            self.on_editor_text_changed
        )
        self.left_editor.selectionChanged.connect(self.update_editor_statistics)
        
        # 포커스 이벤트 가로채기를 위한 이벤트 필터 설치
        self.left_editor.installEventFilter(self)
        
        self.left_wrap_frame = QFrame()
        left_wrap_layout = QVBoxLayout(self.left_wrap_frame)
        left_wrap_layout.setContentsMargins(0, 0, 0, 0)
        left_wrap_layout.setSpacing(0)
        
        left_wrap_layout.addWidget(left_nav_frame)
        left_wrap_layout.addWidget(self.left_editor)
        
        self.lbl_status_left = QLabel("[좌측] 공백 포함 0자 / 제외 0자")
        self.lbl_status_left.setStyleSheet("color: #888; font-size: 14px; padding: 4px 0px;")
        self.lbl_status_left.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        
        left_ed_layout.addWidget(self.left_wrap_frame)
        left_ed_layout.addWidget(self.lbl_status_left)
        
        # 오른쪽 보조 에디터 컨테이너
        self.right_editor_container = QWidget()
        right_ed_layout = QVBoxLayout(self.right_editor_container)
        right_ed_layout.setContentsMargins(0, 0, 0, 0)
        right_ed_layout.setSpacing(0)
        
        right_nav_frame = QFrame()
        right_nav_frame.setStyleSheet("QFrame { background-color: #212529; } QToolButton { color: white; border: none; padding: 4px 8px; } QToolButton:hover { background-color: #343a40; }")
        right_nav_layout = QHBoxLayout(right_nav_frame)
        right_nav_layout.setContentsMargins(5, 5, 5, 5)
        
        btn_r_prev = QToolButton(); btn_r_prev.setText("<")
        btn_r_next = QToolButton(); btn_r_next.setText(">")
        self.btn_save_right = QToolButton(); self.btn_save_right.setText("💾 저장")
        self.btn_save_right.clicked.connect(self.manual_save)
        
        self.lbl_r_doc = QLabel("보조 에디터")
        self.lbl_r_doc.setStyleSheet("font-weight: bold; color: #00e5ff; border: none;")
        
        right_nav_layout.addWidget(btn_r_prev)
        right_nav_layout.addWidget(btn_r_next)
        right_nav_layout.addWidget(self.lbl_r_doc)
        right_nav_layout.addStretch()
        right_nav_layout.addWidget(self.btn_save_right)
        
        self.right_editor = SmartTextEdit()
        self.right_editor.setPlaceholderText("바인더에서 문서를 선택해주세요")
        self.right_editor.setReadOnly(True)
        self.right_editor.textChanged.connect(self.on_editor_text_changed)
        self.right_editor.compositionChanged.connect(
            self.on_editor_text_changed
        )
        self.right_editor.selectionChanged.connect(self.update_editor_statistics)
        self.right_editor.installEventFilter(self)
        
        self.right_wrap_frame = QFrame()
        right_wrap_layout = QVBoxLayout(self.right_wrap_frame)
        right_wrap_layout.setContentsMargins(0, 0, 0, 0)
        right_wrap_layout.setSpacing(0)
        
        right_wrap_layout.addWidget(right_nav_frame)
        right_wrap_layout.addWidget(self.right_editor)
        
        self.lbl_status_right = QLabel("[우측] 공백 포함 0자 / 제외 0자")
        self.lbl_status_right.setStyleSheet("color: #888; font-size: 14px; padding: 4px 0px;")
        self.lbl_status_right.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        
        right_ed_layout.addWidget(self.right_wrap_frame)
        right_ed_layout.addWidget(self.lbl_status_right)
        
        self.editor_splitter.addWidget(self.left_editor_container)
        self.editor_splitter.addWidget(self.right_editor_container)
        self.right_editor_container.setVisible(
            self._initial_split_mode_enabled
        )
        
        # 스플리터 비율 설정
        self.main_splitter.addWidget(self.binder_tree)
        self.main_splitter.addWidget(self.editor_splitter)
        self.main_splitter.setStretchFactor(0, 0)
        self.main_splitter.setStretchFactor(1, 1)
        saved_binder_width = self.pm.global_config.get("writing_binder_width", 220)
        try:
            saved_binder_width = max(140, int(saved_binder_width))
        except (TypeError, ValueError):
            saved_binder_width = 220
        self.main_splitter.setSizes([saved_binder_width, 800])

        # 드래그 중에는 설정 파일을 계속 쓰지 않고, 움직임이 멈춘 뒤 한 번만 저장한다.
        self._binder_width_save_timer = QTimer(self)
        self._binder_width_save_timer.setSingleShot(True)
        self._binder_width_save_timer.setInterval(250)
        self._binder_width_save_timer.timeout.connect(self._save_binder_width)
        self.main_splitter.splitterMoved.connect(
            lambda _position, _index: self._binder_width_save_timer.start()
        )
        self.editor_splitter.setSizes([400, 400])
        self.editor_splitter.splitterMoved.connect(self._snap_editor_splitter_to_center)
        
        main_layout.addWidget(self.main_splitter, stretch=1)

        self.current_loaded_file = None
        
        # 타자기 모드 초기화
        self.update_typewriter_setting()
        
        # 초기 활성 에디터 설정
        self.set_active_editor(self.left_editor)
        
        # 저장 단축키 (Ctrl+S)
        self.save_shortcut = QShortcut(QKeySequence("Ctrl+S"), self)
        self.save_shortcut.activated.connect(self.manual_save)

    def _save_binder_width(self):
        sizes = self.main_splitter.sizes()
        if not sizes:
            return
        width = max(140, sizes[0])
        self.pm.global_config["writing_binder_width"] = width
        self.pm.save_global_config()

    def _snap_editor_splitter_to_center(self, _position, _index):
        """Give the two-pane divider a small, tactile snap point at center."""
        if getattr(self, "_editor_splitter_snapping", False):
            return

        left_width, right_width = self.editor_splitter.sizes()
        if abs(left_width - right_width) > 24:
            return

        total_width = left_width + right_width
        if total_width <= 0:
            return

        self._editor_splitter_snapping = True
        try:
            left_width = total_width // 2
            self.editor_splitter.setSizes([left_width, total_width - left_width])
        finally:
            self._editor_splitter_snapping = False

    def update_storage_status(self, state, detail="", pending_count=0):
        labels = {
            "saved": ("● 로컬 저장 완료", "#86efac", "#163522"),
            "backup": (
                "● 로컬 저장 완료 · 복구본 생성 중",
                "#7dd3fc",
                "#173449",
            ),
            "syncing": ("● 로컬 저장 완료 · 서버 전송 중", "#7dd3fc", "#173449"),
            "offline": ("● 로컬 저장 완료 · 오프라인", "#fdba74", "#422a18"),
            "auth_required": (
                "● 로컬 저장 완료 · 로그인 필요",
                "#fcd34d",
                "#3b3017",
            ),
            "lease": (
                "● 로컬 저장 완료 · 다른 기기 편집 중",
                "#fde68a",
                "#443615",
            ),
            "failed": (
                "● 로컬 저장 완료 · 서버 전송 대기",
                "#fca5a5",
                "#451f24",
            ),
            "empty_guard": (
                "● 전체 삭제 확인 필요",
                "#fcd34d",
                "#3b3017",
            ),
            "conflict": (
                "● 로컬 저장 완료 · 충돌 해결 필요",
                "#fecaca",
                "#5f1d2b",
            ),
            "project_trashed": (
                "● 서버 휴지통 · 동기화 중지",
                "#fdba74",
                "#422a18",
            ),
            "project_purged": (
                "● 서버 영구 삭제 · 로컬 사본",
                "#fca5a5",
                "#451f24",
            ),
        }
        text, color, background = labels.get(state, labels["saved"])
        unsaved_editor_count = WritingModeWidget._unsaved_editor_count(self)
        editor_dirty = unsaved_editor_count > 0
        if editor_dirty and state != "empty_guard":
            dirty_suffix = {
                "offline": " · 오프라인",
                "auth_required": " · 로그인 필요",
                "lease": " · 다른 기기 편집 중",
                "failed": " · 서버 전송 대기",
                "conflict": " · 충돌 확인 필요",
                "project_trashed": " · 서버 휴지통",
                "project_purged": " · 서버 영구 삭제",
            }.get(state, "")
            text = f"● 로컬 저장 대기 {unsaved_editor_count}건" + dirty_suffix
            color, background = "#fcd34d", "#3b3017"
        elif pending_count:
            if state == "syncing":
                text = f"● 로컬 저장 완료 · 서버 전송 중 {pending_count}건"
            elif state == "offline":
                text = (
                    f"● 로컬 저장 완료 · 서버 전송 대기 {pending_count}건"
                    " · 오프라인"
                )
            elif state == "auth_required":
                text = (
                    f"● 로컬 저장 완료 · 서버 전송 대기 {pending_count}건"
                    " · 로그인 필요"
                )
            elif state == "lease":
                text = (
                    f"● 로컬 저장 완료 · 서버 전송 대기 {pending_count}건"
                    " · 다른 기기 편집 중"
                )
            elif state == "failed":
                text = (
                    f"● 로컬 저장 완료 · 서버 전송 대기 {pending_count}건"
                    " · 재시도 필요"
                )
            elif state == "conflict":
                text = f"● 로컬 저장 완료 · 충돌 {pending_count}건"
            else:
                text = f"{text} · {pending_count}건 대기"
        account_email = ""
        try:
            manager = getattr(self, "sync_manager", None)
            if manager:
                account_email = manager.authenticated_email()
        except Exception:
            account_email = ""
        if account_email and state == "saved" and not editor_dirty and not pending_count:
            text = "● 동기화 완료"
        self._storage_pending_count = pending_count
        self._storage_state = state
        self._storage_detail = detail
        self._storage_editor_dirty_count = unsaved_editor_count
        self._storage_account_email = account_email
        self.lbl_storage_status.setText(text)
        self.lbl_storage_status.setStyleSheet(
            f"QPushButton {{ color: {color}; background-color: {background}; border: 1px solid {color}; "
            "border-radius: 4px; padding: 1px 7px; font-size: 11px; font-weight: bold; }}"
            f"QPushButton:hover {{ background-color: {background}; }}"
        )
        guidance = WritingModeWidget._storage_status_guidance(
            state,
            detail,
            pending_count,
            unsaved_editor_count,
            bool(account_email),
        )
        tooltip = (
            f"{guidance['summary']}\n"
            f"다음 할 일: {guidance['action']}\n"
            "클릭하면 원인과 해결 방법을 확인할 수 있습니다."
        )
        if account_email:
            tooltip = f"클라우드 자동 로그인됨: {account_email}\n{tooltip}"
        self.lbl_storage_status.setToolTip(tooltip)

    @staticmethod
    def _storage_status_guidance(
        state, detail="", pending_count=0, dirty_count=0, logged_in=False
    ):
        """Translate internal sync state into plain-language cause and action."""
        pending_count = max(0, int(pending_count or 0))
        dirty_count = max(0, int(dirty_count or 0))
        if state == "empty_guard":
            return {
                "title": "전체 삭제 확인 필요",
                "summary": "빈 내용이 기존 원고를 덮어쓰지 않도록 자동저장을 멈췄습니다.",
                "cause": detail or "문서 전체가 비어 있어 의도적인 삭제인지 확인이 필요합니다.",
                "action": "내용을 확인한 뒤 Ctrl+S로 직접 저장해주세요.",
                "action_code": "manual_save",
                "warning": True,
            }
        if dirty_count:
            return {
                "title": "로컬 저장 대기",
                "summary": f"변경한 문서 {dirty_count}건이 로컬 저장을 기다리고 있습니다.",
                "cause": "입력 중에는 원고가 계속 바뀌므로 잠시 기다렸다가 자동저장합니다.",
                "action": "입력을 잠시 멈추거나 Ctrl+S를 눌러 바로 저장해주세요.",
                "action_code": "manual_save",
                "warning": False,
            }

        pending_text = f" {pending_count}건" if pending_count else ""
        guidance = {
            "saved": {
                "title": "동기화 완료" if logged_in else "로컬 저장 완료",
                "summary": (
                    "원고가 로컬과 클라우드에 모두 반영되었습니다."
                    if logged_in else "원고가 이 컴퓨터에 안전하게 저장되었습니다."
                ),
                "cause": "현재 처리하거나 기다리는 저장 작업이 없습니다.",
                "action": "계속 집필하시면 됩니다.",
                "action_code": "",
                "warning": False,
            },
            "backup": {
                "title": "로컬 저장 완료",
                "summary": "현재 원고는 저장됐고 복구용 사본을 만드는 중입니다.",
                "cause": "예기치 않은 종료에 대비한 자동 복구본을 생성하고 있습니다.",
                "action": "계속 집필하셔도 됩니다.",
                "action_code": "",
                "warning": False,
            },
            "syncing": {
                "title": "서버 전송 중",
                "summary": f"로컬 저장은 완료됐고 서버로{pending_text} 전송 중입니다.",
                "cause": "클라우드에 최신 원고를 반영하고 있습니다.",
                "action": "잠시 기다려주세요. 집필은 계속할 수 있습니다.",
                "action_code": "",
                "warning": False,
            },
            "offline": {
                "title": "오프라인 · 서버 전송 대기",
                "summary": f"원고는 로컬에 저장됐고 서버 전송{pending_text}이 대기 중입니다.",
                "cause": detail or "현재 서버 또는 인터넷에 연결할 수 없습니다.",
                "action": "인터넷 연결을 확인하세요. 연결되면 자동 재시도됩니다.",
                "action_code": "retry" if pending_count else "",
                "warning": True,
            },
            "auth_required": {
                "title": "클라우드 로그인 필요",
                "summary": f"원고는 로컬에 저장됐고 서버 전송{pending_text}이 대기 중입니다.",
                "cause": "클라우드 로그인 세션을 자동으로 갱신하지 못했습니다.",
                "action": "설정 탭에서 클라우드 계정에 다시 로그인해주세요.",
                "action_code": "",
                "warning": True,
            },
            "conflict": {
                "title": "문서 충돌 확인 필요",
                "summary": "로컬 원고는 보존됐지만 다른 기기의 변경과 자동 병합하지 못했습니다.",
                "cause": detail or "같은 문서를 여러 기기에서 서로 다르게 수정했습니다.",
                "action": "충돌 폴더에서 두 내용을 비교하고 사용할 원고를 선택해주세요.",
                "action_code": "open_conflicts",
                "warning": True,
            },
            "failed": {
                "title": "서버 전송 대기 · 재시도 필요",
                "summary": f"원고는 로컬에 저장됐고 서버 전송{pending_text}이 대기 중입니다.",
                "cause": detail or "서버가 변경 내용을 처리하지 못했습니다.",
                "action": "상세 원인을 확인한 뒤 지금 다시 시도할 수 있습니다.",
                "action_code": "retry" if pending_count else "",
                "warning": True,
            },
            "lease": {
                "title": "다른 기기에서 편집 중",
                "summary": f"원고는 로컬에 저장됐고 서버 전송{pending_text}이 대기 중입니다.",
                "cause": "다른 기기가 같은 문서의 편집 권한을 사용하고 있습니다.",
                "action": "다른 기기에서 문서를 닫은 뒤 다시 시도해주세요.",
                "action_code": "retry" if pending_count else "",
                "warning": True,
            },
            "project_trashed": {
                "title": "서버 휴지통 작품",
                "summary": "원고는 로컬에 보존되지만 이 작품의 서버 동기화는 중지됐습니다.",
                "cause": detail or "작품이 서버 휴지통에 있습니다.",
                "action": "서버 작품 관리에서 작품을 복원해야 동기화를 재개할 수 있습니다.",
                "action_code": "",
                "warning": True,
            },
            "project_purged": {
                "title": "서버에서 영구 삭제된 작품",
                "summary": "현재 원고는 이 컴퓨터의 로컬 사본으로 보존됩니다.",
                "cause": detail or "서버 작품이 영구 삭제되어 기존 연결을 사용할 수 없습니다.",
                "action": "로컬 사본을 새 서버 작품으로 등록하려면 별도 가져오기 절차가 필요합니다.",
                "action_code": "",
                "warning": True,
            },
        }
        return guidance.get(state, guidance["saved"])

    def _show_storage_status_details(self):
        guidance = WritingModeWidget._storage_status_guidance(
            getattr(self, "_storage_state", "saved"),
            getattr(self, "_storage_detail", ""),
            getattr(self, "_storage_pending_count", 0),
            getattr(self, "_storage_editor_dirty_count", 0),
            bool(getattr(self, "_storage_account_email", "")),
        )
        box = QMessageBox(self)
        box.setWindowTitle(guidance["title"])
        box.setIcon(
            QMessageBox.Icon.Warning
            if guidance["warning"]
            else QMessageBox.Icon.Information
        )
        box.setText(guidance["summary"])
        box.setInformativeText(
            f"원인\n{guidance['cause']}\n\n다음 할 일\n{guidance['action']}"
        )
        action_button = None
        action_code = guidance["action_code"]
        if action_code == "retry":
            action_button = box.addButton(
                "지금 다시 시도", QMessageBox.ButtonRole.ActionRole
            )
        elif action_code == "open_conflicts":
            action_button = box.addButton(
                "충돌 폴더 열기", QMessageBox.ButtonRole.ActionRole
            )
        elif action_code == "manual_save":
            action_button = box.addButton(
                "지금 저장", QMessageBox.ButtonRole.ActionRole
            )
        box.addButton(QMessageBox.StandardButton.Close)
        box.exec()
        if action_button is not None and box.clickedButton() is action_button:
            if action_code == "retry":
                self._retry_storage_sync()
            elif action_code == "open_conflicts":
                self.open_conflict_folder()
            elif action_code == "manual_save":
                self.manual_save()

    @staticmethod
    def _unsaved_editor_count(target):
        count = 0
        editor_pairs = (
            ("is_dirty_left", "left_editor"),
            ("is_dirty_right", "right_editor"),
        )
        for dirty_name, editor_name in editor_pairs:
            dirty = bool(getattr(target, dirty_name, False))
            editor = getattr(target, editor_name, None)
            if not dirty and editor is not None:
                try:
                    dirty = bool(editor.document().isModified())
                except (AttributeError, RuntimeError):
                    dirty = False
            if dirty:
                count += 1
        return count

    @staticmethod
    def _editor_has_unsaved_changes(target):
        return WritingModeWidget._unsaved_editor_count(target) > 0

    def _refresh_storage_status_for_editor_state(self):
        self.update_storage_status(
            getattr(self, "_storage_state", "saved"),
            getattr(self, "_storage_detail", ""),
            getattr(self, "_storage_pending_count", 0),
        )

    def _retry_storage_sync(self):
        if getattr(self, "_storage_state", "") in {
            "project_trashed", "project_purged"
        }:
            return
        if getattr(self, "_storage_state", "") == "conflict":
            # A conflict can coexist with independent pending documents. Give
            # those durable queue items a chance to run before opening the
            # conflict artifacts. If only conflicts remain, open the folder.
            if not self.sync_manager.retry_pending_syncs(manual=True):
                self.open_conflict_folder()
            return
        if getattr(self, "_storage_state", "") == "empty_guard":
            self.manual_save()
            return
        if getattr(self, "_storage_pending_count", 0):
            # 사용자가 누른 재시도는 예약된 자동 재시도 대기 시간을 건너뛴다.
            # 큐 항목은 삭제하거나 다시 만들지 않고, 기존 최신 작업을 그대로 실행한다.
            self.sync_manager.retry_pending_syncs(manual=True)

    def manual_save(self):
        """수동 저장 처리"""
        saved_left = False
        saved_right = False
        content_left = None
        content_right = None
        force_empty_left = False
        force_empty_right = False

        if (
            self.current_loaded_file_left
            and is_live_document_path(self.current_loaded_file_left)
            and self.sync_manager.can_save_path(self.current_loaded_file_left)
            and (
                self.is_dirty_left
                or self.left_editor.document().isModified()
            )
        ):
            content_left = WritingModeWidget._editor_text_for_save(
                self.left_editor
            )
            force_empty_left = WritingModeWidget._confirm_empty_document_save(
                self, self.current_loaded_file_left, content_left,
                user_initiated=WritingModeWidget._allows_intentional_empty_save(
                    self, self.current_loaded_file_left, content_left
                ),
            )
            if force_empty_left is None:
                return
            if force_empty_left:
                WritingModeWidget._backup_before_empty_save(
                    self, self.current_loaded_file_left
                )
            if self.wpm.write_text_file(
                self.current_loaded_file_left, content_left
            ):
                self.is_dirty_left = False
                self.left_editor.document().setModified(False)
                WritingModeWidget._accept_persisted_snapshot(
                    self, self.current_loaded_file_left, content_left
                )
                saved_left = True
            
        if (
            self.current_loaded_file_right
            and is_live_document_path(self.current_loaded_file_right)
            and self.sync_manager.can_save_path(self.current_loaded_file_right)
            and (
                self.is_dirty_right
                or self.right_editor.document().isModified()
            )
        ):
            content_right = WritingModeWidget._editor_text_for_save(
                self.right_editor
            )
            force_empty_right = WritingModeWidget._confirm_empty_document_save(
                self, self.current_loaded_file_right, content_right,
                user_initiated=WritingModeWidget._allows_intentional_empty_save(
                    self, self.current_loaded_file_right, content_right
                ),
            )
            if force_empty_right is None:
                return
            if force_empty_right:
                WritingModeWidget._backup_before_empty_save(
                    self, self.current_loaded_file_right
                )
            if self.wpm.write_text_file(
                self.current_loaded_file_right, content_right
            ):
                self.is_dirty_right = False
                self.right_editor.document().setModified(False)
                WritingModeWidget._accept_persisted_snapshot(
                    self, self.current_loaded_file_right, content_right
                )
                saved_right = True
            
        # v2는 현재 문서만 UUID/revision 기반 영구 큐에 넣는다.
        queued_paths = set()
        if saved_left and self.current_loaded_file_left:
            queued_paths.add(self.current_loaded_file_left)
            self.sync_manager.upload_content_async(
                self.wpm,
                self.pm.current_project,
                self.current_loaded_file_left,
                content_left,
                callback=self.on_sync_finished,
                force_overwrite=force_empty_left,
            )
        if saved_right and self.current_loaded_file_right and self.current_loaded_file_right not in queued_paths:
            self.sync_manager.upload_content_async(
                self.wpm,
                self.pm.current_project,
                self.current_loaded_file_right,
                content_right,
                callback=self.on_sync_finished,
                force_overwrite=force_empty_right,
            )
            
        if saved_left:
            if "✅" not in self.lbl_current_doc.text():
                self._original_text_l = self.lbl_current_doc.text()
            self.lbl_current_doc.setText("✅ 저장됨")
            self.lbl_current_doc.setStyleSheet("font-weight: bold; color: #00ff00;")
            
            def restore_label_l():
                if hasattr(self, '_original_text_l'):
                    self.lbl_current_doc.setText(self._original_text_l)
                self.lbl_current_doc.setStyleSheet("font-weight: bold; color: #00e5ff;")
                
            from PyQt6.QtCore import QTimer
            QTimer.singleShot(1500, restore_label_l)

        if saved_right and self.right_editor_container.isVisible():
            if "✅" not in self.lbl_r_doc.text():
                self._original_text_r = self.lbl_r_doc.text()
            self.lbl_r_doc.setText("✅ 저장됨")
            self.lbl_r_doc.setStyleSheet("font-weight: bold; color: #00ff00; border: none;")
            
            def restore_label_r():
                if hasattr(self, '_original_text_r'):
                    self.lbl_r_doc.setText(self._original_text_r)
                self.lbl_r_doc.setStyleSheet("font-weight: bold; color: #00e5ff; border: none;")
                
            from PyQt6.QtCore import QTimer
            QTimer.singleShot(1500, restore_label_r)

    def _confirm_empty_document_save(
        self, relative_path, content, user_initiated=False
    ):
        """Authorize a whole-document deletion or confirm an ambiguous one.

        Returns True for a known user deletion or confirmed fallback, False
        when no guard is needed, and None when the fallback was cancelled.
        """
        if self.sync_manager.would_erase_nonempty_document(
            relative_path, content
        ) is not True:
            return False
        if user_initiated:
            return True
        self.sync_manager.report_empty_content_guard(relative_path)
        answer = QMessageBox.warning(
            self,
            "문서 전체 삭제 확인",
            "기존 내용이 있는 문서가 완전히 비어 있습니다.\n\n"
            "이 상태로 저장하면 다른 기기에서도 문서 전체 내용이 "
            "삭제됩니다.\n정말 빈 문서로 저장할까요?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return None
        return True

    @staticmethod
    def _allows_intentional_empty_save(target, relative_path, content):
        controller = getattr(target, "controller", None)
        checker = getattr(controller, "allows_intentional_empty_save", None)
        return bool(
            callable(checker) and checker(relative_path, content)
        )

    @staticmethod
    def _accept_persisted_snapshot(target, relative_path, content):
        controller = getattr(target, "controller", None)
        accept = getattr(controller, "accept_persisted_snapshot", None)
        if callable(accept):
            accept(relative_path, content)

    def _backup_before_empty_save(self, relative_path):
        """Keep the last local text recoverable before an intentional erase."""
        previous_content = self.wpm.read_text_file(relative_path)
        if previous_content:
            self.sync_manager.upload_autosave_async(
                self.wpm, relative_path, previous_content
            )
            
    def eventFilter(self, obj, event):
        from PyQt6.QtCore import QEvent
        if event.type() == QEvent.Type.FocusIn:
            if obj == self.left_editor:
                self.set_active_editor(self.left_editor)
            elif obj == self.right_editor:
                self.set_active_editor(self.right_editor)
        return super().eventFilter(obj, event)

    def set_active_editor(self, editor):
        self.active_editor = editor
        
        # 설정에 활성 탭 저장
        if editor == self.left_editor:
            self.pm.global_config["writing_last_active_editor"] = "left"
        else:
            self.pm.global_config["writing_last_active_editor"] = "right"
            
        from ui_components import save_config
        save_config("writing_last_active_editor", self.pm.global_config["writing_last_active_editor"])
        
        # 테두리는 컨테이너에 적용하여 네비바와 텍스트 에디터만 감싸게 함 (상태창 제외)
        active_container_style = "#LeftWrap, #RightWrap { border: 2px solid #3b82f6; border-radius: 4px; }"
        inactive_container_style = "#LeftWrap, #RightWrap { border: 1px solid #3a3f4c; border-radius: 4px; }"
        
        self.left_wrap_frame.setObjectName("LeftWrap")
        self.right_wrap_frame.setObjectName("RightWrap")
        
        if self.active_editor == self.left_editor:
            self.left_wrap_frame.setStyleSheet(active_container_style)
            self.right_wrap_frame.setStyleSheet(inactive_container_style)
            self.lbl_current_doc.setStyleSheet("font-weight: bold; color: #00e5ff; border: none;")
            self.lbl_r_doc.setStyleSheet("font-weight: bold; color: #666666; border: none;")
        else:
            self.right_wrap_frame.setStyleSheet(active_container_style)
            self.left_wrap_frame.setStyleSheet(inactive_container_style)
            self.lbl_r_doc.setStyleSheet("font-weight: bold; color: #00e5ff; border: none;")
            self.lbl_current_doc.setStyleSheet("font-weight: bold; color: #666666; border: none;")
            
        # 텍스트 에디터는 테두리 없이 텍스트 속성만 적용
        editor_style = f"""
            QTextEdit {{ font-family: 'Malgun Gothic'; font-size: 14pt; font-weight: bold; line-height: 1.5; background-color: white; border: none; border-bottom-left-radius: 2px; border-bottom-right-radius: 2px; padding-right: 6px; }}
            QScrollBar:vertical {{ border: none; background: #ffffff; width: 12px; margin: 0px 0px 0px 0px; }}
            QScrollBar::handle:vertical {{ background: #d4d4d4; min-height: 20px; border-radius: 6px; }}
            QScrollBar::handle:vertical:hover {{ background: #b5b5b5; }}
            QScrollBar::handle:vertical:pressed {{ background: #999999; }}
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ border: none; background: none; height: 0px; }}
            QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: #ffffff; }}
        """
        self.left_editor.setStyleSheet(editor_style)
        self.right_editor.setStyleSheet(editor_style)
        
        # 스크롤바가 우측 끝에 붙도록 스타일시트의 padding 대신 QTextFrameFormat을 통해 텍스트 여백을 설정
        self.apply_editor_margins()

    def apply_editor_margins(self):
        for editor in [self.left_editor, self.right_editor]:
            doc = editor.document()
            was_modified = doc.isModified()
            signals_were_blocked = editor.blockSignals(True)
            try:
                root_frame = doc.rootFrame()
                fmt = root_frame.frameFormat()
                fmt.setLeftMargin(self.pad_h)
                fmt.setRightMargin(self.pad_h)
                fmt.setTopMargin(self.pad_v)
                if editor.typewriter_enabled:
                    fmt.setBottomMargin(editor.viewport().height() / 2)
                else:
                    fmt.setBottomMargin(self.pad_v)
                root_frame.setFrameFormat(fmt)
                doc.setModified(was_modified)
            finally:
                editor.blockSignals(signals_were_blocked)

    def show_padding_dialog(self):
        from PyQt6.QtWidgets import QDialog, QVBoxLayout, QFormLayout, QSpinBox, QDialogButtonBox
        dialog = QDialog(self)
        dialog.setWindowTitle("에디터 여백 설정")
        dialog.setFixedSize(280, 150)
        layout = QVBoxLayout(dialog)
        
        form = QFormLayout()
        
        spin_h = QSpinBox()
        spin_h.setRange(0, 1000)
        spin_h.setValue(self.pad_h)
        spin_h.setSuffix(" px")
        
        spin_v = QSpinBox()
        spin_v.setRange(0, 1000)
        spin_v.setValue(self.pad_v)
        spin_v.setSuffix(" px")
        
        form.addRow("좌우 여백 (px):", spin_h)
        form.addRow("상하 여백 (px):", spin_v)
        layout.addLayout(form)
        
        btn_box = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        btn_box.accepted.connect(dialog.accept)
        btn_box.rejected.connect(dialog.reject)
        layout.addWidget(btn_box)
        
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.pad_h = spin_h.value()
            self.pad_v = spin_v.value()
            self.settings.setValue("editor_pad_h", self.pad_h)
            self.settings.setValue("editor_pad_v", self.pad_v)
            self.set_active_editor(self.active_editor) # 즉시 적용

    def update_typewriter_setting(self):
        tw_enabled = self.pm.global_config.get("tw_writing", False)
        self.left_editor.typewriter_enabled = tw_enabled
        self.right_editor.typewriter_enabled = tw_enabled

    @classmethod
    def _saved_split_mode(cls, project_manager):
        return bool(
            project_manager.global_config.get(cls._SPLIT_MODE_STATE_KEY, True)
        )

    def toggle_split_mode(self, checked):
        checked = bool(checked)
        self.right_editor_container.setVisible(checked)
        if not checked and self.active_editor == self.right_editor:
            self.set_active_editor(self.left_editor)
        self.pm.global_config[self._SPLIT_MODE_STATE_KEY] = checked
        self.pm.save_global_config()

    def _open_file_by_path(self, rel_path):
        full_path = os.path.join(self.wpm.writing_root_path, rel_path)
        if os.path.isfile(full_path) and full_path.endswith(".txt"):
            if not self.active_editor:
                self.set_active_editor(self.left_editor)
                
            editor = self.active_editor
            if self._remember_editor_view_state(editor):
                self.pm.save_global_config()
            
            # 설정값 다시 불러와서 양쪽 에디터에 대입 (매 문서 오픈 시마다 최신 상태 반영)
            self.update_typewriter_setting()
            
            # 기존 내용이 수정된 상태라면 로컬 저장 및 클라우드 동기화 (백그라운드)
            if editor == self.left_editor and getattr(self, 'current_loaded_file_left', None):
                if getattr(self, 'is_dirty_left', False):
                    content_to_save = WritingModeWidget._editor_text_for_save(
                        editor
                    )
                    force_empty = WritingModeWidget._confirm_empty_document_save(
                        self,
                        self.current_loaded_file_left, content_to_save,
                        user_initiated=WritingModeWidget._allows_intentional_empty_save(
                            self, self.current_loaded_file_left, content_to_save
                        ),
                    )
                    if force_empty is None:
                        return
                    if force_empty:
                        WritingModeWidget._backup_before_empty_save(
                            self, self.current_loaded_file_left
                        )
                    if self.sync_manager.can_save_path(self.current_loaded_file_left):
                        if not self.wpm.write_text_file(
                            self.current_loaded_file_left, content_to_save
                        ):
                            return
                        self.sync_manager.upload_content_async(
                            self.wpm, self.pm.current_project, self.current_loaded_file_left, content_to_save,
                            callback=self.on_sync_finished,
                            local_updated_at=self.loaded_versions.get(self.current_loaded_file_left),
                            force_overwrite=force_empty,
                        )
                        WritingModeWidget._accept_persisted_snapshot(
                            self, self.current_loaded_file_left, content_to_save
                        )
                    editor.document().setModified(False)
                    self.is_dirty_left = False
                    self._refresh_storage_status_for_editor_state()
                
                # 이전 파일 락 해제
                self.controller.release_lock(self.current_loaded_file_left)
                
            elif editor == self.right_editor and getattr(self, 'current_loaded_file_right', None):
                if getattr(self, 'is_dirty_right', False):
                    content_to_save = WritingModeWidget._editor_text_for_save(
                        editor
                    )
                    force_empty = WritingModeWidget._confirm_empty_document_save(
                        self,
                        self.current_loaded_file_right, content_to_save,
                        user_initiated=WritingModeWidget._allows_intentional_empty_save(
                            self, self.current_loaded_file_right, content_to_save
                        ),
                    )
                    if force_empty is None:
                        return
                    if force_empty:
                        WritingModeWidget._backup_before_empty_save(
                            self, self.current_loaded_file_right
                        )
                    if self.sync_manager.can_save_path(self.current_loaded_file_right):
                        if not self.wpm.write_text_file(
                            self.current_loaded_file_right, content_to_save
                        ):
                            return
                        self.sync_manager.upload_content_async(
                            self.wpm, self.pm.current_project, self.current_loaded_file_right, content_to_save,
                            callback=self.on_sync_finished,
                            local_updated_at=self.loaded_versions.get(self.current_loaded_file_right),
                            force_overwrite=force_empty,
                        )
                        WritingModeWidget._accept_persisted_snapshot(
                            self, self.current_loaded_file_right, content_to_save
                        )
                    editor.document().setModified(False)
                    self.is_dirty_right = False
                    self._refresh_storage_status_for_editor_state()
                    
                # 이전 파일 락 해제
                self.controller.release_lock(self.current_loaded_file_right)
            
            # 내용 먼저 즉시 읽기 (로컬 I/O)
            editor.blockSignals(True)
            content = self.wpm.read_text_file(rel_path)
            
            if content is None:
                QMessageBox.critical(self, "파일 읽기 오류", "파일을 읽어오는 중 오류가 발생했습니다.\n원본 데이터 보호를 위해 문서를 열지 않습니다.")
                editor.blockSignals(False)
                return
                
            editor.setText(content)
            self.apply_editor_margins()
            editor.document().setModified(False)
            if editor == self.left_editor:
                self.is_dirty_left = False
            elif editor == self.right_editor:
                self.is_dirty_right = False
                
            if not self._restore_editor_view_state(editor, rel_path):
                from PyQt6.QtGui import QTextCursor
                cursor = editor.textCursor()
                cursor.movePosition(QTextCursor.MoveOperation.End)
                editor.setTextCursor(cursor)
            
            editor.blockSignals(False)

            # 휴지통의 파일은 tombstone의 로컬 보관본이다. 새 클라우드
            # 문서로 등록되지 않도록 열람만 허용한다.
            if not is_live_document_path(rel_path):
                editor.setReadOnly(True)
                editor.setPlaceholderText("휴지통 문서는 읽기 전용입니다. 복원한 뒤 편집해주세요.")
                if editor == self.left_editor:
                    self.lbl_current_doc.setText(os.path.basename(rel_path))
                    self.current_loaded_file_left = rel_path
                    self.pm.global_config["writing_last_left_file"] = rel_path
                else:
                    self.lbl_r_doc.setText(os.path.basename(rel_path))
                    self.current_loaded_file_right = rel_path
                    self.pm.global_config["writing_last_right_file"] = rel_path
                self.controller.notify_file_opened(rel_path, content)
                self.pm.save_global_config()
                return
            
            # 파일을 여는 것만으로는 lease를 획득하지 않는다. 첫 실제
            # textChanged에서 WritingController가 비동기로 획득한다.
            # 잠금 대기 중에도 로컬 입력은 편집기에 그대로 보존된다.
            editor.setReadOnly(False)
            editor.setPlaceholderText("텍스트 입력")

            from PyQt6.QtWidgets import QAbstractItemView
            if (
                editor is self.active_editor
                and self.isVisible()
                and self.binder_tree.state() != QAbstractItemView.State.EditingState
            ):
                editor.activate_input_method()
            
            if editor == self.left_editor:
                self.lbl_current_doc.setText(os.path.basename(rel_path))
                self.current_loaded_file_left = rel_path
                self.controller.notify_file_opened(rel_path, content)
                self.pm.global_config["writing_last_left_file"] = rel_path
            else:
                self.lbl_r_doc.setText(os.path.basename(rel_path))
                self.current_loaded_file_right = rel_path
                self.controller.notify_file_opened(rel_path, content)
                self.pm.global_config["writing_last_right_file"] = rel_path
                
            self.pm.save_global_config()
            
    def activate_current_editor_input(self):
        editor = self.active_editor or self.left_editor
        if editor is not None and not editor.isReadOnly():
            editor.activate_input_method()

    def load_saved_files(self):
        left_file = self.pm.global_config.get("writing_last_left_file")
        right_file = self.pm.global_config.get("writing_last_right_file")
        last_active = getattr(self, "_initial_last_active", "left")
        
        if left_file and os.path.exists(os.path.join(self.wpm.writing_root_path, left_file)):
            self.set_active_editor(self.left_editor)
            self._open_file_by_path(left_file)
            
        if right_file and os.path.exists(os.path.join(self.wpm.writing_root_path, right_file)):
            self.set_active_editor(self.right_editor)
            self._open_file_by_path(right_file)
            
        if last_active == "right" and self.btn_toggle_split.isChecked():
            self.set_active_editor(self.right_editor)
        else:
            self.set_active_editor(self.left_editor)
            
        self.update_editor_statistics()
        self._refresh_storage_status_for_editor_state()

    def send_to_assistant(self):
        if not self.active_editor: return
        cursor = self.active_editor.textCursor()
        text = cursor.selectedText().replace('\u2029', '\n')
        if not text:
            text = self.active_editor.toPlainText()
        if text:
            self.sendToAssistantRequested.emit(text)

    def update_tree_icon(self, rel_path, has_content):
        from PyQt6.QtWidgets import QTreeWidgetItemIterator
        iterator = QTreeWidgetItemIterator(self.binder_tree)
        self.binder_tree.blockSignals(True)
        try:
            while iterator.value():
                item = iterator.value()
                if item.data(0, Qt.ItemDataRole.UserRole) == rel_path:
                    if has_content:
                        item.setIcon(0, self._get_emoji_icon("📝"))
                    else:
                        item.setIcon(0, self._get_empty_page_icon())
                    break
                iterator += 1
        finally:
            self.binder_tree.blockSignals(False)

    def on_editor_text_changed(self):
        editor = self.sender() if self.sender() else self.active_editor
        if editor == self.left_editor and getattr(self, 'current_loaded_file_left', None) and not editor.isReadOnly():
            self.is_dirty_left = True
            has_content = len(editor.toPlainText().strip()) > 0
            self.update_tree_icon(self.current_loaded_file_left, has_content)
            self.controller.notify_text_changed(self.current_loaded_file_left)
        elif editor == self.right_editor and getattr(self, 'current_loaded_file_right', None) and not editor.isReadOnly():
            self.is_dirty_right = True
            has_content = len(editor.toPlainText().strip()) > 0
            self.update_tree_icon(self.current_loaded_file_right, has_content)
            self.controller.notify_text_changed(self.current_loaded_file_right)

        refresh_status = getattr(
            self, "_refresh_storage_status_for_editor_state", None
        )
        if callable(refresh_status):
            refresh_status()
        self.update_editor_statistics()

    def on_idle_autosave_persisted(self, path, content, success):
        """Clear dirty state only when the editor still matches the saved snapshot."""
        if not success:
            return
        pairs = (
            (
                "current_loaded_file_left",
                "left_editor",
                "is_dirty_left",
            ),
            (
                "current_loaded_file_right",
                "right_editor",
                "is_dirty_right",
            ),
        )
        for path_attr, editor_attr, dirty_attr in pairs:
            if getattr(self, path_attr, None) != path:
                continue
            editor = getattr(self, editor_attr, None)
            if editor is None or editor.toPlainText() != content:
                continue
            setattr(self, dirty_attr, False)
            editor.document().setModified(False)
        refresh_status = getattr(
            self, "_refresh_storage_status_for_editor_state", None
        )
        if callable(refresh_status):
            refresh_status()

    @staticmethod
    def _format_editor_statistics(side, text, selected_count):
        with_spaces = len(text)
        without_spaces = len(text.replace(" ", "").replace("\n", "").replace("\t", ""))
        status = f"[{side}] 공백 포함 {with_spaces:,}자 / 제외 {without_spaces:,}자"
        if selected_count:
            status += f" · 선택 : {selected_count:,}자"
        return status

    def update_editor_statistics(self):
        text_left = self.left_editor.toPlainText()
        selected_left = len(self.left_editor.textCursor().selectedText())
        self.lbl_status_left.setText(
            self._format_editor_statistics("좌측", text_left, selected_left)
        )

        if self.right_editor_container.isVisible():
            text_right = self.right_editor.toPlainText()
            selected_right = len(self.right_editor.textCursor().selectedText())
            self.lbl_status_right.setText(
                self._format_editor_statistics("우측", text_right, selected_right)
            )

    def apply_font(self, font_name):
        if self.active_editor:
            self.active_editor.setFontFamily(font_name)
            
    def apply_size(self, size_str):
        if self.active_editor:
            self.active_editor.setFontPointSize(float(size_str))
            
    def open_backup_folder(self):
        if not self.pm or not self.pm.current_project: return
        import os
        backup_path = os.path.join(self.pm.workspace_dir, self.pm.current_project, "집필모드", "백업", "자동저장")
        os.makedirs(backup_path, exist_ok=True)
        if os.name == 'nt':
            os.startfile(backup_path)
            
    def open_conflict_folder(self):
        if not self.pm or not self.pm.current_project: return
        import os
        conflict_path = os.path.join(self.pm.workspace_dir, self.pm.current_project, "집필모드", "백업", "충돌")
        os.makedirs(conflict_path, exist_ok=True)
        if os.name == 'nt':
            os.startfile(conflict_path)
            
    def apply_format(self, fmt, checked):
        if not self.active_editor: return
        if fmt == "B":
            from PyQt6.QtGui import QFont
            self.active_editor.setFontWeight(QFont.Weight.Bold if checked else QFont.Weight.Normal)
        elif fmt == "I":
            self.active_editor.setFontItalic(checked)
        elif fmt == "U":
            self.active_editor.setFontUnderline(checked)
        elif fmt == "S":
            # 취소선 처리는 QFont를 복사해서 적용
            font = self.active_editor.currentFont()
            font.setStrikeOut(checked)
            self.active_editor.setCurrentFont(font)
            
    def show_local_search(self):
        if not self.active_editor:
            return
        if not hasattr(self, 'local_search_dialog') or not self.local_search_dialog.isVisible():
            self.local_search_dialog = LocalSearchDialog(self, self.window())
            self.local_search_dialog.show()
        self.local_search_dialog.raise_()
        self.local_search_dialog.activateWindow()
        self.local_search_dialog.input_keyword.setFocus()
        self.local_search_dialog.input_keyword.selectAll()

    def show_global_search(self):
        if not self.wpm.writing_root_path:
            return
        dialog = GlobalSearchDialog(self.wpm.writing_root_path, self.window())
        if dialog.exec():
            selected_path = dialog.get_selected_path()
            keyword = dialog.get_search_keyword()
            if selected_path:
                # 트리를 펼쳐서 찾지 않고 바로 파일 열기
                if not self.active_editor:
                    self.set_active_editor(self.left_editor)
                self._open_file_by_path(selected_path)
                
                # 검색어 블록 지정(하이라이트)
                if keyword and self.active_editor:
                    self.active_editor.moveCursor(self.active_editor.textCursor().MoveOperation.Start)
                    self.active_editor.find(keyword)
                    
                    # 로컬 검색창(팝업) 띄워서 '다음 찾기' 이어갈 수 있게 연동
                    if not hasattr(self, 'local_search_dialog') or not self.local_search_dialog.isVisible():
                        self.local_search_dialog = LocalSearchDialog(self, self.window())
                    self.local_search_dialog.input_keyword.setText(keyword)
                    self.local_search_dialog.show()
                    self.local_search_dialog.raise_()
                    self.local_search_dialog.activateWindow()

    def on_sync_finished(self, success, error_msg, rel_path=None, new_updated_at=None):
        if not success:
            # 팝업 대신 콘솔 출력으로 변경 (작업 방해 방지)
            print(f"클라우드 백그라운드 동기화 실패: {error_msg}")
        elif rel_path and new_updated_at:
            # v2 서버가 확정한 revision을 로컬 화면 캐시에 반영한다.
            self.loaded_versions[rel_path] = new_updated_at
            display_name = os.path.basename(rel_path)
            if getattr(self, "current_loaded_file_left", None) == rel_path:
                self._original_text_l = display_name
                self.lbl_current_doc.setText(display_name)
                self.lbl_current_doc.setStyleSheet(
                    "font-weight: bold; color: #00e5ff; border: none;"
                )
            if getattr(self, "current_loaded_file_right", None) == rel_path:
                self._original_text_r = display_name
                self.lbl_r_doc.setText(display_name)
                self.lbl_r_doc.setStyleSheet(
                    "font-weight: bold; color: #00e5ff; border: none;"
                )

    def on_auto_merge_applied(self, payload):
        operation = payload.get("operation", {})
        old_rel_path = payload.get("old_local_path") or operation.get("local_path")
        rel_path = payload.get("new_local_path") or old_rel_path
        merged_content = payload.get("merged_content", "")
        if not rel_path:
            return
        if old_rel_path != rel_path:
            self.controller.rename_path(old_rel_path, rel_path)
            if self.current_loaded_file_left == old_rel_path:
                self.current_loaded_file_left = rel_path
            if self.current_loaded_file_right == old_rel_path:
                self.current_loaded_file_right = rel_path
            self._schedule_remote_tree_refresh()
        if getattr(self, "current_loaded_file_left", None) == rel_path:
            editor = self.left_editor
            dirty_attr = "is_dirty_left"
        elif getattr(self, "current_loaded_file_right", None) == rel_path:
            editor = self.right_editor
            dirty_attr = "is_dirty_right"
        else:
            return
        editor.blockSignals(True)
        editor.setPlainText(merged_content)
        editor.document().setModified(False)
        editor.blockSignals(False)
        setattr(self, dirty_attr, False)

    def on_remote_documents_applied(self, changes):
        """Refresh clean editors after newer UUID/revision snapshots arrive."""
        tree_changed = False
        for change in changes or []:
            if change.get("kind") == "tree_order":
                tree_changed = True
                continue
            old_path = change.get("old_local_path")
            new_path = change.get("new_local_path") or old_path
            if not new_path:
                continue
            revision = change.get("revision", 0)
            is_deleted = bool(change.get("is_deleted"))

            if old_path and old_path != new_path:
                if is_deleted:
                    self.controller.forget_path(old_path)
                else:
                    self.controller.rename_path(old_path, new_path)
                self.loaded_versions.pop(old_path, None)
            self.loaded_versions[new_path] = revision
            tree_changed = True

            for side in ("left", "right"):
                path_attr = f"current_loaded_file_{side}"
                current_path = getattr(self, path_attr, None)
                if current_path not in {old_path, new_path}:
                    continue
                editor = self.left_editor if side == "left" else self.right_editor
                label = self.lbl_current_doc if side == "left" else self.lbl_r_doc
                dirty_attr = "is_dirty_left" if side == "left" else "is_dirty_right"

                if is_deleted:
                    self.controller.release_lock(current_path)
                    setattr(self, path_attr, None)
                    editor.blockSignals(True)
                    editor.clear()
                    editor.document().setModified(False)
                    editor.blockSignals(False)
                    setattr(self, dirty_attr, False)
                    label.setText("선택된 파일 없음" if side == "left" else "보조 에디터")
                    label.setStyleSheet(
                        "font-weight: bold; color: #00e5ff; border: none;"
                    )
                    continue

                setattr(self, path_attr, new_path)
                remote_content = change.get("content") or ""
                if editor.toPlainText() != remote_content:
                    editor.blockSignals(True)
                    editor.setPlainText(remote_content)
                    editor.document().setModified(False)
                    editor.blockSignals(False)
                else:
                    editor.document().setModified(False)
                setattr(self, dirty_attr, False)
                accept_remote = getattr(
                    self.controller, "accept_remote_snapshot", None
                )
                if callable(accept_remote):
                    accept_remote(new_path, remote_content)
                else:
                    self.controller.notify_file_opened(
                        new_path, remote_content
                    )
                display_name = os.path.basename(new_path)
                label.setText(display_name)
                label.setStyleSheet(
                    "font-weight: bold; color: #00e5ff; border: none;"
                )
                if side == "left":
                    self._original_text_l = display_name
                else:
                    self._original_text_r = display_name

        if tree_changed:
            self._schedule_remote_tree_refresh()
        refresh_status = getattr(
            self, "_refresh_storage_status_for_editor_state", None
        )
        if callable(refresh_status):
            refresh_status()

    def on_conflict_detected(self, payload, *legacy_args):
        """Keep the local manuscript untouched and surface a diff3 conflict artifact."""
        import datetime

        if isinstance(payload, dict):
            operation = payload.get("operation", {})
            rel_path = operation.get("local_path", "문서.txt")
            base_content = payload.get(
                "base_content", operation.get("base_content", "")
            )
            merged_content = payload.get("merged_content", "")
            local_content = payload.get("local_content", operation.get("content", ""))
            server_content = (payload.get("remote") or {}).get("content", "")
        else:
            project_name = payload
            rel_path, local_content, server_content = legacy_args
            base_content = None
            merged_content = (
                "<<<<<<< 내 로컬 편집본\n" + local_content +
                "\n=======\n" + server_content + "\n>>>>>>> 서버 최신본\n"
            )

        now_str = datetime.datetime.now().strftime("%Y-%m-%d %H%M%S")
        base, ext = os.path.splitext(os.path.basename(rel_path))
        ext = ext or ".txt"
        conflict_dir = os.path.join("백업", "충돌")
        os.makedirs(os.path.join(self.wpm.writing_root_path, conflict_dir), exist_ok=True)
        merge_path = os.path.join(
            conflict_dir, f"{base} (3방향 병합 충돌 {now_str}){ext}"
        ).replace("\\", "/")
        local_path = os.path.join(
            conflict_dir, f"{base} (내 로컬 편집본 {now_str}){ext}"
        ).replace("\\", "/")
        server_path = os.path.join(
            conflict_dir, f"{base} (서버 최신본 {now_str}){ext}"
        ).replace("\\", "/")
        comparison_path = os.path.join(
            conflict_dir, f"{base} (차이점 비교 {now_str}).txt"
        ).replace("\\", "/")
        self.wpm.write_text_file(merge_path, merged_content)
        self.wpm.write_text_file(local_path, local_content)
        self.wpm.write_text_file(server_path, server_content)
        if base_content is not None:
            self.wpm.write_text_file(
                comparison_path,
                build_conflict_report(base_content, local_content, server_content),
            )

        target_label = self.lbl_current_doc
        if getattr(self, "current_loaded_file_right", None) == rel_path:
            target_label = self.lbl_r_doc
        target_label.setText(f"{os.path.basename(rel_path)} (충돌 해결 필요)")
        target_label.setStyleSheet("font-weight: bold; color: #ff6b81; border: none;")
