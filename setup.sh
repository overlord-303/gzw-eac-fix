#!/usr/bin/env bash
set -uo pipefail

# Configuration:
# Edit these if needed.
# Everything else is derived from these values.

STEAM_APP_ID="2479810"
SERVICE_NAME="gzw-eac-fix"
INSTALL_DIR="$HOME/.local/share/gzw-eac-fix"

NOTIFY="false"          # set to true to enable desktop notifications via notify-send
LOG_MAX_LINES="200"     # max lines kept in the log file
POLL_INTERVAL="3"       # seconds between file-exists checks after steam validate
POST_RESTORE_WAIT="2"   # seconds to wait after files reappear before chmod

BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
PREFIX="[${SERVICE_NAME}]"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$INSTALL_DIR/${SERVICE_NAME}.log"

# create install dir early so we can log immediately
mkdir -p "$INSTALL_DIR"

_ts() { date "+%Y-%m-%d %H:%M:%S"; }

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

{
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [Gray Zone Warfare EAC Fix] Setup - $(_ts)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} >> "$LOG_FILE"

# Guard against downloading individual files instead of cloning the repo
for required_dir in scripts init; do
    [[ -d "$REPO_DIR/$required_dir" ]] || die \
        "Directory '$required_dir/' not found in $REPO_DIR. " \
        "Please clone the full repository rather than downloading files individually."
done

command -v steam &>/dev/null || die "'steam' not found in PATH - is Steam installed?"
command -v awk   &>/dev/null || die "'awk' not found"
command -v sed   &>/dev/null || die "'sed' not found"

find_manifest() {
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
        local m="$lib/appmanifest_${STEAM_APP_ID}.acf"
        [[ -f "$m" ]] && echo "$m" && return 0
    done
    return 1
}

MANIFEST_PATH=$(find_manifest) || die \
    "appmanifest_${STEAM_APP_ID}.acf not found. " \
    "Is Gray Zone Warfare installed? Try: steam://install/${STEAM_APP_ID}"

log_info "Found manifest: $MANIFEST_PATH"

# Replaces all @@TOKEN@@ placeholders in a source file and writes the result
# to a destination. This is the single place all config values are baked in.

substitute() {
    local src="$1"
    local dst="$2"
    sed \
        -e "s|@@INSTALL_DIR@@|${INSTALL_DIR}|g"           \
        -e "s|@@STEAM_APP_ID@@|${STEAM_APP_ID}|g"         \
        -e "s|@@MANIFEST_PATH@@|${MANIFEST_PATH}|g"       \
        -e "s|@@SERVICE_NAME@@|${SERVICE_NAME}|g"         \
        -e "s|@@NOTIFY@@|${NOTIFY}|g"                     \
        -e "s|@@LOG_MAX_LINES@@|${LOG_MAX_LINES}|g"       \
        -e "s|@@POLL_INTERVAL@@|${POLL_INTERVAL}|g"       \
        -e "s|@@POST_RESTORE_WAIT@@|${POST_RESTORE_WAIT}|g" \
        "$src" > "$dst"
}

log_info "Installing scripts to $INSTALL_DIR..."

for script in fix.sh watch.sh; do
    substitute "$REPO_DIR/scripts/$script" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
    log_info "  Installed $script"
done

detect_init() {
    [[ -d /run/systemd/system ]] || systemctl --version &>/dev/null 2>&1 && { echo "systemd"; return; }
    command -v rc-service &>/dev/null || [[ -x /sbin/openrc ]]           && { echo "openrc";  return; }
    command -v runit      &>/dev/null || [[ -d /run/runit ]]             && { echo "runit";   return; }
    command -v s6-svscan  &>/dev/null                                    && { echo "s6";      return; }
    echo "unknown"
}

INIT_SYSTEM=$(detect_init)
log_info "Detected init system: $INIT_SYSTEM"

INIT_SRC="$REPO_DIR/init/$INIT_SYSTEM"

case "$INIT_SYSTEM" in

    systemd)
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"

        for unit in "${SERVICE_NAME}.path" "${SERVICE_NAME}.service"; do
            substitute "$INIT_SRC/$unit" "$SYSTEMD_USER_DIR/$unit"
            log_info "  Installed $unit"
        done

        systemctl --user daemon-reload
        systemctl --user enable --now "${SERVICE_NAME}.path"
        log_info "systemd path watcher enabled."
        echo ""
        systemctl --user status "${SERVICE_NAME}.path" --no-pager
        echo ""
        log_info "Logs: journalctl --user -u ${SERVICE_NAME}.service"
        log_info "      or: $LOG_FILE"
        ;;

    openrc)
        command -v inotifywait &>/dev/null || \
            log_warn "inotifywait not found - install inotify-tools"

        XDG_AUTOSTART_DIR="$HOME/.config/autostart"
        mkdir -p "$XDG_AUTOSTART_DIR"
        substitute "$INIT_SRC/${SERVICE_NAME}.desktop" \
            "$XDG_AUTOSTART_DIR/${SERVICE_NAME}.desktop"
        log_info "XDG autostart entry written."
        log_warn "Watcher starts on next desktop login."
        log_info "Logs: $LOG_FILE"
        ;;

    runit)
        command -v inotifywait &>/dev/null || \
            log_warn "inotifywait not found - install inotify-tools"

        SV_DIR="$HOME/sv/${SERVICE_NAME}"
        mkdir -p "$SV_DIR/log"
        substitute "$INIT_SRC/run"     "$SV_DIR/run"
        substitute "$INIT_SRC/log/run" "$SV_DIR/log/run"
        chmod +x "$SV_DIR/run" "$SV_DIR/log/run"
        mkdir -p "$INSTALL_DIR/log"
        log_info "Runit service written to $SV_DIR"
        log_warn "Link it into your supervision tree to activate, e.g.:"
        log_warn "  ln -s $SV_DIR ~/.local/share/runit/sv/${SERVICE_NAME}  (Void Linux)"
        log_info "Logs: $INSTALL_DIR/log/"
        ;;

    s6)
        command -v inotifywait &>/dev/null || \
            log_warn "inotifywait not found - install inotify-tools"

        S6_DIR="$HOME/.config/s6/sv/${SERVICE_NAME}"
        mkdir -p "$S6_DIR"
        substitute "$INIT_SRC/run" "$S6_DIR/run"
        chmod +x "$S6_DIR/run"
        log_info "s6 service written to $S6_DIR"
        log_warn "Link into your scan directory and reload, e.g.:"
        log_warn "  ln -s $S6_DIR \$S6_SCAN_DIR/${SERVICE_NAME}"
        log_warn "  s6-svscanctl -a \$S6_SCAN_DIR"
        log_info "Logs: $LOG_FILE"
        ;;

    *)
        command -v inotifywait &>/dev/null || \
            log_warn "inotifywait not found - install inotify-tools"

        XDG_AUTOSTART_DIR="$HOME/.config/autostart"
        mkdir -p "$XDG_AUTOSTART_DIR"

        # No matching init/ template - write a generic desktop entry directly
        cat > "$XDG_AUTOSTART_DIR/${SERVICE_NAME}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=GZW EAC Fix Watcher
Exec=${INSTALL_DIR}/watch.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
        log_warn "Unrecognized init system - fell back to XDG autostart."
        log_warn "Watcher starts on next desktop login."
        log_info "Logs: $LOG_FILE"
        ;;
esac

echo ""
log_info "Setup complete."
log_info "Running initial fix..."
bash "$INSTALL_DIR/fix.sh"
