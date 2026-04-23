#!/usr/bin/env bash
# Triggert Pull (DBus mit build_id oder Datei-Fallback), wartet auf pull_ack_<BUILD>
# (Hot-Reload bestätigt), schreibt HOT_RELOAD_OK ins Log – sonst Exit 1.
# Pull-Zeilen kommen zusätzlich per DBus-Signal PipelineOutput auf stdout (Jenkins).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${1:?state dir}"
TRIGGER_FILE="${STATE_DIR}/pipeline_trigger"
LOG="${2:-/dev/stdout}"
BUILD_B="${BUILD_NUMBER:-0}"

mkdir -p "$STATE_DIR"

log() { echo "[notify $(date -Is)] $*" | tee -a "$LOG" >&2; }

log "pipeline notify state=$STATE_DIR BUILD=${BUILD_B}"

rm -f "${STATE_DIR}/pull_ack_${BUILD_B}" 2>/dev/null || true

wait_pull_ack() {
  local f="${STATE_DIR}/pull_ack_${BUILD_B}"
  local i
  for i in $(seq 1 300); do
    if [[ -f "$f" ]]; then
      local content
      content=$(tr -d '\0' <"$f" || true)
      rm -f "$f"
      log "pull_ack empfangen: $content"
      if [[ "$content" == HOT_RELOAD_OK* ]]; then
        echo "HOT_RELOAD_OK=1 build=${BUILD_B}" | tee -a "$LOG" >&2
        return 0
      fi
      echo "HOT_RELOAD fehlgeschlagen: $content" | tee -a "$LOG" >&2
      return 1
    fi
    sleep 2
  done
  log "TIMEOUT: keine pull_ack Datei nach 10 min: $f"
  return 1
}

try_dbus() {
  [[ -f "${STATE_DIR}/dbus.env" ]] || return 1
  # shellcheck disable=SC1090
  source "${STATE_DIR}/dbus.env"
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1
  export DBUS_SESSION_BUS_ADDRESS

  local tee_pid=""
  if [[ -f "${SCRIPT_DIR}/jenkins-dbus-pipeline-output-tee.py" ]]; then
    python3 "${SCRIPT_DIR}/jenkins-dbus-pipeline-output-tee.py" "${BUILD_B}" &
    tee_pid=$!
    sleep 0.35
  fi

  local rc=1
  if command -v dbus-send >/dev/null 2>&1; then
    if dbus-send --session --print-reply --dest=org.markup.vite.DevServer \
      /org/markup/vite/DevServer \
      org.markup.vite.DevServer.PullFromPipeline \
      "string:${BUILD_B}" 2>&1 | tee -a "$LOG"; then
      log "DBus (dbus-send) aufgerufen"
      rc=0
    fi
  fi
  if [[ "$rc" -ne 0 ]] && command -v gdbus >/dev/null 2>&1; then
    if gdbus call --session \
      --dest org.markup.vite.DevServer \
      --object-path /org/markup/vite/DevServer \
      --method org.markup.vite.DevServer.PullFromPipeline \
      "(s)" "${BUILD_B}" 2>&1 | tee -a "$LOG"; then
      log "DBus (gdbus) aufgerufen"
      rc=0
    fi
  fi

  if [[ -n "${tee_pid}" ]]; then
    kill "${tee_pid}" 2>/dev/null || true
    wait "${tee_pid}" 2>/dev/null || true
  fi
  return "$rc"
}

if try_dbus; then
  log "DBus-Aufruf zurück; warte auf pull_ack (sollte schon da sein)…"
else
  log "DBus nicht verfügbar – Fallback pipeline_trigger"
  {
    date -Is
    echo "PULL_REQUEST_FROM_PIPELINE=1"
    echo "JENKINS_BUILD=${BUILD_B}"
    echo "JENKINS_URL=${JENKINS_URL:-}"
  } >>"$TRIGGER_FILE"
  log "pipeline_trigger aktualisiert (Daemon pollt)"
fi

wait_pull_ack
