# usbvfiod 技术架构与设计分析报告

> 对象：`https://github.com/cyberus-technology/usbvfiod`
> 本地独立克隆：`<repo>`（已移除 `origin` remote，与上游断开，作为独立项目）
> 版本：`v0.3.0`（`Cargo.toml`），HEAD `4d2c5af`
> 说明：仓库内没有独立的 PDF“项目报告”；本报告的“报告”依据为 `README.md` 与 `docs/`（`overview.md`、`developers/architecture.md`、`developers/quick-start.md`、`users/basic.md`、`users/systemd.md`、`users/security.md`）以及全部源码。

---

## 0. 一句话概括

`usbvfiod` 是一个**用户态 vfio-user 后端进程**，它在宿主机上模拟一个**虚拟 xHCI（USB 3.x）主机控制器 PCI 设备**，通过 vfio-user 协议挂到 VMM（目前主目标是 Cloud Hypervisor）上；而 USB 设备本体则通过 Linux 的 **usbfs（`/dev/bus/usb/*`）**、借助 Rust 的 `nusb` crate 直通给虚机。它的定位与 `virtiofsd` 之于 `vhost-user` 完全类似，只是把协议换成了 vfio-user（`README.md:5-11`，`docs/overview.md:1-6`，`docs/developers/architecture.md:25-60`）。

---

## 1. 目标、边界与项目阶段

**目标**（`docs/developers/architecture.md:7-21`）：

- 给 Cloud Hypervisor 增加 USB 支持（CH 本身没有原生 USB），且**尽量少改 CH 本身**；
- 优先 USB 存储，随后扩展到通用 USB 设备。

**已明确划定的边界**：

- 一个 `usbvfiod` 进程只服务**一个** USB 主机控制器 / 一个 VM，一个 controller 只接一个 vfio-user 客户端；虽然理论上可多路复用，但为了避免单点故障与安全责任而放弃（`docs/developers/architecture.md:52-60`）。
- 初始不实现 Hub，采用扁平拓扑，最多约 127 个设备（`architecture.md:90-93`）。代码里实际是 8 port / 8 slot（见 §2）。
- Host 侧只支持 Linux（`README.md:34`）。

**路线图状态**（`README.md:12-35`）：假设验证、USB 存储直通、扩展设备支持（USB-2 + 中断端点）、热插拔、稳定性与错误恢复均已完成；**Windows Guest 支持进行中**；**未完成项明确列出：等时（isochronous）端点支持、非 Linux Host、Cloud Hypervisor 之外的其他 VMM**。

**安全模型**（`docs/users/security.md`）：

- 威胁模型：恶意 USB 设备 + 恶意 Guest 驱动；信任 VMM 与 hotplug socket 调用方。
- 缓解手段：独立进程、Rust 内存安全、Guest DMA 只允许访问 vfio-user 映射的 Guest 物理内存（不支持 P2P DMA）、Host DMA 全部经内核 USB API 把关、hotplug socket 通过 **SCM_RIGHTS 传递已打开的 fd** 实现权限分离（server 自身无需打开设备节点的权限）、预留 `usbpolicyd` 做策略与机制分离（`architecture.md:62-80`）。

---

## 2. 运行形态与进程/线程模型

### 2.1 进程与启动流程

`src/main.rs`：

1. `Cli::parse()` 解析参数（`src/cli.rs:24-67`）：`--socket-path/--fd`（vfio-user）、`--hotplug-socket-path/--hotplug-fd`（热插拔控制）、`--device`（启动即直通的设备，可多次）、`--pcap-path`、`-v`。
2. 初始化 `tracing`，初始化 tokio runtime（`async_runtime.rs`）。
3. 构造 `XhciBackend`（`main.rs:53`），按 `--device` 逐个 `add_device_from_path`（`main.rs:55-61`）——**启动期失败直接 panic**。
4. 用 `backend.irqs()` / `backend.regions()` 创建 `vfio_user::Server`（`main.rs:63-73`）；
5. 可选启动 hotplug socket 监听线程（`main.rs:75-81`）；
6. 主线程进入 `server.run(&mut backend)` 阻塞循环（`main.rs:85-87`）。vfio-user 连接断开后 server 返回，进程退出（systemd 文档就是利用这一点做重启，`docs/users/systemd.md:7-12`）。

### 2.2 异步 worker 拓扑

除 vfio-user 主循环外，几乎所有设备逻辑都跑在 tokio 任务（worker）里，通过 `mpsc` channel / `oneshot` 通信，形成“**每个层次一个 mailbox worker**”的结构：

| Worker | 文件 | 职责 |
|---|---|---|
| `CommandWorker` | `xhci/command_ring.rs:50-288` | 服务命令环，解析并分发命令 TRB |
| `EventWorker`(Interrupter) | `xhci/interrupter.rs:65-234` | 向事件环写 Event TRB，并触发 MSI-X eventfd |
| `SlotWorker` | `xhci/slot_manager.rs:96-388` | slot 分配、Address Device / Configure Endpoint / Reset Device 等 |
| `EndpointLauncher` | `xhci/endpoint_launcher.rs:28-291` | 根据 Endpoint Context 的 EP Type 创建对应端点 worker |
| `EndpointWorker`（每个端点一个） | `xhci/endpoint.rs:21-249` | 端点状态机，拉取 TRB、驱动 host 传输、回写 Endpoint Context |
| `PortWorker` | `xhci/port.rs:104-322` | 端口 attach/detach、PORTSC、Port Status Change Event |
| `ResetCoordinator` | `xhci/controller_reset.rs:25-66` | 监听 `USBCMD.HCRST`，向三个组件广播复位并等待完成 |
| 各 detach listener / handler | `xhci/hotplug_endpoint_handle.rs:106-118`、`port.rs:324-334` | 设备拔出时取消 token，让在途传输立即失败 |

