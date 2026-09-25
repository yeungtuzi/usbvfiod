# 论文预评审报告 / Pre-submission Review Report

对象：`paper/main.tex`（IEEE 会议格式，8 页）+ `paper/abstract_zh.tex`（中文摘要）
日期：2026-09-20

---

## 第一部分：在线 AI 预评审服务调研（均已逐一核实）

> 核实方式：对每个候选服务实际发起 HTTP 请求并读取返回页面标题，仅列出**确认存在**的服务。
> 核实日期：2026-09-20。

### 1.1 英文论文（本文主件）

| 服务 | 定位 | 链接 | 核实结果 |
|---|---|---|---|
| **Paperpal** | 英文科技写作辅助 + 投稿前检查（语言、结构、期刊合规） | https://www.paperpal.com/ | 200 ✅ |
| **Writefull** | 基于语料库的学术语言检查 | https://www.writefull.com/ | 200 ✅ |
| **Trinka** | AI 语法/学术写作检查 | https://www.trinka.ai/ | 200 ✅（页面标题：*Trinka: AI Writing and Grammar Checker Tool*） |
| **Editage（意得辑）** | 人工+AI 润色与科研支持（付费服务） | https://www.editage.cn/ | 200 ✅ |
| **SciSpace** | 文献阅读 + 写作辅助 | https://scispace.com/ | 站点存在，但本机直连返回 403（需浏览器访问） |

### 1.2 中文论文 / 中文场景

| 服务 | 定位 | 链接 | 核实结果 |
|---|---|---|---|
| **华算 AI 智评（超算互联网）** | 一站式学术评阅，面向中文论文的 AI 评审 | https://www.scnet.cn/home/news/122552.html | 200 ✅（页面标题：*用AI打造一站式学术评阅｜在超算互联网体验全新华算AI智评*） |

> 注：知网/万方/维普的「检测」是**抄袭/文字复制比**与 AIGC 检测，不是学术内容评审；各校研究生院通常另有内部预审平台（如「学位论文预审系统」），请以你所在学校的通知为准。

### 1.3 学术界的自动化评审研究（可了解其能力与局限）

| 工作 | 说明 | 链接 | 核实结果 |
|---|---|---|---|
| **OpenAIReview**（芝加哥大学 Data Science Institute） | 面向同行评审的辅助工具研究 | https://datascience.uchicago.edu/insights/openaireview/ | 200 ✅（标题：*UChicago Researchers Build a Tool to Help Fix Peer Review*） |
| **Graph-Guided Passage Retrieval for Author-Centric Structured Feedback**（arXiv 2505.14376） | 面向作者的自动结构化反馈 | https://arxiv.org/abs/2505.14376 | 200 ✅ |

> ⚠️ 检索结果中有把该 arXiv 条目称为 "AutoRev" 的说法，但**其页面真实标题如上**；本文只采用核实过的标题，不采用检索摘要中的名称。

### 1.4 使用在线服务前必须知道的三点风险

1. **保密与首发权**：投稿前把未发表稿件上传到第三方服务，可能触及其服务条款中的数据留存/训练条款；部分期刊把「已公开」视为失去新颖性。若论文涉及未公开的设备/漏洞细节，风险更高。
2. **AIGC 检测与学术规范**：目前多数高校对**AI 生成内容**有明确规定（需声明、或设定 AIGC 占比上限），且会做 AIGC 检测。本稿是 AI 辅助生成的初稿，**你必须按所在学校的规定处理**（重写为自己的表述/按要求声明），否则可能在检测环节出问题。这一点比"评审意见"更要紧。
3. **通用写作服务的局限**：Paperpal/Trinka 这类工具擅长语言与格式，**不擅长系统类论文的技术论证与实验方法学**。对本文真正有价值的是同行评议式的技术审查（见第二部分）。

---

## 第二部分：本地多智能体评审团意见（轮次 1）

> 三位审稿人在本机运行（稿件未上传外部服务）。结论如下（**原文摘要**）。

| 审稿人 | 结论 | 核心问题 |
|---|---|---|
| 系统方向（SOSP/OSDI 标准） | **Reject** | ① 新颖性未定位（未对比 QEMU vfio-user migration 系列、既往 USB 迁移工作）② **re-raise 修复与事件 worker 存在真实竞态** ③ 无失败/回滚路径 ④ 评估规模不足（10 次、单设备、无基线、无消融、无开销）⑤ "transparent/zero-perception" 测量不足 ⑥ 多客户端未加固（assert 可打崩线程、无连接上限、socket 世界可连） |
| 实验方法学 | **Major revision** | ① 10/10 对"修复前约 1/5 失败率"**统计上不显著**（p≈0.107）② "迁移后无枚举"判据用固定 >30s 阈值，而迁移发生在 guest uptime ~14.6s，**该判据实际不可能触发** ③ 两项判据取自被本文自己证明不可靠的串口 ④ 图 4/5 取自**不在 10 次表内**的运行，且图 5 不是受控 A/B ⑤ 宿主同时跑 4 台 VM、调试构建 + `-v` + pcap **未披露** ⑥ 无迁移对照、无缓存控制、无时钟域处理 |
| 写作与格式 | **Major revision** | 引用未按首次引用顺序、2 条未被引用、缺访问日期、作者占位、无工件链接；表 I 的 "virtio-usb" 行引用了 VIRTIO 1.2（**该规范没有 USB 设备类型**）；表 IV 与正文重复；图 2 时序颠倒、图 1 花括号指向错误的参与者；约 50 处文字问题 |

**审稿人指出的最有价值的一条**：系统审稿人在 `usbvfiod.log` 中找到证据，说明交接窗口的竞态**确实在成功运行中发生过**（完成事件 05:33:26.749 → 新中断线安装 26.758），而论文完全没有报告这一点。方法学审稿人同样指出："应当把它作为曝光证据写出来"。

---

## 第三部分：轮次 1 修改行动清单（已完成项）

