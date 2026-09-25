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

**设备事实**：Innostor `1f75:0903`，路径 `1-7`，**32 GB**（非用户所说 16 GB），exfat 卷标 `<stick-volume-label>` + `VTOYEFI`（Ventoy 启动盘，数据分区为空）。

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
**Fork**：`<fork-owner>/{usbvfiod, cloud-hypervisor, vfio-user}` 全部就绪。

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

**发现（影响 PR 目标仓库）**：`rust-vmm/vfio-user` 已于 **2025-05-19 归档**，代码迁至 **`rust-vmm/vfio`** 单仓，其中 `vfio-user/` 子目录即 `vfio_user 0.1.5`。已 fork `<fork-owner>/vfio`，修复并推送分支 **`fix/resettable-flag-parsing`**（commit `3a645f8`）。

**网络（重要，已记录）**：本机访问外网（GitHub / Google / HuggingFace）需代理
`socks5h://<proxy-host>:1080`。已写入全局 git 配置（`http.proxy` / `https.proxy`），**对所有项目生效**。

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
| [cyberus-technology/usbvfiod#316](https://github.com/cyberus-technology/usbvfiod/pull/316) | 多客户端 + 陈旧客户端保护 + dma_unmap/reset | `<fork-owner>:pr/multi-client`（仅 `src/` 改动，381 行） |
| [rust-vmm/vfio#171](https://github.com/rust-vmm/vfio/pull/171) | `resettable` 解析取反修复 | `<fork-owner>:fix/resettable-flag-parsing` |

**关键提交**
| commit | 内容 |
|---|---|
| `575c759` | 多客户端共享 backend + `dma_unmap`/`reset` 实现 + `DynamicBus` 幂等 |
| `becc84f` | 陈旧客户端不得拆除设备（IRQ 归属者语义） |
| `abecad6` | 注册 IRQ 后补发踢中断（修复交接窗口丢失中断） |
| `651f7a2` | 上游 PR 分支（仅源码） |

**CH 侧改动**：仅 `Cargo.toml` 的 `[patch.crates-io]`（指向 `<fork-owner>/vfio` 的 `demo/standalone-crate` 分支），**无代码改动**。

**结论**：同主机 USB 存储直通 live migration 演示目标（R14）**达成**——Guest 在迁移期间完成 128 MiB 复制，数据逐字节一致，无重枚举、无 reset、停机 4–18 ms。

**遗留（如实记录，不阻塞演示）**
1. 串口控制台在迁移后重置（目标端重建串口设备），Guest 会重印登录横幅——CH 串口设备行为，与 USB 通路无关。
2. 缺少 usbvfiod 侧显式 quiesce：迁移瞬间在途传输靠"踢中断 + Guest 重试"恢复；如需零重试，需要 D4 的有界 drain。
3. `--max-clients > 1` 下进程不再随最后一个客户端退出；systemd 场景需显式管理生命周期。



---

## D10. 评审驱动的迭代（轮次 1，2026-09-20）

**背景**：论文初稿（`paper/main.pdf`）完成后，用本机模型组建了三位审稿人（系统 / 方法学 / 写作）进行预评审。结论：**系统方向 Reject（顶会标准）、方法学 Major Revision、写作 Major Revision**。完整意见与逐条处理见 `docs/review_report_cn.md`。

**评审发现的两个真缺陷（这是本次迭代最大收获）**

1. **我修复中断竞态的方法本身有竞态**（系统审稿人发现）。
   我把"补发踢中断"放在 `set_irqs` 的**调用线程**上，而事件是由 interrupter 的 worker 线程从 mpsc 队列里顺序取出的。若某个 `SendEvent` 排在 `UpdateInterruptLine` 之前，它仍会被写到**旧的中断线**上；而调用线程的踢中断可能已经在 worker 处理到换线之前就打出去了 —— Guest 扫描事件环时什么也没看到，事件随即丢失。**这正是我以为已经修好的那个缺陷的残余形态。**
   **修复**：把踢中断移入 worker 的 `UpdateInterruptLine` 分支，在**换线之后**执行。只有 worker 自己才能把这次踢中断与排在前面的事件排出先后顺序。

2. **我的验收判据"迁移后无重枚举"根本无法触发**（方法学审稿人发现）。
   harness 统计的是 `uptime > 30s` 的枚举行，而迁移发生在 Guest uptime **≈14.6s**；且 harness 在 `MD5_DONE` 出现后立刻杀掉 VM，因此 `>30s` 的窗口实际只有约 1 秒。也就是说**该判据永远是 0**，"无重枚举"结论当时并没有被真正测量。
   **修复**：新增 `guest/verdict.py` —— 用 Guest 心跳行（同时带 epoch 与 `/proc/uptime`）插值出**迁移时刻的 Guest uptime**，只统计该时刻之后的枚举/复位/IO 错误；并让 Guest 在复制结束后把 `dmesg`+`lsusb` 追加进自己的日志，全部判据取自 **Guest 自己的日志**（而非被本文自己证明会丢行的串口）。

**其他已修**：`set_irqs` 的 `assert!` 改为返回错误（畸形客户端不再能打崩连接线程）；新增相关工作定位（已核实的 QEMU `[PATCH v2 0/8] vfio-user: live migration support`（Hugo Komatsu, 2026-09）与 Watanabe et al., SAINT 2010）；实验环境如实披露（宿主同时跑 4 台 KVM VM、无 CPU 绑定、调试构建 + `-v` + pcap、Guest 2 GiB/1 vCPU）；新增 `Threats to validity` 小节与统计区间（10/10 → Clopper–Pearson [0.74,1.0]，残余失败率上界 ≈26%，与修复前比较 Fisher p≈0.33）；标题/摘要去 overclaim；引用改用 BibTeX+IEEEtran（自动按引用顺序、补访问日期）；修正表 I 中引用 VIRTIO 1.2 的 "virtio-usb" 错误行；重绘图 1/图 2。

**新增验证基础设施（均为可复现脚本）**
| 脚本 | 作用 |
|---|---|
| `guest/verdict.py` | 从 Guest 日志计算判定（含迁移时刻 uptime 插值） |
| `guest/acceptance-batch.sh` | N 次运行 → CSV + 置信区间 |
| `guest/summarize-batch.py` | 独立后处理汇总（Clopper–Pearson） |
| `guest/irq-kick-ab.sh` | **受控 A/B**：同一二进制内通过 debug-only 钩子 `USBVFIOD_DISABLE_IRQ_KICK` 关闭踢中断，作为负对照 |
| `guest/replug-baseline.sh` | "朴素方案"基线：不迁移、直接热拔插，测量 Guest 侧代价 |
| `guest/collect-artifacts.sh` | 把每次运行的全部原始文件（含 pcap）留档 + 校验和 + manifest |
| `guest/sample-host-load.sh` | 批次期间采样宿主负载，用于归因运行间差异 |

**工件留档策略（用户要求：跑够次数、全部原始日志留档）**
- 每次运行的全部原始文件（Guest 日志、串口捕获、两端 CH 日志、usbvfiod 全量 trace 日志、USB pcap、迁移记录）**逐字节保留**，不筛选、不裁剪。
- 落盘到 `artifacts/`（`/run` 是 tmpfs，重启即失），附 `SHA256SUMS` 与 `MANIFEST.md`（逐轮指标 + 文件清单 + 复算方法）。
- 单次运行的 pcap ≈130 MB（完整 128 MiB USB 流量），故 `artifacts/` 的数据不入 git，仅以附件形式交付；`artifacts/README.md` 与 `.gitignore` 入库。

**教训（写入流程）**
1. **判据必须由被观测对象自己的时钟与日志产生**。用宿主时钟 + 固定阈值去判断 Guest 内部状态，两处都出过错（串口丢行、阈值不可能触发）。
2. **修复时序缺陷时，"在哪里执行"和"做什么"同样重要**：同样的踢中断，放在调用线程是错的，放在 worker 内才是对的。
3. **单次通过不能验收时序缺陷**；必须有可开关的负对照（`irq-kick-ab.sh`）与更大的样本量。
4. **跑够次数 + 全部原始日志留档**，否则"10/10"既无法被检验，也无法被复算。

---

## D11. 轮次 3：把"运气"换成"确定性注入"（2026-09-20）

**动机（来自轮次 1/2 的未满足项）**：此前证明"交接窗口的修复有效"依赖的是**运气**——交接窗口是否非空、窗口内是否恰有完成事件，都由迁移时序决定。20 次迁移批次中窗口非空的只有 11 次（55%），窗口内完成事件数 0–4 个。审稿人有权说："你无法证明修复在起作用，只能证明这 20 次没坏。"

**做法：两个编译期休眠、运行时可开关的注入钩子（仅 debug 构建）**

1. `USBVFIOD_INJECT_HANDOVER_DELAY_MS=N`（`src/xhci_backend.rs::set_irqs`）
   在**把新中断线交给 interrupter worker 之前**睡眠 N 毫秒。睡眠期间 worker 仍在把完成事件排到**即将退出**的客户端的中断线上——这正是"踢中断"要覆盖的那个窗口。于是该臂的每一次运行都**按构造被暴露**，而不再靠运气。
   *为什么注入点必须在这里*：我最初想放在 worker 的 `UpdateInterruptLine` 分支里，但那会**缩小**暴露——worker 阻塞期间到达的事件会排在换线消息之后，醒来后一律走新线。只有在 `set_irqs` 里延迟"交线"，旧线才会在这段时间里持续被写入。

2. `USBVFIOD_DISABLE_OWNER_GUARD=1`（`src/shared_backend.rs::owns_device`）
   让每个连接都"自认为"设备归属者，从而**故意重新引入**陈旧拆除缺陷：源端 VMM 的 IRQ-disable 会落到目标端刚装好的线上，把它替换成 dummy。

**代码证据（本次实测的日志顺序，run `debug-3`）**

```
06:11:03.150520  set IRQs: 2 flags: 0x24 start: 0x0 count: 0x1 #fds: 1   <- 目标端注册
06:11:03.150907  interrupt line installed: re-raising one interrupt ...  <- worker 换线 + 踢
06:11:03.155512  ignoring IRQ disable from stale vfio-user client 0      <- 源端陈旧拆除（晚 4.6ms）
```

注意最后一行：陈旧拆除**确实在换线之后到达**（晚 4.6 ms），而其后还有约 11 秒的复制、数千个完成事件。这说明**归属守卫是承重的**（不是"理论上可能有用"）：一旦旁路，目标端的中断线会被 dummy 覆盖，后续所有完成事件都不再产生中断。

**注入臂设计**（`guest/injection-suite.sh`，四臂，判定脚本与验收批次完全一致）

| 臂 | 延迟 | 踢中断 | 归属守卫 | 预期 | 证明什么 |
|---|---|---|---|---|---|
| `baseline` | 0 | on | on | PASS | 钩子在未启用时是惰性的（不会悄悄改变行为） |
| `window` | 500 ms | on | on | PASS | 踢中断能覆盖**被放大**的窗口，而非只会覆盖几毫秒的巧合 |
| `window-loss` | 500 ms | off | on | FAIL | 窗口本身是真实危害（不是"没发生过的故障"） |
| `guard-off` | 0 | on | off | FAIL | 归属守卫是承重的 |

**作者信息（用户决定）**：用户选择"先保持匿名、按双盲投稿处理"。`paper/main.tex` 与 `paper/abstract_zh.tex` 的作者块已改为规范的匿名投稿表述（稿号 + "为双盲评审隐去作者/单位/联系方式"），不再使用 `Author Name` / `author@example.edu` 占位符。真实姓名与单位待用户提供后填入。

**流程**：注入钩子与匿名作者块已 commit。**注入批次排在验收批次之后**，因为它是 debug 构建；验收批次运行期间**不重建二进制**（`acceptance-batch.sh` 不调用 cargo，脚本已核实）。


## D12. 轮次 3：一个被对照臂揪出的方法学缺陷（2026-09-20）

**发现经过**：批次跑到 PHASE C（release 构建的迁移臂）时，第 1 次运行就给出
`spans=NO` + `VERDICT: FAIL`，但 `md5=MATCH`、`late_enum=0`。原始日志：

```
COPY_START : 1789885595.129
COPY_DONE  : 1789885601.476 (rc=0)   -> 复制只用了 6.3 s
migration epoch : 1789885602.661     -> 迁移请求比复制结束还晚 1.2 s
spans migration : NO
```

**根因**（这是我自己的 harness 缺陷，不是 usbvfiod 的缺陷）：harness 在 `COPY_START` 之后
`sleep 4`，再**启动目标端 VM、等 API、启动 receive-migration、再 sleep 2**，最后才
`send-migration`。于是在"复制开始"和"迁移请求"之间有约 **3.5 s 的固定开销**。
debug 构建复制 128 MiB 要 13–38 s，4 s + 3.5 s 的开销落在复制窗口内，所以一直没暴露问题；
release 构建只要 **6.3 s**，同一时序就变成"复制已经结束，迁移才被请求"。

**这是一个真实的教训**：我把"迁移是否落在复制窗口内"当成验收判据，却用**固定墙钟延迟**去安排迁移。
判据是对的，触发方式与构建速度耦合。**如果没有 release 对照臂，这个缺陷不会被发现**——
这正是"必须成对做对照"的价值。

**修复（两处，都是使判据更强而非更松）**

1. **触发改为按复制进度，而不是按墙钟**。
   - Guest 心跳从 `DEMO-HEARTBEAT n <epoch> uptime=U` 扩展为
     `DEMO-HEARTBEAT n <epoch> uptime=U copied=B`（`build-guest.sh`），并把心跳周期从 2 s 缩短到 1 s；
     `demo-copy.sh` 在 `dd` 之前 `rm -f /root/testfile.copy`，避免上一轮遗留的 128 MiB 文件让进度提前"到顶"。
   - Host 在**启动目标端之后**轮询控制台上的 `copied=`，一达到 `COPY_TRIGGER_BYTES`（默认 16 MiB，即 128 MiB 的 12.5%）
     就请求迁移；`COPY_LEAD_SECONDS` 默认降为 0，只作为兜底。
   - 这样迁移点固定在复制的**固定比例**处，与构建速度无关。
2. **判据从"包含迁移请求"加强为"包含整个迁移"**。
   - harness 新增记录 `migration.done`（`send-migration` 返回、即切换完成的时刻）。
   - `verdict.py` 新增 `--migration-done`，当给出时要求
     `COPY_START < epoch <= done < COPY_DONE`，否则 `spans=NO`。
   - 原判据只要求迁移**请求**落在复制窗口内；理论上存在"请求在窗口内、但切换完成时复制已结束"的漏洞。
     现在堵上了。

**代价与处置**：PHASE A（debug 20 次）、PHASE B（control 8 次）用的是旧触发方式，虽然 20/20 全部
`spans=YES`，但为保持四个臂在同一 harness 下可比，**整批作废重跑**。旧批次已完整留档到
`artifacts/campaign-A-fixed-lead/`（31 个 run，含 pcap，4.3 GB，附 `SHA256SUMS` 与 `MANIFEST.md`），
作为"迁移点取在复制开始后约 7.5 s"的独立复现证据保留，不入 git。

**顺带修正**：`/run` 是 6.3 GB 的 tmpfs，容纳不下两批实验（单 run 含 pcap ≈145 MB），
新批次的 `RUNROOT` 改到磁盘 `/root/usb-runs`（根分区余量 120 GB）；宿主内存已用 56/62 GiB，
不采用扩大 tmpfs 的做法，以免影响用户正在运行的 4 台虚拟机。


## D13. 轮次 3：进度触发器上的第二个缺陷（陈旧输出文件）（2026-09-20）

**发现经过**：D12 把触发方式从"固定墙钟"改成"按复制进度（16 MiB）"后，kickoff 臂第 3 次运行
在 `copied=6291456`（6 MiB）处**永久卡死**，而触发器本应等到 16 MiB 才迁移。检查 Guest 心跳：

```
DEMO-HEARTBEAT 1 1789887181 uptime=6.09 copied=134217728   <- 上一轮遗留的 128 MiB 文件
DEMO-HEARTBEAT 2 1789887182 uptime=7.10 copied=2097152
...
DEMO-HEARTBEAT 5 1789887185 uptime=10.17 copied=6291456    <- 此后 118 次心跳都不变
```

**根因**：`rootfs.img` 在多次运行间复用，`/root/testfile.copy` 是上一轮留下的 **128 MiB** 文件。
Guest 启动后、`demo-copy.sh` 执行 `rm -f` 之前，心跳已经把它当作"进度"读走（heartbeat 1）。
宿主侧的 `copy_bytes_seen` 又扫描**整个** `console.log`（包括 COPY_START 之前的心跳），
于是把 134217728 当成"已达到 16 MiB"，**在目标端就绪的那一刻立刻发起迁移**。
所谓"按进度触发"实际上退化成了"尽可能早触发"。

**修复（两道独立防线）**

1. Guest：把截断放到**宣告 COPY_START 之前**（`: > /root/testfile.copy`），
   这样任何 COPY_START 之后的心跳读到的都是真实进度（从 0 开始）。
2. Host：`copy_bytes_seen` 只扫描 `console.log` 中 **COPY_START 之后**的部分。

**这个缺陷的副产品是一份极有价值的证据**：kickoff 臂的这次失败是"丢失中断导致硬挂起"最干净的单一观测：
复制精确停在 6 MiB，连续 118 次心跳（118 秒）不变，服务器日志 `interrupt lines installed: 0`
（踢中断被抑制）、`stale teardowns ignored: 1`，而迁移本身正常完成（停机 17 ms）。
该批次完整留档在 `/root/usb-runs-accidental-trigger/`（含 `README.md` 说明），
并与修正后的批次对照，用于说明结论不依赖于迁移落在复制的哪个位置。

**顺带修正的一处可观测性缺陷**：原来 `interrupt line installed: re-raising one interrupt ...`
这一行只在**执行踢中断**时打印，于是在关闭踢中断的负对照臂里根本**没有**"换线时刻"的日志，
暴露度分析（`analyze-handover-exposure.py`）对负对照臂直接返回 n/a——而负对照恰恰是最需要暴露度的臂。
现在拆成两条独立日志：

- `interrupt line installed`（**无条件**打印，用于定位换线时刻）
- `re-raising one interrupt to cover the hand-over window`（仅在实际踢中断时打印）

harness 的 `kicks` 列也相应改为统计后者（此前误统计前者的数量），CSV 列结构不变。

**教训**：把"触发条件"建立在**跨运行持久化的状态**上（复用磁盘镜像里的文件）是危险的；
触发条件必须只依赖**本次运行之内**产生的事件（此处即 COPY_START 之后的心跳）。


## D14. 轮次 3：完整的对照与确定性注入结果（2026-09-20）

> ⚠️ **本节已被 D15 取代**：D14 记录的是当时的注入臂结果（window-loss 4/5、winlong 3/3 vs 0/3、
> 暴露度按迁移请求锚定 11/20、24 个）。轮次 3 评审发现窗口锚点错误、5 s 臂样本过小（3 次）等问题，
> 修正后的结果见 D15：window-loss **4/10**、winlong **8/8 vs 2/8**、暴露度按源端暂停锚定 **8/20、10 个**。
> 本节保留为过程记录，请勿引用其中的数字。

**批次 B（修正触发后重跑，全部在磁盘 `/root/usb-runs`，含 pcap）**

| 臂 | 通过 | 复制（s） | 停机（ms） | 作用 |
|---|---|---|---|---|
| debug 迁移 | **20/20** | 13.3–32.7（中位 26.0） | 4–21（中位 6） | 主结果 |
| control 不迁移 | 8/8 | 14.4–33.6（中位 26.7） | — | 工作负载本身无问题 |
| release 迁移 | 8/8 | 4.8–10.3（中位 5.8） | 6–21 | 结论不是调试插桩的产物 |
| kickoff 关闭踢中断 | 7/8 | 13.5–32.2 | 4–18 | 自然窗口下丢失中断偶发致命 |

暴露度（20 次验收运行）：窗口宽 **5.00–23.87 ms**，其中 **11 次（55%）** 至少含 1 个完成事件，
合计 24 个，单次最多 4 个。

**故障注入（`guest/injection-suite.sh`，仅 debug 构建，钩子由环境变量开启）**

| 臂 | 注入 | 预期 | 实测通过 |
|---|---|---|---|
| baseline | 无（钩子存在但不启用） | PASS | 5/5 |
| window | 交接前延迟 500 ms，踢中断开 | PASS | 5/5（停机≈519 ms） |
| window-loss | 交接前延迟 500 ms，踢中断关 | FAIL | **4/5**（非确定） |
| winlong-on | 交接前延迟 5000 ms，踢中断开 | PASS | 3/3（停机≈5016 ms） |
| winlong-off | 交接前延迟 5000 ms，踢中断关 | FAIL | **0/3**（确定） |
| guard-off | 关闭归属守卫 | FAIL | **0/5**（确定，$p<0.0001$） |

**朴素基线（热拔插，3 次）**：三次全部失败——Guest 内核记录 `usb 1-1: USB disconnect, device number 2`
与多达 5 条 `blk_update_request: I/O error`（读在途时设备被拔掉），`dd` 返回码为 1，部分拷贝的
校验和与源文件不符。**没有观察到重枚举**，因为复制在重新 attach 生效之前就已经中止。
（修复了 `replug-baseline.sh` 中 `$CH_PID` 未赋值导致脚本在 `set -u` 下直接中止的缺陷——
这个脚本此前从未真正跑通过。）

**本轮最重要的两个技术结论**

1. **归属守卫是确定承重的**：关闭它以后 5/5 失败，Guest 在 36 秒 SCSI 超时（`DID_TIME_OUT`）后
   报出成片 I/O 错误。这是"陈旧拆除会把存活端的中断线换成 dummy"最直接的证据。
2. **踢中断的必要性需要用"足够长的窗口"才能确定地展示**：500 ms 窗口下关闭踢中断仍有 4/5 通过——
   因为丢掉的完成事件若不是**最后一个未完成命令**，Guest 会在下一次完成事件的中断里把事件环一起排空。
   把窗口放大到 5 s 后传输队列必然排空，丢失的必然是最后一个完成事件，于是
   开启 3/3 通过、关闭 0/3 通过。**如果只做 500 ms 那一组，我会得出"踢中断不必要"的错误结论**；
   这正是"注入也必须先想清楚机制、再解释结果"的教训。

**关于"1/5 失败率"的修正**：早期把修复前约 1/5 的卡死全部归因于丢失中断；现在证据显示，
自然窗口下丢失中断只在"恰为最后一个未完成命令"时才致命（约 1/8），而**归属缺陷**是确定致命的那一个。
论文已按此改写：不再声称"单个丢失沿必然致命"，而是给出两种结局的判据（是否最后一个未完成命令）。


## D15. 轮次 3 评审：三位审稿人都指出"叙述超出证据"，逐条修正（2026-09-20）

轮次 3 的结论是 **系统 Major / 方法学 Major / 写作 Minor**。三位**独立**发现了同一个最严重问题，
这在本次迭代里是最有价值的一次外部检验。

### 最严重的问题：交接窗口锚点错了（两位审稿人独立发现）

我把"暴露窗口"的起点定义在 **迁移请求**（`migration.epoch`），并在论文里断言"从这一刻起源端已暂停"。
CH 默认 pre-copy，源端真正暂停要晚 **1.9–6.2 ms**；审稿人把 24 个"有风险"的完成事件逐个映射到
CH 的 uptime 锚点，指出**至少 14 个发生在暂停之前**。

**修复**：窗口起点改为从 `src.log` 解析出的 `event = paused` 时刻，并同时输出请求锚定的严格上界。
重算：**8/20 次、10 个完成事件、窗口 2.99–17.70 ms**（上界 11/20、24、5.00–23.87 ms）。
结论方向不变（窗口确实自然非空），但数字从"多数运行"降到"四成运行"——这正是审稿人说的
"这是'证明'与'在少数运行中证明'的区别"。

### 第二个教训：小样本的 3/3 vs 0/3 是运气

原 5 s 注入臂只有 3 次/臂，$p=0.10$ 不显著，而且是 500 ms 臂预测失败**之后**追加的。
把两臂各扩到 8 次后：**8/8 vs 2/8，$p=0.007$**——仍有 2/8 恢复，所以"确定性失败"的说法也必须收回。
500 ms 臂从 5 次扩到 10 次后是 **4/10**（原来 4/5 看起来"基本没问题"，其实是小样本假象），$p=0.044$。

**教训**：**"确定性"不能靠 3 次运行加上一个完美分裂来宣称**。本轮把"确定性"只留给
0/5 的归属守卫臂；踢中断的结论改为"受控放大窗口下显著，且给出了效力"。

### 其他被审稿人揪出的问题（都已修）

1. **downtime 判定 fail-open**：harness 把缺失的停机值传成 `0`，于是"日志里没有停机行"= 0 ms 通过。
   审稿人用真实日志演示了 `--max-downtime-ms 0` 仍 PASS。已改为原样传递 + 空值即 FAIL。
2. **`migration.done` 不是切换完成时刻**：它比 CH 自己的 `Migration completed` 早 4.6–15.3 ms，
   判据实际只保证"复制包含请求"。已新增 `--src-log`，改用 CH 日志里的真正完成时刻。
   已有批次用 `reverify-batch.py` **离线重判**（不重跑虚拟机），结论不变。
3. **效力分析缺失**：论文声称讨论了效力但没有。已实现精确无条件 Fisher 效力：自然 kick 比较 0.067，
   达 80% 需 62 次/臂；5 s 臂 0.88。
4. **引用错误**：`libvirtformatdomain` 讲的是 `usb-bot`/`usb-storage` 磁盘模型，不是 hostdev USB 直通；
   而且**原句说反了**——libvirt 源码 `qemuMigrationSrcIsAllowedHostdev` 明确允许 USB hostdev 迁移
   （注释里 "migrated" 带引号）。已改为引用 libvirt 源码，并据此把"朴素热拔插"重新定位为
   QEMU/libvirt 的实际做法——这反而让基线对比更有意义。
5. **身份泄露**：`guest/testfile.md5` 的卷标里含真实姓名，DEVLOG 里有 GitHub 句柄与代理 IP。
   新增 `docs/redact-identifiers.py` 做可审计的脱敏（11 处），并提交。
6. **归档不可复算**：`collect-artifacts.sh` 只拷 run 目录，缺 `results-*.csv`；MANIFEST 的指标列全空
   （它去 Guest 日志里找只存在于 harness stdout 的行）。已补齐批次级文件，并用 `make-manifest.py`
   调用 `verdict.py` 重新推导——44 行真实数据，43/44 PASS。
7. **`make data` 崩溃**：硬编码 `paper/data/runs.dat`，从 `paper/` 运行时 FileNotFoundError。已修。
8. 其他：注入钩子作用域声明、guard-off 同时关闭 DmaUnmap 半、reset 修复降级为"未做消融"、
   测试数 108→111、速率 4–10 MiB/s、控制臂仅校验和、热拔插结论句自相矛盾、Firecracker 作者少一人、
   图注补数据来源、删除跟踪的 `__pycache__` 与失效 CSV、页数不再写死。

### 流程层面的教训

**"我自己写的测量脚本"同样需要外部审计**：本轮三个最严重的问题（窗口锚点、fail-open downtime、
`migration.done` 语义）全部出在测量与判定代码里，而不是在被测系统里。论文的可信度主要取决于
这些地方，而不是设备代码。


## D16. 轮次 4 评审：三轮都被判 Minor，核心结论已被接受（2026-09-20）

轮次 4 三位审稿人**全部**给出 **Minor Revision**，且都明确表示核心科学结论成立、不需要新实验，
剩下的都是"叙述/脚本与证据不一致"。逐条处理见 `docs/review_report_cn.md` 第八部分，要点：

1. **暴露窗口锚点再做一次修正**。上一轮用 `migration.epoch + (paused − req)` 仍然偏早，
   因为 `migration.epoch` 在启动 `ch-remote` 之前记录。这一轮改为**用因果相邻的事件对把 CH 的
   uptime 时钟直接对齐到墙钟**（两对原点相差 ≤0.19 ms），得到三个锚点：
   **CH 时钟 4/20、4 个（下界）；harness epoch 8/20、10；迁移请求 11/20、24（严格上界）**。
   论文以下界为头条，另两个并列给出。
2. **多重比较**：六个对比做 Holm 校正，只有归属守卫与 5 s 对存活；500 ms 对比降级为"名义参考"。
3. **最后一个 fail-open**：归档工具 `make-manifest.py` 仍把缺失停机值当 0、且不用 `src.log`；
   已改为原样传递 + `--src-log`，并实测"删掉停机行 → FAIL"。
4. 写作侧最重要的一条是**我自己的脱敏脚本里写着密钥原文**——可审计性做成了泄露源。已改为只存
   SHA-256 摘要；并新增 `make-anonymous-snapshot.sh`，因为仓库的 `.git`（origin 与 commit 作者）
   本身就能识别作者，双盲附件必须是无 `.git` 的快照。

**三轮下来最一致的教训**：审稿人反复攻击的都不是设备代码，而是**测量与判定代码**
（窗口锚点三次、fail-open 两次、归档与脱敏各一次）。这也是本文最值得保留的部分：
把"怎么测"当成一等公民来审计。

## D17. 轮次 5 评审：三位都写"nothing blocks acceptance"（2026-09-20）

三位新审稿人一致 **Minor Revision**，并且都明确说不阻塞接受；科学结论与统计方法被认为成立，
剩余问题全部是文本/工件层面。最值得记录的一条是**我自己的脱敏操作把六个脚本改坏了**：
把 `/root/lvllm/usbvfiod` 全局替换成 `<repo>` 时误伤了 `guest/campaign-b.sh`、
`extend-injection.sh`、`phase-e-and-winlong.sh`、`collect-artifacts.sh`、`sample-host-load.sh`、
`archive-round3.sh`，而这些脚本正是附录推荐的复现路径。审稿人逐个检查了它们能否运行。
**教训：为了匿名做的批量替换，必须对"可执行工件"单独验证（至少 `bash -n` + 一次空跑）。**

其余修正：中文摘要的"此后再无完成事件"（与 kickoff-5 日志矛盾）、另一处 "three orders of
magnitude"、第三个暴露锚点的命名（实为 harness epoch 而非迁移请求）、注入小节不可复现的计数区间、
`verdict.py` 与暴露分析锚点不一致的说明、`injection-suite.sh` 注释、附录重复追加的指引。
至此论文中所有评测数字均由脚本生成，无手写数字。

## D18. 事故与纪律：/tmp（tmpfs）被塞满，连带打挂了 KVM 101（2026-09-20）

**发生了什么**：轮次 5 之后我为了尽快收敛，**同时**发起了 3 个评审 subagent，并叠加了构建/分析命令。
这些命令都经 DSH 执行，而 DSH 的命令通道把包装脚本与输出写在 **`/tmp`（tmpfs，占的是内存）**。
`/proc/meminfo` 显示 `Shmem` 一度达到 **39 GB**，内存被挤爆后：
1. 用户的 **KVM 虚拟机 101 崩溃**；
2. `/mnt/mt` 是 **101 提供的 Samba/CIFS 共享**，因此该文件系统也随之卡死。

**症状的迷惑性**：`bash`/`grep`/`glob` 全部返回 `ENOSPC`，而 `read`/`write` 对 `/root`（ext4）正常。
原因是 DSH 的执行路径与纯文件系统路径不是同一条：`dsh-bash-local` / `dsh-subprocess-local` /
`dsh-tool-fs-search`（起 ripgrep）需要可写的临时目录，`dsh-fs-local` 不需要。
**当时最危险的动作是继续往那个共享里写**——卡死的 CIFS 挂载会让进程进入不可中断睡眠。

**处置**：
1. 清空 `/tmp`（`find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} +`），内存与 Shmem 立即回落；
2. 用户重启 101 并重新挂载 `/mnt/mt`（`//<share-host>/<share-name>`，14 TB，余 6.6 TB）；
3. 新增 `scripts/archive-pcaps-to-mnt.sh`：把 161 个 `usb.pcap`（**20.5 GB**）搬到
   `/mnt/mt/usbvfiod-artifacts/`，先复制成功再删源、按 run 名+大小+sha256 去重、
   并重建各批次 `SHA256SUMS` 与 `PCAPS.md` 指针。
   **所有对网络的访问都用 `timeout` 包裹**，共享挂不上时直接退出而不是挂死。
4. 顺带核实：`/root/usb-runs`、`/root/usb-inject` 里的 pcap 与归档树中的**逐字节重复**（85 个），
   已先删掉这些重复副本，释放 **9.4 GB**；删除后 `update-results.py` 仍能**逐字节**重生成 `paper/data/results.tex`。
5. `/` 从 104 GB 占用降到 **75 GB**（111 GB 可用）。

**纪律（写进流程，后续严格遵守）**
- **不把 `/tmp` 当存储**：所有中间产物写到 `/root/.dsh-tmp`（ext4），命令统一 `export TMPDIR=/root/.dsh-tmp`。
- **限制并发**：评审 subagent **一次只跑一个**，并明确要求"不要复制原始数据、不要写 `/tmp`"。
- **动手前看水位**：`df -h /tmp` 与 `free -g`，异常就先清理再继续。
- **对可能挂死的网络挂载**：只用 `timeout` 包裹的探测，绝不裸 `stat`/`cd`/`cp`。
- **绝不再为了速度同时堆叠多个重任务**——这次代价是打挂了用户正在用的虚拟机。


## D19. 轮次 6：系统与方法学给出 Accept；写作侧因"我自己的检查脚本泄露"打回（2026-09-20）

系统方向与方法学**都给出 Accept**，且都是独立复现全部数字后的结论。写作侧指出一个我先前的修复**本身**成了泄露源：

**缺陷**：为了让"检查器能识别连字符/小写形式"，我在 `docs/redact-identifiers.py` 的注释里写了
"名字可能写作 X、Y、Z"——直接把真实人名与账号写进了仓库；同时脚本用 `ALLOW` 把自己排除在摘要扫描之外，
于是它**报告 OK，却生成了含人名的匿名快照**。审稿人做了两步验证：把快照解包后在**快照内部**运行同一个脚本，
得到 `FAIL: 10`；以及分别从仓库根与 `docs/` 运行，得到不同结论（fail-open + cwd 依赖）。

**修复**：注释去字面量化；固定 `chdir` 到脚本所在仓库根；无 `.git` 时遍历该根（而非调用者目录）；
路径也纳入扫描；取消白名单；新增 `--selftest`（合成摘要，测正文/文件名命中与无漏报，测完即移除）；
并用"生成快照 → 解包 → 在快照内复跑检查器"做端到端复验。

**教训（第三条同源教训）**：**为匿名而写的工具，本身就是审计对象**。
第一次是批量替换把脚本改坏（`<repo>`），第二次是脱敏脚本自己含密钥。
以后任何"安全/匿名"脚本，都必须：(1) 不含被保护对象；(2) 在**它要保护的产物内部**验证；
(3) 有回归自测；(4) 与 cwd/仓库形态无关。

## D20. 轮次 7：连"压缩包元数据"都会泄露（2026-09-20）

写作审稿人确认轮次 6 的五项缺陷全部真修好了（脚本无字面量、不再自我豁免、与 cwd 无关、
路径也扫描、快照内复跑检查器通过），但发现了**新的、更隐蔽的一层泄露**：

**`git archive` 生成的 tar 里带 `pax_global_header`，其中 `comment=<commit id>`；
而该 commit id 在任何托管站点上都能解析到公开的 fork，于是压缩包把工件与账号直接关联起来。**
`--format=zip` 同样在归档注释里带 SHA，换格式没用。检查器只读文件内容与路径，
**结构上看不到归档元数据**，所以此前的"端到端复验"不可能发现它。

**修复**（`docs/make-anonymous-snapshot.sh`）：
1. `git archive` 先导出到临时目录，再用 **普通 gnu tar** 重新打包：固定 mtime、uid/gid 归零、
   `gzip -n`（不写文件名与时间戳）；
2. 断言 `gzip -dc out.tar.gz | git get-tar-commit-id` **为空**，否则拒绝产出；
3. **在解包后的归档里**、从两个不同 cwd 各跑一次检查器；
4. **工作区不干净时拒绝执行**——否则检查的是工作区、发布的是 HEAD。

**同时修好检查器自身的三处不足**（审稿人指出，均属"工具比它宣称的更弱"）：
- `candidates()` 新增 `. : / @` 连接：此前只支持空格/连字符/直接拼接，导致 11 个摘要中
  "点分地址""主机名"这类**根本无法在正文里被构造出来**（只有整串相等才命中）；
- GENERIC 检测重新覆盖**文件正文**（此前只在路径上运行，是个回归）；
- `--selftest` 增加"点分"和"冒号分隔"的合成样例，避免"只测一种形式就宣称能测"。

**教训（同源第四次）**：匿名的层次不止"文件内容"——**文件名、压缩包元数据、版本库历史**都要算。
并且**检查工具自身必须具备"在最终产物内部验证"的能力**，否则它给出的 OK 没有意义。

## D21. 目标达成：三条评审轴全部 Accept（2026-09-20）

轮次 6 系统与方法学即给出 **Accept**；写作/工件轴因**我自己的匿名工具连续两次泄露**
（先是检查脚本注释含人名，后是 tar 的 pax 头带 commit id）被打回两次，
在轮次 8 得到 **Accept**（"the tarball is safe to attach"）。

**最终交付**
- `paper/main.pdf` 13 页、`paper/abstract_zh.pdf` 2 页，0 error / 0 undefined / 0 overfull；
- 所有评测数字由 `paper/update-results.py` 从原始 CSV 生成，独立复现一致；
- 三条独立评审轴均通过：系统方向、实验方法学、写作与工件。
- 匿名快照 `/root/lvllm/usbvfiod-anonymous.tar.gz`（sha256 `bcd17fcc…`）。

**本目标全过程最大的收获（写给未来的自己）**
1. **审稿人反复攻击的是"测量与判定代码"，不是设备代码**：窗口锚点改了三轮、
   fail-open 判定改了两次、归档可复算与脱敏各两轮。
2. **为匿名而写的工具本身就是审计对象**：它自己会泄露、会自我豁免、会看不到归档元数据。
   任何安全/匿名工具必须在**最终产物内部**验证，并有回归自测。
3. **小样本的完美分裂是运气**：3/3 vs 0/3 在扩到 8/臂后变成 8/8 vs 2/8，
   "确定性"这个词因此只保留给 0/5 的归属守卫臂。
4. **一次事故的代价**：并发堆叠任务把 `/tmp`（tmpfs）塞满 → 打挂用户的 KVM 101 →
   连带其提供的 CIFS 共享卡死。纪律（TMPDIR 落 ext4、单并发、动手前看水位、
   网络挂载一律 `timeout`）已写入 D18 并全程遵守。

## D22.【最高纪律】对他人 GitHub 项目的任何写操作必须逐条获得用户批准（2026-09-20）

**规则（用户明确定义，优先级高于本文件其余所有流程约定）**

> 除非得到用户**逐一批准**，否则**不得**对任何 GitHub 上**他人的项目**执行写操作，
> 包括但不限于：创建/修改/关闭 **PR**、发 **issue**、发 **comment**、提交 **review**、
> 推送标签或分支、以及**通过 push fork 间接导致 PR 被创建或更新**（例如推送某个
> 作为 PR head 的分支，会更新上游的 PR）。
> 每一次操作都必须先说明"对哪个仓库、做什么、为什么"，得到明确同意后才能执行。

**执行方式（本 agent 自我约束）**
1. 对第三方仓库（`cyberus-technology/*`、`rust-vmm/*`、`cloud-hypervisor/*` 等）**默认只读**：
   允许 `git clone/fetch/ls-remote`、读 PR/issue 页面；不允许任何写。
2. **推送前先判断目标分支是否某个 PR 的 head**。若是 → 属于"间接写 PR"，必须先获批。
3. 对自己的 fork（`<fork-owner>/*`）的主分支推送，若**不会**导致任何上游 PR 变化，
   视为保存工作所需的最小操作，但仍会在每次推送后明确报告"这次推送影响了什么"；
   只要用户要求，连这类推送也改为先批准。
4. 任何需要批准的操作，一律**先停下来问**，不得因为"就差一步"而自行继续。

**截至本条目，已发生的第三方写操作盘点（均为本会话之前完成，本会话未新增）**

| 对象 | 类型 | 内容 | 状态 |
|---|---|---|---|
| `cyberus-technology/usbvfiod` | PR **#316** | 多客户端 + 陈旧客户端保护 + dma_unmap/reset（head: `<fork-owner>:pr/multi-client`） | **draft，未提交评审**；本会话未再推送该 head 分支，PR 内容未变 |
| `rust-vmm/vfio` | PR **#171** | `resettable` 解析取反修复（head: `<fork-owner>:fix/resettable-flag-parsing`） | 同上，draft，未变 |

以下操作**从未**执行：任何 issue、任何 comment、任何 review、任何非 fork 仓库的直接 push、任何标签推送。

**本会话对 `origin`（`github.com/<fork-owner>/usbvfiod`，用户自己的 fork）的推送**：
只推送 `main` 分支，**不会**更新上述两个 PR（它们的 head 分别是 `pr/multi-client`
与 `fix/resettable-flag-parsing`）。若用户要求，后续连这类推送也先逐次批准。

### D22.1 执行记录：关闭两个 draft PR（经用户逐条批准）

用户批准内容：**静默关闭（不发 comment）+ 删除 head 分支**；并允许推送自己的 fork `main`。

| 操作 | 对象 | 结果 |
|---|---|---|
| `gh pr close 316 --delete-branch` | `cyberus-technology/usbvfiod#316` | ✅ state=**CLOSED** |
| `gh pr close 171 --delete-branch` | `rust-vmm/vfio#171` | ✅ state=**CLOSED** |
| `git push origin --delete pr/multi-client` | `<fork-owner>/usbvfiod` | ✅ 已删除（该 fork 现仅剩 `main`） |
| `git push origin --delete fix/resettable-flag-parsing` | `<fork-owner>/vfio` | ✅ 已删除 |

说明：`gh` 对 fork 来的 PR 会跳过远程分支删除（提示 "Skipped deleting the remote branch of
a pull request from fork"），因此分支是用 `git push --delete` 显式删除的；**未**创建任何
issue/comment/review，**未**触碰上游仓库的任何代码或分支。

**保留未动**：`<fork-owner>/vfio` 的 `demo/standalone-crate`（CH 的 `[patch.crates-io]` 指向它，
论文复现需要）以及 `muislam/*`、`main`（非本次授权范围）。如需一并删除，请再单独指示。

**此后流程**：任何对第三方仓库的写操作（PR/issue/comment/review/标签/分支，
以及会更新上游 PR 的 fork 推送）都会先以"命令 + 逐字文案"形式提交给你批准。

## D23. 根据反馈重做交接语义：两阶段预检 + 显式提交 + 保源回滚（设计稿）

**反馈**：领导认为中心思想可用，但"具体实现不是想要的"——现流程是"先断开旧的再连新的"，
没有"先判断新 VM 能不能成功"，缺东西时应保持旧环境运行，实现"有点粗暴"。

**诊断（对着代码）**：现在的归属是 **commit-on-register**——第二个连接一旦 `SetIrqs`
就立刻成为 `irq_owner`，源端在那刻失去中断线且**无法恢复**；预检、提交点、超时、租约全都没有。
这正是论文 §VII 自己承认的那条限制。

**设计稿**：`docs/handover-two-phase-design_cn.md`（v1.0，未实现）。要点：
1. 新连接先做 **Candidate**：它的中断线**只暂存不安装**，源端在此期间**仍是 owner**，
   中断照打、teardown 照收；
2. **预检**（A1–A6 硬条件 + B1–B3 可配置）：握手/能力兼容、**DMA 区间实际覆盖**、
   eventfd 可用、**设备仍健康**（直接用已有的 `detach_token()`）、控制通道 `ready`；
3. **显式提交**：复用现有 `hotplug_protocol`（Attach/Detach/List）扩展
   `HandoverStatus/Ready/Commit/Abort/Reclaim`，在 `control` 临界区内原子切换并递增 `epoch`；
4. **保源回滚**：预检失败/超时 → 源端完全无感；提交后取消 → 上一任可在 **租约（默认 5 s）内 reclaim**；
5. **防陈旧**：破坏性命令必须携带最新 `epoch`，旧 epoch 一律拒绝；
6. **机制在服务端、策略在控制通道、VMM 源码不改**；单客户端默认行为不变；
7. 验证矩阵 T1–T11（含"缺 DMA 映射""坏 fd""设备被拔""预检超时""提交后回滚""租约过期"等故障注入），
   判定仍全部取自 guest 自身日志。

**下一步**：等用户确认设计稿（M1）后再进入 M2 实现。任何对第三方仓库的写操作仍按 D22 逐条批准。

### D23.1 reclaim 由谁触发（补充设计，含 CH 源码核对）

问题：**上一任如何触发显式 reclaim？** 核对 CH 源码后确认**源端 VMM 自己发不出来**：
`enable_irq`（发 `SetIrqs` 给 usbvfiod）只在设备激活时调用（`pci/src/vfio_user.rs:330`）；
迁移失败走 `try_resume_vm_after_failed_migration`（`vmm/src/lib.rs:2143`），
它**只恢复 vCPU、停 dirty log，不会重新 enable IRQ**。所以：

1. **主触发**：驱动控制通道的 harness/supervisor 在确认迁移失败后发
   `HandoverReclaim { conn: src_id, epoch: N }`；服务端校验
   "conn == prev 且连接存活、epoch == 当前、在租约内、对端可信" 才切换。
2. **身份**：连接 id 由 usbvfiod 分配并在 `HandoverStatus` 里连同角色与**对端 pid（SO_PEERCRED）** 返回，
   驱动方据此把源/目标映射到 id；控制 socket 权限即信任边界（与论文既有信任声明一致）。
3. **自动兜底**（建议默认开）：已提交的 owner 连接断开、而 prev 仍存活且在租约内 →
   服务端自动归还给 prev（覆盖"目标端崩溃"且无人值守的情形；成功迁移时断开的是 prev，不会误触发）。
4. **次要触发（为将来保留）**：接受 prev 在租约内的一次新的非空 `SetIrqs` 作为 reclaim 请求；
   今天 CH 不会发，但若将来 CH 恢复路径重新 enable IRQ 或我们加一个 helper，即自动生效。

设计文档已补 §4.5.1 与 T7b/T7c/T7d 三个测试项。

### D23.2 「CH 自己一定知道迁移结果」——已确认，且 CH 已经主动发出信号

核对 CH 源码后确认：**不需要我们推断，也不需要改 CH**。CH 有两条现成通道：

1. **专用事件通道** `--event-monitor path=<path>`（或 `fd=`），事件以 **JSON** 写出
   （`event_monitor/src/lib.rs::event_log`，含 `timestamp/source/event/properties`）；
2. 同一函数同时写普通日志 `Event: source = {source} event = {event}`，所以现有 `src.log`/`dst.log` 里就有。

与结果相关的全部事件（触发点已核对）：源端 `migration-started`(`lib.rs:1698`)、
`pausing/paused`(`vm.rs:3275/3301`)、**`resuming/resumed`(`vm.rs:3306/3329`，由失败恢复路径
`try_resume_vm_after_failed_migration` 的 `vm.resume()` 触发，`lib.rs:2143`) = 迁移没成功**；
目标端 `migration-receive-started`(`1179`)、**`migration-receive-finished`(`3319`)**、
**`migration-receive-failed`(`3322`)**；源端成功路径 `shutdown`(`2696`)。

**设计升级**：新增 §4.5.2，用**事件驱动的控制器**取代"从 `send-migration` 返回码猜结果"：
在 `migration-receive-started` 且预检全绿时 `ready`+`commit`；在 `migration-receive-failed`
或源端 `resumed` 时按"是否已 commit"选择 abort 或 reclaim。这样"失败/取消"的判定权交给 CH 本身，
harness 不再需要推断取消语义。测试矩阵新增 T12（取消）与 T13（成功不误回滚）。

## D24. E1 实测：迁移失败/取消时 CH 到底发什么事件（以及当前实现如何丢源端）

**结论：CH 完整、及时地把失败告诉了我们，且不需要改 CH。** 用 `--event-monitor path=…`
（JSON，见 `event_monitor/src/lib.rs::event_log`）与普通日志两条通道都能拿到。

### 实测事件序列（`guest/exp-cancel-events.sh`，原始日志 `/root/usb-e1/{s1,s2}`）

**成功路径（s1，8 s 交接延迟 + `timeout_s=2`，CH 仍判成功）**

- 源端：`migration-starting → migration-started → pausing → paused → snapshotting → snapshotted → migration-finished → shutdown`
- 目标端：`migration-receive-ready → migration-receive-starting → migration-receive-started → … → migration-receive-finished`
- 源端日志：`Migration completed after 8.0s with a downtime of 8018ms`

**失败路径（s2，源端 `paused` 后杀掉目标端）**

- 源端：`migration-starting → migration-started → pausing → **paused** → snapshotting → snapshotted → **migration-failed** → resuming → **resumed** → shutdown`
- 源端日志：`Migration failed: Socket error: failed to fill whole buffer` + **`Resumed VM successfully after failed migration`**
- 目标端：`migration-receive-ready → migration-receive-starting → migration-receive-started → activated`（随后被杀）

> 我原先的事件表漏了两个**源端**事件：`migration-starting` 与 `migration-failed`；
> `migration-failed` 比"用 `resumed` 反推失败"更直接，应作为主判据。
> 另外 `resuming/resumed` 在两端都会发（源端失败恢复、目标端接管后恢复），因此判据必须**按实例**区分。

### 当前实现在这一情形下确实丢源端（确定性复现）

s2 的 usbvfiod 日志（毫秒级）：

```
06:51:33.950  源端 set IRQs                          (启动注册)
06:51:41.951  interrupt line installed + kick        (源端线, 8s 注入延迟后)
06:51:50.877  目标端 set IRQs                        (目标端注册)
06:51:58.877  interrupt line installed + kick        (目标端线 → 归属被抢走)
```

同一次运行的 guest 心跳：`copied` 从 2 MiB 涨到 6 MiB 后，**连续 17 次心跳（uptime 26.58 → 42.83，
约 16 秒）停在 6291456 不动**。也就是说：CH 已经把源端 vCPU 恢复（`Resumed VM successfully`），
但 usbvfiod 的中断线还指向**已经死掉的目标端**，源端 guest 再也收不到完成中断 → 复制永久停住。

这正是领导说的"先断开旧的再连新的""不成功时旧环境起不来"，而且**不是理论**：
只要目标端在源端暂停后注册过一次，随后无论因为什么失败，源端都会被留在死线上。
（自然时序下这个窗口只有 0.4 ms 左右，所以表现为偶发；注入 8 s 延迟后 100% 复现。）

**新设计在此情形下的行为**：目标端注册只会让它成为 **Candidate**（线暂存不装），
源端仍是 owner；目标端死在交接窗口 → 预检/事件判定失败 → **abort，源端从未失去中断线** →
复制继续。这条断言将由 T12 实测验证。


## D25. M2/M3 落地 + 真机 T1 实测：新方案完全成功（含一次"目标端已注册后失败"的复现）

### D25.1 服务端：两阶段状态机 + 控制通道（commit `3cfac7d`）

- `src/shared_backend.rs`：`Ownership` 状态机（`owner/prev/epoch/candidate/owner_reg/prev_reg/
  mapped/live/lease/preflight_timeout/require_ready/auto_reclaim`）；`set_irqs` 从"注册即归属"
  改为：首个注册=owner（与启动路径一致），第二个注册=**Candidate（只暂存 fd，不动设备）**；
  `handover_ready/commit/abort/reclaim/status`；`commit` 的**预检在候选仍暂存时完成**，
  只有到"提交点"才 `take()` 候选，因此任何拒绝都可以重试、且不会留下半个交接。
- `src/hotplug_protocol/handover.rs`：新的**行式文本协议**（`status / ready / commit / abort /
  reclaim`，回答 `ok k=v …` 或 `err code=… detail=…`）。三个旧命令保持定长二进制不动；
  接收端先读 1 字节判命令号，旧命令的 fd 仍随首字节送达。选文本而非扩二进制的原因是
  **可诊断**：交接是策略决定，策略决定必须能被读回来。
- `src/bin/remote.rs`：`--handover-status/ready/commit/abort/reclaim`，并且接受
  `owner|prev|candidate|<id>` 角色关键字（自动先查一次 status），harness 不必自己记住连接号。
- `src/hotplug_server.rs`：五条命令接到 `SharedBackendState`；单客户端模式下明确回答
  `ENOHANDOVER`，而不是静默无效。
- CLI：`--handover-preflight-timeout-ms`（2000）、`--handover-lease-ms`（5000）、
  `--handover-require-ready`（true）、`--handover-auto-reclaim`（true）。
- `error code` 是协议的一部分（`ENO_CANDIDATE / EPREFLIGHT_NOT_READY /
  EPREFLIGHT_A3_DMA_INCOMPLETE / EPREFLIGHT_TIMEOUT / EEPOCH_MISMATCH /
  ERECLAIM_NOT_PREVIOUS_OWNER / ERECLAIM_PREV_GONE / ERECLAIM_LEASE_EXPIRED / EBACKEND`），
  harness 断言它们而不是断言人读文本。

### D25.2 无 guest 的确定性证明（commit `5e479c8`，`tests/handover_selftest.rs`）

中断线的安装会在 interrupter worker 里**补发一次中断**，所以"数每个 peer 的 eventfd 被写了几次"
就能直接回答"线装在谁身上、设备是否真的到达了它"。7 个测试，全部断言真实 eventfd 写：

| 测试 | 断言 |
|---|---|
| `staging_…` | 目标端注册后 **源端 0 kick**、目标端 0 kick；未 ready 的 commit 被拒且候选仍在；ready+commit 后目标端 1 kick、源端 0 |
| `…missing_memory…` | 只握手未 `DmaMap` 的目标端 commit 被拒（`EPREFLIGHT_A3_DMA_INCOMPLETE`），源端不动；abort 是 no-op 且 reason 进日志 |
| `…expires…` | 无人 commit → 过期 → 迟到的 commit 得到 `EPREFLIGHT_TIMEOUT`；源端可继续重注册 |
| `…reclaimed_or_falls_back` | commit 后源端被 kick；陈旧 epoch / 非 prev 被拒；**陈旧 unmap+disable 被忽略且新 owner 的线仍可被 kick**；reclaim 后源端被 kick；owner 死在租约内 → 自动归还并 kick |
| `…dead_owner…` | owner 与 prev 都消失 → 设备变 unowned → **下一个注册立即成为 owner 并被 kick**（不需要控制器） |
| `…promoted…` | owner 死亡时暂存的候选被提升为 owner 并被 kick |
| `the_ownership_guard_is_load_bearing` | 打开 `USBVFIOD_DISABLE_OWNER_GUARD=1` 后，陈旧的 disable 真的装上 dummy 线：守卫是承重的，不是装饰 |

### D25.3 真机 T1：控制器驱动，迁移完全成功（`VERDICT: PASS`）

`guest/usb-migration-demo.sh` 现在**由 harness 驱动交接**（源端与目标端都加 `--event-monitor`，
usbvfiod 加 `--hotplug-socket-path`）：控制器轮询 `--handover-status` 直到出现 candidate，
等源端 `paused`，然后 `ready`+`commit`；若 `send-migration` 失败则 `reclaim prev`。
运行：`RUN=/root/.dsh-tmp/usb-demo-t1 HANDOVER=commit ./guest/usb-migration-demo.sh`。

```
status after staging : owner=0 prev=- candidate=1 epoch=1 ready=false   ← 目标端只被暂存
status after commit  : owner=1 prev=0 candidate=- epoch=2               ← 提交才换归属
destination staged at: 802.967 s   committed at: 802.991 s              ← 控制器 24 ms 内完成 ready+commit
source paused        : 802.926 s（CH 时钟）→ 提交安装 802.996 s          ← 暴露窗口 ~70 ms
Migration completed after 0.0s with a downtime of 18ms
md5 verdict: MATCH     spans migration: YES     enumerations after: 0     reset/err: 0
VERDICT: PASS
```

### D25.4 真机实测到的、设计时没有预料到的一件事：CH 在切换点就会拆掉源端设备

T1 的 usbvfiod 日志（毫秒）：

```
01.940  目标端 connect → "hand-over candidate: client 1 staged (owner 0 keeps the line until commit)"
01.948  源端 set IRQs #fds: 0            ← CH 主动 disable 源端中断线（设备 deactivate）
01.949  Connection closed (client 0)     ← 源端 vfio-user 连接被关闭
01.949  owner connection 0 closed (no automatic reclaim)
01.995  commit → set IRQs #fds: 1 → owner 1 (epoch 2) + kick
```

两点结论：

1. **源端不是"被抢"，而是自己先交还**：CH 在切换点会 deactivate 源端设备（disable IRQ + 关连接），
   这发生在目标端注册前后 ~8 ms，**早于迁移结果确定**。所以"暴露窗口"的真实起点是这一次
   disable，而不是源端 paused；终点是 commit 安装线。T1 实测约 **48 ms（disable→commit）/ 70 ms
   （paused→commit）**，窗口内目标端 guest 已经在发命令，但事件 TRB 已经写进共享 event ring，
   只是没人 kick；commit 的那一次 kick 让目标端 guest 重新查看 ring → 全程只掉速度。
2. 由此推出一个**失败路径的真实风险**：如果迁移在"源端已拆、目标端还没装线"之后失败，
   源端的连接已经不存在了，"reclaim 给源端"根本无处可还。因此 `disconnect` 必须把死掉的
   owner 处理干净（见 D25.5），并且真机失败复现实验必须**在目标端注册之后**触发失败。

### D25.5 死掉的 owner 不能继续持有设备（commit `0feef91`）

T1 的 aftermath（`KILL_DST_AFTER_COMMIT=1` 那次跑）暴露：owner 连接消失后
`owner=1 prev=0 epoch=2 live=[]`——**设备永远属于一个已经不存在的连接**，状态行还在骗人。
`disconnect` 改成三级优先：

1. **prev 仍在线 → 归还 prev**。这里**不再要求"仍在租约内"**：租约是约束*控制器* reclaim 决策的
   （防止一个迟到的 actor 把已经成功的交接回滚），而这条路径只在 owner 确已消失时运行；
   拒绝归还只会把设备留给一个不存在的连接。
2. **有暂存候选 → 提升候选**（源端死在成功迁移的最后一刻就是这种情况）。
3. **否则设备变 unowned**（等价于刚启动），**下一个注册立即成为 owner**——迁移失败后重连的
   源端 VMM 因此不需要任何控制器介入就能拿回设备。

三级路径都有测试（D25.2 最后两行）与真机 aftermath 证据。

### D25.6 预检窗口从"回复发出"开始算

`set_irqs` 暂存候选时原先在**暂存瞬间**就设 deadline；但目标端 VMM 只有在收到回复后才能行动，
所以窗口的一部分是在对端还不知道自己是候选时被消耗掉的（真机注入 3 s/8 s 延迟时，控制器的
status 查询会被同一次注册串行化，等它拿到状态时候选已经过期）。现在 deadline 在
**回复发出前**重设：窗口 = 目标端能行动的时长。

> 附带发现的注入钩子语义：`USBVFIOD_INJECT_STAGING_DELAY_MS` 的 sleep 发生在持有
> `ownership` 锁的临界区内（因为暂存与提交必须原子），所以期间控制面（`--handover-status`）
> 会被一起阻塞。这是 debug 注入钩子的性质，生产路径不 sleep；已在此记录，避免误判为控制面缺陷。

### D25.7 负数对照：没人 commit 会怎样

`HANDOVER=none` + 8 s 注入延迟那一次（`/root/.dsh-tmp/usb-demo-t3`）：迁移"成功"、目标端接手，
但**没人给它装线**（`interrupt lines installed: 2` = 源端启动那一次 + 源端拆自己的 dummy 线）。
目标端 guest 继续跑了 35 s 后 xHCI 报 `host not responding to stop endpoint`、
`USB disconnect`、`blk_update_request: I/O error`，复制 `rc=1`、md5 不符。
也就是说：**commit 是承重的**——两阶段交接不是"多此一举的仪式"，少了它目标端 guest 最终会坏。

## D26. 真机收尾：一次由真机抓到的回归（已修）+ 最终 T1/T14 判定

### D26.1 真机抓到的回归：候选的 DMA 覆盖不能看"注册那一刻的快照"

我在 D25.5 给"提升候选"加了自动预检（候选必须已发布设备要用的全部内存），并在**注册时**把候选
当时的 DMA 区间快照进 `Registration`。真机 T1 直接把这个实现打回：

```
07:44:42.147689  hand-over candidate: client 1 staged        ← 暂存（此刻候选还没 DmaMap）
07:44:42.147991  dma_map … size = 2147483648                  ← 目标端 0.3 ms 后才发布内存
07:44:42.155985  源端 set IRQs #fds: 0（deactivate）
07:44:42.156372  WARN not promoting candidate 1: it failed the preflight
07:44:42.156470  WARN the device is unowned (epoch 2)
→ 目标端 guest 再也没有中断线：约 35 s 后 xHCI 报 not responding、USB disconnect、
  blk_update_request: I/O error×9；`md5 verdict: MISMATCH`、`VERDICT: FAIL`
```

根因：**目标端 VMM 的 `DmaMap` 晚于它的 `SetIrqs`**（实测 0.06–0.3 ms），而"源端拆自己"发生在
暂存后 3.7–8.3 ms，所以提升那一刻候选其实已经发布好内存了——是我的**快照**过期，不是候选不合格。

修法：预检改为读**活的** `Ownership.mapped`（候选连接还活着，它的 map 就在那里），
删掉 `Registration.ranges` 快照；并加回归测试
`a_destination_that_publishes_memory_after_registering_is_still_usable`
（注册→发布→owner 死亡→必须被提升并被 kick）。修复后同一条自然路径：

```
07:48:38.243094  hand-over candidate: client 1 staged
07:48:38.243150  dma_map (目标端, +0.06 ms)
07:48:38.246654  源端 set IRQs #fds: 0
07:48:38.246784  promoted the staged candidate 1 (epoch 2) + kick
→ Migration completed after 0.0s with a downtime of 8ms; md5 verdict: MATCH; VERDICT: PASS
```

教训（写进论文也写进这里）：**单元/合成测试覆盖不到 VMM 的真实命令顺序**；这条回归只有真机
跑一遍才会暴露。合成测试里我按 `dma_map → set_irqs` 的"顺理成章"顺序写，正好把缺陷藏住了。

### D26.2 最终判定（自然路径，最终代码）

| 项目 | 值 | 来源 |
|---|---|---|
| T1 自然迁移 | **VERDICT PASS**，md5 MATCH，spans migration，0 重枚举，0 reset/IO 错误 | `usb-w1`（downtime 8 ms）/ `usb-demo-t1`（18 ms） |
| 暴露窗口（paused → 新线安装） | 7.3–29.4 ms（自然 3 次：7.3/9.1/11.7、18.7/23.1/28.5、19.2/23.7/29.4） | `analyze-handover-exposure.py` |
| 窗口内完成的传输数 | 0–3（安装时补发的 kick 覆盖） | 同上 |
| 暂存 → 源端 deactivate | 3.7 ms（w1）/ 8.3 ms（v1） | usbvfiod 日志 |
| 控制器 staged → committed | 23.9 ms（唯一一次赢得竞速的运行 `usb-demo-t1`） | `handover.{candidate,commit}` |
| T14 目标端已注册后迁移失败 | **VERDICT PASS**：`rc=0`、md5 MATCH、copy continued after failure、0 重枚举、0 reset/IO | `usb-f2`、`usb-v2` |
| 无人 commit 的负对照 | 目标端 guest 约 35 s 后失去 USB 栈（9 条 reset/IO 错误），md5 缺失 | `usb-demo-t3`（D25.7）、`usb-v1` |

### D26.3 由数据推出来的、必须如实写进论文的结论

1. **直接收益成立**：目标端注册不再夺线；预检不合格（缺 DMA/未 ready/超时/abort）时源端全程不动，
   已用真机（T14）与无 guest 测试（9 个测试断言 eventfd kick）双向证明。
2. **但控制器显式 commit 不在自然路径的关键路径上**：源端在暂存后 **3.7–8.3 ms** 就被 CH 自己
   deactivate，而控制器的 `ready`+`commit` 需要**两次往返（实测 23.9 ms）**，所以自然路径上真正
   闭合窗口的是**兜底提升**（owner 消失 + 候选通过自动预检 → 提升 + kick）。T1 的 PASS 主要来自这条路。
3. **因此预检目前是"劝告性"的，不是"约束性"的**：CH 不会等控制器判断完再拆源端。要让
   "缺东西就保持旧环境"成为**强制**语义，需要让**目标端注册的应答被挂住**，直到控制器决定
   （commit 放行 / abort 或超时回错 → CH 设备激活失败 → 迁移失败 → 源端恢复）。
   这正是本次实验里用来撑开窗口的注入钩子（`USBVFIOD_INJECT_STAGING_DELAY_MS`）所做的事，
   把它从"测试钩子"提升为"机制"是下一步（需要：暂存时释放 ownership 锁、在条件变量上等决定、
   决定后按 Ok/Err 回复）。已在设计文档与论文里据此改写声明，未声称超出数据的结论。
4. **撤回一个更早的乐观推断**：D23 曾设想"控制器在 `migration-receive-started` 时 commit"，
   实测表明该事件远早于切换点，且目标端设备激活时刻才出现候选；控制器的判定时刻必须由数据
   决定（见第 2、3 点），而不是由事件名字推断。

## D27. 收尾：交付物清单、原始日志位置、以及一件必须记下的自查事故

### D27.1 原始日志（全部在 ext4，未占用 tmpfs）

| 目录 | 内容 | 判定 |
|---|---|---|
| `/root/.dsh-tmp/usb-w1` | 最终代码、自然 T1：PASS，downtime 8 ms，md5 MATCH，暴露窗口 7.3–11.7 ms | T1 |
| `/root/.dsh-tmp/usb-demo-t1` | 控制器真正 commit 的那次：staged→committed 23.9 ms，窗口 18.7–28.5 ms | T1（控制器路径） |
| `/root/.dsh-tmp/usb-f1` | 同一自然路径的复现：PASS，窗口 19.2–29.4 ms | T1 |
| `/root/.dsh-tmp/usb-f2`、`usb-v2` | 目标端**已注册后**迁移失败：`rc=0`、md5 MATCH、copy continued after failure、0 重枚举、0 reset/IO | T14 |
| `/root/.dsh-tmp/usb-v1` | 提升预检快照缺陷的现场（FAIL，9 条 reset/IO） | 回归证据 |
| `/root/.dsh-tmp/usb-demo-t3` | 无人 commit 的负对照：目标端 guest 约 35 s 后失去 USB 栈 | 负对照 |
| `/root/.dsh-tmp/usb-demo-t2`、`usb-demo-t7` | 迁移已完成后再杀目标端：与设备无关，guest 随目标端消失（说明"杀得太晚"） | 排除性证据 |
| `/root/usb-e1/{s1,s2}` | 旧实现下的失败复现（源端被留在死线上、`copied` 卡在 6291456 共 16 s） | 缺陷基线 |

分析工具：`guest/analyze-handover-exposure.py`（窗口与窗口内完成数）、
`guest/verdict.py`（含新增 `--expect-failure` 模式：恢复型运行的判定改为
"源端已恢复 + 失败后复制继续 + md5 一致 + 零重枚举/零 IO 错误"）。

### D27.2 交付物

- 实现：9 个提交，`cf17db0..9bf0dc6`，已推送到 `origin/main`（用户自己的 fork）；**未触碰任何上游 PR**。
- 无 guest 证明：`tests/handover_selftest.rs`，9 个测试，连跑 3 次全绿。
- harness：`guest/usb-migration-demo.sh`（新增控制器、`HANDOVER=`、`KILL_DST_*=`
  与事件驱动的迁移结果判定）。
- 设计：`docs/handover-two-phase-design_cn.md`（v1.0 的 §4.3/§4.5.1/§4.5.3/§7/§9/§10 已按实测更新）。
- 论文：`paper/main.pdf`（14 页，0 error；新增 §Two-phase device hand-over、
  §Failure recovery with the two-phase hand-over，并重写"Failure and rollback"限制段）；
  数字经 `paper/data/two-phase.txt` + `update-results.py` 生成，未手写。
- 匿名快照：`/root/lvllm/usbvfiod-anonymous.tar.gz`，其 sha256 由
  `docs/make-anonymous-snapshot.sh` 打印并同时写入同名 `.sha256` 文件
  （**不在这里写死**：快照内容包含本文件，写死摘要会让"改摘要"本身改变摘要）。

### D27.3 自查事故：匿名快照差点带着 fork 账号名出包

`docs/make-anonymous-snapshot.sh` 在最后一步（在解包后的树里跑 checker）**失败**：
`56 identifying match(es)`，全部来自 `docs/DEVLOG_cn.md` 里 D22 的 GitHub 操作记录——
那几行用了字面账号名（`<fork-owner>` 之外的写法）。也就是说**在上一轮评审之后，
开发日志里又出现了账号名**，而我这一轮先改了论文与日志，正好把它顶到台前。

修法：把该文件里的 7 处字面账号名统一替换为既有的 `<fork-owner>` 占位符；
checker 现在报 `OK: 0 identifying match(es) in 162 files`，快照重新生成并通过三步检查
（tracked 内容、`pax_global_header` 无 commit id、解包后再扫一遍）。

**纪律更新**：每次准备对外附件前，必须完整跑一次 `docs/make-anonymous-snapshot.sh`
（它本身会跑 checker），而不是只跑 `redact-identifiers.py`；因为只有前者会在
**解包后的树**上复核，并拒绝脏工作区。

### D27.4 收尾轮（轮次 9）补的三件事与一次自伤

1. **A4/A5 补齐**：A4 现在真的校验"这是不是一个 eventfd"（读 `/proc/self/fdinfo` 要
   `eventfd-count`），并修掉 `InterruptEventFd::interrupt` 里的 `expect`——客户端给的 fd
   不该能把 interrupter worker 打死；A5（设备仍在）由控制面在每个交接命令前刷新设备清单、
   预检消费它（`--handover-require-device` 可关，无控制面时不误伤）。测试各一个，都断言源端不 kick。
2. **T8 补测**：commit 后等租约过期再 reclaim → `ERECLAIM_LEASE_EXPIRED`，归属与 epoch 不变、
   目标端线仍可被 kick。
3. **T10 单客户端回归**：`MAX_CLIENTS=1 SKIP_MIGRATION=1` 真机跑通（md5 一致、1 次装线）。
4. **一次自伤（写进纪律）**：我在 `usb-migration-demo.sh` **正在执行**的时候去编辑它，
   bash 是按字节偏移边读边执行的，于是后半段被读成了碎片
   （`syntax error near unexpected token 'then'`，`Z1=2`）。
   教训：**脚本运行期间不得修改该脚本**（以及运行期间不要重编它调用的二进制）。

### D27.5 CH 事件：我们的程序可以主动订阅（已实测）

CH 的 `--event-monitor` 支持 `fd=<n>`：它把那个 fd `File::from_raw_fd` 收走，并把每个事件写成
pretty JSON + 一个空行（`event_monitor/src/lib.rs`；写循环在
`vmm/src/lib.rs::start_event_monitor_thread`）。所以**我们自己开一个 socketpair、把一端当参数给它、
在另一端读**，就是主动推送订阅——不落盘、不扫日志、不轮询。

实测（新增 `guest/event-monitor-fd.py`，`fd=` 方式，一次最小 VM 启动）：

```
launching: cloud-hypervisor --api-socket …/api.sock --event-monitor fd=4 --memory size=512M …
  + 0.004s   vmm / starting
  + 0.004s   vmm / started
  + 0.008s    vm / booting
  + 0.407s    vm / booted          ← 事件到达与发出几乎同时（微秒级排队）
events received: 5
```

边界与注意：

- **不保证不丢**：监听线程用非阻塞 fd 写且 `write_all(...).ok()`，读端堵塞会静默丢事件；
  而且 JSON 与分隔符是两次 write，满缓冲时甚至会把一个事件截断。所以订阅端必须及时 drain。
- **同一份写入路径**：`path=` 与 `fd=` 只是 `Option<File>` 的两种来源，写循环完全一致，
  因此 E1 里看到的 `migration-started/paused/resumed/…` 同样会从 fd 出来。
- **不是 REST 订阅**：这个 CH 版本没有 HTTP 事件端点；D-Bus API（需 `dbus_api` feature）才有
  `monitor.subscribe()` 那种进程外推送。
- **seccomp 允许**：`common_thread_rules()` 无条件放行 `write`，socketpair 写入不受限。
- **usbvfiod 自己不能也不该订阅**：它是 vfio-user 后端，CH 连它、它没有 CH 的 API socket；
  把 VMM 协议与策略塞进设备后端会破坏"机制在 usbvfiod、策略在控制器"的分层与信任边界。
  能订阅的是**控制器/harness**（demo 里正是我们启动 CH 的）。
- 顺带解决 D25.6/12.2-M3 里那个"日志块缓冲导致控制器看不到候选"的问题：
  控制器的触发应当走 fd 订阅（或 M6 的阻塞式应答），而不是 tail 日志。

### D27.6 未完成、需要决策的一项

**M6 绑定式预检**（把"目标端注册的应答"挂住到控制器决定为止，见 §9.3）：
D26.3 已说明，这是让"缺东西就保持旧环境"成为**强制**语义的唯一办法。
它是**行为变更**（没有控制器时迁移会在预检窗口后失败），所以按 D22 的纪律，
我把它写成待批准项而没有自行实施。其余已知缺口：预检 A5（设备健康）仍无后端访问器；
T3/T4/T8 注入用例未跑；原始日志尚未归档到 `/mnt/mt`。
