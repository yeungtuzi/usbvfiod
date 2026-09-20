# Phase 0 实验 B：Cloud Hypervisor 对 `--user-device`（vfio-user）Live Migration 的支持边界

> 实测日期：2026-09-20
> 被测版本：Cloud Hypervisor `v53.0-520-gc24527002`（Cargo `54.0.0`，上游 main）、usbvfiod `4d2c5af`（v0.3.0）、`vfio_user` crate `0.1.5`
> 关联：`HANDOFF.md` §9 实验 B；`docs/usb-vfiod-live-migration_cn.md` 需求 R7/R8/R11/R14/R16；计划文档 §11"Cloud Hypervisor / rust-vmm 若上游缺 vfio-user migration 支持则提交补丁"

---

## 1. 结论（TL;DR）

1. **CH 当前不支持迁移挂了 `--user-device` 的 VM**，而且**既不支持、也不显式拒绝**：迁移发起后目标端**无限阻塞**，源端 VM 暂停后一直等待，迁移永不收敛、不超时、不报错。
2. 阻塞点可精确定位：目标端重建设备时调用 `vfio_user::Client::new()`，在**版本协商读取服务端应答**时永久阻塞——因为 vfio-user server **只 `accept()` 一个连接**，而该连接仍被源端持有。
3. **即使目标端能连上（socket 空闲），也拿不到设备状态**：CH 对 vfio-user 设备的 `Pausable`/`Migratable` 是空实现，`VfioCommon::snapshot()` 只含 PCI config / INTx / MSI / MSI-X，**不含** BAR/MMIO 寄存器、不透明设备状态、DMA dirty page。
4. 因此 Phase 0 判定：要让 R7/R8/R16 落地，**必须三方改动**——CH、`vfio-user` crate、usbvfiod，无法只靠 usbvfiod 单侧实现。

---

## 2. 实验方法（可复现）

复现脚本（随仓库）：[`scripts/phase0/exp-b-migrate-test.sh`](../scripts/phase0/exp-b-migrate-test.sh)，用法 `exp-b-migrate-test.sh <control|userdev>`；二进制与镜像路径可用环境变量 `CH` / `CHR` / `USBVF` / `IMG` 覆盖。
Guest：Debian trixie netboot `linux` + `initrd.gz`（12 MB / 39 MB，默认放 `/root/lvllm/images/`）

- 源端：
  `cloud-hypervisor -v --api-socket src.sock --memory size=512M,shared=on --cpus boot=1 --kernel images/linux --initramfs images/initrd.gz --cmdline "console=ttyS0" --serial file=src-console.log --console off [--user-device socket=…/usbvfiod.sock]`
- 目标端：`cloud-hypervisor -v --api-socket dst.sock`
- 接收：`ch-remote --api-socket dst.sock receive-migration receiver_url=unix:…/mig.sock`
- 发送：`ch-remote --api-socket src.sock send-migration destination_url=unix:…/mig.sock,memory_mode=memfds,downtime_ms=300,timeout_strategy=cancel`

> 该实验**不需要真实 USB 设备**：usbvfiod 即使不挂任何物理设备，也会导出一块虚拟 xHCI 控制器。

### 2.1 对照组（control，无 user-device）——通过

`send-migration` 退出码 0；源端进程退出；目标端 `state=Running`，配置与设备树与源端一致。说明**测试环境本身可用**，后续失败与 CH 基础迁移能力无关。

### 2.2 实验组（userdev，挂 usbvfiod）——失败（挂起）

`send-migration` 同样立即返回 0（异步），随后目标端在重建 `_vfio_user0` 时卡死。

---

## 3. 失败根因链（实测证据 + 代码定位）

### 3.1 实测时序（`dst.log` / `src.log` / `usbvfiod.log`）

