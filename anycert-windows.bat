@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

:: ============================================================
:: anycert-windows.bat  —  Anycert Client Certificate Installer
:: Usage:
::   anycert-windows.bat       Install cert, update hosts
::   anycert-windows.bat -u    Uninstall cert, remove hosts entry
:: Run as Administrator
:: Supports multiple anycert sites
:: ============================================================

title Anycert Client Certificate Installer

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
echo !CYAN!                      anycert-windows.bat (Windows Client) !RESET!
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

:: ── Persistent storage folder ────────────────────────────────
set DATA_DIR=%ProgramData%\anycert
if not exist "!DATA_DIR!" mkdir "!DATA_DIR!"
set INFO_FILE=!DATA_DIR!\anycert-info.txt

if /i "%~1"=="-u" goto do_uninstall

:: ============================================================
::  INSTALL MODE
:: ============================================================

set HAS_SERVERS=0
if exist "!INFO_FILE!" (
    for /f "tokens=1,2" %%A in (!INFO_FILE!) do set HAS_SERVERS=1
)

if not "!HAS_SERVERS!"=="1" goto do_skip_menu

echo   Currently registered Anycert servers:
echo   -----------------------------------
for /f "tokens=1,2" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
echo.
echo Please select an action:
echo   [1] Add/Import a new certificate [Default]
echo   [2] Remove/Uninstall an existing certificate
echo   [3] Exit
echo.
set /p CLIENT_ACTION=  Please choose [1-3, default: 1]: 
if "!CLIENT_ACTION!"=="" set CLIENT_ACTION=1
if "!CLIENT_ACTION!"=="2" goto do_uninstall
if "!CLIENT_ACTION!"=="3" exit /b 0
echo.

:do_skip_menu

:: ── Choose Import Mode ───────────────────────────────────────
echo Please choose how to download/import the CA certificate:
echo   [1] Automatically download via SSH (Default)
echo   [2] Use a manually copied local CA certificate (Offline/Manual Mode)
echo.
:choose_import_loop
set /p IMPORT_MODE=  Please choose [1-2, default: 1]: 
if "!IMPORT_MODE!"=="" set IMPORT_MODE=1
if "!IMPORT_MODE!"=="1" goto do_import_ssh
if "!IMPORT_MODE!"=="2" goto offline_mode
echo [WARN] Invalid choice, please choose 1 or 2.
echo.
goto choose_import_loop

:do_import_ssh

:: ── Check SSH dependencies ───────────────────────────────────
where ssh >nul 2>&1
if %errorlevel% equ 0 goto ssh_ok

if exist "C:\Program Files\Git\usr\bin\ssh.exe" (
    set "PATH=!PATH!;C:\Program Files\Git\usr\bin"
    goto ssh_ok
)
if exist "C:\Program Files (x86)\Git\usr\bin\ssh.exe" (
    set "PATH=!PATH!;C:\Program Files (x86)\Git\usr\bin"
    goto ssh_ok
)

echo [WARN] ssh/scp command not found.
echo We can automatically install Git for Windows [built-in ssh/scp] via winget.
set /p INSTALL_GIT_CLI=  Do you want to automatically install Git? [y/N]: 
if /i "!INSTALL_GIT_CLI!"=="y" (
    echo Installing Git for Windows via winget. Please allow installation in the UAC popup...
    winget install -e --id Git.Git
    if !errorlevel! equ 0 (
        echo   [OK] Git installation complete! Refreshing path...
        if exist "C:\Program Files\Git\usr\bin\ssh.exe" (
            set "PATH=!PATH!;C:\Program Files\Git\usr\bin"
            goto ssh_ok
        )
        where ssh >nul 2>&1
        if !errorlevel! equ 0 goto ssh_ok
        echo   [WARN] Installation complete, but ssh still cannot be executed directly.
        echo   Please restart this Command Prompt window to apply environment variables, then run this script again.
        pause
        exit /b 0
    ) else (
        echo   [ERROR] winget installation failed. Please install Git manually.
    )
)

