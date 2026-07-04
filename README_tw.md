![anycert](pic/banner.svg)

# anycert — 自託管伺服器 HTTPS 憑證管理器，每台用戶端都受信任。

瀏覽器的私有伺服器憑證警告，永久消失。支援 Proxmox VE, OpenMediaVault, Unraid, LLM 伺服器, Nginx 等任何自託管伺服器。

伺服器一個指令，每台用戶端一個指令 — 瀏覽器顯示鎖頭，十年內持續有效，完全離線運作，不需要任何公開網域。

[English](README.md) | **繁體中文**

---

## 檔案說明

### 伺服器端 (產證與套用)
| 檔案 | 平台 | 用途 |
|------|------|------|
| `anycert.sh` | Linux (含 WSL) / macOS 伺服器 | 產生 Root CA + 伺服器憑證，支援 PVE、Nginx 反代一鍵代理 (推薦)、自訂路徑套用與服務重啟 |
| `anycert.bat` | Windows 伺服器 | 產生 Root CA + 伺服器憑證，支援 Nginx 反代一鍵代理 (推薦)、自訂路徑套用與指令重啟 |

### 用戶端 (下載與信任)
| 檔案 | 平台 | 用途 |
|------|------|------|
| `anycert-windows.bat` | Windows 用戶端 | 下載 CA 憑證、更新 hosts、匯入 Windows 信任存放區 |
| `anycert-linux.sh` | Linux 用戶端 (Ubuntu/Debian) | 下載 CA 憑證、更新 hosts、匯入系統與瀏覽器 (Chrome/Firefox) 信任存放區 |
| `anycert-macos.sh` | macOS 用戶端 | 下載 CA 憑證、更新 hosts、匯入 macOS Keychain |

---

## 為什麼要用 anycert？（方案比較表）

處理自託管內網 Web UI 的 TLS 憑證有幾種常見方式，下表詳細比較各方法的差異。

| 特性 | **預設自簽憑證** | **Let's Encrypt (DNS-01 / Cloudflare)** | **Tunnel 服務 (Cloudflared / ngrok)** | **Mesh VPN (Tailscale HTTPS)** | **anycert (本腳本)** |
|---|---|---|---|---|---|
| **瀏覽器鎖頭 🔒** | ❌ 警告（需每年重新手動信任） | ✅ 有 | ✅ 有 | ✅ 有 | ✅ 有（完成用戶端設定後） |
| **需要公開網域** | ✅ 否 | ❌ 是 | ❌ 是 | ✅ 否 | ✅ 否 |
| **需要網際網路連線** | ✅ 否 | ❌ 是 | ❌ 必須連網 | ❌ 必須連網 | ✅ 否 — 完全離線可用 |
| **主機名稱公開曝露** | ✅ 否 | ❌ 是 (CT logs) | ❌ 是 (CT logs) | ✅ 否 | ✅ 否 |
| **可在隔離 LAN 使用** | ✅ 是 | ❌ 否 | ❌ 否 | ❌ 否 | ✅ 是 |
| **更新後用戶端重設** | ❌ 是（每年更新都要重做） | ✅ 不需要 | ✅ 不需要 | ✅ 不需要 | ✅ 不需要 — Root CA 10年受信任 |
| **資料不繞經外網** | ✅ 是 | ✅ 是 | ❌ 否（繞經邊緣節點） | ❌ 否（通常需要打洞或中繼） | ✅ 是 — 純區域網路速度 |
| **多用戶端信任** | 每台每更新一次手動一次 | 自動 | 自動 | 每台都要安裝用戶端軟體 | 每台用戶端只需設定一次 |
| **費用** | 免費 | 免費 | 免費 / 部分付費 | 免費 / 企業收費 | 免費 |
| **以 FQDN 存取** | ✅ 是 (截警告) | ✅ 是 | ✅ 是 | ✅ 是 (限 `*.ts.net`) | ✅ 是 |
| **以 IP 存取** | ✅ 是 (截警告) | ❌ 否 | ❌ 否 | ❌ 否 | ✅ 是 (SAN 包含 IP) |
| **設定複雜度** | 無 | 中高 | 中 | 中 | 低 |

