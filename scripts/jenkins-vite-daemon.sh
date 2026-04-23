#!/usr/bin/env bash
# Lang laufender Hintergrundprozess: npm/Vite-Dev-Server, periodisches git pull, Reaktion auf
# pipeline_trigger-Datei. Sollte mit JENKINS_NODE_COOKIE= gestartet werden, damit der Prozess
# nach Job-Ende weiterläuft.
set -euo pipefail

WORKSPACE=""
BRANCH="main"
REPO_LOG="/var/log/vite-devserver.log"

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

BRANCH_SAFE=${BRANCH//[^A-Za-z0-9._-]/_}
export STATE_DIR="${WORKSPACE}/.vite-jenkins/${BRANCH_SAFE}"
mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$REPO_LOG")" 2>/dev/null || REPO_LOG="${STATE_DIR}/vite-devserver.log"

# Log-Datei: /var/log nur wenn root/jenkins sonst im STATE_DIR
if ! { : >>"$REPO_LOG"; } 2>/dev/null; then
  REPO_LOG="${STATE_DIR}/vite-devserver.log"
fi

log() { echo "[$(date -Is)] $*" | tee -a "$REPO_LOG" >&2; }

log "daemon start branch=$BRANCH workspace=$WORKSPACE"
log "STATE_DIR=$STATE_DIR"
log "LOG=$REPO_LOG"

echo "$$" >"${STATE_DIR}/daemon.pid"

# Optional: lege eine dbus.env-Datei an, falls ihr später ein Session-Bus-Setup einbindet
: >"${STATE_DIR}/pipeline_trigger"
touch "${STATE_DIR}/pipeline_trigger"

# Freien Port
pick_port() {
  node -e "const s=require('net').createServer();s.listen(0,()=>{console.log(s.address().port);s.close();});" 2>/dev/null \
    || python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}
export PORT="${PORT:-$(pick_port)}"
export HOST="${VITE_DEV_HOST:-0.0.0.0}"
echo "$PORT" >"${STATE_DIR}/port.txt"
log "VITE / npm wird PORT=$PORT (HOST=$HOST) nutzen (auch in $STATE_DIR/port.txt)"

# --- Hintergrund: alle 30 s git pull (disown: läuft weiter, falls Vite beendet)
(
  set +e
  while true; do
    sleep 30
    (
      set -e
      cd "$WORKSPACE"
      log "[pull-30s] git fetch origin && git pull --ff-only"
      git fetch --all --prune 2>>"$REPO_LOG" || true
      current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [[ -n "$current_branch" ]]; then
        git pull --ff-only origin "$current_branch" 2>>"$REPO_LOG" || log "[pull-30s] pull fehlgeschlagen"
        npm install --no-audit --no-fund 2>>"$REPO_LOG" || log "[pull-30s] npm install fehlgeschlagen"
        log "[pull-30s] fertig"
      fi
    )
  done
) &
PULL1=$!
disown "$PULL1" 2>/dev/null || true

# --- Hintergrund: pipeline_trigger-Datei (wird bei jedem append/modify ausgelöst)
(
  set +e
  last=$(stat -c %Y "${STATE_DIR}/pipeline_trigger" 2>/dev/null || echo 0)
  while true; do
    sleep 2
    now=$(stat -c %Y "${STATE_DIR}/pipeline_trigger" 2>/dev/null || echo 0)
    if [[ "$now" != "$last" ]]; then
      last=$now
      log "[trigger] neuer Inhalt in pipeline_trigger – git pull"
      (
        set -e
        cd "$WORKSPACE"
        git fetch --all --prune
        b=$(git rev-parse --abbrev-ref HEAD)
        git pull --ff-only origin "$b" || true
        npm install --no-audit --no-fund || true
        log "[trigger] pull abgeschlossen"
      ) || true
    fi
  done
) &
PULL2=$!
disown "$PULL2" 2>/dev/null || true

# --- Wichtig: nur einmal bauen / install vor erstem Vite-Start
cd "$WORKSPACE"
log "npm install (Root-Workspace)…"
npm install --no-audit --no-fund 2>>"$REPO_LOG" || log "WARN: npm install fehlgeschlagen (siehe Log)"

log "starte Vite (npm run watch)…"
export NODE_ENV=development
npm run watch 2>>"$REPO_LOG" &

NPM_PID=$!
echo "$NPM_PID" >"${STATE_DIR}/npm.pid"
log "npm watch PID=$NPM_PID"

# Warten, bis der Port erreichbar ist (HTTP-Head reicht)
for i in $(seq 1 120); do
  if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/"; then
      log "Vite hört auf http://0.0.0.0:$PORT (lokal: http://127.0.0.1:$PORT/)"
      date -Is >"${STATE_DIR}/ready.flag"
      break
    fi
  else
    if timeout 0.3 bash -c "echo > /dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
      log "Port $PORT offen (ohne curl)"
      date -Is >"${STATE_DIR}/ready.flag"
      break
    fi
  fi
  sleep 2
  if ! kill -0 "$NPM_PID" 2>/dev/null; then
    log "Vite/ npm-Prozess beendet (Fehler?) – siehe $REPO_LOG"
    break
  fi
done

# Daemon bleibt aktiv, bis Prozess stirbt
wait "$NPM_PID" || true
log "daemon endet (npm exit)"
