#!/usr/bin/env bash
# Sendet (1) optional eine DBus-Nachricht an einen registrierten DevServer, falls
# DBus-Adresse in state/dbus.env existiert und org.markup.vite.DevServer erreichbar ist,
# (2) sonst Fallback-Trigger-Datei für den Daemon.
set -euo pipefail

STATE_DIR="${1:?state dir}"
TRIGGER_FILE="${STATE_DIR}/pipeline_trigger"
LOG="${2:-/dev/stdout}"

mkdir -p "$STATE_DIR"
echo "$(date -Is) pipeline notify: branch state=$STATE_DIR" | tee -a "$LOG" >/dev/null

# Optional: Adresse von einem früher gestarteten Session-Bus (manuell oder durch Extension)
if [[ -f "${STATE_DIR}/dbus.env" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_DIR}/dbus.env"
  if command -v dbus-send >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    if dbus-send --session --type=method_call --print-reply \
      --dest=org.markup.vite.DevServer \
      /org/markup/vite/DevServer org.markup.vite.DevServer.PullFromPipeline 2>>"$LOG"; then
      echo "$(date -Is) DBus: PullFromPipeline gesendet" | tee -a "$LOG" >/dev/null
      exit 0
    else
      echo "$(date -Is) DBus: Ziel nicht erreichbar, nutze Datei-Fallback" | tee -a "$LOG" >/dev/null
    fi
  fi
else
  echo "$(date -Is) Keine state/dbus.env – nutze Datei-Fallback (DBus später möglich)" | tee -a "$LOG" >/dev/null
fi

{
  date -Is
  echo "PULL_REQUEST_FROM_PIPELINE=1"
  echo "JENKINS_BUILD=${BUILD_NUMBER:-}"
  echo "JENKINS_URL=${JENKINS_URL:-}"
} >>"$TRIGGER_FILE"
echo "$(date -Is) Fallback: pipeline_trigger aktualisiert" | tee -a "$LOG" >/dev/null
