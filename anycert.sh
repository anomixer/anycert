#!/usr/bin/env bash
# =============================================================
# anycert.sh — Self-Hosted Server HTTPS Certificate Generator
# Usage:
#   bash anycert.sh        Install local certificate
#   bash anycert.sh -u     Uninstall / restore original cert
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

CONF_DIR="/etc/anycert"
CONF_FILE="${CONF_DIR}/anycert.conf"
CA_KEY="${CONF_DIR}/anycert-ca.key"
CA_CRT="${CONF_DIR}/anycert-ca.crt"
CA_SRL="${CONF_DIR}/anycert-ca.srl"
SERVER_KEY="${CONF_DIR}/anycert-server.key"
SERVER_CRT="${CONF_DIR}/anycert-server.crt"

PORT_OFFSET=10000

banner() {
  echo -e "${YELLOW} █████╗ ███╗   ██╗██╗   ██╗ ██████╗███████╗██████╗ ████████╗${RESET}"
  echo -e "${YELLOW}██╔══██╗████╗  ██║╚██╗ ██╔╝██╔════╝██╔════╝██╔══██╗╚══██╔══╝${RESET}"
  echo -e "${CYAN}███████║██╔██╗ ██║ ╚████╔╝ ██║     █████╗  ██████╔╝   ██║   ${RESET}"
  echo -e "${CYAN}██╔══██║██║╚██╗██║  ╚██╔╝  ██║     ██╔══╝  ██╔══██╗   ██║   ${RESET}"
  echo -e "${BLUE}██║  ██║██║ ╚████║   ██║   ╚██████╗███████╗██║  ██║   ██║   ${RESET}"
  echo -e "${BLUE}╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝╚══════╝╚═╝  ╚═╝   ╚═╝   ${RESET}"
  echo -e "${CYAN}                       anycert.sh (Server) ${RESET}"
  echo ""
  echo "  Purpose:"
  echo "    Automatically detects the local IP and FQDN, generates a"
  echo "    10-year self-signed Root CA and server certificate, and"
  echo "    installs it into the selected self-hosted service (e.g. PVE, Nginx)."
  echo "    Lets browsers connect securely over the LAN with a trusted lock icon."
  echo ""
  echo "  Usage:"
  echo "    bash anycert.sh        # Install certificate"
  echo "    bash anycert.sh -u     # Uninstall and restore backups"
  echo ""
}

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    warn "This script requires root privileges."
    read -rp "Would you like to re-run with sudo? [y/N]: " RUN_SUDO
    if [[ "$RUN_SUDO" =~ ^[Yy]$ ]]; then
      exec sudo bash "$0" "$@"
    else
      die "Root privileges are required to run this script."
    fi
  fi
}

detect_os() {
  OS_TYPE=$(uname -s)
  if [[ "$OS_TYPE" == "Linux" ]]; then
    IS_LINUX=true
    IS_MAC=false
  elif [[ "$OS_TYPE" == "Darwin" ]]; then
    IS_LINUX=false
    IS_MAC=true
  else
    die "Unsupported operating system: $OS_TYPE"
  fi
}

check_deps() {
  local deps=("openssl" "hostname")
  if $IS_LINUX; then
    deps+=("ip")
  elif $IS_MAC; then
    deps+=("ifconfig")
  fi
  for cmd in "${deps[@]}"; do
    command -v "$cmd" &>/dev/null || die "Required system tool not found: $cmd"
  done
}

