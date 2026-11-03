#!/usr/bin/env bash
# ==============================================================================
# vps-local-dns - Cài Pi-hole TRỰC TIẾP (không Docker) + tên miền nội bộ
#
# Deploy kit độc lập: chạy được trên bất kỳ máy Ubuntu/Debian nào
# (desktop hoặc server):
#   - Tự dò IP LAN và interface, tự sinh mật khẩu, tự tạo .env.
#   - Tự dò app "vps-commander" nằm cạnh kit để tạo venv + service systemd
#     (hoặc truyền --app-dir).
#   - Nếu đặt LAN_IP=<router DNS>, mọi máy trong LAN truy cập được WebApp theo tên.
#
# Cách hoạt động:
#   1. Cài Pi-hole v6 bằng script chính thức, tự trả lời các hộp thoại
#      (dùng đúng cơ chế SKIP_INSTALL mà installer cung cấp).
#   2. Cấu hình FTL: listeningMode=BIND + interface=card LAN
#      -> Pi-hole CHỈ bind 53 trên IP LAN, không đụng 127.0.0.53 của
#         systemd-resolved và không phá Tailscale MagicDNS.
#   3. Bật lại stub listener của systemd-resolved + split-DNS: chỉ tên miền
#      nội bộ đi qua Pi-hole, mọi domain khác giữ nguyên đường cũ.
#   4. Tạo venv, cài thư viện và chạy WebApp bằng systemd (tự chạy lại khi reboot).
#   5. Nếu ufw đang bật: tự mở 53 (tcp/udp), cổng WebApp và cổng admin.
#
# Cách chạy khuyến nghị (detached để terminal không thể ngắt cài đặt):
#   sudo setsid bash ./install-native.sh > /tmp/vps-native.log 2>&1
#   tail -f /tmp/vps-native.log
#
# Gỡ cài đặt: xem cuối file README.md
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Tự dò thư mục app (app.py / requirements.txt) nằm cạnh kit này:
# mặc định là sibling "vps-commander"; ghi đè bằng --app-dir hoặc biến VPS_APP_DIR.
find_app_dir() {
    for cand in "${CLI_APP_DIR:-}" "$SCRIPT_DIR/../vps-commander" "$SCRIPT_DIR/../../vps-commander" "$SCRIPT_DIR/.."; do
        [ -n "$cand" ] || continue
        if [ -f "$cand/app.py" ] || [ -f "$cand/requirements.txt" ]; then
            (cd "$cand" && pwd)
            return 0
        fi
    done
    return 1
}

DOMAIN="${VPS_HOSTNAME:-vps.vn}"
CREATE_SERVICE=1
# Cổng WebApp. Mặc định 80 để gõ tên miền là vào thẳng.
APP_PORT="${APP_PORT:-80}"
ADMIN_PORT="${ADMIN_PORT:-8080}"
CLI_LAN_IP="${LAN_IP:-}"
CLI_UPSTREAM="${UPSTREAM_DNS:-}"
CLI_APP_DIR="${VPS_APP_DIR:-}"

for p in "$APP_PORT" "$ADMIN_PORT"; do
    case "$p" in
        '' | *[!0-9]*) echo "[x] Cổng không hợp lệ: $p" >&2; exit 1 ;;
    esac
done
[ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ] || { echo "[x] APP_PORT ngoài 1-65535" >&2; exit 1; }
[ "$ADMIN_PORT" -ge 1 ] && [ "$ADMIN_PORT" -le 65535 ] || { echo "[x] ADMIN_PORT ngoài 1-65535" >&2; exit 1; }

