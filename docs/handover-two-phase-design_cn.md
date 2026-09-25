# 两阶段设备交接：预检、显式提交与保源回滚（设计方案 v1.0）

> 版本：v1.0（设计稿，尚未实现）
> 日期：2026-09-20
> 关联：`docs/demo-usb-storage-live-migration-plan_cn.md`、`docs/DEVLOG_cn.md`、
> `paper/main.tex` §VII（Failure and rollback）
> 结论先行：**机制放在 usbvfiod 服务端，策略由控制通道决定，VMM 源码不改**。

---

## 0. 英文摘要 / Summary

The current hand-over is commit-on-register: whichever vfio-user connection last
registers its interrupt line becomes the owner, so the destination takes the
device by the act of registering, with no check that it is able to serve it and
no way back if the migration then fails. This document specifies a two-phase
hand-over: a joining connection first becomes a **candidate** whose line is
staged but not installed, while the incumbent keeps serving; a **preflight**
checks that the candidate can actually take over; only an explicit
**commit** on the existing control socket flips ownership atomically; and the
previous owner may **reclaim** within a lease if the migration is cancelled.
The mechanism lives in usbvfiod, the policy is decided by whoever drives the
control socket, and no VMM source change is required.

---

## 1. 反馈与现状定位

领导反馈（转述）：

1. 中心思想可以借鉴，但**具体实现不是想要的**；
2. 现在的流程是**先断开旧的、再连新的**；
3. 需要考虑**迁移不成功**的情况：**先判断新的 VM 能不能成功**，
   缺东西或有问题时**应保持旧环境继续运行**；
4. 现在的实现**有点粗暴**。

这四点全部对应到同一处设计缺陷。逐条对照代码：

| 反馈 | 当前实现 | 位置 |
|---|---|---|
| "先断开旧的再连新的" | 归属定义为"**最后注册中断线者**"；第二个连接一旦 `SetIrqs`（带 fd）成功，归属立即改判 | `src/shared_backend.rs` 中 `irq_owner` 的注释、`owns_device()`、`set_irqs()` 里 `irq_owner.store(self.id)` |
| "没有先判断新的能不能成功" | **没有任何预检**：DMA 区间是否映射完整、region 是否读完、client 能力是否兼容、设备是否还在，一概不检查 | `set_irqs()` 只校验 index/count，不校验接管条件 |
| "不成功时要保持旧环境运行" | 源端在归属被抢走的那一刻就失去了中断线；它随后发来的 teardown 被当作"陈旧"忽略，但**线本身不会回来** | `set_irqs()` 的 `fds.is_empty() && !owns_device()` 分支只"忽略拆除"，没有"归还" |
| "粗暴" | 归属切换是数据面命令的副作用，**与迁移事务没有对应关系**；没有提交点、没有超时、没有租约 | 全文件；论文 §Failure and rollback 已承认：`timeout_strategy=cancel` 实测未能让源端恢复 |

**一句话诊断**：现在把"接管"实现成了 `commit-on-register`——
新连接**注册即拥有**，而不是**先证明自己能服务、再显式接管**；
因此不存在"迁移失败时源端继续运行"这条路径。

---

## 2. 目标与非目标

### 2.1 目标

- **G1 预检**：候选连接必须通过一组可验证的接管条件，才允许成为归属者。
- **G2 显式提交**：预检通过后，由控制通道发出 `commit` 才发生归属切换；
  在此之前**源端始终是归属者**，中断线始终有效。
- **G3 保源回滚**：预检失败/超时 → 源端完全无感；
  提交后迁移被取消 → 上一任 owner 可在**租约内**申请 `reclaim` 并恢复服务。
- **G4 原子性**：归属判定、中断线安装、DMA 归属、epoch 递增在同一临界区内完成。
- **G5 可诊断**：每一次拒绝都要给出机器可读的原因码，而不是静默忽略。
- **G6 不改 VMM 源码**：机制在服务端，策略由控制通道决定。

### 2.2 非目标

