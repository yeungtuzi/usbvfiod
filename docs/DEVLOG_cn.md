# 开发日志（DEVLOG）

> 项目：usbvfiod USB 存储直通「同主机 Cloud Hypervisor live migration」演示
> 约定：**重要改动前先 commit**；每次「得/失/回退」都记入本文件；结论必须带可复现证据（命令、日志、文件行号）。

本文件按时间顺序记录。每条包含：**目标 → 改动 → 结果（得/失）→ 回退 → 后续**。

---

## D0. 环境与权限盘点（2026-09-19/20）

**目标**：确认新开发机是否具备跑 CH + usbvfiod + KVM + usbfs 的权限。

**结论（得）**
| 项 | 结果 |
|---|---|
| 身份 | `uid=0(root)`，`CapEff=0x1ffffffffff`（全 capability） |
| 宿主 | Debian 13 / Proxmox `pve` kernel `6.17.4-2-pve`，8 vCPU / 62 GiB，运行 4 台 KVM VM（100/101/102/103） |
| `/dev/kvm` | 存在；`KVM_GET_API_VERSION=12`；`KVM_CREATE_VM` 成功 |
| usbfs | `/dev/bus/usb/*` 全部可 `O_RDWR`，`USBDEVFS_GET_CAPABILITIES=0x1fd` |
| vfio | `/dev/vfio/vfio`、`/dev/vfio/13` 可用 |
| 网络 | rustup / crates.io / GitHub 可达（GitHub 偶发超时） |

**失**
- 起始 DSH 处于 `workspace-write` 沙箱：`/dev` 是只读最小 devtmpfs，**看不到 kvm/usb 节点**，`/var` 只读导致 apt 全废。切换到 `danger-full-access` 后恢复正常。
- `cargo deny check`（advisories 部分）因克隆 RustSec advisory-db 超时失败；`licenses/bans/sources` 通过。

**后续**：安装工具链（Rust 1.98.1 + clippy/rustfmt、gcc 14、pkg-config、libssl/libseccomp、cargo-deny、cargo-nextest、gh 2.101.0）。

---

## D1. 代码基线与 Phase 0 实验 B（2026-09-20）

**目标**：建立可编译基线；实测 CH 对 `--user-device`（vfio-user）迁移的支持边界。

**得**
- usbvfiod `4d2c5af`：`cargo build` ✅、`cargo test` **109 passed** ✅、`fmt` ✅、`deny(licenses/bans/sources)` ✅。
- Cloud Hypervisor 上游克隆并构建：`v53.0-520-gc24527002`（Cargo `54.0.0`）。
- 对照实验（无 user-device）迁移**成功**：源端退出、目标端 `state=Running`。

**失（重要）**：挂了 `--user-device` 的迁移**死锁**，不是报错：
- 目标端 `dst.log` 停在 `device_manager.rs:4749 Restoring virtio-pci _vfio_user0 resources`，随后 **199.9 s 零进展**。
- 根因链：`vmm/src/device_manager.rs:4338-4341 vfio_user::Client::new()` → crate `negotiate_version()` → `read_exact`（`vfio_user-0.1.5/src/lib.rs:373-375`）永久阻塞；因为 `Server::run()` 只 `accept()` 一次（crate `:1393-1394`），而连接被源端持有。
- usbvfiod 全程只收到 **1 次** client version 握手；`ss -x` 显示监听队列 `Recv-Q=1`（目标端连接无人 accept）。
- 静态分析补充：`VfioUserPciDevice` 的 `Pausable`/`Migratable` 是空实现，`snapshot()` 只含 PCI config/INTx/MSI/MSI-X，**没有** BAR/设备状态/DMA dirty。
- 附带发现：crate `lib.rs:517` 的 `resettable` 解析取反（`!=` 应为 `==`）；usbvfiod 传 `true` 时 CH 反而认为不可 reset，恰好避开了 `reset() todo!()`。
- R16 反例：`timeout_strategy=cancel` **并未**让源端继续运行，源端停在 `paused/migrating` 约 200 s。

**产物**：`docs/phase0-exp-b-ch-vfio-user-migration_cn.md`、`scripts/phase0/exp-b-migrate-test.sh`（提交 `cf611b9`）。

---

