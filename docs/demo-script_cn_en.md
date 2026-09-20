# USB 存储直通 Live Migration 演示脚本（中英双语）
# USB Passthrough Live Migration — Demo Script (Bilingual)

> 适用版本 / Applies to：usbvfiod（分支 `main`，含多客户端后端与两个交接修复）+ Cloud Hypervisor `v53.0-520` + 一键脚本 `guest/usb-migration-demo.sh`
> 实测结论 / Measured result：**20/20 通过**，停机 **4–21 ms**（中位 6 ms），复制跨越迁移，md5 完全一致，迁移后**零重枚举、零复位、零 I/O 错误**。
> 对照与注入 / Controls and injection：不迁移 8/8；release 构建 8/8（复制快约 4.5 倍）；关闭踢中断 7/8；朴素热拔插基线 0/3；故障注入「关闭归属守卫」0/5、「5 s 窗口关闭踢中断」2/8（8/8 对 2/8，$p=0.007$）。详见 `paper/main.pdf`、`docs/DEVLOG_cn.md` D15 与 `docs/review_report_cn.md` 第七部分。

---

## 0. 演示前提与准备 / Prerequisites & Setup

### 0.1 硬件与软件 / Hardware & software
| 项 / Item | 要求 / Requirement |
|---|---|
| U 盘 / USB stick | 专用存储盘，exfat，内含 `testfile.bin`（128 MiB） / dedicated storage stick, exfat, containing `testfile.bin` (128 MiB) |
| 设备节点 / Device node | `/dev/bus/usb/001/007`（用 `lsusb` 确认，宿主唯一存储类 USB） |
| Guest 镜像 / Guest image | `guest/rootfs.img` + `guest/initrd-custom.gz` + `guest/casper/vmlinuz` |
| 主机 / Host | 有 KVM + usbfs 权限；本演示同主机 / KVM + usbfs access; same host |
| 预期 md5 / Expected md5 | `d62dd28c4faf1bbe19e300a3b605e503`（见 `guest/testfile.md5`） |

### 0.2 演示前 30 秒自检 / 30-second pre-flight check
```console
$ lsusb | grep -i innostor                 # U 盘在位 / stick present
$ ls -l /dev/kvm                           # KVM 可用 / KVM available
$ cd <repo>/guest
$ ls -l rootfs.img initrd-custom.gz casper/vmlinuz    # 镜像就绪 / images ready
$ cat testfile.md5                         # 期望校验值 / expected checksum
```
> 若 U 盘被宿主自动挂载，脚本会自行处理；也可先 `for f in /media/root/*/; do umount "$f"; done`。
> If the host auto-mounted the stick the script handles it; you may also unmount it first.

### 0.3 两种演示方式 / Two ways to run

| 方式 / Mode | 命令 / Command | 适用 / Use for |
|---|---|---|
| 一键自动 / one-command | `cd guest && ./usb-migration-demo.sh` | 回归、录制 / regression, recording |
| **交互讲解 / narrated** | `cd guest && PAUSE=1 ./usb-migration-demo.sh` | **现场讲解**，每个节点等回车 / **live talk**, waits for Enter at each milestone |

两种方式都会在结束时打印同一张判定表。
Both end with the same verdict table.

---

## 1. 演示总览 / Demo at a glance

| 步骤 / Step | 操作 / Action | 看点 / What to watch | 时长 / Time |
|---|---|---|---|
| 1 | usbvfiod 抢占 U 盘 / usbvfiod claims the stick | 宿主 `/dev/sdb` 消失、驱动 `usb-storage → usbfs` | ~2 s |
| 2 | 启动源 VM / start source VM | Guest 内出现 `/dev/sda` 与虚拟 xHCI 控制器 | ~25 s |
| 3 | Guest 挂载并开始复制 / guest mounts & copies | 128 MiB 从 U 盘写入 Guest 本地盘 | 立即 / immediate |
| 4 | 发起 live migration / start migration | 停机 **毫秒级**；源进程退出、目标端 Running | ~2 s |
| 5 | 复制继续 / copy continues | 迁移后传输继续，Guest 心跳不断 | 数秒–数十秒 |
| 6 | 校验 / verify | md5 一致、无重枚举、无 reset | ~2 s |

