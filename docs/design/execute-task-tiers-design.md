# execute-task 分档与收敛改造设计

状态：已确认（2026-11-26，用户：「几个问题都按你的推荐处理」）。确认的取舍：设计评审上限按评审点计（主路径 / 附属子功能分开），到上限交用户；跨 harness 保留在设计各轮、实现第 1 轮和汇总评审，实现增量轮取消；轮次上限和收口检查由 hook 强制；快速档允许主 agent 直接改单 lane 的小改动；快速档和标准档由一个 lane agent 同时写代码和测试；watchdog 的问题另开独立 PR。落地契约见 §10。依据是 2026-11-26 的讨论，以及三份只读复盘：execute-task 重型任务的 517 条 blocking 发现分类、mumuko-api 快速开发、其它本地快速开发会话与本应是中短程的 execute-task 任务。复盘原始数据放在本机 `/tmp/zyz-retro/`，不进仓库，因为里面有业务细节。

## 1. 问题与根因

现象：设计→评审、实现→测试→评审的循环长时间不收敛。中短程任务最明显，但这个问题不分任务长短。

| 证据 | 数字 |
|---|---|
| 评审循环（含修复）占活跃时间 | 48% / 60%（两个重型任务） |
| blocking 修复后没有改变产品行为的比例 | 32%：测试强度 13%、文档同步 9%、证据流程 8%、其他 3% |
| 快速审阅漂移 | 文档同步类 44 条里占 27 条，改变产品行为 0 条 |
| 变异直接引出的 blocking | 21 条，改变产品行为 0 条；起作用的 2 例都是关键机制 |
| 实现阶段各轮的真缺陷 | 第 1 轮 58 条、第 2 轮 17 条、第 3 轮及以后 4 条 |
| 设计阶段第 3 轮及以后的真缺陷 | 54 条，其中 9 条中高危或涉及安全；约一半集中在附属子功能，另有 15 条是上一轮修复引入的 |
| 跨 harness 在实现第 1 轮的独有真缺陷 | 39 条（reviewAgent 只有 6 条）；第 2 轮起只有 3 条 |
| 收口检查实际执行率 | 6 个该做的点只做了 1 个；有一次设计跑到 14 轮，是用户手动叫停的 |
| 同量级小改动（生产代码 ≤150 行）的活跃时长 | 直接开发中位约 28 分钟；execute-task 中位约 144 分钟 |
| 合并后返工 | 两组没有明显差别（约 1/14 对 2/7，样本小） |
| 用户升级 | 某任务约 1/4 的回答是"全部按建议"；另一个任务约七成是真正的架构或算法决策 |

根因：

1. **停止条件是"对抗性评审者再也找不出问题"。** 这是一个无界搜索。工程验收应该用事先约定、有限的退出条件。
2. **blocking 的准入太宽。** 证据缺口、文档同步、测试强度都算 blocking，而且会自我再生。
3. **每轮都全量复审。** 多个发现源（变异、互补变异、两个评审者）的结果取并集。
4. **评审强度和风险不挂钩。** 所有任务走同一套流程，固定开销在小任务里占比极高。
5. **规则只增不减，没有成本意识；能机械检查的规则（比如轮次）也只写在提示词里，靠自觉执行。**

## 2. 设计原则

- **合同先行。** 设计批准时，验收标准、测试计划和声明域就构成合同。评审只判两件事：是否违反合同，以及在可达输入下能否复现缺陷。合同之外的问题进遗留清单，后续另开 PR 处理。"严格"体现在合同写得多细，而不是评审对抗多久。
- **成本意识。** 每个机制都要说清楚它花了什么、救过什么。说不清的就降级或删除。
- **机械的交给脚本，判断的写进提示词。** 轮次上限、收口检查、档位字段由脚本和 hook 执行；提示词只写需要判断的部分。
- **并行的单位是端到端的 lane**，不是多开几个同阶段的角色。

## 3. 三个档位

| | 快速 `fast` | 标准 `standard` | 严格 `strict` |
|---|---|---|---|
| 适用 | 目标明确、改动可回滚、影响面小：止血、小功能、配置、文案、几小时内的改动 | 大多数功能开发 | 鉴权/安全、数据迁移或删除、资金、不可逆变更、对外契约 |
| 设计 | 一条消息写清现状、改法、不在范围、怎么验证，记入 `status.md`；用户确认即可。不写设计文档 | 设计文档 + 快速审阅 | 同标准档，可以拆成多份文档 |
| 设计评审 | 无 | 每个评审点最多 2 轮 | 不设上限，有收口检查（§4.5） |
| 实现组织 | 单 lane：主 agent 直接改，或派 1 个端到端 lane；多个独立改动时多 lane 并行 | lane 模型（§6） | lane 模型；关键机制的实现和测试分给不同角色 |
| 测试 | 必须有负对照：新测试在旧代码上要失败；按项目惯例跑构建和测试 | 加上测试计划规定的类别；变异只用于设计标为"关键"的机制 | 现行全套 |
| 实现评审 | 1 轮独立评审，最多再 1 轮复核修复 | 每个评审点最多 3 轮；第 2 轮起是增量复审 | 不设上限；第 2 轮起是增量复审；有收口检查 |
| 跨 harness | 和那 1 轮评审并发跑一次 | 设计各轮、实现第 1 轮、汇总评审 | 同标准档 |
| 汇总评审 | 无（只有一个 lane 时）；多 lane 时做一次轻量的契约一致性检查 | 有 | 有 |
| 用户关卡 | 改法确认；合并、打 tag、发布前 | 设计批准；架构或算法类决定 | 同标准档 |

**档位怎么定**

