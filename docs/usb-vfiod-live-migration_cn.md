# usbvfiod 设备状态保持与 Live Migration 工作计划

| 项目 | 内容 |
|---|---|
| 状态 | 最终版计划（待评审） |
| 版本 | v1.0 |
| 范围 | 本机休眠/唤醒、本机快照/恢复、本机 live migration、controller/agent 重启；跨主机迁移为可行性研究 |
| 目标组件 | `usbvfiod`、`usbdev-agent`、Guest helper/driver、必要时的 Cloud Hypervisor / rust-vmm 集成 |
| 相关文档 | `docs/developers/architecture.md`、`docs/users/systemd.md`、`docs/users/security.md` |

---

## 1. 范围与目标

本计划为 `usbvfiod` 建立完整的**设备状态保持与迁移**能力，使使用 usbvfiod 直通 USB 设备的 Guest 能够：

1. 完整地休眠与唤醒控制器；
2. 在暂停/迁移前主动或被动地让控制器进入 quiesce 状态并被正确响应；
3. 全程保持 host 侧 USB 设备连接与上下文（不断开、不 reset、不 autosuspend）；
4. 唤醒/迁移后在原位置或新位置恢复，并重新绑定 host 侧设备会话；
5. 对 Guest 表现为无断开、无重枚举、上下文不变、可继续休眠/迁移前的操作。

**范围内**：状态盘点与格式；quiesce；状态保存/恢复/重连；Guest 休眠/唤醒；VMM live migration；`usbdev-agent`；迁移失败/回滚；跨主机可行性分析；评估与交付文档。

**非目标（本期不承诺实现）**：跨主机"透明"迁移物理设备；USB/IP 与 virtio-usb 的实现（仅分析与未来工作）；非 Linux Host；等时（isochronous）支持（独立方向）。

---

## 2. 术语

- **Controller（控制器核心）**：`usbvfiod` 内的 xHCI 仿真部分，可被停止与重建。
- **Agent（`usbdev-agent`）**：长生命周期进程，持有 USB fd、interface claim 与 endpoint；禁止 reset 与 autosuspend。
- **Quiesce**：停止接受新工作并收敛在途传输，但**不**销毁端点、**不**释放设备。
- **Zero-perception**：Guest 观察不到任何设备变化（无 disconnect、无 reset、无重枚举）。
- **guest-cooperative migration**：VMM 在暂停 vCPU 前请求 Guest 先完成 USB 层 quiesce 的迁移变体。
- **vCPU-pause only migration**：VMM 仅暂停 vCPU，控制器在暂停瞬间直接 freeze 的迁移变体。

---

## 3. 最终需求

### 3.1 状态与语义

| ID | 需求 |
|---|---|
| R1 | 完成迁移相关状态盘点与分类（controller-private / guest-RAM / host-session / agent），产出 inventory 文档 |
| R2 | 定义版本化、可校验、前向兼容的状态格式（`schema_version` + `abi_version` + CRC） |
| R3 | 状态可完整保存、恢复、重连；同一状态格式服务于休眠与迁移两条路径 |
| R4 | 边界处 I/O 不丢、不重、无意外 disconnect/re-enumeration |
| R5 | 支持 VMM 迁移生命周期语义（pre-copy / stop-and-copy、停机窗口、收敛与脏处理） |

### 3.2 触发与传输

| ID | 需求 |
|---|---|
| R6 | Guest 主动 suspend/resume：标准 PCI PM 与 paravirtual ABI + Guest helper |
| R7 | VMM 主动迁移：实现并集成 vfio-user migration 模型到 Cloud Hypervisor（必要时含 rust-vmm 改动） |
| R8 | Guest 休眠与 VMM 迁移复用同一 quiesce/resume 生命周期与状态核心，语义一致 |
| R9 | 支持 guest-cooperative 与 vCPU-pause only 两种迁移变体，并明确各自适用条件 |

### 3.3 设备与主机资源

