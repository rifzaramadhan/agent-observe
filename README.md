# Agent Observe

Instalasi Zabbix Agent 2 dan Vector Agent untuk **Rocky Linux 10 x86_64**. Skrip memasang paket RPM yang belum tersedia, menyiapkan konfigurasi, memvalidasinya, lalu mengaktifkan layanan melalui systemd.

Untuk node **Proxmox VE**, gunakan [installer Proxmox VE](./install-agents-proxmox.sh) dan [panduan langkah demi langkah](./docs/proxmox.md). Vector pada node Proxmox mengirim log langsung ke aggregator.

## Prasyarat

- Jalankan di server Rocky Linux 10 x86_64 yang akan dipantau. Siapkan akses `sudo` atau root dan pastikan systemd berjalan.
- Untuk instalasi paket, server memerlukan `curl` dan akses HTTPS ke repositori paket. Jika kedua paket sudah terpasang, skrip melewati pengecekan internet dan langsung melanjutkan konfigurasi.
- Pastikan Zabbix Server atau Proxy menerima **active checks** dan Vector Aggregator memiliki listener **Vector native** yang bisa dijangkau dari server agen.

## Instalasi dan konfigurasi interaktif

Jalankan di server Rocky Linux yang akan dipantau. Jika Anda sudah mengunduh skrip, buka direktori unduhan lalu jalankan perintah `sudo bash` di bawah.

```bash
git clone https://github.com/rifzaramadhan/agent-observe.git
cd agent-observe
sudo bash install-agents-rocky10.sh
```

Di setiap langkah, pilih **`u`** untuk mengubah, atau tekan **Enter** maupun **`s`** untuk melewati. Langkah yang dilewati memakai pengaturan tersimpan atau default. Saat memasukkan nilai, tekan Enter untuk memakai nilai yang ditampilkan.

| Langkah | Pengaturan |
| --- | --- |
| 1. Zabbix Agent 2 | Server atau Proxy, port active checks, nama host, seri paket 8.0 atau 7.0, dan passive checks |
| 2. Vector Agent | Aggregator, port Vector native, dan pengiriman metrik host |
| 3. File log aplikasi | Preset Nginx atau Apache, path khusus, dan grup akses |
| 4. Plugin Zabbix Agent 2 | Tambah, ganti, atau berhenti memuat plugin |
| 5. TLS | Identitas dan file PSK Zabbix, serta TLS Vector dengan CA sistem atau file CA |
| 6. Konfigurasi milik deployment lain | Izin mengganti konfigurasi yang dikelola di luar skrip |

Tinjau ringkasan lalu ketik **`y`** untuk menerapkan. Tekan Enter pada ringkasan untuk membatalkan. Skrip mengecek HTTPS ke repositori jika ada paket yang perlu dipasang. Bila semua paket sudah tersedia, konfigurasi dapat diterapkan tanpa internet.

| Komponen | Pengaturan default |
| --- | --- |
| Zabbix Agent 2 | Seri `8.0`, active checks ke `10.7.146.72:10051`, menggunakan hostname OS |
| Vector Agent | Journal dan metrik host ke `10.7.146.73:6000` dengan protokol Vector native dan buffer disk 512 MiB |

Koneksi default menggunakan plaintext. Untuk TLS, atur identitas dan kunci PSK yang sama di Zabbix, serta siapkan sertifikat di Vector Aggregator. Gunakan nama aggregator yang sesuai dengan sertifikat.

## Ubah konfigurasi setelah instalasi

Jalankan kembali skrip dengan cara yang sama. Pengaturan dari deployment sebelumnya dimuat dari `/etc/agent-observe.args`. Ubah langkah yang diperlukan lalu lewati langkah lainnya. Jika instalasi lama belum memiliki pengaturan tersimpan, isi pengaturan deployment yang berlaku saat pertama kali menjalankan panduan.

Untuk integrasi otomasi, opsi CLI masih tersedia melalui `bash install-agents-rocky10.sh --help`.

## Plugin Zabbix Agent 2

Pada langkah 4, pilih **tambah** lalu masukkan nama seperti `postgresql mongodb`. Paket harus tersedia untuk seri dan platform yang digunakan. Skrip menambahkan file konfigurasi paket ke `Include`. Pilihan **berhenti memuat** mengeluarkan plugin dari konfigurasi Agent 2 dan paketnya tetap terpasang. Sesuaikan template Zabbix, macro, dan akses database untuk plugin yang dipilih. [Daftar plugin Zabbix](https://www.zabbix.com/documentation/current/en/manual/concepts/agent2/loadable_plugins)

## Log aplikasi

Vector membaca journal secara default. Pilih preset di langkah 3 untuk file log yang ditulis aplikasi secara langsung.

| Preset | File |
| --- | --- |
| `nginx` | `/var/log/nginx/access.log`, `/var/log/nginx/error.log` |
| `apache` | `/var/log/httpd/access_log`, `/var/log/httpd/error_log` |
| Log khusus | Masukkan `my_app=/var/log/my-app/*.log` ketika diminta. Ulangi untuk menambah file lain. |

Vector perlu izin baca file dan akses lintas direktori. Berikan juga izin membaca daftar isi direktori jika memakai wildcard. Siapkan ACL untuk user `vector` atau tambahkan grup yang sudah diberi akses pada langkah 3. Periksa izin file baru setelah rotasi. Vector membaca file yang baru ditemukan dari awal dan melanjutkan file yang telah memiliki checkpoint dari posisi terakhir.

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