- 显式参数：`/execute-task --fast|--standard|--strict <任务>`。
- 没给参数时，主 agent 在第一条回复里提议一个档位，并用一句话说明理由。用户随时可以用自然语言调整，比如"这个走快速"或"这块按严格来"。
- 档位记在 `status.md` 的 `Tier:` 字段，hook 从这里读。
- **升档：** 改动涉及鉴权、安全、数据删除或迁移、资金、不可逆操作时，主 agent 提议把相关评审点升档，用户确认即可。升档可以只针对某个评审点，不必整个任务一起升。
- **降档：** 主 agent 不能自行降档，只能由用户来降。
- **先止血，后功能。** 快速档遇到"止血 + 恢复功能"这类任务时，先交付止血，恢复功能另开任务并重新选档位，不在同一个任务里自动升成完整流程。

## 4. 评审收口 v2（适用于所有档位）

### 4.1 评审点按主路径和附属子功能拆开

设计和实现都把主路径单独设为一个评审点，每个附属子功能各自一个评审点，各自计轮次。附属子功能不能拖住主路径的关闭。复盘里约一半的设计 blocking 都集中在附属子功能上。

### 4.2 首轮全量，之后增量

- 第 1 轮：全量评审。
- 第 2 轮起：输入是上一轮被接受的 blocking 清单，加上修复的 diff。任务有两项：逐条核实这些修复是否已落地，再评审这份 diff 是否引入了新问题（复盘里有 15 条 blocking 是上一轮修复引入的）。
- 全量复审只在汇总评审时做，或者某次修复大到改变了结构时做。
- L5 范围守卫要放行带"增量复审"声明的派发。"恢复卡住的角色时缩减范围"仍然禁止。

### 4.3 blocking 的准入

只有以下三类算 `blocking`：

1. **可达的产品缺陷。** 实现评审要附复现：失败的测试、具体输入，或者调用路径的 `file:line`。
2. **设计缺失或矛盾。** 要指明具体章节，以及缺了什么或哪两处冲突。
3. **违反合同。** 验收标准或测试计划明确要求的东西缺失或不满足。

其余发现的去向：

| 发现 | 去向 |
|---|---|
| 测试强度（代码没错，测试不够强） | `non-blocking:normal`；如果合同点名要求的测试缺失，按第 3 类处理 |
| 证据或流程缺口（缺坐标、缺变异记录、维度没登记、冻结或哈希问题） | **补证请求**：作者补上，裁决者核对，不开新的一轮 |
| 文档同步（快速审阅漂移、引用不同步、措辞） | 主 agent 在设计批准前机械地重新生成一次；不进入评审 |
| 极端构造 | `non-blocking:contrived`，进遗留风险清单（现有规则不变） |

拿不准时：可达性不清楚，就按 blocking 处理，但必须写明那个悬而未决的可达性问题。不能用"拿不准"给证据缺口升级。

### 4.4 到上限时（快速档、标准档）

不悄悄关闭，也不自动继续。主 agent 用一条消息交给用户：剩余 blocking 清单、每条的可达性和影响，再给出建议，三选一：

- 再开一轮：剩余问题涉及安全或数据、真实路径的缺陷还在减少时，主 agent 应该建议这一项；
- 接受为遗留风险；
- 拆成加固任务。

用户批准再开一轮时，记一条 `extra-round` 授权，每次授权只管一轮。

### 4.5 严格档

不设轮次上限。保留现有的"主要问题 vs 边界或极端构造"分级：极端构造进遗留清单，后续另开 PR 增强，不在本轮里反复对抗，也不能影响主体实现。从第 3 轮起，每满 3 轮做一次收口检查，并由 hook 强制执行（§4.6）。

### 4.6 机械化

- 新脚本 `hooks/scripts/review-round.sh` 记录每个评审点的轮次，新 hook `review-gate.sh` 在派发 review-agent 时检查上限和收口检查；`cross-review.sh` 在实现阶段的增量轮自动跳过。命令、行格式、上限和闸门逻辑以 §10.4、§10.5 为准。

### 4.7 变异

- 快速档：只做负对照，不设变异门。
- 标准档：只对设计里标为"关键"的机制做变异，包括安全守卫、权限、数据完整性，以及用户点名的机制。互补面变异也只针对这些机制。
- 严格档：保持现状。

`Tested: true` 的变异要求同样按档位适用。

## 5. 用户设计主导权 v2

### 5.1 决定分两类

| 类 | 范围 | 处理 |
|---|---|---|
| A 设计决定 | 架构、模块划分、关键算法、对外接口契约、持久化的数据结构、用户可见的行为 | 必须经用户批准（不变） |
| B 可逆的实现细节 | 以后能低成本改回来的选择：内部命名、配置键的默认值、内部函数怎么拆分、日志措辞、内部错误码映射、依赖的小版本等 | 按推荐执行，批量记入 `decisions.md` 的「按推荐执行的决定」（§10.6）；在设计批准时和最终报告里列给用户，用户可以否决任何一条 |

拿不准属于 A 还是 B 时，按 A 处理。运维类许可（环境准备、用户已授权的合并）已经从 0.31.0 起不再询问，保持不变。

需要提问时，一次停下只发一条消息：所有问题编号列出，每条附推荐选项。用户回答"全部按建议"即视为逐条采纳。

### 5.2 实现中发现偏离

这种情况不常见。大多数实现中的疑问都在已批准设计之内，照常推进即可。只有在有证据时才触发，按下表处理：

