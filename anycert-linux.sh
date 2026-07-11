#!/usr/bin/env bash
# ============================================================
# anycert-linux.sh  —  Anycert Client Certificate Installer
# Usage:
#   sudo bash anycert-linux.sh       Install cert, update hosts
#   sudo bash anycert-linux.sh -u    Uninstall cert, remove hosts entry
# Tested on: Ubuntu 20.04+, Debian 11+
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

DISPLAY_NAME="anycert-linux.sh"
HOSTS_FILE="/etc/hosts"

echo
echo -e "${YELLOW} █████╗ ███╗   ██╗██╗   ██╗ ██████╗███████╗██████╗ ████████╗${RESET}"
echo -e "${YELLOW}██╔══██╗████╗  ██║╚██╗ ██╔╝██╔════╝██╔════╝██╔══██╗╚══██╔══╝${RESET}"
echo -e "${CYAN}███████║██╔██╗ ██║ ╚████╔╝ ██║     █████╗  ██████╔╝   ██║   ${RESET}"
echo -e "${CYAN}██╔══██║██║╚██╗██║  ╚██╔╝  ██║     ██╔══╝  ██╔══██╗   ██║   ${RESET}"
echo -e "${BLUE}██║  ██║██║ ╚████║   ██║   ╚██████╗███████╗██║  ██║   ██║   ${RESET}"
echo -e "${BLUE}╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝╚══════╝╚═╝  ╚═╝   ╚═╝   ${RESET}"
echo -e "${CYAN}                      anycert-linux.sh (Linux Client) ${RESET}"
echo

# ── Check root & Get Real User ──────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[INFO] This script requires root privileges."
    read -rp "  Would you like to re-run with sudo? [y/N]: " RUN_SUDO
    if [[ "$RUN_SUDO" =~ ^[Yy]$ ]]; then
        exec sudo bash "$0" "$@"
    fi
    echo "[ERROR] Root privileges are required to run this script."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
DATA_DIR="$REAL_HOME/.local/share/anycert"
INFO_FILE="$DATA_DIR/anycert-info.txt"

auto_install_cmd() {
    local CMD="$1"
    local PKG="$2"
    if command -v "$CMD" &>/dev/null; then
        return 0
    fi

    echo "  [INFO] Installing missing package: $PKG"

    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    elif command -v dnf &>/dev/null; then
        dnf install -y "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    elif command -v yum &>/dev/null; then
        yum install -y "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    elif command -v zypper &>/dev/null; then
        zypper --non-interactive install "$PKG" >/dev/null 2>&1 || {
            echo "[ERROR] Failed to install package: $PKG"
            exit 1
        }
    else
        echo "[ERROR] Unsupported package manager. Please manually install: $PKG"
        exit 1
    fi

    command -v "$CMD" &>/dev/null || {
        echo "[ERROR] Command not found after installation: $CMD"
        exit 1
    }
    echo "  [OK] Successfully installed: $PKG"
}

# ── Check / auto-install dependencies ────────────────────────
auto_install_cmd ssh openssh-client
auto_install_cmd scp openssh-client
auto_install_cmd openssl openssl
auto_install_cmd certutil libnss3-tools

mkdir -p "$DATA_DIR"
chown "$REAL_USER" "$DATA_DIR"

# ── Detect system trust store update tool ────────────────────
if command -v update-ca-certificates &>/dev/null; then
    CA_TOOL="update-ca-certificates"
    CA_TRUST_DIR="/usr/local/share/ca-certificates"
elif command -v update-ca-trust &>/dev/null; then
    CA_TOOL="update-ca-trust"
    CA_TRUST_DIR="/etc/pki/ca-trust/source/anchors"
else
    echo "[ERROR] Command update-ca-certificates or update-ca-trust not found."
    exit 1
fi

