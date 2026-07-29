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
- **選單順序對齊**：將 `anycert.bat` 的 Service Profile 選單順序改成與 `anycert.sh` 完全一致：`[1] Nginx SSL Proxy（預設）` / `[2] Nginx SSL Gateway` / `[3] Custom Path` / `[4] Generate Only` / `[5] Proxmox VE（僅 PVE 系統顯示）`，預設選項統一為 Nginx SSL Proxy。
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
- **痛點**：原有 Renew（[2]）流程在重新產生憑證前，仍會重新執行 `choose_profile`，讓使用者重新選擇部署模式。這除了多此一舉，也讓使用者在 Renew 時有機會誤選其他 Profile（例如從 `Nginx SSL Proxy` 誤切到 `Custom Path`），進而觸發不必要的部署錯誤。
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

### 階段 13：修復 WSL/非 Root 權限連線與 Port 漏失，解決 UTF-8/Big5 指紋編碼與 netsh 括號語法 Bug
- **非 Root SSH 用戶端連線 Permission Denied 修正**：
  * *問題*：當伺服器是 WSL/Linux 且使用者以非 root 帳號連線時，因 `/etc/anycert/anycert.conf` 權限預設為 `600`，用戶端無法讀取，進而導致 `SERVER_FQDN` 與 `PROXY_PORTS` 皆讀取為空。這在用戶端造成 FQDN 回退至 `hostname -f` (在 WSL 中為 Windows 電腦名 `.localdomain`)，且因無 Port 資訊致使 Available HTTPS URLs 列表漏失 `:16502` 等 SSL Ports。
  * *修正*：在 `anycert.sh` 寫入 config 檔案後，**將權限修改為 `chmod 644` (所有人皆可讀)**。由於該檔案僅存放公開的 Port 與主機名等配置資訊而不含私鑰，此設定安全無虞。
  * *修正*：在三端用戶端腳本（`anycert-windows.bat`、`anycert-linux.sh`、`anycert-macos.sh`）的 FQDN Fallback 模組中，若偵測 FQDN 失敗，皆新增**黃色 `[WARN]` 提示說明**，引導非 root SSH 使用者去伺服器端檢查或修改 `anycert.conf` 的讀取權限。
- **CA 憑證指紋亂碼與子 shell 變數展開 Bug 修正**：
  * *問題*：中文 Windows 用戶端執行 `anycert-windows.bat` 時，`CA Fingerprint` 顯示為 `-dumpRO\C` 亂碼，且若遠端 config 讀取失敗時指紋更常出錯。
  * *根因*：在 `for /f` 的 `' '` 單引號外部命令中，子 shell 預設不支援延遲展開變數 `!CA_LOCAL!`，導致 `certutil -dump` 實際拿到了字面字串 `"!CA_LOCAL!"` 並噴錯 `指定檔案找不到`。此時中文 `失敗` 二字在 UTF-8/Big5 轉碼衝突下被 `findstr` 匹配並解碼成了亂碼 `RO\C`。此外，`certutil -dump` 的輸出在中文語系下為 `憑證雜湊(sha1)`，原本的英文 `Cert Hash` 匹配規則根本無法在成功時抓到指紋。
  * *修正*：改用**與系統語系無關且不依賴 `findstr` 的原生 `certutil -hashfile` 語法**，並以 `skip=1` 和第一筆鎖定獲取。同時，在單引號中以 `%CA_LOCAL%` 代替 `!CA_LOCAL!`，確保在進入子 shell 前路徑已正確展開成實體路徑。
- **解決 netsh 防火牆命令在 if 括號內的語法截斷 Bug**：
  * *問題*：在匯入 CA 提示確認後，執行 sshd 判斷時，CMD 解析器頻繁回報 `... was unexpected at this time.` 並崩潰。
  * *根因*：在 `if ( ... )` 的括號區塊內部，執行 `netsh` 防火牆指令時包含了帶引號的規則名稱 `name="OpenSSH SSH Server (sshd)"`。由於雙引號內部的 `^` 逸出符號會失去作用，`^(sshd^)` 的右括號依然會被 CMD 解析器誤判為外層 `if` 的結束括號，進而使隨後的 `dir=in` 參數被當成 if 區塊外的垃圾指令而報錯。
  * *修正*：**徹底將 OpenSSH 偵測與安裝流程進行「100% 物理扁平化」重構**！拿掉所有 SSHD 行程的 `if ( ... )` 括號控制，改用獨立單行 `if` 設定變數，並以原生 `goto` 標籤控制流程跳轉。如此一來，在物理上沒有任何括號包覆，徹底根治 `was unexpected` 崩潰問題。
- **WSL 2 對外連線動態 netsh 提示**：
  * *功能*：在 `anycert.sh` 中偵測當前作業系統是否在 WSL 2 容器中。當偵測到 WSL 且使用者設定的實體 IP 與 WSL 的虛擬 IP 不同時，Summary 結尾會依據使用者選定的 Nginx Proxy Ports，動態產生並印出對應的 Windows `netsh interface portproxy` 以及 `netsh advfirewall` 防火牆放行指令，使用者只需複製並在 Windows 宿主機貼上執行即可通訊，極致優化 WSL 對外連接埠轉介體驗。
