# anycert - AI 助理開發歷程與專案脈絡

本文件作為 `anycert` 專案的持久化記憶與開發人員指南。它記錄了工程細節、跨平台相容性雷區、防退化警告以及開發時間軸。

---

## 📅 開發時間軸與歷程

### 階段 1：基礎 Shell 腳本重構與 Port 更新
- **伺服器端 Port 更新選項**：重构了 `anycert.sh` 與 `anycert.bat` 的進入流程，允許使用者在不重新簽發憑證的情況下，直接更新 Nginx Port 映射。
- **Port 增量微調語法**：
  - 實作了 `+PORT` 語法：可直接將新的 HTTP Port 追加到 Nginx 反向代理中。
  - 實作了 `-PORT` 語法：安全地將指定的 Port 從 Nginx 反向代理中移除。
  - 輸入無首字元的空白分隔連接埠（例如 `3000 8080`），則預設為完全覆蓋模式。
  - 更新完成後，腳本會自動重寫配置並重載（Reload）Nginx 服務。

### 階段 2：CMD 解析器 Bug 避雷（關鍵 Windows 相容性）
- **括號巢狀崩潰 Bug**：在 Windows CMD/Batch 腳本中，如果在被括號 `( )` 包裹的 `if` 或 `for` 區塊內部呼叫副程式（subroutine）或進行標籤跳轉（`goto`），會破壞 CMD 內部的檔案讀取指標，拋出 `The system cannot find the path specified.` 錯誤並崩潰。
  - *修正*：將 `anycert.bat` 中所有的迴圈與摘要輸出區塊扁平化，全部改用原生標籤 `goto` 迴圈跳轉，完美避開括號巢狀 Bug。
- **CLI 選項解析 Bug**：在 CMD 中使用 `findstr "-"` 容易觸發參數解析錯誤，我們改用 CMD 原生字串替換法：`if "!NEW_PROXY_PORTS!"=="!NEW_PROXY_PORTS:-=!"` 來偵測是否存在減號，避開外部指令呼叫。

### 階段 3：跨平台 Windows SMB 備援通道
- **問題痛點**：Windows Server 預設通常沒有安裝 SSH/SCP，但 SMB (Port 445) 與 C$ 管理共用預設是開啟的。當 Linux/macOS 的用戶端電腦想去抓憑證和 FQDN 配置時，如果強迫管理員去 Windows 上安裝 OpenSSH 服務，體驗會非常糟糕。
- **Linux 用戶端 (`anycert-linux.sh`) SMB 支援**：
  - 偵測到 SCP 下載失敗且遠端為 Windows 時，會自動嘗試 SMB。
  - 自動偵測本地包管理器（`apt`, `dnf`, `yum`），並自動無痛下載安裝 `smbclient` 套件。
  - 提示輸入 SMB 密碼後，直接利用 `smbclient "//${SERVER_IP}/c$" -U "${SSH_USER}%${SMB_PASS}" -c "cd anycert; get anycert-ca.crt ..."` 抓取憑證。
  - 同時透過 SMB 下載遠端的 `anycert.conf` 配置檔以解析 FQDN，完全免去 SSH 連線。
- **macOS 用戶端 (`anycert-macos.sh`) SMB 支援**：
  - 利用 macOS 內建的 `mount_smbfs` 指令，無痛掛載 Windows 系統的 `c$` 共用磁碟。
  - 複製 CA 憑證，並直接從掛載的 `anycert.conf` 中提取 FQDN。
  - 完成後自動 `umount` 卸載掛載點並清理暫存目錄，做到完全綠色無痕。

### 階段 4：強健的 Client 清理與手動 Fallback
- **反安裝時的手動 DNS 清除**：在用戶端反安裝模式（`-u`）下，若記錄檔 `anycert-info.txt` 意外遺失或為空，腳本會主動提示使用者「手動輸入要清理的 DNS 網域名稱」，確保能精準清除 hosts 中的殘留項目。
- **離線手動複製模式**：在用戶端腳本中加入了手動模式選單。如果 Windows Server 把 SSH 與 SMB 通通關閉，使用者可以自行將 `anycert-ca.crt` 拷貝至 Client 本地端，腳本依然會全自動幫忙完成系統信任導入、瀏覽器設定與 hosts 配置。

