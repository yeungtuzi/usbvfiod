# HANDOFF — usbvfiod 设备状态保持与 Live Migration 项目

> 用途：把本会话的工作从原服务器交接给**新的专用开发 PC**（100% 权限）。
> 阅读顺序：先看 §0/§1，再看 §5 关键技术结论，然后按 §8 启动新机器，最后按 §9/§10 继续开发。
> **本文件就在项目仓库内（`usbvfiod/HANDOFF.md`）：只需复制 `usbvfiod/` 目录，所有资料随仓库一起迁移。**
> （原工作区根目录另有一份同内容副本，但本次不复制工作区，因此以仓库内本文件为准。）

---

## 0. 交接摘要（TL;DR）

| 项 | 状态 |
|---|---|
| 需求 | ✅ 已确认并冻结（R1–R20，见 §4） |
| 架构与方案 | ✅ 已完成（架构报告 + 双语工作计划，见 §2/§4） |
| 代码实现 | ❌ **尚未开始任何代码改动**（本会话无 Rust 工具链、无 root） |
| 环境 | ⚠️ 原服务器无法跑 Cloud Hypervisor（无 `/dev/kvm` 权限） |
| 下一步 | 在新开发 PC 上执行 §8 启动清单，然后做 §9 的两个 Phase 0 关键实验 |

**本会话只产出文档，没有编译、没有改代码、没有跑过测试。** 接手者从零开始实现，文档即需求与设计依据。

---

## 1. 项目一句话

`usbvfiod` 是一个 Rust 写的 **vfio-user 后端**：它模拟一块虚拟 xHCI（USB 3.x）控制器，挂给 Cloud Hypervisor，并通过 Linux usbfs（`nusb`）把物理 USB 设备直通进 Guest。
本项目要在此之上实现 **设备状态保持 + Live Migration**（含 Guest 休眠/唤醒），目标是对 Guest 表现为「无断开、无 reset、无重枚举、上下文不变」。

- 上游仓库：`https://github.com/cyberus-technology/usbvfiod`
- 本地副本：独立克隆，**已移除 `origin`**（无 remote，不会被误 push）

---

## 2. 仓库清单（只需复制 `usbvfiod/`）

| 仓库内路径 | 内容 | 说明 |
|---|---|---|
| `./`（`usbvfiod/` 仓库根） | **项目仓库**（约 2.8 MB） | 独立克隆，保留完整 `.git`（1024 commits） |
| `HANDOFF.md` | 本文件 | 随仓库一起迁移 |
| `docs/` | 全部计划、报告与来源文档 | 见下表；**无任何文件在仓库之外** |

`usbvfiod/docs/` 下的文档：

| 文件 | 版本/行数 | 用途 |
|---|---|---|
| `usbvfiod-architecture-report.md` | 中文，约 428 行 | 架构与 Q1/Q2/Q3 分析报告 |
| `usb-vfiod-live-migration_cn.md` / `_en.md` | **v1.0，各 501 行** | **最终版计划**：只有最终需求（R1–R20）与实现计划，无来源对比 |
| `suspend-resume-plan_cn.md` / `_en.md` | v2.1，各 522 行 | 合并版计划，**含两份来源的对比与合并过程**（历史参考，勿删） |
| `ziyi-fu-discuss-for-da.md` | 8.7 KB | 归档的迁移论文提案（需求来源之一） |

### Git 状态（迁移前快照）
- HEAD：`4d2c5af768434e3889af6c50125e4df07918eff7`（2026-09-15，"Merge pull request #314 …"）
- 最新 tag：`v0.3.0`；`Cargo.toml` version `0.3.0`
- 工作树无代码改动；`git status --short` 显示 **7 个未跟踪文件**（5 个计划/来源文档 + 架构报告 + 本 HANDOFF）
- remote：无
- **建议接手第一步**：`git add -A && git commit -m "docs: architecture report + suspend/resume and live migration plans + handoff"`（本地提交，不 push）
- 若要拉上游更新：显式 `git remote add origin https://github.com/cyberus-technology/usbvfiod.git`

