# 单活 rotate（feat/single-active-rotate）开发计划

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 在最新 `feat/multi-instance-lb` 上重做单活分支：任意时刻最多 1 个 HAProxy `ready`（primary）；其余健康实例为 `drain` 热备；Web API 手动切主；primary 巡检失败自动 failover；**不做 MAX_CONN 轮转**。

**Architecture:** 复用 lb 现有 runtime `drain/ready/maint`、busy 排空、`request_instance_recovery` 后台 worker。新增 primary 记账 + 选人策略 + 轻量 admin HTTP。选人**不是固定环**，而是「最近一次健康检测通过」的实例（启动初检或巡检均可，时间戳最新者优先）。

**Tech Stack:** Alpine/`#!/bin/sh`、HAProxy stats socket（`socat`）、文件状态机（`/var/run/microwarp`）、可选 admin HTTP（busybox/`socat` 或等价轻量 loop）。

**Base:** `feat/multi-instance-lb` @ `5831f43`（含 infinite drain / streaming 修复）。  
**Branch:** 本地已重建干净 `feat/single-active-rotate`（fork 远端旧 tip 待删除/覆盖推送时再处理）。

---

## 0. 已锁定意图（产品）

| 项 | 结论 |
|---|---|
| 模式 | **常驻单活**（本分支 multi 即一主多备） |
| 范围 | 仅 lb 系分支；**不同步 l7** |
| 触发 | **Web API 手动** + **primary 巡检失败自动 failover** |
| MAX_CONN | **本分支不因 MAX_CONN 轮转**（可留 env 兼容，强制不触发） |
| 升 ready | **立刻升**（旧主 drain 后马上 ready 新主；零空窗） |
| 选人 | **最近健康通过者**（见 §1），**不是固定环** |
| 旧主 | drain → 排空/超时 → 下线；**进入 recovery 后旧 WG 隧道不保留，至少 WG 重连**（禁止「只拉 SOCKS」捷径）；恢复后 **仍 standby=drain** |
| 无候选 | **拒绝 rotate**（当前 primary 继续 ready） |
| 实例数 | `WARP_INSTANCES` <2 / 非法 → **按 2** |
| Admin 监听 | **写死 `0.0.0.0:9180`**（不需要 `ADMIN_HTTP_ADDR/PORT` 配置；宿主机 `-p 9180:9180` 映射） |
| Admin 鉴权 | `ADMIN_HTTP_TOKEN` 环境变量；**空 = 不启服务** |
| API 返回 | 客户端**只关心是否成功切到新实例**；**不暴露旧主后续排空/重连状态** |
| 黄金规则 | 不杀已有客户端 TCP；HAProxy 用官方 `drain`/`ready`/`maint` |

### 0.1 相对原计划的修正（2026-08-10 用户补充，已并入）

1. **`request_instance_recovery` / recovery worker：旧 WG 隧道不保留**
   - 任意原因进入 recovery（健康失败 / force_rotate / 手动切主后的旧主）→ **禁止**「隧道仍健康 → 只重启 SOCKS」捷径。
   - 至少执行 **WG 重连**；仍失败再走重注册。
   - 实现：删除/绕过 `SKIP_HEALTHY_SHORTCUT` 的「健康则 mark_up 直接成功」分支；本分支 worker 一律先 drain 停 SOCKS，再 `try_instance_wg_reconnect_recovery`（或等价），不保留旧隧道。
2. **Admin HTTP 监听写死**
   - Bind：`0.0.0.0:9180` only。
   - **不要** `ADMIN_HTTP_ADDR` / `ADMIN_HTTP_PORT` 可配。
   - 仅 `ADMIN_HTTP_TOKEN`：空=不启；非空=启并鉴权。
   - 宿主机负责端口映射。

---

## 1. 选人规则（相对旧方案的变更）

**旧默认（已废弃）：** 固定环 `id → id+1 → …`。

**现行规则：**

```text
候选 = status=up 且 非当前 primary 且 非 recovering
排序键 = last_healthy_at（最近一次「健康检测通过」的 epoch 秒）
         来源：启动 ensure/初检通过，或巡检 run_instance_health_checks 通过
取 max(last_healthy_at) 的那一个
若并列：可用更小 inst id 作稳定 tie-break（实现时写死并测）
若无候选：拒绝 rotate
```

实现要点：

- 新增 per-inst 文件，例如 `/var/run/microwarp/instK.last_healthy`（epoch）。
- 在所有「判健康通过」路径戳时间：
  - `mark_instance_up` 成功路径
  - `probe_instance_and_schedule_recovery` 中 `up` 分支巡检通过时（即使不 mark_up 也要刷新时间戳）
  - 启动 `ensure_instance_ready` 通过时
- **不要**在 drain/maint/down 时保留「假装最新」；失败/下线可 clear 或保留旧戳但候选过滤掉 non-up。
- rotate **禁止**选当前 primary 自己。

---

## 2. API 契约（对客户端尽量薄）