### 階段 5：選單順序對齊與可自訂 HTTPS Port 偏移量
- **選單順序對齊**：將 `anycert.bat` 的 Service Profile 選單順序改成與 `anycert.sh` 完全一致：`[1] Nginx（預設）` / `[2] Custom` / `[3] Generate Only`，預設選項統一為 Nginx。
- **可自訂 HTTPS Port 偏移量（PORT_OFFSET）**：
  - 原本 Nginx 一鍵代理的 HTTPS 連接埠固定為 `HTTP Port + 10000`。
  - 現在使用者可在 Nginx 設定階段自行輸入偏移量（如 `+1` / `+10` / `+443`），預設仍為 `10000`，並保留碰撞自動 `+1` 避讓邏輯（例如 offset=1 時若 `8081` 已佔用則自動取 `8082`）。
  - `anycert.sh` 抽出 `resolve_ssl_port` 函式統一計算 SSL 埠；`anycert.bat` 的 `:resolve_ssl_port` 改讀取 `!PORT_OFFSET!`。
  - `PORT_OFFSET` 會寫入 `anycert.conf` 並在既有憑證偵測時讀回，確保重新設定 / 更新 Port 時偏移量不會被重置。
  - 客戶端腳本（`anycert-linux.sh` / `anycert-macos.sh` / `anycert-windows.bat`）只負責下載 CA 與寫 hosts，不涉及 port 計算，故不需改動。

### 階段 6：修復既有憑證選單 [1] 消失的 CMD 解析器 Bug
- **症狀**：在 Windows 伺服器上重新執行 `anycert.bat` 時，既有憑證偵測選單只顯示 `[2] [3] [4]`，缺少 `[1] Update/Modify Nginx port mappings`。
- **根因**：既有的「檢查既有憑證」邏輯整段被包在 `if exist "!SERVER_CRT!" ( ... )` 的括號區塊內，而區塊中又定義了 `:exist_action_loop` / `:do_update_ports` / `:do_renew_cert` 等多個標籤。CMD 解析器遇見括號區塊內的標籤會破壞區塊結構，導致標籤前的 `if/else` 輸出（即 `[1]` 與 `Please choose an action:`）被吞掉。這正是守則 1 明令禁止的「括號內使用標籤跳轉」。
- **修正**：將整段重構為扁平結構——改用 `if not exist "!SERVER_CRT!" goto after_existing_check` 跳過，所有標籤（`:exist_action_loop` / `:do_update_ports` / `:do_renew_cert` / `:after_existing_check`）提升至頂層，不再嵌於任何 `( )` 區塊內。`[1]` 選項恢復正常顯示。

### 階段 7：修復 `do_post_install` 標籤缺失崩潰 + Custom Reload 防禦
- **症狀**：選 `[2] Renew` 或 Custom Path 部署後，腳本報錯 `The system cannot find the batch label specified - do_post_install` 並直接崩潰退出。
- **根因**：部署完成後用 `goto do_post_install` 跳轉到「匯入 CA / 啟用 OpenSSH / 存檔摘要」區段，但 `:do_post_install` 這個標籤從未被定義（歷史重構時遺失）。任何走到該 `goto` 的路徑（Generate Only、Custom Path）都會崩潰。
- **修正**：在「Import CA locally」區段前方補上 `:do_post_install` 頂層標籤，使所有 `goto do_post_install` 都能正確落點。
- **Custom Path Reload 防禦**：使用者在 Custom Path 輸入 `nginx -s reload` 但本機未安裝 Nginx 時，原本會噴 `'nginx' is not recognized` 且隨後崩潰。現於執行 `RELOAD_CMD` 前先偵測：若指令含 `nginx` 且 `C:\nginx\nginx.exe` 不存在，直接給出明確警告並跳過執行，不再盲目呼叫導致報錯。