### 关键依赖版本（`Cargo.lock`）
`nusb 0.2.7`、`vfio_user 0.1.5`、`vmm-sys-util 0.15.0`、`tokio 1.53.1`、`memmap2 0.9.11`。
`deny.toml` 许可证白名单：`MIT`、`Apache-2.0`、`Unicode-3.0`、`BSD-3-Clause`。

---

## 3. 本会话已完成的工作

1. 克隆 usbvfiod 为独立项目（去 remote），通读全部源码（约 14.5k 行）与文档。
2. 产出架构报告 `docs/usbvfiod-architecture-report.md`，并回答三个问题：
   - Q1 是否支持 Cloud Hypervisor：**是，且 CH 是唯一主目标**（vfio-user `--user-device`）。
   - Q2 等时（isochronous）需做什么：**当前完全不支持**（nusb 无 isoch API、EP type 未识别、TRB 不解析、无周期调度）；详见报告。
   - Q3 是否支持完整 suspend/resume：**不支持**（无 PCI PM cap、无 save/restore、无 device-state region、HCRST 是破坏性重置）。
3. 合并两份需求（本机休眠/唤醒 + 迁移论文提案），确定统一模型。
4. 产出最终双语计划（`usb-vfiod-live-migration_*`）与含对比的合并版计划（`suspend-resume-plan_*`）。
5. 探测原服务器环境，产出开发计划（本文件 §7–§10）。

---

## 4. 最终需求（R1–R20）摘要

> 权威定义见 `docs/usb-vfiod-live-migration_cn.md` §3（英文见 `_en.md`）。

- **状态与语义**：R1 状态盘点分类；R2 版本化/CRC/前向兼容格式；R3 保存-恢复-重连；R4 边界 I/O 不丢不重、无重枚举；R5 迁移生命周期（pre-copy/stop-and-copy/停机/收敛）。
- **触发与传输**：R6 Guest 主动 suspend/resume（标准 PCI PM + paravirtual）；R7 VMM 主动迁移（vfio-user migration + CH/rust-vmm 集成）；R8 两者复用同一 quiesce/resume 生命周期；R9 支持 guest-cooperative 与 vCPU-pause only 两种变体。
- **设备与主机资源**：R10 `usbdev-agent` 保活设备会话（不 reset/不断开/不 autosuspend）；R11 usbvfiod 可独立重启/升级不丢设备；R12 物理设备迁移机制分析。
- **场景与边界**：R13 同主机 S3/S4/快照/重启；R14 同主机 live migration；R15 跨主机可行性判定；R16 迁移失败回滚（源端继续运行）。
- **评估/交付/约束**：R17 评估（正确性/连续性/停机/兼容/限制）；R18 QEMU 对照 + USB/IP 未来工作；R19 文档交付；R20 非 GPL 依赖白名单 + 最小权限。

**范围**：同主机为承诺交付；跨主机为可行性研究。
**硬性验收指标**：`lsusb -v` 前后一致、无 udev remove/add、**CSC/PRC=0、非请求 HCRST=0**、无 lost/duplicated I/O。

---

## 5. 关键技术结论（接手前必读）

1. **统一 quiesce/resume 生命周期**：三种触发（Guest S3/S4、VMM guest-cooperative、VMM vCPU-pause only）映射到同一状态机
   `RUNNING → PREPARING → READY → SUSPENDED/FROZEN → RESUMING → RUNNING`，并与 vfio-user migration 的 `PRE_COPY / STOP_COPY / STOP / RESUMING` 对齐。