echo [ERROR] ssh/scp command not found!
echo Please install Git for Windows or enable OpenSSH Client in Windows optional features first.
echo.
pause
exit /b 1
:ssh_ok

:: ── Step 1 ───────────────────────────────────────────────────
echo [Step 1/5] Input Server Information
echo -----------------------------------------------------
echo.
set /p SERVER_IP=  Server IP Address [e.g. 192.168.1.100]: 
if "!SERVER_IP!"=="" (
    echo [ERROR] IP Address cannot be empty.
    pause
    exit /b 1
)

if exist "!INFO_FILE!" (
    set ALREADY=0
    for /f "tokens=1,2" %%A in (!INFO_FILE!) do (
        if "%%A"=="!SERVER_IP!" set ALREADY=1
    )
    if "!ALREADY!"=="1" (
        echo   [WARN] This IP has already been registered.
        echo.
        set /p REIMPORT=  Are you sure you want to overwrite and re-import? [y/N]: 
        if /i not "!REIMPORT!"=="y" (
            echo   Cancelled.
            pause
            exit /b 0
        )
    )
)

set /p SSH_USER=  SSH Username [default: root]: 
if "!SSH_USER!"=="" set SSH_USER=root

set /p SERVER_OS=  Is the remote server running Windows Server? [Y/n]: 
if "!SERVER_OS!"=="" set SERVER_OS=y

echo.
echo   [Tip] You will be prompted to enter the SSH password shortly.
echo.

:: ── Step 2 ───────────────────────────────────────────────────
echo [Step 2/5] Download Server Root CA Certificate
echo -----------------------------------------------------

set CA_REMOTE=/etc/anycert/anycert-ca.crt
set CA_LOCAL=!DATA_DIR!\anycert-ca-!SERVER_IP!.crt

echo   Source      : !SSH_USER!@!SERVER_IP!:!CA_REMOTE!
echo   Destination : !CA_LOCAL!
echo.

:: Path probing by OS selection
set SMB_CONNECTED=0

if /i "!SERVER_OS!"=="y" goto scp_windows

:: Otherwise, try Linux paths
scp -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!:!CA_REMOTE!" "!CA_LOCAL!"
if !errorlevel! equ 0 goto scp_ok

echo   [INFO] Linux default path download failed. Probing backup path [/root/anycert/anycert-ca.crt]...
scp -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!:/root/anycert/anycert-ca.crt" "!CA_LOCAL!"
if !errorlevel! equ 0 goto scp_ok
goto scp_failed

:scp_windows
echo   [INFO] Probing Windows server path [C:/anycert/anycert-ca.crt]...
scp -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!:C:/anycert/anycert-ca.crt" "!CA_LOCAL!"
if !errorlevel! equ 0 goto scp_ok

echo   [INFO] SCP download failed. Probing Windows SMB share [C$]...
set /p SERVER_PASS=  Enter password for !SSH_USER! to connect via SMB: 
net use \\!SERVER_IP!\c$ "!SERVER_PASS!" /user:"!SSH_USER!" >nul 2>&1
if !errorlevel! neq 0 goto scp_failed

copy /y "\\!SERVER_IP!\c$\anycert\anycert-ca.crt" "!CA_LOCAL!" >nul 2>&1
if not exist "!CA_LOCAL!" goto scp_failed

set SMB_CONNECTED=1
echo   [OK] CA certificate successfully copied via SMB Share!
goto scp_ok

:scp_failed
echo.
echo [ERROR] Certificate download failed! Please check:
echo   1. Server IP address is correct: !SERVER_IP!
echo   2. SSH credentials are correct
echo   3. The server-side anycert.sh or anycert.bat has been executed to generate the certificate
echo   4. Firewall allows SSH connections on Port 22
echo.
pause
exit /b 1

:scp_ok
echo.
echo   [OK] Certificate downloaded successfully!
echo.