| ID | 需求 |
|---|---|
| R10 | `usbdev-agent` 保持设备会话：不 reset、不断开、不 autosuspend、保持 interface claim |
| R11 | `usbvfiod` 可独立重启/升级而不丢设备（由 agent 保活并重新绑定） |
| R12 | 分析并设计 usbvfiod ↔ Linux kernel/物理设备的迁移机制 |

### 3.4 场景与边界

| ID | 需求 |
|---|---|
| R13 | 同主机：S3/S4、CH 快照/恢复、controller/agent 重启 |
| R14 | 同主机 live migration |
| R15 | 跨主机迁移可行性判定；不可行时给出限制分析与替代方案 |
| R16 | 迁移失败/回滚：失败后源主机继续正确运行，Guest 不损坏 |

### 3.5 评估、交付与约束

| ID | 需求 |
|---|---|
| R17 | 评估：状态正确性、I/O 连续性、停机时间、兼容性、遗留限制 |
| R18 | 参考/对照：QEMU/KVM 作为 reference；USB/IP、virtio-usb 作为未来工作 |
| R19 | 文档交付：设计、用户、运维与评估报告 |
| R20 | 工程约束：仅引入非 GPL/非传染性依赖（`deny.toml` 白名单）；状态文件、agent、Guest helper 的最小权限与完整性 |

---

## 4. 验收与评估标准

### 4.1 功能验收

| 需求 | 验收标准 |
|---|---|
| R6 Guest 休眠/唤醒 | 标准 PM 与 paravirtual 两条路径均可完成握手；失败可中止并重试 |
| R13 同主机休眠/快照/重启 | resume 后寄存器与内部状态逐字段一致；I/O 可继续 |
| R14 同主机迁移 | 迁移后 Guest 继续使用同一虚拟控制器；无重枚举 |
| R3/R4 状态与 I/O | `lsusb -v` 前后一致；无 udev remove/add；**CSC/PRC=0，非请求 HCRST=0**；无 lost/duplicated I/O |
| R16 回滚 | 迁移失败后源端继续正常运行，Guest 状态一致 |
| R10/R11 设备会话 | 休眠与 `usbvfiod` 重启期间 fd 保持、claim 保持、`power/control=on` |

### 4.2 评估指标

1. **状态正确性**：保存/恢复字段级比对；Guest 视角设备树与句柄不变。
2. **I/O 连续性**：边界前后块设备 fio/校验和无丢失、无重复。
3. **停机时间**：live migration 的 downtime 测量与收敛行为。
4. **无中断性**：CSC/PRC=0、udev 事件=0。
5. **兼容性**：USB storage / HID / serial 等类别分别验证。
6. **迁移变体对比**：guest-cooperative 与 vCPU-pause only 在正确性、I/O 连续性、停机时间上的差异。
7. **限制**：跨主机、物理设备不可复制、在途传输语义、类别差异。

---

## 5. 目标架构

### 5.1 组件

```mermaid
graph TD
    VM[Guest: xHCI driver + suspend helper]
    VMM[Cloud Hypervisor + migration logic]
    CTRL[usbvfiod controller core]
    STATE[(ControllerState store / vfio-user state region)]
    AGENT[usbdev-agent]
    DEV[(Physical USB device)]

    VM --- VMM
    VMM -- "vfio-user: MMIO/IRQ/DMA + migration state" --- CTRL
    CTRL --- STATE
    CTRL -- "local IPC: control + transfer + session" --- AGENT
    AGENT -- usbfs --- DEV
```

| 组件 | 职责 |
|---|---|
| Controller core | xHCI 仿真；quiesce；状态导入导出；paravirtual/PM 寄存器 |
| Migration adapter | 通过 vfio-user migration 模型与 CH 交互（state region、迁移状态机） |
| `usbdev-agent` | 持有 fd/claim/endpoint；设备会话保活；禁止 reset/autosuspend |
| Guest helper | Guest 主动休眠握手与 guest-cooperative 迁移响应 |
| CH/rust-vmm（可能改动） | 迁移编排、状态搬运、设备生命周期 |

### 5.2 一个核心、两类触发