| # | 来源 | 意见 | 处理 | 证据 |
|---|---|---|---|---|
| 1 | 系统 M2 | re-raise 在调用线程执行，与事件 worker 无序 | **把踢中断移入 `interrupter` worker 的 `UpdateInterruptLine` 分支**，保证排在前面的 SendEvent 已入队后才踢 | `src/device/xhci/interrupter.rs`；`xhci_backend.rs` 中删除调用线程的 kick |
| 2 | 系统 M6 | `set_irqs` 的 `assert!` 可被畸形客户端打崩 | 改为返回 `io::Error` | `src/xhci_backend.rs` |
| 3 | 系统 M1 | 未定位相关工作 | 补 **QEMU `[PATCH v2 0/8] vfio-user: live migration support`（Hugo Komatsu, 2026-09，已核实）** 与 **Watanabe et al., SAINT 2010（已核实，doi:10.1109/SAINT.2010.59）**，并明确本文是"同主机保会话"而非"搬状态" | `refs.bib`、§II-B |
| 4 | 系统 M3 | 无失败/回滚路径 | 新增 `Failure and rollback` 限制段落，如实说明 `timeout_strategy=cancel` 未能恢复源端 | §VII |
| 5 | 系统 M8 | DmaUnmap 未被证据支持 | 明确写出"只观察到 IRQ-disable 一半，DmaUnmap 实现了但本工作负载未触发" | §IV-C |
| 6 | 方法学 | 枚举判据阈值错误 | 新增 `guest/verdict.py`：**以 Guest 自身 uptime 在迁移时刻为界**判定枚举/复位/IO 错误 | 实测输出 `guest uptime @migr. 15.43 s` / `enumerations after migration 0` |
| 7 | 方法学 | 判据取自不可靠串口 | Guest 侧在复制后追加 `dmesg` + `lsusb` 到 `/root/demo.log`，判定全部取自 Guest 日志 | `guest/build-guest.sh` |
| 8 | 方法学 | 判定标记不持久 | `sync` → 写 `MD5_DONE` → 再 `sync` | 同上；本次实测 `MD5_DONE marker: present` |
| 9 | 方法学 | 统计不足 | 论文加入 Clopper–Pearson 区间（10/10 → [0.74,1.0]，残余失败率上界 ≈26%）、与修复前比较不显著（Fisher p≈0.33）、双峰/时间聚集的说明；新增 `guest/acceptance-batch.sh` + `guest/summarize-batch.py`（CSV + CI） | §VI-B |
| 10 | 方法学 | 混淆因素未披露 | 实验环境披露：宿主同时运行 4 台 KVM VM、无 CPU 绑定、调试构建 + `-v` + pcap、Guest 2 GiB/1 vCPU、设备型号 | §III-A |
| 11 | 方法学 | 缺效度威胁 | 新增 `Threats to validity` 小节（构念/内部/外部/统计四类） | §VI-G |
| 12 | 写作 M1/M2 | 引用顺序、未引用条目、缺访问日期 | 改用 **BibTeX + IEEEtran 样式**（自动按引用顺序）；每条补 `Accessed: 2026-09-20`；未引用条目不再出现 | `refs.bib`（22 条） |
| 13 | 写作 | "virtio-usb" 引用不成立 | 表 I 重写为五行：本文方案 / USB-IP / QEMU `usb-host` / usbredir / 内核 VFIO 迁移，并修正各行描述 | §II 表 I |
| 14 | 写作 | 标题/摘要 overclaim | 标题去掉 "Transparent"；摘要改为 "at the USB level"，并补上 crate 修复 | `main.tex` |
| 15 | 写作 | 图 1/2 结构问题 | 图 1 区分 source/destination VMM 并修正花括号范围；图 2 按真实时间顺序重绘并加时间轴 | `figures/arch.tex`、`figures/deadlock.tex` |
| 16 | 写作 | 图 4/5 来源不明 | 图注明确标注"演示运行，不属于表 III 的十次验收" | §VI-C/VI-D |
| 17 | 写作 | "without changing the VMM" | 改为"未修改 VMM 源码，但需要针对修复后的 crate 重新构建 CH" | 摘要、§IV-A、§V-C |
| 18 | 双方 | 每轮曝光证据 | usbvfiod 在安装新中断线并补发踢中断时打日志；harness 报告每轮 `kicks`/`stale teardown` 计数 | `interrupter.rs`、`usb-migration-demo.sh` |

## 第四部分：仍未完成的评审意见（如实记录）

| 意见 | 状态 | 原因 / 计划 |
|---|---|---|
| 确定性竞态注入测试（P0） | **未完成** | 需要在 usbvfiod 中加入测试钩子（人为放大交接窗口）。计划下一轮以 `#[cfg(debug_assertions)]` 环境变量钩子实现，并跑"放大窗口仍能恢复"的对照 |
| 100+ 次运行 / 更窄的 CI | **部分** | 已启动 20 次迁移 + 8 次无迁移对照 + 8 次 release 构建批次；更大规模留待下一轮 |
| 重枚举基线（detach/re-attach 的中断时长） | **未完成** | 需要实现"不做迁移、直接热拔插"的对照组 |
| per-command 锁与无条件踢中断的开销 | **未完成** | 需要 micro-benchmark 或 release vs debug 对比（批次中包含 release 组） |
| 多设备 / 多控制器 / USB 3.0 UAS | **未完成** | 需要额外硬件 |
| 约 50 处文字润色 | **部分** | 已处理结构性条目；逐句润色留待写作审稿人下一轮复核 |


---

## 第五部分：轮次 2 评审结论（2026-09-20）

三位**全新**审稿人以"硕士答辩 / 系统工作坊"为标尺复核，并逐条核验了轮次 1 的修复。

| 审稿人 | 轮次 1 | **轮次 2** | 残留问题 |
|---|---|---|---|
| 系统方向 | Reject | **MINOR REVISION**（borderline accept） | 6 项修复全部确认为"真正解决"；新发现 **ownership 守卫 TOCTOU**（已修）；建议补确定性注入测试与基线 |
| 实验方法学 | Major Revision | **MINOR REVISION** | 判定已全部取自 Guest 日志、以迁移时刻 uptime 为界（已用真实数据复算验证）；新发现**判定脚本 fail-open**（心跳缺失时判据空转 → PASS，审稿人用注入实验证明）、正则覆盖不全、批脚本解析错位、CP 数字标注错误 |
| 写作格式 | Major Revision | **MINOR REVISION** | 引用顺序/未引用/访问日期全部通过；新发现**三条引用不成立**（我引的页面根本没有相应内容，审稿人逐个 fetch 核验） |

### 本轮的实质性收获（审稿人发现、我已复验并修复）

1. **ownership 守卫 TOCTOU**（系统审稿人）：`owns_device()` 在取后端锁**之前**检查，`irq_owner` 在**释放锁之后**写入。中间窗口里，正在退出的源端可以插入一次"关闭中断"，把目标端刚装上的线替换成 dummy —— 正是该守卫要防的故障。**修复**：新增 `control: Mutex<()>`，把"检查 + 后端变更 + 归属写入"合并为一个临界区。
2. **判定脚本 fail-open**（方法学审稿人，附可复现的注入实验）：心跳行缺失时 `mig_uptime=None`，dmesg 循环全部 `continue` → `late_enum=late_bad=0` → **PASS**。**修复**：心跳与 dmesg 现在是**必需**项，缺失即 FAIL；并强制 `src==expected`、检查复制退出码、加宽正则（low/full/high/SuperSpeed、`USB disconnect`、端口 reset）、把 downtime 纳入判据。
3. **三条引用不成立**（写作审稿人 fetch 核验）：
   - `docs.kernel.org/driver-api/vfio.html` —— **全文 0 次提及 migration**，我却用它引"VFIO 迁移接口"。已改为 Linux 内核 UAPI 头文件 `include/uapi/linux/vfio.h`（已核实含 16 处 VFIO migration 符号）。
   - QEMU `usb.html` —— **0 次提及 redirection/usbredir**。已改为 SPICE `usbredir` 页面（已核实）。
   - usb-host "迁移被拒绝" —— 该页无此内容。已改为 libvirt `formatdomain` 文档（已核实含 "can't be interchanged during migration" 原文）。
