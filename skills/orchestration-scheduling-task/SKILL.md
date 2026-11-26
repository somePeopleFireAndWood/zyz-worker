---
name: orchestration-scheduling-task
description: 当用户想驱动一份主任务清单（master task list）时使用——分析依赖、派发并行运行 execute-task 的 tmux/git-worktree worker、汇总状态，并以用户批准作为合并闸门。默认自动轮询（会话内自调度）；也可以用 /loop 包裹，或通过退出开关改为单次执行。
---

# 编排调度任务

用本 skill 驱动一份开发任务主清单。编排器（orchestrator）扫描清单、分析依赖、派发相互隔离的 worker（每个 worker 有自己的 tmux session 和 git worktree，各自运行 `execute-task` skill），通过文件汇总 worker 状态，并以用户的明确批准作为合并的闸门。一个 worker 为它涉及的每个仓库各分配一个 worktree，所有 worktree 都在同一个 tmux session 内，由同一个选定的 agent 运行时（`claude` 或 `codex`）管理。

编排器**不**亲自执行任务。它只负责调度、派发、轮询和汇报。每个任务都由一个独立的 Claude Code 或 Codex 进程在专属的 tmux session 中执行。Claude 调用 `/zyz-worker:execute-task`；Codex 遵循已安装的 Skill，或运行时适配器提供的绝对路径 `skills/execute-task/SKILL.md` 兜底。

运行时由 `ZYZ_AGENT_RUNTIME=claude|codex|auto` 选择（默认 `auto`）。在 agent 环境中，根据 `CODEX_THREAD_ID`/`CODEX_CI` 或 Claude 相关变量自动检测；非 agent 的 shell 为了向后兼容默认选 Claude。任务条目可以设置 `agent-runtime: claude|codex`。通用的派发字段（`agent-runtime`、`agent-pid`、`agent-session-id`、`worker-runtime-args`、`reuse-agent-effective`）是权威字段；旧的以 Claude 命名的别名仍可读写，以兼容已有的任务数据。

本 skill 建立在 zyz-worker 的一条约定之上：长期运行的任务状态存放在文件里，而不是对话上下文里。参见 [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md)。编排器与 worker 之间的所有跨进程通信都通过主清单目录中的文件进行；不在内存中交换任何东西。

## 何时使用本 skill

用户有以下任一需求时加载本 skill：

- 以并行执行的方式推进一份多任务的开发待办清单。
- 监视一个任务定义目录，并把用户的编辑当作事实来源（source of truth）做出响应。
- 把 `execute-task` worker 派发到相互隔离的 tmux session 和 git worktree 中（任务涉及的每个仓库各一个 worktree）。
- 把 worker 的进度（phase、wait-state、心跳）汇总成一份摘要。
- 以用户的明确批准作为合并与 worktree 清理的闸门。

如果用户只想运行单个已确认的任务，直接使用 `execute-task` skill。如果用户想针对同一份主清单调度许多任务，本 skill 就是入口。

## 架构（三层）

编排是一个**三层调用结构**。之所以这样拆分，是因为交互式地驱动 worker 的 tmux pane（启动 `claude`、点掉启动确认页、救援卡住的 worker）消耗大量 token 且噪声很多；把 N 个并行 worker 的 pane 驱动工作塞进同一个上下文，会污染上下文并压低实际的并行度。所以这项重活按 worker 隔离，而廉价的只读轮询则保留在主流程内联执行。

- **L1 —— 编排主 agent**（面向用户；唯一；持有 `<list-dir>` 的 flock）。统筹一切：扫描、分析依赖、规划派发、合并闸门、通知。为每个 worker 的整体状态投影保留一个廉价的**内联只读轮询**（`orch-check-worker.sh` —— 只读文件 + `pgrep`，绝不 `capture-pane` / `send-keys`）。**绝不碰 pane。** 只有一项重活——交互式驱动 pane——按需委派给 L2。
- **L2 —— 每个 worker 一个的 `orch-driver-agent` subagent**（短生命周期；按需派发，**不是**每个 tick 都派发）。只为一个 worker 做 pane 重活：以 bypass 模式启动 `claude`、点掉信任文件夹（trust-folder）和 bypass 风险两个确认页、运行 `/execute-task`，或在该 worker 卡住时介入。它是**唯一**会交互式触碰 pane 的一层（`send-keys` / `capture-pane`）。它只观察整体状态（`worker-status.md` / `dispatch.md` 这些向上投影），**绝不读取任务内部细节**，**只**写 `monitor.md`，退出前向 L1 返回一行结果。
- **L3 —— 运行 `/execute-task` 的 tmux window + 独立 `claude` 进程**（执行层）。它有自己的主 agent 以及 `implementation` / `test` / `review` 三个 subagent，在自己的 git worktree（任务涉及的每个仓库各一个）中依次完成设计 → 实现 → 测试 → 评审 → 交付。它**对 L1/L2 不可见**，由 L2 通过 `tmux send-keys` 驱动（而不是嵌套调用）。

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ L1  编排主 agent（面向用户 · 唯一 · 持有 list-dir flock）                  │
│                                                                            │
│  做什么：  扫描 → 分析(依赖) → 规划(派发) →                                │
│            轮询(内联 orch-check-worker.sh，只读 · 不碰 pane) →             │
│            首次启动 / 卡住时派发 L2 → 投影 → 闸门 →                        │
│            notify → 汇报                                                   │
│  能看到：  主条目、worker-status.md(投影)、dispatch.md、                   │
│            heartbeat、monitor.md、L2 返回的一行摘要                        │
│  碰 pane？ 不碰。L1 只调用只读脚本，绝不 send-keys / capture-pane          │
│  不能碰：  L3 内部细节（设计 / subtask / 实现 / 测试 / 评审 /              │
│            question.md 正文）                                              │
│  与用户：  编排层面的交互 + 通知"任务 X 在 window Y 需要你"                │
│            （绝不转述问答内容）                                            │
└───────────────┬────────────────────────────────────────────────────────────┘
                │ 按需（不是每个 tick）：首次启动或卡住需要介入时，
                │ 派发一个短生命周期的 driver subagent
                │ 传入：task-id + list-dir + pane 信息（自包含的提示词）；取回：一行结果
                │ 多个 worker 的 L2 一次性批量派发（单条消息，多个 Agent 调用）
        ┌───────┴───────┬───────────────┬───────────────┐
        ▼               ▼               ▼               ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐  ...（每个 worker 一个，按需）
