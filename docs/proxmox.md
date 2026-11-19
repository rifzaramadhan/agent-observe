# Instalasi agen observability di Proxmox VE

Jalankan [install-agents-proxmox.sh](../install-agents-proxmox.sh) sebagai root pada setiap node Proxmox VE 9 (Debian 13) atau Proxmox VE 8 (Debian 12), arsitektur x86_64. Jalur data menggunakan Vector pada node Proxmox → Vector Aggregator → VictoriaLogs. Zabbix Agent 2 pada node mengirim active checks ke Zabbix Server atau Proxy.

## 1. Siapkan koneksi dan paket dasar

- Pastikan repositori APT Debian dan Proxmox pada node dapat diakses. Jika `apt-get update` gagal dengan HTTP 401 dari repositori enterprise, sesuaikan konfigurasi repositori dengan langganan dan kebijakan Proxmox yang berlaku sebelum melanjutkan.
- Izinkan koneksi keluar TCP ke Zabbix Server atau Proxy (default `10051`) dan Vector Aggregator (default `6000`). Untuk instalasi pertama, siapkan `curl` dan akses HTTPS ke repositori vendor.
- Pilih hostname di Zabbix yang sama dengan hostname node atau tentukan `--hostname` secara eksplisit.

Jalankan dari shell root pada node.

```bash
pveversion
apt-get update
apt-get install -y curl ca-certificates git
git clone https://github.com/rifzaramadhan/agent-observe.git
cd agent-observe
bash install-agents-proxmox.sh --help
```

## 2. Instal dan konfigurasi agen

Ganti kedua hostname contoh dengan endpoint Anda. Nilai default proyek mengikuti installer Rocky Linux (`10.7.146.72:10051` dan `10.7.146.73:6000`).

```bash
bash install-agents-proxmox.sh \
  --zabbix-server zabbix.example.com \
  --vector-aggregator vector.example.com
```

Skrip memeriksa koneksi HTTPS sebelum menyiapkan paket yang belum tersedia. APT memasang Zabbix Agent 2 seri `8.0` secara default dan Vector dari repositori resmi masing-masing. Gunakan `--zabbix-series 7.0` jika deployment menggunakan seri tersebut. Saat kedua paket sudah terpasang, skrip melanjutkan konfigurasi tanpa pengecekan internet.

Secara default Vector mengirim journal sistem dan layanan Proxmox, termasuk pesan daemon seperti `pvedaemon`, `pveproxy`, dan `corosync` yang tercatat di journal. Vector juga mengirim metrik host. Gunakan `--logs-only` untuk menonaktifkan metrik host, misalnya jika sudah dikumpulkan oleh exporter lain.

Gunakan `--passive` jika diperlukan untuk item passive checks melalui TCP `10050`. Koneksi agen secara default menggunakan plaintext. Gunakan `--psk-identity` bersama `--psk-file` untuk TLS PSK Zabbix. Gunakan `--vector-tls` untuk CA yang sudah dipercaya sistem atau `--vector-ca /path/ke/ca.pem` untuk CA internal. Siapkan konfigurasi TLS yang sesuai pada Zabbix dan aggregator sebelum mengaktifkannya pada agen.

## 3. Aktifkan file log bila diperlukan

| Opsi | Sumber |
| --- | --- |
| `--pve-access-logs` | `/var/log/pveproxy/access.log` |
| `--pve-task-logs` | `/var/log/pve/tasks/*/UPID:*:` untuk output task pada node yang menjalankannya |
| `--app-logs nginx` | `/var/log/nginx/access.log` dan `/var/log/nginx/error.log` |
| `--app-logs apache` | `/var/log/apache2/access.log` dan `/var/log/apache2/error.log` |
| `--app-log 'nama=/path/absolut/*.log'` | File atau pola log aplikasi sendiri |

Setelah instalasi awal, beri user `vector` akses baca ke log yang akan dikumpulkan dan akses lintas ke direktori induk. Untuk pola wildcard, Vector juga perlu izin membaca daftar isi direktori yang dicocokkan. Gunakan ACL terbatas atau grup yang sudah diberi akses. Setelah rotasi atau task baru, periksa kembali akses ke file baru. Vector memulai dari awal pada file yang baru ditemukan, termasuk file lama yang cocok dengan pola saat pertama kali opsi diaktifkan.

Contoh pemberian ACL pada access log yang sudah ada, jika kebijakan node mengizinkan dan `setfacl` tersedia.

