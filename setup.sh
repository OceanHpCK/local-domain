#!/usr/bin/env bash
# ==============================================================================
# vps-local-dns - Thiết lập tên miền nội bộ bằng Pi-hole (Docker)
#
# Script làm 4 việc, chạy lại nhiều lần vẫn an toàn (idempotent):
#   1. Cài Docker + Docker Compose nếu chưa có.
#   2. Tạo .env (mật khẩu Pi-hole tự sinh).
#   3. Thêm split-DNS vào systemd-resolved: chỉ riêng tên miền nội bộ đi qua
#      Pi-hole. -> KHÔNG tắt stub listener, KHÔNG phá DNS của Tailscale/host.
#   4. Khởi động Pi-hole, kiểm tra phân giải, bật app ra LAN nếu cần.
#   5. App = thư mục "vps-commander" nằm cạnh kit (tự dò); ghi đè bằng
#      biến APP_DIR nếu app nằm chỗ khác.
#
# Dùng:
#   sudo ./setup.sh                     # tự dò IP LAN
#   sudo LAN_IP=192.168.1.153 ./setup.sh
#   sudo ALLOW_UFW=1 ./setup.sh         # tự mở cổng nếu ufw đang bật
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Tự dò thư mục app (app.py / requirements.txt) cạnh kit, hoặc APP_DIR env.
APP_DIR="${APP_DIR:-}"
if [ -z "$APP_DIR" ]; then
    for cand in "$SCRIPT_DIR/../vps-commander" "$SCRIPT_DIR/../../vps-commander"; do
        [ -n "$cand" ] || continue
        if [ -f "$cand/app.py" ] || [ -f "$cand/requirements.txt" ]; then
            ROOT_DIR="$(cd "$cand" && pwd)"
            break
        fi
    done
fi
ROOT_DIR="${ROOT_DIR:-${APP_DIR:-}}"
[ -n "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ] || ROOT_DIR="/nonexistent"

DOMAIN="${VPS_HOSTNAME:-vps.vn}"

# ------------------------------------------------------------------------------
# Tiện ích in màu
# ------------------------------------------------------------------------------
c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c "96" "[i] $*"; }
ok()   { c "92" "[✓] $*"; }
warn() { c "93" "[!] $*"; }
die()  { c "91" "[x] $*" >&2; exit 1; }

# Mật khẩu an toàn với `set -e -o pipefail`: od thoát 0, không SIGPIPE.
gen_password() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    cat <<'EOF'
Thiết lập tên miền nội bộ vps.vn bằng Pi-hole (Docker)

Script làm 4 việc, chạy lại nhiều lần vẫn an toàn:
  1. Cài Docker + Docker Compose nếu chưa có.
  2. Tạo .env (mật khẩu Pi-hole tự sinh).
  3. Thêm split-DNS vào systemd-resolved: chỉ vps.vn đi qua Pi-hole.
     (Không tắt stub listener, không phá DNS của host/Tailscale.)
  4. Khởi động Pi-hole, kiểm tra phân giải, mở app ra LAN nếu cần.

Dùng:
  sudo ./setup.sh                     # tự dò IP LAN
  sudo LAN_IP=192.168.1.153 ./setup.sh
  sudo ALLOW_UFW=1 ./setup.sh         # tự mở cổng nếu ufw đang bật
EOF
    exit 0
fi

# ------------------------------------------------------------------------------
# 0. Cần root (cài Docker + sửa systemd-resolved)
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    warn "Cần quyền root để cài Docker và cấu hình systemd-resolved."
    info "Đang chạy lại bằng sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ------------------------------------------------------------------------------
# 1. Xác định IP LAN
# ------------------------------------------------------------------------------
detect_lan_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

if [ -f "$SCRIPT_DIR/.env" ]; then
    # Ưu tiên biến người dùng truyền vào (sudo LAN_IP=... ./setup.sh) hơn file .env
    CLI_LAN_IP="${LAN_IP:-}"
    CLI_DOMAIN="${VPS_HOSTNAME:-}"
    # shellcheck disable=SC1091
    set -a; . "$SCRIPT_DIR/.env"; set +a
else
    CLI_LAN_IP="${LAN_IP:-}"
    CLI_DOMAIN="${VPS_HOSTNAME:-}"
fi

LAN_IP="${CLI_LAN_IP:-${LAN_IP:-$(detect_lan_ip)}}"
[ -n "$LAN_IP" ] || die "Không tự dò được IP LAN. Chạy lại với: sudo LAN_IP=192.168.x.y ./setup.sh"
DOMAIN="${CLI_DOMAIN:-${VPS_HOSTNAME:-$DOMAIN}}"

if ! ip -4 addr show | grep -q "inet ${LAN_IP}/"; then
    warn "IP $LAN_IP không gắn với card mạng nào trên máy này."
    read -r -p "Tiếp tục vẫn được, nhưng hãy kiểm tra lại. Tiếp tục? [y/N] " ans
    [[ "${ans:-n}" =~ ^[yY]$ ]] || exit 1