**一句话主题 / One-line theme**
> 中：**Guest 正在从直通 U 盘复制文件时对 VM 做热迁移，复制不断、数据不变、Guest 无感知。**
> EN: **The VM is live-migrated while it is copying from a passed-through USB stick — the copy continues, the data matches, and the guest notices nothing.**

---

## 2. 讲解脚本 / Narration script

> 下面每一节给出：**操作 / Action** → **讲解词 / Narration** → **预期输出 / Expected output**。
> Each section gives: **Action** → **Narration** → **Expected output**.

### 开场 / Opening（约 30 秒 / ~30 s）

**中**
> "我们要演示的是 USB 设备直通下的虚拟机热迁移。
> 主机上插着一个 U 盘，通过 usbvfiod 以 vfio-user 协议直通给虚拟机；虚拟机正在从这个 U 盘复制一个 128 MB 的文件。
> 就在复制进行中，我们把虚拟机热迁移到同一个主机上的另一个 VMM 实例。
> 迁移完成后，复制继续、文件校验一致，而且虚拟机**从头到尾没有看到设备被拔插或重置**。
> 关键指标是：停机时间毫秒级、数据逐字节一致、Guest 无重枚举。"

**EN**
> "We're demonstrating live migration of a VM that has a USB device passed through.
> A USB stick is plugged into the host and passed through to the guest via usbvfiod using the vfio-user protocol. The guest is copying a 128 MB file from that stick.
> Right in the middle of the copy we live-migrate the VM to a second VMM instance on the same host.
> After the migration the copy continues, the file checksums match, and the guest **never sees the device disappear or reset**.
> The key numbers are: sub-20-millisecond downtime, byte-for-byte identical data, and zero re-enumeration in the guest."

---

### Step 1/6 — usbvfiod 抢占设备 / usbvfiod claims the device

**操作 / Action**
```console
$ cd <repo>/guest && PAUSE=1 ./usb-migration-demo.sh
```

**讲解词 / Narration**

**中**
> "第一步，usbvfiod 从宿主内核手里接管这支 U 盘。注意宿主侧的驱动会从 `usb-storage` 变成 `usbfs`，`/dev/sdb` 也随之消失——这证明设备已经完全交给用户态了。
> 这一步很关键：后面所有 USB 流量都由 usbvfiod 转发，宿主内核不再碰它。"

**EN**
> "First, usbvfiod takes the stick over from the host kernel. Watch the host driver change from `usb-storage` to `usbfs`, and `/dev/sdb` disappear — the device now belongs entirely to user space.
> That matters: from here on all USB traffic goes through usbvfiod and the host kernel no longer touches it."

**预期输出 / Expected**
```
[demo] ==== 1/6 usbvfiod claimed /dev/bus/usb/001/007 (host driver switched to usbfs) ====
```
（可现场加一句 / you may add：`$ lsusb -t | grep 'Dev 007'` → `Driver=usbfs`）

---

### Step 2/6 — 启动源虚拟机 / Boot the source VM

**讲解词 / Narration**

**中**
> "现在启动源虚拟机。Guest 里跑的是一块由 usbvfiod 模拟的 xHCI 控制器，U 盘挂在它的一个端口上。
> Guest 侧会看到标准的 USB 存储设备 `/dev/sda`，和真实硬件没有区别——Guest 不需要任何特殊驱动或改动。"

**EN**
> "Now we boot the source VM. Inside the guest, usbvfiod presents an emulated xHCI controller with the stick attached to one of its ports.
> The guest sees a completely standard USB mass-storage device, `/dev/sda`. No special driver, no guest modification — it looks like real hardware."

**预期输出 / Expected**
```
[demo] ==== 2/6 source VM booted; guest will mount the stick and start copying ====
```
（Guest 内 / inside the guest：`lsusb` 显示 `1f75:0903 Innostor`，`lsblk` 显示 `sda 29.8G`）

