# near-node-ctl

Hai script bash để chạy NEAR validator trên VPS Linux (Ubuntu), không dùng Docker:

| Script | Dùng khi | Làm gì |
|---|---|---|
| `nearauto.sh` | VPS mới, node đầu tiên | Cài deps + Rust + NEAR CLI, build `nearcore`, init 1 node chạy bằng root (`/root/.near`, `neard.service`) |
| `nearctl.sh` | Đã có node từ `nearauto.sh`, muốn thêm node trên cùng VPS | Mỗi node 1 user Linux + 1 systemd service + port riêng, dùng chung 1 binary; TUI theo dõi; upgrade lần lượt; doctor |

Validator ngoài top 100 (chunk validator) chỉ tốn khoảng 8–10 GB RAM và 50 GB NVMe, nên 1 VPS 64 GB / 2 TB chạy được nhiều node. Giới hạn thật thường là **CPU** (NEAR khuyến nghị 8 core vật lý cho mỗi chunk validator), nên thêm từng node một và theo dõi tỷ lệ endorsement (cần từ 70% trở lên).

---

## 1. `nearauto.sh` — cài node đầu tiên

Chạy bằng root trên VPS mới:

```bash
bash nearauto.sh
```

Script hỏi lần lượt:
1. Network: `mainnet` (mặc định) / `testnet` / custom (tên + RPC URL)
2. Loại node: Validator (`NoShards`) / RPC (`AllShards`, cần ~2 TB)
3. Version nearcore (xem https://github.com/near/nearcore/releases)
4. Pool ID, ví dụ `mypool.poolv1.near`

Kết quả:
- Source + binary: `/root/nearcore/target/release/neard`
- Data, config, key: `/root/.near`
- Service: `/etc/systemd/system/neard.service` (đã enable, **chưa start**)
- `config.json`: `gc_num_epochs_to_keep=3`, tracked shards theo loại node, boot nodes lấy từ RPC
- sysctl tối ưu mạng: `/etc/sysctl.d/local.conf`

Sau khi cài:
```bash
near login                                    # đăng nhập ví
systemctl start neard
journalctl -n 100 -f -u neard | ccze -A       # xem log
```

---

## 2. `nearctl.sh` — nhiều node trên cùng VPS

### Mô hình

- **Node root** (từ `nearauto.sh`) **giữ nguyên**: script không sửa service, config hay data của nó. Nó chỉ được đăng ký vào dashboard với tên `root` và giữ chỗ port (24567 / 3030).
- **Mỗi node mới**:
  - user `near-<name>`
  - `--home` riêng: `/home/near-<name>/.near` (config, genesis, `node_key.json`, `validator_key.json`, `data/`)
  - service `neard-<name>` chạy bằng user đó, có `MemoryMax=16G` và `LimitNOFILE=65535`
  - port tự cấp: P2P `24568, 24569, …` (public); RPC + `/metrics` `127.0.0.1:3031, 3032, …`
  - credentials `near login` riêng trong `~/.near-credentials` của user đó
- **Build 1 lần cho tất cả**: build trong `/root/nearcore` (như cách upgrade thủ công cũ), rồi copy ra `/usr/local/lib/neard/neard-<version>`. `/usr/local/bin/neard` là symlink tới bản đang dùng. Phải copy vì user khác không đọc được `/root`.
- Registry: `/etc/near-nodes/<name>.env`

```
/root/.near/                       node root (không đổi)
/home/near-node2/.near/            node2: config, keys, data/
/home/near-node3/.near/            node3 ...
/usr/local/bin/neard               -> /usr/local/lib/neard/neard-<ver>   (binary chung)
/etc/systemd/system/neard-*.service
/etc/near-nodes/*.env
```

### Cài đặt

```bash
bash nearctl.sh setup              # deps còn thiếu, đăng ký node root, cài /usr/local/bin/nearctl
nearctl build 2.14.1               # nên dùng version root đang chạy: make gần như no-op, chỉ copy binary
nearctl use 2.14.1
```

### Cập nhật script

```bash
scp nearctl.sh root@<vps>:/root/ && ssh root@<vps> bash /root/nearctl.sh install
```
Phải thấy dòng `installed /usr/local/bin/nearctl (N lines, md5 …)`. Không in gì nghĩa là file upload bị cắt cụt; upload lại bằng `scp`, không paste qua terminal.

### Thêm node

```bash
nearctl add node2 pool2.poolv1.near mainnet   # tạo user + neard init + config + service (+ ufw nếu đang bật)
nearctl info node2                            # public key của validator để dùng cho pool
nearctl start node2
sudo -iu near-node2                           # near login / near-validator với credentials riêng
```

Mở port P2P của node ở firewall nhà cung cấp cloud. Không bắt buộc, nhưng nên mở: không mở thì node có ít peer hơn và dễ mất endorsement.

**Không copy `config.json`, `node_key.json` hay `validator_key.json` từ node khác** (kể cả từ root). Config cũ mang theo port và boot nodes cũ; node_key trùng thì node có 0 peer; validator key trùng nghĩa là 1 pool đang ký trên 2 node.

### Nâng cấp nearcore

Thay cho lệnh cũ `cd ~/nearcore && git fetch && git checkout <ver> -f && make release && systemctl stop neard && systemctl start neard`:

```bash
nearctl upgrade 2.15.0
```
1. `git fetch` + `checkout` + `make release` trong `/root/nearcore` (1 lần build, mức ưu tiên CPU/IO thấp nhất)
2. Copy sang `/usr/local/lib/neard/neard-2.15.0` và chuyển symlink
3. Restart lần lượt: **root trước**, rồi từng node; đợi node sync xong mới sang node kế tiếp. Node nào sau 30 phút chưa sync lại thì dừng.

Làm tay từng bước:
```bash
nearctl build 2.15.0 && nearctl use 2.15.0
systemctl restart neard          # node root
nearctl restart all              # các node nearctl, lần lượt
```
Rollback các node mới: `nearctl use 2.14.1 && nearctl restart all`. Node root phải build lại bản cũ trong `/root/nearcore`.

### Theo dõi & vận hành

```bash
nearctl                    # TUI: ↑/↓ chọn, s start, x stop, r restart, l logs (Ctrl-C quay lại), i info, q thoát
nearctl list               # bảng 1 lần: state, CPU%, RAM, disk, port, block height, sync
nearctl logs node2         # hoặc: nearctl logs root
nearctl info node2         # port, key, version, trạng thái sync
nearctl start|stop|restart node2
nearctl restart all        # chỉ các node nearctl, lần lượt; node root phải gọi đích danh
```

### Xử lý sự cố

```bash
nearctl doctor             # kiểm tra (chỉ đọc), có FAIL thì exit 1
nearctl fix-ports node2    # đặt lại port trong config.json theo registry
nearctl boot-nodes node2   # lấy lại boot nodes từ RPC public
nearctl new-config node2   # tạo config.json mới từ binary hiện tại + áp lại thiết lập (backup config cũ)
```

`doctor` kiểm tra:
- **Host:** binary chung, RAM còn trống, dung lượng `/home`
- **Port:** config khớp registry không, có trùng giữa các node không, RPC có bị mở public không
- **Key:** có tồn tại không, quyền 600, có trùng giữa các node không, có khớp pool không; `chain_id` có khớp network không
- **Quyền file:** file nào không thuộc user của node
- **Service:** enable/active, số lần restart, lỗi gần nhất trong log
- **Port P2P:** có đúng tiến trình của node đó đang giữ không; `ufw` có cho phép không
- **Sync và peers:** đã sync chưa, số peer
- **Tiến trình lạ:** `neard` chạy ngoài các service đã đăng ký (nguy cơ ký trùng)

| Triệu chứng | Nguyên nhân thường gặp | Sửa |
|---|---|---|
| `Address already in use` 0.0.0.0:24567 | config copy từ node root | `nearctl fix-ports <name>` hoặc `nearctl new-config <name>` |
| `Waiting for peers 0 peers` ở block 9820210 | node_key trùng / boot nodes cũ / config cũ | tạo node_key mới, `nearctl boot-nodes <name>` hoặc `nearctl new-config <name>` |
| `no validator key` | thiếu `validator_key.json` | đặt file key của pool vào `.near/`, `chmod 600`, chown cho user của node |
| `encountered unrecognized fields` | config từ version cũ | `nearctl new-config <name>` |

### Xóa node

```bash
nearctl remove node2       # dừng + gỡ service/registry/ufw; GIỮ user và data
```
Muốn xóa hẳn (**không hoàn tác được**, nên backup key trước):
```bash
mkdir -p /root/key-backup/node2 && cp -p /home/near-node2/.near/*_key.json /root/key-backup/node2/
userdel -r near-node2
```
Trước khi xóa, unstake hoặc chuyển pool sang node khác. Nhớ đóng port ở firewall của nhà cung cấp cloud.

### Tất cả lệnh

```
setup | install | build <ver> | use <ver> | upgrade <ver>
add <name> <pool> [net] | remove <name> | new-config <name> | fix-ports <name> | boot-nodes <name>
start|stop|restart <name|all> | logs <name> | info <name> | list | doctor | tui (mặc định)
Env: MEM_MAX (mặc định 16G, áp dụng khi add), RPC_URL (network custom)
```