- **Windows 伺服器端 SMB 遠端存取 UAC 防禦**：為了解決 Windows 預設阻擋非內建 Administrator 帳號遠端存取 `C$` 共享資料夾的 UAC 限制，在 `anycert.bat` 新增了 `LocalAccountTokenFilterPolicy` 偵測與一鍵修復選項。
- **跨平台 SFTP 絕對路徑相容性修復**：修復了 Linux/macOS 透過新版 `scp` (預設為 SFTP 協定) 下載 Windows 檔案時的路徑解析 Bug（將 `:C:/anycert` 改為絕對路徑 `:/C:/anycert`）。
- **優化 `smbclient` 的密碼安全傳遞**：在 Linux 端使用 `PASSWD` 環境變數傳遞 SMB 密碼，避免密碼中的特殊字元在命令列中被截斷或被 Bash 二次展開。
- **貼心的下載錯誤排查提示高亮**：在三端用戶端將「伺服器端尚未簽發憑證」作為第一優先排查點置頂並著色，防止執行順序顛倒導致的盲點。
- **階段 14：macOS 伺服器端 Nginx 與 Homebrew 相容性、SFTP 下載優化與職責分離解耦**：
  - **自動安裝與配置 Homebrew**：若 macOS 伺服器端缺少 Nginx，自動切換為登入使用者（`SUDO_USER`）身份下載並安裝 Homebrew。並將環境變數自動設定在當前進程與寫入使用者的 `~/.zprofile` 中。
  - **解決 Homebrew Nginx 啟動權限與暫存目錄 Bug**：在 macOS 上寫入 Homebrew 的 `servers/anycert_proxy.conf` 設定，並自動建立 `var/run/nginx` 與 `var/log/nginx` 暫存目錄並將 Owner 歸給使用者，解決 `mkdir() failed` 導致的配置檢測失敗。
  - **Nginx 錯誤高亮捕捉**：重構 `nginx -t` 的檢測，若出錯時會在終端機直接印出 stderr 詳細日誌，方便秒級除錯。
  - **三端 Windows 用戶下載 SFTP 優化**：將 macOS 與 Linux 用戶端針對 Windows 伺服器的下載流程優化為：`SUDO_USER` 下的 `scp` 路徑探測（解決 root 跑 scp 讀不到本機 Keychain 的問題）並以 `/C:/anycert/...` 作為優先探測路徑。
  - **Server-Client 職責分離解耦**：在 `anycert.sh` 中回退了複雜的本地 hosts 寫入與 NSS DB 導入邏輯，簡化維護。改為在 Trust 流程結束時給予明確提示：若伺服器本機需要瀏覽器安全連線（Local Browser Access），只需以 `127.0.0.1` 為目標 IP 直接在伺服器上執行 `anycert-macos.sh` 或 `anycert-linux.sh` 客戶端安裝腳本即可。
  - **Root CA 規格加固與 Chrome Root Store 相容性**：在 `anycert.sh` 與 `anycert.bat` 生成 Root CA 時，明確使用 openssl 設定檔注入 `basicConstraints = critical, CA:true` 和 `keyUsage = critical, keyCertSign, cRLSign` 延伸屬性，強制讓憑證在 RFC 標準上具備 Root CA 的合法簽署屬性，從根本上解決了 Ubuntu 26.04 上新版 Google Chrome (Chrome Root Store 機制) 無法信任本地 CA 簽發憑證的相容性問題。
  - **Linux 用戶端 Chrome Modern NSSDB 支援**：在 `anycert-linux.sh` 新增對 Chrome M146+ 新版 NSS 共用資料庫路徑 `~/.local/share/pki/nssdb` 的自動偵測與導入/清理支援，並在終端機加上 Verbose Debug Log（自動顯示 `certutil -L` 狀態）以利排查。搭配徹底重設 Chrome 後，完美在 Ubuntu 26.04 Chrome 亮起安全鎖頭。

---

### 階段 15：用戶端 SSH Host Key 變更自動偵測與 known_hosts 清理
- **問題痛點**：當遠端伺服器被重新安裝、WSL 被重建、或者是 SSH 服務金鑰重新產生時，用戶端執行 `scp` 時會因為 `known_hosts` 記錄與遠端金鑰不符，拋出嚴重的 `REMOTE HOST IDENTIFICATION HAS CHANGED` 與 `Host key verification failed` 報錯，並直接拒絕連線。強迫使用者手動去尋找與編輯 known_hosts 檔案體驗極差。
- **三端用戶端 (Windows/Linux/macOS) 自動化防禦與修復**：
  - 在三端用戶端的 `scp` 憑證下載過程中，將錯誤日誌導向臨時檔案，並在執行失敗時主動檢查日誌內容。
  - 一旦偵測到 Host Key 變更或驗證失敗，會在終端機以顯眼的黃色 `[WARN]` 給予說明，並主動詢問使用者：「是否自動清除 known_hosts 中該 IP 的舊記錄？[y/N]」。
  - 使用者確認後，腳本會自動以 `ssh-keygen -R <SERVER_IP>` 來乾淨地移去舊的金鑰紀錄（Linux/macOS 會自動相容 `root` 與 `SUDO_USER` 的 known_hosts 目錄；Windows 則直接呼叫系統的 `ssh-keygen`），並在清理後自動重新嘗試連線，達成完全無痛的 SSH 連線重建體驗。

---