usage() {
    cat <<EOF
Pi-hole trực tiếp (không Docker) + WebApp theo tên miền nội bộ $DOMAIN

Khuyến nghị - chạy detached để terminal không thể ngắt cài đặt:
  sudo setsid bash ./install-native.sh > /tmp/vps-native.log 2>&1
  tail -f /tmp/vps-native.log   (Ctrl+C chỉ dừng tail, không ảnh hưởng cài đặt)

Tùy chọn:
  -h, --help              Hiển thị hướng dẫn
  --ip <IP LAN>           IP LAN để bind DNS (mặc định: tự dò qua route)
  --app-dir <đường-dẫn>   Thư mục app để tạo venv + service systemd
                          (mặc định: tự dò thư mục "vps-commander" nằm cạnh kit)
  --domain <tên-miền>     Tên miền nội bộ (mặc định: vps.vn)
  --port <N>              Cổng WebApp (mặc định: 80)
  --admin-port <N>        Cổng quản trị Pi-hole (mặc định: 8080, áp dụng khi WebApp chiếm cổng 80)
  --upstream "<IP>;IP"    DNS upstream (mặc định: 1.1.1.1;1.0.0.1)
  --no-service            Không tạo systemd cho WebApp

Biến môi trường tương đương: LAN_IP, VPS_HOSTNAME, APP_PORT, ADMIN_PORT, UPSTREAM_DNS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --no-service) CREATE_SERVICE=0 ;;
        --app-dir) [ $# -ge 2 ] || { echo "[x] --app-dir thiếu giá trị" >&2; exit 1; }; CLI_APP_DIR="$2"; shift ;;
        --ip) [ $# -ge 2 ] || { echo "[x] --ip thiếu giá trị" >&2; exit 1; }; CLI_LAN_IP="$2"; shift ;;
        --domain) [ $# -ge 2 ] || { echo "[x] --domain thiếu giá trị" >&2; exit 1; }; DOMAIN="$2"; shift ;;
        --port) [ $# -ge 2 ] || { echo "[x] --port thiếu giá trị" >&2; exit 1; }; APP_PORT="$2"; shift ;;
        --admin-port) [ $# -ge 2 ] || { echo "[x] --admin-port thiếu giá trị" >&2; exit 1; }; ADMIN_PORT="$2"; shift ;;
        --upstream) [ $# -ge 2 ] || { echo "[x] --upstream thiếu giá trị" >&2; exit 1; }; CLI_UPSTREAM="$2"; shift ;;
        *)
            echo "[x] Tùy chọn lạ: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

[ "$APP_PORT" -ne "$ADMIN_PORT" ] || { echo "[x] APP_PORT và ADMIN_PORT không được trùng nhau" >&2; exit 1; }

# Thư mục app (dùng ở phần 7: venv + service systemd cho WebApp)
if [ -n "$CLI_APP_DIR" ]; then
    [ -d "$CLI_APP_DIR" ] || { echo "[x] Thư mục app không tồn tại: $CLI_APP_DIR" >&2; exit 1; }
    ROOT_DIR="$(cd "$CLI_APP_DIR" && pwd)"
else
    ROOT_DIR="$(find_app_dir)" || ROOT_DIR=""
fi
if [ "$CREATE_SERVICE" -eq 1 ] && [ ! -f "${ROOT_DIR:-/dev/null}/requirements.txt" ]; then
    echo "[x] Không tìm thấy app (app.py/requirements.txt)." >&2
    echo "    Truyền --app-dir /đường/dẫn/vps-commander, hoặc --no-service nếu chỉ cài DNS." >&2
    exit 1
fi

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c "96" "[i] $*"; }
ok() { c "92" "[✓] $*"; }
warn() { c "93" "[!] $*"; }
die() {
    c "91" "[x] $*" >&2
    exit 1
}

# Mật khẩu ngẫu nhiên an toàn với `set -e -o pipefail`:
# od đọc đúng 16 byte rồi thoát 0, không có SIGPIPE như `tr | head -c N`.
gen_password() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

if [ "$(id -u)" -ne 0 ]; then
    warn "Cần quyền root. Đang chạy lại bằng sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ------------------------------------------------------------------------------
# 0. Đọc cấu hình sẵn có (nếu có) và dò IP LAN
# ------------------------------------------------------------------------------
detect_lan_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

