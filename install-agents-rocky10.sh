#!/usr/bin/env bash
# NUCC PLNNP | Zabbix Agent 2 dan Vector Agent untuk Rocky Linux 10.
set -Eeuo pipefail
umask 077

usage() {
    cat <<'HELP'
Penggunaan:
  sudo bash install-agents-rocky10.sh [opsi]
  sudo bash install-agents-rocky10.sh --configure-only [opsi perubahan]
  sudo bash install-agents-rocky10.sh --install-plugins --zabbix-plugin NAMA

  --interactive             Buka panduan langkah demi langkah. Default jika tanpa argumen.
  --hostname NAMA           Nama Host di Zabbix (default: hostname OS)
  --zabbix-server HOST      IPv4 atau DNS Zabbix Server/Proxy (default: 10.7.146.72)
  --zabbix-port PORT        Port active checks (default: 10051)
  --zabbix-series VERSI     Seri paket resmi 8.0 atau 7.0 (default: 8.0)
  --zabbix-plugin NAMA      Pasang dan muat plugin Agent 2 (contoh: postgresql, mongodb, mssql). Dapat diulang.
  --install-plugins         Tambah plugin setelah instalasi dengan pengaturan tersimpan. Letakkan pertama.
  --clear-zabbix-plugins    Berhenti memuat plugin pilihan sebelumnya. Paket tetap terpasang.
  --passive                 Aktifkan juga passive checks TCP 10050 dari --zabbix-server
  --psk-identity IDENTITAS  Aktifkan Zabbix TLS PSK bersama --psk-file
  --psk-file FILE           Satu baris kunci hex 32–512 karakter dengan panjang genap
  --vector-aggregator HOST  IPv4 atau DNS Vector Aggregator (default: 10.7.146.73)
  --vector-port PORT        Port Vector native (default: 6000)
  --vector-tls              Aktifkan TLS dan verifikasi sertifikat serta nama endpoint
  --vector-ca FILE          Gunakan CA PEM internal dan aktifkan TLS
  --logs-only               Kirim log journald dan log aplikasi yang dipilih, tanpa host metrics.
  --docker-monitoring       Aktifkan preset metrik dan log Docker. Layanan diberi akses socket Docker.
  --no-docker-monitoring    Nonaktifkan preset Docker.
  --app-logs nginx|apache   Tambahkan log access/error standar. Opsi dapat diulang.
  --app-log NAMA=POLA        Tambahkan file log aplikasi dari path absolut (* dan ? didukung).
  --app-log-group GRUP      Beri layanan Vector akses melalui grup Linux yang sudah ada. Opsi dapat diulang.
  --configure-only          Pakai pengaturan tersimpan tanpa instalasi paket. Letakkan sebagai opsi pertama.
  --active-only             Matikan passive checks Zabbix.
  --zabbix-no-psk           Nonaktifkan TLS PSK Zabbix.
  --vector-no-tls           Nonaktifkan TLS Vector dan hapus referensi CA dari konfigurasi.
  --host-metrics            Aktifkan kembali pengiriman metrik host.
  --clear-app-logs           Kosongkan sumber file log aplikasi sebelum menambah daftar baru.
  --clear-app-log-groups     Kosongkan daftar grup tambahan untuk akses file log.
  --replace-config          Izinkan mengganti konfigurasi agen milik deployment lain
  -h, --help                Tampilkan opsi

Sebelum memasang paket, Script mengecek akses HTTPS ke repositori yang diperlukan.
Jalankan pada server yang dipantau. Gunakan endpoint yang sesuai dengan
konfigurasi server pusat. Tanpa opsi TLS/PSK, koneksi menggunakan plaintext.
Vector menggunakan nama OS yang tercatat pada journal dan host metrics.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

configure_only=0
install_plugins_only=0
interactive=0
installer_platform=rocky
if (($# == 0)); then interactive=1; fi
case "${1:-}" in
    --interactive)
        interactive=1; shift
        (($# == 0)) || die 'Gunakan --interactive tanpa opsi tambahan.' ;;
    --configure-only) configure_only=1; shift ;;
    --install-plugins) install_plugins_only=1; shift ;;
esac
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
if ((interactive)); then
    [[ -t 0 && -t 1 ]] || die 'Mode interaktif memerlukan terminal. Gunakan opsi CLI eksplisit untuk otomasi.'
fi

((EUID == 0)) || die "Jalankan Script menggunakan sudo."
source /etc/os-release
[[ $ID == rocky && ${VERSION_ID%%.*} == 10 ]] || die "Script ini ditujukan untuk Rocky Linux 10."
[[ $(uname -m) == x86_64 ]] || die "Script ini ditujukan untuk x86_64."
[[ -d /run/systemd/system ]] || die "Systemd harus berjalan."

exec 9>/run/lock/victoria-install-agents.lock
flock -n 9 || die "Instalasi agen lain sedang berjalan."

state_file=/etc/agent-observe.args
state_header='# agent-observe settings v1'
if [[ -e $state_file || -L $state_file ]]; then
    [[ -f $state_file && ! -L $state_file && $(stat -c '%u:%g:%a' -- "$state_file") == 0:0:600 ]] ||
        die "File pengaturan harus milik root:root dengan mode 0600: $state_file."
    mapfile -t saved_args < "$state_file"
    [[ ${saved_args[0]:-} == "$state_header" && ${#saved_args[@]} -gt 1 ]] ||
        die "Format pengaturan tidak dikenali: $state_file."
elif ((configure_only || install_plugins_only)); then
    die "Pengaturan belum tersimpan. Jalankan versi Script ini sekali dengan semua opsi deployment yang berlaku."
fi
if ((configure_only || install_plugins_only || interactive)) && [[ -f $state_file ]]; then
    set -- "${saved_args[@]:1}" "$@"
fi

zabbix_server=10.7.146.72
zabbix_port=10051
zabbix_series=8.0
zabbix_plugins=()
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
docker_monitoring=0
docker_socket=/var/run/docker.sock
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

parse_args() {
    while (($#)); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --passive) passive=1; shift ;;
            --clear-zabbix-plugins) zabbix_plugins=(); shift ;;
            --logs-only) metrics=0; shift ;;
            --replace-config) replace=1; shift ;;
            --vector-tls) vector_tls=1; shift ;;
            --active-only) passive=0; shift ;;
            --zabbix-no-psk) psk_identity=; psk_source=; shift ;;
            --vector-no-tls) vector_tls=0; ca_source=; shift ;;
            --host-metrics) metrics=1; shift ;;
            --docker-monitoring) docker_monitoring=1; shift ;;
            --no-docker-monitoring) docker_monitoring=0; shift ;;
            --clear-app-logs) app_services=(); app_log_paths=(); shift ;;
            --clear-app-log-groups) app_log_groups=(); shift ;;
            --hostname|--zabbix-server|--zabbix-port|--zabbix-series|--zabbix-plugin|--psk-identity|--psk-file|--vector-aggregator|--vector-port|--vector-ca|--app-logs|--app-log|--app-log-group)
                (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Nilai diperlukan untuk $1."
                case "$1" in
                    --hostname) agent_hostname=$2 ;;
                    --zabbix-server) zabbix_server=$2 ;;
                    --zabbix-port) zabbix_port=$2 ;;
                    --zabbix-series) zabbix_series=$2 ;;
                    --zabbix-plugin)
                        [[ $2 =~ ^[a-z][a-z0-9-]{0,39}$ ]] ||
                            die "Nama plugin Zabbix tidak valid: $2."
                        if [[ " ${zabbix_plugins[*]} " != *" $2 "* ]]; then zabbix_plugins+=("$2"); fi ;;
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
}