fi

info "IP LAN dùng cho $DOMAIN: $LAN_IP"

# ------------------------------------------------------------------------------
# 2. Docker + Compose
# ------------------------------------------------------------------------------
install_docker() {
    command -v docker >/dev/null 2>&1 && return 0
    warn "Chưa có Docker, đang cài..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    command -v curl >/dev/null 2>&1 || apt-get install -y curl ca-certificates
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        sh /tmp/get-docker.sh
    else
        warn "Không tải được get.docker.com, dùng gói của Ubuntu."
        apt-get install -y docker.io || die "Cài Docker thất bại."
        apt-get install -y docker-compose-v2 2>/dev/null \
            || apt-get install -y docker-compose-plugin 2>/dev/null \
            || apt-get install -y docker-compose 2>/dev/null || true
    fi
    systemctl enable --now docker
    ok "Đã cài Docker."
}

install_docker

COMPOSE=()
if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    die "Không tìm thấy Docker Compose. Cài: sudo apt install docker-compose-v2"
fi

# Cho phép user thật dùng docker mà không cần sudo ở các lần sau
if [ -n "${SUDO_USER:-}" ] && ! id -nG "$SUDO_USER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$SUDO_USER"
    warn "Đã thêm $SUDO_USER vào nhóm docker (cần đăng xuất/đăng nhập lại để có hiệu lực)."
fi

# ------------------------------------------------------------------------------
# 3. File .env cho Pi-hole
# ------------------------------------------------------------------------------
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    PIHOLE_PASSWORD="$(gen_password)"
    cat > "$SCRIPT_DIR/.env" <<EOF
# Pi-hole nội bộ - sinh tự động bởi setup.sh ($(date '+%Y-%m-%d %H:%M'))
LAN_IP=$LAN_IP
VPS_HOSTNAME=$DOMAIN
PIHOLE_PASSWORD=$PIHOLE_PASSWORD
UPSTREAM_DNS="1.1.1.1;1.0.0.1"
TZ=Asia/Ho_Chi_Minh
EOF
    chmod 600 "$SCRIPT_DIR/.env"
    ok "Đã tạo $SCRIPT_DIR/.env (mật khẩu admin Pi-hole ở trong đó)."
else
    chmod 600 "$SCRIPT_DIR/.env"
    # Đồng bộ LAN_IP / tên miền nếu người dùng truyền vào khác file cũ
    if grep -qE '^LAN_IP=' "$SCRIPT_DIR/.env"; then
        sed -i "s|^LAN_IP=.*|LAN_IP=$LAN_IP|" "$SCRIPT_DIR/.env"
    else
        printf 'LAN_IP=%s\n' "$LAN_IP" >> "$SCRIPT_DIR/.env"
    fi
    if grep -qE '^VPS_HOSTNAME=' "$SCRIPT_DIR/.env"; then
        sed -i "s|^VPS_HOSTNAME=.*|VPS_HOSTNAME=$DOMAIN|" "$SCRIPT_DIR/.env"
    else
        printf 'VPS_HOSTNAME=%s\n' "$DOMAIN" >> "$SCRIPT_DIR/.env"
    fi
    info "Dùng lại $SCRIPT_DIR/.env (LAN_IP=$LAN_IP, VPS_HOSTNAME=$DOMAIN)."
fi

# ------------------------------------------------------------------------------
# 4. Split-DNS: chỉ vps.vn đi qua Pi-hole
# ------------------------------------------------------------------------------
if systemctl is-active --quiet systemd-resolved; then
    install -d /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-vps-local-domain.conf <<EOF
# Do setup.sh của kit tạo: chỉ định tuyến $DOMAIN sang Pi-hole nội bộ.
# Các domain khác (kể cả Tailscale MagicDNS) vẫn dùng DNS của từng interface.
[Resolve]
DNS=$LAN_IP
Domains=~$DOMAIN
EOF
    systemctl restart systemd-resolved
    resolvectl flush-caches 2>/dev/null || true
    ok "Đã thêm split-DNS cho ~$DOMAIN -> $LAN_IP."
else
    warn "systemd-resolved không chạy - bỏ qua bước split-DNS."
    warn "Hãy tự thêm bản ghi $DOMAIN -> $LAN_IP vào DNS của host nếu cần."
fi

# ------------------------------------------------------------------------------
# 5. Khởi động Pi-hole
# ------------------------------------------------------------------------------
info "Đang khởi động Pi-hole..."
"${COMPOSE[@]}" up -d

info "Chờ Pi-hole sẵn sàng (tối đa 120s)..."
for _ in $(seq 1 60); do
    if dig +short +time=1 +tries=1 "@$LAN_IP" "$DOMAIN" 2>/dev/null | grep -qx "$LAN_IP"; then
        break
    fi
    sleep 2
done

# ------------------------------------------------------------------------------
# 6. Kiểm tra
# ------------------------------------------------------------------------------
FAILED=0