4. **统计标注错误**（方法学审稿人复算）：`[0.74,1.0]` 是**单侧** 95% 下界，不是双侧区间；双侧 Clopper–Pearson 为 `[0.69,1.0]`；残余失败率单侧上界为 **26%**（`1-0.05^{1/10}`）。已按此精确标注，并把汇总脚本改为同时输出单侧与双侧。
5. **`rc=$?` 恒为 0**（方法学审稿人）：`say "… rc=$?"` 里的 `$(date …)` 会重置 `$?`，所以 dd 的退出码永远显示 0。已改为先捕获 `dd_rc=$?`。
6. **批脚本 5/8 列解析错位、内联 CP 算法错误、相对路径**：已重写，聚合统一交给 `summarize-batch.py`（并新增 bootstrap 中位数区间与 Fisher 精确检验）。
7. **Table IV 只列 3 个缺陷，实际修了 4 个**（漏了 crate 解析 bug），摘要"two further defects"却列了三项：已统一为四项。

### 本轮新增的验证能力
| 能力 | 说明 |
|---|---|
| `guest/verdict.py`（重写） | 判据全部取自 Guest 日志；以迁移时刻 uptime 为界；**缺失证据即 FAIL（fail-closed）**；含 downtime 预算判据 |
| `guest/acceptance-batch.sh` + `summarize-batch.py` | N 次运行 → CSV；pass rate + **双侧 Clopper–Pearson** + **bootstrap 中位数区间** + 两臂 **Fisher 精确检验** |
| `guest/irq-kick-ab.sh` + `USBVFIOD_DISABLE_IRQ_KICK` | **受控 A/B 负对照**：同一二进制内关闭踢中断，用于证明机制而非"碰巧通过" |
| `guest/replug-baseline.sh` | "朴素方案"基线：不迁移、直接热拔插，测 Guest 侧代价 |
| `guest/collect-artifacts.sh` | 全部原始文件（含 pcap）留档 + `SHA256SUMS` + `MANIFEST.md` |
| `guest/sample-host-load.sh` + `artifacts/host-load.log` | 批次期间宿主负载采样，用于归因运行间差异 |
| `paper/update-results.py` | 论文表格与全部数字宏**由 CSV 自动生成**，杜绝手工抄写 |

### 仍未满足（如实记录，下一轮处理）
| 项 | 状态 |
|---|---|
| 更大样本量（20 migrate + 8 control + 8 release + 8 kick-off A/B + 3 基线） | **正在运行** |
| 确定性的交接窗口注入测试 | 已有可开关负对照（kick-off 臂）；**放大窗口**的注入钩子未实现 |
| 多设备 / USB 3.0 UAS / 跨主机 | 无硬件，保持为已声明范围外 |
| 作者/单位占位符 | **需用户填写**（我不能编造） |

---

## 第六部分：轮次 3 的改进内容（2026-09-20）

轮次 2 的三位审稿人都给出 **MINOR REVISION**，共同指出的下一步是：**证据规模不足、缺少负对照与确定性注入**。
本部分记录针对这一点的实际改动。审稿人的逐条复核结论见第七部分（评审完成后补）。

### 6.1 从"一次通过"升级为"多臂对照"

| 臂 | 运行次数 | 构建 | 迁移 | 目的 |
|---|---|---|---|---|
| `debug`（验收） | 20 | debug | 是 | 主结果 |
| `control` | 8 | debug | **否** | 证明工作负载本身不会产生该结果 |
| `release` | 8 | release | 是 | 证明结论不是调试构建/插桩的产物 |
| `kickoff` | 8 | debug（关闭踢中断） | 是 | **负对照**：踢中断是否承重 |
| `replug` | 3 | debug | 否（热拔插） | **朴素方案基线**：不迁移、直接 detach/attach |

所有臂由同一个 harness（`guest/campaign-b.sh`）产生，判定脚本与验收判据完全相同
（`guest/verdict.py`，全部取自 Guest 自身日志）。

### 6.2 从"碰巧暴露"升级为"按构造暴露"（确定性注入）

`guest/injection-suite.sh` 用两个**编译期休眠、运行时可开**的钩子（仅 debug 构建）构造四臂：

| 臂 | 钩子 | 预期 |
|---|---|---|
| `baseline` | 无（钩子存在但不启用） | PASS（证明钩子惰性） |
| `window` | 交接前延迟 500 ms；踢中断开 | PASS（踢中断覆盖被放大的窗口） |
| `window-loss` | 交接前延迟 500 ms；踢中断关 | FAIL（窗口本身是真实危害） |
| `guard-off` | 关闭归属守卫 | FAIL（守卫承重） |

**注入点为什么在 `set_irqs` 而不是 interrupter worker**：只有延迟"把新中断线交给 worker"这一刻，
旧线才会在延迟期间持续被写入；若把延迟放在 worker 的换线分支里，延迟期间到达的事件会排在换线消息之后，
醒来后一律走新线，暴露反而被**缩小**。

### 6.3 由一个对照臂揪出的 harness 缺陷（本轮最重要的方法学收获）

release 臂第 1 次运行就 `spans=NO` + FAIL（`md5=MATCH`）。根因不在设备代码，而在 harness：
它在 `COPY_START` 后固定 `sleep 4`，再花约 3.5 s 启动目标端，最后才请求迁移。
debug 构建复制要 13–38 s，所以从未暴露；**release 构建只要 6.3 s**，于是"复制已结束、迁移才发起"。
修复：Guest 心跳上报 `copied=B`（`build-guest.sh`），harness 按**复制比例**（16 MiB）触发迁移；
并把判据从"包含迁移请求"加强为"包含**整个**迁移"（新增 `migration.done`，
要求 `COPY_START < epoch <= done < COPY_DONE`）。整批因此重跑（旧批留档为
`artifacts/campaign-A-fixed-lead/`）。详见 `docs/DEVLOG_cn.md` 的 D12。

### 6.4 作者块

按用户决定采用**双盲匿名**：`paper/main.tex` 与 `paper/abstract_zh.tex` 的作者/单位/邮箱占位符已替换为
规范的匿名投稿表述；正文中的仓库 URL（会泄露身份）也已移除，改为"随投稿提供工件、为双盲隐去位置"。

### 6.5 待补

- 第七部分：轮次 3 三位审稿人的逐条结论与残留问题。
- 更大样本（>20）与跨主机方案展望（后者声明为范围外）。

### 6.6 本轮实测结果（2026-09-20 完成）