```mermaid
graph LR
    A[Guest 主动 suspend/resume] --> CORE[Quiesce + ControllerState 核心]
    B[VMM 主动 live migration] --> CORE
    CORE --> S1[本地状态文件]
    CORE --> S2[vfio-user migration region]
    CORE --> AG[usbdev-agent 设备会话]
```

### 5.3 不变量

1. Agent 是物理设备会话的唯一所有者。
2. 任何挂起/迁移路径不得 `reset`/`clear_halt`/重开设备节点。
3. 任何恢复路径不得置 PORTSC 的 CSC/PRC/PSC。
4. 状态格式唯一，两条路径共用；版本不匹配必须拒绝加载并报错。

---

## 6. 协议

### 6.0 统一 quiesce/resume 生命周期

三种触发方式映射到同一个状态机：

| 触发 | 进入 quiesce 的时机 | 停机窗口 | Guest 感知 |
|---|---|---|---|
| Guest 系统休眠（S3/S4） | Guest helper 发起 `PREPARE/ENTER`；内核随后执行 PCI D3 | 长（直到唤醒） | 明确休眠/唤醒 |
| VMM migration（guest-cooperative） | VMM 在 stop-and-copy 前请求 Guest quiesce，再暂停 vCPU | 短（blackout） | 无（仅时间跳跃） |
| VMM migration（vCPU-pause only） | 随 vCPU 暂停直接 freeze 控制器 | 短 | 无 |

统一状态机：`RUNNING → PREPARING → READY → SUSPENDED/FROZEN → RESUMING → RUNNING`，并与 vfio-user migration 的 `PRE_COPY / STOP_COPY / STOP / RESUMING` 对齐（具体命名以规范与 CH 实现为准）。

**guest-cooperative 迁移的请求通道**：VMM 通过 vfio-user migration 状态告知 usbvfiod 迁移开始 → usbvfiod 在 paravirtual 控制块置"host 请求 quiesce"位（附录 A 的 `PV_HOST_REQ`）→ Guest helper 轮询到后完成 USB 层 quiesce 并写 `PREPARE_SUSPEND`/`ENTER_SUSPEND` → usbvfiod 变为 READY 并通过 migration 状态回报 VMM → VMM 随即暂停 vCPU 完成 stop-and-copy。这样在途 I/O 在 blackout 之前就已收敛。

> 说明：标准 live migration 只暂停 vCPU，**不会**通知 Guest OS 进入 suspend。要让物理 USB 的在途 I/O 优雅收敛、避免重枚举，必须由 Guest 配合（paravirtual 通知或标准 PM 前置 quiesce）；这是本计划要补的能力。

### 6.1 标准 PCI PM 路径

1. 新增 PM Capability（cap id `0x01`）+ PMCSR，支持 D0/D3hot、PME。
2. `ConfigSpace`/`RegisterSet` 增加**写回调（副作用）**能力，用于拦截 PMCSR 写。
3. 收到 D3hot：若尚未 SUSPENDED，则尽力执行 quiesce（有界 drain），随后标记 SUSPENDED；D3 写一律接受。
4. 收到 D0：执行 resume，**不产生任何端口变更事件**。
5. 对 Guest 驱动在 suspend/resume 期间的寄存器序列采取**幂等接受**：保留 slot/context/ring，不因驱动重写寄存器而清空。

### 6.2 Paravirtual 路径

- 在 xHCI 扩展能力链尾部添加**厂商自定义 xECP**，其字段给出 BAR0 内一个专用控制块的偏移（建议 `0x1000`，该区间当前未使用）。
- Guest helper 通过 `/sys/bus/pci/devices/<bdf>/resource0` 映射 BAR0 后定位并操作该控制块（需 root/CAP_SYS_RAWIO）。
- 控制块提供 `MAGIC`、`ABI_VERSION`、`CMD`、`STATUS`、`ACK`(RW1C)、`COOKIE`、`DEADLINE_MS`、`ERR_DETAIL`、`HOST_REQ`，定义见附录 A。
- Guest helper 以 `systemd-sleep` hook（pre/post）实现握手；失败以非零退出中止休眠。

