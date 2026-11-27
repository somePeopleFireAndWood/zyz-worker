---
name: execute-task
description: 当用户希望协助执行一个已确认的单个开发任务时使用：设计先行的工作流，由面向用户的主 agent 协调、仅靠提示词驱动的 subagent 分工，配合任务状态跟踪、实现、测试、评审和最终交付。
---

# 执行任务

本 skill 把一个已确认的单个开发任务从设计做到交付（多任务编排见 `orchestration-scheduling-task`），按风险分三档，设计由用户主导。不能启动 subagent 时，把角色提示词当作角色说明，在对话里维持职责边界。

## 加载与文件

当前对话 agent 就是主 agent，先加载 `prompts/main-agent.md`（控制器，不是 subagent），加载不了时按本文件执行。角色提示词在 `../../subagents/`，需要时加载。`<plugin-root>` 是本 skill 目录往上两级的目录（设置了 `ZYZ_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` / `CODEX_PLUGIN_ROOT` 时取其值）。

模板（`templates/`）：`change-note.md`（快速档）、`design-doc.md`（标准档、严格档）、`task-status.md`、`decisions.md`、`impl-notes.md`、`review-report.md`、`final-report.md`、`residual-risks.md`、`cross-review-prompt.md`（由脚本渲染）。

专题细则在 `references/`，按需加载：

| 文件 | 何时加载 |
|---|---|
| `review-closure.md` | 第一次派发 review-agent 之前；分级、到上限或提前停、收口检查、写遗留风险清单时 |
| `cross-harness.md` | 第一次运行 `cross-review.sh` 之前 |
| `design-doc-discipline.md` | 标准档、严格档写设计文档或应用设计评审发现之前 |
| `watchdog.md` | 收到告警、要写本文没列出的声明、或怀疑 watchdog 未生效时 |
| `recovery.md` | 接手进行中的任务、角色卡住或超时、未提交工作丢失时 |
| `version-control.md` | 第一次提交、搁置或回退改动、多 worktree 交付之前 |
| `pr-review.md` | 收到真实 PR 上的评审意见时 |
| `orchestration-mode.md` | 设置了 `ZYZ_WORKER_STATUS_FILE` 时，写第一份状态之前 |

## 档位

| | 快速 `fast` | 标准 `standard` | 严格 `strict` |
|---|---|---|---|
| 适用 | 目标明确、可回滚、影响面小：止血、小功能、配置、文案 | 大多数功能 | 鉴权/安全、数据迁移或删除、资金、不可逆、对外契约 |
| 设计 | `change-note.md`，用户确认改法 | 设计文档 + 快速审阅 | 同标准档，可拆多份 |
| 设计评审 | 无 | 每个评审点最多 3 轮，第 2 轮不收敛提前停 | 不设上限，有收口检查 |
| 实现组织 | 主 agent 直接改，或 1 个 lane；独立改动多时多 lane | lane 模型 | lane 模型；关键机制的实现和测试分给不同角色 |
| 测试 | 负对照（新测试在旧代码上失败）+ 项目惯例的构建和测试 | 加测试计划的类别；变异只用于"关键"机制 | 全套；声称覆盖的机制都要有被杀死的变异 |
| 实现评审 | 1 轮，最多再 1 轮复核修复 | 每个评审点最多 3 轮，第 2 轮起增量，不收敛提前停 | 不设上限，第 2 轮起增量，有收口检查 |
| 跨 harness | 与那 1 轮实现评审并发一次；多 lane 时汇总第 1 轮也跑 | 设计各轮、实现第 1 轮、汇总第 1 轮 | 同标准档 |
| 汇总评审 | 单 lane 无；多 lane 做一次轻量契约一致性检查 | 有 | 有 |
| 用户关卡 | 改法确认；合并、打 tag、发布前 | 设计批准；A 类决定 | 同标准档 |

"关键"机制由主 agent 列在设计文档的 `## 关键机制` 里（安全守卫、权限、数据完整性、用户点名的机制），随设计一起批准；快速档没有这份清单。

