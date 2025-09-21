#!/usr/bin/env bash
# MDV installation / backup helper with safety checks

set -euo pipefail
trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR
trap 'echo; echo "[INFO] Caught SIGINT. Aborting."; exit 130' INT

# ---------- CONFIG ----------
# Adjust as needed
export CTG_RTTCT="/apps1/tomcat3"                    # Tomcat root (content resides here)
export CTG_RTDATA="/usr/data/pbadata"                # Root where configs/data reside
export CTG_DEPLOY="/usr/data/pbadata/deployment/mdv5" # Root of deployment artifacts/backups (fixed /usr)
export CTG_TODAY="$(date +'%Y%m%d')"                 # YYYYMMDD
export CTG_TOMUSER="ctg-tomcat"                      # Tomcat service user
export CTG_ASSET="las5"                              # Server/asset name that hosts Tomcat
export CTG_SERVICENAME="tomcat3"                     # systemd service name
CTG_SOURCES="/path/to/mdv5_artifacts"                # <-- set: directory containing new deploy artifacts

# Pre-check controls
DISK_PATH="${CTG_RTDATA}"     # Check disk usage where we write backups/artifacts
MAX_USE_PCT=80                # Fail if >= this usage %
PAUSE_SECONDS=300             # When others are logged in, wait this long per cycle
RECHECK_ON_TIMEOUT=1          # 1=recheck again after waiting, 0=proceed after one wait

# ---------- HELPERS ----------
log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

check_disk_usage() {
  local path="${1:?path}" threshold="${2:?threshold}"
  local used_pct
  used_pct="$(df -P "$path" | awk 'NR==2 {gsub("%","",$5); print $5}')"
  [[ "$used_pct" =~ ^[0-9]+$ ]] || die "Could not parse disk usage for $path"
  log "Disk usage on $path: ${used_pct}% (threshold ${threshold}%)"
  (( used_pct < threshold )) || die "Disk usage ${used_pct}% >= ${threshold}%. Free space before proceeding."
}

list_other_users() {
  local me; me="$(id -un)"
  who | awk -v me="$me" '$1 != me {print $1, $2, $3, $4, $5}' | sort -u
}

other_users_present() {
  local me; me="$(id -un)"
  if who | awk -v me="$me" '$1 != me {exit 0} END {exit 1}'; then return 0; else return 1; fi
}

pause_if_others_logged_in() {
  if other_users_present; then
    log "Detected other logged-in users:"
    echo "----------------------------------------"
    list_other_users || true
    echo "----------------------------------------"
    echo "Options: [C] Continue, [A] Abort, [Enter] Wait ${PAUSE_SECONDS}s and re-check"
    while other_users_present; do
      local ans=""
      read -r -t "$PAUSE_SECONDS" -p "Your choice (C/A/<Enter>): " ans || true
      case "${ans^^}" in
        C) log "Continuing by operator choice."; return 0;;
        A) die "Aborted by operator due to other active sessions.";;
        "") if (( RECHECK_ON_TIMEOUT )); then
              log "Re-checking sessions..."
              if ! other_users_present; then log "No other users now. Proceeding."; return 0; fi
              echo "----------------------------------------"; list_other_users || true; echo "----------------------------------------"
            else
              log "Proceeding after timeout without re-check."; return 0
            fi
            ;;
        *) echo "Invalid choice. Press C, A, or Enter.";;
      esac
    done
    log "No other users remain. Proceeding."
  else
    log "No other users logged in. Proceeding."
  fi
}

confirm_env() {
  [[ -d "$CTG_RTTCT" ]] || die "CTG_RTTCT not found: $CTG_RTTCT"
  [[ -d "$CTG_RTDATA" ]] || die "CTG_RTDATA not found: $CTG_RTDATA"
  [[ -d "$CTG_DEPLOY" ]] || { log "Creating CTG_DEPLOY: $CTG_DEPLOY"; sudo mkdir -p "$CTG_DEPLOY"; }
  id -u "$CTG_TOMUSER" >/dev/null 2>&1 || die "Tomcat user not found: $CTG_TOMUSER"
  systemctl list-unit-files | grep -q "^${CTG_SERVICENAME}\.service" || die "systemd service not found: ${CTG_SERVICENAME}.service"
  [[ -d "$CTG_SOURCES" ]] || die "CTG_SOURCES not found: $CTG_SOURCES"
}