### 6.3 VMM 主动 migration

以 vfio-user migration 模型为基线：

1. **能力协商**：controller 向 CH 报告支持迁移的 region 与迁移状态集合。
2. **迁移状态机**（对齐 vfio-user 规范/CH 现有框架）：`RUNNING → PRE_COPY → STOP_COPY → STOP → RESUMING → RUNNING`。
3. **pre-copy 阶段**：允许 Guest 继续运行；controller 支持可重复的状态快照（增量或全量，取决于 vfio-user 语义）。
4. **stop-and-copy**：quiesce；收敛在途 I/O；导出最终状态；记录 dequeue pointer 等。
5. **目标端恢复**：加载状态；重建 worker；重新绑定设备会话（目标端 agent）或建立等效资源；不产生端口变更事件。
6. **源端清理 / 回滚**：成功后释放；失败则源端解除 quiesce 继续运行（R16）。

**与统一生命周期的映射**：stop-and-copy 对应 `PREPARING → READY → SUSPENDED`，目标端 `RESUMING → RUNNING` 对应唤醒。guest-cooperative 变体在暂停 vCPU 前完成 USB 层 quiesce；vCPU-pause only 变体在暂停瞬间直接 freeze，并在目标端恢复未完成事务。

> 关键未知：CH/rust-vmm 当前对 vfio-user migration 的支持边界；是否需要上游补丁。若不可用，本机场景回退到"本地状态文件 + agent 重绑定"。

### 6.4 Quiesce 与在途 I/O 策略

- 停止接受新 doorbell/TRB；等待在途 URB 完成（上限 `DEADLINE_MS`，默认 2000 ms）。
- 未提交的 TRB 留在 ring，恢复后从保存的 dequeue pointer/cycle 继续。
- 超时或仍有排队工作：
  - Guest 路径：返回 `BUSY_RETRY`，helper 中止并重试。
  - 迁移路径：延长 stop-and-copy 停机窗口（若框架允许）或取消 URB 并让 Guest 重试；迁移失败则回滚。
- 取消**不 reset 设备**；OUT 传输部分生效的语义限制必须文档化，重试需上层协议保证幂等。

### 6.5 失败与回滚

- 源端在收到迁移成功确认前**不得**释放设备会话与状态。
- 迁移失败：源端 `RESUME`，恢复 worker 与设备会话，Guest 继续运行；记录并上报失败原因。
- 目标端失败：清理已加载状态，不占用设备资源。

### 6.6 Zero-perception 保证

1. 冻结并原值返回 PORTSC/PORTPMSC，绝不置变更位。
2. 不改变 slot/endpoint context 与各 dequeue pointer（Guest RAM 内容保持）。
3. 对 Guest 驱动在 resume 时重写的寄存器（USBCMD/CRCR/DCBAAP/ERSTBA/ERDP）幂等处理。
4. 不因 suspend/resume/migration 产生 Port Status Change Event。
5. 恢复后重新校验 Guest RAM 映射（DMA map 重建）再放行 worker。
6. Guest 前置条件：避免 `XHCI_RESET_ON_RESUME` 行为（使用 s2idle、定制配置或定制驱动）。

---

## 7. 状态模型与持久化

### 7.1 状态分类

| 类别 | 内容 | 处理 |
|---|---|---|
| Controller 私有 | PCI config + MSI-X + PMCSR、USBCMD/USBSTS/CRCR/DCBAAP/CONFIG、PORTSC/PORTPMSC、IMAN/IMOD/ERSTSZ/ERSTBA/ERDP、EventRing 生产者状态、CommandRing 状态、slot/endpoint worker 状态、在途 TD | 序列化为 `ControllerState` |
| Guest RAM 内 | DCBAA、Device/Input Context、传输环、ERST、事件环内容 | 不重复保存；恢复时按地址引用并校验 |
| Host kernel/device | 设备配置、endpoint toggle、设备内部状态 | **不可序列化**；靠 agent 保持 fd/claim、不 reset 保全 |
| Agent 会话 | session id、设备标识、claim、已打开 endpoint | agent 侧保持；跨 controller 重启保留 |

