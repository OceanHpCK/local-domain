#!/usr/bin/env bash
# ==============================================================================
# vps-local-dns - GỠ CÀI ĐẶT (bản native và/hoặc Docker)
#
# Gỡ lần lượt, an toàn theo thứ tự:
#   1. Service WebApp (systemd) - mặc định "vps-commander", đổi bằng --app-name.
#   2. Pi-hole:
#        - native : systemctl disable pihole-FTL + `pihole uninstall`
#        - docker : docker compose down (ở thư mục kit)
#   3. Split-DNS trong systemd-resolved + khôi phục /etc/resolv.conf.
#   4. (Tùy chọn --remove-ufw) xoá rule ufw đã mở khi cài.
#
# Dữ liệu còn lại: Pi-hole native lưu ở /etc/pihole, /var/log/pihole -
# `pihole uninstall` tự gỡ phần lớn; cờ --purge-pihole xoá nốt phần sót lại.
# File .env của kit KHÔNG bị xoá tự động (chứa mật khẩu, do bạn giữ).
#
# Dùng:
#   sudo ./uninstall.sh                     # gỡ cả native lẫn docker (nếu có)
#   sudo ./uninstall.sh --app-name my-app   # service WebApp đặt tên khác
#   sudo ./uninstall.sh --yes               # không hỏi xác nhận
#   sudo ./uninstall.sh --remove-ufw        # xoá luôn rule 53/80/5000/443
#   sudo ./uninstall.sh --purge-pihole      # xoá nốt dữ liệu /etc/pihole...
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="${VPS_APP_NAME:-vps-commander}"
ASSUME_YES=0
PURGE_PIHOLE=0
REMOVE_UFW=0

show_help() {
    sed -n '/^# vps-local-dns - GỠ CÀI/,/^# ==============================================================================$/p' "$0" \
        | tail -n +2 | head -n -1 | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) show_help; exit 0 ;;
        --app-name) [ $# -ge 2 ] || { echo "[x] --app-name thiếu giá trị" >&2; exit 1; }; APP_NAME="$2"; shift ;;
        --app-name=*) APP_NAME="${1#*=}" ;;
        -y | --yes) ASSUME_YES=1 ;;
        --purge-pihole) PURGE_PIHOLE=1 ;;
        --remove-ufw) REMOVE_UFW=1 ;;
        *) echo "[x] Tùy chọn lạ: $1" >&2; exit 1 ;;
    esac
    shift
done

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c "96" "[i] $*"; }
ok() { c "92" "[✓] $*"; }
warn() { c "93" "[!] $*"; }
die() { c "91" "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    warn "Cần quyền root. Đang chạy lại bằng sudo..."
    exec sudo -E bash "$0" "$@"
fi

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    read -r -p "$1 [y/N] " ans
    [[ "${ans:-n}" =~ ^[yY]$ ]]
}

# Đọc cấu hình kit (LAN_IP, DOMAIN) nếu có
DOMAIN=""
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi
DOMAIN="${VPS_HOSTNAME:-vps.vn}"

echo
c "93" "══════════════════════════════════════════════════════════"
warn "SẮP GỠ CÀI ĐẶT vps-local-dns (tên miền nội bộ: $DOMAIN)"
echo "    - Service WebApp : $APP_NAME (nếu có)"
echo "    - Pi-hole        : native và/hoặc Docker (nếu có)"
echo "    - Split-DNS      : /etc/systemd/resolved.conf.d/*vps-local*"
echo "    - DNS của host   : dùng lại systemd-resolved như trước khi cài"
echo "══════════════════════════════════════════════════════════"
confirm "Tiếp tục?" || die "Đã hủy."

# ------------------------------------------------------------------------------
# 1. Service WebApp (systemd)
# ------------------------------------------------------------------------------
for unit in "$APP_NAME" vps-commander; do
    if [ -f "/etc/systemd/system/$unit.service" ]; then
        info "Gỡ service $unit..."
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit.service"
    fi
done
systemctl daemon-reload || true
ok "Đã gỡ service WebApp."