CLI_LAN_IP="${LAN_IP:-}"
CLI_DOMAIN="${VPS_HOSTNAME:-}"
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi
LAN_IP="${CLI_LAN_IP:-${LAN_IP:-$(detect_lan_ip)}}"
DOMAIN="${CLI_DOMAIN:-${VPS_HOSTNAME:-$DOMAIN}}"
[ -n "$LAN_IP" ] || die "Không dò được IP LAN. Chạy: sudo LAN_IP=192.168.x.y ./install-native.sh"

IFACE="$(ip -o -4 addr show | awk -v ip="$LAN_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
[ -n "$IFACE" ] || die "IP $LAN_IP không thuộc card mạng nào. Kiểm tra: ip -4 addr"
ok "IP LAN: $LAN_IP (interface: $IFACE), tên miền: $DOMAIN"

# ------------------------------------------------------------------------------
# 1. File .env dùng chung với phương án Docker
# ------------------------------------------------------------------------------
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    PIHOLE_PASSWORD="$(gen_password)"
    cat >"$SCRIPT_DIR/.env" <<EOF
# Pi-hole nội bộ - sinh tự động ($(date '+%Y-%m-%d %H:%M'))
LAN_IP=$LAN_IP
VPS_HOSTNAME=$DOMAIN
PIHOLE_PASSWORD=$PIHOLE_PASSWORD
UPSTREAM_DNS="${CLI_UPSTREAM:-1.1.1.1;1.0.0.1}"
TZ=Asia/Ho_Chi_Minh
EOF
    chmod 600 "$SCRIPT_DIR/.env"
    ok "Đã tạo $SCRIPT_DIR/.env (mật khẩu admin Pi-hole ở trong)."
else
    chmod 600 "$SCRIPT_DIR/.env"
    sed -i "s|^LAN_IP=.*|LAN_IP=$LAN_IP|" "$SCRIPT_DIR/.env"
    sed -i "s|^VPS_HOSTNAME=.*|VPS_HOSTNAME=$DOMAIN|" "$SCRIPT_DIR/.env"
    grep -qE '^PIHOLE_PASSWORD=' "$SCRIPT_DIR/.env" \
        || printf 'PIHOLE_PASSWORD=%s\n' "$(gen_password)" >>"$SCRIPT_DIR/.env"
    grep -qE '^UPSTREAM_DNS=' "$SCRIPT_DIR/.env" \
        || echo "UPSTREAM_DNS=\"${CLI_UPSTREAM:-1.1.1.1;1.0.0.1}\"" >>"$SCRIPT_DIR/.env"
fi

# shellcheck disable=SC1091
set -a; . "$SCRIPT_DIR/.env"; set +a
if [ -n "$CLI_UPSTREAM" ]; then
    UPSTREAM_DNS="$CLI_UPSTREAM"
    sed -i "s|^UPSTREAM_DNS=.*|UPSTREAM_DNS=\"$CLI_UPSTREAM\"|" "$SCRIPT_DIR/.env" || true
fi
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:?Thiếu PIHOLE_PASSWORD trong .env}"
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1;1.0.0.1}"
UP1="$(cut -d';' -f1 <<<"$UPSTREAM_DNS")"
UP2="$(cut -d';' -f2 <<<"$UPSTREAM_DNS")"
[ -n "$UP1" ] || UP1="1.1.1.1"
# Chỉ cho 1 upstream cũng được -> dùng lại UP1, FTL cấu hình mảng 1 phần tử.
[ -n "$UP2" ] || UP2="$UP1"

command -v apt-get >/dev/null || die "Script này dành cho Debian/Ubuntu (cần apt-get)."

# ------------------------------------------------------------------------------
# 2. Gói phụ thuộc
# ------------------------------------------------------------------------------
info "Cài gói phụ thuộc (curl, dig, python3-venv)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl ca-certificates dnsutils python3-venv python3-pip
ok "Đã cài gói phụ thuộc."