:: ── Get cert thumbprint and save to info file later ──────────
set "CERT_THUMB="
for /f "skip=1 delims=" %%A in ('certutil -hashfile "%CA_LOCAL%" SHA1 2^>nul') do (
    if not defined CERT_THUMB (
        set "HASH=%%A"
        set "HASH=!HASH: =!"
        set "CERT_THUMB=!HASH!"
    )
)
echo   [INFO] CA Certificate SHA-1 Fingerprint: !CERT_THUMB!
echo.

:: ── Step 3 ───────────────────────────────────────────────────
echo [Step 3/5] Auto-detect Server FQDN
echo -----------------------------------------------------
echo.

set SERVER_DNS=
set REMOTE_PROXY_PORTS=
set REMOTE_PORT_OFFSET=
set REMOTE_PROFILE=

:: If connected via SMB, parse remote anycert.conf directly
if "!SMB_CONNECTED!"=="1" (
    if exist "\\!SERVER_IP!\c$\anycert\anycert.conf" (
        echo   [INFO] Parsing remote config file via SMB...
        for /f "usebackq tokens=1,2 delims==" %%A in ("\\!SERVER_IP!\c$\anycert\anycert.conf") do (
            if "%%A"=="SERVER_FQDN" set "SERVER_DNS=%%B"
            if "%%A"=="PROXY_PORTS" set "REMOTE_PROXY_PORTS=%%B"
            if "%%A"=="PORT_OFFSET" set "REMOTE_PORT_OFFSET=%%B"
            if "%%A"=="PROFILE" set "REMOTE_PROFILE=%%B"
        )
    )
)

:: If not yet fetched, try via SSH
if "!SERVER_DNS!"=="" (
    if /i "!SERVER_OS!"=="y" (
        ssh -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!" "type C:\anycert\anycert.conf" > "!DATA_DIR!\conf.tmp" 2>nul
    ) else (
        ssh -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!" "cat /etc/anycert/anycert.conf 2>/dev/null || cat ~/anycert/anycert.conf 2>/dev/null" > "!DATA_DIR!\conf.tmp" 2>nul
    )
    if exist "!DATA_DIR!\conf.tmp" (
        echo   [INFO] Parsing remote config file via SSH...
        for /f "usebackq tokens=1,2 delims==" %%A in ("!DATA_DIR!\conf.tmp") do (
            if "%%A"=="SERVER_FQDN" set "SERVER_DNS=%%B"
            if "%%A"=="PROXY_PORTS" set "REMOTE_PROXY_PORTS=%%B"
            if "%%A"=="PORT_OFFSET" set "REMOTE_PORT_OFFSET=%%B"
            if "%%A"=="PROFILE" set "REMOTE_PROFILE=%%B"
        )
        del "!DATA_DIR!\conf.tmp"
    )
)

:: Fallback if SERVER_DNS still empty (older configurations)
if "!SERVER_DNS!"=="" (
    if /i "!SERVER_OS!"=="y" (
        ssh -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!" "echo %%COMPUTERNAME%%" > "!DATA_DIR!\fqdn.tmp" 2>nul
        set /p SERVER_DNS=<"!DATA_DIR!\fqdn.tmp"
        if exist "!DATA_DIR!\fqdn.tmp" del "!DATA_DIR!\fqdn.tmp"
        if not "!SERVER_DNS!"=="" set "SERVER_DNS=!SERVER_DNS!"
    ) else (
        ssh -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!" "hostname -f" > "!DATA_DIR!\fqdn.tmp" 2>nul
        set /p SERVER_DNS=<"!DATA_DIR!\fqdn.tmp"
        if exist "!DATA_DIR!\fqdn.tmp" del "!DATA_DIR!\fqdn.tmp"
    )
)

