---
name: execute-task
description: 当用户希望协助执行一个已确认的单个开发任务时使用：设计先行的工作流，由面向用户的主 agent 协调 subagent 完成实现、测试、评审和交付。
---

# 执行任务

## 加载与文件

当前对话 agent 就是主 agent，先加载 `prompts/main-agent.md`：本文件写规则，它写每一步的操作。角色提示词在 `../../subagents/`，模板在 `templates/`；专题细则在 `references/`，正文点到哪一份时再加载。`<plugin-root>` 是本目录往上两级（或 `ZYZ_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` / `CODEX_PLUGIN_ROOT` 的值）。

## 档位

| | 快速 `fast` | 标准 `standard` | 严格 `strict` |
|---|---|---|---|
| 适用 | 目标明确、可回滚、影响面小 | 大多数功能 | 鉴权/安全、数据迁移或删除、资金、不可逆、对外契约 |
| 评审轮数（每个评审点，含首轮） | 设计不评审；实现 2；多 lane 时汇总 1 | 设计、实现、汇总各 3 | 不设上限 |

- **怎么定**：`$ARGUMENTS` 以 `--fast` / `--standard` / `--strict` 开头，或用户说"快速档 / 标准档 / 严格档"，取该档；都没有时主 agent 在第一条回复里提议一档并附一句理由，用户随时可改。档位是 `status.md` 的 `- Tier:` 一行；没有这一行的旧任务按 `strict` 执行。
- **升降档**：涉及严格档适用的内容时主 agent 提议升档（整个任务或单个评审点），用户确认后写入；降档只由用户决定。
- **先止血，后功能**：快速档先交付止血，恢复功能另开任务、重新选档。

## 范围

第一次把一件事做出来时，只管正常运行。对设计、实现、测试和评审里的每一种情况，问两个问题：

1. **所有人都按预期使用和操作时，它会发生吗？** 会发生的在范围内：主流程，以及正常运行本来就会遇到的条件（并发、重试、超时、重启、依赖失败、空数据和边界值）。要有人做错（配置写错、以后的维护者改错代码）、有人恶意、或几个互不相关的罕见故障同时出现才会发生的，不在范围内：不去找，也不为它设计、写测试或提发现。设计的范围边界写明有对手的地方（公网入口、鉴权）除外，那里恶意输入属于正常运行。
2. **它出错时，会不会悄悄造成难以挽回的后果**（线上数据算错、数据丢失、资金）？会的事先设计。出错看得见、不影响生产、当场能查的，设计里写一句"发生时谁、看什么数据来判断"就算完整，不预先枚举原因和分类。

顺手看到的范围外情形只记一行，不定级、不讨论：角色写在自己的报告里，主 agent 收进 `residual-risks.md` 的 `## 后续对抗任务`，留给之后专门的对抗任务。

## 核心规则

- 用户陈述的需求是最终、完整的目标：不收窄、不推迟、不用占位代替，做不到时交给用户决定。不做 `## 范围` 之外的情形不算收窄。
- 已批准的设计（快速档是 `change-note.md`）是实现、测试和评审的依据：每个元素都实现，不替换机制，不加没要求的模块。
- 实现都由 review-agent 评审，主 agent 不亲自评审；除快速档单 lane 的小改动外，主 agent 不写实现和测试代码。
- 长时间运行的任务必须把进度、决策、阻塞项和下一步持久化到任务状态文件中；对话上下文只用于执行。见 [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md)。
- 每个任务一份总状态文件 `<task-dir>/status.md`（文件名固定，只放当前状态）；用户决策在 `decisions.md`，实现备注在 `impl-notes.md`，lane 报告在 `lanes/`，评审报告在 `reviews/`，追加型日志在 `log/`。状态转换和写入是同一个动作：阶段变化、标志翻转写进 `status.md` 之后才继续。
- 设计文档、变更说明和最终报告用用户的对话语言。
- 受支持的运行时操作恰好是 `adopt-legacy`、`finalize`、`gc-step`、`probe-ack`、`probe-cancel`、`probe-create`、`probe-status`、`reconcile-start` 和 `reconcile-stop`；`gc-step` 不由角色运行。