- **怎么定。** `$ARGUMENTS` 以 `--fast` / `--standard` / `--strict` 开头时取该档；"快速档 / 标准档 / 严格档"等自然语言同义。没给时，主 agent 在第一条回复里提议档位并附一句理由，用户随时可改。档位是 `status.md` 中 `- Current Phase:` 下一行的 `- Tier: fast|standard|strict`，用 `<plugin-root>/hooks/scripts/review-round.sh tier <档位> --reason …` 写入。没有 `Tier:` 行的旧任务按 `strict` 的旧行为执行。
- **升降档。** 涉及严格档适用的内容时，主 agent 提议升档，用户确认即可：整个任务用 `tier`，单个评审点用 `open <point> … --tier <t>`（只能比任务档位更严）。降档只由用户决定（`--by user`）。
- **先止血，后功能。** 快速档遇到"止血 + 恢复功能"时先交付止血；恢复功能另开任务、重新选档。

## 核心规则

- 设计由用户主导：agent 帮助澄清、组织、成文和执行，不自己发起设计。A 类设计决定经用户批准；这一条优先于下文"默认不询问用户"的姿态。
- 用户陈述的需求是最终、完整的目标。
- 合同先行：已批准的设计（快速档是 `change-note.md`）连同验收标准、测试计划和声明域（`## 范围边界`）构成合同，是实现、测试和评审的唯一依据；合同之外的问题进遗留风险清单。
- 标准档、严格档的测试计划底线是单元、回归、e2e，各有针对本任务场景的用例；省略一类要写明理由并经用户同意。
- 独立评审：作者不当自己的裁判，每个档位的实现都由 review-agent 评审，主 agent 不亲自评审。快速档单 lane 的小改动主 agent 可以直接改并自验证；其余情况不写实现和测试代码（边界细节见 `prompts/main-agent.md`）。
- 状态持久化：每个任务恰好一份总状态文件 `<task-dir>/status.md`，只放当前状态；决策写 `decisions.md`，实现备注写 `impl-notes.md`，lane 报告写 `lanes/<id>.md`，追加型日志写 `log/`。阶段变化、标志翻转在继续之前写进 `status.md`。
- 长时间运行的任务必须把进度、决策、阻塞项和下一步持久化到任务状态文件中；对话上下文只用于执行。见 [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md)。
- 不阻断的歧义记录假设后继续；可能造成数据丢失、不可逆变更或严重偏离目标时停下来问。
- 设计文档、变更说明和最终报告用用户的对话语言。已安装的 skill、插件能提升质量就用，缺少时不阻断、不要求安装。

## 用户设计主导权

用户的设计在两个阶段都是权威。决定分两类：

| 类 | 范围 | 处理 |
|---|---|---|
| A 设计决定 | 架构、模块划分、关键算法、对外接口契约、持久化的数据结构、用户可见的行为 | 经用户批准 |
| B 可逆的实现细节 | 内部命名、配置默认值、内部函数拆分、日志措辞、依赖小版本等 | 按推荐执行，记入 `decisions.md` 的「按推荐执行的决定」，批准时和最终报告里列给用户，用户可否决 |

拿不准时按 A 处理。环境准备、已授权的合并等运维许可不再询问。

- **提问**：一次停下只发一条消息，格式见 `prompts/main-agent.md` `## 提问与自动执行`。
- **设计阶段主 agent 组织而不设计**：补齐机械细节，不引入用户没描述过的模块、数据流、关键算法或架构；在用户描述的内容里找错误、矛盾、歧义、可能不成立的隐含假设，连同选项交给用户。
- **设计变更**：要改 A 类内容的角色说明问题、位置（`file:line` 或章节）和选项；主 agent 交给用户并等待，同意后更新设计再派发，拒绝则按原设计实现。先实现后报告不被接受；实质性修改重新打开设计批准闸门。
- **实现中发现偏离**：按 `prompts/main-agent.md` 的偏离决策表处理。

## 自动执行策略

默认不询问用户，但服从 `## 用户设计主导权`：

- 设计评审的发现由主 agent 裁决；实现评审的发现由产物的作者裁决（lane agent，或严格档关键机制的 implementation-agent / test-agent），主 agent 核对证据后记录；跨 harness 发现由同一裁决者核实后裁决。
- 测试失败先归因再修：改动面 → 工具 → 他人进行中的编辑或环境 → 真回归。
- **环境准备默认无需批准**：构建环境、装依赖、拉取或构建镜像、启停本任务的容器都直接做，只权衡本地还是容器并记一行理由。删除或覆盖非本任务创建的数据或改动共享环境，按不可逆变更升级。被权限模式拦下的命令换做法。
- 外部 PR 评审意见按 `references/pr-review.md` 逐条核实后处理。