---

### Step 3/6 — Guest 开始复制 / The guest starts copying

**讲解词 / Narration**

**中**
> "Guest 自动挂载 U 盘并开始复制一个 128 MB 的文件。我们特意让复制持续足够久，好让迁移发生在复制过程中间。
> 这里请记住两件事：复制是从 U 盘读、写到 Guest 自己的磁盘；以及这个复制过程会跨越后面的迁移点。"

**EN**
> "The guest mounts the stick and starts copying a 128 MB file. We deliberately keep the copy long enough for the migration to land in the middle of it.
> Two things to remember: the copy reads from the stick and writes to the guest's own disk, and this copy will span the migration point."

**预期输出 / Expected**
```
[demo] ==== 3/6 copy in flight; waiting for 16 MiB of progress, then migrating ====
```

---

### Step 4/6 — 发起热迁移 / Start the live migration

**讲解词 / Narration**

**中**
> "现在发起热迁移。目标端是一个空的 Cloud Hypervisor 实例。
> 我们用的是同主机迁移：内存用 `memory_mode=memfds`，也就是源和目标**映射同一份 Guest 内存**，所以迁移几乎是瞬时的——实测停机只有几毫秒。
> 同时，usbvfiod 会把设备同时服务给两个连接：源端还没断开，目标端就已经接上来了。这正是我们改动的核心。"

**EN**
> "Now we start the live migration. The destination is an empty Cloud Hypervisor instance.
> This is a same-host migration using `memory_mode=memfds`: source and destination map the *same* guest memory, so the migration is nearly instantaneous — we measure only a few milliseconds of downtime.
> At the same time usbvfiod serves two connections at once: the destination attaches before the source has disconnected. That is exactly the change we made."

**预期输出 / Expected**
```
[demo] ==== 4/6 starting the live migration ====
[demo] send-migration exit=0
[demo] ==== 5/6 migration issued; the copy must continue on the destination ====
```
（随后判定表 / later in the verdict：`Migration completed after 0.0s with a downtime of Nms`）

---

### Step 5/6 — 复制继续 / The copy continues

**讲解词 / Narration**

**中**
> "迁移已经完成：源端进程退出，目标端接管了同一个虚拟机。
> 关键点在这里——USB 设备和主机侧的会话**从来没有中断过**：usbvfiod 一直持有这个设备，端点、寄存器、以及 Guest 内存里的传输环都原样保留。
> 所以 Guest 只是'停顿了几毫秒'，然后从断点继续复制，它并不知道背后换了 VMM。"

**EN**
> "The migration is done: the source process exited and the destination took over the very same VM.
> Here is the key point — the USB device and its host-side session **never went away**: usbvfiod held on to the device the whole time, keeping the endpoints, the controller registers and the transfer rings in guest memory intact.
> So the guest simply paused for a few milliseconds and then carried on from where it left off. It has no idea the VMM changed underneath it."

**说明（可选深入）/ Optional deep dive**
> 中：迁移窗口内可能有一个已完成的传输，其中断打到了即将退出的源端；我们用"**新客户端注册中断后补发一次踢中断**"让 Guest 重新扫描事件环，把这个窗口补齐。
> EN: A transfer completing inside the hand-over window may have its interrupt delivered to the VMM that is exiting. We **re-raise one interrupt when the new client registers its line**, so the guest re-scans the event ring and picks up that completion.

---

### Step 6/6 — 校验 / Verification

**讲解词 / Narration**

**中**
> "最后看结论。我们从 Guest 自己的日志里取数据——不是靠宿主观测，而是 Guest 内部真实的复制结果：
> 复制窗口完整地跨过了迁移点；复制返回码 0；U 盘上原文件和 Guest 里复制出来的文件 **md5 完全一致**；
> 而且迁移之后 Guest 没有发生任何一次设备重枚举、没有 reset、没有 I/O 错误。"