ensure_tools() {
  # Prefer ss; fall back to netstat or lsof
  if command -v ss >/dev/null 2>&1; then :
  elif command -v netstat >/dev/null 2>&1; then :
  elif command -v lsof >/dev/null 2>&1; then :
  else
    die "Need one of: ss, netstat, or lsof for port checks."
  fi
  require_cmd df awk tar systemctl ps grep sudo
}

# ---------- ACTIONS ----------
save_prior_artifacts() {
  log "Preparing deployment root and ownership…"
  sudo mkdir -p "${CTG_DEPLOY}"
  sudo chown -R "${CTG_TOMUSER}:${CTG_TOMUSER}" "${CTG_DEPLOY}"

  log "Copying new deployment artifacts to ${CTG_DEPLOY}…"
  rsync -aH --delete "${CTG_SOURCES}/" "${CTG_DEPLOY}/artifacts/"
}

stop_tomcat_and_verify() {
  log "Stopping service: ${CTG_SERVICENAME}"
  sudo systemctl stop "${CTG_SERVICENAME}"
  # brief wait then verify
  sleep 2
  sudo systemctl --no-pager status "${CTG_SERVICENAME}" || true

  log "Verifying process is not running…"
  if pgrep -u "${CTG_TOMUSER}" -f "tomcat|${CTG_SERVICENAME}" >/dev/null 2>&1; then
    die "Tomcat processes still running after stop."
  fi

  log "Verifying port not listening…"
  if command -v ss >/dev/null 2>&1; then
    if sudo ss -tulnp | grep -qi tomcat; then die "Tomcat port still listening."; fi
  elif command -v netstat >/dev/null 2>&1; then
    if sudo netstat -tulnp | grep -qi tomcat; then die "Tomcat port still listening."; fi
  else
    if sudo lsof -i -P -n | grep -qi tomcat; then die "Tomcat port still listening."; fi
  fi
}

perform_backups() {
  local bdir="${CTG_DEPLOY}/backups/${CTG_ASSET}/${CTG_TODAY}"
  log "Creating backup dir: $bdir"
  mkdir -p "$bdir"

  # Backup Tomcat tree
  local tomcat_tgz="${bdir}/${CTG_TODAY}_${CTG_SERVICENAME}.tgz"
  log "Backing up Tomcat root ${CTG_RTTCT} -> ${tomcat_tgz}"
  tar czf "${tomcat_tgz}" -C "$(dirname "${CTG_RTTCT}")" "$(basename "${CTG_RTTCT}")"

  # Backup mdv4 configs if present
  local mdv4_cfg_dir="${CTG_RTDATA}/mdv4_config"
  if [[ -d "$mdv4_cfg_dir" ]]; then
    local cfg_tgz="${bdir}/${CTG_TODAY}_mdv4_configs.tgz"
    log "Backing up MDV4 configs ${mdv4_cfg_dir} -> ${cfg_tgz}"
    tar czf "${cfg_tgz}" -C "$(dirname "${mdv4_cfg_dir}")" "$(basename "${mdv4_cfg_dir}")"
  else
    log "MDV4 config dir not found (${mdv4_cfg_dir}); skipping."
  fi

  # Backup systemd unit files
  if compgen -G "/etc/systemd/system/${CTG_SERVICENAME}*" > /dev/null; then
    log "Copying systemd unit files for ${CTG_SERVICENAME}"
    cp /etc/systemd/system/"${CTG_SERVICENAME}"* "${bdir}/"
  else
    log "No specific unit files for ${CTG_SERVICENAME}*; copying generic tomcat units if present."
    if compgen -G "/etc/systemd/system/tomcat*" > /dev/null; then
      cp /etc/systemd/system/tomcat* "${bdir}/"
    fi
  fi
}

