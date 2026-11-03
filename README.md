# vps-local-dns — Pi-hole + tên miền nội bộ + HTTPS (cho dự án bất kỳ)

Deploy kit **độc lập, dùng chung được cho mọi dự án web** (không bó buộc vào
VPS-Commander): trong mạng LAN truy cập WebApp của bạn bằng
`http://vps.vn` (bản cài trực tiếp) hoặc `http://vps.vn:5000` (bản Docker),
với Pi-hole làm DNS nội bộ, và có thể bật thêm **HTTPS nội bộ** bằng Caddy.
Không mở gì ra Internet, không cần mua tên miền, không sửa code ứng dụng.

```
Thiết bị trong LAN ──DNS──> Pi-hole (192.168.2.38:53) ──> trả lời vps.vn = 192.168.2.38
                   │
                   └──HTTP──> http://vps.vn ──> WebApp của bạn (dự án bất kỳ)
                   └──HTTPS─> https://vps.vn ──> Caddy (tls internal) ──> WebApp
```

App mặc định tìm thư mục `vps-commander` nằm cạnh kit, nhưng **bất kỳ thư mục
dự án nào** có `app.py`/`requirements.txt` (Python) — hay server Node/Go/... —
đều chạy được; xem phần [Dùng cho dự án bất kỳ](#dùng-cho-dự-án-bất-kỳ).

## Vì sao không cài Pi-hole "chuẩn" (chiếm 0.0.0.0:53)

Máy này đang dùng `systemd-resolved` (127.0.0.53:53) **và Tailscale MagicDNS**
(100.100.100.100). Cách cài Pi-hole thông thường sẽ tắt stub resolver, chiếm
toàn bộ cổng 53 và làm hỏng DNS của host/Tailscale, đồng thời làm container
không phân giải được tên miền.

Bộ file này thay vào đó:

- Pi-hole chỉ bind `53` trên **IP LAN** (`192.168.2.38:53`), không đụng
  `127.0.0.53:53`.
- Thêm một **split-DNS** nhỏ vào `systemd-resolved`: chỉ các truy vấn `vps.vn`
  mới đi qua Pi-hole; mọi domain khác vẫn dùng DNS cũ.
- Pi-hole lắng nghe `ALL` interface (bắt buộc với bridge network) và lưu cấu
  hình trong `etc-pihole/` của kit.

## Cài trực tiếp trên Ubuntu/Debian (không Docker — khuyến nghị)

Máy chưa có Docker thì dùng cách này: Pi-hole chạy native qua `systemd`,
WebApp chạy bằng `gunicorn` + `systemd`. Chạy được trên **bất kỳ server Ubuntu
nào** — script tự dò IP LAN, tự sinh mật khẩu, tự tạo `.env`.

```bash
cd ~/projects/vps-local-dns
sudo setsid bash ./install-native.sh > /tmp/vps-native.log 2>&1
tail -f /tmp/vps-native.log
```

Script tự: cài gói phụ thuộc → cài Pi-hole v6 bằng installer chính thức (tự trả
lời các hộp thoại) → cấu hình FTL `listeningMode=BIND` để **chỉ bind 53 trên IP
LAN** → bật lại `systemd-resolved` + split-DNS cho tên miền nội bộ → tạo `.venv`
và chạy WebApp qua `systemd` (tự lên lại khi reboot). Nếu `ufw` đang bật, tự mở
cổng 53, cổng WebApp và cổng admin.

Tùy chỉnh theo server (cờ CLI hoặc biến môi trường tương đương):

```bash
sudo ./install-native.sh --help            # danh sách đầy đủ
sudo ./install-native.sh --domain vps.home --ip 192.168.1.153
sudo ./install-native.sh --app-dir ~/projects/my-webapp       # dự án khác
sudo ./install-native.sh --app-name my-webapp                  # tên service systemd
sudo ./install-native.sh --port 5000       # giữ cổng 5000 cho WebApp
sudo ./install-native.sh --no-service      # chỉ cài DNS, không tạo service app
sudo UPSTREAM_DNS="9.9.9.9;149.112.112.112" ./install-native.sh
```

Kết quả (với mặc định): gõ **`http://vps.vn`** là vào thẳng WebApp (không cần
`:5000`), vì app bind cổng 80 bằng `AmbientCapabilities=CAP_NET_BIND_SERVICE`
chứ không chạy root. Trang quản trị Pi-hole được dời sang
**`http://<IP_LAN>:8080/admin`** để nhường cổng 80.

> Vì sao `BIND`: Pi-hole v6 có 5 chế độ nghe. `LOCAL` (mặc định) vẫn bind
> `0.0.0.0:53`; `BIND` mới thật sự bind riêng địa chỉ của interface — nhờ vậy
> `systemd-resolved` (127.0.0.53:53) và Tailscale MagicDNS vẫn sống bình thường.

Quản lý sau khi cài:

```bash
systemctl status pihole-FTL vps-commander   # (tên service = tên thư mục app)
journalctl -u vps-commander -f
pihole setpassword                          # đổi mật khẩu admin Pi-hole
sudo ./status.sh                            # kiểm tra tổng thể (xem bên dưới)
```

## Dùng cho dự án bất kỳ

`install-native.sh` không bó buộc "VPS Commander". Ba cách cung cấp app:

**1. Dự án Python bất kỳ (Flask/FastAPI/...)** — chỉ cần `requirements.txt`
và module WSGI. Script tự dò entrypoint: có `wsgi.py` → `wsgi:app`, còn lại
→ `app:app`:

```bash
sudo ./install-native.sh --app-dir ~/projects/my-dash --app-name my-dash
sudo ./install-native.sh --app-dir ~/projects/api --app-module "main:app"
```

**2. Server KHÔNG phải Python** (Node, Go, Rust,...) — dùng `--start-cmd`,
script bỏ qua venv/gunicorn và chạy lệnh của bạn dưới systemd:

```bash
sudo ./install-native.sh --app-dir ~/projects/web-tool --start-cmd "npm start"
sudo ./install-native.sh --app-dir ~/projects/goweb --start-cmd "./server --port 80"
```

**3. Chỉ cài DNS, không đụng app**:

```bash
sudo ./install-native.sh --no-service
```

Tên service systemd mặc định lấy từ **tên thư mục app** (vd `vps-commander`
→ service `vps-commander`), đổi bằng `--app-name`. Service giữ đúng cấu trúc
an toàn đã có: chạy bằng user thư thường, không root, tự restart khi sự cố
(`Restart=on-failure`), tự bind cổng < 1024 bằng capability.

## Kiểm tra tình trạng (status.sh)

Một lệnh xem toàn bộ hệ thống có sống không — DNS, split-DNS, WebApp, HTTPS:

```bash
./status.sh                       # đọc cấu hình trong .env của kit
./status.sh --app-name my-dash    # nếu service đặt tên khác
./status.sh --port 5000           # nếu WebApp chạy cổng khác
```

## Gỡ cài đặt (uninstall.sh)

```bash
sudo ./uninstall.sh                   # gỡ service app + Pi-hole + split-DNS
sudo ./uninstall.sh --app-name my-dash
sudo ./uninstall.sh --purge-pihole    # xoá nốt dữ liệu /etc/pihole...
sudo ./uninstall.sh --remove-ufw      # xoá rule 53/80/5000/443/8080
```

Script hỏi xác nhận từng phần; `--yes` để chạy không tương tác. File `.env` của
kit (chứa mật khẩu) **không** bị xoá tự động.

## Cài bằng Docker (tuỳ chọn)

Nếu sau này bạn cài Docker:

```bash
sudo ./setup.sh
```

Script sẽ tự: cài Docker (nếu thiếu) → tạo `.env` + mật khẩu Pi-hole → thêm
split-DNS → chạy Pi-hole → kiểm tra `vps.vn` → đặt `VPS_HOST=0.0.0.0` trong
`.env` gốc để app nghe ra LAN.

Máy có nhiều dải LAN thì chọn đúng dải đang dùng:

```bash
sudo LAN_IP=192.168.1.153 ./setup.sh
```

Nếu `ufw` đang bật và bạn muốn script tự mở cổng:

```bash
sudo ALLOW_UFW=1 ./setup.sh
```

Ghi chú Docker:

- Image đã **pin tag** (`pihole/pihole:2026.10.1` — bản vá bảo mật mới nhất:
  Core v6.5, FTL v6.8, Web v6.6.1). Nâng cấp: đổi tag trong `docker-compose.yml`
  rồi `docker compose pull && docker compose up -d`.
- Trang admin Pi-hole chỉ publish trên **IP LAN** (không mở 0.0.0.0), đổi cổng
  bằng `PIHOLE_ADMIN_PORT` trong `.env`.
- Container có **healthcheck** tự động (dig pi.hole mỗi 60s).

## HTTPS nội bộ + nghiên cứu chứng chỉ SSL

### Các đường chứng chỉ (so sánh nhanh)

| Phương án | Cần gì | Thiết bị LAN tin lúc đầu? | Dùng khi nào |
|---|---|---|---|
| **Caddy `tls internal`** (kit dùng) | Không cần gì thêm; root CA 10 năm, cert 12h tự gia hạn | Không — phải import `root.crt` 1 lần | LAN không có tên miền công khai — **mặc định của kit** |
| Tự ký "trần trụi" (self-signed trực tiếp) | `openssl` | Không, và không có cơ chế gia hạn/tự động | Chỉ test 1 máy, không nên |
| mkcert | Cài mkcert từng máy phát triển | Không | Dev môi trường máy cá nhân |
| Easy-RSA / Smallstep | Tự quản CA, phức tạp hơn | Không | Nhiều server, cần PKI thật |
| **Let's Encrypt (HTTP-01)** | **Tên miền công khai** trỏ được về IP | Có (trust toàn cầu), nhưng chỉ khi DNS public | Có domain + mở 80/443 ra Internet |
| **Let's Encrypt (DNS-01)** | Tên miền công khai + API DNS (Cloudflare...) | Có, và cert cho wildcard; không cần mở port | Có domain nhưng muốn mọi thứ vẫn chỉ-LAN |
| Tailscale HTTPS | Tailscale | Có trong mesh | Đã dùng Tailscale, truy cập qua tailnet |

Khuyến nghị của kit: dùng **Caddy `tls internal`** — nó quản cả CA nội bộ,
cấp, gia hạn (12h) và cài trust một cách tự động; bạn chỉ việc phát
`root.crt` cho các thiết bị trong LAN import 1 lần.

Lưu ý: tên miền nội bộ `vps.vn` không xin Let's Encrypt được — không phải
tên miền công khai, CA sẽ từ chối (lỗi "invalid public suffix"), trừ khi bạn
dùng tên miền thật trỏ về IP công cộng. Vì vậy với HTTPS nội bộ, **mặc định
của kit là Caddy `tls internal`**; nếu có domain riêng + DNS public có API
(Cloudflare...) thì chuyển sang **Let's Encrypt DNS-01** để mọi thiết bị tin
luôn mà không cần import gì.

### Cài HTTPS (bản native)

```bash
sudo ./setup-https.sh                  # backend mặc định cổng 80
sudo ./setup-https.sh --port 5000      # nếu WebApp chạy cổng 5000
sudo ./setup-https.sh --domain vps.home
```

Script làm: cài Caddy (repo chính thức) → viết Caddyfile
`https://$DOMAIN -> reverse_proxy 127.0.0.1:$APP_PORT` với `tls internal` →
import root CA vào trust store máy này (và Chrome/Chromium nếu có `certutil`)
→ xuất **`certs/root.crt`** để chép sang thiết bị khác → đặt
`VPS_COOKIE_SECURE=true` trong `.env` của app → mở ufw 443/tcp+udp (HTTP/3).

### Cho thiết bị khác trong LAN tin chứng chỉ

Chép `certs/root.crt` về thiết bị rồi import:

- **Windows**: double-click `root.crt` → Install Certificate → Local Machine →
  Trusted Root Certification Authorities.
- **Android**: Settings → Security → Encryption & credentials → Install a
  certificate → CA certificate (từ file).
- **macOS / iOS**: mở file → cài vào Profile → bật Trust full cho CA.
- **Linux**: `sudo cp root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`
- **Firefox** (mọi hệ): Settings → Privacy & Security → Certificates →
  View Certificates → Authorities → Import `root.crt`.

Ghi chú kỹ thuật từ nghiên cứu:

- Caddy dùng thư viện **Smallstep** làm CA; root 10 năm, intermediate 7 ngày,
  leaf 12 giờ nhưng **tự gia hạn** — thiết bị chỉ cần tin root 1 lần.
- Nhớ **đừng xoá** thư mục dữ liệu Caddy (`/var/lib/caddy/.local/share/caddy`),
  nếu xoá thì Caddy phát sinh root mới và hết thiết bị nào tin root cũ.
- Browser có **DoH / Secure DNS** sẽ bỏ qua Pi-hole → nhớ tắt (xem phần dưới).
- Cookie của app phải dùng `VPS_COOKIE_SECURE=true` (script tự đặt) để cookie
  session không bị gửi ra HTTP thường.

## Làm thủ công (không dùng script)

```bash
cp .env.example .env      # sửa LAN_IP + PIHOLE_PASSWORD
docker compose up -d
```

Rồi thêm split-DNS cho host:

```bash
sudo tee /etc/systemd/resolved.conf.d/99-vps-local-domain.conf >/dev/null <<'EOF'
[Resolve]
DNS=192.168.2.38
Domains=~vps.vn
EOF
sudo systemctl restart systemd-resolved
```

Và cho app nghe ra LAN (trong `.env` ở thư mục gốc):

```bash
VPS_HOST=0.0.0.0
```

sau đó `docker compose up -d` ở thư mục gốc.

> `.env` được truyền cho app, đồng thời Compose dùng `VPS_HOST` để quyết định
> địa chỉ publish cổng 5000 (`"${VPS_HOST:-127.0.0.1}:5000:5000"`).
> `127.0.0.1` = chỉ máy này; `0.0.0.0` = cả LAN.

## Kiểm tra

```bash
./status.sh                               # tổng thể (khuyến nghị)
dig +short @192.168.2.38 vps.vn           # -> 192.168.2.38
resolvectl query vps.vn                   # -> 192.168.2.38
curl -I http://vps.vn/healthz             # -> 200 OK (bản native, cổng 80)
curl -I http://vps.vn:5000/healthz        # -> 200 OK (bản Docker)
curl -I https://vps.vn/healthz            # -> 200 OK (nếu đã cài HTTPS)
```

Mở `http://vps.vn` → đăng nhập bằng token `VPS_WEB_TOKEN` trong `.env`.
Quản trị Pi-hole: `http://192.168.2.38:8080/admin` (native) hoặc
`http://192.168.2.38/admin` (Docker).

## Cho cả LAN dùng tên miền này

Pi-hole chỉ trả lời các thiết bị **đang dùng nó làm DNS**. Chọn một trong hai:

1. **Router DHCP (khuyến nghị)**: đặt DNS server cấp cho DHCP = `192.168.2.38`.
   Tất cả thiết bị trong LAN tự nhận, kể cả điện thoại.
2. **Từng thiết bị**: đặt DNS thủ công = `192.168.2.38` (ví dụ trên Windows:
   Settings → Network → DNS server assignment).

Lưu ý:

- Một số router không cho đổi DNS DHCP; khi đó dùng cách 2 (đặt DNS thủ công
  trên từng thiết bị).
- **Tắt DNS-over-HTTPS / "Secure DNS"** trong Chrome/Edge/Firefox, nếu không
  trình duyệt sẽ tự hỏi Cloudflare/Google và bỏ qua Pi-hole.
- Nếu Pi-hole tắt, các thiết bị trỏ DNS vào nó sẽ mất Internet. Muốn an toàn,
  cấu hình thêm DNS phụ (nhưng khi đó `vps.vn` có thể không phân giải được).

## Pi-hole lọc quảng cáo?

Mặc định bộ này bật blocklist của Pi-hole. Thiết bị dùng Pi-hole làm DNS sẽ
được lọc quảng cáo — tiện, nhưng nếu chỉ muốn tên miền nội bộ mà không lọc,
vào **Settings → DNS → Blocklists** và xoá các danh sách.

## Đổi IP / đổi tên miền

```bash
sed -i 's/^LAN_IP=.*/LAN_IP=192.168.2.50/' .env
sed -i 's/^VPS_HOSTNAME=.*/VPS_HOSTNAME=vps.home/' .env
docker compose up -d
sudo ./setup.sh          # cập nhật lại split-DNS + kiểm tra
```

Nhớ cập nhật cả DNS trên router nếu IP đổi. Nên đặt **DHCP reservation** cho
máy này để IP không thay đổi.

## Xử lý sự cố

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| `bind: address already in use` ở cổng 53 | Có tiến trình khác giữ `LAN_IP:53` (`sudo ss -lunp \| grep :53`). Nếu là `dnsmasq`/`pihole-FTL` cài ngoài Docker, tắt nó trước. |
| `dig @192.168.2.38 vps.vn` không trả lời | `docker compose logs pihole`; kiểm tra `LAN_IP` trong `.env` có đúng IP card mạng không. |
| Máy này phân giải được, máy khác không | Thiết bị kia chưa dùng Pi-hole làm DNS, hoặc `ufw` chặn cổng 53. |
| Trình duyệt vẫn báo không tìm thấy | Secure DNS (DoH) đang bật, hoặc cache DNS: `resolvectl flush-caches`, `chrome://net-internals/#dns`. |
| `permission denied` khi chạy `docker compose` | Chưa đăng xuất/đăng nhập lại sau khi được thêm nhóm `docker`, hoặc dùng `sudo`. |
| `vps.vn` ra IP công cộng | Domain `.vn` có thể đã được đăng ký ở nơi khác. Trong LAN, Pi-hole vẫn thắng nếu thiết bị dùng DNS nội bộ; nếu không, đổi `VPS_HOSTNAME=vps.home`. |
| `ERR_CERT_AUTHORITY_INVALID` khi vào HTTPS | Thiết bị chưa tin root CA: import `certs/root.crt` (hướng dẫn ở phần HTTPS). |
| HTTPS hoạt động -k được nhưng không -k | Máy host chưa chạy `update-ca-certificates` với root.crt; chạy lại `setup-https.sh` hoặc import thủ công. |
| Caddy vừa cài xong không chạy | `systemctl status caddy` + `journalctl -u caddy -n 50`; thường là Caddyfile không hợp lệ (xem backup `/etc/caddy/Caddyfile.bak.*`). |
| App service không chạy sau khi cài HTTPS | Caddy đặt `VPS_COOKIE_SECURE=true` vào `.env` app; `sudo systemctl restart <app-service>` để áp dụng. |
| Pi-hole bản Docker muốn nâng cấp | Đổi tag trong `docker-compose.yml`, rồi `docker compose pull && docker compose up -d`. |
| Chạy bằng `./run.sh` (không Docker) thì không vào được từ LAN | `.env` đã có `VPS_HOST=0.0.0.0` nhưng app phải khởi động lại; `Ctrl+C` rồi `./run.sh` lại. |

## Gỡ cài đặt

Dùng `sudo ./uninstall.sh` (xem đầu tài liệu). Hoặc làm tay:

```bash
sudo systemctl disable --now vps-commander
sudo rm -f /etc/systemd/system/vps-commander.service
sudo systemctl daemon-reload

sudo pihole uninstall                       # gỡ Pi-hole (hỏi xác nhận)

sudo rm -f /etc/systemd/resolved.conf.d/99-vps-local-domain.conf \
           /etc/systemd/resolved.conf.d/90-pi-hole-disable-stub-listener.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

Dữ liệu Pi-hole nằm ở `/etc/pihole` và `/var/log/pihole`; xoá thêm nếu muốn
sạch hoàn toàn. Gỡ HTTPS: `sudo apt purge caddy` + xoá Caddyfile backup.

## Bảo mật

- Ứng dụng mở ra LAN nghĩa là **ai trong LAN cũng chạm được trang đăng nhập**.
  Giữ `VPS_WEB_TOKEN` dài, ngẫu nhiên; không đặt `VPS_AUTH_DISABLED=true`.
- Pi-hole admin (`/admin`) cũng lộ ra LAN — dùng mật khẩu mạnh trong `.env`.
- Không publish cổng 53 ra Internet (router không NAT cổng 53 vào máy này).
  DNS mở ra Internet sẽ bị lợi dụng để khuếch đại DDoS.
- **TLS nội bộ là trust "cả LAN chép nhau"**: ai có `root.crt` có thể MITM
  được HTTPS nội bộ của những máy tin root đó (trong LAN thì chấp nhận được);
  không dùng CA nội bộ này cho dịch vụ ra Internet.
- Toàn bộ chỉ dùng HTTP trong LAN trừ khi bạn bật `setup-https.sh`.
