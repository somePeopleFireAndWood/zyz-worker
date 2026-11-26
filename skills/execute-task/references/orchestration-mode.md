# 编排模式

本文件是 `SKILL.md` `## 编排模式` 的完整契约。设置了环境变量 `ZYZ_WORKER_STATUS_FILE` 时，写第一份状态之前加载本文件。契约与 `orchestration-scheduling-task` skill 耦合，逐条保留，不改语义；只有指向工作流步骤的位置随 `SKILL.md` 的新结构更新。

设置了环境变量 `ZYZ_WORKER_STATUS_FILE` 时，本 skill 在编排模式下运行——也就是说，它是由 `orchestration-scheduling-task` skill 派发到自己的 tmux 会话中的。在此模式下，主 agent（以及经由它的每一个 subagent）**必须**把一份小的状态快照写入该文件路径，让编排器能看到这个 worker 在做什么。

## worker-status.md 字段

`worker-status.md` 中的必需字段是：

- `phase`——取值为 `design | implementation | testing | review | delivery | awaiting-confirmation | done | error` 之一
- `phase-since`——进入当前 `phase` 时的 ISO 时间戳
- `wait-state`——取值为 `none | waiting-user | waiting-subagent | waiting-resource` 之一
- `waiting-reason`——自由文本，仅当 `wait-state != none` 时非空
- `expected-resume-by`——ISO 时间戳，仅当 `wait-state != none` 时非空
- `last-flush`——本次写入的 ISO 时间戳

## 硬性规则

- **任何挂起之前先写盘。** 在挂起之前、派发 subagent 之前、收到 subagent 结果之后，以及进入任何新的工作流阶段时，都要原子地写入 `ZYZ_WORKER_STATUS_FILE`（tmpfile + rename）。绝不就地编辑该文件。
- **`worker-status.md` 必须是一个有效的 YAML frontmatter 文档。** 把所有必需的快照字段写在一对 `---` 围栏之内：文件第一行就是 `---`，接着是各字段，然后是一行收尾的 `---`。没有围栏的裸字段转储（例如一个直接以 `phase: review` 开头的文件）是格式错误的：编排器的 frontmatter 解析器读不到任何内容，也就看不到这个 worker 的进度。随插件发布的 `skills/orchestration-scheduling-task/templates/worker-status.md` 模板已经是正确的形状——照着它写。
- **`phase` 可以回退，但 `done` 是吸收态。** `phase` **可以**在 `design`、`implementation`、`testing`、`review`、`delivery` 和 `awaiting-confirmation` 之间前进或后退，以反映真实的迭代——例如对一个处于 `awaiting-confirmation` 的 worker 做的评审要求修改时，phase 回退到 `implementation`。**唯一**不可逆的阶段是 `done`：一旦写入，它就是**吸收**终态，永远不会再改成更早的阶段。`done` 表示**用户已确认交付**；worker **只有**在用户明确确认之后（独立模式下在 worker 窗口中，编排模式下经由 L1 转达）才写入 `done`——**绝不**自主写入，也绝不在没有用户确认的情况下从 `awaiting-confirmation` 自行推进。`awaiting-confirmation` 表示 worker 自我声明已完成、正在等待那次确认，它仍然是可逆的。`error` 也是可逆的——错误修复后，恢复到某个工作阶段。
- **`wait-state` 与 `phase` 相互正交。** 独立于 `phase` 设置 `wait-state`。挂起之前设置 `wait-state=waiting-user`/`waiting-subagent`/`waiting-resource`，并附非空的 `waiting-reason`；恢复后立即设置 `wait-state=none`。
- **确认会把 worker 推进到 `done`。** 生成最终报告后，worker 进入 `phase=awaiting-confirmation`（自我声明已完成）并**等待**。**只有**在用户确认时它才推进到 `phase=done`——用户可以直接在 worker 窗口/对话中确认，也可以通过 L1 转达、到达 pane 中的确认消息来确认（用户写下 `confirmed` 令牌时，编排器会派发一个带 `intent=relay-confirmation` 的 `orch-driver-agent`）。worker 绝不自行推进到 `done`。用户确认后，worker 写入 `phase=done`（原子写入，frontmatter 有效）；编排器在下一次轮询时把它同步为 `state: completed`。
- **设计→实现是一道硬性的用户批准闸门。** 进入实现之前，worker **必须**写入 `wait-state=waiting-user`（保持 `phase=design`），并且在明确的用户批准到达之前，**不得**写入 `phase=implementation`，也不得派发实现角色（implementation-agent 或 lane），快速档里主 agent 也不得开始直接改动。合法的批准渠道**只有**：用户接入 worker 的 pane，或者一份匹配的 `answer.md`（worker 先向 `ZYZ_QUESTION_FILE` 发出一个带 question-id 的批准请求；只有回答了该 id 的 `answer.md` 才算——过时或无关的答复不算）。编排器从不转达设计批准。worker 在写入 `phase=implementation` **之前**，把批准事件（或事先明确的跳过指令原文）记入磁盘上 `.zyz-worker/tasks/<task-id>/status.md` 的 `## 设计评审 > 设计批准记录`；一个恢复中或重新装载的 worker，**只有**在磁盘上存在该记录时才进入实现——绝不单凭 `phase` 进入。各档位的这道闸门：标准档、严格档是设计批准，快速档是改法确认（`SKILL.md` `## 自动执行策略`）。
- **异步的用户问答走文件。** 用户没有接入 tmux pane 时，使用 `ZYZ_QUESTION_FILE` 和 `ZYZ_ANSWER_FILE`。写完问题后，在后台轮询回答文件（例如后台 Bash 运行 `until [ -f "$ZYZ_ANSWER_FILE" ]; do sleep 30; done`）：回答写入对话之外，不会有任何东西把你叫醒，这个后台任务就是那个会叫醒你的执行者，它在跑时 watchdog 也不会把任务当成搁置。消费完一份 `answer.md` 后，把它重命名为 `answer.md.consumed.<question-id>`。评审点到达轮次上限、严格档收口检查结论为升级，同样通过这一问答进行。
- **两个状态文件，而不是一个。** 编排模式保留现有的 `.zyz-worker/tasks/<task-id>/status.md` 作为 worker 的详细任务状态（供 execute-task 工作流使用），并在 `ZYZ_WORKER_STATUS_FILE` 所指的路径上新增 `worker-status.md`，作为面向编排器的快照。两个文件互不替代。