### 各方法適用情境
- **Let's Encrypt + Cloudflare**：適合家裡有公開網域，且不介意主機名稱暴露在 Certificate Transparency Logs 中的 Homelab 用戶。
- **Cloudflared / ngrok**：適合需要從外網存取內網服務的人，但有隱私安全疑慮，且無法在離線/無網網路下運作。
- **Tailscale HTTPS**：適合已經全站部署 Tailscale 的環境，但必須連網更新憑證，且所有用戶端都必須加入同一個 Tailnet。
- **anycert**：推薦用於任何**無公開網域、處於內網隔離環境、或不希望服務暴露至外網**的自託管基礎設施。其核心優勢是**完全離線**、**資料安全不經外網**，且**支援直接以 IP 存取**。

---

## 🔒 為什麼內網也需要 HTTPS？

在區域網路 (LAN) 中使用 HTTPS，除了**消除瀏覽器紅色不安全警告**外，還有以下幾個非常關鍵的技術與實務原因：

### 1. 啟用現代瀏覽器的進階功能 (Secure Contexts 限制)
現代瀏覽器（如 Chrome, Safari, Edge）基於隱私安全防護，規定許多強大的 Web API 僅能在**「安全上下文 (Secure Contexts)」**中執行（即 `https://` 網址，或是**僅限在伺服器本機上存取時的 `http://localhost`**）。

若您從區域網路內的其他裝置（例如您的手機、平板或其他筆電）使用普通的 `http://` 加上內網 IP 或自訂 FQDN 連線，瀏覽器會判定為不安全環境，並**強行禁用**以下功能：
- **剪貼簿操作 (Clipboard API)**：這是最常見的痛點！在 AI 聊天室（如 Open WebUI, LLMChat）中，如果使用 HTTP 跨裝置連線，點擊「複製程式碼塊 (Copy Code)」按鈕將會**直接失效**。
- **麥克風與相機 (Microphone & Camera)**：若您使用語音對話 AI（Speech-to-Text），非 HTTPS 網址瀏覽器將**無法存取您的麥克風進行收音**。
- **PWA 應用安裝 (Progressive Web Apps)**：無法將網頁服務安裝到桌面或手機主畫面，也無法使用背景推送與快取 (Service Workers)。
- **外部硬體支援**：包括藍牙 (WebBluetooth)、USB 裝置 (WebUSB)、MIDI 鍵盤、搖桿 (Gamepad API) 等硬體互動。
- **安全憑證與無密碼登入 (Web Crypto / Passkeys)**：無法在該網頁上註冊金鑰。

### 2. 防止區域網路內的密碼與 Token 被竊聽
在公司、學校、共享出租套房、或公共 Wi-Fi 等區域網路環境中，未經加密的 HTTP 流量很容易被同網路的其他人使用網路嗅探工具（如 Wireshark）側錄。HTTPS 能將所有傳輸加密，防止：
- 您的自託管服務登入密碼外洩。
- 傳輸的 AI API Keys (如 OpenAI/Claude Tokens) 被竊取。
- LLM 聊天隱私與資料庫內容被中途監聽。

---

## 💡 關鍵機制：10 年 CA 與 825 天憑證

**為什麼 Root CA 有效期是 10 年（3650 天），而伺服器憑證只有 825 天？**
現代瀏覽器與作業系統（例如 Apple iOS/macOS Safari 與 Google Chrome）基於安全政策，規定私有 CA 簽發的 SSL/TLS 伺服器憑證（分葉憑證）最長有效期不能超過 **825 天**（約 2.2 年）。若設定超過這個天數，瀏覽器會直接拒絕連線並顯示錯誤。

因此 `anycert` 採用雙層架構：
1. **Root CA (10年)**：寫入用戶端信任存取區。10 年之內完全不需要變更。
2. **伺服器憑證 (825天)**：安裝在您的自託管伺服器上。
由於 Root CA 在這 10 年內不變，**當伺服器憑證到期時，您只需在伺服器端重新跑一次腳本更新伺服器憑證，所有用戶端完全無感，不需要進行任何重新匯入或設定**。這實現了「一次設定，終身免重設」的最佳體驗。

---