:: Trim output and strip surrounding quotes (remote conf stores values quoted)
if not "!SERVER_DNS!"=="" (
    for /f "tokens=* delims= " %%A in ("!SERVER_DNS!") do set "SERVER_DNS=%%A"
    for /f "delims=" %%Q in ("!SERVER_DNS!") do set "SERVER_DNS=%%~Q"
)
if not "!REMOTE_PROXY_PORTS!"=="" (
    for /f "delims=" %%Q in ("!REMOTE_PROXY_PORTS!") do set "REMOTE_PROXY_PORTS=%%~Q"
)
if not "!REMOTE_PORT_OFFSET!"=="" (
    for /f "delims=" %%Q in ("!REMOTE_PORT_OFFSET!") do set "REMOTE_PORT_OFFSET=%%~Q"
)
if not "!REMOTE_PROFILE!"=="" (
    for /f "delims=" %%Q in ("!REMOTE_PROFILE!") do set "REMOTE_PROFILE=%%~Q"
)

if "!SERVER_DNS!"=="" goto dns_fallback
goto dns_ok

:dns_fallback
echo   [WARN] Auto-detect FQDN failed.
set /p SERVER_DNS=  Please manually enter Server DNS Name (FQDN) [e.g. my-server.local]: 
if "!SERVER_DNS!"=="" (
    echo [ERROR] DNS Name cannot be empty.
    pause
    exit /b 1
)

:dns_ok
if "!SMB_CONNECTED!"=="1" (
    net use \\!SERVER_IP!\c$ /delete >nul 2>&1
)
echo   [OK] Detected server DNS name: !SERVER_DNS!
echo.

:: ── Save site info: IP DNS THUMBPRINT ────────────────────────
set TEMP_INFO=!DATA_DIR!\anycert-info.tmp
if exist "!TEMP_INFO!" del "!TEMP_INFO!"
if exist "!INFO_FILE!" (
    for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
        if not "%%A"=="!SERVER_IP!" echo %%A %%B %%C>> "!TEMP_INFO!"
    )
)
echo !SERVER_IP! !SERVER_DNS! !CERT_THUMB!>> "!TEMP_INFO!"
copy /y "!TEMP_INFO!" "!INFO_FILE!" >nul
del "!TEMP_INFO!"

:skip_ssh_steps

:: ── Step 4 ───────────────────────────────────────────────────
echo [Step 4/5] Update hosts file
echo -----------------------------------------------------

set HOSTS_FILE=C:\Windows\System32\drivers\etc\hosts

set DNS_EXISTS=0
for /f "tokens=" %%L in ('type "!HOSTS_FILE!"') do (
    echo %%L | findstr /i "!SERVER_DNS!" >nul 2>&1
    if !errorlevel! equ 0 set DNS_EXISTS=1
)

if "!DNS_EXISTS!"=="0" goto hosts_add

echo   [WARN] Found existing !SERVER_DNS! entry in hosts file:
findstr /i "!SERVER_DNS!" "!HOSTS_FILE!"
echo.
set /p OVERWRITE=  Do you want to overwrite this entry? [y/N]: 
if /i "!OVERWRITE!"=="y" goto hosts_overwrite
echo   [SKIP] Kept existing entry unchanged.
goto skip_hosts

:hosts_overwrite
set TEMP_HOSTS=%TEMP%\hosts.tmp
findstr /v /i "!SERVER_DNS!" "!HOSTS_FILE!" > "!TEMP_HOSTS!"
copy /y "!TEMP_HOSTS!" "!HOSTS_FILE!" >nul
del "!TEMP_HOSTS!"
echo   [OK] Old entry removed.

:hosts_add
echo.>> "!HOSTS_FILE!"
echo # Anycert Server [!SERVER_IP!] - Added by anycert-windows.bat>> "!HOSTS_FILE!"
echo !SERVER_IP!    !SERVER_DNS!>> "!HOSTS_FILE!"
echo   [OK] Hosts file updated: !SERVER_IP!    !SERVER_DNS!

:skip_hosts
echo.

:: ── Step 5 ───────────────────────────────────────────────────
echo [Step 5/5] Import CA Certificate to Windows System Trust Store
echo -----------------------------------------------------

certutil -addstore -f "Root" "!CA_LOCAL!" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [OK] CA certificate successfully imported!
) else (
    echo   [ERROR] Auto-import failed. Please install manually:
    echo   Double click !CA_LOCAL! -^> Install Certificate -^> Local Machine -^> Place all certificates in the following store -^> Browse -^> Trusted Root Certification Authorities
)
echo.