│ L2  driver    │ │ L2  driver    │ │ L2  driver    │
│ subagent      │ │ subagent      │ │ subagent      │
│ (worker A)    │ │ (worker B)    │ │ (worker C)    │
│ 短生命周期 ·  │ │               │ │               │
│ 按需派发      │ │               │ │               │
│ （只做重活）：│ │               │ │               │
│ · first-disp：│ │               │ │               │
│   幂等的启动前│ │               │ │               │
│   检查 →      │ │               │ │               │
│   send-keys   │ │               │ │               │
│   启动 claude │ │               │ │               │
│   （bypass；在│ │               │ │               │
│   记录在案的  │ │               │ │               │
│   pane 中，不 │ │               │ │               │
│   换父进程）+ │ │               │ │               │
│   点掉确认页 +│ │               │ │               │
│   /execute-   │ │               │ │               │
│   task        │ │               │ │               │
│ · intervene： │ │               │ │               │
│   保守地      │ │               │ │               │
│   send-keys   │ │               │ │               │
│   救援        │ │               │ │               │
│ · relay-conf：│ │               │ │               │
│   把用户确认  │ │               │ │               │
│   send-keys   │ │               │ │               │
│   进 pane     │ │               │ │               │
│ · 设置 needs- │ │               │ │               │
│   user（仅限  │ │               │ │               │
│   waiting-    │ │               │ │               │
│   user）      │ │               │ │               │
│ · 写          │ │               │ │               │
│   monitor.md  │ │               │ │               │
│ · 返回一行    │ │               │ │               │
│ 能看到：      │ │               │ │               │
│ worker-status/│ │               │ │               │
│ dispatch      │ │               │ │               │
│ （投影），    │ │               │ │               │
│ 瞄一眼 pane   │ │               │ │               │
│ 不写 worker-  │ │               │ │               │
│ status，不读  │ │               │ │               │
│ L3 内部细节   │ │               │ │               │
└───────┬───────┘ └───────┬───────┘ └───────┬───────┘
        │ tmux send-keys / capture-pane（进程外驱动，不是 agent 嵌套）
        ▼               ▼               ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐
│ L3  tmux win  │ │ L3  tmux win  │ │ L3  tmux win  │
│ zyz-task-A    │ │ zyz-task-B    │ │ zyz-task-C    │
│               │ │               │ │               │
│ 独立的        │ │ 独立的        │ │ 独立的        │
│ claude 进程   │ │ claude 进程   │ │ claude 进程   │
│ （bypass）    │ │               │ │               │
│ 运行          │ │               │ │               │
│ /execute-task │ │               │ │               │
│               │ │               │ │               │
│ execute-task  │ │               │ │               │
│ 有自己的：    │ │               │ │               │
│  · 主 agent   │ │               │ │               │
│  · impl-agent │ │               │ │               │
│  · test-agent │ │               │ │               │
│  · review-agt │ │               │ │               │
│               │ │               │ │               │
│ 在自己的      │ │               │ │               │
│ worktree 中   │ │               │ │               │
│ 工作 ·        │ │               │ │               │
│ 对上层不可见  │ │               │ │               │
└───────┬───────┘ └───────────────┘ └───────────────┘
        │ execute-task 需要用户决策时
        ▼
┌───────────────────────────────────────────────────────────┐
│ 用户  ── attach 到 tmux window ──> 与 L3 的 claude        │
│       直接对话                                            │
│                                                           │
│ L1 只通知"window Y 需要你"；它绝不转述问答内容。          │
│ attach 之后，用户直接与 L3 交互；问答绝不经过 L1/L2。     │
└───────────────────────────────────────────────────────────┘

通信媒介（全部经由文件 + 返回值；不跨 agent 共享内存；
用户直接 attach 到 pane）：
  L1 ←→ 文件(<list-dir>/...) ←→ L2                 [L2 写状态文件，L1 读]
  L1 ←  返回值(一行) ←  L2                         [L2 退出时返回]
  L2 ←→ tmux(send-keys/capture) ←→ L3              [进程外驱动]
  L3 ←→ 文件(它的 worktree 中 + worker-status.md)  [L3 自己的执行状态]
  用户 ←→ tmux attach ←→ L3                        [问答，绝不经过 L1/L2]