2. **guest-cooperative 请求通道**：VMM → usbvfiod（migration state）→ paravirtual 控制块 `PV_HOST_REQ` → Guest helper 轮询 → `PREPARE/ENTER_SUSPEND` → usbvfiod READY → VMM 才暂停 vCPU。目的是让在途 I/O 在 blackout 前收敛。
3. **重要事实澄清**：stock live migration **只暂停 vCPU，不通知 Guest OS 进入 suspend**。物理 USB 要「不丢不重、不重枚举」必须 Guest 配合，这是本项目要补的能力，不是 CH 现成行为。
4. **架构主线**：`usbvfiod`（控制器核心，可重建）+ **`usbdev-agent`**（长生命周期，持有 fd/claim/endpoint，禁 reset/autosuspend）+ Guest helper + CH/rust-vmm 集成。复用现有 `RealDevice` trait，新增 `AgentRealDevice` 代理。
5. **状态模型三分**：controller-private（需序列化为 `ControllerState`）/ Guest RAM 内（context/ring，随 VM RAM 走，不重复保存）/ host kernel+device（不可序列化，靠 agent 保持 fd/claim 保全）。
6. **传输通道两条**：vfio-user migration region（主线）+ 本地状态文件 `/run/usbvfiod/<uuid>/state.bin`（Guest 休眠与降级）。
7. **两个 Phase 0 关键未知（必须先实测）**：
   - **A：CH 是否支持 Guest S3/S4**（CH 历史上偏 S5/reboot；若不支持，`systemctl suspend` 不生效）。
   - **B：CH 是否支持 `--user-device`（vfio-user）的迁移**（CH 只文档化过可迁移 VFIO 设备，未提 vfio-user）。
8. **零感知保证**：冻结 PORTSC/PORTPMSC、不改 context/dequeue pointer、不产生 Port Status Change Event、resume 后先校验 Guest RAM（DMA 重建）再放行 worker、Guest 侧避免 `XHCI_RESET_ON_RESUME`。
9. **Paravirtual ABI v1**：厂商 xECP + BAR0 控制块（建议 `0x1000`），寄存器 `MAGIC/ABI_VERSION/CMD/STATUS/ACK/COOKIE/DEADLINE_MS/ERR_DETAIL/HOST_REQ`；命令 `PREPARE/ENTER/ABORT/RESUME/QUERY`；详见计划文档附录 A。
10. **`ControllerState` schema 草案**：见计划文档附录 B。

---

## 6. 代码状态与改动锚点

**未写任何代码。** 计划中的文件级改动清单见 `docs/usb-vfiod-live-migration_cn.md` §11，摘要：

| 文件/组件 | 计划改动 |
|---|---|
| `src/device/pci/{constants,config_space,register_set,xhci}.rs` | PM capability/PMCSR、配置空间写回调、suspend/resume 钩子 |
| 新增 `src/device/xhci/suspend.rs` | `SuspendCoordinator`、状态机、quiesce |
| `src/device/xhci/{command_ring,slot_manager,interrupter,port,endpoint}.rs` | freeze/unfreeze、状态导入导出 |
| 新增 `src/state.rs` | `ControllerState`、序列化、版本/CRC |
| `src/xhci_backend.rs` | vfio-user migration/device-state region、`reset`/`dma_unmap`、DMA 校验 |
| 新增 `src/migration/` | 迁移状态机、CH 交互适配 |
| 新增 `src/agent/`（或独立 crate） | `usbdev-agent`、IPC、`AgentRealDevice` |
| 新增 `src/device/xhci/paravirt.rs` | 厂商 xECP 与控制块 |
| `src/main.rs`、`src/cli.rs`、`Cargo.toml` | 状态文件、agent socket、迁移参数、新依赖 |
| Cloud Hypervisor / rust-vmm | 若上游缺 vfio-user migration 支持则提交补丁 |

**现有代码关键锚点**（便于上手）：
- `src/main.rs` 组装 backend + vfio-user server；`src/xhci_backend.rs` 实现 `ServerBackend`（regions/irqs/DMA）。
- `src/device/pci/xhci.rs` xHCI MMIO 分发；`constants.rs` 能力值（只声明 xHCI 1.0、1 interrupter、8 slot、<4G）。
- `src/device/xhci/endpoint.rs` 端点状态机；`endpoint_handle.rs` TRB→host 传输；`nusb.rs` 后端（无 isoch）。
- `src/device/xhci/controller_reset.rs` 现有 HCRST 广播模式（`ResetSender`），新 quiesce 可仿照。
- `src/device/xhci/slot_manager.rs` 状态在 Guest 内存；`event_ring.rs` 生产者状态在进程内。

