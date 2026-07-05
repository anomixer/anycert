@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

:: ============================================================
:: anycert.bat — Windows Server HTTPS Certificate Generator
:: Usage:
::   anycert.bat       Install local certificate
::   anycert.bat -u    Uninstall / restore backup
:: Run as Administrator
:: ============================================================

title Anycert Windows Server Certificate Generator

:: Define ANSI colors
for /F "delims=" %%A in ('powershell -NoProfile -Command "[char]27"') do set "ESC=%%A"
set "YELLOW=!ESC![1;33m"
set "CYAN=!ESC![1;36m"
set "BLUE=!ESC![1;34m"
set "RESET=!ESC![0m"

echo.
echo !YELLOW! █████╗ ███╗   ██╗██╗   ██╗ ██████╗███████╗██████╗ ████████╗!RESET!
echo !YELLOW!██╔══██╗████╗  ██║╚██╗ ██╔╝██╔════╝██╔════╝██╔══██╗╚══██╔══╝!RESET!
echo !CYAN!███████║██╔██╗ ██║ ╚████╔╝ ██║     █████╗  ██████╔╝   ██║   !RESET!
echo !CYAN!██╔══██║██║╚██╗██║  ╚██╔╝  ██║     ██╔══╝  ██╔══██╗   ██║   !RESET!
echo !BLUE!██║  ██║██║ ╚████║   ██║   ╚██████╗███████╗██║  ██║   ██║   !RESET!
echo !BLUE!╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝╚══════╝╚═╝  ╚═╝   ╚═╝   !RESET!
echo !CYAN!                      anycert.bat (Windows Server) !RESET!
echo.

:: ── Check Administrator privileges ──────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] This script requires Administrator privileges.
    set /p ELEVATE_CONFIRM=  Would you like to elevate to Administrator now? [y/N]: 
    if /i "!ELEVATE_CONFIRM!"=="y" (
        powershell -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~dp0%~nx0\"\" %*' -Verb RunAs"
        exit /b 0
    )
    echo [ERROR] Administrator privileges are required to run this script.
    echo.
    pause
    exit /b 1
)

:: ── Paths ───────────────────────────────────────────────────
set CONF_DIR=C:\anycert
if not exist "!CONF_DIR!" mkdir "!CONF_DIR!"
set CONF_FILE=!CONF_DIR!\anycert.conf
set CA_KEY=!CONF_DIR!\anycert-ca.key
set CA_CRT=!CONF_DIR!\anycert-ca.crt
set CA_SRL=!CONF_DIR!\anycert-ca.srl
set SERVER_KEY=!CONF_DIR!\anycert-server.key
set SERVER_CRT=!CONF_DIR!\anycert-server.crt

if /i "%~1"=="-u" goto do_uninstall

:: Load existing configurations if present
if exist "!CONF_FILE!" (
    for /f "usebackq delims=" %%A in ("!CONF_FILE!") do set %%A
)

:: ── Check existing certificate ──────────────────────────────
if exist "!SERVER_CRT!" (
    echo An existing certificate setup is detected.
    echo -----------------------------------------------------
    for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 '!SERVER_CRT!').Subject"`) do set "CERT_SUBJ=%%S"
    for /f "usebackq" %%D in (`powershell -NoProfile -Command "[math]::Round(((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 '!SERVER_CRT!').NotAfter - (Get-Date)).TotalDays)"`) do set "DAYS_LEFT=%%D"
    
    echo   Subject/FQDN : !CERT_SUBJ!
    echo   Days Left    : !DAYS_LEFT! days
    echo   Current Profile : !PROFILE!
    if "!PROFILE!"=="nginx_proxy" (
        echo   Current Mapped Ports : !PROXY_PORTS!
    )
    echo.
    if !DAYS_LEFT! lss 30 (
        echo   !YELLOW![WARN] This certificate is expiring soon ^(!DAYS_LEFT! days left^)^!!RESET!
        echo.
    )
    
    echo Please choose an action:
    if "!PROFILE!"=="nginx_proxy" (
        echo   [1] Update/Modify Nginx port mappings
    ) else (
        echo   [1] Update/Modify Nginx port mappings (Switch to Nginx SSL Proxy)
    )
    echo   [2] Renew/Regenerate the SSL certificate
    echo   [3] Uninstall and restore original settings
    echo   [4] Keep existing and exit
    echo.
    
    :exist_action_loop
    set EXIST_ACTION=
    set /p EXIST_ACTION=  Please choose [1-4]: 
    if "!EXIST_ACTION!"=="1" goto do_update_ports
    if "!EXIST_ACTION!"=="2" goto do_renew_cert
    if "!EXIST_ACTION!"=="3" goto do_uninstall
    if "!EXIST_ACTION!"=="4" (
        echo Keeping existing settings. Exiting...
        pause
        exit /b 0
    )
    goto exist_action_loop

    :do_update_ports
    echo.
    echo [Update Nginx Port Mappings]
    echo -----------------------------------------------------
    echo   Current proxy ports: !PROXY_PORTS!
    echo   Rules:
    echo     - To overwrite: Enter list of ports [e.g. 3000 8080]
    echo     - To adjust   : Use + to add, - to remove [e.g. +8080 -3000]
    echo.
    set /p NEW_PROXY_PORTS=  Enter new HTTP ports to wrap in SSL: 
    if not "!NEW_PROXY_PORTS!"=="" (
        call :process_port_adjustments
    )
    set PROFILE=nginx_proxy
    set ONLY_UPDATE_PORTS=1
    goto do_deploy_nginx_proxy

    :do_renew_cert
    echo.
    echo [Renewing Certificate] Keep current port configurations and regenerate files...
    echo.
)