升级给用户：A 类决定或设计变更；设计元素实现不了；数据丢失、不可逆或偏离目标；设计批准闸门（§2）；评审点到上限或提前停；严格档收口检查结论是升级；同一发现在接受与拒绝间反复 3 轮。

## 评审收口

细则在 `references/review-closure.md`。

- **评审点**：主路径、每个附属子功能、汇总评审各一个，各自计轮次。
- **首轮全量，之后增量**：第 2 轮起只核实被接受的 blocking 已修好、评审修复 diff、复核被拒绝的 blocking（认可或重新提出）；结构性修复后用 `start --full` 走全量。
- **blocking 只有三类**：可达的产品缺陷（附失败的测试、具体输入或调用路径 `file:line`）；设计缺失或矛盾（指明章节）；违反合同（含违背已批准设计）。测试强度是 `non-blocking:normal`；证据或流程缺口是补证请求，不开新一轮；快速审阅漂移不进评审；极端构造是 `non-blocking:contrived`，进遗留风险清单。可达性拿不准时按 blocking 并写明疑点。
- **关闭**：reviewAgent 本轮零条 blocking（被拒绝的也算，用 `result --rejected` 记），跨 harness 发现都有处置且无一被接受为 blocking，没有等待用户的发现，覆盖维度都已登记；此时 `close <point> --outcome passed`（要求 `blocking=0` 且 `rejected=0`）。
- **轮次上限**（同一评审点总轮数，含首轮）：`fast` design 0 / impl 2 / aggregate 1；`standard` 各 3；`strict` 不设。
- **到上限或提前停**（快速档、标准档）：标准档评审点第 2 轮的 blocking 数（接受的加被拒绝的）不为零、且不少于第 1 轮时，不开第 3 轮。停下时不悄悄关闭、也不自动继续：一条消息带诊断（细则 §7）交给用户，四选一：再开一轮（`grant`，一次只管一轮）、带着进实现（逐条写进 `impl-notes.md`）、接受为遗留风险、拆成加固任务；后三项 `close --outcome carried|residual|split --by user`。
- **每轮修订**：等级只看问题本身、不看解法；设计评审的非阻断发现不进设计正文（细节进 `impl-notes.md`）；非阻断发现要加新机制才能解决时先重新核对等级，改判只凭可达性证据；blocking 的修复优先做减法；要用户定的问题裁决完马上问，依赖回答的部分不动。
- **严格档**不设上限：极端构造进遗留清单另开 PR；从第 3 轮起每满 3 轮做一次收口检查（`check`）；结论 `escalate` 时交用户，批准继续后 `grant`；同样带诊断。
- **由脚本强制**：评审点用 `<plugin-root>/hooks/scripts/review-round.sh` 的 `open` / `start` / `result` / `close` 推进，不手写 `## 评审收口`；上一轮先 `result` 再开新一轮。每轮重新派发 review-agent（不用 SendMessage 续用），prompt 里写 `start` 输出对应的 `review-point=<id> round=<n> mode=<full|incremental>`，另起一行 `Tier: <评审点生效档位>`，由 `review-gate.sh` 核对；`start` exit 3 时照输出做。

## 跨 harness 交叉评审

每个评审点除了 review-agent，还在本机每一个**其他** agent harness 里各起一个只读评审会话（宿主是 Claude Code 时起 Codex，反之起 Claude Code），报告只作参考。用法见 `references/cross-harness.md`。

- **何时跑**：`review-round.sh start` 输出 `cross-harness=yes` 时，与 review-agent 同批次后台运行 `<plugin-root>/scripts/cross-review.sh run … --point <id> --round <n> --mode <start 输出的 mode>`。
- **可选，不阻断**：没装、关闭、失败或超时时记下结果，只靠 review-agent 继续。
- **独立核实，可以拒绝**：裁决者逐条对照真实产物核实，不凭摘要、不批量接受；每条以接受或附理由拒绝结束，分级和准入与 review-agent 相同。

## 并行模型

并行的单位是端到端的 lane，上限只看真实依赖和隔离能力。

