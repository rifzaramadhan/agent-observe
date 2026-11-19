# Agent Observe

Instalasi Zabbix Agent 2 dan Vector Agent untuk **Rocky Linux 10 x86_64**. Skrip memasang paket RPM yang belum tersedia, menyiapkan konfigurasi, memvalidasinya, lalu mengaktifkan layanan melalui systemd.

## Prasyarat

- Jalankan di server Rocky Linux 10 x86_64 yang akan dipantau. Siapkan akses `sudo` atau root dan pastikan systemd berjalan.
- Untuk instalasi paket, server memerlukan `curl` dan akses HTTPS ke repositori paket. Jika kedua paket sudah terpasang, skrip melewati pengecekan internet dan langsung melanjutkan konfigurasi.
- Pastikan Zabbix Server atau Proxy menerima **active checks** dan Vector Aggregator memiliki listener **Vector native** yang bisa dijangkau dari server agen.

## Instalasi

Jalankan perintah berikut di server yang akan dipantau. Alternatifnya, unduh file [install-agents-rocky10.sh](./install-agents-rocky10.sh) dari repositori dan jalankan dari direktori unduhan.

```bash
git clone https://github.com/rifzaramadhan/agent-observe.git
cd agent-observe
bash install-agents-rocky10.sh --help
sudo bash install-agents-rocky10.sh
```

Jika ada paket yang belum terpasang, skrip mengecek akses HTTPS ke repositori yang diperlukan sebelum mengunduh atau memasang paket. Jika pengecekan gagal, skrip menampilkan endpoint yang bermasalah dan menghentikan instalasi.

| Komponen | Pengaturan default |
| --- | --- |
| Zabbix Agent 2 | Seri `8.0`, active checks ke `10.7.146.72:10051`, menggunakan hostname OS |
| Vector Agent | Log `journald` dan metrik host dikirim ke `10.7.146.73:6000` dengan protokol Vector native dan buffer disk 512 MiB |

## Contoh penggunaan

**Tentukan hostname Zabbix dan endpoint sendiri.** Ganti nama contoh dengan nilai di lingkungan Anda. Gunakan `--logs-only` untuk mematikan metrik host. Log `journald` dan file aplikasi yang Anda pilih tetap dikirim.

```bash
sudo bash install-agents-rocky10.sh \
  --hostname rocky-app-01 \
  --zabbix-server zabbix.example.com \
  --vector-aggregator vector.example.com \
  --logs-only
```

**Aktifkan TLS pada kedua koneksi.** Koneksi default menggunakan plaintext. Untuk Zabbix, siapkan file berisi satu baris kunci PSK heksadesimal dan konfigurasikan identitas serta kunci yang sama pada host di Zabbix. Untuk Vector, aktifkan TLS pada aggregator dan gunakan nama DNS yang sesuai dengan sertifikatnya.

```bash
sudo bash install-agents-rocky10.sh \
  --hostname rocky-app-01 \
  --zabbix-server zabbix.example.com \
  --psk-identity rocky-app-01 \
  --psk-file /root/rocky-app-01.psk \
  --vector-aggregator vector.example.com \
  --vector-ca /root/vector-ca.pem
```

Gunakan `--vector-tls` jika sertifikat aggregator sudah dipercaya oleh sistem. Opsi `--vector-ca` mengaktifkan TLS dan menggunakan CA internal dari file PEM.

| Opsi lain | Kegunaan |
| --- | --- |
| `--zabbix-series 7.0` | Pilih paket Zabbix Agent 2 seri 7.0. Untuk agen yang sudah terpasang, pilih seri yang sesuai dengan versi terpasang. |
| `--zabbix-port PORT`, `--vector-port PORT` | Ubah port tujuan active checks Zabbix atau port Vector native. |
| `--passive` | Aktifkan juga passive checks TCP 10050 dari alamat `--zabbix-server`. Jika diperlukan, izinkan akses TCP 10050 dari server tersebut pada firewall. |
| `--replace-config` | Izinkan penggantian konfigurasi dari deployment lain. Tinjau dulu konfigurasi yang ada. Skrip menyimpan salinan file yang diganti di `/var/backups/victoria-agents/`. |

## Ubah konfigurasi setelah instalasi

Setelah instalasi atau konfigurasi berhasil, skrip menyimpan pengaturan di `/etc/agent-observe.args`. File tersebut hanya dapat diakses root. Isinya mencatat opsi deployment dan path file PSK atau CA yang dikelola skrip.