:: ============================================================
::  INSTALL MODE
:: ============================================================

:: ── Find OpenSSL ─────────────────────────────────────────────
set OPENSSL_BIN=
where openssl >nul 2>&1
if %errorlevel% equ 0 (
    set OPENSSL_BIN=openssl
    goto openssl_ok
)

:: Check Git for Windows path
if exist "C:\Program Files\Git\usr\bin\openssl.exe" (
    set OPENSSL_BIN="C:\Program Files\Git\usr\bin\openssl.exe"
    goto openssl_ok
)
if exist "C:\Program Files (x86)\Git\usr\bin\openssl.exe" (
    set OPENSSL_BIN="C:\Program Files (x86)\Git\usr\bin\openssl.exe"
    goto openssl_ok
)

echo [WARN] openssl executable not found!
echo We can automatically install Git for Windows (built-in OpenSSL) via winget.
set /p INSTALL_GIT=  Do you want to automatically install Git? [y/N]: 
if /i "!INSTALL_GIT!"=="y" (
    echo Installing Git for Windows via winget. Please allow installation in the UAC popup...
    winget install -e --id Git.Git
    if !errorlevel! equ 0 (
        echo   [OK] Git installation complete! Refreshing path...
        if exist "C:\Program Files\Git\usr\bin\openssl.exe" (
            set OPENSSL_BIN="C:\Program Files\Git\usr\bin\openssl.exe"
            goto openssl_ok
        )
        where openssl >nul 2>&1
        if !errorlevel! equ 0 (
            set OPENSSL_BIN=openssl
            goto openssl_ok
        )
        echo   [WARN] Installation complete, but openssl.exe still cannot be loaded directly.
        echo   Please restart this Command Prompt window to apply environment variables, then run this script again.
        pause
        exit /b 0
    ) else (
        echo   [ERROR] winget installation failed. Please install Git manually.
    )
)

echo [ERROR] openssl executable not found!
echo Please install Git for Windows or OpenSSL for Windows first.
echo.
pause
exit /b 1

:openssl_ok
:: ── Detect network info ──────────────────────────────────────
echo [1/6] Auto-detecting network configurations...
echo -----------------------------------------------------

:: Detect IP using PowerShell
set SERVER_IP=
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike '*Loopback*' -and $_.InterfaceAlias -notlike '*vEthernet*' -and $_.InterfaceAlias -notlike '*WSL*' -and $_.InterfaceAlias -notlike '*Tailscale*' -and $_.InterfaceAlias -notlike '*VirtualBox*' -and $_.InterfaceAlias -notlike '*VMware*' } | Select-Object -First 1).IPAddress"`) do (
    set SERVER_IP=%%A
)
if "!SERVER_IP!"=="" set SERVER_IP=127.0.0.1