- 不实现**设备状态迁移**（协议 0.1.5 不携带该类状态）——跨主机仍不在范围内。
- 不做**显式 quiesce**（本次允许在途传输由 kick + 设备重试恢复）。
- 不引入需要修改 CH 的新 vfio-user 命令；预检只用现有数据面命令 + 我们自己的控制通道。
- 不改变默认单客户端行为（`--max-clients 1` 时行为与今天一致）。

---

## 3. 术语与不变量

- **owner**：当前被授权接收中断、并有权执行破坏性拆除（`SetIrqs` 空 fd、`DmaUnmap`）的连接。
- **candidate**：已连接、正在接受预检、**尚未**获得归属的连接。
- **epoch**：每次归属变更递增的 64 位序号。所有破坏性操作必须携带"操作者观察到的最新 epoch"
  （由服务端在控制通道与数据面响应中下发）。
- **lease**：owner 的有效期；到期未续则归属可回到上一任存活连接。

**不变量**

- **I1**：任意时刻至多一个 owner。
- **I2**：candidate 的存在**不影响** owner 的服务：owner 的中断线不被替换，owner 的 teardown 仍被接受。
- **I3**：归属切换只发生在 `commit`，且在一次 `control` 临界区内完成。
- **I4**：epoch 只增不减；携带旧 epoch 的破坏性操作一律拒绝并诊断。
- **I5**：candidate 失败时，其 `DmaMap` 等残留随连接关闭回收，**不触碰** owner 的状态。

---

## 4. 设计

### 4.1 状态机

```
                 第一个连接注册线
   ┌──────────┐ ─────────────────► ┌──────────────────────┐
   │ NoOwner  │                    │ Serving{owner, epoch}│
   └──────────┘                    └──────────────────────┘
                                        │            ▲
                    第二连接注册线       │            │ abort / 预检失败 / 超时
                                        ▼            │
                            ┌───────────────────────────────┐
                            │ Candidate{prev, cand,         │
                            │           staged_line,        │
                            │           deadline}           │
                            └───────────────────────────────┘
                                        │
                       预检通过 + 控制通道 commit
                                        ▼
                            ┌───────────────────────────────┐
                            │ Serving{owner=cand, epoch+1}  │
                            │ (prev 自此为"上一任")          │
                            └───────────────────────────────┘
                                        │
                     prev 在租约内 reclaim（epoch-1 有效）
                                        ▼
                            ┌───────────────────────────────┐
                            │ Serving{owner=prev, epoch+2}  │
                            └───────────────────────────────┘
```

关键点：**候选期间 `prev` 仍是 owner**。这是与今天最大的区别——
今天 `cand` 一注册就变成 owner，`prev` 立即失效。

### 4.2 预检清单

分三档，便于按场景配置（默认值见括号）：

**A. 硬条件（缺一即拒绝，`EPREFLIGHT_*`）**

| 编号 | 检查 | 依据 |
|---|---|---|
| A1 | 握手完成（`Version`/`DeviceGetInfo`/`DeviceGetRegionInfo`/`GetIrqInfo`） | 服务端已记录，见 `ServerBackend` 调用序列 |
| A2 | 能力兼容：region 布局、MSI-X index、单中断限制、`max_data_xfer_size` | 与现有 `set_irqs` 校验合并 |
| A3 | **设备所需的 DMA 区间已全部映射**（用动态 bus 的**实际覆盖**判断，而不是"发过 DmaMap"） | 需新增 `dynamic_bus::covers(addr, size) -> bool`（当前只有 `add`/`remove_range`，**没有查询 API**）；`src/xhci_backend.rs::dma_map` |
| A4 | 提供的 **eventfd 可用**（`fcntl(F_GETFL)` 等有效性探测；**不写入**，避免向目标注入伪中断） | `InterruptEventFd` |
| A5 | **设备仍在且健康**（未被拔出、attach 未被取消） | `CompleteRealDevice::detach_token()`（已存在，`CancellationToken`）：`is_cancelled()` 即为"设备已不可用" |
| A6 | 控制通道的 **`ready`**：驱动方确认目标 VM 已就绪（含"guest 已识别并打算使用该设备"这类业务判断） | 控制通道 |

**B. 可配置条件（默认开启，可用策略关闭）**