# ── NSS import into a single profile dir ──────────────────────
import_nss_profile() {
    local PROFILE_DIR="$1" CERT_FILE="$2" CERT_NICK="$3" LABEL="$4"
    if [[ ! -f "$PROFILE_DIR/cert9.db" ]]; then return 1; fi
    sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" -D -n "$CERT_NICK" >/dev/null 2>&1 || true
    local ERR_MSG
    if ERR_MSG=$(sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" \
            -A -t "CT,," -n "$CERT_NICK" -i "$CERT_FILE" 2>&1); then
        echo "  [OK] Imported to $LABEL: $(basename "$PROFILE_DIR")"
        return 0
    else
        echo "  [WARN] Failed to import to $LABEL: $(basename "$PROFILE_DIR")"
        echo "         Details: $ERR_MSG"
        return 1
    fi
}

# ── NSS import helper (Firefox / Chrome / Chromium) ──────────
import_nss() {
    local CERT_FILE="$1" CERT_NICK="$2"
    local IMPORTED=0

    # Chrome / Chromium (legacy path)
    local CHROME_DB="$REAL_HOME/.pki/nssdb"
    if [[ -d "$CHROME_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROME_DB" -D -n "$CERT_NICK" >/dev/null 2>&1 || true
        local ERR_MSG
        if ERR_MSG=$(sudo -u "$REAL_USER" certutil -d sql:"$CHROME_DB" \
                -A -t "CT,," -n "$CERT_NICK" -i "$CERT_FILE" 2>&1); then
            echo "  [OK] Imported to Chrome/Chromium NSS database (legacy)."
            IMPORTED=1
        else
            echo "  [WARN] Chrome NSS (legacy) import failed."
            echo "         Details: $ERR_MSG"
        fi
    fi

    # Chrome / Chromium (modern path - M146+)
    local CHROME_MODERN_DB="$REAL_HOME/.local/share/pki/nssdb"
    if [[ -d "$CHROME_MODERN_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROME_MODERN_DB" -D -n "$CERT_NICK" >/dev/null 2>&1 || true
        local ERR_MSG
        if ERR_MSG=$(sudo -u "$REAL_USER" certutil -d sql:"$CHROME_MODERN_DB" \
                -A -t "CT,," -n "$CERT_NICK" -i "$CERT_FILE" 2>&1); then
            echo "  [OK] Imported to Chrome/Chromium NSS database (modern)."
            IMPORTED=1
        else
            echo "  [WARN] Chrome NSS (modern) import failed."
            echo "         Details: $ERR_MSG"
        fi
    fi

    # Chrome / Chromium (snap path - Ubuntu 24.04/26.04)
    local CHROMIUM_SNAP_DB="$REAL_HOME/snap/chromium/current/.pki/nssdb"
    if [[ -d "$CHROMIUM_SNAP_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROMIUM_SNAP_DB" -D -n "$CERT_NICK" >/dev/null 2>&1 || true
        local ERR_MSG
        if ERR_MSG=$(sudo -u "$REAL_USER" certutil -d sql:"$CHROMIUM_SNAP_DB" \
                -A -t "CT,," -n "$CERT_NICK" -i "$CERT_FILE" 2>&1); then
            echo "  [OK] Imported to Chromium (snap) NSS database."
            IMPORTED=1
        else
            echo "  [WARN] Chromium (snap) NSS import failed."
            echo "         Details: $ERR_MSG"
        fi
    fi

    # Firefox (standard path)
    local FF_BASE="$REAL_HOME/.mozilla/firefox"
    if [[ -d "$FF_BASE" ]]; then
        for PROFILE_DIR in "$FF_BASE"/*/; do
            import_nss_profile "$PROFILE_DIR" "$CERT_FILE" "$CERT_NICK" "Firefox" && IMPORTED=1 || true
        done
    fi

    # Firefox (snap path - Ubuntu 22.04+)
    local FF_SNAP_BASE="$REAL_HOME/snap/firefox/common/.mozilla/firefox"
    if [[ -d "$FF_SNAP_BASE" ]]; then
        for PROFILE_DIR in "$FF_SNAP_BASE"/*/; do
            import_nss_profile "$PROFILE_DIR" "$CERT_FILE" "$CERT_NICK" "Firefox (snap)" && IMPORTED=1 || true
        done
    fi

    if [[ $IMPORTED -eq 0 ]]; then
        echo "  [INFO] No Chrome or Firefox profile directory found for user $REAL_USER ($REAL_HOME)"
        echo "  [INFO] Please start the browser at least once and run this script again."
    fi
}

# ── NSS remove helper ─────────────────────────────────────────
remove_nss() {
    local CERT_NICK="$1"

    # Chrome / Chromium (legacy path)
    local CHROME_DB="$REAL_HOME/.pki/nssdb"
    if [[ -d "$CHROME_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROME_DB" \
            -D -n "$CERT_NICK" >/dev/null 2>&1 && \
            echo "  [OK] Removed from Chrome/Chromium NSS database (legacy)." || true
    fi

    # Chrome / Chromium (modern path - M146+)
    local CHROME_MODERN_DB="$REAL_HOME/.local/share/pki/nssdb"
    if [[ -d "$CHROME_MODERN_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROME_MODERN_DB" \
            -D -n "$CERT_NICK" >/dev/null 2>&1 && \
            echo "  [OK] Removed from Chrome/Chromium NSS database (modern)." || true
    fi

    local CHROMIUM_SNAP_DB="$REAL_HOME/snap/chromium/current/.pki/nssdb"
    if [[ -d "$CHROMIUM_SNAP_DB" ]]; then
        sudo -u "$REAL_USER" certutil -d sql:"$CHROMIUM_SNAP_DB" \
            -D -n "$CERT_NICK" >/dev/null 2>&1 && \
            echo "  [OK] Removed from Chromium (snap) NSS database." || true
    fi

    local FF_BASE="$REAL_HOME/.mozilla/firefox"
    if [[ -d "$FF_BASE" ]]; then
        for PROFILE_DIR in "$FF_BASE"/*/; do
            if [[ -f "$PROFILE_DIR/cert9.db" ]]; then
                sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" \
                    -D -n "$CERT_NICK" >/dev/null 2>&1 && \
                    echo "  [OK] Removed from Firefox profile: $(basename "$PROFILE_DIR")" || true
            fi
        done
    fi

    local FF_SNAP_BASE="$REAL_HOME/snap/firefox/common/.mozilla/firefox"
    if [[ -d "$FF_SNAP_BASE" ]]; then
        for PROFILE_DIR in "$FF_SNAP_BASE"/*/; do
            if [[ -f "$PROFILE_DIR/cert9.db" ]]; then
                sudo -u "$REAL_USER" certutil -d sql:"$PROFILE_DIR" \
                    -D -n "$CERT_NICK" >/dev/null 2>&1 && \
                    echo "  [OK] Removed from Firefox (snap) profile: $(basename "$PROFILE_DIR")" || true
            fi
        done
    fi
}

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

        if grep -qi "$R_DNS" "$HOSTS_FILE" 2>/dev/null; then
            if [[ -n "$R_IP" ]]; then
                sed -i "/# Anycert Server \[$R_IP\]/d" "$HOSTS_FILE"
                sed -i "/^$R_IP[[:space:]]\+$R_DNS/d" "$HOSTS_FILE"
            else
                sed -i "/$R_DNS/d" "$HOSTS_FILE"
            fi
            echo "  [OK] Removed hosts entry: $R_DNS"
        else
            echo "  [SKIP] Hosts entry not found for: $R_DNS"
        fi

        if [[ -n "$R_IP" ]]; then
            local CERT_NAME="anycert-ca-${R_IP}.crt"
            if [[ -f "$CA_TRUST_DIR/$CERT_NAME" ]]; then
                rm -f "$CA_TRUST_DIR/$CERT_NAME"
                if [[ "$CA_TOOL" == "update-ca-trust" ]]; then
                    update-ca-trust extract
                else
                    update-ca-certificates
                fi
                echo "  [OK] CA certificate removed from system trust store."
            else
                echo "  [WARN] CA certificate not found in system trust store: $CA_TRUST_DIR/$CERT_NAME"
            fi

            remove_nss "anycert-ca-${R_IP}"

            [[ -f "$DATA_DIR/anycert-ca-${R_IP}.crt" ]] && rm -f "$DATA_DIR/anycert-ca-${R_IP}.crt" && echo "  [OK] Cached certificate file deleted."

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

    mapfile -t LINES < "$INFO_FILE"
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

    CERT_FINGER=$(openssl x509 -noout -fingerprint -sha256 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2)

    if [[ -f "$INFO_FILE" ]]; then
        grep -v "^$SERVER_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
        mv "$INFO_FILE.tmp" "$INFO_FILE"
    fi
    echo "$SERVER_IP $SERVER_DNS $CERT_FINGER" >> "$INFO_FILE"

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
if [[ "$SERVER_OS" == "y" || "$SERVER_OS" == "Y" ]]; then
    # Windows server
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}:/C:/anycert/anycert-ca.crt" "$CA_LOCAL" 2>/dev/null; then
        echo "  [INFO] SCP download failed. Probing Windows SMB share [C$]..."
        
        # Check/install smbclient on Linux client
        if ! command -v smbclient &>/dev/null; then
            echo "  [INFO] Installing smbclient for Windows share support..."
            if command -v apt-get &>/dev/null; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -y >/dev/null 2>&1 || true
                apt-get install -y smbclient >/dev/null 2>&1 || true
            elif command -v dnf &>/dev/null; then
                dnf install -y samba-client >/dev/null 2>&1 || true
            elif command -v yum &>/dev/null; then
                yum install -y samba-client >/dev/null 2>&1 || true
            fi
        fi

        if command -v smbclient &>/dev/null; then
            if [[ "$SSH_USER" != "administrator" && "$SSH_USER" != "Administrator" ]]; then
                echo -e "  ${YELLOW}[NOTE] Windows UAC blocks custom accounts (like '$SSH_USER') from accessing C$ admin share remotely.${RESET}"
                echo -e "         ${YELLOW}Please ensure OpenSSH is installed on the server, or use the built-in 'Administrator' account.${RESET}"
            fi
            read -srp "  Enter password for ${SSH_USER} to connect via SMB: " SMB_PASS
            echo ""
            export PASSWD="$SMB_PASS"
            if smbclient "//${SERVER_IP}/c$" -U "${SSH_USER}" -c "cd anycert; get anycert-ca.crt ${CA_LOCAL}" >/dev/null 2>&1; then
                echo "  [OK] CA certificate successfully copied via SMB Share!"
                SMB_CONNECTED=true
            fi
            unset PASSWD
        fi

        if [[ "$SMB_CONNECTED" != "true" ]]; then
            echo
            echo -e "  ${RED}[ERROR]${RESET} Certificate download failed! Please check:"
            echo -e "  ${YELLOW}1. The server-side anycert.bat has NOT been executed yet.${RESET}"
            echo "     (This is the most common reason! You must run the server script first to generate certificates.)"
            echo "  2. Server IP address is correct: $SERVER_IP"
            echo "  3. SSH / SMB credentials are correct"
            echo "  4. Firewall allows SSH (Port 22) or SMB (Port 445)"
            exit 1
        fi
    fi
else
    # Linux server
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}:${CA_REMOTE}" "$CA_LOCAL" 2>/dev/null; then
        echo "  [INFO] Linux default path failed. Probing backup path (/root/anycert/anycert-ca.crt)..."
        if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}:/root/anycert/anycert-ca.crt" "$CA_LOCAL"; then
            echo
            echo -e "  ${RED}[ERROR]${RESET} Certificate download failed! Please check:"
            echo -e "  ${YELLOW}1. The server-side anycert.sh has NOT been executed yet.${RESET}"
            echo "     (This is the most common reason! You must run the server script first to generate certificates.)"
            echo "  2. Server IP address is correct: $SERVER_IP"
            echo "  3. SSH credentials are correct"
            echo "  4. Firewall allows SSH connections on Port 22"
            exit 1
        fi
    fi
fi

echo
echo "  [OK] Certificate downloaded successfully!"
echo

CERT_FINGER=$(openssl x509 -noout -fingerprint -sha256 -in "$CA_LOCAL" 2>/dev/null | cut -d= -f2)
echo "  [INFO] CA Certificate SHA-256 Fingerprint: $CERT_FINGER"
echo

echo "[Step 3/5] Auto-detect Server FQDN"
echo "-----------------------------------------------------"
echo

# Temporarily disable set -e to prevent command substitution crash during FQDN probing
set +e

# Probe FQDN based on server OS or SMB connection
SERVER_DNS=""
if [[ "$SMB_CONNECTED" == "true" ]]; then
    # Grab anycert.conf via smbclient
    export PASSWD="$SMB_PASS"
    if smbclient "//${SERVER_IP}/c$" -U "${SSH_USER}" -c "cd anycert; get anycert.conf /tmp/anycert_conf.tmp" >/dev/null 2>&1; then
        SERVER_DNS=$(grep "^SERVER_FQDN=" /tmp/anycert_conf.tmp | cut -d= -f2- | tr -d '\r\n"')
        REMOTE_PROXY_PORTS=$(grep "^PROXY_PORTS=" /tmp/anycert_conf.tmp | cut -d= -f2- | tr -d '\r\n"')
        REMOTE_PORT_OFFSET=$(grep "^PORT_OFFSET=" /tmp/anycert_conf.tmp | cut -d= -f2- | tr -d '\r\n"')
        REMOTE_PROFILE=$(grep "^PROFILE=" /tmp/anycert_conf.tmp | cut -d= -f2- | tr -d '\r\n"')
        rm -f /tmp/anycert_conf.tmp
    fi
    unset PASSWD
fi

if [[ -z "$SERVER_DNS" ]]; then
    if [[ "$SERVER_OS" == "y" || "$SERVER_OS" == "Y" ]]; then
        REMOTE_CONF=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}" 'type C:\anycert\anycert.conf 2>nul || true' 2>/dev/null || true)
    else
        REMOTE_CONF=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}" 'cat /etc/anycert/anycert.conf 2>/dev/null || cat ~/anycert/anycert.conf 2>/dev/null || true' 2>/dev/null || true)
    fi
    if [[ -n "$REMOTE_CONF" ]]; then
        SERVER_DNS=$(echo "$REMOTE_CONF" | grep "^SERVER_FQDN=" | cut -d= -f2- | tr -d '\r\n"')
        REMOTE_PROXY_PORTS=$(echo "$REMOTE_CONF" | grep "^PROXY_PORTS=" | cut -d= -f2- | tr -d '\r\n"')
        REMOTE_PORT_OFFSET=$(echo "$REMOTE_CONF" | grep "^PORT_OFFSET=" | cut -d= -f2- | tr -d '\r\n"')
        REMOTE_PROFILE=$(echo "$REMOTE_CONF" | grep "^PROFILE=" | cut -d= -f2- | tr -d '\r\n"')
    fi
    if [[ -z "$SERVER_DNS" ]]; then
        if [[ "$SERVER_OS" == "y" || "$SERVER_OS" == "Y" ]]; then
            comp_name=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}" 'echo %COMPUTERNAME% || true' 2>/dev/null | tr -d '\r\n' | xargs)
            SERVER_DNS="${comp_name}"
        else
            SERVER_DNS=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${SERVER_IP}" 'hostname -f || hostname || true' 2>/dev/null | tr -d '\r\n' | xargs)
        fi
    fi
fi

# Clean up string
SERVER_DNS=$(echo "$SERVER_DNS" | tr -d '\r' | xargs)

if [[ -z "$SERVER_DNS" ]]; then
    echo -e "  ${YELLOW}[WARN] Auto-detect FQDN failed.${RESET}"
    echo -e "         ${YELLOW}(If connecting via non-root SSH user, please check if /etc/anycert/anycert.conf is readable [chmod 644] on the server)${RESET}"
    read -rp "  Please manually enter Server DNS Name (FQDN) [e.g. my-server.local]: " SERVER_DNS
    [[ -z "$SERVER_DNS" ]] && { echo -e "${RED}[ERROR]${RESET} DNS Name cannot be empty."; exit 1; }
fi

echo "  [OK] Detected server DNS name: $SERVER_DNS"
echo

if [[ -f "$INFO_FILE" ]]; then
    grep -v "^$SERVER_IP " "$INFO_FILE" > "$INFO_FILE.tmp" || true
    mv "$INFO_FILE.tmp" "$INFO_FILE"
fi
echo "$SERVER_IP $SERVER_DNS $CERT_FINGER" >> "$INFO_FILE"
fi

# Re-enable set -e for subsequent steps
set -e

echo "[Step 4/5] Update /etc/hosts file"
echo "-----------------------------------------------------"

if grep -qi "$SERVER_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "  [WARN] Found existing $SERVER_DNS entry in hosts file:"
    grep -i "$SERVER_DNS" "$HOSTS_FILE"
    echo
    read -rp "  Do you want to overwrite this entry? [y/N]: " OVERWRITE
    if [[ "$OVERWRITE" =~ ^[Yy]$ ]]; then
        sed -i "/# Anycert Server \[$SERVER_IP\]/d" "$HOSTS_FILE"
        sed -i "/^$SERVER_IP[[:space:]]\+$SERVER_DNS/d" "$HOSTS_FILE"
        echo "  [OK] Old entry removed."
    else
        echo "  [SKIP] Kept existing entry unchanged."
    fi
fi

if ! grep -qi "$SERVER_DNS" "$HOSTS_FILE" 2>/dev/null; then
    echo "" >> "$HOSTS_FILE"
    echo "# Anycert Server [$SERVER_IP] - Added by anycert-linux.sh" >> "$HOSTS_FILE"
    echo "$SERVER_IP    $SERVER_DNS" >> "$HOSTS_FILE"
    echo "  [OK] Hosts file updated: $SERVER_IP    $SERVER_DNS"
fi
echo

echo "[Step 5/5] Import CA Certificate to System Trust Store"
echo "-----------------------------------------------------"

CERT_DEST="$CA_TRUST_DIR/anycert-ca-${SERVER_IP}.crt"
cp "$CA_LOCAL" "$CERT_DEST"
if [[ "$CA_TOOL" == "update-ca-trust" ]]; then
    update-ca-trust extract
else
    update-ca-certificates
fi
echo "  [OK] System trust store updated."
echo

echo "  Importing to Chrome / Firefox browser database..."
import_nss "$CA_LOCAL" "anycert-ca-${SERVER_IP}"
echo

echo "====================================================="
echo "  Setup Complete!"
echo "====================================================="
echo
printf "  %-17s : %s\n" "Server IP" "$SERVER_IP"
printf "  %-17s : %s\n" "Server DNS" "$SERVER_DNS"
printf "  %-17s : %s\n" "CA Fingerprint" "$CERT_FINGER"
printf "  %-17s : %s\n" "CA Local Path" "$CA_LOCAL"
CA_FROM=$(openssl x509 -in "$CA_LOCAL" -noout -startdate 2>/dev/null | cut -d= -f2)
CA_UNTIL=$(openssl x509 -in "$CA_LOCAL" -noout -enddate 2>/dev/null | cut -d= -f2)
printf "  %-17s : %s\n" "CA Validity From" "$CA_FROM"
printf "  %-17s : %s\n" "CA Validity Until" "$CA_UNTIL"
echo
echo "  All Currently Registered Anycert Servers:"
echo "  -----------------------------------"
    awk '{print "    " $1 "  <>  " $2}' "$INFO_FILE"
echo
echo "  Available HTTPS connections (you can open any in browser):"
if [[ "${REMOTE_PROFILE:-}" == "pve" ]]; then
    echo "    https://${SERVER_DNS}:8006"
    echo "    https://${SERVER_IP}:8006"
elif [[ -n "${REMOTE_PROXY_PORTS:-}" ]]; then
    PORT_OFFSET_VAL="${REMOTE_PORT_OFFSET:-10000}"
    for P in $REMOTE_PROXY_PORTS; do
        SSL_P=$((P + PORT_OFFSET_VAL))
        [[ $SSL_P -gt 65535 ]] && SSL_P=$((P - PORT_OFFSET_VAL))
        echo "    https://${SERVER_DNS}:${SSL_P}   (via FQDN)"
        echo "    https://${SERVER_IP}:${SSL_P}   (via IP, use this if app blocks hostname)"
        echo "      ->  http://localhost:${P}"
        echo
    done
else
    echo "    https://${SERVER_DNS}"
    echo "    https://${SERVER_IP}"
    echo "    (Run anycert.sh/bat on the server to configure Nginx SSL proxy ports)"
fi
echo -e "  ${YELLOW}[NOTE] If Chrome still shows 'Not Secure' after installation:${RESET}"
echo -e "         1. Fully restart Chrome (visit ${CYAN}chrome://restart${RESET} in URL bar)."
echo -e "         2. Ensure you have **regenerated the Root CA** on the server (select Y to"
echo -e "            'Regenerate CA' when running anycert.sh/bat) to apply modern CA:true constraints."
echo
echo "  To uninstall, run: sudo bash anycert-linux.sh -u"
echo
