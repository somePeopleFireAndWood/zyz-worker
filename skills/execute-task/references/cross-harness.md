# 跨 harness 交叉评审细则

`SKILL.md` `## 跨 harness 交叉评审` 的细则。每个评审点同时有两类评审者：任务自己的 reviewAgent subagent（在当前 harness 中），以及本机已安装的每一个**其他** agent harness 中的一个只读评审会话。主 agent 在 Claude Code 中运行且装有 `codex` 时，由一个 Codex 会话参与；在 Codex 中运行且装有 `claude` 时，由一个 Claude Code 会话参与。不同产品的评审者盲区不同，这是它的意义；也正因如此，它的报告是参考性输入，而不是结论。

## 何时跑

以 `review-round.sh start <point>` 输出的 `cross-harness=yes|no` 为准：

| 评审点 | 跑 |
|---|---|
| design（标准档、严格档；快速档没有设计评审） | 每一轮 |
| impl | 第 1 轮和用 `start --full` 开的全量轮；增量轮不跑 |
| aggregate（含快速档多 lane 时的契约一致性检查） | 只有第 1 轮；`start --full` 开的 aggregate 轮也不跑 |
| 任意 | `ZYZ_CROSS_REVIEW=off` 时一律不跑 |

快速档的 impl 第 1 轮就是"和那 1 轮实现评审并发一次"；快速档多 lane 时，aggregate 第 1 轮也跑。复盘数据：实现第 1 轮跨 harness 独有的真缺陷有 39 条，第 2 轮起只有 3 条，所以增量轮取消。

跑的时候，与 review-agent 的派发放在**同一**批次里启动；它是独立的工作，并发运行，不放在之前或之后。

## 怎么做

在任务目录中写一份简短的评审简报文件，然后运行（平台支持时放到后台，例如后台 Bash 调用）：

```text
<plugin-root>/scripts/cross-review.sh run --task-dir <task-dir> --kind <design|implementation|aggregate> --brief <brief-file> --label <round-label> --point <id> --round <n> --mode <full|incremental> [--cwd <primary-worktree>]
```

- `--point` / `--round` / `--mode` 取自 `review-round.sh start` 的输出。只有 impl 评审点且 `--mode incremental` 时，脚本直接输出 `status=skipped reason=incremental-round`，不启动评审者；用 `start --full` 开的 impl 全量轮是 `--mode full`，照常运行。aggregate 的第 2 轮起 `start` 输出 `cross-harness=no`，不启动。
- 平台没有后台工具调用时，以分离方式启动它，把 stdout 重定向到 `<task-dir>/reviews/cross/<label>.summary`（先创建目录），等 reviewAgent 返回后再读取该文件和 `.meta` 文件。一个评审者可能跑几十分钟；不要让 reviewAgent 的派发因它阻塞。
- 简报包含 reviewAgent 派发时会给的内容：最终态设计文档路径；设计复审时附评审历史文件路径；实现评审时附 lane id、冻结文件集、diff 基线 / 提交范围；之前各轮已被拒绝的带编号发现及其理由；遗留风险清单路径（一旦存在）。范围与 reviewAgent 派发相同，不缩小。
- 脚本检测宿主 harness，选出所有其他已安装的 harness（`cross-review.sh detect` 显示选择结果），渲染 `templates/cross-review-prompt.md` + 简报，并发运行每个评审者。输出落在 `<task-dir>/reviews/cross/<label>.<harness>.{md,meta,jsonl,stderr,prompt.md}`；每个评审者在 stdout 上输出一行摘要：`status=ok|empty|failed|timeout|skipped`，外加 `tree-stable=yes|no|n/a`。tree-stable 的指纹排除 `.zyz-worker/` 和 `--task-dir` 所在目录，评审期间写 `status.md` 不会被误判为评审对象变了。
- 评审会话是只读的（Codex 用 `-s read-only`；Claude 用 `--permission-mode dontAsk`，只带读取 / 搜索工具和只读 git），运行时清除所有 `ZYZ_*` 变量并设置 `ZYZ_HOOKS_DISABLE=1`（这样两个 harness 都装了的插件 hooks 不会把评审者误认为本任务的 agent），默认不带任何 MCP 服务器。它们不注入变异，也不重跑测试——这些仍归 reviewAgent。评审者读的是实时工作树，所以派发 reviewAgent 时要告诉它有一个并发的只读评审者在读，只要任务允许，它就在工作树之外的副本上做变异。
- 调节项：`ZYZ_CROSS_REVIEW=auto`（默认）| `off` | 显式的 harness 列表；`ZYZ_CROSS_REVIEW_TIMEOUT`（秒，默认 2400）；`ZYZ_CROSS_REVIEW_MCP`（取值同 `ZYZ_WORKER_MCP`，默认 `none`）；`ZYZ_CROSS_REVIEW_CODEX_ARGS` / `ZYZ_CROSS_REVIEW_CLAUDE_ARGS` 用于额外的 CLI 参数，例如指定模型；`ZYZ_CROSS_REVIEW_FORCE=1` 让 impl 增量轮也照常运行跨 harness。