这是一个**共享内存（Guest 内存）+ 消息传递**的混合并发模型：Guest 侧上下文（slot/endpoint context、各 ring）全部放在 Guest 物理内存中，由代码通过 DMA 读写；控制平面全部走 channel。

---

## 3. 分层架构详解

```
cloud-hypervisor  ──vfio-user(UDS, SCM_RIGHTS, eventfd, mmap)──▶  usbvfiod
                                                                    │
                        ┌───────────────────────────────────────────┤
                        │  vfio-user 传输层 (XhciBackend: regions/irqs/DMA)
                        │  PCI 配置空间 + BAR0(xHCI 寄存器) + BAR3(MSI-X)
                        │  xHCI 设备模型
                        │    ├─ 能力/运行/端口寄存器
                        │    ├─ 命令环 + EventRing + Interrupter
                        │    ├─ SlotManager / EndpointWorker(状态机)
                        │    └─ 端口 & 热插拔
                        └───────────────────────────────────────────┤
                                                                    │
                              RealDevice 抽象 (trait)  ──▶  nusb 后端 ──usbfs──▶ Linux USB core ──▶ 物理 USB 设备
```

### 3.1 vfio-user 传输层：`XhciBackend`

`src/xhci_backend.rs` 实现 `vfio_user::ServerBackend`，这是整个设备对外暴露的“硬件接口”：

- **Region 布局**（`regions()`，`xhci_backend.rs:125-196`）：按 `VFIO_PCI_NUM_REGIONS` 枚举，只真正暴露两类：
  - `VFIO_PCI_CONFIG_REGION_INDEX`：256 字节 PCI 配置空间（`:139-153`）；
  - `BAR0..BAR5` 中由 `controller.bar(bar_no)` 报告存在的 BAR，全部 `READ|WRITE`（`:155-187`）。
  - 其它 index 返回空 region。**没有导出任何 migration / device-state region**（见 §6.3）。
- **MMIO 读写**（`region_read`/`region_write`，`:213-312`）：只有 `config` region 和 BAR0（`region == 0`）被实现，其余分支 `todo!()`。BAR 读写被转成 `Request{addr,size}` 交给 `XhciController::read_io/write_io`。
- **DMA 映射**（`:314-340`）：拿到 VMM 传来的 fd 后，用 `MemorySegment` 做 `mmap`，登记进 `DynamicBus`。**没有 fd 的映射直接 `todo!()`**（不支持的路径）。
- **中断**（`set_irqs`，`:355-392`）：只接受 MSI-X（`VFIO_PCI_MSIX_IRQ_INDEX`），且 `count <= 1`；把 eventfd 包装成 `InterruptEventFd` 注入 interrupter。发中断时会先做一次 `SeqCst` fence 再写 8 字节（`:50-65`），保证 Guest 内存修改对 VMM 可见。
- **未实现**：`dma_unmap`、`reset` 都是 `todo!()`（`:342-353`）。

### 3.2 PCI 设备层

`src/device/pci/` 是**可复用的通用 PCI 仿真**（`config_space.rs`、`register_set.rs`、`msix_table.rs`、`traits.rs`），xHCI 控制器只是其中一个用户。

- 控制器身份（`pci/xhci.rs:85-95`）：vendor `0x1b36`（Red Hat）、device `0x000d`（`constants.rs:86-92`）、class/subclass/prog-if = `0x0C / 0x03 / 0x30`（Serial Bus / USB / xHCI，`constants.rs:112-130`）。这是 QEMU 传统 `qemu-xhci` 的 ID，Guest 能直接绑定 `xhci_hcd`。
- BAR：BAR0 = `4 * 0x1000` = 16 KiB（xHCI 寄存器空间）；BAR3 = `2 * 0x1000` = 8 KiB（MSI-X Table + PBA）——注意代码里有 **“TODO Should be a 64-bit BAR”**（`pci/xhci.rs:90-92`）。
- Capability：只挂了一个 **MSI-X** capability（1 个 vector，table 在 BAR3 offset 0，PBA 在 BAR3 offset 0x1000，`pci/xhci.rs:93`）。**没有 MSI，也没有 PCI Power Management capability**（`constants.rs:142-146` 只定义了 MSI / VENDOR_SPECIFIC / MSI_X）。
- `ConfigSpace` 的已知限制：**写配置空间没有副作用**（`config_space.rs:394-398`），只有 `RegisterSet` 的 RO/RW/W1C 语义。这对 PM/suspend 相关寄存器是致命的（见 §6.3）。

### 3.3 xHCI 寄存器与能力

`XhciController::read_io/write_io`（`pci/xhci.rs:121-264`）用大 `match` 把 MMIO 偏移映射到各子模块。关键能力值（`constants.rs:214-323`）：

- `HCIVERSION = 0x100` → **只声明 xHCI 1.0**；
- `HCSPARAMS1`：`MAX_SLOTS = 8`、`MAX_INTRS = 1`、`MAX_PORTS = 8`（4 USB3 + 4 USB2）；
- `HCSPARAMS2`：ERST 最大 `2^15` 段；
- `HCCPARAMS1 = SUPPORTED_PROTOCOLS << 14`：**只设置了 xECP 指针**。这意味着 AC64（64 位寻址）、BNC（带宽协商）、CSZ（64 字节 context）等位都没置位；代码相应地对 `CRCR_HI/DCBAAP_HI/ERSTBA_HI/ERDP_HI` 直接 `assert_eq!(value, 0, "no support for configuration above 4G")`（`pci/xhci.rs:133-156`），**只支持 <4G 的 Guest 物理地址**；
- 扩展能力：两段 USB Supported Protocol，USB3 端口 1–4、USB2 端口 5–8（`constants.rs:303-322`）。