## D2. Demo 方案细化（2026-09-20）

**目标**：把 5 步演示叙事（插盘 → Guest 挂载复制 → 迁移 → 继续复制）落成可判定方案。

**得**：`docs/demo-usb-storage-live-migration-plan_cn.md`
- 每步的可观测证据 + 硬/软验收指标（CSC/PRC=0、无 reset、`lsusb -v` diff 空、md5 一致；允许 ≤1 次 SCSI 重试）。
- 关键判据：`usb-storage` **reset** 或端口 PRC = 直接失败；SCSI 重试 = 允许。
- 载荷前提核实：CH `docs/live_migration.md:337-342` 明确 `memory_mode=memfds` 传的是 Guest 内存 **backing fd**，源/目标 mmap 同一份共享内存。
- 范围确认：**同主机**；跨主机仅 §11 展望（C1 device-state region / C2 USB/IP / C3 virtio-usb / C4 热拔插），本期不实现。

**修订主计划**：R7 拆为 R7a（同主机）/R7b（跨主机）；关闭「CH 支持度」未知；标注 R16 反例。

---

## D3. Guest 可启动镜像（2026-09-20）

**目标**：用宿主上的 Ubuntu 22.04.4 live-server ISO 造出可跑 demo 的 Guest。

**失 → 得（三连踩坑，全部记录）**
1. **失**：直接 `--kernel casper/vmlinuz --initramfs casper/initrd --disk rootfs.img` → `ImageTypeRequired`。**得**：加 `image_type=raw`。
2. **失**：启动后报 `Unable to find a medium containing a live file system`。**因**：casper 通过 `casper/initrd` 的 `conf/conf.d/{casperize,default-boot-to-casper}.conf` 劫持启动，无视 `root=`。**得**：重建 initramfs 去掉这两个 conf 与 casper 脚本，标准 initramfs-tools init 正常挂 `root=/dev/vda`。
3. **失**：minimal squashfs 的 `/lib/modules` **是空的**（模块在 initrd 里），切 root 后 `usb-storage` 无法加载。**得**：`unmkinitramfs` 拆出 initrd 的 `main` 段，把 `5.15.0-94-generic` 模块树（1561 个 .ko）graft 进 rootfs。

**得（验证）**：Guest 启动到 `root@demo-guest:~#`（串口 autologin），`modprobe usb-storage: OK`、`modprobe uas: OK`；挂 usbvfiod 后 Guest 内 `xhci_hcd 0000:00:03.0` 枚举、`lsusb` 出现两个 root hub。

**产物**：`guest/build-guest.sh`、`guest/README.md`、`guest/.gitignore`（多 GB 产物忽略；提交 `11601b8`）。

---

## D4. 真机 USB 直通与 harness（2026-09-20）

**目标**：接入真实 U 盘，打通 demo Step 1–2 并建立可脚本化的 Guest 控制通道。

**设备事实**：Innostor `1f75:0903`，路径 `1-7`，**32 GB**（非用户所说 16 GB），exfat 卷标 `刘湛渊-U盘-32GB` + `VTOYEFI`（Ventoy 启动盘，数据分区为空）。

**得**
- usbvfiod `detach_and_claim_interface` 抢占成功：宿主驱动 `usb-storage` → `usbfs`，`/dev/sdb` 从宿主消失；Guest 内出现 `/dev/sda`（29.8G，sda1 exfat + sda2 vfat）。
- Guest 内 `mount -t exfat -o ro /dev/sda1 /mnt/usb` → `MOUNT_OK`。
- Guest 内写入 1 GiB `testfile.bin`（md5 `0fc3e7df554fcfd9165d70586ef45bb6`），重新挂到宿主校验 md5 **一致**（持久化确认）。
- **未破坏 Ventoy**（选择补模块而非格式化）。

