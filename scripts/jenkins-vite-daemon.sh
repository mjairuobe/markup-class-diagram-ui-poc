#!/usr/bin/env bash
# Hintergrundprozess: genau EIN Vite-Dev-Server pro Jenkins-Knoten. State in
# MARKUP_VITE_GLOBAL_DIR (nicht pro Branch-Workspace), damit Branch-Wechsel nicht
# zu doppelten Servern / falschen port.txt führt.
# JENKINS_NODE_COOKIE= leeren, damit der Prozess nach dem Job weiterläuft.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKSPACE=""
BRANCH="main"
REPO_LOG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --workspace) WORKSPACE=$2; shift 2 ;;
  --branch) BRANCH=$2; shift 2 ;;
  --log) REPO_LOG=$2; shift 2 ;;
  *) echo "unbekanntes arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$WORKSPACE" ]]; then
  echo "--workspace fehlt" >&2
  exit 1
fi

# Knotenweiter State: ein Port, ein Satz PIDs, eine pipeline_trigger, ein dbus
export MARKUP_VITE_GLOBAL_DIR="${MARKUP_VITE_GLOBAL_DIR:-${JENKINS_HOME:-$HOME}/.markup-vite-devserver}"
export STATE_DIR="$MARKUP_VITE_GLOBAL_DIR"
mkdir -p "$STATE_DIR"

if [[ -z "$REPO_LOG" ]]; then
  REPO_LOG="${STATE_DIR}/vite-devserver.log"
fi
mkdir -p "$(dirname "$REPO_LOG")" 2>/dev/null || REPO_LOG="${STATE_DIR}/vite-devserver.log"

log() { echo "[$(date -Is)] $*" | tee -a "$REPO_LOG" >&2; }

log "daemon start branch=$BRANCH workspace=$WORKSPACE"
log "STATE_DIR (global, ein Server/Knoten)=$STATE_DIR LOG=$REPO_LOG"

echo "$$" >"${STATE_DIR}/daemon.pid"
echo "$WORKSPACE" >"${STATE_DIR}/active_workspace"
echo "$BRANCH" >"${STATE_DIR}/active_branch"

: >"${STATE_DIR}/pipeline_trigger"
touch "${STATE_DIR}/pipeline_trigger"

start_dbus_service() {
  if ! command -v dbus-launch >/dev/null 2>&1; then
    log "WARN: dbus-launch fehlt (Paket dbus) – kein DBus"
    : >"${STATE_DIR}/dbus.env"
    return 0
  fi
  if ! python3 -c "import dbus" 2>/dev/null; then
    log "WARN: python3-dbus fehlt – kein DBus (apt: python3-dbus python3-gi)"
    : >"${STATE_DIR}/dbus.env"
    return 0
  fi
  eval "$(dbus-launch --sh-syntax)"
  {
    echo "export DBUS_SESSION_BUS_ADDRESS=\"${DBUS_SESSION_BUS_ADDRESS}\""
    if [[ -n "${DBUS_SESSION_BUS_PID:-}" ]]; then
      echo "export DBUS_SESSION_BUS_PID=${DBUS_SESSION_BUS_PID}"
    fi
  } >"${STATE_DIR}/dbus.env"
  log "DBus-Session (PID Bus=${DBUS_SESSION_BUS_PID:-?})"

  export DBUS_SESSION_BUS_ADDRESS
  export DBUS_SESSION_BUS_PID="${DBUS_SESSION_BUS_PID:-}"
  export MARKUP_VITE_WORKSPACE="$WORKSPACE"
  export MARKUP_VITE_LOG="$REPO_LOG"
  export MARKUP_VITE_BRANCH="$BRANCH"
  export MARKUP_VITE_STATE_DIR="$STATE_DIR"

  python3 "${SCRIPT_DIR}/markup_vite_dbus_service.py" >>"$REPO_LOG" 2>&1 &
  local p=$!
  echo "$p" >"${STATE_DIR}/dbus_service.pid"
  disown "$p" 2>/dev/null || true
  log "markup_vite_dbus_service.py PID=$p"
}

start_dbus_service

pick_port() {
  node -e "const s=require('net').createServer();s.listen(0,()=>{console.log(s.address().port);s.close();});" 2>/dev/null \
    || python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}
export PORT="${PORT:-$(pick_port)}"
export HOST="${VITE_DEV_HOST:-0.0.0.0}"
echo "$PORT" >"${STATE_DIR}/port.txt"
log "VITE nutzt PORT=$PORT (global $STATE_DIR/port.txt)"

