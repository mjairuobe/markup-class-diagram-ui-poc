#!/usr/bin/env python3
"""
Eigener Session-DBus: org.markup.vite.DevServer, Pfad /org/markup/vite/DevServer,
Methode PullFromPipeline() -> str.

Voraussetzung: DBUS_SESSION_BUS_ADDRESS gesetzt (z. B. per dbus-launch im Daemon),
Pakete: python3-dbus, python3-gi (gir1.2-glib-2.0).

Umgebung: MARKUP_VITE_WORKSPACE (Repo-Root), optional MARKUP_VITE_LOG.
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


def run_git_pull() -> str:
    ws = os.environ.get("MARKUP_VITE_WORKSPACE", "").strip()
    if not ws or not os.path.isdir(ws):
        return "err: MARKUP_VITE_WORKSPACE ungültig"
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
        return f"err: git rev-parse: {r.stderr or r.stdout}"
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
        _log(f"git pull fehlgeschlagen: {r2.stderr or r2.stdout}")
    r3 = subprocess.run(
        ["npm", "install", "--no-audit", "--no-fund"],
        cwd=ws,
        capture_output=True,
        text=True,
        env=env,
        timeout=600,
    )
    if r3.returncode != 0:
        return f"warn: npm install rc={r3.returncode} {r3.stderr or ''}"
    return "ok: PullFromPipeline ausgeführt (git+npm)"


def main() -> None:
    try:
        import dbus
        import dbus.mainloop.glib
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
        @dbus.service.method(IFACE, in_signature="", out_signature="s")
        def PullFromPipeline(self) -> str:
            _log("Methode PullFromPipeline() aufgerufen")
            return run_git_pull()

    bus = dbus.SessionBus()
    dbus.service.BusName(BUS, bus)  # type: ignore[func-returns-value]
    Service(bus, OBJ)

    _log(f"DBus-Name {BUS} registriert, Objekt {OBJ}")
    GLib.MainLoop().run()  # type: ignore[attr-defined]


if __name__ == "__main__":
    main()
