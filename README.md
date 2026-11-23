# Agent Observe

Instalasi Zabbix Agent 2 dan Vector Agent untuk **Rocky Linux 10 x86_64**. Script memasang paket RPM yang belum tersedia, menyiapkan konfigurasi, memvalidasinya, lalu mengaktifkan layanan melalui systemd.

Untuk node **Proxmox VE**, gunakan [installer Proxmox VE](./install-agents-proxmox.sh) dan [panduan langkah demi langkah](./docs/proxmox.md). Vector pada node Proxmox mengirim log langsung ke aggregator.

## Prasyarat

- Jalankan di server Rocky Linux 10 x86_64 yang akan dipantau. Siapkan akses `sudo` atau root dan pastikan systemd berjalan.
- Untuk instalasi paket, server memerlukan `curl` dan akses HTTPS ke repositori paket. Jika kedua paket sudah terpasang, Script melewati pengecekan internet dan langsung melanjutkan konfigurasi.
- Pastikan Zabbix Server atau Proxy menerima **active checks** dan Vector Aggregator memiliki listener **Vector native** yang bisa dijangkau dari server agen.

## Instalasi dan konfigurasi interaktif

Jalankan di server Rocky Linux yang akan dipantau. Jika Anda sudah mengunduh Script, buka direktori unduhan lalu jalankan perintah `sudo bash` di bawah.

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
| 6. Konfigurasi milik deployment lain | Izin mengganti konfigurasi yang dikelola di luar Script |

Tinjau ringkasan lalu ketik **`y`** untuk menerapkan. Tekan Enter pada ringkasan untuk membatalkan. Script mengecek HTTPS ke repositori jika ada paket yang perlu dipasang. Bila semua paket sudah tersedia, konfigurasi dapat diterapkan tanpa internet.

| Komponen | Pengaturan default |
| --- | --- |
| Zabbix Agent 2 | Seri `8.0`, active checks ke `10.7.146.72:10051`, menggunakan hostname OS |
| Vector Agent | Journal dan metrik host ke `10.7.146.73:6000` dengan protokol Vector native dan buffer disk 512 MiB |

Koneksi default menggunakan plaintext. Untuk TLS, atur identitas dan kunci PSK yang sama di Zabbix, serta siapkan sertifikat di Vector Aggregator. Gunakan nama aggregator yang sesuai dengan sertifikat.

## Ubah konfigurasi setelah instalasi

Jalankan kembali Script dengan cara yang sama. Pengaturan dari deployment sebelumnya dimuat dari `/etc/agent-observe.args`. Ubah langkah yang diperlukan lalu lewati langkah lainnya. Jika instalasi lama belum memiliki pengaturan tersimpan, isi pengaturan deployment yang berlaku saat pertama kali menjalankan panduan.

Untuk integrasi otomasi, opsi CLI masih tersedia melalui `bash install-agents-rocky10.sh --help`.

## Firewall passive checks

Saat passive checks aktif, installer Rocky Linux menambahkan rich rule firewalld untuk TCP **10050** hanya dari IP Zabbix Server atau Proxy yang dikonfigurasi. Aturan ditulis ke runtime dan permanen tanpa reload. Installer memilih zona dari interface rute ke server. Untuk host dengan routing asimetris atau zona berbasis alamat sumber, tentukan zona yang menerima koneksi pada langkah 1 atau gunakan `--firewall-zone public` dengan nama zona yang sesuai.

Firewalld harus sudah berjalan untuk menerapkan aturan. Jika firewall host dikelola dengan alat lain, izinkan TCP 10050 dari IP Zabbix Server atau Proxy di alat tersebut. Bila alamat server disetel sebagai nama DNS, jalankan ulang installer setelah alamat DNS berubah. Anda dapat memeriksa aturan efektif dengan `firewall-cmd --zone=public --list-rich-rules` setelah mengganti `public` jika zonanya berbeda.

Saat passive checks dinonaktifkan atau IP tujuan berubah, installer menghapus aturan lama yang dibuatnya. Aturan administrator yang sudah ada di luar installer tetap mengikuti konfigurasi firewalld yang berlaku.

## Plugin Zabbix Agent 2