### 階段 8：Renew 流程跳過 Service Profile 重新詢問
- **痛點**：原有 Renew（[2]）流程在重新產生憑證前，仍會重新執行 `choose_profile`，讓使用者重新選擇部署模式。這除了多此一舉，也讓使用者在 Renew 時有機會誤選其他 Profile（例如從 `nginx_proxy` 誤切到 `Custom`），進而觸發不必要的部署錯誤。
- **修正**：在 `check_existing_cert` 選 `[2] Renew` 時設定 `ONLY_RENEW=1`（bat）/ `RENEW_MODE=1`（sh）；進入安裝流程時，若處於 Renew 模式則**直接沿用既有 `PROFILE` / `PROXY_PORTS` / `PORT_OFFSET` / `CUSTOM_*`**，跳過 `choose_profile`，僅印出「Reusing existing Service Profile: <profile>」與摘要，隨後照常詢問是否繼續並重新簽發憑證、重新部署。兩腳本行為對齊。

### 階段 9：修復 Port 增量調整 `+` 被誤判為覆蓋的 Bug
- **症狀**：在「Update/Modify Nginx port mappings」輸入 `+9899` 要新增埠時，摘要卻只顯示一筆 `HTTP localhost:+9899`（多了 `+`），且原有埠（3000/6501/11434）全部消失。
- **根因**：`process_port_adjustments` 判斷「覆蓋模式」的條件只檢查**不含 `-`**。因為 `+9899` 不含 `-`，被誤判成「完整覆蓋」，直接把原始輸入（含 `+`）整串寫入 `PROXY_PORTS`，導致 `+` 被當成埠號一部分，且原有埠被清空。
- **修正**：覆蓋模式的判定改為**同時不含 `+` 與 `-`** 才成立（`bat`: `if "!NEW_PROXY_PORTS!"=="!NEW_PROXY_PORTS:-=!" if "!NEW_PROXY_PORTS!"=="!NEW_PROXY_PORTS:+=!"`；`sh`: `if [[ "$NEW_PROXY_PORTS" != *"-"* && "$NEW_PROXY_PORTS" != *"+"* ]]`）。只要出現 `+` 就走增量/減量調整分支，正確剝離 `+`/`-` 前綴後增減埠，原有埠得以保留。兩腳本行為對齊。

### 階段 10：Windows Nginx 安裝路徑、連線修復與全專案 PowerShell 零依賴化 (PowerShell-free)
- **問題痛點**：
  - 之前使用 `winget` 安裝 Nginx 時，會將程式裝在 AppData 的 Microsoft WinGet Links 資料夾，導致 Nginx 啟動時因為找不到相關的 logs 與 mime.types 相對目錄而直接崩潰。
  - Nginx 反向代理設定中的 `server_name` 原先只匹配 FQDN，導致使用者從本地使用 `localhost` 或 `127.0.0.1` 或是 IP 連線時無法正確存取。
  - 在部分 Windows 環境下（例如 PowerShell 被 ExecutionPolicy 限制），任何殘留的 PowerShell 呼叫都會導致 IP/FQDN 取得失敗、UAC 提權失敗、CA 指紋讀取錯誤、或是 OpenSSH 服務偵測中斷。
