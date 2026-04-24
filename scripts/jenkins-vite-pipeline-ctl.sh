#!/usr/bin/env bash
# Ein Dev-Server pro Jenkins-Knoten: globaler State unter JENKINS_HOME/.markup-vite-devserver
# Nur systemd --user (markup-vite-devserver.service) + User-D-Bus — kein flock, kein nohup-Fallback.
# Einmalige Einrichtung auf dem Agenten: siehe deploy/INSTALL-jenkins-user-systemd.txt
# Fast-Path: HTTP + gleicher WORKSPACE + npm lebt → Notify/Pull (D-Bus oder Datei).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=jenkins-vite-user-env.sh
source "${ROOT}/scripts/jenkins-vite-user-env.sh"

export WORKSPACE="${WORKSPACE:?WORKSPACE muss gesetzt sein (Jenkins)}"
BRANCH="${BRANCH_NAME:-${GIT_BRANCH#origin/}}"
BRANCH=${BRANCH:-unknown}
BRANCH_SAFE=${BRANCH//[^A-Za-z0-9._-]/_}

export MARKUP_VITE_GLOBAL_DIR="${MARKUP_VITE_GLOBAL_DIR:-${JENKINS_HOME:-$HOME}/.markup-vite-devserver}"
export STATE_DIR="$MARKUP_VITE_GLOBAL_DIR"
mkdir -p "$STATE_DIR"

# Standard: unter STATE_DIR (jenkins-schreibbar). Workspace-Pfad war root-owned → tee im Daemon brach ab.
REPO_LOG="${MARKUP_VITE_LOG:-${STATE_DIR}/vite-devserver.log}"
port_file="${STATE_DIR}/port.txt"
ready_file="${STATE_DIR}/ready.flag"
active_ws="${STATE_DIR}/active_workspace"
npm_pid_file="${STATE_DIR}/npm.pid"

# Nach stderr: bei Jenkins ist stdout oft block-gepuffert → Konsole wirkt „schwarz“, bis der Puffer voll ist.
log() { printf '%s\n' "[pipeline-ctl $(date -Is)] $*" >&2; }

log "Branch=$BRANCH WORKSPACE=$WORKSPACE GLOBAL_STATE=$STATE_DIR"

USER_UNIT="${MARKUP_VITE_SYSTEMD_UNIT:-markup-vite-devserver.service}"
USER_UNIT_FILE="${HOME}/.config/systemd/user/${USER_UNIT}"

ensure_user_session() {
  if ! markup_vite_export_user_runtime; then
    log "FEHLER: /run/user/$(id -u) fehlt — ohne das läuft kein systemd --user für diesen Account."
    log "Auf dem Jenkins-Knoten als root:"
    log "  sudo loginctl enable-linger $(id -un)"
    log "Danach Jenkins-Agent neu starten oder den User einmal interaktiv anmelden."
    return 1
  fi
  if ! systemctl --user show >/dev/null 2>&1; then
    log "FEHLER: systemctl --user antwortet nicht (User-Manager nicht erreichbar)."
    log "Prüfen: ls -la /run/user/$(id -u)  und nach enable-linger den Agenten neu starten."
    return 1
  fi
  return 0
}

ensure_unit_installed() {
  if [[ ! -f "$USER_UNIT_FILE" ]]; then
    log "FEHLER: systemd-User-Unit fehlt: $USER_UNIT_FILE"
    log "Auf dem Knoten als $(id -un), mit ausgechecktem Repo:"
    log "  bash ${ROOT}/scripts/jenkins-vite-install-user-unit.sh"
    return 1
  fi
  return 0
}

write_launch_env() {
  umask 077
  {
    printf 'export WORKSPACE=%q\n' "$WORKSPACE"
    printf 'export BRANCH=%q\n' "$BRANCH"
    printf 'export REPO_LOG=%q\n' "$REPO_LOG"
    printf 'export MARKUP_VITE_DAEMON_SCRIPT=%q\n' "${ROOT}/scripts/jenkins-vite-daemon.sh"
    printf 'export MARKUP_VITE_GLOBAL_DIR=%q\n' "$STATE_DIR"
  } >"${STATE_DIR}/launch.env"
}

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

# Rekursiv Kindprozesse beenden (npm/node, disown-Loops im Daemon), dann Wurzel.
kill_proc_tree() {
  local pid=$1
  [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  local ch
  for ch in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_proc_tree "$ch"
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "kill_proc_tree: beende PID $pid"
    kill "$pid" 2>/dev/null || true
    sleep 0.5
    kill -9 "$pid" 2>/dev/null || true
  fi
}

# Alles beenden, was zu unserem Dev-Server gehört (globaler State)
aggressive_stop_global() {
  log "aggressive_stop: Port, DBus, npm, daemon, Kindprozesse (global)"
  if [[ -f "$port_file" ]]; then
    oldp=$(cat "$port_file" 2>/dev/null || true)
    if [[ -n "${oldp:-}" ]] && command -v fuser >/dev/null 2>&1; then
      log "aggressive_stop: fuser -k TCP $oldp (Vite/npm auf Port)"
      fuser -k "${oldp}/tcp" 2>/dev/null || true
      sleep 1
    fi
  fi
  kill_dbus_stack
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "markup_vite_dbus_service.py" 2>/dev/null || true
  fi
  for name in npm.pid daemon.pid; do
    f="${STATE_DIR}/${name}"
    if [[ -f "$f" ]]; then
      pid=$(tr -d ' \n\r\t' <"$f" || true)
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
        log "aggressive_stop: beende Prozessbaum $name PID $pid"
        kill_proc_tree "$pid"
      else
        log "aggressive_stop: $name enthält PID ${pid:-leer} (nicht lebendig, räume Datei auf)"
      fi
    fi
  done
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "scripts/jenkins-vite-daemon.sh" 2>/dev/null || true
  fi
  cleanup_stale_workspace_ports
  rm -f "$ready_file" "${STATE_DIR}/port.txt" \
    "${STATE_DIR}/npm.pid" "${STATE_DIR}/daemon.pid" \
    "${STATE_DIR}/dbus.env" "${STATE_DIR}/dbus_service.pid" 2>/dev/null || true
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

# Ausführliche Jenkins-Konsolen-Ausgabe: existiert Server? laufen Hintergrundprozesse?
log_devserver_snapshot() {
  local p npid act dp http_ok
  log "--- Zustand Dev-Server (global, dieser Jenkins-Knoten) ---"
  if [[ -f "$port_file" ]]; then
    p=$(cat "$port_file" 2>/dev/null || true)
    log "port.txt: ja → Port=$p"
    if command -v curl >/dev/null 2>&1; then
      if curl -s -o /dev/null --connect-timeout 2 "http://127.0.0.1:${p}/" 2>/dev/null; then
        http_ok=1
      fi
    elif timeout 0.4 bash -c "echo > /dev/tcp/127.0.0.1/${p}" 2>/dev/null; then
      http_ok=1
    fi
    if [[ "${http_ok:-0}" -eq 1 ]]; then
      log "HTTP 127.0.0.1:${p}: erreichbar (Dev-Server antwortet)"
    else
      log "HTTP 127.0.0.1:${p}: NICHT erreichbar (kein lauffähiger Server auf diesem Port)"
    fi
  else
    log "port.txt: nein → kein registrierter Dev-Server-Port im State"
  fi

  if [[ -f "$npm_pid_file" ]]; then
    npid=$(cat "$npm_pid_file" 2>/dev/null || true)
    if [[ -n "${npid:-}" ]] && kill -0 "$npid" 2>/dev/null; then
      log "npm/watch (npm.pid): ja → PID $npid läuft"
    else
      log "npm/watch (npm.pid): Datei vorhanden, Prozess PID=${npid:-?} läuft NICHT"
    fi
  else
    log "npm/watch (npm.pid): nein → kein registrierter npm-Hintergrundprozess"
  fi

  if [[ -f "$active_ws" ]]; then
    act=$(cat "$active_ws" 2>/dev/null | tr -d '\0' || true)
    log "active_workspace: ${act:-leer}"
    if [[ "${act:-}" == "$WORKSPACE" ]]; then
      log "WORKSPACE: Build entspricht dem aktiven Workspace (gleicher Checkout-Pfad)"
    else
      log "WORKSPACE: Build weicht ab (Build=$WORKSPACE)"
    fi
  else
    log "active_workspace: nein (noch kein Workspace vom Daemon gesetzt)"
  fi

  if [[ -f "${STATE_DIR}/daemon.pid" ]]; then
    dp=$(cat "${STATE_DIR}/daemon.pid" 2>/dev/null || true)
    if [[ -n "${dp:-}" ]] && kill -0 "$dp" 2>/dev/null; then
      log "jenkins-vite-daemon (daemon.pid): ja → PID $dp läuft"
    else
      log "jenkins-vite-daemon (daemon.pid): PID ${dp:-?} nicht lebendig (Stale oder beendet)"
    fi
  else
    log "jenkins-vite-daemon (daemon.pid): nein"
  fi
  log "--- Ende Zustand ---"
}

log_why_not_healthy() {
  local reasons=0
  if ! is_port_http_up; then
    log "Grund für Neustart/Fast-Path-Verweigerung: Dev-Server-Port fehlt oder HTTP nicht erreichbar"
    reasons=1
  fi
  if ! npm_process_alive; then
    log "Grund: kein lebendiger npm/watch-Prozess laut npm.pid"
    reasons=1
  fi
  if [[ ! -f "$active_ws" ]]; then
    log "Grund: active_workspace fehlt (Daemon hat keinen aktiven Workspace gespeichert)"
    reasons=1
  else
    local act
    act=$(cat "$active_ws" 2>/dev/null | tr -d '\0' || true)
    if [[ "$act" != "$WORKSPACE" ]]; then
      log "Grund: anderer aktiver Workspace (State: ${act:-leer} ≠ Build: $WORKSPACE)"
      reasons=1
    fi
  fi
  if [[ "$reasons" -eq 0 ]]; then
    log "Hinweis: Bedingungen laut Skript unerwartet false (Details oben im Snapshot)"
  fi
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

wait_for_vite_ready() {
  local hint="${1:-}"
  local tee_pid=""
  log "warte auf Vite (max. 15 min)… — Live-Zeilen per D-Bus (PipelineOutput build_id=vite-log)"
  if [[ -f "${ROOT}/scripts/jenkins-dbus-pipeline-output-tee.py" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "${ROOT}/scripts/jenkins-dbus-pipeline-output-tee.py" "${BUILD_NUMBER:-0}" --vite-log &
    tee_pid=$!
    sleep 0.35
  fi
  for _ in $(seq 1 180); do
    if is_port_http_up && npm_process_alive; then
      [[ -n "${tee_pid:-}" ]] && kill "$tee_pid" 2>/dev/null || true
      [[ -n "${tee_pid:-}" ]] && wait "$tee_pid" 2>/dev/null || true
      P=$(cat "$port_file")
      log "VITE_DEV_PORT=$P"
      log "VITE_DEV_LOG=$REPO_LOG"
      log "VITE_DEV_STATE=$STATE_DIR (global)"
      return 0
    fi
    sleep 5
  done
  [[ -n "${tee_pid:-}" ]] && kill "$tee_pid" 2>/dev/null || true
  [[ -n "${tee_pid:-}" ]] && wait "$tee_pid" 2>/dev/null || true
  log "TIMEOUT. Siehe $REPO_LOG ${hint}"
  return 1
}

run_fast_path_notify() {
  if [[ -z "${BUILD_NUMBER:-}" ]]; then
    log "FEHLER: BUILD_NUMBER nicht gesetzt (Hot-Reload-Ack unmöglich)"
    exit 1
  fi
  log "Entscheidung: Fast-Path – bestehender Dev-Server ist gesund, gleiches WORKSPACE"
  log "Aktion: nur Notify/Pull (DBus oder Datei)"
  bash "${ROOT}/scripts/jenkins-dbus-or-file-notify.sh" "$STATE_DIR" "$REPO_LOG"
  P=$(cat "$port_file")
  log "VITE_DEV_PORT=$P"
  log "VITE_DEV_LOG=$REPO_LOG"
  log "VITE_DEV_STATE=$STATE_DIR (global, ein Server/Knoten)"
  exit 0
}

mkdir -p "$STATE_DIR"
rm -f "${STATE_DIR}/.flock-ctl"

ensure_user_session || exit 1
ensure_unit_installed || exit 1

log "Steuerung: systemd --user (${USER_UNIT}); D-Bus: busctl --user monitor org.markup.vite.DevServer"
log_devserver_snapshot

if is_same_workspace_and_healthy; then
  run_fast_path_notify
fi

log "Entscheidung: Neustart – Fast-Path nicht möglich (siehe Gründe unten)"
log_why_not_healthy
log "Aktion: systemctl --user stop ${USER_UNIT}, aggressive_stop, launch.env, systemctl --user start"
systemctl --user stop "$USER_UNIT" 2>/dev/null || true
sleep 2
aggressive_stop_global
write_launch_env
systemctl --user daemon-reload
systemctl --user reset-failed "$USER_UNIT" 2>/dev/null || true
if ! systemctl --user start "$USER_UNIT"; then
  log "FEHLER: systemctl --user start ${USER_UNIT} fehlgeschlagen."
  log "Log: journalctl --user -u ${USER_UNIT} -n 120 --no-pager"
  exit 1
fi
log "systemd: ${USER_UNIT} gestartet"
sleep 2
wait_for_vite_ready "und: journalctl --user -u ${USER_UNIT} -n 120 --no-pager" || exit 1
exit 0
