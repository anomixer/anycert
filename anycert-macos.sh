#!/usr/bin/env bash
# ============================================================
# anycert-macos.sh  —  Anycert macOS Client Certificate Installer
# Usage:
#   sudo bash anycert-macos.sh       Install cert, update hosts
#   sudo bash anycert-macos.sh -u    Uninstall cert, remove hosts entry
# Tested on: macOS 12 Monterey+
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

DISPLAY_NAME="anycert-macos.sh"
DATA_DIR="$HOME/Library/Application Support/anycert"
INFO_FILE="$DATA_DIR/anycert-info.txt"
HOSTS_FILE="/etc/hosts"

echo
echo -e "${YELLOW} █████╗ ███╗   ██╗██╗   ██╗ ██████╗███████╗██████╗ ████████╗${RESET}"
echo -e "${YELLOW}██╔══██╗████╗  ██║╚██╗ ██╔╝██╔════╝██╔════╝██╔══██╗╚══██╔══╝${RESET}"
echo -e "${CYAN}███████║██╔██╗ ██║ ╚████╔╝ ██║     █████╗  ██████╔╝   ██║   ${RESET}"
echo -e "${CYAN}██╔══██║██║╚██╗██║  ╚██╔╝  ██║     ██╔══╝  ██╔══██╗   ██║   ${RESET}"
echo -e "${BLUE}██║  ██║██║ ╚████║   ██║   ╚██████╗███████╗██║  ██║   ██║   ${RESET}"
echo -e "${BLUE}╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝╚══════╝╚═╝  ╚═╝   ╚═╝   ${RESET}"
echo -e "${CYAN}                      anycert-macos.sh (macOS Client) ${RESET}"
echo

# ── Check root ────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[INFO] This script requires root privileges."
    read -rp "  Would you like to re-run with sudo? [y/N]: " RUN_SUDO
    if [[ "$RUN_SUDO" =~ ^[Yy]$ ]]; then
        exec sudo bash "$0" "$@"
    fi
    echo "[ERROR] Root privileges are required to run this script."
    exit 1
fi

# ── Check dependencies ─────────────────────────────────────
for cmd in ssh scp openssl security; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] 找不到所需的指令: $cmd"
        echo "  ssh/scp/openssl are tools built into macOS."
        echo "  'security' is a tool built into macOS - if missing, the system may be corrupt."
        exit 1
    fi
done

mkdir -p "$DATA_DIR"

