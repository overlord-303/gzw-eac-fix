#!/usr/bin/env bash
set -uo pipefail

# set by setup.sh via @@TOKEN@@ substitution

STEAM_APP_ID="@@STEAM_APP_ID@@"
SERVICE_NAME="@@SERVICE_NAME@@"
INSTALL_DIR="@@INSTALL_DIR@@"
NOTIFY="@@NOTIFY@@"
LOG_MAX_LINES="@@LOG_MAX_LINES@@"
POLL_INTERVAL="@@POLL_INTERVAL@@"
POST_RESTORE_WAIT="@@POST_RESTORE_WAIT@@"

GAME_SUBPATH="common/Gray Zone Warfare/GZW/Content/SKALLA/PrebuildWorldData/World/cache"
MANIFEST_NAME="appmanifest_${STEAM_APP_ID}.acf"

EAC_FILES=(
    "0xb9af63cee2e43b6c_0x3cb3b3354fb31606.dat"
    "0xaf497c273f87b6e4_0x7a22fc105639587d.dat"
)

LOG_FILE="$INSTALL_DIR/${SERVICE_NAME}.log"
STATE_FILE="$INSTALL_DIR/.last_known_state"

# ─── logging ──────────────────────────────────────────────────────────────────

BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
PREFIX="[${SERVICE_NAME}]"

mkdir -p "$INSTALL_DIR"

_ts() { date "+%Y-%m-%d %H:%M:%S"; }

{
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [Gray Zone Warfare EAC Fix] - $(_ts)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} >> "$LOG_FILE"

# Trim log to LOG_MAX_LINES
_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
if (( _lines > LOG_MAX_LINES )); then
    tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

log_info() {
    local msg="$1"
    printf "${BLUE}${PREFIX}${NC} %s\n" "$msg"
    echo "[$(_ts)] [INFO]  $msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="$1"
    printf "${BLUE}${PREFIX}${NC} ⚠ %s\n" "$msg"
    echo "[$(_ts)] [WARN]  $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="$1"
    printf "${RED}${PREFIX} Error: %s${NC}\n" "$msg" >&2
    echo "[$(_ts)] [ERROR] $msg" >> "$LOG_FILE"
}

die() { log_error "$1"; exit 1; }

_notify() {
    [[ "$NOTIFY" != "true" ]] && return
    command -v notify-send &>/dev/null || return
    notify-send -a "$SERVICE_NAME" "$1" "$2" 2>/dev/null || true
}

# ─── auto-detect steam library ────────────────────────────────────────────────

find_steam_library() {
    local bases=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    )

    declare -A seen
    local all=()

    for base in "${bases[@]}"; do
        [[ ! -d "$base/steamapps" ]] && continue
        local real; real=$(realpath "$base" 2>/dev/null || echo "$base")
        [[ "${seen[$real]+x}" ]] && continue
        seen["$real"]=1
        all+=("$base/steamapps")

        local vdf="$base/steamapps/libraryfolders.vdf"
        [[ ! -f "$vdf" ]] && continue
        while IFS= read -r line; do
            local p; p=$(awk -F'"' '/"path"/{print $4}' <<< "$line")
            [[ -n "$p" && -d "$p/steamapps" ]] && all+=("$p/steamapps")
        done < "$vdf"
    done

    [[ ${#all[@]} -eq 0 ]] && return 1

    for lib in "${all[@]}"; do
        [[ -d "$lib/$GAME_SUBPATH" ]] && echo "$lib" && return 0
    done
    return 1
}

STEAM_APPS=$(find_steam_library) || die "Gray Zone Warfare not found in any Steam library."
CACHE_DIR="$STEAM_APPS/$GAME_SUBPATH"
MANIFEST="$STEAM_APPS/$MANIFEST_NAME"

log_info "GZW found at: $CACHE_DIR"

# ─── build state detection ────────────────────────────────────────────────────
#
# Fingerprint = buildid + all InstalledDepots manifest IDs (sorted).
# Depot manifests rotate on every content update even if the buildid doesn't.
# If fingerprint matches last run, skip the fix — nothing was actually updated.

read_game_state() {
    local acf="$1"
    local buildid
    buildid=$(grep -m1 '"buildid"' "$acf" | awk -F'"' '{print $4}')

    local depots
    depots=$(awk '
        /"InstalledDepots"/ { in_depots=1; depth=0; next }
        in_depots && /\{/   { depth++ }
        in_depots && /\}/   { depth--; if (depth < 0) in_depots=0 }
        in_depots && /"manifest"/ { gsub(/"/, ""); print $2 }
    ' "$acf" | sort | paste -sd ':')

    [[ -z "$buildid" || -z "$depots" ]] && return 1
    echo "${buildid}:${depots}"
}

[[ -f "$MANIFEST" ]] || die "Steam manifest not found: $MANIFEST"

CURRENT_STATE=$(read_game_state "$MANIFEST") \
    || die "Could not parse build ID or depot manifests from ACF."

LAST_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")

if [[ "$CURRENT_STATE" == "$LAST_STATE" ]]; then
    log_info "No update detected (state unchanged). Skipping."
    exit 0
fi

if [[ -n "$LAST_STATE" ]]; then
    log_info "Update detected."
    log_info "  Previous: $LAST_STATE"
    log_info "  Current:  $CURRENT_STATE"
else
    log_info "No previous state — running fix and recording baseline."
fi

# ─── fix ──────────────────────────────────────────────────────────────────────

_notify -i dialog-information "Applying EAC cache fix..."

log_info "Flushing disk before delete..."
sync

log_info "Removing EAC cache files..."
for f in "${EAC_FILES[@]}"; do
    rm -f "$CACHE_DIR/$f"
    log_info "  Removed: $f"
done

log_info "Triggering Steam verify integrity (app $STEAM_APP_ID)..."
steam "steam://validate/$STEAM_APP_ID"

log_info "Waiting for Steam to restore files..."
for f in "${EAC_FILES[@]}"; do
    while [[ ! -f "$CACHE_DIR/$f" ]]; do
        sleep "$POLL_INTERVAL"
    done
    log_info "  Restored: $f"
done

log_info "Flushing disk after restore..."
sync

sleep "$POST_RESTORE_WAIT"

log_info "Setting files read-only..."
for f in "${EAC_FILES[@]}"; do
    chmod 400 "$CACHE_DIR/$f"
    log_info "  chmod 400: $f"
done

echo "$CURRENT_STATE" > "$STATE_FILE"

_notify -i dialog-information "EAC cache fix applied."
log_info "Done."