:: Detect Hostname & FQDN
set SERVER_HOSTNAME=%COMPUTERNAME%
set SERVER_FQDN=
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "[System.Net.Dns]::GetHostEntry('').HostName"`) do (
    set SERVER_FQDN=%%A
)
if "!SERVER_FQDN!"=="" set SERVER_FQDN=!SERVER_HOSTNAME!.local

echo   Auto-detection results:
echo   Server IP Address: !SERVER_IP!
echo   Hostname:          !SERVER_HOSTNAME!
echo   Default FQDN (DNS): !SERVER_FQDN!
echo.

:: ── Confirm network info ────────────────────────────────────
echo [2/6] Please confirm or modify the detected information
echo -----------------------------------------------------
set /p INPUT_IP=  Server IP Address [!SERVER_IP!]: 
if not "!INPUT_IP!"=="" set SERVER_IP=!INPUT_IP!

set /p INPUT_FQDN=  Server DNS Name (FQDN) [!SERVER_FQDN!]: 
if not "!INPUT_FQDN!"=="" set SERVER_FQDN=!INPUT_FQDN!
echo.

:: ── Choose profile ──────────────────────────────────────────
echo [3/6] Please choose the Service Profile to apply
echo -----------------------------------------------------
echo   [1] Custom Path (Auto-Deploy)
echo       - Copies certificates to your service folders (e.g. IIS, Nginx, Apache, Emby, Plex, Docker)
echo       - Can automatically run a reload command to apply changes
echo.
echo   [2] Auto-Setup Nginx SSL Proxy (Port-Offset Wrapper) [Lazy-Friendly / Recommended]
echo       - Installs Nginx and automatically wraps your HTTP ports in SSL
echo       - Keeps your existing apps running on HTTP, proxies to SSL Port + 10000
echo.
echo   [3] Generate Only (Manual Deploy) [Painful / Hard Way]
echo       - Generates cert files in C:\anycert\ only
echo       - Requires manual configuration for all your services
echo.
:choose_profile_loop
set /p PROFILE_CHOICE=  Please choose [1-3, default: 2]: 
if "!PROFILE_CHOICE!"=="" set PROFILE_CHOICE=2

if not "!PROFILE_CHOICE!"=="1" if not "!PROFILE_CHOICE!"=="2" if not "!PROFILE_CHOICE!"=="3" (
    echo [WARN] Invalid choice, please try again.
    echo.
    goto choose_profile_loop
)

set PROFILE=none
if "!PROFILE_CHOICE!"=="1" set PROFILE=custom
if "!PROFILE_CHOICE!"=="2" set PROFILE=nginx_proxy
if "!PROFILE_CHOICE!"=="3" set PROFILE=none

set CUSTOM_CERT=
set CUSTOM_KEY=
set RELOAD_CMD=
set PROXY_PORTS=

if "!PROFILE!"=="custom" goto do_profile_custom
if "!PROFILE!"=="nginx_proxy" goto do_profile_nginx_proxy
goto do_ask_proceed

:do_profile_custom
echo.
echo   [Custom Path Settings]
set /p CUSTOM_CERT=  1. Target Certificate Path (CRT/PEM) [e.g. C:\nginx\ssl\nginx.crt]: 
if "!CUSTOM_CERT!"=="" (
    echo [ERROR] Certificate path cannot be empty!
    pause
    exit /b 1
)
set /p CUSTOM_KEY=  2. Target Private Key Path (KEY) [e.g. C:\nginx\ssl\nginx.key]: 
if "!CUSTOM_KEY!"=="" (
    echo [ERROR] Private key path cannot be empty!
    pause
    exit /b 1
)
set /p RELOAD_CMD=  3. Service reload/restart command (optional) [e.g. nginx -s reload]: 
echo.
goto do_ask_proceed

:do_profile_nginx_proxy
echo.
echo   [Automated Nginx SSL Proxy Settings]

:: Detect active local TCP ports
set DETECTED_PORTS=
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue ^| Where-Object {$_.LocalPort -gt 80 -and $_.LocalPort -ne 135 -and $_.LocalPort -ne 445 -and $_.LocalPort -ne 5357} ^| Select-Object -ExpandProperty LocalPort ^| Sort-Object -Unique; $ports -join ' '"`) do set "DETECTED_PORTS=%%P"

set EXISTING_PORTS=
if exist "!CONF_FILE!" (
    for /f "usebackq delims=" %%A in ("!CONF_FILE!") do (
        for /f "tokens=1,2 delims==" %%I in ("%%A") do (
            if "%%I"=="PROXY_PORTS" set "EXISTING_PORTS=%%J"
        )
    )
)

if "!EXISTING_PORTS!"=="" goto do_nginx_no_existing

echo   Currently configured SSL proxy HTTP ports:
echo     !EXISTING_PORTS!
echo.
echo   Select an action:
echo     [1] Keep existing ports [Default]
echo     [2] Add new ports to the list
echo     [3] Remove ports from the list
echo     [4] Overwrite / Set a completely new list of ports
echo.

:nginx_opt_loop
set /p PORT_OPT=  Please choose [1-4, default: 1]: 
if "!PORT_OPT!"=="" set PORT_OPT=1

if "!PORT_OPT!"=="1" goto do_opt_keep
if "!PORT_OPT!"=="2" goto do_opt_add
if "!PORT_OPT!"=="3" goto do_opt_remove
if "!PORT_OPT!"=="4" goto do_opt_overwrite
echo [WARN] Invalid choice, please try again.
goto nginx_opt_loop

:do_opt_keep
set "PROXY_PORTS=!EXISTING_PORTS!"
goto do_nginx_ports_decision_done