:: ── Summary ──────────────────────────────────────────────────
echo =====================================================
echo   Setup Complete!
echo =====================================================
echo.
call :pad "Server IP" 17
echo   !PADDED! : !SERVER_IP!
call :pad "Server DNS" 17
echo   !PADDED! : !SERVER_DNS!
call :pad "CA Fingerprint" 17
echo   !PADDED! : !CERT_THUMB!
call :pad "CA Local Path" 17
echo   !PADDED! : !CA_LOCAL!
set "CA_FROM="
set "CA_UNTIL="
for /f "tokens=1* delims=:" %%A in ('certutil -dump "!CA_LOCAL!" 2^>nul ^| findstr /i "NotBefore"') do set "CA_FROM=%%B"
for /f "tokens=1* delims=:" %%A in ('certutil -dump "!CA_LOCAL!" 2^>nul ^| findstr /i "NotAfter"') do set "CA_UNTIL=%%B"
for /f "tokens=*" %%S in ("!CA_FROM!") do set "CA_FROM=%%S"
for /f "tokens=*" %%S in ("!CA_UNTIL!") do set "CA_UNTIL=%%S"
call :pad "CA Validity From" 17
echo   !PADDED! : !CA_FROM!
call :pad "CA Validity Until" 17
echo   !PADDED! : !CA_UNTIL!
echo.
echo   All Currently Registered Anycert Servers:
echo   -----------------------------------
for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
echo.
echo   Available HTTPS connections (you can open any in browser):
if /i "!REMOTE_PROFILE!"=="pve" goto show_urls_pve
if "!REMOTE_PROXY_PORTS!"=="" goto show_urls_generic
if "!REMOTE_PORT_OFFSET!"=="" set REMOTE_PORT_OFFSET=10000
set "SHOW_PORTS=!REMOTE_PROXY_PORTS!"
:show_ports_loop
if "!SHOW_PORTS!"=="" goto show_ports_done
for /f "tokens=1*" %%A in ("!SHOW_PORTS!") do (
    set "SHOW_P=%%A"
    set "SHOW_PORTS=%%B"
)
set /a SHOW_SSL=!SHOW_P!+!REMOTE_PORT_OFFSET!
if !SHOW_SSL! gtr 65535 set /a SHOW_SSL=!SHOW_P!-!REMOTE_PORT_OFFSET!
echo     https://!SERVER_DNS!:!SHOW_SSL!   (via FQDN)
echo     https://!SERVER_IP!:!SHOW_SSL!   (via IP, use this if app blocks hostname)
echo       -^>  http://localhost:!SHOW_P!
echo.
goto show_ports_loop
:show_ports_done
goto show_urls_done

:show_urls_generic
echo     https://!SERVER_DNS!
echo     https://!SERVER_IP!
echo     (Run anycert.sh/bat on the server to configure Nginx SSL proxy ports)
goto show_urls_done

:show_urls_pve
echo     https://!SERVER_DNS!:8006
echo     https://!SERVER_IP!:8006
goto show_urls_done

:show_urls_done
echo.
echo   To uninstall, run: anycert-windows.bat -u
echo.

goto end

:: ============================================================
::  UNINSTALL MODE
:: ============================================================
:do_uninstall

echo [Uninstall Mode] Removing Anycert Certificates and hosts Entries
echo -----------------------------------------------------
echo.

if not exist "!INFO_FILE!" goto uninstall_no_info

set SITE_COUNT=0
for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
    set /a SITE_COUNT+=1
    set SITE_IP_!SITE_COUNT!=%%A
    set SITE_DNS_!SITE_COUNT!=%%B
    set SITE_THUMB_!SITE_COUNT!=%%C
)

if !SITE_COUNT! equ 0 goto uninstall_no_info