| 情形（要附 `file:line` 或复现） | 做法 |
|---|---|
| 设计之内的局部选择，属于 B 类 | 照常做，记一笔；不回滚 |
| 实现已经偏离了已批准的架构或算法（换了机制、加了模块），而设计本身没错 | 把实现改回到设计 |
| 设计本身行不通：按原样实现，主路径输入会出错，或者根本实现不了 | 停下这一块，告诉用户问题和最小的选项集，等用户决定；其它不受影响的 lane 继续推进 |

写法约束：这条规则只在 `prompts/main-agent.md` 写一处，其它地方只引用；不用"绝不""必须"这类加重语气的词。

## 6. 并行模型 v2

### 6.1 lane

lane 是端到端的工作单位，可以是一个功能、一个 PR 或一个模块。每个 lane 有：

- 文件白名单和标识符前缀；
- 自己的 worktree 和分支，或者在共享 worktree 里有明确划分的插入区域；
- 自己的测试资源租约。

lane 内部自己完成实现、测试和自验证：构建、测试、负对照，还可以再派 Explore 去调研。lane 只做到本地提交为止；push、开 PR、合并由主 agent 或集成 lane 负责。

快速档和标准档里，一个 lane agent 同时写代码和测试，"作者不当自己的裁判"由独立评审来保证（评审包括检查断言形态）。严格档里，关键机制仍然由 implementation-agent 和 test-agent 分开负责。

### 6.2 两种模板

1. **契约骨架 + 按文件扇出。** 主 agent 先写出能编译的接口骨架，再一次性派出 N 个 lane。lane 共用一个 worktree，各自只碰自己的文件白名单，只测自己的包。
2. **一个 PR 一个 lane 一个 worktree。** worktree 由主 agent 用 `git-worktree` skill 创建，不用 `isolation: worktree`。适合跨仓库的改动，或者彼此独立的多个功能。

### 6.3 调度

- **解锁条件从"上游已评审"改为"接口已冻结"：** 上游的骨架能编译、接口不再变化，下游就可以开始。依赖正确性仍由汇总评审和集成测试兜底。
- **评审和实现流水线并行：** 某个 lane 一交付，就立刻派发对它的评审（以及跨 harness 评审），其它 lane 继续干活。评审意见回到同一个 lane 去修复。
- **lane 常驻：** lane 是具名的 teammate，修复轮通过 SendMessage 回到原来的 lane，上下文保留，不用重新派发。
- **设计阶段也并行：** 调研同时派出多个 Explore；拆成多份的设计文档可以并行起草。
- **汇总评审按维度并行，** 由多个 reviewer 同时跑。
- **集成 lane：** 并行 lane 达到 4 个及以上时，单独设一个 lane 负责合 main、跟进 CI 和转发评审 bot 的意见，减轻主 agent 的上下文负担。
- **lane 报告写到文件，** 消息里只传路径。复盘里有 33 条报告因为被截断而分段重发。
- **用户拍板的决策写进 `<task-dir>/decisions.md`，** 每个 lane 的派发都引用这个文件。这样 compact 之后决策不会丢，复盘里 compact 发生了 5 次。

并行没有固定上限，只受真实依赖和隔离能力约束。共享 worktree 里 lane 太多，测试会互相干扰，所以优先用模板 2，或者给每个 lane 划出严格的文件归属。

## 7. 提示词与状态文件瘦身

- `SKILL.md` 只保留入口、档位表、核心规则和文件索引，目标 ≤ 25 KB。`prompts/main-agent.md` 作为唯一的控制器。专题内容按需加载，放进 `skills/execute-task/references/`：编排模式、watchdog 声明、PR 评审、恢复与续做、版本控制、评审收口细则。现在 `SKILL.md` 和 `main-agent.md` 之间的重复内容全部去掉。
- 角色提示词按档位分节。review-agent 的"八种空转断言逐条作答"只在严格档或关键机制上要求；快速档用一份短的评审清单。
- 每条来自事故的规则标注来源；这次改造顺带清理已经被平台或模型能力覆盖的规则。
- `status.md` 只保留当前状态，包括 `Current Phase`、`Tier`、`## Agent State`、SubTask/lane 表、评审收口记录。用户决策历史、恢复记录、发现台账等追加型日志移到 `<task-dir>/log/`。
- freeze 和 tree-stable 的哈希要排除任务目录。复盘里至少 4 次是评审期间写 `status.md`，被跨 harness 评审误判为"评审对象变了"。

## 8. 不在本次范围（复盘发现的 watchdog 问题，另开任务）

- 没跑 execute-task 的会话出现误报；另一次 30 分钟无人干活却没报。
- Codex 作宿主时，调 Claude 做交叉评审在 180/300 秒超时下 5 次全部零产出。
- agent-team 的通知刷屏：一个会话里 74 条，主 agent 回了 23 次"重复"。

## 9. 实施计划

按 lane 并行：

1. **骨架（串行，主 agent）：** 新的 `SKILL.md` 结构和档位表，`references/` 目录划分，`status.md` 模板的新字段。
2. **以下 lane 在骨架完成后同时派出：**
   - a. `prompts/main-agent.md` 重写：§3–§6 的规则、档位判断、偏离决策表、去重；
   - b. `subagents/review-agent.md`：档位、blocking 准入、增量复审、补证请求；
   - c. `subagents/implementation-agent.md` 和 `test-agent.md`：lane 模式、负对照、变异按档位；同步 `agents/` 下的镜像；
   - d. templates：快速档的变更说明、`task-status.md` 瘦身、`review-report.md`、`decisions.md`、`log/`；
   - e. hooks：`review-round.sh` 和 PreToolUse 闸门、L5 放行增量复审、freeze 排除任务目录、`cross-review.sh` 跳过增量轮，以及对应测试（`scripts/test-*.sh`）；
   - f. references 抽取，以及 `docs/`（`watchdog-design`、`architecture`、`hooks/README`、`CLAUDE.md`）同步。