```

### 职责边界表

| 层 | 能看到 | 不能碰 | 能写 | 与用户的关系 |
|---|---|---|---|---|
| **L1 主 agent** | 主条目、`worker-status.md`（投影）、`dispatch.md`、`heartbeat`、`monitor.md`、L2 返回的一行摘要 | L3 内部细节（设计 / subtask / 实现 / 测试 / 评审）、L3 与用户问答的正文、worker pane 的原始内容 | 主条目、`SUMMARY.md`、通知 | 编排层面的交互 + 通知"window Y 需要你"（绝不转述内容） |
| **L2 driver subagent** | 它所驱动的那一个 worker：该 worker 的 `worker-status.md`、`dispatch.md`（向上投影），以及必要时用 `capture-pane` 瞄一眼 | 该 worker 的 L3 内部细节（设计 / subtask / 实现 / 测试 / 评审 / `question.md` 正文）、其他 worker、主条目层面的决策 | 该 worker 的 `monitor.md`（以及为介入而向记录在案的 pane `send-keys`） | 不面向用户；只在 `monitor.md` 里记一个"needs-user"标记 |
| **L3 execute-task** | 自己 worktree 里的一切、自己的 `worker-status.md` | 其他 worker 的 worktree、主清单、L1/L2 的存在本身 | `worker-status.md`、`question.md`、自己任一 worktree 里的代码/文档 | 用户 attach 进来时与用户直接问答 |
| **用户** | 一切（可以 attach 任何 window） | — | 主条目、回答（直接在 pane 里输入） | 编排层面交互 + attach 进某个 window 与 L3 直接问答 |

### 关键不变量

- **只有 L2 会交互式触碰 pane**（`send-keys` / `capture-pane`）。L1 可以调用只读的 `orch-check-worker.sh` 获取投影，但绝不碰 pane；L3 是被驱动的一方，不是对等方。
- **`worker-status.md` 和 `dispatch.md` 是 L3 对整体状态的向上投影**，不属于"内部细节"——L1 和 L2 都可以读（它们是整体状态的权威来源）。
- **"内部细节"指的是** L3 的设计文档、subtask 状态、实现 / 测试 / 评审文件，以及 `question.md` 的**正文**。L1 和 L2 绝不读取这些。
- **L1/L2 绝不转述问答。** execute-task 各阶段的确认和阻塞性决策只在 L3 与用户之间进行。L1 只通知"任务 X 在 window Y 需要你"；用户 attach 进去直接回答 L3。问答绝不经过 L1/L2。
- **notify 以实时轮询得到的 wait-state 为依据，绝不以 `monitor.md` 为依据。** L1 绝不写 `monitor.md`；早先某个 L2 留下的过期 `needs-user=true` 只是无害的草稿状态（下次真正派发 L2 时会从新的轮询结果重新推导）。
- **worktree 隔离发生在 worker 之间，而不是 worker 内部。** worker 之间绝不碰彼此的 worktree（spawn 要求所有任务的 worktree 路径两两不相交，以此强制执行）；在单个 worker 内部，该 worker 对自己的所有 worktree（涉及的每个仓库各一个）拥有完全写权限。

## 主 agent 加载

使用本 skill 时，当前面向用户的对话 agent 就是编排器（主 agent）。首先加载并遵循下面这份完整的控制器提示词：

```text
prompts/main-agent.md
```

该文件不是 subagent。它定义当前对话 agent 如何协调编排循环、如何与用户沟通。

## 提示词文件

按需加载以下文件：

- 主 agent 控制器提示词：`prompts/main-agent.md`（skill 启动时首先加载）。

orchestration-scheduling-task skill 没有主 agent subagent，但它确实拥有一个项目级 subagent：**L2 driver**，即 `agents/orch-driver-agent.md`（镜像在 `subagents/orch-driver-agent.md`，与 execute-task 的 subagent 采用相同的双份布局）。L1 按需派发它去驱动某一个 worker 的 pane（见上文架构（三层）一节）。编排器还会派发 `execute-task` worker，这些 worker 又会使用项目 subagent `implementation-agent`、`test-agent`、`review-agent`。

创建主清单相关文件时使用这些模板：

- 主清单任务条目：`templates/master-list-task-entry.md`
- Worker 状态：`templates/worker-status.md`
- Driver 状态（归 L2 所有）：`templates/monitor.md`
- 异步问答：`templates/question-answer.md`

## 核心规则

- **长期运行状态存放在文件里。** 主清单目录 `<list-dir>` 是唯一的事实来源。对话上下文绝不能替代文件。编排器的每一个决策都必须能从磁盘内容推导出来；一个事实如果不在磁盘上，就等于不存在。参见 [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md)。
- **编排器与 cwd 无关；每个任务自带 `source-repo`。** 编排器可以从 `~/` 或任何目录启动（不一定是 git 仓库）。每个主条目的 `source-repo:` frontmatter 字段是必填的，指向该任务*主*（primary）项目 git 工作树的绝对路径；该仓库的所有 git 操作都限定在 `git -C "$SOURCE_REPO"` 范围内。跨多个仓库的任务用编号键（`source-repo-2:`、`source-repo-3:`、…）列出其余仓库；spawn 会在该任务唯一的 tmux session 内为每个仓库各建一个 worktree（兄弟目录布局）。因此一份主清单可以跨多个仓库派发 worker，单个 worker 自身也可以管理多个仓库。
- **每份主清单同一时间只能有一个编排器。** 编排器启动时通过 `flock` 获取 `<list-dir>/.orchestrator.lock`。针对同一份清单启动第二个编排器会失败。这把锁防的是编排器与编排器之间的并发；用户对主条目的编辑则靠流程约束来保护（用户必须先 `Ctrl-C` 停掉编排器——见下文）。
- **主条目由用户与编排器共同编写。** 编排器通过 `tmpfile + rename` 写入。**用户在外部编辑器中编辑主条目之前，必须先 `Ctrl-C` 停掉编排器**，让 flock 释放。编辑保存后再重启编排器。
- **每个 worker 只写自己的运行时文件。** worker 写 `worker-status.md`、`question.md`，并通过守护进程更新 `heartbeat`。编排器只读、绝不写 worker 的运行时文件（清理时的归档除外）。编排器写主条目；worker 绝不写主条目。
- **启发式分析永远是暂定的。** 编排器写下的依赖、项目、merge-with 建议，在主条目 frontmatter 中带有 `deps-tentative: true`，直到用户把它改成 `false`。
- **不自动改状态、不自动合并、不自动清理。** 任何交付动作都需要 `## Pending Merge Approval` 中有对应的、明确的用户令牌；编排器绝不自主发起这些动作。令牌：`confirmed`（把用户的确认转交给 worker，由 worker 写入 `phase=done`，编排器随后把它镜像为 `state: completed`；不直接写状态，不合并/清理）、`merge` / `merge: <base>`（合并到 base 并 push，不改状态）、旧版 `approved`（合并 + completed + 清理，原子执行——会短路掉本 tick 同时存在的其他令牌）、`cleanup-approved`（清理 worktree）、`rejected: <reason>`（退回 blocked）。清理 stale worker 仍然需要 `cleanup-approved`。对于多仓库任务，合并和清理会针对 worker 的 worktree 集合**逐仓库**执行（仓库集合取自该任务的 `dispatch.md`）：合并不是跨仓库原子的，遇到第一个无法合并的仓库即快速失败，重新运行是幂等的（已合并的仓库会被跳过）。
- **`task-id` 采用白名单。** 辅助脚本拒绝任何不匹配 `^[a-zA-Z0-9_-]+$` 的 `task-id`。`tmux` session、git 分支、worktree 路径和运行时目录都会嵌入字面的 `task-id`。
- **worker 的 tmux session 名使用固定前缀 `zyz-task-<task-id>`。** 默认 git 分支是 `task/<task-id>`。默认合并 base 是 `main`；可通过主条目 frontmatter 的 `base:` 字段覆盖。
- **心跳阈值默认为 300 秒**（按设计规格 §A.6 分为 fresh / suspect / stale 三档）。当 worker 报告 `wait-state=waiting-user` 时，阈值放宽到 900 秒。除非是严格的本地（非网络）文件系统，否则不要低于 120 秒。
- **与 `execute-task` 的编排模式握手。** 编排器把 `ZYZ_WORKER_STATUS_FILE`、`ZYZ_TASK_ID`、`ZYZ_QUESTION_FILE`、`ZYZ_ANSWER_FILE`、`ZYZ_HEARTBEAT_FILE` 导出到 worker 的 tmux session 中。worker 的 `execute-task` skill 检测到 `ZYZ_WORKER_STATUS_FILE` 后，会把 phase/wait-state 写进该文件。编排器只能看到 worker 刷写出来的内容；上下文里的记忆不算数。
- **容器复用由用户声明，且旧任务必须已完成。** 新任务可以在它**自己的**主条目 frontmatter 中声明 `reuse-from: <old-task-id>` + `reuse-scope: worktree|tmux|both` + `reuse-claude: true|false`，从而复用一个*已完成*任务遗留的 tmux session 和/或 git worktree。复用会移交旧任务的**整个 worktree 集合**（所有仓库），而不是单个 worktree——不支持只复用集合中某一个仓库的部分复用。此时派发路径调用 `scripts/orch-reuse-worker.sh`（而不是 `orch-spawn-worker.sh`）。复用只是*关联*容器——它绝不推进或改写旧任务，旧任务保持 `completed`。`reuse-from` 指向的目标必须在**同一个** `<list-dir>` 中且已经 `completed`；否则拒绝复用，新任务也不会被派发。参见下文 `## 容器复用`。

## 工作流

编排器运行一个循环。每个 tick（手动调用、自动定时模式下的自调度，或 `/loop` 唤醒）执行：

