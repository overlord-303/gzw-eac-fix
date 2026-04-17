#!/usr/bin/env bash
set -uo pipefail

SERVICE_NAME="gzw-eac-fix"
INSTALL_DIR="$HOME/.local/share/gzw-eac-fix"

BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
PREFIX="[${SERVICE_NAME}]"

log_info() { printf "${BLUE}${PREFIX}${NC} %s\n" "$1"; }
log_warn() { printf "${BLUE}${PREFIX}${NC} ⚠ %s\n" "$1"; }
log_error(){ printf "${RED}${PREFIX} Error: %s${NC}\n" "$1" >&2; }
die()      { log_error "$1"; exit 1; }

echo ""
printf "${BLUE}${PREFIX}${NC} This will remove:\n"
printf "  %s\n" "$INSTALL_DIR"
printf "  systemd units, autostart entries, or sv dirs created by setup.sh\n"
echo ""
read -r -p "Continue? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { log_info "Aborted."; exit 0; }
echo ""

removed=0

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

if [[ -f "$SYSTEMD_USER_DIR/${SERVICE_NAME}.path" || \
      -f "$SYSTEMD_USER_DIR/${SERVICE_NAME}.service" ]]; then
    log_info "Removing systemd units..."

    systemctl --user stop "${SERVICE_NAME}.path" 2>/dev/null \
        && log_info "  Stopped ${SERVICE_NAME}.path" || true
    systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true

    systemctl --user disable "${SERVICE_NAME}.path" 2>/dev/null \
        && log_info "  Disabled ${SERVICE_NAME}.path" || true

    for wants_dir in \
        "$SYSTEMD_USER_DIR/default.target.wants" \
        "$SYSTEMD_USER_DIR/multi-user.target.wants"; do
        local_link="$wants_dir/${SERVICE_NAME}.path"
        if [[ -L "$local_link" ]]; then
            rm -f "$local_link"
            log_info "  Removed stale symlink: $local_link"
        fi
    done

    for unit in "${SERVICE_NAME}.path" "${SERVICE_NAME}.service"; do
        if [[ -f "$SYSTEMD_USER_DIR/$unit" ]]; then
            rm -f "$SYSTEMD_USER_DIR/$unit"
            log_info "  Removed $SYSTEMD_USER_DIR/$unit"
            (( removed++ )) || true
        fi
    done

    systemctl --user daemon-reload
    log_info "  Daemon reloaded."
fi


DESKTOP_FILE="$HOME/.config/autostart/${SERVICE_NAME}.desktop"
if [[ -f "$DESKTOP_FILE" ]]; then
    log_info "Removing XDG autostart entry..."
    rm -f "$DESKTOP_FILE"
    log_info "  Removed $DESKTOP_FILE"
    (( removed++ )) || true
fi

RUNIT_SV_DIR="$HOME/sv/${SERVICE_NAME}"
if [[ -d "$RUNIT_SV_DIR" ]]; then
    log_info "Removing runit service..."
    sv stop "$SERVICE_NAME" 2>/dev/null || true
    rm -rf "$RUNIT_SV_DIR"
    log_info "  Removed $RUNIT_SV_DIR"
    (( removed++ )) || true
fi

S6_SV_DIR="$HOME/.config/s6/sv/${SERVICE_NAME}"
if [[ -d "$S6_SV_DIR" ]]; then
    log_info "Removing s6 service..."
    s6-svc -d "$S6_SV_DIR" 2>/dev/null || true
    rm -rf "$S6_SV_DIR"
    log_info "  Removed $S6_SV_DIR"
    (( removed++ )) || true
fi

if [[ -d "$INSTALL_DIR" ]]; then
    log_info "Removing install directory..."
    rm -rf "$INSTALL_DIR"
    log_info "  Removed $INSTALL_DIR"
    (( removed++ )) || true
fi

echo ""
if (( removed > 0 )); then
    log_info "Uninstall complete."
else
    log_warn "Nothing found to remove - was setup.sh ever run?"
fi