Gunakan `--configure-only` sebagai opsi pertama. Tentukan hanya perubahan yang diinginkan. Skrip memuat pengaturan sebelumnya, memvalidasi konfigurasi kedua agen, dan me-restart layanan yang konfigurasinya berubah. Mode ini memerlukan kedua paket sudah terpasang dan berjalan tanpa akses internet.

**Ubah Zabbix Server dan nama host** sambil mempertahankan pengaturan Vector.

```bash
sudo bash install-agents-rocky10.sh --configure-only \
  --zabbix-server zabbix.example.com \
  --hostname rocky-app-02
```

**Tambahkan log Nginx** ke daftar log aplikasi yang sudah dikumpulkan.

```bash
sudo bash install-agents-rocky10.sh --configure-only --app-logs nginx
```

**Ganti daftar file log aplikasi** dengan log Apache saja. Log `journald` tetap dikumpulkan.

```bash
sudo bash install-agents-rocky10.sh --configure-only \
  --clear-app-logs --app-logs apache
```

Opsi `--app-logs`, `--app-log`, dan `--app-log-group` menambah entri ke pengaturan sebelumnya. Gunakan `--clear-app-log-groups` untuk memulai daftar grup tambahan dari kosong. Gunakan `--active-only` untuk mematikan passive checks, `--host-metrics` untuk mengaktifkan kembali metrik host, dan `--zabbix-no-psk` atau `--vector-no-tls` jika koneksi terkait memang akan dikembalikan ke plaintext.

Untuk deployment dari versi lama, jalankan versi skrip terbaru sekali dengan **seluruh opsi deployment yang berlaku**, termasuk endpoint, TLS, sumber log, dan grup yang digunakan. Langkah ini membuat pengaturan awal untuk `--configure-only`. Menjalankan mode instalasi biasa setelah itu tetap menggunakan default dan opsi dari perintah tersebut sebagai konfigurasi lengkap.

## Log aplikasi

Secara default Vector membaca `journald`, termasuk keluaran aplikasi yang masuk ke journal systemd. Tambahkan opsi berikut untuk log yang ditulis langsung ke file.

| Opsi | File yang dibaca |
| --- | --- |
| `--app-logs nginx` | `/var/log/nginx/access.log` dan `/var/log/nginx/error.log` |
| `--app-logs apache` | `/var/log/httpd/access_log` dan `/var/log/httpd/error_log`. Alias `httpd` juga bisa dipakai. |
| `--app-log 'nama=/path/absolut/*.log'` | Path file atau pola dengan `*` dan `?`. Ulangi opsi untuk menambah file atau aplikasi. Bungkus pola dengan tanda kutip agar shell meneruskannya ke Vector. |

Contoh mengaktifkan preset dan log aplikasi sendiri pada host yang menyimpan file tersebut.

```bash
sudo bash install-agents-rocky10.sh \
  --app-logs nginx \
  --app-logs apache \
  --app-log 'my_app=/var/log/my-app/*.log'
```

Gunakan path sesuai konfigurasi aplikasi. Jika Nginx atau Apache menulis ke path khusus, gunakan `--app-log` untuk menunjuk file tersebut. Nama aplikasi pada `--app-log` menggunakan huruf kecil, angka, atau garis bawah dan harus diawali huruf.

Vector mengirim setiap baris dengan field `app_service` dan `file` ke aggregator. Saat pertama menemukan file, Vector membaca dari awal. Untuk file yang sudah memiliki checkpoint, Vector melanjutkan dari posisi terakhir. Pilih pola yang hanya mencakup file yang ingin dikirim dan hindari memasukkan file yang sama dengan nama aplikasi berbeda.

### Akses file log

Layanan Vector perlu akses baca ke file dan akses lintas direktori induknya. Untuk pola wildcard, berikan juga akses daftar isi pada direktori yang dicocokkan. Gunakan grup khusus yang sudah diberi akses ke log, atau ACL untuk user `vector`. Pastikan izin yang sama berlaku untuk file baru setelah rotasi.

Jika menggunakan grup khusus, jalankan skrip dengan `--app-log-group` seperti contoh berikut. Ganti `app-logs` dengan grup yang sudah tersedia di server.

```bash
sudo bash install-agents-rocky10.sh --app-logs nginx --app-log-group app-logs
sudo systemctl show vector -p SupplementaryGroups
```

Untuk menguji, buat permintaan HTTP ke Nginx atau Apache lalu cari baris access log yang baru di Grafana dengan datasource VictoriaLogs. Gunakan field `app_service` jika aggregator meneruskan field tersebut ke VictoriaLogs.

## Log Proxmox VE