| 臂 | 通过 | 备注 |
|---|---|---|
| debug 迁移 | 20/20 | 停机 4–21 ms（中位 6），复制 13.3–32.7 s |
| control 不迁移 | 8/8 | 复制 14.4–33.6 s（中位 26.7） |
| release 迁移 | 8/8 | 复制快约 4.5 倍（中位 5.8 s） |
| kickoff 关闭踢中断 | 7/8 | 1 次复制停在固定字节数、此后再无完成事件 |
| 朴素热拔插基线 | 0/3 | `USB disconnect` + 最多 5 条 I/O error，dd rc=1，校验和不符 |
| 注入 baseline（钩子惰性） | 5/5 | — |
| 注入 window 500 ms + 踢 | 5/5 | 停机≈519 ms |
| 注入 window-loss 500 ms − 踢 | 4/5 | **非确定**：丢的不是最后一个未完成命令时仍可恢复 |
| 注入 winlong 5 s + 踢 | 3/3 | 停机≈5016 ms |
| 注入 winlong 5 s − 踢 | **0/3** | **确定失败** |
| 注入 guard-off | **0/5** | **确定失败**，36 s `DID_TIME_OUT` + 成片 I/O error，Fisher p<0.0001 |

暴露度：窗口 5.00–23.87 ms，20 次中 11 次（55%）窗口非空，合计 24 个完成事件，单次最多 4 个。

**结论层面的自我修正**：轮次 1/2 把修复前约 1/5 的卡死全部归因于"丢失交接中断"。
本轮的注入结果说明：**归属守卫缺陷是确定致命的**（0/5），而丢失中断只在"恰为最后一个未完成命令"时致命
（自然窗口约 1/8；500 ms 窗口 1/5；5 s 窗口 3/3）。论文与摘要已据此改写为更精确、更弱的表述。


---

## 第七部分：轮次 3 评审结论与处理（2026-09-20）

三位**全新**审稿人对修正后的证据复核。结论：**系统方向 Major Revision、方法学 Major Revision、写作与格式 Minor Revision**。
共同的核心意见是"论文的机制叙述超出了证据"，下面逐条记录可执行项与处理。

### 7.1 最严重：交接窗口的锚点错误（方法学 + 系统两位独立发现）

`analyze-handover-exposure.py` 把窗口起点取在 **migration.epoch（迁移请求）**，并在正文里写"从这一刻起源端 VMM 已暂停"。
**这是错的**：CH 默认 pre-copy，源码日志显示源端真正 `event = paused` 比请求晚 **1.9–6.2 ms**，
这段时间内完成的传输会被正常服务。审稿人把每个 `Sent event` 按 CH 的 uptime 锚点映射后指出：
24 个"有风险"的完成事件里**至少 14 个发生在暂停之前**。

**修复**：`analyze-handover-exposure.py` 改为从 `src.log` 解析 `VmSendMigration` 与 `event = paused` 的相对时刻，
把窗口起点锚定在**暂停时刻**；同时打印请求锚定的"严格上界"。重算结果：

| 锚点 | 有风险的运行 | 完成事件数 | 窗口 |
|---|---|---|---|
| **暂停时刻（采用）** | **8/20（40%）** | **10** | 2.99–17.70 ms |
| 迁移请求（上界） | 11/20（55%） | 24 | 5.00–23.87 ms |

论文正文、摘要与中文摘要已按 8/20、10 个改写，并同时给出上界。

### 7.2 5 s 注入臂：显著性、事后性与效力（方法学）

原 5 s 臂只有 3/3 vs 0/3，Fisher 双侧 $p=0.10$ **不显著**，且是在 500 ms 臂预测失败**之后**追加的。
**修复**：把两臂各扩到 **8 次**（预注册样本量），结果为 **8/8 vs 2/8，$p=0.007$**；
论文明确标注这是**探索性**的事后扩展，并给出效力（对 5%/80% 效应量为 0.88，达到 80% 效力需 8 次/臂）。
同时把 500 ms 臂从 5 次扩到 **10 次**：**4/10**（原 4/5 是小样本假象），$p=0.044$。
扩展后甚至发现 5 s 臂也并非"必然失败"（2/8 恢复），论文据此把"确定性"改为"受控显著"，
并把"确定性"一词只留给归属守卫臂（0/5）。

### 7.3 效力分析缺失（方法学）

论文原来声称"讨论了每个比较的效力"，但全文没有效力分析。
**修复**：`update-results.py` 新增**精确无条件 Fisher 检验效力**计算，输出宏：
自然 kick 比较效力 $0.067$、达 80% 需约 62 次/臂；5 s 臂效力 $0.88$。

### 7.4 判定逻辑的两个 fail-open（方法学）

1. `usb-migration-demo.sh` 把缺失的 downtime 传成 `${DOWNTIME_MS:-0}`，于是"日志里没有停机行"会被判成 0 ms 通过。
   **修复**：原样传递（可为空），`verdict.py` 收到空值即 FAIL。
2. `migration.done` 只是 `send-migration` 返回的时刻，比 CH 自己 `Migration completed` 早 4.6–15.3 ms，
   判据实际只保证"复制包含迁移请求"。
   **修复**：`verdict.py` 新增 `--src-log`，从 CH 日志解析**真正的完成时刻**并要求它落在复制窗口内。
   全部已有批次用 `reverify-batch.py` **离线重判**（无需重跑虚拟机），结论不变：20/20、8/8、8/8、7/8。

### 7.5 逐条处理的其余意见