寄存器实现细节：

- `USBCMD`：只接受 `RS | INTE | HCRST`，并特殊处理 HCRST（保持置位直到 `ResetCoordinator` 清掉）（`registers.rs:190-247`）。
- `USBSTS`：**合成值**——HCH 由 RS 取反得到，另外恒定返回 `EINT | PCD`（`registers.rs:249-264`）。
- `PORTSC`：支持 RW1C 位和“假复位”（PR 写 1 直接伪装成功）（`registers.rs:27-125`）。
- `PORTPMSC`/`PORTLI`：存储型寄存器，无 U1/U2 等电源管理语义（`registers.rs:132-144`，`pci/xhci.rs:175-180,250-257`）。
- `MFINDEX`：**恒返回 0**（`pci/xhci.rs:240`）。这是后面 isochronous 结论的关键：没有 125 µs 微帧时基。

### 3.4 命令环与 Slot 管理

- `LinkedRing`（`linked_ring.rs:14-130`）是命令环和传输环共用的环形缓冲抽象：只保存 dequeue pointer + consumer cycle state，其余状态在 Guest 内存；正确实现 cycle bit 判断、Link TRB 跳转与 Toggle Cycle，并对连续 Link TRB 数量设上限（256）防止 Guest 制造死循环。
- `CommandWorker` 状态机 `Stopped/Idle/LookingForNewCommand/ProcessingCommand/Stopping`（`command_ring.rs:62-68,189-288`），支持的命令（`command_ring.rs:305-414`）：No-Op、Enable/Disable Slot、Address Device、Configure Endpoint、Evaluate Context、Reset/Stop Endpoint、Set TR Dequeue Pointer、Reset Device。`ForceHeader` 是 `todo!()`；`Negotiate Bandwidth`、`Get Port Bandwidth`、`Set Latency Tolerance`、`Force Event` 被标记为“可选且不支持”（`trb.rs:404-430`），返回 `TrbError`。
- `SlotManager`（`slot_manager.rs`）：**slot 状态机严格对齐 xHCI 的 Enabled→Default→Addressed→Configured**（`SlotState`，`:401-408`），并在 Guest 内存里同步写 Slot Context 的 state 字段（`:422-435`）。Input Context → Device Context 的拷贝是**字面上的 32 字节 DMA 拷贝**（`:514-532`），不做字段级校验（`check_slot_and_ep0_input_context` 直接 `true`，`:509-512`；Configure Endpoint 也标了 `TODO input checks`，`:561`）。
- `EndpointContext`（`:702-770`）封装了对 Guest 内存中 endpoint context 的访问：读/写 dequeue pointer + cycle state、写 EP state、读 **EP Type**。
- 关键限制：`get_endpoint_type()` 只映射 `2=BulkOut, 6=BulkIn, 4=Control, 7=InterruptIn, 3=InterruptOut`，其余（含 **1=IsochOut、5=IsochIn**）落到 `Unsupported`（`:753-769`）；而 `EndpointType::Unsupported` 在端点启动器里是 `unreachable!`（`endpoint_launcher.rs:220-222`），注释说“slot 应该在 Configure Endpoint 阶段提前拒绝”，但 `handle_configure_endpoint` 实际并没有类型校验——这是一个潜在 panic 点，也是 isoch 的第一处改动点。
- `Evaluate Context` 是**空实现**，只打 warn 然后返回成功（`slot_manager.rs:651-657`）。

### 3.5 端点 worker 与 TRB 处理

每个被配置的 endpoint 由一个独立的 `EndpointWorker` 驱动（`endpoint.rs`）：

- 状态机：`WaitForDoorbell → LookForTrb → WaitForTrbCompletion`，加上 `Halted / Error / Stopped / StoppedWithContinuableTrb / SettingTrDequeuePointer / Terminating`（`endpoint.rs:30-42,100-249`）。
- 它把端点 context 的 dequeue pointer / cycle state 读出来建 `LinkedRing`（`:75-77`），doorbell 后逐条取 TRB，交给下层 `EndpointHandle::submit_trb`，再 `next_completion()`，根据结果 `advance()` 或把 dequeue pointer 回退（Stall/TransactionError 的 TD 聚合场景）、并更新 Guest 内存里的 EP state 和 dequeue pointer。
- 在 `Stop` 时会 `real_endpoint.cancel()`，并把“生成 Stopped/Residual 的 Transfer Event”标为 **TODO**（`endpoint.rs:164-166`）。

**TRB → Host 传输**的三种 handle（`endpoint_handle.rs`）：

1. `ControlEndpointHandle`（`:82-312`）：`ControlRequestParser`（`:314-402`）把 Setup Stage / Data Stage / Status Stage 三个 TRB 拼成一个 `UsbRequest`，然后交给 `RealControlEndpointHandle`；支持 immediate data（但 `length > 8` 是 `todo!()`，`:366`）。
2. `OutEndpointHandle`（`:404-601`）：处理 OUT 方向的 `NormalTrbData`，直接读出 Guest 数据并提交给真实设备；`Isoch` 等其它类型落入 `UnsupportedTrbType` → 返回 `TrbError`（`:481,495-507`）。
3. `TdBasedInEndpointHandle`（`:603-1002`）：IN 方向，会把一个 TD 内多个 Normal/EventData/NoOp TRB **先聚合**，累加长度后做**一次** host IN 传输，再把收到的数据按各 TRB 的 transfer length 顺序拆写回 Guest 内存，并正确处理 short packet 与 IOC/IOS 事件。
   - 明确未完成点：`EventData` 的处理是 `todo!()`（`:853`）。