# ------------------------------------------------------------------------------
# 3. Chuẩn bị installer Pi-hole
#    Ưu tiên: bản đã kèm sẵn trong repo (vendor/) -> bản còn trong /tmp
#    -> tải lại (tối đa 3 lần). Kiểm chứng bằng chữ ký + sha256 nếu có.
# ------------------------------------------------------------------------------
VENDOR_DIR="$SCRIPT_DIR/vendor"
VENDOR_INSTALLER="$VENDOR_DIR/pihole-basic-install.sh"
INSTALLER=/tmp/pihole-install.sh

valid_install() {
    [ -s "$1" ] || return 1
    [ "$(wc -c <"$1")" -gt 50000 ] || return 1
    grep -q "SKIP_INSTALL" "$1" \
        && grep -q "runUnattended" "$1" \
        && grep -q "disable_resolved_stublistener" "$1"
}

GOT=0
if [ -f "$VENDOR_INSTALLER" ] && valid_install "$VENDOR_INSTALLER"; then
    if [ ! -f "$VENDOR_INSTALLER.sha256" ] \
        || (cd "$VENDOR_DIR" && sha256sum -c pihole-basic-install.sh.sha256 >/dev/null 2>&1); then
        cp "$VENDOR_INSTALLER" "$INSTALLER"
        chmod 755 "$INSTALLER"
        ok "Dùng installer Pi-hole kèm sẵn trong repo (đã kiểm tra sha256/chữ ký)."
        GOT=1
    else
        warn "Checksum của installer kèm sẵn không khớp - sẽ tải bản mới."
    fi
fi

if [ "$GOT" -ne 1 ] && [ ! -f "$INSTALLER" ] && ! valid_install "$INSTALLER"; then
    # không có gì dùng lại được -> sẽ đi vào vòng tải bên dưới
    :
fi

if [ "$GOT" -ne 1 ] && [ -f "$INSTALLER" ] && valid_install "$INSTALLER"; then
    chmod 755 "$INSTALLER"
    ok "Dùng lại installer còn trong /tmp."
    GOT=1
fi

if [ "$GOT" -ne 1 ]; then
    for attempt in 1 2 3; do
        info "Tải Pi-hole installer (lần $attempt/3)..."
        rm -f "$INSTALLER"
        if curl -fsSL --connect-timeout 10 https://install.pi-hole.net -o "$INSTALLER" 2>/dev/null \
            || wget -q -O "$INSTALLER" https://install.pi-hole.net 2>/dev/null; then
            if valid_install "$INSTALLER"; then
                chmod 755 "$INSTALLER"
                GOT=1
                break
            fi
        fi
        sleep 3
    done
fi

[ "$GOT" -eq 1 ] || die "Không tải/kiểm chứng được installer Pi-hole. Kiểm tra mạng rồi chạy lại."
ok "Sẵn sàng installer ($(wc -l <"$INSTALLER") dòng, $(wc -c <"$INSTALLER") byte)."

# ------------------------------------------------------------------------------
# 4. Chạy installer với các "hộp thoại" được trả lời sẵn
#    Pi-hole v6 không còn hỗ trợ --unattended cho cài mới, nên ta source
#    script (SKIP_INSTALL=true) rồi thay các hàm hỏi đáp bằng giá trị cố định.
# ------------------------------------------------------------------------------
info "Chạy installer Pi-hole (có thể mất 2-5 phút)..."

# Giữ DNS tạm thời hoạt động trong lúc cài: installer sẽ tắt stub listener,
# nếu /etc/resolv.conf vẫn trỏ 127.0.0.53 thì apt/gravity sẽ mất DNS.
RESOLV_BACKUP="/var/backups/vps-commander/resolv.conf.$(date +%s)"
mkdir -p /var/backups/vps-commander
cp -a /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
rm -f /etc/resolv.conf
printf 'nameserver %s\nnameserver %s\n' "$UP1" "$UP2" >/etc/resolv.conf

# Installer dùng `set -e` nhưng không dùng `set -u`; tắt nounset khi source.
set +u
set +o pipefail
# shellcheck disable=SC1090,SC1091
SKIP_INSTALL=true source "$INSTALLER"