**lane** 是一个功能、PR 或模块，有文件白名单和标识符前缀、自己的 worktree 和分支（或共享 worktree 里划定的插入区域）、自己的测试资源租约。lane 内部完成实现、测试和自验证（构建、测试、负对照），只做到本地提交。快速档和标准档由一个 lane agent（implementation-agent 的 lane 模式）同时写代码和测试，独立评审兼查断言形态；严格档的关键机制由 implementation-agent 和 test-agent 分开负责。

**两种模板**：(1) 契约骨架 + 按文件扇出——先写出能编译的接口骨架，再派出 N 个 lane，共用 worktree、各碰各的文件；(2) 一个 PR 一个 lane 一个 worktree——主 agent 用 `git-worktree` skill 创建，适合跨仓库或独立功能，lane 多时优先。subagent 默认在主 agent 的工作目录里派发，不用 `isolation: worktree`。

**调度**：

- 每个派发点找出所有没有未满足依赖的事项，一条消息一起发出。依赖从实施计划和改动文件推导，不从编号推导；阻塞项完成时重新扫描，一次放行所有以它为最后阻塞的事项。
- 解锁条件是接口已冻结：上游骨架能编译、接口不再变，下游即可开始，依赖正确性由汇总评审和集成测试兜底。
- 共享同一文件不是串行理由：装配点声明为热点、给每个 lane 分插入区域；重写同一段逻辑时才串行。
- 评审与实现流水线并行：lane 一交付就派发对它的评审，修复意见用 SendMessage 回到原 lane。设计调研、拆分的设计文档、汇总评审各维度也并行。并行 lane ≥ 4 时设一个集成 lane 负责合 main、跟进 CI、转发评审 bot 意见。
- **资源租约**：≥ 2 个会跑测试的并发 lane（含 review-agent）之前，给每个 lane 分配独占的完整端口组（HTTP / gRPC / metrics / pprof）和测试数据库，记入 `## 并行资源租约`；不共享开发数据库、不全表清理共享库；启动后探测身份端点确认是自己的实例；共享构建产物每批只由一个 lane 生成。

**决策与报告**：每个 lane 的派发都引用 `decisions.md` 和 `impl-notes.md`；lane 报告写到 `lanes/<id>.md`，消息里只传路径。

## 工作流

### 1. 启动任务

1. 创建任务目录（首选 `.zyz-worker/tasks/<task-id>/`）和 `status.md`（文件名不能改，watchdog 按它读）。
2. 在会话 cwd 下运行 `<plugin-root>/hooks/scripts/task-pointer.sh arm <任务目录>`，写入本会话的指针 `.zyz-worker/sessions/<session-id>`（拿不到会话 id 时脚本退回共享的 `.zyz-worker/current-task`，不手工写）。只有主 agent 写指针。
3. 定档位写入 `Tier:`，把用户完整目标记入 `## 总目标`。

### 2. 设计

**快速档**：基于模板写 `change-note.md`（现状、改法、不在范围、怎么验证，含负对照），用一条消息发给用户确认；确认即设计批准，记入 `## 设计评审 > 设计批准记录`，原文要点写进 `change-note.md`。

**标准档、严格档**：

1. 加载 `references/design-doc-discipline.md`，和用户一起写设计文档（含 `## 目标`、`## 范围边界`、验收标准、`## 测试计划`、`## 关键机制`），主路径先锁定。拆成多份时加索引，路径记入 `## 元数据 > 设计文档`。
2. 缺口和四类问题集中在一条消息里问用户。
3. 按评审点做设计评审（`review-round.sh open <point> --stage design --kind main|aux` → `start` → 派发 → `result`），同批跨 harness。主 agent 裁决；要用户定的问题当轮就问。
4. 评审点关闭后，主 agent 根据正文重新生成 `## 快速审阅`（用户没亲口说过的范围边界条款列进 `### 需要你关注的细节`），引导用户去看 `## 快速审阅`、B 类决定清单和仍未回答的 A 类问题。

**设计批准闸门是硬性停止点**：等待用户明确的进入实现的许可；对其他升级的答复不算，沉默时一直等。唯一例外是事先明确跳过这一次审批的指令（"设计完直接实现""跳过审批"）；泛泛的信任或目标陈述不算。批准或跳过指令原文记入 `status.md` 的 `## 设计评审 > 设计批准记录` 之后才进入实现。

### 3. 实现与测试

#### 3.0.0 严格按设计文档实现

