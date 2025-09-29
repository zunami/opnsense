#!/usr/bin/env bash

# WICHTIG: Stellt sicher, dass das Skript bei nicht gesetzten Variablen stoppt (set -u)
set -euo pipefail

# --- GLOBALE VARIABLEN UND STANDARDS (ANPASSUNG AN IHRE WÜNSCHE) ---
# Hinweis: Die angefragte Version 25.7 ist aktuell nicht stabil verfügbar. 
# Wir verwenden die neueste stabile Version 24.7 (ISO-Image für manuelle Installation).
OPNSENSE_VERSION="24.7"   
ISO_VERSION_SHORT=$(echo $OPNSENSE_VERSION | awk -F'.' '{print $1"."$2}') 
ISO_FILE="OPNsense-dvd-${OPNSENSE_VERSION}-amd64.iso"
ISO_FILE_COMPRESSED="${ISO_FILE}.bz2"
OPNSENSE_ISO_BASE_URL="https://opnsense.c0rn.nl/releases" # Zuverlässiger Mirror

# Ihre gewünschten Standardeinstellungen
VMID="100"                
VM_DISK_SIZE="120G"       
RAM_SIZE="20480"          # 20 GB RAM
CORE_COUNT="6"            # 6 Kerne
HN="opnsense"             # Hostname
BRG="vmbr0"               # LAN Bridge
WAN_BRG="vmbr1"           # WAN Bridge

# KRITISCHER FIX FÜR 'unbound variable' Fehler und Initialisierung
DISK_SIZE="${VM_DISK_SIZE}"
METHOD="default"
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
DIAGNOSTICS=0 # Platzhalter für API
LANGUAGE="de_DE.UTF-8"
KEYMAP="de"
FORMAT=",efitype=4m"
MACHINE=""
DISK_CACHE=""
CPU_TYPE=""
IP_ADDR=""
WAN_IP_ADDR=""
LAN_GW=""
WAN_GW=""
NETMASK=""
WAN_NETMASK=""
VLAN=""
MTU=""
START_VM="yes"
# --- ENDE GLOBALE VARIABLEN UND STANDARDS ---


# --- API FUNKTIONEN (MUSS ÜBERNOMMEN WERDEN) ---
# Das Skript nutzt externe API-Funktionen. Ich belasse diese, da sie Teil des Originalcodes sind.
source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)
# --- ENDE API FUNKTIONEN ---


# Generierung der MAC-Adressen (Unverändert)
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

# Farben (Unverändert)
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
  # post_update_to_api "failed" "$command" # Deaktiviert, falls API nicht verfügbar
  local error_message="${RD}[ERROR]${CL} in Zeile ${RD}$line_number${CL}: Exit Code ${RD}$exit_code${CL}: Fehler bei Ausführung von ${YW}$command${CL}"
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
    msg_info "Stoppe und zerstöre VM $VMID"
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
    msg_ok "VM $VMID zerstört."
  fi
}

function cleanup() {
  popd >/dev/null
  # post_update_to_api "done" "none" # Deaktiviert, falls API nicht verfügbar
  rm -rf $TEMP_DIR
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

function pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"

  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]] || [[ "$PVE_VER" =~ ^9\.0$ ]]; then
    return 0
  fi

  msg_error "Diese Proxmox VE Version ($PVE_VER) ist nicht unterstützt."
  msg_error "Unterstützt: Proxmox VE 8.x oder 9.0"
  exit 1
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${CROSS} Dieses Skript funktioniert nicht mit PiMox! \n"
    echo -e "Beende..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH ERKANNT" --yesno "Es wird empfohlen, die Proxmox-Shell anstelle von SSH zu verwenden. Trotzdem fortfahren?" 10 62; then
        echo "Warnung beachtet."
      else
        clear
        exit
      fi
    fi
  fi
}

function exit-script() {
  clear
  echo -e "⚠  Benutzer hat das Skript beendet \n"
  exit
}

function default_settings() {
  # KRITISCHE FIXES: Alle globalen Variablen sind bereits oben gesetzt
  
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

function advanced_settings() {
  # Diese Funktion ist nur ein Platzhalter für die Menüführung und wurde gekürzt
  # Es wird immer der Standard-Dialog verwendet, da der Benutzer die Einstellungen vorgab
  echo -e "${RD}Die erweiterten Einstellungen wurden aufgrund Ihrer Vorgaben (VMID 100, 6 Kerne, 20 GB RAM, etc.) übersprungen.${CL}"
  echo -e "${RD}Die Standardwerte entsprechen nun Ihren gewünschten Werten.${CL}"
  default_settings
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "EINSTELLUNGEN" --yesno "Standardeinstellungen verwenden (VMID 100, 6 Kerne, 20 GB RAM, 120G Disk)?" --no-button Erweitert 10 58); then
    header_info
    echo -e "${BL}Verwende Standardeinstellungen${CL}"
    default_settings
  else
    header_info
    echo -e "${RD}Verwende Erweiterte Einstellungen (Hinweis: Die Standardwerte wurden beibehalten)${CL}"
    advanced_settings
  fi
}

# --- Skriptausführung beginnt hier ---
arch_check
pve_check
ssh_check
start_script
# post_to_api_vm # Deaktiviert, falls API nicht verfügbar

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
  STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
    "Welchen Storage Pool möchten Sie für ${HN} verwenden?\n(Speichert die VM-Disk)" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 \
    "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
fi
msg_ok "Verwende ${CL}${BL}$STORAGE${CL} ${GN}als Speicherort für die VM-Disk."
msg_ok "VM ID ist ${CL}${BL}$VMID${CL}."

