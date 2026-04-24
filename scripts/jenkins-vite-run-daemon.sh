#!/usr/bin/env bash
# Wird von systemd --user (markup-vite-devserver.service) aufgerufen.
# launch.env legt die Pipeline fest (Workspace/Branch/Log/Pfad zum Daemon-Skript).
set -euo pipefail

STATE_DIR="${JENKINS_HOME:-$HOME}/.markup-vite-devserver"
ENV_FILE="${STATE_DIR}/launch.env"

if [[ ! -f "$ENV_FILE" ]]; then
  printf '%s\n' "[run-daemon] FEHLER: fehlt $ENV_FILE (von jenkins-vite-pipeline-ctl.sh geschrieben)" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

export MARKUP_VITE_GLOBAL_DIR="${MARKUP_VITE_GLOBAL_DIR:-$STATE_DIR}"
export MARKUP_VITE_USER_SESSION_DBUS=1
uid="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/${uid}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

if [[ -z "${MARKUP_VITE_DAEMON_SCRIPT:-}" || ! -f "$MARKUP_VITE_DAEMON_SCRIPT" ]]; then
  printf '%s\n' "[run-daemon] FEHLER: MARKUP_VITE_DAEMON_SCRIPT ungültig: ${MARKUP_VITE_DAEMON_SCRIPT:-}" >&2
  exit 1
fi

exec bash "$MARKUP_VITE_DAEMON_SCRIPT" --workspace "$WORKSPACE" --branch "$BRANCH" --log "$REPO_LOG"