**EN**
> "Finally, the verdict. These numbers come from the guest's own log — not from host-side observation, but from the real copy inside the guest:
> the copy window fully spans the migration point, the copy exited with status 0, and the md5 of the copied file **exactly matches** the original on the stick.
> And after the migration there is not a single re-enumeration, reset or I/O error."

**预期输出 / Expected**
```
migration line       : Migration completed after 0.0s with a downtime of 4ms (goal was 300ms)
spans migration      : YES (start before, end after)
MD5 VERDICT          : MATCH
enumerations after migration : 0 (expected: 0 = no re-enumeration at/after the migration)
(no resets / no I/O errors)
```

---

## 3. 结论与数据 / Verdict and numbers

**中**
> 总结三句话：**第一，迁移期间 USB 数据面没有中断**——128 MB 复制完整跨越迁移；**第二，数据正确**——逐字节一致；**第三，Guest 无感知**——无重枚举、无 reset、无错误。停机时间 4–21 毫秒，远低于我们 2 秒的目标；关闭踢中断的负对照与放大窗口的注入实验进一步证明修复是承重的（见 `paper/main.pdf`）。

**EN**
> Three takeaways: **one, the USB data path never broke** — the full 128 MB copy spans the migration; **two, the data is correct** — byte-for-byte identical; **three, the guest is undisturbed** — no re-enumeration, no reset, no errors. Downtime was 4–21 ms, far below our 2-second target.

| 指标 / Metric | 目标 / Target | 实测 / Measured（20 次 / runs） |
|---|---|---|
| 停机时间 / downtime | ≤ 2000 ms | **4–21 ms**（中位 6） |
| 复制跨越迁移 / copy spans migration | 必须 / required | **20/20 YES**（含切换完成时刻） |
| md5 | 与源一致 / identical | **20/20 MATCH** |
| 迁移后重枚举 / re-enumeration after migration | 0 | **0** |
| reset / I/O 错误 / reset / I/O errors | 0 | **0** |
| Guest 存活 / guest alive | 是 / yes | 心跳持续 + `rc=0` |

---

## 4. 预设问答 / Anticipated Q&A

**Q1：Guest 真的完全无感吗？**
> 中：USB 设备层面是——没有重枚举、没有 reset、数据一致。但有一个已知的、与 USB 无关的扰动：迁移后 Guest 的**串口控制台会重印登录横幅**，因为目标端重建了串口设备，导致 Guest 的 tty 被重置。要做到连串口都零感知，需要在 CH 侧保留串口设备实例。
> EN: At the USB level, yes — no re-enumeration, no reset, matching data. There is one known disturbance unrelated to USB: after the migration the guest's **serial console reprints its login banner**, because the destination re-creates the serial device and that resets the guest tty. Making even that invisible would require CH to preserve the serial device instance.

**Q2：为什么需要改 usbvfiod？原来的问题是什么？**
> 中：原来 usbvfiod 只接受**一个** vfio-user 连接。迁移时目标端要连接，但源端还没断开，于是目标端永远卡在协议握手上——实测 200 秒零进展。我们发现握手类命令（`Version`、`DeviceGetInfo` 等）根本不碰设备后端，所以把后端锁改成**按命令加锁**而不是按连接持有，就能同时服务两个连接。
> EN: Originally usbvfiod accepted exactly **one** vfio-user connection. During a migration the destination connects while the source is still connected, so the destination blocked forever in the protocol handshake — we measured 200 seconds with zero progress. We found that the handshake commands (`Version`, `DeviceGetInfo`, …) never touch the device backend, so taking the backend lock **per command** instead of per connection lets both connections be served.

**Q3：需要改 Cloud Hypervisor 吗？**
> 中：不需要改代码。CH 只需要一个 `Cargo.toml` 的 `[patch.crates-io]` 指向我们修好的 `vfio_user` crate（修的是 `resettable` 标志解析取反的 bug）。这个 crate 修复已作为草稿 PR 提交给上游。
> EN: No code change. CH only needs a `[patch.crates-io]` entry pointing at our fixed `vfio_user` crate (the fix corrects an inverted `resettable` flag parse). That crate fix is proposed upstream as a draft PR.