### 階段 16：修復 Nginx SSL Gateway (Profile 2) 複合埠解析與轉發提示 Bug
- **問題痛點**：在 `Nginx SSL Gateway` 模式下，`PROXY_PORTS` 中儲存的格式為 `PORT:BACKEND_IP`（例如 `3000:172.16.21.52`），非單純數字。這會導致 Windows 用戶端腳本在執行 SSL Port 數學計算時，因為傳入帶有冒號與 IP 的字串，導致 `set /a` 發生語法解析錯誤並拋出 `Missing operator.` 崩潰；同時，三端用戶端在輸出 Available HTTPS connections 列表時，也會將目標 Backend 連線網址誤植為 `http://localhost:3000:172.16.21.52` 的畸形 URL。
- **修正**：
  - **三端智慧分隔符拆分**：在三端用戶端腳本（`anycert-windows.bat`、`anycert-linux.sh`、`anycert-macos.sh`）的 HTTPS connections 列表輸出模組中，主動偵測 `PROXY_PORTS` 欄位中是否包含冒號 `:`。
  - **精準提取與計算**：若含有冒號，則自動拆分出純 Port 數字與目標 Backend IP。Windows 用戶端利用拆解後的純 Port 進行 `set /a` 計算，徹底解決 `Missing operator.` 崩潰；三端列印轉發提示時，亦正確指向各自的 Backend 目標（如 `-> http://172.16.21.52:3000`）。

---

### 階段 17：實現 Nginx 497 埠級自動 HTTP ➔ HTTPS 重導向 (Redirect)
- **問題痛點**：當服務以 SSL 監聽在特定 Port 時（例如 `https://anyc:9899`），若使用者在瀏覽器中誤打為純 HTTP（例如 `http://anyc:9899`），Nginx 會預設拒絕請求並拋出 `400 Bad Request (The plain HTTP request was sent to HTTPS port)` 錯誤，無法自動跳轉。
- **修正**：
  - **導入 497 錯誤捕獲重定向**：在伺服器端腳本 `anycert.sh` 與 `anycert.bat` 的 Nginx 配置產生區塊中，於 `server` 區段內新增 `error_page 497 https://$http_host$request_uri;` 指令。
  - **精準保留 Port 與路徑**：藉由 `$http_host`（包含原始 Port 資訊）與 `$request_uri`（包含原始路徑與參數），實現在同一個 SSL Port 上無縫、全自動地將純 HTTP 請求跳轉至安全 HTTPS 協議，極致優化終端存取體驗。
  - **Windows Excluded Port & PortProxy 故障診斷**：針對 Windows 下常因 Hyper-V / WSL2 動態保留埠範圍，或是歷史遺留的 PortProxy 轉發規則（由 `netsh interface portproxy` 註冊且重開機亦不消失）導致 `bind()` 噴錯 `10013` 造成 Nginx 測試失敗的痛點，在 `anycert.bat` 中加入精準診斷提示。指引使用者如何以 `netsh interface portproxy show all` 排查，並提供 `delete` 指令釋放該連接埠，或是引導使用者重跑並更換 `PORT_OFFSET` 避開衝突。

---

### 階段 18：優化 Windows 用戶端路徑顯示與 SMB 故障詳細報錯
- **問題痛點**：
  - 在 `anycert-windows.bat` 用戶端中，不論遠端伺服器為 Windows 還是 Linux，畫面印出的下載來源路徑（`Source`）均被固定顯示為 Linux 預設路徑 `/etc/anycert/anycert-ca.crt`，造成嚴重的視覺誤導。
  - 當 SCP 下載失敗並自動降級嘗試 SMB 連線時，若連線失敗，腳本並未輸出 `net use` 軟體的具體錯誤（例如權限不足、密碼錯誤等），直接回報連線失敗，排障資訊不足。
- **修正**：
  - **強制遠端作業系統輸入驗證**：將三端用戶端原有的 `Is the remote server running Windows Server? [Y/n]` 提示重構為更嚴謹、清晰的問句：`What OS is remote server running? (L) for Linux/WSL/macOS, [W] for Windows Family [L/W]:`。引進輸入驗證迴圈，強制使用者必須輸入 `L`/`l` 或 `W`/`w`，直接按下 Enter 或輸入其他字元會持續循環詢問，大幅降低誤按或誤設的機率。
  - **動態來源路徑展示**：在三端用戶端中，依據使用者的遠端作業系統選擇，動態設定 `CA_REMOTE` 變數（Windows 伺服器設為 `/C:/anycert/anycert-ca.crt`，Linux 伺服器設為 `/etc/anycert/anycert-ca.crt`），讓畫面上顯示的來源下載路徑百分之百正確。
  - **三端 SMB 錯誤資訊實體輸出與排障指南**：
    - 在三端用戶端腳本（`anycert-windows.bat`、`anycert-linux.sh`、`anycert-macos.sh`） the SMB 複製失敗路徑中，不再吞掉錯誤輸出，而是實體將 `net use`、`smbclient` 或 `mount_smbfs` 的錯誤輸出印在畫面上。
    - 同步於三端錯誤路徑中增加黃色 `[Tip]` 指引，明示 `Access is denied` / `NT_STATUS_ACCESS_DENIED` 錯誤乃是由於 Windows 遠端 UAC 限制引起，引導使用者使用內建 `Administrator` 連線，或是直接提供手動繞過指令（`reg add ...`），省去對伺服器腳本的依賴。
  - **移去伺服器端 UAC 阻塞與自動修改（極簡安全重構）**：徹底清理了伺服器端 `anycert.bat` 中所有自動修改登錄檔、寫入備份與卸載時還原的 Legacy 邏輯，並移除全部的阻塞式 `set /p` 詢問。開頭僅保留一個非阻塞、無害的 `[UAC Guard Note]` 冷知識提醒，100% 避免打擾不需要 SMB 功能的 Linux/macOS 用戶，將主控權完全交還給使用者。
  - **雙語 README 加入 UAC 重要說明**：於 `README.md` 及 `README_tw.md` 中，針對 Windows SMB 管道特別追加 UAC 管理員降權防禦說明，指導使用者使用 Built-in `Administrator` 或手動執行伺服器 UAC 機碼一鍵解除與還原，確保文檔與程式碼功能 100% 同步。