1. **扫描** —— `scripts/orch-scan-tasks.sh <list-dir>` 列出每个任务条目、其声明的 `state`，以及（对于 in-progress/paused 任务）worker 报告的 phase + wait-state。缺失或非法的 `state` 值按 `not-analyzed` 处理。
2. **分析** —— 对 `not-analyzed` 任务做依赖 / 项目 / merge-with 分析。把暂定结果写进主条目的 `## Orchestrator Analysis` 一节。**如果 `## Description` 为空，保持 `state: not-analyzed`，并在分析一节写入 `needs Description`；不要派发。**
3. **规划** —— 决定本 tick 派发哪些 `ready` 任务。并行上限是 `ZYZ_MAX_PARALLEL_WORKERS`（**默认 `-1` = 不设上限**；设为正整数即可限流——为 `-1` 时不施加上限，每个 `ready` 任务都可派发）。把依赖已满足的 `blocked` 任务移到 `ready`。**资源提醒：** 每个 worker = 1 个 tmux session + n 个 git worktree（每个仓库一个；单仓库任务 n=1）+ 1 个完整的 `claude` 进程（运行整个 `execute-task` 工作流，包括它自己的 subagent）——远比 execute-task 那些纯提示词的 subagent 重。不设上限时，要留意 API 配额 / 内存 / 磁盘；需要限制就设一个正数上限。**磁盘 I/O 提醒：** 每个 worker 默认被注入 Go 构建优化环境变量（`GOTMPDIR` 放在 tmpfs 内存盘上 + `GOFLAGS=-p`）；**总编译并行度 = worker 数 × p**，因此控制磁盘压力应调低 `p`（`ZYZ_GO_BUILD_P`，默认 4），而不是减少 worker 数（参见 README *Go 构建 I/O 优化注入* 一节以及 `ZYZ_GO_BUILD_OPT` / `ZYZ_GO_TMPFS_DIR`）。
4. **派发** —— 对每个选中派发的任务，编排器分两个阶段工作。先调用 `scripts/orch-spawn-worker.sh <task-id> <list-dir>`，**只搭建容器**：为任务声明的每个仓库各建一个 worktree（无论仓库多少，都只有一个 tmux session）、tmux session、pane 内的心跳守护进程，以及 `dispatch.md` 的 Phase-1 字段（多仓库任务还包括编号的 `worktree-N` / `source-repo-N` / `branch-N` / `base-N` 字段组）。spawn **绝不**启动 `claude`（不存在 `--auto-start`）。然后**派发一个 `intent=first-dispatch` 的 L2 `orch-driver-agent` subagent** 去做 pane 重活——以 bypass 模式启动 `claude`、点掉确认页、做就绪探测、运行 `/execute-task`。同时派发多个新 worker 时，它们的 L2 driver 一次性批量启动（单条消息，多个 `Agent` 调用）。
5. **轮询** —— 对每个 `in-progress` 或 `paused` 任务，编排器**内联**调用 `scripts/orch-check-worker.sh <task-id> <list-dir>`（只读：文件 + `pgrep`，绝不碰 pane），并把 worker 状态投影到主条目。这个内联轮询每个 tick 都会对**每一个**活跃 worker 运行（包括被限流的），也是检测"用户已回答、worker 已离开 `waiting-user`"的唯一位置。L1 **只**对轮询显示卡住/异常的 worker（session 已死但本应存活、心跳过期且 `phase-since` 连续数个 tick 不变、出现 Unknown command 迹象）派发 `intent=intervene` 的 L2 driver；健康的 worker **不**派 L2。`heartbeat-status=fresh` 时更新 `last-seen`。过期（stale）时，把 stale 摘要写进 `## Notes` 并缩短轮询间隔；不要悄悄改动主条目的 `state`。
6. **处理错误** —— 如果 worker 报告 `phase=error`，把主条目设为 `state: blocked`，把 worker 的 `## Last Output Summary` 复制进主条目的 `## Notes`，并缩短轮询间隔。
7. **闸门** —— 对于 `## Pending Merge Approval` 一节含有 `approved` 的任务，调用 `scripts/orch-merge-and-cleanup.sh <task-id> <list-dir> <base-branch>`。对于多仓库任务，它会对 worker worktree 集合中的每个仓库分别合并和清理（仓库集合从 `dispatch.md` 读取）；合并是快速失败的，重新运行是幂等的（已合并的仓库会被跳过）。
8. **汇报** —— 在对话窗口写一段简短摘要，并（重新）写入 `<list-dir>/SUMMARY.md`，列出所有任务及其当前视图。

完整的工作流细节、决策分支、失败模式和轮询节奏策略，请加载 `prompts/main-agent.md`。

## 文件协议

编排器与 worker 通过 `<list-dir>` 中的一小组文件通信。路径汇总：

| 文件 | 路径 | 写入方 | 读取方 |
|---|---|---|---|
| 主条目 | `<list-dir>/tasks/<task-id>.md` | 编排器 + 用户 | 编排器 + 用户 |
| worker 状态 | `<list-dir>/runtime/<task-id>/worker-status.md` | worker（execute-task） | 编排器 |
| monitor | `<list-dir>/runtime/<task-id>/monitor.md` | L2 orch-driver-agent | 编排器（L1） |
| dispatch | `<list-dir>/runtime/<task-id>/dispatch.md` | spawn（Phase-1）+ check（Phase-2） | 编排器 + 运维人员 |
| heartbeat | `<list-dir>/runtime/<task-id>/heartbeat` | pane 内的心跳守护进程 | 编排器 |
| question | `<list-dir>/runtime/<task-id>/question.md` | worker | 用户 |
| answer | `<list-dir>/runtime/<task-id>/answer.md` | 用户 | worker |
| lock | `<list-dir>/.orchestrator.lock` | 编排器（flock） | 编排器 |
| SUMMARY | `<list-dir>/SUMMARY.md` | 编排器 | 用户 |

这把锁只防编排器与编排器之间的并发。用户与编排器之间的并发靠流程约束处理：用户在编辑主条目之前，必须先 `Ctrl-C` 停掉编排器。

### 主条目 frontmatter（节选）

```yaml
task-id: <task-id>            # 不可变
project: <project name>       # 用户维护；仅作标签；省略时默认 = basename(主 source-repo)
source-repo: ~/workspace/<repo>  # 必填；主仓库；绝对路径或以 ~/ 开头；支持 ~/ 展开
source-repo-2: ~/workspace/<repo2>  # 可选；多仓库任务的额外仓库；从 2 开始编号，必须连续
state: not-analyzed           # not-analyzed | blocked | ready | in-progress | paused | awaiting-user-confirmation | completed
priority: normal              # low | normal | high
branch: task/<task-id>        # 默认值；用户可覆盖
branch-2: task/<task-id>      # 可选，按仓库设置的分支；默认取 branch 解析后的值
base: main                    # 合并 base；用户可覆盖
base-2: main                  # 可选，按仓库设置的 base；默认取 base 解析后的值
worktree: ~/.zyz-worker/worktrees/<project>/task/<task-id>          # 主 worktree = pane 的 cwd
worktree-2: ~/.zyz-worker/worktrees/<project>/task/<task-id>/<repo2>  # 可选；默认按仓库采用兄弟目录布局
tmux-session: zyz-task-<task-id>   # 任务级单一值，与仓库数量无关
reuse-from:                   # 可选；本清单中某个已完成任务的 task-id，复用它的容器
reuse-scope: both             # worktree | tmux | both；设置了 reuse-from 时必填（默认 both）
reuse-claude: true            # true（默认）| false；只在复用 tmux 时有意义
blocked-by: []                # 用户维护
merged-with: []               # 用户维护
deps-tentative: true          # 只有在用户批准分析后，编排器才把它清为 false
last-seen: <iso>              # 仅由编排器写入
heartbeat-stale-sec: 300      # 可选的覆盖值
created-at: <date>
updated-at: <date>
```