`HotplugEndpointHandleImpl`（`hotplug_endpoint_handle.rs`）在每个 handle 外面包一层：拔出时把内部 handle 置 `None`，在途 `next_completion` 会立即返回 `TransactionError` 并发出 Transfer Event（`:160-203`），而 `Disconnect` 被映射成 `TransactionError`（`:25-35`）——即“热插拔对端点状态机表现为事务错误”。

### 3.6 真实设备后端：`RealDevice` 抽象 + nusb

`real_device.rs` 定义了后端无关的抽象：

```rust
trait RealDevice {
    type RCEH: RealControlEndpointHandle;
    type RBIEH: RealInEndpointHandle;   // bulk in
    type RBOEH: RealOutEndpointHandle;  // bulk out
    type RIIEH: RealInEndpointHandle;   // interrupt in
    type RIOEH: RealOutEndpointHandle;  // interrupt out
    fn speed(&self) -> Option<Speed>;
    ...
}
```

（`real_device.rs:38-51`）**注意：这里完全没有 isochronous 的端点句柄类型。**

`CompleteRealDevice`（`:72-79`）在 `RealDevice` 上附加了“唯一标识符”和一个 `CancellationToken`（用于拔出时让所有引用同步释放设备）。

nusb 后端（`nusb.rs`）：

- `NusbDeviceWrapper` 在构造时 **claim 该设备的所有 interface**（`detach_and_claim_interface`，`:42-57`），端点按需惰性打开（`NormalEndpointHandle::endpoint()`，`:332-343`）。
- 控制传输用 `device.control_in/control_out`，**超时硬编码 2000 ms**（`:248,265`）。
- bulk/interrupt 用 `Endpoint<Bulk, In/Out>`、`Endpoint<Interrupt, In/Out>`，实现为一个同步“submit 一次 → next_complete 一次”的模型（`:345-422`）。IN 传输的缓冲区大小会向上取整到 max packet size 的整数倍（`:470-476`）。
- 速度从 nusb 转换（`:478-488`）。

这层就是 Q2 的最大瓶颈：**nusb 0.2.7 的 `transfer` 模块只提供 Bulk / Interrupt / Control，没有 Isochronous**（已核对 docs.rs 的 0.2.7 API 列表）。

### 3.7 端口、热插拔与设备身份

- `PortArray` 创建 8 个 port，port 1–4 是 USB3、5–8 是 USB2（`port.rs:95-101`）；每个端口有独立的 `PortscRegister`。
- `PortWorker::attach`（`:176-242`）：若同 identifier 已挂则先摘；按设备实际速度选择同版本的端口；填 PORTSC（USB3 置 CCS|PED|PP|CSC|PEC|PRC|speed；USB2 置 CCS|PLS_POLLING|PP|speed|CSC），并发 **Port Status Change Event**。
- `detach`（`:257-321`）：取消该设备实例的 `detach_token`，`PortWorker` 通过 `DeviceInstanceId`（本质上就是 token 身份）区分不同 attach 生命周期，避免“快速拔插”误摘新设备。
- 热插拔协议（`hotplug_protocol/command.rs`）：3 字节命令 `Attach/Detach/List`，**Attach 时通过 `SCM_RIGHTS` 传递一个已经打开的 USB 设备 fd**（`:20-40,42-63`），因此 usbvfiod 本身不需要打开 `/dev/bus/usb` 的权限。`remote` 二进制是配套客户端（`src/bin/remote.rs`）。
- 设备身份默认用 `(bus, device)` 号（`CompleteRealDeviceImpl<(u8,u8)>`），文档也提醒该方案在“快速 detach/reattach”场景可能指错设备（`slot_manager.rs:449-454`）。

### 3.8 DMA / Guest 内存

- `MemorySegment`（`memory_segment.rs:74-212`）：对 VMM 通过 `DMA_MAP` 传来的 fd 做 `mmap`（区分 RO/RW），访问一律通过 `AtomicU8/16/32/64` 的 `Relaxed` load/store，保证“多字节访问原子”；`read_bulk/write_bulk` 目前走默认逐字节实现（`:211` 有 TODO）。
- `DynamicBus`（`dynamic_bus.rs`）：用 `ArcSwap<Bus>` 支持运行期追加内存段（DMA map 是后到的）；`Bus` 本身是不可变区间表。
- Guest 地址运算全部要求用 `wrapping_add`，以模拟真实控制器的回绕行为（`docs/developers/guidelines.md` 的 “DMA Address Calculations”）。

### 3.9 事件环与中断

- `EventRing`（`event_ring.rs`）：支持 **ERST 多段**，维护 enqueue pointer / 剩余 TRB 数 / segment index / producer cycle state；写满时 `todo!("The Event Ring is full!")`（`:141-143`），即 **未实现 ring-full 恢复**。
- `Interrupter`（`interrupter.rs`）：单 interrupter；未配置事件环前丢弃事件；收到 `ERSTBA` 写才配置事件环；`IMOD` 默认 4000（约 1 ms，`constants.rs:393-396`），但代码只是保存该值，**没有真正做中断节流**，每写一个 event TRB 就发一次 MSI-X。
- 复位时会清 `IMAN/IMOD/ERSTSZ/ERSTBA/ERDP` 并重置事件环（`:224-233`）。