- **修正**：
  * **安裝路徑與執行檔重構**：統一將 Nginx 的目標與工作目錄 `NGINX_DIR` 設為 `C:\nginx`。當 Nginx 不存在時，使用 Windows 原生 `curl.exe` 下載官方官方 `nginx-1.26.1.zip` 並用 `tar.exe` 解壓至 `C:\nginx`，全程不需要 PowerShell。
  * **扁平化 Error Handling**：下載與部署失敗路徑完全採用 top-level label 與 `goto` 跳轉，杜絕 Batch 的括號 `( )` 巢狀 Bug。
  * **server_name 多元連線支援**：設定檔的 `server_name` 調整為 `!SERVER_FQDN! !SERVER_IP! localhost 127.0.0.1;`，`anycert.sh` 同步對齊為 `${SERVER_FQDN} ${SERVER_IP} localhost 127.0.0.1;`。
  * **Nginx 設定檔語法測試**：在 daemon 啟動與 `reload` 前，先切換工作目錄至 `C:\nginx` 並呼叫 `.\nginx.exe -t`。一旦設定檔有誤則印出警告並中止，保障服務強健性。
  * **後端重導向 (Redirect) 連接埠遺失修復**：修復了 `anycert.bat` 中 `proxy_redirect` 規則過於死板、且 `Host` 標頭採用了不含 Port 的 `$host`，導致後端服務在進行重導向 (Redirect) 時將埠號剝離（如原本應跳轉至 `127.0.0.1:19899` 卻丟失埠號跳轉至 `127.0.0.1/chat`）進而連線失敗。
    - *修正*：將 Nginx 的 `Host` 傳遞標頭改為包含 Port 的 `$http_host`，並新增 `X-Forwarded-Port $server_port` 傳遞前端埠號。
    - *修正*：將 `proxy_redirect` 替換為對齊 Linux 版的 `proxy_redirect http:// https://;`，全自動將後端回傳的 HTTP 地址補回正確的 HTTPS 協議與前端連接埠。
  * **全專案 PowerShell 零依賴化 (PowerShell-free) 重構**：徹底清除了所有 `*.bat`、`*.sh` 裡的 `powershell` 命令與遠端呼叫：
    - *ANSI ESC 取得*：改用原生 `prompt $E` 取得，速度極快且不需 PowerShell。
    - *UAC 提權*：改用 WSH VBScript (`Shell.Application`) 替代 PowerShell。
    - *IP 與 FQDN 偵測*：改用原生 `ipconfig`（支援中/英文語系 Windows）及 `REG QUERY` 讀取 TCP/IP 註冊表。
    - *Ports 增減與去重*：以純 Batch 迴圈解析去重與過濾代替 PowerShell 的字串分割。
    - *CA 指紋讀取與證書刪除*：改用 Windows 原生的 `certutil` 指令 (`certutil -dump` / `certutil -delstore`)。
    - *時間戳記 (Backup)*：改用原生 VBScript 輸出 `yyyyMMddHHmmss` 以確保跨語系與系統的版本相容性。
    - *OpenSSH (sshd) 管理與安裝*：改用原生的 `sc query`、`sc config` 和 `net start` 進行狀態檢查與服務控制；安裝改用映像管理工具 `dism` 替代 `Add-WindowsCapability`。
    - *遠端 FQDN 查詢 (Linux/macOS 伺服器與用戶端)*：改為直接優先從已下載的 `anycert.conf` 內提取 `SERVER_FQDN`，若為空再透過原生遠端 `echo %COMPUTERNAME%` 回傳，完全避免 SSH 發送 powershell。

---

### 階段 11：用戶端完成摘要改為列出可連 HTTPS Ports（移除開 Browser 互動、支援多 IP SAN）
- **痛點**：
  * 三端用戶端腳本（`anycert-windows.bat`、`anycert-linux.sh`、`anycert-macos.sh`）在安裝完成後，會詢問使用者是否要「立即開啟瀏覽器」，且只顯示一個通用的 FQDN URL，缺乏實用性。
  * 部分開發框架（如 Vite）會預設透過 `allowedHosts` 阻擋 Hostname 存取，僅允許 localhost 或 IP 直接連線，導致透過 FQDN 連結時會出現 `Blocked request` 錯誤。
  * 原先伺服器端憑證簽發僅支援單一實體網卡 IP，若使用者使用 Tailscale、VPN 等虛擬網路，其 IP 無法包含在 SAN 中，以 IP 存取時會提示證書不安全。
- **修正**：
  * **移除「是否開啟瀏覽器」互動提示**：安裝完成後不再詢問，直接顯示所有可用的 HTTPS 連線清單。
  * **讀取遠端 `anycert.conf` 以取得 `PROXY_PORTS` 和 `PORT_OFFSET`**：三端均從遠端伺服器的 `anycert.conf` 解析這兩個值（透過 SMB 或 SSH）。
  * **計算並列出所有 HTTPS SSL Port 的完整 URL（同時包含 FQDN 與 IP）**：若有 `PROXY_PORTS`，依照 `SSL Port = HTTP Port + PORT_OFFSET` 計算，逐行印出 `https://<FQDN>:<ssl_port> (via FQDN)` 與 `https://<IP>:<ssl_port> (via IP)`，以便直接複製。若無 Port 資訊，則退回顯示基本 FQDN/IP URL 與提示。
  * **伺服器端支援多 IP SAN 與 Nginx server_name 同步**：在伺服器端簽發證書時（`anycert.sh` 與 `anycert.bat`），新增額外 IP 輸入提示（多個 IP 以空白分隔，如 Tailscale IP），自動將多個 IP 寫入證書的 SAN 中。同時，一併將這些額外 IP 寫入 Nginx 的 `server_name` 規則，確保多重虛擬網路或多實體網卡下的連線皆可順暢路由且證書有效。

