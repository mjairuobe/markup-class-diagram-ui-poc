#!/usr/bin/env python3
"""
User-Session-DBus (loginctl linger / systemd --user) oder privater dbus-launch:
org.markup.vite.DevServer.PullFromPipeline(build_id: s) -> s
Führt git pull + npm im Workspace aus, schreibt pull_ack_<build_id> im STATE_DIR
(Hot-Reload-Bestätigung für Jenkins), dann Rückgabestring.

Während des Pulls: Signal PipelineOutput(ss) build_id, Zeile — für Jenkins-Konsole.
Laufend: neue Zeilen aus MARKUP_VITE_LOG (Vite/npm) → PipelineOutput("vite-log", Zeile)
für Live-Ausgabe in der Pipeline (jenkins-dbus-pipeline-output-tee.py --vite-log).
"""
from __future__ import annotations

import os
import select
import subprocess
import sys
import threading
import time
from collections.abc import Callable

BUS = "org.markup.vite.DevServer"
OBJ = "/org/markup/vite/DevServer"
IFACE = "org.markup.vite.DevServer"
_MAX_LINE = 16384
_DEFAULT_VITE_LOG = "/var/lib/jenkins/workspace/vitedevserverlog.txt"
# Jenkins pipeline-ctl: Tee hört auf dieselbe build_id (siehe jenkins-dbus-pipeline-output-tee.py).
VITE_LOG_SIGNAL_BUILD_ID = "vite-log"


def _log(msg: str) -> None:
    path = (os.environ.get("MARKUP_VITE_LOG") or "").strip() or _DEFAULT_VITE_LOG
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


def _vite_log_path() -> str:
    p = (os.environ.get("MARKUP_VITE_LOG") or "").strip()
    if p:
        return p
    sd = _state_dir()
    if sd:
        return os.path.join(sd, "vite-devserver.log")
    return ""


def start_vite_log_follower(queue_line: Callable[[str, str], None]) -> None:
    """Liest vite-devserver.log inkrementell und sendet Zeilen per PipelineOutput (IPC für Jenkins)."""

    def tail_loop() -> None:
        log_path = _vite_log_path()
        last_pos = 0
        while True:
            try:
                if not log_path:
                    log_path = _vite_log_path()
                if log_path and os.path.isfile(log_path):
                    with open(log_path, encoding="utf-8", errors="replace") as f:
                        st = os.stat(log_path)
                        if st.st_size < last_pos:
                            last_pos = 0
                        f.seek(last_pos)
                        while True:
                            raw = f.readline()
                            if not raw:
                                break
                            line = raw.rstrip("\r\n")
                            if line:
                                queue_line(VITE_LOG_SIGNAL_BUILD_ID, line)
                        last_pos = f.tell()
            except OSError:
                pass
            time.sleep(0.45)

    threading.Thread(target=tail_loop, daemon=True).start()


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


def _truncate_line(s: str) -> str:
    if len(s) <= _MAX_LINE:
        return s
    return s[: _MAX_LINE - 3] + "..."


def _run_process_streaming(
    cmd: list[str],
    cwd: str,
    env: dict[str, str],
    timeout_sec: float,
    emit: Callable[[str], None],
    label: str,
) -> int:
    """Führt cmd aus, merged stderr nach stdout, emit pro Zeile; Rückgabe exit code."""
    emit(f"[{label}] $ {' '.join(cmd)}")
    deadline = time.monotonic() + timeout_sec
    p = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    if not p.stdout:
        return -1
    fd = p.stdout.fileno()
    buf = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            emit(f"[{label}] TIMEOUT nach {timeout_sec:.0f}s — beende Prozess")
            p.kill()
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
            return -1
        r, _, _ = select.select([fd], [], [], min(0.5, max(0.05, remaining)))
        if r:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("utf-8", errors="replace").rstrip("\r")
                if line:
                    emit(f"[{label}] {line}")
        elif p.poll() is not None:
            break
    if buf:
        tail = buf.decode("utf-8", errors="replace").rstrip("\n\r")
        if tail:
            emit(f"[{label}] {tail}")
    p.stdout.close()
    try:
        return int(p.wait(timeout=120))
    except subprocess.TimeoutExpired:
        p.kill()
        return -1


