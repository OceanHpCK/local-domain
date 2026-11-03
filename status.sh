#!/usr/bin/env bash
# ==============================================================================
# vps-local-dns - KIỂM TRA TÌNH TRẠNG hệ thống sau khi cài
#
# Chạy một lệnh để biết mọi thứ có sống không:
#   ./status.sh                     # dùng cấu hình trong .env của kit
#   ./status.sh --app-name my-app   # service WebApp đặt tên khác
#   ./status.sh --port 5000         # WebApp chạy ở cổng khác (mặc định 80)
#
# Không cần sudo (trừ khi muốn xem ss -lnp đầy đủ).
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

APP_NAME=""
APP_PORT="${APP_PORT:-80}"
DOMAIN=""
LAN_IP=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help)
            echo "Dùng: ./status.sh [--app-name <tên-service>] [--port <cổng-webapp>]"
            exit 0
            ;;
        --app-name) [ $# -ge 2 ] || { echo "[x] --app-name thiếu giá trị" >&2; exit 1; }; APP_NAME="$2"; shift ;;
        --port) [ $# -ge 2 ] || { echo "[x] --port thiếu giá trị" >&2; exit 1; }; APP_PORT="$2"; shift ;;
        *) echo "[x] Tùy chọn lạ: $1" >&2; exit 1 ;;
    esac
    shift
done

# Đọc cấu hình kit
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi
DOMAIN="${VPS_HOSTNAME:-${DOMAIN:-vps.vn}}"
LAN_IP="${LAN_IP:-}"

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok() { c "92" "  [✓] $*"; }
bad() { c "91" "  [✗] $*"; }
warn() { c "93" "  [!] $*"; }
accept() { c "96" "\n== $* =="; }
# Màu chỉ bật khi stdout là terminal (để không rác ký tự thoát khi thu output).
if [ ! -t 1 ]; then
    c() { printf '%s\n' "$2"; }
    accept() { printf '\n== %s ==\n' "$*"; }
fi

FAILED=0
# ------------------------------------------------------------------------------
# 1. DNS server (Pi-hole)
# ------------------------------------------------------------------------------
accept "Pi-hole / DNS server"

NATIVE=0
if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
    NATIVE=1
    ok "pihole-FTL (native systemd) đang chạy"
else
    warn "pihole-FTL (native) không chạy - nếu bạn cài bản Docker thì bình thường"
fi

DOCKER=0
if grep -qx 'pihole' <(docker ps --format '{{.Names}}' 2>/dev/null); then
    DOCKER=1
    ok "Container pihole (Docker) đang chạy"
fi

if [ "$NATIVE" -eq 0 ] && [ "$DOCKER" -eq 0 ]; then
    bad "Không thấy Pi-hole native lẫn Docker nào đang chạy"
    warn "      thử: sudo systemctl start pihole-FTL, hoặc docker compose up -d"
    FAILED=1
fi

# Cổng 53 bind ở đâu? (cột 4 của ss = địa chỉ local)
BINDS="$(ss -lnu 2>/dev/null | awk '/:53[[:space:]]/ {print $4}' | sort -u | tr '\n' ' ')"
if [ -n "$BINDS" ]; then
    ok "Cổng 53/udp lắng nghe tại: $BINDS"
    case "$BINDS" in
        *" 0.0.0.0"*|*"[::] "*)
            if [ "$NATIVE" -eq 1 ]; then
                warn "Pi-hole native đang bind wildcard (0.0.0.0:53) - đã dùng làm DNS của host."
            else
                warn "Pi-hole Docker bind 0.0.0.0:53 (FTLCONF_dns_listeningMode=ALL) - đúng thiết kế cho bridge network."
            fi
            ;;
        *)
            ok "Không bind wildcard: systemd-resolved stub (127.0.0.53) và Tailscale không bị đụng."
            ;;
    esac
else
    bad "Không thấy cổng 53/udp nào đang lắng nghe"
    warn "      thử: sudo systemctl status pihole-FTL"
    FAILED=1
fi

# ------------------------------------------------------------------------------
# 2. Phân giải DNS
# ------------------------------------------------------------------------------
accept "Phân giải DNS cho $DOMAIN"
if [ -z "$LAN_IP" ]; then
    LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
fi
if grep -qx "$LAN_IP" <(dig +short +time=2 +tries=1 "@$LAN_IP" "$DOMAIN" 2>/dev/null); then
    ok "Pi-hole trả lời: $DOMAIN -> $LAN_IP (hỏi trực tiếp @$LAN_IP)"
else
    bad "Pi-hole KHÔNG trả lời đúng @$LAN_IP cho $DOMAIN"
    warn "      thử: docker compose logs --tail=50 pihole, hoặc journalctl -u pihole-FTL -n 50"
    FAILED=1
fi
if grep -q "$LAN_IP" <(resolvectl query "$DOMAIN" 2>/dev/null); then
    ok "Host (systemd-resolved) phân giải được $DOMAIN (split-DNS hoạt động)"
else
    bad "Host chưa phân giải được $DOMAIN qua systemd-resolved"
    warn "      thử: resolvectl flush-caches; kiểm tra /etc/systemd/resolved.conf.d/99-vps-local-domain.conf"
    FAILED=1
