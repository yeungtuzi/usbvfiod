# 两阶段设备交接：预检、显式提交与保源回滚（设计方案 v1.0）

> 版本：v1.1（**已实现并实测**，2026-09-25；A1–A6/B3 的状态见 §4.2，实测结论见
> `DEVLOG_cn.md` D25–D27 与 `review_report_cn.md` 第十二部分）
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

**A. 硬条件（缺一即拒绝，`EPREFLIGHT_*`）——实现状态见最后一列（2026-09-25 更新）**

| 编号 | 检查 | 实现位置 | 状态与证据 |
|---|---|---|---|
| A1 | 握手完成（`Version`/`DeviceGetInfo`/`DeviceGetRegionInfo`/`GetIrqInfo`） | —— | **由构造保证**：vfio-user 协议里 `SetIrqs` 只能出现在握手之后，而候选正是由 `SetIrqs` 产生的；`vfio_user::Server` 自己处理握手命令，后端看不到也不需要伪造该检查。不假装有独立检查 |
| A2 | 能力兼容：MSI-X index、单中断限制（region 布局与 `max_data_xfer_size` 由握手固定） | `xhci_backend::validate_irq_request`，**暂存路径也会调用** | **已实现**：非 MSI-X index / `count>1` 直接拒绝（`xhci_backend.rs`） |
| A3 | **设备所需的 DMA 区间已全部映射**（比较 owner 与候选的**实际覆盖**） | `shared_backend::preflight_hard` + `ranges_cover` | **已实现**：`EPREFLIGHT_A3_DMA_INCOMPLETE`；测试 `a_destination_that_is_missing_memory_is_refused`。注意读**活状态**，因为目标端的 `DmaMap` 晚于它的 `SetIrqs`（实测 0.06–0.3 ms） |
| A4 | 提供的 **eventfd 可用**（不写入、不注入伪中断） | `shared_backend::is_eventfd`（读 `/proc/self/fdinfo` 要求 `eventfd-count`） | **已实现**：`EPREFLIGHT_A4_EVENTFD`；测试 `a_candidate_without_a_real_eventfd_is_refused`（`/dev/null`）。另修掉 `InterruptEventFd::interrupt` 的 `expect`（客户端 fd 不该打死 interrupter） |
| A5 | **设备仍在** | 控制面每个交接命令前用 `HotplugControl::list_devices()` 刷新清单 → `SharedBackendState::note_device_inventory` → 预检 | **已实现**：`EPREFLIGHT_A5_DEVICE_GONE`；测试 `a_handover_without_an_attached_device_is_refused`（注入空清单）。`--handover-require-device=false` 可关；无控制面时条件"未上报"而非误伤。设计原想用 `detach_token().is_cancelled()`，但设备清单只在 port 的异步通道里，同步访问器不存在，故改为控制面刷新 |
| A6 | 控制通道的 **`ready`**：驱动方确认目标 VM 已就绪 | `handover_ready` + `o.require_ready` | **已实现**：`EPREFLIGHT_NOT_READY`；注意兜底提升**不受** A6 约束（owner 已死时无人能声明 ready），只受 A3/A4/B3 约束 |

**B. 可配置条件（默认开启）**

| 编号 | 检查 | 状态 |
|---|---|---|
| B1 | 候选连接的 **region 读取完整性**（防止"只握手不干活"） | **未实现**：需要在 wrapper 里按连接累计 region 读计数；当前由 A3 的 DMA 覆盖间接拦住"什么都没做"的候选 |
| B2 | 候选的 **DMA 区间与源端一致** | **已由 A3 覆盖**（A3 就是"候选覆盖 owner 的区间"，比"区间集合相等"更弱也更有用：允许候选多映射） |
| B3 | 候选的 **中断 index/start/count 与源端一致** | **已实现**：`EPREFLIGHT_B3_IRQ_MISMATCH`；测试 `a_candidate_with_a_different_interrupt_vector_is_refused` |

**C. 观测项（不参与判定，只记录）**