echo   Registered Anycert Servers:
echo   -----------------------------------
for /l %%N in (1,1,!SITE_COUNT!) do (
    echo     [%%N]  !SITE_IP_%%N!  ^<^>  !SITE_DNS_%%N!
)
echo     [0]  Remove All
echo.

set /p SITE_CHOICE=  Please choose [1-!SITE_COUNT!, 0=all]: 
if "!SITE_CHOICE!"=="" goto uninstall_abort
if "!SITE_CHOICE!"=="0" goto uninstall_all

set CHOSEN_IP=!SITE_IP_%SITE_CHOICE%!
set CHOSEN_DNS=!SITE_DNS_%SITE_CHOICE%!
set CHOSEN_THUMB=!SITE_THUMB_%SITE_CHOICE%!
for /f "delims=" %%I in ("!SITE_CHOICE!") do (
    set CHOSEN_IP=!SITE_IP_%%I!
    set CHOSEN_DNS=!SITE_DNS_%%I!
    set CHOSEN_THUMB=!SITE_THUMB_%%I!
)
if "!CHOSEN_IP!"=="" goto uninstall_abort

echo.
echo   Selected: !CHOSEN_IP!  ^<^>  !CHOSEN_DNS!
set /p CONFIRM_U=  Are you sure you want to proceed? [y/N]: 
if /i not "!CONFIRM_U!"=="y" goto uninstall_abort

call :remove_one "!CHOSEN_IP!" "!CHOSEN_DNS!" "!CHOSEN_THUMB!"
goto uninstall_done

:uninstall_all
echo.
set /p CONFIRM_ALL=  Are you sure you want to remove all !SITE_COUNT! registered servers? [y/N]: 
if /i not "!CONFIRM_ALL!"=="y" goto uninstall_abort
for /l %%N in (1,1,!SITE_COUNT!) do (
    call :remove_one "!SITE_IP_%%N!" "!SITE_DNS_%%N!" "!SITE_THUMB_%%N!"
)
goto uninstall_done

:uninstall_no_info
echo   No registered servers found. Please manually enter DNS name to clean up:
set /p MANUAL_DNS=  DNS Name [e.g. my-server.local]: 
if "!MANUAL_DNS!"=="" goto uninstall_abort
call :remove_one "" "!MANUAL_DNS!" ""
goto uninstall_done

:uninstall_abort
echo   Cancelled.
pause
exit /b 0

:uninstall_done
echo.
echo =====================================================
echo   Uninstallation Complete!
echo =====================================================
echo.
if exist "!INFO_FILE!" (
    set REMAINING=0
    for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do set /a REMAINING+=1
    if "!REMAINING!"=="0" (
        del "!INFO_FILE!"
        echo   No registered Anycert servers currently.
    ) else (
        echo   Remaining registered servers:
        for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
    )
) else (
    echo   No registered Anycert servers currently.
)
echo.
echo   Please restart your browser to apply changes.
echo   Remember to run 'anycert.sh -u' on the server side to restore original settings if needed.
echo.
goto end

:: ============================================================
::  SUBROUTINE: remove_one <IP> <DNS> <THUMBPRINT>
:: ============================================================
:remove_one
set R_IP=%~1
set R_DNS=%~2
set R_THUMB=%~3
set HOSTS_FILE=C:\Windows\System32\drivers\etc\hosts
echo.
echo   --- Removing: !R_IP! !R_DNS! ---

:: Remove from hosts
if exist "!HOSTS_FILE!" (
    findstr /v /i /c:"!R_DNS!" /c:"Anycert Server [!R_IP!]" "!HOSTS_FILE!" > "%temp%\hosts.tmp" 2>nul
    copy /y "%temp%\hosts.tmp" "!HOSTS_FILE!" >nul
    del "%temp%\hosts.tmp"
)
echo   [OK] Removed hosts entry: !R_DNS!