:do_opt_add
if not "!DETECTED_PORTS!"=="" (
    echo   [INFO] Detected active local TCP ports: !DETECTED_PORTS!
)
echo   Nginx will map new ports to "Port + 10000" under HTTPS [e.g. 3000 -^> 13000].
echo   For ports ^>= 55536, it maps to "Port - 10000" [e.g. 60000 -^> 50000] to fit in TCP range [1-65535].
set /p NEW_PORTS=  Enter new HTTP ports to add (space-separated): 
for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "$ports = ('!EXISTING_PORTS! ' + '!NEW_PORTS!').Split(' ') ^| Where-Object {$_} ^| Select-Object -Unique; $ports -join ' '"`) do set "PROXY_PORTS=%%D"
goto do_nginx_ports_decision_done

:do_opt_remove
set /p REMOVE_PORTS=  Enter HTTP ports to remove (space-separated): 
for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "$ports = ('!EXISTING_PORTS!').Split(' ') ^| Where-Object {$_}; $remove = ('!REMOVE_PORTS!').Split(' ') ^| Where-Object {$_}; $res = $ports ^| Where-Object { $remove -notcontains $_ }; $res -join ' '"`) do set "PROXY_PORTS=%%D"
goto do_nginx_ports_decision_done

:do_opt_overwrite
if not "!DETECTED_PORTS!"=="" (
    echo   [INFO] Detected active local TCP ports: !DETECTED_PORTS!
)
echo   Nginx will map these ports to "Port + 10000" under HTTPS [e.g. 3000 -^> 13000].
echo   For ports ^>= 55536, it maps to "Port - 10000" [e.g. 60000 -^> 50000] to fit in TCP range [1-65535].
set /p NEW_LIST=  Enter new list of HTTP ports (space-separated): 
set "PROXY_PORTS=!NEW_LIST!"
goto do_nginx_ports_decision_done

:do_nginx_ports_decision_done
goto do_nginx_ports_done

:do_nginx_no_existing
if not "!DETECTED_PORTS!"=="" (
    echo   [INFO] Detected active local TCP ports: !DETECTED_PORTS!
)
echo   Enter the HTTP ports of your local services to wrap in SSL.
echo   Nginx will map these to "Port + 10000" under HTTPS [e.g. 3000 -^> 13000].
echo   For ports ^>= 55536, it maps to "Port - 10000" [e.g. 60000 -^> 50000] to fit in TCP range [1-65535].
echo   Separate multiple ports with spaces [e.g. 3000 6000 11434].
set /p PROXY_PORTS=  Enter ports: 

:do_nginx_ports_done

if "!PROXY_PORTS!"=="" (
    echo [ERROR] You must specify at least one port for proxying!
    pause
    exit /b 1
)
echo.
goto do_ask_proceed

:do_ask_proceed

:: ── Ask to proceed ──────────────────────────────────────────
echo [4/6] The following actions will be performed:
echo -----------------------------------------------------
echo   1. Create a 10-year local Root CA certificate (!CA_CRT!)
echo   2. Issue a 825-day server certificate (!SERVER_CRT!) with SAN:
echo      DNS: !SERVER_FQDN!
echo      IP : !SERVER_IP!
if "!PROFILE!"=="custom" (
    echo   3. Copy certificates to custom paths:
    echo      CRT -^> !CUSTOM_CERT!
    echo      KEY -^> !CUSTOM_KEY!
    if not "!RELOAD_CMD!"=="" echo   4. Run reload command: !RELOAD_CMD!
) else if "!PROFILE!"=="nginx_proxy" (
    echo   3. Install Nginx if missing, and configure it as an SSL wrapper for ports:
    echo      !PROXY_PORTS! (SSL ports: Original + 10000)
    echo   4. Start or reload Nginx to apply changes
) else (
    echo   3. Store files in !CONF_DIR!\ only, without applying to any service
)
echo.
set /p PROCEED_CONFIRM=  Do you want to proceed? [y/N]: 
if /i not "!PROCEED_CONFIRM!"=="y" (
    echo Cancelled.
    pause
    exit /b 0
)
echo.

:: ── Generate CA ─────────────────────────────────────────────
echo [5/6] Generating Root CA Certificate...
echo -----------------------------------------------------
if not exist "!CA_CRT!" goto do_gen_ca

echo   [WARN] CA Certificate already exists: !CA_CRT!
set /p REGEN_CA=  Regenerate CA? [y to regenerate, N to reuse existing CA, recommended: N] [y/N]: 
if /i "!REGEN_CA!"=="y" goto do_gen_ca
echo   Reusing existing CA certificate.
goto skip_gen_ca

:do_gen_ca
!OPENSSL_BIN! genrsa -out "!CA_KEY!" 4096 >nul 2>&1
!OPENSSL_BIN! req -x509 -new -nodes -key "!CA_KEY!" -sha256 -days 3650 -out "!CA_CRT!" -subj "/C=US/O=AnycertLocalCA/CN=Anycert Local Root CA (!SERVER_HOSTNAME!)" >nul 2>&1
echo   [OK] Root CA created successfully: !CA_CRT!

:skip_gen_ca
echo.