### 7.2 状态格式与传输

- `ControllerState`：版本化 + CRC + UUID + DMA 段摘要（附录 B）。
- **两条传输通道**：
  1. **vfio-user migration region / device-state region**（迁移主线）；
  2. 本机状态文件 `/run/usbvfiod/<uuid>/state.bin`（Guest 休眠与降级路径）。
- 原子写入（temp→fsync→rename）；权限 `0600`/目录 `0700`；读取时校验版本与 CRC。
- 前向兼容：未知字段忽略；版本不匹配拒绝加载并报错。

### 7.3 跨主机状态语义

- **Guest RAM** 随 VM 迁移（VMM 负责）。
- **Controller 私有状态** 通过 vfio-user migration region 搬运。
- **Host 设备会话** 无法搬运 → 目标主机需要等效资源（见 §8.3）。

---

## 8. 设备与主机资源

### 8.1 `usbdev-agent`

- 持有 fd/claim/endpoint；休眠期间不提交新 URB；禁 autosuspend（`power/control=on`）；不 reset。
- 与 controller 通过本地 IPC 解耦：`AgentRealDevice` 代理现有 `RealDevice` trait，控制器核心逻辑基本不变；`nusb` 后端迁入 agent，进程内后端保留供测试。
- IPC：Unix domain socket，长度前缀二进制帧，请求/响应带 `request_id`；完成以异步事件通知；大传输用 memfd/`SCM_RIGHTS` 或共享内存环。
- controller 重启时按 `session_id` 重新绑定。

### 8.2 同主机

- 休眠/快照/迁移都保持同一 agent 会话，源=目标。
- `usbvfiod` 可重启，agent 保活设备。

### 8.3 跨主机可行性分析

物理设备不可复制，目标主机必须获得等效 USB 资源。候选机制：

| 机制 | 思路 | 代价/限制 |
|---|---|---|
| 目标端本地同型设备 | 目标 agent 打开本地设备，迁移软件状态 | 不是"迁移设备"；设备内部状态需重建；适用存储类 |
| USB/IP | 设备留源主机，经 USB/IP 导出，目标 `vhci-hcd` 接入 | 源主机必须在线；网络延迟/带宽；与 xHCI 模型叠加复杂 |
| virtio-usb（未来工作） | 复用 USB/IP + vhci-hcd，替换 TCP 为 VirtIO 传输 | 上游多为 stub，早期阶段 |
| 不支持 | 迁移前热拔出、迁移后热插入 | Guest 会看到 disconnect/re-enumerate，违反 R4 |

**判定要点**：设备内部状态不可复制；类别差异（存储可重挂载恢复逻辑状态，HID/实时设备更差）；在途 I/O 无法跨主机续传。Phase 5 给出明确结论。

---

## 9. 工作分解

### Phase 0 — 调研、行为验证与设计冻结（4 周）
- T0.1 分析 vfio-user migration 规范、QEMU 实现、CH/rust-vmm 相关 draft PR。
- T0.2 确认 CH 对 vfio-user migration 的支持边界与所需改动。
- T0.3 实测 stock Guest S3/S4 的 xhci 寄存器/命令序列与是否重枚举。
- T0.4 状态盘点（R1）与需求确认。
- T0.5 同主机/跨主机可行性前置分析、物理资源模型。
- T0.6 冻结 paravirtual ABI v1 与 `ControllerState` schema v1。
- **退出**：支持度地图、状态 inventory、需求/范围、go-no-go。

### Phase 1 — 状态核心：quiesce + 序列化 + 零感知（6 周）
- T1.1 `ControllerState` + 序列化 + 版本/CRC。
- T1.2 `SuspendCoordinator`/quiesce 广播 + 在途 I/O 策略。
- T1.3 端口/context 冻结 + zero-perception 保证。
- T1.4 多 worker 快照一致性 barrier。
- T1.5 单元测试。
- **退出**：状态往返正确；quiesce 在单元层面可验证。