| 时刻 | 端 | 事件 |
|---|---|---|
| t=2.019s | dst | `vm.rs:607 Booting VM from config`，配置里带 `user_devices: [UserDeviceConfig { id: Some("_vfio_user0"), socket: "…/usbvfiod.sock" }]` |
| t=2.024s | dst | `device_manager.rs:4749 Restoring virtio-pci _vfio_user0 resources` |
| t≈2.03–202s | dst | **199.9 秒无任何新日志**（无进度、无错误、`ch-remote info` 也不响应） |
| t=8.03s | src | `pausing → paused → snapshotting → snapshotted`，此后一直停在此状态 |
| 全程 | usbvfiod | 只收到 **1 次** `Received client version`（来自源端） |
| — | host | `ss -x` 显示 `usbvfiod.sock` 的 LISTEN 队列 **`Recv-Q=1`**：目标端的连接已建立但从未被 accept |

> ⚠️ 注意：`dst.log` 里那条 `Migration aborted … Failed to receive migratable component snapshot` 是**我们在测试超时后 kill 掉进程**才产生的，**不是 CH 自行报错**。稳定态是**无限挂起**（`timeout_strategy=cancel` 也没有挽救/回滚，源端只是停在暂停态）。

### 3.2 代码路径

| 层 | 位置 | 行为 |
|---|---|---|
| CH | `vmm/src/device_manager.rs:4304 add_vfio_user_device()` | 重建目标端设备 |
| CH | `:4317 pci_resources()` → `:4749` 日志 | 打印 "Restoring virtio-pci _vfio_user0 resources" |
| CH | **`:4338-4341`** `vfio_user::Client::new(&device_cfg.socket)` | 连接源端配置里的**同一个** socket |
| crate | `vfio_user-0.1.5/src/lib.rs:317-333 Client::new()` | `UnixStream::connect()` → `negotiate_version()` |
| crate | **`:373-375`** `self.stream.read_exact(server_version.as_mut_slice())` | **永久阻塞**，等待服务端版本应答 |
| crate | **`:1393-1394`** `Server::run()`：`let (mut stream, _) = self.listener.accept()?;` | **只 accept 一次**，服务完当前 client 才返回 |
| usbvfiod | `src/main.rs:65` `Server::new(socket_path, true, …)` | 单连接服务模型 |

**结论**：源端持有唯一连接 → 目标端 `connect()` 进 backlog 成功但无人 `accept` → 目标端读应答永久阻塞 → 迁移无法收敛。这不是竞态或超时问题，而是**架构性的单连接 + 无迁移协议**。

---

## 4. 静态分析：即便连接成功，状态也会丢

- **迁移钩子全是空实现**：`pci/src/vfio_user.rs:533`（`Pausable`）、`:549`（`Transportable`）、`:550`（`Migratable`）——均为 `{}`，走默认 no-op（`vm-migration/src/lib.rs:118-128, 286-305`）。
  对比内核 VFIO：`pci/src/vfio.rs:2559-2563` 有 `"VFIO device does not support migration"` 的显式检查；vfio-user 路径**没有对应检查**。
- **snapshot 内容**：`pci/src/vfio_user.rs:535-548` 只保存 `self.common`；`pci/src/vfio.rs:1866-1894` 中设备迁移 blob 仅当 `migration_flags.is_some()` 才保存，而 `VfioUserClientWrapper`（`pci/src/vfio_user.rs:300-396`）从不覆写 `migration_flags`（默认 `Ok(None)`，`pci/src/vfio.rs:511-513`）。
- **会丢**：BAR/MMIO 寄存器（xHCI operational/port 寄存器、event ring dequeue pointer 等）、不透明设备状态、DMA dirty page、外部 vfio-user server 的进程状态。
  **会传**：PCI config shadow、INTx 使能、MSI/MSI-X 配置 + MSI-X table/PBA（`pci/src/msix.rs:69-74`）。
