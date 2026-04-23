#!/usr/bin/env python3
"""
Session-DBus: org.markup.vite.DevServer.PullFromPipeline(build_id: s) -> s
Führt git pull + npm im Workspace aus, schreibt pull_ack_<build_id> im STATE_DIR
(Hot-Reload-Bestätigung für Jenkins), dann Rückgabestring.
"""
from __future__ import annotations

import os
import subprocess
import sys

BUS = "org.markup.vite.DevServer"
OBJ = "/org/markup/vite/DevServer"
IFACE = "org.markup.vite.DevServer"


def _log(msg: str) -> None:
    path = os.environ.get("MARKUP_VITE_LOG", "")
    line = f"[dbus-service {__import__('datetime').datetime.now().isoformat()}] {msg}\n"
    if path and path not in ("/dev/stdout", "/dev/stderr"):
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass
    sys.stderr.write(line)


def _state_dir() -> str:
    return os.environ.get("MARKUP_VITE_STATE_DIR", "").strip()


def _write_ack(build_id: str, ok: bool, detail: str) -> None:
    sd = _state_dir()
    if not sd or not build_id or build_id == "0":
        return
    try:
        path = os.path.join(sd, f"pull_ack_{build_id}")
        prefix = "HOT_RELOAD_OK" if ok else "HOT_RELOAD_ERR"
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"{prefix} {detail}\n")
    except OSError as e:
        _log(f"ack schreiben fehlgeschlagen: {e}")


def run_git_pull() -> tuple[bool, str]:
    """(success, message für Ack / Dbus-Out)"""
    ws = os.environ.get("MARKUP_VITE_WORKSPACE", "").strip()
    if not ws or not os.path.isdir(ws):
        return False, "err: MARKUP_VITE_WORKSPACE ungültig"
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    r0 = subprocess.run(
        ["git", "fetch", "--all", "--prune"],
        cwd=ws,
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )
    if r0.returncode != 0:
        _log(f"git fetch: {r0.stderr or r0.stdout}")
    r = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=ws,
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    if r.returncode != 0:
        return False, f"err: git rev-parse: {r.stderr or r.stdout}"
    branch = (r.stdout or "").strip()
    r2 = subprocess.run(
        ["git", "pull", "--ff-only", "origin", branch],
        cwd=ws,
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
    )
    if r2.returncode != 0:
        _log(f"git pull: {r2.stderr or r2.stdout}")
        return False, f"err: git pull: {(r2.stderr or r2.stdout)[:500]}"
    r3 = subprocess.run(
        ["npm", "install", "--no-audit", "--no-fund"],
        cwd=ws,
        capture_output=True,
        text=True,
        env=env,
        timeout=600,
    )
    if r3.returncode != 0:
        return False, f"err: npm install rc={r3.returncode} {r3.stderr or ''}"
    return True, "git+npm (Vite HMR)"


def main() -> None:
    try:
        import dbus
        import dbus.service
    except ImportError as e:
        print(f"python3-dbus fehlt: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        from gi.repository import GLib
    except ImportError as e:
        print(f"python3-gi fehlt: {e}", file=sys.stderr)
        sys.exit(1)
    from dbus.mainloop.glib import DBusGMainLoop  # type: ignore

    DBusGMainLoop(set_as_default=True)

    class Service(dbus.service.Object):  # type: ignore[name-defined, misc]
        @dbus.service.method(IFACE, in_signature="s", out_signature="s")
        def PullFromPipeline(self, build_id: str) -> str:
            _log(f"PullFromPipeline build_id={build_id!r}")
            ok, msg = run_git_pull()
            _write_ack(str(build_id or "0"), ok, msg)
            if ok:
                return f"ok: {msg}"
            return f"err: {msg}"

    bus = dbus.SessionBus()
    dbus.service.BusName(BUS, bus)  # type: ignore[func-returns-value]
    Service(bus, OBJ)

    _log(f"DBus-Name {BUS} registriert, PullFromPipeline(s) aktiv")
    GLib.MainLoop().run()  # type: ignore[attr-defined]


if __name__ == "__main__":
    main()
