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

Saat menjalankan ulang skrip, sertakan kembali semua opsi konfigurasi yang ingin dipakai, termasuk opsi TLS, endpoint, sumber log, dan grup jika sebelumnya digunakan. Untuk menguji, buat permintaan HTTP ke Nginx atau Apache lalu cari baris access log yang baru di Grafana dengan datasource VictoriaLogs. Gunakan field `app_service` jika aggregator meneruskan field tersebut ke VictoriaLogs.

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
