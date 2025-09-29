#!/usr/bin/env bash

# WICHTIG: Stellt sicher, dass das Skript bei nicht gesetzten Variablen stoppt (set -u)
set -euo pipefail

# --- GLOBALE VARIABLEN UND STANDARDS (ANPASSUNG AN IHRE WÜNSCHE) ---
# WICHTIG: Umstellung auf QCOW2-Image für stabilere Installation
OPNSENSE_QCOW2_URL="https://opnsense.c0rn.nl/latest/OPNsense-24.7-vga-amd64.qcow2.bz2" 
VM_DISK_SIZE="120G"       
RAM_SIZE="20480"          # 20 GB RAM
CORE_COUNT="6"            # 6 Kerne
VMID="100"                # Ihre gewünschte VM-ID
HN="opnsense"             # Hostname
BRG="vmbr0"               # LAN Bridge
WAN_BRG="vmbr1"           # WAN Bridge
# --- ENDE GLOBALE VARIABLEN ---

# --- API FUNKTIONEN (MUSS ÜBERNOMMEN WERDEN) ---
# Das Skript nutzt externe API-Funktionen. Ich belasse diese, da sie Teil des Originalcodes sind.
source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)
# --- ENDE API FUNKTIONEN ---


# Initialisierung und Farben (Unverändert)
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="opnsense-vm"
var_os="opnsense"
var_version="25.1"
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
DISK_CACHE=""
CPU_TYPE=""
VLAN=""
IP_ADDR=""
WAN_IP_ADDR=""
LAN_GW=""
WAN_GW=""
NETMASK=""
WAN_NETMASK=""
MTU=""
START_VM="yes"

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -Eeo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# Alle Funktionen (header_info, error_handler, get_valid_nextid, cleanup_vmid, cleanup, send_line_to_vm,
# msg_info, msg_ok, msg_error, pve_check, arch_check, ssh_check, exit-script, default_settings, advanced_settings, start_script)
# sind hier nicht abgebildet, um den Code kurz zu halten, aber sie müssten in Ihrem vollständigen Skript vorhanden sein.
# WICHTIG: Die Funktionen 'default_settings' und 'start_script' im Original-Skript MÜSSEN gelöscht werden, da wir nun
# eine direkte Konfiguration verwenden und die whiptail-Abfragen überspringen.

function header_info {
  clear
  cat <<"EOF"
   ____  ____  _   __                        
  / __ \/ __ \/ | / /_______  ____  ________ 
 / / / / /_/ /  |/ / ___/ _ \/ __ \/ ___/ _ \
/ /_/ / ____/ /|  (__  )  __/ / / (__  )  __/
\____/_/   /_/ |_/____/\___/_/ /_/____/\___/ 
                                                                         
EOF
}
header_info
echo -e "Loading..."

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  post_update_to_api "failed" "$command"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  post_update_to_api "done" "none"
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
function send_line_to_vm() {
  echo -e "${DGN}Sending line: ${YW}$1${CL}"
  for ((i = 0; i < ${#1}; i++)); do
    character=${1:i:1}
    case $character in
    " ") character="spc" ;;
    "-") character="minus" ;;
    "=") character="equal" ;;
    ",") character="comma" ;;
    ".") character="dot" ;;
    "/") character="slash" ;;
    "'") character="apostrophe" ;;
    ";") character="semicolon" ;;
    '\') character="backslash" ;;
    '`') character="grave_accent" ;;
    "[") character="bracket_left" ;;
    "]") character="bracket_right" ;;
    "_") character="shift-minus" ;;
    "+") character="shift-equal" ;;
    "?") character="shift-slash" ;;
    "<") character="shift-comma" ;;
    ">") character="shift-dot" ;;
    '"') character="shift-apostrophe" ;;
    ":") character="shift-semicolon" ;;
    "|") character="shift-backslash" ;;
    "~") character="shift-grave_accent" ;;
    "{") character="shift-bracket_left" ;;
    "}") character="shift-bracket_right" ;;
    "A") character="shift-a" ;;
    "B") character="shift-b" ;;
    "C") character="shift-c" ;;
    "D") character="shift-d" ;;
    "E") character="shift-e" ;;
    "F") character="shift-f" ;;
    "G") character="shift-g" ;;
    "H") character="shift-h" ;;
    "I") character="shift-i" ;;
    "J") character="shift-j" ;;
    "K") character="shift-k" ;;
    "L") character="shift-l" ;;
    "M") character="shift-m" ;;
    "N") character="shift-n" ;;
    "O") character="shift-o" ;;
    "P") character="shift-p" ;;
    "Q") character="shift-q" ;;
    "R") character="shift-r" ;;
    "S") character="shift-s" ;;
    "T") character="shift-t" ;;
    "U") character="shift-u" ;;
    "V") character="shift-v" ;;
    "W") character="shift-w" ;;
    "X") character="shift=x" ;;
    "Y") character="shift-y" ;;
    "Z") character="shift-z" ;;
    "!") character="shift-1" ;;
    "@") character="shift-2" ;;
    "#") character="shift-3" ;;
    '$') character="shift-4" ;;
    "%") character="shift-5" ;;
    "^") character="shift-6" ;;
    "&") character="shift-7" ;;
    "*") character="shift-8" ;;
    "(") character="shift-9" ;;
    ")") character="shift-0" ;;
    esac
    qm sendkey $VMID "$character"
  done
  qm sendkey $VMID ret
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"

  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR < 0 || MINOR > 9)); then
      msg_error "This version of Proxmox VE is not supported."
      msg_error "Supported: Proxmox VE version 8.0 – 8.9"
      exit 1
    fi
    return 0
  fi

  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR != 0)); then
      msg_error "This version of Proxmox VE is not yet supported."
      msg_error "Supported: Proxmox VE version 9.0"
      exit 1
    fi
    return 0
  fi

  msg_error "This version of Proxmox VE is not supported."
  msg_error "Supported versions: Proxmox VE 8.0 – 8.x or 9.0"
  exit 1
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${CROSS} This script will not work with PiMox! \n"
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
      fi
    fi
  fi
}

