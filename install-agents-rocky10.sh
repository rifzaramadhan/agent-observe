#!/usr/bin/env bash
# NUCC PLNNP | Zabbix Agent 2 dan Vector Agent untuk Rocky Linux 10.
set -Eeuo pipefail
umask 077

usage() {
    cat <<'HELP'
Penggunaan:
  sudo bash install-agents-rocky10.sh [opsi]

  --hostname NAMA           Nama Host di Zabbix (default: hostname OS)
  --zabbix-server HOST      IPv4 atau DNS Zabbix Server/Proxy (default: 10.7.146.72)
  --zabbix-port PORT        Port active checks (default: 10051)
  --zabbix-series VERSI     Seri paket resmi 8.0 atau 7.0 (default: 8.0)
  --passive                 Aktifkan juga passive checks TCP 10050 dari --zabbix-server
  --psk-identity IDENTITAS  Aktifkan Zabbix TLS PSK bersama --psk-file
  --psk-file FILE           Satu baris kunci hex 32–512 karakter dengan panjang genap
  --vector-aggregator HOST  IPv4 atau DNS Vector Aggregator (default: 10.7.146.73)
  --vector-port PORT        Port Vector native (default: 6000)
  --vector-tls              Aktifkan TLS dan verifikasi sertifikat serta nama endpoint
  --vector-ca FILE          Gunakan CA PEM internal dan aktifkan TLS
  --logs-only               Kirim log journald dan log aplikasi yang dipilih, tanpa host metrics.
  --app-logs nginx|apache   Tambahkan log access/error standar. Opsi dapat diulang.
  --app-log NAMA=POLA        Tambahkan file log aplikasi dari path absolut (* dan ? didukung).
  --app-log-group GRUP      Beri layanan Vector akses melalui grup Linux yang sudah ada. Opsi dapat diulang.
  --replace-config          Izinkan mengganti konfigurasi agen milik deployment lain
  -h, --help                Tampilkan opsi

Sebelum memasang paket, skrip mengecek akses HTTPS ke repositori yang diperlukan.
Jalankan pada server yang dipantau. Gunakan endpoint yang sesuai dengan
konfigurasi server pusat. Tanpa opsi TLS/PSK, koneksi menggunakan plaintext.
Vector menggunakan nama OS yang tercatat pada journal dan host metrics.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

zabbix_server=10.7.146.72
zabbix_port=10051
zabbix_series=8.0
vector_aggregator=10.7.146.73
vector_port=6000
agent_hostname=
passive=0
metrics=1
replace=0
psk_identity=
psk_source=
vector_tls=0
ca_source=
app_services=()
app_log_paths=()
app_log_groups=()
app_name_pattern='^[a-z][a-z0-9_]{0,47}$'
app_path_pattern='^/[A-Za-z0-9_./*?@-]+$'
app_group_pattern='^[A-Za-z_][A-Za-z0-9_.-]*$'

add_app_log() {
    local name=$1 path=$2 index
    [[ $name =~ $app_name_pattern && $path =~ $app_path_pattern && $path != */ ]] ||
        die 'Gunakan --app-log nama=/path/absolut/*.log dengan nama huruf kecil, angka, atau garis bawah.'
    for ((index=0; index<${#app_services[@]}; index++)); do
        if [[ ${app_services[index]} == "$name" ]]; then
            if ! grep -Fxq -- "$path" <<< "${app_log_paths[index]}"; then
                app_log_paths[index]+=$'\n'"$path"
            fi
            return 0
        fi
    done
    app_services+=("$name")
    app_log_paths+=("$path")
}

while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --passive) passive=1; shift ;;
        --logs-only) metrics=0; shift ;;
        --replace-config) replace=1; shift ;;
        --vector-tls) vector_tls=1; shift ;;
        --hostname|--zabbix-server|--zabbix-port|--zabbix-series|--psk-identity|--psk-file|--vector-aggregator|--vector-port|--vector-ca|--app-logs|--app-log|--app-log-group)
            (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Nilai diperlukan untuk $1."
            case "$1" in
                --hostname) agent_hostname=$2 ;;
                --zabbix-server) zabbix_server=$2 ;;
                --zabbix-port) zabbix_port=$2 ;;
                --zabbix-series) zabbix_series=$2 ;;
                --psk-identity) psk_identity=$2 ;;
                --psk-file) psk_source=$2 ;;
                --vector-aggregator) vector_aggregator=$2 ;;
                --vector-port) vector_port=$2 ;;
                --vector-ca) ca_source=$2; vector_tls=1 ;;
                --app-logs)
                    case "$2" in
                        nginx)
                            add_app_log nginx /var/log/nginx/access.log
                            add_app_log nginx /var/log/nginx/error.log ;;
                        apache|httpd)
                            add_app_log apache /var/log/httpd/access_log
                            add_app_log apache /var/log/httpd/error_log ;;
                        *) die "Preset log tidak dikenal: $2. Pilih nginx atau apache." ;;
                    esac ;;
                --app-log)
                    [[ $2 == *=* ]] || die 'Gunakan --app-log nama=/path/absolut/*.log.'
                    add_app_log "${2%%=*}" "${2#*=}" ;;
                --app-log-group)
                    [[ $2 =~ $app_group_pattern ]] || die "Nama grup log tidak valid: $2."
                    app_log_groups+=("$2") ;;
            esac
            shift 2 ;;
        *) die "Opsi tidak dikenal: $1. Lihat --help." ;;
    esac