# --- Thay các hàm tương tác bằng giá trị của chúng ta ---
welcomeDialogs() { :; }
chooseInterface() { PIHOLE_INTERFACE="$IFACE"; }
setDNS() {
    PIHOLE_DNS_1="$UP1"
    PIHOLE_DNS_2="$UP2"
}
chooseBlocklists() {
    if [ -f "${adlistFile}" ]; then
        mv -f "${adlistFile}" "${adlistFile}.old"
    fi
    install -m 644 /dev/null "${adlistFile}"
    echo "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" >>"${adlistFile}"
}
setLogging() { QUERY_LOGGING=true; }
setPrivacyLevel() { PRIVACY_LEVEL=0; }
dialog() { return 0; }

PIHOLE_INTERFACE="$IFACE"
PIHOLE_DNS_1="$UP1"
PIHOLE_DNS_2="$UP2"
QUERY_LOGGING=true
PRIVACY_LEVEL=0

main || RC=$?
set -u
set -o pipefail
RC="${RC:-0}"
[ "$RC" -eq 0 ] || die "Installer Pi-hole thất bại (mã $RC). Xem log trong /var/log/pihole/."

command -v pihole-FTL >/dev/null || die "Không tìm thấy pihole-FTL sau khi cài."
ok "Đã cài xong Pi-hole."

# ------------------------------------------------------------------------------
# 5. Cấu hình FTL: chỉ bind trên IP LAN, thêm bản ghi vps.vn
# ------------------------------------------------------------------------------
info "Cấu hình Pi-hole chỉ phục vụ DNS trên $LAN_IP..."

pihole setpassword "$PIHOLE_PASSWORD" >/dev/null 2>&1 \
    || pihole-FTL --config webserver.api.password "$PIHOLE_PASSWORD" >/dev/null

if [ -n "$UP2" ] && [ "$UP2" != "$UP1" ]; then
    pihole-FTL --config dns.upstreams "[\"$UP1\", \"$UP2\"]" >/dev/null
else
    pihole-FTL --config dns.upstreams "[\"$UP1\"]" >/dev/null
fi
pihole-FTL --config dns.hosts "[\"$LAN_IP $DOMAIN\"]" >/dev/null
pihole-FTL --config dns.interface "$IFACE" >/dev/null
# BIND = bind thật sự chỉ trên interface ở trên (không phải 0.0.0.0)
pihole-FTL --config dns.listeningMode "BIND" >/dev/null

# Nhường cổng 80 cho WebApp: dời trang quản trị Pi-hole sang ADMIN_PORT.
if [ "$APP_PORT" -eq 80 ]; then
    info "Dời quản trị Pi-hole sang cổng $ADMIN_PORT để nhường cổng 80 cho WebApp..."
    pihole-FTL --config webserver.port "$ADMIN_PORT" >/dev/null
fi

systemctl restart pihole-FTL

info "Chờ Pi-hole trả lời trên $LAN_IP..."
READY=0
for _ in $(seq 1 40); do
    if dig +short +time=1 +tries=1 "@$LAN_IP" "$DOMAIN" 2>/dev/null | grep -qx "$LAN_IP"; then
        READY=1
        break
    fi
    sleep 2
done
[ "$READY" -eq 1 ] || warn "Pi-hole chưa trả lời. Xem: journalctl -u pihole-FTL -n 50 --no-pager"

# FTL có bind đúng 192.168.x.y:53 thay vì 0.0.0.0:53 không?
if ss -lnu 2>/dev/null | grep -qE '(^|[\s:])(0\.0\.0\.0|\*|\[::\]):53\b'; then
    LAN_ONLY=0
else
    LAN_ONLY=1
fi
info "Kiểm tra bind cổng 53: $(ss -lnu 2>/dev/null | awk '/:53[[:space:]]/ {print $4}' | tr '\n' ' ')"