| 编号 | 检查 | 说明 |
|---|---|---|
| B1 | 候选连接的 **region 读取完整性**：`DeviceGetRegionInfo` 声明的 region 是否都被读过/映射过 | 防止"只握手不干活"的客户端 |
| B2 | 候选的 **DMA 区间与源端一致**（同一 guest 内存布局） | 同主机 + `memory_mode=memfds` 场景下的强校验 |
| B3 | 候选的 **中断 index/flags 与源端一致** | 防止能力错配 |

**C. 观测项（不参与判定，只记录）**

- 候选连接建立时刻、预检各步耗时、eventfd 类型、region 读次数、DMA 映射区间列表。

失败时返回原因码（`EPREFLIGHT_A3_DMA_INCOMPLETE` 等），
并在 usbvfiod 日志中打印一行结构化记录，供 harness 断言。

### 4.3 控制通道协议

复用现有的 `src/hotplug_protocol`（已有 `Attach`/`Detach`/`List` 与 `remote` 工具），新增：

| 命令 | 语义 | 成功响应 |
|---|---|---|
| `HandoverStatus` | 列出所有连接、owner/epoch、候选状态与预检结果 | `{connections[], owner, epoch, candidate?, preflight{}}` |
| `HandoverReady { conn }` | 驱动方声明"目标已就绪"，作为 A6 | `{ok, preflight}` |
| `HandoverCommit { conn, epoch }` | **显式提交**：校验 epoch 与预检全绿后切换 | `{ok, epoch+1}` |
| `HandoverAbort { conn, reason }` | 主动放弃候选（驱动方发现目标有问题） | `{ok}` |
| `HandoverReclaim { conn, epoch }` | 上一任在租约内申请回滚 | `{ok, epoch+1}` |

错误：`{error: code, detail}`。命令幂等；重复 `commit` 返回当前 epoch 而不重复切换。

### 4.4 提交（原子性）

在单个 `control` 临界区内完成，顺序固定：

1. 校验 `conn == candidate`、`epoch == 当前 epoch`、预检**全绿**且未超时；
2. `epoch += 1`；
3. 把 `staged_line` 交给 interrupter worker 安装，并**在 worker 内补发一次中断**（沿用现有 kick，见 `src/device/xhci/interrupter.rs`）；
4. `owner = candidate`，`prev = 旧 owner`，记录 `handover_committed_at`；
5. 释放临界区后才回复 `commit`（保证"回复即生效"）。

任何一步失败 → 保持原 owner，`epoch` 不变（避免"半个提交"）。

### 4.5 回滚与 reclaim

- **提交前失败**（预检不过/超时/`HandoverAbort`）：丢弃候选的 staged line，
  `owner` 与 epoch 不变，**源端完全无感**；候选的 DMA 映射随其连接关闭回收。
  这是绝大多数迁移失败的情形，**不需要 reclaim**。
- **提交后取消**：才需要 reclaim，见 4.5.1。
- **租约**：`prev` 的 reclaim 窗口 = `lease_ms`（默认 5000 ms，可配）。
  超时后拒绝并返回 `ERECLAIM_LEASE_EXPIRED`，同时在日志中给出"设备当前归属"。

### 4.5.1 reclaim 由谁触发、如何证明身份

**结论：由驱动控制通道的一方（harness / supervisor）显式发出；源端 VMM 不会也无法发出。**

已核对 CH 源码得出的两个事实：

1. 往 usbvfiod 发 `SetIrqs` 的位置是 `pci/src/vfio_user.rs:330` 的 `enable_irq`，
   **只在设备激活时调用**；
2. 迁移失败时 CH 调用 `vmm/src/lib.rs:2143` 的 `try_resume_vm_after_failed_migration`，
   它**只 `vm.resume()` 恢复 vCPU、停 dirty log**，**不会重新 `enable_irq`**。

因此源端在"提交后被取消"时不会重新注册中断线，"靠源端重新注册来自动回滚"这条路**今天不存在**
（可作为将来 CH 版本或 helper 的补充信号，见下文的次要触发）。

#### 主触发：控制通道 `HandoverReclaim`

驱动方的调用序列：

