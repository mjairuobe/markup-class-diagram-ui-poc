#!/usr/bin/env bash
# shellcheck shell=bash
# Für Jenkins-User: XDG_RUNTIME_DIR + Session-Bus (User-Bus), nötig für
# systemctl --user und dbus SessionBus() / gdbus --session.
# Einmalig auf dem Host: sudo loginctl enable-linger <jenkins-user>

markup_vite_export_user_runtime() {
  local uid run
  uid=$(id -u)
  run="/run/user/${uid}"
  if [[ ! -d "$run" ]]; then
    return 1
  fi
  export XDG_RUNTIME_DIR="$run"
  if [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi
  return 0
}