## 安裝步驟

### 步驟一 — 在伺服器端執行 (產生憑證)

#### Linux (含 WSL) / macOS 伺服器：
在伺服器上 clone 此 repo 並執行 `anycert.sh`：
```bash
git clone https://github.com/anomixer/anycert.git
cd anycert
sudo bash anycert.sh
```
腳本將會：
1. 自動偵測 IP、主機名稱與 FQDN。
2. 提供三個服務部署設定檔 (Service Profile) 選擇：
   - **Auto-Setup Nginx SSL Proxy [Lazy-Friendly / Recommended] (一鍵代理模式)**：自動偵測伺服器目前正在監聽的 TCP Ports，引導您選擇要對外開通的服務，一鍵幫您裝好 Nginx，並建立 `HTTPS Port+10000` 到 `HTTP Port` 的反向代理封裝（完美相容 WebSockets 連結，如 Open WebUI 等服務）。
   - **Proxmox VE (PVE)**：自動備份並覆蓋 PVE 預設憑證，並重啟 `pveproxy`。
   - **Custom Path**：自訂憑證與金鑰複製目標路徑，並可設定自訂的重啟/重載服務指令（適用於已有現成服務的環境）。
   - **Generate Only [Painful / Hard Way]**：僅產生檔案於 `/etc/anycert/` 中，供手動套用。

#### Windows 伺服器：
以**系統管理員身分**執行命令提示字元 (cmd) 並執行：
```cmd
anycert.bat
```
腳本將會搜尋系統中的 OpenSSL（例如 Git for Windows 內建的 OpenSSL），簽發憑證後，提供與 Linux 完全一致的 Nginx 一鍵代理功能（自動下載 Nginx 設定並啟動），或允許您將憑證部署到自訂路徑（如 IIS）。

---

### 步驟二 — 在每台用戶端執行 (信任 CA)

依用戶端的作業系統，在用戶端機器執行對應的腳本：

#### Windows 用戶端：
右鍵點擊 `anycert-windows.bat` → **以系統管理員身分執行**。
```cmd
anycert-windows.bat
```

#### Linux 用戶端 (Ubuntu / Debian)：
```bash
sudo bash anycert-linux.sh
```

#### macOS 用戶端：
```bash
sudo bash anycert-macos.sh
```

這些腳本會：
1. 提示輸入伺服器 IP 與 SSH 使用者名稱。
2. 智慧偵測伺服器 OS，並自動透過 `scp` 下載 Root CA 憑證。
3. 透過 SSH 偵測伺服器的 FQDN，並自動寫入用戶端的 `hosts` 檔案中。
4. 將 CA 憑證匯入系統信任區（Linux 版會同時自動匯入 Chrome 與 Firefox 的 NSS 憑證庫）。

---

### 步驟三 — 享受 HTTPS 🔒
重啟瀏覽器，您就可以透過 FQDN 或 IP 網址安全連線了：
- `https://<your-server-fqdn>:<port>`
- `https://<your-server-ip>:<port>`

---

## 部署範例 (自定義服務套用)

### 1. Nginx 一鍵反向代理 (適用於多容器 / 多服務並存，最懶人推薦)
若您在伺服器上同時跑了多個 HTTP 服務（例如：Ollama 在 11434、Portainer 在 9443、Node.js LLMChat 在 3000、Python Web 在 6000），直接選擇 **Option 2 (Auto-Setup Nginx SSL Proxy)**：
- 程式會掃描目前本機監聽的 TCP 連接埠（如 `3000 6000 9443 11434`）並印出提示。
- 輸入您要以 SSL 封裝的連接埠，Nginx 就會自動監聽對應的 `安全埠 (原本連接埠 + 10000)`：
  - `https://mysrv:13000` ➔ 轉發至本地 `http://localhost:3000` (LLMChat)
  - `https://mysrv:16000` ➔ 轉發至本地 `http://localhost:6000` (Python)
  - `https://mysrv:19443` ➔ 轉發至本地 `http://localhost:9443` (Portainer)
  - `https://mysrv:21434` ➔ 轉發至本地 `http://localhost:11434` (Ollama)