3. **汇总：** 跑全量测试，独立评审一次，再加一次跨 harness 评审。
4. **发版 0.33.0：** 按发版清单移动全部 7 处版本号。
5. **试点：** 用快速档在一个真实的小改动上跑一遍，对照本文 §1 的指标。

## 10. 落地契约（所有 lane 共同遵守）

本节是各 lane 之间的接口。任何 lane 想改本节，先报告主 agent，不要自行改动。

### 10.1 文件归属

所有 lane 共用 worktree `~/.zyz-worker/worktrees/zyz-worker/feat-execute-task-tiers`（分支 `feat/execute-task-tiers`）。每个 lane 只改自己名下的文件；lane 不做 git commit，提交由主 agent 负责。

| lane | 独占文件 |
|---|---|
| A skill | `skills/execute-task/SKILL.md`（重写）、`skills/execute-task/references/*.md`（新建）、`commands/execute-task.md`、`commands/code-development.md` |
| B main | `skills/execute-task/prompts/main-agent.md` |
| C review | `subagents/review-agent.md`、`agents/review-agent.md`、`skills/execute-task/templates/review-report.md`、`skills/execute-task/templates/cross-review-prompt.md` |
| D impl-test | `subagents/implementation-agent.md`、`subagents/test-agent.md`、`agents/implementation-agent.md`、`agents/test-agent.md` |
| E templates | `skills/execute-task/templates/` 下除 C 名下以外的全部文件，新建 `change-note.md`、`decisions.md` |
| F hooks | `hooks/scripts/review-round.sh`（新建）、`hooks/scripts/review-gate.sh`（新建）、`hooks/hooks.json`、`hooks/scripts/lib.sh`、`hooks/scripts/dispatch-scope-guard.sh`、`scripts/cross-review.sh`、`scripts/test-review-round.sh`（新建）、`scripts/test-cross-review.sh`、`scripts/test-watchdog-hooks.sh` 中 L5 相关的用例、`hooks/README.md` |
| H 集成（在 A–F 完成后） | 其余 `scripts/test-*.sh` 里的提示词锚点、`CLAUDE.md`、`README.md`、`docs/architecture.md`、`docs/design/execute-task-skill-design.md`、`docs/design/watchdog-design.md`、`CHANGELOG.md` 的 `[Unreleased]` |

`agents/*.md` 是 `subagents/*.md` 的镜像：只有 frontmatter 和身份行（"You are … for the execute-task skill."）不同，其余逐字一致。镜像一致性测试在 `scripts/test-orchestration-helpers.sh` 的 `t10_mirror_diff`。

### 10.2 通用写法

- 全部用简体中文。以下字面量保持英文：`## Agent State`、`- Current Phase:` 及其取值、`- Tier:` 及其取值、`Coded:` `Tested:` `Reviewed:` `Committed:`、`[zyz-worker watchdog]`、frontmatter 键、等级值 `blocking` / `non-blocking:normal` / `non-blocking:contrived`、遗留风险字段 `- Origin:` … `- Status:`、角色身份行。
- 一条规则只写在它的归属文件里，其它地方一句话引用。不用"绝不""必须"之类的加重语气词去强调；硬约束写成条件和动作。
- 体积目标：`SKILL.md` ≤ 25 KB；`main-agent.md` ≤ 30 KB；`review-agent.md` ≤ 15 KB；`implementation-agent.md` 和 `test-agent.md` 各 ≤ 12 KB。
- 保留的结构性保障：
  - 独立评审：作者不当自己的裁判；
  - 状态持久化；
  - watchdog 义务：arm 指针、`status.md` 文件名、阶段、声明、告警处理；
  - A 类设计决定经用户批准；
  - 总目标忠实度；
  - 破坏性 git 操作禁令；
  - 编排模式契约（`worker-status.md` 字段、阶段映射、复用块、多 worktree），逐条保留，不改语义；
  - 恢复时不能拿范围换交付，但增量复审不属于缩范围；
  - 标准档和严格档的测试计划底线：单元 / 回归 / e2e。
- 别的文件引用了下面这些 `SKILL.md` 标题，它们要保留在 `SKILL.md` 里（可以只剩一两句话加一个指向 `references/` 的链接）：`## 评审收口`、`## Watchdog 强制层`、`## 编排模式`、`## 自动执行策略`、`## 用户设计主导权`、`## 跨 harness 交叉评审`、`## 设计文档编辑纪律`、`## 总目标忠实度`、`## 增量输出`、`## 评审历史文件`、`## 恢复进行中的任务`、`## 版本控制`。新增的标题：`## 档位`、`## 并行模型`。

### 10.3 档位字段与参数

- `status.md` 的 `## 元数据` 里，`- Current Phase:` 的下一行是 `- Tier: fast|standard|strict`。没有这一行，就按旧任务处理：hook 对它 fail open，提示词按 `strict` 的旧行为执行。
- 命令参数：`$ARGUMENTS` 以 `--fast` / `--standard` / `--strict` 开头时，取该档位。自然语言"快速档 / 标准档 / 严格档"等同于对应参数。
- 档位变更由主 agent 用 `review-round.sh tier <fast|standard|strict> --reason …` 写入。写入会在 `log/tier.md` 追加一条记录；降档时要求 `--by user`。

### 10.4 评审点与 `review-round.sh`

用法：`<plugin-root>/hooks/scripts/review-round.sh <cmd> [--task <task-dir>]`。不给 `--task` 时，默认作用于本会话的主任务（与 `expect.sh` 的解析方式相同）。脚本校验后原子写入 `status.md` 的 `## 评审收口`，主 agent 不手写这些行。

