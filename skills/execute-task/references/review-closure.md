# 评审收口细则

命令都是 `<plugin-root>/hooks/scripts/review-round.sh <cmd>`，由它写 `status.md` 的 `## 评审收口`；它以 exit 3 拒绝时照输出做。

## 1. 评审点

- 用 `open` 登记：主路径 `--kind main`，附属子功能 `--kind aux`，汇总评审 `--stage aggregate`；`<point>` 用 `[a-z0-9-]+`。各评审点各自计轮次、各自关闭。
- `--tier` 只能比任务档位更严，降回去要 `--by user`。已关闭的评审点要再评审，先重新 `open`。

## 2. 轮次与模式

- 每轮先 `start <point>`（上一轮要已 `result`），输出 `round=<n> mode=full|incremental cross-harness=yes|no`。第 1 轮全量，之后增量；修复改变了结构（换了机制、移动了模块边界）时加 `--full --reason …` 开全量轮，轮次照常计数。
- 增量轮的输入：上一轮被接受的 `blocking` 清单、修复的 diff、被拒绝的 `blocking` 及理由。评审者做三件事：核实修复、评审这份 diff、对每条被拒绝的 `blocking` 认可或重新提出。
- 裁决完运行 `result`（§10）：
  - `N`：被接受的 `blocking` 条数；`M`：其中会改变产品行为的条数。
  - `R`：评审者报为 `blocking`、被拒绝或降级的条数。
  - `I`：`N + R` 里由上一轮修订带出的条数，按报告的「来源」列。
  - `P`：这个评审点此刻仍在等用户回答的 `blocking` 条数，含更早轮次提出的。等用户的条目不计入之后各轮的 `N`。
  - 第 2 轮起 `R`、`I`、`P` 必填，没有写 `0`。`result` 每次整行重填，更正时所有参数再写一遍。
- 设计评审点的 `start` 给本轮文档存快照（`--docs`，不给时取 `status.md` 的 `- 设计文档:`；每一轮给同一组）。第 2 轮起输出 `delta=+<增行>/-<删行> prev=… growing=yes|no` 和 `diff=<路径>`，增量复审用这份 diff。`growing=yes` 表示这一轮新写的比上一轮多，只告警：派发前按 §5、§6 再看一遍正文。

## 3. 等级

| 等级 | 含义 |
|---|---|
| `blocking` | 报告者指得出一条正常流程（设计 `## 场景` 里的一条，或所有人按预期使用时会发生的情况）走到它并出错（设计评审里是走不通）；或者实现违背已批准的设计 |
| `non-blocking:normal` | 在范围内、不会出错的改进 |
| `non-blocking:contrived` | 范围外（`SKILL.md` `## 范围`） |

- 举证在报告者一侧：报 `blocking` 要写出那条流程和出错的那一步。写不出的不是 `blocking`，裁决时拒绝或降级并写明理由。
- 等级只看问题本身，不看解法要不要加机制、改动有多大。
- 改动涉及安全或数据，而设计的 `## 范围边界` 没说有没有对手：标 `requires-user-decision`，问用户。
- 证据缺口（结论缺命令、输出或位置）是补证请求：作者补上，不算发现，不计入 `N`，不开新一轮。
- 设计里没写的 B 类细节不是发现，由实现者决定。

## 4. 关闭

`close <point> --outcome passed` 的条件：最近一轮 review-agent 没有报 `blocking`（`blocking=0`、`rejected=0`），没有条目在等用户回答（`pending=0`），本轮跨 harness 的发现都已处置、没有一条被接受为 `blocking`。

被拒绝的 `blocking` 记在 `--rejected`，这一轮关不了：下一轮的评审者认可这次拒绝，或重新提出。另外两种关闭由用户在停下时决定（§7）。

## 5. 非阻断发现

- 设计评审的 `non-blocking:normal` 不进设计正文，只记评审历史文件；实现者需要的细节写进 `<task-dir>/impl-notes.md`。不为它们另开一轮。
- 实现评审的 `non-blocking:normal`：有 `blocking` 修复要开下一轮时可以一起落地，前提是不加新机制；没落地的记进 `## 接受的遗留问题`（§9）。
- 要加新机制（新的表、接口、状态或跨模块规则）才能解决的非阻断发现，先用 `## 范围` 的两个问题重新核对等级。指得出走到它并出错的正常流程：改判 `blocking`，计入本轮 `N`。指不出或拿不准：等级不变，记进 `## 接受的遗留问题`，不在本任务内做。
- `non-blocking:contrived` 在 `## 后续对抗任务` 记一行，不修。