:: Remove cert by THUMBPRINT
if not "!R_THUMB!"=="" (
    certutil -delstore Root "!R_THUMB!" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK] Removed CA certificate from system trust store.
    ) else (
        echo   [WARN] Cannot delete automatically. Please clean up manually:
        echo   Run certmgr.msc -> Trusted Root Certification Authorities -> Certificates -> delete entry containing !R_DNS!
    )
) else (
    echo   [WARN] Fingerprint record not found. Please clean up manually.
)

:: Remove cert file
if not "!R_IP!"=="" (
    if exist "!DATA_DIR!\anycert-ca-!R_IP!.crt" (
        del "!DATA_DIR!\anycert-ca-!R_IP!.crt"
        echo   [OK] Cached certificate file deleted.
    )
)

:: Remove from info file
if not "!R_IP!"=="" (
    if exist "!INFO_FILE!" (
        set TEMP_INFO=!DATA_DIR!\anycert-info.tmp
        if exist "!TEMP_INFO!" del "!TEMP_INFO!"
        for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
            if not "%%A"=="!R_IP!" echo %%A %%B %%C>> "!TEMP_INFO!"
        )
        if exist "!TEMP_INFO!" (
            copy /y "!TEMP_INFO!" "!INFO_FILE!" >nul
            del "!TEMP_INFO!"
        ) else (
            del "!INFO_FILE!"
        )
    )
)
goto :eof

:end
echo.
pause
endlocal
exit /b 0

:: ============================================================
::  Helper: right-pad %1 to width %2 (sets PADDED)
:: ============================================================
:pad
set "pad_s=%~1"
set "pad_w=%~2"
:pad_loop
if not "!pad_s:~%pad_w%!"=="" goto :pad_done
set "pad_s=!pad_s! "
goto :pad_loop
:pad_done
set "PADDED=!pad_s!"
goto :eof

:: ============================================================
::  OFFLINE IMPORT SUBROUTINE
:: ============================================================
:offline_mode
echo.
echo [Offline/Manual Mode] Please enter the path to the manually copied local CA certificate
echo -----------------------------------------------------
set /p OFFLINE_CA=  CA Certificate Path [e.g. C:\Users\User\Desktop\anycert-ca.crt]: 
if "!OFFLINE_CA!"=="" (
    echo [ERROR] File path cannot be empty.
    pause
    exit /b 1
)
if not exist "!OFFLINE_CA!" (
    echo [ERROR] File not found: !OFFLINE_CA!
    pause
    exit /b 1
)

set /p SERVER_IP=  Enter Server IP Address [e.g. 192.168.1.100]: 
if "!SERVER_IP!"=="" (
    echo [ERROR] IP Address cannot be empty.
    pause
    exit /b 1
)

set /p SERVER_DNS=  Enter Server DNS Name (FQDN) [e.g. my-server.local]: 
if "!SERVER_DNS!"=="" (
    echo [ERROR] DNS Name cannot be empty.
    pause
    exit /b 1
)

:: Copy offline CA to CA_LOCAL
set CA_LOCAL=!DATA_DIR!\anycert-ca-!SERVER_IP!.crt
copy /y "!OFFLINE_CA!" "!CA_LOCAL!" >nul

:: Get cert thumbprint
set "CERT_THUMB="
for /f "skip=1 delims=" %%A in ('certutil -hashfile "%CA_LOCAL%" SHA1 2^>nul') do (
    if not defined CERT_THUMB (
        set "HASH=%%A"
        set "HASH=!HASH: =!"
        set "CERT_THUMB=!HASH!"
    )
)

:: Save site info: IP DNS THUMBPRINT
set TEMP_INFO=!DATA_DIR!\anycert-info.tmp
if exist "!TEMP_INFO!" del "!TEMP_INFO!"
if exist "!INFO_FILE!" (
    for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do (
        if not "%%A"=="!SERVER_IP!" echo %%A %%B %%C>> "!TEMP_INFO!"
    )
)
echo !SERVER_IP! !SERVER_DNS! !CERT_THUMB!>> "!TEMP_INFO!"
copy /y "!TEMP_INFO!" "!INFO_FILE!" >nul
del "!TEMP_INFO!"

goto skip_ssh_steps