| 命令 | 作用 |
|---|---|
| `open <point> --stage design\|impl\|aggregate [--kind main\|aux]` | 登记一个评审点。`<point>` 用 `[a-z0-9-]+`，例如 `design-main`、`design-replay`、`impl-st2`、`aggregate` |
| `start <point>` | 开新的一轮。超过上限且没有授权、或者严格档缺收口检查时，以 exit 3 拒绝，并输出该怎么做（交用户 / 先做收口检查）；成功时输出 `round=<n> mode=full\|incremental cross-harness=yes\|no` |
| `result <point> --blocking N [--behavior M]` | 记录本轮结果。`M` 是本轮被接受的 blocking 里会改变产品行为的条数 |
| `grant <point> --reason …` | 用户批准额外一轮，一次授权只管一轮 |
| `check <point> --outcome continue\|class-fix\|reorder\|escalate --reason …` | 严格档的收口检查 |
| `tier …` | 见 §10.3 |
| `status [<point>]` | 列出评审点、轮次、上限、下一轮的模式 |

写入 `## 评审收口` 的行格式：

```text
- Review: point=<id>; stage=<s>; kind=<main|aux>; round=<n>; started=<unix>; blocking=<n|->; behavior=<n|->
- Review-Grant: point=<id>; round=<n>; at=<unix>; reason=<text>
- Review-Check: point=<id>; round=<n>; outcome=<o>; at=<unix>; reason=<text>
```

上限（同一评审点的总轮数，含首轮）：

| | design | impl | aggregate |
|---|---|---|---|
| fast | 0（不派设计评审） | 2 | 1 |
| standard | 2 | 3 | 3 |
| strict | 无 | 无 | 无 |

- 严格档在开第 4、7、10… 轮之前，上一满三轮必须有一条 `Review-Check` 记录。
- 模式：每个评审点第 1 轮 `full`，之后都是 `incremental`。
- `cross-harness`：
  - design 各轮：fast 无设计评审；standard 和 strict 为 `yes`；
  - impl：只有第 1 轮为 `yes`；
  - aggregate：第 1 轮为 `yes`；
  - 设置 `ZYZ_CROSS_REVIEW=off` 时一律为 `no`。

### 10.5 评审派发的标记与闸门

主 agent 每次派发 review-agent 时，派发 prompt 里要有一行：

```text
review-point=<id> round=<n> mode=<full|incremental>
```

新 hook `review-gate.sh`（PreToolUse，matcher `^Agent$`，只处理 review-agent 派发）的逻辑：

- 解析到本会话的任务，且该任务有 `Tier:` 时，检查这一行是否存在，以及它是否和 `review-round.sh` 已 `start` 的最新一轮一致。缺失或不一致时拒绝派发，拒绝理由写明要先运行的命令。
- 没有任务、或者没有 `Tier:` 时，fail open。
- `ZYZ_REVIEW_GATE_DISABLE=1` 只关闭这一个闸门。

L5 范围守卫遇到 `mode=incremental` 标记的派发时放行。不带这个标记时，现有的缩范围检测不变。

`cross-review.sh run` 新增参数 `--point <id> --round <n>`：

- 对 impl 评审点且 `n ≥ 2` 时，直接输出 `status=skipped reason=incremental-round`，不启动评审者。
- 设置 `ZYZ_CROSS_REVIEW_FORCE=1` 时照常运行。

tree-stable 的指纹计算要排除 `.zyz-worker/` 和 `--task-dir` 所在目录。

### 10.6 任务目录布局

```text
<task-dir>/status.md         当前状态：元数据（含 Tier）、总目标、进度、Agent State、SubTasks（lane 即 SubTask，字段名不变）、评审收口、当前未关闭的发现台账、交付前检查清单、下一步
<task-dir>/decisions.md      用户决策（A 类问答原文要点）与"按推荐执行的决定"（B 类），lane 派发时引用
<task-dir>/change-note.md    快速档的变更说明（代替设计文档）
<task-dir>/lanes/<id>.md     lane 报告：lane 写入，消息里只传路径
<task-dir>/log/*.md          追加型日志：restarts.md、tier.md、review-ledger.md（已关闭的发现）
<task-dir>/design/…          设计文档与 *.review-history.md（标准档和严格档）
<task-dir>/residual-risks.md 遗留风险清单（不变）
```

### 10.7 契约补充（回应 lane 疑问，2026-11-26）

1. **结构性修复后改走全量复审。** 用 `review-round.sh start <point> --full --reason …` 强制本轮 `mode=full`。impl 评审点的全量轮 `cross-harness=yes`。轮次照常计数，上限不变。
2. **评审点的关闭。** 新增命令 `close <point> --outcome passed|residual|split [--by user] --reason …`，写入一行：
   `- Review-Close: point=<id>; round=<n>; outcome=<o>; at=<unix>; reason=<text>`
   - `passed`：要求最近一轮已 `result`，且 `blocking=0`。
   - `residual` 和 `split`：要求 `--by user`，是用户在 §4.4 三选一时的处置。
   - 已关闭的评审点再 `start` 会被拒绝；要重开需要先 `open`，`open` 会生成新的一组记录。
   - 交付核验要求每个已登记的评审点都有一条 `Review-Close`。