| 来源 | 意见 | 处理 |
|---|---|---|
| 系统 | kickoff 失败被写成"无 I/O 错误"，实际 console 在 ~30 s 超时后出现 I/O error | 改为"无重枚举；约 30 s 命令超时后出现 I/O 错误" |
| 系统 | "有风险的完成事件数随延迟增长"是错的（饱和于队列深度） | 改为"延迟使队列排空，从而丢失的完成事件更可能是最后一个" |
| 系统 | 注入钩子未限定在交接路径（也延迟启动时注册、且持有后端锁） | 论文明确声明 |
| 系统 | guard-off 钩子同时关掉 DmaUnmap 一半 | 论文明确声明 |
| 系统 | reset 修复没有对照臂，且失败模式描述有误 | 论文降级为"由源码与未打补丁构建的行为确立"，明确说明未做消融 |
| 写作 | `libvirtformatdomain` 不支持该句（讲的是 usb-bot 磁盘模型） | **该claim本身也反了**：libvirt 源码 `qemuMigrationSrcIsAllowedHostdev` 明确允许 USB hostdev 迁移（detach/re-attach）。改为引用新条目 `libvirtmigrationsrc` 并据此把"朴素热拔插"定位为 QEMU/libvirt 的做法 |
| 写作 | `kernelusb` 不支持"USB 是困难情形" | 删除该引用，改为自述 |
| 写作 | `usbredir` "reconnection semantics" 无出处 | 删除该短语 |
| 写作 | bootstrap 中位数区间被写成 4–21 ms（实为 [5,17]） | 新增 `\DowntimeMedianCILow/High` 宏并改用 |
| 写作 | `make data` 因硬编码 `paper/data/runs.dat` 崩溃 | 改为相对 `--out` 解析；已实测 |
| 写作 | 归档缺少 `results-*.csv`，MANIFEST 全空 | `collect-artifacts.sh` 增补批次级文件；MANIFEST 改用 `make-manifest.py`（调用 `verdict.py` 重新推导，已由 0 行变为 44 行真实数据） |
| 写作 | 作者身份泄露：`guest/testfile.md5` 卷标含真名、DEVLOG 含 GitHub 句柄与代理 IP | 新增 `docs/redact-identifiers.py` 脱敏（11 处）并提交；`testfile.md5` 只留哈希与文件名 |
| 写作 | 页数漂移（中文摘要写 9 页、README 写 11 页、实际 13 页） | 两处都不再写死页数 |
| 写作 | 实现规模写成 380/30（那是上游 PR 分支） | 改为 6 文件 381/28（多客户端改动）与 7 文件 516/104（含注入钩子），并注明排除单行 USB 后端改动为 515/103 |
| 写作 | 速率写成 ~2–6 MiB/s，实测 3.9–9.6 | 由 `\CopyMin/\CopyMax` 生成"约 4–10 MiB/s" |
| 写作 | 热拔插小节结论句自相矛盾 | 改为"不只是打扰 Guest，而是让传输失败" |
| 写作 | Firecracker 作者列表少一人 | 补为 8 人（Florescu 与 Iordache 分开） |
| 写作 | 图注未写数据来源；注入表未说明是机制实验 | 全部图注补来源；注入表标注"机制实验，非验收" |
| 写作 | 已跟踪 `__pycache__`、失效的 `paper/data/runs-current.csv` | 删除并加入 `.gitignore` |
| 写作 | 控制臂判据比迁移臂弱，但表注说"meeting the verdict" | 表注与正文明确：控制臂只做校验和判定 |
| 写作 | 199.9 s 死锁数字在第三轮批次里无法复算 | 正文注明来自 phase-0 实验，并指向对应文档 |
| 写作 | 枚举/复位判据在本数据集中从未独立决定任何判定 | Threats 中如实说明 |
| 写作 | 修复前 5 次没有原始文件 | Threats 中如实说明其为定性比较 |

### 7.6 处理后的实测结果

| 臂 | 通过 | 备注 |
|---|---|---|
| debug 迁移 | 20/20 | 停机 4–21 ms（中位 6） |
| control 不迁移 | 8/8 | 仅校验和判定 |
| release 迁移 | 8/8 | 复制中位 5.8 s |
| kickoff 关闭踢中断 | 7/8 | 1 次在固定字节数处停住 |
| 注入 baseline | 5/5 | 钩子惰性 |
| 注入 window 500 ms + 踢 | 5/5 | 停机≈519 ms |
| 注入 window-loss 500 ms − 踢 | **4/10** | $p=0.044$ |
| 注入 winlong 5 s + 踢 | **8/8** | — |
| 注入 winlong 5 s − 踢 | **2/8** | $p=0.007$，效力 0.88 |
| 注入 guard-off | **0/5** | 确定性；$p<0.001$ |
| 朴素热拔插 | 0/3 | `USB disconnect` + I/O error，dd rc=1 |
| 暴露度（暂停锚定） | 8/20（40%） | 10 个完成事件；请求锚定上界为 11/20、24 |

---

## 第八部分：轮次 4 评审结论与处理（2026-09-20）

三位**全新**审稿人复核后仍为 **Minor Revision ×3**：核心科学结论已被接受，剩下的都是
"叙述/脚本与证据不一致"。本部分记录并逐条关闭。

### 8.1 最严重：暴露窗口的锚点仍偏早（方法学，第二轮指出）

上一轮把窗口起点改成"源端暂停"，但暂停时刻是用 `migration.epoch + (paused − req)` 算的，
而 `migration.epoch` 是 harness **启动 ch-remote 之前**记录的，比真正的请求早 **0.9–4.6 ms**。

**修复**：不再依赖 `migration.epoch`，而是**用两条因果相邻的事件对把 CH 自己的 uptime 时钟
与墙钟对齐**：CH 的 `Enabling IRQ` ↔ usbvfiod 第一次 `set IRQs`；CH 的 `Disabling IRQ` ↔
`ignoring IRQ disable`。20 次运行中这两对给出的原点相差 **≤0.19 ms**。据此同时给出三个锚点：

| 锚点 | 有风险的运行 | 完成事件 | 窗口 |
|---|---|---|---|
| **CH 时钟（下界，论文采用）** | **4/20（20%）** | **4** | 2.11–13.36 ms |
| harness epoch（上界） | 8/20（40%） | 10 | 3.0–17.7 ms |
| 迁移请求（严格上界） | 11/20（55%） | 24 | ≤23.9 ms |

论文改为以下界为头条数字、同时列出另两个，并说明真值在 CH 时钟与 harness epoch 之间。
另外把"复制在切换后至少还剩 \SpanMarginMin 秒"改为**生成**的数字（验收臂 9.50 s），
替换原先手写的"约 7 s"。

### 8.2 多重比较未控制（方法学）

论文现在明确把六个对比列为同一族并做 **Holm** 校正：**归属守卫（$p<0.0001$）与 5 s 对（$p=0.007$）
存活，500 ms 对比（$p=0.044$）不存活**。正文把 500 ms 结论从"effect is clear"改为
"nominal only"，并声明踢中断的作用由 5 s 臂确立。所有 Fisher $p$ 值都标注为双侧。

### 8.3 make-manifest 仍有 fail-open（方法学）

归档工具 `guest/make-manifest.py` 仍把缺失的 downtime 传成 `"0"` 且不使用 `src.log`——
审稿人构造了一个删掉停机行的真实运行目录，manifest 判 PASS 而 `verdict.py` 判 FAIL。
**修复**：原样传递（缺失即 FAIL）、传 `--src-log`、对放大窗口臂使用 12000 ms 预算、
并在复现配方里写出 `--src-log`。

### 8.4 逐条关闭的其余意见