- **没有"目标端 server"参数**：`vmm/src/api/mod.rs:370-376` 的 `receive-migration` 只接受 `receiver_url / tls_dir / vfio_fds / iommufd_fd / zone_updates`；`UserDeviceConfig.socket`（`vmm/src/vm_config.rs:828-832`）随 snapshot 配置**原样序列化**，目标端只能连同一个宿主路径。因此"目标端另起一个 server"也无法自然绕过。
- **crate 无迁移协议**：`vfio_user-0.1.5/src/lib.rs:34-51` 的 `Command` 枚举没有 migration/device-state 命令；`DmaRead/DmaWrite/UserDirtyPages/GetRegionIoFds` 直接返回 `UnsupportedCommand`（`:933-940`）。Version 里的 `MigrationCapabilities { pgsize }` 只是页大小提示，无消费者。
- **usbvfiod 无 device-state region**：`src/xhci_backend.rs:126-196` 只处理 CONFIG + BAR0–5，其余索引记为 `"unknown VFIO region"` 并返回空 region；`reset()` 是 `todo!()`（`:351-353`），`dma_unmap` 是 `todo!()`（`:344-348`）。

---

## 5. 附带发现：`vfio_user` 0.1.5 的 `resettable` 解析疑似取反

`vfio_user-0.1.5/src/lib.rs:517`：

```rust
self.resettable = reply.flags & VFIO_DEVICE_FLAGS_RESET != VFIO_DEVICE_FLAGS_RESET;
```

服务端（`:1106-1111`）在 `self.resettable == true` 时**置位** `VFIO_DEVICE_FLAGS_RESET`。于是上面的表达式在"服务端支持 reset"时恒为 `false`（应为 `==`）。

usbvfiod 传 `resettable = true`（`src/main.rs:65`），所以 CH 认为设备**不可 reset**，不会调用 `client.reset()`（`pci/src/vfio_user.rs:94-101`）。当前效果是**避免了 usbvfiod `reset()` 的 `todo!()` panic**，但语义是错的；一旦上游修掉这个 bug，重连路径就会踩到 `todo!()`。

---

## 6. 对 HANDOFF §9 实验 B 问题的回答

| 问题 | 实测/代码答案 |
|---|---|
| CH 是否支持 `--user-device` 迁移？ | **否**。既不支持也不拒绝；实测**无限挂起** |
| 若不支持，失败点在哪？ | 目标端 `device_manager.rs:4338-4341` → `Client::new` → `negotiate_version` → `read_exact`（crate `:373-375`）；根因是 server 单 `accept()`（crate `:1393-1394`）+ 源端仍持连接 |
| 能否用"目标端另起 server"绕过？ | 不能。socket 路径随配置固定；且即便连上也是**全新设备**，状态丢失 |
| vfio-user 协议层是否有迁移能力？ | crate 0.1.5 **完全没有**；device-state / migration region 未实现 |
| 需要改哪里？ | **CH**：`VfioUserClientWrapper` 实现 `migration_flags`/state/read-write-migration-data/DMA logging，`VfioUserPciDevice` 实现 `Pausable`/`Migratable`/扩展 `Snapshottable`，receive-migration 增加目标端 server 参数<br>**vfio-user crate**：device-state / migration region、dirty-page 协议、`ServerBackend` 状态钩子<br>**usbvfiod**：暴露 state region、实现导入导出、`reset()` |

---

## 7. 影响与建议

- R7（VMM 主动迁移）与 R16（失败回滚）在**当前上游 CH 上无法直接落地**，必须先做 CH / rust-vmm 补丁——与计划文档 §11 的预判一致。
- 短期同主机场景建议走计划中的**降级路径**：本地状态文件 + `usbdev-agent` 重绑定（R11/R14）。
- ⚠️ 本次实测中 `timeout_strategy=cancel` **并未**表现为"失败后源端继续运行"：源端在约 200 s 内一直停在 `paused/migrating`，需要单独验证其可恢复性（这正是 R16 的核心假设，值得作为下一个实验）。
- 建议的**对照 2**：让目标端 socket 指向**另一个空闲的 vfio-user server**，以隔离出"连接成功但状态丢失"的分支，量化纯状态丢失的行为。

---

## 8. 未决 / 不确定

1. 上游 vfio-user 规范中 device-state / migration region 的具体 ID 未取得（网络超时），不影响 crate/CH 层结论。
2. usbvfiod `reset()` 为 `todo!()`，本次未触发（见 §5）；修复 crate bug 后需补实现。
3. 同主机 **snapshot/restore**（非 migration）可能因 usbvfiod 进程存活而"看起来可用"，本次未测，建议单独实验。