### 3.10 复位协调

`ResetCoordinator`（`controller_reset.rs:25-66`）等待 `USBCMD.HCRST`，然后依次对 **CommandRing、Interrupter、SlotManager** 调用 `ResetSender::reset()`，全部完成后清掉 HCRST。`SlotManager::reset` 会清 `CONFIG/DCBAAP` 并 `pre_drop()` 掉所有 slot（连带 terminate 所有端点 worker、放开 host 侧设备引用）。这是**破坏性全量重置**（见 §6.3）。

### 3.11 可观测性

- `tracing` 日志 + `-v/-vv`。
- 可选 **PCAP** 抓包（`device/pcap/`），使用 Linux USB PCAP link type；为适配，bus 字段被复用为 USB 版本（2/3/0），device 字段复用为 xHCI slot ID（`docs/developers/quick-start.md:95-115`）。isoch 类型的日志被显式标为 TODO（`pcap/packet.rs:37-48`）。

---

## 4. 关键设计决策与取舍

| 决策 | 理由 / 代价 |
|---|---|
| vfio-user 而非 vhost-user / 原生 CH 改动 | 复用现成 VMM 设备框架，CH 改动最小；代价是 vfio-user 在 CH 中仍是 **experimental**，功能子集（见 §5） |
| 每 VM 一个进程 | 隔离、可沙箱化；代价是无多路复用 |
| 状态尽量放 Guest 内存 | 代码“无状态化”，简单；代价是无法序列化/迁移（见 §6.3） |
| worker-per-component + channel | 并发清晰、易测；代价是状态分散在多个 tokio 任务里，难以整体快照 |
| 用 nusb 而非 libusb/裸 usbfs | 纯 Rust、异步、安全；代价是**功能覆盖不足（无 isoch）** |
| 只声明 xHCI 1.0 + 32 字节 context + <4G DMA | 实现简单；代价是能力受限（无 64 位地址、无带宽协商、无 Save/Restore） |
| 单 interrupter / 单 MSI-X vector | 简单；代价是无法多队列/多 vector 中断 |
| 事件环满、未识别 MMIO 等用 `todo!()`/panic | 开发期“快速失败”；README 的稳定性阶段声称已收敛，但仍残留（`event_ring.rs:142`、`pci/xhci.rs:183,261`、`xhci_backend.rs:336,348,352`） |

---

## 5. Q1：这个虚拟控制器是否支持 Cloud Hypervisor？

### 结论

**支持，而且 Cloud Hypervisor 就是它唯一的主目标/官方测试目标。** 对接方式就是 vfio-user 用户态设备（`--user-device`）。

### 证据

1. `README.md:5-10` 开篇即写：“enable USB device passthrough to **Cloud Hypervisor** virtual machines using the vfio-user protocol. Other VMMs might also work, but are currently not the main target.”
2. `docs/developers/architecture.md:9-21` 把“给 CH 加 USB”定义为项目目标。
3. 官方调用方式（`docs/developers/quick-start.md:19-27`）：

   ```console
   $ cloud-hypervisor \
      --memory size=4G,shared=on \
      --serial tty \
      --user-device socket=/tmp/usbvfiod.sock \
      ...
   ```

   注意 **`--memory shared=on`** 是必须的（vfio-user 需要共享内存做 DMA map），且 socket 必须先存在（usbvfiod 先启动，或用 systemd socket activation 以 `--fd 3` 方式传入，`docs/users/systemd.md`）。
4. `src/cli.rs:36-41` 注释直接写明“This is the path where **Cloud Hypervisor** will connect to usbvfiod.”
5. **CI 就是用 Cloud Hypervisor 跑的**：`nix/checks/default.nix:6-37` 加载 `pkgs.cloud-hypervisor`，`nix/checks/testutils.nix:303-323` 启动 `cloud-hypervisor.service` 并传 `--user-device socket=...`；集成测试覆盖 blockdevice / hid keyboard / usb-serial / attach-detach / forceful-removal / controller-reset / interrupt 等（`nix/checks/*.nix`）。
6. 设备对 Guest 呈现为 `1b36:000d` 的 xHCI PCI 控制器（`pci/xhci.rs:88-94`、`constants.rs:79-97`），Guest 用标准 `xhci_hcd` 驱动即可（`docs/developers/quick-start.md:72-90` 甚至给了打开 `xhci_dbg` 的方法）。
7. Cloud Hypervisor 上游文档确认 `--user-device socket=<path>` 的 vfio-user 用法：参见 [Cloud Hypervisor VFIO-user HOWTO](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vfio-user.md)。该文档也说明 **CH 的 vfio-user 支持是 experimental，且 virtio-mem / IOMMU 不支持**。

### 注意事项 / 限制

- **其他 VMM 未作为目标**：项目明确把“支持 CH 之外的 VMM”列为未完成项（`README.md:34-35`）。理论上 QEMU 的 vfio-user 也能对接，但没有官方验证。
- CH 侧 vfio-user 是实验特性，建议使用较新的 CH（文档示例为 `cloud-hypervisor-53.0`，`docs/users/systemd.md:82`）。
- VM 内存需 `shared=on`；usbvfiod 必须先于 CH 就绪（或用 socket activation）。
- 设备地址限制：只支持 32 位 Guest 物理地址（HI 寄存器强制为 0）。

---