| 来源 | 意见 | 处理 |
|---|---|---|
| 方法学 | `migration.done` 仍被描述为"switchover complete" | 全文改正：请求由 harness 记录，完成时刻取自 CH 日志 |
| 方法学 | 中文摘要的控制臂写成普通 8/8 | 补"仅校验和判定" |
| 方法学 | 中文摘要的暴露度只有单一锚点 | 补三个锚点 |
| 方法学 | "three orders of magnitude" 偏大 | 改为 "two to three"（5 s 是自然窗口的 280–1670 倍） |
| 方法学 | 工具注释里 "11/20" 是被取代的请求锚定数字 | 改为 CH 时钟 4/20（并列出另两个） |
| 方法学 | `injection-suite.sh` 写 window-loss 8 次而发表为 10 次 | 改为 10 |
| 方法学 | 附录缺少扩展/重判脚本 | 补 `extend-injection.sh`、`phase-e-and-winlong.sh`、`reverify-batch.py` |
| 系统 | 手写"约 7 s"边距错了（真值验收臂 9.5 s，全臂 1.26 s） | 改为生成的 `\SpanMarginMin`（验收臂 9.50 s） |
| 系统 | "both recorded by the harness" 与实现不符 | 改为"请求由 harness 记录、完成取自 CH 日志" |
| 系统 | 381/28 是 PR 分支的 diff | 明确标注，并给出当前树 483/103（七文件合计 516/104） |
| 系统 | reset 缺陷被列在"确定性"里但没有消融 | 改为 "deterministic by inspection" |
| 系统 | "between 2 and 2" | 改为 "exactly 2" |
| 写作 | `redact-identifiers.py` 自己泄露了密钥 | 改为只存 SHA-256 摘要 + 通用检测；实测 OK |
| 写作 | 文件名/正文含人名 | 重命名为 `migration-paper-proposal.md` 并脱敏 |
| 写作 | 仓库 `.git`（origin、commit 作者）仍可识别作者 | 新增 `make-anonymous-snapshot.sh`，用 `git archive` 产出无 `.git` 的附件 |
| 写作 | demo 脚本文档仍写 5 s 臂 0/3 | 改为 2/8；DEVLOG D14 就地标注被 D15 取代 |
| 写作 | 中文摘要 guard 写 $p<0.001$ | 与宏对齐为 $<0.0001$ |
| 写作 | 空批次时 `update-results.py` 除零崩溃 | 补 `n==0` 守卫，输出 `?` 占位 |
| 写作 | "four comparison arms" | 改为 three + 单独报告的朴素基线 |
| 写作 | libvirt 那句把 detach/re-attach 归给 libvirt | 改为归给 QEMU `usb-host`，libvirt 只提供"允许迁移"的注释 |

### 8.5 本轮仍未做／已知边界

- 自然窗口下踢中断的统计显著性仍不成立（7/8 vs 20/20，$p=0.286$，效力 0.067）；其必要性由
  受控放大窗口（500 ms 名义、5 s 经 Holm 存活）确立。论文已如实声明。
- reset 解析修复没有消融臂，已降级为"由源码与未打补丁构建的行为确立"。
- 跨主机、多设备、USB 3.0/UAS、显式 quiesce 仍为范围外。

---

## 第九部分：轮次 5 评审结论与处理（2026-09-20）

三位**全新**审稿人一致给出 **Minor Revision**，并都明确写下"**nothing blocks acceptance / 不阻塞接受**"：
科学结论与统计方法被认为已经成立，剩下的全是文本与工件层面的修补。逐条处理如下。

### 9.1 三个独立复现的共同结论

三位审稿人**各自独立**重算了暴露度并得到一模一样的结果（与论文宏一致）：

| 锚点 | 有风险的运行 | 完成事件 | 窗口 |
|---|---|---|---|
| CH 时钟（下界，论文头条） | 4/20 | 4 | 2.11–13.36 ms |
| harness epoch（上界） | 8/20 | 10 | 3.0–17.7 ms |
| harness epoch 原值（严格上界） | 11/20 | 24 | ≤23.87 ms |

两对 CH 锚点原点的最大差 **0.189 ms**；**窗口内每一个事件都是 `Transfer` TRB**（不是命令完成或端口事件）。
Fisher $p$ 值、Holm 校正结论（守卫与 5 s 对存活、500 ms 不存活）、精确效力（0.067 / 62 / 0.88 / 8）、
bootstrap 中位数区间 [5,17]、宿主负载相关系数 −0.376、最近枚举事件 6.92 s、36 s `DID_TIME_OUT`
全部被独立复现。

### 9.2 逐条处理

| 意见 | 处理 |
|---|---|
| 中文摘要仍写"此后再无完成事件"（与 kickoff-5 的日志矛盾：31 s 后确实有事件） | 改为"复制停在固定字节数，约 30 s 命令超时后出现 I/O 错误，复制始终未完成" |
| `main.tex` 另一处仍写 "three orders of magnitude" | 改为 "two to three"（实测 375–2375 倍 ≈ 2.6–3.4 个数量级） |
| **六个脚本含字面 `<repo>`，无法运行**（脱敏时误伤）且附录推荐使用 | 六个脚本改为从 `$0` 推导自身目录；`campaign-b.sh` 补上此前引用却未定义的 `REPO`；全部 `bash -n` 通过 |
| 第三个锚点被称作"迁移请求"，实际锚在 harness epoch | 正文与生成注释改为"harness epoch（在启动 ch-remote 之前记录）" |
| 注入小节的完成事件数区间（1–3 等）在同一锚点下不可复现 | 删去具体区间，保留"不随延迟增长、饱和于队列深度"的定性结论 |
| `verdict.py` 仍用 epoch 锚点（比 CH 时钟早几 ms） | 加注释说明：该偏差只会**放大** 9.5 s 的复制余量，不可能翻转判定 |
| `injection-suite.sh` 注释自相矛盾（n=4 才是首个显著值） | 更正 |
| 附录让读者先跑 `injection-suite.sh` 再跑 `extend-injection.sh`（会重复追加） | 说明 suite 已含最终样本量，extend 仅记录达到该样本量的过程 |
| 中文摘要 Fisher $p$ 未标"双侧" | 全部标注 |

### 9.3 三轮（3→5）反复被攻击的地方

三位审稿人在三轮里最集中的火力始终是**测量与判定代码**，而不是被研究的设备代码：
窗口锚点（三次）、fail-open（两次）、归档可复算性与脱敏（各两次）、以及"手写的数字"。
本轮之后，**结论性**数字（暴露度三锚点、复制余量、bootstrap 区间、效力、$p$ 值）全部由
`paper/update-results.py` 从原始 CSV/日志生成；但仍有少量**描述性**数字是写在正文里的
（宿主负载相关系数 −0.38、停机分布 11/8/1、最近枚举事件 ≥6.9 s、锚点一致性 ≤0.2 ms、
约 4–10 MiB/s，以及 199.9 s / 30 s / 36 s 等时间），它们均已人工复核但与宏无关，
评审轮次 6 已如实指出这一措辞过强。

---

## 第十部分：轮次 6 评审结论与处理（2026-09-20）

| 审稿人 | 结论 | 说明 |
|---|---|---|
| 系统方向 | **Accept** | 全部数字与三个暴露锚点被独立复现；剩余为文案级修补 |
| 实验方法学 | **Accept** | 独立复算 Fisher/Holm/效力/bootstrap 与全部臂判定；无阻塞项 |
| 写作与工件 | 首次 **不通过**（仅因工件）→ 修复后复评通过 | 阻塞项：**我自己的脱敏检查脚本第 93 行注释里写着人名原文**，且 `ALLOW` 把该文件排除在摘要扫描之外，于是"检查通过"却输出了含人名的快照 |