- 候选连接建立时刻、预检各步耗时、eventfd 类型、region 读次数、DMA 映射区间列表。

失败时返回原因码（`EPREFLIGHT_A3_DMA_INCOMPLETE` 等），
并在 usbvfiod 日志中打印一行结构化记录，供 harness 断言。

#### 4.2.1 部署前提：要收到通知，VMM 必须按约定启动

交接的**决策**走控制 socket，但**"迁移失败了/切换开始了"这类通知**来自 VMM 自己的事件流。
因此有一个必须写进部署文档的前提：

> **Cloud Hypervisor 必须带 `--event-monitor fd=<n>`（或 `path=<file>`）启动**，
> 否则我们收不到任何事件通知。

- `fd=` 形式：由启动方（本 harness 的 `guest/ch-with-events.py`）创建 `socketpair`，
  把一端作为 `fd=<n>` 传给 CH，另一端自己读——**主动推送订阅**，不落盘、不扫日志、不轮询。
  CH 侧零改动，只需这一个启动参数。
- `path=` 形式：指向 FIFO 或文件，效果相同，只是多一个文件系统对象。
- **不带的后果**（必须在运维文档里写明）：控制器仍可通过控制 socket 做
  `ready`/`commit`/`abort`/`reclaim`，也可以用 `watch` 等服务端的候选通知；
  但它**无法及时得知迁移失败**，此时保源只能依赖服务端的三级兜底链，
  而不是控制器的显式回滚。
- 实测（`guest/event-monitor-fd.py`）：事件在 CH 发出后微秒级到达
  （`+0.004s vmm/starting`、`+0.407s vm/booted`）。
- **不保证不丢**：CH 监听线程用非阻塞 fd 写且忽略写错误，读端堵塞会静默丢事件
  （JSON 与分隔符是两次 write，满缓冲时甚至可能截断一个事件）。订阅端必须及时 drain。

M6（绑定式预检，见 §9.3）**不需要**新增 CH 启动参数：它只要求控制 socket 可达。

### 4.3 控制通道协议

复用现有的 `src/hotplug_protocol`（已有 `Attach`/`Detach`/`List` 与 `remote` 工具），新增：

**实现说明（commit `3cfac7d`）**：三个旧命令是定长二进制消息，交接命令需要携带连接号、epoch
和自由文本原因，因此**在同一 socket 上新增命令号 3 = 行式文本协议**：

```text
status | ready <conn> | commit <conn> <epoch> | abort <conn> [reason…] | reclaim <conn> <epoch>
ok owner=0 prev=- candidate=1 epoch=1 ready=false lease_ms=5000 live=[…]
err code=EPREFLIGHT_NOT_READY detail=…
```

其中 `watch <ms>`（`remote --handover-watch <MS>`）是**推送路径**：服务端在 ownership 状态上
挂一个条件变量，候选一旦暂存、或归属/epoch 变化，就立刻应答；否则最多等 `ms` 毫秒。
原因是实测数字——候选只活 3.7–8.3 ms，比一次 status 往返还短，**轮询必然漏掉**。

理由是可诊断性：交接是策略决定，而读不回来的策略决定无法排障（`socat` 即可手工驱动）。
`remote` 工具额外接受 `owner|prev|candidate|<id>` 角色关键字，harness 不必记住连接号。

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

#### 自动兜底：owner 连接消失时的三级处理（**已实现，见 D25.5**）

死掉的连接不能继续持有设备——它无法服务中断，而状态行还会继续报告它是 owner（真机 T1 的
aftermath 实测到 `owner=1 prev=0 live=[]`）。因此 `owner` 连接断开时按优先级处理：

| 顺序 | 条件 | 动作 | 日志 |
|---|---|---|---|
| 1 | `prev` **仍在线** | `owner = prev`、装线、kick 一次 | `auto-reclaimed the device for client {prev} because the owner {id} disconnected` |
| 2 | 有**暂存的候选** | 提升候选为 owner、装线、kick | `promoted the staged candidate {id} because the owner {id} disconnected` |
| 3 | 都没有 | 设备变 **unowned**（等价于刚启动），**下一个注册立即成为 owner** | `nothing could take the device over; it is unowned` |