def run_git_pull_streaming(
    build_id: str,
    emit: Callable[[str], None],
) -> tuple[bool, str]:
    ws = os.environ.get("MARKUP_VITE_WORKSPACE", "").strip()
    if not ws or not os.path.isdir(ws):
        emit("[pull] err: MARKUP_VITE_WORKSPACE ungültig")
        return False, "err: MARKUP_VITE_WORKSPACE ungültig"
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    rc = _run_process_streaming(
        ["git", "fetch", "--all", "--prune"],
        ws,
        env,
        120.0,
        emit,
        "git fetch",
    )
    if rc != 0:
        msg = f"git fetch exit {rc}"
        _log(msg)
        return False, f"err: {msg}"
    br = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=ws,
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    if br.returncode != 0:
        emit(f"[git branch] err: {br.stderr or br.stdout}")
        return False, f"err: git rev-parse: {br.stderr or br.stdout}"
    branch = (br.stdout or "").strip()
    emit(f"[pull] branch={branch!r}")
    rc = _run_process_streaming(
        ["git", "pull", "--ff-only", "origin", branch],
        ws,
        env,
        300.0,
        emit,
        "git pull",
    )
    if rc != 0:
        msg = f"git pull exit {rc}"
        _log(msg)
        return False, f"err: {msg}"
    rc = _run_process_streaming(
        ["npm", "install", "--no-audit", "--no-fund"],
        ws,
        env,
        600.0,
        emit,
        "npm install",
    )
    if rc != 0:
        msg = f"npm install exit {rc}"
        return False, f"err: {msg}"
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
        @dbus.service.signal(IFACE, signature="ss")
        def PipelineOutput(self, build_id: str, line: str) -> None:  # noqa: N802
            pass

        def _emit_line(self, build_id: str, line: str) -> bool:
            try:
                self.PipelineOutput(build_id, _truncate_line(line))
            except Exception as e:  # noqa: BLE001
                _log(f"PipelineOutput signal: {e}")
            return False

        def _queue_line(self, build_id: str, line: str) -> None:
            GLib.idle_add(lambda: self._emit_line(build_id, line))  # type: ignore[attr-defined]

        @dbus.service.method(IFACE, in_signature="s", out_signature="s")
        def PullFromPipeline(self, build_id: str) -> str:
            bid = str(build_id or "0")
            _log(f"PullFromPipeline build_id={bid!r}")

            done = threading.Event()
            outcome: list[tuple[bool, str] | None] = [None]
            err_box: list[BaseException | None] = [None]

            def worker() -> None:
                try:

                    def emit(line: str) -> None:
                        self._queue_line(bid, line)

                    emit(f"[pull] start build_id={bid} workspace={os.environ.get('MARKUP_VITE_WORKSPACE', '')}")
                    ok, msg = run_git_pull_streaming(bid, emit)
                    outcome[0] = (ok, msg)
                    emit(f"[pull] fertig ok={ok} {msg[:200]}")
                except BaseException as e:  # noqa: BLE001
                    err_box[0] = e
                finally:
                    done.set()

            threading.Thread(target=worker, daemon=True).start()
            ctx = GLib.MainContext.default()
            while not done.is_set():
                while ctx.pending():
                    ctx.iteration(may_block=False)
                done.wait(0.05)

            if err_box[0] is not None:
                e = err_box[0]
                _log(f"PullFromPipeline exception: {e}")
                _write_ack(bid, False, str(e))
                return f"err: {e}"
            if outcome[0] is None:
                _write_ack(bid, False, "internal: kein Ergebnis")
                return "err: internal"
            ok, msg = outcome[0]
            _write_ack(bid, ok, msg)
            if ok:
                return f"ok: {msg}"
            return f"err: {msg}"

    bus = dbus.SessionBus()
    dbus.service.BusName(BUS, bus)  # type: ignore[func-returns-value]
    svc = Service(bus, OBJ)
    start_vite_log_follower(svc._queue_line)  # type: ignore[attr-defined]

    _log(
        f"DBus-Name {BUS} registriert; PullFromPipeline(s); "
        f"Vite-Log-Signal build_id={VITE_LOG_SIGNAL_BUILD_ID!r}"
    )
    GLib.MainLoop().run()  # type: ignore[attr-defined]


if __name__ == "__main__":
    main()
