"""Launch two isolated Windows app profiles against one Supabase v2 project."""

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent
TEST_HOME = Path(
    os.environ.get("LOCALAPPDATA", str(Path.home()))
) / "AntigravityWriter" / "dual-v2-test"
CURRENT_FILE = TEST_HOME / "current.json"
RENAME_TEST_RELATIVE_PATH = Path("메인") / "메모장" / "이름변경동시수정.txt"
RENAME_TEST_CONTENT = (
    "이름 변경 테스트\n"
    "A가 파일 이름을 바꿉니다.\n"
    "B가 이 줄을 수정합니다.\n"
)


def _write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def _read_manifest():
    if not CURRENT_FILE.exists():
        raise SystemExit("먼저 `python windows_v2_dual_test.py new`를 실행해주세요.")
    return json.loads(CURRENT_FILE.read_text(encoding="utf-8"))


def _profile_dir(manifest, profile):
    return Path(manifest["run_dir"]) / profile


def _pid_file(manifest, profile):
    return _profile_dir(manifest, profile) / "app.pid"


def _read_pid(path):
    try:
        return int(path.read_text(encoding="ascii").strip())
    except (FileNotFoundError, OSError, TypeError, ValueError):
        return None


def _pid_is_running(pid):
    if not pid:
        return False
    if os.name == "nt":
        import ctypes

        process_query_limited_information = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(
            process_query_limited_information, False, int(pid)
        )
        if not handle:
            return False
        exit_code = ctypes.c_ulong()
        queried = ctypes.windll.kernel32.GetExitCodeProcess(
            handle, ctypes.byref(exit_code)
        )
        ctypes.windll.kernel32.CloseHandle(handle)
        return bool(queried and exit_code.value == 259)  # STILL_ACTIVE
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def _running_pid(manifest, profile):
    candidates = (
        _read_pid(_pid_file(manifest, profile)),
        manifest.get("pids", {}).get(profile),
    )
    for pid in candidates:
        if _pid_is_running(pid):
            return pid
    return None


def _seed_rename_document(profile_dir, project_name):
    writing_root = (
        Path(profile_dir) / "root" / "작품목록" / project_name / "집필모드"
    )
    target = writing_root / RENAME_TEST_RELATIVE_PATH
    if target.exists():
        return target, False
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(RENAME_TEST_CONTENT, encoding="utf-8")
    return target, True


def _make_profile(run_dir, profile, project_name):
    profile_dir = run_dir / profile
    root_dir = profile_dir / "root"
    writing_root = root_dir / "작품목록" / project_name / "집필모드"
    manuscript = writing_root / "메인" / "원고" / "충돌테스트.txt"
    manuscript.parent.mkdir(parents=True, exist_ok=True)
    manuscript.write_text(
        "공통 제목\nA에서 바꿀 줄\n양쪽에서 겹쳐 바꿀 줄\nB에서 바꿀 줄\n",
        encoding="utf-8",
    )
    _seed_rename_document(profile_dir, project_name)
    _write_json(root_dir / "config.json", {
        "last_project": project_name,
        "project_order": [project_name],
        "minimize_to_tray": False,
    })
    (profile_dir / "appdata").mkdir(parents=True, exist_ok=True)
    return profile_dir


def new_run(_args):
    TEST_HOME.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    run_dir = TEST_HOME / run_id
    project_name = f"V2 충돌 테스트 {run_id}"
    for profile in ("A", "B"):
        _make_profile(run_dir, profile, project_name)
    manifest = {
        "run_id": run_id,
        "run_dir": str(run_dir),
        "project_id": str(uuid.uuid4()),
        "project_name": project_name,
        "pids": {},
    }
    _write_json(run_dir / "manifest.json", manifest)
    _write_json(CURRENT_FILE, manifest)
    print(f"새 테스트 세트: {project_name}")
    print(f"project_id: {manifest['project_id']}")
    launch_profiles(manifest, ("A", "B"))