### 階段 19：基於 Nginx + HTTP Curl 的無密碼、免 SSH/SMB 自動傳輸與 4 級容災降級設計
- **問題痛點**：
  - 原本的憑證傳輸管道極度仰賴 SSH（SCP）或 SMB 共享通道。對於絕大多數以 `Profile 1 (Nginx SSL Proxy)` 或 `Profile 2 (Nginx SSL Gateway)` 部署的用戶而言，雖然伺服器本來就已經跑著 Nginx 的 Web 服務，卻依然必須為用戶端開通 SSH 埠（22）、SMB 埠（445），且需要繁瑣地輸入 SSH 密碼、設定公私鑰、或是手動排除複雜的 Windows UAC 權限，體驗不夠平滑。
- **修正與架構革新**：
  * **Nginx 80 埠智慧衝突探測與唯讀端點暴露**：
    - 在伺服器端腳本（`anycert.sh` 與 `anycert.bat`）中，引進了 **80 埠衝突智慧探測**。當偵測到本機的 80 埠已被其他服務佔用時，自動跳過 Nginx 80 埠的配置生成，徹底消除了 Port 衝突導致 Nginx 啟動失敗的致命隱患。
    - 若 80 埠未被佔用，則正常生成 80 埠 HTTP server，並預設新增兩個唯讀 location 端點：`/anycert/anycert-ca.crt` 與 `/anycert/anycert.conf` 用於憑證傳輸。
  * **SSL 埠雙軌下載備援機制**：
    - 同步在伺服器端產生的**每一個 SSL (HTTPS) server 區塊**內，亦寫入這兩個 `/anycert/` 唯讀端點。這提供了多重保險的備援通道：即使 80 埠因衝突被跳過，用戶端依然能透過已開通的 HTTPS 埠（如 13000）安全、免密碼地完成憑證拉取。
  * **用戶端四級傳輸降級鏈路與 SSL 埠拉取優化 (HTTP/HTTPS ➔ SCP ➔ SMB ➔ 手動)**：
    - 三端用戶端腳本（`anycert-windows.bat`、`anycert-linux.sh`、`anycert-macos.sh`）在啟動時，會第一優先發送 HTTP curl 請求（Port 80）下載憑證。
    - **SSL 埠自動探測**：若 80 埠下載失敗（如 80 埠被佔用或未開），用戶端會自動嘗試向一系列熱門的 SSL 備援埠（如 `13000`, `18080`, `21434`, `16502` 等）發送 `curl -k` (HTTPS) 探測拉取，大幅提升免密碼下載的成功機率。
    - **零密碼、秒級下載**：若 HTTP/HTTPS 端點下載成功，腳本會直接跳過後續所有 SSH/SCP 密碼輸入與 SMB 權限驗證流程，一秒內自動完成本機 CA 信任導入與 hosts 解析。
    - **強健的 Fallback 鏈路**：若 HTTP/HTTPS curl 皆失敗，用戶端會完全透明、無縫地向後降級至 SCP (SSH) -> SMB (Windows) -> 手動複製模式，確保在任何環境下皆能 100% 成功部署。
  * **文檔同步與 Profile 3/4 擴充引導**：
    - 更新 `README.md` 與 `README_tw.md` 將 HTTP/HTTPS Curl 註冊為第一優先 (Priority 1) 管道，並提供 Nginx location snippet 說明，引導 Profile 3 和 4 的自訂 Web 伺服器使用者手動加上此 location 以享受無密碼下載的超凡體驗。

---

### 階段 17：Nginx 原生首頁 (Landing Page) 與伺服器本地 Zero-Password 用戶端腳本分發
- **問題痛點與架構解耦**：
  - Nginx 部署完成後，預設首頁為原始 `Welcome to nginx!`，缺乏視覺吸引力與功能提示。
  - 原先用戶端下載腳本連結指向 GitHub Releases，缺乏離線/內網環境韌性，且需要連外網路。
  - 舊版 Client Setup 摘要步驟以 SCP/SSH 密碼手動下載為主，未能突出 Zero-Password HTTP 首頁下載優勢。
- **現代化 Nginx Landing Page (`public/index.html` & `public/banner.svg`)**：
  - 設計高顏值深色主題首頁，內建 AnyCert 多色 ASCII Banner SVG 霓虹光暈動畫、Server Info 卡片與 HTTPS Proxy Ports 反代埠卡片。
  - **動態 Conf 渲染**：利用純 JavaScript 在瀏覽器端發送 AJAX 請求 `fetch('/anycert/anycert.conf')`，即時解析 `PROXY_PORTS`、`PORT_OFFSET`、`SERVER_FQDN`、`SERVER_IP` 與 `PROFILE`，完全免去伺服器端樣板字串替換。
  - **響應式卡片列表 (Port Cards)**：捨棄傳統 3 欄 Table 佈局，改用垂直彈性卡片顯示各個代理埠的 FQDN 連結、IP 連結與 Backend Target，徹底消除水平滾動條 (Horizontal Scrollbar)。