## 用户设计主导权

| 类 | 范围 | 处理 |
|---|---|---|
| A 设计决定 | 架构、模块划分、关键算法、对外接口契约、持久化的数据结构、用户可见的行为、范围取舍 | 经用户批准 |
| B 可逆的实现细节 | 内部命名、配置默认值、内部函数拆分、日志措辞、依赖小版本等 | 按推荐执行，记入 `decisions.md`，批准时和最终报告里列给用户，用户可否决 |

拿不准按 A。

- 主 agent 整理用户的设计，不发起设计：不引入用户没描述过的模块、数据流、关键算法或架构；发现错误、矛盾、歧义时连同选项交给用户。
- 任何角色要改 A 类内容时，由主 agent 把问题、位置和选项交给用户并等待；先实现后报告不被接受。对已批准设计的实质改动重新打开批准闸门（§2）。
- 其余时候自主推进。要问用户的只有：A 类决定、设计实现不了、数据丢失或不可逆操作（含删除不是本任务创建的数据、改动共享环境）、批准闸门、评审点停下。装依赖、构建、启停本任务的容器不问。

## 并行模型

并行的单位是端到端的 lane：一个功能、PR 或模块，有文件白名单、自己的 worktree 和分支（或共享 worktree 里的插入区域）和测试资源租约。lane 由 implementation-agent 写代码和测试并自验证，只做到本地提交；push、开 PR、合并归主 agent。

- **两种模板**：(1) 契约骨架 + 按文件扇出——先落能编译的接口骨架，再派 N 个 lane 共用 worktree、各改各的文件；(2) 一个 PR 一个 lane 一个 worktree——主 agent 用 `git-worktree` skill 创建，跨仓库或功能独立时用。
- **调度**：没有未满足依赖的事项一起派发；上游接口冻结（骨架能编译、接口不再变）下游即可开始。lane 一交付就派对它的评审，其它 lane 继续；修复回到原 lane。并行 lane ≥ 4 时设一个集成 lane 负责合并和跟 CI。
- **资源租约**：≥ 2 个会跑测试的并发 lane（含 review-agent）之前，给每个分配独占的端口组和测试数据库，记入 `status.md` 的 `## 并行资源租约`。

## 评审收口

等级、关闭条件、每轮修订怎么做和命令在 `references/review-closure.md`。

- **评审点**：设计和实现各把主路径设为一个评审点，每个附属子功能各一个，汇总评审一个，各自计轮次。
- **轮次**：第 1 轮全量，之后增量。每一轮都新派发 review-agent，不用 SendMessage 续用上一轮的评审者；评审期间被评审的文件不改。
- **由脚本记录和限制**：轮次经 `<plugin-root>/hooks/scripts/review-round.sh` 推进，`## 评审收口` 段的行不手写。上限见档位表；标准档第 2 轮不收敛时提前停，严格档每满 3 轮做一次收口检查。
- **停下时**：脚本拒绝开新一轮时，不悄悄关闭、也不自动继续，带诊断交给用户三选一：再开一轮、接受为遗留风险、拆成加固任务。

## 跨 harness 交叉评审

默认只在严格档跑（含单独升到严格档的评审点），以 `review-round.sh start` 输出的 `cross-harness=yes` 为准：同一批在本机每个**其它** agent harness 里后台起一个只读评审会话（`references/cross-harness.md`）。其它档位用户明确要求时直接运行 `cross-review.sh run`。没装、失败或超时就只靠 review-agent 继续。它的发现只作参考：逐条对照真实产物核实，接受或附理由拒绝。

## 工作流

### 1. 启动任务

1. 建任务目录（首选 `.zyz-worker/tasks/<task-id>/`）和 `status.md`。
2. 运行 `task-pointer.sh arm <任务目录>`，写入本会话的指针 `.zyz-worker/sessions/<session-id>`。
3. 写入档位，把用户的完整目标记入 `## 总目标`。

### 2. 设计