# ── Uninstall ──────────────────────────────────────────────
do_uninstall() {
  echo -e "${BOLD}Uninstall Mode - Restoring Original Certificate Settings${RESET}"
  echo ""

  if [[ ! -f "$CONF_FILE" ]]; then
    warn "Configuration file $CONF_FILE not found. Only cleaning up default certificate files."
    PROFILE="none"
  else
    # Load existing config
    # shellcheck source=/dev/null
    source "$CONF_FILE"
  fi

  echo -e "${BOLD}[ Files to be removed ]${RESET}"
  echo "  ${CA_KEY}"
  echo "  ${CA_CRT}"
  echo "  ${SERVER_KEY}"
  echo "  ${SERVER_CRT}"
  echo "  ${CA_SRL}"
  echo "  ${CONF_FILE}"
  echo ""

  # Profile-specific cleanup
  if [[ "${PROFILE:-none}" == "pve" ]]; then
    PVE_SSL_DIR="/etc/pve/local"
    BACKUP_PEM=$(ls -t "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak."* 2>/dev/null | head -1 || true)
    BACKUP_KEY=$(ls -t "${PVE_SSL_DIR}/pveproxy-ssl.key.bak."* 2>/dev/null | head -1 || true)

    if [[ -n "$BACKUP_PEM" ]]; then
      echo -e "${BOLD}[ PVE Backup Detected - Will Restore ]${RESET}"
      echo "  $BACKUP_PEM"
      echo "  $BACKUP_KEY"
    else
      echo -e "${YELLOW}[ PVE Backup Not Detected - Will Delete Certificates Directly ]${RESET}"
    fi
  elif [[ "${PROFILE:-none}" == "custom" ]]; then
    if [[ -n "${CUSTOM_CERT:-}" && -f "${CUSTOM_CERT}" ]]; then
      BACKUP_CERT=$(ls -t "${CUSTOM_CERT}.bak."* 2>/dev/null | head -1 || true)
      BACKUP_KEY=$(ls -t "${CUSTOM_KEY}.bak."* 2>/dev/null | head -1 || true)
      if [[ -n "$BACKUP_CERT" ]]; then
        echo -e "${BOLD}[ Custom Path Backup Detected - Will Restore ]${RESET}"
        echo "  $BACKUP_CERT"
        echo "  $BACKUP_KEY"
      else
        echo -e "${YELLOW}[ Backup Not Detected - Will Delete Custom Certificates Directly ]${RESET}"
      fi
    fi
  fi

  echo ""
  read -rp "$(echo -e "${YELLOW}Are you sure you want to uninstall? [y/N]${RESET} ")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }

  # Restore
  if [[ "${PROFILE:-none}" == "pve" ]]; then
    if [[ -n "$BACKUP_PEM" && -f "$BACKUP_PEM" ]]; then
      cp "$BACKUP_PEM" "${PVE_SSL_DIR}/pveproxy-ssl.pem"
      ok "Restored PVE certificate: ${PVE_SSL_DIR}/pveproxy-ssl.pem"
    else
      rm -f "${PVE_SSL_DIR}/pveproxy-ssl.pem"
    fi
    if [[ -n "$BACKUP_KEY" && -f "$BACKUP_KEY" ]]; then
      cp "$BACKUP_KEY" "${PVE_SSL_DIR}/pveproxy-ssl.key"
      ok "Restored PVE key: ${PVE_SSL_DIR}/pveproxy-ssl.key"
    else
      rm -f "${PVE_SSL_DIR}/pveproxy-ssl.key"
    fi
    # Delete backup files
    rm -f "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak."* 2>/dev/null || true
    rm -f "${PVE_SSL_DIR}/pveproxy-ssl.key.bak."* 2>/dev/null || true
    info "Restarting PVE proxy service..."
    systemctl restart pveproxy pvedaemon || true
  elif [[ "${PROFILE:-none}" == "custom" ]]; then
    if [[ -n "${CUSTOM_CERT:-}" ]]; then
      if [[ -n "${BACKUP_CERT:-}" && -f "$BACKUP_CERT" ]]; then
        cp "$BACKUP_CERT" "$CUSTOM_CERT"
        ok "Restored certificate: $CUSTOM_CERT"
      else
        rm -f "$CUSTOM_CERT"
      fi
      rm -f "${CUSTOM_CERT}.bak."* 2>/dev/null || true
    fi
    if [[ -n "${CUSTOM_KEY:-}" ]]; then
      if [[ -n "${BACKUP_KEY:-}" && -f "$BACKUP_KEY" ]]; then
        cp "$BACKUP_KEY" "$CUSTOM_KEY"
        ok "Restored private key: $CUSTOM_KEY"
      else
        rm -f "$CUSTOM_KEY"
      fi
      rm -f "${CUSTOM_KEY}.bak."* 2>/dev/null || true
    fi
    if [[ -n "${RELOAD_CMD:-}" ]]; then
      info "Running reload command: $RELOAD_CMD"
      eval "$RELOAD_CMD" || true
    fi
  elif [[ "${PROFILE:-none}" == "nginx_proxy" ]]; then
    local NGINX_CONF="/etc/nginx/conf.d/anycert_proxy.conf"
    if [[ -f "$NGINX_CONF" ]]; then
      info "Removing Nginx proxy configuration file..."
      rm -f "$NGINX_CONF"
      ok "Nginx proxy configuration file removed."
      
      if systemctl is-active --quiet nginx 2>/dev/null; then
        info "Reloading Nginx daemon..."
        systemctl reload nginx || true
        ok "Nginx reloaded."
      fi
    fi
  fi

  # Clean up anycert files
  rm -f "$CA_KEY" "$CA_CRT" "$SERVER_KEY" "$SERVER_CRT" "$CA_SRL" "$CONF_FILE" || true
  if [[ -d "$CONF_DIR" ]]; then
    rmdir "$CONF_DIR" 2>/dev/null || true
  fi

  echo ""
  ok "Uninstallation complete."
  echo "On client machines, run anycert-*.sh -u or anycert-windows.bat -u to clean up the CA certificate."
  echo ""
}

# ── Install ──────────────────────────────────────────────────
detect_server_info() {
  info "Auto-detecting network configurations..."

  if $IS_LINUX; then
    SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')
  else
    # macOS
    SERVER_IP=$(ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')" 2>/dev/null || true)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1 || true)
  fi

  SERVER_HOSTNAME=$(hostname -s)
  SERVER_FQDN=$(hostname -f 2>/dev/null || echo "${SERVER_HOSTNAME}.local")
  [[ "$SERVER_FQDN" == "$SERVER_HOSTNAME" || "$SERVER_FQDN" == "localhost" ]] && SERVER_FQDN="${SERVER_HOSTNAME}.local"

  echo ""
  echo -e "  Auto-detection results:"
  echo -e "  ${BOLD}Server IP Address:${RESET} ${GREEN}${SERVER_IP}${RESET}"
  echo -e "  ${BOLD}Hostname:${RESET}          ${GREEN}${SERVER_HOSTNAME}${RESET}"
  echo -e "  ${BOLD}Default FQDN (DNS):${RESET} ${GREEN}${SERVER_FQDN}${RESET}"
  echo ""
}

confirm_info() {
  echo -e "${YELLOW}Please confirm or modify the detected information:${RESET}"

  read -rp "  Server IP Address [${SERVER_IP}]: " INPUT_IP
  [[ -n "$INPUT_IP" ]] && SERVER_IP="$INPUT_IP"
  echo "  (Tip: enter multiple IPs separated by spaces, e.g. 192.168.1.10 100.64.1.2)"

  read -rp "  Additional IP Addresses (optional, space-separated, e.g. Tailscale/VPN IPs): " EXTRA_IPS

  read -rp "  Server DNS Name (FQDN) [${SERVER_FQDN}]: " INPUT_FQDN
  [[ -n "$INPUT_FQDN" ]] && SERVER_FQDN="$INPUT_FQDN"

  echo ""
}

detect_listening_ports() {
  echo -e "  Scanning local ports, please wait..." >&2
  local ports=""
  if command -v ss &>/dev/null; then
    ports=$(ss -tln | awk 'NR>1 {print $4}' | awk -F: '{print $NF}' 2>/dev/null)
  elif command -v netstat &>/dev/null; then
    ports=$(netstat -an | grep -i listen | awk '{print $4}' | awk -F. '{print $NF}' 2>/dev/null)
  elif command -v lsof &>/dev/null; then
    ports=$(lsof -iTCP -sTCP:LISTEN -P -n | awk 'NR>1 {split($9, a, ":"); print a[length(a)]}' 2>/dev/null)
  fi
  
  local filtered=""
  for p in $ports; do
    if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -gt 80 && "$p" -ne 135 && "$p" -ne 445 && "$p" -ne 5357 && "$p" -ne 111 ]]; then
      local http_code
      http_code=$(curl -s -w "%{http_code}" -o /dev/null --connect-timeout 0.2 --max-time 0.5 "http://127.0.0.1:${p}" 2>/dev/null || echo "000")
      if [[ "$http_code" != "000" && -n "$http_code" ]]; then
        filtered="$filtered $p"
      fi
    fi
  done
  if [[ -n "$filtered" ]]; then
    echo "$filtered" | tr ' ' '\n' | sort -n -u | xargs
  fi
}

