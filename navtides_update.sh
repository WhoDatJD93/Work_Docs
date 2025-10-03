#!/bin/bash
# NAVTIDE Upgrade & Backup

 set -euo pipefail
  5 trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR
  6 trap 'echo; echo "[INFO] Caught SIGINT. Aborting."; exit 130' INT

# -------------------CONFIG---------------------

export CTG_RTTCT="/app1/tomcat"
export CTG_RTDATA="/usr/data/pbadata"
export "CTG_TODAY"="$(date +'%Y%m%d')"
export CTG_TOMUSER="ctg-tomcat"                    # Tomcat service user
export CTG_ASSET="COSMOS"                          # Server/asset name that hosts Tomcat
export CTG_SERVICENAME="tomcat"                    # systemd service name
export CTG_SOURCES=
export CTG_DEPLOY="/usr/data/pbadata/deployments/onpremapps/NAVTIDES"

# Pre-check controls
DISK_PATH="${CTG_RTDATA}"     # Check disk usage where we write backups/artifacts
MAX_USE_PCT=90                # Fail if >= this usage %
PAUSE_SECONDS=300             # When others are logged in, wait this long per cycle
RECHECK_ON_TIMEOUT=1          # 1=recheck again after waiting, 0=proceed after one wait

 # ---------- HELPERS ----------
log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }

require_cmd() {
   for c in "$@"; do 
      command -v "$c" >/dev/null 2>&1 || die "Requied command not found: $c"
   done
}

main() {
  log "Starting NAVTIDES Upgrade pre-checks..."

}