## 复用块：带内的运行时配置块优先于启动时的环境变量

当 worker 被派发到一个**复用的**容器上时（编排的 `reuse-dispatch` 路径），它可能会在对话中收到一个带内运行时配置块——一条结构化、人类可读的消息，以 `[zyz-worker reuse-runtime-config]` … `[/zyz-worker reuse-runtime-config]` 围起，携带 `task-id`、`worker-status-file`、`question-file`、`answer-file`、`heartbeat-file`，以及——仅对多仓库的复用容器——一行**可选的** `worktrees:`。之所以会这样，是因为一个被复用、仍在运行的 claude 进程看不到新重新导出的环境变量（Bash 子进程继承的是 claude 启动时的环境，而不是之后在 pane 中执行的 `export`）。约定如下：

- **一旦收到这个块，它的值在整个任务生命周期内都是权威的，并优先于启动时的环境变量。** 用块中的 `task-id` 作为本任务在编排模式下的任务身份，**取代继承来的 `ZYZ_TASK_ID`**；用块中的 `worker-status-file` / `question-file` / `answer-file` / `heartbeat-file` 取代 `ZYZ_WORKER_STATUS_FILE` / `ZYZ_QUESTION_FILE` / `ZYZ_ANSWER_FILE` / `ZYZ_HEARTBEAT_FILE`。
- **这种覆盖适用于所有由 task-id 派生的路径**，而不只是快照/问答/心跳文件：详细任务状态目录 `.zyz-worker/tasks/<task-id>/`（即上面"两个状态文件"中的那个），以及任何嵌入了 task-id 的提交信息 / 分支引用，都使用块中的 `task-id`。忽略这一点的 worker 会把详细状态写进**旧**任务的目录，并使用错误的 task-id——这正是本约定要防止的失败。
- **块中的 `worktrees:` 行是权威的 worktree 集合（优先于 `ZYZ_WORKTREES`）。** 当块中带有 `worktrees: <wt1>:<wt2>:…`（冒号分隔，主 worktree 在前）时，把它视为本任务权威的 worktree 集合，覆盖任何启动时的 `ZYZ_WORKTREES`——worker 管理所有列出的 worktree（见下面的多 worktree 规则）。当块中**省略**了 `worktrees:` 行时，回退到启动时的环境变量：设置了 `ZYZ_WORKTREES` 就用它，否则就用单一的 cwd（当前的单 worktree 行为）。worktree 路径绝不包含冒号，所以冒号是无歧义的分隔符。
- **复用的 worker 还要在每次写盘时（每次写 `worker-status.md` 时）`touch` 块中的 `heartbeat-file`**，作为编排器同会话新窗口心跳守护进程之外的第二个存活信号。（主要的心跳来自守护进程；这次 touch 是备份。）
- 如果没有收到这样的块，行为与以前完全相同——启动时的 `ZYZ_*` 环境变量是权威的（标准派生）。