## 6. Q2：要提供等时（Isochronous）支持，需要做哪些工作？

### 现状：完全不支持

- `README.md:34` 明确把 “isochronous endpoint support” 列为缺失特性。
- `EndpointContext::get_endpoint_type()` 不识别 Isoch 端点类型（1=IsochOut、5=IsochIn），一律归为 `Unsupported`（`slot_manager.rs:753-769`）。
- `RealDevice` trait 没有 isochronous 端点句柄（`real_device.rs:38-51`）。
- `EndpointType` 枚举没有 Isoch 变体（`slot_manager.rs:772-780`），`EndpointLauncher` 的分发没有 isoch 分支，且 `Unsupported` 分支是 `unreachable!`（`endpoint_launcher.rs:141-223`）。
- TRB 层：`TransferTrbVariant::Isoch` 是一个**无字段的 unit variant**（`trb.rs:825,852`），只识别了类型号 5，**不解析任何 Isoch 字段**。
- 现有 IN/OUT handle 遇到非 Normal/Setup/Data/Status 的 TRB 会返回 `TrbError`（`endpoint_handle.rs:481,495-507,713-720`）。
- PCAP 的 isoch 记录是 TODO（`pcap/packet.rs:37-48`）。
- 后端 nusb 0.2.7 **根本没有 isochronous API**（`transfer` 模块只有 Bulk / Interrupt / Control）。

### 完整工作分解

#### A. 后端（最硬的阻塞点）

1. `nusb` 当前不支持 isochronous 传输。可选路线：
   - **A1**：换/加一个支持 isoch 的后端，例如 `rusb`/libusb（`libusb_transfer` 支持 `LIBUSB_TRANSFER_TYPE_ISOCHRONOUS`，并有 per-packet 的 `iso_packet_desc`），或直接对 usbfs 发 `USBDEVFS_SUBMITURB`（`URB_ISO_ASAP`、`urb.iso_frame_desc[]`）；
   - **A2**：先向上游 `nusb` 补齐 isoch 支持再接入；
   - 无论哪条，`RealDevice` 都要新增 `isoch_in_endpoint_handle` / `isoch_out_endpoint_handle`（`real_device.rs`）。

#### B. 端点类型与上下文

2. `EndpointType` 增加 `IsochIn(5)` / `IsochOut(1)`，`get_endpoint_type()` 正确映射（`slot_manager.rs:753-780`），`EndpointLauncher` 增加分发（`endpoint_launcher.rs:141-223`），并**补上 Configure Endpoint 阶段对不支持类型的显式拒绝**（消除 `unreachable!` 隐患）。
3. 解析并按需使用 Endpoint Context 中 isoch 相关字段：
   - `Interval`、`Mult`、`Max Burst Size`、
   - `Max ESIT Payload Lo/Hi`（USB3 等时端点），
   - USB2 vs USB3 的 interval/微帧语义差异。
   当前 `EndpointContext` 只读 EP Type（`slot_manager.rs:753-769`），其余字段一概没解析。

#### C. TRB / TD 层

4. 实现 **Isoch TRB（type 5）** 的完整解析（xHCI 用这一种 TRB 表达等时传输；注意 not EHCI 的 ITD/siTD）：
   - Data Buffer Pointer、Transfer Length（17 bit）、
   - **TBC**（Transfer Burst Count）、**TLBPC**（Transfer Last Burst Packet Count）、
   - **Frame ID**、**SIA**（Start Isochronous ASAP）、
   - CH / IOC / ISP（Interrupt on Short Packet）等标志。
   目前 `Isoch` 连字段结构体都没有（`trb.rs:807-858`）。
5. 实现 **Isoch TD 组帧**：SIA=1 时按当前微帧 ASAP 出发；SIA=0 时按 Frame ID 延迟到指定微帧；跨 burst 的 per-packet 长度切分。
6. 新增 `IsochEndpointHandle`（IN/OUT），语义上不能复用现有模型：
   - OUT 不能像 `OutEndpointHandle` 那样“一次 Normal TRB = 一次提交”；
   - IN 不能像 `TdBasedInEndpointHandle` 那样“聚合整个 TD 后只做一次 host IN 再回填”，因为 isoch 需要**按包边界、按帧、可同时多个 in-flight** 的流式提交与完成。
7. 完成/错误上报：Isoch 的 Transfer Event 需要报告 residual 与 per-packet 状态；`CompletionCode` 已定义 `MissedServiceError / IsochBufferOverrun / BandwidthOverrunError / RingOverrun / BandwidthError`（`trb.rs:236-274`）但从未产生；还要处理 `EventData`（IN 路径目前 `todo!()`，`endpoint_handle.rs:853`）。

#### D. 周期性调度与时基（架构性改动）

8. 当前实现是**同步请求/响应**模型，没有任何“周期性调度器”概念；`MFINDEX` 恒为 0（`pci/xhci.rs:240`）。等时要求：
   - 增加微帧（125 µs）时基 / 帧计数器，正确实现 `MFINDEX`（含 wrap）；
   - 按 Frame ID 延迟/排队提交；
   - 对 missed service、overrun 的检测与上报；
   - （可选）带宽记账：`Negotiate Bandwidth` / `Get Port Bandwidth` 命令目前被当作不支持（`trb.rs:408-428`），Linux 驱动通常不依赖，但规范上等时带宽协商与之相关。

#### E. 工程与测试

