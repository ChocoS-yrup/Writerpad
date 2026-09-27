#!/usr/bin/env python3
"""Two-session regression in the disposable PostgreSQL CI database only."""

import os
import subprocess
import sys
import time


def query(sql, *, env=None):
    return subprocess.run(
        ["psql", "-XAtq", "-v", "ON_ERROR_STOP=1", "-c", sql],
        env=env, capture_output=True, text=True, check=True, timeout=15,
    ).stdout.strip()


def main():
    # No --linked mode, service discovery or arbitrary remote connection string.
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("PGHOST") != "localhost"
            or os.environ.get("PGDATABASE") != "writerpad_stage7"):
        raise SystemExit("This fixture is restricted to the disposable server-contract CI database")

    preparation = "--transition-prepare" in sys.argv
    transition = "--transition" in sys.argv or preparation
    suffix = "921" if preparation else "911" if transition else "901"
    project = f"08000000-0000-4000-8000-000000000{suffix}"
    owner = f"98000000-0000-4000-8000-000000000{suffix}"
    editor = f"98000000-0000-4000-8000-{int(suffix)+1:012d}"
    caller = owner if transition else editor
    rpc = "prepare_project_sync_transition" if preparation else "get_project_sync_transition_plan" if transition else "validate_project_sync_migration"
    argument = f"'{{\"project_id\":\"{project}\"}}'::jsonb" if preparation else f"'{project}'"
    revoke = (f"update public.projects set owner_id='{editor}' where project_id='{project}';"
              if transition else f"delete from public.project_members where project_id='{project}' and user_id='{editor}';")
    query(f"""
        insert into auth.users(id) values ('{owner}'), ('{editor}');
        insert into public.projects(project_id, owner_id, name)
        values ('{project}', '{owner}', 'CI validator lock authorization');
        insert into public.project_members(project_id, user_id, role)
        values ('{project}', '{editor}', 'editor');
    """)
    blocker = subprocess.Popen(
        ["psql", "-XAtq", "-v", "ON_ERROR_STOP=1"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    validator = None
    try:
        # Transaction A serializes the project; its membership revocation only
        # becomes visible when the waiting validator is allowed to acquire it.
        blocker.stdin.write(f"""
            begin;
            set local statement_timeout = '10s';
            select pg_advisory_xact_lock(hashtextextended('project:{project}', 0));
            {revoke}
            select 'LOCK_READY';
        """)
        blocker.stdin.flush()
        while blocker.stdout.readline().strip() != "LOCK_READY":
            if blocker.poll() is not None:
                raise AssertionError("lock holder exited before readiness")

        validator = subprocess.Popen(
            ["psql", "-XAtq", "-v", "ON_ERROR_STOP=1", "-c", f"""
                set statement_timeout = '10s';
                select set_config('request.jwt.claim.sub', '{caller}', false);
                set role authenticated;
                select public.{rpc}({argument});
            """],
            env={**os.environ, "PGAPPNAME": "writerpad-migration-lock-regression"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        deadline = time.monotonic() + 8
        while query("""
            select exists(select 1 from pg_stat_activity
              where application_name = 'writerpad-migration-lock-regression'
                and wait_event_type = 'Lock' and wait_event = 'advisory')
        """) != "t":
            if validator.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError("validator did not wait on the project advisory lock")
            time.sleep(0.1)

        blocker.stdin.write("commit;\n\\q\n")
        blocker.stdin.flush()
        blocker.wait(timeout=10)
        output, error = validator.communicate(timeout=12)
        if blocker.returncode != 0 or validator.returncode == 0 or "FORBIDDEN" not in error:
            raise AssertionError(f"revoked editor was not rejected after lock wait: {output} {error}")
        if query(f"select count(*) from public.project_sync_settings where project_id = '{project}'") != "0":
            raise AssertionError("validator changed project mode")
        print(f"project_sync_migration_lock_passed: {rpc} rechecks revoked authorization")
    finally:
        for process in (validator, blocker):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
