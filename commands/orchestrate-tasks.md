---
argument-hint: [list-dir]
description: 针对一个主任务清单目录，运行 zyz-worker 的 orchestration-scheduling-task 工作流。
---

针对下面这个主任务清单，运行 zyz-worker 的 `orchestration-scheduling-task` 工作流：

```text
$ARGUMENTS
```

如果没有给出路径，就向用户要一个。推荐的默认路径是 `.zyz-worker/orchestration/<list-name>/`。

加载并遵循主控提示词：

@${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/prompts/main-agent.md

使用技能定义和模板：

@${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/SKILL.md

可用模板：

- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/master-list-task-entry.md
- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/worker-status.md
- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/question-answer.md
- @${CLAUDE_PLUGIN_ROOT}/skills/orchestration-scheduling-task/templates/monitor.md

编排器（orchestrator，L1）为每个 worker 派发一个短生命周期的 `orch-driver-agent`（L2）子 agent，由它驱动该 worker 的 tmux pane：启动 `claude` 并运行 `/execute-task`，或在 worker 卡住时介入。L1 自己从不碰 pane；它以内联方式（只读）轮询 worker 状态，并在某个 worker 需要用户时通知用户。参见 SKILL 的 `## 架构（三层）` 一节。

辅助脚本（由编排器调用，不要自己重新实现）：

- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-scan-tasks.sh <list-dir>`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-spawn-worker.sh <task-id> <list-dir>`（只搭建容器：每个声明的仓库一个 worktree + 一个 tmux session + 心跳 + dispatch.md 第一阶段字段，多仓任务还包括编号的 `worktree-N`/`source-repo-N`/`branch-N`/`base-N` 字段组；从不启动 claude）
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-reuse-worker.sh <task-id> <list-dir>`（主条目声明了 `reuse-from` 时用它代替 spawn：把一个已完成任务的 tmux session 和/或整套 worktree 关联到本任务；同样从不启动 claude）
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-build-env.sh`（打印 Go 构建 I/O 优化片段，由 spawn / worktree 范围的复用注入 worker pane；编排器不直接调用）
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-worker-mcp-args.sh`（根据 `ZYZ_WORKER_MCP` 策略打印 MCP 隔离用的 CLI 参数。默认 `none` = `--strict-mcp-config` = worker 没有任何 MCP server；spawn/reuse 把输出快照进 `dispatch.md` 的 `worker-mcp-args:`，L2 driver 再把它追加到 claude 启动命令后面；编排器不直接调用）
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-check-worker.sh <task-id> <list-dir>`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-heartbeat-daemon.sh <heartbeat-file> <interval-sec>`（在 worker 的 tmux pane 内运行；编排器不直接调用）
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-cleanup-worker.sh <task-id> <list-dir> [--force]`
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-merge.sh <task-id> <list-dir> <base-branch>`（对应 `merge` / `merge: <base>` 令牌：只做 merge + push，从不写 `state`，从不清理）
- `${CLAUDE_PLUGIN_ROOT}/scripts/orch-merge-and-cleanup.sh <task-id> <list-dir> <base-branch>`（对应旧版 `approved` 令牌：merge + `state: completed` + 清理，原子执行）

重要边界：

- 编排器可以从任意 cwd 启动（`~/`、非 git 目录，或任何无关的 git 仓库）。每个任务的主条目**必须**带有 `source-repo:` frontmatter 字段，指向该任务主项目 git 工作树的绝对路径（`~/` 开头的路径会被展开）。跨多个仓库的任务用编号键 `source-repo-2:`、`source-repo-3:`……（从 2 开始连续编号）列出其余仓库。spawn 辅助脚本会校验每个声明的仓库，缺失或无效时以退出码 5 拒绝（多仓场景的诊断信息带 `repo <N>` 前缀）。
- 当前对话 agent 就是编排器。它负责调度、派发、轮询和汇报，但**不**自己执行任务：每个任务都在自己的 tmux session 里以 `/execute-task` 运行。多仓任务的默认形态是一个 tmux session + 一个 `claude`，管理每个仓库各一个 worktree（每个仓库各有自己的分支、提交和 push）；merge 和清理按仓库执行（仓库集合从 `dispatch.md` 读取），不是原子操作，重跑是幂等的。`each worker = 1 tmux session + n git worktrees (one per repo; n=1 for single-repo tasks) + 1 full claude process`；worker 之间从不碰彼此的 worktree，而在一个 worker 内部，它对自己的所有 worktree 都有完整写权限。
- 主清单目录 `<list-dir>` 是唯一的事实来源。编排器的每个决策都必须能从磁盘内容推导出来。
- 每个 `<list-dir>` 同一时间只能有一个编排器（通过对 `<list-dir>/.orchestrator.lock` 加 `flock` 强制保证）。
- 在外部编辑器中编辑主条目之前，用户**必须**先 `Ctrl-C` 停掉编排器，让锁释放。
- merge、状态变更和 worktree 清理都需要用户在 `## Pending Merge Approval` 中写入明确的令牌，编排器绝不自行发起。令牌：`confirmed`（把确认转达给 worker，由 worker 写 `phase=done`，编排器随后把它镜像成 `state: completed`；编排器从不直接写 `completed`）、`merge` / `merge: <base>`（merge + push，不改状态）、旧版 `approved`（原子执行 merge + completed + 清理；同一 tick 中若同时存在其它令牌，一律被它短路忽略）、`cleanup-approved`（worktree 清理）、`rejected: <reason>`。清理失联的 worker 还额外要求在 `## Notes` 中写 `cleanup-approved`。对多仓任务，这些令牌作用于 worktree 集合中的每个仓库。
- 直接运行 `/orchestrate-tasks <list-dir>` 时默认自动轮询：每个 tick 都通过会话内的 `ScheduleWakeup` 自行安排下一个 tick。用 `/loop` 包装（`/loop /orchestrate-tasks <list-dir>`）是一种可选的显式替代方式。设置 `ZYZ_ORCH_ONCE=1` 则只跑一个 tick 就返回，不再自行调度（即使在 `/loop` 下也强制单次运行）。
- 已安装的技能、插件和工具如果能提升产出质量，就使用它们；但绝不要求用户安装缺失的可选能力。