已批准的设计是规格：每个元素都实现，不遗漏；不替换机制、不换关键算法、不加未要求的模块，不违背。派发只给最终态设计、`decisions.md` 和 `impl-notes.md`，实现评审也拿到。review-agent 双向逐元素核对符合性。

#### 3.A 快速档

1. 主 agent 直接改，或派 1 个 lane（独立改动多时多 lane 并行），自验证：负对照、按项目惯例跑构建和测试；不设变异门。
2. 1 轮独立评审（快速档评审清单）同批跨 harness；修完最多再 1 轮复核，仍有 blocking 时交用户。多 lane 时加 1 轮契约一致性检查。
3. 本地提交后进入 §4；合并、打 tag、发布前等用户。

#### 3.B 标准档与严格档

1. 按 `## 并行模型` 把实施计划拆成 lane，记入 `## SubTasks`（lane 即 SubTask，字段名不变），写骨架、分租约后按依赖图派发。
2. lane 实现、写测试、自验证。变异：标准档由 lane 自写自执行；严格档的关键机制由 test-agent 写清单、implementation-agent 执行，非关键机制由作者 lane 自写自执行。逐条 KILLED/SURVIVED，恢复后逐字节一致。
3. 测试通过后记下工作区冻结声明（冻结文件集）再派发评审；评审中途文件改变则作废重派。
4. 标志翻转时同步写入 `status.md`：`Coded: true` 实现完成；`Tested: true` 测试通过且负对照和本档要求的变异有记录；`Reviewed: true` 评审点有 `Review-Close`、非阻断发现都已落地或已记录、该次评审登记了每个覆盖维度、跨 harness 发现都有处置；`Committed:` lane 完成后自主提交（共享装配文件分开提交无法编译时，提交最小可编译单元并记下偏离）。
5. 过了设计批准闸门后自主推进，lane 之间不停下问。

#### 3.C 汇总测试与汇总评审

1. 汇总测试覆盖 `## 测试计划` 的每个类别（用户点名的各占一行），在 `## 最终汇总测试` 逐类登记 `ran`（附结果）或 `skipped`（附理由）和一行结构覆盖上限；跳过有成本的测试前，可行时先问用户。
2. 汇总评审全量检查跨 lane 的一致性、契约和回归；覆盖维度（设计符合性、正确性、测试质量、回归风险，加 `## 风险` 的每项）各登记 `covered` 或 `not-covered: <reason>`，未登记不算关闭。
3. 循环到测试通过、评审点关闭或到上限交用户。

### 4. 交付

1. 对照 `## 总目标` 核实没有被悄悄收窄、推迟或用占位替代。
2. 标准档、严格档：`## 最终汇总测试` 登记了每一个必需的类别，`## 最终汇总评审` 登记了每一个覆盖维度；快速档：负对照和构建、测试结果已记录。
3. 每个已登记的评审点都有 `Review-Close`；`## 发现台账` 没有未处置或已接受未落地的发现；每条移入加固 SubTask 的阻断发现都已落地；带进实现的 blocking（`impl-notes.md`）都已落地；每个反复出现的类都已由类级修复或清单条目回应；遗留风险条目字段齐全；分阶段交付的每一批都已到达。
4. 逐项回答 `## 交付前检查清单` 并附证据。
5. 最终提交，配置了 remote 时推送（失败不阻断）；基于模板写最终报告（含 B 类决定），进入 `awaiting-confirmation` 等待。用户确认后才写 `done`，它是唯一不可逆的终态。最后询问用户是否删除任务状态文件。

## 总目标忠实度

- 在整体任务层面不收窄、简化、推迟目标的任何部分，也不用"实验性占位"代替；"先交付简化版"只能描述中间状态。目标写进设计的 `## 目标`（或 `change-note.md`）和 `## 总目标`，交付前对照。
- 确实无法完全实现时升级给用户，而不是交付缩水版。
- 把一条 `non-blocking:contrived` 发现记入遗留风险清单而不修复，并不算收窄目标——该构造位于用户批准的域之外。而让一项域内需求没有得到满足，无论给它贴了什么等级标签，都是在收窄目标；移动声明域的边界由用户决定。

## 增量输出

各角色可以分多轮、多次编辑完成大产物；这是交付技巧，不是推迟范围的许可。

