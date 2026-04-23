#!/usr/bin/env bash
# Von Jenkinsfile aufgerufen: prüft bestehenden Server, sendet ggf. DBus/Fallback-Trigger,
# startet Daemon neu, schreibt VITE_DEV_PORT ins Build-Log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export WORKSPACE="${WORKSPACE:?WORKSPACE muss gesetzt sein (Jenkins)}"
BRANCH="${BRANCH_NAME:-${GIT_BRANCH#origin/}}"
BRANCH=${BRANCH:-unknown}
BRANCH_SAFE=${BRANCH//[^A-Za-z0-9._-]/_}
export STATE_DIR="${WORKSPACE}/.vite-jenkins/${BRANCH_SAFE}"
mkdir -p "$STATE_DIR"

REPO_LOG="/var/log/vite-devserver.log"
if ! { : >>"$REPO_LOG"; } 2>/dev/null; then
  REPO_LOG="${STATE_DIR}/vite-devserver.log"
fi

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

LOCK="${STATE_DIR}/.flock-ctl"
exec 200>"$LOCK"
flock 200

# 1) Dev-Server antwortet bereits? -> nur benachrichtigen, Port ausgeben
if is_server_up; then
  log "Dev-Server läuft – sende Pipeline-Signal (DBus/Fallback)"
  bash "${ROOT}/scripts/jenkins-dbus-or-file-notify.sh" "$STATE_DIR" "$REPO_LOG" || true
  P=$(cat "$port_file")
  log "VITE_DEV_PORT=$P (bestehend)"
  log "VITE_DEV_LOG=$REPO_LOG"
  log "VITE_DEV_STATE=$STATE_DIR"
  exit 0
fi

# 2) Kein gesunder Server: alte PIDs beenden, Port frei machen
log "Kein erreichbarer Dev-Server – räume alte PIDs auf"
if [[ -f "$port_file" ]]; then
  oldp=$(cat "$port_file" 2>/dev/null || true)
  if [[ -n "${oldp:-}" ]] && command -v fuser >/dev/null 2>&1; then
    log "fuser: Prozesse auf Port $oldp (falls vorhanden) beenden"
    fuser -k "${oldp}/tcp" 2>/dev/null || true
    sleep 1
  fi
fi
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

# 3) Neuen Hintergrund-Daemon starten
log "starte jenkins-vite-daemon.sh im Hintergrund…"
export JENKINS_NODE_COOKIE=
nohup env SHELL=/bin/bash bash "${ROOT}/scripts/jenkins-vite-daemon.sh" \
  --workspace "$WORKSPACE" \
  --branch "$BRANCH" \
  --log "$REPO_LOG" \
  >>"${STATE_DIR}/daemon.nohup.log" 2>&1 &
disown || true
sleep 2

# 4) Warten, bis Port erreichbar
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

log "TIMEOUT: Vite nicht erreichbar. Siehe $REPO_LOG und ${STATE_DIR}/daemon.nohup.log"
exit 1
