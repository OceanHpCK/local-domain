# vps-local-dns — Pi-hole + tên miền nội bộ cho VPS Commander

Deploy kit **độc lập** để trong mạng LAN truy cập WebApp VPS Commander bằng
`http://vps.vn` (bản cài trực tiếp) hoặc `http://vps.vn:5000` (bản Docker),
dùng Pi-hole làm DNS nội bộ. Không mở gì ra Internet, không cần mua tên miền,
không sửa code ứng dụng. App có thể lấy từ
[VPS-Commander](https://github.com/OceanHpCK/VPS-Commander) — kit tự dò thư mục
`vps-commander` nằm cạnh, hoặc truyền `--app-dir`.

```
Thiết bị trong LAN ──DNS──> Pi-hole (192.168.2.38:53) ──> trả lời vps.vn = 192.168.2.38
                   │
                   └──HTTP──> http://vps.vn (hoặc :5000 với bản Docker) ──> vps-commander
```

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
sudo ./install-native.sh --app-dir ~/projects/vps-commander   # app ở chỗ khác
sudo ./install-native.sh --port 5000       # giữ cổng 5000 cho WebApp
sudo ./install-native.sh --no-service      # không tạo systemd cho WebApp
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
systemctl status pihole-FTL vps-commander
journalctl -u vps-commander -f
pihole setpassword                    # đổi mật khẩu admin Pi-hole
```

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
dig +short @192.168.2.38 vps.vn          # -> 192.168.2.38
resolvectl query vps.vn                  # -> 192.168.2.38
curl -I http://vps.vn/healthz            # -> 200 OK (bản native, cổng 80)
curl -I http://vps.vn:5000/healthz       # -> 200 OK (bản Docker)
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
| Pi-hole admin mở nhầm app | Bản native: WebApp ở cổng 80 (`http://vps.vn`), Pi-hole admin ở `:8080/admin`. Bản Docker: app ở `:5000`, admin ở cổng 80. |
| Chạy bằng `./run.sh` (không Docker) thì không vào được từ LAN | `.env` đã có `VPS_HOST=0.0.0.0` nhưng app phải khởi động lại; `Ctrl+C` rồi `./run.sh` lại. |

## Gỡ cài đặt (bản native)

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
sạch hoàn toàn.

## Bảo mật

- Ứng dụng mở ra LAN nghĩa là **ai trong LAN cũng chạm được trang đăng nhập**.
  Giữ `VPS_WEB_TOKEN` dài, ngẫu nhiên; không đặt `VPS_AUTH_DISABLED=true`.
- Pi-hole admin (`/admin`) cũng lộ ra LAN — dùng mật khẩu mạnh trong `.env`.
- Không publish cổng 53 ra Internet (router không NAT cổng 53 vào máy này).
  DNS mở ra Internet sẽ bị lợi dụng để khuếch đại DDoS.
- Toàn bộ chỉ dùng HTTP trong LAN; nếu cần HTTPS nội bộ, thêm Caddy với
  chứng chỉ tự ký rồi đổi `VPS_COOKIE_SECURE=true`.