# ============================================================
#  UNINSTALL MODE
# ============================================================
if [[ "${1:-}" == "-u" ]]; then
    echo "[Uninstall Mode] Removing Anycert Certificates and hosts Entries"
    echo "-----------------------------------------------------"
    echo

    remove_one() {
        local R_IP="$1" R_DNS="$2" R_FINGER="$3"
        echo
        echo "  --- Removing: $R_IP $R_DNS ---"

        # Remove hosts entry
        if grep -qi "$R_DNS" "$HOSTS_FILE" 2>/dev/null; then
            if [[ -n "$R_IP" ]]; then
                sed -i '' "/# Anycert Server \[$R_IP\]/d" "$HOSTS_FILE"
                sed -i '' "/^$R_IP[[:space:]][[:space:]]*$R_DNS/d" "$HOSTS_FILE"
            else
                sed -i '' "/$R_DNS/d" "$HOSTS_FILE"
            fi
            echo "  [OK] Removed hosts entry: $R_DNS"
        else
            echo "  [SKIP] Hosts entry not found for: $R_DNS"
        fi

        if [[ -n "$R_IP" ]]; then
            # Remove cert from macOS Keychain
            if [[ -n "$R_FINGER" ]]; then
                local SHA1
                SHA1=$(echo "$R_FINGER" | tr -d ':' | tr '[:upper:]' '[:lower:]')
                if security delete-certificate -Z "$SHA1" /Library/Keychains/System.keychain 2>/dev/null; then
                    echo "  [OK] Removed CA certificate from macOS Keychain."
                else
                    echo "  [WARN] Cannot delete automatically. Please clean up manually:"
                    echo "  Launch 'Keychain Access' > System > Certificates > delete entry containing $R_DNS"
                fi
            else
                echo "  [WARN] Fingerprint record not found. Please clean up Keychain certificate manually."
            fi

            # Remove local cached cert
            [[ -f "$DATA_DIR/anycert-ca-${R_IP}.crt" ]] && rm -f "$DATA_DIR/anycert-ca-${R_IP}.crt" && echo "  [OK] Cached certificate file deleted."

            # Remove from info file
            if [[ -f "$INFO_FILE" ]]; then
                grep -v "^$R_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
                mv "$INFO_FILE.tmp" "$INFO_FILE"
            fi
        fi
    }

    if [[ ! -f "$INFO_FILE" ]]; then
        echo "  No registered servers found. Please manually enter DNS name to clean up:"
        read -rp "  DNS Name [e.g. my-server.local]: " MANUAL_DNS
        [[ -z "$MANUAL_DNS" ]] && { echo "  Cancelled."; exit 0; }
        remove_one "" "$MANUAL_DNS" ""
        echo
        echo "====================================================="
        echo "  Uninstallation Complete!"
        echo "====================================================="
        exit 0
    fi

    # Read info file (compatible with older bash)
    LINES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && LINES+=("$line")
    done < "$INFO_FILE"
    SITE_COUNT=${#LINES[@]}

    if [[ $SITE_COUNT -eq 0 ]]; then
        echo "  No registered servers found. Please manually enter DNS name to clean up:"
        read -rp "  DNS Name [e.g. my-server.local]: " MANUAL_DNS
        [[ -z "$MANUAL_DNS" ]] && { echo "  Cancelled."; exit 0; }
        remove_one "" "$MANUAL_DNS" ""
        echo
        echo "====================================================="
        echo "  Uninstallation Complete!"
        echo "====================================================="
        exit 0
    fi

    echo "  Registered Anycert Servers:"
    echo "  -----------------------------------"
    for i in "${!LINES[@]}"; do
        IP=$(echo "${LINES[$i]}" | awk '{print $1}')
        DNS=$(echo "${LINES[$i]}" | awk '{print $2}')
        echo "    [$((i+1))]  $IP  <>  $DNS"
    done
    echo "    [0]  Remove All"
    echo
    read -rp "  Please choose [1-$SITE_COUNT, 0=all]: " CHOICE

    if [[ "$CHOICE" == "0" ]]; then
        read -rp "  Are you sure you want to remove all $SITE_COUNT registered servers? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "  Cancelled."; exit 0; }
        for LINE in "${LINES[@]}"; do
            remove_one "$(echo "$LINE" | awk '{print $1}')" \
                       "$(echo "$LINE" | awk '{print $2}')" \
                       "$(echo "$LINE" | awk '{print $3}')"
        done
    else
        IDX=$((CHOICE-1))
        LINE="${LINES[$IDX]:-}"
        [[ -z "$LINE" ]] && { echo "  Invalid choice, cancelled."; exit 1; }
        read -rp "  Are you sure you want to proceed? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "  Cancelled."; exit 0; }
        remove_one "$(echo "$LINE" | awk '{print $1}')" \
                   "$(echo "$LINE" | awk '{print $2}')" \
                   "$(echo "$LINE" | awk '{print $3}')"
    fi

    echo
    echo "====================================================="
    echo "  Uninstallation Complete!"
    echo "====================================================="
    echo
    echo "  Please restart your browser to apply changes."
    echo "  Remember to run 'anycert.sh -u' on the server side to restore original settings if needed."
    echo
    exit 0
fi

# ============================================================
#  INSTALL MODE
# ============================================================

# ── Show existing sites ───────────────────────────────────────
HAS_SERVERS=0
if [[ -f "$INFO_FILE" && -s "$INFO_FILE" ]]; then
    HAS_SERVERS=1
fi

if [[ $HAS_SERVERS -eq 1 ]]; then
    echo "  Currently registered Anycert servers:"
    echo "  -----------------------------------"
    awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
    echo
    echo "Please select an action:"
    echo "  [1] Add/Import a new certificate (Default)"
    echo "  [2] Remove/Uninstall an existing certificate"
    echo "  [3] Exit"
    echo ""
    read -rp "  Please choose [1-3, default: 1]: " CLIENT_ACTION
    CLIENT_ACTION=${CLIENT_ACTION:-1}
    if [[ "$CLIENT_ACTION" == "2" ]]; then
        exec bash "$0" -u
    elif [[ "$CLIENT_ACTION" == "3" ]]; then
        exit 0
    fi
    echo ""
fi

# ── Step 1 ───────────────────────────────────────────────
echo "Please choose how to download/import the CA certificate:"
echo "  [1] Automatically download via SSH (Default)"
echo "  [2] Use a manually copied local CA certificate (Offline/Manual Mode)"
echo
read -rp "  Please choose [1-2, default: 1]: " IMPORT_MODE
IMPORT_MODE=${IMPORT_MODE:-1}

if [[ "$IMPORT_MODE" == "2" ]]; then
    echo
    echo "[Offline/Manual Mode] Please enter the path to the manually copied local CA certificate"
    echo "-----------------------------------------------------"
    read -rp "  CA Certificate Path [e.g. /tmp/anycert-ca.crt]: " OFFLINE_CA
    [[ -z "$OFFLINE_CA" ]] && { echo "[ERROR] File path cannot be empty."; exit 1; }
    [[ ! -f "$OFFLINE_CA" ]] && { echo "[ERROR] File not found: $OFFLINE_CA"; exit 1; }

    read -rp "  Enter Server IP Address [e.g. 192.168.1.100]: " SERVER_IP
    [[ -z "$SERVER_IP" ]] && { echo "[ERROR] IP Address cannot be empty."; exit 1; }

    read -rp "  Enter Server DNS Name (FQDN) [e.g. my-server.local]: " SERVER_DNS
    [[ -z "$SERVER_DNS" ]] && { echo "[ERROR] DNS Name cannot be empty."; exit 1; }

    CA_LOCAL="$DATA_DIR/anycert-ca-${SERVER_IP}.crt"
    cp "$OFFLINE_CA" "$CA_LOCAL"
    chmod 644 "$CA_LOCAL"

    CERT_FINGER_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2)
    CERT_FINGER_SHA1=$(openssl x509 -noout -fingerprint -sha1 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2 | tr -d ':')

    if [[ -f "$INFO_FILE" ]]; then
        grep -v "^$SERVER_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
        mv "$INFO_FILE.tmp" "$INFO_FILE"
    fi
    echo "$SERVER_IP $SERVER_DNS $CERT_FINGER_SHA1" >> "$INFO_FILE"

    IS_OFFLINE=true