wizard_read() {
    printf '%s' "$1"
    IFS= read -r wizard_reply || die "Input berakhir. Konfigurasi belum diterapkan."
}

wizard_choice() {
    local prompt=$1 pattern=$2
    while :; do
        wizard_read "$prompt"
        [[ $wizard_reply =~ $pattern ]] && return 0
        info "Pilihan tidak valid. Coba lagi."
    done
}

wizard_value() {
    local label=$1 current=$2 flag=$3
    wizard_read "$label [$current, Enter untuk lewati]: "
    if [[ -n $wizard_reply ]]; then wizard_args+=("$flag" "$wizard_reply"); fi
}

wizard_toggle() {
    local label=$1 current=$2 enable=$3 disable=$4
    wizard_choice "$label [$current]: [y] aktifkan, [n] nonaktifkan, [Enter] lewati: " '^(y|n|s|skip)?$'
    case "$wizard_reply" in
        y) wizard_args+=("$enable") ;;
        n) wizard_args+=("$disable") ;;
    esac
}

wizard_step() {
    printf '\n%s\n' "$1"
    wizard_choice '[u] ubah, [s] skip, [Enter] skip: ' '^(u|s|skip)?$'
    [[ $wizard_reply == u ]]
}

wizard_collect() {
    local preset presets plugin
    local -a choices
    wizard_args=()
    info "Agent Observe | Panduan instalasi dan konfigurasi"
    info "Lewati langkah opsional untuk memakai nilai tersimpan atau default."
    info "Script menerapkan perubahan hanya setelah Anda mengonfirmasi ringkasan."

    if wizard_step '1/6 Zabbix Agent 2'; then
        wizard_value 'Zabbix Server atau Proxy' "$zabbix_server" --zabbix-server
        wizard_value 'Port active checks' "$zabbix_port" --zabbix-port
        wizard_value 'Nama host Zabbix' "${agent_hostname:-$(hostname)}" --hostname
        wizard_value 'Seri Agent 2 (8.0 atau 7.0)' "$zabbix_series" --zabbix-series
        wizard_toggle 'Passive checks' "$([[ $passive == 1 ]] && printf aktif || printf nonaktif)" --passive --active-only
    fi

    if wizard_step '2/6 Vector Agent dan metrik host'; then
        wizard_value 'Alamat Vector Aggregator' "$vector_aggregator" --vector-aggregator
        wizard_value 'Port Vector native' "$vector_port" --vector-port
        wizard_toggle 'Metrik host' "$([[ $metrics == 1 ]] && printf aktif || printf nonaktif)" --host-metrics --logs-only
    fi

    if wizard_step '3/6 File log aplikasi dan preset Docker'; then
        info "Preset Docker memberi Agent 2 dan Vector akses ke socket Docker. Akses ini setara dengan hak root."
        wizard_toggle 'Preset Docker (metrik dan log)' "$([[ $docker_monitoring == 1 ]] && printf aktif || printf nonaktif)" \
            --docker-monitoring --no-docker-monitoring
        wizard_choice 'File log: [t] tambah, [g] ganti, [h] hapus dari koleksi, [Enter] lewati: ' '^(t|g|h|s|skip)?$'
        case "$wizard_reply" in
            g|h) wizard_args+=(--clear-app-logs) ;;
        esac
        if [[ $wizard_reply == t || $wizard_reply == g ]]; then
            presets='nginx apache'
            if [[ $installer_platform == proxmox ]]; then presets+=' pve-access pve-task'; fi
            wizard_read "Preset ($presets), pisahkan dengan spasi, atau Enter: "
            choices=()
            IFS=' ' read -r -a choices <<< "$wizard_reply"
            for preset in "${choices[@]}"; do
                case "$preset" in
                    pve-access|pve-task)
                        [[ $installer_platform == proxmox ]] || die "Preset $preset tersedia pada installer Proxmox."
                        wizard_args+=("--$preset-logs") ;;
                    *) wizard_args+=(--app-logs "$preset") ;;
                esac
            done
            while :; do
                wizard_read 'Log khusus nama=/path/absolut/*.log (Enter jika selesai): '
                [[ -n $wizard_reply ]] || break
                wizard_args+=(--app-log "$wizard_reply")
            done
        fi
        wizard_choice 'Grup akses log: [t] tambah, [g] ganti, [h] kosongkan, [Enter] lewati: ' '^(t|g|h|s|skip)?$'
        case "$wizard_reply" in
            g|h) wizard_args+=(--clear-app-log-groups) ;;
        esac
        if [[ $wizard_reply == t || $wizard_reply == g ]]; then
            wizard_read 'Grup yang sudah ada (pisahkan dengan spasi, Enter jika selesai): '
            choices=()
            IFS=' ' read -r -a choices <<< "$wizard_reply"
            for preset in "${choices[@]}"; do wizard_args+=(--app-log-group "$preset"); done
        fi
    fi

    if wizard_step '4/6 Plugin Zabbix Agent 2'; then
        wizard_choice 'Plugin: [t] tambah, [g] ganti, [h] berhenti memuat, [Enter] lewati: ' '^(t|g|h|s|skip)?$'
        case "$wizard_reply" in
            g|h) wizard_args+=(--clear-zabbix-plugins) ;;
        esac
        if [[ $wizard_reply == t || $wizard_reply == g ]]; then
            wizard_read 'Nama plugin, mis. postgresql mongodb mssql (pisahkan dengan spasi): '
            choices=()
            IFS=' ' read -r -a choices <<< "$wizard_reply"
            for plugin in "${choices[@]}"; do wizard_args+=(--zabbix-plugin "$plugin"); done
        fi
    fi

    if wizard_step '5/6 TLS'; then
        wizard_choice 'Zabbix: [p] setel PSK, [n] nonaktifkan PSK, [Enter] lewati: ' '^(p|n|s|skip)?$'
        case "$wizard_reply" in
            p)
                wizard_value 'Identitas PSK' "${psk_identity:-belum diatur}" --psk-identity
                wizard_value 'Path file PSK' "${psk_source:-belum diatur}" --psk-file ;;
            n) wizard_args+=(--zabbix-no-psk) ;;
        esac
        wizard_choice 'Vector: [t] TLS dengan CA sistem, [c] TLS dengan file CA, [n] nonaktifkan TLS, [Enter] lewati: ' '^(t|c|n|s|skip)?$'
        case "$wizard_reply" in
            t) wizard_args+=(--vector-no-tls --vector-tls) ;;
            c) wizard_value 'Path file CA' "${ca_source:-belum diatur}" --vector-ca ;;
            n) wizard_args+=(--vector-no-tls) ;;
        esac
    fi

    if wizard_step '6/6 Konfigurasi milik deployment lain'; then
        wizard_choice 'Izinkan penggantian konfigurasi yang tidak dikelola Script? [y/N]: ' '^(y|n|s|skip)?$'
        if [[ $wizard_reply == y ]]; then wizard_args+=(--replace-config); fi
    fi
    parse_args "${wizard_args[@]}"
}