编号键（`source-repo-2:`、`branch-2:`、`base-2:`、`worktree-2:`、…）是可选的，只用于多仓库任务；`source-repo-N` 从 2 开始编号，且必须连续。只有一个 `source-repo:` 的条目完全向后兼容——解析、spawn、合并、清理都与以前完全一样。`branch-N` / `base-N` / `worktree-N` 每一项都可以省略并取默认值（各仓库的 branch/base 继承主仓库解析后的值；`worktree-N` 默认采用兄弟目录布局）。worktree 路径不得包含 `:`（该字符在 `ZYZ_WORKTREES` 环境变量和复用时的 `worktrees:` 行中用作条目分隔符）。

用户可写的 `state:` 合法值是 `not-analyzed | blocked | ready | completed`。`in-progress | paused | awaiting-user-confirmation` 由编排器自行写入（`awaiting-user-confirmation` 由编排器根据 worker 的 phase 投影得出，绝不由用户手写）。

### Worker 状态 frontmatter（节选）

```yaml
task-id: <task-id>
phase: design | implementation | testing | review | delivery | awaiting-confirmation | done | error
phase-since: <iso>
wait-state: none | waiting-user | waiting-subagent | waiting-resource
waiting-reason: <free text; non-empty when wait-state != none>
expected-resume-by: <iso; non-empty when wait-state != none>
last-flush: <iso>
```

worker 在任何挂起之前、派发 subagent 之前，以及每次 phase 切换时刷写状态。编排器只读、绝不写 `worker-status.md`。

## 状态机

七个显式状态 + 一个由编排器推导出的状态（`stale`）：

| 状态 | 含义 | 由谁设置 |
|---|---|---|
| `not-analyzed` | 新任务；编排器尚未分析。 | 模板默认值 / 扫描 |
| `blocked` | 依赖未满足，或 worker 报告了 `phase=error`。 | 编排器 |
| `ready` | 没有阻塞项；可以派发。 | 编排器 |
| `in-progress` | worker 已派发；tmux session 存活；心跳新鲜；worker 处于工作阶段（`design`..`delivery`）且 `wait-state=none`。 | 编排器 |
| `paused` | worker 已派发；`wait-state != none`。 | 编排器（投影 worker 的 wait-state） |
| `awaiting-user-confirmation` | worker 到达 `phase=awaiting-confirmation`（自我声明已完成，等待用户确认）。与 `paused` 不同（`paused` 是任务中途在等问答/资源）。 | 编排器（投影 worker 的 phase） |
| `completed` | 交付已确认：worker 到达 `phase=done`（用户已确认——直接在 worker window 中确认，或通过 L1 转交的确认），并由编排器镜像过来；或者旧版 `approved` 令牌执行了原子的合并+完成+清理。合并到 base 可能发生过，也可能没有（done 与合并已解耦）。终态且不可变；交付后的变更要通过一个**新的**、取而代之的任务进行。 | 编排器 |
| `stale`（推导） | 心跳超过 stale 阈值，或 `phase-since` 连续 5 个 tick 不变。主条目的 `state:` **不**会被改写；stale 通过 `## Notes` 一节和 `last-seen` 字段报告。 | 编排器 |

状态转换（非正式）：

- `not-analyzed` → `ready`（分析通过，无阻塞项）| `blocked`（分析通过但依赖未满足）
- `blocked` → `ready`（依赖已满足或错误已解决）
- `ready` → `in-progress`（编排器派发）
- `in-progress` → `paused`（worker 写入 `wait-state != none`）| `awaiting-user-confirmation`（worker 写入 `phase=awaiting-confirmation`）| `blocked`（worker 写入 `phase=error`）
- `paused` → `in-progress`（worker 写入 `wait-state=none`）
- `awaiting-user-confirmation` → `in-progress`（worker 回滚，例如用户要求修改）| `completed`（用户确认后 worker 写入 `phase=done`——直接在 worker window 中确认，或经由 L1 的 `confirmed`→转交路径——再由编排器把 `phase=done` 镜像为 `completed`；或者走旧版 `approved` 原子路径）

worker 到达 `phase=awaiting-confirmation` 时投影为 `state: awaiting-user-confirmation`。只有当 worker 写入 `phase=done`（在用户确认之后）并由编排器镜像时，才会到达 `completed`——或者经由旧版 `approved` 原子路径；绝不会由 `confirmed` 令牌直接到达。`completed` 是终态且不可变；编排器判断下游任务能否启动时，依据的就是它（参见 `prompts/main-agent.md` 中关于依赖解锁的指引）。交付后的变更要通过一个**新的**、取而代之的任务进行；绝不重新打开或回滚 `completed`。

**容器复用**任务（主条目设置了 `reuse-from`）**不新增任何状态**——它走的是同样的七个状态。唯一的区别在派发环节：编排器先在**分析**步骤中做复用前置检查（旧任务在本清单中、已 `completed`、scope 合法、旧容器仍然存在），然后在**派发**步骤中调用 `orch-reuse-worker.sh` 并派发一个 L2 `reuse-dispatch`。旧的 `reuse-from` 任务始终保持 `completed`（复用绝不推进它）。参见 `## 容器复用`。

完整的状态机，以及 `execute-task` 工作流各位置对应的 phase 映射表，见设计规格（`.zyz-worker/tasks/orchestration-scheduling-task/design-spec.md` 的 §A 与 §D.5）。

### PR 流程（合并在编排器之外完成）

并非每个分支都合并到 `main`，有些还需要 PR + 人工评审。原生的 PR 创建不在范围内。要通过 PR 完成任务：让 worker 到达 `phase=awaiting-confirmation`，自己（在 zyz-worker 之外）开 PR、评审并合并——多仓库任务每个仓库一个 PR，因为每个仓库都有自己的分支——然后在 `## Pending Merge Approval` 中写入 `confirmed`（**不是** `merge`），这样编排器会记录 `state: completed`，而不执行任何 git 合并。编排器绝不开 PR，也绝不合并 PR。

如果 PR 评审返回了修改请求，worker 主 agent 会对其进行评估，而不是盲目接受——修复成立的发现，对不成立的发现在 PR 上发布有理有据的拒绝说明（参见 `skills/execute-task/prompts/main-agent.md` 的 `## PR 评审处理` 与 `skills/execute-task/references/pr-review.md`）。根据 PR 反馈采取行动的 worker 会按需把 `phase` 从 `awaiting-confirmation` 回滚到 `implementation`/`testing`/`review`；只有在你对处理后的 PR 满意时，才写入 `confirmed`。

