#!/usr/bin/env bash
set -uo pipefail

# set by setup.sh via @@TOKEN@@ substitution

SERVICE_NAME="@@SERVICE_NAME@@"
INSTALL_DIR="@@INSTALL_DIR@@"
MANIFEST_PATH="@@MANIFEST_PATH@@"


LOG_FILE="$INSTALL_DIR/${SERVICE_NAME}.log"
FIX_SCRIPT="$INSTALL_DIR/fix.sh"

BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
PREFIX="[${SERVICE_NAME}]"

mkdir -p "$INSTALL_DIR"

_ts() { date "+%Y-%m-%d %H:%M:%S"; }

log_info() {
    local msg="$1"
    printf "${BLUE}${PREFIX}${NC} %s\n" "$msg"
    echo "[$(_ts)] [INFO]  $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="$1"
    printf "${RED}${PREFIX} Error: %s${NC}\n" "$msg" >&2
    echo "[$(_ts)] [ERROR] $msg" >> "$LOG_FILE"
}

die() { log_error "$1"; exit 1; }

command -v inotifywait &>/dev/null \
    || die "inotifywait not found - install inotify-tools"

[[ -f "$MANIFEST_PATH" ]] \
    || die "Manifest not found: $MANIFEST_PATH - was the game uninstalled or moved? Re-run setup.sh."

[[ -x "$FIX_SCRIPT" ]] \
    || die "fix.sh not found or not executable at $FIX_SCRIPT - re-run setup.sh."

log_info "Watching: $MANIFEST_PATH"

inotifywait -m -e close_write "$MANIFEST_PATH" 2>/dev/null \
    | while read -r _dir _event _file; do
        log_info "Manifest changed — invoking fix..."
        bash "$FIX_SCRIPT"
    done