```bash
setfacl -m u:vector:rx /var/log/pveproxy
setfacl -m u:vector:r /var/log/pveproxy/access.log
runuser -u vector -- test -r /var/log/pveproxy/access.log
```

Setelah izin siap, aktifkan file yang dibutuhkan. Jika izin diberikan melalui grup tambahan yang sudah ada, sertakan `--app-log-group NAMA_GRUP`.

```bash
bash install-agents-proxmox.sh --configure-only \
  --pve-access-logs --pve-task-logs
```

## 4. Verifikasi

```bash
systemctl is-active zabbix-agent2 vector
journalctl -u zabbix-agent2 -u vector -n 50 --no-pager
logger -t pve-vector-test "pve-vector-test $(hostname) $(date -Is)"
```

1. Cek **Monitoring → Latest data** di Zabbix setelah mengaitkan template Linux dengan active checks pada host.
2. Cari `pve-vector-test` di Grafana melalui datasource VictoriaLogs. Gunakan `platform="proxmox"` jika field tersebut dipertahankan aggregator.
3. Untuk file log, cari entri baru dari UI/API atau task yang memang dijalankan. Vector mengirim field `app_service` dengan nilai `pve_access` atau `pve_task` untuk memudahkan pencarian jika field dipertahankan aggregator.

## Plugin Zabbix Agent 2

Tambahkan `--zabbix-plugin NAMA` saat instalasi awal. Opsi dapat diulang untuk memasang beberapa plugin, misalnya `postgresql`, `mongodb`, atau `mssql`. Paket harus tersedia untuk seri Zabbix dan platform yang digunakan.

```bash
bash install-agents-proxmox.sh \
  --zabbix-plugin postgresql \
  --zabbix-plugin mongodb
```

Untuk host yang sudah dikelola skrip, gunakan `--install-plugins` sebagai opsi pertama. Skrip menggunakan pengaturan tersimpan dan hanya mengunduh paket plugin yang belum tersedia.

```bash
bash install-agents-proxmox.sh --install-plugins --zabbix-plugin mssql
```

Skrip menambahkan `Include` untuk file konfigurasi dari paket yang dipilih dan memvalidasi Agent 2 sebelum menerapkan perubahan layanan. Untuk memuat paket plugin yang sudah terpasang tanpa internet, gunakan `--configure-only --zabbix-plugin NAMA`. Dengan `--configure-only --clear-zabbix-plugins`, Agent 2 berhenti memuat plugin yang dipilih sebelumnya dan paketnya tetap terpasang. Tambahkan opsi `--zabbix-plugin` setelah opsi tersebut jika ingin mengganti daftar pilihan.

Sesuaikan template Zabbix, macro, dan akses database untuk plugin yang digunakan. Periksa status Agent 2 dan log journal setelah instalasi.

```bash
systemctl is-active zabbix-agent2
journalctl -u zabbix-agent2 -n 50 --no-pager
```

[Daftar dan persyaratan plugin resmi Zabbix](https://www.zabbix.com/documentation/current/en/manual/concepts/agent2/loadable_plugins)

## 5. Ubah konfigurasi setelah instalasi

Jadikan `--configure-only` opsi pertama dan cantumkan hanya perubahan yang diperlukan. Mode ini membutuhkan kedua paket sudah terpasang, mempertahankan pengaturan tersimpan, serta memvalidasi konfigurasi sebelum restart layanan yang berubah. Skrip mencatat pengaturan di `/etc/agent-observe.args` dan menyimpan cadangan konfigurasi yang diganti di `/var/backups/victoria-agents/`.

```bash
bash install-agents-proxmox.sh --configure-only \
  --vector-aggregator vector-baru.example.com
```

Untuk mengganti daftar sumber file, gunakan `--clear-app-logs` lalu sebutkan lagi semua sumber file yang ingin dipertahankan. Log journal tetap dikumpulkan.

Jika sebelumnya memakai forwarding rsyslog dari Proxmox ke listener Rocky Linux, nonaktifkan rule forwarding lama setelah alur langsung dari Vector pada node sudah terverifikasi. Pada receiver Rocky Linux yang pernah mengaktifkan listener itu, terapkan ulang versi terbaru installer Rocky dengan **seluruh opsi Rocky yang berlaku** melalui mode instalasi biasa untuk mengganti pengaturan lama.