监听：**写死 `0.0.0.0:9180`**（无 ADDR/PORT env）  
Token：`ADMIN_HTTP_TOKEN`（Header `Authorization: Bearer …` 或 `X-Admin-Token` / `?token=`；空 token 不监听）

| 方法 | 路径 | 成功 | 失败 |
|---|---|---|---|
| `POST` | `/rotate` | **能让客户端判断「已切到新实例」即可**（建议短文本或极简 JSON：`OK to=N` / `{"ok":true,"primary":N}`） | `ERR no_candidate` / `ERR in_progress` / `401` |
| `GET` | `/status` | 运维用：primary + 各 inst status/role + 可选 last_healthy | 401 |

**明确不做：**

- 不在 rotate 响应里返回旧主 drain/busy/重连进度。
- 不要求客户端轮询旧主状态。
- 旧主后续全在后台 worker，对 API 不可见。

**并发：** rotate 进行中再来 → **拒绝**（`in_progress`），不排队。

**同步边界：**  
`POST /rotate` 在「新 primary 已 promote + HAProxy ready 已生效」后即可返回成功；旧主 `request_instance_recovery` 已投递即可，**不必等**旧主排空结束。

---

## 3. 状态机 / HAProxy 映射

| 内部 | HAProxy admin state | 说明 |
|---|---|---|
| `up` + primary | `ready` | 唯一接新连接 |
| `up` + 非 primary | `drain` | 热备：WARP+SOCKS 仍跑 |
| `draining` | `drain` | 旧主/恢复中：停新连接，保旧 TCP |
| `down` | `maint` | 离线重启 |

**不变式：** `count(ready) ≤ 1`（有健康时尽量 =1；全挂可为 0）。

---

## 4. 关键改动点（相对 `5831f43` entrypoint.sh）

### 4.1 必改钩子

| 钩子 | 现状 (lb) | 单活改法 |
|---|---|---|
| `get_warp_instance_count` | 默认 1，下限 1 | 下限 **2**，非法/<2 → 2 |
| `mark_instance_up` | 直接 `ready` | 记 `up` + 戳 `last_healthy`；**仅当无 primary 或自己是 primary 才 ready**，否则 HAProxy **drain** |
| `_reload_haproxy_from_status_unlocked` 重打 state | `up→ready` | 改为 **up+primary→ready，其它 up→drain** |
| `probe_instance…` 已 `up` 通过 | 只打日志 | **刷新 last_healthy**；若 primary 巡检失败走 failover |
| `probe` 失败 | `request_instance_recovery` | 若是 primary → **先 promote 最近健康者（若有）再 recover 旧主**；无候选则 clear primary 后仍 recover |
| `instance_should_force_rotate_for_max_conn` 调用点 | probe 内可触发 | **本分支禁用**（函数恒 false 或调用删除） |
| `instance_recovery_worker` | 可选「仍健康只拉 SOCKS」捷径（`SKIP_HEALTHY_SHORTCUT=0`） | **本分支一律禁止 SOCKS-only**：进入 recovery 后旧 WG **不保留**，至少 `try_instance_wg_reconnect_recovery`，失败再重注册 |
| recovery 成功 `mark_instance_up` | 变 ready | 受单活规则约束 → 通常进 **standby drain** |
| bootstrap 结束 | 多 ready 池 | 第一个成功 up 抢 primary；后续 up 保持 drain |

### 4.2 新增模块（建议集中一段，便于审）

- primary 文件：`get/set/clear_primary_id`
- last_healthy：`record/get_last_healthy_at` / `find_latest_healthy_standby`
- rotate lock：`acquire/release` + `is_rotate_in_progress`
- `haproxy_reapply_instance_states`（按 primary 映射 ready/drain/maint）
- `promote_primary NEW`
- `request_primary_rotate`（API）
- `failover_primary_on_health_fail FAILED`
- admin HTTP loop：**固定 `TCP-LISTEN:9180,bind=0.0.0.0`** + token 校验 + `/status` `/rotate`
  - 仅 env：`ADMIN_HTTP_TOKEN`（空=不启）
  - **禁止** `ADMIN_HTTP_ADDR` / `ADMIN_HTTP_PORT`

### 4.3 文档 / 测试

- `README.md`：单活语义、选人规则、API、env（`ADMIN_HTTP_TOKEN`、固定 9180、`WARP_INSTANCES` 下限 2、MAX_CONN 本分支无效、recovery 强制 WG 重连）
- `tests/test_multi_instance_helpers.sh`：单活相关单测（见 §6）
- 可选：更新 skill `microwarp-multi-instance` 的 single-active 小节

---

## 5. 分任务实施顺序（实现时按序；本文件是计划，不是现在写代码）

### Task A — 分支与基线确认
- 已完成本地：从 `feat/multi-instance-lb` 新开干净 `feat/single-active-rotate`。
- 待做：确认 fork 远端旧 `feat/single-active-rotate` 是否删除或 force-push 覆盖（**推送前再问你**）。