```text
1. HandoverStatus                      -> { owner: dst_id, prev: src_id, epoch: N, connections[] }
2. （迁移失败/取消：send-migration 返回错误，或目标 VM 已死）
3. HandoverReclaim { conn: src_id, epoch: N }
   -> { ok: true, epoch: N+1 }          # 服务端完成：owner=src、装线、kick 一次
```

服务端在接受 `reclaim` 前逐项校验（全部满足才切换）：

| 校验 | 否定的结果 |
|---|---|
| `conn` == 记录中的 `prev` | `ERECLAIM_NOT_PREVIOUS_OWNER` |
| `prev` 的连接**仍然打开**（socket 存活） | `ERECLAIM_PREV_GONE`（源端已退出，无处可回） |
| `epoch` == 当前 epoch（即 commit 时下发的那一个） | `ERECLAIM_EPOCH_MISMATCH`（拒绝陈旧回滚） |
| `now - committed_at <= lease_ms` | `ERECLAIM_LEASE_EXPIRED` |
| 控制通道对端身份可信（见下） | `ERECLAIM_UNTRUSTED_PEER` |

#### 身份与信任边界

- usbvfiod 为每个被接受的连接分配 `id`（现有 `next_id`），并在 `HandoverStatus` 中同时返回
  `id`、角色（owner/prev/candidate）、**对端 pid**（`SO_PEERCRED`）与连接年龄，
  驱动方据此把"源端/目标端"映射到具体 `id`；
- 控制命令只从本地 unix socket 接受，权限由文件系统控制；
  可选要求 `conn` 与命令发起者的 `SO_PEERCRED` 存在允许关系（例如同一 pid 或同一 cgroup），
  避免本机其它进程劫持归属；
- 这与论文已声明的信任模型一致：**vfio-user socket 与控制 socket 都必须视为可信**，
  不是防御恶意本地客户端的机制。

#### 自动兜底：owner 丢失时归还给上一任（建议默认开启）

最需要"无人值守也能恢复"的情形是**目标端崩溃**。此时不需要驱动方参与：

> 若已提交的 `owner` 连接断开，而 `prev` 仍然连接、且仍在租约内 →
> 服务端自动 `owner = prev`、装线、kick 一次，并记录
> `auto-reclaimed because the committed owner disconnected`。

这条规则在**成功迁移**中不会误触发：成功时断开的是源端（`prev`），不是 owner。

#### 次要触发（为将来保留）

接受来自 `prev` 的**一次新的非空 `SetIrqs`**（在租约内、`prev` 身份成立）作为 reclaim 请求。
今天 CH 不会发（见上面的源码事实），但若将来 CH 在失败恢复路径中重新 `enable_irq`，
或我们提供一个调用 `enable_irq` 的 helper，这条路径即自动生效，且与主触发不冲突（幂等）。

#### 两种时序对照

```text
A. 提交前失败（常见）                        B. 提交后取消（需要 reclaim）
   src=owner, dst=Candidate                     src=prev, dst=owner(epoch=N)
   dst 预检失败/超时/Abort                      迁移取消 / dst 崩溃
   -> 丢弃 staged line                          -> HandoverReclaim{src,N}  (驱动方)
   -> src 全程未受影响，**不需要 reclaim**         或 owner 连接断开 -> 自动兜底
                                                -> src=owner(epoch=N+1)，装线 + kick
```

### 4.5.2 迁移结果的检测：直接用 CH 自己的事件（不改 CH）

**结论：能检测，而且 CH 已经主动告诉我们了。** 不需要我们猜、也不需要"源端重新注册"这种间接信号。

CH 有两条现成的输出通道：

1. **专用事件通道**：`--event-monitor path=<path>`（或 `fd=<fd>`），事件以 **JSON** 写出
   （`event_monitor/src/lib.rs::event_log`；`timestamp/source/event/properties`）；
2. **普通日志**：同一个函数同时 `info!("Event: source = {source} event = {event} ...")`，
   因此即使不加参数，现有 `src.log`/`dst.log` 里也有这些行。

与迁移结果相关的**全部**事件与触发点（已核对源码）：

下表**已按 E1 实测校正**（E1 见 `DEVLOG_cn.md` D24，原始日志 `/root/usb-e1/{s1,s2}`；
带 ★ 的是 E1 实测新增/修正的项）：

