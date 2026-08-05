# MicroWARP 🚀

[![Docker Pulls](https://img.shields.io/badge/docker-ready-blue.svg)](https://github.com/ccbkkb/MicroWARP/packages)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[English](#english) |[中文说明](#chinese)

### 📊 Performance Comparison (性能碾压对比)

Here is a real-world performance test on a 1C1G (1 vCPU, 1GB RAM) VPS, comparing MicroWARP with the widely used `caomingjun/warp`.

以下是在 1C1G 廉价小鸡上的真实运行数据截图对比。你可以清楚地看到 MicroWARP 是如何榨干物理机极限的：

| Metric (性能指标) | `caomingjun/warp` (Official Daemon) | 🚀 `MicroWARP` (Our pure C + Kernel approach) | 碾压级提升 (Improvement) |
| :--- | :--- | :--- | :--- |
| **Image Size**<br>(Docker 镜像体积) | 201 MB | **9.08 MB** | 📉 **直降 95%** |
| **RAM Usage**<br>(日常内存占用) | ~150 MB | **800 KiB** (< 1MB) | 📉 **暴降 99.4%** |
| **CPU Overhead**<br>(高并发 CPU 损耗) | High (Userspace App) | **~0.25%** (Kernel Space) | ⚡ **近乎为零** |
| **Core Engine**<br>(底层核心引擎) | Cloudflare `warp-cli` (Rust/Heavy) | Linux `wg0` + Pure C `microsocks` | 🛠️ **极简硬核** |

> **🔥 Real `docker stats` output (真实的生产环境终端输出):**
> ```text
> CONTAINER ID   NAME       CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O
> 2fa58f84c517   warp       0.25%     800KiB / 967.4MiB     0.08%     48.8MB / 39.1MB   238kB / 36.9kB
> ```
> *Yes, you read that right. It processed ~90MB of traffic using only **800 KB** of RAM!*
> *(没看错，它在处理了近 90MB 网络吞吐的同时，仅仅占用了 **800 KB** 的内存！)*

---

<a name="english"></a>
## 🇬🇧 English

An ultra-lightweight, high-performance Cloudflare WARP SOCKS5 proxy in Docker. 
A perfect drop-in replacement for `caomingjun/warp`.

### 🌟 Why MicroWARP?

Many popular WARP Docker images (like `caomingjun/warp`) rely on the official Cloudflare `warp-cli` daemon. This results in heavy memory usage (often **150MB+**) and potential process deadlocks under high concurrency.

**MicroWARP** does things differently:
1. **Kernel-Level WireGuard**: It drops the bloated official client and uses Linux's native `wg0` interface. CPU usage is almost zero.
2. **MicroSOCKS**: It uses a pure C-based `microsocks` server instead of heavy Go/Rust proxies.
3. **Extreme Low RAM**: Runs smoothly on **< 5MB RAM** (often under 1MB). Perfect for 1C1G cheap VPS.
4. **Multi-Arch**: Native support for `amd64` and `arm64` (Oracle Cloud ARM ready).

### 📦 Quick Start

You can seamlessly replace your existing WARP proxy. Just map port `1080` and give it `NET_ADMIN` privileges. Create a `docker-compose.yml`:

```yaml
version: '3.8'

services:
  microwarp:
    image: ghcr.io/buddhism5080/microwarp-fork-1193760856:feat-multi-instance-lb
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
      # multi-instance (WARP_INSTANCES>1) also needs:
      # - SYS_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - warp-data:/etc/wireguard # Keep account data to avoid rate limits
    environment:
      - ROTATE_IP_ON_START=0 # Set to 1 to refresh the WARP exit IP on each container start
      # - WARP_INSTANCES=3 # >1 = multiple in-container WARP tunnels + single SOCKS LB

volumes:
  warp-data:
```

> **Fork image note:** this branch’s CI publishes to  
> `ghcr.io/buddhism5080/microwarp-fork-1193760856:<branch-tag>`  
> (branch slashes become hyphens, e.g. `feat/multi-instance-lb` → `feat-multi-instance-lb`).  
> Upstream mainline images remain under `ghcr.io/ccbkkb/microwarp`.

Run the container:
```bash
docker compose up -d
```

### 🔥 Advanced Features (Auth, Port, Bypass DPI)

MicroWARP supports powerful environment variables to customize your setup while keeping the RAM at 800KB:

```yaml
    environment:
      - BIND_ADDR=0.0.0.0     # Bind address (default: 0.0.0.0)
      - BIND_PORT=1080        # Custom SOCKS5 port (default: 1080)
      - SOCKS_USER=admin      # Enable authentication (leave empty for no auth)
      - SOCKS_PASS=123456     # Auth password
      - ENDPOINT_IP=162.159.193.10:2408 # Custom WARP Endpoint IP, or a comma/semicolon-separated candidate list
      - ROTATE_IP_ON_START=1 # Re-register a fresh WARP device on every container start to refresh the egress IP (default: 0)
      - WARP_STACK=ipv6-preferred # ipv6-preferred (default), dual, ipv4-only, or ipv6-only
      - WARP_API_URL=https://api1.example.com/register?format=wireguard,https://api2.example.com/register?format=wireguard # One or more compatible API endpoints; each request tries them in order
      - WARP_API_PROXY=http://127.0.0.1:8080 # Optional proxy used only for the API registration request
      - WG_RECONNECT_RETRIES=5 # Reconnect wg0 this many times before requesting a brand new config; minimum 0 disables this stage, large values are capped at 20
      - TEST_URLS=https://grok.com,https://example.com # Comma/semicolon-separated URLs; all must avoid 4xx/5xx before startup succeeds
      - TEST_URLS_CHECK_INTERVAL=900 # Background TEST_URLS inspection interval in seconds; default 900
      - WARP_INSTANCES=1 # Number of in-container WARP tunnels (default 1, max 100). >1 enables single-port HAProxy LB over healthy instances only
      - CONFIG_STALE_OFFLINE_SECONDS=7200 # If an instance stays offline this long, force re-register (default 7200=2h; 0=disable)
      - MAX_CONN_DURATION=0 # Max continuous healthy uptime (seconds) per instance; when exceeded AND currently idle (no active clients), force offline + reconnect (default 0=disable)
      # Optional egress-IP probe overrides (multi-source; first success wins per family; vendors interleaved):
      # - EGRESS_IP_V4_URLS=https://1.1.1.1/cdn-cgi/trace,https://api4.ipify.org,...,https://1.0.0.1/cdn-cgi/trace,...
      # - EGRESS_IP_V6_URLS=https://[2606:4700:4700::1111]/cdn-cgi/trace,https://api6.ipify.org,...,https://[2606:4700:4700::1001]/...
      # - EGRESS_IP_CURL_MAX_TIME=4 # per-source curl max-time seconds (default 4)
      # - EGRESS_IP_FAIL_THRESHOLD=4 # max links to try per family in one check; all miss => WARP down (0=never hard-fail on IP)
```

*(Note: If your VPS is in HK or US and cannot connect to WARP due to Cloudflare's `reserved` bytes verification, simply scan a clean CF endpoint IP and inject it via `ENDPOINT_IP`. MicroWARP will seamlessly route traffic through it!)*

*(If `ROTATE_IP_ON_START=1`, MicroWARP will overwrite the persisted `wg0.conf` on each container start by registering a fresh WARP device. Leave it off if you prefer a stable device identity and fewer rate-limit risks.)*

*(You can override `WARP_API_URL` when you want to query one or more compatible registration APIs. Separate multiple addresses with commas or semicolons, and each registration attempt will try them in order. Set `WARP_API_PROXY` if that API request must go through an HTTP/SOCKS proxy. When `WARP_API_PROXY` is **unset** and multi-instance has **more than one healthy** backend, registration automatically uses the local HAProxy SOCKS (`socks5h://127.0.0.1:$BIND_PORT`) so API traffic exits via a live WARP tunnel; with 0–1 healthy instances it still registers direct to avoid bootstrap deadlock. The request and returned WireGuard config format stay unchanged.)*

*(When health checks fail, MicroWARP now first disconnects and reconnects `wg0`, then reruns the checks. Only after `WG_RECONNECT_RETRIES` attempts still fail will it request a brand new config. The default is `5`, and `0` disables the reconnect phase.)*

*(Egress IP discovery is multi-source with same-vendor endpoints interleaved (e.g. `1.1.1.1` … later `1.0.0.1`). In **one** health check it tries up to `EGRESS_IP_FAIL_THRESHOLD` links per address family (default **4**), first success wins; if those links yield no IP, WARP is declared down. Set the threshold to `0` to disable IP-based hard-fail (then `TEST_URLS` alone decide).)*

*(Startup logs now print a short WARP identity summary, including a private-key fingerprint, interface addresses, and the selected peer endpoint. If you pass multiple endpoints in `ENDPOINT_IP`, separated by commas or semicolons, MicroWARP will randomly pick one on each start.)*

*(Set `WARP_INSTANCES=N` (N>1) to run **multiple WARP tunnels inside one container**. Only one SOCKS port is exposed (`BIND_ADDR`/`BIND_PORT`); HAProxy round-robins to healthy in-container backends and immediately removes unhealthy ones from the pool. Per-instance configs live under `/etc/wireguard/instances/<id>/wg0.conf`. Multi-instance needs extra privileges for network namespaces — add `SYS_ADMIN` (in addition to the usual `NET_ADMIN` / `SYS_MODULE`). Default remains `1` and keeps the original single-tunnel path.)*

*(Multi-instance runtime notes: HAProxy opens as soon as bootstrap begins (even with zero backends). Each instance is health-checked and joined to the pool **as soon as it comes up** — the container does **not** wait for all N tunnels before serving. Instances still start **serially with a 1s stagger**. Health probes are staggered by `TEST_URLS_CHECK_INTERVAL / WARP_INSTANCES`. A failed instance is removed from HAProxy immediately and revived by its own **background worker** (reconnect → re-register with backoff). If register/config fetch fails 3 times for an instance, it is **enqueued to a serial background config-retry queue** instead of exiting the container; one worker retries those registrations FIFO with backoff. Registration API calls remain serialized across workers/queue.)*

*(If an instance stays continuously offline for `CONFIG_STALE_OFFLINE_SECONDS` (default **7200** = 2 hours), MicroWARP treats its WARP config as stale: it skips further reconnect-only attempts and forces a new registration. The offline timer is persisted under the wireguard volume so container restarts do not reset it. Set `0` to disable.)*

*(Set `MAX_CONN_DURATION` (seconds, default **0** = disabled) to cap how long a healthy instance may stay continuously online. On each health probe, if uptime ≥ this value **and** the instance currently has **no active client connections** (idle), MicroWARP force-offs it and reconnects — multi-instance via the background recovery worker; single-instance via WG reconnect (then re-register if reconnect fails). Active traffic is never interrupted: busy instances are left alone until they become idle.)*

### 🚀 Need an HTTP Proxy?

MicroWARP strictly adheres to the Unix philosophy. We keep the memory usage at **800KB** by providing a pure L4 SOCKS5 engine. We will never bloat the image with heavy L7 HTTP parsers. 

If your app only supports HTTP proxies, you can elegantly chain it with tools like `gost`:
```bash
nohup gost -F=socks5://admin:123456@127.0.0.1:1080 -L=http://:8081 > /dev/null 2>&1 &
```
*⚠️ **Pro Tip**: Use `socks5://` instead of `socks5h://`. This forces the host to resolve DNS locally, completely avoiding `503 Service Unavailable` errors caused by WireGuard's UDP handshake delay!*

### 📝 Auto-Registration
Zero configuration required. On the first run, MicroWARP will automatically register a free WARP account and persist the configuration in the Docker volume.

---

<a name="chinese"></a>
## 🇨🇳 中文说明

一个超轻量、高性能的 Cloudflare WARP SOCKS5 Docker 代理。
完美平替 `caomingjun/warp` 的终极方案。

### 🌟 为什么选择 MicroWARP？

市面上流行的 WARP 镜像（例如 `caomingjun/warp`）绝大多数打包了 Cloudflare 官方的 `warp-cli` 守护进程。这会导致极高的内存占用（通常在 **150MB 以上**），并且在高并发下极易发生进程死锁和崩溃。

**MicroWARP** 采用了完全不同的极客底层架构：
1. **内核级 WireGuard**：彻底抛弃臃肿的官方客户端，直接调用 Linux 原生内核态的 `wg0` 网卡接管流量，CPU 损耗近乎为零。
2. **MicroSOCKS 引擎**：使用纯 C 语言编写的 `microsocks` 服务器替代繁重的 Go/Rust 代理引擎。
3. **极致极低内存**：高并发下内存占用依然 **< 5MB**（实测常驻 800KB 左右）。专为 1C1G 的廉价小内存 VPS 打造的拯救者。
4. **多架构支持**：原生支持 `amd64` 和 `arm64`（完美兼容甲骨文免费 ARM 机器）。

### 📦 快速开始

你可以零成本无缝替换掉现有的 WARP 代理。只需映射 `1080` 端口并赋予容器 `NET_ADMIN` 网络管理权限。新建一个 `docker-compose.yml`：

```yaml
version: '3.8'

services:
  microwarp:
    image: ghcr.io/buddhism5080/microwarp-fork-1193760856:feat-multi-instance-lb
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080" # 标准的无密码 SOCKS5 端口，仅监听本机
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
      # 多实例 (WARP_INSTANCES>1) 还需要:
      # - SYS_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - warp-data:/etc/wireguard # 持久化保存账号凭证，防止重启触发风控
    environment:
      - ROTATE_IP_ON_START=0 # 改成 1 则每次容器启动时都刷新一次 WARP 出口 IP
      # - WARP_INSTANCES=3 # >1 = 单容器多 WARP 隧道 + 单 SOCKS 健康负载均衡

volumes:
  warp-data:
```

> **Fork 镜像说明：** 当前分支的 CI 会推到  
> `ghcr.io/buddhism5080/microwarp-fork-1193760856:<分支标签>`  
> （分支名里的 `/` 会变成 `-`，例如 `feat/multi-instance-lb` → `feat-multi-instance-lb`）。  
> 上游正式镜像仍是 `ghcr.io/ccbkkb/microwarp`。

启动容器：
```bash
docker compose up -d
```

启动后，将你的应用（Telegram、v2ray、Xray、AIzaSy、Grok2API 等）的 SOCKS5 代理指向 `127.0.0.1:1080`，你的出站流量就已经被 Cloudflare 骨干网完美接管并洗白了！

### 🔥 进阶配置：自定义端口、密码认证与抗阻断

MicroWARP 支持极其强大的环境变量注入配置，并且开启这些功能后，内存依旧保持 **800KB** 的神话：

```yaml
    environment:
      - BIND_ADDR=0.0.0.0     # 监听地址 (默认 0.0.0.0，请不要修改这里，除非你知道自己在做什么)
      - BIND_PORT=1080        # 监听端口 (默认 1080)
      - SOCKS_USER=admin      # SOCKS5 认证用户名 (留空则为无密码模式)
      - SOCKS_PASS=123456     # SOCKS5 认证密码
      - ROTATE_IP_ON_START=1 # 每次容器启动时重新注册 WARP 设备并刷新出口 IP (默认: 0)
      - WARP_STACK=ipv6-preferred # ipv6-preferred（默认）、dual、ipv4-only 或 ipv6-only
      - WARP_API_URL=https://api1.example.com/register?format=wireguard,https://api2.example.com/register?format=wireguard # 可配置一个或多个兼容注册 API，逗号/分号分隔后会按顺序尝试
      - WARP_API_PROXY=http://127.0.0.1:8080 # 仅用于注册 API 请求的可选代理
      - WG_RECONNECT_RETRIES=5 # 健康检查失败后，先断开重连 wg0 的重试次数；最低为 0，设为 0 则直接跳过此阶段，过大值会被限制到 20
      - TEST_URLS=https://grok.com,https://example.com # 逗号/分号分隔的测试 URL；必须全部不返回 4xx/5xx 才算通过
      - TEST_URLS_CHECK_INTERVAL=900 # 后台 TEST_URLS 巡检间隔，单位秒；默认 900
      - WARP_INSTANCES=1 # 单容器内并行 WARP 隧道数量（默认 1，最大 100）。>1 时只暴露一个 SOCKS 端口，经 HAProxy 只负载到健康实例
      - CONFIG_STALE_OFFLINE_SECONDS=7200 # 连续离线超过该秒数则判定配置失效并强制重注册（默认 7200=2小时；0=关闭）
      - MAX_CONN_DURATION=0 # 每个实例最长连续健康在线秒数；超时且当前空闲（无活动客户端连接）则强制下线并重连（默认 0=关闭）
      # 可选：出口 IP 多源探测（每栈按顺序试、成功即停；同厂商错开）：
      # - EGRESS_IP_V4_URLS=https://1.1.1.1/cdn-cgi/trace,https://api4.ipify.org,...,https://1.0.0.1/cdn-cgi/trace,...
      # - EGRESS_IP_V6_URLS=https://[2606:4700:4700::1111]/cdn-cgi/trace,https://api6.ipify.org,...,https://[2606:4700:4700::1001]/...
      # - EGRESS_IP_CURL_MAX_TIME=4 # 单个探测源超时秒数（默认 4）
      # - EGRESS_IP_FAIL_THRESHOLD=4 # 单次检查每栈最多试几条链接，都失败则判 WARP 挂（默认 4；0=不因 IP 判死）

      # ⚠️ 针对香港/美西机房的防阻断绝杀：
      - ENDPOINT_IP=162.159.193.10:2408 # 注入你扫出的优选 IP，完美绕过 CF 的 reserved 字节阻断！
      - ENDPOINT_IP=162.159.193.10:2408,188.114.98.7:2408 # 也可以传多个候选，启动时随机选择一个
```

> 如果启用 `ROTATE_IP_ON_START=1`，MicroWARP 会在每次容器启动时重新注册一个新的 WARP 设备，并覆盖持久化卷里的 `wg0.conf`。如果你更在意设备身份稳定和降低限频/风控概率，就保持默认关闭。
>
> 如果你要切换到别的兼容注册 API，可以设置 `WARP_API_URL`；如果配置了多个地址（逗号或分号分隔），每次注册请求都会按顺序逐个尝试；如果只有这一步注册请求需要走代理，可以设置 `WARP_API_PROXY`。**未设置** `WARP_API_PROXY` 且多实例**健康后端 > 1** 时，注册会自动走本机 HAProxy SOCKS（`socks5h://127.0.0.1:$BIND_PORT`），让 API 经已存活的 WARP 出口出去；健康数 ≤1 时仍直连注册，避免首启死锁。两者都不会改变请求方式和返回的 WireGuard 配置格式。
>
> 出口 IP 探测为**多源、短超时、同厂商错开**（例如先 `1.1.1.1`，中间插其它厂商，再试 `1.0.0.1`）。**同一次**健康检查内，每个地址族最多试 `EGRESS_IP_FAIL_THRESHOLD` 条链接（默认 **4**），成功即停；若这几条都拿不到 IP，判定 WARP 连接失败。`EGRESS_IP_FAIL_THRESHOLD=0` 时不因 IP 判死，改由 `TEST_URLS` 决定。健康检查失败后仍按 `WG_RECONNECT_RETRIES` 先重连再重检，全部失败后才重新向 API 申请配置（默认 `5`，`0` 跳过重连，过大值封顶 `20`）。
>
> 现在启动日志还会打印一份简短的身份摘要，包括私钥指纹、接口地址和最终采用的 Peer Endpoint，方便你确认“设备身份是否真的变了”。如果 `ENDPOINT_IP` 传入多个候选（逗号或分号分隔），容器每次启动时会随机挑一个。
>
> 设置 `WARP_INSTANCES=N`（N>1）可在**同一个容器内**并行多条 WARP 隧道：对外仍只暴露一个 SOCKS 端口（`BIND_ADDR`/`BIND_PORT`），由 HAProxy 轮询健康后端，不健康实例会立刻从池中剔除。各实例配置保存在 `/etc/wireguard/instances/<id>/wg0.conf`。多实例依赖 network namespace，除常规 `NET_ADMIN` / `SYS_MODULE` 外建议再加 `SYS_ADMIN`。默认仍是 `1`，完全走原来的单隧道路径。
>
> 多实例运行细节：启动时 **HAProxy 会立刻监听**（即使暂时 0 后端）；**每个实例一旦启动完成就立刻测活并加入池**，不必等全部 N 条隧道都起来才开放服务。实例仍**串行启动并间隔 1 秒错峰**；健康巡检按 `TEST_URLS_CHECK_INTERVAL / WARP_INSTANCES` 错峰。失败实例会立刻踢出 HAProxy，并由各自的**后台 worker**独立复活（重连 → 重注册，带退避）。若某个实例**获取配置连续失败 3 次**，不会再拖垮整容器退出，而是进入**后台串行配置重试队列**（FIFO + 退避）继续注册。各 worker/队列对注册 API 的请求会串行化，降低打爆注册接口的风险。
>
> 若某个实例**连续离线**超过 `CONFIG_STALE_OFFLINE_SECONDS`（默认 **7200 秒 = 2 小时**），会判定现有 WARP 配置失效：跳过“只重连”阶段，直接强制重新注册新配置。离线计时落在 wireguard volume 里，容器重启不会清零。设为 `0` 可关闭该策略。
>
> 设置 `MAX_CONN_DURATION`（秒，默认 **0** = 关闭）可限制每个实例最长连续健康在线时长。健康巡检时若已在线 ≥ 该值，**且当前无活动客户端连接（空闲）**，则强制下线并重连：多实例走后台复活 worker；单实例先 WG 重连，失败再走完整修复/重注册。有活动流量时不会打断，等空闲后再轮换。

### 🚀 高级玩法：如何将其转换为 HTTP 代理？

MicroWARP 坚守 Unix 哲学（Do one thing and do it well）。为了保持 800KB 的极限内存，我们绝不会在底层内置臃肿的七层 HTTP 解析引擎。

如果你需要 HTTP 代理，可以使用 `gost` 极其优雅地串联转换（L4 转 L7）：
```bash
nohup gost -F=socks5://admin:123456@127.0.0.1:1080 -L=http://:8081 > /dev/null 2>&1 &
```
*⚠️ **避坑诊断指南**：请务必使用 `socks5://` 而不是 `socks5h://`。去掉 `h` 可以让 gost 在宿主机本地网络解析 DNS，完美避开 WARP UDP 隧道冷启动握手时容易触发的 DNS 解析死锁，彻底告别偶尔出现的 `503 Service Unavailable` 报错！稳如老狗！*

### 📝 全自动免配置
你不需要手动提取任何密钥。首次启动时，MicroWARP 会在后台全自动向 Cloudflare 申请注册免费 WARP 账户，提取节点信息，并永久保存在本地的数据卷中。

---

*特别鸣谢: __LinuxDo__ ❤️