### Task B — last_healthy 记账 + 选人函数（TDD）
- Test：多 inst 不同 last_healthy → `find_latest_healthy_standby` 选最新且非 primary。
- Impl：文件读写 + 过滤 up/recovering。

### Task C — primary + HAProxy 映射（TDD）
- Test：`ensure_only_primary_ready` / reapply：仅 primary ready，其它 up → drain。
- Impl：改 `mark_instance_up`、reload 后 reapply。

### Task D — `request_primary_rotate`（TDD）
- 成功：promote 最新健康 standby，投递旧主 recovery（**force 全量 WG 重连，无 SOCKS-only**），返回「成功切到新实例」形状。
- 失败：无候选 / in_progress → ERR；**响应不含旧主后续状态**。

### Task E — health failover
- primary 巡检失败：有候选则 promote 最新健康者；无论是否有候选都 recover 失败 inst（同样强制 WG 重连）。
- 非 primary 失败：只 recover，不改 primary。

### Task F — 禁用 MAX_CONN 轮转
- probe 路径不再 `request_instance_recovery … max_conn`。
- 测试：即便 `MAX_CONN_DURATION` 很大也不触发。

### Task G — Admin HTTP
- token 空不监听；有 token 才 bind **`0.0.0.0:9180`（写死）**。
- `POST /rotate` / `GET /status`；401 无 token/错 token。
- 无 ADDR/PORT 配置项。

### Task H — WARP_INSTANCES 下限 2
- 改 `get_warp_instance_count` + 测。

### Task I — README + 手工验收清单
- 文档与「部署后怎么 curl 验证」一节（宿主机映射 9180）。

### Task J — 跑全量 `tests/test_multi_instance_helpers.sh`，修回归
- 提交本地 commit；**push/CI 等你点头**。

---

## 6. 测试清单（最低）

1. `get_warp_instance_count`：`1`/`0`/`abc` → `2`；`5` → `5`。  
2. last_healthy：巡检刷新后，选人指向最新 stamp 的 standby。  
3. 单活映射：3 个 up 时 HAProxy 目标态只有 1 ready。  
4. rotate 成功：primary 从 A→B，B 为最近健康；响应可判定成功且**无旧主进度字段**。  
5. rotate 拒绝：无其它 up / lock 占用。  
6. failover：primary 失败，自动切到最近健康 standby。  
7. MAX_CONN：本分支不触发 recovery。  
8. recovery worker：**无 SOCKS-only 捷径**；进入后至少走 WG 重连路径（可用 mock/桩测或静态断言无 `SKIP_HEALTHY_SHORTCUT` 成功早退）。  
9. admin：仅当 token 非空监听 `0.0.0.0:9180`；无 ADDR/PORT env 依赖。  
10. 既有 drain/infinite timeout / busy fail-closed 回归仍绿。

---

## 7. 风险与实现注意

- **reload/cold-start reapply**：任何 `up→ready` 的旧逻辑都会破坏单活；必须统一走 primary 映射。  
- **「已 up 巡检通过」** 必须更新 last_healthy，否则选人永远停在首次上线时间。  
- **standby 热备**：rotate 选中的目标必须已是 `up`（SOCKS 已在）；不要选 down 再等拉起（那会空窗）。  
- **API 成功定义**：以「新 primary 已 ready」为准，不是「旧主重连完成」。  
- **不要**把内部 status 名 `draining` 当成 HAProxy 官方状态；对外只有 ready/drain/maint。  
- **recovery 禁止保留旧 WG**：本分支 worker 不得在 stop SOCKS 后因 health 仍 OK 就 mark_up 退出；必须重连（或重注册）。  
- **admin bind 写死**：避免再引入 ADDR/PORT 分叉；宿主机映射即可。  
- 旧烂实现（33 行残片 / 环选）**整支丢弃**，不在屎上堆。

---

## 8. 验收标准（你可直接当 DoD）

- [ ] 任意时刻 ready ≤ 1  
- [ ] `POST /rotate` 成功 ⟺ 已切换到**另一**健康实例，且该实例是**当时 last_healthy 最新**的 standby  
- [ ] 客户端无需、也拿不到旧主后续状态  
- [ ] 无候选 / 进行中 → 明确失败，primary 不变  
- [ ] primary 挂 → 自动切（有候选时）  
- [ ] 无 MAX_CONN 自动轮转  
- [ ] recovery：**旧 WG 不保留**，至少重连（禁止只拉 SOCKS）  
- [ ] admin：**`0.0.0.0:9180` 写死**；仅 token 控制启停  
- [ ] 流式/长连接：drain 不杀已有 TCP；`INSTANCE_DRAIN_TIMEOUT` 空=无限等  
- [ ] helper 测试通过  

---

## 9. 执行方式（等你一句「开干」）

确认本计划后：按 Task B→J 实现；默认本地提交；**push fork / 开 PR 仅在你明确要求时**。

**当前分支状态：** 本地 `feat/single-active-rotate` 已基于 `5831f43` 干净重建；工作区含本 plan（未跟踪）。