**Q4：如果 U 盘在迁移过程中被物理拔出会怎样？**
> 中：那是另一种情况，当前不保证零感知——设备真的消失了，Guest 会看到断开。我们记录为明确的限制。
> EN: That is a different scenario and we do not claim zero-perception there — the device really is gone and the guest will see a disconnect. We record it as an explicit limitation.

**Q5：跨主机迁移呢？**
> 中：跨主机需要把设备状态显式搬过去（vfio-user 的 device-state region）或在目标主机提供等效设备，当前只做了可行性分析，不在本次演示范围。
> EN: Cross-host would require explicitly transferring device state (a vfio-user device-state region) or providing an equivalent device on the target host. We only did a feasibility analysis; it is out of scope for this demo.

**Q6：这个演示能重复吗？**
> 中：能。修复后连续 20 次全部通过（另有不迁移对照、release 构建臂与注入实验，见 `docs/DEVLOG_cn.md` D15）；`./usb-migration-demo.sh` 一条命令即可重跑并打印判定表。
> EN: Yes. After the fix we ran it 20 times in a row with 20 passes (plus a no-migration control, a release-build arm, a kick-disabled negative control, a naive detach/re-attach baseline and a fault-injection suite; see `docs/DEVLOG_cn.md` D15). `./usb-migration-demo.sh` reruns it and prints the verdict table.

---

## 5. 故障处理 / Troubleshooting

| 现象 / Symptom | 原因 / Cause | 处理 / Fix |
|---|---|---|
| `usbvfiod did not attach` | 设备被宿主挂载 / stick still mounted | `for f in /media/root/*/; do umount "$f"; done`，确认 `/dev/bus/usb/001/007` 存在 |
| Guest 里没有 `/dev/sda` | exfat 模块缺失 / exfat module missing | 重新 `./build-guest.sh`（会合并 `linux-modules-extra`） |
| 复制卡住且无报错 | 旧二进制 / stale binary | `cargo build` 后重跑（**改完源码必须重建**） |
| 判定表显示 `guest log NOT AVAILABLE` | 镜像挂载失败 / mount failed | 确认没有残留 CH 进程占用镜像；脚本会用 rw 挂载回放 ext4 日志 |
| 判定表 `spans migration: NO` | 迁移请求或切换完成落在复制之外 / migration not inside the copy | 检查 Guest 心跳的 `copied=` 是否被正确识别；必要时调小 `COPY_TRIGGER_BYTES`（默认 16 MiB）。**不要**用固定墙钟延迟去凑——release 构建的复制比 debug 快约 4.5 倍 |
| `MISMATCH` | 数据面真正出错 / real data-path bug | 保留 `$RUN/{guest-demo.log,usb.pcap,usbvfiod.log}` 用于分析 |

---

## 6. 速查卡 / Cheat sheet（演示时贴屏 / keep on screen）

```console
# 一键演示 / one-command
cd <repo>/guest && ./usb-migration-demo.sh

# 交互讲解（每步等回车）/ narrated (Enter at each step)
cd <repo>/guest && PAUSE=1 ./usb-migration-demo.sh

# 只看结论 / verdict only
./usb-migration-demo.sh | tail -20

# 产物 / artifacts
$RUN/{console.log,guest-demo.log,src.log,dst.log,usbvfiod.log,usb.pcap} (batches now use RUNROOT on disk, e.g. /root/usb-runs)

# 关键期望值 / key expected value
d62dd28c4faf1bbe19e300a3b605e503   # testfile.bin md5
```

**判定通过的四个必要条件 / The four pass conditions**
1. `spans migration : YES` — 复制跨越了迁移 / the copy spans the migration
2. `MD5 VERDICT : MATCH` — 数据逐字节一致 / data identical
3. `enumerations after migration : 0` — 迁移后无重枚举 / no re-enumeration
4. `(no resets / no I/O errors)` — 无 reset、无 I/O 错误 / no resets, no I/O errors