- **伺服器本地端 Zero-Password 用戶端腳本分發**：
  - 伺服器端腳本（`anycert.sh` / `anycert.bat`）部署時，會自動將三端用戶端腳本（`anycert-windows.bat`、`anycert-linux.sh`、`anycert-macos.sh`）複製至憑證目錄與 Nginx `html` 根目錄中。
  - Nginx 在 Port 80 與所有 SSL Wrapper 埠自動注入 `/anycert/anycert-*.bat/sh` location 路由，點擊首頁下載按鈕即可直接從本地伺服器下載安裝腳本，達成 100% 離線無密碼部署。
- **客戶端安裝摘要三選項重構 (Option A / B / C)**：
  - 重構 `anycert.sh` 與 `anycert.bat` 的完成摘要，將 **Option A: Web Browser One-Click Setup [Recommended ⭐]** 置頂，引導使用者開啟 `http://<SERVER_IP>/` 下載安裝；`Option B` 為命令列/遠端腳本執行；`Option C` 為純手動模式。
- **用戶端作業系統智慧自動偵測 (Client OS Auto-Detection)**：
  - 於 `index.html` 整合 `detectOS()` 函式，利用 `navigator.userAgentData.platform` 與 `User-Agent` 即時判定連線裝置作業系統（Windows / Linux / macOS）。
  - 自動將符合當前裝置作業系統的下載按鈕設定為滿色亮青色高亮 (Primary Button)，並動態加上 `DETECTED` 徽章，大幅提升使用者體驗。
- **修復傳入 `-s <server-ip>` 時仍跳出 [1-2] 下載選單問題與選項名稱更新**：
  - *問題*：當傳入 `-s <server-ip>` 參數時，先前版本仍會彈出已註冊伺服器選單與 `Please choose how to download/import [1-2]` 詢問提示，且選項名稱仍顯示為舊版的 `via SSH`。
  - *修正*：帶入 `-s <server-ip>` 時自動跳過一切前置選單並自動預設 `IMPORT_MODE=1`；同步將選項 1 的文字更新為 `Automatic Download (HTTP / SSH / SMB) [Default]`，精準反映當前多元傳輸機制。
- **新增 Port 443 標準 HTTPS 導覽頁支援與動態連線安全狀態條 (Security Status Bar & CA Trust Probe)**：
  - *問題*：使用者在尚未安裝 CA 憑證前連線 `http://<SERVER_IP>/` 顯示「不安全」；但在執行完安裝腳本後重新重新整理 `http://<SERVER_IP>/`，瀏覽器因仍處於明文 HTTP 80 埠，網址列依然顯示「不安全」，容易誤導使用者以為憑證安裝失敗。
  - *修正*：
    1. 伺服器端（`anycert.bat` / `anycert.sh`）自動偵測並開啟 Port 443 標準 HTTPS 導覽頁區塊，使 `https://<SERVER_IP>/`（無需輸入任何連接埠）亦可直接存取 AnyCert 導覽頁。
    2. `public/index.html` 新增 **動態連線安全狀態條 (`.sec-bar`)** 與背景 CA 探測機制。若為 HTTP 連線且背景探測發現 CA 已成功信任，會即時顯示亮眼綠色徽章 `✨ AnyCert Root CA Trusted on your Device!` 並附上 `🔒 Switch to https://<SERVER_IP>/` 一鍵切換按鈕，使用者點擊即可看見亮起的安全綠鎖頭 🔒，徹底解決誤導問題。
    3. `public/index.html` 在三平台執行指令下方顯眼標示「請關閉並重新開啟瀏覽器（或開新無痕視窗）以載入已信任的 Root CA 憑證並順利顯示 🔒 HTTPS 安全鎖頭」溫馨提示。
- **優化 Nginx 啟用時自動跳過冗餘的 Windows OpenSSH Server 安裝詢問**：
  - *問題*：在舊版中，`anycert.bat` 完成部署後會檢查並詢問使用者「是否安裝與啟用 OpenSSH Server」。但在當前架構下，Nginx 已經成功運作並經由 HTTP (Port 80) / HTTPS (Port 443 / SSL 埠) 提供零密碼自動化憑證與腳本下載，繼續詢問安裝 OpenSSH 已無必要且增加互動成本。
  - *修正*：當使用 Nginx 模式（Profile 1, 2, 3）部署完成時，`anycert.bat` 自動跳過 OpenSSH 安裝詢問，實現更流暢、更少打擾的一鍵部署體驗。
- **新增 AnyCert 品牌向量 Favicon (Shield + Lock SVG Icon)**：
  - 設計並新增 `public/favicon.svg` 向量圖示（包含深色背景、Cyan/Blue 漸層安全盾牌與金色 SSL 金屬鎖頭）。
  - 於 `public/index.html` 內嵌 inline Data URI Favicon，使瀏覽器分頁標籤在零額外 HTTP 請求下秒級顯示專屬 AnyCert 鎖頭分頁圖示。