Pada langkah 4, pilih **tambah** lalu masukkan nama seperti `postgresql mongodb`. Paket harus tersedia untuk seri dan platform yang digunakan. Script menambahkan file konfigurasi paket ke `Include`. Pilihan **berhenti memuat** mengeluarkan plugin dari konfigurasi Agent 2 dan paketnya tetap terpasang. Sesuaikan template Zabbix, macro, dan akses database untuk plugin yang dipilih. [Daftar plugin Zabbix](https://www.zabbix.com/documentation/current/en/manual/concepts/agent2/loadable_plugins)

## Log aplikasi

Vector membaca journal secara default. Pilih preset di langkah 3 untuk file log yang ditulis aplikasi secara langsung.

| Preset | File |
| --- | --- |
| `nginx` | `/var/log/nginx/access.log`, `/var/log/nginx/error.log` |
| `apache` | `/var/log/httpd/access_log`, `/var/log/httpd/error_log` |
| Log khusus | Masukkan `my_app=/var/log/my-app/*.log` ketika diminta. Ulangi untuk menambah file lain. |

Vector perlu izin baca file dan akses lintas direktori. Berikan juga izin membaca daftar isi direktori jika memakai wildcard. Siapkan ACL untuk user `vector` atau tambahkan grup yang sudah diberi akses pada langkah 3. Periksa izin file baru setelah rotasi. Vector membaca file yang baru ditemukan dari awal dan melanjutkan file yang telah memiliki checkpoint dari posisi terakhir.

## Preset Docker

Pada host Rocky Linux yang menjalankan Docker Engine, pilih **ubah** di langkah 3 dan aktifkan **Preset Docker (metrik dan log)**. Dari CLI, gunakan `--configure-only --docker-monitoring` pada host yang pengaturannya sudah tersimpan, atau `--docker-monitoring` bersama opsi deployment awal.

| Komponen | Data |
| --- | --- |
| Zabbix Agent 2 | Plugin Docker bawaan membaca Docker Engine API lokal. Zabbix dapat menampilkan status engine, discovery container, CPU, memori, dan metrik lainnya. |
| Vector | Source `docker_logs` membaca stdout/stderr container melalui Docker Engine API, lalu meneruskan log dan metadata container ke Vector Aggregator. |

Preset memerlukan Docker Engine yang sudah berjalan dengan socket lokal `/var/run/docker.sock` milik grup `docker`. Script menguji akses API dari akun kedua layanan sebelum mengubah konfigurasi. Saat preset aktif, systemd memberi grup `docker` kepada proses Agent 2 dan Vector. Akses socket tersebut setara dengan akses root pada host Docker. [Dokumentasi izin Docker](https://docs.docker.com/engine/install/linux-postinstall/)

1. **Zabbix** · Hubungkan template **Docker by Zabbix agent 2** ke host yang dipantau dan pastikan passive checks bisa dijangkau oleh Zabbix Server atau Proxy. Di **Latest data**, nilai `docker.ping` yang sehat adalah `1`. [Integrasi Docker Zabbix](https://www.zabbix.com/integrations/docker)
2. **Vector** · Cari log yang baru dihasilkan container di VictoriaLogs. Filter dengan `container_name` jika aggregator mempertahankan field itu. Pastikan logging driver container mendukung pembacaan lewat `docker logs`. [Source Docker Logs Vector](https://vector.dev/docs/reference/configuration/sources/docker_logs/)

Untuk mematikan preset, pilih **nonaktifkan** pada langkah 3 atau gunakan `--configure-only --no-docker-monitoring`. Saat diterapkan, Script menonaktifkan source `docker_logs` dan mencabut grup Docker yang ditambahkan oleh preset dari konfigurasi kedua layanan.

## Verifikasi

1. Periksa status layanan dari server agen.

   ```bash
   sudo systemctl is-active zabbix-agent2 vector
   ```

2. Di Zabbix, pastikan **Host name** sama persis dengan hostname yang dicetak Script. Pasang template Linux dengan active checks, lalu buka **Monitoring → Latest data** untuk memastikan data masuk.
3. Kirim log uji dari server agen dan cari teks `agent-observe-test` di Grafana menggunakan datasource VictoriaLogs.

   ```bash
   logger -t agent-observe-test "agent-observe-test $(hostname) $(date -Is)"
   ```

Jika layanan aktif tetapi data belum muncul, periksa log agen dan koneksi dari host ke port tujuan. Untuk Vector, periksa juga apakah aggregator meneruskan log ke VictoriaLogs.

```bash
sudo journalctl -u zabbix-agent2 -u vector -n 100 --no-pager
```

Konfigurasi agen berada di `/etc/zabbix/zabbix_agent2.conf` dan `/etc/vector/vector.yaml`.