:: ── Generate Server Cert ────────────────────────────────────
echo [6/6] Issuing Server Certificate (with SAN)...
echo -----------------------------------------------------
set SERVER_CSR=!CONF_DIR!\anycert-server.csr
set SAN_CONF=!CONF_DIR!\san.conf

!OPENSSL_BIN! genrsa -out "!SERVER_KEY!" 2048 >nul 2>&1
!OPENSSL_BIN! req -new -key "!SERVER_KEY!" -out "!SERVER_CSR!" -subj "/CN=!SERVER_FQDN!" >nul 2>&1

(
echo subjectAltName=DNS:!SERVER_FQDN!,IP:!SERVER_IP!
echo basicConstraints=CA:FALSE
echo keyUsage=digitalSignature,keyEncipherment
echo extendedKeyUsage=serverAuth
) > "!SAN_CONF!"

!OPENSSL_BIN! x509 -req -in "!SERVER_CSR!" -CA "!CA_CRT!" -CAkey "!CA_KEY!" -CAcreateserial -out "!SERVER_CRT!" -days 825 -sha256 -extfile "!SAN_CONF!" >nul 2>&1

:: Cleanup temp files
if exist "!SERVER_CSR!" del "!SERVER_CSR!"
if exist "!SAN_CONF!" del "!SAN_CONF!"

echo   [OK] Server certificate issued successfully: !SERVER_CRT!
echo.

:: ── Install Cert ────────────────────────────────────────────
:: Generate timestamp for backup (WMIC is deprecated/missing in modern Windows)
for /f "usebackq" %%T in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMddHHmmss'"`) do set "TS=%%T"

if "!PROFILE!"=="custom" goto do_deploy_custom
if "!PROFILE!"=="nginx_proxy" goto do_deploy_nginx_proxy
goto do_post_install

:do_deploy_custom
echo Deploying certificates to custom paths...
echo -----------------------------------------------------

:: Backup existing
if exist "!CUSTOM_CERT!" copy /y "!CUSTOM_CERT!" "!CUSTOM_CERT!.bak.!TS!" >nul
if exist "!CUSTOM_KEY!" copy /y "!CUSTOM_KEY!" "!CUSTOM_KEY!.bak.!TS!" >nul

copy /y "!SERVER_CRT!" "!CUSTOM_CERT!" >nul
copy /y "!SERVER_KEY!" "!CUSTOM_KEY!" >nul

echo   [OK] Certificate copied to: !CUSTOM_CERT!
echo   [OK] Private key copied to: !CUSTOM_KEY!

if not "!RELOAD_CMD!"=="" (
    echo   Executing service reload command: !RELOAD_CMD!
    cmd /c "!RELOAD_CMD!"
    if !errorlevel! equ 0 (
        echo   [OK] Reload command executed successfully!
    ) else (
        echo   [WARN] Reload command failed. Please check the service status.
    )
)
echo.
goto do_post_install

:do_deploy_nginx_proxy
echo Deploying and configuring Nginx Reverse Proxy...
echo -----------------------------------------------------

:: Install Nginx if not exists at C:\nginx
if not exist "C:\nginx\nginx.exe" (
    echo   [INFO] Nginx not found at C:\nginx. Downloading and installing...
    powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://nginx.org/download/nginx-1.26.1.zip' -OutFile '!CONF_DIR!\nginx.zip'"
    powershell -NoProfile -Command "Expand-Archive -Path '!CONF_DIR!\nginx.zip' -DestinationPath '!CONF_DIR!'"
    move "!CONF_DIR!\nginx-1.26.1" "C:\nginx" >nul 2>&1
    del "!CONF_DIR!\nginx.zip" >nul 2>&1
    echo   [OK] Nginx installed successfully to C:\nginx!
)

