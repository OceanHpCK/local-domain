#!/usr/bin/env bash
# ==============================================================================
# vps-local-dns - HTTPS NỘI BỘ bằng Caddy (chứng chỉ tự ký qua CA nội bộ)
#
# Làm gì:
#   1. Cài Caddy (repo chính thức cloudsmith).
#   2. Viết Caddyfile: https://$DOMAIN -> reverse_proxy 127.0.0.1:$APP_PORT,
#      dùng `tls internal` (CA nội bộ của Caddy: root 10 năm, cert 12h tự gia hạn).
#   3. Trust root CA trên máy này: copy root.crt -> /usr/local/share/ca-certificates
#      + update-ca-certificates (+ certutil cho Chrome/Chromium nếu có).
#   4. Export root.crt ra ./certs/ để chép sang máy/điện thoại khác import.
#   5. Đặt VPS_COOKIE_SECURE=true trong .env của app (cookie chỉ gửi qua HTTPS).
#   6. Mở ufw cổng 443 (tcp/udp - HTTP/3), 80/tcp cho redirect.
#
# Các thiết bị KHÁC trong LAN muốn vào https://$DOMAIN mà không cảnh báo:
#   chép file certs/root.crt về máy rồi import vào trình duyệt/HĐH
#   (hướng dẫn in ở cuối script, và trong README.md phần HTTPS).
#
# Dùng:
#   sudo ./setup-https.sh                       # backend = cổng 80, domain từ .env
#   sudo ./setup-https.sh --port 5000           # backend chạy ở cổng khác
#   sudo ./setup-https.sh --domain vps.home     # đổi domain
#   sudo ./setup-https.sh --app-dir ~/du-an      # app nằm chỗ khác
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLI_DOMAIN="" CLI_APP_PORT="" CLI_APP_DIR=""

usage() {
    cat <<'EOF'
HTTPS nội bộ bằng Caddy (chứng chỉ tự ký qua CA nội bộ của Caddy)

Dùng:
  sudo ./setup-https.sh                       # backend = cổng 80, domain từ .env
  sudo ./setup-https.sh --port 5000           # backend chạy ở cổng khác
  sudo ./setup-https.sh --domain vps.home     # đổi domain
  sudo ./setup-https.sh --app-dir ~/du-an     # app nằm chỗ khác

Script làm:
  1. Cài Caddy (repo chính thức).
  2. Caddyfile: https://<domain> -> reverse_proxy 127.0.0.1:<port>, dùng tls internal.
  3. Import root CA vào trust store máy này + Chrome/Chromium (NSS) nếu có certutil.
  4. Xuất certs/root.crt để chép sang thiết bị khác import.
  5. Đặt VPS_COOKIE_SECURE=true trong .env của app.
  6. Mở ufw 443/tcp + 443/udp (HTTP/3).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --port) [ $# -ge 2 ] || { echo "[x] --port thiếu giá trị" >&2; exit 1; }; CLI_APP_PORT="$2"; shift ;;
        --domain) [ $# -ge 2 ] || { echo "[x] --domain thiếu giá trị" >&2; exit 1; }; CLI_DOMAIN="$2"; shift ;;
        --app-dir) [ $# -ge 2 ] || { echo "[x] --app-dir thiếu giá trị" >&2; exit 1; }; CLI_APP_DIR="$2"; shift ;;
        *) echo "[x] Tùy chọn lạ: $1" >&2; usage >&2; exit 1 ;;
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

# Cấu hình: ưu tiên CLI > .env của kit
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi
LAN_IP="${LAN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')}"
DOMAIN="${CLI_DOMAIN:-${VPS_HOSTNAME:-vps.vn}}"
APP_PORT="${CLI_APP_PORT:-${APP_PORT:-80}}"
[ -n "$LAN_IP" ] || die "Không dò được IP LAN (LAN_IP trong .env cũng trống)."

# Thư mục app (để đặt VPS_COOKIE_SECURE cho đúng file .env của app)
ROOT_DIR="${CLI_APP_DIR:-}"
if [ -z "$ROOT_DIR" ]; then
    for cand in "$SCRIPT_DIR/../vps-commander" "$SCRIPT_DIR/../../vps-commander" "$SCRIPT_DIR/.."; do
        if [ -f "$cand/.env" ]; then ROOT_DIR="$(cd "$cand" && pwd)"; break; fi
    done
