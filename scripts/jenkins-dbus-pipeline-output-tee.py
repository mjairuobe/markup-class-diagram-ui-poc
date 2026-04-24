#!/usr/bin/env python3
"""Empfängt PipelineOutput-Signale vom DevServer-DBus und schreibt Zeilen auf stdout (Jenkins)."""
from __future__ import annotations

import os
import signal
import sys

IFACE = "org.markup.vite.DevServer"
OBJ = "/org/markup/vite/DevServer"
SIGNAL = "PipelineOutput"


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: jenkins-dbus-pipeline-output-tee.py <BUILD_NUMBER>", file=sys.stderr)
        sys.exit(2)
    build_id = sys.argv[1].strip()

    uid = os.getuid()
    xdg = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{uid}"
    os.environ.setdefault("XDG_RUNTIME_DIR", xdg)
    bus_path = os.path.join(xdg, "bus")
    if os.path.exists(bus_path):
        os.environ.setdefault(
            "DBUS_SESSION_BUS_ADDRESS",
            f"unix:path={bus_path}",
        )

    try:
        import dbus
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
    loop = GLib.MainLoop()

    def on_signal(bid: str, line: str) -> None:
        if bid == build_id:
            print(line, flush=True)

    def quit_loop(*_args: object) -> None:
        loop.quit()

    signal.signal(signal.SIGTERM, quit_loop)
    signal.signal(signal.SIGINT, quit_loop)

    bus = dbus.SessionBus()
    bus.add_signal_receiver(
        on_signal,
        signal_name=SIGNAL,
        dbus_interface=IFACE,
        path=OBJ,
    )
    loop.run()


if __name__ == "__main__":
    main()