### 10.1 写作审稿人发现的工件缺陷（全部已修）

1. **`docs/redact-identifiers.py` 注释里含人名原文**：我在"关闭最后一个泄露"那次提交里，
   为了说明"名字可能以空格、连字符、连写三种形式出现"，把**这三种真实写法**直接写进了注释；
   同时脚本的 `ALLOW` 把自己排除在摘要扫描之外，于是它报告 OK、却生成了含人名的匿名快照。
   **修复**：注释改为不含任何字面量（只用文字描述"三种写法"）；脚本只保留 11 个 SHA-256 摘要与通用检测；
   取消对自己的豁免。
2. **检查器是 fail-open 且依赖 cwd**：从仓库根目录运行报 OK，从 `docs/` 运行报 FAIL；
   在非仓库目录运行时扫描的是**调用者目录**却仍报 OK。
   **修复**：脚本固定 `chdir` 到自己所在的仓库根；没有 `.git` 时回退为遍历该根目录（而不是调用者目录）；
   路径本身也参与扫描（原先只扫内容，而最初的泄露正是**文件名**）。
3. **检查器把自己排除在摘要扫描之外**，所以"自己含密钥"也能报 OK。**修复**：取消白名单。
4. **新增 `--selftest`**：用合成字符串（非真实密钥）验证"正文命中、文件名命中、干净文本不误报"三种情况，
   且测试后从摘要表中移除该合成摘要，避免污染随后扫描。
5. **快照端到端复验**：`make-anonymous-snapshot.sh` 产出无 `.git` 的 tar，解包后在快照内运行检查器
   （仓库根与 `docs/` 两个 cwd）均为 OK；这是审稿人明确要求的"再验证而非口头声明"。

### 10.2 其余轮次 6 意见（已修）

| 意见 | 处理 |
|---|---|
| "exactly 2 / exactly 1" 只引用 Min 宏 | 改为"每次运行计数相同（2 / 1）"的中性表述 |
| 中位数 26.0 / 5.8 是二进制浮点截断 | 改为十进制 half-up：26.1 / 5.9（`26.05/5.85=4.45`，与摘要"约 4.5 倍"一致） |
| `verdict.py` 在既无 `--src-log` 又无 `--migration-done` 时会静默放松判据 | 新增 `missing-switchover-instant` 失败分支（已自测） |
| 宿主负载相关系数未说明取样规则 | 正文注明"取迁移时刻之前最近一次采样"（换规则会从 −0.376 变 −0.313） |
| 评审报告 §9.3 "已无手写评测数字"过强 | 改为区分"结论性数字已生成 / 少量描述性数字仍手写" |
| 中文摘要缺少 crate 补丁需重建 VMM 的限定 | 补上 |
| 若干脚本输出根目录写死 | 改为 `REPLUG_ROOT` / `INJECT_ROOT` / `RUNROOT` 可覆盖 |
| 两个 Overfull hbox（34.6 pt / 26.8 pt） | 缩短表注与代码标记，重建后归零 |


---

## 第十一部分：轮次 6–8 最终结论（2026-09-20）

| 轮次 | 系统方向 | 实验方法学 | 写作与工件 |
|---|---|---|---|
| 6 | **Accept** | **Accept** | 不通过（工件：检查脚本含人名原文 + 自我豁免） |
| 7 | — | — | 不通过（工件：tar 的 pax 头里带 commit id → 可解析到公开 fork） |
| 8 | — | — | **Accept**（"the tarball is safe to attach"） |

**三条轴全部 accept，目标达成。**

### 11.1 写作/工件轴两次打回的原因与修复（均为我自己的工具缺陷）

1. **轮次 6**：`docs/redact-identifiers.py` 的**注释里写着人名的三种写法**，且 `ALLOW` 把自己排除在扫描之外，
   于是"检查通过"却输出了含人名的快照。修复：注释去字面量化、取消自我豁免、固定仓库根、
   路径也扫描、新增 `--selftest`。
2. **轮次 7**：`git archive` 生成的 tar 带 `pax_global_header: comment=<commit id>`，
   该 commit 可解析到公开 fork；`--format=zip` 同理。检查器结构上看不到归档元数据。
   修复：导出后用普通 gnu tar 重打包（固定 mtime、uid/gid 归零、`gzip -n`），
   断言 `git get-tar-commit-id` 为空，**在解包后的归档内部**从两个 cwd 复跑检查器，
   并且**工作区不干净时拒绝执行**。

### 11.2 轮次 8 之后又做的一处加固（审稿人非阻塞建议）

单一分隔符窗口无法重构"混合分隔符"密钥（如完整代理 URL），因此
`docs/redact-identifiers.py` 现在把**按空白切分的原始 token** 也作为候选，
并补上"裸人名"摘要；`refs.bib` 中未被引用的条目已删除（24 条全部被引用）。

### 11.3 交付物

- 论文：`paper/main.pdf`（13 页）、`paper/abstract_zh.pdf`（2 页）
- 仓库：`origin/main` = `632dc09`
- 匿名快照：`/root/lvllm/usbvfiod-anonymous.tar.gz`
  （sha256 `bcd17fcc…`，无 `.git`、无 commit id，解包后检查器从两个 cwd 均通过）
- 原始证据：文本日志在 `artifacts/`；161 个 pcap（20.5 GB）在
  `/mnt/mt/usbvfiod-artifacts/`，附 `SHA256SUMS-pcap`

---

## 第十二部分：轮次 9 评审（两阶段设备交接的实现与实测，2026-09-25）

**本轮范围**：把"多客户端 + 陈旧客户端保护"升级为**两阶段设备交接**
（注册=暂存候选 → 预检 → 控制通道显式 `commit` / `abort` / 租约内 `reclaim` +
owner 连接消失时的三级兜底），补齐 A4/A5 预检，把真机 harness 改成**事件驱动**判定迁移结果，
并用真实虚拟机做成功与失败两组实验。工件：8 个提交（`cf17db0..`）、12 个无 guest 端到端测试、
`docs/handover-two-phase-design_cn.md` 的修订、`paper/main.pdf` 14 页、匿名快照重建。

### 12.1 系统方向