三点说明：

- 第 1 条**不再要求"仍在租约内"**。租约约束的是*控制器*的 reclaim 决策（防止迟到的 actor 把
  已经成功的交接回滚）；而这条路径只在 owner **确已消失**时运行，此时拒绝归还只会把设备留给
  一个不存在的连接，严格更差。`--handover-auto-reclaim` 仍然是这条兜底的总开关。
- 第 2 条覆盖"源端死在成功迁移最后一刻"；第 3 条覆盖"迁移失败后源端 VMM 重连"——
  重连会是一个**新连接、新 id**，既不是 `prev` 也无法 reclaim，只有"设备无人认领，
  下一个注册立即接管"才能让它自动拿回设备。
- 成功迁移中不会误触发：成功时断开的是源端（`prev`），不是 owner；
  而 owner 断开时 `prev` 的连接也已经关闭（见 4.5.3）。

#### 次要触发（为将来保留）

接受来自 `prev` 的**一次新的非空 `SetIrqs`**（在租约内、`prev` 身份成立）作为 reclaim 请求。
今天 CH 不会发（见上面的源码事实），但若将来 CH 在失败恢复路径中重新 `enable_irq`，
或我们提供一个调用 `enable_irq` 的 helper，这条路径即自动生效，且与主触发不冲突（幂等）。
**注意**：若该重连是一个**新连接**（新 id），它不会命中这条规则，而是命中上面第 3 条。

#### 两种时序对照

```text
A. 提交前失败（常见）                        B. 提交后取消（需要 reclaim）
   src=owner, dst=Candidate                     src=prev, dst=owner(epoch=N)
   dst 预检失败/超时/Abort                      迁移取消 / dst 崩溃
   -> 丢弃 staged line                          -> HandoverReclaim{src,N}  (驱动方)
   -> src 全程未受影响，**不需要 reclaim**         或 owner 连接断开 -> 自动兜底
                                                -> src=owner(epoch=N+1)，装线 + kick
```

### 4.5.3 实测：CH 在切换点就会拆掉源端设备（**真机 T1**）

真机 T1（`/root/.dsh-tmp/usb-demo-t1`，见 D25.3）抓到的毫秒级时序：

```
01.940  目标端 connect → "hand-over candidate: client 1 staged (owner 0 keeps the line until commit)"
01.948  源端 set IRQs #fds: 0            ← CH 主动 disable 源端中断线（设备 deactivate）
01.949  Connection closed (client 0)     ← 源端 vfio-user 连接被关闭
01.995  commit → set IRQs #fds: 1 → owner 1 (epoch 2) + kick
```

两个必须写进结论的事实：

1. **源端不是"被抢"，而是自己先交还。** CH 在切换点 deactivate 源端设备（disable IRQ + 关闭
   vfio-user 连接），发生在目标端注册前后约 8 ms，**早于迁移结果确定**。因此"暴露窗口"的
   真实起点是这次 disable（而不是源端 `paused`），终点是 commit 时新线安装 + kick。
   T1 实测：disable→安装 ≈ **48 ms**，paused→安装 ≈ **70 ms**。
   窗口内目标端 guest 已经在发命令，事件 TRB 也已经写进共享 event ring（两端共享同一份
   guest 内存），只是没人 kick；commit 的那一次 kick 让目标端 guest 重新查看 ring，
   所以业务侧只表现为"掉速度"。
