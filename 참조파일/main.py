import sys, os
from PyQt6.QtWidgets import QApplication, QMainWindow, QStackedWidget
from PyQt6.QtGui import QIcon, QFont, QKeySequence, QShortcut
from PyQt6.QtCore import QEvent, Qt

from mode_assistant import AssistantModeWidget, SingleApplication
from mode_writing import WritingModeWidget
from text_editor import SmartTextEdit
from ui_components import get_saved_font

MIN_MAIN_WINDOW_WIDTH = 1000
MIN_MAIN_WINDOW_HEIGHT = 800


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setStyleSheet("QMainWindow { background-color: #1b1d24; }")
        
        # 1. AI 어시스턴트 모드 초기화 (여기서 프로젝트 선택 다이얼로그 뜸)
        self.assistant_mode = AssistantModeWidget()
        
        # 2. Window Title 설정 (AssistantModeWidget.pm 에 선택된 프로젝트가 있음)
        project_name = self.assistant_mode.pm.current_project
        from runtime_profile import profile_name
        profile = profile_name()
        profile_label = f" [{profile}]" if profile else ""
        self.setWindowTitle(f"웹소설 어시스턴트{profile_label} - [{project_name}]")
        # 사이드바의 큰 한글 탭과 상단 컨트롤이 압축되지 않는 최소 크기다.
        self.setMinimumSize(MIN_MAIN_WINDOW_WIDTH, MIN_MAIN_WINDOW_HEIGHT)
        
        # 전역 폰트 설정 (맑은고딕 Bold)
        app_font = QFont("Malgun Gothic", 10, QFont.Weight.Bold)
        QApplication.setFont(app_font)
        
        # 3. 집필 모드 초기화
        self.writing_mode = WritingModeWidget(self.assistant_mode.pm)
        
        self.init_ui()
        
        # 창 크기 복원 (기존 main.py의 restore_window_state 로직)
        self.restore_window_state()

    def event(self, event):
        handled = super().event(event)
        if (
            event.type() == QEvent.Type.WindowActivate
            and hasattr(self, "writing_mode")
            and SmartTextEdit._force_korean_on_first_activation
        ):
            SmartTextEdit.force_startup_korean_for_widget(self)
        return handled

    def init_ui(self):
        self.mode_stack = QStackedWidget()
        self.setCentralWidget(self.mode_stack)
        
        self.mode_stack.addWidget(self.assistant_mode)
        self.mode_stack.addWidget(self.writing_mode)
        
        # writing_mode 참조 전달 (종료 시 팝업 등에서 사용)
        self.assistant_mode.writing_mode = self.writing_mode
        
        # 모드 스위칭 시그널 연결
        self.assistant_mode.switchModeRequested.connect(self.switch_to_writing)
        self.writing_mode.switchModeRequested.connect(self.switch_to_assistant)
        
        # 브릿지 시그널 연결
        self.assistant_mode.sendToWritingModeRequested.connect(self.handle_send_to_writing)
        self.writing_mode.sendToAssistantRequested.connect(self.handle_send_to_assistant)
        self.assistant_mode.typewriterModeToggled.connect(self.on_typewriter_toggled)
        
        # F11 단축키로 모드 전환
        self.shortcut_toggle_mode = QShortcut(QKeySequence("F11"), self)
        self.shortcut_toggle_mode.activated.connect(self.toggle_mode)
        
    def switch_to_writing(self):
        self.mode_stack.setCurrentWidget(self.writing_mode)
        self.writing_mode.activate_current_editor_input()
        
    def switch_to_assistant(self):
        self.mode_stack.setCurrentWidget(self.assistant_mode)
        
    def toggle_mode(self):
        if self.mode_stack.currentWidget() == self.assistant_mode:
            self.switch_to_writing()
        else:
            self.switch_to_assistant()

    def handle_send_to_writing(self, text):
        # 활성화된 에디터에 내용 추가 (좌우 분할 모드 지원)
        active_editor = self.writing_mode.active_editor
        if not active_editor:
            active_editor = self.writing_mode.left_editor
        active_editor.append("\n" + text)
        self.switch_to_writing()

    def handle_send_to_assistant(self, text):
        # 어시스턴트 모드에서 현재 활성화된 패널(좌/우 중 하나)의 텍스트 에디터에 추가
        side = getattr(self.assistant_mode, 'last_focused_side', "left")
        stack = self.assistant_mode.left_stack if side == "left" else self.assistant_mode.right_stack
        idx = stack.currentIndex()
        if idx >= 0:
            panel = stack.widget(idx)
            if hasattr(panel, 'text_edit'):
                panel.text_edit.append("\n" + text)
        self.switch_to_assistant()
        
    def on_typewriter_toggled(self, step_name, enabled):
        if step_name == "집필모드":
            self.writing_mode.update_typewriter_setting()

    def restore_window_state(self):
        try:
            geometry = self.assistant_mode.pm.global_config.get("window_geometry")
            state = self.assistant_mode.pm.global_config.get("window_state")
            if geometry:
                from PyQt6.QtCore import QByteArray
                self.restoreGeometry(QByteArray.fromHex(geometry.encode()))
            if state:
                from PyQt6.QtCore import QByteArray
                self.restoreState(QByteArray.fromHex(state.encode()))
        except Exception as e:
            print(f"창 상태 복원 실패: {e}")

    def closeEvent(self, event):
        # 창 상태 저장
        self.assistant_mode.pm.global_config["window_geometry"] = self.saveGeometry().toHex().data().decode()
        self.assistant_mode.pm.global_config["window_state"] = self.saveState().toHex().data().decode()
        self.assistant_mode.pm.save_global_config()
        
        # assistant_mode 에 있는 close 로직들 호출
        if hasattr(self.assistant_mode, 'closeEvent'):
            self.assistant_mode.closeEvent(event)
            
        if event.isAccepted() and hasattr(self, 'writing_mode') and hasattr(self.writing_mode, 'closeEvent'):
            self.writing_mode.closeEvent(event)
        
        if event.isAccepted():
            super().closeEvent(event)

