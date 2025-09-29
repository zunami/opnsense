#!/usr/bin/env bash

# WICHTIG: Stellt sicher, dass das Skript bei nicht gesetzten Variablen stoppt (set -u)
set -euo pipefail

# Copyright (c) 2021-2025 community-scripts ORG
# Lizenz: MIT
# ÄNDERUNGEN:
# - KRITISCHE KORREKTUR: Entfernung des externen API-Skripts, der Ursache aller 'unbound variable' Fehler.
# - NEUER STANDARD: CORE_COUNT auf 6 gesetzt.
# - Standards: OPNsense 25.7, 20G RAM, 120G Disk.
# - Korrekturen: PVE-Versionsprüfung und OPNsense ISO Download/Boot-Logik.

# --- GLOBALE VARIABLEN UND STANDARDS ---
OPNSENSE_VERSION="25.7"   
VM_DISK_SIZE="120G"       
RAM_SIZE="20480"          
CORE_COUNT="6"            # Hier ist Ihre Anpassung auf 6 Kerne
LANGUAGE="de_DE.UTF-8"    
KEYMAP="de"               
HN="opnsense"             # Standard-Hostname
# --- ENDE GLOBALE VARIABLEN UND STANDARDS ---

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

# Farben
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

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  # API-Calls entfernt, um Fehler zu vermeiden
  local error_message="${RD}[ERROR]${CL} in Zeile ${RD}$line_number${CL} (Exit Code ${RD}$exit_code${CL}): Fehler bei Ausführung von ${YW}$command${CL}"
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
  # API-Calls entfernt
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "OPNsense VM" --yesno "Dies wird eine neue OPNsense VM erstellen. Fortfahren?" 10 58); then
  :
else
  header_info && echo -e "⚠ Benutzer hat das Skript beendet \n" && exit
fi

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