wizard_confirm() {
    printf '\nRingkasan konfigurasi\n'
    printf '  Zabbix: %s:%s | host %s | seri %s\n' "$zabbix_server" "$zabbix_port" "$agent_hostname" "$zabbix_series"
    printf '  Passive checks: %s | TLS PSK: %s\n' "$([[ $passive == 1 ]] && printf aktif || printf nonaktif)" "$([[ -n $psk_source ]] && printf aktif || printf nonaktif)"
    printf '  Vector: %s:%s | TLS: %s | metrik host: %s\n' "$vector_aggregator" "$vector_port" "$([[ $vector_tls == 1 ]] && printf aktif || printf nonaktif)" "$([[ $metrics == 1 ]] && printf aktif || printf nonaktif)"
    printf '  File log aplikasi: %s\n' "${app_services[*]:-tidak ada}"
    printf '  Grup log tambahan: %s\n' "${app_log_groups[*]:-tidak ada}"
    printf '  Plugin Zabbix: %s\n' "${zabbix_plugins[*]:-tidak ada}"
    printf '  Preset Docker: %s\n' "$([[ $docker_monitoring == 1 ]] && printf aktif || printf nonaktif)"
    if ((replace)); then info "  Penggantian konfigurasi deployment lain diizinkan."; fi
    wizard_choice 'Instal paket yang diperlukan dan terapkan konfigurasi? [y/N]: ' '^(y|n|s|skip)?$'
    if [[ $wizard_reply != y ]]; then
        info "Dibatalkan. Konfigurasi belum diterapkan."
        exit 0
    fi
}

