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