9. PCAP 支持 isoch 事件类型（`pcap/packet.rs:37-48`）。
10. 单元测试：Isoch TRB 解析、TD 组帧、Frame ID/SIA 调度边界。
11. 端到端测试：CI 目前用 QEMU 的 storage/HID/serial（`nix/checks/testutils.nix:357-377`），没有等时设备；需要引入如 `usb-audio` 之类的等时设备（或 gadget）来做真实回环验证。

### 建议的落地顺序

1. 后端能力（A）→ 2. 端点类型/上下文（B）→ 3. Isoch TRB 解析与 TD 组帧（C 的 4/5）→ 4. isoch endpoint handle + 完成上报（C 的 6/7）→ 5. 微帧时基与调度（D）→ 6. PCAP/测试（E）。

其中 **A（后端是否具备 isoch API）和 D（周期性调度模型）是两个真正的架构级缺口**，其余多为增量实现。

---

## 7. Q3：这个虚拟设备支持完全状态和上下文保持的 suspend/resume 吗？

### 结论

**不支持。** 具体来说：

- **不支持 VMM 侧的设备状态保存/恢复（save/restore、快照、live migration）**；
- **不实现 Guest 侧的 PCI 电源管理（PM capability / PMCSR / D0-D3）与 xHCI Save/Restore**，因此不具备规范意义上的挂起/恢复语义；
- **唯一“相关”的行为是 HCRST 复位，而它是破坏性的全量重置**，不是状态保持。

下面分三种语义分别说明。

#### (a) Guest VM S3/系统挂起 + 恢复

- 控制器**没有 PCI Power Management Capability**：配置空间只挂了 MSI-X（`pci/xhci.rs:93`），`capability_id` 只定义了 MSI/VENDOR_SPECIFIC/MSI_X（`constants.rs:142-146`）。xHCI 规范要求 xHC 实现 PCI PM capability；没有它，Guest 的 `xhci-pci` 驱动无法做规范的 D 状态转换，挂起路径上的设备电源管理不会被正确建模。
- 即使 Guest 写配置空间的 PM 寄存器，`ConfigSpace` **写操作没有任何副作用**（`config_space.rs:394-398`），不会被翻译成任何挂起/恢复动作。
- **没有 xHCI Save/Restore 实现**：`HCCPARAMS1` 只设置了 xECP 指针（`constants.rs:299`），代码中不存在任何 save area / 状态保存逻辑，也没有 D3 触发的 save/restore 路径（全仓库搜不到 suspend/save/restore 相关机制）。
- 如果指的是“VMM 暂停 vCPU、usbvfiod 进程继续运行、Guest 恢复后继续用”，那么因为 usbvfiod 是**独立常驻进程**，其内存中的寄存器状态 + Guest 内存中的 ring/context 确实还在——**但这是“没人动它”的副作用，不是实现出来的挂起/恢复机制**：没有任何 quiesce、没有 suspend 通知、在途传输也不做特殊处理。而且只要 vfio-user 连接断开（Guest reboot、CH 重启、`usbvfiod` 被 systemd 重启，见 `docs/users/systemd.md:7-12`），全部状态丢失，Guest 必须重新枚举。
- 相关的负面证据：CI 明确**关闭了宿主机侧的 USB autosuspend**，注释写“currently we can not handle the automatic suspend that is triggered”（`nix/checks/testutils.nix:27-30`，`docs/users/systemd.md:84` 的 `usbcore.autosuspend=-1`）。连 host 侧运行时电源管理都没处理。

#### (b) VMM 驱动的设备状态保存/恢复与迁移

- `regions()` 只导出 **PCI config + BAR**，**没有任何 migration / device-state region**（`xhci_backend.rs:125-196`）。
- `ServerBackend::reset()` 是 `todo!()`，`dma_unmap()` 也是 `todo!()`（`xhci_backend.rs:342-353`）——连 vfio-user 的设备复位/解映射回调都没实现。
- 代码中**没有 serde/序列化**任何控制器状态；状态分散在：`AtomicU32/64` 寄存器、各 tokio worker 的私有状态机、Guest 内存中的 ring/context、以及宿主机上活的 nusb 设备句柄（`Arc<NusbDeviceWrapper>`、打开的 `Endpoint`）。
- 因此 **live migration 在设备层面不可能**：目标主机既拿不到 emulated controller 的完整状态，也无法迁移物理 USB 设备本身。

#### (c) 控制器复位（HCRST）

- `ResetCoordinator`（`controller_reset.rs:25-66`）在 `USBCMD.HCRST` 时依次复位 CommandRing、Interrupter、SlotManager，然后清 HCRST。
- `SlotManager::reset()` 会清 `CONFIG`、`DCBAAP`，并 `pre_drop()` 所有 slot（terminate 所有 EndpointWorker，释放 host 设备引用）（`slot_manager.rs:376-388`）。
- Interrupter 复位清掉事件环配置（`interrupter.rs:224-233`）；CommandRing 停到 `Stopped`（`command_ring.rs:193-197,215-219,235-239`）。
- 集成测试 `nix/checks/controller-reset.nix:11-34` 反复 `modprobe -r/-i xhci_pci` 并验证之后仍能 I/O——它验证的是**Guest 重新初始化后能恢复工作（re-enumeration）**，恰恰说明不是“保持上下文”，而是“推倒重来”。

### 要做到“完全状态保持的 suspend/resume”需要什么