**失 → 得**
- **失**：Guest 无 `exfat` 模块（initrd 只带启动必需模块），挂载失败。**得**：下载 `linux-modules-extra-5.15.0-94-generic_5.15.0-94.104`，合并进 rootfs（模块 1561 → 5394），`depmod` 重建索引。
- **失**：用 `pkill -f 'cloud-hypervisor --api-socket /run/guest.sock'` **误杀了自己的 shell**（模式匹配到自身命令行）。**得**：改用 pidfile 管理的 `demo-guest.sh`，彻底移除 pkill。
- **失**：harness sentinel 用 `<<<RC0>>>`，bash 把 `<` 当重定向 → `syntax error near unexpected token '>'`。**得**：sentinel 改为运行时拼接 `echo "__RC""0""__$?"`，既避开 shell 特殊字符，又避免匹配到回显。
- **失**：`findmnt -o TARGET` 把中文路径转义成 `\xe5...`，导致 umount/路径失败。**得**：改用 shell glob `/media/root/*/` 绕开转义。

**宿主配置（最小侵入，已验证不影响运行中 VM）**
- 仅对目标设备 `power/control=on`（**未动全局 autosuspend**）。
- 写入 `/etc/modprobe.d/usbvfiod.conf`、`/etc/udev/rules.d/70-usbvfiod.rules`（仅 `--reload-rules`，**未 trigger 设备**）、建 `/run/usbvfiod`。
- 证据：改动前后 `qm list` 的 4 台 VM **PID 完全相同**（3220/2188/2299/4021624）。

**产物**：`guest/demo-guest.sh`、`guest/guest-exec.py`、`guest/build-guest.sh`（extras 步骤）、`guest/README.md`（提交 `ae63f63`）。
**Fork**：`yeungtuzi/{usbvfiod, cloud-hypervisor, vfio-user}` 全部就绪。

---

## D5. 迁移握手方案选型（转折点，2026-09-20）

**目标**：找到让「目标端 CH 能接上 usbvfiod」的最小改动路径。

**候选**
| 方案 | 思路 | 改动面 |
|---|---|---|
| A. vfio-user 客户端 fd 交接 | 源 CH 把已建立的连接 fd 经 SCM_RIGHTS 交目标 CH | `vfio-user` crate + CH + 新增导出/传递通道 |
| **B. usbvfiod 多客户端共享 backend** | usbvfiod 并发 accept 多个连接，handshake 不需要 backend，I/O 命令按次加锁 | **仅 usbvfiod**（+ 可选 crate 小改） |

**决定性证据（读 crate 源码）**：`vfio_user-0.1.5/src/lib.rs` 中只有
`DmaMap(:1020)`、`DmaUnmap(:1054)`、`SetIrqs(:1269)`、`RegionRead(:1308)`、`RegionWrite(:1346)`、`DeviceReset(:1371)` 会调用 `backend`；
而 `Version(:941)`、`DeviceGetInfo(:1083)`、`DeviceGetRegionInfo(:1119)`、`GetIrqInfo(:1216)` **完全不碰 backend**。

**推论**：只要 backend 用「每次方法调用加锁」的包装（而不是整条连接持有锁），目标端的 `Client::new`（= Version + DeviceGetInfo + GetRegionInfo）就能在**源端仍连接**时完成，死锁消失；且 backend 状态（xHCI 寄存器、端点）天然保留，Guest RAM 因 `memfds` 是同一份，DMA 映射继续有效。

**选择**：**优先方案 B**——改动小、不碰 CH、不需要 fd 传递。方案 A 退为备选（若 B 在实测中暴露多客户端语义问题）。

**已知风险（待实测）**
1. 两个客户端并发时可能交错发 I/O 命令；迁移窗口内源端已 paused，实际并发窗口很小。
2. IRQ eventfd 切换窗口可能丢中断（对应 D1.2 闩锁）。
3. `reset()`/`dma_unmap()` 仍是 `todo!()`，需实现以避免 panic。

**后续**：实现 `SharedBackend` + 多线程 accept，重跑实验 B 验证死锁消失。

---

## D6. 多客户端实现与实测（2026-09-20）——死锁已消除

**目标**：实现方案 B 并验证迁移死锁消失。