parse_args "$@"
if ((interactive)); then wizard_collect; fi

if ((install_plugins_only && ${#zabbix_plugins[@]} == 0)); then
    die 'Tentukan minimal satu --zabbix-plugin untuk mode --install-plugins.'
fi
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

if ((interactive)); then wizard_confirm; fi

if ((docker_monitoring)); then
    [[ -S $docker_socket ]] || die "Socket Docker belum tersedia: $docker_socket. Pastikan Docker Engine aktif."
    docker_owner=$(stat -Lc '%G:%g' -- "$docker_socket") || die "Gagal memeriksa grup socket Docker."
    [[ $docker_owner =~ ^docker:[1-9][0-9]*$ ]] || die "Preset Docker memerlukan socket dengan grup docker non-root: $docker_socket."
    command -v curl >/dev/null || die "curl diperlukan untuk memeriksa akses API Docker."
fi
vector_service_groups=$vector_groups
if ((docker_monitoring)) && [[ " $vector_service_groups " != *" docker "* ]]; then
    vector_service_groups+=" docker"
fi

zbx_config=/etc/zabbix/zabbix_agent2.conf
zbx_docker_dropin=/etc/systemd/system/zabbix-agent2.service.d/60-victoria-docker.conf
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
manage_zbx_docker_dropin=0
if ((docker_monitoring)) || grep -Fxq -- "$marker" "$zbx_docker_dropin" 2>/dev/null; then
    check_existing_config "$zbx_docker_dropin" zabbix-agent2
    manage_zbx_docker_dropin=1
fi

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
    if ((!configure_only && !install_plugins_only)) && ! dnf -q --cacheonly repolist --enabled |
        awk '$1 == "vector" { found=1 } END { exit !found }'; then
        setup_vector_repo=1
    fi
fi

if ((configure_only || install_plugins_only)) && { [[ -z $installed_series ]] || ((install_vector)); }; then
    die "Mode --configure-only dan --install-plugins memerlukan zabbix-agent2 dan vector yang sudah terpasang."
fi

missing_plugins=()
for plugin in "${zabbix_plugins[@]}"; do
    package="zabbix-agent2-plugin-$plugin"
    version=$(rpm -q --qf '%{VERSION}' "$package" 2>/dev/null) || version=
    version=${version#*:}
    if [[ -z $version ]]; then
        missing_plugins+=("$package")
    elif [[ $version != "$zabbix_series".* || $version == *~* ]]; then
        die "Versi $package yang terpasang ($version) tidak cocok dengan seri $zabbix_series."
    fi
done
if ((configure_only && ${#missing_plugins[@]} > 0)); then
    die "Paket belum terpasang: ${missing_plugins[*]}. Gunakan --install-plugins bersama --zabbix-plugin."
fi

install_zabbix_packages=0
if [[ -z $installed_series ]] || ((${#missing_plugins[@]})); then install_zabbix_packages=1; fi

if ((install_zabbix_packages)) || ((install_vector)); then
    command -v curl >/dev/null || die "curl diperlukan untuk mengecek koneksi HTTPS sebelum instalasi."
    if ((install_zabbix_packages)); then
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
    info "Paket yang diminta sudah terpasang. Pengecekan koneksi internet dilewati."
fi

if ((install_zabbix_packages)); then
    info "Memasang paket Zabbix seri $zabbix_series."
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
    zabbix_packages=()
    zabbix_dnf_args=(--disablerepo='epel*')
    if [[ -z $installed_series ]]; then
        zabbix_packages+=("zabbix-agent2-$zabbix_series.*")
    else
        zabbix_dnf_args+=(--exclude=zabbix-agent2)
    fi
    for package in "${missing_plugins[@]}"; do zabbix_packages+=("$package-$zabbix_series.*"); done
    dnf -y "${zabbix_dnf_args[@]}" install "${zabbix_packages[@]}"
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
if ((docker_monitoring)); then
    info "Menguji akses Docker untuk Zabbix Agent 2 dan Vector."
    for account in zabbix vector; do
        runuser -u "$account" -g "$account" -G docker -- \
            curl -q --fail --silent --show-error --max-time 5 --noproxy '*' \
            --unix-socket "$docker_socket" http://localhost/_ping >/dev/null ||
            die "User $account tidak dapat mengakses API Docker melalui $docker_socket."
    done
fi

plugin_configs=()
for plugin in "${zabbix_plugins[@]}"; do
    package="zabbix-agent2-plugin-$plugin"
    package_files=$(rpm -ql "$package") || die "Gagal membaca daftar file dari $package."
    found=0
    while IFS= read -r path; do
        case "$path" in
            /etc/zabbix/zabbix_agent2.d/*.conf)
                [[ -f $path && -r $path ]] || die "Konfigurasi plugin tidak dapat dibaca: $path."
                plugin_configs+=("$path")
                found=1 ;;
        esac
    done <<< "$package_files"
    ((found)) || die "Tidak menemukan konfigurasi Agent 2 dari paket $package."
done

{
    printf '%s\nLogType=system\nHostname=%s\nServerActive=%s:%s\n' \
        "$marker" "$agent_hostname" "$zabbix_server" "$zabbix_port"
    if ((passive)); then
        printf 'Server=%s\nListenPort=10050\n' "$zabbix_server"
    fi
    if [[ -n $psk_source ]]; then
        printf 'TLSConnect=psk\nTLSAccept=psk\nTLSPSKIdentity=%s\nTLSPSKFile=%s\n' "$psk_identity" "$psk_dest"
    fi
    if ((docker_monitoring)); then
        printf 'Plugins.Docker.Endpoint=unix://%s\n' "$docker_socket"
    fi
    for path in "${plugin_configs[@]}"; do printf 'Include=%s\n' "$path"; done
} > "$work_dir/zabbix.conf"

# Vector cannot follow journals across boots with journalctl 250 through 257.
journal_boot_only=true
journalctl_version=$(LC_ALL=C journalctl --version 2>/dev/null) || journalctl_version=
if [[ $journalctl_version =~ ^systemd[[:blank:]]+([0-9]{1,5})([.[:space:]]|$) ]]; then
    systemd_major=$((10#${BASH_REMATCH[1]}))
    if ((systemd_major >= 250 && systemd_major <= 257)); then
        info "systemd $systemd_major terdeteksi. Vector akan membaca journal dari boot saat ini."
    else
        journal_boot_only=false
    fi
else
    info "Versi journalctl tidak terdeteksi. Vector akan membaca journal dari boot saat ini."
fi

vector_scheme=http
if ((vector_tls)); then vector_scheme=https; fi

{
    printf '%s\n' "$marker"
    cat <<YAML
data_dir: /var/lib/vector
sources:
  journald:
    type: journald
    since_now: true
    current_boot_only: $journal_boot_only
    exclude_units:
      - vector.service
YAML
    inputs='journald'
    if ((docker_monitoring)); then
        cat <<YAML
  docker_container_logs:
    type: docker_logs
    docker_host: "unix://$docker_socket"
YAML
        inputs+=', docker_container_logs'
    fi
    if ((metrics)); then
        cat <<'YAML'
  host_metrics:
    type: host_metrics
    scrape_interval_secs: 30
    filesystem:
      mountpoints:
        excludes:
          - "/run/user/*"
          - "/run/user/**/*"
          - "/run/media/**/*"
          - "/var/lib/docker/rootfs/overlayfs/**/*"
          - "/var/lib/docker/overlay2/*/merged"
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
    address: "$vector_scheme://$vector_aggregator:$vector_port"
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
SupplementaryGroups=$vector_service_groups
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
    if [[ -n $service ]]; then restart_needed[$service]=1; fi
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
if ((manage_zbx_docker_dropin)); then
    {
        printf '%s\n[Service]\n' "$marker"
        if ((docker_monitoring)); then printf '%s\n' 'SupplementaryGroups=docker'; fi
    } > "$work_dir/zabbix-docker.conf"
    put_file "$work_dir/zabbix-docker.conf" "$zbx_docker_dropin" root 0644 "${services[0]}"
fi
put_file "$work_dir/zabbix.conf" "$zbx_config" zabbix 0640 "${services[0]}"
put_file "$work_dir/vector.yaml" "$vector_config" vector 0640 "${services[1]}"
put_file "$work_dir/vector.conf" "$vector_dropin" root 0644 "${services[1]}"

runuser -u zabbix -- zabbix_agent2 -T -c "$zbx_config"
runuser -u vector -- vector validate --no-environment "$vector_config"

report_service_failure() {
    local service=$1
    systemctl status "$service" --no-pager --full >&2 || :
    journalctl -u "$service" --since "@$service_start_at" -n 30 --no-pager >&2 || :
    die "Layanan gagal berjalan: $service."
}

changing_services=1
info "Memuat ulang unit systemd."
systemctl daemon-reload
service_start_at=$(date +%s)
for service in "${services[@]}"; do
    info "Mengaktifkan $service saat boot."
    systemctl enable "$service" || report_service_failure "$service"
    if systemctl is-active --quiet "$service"; then
        if [[ ${restart_needed[$service]:-0} != 1 ]]; then
            info "$service sudah aktif dan konfigurasinya sama."
            continue
        fi
        info "Memulai ulang $service."
        if [[ $service == vector.service ]]; then
            info "Menunggu Vector menyelesaikan graceful shutdown sebelum memakai konfigurasi baru."
        fi
        systemctl restart "$service" || report_service_failure "$service"
    else
        info "Memulai $service."
        systemctl reset-failed "$service" >/dev/null 2>&1 || :
        systemctl start "$service" || report_service_failure "$service"
    fi
done
sleep 2
for service in "${services[@]}"; do
    systemctl is-active --quiet "$service" || report_service_failure "$service"
done

# Tulis pengaturan setelah konfigurasi valid dan kedua layanan terverifikasi aktif.
settings=(
    --hostname "$agent_hostname"
    --zabbix-server "$zabbix_server" --zabbix-port "$zabbix_port" --zabbix-series "$zabbix_series"
    --vector-aggregator "$vector_aggregator" --vector-port "$vector_port"
)
for plugin in "${zabbix_plugins[@]}"; do settings+=(--zabbix-plugin "$plugin"); done
if ((passive)); then settings+=(--passive); fi
if ((docker_monitoring)); then settings+=(--docker-monitoring); fi
if ((!metrics)); then settings+=(--logs-only); fi
if [[ -n $psk_source ]]; then settings+=(--psk-identity "$psk_identity" --psk-file "$psk_dest"); fi
if ((vector_tls)); then settings+=(--vector-tls); fi
if [[ -n $ca_source ]]; then settings+=(--vector-ca "$ca_dest"); fi
for ((index=0; index<${#app_services[@]}; index++)); do
    while IFS= read -r path; do
        settings+=(--app-log "${app_services[index]}=$path")
    done <<< "${app_log_paths[index]}"
done
read -r -a state_groups <<< "$vector_groups"
for group in "${state_groups[@]:1}"; do
    settings+=(--app-log-group "$group")
done
printf '%s\n' "$state_header" "${settings[@]}" > "$work_dir/settings"
put_file "$work_dir/settings" "$state_file" root 0600 ''

info "Kedua agen aktif. Host Zabbix: $agent_hostname"
info "Pengaturan deployment tersimpan di $state_file."
info "Zabbix active: $zabbix_server:$zabbix_port | Vector native: $vector_aggregator:$vector_port"
if [[ -n $backup_dir ]]; then info "Cadangan konfigurasi: $backup_dir"; fi
info 'Verifikasi Latest data di Zabbix dan cari log uji berikut di VictoriaLogs/Grafana.'
info 'logger -t victoria-agent-test "victoria-agent-test $(hostname) $(date -Is)"'