2. **"提交后失败"必须重新审视**：此时源端连接已经不存在，"reclaim 给源端"无处可还。
   也就是说，切换点之后的失败要在 CH 层面恢复源端设备，只能靠 CH 自己重新
   `enable_irq`/重连；usbvfiod 能做的、也必须做的是：**死掉的 owner 不持有设备**（4.5.1 三级兜底），
   从而让重连的源端**下一个注册立即接管**。真机失败复现因此必须在"目标端注册之后"触发
   （`guest/usb-migration-demo.sh` 的 `KILL_DST_ON_REGISTRATION=1` +
   `USBVFIOD_INJECT_STAGING_DELAY_MS`）。

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
| `docs/`、`paper/` | **已完成**：论文 §Failure and rollback 已改写为"已实现并实测"，并新增两节；`paper/data/two-phase.txt` 提供数字 |

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
| T1 | 正常迁移 | 现有 harness + `ready`/`commit` | **已实测 PASS**（D25.3）：md5 一致、spans migration、零重枚举、downtime 18 ms |
| T2 | 候选缺 DMA 映射 | 候选只读 region 不 `DmaMap` | **已用无 guest 测试证明**（D25.2）：A3 拒绝、源端不动、候选可重试 |
| T3 | 候选 eventfd 无效 | 传入坏 fd | A4 拒绝；源端无感 |
| T4 | 设备已被拔出 | 候选期间 detach 设备 | A5 拒绝；源端收到明确错误而非静默卡死 |
| T5 | 驱动方声明目标有问题 | 只 `HandoverAbort` | **已用无 guest 测试证明**（D25.2）：不切换、epoch 不变、reason 进日志 |
| T6 | 预检超时 | 候选不发 `ready` 直到超时 | **已用无 guest 测试证明**（D25.2）：过期 → `EPREFLIGHT_TIMEOUT`；源端无感 |
| T7 | 提交后取消（显式） | commit 后立刻 `HandoverReclaim{src, N}` | **已用无 guest 测试证明**（D25.2，断言源端 eventfd 被 kick） |
| T7b | 提交后目标端崩溃（自动兜底） | commit 后 kill 目标 CH | **已用无 guest 测试证明**（D25.2）：自动归还 `prev` 并 kick |
| T7e | owner 死亡且 `prev` 已消失 | 断开源端后再断开目标端 | 设备变 unowned；**下一个注册立即成为 owner 并被 kick**（D25.5） |
| T7f | owner 死亡时有暂存候选 | 源端 owner 直接断连 | 暂存候选被提升为 owner 并被 kick（D25.5） |
| T7c | 非上一任发 reclaim | 用第三个连接/错误 pid 发 reclaim | `ERECLAIM_NOT_PREVIOUS_OWNER` / `ERECLAIM_UNTRUSTED_PEER`，归属不变 |
| T7d | 陈旧 epoch | 用 `N-1` 发 reclaim | **已用无 guest 测试证明**：`EEPOCH_MISMATCH`，归属不变；非 prev 得 `ERECLAIM_NOT_PREVIOUS_OWNER` |
| T12 | 事件驱动检测（取消） | 迁移中途杀目标端 / 触发源端 `resumed` | 控制器据 `migration-receive-failed` 或 `resumed` 自动 reclaim；源端复制继续 |
| T13 | 事件驱动检测（成功） | 正常迁移 | `migration-receive-finished` → 不回滚；与 T1 等价 |
| T8 | 租约过期后 reclaim | 超过 `lease_ms` | 拒绝并给 `ERECLAIM_LEASE_EXPIRED`；设备归属不变 |
| T9 | 陈旧破坏性命令 | 非 owner 发 `SetIrqs` 空 fd / `DmaUnmap` | **已用无 guest 测试证明**：忽略 + warn；且新 owner 的线仍可被 kick |
| T14 | 目标端"已注册但迁移失败"（真机） | 目标端注册后 kill 目标 CH（`USBVFIOD_INJECT_STAGING_DELAY_MS`） | 源端从未失去线；CH 恢复源端后复制继续 |
| T10 | 单客户端回归 | `--max-clients 1` | 与基线逐字节一致 |
| T11 | owner 卡死 | 提交后 owner 不续租约 | 归属回到上一任存活连接（若启用租约归还） |