---

### 階段 12：移除 Windows 伺服器端埠偵測對 PowerShell 的依賴、新增 HTTP 探測與數值排序
- **痛點**：
  * 原本 `anycert.bat` 偵測 Windows 本地監聽連接埠時使用 PowerShell 命令 `Get-NetTCPConnection`，但在某些環境下會因 ExecutionPolicy 權限限制、或是執行緩慢等原因返回空值，導致無法成功列出目前正在聽的 `[TIP]` 提示服務（如 `9899` / `6502` 服務明明在監聽卻抓不到）。
  * 舊版偵測會把非 HTTP 的服務（如 RDP 3389、SSH 22 等純 TCP 服務）一併列出，在進行 Nginx 一鍵反代時沒有用處。
  * 偵測出來的連接埠列表未進行排序，且可能在有多重 IP 綁定時出現重複連接埠。
- **修正**：
  * **改用原生 netstat 探測**：完全捨棄 PowerShell，改用 `netstat -ano | findstr /i "listening"` 取得目前所有監聽狀態的連接埠。
  * **避開 CMD 迴圈括號替換 Bug**：因為 CMD 的 `for %%P in (!ADDR::= !)` 語句在括號內執行延遲替換時，會因為雙冒號優先權問題解析成 `ADDR::` 導致失敗。修正為先將值存到臨時變數再進行替換，最後以 loop 比對來進行去重。速度快且 100% 穩定，達成完全 PowerShell-free 探測。
  * **引進 curl 本地 HTTP 協定探測**：對偵測到的每個連接埠發送 `curl -s -w "%{http_code}" -o nul --connect-timeout 0.2 --max-time 0.5` 請求。若回傳的 HTTP code 為 `000`（即連線被拒絕、斷開或非 HTTP 協定）則過濾不顯示，僅保留真正具有 HTTP 回應的 Web 服務。
  * **連接埠數值排序 (Deduplicate & Sort)**：在 `anycert.bat` 實作了純 Batch 版本的氣泡排序法 (Bubble Sort) 將 ports 進行數值由小到大排序；在 `anycert.sh` 則使用 `sort -n -u` 對齊，確保偵測提示的 Ports 整潔且有序。

---

## 🏗️ 架構與組件角色

### 🖥️ 伺服器端腳本
- [anycert.sh](anycert.sh) (Linux/macOS 伺服器)：
  - 負責產生 Root CA（10年）與伺服器憑證（825天）。
  - 提供四大部署選項：一鍵 Nginx 反代（HTTPS Port = HTTP Port + 自訂偏移量，預設 +10000）、Proxmox VE (PVE) 自動替換、自訂路徑部署與僅產生憑證。
- [anycert.bat](anycert.bat) (Windows 伺服器)：
  - 尋找 Git 內建的 OpenSSL 或系統 OpenSSL 簽發憑證。
  - 支援 Windows 本地端一鍵 Nginx 反代安裝與配置（選單順序與 `anycert.sh` 對齊：`[1] Nginx` / `[2] Custom` / `[3] Generate Only`，預設 Nginx）。
  - 採用扁平化 label 語法，避開 CMD 解析器陷阱。

### 💻 用戶端腳本
- [anycert-windows.bat](anycert-windows.bat) (Windows 用戶端)：
  - 下載憑證並匯入 Windows 本地電腦受信任的根憑證授權單位。
  - 安裝完成後，自動讀取遠端 `anycert.conf` 取得 `PROXY_PORTS` / `PORT_OFFSET`，列出所有可連線的 HTTPS URLs。
