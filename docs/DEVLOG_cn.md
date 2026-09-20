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

## D6. 多客户端实现（进行中）

（实现与实测结果在下一条记录中追加。）

---