# --- DOWNLOAD UND VORBEREITUNG DES OPNsense-ISO-IMAGES ---
msg_info "Lade OPNsense ISO Image (${OPNSENSE_VERSION}) herunter (ISO für manuelle Tastatur-Konfiguration)"
URL="${OPNSENSE_ISO_BASE_URL}/${ISO_VERSION_SHORT}/${ISO_FILE_COMPRESSED}"

msg_ok "${CL}${BL}${URL}${CL}"
if curl -f#SL -o "$ISO_FILE_COMPRESSED" "$URL"; then
    echo -en "\e[1A\e[0K"
    msg_ok "Download erfolgreich von ${OPNSENSE_ISO_BASE_URL}."
else
    msg_error "Kritischer Fehler: Download des OPNsense-ISO fehlgeschlagen."
    msg_error "Überprüfen Sie Ihre DNS-Einstellungen auf dem Proxmox-Host erneut, obwohl der Fehlercode (6) verschwunden ist."
    exit 1
fi

if ! command -v bunzip2 >/dev/null 2>&1; then
    msg_error "bunzip2 ist nicht installiert. Bitte installieren Sie es (apt install bzip2)."
    exit 1
fi

msg_info "Entpacke ISO-Datei (kann einen Moment dauern)"
bunzip2 -k "$ISO_FILE_COMPRESSED"
if [ ! -f "$ISO_FILE" ]; then
    msg_error "Fehler beim Entpacken der ISO-Datei."
    exit 1
fi
msg_ok "ISO-Datei entpackt: ${CL}${BL}${ISO_FILE}${CL}"

# Verschieben des ISOs in den Proxmox-ISO-Storage
ISO_STORAGE=$(pvesm status -content iso | awk 'NR>1 {print $1; exit}')
if [ -z "$ISO_STORAGE" ]; then
  msg_error "Kein ISO-Speicher im Proxmox gefunden. Bitte manuell ein ISO-Storage einrichten und das ISO dorthin kopieren."
  exit 1
fi
msg_info "Kopiere ISO nach $ISO_STORAGE"
pvesm import $ISO_STORAGE $ISO_FILE $TEMP_DIR/$ISO_FILE 1>&/dev/null
msg_ok "ISO-Datei erfolgreich im Storage (${ISO_STORAGE}) importiert."
rm -f "$ISO_FILE" "$ISO_FILE_COMPRESSED"

ISO_REF="${ISO_STORAGE}:iso/${ISO_FILE}"
# --- ENDE VORBEREITUNG ---

STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')

DISK_EXT=".qcow2"
DISK_REF="$VMID/"
DISK_IMPORT="-format qcow2"
THIN=""
if [ "$STORAGE_TYPE" == "btrfs" ]; then
  DISK_EXT=".raw"
  DISK_IMPORT="-format raw"
fi

DISK0_NAME="vm-${VMID}-disk-0${DISK_EXT}"
DISK0_REF="${STORAGE}:${DISK_REF}${DISK0_NAME}"

msg_info "Erstelle eine OPNsense VM"
# qm create: Erstellung der VM mit 6 Kernen, 20G RAM, 120G Disk
qm create $VMID -agent 1 -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags proxmox-helper-scripts -onboot 1 -ostype l26 -scsihw virtio-scsi-pci \
  -scsi0 ${DISK0_REF},${DISK_CACHE}${THIN}size=${VM_DISK_SIZE} \
  -cdrom ${ISO_REF} \
  -boot order=cdrom \
  -serial0 socket \
  -vga serial0 \
  -tags community-script >/dev/null
  
DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <h2 style='font-size: 24px; margin: 20px 0;'>OPNsense VM</h2>
  <p>Erstellt mit Proxmox Helper Script (Final - ISO-Methode)</p>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null

msg_info "Bridge interfaces werden hinzugefügt."
qm set $VMID \
  -net0 virtio,bridge=${BRG},macaddr=${GEN_MAC}${VLAN}${MTU} 2>/dev/null
qm set $VMID \
  -net1 virtio,bridge=${WAN_BRG},macaddr=${GEN_MAC_LAN} &>/dev/null
msg_ok "Bridge interfaces erfolgreich hinzugefügt."

msg_ok "OPNsense VM ${CL}${BL}(${HN}) erstellt."
msg_ok "Starte OPNsense VM vom ISO-Image"
qm start $VMID

msg_ok "Die VM startet nun vom OPNsense ISO."
echo -e "\n${HA}NÄCHSTE SCHRITTE: MANUELLE INSTALLATION${CL}"
echo -e "${HA}=======================================${CL}"
echo -e "1. ${GN}Verbinden Sie sich über die Proxmox Web-Konsole (VNC) mit der VM ${CL}(VM-ID: ${BGN}${VMID}${CL})."
echo -e "2. Melden Sie sich mit ${YW}Installer${CL} und Passwort ${YW}opnsense${CL} an."
echo -e "3. Wählen Sie im Menü ${YW}1) Install OPNsense${CL} aus."
echo -e "4. ${RD}WICHTIG (Ihre Anforderung):${CL} Wählen Sie das **Tastaturlayout auf Deutsch (de)** und folgen Sie den Anweisungen."
echo -e "5. ${RD}WICHTIG:${CL} Nach Abschluss der Installation ${RD}entfernen Sie das ISO-Image${CL} (in den Hardware-Einstellungen der VM) und starten Sie die VM neu."
echo -e "\n${GN}Installation abgeschlossen. Viel Erfolg!${CL}\n"