### Phase 2 — Guest 主动路径（设计 + 实现）
- T2.1 PCI PM capability + 配置空间写回调。
- T2.2 厂商 xECP + 控制块 ABI。
- T2.3 参考 Guest helper（systemd-sleep hook）。
- T2.4 S3/S4 集成测试（含 busy→retry）。
- **退出**：确定性 Guest 休眠/唤醒。

### Phase 3 — VMM 迁移路径（主线，设计 + 实现）
- T3.1 usbvfiod 侧 vfio-user migration/device-state region 实现。
- T3.2 CH / rust-vmm 集成（能力协商、状态搬运、生命周期）。
- T3.3 迁移状态机（pre-copy / stop-and-copy / downtime）与两种变体。
- T3.4 失败与回滚（R16）。
- T3.5 同主机 live migration 原型。
- **退出**：同主机迁移后 Guest 可继续使用设备，无重枚举。

### Phase 4 — 设备会话与物理资源
- T4.1 `usbdev-agent` 拆分 + IPC + `AgentRealDevice`。
- T4.2 `usbvfiod` 独立重启/升级验证。
- T4.3 物理设备处理：同主机绑回；跨主机候选机制实验。
- T4.4 跨主机可行性实验与结论。
- **退出**：kill/restart usbvfiod 无断连；跨主机结论成文。

### Phase 5 — 评估与对照
- T5.1 功能/正确性/连续性/停机时间评估（R17）。
- T5.2 失败与边界测试（回滚、agent 崩溃、设备拔出）。
- T5.3 QEMU/KVM 对照（R18）。
- T5.4 跨主机限制与替代方案结论。
- **退出**：评估报告。

### Phase 6 — 加固、文档与交付
- T6.1 故障注入与安全评审（R20）。
- T6.2 用户/开发/运维文档与评估报告（R19）。
- **退出**：验收矩阵全绿；文档定稿。

---

## 10. 时间线与里程碑

| 周期 | 阶段 | 主要交付 |
|---|---|---|
| 第 1–4 周 | Phase 0 | 支持度地图、状态 inventory、需求与范围、go/no-go |
| 第 5–10 周 | Phase 1 + Phase 2/3 设计 | 状态核心；休眠与迁移设计；迁移生命周期 |
| 第 11–14 周 | Phase 2/3 实现 | Guest 休眠路径 + usbvfiod migration + CH/rust-vmm 集成原型 |
| 第 15–18 周 | Phase 4/5 | 连续性/停机/回滚/限制评估；跨主机结论 |
| 第 19–22 周 | Phase 6 | 加固、文档与交付 |

**里程碑**：
- M1（第 4 周）：支持度地图与设计冻结。
- M2（第 10 周）：状态核心可用，设计评审通过。
- M3（第 14 周）：同主机休眠与迁移原型可运行。
- M4（第 18 周）：评估报告与跨主机结论。
- M5（第 22 周）：文档与交付定稿。

---

## 11. 文件级改动清单

| 文件/组件 | 改动 |
|---|---|
| `src/device/pci/{constants,config_space,register_set,xhci}.rs` | PM capability/PMCSR、写回调、suspend/resume 钩子 |
| 新增 `src/device/xhci/suspend.rs` | SuspendCoordinator、状态机、quiesce |
| `src/device/xhci/{command_ring,slot_manager,interrupter,port,endpoint}.rs` | freeze/unfreeze、状态导入导出 |
| 新增 `src/state.rs` | `ControllerState`、序列化、版本/CRC |
| `src/xhci_backend.rs` | vfio-user migration/device-state region、`reset`/`dma_unmap`、DMA 校验 |
| 新增 `src/migration/` | 迁移状态机、CH 交互适配 |
| Cloud Hypervisor / rust-vmm | 若上游缺 migration 支持，提交补丁（Phase 0 判定） |
| 新增 `src/agent/`（或独立 crate） | usbdev-agent、IPC、`AgentRealDevice` |
| 新增 `src/device/xhci/paravirt.rs` | 厂商 xECP 与控制块 |
| `src/main.rs`、`src/cli.rs` | 状态文件、agent socket、迁移参数 |
| `Cargo.toml` | `serde` + 二进制格式 + CRC 等 |
| `nix/checks/*` | 休眠/唤醒、快照、迁移、重连、回滚测试 |
| `docs/` | 设计、用户、运维与评估文档 |