---

## 7. 原服务器环境探测结论（解释为何没跑起来）

| 项 | 现状 | 影响 |
|---|---|---|
| Ubuntu 22.04.5 / kernel 5.15 / x86_64 / AMD `svm` / 裸金属 | 可用 | 适合跑 KVM |
| 192 vCPU / 1.5 TiB RAM / 287 GB 可用 | 充足 | 可跑多实例 CH + QEMU |
| **root** | `sudo` 失败：*"no new privileges flag is set"* | 无法 apt/modprobe/改 udev |
| **`/dev/kvm`** | `root:kvm 0660`，用户不在 kvm 组 | **CH 无法启动** |
| **`/dev/bus/usb/*`** | `root:root 0664`，可读不可写 | **无法 claim USB 设备** |
| `/dev/net/tun` | 0666 但 `ip tuntap add` 需 CAP_NET_ADMIN | 不能建 tap |
| `/run` | 不可写 | 状态目录需改用户路径 |
| Rust / Nix / QEMU / CH | 均缺失 | 需安装 |
| `usbip`/`lsusb`/`gcc`/`git`/`curl`/`libclang` | 已有 | 可用 |
| 网络（rustup/crates/GitHub） | 均 200 可达 | 可下载 |
| USB 硬件 | 仅 Hub + BMC 虚拟键鼠（`046b:ff10`），无存储设备 | 需真实 U 盘或模拟 |

→ 该机只能做「文档/单测级」工作；集成验证全部留给新开发 PC。

---

## 8. 新开发 PC 启动清单（有 root，可全速）

> 目标：从复制目录到「CH + usbvfiod + 真实 USB 设备」跑通。

**Step 0 — 复制**
至少复制：`usbvfiod/`（含 `.git`）与 `usbvfiod-architecture-report.md`。不要复制工作区里无关的大文件。

**Step 1 — 系统依赖**
```bash
sudo apt update
sudo apt install -y build-essential pkg-config libssl-dev libseccomp-dev \
  qemu-system-x86 qemu-utils usbutils usbip jq socat tcpdump \
  linux-headers-$(uname -r)
```

**Step 2 — Rust 工具链**
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
. "$HOME/.cargo/env"
rustup component add clippy rustfmt
cargo install cargo-deny cargo-nextest --locked
```

**Step 3 — 构建与基线测试**
```bash
cd <repo>/usbvfiod
cargo build
cargo test
cargo clippy --all-targets -- --deny warnings
cargo deny check
```

**Step 4 — Cloud Hypervisor（建议源码构建，因为可能要打补丁）**
```bash
git clone https://github.com/cloud-hypervisor/cloud-hypervisor
cd cloud-hypervisor && git checkout <pinned-tag>   # 固定版本；迁移兼容从 v54 起
cargo build --release
# 产出 target/release/cloud-hypervisor 与 target/release/ch-remote
```

**Step 5 — 权限/内核（本机 root，直接配好）**
```bash
# KVM
sudo usermod -aG kvm "$USER"        # 重新登录生效
# USB 设备读写（开发期可用 plugdev，生产建议按 VID:PID 收窄）
echo 'SUBSYSTEM=="usb", MODE="0660", GROUP="plugdev"' | sudo tee /etc/udev/rules.d/70-usbvfiod.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
# 关闭 autosuspend（R10）
echo 'usbcore.autosuspend=-1' | sudo tee /etc/modprobe.d/usbvfiod.conf
# 可选：USB/IP
sudo modprobe usbip-core vhci-hcd
# 可选：状态目录（或改用 $XDG_RUNTIME_DIR）
sudo install -d -o "$USER" -g "$USER" -m 700 /run/usbvfiod
```

**Step 6 — USB 测试设备**
插一个 **USB 存储盘**（推荐）。**不要**用 BMC 虚拟键鼠做测试设备（会抢走远程键鼠）。无硬件时用 QEMU 嵌套拓扑（见仓库 `nix/checks/testutils.nix`）或 USB/IP。

**Step 7 — Guest 镜像**
- 最小：Debian netboot 的 `linux` + `initrd.gz`（CH 文档示例）。
- 测 suspend：Ubuntu/Debian cloud image（带 systemd）；可用 `mke2fs -d <dir>` 免挂载生成 ext4。

**Step 8 — Smoke test（CH + usbvfiod + 设备）**
```bash
# usbvfiod 必须先起，socket 必须先存在
cargo run --bin usbvfiod -- --socket-path "$XDG_RUNTIME_DIR/usbvfiod.sock" \
  --hotplug-socket-path "$XDG_RUNTIME_DIR/usb-hotplug.sock" -vv