else
    IS_OFFLINE=false
fi

if ! $IS_OFFLINE; then
echo "[Step 1/5] Input Server Information"
echo "-----------------------------------------------------"
echo
read -rp "  Server IP Address [e.g. 192.168.1.100]: " SERVER_IP
[[ -z "$SERVER_IP" ]] && { echo "[ERROR] IP Address cannot be empty."; exit 1; }

if [[ -f "$INFO_FILE" ]] && grep -q "^$SERVER_IP " "$INFO_FILE"; then
    echo "  [WARN] This IP has already been registered."
    echo
    read -rp "  Are you sure you want to overwrite and re-import? [y/N]: " REIMPORT
    [[ "$REIMPORT" =~ ^[Yy]$ ]] || { echo "  Cancelled."; exit 0; }
fi

read -rp "  SSH Username [default: root]: " SSH_USER
SSH_USER=${SSH_USER:-root}

read -rp "  Is the remote server running Windows Server? [Y/n]: " SERVER_OS
SERVER_OS=${SERVER_OS:-y}

echo
echo "  [Tip] You will be prompted to enter the SSH password shortly."
echo

# ── Step 2 ───────────────────────────────────────────────
echo "[Step 2/5] Download Server Root CA Certificate"
echo "-----------------------------------------------------"

CA_REMOTE="/etc/anycert/anycert-ca.crt"
CA_LOCAL="$DATA_DIR/anycert-ca-${SERVER_IP}.crt"