:: Create clean config
set NGINX_CONF=C:\nginx\conf\nginx.conf
(
echo worker_processes  1;
echo.
echo events {
echo     worker_connections  1024;
echo }
echo.
echo http {
echo     include       mime.types;
echo     default_type  application/octet-stream;
echo     sendfile        on;
echo     keepalive_timeout  65;
echo.
echo     # Standard HTTP Server
echo     server {
echo         listen       80;
echo         server_name  !SERVER_FQDN!;
echo         location / {
echo             root   html;
echo             index  index.html index.htm;
echo         }
echo     }
) > "!NGINX_CONF!"

:: Loop over ports and write server blocks using label loop to avoid CMD parser bugs
set "TEMP_PORTS=!PROXY_PORTS!"
set ASSIGNED_SSL_PORTS=
:nginx_write_loop
if "!TEMP_PORTS!"=="" goto nginx_write_done
for /f "tokens=1*" %%A in ("!TEMP_PORTS!") do (
    set "CURR_PORT=%%A"
    set "TEMP_PORTS=%%B"
)
call :resolve_ssl_port !CURR_PORT!
(
echo.
echo     # SSL Wrapper for Port !CURR_PORT! -^> !SSL_P!
echo     server {
echo         listen       !SSL_P! ssl;
echo         server_name  !SERVER_FQDN!;
echo.
echo         ssl_certificate      C:/anycert/anycert-server.crt;
echo         ssl_certificate_key  C:/anycert/anycert-server.key;
echo.
echo         location / {
echo             proxy_pass http://127.0.0.1:!CURR_PORT!;
echo             proxy_set_header Host localhost;
echo             proxy_set_header X-Real-IP $remote_addr;
echo             proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
echo             proxy_set_header X-Forwarded-Proto $scheme;
echo             proxy_set_header Upgrade $http_upgrade;
echo             proxy_set_header Connection "upgrade";
echo         }
echo     }
) >> "!NGINX_CONF!"
goto nginx_write_loop
:nginx_write_done

    
    :: Close http block
    echo } >> "!NGINX_CONF!"
    echo   [OK] Nginx configuration written successfully: !NGINX_CONF!
    
    :: Start or reload Nginx
    tasklist | findstr /i "nginx.exe" >nul
    if !errorlevel! neq 0 (
        echo   Starting Nginx daemon...
        cd /d C:\nginx
        start nginx
        echo   [OK] Nginx daemon started successfully!
    ) else (
        echo   Reloading Nginx configuration...
        cd /d C:\nginx
        nginx -s reload >nul 2>&1
        echo   [OK] Nginx configuration reloaded successfully!
    )
    echo.
    if "!ONLY_UPDATE_PORTS!"=="1" goto do_save_and_summary
)

:: ── Import CA locally ────────────────────────────────────────
set /p LOCAL_TRUST=  Do you want to import this Root CA into this Windows Server's local system trust store? [y/N]: 
if /i "!LOCAL_TRUST!"=="y" (
    certutil -addstore -f "Root" "!CA_CRT!" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK] CA certificate successfully imported to local system trust store!
    ) else (
        echo   [ERROR] Failed to import CA certificate to local trust store.
    )
)
echo.

:: ── Check & Enable OpenSSH Server (optional) ─────────────────
set SSHD_STATUS=missing
for /f "usebackq" %%S in (`powershell -NoProfile -Command "if (Get-Service sshd -ErrorAction SilentlyContinue) { if ((Get-Service sshd).Status -eq 'Running') { 'running' } else { 'stopped' } } else { 'missing' }"`) do set "SSHD_STATUS=%%S"

if "!SSHD_STATUS!"=="missing" (
    echo [INFO] Windows built-in OpenSSH Server is not installed on this server.
    echo        Enabling OpenSSH allows clients to automatically download the CA certificate via SCP.
    set /p INSTALL_SSHD=  Do you want to automatically install and enable OpenSSH Server now? [y/N]: 
    if /i "!INSTALL_SSHD!"=="y" (
        echo   Installing OpenSSH Server via PowerShell...
        powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >nul 2>&1
        powershell -NoProfile -Command "Start-Service sshd; Set-Service -Name sshd -StartupType 'Automatic'" >nul 2>&1
        netsh advfirewall firewall add rule name="OpenSSH SSH Server (sshd)" dir=in action=allow protocol=TCP localport=22 >nul 2>&1
        echo   [OK] OpenSSH Server installed and started successfully!
    )
    echo.
) else if "!SSHD_STATUS!"=="stopped" (
    echo [INFO] Windows built-in OpenSSH Server is installed but not running.
    set /p START_SSHD=  Do you want to start the OpenSSH service now and set it to automatic? [y/N]: 
    if /i "!START_SSHD!"=="y" (
        powershell -NoProfile -Command "Start-Service sshd; Set-Service -Name sshd -StartupType 'Automatic'" >nul 2>&1
        netsh advfirewall firewall add rule name="OpenSSH SSH Server (sshd)" dir=in action=allow protocol=TCP localport=22 >nul 2>&1
        echo   [OK] OpenSSH Server started successfully!
    )
    echo.
)


:do_save_and_summary
:: ── Save Config ─────────────────────────────────────────────
(
echo PROFILE=!PROFILE!
echo SERVER_IP=!SERVER_IP!
echo SERVER_FQDN=!SERVER_FQDN!
echo CUSTOM_CERT=!CUSTOM_CERT!
echo CUSTOM_KEY=!CUSTOM_KEY!
echo RELOAD_CMD=!RELOAD_CMD!
echo PROXY_PORTS=!PROXY_PORTS!
) > "!CONF_FILE!"