## 容器复用

新任务可以复用一个**已完成**任务遗留的 tmux session 和/或 git worktree，而不必搭建全新的容器。如果旧任务是多仓库任务，复用会把它的**整个 worktree 集合**（所有仓库）作为一个整体接管——不支持只复用集合中的某一个仓库。这是可选功能，完全由用户在新任务的主条目 frontmatter 中声明：

```yaml
reuse-from: <old-task-id>     # 存在 => 复用；必须是本清单中的已完成任务
reuse-scope: both             # worktree | tmux | both（默认 both）
reuse-claude: true            # true（默认）| false；只在复用 tmux 时有意义
```

当选中派发的任务有非空的 `reuse-from` 时，**派发**步骤调用 `scripts/orch-reuse-worker.sh <new-id> <list-dir>`（而不是 `orch-spawn-worker.sh`），然后派发一个 `intent=reuse-dispatch`（而不是 `first-dispatch`）的 L2 driver。其余一切（轮询 / 投影 / 闸门 / 汇报）不变——新任务有自己的 `runtime/<new-id>/`，和其他 worker 一样被观察。

### scope → 容器动作

| `reuse-scope` | worktree 集合 | tmux session | 心跳 | claude |
|---|---|---|---|---|
| `worktree` | 复用旧 worktree 集合（相同目录/分支） | **新的** `zyz-task-<new-id>` | pane 内守护进程（与 spawn 相同） | **新的** claude（干净环境；类似 `first-dispatch`）——`reuse-claude` 被**忽略**（`reuse-claude-effective=n/a`） |
| `tmux`（`reuse-claude:true`，默认） | **旧的** worktree 集合（被复用 pane 的 cwd 固定在旧的主 worktree 上，不可改变；`worktree:` 字段被忽略） | 复用旧 session | 在被复用的 session 里开一个**新 window** 运行守护进程 | **同一个**正在运行的 claude（in-band 运行时配置块） |
| `tmux`（`reuse-claude:false`） | 旧 worktree 集合（重启仍在同一个 pane 里） | 复用旧 session | 新 window 守护进程 | 在被复用的 session 里**重启** claude（干净的握手） |
| `both`（`reuse-claude:true`，默认） | 复用旧 worktree 集合 | 复用旧 session | 新 window 守护进程 | **同一个**正在运行的 claude（in-band 配置块） |
| `both`（`reuse-claude:false`） | 复用旧 worktree 集合 | 复用旧 session | 新 window 守护进程 | **重启** claude |

### 同一 claude 复用：in-band 运行时配置块 + 新 window 心跳

仍在运行的 claude 看不到重新导出的环境变量（Bash 子进程继承的是 claude 启动时的环境，而不是之后在 pane 里 `export` 的变量）。因此当 `reuse-claude-effective=true` 时，新任务的运行时路径由 L2 `reuse-dispatch` driver **以 in-band 运行时配置块的形式**交给正在运行的 claude（这是一段结构化文本消息，用 `[zyz-worker reuse-runtime-config]` … `[/zyz-worker reuse-runtime-config]` 包围，携带 `task-id` / `worker-status-file` / `question-file` / `answer-file` / `heartbeat-file`，多仓库复用任务还会带一行可选的 `worktrees:`——以冒号分隔，主仓库在前），与 `/zyz-worker:execute-task <new-id>` 一起发送进 pane。execute-task 的契约（`skills/execute-task/SKILL.md ## 编排模式`）规定，在整个任务生命周期内该配置块**覆盖**启动时的 `ZYZ_*` 环境变量，**包括 `task-id` 以及所有由 task-id 派生的路径**（详细的 `.zyz-worker/tasks/<task-id>/` 状态目录、commit/分支引用）。

由于 claude 占着被复用 session 原来的 window/pane，新任务的心跳守护进程运行在被复用 session 中新开的一个 **tmux window** 里（无法在 claude 的 pane 里启动 shell 守护进程）。该守护进程指向新任务的心跳文件，并随被复用的 session 一起消亡（`orch-heartbeat-daemon.sh` 的 `tmux has-session` watchdog 跟踪的是 session 名，因此新 window 也在覆盖范围内）。复用 worker 还会在每次刷写时 `touch` 一下 in-band 配置块里的 `heartbeat-file`，作为备用的存活信号。

### 复用绑定与恢复语义

同一 claude 复用的任务与旧任务共享 claude 进程：它的 `dispatch.md` 中 `claude-pid` 与旧任务相同（同一个进程），`claude-session-id` / `transcript-path` 指向**共享的** session——这是预期行为，不是绑定错乱。因此，同一 claude 复用的任务**只支持恢复情形 1（attach）**：`orch-check-worker.sh` 为它写入**只含 attach** 的 `## Recovery` 正文，并有意省略独立的 `claude --resume` 命令，因为从两个 `dispatch.md` 文件分别 resume 同一个共享 session-id 是已知的陷阱。`reuse-claude-effective=false`（重启）和 `reuse-scope=worktree`（新 session）的任务有各自独立的 claude session，恢复方式与普通 spawn 完全相同（attach **和** `--resume` 都可用）。

### 共享容器的清理（执行 `cleanup-approved` 之前请先读这一节）

复用任务与其 `reuse-from` 旧任务**共享** tmux session 和/或 worktree 集合。对其中任何一个执行清理，都会杀掉共享的 session 并删除共享的 worktree，从而影响另一个。编排器**不**对共享容器做引用计数（这是有意设定的非目标）。有两道保护：(1) 清理仍然需要明确的 `cleanup-approved` 令牌（绝不自动执行）；(2) 对 `reuse-from` 任务兑现 `cleanup-approved` 之前，编排器的闸门步骤会在该任务的 `## Notes` 中追加一条共享容器警告（写明 `reuse-from` 旧 id 以及共享的 session/worktree）。清理之前，请确保所有共享方都已完成。

## 长期运行状态

本 skill 端到端地贯彻 zyz-worker 的[长期运行状态约定](../../docs/conventions/long-running-state.md)：

- 主清单目录**就是**状态。编排器必须从磁盘内容推导出每一个决策。
- worker 在任何挂起之前写 `worker-status.md`。
- 心跳守护进程存活期间每 30 秒写一次 `heartbeat` 文件（它随 tmux session 一起消亡——不需要手动 `pkill`）。
- 编排器每个 tick 写一次 `SUMMARY.md`。

如果编排器的对话上下文被丢弃或压缩，重新运行 `/orchestrate-tasks <list-dir>` 即可仅凭磁盘内容重建完整的态势感知。

## 崩溃恢复