# CH（注意 memory shared=on）
cloud-hypervisor --memory size=2G,shared=on \
  --kernel /path/linux --initramfs /path/initrd.gz --cmdline "console=ttyS0" \
  --serial tty --console off --api-socket "$XDG_RUNTIME_DIR/ch1.sock" \
  --user-device socket="$XDG_RUNTIME_DIR/usbvfiod.sock"
# 直通设备
cargo run --bin remote -- --socket "$XDG_RUNTIME_DIR/usb-hotplug.sock" --attach /dev/bus/usb/XXX/YYY
```

**Step 9 — 同主机 migration smoke test（CH 文档流程）**
```bash
# destination 空 VM
cloud-hypervisor --api-socket "$XDG_RUNTIME_DIR/ch2.sock"
ch-remote --api-socket "$XDG_RUNTIME_DIR/ch2.sock" \
  receive-migration receiver_url=unix:"$XDG_RUNTIME_DIR/mig.sock"
ch-remote --api-socket "$XDG_RUNTIME_DIR/ch1.sock" \
  send-migration destination_url=unix:"$XDG_RUNTIME_DIR/mig.sock",memory_mode=memfds,downtime_ms=300,timeout_strategy=cancel
```
关键点：UDS 用于同主机；`memory_mode=memfds` 需 `shared=on`；`timeout_strategy=cancel` = **迁移失败源端继续运行**（对应 R16）。

---

## 9. 接手后第一件事：两个 Phase 0 关键实验

**实验 A — CH Guest S3/S4 行为**
1. 用真实 Guest（systemd）在 CH 里执行 `systemctl suspend` / `echo disk > /sys/power/state`。
2. 打开 `xhci_pci.dyndbg==pmfl xhci_hcd.dyndbg==pmfl`，抓取 xhci 寄存器/命令全序列。
3. 判定：是否发 HCRST、是否 re-enumerate、CH 是否真的进入 S3。
4. 若 CH 不支持 S3：备选 = ① Guest helper 直接驱动 paravirtual quiesce（不依赖 OS suspend）；② 用 QEMU 作 S3 参考；③ 给 CH 加 S3（较大）。

**实验 B — CH 是否支持 `--user-device` 迁移**
1. 读 CH 源码/文档，确认 `--user-device` 是否有 migration/device-state 支持。
2. 直接尝试用 Step 9 的流程迁移一个挂了 usbvfiod 的 VM，记录失败点。
3. 若不支持：需要改 CH/rust-vmm；本机场景可先回退「本地状态文件 + agent 重绑定」。

**产出**：一份「CH 支持边界 + Guest 行为实测」文档，更新计划的 Phase 0 结论。

---

## 10. 建议的继续顺序

新机器权限齐全，可直接全速，但建议仍按依赖顺序：

1. §8 启动清单（环境）+ §9 两个实验（事实）。
2. **Phase 1 状态核心**（可先用 `MockRealDevice` 单测）：`ControllerState` 序列化/CRC、`SuspendCoordinator`/quiesce、零感知保证。
3. **Phase 2 Guest 休眠路径**：PM capability + 写回调、paravirtual xECP/控制块、Guest helper。
4. **Phase 3 VMM 迁移路径（主线）**：vfio-user migration region、CH/rust-vmm 集成、迁移状态机、回滚、同主机原型。
5. **Phase 4 agent 拆分**：`usbdev-agent` + IPC + `AgentRealDevice`；验证 usbvfiod 独立重启。
6. **Phase 5/6**：评估、QEMU 对照、跨主机分析、加固与文档。

详细任务分解（T0.x–T6.x）、验收标准、风险表见 `docs/usb-vfiod-live-migration_cn.md` §3/§4/§9–§14。

---

## 11. 开放问题 / 待你确认

1. 是否删除带来源对比的 `suspend-resume-plan_*`？还是保留为历史？
2. 是否把新文档挂到 `docs/overview.md` 的索引？
3. 跨主机是否要从「可行性研究」升级为「承诺实现」？（涉及第二台主机与 USB/IP）
4. 状态序列化格式选型（`bincode` / `postcard` / `ciborium`）。
5. CH 固定到哪个版本/tag（影响迁移兼容与是否需要补丁）。
6. Guest helper 形态：`systemd-sleep` hook（推荐先做）还是内核模块？

---

## 12. 参考

**仓库内**
- `usbvfiod/docs/usbvfiod-architecture-report.md`（架构 + Q1/Q2/Q3）
- `usbvfiod/docs/usb-vfiod-live-migration_cn.md` / `_en.md`（最终计划）
- `usbvfiod/docs/suspend-resume-plan_cn.md` / `_en.md`（含对比的合并版）
- `usbvfiod/docs/developers/architecture.md`、`docs/users/systemd.md`
- `usbvfiod/nix/checks/`（上游 NixOS + Cloud Hypervisor 集成测试，可借鉴拓扑）

**外部**
- Cloud Hypervisor VFIO-user HOWTO：https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vfio-user.md
- Cloud Hypervisor Live Migration：https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/live_migration.md
- vfio-user 协议规范：https://github.com/nutanix/libvfio-user/blob/master/docs/vfio-user.rst
- nusb 文档（注意无 isochronous API）：https://docs.rs/nusb/0.2.7/nusb/transfer/

---

## 13. 注意事项 / 已知坑

- vfio-user 要求 CH 侧 `--memory shared=on`。
- **usbvfiod 必须先启动**，socket 必须先存在，CH 才能连接。
- 同主机迁移用 UDS + `memory_mode=memfds`；`timeout_strategy=cancel` 才会在失败时保留源端。
- Host 侧 **autosuspend 必须关闭**（R10 要求设备不休眠）。
- 不要用 BMC 虚拟键鼠做直通测试设备。
- 本地克隆**没有 remote**，不会误 push；需要上游更新时显式添加 `origin`。
- 原服务器会话无 root、无 cargo，所以**仓库里没有任何编译产物**（无 `target/`）。
- 仓库 commit 时间在 2026 年（上游仍在活跃开发），拉取上游时注意 baseline 变化。

---

## 14. 复制建议

- **只需要复制 `usbvfiod/` 整个目录**（含 `.git`）。架构报告、计划文档、handoff 都已在本目录内：
  - `docs/usbvfiod-architecture-report.md`
  - `docs/usb-vfiod-live-migration_cn.md` / `_en.md`
  - `docs/suspend-resume-plan_cn.md` / `_en.md`
  - `docs/migration-paper-proposal.md`
  - `HANDOFF.md`（本文件）
- 工作区里其它目录与文件（`Lvllm/`、`vllm-xiaotu-moe/`、`ShareGPT_*.json` 等）与本项目无关，**不要复制**（`ShareGPT_V3_unfiltered_cleaned_split.json` 有 640 MB）。
- 复制到新机器后：`cd usbvfiod && git status`，确认 HEAD 为 `4d2c5af…`，再把未跟踪文件做一次本地提交：
  `git add -A && git commit -m "docs: architecture report + suspend/resume and live migration plans + handoff"`（不 push）。