echo "  Source      : ${SSH_USER}@${SERVER_IP}:${CA_REMOTE}"
echo "  Destination : $CA_LOCAL"
echo

# Try probing download paths based on server OS
SMB_CONNECTED=false
SMB_PASS=""
if [[ "${SERVER_OS,,}" == "y" ]]; then
    # Windows server
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${SSH_USER}@${SERVER_IP}:C:/anycert/anycert-ca.crt" "$CA_LOCAL" 2>/dev/null; then
        echo "  [INFO] SCP download failed. Probing Windows SMB share [C$]..."
        
        read -srp "  Enter password for ${SSH_USER} to connect via SMB: " SMB_PASS
        echo ""
        
        local mount_dir="/tmp/anycert_smb_mount"
        mkdir -p "$mount_dir"
        
        # Mount and copy
        if mount_smbfs "//${SSH_USER}:${SMB_PASS}@${SERVER_IP}/c$" "$mount_dir" >/dev/null 2>&1; then
            if [[ -f "${mount_dir}/anycert/anycert-ca.crt" ]]; then
                cp "${mount_dir}/anycert/anycert-ca.crt" "$CA_LOCAL"
                echo "  [OK] CA certificate successfully copied via SMB Share!"
                SMB_CONNECTED=true
            fi
            umount "$mount_dir" >/dev/null 2>&1
        fi
        rmdir "$mount_dir" >/dev/null 2>&1

        if [[ "$SMB_CONNECTED" != "true" ]]; then
            echo
            echo "[ERROR] Certificate download failed! Please check:"
            echo "  1. Server IP address is correct: $SERVER_IP"
            echo "  2. SSH / SMB credentials are correct"
            echo "  3. The server-side anycert.bat has been executed to generate the certificate"
            echo "  4. Firewall allows SSH (Port 22) or SMB (Port 445)"
            exit 1
        fi
    fi
else
    # Linux server
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${SSH_USER}@${SERVER_IP}:${CA_REMOTE}" "$CA_LOCAL" 2>/dev/null; then
        echo "  [INFO] Linux default path failed. Probing backup path (/root/anycert/anycert-ca.crt)..."
        if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 "${SSH_USER}@${SERVER_IP}:/root/anycert/anycert-ca.crt" "$CA_LOCAL"; then
            echo
            echo "[ERROR] Certificate download failed! Please check:"
            echo "  1. Server IP address is correct: $SERVER_IP"
            echo "  2. SSH credentials are correct"
            echo "  3. The server-side anycert.sh has been executed to generate the certificate"
            echo "  4. Firewall allows SSH connections on Port 22"
            exit 1
        fi
    fi
fi

echo
echo "  [OK] Certificate downloaded successfully!"
echo

# Get fingerprint (SHA-1 for macOS keychain)
CERT_FINGER_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2)
CERT_FINGER_SHA1=$(openssl x509 -noout -fingerprint -sha1 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2 | tr -d ':')
echo "  [INFO] CA Certificate SHA-256 Fingerprint: $CERT_FINGER_SHA256"
echo

# ── Step 3 ───────────────────────────────────────────────
echo "[Step 3/5] Auto-detect Server FQDN"
echo "-----------------------------------------------------"
echo

# Probe FQDN based on server OS or SMB connection
SERVER_DNS=""
if [[ "$SMB_CONNECTED" == "true" ]]; then
    local mount_dir="/tmp/anycert_smb_mount"
    mkdir -p "$mount_dir"
    if mount_smbfs "//${SSH_USER}:${SMB_PASS}@${SERVER_IP}/c$" "$mount_dir" >/dev/null 2>&1; then
        if [[ -f "${mount_dir}/anycert/anycert.conf" ]]; then
            SERVER_DNS=$(grep "^SERVER_FQDN=" "${mount_dir}/anycert/anycert.conf" | cut -d= -f2- | tr -d '\r\n')
        fi
        umount "$mount_dir" >/dev/null 2>&1
    fi
    rmdir "$mount_dir" >/dev/null 2>&1