## 可选，不阻断

没有安装其他 harness、设置了 `ZYZ_CROSS_REVIEW=off`、被跳过，或者某个评审者失败 / 超时 / 没有返回内容：把结果记入 `status.md` 的 `## 发现台账`（`跨 harness 运行` 一行），只靠 reviewAgent 继续。每个评审点对失败的评审者最多重试一次，不为了等它让评审点在超时后仍保持打开。它是对 reviewAgent 的补充，不取代 reviewAgent，也不替代 reviewAgent 应当提供的覆盖维度、变异证据或独立复现。

## 姿态：独立核实，可以拒绝

与 `references/pr-review.md` 的立场相同，也不弱于对待 reviewAgent 自身发现的立场：

- **逐条**处理。裁决者对照真实产物独立核实问题是否客观存在——读所引用的 `file:line`，确认引用的文字确实在那里，而且确实如发现所说的那样运作。不凭评审者的摘要接受，不批量接受，两个评审者意见一致本身不算证据。
- 裁决者就是在该时点裁决 reviewAgent 发现的那个角色：设计评审中是主 agent（附 `file:line` + 谓词证据），实现评审中是产物的作者（lane agent，或严格档关键机制的 implementation-agent / test-agent）。会改变用户设计的发现，或揭示出设计中错误 / 矛盾 / 歧义 / 站不住的假设的发现，交给用户（`SKILL.md` `## 用户设计主导权`）。
- 每条最终要么是**接受**（记入与 reviewAgent 发现相同的发现台账——已裁决 → 已派发 → 已落地），要么是**附具体理由拒绝**（引用的文字不存在、声称的行为无法复现、与已批准的设计相矛盾、超出范围、与第 N 条发现重复）。"读过并忽略"不算处置。与某条 reviewAgent 发现重复的，合并进那一条台账记录。
- 带 `tree-stable=no` 的报告，或证据与当前工作树不符的发现，对照当前冻结的工作树核实；在那里无法复现的，以此为由拒绝。
- 处置记入 `status.md` 的 `## 发现台账`（来源列写 `跨 harness:<harness>`；评审点关闭后移到 `log/review-ledger.md`）；设计阶段还把拒绝和非阻断发现记入评审历史文件，做法与 reviewAgent 的发现相同（下一轮简报会带上它们，对重新提出的发现指向已记录的拒绝即可）。接受↔拒绝反复 3 轮即升级的规则同样适用。

## 收口

评审点按 `references/review-closure.md` 的关闭条件关闭。跨 harness 这一侧，评审者自己给出的 `changes-requested` 结论不会让循环保持打开，它的 `no-changes-needed` 也不会让循环关闭；只有尚未裁决的发现和被接受为 `blocking` 的发现会让评审点保持打开。它的发现与 reviewAgent 的发现采用相同的分级和 blocking 准入，由裁决者核实分级。被接受的跨 harness 发现引起改动后，下一轮是否再跑跨 harness，仍以 `review-round.sh start` 的输出为准。