3. **设计批准记录**留在原位：`status.md` 的 `## 设计评审 > 设计批准记录`。编排模式靠这里判断能否进入实现，位置不变。快速档的改法确认也记在这一处，原文要点写进 `change-note.md`。
4. **快速档和标准档的 lane** 用 `implementation-agent` 的 lane 模式，同时写代码和测试。
5. **`status.md` 里的固定小节名：**
   - `## 发现台账`：只放当前未关闭的发现，来源包括 reviewAgent、跨 harness 和 PR 评审，用一列"来源"区分；被拒绝的发现带着理由也留在这里，直到评审点关闭，之后移到 `log/review-ledger.md`。
   - `## 并行资源租约`：保留。
   - `## 设计评审`：保留，只放最近一次评审结果和设计批准记录。
   - `## 跨 harness 交叉评审`、`## PR 评审`：并入 `## 发现台账`，不再单列。
6. **合同包含已批准的设计本身**：快速档是 `change-note.md`，标准档和严格档是设计文档。所以实现违背已批准设计，属于 blocking 的"违反合同"。
7. **"关键机制"由主 agent 在设计文档的 `## 关键机制` 小节里列出**，依据是用户的设计，加上安全、权限、数据完整性这类机制，以及用户点名的机制。这一节同时列入 `### 需要你关注的细节`，随设计一起批准。用户可以增删。快速档没有关键机制清单，只做负对照。评审者认为有遗漏时，提一条 `non-blocking:normal` 建议，不作为 blocking。
8. **声明域条款**：主 agent 在审批闸门前重新生成快速审阅时，把用户没有亲口说过的范围边界条款（首先是威胁模型）列进 `### 需要你关注的细节`。评审方面，涉及安全或数据的改动缺少声明域、或者声明域含糊时，算 blocking 的"设计缺失"，并标 `requires-user-decision`。
9. **单个评审点升档**：`open <point> --stage … [--kind …] [--tier standard|strict]`。`--tier` 只能比任务级 `- Tier:` 更严；写入时在该评审点的 `Review` 行加 `tier=<t>` 字段，上限、`mode`、`cross-harness` 都按这个评审点自己的档位算。改已经打开的评审点的档位，用 `open <point> --tier …` 重新打开（只能升）。降回任务档位要求 `--by user`。review-gate 比对的 `Tier:` 行取评审点的生效档位。

### 10.8 最终评审后的修正（2026-11-26，独立评审 + 跨 harness 评审）

1. **被拒绝的 blocking 要由独立方复核。**
   - 命令改为 `result <point> --blocking N [--rejected R] [--behavior M]`。`N` 是本轮被接受的 blocking 条数；`R` 是评审者报告为 blocking、但被裁决者拒绝或降级的条数。`Review` 行新增 `rejected=<n|->` 字段。
   - `close --outcome passed` 要求最近一轮 `blocking=0` 且 `rejected=0`。
   - 下一轮（增量）的输入在"被接受的 blocking 清单 + 修复 diff"之外，还要附上"被拒绝的 blocking 及理由"。评审者对每一条二选一：在 `## 已复核的被拒绝建议` 里认可这次拒绝，或者重新提出为 blocking。
   - 拒绝一直僵持到上限时，按 §4.4 交用户三选一。
2. **review-gate 只放行尚未出结果的那一轮。** 最新一轮已经 `result`，就拒绝用同一标记再派发。
3. **每一轮评审都重新派发 review-agent。** 不能把评审者留作常驻 teammate、下一轮用 SendMessage 续用，因为那样会绕开闸门。
4. **严格档：非关键机制的变异由作者 lane 自己写、自己执行。** 关键机制仍按 test-agent 写、implementation-agent 执行。
5. **严格档收口检查只认刚完成的这一组三轮：** 要开第 n 轮（n = 4, 7, 10…），必须有一条 `round == n-1` 的 `Review-Check`。`escalate` 结论在任何轮次都挡住下一轮，直到用户 `grant`。
6. **重开已关闭的评审点时，保留原来的单点档位。** 降档无论走哪条路径，都要求 `--by user`。
7. **aggregate 只有第 1 轮 `cross-harness=yes`。** 用 `--full` 开的 aggregate 轮也是 `no`。
8. **编排模式定档。** worker 把所选档位和一句理由写进第一份交给用户的确认问题里（快速档是改法确认，标准档和严格档是设计批准），由用户确认或改档。主条目不新增字段。
9. **主 agent 可以跑只读验证命令**，包括复跑 lane 的构建或测试命令来核对结论，但不替代 lane 的权威运行。依据是 2026-11-26 讨论中用户认可的"缩短修复回路：……主 agent 可以跑只读的验证命令"；第 1 轮评审的 N10 据此拒绝，第 2 轮评审认可了这次拒绝。
10. **遗留到后续加固**（极端构造，或不在本次范围内）：
    - 第 1 轮 C1–C4：cross-review.sh 推断 stage 时不跳过 HTML 注释；`tier` 命令遇到遗留风险格式的 `- Tier:` 行；多任务同名评审点互相满足标记；tree 指纹排除没有加 `literal`。
    - 第 2 轮 R2-N2：作者可以重写自己的 result 或 check 记录。
    - 第 2 轮 R2-N3：cross-review.sh 自身不拦 aggregate 第 2 轮起的运行，作为纵深防御。

## 11. 设计评审收敛修正（0.34.0，2026-11-27，用户已确认）

### 11.1 依据

0.33.0 发布后的第一个标准档任务（一个六分册、约 200 KB 的数仓引擎设计）在设计评审上没有收敛。三个评审点前两轮的 blocking 数：主路径 24 → 16，注册表 12 → 14，切换 9 → 7。第 3 轮是用户授权加开的。

