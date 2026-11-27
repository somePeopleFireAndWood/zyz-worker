# 评审报告

- 派发标记: review-point=<id> round=<n> mode=<full|incremental>（原样回显派发里的这一行；派发里没有时写 `missing`，并按 `mode=full` 评审）
- 档位: <fast | standard | strict>（回显派发里单独一行的 `Tier:`；没给时写 `strict (unset)`）
- 评审类型: <design | implementation | aggregate>

## 范围

<!-- 评审对象（文件、diff 基准、评审点）。写明评审开始时记录、结束时复核的被评审文件 mtime / 哈希。评审过程中有文件变了，本报告作废——报告给主 agent 以便重新派发，不修补发现。mode=incremental 时写明上一轮被接受的 blocking 清单、被拒绝的 blocking 及理由的来源，以及修复 diff 的范围。派发里列了"等用户决定"的点时，在这里照抄一遍。 -->

## 覆盖维度

<!-- 每个维度登记为 `covered` 或 `not-covered: <具体理由>`；有一个未登记，评审就没有结束，无论下面的 `结果` 写什么。按档位和模式只保留适用的那一组，删掉其余。 -->

快速档（`fast`）：

- 正确性: (covered | not-covered: <reason>)
- 改法符合变更说明: (covered | not-covered: <reason>)
- 负对照: (covered | not-covered: <reason>)
- 明显回归: (covered | not-covered: <reason>)

标准档 / 严格档（设计评审时，面向实现的维度登记为 `n/a: design phase`）：

- 设计一致性: (covered | not-covered: <reason>)——双向逐元素：设计要求的一样不缺，也没有与设计相抵触之处。
- 正确性: (covered | not-covered: <reason> | n/a: design phase)
- 测试质量: (covered | not-covered: <reason> | n/a: design phase)
- 回归风险: (covered | not-covered: <reason> | n/a: design phase)
- 风险专项: （设计 `## 风险` 点名的每个维度一行，例如性能、安全、数据迁移；或 `n/a: no such risk recorded`）

`mode=incremental`：

- 修复落地核实: (covered | not-covered: <reason>)
- diff 新问题: (covered | not-covered: <reason>)
- 被拒绝 blocking 复核: (covered | not-covered: <reason> | n/a: none rejected)
- 其余维度: n/a: incremental round

## 结果

- 状态: （当且仅当下面至少有一个发现是 `blocking` 时为 `changes-requested`；否则为 `no-changes-needed`。补证请求不影响状态。）
- 评审者: （`reviewAgent`；跨 harness 评审会话则为 `cross-harness:<harness>`）

## 修复落地核实

<!-- 仅 mode=incremental；mode=full 写 n/a。上一轮被接受的每条 blocking 一行。未落地或部分落地的条目沿用原编号，在 ## 发现 中仍记为 blocking。 -->

| 上轮编号 | 内容（一句话） | 状态（已落地 / 部分落地 / 未落地） | 证据（file:line 与实际内容；实现评审附复现结果） |
|---|---|---|---|

## 发现

<!-- 编号，按严重程度排序；编号会进入主 agent 的发现台账和 ## 下一轮评审输入。规则见 reviewAgent `## 发现分级`，以设计的 `## 范围边界` 为准：
     - `blocking` 只有三类，「类别」列必填：
       缺陷——声明域或现有调用方能产生的输入上出错；实现评审附复现（失败的测试 / 具体输入 / 调用路径 file:line）。
       设计——设计缺失或矛盾；写明章节，以及缺了什么或哪两处冲突。
       合同——验收标准、测试计划或已批准设计明确要求的东西缺失或不满足；写明条款。
     - `non-blocking:normal`——真实的改进，但任何可达输入上都不出错：测试强度（合同点名的测试缺失除外）、清晰度、可维护性、设计文档卫生（去向是评审历史文件）。
     - `non-blocking:contrived`——只在声明域之外出现，并且没有现有调用方能触达；附最小复现、列举的调用方、加固方案（如有）。同一类的多个变体算一条。
     - 可达性拿不准时按 `blocking`，在「可达性 / 复现」里写明悬而未决的可达性问题。证据或流程缺口不是发现，写进 ## 补证请求。文档同步（快速审阅漂移、引用、措辞）不评审。
     - 等级只看问题本身：按原样实现会不会在声明域内出错。解法要不要加机制不影响等级。
     - 「标注」列按需填：`requires-user-decision`（附两种解读或最小选项集）、`recurring: <class> (rounds …)`（附类级修复覆盖什么）、`outside-diff`（增量轮在 diff 之外顺带发现）。
     - 「来源」列从第 2 轮起必填（含 `--full` 开的全量轮），主 agent 用它填 `result --induced`：`原有`（之前就有、前几轮没报）或 `上一轮修订带出`（上一轮修复新写的内容引出的，含只落地一半的修复）。第 1 轮写 `-`。
     - 派发里列为"等用户决定"的点不重复报告；有新的事实时照常报告，并写明新在哪里。
     等级改变的是去向，不改变是否报告：每条发现都在这里出现，并带着各自的证据。证据较长时，在表格下方用 `### F<n>` 展开。 -->

