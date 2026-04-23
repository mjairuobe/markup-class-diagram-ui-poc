#!/usr/bin/env bash
# Ein Dev-Server pro Jenkins-Knoten: globaler State unter JENKINS_HOME/.markup-vite-devserver
# Fast-Path (nur Notify): nur wenn HTTP + gleicher WORKSPACE + npm lebt.
# Sonst: alte Prozesse hart beenden (inkl. alter Branch-port.txt unter workspace), neu starten.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export WORKSPACE="${WORKSPACE:?WORKSPACE muss gesetzt sein (Jenkins)}"
BRANCH="${BRANCH_NAME:-${GIT_BRANCH#origin/}}"
BRANCH=${BRANCH:-unknown}
BRANCH_SAFE=${BRANCH//[^A-Za-z0-9._-]/_}

export MARKUP_VITE_GLOBAL_DIR="${MARKUP_VITE_GLOBAL_DIR:-${JENKINS_HOME:-$HOME}/.markup-vite-devserver}"
export STATE_DIR="$MARKUP_VITE_GLOBAL_DIR"
mkdir -p "$STATE_DIR"

REPO_LOG="${STATE_DIR}/vite-devserver.log"
port_file="${STATE_DIR}/port.txt"
ready_file="${STATE_DIR}/ready.flag"
active_ws="${STATE_DIR}/active_workspace"
npm_pid_file="${STATE_DIR}/npm.pid"

log() { echo "[pipeline-ctl $(date -Is)] $*"; }

log "Branch=$BRANCH WORKSPACE=$WORKSPACE GLOBAL_STATE=$STATE_DIR"

# Alte Prozesse, die noch auf irgendeinen alten port.txt aus Branch-Workspaces hören
cleanup_stale_workspace_ports() {
  if [[ -z "${JENKINS_HOME:-}" ]]; then
    return 0
  fi
  local f p
  while IFS= read -r -d '' f; do
    p=$(cat "$f" 2>/dev/null || true)
    if [[ -n "${p:-}" ]] && [[ "$p" =~ ^[0-9]+$ ]] && command -v fuser >/dev/null 2>&1; then
      log "stale port.txt $f → fuser -k ${p}/tcp"
      fuser -k "${p}/tcp" 2>/dev/null || true
    fi
    rm -f "$f" 2>/dev/null || true
  done < <(find "$JENKINS_HOME/workspace" -path '*/.vite-jenkins/*/port.txt' -print0 2>/dev/null || true)
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
      log "beende DBus-Session PID $DBUS_SESSION_BUS_PID"
      kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
      sleep 1
      kill -9 "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
    fi
  fi
  rm -f "${STATE_DIR}/dbus.env" "${STATE_DIR}/dbus_service.pid" 2>/dev/null || true
}

# Alles beenden, was zu unserem Dev-Server gehört (globaler State)
aggressive_stop_global() {
  log "aggressive_stop: Port, DBus, npm, daemon (global)"
  if [[ -f "$port_file" ]]; then
    oldp=$(cat "$port_file" 2>/dev/null || true)
    if [[ -n "${oldp:-}" ]] && command -v fuser >/dev/null 2>&1; then
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
        log "beende $name PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
  done
  # evtl. hängen gebliebene Hintergrund-Shells mit unserem Script
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "scripts/jenkins-vite-daemon.sh" 2>/dev/null || true
  fi
  cleanup_stale_workspace_ports
  rm -f "$ready_file" "${STATE_DIR}/port.txt" 2>/dev/null || true
}

is_port_http_up() {
  local p
  [[ -f "$port_file" ]] || return 1
  p=$(cat "$port_file" 2>/dev/null || true)
  [[ -n "${p:-}" ]] || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null --connect-timeout 2 "http://127.0.0.1:${p}/" && return 0
  fi
  timeout 0.4 bash -c "echo > /dev/tcp/127.0.0.1/${p}" 2>/dev/null
}

npm_process_alive() {
  local f="$npm_pid_file" pid
  [[ -f "$f" ]] || return 1
  pid=$(cat "$f" 2>/dev/null || true)
  [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null
}

# Nur wenn derselbe Job-Workspace noch bedient wird: schnell nur Pull triggern
is_same_workspace_and_healthy() {
  is_port_http_up || return 1
  npm_process_alive || return 1
  [[ -f "$active_ws" ]] || return 1
  local act
  act=$(cat "$active_ws" 2>/dev/null | tr -d '\0' || true)
  [[ -n "$act" && "$act" == "$WORKSPACE" ]]
}

LOCK="${STATE_DIR}/.flock-ctl"
mkdir -p "$STATE_DIR"
exec 200>"$LOCK"
flock 200

if is_same_workspace_and_healthy; then
  if [[ -z "${BUILD_NUMBER:-}" ]]; then
    log "FEHLER: BUILD_NUMBER nicht gesetzt (Hot-Reload-Ack unmöglich)"
    exit 1
  fi
  log "Dev-Server gesund, gleiches WORKSPACE – DBus/Datei-Notify (kein Neustart)"
  bash "${ROOT}/scripts/jenkins-dbus-or-file-notify.sh" "$STATE_DIR" "$REPO_LOG"
  P=$(cat "$port_file")
  log "VITE_DEV_PORT=$P"
  log "VITE_DEV_LOG=$REPO_LOG"
  log "VITE_DEV_STATE=$STATE_DIR (global, ein Server/Knoten)"
  exit 0
fi

log "Neustart: anderer Branch/Workspace, oder ungesund/Timeout zuvor – aggressive_stop, dann neuer Start"
aggressive_stop_global

log "starte jenkins-vite-daemon.sh (nohup)…"
export JENKINS_NODE_COOKIE=
nohup env SHELL=/bin/bash \
  MARKUP_VITE_GLOBAL_DIR="$STATE_DIR" \
  bash "${ROOT}/scripts/jenkins-vite-daemon.sh" \
  --workspace "$WORKSPACE" \
  --branch "$BRANCH" \
  --log "$REPO_LOG" \
  >>"${STATE_DIR}/daemon.nohup.log" 2>&1 &
disown || true
sleep 2

log "warte auf Vite (max. 15 min)…"
for _ in $(seq 1 180); do
  if is_port_http_up && npm_process_alive; then
    P=$(cat "$port_file")
    log "VITE_DEV_PORT=$P"
    log "VITE_DEV_LOG=$REPO_LOG"
    log "VITE_DEV_STATE=$STATE_DIR (global)"
    exit 0
  fi
  sleep 5
done

log "TIMEOUT. Siehe $REPO_LOG und ${STATE_DIR}/daemon.nohup.log"
exit 1