- [anycert-linux.sh](anycert-linux.sh) (Linux 用戶端)：
  - 支援 SCP 與 `smbclient` 下載通道。
  - 自動寫入系統 Trust Store，並自動將憑證匯入 Chrome 與 Firefox 的 NSS 憑證資料庫。
  - 安裝完成後列出所有可連線的 HTTPS URLs。
- [anycert-macos.sh](anycert-macos.sh) (macOS 用戶端)：
  - 支援 SCP 與 `mount_smbfs` 下載通道。
  - 自動寫入 macOS 系統 Keychain 鑰匙圈中設為受信任。
  - 安裝完成後列出所有可連線的 HTTPS URLs。

---

## 🧪 平台交叉測試對比表

用於記錄各腳本在各個平台上的實際測試與支援狀態。（`v` 代表測試通過，`x` 代表不支援，空白代表待測試）

### 1. 伺服器端部署 (Server Setup)
| 腳本名稱 / 平台 | Windows | Linux | macOS | WSL |
| :--- | :---: | :---: | :---: | :---: |
| `anycert.bat` | v | x | x | x |
| `anycert.sh` | x | | | |

### 2. 用戶端信任導入 (Client Setup)
| 腳本名稱 / 平台 | Windows | Linux | macOS | WSL |
| :--- | :---: | :---: | :---: | :---: |
| `anycert-linux.sh` | x | | | |
| `anycert-macos.sh` | x | | | |
| `anycert-windows.bat` | v | x | x | x |

---

## ⚠️ 未來開發的重要守則（開發人員指南）

1. **保持 Windows Batch 檔案扁平化**：
   - **絕對不要**在 `anycert.bat` 的括號 `( )` 包裹區塊內使用巢狀迴圈。
   - **絕對不要**在括號 `( )` 內呼叫標籤跳轉（`goto` 或 `call :label`）。如果需要迴圈，請使用扁平的標籤 jump 語法。
2. **Batch 輸出括號必須雙重轉義**：
   - 在 Batch 中，若 `echo` 輸出的文字包含括號，且該輸出位於 `if/for` 條件句內部，必須使用 `^` 進行轉義（例如 `echo 移除資料夾 ^(C:\nginx^)...`），否則會被 CMD 誤判為條件句結束而崩潰。
3. **功能跨平台對齊**：
   - 任何在 `anycert.sh` 做的設定更新，應適時對齊至 `anycert.bat`。
   - 任何用戶端導入、清理或備援機制的調整，必須同步更新至 `anycert-windows.bat`、`anycert-linux.sh` 與 `anycert-macos.sh` 三端。
4. **離線韌性設計**：
   - 始終確保用戶端腳本在網路不通或服務被防火牆阻擋時，能夠優雅降級（Fallback）引導至手動離線模式，不得直接噴錯中斷。

---

## 🔮 未來開發與測試計畫 (Next Steps / TODO)

在下一個 Session 開始時，可優先關注以下方向：

- [ ] **交叉平台實機測試**：
  - 根據「🧪 平台交叉測試對比表」，將各個客戶端腳本（Linux/macOS/Windows）對接 Windows Server 及 Linux Server 的各種網路排列組合進行實際環境測試，填補表格空白。
- [ ] **Windows 客戶端 (`anycert-windows.bat`) 的 SMB Fallback**：
  - 目前 Windows 用戶端腳本在 SCP 失敗時尚未實作自動 Windows 原生 SMB 連線複製（如 `net use` 搭配 `copy` 抓取 `\\ip\c$\anycert\` 底下的憑證與 config）。這在對接未裝 SSH 的 Windows Server 時是非常有價值的提升。
- [ ] **WSL 虛擬網路對接最佳化**：
  - 進一步測試 Linux 用戶端在 WSL 2 環境中對接實體 Windows Server 或同機 Windows 宿主機時的網路通訊與證書導入順暢度。
- [ ] **Nginx 反代 SSL 設定檔安全加固**：
  - 未來可微調 Nginx 反代產生的 SSL 配置，預設加入更嚴格的 TLS 1.2/1.3 協定限制與現代 Cipher Suites 加密套件。