| # | 等级 | 类别 | 位置与原文 | 问题 | 可达性 / 复现 | 来源 | 标注 |
|---|---|---|---|---|---|---|---|

## 补证请求

<!-- 证据或流程缺口：结论缺坐标（完整命令、测试库、端口、进程启动时间对源码 mtime）、缺变异记录、维度没登记、冻结或哈希问题、没有证据的"已覆盖"。它们不算发现，不影响 ## 结果；作者补上，裁决者核对，不开新一轮。没有就写 none。 -->

| # | 缺什么证据 | 应补在哪里 | 怎么核对 |
|---|---|---|---|

## 独立复现

<!-- 你只读地重跑了作者的哪些关键结论，以及你的探针与作者记录的输出如何对齐（用作判据之前逐字节比对）。范围按档位：快速档核对 lane 报告里的负对照证据（命令、旧代码上失败、新代码上通过的输出），成本低时可复跑；标准档复跑主路径测试和关键机制的检查；严格档覆盖全部关键结论。设计阶段评审写 n/a。 -->

## 注入的变异

<!-- 互补面变异（你自己选的目标）：每条写目标、预期变红的用例、KILLED/SURVIVED，以及还原验证——逐文件对变异前的备份执行 `cmp`，不是"git status 干净"，也不用 git checkout/restore 还原。范围按档位：严格档覆盖每个声称已覆盖的机制；标准档只覆盖设计标为"关键"的机制；快速档写 `n/a: fast tier, negative control checked`；设计阶段写 n/a。 -->

## 空转断言清单

<!-- 严格档，或标准档中设计标为"关键"的机制：八种形态（见 reviewAgent `## 空转断言清单`）逐条作答，每种附读到的证据（file:line + 实际谓词），不合并成"其余都没问题"。其它情况写 `n/a: <档位>, no critical mechanism`。 -->

## 必须修改项

<!-- 即上面全部 `blocking` 的编号与一句话修复方向；`requires-user-decision` 的条目写成待用户决定，不写成必须修复。 -->

## 建议

## 已复核的被拒绝建议

<!-- mode=incremental：上一轮被拒绝或降级的每条 blocking 一行，二选一：认可这次拒绝（写明依据），或重新提为 blocking（同时在 ## 发现 里记一条，附证据）。没有被拒绝的条目写 none。已登记在遗留风险清单或评审历史文件中的条目凭 id 答复一次。 -->

| 上轮编号 | 内容（一句话） | 拒绝理由（摘要） | 结论（认可拒绝 / 重新提为 blocking → ## 发现 #<n>） | 依据 |
|---|---|---|---|---|

## 遗留风险

<!-- 本轮留下的非阻断行为或测试发现，每条写成一条遗留风险清单记录（字段同 `templates/residual-risks.md`）：

- Origin: <评审点> #<发现编号>（<reviewAgent | cross-harness:<harness>>）
- Tier: <non-blocking:contrived | non-blocking:normal>
- Reproduction: <最小具体构造；一个类时列出每个变体>
- Impact: <为什么声明域内没有东西能触达它——列举的调用点 file:line——以及什么改动会让它变得可触达>
- Hardening Plan: <改什么、改在哪、如何验证过，或 `none proposed`>
- Status: open

已在清单中的项用条目 id 引用，不重复。设计文档本身的非阻断发现记入评审历史文件，不在这里，也不进设计正文。 -->

## 下一轮评审输入

<!-- 下一轮（mode=incremental）要核实落地的 `blocking` 编号清单，以及各自的修复判据。非阻断发现不列在这里：它们已记入评审历史文件或遗留风险清单，不会落地；列进来只会让下一轮去核实一个从未打算发生的落地。 -->