| 事件 | 来源 | 触发点 | 含义 | 控制器的动作 |
|---|---|---|---|---|
| `migration-starting` ★ | source | 实测 | 源端开始迁移 | 标记"迁移中" |
| `migration-started` | source | `vmm/src/lib.rs:1698` | 迁移已启动 | 标记"迁移中" |
| `pausing` / `paused` | source | `vmm/src/vm.rs:3275/3301` | **源端暂停（切换点）** | 候选预检的最后窗口；此后才允许 commit |
| `snapshotting` / `snapshotted` ★ | source | 实测 | 设备/快照阶段 | 观测 |
| **`migration-failed`** ★ | source | 实测（`vmm/src/lib.rs:2185` 分支） | **迁移失败/取消（最直接判据）** | 已 commit → **reclaim**；未 commit → abort |
| `migration-finished` ★ | source | 实测（对应 `Migration completed`，`:1895`） | 源端侧成功 | 无需回滚 |
| `resuming` / `resumed` | source **与** dest ★ | `vmm/src/vm.rs:3306/3329`（源端由 `try_resume_vm_after_failed_migration` → `vm.resume()` 触发，`lib.rs:2143`） | 该实例的 vCPU 被恢复；**必须按实例区分** | 源端出现 `resumed` ⇒ 失败 → reclaim/abort |
| `migration-receive-starting` ★ | dest | 实测 | 目标端开始接收 | 预检须在此前变绿 |
| `migration-receive-started` | dest | `vmm/src/lib.rs:1179` | 目标端接管开始 | `ready`+`commit` |
| `migration-receive-finished` | dest | `vmm/src/lib.rs:3319` | **目标端接管成功** | 成功，无需回滚 |
| `migration-receive-failed` | dest | `vmm/src/lib.rs:3322` | **目标端失败** | 未 commit → abort；已 commit → reclaim |
| `restoring`/`restored`、`activated` ★ | dest | 实测 | 目标端设备恢复/激活 | 观测（候选注册就在这附近） |
| `shutdown` | source | `vmm/src/lib.rs:2696` | 源端退出（成功迁移的正常路径） | 无需 reclaim |

> **判据（按 E1 修正）**：主判据用**源端 `migration-failed`**（最直接）；
> 辅以"源端 `paused` 之后出现 `resumed`"以及目标端 `migration-receive-failed`。
> 成功判据用目标端 `migration-receive-finished`（或源端 `migration-finished`）。
> `resuming/resumed` 两端都会发，所以必须订阅**两个实例**并分别归属事件来源。

配套的日志行（可作为 JSON 通道不可用时的兜底）：
成功 `Migration completed after ...`（`:1895`）；失败 `Migration failed: ...`（`:2185`）；
接收侧失败 `Migration aborted as migration command ... failed`（`:1165`）。

#### 事件驱动的控制器（取代"从 send-migration 返回值猜"）

```text
watcher: 订阅 src 与 dst 两个 CH 的事件通道
  on dst migration-receive-started:
       若预检全绿 -> HandoverReady + HandoverCommit      # 在目标 guest 恢复前完成装线
  on dst migration-receive-failed:
       若已 commit -> HandoverReclaim{src}               # 目标端挂了
       否则        -> HandoverAbort{dst}                 # 尚未切换，源端无感
  on src resuming/resumed:                                # CH 自己恢复源端 = 取消/失败
       若已 commit -> HandoverReclaim{src}
  on dst migration-receive-finished: 什么都不做（成功）
```

这样"失败/取消"的判定权完全交给 CH 自己，而不是由 harness 根据
`send-migration` 的返回码推断（后者拿不到"取消"这类语义）。

**顺序保证**：commit 发生在 `migration-receive-started` 之后、源端 `resumed` 之前；
因此若随后出现 `migration-receive-failed` 或源端 `resumed`，reclaim 一定能命中租约窗口。

**一个边界情形**：`preserve_source=true` 的成功迁移不会发 `resumed`（源端只是停住），
所以 `resumed` 不会误判为失败；反之，成功路径上源端会 `shutdown`，其连接消失，
即使有人误发 reclaim 也会被 `ERECLAIM_PREV_GONE` 拒绝。