:: ── Show Summary ────────────────────────────────────────────
echo =====================================================
echo   Certificate Setup Summary
echo =====================================================
echo.
echo   [ Certificate Info ]
echo   Subject FQDN:   !SERVER_FQDN!
echo   Server IP:      !SERVER_IP!
echo   Validity:       825 days (Root CA: 10 years)
echo.
echo   [ File Locations ]
echo   Root CA Certificate (for clients): !CA_CRT!
echo   Root CA Private Key (KEEP IT SECURE):   !CA_KEY!
echo   Server Certificate (CRT):                !SERVER_CRT!
echo   Server Private Key (KEY):                !SERVER_KEY!
if "!PROFILE!"=="custom" (
echo   Applied Certificate Path:              !CUSTOM_CERT!
)
if "!PROFILE!"=="nginx_proxy" (
echo   Nginx Configured File:                 !NGINX_CONF!
)
echo.
if "!PROFILE!"=="nginx_proxy" (
echo   [ Nginx SSL Proxy Port Mappings ]
set "TEMP_PORTS=!PROXY_PORTS!"
set ASSIGNED_SSL_PORTS=
call :show_nginx_summary
echo.
)
echo   [ Client Device Setup Steps ]
echo   1. Download the Root CA certificate on each client device:
echo      scp -o StrictHostKeyChecking=no Administrator@!SERVER_IP!:!CA_CRT:\=/! ./anycert-ca.crt
echo      (Use Windows SSH account to connect, or manually copy the CA file)
echo.
echo   2. Add the following entry to the client's hosts file:
echo      !SERVER_IP!    !SERVER_FQDN!
echo.
echo   3. Connect to the server from your browser using the FQDN:
echo      https://!SERVER_FQDN!:^<port^>
echo.
echo   👉 Recommended: Execute the corresponding client script directly on the client machine:
echo      - Windows: anycert-windows.bat
echo      - Linux:   sudo bash anycert-linux.sh
echo      - macOS:   sudo bash anycert-macos.sh
echo.
echo Installation complete!
pause
exit /b 0

:: ============================================================
::  UNINSTALL MODE
:: ============================================================
:do_uninstall
echo Uninstall Mode - Restoring Original Certificate Settings
echo -----------------------------------------------------
echo.

if not exist "!CONF_FILE!" (
    echo [WARN] Configuration file !CONF_FILE! not found. Only cleaning up default certificate files.
    set PROFILE=none
) else (
    for /f "usebackq delims=" %%A in ("!CONF_FILE!") do set %%A
)

echo [ Files to be removed ]
echo   !CA_KEY!
echo   !CA_CRT!
echo   !SERVER_KEY!
echo   !SERVER_CRT!
echo   !CA_SRL!
echo   !CONF_FILE!
echo.

if "!PROFILE!"=="custom" (
    if not "!CUSTOM_CERT!"=="" (
        :: Find backup cert
        set BACKUP_CERT=
        for /f "delims=" %%F in ('dir /b /o-n "!CUSTOM_CERT!.bak.*" 2^>nul') do (
            if "!BACKUP_CERT!"=="" set BACKUP_CERT=%%F
        )
        if not "!BACKUP_CERT!"=="" (
            echo [ Custom Path Backup Detected - Will Restore ]
            echo   !CUSTOM_CERT! ^<- !BACKUP_CERT!
        ) else (
            echo [ Backup Not Detected - Will Delete Custom Certificate Directly ]
        )
    )
)
echo.
set /p UNINSTALL_CONFIRM=  Are you sure you want to uninstall? [y/N]: 
if /i not "!UNINSTALL_CONFIRM!"=="y" (
    echo Cancelled.
    pause
    exit /b 0
)

:: Restore Custom files
if "!PROFILE!"=="custom" (
    if not "!CUSTOM_CERT!"=="" (
        set DIR_OF_CERT=
        for %%I in ("!CUSTOM_CERT!") do set DIR_OF_CERT=%%~dpI
        if not "!BACKUP_CERT!"=="" (
            copy /y "!DIR_OF_CERT!\!BACKUP_CERT!" "!CUSTOM_CERT!" >nul
            del "!DIR_OF_CERT!\!CUSTOM_CERT!.bak.*" >nul 2>&1
            echo [OK] Restored certificate: !CUSTOM_CERT!
        ) else (
            if exist "!CUSTOM_CERT!" del "!CUSTOM_CERT!"
        )
    )
    if not "!CUSTOM_KEY!"=="" (
        set DIR_OF_KEY=
        for %%I in ("!CUSTOM_KEY!") do set DIR_OF_KEY=%%~dpI
        set BACKUP_KEY=
        for /f "delims=" %%F in ('dir /b /o-n "!CUSTOM_KEY!.bak.*" 2^>nul') do (
            if "!BACKUP_KEY!"=="" set BACKUP_KEY=%%F
        )
        if not "!BACKUP_KEY!"=="" (
            copy /y "!DIR_OF_KEY!\!BACKUP_KEY!" "!CUSTOM_KEY!" >nul
            del "!DIR_OF_KEY!\!CUSTOM_KEY!.bak.*" >nul 2>&1
            echo [OK] Restored private key: !CUSTOM_KEY!
        ) else (
            if exist "!CUSTOM_KEY!" del "!CUSTOM_KEY!"
        )
    )
    if not "!RELOAD_CMD!"=="" (
        echo Running reload command: !RELOAD_CMD!
        cmd /c "!RELOAD_CMD!" >nul 2>&1
    )
)