- **快速档**：写 `change-note.md`，用户确认改法即设计批准。
- **标准档、严格档**：和用户一起写设计文档（`references/design-doc-discipline.md`），其中 `## 场景` 是评审和测试的清单。按评审点做设计评审，评审点关闭后请用户批准。

**设计批准闸门是硬性停止点**：等用户明确许可进入实现；对其它问题的答复不算，沉默时一直等。唯一例外是事先明确跳过这一次审批的指令（"设计完直接实现""跳过审批"），泛泛的信任或目标陈述不算。批准或跳过指令的原文记入 `status.md` 的 `## 设计评审 > 设计批准记录` 之后才进入实现。

### 3. 实现与测试

完成条件：构建和测试通过；新测试在改动前的代码上失败（负对照）；`## 场景`（快速档是"怎么验证"）的每一条有对应的测试；标准档、严格档覆盖测试计划的单元、回归、e2e。

#### 3.A 快速档

1. 主 agent 直接改，或派 lane。
2. 派独立评审；多 lane 时加汇总评审。
3. 本地提交后进入 §4；合并、打 tag、发布前等用户。

#### 3.B 标准档与严格档

1. 按设计的 `## 拆分` 把 lane 记入 `## SubTasks`，按依赖派发。
2. lane 实现并写测试；严格档设计里 `## 关键机制` 列出的机制，测试由 test-agent 写，实现者不改这些测试。
3. lane 交付后按评审点派实现评审。
4. lane 的标志翻转时写入 `status.md`；`Tested: true` 要求测试通过且负对照有记录，`Reviewed: true` 要求评审点已关闭。

#### 3.C 汇总测试与汇总评审

所有 lane 完成后跑汇总测试，在 `## 最终汇总测试` 给测试计划的每个类别登记 `ran`（附结果）或 `skipped`（附理由，跳过前先问用户）；再做汇总评审（评审点 `aggregate`）。

### 4. 交付

1. 对照 `## 总目标`：没有一项被收窄、推迟或用占位代替。
2. 每个评审点都已关闭；被接受的 `blocking` 都已落地；`decisions.md` 里没有仍在等回答的问题；`## 最终汇总测试` 登记了每一个必需的类别（快速档：负对照和构建、测试结果已记录）。
3. 最终提交并推送（失败不阻断），写最终报告，进入 `awaiting-confirmation` 等用户确认。用户确认后才写 `done`，它不可逆。

## 恢复进行中的任务

接手时先核对 `status.md` 再继续。卡住的角色续做而不重做，以相同范围重新派发：可以分成几步，不缩小总交付。见 `references/recovery.md`。

## 版本控制

提交和推送自主进行，失败记下后继续。不 force-push、`reset --hard` 或改写已发布的历史；工作树与其它 agent 共享，`git stash`、`git checkout <file>`、`git restore <file>` 会毁掉别人未提交的改动，也不用。合并到基线分支只在用户明确指示时做。见 `references/version-control.md`。

## Watchdog 强制层

主 agent 对插件 watchdog 的义务（`references/watchdog.md`）：

- 会话恢复后重新 arm 指针，没有指针就没有 watchdog。
- `- Current Phase:` 保持准确。
- `[zyz-worker watchdog]` 通知是要立即执行的指令，照通知写的做。
- 活跃阶段结束一轮之前，有一个核实过的执行者（在跑的 subagent、后台任务或排定的唤醒），否则派发或声明。
- 声明经 `<plugin-root>/hooks/scripts/expect.sh` 写，不手写，不手改 `runtime/`。

## 编排模式

设置了 `ZYZ_WORKER_STATUS_FILE` 时运行在编排模式下，写第一份状态之前加载 `references/orchestration-mode.md` 并按它执行：

- 挂起前、派发前、收到结果后、进入新阶段时原子写 `worker-status.md`（YAML frontmatter）：`phase`（`design | implementation | testing | review | delivery | awaiting-confirmation | done | error`）、`phase-since`、`wait-state`（`none | waiting-user | waiting-subagent | waiting-resource`）、`waiting-reason`、`expected-resume-by`、`last-flush`。
- `phase` 可以回退，但 `done` 是吸收态，只在用户确认交付后写入。
