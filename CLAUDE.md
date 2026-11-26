# zyz-worker Claude Code 说明

本仓库为 Codex 和 Claude Code 提供一个 agent 插件框架。

## Execute Task 工作流

当用户要求运行 execute-task 工作流时，使用项目斜杠命令：

```text
/execute-task [--fast|--standard|--strict] <task description>
```

`/code-development` 作为同一工作流的别名保留。

该工作流由以下文件定义：

- `skills/execute-task/SKILL.md`
- `skills/execute-task/prompts/main-agent.md`
- `skills/execute-task/templates/`
- `skills/execute-task/references/`（按需加载的专题细则：评审收口、跨 harness、watchdog、恢复、版本控制、PR 评审、编排模式、设计文档纪律）
- `hooks/scripts/review-round.sh` + `hooks/scripts/review-gate.sh`（分档与评审轮次：任务按风险分 `fast` / `standard` / `strict` 三档，写在 `status.md` 的 `- Tier:`；`review-round.sh` 记录每个评审点的轮次、按档位拒绝越限的轮次，`review-gate.sh` 拒绝没有记录在案的 review-agent 派发——见 `skills/execute-task/SKILL.md` `## 档位`、`## 评审收口` 与 `docs/design/execute-task-tiers-design.md`）
- `scripts/cross-review.sh` + `skills/execute-task/templates/cross-review-prompt.md`（跨 harness 交叉评审：在评审点的设计各轮、实现第 1 轮与全量轮、汇总第 1 轮（以 `review-round.sh start` 输出的 `cross-harness=` 为准），除了 `review-agent` subagent 之外，还会在本机装着的每一个**其它** agent harness 里各起一个只读评审会话——宿主是 Claude Code 时起 Codex，宿主是 Codex 时起 Claude Code；它的发现只作参考，每一条都要先经过独立核实才能接受，也可以附上记录在案的理由予以拒绝——见 `skills/execute-task/SKILL.md` `## 跨 harness 交叉评审`）
- `hooks/hooks.json` + `hooks/scripts/` 与 `monitors/`（watchdog 强制层：每次工具调用自动写心跳与会话活动、状态新鲜度提醒、subagent 退出门、后台 watchdog（死亡角色、会话静默、API 错误中断、无执行者、声明到点）、主 agent 停止门——见 `skills/execute-task/SKILL.md` `## Watchdog 强制层` 与 `hooks/README.md`；设计原则与长期方向「agent 主导，插件做工具与保障者」见 `docs/design/watchdog-design.md`）

主 agent 在任务开始时用 `hooks/scripts/task-pointer.sh arm <任务目录>` 写入本会话的指针 `.zyz-worker/sessions/<session-id>`（拿不到会话 id 时退回共享的 `.zyz-worker/current-task`），从而启用 watchdog——同一目录下的多个会话各跑各的 execute-task，互不覆盖；`[zyz-worker watchdog]` 通知和注入的上下文都是需要立即执行的指令（重新派发被点名的角色，或马上刷新状态文件），不是噪音。

当前对话 agent 就是主 agent。它保持面向用户，并负责协调整个工作流。

项目级 Claude Code subagent 位于 `agents/`（也可通过符号链接 `.claude/agents/` 访问）：

- `implementation-agent`
- `test-agent`
- `review-agent`

这些 subagent 是 `subagents/` 中共享提示词定义的镜像。

不要把 `skills/execute-task/prompts/main-agent.md` 当作 Claude Code subagent。它是当前面向用户的对话 agent 的控制器提示词。

## 编排调度任务工作流

当用户想推进一份开发任务主清单时——分析依赖、把并行的 `execute-task` worker 派发到隔离的 tmux 会话和 git worktree（任务涉及的每个仓库各一个 worktree）、汇总状态、并把合并卡在用户审批上——使用项目斜杠命令：

```text
/orchestrate-tasks <list-dir>
```

`<list-dir>` 默认为 `.zyz-worker/orchestration/<list-name>/`。主清单中的每个任务都是 `<list-dir>/tasks/<task-id>.md` 下的一个 Markdown 文件。

该工作流由以下文件定义：

- `skills/orchestration-scheduling-task/SKILL.md`
- `skills/orchestration-scheduling-task/prompts/main-agent.md`
- `skills/orchestration-scheduling-task/templates/`
- `scripts/orch-*.sh`（bash 辅助脚本：scan、spawn、reuse、build-env、worker-mcp-args、check、heartbeat-daemon、cleanup、merge、merge-and-cleanup）。其中：
  - `orch-merge.sh` 在收到 `merge` 令牌时只做合并 + 推送，不动 `state` 也不动 worktree；`orch-merge-and-cleanup.sh` 是旧的原子化「合并 + 完成 + 清理」路径。
  - `orch-reuse-worker.sh` 把一个已完成任务的 tmux 会话和 worktree 集合（所有仓库）关联给一个新的 `reuse-from` 任务，而不是新建容器。
  - `orch-build-env.sh` 输出 Go 构建 I/O 优化片段——`GOTMPDIR` tmpfs + `GOFLAGS=-p`——spawn 和 worktree 粒度的复用会把它注入到每个 worker pane，可通过 `ZYZ_GO_BUILD_OPT` / `ZYZ_GO_BUILD_P` / `ZYZ_GO_TMPFS_DIR` 调整。
  - `orch-worker-mcp-args.sh` 输出 MCP 隔离 CLI 参数，快照进每个 worker 的 `dispatch.md` `worker-mcp-args:`。默认 `ZYZ_WORKER_MCP=none` 给 worker 加 `--strict-mcp-config`（零 MCP server，因为 stdio MCP server 是每个 claude 进程各起一份，否则每个 worker 都要重新付一遍宿主的完整 MCP 内存基线）；`inherit` 恢复全量继承；`<config-path>` 把 worker 限定为恰好该 JSON 中的 server。