:: Stop and clean up Nginx if applicable
if "!PROFILE!"=="nginx_proxy" (
    echo Stopping Nginx daemon...
    taskkill /f /im nginx.exe >nul 2>&1
    echo   [OK] Nginx daemon stopped.
    if exist "C:\nginx" (
        echo   Removing Nginx installation folder ^(C:\nginx^)...
        rd /s /q "C:\nginx" >nul 2>&1
        echo   [OK] C:\nginx removed successfully.
    )
)

:: Delete CA/Server keys and folder
if exist "!CA_KEY!" del "!CA_KEY!"
if exist "!CA_CRT!" del "!CA_CRT!"
if exist "!CA_SRL!" del "!CA_SRL!"
if exist "!SERVER_KEY!" del "!SERVER_KEY!"
if exist "!SERVER_CRT!" del "!SERVER_CRT!"
if exist "!CONF_FILE!" del "!CONF_FILE!"

echo.
echo Uninstallation complete.
echo On client machines, run anycert-*.sh -u or anycert-windows.bat -u to remove the CA certificate.
pause
exit /b 0

:resolve_ssl_port
set "P=%~1"
set /a SSL_P=%P%+10000
if !SSL_P! gtr 65535 set /a SSL_P=%P%-10000

:res_loop
set COLLIDED=0
for %%O in (!PROXY_PORTS!) do (
    if !SSL_P! equ %%O set COLLIDED=1
)
for %%A in (!ASSIGNED_SSL_PORTS!) do (
    if !SSL_P! equ %%A set COLLIDED=1
)
if !COLLIDED! equ 1 (
    set /a SSL_P=!SSL_P!+1
    if !SSL_P! gtr 65535 set SSL_P=10000
    goto res_loop
)
set ASSIGNED_SSL_PORTS=!ASSIGNED_SSL_PORTS! !SSL_P!
exit /b 0

:show_nginx_summary
if "!TEMP_PORTS!"=="" exit /b 0
for /f "tokens=1*" %%A in ("!TEMP_PORTS!") do (
    set "CURR_PORT=%%A"
    set "TEMP_PORTS=%%B"
)
call :resolve_ssl_port !CURR_PORT!
echo   - https://!SERVER_FQDN!:!SSL_P!  -^>  HTTP localhost:!CURR_PORT!
goto show_nginx_summary

:process_port_adjustments
:: Check if the input contains '-' using native string replacement
if "!NEW_PROXY_PORTS!"=="!NEW_PROXY_PORTS:-=!" (
    :: No '-' found, simple overwrite
    set "PROXY_PORTS=!NEW_PROXY_PORTS!"
    exit /b 0
)

:: Incremental/decremental adjustment mode
set "ADJUST_INPUT=!NEW_PROXY_PORTS!"
:adjust_loop
if "!ADJUST_INPUT!"=="" exit /b 0
for /f "tokens=1*" %%A in ("!ADJUST_INPUT!") do (
    set "TOKEN=%%A"
    set "ADJUST_INPUT=%%B"
)

set "FIRST_CHAR=!TOKEN:~0,1!"
if "!FIRST_CHAR!"=="-" (
    set "TARGET_PORT=!TOKEN:~1!"
    :: Remove TARGET_PORT from PROXY_PORTS
    set "NEW_LIST="
    for %%P in (!PROXY_PORTS!) do (
        if not "%%P"=="!TARGET_PORT!" (
            if "!NEW_LIST!"=="" (
                set "NEW_LIST=%%P"
            ) else (
                set "NEW_LIST=!NEW_LIST! %%P"
            )
        )
    )
    set "PROXY_PORTS=!NEW_LIST!"
) else (
    set "TARGET_PORT=!TOKEN!"
    if "!FIRST_CHAR!"=="+" set "TARGET_PORT=!TOKEN:~1!"
    :: Add TARGET_PORT to PROXY_PORTS if not already present
    set "ALREADY_HAS=0"
    for %%P in (!PROXY_PORTS!) do (
        if "%%P"=="!TARGET_PORT!" set ALREADY_HAS=1
    )
    if !ALREADY_HAS! equ 0 (
        if "!PROXY_PORTS!"=="" (
            set "PROXY_PORTS=!TARGET_PORT!"
        ) else (
            set "PROXY_PORTS=!PROXY_PORTS! !TARGET_PORT!"
        )
    )
)
goto adjust_loop


