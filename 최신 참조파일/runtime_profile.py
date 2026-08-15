import os


def profile_name():
    return os.environ.get("ANTIGRAVITY_PROFILE", "").strip()


def root_dir(default_root):
    override = os.environ.get("ANTIGRAVITY_ROOT_DIR", "").strip()
    return os.path.abspath(override) if override else os.path.abspath(default_root)


def app_data_dir():
    override = os.environ.get("ANTIGRAVITY_APP_DATA_DIR", "").strip()
    if override:
        return os.path.abspath(override)
    return os.path.join(
        os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
        "AntigravityWriter",
    )


def instance_key(default_key):
    return os.environ.get("ANTIGRAVITY_INSTANCE_KEY", "").strip() or default_key


def pid_file_path():
    return os.environ.get("ANTIGRAVITY_PID_FILE", "").strip()


def forced_project_id():
    return os.environ.get("ANTIGRAVITY_SYNC_PROJECT_ID", "").strip()


def offline_marker_path():
    return os.environ.get("ANTIGRAVITY_SYNC_OFFLINE_FILE", "").strip()


def is_forced_offline():
    marker = offline_marker_path()
    return bool(marker and os.path.exists(marker))
