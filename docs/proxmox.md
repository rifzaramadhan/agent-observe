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
```

## 2. Jalankan panduan interaktif

```bash
bash install-agents-proxmox.sh
```

Pilih **`u`** untuk mengubah langkah, atau tekan **Enter** maupun **`s`** untuk melewati. Nilai yang dilewati memakai konfigurasi tersimpan atau default. Isi endpoint, port dan pilihan lain saat diminta.

| Langkah | Pengaturan |
| --- | --- |
| 1. Zabbix Agent 2 | Server atau Proxy, port, hostname, seri paket 8.0 atau 7.0, dan passive checks |
| 2. Vector Agent | Aggregator, port Vector native, dan apakah metrik host ikut dikirim |
| 3. File log aplikasi | Preset Proxmox, Nginx, Apache, atau file khusus beserta grup akses |
| 4. Plugin Zabbix Agent 2 | Tambah, ganti, atau berhenti memuat plugin. Masukkan nama seperti `postgresql mongodb mssql` dan sesuaikan template, macro, serta akses target di Zabbix. |
| 5. TLS | Identitas dan file PSK Zabbix, serta TLS Vector dengan CA sistem atau file CA |
| 6. Konfigurasi milik deployment lain | Izin mengganti konfigurasi yang dikelola di luar Script |

Tinjau ringkasan dan ketik **`y`** untuk menerapkan, atau tekan Enter untuk membatalkan. Script memeriksa HTTPS dan memasang paket jika diperlukan. Secara default Zabbix memakai `10.7.146.72:10051` dan Vector memakai `10.7.146.73:6000`. Gunakan endpoint sesuai jaringan Anda.

Vector mengirim journal sistem dan layanan seperti `pvedaemon`, `pveproxy`, dan `corosync` bila tercatat di journal. Metrik host aktif secara default dan bisa dinonaktifkan di langkah 2. Koneksi default menggunakan plaintext. Siapkan pengaturan TLS pada Zabbix Server dan Vector Aggregator sebelum mengaktifkannya pada agen. [Daftar plugin Zabbix](https://www.zabbix.com/documentation/current/en/manual/concepts/agent2/loadable_plugins)

## 3. Aktifkan file log bila diperlukan

| Pilihan di langkah 3 | Sumber |
| --- | --- |
| `pve-access` | `/var/log/pveproxy/access.log` |
| `pve-task` | `/var/log/pve/tasks/*/UPID:*:` pada node yang menjalankan task |
| `nginx` | `/var/log/nginx/access.log` dan `/var/log/nginx/error.log` |
| `apache` | `/var/log/apache2/access.log` dan `/var/log/apache2/error.log` |
| Log khusus | Masukkan `nama=/path/absolut/*.log` ketika diminta. |

Setelah instalasi awal, beri user `vector` akses baca ke log yang akan dikumpulkan dan akses lintas ke direktori induk. Untuk pola wildcard, Vector juga perlu izin membaca daftar isi direktori yang dicocokkan. Gunakan ACL terbatas atau grup yang sudah diberi akses. Setelah rotasi atau task baru, periksa kembali akses ke file baru. Vector memulai dari awal pada file yang baru ditemukan, termasuk file lama yang cocok dengan pola saat pertama kali opsi diaktifkan.

Contoh pemberian ACL pada access log yang sudah ada, jika kebijakan node mengizinkan dan `setfacl` tersedia.

```bash
setfacl -m u:vector:rx /var/log/pveproxy
setfacl -m u:vector:r /var/log/pveproxy/access.log
runuser -u vector -- test -r /var/log/pveproxy/access.log
```

Setelah izin siap, jalankan kembali panduan dan pilih **tambah** pada langkah 3. Masukkan preset yang dibutuhkan, misalnya `pve-access pve-task`. Jika izin diberikan melalui grup tambahan, pilih **tambah** pada pertanyaan grup akses dan masukkan nama grup tersebut.

## 4. Verifikasi

```bash
systemctl is-active zabbix-agent2 vector
journalctl -u zabbix-agent2 -u vector -n 50 --no-pager
logger -t pve-vector-test "pve-vector-test $(hostname) $(date -Is)"
```

1. Cek **Monitoring → Latest data** di Zabbix setelah mengaitkan template Linux dengan active checks pada host.
2. Cari `pve-vector-test` di Grafana melalui datasource VictoriaLogs. Gunakan `platform="proxmox"` jika field tersebut dipertahankan aggregator.
3. Untuk file log, cari entri baru dari UI/API atau task yang memang dijalankan. Vector mengirim field `app_service` dengan nilai `pve_access` atau `pve_task` untuk memudahkan pencarian jika field dipertahankan aggregator.

## 5. Ubah konfigurasi setelah instalasi

Jalankan kembali `bash install-agents-proxmox.sh`. Panduan memuat pengaturan tersimpan dan memakai ulang nilai untuk setiap langkah yang dilewati. Script mencatat pengaturan di `/etc/agent-observe.args` dan menyimpan cadangan file konfigurasi yang diganti di `/var/backups/victoria-agents/`.

Jika sebelumnya memakai rsyslog dari Proxmox ke listener Rocky Linux, hentikan forwarding lama setelah alur langsung dari Vector terverifikasi. Untuk receiver Rocky Linux dengan konfigurasi listener lama, terapkan ulang installer Rocky terbaru dengan opsi deployment yang berlaku. Daftar opsi tersedia melalui `--help`.