fi

# ------------------------------------------------------------------------------
# 1. Cài Caddy (repo chính thức)
# ------------------------------------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
    info "Cài Caddy từ repo chính thức..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl ca-certificates gnupg >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y >/dev/null
    apt-get install -y caddy >/dev/null
    ok "Đã cài Caddy ($(caddy version 2>/dev/null || echo '?'))."
else
    ok "Caddy đã có sẵn ($(caddy version 2>/dev/null || echo '?'))."
fi

# ------------------------------------------------------------------------------
# 2. Caddyfile: HTTPS cho DOMAIN -> backend 127.0.0.1:APP_PORT
# ------------------------------------------------------------------------------
info "Viết Caddyfile cho https://$DOMAIN -> 127.0.0.1:$APP_PORT..."
if [ -f /etc/caddy/Caddyfile ]; then
    cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
    warn "Đã backup Caddyfile cũ vào /etc/caddy/Caddyfile.bak.*"
fi
mkdir -p /etc/caddy
cat >/etc/caddy/Caddyfile <<EOF
# Do setup-https.sh của kit vps-local-dns tạo / cập nhật.
# HTTPS nội bộ: Caddy tự quản CA (tls internal) - không cần Let's Encrypt,
# vì $DOMAIN không phải tên miền công khai.

# Client HTTP vẫn vào được qua cổng HTTP của app (gunicorn bind), nên
# Caddy chỉ cần phục vụ 443. Redirect port 80 -> 443 chỉ khi Caddy tự giữ 80.

https://$DOMAIN {
	tls internal
	# Đẩy tiếp thẳng tới WebApp đang chạy native (127.0.0.1:$APP_PORT).
	reverse_proxy 127.0.0.1:$APP_PORT {
		header_up X-Real-IP {remote_host}
	}
}
EOF
caddy validate --config /etc/caddy/Caddyfile >/dev/null || die "Caddyfile không hợp lệ."
ok "Caddyfile hợp lệ."

# ------------------------------------------------------------------------------
# 3. Chạy Caddy (systemd) - unit caddy.service đã có sẵn sau khi cài Caddy
# ------------------------------------------------------------------------------
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy
sleep 2
if ! systemctl is-active --quiet caddy; then
    journalctl -u caddy -n 20 --no-pager || true
    die "Caddy không chạy được - xem log phía trên."
fi
ok "Caddy đang chạy (cổng 443/tcp + 443/udp HTTP/3)."

# ------------------------------------------------------------------------------
# 4. Trust root CA trên MÁY NÀY
# ------------------------------------------------------------------------------
CA_ROOT="/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
info "Chờ Caddy phát sinh root CA (tối đa 30s)..."
for _ in $(seq 1 15); do
    [ -s "$CA_ROOT" ] && break
    sleep 2
done
if [ ! -s "$CA_ROOT" ]; then
    # Kích hoạt lần đầu: gọi https một phát để force Caddy cấp cert (và CA).
    curl -sk --max-time 5 -o /dev/null "https://127.0.0.1/healthz" -H "Host: $DOMAIN" 2>/dev/null || true
    sleep 2
fi
[ -s "$CA_ROOT" ] || die "Không thấy root CA tại $CA_ROOT. Kiểm tra: journalctl -u caddy -n 50"

info "Import root CA vào trust store của máy này..."
install -m 644 "$CA_ROOT" /usr/local/share/ca-certificates/caddy-local-authority.crt
update-ca-certificates >/dev/null
ok "Máy này tin chứng chỉ của Caddy (system-wide; curl/Python có tác dụng ngay)."

# Chrome/Chromium dùng NSS DB riêng - thử import luôn nếu có certutil
RUN_USER="${SUDO_USER:-}"
if [ -n "$RUN_USER" ] && command -v certutil >/dev/null 2>&1; then
    NSS_DB="/home/$RUN_USER/.pki/nssdb"
    mkdir -p "$NSS_DB"
    certutil -d "sql:$NSS_DB" -A -t "C,," -n "Caddy Local Authority" -i "$CA_ROOT" >/dev/null 2>&1 \
        && chown -R "$RUN_USER" "$NSS_DB" 2>/dev/null || true
    ok "Đã import root CA vào Chrome/Chromium của $RUN_USER (NSS DB)."
    warn "Firefox cần import thủ công: Settings -> Privacy & Security -> Certificates -> View Certificates -> Authorities -> Import."
