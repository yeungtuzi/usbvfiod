# GitHub 署名约定（**长期有效，适用于所有仓库**）

> 用户指示（2026-09-26）：**以后所有的 GitHub 署名都按本次约定办理，不管项目有没有明确要求。**
> 本文件是这条约定的唯一权威说明；`DEVLOG_cn.md`（D34/D35）记录了它的由来。

## 1. 约定内容

每一次**对外可见的 GitHub 署名**（提交、PR 描述、PR 评论如涉及 LLM 产出）都使用下面两组固定字符串：

```
Signed-off-by: BigHippo <dahema@me.com>
Assisted-by: DeepSeek:deepseek-flash
```

- **`Signed-off-by` 必须写**，即使项目没有 DCO 要求（这是"不管项目有没有明确要求"的直接含义）。
- **`Assisted-by` 必须写**，即使项目没有 AI/LLM 政策。
  格式沿用 Cloud Hypervisor 的政策：`Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]`，
  本次约定的取值为 `DeepSeek:deepseek-flash`。
- **作者与提交者**也用同一个身份，避免"署名是一个身份、作者是另一个身份"：

```sh
git -c user.name=BigHippo -c user.email=dahema@me.com commit ...
# 或对某个仓库一次性配置：
git config user.name BigHippo && git config user.email dahema@me.com
```

- **提交信息与 PR 描述都要简短**。上游维护者对上一条 PR 的原话是
  "the descriptions are a bit verbose"：结论 + 一两个短段落 + 复现/测试一行即可，
  不要把排查过程整段贴上去。`Assisted-by:` 放在提交信息末尾，PR 描述也在末尾带一行。

## 2. 固定写法（提交信息模板）

```text
<subsystem>: <imperative summary, < 72 chars>

<What was wrong and what the change does, 2-4 short lines. Say what the user or
caller observes, not the journey.>

<How it was verified, one line.>

Signed-off-by: BigHippo <dahema@me.com>
Assisted-by: DeepSeek:deepseek-flash
```

## 3. 仍然有效的两条既有纪律（本约定**不**覆盖它们）

1. **对第三方仓库的任何写操作（PR/issue/comment/review、以及会改变上游 PR 的 fork 推送）
   都必须逐条获得用户批准。** 署名规范只规定"怎么签"，不构成"可以签"的授权。
2. **不重写已发布的历史。** 本约定自 2026-09-26 起对**新**提交生效；此前已推送的提交
   （例如 usbvfiod 里带 `Co-Authored-By: DeepSeek <noreply@deepseek.com>` 的那些）
   保持原样。若以后确实要回填，属于重写公开历史的操作，需要单独批准。

## 4. 一次性核对清单

推送到任何仓库之前：

- [ ] 作者/提交者 = `BigHippo <dahema@me.com>`
- [ ] 提交信息末尾有 `Signed-off-by: BigHippo <dahema@me.com>`
- [ ] 提交信息末尾有 `Assisted-by: DeepSeek:deepseek-flash`
- [ ] 描述简短（结论优先，不贴排查过程）
- [ ] 若是第三方仓库：这一条写操作已获得用户逐条批准

`scripts/git-identity.sh` 会打印这两行 trailer 并按需配置身份，
可以直接用：`git commit -F - < <(cat msg.txt; scripts/git-identity.sh --trailers)`
（见脚本 `--help`）。