受支持的运行时操作恰好是 `adopt-legacy`、`finalize`、`gc-step`、`probe-ack`、`probe-cancel`、`probe-create`、`probe-status`、`reconcile-start` 和 `reconcile-stop`。只有 main/watchdog/lifecycle/system-timer 这几类调用方可以触发对应的 `gc-step`；角色提示词不因此获得手动 GC 的权限。不手工伪造或删除运行时记录。

## 恢复进行中的任务

接手时先拿 `status.md` 和会自行前进的来源（`git log` / `git status`、`lanes/`、fixed-pack 观察器）交叉核对，有冲突就把核对后的状态写回并标明哪些是重建的。卡住的角色续做而不重做，以相同范围重新派发：可以缩小每轮输出量，不缩小总交付；增量复审不属于缩范围。细则（含 `## 恢复卡住的角色：绝不拿范围换交付`、从会话记录恢复未提交工作）见 `references/recovery.md`。

## 版本控制

提交和推送自主进行、不询问，失败记下后继续。不自行 force-push、`reset --hard` 或改写已发布的历史；共享工作树上的 `git stash push/pop`、`git checkout <file>`、`git restore <file>` 同样是破坏性操作，回退自己的改动用编辑前的备份或 `git apply -R`。合并到基线分支只在用户明确指示时做。细节见 `references/version-control.md`。

## Watchdog 强制层

插件的 hooks 和 monitor 为"重启无响应的角色"和"保持状态文件最新"兜底（L0–L7，见 `references/watchdog.md`）。主 agent 用阶段和声明说明任务为什么安静，插件观察事实、守住不变量。

主 agent 的义务：

- **arm 指针**：§1 用 `task-pointer.sh arm` 写 `.zyz-worker/sessions/<session-id>`，活动任务变化或会话恢复时重新 arm；没有指针就没有 watchdog。
- **文件名与阶段**：总状态文件叫 `status.md`，`Current Phase` 保持准确；只等到点观察时写 `observing` 并排定 `wait`。
- **确认已启用**：用只读的 fixed-pack 观察器确认 `main_heartbeat_epoch` 在推进；验证不了就在状态文件里和对用户说明 watchdog 未生效。
- **告警当指令**：`[zyz-worker watchdog]` 通知要立即执行——重新派发被点名的角色，或马上刷新状态文件。收到「会话静默」或「API 错误中断」时核实在等的通道，死掉的续做重派，正当在等就声明。
- **核实归属**：告警点名的路径属于本会话的任务（`task-pointer.sh show`）才写，否则报告用户。
- **停下前确认有执行者**：活跃阶段结束一轮前，确认有核实过的执行者（在跑的 subagent、后台任务或排定的唤醒），否则派发或声明。
- **声明**：用 `<plugin-root>/hooks/scripts/expect.sh`，不手写声明行、不手改 `runtime/`。提问后停下：同一条回复里 `set q user --reason …`；问题挂着但还有活：`set q user --watch`；等后台或外部：`set <key> wait --at +90m [--ref <id>]`；常驻后台任务：`resident --ref <id>`；会长时间安静：`tune silence-sec=<秒>`。

hooks 不可用时这些义务照样有效；`ZYZ_HOOKS_DISABLE=1` 关闭强制层。

## 编排模式

设置了 `ZYZ_WORKER_STATUS_FILE` 时运行在编排模式下，写第一份状态之前加载 `references/orchestration-mode.md` 并按其契约执行。要点：

- 挂起前、派发前、收到结果后、进入新阶段时原子写 `worker-status.md`（YAML frontmatter）：`phase`（`design | implementation | testing | review | delivery | awaiting-confirmation | done | error`）、`phase-since`、`wait-state`、`waiting-reason`、`expected-resume-by`、`last-flush`。
- `phase` 可以回退，但 `done` 是吸收态，只在用户确认交付后写入。
- 设计批准只来自用户接入 pane 或匹配 question-id 的 `answer.md`，记录写入 `status.md` 后才写 `phase=implementation`。
- `[zyz-worker reuse-runtime-config]` 块的值优先于启动时的环境变量；多 worktree 按仓库交付。

## 评审历史文件

标准档、严格档里，设计文档 `<basename>.md` 的评审历史放在同级的 `<basename>.review-history.md`，不发给实现阶段的角色。见 `references/design-doc-discipline.md`。

## 设计文档编辑纪律

适用于标准档、严格档的任务设计文档：纠正类发现就地改或删，理由写进评审历史；缺失类发现补上规格。见 `references/design-doc-discipline.md`。