## 多 worktree 感知与按仓库交付（多仓库任务）

一个 worker（一个 tmux 会话 + 一个 claude 进程）可以管理 n 个 git worktree，每个仓库一个：

- **worktree 集合的发现。** 如果设置了 `ZYZ_WORKTREES`（冒号分隔，主 worktree 在前）——或者 reuse-runtime-config 块中带有 `worktrees:` 行（按上面的块约定，它优先于 `ZYZ_WORKTREES`）——worker 就管理**所有**列出的 worktree。两者都不存在时，worker 管理单一的 cwd worktree（单仓库行为不变）。第一项是主 worktree（即 pane 的 cwd）。
- **写权限边界。** worker 对自己的每一个 worktree 都有**完全**的写权限。它**不得**写入任何其他 worker 的 worktree。隔离存在于 worker 之间，而不是 worker 与它自己的仓库之间：在一个 worker 内，它的所有 worktree 都可写；跨 worker 时，各自的 worktree 集合互不相交（由 spawn 脚本强制保证）。worker 内部按 `SKILL.md` `## 并行模型` 派生的 lane worktree 属于该 worker 自己。
- **按仓库提交、推送和交付。** 每个仓库在自己的 worktree 中、在自己的分支上；按仓库提交和推送（一个 lane / SubTask 在它碰过的每个仓库中各提交一次；最终交付提交也按仓库分别创建）。合并到基线分支同样按仓库进行（每个仓库的分支合并进该仓库的基线分支——编排模式下由编排器驱动）。交付报告按仓库拆分：最终报告的 `## 变更` 小节按仓库列出（仓库 / 分支 / 提交 / 推送结果），任务状态的 `## SubTasks > Committed` 字段对多仓库 SubTask 分多行记录 `<repo>:<sha>`。

## 阶段映射

每个 phase 值必须在何时写入 `worker-status.md`（位置指 `SKILL.md` `## 工作流`）：

| execute-task 工作流位置 | 要写入的 phase | 写盘时机 |
|---|---|---|
| §1 启动任务 | `design` | 初始化任务状态文件时 |
| §2 设计（全部，包括快速档的改法确认和评审循环） | `design` | 进入时写一次；每次返回主 agent 时 |
| §3.A 第 1 步 / §3.B 第 1 步——主 agent 开始直接改动，或派发 lane / implementation-agent | `implementation`（仅在用户批准后——绝不自主；见设计→实现硬性闸门规则） | 开始改动或派发之前 |
| 单独派发的测试运行或 test-agent（§3.A 第 1 步的自验证、§3.B 第 2 步）；lane 在内部自验证时保持 `implementation` | `testing` | 派发之前 / 运行之前 |
| §3.A 第 2 步 / §3.B 第 3 步——工作区冻结，然后派发 review-agent | `review` | 派发之前 |
| 评审 → 修复循环（§3.A 第 2 步、§3.B 第 3–4 步） | `review`（默认保持；如果确实回到了大量实现工作，**可以**回退到 `implementation`——允许回退） | 不写盘 |
| §3.C 汇总测试 | `testing` | 进入时 |
| §3.C 汇总评审 | `review` | 进入时 |
| §4 交付 | `delivery` | 进入时 |
| 最终报告已发出（worker 自己能到达的最远状态） | `awaiting-confirmation` | 最后一次写入 |
| 用户确认交付（在 worker 窗口中，或经由 L1 转达） | `done` | 仅在用户确认时——绝不自主 |
| 无法恢复的错误 | `error`（设置 `wait-state=none`） | 立即 |

worker **只有**在用户明确确认之后才写入 `phase=done`（绝不自主写入）；`done` 是唯一不可逆的吸收终态。在编排模式下，编排器把 worker 的 `phase=done` 同步为主条目的 `state: completed`；在独立模式下，`phase=done` 本身就是终态。合并到基线分支仍然是一个单独的、需要独立令牌的操作，可能发生也可能不发生（与 done 解耦）——见 `skills/orchestration-scheduling-task/SKILL.md` 的 `## 状态机`。

如果没有设置 `ZYZ_WORKER_STATUS_FILE`，就忽略本文件全部内容——本 skill 在独立模式下运行。

## 维护说明

本文件与 `orchestration-scheduling-task` skill 的约定相耦合。如果 execute-task 工作流新增了一个阶段，要同步扩展这里、`SKILL.md` `## 编排模式` 的要点和 `skills/orchestration-scheduling-task/templates/worker-status.md` 中的 `phase` 枚举，并同步扩展这里的阶段映射表。