每个 worker 都会在自己的运行时目录 `<list-dir>/runtime/<task-id>/dispatch.md` 写一份 `dispatch.md`。该文件把 worker 的 tmux session/pane 与它的 claude session-id 和 transcript 路径绑定在一起，这样 tmux session、claude 进程或编排器崩溃后都能恢复。spawn 辅助脚本在预检的最后一步写入 Phase-1 字段（确定性的、spawn 时即可得到的字段）；`orch-check-worker.sh` 在后续轮询中惰性地填入 Phase-2 字段（claude 侧字段）——`claude-pid`、`claude-session-id`、`transcript-path`、`first-seen-iso`——并在前三项全部填好后，用具体命令重新生成 `## Recovery` 正文。

运行 `bash scripts/orch-check-worker.sh <task-id> <list-dir>` 并阅读它的 stdout：它现在会输出一行 `dispatch-bound=true|false|<empty>`（`true` = Phase-2 三项已填好；`false` = dispatch.md 存在但三项不完整；空 = dispatch.md 不存在）和一行 `session-alive=true|false`（tmux session 是否仍然存在）。当 `worker-status.md` 存在但缺少 `---` 分隔符时，它还会输出 `worker-status-malformed=true`——只会有这一种形式，绝不会输出 `=false`——这意味着解析出的每个字段都是空的，报告的 `phase`/`wait-state` 不可信（参见 `prompts/main-agent.md` 中的轮询步骤）。这两行合起来就能告诉你适用下面哪种恢复情形。要直接从 dispatch.md 取出单个字段，使用与辅助脚本相同的 `awk` 写法：

```text
awk -F': ' '/^<field>:/{sub(/^ +/,"",$2); print $2; exit}' <list-dir>/runtime/<task-id>/dispatch.md
```

这个简化写法假定文件是 spawn/check 写出的格式（没有行内 `#` 注释，值里没有 `: `）；要解析一般的 frontmatter，辅助脚本里的 `fm_field` 更稳健。

四种恢复情形：

1. **tmux session 仍然存活**（`tmux has-session -t <tmux-session>` 退出码为 0；等价于 `session-alive=true`）：
   - attach 进去，在现有 pane 中继续工作：`tmux attach -t <tmux-session>`。

2. **tmux session 已死，但 `transcript-path` 已填写**（`session-alive=false`、`dispatch-bound=true`）：
   - 阅读 `dispatch.md ## Recovery`，获取已替换好真实值的确切命令。
   - 运行 `cd <worktree> && claude --resume <claude-session-id> --plugin-dir <plugin-root>`（对于多仓库任务，`<worktree>` 是主 worktree = pane 的 cwd）。Claude 会读取记录在 `transcript-path` 的 JSONL 并恢复对话。`--plugin-dir` 让 `/execute-task` 在恢复后的 session 中保持已注册——**省略它会再次触发 "Unknown command: /execute-task" 失败**，因为恢复的 transcript 只恢复对话，不恢复插件注册。

3. **dispatch.md 有 Phase-1 字段但没有 Phase-2 字段**（`dispatch-bound=false`——claude 从未完成绑定；通常是 `/execute-task` 在斜杠命令层被拒绝、spawn 在 claude 注册前被杀掉，或者 claude 从未完成第一次 LLM 往返）：
   - 没有可供恢复的有用 claude 状态。把它当作一个全新任务：用 `scripts/orch-cleanup-worker.sh <task-id> <list-dir>` 清理 worktree，然后从主条目重新派发。

4. **dispatch.md 完全不存在**（`dispatch-bound=` 为空）：有两种可能的原因——(i) 这是本功能引入之前 spawn 的旧 worker，或 (ii) spawn 在到达写 dispatch.md 这一步之前就崩溃了。用 `session-alive` 来区分：
   - `session-alive=true` → 按情形 1 attach 并继续。这个 worker 可能仍然可用。
   - `session-alive=false` → 没有记录任何恢复信息；视为运行时已无法挽救。清理后从主条目重新派发。

   （如果需要 worker 最近一次活动的时间戳，读取 `worker-status.md` 的 `last-flush`。编排器只读、绝不写 `worker-status.md`。）

### 崩溃语义

按下表把运行时目录的可观察状态映射为相应的解读：

| dispatch.md | Phase-2 状态 | session-alive | 解读 |
|---|---|---|---|
| 存在 | 空 | 存活 | claude 尚未启动或尚未绑定；对于由 L2 驱动的 worker，这是 L2 启动 `claude` 之前正常的首次启动过渡态（spawn 绝不启动 `claude`——不存在 `--auto-start`） |
| 存在 | 空 | 已死 | worker 在绑定前就死了（claude 没走多远） |
| 存在 | 部分 | 存活/已死 | claude 已注册，但还没有 LLM 往返（最可能是 `/execute-task` 被拒绝，而用户之后什么也没输入） |
| 存在 | 完整 | 存活/已死 | 正常绑定的 worker；按情形 1（存活）或情形 2（已死）恢复 |
| 不存在 | n/a | 存活 | spawn 在预检中途、写 dispatch.md 之前崩溃（spawn 只在其 Step 6 写入**初始**的 `worker-status.md`，所以该文件可能仍然存在）；需人工处理 |
| 不存在 | n/a | 已死 | 本功能之前的旧 worker，没有恢复信息；按情形 4 处理 |

**范围说明**：自动检测这些状态并自动把主条目设为 `state: error`，**不在**本功能范围内。本节只是给人工运维者的文档性指引——编排器的轮询循环**不会**自动检测这些崩溃状态，也不会据此采取行动。

### 复用容器的恢复

容器复用 worker（其 `dispatch.md` 中 `reuse-from` 非空）需要根据 `reuse-claude-effective` 注意不同的恢复事项：

- **同一 claude 复用**（`reuse-claude-effective=true`，即 `reuse-scope=tmux`/`both` 且 `reuse-claude:true`）：该任务与旧任务共享 claude 进程和 session。它的 `claude-pid` 与旧任务相同，`claude-session-id` / `transcript-path` 指向**共享的**（旧+新合并的）session——这是预期行为，不是绑定错误。恢复方式**只有情形 1**：`tmux attach -t <tmux-session>`（被复用的 session）。**不要为该任务单独运行 `claude --resume`**——从两个 dispatch.md 文件分别 resume 共享的 session-id 是陷阱；而且即使旧任务的运行时已经归档，`--resume` 解析到的仍是那个共享 session。`orch-check-worker.sh` 会为这类任务写入只含 attach 的 `## Recovery` 正文，并有意省略 `--resume` 命令；如果你在同一 claude 复用任务上看到了生成的 `--resume` 行，忽略它，改为 attach。
- **重启 claude 的复用**（`reuse-claude-effective=false`）和**新 session 复用**（`reuse-scope=worktree`、`reuse-claude-effective=n/a`）：这些任务有各自**独立的** claude session，恢复方式与普通 spawn 完全相同——情形 1（attach）和情形 2（`claude --resume`）都适用。

复用任务 `dispatch.md` 中的 `heartbeat-window-id` 字段仅用于诊断（它是同一 session 中新开 window 里那个心跳守护进程的 window id）。不要据此推导清理/kill 逻辑——杀掉 session 时，watchdog 会把守护进程一并拆掉。