def _environment(manifest, profile):
    profile_dir = _profile_dir(manifest, profile)
    env = os.environ.copy()
    env.update({
        "ANTIGRAVITY_PROFILE": f"V2-{profile}",
        "ANTIGRAVITY_ROOT_DIR": str(profile_dir / "root"),
        "ANTIGRAVITY_APP_DATA_DIR": str(profile_dir / "appdata"),
        "ANTIGRAVITY_INSTANCE_KEY": f"Antigravity_V2_Test_{manifest['run_id']}_{profile}",
        "ANTIGRAVITY_PID_FILE": str(profile_dir / "app.pid"),
        "ANTIGRAVITY_SYNC_PROJECT_ID": manifest["project_id"],
        "ANTIGRAVITY_AUTO_PROJECT": manifest["project_name"],
        "ANTIGRAVITY_SYNC_OFFLINE_FILE": str(profile_dir / "OFFLINE"),
        "PYTHONFAULTHANDLER": "1",
        "PYTHONUNBUFFERED": "1",
    })
    return env


def launch_profiles(manifest, profiles):
    creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    for profile in profiles:
        running_pid = _running_pid(manifest, profile)
        if running_pid:
            manifest.setdefault("pids", {})[profile] = running_pid
            print(f"{profile}: 이미 실행 중입니다. PID {running_pid}")
            continue
        profile_dir = _profile_dir(manifest, profile)
        launch_stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        log_path = profile_dir / f"app-{launch_stamp}.log"
        with log_path.open("a", encoding="utf-8", buffering=1) as log_file:
            log_file.write(f"\n=== launch {datetime.now().isoformat(timespec='seconds')} ===\n")
            process = subprocess.Popen(
                [sys.executable, str(REPO_ROOT / "main.py")],
                cwd=str(REPO_ROOT),
                env=_environment(manifest, profile),
                creationflags=creationflags,
                stdout=log_file,
                stderr=subprocess.STDOUT,
            )
        time.sleep(0.35)
        if process.poll() is not None:
            print(f"{profile}: 실행 직후 종료됐습니다. {log_path.name}을 확인해주세요.")
            continue
        manifest.setdefault("pids", {})[profile] = process.pid
        manifest.setdefault("logs", {})[profile] = str(log_path)
        print(f"{profile} 실행됨: PID {process.pid}")
    _write_json(Path(manifest["run_dir"]) / "manifest.json", manifest)
    _write_json(CURRENT_FILE, manifest)


def launch(args):
    manifest = _read_manifest()
    profiles = ("A", "B") if args.target == "both" else (args.target.upper(),)
    launch_profiles(manifest, profiles)


def prepare_rename(_args):
    manifest = _read_manifest()
    for profile in ("A", "B"):
        path, created = _seed_rename_document(
            _profile_dir(manifest, profile), manifest["project_name"]
        )
        state = "새로 생성됨" if created else "이미 있음 - 기존 내용 유지"
        print(f"{profile}: {state} / {path}")
    print("준비 완료: A/B를 다시 실행하면 메모장에 이름 변경 테스트 문서가 보입니다.")


def set_offline(args, offline):
    manifest = _read_manifest()
    profiles = ("A", "B") if args.target == "both" else (args.target.upper(),)
    for profile in profiles:
        marker = _profile_dir(manifest, profile) / "OFFLINE"
        if offline:
            marker.write_text("offline", encoding="ascii")
            print(f"{profile}: 오프라인 켜짐")
        else:
            marker.unlink(missing_ok=True)
            print(f"{profile}: 온라인 복구됨 - 앱의 저장 상태 버튼을 눌러 재시도하세요.")