if [ "$APP_PORT" -eq 80 ] && ss -ltn 2>/dev/null | grep -qE ':80[[:space:]]'; then
    warn "Cổng 80 vẫn đang bị chiếm (Pi-hole chưa dời cổng?). Kiểm tra: ss -ltnp | grep ':80 '"
    warn "Có thể đổi tay: pihole-FTL --config webserver.port \"$ADMIN_PORT\" && systemctl restart pihole-FTL"
fi

# ------------------------------------------------------------------------------
# 6. Trả lại DNS cho host
# ------------------------------------------------------------------------------
if [ "$LAN_ONLY" -eq 1 ]; then
    # Pi-hole chỉ bind IP LAN -> bật lại stub của systemd-resolved an toàn.
    info "Bật lại systemd-resolved stub + split-DNS cho ~$DOMAIN..."
    install -d /etc/systemd/resolved.conf.d
    cat >/etc/systemd/resolved.conf.d/99-vps-local-domain.conf <<EOF
# Do install-native.sh của dự án vps-local-dns tạo.
# Chỉ $DOMAIN đi qua Pi-hole nội bộ; các domain khác (Tailscale...) giữ nguyên.
[Resolve]
DNSStubListener=yes
DNS=$LAN_IP
Domains=~$DOMAIN
EOF
    systemctl restart systemd-resolved
    resolvectl flush-caches 2>/dev/null || true
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    ok "Host dùng lại systemd-resolved (127.0.0.53), Tailscale MagicDNS không bị ảnh hưởng."
else
    # Không bind riêng được -> dùng Pi-hole làm DNS cho host.
    warn "Pi-hole đang bind 0.0.0.0:53; dùng nó làm DNS của host."
    rm -f /etc/resolv.conf
    printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n' >/etc/resolv.conf
    # Giữ Tailscale MagicDNS hoạt động khi không còn systemd-resolved stub
    pihole-FTL --config misc.dnsmasq_lines "[\"server=/ts.net/100.100.100.100\"]" >/dev/null
    systemctl restart pihole-FTL
    ok "Host dùng Pi-hole tại 127.0.0.1; đã thêm forward riêng cho *.ts.net."
fi

# ------------------------------------------------------------------------------
# 7. Chạy WebApp bằng systemd (venv + gunicorn)
# ------------------------------------------------------------------------------
RUN_USER="${SUDO_USER:-root}"
RUN_GROUP="$(id -gn "$RUN_USER")"

set_root_env() {
    local f="$ROOT_DIR/.env"
    if [ ! -f "$f" ]; then
        warn "Chưa có $f - hãy cp .env.example .env ở thư mục gốc."
        return
    fi
    if grep -qE '^VPS_HOST=' "$f"; then
        sed -i 's|^VPS_HOST=.*|VPS_HOST=0.0.0.0|' "$f"
    else
        printf '\n# Bind ra LAN để dùng chung tên miền nội bộ %s\nVPS_HOST=0.0.0.0\n' "$DOMAIN" >>"$f"
    fi
    chown "$RUN_USER:$RUN_GROUP" "$f" 2>/dev/null || true
}

if [ "$CREATE_SERVICE" -eq 1 ]; then
    set_root_env
    BIND_ADDR="$(grep -E '^VPS_HOST=' "$ROOT_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
    BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

    info "Tạo môi trường Python (.venv) cho WebApp..."
    if [ ! -x "$ROOT_DIR/.venv/bin/python" ]; then
        sudo -u "$RUN_USER" -H python3 -m venv "$ROOT_DIR/.venv"
    fi
    sudo -u "$RUN_USER" -H "$ROOT_DIR/.venv/bin/pip" install -q --upgrade pip
    sudo -u "$RUN_USER" -H "$ROOT_DIR/.venv/bin/pip" install -q -r "$ROOT_DIR/requirements.txt"
    ok "Đã cài thư viện Python."

    if ss -ltn 2>/dev/null | grep -qE ":${APP_PORT}[[:space:]]" \
        && ! systemctl is-active --quiet vps-commander; then
        warn "Cổng $APP_PORT đang bị tiến trình khác dùng. Dừng nó (vd: Ctrl+C ở cửa sổ ./run.sh) rồi chạy lại script."
    else
        CAP_LINES=""
        if [ "$APP_PORT" -lt 1024 ]; then
            CAP_LINES=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'
        fi
        cat >/etc/systemd/system/vps-commander.service <<EOF