fi

if [[ -z "$SERVER_DNS" ]]; then
    if [[ "${SERVER_OS,,}" == "y" ]]; then
        SERVER_DNS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${SERVER_IP}" 'powershell -NoProfile -Command "[System.Net.Dns]::GetHostEntry(\"\").HostName"' 2>/dev/null || true)
    else
        SERVER_DNS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${SERVER_IP}" 'hostname -f' 2>/dev/null || true)
    fi
fi

# Clean up string
SERVER_DNS=$(echo "$SERVER_DNS" | tr -d '\r' | xargs)

if [[ -z "$SERVER_DNS" ]]; then
    echo "  [WARN] Auto-detect FQDN failed."
    read -rp "  Please manually enter Server DNS Name (FQDN) [e.g. my-server.local]: " SERVER_DNS
    [[ -z "$SERVER_DNS" ]] && { echo "[ERROR] DNS Name cannot be empty."; exit 1; }
fi

echo "  [OK] Detected server DNS name: $SERVER_DNS"
echo

# ── Save site info ────────────────────────────────────────────
if [[ -f "$INFO_FILE" ]]; then
    grep -v "^$SERVER_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
    mv "$INFO_FILE.tmp" "$INFO_FILE"
fi
echo "$SERVER_IP $SERVER_DNS $CERT_FINGER_SHA1" >> "$INFO_FILE"
fi

# ── Step 4 ───────────────────────────────────────────────
echo "[Step 4/5] Update /etc/hosts file"
echo "-----------------------------------------------------"

if grep -qi "$SERVER_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "  [WARN] Found existing $SERVER_DNS entry in hosts file:"
    grep -i "$SERVER_DNS" "$HOSTS_FILE"
    echo
    read -rp "  Do you want to overwrite this entry? [y/N]: " OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        sed -i '' "/# Anycert Server \[$SERVER_IP\]/d" "$HOSTS_FILE"
        sed -i '' "/^$SERVER_IP[[:space:]][[:space:]]*$SERVER_DNS/d" "$HOSTS_FILE"
        echo "  [OK] Old entry removed."
    else
        echo "  [SKIP] Kept existing entry unchanged."
    fi
fi

if ! grep -qi "$SERVER_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "" >> "$HOSTS_FILE"
    echo "# Anycert Server [$SERVER_IP] - Added by anycert-macos.sh" >> "$HOSTS_FILE"
    echo "$SERVER_IP    $SERVER_DNS" >> "$HOSTS_FILE"
    echo "  [OK] Hosts file updated: $SERVER_IP    $SERVER_DNS"
fi
echo

# ── Step 5 ───────────────────────────────────────────────
echo "[Step 5/5] Import CA Certificate to macOS System Keychain"
echo "-----------------------------------------------------"

if security add-trusted-cert -d -r trustRoot \
       -k /Library/Keychains/System.keychain \
       "$CA_LOCAL"; then
    echo "  [OK] CA certificate successfully imported and set to Always Trust!"
else
    echo "  [ERROR] Auto-import failed. Please install manually:"
    echo "  1. Double click $CA_LOCAL or open Keychain Access"
    echo "  2. Drag and drop the file into the System keychain"
    echo "  3. Double click the certificate, expand Trust, and set 'When using this certificate' to 'Always Trust'"
fi
echo

# ── Summary ──────────────────────────────────────────────
echo "====================================================="
echo "  Setup Complete!"
echo "====================================================="
echo
echo "  Server IP   : $SERVER_IP"
echo "  Server DNS  : $SERVER_DNS"
echo "  CA Fingerprint: $CERT_FINGER_SHA256"
echo "  CA Local Path : $CA_LOCAL"
echo
echo "  All Currently Registered Anycert Servers:"
echo "  -----------------------------------"
awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
echo
echo "  Please open in your browser: https://${SERVER_DNS}"
echo
echo "  To uninstall, run: sudo bash anycert-macos.sh -u"
echo

read -rp "  Open this page in browser now? [y/N]: " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Yy]$ ]]; then
    open "https://${SERVER_DNS}"
fi