# KORRIGIERTE PVE VERSIONS PRÜFUNG (Akzeptiert 8.x und 9.0)
pve_check() {
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
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  CPU_TYPE=""
  BRG="vmbr0"
  IP_ADDR=""
  WAN_IP_ADDR=""
  LAN_GW=""
  WAN_GW=""
  NETMASK=""
  WAN_NETMASK=""
  VLAN=""
  MAC=$GEN_MAC
  WAN_MAC=$GEN_MAC_LAN
  WAN_BRG="vmbr1"
  MTU=""
  START_VM="yes"
  METHOD="default"

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
  echo -e "${DGN}Verwende LAN MAC: ${BGN}${MAC}${CL}"
  echo -e "${DGN}Verwende WAN MAC: ${BGN}${WAN_MAC}${CL}"
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
  local ip_regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then
        VMID=$(get_valid_nextid)
      fi
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID ist bereits in Verwendung${CL}"
        sleep 2
        continue
      fi
      echo -e "${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else
      exit-script
    fi
  done

  if MACH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" --radiolist --cancel-button Exit-Script "Wähle Typ" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35" "Machine q35" OFF \
    3>&1 1>&2 2>&3); then
    if [ $MACH = q35 ]; then
      echo -e "${DGN}Verwende Machine Type: ${BGN}$MACH${CL}"
      FORMAT=""
      MACHINE=" -machine q35"
    else
      echo -e "${DGN}Verwende Machine Type: ${BGN}$MACH${CL}"
      FORMAT=",efitype=4m"
      MACHINE=""
    fi
  else
    exit-script
  fi

  if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" --radiolist "Wähle" --cancel-button Exit-Script 10 58 2 \
    "0" "KVM64 (Standard)" ON \
    "1" "Host" OFF \
    3>&1 1>&2 2>&3); then
    if [ $CPU_TYPE1 = "1" ]; then
      echo -e "${DGN}Verwende CPU Model: ${BGN}Host${CL}"
      CPU_TYPE=" -cpu host"
    else
      echo -e "${DGN}Verwende CPU Model: ${BGN}KVM64${CL}"
      CPU_TYPE=""
    fi
  else
    exit-script
  fi

  if DISK_CACHE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" --radiolist "Wähle" --cancel-button Exit-Script 10 58 2 \
    "0" "None (Standard)" ON \
    "1" "Write Through" OFF \
    3>&1 1>&2 2>&3); then
    if [ $DISK_CACHE = "1" ]; then
      echo -e "${DGN}Verwende Disk Cache: ${BGN}Write Through${CL}"
      DISK_CACHE="cache=writethrough,"
    else
      echo -e "${DGN}Verwende Disk Cache: ${BGN}None${CL}"
      DISK_CACHE=""
    fi
  else
    exit-script
  fi

  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze Hostname" 8 58 OPNsense --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VM_NAME ]; then
      HN="OPNsense"
    else
      HN=$(echo ${VM_NAME,,} | tr -d ' ')
    fi
    echo -e "${DGN}Verwende Hostname: ${BGN}$HN${CL}"
  else
    exit-script
  fi

  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Weise CPU Kerne zu" 8 58 6 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $CORE_COUNT ]; then
      CORE_COUNT="2"
    fi
    echo -e "${DGN}Zugewiesene Kerne: ${BGN}$CORE_COUNT${CL}"
  else
    exit-script
  fi

  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Weise RAM in MiB zu" 8 58 20480 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $RAM_SIZE ]; then
      RAM_SIZE="8192"
    fi
    echo -e "${DGN}Zugewiesener RAM: ${BGN}$RAM_SIZE${CL}"
  else
    exit-script
  fi
  
  # Hinzufügen der Festplattengrößenabfrage (Optional, aber gut für erweiterte Einstellungen)
  if VM_DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze Festplattengröße (z.B. 120G)" 8 58 ${VM_DISK_SIZE} --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VM_DISK_SIZE ]; then
      VM_DISK_SIZE="120G"
    fi
    echo -e "${DGN}Festplattengröße: ${BGN}$VM_DISK_SIZE${CL}"
  else
    exit-script
  fi

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine LAN Bridge" 8 58 vmbr0 --title "LAN BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then
      BRG="vmbr0"
    fi
    if ! grep -q "^iface ${BRG}" /etc/network/interfaces; then
      msg_error "Bridge '${BRG}' existiert nicht in /etc/network/interfaces"
      exit
    fi
    echo -e "${DGN}Verwende LAN Bridge: ${BGN}$BRG${CL}"
  else
    exit-script
  fi

  if IP_ADDR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine LAN IP" 8 58 $IP_ADDR --title "LAN IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $IP_ADDR ]; then
      echo -e "${DGN}Verwende DHCP ALS LAN IP ADDRESS${CL}"
    else
      if [[ -n "$IP_ADDR" && ! "$IP_ADDR" =~ $ip_regex ]]; then
        msg_error "Ungültiges IP-Adressformat für LAN IP. Muss 0.0.0.0 sein, war $IP_ADDR"
        exit
      fi
      echo -e "${DGN}Verwende LAN IP ADDRESS: ${BGN}$IP_ADDR${CL}"
      if LAN_GW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine LAN GATEWAY IP" 8 58 $LAN_GW --title "LAN GATEWAY IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $LAN_GW ]; then
          echo -e "${DGN}Gateway muss gesetzt werden, wenn IP nicht DHCP ist${CL}"
          exit-script
        fi
        if [[ -n "$LAN_GW" && ! "$LAN_GW" =~ $ip_regex ]]; then
          msg_error "Ungültiges IP-Adressformat für Gateway. Muss 0.0.0.0 sein, war $LAN_GW"
          exit
        fi
        echo -e "${DGN}Verwende LAN GATEWAY ADDRESS: ${BGN}$LAN_GW${CL}"
      fi
      if NETMASK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine LAN Netzmaske (z.B. 24)" 8 58 $NETMASK --title "LAN NETMASK" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $NETMASK ]; then
          echo -e "${DGN}Netzmaske muss gesetzt werden, wenn IP nicht DHCP ist${CL}"
        fi
        if [[ -n "$NETMASK" && ! ("$NETMASK" =~ ^[0-9]+$ && "$NETMASK" -ge 1 && "$NETMASK" -le 32) ]]; then
          msg_error "Ungültiges LAN NETMASK Format. Muss 1-32 sein, war $NETMASK"
          exit
        fi
        echo -e "${DGN}Verwende LAN NETMASK: ${BGN}$NETMASK${CL}"
      else
        exit-script
      fi
    fi
  else
    exit-script
  fi

  if WAN_BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine WAN Bridge" 8 58 vmbr1 --title "WAN BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $WAN_BRG ]; then
      WAN_BRG="vmbr1"
    fi
    if ! grep -q "^iface ${WAN_BRG}" /etc/network/interfaces; then
      msg_error "WAN Bridge '${WAN_BRG}' existiert nicht in /etc/network/interfaces"
      exit
    fi
    echo -e "${DGN}Verwende WAN Bridge: ${BGN}$WAN_BRG${CL}"
  else
    exit-script
  fi

  if WAN_IP_ADDR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine WAN IP" 8 58 $WAN_IP_ADDR --title "WAN IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $WAN_IP_ADDR ]; then
      echo -e "${DGN}Verwende DHCP ALS WAN IP ADDRESS${CL}"
    else
      if [[ -n "$WAN_IP_ADDR" && ! "$WAN_IP_ADDR" =~ $ip_regex ]]; then
        msg_error "Ungültiges IP-Adressformat für WAN IP. Muss 0.0.0.0 sein, war $WAN_IP_ADDR"
        exit
      fi
      echo -e "${DGN}Verwende WAN IP ADDRESS: ${BGN}$WAN_IP_ADDR${CL}"
      if WAN_GW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine WAN GATEWAY IP" 8 58 $WAN_GW --title "WAN GATEWAY IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $WAN_GW ]; then
          echo -e "${DGN}Gateway muss gesetzt werden, wenn IP nicht DHCP ist${CL}"
          exit-script
        fi
        if [[ -n "$WAN_GW" && ! "$WAN_GW" =~ $ip_regex ]]; then
          msg_error "Ungültiges IP-Adressformat für WAN Gateway. Muss 0.0.0.0 sein, war $WAN_GW"
          exit
        fi
        echo -e "${DGN}Verwende WAN GATEWAY ADDRESS: ${BGN}$WAN_GW${CL}"
      else
        exit-script
      fi
      if WAN_NETMASK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine WAN Netzmaske (z.B. 24)" 8 58 $WAN_NETMASK --title "WAN NETMASK" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $WAN_NETMASK ]; then
          echo -e "${DGN}WAN Netzmaske muss gesetzt werden, wenn IP nicht DHCP ist${CL}"
        fi
        if [[ -n "$WAN_NETMASK" && ! ("$WAN_NETMASK" =~ ^[0-9]+$ && "$WAN_NETMASK" -ge 1 && "$WAN_NETMASK" -le 32) ]]; then
          msg_error "Ungültiges WAN NETMASK Format. Muss 1-32 sein, war $WAN_NETMASK"
          exit
        fi
        echo -e "${DGN}Verwende WAN NETMASK: ${BGN}$WAN_NETMASK${CL}"
      else
        exit-script
      fi
    fi
  else
    exit-script
  fi
  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine LAN MAC Adresse" 8 58 $GEN_MAC --title "LAN MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC1 ]; then
      MAC="$GEN_MAC"
    else
      MAC="$MAC1"
    fi
    echo -e "${DGN}Verwende LAN MAC Adresse: ${BGN}$MAC${CL}"
  else
    exit-script
  fi

  if MAC2=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Setze eine WAN MAC Adresse" 8 58 $GEN_MAC_LAN --title "WAN MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC2 ]; then
      WAN_MAC="$GEN_MAC_LAN"
    else
      WAN_MAC="$MAC2"
    fi
    echo -e "${DGN}Verwende WAN MAC Adresse: ${BGN}$WAN_MAC${CL}"
  else
    exit-script
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ERWEITERTE EINSTELLUNGEN ABGESCHLOSSEN" --yesno "Bereit zur Erstellung der OPNsense VM?" --no-button Do-Over 10 58); then
    echo -e "${RD}Erstelle eine OPNsense VM mit den erweiterten Einstellungen${CL}"
  else
    header_info
    echo -e "${RD}Verwende Erweiterte Einstellungen${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "EINSTELLUNGEN" --yesno "Standardeinstellungen verwenden?" --no-button Erweitert 10 58); then
    header_info
    echo -e "${BL}Verwende Standardeinstellungen${CL}"
    default_settings
  else
    header_info
    echo -e "${RD}Verwende Erweiterte Einstellungen${CL}"
    advanced_settings
  fi
}