### 階段 18：官方 GitHub Pages 展示網站 (`docs/index.html`) 與中英雙語切換 Engine
- **打造專業 GitHub Pages 官方展示網站**：
  - 於 `docs/index.html` 建立專為 GitHub Pages 發布的單頁式（Single-Page Application）官方導覽展示網站。
  - **視覺美學與 Logo 呼吸燈動畫**：採用 AnyCert 經典深海黑 (#0d1117) 與青藍發光色調，並為 AnyCert 向量 Banner SVG 加入 `@keyframes pulse-glow` 霓虹呼吸燈光暈動畫。
  - **中英雙語無縫切換 Engine**：頂部導覽列提供 `繁體中文` <-> `English` 一鍵切換按鈕，免重載頁面並自動記憶偏好設定 (`localStorage`)。
  - **完整的章節架構**：
    1. *Hero 主視覺區塊*：霓虹 Logo、雙語動態標題、一鍵快速開始與 GitHub Star 按鈕。
    2. *痛點與架構對比 (Before vs. After)*：明文 HTTP 不安全警告 vs. AnyCert 10 年內網信任 CA 綠色鎖頭卡片對比。
    3. *五大 Profile 展示區*：單機反代、SSL Gateway、Custom Path、僅簽發、PVE 節點支援。
    4. *互動式快速入門 (Quick Start)*：分頁切換 Server 端與 Client 端安裝指令，附帶一鍵複製剪貼簿按鈕。
    5. *畫面展示畫廊 (Screenshots & Lightbox)*：整合 `pic/` 的終端機與 Nginx 網頁截圖，支援點擊彈窗全螢幕放大檢視 (Lightbox Modal)。
    6. *常見問題 (FAQ Accordion)*：折疊式卡片解答連線、無網域名稱、Tailscale IP SAN 與反安裝說明。

---

### 階段 20：修正 macOS 下 Homebrew Nginx launchctl bootstrap 提權啟動崩潰 Bug
- **問題痛點**：在 macOS 上以 `sudo bash anycert.sh` 執行腳本時，當啟動 Nginx daemon 時，腳本先前的邏輯會呼叫 `sudo "$BREW_CMD" services start nginx`。在 macOS (Sonoma/Sequoia) 上，Homebrew 嚴格禁止在 root/sudo 權限下呼叫 `brew services` 註冊 LaunchDaemons，會噴出 `Warning: nginx must be run as non-root to start at user login!` 並被 macOS 的 `launchctl` 拒絕，拋出致命的 `Bootstrap failed: 5: Input/output error` 報錯中斷 exit。
- **修正**：
  - **繞過 Homebrew Services，直呼原生 `nginx` 守護行程**：在 macOS 平台上，啟動 Nginx 時不再呼叫 `brew services start nginx`，而是直接呼叫全域可執行的 `nginx` 原生命令啟動 master process。
  - **解決權限與 Launchctl 碰撞**：呼叫 `nginx` 原生指令能在擁有 `root` 權限下直接綁定 `80` 與 `443` 等特權 Ports，並完全避開 macOS `launchctl` 服務管理器被阻擋的權限衝突，達成 100% 平滑且穩定的 Nginx 啟動與 `nginx -s reload`。

---

### 階段 21：官方展示網站 Lightbox 互動縮放、常駐控制列、相容性矩陣對齊與 SVG 架構圖色塊分組
- **Lightbox 全螢幕大圖視窗與 150% 互動 Zoom In / Out**：
  - 將燈箱預設圖檔尺寸上限擴展至 `95vw` / `90vh`。
  - 支援點擊圖檔或按鈕自由切換 **150% 實體大圖縮放 (`width: 140vw`)** 與 fit-to-screen 原尺寸；採用 `margin: auto` 彈性滾動佈局，徹底解決 Flexbox 垂直置中導致大圖頂部被截斷無法向上捲動的 CSS 經典 Bug。
- **燈箱控制列 (Lightbox Toolbar) Viewport 常駐釘選 (Always On Top)**：
  - 將控制列 `#lightbox-toolbar` 提升為 `body` 直屬頂層元素，徹底解耦 `backdrop-filter` 建立的包含塊限制。
  - 設定最高的 `z-index: 99999` 與 `position: fixed`，使 `🔍 放大 150%` 與 `✕ 關閉` 按鈕在使用者滾動平移 (Pan) 圖檔時 100% 常駐螢幕右上角。
- **相容性矩陣 (Compatibility Matrix) X/Y 軸對調與全功能對齊**：
  - 將「用戶端信任導入相容性 (Client Side)」表格的 X/Y 軸對調，讓平台標題 (Windows, Linux, macOS) 成為頂部欄位，與「伺服器端部署相容性」達到 100% 的結構對稱與閱讀邏輯統一。
  - 於伺服器端相容性表格底部同步補齊「一鍵反安裝 (`-u`) 支援」列。
- **SVG 架構流程圖實體伺服器色塊外框重構**：
  - *Profile 1 (Single-Host)*：將 Local Nginx Proxy 與 Open-WebUI / Ollama 統一包裹於 **`🖥️ Server A (Single Host)`** 虛線色塊外框內。
  - *Profile 2 (SSL Gateway)*：獨立劃分 **`🌐 Gateway (VM / LXC)`** 網關框、**`🖥️ Server A (NAS)`**、**`🖥️ Server B (Apps)`** 共享框（包含 Home Assistant 與修正後的 OctoPrint `172.16.21.51:15000 ➔ :15000`）與 **`🖥️ Server C (Dev)`** 框。

---

### 階段 22：新增單機本地受信 Q&A 問答至全站文檔與展示頁
- **需求**：解答使用者關於單一一台電腦是否可做本地受信的疑慮。
- **更新內容**：
  - **`docs/index.html` (官方展示頁)**：在 FAQ 折疊卡片中新增 Q5「可以在單一一台電腦上完成本地受信設定嗎？」，支援中英雙語切換。
  - **`README_tw.md` (繁體中文)**：新增「常見問題與問答 (Q&A)」章節，說明跑 Server 腳本並將 IP 指定為 `127.0.0.1` 後，Windows 平台可自動詢問匯入信任區免跑 Client 腳本；Linux/macOS/WSL 平台則在同一台電腦跑對應 Client 腳本即可。
  - **`README.md` (English)**：同步新增 Frequently Asked Questions (FAQ) 章節，為英文使用者提供對等說明的問答卡片。

---

### 階段 23：新增雙網卡 / 虛擬 IP (IP Alias) 單機融合模式 (Fusion Mode) FAQ 與避雷指南
- **需求**：解答使用者是否能透過雙網卡或虛擬 IP (IP Alias) 在單機上實現 Profile 2 的 1:1 Port 轉發（`https://IP-B:3000` 🔒 &rarr; `http://IP-A:3000` 🔓），並完整提供架構運作原理與關鍵避雷指南（如 `0.0.0.0` 綁定衝突、雲端 IP 申購與重啟持久化）。
- **更新內容**：
  - **`docs/index.html` (官方展示頁)**：在 FAQ 卡片擴充 Q6，以清單與雙語標籤完整說明融合模式 (Fusion Mode) 架構路由與三大避雷重點。
  - **`README_tw.md` (繁體中文)**：在 Q&A 章節同步補齊豐富的單機 1:1 Port 轉發架構與避雷說明。
  - **`README.md` (English)**：在 FAQ 章節同步新增對等的 Fusion Mode Architecture & Pitfalls 問答。
- **💡 融合模式不自動化腳本化之戰略考量 (Strategic Decision & Rationale)**：
  - **決策**：融合模式**僅作為 FAQ 進階指引，不寫入 `anycert` 的自動化 CLI 腳本選單**。
  - **考量一（跨平台 IP 設置與持久化天坑）**：Linux 發行版網路設定檔格式天差地別（Ubuntu Netplan, Debian interfaces, RedHat NetworkManager, Windows netsh），自動化配發 IP Alias 且確保重啟不失聯維護成本極高。
  - **考量二（`0.0.0.0` 監聽衝突無法自動修復）**：多數 Docker 容器或 Web 服務預設綁定 `0.0.0.0:PORT`，即使腳本建立 IP-B，Nginx 啟動時仍會因 `EADDRINUSE` 崩潰，腳本無法自動改寫使用者本機所有第三方程式與容器的連接埠綁定。
  - **結論**：進階玩家參照 FAQ 手動配置即可，普通使用者維持 Profile 1 (+10000 偏移) 或 Profile 2 (獨立 VM/Gateway)，確保 `anycert` 腳本的極簡與百分之百穩定。

---

### 階段 24：新增軟路由 (OpenWrt / pfSense / iStoreOS) 競品對比 FAQ
- **需求**：解答使用者「為何不直接用軟路由內建 ACME 簽發憑證即可，而需要使用 AnyCert？」的疑慮。
- **更新內容**：
  - **`docs/index.html` (官方展示頁)**：在 FAQ 卡片新增 Q7 說明 AnyCert 與軟路由在「離線/零 Domain 依賴」、「跨平台端到端自動信任庫導入」與「零網路拓撲變更」的三大差異。
  - **`README_tw.md` (繁體中文)**：在 Q&A 章節同步補齊軟路由對比問答。
  - **`README.md` (English)**：在 FAQ 章節同步新增對等的 Soft Router (OpenWrt/pfSense) Comparison 問答。



### 階段 25：新增行動裝置 (iOS / Android) 憑證導入與 IP SAN 直連 FAQ、首頁 Mobile 指南與 SVG 標籤優化
- **需求**：解答使用者「手機和平板 (iOS / Android) 是否可以使用 AnyCert 簽發的憑證」與具體匯入步驟，優化 Nginx 伺服器首頁空白處，並精簡 Profile 2 SVG 流程圖標籤。
- **更新內容**：
  - **`docs/index.html` (官方展示頁)**：在 FAQ 卡片新增 Q8 說明 IP SAN 讓手機免改 hosts 直連存取（`https://<SERVER_IP>:xxxx`）的特性，提供 iOS「完全信任」與 Android 導入步驟；並將 Profile 2 SVG 流程圖中的標籤精簡更新為 `Server B (Apps)`。
  - **`public/index.html` (Nginx 伺服器首頁)**：在 Server Info 卡片 `Root CA` 連結下方空白處新增「📱 Mobile CA Setup (iOS / Android)」引導步驟，利於手機用戶直連下載與啟用信任。
  - **`README_tw.md` (繁體中文)**：在 Q&A 章節同步補齊 iOS / Android 手機連線 IP vs FQDN 說明與導入憑證指南。
  - **`README.md` (English)**：在 FAQ 章節同步新增 Mobile Devices (iOS / Android) IP vs FQDN Setup 指南。

---

### 階段 26：Nginx 伺服器預設首頁 (`public/index.html`) 全站雙語 i18n 切換支援
- **需求**：對齊官方展示頁，讓內網 Nginx SSL 伺服器落地的 landing page (`public/index.html`) 也支援瀏覽器語系自動偵測與「🌐 繁體中文 / English」手動一鍵切換。
- **更新內容**：
  - **`public/index.html`**：加入右上角 Floating 語言切換按鈕 (`#lang-toggle-btn`)，將所有文字標籤、卡片標題、連線安全狀態條 (.sec-bar)、用戶端安裝指引與 Mobile 指南包裹為雙語標籤，並透過 JavaScript 結合 `localStorage` 與 `navigator.language` 實現無縫切換。

---

### 階段 27：相容性對比表更新 (Proxmox VE 9 & Arch 暫除)
- **需求**：更新官方網站 (`docs/index.html`) 伺服器端與用戶端部署相容性矩陣對比表。
- **更新內容**：
  - **Proxmox VE 相容性**：標記由 `(PVE 7 / 8)` 更新為 `(PVE 7 / 8 / 9)`（實測 Proxmox VE 9 運作無虞）。
  - **Linux 發行版相容性**：標記由 `(Ubuntu/Debian/Arch)` 調整為 `(Ubuntu/Debian)`，並自包管理器清單中移除 `pacman`（Arch 未經完整實機驗證先予除名）。

---

## 🏗️ 架構與組件角色

### 🖥️ 伺服器端腳本
- [anycert.sh](anycert.sh) (Linux/macOS 伺服器)：
  - 負責產生 Root CA（10年）與伺服器憑證（825天）。
  - 提供五大部署選項：一鍵 Nginx 反代（HTTPS Port = HTTP Port + 自訂偏移量，預設 +10000）、Nginx SSL Gateway、自訂路徑部署、僅產生憑證，以及 Proxmox VE (PVE) 自動替換（僅在 PVE 系統顯示）。
- [anycert.bat](anycert.bat) (Windows 伺服器)：
  - 尋找 Git 內建的 OpenSSL 或系統 OpenSSL 簽發憑證。
  - 支援 Windows 本地端一鍵 Nginx 反代安裝與配置（選單順序與 `anycert.sh` 對齊：`[1] Nginx SSL Proxy（預設）` / `[2] Nginx SSL Gateway` / `[3] Custom Path` / `[4] Generate Only` / `[5] Proxmox VE（僅 PVE 系統顯示）`）。
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

用於記錄各腳本在各個平台上的實際測試與支援狀態。（✅ 代表測試通過，❌ 代表不支援，⚠️ 代表不適用，`空白` 代表待測試）

### 1. 伺服器端部署 (Server Setup)
| 腳本名稱 \ 伺服器平台 | Windows | Linux | macOS | WSL | PVE |
| :--- | :---: | :---: | :---: | :---: | :---: |
| `anycert.???`        | .bat  | .sh   |  .sh  | .sh  | .sh |
| -> server setup      |  ✅  |  ✅  |  ✅  | ✅  | ✅ |
| local browser access |  ✅  |  ✅  |  ✅  | ✅  | N/A (No GUI) |
| -> need local client setup?| ✅ no |  ✅ yes  |  ✅ yes  | ✅ yes | N/A (No GUI) |

### 2. 用戶端信任導入 (Client Setup)
| 腳本名稱 \ 伺服器平台 | Windows | Linux | macOS | WSL | PVE |
| :--- | :---: | :---: | :---: | :---: | :---: |
| `anycert-linux.sh`    |  ✅  |  ✅  |  ✅  |  ✅  |  ✅  |
| `anycert-macos.sh`    |  ✅  |  ✅  |  ✅  |  ✅  |  ✅  |
| `anycert-windows.bat` |  ✅  |  ✅  |  ✅  |  ✅  |  ✅  |

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
5. **在 Commit/Push 前進行 Bash 語法靜態檢測**：
   - 任何對 `.sh` 腳本（`anycert.sh`、`anycert-linux.sh`、`anycert-macos.sh`）的變更，在 Commit/Push 之前，**必須**在終端機執行 `bash -n <script_name>` 進行語法靜態檢測，徹底避免遺漏 `done`、`fi` 等低級語法解析錯誤。
   - 任何 `local` 變數宣告必須嚴格限定在 shell 函數（function）內部使用，嚴禁在頂層腳本 scope 中宣告，以免在執行時拋出語法異常。

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
- [ ] **Web 管理介面 (Profile [1] & [2] 專用)**：
  - 針對已部署 Nginx 的 Profile [1] Nginx SSL Proxy 和 Profile [2] Nginx SSL Gateway，開發基於瀏覽器的 Web 管理介面。
  - 利用現有 Nginx HTTPS 基礎，直接使用靜態 HTML/JS 頁面服務，無需額外 API 進程。
  - 用戶端直接登入 server 端的 cert management site，選擇平台後下載打包好的 zip 檔案。
  - zip 包含：CA 憑證、專屬 client 腳本（已預配置 server IP/FQDN）、安裝說明。
  - 用戶下載後解壓執行腳本即可自動導入憑證，免除手動執行 client script 的複雜操作。
  - 預設監聽 localhost:8443，可選擇開放遠端存取（需基本認證）。

