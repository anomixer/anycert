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

:: Define ANSI colors (fully PowerShell-free and locale-safe)
echo WScript.Echo Chr^(27^) > "%temp%\getesc.vbs"
for /f "delims=" %%A in ('cscript //nologo "%temp%\getesc.vbs"') do set "ESC=%%A"
if exist "%temp%\getesc.vbs" del "%temp%\getesc.vbs"
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
echo   Purpose:
echo     Automatically detects the local IP and FQDN, generates a
echo     10-year self-signed Root CA and server certificate, and
echo     installs it into the selected self-hosted service (e.g. Nginx).
echo     Lets browsers connect securely over the LAN with a trusted lock icon.
echo.
echo   Usage:
echo     anycert.bat        # Install certificate
echo     anycert.bat -u     # Uninstall and restore backups
echo.

:: ── Check Administrator privileges ──────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] This script requires Administrator privileges.
    set /p ELEVATE_CONFIRM=  Would you like to elevate to Administrator now? [y/N]: 
    if /i "!ELEVATE_CONFIRM!"=="y" (
        echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
        echo UAC.ShellExecute "cmd.exe", "/c ""%~dp0%~nx0"" %*", "", "runas", 1 >> "%temp%\getadmin.vbs"
        "%temp%\getadmin.vbs"
        del "%temp%\getadmin.vbs"
        exit /b 0
    )
    echo [ERROR] Administrator privileges are required to run this script.
    echo.
    pause
    exit /b 1
)