### 4.6 超时与租约

| 参数 | 默认 | 作用 |
|---|---|---|
| `--handover-preflight-timeout-ms` | 2000 | 候选进入 Candidate 后，预检必须在此时限内全绿，否则自动 abort |
| `--handover-lease-ms` | 5000 | 提交后上一任可 reclaim 的窗口 |
| `--handover-require-ready` | on | 是否把 A6（控制通道 ready）作为硬条件 |

超时处理在服务端定时器里执行，不依赖客户端行为——这是"新 VM 卡死不会带走设备"的关键。

### 4.7 并发与锁

- 现有 `control: Mutex<()>` 继续作为唯一的归属临界区；`irq_owner` 从
  `AtomicU64` 升级为临界区内的 `Ownership` 结构（`owner/prev/epoch/candidate/deadline`）。
- 数据面命令仍按命令加锁（`backend` 锁），**不与** `control` 锁嵌套顺序颠倒：
  统一 `control` → `backend`，与今天的 `set_irqs`/`dma_unmap` 一致。
- 候选的 `DmaMap` 不被特殊对待（它本来就是幂等共享后端），
  但**候选的 `DmaUnmap` 永远不生效**（非 owner）。

---

## 5. 改动点（文件级）

| 文件 | 改动 |
|---|---|
| `src/shared_backend.rs` | `Ownership` 状态机；`set_irqs` 从"注册即归属"改为"注册即候选"；`owns_device()` 增加 epoch 校验；新增预检入口与 abort/commit/reclaim 内部 API |
| `src/hotplug_protocol/`（+`src/bin/remote`） | 新增 5 条控制命令与响应；`remote` 工具增加子命令 |
| `src/hotplug_server.rs` | 把新命令接到 `SharedBackendState` 的交接 API |
| `src/xhci_backend.rs` | 新增 `dma_regions_cover(...)`（供 A3）与 `device_is_healthy()`（查 `detach_token()`，供 A5）；`dma_map` 不变 |
| `src/dynamic_bus.rs` | 新增只读的区间覆盖查询 `covers(addr, size) -> bool`（A3 依赖） |
| `src/device/xhci/interrupter.rs` | 不变（kick 仍由 worker 在换线后执行） |
| `src/cli.rs` / `src/main.rs` | 三个新参数；默认值保证单客户端行为不变 |
| `guest/` | 新增交接驱动：harness 在"目标 guest 就绪"后发 `HandoverReady`/`HandoverCommit`；故障注入臂 |
| `docs/`、`paper/` | 更新 §Failure and rollback（从"未实现"改为"已实现并实测"），并如实记录对论文声明的影响 |

---

## 6. 兼容性

- `--max-clients 1`：不产生候选，行为与今天逐字节一致；
- 未配置控制通道：`--handover-require-ready` 自动退化为 off（或直接拒绝多客户端），
  并通过日志明确提示"无控制通道，交接退化为预检通过后由驱动方 commit"；
- 旧的控制客户端（只发 Attach/Detach/List）不受影响，新命令是增量。

---

## 7. 验证矩阵

