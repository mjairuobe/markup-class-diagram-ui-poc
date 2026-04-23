#!/usr/bin/env bash
# Jenkins: prüft Vite, sendet DBus/Fallback, startet Daemon; Logs nur unter WORKSPACE/.vite-jenkins/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export WORKSPACE="${WORKSPACE:?WORKSPACE muss gesetzt sein (Jenkins)}"
BRANCH="${BRANCH_NAME:-${GIT_BRANCH#origin/}}"
BRANCH=${BRANCH:-unknown}
BRANCH_SAFE=${BRANCH//[^A-Za-z0-9._-]/_}
export STATE_DIR="${WORKSPACE}/.vite-jenkins/${BRANCH_SAFE}"
mkdir -p "$STATE_DIR"

REPO_LOG="${STATE_DIR}/vite-devserver.log"

log() { echo "[pipeline-ctl $(date -Is)] $*"; }

log "Branch=$BRANCH STATE_DIR=$STATE_DIR WORKSPACE=$WORKSPACE"

port_file="${STATE_DIR}/port.txt"
ready_file="${STATE_DIR}/ready.flag"

is_server_up() {
  local p
  [[ -f "$port_file" ]] || return 1
  p=$(cat "$port_file" 2>/dev/null || true)
  [[ -n "${p:-}" ]] || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null --connect-timeout 2 "http://127.0.0.1:${p}/" && return 0
  fi
  timeout 0.4 bash -c "echo > /dev/tcp/127.0.0.1/${p}" 2>/dev/null
}

kill_dbus_stack() {
  if [[ -f "${STATE_DIR}/dbus_service.pid" ]]; then
    ds=$(cat "${STATE_DIR}/dbus_service.pid" 2>/dev/null || true)
    if [[ -n "${ds:-}" ]] && kill -0 "$ds" 2>/dev/null; then
      log "beende DBus-Python PID $ds"
      kill "$ds" 2>/dev/null || true
      sleep 1
      kill -9 "$ds" 2>/dev/null || true
    fi
  fi
  if [[ -f "${STATE_DIR}/dbus.env" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_DIR}/dbus.env" || true
    if [[ -n "${DBUS_SESSION_BUS_PID:-}" ]] && kill -0 "$DBUS_SESSION_BUS_PID" 2>/dev/null; then
      log "beende DBus-Session-Bus PID $DBUS_SESSION_BUS_PID"
      kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
      sleep 1
      kill -9 "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
    fi
  fi
  rm -f "${STATE_DIR}/dbus.env" "${STATE_DIR}/dbus_service.pid" 2>/dev/null || true
}

LOCK="${STATE_DIR}/.flock-ctl"
exec 200>"$LOCK"
flock 200

if is_server_up; then
  log "Dev-Server läuft – DBus (ggf. Fallback)"
  bash "${ROOT}/scripts/jenkins-dbus-or-file-notify.sh" "$STATE_DIR" "$REPO_LOG" || true
  P=$(cat "$port_file")
  log "VITE_DEV_PORT=$P (bestehend)"
  log "VITE_DEV_LOG=$REPO_LOG"
  log "VITE_DEV_STATE=$STATE_DIR"
  exit 0
fi

log "Kein erreichbarer Dev-Server – räume auf (fuser, DBus, npm, daemon)"
if [[ -f "$port_file" ]]; then
  oldp=$(cat "$port_file" 2>/dev/null || true)
  if [[ -n "${oldp:-}" ]] && command -v fuser >/dev/null 2>&1; then
    log "fuser -k ${oldp}/tcp"
    fuser -k "${oldp}/tcp" 2>/dev/null || true
    sleep 1
  fi
fi

kill_dbus_stack

for name in npm.pid daemon.pid; do
  f="${STATE_DIR}/${name}"
  if [[ -f "$f" ]]; then
    pid=$(cat "$f" || true)
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      log "beende PID $pid ($name)"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
done
rm -f "$ready_file" || true

log "starte jenkins-vite-daemon.sh (nohup)…"
export JENKINS_NODE_COOKIE=
nohup env SHELL=/bin/bash bash "${ROOT}/scripts/jenkins-vite-daemon.sh" \
  --workspace "$WORKSPACE" \
  --branch "$BRANCH" \
  --log "$REPO_LOG" \
  >>"${STATE_DIR}/daemon.nohup.log" 2>&1 &
disown || true
sleep 2

log "warte auf Vite (max. 15 min)…"
for _ in $(seq 1 180); do
  if is_server_up; then
    P=$(cat "$port_file")
    log "VITE_DEV_PORT=$P"
    log "VITE_DEV_LOG=$REPO_LOG"
    log "VITE_DEV_STATE=$STATE_DIR"
    exit 0
  fi
  sleep 5
done

log "TIMEOUT. Siehe $REPO_LOG und ${STATE_DIR}/daemon.nohup.log"
exit 1