verify_runtime_prereqs() {
  log "Verifying JRE ≥17…"
  if command -v java >/dev/null 2>&1; then
    local jv
    jv="$(java -version 2>&1 | awk -F\" '/version/ {print $2}' | cut -d. -f1)"
    [[ "${jv:-0}" -ge 17 ]] || die "Java runtime <17 detected. Found: ${jv:-unknown}"
    log "Java OK (major ${jv})"
  else
    die "java not found in PATH. Install JRE/JDK 17+."
  fi

  log "Verifying Python 3.9 availability…"
  # Prefer explicit python3.9 to avoid system 'python' surprises
  if command -v python3.9 >/dev/null 2>&1; then
    log "python3.9 found at: $(command -v python3.9)"
  else
    die "python3.9 not found. Install it (e.g., yum/dnf install python39)."
  fi

  # Sanity-check pip for 3.9 (optional but nice)
  if command -v pip3.9 >/dev/null 2>&1; then
    log "pip3.9 found."
  else
    log "pip3.9 not found; will use venv’s pip."
  fi
}

setup_utils_env() {
  # Paths
  local mdv_root="${CTG_RTDATA}/mdv/5"
  local venv_dir="${mdv_root}/mdv_utils_env"
  local req_file="${CTG_DEPLOY}/UTILS/requirements_UTILS.txt"
  local pip_log="${CTG_DEPLOY}/mdv_utils_env.log"

  log "Preparing UTILs directories at ${mdv_root}…"
  sudo mkdir -p "${mdv_root}"
  sudo chown -R "${CTG_TOMUSER}:${CTG_TOMUSER}" "${CTG_RTDATA}/mdv"
  sudo chmod -R o-rwx "${CTG_RTDATA}/mdv"

  [[ -f "${req_file}" ]] || die "Requirements file missing: ${req_file}"

  log "Creating Python 3.9 virtualenv for UTILs at ${venv_dir}…"
  # Use the explicit interpreter to guarantee 3.9
  python3.9 -m venv "${venv_dir}"

  # Upgrade pip inside the venv (not system-wide)
  log "Upgrading pip inside venv…"
  "${venv_dir}/bin/python" -m pip install --upgrade pip wheel setuptools

  log "Installing UTILs requirements (logging to ${pip_log})…"
  "${venv_dir}/bin/pip" install --log-file="${pip_log}" -r "${req_file}"

  log "UTILs venv ready at ${venv_dir}"
}

test_utils_env() {
  local venv_dir="${CTG_RTDATA}/mdv/5/mdv_utils_env"

  [[ -x "${venv_dir}/bin/python" ]] || die "UTILs venv not found: ${venv_dir}"

  log "Testing Python version inside venv…"
  "${venv_dir}/bin/python" --version

  log "Import test: netCDF4 (as per requirements)…"
  "${venv_dir}/bin/python" - <<'PY'
import sys
try:
    import netCDF4 as nc
    print("netCDF4 OK:", nc.__version__)
except Exception as e:
    print("netCDF4 import FAILED:", e, file=sys.stderr)
    sys.exit(1)
PY

  log "UTILs venv tests passed."
}




main() {
  log "Starting MDV install pre-checks…"
  ensure_tools
  confirm_env
  verify_runtime_prereqs         # <— NEW
  check_disk_usage "$DISK_PATH" "$MAX_USE_PCT"
  pause_if_others_logged_in

  log "Saving prior artifacts…"
  save_prior_artifacts

  log "Stopping Tomcat and verifying shutdown…"
  stop_tomcat_and_verify

  log "Performing backups…"
  perform_backups

  log "Setting up UTILs Python env…"
  setup_utils_env                # <— NEW
  test_utils_env                 # <— NEW

  log "Pre-checks, backups, and UTILs env complete. Proceed to artifact unpack/config…"
  # unpack_artifacts
  # apply_config_overlays
  # set_permissions
  # restart_and_healthcheck
}



main "$@"