| # | 发现 | 处理 |
|---|---|---|
| S1 | **显式 `commit` 不在自然成功路径的关键路径上**：CH 在"目标端注册"后 3.7–8.3 ms 就 deactivate 源端设备并关闭连接，而 `ready`+`commit` 需要两次往返（实测 23.9 ms），所以自然路径上闭合窗口的是**兜底提升** | **不做成"控制器驱动"的假象**：论文在 §Failure recovery 明确写"the automatic fallback is what closes the natural case"，并在限制段指出"让预检成为强制语义需要挂住目标端注册应答"（下一步 M6）。这是本轮最重要的诚实化 |
| S2 | 兜底提升如果不过预检，会把设备交给一个 DMA 都发布不全的连接 | 提升必须通过**自动预检**（A3 覆盖 + A4 描述符），失败则退化为 unowned；有测试 |
| S3 | 预检读"注册那一刻"的 DMA 快照 → 真机上误拒（目标端 `DmaMap` 晚 0.06–0.3 ms） | 改为读**活状态**；加回归测试（见 12.2 M1） |
| S4 | `A4` 原本只检查 `metadata()`，任何可读 fd 都能装上线 | 改为读 `/proc/self/fdinfo` 要求 `eventfd-count`；并修掉 `InterruptEventFd::interrupt` 里的 `expect`——客户端给的 fd 不该能把 interrupter worker 打死（改为 warn） |
| S5 | `A5`（设备仍在）在设计里是硬条件但**没有实现** | 设备的在线情况只能通过 hot-plug port 的异步通道查询，因此由**控制面在每个交接命令前刷新**，预检消费它；`--handover-require-device` 可关（无控制面时不误伤），有注入空清单的测试 |
| S6 | M6（把注册应答挂住到控制器决定为止）未实现 | 列为待批准的行为变更，不自行实施；论文/设计/日志三处都写明 |

**结论：Accept**（带 S1/S6 的明确限制声明）。

### 12.2 实验方法学

| # | 发现 | 处理 |
|---|---|---|
| M1 | **只有真机才暴露的回归**：合成测试按 `dma_map → set_irqs` 的"想当然"顺序写，正好把"VMM 先注册后发布内存"的真实顺序缺陷藏住；真机 T1 因此 FAIL（目标端 guest 35 s 后丢 USB 栈、9 条 IO 错误） | 修实现 + 用**实测顺序**写回归测试；并把"合成测试的顺序假设必须来自真机日志"写进开发日志 |
| M2 | harness 用 `send-migration` 返回码 + 一次 grep 判定迁移结果 → 真机证明**返回 0 而源端随后记 `Migration failed`** | 改为**事件驱动**：读源端 `--event-monitor` 的 `migration-failed`/`resumed`/`shutdown`，并规定失败标记优先于 `shutdown` |
| M3 | 一次运行里控制器报"no candidate appeared"，但日志显示候选确实存在过 | 定位为**stdout 块缓冲**（重定向到文件时 8 KiB 才落盘）+ 候选只活 7–8 ms；已记录：控制器的触发不应依赖日志刷新，M6 的阻塞式应答才是正解 |
| M4 | 暴露窗口的锚点与样本量 | 自然成功运行 3 次（7.3/9.1/11.7、18.7/23.1/28.5、19.2/23.7/29.4 ms），注入撑开 1 次（320 ms）；窗口内完成数 0–3；宏取"最小下界 / 最大上界" |
| M5 | 迁移"取消"在本 CH 版本没有独立 API（`timeout_strategy=cancel` 也不会取消已完成的迁移） | 用"目标端已注册后杀目标端"作为失败/取消的等价注入（T14），并明确论文不声称"取消 API"路径 |
| M6 | 单客户端回归（T10）此前未在改动后重跑 | 新增 `MAX_CLIENTS=1` + `SKIP_MIGRATION=1` 控制臂，本轮实测（见 12.4） |

**结论：Accept**（M3 的控制器触发限制已记录，M6 列为下一轮机制）。

### 12.3 写作与工件

| # | 发现 | 处理 |
|---|---|---|
| W1 | **匿名快照的最后一层检查失败**：`56 identifying match(es)`，全部是开发日志 D22 里的 fork 账号名原文——它是在上一轮 accept **之后**才写进去的 | 统一替换为既有 `<fork-owner>` 占位符；checker 报 0/162；快照重新生成并通过三层检查。纪律更新：**出件前必须跑完整的 `make-anonymous-snapshot.sh`**（它会在解包后的树上复核且拒绝脏工作区），而不是只跑 checker |
| W2 | 论文若把两阶段写成"控制器驱动的成功迁移"就是编造 | 新增两节如实描述机制与实测，重写 "Failure and rollback" 限制段；新增 8 个自动生成宏（`data/two-phase.txt`），**没有一个数字是手写进 .tex 的** |
| W3 | 快照摘要不能写进被快照包含的文件（自指） | 摘要改由构建脚本打印并写入同名 `.sha256`，开发日志不再内嵌摘要 |
| W4 | 论文页数/编译 | `main.pdf` 14 页、`latexmk -halt-on-error` 0 error；`abstract_zh.pdf` 因本机缺 CTeX `fandol` 字体集**无法重编**，但其引用宏未变化（`results.tex` 只新增、未改动既有宏值），已核实 |

**结论：Accept**。

### 12.4 本轮实测清单（判定与原始日志）

| 用例 | 方式 | 判定 | 日志 |
|---|---|---|---|
| T1 正常迁移 | 真机 + 控制器 | **PASS**（downtime 8 ms，md5 MATCH，0 重枚举，窗口 7.3–11.7 ms） | `usb-w1` / `usb-z3` |
| T14 目标端已注册后迁移失败 | 真机 + 杀伤注入 | **PASS**（源端仍在 owner=0、epoch 未动、md5 MATCH、0 重枚举、0 reset/IO） | `usb-f2`/`usb-v2`/`usb-z2` |
| T2 缺 DMA 映射 | 无 guest | 拒绝 `EPREFLIGHT_A3_DMA_INCOMPLETE`，源端不 kick | `handover_selftest` |
| T3 坏 fd | 无 guest（`/dev/null`） | 拒绝 `EPREFLIGHT_A4_EVENTFD`，源端不 kick | 同上 |
| T4 设备不在 | 无 guest（注入空清单） | 拒绝 `EPREFLIGHT_A5_DEVICE_GONE`，源端不 kick | 同上 |
| T6 预检超时 | 无 guest | 过期 → `EPREFLIGHT_TIMEOUT`，源端可继续重注册 | 同上 |
| T7 / T7c / T7d / T8 | 无 guest | reclaim 换线并 kick；非 prev / 陈旧 epoch / 租约过期分别拒绝且归属不变 | 同上 |
| T7b / T7e / T7f | 无 guest | owner 死亡：归还 prev / 变 unowned 后下一个注册接管 / 提升暂存候选；都有 kick 证明 | 同上 |
| T9 陈旧破坏性命令 | 无 guest | 忽略 + warn，新 owner 的线仍可 kick | 同上 |
| T10 单客户端回归 | 真机（`MAX_CLIENTS=1`，无迁移） | **PASS**：复制 55.9 s、rc=0、md5 与期望一致、`interrupt lines inst.: 1`（单客户端路径无交接） | `usb-z4` |
| T5 abort / 负对照 | 无 guest / 真机 | abort 不切换且 reason 入日志；无人 commit 时目标端 guest 约 35 s 后失去 USB 栈 | `usb-demo-t3` |