# Resolve the HTTPS (SSL) port for a given HTTP port using the global PORT_OFFSET.
# Considers COLLISION with the original HTTP ports and previously assigned SSL ports,
# appending the result into the global ASSIGNED_SSL_PORTS array.
resolve_ssl_port() {
  local P="$1"
  local SSL_P=$((P + PORT_OFFSET))
  if [[ $SSL_P -gt 65535 ]]; then
    SSL_P=$((P - PORT_OFFSET))
  fi

  while true; do
    local collided=0
    for OP in ${PROXY_PORTS}; do
      if [[ $SSL_P -eq $OP ]]; then collided=1; break; fi
    done
    if [[ $collided -eq 0 ]]; then
      local i
      for ((i = 0; i < ${#ASSIGNED_SSL_PORTS[@]}; i++)); do
        if [[ $SSL_P -eq ${ASSIGNED_SSL_PORTS[$i]} ]]; then collided=1; break; fi
      done
    fi

    if [[ $collided -eq 1 ]]; then
      SSL_P=$((SSL_P + 1))
      if [[ $SSL_P -gt 65535 ]]; then
        SSL_P=$PORT_OFFSET
      fi
    else
      break
    fi
  done

  ASSIGNED_SSL_PORTS+=("$SSL_P")
  echo "$SSL_P"
}

choose_profile() {
  echo -e "${BOLD}Please choose the Service Profile to apply:${RESET}"
  
  local opts=()
  local desc=()

  opts+=("nginx_proxy")
  desc+=("Auto-Setup Nginx SSL Proxy (Port-Offset Wrapper) [Lazy-Friendly / Recommended]\n      - Installs Nginx and automatically wraps your HTTP ports in SSL\n      - Keeps your existing apps running on HTTP, proxies to SSL Port + ${PORT_OFFSET} (configurable)\n")
  opts+=("custom")
  desc+=("Custom Path (Auto-Deploy)\n      - Copies certificates to your service folders (e.g. Nginx, Apache, Home Assistant, OpenMediaVault, Unraid, Docker, etc.)\n      - Can automatically run a reload command to apply changes\n")
  opts+=("none")
  desc+=("Generate Only (Manual Deploy) [Painful / Hard Way]\n      - Generates cert files in ${CONF_DIR}/ only\n      - Requires manual configuration for all your services\n")

  local default_choice="1"
  if $IS_LINUX && [[ -d "/etc/pve" ]]; then
    opts+=("pve")
    desc+=("Proxmox VE (PVE Proxy)\n      - Automatically replaces PVE's web proxy certificate\n      - Restarts pveproxy to apply immediately\n")
    default_choice="4"
  fi

  for i in "${!opts[@]}"; do
    echo -e "  [$((i+1))] ${desc[$i]}"
  done
  echo ""

  local choice=""
  while true; do
    read -rp "  Please choose [1-${#opts[@]}, default: ${default_choice}]: " raw_choice
    raw_choice=${raw_choice:-${default_choice}}
    if [[ "$raw_choice" =~ ^[0-9]+$ ]] && [ "$raw_choice" -ge 1 ] && [ "$raw_choice" -le "${#opts[@]}" ]; then
      choice="${opts[$((raw_choice-1))]}"
      break
    fi
    warn "Invalid choice, please try again."
  done

  PROFILE="$choice"
  echo ""

  if [[ "$PROFILE" == "custom" ]]; then
    echo -e "${YELLOW}Custom Path Settings:${RESET}"
    read -rp "  1. Target Certificate Path (CRT/PEM) [e.g. /etc/nginx/ssl/nginx.crt]: " CUSTOM_CERT
    while [[ -z "$CUSTOM_CERT" ]]; do
      warn "Certificate path cannot be empty!"
      read -rp "  1. Target Certificate Path (CRT/PEM): " CUSTOM_CERT
    done

    read -rp "  2. Target Private Key Path (KEY) [e.g. /etc/nginx/ssl/nginx.key]: " CUSTOM_KEY
    while [[ -z "$CUSTOM_KEY" ]]; do
      warn "Private key path cannot be empty!"
      read -rp "  2. Target Private Key Path (KEY): " CUSTOM_KEY
    done

    read -rp "  3. Service reload/restart command (optional) [e.g. systemctl reload nginx]: " RELOAD_CMD
    echo ""
  fi

  if [[ "$PROFILE" == "nginx_proxy" ]]; then
    echo -e "${YELLOW}Automated Nginx SSL Proxy Settings:${RESET}"

    local DETECTED_PORTS
    DETECTED_PORTS=$(detect_listening_ports)
    
    local EXISTING_PORTS=""
    if [[ -f "$CONF_FILE" ]]; then
      # Load existing PROXY_PORTS from config file
      EXISTING_PORTS=$(grep '^PROXY_PORTS=' "$CONF_FILE" | cut -d= -f2- | tr -d '"')
    fi
    
    if [[ -n "$EXISTING_PORTS" ]]; then
      echo "  You already have these HTTP ports mapped:"
      echo "    $EXISTING_PORTS"
      echo ""
      echo "  What do you want to do?"
      echo "    [1] Keep them as-is (Default)"
      echo "    [2] Add more ports"
      echo "    [3] Remove some ports"
      echo "    [4] Start over with a new list"
      echo ""
      
      local port_opt=""
      while true; do
        read -rp "  Please choose [1-4, default: 1]: " port_opt
        port_opt=${port_opt:-1}
        if [[ "$port_opt" =~ ^[1-4]$ ]]; then
          break
        fi
        warn "Invalid choice, please try again."
      done
      
      if [[ "$port_opt" == "1" ]]; then
        PROXY_PORTS="$EXISTING_PORTS"
      elif [[ "$port_opt" == "2" ]]; then
        if [[ -n "$DETECTED_PORTS" ]]; then
          echo -e "  [TIP] I found these ports listening on your machine: ${GREEN}${DETECTED_PORTS}${RESET}"
        fi
        echo -e "  I will add HTTPS access to each port you give me, on port (that port + ${PORT_OFFSET})."
        echo -e "  For example: port 3000 will get a HTTPS wrapper on port $((3000 + PORT_OFFSET))."
        echo -e "  (If a port is too large, I subtract ${PORT_OFFSET} instead, e.g. 60000 -> $((60000 - PORT_OFFSET)).)"
        read -rp "  Which extra ports do you want to expose via HTTPS? (space-separated): " NEW_PORTS
        # Deduplicate and merge
        PROXY_PORTS=$(echo "$EXISTING_PORTS $NEW_PORTS" | tr ' ' '\n' | awk 'NF && !seen[$1]++' | tr '\n' ' ' | xargs)
      elif [[ "$port_opt" == "3" ]]; then
        read -rp "  Enter HTTP ports to remove (space-separated): " REMOVE_PORTS
        # Filter out removed ports
        PROXY_PORTS=$(echo "$EXISTING_PORTS" | tr ' ' '\n' | awk -v rem="$REMOVE_PORTS" 'BEGIN{split(rem,a," ")} {ok=1; for(i in a) if(a[i]==$1) ok=0; if(ok) print $1}' | tr '\n' ' ' | xargs)
      elif [[ "$port_opt" == "4" ]]; then
        if [[ -n "$DETECTED_PORTS" ]]; then
          echo -e "  [TIP] I found these ports listening on your machine: ${GREEN}${DETECTED_PORTS}${RESET}"
        fi
        echo -e "  I will add HTTPS access to each port you give me, on port (that port + ${PORT_OFFSET})."
        echo -e "  For example: port 3000 will get a HTTPS wrapper on port $((3000 + PORT_OFFSET))."
        echo -e "  (If a port is too large, I subtract ${PORT_OFFSET} instead, e.g. 60000 -> $((60000 - PORT_OFFSET)).)"
        read -rp "  What ports do you want to expose via HTTPS? (space-separated): " NEW_LIST
        PROXY_PORTS="$NEW_LIST"
      fi
    else
      if [[ -n "$DETECTED_PORTS" ]]; then
        echo -e "  [TIP] I found these ports listening on your machine: ${GREEN}${DETECTED_PORTS}${RESET}"
      fi
      echo -e "  Tell me which of your local services should be accessible via HTTPS."
      echo -e "  I will add a secure HTTPS wrapper on port (your_port + ${PORT_OFFSET})."
      echo -e "  For example: if you have a service on port 3000, I will make it available"
      echo -e "  on https://localhost:$((3000 + PORT_OFFSET)) (3000 + ${PORT_OFFSET})."
      echo -e "  (For high ports >= $((65536 - PORT_OFFSET)) I subtract ${PORT_OFFSET} instead.)"
      echo -e "  Type the ports separated by spaces, like: 3000 6000 11434"
      read -rp "  Which local HTTP services should get HTTPS access? (space-separated): " PROXY_PORTS
    fi
    
    while [[ -z "$PROXY_PORTS" ]]; do
      warn "You must specify at least one port for proxying!"
      read -rp "  Enter HTTP ports you want to make them HTTPS secure connection: " PROXY_PORTS
    done
    sanitize_proxyports

    echo -e "  ${CYAN}HTTPS (SSL) port offset${RESET}"
    echo -e "    The HTTPS port for each service = HTTP port + offset."
    echo -e "    Default is ${PORT_OFFSET} (e.g. 3000 -> $((3000 + PORT_OFFSET)))."
    echo -e "    You may enter a custom offset (e.g. 1, 10, 443) or leave blank for default."
    while true; do
      read -rp "  Enter HTTPS port offset [default: ${PORT_OFFSET}]: " INPUT_OFFSET
      INPUT_OFFSET=${INPUT_OFFSET:-$PORT_OFFSET}
      if [[ "$INPUT_OFFSET" =~ ^[0-9]+$ ]] && [ "$INPUT_OFFSET" -ge 1 ] && [ "$INPUT_OFFSET" -le 65535 ]; then
        PORT_OFFSET=$INPUT_OFFSET
        break
      fi
      warn "Invalid offset, please enter a number between 1 and 65535."
    done
    echo ""
  fi
}

ask_proceed() {
  echo -e "${BOLD}The following actions will be performed:${RESET}"
  echo "  1. Create a 10-year local Root CA certificate (${CA_CRT})"
  echo "  2. Issue a 825-day server certificate (${SERVER_CRT}) with SAN:"
  echo "     DNS: ${SERVER_FQDN}"
  echo "     IP : ${SERVER_IP}"
  
  if [[ "$PROFILE" == "pve" ]]; then
    echo "  3. Install certificates to PVE directory (/etc/pve/local/)"
    echo "  4. Restart PVE proxy services (pveproxy / pvedaemon)"
  elif [[ "$PROFILE" == "nginx_proxy" ]]; then
    echo "  3. Install Nginx if missing, and configure it as an SSL wrapper for ports:"
    echo "     ${PROXY_PORTS} (SSL ports: Original + ${PORT_OFFSET})"
    echo "  4. Start or reload Nginx to apply changes"
  elif [[ "$PROFILE" == "custom" ]]; then
    echo "  3. Copy certificates to custom paths:"
    echo "     CRT -> ${CUSTOM_CERT}"
    echo "     KEY -> ${CUSTOM_KEY}"
    if [[ -n "${RELOAD_CMD:-}" ]]; then
      echo "  4. Run reload command: ${RELOAD_CMD}"
    fi
  else
    echo "  3. Store files in ${CONF_DIR}/ only, without applying to any service"
  fi
  echo ""
  read -rp "$(echo -e "${YELLOW}Do you want to proceed? [y/N]${RESET} ")" CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Cancelled by user."; exit 0; }
}

generate_ca() {
  mkdir -p "$CONF_DIR"
  chmod 755 "$CONF_DIR"

  if [[ -f "$CA_CRT" ]]; then
    warn "CA certificate already exists: $CA_CRT"
    read -rp "$(echo -e "${YELLOW}Regenerate CA? (N to reuse existing CA, recommended: N) [y/N]${RESET} ")" REGEN_CA
    if [[ ! "$REGEN_CA" =~ ^[Yy]$ ]]; then
      ok "Reusing existing CA certificate."
      return
    fi
  fi

  info "Generating Root CA..."
  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -out "$CA_CRT" \
    -subj "/C=US/O=AnycertLocalCA/CN=Anycert Local Root CA (${SERVER_HOSTNAME})" \
    2>/dev/null
  chmod 600 "$CA_KEY"
  chmod 644 "$CA_CRT"
  ok "Root CA created successfully: $CA_CRT"
}

generate_server_cert() {
  info "Issuing server certificate (with SAN)..."

  openssl genrsa -out "$SERVER_KEY" 2048 2>/dev/null
  
  local csr_temp
  csr_temp=$(mktemp)
  openssl req -new -key "$SERVER_KEY" \
    -out "$csr_temp" \
    -subj "/CN=${SERVER_FQDN}" \
    2>/dev/null

  # Build SAN IP entries: primary IP + extra IPs (Tailscale, VPN, etc.)
  local SAN_IPS="IP:${SERVER_IP},IP:127.0.0.1"
  for EIP in ${EXTRA_IPS:-}; do
    [[ "$EIP" == "$SERVER_IP" || "$EIP" == "127.0.0.1" ]] && continue
    SAN_IPS="${SAN_IPS},IP:${EIP}"
  done

  local san_conf
  san_conf=$(mktemp)
  cat > "$san_conf" <<EOF
subjectAltName=DNS:${SERVER_FQDN},DNS:localhost,${SAN_IPS}
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF

  openssl x509 -req -in "$csr_temp" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SERVER_CRT" -days 825 -sha256 \
    -extfile "$san_conf" \
    2>/dev/null

  rm -f "$san_conf" "$csr_temp"
  chmod 600 "$SERVER_KEY"
  chmod 644 "$SERVER_CRT"
  ok "Server certificate issued successfully: $SERVER_CRT"
}

verify_cert() {
  info "Verifying certificate Subject Alternative Name (SAN)..."
  local san_line
  san_line=$(openssl x509 -in "$SERVER_CRT" -text -noout 2>/dev/null | grep -A1 "Subject Alt" | tail -1 || true)
  echo -e "  SAN Contents: ${GREEN}${san_line}${RESET}"
  local first_ip
  first_ip=$(echo "$SERVER_IP" | awk '{print $1}')
  if echo "$san_line" | grep -q "IP Address:${first_ip}"; then
    ok "IP SAN verified successfully!"
  else
    warn "IP SAN not detected, but it will still work via DNS name."
  fi
}

install_cert() {
  TS=$(date +%Y%m%d%H%M%S)

  if [[ "$PROFILE" == "pve" ]]; then
    info "Installing certificates to Proxmox VE..."
    PVE_SSL_DIR="/etc/pve/local"
    [[ -f "${PVE_SSL_DIR}/pveproxy-ssl.pem" ]] && \
      cp "${PVE_SSL_DIR}/pveproxy-ssl.pem" "${PVE_SSL_DIR}/pveproxy-ssl.pem.bak.${TS}"
    [[ -f "${PVE_SSL_DIR}/pveproxy-ssl.key" ]] && \
      cp "${PVE_SSL_DIR}/pveproxy-ssl.key" "${PVE_SSL_DIR}/pveproxy-ssl.key.bak.${TS}"

    cp "$SERVER_CRT" "${PVE_SSL_DIR}/pveproxy-ssl.pem"
    cp "$SERVER_KEY" "${PVE_SSL_DIR}/pveproxy-ssl.key"
    ok "Certificates copied to ${PVE_SSL_DIR}"

    info "Restarting PVE proxy services (pveproxy / pvedaemon)..."
    systemctl restart pveproxy pvedaemon
    sleep 2
    if systemctl is-active --quiet pveproxy; then
      ok "PVE services restarted successfully!"
    else
      warn "PVE services restart failed. Run 'systemctl status pveproxy' to check."
    fi

  elif [[ "$PROFILE" == "nginx_proxy" ]]; then
    info "Deploying and configuring Nginx Reverse Proxy..."
    
    # 1. Install Nginx if missing
    if ! command -v nginx &>/dev/null; then
      info "Nginx not found. Installing Nginx..."
      if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y nginx
      elif command -v dnf &>/dev/null; then
        dnf install -y nginx
      elif command -v yum &>/dev/null; then
        yum install -y nginx
      else
        die "Nginx package installation is not supported on this OS. Please install Nginx manually."
      fi
      ok "Nginx installed successfully!"
    fi
    
    # 2. Write configuration file /etc/nginx/conf.d/anycert_proxy.conf
    local NGINX_CONF="/etc/nginx/conf.d/anycert_proxy.conf"
    mkdir -p "$(dirname "$NGINX_CONF")"
    
    # Clean file first
    : > "$NGINX_CONF"

    # Build server_name list (FQDN + primary IP + extra IPs + localhost)
    local NGINX_SERVER_NAMES="${SERVER_FQDN} ${SERVER_IP}"
    for EIP in ${EXTRA_IPS:-}; do
      [[ "$EIP" == "$SERVER_IP" || "$EIP" == "127.0.0.1" ]] && continue
      NGINX_SERVER_NAMES="${NGINX_SERVER_NAMES} ${EIP}"
    done
    NGINX_SERVER_NAMES="${NGINX_SERVER_NAMES} localhost 127.0.0.1"
    
    # Write server blocks
    local ASSIGNED_SSL_PORTS=()
    for P in ${PROXY_PORTS}; do
      local SSL_P
      SSL_P=$(resolve_ssl_port "$P")

      cat << EOF >> "$NGINX_CONF"

# SSL Wrapper for Port ${P} -> ${SSL_P}
server {
    listen ${SSL_P} ssl;
    server_name ${NGINX_SERVER_NAMES};

    ssl_certificate      /etc/anycert/anycert-server.crt;
    ssl_certificate_key  /etc/anycert/anycert-server.key;

    location / {
        proxy_pass http://127.0.0.1:${P};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect http:// https://;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    done
    ok "Nginx configuration written successfully: ${NGINX_CONF}"
    
    # 3. Start or reload Nginx
    info "Testing Nginx configuration..."
    if nginx -t &>/dev/null; then
      if systemctl is-active --quiet nginx; then
        info "Reloading Nginx daemon..."
        systemctl reload nginx
        ok "Nginx reloaded successfully!"
      else
        info "Starting Nginx daemon..."
        systemctl start nginx
        systemctl enable nginx || true
        ok "Nginx started successfully!"
      fi
    else
      error "Nginx configuration test failed! Please check '/etc/nginx/conf.d/anycert_proxy.conf'."
    fi

  elif [[ "$PROFILE" == "custom" ]]; then
    info "Deploying certificates to custom paths..."
    local dest_cert_dir dest_key_dir
    dest_cert_dir=$(dirname "$CUSTOM_CERT")
    dest_key_dir=$(dirname "$CUSTOM_KEY")
    mkdir -p "$dest_cert_dir" "$dest_key_dir"

    # Backup old certs
    [[ -f "$CUSTOM_CERT" ]] && cp "$CUSTOM_CERT" "${CUSTOM_CERT}.bak.${TS}"
    [[ -f "$CUSTOM_KEY" ]] && cp "$CUSTOM_KEY" "${CUSTOM_KEY}.bak.${TS}"

    cp "$SERVER_CRT" "$CUSTOM_CERT"
    cp "$SERVER_KEY" "$CUSTOM_KEY"
    chmod 644 "$CUSTOM_CERT" || true
    chmod 600 "$CUSTOM_KEY" || true
    ok "Certificate copied to: $CUSTOM_CERT"
    ok "Private key copied to: $CUSTOM_KEY"

    if [[ -n "${RELOAD_CMD:-}" ]]; then
      info "Running reload command: ${RELOAD_CMD}"
      if eval "${RELOAD_CMD}"; then
        ok "Reload command executed successfully!"
      else
        warn "Reload command failed. Please check the command and service status."
      fi
    fi
  else
    info "Generated files only, not applied to any service."
  fi

  if [[ "${ONLY_UPDATE_PORTS:-0}" == "1" ]]; then
    return
  fi

  # ── Import CA locally (optional) ──
  echo ""
  echo -e "${CYAN}[INFO]${RESET} Import this Root CA into this server's local system trust store for local browser/tooling access."
  read -rp "$(echo -e "${YELLOW}Do you want to import? [y/N]${RESET} ")" LOCAL_TRUST
  if [[ "$LOCAL_TRUST" =~ ^[Yy]$ ]]; then
    if $IS_LINUX; then
      if command -v update-ca-certificates &>/dev/null; then
        cp "$CA_CRT" "/usr/local/share/ca-certificates/anycert-ca-local.crt"
        update-ca-certificates
        ok "CA certificate imported to local system trust store."
      elif command -v update-ca-trust &>/dev/null; then
        cp "$CA_CRT" "/etc/pki/ca-trust/source/anchors/anycert-ca-local.crt"
        update-ca-trust extract
        ok "CA certificate imported to local system trust store."
      else
        warn "Local certificate update tool not found. Skipping import."
      fi
    elif $IS_MAC; then
      if security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_CRT"; then
        ok "CA certificate imported to macOS local System Keychain."
      else
        warn "Failed to import CA certificate to macOS local Keychain."
      fi
    fi
  fi
}

save_config() {
  cat > "$CONF_FILE" <<EOF
# anycert configuration
PROFILE="${PROFILE}"
SERVER_IP="${SERVER_IP}"
SERVER_FQDN="${SERVER_FQDN}"
EOF

  if [[ "$PROFILE" == "custom" ]]; then
    cat >> "$CONF_FILE" <<EOF
CUSTOM_CERT="${CUSTOM_CERT}"
CUSTOM_KEY="${CUSTOM_KEY}"
RELOAD_CMD="${RELOAD_CMD}"
EOF
  elif [[ "$PROFILE" == "nginx_proxy" ]]; then
    cat >> "$CONF_FILE" <<EOF
PROXY_PORTS="${PROXY_PORTS}"
PORT_OFFSET="${PORT_OFFSET}"
EOF
  fi
  chmod 600 "$CONF_FILE"
}

show_summary() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}║             Certificate Setup Summary                ║${RESET}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}[ Certificate Info ]${RESET}"

  local subject issuer startdate enddate fingerprint san_full
  subject=$(openssl x509    -in "$SERVER_CRT" -noout -subject    2>/dev/null | sed 's/subject=//')
  issuer=$(openssl x509     -in "$SERVER_CRT" -noout -issuer     2>/dev/null | sed 's/issuer=//')
  startdate=$(openssl x509 -in "$SERVER_CRT" -noout -startdate  2>/dev/null | sed 's/notBefore=//')
  enddate=$(openssl x509  -in "$SERVER_CRT" -noout -enddate    2>/dev/null | sed 's/notAfter=//')
  fingerprint=$(openssl x509 -in "$SERVER_CRT" -noout -fingerprint -sha256 2>/dev/null | sed 's/SHA256 Fingerprint=//')
  san_full=$(openssl x509   -in "$SERVER_CRT" -text  -noout 2>/dev/null | grep -A1 "Subject Alt" | tail -1 | xargs)

  local total_days=0 start_epoch end_epoch
  start_epoch=$(date -d "$startdate" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$startdate" +%s 2>/dev/null || echo 0)
  end_epoch=$(date -d "$enddate" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$enddate" +%s 2>/dev/null || echo 0)
  if [[ $start_epoch -gt 0 && $end_epoch -gt 0 ]]; then
    total_days=$(( (end_epoch - start_epoch) / 86400 ))
  fi

  local ca_start ca_end ca_total=0 ca_start_epoch ca_end_epoch
  ca_start=$(openssl x509 -in "$CA_CRT" -noout -startdate 2>/dev/null | sed 's/notBefore=//')
  ca_end=$(openssl x509   -in "$CA_CRT" -noout -enddate   2>/dev/null | sed 's/notAfter=//')
  ca_start_epoch=$(date -d "$ca_start" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$ca_start" +%s 2>/dev/null || echo 0)
  ca_end_epoch=$(date -d "$ca_end" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$ca_end" +%s 2>/dev/null || echo 0)
  if [[ $ca_start_epoch -gt 0 && $ca_end_epoch -gt 0 ]]; then
    ca_total=$(( (ca_end_epoch - ca_start_epoch) / 86400 ))
  fi

  printf "  %-22s %s\n" "Subject:"   "$subject"
  printf "  %-22s %s\n" "Issuer:"    "$issuer"
  printf "  %-22s %s\n" "Validity From:"   "$startdate"
  printf "  %-22s %s\n" "Validity Until:"  "$enddate"
  printf "  %-22s %s\n" "Validity:"        "${total_days} days"
  printf "  %-22s %s\n" "Root CA Validity:" "${ca_total} days"
  printf "  %-22s %s\n" "SAN Contents:"     "$san_full"
  printf "  %-22s %s\n" "SHA256 Fingerprint:"  "$fingerprint"

  echo ""
  echo -e "${BOLD}[ File Locations ]${RESET}"
  printf "  %-45s %s\n" "Root CA Certificate (for clients):" "$CA_CRT"
  printf "  %-45s %s\n" "Root CA Private Key (KEEP IT SECURE!):" "$CA_KEY"
  printf "  %-45s %s\n" "Server Certificate (CRT):"            "$SERVER_CRT"
  printf "  %-45s %s\n" "Server Private Key (KEY):"            "$SERVER_KEY"
  if [[ "$PROFILE" == "pve" ]]; then
    printf "  %-45s %s\n" "PVE Applied Certificate Path:"          "/etc/pve/local/pveproxy-ssl.pem"
  elif [[ "$PROFILE" == "custom" ]]; then
    printf "  %-45s %s\n" "Custom Applied Certificate Path:"          "$CUSTOM_CERT"
  elif [[ "$PROFILE" == "nginx_proxy" ]]; then
    printf "  %-45s %s\n" "Nginx Configured File:"                 "/etc/nginx/conf.d/anycert_proxy.conf"
  fi

  if [[ "$PROFILE" == "nginx_proxy" ]]; then
    echo ""
    echo -e "${BOLD}[ Nginx SSL Proxy Port Mappings ]${RESET}"
    local ASSIGNED_SSL_PORTS=()
    for P in ${PROXY_PORTS}; do
      local SSL_P
      SSL_P=$(resolve_ssl_port "$P")
      echo -e "  - ${GREEN}https://${SERVER_FQDN}:${SSL_P}${RESET}  ->  HTTP localhost:${P}"
    done
  fi

  echo ""
  echo -e "${BOLD}--------------------------------------------${RESET}"
  echo -e "${BOLD}[ Client Device Setup Steps ]${RESET}"
  echo -e "${BOLD}Option A: Manual${RESET}"
  echo ""
  echo -e "  1. Download the Root CA certificate on each client device:"
  echo -e "     ${YELLOW}scp -o StrictHostKeyChecking=no root@${SERVER_IP}:${CA_CRT} ./anycert-ca.crt${RESET}"
  echo -e "     (Even if connecting via SSH with a non-root user, the CA file is readable [644] and downloadable)"
  echo ""
  echo -e "  2. Add the following entry to the client's hosts file:"
  echo -e "     ${YELLOW}${SERVER_IP}  ${SERVER_FQDN}${RESET}"
  echo ""
  echo -e "  3. Connect to the server from your browser using the FQDN:"
  echo -e "     ${GREEN}https://${SERVER_FQDN}:<port>${RESET}"
  echo ""
  echo -e "${BOLD}Option B: Automatic${RESET}"
  echo ""
  echo -e "  👉 Recommended: Execute the corresponding client script directly on the client machine:"
  echo -e "     - Windows: ${BOLD}anycert-windows.bat${RESET}"
  echo -e "     - Linux:   ${BOLD}sudo bash anycert-linux.sh${RESET}"
  echo -e "     - macOS:   ${BOLD}sudo bash anycert-macos.sh${RESET}"
  echo ""
  ok "Installation completed successfully!"
}

sanitize_proxyports() {
  if [[ -z "${PROXY_PORTS:-}" ]]; then
    return
  fi
  local SP_NEW=""
  for P in $PROXY_PORTS; do
    local SP_T="$P"
    # Strip leading +, -, or : prefix
    [[ "${SP_T:0:1}" == "+" ]] && SP_T="${SP_T:1}"
    [[ "${SP_T:0:1}" == "-" ]] && SP_T="${SP_T:1}"
    [[ "${SP_T:0:1}" == ":" ]] && SP_T="${SP_T:1}"
    if [[ -z "$SP_NEW" ]]; then
      SP_NEW="$SP_T"
    else
      SP_NEW="$SP_NEW $SP_T"
    fi
  done
  # Sort numerically ascending and deduplicate
  PROXY_PORTS=$(echo "$SP_NEW" | tr ' ' '\n' | awk 'NF && !seen[$1]++' | sort -n | tr '\n' ' ' | xargs)
}

process_port_adjustments() {
  # Check if NEW_PROXY_PORTS contains '+' or '-'
  if [[ "$NEW_PROXY_PORTS" != *"-"* && "$NEW_PROXY_PORTS" != *"+"* ]]; then
    # Neither '+' nor '-' found, simple overwrite
    PROXY_PORTS="$NEW_PROXY_PORTS"
    return
  fi

  # Incremental/decremental adjustment mode
  for TOKEN in $NEW_PROXY_PORTS; do
    # Strip all leading +, -, : prefixes first to get the clean port number
    local TARGET_PORT="$TOKEN"
    [[ "${TARGET_PORT:0:1}" == "+" ]] && TARGET_PORT="${TARGET_PORT:1}"
    [[ "${TARGET_PORT:0:1}" == "-" ]] && TARGET_PORT="${TARGET_PORT:1}"
    [[ "${TARGET_PORT:0:1}" == ":" ]] && TARGET_PORT="${TARGET_PORT:1}"

    # Determine if original token starts with '-'
    if [[ "$TOKEN" =~ ^- ]]; then
      # Remove TARGET_PORT from PROXY_PORTS
      local NEW_LIST=""
      for P in $PROXY_PORTS; do
        if [[ "$P" != "$TARGET_PORT" ]]; then
          NEW_LIST="$NEW_LIST $P"
        fi
      done
      PROXY_PORTS=$(echo "$NEW_LIST" | xargs)
    else
      # TARGET_PORT is already cleaned above; use it for addition
      local ALREADY_HAS=0
      for P in $PROXY_PORTS; do
        if [[ "$P" == "$TARGET_PORT" ]]; then
          ALREADY_HAS=1
          break
        fi
      done
      if [[ $ALREADY_HAS -eq 0 ]]; then
        PROXY_PORTS="$PROXY_PORTS $TARGET_PORT"
      fi
    fi
  done
  PROXY_PORTS=$(echo "$PROXY_PORTS" | xargs)
}

check_existing_cert() {
  if [[ -f "$SERVER_CRT" ]]; then
    echo "An existing certificate setup is detected."
    echo "-----------------------------------------------------"
    
    # Parse subject and expiration
    local CERT_SUBJ
    CERT_SUBJ=$(openssl x509 -subject -noout -in "$SERVER_CRT" 2>/dev/null | sed 's/subject=//' | sed 's/CN=//' | xargs)
    local EXP_DATE
    EXP_DATE=$(openssl x509 -enddate -noout -in "$SERVER_CRT" 2>/dev/null | cut -d= -f2)
    local EXP_EPOCH
    EXP_EPOCH=$(date -d "$EXP_DATE" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXP_DATE" +%s 2>/dev/null || echo 0)
    local NOW_EPOCH
    NOW_EPOCH=$(date +%s)
    local DAYS_LEFT=0
    if [[ $EXP_EPOCH -gt 0 ]]; then
      DAYS_LEFT=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
    fi
    
    echo "  Subject/FQDN : $CERT_SUBJ"
    echo "  Days Left    : $DAYS_LEFT days"
    echo "  Current Profile : ${PROFILE:-none}"
    if [[ "${PROFILE:-none}" == "nginx_proxy" ]]; then
      echo "  Current Mapped Ports : ${PROXY_PORTS:-}"
      echo "  Current HTTPS Offset: ${PORT_OFFSET:-}"
    fi
    echo ""
    
    if [[ $DAYS_LEFT -lt 30 ]]; then
      warn "This certificate is expiring soon ($DAYS_LEFT days left)!"
      echo ""
    fi
    
    echo "Please choose an action:"
    if [[ "${PROFILE:-none}" == "nginx_proxy" ]]; then
      echo "  [1] Update/Modify Nginx port mappings"
    else
      echo "  [1] Update/Modify Nginx port mappings (Switch to Nginx SSL Proxy)"
    fi
    echo "  [2] Renew/Regenerate the SSL certificate"
    echo "  [3] Uninstall and restore original settings"
    echo "  [4] Keep existing and exit"
    echo ""
    
    local choice=""
    while true; do
      read -rp "  Please choose [1-4]: " choice
      if [[ "$choice" =~ ^[1-4]$ ]]; then
        break
      fi
      warn "Invalid choice, please try again."
    done
    
    if [[ "$choice" == "1" ]]; then
      echo ""
      echo "[Update Nginx Port Mappings]"
      echo "-----------------------------------------------------"
      echo "  Current proxy ports: ${PROXY_PORTS:-}"
      echo ""
      echo "  Quick guide:"
      echo "    - To overwrite all: just type the new list, like: 3000 8080"
      echo "    - To add more: put + in front, like: +8080 +9090"
      echo "    - To remove: put - in front, like: -3000"
      echo ""
      read -rp "  What ports should I wrap in SSL now? " NEW_PROXY_PORTS
      if [[ -n "$NEW_PROXY_PORTS" ]]; then
        process_port_adjustments
      fi
      sanitize_proxyports
      PROFILE="nginx_proxy"
      ONLY_UPDATE_PORTS=1
      
      # Execute only the necessary steps for port update
      install_cert
      save_config
      show_summary
      exit 0
    elif [[ "$choice" == "2" ]]; then
      echo ""
      info "Renewing Certificate. Keeping current settings..."
      echo ""
      RENEW_MODE=1
    elif [[ "$choice" == "3" ]]; then
      do_uninstall
      exit 0
    elif [[ "$choice" == "4" ]]; then
      info "Keeping existing settings. Exiting..."
      exit 0
    fi
  fi
}

# ── Entry point ──────────────────────────────────────────────
banner
check_root
detect_os
check_deps

if [[ "${1:-}" == "-u" ]]; then
  do_uninstall
  exit 0
fi

if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
fi
sanitize_proxyports

check_existing_cert

detect_server_info
confirm_info
if [[ "${RENEW_MODE:-0}" == "1" ]]; then
  echo -e "${BOLD}[3/6] Reusing existing Service Profile: ${PROFILE}${RESET}"
  echo "-----------------------------------------------------"
  if [[ "$PROFILE" == "nginx_proxy" ]]; then
    echo "  Nginx SSL Proxy ports: ${PROXY_PORTS} (HTTPS offset: ${PORT_OFFSET})"
  elif [[ "$PROFILE" == "custom" ]]; then
    echo "  Custom CRT: ${CUSTOM_CERT}"
    echo "  Custom KEY: ${CUSTOM_KEY}"
  fi
  echo ""
else
  choose_profile
fi
ask_proceed
generate_ca
generate_server_cert
verify_cert
install_cert
save_config
show_summary