fi
if [ -f /etc/systemd/resolved.conf.d/99-vps-local-domain.conf ]; then
    ok "File split-DNS tồn tại: /etc/systemd/resolved.conf.d/99-vps-local-domain.conf"
else
    warn "Chưa có file split-DNS /etc/systemd/resolved.conf.d/99-vps-local-domain.conf"
fi

# Phân giải Internet vẫn thông? (upstream Pi-hole hoạt động)
EXT="$(dig +short +time=3 +tries=1 "@$LAN_IP" one.one.one.one 2>/dev/null | head -1)"
if [ -n "$EXT" ]; then
    ok "Pi-hole hỏi ra Internet được (upstream trả lời: $EXT)"
else
    bad "Pi-hole không hỏi ra Internet được - LAN có thể mất DNS outbound"
    warn "      thử: kiểm tra UPSTREAM_DNS trong .env, và curl -I https://1.1.1.1"
    FAILED=1
fi

# ------------------------------------------------------------------------------
# 3. WebApp
# ------------------------------------------------------------------------------
accept "WebApp"

SERVICE=""
for cand in "$APP_NAME" "vps-commander"; do
    [ -n "$cand" ] || continue
    if grep -q "^$cand\.service" <(systemctl list-unit-files 2>/dev/null); then
        SERVICE="$cand"
        break
    fi
done
# Fallback: dò unit theo Description có "tên miền nội bộ" (do kit tạo)
if [ -z "$SERVICE" ]; then
    for f in /etc/systemd/system/*.service; do
        [ -f "$f" ] || continue
        if grep -qE '^(Description=.*t[êe]n mi[ềe]n n[ộ]i b[ộ]|Description=WebApp)' "$f"; then
            SERVICE="$(basename "$f" .service)"
            break
        fi
    done
fi

if [ -n "$SERVICE" ]; then
    if systemctl is-active --quiet "$SERVICE"; then
        ok "Service '$SERVICE' đang chạy"
    else
        bad "Service '$SERVICE' KHÔNG chạy"
        warn "      thử: sudo systemctl start $SERVICE; journalctl -u $SERVICE -n 50"
        FAILED=1
    fi
else
    warn "Không dò được service systemd của WebApp (chạy --app-name nếu đặt tên khác)"
fi

if curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$APP_PORT/healthz" 2>/dev/null; then
    ok "WebApp trả lời 200 tại 127.0.0.1:$APP_PORT (/healthz)"
else
    STATUS="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/healthz" 2>/dev/null)"
    if [ "$STATUS" != "000" ] && [ -n "$STATUS" ]; then
        warn "WebApp trả lời HTTP $STATUS (không 200) tại 127.0.0.1:$APP_PORT/healthz"
    else
        bad "WebApp KHÔNG trả lời tại cổng $APP_PORT"
        STATUS2="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/healthz 2>/dev/null)"
        if [ "$STATUS2" != "000" ] && [ -n "$STATUS2" ]; then
            warn "      thử: chạy ./status.sh --port 5000 (WebApp đang ở cổng 5000)"
        fi
        FAILED=1
    fi
fi

# Hostname truy cập được từ chính máy này?
if curl -fsS --max-time 5 -o /dev/null "http://$DOMAIN/healthz" 2>/dev/null \
    || { [ "$APP_PORT" != "80" ] && curl -fsS --max-time 5 -o /dev/null "http://$DOMAIN:$APP_PORT/healthz"; }; then
    ok "Truy cập http://$DOMAIN được (từ chính máy này)"
else
    warn "Chưa truy cập được http://$DOMAIN từ máy này (thiết bị khác phải dùng $LAN_IP làm DNS)"
fi

# ------------------------------------------------------------------------------
# 4. HTTPS (nếu đã cài)
# ------------------------------------------------------------------------------
accept "HTTPS (nếu cài)"
if grep -qE ':443[[:space:]]' <(ss -ltn 2>/dev/null); then
    if curl -fsS --max-time 5 -o /dev/null "https://$DOMAIN/healthz" 2>/dev/null; then
        ok "HTTPS hoạt động: https://$DOMAIN"
    elif curl -kfsS --max-time 5 -o /dev/null "https://$DOMAIN/healthz" 2>/dev/null; then
        warn "HTTPS trả lời -k được nhưng máy này chưa tin chứng chỉ (chưa import root CA?)"
        warn "      thử: chạy setup-https.sh lại để xem bước 'caddy trust'"
        FAILED=1
    else
        bad "Cổng 443 mở nhưng https://$DOMAIN không trả lời"
        warn "      thử: systemctl status caddy"
        FAILED=1
    fi
else
    warn "Chưa có HTTPS (chưa chạy setup-https.sh) - bình thường nếu cố tình dùng HTTP"
fi

# ------------------------------------------------------------------------------
# Tổng kết
# ------------------------------------------------------------------------------
c "92" "  ══════════════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
    ok "TẤT CẢ CÁC KIỂM TRA CHÍNH ĐỀU ĐẠT"
else
    c "93" "  Còn mục [✗] cần xử lý - xem gợi ý in sẵn phía trên."
fi
echo
echo "  Mẹo truy cập từ thiết bị khác trong LAN:"
echo "   - Đặt DNS của thiết bị = $LAN_IP (hoặc trỏ DNS DHCP trên router về IP này)."
echo "   - Tắt 'Secure DNS / DNS-over-HTTPS' trong trình duyệt."
exit "$FAILED"