---

## 12. 测试与评估计划

| 层级 | 内容 |
|---|---|
| 单元 | `ControllerState` 往返、ABI 解析、PMCSR 语义、freeze 状态机、迁移状态机、零事件保证 |
| 集成（NixOS + CH） | s2idle/deep S3、S4 hibernate、CH 快照/恢复、同主机 live migration、controller 重启、agent 重启 |
| 场景矩阵 | 见附录 C |
| 故障注入 | 在途超时、agent 崩溃、设备拔出、状态损坏、迁移失败回滚、helper 中止 |
| 评估 | 状态正确性、I/O 无丢/重、停机时间、兼容性、迁移变体对比、跨主机限制（R17） |

---

## 13. 依赖与许可证

`deny.toml` 允许 `MIT`、`Apache-2.0`、`Unicode-3.0`、`BSD-3-Clause`。新增依赖必须落在该列表内且为非 GPL/非传染：

| 用途 | 候选 | 许可 |
|---|---|---|
| 状态序列化 | `serde` + `bincode`/`postcard`/`ciborium` | MIT / MIT+Apache-2.0 |
| 校验 | `crc32fast` | MIT+Apache-2.0 |
| sysfs/权限 | `nix`（可选） | MIT |
| systemd 通知 | `sd-notify`（可选） | MIT |
| IPC/SCM_RIGHTS | 现有 `tokio` + `vmm-sys-util` | MIT / BSD-3-Clause |
| 共享内存 | 现有 `memmap2` | MIT+Apache-2.0 |

**排除**：`libusb`（LGPL）、任何 GPL/AGPL。USB 后端继续使用纯 Rust 的 `nusb`。

---

## 14. 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| CH/rust-vmm 缺 vfio-user migration 支持 | 高 | Phase 0 判定；必要时提交上游补丁；本机回退本地状态文件 |
| stock Guest resume 时 reset/重枚举 | 高 | Phase 0 实测；paravirtual + 定制 Guest 配置/驱动 |
| 跨主机物理设备不可迁移 | 高 | 明确定位为可行性研究；给出替代与限制结论 |
| 迁移失败导致 Guest 损坏 | 中 | 源端延迟释放 + 回滚路径（R16） |
| agent 崩溃丢失设备 | 中 | watchdog、最小依赖、快速重启；残余风险上报 |
| 多 worker 快照不一致 | 中 | 全局 quiesce barrier + CRC |
| IPC 数据面性能 | 中 | memfd/共享内存、批量提交、基准门禁 |
| 状态文件泄露/篡改 | 中 | tmpfs、`0600`/`0700`、CRC/版本 |
| 休眠/迁移中设备被拔出 | 中 | 明确不可满足，走 detach 并上报 |
| 新增依赖触许可证红线 | 低 | 白名单 + `cargo-deny` |

---

## 附录 A：Paravirtual ABI v1

**厂商 xECP**（位于 BAR0 扩展能力链尾）：

| DWORD | 字段 | 说明 |
|---|---|---|
| 0 | `CAP_ID[7:0]`, `NEXT[15:8]` | 厂商自定义 ID；NEXT 指向下一 xECP（0=结束） |
| 1 | `ABI_VERSION[15:0]`, `CTRL_OFF_DW[31:16]` | 控制块在 BAR0 内的 dword 偏移 |
| 2 | `FEATURES[31:0]` | 保留特性位 |
| 3 | `RESERVED` | 保留 |

**控制块寄存器**（BAR0 + `CTRL_OFF_DW*4`，建议 `0x1000`）：