[Unit]
Description=VPS Commander WebApp
After=network-online.target pihole-FTL.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$ROOT_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$ROOT_DIR/.venv/bin/gunicorn --bind $BIND_ADDR:$APP_PORT --workers 1 --threads 8 --timeout 180 app:app
$CAP_LINES
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable vps-commander >/dev/null
        systemctl restart vps-commander
        ok "WebApp chạy dưới systemd: $APP_URL (bind $BIND_ADDR:$APP_PORT)"
    fi
fi

# Định nghĩa URL dùng chung (phải nằm trước mọi lệnh in)
APP_URL="http://$DOMAIN"
[ "$APP_PORT" -eq 80 ] || APP_URL="http://$DOMAIN:$APP_PORT"
if [ "$APP_PORT" -eq 80 ]; then
    ADMIN_URL="http://$LAN_IP:$ADMIN_PORT/admin"
else
    ADMIN_URL="http://$LAN_IP/admin"
fi

# ------------------------------------------------------------------------------
# 7.5. Firewall: nếu ufw đang bật, mở cổng cần thiết (DNS + WebApp + admin)
# ------------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "ufw đang bật - mở cổng 53 (tcp/udp), $APP_PORT/tcp, $ADMIN_PORT/tcp..."
    ufw allow 53/tcp >/dev/null
    ufw allow 53/udp >/dev/null
    ufw allow "$APP_PORT/tcp" >/dev/null
    [ "$APP_PORT" -eq 80 ] && ufw allow "$ADMIN_PORT/tcp" >/dev/null
    ok "Đã mở cổng trong ufw."
fi

# ------------------------------------------------------------------------------
# 8. Kiểm tra tổng thể
# ------------------------------------------------------------------------------
echo
info "Kiểm tra phân giải và kết nối..."
FAILED=0
if dig +short +time=2 +tries=1 "@$LAN_IP" "$DOMAIN" | grep -qx "$LAN_IP"; then
    ok "Pi-hole: $DOMAIN -> $LAN_IP"
else
    warn "Pi-hole không trả lời đúng cho $DOMAIN"
    FAILED=1
fi
if getent hosts "$DOMAIN" >/dev/null 2>&1; then
    ok "Host phân giải được $DOMAIN"
else
    warn "Host chưa phân giải được $DOMAIN (thử: resolvectl flush-caches)"
    FAILED=1
fi
if curl -s --max-time 5 -o /dev/null "$APP_URL/healthz"; then
    ok "WebApp trả lời tại $APP_URL"
else
    warn "WebApp chưa trả lời (xem: journalctl -u vps-commander -n 50 --no-pager)"
    FAILED=1
fi

# ------------------------------------------------------------------------------
# 9. Tổng kết
# ------------------------------------------------------------------------------
echo
c "92" "══════════════════════════════════════════════════════════════════"
c "92" "  CÀI ĐẶT HOÀN TẤT (Pi-hole trực tiếp, không Docker)"
c "92" "══════════════════════════════════════════════════════════════════"
echo "  WebApp        : $APP_URL"
echo "  Pi-hole admin : $ADMIN_URL"
echo "  DNS nội bộ    : $DOMAIN -> $LAN_IP"
echo "  Mật khẩu admin: $PIHOLE_PASSWORD   (lưu trong $SCRIPT_DIR/.env)"
echo
echo "  Quản lý dịch vụ:"
echo "    systemctl status pihole-FTL vps-commander"
echo "    journalctl -u vps-commander -f"
echo
echo "  Để cả LAN dùng được: trỏ DNS DHCP của router về $LAN_IP,"
echo "  và tắt Secure DNS/DoH trong trình duyệt."
echo
[ "$FAILED" -eq 0 ] || warn "Còn bước kiểm tra chưa đạt - xem cảnh báo phía trên."