- **发现本身是真问题：** 前两轮 82 条 blocking 里，75 条修复后会改变产品行为。
- **评审对象逐轮变大：** 设计文档 95 KB → 145 KB → 199 KB，第 2 轮三个评审点都走了全量复审。
- **新问题主要来自修订本身：** 第 3 轮先回来的 9 条 blocking，全部出在第 2 轮修订新写的规则里。其中至少 4 条能追到两条被落地的非阻断发现上。
- **非阻断发现全部进了设计正文：** 两轮约 200 条。`design-doc-discipline.md` 写的是"只做记录"，`review-closure.md` 写的是"可以一起落地"，两处矛盾，主 agent 按后者执行。
- **要用户定的问题攒到批准闸门：** 两轮有 18 条 blocking 需要用户决定。主 agent 先按推荐项改了正文再送评审，评审者评的是未确认的方案；有一个问题因此连续三轮被报。

结论：设计文档是散文，没有编译器和测试来裁决。每轮修订新写的文字越多，下一轮能被挑出的问题就越多。要收敛，每轮新写的量必须逐轮变小。单纯放宽轮次上限不解决问题。

### 11.2 每轮修订怎么做（所有档位）

1. **等级只看问题本身。** 按当前设计原样实现，在声明域内的真实情况下会出错，就是 `blocking`，否则是非阻断。解法要不要加机制，不影响等级。
2. **设计评审的非阻断发现不进设计正文。** 只记入评审历史文件。实现者确实需要的细节写进 `<task-dir>/impl-notes.md`，随 lane 派发，由实现评审验证。实现评审的非阻断发现仍可随阻断修复落地，前提是不引入新机制。
3. **非阻断发现要加机制才能解决时，先重新核对等级。** "新机制"指新增表、接口、状态，或跨模块的规则。核对后确实会出错的，改判 `blocking`，附可达性证据，计入本轮 blocking 数。不会出错的，记入遗留风险清单，后续 PR 再做，不在本任务内完成。
4. **blocking 的修复优先做减法。** 减掉的是主 agent 自己加的东西，可以直接做。会缩小用户要的范围时，主 agent 只推荐，由用户决定（A 类）。
5. **要用户定的问题，裁决完马上问；依赖回答的部分不动。**
   - 每轮裁决后，用一条消息列完所有必须由用户定的问题。每条附推荐，并写明它影响设计的哪些部分。用 `expect.sh set <key> user --watch` 声明：用户会收到 IM，主 agent 不停下。
   - 必须由用户定的范围是：架构、关键算法、对外契约、持久化数据、用户可见行为、范围取舍。
   - 不依赖回答的修复照常做，下一轮评审照常开。
   - 依赖回答的部分保持原文，标为待定。派发评审时告诉评审者这几处在等用户，不用重复报告。
   - 用户回答后再改这几处，改动进下一轮增量复审。
   - 剩下的修复全都依赖回答时，主 agent 才停下等用户。
   - 还有待定问题的评审点不能按 `passed` 关闭（原有规则，不变）。
   - §3 和 §4 里"不阻碍主路径的问题集中到批准闸门再问"的做法作废。

### 11.3 什么时候停、停下时说什么

6. **标准档设计评审上限从 2 轮改为 3 轮。** 实现评审本来就是 3 轮。
7. **第 2 轮不收敛就提前停。** 适用于标准档的每一个评审点（设计、实现、汇总）。第 2 轮的 blocking 数不少于第 1 轮时，不开第 3 轮，先按第 8 条交给用户。"blocking 数"取被接受的与被拒绝的之和。第 2 轮一条都没报时不算不收敛（判据是第 2 轮 ≥ max(第 1 轮, 1)）：两轮都没有新 blocking、只剩待定项，用户回答后开第 3 轮复审是正常路径。
8. **停下来问用户时带诊断，选项是四个。**
   - 诊断包括：
     - 各轮 blocking 走势；
     - 各轮修订量；
     - 本轮 blocking 的来源：原有漏报、上一轮修订带出（含只落地一半的）、等用户决定；
     - 剩余 blocking 分成结构类和细节类。结构类指要改模块划分、接口或数据模型；细节类指某个模块内部的规则。
   - 选项：
     - 再开一轮；
     - 带着进实现（新增）；
     - 接受为遗留风险；
     - 拆成加固任务。
   - 只剩细节类时，主 agent 推荐"带着进实现"：每条写成 `impl-notes.md` 里必须通过的测试项，交付前逐条核对。
   - 严格档的收口检查结论为 `escalate` 时，同样带这份诊断。

### 11.4 `review-round.sh` 的改动

- **上限表：** `standard` 的 `design` 从 2 改为 3。
- **`result` 新增两个参数，写入 `Review` 行的同名字段：**
  - `--induced I`：本轮 blocking 里由上一轮修订带出的条数，含只落地一半的。
  - `--pending P`：这个评审点此刻仍在等用户回答的 blocking 条数，包括更早轮次提出、还没回答的。它是一个当前状态，不是本轮 blocking 的子集，所以不和 `blocking + rejected` 比大小。评审者按要求不重复报告待定项，这些项不再计入之后各轮的 `--blocking`，只通过 `--pending` 体现。
  - 字段顺序接在 `behavior=` 之后：`induced=<n|->; pending=<n|->`。
  - 有档位的任务从第 2 轮起，`--induced` 和 `--pending` 都必填（没有就填 0），缺了以 exit 2 拒绝。旧任务不要求。