# --- 30s pull (Workspace des aktuell aktiven Jobs = dieses Start-Workspace)
(
  set +e
  while true; do
    sleep 30
    (
      set -e
      ws="${STATE_DIR}/active_workspace"
      [[ -f "$ws" ]] || exit 0
      cd "$(cat "$ws")" || exit 0
      log "[pull-30s] git… (workspace=$(cat "$ws"))"
      git fetch --all --prune 2>>"$REPO_LOG" || true
      current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [[ -n "$current_branch" ]]; then
        git pull --ff-only origin "$current_branch" 2>>"$REPO_LOG" || log "[pull-30s] pull fehlgeschlagen"
        npm install --no-audit --no-fund 2>>"$REPO_LOG" || log "[pull-30s] npm fehlgeschlagen"
        log "[pull-30s] fertig"
      fi
    )
  done
) &
PULL1=$!
disown "$PULL1" 2>/dev/null || true

# --- pipeline_trigger (knotenweit, gleiche Datei für alle Pipelines)
(
  set +e
  last=$(stat -c %Y "${STATE_DIR}/pipeline_trigger" 2>/dev/null || echo 0)
  while true; do
    sleep 2
    now=$(stat -c %Y "${STATE_DIR}/pipeline_trigger" 2>/dev/null || echo 0)
    if [[ "$now" != "$last" ]]; then
      last=$now
      log "[file-trigger] pipeline_trigger – pull im active_workspace"
      (
        set +e
        build=""
        if [[ -f "${STATE_DIR}/pipeline_trigger" ]]; then
          build=$(grep -E '^JENKINS_BUILD=' "${STATE_DIR}/pipeline_trigger" | tail -1 | cut -d= -f2-)
          build="${build//$'\r'/}"
          build="${build//$'\n'/}"
        fi
        write_ack() {
          local pfx="$1" msg="$2"
          if [[ -z "$build" || "$build" == "0" ]]; then
            return 0
          fi
          echo "${pfx} ${msg}" >"${STATE_DIR}/pull_ack_${build}"
        }
        ws_file="${STATE_DIR}/active_workspace"
        if [[ ! -f "$ws_file" ]]; then
          log "[file-trigger] kein active_workspace"
          write_ack "HOT_RELOAD_ERR" "kein active_workspace"
          exit 0
        fi
        if ! cd "$(cat "$ws_file")"; then
          log "[file-trigger] cd fehlgeschlagen"
          write_ack "HOT_RELOAD_ERR" "cd fehlgeschlagen"
          exit 0
        fi
        if ! git fetch --all --prune; then
          log "[file-trigger] git fetch fehlgeschlagen"
          write_ack "HOT_RELOAD_ERR" "git fetch"
          exit 0
        fi
        b=$(git rev-parse --abbrev-ref HEAD) || {
          log "[file-trigger] git rev-parse fehlgeschlagen"
          write_ack "HOT_RELOAD_ERR" "rev-parse"
          exit 0
        }
        if ! git pull --ff-only origin "$b"; then
          log "[file-trigger] git pull fehlgeschlagen"
          write_ack "HOT_RELOAD_ERR" "git pull"
          exit 0
        fi
        if ! npm install --no-audit --no-fund; then
          log "[file-trigger] npm fehlgeschlagen"
          write_ack "HOT_RELOAD_ERR" "npm install"
          exit 0
        fi
        log "[file-trigger] fertig (ok, pull_ack build=${build:-?})"
        write_ack "HOT_RELOAD_OK" "git+npm (Vite HMR)"
      ) || true
    fi
  done
) &
PULL2=$!
disown "$PULL2" 2>/dev/null || true

cd "$WORKSPACE"
log "npm install…"
npm install --no-audit --no-fund 2>>"$REPO_LOG" || log "WARN: npm install fehlgeschlagen"

log "npm run watch (Vite HMR)…"
export NODE_ENV=development
npm run watch 2>>"$REPO_LOG" &

NPM_PID=$!
echo "$NPM_PID" >"${STATE_DIR}/npm.pid"
log "npm watch PID=$NPM_PID"

for _ in $(seq 1 120); do
  if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/"; then
      log "Vite: http://127.0.0.1:$PORT/ workspace=$WORKSPACE"
      date -Is >"${STATE_DIR}/ready.flag"
      break
    fi
  elif timeout 0.3 bash -c "echo > /dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
    log "Port $PORT offen (ohne curl)"
    date -Is >"${STATE_DIR}/ready.flag"
    break
  fi
  sleep 2
  if ! kill -0 "$NPM_PID" 2>/dev/null; then
    log "npm/Vite beendet (Fehler?) – $REPO_LOG"
    break
  fi
done

wait "$NPM_PID" || true
log "daemon endet (npm exit)"
