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
echo !CYAN!                      anycert-windows.bat (Windows Client) !RESET!
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

if "!HAS_SERVERS!"=="1" (
    echo   Currently registered Anycert servers:
    echo   -----------------------------------
    for /f "tokens=1,2" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
    echo.
    echo Please select an action:
    echo   [1] Add/Import a new certificate (Default)
    echo   [2] Remove/Uninstall an existing certificate
    echo   [3] Exit
    echo.
    set /p CLIENT_ACTION=  Please choose [1-3, default: 1]: 
    if "!CLIENT_ACTION!"=="" set CLIENT_ACTION=1
    if "!CLIENT_ACTION!"=="2" goto do_uninstall
    if "!CLIENT_ACTION!"=="3" exit /b 0
    echo.
)

:: ── Choose Import Mode ───────────────────────────────────────
echo Please choose how to download/import the CA certificate:
echo   [1] Automatically download via SSH (Default)
echo   [2] Use a manually copied local CA certificate (Offline/Manual Mode)
echo.
set /p IMPORT_MODE=  Please choose [1-2]: 
if "!IMPORT_MODE!"=="" set IMPORT_MODE=1

if "!IMPORT_MODE!"=="2" goto offline_mode

:: ── Check SSH dependencies ───────────────────────────────────
where ssh >nul 2>&1
if %errorlevel% neq 0 (
    if exist "C:\Program Files\Git\usr\bin\ssh.exe" (
        set PATH=!PATH!;C:\Program Files\Git\usr\bin
        goto ssh_ok
    )
    if exist "C:\Program Files (x86)\Git\usr\bin\ssh.exe" (
        set PATH=!PATH!;C:\Program Files (x86)\Git\usr\bin
        goto ssh_ok
    )

    echo [WARN] ssh/scp command not found.
    echo We can automatically install Git for Windows (built-in ssh/scp) via winget.
    set /p INSTALL_GIT_CLI=  Do you want to automatically install Git? [y/N]: 
    if /i "!INSTALL_GIT_CLI!"=="y" (
        echo Installing Git for Windows via winget. Please allow installation in the UAC popup...
        winget install -e --id Git.Git
        if !errorlevel! equ 0 (
            echo   [OK] Git installation complete! Refreshing path...
            if exist "C:\Program Files\Git\usr\bin\ssh.exe" (
                set PATH=!PATH!;C:\Program Files\Git\usr\bin
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
)
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

:: Try multiple paths
scp -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!:!CA_REMOTE!" "!CA_LOCAL!"
if !errorlevel! neq 0 (
    echo   [INFO] Linux default path download failed. Probing Windows server path (C:/anycert/anycert-ca.crt)...
    scp -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!:C:/anycert/anycert-ca.crt" "!CA_LOCAL!"
    if !errorlevel! neq 0 (
        echo   [INFO] Probing backup path (/root/anycert/anycert-ca.crt)...
        scp -o StrictHostKeyChecking=no "!SSH_USER!@!SERVER_IP!:/root/anycert/anycert-ca.crt" "!CA_LOCAL!"
        if !errorlevel! neq 0 goto scp_failed
    )
)
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
set CERT_THUMB=
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 '!CA_LOCAL!').Thumbprint"`) do (
    if "!CERT_THUMB!"=="" set CERT_THUMB=%%T
)
echo   [INFO] CA Certificate SHA-1 Fingerprint: !CERT_THUMB!
echo.

:: ── Step 3 ───────────────────────────────────────────────────
echo [Step 3/5] Auto-detect Server FQDN
echo -----------------------------------------------------
echo.

set SERVER_DNS=
:: Try hostname -f
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "& ssh -o StrictHostKeyChecking=no '!SSH_USER!@!SERVER_IP!' 'hostname -f' 2>$null"`) do (
    if "!SERVER_DNS!"=="" set SERVER_DNS=%%H
)
:: Try Windows PowerShell FQDN fallback
if "!SERVER_DNS!"=="" (
    for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "& ssh -o StrictHostKeyChecking=no '!SSH_USER!@!SERVER_IP!' 'powershell -NoProfile -Command \"[System.Net.Dns]::GetHostEntry('''').HostName\"' 2>$null"`) do (
        if "!SERVER_DNS!"=="" set SERVER_DNS=%%H
    )
)

:: Trim output
if not "!SERVER_DNS!"=="" (
    for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "'!SERVER_DNS!'.Trim()"`) do set SERVER_DNS=%%D
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
echo   Server IP   : !SERVER_IP!
echo   Server DNS  : !SERVER_DNS!
echo   CA Fingerprint: !CERT_THUMB!
echo   CA Local Path : !CA_LOCAL!
echo.
echo   All Currently Registered Anycert Servers:
echo   -----------------------------------
for /f "tokens=1,2,3" %%A in (!INFO_FILE!) do echo     %%A  ^<^>  %%B
echo.
echo   Please open in your browser: https://!SERVER_DNS!
echo.
echo   To uninstall, run: anycert-windows.bat -u
echo.

set /p OPEN_BROWSER=  Open this page in browser now? [y/N]: 
if /i "!OPEN_BROWSER!"=="y" start https://!SERVER_DNS!

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
set DNS_IN_HOSTS=0
for /f "tokens=" %%L in ('type "!HOSTS_FILE!"') do (
    echo %%L | findstr /i "!R_DNS!" >nul 2>&1
    if !errorlevel! equ 0 set DNS_IN_HOSTS=1
)
if "!DNS_IN_HOSTS!"=="0" (
    echo   [SKIP] Hosts entry not found for: !R_DNS!
) else (
    set TEMP_HOSTS=%TEMP%\hosts.tmp
    findstr /v /i "!R_DNS!" "!HOSTS_FILE!" > "!TEMP_HOSTS!"
    findstr /v /i "anycert-windows.bat" "!TEMP_HOSTS!" > "!HOSTS_FILE!"
    del "!TEMP_HOSTS!"
    echo   [OK] Removed hosts entry: !R_DNS!
)

:: Remove cert by THUMBPRINT
if not "!R_THUMB!"=="" (
    powershell -NoProfile -Command "& { $s = [System.Security.Cryptography.X509Certificates.StoreName]::Root; $l = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine; $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($s,$l); $store.Open('ReadWrite'); $certs = $store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,'!R_THUMB!',$false); foreach($c in $certs){$store.Remove($c)}; $store.Close() }" >nul 2>&1
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
set CERT_THUMB=
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 '!CA_LOCAL!').Thumbprint"`) do (
    if "!CERT_THUMB!"=="" set CERT_THUMB=%%T
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