### dispatch.md 绑定如何工作（以及 Phase-2 为何延迟绑定）

Phase-2 之所以延迟绑定，是因为 Claude Code *何时*持久化它的 session 文件。在经过验证的主机上（Claude Code v2.1.152，macOS），Claude 只在 session 第一次成功完成 LLM 往返之后才写入以下两个文件——绝不在启动时写：

- `~/.claude/sessions/<pid>.json` —— session 指针。文件名中的 `<pid>` 等于 claude 进程的 PID，内容带有 `{sessionId, cwd, ...}`。`orch-check-worker.sh` 从中读取 `sessionId`。
- `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` —— 完整的 transcript。`encoded-cwd` 是（主）worktree 的**物理**路径（`pwd -P`，因此 macOS 的 `/var → /private/var` 这类符号链接会被解析），把其中的 `/` 和 `.` 都替换成 `-`，再把连续的 `-` 压缩成一个。`orch-check-worker.sh` **不会**通过重建这个目录名来定位 transcript：它用 session-id（全局唯一的 UUID）通过 `find ~/.claude/projects -name "<sessionId>.jsonl"` 发现 JSONL，因此发现过程不受 claude 具体路径编码规则的影响。记录下来的 `encoded-cwd` 字段会如实维护，用于诊断和恢复命令路径，但绑定并不依赖它。

恢复运维者需要理解的后果：

- worker 的 claude 进程可能已经**存在**（因此 `claude-pid` 可以通过 `pgrep -P <shell-pid> -n -x claude` 绑定），但要再过几秒到几分钟，它的 `session-id` 和 `transcript-path` 才能在磁盘上被发现。这就是上表中 `存在 | 部分` 那一行，也是正常的 `dispatch-bound=false` 过渡态——不是错误。
- 只有在第一次往返发生之后，`claude --resume <session-id>` 才有 transcript 可以恢复。在此之前确实没有任何东西可恢复（情形 3）。
- claude 进程是 pane shell 的**直接**子进程，这正是 `pgrep -P <shell-pid>` 能找到它的原因。如果未来的 Claude Code 版本改变了这些文件的刷写时机或进程的父子关系，在依赖这一时序之前要重新验证。

## 可选技能与插件

在扫描、分析、派发或汇总之前，先检查当前 agent 是否已经有相关的技能、插件或工具可用：

- 使用 git 相关的技能（例如本插件中的 `git-worktree` skill）推导默认 worktree 路径（多仓库任务每个仓库一个）。
- 编排器默认已经会自动轮询：每个 tick 通过 `ScheduleWakeup` 以动态间隔自调度下一个 tick（参见 `prompts/main-agent.md` 中的节奏策略）。用 `/loop` 斜杠命令（Claude Code）包裹是一个可选的显式替代方案；无论哪种方式，间隔都由同一套节奏策略决定。
- 如果可用，使用文档、工程工作流或测试类技能（`llmdoc`、`superpowers`、…）；在 SUMMARY 中记录使用情况。

这些可选能力不可用时，不要阻塞、不要失败，也不要要求用户安装任何东西。

## 维护说明

本 skill 与 `execute-task` 耦合。如果 `execute-task` 将来引入新的 phase，这里的编排模式契约必须同步更新：

- worker 状态模板中的 `phase:` 枚举必须扩展。
- phase 映射表（设计规格 §D.5）必须扩展。
- 本 SKILL.md 和 `prompts/main-agent.md` 应当明确提到这个新 phase。

如果 `dispatch.md` 的 schema 发生变化，以下各处要同步更新：`templates/dispatch.md` 模板；`scripts/orch-spawn-worker.sh` **以及** `scripts/orch-reuse-worker.sh` 中的 Phase-1 写入（两个写入方输出相同的字段集——spawn 把四个复用字段写成空值，reuse 填入它们；两者都从 `scripts/orch-worker-mcp-args.sh` 快照 `worker-mcp-args:`；对于多仓库任务，两者还都会输出编号字段组 `worktree-N` / `source-repo-N` / `branch-N` / `base-N`，N 从 2 开始，值都是完全解析后的非空值）；`scripts/orch-check-worker.sh` 中的 Phase-2 惰性填充 / 字段保留重写（`rewrite_dispatch_atomic` 会读回并重新输出四个复用字段 `reuse-from` / `reuse-scope` / `reuse-claude-effective` / `heartbeat-window-id`、`worker-mcp-args` 快照，**以及**编号的 `worktree-N` / `source-repo-N` / `branch-N` / `base-N` 字段组，否则第一次 Phase-2 轮询就会把它们丢掉）；从 `dispatch.md` 读取编号字段组作为权威仓库集合的 merge/cleanup/reuse 脚本；上文的 `## 崩溃恢复` 一节（包括复用容器恢复小节）；以及 `scripts/test-orchestration-helpers.sh` 中的 T8 用例（它们固化了字段列表和恢复命令的形态）。

如果**三层架构**发生变化（L1/L2/L3 的边界、L2 driver 的契约，或 pane 驱动所在的位置），以下各处要保持同步：driver agent 定义（`agents/orch-driver-agent.md` **及其**镜像 `subagents/orch-driver-agent.md`）、`templates/monitor.md` driver 状态模板、`prompts/main-agent.md` 中的 L1 循环、本 SKILL.md 中的架构（三层）/ 文件协议 / 崩溃语义各节，以及 `scripts/test-orchestration-helpers.sh` 中的 T 系列测试。特别是：spawn 只搭建容器（它绝不启动 `claude`；L2 driver 是唯一的启动者），`monitor.md` 归 L2 所有、L1 只读，notify 以实时轮询得到的 wait-state 为依据。L2 driver 的 `intent` 枚举有**四个**值——`first-dispatch`、`intervene`、`relay-confirmation`、`reuse-dispatch`——分别从以下 L1 位置派发：**派发**（普通 spawn 用 `intent=first-dispatch`，`reuse-from` 任务用 `intent=reuse-dispatch`）、**轮询**（`intent=intervene`，仅针对卡住的 worker），以及 **闸门**（`intent=relay-confirmation`，把用户确认转交进 worker pane）。如果 L2 driver 的契约或其 `intent` 枚举发生变化，以下**所有**位置都要保持同步：每一个派发位置；`intent` 枚举（`agents/` 和 `subagents/` **两份**中 driver 的 `## 输入` 一行、两份中 driver 的 `## intent=…` 各节标题，以及 `templates/monitor.md` 的 `driver-intent`）。

notify 机制有意设计为结构化签名 `(task-id, window, reason)`，其中 `reason ∈ {needs-user, needs-attention, error}`。当前版本只输出到对话窗口和 `SUMMARY.md`；这个签名就是**未来接入 webhook 的扩展点**——webhook / IM 通道将挂在这里。有意不提供 `orch-notify.sh` 脚本（notify 是 L1 自己的对话输出）；以后如果增加通道，保持签名不变，把新通道接在它后面。