:: ── Find OpenSSL (now moved to the top) ─────────────────────────
set OPENSSL_BIN=
where openssl >nul 2>&1
if %errorlevel% equ 0 (
    set OPENSSL_BIN=openssl
    goto openssl_ok
)
if exist "C:\PROGRA~1\Git\usr\bin\openssl.exe" (
    set OPENSSL_BIN=C:\PROGRA~1\Git\usr\bin\openssl.exe
    goto openssl_ok
)
if exist "C:\PROGRA~2\Git\usr\bin\openssl.exe" (
    set OPENSSL_BIN=C:\PROGRA~2\Git\usr\bin\openssl.exe
    goto openssl_ok
)
echo [WARN] openssl executable not found!
echo We can automatically install Git for Windows (built-in OpenSSL) via winget.
set /p INSTALL_GIT=  Do you want to automatically install Git? [y/N]: 
if /i "!INSTALL_GIT!"=="y" (
    echo Installing Git for Windows via winget. Please allow installation in the UAC popup...
    winget install -e --id Git.Git
    if not errorlevel 1 (
        echo   [OK] Git installation complete! Refreshing path...
        where openssl >nul 2>&1
        if not errorlevel 1 (
            set OPENSSL_BIN=openssl
            goto openssl_ok
        )
        if exist "C:\PROGRA~1\Git\usr\bin\openssl.exe" (
            set OPENSSL_BIN=C:\PROGRA~1\Git\usr\bin\openssl.exe
            goto openssl_ok
        )
        if exist "C:\PROGRA~2\Git\usr\bin\openssl.exe" (
            set OPENSSL_BIN=C:\PROGRA~2\Git\usr\bin\openssl.exe
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

:: ── Paths ───────────────────────────────────────────────────
set CONF_DIR=C:\anycert
if not exist "!CONF_DIR!" mkdir "!CONF_DIR!"
set CONF_FILE=!CONF_DIR!\anycert.conf
set CA_KEY=!CONF_DIR!\anycert-ca.key
set CA_CRT=!CONF_DIR!\anycert-ca.crt
set CA_SRL=!CONF_DIR!\anycert-ca.srl
set SERVER_KEY=!CONF_DIR!\anycert-server.key
set SERVER_CRT=!CONF_DIR!\anycert-server.crt
set PORT_OFFSET=10000

if /i "%~1"=="-u" goto do_uninstall

:: Load existing configurations if present
if exist "!CONF_FILE!" (
    for /f "usebackq delims=" %%A in ("!CONF_FILE!") do set %%A
)
call :sanitize_proxyports

:: ── Check existing certificate ──────────────────────────────
if not exist "!SERVER_CRT!" goto after_existing_check

echo An existing certificate setup is detected.
echo -----------------------------------------------------
set "CERT_SUBJ="
for /f "tokens=2 delims==" %%S in ('!OPENSSL_BIN! x509 -noout -subject -in "!SERVER_CRT!"') do set "CERT_SUBJ=%%S"
set "CERT_ENDDATE="
for /f "tokens=2 delims==" %%D in ('!OPENSSL_BIN! x509 -noout -enddate -in "!SERVER_CRT!"') do set "CERT_ENDDATE=%%D"
!OPENSSL_BIN! x509 -checkend 2592000 -noout -in "!SERVER_CRT!" >nul 2>&1
if !errorlevel! neq 0 (
    set "CERT_STATUS=Expiring soon or expired"
) else (
    set "CERT_STATUS=Valid"
)

echo   Subject/FQDN : !CERT_SUBJ!
echo   Expiry Date  : !CERT_ENDDATE! (!CERT_STATUS!)
echo   Current Profile : !PROFILE!
if "!PROFILE!"=="nginx_proxy" (
    echo   Current Mapped Ports : !PROXY_PORTS!
    echo   Current HTTPS Offset: !PORT_OFFSET!
)
echo.
if "!CERT_STATUS!"=="Expiring soon or expired" (
    echo   !YELLOW![WARN] This certificate is expiring soon or has expired!!RESET!
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
echo.
echo   Quick guide:
echo     - To overwrite all: just type the new list, like: 3000 8080
echo     - To add more: put + in front, like: +8080 +9090
echo     - To remove: put - in front, like: -3000
echo.
    set /p NEW_PROXY_PORTS=  What ports should I wrap in SSL now? 
    if not "!NEW_PROXY_PORTS!"=="" (
        call :process_port_adjustments
    )
    call :sanitize_proxyports
    set PROFILE=nginx_proxy
set ONLY_UPDATE_PORTS=1
goto do_deploy_nginx_proxy

:do_renew_cert
echo.
echo [Renewing Certificate] Keep current port configurations and regenerate files...
echo.
set ONLY_RENEW=1

:after_existing_check

:: ============================================================
::  INSTALL MODE
:: ============================================================


:: ── Detect network info ──────────────────────────────────────
echo [1/6] Auto-detecting network configurations...
echo -----------------------------------------------------

:: Detect IP using native ipconfig (fully PowerShell-free)
set SERVER_IP=
set SKIP_ADAPTER=0
for /f "usebackq delims=" %%L in (`ipconfig`) do (
    set "LINE=%%L"
    :: Check if line starts an adapter section (supports English and Chinese Windows)
    echo !LINE! | findstr /i "adapter 卡" >nul
    if not errorlevel 1 (
        set "SKIP_ADAPTER=0"
        :: Filter out virtual adapters
        for %%V in (VMware VirtualBox vEthernet WSL Tailscale Loopback Pseudo) do (
            echo !LINE! | findstr /i "%%V" >nul
            if not errorlevel 1 set "SKIP_ADAPTER=1"
        )
    )
    if "!SKIP_ADAPTER!"=="0" (
        echo !LINE! | findstr /i "IPv4" >nul
        if not errorlevel 1 (
            for /f "tokens=2 delims=:" %%A in ("!LINE!") do (
                set "TEMP_IP=%%A"
                set "TEMP_IP=!TEMP_IP: =!"
                for /f "delims=" %%I in ("!TEMP_IP!") do set "SERVER_IP=%%I"
            )
        )
    )
)
if "!SERVER_IP!"=="" set SERVER_IP=127.0.0.1

:: Detect Hostname & FQDN using registry (fully PowerShell-free)
set SERVER_HOSTNAME=%COMPUTERNAME%
set SERVER_FQDN=
set REG_DOM=
set REG_NV_DOM=
for /f "tokens=3" %%A in ('REG QUERY "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v "Domain" 2^>nul') do set "REG_DOM=%%A"
for /f "tokens=3" %%A in ('REG QUERY "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v "NV Domain" 2^>nul') do set "REG_NV_DOM=%%A"

if not "!REG_DOM!"=="" (
    set SERVER_FQDN=!SERVER_HOSTNAME!.!REG_DOM!
) else if not "!REG_NV_DOM!"=="" (
    set SERVER_FQDN=!SERVER_HOSTNAME!.!REG_NV_DOM!
) else (
    set SERVER_FQDN=!SERVER_HOSTNAME!
)

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
echo   (Tip: you can enter additional IPs e.g. Tailscale/VPN IPs)
set /p EXTRA_IPS=  Additional IP Addresses (optional, space-separated): 

set /p INPUT_FQDN=  Server DNS Name (FQDN) [!SERVER_FQDN!]: 
if not "!INPUT_FQDN!"=="" set SERVER_FQDN=!INPUT_FQDN!
echo.

:: ── Choose profile ──────────────────────────────────────────
if "!ONLY_RENEW!"=="1" goto renew_skip_profile
echo [3/6] Please choose the Service Profile to apply
echo -----------------------------------------------------
echo   [1] Auto-Setup Nginx SSL Proxy (Port-Offset Wrapper) [Lazy-Friendly / Recommended]
echo       - Installs Nginx and automatically wraps your HTTP ports in SSL
echo       - Keeps your existing apps running on HTTP, proxies to SSL Port + 10000 (configurable)
echo.
echo   [2] Custom Path (Auto-Deploy)
echo       - Copies certificates to your service folders (e.g. IIS, Nginx, Apache, Emby, Plex, Docker, etc.)
echo       - Can automatically run a reload command to apply changes
echo.
echo   [3] Generate Only (Manual Deploy) [Painful / Hard Way]
echo       - Generates cert files in C:\anycert\ only
echo       - Requires manual configuration for all your services
echo.
:choose_profile_loop
set /p PROFILE_CHOICE=  Please choose [1-3, default: 1]: 
if "!PROFILE_CHOICE!"=="" set PROFILE_CHOICE=1

if not "!PROFILE_CHOICE!"=="1" if not "!PROFILE_CHOICE!"=="2" if not "!PROFILE_CHOICE!"=="3" (
    echo [WARN] Invalid choice, please try again.
    echo.
    goto choose_profile_loop
)

set PROFILE=none
if "!PROFILE_CHOICE!"=="1" set PROFILE=nginx_proxy
if "!PROFILE_CHOICE!"=="2" set PROFILE=custom
if "!PROFILE_CHOICE!"=="3" set PROFILE=none

set CUSTOM_CERT=
set CUSTOM_KEY=
set RELOAD_CMD=
set PROXY_PORTS=

if "!PROFILE!"=="custom" goto do_profile_custom
if "!PROFILE!"=="nginx_proxy" goto do_profile_nginx_proxy
goto do_ask_proceed

:renew_skip_profile
echo [3/6] Reusing existing Service Profile: !PROFILE!
echo -----------------------------------------------------
if "!PROFILE!"=="nginx_proxy" echo   Nginx SSL Proxy ports: !PROXY_PORTS! ^(HTTPS offset: !PORT_OFFSET!^)
if "!PROFILE!"=="custom" (
    echo   Custom CRT: !CUSTOM_CERT!
    echo   Custom KEY: !CUSTOM_KEY!
)
echo.
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

:: Precompute example values for display (based on default/current offset)
set /a OFFSET_THRESHOLD=65536-!PORT_OFFSET!
set /a OFFSET_EXAMPLE=3000+!PORT_OFFSET!
set /a OFFSET_SUB=60000-!PORT_OFFSET!

:: Detect active local TCP ports (probe HTTP only & sort)
echo   Scanning local ports, please wait...
set DETECTED_PORTS=
for /f "tokens=2" %%A in ('netstat -ano ^| findstr /i "listening"') do (
    set "ADDR=%%A"
    set "T=!ADDR!"
    set "T=!T::= !"
    for %%P in (!T!) do set "CURR_P=%%P"
    
    :: Clean brackets just in case
    set "CURR_P=!CURR_P:[=!"
    set "CURR_P=!CURR_P:]=!"
    
    :: Basic numeric validation (ensure it is a number)
    set "IS_NUM=1"
    for /f "delims=0123456789" %%K in ("!CURR_P!") do set "IS_NUM=0"
    
    if "!IS_NUM!"=="1" (
        if !CURR_P! gtr 80 (
            if not "!CURR_P!"=="135" if not "!CURR_P!"=="445" if not "!CURR_P!"=="5357" (
                set "PORT_EXISTS="
                for %%D in (!DETECTED_PORTS!) do (
                    if "%%D"=="!CURR_P!" set "PORT_EXISTS=1"
                )
                if not "!PORT_EXISTS!"=="1" (
                    :: Probe if it is actually HTTP protocol
                    set "IS_HTTP=0"
                    for /f "usebackq" %%C in (`curl -s -w "%%{http_code}" -o nul --connect-timeout 0.2 --max-time 0.5 http://127.0.0.1:!CURR_P!`) do (
                        set "HTTP_CODE=%%C"
                        if not "!HTTP_CODE!"=="000" if not "!HTTP_CODE!"=="" set "IS_HTTP=1"
                    )
                    if "!IS_HTTP!"=="1" (
                        set "DETECTED_PORTS=!DETECTED_PORTS! !CURR_P!"
                    )
                )
            )
        )
    )
)

:: Bubble Sort the DETECTED_PORTS
set "PORT_COUNT=0"
for %%A in (!DETECTED_PORTS!) do (
    set /a PORT_COUNT+=1
    set "PORT_ARR_!PORT_COUNT!=%%A"
)
if !PORT_COUNT! gtr 1 (
    set /a MAX_IDX=PORT_COUNT-1
    for /l %%I in (1,1,!MAX_IDX!) do (
        set /a NEXT_I=%%I+1
        for /l %%J in (!NEXT_I!,1,!PORT_COUNT!) do (
            if !PORT_ARR_%%I! gtr !PORT_ARR_%%J! (
                set "TEMP=!PORT_ARR_%%I!"
                set "PORT_ARR_%%I=!PORT_ARR_%%J!"
                set "PORT_ARR_%%J=!TEMP!"
            )
        )
    )
)
:: Rebuild sorted DETECTED_PORTS
set "DETECTED_PORTS="
for /l %%I in (1,1,!PORT_COUNT!) do (
    set "DETECTED_PORTS=!DETECTED_PORTS! !PORT_ARR_%%I!"
)
if not "!DETECTED_PORTS!"=="" (
    for /f "tokens=* delims= " %%A in ("!DETECTED_PORTS!") do set "DETECTED_PORTS=%%A"
)

set EXISTING_PORTS=
if exist "!CONF_FILE!" (
    for /f "usebackq delims=" %%A in ("!CONF_FILE!") do (
        for /f "tokens=1,2 delims==" %%I in ("%%A") do (
            if "%%I"=="PROXY_PORTS" set "EXISTING_PORTS=%%J"
        )
    )
)

if "!EXISTING_PORTS!"=="" goto do_nginx_no_existing

echo   You already have these HTTP ports mapped:
echo     !EXISTING_PORTS!
echo.
echo   What do you want to do?
echo     [1] Keep them as-is [Default]
echo     [2] Add more ports
echo     [3] Remove some ports
echo     [4] Start over with a new list
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
    echo   [TIP] I found these ports listening on your machine: !DETECTED_PORTS!
)
echo   I will add HTTPS access to each port you give me, on port ^(that port + !PORT_OFFSET!^).
echo   For example: port 3000 will get a HTTPS wrapper on port !OFFSET_EXAMPLE!.
echo   ^(If a port is too large, I subtract !PORT_OFFSET! instead, e.g. 60000 -> !OFFSET_SUB!.^)
set /p NEW_PORTS=  Which extra ports do you want to expose via HTTPS? ^(space-separated^): 
set "PROXY_PORTS=!EXISTING_PORTS!"
for %%P in (!NEW_PORTS!) do (
    set "PORT_EXISTS="
    for %%D in (!PROXY_PORTS!) do (
        if "%%D"=="%%P" set "PORT_EXISTS=1"
    )
    if not "!PORT_EXISTS!"=="1" (
        set "PROXY_PORTS=!PROXY_PORTS! %%P"
    )
)
goto do_nginx_ports_decision_done

:do_opt_remove
set /p REMOVE_PORTS=  Enter HTTP ports to remove (space-separated): 
set "PROXY_PORTS="
for %%P in (!EXISTING_PORTS!) do (
    set "PORT_REMOVE="
    for %%R in (!REMOVE_PORTS!) do (
        if "%%R"=="%%P" set "PORT_REMOVE=1"
    )
    if not "!PORT_REMOVE!"=="1" (
        set "PROXY_PORTS=!PROXY_PORTS! %%P"
    )
)
goto do_nginx_ports_decision_done

:do_opt_overwrite
if not "!DETECTED_PORTS!"=="" (
    echo   [TIP] I found these ports listening on your machine: !DETECTED_PORTS!
)
echo   I will add HTTPS access to each port you give me, on port ^(that port + !PORT_OFFSET!^).
echo   For example: port 3000 will get a HTTPS wrapper on port !OFFSET_EXAMPLE!.
echo   ^(If a port is too large, I subtract !PORT_OFFSET! instead, e.g. 60000 -> !OFFSET_SUB!.^)
set /p NEW_LIST=  What ports do you want to expose via HTTPS? ^(space-separated^): 
set "PROXY_PORTS=!NEW_LIST!"
goto do_nginx_ports_decision_done

:do_nginx_ports_decision_done
goto do_nginx_ports_done

:do_nginx_no_existing
if not "!DETECTED_PORTS!"=="" (
    echo   [TIP] I found these ports listening on your machine: !DETECTED_PORTS!
)
echo   Tell me which of your local services should be accessible via HTTPS.
echo   I will add a secure HTTPS wrapper on port ^(your_port + !PORT_OFFSET!^).
echo   For example: if you have a service on port 3000, I will make it available
echo   on https://localhost:!OFFSET_EXAMPLE! ^(3000 + !PORT_OFFSET!^).
echo   ^(For high ports ^>= !OFFSET_THRESHOLD! I subtract !PORT_OFFSET! instead.^)
echo   Type the ports separated by spaces, like: 3000 6000 11434
set /p PROXY_PORTS=  Which local HTTP services should get HTTPS access? ^(space-separated^): 

:do_nginx_ports_done
call :sanitize_proxyports

:: ── HTTPS port offset (user customizable, default 10000) ──
echo.
echo   HTTPS ^(SSL^) port offset: HTTPS port = HTTP port + offset.
echo   Default is !PORT_OFFSET! ^(the HTTPS port for 3000 is !OFFSET_EXAMPLE!^).
set /p INPUT_OFFSET=  Enter HTTPS port offset [default: !PORT_OFFSET!]: 
if "!INPUT_OFFSET!"=="" set INPUT_OFFSET=!PORT_OFFSET!
set /a PORT_OFFSET=!INPUT_OFFSET! 2>nul
if !PORT_OFFSET! lss 1 set PORT_OFFSET=10000
if !PORT_OFFSET! gtr 65535 set PORT_OFFSET=10000
set /a OFFSET_THRESHOLD=65536-!PORT_OFFSET!
set /a OFFSET_EXAMPLE=3000+!PORT_OFFSET!
set /a OFFSET_SUB=60000-!PORT_OFFSET!
echo.

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
    echo      !PROXY_PORTS! ^(SSL ports: Original + !PORT_OFFSET!^)
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

:: Build SAN IP list (primary + extra IPs)
set SAN_IPS=IP:!SERVER_IP!,IP:127.0.0.1
set EXTRA_IPS_REMAIN=!EXTRA_IPS!
:san_extra_loop
if "!EXTRA_IPS_REMAIN!"=="" goto san_extra_done
for /f "tokens=1*" %%A in ("!EXTRA_IPS_REMAIN!") do (
    set SAN_ONE=%%A
    set EXTRA_IPS_REMAIN=%%B
)
if "!SAN_ONE!"=="!SERVER_IP!" goto san_extra_loop
if "!SAN_ONE!"=="127.0.0.1" goto san_extra_loop
set SAN_IPS=!SAN_IPS!,IP:!SAN_ONE!
goto san_extra_loop
:san_extra_done

(
echo subjectAltName=DNS:!SERVER_FQDN!,DNS:localhost,!SAN_IPS!
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
:: Generate timestamp for backup (fully PowerShell-free)
echo WScript.Echo Year^(Now^)^&Right^("0"^&Month^(Now^),2^)^&Right^("0"^&Day^(Now^),2^)^&Right^("0"^&Hour^(Now^),2^)^&Right^("0"^&Minute^(Now^),2^)^&Right^("0"^&Second^(Now^),2^) > "%temp%\getts.vbs"
for /f %%T in ('C:\Windows\System32\cscript.exe //nologo "%temp%\getts.vbs"') do set "TS=%%T"
if exist "%temp%\getts.vbs" del "%temp%\getts.vbs"

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
    set RUN_RELOAD=1
    echo !RELOAD_CMD! | findstr /i "nginx" >nul
    if not errorlevel 1 (
        if not exist "C:\nginx\nginx.exe" (
            echo   [WARN] The reload command references nginx, but nginx was not found at C:\nginx\nginx.exe.
            echo   [WARN] Skipping reload command. Please install Nginx first or correct the command.
            set RUN_RELOAD=0
        )
    )
    if !RUN_RELOAD! equ 1 (
        echo   Executing service reload command: !RELOAD_CMD!
        cmd /c "!RELOAD_CMD!"
        if not errorlevel 1 (
            echo   [OK] Reload command executed successfully!
        ) else (
            echo   [WARN] Reload command failed. Please check the service status.
        )
    )
)
echo.
goto do_post_install

:do_deploy_nginx_proxy
echo Deploying and configuring Nginx Reverse Proxy...
echo -----------------------------------------------------

:: Check/Install Nginx
set "NGINX_DIR=C:\nginx"
if exist "C:\nginx\nginx.exe" (
    echo   [INFO] Using existing Nginx at C:\nginx\
    goto nginx_installed
)

echo   [INFO] Nginx not found at C:\nginx\nginx.exe.
echo          Automatically downloading Nginx 1.26.1 stable zip...
curl.exe -L -o "!CONF_DIR!\nginx.zip" "https://nginx.org/download/nginx-1.26.1.zip"
if %errorlevel% neq 0 goto nginx_download_fail

echo   Extracting Nginx...
pushd "!CONF_DIR!"
    C:\Windows\System32\tar.exe -xf nginx.zip
popd
if not exist "!CONF_DIR!\nginx-1.26.1" goto nginx_extract_fail

if exist "C:\nginx" rd /s /q "C:\nginx" >nul 2>&1
move "!CONF_DIR!\nginx-1.26.1" "C:\nginx" >nul 2>&1
if not exist "C:\nginx\nginx.exe" goto nginx_move_fail

echo   [OK] Nginx successfully installed to C:\nginx!
del "!CONF_DIR!\nginx.zip" >nul 2>&1
goto nginx_installed

:nginx_download_fail
echo   [ERROR] Failed to download Nginx zip.
goto nginx_fail_common

:nginx_extract_fail
echo   [ERROR] Failed to find extracted Nginx files.
goto nginx_fail_common

:nginx_move_fail
echo   [ERROR] Failed to move Nginx files to C:\nginx.
goto nginx_fail_common

:nginx_fail_common
echo          If this is an offline environment, please manually download Nginx from:
echo            https://nginx.org/en/download.html
echo          And extract it so that C:\nginx\nginx.exe exists, then run this script again.
pause
exit /b 1

:nginx_installed


:: Create clean config
if not exist "!NGINX_DIR!\conf" mkdir "!NGINX_DIR!\conf" >nul 2>&1
set NGINX_CONF=!NGINX_DIR!\conf\nginx.conf

:: Build Nginx server_name list (FQDN + primary IP + extra IPs + localhost)
set NGINX_SERVER_NAMES=!SERVER_FQDN! !SERVER_IP!
for %%E in (!EXTRA_IPS!) do (
    if not "%%E"=="!SERVER_IP!" if not "%%E"=="127.0.0.1" (
        set NGINX_SERVER_NAMES=!NGINX_SERVER_NAMES! %%E
    )
)
set NGINX_SERVER_NAMES=!NGINX_SERVER_NAMES! localhost 127.0.0.1

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
echo         server_name  !NGINX_SERVER_NAMES!;
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
echo         server_name  !NGINX_SERVER_NAMES!;
echo.
echo         ssl_certificate      C:/anycert/anycert-server.crt;
echo         ssl_certificate_key  C:/anycert/anycert-server.key;
echo.
echo         location / {
echo             proxy_pass http://127.0.0.1:!CURR_PORT!;
echo             proxy_set_header Host $http_host;
echo             proxy_set_header X-Real-IP $remote_addr;
echo             proxy_redirect http:// https://;
echo             proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
echo             proxy_set_header X-Forwarded-Proto $scheme;
echo             proxy_set_header X-Forwarded-Port $server_port;
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

:: Test configuration first
echo   Testing Nginx configuration...
cd /d "!NGINX_DIR!"
.\nginx.exe -t >nul 2>&1
if errorlevel 1 (
    echo   [ERROR] Nginx configuration test failed! Please check:
    .\nginx.exe -t
    pause
    exit /b 1
)

:: Start or reload Nginx
tasklist | findstr /i "nginx.exe" >nul
if errorlevel 1 (
    echo   Starting Nginx daemon...
    cd /d "!NGINX_DIR!"
    start nginx.exe
    echo   [OK] Nginx daemon started successfully!
) else (
    echo   Reloading Nginx configuration...
    cd /d "!NGINX_DIR!"
    .\nginx.exe -s reload >nul 2>&1
    echo   [OK] Nginx configuration reloaded successfully!
)
echo.
if "!ONLY_UPDATE_PORTS!"=="1" goto do_save_and_summary

:: ── Import CA locally ────────────────────────────────────────
:do_post_install
echo   [INFO] Import this Root CA into this Windows Server's local system trust store for local browser access.
set /p LOCAL_TRUST=  Do you want to import? [y/N]: 
if /i "!LOCAL_TRUST!"=="y" (
    certutil -addstore -f "Root" "!CA_CRT!" >nul 2>&1
    if not errorlevel 1 (
        echo   [OK] CA certificate successfully imported to local system trust store!
    ) else (
        echo   [ERROR] Failed to import CA certificate to local trust store.
    )
)
echo.

:: ── Check & Enable OpenSSH Server (optional) ─────────────────
set SSHD_STATUS=missing
sc query sshd >nul 2>&1
if not errorlevel 1 set SSHD_STATUS=stopped
sc query sshd 2>nul | findstr /i "RUNNING" >nul
if not errorlevel 1 set SSHD_STATUS=running

if "!SSHD_STATUS!"=="missing" goto sshd_missing_flow
if "!SSHD_STATUS!"=="stopped" goto sshd_stopped_flow
goto after_sshd_flow

:sshd_missing_flow
echo [INFO] Windows built-in OpenSSH Server is not installed on this server.
echo        Enabling OpenSSH allows clients to automatically download the CA certificate via SCP.
set /p INSTALL_SSHD=  Do you want to automatically install and enable OpenSSH Server now? [y/N]: 
if /i not "!INSTALL_SSHD!"=="y" goto after_sshd_flow

echo   Installing OpenSSH Server via DISM (please wait)...
dism /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 >nul 2>&1
sc config sshd start= auto >nul 2>&1
net start sshd >nul 2>&1
netsh advfirewall firewall add rule name="OpenSSH SSH Server (sshd)" dir=in action=allow protocol=TCP localport=22 >nul 2>&1
echo   [OK] OpenSSH Server installed and started successfully!
echo.
goto after_sshd_flow

:sshd_stopped_flow
echo [INFO] Windows built-in OpenSSH Server is installed but not running.
set /p START_SSHD=  Do you want to start the OpenSSH service now and set it to automatic? [y/N]: 
if /i not "!START_SSHD!"=="y" goto after_sshd_flow

sc config sshd start= auto >nul 2>&1
net start sshd >nul 2>&1
netsh advfirewall firewall add rule name="OpenSSH SSH Server (sshd)" dir=in action=allow protocol=TCP localport=22 >nul 2>&1
echo   [OK] OpenSSH Server started successfully!
echo.

:after_sshd_flow


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
echo PORT_OFFSET=!PORT_OFFSET!
) > "!CONF_FILE!"

:: ── Extract certificate details for summary ───────────────
set "CRT_SUBJECT="
set "CRT_ISSUER="
set "CRT_START="
set "CRT_END="
set "CRT_FP="
set "CRT_SAN="
set "CA_START="
set "CA_END="
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !SERVER_CRT! -noout -subject 2^>nul') do set "CRT_SUBJECT=%%B"
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !SERVER_CRT! -noout -issuer 2^>nul') do set "CRT_ISSUER=%%B"
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !SERVER_CRT! -noout -startdate 2^>nul') do set "CRT_START=%%B"
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !SERVER_CRT! -noout -enddate 2^>nul') do set "CRT_END=%%B"
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !SERVER_CRT! -noout -fingerprint -sha256 2^>nul') do set "CRT_FP=%%B"
for /f "tokens=* delims=" %%A in ('!OPENSSL_BIN! x509 -in !SERVER_CRT! -noout -ext subjectAltName 2^>nul ^| findstr /i "DNS:"') do set "CRT_SAN=%%A"
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !CA_CRT! -noout -startdate 2^>nul') do set "CA_START=%%B"
for /f "tokens=1* delims==" %%A in ('!OPENSSL_BIN! x509 -in !CA_CRT! -noout -enddate 2^>nul') do set "CA_END=%%B"
for /f "tokens=*" %%S in ("!CRT_SAN!") do set "CRT_SAN=%%S"
if "!CRT_SAN!"=="" set "CRT_SAN=N/A"

:: Compute total validity in days from start/end dates
call :date_to_days "!CRT_START!"
set "START_JDN=!JDN!"
call :date_to_days "!CRT_END!"
set /a VALIDITY_DAYS=!JDN! - !START_JDN!
call :date_to_days "!CA_START!"
set "CA_START_JDN=!JDN!"
call :date_to_days "!CA_END!"
set /a CA_VALIDITY_DAYS=!JDN! - !CA_START_JDN!

:: ── Show Summary ────────────────────────────────────────────
echo =====================================================
echo   Certificate Setup Summary
echo =====================================================
echo.
echo   [ Certificate Info ]
echo   Subject:               !CRT_SUBJECT!
echo   Issuer:                !CRT_ISSUER!
echo   Validity From:         !CRT_START!
echo   Validity Until:        !CRT_END!
echo   Validity:              !VALIDITY_DAYS! days
echo   Root CA Validity:     !CA_VALIDITY_DAYS! days
echo   SAN Contents:          !CRT_SAN!
echo   SHA256 Fingerprint:    !CRT_FP!
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
echo   --------------------------------------------
echo   [ Client Device Setup Steps ]
echo   Option A: Manual
echo.
echo     1. Download the Root CA certificate on each client device:
echo        scp -o StrictHostKeyChecking=no Administrator@!SERVER_IP!:!CA_CRT:\=/! ./anycert-ca.crt
echo        (Use Windows SSH account to connect, or manually copy the CA file)
echo.
echo     2. Add the following entry to the client's hosts file:
echo        !SERVER_IP!    !SERVER_FQDN!
echo.
echo     3. Connect to the server from your browser using the FQDN:
echo        https://!SERVER_FQDN!:^<port^>
echo.
echo   Option B: Automatic
echo.
echo     👉 Recommended: Execute the corresponding client script directly on the client machine:
echo        - Windows: anycert-windows.bat
echo        - Linux:   sudo bash anycert-linux.sh
echo        - macOS:   sudo bash anycert-macos.sh
echo.
echo Installation complete!
pause
exit /b 0

:: ============================================================
::  Helper: convert "Mmm DD HH:MM:SS YYYY GMT" to Julian Day Number (sets JDN)
:: ============================================================
:date_to_days
set "dt_ds=%~1"
set "dt_mabbr=!dt_ds:~0,3!"
set "dt_rest=!dt_ds:~4!"
for /f "tokens=1,3" %%a in ("!dt_rest!") do (
    set "dt_dd=%%a"
    set "dt_yyyy=%%b"
)
set "dt_mm=0"
if /i "!dt_mabbr!"=="Jan" set "dt_mm=1"
if /i "!dt_mabbr!"=="Feb" set "dt_mm=2"
if /i "!dt_mabbr!"=="Mar" set "dt_mm=3"
if /i "!dt_mabbr!"=="Apr" set "dt_mm=4"
if /i "!dt_mabbr!"=="May" set "dt_mm=5"
if /i "!dt_mabbr!"=="Jun" set "dt_mm=6"
if /i "!dt_mabbr!"=="Jul" set "dt_mm=7"
if /i "!dt_mabbr!"=="Aug" set "dt_mm=8"
if /i "!dt_mabbr!"=="Sep" set "dt_mm=9"
if /i "!dt_mabbr!"=="Oct" set "dt_mm=10"
if /i "!dt_mabbr!"=="Nov" set "dt_mm=11"
if /i "!dt_mabbr!"=="Dec" set "dt_mm=12"
set /a "dt_a=(14-dt_mm)/12"
set /a "dt_y=dt_yyyy+4800-dt_a"
set /a "dt_m=dt_mm+12*dt_a-3"
set /a "JDN=dt_dd+(153*dt_m+2)/5+365*dt_y+dt_y/4-dt_y/100+dt_y/400-32045"
goto :eof

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
set /a SSL_P=%P%+!PORT_OFFSET!
if !SSL_P! gtr 65535 set /a SSL_P=%P%-!PORT_OFFSET!

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
    if !SSL_P! gtr 65535 set SSL_P=!PORT_OFFSET!
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

:sanitize_proxyports
set "SP_TMP="
if "!PROXY_PORTS!"=="" exit /b 0
for %%P in (!PROXY_PORTS!) do (
    set "SP_T=%%P"
    if "!SP_T:~0,1!"=="+" set "SP_T=!SP_T:~1!"
    if "!SP_T:~0,1!"=="-" set "SP_T=!SP_T:~1!"
    if "!SP_T:~0,1!"==":" set "SP_T=!SP_T:~1!"
    if "!SP_TMP!"=="" (set "SP_TMP=!SP_T!") else (set "SP_TMP=!SP_TMP! !SP_T!")
)
set "PROXY_PORTS=!SP_TMP!"
goto :sort_proxyports
exit /b 0

:sort_proxyports
if "!PROXY_PORTS!"=="" exit /b 0
:: Numeric bubble sort using a dummy nth loop trick
set "SRT_NEXT=!PROXY_PORTS!"
set "SRT_RES="
:srt_outer
if "!SRT_NEXT!"=="" goto srt_finish
:: Find the smallest number in SRT_NEXT
set "SRT_MIN=99999"
set "SRT_NEW="
for %%P in (!SRT_NEXT!) do (
   if %%P lss !SRT_MIN! set "SRT_MIN=%%P"
)
:: Rebuild SRT_NEXT excluding SRT_MIN (first occurrence only)
set "SRT_SKIPPED=0"
for %%P in (!SRT_NEXT!) do (
   if !SRT_SKIPPED! equ 0 if "%%P"=="!SRT_MIN!" (set "SRT_SKIPPED=1") else (
      if "!SRT_NEW!"=="" (set "SRT_NEW=%%P") else (set "SRT_NEW=!SRT_NEW! %%P")
   )
   if !SRT_SKIPPED! equ 1 if not "%%P"=="!SRT_MIN!" (
      if "!SRT_NEW!"=="" (set "SRT_NEW=%%P") else (set "SRT_NEW=!SRT_NEW! %%P")
   )
)
set "SRT_NEXT=!SRT_NEW!"
if "!SRT_RES!"=="" (set "SRT_RES=!SRT_MIN!") else (set "SRT_RES=!SRT_RES! !SRT_MIN!")
goto srt_outer
:srt_finish
set "PROXY_PORTS=!SRT_RES!"
exit /b 0

:process_port_adjustments
:: Check if the input contains '+' or '-' using native string replacement
if "!NEW_PROXY_PORTS!"=="!NEW_PROXY_PORTS:-=!" if "!NEW_PROXY_PORTS!"=="!NEW_PROXY_PORTS:+=!" (
    :: Neither '+' nor '-' found, simple overwrite
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
) else (
    set "TARGET_PORT=!TOKEN!"
    if "!FIRST_CHAR!"=="+" set "TARGET_PORT=!TOKEN:~1!"
)
:: Strip all remaining leading +, -, : prefixes from TARGET_PORT
if "!TARGET_PORT:~0,1!"=="+" set "TARGET_PORT=!TARGET_PORT:~1!"
if "!TARGET_PORT:~0,1!"=="-" set "TARGET_PORT=!TARGET_PORT:~1!"
if "!TARGET_PORT:~0,1!"==":" set "TARGET_PORT=!TARGET_PORT:~1!"

if "!FIRST_CHAR!"=="-" (
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