判定仍**全部取自 guest 自身日志**（沿用 `guest/verdict.py`），
并新增"交接诊断"字段：`preflight_result`、`commit_epoch`、`reclaim_used`。

---

## 8. 对论文声明的影响（必须如实处理）

论文原先把"失败与回滚"列为**未实现的限制**，并明确指出
"归属不提交到迁移事务、取消后源端无法恢复"。**本方案落地后该段已按实测改写**：

- §VII 的该段已改为"已实现（预检 + 显式提交 + 租约内 reclaim + owner 死亡兜底）"，并附实测；
- 需要**新增一节**描述两阶段交接的状态机与预检清单；
- 摘要/贡献里"无重枚举、零感知"的结论**不变**，但增加"失败保源"这一新的可验证性质；
- 必须重新跑 T1–T11 并保留原始日志（沿用 `artifacts/` 归档与 `collect-artifacts.sh`）。

---

## 9. 风险与未决问题

1. **A6 的判定边界**：`ready` 由驱动方给出，服务端无法验证其真实性。
   → 需要约定：驱动方必须是可信控制通道（unix socket 权限），并在文档中明确"ready 的语义"。
2. **提交与 VMM 时序（已实测，结论有更新）**：**源端在暂存后 3.7–8.3 ms 就被 CH 自己
   deactivate 并关闭连接**，而控制器的 `ready`+`commit` 需要两次往返（实测 23.9 ms），
   所以自然路径上闭合窗口的是**兜底提升**，不是显式 commit。**推荐的调用点因此改为**：
   控制器应当把"目标端注册"当作可供判断的**最后**时机；若需要在切换前完成判断，
   必须启用下面的"绑定式预检"。
3. **绑定式预检（下一步，见 §9.6）**：把预检从"劝告性"变成"约束性"——目标端注册的应答
   要挂住到控制器决定为止。这是让领导要求的"缺东西就保持旧环境"成为**强制**语义的唯一办法。
4. **回滚的传输语义**：reclaim 时，源端可能有在途传输已由设备完成但未送达源端，
   kick 能否覆盖需要实测（与现有 kick 同源风险）。目前只有事件计数（窗口内 0–3 个）
   与端到端 md5 一致作为间接证据。
5. **多设备**：当前按设备/控制器单实例设计；多设备时需要 per-device 的 Ownership。
6. **A6 与 `ready` 的语义**：默认 `--handover-require-ready=true` 只约束显式 commit；
   兜底提升**不受** `ready` 约束（owner 已死时没有人能声明 ready），只受自动预检（A3/A4）约束。

---

## 10. 里程碑（待批准后执行）

| 阶段 | 内容 | 产出 |
|---|---|---|
| M1 | 本文档评审与定稿 | 本文件 + 反馈修订 |
| M2 | 服务端状态机 + 预检 A3/A4/A6 + 控制通道命令 | **完成**（`3cfac7d`；无 guest 测试：9 个） |
| M3 | harness 驱动（ready/commit/abort/reclaim/事件判定）+ T1 | **完成**（`usb-w1`/`usb-demo-t1`：VERDICT PASS） |
| M4 | 故障注入与恢复（T2/T5/T6/T7/T7b/T7e/T7f/T9/T14） | **完成**（无 guest 9 测试 + 真机 `usb-f2`/`usb-v2` PASS）；T3/T4/T8 仍待做 |
| M5 | 论文与开发日志更新、原始日志归档 | **论文已更新并编译（14 页）**，[`DEVLOG_cn.md`](DEVLOG_cn.md) D25–D26；原始日志待归档到 `/mnt/mt` |
| M6 | **绑定式预检**：暂存时释放 ownership 锁、在条件变量上等控制器决定、按 Ok/Err 回复 | 待批准后执行（见 §9.3） |

> 说明：M2–M5 涉及本地代码与实验；任何对第三方 GitHub 仓库的写操作
> （PR/issue/comment/review，或会更新上游 PR 的 fork 推送）都会先按
> `DEVLOG_cn.md` D22 的纪律逐条请你批准。
