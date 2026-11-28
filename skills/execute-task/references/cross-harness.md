# 跨 harness 交叉评审

在本机装着的另一个 agent harness 里起一个只读评审会话（宿主是 Claude Code 时起 Codex，反之起 Claude Code），与 review-agent 并行，互相看不到报告。

## 何时跑

默认只在严格档跑，含单独升到严格档的评审点和没有 `- Tier:` 的旧任务。以 `review-round.sh start` 输出的 `cross-harness=yes|no` 为准：严格档的设计评审各轮、实现评审第 1 轮和 `--full` 开的全量轮、汇总评审第 1 轮是 `yes`；快速档和标准档一律 `no`。

其它档位用户明确要求时，直接运行下面的命令（它不看档位；实现评审的增量轮要加 `ZYZ_CROSS_REVIEW_FORCE=1`）。`ZYZ_CROSS_REVIEW=off` 时一律不跑。

## 怎么跑

在任务目录里写一份简报文件，内容与给 review-agent 的派发相同，只是不给报告路径。和 review-agent 的派发同一批启动，放到后台：

```text
<plugin-root>/scripts/cross-review.sh run --task-dir <task-dir> --kind <design|implementation|aggregate> --brief <brief-file> --label <label> --point <id> --round <n> --mode <full|incremental> [--cwd <worktree>]
```

- `--point`、`--round`、`--mode` 取自 `start` 的输出。
- 报告落在 `<task-dir>/reviews/cross/<label>.<harness>.md`。每个评审者在 stdout 输出一行摘要：`status=ok|empty|failed|timeout|skipped` 和 `tree-stable=yes|no|n/a`。
- 评审会话只读，不跑测试，读的是实时工作树：它跑完之前被评审的文件不改。
- 一个评审者可能跑几十分钟。不让 review-agent 的派发等它；超时由 `ZYZ_CROSS_REVIEW_TIMEOUT` 控制（秒，默认 2400，低于 1200 的值会被提到 1200）。
- 平台没有后台工具调用时以分离方式启动，stdout 重定向到文件。
- 其它调节项：`ZYZ_CROSS_REVIEW=auto|off|<harness 列表>`；`ZYZ_CROSS_REVIEW_MCP`（默认 `none`）；`ZYZ_CROSS_REVIEW_CODEX_ARGS` / `ZYZ_CROSS_REVIEW_CLAUDE_ARGS`。`cross-review.sh detect` 显示会选中哪些 harness。

## 没跑成

没装别的 harness、被关闭或跳过、失败、超时、没有产出：在 `status.md` 的 `## 发现台账` 的 `- 跨 harness 运行:` 一行记下状态，只靠 review-agent 继续。失败的评审者每个评审点最多重试一次；评审点不为了等它保持打开。

## 处置它的发现

- 主 agent 逐条处置：读发现引用的 `file:line` 或章节，确认原文在那里、行为如它所说。核实不了的拒绝。不凭摘要接受，不批量接受。
- 每条以接受或附理由拒绝结束，等级按 `references/review-closure.md` §3。被接受的和 review-agent 的发现走同一条路；与 review-agent 某条发现重复的并进那一条。
- `tree-stable=no` 的报告对照当前工作树核实，复现不了的拒绝。
- 处置记进 `## 发现台账`，来源写 `跨 harness:<harness>`。
- 它自己写的 `changes-requested` / `no-changes-needed` 不决定评审点开关：只有被接受为 `blocking` 的发现让评审点保持打开。
