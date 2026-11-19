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

**Tentukan hostname Zabbix dan endpoint sendiri.** Ganti nama contoh dengan nilai di lingkungan Anda. Gunakan `--logs-only` jika hanya perlu mengirim log `journald`.

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