## 6. 修复与等用户

- `blocking` 的修复优先做减法：先看能不能删掉或收窄引出问题的东西，再考虑加规则或机制。减掉的是主 agent 自己加的东西时直接做；会缩小用户要的范围时只推荐，由用户决定。
- 要用户定的问题（A 类）裁决完当轮就问：一条消息列完，每条附推荐和它影响的设计部分，记进 `decisions.md` 的 `## 等待回答的问题`，声明 `user --watch`，不停下。
- 不依赖回答的修复照常做，下一轮照常开。依赖回答的部分保持原文：不按推荐项先改，不在设计正文里加批注，派发评审时列出这几处。用户回答后再改，改动进下一轮增量复审。剩下的修复全都依赖回答时才停下等。

## 7. 上限与提前停

轮数上限见 `SKILL.md` 的档位表。标准档的每个评审点（设计、实现、汇总）另有提前停：第 2 轮的 `blocking + rejected` 不为零、且不少于第 1 轮时，不开第 3 轮。

到上限或提前停时，`start` 拒绝并输出各轮走势。用一条消息交给用户：

1. **诊断**：各轮 blocking 走势；各轮修订量（`delta`）；本轮 blocking 的来源各几条（原有漏报、上一轮修订带出、等用户决定）；剩余的里面结构类（要改模块划分、接口或数据模型）和细节类（某个模块内部的规则）各几条。
2. **剩余 `blocking` 清单**，含被拒绝而评审者仍坚持的。
3. **三个选项和推荐**：
   - **再开一轮**：剩余问题涉及安全或数据、真实路径上的缺陷还在减少、或者修复方案已经明确时推荐。用户批准后 `grant <point> --reason <用户原话要点>`，一次只管一轮。
   - **接受为遗留风险**：逐条记进 `residual-risks.md` 的 `## 接受的遗留问题`，再 `close <point> --outcome residual --by user --reason …`。
   - **拆成加固任务**：清单写进新任务的输入，再 `close <point> --outcome split --by user --reason …`。

## 8. 严格档：收口检查

开第 4、7、10… 轮之前，对刚完成的三轮做一次检查：剩下的 `blocking` 是不是都在正常流程上、是不是在减少。用 `check <point> --outcome <o> --reason …` 记录，并用一条简短消息告诉用户结论：

- `continue`、`class-fix`（反复出现的一类问题一次修掉）、`reorder`（把拖住主路径的部分排到后面的 lane，仍在本任务内交付）：开下一轮。
- `escalate`：剩余的 `blocking` 取决于设计没有回答的问题，或者要把内容移出本任务。按 §7 带诊断和三个选项交给用户；用户同意继续后 `grant`。

## 9. 遗留清单

`<task-dir>/residual-risks.md`（`templates/residual-risks.md`），两节，每条一行：`## 后续对抗任务` 收范围外情形，`## 接受的遗留问题` 收用户在停下时接受的 `blocking` 和没落地的改进。路径随评审派发给出。

## 10. 命令

| 命令 | 作用 |
|---|---|
| `open <point> --stage design\|impl\|aggregate [--kind main\|aux] [--tier standard\|strict]` | 登记评审点，或升档、重开 |
| `start <point> [--full --reason …] [--docs <path>...]` | 开新一轮 |
| `result <point> --blocking N --rejected R --induced I --pending P [--behavior M]` | 记录本轮结果 |
| `grant <point> --reason …` | 用户批准的额外一轮 |
| `check <point> --outcome continue\|class-fix\|reorder\|escalate --reason …` | 严格档收口检查 |
| `close <point> --outcome passed\|residual\|split [--by user] --reason …` | 关闭评审点 |
| `tier <fast\|standard\|strict> --reason … [--by user]` | 写档位，降档要 `--by user` |
| `status [<point>]` | 各评审点的轮次、各轮数字、下一轮能否开 |

不给 `--task <task-dir>` 时作用于本会话的主任务。