else
    warn "Không có certutil - Chrome cần import thủ công (xem README phần HTTPS)."
fi

# ------------------------------------------------------------------------------
# 5. Export root.crt cho các thiết bị KHÁC trong LAN
# ------------------------------------------------------------------------------
mkdir -p "$SCRIPT_DIR/certs"
cp -f "$CA_ROOT" "$SCRIPT_DIR/certs/root.crt"
chmod 644 "$SCRIPT_DIR/certs/root.crt"
ok "Đã xuất root CA: $SCRIPT_DIR/certs/root.crt (chép file này sang máy/điện thoại khác để import)."

# ------------------------------------------------------------------------------
# 6. Bật cookie secure cho app
# ------------------------------------------------------------------------------
if [ -n "$ROOT_DIR" ] && [ -f "$ROOT_DIR/.env" ]; then
    if grep -qE '^VPS_COOKIE_SECURE=' "$ROOT_DIR/.env"; then
        sed -i 's|^VPS_COOKIE_SECURE=.*|VPS_COOKIE_SECURE=true|' "$ROOT_DIR/.env"
    else
        printf '\n# Cookie chỉ gửi qua HTTPS (bật khi cài HTTPS nội bộ)\nVPS_COOKIE_SECURE=true\n' >>"$ROOT_DIR/.env"
    fi
    ok "Đã đặt VPS_COOKIE_SECURE=true trong $ROOT_DIR/.env"
    warn "Nhớ restart WebApp để cookie secure có hiệu lực: sudo systemctl restart <app-service>"
else
    warn "Không tìm thấy .env của app - tự thêm VPS_COOKIE_SECURE=true vào app của bạn."
fi

# ------------------------------------------------------------------------------
# 7. ufw
# ------------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && grep -q "Status: active" <(ufw status 2>/dev/null); then
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    ok "Đã mở ufw cổng 443 (tcp/udp - HTTPS + HTTP/3)."
fi

# ------------------------------------------------------------------------------
# 8. Kiểm tra + tổng kết
# ------------------------------------------------------------------------------
FAILED=0
HTTPS_URL="https://$DOMAIN"
if grep -q '200' <(curl --max-time 8 -o /dev/null -w '%{http_code}' "$HTTPS_URL/healthz" 2>/dev/null); then
    ok "WebApp trả lời 200 tại $HTTPS_URL/healthz - HTTPS nội bộ HOẠT ĐỘNG"
else
    warn "Chưa xác nhận được https://$DOMAIN/healthz (máy này chắc chắn trusted; thử lại sau vài giây)."
    FAILED=1
fi

echo
c "92" "══════════════════════════════════════════════════════════"
ok "HTTPS nội bộ đã cài xong."
echo "  WebApp HTTPS : $HTTPS_URL"
echo "  Root CA      : $SCRIPT_DIR/certs/root.crt"
echo "  Caddyfile    : /etc/caddy/Caddyfile (backup: /etc/caddy/Caddyfile.bak.*)"
echo
echo "  Cho thiết bị KHÁC vào không cảnh báo - import certs/root.crt vào:"
echo "   - Windows      : double-click root.crt -> Install Certificate -> Local Machine -> Trusted Root."
echo "   - Android      : Settings -> Security -> Install from storage (CA certificate)."
echo "   - macOS / iOS  : File root.crt -> cài vào Profile -> bật Trust full."
echo "   - Linux        : sudo cp root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
echo
echo "  Lưu ý:"
echo "   - Android 7+: trình duyệt (Chrome/Firefox) tin user CA bình thường;"
echo "     riêng một số APP không tôn trọng user CA trừ khi khai báo network config."
echo "   - Firefox: import thủ công vào Authorities như gợi ý phía trên."
echo "══════════════════════════════════════════════════════════"
[ "$FAILED" -eq 0 ] || warn "Kiểm tra HTTPS chưa đạt ngay lần đầu - chạy ./status.sh để xem lại."
exit "$FAILED"