与 `/execute-task` 的关系：编排器自己**不**执行任务。它只负责调度和派发。每个任务在自己的 tmux 会话、自己的 git worktree（任务涉及的每个仓库各一个）里，作为一个调用 `/execute-task` 的独立 `claude` 进程运行——即 `each worker = 1 tmux session + n git worktrees (one per repo; n=1 for single-repo tasks) + 1 full claude process`。编排器与每个 worker 之间只通过 `<list-dir>` 中的文件通信（主条目、`worker-status.md`、`heartbeat`、`question.md`/`answer.md`）；没有任何东西在内存中跨越 agent 边界。

当前对话 agent 就是编排器（主 agent）。它保持面向用户，并运行编排循环。每个被派发的 worker 通过 `/execute-task` 复用同一组项目级 subagent（`implementation-agent`、`test-agent`、`review-agent`）；编排器本身不需要专属的 subagent。

直接执行 `/orchestrate-tasks <list-dir>` 默认会自动轮询：每个 tick 都通过会话内的 `ScheduleWakeup` 自行安排下一次，`delaySeconds` 按编排器的 7 分支节奏策略选取。直接执行（自动定时）模式下的重新调度提示词就是这条 `/orchestrate-tasks <list-dir>` 本身。也可以用 `/loop` 包装，作为显式的替代方式；在循环模式下，编排器改用 `/loop /orchestrate-tasks <list-dir>` 这个字符串重新调度。设置 `ZYZ_ORCH_ONCE=1` 则只跑一个 tick 就返回、不再自行调度（即使在 `/loop` 下也强制单次）：

```text
/orchestrate-tasks <list-dir>
/loop /orchestrate-tasks <list-dir>
```

关键边界：

- 主清单目录 `<list-dir>` 是唯一事实来源。编排器的每一个决定都必须能从磁盘内容推导出来——绝不能来自对话上下文。
- **编排器可以从 `~/` 或任意目录（磁盘上任何位置）启动，包括任何非 git 的 cwd。** 编排器不假设自己的 cwd 位于任何任务的源仓库内。每个任务的 git 操作都限定在它自己主条目的 `source-repo:` 字段所指的仓库。
- **每个任务的主条目都必须包含 `source-repo:` frontmatter 字段**，值为项目 git 工作树的绝对路径或 `~/` 开头的路径。spawn 辅助脚本会校验 `source-repo:`：缺失、非绝对路径、不存在或不是 git 工作树时，以 exit 5 退出并给出精确诊断。因此一份主清单可以跨多个仓库派发 worker（多项目编排）。软警示：不要把 `source-repo:` 指向 zyz-worker 插件仓库自身，除非你本意就是在插件源码里派发一个 worker。
- **单个任务可以跨多个仓库（默认行为）。** 一个任务涉及多个仓库时，用编号键 `source-repo-2:`、`source-repo-3:`… 声明额外的仓库（编号从 2 开始且必须连续；不带编号的 `source-repo:` 是主仓库，它的 worktree 就是 pane 的 cwd）。默认是一个 tmux 会话 + 一个 `claude` 管理每个仓库各一个 worktree（各自有分支、提交和推送）——除非用户明确要求，否则**不**按仓库拆分任务。`branch-N:` / `base-N:` / `worktree-N:` 可逐仓库覆盖；省略时按继承规则取值（branch/base 继承主仓库的解析值，worktree 采用共享父目录下的兄弟目录布局，目录名 = 仓库名）。worktree 路径不得包含 `:`（`ZYZ_WORKTREES` 的分隔符）。只写单个 `source-repo:` 的条目完全向后兼容。合并和清理按仓库逐个进行（仓库集合读自任务的 `dispatch.md`）；合并不是原子的、失败即停、重跑幂等。隔离边界：worker 之间绝不触碰彼此的 worktree（spawn 强制 worktree 路径两两不相交）；在 worker 内部，它对自己名下的所有 worktree 有完整写权限。
- 每个 `<list-dir>` 同一时间只能有一个编排器（通过对 `<list-dir>/.orchestrator.lock` 加 `flock` 强制）。
- **在外部编辑器里编辑主条目之前，用户必须先 `Ctrl-C` 停掉编排器，让 flock 释放。** 否则编排器的 `tmpfile + rename` 写入可能和编辑器的保存竞争。编辑保存后再重新启动编排器。
- 合并、状态变更和 worktree 清理都需要用户在主条目的 `## Pending Merge Approval` 中写入明确的令牌；编排器绝不会自主发起。令牌：
  - `confirmed`：转发给 worker，由 worker 写入 `phase=done`；编排器把它镜像为 `state: completed`，绝不直接写 `completed`。
  - `merge` / `merge: <base>`：调用 `scripts/orch-merge.sh`（只做合并 + 推送）。
  - 旧的 `approved`：调用 `scripts/orch-merge-and-cleanup.sh`（原子化的「合并 + 完成 + 清理」；多仓库任务会对 worktree 集合逐仓库执行，并且只在所有仓库都合并后才写 `state: completed`）。
  - `cleanup-approved`：清理 worktree。
  - `rejected: <reason>`：拒绝。

  清理过期 worker 还额外需要在 `## Notes` 中写 `cleanup-approved`。
- 编排器绝不代理用户与 worker 之间的问答。用户要么直接 attach 到 worker 的 tmux pane（同步方式），要么编辑 `<list-dir>/runtime/<task-id>/answer.md`（异步方式）。

不要把 `skills/orchestration-scheduling-task/prompts/main-agent.md` 当作 Claude Code subagent。和 execute-task 的控制器提示词一样，它是当前面向用户的对话 agent 的控制器提示词。