**实现**（提交 `575c759`）
- `src/shared_backend.rs`（新增）：`SharedBackend<CRD>` 包装 `Arc<Mutex<XhciBackend<CRD>>>`，`ServerBackend` 的每个方法**按次加锁**，握手命令不经过 backend。
- `src/main.rs`：新增 `run_multi_client`；起 N 个线程，各自循环 `server.run(&mut SharedBackend)`。
- `src/cli.rs`：新增 `--max-clients`（默认 1 = 完全保留原行为）。
- `src/dynamic_bus.rs`：`add` 改为同址幂等（同 `start_addr` 替换；异址重叠仍报错）；新增 `remove_range`；失败不再污染 bus 状态。
- `src/xhci_backend.rs`：`dma_map` 改用 `add` 并返回 `io::Error`（不再 `unwrap`）；**实现 `dma_unmap`**（CH 拆除设备时会调用，原为 `todo!()`）；`reset()` 明确返回错误而非 `todo!()`。
- `Server::new(..., resettable = false, ...)`。

**得（实测，实验 B userdev）**
```
Migration completed after 0.0s with a downtime of 13ms (goal was 300ms)
event = migration-receive-finished → resumed
RESULT: mode=userdev send_rc=0 outcome=migrated
```
- **死锁消失**（此前：目标端卡在 `Restoring virtio-pci _vfio_user0 resources`，199.9 s 零进展）。
- usbvfiod 收到**两次** client version 握手（源端 + 目标端），源端断开后 `vfio-user client disconnected, accepting the next one`。
- `cargo test` **112 passed**（新增 3 个 DynamicBus 测试）；`clippy --deny warnings` clean。

**失**
- 日志出现 `Error handling command: 13`（命令 13 = `DeviceReset`）。原因：`resettable` 的解析在 **Client 侧（即 CH）**，我把 `resettable` 从 `true` 改为 `false` 后，crate 的取反 bug 反而让 CH 认为"设备可 reset"，于是**每次连接**都发 `VFIO_USER_DEVICE_RESET`（迁移时源端、目标端各一次）。
- **回退记录**：先误把 crate 补丁加到 usbvfiod（usbvfiod 只用 `Server`，根本不需要）→ 无效果；且 `vfio_user` 通过 **path** 依赖 monorepo 内的 `vfio-bindings`，导致同一 crate 出现两个来源（crates.io + git），编译报 3 处 E0308 类型不匹配。**已回退 usbvfiod 的 `Cargo.toml`/`Cargo.lock`**。
- 正确做法：patch **CH**（Client 在 CH 内），并同时 patch `vfio-bindings` 到同一 git 源以统一类型。

**发现（影响 PR 目标仓库）**：`rust-vmm/vfio-user` 已于 **2025-05-19 归档**，代码迁至 **`rust-vmm/vfio`** 单仓，其中 `vfio-user/` 子目录即 `vfio_user 0.1.5`。已 fork `yeungtuzi/vfio`，修复并推送分支 **`fix/resettable-flag-parsing`**（commit `3a645f8`）。

**网络（重要，已记录）**：本机访问外网（GitHub / Google / HuggingFace）需代理
`socks5h://192.168.100.4:1080`。已写入全局 git 配置（`http.proxy` / `https.proxy`），**对所有项目生效**。

**后续**：用 patch 后的 CH 复测，确认 `DeviceReset` 错误消失；然后进入真实 demo（U 盘 + Guest 内文件复制 + 迁移 + 校验）。

---

## D7. 真实 demo 打通（2026-09-20）—— 成功

**目标**：U 盘直通 + Guest 内 128 MiB 文件复制 + 同主机 live migration + 完整性校验。

**结果（权威证据来自 Guest 自己的 `/root/demo.log`）**
```
migration line       : Migration completed after 0.0s with a downtime of 4ms (goal was 300ms)
COPY_START           : 1789880056.772
COPY_DONE            : 1789880069.733   rc=0
copy duration        : 13.0 s
spans migration      : YES   (start < migration epoch < end)
expected (host)      : d62dd28c4faf1bbe19e300a3b605e503
read back from stick : d62dd28c4faf1bbe19e300a3b605e503
copied file          : d62dd28c4faf1bbe19e300a3b605e503
MD5 VERDICT          : MATCH
```
- Guest 复制 **128 MiB** 期间发生迁移，复制**跨越**迁移且**数据完全一致**。
- 控制台 USB 事件：两次 `new high-speed USB device` **均在 guest uptime `[1.99s]`（开机枚举）**；迁移后**无任何 usb/xhci/sd 消息** → 无重枚举、无 reset、无 I/O error。

**排查过程中的得失（逐步记录）**