# ------------------------------------------------------------------------------
# 2a. Pi-hole native
# ------------------------------------------------------------------------------
if command -v pihole >/dev/null 2>&1 && grep -q '^pihole-FTL\.service' <(systemctl list-unit-files 2>/dev/null); then
    if confirm "Gỡ Pi-hole native (pihole uninstall)?"; then
        info "Chạy pihole uninstall (chấp nhận hộp thoại mặc định)..."
        systemctl disable --now pihole-FTL 2>/dev/null || true
        yes | pihole uninstall >/dev/null 2>&1 || warn "pihole uninstall trả lỗi - kiểm tra: pihole uninstall"
        # Xoá nốt dữ liệu nếu yêu cầu
        if [ "$PURGE_PIHOLE" -eq 1 ]; then
            rm -rf /etc/pihole /etc/pihole-FTL* /var/log/pihole /var/log/pihole-* \
                   /usr/bin/pihole /usr/bin/pihole-FTL /opt/pihole \
                   /etc/systemd/system/pihole-FTL.service /etc/cron.d/pihole
            systemctl daemon-reload || true
            ok "Đã xoá dữ liệu Pi-hole (/etc/pihole, /var/log/pihole, ...)."
        else
            warn "Dữ liệu Pi-hole còn lại ở /etc/pihole, /var/log/pihole."
        fi
        ok "Đã gỡ Pi-hole native."
    fi
fi

# ------------------------------------------------------------------------------
# 2b. Pi-hole Docker (nếu dùng)
# ------------------------------------------------------------------------------
if grep -qx 'pihole' <(docker ps -a --format '{{.Names}}' 2>/dev/null); then
    if confirm "Gỡ Pi-hole Docker (docker compose down)?"; then
        COMPOSE=()
        if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose); else COMPOSE=(docker-compose); fi
        ( cd "$SCRIPT_DIR" && "${COMPOSE[@]}" down ) || true
        ok "Đã gỡ container Pi-hole (dữ liệu ./etc-pihole vẫn còn trong kit)."
    fi
fi
# ------------------------------------------------------------------------------
# 3. Split-DNS + khôi phục DNS của host
# ------------------------------------------------------------------------------
if [ -f /etc/systemd/resolved.conf.d/99-vps-local-domain.conf ] \
    || [ -f /etc/systemd/resolved.conf.d/90-pi-hole-disable-stub-listener.conf ]; then
    info "Xoá split-DNS của kit khỏi systemd-resolved..."
    rm -f /etc/systemd/resolved.conf.d/99-vps-local-domain.conf \
          /etc/systemd/resolved.conf.d/90-pi-hole-disable-stub-listener.conf
fi
if [ -e /etc/resolv.conf ] && ! grep -q 'stub-resolv.conf' <(readlink /etc/resolv.conf 2>/dev/null); then
    info "Khôi phục /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf..."
    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl restart systemd-resolved || true
fi
resolvectl flush-caches 2>/dev/null || true
ok "DNS của host đã dùng lại systemd-resolved (127.0.0.53)."

# ------------------------------------------------------------------------------
# 4. ufw (tùy chọn)
# ------------------------------------------------------------------------------
if [ "$REMOVE_UFW" -eq 1 ] && command -v ufw >/dev/null 2>&1; then
    info "Xoá rule ufw do kit thêm..."
    for rule in "53/tcp" "53/udp" "80/tcp" "5000/tcp" "443/tcp" "8080/tcp"; do
        ufw delete allow "$rule" >/dev/null 2>&1 || true
    done
    ok "Đã xoá rule ufw (53, 80, 5000, 443, 8080)."
fi

# ------------------------------------------------------------------------------
# 5. Tổng kết
# ------------------------------------------------------------------------------
echo
c "92" "══════════════════════════════════════════════════════════"
ok "Gỡ cài đặt xong."
echo "  Còn lại (tự quyết định giữ hay xoá):"
echo "   - $SCRIPT_DIR/.env         (mật khẩu admin — giữ nếu muốn cài lại)"
echo "   - $SCRIPT_DIR/etc-pihole/  (dữ liệu Pi-hole Docker)"
if [ "$PURGE_PIHOLE" -ne 1 ]; then
    echo "   - /etc/pihole, /var/log/pihole  (Pi-hole native, nếu chưa gỡ)"
    echo "     -> xoá nốt: sudo ./uninstall.sh --purge-pihole"
fi
echo "══════════════════════════════════════════════════════════"