function exit-script() {
  clear
  echo -e "⚠  User exited script \n"
  exit
}

function start_script() {
  # Stellt die Standardeinstellungen dar, ohne den whiptail-Dialog.
  echo -e "${DGN}Verwende VM ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Zugewiesene Kerne: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}Zugewiesener RAM: ${BGN}${RAM_SIZE} MiB (20 GB)${CL}"
  if ! grep -q "^iface ${BRG}" /etc/network/interfaces; then
    msg_error "Bridge '${BRG}' existiert nicht in /etc/network/interfaces"
    exit
  else
    echo -e "${DGN}Verwende LAN Bridge: ${BGN}${BRG}${CL}"
  fi
  echo -e "${DGN}Verwende LAN MAC: ${BGN}${GEN_MAC}${CL}"
  echo -e "${DGN}Verwende WAN MAC: ${BGN}${GEN_MAC_LAN}${CL}"
  if ! grep -q "^iface ${WAN_BRG}" /etc/network/interfaces; then
    msg_error "Bridge '${WAN_BRG}' existiert nicht in /etc/network/interfaces"
    exit
  else
    echo -e "${DGN}Verwende WAN Bridge: ${BGN}${WAN_BRG}${CL}"
  fi
  echo -e "${DGN}Festplattengröße: ${BGN}${VM_DISK_SIZE}${CL}"
  echo -e "${DGN}Starte VM nach Abschluss: ${BGN}ja${CL}"
  echo -e "${BL}Erstelle eine OPNsense VM mit den oben genannten Standardeinstellungen${CL}"
}

arch_check
pve_check
ssh_check
start_script
post_to_api_vm

msg_info "Speicherort wird überprüft"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Typ: $TYPE Frei: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Kein gültiger Speicherort für Images gefunden."
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  # Wenn es mehrere Storages gibt, muss der Benutzer immer noch manuell auswählen.
  # Da wir Standardeinstellungen verwenden, nehme ich den ersten gefundenen Storage.
  STORAGE=${STORAGE_MENU[0]}
fi
msg_ok "Verwende ${CL}${BL}$STORAGE${CL} ${GN}als Speicherort für die VM-Disk."
msg_ok "VM ID ist ${CL}${BL}$VMID${CL}."

# --- DOWNLOAD UND VORBEREITUNG DES OPNsense-QCOW2-IMAGES ---
msg_info "Lade das OPNsense QCOW2 Disk Image herunter (zuverlässigste Methode)"
msg_ok "${CL}${BL}${OPNSENSE_QCOW2_URL}${CL}"

# Download-Versuch
FILE_COMPRESSED="$(basename "$OPNSENSE_QCOW2_URL")"
FILE_QCOW2="${FILE_COMPRESSED/.bz2/}"

if curl -f#SL -o "$FILE_COMPRESSED" "$OPNSENSE_QCOW2_URL"; then
    echo -en "\e[1A\e[0K"
    msg_ok "Download erfolgreich von ${OPNSENSE_QCOW2_URL}."
else
    msg_error "Kritischer Fehler: Download des OPNsense-QCOW2-Images fehlgeschlagen."
    msg_error "Bitte beheben Sie das DNS-Problem auf Ihrem Proxmox-Host (siehe Anweisungen oben) und versuchen Sie es erneut."
    exit 1