Skrip berjalan pada **Rocky Linux**. Aktifkan listener Vector di host Rocky Linux yang dapat dijangkau node Proxmox, lalu kirim log dari setiap node menggunakan rsyslog. Vector meneruskan log ke Vector Aggregator yang sudah dikonfigurasi.

### 1. Aktifkan penerima di Rocky Linux

Contoh ini menggunakan IP receiver `192.0.2.10` dan dua node Proxmox `192.0.2.21` serta `192.0.2.22`. Ganti semua alamat contoh dengan IPv4 di jaringan manajemen Anda.

```bash
sudo bash install-agents-rocky10.sh --configure-only \
  --proxmox-listen 192.0.2.10:1514 \
  --proxmox-node 192.0.2.21 \
  --proxmox-node 192.0.2.22
```

Untuk instalasi awal, gunakan opsi yang sama bersama konfigurasi deployment dan lewati `--configure-only`. Listener mengikat satu IPv4 lokal spesifik dan hanya menerima koneksi dari IP node yang didaftarkan. Izinkan koneksi TCP 1514 dari node tersebut pada firewall jaringan dan host sesuai kebutuhan. Jalur Proxmox ke receiver menggunakan syslog TCP plaintext untuk jaringan manajemen internal. Opsi TLS Vector yang sudah ada berlaku untuk koneksi dari receiver ke aggregator.

### 2. Atur forwarding pada setiap node Proxmox VE

Jalankan sebagai root pada node Proxmox. Pasang rsyslog jika paketnya belum tersedia.

```bash
apt install rsyslog
```

Buat `/etc/rsyslog.d/40-vector-proxmox.conf` dengan isi berikut. Ganti `target` dan `port` sesuai listener Rocky Linux.

```rsyslog
if ($programname startswith "pve" or $programname == "corosync"
    or $programname == "vzdump" or $programname == "qmeventd"
    or $programname == "spiceproxy") then {
    action(
        type="omfwd"
        target="192.0.2.10"
        port="1514"
        protocol="tcp"
        template="RSYSLOG_SyslogProtocol23Format"
        queue.type="linkedList"
        action.resumeRetryCount="-1"
    )
}
```

Jika rsyslog menerima journal melalui `imuxsock`, pastikan systemd-journald meneruskan event ke soket syslog. Jika forwarding belum aktif, buat `/etc/systemd/journald.conf.d/50-rsyslog.conf` dengan pengaturan berikut, lalu jalankan `systemctl restart systemd-journald`. Jika rsyslog sudah membaca journal lewat `imjournal`, gunakan input yang tersedia agar log tidak dikirim dua kali.

```ini
[Journal]
ForwardToSyslog=yes
```

Validasi konfigurasi dan kirim log uji.

```bash
rsyslogd -N1 && systemctl enable rsyslog && systemctl restart rsyslog
logger -t pve-vector-test "pve-vector-test $(hostname) $(date -Is)"
```

### 3. Verifikasi di VictoriaLogs

Cari `pve-vector-test` di Grafana melalui datasource VictoriaLogs. Vector memberi label `platform="proxmox"` sebelum meneruskan log. Gunakan field tersebut jika konfigurasi aggregator meneruskannya ke VictoriaLogs. Aturan forwarding ini mencakup pesan daemon dengan nama program yang dipilih. File access log PVE, output detail task, dan log di dalam VM atau container memerlukan input tambahan pada perangkat yang menyimpan log tersebut.

Untuk mengganti daftar IP pengirim, jalankan `--configure-only --clear-proxmox-nodes` bersama daftar `--proxmox-node` yang baru. Untuk menonaktifkan listener, jalankan `--configure-only --disable-proxmox-syslog`.

## Verifikasi

1. Periksa status layanan dari server agen.

   ```bash
   sudo systemctl is-active zabbix-agent2 vector
   ```

2. Di Zabbix, pastikan **Host name** sama persis dengan hostname yang dicetak skrip. Pasang template Linux dengan active checks, lalu buka **Monitoring → Latest data** untuk memastikan data masuk.
3. Kirim log uji dari server agen dan cari teks `agent-observe-test` di Grafana menggunakan datasource VictoriaLogs.

   ```bash
   logger -t agent-observe-test "agent-observe-test $(hostname) $(date -Is)"
   ```

Jika layanan aktif tetapi data belum muncul, periksa log agen dan koneksi dari host ke port tujuan. Untuk Vector, periksa juga apakah aggregator meneruskan log ke VictoriaLogs.

```bash
sudo journalctl -u zabbix-agent2 -u vector -n 100 --no-pager
```

Konfigurasi agen berada di `/etc/zabbix/zabbix_agent2.conf` dan `/etc/vector/vector.yaml`.
