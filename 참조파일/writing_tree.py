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
from PyQt6.QtCore import Qt, pyqtSignal, QTimer, QThread

from writing_backup import HistoryViewerDialog


class WritingTreeMixin:
    def _schedule_remote_tree_refresh(self):
        """Reload the binder only after every inline editor is safely closed."""
        self._remote_tree_refresh_pending = True
        if getattr(self, "_remote_tree_refresh_scheduled", False):
            return
        self._remote_tree_refresh_scheduled = True
        QTimer.singleShot(0, self._flush_remote_tree_refresh)

    def _flush_remote_tree_refresh(self):
        self._remote_tree_refresh_scheduled = False
        if not getattr(self, "_remote_tree_refresh_pending", False):
            return
        if getattr(self, "_tree_item_creation_active", False):
            return
        try:
            from PyQt6.QtWidgets import QAbstractItemView
            if self.binder_tree.state() == QAbstractItemView.State.EditingState:
                self._remote_tree_refresh_scheduled = True
                QTimer.singleShot(50, self._flush_remote_tree_refresh)
                return
        except (AttributeError, RuntimeError):
            return
        self._remote_tree_refresh_pending = False
        self.load_tree_data()

    def _finish_tree_item_creation(self, item):
        try:
            item.setData(0, Qt.ItemDataRole.UserRole + 4, False)
        except RuntimeError:
            pass
        pending_items = getattr(self, "_pending_tree_creation_items", [])
        self._pending_tree_creation_items = [
            pending for pending in pending_items if pending is not item
        ]
        if getattr(self, "_tree_creation_item", None) is item:
            self._tree_creation_item = None
        self._tree_item_creation_active = bool(self._pending_tree_creation_items)
        if (
            not self._tree_item_creation_active
            and getattr(self, "_remote_tree_refresh_pending", False)
        ):
            self._schedule_remote_tree_refresh()

    def _commit_tree_item_creation(self, item):
        try:
            is_pending = bool(
                item and item.data(0, Qt.ItemDataRole.UserRole + 4)
            )
        except RuntimeError:
            is_pending = False
        if not is_pending:
            return False
        try:
            rel_path = item.data(0, Qt.ItemDataRole.UserRole)
            is_folder = bool(item.data(0, Qt.ItemDataRole.UserRole + 1))
        except RuntimeError:
            return False
        if rel_path and not is_folder and hasattr(self, "sync_manager"):
            self.sync_manager.record_path_change(rel_path, rel_path)
        self._finish_tree_item_creation(item)
        self.save_tree_order()
        return True

    def _finalize_current_tree_creation(self):
        item = getattr(self, "_tree_creation_item", None)
        if item is not None:
            self._commit_tree_item_creation(item)

    def on_tree_editor_closed(self, *_args):
        """Finish a new-item transaction even when inline editing is cancelled."""
        item = getattr(self, "_tree_creation_item", None)
        if item is None:
            item = self.binder_tree.currentItem()

        def finish_if_needed():
            self._commit_tree_item_creation(item)

        QTimer.singleShot(0, finish_if_needed)

    def load_tree_data(self):
        """로컬 폴더를 스캔하여 트리에 동적으로 노드를 생성합니다."""
        self.binder_tree.blockSignals(True)
        self.binder_tree.clear()


        # 고정 노드 맵핑
        self.root_nodes = {
            "📚 원고": "메인/원고",
            "👤 캐릭터": "메인/캐릭터",
            "📖 설정집": "메인/설정집",
            "📝 메모장": "메인/메모장",
            "🗺️ 메인 스토리 틀": "메인/플롯",
            "🌊 흐름 정리": "메인/흐름정리",
            "🔍 복선": "메인/복선",
            "📌 장소": "메인/장소",
            "🗑️ 휴지통": "메인/휴지통"
        }

        tree_order = self.wpm.project_settings.get("tree_order", {})
        root_order = tree_order.get("<root>", [])

        sorted_root_keys = list(self.root_nodes.keys())
        # '📚 원고'는 무조건 최상단(-1)으로 고정, 나머지는 root_order 인덱스를 따름
        sorted_root_keys.sort(key=lambda x: -1 if x == "📚 원고" else (root_order.index(x) if x in root_order else 999))

        for name in sorted_root_keys:
            relative_path = self.root_nodes[name]
            item = QTreeWidgetItem(self.binder_tree, [name])
            item.setData(0, Qt.ItemDataRole.UserRole, relative_path)

            if relative_path and self.wpm.writing_root_path:
                full_path = os.path.join(self.wpm.writing_root_path, relative_path)
                if os.path.exists(full_path):
                    self._populate_tree_level(item, full_path, relative_path)

        # 추가 커스텀 최상위 폴더 및 문서 스캔
        main_path = os.path.join(self.wpm.writing_root_path, "메인") if self.wpm.writing_root_path else ""
        if main_path and os.path.exists(main_path):
            try:
                for d in os.listdir(main_path):
                    if d not in ["원고", "캐릭터", "설정집", "메모장", "플롯", "흐름정리", "복선", "장소", "휴지통"]:
                        full_path = os.path.join(main_path, d)
                        rel_path = f"메인/{d}"

                        if os.path.isdir(full_path):
                            item = QTreeWidgetItem(self.binder_tree, [d])
                            item.setData(0, Qt.ItemDataRole.UserRole, rel_path)
                            item.setIcon(0, self._get_emoji_icon("📁"))
                            self._populate_tree_level(item, full_path, rel_path)
                        elif full_path.endswith(".txt"):
                            display_text = d[:-4]
                            item = QTreeWidgetItem(self.binder_tree, [display_text])
                            item.setData(0, Qt.ItemDataRole.UserRole, rel_path)
                            if os.path.getsize(full_path) == 0:
                                item.setIcon(0, self._get_empty_page_icon())
                            else:
                                item.setIcon(0, self._get_emoji_icon("📝"))
            except Exception:
                pass

        if "expanded_folders" not in self.wpm.project_settings:
            for i in range(self.binder_tree.topLevelItemCount()):
                item = self.binder_tree.topLevelItem(i)
                item.setExpanded(True)
                self.on_tree_item_expanded(item)
        else:
            self.restore_tree_state()

        self.binder_tree.blockSignals(False)

    def _get_emoji_icon(self, emoji_text):
        from PyQt6.QtGui import QPixmap, QPainter, QIcon
        pixmap = QPixmap(20, 20)
        pixmap.fill(Qt.GlobalColor.transparent)
        painter = QPainter(pixmap)
        from PyQt6.QtGui import QFont
        font = QFont("Segoe UI Emoji", 12)
        painter.setFont(font)
        painter.drawText(pixmap.rect(), Qt.AlignmentFlag.AlignCenter, emoji_text)
        painter.end()
        return QIcon(pixmap)

    def _get_empty_page_icon(self):
        from PyQt6.QtGui import QPixmap, QPainter, QIcon, QColor, QPen
        from PyQt6.QtCore import Qt
        pixmap = QPixmap(20, 20)
        pixmap.fill(Qt.GlobalColor.transparent)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        pen = QPen(QColor("#cccccc"))
        pen.setWidth(1)
        painter.setPen(pen)
        painter.setBrush(QColor("#ffffff"))

        # 12x16 픽셀 크기의 아무 무늬 없는 백지 그리기 (오른쪽 위 모서리는 살짝 접힌 효과를 주어도 되지만 깔끔하게 직사각형으로 처리)
        painter.drawRect(4, 2, 12, 16)

        painter.end()
        return QIcon(pixmap)

    def _populate_tree_level(self, parent_item, dir_path, relative_base):
        # Programmatic tree rebuilding changes item data several times.  Those
        # changes must never enter the rename/create handler while the subtree is
        # only half built, otherwise a file can be reinserted as another file's
        # child and the refresh can recurse until the process exits.
        previous_signal_state = self.binder_tree.blockSignals(True)
        try:
            # 게으른 로딩을 위해 기존 자식들을 모두 지웁니다.
            parent_item.takeChildren()
            entries = self._sorted_tree_entries(dir_path, relative_base)

            for entry in entries:
                if entry.endswith(".tmp"):
                    continue
                full_entry_path = os.path.join(dir_path, entry)
                rel_path = os.path.join(relative_base, entry).replace("\\", "/")

                # 파일인 경우 .txt 확장자 숨김 처리
                display_text = entry[:-4] if entry.endswith(".txt") else entry
                child_item = QTreeWidgetItem(parent_item, [display_text])
                child_item.setData(0, Qt.ItemDataRole.UserRole, rel_path)

                if os.path.isdir(full_entry_path):
                    child_item.setIcon(0, self._get_emoji_icon("📁"))
                    # 폴더인 경우, 내부에 항목이 있는지 확인하기 위해 더미 아이템 추가
                    dummy = QTreeWidgetItem(child_item, ["<dummy>"])
                    child_item.setData(0, Qt.ItemDataRole.UserRole + 1, True) # is_folder
                    child_item.setData(0, Qt.ItemDataRole.UserRole + 2, False) # is_loaded
                    child_item.setFlags(
                        Qt.ItemFlag.ItemIsSelectable
                        | Qt.ItemFlag.ItemIsDragEnabled
                        | Qt.ItemFlag.ItemIsDropEnabled
                        | Qt.ItemFlag.ItemIsEnabled
                    )
                else:
                    child_item.setData(0, Qt.ItemDataRole.UserRole + 1, False) # is_folder
                    child_item.setFlags(
                        Qt.ItemFlag.ItemIsSelectable
                        | Qt.ItemFlag.ItemIsDragEnabled
                        | Qt.ItemFlag.ItemIsEnabled
                    )
                    if full_entry_path.endswith(".txt"):
                        if os.path.getsize(full_entry_path) == 0:
                            child_item.setIcon(0, self._get_empty_page_icon())
                        else:
                            child_item.setIcon(0, self._get_emoji_icon("📝"))
        except Exception:
            pass
        finally:
            self.binder_tree.blockSignals(previous_signal_state)

    def _sorted_tree_entries(self, dir_path, relative_base):
        entries = os.listdir(dir_path)

        if relative_base == "메인/휴지통":
            # 휴지통은 장치별 로컬 드래그 순서를 무시하고 최신 삭제본부터
            # 표시한다. 원격 장치에서 보관 파일명이 달라도 순서가 같아진다.
            trash_items = {
                item.get("name"): item
                for item in self.wpm.list_trash_items()
                if item.get("name")
            }

            def trash_sort_key(name):
                info = trash_items.get(name, {})
                deleted_at = info.get("deleted_at") or ""
                try:
                    from datetime import datetime
                    deleted_timestamp = datetime.fromisoformat(
                        deleted_at.replace("Z", "+00:00")
                    ).timestamp()
                except (TypeError, ValueError):
                    try:
                        deleted_timestamp = os.path.getmtime(os.path.join(dir_path, name))
                    except OSError:
                        deleted_timestamp = 0
                # Server commit time is shared by every device. UUID is the
                # deterministic tie breaker when many deletes share a timestamp.
                return (
                    -deleted_timestamp,
                    str(info.get("document_id") or ""),
                    name.casefold(),
                )

            entries.sort(key=trash_sort_key)
            return entries

        tree_order = self.wpm.project_settings.get("tree_order", {})
        saved_order = tree_order.get(relative_base, [])

        def sort_key(x):
            # 1. 커스텀 순서가 저장되어 있으면 그 인덱스를 따른다.
            if x in saved_order:
                return (0, saved_order.index(x))
            # 2. 없으면 폴더가 먼저 오고 이름순으로 (새 파일 등)
            is_file = not os.path.isdir(os.path.join(dir_path, x))
            return (1, is_file, self._natural_sort_key(x))

        entries.sort(key=sort_key)
        return entries

    def on_tree_item_expanded(self, item):
        is_loaded = item.data(0, Qt.ItemDataRole.UserRole + 2)
        if is_loaded is False: # 명시적 체크
            rel_path = item.data(0, Qt.ItemDataRole.UserRole)
            if rel_path and self.wpm.writing_root_path:
                full_path = os.path.join(self.wpm.writing_root_path, rel_path)
                self.binder_tree.blockSignals(True)
                self._populate_tree_level(item, full_path, rel_path)
                item.setData(0, Qt.ItemDataRole.UserRole + 2, True)
                self.binder_tree.blockSignals(False)

    def save_tree_state(self, item=None):
        if getattr(self, '_is_restoring_tree', False):
            return

        expanded_paths = []
        def traverse(current_item):
            if current_item.isExpanded():
                rel_path = current_item.data(0, Qt.ItemDataRole.UserRole)
                if rel_path:
                    expanded_paths.append(rel_path)
            for i in range(current_item.childCount()):
                traverse(current_item.child(i))

        for i in range(self.binder_tree.topLevelItemCount()):
            traverse(self.binder_tree.topLevelItem(i))

        self.wpm.project_settings["expanded_folders"] = expanded_paths
        self.wpm.save_settings()

    def restore_tree_state(self):
        expanded_paths = set(self.wpm.project_settings.get("expanded_folders", []))
        if not expanded_paths: return

        self._is_restoring_tree = True
        try:
            def try_expand(current_item):
                rel_path = current_item.data(0, Qt.ItemDataRole.UserRole)
                if rel_path in expanded_paths:
                    if not current_item.isExpanded():
                        current_item.setExpanded(True)
                        self.on_tree_item_expanded(current_item)
                    for i in range(current_item.childCount()):
                        try_expand(current_item.child(i))

            for i in range(self.binder_tree.topLevelItemCount()):
                try_expand(self.binder_tree.topLevelItem(i))
        finally:
            self._is_restoring_tree = False

    def _natural_sort_key(self, s):
        return [int(text) if text.isdigit() else text.lower() for text in re.split('([0-9]+)', s)]

    def show_tree_context_menu(self, pos):
        from PyQt6.QtWidgets import QApplication, QMenu
        from PyQt6.QtCore import Qt, QTimer, QObject, QEvent
        from PyQt6.QtGui import QAction

        callbacks = {}
        custom_triggered_shortcut = [None]

        class GlobalMenuFilter(QObject):
            def __init__(self, menu):
                super().__init__()
                self.menu = menu
                self._processing = False

            def eventFilter(self, obj, event):
                if self._processing:
                    return False
                self._processing = True
                try:
                    target_shortcut = None

                    if event.type() == QEvent.Type.KeyPress:
                        key = event.key()
                        text = event.text().lower()
                        try:
                            vk = event.nativeVirtualKey()
                        except:
                            vk = 0

                        if key == Qt.Key.Key_F or text in ['f', 'ㄹ'] or vk == 0x46:
                            target_shortcut = 'F'
                        elif key == Qt.Key.Key_N or text in ['n', 'ㅜ'] or vk == 0x4E:
                            target_shortcut = 'N'
                        elif key == Qt.Key.Key_D or text in ['d', 'ㅇ'] or vk == 0x44:
                            target_shortcut = 'D'
                        elif key == Qt.Key.Key_E or text in ['e', 'ㄷ'] or vk == 0x45:
                            target_shortcut = 'E'

                    elif event.type() == QEvent.Type.InputMethod:
                        text = event.commitString()
                        if not text:
                            text = event.preeditString()
                        if text:
                            text = text.lower()
                            if text in ['f', 'ㄹ']:
                                target_shortcut = 'F'
                            elif text in ['n', 'ㅜ']:
                                target_shortcut = 'N'
                            elif text in ['d', 'ㅇ']:
                                target_shortcut = 'D'
                            elif text in ['e', 'ㄷ']:
                                target_shortcut = 'E'

                    if target_shortcut and target_shortcut in callbacks:
                        custom_triggered_shortcut[0] = target_shortcut
                        self.menu.close()
                        return True

                    return False
                finally:
                    self._processing = False

        item = self.binder_tree.itemAt(pos)
        menu = QMenu(self.window())

        if not item:
            add_folder_action = QAction("새 폴더", self)
            add_folder_action.triggered.connect(lambda: self.start_create_root_item(is_folder=True))
            menu.addAction(add_folder_action)
            callbacks['F'] = lambda: self.start_create_root_item(is_folder=True)

            add_file_action = QAction("새 문서", self)
            add_file_action.triggered.connect(lambda: self.start_create_root_item(is_folder=False))
            menu.addAction(add_file_action)
            callbacks['N'] = lambda: self.start_create_root_item(is_folder=False)
        elif item.text(0) == "📚 원고":
            add_volume_action = QAction("권 추가", self)
            add_volume_action.triggered.connect(self.add_volume)
            menu.addAction(add_volume_action)

            menu.addSeparator()
            extract_menu = menu.addMenu("챕터 추출")

            extract_all_action = QAction("전체 추출", self)
            extract_all_action.triggered.connect(self.extract_all_chapters)
            extract_menu.addAction(extract_all_action)

            extract_partial_action = QAction("부분 추출", self)
            extract_partial_action.triggered.connect(self.extract_partial_chapters)
            extract_menu.addAction(extract_partial_action)
        elif item.text(0) == "🗑️ 휴지통":
            empty_trash_action = QAction("비우기", self)
            empty_trash_action.triggered.connect(self.empty_trash)
            menu.addAction(empty_trash_action)
            callbacks['E'] = self.empty_trash
            callbacks['D'] = self.empty_trash
        else:
            rel_path = item.data(0, Qt.ItemDataRole.UserRole)
            is_file = rel_path and rel_path.endswith(".txt")
            top_parent = item
            while top_parent.parent():
                top_parent = top_parent.parent()

            if top_parent.text(0) == "🗑️ 휴지통":
                restore_original_action = QAction("↩ 원래 위치로 복원", self)
                restore_original_action.triggered.connect(lambda: self.restore_trash_item(item))
                menu.addAction(restore_original_action)

                restore_selected_action = QAction("📁 선택 위치로 복원", self)
                restore_selected_action.triggered.connect(lambda: self.restore_trash_item(item, choose_location=True))
                menu.addAction(restore_selected_action)
                menu.addSeparator()

                delete_action = QAction("영구 삭제", self)
                delete_action.triggered.connect(lambda: self.delete_tree_item(item))
                menu.addAction(delete_action)
                callbacks['D'] = lambda: self.delete_tree_item(item)
            else:
                if is_file:
                    history_action = QAction("🕒 이전 버전 보기/복원", self)
                    history_action.triggered.connect(lambda: self.show_history_viewer(rel_path))
                    menu.addAction(history_action)

                if top_parent.text(0) != "📚 원고" and not is_file:
                    add_folder_action = QAction("새 폴더", self)
                    add_folder_action.triggered.connect(lambda: self.start_create_item(item, is_folder=True))
                    menu.addAction(add_folder_action)
                    callbacks['F'] = lambda: self.start_create_item(item, is_folder=True)

                    add_file_action = QAction("새 문서", self)
                    add_file_action.triggered.connect(lambda: self.start_create_item(item, is_folder=False))
                    menu.addAction(add_file_action)
                    callbacks['N'] = lambda: self.start_create_item(item, is_folder=False)

                if item.parent() is not None or item.text(0) not in self.root_nodes:
                    is_volume = (item.parent() is not None and item.parent().text(0) == "📚 원고")
                    if not is_volume:
                        rename_action = QAction("이름 변경", self)
                        rename_action.triggered.connect(lambda: self.start_rename_item(item))
                        menu.addAction(rename_action)

                    # '📚 원고' 하위의 모든 폴더/파일은 삭제 불가 (불상사 방지)
                    if top_parent.text(0) != "📚 원고":
                        delete_action = QAction("삭제", self)
                        delete_action.triggered.connect(lambda: self.delete_tree_item(item))
                        menu.addAction(delete_action)
                        callbacks['D'] = lambda: self.delete_tree_item(item)

        # 글로벌 이벤트 필터 장착 (메뉴가 열려있는 동안 모든 키보드/IME 이벤트 감시)
        global_filter = GlobalMenuFilter(menu)
        QApplication.instance().installEventFilter(global_filter)

        def _exec_menu():
            try:
                # 50ms 대기하는 동안 이미 단축키가 눌렸다면 메뉴를 열지 않고 바로 콜백 실행
                if custom_triggered_shortcut[0] is None:
                    menu.exec(self.binder_tree.viewport().mapToGlobal(pos))
            finally:
                QApplication.instance().removeEventFilter(global_filter)

                # 좀비 청소
                for action in menu.actions():
                    action.deleteLater()

                # 안전한 외부 실행 (팝업 충돌 방지)
                triggered_shortcut = custom_triggered_shortcut[0]
                if triggered_shortcut:
                    QApplication.inputMethod().reset()
                    QTimer.singleShot(0, callbacks[triggered_shortcut])

        QTimer.singleShot(50, _exec_menu)

    def delete_tree_item(self, item):
        rel_path = item.data(0, Qt.ItemDataRole.UserRole)
        if not rel_path: return

        top_parent = item
        while top_parent.parent():
            top_parent = top_parent.parent()

        if top_parent.text(0) == "🗑️ 휴지통":
            reply = QMessageBox.question(self, "영구 삭제 확인", f"'{item.text(0)}'을(를) 영구적으로 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.", QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
            if reply == QMessageBox.StandardButton.Yes:
                try:
                    trash_entry = next(
                        (
                            entry for entry in self.wpm.list_trash_items()
                            if entry.get("trash_path") == rel_path
                        ),
                        {"trash_path": rel_path},
                    )
                    self.wpm.delete_from_trash(rel_path)
                    if hasattr(self, "sync_manager"):
                        self.sync_manager.record_trash_purge([trash_entry])
                    self._cleanup_after_delete(rel_path, item)
                except Exception as e:
                    QMessageBox.warning(self, "오류", f"영구 삭제 실패: {e}")
            return

        reply = QMessageBox.question(self, "삭제 확인", f"'{item.text(0)}'을(를) 휴지통으로 이동하시겠습니까?", QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
        if reply == QMessageBox.StandardButton.Yes:
            try:
                trash_rel_path = self.wpm.move_to_trash(rel_path)
                if hasattr(self, "sync_manager"):
                    self.sync_manager.record_tombstone(rel_path, trash_rel_path)
                if hasattr(self, "controller"):
                    self.controller.forget_path(rel_path)
                self._cleanup_after_delete(rel_path, item)

                # 휴지통 노드 시각적 갱신
                for i in range(self.binder_tree.topLevelItemCount()):
                    if self.binder_tree.topLevelItem(i).text(0) == "🗑️ 휴지통":
                        trash_item = self.binder_tree.topLevelItem(i)
                        if trash_item.isExpanded():
                            self._populate_tree_level(trash_item, os.path.join(self.wpm.writing_root_path, "메인", "휴지통"), "메인/휴지통")
                        else:
                            trash_item.setData(0, Qt.ItemDataRole.UserRole + 2, False) # is_loaded = False
                            if trash_item.childCount() == 0:
                                from PyQt6.QtWidgets import QTreeWidgetItem
                                QTreeWidgetItem(trash_item, ["<dummy>"])
                        break
            except Exception as e:
                QMessageBox.warning(self, "오류", f"삭제 실패: {e}")

    def restore_trash_item(self, item, choose_location=False):
        rel_path = item.data(0, Qt.ItemDataRole.UserRole)
        if not rel_path:
            return

        destination_parent = None
        if choose_location:
            main_root = os.path.abspath(os.path.join(self.wpm.writing_root_path, "메인"))
            selected = QFileDialog.getExistingDirectory(self, "복원할 위치 선택", main_root)
            if not selected:
                return
            selected = os.path.abspath(selected)
            try:
                if os.path.commonpath([selected, main_root]) != main_root:
                    raise ValueError
            except ValueError:
                QMessageBox.warning(self, "복원 실패", "집필 모드의 메인 폴더 안에서 위치를 선택해주세요.")
                return
            destination_parent = os.path.relpath(selected, self.wpm.writing_root_path).replace("\\", "/")

        try:
            restored_path = self.wpm.restore_from_trash(rel_path, destination_parent)
            if hasattr(self, "sync_manager"):
                self.sync_manager.record_restore(rel_path, restored_path)
            if hasattr(self, "controller"):
                self.controller.rename_path(rel_path, restored_path)
            self.load_tree_data()
            QMessageBox.information(self, "복원 완료", f"다음 위치로 복원했습니다.\n{restored_path}")
        except Exception as e:
            QMessageBox.warning(self, "복원 실패", str(e))

    def _cleanup_after_delete(self, rel_path, item):
        parent = item.parent()
        if parent:
            parent.removeChild(item)
        else:
            index = self.binder_tree.indexOfTopLevelItem(item)
            self.binder_tree.takeTopLevelItem(index)

        def path_was_deleted(current_path):
            return bool(
                current_path
                and (current_path == rel_path or current_path.startswith(rel_path + "/"))
            )

        if path_was_deleted(getattr(self, 'current_loaded_file_left', None)):
            self.left_editor.clear()
            self.left_editor.setReadOnly(True)
            self.current_loaded_file_left = None
            self.lbl_current_doc.setText("문서를 선택하세요")
            self.is_dirty_left = False
            self.left_editor.document().setModified(False)

        if path_was_deleted(getattr(self, 'current_loaded_file_right', None)):
            self.right_editor.clear()
            self.right_editor.setReadOnly(True)
            self.current_loaded_file_right = None
            self.lbl_r_doc.setText("문서를 선택하세요")
            self.is_dirty_right = False
            self.right_editor.document().setModified(False)

        self.save_tree_order()

    def empty_trash(self):
        reply = QMessageBox.question(self, "휴지통 비우기", "휴지통의 모든 항목을 영구적으로 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.", QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
        if reply == QMessageBox.StandardButton.Yes:
            try:
                trash_items = self.wpm.list_trash_items()
                self.wpm.empty_trash()
                if hasattr(self, "sync_manager"):
                    self.sync_manager.record_trash_purge(
                        trash_items, empty_all=True
                    )
                for i in range(self.binder_tree.topLevelItemCount()):
                    if self.binder_tree.topLevelItem(i).text(0) == "🗑️ 휴지통":
                        trash_item = self.binder_tree.topLevelItem(i)
                        trash_item.takeChildren()
                        break
                QMessageBox.information(self, "완료", "휴지통을 비웠습니다.")
            except Exception as e:
                QMessageBox.warning(self, "오류", f"휴지통 비우기 실패: {e}")

    def handle_item_moved(self, item, old_rel_path, new_parent_rel_path):
        try:
            new_rel_path = self.wpm.move_item(old_rel_path, new_parent_rel_path)
            if hasattr(self, "sync_manager"):
                self.sync_manager.record_path_change(old_rel_path, new_rel_path)
            if hasattr(self, "controller"):
                self.controller.rename_path(old_rel_path, new_rel_path)

            # 하위 항목들의 rel_path도 전부 업데이트
            def update_paths(node, current_rel_path):
                node.setData(0, Qt.ItemDataRole.UserRole, current_rel_path)
                for i in range(node.childCount()):
                    child = node.child(i)
                    if child.text(0) == "<dummy>": continue
                    child_basename = os.path.basename(child.data(0, Qt.ItemDataRole.UserRole))
                    update_paths(child, os.path.join(current_rel_path, child_basename).replace("\\", "/"))

            update_paths(item, new_rel_path)

            def update_loaded_file(attr_name):
                current_path = getattr(self, attr_name, None)
                if current_path:
                    if current_path == old_rel_path:
                        setattr(self, attr_name, new_rel_path)
                    elif current_path.startswith(old_rel_path + "/"):
                        setattr(self, attr_name, current_path.replace(old_rel_path, new_rel_path, 1))

            update_loaded_file('current_loaded_file_left')
            update_loaded_file('current_loaded_file_right')

            self.save_tree_order()

        except Exception as e:
            QMessageBox.warning(self, "이동 실패", f"항목을 이동할 수 없습니다:\n{e}")
            self.load_tree_data() # UI 원복

    def save_tree_order(self):
        tree_order = {}
        def traverse(item):
            rel_path = item.data(0, Qt.ItemDataRole.UserRole)
            if rel_path:
                child_names = []
                for i in range(item.childCount()):
                    child = item.child(i)
                    if child.text(0) == "<dummy>": continue
                    child_rel_path = child.data(0, Qt.ItemDataRole.UserRole)
                    if child_rel_path:
                        child_names.append(os.path.basename(child_rel_path))
                if child_names:
                    tree_order[rel_path] = child_names
            for i in range(item.childCount()):
                traverse(item.child(i))

        root_names = []
        for i in range(self.binder_tree.topLevelItemCount()):
            item = self.binder_tree.topLevelItem(i)
            root_names.append(item.text(0))
            traverse(item)

        tree_order["<root>"] = root_names
        self.wpm.project_settings["tree_order"] = tree_order
        self.wpm.save_settings()
        if hasattr(self, "sync_manager"):
            self.sync_manager.record_tree_order(tree_order)

    def start_create_root_item(self, is_folder):
        # Rapid clicks can arrive before the first 150ms inline-editor timer.
        # Commit the previous default-named item so only one editor can open.
        self._finalize_current_tree_creation()
        new_name = self.wpm.create_physical_item("메인", "새 폴더" if is_folder else "새_문서", is_folder)
        if not new_name: return

        self.binder_tree.blockSignals(True)
        new_item = QTreeWidgetItem(self.binder_tree)
        display_name = new_name[:-4] if not is_folder else new_name
        new_item.setText(0, display_name)
        editable_flags = Qt.ItemFlag.ItemIsSelectable | Qt.ItemFlag.ItemIsEditable | Qt.ItemFlag.ItemIsDragEnabled | Qt.ItemFlag.ItemIsDropEnabled | Qt.ItemFlag.ItemIsEnabled
        new_item.setFlags(editable_flags)

        if is_folder:
            new_item.setIcon(0, self._get_emoji_icon("📁"))
        else:
            new_item.setIcon(0, self._get_empty_page_icon())

        new_item.setData(0, Qt.ItemDataRole.UserRole, f"메인/{new_name}")
        new_item.setData(0, Qt.ItemDataRole.UserRole + 1, is_folder)
        new_item.setData(0, Qt.ItemDataRole.UserRole + 4, True)  # creation in progress
        self.binder_tree.blockSignals(False)
        pending_items = getattr(self, "_pending_tree_creation_items", [])
        pending_items.append(new_item)
        self._pending_tree_creation_items = pending_items
        self._tree_creation_item = new_item
        self._tree_item_creation_active = True

        def edit_new_item():
            try:
                if not bool(new_item.data(0, Qt.ItemDataRole.UserRole + 4)):
                    return
            except RuntimeError:
                return
            self.binder_tree.blockSignals(True)
            self.binder_tree.scrollToItem(new_item)
            self.binder_tree.setCurrentItem(new_item)
            self.binder_tree.blockSignals(False)

            self.binder_tree.setFocus()
            self.binder_tree.editItem(new_item, 0)

        from PyQt6.QtCore import QTimer
        QTimer.singleShot(150, edit_new_item)

    def show_history_viewer(self, rel_path):
        if not self.wpm.writing_root_path: return
        dialog = HistoryViewerDialog(self.wpm, rel_path, self)
        if dialog.exec():
            backup_path = dialog.get_selected_backup_path()
            if backup_path:
                success, msg = self.sync_manager.check_and_acquire_lock(self.pm.current_project, rel_path, self.session_id)
                if not success:
                    QMessageBox.warning(self, "복원 실패", msg)
                    return
                try:
                    restore_result = self.wpm.restore_backup(rel_path, backup_path)
                    restored_content = restore_result["content"]
                except Exception as e:
                    QMessageBox.warning(self, "복원 실패", str(e))
                    return
                self.sync_manager.upload_content_async(
                    self.wpm, self.pm.current_project, rel_path, restored_content,
                    local_updated_at=self.loaded_versions.get(rel_path),
                    conflict_callback=self.on_conflict_detected
                )
                if self.current_loaded_file_left == rel_path:
                    self.left_editor.blockSignals(True)
                    self.left_editor.setText(restored_content)
                    self.left_editor.document().setModified(False)
                    self.is_dirty_left = False

                    from PyQt6.QtGui import QTextCursor
                    cursor = self.left_editor.textCursor()
                    cursor.movePosition(QTextCursor.MoveOperation.End)
                    self.left_editor.setTextCursor(cursor)

                    self.left_editor.blockSignals(False)
                if self.current_loaded_file_right == rel_path:
                    self.right_editor.blockSignals(True)
                    self.right_editor.setText(restored_content)
                    self.right_editor.document().setModified(False)
                    self.is_dirty_right = False

                    from PyQt6.QtGui import QTextCursor
                    cursor = self.right_editor.textCursor()
                    cursor.movePosition(QTextCursor.MoveOperation.End)
                    self.right_editor.setTextCursor(cursor)

                    self.right_editor.blockSignals(False)
                self.apply_editor_margins()
                QMessageBox.information(self, "복원 완료", "과거 버전으로 성공적으로 복원되었습니다.")

    def start_create_item(self, parent_item, is_folder):
        if not parent_item: return
        if parent_item.data(0, Qt.ItemDataRole.UserRole + 1) is False:
            return
        self._finalize_current_tree_creation()
        if not parent_item.isExpanded():
            parent_item.setExpanded(True)

        parent_rel_path = parent_item.data(0, Qt.ItemDataRole.UserRole)

        new_name = self.wpm.create_physical_item(parent_rel_path, "새 폴더" if is_folder else "새_문서", is_folder)
        new_rel_path = os.path.join(parent_rel_path, new_name).replace("\\", "/") if parent_rel_path else new_name

        self.binder_tree.blockSignals(True)
        new_item = QTreeWidgetItem(parent_item)
        display_name = new_name[:-4] if not is_folder else new_name
        new_item.setText(0, display_name)
        editable_flags = (
            Qt.ItemFlag.ItemIsSelectable
            | Qt.ItemFlag.ItemIsEditable
            | Qt.ItemFlag.ItemIsDragEnabled
            | Qt.ItemFlag.ItemIsEnabled
        )
        if is_folder:
            editable_flags |= Qt.ItemFlag.ItemIsDropEnabled
        new_item.setFlags(editable_flags)

        if not is_folder:
            new_item.setIcon(0, self._get_empty_page_icon())
        else:
            new_item.setIcon(0, self._get_emoji_icon("📁"))

        new_item.setData(0, Qt.ItemDataRole.UserRole, new_rel_path)
        new_item.setData(0, Qt.ItemDataRole.UserRole + 1, is_folder)
        new_item.setData(0, Qt.ItemDataRole.UserRole + 4, True)  # creation in progress
        self.binder_tree.blockSignals(False)
        pending_items = getattr(self, "_pending_tree_creation_items", [])
        pending_items.append(new_item)
        self._pending_tree_creation_items = pending_items
        self._tree_creation_item = new_item
        self._tree_item_creation_active = True

        def edit_new_item():
            try:
                if not bool(new_item.data(0, Qt.ItemDataRole.UserRole + 4)):
                    return
            except RuntimeError:
                return
            self.binder_tree.blockSignals(True)
            self.binder_tree.scrollToItem(new_item)
            self.binder_tree.setCurrentItem(new_item)
            self.binder_tree.blockSignals(False)

            self.binder_tree.setFocus()
            self.binder_tree.editItem(new_item, 0)

        from PyQt6.QtCore import QTimer
        QTimer.singleShot(150, edit_new_item)

    def start_rename_item(self, item=None):
        if item is None:
            item = self.binder_tree.currentItem()
        if not item: return

        if item.parent() is None and item.text(0) in self.root_nodes:
            return

        is_volume = (item.parent() is not None and item.parent().text(0) == "📚 원고")
        if is_volume:
            return

        is_folder = item.data(0, Qt.ItemDataRole.UserRole + 1) is True
        editable_flags = (
            Qt.ItemFlag.ItemIsSelectable
            | Qt.ItemFlag.ItemIsEditable
            | Qt.ItemFlag.ItemIsDragEnabled
            | Qt.ItemFlag.ItemIsEnabled
        )
        if is_folder:
            editable_flags |= Qt.ItemFlag.ItemIsDropEnabled
        self.binder_tree.blockSignals(True)
        item.setFlags(editable_flags)
        self.binder_tree.blockSignals(False)
        self.binder_tree.editItem(item, 0)

    def on_tree_item_changed(self, item, column):
        is_folder = item.data(0, Qt.ItemDataRole.UserRole + 1)
        was_creating = bool(item.data(0, Qt.ItemDataRole.UserRole + 4))
        print(f"[DEBUG TOP] on_tree_item_changed called! is_folder = {is_folder!r}, text = {item.text(0)!r}")
        if is_folder is not None:
            self.binder_tree.blockSignals(True)
            try:
                old_rel_path = item.data(0, Qt.ItemDataRole.UserRole)
                if not old_rel_path: return

                parent_rel_path = os.path.dirname(old_rel_path)
                new_display_name = item.text(0)

                # '📚 원고' 하위 항목 이름 변경 규칙 강제
                if old_rel_path.startswith("메인/원고/"):
                    if is_folder:
                        # 더 이상 이곳에 도달하지 않아야 하지만, 안전장치로 롤백만 수행 (팝업 제거)
                        item.setText(0, os.path.basename(old_rel_path))

                        return
                    else:
                        old_base = os.path.basename(old_rel_path).replace(".txt", "")
                        match = re.match(r'^(\d+화)', old_base)
                        if match:
                            prefix = match.group(1)
                            if not new_display_name.startswith(prefix):
                                cleaned_suffix = re.sub(r'^\d+화\s*', '', new_display_name)
                                new_display_name = f"{prefix} {cleaned_suffix}".strip()
                                item.setText(0, new_display_name)

                if not is_folder:
                    new_name = new_display_name + ".txt"
                else:
                    new_name = new_display_name

                new_rel_path = os.path.join(parent_rel_path, new_name).replace("\\", "/") if parent_rel_path else new_name

                if old_rel_path == new_rel_path:
                    if was_creating and hasattr(self, "sync_manager"):
                        self.sync_manager.record_path_change(old_rel_path, new_rel_path)
                    if was_creating:
                        self._finish_tree_item_creation(item)
                        self.save_tree_order()
                    item_flags = (
                        Qt.ItemFlag.ItemIsSelectable
                        | Qt.ItemFlag.ItemIsDragEnabled
                        | Qt.ItemFlag.ItemIsEnabled
                    )
                    if is_folder:
                        item_flags |= Qt.ItemFlag.ItemIsDropEnabled
                    item.setFlags(item_flags)
                    def _set_active():
                        try:
                            self.binder_tree.setCurrentItem(item)
                            item.setSelected(True)
                            from PyQt6.QtWidgets import QApplication
                            if not QApplication.activePopupWidget():
                                self.binder_tree.setFocus()
                        except RuntimeError:
                            pass
                    from PyQt6.QtCore import QTimer
                    QTimer.singleShot(10, _set_active)
                    return

                print(f"[DEBUG] rename target: {old_rel_path} -> {new_rel_path}")
                print(f"[DEBUG] writing_root_path = {self.wpm.writing_root_path!r}")
                print(f"[DEBUG] wpm object id = {id(self.wpm)}")

                if self.wpm.writing_root_path:
                    try:
                        self.wpm.rename_item(old_rel_path, new_rel_path)
                        if hasattr(self, "sync_manager"):
                            self.sync_manager.record_path_change(old_rel_path, new_rel_path)
                        if hasattr(self, "controller"):
                            self.controller.rename_path(old_rel_path, new_rel_path)
                        item.setData(0, Qt.ItemDataRole.UserRole, new_rel_path)
                        if was_creating:
                            self._finish_tree_item_creation(item)
                        print(f"[DEBUG] setData 직후 재확인: {item.data(0, Qt.ItemDataRole.UserRole)!r}")

                        # 1. 탭 제목 실시간 갱신 및 현재 열린 파일 경로 갱신
                        def update_loaded_file(attr_name, label_widget):
                            current_path = getattr(self, attr_name, None)
                            if current_path:
                                if current_path == old_rel_path:
                                    setattr(self, attr_name, new_rel_path)
                                    base_name = os.path.basename(new_rel_path).replace(".txt", "")
                                    label_widget.setText(f"{base_name}")
                                    if attr_name == 'current_loaded_file_left':
                                        self._original_text_l = f"{base_name}"
                                    else:
                                        self._original_text_r = f"{base_name}"
                                elif current_path.startswith(old_rel_path + "/"):
                                    new_cur_path = current_path.replace(old_rel_path, new_rel_path, 1)
                                    setattr(self, attr_name, new_cur_path)
                                    base_name = os.path.basename(new_cur_path).replace(".txt", "")
                                    label_widget.setText(f"{base_name}")
                                    if attr_name == 'current_loaded_file_left':
                                        self._original_text_l = f"{base_name}"
                                    else:
                                        self._original_text_r = f"{base_name}"

                        update_loaded_file('current_loaded_file_left', self.lbl_current_doc)
                        update_loaded_file('current_loaded_file_right', self.lbl_r_doc)

                        # 2. 서버 동기화 버전 캐시(self.loaded_versions) 동기화
                        new_versions = {}
                        for path, version in list(self.loaded_versions.items()):
                            if path == old_rel_path:
                                new_versions[new_rel_path] = self.loaded_versions.pop(path)
                            elif path.startswith(old_rel_path + "/"):
                                new_path = path.replace(old_rel_path, new_rel_path, 1)
                                new_versions[new_path] = self.loaded_versions.pop(path)
                        self.loaded_versions.update(new_versions)

                        # 3. 만약 폴더라면, 트리에 이미 존재하는 자식 노드들의 UserRole 경로도 동기적으로 즉시 갱신 (레이스 컨디션 방지)
                        if is_folder:
                            def update_children_user_role(parent_item, old_base, new_base):
                                for i in range(parent_item.childCount()):
                                    child = parent_item.child(i)
                                    child_path = child.data(0, Qt.ItemDataRole.UserRole)
                                    if child_path and child_path.startswith(old_base + "/"):
                                        new_child_path = child_path.replace(old_base, new_base, 1)
                                        child.setData(0, Qt.ItemDataRole.UserRole, new_child_path)
                                        update_children_user_role(child, old_base, new_base)
                            update_children_user_role(item, old_rel_path, new_rel_path)

                        self.save_tree_order()

                        def _set_active():
                            try:
                                self.binder_tree.setCurrentItem(item)
                                item.setSelected(True)
                                from PyQt6.QtWidgets import QApplication
                                if not QApplication.activePopupWidget():
                                    self.binder_tree.setFocus()
                            except RuntimeError:
                                pass
                        from PyQt6.QtCore import QTimer
                        QTimer.singleShot(10, _set_active)
                    except Exception as e:
                        if was_creating:
                            self._finish_tree_item_creation(item)
                        print(f"[DEBUG] rename_item 실패! old={old_rel_path!r}, new={new_rel_path!r}, error={e!r}")
                        QMessageBox.warning(self, "오류", f"이름 변경 실패: {e}")
                        item.setText(0, os.path.basename(old_rel_path).replace(".txt", "") if not is_folder else os.path.basename(old_rel_path))

                        def _set_active():
                            try:
                                self.binder_tree.setCurrentItem(item)
                                item.setSelected(True)
                                from PyQt6.QtWidgets import QApplication
                                if not QApplication.activePopupWidget():
                                    self.binder_tree.setFocus()
                            except RuntimeError:
                                pass
                        from PyQt6.QtCore import QTimer
                        QTimer.singleShot(10, _set_active)
            finally:
                self.binder_tree.blockSignals(False)

    def add_volume(self):
        new_vol_name = self.wpm.add_volume()
        if not new_vol_name: return

        QMessageBox.information(self, "권 추가", f"{new_vol_name}이 생성되고 25화 분량 파일이 만들어졌습니다.")
        self.load_tree_data()

        # 새 권수 아이템 포커스 강제
        def _set_active():
            for i in range(self.binder_tree.topLevelItemCount()):
                root_item = self.binder_tree.topLevelItem(i)
                if root_item.text(0) == "📚 원고":
                    for j in range(root_item.childCount()):
                        if root_item.child(j).text(0) == new_vol_name:
                            new_item = root_item.child(j)
                            self.binder_tree.setCurrentItem(new_item)
                            new_item.setSelected(True)
                            self.binder_tree.setFocus()
                            break
                    break
        from PyQt6.QtCore import QTimer
        QTimer.singleShot(10, _set_active)

    def on_tree_current_item_changed(self, current, previous):
        if not current:
            return
        if bool(current.data(0, Qt.ItemDataRole.UserRole + 4)):
            return
        rel_path = current.data(0, Qt.ItemDataRole.UserRole)
        print(f"[DEBUG] 클릭 시 읽어온 경로: {rel_path!r}")
        if not rel_path:
            return

        self._open_file_by_path(rel_path)