if __name__ == "__main__":
    from runtime_profile import instance_key, pid_file_path
    app = SingleApplication(instance_key("Antigravity_AI_Writer_App"), sys.argv)
    
    if getattr(sys, 'frozen', False):
        base_path = sys._MEIPASS
    else:
        base_path = os.path.dirname(os.path.abspath(__file__))
    
    icon_path = os.path.join(base_path, "app_icon.ico")
    if os.path.exists(icon_path):
        app.setWindowIcon(QIcon(icon_path))
        
    style_path = os.path.join(base_path, "style.qss")
    try:
        with open(style_path, "r", encoding="utf-8") as f:
            app.setStyleSheet(f.read())
    except Exception as e:
        print(f"스타일시트 로드 실패: {e}")
    
    font = get_saved_font()
    app.setFont(font)
    
    if app.is_running():
        print("프로그램이 이미 실행 중입니다. 기존 창을 최상단으로 띄웁니다.")
        app.wake_up_server()
        sys.exit(0)

    pid_path = pid_file_path()
    if pid_path:
        from pathlib import Path

        pid_file = Path(pid_path)
        pid_file.parent.mkdir(parents=True, exist_ok=True)
        pid_file.write_text(str(os.getpid()), encoding="ascii")

        def remove_pid_file():
            try:
                if pid_file.exists() and pid_file.read_text(encoding="ascii").strip() == str(os.getpid()):
                    pid_file.unlink()
            except OSError:
                pass

        app.aboutToQuit.connect(remove_pid_file)
        
    window = MainWindow()
    app.set_activation_window(window)
    window.show()
    SmartTextEdit.force_startup_korean_for_widget(window)
    
    sys.exit(app.exec())
