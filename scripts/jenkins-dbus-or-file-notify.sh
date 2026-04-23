#!/usr/bin/env bash
# 1) DBus: PullFromPipeline an org.markup.vite.DevServer (Session-Bus aus state/dbus.env)
# 2) Falls kein Bus / Fehler: Fallback pipeline_trigger
set -euo pipefail

STATE_DIR="${1:?state dir}"
TRIGGER_FILE="${STATE_DIR}/pipeline_trigger"
LOG="${2:-/dev/stdout}"

mkdir -p "$STATE_DIR"
echo "$(date -Is) pipeline notify: state=$STATE_DIR" | tee -a "$LOG" >/dev/null

try_dbus() {
  [[ -f "${STATE_DIR}/dbus.env" ]] || return 1
  # shellcheck disable=SC1090
  source "${STATE_DIR}/dbus.env"
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1

  export DBUS_SESSION_BUS_ADDRESS
  if command -v gdbus >/dev/null 2>&1; then
    if out=$(gdbus call --session \
      --dest org.markup.vite.DevServer \
      --object-path /org/markup/vite/DevServer \
      --method org.markup.vite.DevServer.PullFromPipeline 2>>"$LOG"); then
      echo "$(date -Is) DBus (gdbus): $out" | tee -a "$LOG" >/dev/null
      return 0
    fi
  fi
  if command -v dbus-send >/dev/null 2>&1; then
    if dbus-send --session --print-reply --dest=org.markup.vite.DevServer \
      /org/markup/vite/DevServer org.markup.vite.DevServer.PullFromPipeline 2>>"$LOG"; then
      echo "$(date -Is) DBus (dbus-send): PullFromPipeline ok" | tee -a "$LOG" >/dev/null
      return 0
    fi
  fi
  return 1
}

if try_dbus; then
  exit 0
fi

echo "$(date -Is) DBus nicht verfügbar oder Fehler – Fallback pipeline_trigger" | tee -a "$LOG" >/dev/null
{
  date -Is
  echo "PULL_REQUEST_FROM_PIPELINE=1"
  echo "JENKINS_BUILD=${BUILD_NUMBER:-}"
  echo "JENKINS_URL=${JENKINS_URL:-}"
} >>"$TRIGGER_FILE"
echo "$(date -Is) Fallback: pipeline_trigger aktualisiert" | tee -a "$LOG" >/dev/null