- 您**完全不需修改任何 Docker 容器或程式碼設定**，也無須在容器內啟用 HTTPS（例如可以將 Portainer 容器的 HTTP 埠映射至宿主機的 9443 埠），全交給本機 Host 端 Nginx 在外層套上 SSL 憑證防護。

### 2. OpenMediaVault (OMV)
OMV 預設的 nginx 憑證路徑通常位於 `/etc/ssl/certs/`，您可以將其覆蓋（Option 1）：
- 憑證目標路徑: `/etc/ssl/certs/openmediavault-webgui.crt`
- 金鑰目標路徑: `/etc/ssl/private/openmediavault-webgui.key`
- 重啟指令: `systemctl restart nginx`

### 3. Unraid
Unraid 的 SSL 憑證位於 USB 隨身碟掛載路徑：
- 憑證目標路徑: `/boot/config/ssl/certs/cert.pem`
- 金鑰目標路徑: `/boot/config/ssl/certs/key.pem`
- 重啟指令: `/etc/rc.d/rc.nginx reload`

### 4. VMware ESXi
ESXi 的 Web 控制台憑證存放於主機的固定路徑中，覆蓋即可（Option 1）：
- 憑證目標路徑: `/etc/vmware/ssl/rui.crt`
- 金鑰目標路徑: `/etc/vmware/ssl/rui.key`
- 重啟指令: `/etc/init.d/hostd restart && /etc/init.d/vpxa restart`

### 5. Nginx 手動反向代理 (如各類 LLM 伺服器 / Open WebUI)
您可以透過 Nginx 反向代理，為 `http://localhost:3000` (Open WebUI) 加上 HTTPS。
在 Nginx 設定檔中：
```nginx
server {
    listen 443 ssl;
    server_name openwebui.local;
    ssl_certificate /etc/nginx/ssl/anycert.crt;
    ssl_certificate_key /etc/nginx/ssl/anycert.key;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```
執行 `anycert.sh` 時輸入：
- 憑證目標路徑: `/etc/nginx/ssl/anycert.crt`
- 金鑰目標路徑: `/etc/nginx/ssl/anycert.key`
- 重啟指令: `nginx -s reload`

### 6. WSL (Windows Subsystem for Linux) 部署指引
如果您的服務（如 Nginx, Docker 容器等）架設在 WSL 2 中，因為 WSL 2 是 Linux 系統，您應該**直接在 WSL 終端機內執行 Linux 伺服器指令**，而不是在 Windows 宿主機執行 `.bat`：
1. 開啟您的 WSL 終端機 (如 Ubuntu/Debian)，直接執行：
   ```bash
   sudo bash anycert.sh
   ```
2. 當 `anycert.sh` 偵測網路資訊並提示確認時：
   - **如果僅在 Windows 本機瀏覽器存取 WSL 服務**：直接沿用偵測到的 WSL 內部虛擬 IP 即可，並可直接透過 `localhost` 或 FQDN 存取。
   - **如果需要開放區網內其他裝置連線至 WSL 服務**：請手動將 IP 修改輸入為 **Windows 宿主機的實體區網 IP**。這樣簽發出的憑證才會包含該實體 IP。隨後只需在 Windows 宿主機使用 `netsh` 設定埠號轉發（Port Forwarding）將流量轉入 WSL 即可。

> [!NOTE]
> **關於 Windows 的實體網卡 IP 偵測**
> 在 Windows 伺服器端執行 `anycert.bat` 時，系統已內建智慧過濾。會自動排除 Hyper-V 虛擬網卡 (`vEthernet`)、WSL 虛擬交換機、Tailscale 以及 VMware/VirtualBox 等虛擬網路介面，精準自動取得本機實體的實體 LAN IP。

---

## 解除安裝

### 伺服器端
```bash
sudo bash anycert.sh -u
# 或 Windows
anycert.bat -u
```
會將所有備份還原，並清理產生的憑證。

### 用戶端
```bash
sudo bash anycert-linux.sh -u
# 或 macOS
sudo bash anycert-macos.sh -u
# 或 Windows
anycert-windows.bat -u
```
會提供已註冊網站列表，允許您單個或全部刪除 hosts 項目與匯入的 Root CA 信任。