1. **失**：首次 demo 失败 —— 复制 17 MB 后 Guest 报
   `xhci_hcd 0000:00:03.0: xHCI host controller not responding, assume dead` + `dd: Input/output error`。
   **根因**：usbvfiod 日志显示，**目标端注册 IRQ 之后**、正在退出的源端 CH 又发了 `SetIrqs #fds: 0`（关闭），把共享 backend 的中断线覆盖成 dummy。
   **得**：`SharedBackendState` 引入 **IRQ 归属者（owner）** 语义——只有最近注册中断的连接才能下发破坏性命令（`SetIrqs` 无 fd / `DmaUnmap`），陈旧客户端的拆除被 `WARN` 记录并忽略（提交 `becc84f`）。

2. **失**：修复后现象不变，且日志里看不到"忽略陈旧 IRQ"。
   **根因**：我只跑了 `cargo clippy` / `cargo test`，**没有 `cargo build`**，`target/debug/usbvfiod` 仍是旧二进制（12:28 vs 12:40）。
   **得**：确立"改完源码必须重建二进制再验证"的流程。

3. **失**：修复并重建后复制仍像"停住"。
   **根因**：Guest 把日志写到 `/dev/ttyS0`；迁移会**重建目标端串口设备**导致 Guest tty 重置，dd 的进度写入失败，看起来像卡死。
   **得**：Guest 侧改为**文件为主（`/root/demo.log`）+ 串口尽力镜像**；宿主侧改为**挂载 Guest 镜像读取 Guest 自己的日志**作为权威判据。

4. **失**：挂载镜像读到的是**过期数据**（md5 行丢失、心跳仅 7 条），一度误判为"Guest 冻结"。
   **根因**：VM 被强杀后 ext4 需要日志恢复，而我用了 `-o ro,noload`，**跳过 journal 回放**，看到的是最后一个 checkpoint。
   **得**：改用 `mount -o loop`（rw）回放 journal；Guest 侧在 md5 后再 `sync`。
   **反证**：用串口直接交互探测 Guest，返回 `up 1 min`、心跳 #44、`testfile.copy` 128 MiB、日志 3552 字节——**Guest 全程健康**，之前的"冻结"是观测假象。

5. **得（决定性线索）**：pcap 分析显示迁移后 +8..+18 s 仍以 **~1400 包/秒**传输，证明**迁移后 USB 数据面正常工作**，从而把故障面锁定在"串口/观测"而非 USB 通路。

**仍未消除的 Guest 可见扰动（如实记录）**：迁移后 Guest 串口控制台会**重印登录横幅**（目标端重建串口设备导致 tty 重置）。这是 CH 串口设备的行为，与 USB 通路无关；若要"完全零感知"，需在 CH 侧保留串口设备实例。

**产物**
- `guest/usb-migration-demo.sh`：一键端到端 demo（迁移 + 权威校验）
- `guest/fifo-capture.py`：FIFO 常驻捕获（避免目标端 `File::create` 截断迁移前日志）
- `guest/testfile.md5`：期望校验值
- 提交：见 D7 之后的 commit

---

## D8. 间歇性缺陷：交接窗口丢失中断（2026-09-20）—— 已修复并稳定

**现象**：D7 的 4 次成功之后，第 5 次**失败**——复制在迁移点（pcap 显示 +8 s）戛然而止：
- USB 传输速率从 ~1400 包/秒**掉到 0**，此后长时间为 0；
- Guest **仍然存活**（心跳继续到 uptime 127 s）；
- Guest 每 ~30 s 发一次 `ResetDevice`，usbvfiod 记录
  `ResetDevice in state Default(...) is treated as ContextStateError`（xHCI 规范行为），恢复失败。

**根因**：`interrupter.rs:206` 对每个事件调用 `interrupt_line.interrupt()`。迁移时目标端**稍后**才注册自己的中断线；在"旧线仍生效"的窗口内完成的传输，其**完成事件已写入 Guest 事件环（Guest RAM）**，但**中断打到了即将退出的源端 eventfd**，永久丢失 → Guest 不再扫描事件环 → 复制卡死。这是**时序相关**的窗口缺陷，所以表现为间歇性。