1. **PCI PM capability + PMCSR 语义**：暴露 PM capability，正确处理 D0/D3hot、PME、以及配置空间写的副作用（当前 `ConfigSpace` 支持不了副作用，需要改造 `register_set`/`ConfigSpace`）。
2. **xHCI Save/Restore**：实现进入 D3 时把 xHC 内部状态写入 Guest 内存 save area、恢复时还原（寄存器、interrupter、doorbell、端口状态等）的完整路径，并在 capability 中正确声明。
3. **vfio-user device-state / migration region**：导出一个可读写的设备状态 region，实现状态的 `save`/`load`（序列化所有寄存器、slot/endpoint context 镜像、ring 指针、event ring、端口状态、MSI-X 配置等），并实现 `dma_unmap`、`reset` 等回调。
4. **在途传输的静默与恢复**：挂起前 quiesce 所有端点、记录 dequeue pointer/cycle 与未完成 TD；恢复后重新提交或按规范报 Stopped/residual（当前 `endpoint.rs:165` 还是 TODO）。
5. **宿主设备句柄生命周期**：物理设备状态（配置、interface claim、endpoint toggle）本身不可序列化；迁移场景下目标主机需要一条“重新定位/重挂同一物理设备”的路径（例如热插拔 + `usbpolicyd` 风格的 fd 传递），并在恢复后重新 claim interface、重开端点。
6. **Guest 侧配合**：`Evaluate Context` 目前是空实现（`slot_manager.rs:651-657`），恢复后 Guest 更新 context 必须真正生效。
7. **测试**：需要覆盖 guest S3 挂起/恢复、`virsh`/CH 快照、以及（如果追求迁移）跨主机迁移的集成测试——目前完全没有。

---

## 8. 附录

### 8.1 能力速查表

| 能力 | 状态 | 证据 |
|---|---|---|
| Cloud Hypervisor 对接（vfio-user） | ✅ 主目标 | `README.md:5-10`，`quick-start.md:19-27`，`nix/checks/testutils.nix:315-320` |
| USB 存储 / HID / 串口 直通 | ✅ | `nix/checks/*` |
| Bulk / Interrupt / Control 端点 | ✅ | `endpoint_launcher.rs:141-223`，`nusb.rs` |
| 热插拔（attach/detach/list） | ✅ | `port.rs`，`hotplug_server.rs`，`hotplug_protocol/` |
| 控制器复位（HCRST）后恢复 | ✅（重新初始化） | `controller_reset.rs`，`nix/checks/controller-reset.nix` |
| 等时（isochronous） | ❌ | `README.md:34`，`trb.rs:825`，`slot_manager.rs:753-769`，nusb 无 isoch |
| 64 位 Guest 地址 | ❌ | `constants.rs:299`，`pci/xhci.rs:133-156` |
| 多 interrupter / 多 MSI-X vector | ❌（1/1） | `constants.rs:221`，`xhci_backend.rs:199-210` |
| Streams | ❌ | 未声明；`SetTrDequeuePointer` 解析但无 stream 支持 |
| Evaluate Context | ⚠️ 空实现 | `slot_manager.rs:651-657` |
| Event Ring full 恢复 | ❌ `todo!()` | `event_ring.rs:141-143` |
| PCI PM / D 状态 | ❌ | `pci/xhci.rs:93`，`constants.rs:142-146` |
| 设备状态 save/restore、迁移 | ❌ | `xhci_backend.rs:125-196,342-353` |
| 非 Linux Host | ❌ | `README.md:34` |
| Windows Guest | 🚧 进行中 | `README.md:29-31` |

### 8.2 源码文件地图

| 文件 | 角色 |
|---|---|
| `src/main.rs` | 进程入口、CLI、backend/server 组装 |
| `src/xhci_backend.rs` | vfio-user `ServerBackend`：region/IRQ/DMA |
| `src/cli.rs` | 命令行参数与 socket 处理 |
| `src/device/pci/*` | 通用 PCI 配置空间/BAR/MSI-X/trait |
| `src/device/pci/xhci.rs` | xHCI MMIO 寄存器分发 + PCI 设备描述 |
| `src/device/pci/constants.rs` | PCI/xHCI 全部常量与能力值 |
| `src/device/xhci/command_ring.rs` | 命令环 worker |
| `src/device/xhci/trb.rs` | TRB 类型与解析（命令/传输/事件） |
| `src/device/xhci/linked_ring.rs` | 环缓冲抽象（cycle bit / Link TRB） |
| `src/device/xhci/event_ring.rs` | 事件环（多段 ERST） |
| `src/device/xhci/interrupter.rs` | 中断器与事件发送 |
| `src/device/xhci/slot_manager.rs` | slot/endpoint context 管理 |
| `src/device/xhci/endpoint.rs` | 端点状态机 |
| `src/device/xhci/endpoint_launcher.rs` | 按 EP 类型创建端点 worker |
| `src/device/xhci/endpoint_handle.rs` | TRB → host 传输的核心逻辑 |
| `src/device/xhci/hotplug_endpoint_handle.rs` | 拔出语义包装 |
| `src/device/xhci/real_device.rs` | 真实设备抽象（无 isoch） |
| `src/device/xhci/nusb.rs` | nusb 后端实现 |
| `src/device/xhci/port.rs` | 端口/热插拔/PORTSC |
| `src/device/xhci/controller_reset.rs` | HCRST 复位协调 |
| `src/device/xhci/registers.rs` | USBCMD/USBSTS/PORTSC 等寄存器 |
| `src/device/bus.rs` / `dynamic_bus.rs` / `memory_segment.rs` | DMA/内存总线 |
| `src/hotplug_*` | 热插拔 socket 协议与服务端 |
| `src/bin/remote.rs` | 热插拔客户端 |
| `docs/` | 项目“报告”文档 |
| `nix/checks/*` | 基于 Cloud Hypervisor 的集成测试 |