- **`start` 的提前停：** 生效档位是 `standard`、准备开第 3 轮、第 2 轮的 `blocking + rejected` 不少于第 1 轮、且没有本轮 `grant` 时，以 exit 3 拒绝，并输出各轮走势和第 8 条的做法。
- **`start` 的修订量：**
  - 新增可选参数 `--docs <path>...`，列出本轮被评审的文档。不给时，取 `status.md` 元数据里 `- 设计文档:` 一行的路径。
  - 对 design 评审点，把这些文档复制到 `<task-dir>/reviews/snap/<point>/r<n>/`。从第 2 轮起，与上一轮的快照比较，输出 `delta=+<增行>/-<删行> prev=+<a>/-<b> growing=yes|no`，并把 diff 写到 `<task-dir>/reviews/snap/<point>/r<n-1>-r<n>.diff`，供增量复审使用。
  - `Review` 行新增 `delta=+a/-b` 字段。
  - 新增行数比上一轮多时只告警，不拒绝。
  - 没有可读的文档时跳过，不报错。
- **`close` 新增结局 `carried`：** 需要 `--by user`，表示剩余 blocking 带进实现。
- **`pending`：** 最近一轮 `pending` 大于 0 时，`close --outcome passed` 被拒绝；`start` 不因此拒绝。
- **`status`：** 每个评审点多显示各轮的 `blocking / rejected / induced / pending / delta`。

### 11.5 任务目录

新增 `<task-dir>/impl-notes.md`，分两节：

- **实现备注：** 设计评审里实现者需要的非阻断细节，每条注明来源发现的编号。
- **带进实现的 blocking：** 每条写成一个必须通过的测试项，交付前逐条核对是否已落地。

lane 派发时，这个文件和 `decisions.md` 一起附上。

### 11.6 范围

- 第 6、7 条只针对标准档，其余对严格档同样适用。
- 修订量只在设计阶段计量，只告警、不拦截。实现阶段有测试裁决，不计量。
- 没有 `- Tier:` 的旧任务对新增的检查一律 fail open。

### 11.7 最终评审后的修正（2026-11-27，独立评审 + 跨 harness 评审）

第 1 轮：独立评审 1 条 blocking（B1），Codex 2 条（F1、F2），都接受；没有被拒绝的 blocking。

1. **`impl-notes.md` 要交给实现评审（B1）。**
   - 评审派发在文件存在时附上 `impl-notes.md`；严格档 test-agent 的派发同样附上。
   - 评审者逐条核对：`## 实现备注` 的条目是否落地；`## 带进实现的 blocking` 每条的测试是否存在并通过，缺测试或测试不过按违反合同报告。
   - 两节和设计正文的关系不同。`## 带进实现的 blocking` 的条目在它写明的范围内优先于设计正文：用户选"带着进实现"时同意的就是这处偏离，评审者不把按它做的修复报成违反合同。`## 实现备注` 不改设计，和设计冲突时 lane 停下这一块并报告主 agent。
2. **修订量只比较两轮都采集到的文档（F1，独立评审 N9）。** 上一轮快照里有、这一轮没有采集的文档（超过大小上限，或这一轮没有列出而源文件还在）不参与比较，输出一行 `note:` 写明是哪几份；源文件已经不存在的按删除计。这一轮新出现的文档按新增计，同样输出 `note:`。上一轮没采集到的文档回来的那一轮也不参与比较，下一轮恢复——否则整份文档的行数会被算成新增，误报修订量变大；代价是那一轮它的改动没有被计量。为了判断源文件是否还在，每轮快照旁边写一份 `r<n>.sources.json` 记录来源路径；上一轮没有这份记录时不比较。提示词写明同一评审点每一轮给同一组文档。
3. **提示词里的提前停判据补上零发现的例外（F2）。** 三处短写法与 §11.3 第 7 条对齐：第 2 轮的 blocking 数不为零、且不少于第 1 轮时才提前停。
4. **`--rejected` 从第 2 轮起必填（独立评审 N1）。** 有档位的任务第 2 轮起，`result` 的 `--rejected`、`--induced`、`--pending` 三个都要给。原因：`result` 是整行重填，漏写的 `--rejected` 会按 0 参与提前停的比较。
5. **"带着进实现"在实现和汇总评审点的含义（N3）。** 剩余 blocking 照修，不再开评审轮；每条同样写成必须通过的测试项记进 `impl-notes.md`，由交付核验逐条确认。快速档的交付清单也核对这一项（N4）。
6. **重新核对等级时，可达性拿不准的不改判（N6）。** 改判只凭可达性证据；"拿不准按 blocking"只适用于评审者第一次定级，不适用于为了加机制而做的重新核对。
7. **其它文字修正：**
   - `design-doc-discipline.md` 里"补规格带来的增长是预期之中"加限定：只指被接受的 blocking（N7）；
   - 待定项标在 `decisions.md` 的"影响的设计部分"，不在设计正文里加批注（N14）；
   - 交付清单核对 `decisions.md` 里没有仍在等回答的问题（N12）；
   - `- 设计文档:` 支持嵌套列表写法，解析到目录或不存在的路径时输出 `note:`（N10）；
   - 编排模式的问答入口补上提前停（N8 的一部分）；
   - 补 4 MB 上限和快照目录排除的测试（N11）。
8. **遗留到后续加固：**
   - N2：评审点已被提前停或上限挡住时，主 agent 仍可以不带 `--by user` 升到严格档，从而解除这两项限制。提示词要求升档经用户确认，脚本没有强制。0.33.0 起就是这样。
   - N8：编排模式下 worker 不停下时，"裁决完马上问"的问题要等 worker 真正停下才会被编排器通知给用户。结果不会出错，只是问得晚。
   - N13：待定项在第 1 轮计入 blocking 数，第 2 轮起不再计入，提前停的比较因此偏向"已收敛"。
   - C1–C4：自报的数字和 `--by user` 脚本无法核实（同 §10.8 的 R2-N2）；用户回答后的改动可以不经复审就关闭；`- 设计文档:` 的自由文本可能碰巧解析到无关文件；从未评审的评审点也能 `close --outcome carried`。