if dig +short +time=2 +tries=1 "@$LAN_IP" "$DOMAIN" | grep -qx "$LAN_IP"; then
    ok "Pi-hole trả lời: $DOMAIN -> $LAN_IP"
else
    warn "Pi-hole chưa trả lời đúng. Xem log: docker compose -f $SCRIPT_DIR/docker-compose.yml logs --tail=50 pihole"
    FAILED=1
fi

if command -v resolvectl >/dev/null 2>&1; then
    if resolvectl query "$DOMAIN" 2>/dev/null | grep -q "$LAN_IP"; then
        ok "Host này phân giải $DOMAIN -> $LAN_IP (qua systemd-resolved)."
    else
        warn "Host chưa phân giải được $DOMAIN. Thử: resolvectl flush-caches && resolvectl query $DOMAIN"
        FAILED=1
    fi
fi

# ------------------------------------------------------------------------------
# 7. Cho app nghe ra LAN (VPS_HOST=0.0.0.0)
# ------------------------------------------------------------------------------
if [ -f "$ROOT_DIR/.env" ]; then
    if grep -qE '^VPS_HOST=' "$ROOT_DIR/.env"; then
        sed -i 's|^VPS_HOST=.*|VPS_HOST=0.0.0.0|' "$ROOT_DIR/.env"
    else
        printf '\n# Bind ra LAN để dùng chung tên miền nội bộ %s\nVPS_HOST=0.0.0.0\n' "$DOMAIN" >> "$ROOT_DIR/.env"
    fi
    info "Đã đặt VPS_HOST=0.0.0.0 trong $ROOT_DIR/.env (cổng 5000 mở ra LAN)."

    if docker ps --format '{{.Names}}' | grep -qx 'vps-commander'; then
        info "Khởi động lại vps-commander để áp dụng cổng mới..."
        ( cd "$ROOT_DIR" && "${COMPOSE[@]}" up -d )
    elif curl -s --max-time 3 -o /dev/null http://127.0.0.1:5000/healthz; then
        warn "WebApp đang chạy NGOÀI Docker (./run.sh). Hãy Ctrl+C rồi chạy lại ./run.sh"
        warn "để nó bind 0.0.0.0:5000 (đã đặt trong .env)."
    else
        info "WebApp chưa chạy - đang build và khởi động bằng Docker (lần đầu hơi lâu)..."
        ( cd "$ROOT_DIR" && "${COMPOSE[@]}" up -d --build )
    fi
else
    warn "Chưa có $ROOT_DIR/.env - hãy chạy 'cp .env.example .env' ở thư mục gốc."
    warn "Sau đó đặt VPS_HOST=0.0.0.0 nếu muốn truy cập từ máy khác trong LAN."
fi

# ------------------------------------------------------------------------------
# 8. Gợi ý firewall
# ------------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if [ "${ALLOW_UFW:-0}" = "1" ]; then
        ufw allow 53/udp >/dev/null && ufw allow 53/tcp >/dev/null
        ufw allow 80/tcp >/dev/null && ufw allow 5000/tcp >/dev/null
        ok "Đã mở cổng 53, 80, 5000 trên ufw."
    else
        warn "ufw đang bật. Nếu thiết bị khác không kết nối được, chạy:"
        echo "    sudo ufw allow 53/udp && sudo ufw allow 53/tcp"
        echo "    sudo ufw allow 80/tcp && sudo ufw allow 5000/tcp"
    fi
fi

# ------------------------------------------------------------------------------
# 9. Tổng kết
# ------------------------------------------------------------------------------
echo
c "92" "══════════════════════════════════════════════════════════════════"
c "92" "  HOÀN TẤT CẤU HÌNH TÊN MIỀN NỘI BỘ"
c "92" "══════════════════════════════════════════════════════════════════"
echo "  WebApp        : http://$DOMAIN:5000"
echo "  Pi-hole admin : http://$LAN_IP/admin"
echo "  DNS nội bộ    : $DOMAIN -> $LAN_IP  (chỉ áp dụng cho máy dùng Pi-hole)"
echo
if [ -f "$SCRIPT_DIR/.env" ]; then
    echo "  Mật khẩu admin Pi-hole: ${PIHOLE_PASSWORD:-<xem trong .env>}"
fi
echo
echo "  Việc còn lại:"
echo "   1. Trỏ DNS của router (DHCP) về $LAN_IP để mọi thiết bị trong LAN"
echo "      tự phân giải $DOMAIN (hoặc đặt DNS thủ công trên từng máy)."
echo "   2. Tắt DNS-over-HTTPS (Secure DNS) trong trình duyệt, nếu không"
echo "      trình duyệt sẽ bỏ qua Pi-hole."
echo "   3. Đăng nhập WebApp bằng token VPS_WEB_TOKEN trong .env."
echo
[ "$FAILED" -eq 0 ] || warn "Có bước kiểm tra chưa đạt - xem cảnh báo phía trên."
