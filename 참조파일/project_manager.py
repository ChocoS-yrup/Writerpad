import os
import sys
import json
from PyQt6.QtCore import QMutex, QMutexLocker

class ProjectManager:
    def __init__(self):
        self.mutex = QMutex()
        if getattr(sys, 'frozen', False):
            self.root_dir = os.path.dirname(sys.executable)
        else:
            self.root_dir = os.path.abspath(os.path.dirname(__file__))
        from runtime_profile import root_dir
        self.root_dir = root_dir(self.root_dir)
        self.config_path = os.path.join(self.root_dir, "config.json")
        self.workspace_dir = os.path.join(self.root_dir, "작품목록")
        
        self.current_project = None
        self.project_path = None
        self.project_settings_path = None
        self.session_cost = 0.0
        
        # 기본 전역 설정 로드
        self.global_config = self.load_global_config()
        
    def load_global_config(self):
        if not os.path.exists(self.config_path):
            default_config = {"last_project": ""}
            self.save_global_config(default_config)
            return default_config
            
        try:
            with open(self.config_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {"last_project": ""}
            
    def save_global_config(self, config=None):
        if config is not None:
            self.global_config = config
        with open(self.config_path, "w", encoding="utf-8") as f:
            json.dump(self.global_config, f, ensure_ascii=False, indent=4)
            
    def get_all_projects(self):
        os.makedirs(self.workspace_dir, exist_ok=True)
        # 실제 존재하는 폴더 목록
        from project_paths import IMPORT_MARKER_FILENAME
        existing_projects = []
        for name in os.listdir(self.workspace_dir):
            project_path = os.path.join(self.workspace_dir, name)
            if not os.path.isdir(project_path):
                continue
            marker_path = os.path.join(project_path, IMPORT_MARKER_FILENAME)
            if os.path.exists(marker_path):
                try:
                    with open(marker_path, "r", encoding="utf-8") as marker_file:
                        marker = json.load(marker_file)
                    if marker.get("state") != "complete":
                        continue
                except (AttributeError, json.JSONDecodeError, OSError):
                    continue
            existing_projects.append(name)
        
        # 저장된 순서 가져오기
        saved_order = self.global_config.get("project_order", [])
        
        # 저장된 순서 중 실제로 존재하는 것만 유지
        ordered_projects = [p for p in saved_order if p in existing_projects]
        
        # 새로 생성되었거나 순서가 없는 프로젝트를 뒤에 추가
        for p in existing_projects:
            if p not in ordered_projects:
                ordered_projects.append(p)
                
        # 변경사항이 있다면 저장
        if len(ordered_projects) != len(saved_order):
            self.global_config["project_order"] = ordered_projects
            self.save_global_config()
            
        return ordered_projects
        
    def save_project_order(self, ordered_projects):
        self.global_config["project_order"] = ordered_projects
        self.save_global_config()
        
    def rename_project(self, old_name, new_name):
        if not old_name or not new_name or old_name == new_name:
            return False, "유효하지 않은 이름입니다."
            
        old_path = os.path.join(self.workspace_dir, old_name)
        new_path = os.path.join(self.workspace_dir, new_name)
        
        if not os.path.exists(old_path):
            return False, "기존 프로젝트를 찾을 수 없습니다."
        if os.path.exists(new_path):
            return False, "이미 존재하는 프로젝트 이름입니다."
            
        try:
            os.rename(old_path, new_path)
            
            # config.json 업데이트
            if "project_order" in self.global_config:
                order = self.global_config["project_order"]
                if old_name in order:
                    idx = order.index(old_name)
                    order[idx] = new_name
            
            if self.global_config.get("last_project") == old_name:
                self.global_config["last_project"] = new_name
                
            self.save_global_config()
            return True, ""
        except Exception as e:
            return False, f"이름 변경 실패: {e}"

    def delete_project(self, project_name):
        if not project_name:
            return False, "프로젝트 이름이 비어있습니다."
            
        target_path = os.path.join(self.workspace_dir, project_name)
        if not os.path.exists(target_path):
            return False, "프로젝트를 찾을 수 없습니다."
            
        try:
            import shutil
            shutil.rmtree(target_path)
            
            # config.json 업데이트
            if "project_order" in self.global_config:
                order = self.global_config["project_order"]
                if project_name in order:
                    order.remove(project_name)
                    
            if self.global_config.get("last_project") == project_name:
                self.global_config["last_project"] = ""
                
            self.save_global_config()
            return True, ""
        except Exception as e:
            return False, f"삭제 실패: {e}"
        
    def set_current_project(self, project_name):
        self.current_project = project_name
        self.project_path = os.path.join(self.workspace_dir, project_name)
        self.project_settings_path = os.path.join(self.project_path, "설정.json")
        
        # 폴더 트리 생성
        dirs = [
            "메인/요약",
            "메인/초안",
            "메인/평가",
            "메인/완성본",
            "백업/자동저장",
            "백업/전환직전",
            "백업/충돌",
            "AI/초안",
            "AI/완성본",
            "AI/평가",
            "AI/요약"
        ]
        for d in dirs:
            os.makedirs(os.path.join(self.project_path, d), exist_ok=True)
            
        self.global_config["last_project"] = project_name
        self.save_global_config()
        
    def save_ai_response(self, step_name, chapter_num, content):
        if not getattr(self, 'project_path', None):
            return
            
        import datetime
        now = datetime.datetime.now()
        date_str = now.strftime("%Y%m%d_%H%M%S")
        
        if step_name not in ["초안", "완성본", "평가", "요약"]:
            step_name = "평가"
            
        ai_dir = os.path.join(self.project_path, "AI", step_name)
        os.makedirs(ai_dir, exist_ok=True)
        
        file_name = f"{chapter_num:03d}화_{date_str}.md"
        file_path = os.path.join(ai_dir, file_name)
        
        try:
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception as e:
            print(f"AI response save error: {e}")

    def get_project_setting(self, key, default=None):
        if not self.project_settings_path or not os.path.exists(self.project_settings_path):
            return default
            
        try:
            with open(self.project_settings_path, "r", encoding="utf-8") as f:
                settings = json.load(f)
                return settings.get(key, default)
        except:
            return default
            
    def set_project_setting(self, key, value):
        if not self.project_settings_path:
            return
            
        settings = {}
        if os.path.exists(self.project_settings_path):
            try:
                with open(self.project_settings_path, "r", encoding="utf-8") as f:
                    settings = json.load(f)
            except:
                pass
                
        settings[key] = value
        with open(self.project_settings_path, "w", encoding="utf-8") as f:
            json.dump(settings, f, ensure_ascii=False, indent=4)
            
    def get_text_file_path(self, step_name, chapter, is_backup=False, backup_type="자동저장", timestamp=""):
        if not self.project_path: return ""
        
        # 파일명 구성: n화.txt
        # 단, 백업인 경우 백업포맷을 따름
        file_name = f"{chapter:03d}화.txt"
        
        if is_backup:
            if backup_type == "전환직전":
                file_name = f"전환직전_{step_name}_{chapter:03d}화.txt"
            else:
                file_name = f"자동저장_{step_name}_{chapter:03d}화_{timestamp}.txt"
            return os.path.join(self.project_path, f"백업/{backup_type}", file_name)
        else:
            return os.path.join(self.project_path, f"메인/{step_name}", file_name)
            
    def save_chapter_text(self, step_name, chapter, text, is_backup=False, backup_type="자동저장", timestamp=""):
        path = self.get_text_file_path(step_name, chapter, is_backup, backup_type, timestamp)
        if path:
            locker = QMutexLocker(self.mutex)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
                
    def load_chapter_text(self, step_name, chapter):
        path = self.get_text_file_path(step_name, chapter)
        if path and os.path.exists(path):
            locker = QMutexLocker(self.mutex)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    return f.read()
            except:
                return ""
        return ""

    def search_all_chapters(self, keyword):
        results = []
        if not self.project_path or not keyword:
            return results
            
        steps = ["요약", "초안", "평가", "완성본"]
        for step in steps:
            step_dir = os.path.join(self.project_path, f"메인/{step}")
            if not os.path.exists(step_dir):
                continue
                
            for filename in os.listdir(step_dir):
                if filename.endswith("화.txt"):
                    try:
                        chapter = int(filename.replace("화.txt", ""))
                        path = os.path.join(step_dir, filename)
                        with open(path, "r", encoding="utf-8") as f:
                            text = f.read()
                            
                        idx = 0
                        while True:
                            idx = text.find(keyword, idx)
                            if idx == -1:
                                break
                            
                            start = max(0, idx - 15)
                            end = min(len(text), idx + len(keyword) + 15)
                            snippet = text[start:end].replace('\n', ' ')
                            if start > 0: snippet = "..." + snippet
                            if end < len(text): snippet = snippet + "..."
                            
                            results.append({
                                "step": step,
                                "chapter": chapter,
                                "snippet": snippet,
                                "index": idx
                            })
                            idx += len(keyword)
                    except:
                        pass
                        
        step_order = {"요약": 0, "초안": 1, "평가": 2, "완성본": 3}
        results.sort(key=lambda x: (x["chapter"], step_order.get(x["step"], 99)))
        return results

    # API 모델별 100만 토큰당 단가 (USD)
    API_PRICING = {
        "Gemini 3.1 Pro": {"input": 2.00, "output": 12.00},
        "Claude Opus 4.8": {"input": 5.00, "output": 25.00},
        "GPT-4o": {"input": 2.50, "output": 10.00},
        "GPT-5.6 Sol": {"input": 5.00, "output": 30.00},
        "GPT-5.6 Terra": {"input": 2.50, "output": 15.00},
        "GPT-5.6 Luna": {"input": 1.00, "output": 6.00},
    }

    def calculate_cost(self, model_name, input_tokens, output_tokens):
        """토큰 수량을 기반으로 비용을 USD로 계산합니다."""
        rates = self.API_PRICING.get(model_name)
        if not rates:
            # 계정에서 동적으로 발견한 모델은 가격표가 없으므로 다른 모델 단가를 추정 적용하지 않는다.
            return 0.0
        
        input_cost = (input_tokens / 1_000_000) * rates["input"]
        output_cost = (output_tokens / 1_000_000) * rates["output"]
        return round(input_cost + output_cost, 4)

    def log_api_cost(self, step_name, model_name, input_tokens, output_tokens):
        if not self.project_path:
            return
        
        cost = self.calculate_cost(model_name, input_tokens, output_tokens)
        self.session_cost += cost
        
        from datetime import datetime
        import json
        
        log_entry = {
            "timestamp": datetime.now().isoformat(),
            "step_name": step_name,
            "model_name": model_name,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost_usd": cost
        }
        
        cost_file = os.path.join(self.project_path, "cost_history.json")
        history = []
        if os.path.exists(cost_file):
            try:
                with open(cost_file, 'r', encoding='utf-8') as f:
                    history = json.load(f)
            except:
                pass
        
        history.append(log_entry)
        
        with open(cost_file, 'w', encoding='utf-8') as f:
            json.dump(history, f, ensure_ascii=False, indent=4)

    def get_aggregated_cost_history(self):
        """모든 프로젝트의 cost_history.json을 읽어 하나의 리스트로 병합하여 반환합니다."""
        all_history = []
        import os, json
        if not os.path.exists(self.workspace_dir):
            return all_history
            
        for proj_dir in os.listdir(self.workspace_dir):
            full_path = os.path.join(self.workspace_dir, proj_dir, "cost_history.json")
            if os.path.isfile(full_path):
                try:
                    with open(full_path, 'r', encoding='utf-8') as f:
                        data = json.load(f)
                        if isinstance(data, list):
                            all_history.extend(data)
                except Exception as e:
                    print(f"Failed to read {full_path}: {e}")
                    
        # timestamp 기준으로 오름차순 정렬
        all_history.sort(key=lambda x: x.get("timestamp", ""))
        return all_history