done

((EUID == 0)) || die "Jalankan skrip menggunakan sudo."
source /etc/os-release
[[ $ID == rocky && ${VERSION_ID%%.*} == 10 ]] || die "Skrip ini ditujukan untuk Rocky Linux 10."
[[ $(uname -m) == x86_64 ]] || die "Skrip ini ditujukan untuk x86_64."
[[ -d /run/systemd/system ]] || die "Systemd harus berjalan."
[[ $zabbix_series == 8.0 || $zabbix_series == 7.0 ]] || die "Pilih --zabbix-series 8.0 atau 7.0."
agent_hostname=${agent_hostname:-$(hostname)}
[[ $agent_hostname =~ ^[[:alnum:]_.-][[:alnum:]_.[:blank:]-]{0,127}$ ]] &&
    [[ $agent_hostname != *$'\t'* && $agent_hostname != *' ' ]] || die "Hostname Zabbix tidak valid."

for endpoint in "$zabbix_server" "$vector_aggregator"; do
    [[ $endpoint =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && ${#endpoint} -le 253 ]] ||
        die "Gunakan alamat IPv4 atau DNS untuk endpoint: $endpoint."
done
for port in "$zabbix_port" "$vector_port"; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || die "Port tidak valid: $port."
done
if [[ -n $psk_identity || -n $psk_source ]]; then
    [[ -n $psk_identity && -f $psk_source && -r $psk_source ]] ||
        die "--psk-identity dan --psk-file yang dapat dibaca diperlukan bersama."
    [[ $psk_identity =~ ^[A-Za-z0-9_.:@-]{1,128}$ ]] || die "Identitas PSK tidak valid."
    psk_value=$(<"$psk_source")
    [[ $psk_value =~ ^[0-9A-Fa-f]{32,512}$ ]] && ((${#psk_value} % 2 == 0)) ||
        die "File PSK harus berisi satu baris hex dengan panjang genap antara 32–512 karakter."
fi
if [[ -n $ca_source ]]; then
    [[ -f $ca_source && -r $ca_source ]] || die "File CA tidak dapat dibaca."
    openssl x509 -in "$ca_source" -noout || die "CA harus berformat PEM."
fi

vector_groups=systemd-journal
for group in "${app_log_groups[@]}"; do
    getent group "$group" >/dev/null || die "Grup log tidak ditemukan: $group."
    if [[ " $vector_groups " != *" $group "* ]]; then
        vector_groups+=" $group"
    fi
done

exec 9>/run/lock/victoria-install-agents.lock
flock -n 9 || die "Instalasi agen lain sedang berjalan."

zbx_config=/etc/zabbix/zabbix_agent2.conf
vector_config=/etc/vector/vector.yaml
vector_dropin=/etc/systemd/system/vector.service.d/50-victoria-agent.conf
psk_dest=/etc/zabbix/victoria-agent.psk
ca_dest=/etc/vector/victoria-agent-ca.pem
marker='# Managed by install-agents-rocky10.sh'
services=(zabbix-agent2.service vector.service)
declare -a changed_files=()
declare -A previous_active=() previous_enabled=() restart_needed=()
backup_dir=
changing_services=0
temp_install=
work_dir=$(mktemp -d /var/tmp/victoria-agents.XXXXXXXX)

finish() {
    local status=$? path service i
    trap - EXIT INT TERM
    set +e
    if ((status != 0 && ${#changed_files[@]} > 0)); then
        info "Terjadi kegagalan. Memulihkan konfigurasi sebelumnya."
        for ((i=${#changed_files[@]}-1; i>=0; i--)); do
            path=${changed_files[i]}
            if [[ -e $backup_dir$path ]]; then
                cp -a --remove-destination -- "$backup_dir$path" "$path" ||
                    printf 'Gagal memulihkan %s. Salinan ada di %s.\n' "$path" "$backup_dir" >&2
            else
                rm -f -- "$path"
            fi
        done
    fi
    if ((status != 0 && changing_services)); then
        systemctl daemon-reload
        for service in "${services[@]}"; do
            case "${previous_enabled[$service]}" in
                enabled) systemctl enable "$service" ;;
                enabled-runtime) systemctl disable "$service"; systemctl enable --runtime "$service" ;;
                disabled) systemctl disable "$service" ;;
            esac
            if [[ ${previous_active[$service]} == active ]]; then
                systemctl restart "$service" || printf 'Gagal menjalankan kembali %s.\n' "$service" >&2
            else
                systemctl stop "$service"
            fi
        done
    fi
    [[ -z $temp_install ]] || rm -f -- "$temp_install"
    rm -rf -- "$work_dir"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_existing_config() {
    local file=$1 package=$2
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || die "Tipe file konfigurasi tidak didukung: $file."
    [[ -e $file ]] || return 0
    ((replace)) && return 0
    grep -Fxq -- "$marker" "$file" && return 0

    # Izinkan file bawaan RPM yang belum diedit, termasuk pada percobaan ulang.
    if rpm -q "$package" &>/dev/null &&
        rpm -q --qf '[%{FILENAMES}\n]' "$package" | grep -Fx -- "$file" >/dev/null &&
        ! rpm -V --noscripts "$package" 2>/dev/null | awk -v path="$file" '$NF == path { changed=1 } END { exit !changed }'; then
        return 0
    fi
    die "Konfigurasi sudah ada di $file. Tinjau dahulu, lalu gunakan --replace-config bila ingin menggantinya."
}

check_existing_config "$zbx_config" zabbix-agent2
check_existing_config "$vector_config" vector
check_existing_config "$vector_dropin" vector

installed_series=$(rpm -q --qf '%{VERSION}' zabbix-agent2 2>/dev/null) || installed_series=
if [[ -n $installed_series && $installed_series != "$zabbix_series".* ]]; then
    die "Zabbix Agent 2 versi $installed_series sudah terpasang. Gunakan --zabbix-series yang sesuai."
fi

check_https() {
    local label=$1 url=$2
    info "Mengecek koneksi HTTPS ke $label..."
    if ! curl --proto '=https' --proto-redir '=https' \
        --fail --silent --show-error --location \
        --connect-timeout 5 --max-time 15 --output /dev/null "$url"; then
        die "Tidak dapat mengakses $label ($url). Periksa DNS, proxy, firewall, dan sertifikat TLS. Coba lagi setelah koneksi pulih."
    fi
}

install_vector=0
setup_vector_repo=0
vector_setup_url=https://setup.vector.dev
if ! rpm -q vector &>/dev/null; then
    install_vector=1
    if ! dnf -q --cacheonly repolist --enabled |
        awk '$1 == "vector" { found=1 } END { exit !found }'; then
        setup_vector_repo=1
    fi
fi

if [[ -z $installed_series ]] || ((install_vector)); then
    command -v curl >/dev/null || die "curl diperlukan untuk mengecek koneksi HTTPS sebelum instalasi."
    if [[ -z $installed_series ]]; then
        case "$zabbix_series" in
            8.0) zabbix_package_repo=https://repo.zabbix.com/zabbix/8.0/stable/rocky/10/x86_64 ;;
            7.0) zabbix_package_repo=https://repo.zabbix.com/zabbix/7.0/rocky/10/x86_64 ;;
        esac
        check_https 'repositori Zabbix' "$zabbix_package_repo/repodata/repomd.xml"
    fi
    if ((install_vector)); then
        check_https 'repositori Vector' 'https://yum.vector.dev/stable/vector-0/x86_64/repodata/repomd.xml'
        if ((setup_vector_repo)); then
            check_https 'layanan setup Vector' "$vector_setup_url"
        fi
    fi
else
    info "Kedua paket sudah terpasang. Pengecekan koneksi internet dilewati."
fi

if [[ -z $installed_series ]]; then
    info "Memasang Zabbix Agent 2 seri $zabbix_series."
    repo_version=$(rpm -q --qf '%{VERSION}' zabbix-release 2>/dev/null) || repo_version=
    if [[ -z $repo_version ]]; then
        repo_base=https://repo.zabbix.com/zabbix
        case "$zabbix_series" in
            8.0) repo_base+=/8.0/release/rocky/10/noarch ;;
            7.0) repo_base+=/7.0/rocky/10/x86_64 ;;
        esac
        dnf -y install "$repo_base/zabbix-release-latest-$zabbix_series.el10.noarch.rpm"
    elif [[ $repo_version != "$zabbix_series" && $repo_version != "$zabbix_series".* ]]; then
        die "Repositori Zabbix seri $repo_version sudah terpasang. Gunakan seri yang sesuai."
    fi
    dnf -y --disablerepo='epel*' install "zabbix-agent2-$zabbix_series.*"
fi

if ((install_vector)); then
    info "Memasang Vector dari repositori resmi."
    if ((setup_vector_repo)); then
        curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 \
            "$vector_setup_url" -o "$work_dir/setup-vector.sh"
        bash "$work_dir/setup-vector.sh"
    fi
    dnf -y install vector
fi

for service in "${services[@]}"; do
    previous_active[$service]=$(systemctl is-active "$service") || :
    previous_enabled[$service]=$(systemctl is-enabled "$service") || :
    case "${previous_enabled[$service]}" in
        enabled|disabled|enabled-runtime) ;;
        *) die "Status systemd untuk $service perlu ditinjau: ${previous_enabled[$service]}." ;;
    esac
done
getent group systemd-journal >/dev/null || die "Grup systemd-journal tidak ditemukan."
install -d -m 0750 -o vector -g vector /var/lib/vector

{
    printf '%s\nLogType=system\nHostname=%s\nServerActive=%s:%s\n' \
        "$marker" "$agent_hostname" "$zabbix_server" "$zabbix_port"
    if ((passive)); then
        printf 'Server=%s\nListenPort=10050\n' "$zabbix_server"
    fi
    if [[ -n $psk_source ]]; then
        printf 'TLSConnect=psk\nTLSAccept=psk\nTLSPSKIdentity=%s\nTLSPSKFile=%s\n' "$psk_identity" "$psk_dest"
    fi
} > "$work_dir/zabbix.conf"

{
    printf '%s\n' "$marker"
    cat <<'YAML'
data_dir: /var/lib/vector
sources:
  journald:
    type: journald
    since_now: true
    current_boot_only: false
    exclude_units:
      - vector.service
YAML
    inputs='journald'
    if ((metrics)); then
        cat <<'YAML'
  host_metrics:
    type: host_metrics
    scrape_interval_secs: 30
YAML
        inputs+=', host_metrics'
    fi
    for ((index=0; index<${#app_services[@]}; index++)); do
        name=${app_services[index]}
        printf '  app_file_%s:\n    type: file\n    read_from: beginning\n    include:\n' "$name"
        while IFS= read -r path; do
            printf '      - "%s"\n' "$path"
        done <<< "${app_log_paths[index]}"
    done
    if ((${#app_services[@]})); then
        printf 'transforms:\n'
        for name in "${app_services[@]}"; do
            printf '  app_tag_%s:\n    type: remap\n    inputs: [app_file_%s]\n    source: |\n      .app_service = "%s"\n' \
                "$name" "$name" "$name"
            inputs+=", app_tag_$name"
        done
    fi
    cat <<YAML
sinks:
  victoria_aggregator:
    type: vector
    inputs: [$inputs]
    address: "$vector_aggregator:$vector_port"
    buffer:
      type: disk
      max_size: 536870912
      when_full: block
YAML
    if ((vector_tls)); then
        printf '    tls:\n      enabled: true\n      verify_certificate: true\n      verify_hostname: true\n'
        if [[ -n $ca_source ]]; then printf '      ca_file: "%s"\n' "$ca_dest"; fi
    fi
} > "$work_dir/vector.yaml"

cat > "$work_dir/vector.conf" <<SYSTEMD
$marker
[Service]
SupplementaryGroups=$vector_groups
ExecStartPre=
ExecStartPre=/usr/bin/vector validate --skip-healthchecks $vector_config
ExecStart=
ExecStart=/usr/bin/vector --config $vector_config
ExecReload=
ExecReload=/usr/bin/vector validate --no-environment $vector_config
ExecReload=/bin/kill -HUP \$MAINPID
SYSTEMD

put_file() {
    local source=$1 target=$2 group=$3 mode=$4 service=$5
    [[ ! -L $target && ( ! -e $target || -f $target ) ]] || die "Tipe file tidak didukung: $target."
    if [[ -f $target ]] && cmp -s -- "$source" "$target" &&
        [[ $(stat -c '%U:%G:%a' -- "$target") == "root:$group:${mode#0}" ]]; then
        return 0
    fi
    if [[ -z $backup_dir ]]; then
        install -d -m 0700 /var/backups/victoria-agents
        backup_dir=$(mktemp -d /var/backups/victoria-agents/config.XXXXXXXX)
    fi
    if [[ -e $target ]]; then
        mkdir -p -- "$backup_dir$(dirname -- "$target")"
        cp -a -- "$target" "$backup_dir$target"
    fi
    mkdir -p -- "$(dirname -- "$target")"
    temp_install=$(mktemp "${target}.tmp.XXXXXXXX")
    install -m "$mode" -o root -g "$group" -- "$source" "$temp_install"
    changed_files+=("$target")
    mv -f -- "$temp_install" "$target"
    temp_install=
    if command -v restorecon >/dev/null; then restorecon "$target"; fi
    restart_needed[$service]=1
}

info "Memasang dan memvalidasi konfigurasi agen."
if [[ -n $psk_source ]]; then
    printf '%s\n' "$psk_value" > "$work_dir/zabbix.psk"
    unset psk_value
    put_file "$work_dir/zabbix.psk" "$psk_dest" zabbix 0640 "${services[0]}"
fi
if [[ -n $ca_source ]]; then
    put_file "$ca_source" "$ca_dest" vector 0640 "${services[1]}"
fi
put_file "$work_dir/zabbix.conf" "$zbx_config" zabbix 0640 "${services[0]}"
put_file "$work_dir/vector.yaml" "$vector_config" vector 0640 "${services[1]}"
put_file "$work_dir/vector.conf" "$vector_dropin" root 0644 "${services[1]}"

runuser -u zabbix -- zabbix_agent2 -T -c "$zbx_config"
runuser -u vector -- vector validate --no-environment "$vector_config"

changing_services=1
systemctl daemon-reload
for service in "${services[@]}"; do
    systemctl enable "$service"
    if [[ ${restart_needed[$service]:-0} == 1 && ${previous_active[$service]} == active ]]; then
        systemctl restart "$service"
    else
        systemctl start "$service"
    fi
done
sleep 2
for service in "${services[@]}"; do
    if ! systemctl is-active --quiet "$service"; then
        journalctl -u "$service" -n 20 --no-pager >&2 || :
        die "Layanan gagal berjalan: $service."
    fi
done

info "Kedua agen aktif. Host Zabbix: $agent_hostname"
info "Zabbix active: $zabbix_server:$zabbix_port | Vector native: $vector_aggregator:$vector_port"
if [[ -n $backup_dir ]]; then info "Cadangan konfigurasi: $backup_dir"; fi
info 'Verifikasi Latest data di Zabbix dan cari log uji berikut di VictoriaLogs/Grafana.'
info 'logger -t victoria-agent-test "victoria-agent-test $(hostname) $(date -Is)"'