arch_check
pve_check
ssh_check
start_script
# post_to_api_vm entfernt

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
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Welchen Storage Pool möchten Sie für ${HN} verwenden?\n(Speichert die VM-Disk)" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Verwende ${CL}${BL}$STORAGE${CL} ${GN}als Speicherort für die VM-Disk."
msg_ok "VM ID ist ${CL}${BL}$VMID${CL}."

# --- DOWNLOAD UND VORBEREITUNG DES OPNsense-ISO-IMAGES ---
msg_info "Lade das offizielle OPNsense ISO Image (${OPNSENSE_VERSION}) herunter"
ISO_VERSION_SHORT=$(echo $OPNSENSE_VERSION | awk -F'.' '{print $1"."$2}') 
URL="https://mirror.opnsense.org/releases/${ISO_VERSION_SHORT}/OPNsense-dvd-${OPNSENSE_VERSION}-amd64.iso.bz2"
ISO_FILE="OPNsense-dvd-${OPNSENSE_VERSION}-amd64.iso"
ISO_FILE_COMPRESSED=$(basename "$URL")

if ! command -v bunzip2 >/dev/null 2>&1; then
    msg_error "bunzip2 ist nicht installiert. Bitte installieren Sie es (apt install bzip2)."
    exit 1
fi

msg_ok "${CL}${BL}${URL}${CL}"
if command -v curl >/dev/null 2>&1; then
  curl -f#SL -o "$ISO_FILE_COMPRESSED" "$URL"
else
  wget -qO "$ISO_FILE_COMPRESSED" "$URL"
fi
echo -en "\e[1A\e[0K"

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
# --- ENDE DOWNLOAD UND VORBEREITUNG ---

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
  <p>Erstellt mit Proxmox Helper Script (final korrigiert)</p>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null

msg_info "Bridge interfaces werden hinzugefügt."
qm set $VMID \
  -net0 virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU} 2>/dev/null
qm set $VMID \
  -net1 virtio,bridge=${WAN_BRG},macaddr=${WAN_MAC} &>/dev/null
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
echo -e "4. Stellen Sie das **Tastaturlayout auf Deutsch (de)** ein und folgen Sie den Anweisungen zur Installation auf die **${VM_DISK_SIZE} Festplatte**."
echo -e "5. ${RD}WICHTIG:${CL} Nach Abschluss der Installation ${RD}entfernen Sie das ISO-Image aus den Hardware-Einstellungen${CL} und starten Sie die VM neu."
echo -e "\n${GN}Installation abgeschlossen. Viel Erfolg!${CL}\n"