| 偏移 | 寄存器 | 访问 | 说明 |
|---|---|---|---|
| 0x00 | `PV_MAGIC` | RO | 固定魔数，用于存在性校验 |
| 0x04 | `PV_ABI_VERSION` | RO | ABI 版本 |
| 0x08 | `PV_CMD` | RW | 写入命令触发动作 |
| 0x0C | `PV_STATUS` | RO | 当前状态机状态 |
| 0x10 | `PV_ACK` | RW1C | 写 1 清除应答/事件位 |
| 0x14 | `PV_COOKIE` | RW | 本次握手令牌，原样回显 |
| 0x18 | `PV_DEADLINE_MS` | RW | helper 请求的最大 drain 时间 |
| 0x1C | `PV_ERR_DETAIL` | RO | `BUSY_RETRY`/`ERROR` 的细分原因 |
| 0x20 | `PV_HOST_REQ` | RO | host/VMM 请求 quiesce 的标志（由 usbvfiod 置位，供 Guest helper 轮询） |

**命令**：`PREPARE_SUSPEND=0x01`、`ENTER_SUSPEND=0x02`、`ABORT_SUSPEND=0x03`、`RESUME=0x04`、`QUERY=0x05`。

**状态**：`RUNNING=0`、`PREPARING=1`、`READY=2`、`SUSPENDED=3`、`BUSY_RETRY=4`、`ERROR=5`。

**错误细节**：`NONE=0`、`INFLIGHT_TIMEOUT=1`、`QUEUED_WORK=2`、`DEVICE_FAULT=3`、`INTERNAL=4`。

---

## 附录 B：`ControllerState` 字段草案

```
header: schema_version, abi_version, controller_uuid, payload_len, crc32
pci:    config_space[256], msix_table, msix_pba, pmcsr
xhci_operational: usbcmd, usbsts_shadow, crcr, dcbaap, config, pagesize
ports:  [ {portsc, portpmsc, usb_version, attached_device_id} ; 8 ]
runtime:[ {iman, imod, erstsz, erstba, erdp} ]
event_ring: {enqueue_pointer, trb_count, erst_count, cycle_state}
command_ring: {running, worker_state, dequeue_pointer, cycle_state}
slots:  [ {slot_id, slot_state, dcbaae,
           endpoints:[ {endpoint_id, ep_type, context_addr, ep_state,
                        dequeue_pointer, cycle_state, worker_state,
                        in_flight:[ {td_addr, submitted_bytes} ]} ]} ]
agent_session: {session_id, device_identifier, claimed_interfaces,
                open_endpoints:[{endpoint_id, direction, type}], speed}
dma_segments: [ {iova, size, kind} ]       // 仅作恢复后校验
migration: {state, generation, dirty_or_iteration_hint}
```

---

## 附录 C：场景矩阵

| 场景 | VMM | Controller | Agent | 期望 |
|---|---|---|---|---|
| S3（s2idle/deep） | 运行 | 运行 | 运行 | 零感知，I/O 继续 |
| S4 hibernate | 保存退出 | 重启+恢复 | 运行（设备不断） | 零感知，I/O 继续 |
| CH 快照/恢复（本机） | save→exit→restore | 重启+恢复 | 运行 | 零感知，I/O 继续 |
| 同主机 live migration | 源→目标 | 源导出/目标重建 | 运行（同一会话） | 无重枚举，I/O 连续 |
| controller 重启/升级 | 运行 | 重启 | 运行 | 无断连，I/O 继续 |
| agent 重启 | 任意 | 任意 | 重启 | 允许一次明确错误；上报并重试 |
| 迁移失败回滚 | 源继续 | 源 RESUME | 运行 | 源端 Guest 不受损 |
| 在途传输跨边界 | — | — | — | 优先完成；否则 BUSY_RETRY 或报错重试 |
| 跨主机迁移 | 源→目标 | 状态可搬运 | 目标需等效资源 | 可行性研究：给出可达性与限制结论 |
| 设备在过程中被拔出 | — | — | — | 不可满足零感知；detach + 明确上报 |