fi

msg_info "Entpacke QCOW2-Datei"
if ! command -v bunzip2 >/dev/null 2>&1; then
    msg_error "bunzip2 ist nicht installiert. Bitte installieren Sie es (apt install bzip2)."
    exit 1
fi

bunzip2 -k "$FILE_COMPRESSED"
if [ ! -f "$FILE_QCOW2" ]; then
    msg_error "Fehler beim Entpacken der QCOW2-Datei."
    exit 1
fi
msg_ok "QCOW2-Datei entpackt: ${CL}${BL}${FILE_QCOW2}${CL}"
# --- ENDE VORBEREITUNG ---


STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs | dir)
  DISK_EXT=".qcow2"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format qcow2"
  THIN=""
  ;;
btrfs)
  DISK_EXT=".raw"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format raw"
  FORMAT=",efitype=4m"
  THIN=""
  ;;
esac

# Die OPNsense QCOW2 hat nur eine Disk, die wir als scsi0 importieren.
DISK0_NAME="vm-${VMID}-disk-0${DISK_EXT:-}"
DISK0_REF="${STORAGE}:${DISK_REF:-}${DISK0_NAME}"
DISK_SIZE_BYTES=$(numfmt --from=iec $VM_DISK_SIZE | numfmt --to=iec --format='%.0f')

msg_info "Erstelle eine OPNsense VM"
# qm create: Erstellung der VM mit 6 Kernen, 20G RAM
qm create $VMID -agent 1 -tablet 0 -localtime 1 -bios ovmf -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags proxmox-helper-scripts -onboot 1 -ostype l26 -scsihw virtio-scsi-pci \
  -serial0 socket -vga serial0 -tags community-script >/dev/null

msg_info "Importiere QCOW2-Disk und weise ${VM_DISK_SIZE} Speicherplatz zu"
# Import der heruntergeladenen QCOW2-Datei
qm importdisk $VMID ${FILE_QCOW2} $STORAGE ${DISK_IMPORT:-} 1>&/dev/null

# Setze die importierte Disk als SCSI0 und stelle die Boot-Reihenfolge ein
qm set $VMID \
  -scsi0 ${DISK0_REF},${DISK_CACHE}${THIN}size=${VM_DISK_SIZE} \
  -boot order=scsi0 \
  -efidisk0 none >/dev/null # EFI-Disk ist in QCOW2 bereits integriert oder wird nicht benötigt

# Resize der Disk, falls die importierte Disk kleiner ist als die Zielgröße
qm resize $VMID scsi0 ${VM_DISK_SIZE} >/dev/null

rm -f "$FILE_COMPRESSED" "$FILE_QCOW2"

msg_info "Bridge interfaces werden hinzugefügt."
# -net0 ist LAN
qm set $VMID \
  -net0 virtio,bridge=${BRG},macaddr=${GEN_MAC}${VLAN}${MTU} 2>/dev/null
# -net1 ist WAN
qm set $VMID \
  -net1 virtio,bridge=${WAN_BRG},macaddr=${GEN_MAC_LAN} &>/dev/null
msg_ok "Bridge interfaces erfolgreich hinzugefügt."

DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <h2 style='font-size: 24px; margin: 20px 0;'>OPNsense VM</h2>
  <p>Erstellt mit Proxmox Helper Script (final korrigiert - QCOW2)</p>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null

msg_ok "OPNsense VM ${CL}${BL}(${HN}) erstellt."
msg_ok "Starte OPNsense VM"
qm start $VMID
sleep 10
msg_ok "OPNsense wurde erfolgreich gestartet. Es ist keine manuelle Installation mehr nötig, da ein QCOW2-Image verwendet wurde."
echo -e "\n${HA}NÄCHSTE SCHRITTE: ZUGRIFF AUF DIE VM${CL}"
echo -e "${HA}===================================${CL}"
echo -e "1. ${GN}Warten Sie 1-2 Minuten, bis OPNsense komplett hochgefahren ist.${CL}"
echo -e "2. ${GN}Verbinden Sie sich über die Proxmox Web-Konsole (VNC) mit der VM ${CL}(VM-ID: ${BGN}${VMID}${CL})."
echo -e "3. Melden Sie sich mit ${YW}root${CL} und Passwort ${YW}opnsense${CL} an."
echo -e "4. ${RD}Konfigurieren Sie die LAN/WAN-Schnittstellen${CL} oder führen Sie das Web-Setup durch."
echo -e "\n${GN}Installation abgeschlossen. Viel Erfolg!${CL}\n"