**修复**（提交 `abecad6`）：在新客户端注册 IRQ、安装好新中断线之后，**主动补发一次"踢"中断**，让 Guest 重新扫描事件环，捡回那些完成事件。多余的一次 MSI-X 中断无害（Guest 发现没有新事件即返回）。

**验证**：修复后**连续 5/5 通过**：

| 试验 | 停机 | 复制时长 | 跨越迁移 | MD5 | 迁移后重枚举 |
|---|---|---|---|---|---|
| 1 | 17 ms | 20.6 s | YES | MATCH | 0 |
| 2 | 18 ms | 30.2 s | YES | MATCH | 0 |
| 3 | 15 ms | 33.9 s | YES | MATCH | 0 |
| 4 | 17 ms | 33.5 s | YES | MATCH | 0 |
| 5 | 15 ms | 35.3 s | YES | MATCH | 0 |

**教训（写入流程）**：
1. 这类"交接窗口"缺陷是**时序相关**的，**单次通过不能作为验收依据**，必须重复试验（本 demo 采用 5 次）。
2. 观测通道本身必须可靠，否则会把"观测断裂"误判为"功能失败"（D7 的串口与 `noload` 两次误判）。
3. 修复后必须**重建二进制**再验证（D7 的教训）。

---

## D9. 验收完成与上游 PR（2026-09-20）

**修复后连续 10/10 通过**（验收标准 N=10 达成）：

| # | 停机 | 复制时长 | 跨越迁移 | MD5 | 迁移后重枚举 |
|---|---|---|---|---|---|
| 1 | 17 ms | 20.6 s | YES | MATCH | 0 |
| 2 | 18 ms | 30.2 s | YES | MATCH | 0 |
| 3 | 15 ms | 33.9 s | YES | MATCH | 0 |
| 4 | 17 ms | 33.5 s | YES | MATCH | 0 |
| 5 | 15 ms | 35.3 s | YES | MATCH | 0 |
| 6 | 16 ms | 32.4 s | YES | MATCH | 0 |
| 7 | 4 ms | 28.4 s | YES | MATCH | 0 |
| 8 | 4 ms | 13.2 s | YES | MATCH | 0 |
| 9 | 6 ms | 15.0 s | YES | MATCH | 0 |
| 10 | 17 ms | 52.4 s | YES | MATCH | 0 |

**上游 PR（草稿，未提交合并）**
| PR | 内容 | 分支 |
|---|---|---|
| [cyberus-technology/usbvfiod#316](https://github.com/cyberus-technology/usbvfiod/pull/316) | 多客户端 + 陈旧客户端保护 + dma_unmap/reset | `yeungtuzi:pr/multi-client`（仅 `src/` 改动，381 行） |
| [rust-vmm/vfio#171](https://github.com/rust-vmm/vfio/pull/171) | `resettable` 解析取反修复 | `yeungtuzi:fix/resettable-flag-parsing` |

**关键提交**
| commit | 内容 |
|---|---|
| `575c759` | 多客户端共享 backend + `dma_unmap`/`reset` 实现 + `DynamicBus` 幂等 |
| `becc84f` | 陈旧客户端不得拆除设备（IRQ 归属者语义） |
| `abecad6` | 注册 IRQ 后补发踢中断（修复交接窗口丢失中断） |
| `651f7a2` | 上游 PR 分支（仅源码） |

**CH 侧改动**：仅 `Cargo.toml` 的 `[patch.crates-io]`（指向 `yeungtuzi/vfio` 的 `demo/standalone-crate` 分支），**无代码改动**。

**结论**：同主机 USB 存储直通 live migration 演示目标（R14）**达成**——Guest 在迁移期间完成 128 MiB 复制，数据逐字节一致，无重枚举、无 reset、停机 4–18 ms。

**遗留（如实记录，不阻塞演示）**
1. 串口控制台在迁移后重置（目标端重建串口设备），Guest 会重印登录横幅——CH 串口设备行为，与 USB 通路无关。
2. 缺少 usbvfiod 侧显式 quiesce：迁移瞬间在途传输靠"踢中断 + Guest 重试"恢复；如需零重试，需要 D4 的有界 drain。
3. `--max-clients > 1` 下进程不再随最后一个客户端退出；systemd 场景需显式管理生命周期。


