#!/usr/bin/env python3
"""Empfängt PipelineOutput-Signale vom DevServer-DBus und schreibt Zeilen auf stdout (Jenkins).

Nutzt dbus-next (asyncio), ohne python3-gi.
"""
from __future__ import annotations

import asyncio
import os
import signal
import sys

try:
    from dbus_next import BusType
    from dbus_next.aio import MessageBus
except ImportError as _e:  # pragma: no cover
    _import_err = _e
else:
    _import_err = None

IFACE = "org.markup.vite.DevServer"
BUS = "org.markup.vite.DevServer"
OBJ = "/org/markup/vite/DevServer"


async def _run_tee(build_id: str, vite_log: bool) -> None:
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    intr = await bus.introspect(BUS, OBJ)
    proxy = bus.get_proxy_object(BUS, OBJ, intr)
    iface = proxy.get_interface(IFACE)

    vite_bid = "vite-log"

    def on_pipeline_output(bid: str, line: str) -> None:
        if bid == build_id or (vite_log and bid == vite_bid):
            prefix = "[vite] " if vite_log and bid == vite_bid else ""
            print(f"{prefix}{line}", flush=True)

    iface.on_pipeline_output(on_pipeline_output)

    loop = asyncio.get_running_loop()
    stop = asyncio.Event()

    def request_stop() -> None:
        stop.set()

    signal.signal(signal.SIGTERM, lambda *_: loop.call_soon_threadsafe(request_stop))
    signal.signal(signal.SIGINT, lambda *_: loop.call_soon_threadsafe(request_stop))

    wait_stop = asyncio.create_task(stop.wait())
    wait_disc = asyncio.create_task(bus.wait_for_disconnect())
    done, pending = await asyncio.wait(
        {wait_stop, wait_disc},
        return_when=asyncio.FIRST_COMPLETED,
    )
    for t in pending:
        t.cancel()
    try:
        await asyncio.gather(*pending, return_exceptions=True)
    except asyncio.CancelledError:
        pass
    for t in done:
        if t.cancelled():
            continue
        exc = t.exception()
        if exc is not None:
            raise exc


def main() -> None:
    if _import_err is not None:
        print(f"dbus-next fehlt: {_import_err} (pip install dbus-next)", file=sys.stderr)
        sys.exit(1)
    args = [a for a in sys.argv[1:] if a != "--vite-log"]
    vite_log = "--vite-log" in sys.argv[1:]
    if len(args) < 1:
        print(
            "usage: jenkins-dbus-pipeline-output-tee.py <BUILD_NUMBER> [--vite-log]",
            file=sys.stderr,
        )
        sys.exit(2)
    build_id = args[0].strip()

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
        asyncio.run(_run_tee(build_id, vite_log))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