def kill(args):
    manifest = _read_manifest()
    profiles = ("A", "B") if args.target == "both" else (args.target.upper(),)
    for profile in profiles:
        pid = _running_pid(manifest, profile)
        if not pid:
            _pid_file(manifest, profile).unlink(missing_ok=True)
            manifest.setdefault("pids", {}).pop(profile, None)
            print(f"{profile}: 이미 종료되어 있습니다.")
            continue
        completed = subprocess.run(
            ["taskkill", "/PID", str(pid), "/F"], capture_output=True, text=True
        )
        message = completed.stdout.strip() or completed.stderr.strip()
        print(f"{profile}: {message}")
        if completed.returncode == 0:
            _pid_file(manifest, profile).unlink(missing_ok=True)
            manifest.setdefault("pids", {}).pop(profile, None)
    _write_json(Path(manifest["run_dir"]) / "manifest.json", manifest)
    _write_json(CURRENT_FILE, manifest)


def _db_status(db_path):
    if not db_path.exists():
        return "큐 DB 없음"

    def read_counts(uri):
        with sqlite3.connect(uri, uri=True) as connection:
            rows = connection.execute(
                "SELECT status, count(*) FROM sync_operations GROUP BY status ORDER BY status"
            ).fetchall()
            documents = connection.execute(
                """
                SELECT count(*), max(revision)
                FROM sync_documents
                WHERE local_path NOT LIKE '__antigravity__/%'
                """
            ).fetchone()
        return rows, documents

    try:
        uri = db_path.resolve().as_uri() + "?mode=ro"
        try:
            rows, documents = read_counts(uri)
        except sqlite3.OperationalError:
            # Read-only diagnostic environments cannot create SQLite lock files.
            rows, documents = read_counts(uri + "&immutable=1")
        state = ", ".join(f"{name}={count}" for name, count in rows) or "작업 없음"
        return f"문서={documents[0]}, 최대 revision={documents[1] or 0}, {state}"
    except sqlite3.Error as error:
        return f"DB 읽기 실패: {error}"


def status(_args):
    manifest = _read_manifest()
    print(f"테스트: {manifest['project_name']}")
    print(f"project_id: {manifest['project_id']}")
    for profile in ("A", "B"):
        profile_dir = _profile_dir(manifest, profile)
        offline = (profile_dir / "OFFLINE").exists()
        db_path = profile_dir / "appdata" / "sync_v2.sqlite3"
        running = _running_pid(manifest, profile)
        process_state = f"실행 중(PID {running})" if running else "종료됨"
        print(
            f"{profile}: {process_state} / "
            f"{'오프라인' if offline else '온라인'} / {_db_status(db_path)}"
        )


def paths(_args):
    manifest = _read_manifest()
    print(manifest["run_dir"])
    for profile in ("A", "B"):
        print(f"{profile}: {_profile_dir(manifest, profile)}")


def build_parser():
    parser = argparse.ArgumentParser(description="Supabase v2 Windows 두 인스턴스 테스트")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("new", help="격리된 A/B 테스트 세트를 만들고 둘 다 실행")
    sub.add_parser(
        "prepare-rename",
        help="현재 A/B 테스트의 메모장에 이름 변경용 공용 문서 준비",
    )
    for command, help_text in (
        ("launch", "종료된 테스트 인스턴스 다시 실행"),
        ("offline", "강제 오프라인 전환"),
        ("online", "온라인 복구"),
        ("kill", "프로세스 강제 종료"),
    ):
        child = sub.add_parser(command, help=help_text)
        child.add_argument("target", choices=("A", "B", "both"))
    sub.add_parser("status", help="A/B SQLite 큐 상태 확인")
    sub.add_parser("paths", help="격리된 테스트 폴더 표시")
    return parser


def main():
    args = build_parser().parse_args()
    if args.command == "new":
        new_run(args)
    elif args.command == "prepare-rename":
        prepare_rename(args)
    elif args.command == "launch":
        launch(args)
    elif args.command == "offline":
        set_offline(args, True)
    elif args.command == "online":
        set_offline(args, False)
    elif args.command == "kill":
        kill(args)
    elif args.command == "status":
        status(args)
    elif args.command == "paths":
        paths(args)


if __name__ == "__main__":
    main()