| # | 场景 | 注入方式 | 期望 |
|---|---|---|---|
| T1 | 正常迁移 | 现有 harness + `ready`/`commit` | 与今天等价：20/20、md5 一致、零重枚举 |
| T2 | 候选缺 DMA 映射 | 候选只读 region 不 `DmaMap` | 预检 A3 拒绝；**源端复制不中断**；迁移失败可重试 |
| T3 | 候选 eventfd 无效 | 传入坏 fd | A4 拒绝；源端无感 |
| T4 | 设备已被拔出 | 候选期间 detach 设备 | A5 拒绝；源端收到明确错误而非静默卡死 |
| T5 | 驱动方声明目标有问题 | 只 `HandoverAbort` | 不切换；源端继续完成复制 |
| T6 | 预检超时 | 候选不发 `ready` 直到超时 | 服务端自动 abort；源端无感 |
| T7 | 提交后取消（显式） | commit 后立刻 `HandoverReclaim{src, N}` | 源端恢复服务，复制继续 |
| T7b | 提交后目标端崩溃（自动兜底） | commit 后 kill 目标 CH | owner 连接断开 → 自动归还 `prev`；源端恢复 |
| T7c | 非上一任发 reclaim | 用第三个连接/错误 pid 发 reclaim | `ERECLAIM_NOT_PREVIOUS_OWNER` / `ERECLAIM_UNTRUSTED_PEER`，归属不变 |
| T7d | 陈旧 epoch | 用 `N-1` 发 reclaim | `ERECLAIM_EPOCH_MISMATCH`，归属不变 |
| T12 | 事件驱动检测（取消） | 迁移中途杀目标端 / 触发源端 `resumed` | 控制器据 `migration-receive-failed` 或 `resumed` 自动 reclaim；源端复制继续 |
| T13 | 事件驱动检测（成功） | 正常迁移 | `migration-receive-finished` → 不回滚；与 T1 等价 |
| T8 | 租约过期后 reclaim | 超过 `lease_ms` | 拒绝并给 `ERECLAIM_LEASE_EXPIRED`；设备归属不变 |
| T9 | 陈旧 epoch 破坏性命令 | 带 `epoch-1` 发 `SetIrqs` 空 fd | 拒绝并诊断 |
| T10 | 单客户端回归 | `--max-clients 1` | 与基线逐字节一致 |
| T11 | owner 卡死 | 提交后 owner 不续租约 | 归属回到上一任存活连接（若启用租约归还） |

判定仍**全部取自 guest 自身日志**（沿用 `guest/verdict.py`），
并新增"交接诊断"字段：`preflight_result`、`commit_epoch`、`reclaim_used`。

---

## 8. 对论文声明的影响（必须如实处理）

论文目前把"失败与回滚"列为**未实现的限制**，并明确指出
"归属不提交到迁移事务、取消后源端无法恢复"。本方案落地后：

- §VII 的该段应从"未实现"改为"已实现（预检 + 显式提交 + 租约内 reclaim）"，并附实测；
- 需要**新增一节**描述两阶段交接的状态机与预检清单；
- 摘要/贡献里"无重枚举、零感知"的结论**不变**，但增加"失败保源"这一新的可验证性质；
- 必须重新跑 T1–T11 并保留原始日志（沿用 `artifacts/` 归档与 `collect-artifacts.sh`）。

---

## 9. 风险与未决问题

1. **A6 的判定边界**：`ready` 由驱动方给出，服务端无法验证其真实性。
   → 需要约定：驱动方必须是可信控制通道（unix socket 权限），并在文档中明确"ready 的语义"。
2. **提交与 VMM 时序**：显式 commit 发生在 CH 的设备 resume 之后、
   迁移最终提交之前还是之后，需要与 CH 的时序对齐；本方案把选择权交给驱动方，
   但要在文档里给出推荐的调用点（建议：目标 guest 恢复运行并确认设备可用之后）。
3. **回滚的传输语义**：reclaim 时，源端可能有在途传输已由设备完成但未送达源端，
   kick 能否覆盖需要实测（与现有 kick 同源风险）。
4. **租约自动归还**（T11）是否开启：涉及"如何判断 owner 仍存活"，
   默认不开启，作为可选项。
5. **多设备**：当前按设备/控制器单实例设计；多设备时需要 per-device 的 Ownership。

---

## 10. 里程碑（待批准后执行）

| 阶段 | 内容 | 产出 |
|---|---|---|
| M1 | 本文档评审与定稿 | 本文件 + 反馈修订 |
| M2 | 服务端状态机 + 预检 A1–A5 + 控制通道命令 | 单元测试（状态机、epoch、超时） |
| M3 | harness 驱动（ready/commit/abort/reclaim）+ T1/T5/T6/T7 | 端到端日志与判定 |
| M4 | 故障注入 T2/T3/T4/T8/T9/T10/T11 | 注入矩阵报告 |
| M5 | 论文与开发日志更新、原始日志归档 | 新 PDF + `artifacts/` 批次 |

> 说明：M2–M5 涉及本地代码与实验；任何对第三方 GitHub 仓库的写操作
> （PR/issue/comment/review，或会更新上游 PR 的 fork 推送）都会先按
> `DEVLOG_cn.md` D22 的纪律逐条请你批准。
