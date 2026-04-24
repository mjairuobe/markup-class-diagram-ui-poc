#!/usr/bin/env bash
# Einmalig als Jenkins-Agent-User ausführen (z. B. jenkins).
# Root auf dem Host: loginctl enable-linger <user>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${JENKINS_HOME:-$HOME}/.markup-vite-devserver"
USER_SYSTEMD="${HOME}/.config/systemd/user"
UNIT_SRC="${ROOT}/deploy/systemd-user/markup-vite-devserver.service"
RUN_SRC="${ROOT}/scripts/jenkins-vite-run-daemon.sh"

# shellcheck source=jenkins-vite-user-env.sh
source "${ROOT}/scripts/jenkins-vite-user-env.sh"

if [[ ! -f "$UNIT_SRC" ]] || [[ ! -f "$RUN_SRC" ]]; then
  echo "Erwarte Repo unter $ROOT (deploy/systemd-user, scripts/)." >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$USER_SYSTEMD"
install -m 0755 "$RUN_SRC" "${STATE_DIR}/run-daemon.sh"
install -m 0644 "$UNIT_SRC" "${USER_SYSTEMD}/markup-vite-devserver.service"

if command -v systemctl >/dev/null 2>&1; then
  if markup_vite_export_user_runtime; then
    systemctl --user daemon-reload
    systemctl --user enable markup-vite-devserver.service
    echo "Unit installiert. Start erfolgt durch die Pipeline (launch.env)."
  else
    echo "WARN: /run/user/$(id -u) fehlt — nach 'sudo loginctl enable-linger $(id -un)' erneut: systemctl --user daemon-reload"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
fi

echo ""
echo "Als root einmalig (Headless-Agent):"
echo "  sudo loginctl enable-linger $(id -un)"
echo ""
echo "Steuerung:"
echo "  systemctl --user status markup-vite-devserver.service"
echo "  systemctl --user restart markup-vite-devserver.service"
echo "  busctl --user monitor org.markup.vite.DevServer"
echo ""
