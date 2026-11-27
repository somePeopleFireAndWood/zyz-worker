# Changelog

All notable changes to zyz-worker are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- **execute-task 设计评审收敛修正。** 0.33.0 发布后的第一个标准档任务（一个六分册、约 200 KB 的数仓引擎设计）在设计评审上没有收敛：三个评审点前两轮的 blocking 数是主路径 24 → 16、注册表 12 → 14、切换 9 → 7，第 3 轮是用户授权加开的。发现本身是真问题（前两轮 82 条 blocking 里 75 条修复后会改变产品行为），但评审对象逐轮变大（设计文档 95 KB → 145 KB → 199 KB），新问题主要来自修订本身（第 3 轮先回来的 9 条 blocking 全部出在第 2 轮修订新写的规则里，其中至少 4 条能追到两条被落地的非阻断发现上）。两轮约 200 条非阻断发现全部进了设计正文：`design-doc-discipline.md` 写「只做记录」，`review-closure.md` 写「可以一起落地」，两处矛盾，主 agent 按后者执行。要用户定的 18 条 blocking 攒到了批准闸门，主 agent 先按推荐项改正文再送评审，有一个问题因此连续三轮被报。结论：设计文档是散文，没有编译器和测试来裁决，每轮修订新写的文字越多，下一轮能被挑出的问题就越多；要收敛，每轮新写的量要逐轮变小，单纯放宽轮次上限不解决问题。依据与契约见 `docs/design/execute-task-tiers-design.md` §11。
  - **每轮修订怎么做（所有档位）。**
    - **等级只看问题本身**：按当前设计原样实现，正常运行时会出错，就是 `blocking`，否则是非阻断；解法要不要加机制不影响等级。（「正常运行」的界线见下一条的范围规则。）
    - **设计评审的非阻断发现不进设计正文**：只记入评审历史文件，实现者确实需要的细节写进 `<task-dir>/impl-notes.md`。「随阻断修复一起落地」和「额外开一轮落地」只对实现评审成立，且以不引入新机制为前提；两个文件的说法现在一致。
    - **非阻断发现要加机制才能解决时，先重新核对等级**：「新机制」指新增表、接口、状态，或跨模块的规则。指得出走到它并出错的正常流程的改判 `blocking`，计入本轮 blocking 数；指不出或拿不准的等级不变，记入遗留清单，不在本任务内做。
    - **blocking 的修复优先做减法**：减掉的是主 agent 自己加的东西时直接做；会缩小用户要的范围时只推荐，由用户决定（A 类）。
    - **要用户定的问题，裁决完马上问；依赖回答的部分不动**：每轮裁决后用一条消息列完必须由用户定的问题（架构、关键算法、对外契约、持久化数据、用户可见行为、范围取舍），每条附推荐并写明影响设计的哪些部分，记进 `decisions.md` 新增的「等待回答的问题」，用 `expect.sh set <key> user --watch` 声明后继续。不依赖回答的修复照常做、下一轮照常开；依赖回答的部分保持原文、标为待定，派发评审时列给评审者，评审者不重复报告；用户回答后再改，改动进下一轮增量复审；剩下的修复全都依赖回答时才停下等用户。「不阻碍主路径的问题集中到批准闸门再问」的做法作废，批准闸门只列 B 类决定和仍未回答的 A 类问题。
  - **什么时候停、停下时说什么。**
    - **标准档设计评审上限从 2 轮改为 3 轮**（实现和汇总本来就是 3 轮）。
    - **第 2 轮不收敛就提前停**：标准档的每一个评审点（设计、实现、汇总），第 2 轮的 blocking 数（被接受的加被拒绝的）不为零、且不少于第 1 轮时，不开第 3 轮，先交给用户。第 2 轮一条都没报不算不收敛：两轮都没有新 blocking、只剩待定项时，用户回答后开第 3 轮复审是正常路径。
    - **停下来问用户时带诊断，选项仍是三个**：诊断包括各轮 blocking 走势、各轮修订量、本轮 blocking 的来源（原有漏报、上一轮修订带出、等用户决定）、剩余 blocking 分成结构类（要改模块划分、接口或数据模型）和细节类（某个模块内部的规则）。选项和 0.33.0 相同：再开一轮（`grant`，一次只放一轮）、接受为遗留风险、拆成加固任务。剩余问题涉及安全或数据、真实路径上的缺陷还在减少、或者修复方案已经明确时，主 agent 推荐再开一轮。严格档收口检查结论为 `escalate` 时带同样的诊断。评审阶段曾设计过第四个选项「带着进实现」（把剩余 blocking 写成实现阶段必须通过的测试项），用户在 PR 评审时决定去掉：修复方案明确时应该在设计阶段落实并增量复审，带进实现只是让实现阶段带着一份已知有缺陷的设计开工。
  - **`review-round.sh` 的改动。**
    - 上限表：`standard` 的 `design` 从 2 改为 3。
    - `result` 新增 `--induced I`（本轮 blocking 里由上一轮修订带出的条数，含只落地一半的）和 `--pending P`（这个评审点此刻仍在等用户回答的 blocking 条数，含更早轮次提出的；它是当前状态，不和本轮的 `blocking + rejected` 比大小），写入 `Review` 行的 `induced=` / `pending=` 字段。有档位的任务从第 2 轮起，`--rejected`、`--induced`、`--pending` 三个都必填，没有就写 0：`result` 是整行重填，漏写的 `--rejected` 会按 0 参与提前停的比较。
    - `start` 的提前停：生效档位是 `standard`、要开第 3 轮、第 2 轮的 `blocking + rejected` 不为零且不少于第 1 轮（即 ≥ max(第 1 轮, 1)）、且没有本轮 `grant` 时以 exit 3 拒绝；`status` 里显示 `gate=not-converging`。到上限、提前停、`escalate` 三种拒绝的输出结构相同：各轮走势、要写的诊断、三个选项各自的命令；`result` 之后下一轮开不了时当场输出同一段。
    - `start` 的修订量：design 评审点把本轮被评审的文档（`--docs <path>...`，不给时取 `status.md` 的 `- 设计文档:`）复制到 `<task-dir>/reviews/snap/<point>/r<n>/`，从第 2 轮起输出 `delta=+<增行>/-<删行> prev=… growing=yes|no`，把与上一轮的 diff 写到 `r<n-1>-r<n>.diff` 供增量复审使用，并在 `Review` 行记 `delta=`。新增行数比上一轮多时只告警、不拒绝；没有可读的文档时跳过。只比较两轮都采集到的文档：这一轮没有采集的（超过大小上限，或没有列出而源文件还在）不参与比较，输出一行 `note:` 写明是哪几份，所以同一评审点每一轮要给同一组文档。修订量只在设计阶段计量。
    - `close` 的结局不变（`passed` / `residual` / `split`）；最近一轮 `pending` 大于 0 时 `close --outcome passed` 被拒绝，`start` 不因此拒绝。
    - `status` 在每个评审点下面多显示各轮的 `blocking / rejected / induced / pending / delta`。
  - **新文件 `<task-dir>/impl-notes.md`**（模板 `skills/execute-task/templates/impl-notes.md`），只有一节「实现备注」：设计评审里实现者需要的非阻断细节，每条注明来源发现的编号。它和 `decisions.md` 一起随 lane 派发，也附给实现评审、汇总评审、跨 harness 评审和严格档的 test-agent，评审者逐条核对是否落地。它不改设计，某一条和设计冲突时 lane 停下这一块并报告主 agent。
  - **提示词与模板。** 规则各写在一处：等级、关闭条件、非阻断发现的去向、减法优先和「马上问、待定部分不动」、上限与提前停、诊断与三个选项都在 `references/review-closure.md`（§2–§8）；`SKILL.md` 的 `## 评审收口` 只留摘要，`prompts/main-agent.md` 的 `## 评审` 只写每一步的命令和派发内容。review-agent 从第 2 轮起（含 `--full` 开的全量轮）给每条新发现注明来源（`原有` 或 `上一轮修订带出`），供主 agent 填 `--induced`，并且不重复报告派发里列为「等用户决定」的点；`review-report.md` 的发现表有「来源」列，`cross-review-prompt.md` 对跨 harness 评审者提同样的要求。待定项标在 `decisions.md` 的「影响的设计部分」，不在设计正文里加批注；交付前核对 `decisions.md` 里没有仍在等回答的问题；编排模式下提前停同样走 `ZYZ_QUESTION_FILE` 问答。
  - **测试。** `scripts/test-review-round.sh` 新增 L 节，覆盖提前停、`--rejected` / `--induced` / `--pending`、快照与修订量、旧格式的行。`task-status.md` 里的示例行交给真实的 `review-round.sh status` 解析。被有意删除的说法（标准档 design 2 轮、评审阶段去掉的「带着进实现」和 `carried`）有反向守卫。提示词的措辞锚点见下一条。
  - **对旧任务的兼容。** 没有 `- Tier:` 的旧任务对新增的检查一律 fail open：不设上限、不提前停，`result` 不要求 `--rejected` / `--induced` / `--pending`。没有 `induced=` / `pending=` / `delta=` 字段的旧 `Review` 行照常解析，值按 `-`。上限放宽和提前停只针对标准档，其余规则对严格档同样适用。进行中的标准档任务升级后，设计评审点的上限变成 3 轮；每个评审点第 2 轮起的 `result` 要写全 `--rejected`、`--induced`、`--pending`（0.33.0 里 `--rejected` 可以不写，现在缺了会以 exit 2 拒绝）。
  - **最终评审**（独立 review agent + Codex 跨 harness）第 1 轮的 3 条 blocking 都接受并已修正，上面各条写的是修正后的规则：`impl-notes.md` 原来只发给 lane、到不了实现评审；提示词里提前停的三处短写法漏了「第 2 轮为零不算」的例外；文档跨过快照大小上限后被当成整份删除，写进修订量和交给增量复审的 diff。遗留到后续加固的项记在设计文档 §11.7 第 8 条。
  - 文档同步：`README.md`、`docs/architecture.md`（主线流程、设计决策 h、测试套件表、成对修改清单）、`hooks/README.md`、`docs/design/watchdog-design.md`、`docs/design/execute-task-skill-design.md`。
- **execute-task 提示词精简与范围规则。** 依据：同一个标准档任务里，对账归类规则在第 2、3、4 轮每一轮都出 blocking，每次都是换一种判据后露出新的边界；用户叫停这块设计（对不上时当场让 agent 查数据）之后，同一分册的 blocking 从 6 条变成 1 条。用户的观察是 agent 倾向给自己出难题、追求完备、想在程序运行之前穷举所有出错情况，评审里倾向把对抗性问题升级；提示词里「怎么找问题、怎么修、怎么验证」的规则在助长这一点。用户的决定：提示词只留流程约束、任务与完成条件、本环境的事实，「怎么干活」全部删掉，不迁移到别处。契约见 `docs/design/execute-task-tiers-design.md` §12。
  - **范围规则。** `SKILL.md` 和三个角色提示词新增逐字相同的 `## 范围` 一节：第一次把一件事做出来时只管正常运行。对每一种情况问两个问题：所有人都按预期使用和操作时它会发生吗——会的在范围内（主流程，以及并发、重试、超时、重启、依赖失败、空数据和边界值），要有人做错、有人恶意、或几个互不相关的罕见故障同时出现才会发生的不在范围内，不去找，也不为它设计、写测试或提发现（设计的范围边界写明有对手的地方除外）；它出错时会不会悄悄造成难以挽回的后果——会的事先设计，出错看得见、当场能查的，设计里写一句「发生时谁、看什么数据来判断」就算完整。顺手看到的范围外情形只记一行，留给之后专门的对抗任务。
  - **评审者的任务。** 设计文档新增 `## 场景`（主流程加正常运行会遇到的条件，每条写期望行为）和 `## 发生时再查`。设计评审拿每一条场景走一遍设计，报告走不通的地方；实现评审拿每一条场景走一遍代码和测试，并报告实现与已批准设计不一致的地方。评审者不回答「还有什么可能出错」。快速档用 `change-note.md` 的「怎么验证」充当场景清单。
  - **等级。** 字面量不变。`blocking`：报告者指得出一条正常流程走到它并出错，或者实现违背已批准的设计；举证在报告者一侧，写不出那条流程和出错那一步的不是 `blocking`。`non-blocking:normal`：范围内、不会出错的改进。`non-blocking:contrived`：范围外。0.33.0 的「可达性拿不准按 blocking」「升级总是允许、降级要举证」「列举所有调用方才能定为 contrived」作废。设计里没写的 B 类细节不是发现。
  - **删除的规则。** 变异（清单、执行、备份协议、档位表里的变异行、`Tested: true` 的变异条件）、八种空转断言清单、互补面变异、独立复现、覆盖维度登记、「不对移动的目标签字」的哈希流程、断言形态规则、测试失败归因顺序、止损规则、最薄弱环节自述、裁决纪律四条、发现台账的六列格式、声明域推导与调用方兜底、反复出现类别的类级修复规则、设计文档编辑纪律的细则、遗留风险条目的六个字段。`Tested: true` 现在的条件是测试通过且负对照有记录。实现的完成条件：构建和测试通过；新测试在改动前的代码上失败；`## 场景` 每一条有对应的测试；标准档和严格档覆盖测试计划的单元 / 回归 / e2e。
  - **保留的流程。** 档位与升降档、A / B 类决定与设计批准闸门、总目标不收窄、状态文件布局、lane 模型与资源租约、评审点与轮次（首轮全量之后增量、每轮重新派发、派发标记、上限、提前停、三个选项、严格档收口检查）、上一条的修订规则、跨 harness、watchdog 义务与声明、版本控制禁令、恢复时不拿范围换交付、编排模式契约、交付核验与 `awaiting-confirmation` / `done`。`## 关键机制` 在任何档位都可以填，用途是给用户审查；严格档里这些机制的测试由 test-agent 写。
  - **文件与体积（字节）。** `SKILL.md` 25,550 → 12,260（上限 12,288）；`prompts/main-agent.md` 30,396 → 10,188（10,240）；`references/review-closure.md` 29,274 → 8,095（8,192）；`design-doc-discipline.md` 8,591 → 2,856、`cross-harness.md` 7,860 → 2,925、`recovery.md` 8,338 → 2,715、`version-control.md` 4,094 → 2,175（各 3,072）；`pr-review.md` 2,578 → 1,116；`review-agent.md` 15,250 → 5,471（6,144）；`implementation-agent.md` 12,272 → 4,738、`test-agent.md` 11,411 → 4,243（各 5,120）；`templates/task-status.md` 12,564 → 3,859（5,120）；`review-report.md` 8,671 → 2,227、`design-doc.md` 5,706 → 1,851、`cross-review-prompt.md` 6,449 → 2,146（各 3,072）。`references/watchdog.md` 和 `orchestration-mode.md` 是机制和协议说明，没有改写。`SKILL.md` 去掉了 `## 自动执行策略`、`## 总目标忠实度`、`## 增量输出`、`## 评审历史文件`、`## 设计文档编辑纪律` 五个标题，内容并进 `## 核心规则`、`## 用户设计主导权` 和 `references/design-doc-discipline.md`；`## 工作流` 的 §1–§4 编号不变。`references/review-closure.md` 重新编号为 §1 评审点、§2 轮次与模式、§3 等级、§4 关闭、§5 非阻断发现、§6 修复与等用户、§7 上限与提前停、§8 严格档收口检查、§9 遗留清单、§10 命令。设计文档模板只保留被后续流程用到的小节；遗留清单 `residual-risks.md` 改成两节、每条一行（`## 后续对抗任务`、`## 接受的遗留问题`）。
  - **测试。** 提示词测试只守四样：脚本解析或输出的字面量、`## 范围` 一节四处逐字相同、体积上限、每条保留规则一个短锚点。原有的措辞锚点随被删除的文字一起删除。hook 和脚本的行为测试没有动。
  - **对进行中任务的影响。** 脚本和 hook 没有改，状态文件里被解析的小节和字段不变。按旧模板建的 `status.md` 和 `residual-risks.md` 仍可使用。按旧模板写的设计文档没有 `## 场景` 一节，而评审者和 lane 现在都按它逐条走：进行中的任务在下一次派发评审或 lane 之前由主 agent 补上这一节。

## [0.33.0] — 2026-11-26

- **execute-task 分档与评审收敛改造。** 复盘（两个重型任务的 517 条 blocking 发现，以及一批本应是中短程的任务）显示：评审循环占重型任务活跃时间的 48%–60%；32% 的 blocking 修复没有改变产品行为（测试强度 13%、文档同步 9%、证据流程 8%）；实现阶段的真缺陷第 1 轮 58 条、第 2 轮 17 条、第 3 轮及以后 4 条；收口检查 6 个该做的点只做了 1 个，有一次设计评审跑到 14 轮才被用户叫停；同量级小改动（生产代码 ≤150 行）直接开发中位约 28 分钟，走 execute-task 中位约 144 分钟。根因是停止条件为「对抗性评审者再也找不出问题」这种无界搜索、blocking 准入太宽、每轮全量复审、评审强度不随风险变化，以及能机械检查的规则只写在提示词里。设计依据与落地契约见 `docs/design/execute-task-tiers-design.md`（§10 为契约）。
  - **三个档位。** `/execute-task --fast|--standard|--strict <任务>`；自然语言「快速档 / 标准档 / 严格档」等同；都没给时主 agent 在第一条回复里提议一个档位并附一句理由。档位记在 `status.md` 中 `- Current Phase:` 下一行的 `- Tier:`，只经 `review-round.sh tier … --reason …` 写入并追加 `log/tier.md`。主 agent 可以提议升档（整个任务，或用 `open <point> --tier …` 只升某个评审点），降档只由用户决定（`--by user`）。快速档：一条消息加 `change-note.md` 代替设计文档，用户确认改法即可；主 agent 可以直接改单 lane 的小改动；测试要负对照（新测试在旧代码上失败），不设变异门；1 轮独立评审，最多再 1 轮复核。标准档：设计文档 + 快速审阅，变异只对设计 `## 关键机制` 列出的机制。严格档：保持现行全套要求，不设轮次上限。「止血 + 恢复功能」类任务先交付止血，恢复功能另开任务。
  - **评审收口 v2。**
    - **合同先行**：已批准的设计（快速档是 `change-note.md`）连同验收标准、测试计划和声明域就是合同，评审只判是否违反合同、以及在可达输入下能否复现缺陷。
    - **blocking 只有三类**：可达的产品缺陷（实现评审要附失败的测试、具体输入或调用路径 `file:line`）、设计缺失或矛盾（指明章节）、违反合同（含实现违背已批准设计）。测试强度降为 `non-blocking:normal`（合同点名要求的测试缺失除外）；快速审阅漂移、引用不同步等文档同步问题不进评审，由主 agent 在设计批准前机械地重新生成；可达性拿不准时按 blocking，但「拿不准」不能给证据缺口升级。
    - **补证请求**：缺坐标、缺变异记录、维度没登记、冻结或哈希问题，由作者补上、裁决者核对，不开新的一轮，也不计入 blocking 数。
    - **评审点拆开、首轮全量之后增量**：主路径、每个附属子功能、汇总评审各一个评审点，各自计轮次。第 2 轮起评审者只逐条核实上一轮被接受的 blocking 已落地，并评审修复 diff 是否引入新问题；结构性修复后用 `start --full --reason …` 改走全量。增量复审不算缩范围，L5 对经核实的增量轮放行；「恢复卡住的角色时缩范围」仍然禁止。
    - **上限与交用户**：同一评审点的总轮数上限，快速档 design 0 / impl 2 / aggregate 1，标准档 2 / 3 / 3。到上限时不悄悄关闭、也不自动继续，主 agent 用一条消息交给用户剩余 blocking 及其可达性和影响，并推荐三选一：再开一轮（`grant`，一次只放一轮）、接受为遗留风险（`close --outcome residual --by user`）、拆成加固任务（`close --outcome split --by user`）。评审点关闭用 `close --outcome passed`（要求最近一轮 `blocking=0`），交付核验要求每个登记过的评审点都有 `Review-Close`。
    - **严格档**：不设上限，保留主要问题 vs 极端构造的分级；从第 3 轮起每满 3 轮做一次收口检查，开第 4、7、10… 轮前缺 `check` 记录会被拒绝；结论为 `escalate` 时交用户，用户同意继续后用 `grant` 放行下一轮。
    - **跨 harness 时机**：设计评审每一轮、实现第 1 轮与 `--full` 轮、汇总第 1 轮；实现的增量轮取消（复盘：实现第 1 轮跨 harness 独有的真缺陷 39 条，第 2 轮起只有 3 条）。
  - **用户设计主导权 v2。** 决定分两类：A 类设计决定（架构、模块划分、关键算法、对外接口契约、持久化数据结构、用户可见行为）仍经用户批准；B 类可逆的实现细节（内部命名、配置默认值、内部函数拆分、日志措辞、依赖小版本等）按推荐执行，批量记入新模板 `decisions.md` 的「按推荐执行的决定」，在设计批准时和最终报告里列给用户，用户可以否决任何一条；拿不准时按 A 处理。提问一次停下只发一条消息，问题编号列出、每条附推荐，用户答「全部按建议」即逐条采纳。实现中发现偏离按 `prompts/main-agent.md` `### 实现中发现偏离` 的三行决策表处理（这条规则只写在那里）：B 类照常做并记一笔；实现偏离了设计而设计没错，就改回设计；设计本身行不通，才停下这一块交给用户，其它 lane 继续。设计批准前，用户没有亲口说过的范围边界条款（首先是威胁模型）列进 `### 需要你关注的细节`；涉及安全或数据的改动缺少声明域时算 blocking 的设计缺失，并标 `requires-user-decision`。
  - **并行模型。** 并行的单位是端到端的 lane（一个功能、PR 或模块：文件白名单、自己的 worktree 或划定的插入区域、自己的测试资源租约），lane 内部完成实现、测试和自验证，只做到本地提交。快速档和标准档由 implementation-agent 的 lane 模式同时写代码和测试，「作者不当自己的裁判」由独立评审（兼查断言形态）保证；严格档的关键机制仍由 test-agent 写测试、负对照和变异清单，implementation-agent 执行。两种模板：契约骨架 + 按文件扇出，或一个 PR 一个 lane 一个 worktree（用 `git-worktree` skill 建，不用 `isolation: worktree`）。解锁条件从「上游已评审」改为「接口已冻结」；评审和实现流水线并行；lane 用具名 teammate 常驻，修复轮经 SendMessage 回到原 lane；并行 lane ≥ 4 时设集成 lane。lane 报告写到 `<task-dir>/lanes/<id>.md`，消息里只传路径。
  - **提示词与状态文件瘦身。** 常驻上下文的 `SKILL.md` 121,332 → 24,998 字节，`prompts/main-agent.md` 57,857 → 30,044 字节（两者合计 -69%），两者之间的重复全部去掉；专题细则移到按需加载的 `skills/execute-task/references/`（`review-closure.md`、`cross-harness.md`、`design-doc-discipline.md`、`watchdog.md`、`recovery.md`、`version-control.md`、`pr-review.md`、`orchestration-mode.md`，共约 81 KB），编排模式契约逐条原样保留。角色提示词按档位分节：`review-agent.md` 25,026 → 15,035，`implementation-agent.md` 19,535 → 12,156，`test-agent.md` 17,194 → 11,113 字节；review-agent 的「八种空转断言逐条作答」只在严格档或关键机制上要求，快速档用 4 项短清单，并新增 `## 派发标记与评审模式`。`templates/task-status.md` 16,949 → 11,358 字节，只放当前状态（新增 `- Tier:`、`## 评审收口`，`## 发现台账` 合并了原来的实现评审、跨 harness 和 PR 评审记录）；用户决策移到 `decisions.md`，重启记录、档位变更、已关闭的发现移到 `log/`。新模板 `change-note.md`、`decisions.md`；`design-doc.md` 新增 `## 评审点划分` 与 `## 关键机制`；`review-report.md` 新增派发标记与档位回显、`## 修复落地核实`、`## 补证请求`。去掉了加重语气的「绝不 / 必须」，硬约束改写成条件和动作。
  - **新脚本与新 hook。**
    - `hooks/scripts/review-round.sh`（实现在 `review_round.py`）：`open` / `start [--full]` / `result` / `grant` / `check` / `close` / `tier` / `status`，校验后原子写入 `status.md` 的 `## 评审收口`（`- Review:` / `- Review-Grant:` / `- Review-Check:` / `- Review-Close:` 行，与 `expect.sh` 共用同一把锁），主 agent 不手写这些行。`start` 在上一轮没 `result`、超过上限且没有授权、严格档缺收口检查、最近一次检查为 `escalate` 且没有授权、或评审点已关闭时以 exit 3 拒绝，并在 stdout 写明下一步；成功时输出 `round=<n> mode=full|incremental cross-harness=yes|no`。
    - `hooks/scripts/review-gate.sh`（PreToolUse，与 L5 同组，Claude Code 与 Codex 的派发工具都覆盖）：本会话有带有效 `Tier:` 的任务时，派发 review-agent 的 prompt 要有一行与最新一轮一致的 `review-point=<id> round=<n> mode=<full|incremental>`，并单独一行 `Tier: <评审点的生效档位>`，否则拒绝并写明要先运行的命令，拒绝记入 `runtime/review-gate.log`。`ZYZ_REVIEW_GATE_DISABLE=1` 只关这一个闸门。
    - L5（`dispatch-scope-guard.sh`）：派发给 review-agent、且 `mode=incremental` 标记经 `review-round.sh` 核实（n ≥ 2、最新一轮、不是 `--full` 轮）时放行；其余缩范围检测不变。
    - `scripts/cross-review.sh run` 新增 `--point <id> --round <n> --mode <full|incremental>`：impl 评审点的增量轮直接输出 `status=skipped reason=incremental-round`，`ZYZ_CROSS_REVIEW_FORCE=1` 时照常运行；tree-stable 指纹除 `.zyz-worker/` 外还排除任务目录，评审期间写 `status.md` 不再被误判为评审对象变了；顺带修了标志后缺值时的死循环。
    - 新增 `scripts/test-review-round.sh`（309 项）；`test-cross-review.sh` 增补增量跳过、强制全量、重开与指纹用例；两个套件共约 49 个定向变异全部被杀，记录在各自头部。既有套件里因规则迁移到 `references/` 而失效的提示词锚点改指向规则现在所在的文件；被有意删除的规则（review-agent 核对快速审阅与正文的一致性、「无论任务大小都先写设计文档」）改成反向守卫；新增一组 tiers 锚点，钉住派发标记、`Tier:` 行、`result` 先于 `start`、`escalate` 后 `grant`、`close` 的用户出口等提示词表述。
  - **最终评审（独立 review agent + Codex 跨 harness，第 1 轮 8 条 blocking 全部修复，第 2 轮增量复审 no-changes-needed）带来的修正：**被拒绝的 blocking 由下一轮评审者复核（`result --blocking N --rejected R`，`close --outcome passed` 要求两者都为 0）；review-gate 只放行尚未 `result` 的一轮；每一轮评审都重新派发 review-agent，不用 SendMessage 续用；严格档收口检查只认刚完成的一组三轮、`escalate` 在任何轮次都挡住下一轮；重开已关闭的评审点保留单点档位、降档一律要 `--by user`；aggregate 只有第 1 轮跑跨 harness；严格档非关键机制的变异由作者 lane 自写自执行；编排模式下档位写进第一份确认问题，lane 分支并回 worker 的任务分支、不直接合 base。遗留的极端构造与纵深防御项记在设计文档 §10.8 第 10 条。
  - **对旧任务的兼容。** `status.md` 没有 `- Tier:` 行（或为空、只是模板占位）时一律按旧任务处理：`review-round.sh start` 不设上限、不要求收口检查、照常记录，`review-gate.sh` 放行，提示词按严格档的旧行为执行，review-agent 缺档位时按 `strict` 评审——即 fail open，进行中的任务不需要迁移。
  - 文档同步：`README.md`、`CLAUDE.md`、`docs/architecture.md`（角色表、主线流程、新增设计决策 h、L5 层、逃生开关、测试套件表新增 `test-review-round.sh`、成对修改清单）、`docs/design/watchdog-design.md`（§3 新增评审账本、§5 新增派发范围守卫与评审轮次闸门两行及「上限与收口检查不是告警」的说明、§9 新增派发闸门规则）、`hooks/README.md`、`docs/design/execute-task-skill-design.md`（标出被新设计取代的部分）、`docs/conventions/long-running-state.md`，以及编排 skill 里指向已删除章节的引用。
- **没有 arm 的会话不再收到任何 watchdog 告警。** 一个会话「哪个任务属于我」只由会话身份决定，但 0.32.1 之前还有两条路违反这一点，都已在当前代码上复现：
  - **回落读共享的 `current-task`。** 有会话 id、却没有自己会话指针的会话（也就是没在这里跑过 execute-task 的普通会话），解析器会回落读目录里的 `.zyz-worker/current-task`，挂到它指向的任务上：L1 注入「状态文件过期」、L4 拦下 Stop（状态过期 + 无执行者）、L3 报状态过期和会话静默、再升级成 IM，还会往那个任务的 `runtime/` 里写心跳。真实事故（11-04 tipsy-ab-config）：一个从没调用 execute-task 的会话收到 5 次 watchdog 通知，其中一次把另一个会话的任务误判为卡住，用户最后让它把 watchdog 关掉。这个目录现在仍留着 0.28.0 之前写的 `current-task`，其它几个仓库也有（其中一个指向一个今天还在推进的任务）。现在 `current-task` **只在拿不到任何会话 id 时**才读——也只有这时 `task-pointer.sh arm` 才会写它；`$ZYZ_TASK_DIR`（按进程导出）照旧有效。**迁移：** 仍靠 `current-task` 启用的旧会话需要用 `task-pointer.sh arm <任务目录>` 重新 arm 一次；`task-pointer.sh show` 会用一行 `ignored:` 标出被忽略的 `current-task`。
  - **L3 的「未启用」按目录猜。** 只要会话 cwd 下有一个未完成、且没有被任何会话指针认领的任务目录，watchdog 就对本会话报一次「未启用」。monitor 随每个会话启动，所以在留有废弃任务的仓库里打开的每个普通会话都会收到。已删除：没有 arm 的会话里 watchdog 完全安静。「没 arm」的提醒改到 L1，证据只取本会话自己的动作：主 agent 自己用 Write / Edit / MultiEdit 修改某个未结束任务的 `.zyz-worker/tasks/<id>/status.md`，而且距它第一次这样改已过 `ZYZ_UNARMED_GRACE_SEC`（默认 300 秒，正常启动时 status.md 先写、几秒后才 arm）仍解析不到本会话的指针，才注入一次提示（每个会话每个任务一次），并说明任务若属于别的会话就忽略、不要替它 arm。subagent 的写入、Bash / Read 调用、目录里的任务和别的会话的指针都不算证据。Codex 的文件编辑不经过这个 hook，所以 Codex 上没有这条提示（只会少报）。
  - 已 arm 的会话不受影响：同一目录里的正对照（Stop 拦截、watchdog 报告、IM）照常触发。
- **空闲的 agent-team teammate 不再算执行者（补上 issue #24 的 11-17 漏报）。** 回放 11-17 事故（f0b8d80a）发现：主 agent 22:22 停下时宿主列着 12 个 teammate 和 st4-impl 起的两个后台 shell，「无执行者」把它们都算成执行者；shell 22:25 结束后完成通知排在空闲的 st4-impl 队列里没人处理，用户 22:53 才发现，插件最早要到 23:23 才由「会话静默」报出。在 Claude Code 2.1.251 的交互会话里实测（hook 载荷存成 `scripts/fixtures/teammate-live-2.1.251.jsonl`）：teammate 不论忙闲都以 `running` 列出；空闲的 teammate **不会**被它自己起的后台任务结束叫醒；它的 hook 带 `agent_id = a<名字>-<hex>`、`agent_type = 名字`；每开始一轮（派发、被 SendMessage 叫醒）触发 `SubagentStart`，每结束一轮触发 `TeammateIdle {teammate_name}`；列表里 teammate 条目的描述是派发 prompt 的前 50 个 UTF-16 单元加 `...`。
  - 新 hook `hooks/scripts/teammate-track.sh`（`PostToolUse` 派发、`SubagentStart` `*`、`TeammateIdle`）和 `heartbeat.sh` 一起记下每个 teammate 这一轮是否结束、它的描述、它起了哪些后台任务（Bash `backgroundTaskId`、Monitor `taskId`），存在主任务的 `runtime/teammates/` 下。
  - L4 停止门和 design 阶段的 `needs_input` 兜底扣除空闲的 teammate 及其后台任务；描述对不上、或多个 teammate 描述相同且有一个在忙时照旧算执行者，插件没见过的 teammate 也照旧算（只会漏报，由会话静默兜底）。快照的 id 字段不变，`wait --ref` 不受影响。
  - L3：Stop 时在忙、之后结束这一轮并空闲满 `no-executor-sec` 的 teammate 也从快照计数里扣除（`runtime/stop-teammates`）——它的空闲通知没送到主 agent 时由 watchdog 叫醒。
  - 按 11-17 的形态回放：带上 hooks 会写的记录，22:22 那次 Stop 当场被拦，并点名未提交的 ST4（0.32.1 放行）；没有记录的团队仍在 61 分钟时由会话静默报出。
  - **顺带修正：** jq 不接受孤立的 UTF-16 代理转义（`"\ud83d"`），而宿主截断到半个 emoji 时就会输出它（teammate 的 prompt 前 50 个单元正好截在 emoji 中间）。这时 `zyz_get` 读每个字段都是空，整个 hook 静默放行。现在 jq 解析失败时退回 python3。
- 测试：`scripts/test-session-pointer.sh` 新增 S9（一个从未 arm 的会话，在另一个会话的任务、一个无人认领的进行中任务和一个残留 `current-task` 旁边，驱动全部 hook、watchdog 和 IM，断言什么都不输出、什么都不写、谁都不通知，并在同一目录做正对照）和 S10（新的「未启用」提示的正例与 9 种反例），S1 / S4 / S5 改为新契约（106 项）；`scripts/test-watchdog-hooks.sh` T11 改为「没 arm 的 watchdog 在任何目录形态下都安静」；`scripts/test-session-silence.sh` 新增 R2 回放（124 项）；新增 `scripts/test-idle-teammates.sh`（51 项：实测载荷回放、描述映射含 UTF-16 截断与重名、后台任务归属、L3 事后扣除、design 阶段 IM 兜底、hooks.json 接线；19 个定向变异，见套件头部）。13 个定向变异中 12 个被杀，1 个是等价变异（文件名检查被其它守卫兜住），第一轮存活的 H6 暴露出反例只改一次、而第一次修改本来就不提示，已改成两次修改；记录在 `test-session-pointer.sh` 头部。`test-session-silence.sh` 的 I3 和 `test-codex-adaptation.sh --real` 原先依赖「有会话 id 也读 `current-task`」，分别改为写会话指针和导出 `$ZYZ_TASK_DIR`。
- **后台任务通知不再被当成用户发言；teammate 的结果只送一次。** 复盘（11-09～11-12，tipsy-ab-config，CC 2.1.251）：主 agent 一共收到 74 轮、80 条 teammate 消息，其中 40 条是 teammate 主动用 SendMessage 发来的报告，另外 40 条是宿主自动发的 idle 通知（`result` 就是 teammate 这一轮的最终文本，超过约 4000 字会被截断）。teammate 在同一轮里先用 SendMessage 发报告，再把同样的内容写成最终消息，主 agent 于是收到两份，其中至少 18 次专门回复「这条是重复的，没有新内容」。插件的 hook 在这些 teammate 里一次都没有注入过：L1 跳过非三种角色名的 `agent_type`，L2 的 matcher 也匹配不上按 `name` 派发的 teammate。所以重复本身是平台行为，这里只做提示词层的缓解。
  - **`main-state.sh`：`<task-notification>` 轮次不写 `runtime/user-prompt-epoch`。** 调查中实测：宿主把后台任务通知（后台 subagent / Bash 结束、monitor 的一行输出，watchdog 自己的唤醒也在内）作为一轮送给主 agent 时，也会触发 `UserPromptSubmit`；teammate 消息则不会触发。之前每一条这样的通知都被记成「用户刚发过言」，造成两个后果：`user` 声明提前失效，下一次 Stop 被「无执行者」拦下，主 agent 只好重新声明，用户又收到一条 IM；延迟 60 秒的提问 IM 只要这期间来一条通知就被丢掉。这类轮次照常记 `working`、照常删除 stop-snapshot，只是不再算作用户发言。测试见 `scripts/test-no-executor.sh` N4h–N4k，套件头部记录了变异测试。
  - **提示词：用 `name` 派发 teammate 时，结果只送一次。** `prompts/main-agent.md` 要求在派发里写明以下几点：完整报告写进报告文件；最终消息就是汇报，只写结论和路径；不要再用 SendMessage 重发同样的内容；SendMessage 只用来在本轮中途提出需要主 agent 答复的问题或阻塞。主 agent 收到只是重复内容的 idle 通知时，不回复，也不向用户复述。
- **跨 harness 评审：超时加下限，超时给出诊断。** 实战（11-15）：主 agent 跑在 Codex 时，自己用 `ZYZ_CROSS_REVIEW_TIMEOUT=180`（一次 300）调用 `cross-review.sh`，5 次 Claude 评审全部 `status=timeout rc=143`，报告只有 0–69 字节（其中一份全文是「Now GetPublic in full.」）。评审者其实没卡住：stderr 为空，事件流 340–900 KB，每次 17–46 次工具调用，被杀时还在读代码；rc=143 是脚本自己的超时发出的 SIGTERM，Codex 的 `exec_command`（`yield_time_ms=1000`）并没有杀它。400 次真实 Codex 评审中只有 9 次在 180 秒内、38 次在 300 秒内跑完，中位数 567 秒。Claude 宿主一侧从未调小过超时（都用 2400 以上），所以没出过问题。
  - `ZYZ_CROSS_REVIEW_TIMEOUT` 低于下限 1200 秒（400 次中 97% 在此之内跑完）时提升到 1200，在 stderr 告警，并在 `.meta` 记 `timeout=` / `timeout-requested=` / `timeout-raised=yes`。默认值 2400 不变。下限可用 `ZYZ_CROSS_REVIEW_TIMEOUT_FLOOR` 调整，只供测试套件使用。
  - 超时的摘要行新增 `diagnosis=<still-working|stalled|no-output> timeout=<秒>`，`.meta` 新增 `timeout-diagnosis`、`last-output-age`、`log-bytes`、`report-partial`。判据是被杀前事件流最后一次增长的时间：`still-working` 表示超时设短了；`stalled` 表示事件流已安静 `ZYZ_CROSS_REVIEW_STALL_SEC`（默认 300）秒，评审者挂死；`no-output` 表示评审者从未写出任何事件。超时时抓到的旁白仍保留在报告文件里，标为部分输出。
  - 提示词：`SKILL.md` `## 跨 harness 交叉评审` 补充：不要为了让评审者赶上 reviewAgent 而调小超时，以及 `diagnosis=` 字段的含义。README 的调节项表同步更新。
  - `scripts/test-cross-review.sh` 新增 29 项（共 92 项），覆盖下限、按测试比例回放这次事故，以及三种诊断。9 个定向变异全部被检出，记录在套件头部。

## [0.32.1] — 2026-11-23

- **提示词：向用户提问一律用自然语言，不使用 AskUserQuestion 工具。** 即使工具可用、即使是让用户在几个选项里做选择（把选项编号列在回复里），也用自然语言提问，并照旧在同一条回复里、结束这一轮之前 `expect.sh set <key> user`。主 agent 提示词删除了「用 AskUserQuestion 提问什么都不用做、做选择时优先用它」一条；`SKILL.md` 的 L7 IM 通知说明和声明用法表同步改写。watchdog 对 AskUserQuestion 的处理（`awaiting-user`、延迟 `needs_input` IM、回答记为用户发言）保留不变，作为工具仍被调用时的兜底。

## [0.32.0] — 2026-11-19

- **watchdog 新增两条与平台、角色类型无关的底线：会话静默与 API 错误中断。** 真实事故（11-19，macOS）：一个评审 teammate 04:14 因上游 402 中断，宿主后台任务列表里还挂着 16 条，整个会话 6.5 小时没有任何工具调用，直到用户早上回来。没有一层发声：macOS 上 fixed-pack 不可用，逐角色检查全部停用；用 `name` 派发的 teammate，`agent_type` 是它的名字，匹配不上三种角色名的 matcher，即使在 Linux 上也不被跟踪；「无执行者」只信 Stop 时宿主列出的 16 条；「状态过期」在主 agent 停下后被 `idle` 静音。宿主其实在 04:14 触发了 StopFailure，但插件只用它发了一条 IM。
  - **会话静默。** `heartbeat.sh` 在主 agent、subagent、teammate 的每次工具调用时写 `runtime/activity`。活跃任务还有活、整个会话 `silence-sec`（默认 1 小时，`ZYZ_WATCHDOG_SILENCE_SEC`；静默多久叫醒、之后多久再叫由主 agent 用 `tune silence-sec= remind-sec=` 自己定，各最多 24 小时）没有任何工具调用、用户没有发言、状态文件也没写，又没有有效的 `wait` / `user` 声明或打开着的对话框时，L3 叫醒主 agent，之后每 `remind-sec` 最多一次。上次 Stop 时宿主排着唤醒（ScheduleWakeup / CronCreate / loop）的，在 `silence-sec` 之后再宽限 1 小时。它不看宿主后台任务列表、不看 `idle`，与「无执行者」共用同一组压制，无执行者条件成立时（含冷却中）不报。
  - **API 错误中断。** 新 hook `hooks/scripts/api-failure.sh`（StopFailure）把每次因 API 错误结束的一轮落成 `runtime/api-failures/` 下的一条记录。L3 扫描本会话所有任务下的记录，把 subagent / teammate 的记录合并成一行告诉主 agent（谁、几点、什么错误、先核实是否已处理过），每条只报一次；格式不对的记录只归档；超过 7 天的记录被清理；冷却（`ZYZ_WATCHDOG_FAILURE_COOLDOWN_SEC`，默认 600 秒）内的新记录留到下次合并，持续的上游错误不会变成「重派 → 又死 → 立刻叫醒」的快速循环。主 agent 自己那一轮的失败不单独叫醒（持续错误时会以轮询间隔反复失败），由会话静默按 `remind-sec` 的节奏带出；它同时把 main-state 记为 `idle`（这一轮已结束）。
  - **IM 只在需要人的时候发。** 过去主 agent 每次停下都发一条 `idle`，watchdog 的每条发现也同时发 IM，于是 subagent 走一步、主 agent 收到结果正常推进，用户也会被打扰。现在任务还在执行时一律不发 IM，由 watchdog 叫醒主 agent；只在这几种时刻通知用户：
    - **在问你**（`needs_input`）：权限确认 / elicitation；主 agent 调用 AskUserQuestion；主 agent 用自然语言提问后 `expect.sh set <key> user`。提问类延迟 60 秒（`ZYZ_NOTIFY_ASK_DELAY_SEC`），期间用户已回答就不发。兜底：主 agent 在 design 阶段停下、宿主报告没有执行者、也没有 `user` 声明（多半停在设计批准闸门却忘了声明）。
    - **交给你了**（`completed`）：任务进入 `awaiting-confirmation` / `observing` / 终态，每次进入只发一次。
    - **主 agent 处理不了**：主 agent 自己这一轮因 API 错误中断（`failed`；subagent 的失败不再发，由 watchdog 告诉主 agent）；或 watchdog 叫醒主 agent 至少 `ZYZ_WATCHDOG_ESCALATE_SEC`（默认 600）秒后再报时，会话里仍没有任何动作（`stuck`，升级，同一段停摆每个任务一次，取代原来散落各处的「第 3、5 次」「第 1、3、5 次」计数）。
    - 新声明参数 `expect.sh set <key> user --watch`（行内 `watch=yes`）：有问题要问用户、但还有能独立推进的活——发 IM，但什么都不压，watchdog 照常监控。
    - `idle` 类别删除（配置里写了也不会发）；`idle_prompt` / `agent_completed` 通知不再发 IM。
    - **每条 IM 带会话名称**：标题前缀 `【<会话名>】`，以及新字段 `ZYZ_NOTIFY_SESSION_NAME` / `session_name`。Claude Code 取 `/rename` 的名字，没有就取 AI 标题，再没有就取会话注册表名；Codex 取线程名。随 `include_message` 关闭，关闭时改用会话 id 前 8 位。
    - 所有测试套件都把 `ZYZ_NOTIFY_CONFIG` 指向不存在的文件，原先有两个套件中途 `unset` 它、会退回读取用户真实的 `~/.zyz-worker/notify.json`。
  - **修正 main-state 的语义冲突。** `awaiting-user` 现在只表示「一个用户对话框正打开着」：`idle_prompt`（「停下约一分钟、用户没有操作」，不是对话框）记 `idle` 而不是 `awaiting-user`；Stop 一律记 `idle`，删除了「已有 awaiting-user 时 Stop 不覆盖」的豁免（它会在权限被拒后留下一个过期的「对话框开着」）及只服务于它的 `zyz_main_state_awaiting`。状态过期的压制不受影响（`idle` 与 `awaiting-user` 同样压制）。`awaiting-user` 行记下对话框的归属者（主 agent，或通知带 `agent_id` 的 subagent / teammate），只有归属者自己的下一步才关闭它：subagent 的权限确认被批准后它的下一次工具调用就关闭对话框，所以不会让会话永久静音；后台角色照常干活也不会把主 agent 正打开着的 AskUserQuestion 误判为已关闭。主 agent 回答完 AskUserQuestion 记为用户发言，`user` 声明随之失效。
  - **设计文档。** 新增 `docs/design/watchdog-design.md`，写下长期方向「agent 主导，插件做工具与保障者」：判断任务为什么安静的权交给主 agent（阶段 + 声明），插件提供工具，并作为监测者与保障者观察事实、守住不变量；允许误报，但每条告警都必须写明怎么确认、怎么用声明清掉；新的正当安静场景先扩展声明，不加硬编码豁免。文中给出告警目录（触发、压制、清除办法、重复节奏）、平台能力矩阵，以及对 0.25～0.31 累积机制的冲突与重复梳理：旧格式 `Waiting On` 的独立严格校验器是已知重复，冻结不再扩展，待老任务目录不再需要时删除。
  - 提示词：`SKILL.md` `## Watchdog 强制层`、主 agent 提示词新增对两条新告警的处理方式（核实通道、续做重派、正当等待要声明、同一 API 错误反复出现时先告诉用户再 `wait`）；声明用法表新增「在等一个长时间不调用工具的东西」一行。`docs/architecture.md`、`hooks/README.md`、`README.md`、状态模板同步；架构文档的测试套件表补齐了此前漏列的 5 个 watchdog 套件。
  - 新增 `scripts/test-session-silence.sh`（118 项；与 `test-main-state.sh` 一起跑的定向变异全部被杀，见套件头部记录）：活动记录、会话静默的触发与每一种压制（含正对照，含排定唤醒的有界压制）、冷却与 IM 升级、IM 策略与会话名称、24 小时静默上限、多任务会话、StopFailure 记录的字段、坏记录、清理与 fail-open、一次性报告与合并、对话框归属语义，以及 11-19 事故形态的回放；每次 watchdog 扫描都断言 stderr 为空。既有套件中针对被删除豁免与 `idle_prompt` 旧映射的断言改为新语义。

## [0.31.0] — 2026-11-19

- **提示词：环境准备默认无需向用户请求批准。** 过去 agent 在开发或测试时，常会停下来问用户是否同意构建环境、安装依赖、拉取镜像、运行容器。现在 `SKILL.md` `## 自动执行策略`、主 agent 提示词和 implementation-agent（`subagents/` 与 `agents/` 两份镜像）都写明：这些都属于例行执行，默认不请求批准；agent 只需权衡本地直接构建运行还是在容器中执行更合适（项目已有约定、本机工具链、隔离需要、可复现性），选定后直接执行，并用一行记下选择和理由。边界不变：删除或覆盖不是本任务创建的容器 / 卷 / 数据、改动生产或共享的远程环境，仍按「数据丢失 / 不可逆变更」升级给用户；宿主权限模式拦下的命令视为用户的决定，换做法而不是原样重试。`scripts/test-watchdog-hooks.sh` T6 新增对应锚点。

## [0.30.1] — 2026-11-18

- **提示词：向用户提问并等待时怎么告诉 watchdog。** 主 agent 提示词新增一条规则，按提问方式区分：
  - 用 AskUserQuestion 提问不用做任何事。
  - 用自然语言提问，要在同一条回复里、结束这一轮之前 `expect.sh set <key> user`，否则停下时会被当成任务搁置拦一次。
  - 编排模式下用户通过 `answer.md` 异步回复时，**不要**用 `user` 声明：用户回复不经过对话，这条声明不会失效，也没有任何东西会在回答到达时唤醒 worker，任务会一直停在那里。改为写完 `question.md` 后用后台任务轮询回答文件，它就是会唤醒 worker 的执行者。`SKILL.md` 的声明用法表、`## 编排模式` 和问答模板同步补上了这一点，补齐了模板里只写了「worker 检测到 answer.md 时」、却没写怎么检测的缺口。

## [0.30.0] — 2026-11-18

- **watchdog 改为「agent 声明、插件兑现」。** 过去每遇到一种正当的安静场景（等用户、等长跑任务、常驻的开发服务器、发布后到点对账……），都要在脚本里硬编码一条豁免规则，场景穷举不完。现在主 agent 用新命令 `hooks/scripts/expect.sh` 在状态文件里**声明**自己的意图，watchdog 按声明行事，不再去猜。插件只守三条 agent 不能覆盖的不变量：活跃任务既没有执行者、也没有声明就报警；每条声明都会自然失效（到点、用户下次发言、或它绑定的后台任务结束），不存在永久静音；宿主报告的事实优先于声明。
  - **一种统一的声明行** `- Expect: key=…; kind=wait|user|resident; …`，取代各自为政的行格式；`hooks/scripts/expect_state.py` 是唯一的解析器。
    - `wait --at <时间> [--ref <后台任务 id>]`：某样东西会在这个时间之前推进任务。到点之前压住「状态过期」和「无执行者」；到点叫醒主 agent，不处理就每隔 `remind-sec` 再提醒，第 3 次起同时通知用户。带 `--ref` 时只在那个后台任务还在跑时有效，任务消失会提醒一次。最远 7 天。
    - `user`：停下来等用户，用户下次发言后自动失效（取代 0.29.0 的 `- Awaiting-User:` 行）。它只压住「无执行者」，不压「状态过期」。
    - `resident --ref <id>`：常驻后台任务（开发服务器、`tail -f` Monitor、无关的 cron）不算执行者。凡是自己不会结束、也不推进任务的后台任务都要声明，否则「无执行者」检查永远不会触发。工具返回的 id 与 Stop 输入里的后台任务 id 一致，已在 Claude Code 2.1.251 上实测。
    - `tune status-stale-sec=… no-executor-sec=… remind-sec=…`：按任务放宽阈值。每一层都取它与默认值中较大的那个，所以只能放宽；状态过期和无执行者最多放宽到 4 小时。
  - **`expect.sh`**（`set` / `clear` / `tune` / `list`）在写入前校验每一行，非法输入直接拒绝并给出诊断；写入加锁（并行调用不丢行）、按解析器的位置插入、写完重新解析确认生效，保留原有换行风格。手写声明行一个错字就会悄无声息地失效，所以提示词要求一律用它。
  - **新阶段 `observing`（观察期）。** 主体已交付、窗口保留用于到点观察（例如数仓 SQL 发布后次日对账）。它不是活跃阶段，到点之前 watchdog 完全安静；但必须用 `wait` 排定下一次检查，否则停下时 L4 拦一次、L3 每 3 小时提醒一次。
  - 每一行各自独立：格式错误或重复的行什么都不做，也不连累别的行（`expect.sh list` 会标成 INVALID）。所有解析都跳过 HTML 注释。评估器不可用（没有 python3）时一律放行，不会误报。
  - observing 阶段也认宿主排定的唤醒（没有声明为 resident 的 cron）和有效的 `user` 声明。
  - 旧格式 `- Waiting On:` 和 `- Awaiting-User:` 继续有效；`Waiting On` 到期后的提醒也改走新的「叫醒 + 再提醒」逻辑。
  - `runtime/stop-snapshot` 新增第三个字段，记录在跑的后台任务 id。新增环境变量 `ZYZ_EXPECT_MAX_SEC`、`ZYZ_WATCHDOG_REMIND_SEC`、`ZYZ_WATCHDOG_OBSERVE_SEC`。
  - `scripts/test-no-executor.sh` 扩充到 161 项，覆盖声明的每一种用法、observing 阶段、Tune、L1/L3/L4 对同一声明的判断一致、写入器的并发与注释布局，以及非法声明被拒的情况。独立评审抓到的 7 个阻断问题都已修复，并各自补了能让它变红的用例。

## [0.29.0] — 2026-11-17

- **活跃任务「无执行者」不再静默搁置（closes #24）。** 已有的三层检查（L2 退出门、L3 watchdog、L4 停止门）判据都是「某个具体角色有没有异常」，于是一种整体状态谁都不管：任务还有活，却没有任何执行者。真实事故：implementation-agent 在后台启动约 60 分钟的全量用例后以「等待通知」收尾、被记为 DONE；用例跑绿时没有任何东西唤醒它；主 agent 一直在处理别的通道，所以「已完成未收取」不成立、状态文件也是新的；最后主 agent 说「数仓还在跑」然后停下，Stop 门放行，任务空等约 30 分钟。
  - **L4 停止门新增「无执行者」子句。** 同时满足以下条件时拦一次（与其它子句共用冷却）：任务在活跃阶段且还有活（非 delivery 阶段，或 `## SubTasks` 记分板里还有未提交的 SubTask——列表和表格两种写法都解析，拦截理由会点名）；Stop 输入的 `background_tasks` 里没有未结束的任务、`session_crons` 为空；观察器看不到未结束的已派发角色；状态文件里没有显式的等待声明。主 agent 空闲**不**算豁免。插件 monitor 不算执行者——本 watchdog 自己就以一个 `running` 的 shell 任务出现在 `background_tasks` 里（已在 Claude Code 2.1.251 上实测）。输入里没有 `background_tasks`（Codex）时 fail open。
  - **新的显式等待声明 `- Awaiting-User: since-epoch=<unix>; reason=<…>`**（写在 `## Agent State`）。它只在用户下一次发言之前有效（`main-state.sh` 在 `UserPromptSubmit` 时记录 `runtime/user-prompt-epoch`），所以一行被忘掉的声明不会永久压住检查。有效的 `Waiting On` 行同样算显式等待。
  - **L3 watchdog 定时兜底。** L4 在每次 Stop 时写 `runtime/stop-snapshot`（宿主报告的执行者数），主 agent 的下一次工具调用或用户发言会删掉它。快照存在、执行者为 0、已过去 `ZYZ_WATCHDOG_NO_EXECUTOR_SEC`（默认 600）秒且没有显式等待时，watchdog 发一条唤醒通知和一条 `--origin stall` 的 stuck IM（绕过空闲压制）。它覆盖 L4 冷却期内的停止，不受 main-state 门控（`idle_prompt` 会在每次 Stop 后把状态记成 `awaiting-user`）。
  - **`Waiting On` 到期主动提醒。** 某一行的 `next-check-epoch` 到期后，L3 提醒主 agent 复查（每个 key 每个复查时间一次，按冷却限频）。
  - **L2 拦下「以等待收尾」。** 角色在本轮启动过后台任务（会话记录里有 `run_in_background`、Monitor、`nohup`/`setsid`/结尾 `&`），最终消息却以「等待完成通知 / monitor 通知」收尾时拦一次，要求前台等到结果，或把后台任务的 id、输出路径、预计完成时间明确交给主 agent。每个实例一次，`stop_hook_active` 时也检查（事故里那句话正是对「过短」拦截的回应）。
  - 提示词：主 agent 停下之前必须能指出一个核实过的执行者，否则继续派发或写 `Awaiting-User`；接手 subagent 留下的后台进程时用自己的后台等待盯住它。implementation / test / review 角色新增「不要以等待收尾」。
  - **修正：`## Agent State` 解析器跳过 HTML 注释。** 状态模板在这个小节的注释里写着 `- Waiting On:`（以及新增的 `- Awaiting-User:`）示例行，旧解析器把它们当成格式错误的行，导致从模板创建的 status.md 里任何真实的 `Waiting On` 声明都无效。
  - 已知局限写进了 `hooks/README.md`：常驻后台条目（自己的 `tail -f` Monitor、开发服务器、其它插件 monitor、循环 cron）会让检查一直不触发；空闲 teammate 在 `background_tasks` 里的呈现未经验证；完成通知丢失时 L3 在 macOS 上没有兜底。
  - 新增 `scripts/test-no-executor.sh`（79 项），驱动真实的 hook / monitor 脚本覆盖上述各层，包括用真实模板生成的 status.md、多仓库写法的 `Committed`，以及用替身观察器驱动的已派发角色与多任务会话；除一个等价变异外，每个守卫被去掉后都有用例变红。

## [0.28.0] — 2026-11-16

- **任务指针按会话区分（closes #23）。** 过去一个目录只有一份 `.zyz-worker/current-task`：同一目录下两个会话各跑一个 execute-task 时，后启动的会话只能覆盖它（先启动的会话的 watchdog 悄无声息地挂到新任务上）或者不写（自己的 watchdog 失效），两种结果都没有任何提示；唯一的绕行办法是另开 worktree 和新会话，丢掉当前会话的全部上下文。
  - **新指针 `.zyz-worker/sessions/<session-id>`**，一行一个任务（绝对路径），一个会话可以同时被 watchdog 监视多个任务。解析顺序：本会话的指针 → `current-task` → `$ZYZ_TASK_DIR`。仍然不做任何搜索，也不读别的会话的指针，保持 #18 的不变量——"哪个任务属于我"只由会话身份决定。
  - **会话身份**取自 hook 输入的 `session_id`。已在 Claude Code 2.1.251 和 codex-cli 0.151.0 上实测：它等于 `$CLAUDE_CODE_SESSION_ID` / `$CODEX_THREAD_ID`，并且在 subagent 的 hook 里仍是**父**会话的 id（Codex sub-agent 自己 shell 里的 `$CODEX_THREAD_ID` 则是子线程 id，所以 hook 侧优先读输入）。Claude 的后台 monitor 能拿到本会话的 `$CLAUDE_CODE_SESSION_ID` 和 `$CLAUDE_PID`，并额外认 `~/.claude/sessions/$CLAUDE_PID.json` 里的实时 id；Codex 的 `start-watchdog.sh` 把 hook 输入里的 id 通过 `$ZYZ_SESSION_ID` 交给 watchdog。
  - **新脚本 `hooks/scripts/task-pointer.sh`**（`arm` / `disarm` / `show` / `session-id`），主 agent 在 §1 用它写指针。它按最近的 `claude` / `codex` 祖先进程判定 harness，因为两个会话 id 变量都会泄漏进嵌套启动的另一个 harness；拿不到会话 id 时退回写 `current-task` 并提示。
  - **多任务语义。**
    - 主 agent 相关的层（主心跳、main-state、L1 主 agent 提醒、L4 停止门、notify 的 awaiting-user）作用于会话的每个任务，L4 把多个任务的理由合并成一次拦截。L3 watchdog 对每个任务的状态文件分别检查、分别报告。
    - subagent 的运行时记录存在主任务（指针第一行）下，但 hook 无法知道 subagent 是为哪个任务派发的，所以 subagent 类告警按会话处理：只要任一任务活跃就检查；"已完成未收取"以所有任务中最新的状态写入为准；多任务时消息不断言归属，列出全部任务由主 agent 判断，并写明记账目录供 `finalize` 使用。
    - IM 每个事件只发一条，多任务时 `task_id` 为全部任务（新增 `notify.sh --task-id`）。
  - **未启用报告**不再把同目录下其它会话指针认领的任务当作本会话丢了指针的证据。
  - 新增 `scripts/test-session-pointer.sh`（75 项），覆盖两个会话同目录互不串扰、回落行为、多任务报告与 subagent 告警措辞、旧会话兼容和脚本本身。subagent 类场景用替身观察器驱动，因此在没有 GENESIS 能力的主机（如 macOS）上也会实际运行。

## [0.27.0] — 2026-11-15

- **插件的全部提示词与文档改为简体中文。** 范围包括：
  - 各 skill（`SKILL.md`、主 agent 控制器提示词、模板、参考资料）、角色提示词（`subagents/` 与 `agents/` 两份镜像，含 frontmatter `description`）、斜杠命令（含 `argument-hint`）；
  - `README.md`、`CLAUDE.md`、`docs/`、`hooks/README.md`；
  - 插件清单与 `hooks.json` / `monitors.json` 的描述；
  - hook / watchdog 运行时注入给模型的消息（L1 状态新鲜度提醒、L2 退出门、L4 停止门、L5 范围守卫与 L6 checkout 守卫的拒绝理由、L3 后台 watchdog 通知），以及 IM 通知的默认标题。

  **脚本与协议按字面解析的内容一律保持英文**，升级不会破坏已有任务目录或主清单。具体包括：
  - `## Agent State` 及其 `- Waiting On:` 行格式、`- Current Phase:` 及其取值；
  - `## Pending Merge Approval` 与合并令牌，主条目 / `worker-status.md` / `dispatch.md` / `monitor.md` / 问答文件的协议标题；
  - 所有 frontmatter 键与枚举值、`intent=…` 名称、`[zyz-worker watchdog]` 前缀；
  - 评审裁决值与分级名、遗留风险清单字段、SubTask 记分板字段。

  其余章节标题按统一译名表翻译，所有跨文件的 `` `## …` `` 引用同步改名，并校验了无悬空引用。
  - 角色文件开头的身份句保持英文：镜像一致性测试只对这一行做归一化。
  - CHANGELOG 中已发布版本的条目保持英文原样，从本版本起的新条目使用中文。

  测试套件中针对提示词英文措辞的断言改为锚定对应的中文规则。一批原本靠 `! grep 'status file'` 判断"已压制"的负向检查，在消息改为中文后会恒真；现改为锚定 `分钟没有更新`，恢复了判别力。

  顺带修正了 `docs/notify.md` 的一处既有不一致：默认事件集合实际包含 `idle`，文档原先漏列。

- **L5 范围守卫识别中文限缩措辞。** 新增的中文模式覆盖这些说法："限 3 条发现"、"不超过 3 条"、"最严重的 N 条就够了"、"一行结论"、"只报阻断 / blocking 发现"、"跳过 / 不用报非阻断发现"。"第 1 步，共 4 步"、"然后继续……"这类分步交付的说法被识别为承诺交付剩余部分，予以放行；"每页最多 3 条记录"这类与评审范围无关的普通需求不会误伤。

- **评审循环按"能否到达产物"收口（closes #22）。** 过去评审循环要等评审者无话可说才结束，遇到刁钻构造时不收敛：每次修复只回应一个构造，下一轮就在同类的下一个变体上找到缺口。生产中一个令牌脱敏子任务因此从第 10 轮走到了第 20 轮。新增 `skills/execute-task/SKILL.md` `## 评审收口`：
  - **三级分级。** 每个评审点、每个评审者的每条发现都分为 `blocking` / `non-blocking:normal` / `non-blocking:contrived` 三级。分级的判据是设计文档新增的 `## 范围边界`（声明的输入、调用方、威胁模型、用户裁定的范围外构造），而不是构造看起来有多刁钻。
    - 威胁模型与范围外条款由用户决定；用户未明说的条款要列入快速审阅的关注项。
    - 涉及安全 / 数据且边界未声明时，交给用户决定。设计赖以成立的未声明前提，绝不会因为现有调用方恰好满足而被判成 `contrived`。
    - 对外暴露的接口，其外部使用方也算调用方。
  - **收口条件。** 评审点在同一轮满足三条时收口：reviewAgent 自己的报告为零 blocking（当且仅当存在 blocking 发现时 `结果` 为 `changes-requested`）；交叉评审没有被接受为 blocking 的发现；也没有待用户决定的问题。
    - 拒绝或降级一条 blocking 不能单凭裁决收口，要由下一轮评审者确认或重提，"接受↔拒绝反复 3 次即升级"因此依然有效。
    - 每个评审点至多再开一轮用于落地 normal 级修复。
  - **遗留风险清单。** contrived 发现从不在本循环内修复，而是按类记入新的遗留风险清单（`templates/residual-risks.md`：来源、复现、影响面、已验证的加固方案、状态）。后续评审者拿到清单后不再重复提出；但如果某个变体由清单条目未排查过的调用方触发，它算作一条新发现。最终报告把清单作为后续加固任务的输入提出。
  - **同类变体。** 已修过的类再出现第二个变体时，标为 `recurring`，必须用一次类级修复（或一个清单条目）解决，不再逐个打补丁。
  - **收敛检查。** 评审点到第 3 轮仍有 blocking 时（之后每 3 轮一次），主 agent 做一次收敛检查并告知用户结论：继续；改为类级修复；把域内的对抗性加固重排为主路径之后的独立 SubTask，并为它接手的发现建台账行；或把范围问题升级给用户。
  - **护栏。** 分级只改变处置，不改变上报；把评审者判的 blocking 降级，要像拒绝一样附上调用方枚举证据；拿不准时按 blocking 处理。
  - **落地范围。** 主 agent 与 review / implementation / test 角色提示词（两份镜像）以及评审报告、交叉评审、任务状态、最终报告、设计文档模板均已接入。

- **L5 范围守卫：否定只在本句生效，词库覆盖分级词汇。** 过去一处否定会让整条派发提示词都被放行，所以"Never skip contrived findings. Report only the blocking findings." 能逃过检查，#20 的非阻断否定也有同样的漏洞。改动如下：
  - 否定现在按子句判定，只对它所在的那一句生效。
  - 反引号包裹的分级词在去引号之前先解包，所以"report only `blocking` findings"能被拦下。
  - 否定的上报动词只在否定的是 "only" 时才算放行信号，"do not report non-blocking findings" 属于限缩。
  - 新增 contrived / 刁钻 / 边角 / 对抗 等限缩模式，以及 不要 / 不能 / 别 + 跳过 / 忽略 的中文否定。

## [0.26.0] — 2026-09-28

- **Fixed: Codex workers could not start when a Codex plugin provides an MCP
  server.** With the default `ZYZ_WORKER_MCP=none`,
  `scripts/orch-worker-mcp-args.sh` emitted a lone
  `-c mcp_servers.<name>.enabled=false` per enabled server. For a server that
  comes from a Codex plugin rather than `config.toml` (e.g. `cua_repl` from the
  bundled computer-use plugin) that override materializes a transport-less
  entry, and every codex command — the interactive worker included — refused to
  start (`Error loading config.toml: invalid transport`). Each disable override
  is now paired with the server's own transport key (`.command=` for stdio,
  `.url=` for streamable_http), values TOML-encoded and shell-quoted; a config
  entry takes precedence over the plugin's, so the server is disabled, and a
  server `config.toml` already defines keeps its args/env. A server whose
  transport cannot be rendered fails the spawn closed. The two duplicated
  renderers in the helper are now one. Verified against codex-cli 0.151.0;
  `scripts/test-codex-adaptation.sh` covers the rendering and, when codex is
  installed, checks that real codex loads the overrides with every server
  disabled.

- **Cross-harness review: every review point also runs a reviewer from another
  agent product.** Alongside the `review-agent` subagent, each design-review
  iteration, implementation / SubTask review, and aggregate review launches a
  read-only review session in every OTHER agent harness installed on the
  machine — `codex exec` when the main agent runs in Claude Code, `claude -p`
  when it runs in Codex (the host is never re-launched). New
  `scripts/cross-review.sh` (`detect` / `run`) renders
  `skills/execute-task/templates/cross-review-prompt.md` + a main-agent brief,
  runs the reviewers concurrently, and captures each report under
  `<task-dir>/reviews/cross/`. Sessions are read-only (Codex `-s read-only`;
  Claude `--permission-mode dontAsk` with a read-only tool allowlist), run with
  every `ZYZ_*` variable scrubbed and `ZYZ_HOOKS_DISABLE=1` so the plugin's own
  hooks never treat the reviewer as this task's agent, and default to zero MCP
  servers (a Codex config-load failure caused by the overrides retries once
  inheriting). The posture is unchanged: cross-harness
  findings are advisory, each is independently verified by the usual
  adjudicator before acceptance and may be rejected with a recorded reason
  (status file `## Cross-Harness Review`); a review point converges when
  `review-agent` reports `no-changes-needed` AND every cross-harness finding has
  a disposition. Optional and never blocking: no other harness,
  `ZYZ_CROSS_REVIEW=off`, a failure, or a timeout is recorded and the workflow
  continues. Knobs: `ZYZ_CROSS_REVIEW`, `ZYZ_CROSS_REVIEW_TIMEOUT`,
  `ZYZ_CROSS_REVIEW_MCP`, `ZYZ_CROSS_REVIEW_{CODEX,CLAUDE}_ARGS`. Tests:
  `scripts/test-cross-review.sh`.

## [0.25.1] — 2026-09-28

- **Fixed: hooks went silent once the agent `cd`-ed away from the project
  root, so the idle gate never held.** Every hook resolved the task pointer
  from the payload `cwd` only; Claude Code keeps the shell cwd across Bash
  calls, so after a `cd .zyz-worker/tasks/<id>` (or `apps/api`) heartbeat /
  Stop / Notification all found no pointer and no-op'd. `main-state` froze at
  its last `working`, while the watchdog — resolving from the project dir —
  kept seeing an active task and nagged for hours (observed: hourly
  `status file … stale` events for 14 h after a task handed back to the user,
  the main agent woken each time just to renew a `Waiting On` row).
  `zyz_task_root` now falls back to the session project dir
  (`$CODEX_PROJECT_DIR` / `$CLAUDE_PROJECT_DIR`, the dir the watchdog already
  uses) when the cwd has no pointer; a cwd with its own pointer still wins.
  This is the session's own launch dir, not a search (#18 unchanged). Hook
  test suites now unset both variables so the invoking session cannot leak a
  real task into their sandboxes.
- **Fixed: the watchdog still nagged every cooldown while the main agent waited
  on an AskUserQuestion.** The 0.25.0 gate relied on a Notification hook to
  record `awaiting-user`, but Claude Code does not reliably emit one for an
  AskUserQuestion dialog (observed: 1 `needs_input` across 10 questions,
  including a 10-hour wait), and the question's own PreToolUse heartbeat wrote
  `working` — so the state never left `working` and a `status file … stale`
  Monitor event fired every 15 minutes for the whole wait. `heartbeat.sh` now
  records `awaiting-user` on the main agent's PreToolUse of `AskUserQuestion`
  (the matching PostToolUse, when the user answers, records `working`).

## [0.25.0] — 2026-09-21

- **Pure-signal main-agent state machine gates idle nags while the main agent
  waits on the user.** Previously the L3 background watchdog and L4 stop-gate
  could not tell "the main agent is legitimately waiting for a user answer"
  (an AskUserQuestion panel, a permission prompt, an MCP elicitation — possibly
  for hours) apart from "the main agent is stuck", so they kept injecting
  role-silence / status-stale / stuck events into the main agent's context.
  A single per-task state file `<task-dir>/runtime/main-state` (states
  `working` / `awaiting-user` / `idle` / `ended`) is now written atomically by
  hooks at platform-confirmed transition points, and the watchdog/stop-gate
  read it to suppress main-agent-attributed nags while the main agent is
  waiting or stopped. **No TTL** — the gate is a pure string compare and never
  reads a timestamp, so a wait of any length (hours away from the keyboard) is
  never misread as a stall; the state is only left by a later
  timestamp-updating signal (UserPromptSubmit / a main-agent tool call / Stop /
  SessionEnd).
- **Real subagent deaths are still reported (A-scope).** Suppression covers
  only main-agent-attributed events; a genuinely dead or silent subagent role
  (stale / unharvested / tracking / probe / no-output) is reported as before,
  and its stuck IM push bypasses the gate (new `notify.sh --origin
  main|subagent` split) so an away user is still paged about a real death.
- **New `idle` IM event.** When the main agent stops during an active phase,
  a dedicated `idle` notification tells the user "the agent stopped and handed
  back" via the configured IM — separating the user-facing notification path
  from the monitor→main-agent nag path, which is now silenced. Added to the
  default notify event set (opt out via `events` in `notify.json`).
- New hook `hooks/scripts/main-state.sh` on `UserPromptSubmit` / `Stop` /
  `SessionEnd`; `hooks/scripts/heartbeat.sh` records `working` on each
  main-agent tool call. Known limitation (accepted, documented): a main-agent
  tool that truly hangs after a permission grant is not status-stale-reported
  while in the suppressed state — the deliberate cost of the no-TTL design.

## [0.24.0] — 2026-09-10

- **Mandatory test-layer coverage hardened in the execute-task design phase.**
  Practice surfaced tasks delivered with no end-to-end test at all, badly
  hurting delivery quality. The design-doc template's `## Testing Plan` section
  is rewritten from a soft note into a HARD requirement: every design MUST plan
  concrete, scenario-specific cases and flows for all three layers — unit,
  regression, and end-to-end (e2e) — with e2e explicitly not skippable on the
  grounds that "unit tests cover it"; omitting any of the three now requires an
  explicit written reason plus the user's agreement. Pressure/stress tests
  remain a scenario-driven judgement call (throughput, concurrency, data
  volume, latency/capacity SLOs, or a `## Risks` performance/capacity entry),
  planned with concrete load targets when warranted.
- `SKILL.md` §2 step 1 gains a matching instruction: the design phase must
  design the actual test cases and flows the task needs from its real scenario,
  treating unit/regression/e2e as a hard floor and judging pressure testing by
  scenario — with the rationale (shipped-without-e2e regressions) recorded so
  the emphasis is not silently softened later.

## [0.23.0] — 2026-09-09

- **Design-phase authority sharpened in the execute-task workflow.** Three
  gaps between the shipped prompts and the intended "user leads design, the
  agent only organizes" standard are closed:
  - **`key algorithm` added to every design-change trigger and conformance
    enumeration.** The protected-element lists previously read
    module/flow/interface/data-structure/architecture and omitted algorithms,
    so a finding that would change a key algorithm could be adjudicated as an
    ordinary within-design finding instead of escalated to the user. Fixed
    across `SKILL.md`, `main-agent.md`, both `review-agent.md` and
    `implementation-agent.md` copies (`agents/` + `subagents/`), and the
    `design-doc.md` template banner.
  - **New duty to surface problems in the user's own design, never resolve
    them silently.** The main agent (with reviewAgent) now actively hunts for
    and routes to the user four problem kinds in what the user *did* describe —
    errors, contradictions, ambiguities, and **implicit assumptions that may
    not hold** — instead of picking an interpretation or encoding a shaky
    premise as fact. Added to `SKILL.md` `## User Design Authority` / §2 Design
    and the `main-agent.md` responsibilities + Design Workflow.
  - **reviewAgent design-review standard now names key algorithms and unstated
    assumptions** as explicit check items (both `agents/` and `subagents/`
    copies).
- Prompt-only change; no runtime, hook, or script behavior changes.

## [0.22.0] — 2026-09-09

- **New skill `zyz-worker:self-healing-loop`** (closes #21): a reliable
  long-running, on-schedule agent that lives in a Claude Code session and heals
  itself when the wake-up chain breaks. A bare session `/loop` (self-scheduled
  via `ScheduleWakeup`) silently sleeps after one network/API blip snaps the
  chain; this skill adds a two-layer **loop + watchdog** architecture. The
  **loop** (living half) runs in the main session and executes due tasks; the
  **watchdog** (dead half, a `*/20 * * * *` cron script) reads the same state
  file and, on a miss, first writes a sentinel file that a persistent Monitor
  turns into a fresh turn so the live session back-fills with full context, then
  falls back to headless `claude -p` only if a grace period passes. One
  `/zyz-worker:self-healing-loop <task>` turn installs the watchdog + crontab
  line, arms the sentinel Monitor, and starts the loop; `uninstall <name>` tears
  it down. Ships `skills/self-healing-loop/SKILL.md`, four `templates/`
  (`watchdog.sh`, `monitor-sentinel.sh`, `loop_state.md`, `uninstall.sh`), a
  `references/wakeup-channel.md` deep-dive, and `commands/self-healing-loop.md`.
  Design lessons baked in: the wake-up channel must be push-style (sentinel +
  Monitor wakes a slept session; cross-session `SendMessage` cannot); the Monitor
  is re-armed on every loop wake-up because it does not self-heal; the watchdog
  writes the sentinel unconditionally rather than pre-checking liveness from
  unstable fields; and idempotency (today's date in the state row) plus an
  `mkdir` mutex prevent double-runs. `<NOTIFY>` reuses the existing IM layer
  (`~/.zyz-worker/notify.json`, see `docs/notify.md`). Documented boundary,
  stated in every artifact: self-healing covers a broken/slept chain, NOT a
  killed process — headless protects business continuity but restoring the
  resident loop takes one manual re-launch. Installing the crontab line is a
  system-level change and requires explicit user confirmation.

## [0.21.1] — 2026-09-09

- **Dispatch subagents in the main agent's own working directory, not into a
  git worktree.** On cross-repo / full-stack tasks the main agent could spawn
  implementationAgent / testAgent / reviewAgent with `isolation: worktree`,
  landing the subagent in a fresh worktree path that is usually OUTSIDE the
  session's permitted directories — its file writes were then denied and the
  role could not work at all (worse when the main agent was itself already
  inside an orchestrator-created worktree, nesting one worktree in another).
  `skills/execute-task/prompts/main-agent.md` now carries an explicit rule to
  default to no isolation so each subagent inherits the main agent's cwd and
  granted permissions, reserving `isolation: worktree` for the rare
  isolated-tree lane whose worktree path has been confirmed permitted (and
  never for ordinary implementation/test/review dispatch). `SKILL.md` §3.0.x no
  longer recommends `isolation: worktree` as the default escape hatch for
  mutation / refactor lanes — backup-copy discipline is the default, with the
  permitted-path caveat spelled out.

## [0.21.0] — 2026-09-09

- **testAgent gains `Bash`, scoped to self-verifying its OWN test code.** The
  role previously had no shell, so it could not compile what it wrote and the
  "delivered ≠ compilable" class of defect (leaked `</content>` tags, missing
  helpers, arity mismatches) always leaked downstream to implementationAgent /
  the main agent. testAgent now (a) MUST compile / type-check / vet / lint its
  tests and fix syntax, import, type, and arity errors before handoff, and (b)
  MAY smoke-run its own lightweight cases (`-run`-scoped to what it just wrote,
  no test DB / ports / network, nothing heavy / e2e / concurrent) purely as
  private authoring feedback. The smoke-run is deliberately NOT a verdict: its
  result is not reported to the main agent and never substitutes for or
  short-circuits the authoritative run — that keeps it out of the verdict chain
  so it cannot be mistaken for a green signal. The writer-does-not-certify-green
  separation is preserved intact: testAgent still must not run the full suite to
  declare it green, must not run heavy / e2e / DB-backed / concurrent suites, and
  must not execute the `## Mutation Manifest` or the injected-degradation
  manifest — implementationAgent runs those and returns per-entry
  KILLED/SURVIVED, so a test's author is never the sole judge of that test's
  result. Changed in `agents/test-agent.md` + `subagents/test-agent.md` (bodies
  kept byte-identical), and the boundary docs `skills/execute-task/SKILL.md`
  (§Role Boundaries) and `docs/architecture.md` (role table + rationale; the
  rationale no longer claims review-agent is the *only* Bash-carrying role).

## [0.20.0] — 2026-09-09

- **IM stop-notifications: get pinged when a workflow needs you, finishes,
  fails, or stalls.** New `hooks/scripts/notify.sh` (L7) forwards the
  hook-catchable "agent stopped" events to a user-configured command, so a
  long-running `execute-task` / `orchestrate-tasks` run can be left unattended.
  It ships one mechanism — a custom command — that receives the event as
  `ZYZ_NOTIFY_*` env vars and a JSON object on stdin; `docs/notify.md` carries
  ready-to-paste Feishu / Telegram / generic-webhook recipes. Configuration
  lives in `~/.zyz-worker/notify.json` (`enabled`, `command`, optional `events`
  whitelist, `cooldown_sec`, `include_message`); secrets never enter the repo.
  Event sources: `Notification` (permission_prompt / agent_needs_input /
  elicitation → **needs_input**; agent_completed / idle_prompt → **completed**),
  `StopFailure` (API-error terminations → **failed**), `SessionEnd` (graceful
  close → **session_end**, OFF by default), and the existing L3 watchdog, which
  now also fires **stuck** on a silent-role / stale-status / unharvested
  finding (the requested reuse of the monitor layer). All three new hooks are
  registered `async: true`, so IM latency never slows the workflow, and every
  path is workflow-scoped (no `.zyz-worker/current-task` pointer → no
  notification) and fail-open. `needs_input` / `completed` ride Claude Code's
  idle/permission timers, so an actively-typing session is never spammed.
  Honest coverage boundary, documented: a true whole-process death (kill -9,
  OOM, terminal close, network drop) fires no hook and takes the monitor down
  with it, so it is not covered; `stuck` catches the in-session stall.
  Disable with `ZYZ_NOTIFY_DISABLE=1` (just the notifier) or
  `ZYZ_HOOKS_DISABLE=1` (the whole layer). New `scripts/test-notify-hook.sh`
  (21 checks) covers event→category mapping, scope/config gating, the
  default-vs-explicit event set, `include_message` redaction, per-category
  cooldown, and the watchdog `stuck` path; T2R in `scripts/test-watchdog-hooks.sh`
  now validates all thirteen registered hook commands.

- **Fix an incomplete 0.19.1 release.** 0.19.1 bumped only the two Claude
  manifests and the changelog, leaving `.codex-plugin/plugin.json` and all four
  test suites' `EXPECTED_VERSION` at 0.19.0 — which left the version-consistency
  checks (T6 and friends) red. 0.20.0 brings every version location back in sync
  (three manifests + `test-watchdog-hooks.sh` / `test-codex-adaptation.sh` /
  `test-clean-tmp-skill.sh` / `test-release-0-5-0.sh`) and ships the
  previously-missing release archive.

## [0.19.1] — 2026-09-09

- **Make progressive, dimension-by-dimension review output the DEFAULT, not a
  permitted option.** Observed failure: reviewAgent ran for a long time and then
  crashed at the output stage, returning nothing — the whole review lost with
  not one word delivered. The cause was that its `## Incremental Output` section
  only *allowed and encouraged* multi-pass delivery, so the model composed the
  entire report and emitted it in one final turn — the exact emission that
  fails. Both reviewAgent copies (`subagents/review-agent.md` and
  `agents/review-agent.md`) now direct the role to emit each part the moment it
  is finished, as its own message (design conformance → correctness → test
  quality → regression risk → risk-specific → overall verdict), and explicitly
  permit revising or extending an already-emitted section in a later message so
  there is no reason to withhold a finding until it feels "final". The section
  now names the crash as the failure mode it prevents: each smaller emission is
  less likely to fail, and what already landed is preserved even if a later turn
  does. The main agent (`prompts/main-agent.md`) now requests this progressive
  delivery by default at review dispatch — not only during stuck-role recovery —
  and records each installment as it arrives.

- **Make SubTasks flow through to completion autonomously — no per-SubTask user
  approval.** Observed failure: on a multi-SubTask task the workflow finished the
  earlier SubTasks and then stopped to ask the user whether to run the rest. The
  rule "do not start SubTask N+1 until SubTask N has all three flags true" is
  about dependency correctness, but it read like an approval checkpoint.
  `SKILL.md` §3.B and `prompts/main-agent.md` now state explicitly that once the
  design→implementation gate (§2 step 8) has been passed, the implementation
  phase runs to completion on its own: as soon as a SubTask's flags are true (or
  it is recorded blocked-and-deferred) the next ready SubTask(s) are dispatched
  immediately, and the only mid-implementation stops are the genuine blocking
  cases already in `## Automatic Execution Policy` (a role wanting to change the
  user's design, data loss / irreversible change, a decision contradicting Goals
  or Acceptance Criteria, or a true blocker). No runtime code changed.

## [0.19.0] — 2026-09-08

- **Give every design document a `## Quick Review` approval surface.** Directly
  under the user-is-designer banner, above the body: `### Design Summary` (the
  whole design in a page or less — which modules exist and what each owns, how
  the work divides, the key algorithms, the end-to-end flow, named as the body
  names them) and `### Details Needing Your Attention` (implementation details
  the user should look at before approving, each with why — an irreversible
  decision, a real trade-off, a performance/security/data-shape consequence, a
  deviation from local convention, an assumption made absent a user decision;
  legitimately `none`, and not a second home for `## Open Questions`). The
  design→implementation approval gate now points the user at this section, so
  the direction can be judged without reading the whole spec.
  A summary goes stale the same way a design body does — someone APPENDS the
  correction instead of rewriting what is now wrong ("(now five modules)" bolted
  onto a sentence that still says four) — so three rules keep it honest: it is
  updated in the same edit as the body and by rewriting, never by appending;
  when the two disagree the **body wins**; and the repair is to **regenerate the
  affected part of the summary from the body** as it now stands, not to patch
  the one sentence that was caught and never to soften the body to match. A
  stale claim means the summary was derived from a design state that no longer
  exists, so its neighbours are suspect too.
  reviewAgent audits summary-vs-body consistency during design review and
  reports a divergence as blocking (it misleads the approving human), stating
  the repair as re-derivation rather than a one-line fix. 8 new T6 assertions,
  four mutation-verified — one of them caught a self-satisfying assertion of my
  own: a loose `/re-deriv|regenerat/` grep matched unrelated lines elsewhere in
  SKILL.md and stayed green with the rule deleted, so it is now anchored to the
  rule's own wording.

- **Make the user's design authoritative in both phases, and gate every change
  to it on the user's prior agreement.** New `## User Design Authority` in
  `SKILL.md` and `prompts/main-agent.md`, plus `#### 3.0.0 Implement the design
  document exactly`. Three rules: (1) in the design phase the main agent
  ORGANIZES rather than designs — it turns the user's described flow and
  structure into an executable spec (ordered steps, exact fields/signatures/
  paths, error cases, test points), names the gaps and asks, and never
  introduces a module, layer, data flow, or architectural choice the user did
  not describe; a missing design decision is a question for the user, not a gap
  to fill with a documented assumption. (2) Any role in either phase that wants
  to add, remove, restructure, or substitute a module, flow, interface, data
  structure, or architectural decision states the case to the main agent, which
  puts the problem and the smallest option set to the USER and waits — only the
  user's agreement authorizes it; implement-then-report is a violation even when
  the result is better, and silently skipping an element that could not be built
  is the worst form of it because it ships as if complete. (3) In the
  implementation phase the design document is implemented exactly: nothing
  dropped (every module, step, field, error case, interface, acceptance
  criterion) and nothing contradicted (no substituted mechanism, no "equivalent
  but simpler" structure, no unrequested module or abstraction, no reordered
  flow).
  This **outranks** the standing "do not ask the user by default" posture, which
  governs accept/reject decisions and failure attribution only WITHIN the
  approved design and never authorizes changing the design itself — the
  escalation list and design-workflow steps 1/4/7 are updated so the two do not
  disagree. reviewAgent's design-conformance dimension is now a bidirectional
  element-by-element audit (missing elements AND unrequested additions), both
  directions blocking, with the design section and `file:line` named; the
  document-hygiene non-blocking calibration never applies to it, since these
  findings reach the artifact. implementationAgent and testAgent gain the
  matching hard limit and reporting duty; testAgent additionally asserts what
  the design specifies rather than what it would have designed.
  `templates/task-status.md` gains a design-change request ledger under
  `## User Decisions`; `templates/review-report.md` states the bidirectional
  conformance requirement. `templates/design-doc.md` opens with a short KEPT
  banner naming the user as the document's designer — it stays in the filled
  document (unlike the delete-on-read scaffolding above it) so
  implementation-agent, test-agent, and the approving human all read the rule
  in the artifact itself rather than only in the prompts. 15 new T6 assertions,
  five mutation-verified — including one that distinguishes the banner being
  present from the banner sitting outside the scaffolding comment, since a
  banner nested inside it would vanish from every real design document.

- **Constrain the SHAPE of a design-document repair (#20).** The design phase
  had a rule for where review history goes (#15) but none for how a design
  defect gets fixed, so main agents fixed defects by appending self-annotations
  to the design document instead of editing or deleting the wrong text. Measured
  on a real 21-round design review: `design.md` grew 127KB → 148KB across four
  rounds with **no substantive technical change** (the reviewer independently
  confirmed the technical surface had been stable since round 17), a 432-line
  delivery spec carried 81 `第 N 轮` / 77 `前版` / 21 `订正` traces, and the
  fix-to-new-defect rate reached roughly 1:1 — four fixes in round 21 introduced
  three new defects. The mechanism: deleting a rotten number is O(1) with no
  side effects, while appending a paragraph about the deletion creates a new
  reviewed text face, a new coupling point, and something that can itself rot
  (and did). New `## Design Document Edit Discipline` in both
  `main-agent.md` and `SKILL.md`: repair by editing or deleting the
  wrong text and never by annotating it; after a repair the document holds flat
  or shrinks (measured `wc -c` before vs after the round's accepted findings);
  "why it changed" / "what the previous version got wrong" /
  "corrected in round N" go to `<basename>.review-history.md`, which is not
  reviewed, generates no findings, and may grow without limit. A finding that
  names something MISSING is explicitly carved out — it is fixed by ADDING the
  missing spec, and that growth is expected; without the carve-out an agent
  holding a blocking "AC7 is missing" finding plus an absolute no-growth rule
  had no compliant move, and the cheapest reconciliation was to under-specify.
  The discipline is scoped to a task's design document under the task
  directory, not this repository's own `docs/`. Design workflow step 6 in both
  files states the repair shape at the point of use, and
  `templates/design-doc.md` carries the same note as deletable scaffolding.
- **Keep document-text self-check rules out of the design document (#20).**
  Performing a grep over the design's own prose is free; writing that grep into
  the deliverable makes it a reviewed surface, its own scan target, and a new
  coupling point at once — on the same task, such blocks caught ~3 issues the
  review had missed while generating 20+ findings of their own (baseline already
  red, output empty by construction, matching only their own command line, the
  checklist sitting outside its own scan surface). The design document specifies
  how to check **code** — mutation targets, positive anchors, no-op
  classification, carrier ownership — where a compiler and a test suite
  adjudicate. Also documented: accumulated annotations are stripped in ONE pass
  leaving no trace of the strip, verified as a pure deletion by the set
  difference of identifiers and `file:line` coordinates (only document
  self-references may disappear; zero code coordinates may be lost).
- **Calibrate reviewAgent: document-hygiene findings are non-blocking (#20).**
  New `### Document-Hygiene Findings Are Non-Blocking` in both review-agent
  mirror copies: a design finding whose ONLY consequence is that a future editor
  of the design document might be misled — unreachable from the implementation,
  the tests, and the delivered behavior — is labeled `non-blocking`, recommended
  for the review-history file rather than a design-body edit, and does not hold
  back `no-changes-needed`. The dividing line is reachability into the artifact,
  not severity of wording; anything that can produce wrong code, an untestable
  acceptance criterion, a missed requirement, a conflict, or an ambiguity a role
  would have to guess at stays a required change. reviewAgent also stops
  reporting the *absence* of document-text self-check rules as a finding.
  `non-blocking` is explicitly a **verdict, not a license to report less** —
  every such finding still appears with its own evidence, so the calibration
  cannot be misread against the "never batch findings into 'the rest are
  fine'" hard limit or the L5 dispatch-scope-guard's anti-scope-reduction
  posture; it changes only where the fix is recorded and whether it can hold
  back `no-changes-needed`.
  `templates/review-report.md` labels design-phase findings blocking /
  non-blocking (and lists only blocking ones as expected-to-land in
  `## Next Review Input`, so a recorded non-blocking finding is not re-raised
  every round), and `templates/task-status.md` gains
  `## Design Review > Non-Blocking Findings Recorded To Review History` — with
  an owning rule in both the prompt and SKILL.md design workflows, so the field
  has a writer rather than being an orphaned slot.
- **Teach the L5 dispatch-scope-guard the new blocking/non-blocking vocabulary
  (#20).** Minting a severity label created a scope-reduction phrasing the guard
  did not know: `report only blocking findings`, `blocking findings only`,
  `skip the non-blocking ones`, `只报阻塞性问题`, `跳过非阻塞的` all passed
  while the equivalent `blockers only` was denied. `hooks/scripts/lib.sh`
  extends the existing severity-filter family (rather than adding a new
  mechanism) with `blocking`/`non-blocking` plus two CJK arms, and extends the
  matching negation veto so the anti-cap instruction the coverage rules teach
  the main agent to send (`do not report only blocking findings`, `never skip
  the non-blocking ones`, `不要只报阻塞性问题`) is still allowed.
- **Documentation and coupling points.** `docs/architecture.md` gains §3.3 f)
  (the mechanism plus the measured evidence) and a §8 row listing all seven
  carriers that must change together; `docs/design/execute-task-skill-design.md`
  gains `### 设计文档的修改形态`, mirroring the discipline and the reviewAgent
  calibration in the plugin's own design document.

## [0.18.2] — 2026-09-01

- **Resolve hooks from the host-installed plugin root.** All ten hook commands
  now use the same `PLUGIN_ROOT` → orchestrated `ZYZ_PLUGIN_ROOT` →
  `CLAUDE_PLUGIN_ROOT` → legacy `CODEX_PLUGIN_ROOT` chain, treating unset and
  empty values alike. If no host supplies a root, the hook succeeds without
  running anything instead of resolving a script from the session cwd or a
  developer-specific source path.
- **Preserve tracked symbolic links in release archives.** `pack.sh` still uses
  `git ls-files` as its only inclusion list and reads regular-file bytes from
  the current working tree, but now stores each tracked symlink as a symlink
  entry with its exact target instead of dereferencing a directory link into
  an empty archive directory.

## [0.18.1] — 2026-09-01

- **Teach the `git-worktree` skill copy-on-miss for untracked-but-required
  files.** A fresh worktree only holds what git tracks, so gitignored local
  files a project needs to build/start/test (`conf/test.yaml`, `.env`, local
  fixtures) are simply absent — and the failure looks like a broken branch
  rather than a missing file. The skill now carries an on-demand procedure:
  resolve the main work tree from `git worktree list --porcelain`, verify the
  path exists there and is untracked (a tracked-but-missing path is a checkout
  problem that copying would mask), refuse to overwrite, then `cp -p` into the
  same relative path and report the copy. Invariants: copy rather than symlink
  (a symlink leaks a worktree's writes into the main tree and every other
  worktree, defeating the isolation); config/fixture files only — reinstall
  dependency trees and rebuild outputs instead; never bulk-copy everything
  gitignored; copied secrets stay untracked; missing in the main work tree too
  is a stop, not a cue to synthesize from a `.example`; and the copies make a
  later `git worktree remove` require `--force`.

## [0.18.0] — 2026-08-28

- **Remove the sibling-worktree fallback from task-pointer resolution (#18).**
  `zyz_task_root` resolves the active task ONLY via the base dir's
  `.zyz-worker/current-task` pointer and the exported `$ZYZ_TASK_DIR`; it no
  longer enumerates sibling git worktrees. Real incident: with two concurrent
  execute-task runs in one repo, a session whose own pointer went missing
  silently attached to the OTHER session's task, and the watchdog then drove
  imperative, authoritative-looking staleness alerts (backed by the Stop
  gate) pushing that session's main agent to write "current progress" into a
  status file it did not own. The fallback traded a deterministic failure
  (no pointer → layer silent, which the §1 armed check already surfaces) for
  a probabilistic wrong attach indistinguishable from a correct one; the
  scenario it covered is handled by the absolute-path pointer contract
  (SKILL.md §1 step 4) plus `$ZYZ_TASK_DIR` for orchestrated spawns. The
  watchdog's NOT ARMED message now states that sibling worktrees are
  deliberately not searched.
- **Recognize terminal-phase synonyms (#18 rec 4).** New `zyz_phase_terminal`
  accepts `done`/`delivered`/`completed`/`closed`/`finished`/`cancelled`/
  `abandoned` (prefix match, so annotated forms like `done(delivered)` count);
  `zyz_task_is_done` uses it, and `zyz_phase_active` excludes terminal phases
  before its active match. Previously `*deliver*` classified a task whose
  phase said `delivered` as ACTIVE, so L1/L3/L4 staleness machinery nagged a
  finished task forever — which is exactly what pushed the #18 session to
  delete its pointer and expose the wrong-attach path.
- **Document alert-ownership discipline (#18 rec 5).** SKILL.md
  `## Watchdog Enforcement` and the main-agent prompt now require verifying
  that a watchdog alert's named path belongs to THIS session's task before
  writing into it; a mismatch is reported to the user, never written through.

- Fix an intermittent false FAIL in `scripts/test-rename-and-conventions.sh`
  T4 Pattern B. The check piped ~28KB of bullet lines into `grep -q` under
  `set -o pipefail`: `-q` exits at the first match (the target bullet sits
  ~4.7KB in) and closes the pipe's read end, so when scheduling left the
  upstream `grep` still writing past the kernel pipe buffer it died of
  SIGPIPE (exit 141) and pipefail turned a real match into a FAIL. The
  downstream grep now drains all input (`>/dev/null` instead of `-q`),
  which removes the race categorically while keeping identical match
  semantics. Observed twice as a first-run-only flake on an unchanged,
  passing file; the suite's other `-q` pipelines are not affected (their
  upstream outputs fit the pipe buffer or their exit status is unused).
- Move review history out of the design document into standalone
  review-history files (#15). The design-doc template no longer has a
  `## Review History` section; each design document `<basename>.md` records
  its review history in the sibling file `<basename>.review-history.md`
  (one per design document, created lazily on the first entry — split
  designs get one per part). Review history only matters to the design
  phase's review loop and human approval; for the implementation phase it
  is noise, so implementation-agent / test-agent dispatches send the
  final-state design document(s) only and never include review-history
  files, which are also excluded from the status file
  `## Metadata > Design Document` list. The status file's
  `## Design Review > Rejected Suggestions` record is unchanged. New
  SKILL.md `## Review History Files` section defines the convention;
  main-agent.md's design/implementation workflows and the plugin's own
  design doc are updated to match, and "discovered during implementation"
  entries now update the design's `## Testing Plan` to its new final state
  while the history entry goes to the review-history file.

- Detect terminal-but-unharvested subagent roles as a mitigation for dropped
  subagent-completion notifications. When a role reaches a terminal state
  (clean DONE or adjudicated FINALIZED) but the main agent stays idle since it
  completed — the symptom of a completion notification that never arrived, with
  the result already on disk — the watchdog layers now flag it instead of
  silently skipping every terminal instance. **L4 stop-gate (`stop-gate-main.sh`,
  primary):** synchronously blocks the idle attempt during an active phase,
  names the completed role and where its result lives, and instructs the main
  agent to read and record it before idling; the block is satisfiable and
  self-clearing (any tool call or status write clears it), honors
  `stop_hook_active`, and shares the existing `runtime/nag/stopgate.last`
  cooldown. **L3 watchdog (`monitors/watchdog.sh`, backup):** the instance loop
  no longer blindly skips terminal instances; a new `unharvested` scan emits one
  rate-limited wake line (own `runtime/nag/watchdog-unharvested-<key>.last`
  cooldown) for the case L4 cannot catch — the role going terminal after the
  main agent already idled. The predicate (`terminal` AND
  `main_heartbeat_epoch <= terminal_epoch` AND `status.md` mtime
  `<= terminal_epoch`) `isinstance(int)`-guards every epoch so a missing value
  skips the instance rather than throwing and aborting the shared loop. Adds a
  read-only, additive `terminal_epoch` field to the fixed-pack observer
  (`runtime_state.py hook-observe`), surfaced on all three terminal paths. This
  is a **mitigation**, not a root-cause fix of the harness notification-delivery
  layer (out of a plugin hook's reach); L4 is primary because it does not ride
  the completion channel that drops events. **Linux-only:** like the dead-role
  scan, the detection is inert on macOS where the observer returns
  `genesis-capability-unavailable`.
- Probe update errors now distinguish malformed challenge syntax
  (`invalid-probe-id`, exit 2) from a syntactically valid but non-current
  challenge (`probe-mismatch`, exit 4), giving callers a stable
  machine-readable validation boundary.
- Resolve standalone execute-task issues #7–#10 with hash-keyed role identity,
  distinct logical DONE/FINALIZED audit state in fixed packs, explicit reconnect
  challenge/ACK, bounded multi-lane `Waiting On`, incremental-output contracts,
  and content-sensitive no-output observation. **Linux-only:** the fixed-pack
  layer requires `statx(STATX_MNT_ID)` mount identity; on macOS it fails closed
  as `genesis-capability-unavailable`, all hooks stay fail-open, and L3/L4
  dead-role detection is disabled (see hooks/README.md `## Degraded
  environments`).
- Add the supported `agent-runtime-state.sh` interface, persistent advisory-lock
  carriers, fixed-slot transition journals, terminal-first hook/watchdog
  consumers, the bounded public `gc-step`, validated runtime bounds, and a
  15-second SubagentStart budget (host timeout raised to 20 s for margin).
- Read Claude Code's `tool_use_id` (falling back to Codex's
  `tool_call_id`/`call_id`) so the fixed-table INFLIGHT feature works on both
  runtimes, add a dispatch grace period before non-armed/stale role instances
  can block the main-agent stop gate or page the watchdog, and align the
  PostToolUse heartbeat timeout with PreToolUse.

## [0.17.0] — 2026-08-10

### Added — full Codex runtime compatibility

- **Dual-runtime worker lifecycle.** New `scripts/orch-agent-runtime.sh` detects Claude Code or Codex, renders runtime-specific launch/resume commands, and discovers Codex sessions from rollout metadata. Spawn, reuse, and check helpers now persist generic runtime/PID/session fields while retaining the legacy Claude aliases for backward compatibility.
- **Real Codex orchestration.** Codex workers can launch in tmux, pass the directory trust prompt, bind their session and transcript, resume after interruption, reuse existing worker containers, and receive an absolute `execute-task` Skill fallback when slash commands are unavailable.
- **Codex-aware MCP isolation.** Interactive Codex does not accept Claude's MCP flags or `codex exec --ignore-user-config`; the worker helper now snapshots enabled Codex MCP servers and emits per-server `enabled=false` overrides for the default isolated mode, failing closed if that snapshot cannot be obtained.
- **Codex hook and watchdog support.** Hook commands resolve `CODEX_PLUGIN_ROOT`, orchestrated `ZYZ_PLUGIN_ROOT`, or legacy `CLAUDE_PLUGIN_ROOT`; payload parsing accepts Codex tool fields; synchronous heartbeat and detached SessionStart watchdog paths cover the Codex host's current lack of Claude-style async monitor wake-ups.
- **Codex adaptation test suite.** `scripts/test-codex-adaptation.sh` covers runtime selection, command rendering, MCP policy, session/transcript binding, recovery output, plugin-root resolution, and an opt-in real Codex/tmux/hook smoke test.
- **Documentation and templates.** Runtime selection, generic dispatch fields, recovery behavior, Codex limitations, worker startup, and cleanup guidance now describe both Claude Code and Codex.

### Fixed — issue #6: `git checkout` on a shared worktree destroyed another agent's uncommitted work

Real incident (2026-08-06): several subagents shared one worktree; an audit agent reverted its throwaway mutation with `git checkout <file>` — which resets to HEAD — and deleted another agent's uncommitted work in that file (~5000 chars of security-guard code plus supporting edits). The damage class is uniquely nasty: never-committed content is in NO git recovery mechanism (no reflog, no stash, no `fsck --lost-found`), and `go build` stayed green because the loss sat behind a runtime type-assertion seam — had that seam been written "skip if absent", the accident would have become a silent security bypass. Recovery succeeded only by replaying the author agent's transcript (`tool_use` inputs hold everything ever written, verbatim).

- **New L6 hook `hooks/scripts/checkout-guard.sh`** (PreToolUse on `^Bash$`, sync): denies `git checkout` / `git restore` whose target currently has uncommitted modifications (`git status --porcelain` decides — clean files, branch names, `-b`, and untracked paths all pass), and the state-moving `git stash` forms (bare/push/save/pop/apply/drop/clear; `list`/`show` pass). The deny reason carries the safe recipe. Same policies as every other layer: applies only when a task pointer resolves (general sessions keep full git freedom), fails open on malformed input / missing parser / non-repo cwd, argument scanning stops at the first shell metacharacter (a following command's words are never misread as targets), and `ZYZ_CHECKOUT_GUARD_DISABLE=1` disables just this guard — parsing shell with shell is heuristic, so the escape hatch is mandatory.
- **Mutation-restore discipline rewritten** in implementation-agent and review-agent (both mirrors), SKILL Role Boundaries, and the review-report template: restore from a **backup copy taken before mutating** (`cp` → `mv` → per-file `cmp`), never via git revert commands. The verification criterion changed too — the old wording said restore until "`git status` clean", which on a shared worktree is a goal that INVITES a checkout, because other agents' legitimate in-flight edits mean status is never clean. "Byte-identical" now explicitly means identical to your own pre-mutation copy, not to HEAD.
- **Both Version Control prohibition lists** extended: `git checkout <file>` / `git restore <file>` on a shared working tree are destructive in the same class as `git stash push/pop`; alternatives spelled out (`git show HEAD:<file>` for read-only, own-diff `git apply -R` for set-asides).
- **Transcript recovery documented** (`SKILL.md ## Resuming An Existing Task`): everything an agent ever wrote is recorded verbatim in its transcript jsonl (`Write.input.content`, `Edit.input.new_string`); recovery = identify the author agent, extract its edits for the lost file, replay in original order — never rebuild from memory, because a subtly-wrong rebuild of guard/adjudication/redaction code is a silent bypass, worse than the visible absence. This is the path that recovered the incident's lost function verbatim.
- **Isolation guidance** in §3.0.3: a lane that temporarily modifies production files (mutation testing, refactor probes) gets its own worktree (`isolation: worktree`) or runs while no other lane has uncommitted work in the files it will touch — its revert step is the single most dangerous write on a shared tree.
- **T12 group** in `scripts/test-watchdog-hooks.sh` (suite now 117): the accident's exact command shape plus five deny variants, seven ordinary-git allow cases, compound-command target isolation, the no-pointer no-op, the per-guard disable, and fail-open. Mutation-tested: removing the porcelain check reds the checkout denials; removing the stash branch reds the stash denials.

## [0.16.1] — 2026-08-03

### Fixed
- **The unarmed-watchdog warning cried wolf in ordinary sessions.** 0.16.0 paired two changes that interact badly: the monitor is armed `when: always` (so it starts in *every* session), and it reported any pointer-resolution miss. In a session that simply is not running `execute-task` — the overwhelming majority — that produced `NOT ARMED: … dead subagents will NOT be reported and the idle gate will NOT hold`, which is alarming, useless, and self-defeating: a warning that fires in normal use trains people to ignore the one that matters. Observed immediately after installing 0.16.0 in this repo, which has 14 finished task directories and no active pointer — the correct state for a repo not running a task.
  The report is now gated on a task **plausibly existing but unresolvable**: some `.zyz-worker/tasks/<id>/` present with a `status.md` whose phase is not `done`. A repo with no task directories, or one whose task directories are all finished, stays silent; the genuine issue-#5 case (live task dir, pointer unreachable) still reports exactly once. Three T11 cases pin all of it, mutation-verified — removing the gate turns the two false-alarm cases red.
- **`grep -c … || echo 0` produced `"0\n0"`** in two test helpers. `grep -c` prints `0` *and* exits 1 on no match, so the fallback appended a second zero and the following `-eq` died with "integer expression expected" — the assertion broke precisely in the case it existed to detect. Found because it made three of the new T11 cases fail while reporting the value they wanted; fixed in `test-watchdog-hooks.sh` and in `test-orchestration-helpers.sh` T12 (latent there: one match today, but it would have failed the same way had the call ever disappeared).
- **Version bump 0.16.0 → 0.16.1** across the three manifests (codex build suffix regenerated); `EXPECTED_VERSION` aligned in the three test scripts.

## [0.16.0] — 2026-08-03

Four field-reported issues (#2–#5), each reproduced by execution before being fixed and pinned by a mutation-tested guard after. Two of them turned out to be the same defect seen from different ends: the watchdog layer was silently inert whenever a task ran in a git worktree (#5), which is also why nobody noticed the status file going a day stale (#4).

### Fixed — issue #5: the watchdog was silently inert whenever the pointer lived in a git worktree

`zyz_task_root` resolved `.zyz-worker/current-task` under exactly one base — the hook payload's `cwd`. The plugin's own `git-worktree` skill places worktrees *outside* the main checkout and deliberately does not `cd` into them, so a task run in such a worktree put its pointer where the session cwd could not see it, and **all six layers returned empty and no-op'd**: no `runtime/` was ever created, two dead subagents went unreported, and the idle gate let the main agent stop. Reproduced against the shipped scripts: the same payload creates `runtime/agents/main.heartbeat` with `cwd` set to the worktree and creates nothing with `cwd` set to the main checkout. Also confirmed as the mechanism behind issue #4's worst symptom — in #4's exact scenario (status.md a day stale) L1 stays silent and L4 allows idle.

- **Bounded fallback in `zyz_task_root`**, in order: the existing single-base hit (hot path, no fork, byte-identical on a hit) → `$ZYZ_TASK_DIR` if exported → sibling git worktrees of the same repo. Reducing a linked worktree to its main checkout already worked; main checkout → sibling worktree was the unreachable direction, and enumerating it is the only route that actually reaches the pointer. Deliberately **not** an unbounded upward walk: the default layout's ancestor chain climbs through `$HOME/.zyz-worker`, where one stray pointer would capture every session under `$HOME`.
- **Ambiguity handled explicitly.** Candidates are ordered newest-first by `status.md` mtime, because `git worktree list` is path-ordered and first-hit-wins would otherwise pick by alphabetical accident; tasks whose phase is `done` are skipped, since pointers are never deleted anywhere in this plugin and stale ones accumulate with worktree count. Residual risk stated rather than hidden: two genuinely concurrent runs in one repo can still attach to the wrong task, so every fallback hit appends to `<task-dir>/runtime/task-root-fallback.log` — a wrong reminder is more confusing than silence, so it must at least be diagnosable.
- **"Unarmed" is now visible.** This is the deeper defect: an inert layer and a healthy quiet one were externally identical, which is how a whole task ran unprotected. `monitors/watchdog.sh` now reports a resolution miss **once** (not per tick), naming the base it probed and stating plainly that dead subagents will not be reported and the idle gate will not hold. The report is gated on a task plausibly EXISTING (some unfinished `.zyz-worker/tasks/<id>/` present) but unresolvable — because this monitor is armed `when: always` and therefore starts in every session, the ungated version fired in ordinary sessions that never ran `execute-task` (observed immediately after install). A warning that cries wolf in normal use is worse than none: it trains people to ignore the one that matters. `SKILL.md` §1 step 4 and the main-agent prompt now require confirming `<task-dir>/runtime/agents/main.heartbeat` exists after a few tool calls (the heartbeat is async, so not on the first), and saying so if it does not.
- **Docs de-ambiguated.** "at the project root" is gone from both loaded documents: the pointer belongs under the **session cwd** (what hooks receive as `cwd`), and if the task dir is not under it, the pointer's contents **must** be an absolute path — a bare id resolves against the pointer's own directory and cannot cross trees. `git rev-parse --show-toplevel` returns the *worktree* root inside a linked worktree, which is exactly why the phrase misled. `skills/git-worktree/SKILL.md` now states that creating a worktree does not move the watchdog's anchor.
- **T10/T11 guards** in `scripts/test-watchdog-hooks.sh` (suite 90 → 96). Every prior fixture wrote the pointer into the same directory it then passed as `cwd`, so the split-base case had no coverage and the missing-pointer no-op was pinned as the only outcome. T10 pins cross-worktree resolution, newest-wins over alphabetical order, `done`-skipping, and that a total miss still yields empty + rc 0 (fail-open preserved). T11 pins the once-only unarmed report. Mutation-tested: removing the fallback or the `done`-skip turns them red.
- **Rejected one claim from the report after testing it.** Issue #5's "another small problem" said `monitors.json` interpolating an unset `${CLAUDE_PROJECT_DIR}` yields an empty `$1` that defeats `${1:-default}`. It does not — `${1:-word}` substitutes when `$1` is unset **or** empty (`${1-word}` is the form that distinguishes them), verified across all nine arg/env combinations. I had briefly "confirmed" this from a misread of my own test output; the mutation test caught it, and the original one-liner is kept with a comment recording why it must not be "fixed". The T11 case now guards the genuinely-broken `${1-word}` variant instead.

### Fixed — issue #4: stale `status.md` made a resumed session misjudge where the work stopped

A 9-SubTask task's main status file froze at "ST1 coded" while all nine SubTasks were implemented, tested, reviewed and pushed; individual `subtasks/*.md` advanced further and one contradicted itself. A resuming session read the main file first, concluded the work was still around ST1–ST5, and had to reconstruct the real interruption point from `git log` plus transcripts — after which every status conclusion needed re-verification. Worse, a still-running subagent left no trace in any status file, so recovery nearly re-dispatched it into the same workspace as the live one (two agents writing the same files); only a process-list and mtime check prevented it.

- **Transitions write through.** §3.B step 6 now states that flipping any `Coded`/`Tested`/`Reviewed` bit is not complete until the **main** status file is written — not batched, not reconciled later, not only in the SubTask file. Mirrored in the main-agent prompt. Two-layer drift (main frozen, SubTask files advancing) is the specific shape that makes recovery expensive, because the main file is what a resuming session reads first and everything downstream inherits its error.
- **New `## Resuming An Existing Task`** section: cross-check the status file against sources that advance by themselves before trusting it — `git log`/`git status` (commits are written by the work itself and cannot lag), `subtasks/*.md` versus the main file, and `runtime/agents/*.heartbeat` to separate "died and lost its work" from "still running". Conflicts are reconciled into the main file immediately, with reconstructed parts marked as such.
- **The live-agent registry the issue asked for already exists** — it is the L0 heartbeat layer, which was inert for exactly the reason issue #5 documents. With #5 fixed, `.start` without `.done` plus an advancing heartbeat *is* the "this role is alive, do not re-dispatch" signal; an absent `runtime/` now means "the watchdog never armed", which the layer itself reports rather than leaving to inference.
- **New `## Status Freshness`** block in the status template (`Updated At`, `Reconciled From Code At`, `Fields Reconstructed From Code`, `Known Divergences`) plus pre-delivery items 18b/18c, so a later reader can tell which entries were recorded live by the actor that did the work and which were rebuilt afterwards.

### Added — issue #2: worker MCP isolation (`ZYZ_WORKER_MCP`)

Every worker is a full `claude` process, and stdio MCP servers spawn per process — they cannot be shared. Workers inheriting the host's global `mcpServers` therefore re-pay the host's entire MCP memory baseline each (measured: ~745 MB/worker for one lark-mcp, ~695 MB of it private per smaps_rollup; 11 workers ≈ 8 GB), for tools most execute-task work never touches. This is the memory-axis sibling of the `ZYZ_GO_BUILD_P` disk-I/O fix: `workers × MCP baseline`, and the knob is the inheritance policy, not the worker count.

- **`scripts/orch-worker-mcp-args.sh`** — prints the MCP-isolation CLI args from `ZYZ_WORKER_MCP`: `none` (default) → `--strict-mcp-config` (worker gets ZERO MCP servers); `inherit` → nothing (legacy full inheritance); `<config-path>` → `--strict-mcp-config --mcp-config '<path>'` (exactly that JSON's servers — the shared-server hook). An invalid path fails CLOSED to `none` with a stderr warning, never silently open to full inheritance; `~/` expands; single quotes rejected (launch-command quoting).
- **`dispatch.md` gains `worker-mcp-args:`** (Phase-1, may be legitimately empty for `inherit`): spawn and reuse snapshot the policy once at container build time; the L2 driver appends it verbatim to the `claude` launch command; `orch-check-worker.sh`'s Phase-2 rewrite preserves it and embeds it in the generated `--resume` recovery command — so a crash-resumed worker keeps the same MCP policy instead of silently re-inheriting everything.
- **⚠️ Behavior change (breaking):** workers no longer inherit the host's MCP servers by default. A task that needs the host's MCP tools must set `ZYZ_WORKER_MCP=inherit` (or point at a scoped config). README documents the shared-server security boundary from the issue thread: no TCP even on 127.0.0.1 (any local user can drive the credential-bearing server), sockets under `$XDG_RUNTIME_DIR`-style 0700 dirs, credentials via `--config <0600>`/env — never argv (`ps`-visible) — and prefer installed binaries over `npx` wrappers (~47 MB/worker of wrapper processes).
- Orchestrator prompt's resource caveat is now quantified (peak ≈ workers × (claude ~500MB + Σ stdio-MCP baselines)) and names the right knob. T8 gains two assertions: `worker-mcp-args` key present, and default policy renders `--strict-mcp-config` (spawn env sanitized so the assertion tests the default, not the caller's env). `test-e2e-layered.sh`'s launch command consumes the snapshot like the real driver.

### Changed — issue #3: 21 process gaps from the 20-agent / 9-SubTask field run

The core insight from the field report: **"ran" ≠ "tested"** — every silent no-op assertion found that round was found by mutation injection, none by careful reading; and a failing verification TOOL produces output that looks exactly like a failing SYSTEM. All 21 items applied across both prompt mirrors (`agents/` + `subagents/`, byte-equal), the SKILL, the main-agent prompt, and the four templates:

- **P0-1 `Tested: true` redefined**: tests pass AND every claimed-covered mechanism has a recorded killed mutation. test-agent authors a `## Mutation Manifest` (mechanism → mutation → cases expected red); implementation-agent executes it (KILLED/SURVIVED per entry, tree restored byte-identical) — the "test-agent must not run tests" boundary is preserved by splitting authorship from execution. Templates carry `Mutations:` / `Mutation evidence:` fields.
- **P0-2 Mutation reachability** (new implementation-agent section): positive evidence the mutation reached the code before interpreting red/green; full process-group kills + port-vacancy polls + no-stale-binary rule for restarts; non-production write paths pair with production invalidation (advance seq / emit event / clear key).
- **P0-3 Coordinates + leases**: every green carries command / test DB / port group / process-vs-source freshness (a green without coordinates is not delivery evidence — judged `changes-requested` on that ground alone); new SKILL §3.0.3 mandates per-lane port-group + test-DB leases at ≥2 lanes, recorded in the new status `## Parallel Resource Leases` table with a single generated-artifacts owner per batch.
- **P0-4 Verdict hygiene** (new implementation-agent section, five mechanical rules): pipeline exit codes from the judged segment (no `cmd | head && echo OK`); no grep-as-success-proof, totals cross-checked; executed-count vs baseline on every `ran:`; read the matched lines behind any grep count; no shell-builtin variable names, failure messages keep raw values.
- **P0-5 Third attribution bucket**: failure attribution ordered change-surface → tooling → concurrent-edit/environment → real regression, replacing the two-bucket forced choice in all three places it appeared; "a rerun proves flaky, only the change surface proves not-mine"; mtime observation or owner confirmation before blaming another lane; stop-loss after the second failed hypothesis-fix.
- **P0-6 Assertion shape rules** (new test-agent section): expected values from independent recorded anchors, never the code-under-test's own rule (the one defect class where more diligence makes assertions worse); templated ids equality-only; every classification arm violable; bidirectional guards.
- **P1-7 review-agent gains Bash**: may rerun checks read-only and inject throwaway complementary-surface mutations, must restore byte-identical and verify, must not leave edits; measured basis — read-only review's hit rate on no-op assertions was zero, and the author is otherwise the sole judge of their own verdicts.
- **P1-8 No-op assertion checklist** (eight forms, each answered with file:line evidence, batching banned) in review-agent + review-report template.
- **P1-9 "What these tests do NOT prove"** required in test-agent output and test-file headers (silence is an overclaim); new `## Which Layer Can Actually Catch This` decision rule — distinguishability of end states at this layer's observation granularity, harden observation before declaring untestable, executable guards at structurally untestable spots, explicit handover naming the capable layer.
- **P1-10 Finding ledger**: status `## Implementation Review` becomes a per-finding table (verdict+evidence / dispatched-to / landed / verified-by); adjudicated→dispatched→landed are three distinguishable states; accepted-but-undispatched is mechanically detectable; re-review requests scan the ledger first.
- **P1-11 Adjudication discipline** (new main-agent section + hard limit): code-level rulings need file:line + predicate; confirming the symptom ≠ confirming the intent ("would this change turn an existing assertion red?"); no handed-down code/SQL forms — state properties, let executing roles choose forms; downstream rejections verified like review findings.
- **P1-12 Freeze before review**: new §3.B step 3.5 — workspace-frozen declaration recorded (with file set) before review dispatch; review-agent records and re-checks mtimes/hashes, mid-review change voids the review; `Frozen At:` in the scoreboard.
- **P1-13 Continuation, not redo**: `## Long-Running Work` rewritten as inventory → resume-point → debris-cleanup (interrupted runs are assumed dirty; stable reproduction = dirty data, not race); `## Restart And Recovery Notes` becomes an append-only event list (the single-slot form could not hold one real run's six timeouts).
- **P1-14 Rule-wide sweeps**: once a finding establishes a rule, sweep all same-shaped sites and return the enumerated list (enumerate the outbound surface, don't recall handled instances); 3+ recurrences → make the wrong form inexpressible via signature change, designed together with its test-driving path.
- **P1-15 `## Weakest Link`** required in implementation-agent, test-agent outputs and the final report — the author's private knowledge of the argument's thinnest point becomes a mandatory field; review treats self-reported tool failures as credibility-raising.
- **P1-16 Shared-file hotspots ≠ serialization**: §3.0.2 no longer serializes on "two items write the same file" — assembly points get declared hotspots with per-lane insertion regions; §3.B step 8 gains the smallest-compilable-unit commit exception (a non-compiling intermediate commit breaks bisect/CI and costs more than deviating from one-SubTask-one-commit); `Committed:` accepts `shared:<sha> (STx+STy)`.
- **P2-17 Statistical tolerances**: criterion derived before results, actual deviation reported (not just "within tolerance" — the format that hides how close to the edge it ran), one reverse injection; the three prove different things and none implies another.
- **P2-18 Bucketing fixtures**: symmetric splits banned where wrong values can land right by chance (50/50 is everyone's default and the lowest-discrimination point); one ~1% narrow bucket; derivation written into the fixture comment so a later "simplification" can't silently destroy discriminating power.
- **P2-19 Guard lifecycle**: record the first real interception in the guard's comment (an interception-less guard reads as noise and gets deleted with its discipline); diagnostic failure messages survive the fix as forward pointers; source-scan guards hold "X says", not "nothing else says Y".
- **P2-20 `git stash push/pop` banned on shared working trees** (both prohibition lists + implementation-agent): another agent's stash may exist, and a conflicted `go.mod` still BUILDS while `go test` breaks at module parse — reading as "their code is broken"; replacement `git diff > patch` + `git apply -R`; bisection requires a clean-environment precondition.
- **P2-21 Test categories derive from the design's Testing Plan**: the fixed unit/e2e/regression/pressure enumeration becomes example slots in all five places it was hardcoded; user-named categories get their own registration line plus a structural-ceiling note — a fixed enum let a user's explicitly-not-skippable category pass the delivery gate silently.
- **Pre-Delivery Checklist** (the field run's live checklist, generalized): 26 items across test effectiveness / verdict hygiene / environment & coordinates / attribution & collaboration / scope & self-disclosure, answered item-by-item with evidence as a delivery gate (§4 step 4).

### Changed
- **Version bump 0.15.0 → 0.16.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.16.0 in `scripts/test-release-0-5-0.sh`, `scripts/test-clean-tmp-skill.sh`, and `scripts/test-watchdog-hooks.sh`.

### Upgrade notes
- **Breaking (issue #2):** workers no longer inherit the host's MCP servers. Set `ZYZ_WORKER_MCP=inherit` for tasks that need the host's MCP tools, or point it at a scoped config file. Default `none` gives each worker zero MCP servers.
- **Behavior change (issue #5):** the pointer belongs under the **session cwd**, not "the project root" — inside a linked worktree those differ. A task whose task dir is not under the session cwd must write an **absolute** path into the pointer. The new sibling-worktree fallback covers the common case, but it is a safety net, not a contract: with two concurrent runs in one repo it can attach to the wrong task (every fallback hit is logged to `<task-dir>/runtime/task-root-fallback.log`).
- **New expectation (issues #4/#5):** after a few tool calls, confirm `<task-dir>/runtime/agents/main.heartbeat` exists. Its absence means the watchdog never armed and no conclusion should rest on it; the monitor now says so once per miss instead of staying silent.

## [0.15.0] — 2026-08-03

Consolidation pass over the whole plugin after the rapid 0.5.0 → 0.14.0 run: an audit of prompts, scripts, hooks, and docs for inconsistency, contradiction, and dead weight, plus a single architecture document. Thirteen classes of real defects fixed — every one reproduced by execution before fixing and pinned by a mutation-tested regression guard after.

### Added
- **`docs/architecture.md`** — the plugin's architecture overview: what each skill / subAgent / script / hook is, its responsibility boundary, and the main operating principles (execute-task's four roles and hard boundaries, the six watchdog layers and why each exists, orchestration's three layers with the file-ownership table, the bash helper contracts, crash-recovery reasoning, the test strategy, and the coupling points that must be changed in pairs). Deliberately architecture-level, not exhaustive — per-file detail stays in the in-file contract blocks and the SKILL.md files. Linked from `README.md` and `docs/conventions/project-structure.md`.
- **`test-agent` mirror guard** in `scripts/test-orchestration-helpers.sh` T10. It was the one role pair of four with no `agents/` ↔ `subagents/` body-equality check, so a bullet added on one side could silently drift on the other.
- **`CONSOL` regression group** in `scripts/test-orchestration-helpers.sh` (7 checks; suite now 430) pinning the three highest-consequence fixes below so they cannot silently return: the `approved`-token boundary (`cleanup-approved` / `not-approved` must not clear the gate), heartbeat-threshold env validation (a malformed value must degrade, not exit 1), and worktree-numbering-gap refusal in all three reader helpers. Pure file reads, so the group runs unconditionally. Each guard was mutation-tested — reintroducing the original bug turns it red.
- **T9 group + a tightened T2 monitor assertion** in `scripts/test-watchdog-hooks.sh` (suite now 90) covering the four watchdog fixes plus the L1 single-nag rule. T2 previously grepped the `on-skill-invoke:` substring, so it passed for the broken bare form — it now parses the `when` value and explicitly *fails* a bare skill name, testing the arming rather than the string. T9 pins design-phase quietness (full classification table), the clearable dead-role marker (both the reason text and the deletion), locale-independent CJK length in both `en_US.UTF-8` and `C`, and exactly-one-L1-nag-per-tool-call.
- **T8 group** in `scripts/test-watchdog-hooks.sh` pinning `zyz_get`'s extraction shapes — plain string, nested path, absent key (must be empty), and the boolean the stop gates compare against the literal `"true"`. It is the single field-extraction path every hook depends on and it has two interchangeable backends; the guard was verified against both by disabling the `jq` path and confirming `python3` produces identical output.

### Fixed
- **The L3 background watchdog could never arm under a normal plugin install** (`monitors/monitors.json`). `when: "on-skill-invoke:execute-task"` is compared as an *exact* string against the emitted skill name, and a plugin-loaded skill emits the **qualified** form. Verified two ways: the 2.1.218 binary arms via `a.when === "on-skill-invoke:" + s`, and `~/.claude.json` `skillUsage` holds **both** `zyz-worker:execute-task` (plugin mode) and bare `execute-task` (project mode) — so no single `on-skill-invoke:` literal can cover both, and the shipped bare form armed only in project mode. The layer that `SKILL.md` bills as "the only one that catches API-error deaths" was therefore inert exactly where it matters. Switched to `when: "always"` (also verified supported in the binary: `s.when==="always"` arms at startup), which sidesteps the plugin-name coupling; `watchdog.sh` is itself gated on the `.zyz-worker/current-task` pointer, so arming it always is equivalent in effect and costs one sleeping process. My own earlier check of this layer was invalid — running `watchdog.sh` by hand validates the script's logic, not that Claude Code arms it.
- **The watchdog fired during the design phase, where both prompts promise silence** (`hooks/scripts/lib.sh`). `zyz_phase_active` matched `*review*`, which also matches `design review` / `designreview`. Verified: `Current Phase: Design Review` plus a stale status file made `stop-gate-main.sh` emit a block. The worst consequence is at §2 step 8 — the one gate the workflow mandates *waiting at indefinitely* for human approval — where the gate pushed the agent to act while the prompt said hold. Any phase naming `design` is now excluded first, before the active-phase patterns.
- **A dead role's block could not be cleared by complying with it** (`hooks/scripts/stop-gate-main.sh`, `stop-gate-subagent.sh`). The block reason said "mark it finished in the status file", but this gate reads only the runtime markers and never `status.md`; a `.start` was cleared solely by the `.done` that `SubagentStop` writes — and `SubagentStop` by design does not fire on the API-error death this gate exists to catch. Verified: the agent complied exactly as instructed and the gate re-blocked; only the cooldown or the platform's block cap escaped. Two changes: a clean `SubagentStop` now **deletes** the role's `.start`/`.heartbeat` (which also stops `runtime/` accumulating one marker triple per dispatch, since `agent_id` is fresh per dispatch), and the block reason now names the exact `rm -f` that clears a marker whose role really did finish.
- **L1 nagged the same invariant twice in one turn** (`hooks/scripts/status-freshness.sh`). `status-freshness.sh` and `post-agent-flush.sh` are both sync `PostToolUse` hooks reading the same status-file mtime with independent cooldowns, so on a stale-status Agent return both injected a "persist the status file" instruction into the same turn — verified, two near-identical `additionalContext` blocks. `status-freshness.sh` now defers when `tool_name` is `Agent`: `post-agent-flush.sh` owns that moment (its message names the just-received subagent result and says to persist it *before* dispatching further work, and its threshold is tighter). Every other tool call still gets the freshness reminder, so no coverage is lost — exactly one L1 nag per tool call now.
- **The L5 scope guard denied legitimate dispatches, including work on the guard itself** (`hooks/scripts/lib.sh`). Two independent causes, both verified by execution before fixing. (1) A prompt that *quotes* a capping phrase was read as *issuing* one, so "Add a test asserting that a dispatch saying \"limit to 3 findings\" is denied" and "Implement the L5 scope guard. It must deny prompts like \"only the top 3 findings\"" were both blocked — writing docs, tests, or changelog entries about this guard is routine in this repo, so the guard obstructed its own maintenance. Caps are now matched against a quote-stripped copy (`zyz_scope_strip_quotes`, handling `"`, backticks, and `'`); single quotes only open a span after whitespace or punctuation, so contractions like `don't be exhaustive` cannot pair up and swallow real text, and negation is still evaluated on the full text so a quoted negation keeps its veto. (2) The count-cap patterns accepted `items` as the capped noun and made the noun optional, so ordinary domain requirements matched: "the API should return no more than 3 items per page" and "the retry budget must cap it at 3 attempts". The noun is now required and limited to `findings|issues|problems`, so a cap must name a review deliverable. Known tradeoff, taken deliberately: a prompt that is *entirely* a quoted cap now passes — a dispatch whose whole body is one quoted string is not a plausible instruction. Patch authored by the hooks auditor; verified, mutation-tested, and applied here.
- **T7's fixture harness could pass vacuously** (`scripts/test-watchdog-hooks.sh`). `sg()` interpolated the prompt straight into a JSON string, so any fixture containing a double quote produced invalid JSON — the guard then failed open and the assertion passed for the wrong reason, which is exactly the shape the new quote-skip fixtures need. It now builds the payload with a real JSON encoder (falling back to raw `printf` only without `python3`), and all 23 pre-existing capped fixtures were confirmed to still deny through the escaped path before the new ones were added. T7's legitimate set grew 21 → 28 with the seven cases above; both halves of the fix were mutation-tested (reverting the quote-strip yields 4 false positives, restoring the loose `items` pattern yields 1).
- **The subagent exit gate blocked valid Chinese final reports** (`hooks/scripts/stop-gate-subagent.sh`). `${#var}` counts characters under a UTF-8 locale but bytes under `LC_ALL=C`, so the threshold meant two different things. Verified: a complete 45-character Chinese report scored 45 against the threshold of 80 and was blocked as "too short", though the same string is 135 bytes and the workflow explicitly supports Chinese output. Now measured in bytes (locale-independent), with the 80 threshold calibrated for them — ~80 ASCII characters or ~26 CJK characters, both genuinely too short. Verified across both locales, with short replies still blocked.
- **`cleanup-approved` cleared the `approved` merge gate.** `orch-merge-and-cleanup.sh` bounded its `approved` token with `[^a-zA-Z0-9_]`, a class that omits `-`, so `cleanup-approved` — and `not-approved` — satisfied the gate. Verified end-to-end: an entry whose `## Pending Merge Approval` held only `cleanup-approved` passed the gate (failing later at exit 11 instead of the gate's exit 10), meaning the narrower cleanup token alone could trigger merge + push + the terminal, immutable `state: completed`. `orch-merge.sh` already used the correct `[^a-zA-Z0-9_-]` class for its own `merge` token — the same idiom had simply drifted between the two. Now aligned, with the reason recorded inline so it cannot regress.
- **`orch-check-worker.sh` exited 1 on a malformed threshold env var.** `ZYZ_HEARTBEAT_STALE_SEC`/`ZYZ_HEARTBEAT_WAITING_USER_SEC` were read unvalidated (while the per-task `heartbeat-stale-sec` frontmatter override *was* validated) and reached an arithmetic context; under `set -u` bash treats a non-numeric value as a variable name and aborts with "unbound variable". Verified `ZYZ_HEARTBEAT_STALE_SEC=abc` → exit 1, a code this helper's contract does not define and the orchestrator has no branch for. Since L1 polls every active worker through this helper on every tick, one typo'd env var silently blinded the whole poll loop. Both knobs now fall back to their defaults.
- **`orch-cleanup-worker.sh --force` exited 128 silently where the contract promises 8.** The `git rev-parse --git-common-dir` result was assigned bare, so under `set -e` a failing call killed the script before the `[ -z "$main_repo" ]` check could report exit 8 — making that branch unreachable for the case it was written for. Verified: a worktree path that exists but is not a git work tree produced rc=128 with no stdout and no stderr at all. The `git status` probe two lines above was already `if`-guarded; the assignment now matches it and reports exit 8 with a diagnostic. (`orch-merge-and-cleanup.sh` has the same shape but is genuinely masked by an earlier git-status check that exits 11 — verified, left unchanged.)
- **Both merge helpers stranded the operator's checkout.** `git checkout "$BASE_BRANCH"` runs in the *main* repo with no save or restore, and the switch was absent from both scripts' documented side effects. Verified: a repo sitting on `my-feature-wip` was silently left on `main` after a successful merge. Both scripts now record each main checkout's pre-merge ref and restore it from an `EXIT` trap, so every exit path (success, conflict 12, push-failure 13) leaves the operator where they were; restore failures are non-fatal and never mask the real exit code.
- **Silent repo-set truncation on a worktree-numbering gap.** `orch-spawn-worker.sh` probes for numbering holes and rejects them with exit 5, but all four *readers* (`orch-merge.sh`, `orch-merge-and-cleanup.sh`, `orch-cleanup-worker.sh`, `orch-reuse-worker.sh`) simply broke at the first empty `worktree-N`. Verified on a 3-repo fixture whose `dispatch.md` had `worktree-3` but no `worktree-2`: `orch-merge.sh` merged only repo 1, skipped repo 3, and still printed `merge-status=success`. Each reader now runs the same gap probe as spawn and fails loudly — a reader must not be more permissive than the writer.
- **Single quotes in worktree/branch values broke out of every `tmux send-keys` payload.** Spawn validated worktree paths for `:` (the `ZYZ_WORKTREES` separator) but not for `'`, while every send-keys payload wraps these values in single quotes. `orch-build-env.sh` already rejects `'` in `ZYZ_GO_TMPFS_DIR` for exactly this reason; spawn now matches that guard for both worktree paths and branch names (exit 5 with a precise diagnostic). The values are user-written in their own master entry, so this is robustness rather than a privilege boundary.
- **`scripts/pack.sh`: false dirty-tree warning and an unreachable exit 4.** The warning claimed the zip "will reflect the git index, not HEAD"; verified false — `git ls-files` chooses *which* paths ship but `zip` reads each from the working tree, so an unstaged edit silently ships in a release archive. Wording corrected. Separately, the documented exit 4 (unparseable version) was unreachable: the inner `grep` fails on a version-less manifest and `pipefail` aborted the assignment first (verified rc=1, no message). Now exits 4 with its diagnostic as documented.
- **`fm_field` divergence across the orchestration helpers.** The frontmatter reader is copy-pasted into six scripts and the copies had drifted: `orch-spawn-worker.sh`, `orch-merge.sh`, `orch-merge-and-cleanup.sh`, and `orch-cleanup-worker.sh` lacked the absent/unreadable-file guard that `orch-check-worker.sh` and `orch-reuse-worker.sh` had. Without it `awk` exits non-zero on a missing file and, under `set -euo pipefail`, kills the caller instead of yielding an empty field. Not reachable today (every such call site is `[ -f ]`-guarded and `MASTER_ENTRY` is validated earlier with exit 4), so this was a latent trap rather than a live bug; all six copies are now behaviorally identical. `docs/architecture.md` records the copy-paste surface so the copies stay in lockstep.
- **Flaky T5 stop-gate fixture** in `scripts/test-watchdog-hooks.sh` (pre-existing, surfaced while verifying the L1 fix). Two cases assert on the gate's *dead-role* branch, but their fixture backdates `status.md` by exactly 20 minutes while the *status-stale* branch fires at age strictly greater than 1200 s — so whether the status-stale text also appeared depended on how many seconds the suite had been running. The result was green in isolation and red inside a longer back-to-back sweep (observed both ways). Those two cases now pin `ZYZ_STOP_STATUS_STALE_SEC` out of range so they test the role branch alone; the status-stale branch keeps its own dedicated assertions.
- **Stale TR-neg exit-precedence fixture** in `scripts/test-orchestration-helpers.sh` (the suite's one pre-existing failure). The case asserts that the tmux-dependent old-session-alive check is only reachable after the `tmux`/`git` dependency gate, but its fixture never created the old task's `dispatch.md` — so the newer (and correctly-ordered) tmux-free guard requiring the old pane coordinates fired first and returned 5 where the case expected 3. The fixture now supplies an old `dispatch.md` with `shell-pid` / `tmux-pane-id`, making it well-formed against *every* tmux-free precondition. `orch-reuse-worker.sh` was correct and is unchanged.

### Changed
- **Watchdog layer audited; no defects found, findings recorded as notes.** The six enforcement layers were checked for hook-contract correctness, deadlock, cost, overlap, reachability, and threshold drift — every claim verified by execution, not by reading. Results: the emitted JSON matches the platform shape for each event type (`PostToolUse`/`PreToolUse` hooks emit `hookSpecificOutput` with the matching `hookEventName`; the two Stop-family gates emit a bare `{decision:"block",reason}` with no event name, as that family expects); all seven hook scripts fail open with exit 0 on malformed JSON, empty stdin, and a missing `current-task` pointer; all three escape hatches work (`ZYZ_HOOKS_DISABLE`, `ZYZ_SCOPE_GUARD_DISABLE`, and `stop_hook_active`); both stop gates are bounded (each checks `stop_hook_active`, so at most one block per stop — no livelock); every documented `ZYZ_*` threshold matches its hardcoded default exactly (no drift); the L3 background monitor is reachable and was confirmed firing against a simulated stale role; and the apparent overlap between layers is a deliberate escalation ladder (status freshness 600 s advisory → 1200 s stop gate → 1800 s monitor wake; role liveness 900 s → 1200 s) rather than redundancy. `hooks/README.md` and `docs/architecture.md` now state these properties so they are not re-derived each time.
- **`zyz_get` caching documented as a dead end.** The per-tool-call hook cost comes from one `jq` process per field read. Memoizing `zyz_get` in a shell variable was implemented and then reverted: every call site is `x="$(zyz_get foo)"`, and command substitution runs in a subshell, so the cache dies before the next call — A/B measurement showed noise, not gain. `lib.sh`, `hooks/README.md`, and the architecture doc now record why, and point at the approach that would work (single-pass extraction inside the hook script). `heartbeat.sh` is already registered `async`, so only the sync `status-freshness.sh` sits in the agent's loop.
- **Doc inventory brought back in line with the shipped tree.** `README.md`'s repository-structure tree was missing six shipped files (both `orch-driver-agent.md` copies, `hooks/scripts/dispatch-scope-guard.sh`, `scripts/orch-build-env.sh`, `scripts/pack.sh`, and the `monitor.md` / `dispatch.md` templates); the L2 driver subagent — a whole architectural layer — appeared in no top-level doc. `subagents/README.md` listed three roles when four exist and now states the mirror contract. `skills/README.md` omitted the `prompts/` directory used by two of the four skills and now lists the current skill set. `docs/conventions/project-structure.md` now names the four `agents/` roles, `pack.sh`, and the L5 scope guard in its hooks description.
- **Helper list unified across the four docs that enumerate it.** `CLAUDE.md`, `commands/orchestrate-tasks.md`, and `docs/conventions/project-structure.md` each omitted a different subset (most often `orch-merge.sh`, which every doc but `README.md` dropped despite the gate step routing the `merge` token to it). All four now list the same nine helpers, and the command doc distinguishes `orch-merge.sh` (merge + push only) from `orch-merge-and-cleanup.sh` (legacy atomic path).
- **Approval-token documentation completed** in `CLAUDE.md` and `commands/orchestrate-tasks.md`. Both described only the legacy `approved` token, omitting `confirmed` / `merge` / `cleanup-approved` / `rejected:` and the invariant that the orchestrator mirrors the worker's `phase=done` into `state: completed` rather than writing it directly.
- **`status.md` filename documented as load-bearing.** All four watchdog consumers (`status-freshness.sh`, `post-agent-flush.sh`, `stop-gate-main.sh`, `monitors/watchdog.sh`) resolve the overall status file as `<task-dir>/status.md`, but no prompt said so — a differently-named status file left the L1/L3/L4 freshness layers silently inert. `skills/execute-task/SKILL.md` §1 step 3 and the watchdog-obligations list now state it.
- **L2 driver `intent` enum corrected in both mirrors.** `agents/orch-driver-agent.md` and `subagents/orch-driver-agent.md` opened by saying L1 dispatches the driver for two intents (`first-dispatch`, `intervene`) while the same files document four sections and the `## Inputs` line lists all four; the sentence now names all four dispatch reasons.
- **`worker-status-malformed=true` is now documented.** `orch-check-worker.sh` has been emitting it (worker-status.md present but fence-less, so every parsed field reads empty) while neither the script's contract, the SKILL, nor the orchestrator prompt mentioned it — a consumer-less signal. All three now describe it, including the trap it guards: all-empty fields are not the same as a genuinely idle worker, so `state:` must not be projected from them. The helper's contract also now documents that `heartbeat-status=missing` covers an unreadable mtime as well as an absent file, and that its threshold env vars are validated.
- **Missing `python3` no longer degrades invisibly** in `orch-check-worker.sh`. Session-id discovery is a `python3` one-liner whose absence is swallowed (`2>/dev/null || true`) — a deliberate fail-open, but it leaves `dispatch-bound` false forever and removes the `claude --resume` recovery path with no clue why. It now warns on stderr while keeping stdout a clean `key=value` report and the exit code 0.
- **`orch-reuse-worker.sh` exit-code contract corrected.** Its header listed "(worktree-scope) new session name already taken" in the tmux-free exit-5 class, but that check needs tmux, runs after the dependency gate, and exits 6.
- **Version bump 0.14.0 → 0.15.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.15.0 in `scripts/test-release-0-5-0.sh`, `scripts/test-clean-tmp-skill.sh`, and `scripts/test-watchdog-hooks.sh`.
- `scripts/test-rename-and-conventions.sh` regained the executable bit every other script in the repo carries.

## [0.14.0] — 2026-08-02

This release closes a **scope-degradation** hole observed in practice: when a role stalled, the main agent reduced what it asked for ("only the total verdict + the 3 most severe findings") so the role could deliver something. The existing Total Goal Fidelity rule did not catch it — that rule guards the user's stated goal and the overall deliverable, while a single role's asked-for scope is a different surface. A review that reported only its worst few findings then passed every downstream gate looking clean, carrying the unreported findings into delivery. Three layers now cover it: a named anti-pattern in the prompts, per-dimension review coverage registration (mirroring the aggregate-testing contract), and a dispatch-side hook that denies scope-capping instructions before they reach the role.

### Added
- **`## Recovering A Stuck Role: Never Trade Scope For A Delivery`** in `skills/execute-task/prompts/main-agent.md` (and a mirror subsection under `## Incremental Output` in `skills/execute-task/SKILL.md`): reducing PER-ROUND output volume is always allowed, reducing the TOTAL deliverable never is. Names the banned phrasings ("just the overall verdict", "only the top 3 findings", "一句话结论也行", "细节可以省") as forbidden in recovery/re-dispatch instructions, allows a capped installment only when the same instruction commits to the remainder, records the standard recovery recipe (same full scope, N labeled steps, one message per step, flush between), states why Total Goal Fidelity does not already cover this surface, and requires sending back a role that proposes or delivers its own reduced scope.
- **Review coverage-dimension registration** — the aggregate-testing per-category contract, applied to review. `skills/execute-task/templates/review-report.md` gains a `## Coverage Dimensions` section (design conformance / correctness / test quality / regression risk, plus one per risk the design `## Risks` calls out), each registered `covered` or `not-covered: <reason>`; an unregistered dimension means the review is not closed regardless of its verdict. Wired into `subagents/review-agent.md` + `agents/review-agent.md` (new `## Coverage Dimensions Are Registered, Not Optional` section + output format), `skills/execute-task/SKILL.md` §3.C step 2 and the §4 delivery gate (new step 3 — unregistered dimension blocks delivery), `templates/task-status.md` `## Final Aggregate Review`, and the main-agent prompt's Delivery section.
- **`hooks/scripts/dispatch-scope-guard.sh` (L5)** — `PreToolUse` hook on matcher `^Agent$`, sync. The only watchdog layer that inspects what a dispatch *asks for*; all others observe after the fact. Denies (via `hookSpecificOutput.permissionDecision: "deny"`, whose reason the model sees and can act on) a dispatch to a zyz-worker role whose prompt caps the deliverable AND carries no continuation commitment ("then continue with the rest", "step 1 of 4", "分维度", "register all dimensions"). Blocked attempts are appended to `<task-dir>/runtime/scope-guard.log`. Fails open, no-ops without the `current-task` pointer, ignores non-role dispatches; `ZYZ_SCOPE_GUARD_DISABLE=1` disables just this guard. New `lib.sh` helpers: `zyz_emit_deny`, `zyz_scope_cap_hit`, `zyz_scope_continuation`.
- **T7 test group** in `scripts/test-watchdog-hooks.sh` (suite now 84 checks): 23 scope-capping phrasings that must be denied and 21 legitimate dispatches that must pass untouched — the false-positive fixture covers negated instructions ("do not just report the verdict", "只要总结论是不够的"), `其余…随后` / `remaining … second pass` staging, and target-scoping ("review just the first SubTask") — plus non-role scoping, both disable switches, bare-vs-scoped role names, the deny JSON shape, the audit log, no-pointer no-op, and fail-open on malformed input. T6 gains doc-wiring checks for the new prompt rules, dimension registration, the final-report coverage lines, the per-SubTask flag condition, and staged-installment tracking.
- **Negation veto + count-cap patterns after independent review.** A review-agent pass on this change found the guard denied the very instruction L1 teaches ("do not just report the verdict — list every finding") and missed a whole family of count caps. Fixed: `zyz_scope_negated` vetoes cap matching when the prompt forbids truncation (English and Chinese; deliberately narrow on bare `不行` so the degradation idiom "实在不行就先给一句话结论" still denies), continuation now recognizes `其余…随后` / `剩余…后续` / `remaining … second pass`, `first` no longer treats target-scoping as output-capping, and the cap list gained `limit/cap/hold to N`, `no more than N`, `at most N`, `blockers/P0/high-severity only`, `don't be exhaustive`, `重点问题就行`, `挑最重要的几条`, `关键的几条就行`. All 44 phrasings are pinned as T7 fixtures.
- **Staged-installment follow-through.** The same review found the continuation exemption was trivially satisfiable — appending "then continue" with no intent passes the guard and reproduces the original bug. The prompts now require recording the step plan in `## Restart And Recovery Notes` and actually collecting every installment; `## Final Aggregate Review` gains an `Outstanding Staged Installments` field, and the §4 gate counts an outstanding installment as an uncovered dimension.
- **Review registration reaches the delivered artifact and the per-SubTask flag.** `templates/final-report.md` `## Review Result` now carries the per-dimension coverage lines (previously only test categories survived into the final report), and §3.B step 6 states that `Reviewed: true` requires a review that registered its dimensions — closing the path where a truncated per-SubTask review flipped the flag before §3.C ever ran.

### Changed
- **`hooks/README.md`** — third hardened rule documented ("recovery never shrinks the ask") plus the full L5 contract, including the note that phrase matching is heuristic by nature, which is why the continuation exemption and the per-guard disable switch exist.
- **`skills/execute-task/SKILL.md` `## Watchdog Enforcement`** — L5 added to the layer list; the `## Long-Running Work` restart rule and the main-agent prompt's monitoring bullet now say restarts happen at the same scope.
- **Version bump 0.13.0 → 0.14.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.14.0 in `scripts/test-release-0-5-0.sh`, `scripts/test-clean-tmp-skill.sh`, and `scripts/test-watchdog-hooks.sh`.

## [0.13.0] — 2026-08-02

This release adds a **watchdog enforcement layer** for the execute-task workflow: the two long-standing prompt-only rules — "the main agent must notice and restart silent/dead subagents" and "status files must be created and kept current" — are now backed by deterministic mechanisms (Claude Code plugin hooks + a background monitor) instead of relying on model compliance. Liveness becomes an automatic side effect of tool calls; stale status triggers injected reminders and stop gates; dead roles (including subagents killed by API errors, where `SubagentStop` never fires) wake the main agent via a background watchdog. All layers fail open, no-op without a `.zyz-worker/current-task` pointer, and can be disabled with `ZYZ_HOOKS_DISABLE=1`; prompt-level duties remain in force as the fallback for degraded environments (managed-policy hook blocks, platforms without monitors).

### Added
- **`hooks/hooks.json`** — plugin hook registrations (active in any session with the plugin enabled): L0 heartbeats (`PreToolUse`/`PostToolUse`, async), L0 dispatch tracking (`SubagentStart`), L1 status-freshness reminders (`PostToolUse` sync, `additionalContext` injection), L1 post-subagent-result flush reminder (`PostToolUse` matcher `^Agent$`), L2 subagent exit gate (`SubagentStop` block on empty/too-short final message), L4 main-agent stop gate (`Stop` block while a dispatched role looks dead or the status file is badly stale during an active phase).
- **`hooks/scripts/`** — `lib.sh` (shared helpers: JSON extraction via jq/python3, atomic writes, task-root resolution through the `current-task` pointer, stale-role scanning, cooldown stamps), `heartbeat.sh`, `subagent-track.sh`, `status-freshness.sh`, `post-agent-flush.sh`, `stop-gate-subagent.sh`, `stop-gate-main.sh`. All macOS bash 3.2 + Linux compatible; every script fails open (exit 0 on any missing input/parser/write error) so the watchdog can never break the workflow it protects. Runtime bookkeeping lands under `<task-dir>/runtime/` (`agents/*.heartbeat|.start|.done`, `nag/*.last`); `.start` + no `.done` + stale heartbeat = dead-or-stuck role. Thresholds tunable via `ZYZ_*` env vars.
- **`monitors/monitors.json` + `monitors/watchdog.sh`** — L3 background watchdog, started on the first execute-task invocation per session (`when: on-skill-invoke:execute-task`). Scans heartbeats and status mtime every 60s (default) and emits one rate-limited notification line per finding — "role X silent N min with no clean finish" / "status file N min stale" — delivered to the main agent, able to wake an idle session. This is the layer that catches API-error-killed subagents. Its role threshold (`ZYZ_WATCHDOG_ROLE_STALE_SEC`, default 1200) is deliberately above the L4 gate's, and its message asks the main agent to VERIFY rather than blindly restart, since L3 cannot cross-check `background_tasks`.
- **`skills/execute-task/SKILL.md` `## Watchdog Enforcement`** — documents the five layers (L0 heartbeats, L1 reminders, L2 exit gate, L3 watchdog, L4 stop gate), the main agent's obligations (write the `current-task` pointer at §1 Start Task; treat `[zyz-worker watchdog]` messages as actionable instructions; keep `Current Phase` accurate), and degraded-environment behavior. §1 Start Task gains the pointer-file step.
- **`scripts/test-watchdog-hooks.sh`** — 63-check static + smoke suite (layout/exec/syntax, manifest validity and registrations, sandboxed behavioral tests of every hook including block/allow/cooldown/no-pointer/disable paths and scoped-vs-bare `agent_type` normalization, doc wiring, three-manifest version consistency).

### Changed
- **`skills/execute-task/prompts/main-agent.md`** — new responsibilities: write/maintain the `current-task` pointer, act immediately on watchdog messages (re-dispatch the named role or flush status — never defer), keep `Current Phase` accurate at every transition.
- **`hooks/README.md`** — rewritten from placeholder to the full per-script contract documentation (trigger point, inputs, outputs, failure behavior, supported agents for each hook + the monitor).
- **`CLAUDE.md`, `README.md`, `docs/conventions/project-structure.md`** — watchdog layer and new `monitors/` directory documented; "hooks not yet implemented" notes removed.
- **`.gitignore`** — ignores local scratch paths (`tmp/`, `.orphaned_at`, `docs/superpowers/`) so the release surface stays clean.
- **Version bump 0.12.0 → 0.13.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.13.0 in `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh`.

## [0.12.0] — 2026-08-02

This release adds a **PR review handling** policy so the execute-task / worker main agent does not blindly accept external pull-request review feedback. When review results (comments, "changes requested", inline threads, or automated review findings) land on an actual PR, the main agent processes them one at a time and independently verifies whether each raised problem objectively exists. Findings confirmed to exist are fixed through the normal role/test/review gates and acknowledged on the PR; findings that do not hold are declined with a reasoned comment posted on the PR thread. No finding is silently ignored. This is distinct from the plugin's pre-existing internal review-agent loop.

### Added
- **New `## PR Review Handling (External Review Feedback)` section** in `skills/execute-task/prompts/main-agent.md`: do-not-blindly-accept posture, per-finding independent verification (one at a time), route confirmed findings to implementation-agent/test-agent, reject non-holding findings with a concrete reason posted on the PR via the platform CLI (`gh pr`/`gh api`, `glab mr`, or the repo tool), never silently ignore, escalate on Goals/Acceptance-Criteria impact or accept↔reject loops, and record every decision in the status file.
- **Mirror `### PR Review Handling` subsection** in `skills/execute-task/SKILL.md` under the Automatic Execution Policy.
- **New `## PR Review` section** in `skills/execute-task/templates/task-status.md` (PR reference, accepted findings with verification + change, rejected findings with disproving evidence + posted comment, escalated items) so external-review decisions are auditable and survive restart/handoff.

### Changed
- **`skills/orchestration-scheduling-task/SKILL.md` PR flow note** now points at the worker's PR-review-handling behavior and clarifies that a worker acting on PR feedback rolls `phase` back from `awaiting-confirmation`; only write `confirmed` once the resolved PR is satisfactory.
- **Version bump 0.11.0 → 0.12.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.11.0] — 2026-07-28

This release evolves the **`clean-tmp`** skill from an interactive-only `/tmp` cleaner into a **dual-mode (interactive / auto-unattended) cleanup skill with two new cleanup surfaces — Docker resources and language build/package-manager caches** (GitHub issue #1). Interactive mode (the default) keeps the inventory → user-confirms → delete contract unchanged; the new auto mode (`--auto` or explicit unattended authorization) replaces "wait for confirmation" with a tightened five-condition DELETE criterion (owner = current user, mtime > 48h, not protected, no open handles, positive allowlist match) plus a fixed four-block post-run report. The other three safety-contract rules (never wildcard-delete, never touch other users' files, uncertain → keep) are explicitly not relaxed in either mode, and NEEDS-YOUR-CALL items are always kept and reported in auto mode.

### Added
- **Auto (unattended) mode** in `skills/clean-tmp/SKILL.md`: a `模式判定` section (default interactive; `--auto` or an explicit "已授权自动执行 / unattended" prompt statement enters auto mode; vague wording never counts), a five-condition conjunctive DELETE criterion section with fail→keep direction stated per condition, and a fixed four-block `自动模式事后报告` section (deleted list with per-category totals, kept list with reason tags recent/in-use/needs-call/protected/not-on-allowlist, `quota -s`, per-root `df -h` before/after).
- **48-hour dwell threshold** for auto mode: files probed with `find "$p" -maxdepth 0 -mmin -2880`, directories probed recursively with `find "$p" -mmin -2880 -print -quit` (inner mtime; `-print -quit` short-circuit preserves find's exit status so probe failure stays distinguishable from "old enough"), with the mtime-not-atime rationale (atime unreliable on noatime mounts).
- **Cleanup surface A — Docker resources** (gated on auto mode / explicit authorization): `docker system df` pre-probe, `docker image prune -a -f` (with short-loop re-pull cost note), `docker volume prune -f` with accurate volume-protection semantics (volumes referenced by ANY existing container — including stopped ones — survive; risk exists only after the container itself is deleted) and the Docker ≥23 anonymous-vs-named prune scope note, a `--keep-volumes` exclusion-list path via `docker volume ls -q` + per-name `docker volume rm` (scope equivalent to `prune -a`, so the list must be complete or fall back), optional `docker builder prune -f`, daemon-unreachable → skip the whole block (marked, not a failure), and the rootless-docker `~/.local/share/docker` uid-quota motivation.
- **Cleanup surface B — build/package-manager caches**: a six-row tier table (Go build cache delete-over-threshold with `--go-cache-threshold` default `1G` / Go module cache never / pnpm store prune ok / uv cache clean ok / npm interactive-only / playwright browsers needs-your-call), each row gated on `command -v`, cache paths always queried from the tool itself (`go env GOCACHE` / `go env GOMODCACHE` / `uv cache dir`) so macOS paths are not silently missed.
- **`skills/clean-tmp/references/`** — two on-demand reference docs split out of the SKILL.md body: `macos-tmpdir-trap.md` (the `/tmp` → `/private/tmp` symlink trap and the physical-path fix) and `socket-liveness.md` (ss/lsof dual branch, `kill -0` EPERM-vs-ESRCH semantics, `lsof +D`).

### Changed
- **Safety contract rule 1 is now dual-mode** (interactive: inventory → confirm → delete; auto: inventory → tightened criteria → post-run report); rules 2–4 kept and explicitly marked as not relaxed in either mode.
- **Default keep-list expanded from 4 to 6 categories**: adds `vscode-*` / `code-<uuid>` (merged wording, verify-alive-before-delete) and `*.keep` (user-marked keep) to `claude-*` / `tmux-<uid>` / `mcp-*` / `ssh-*`.
- **Multi-user guardrails hardened** in the pitfalls section: never estimate your own usage with an owner-unfiltered `du -sk /tmp/*` (a shared-host lesson — other users' 30GB dirs get miscounted as yours), and the quota perspective (quota counts per-uid files filesystem-wide; assess with `quota -s` + owner-filtered du).
- **Trigger words extended** (frontmatter `description` + `## 何时加载本 skill`): 定期磁盘整理, 清 docker, 配额超了, quota 超限, 无人值守清理 / unattended / auto.
- **README skill bullet and repo-structure tree updated in lockstep** (dual mode + Docker/build-cache surfaces; `references/` files listed under `clean-tmp/`); `docs/conventions/project-structure.md` now cites `git-worktree` alone as the SKILL.md-only example and `clean-tmp` as a `SKILL.md` + `references/` on-demand-loading example.
- **Version bump 0.10.0 → 0.11.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **EXPECTED_VERSION aligned to 0.11.0** in both `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh`, and the clean-tmp test suite gains groups T7–T11 covering the new sections (those edits are made by test-agent; recorded here for completeness).

## [0.10.0] — 2026-07-22

This release makes **a single task spanning multiple repos default to one tmux session + one `claude` managing one git worktree per repo** (each repo on its own branch, with its own commits and push), instead of splitting a multi-repo task across sessions. The "one worker = one worktree" invariant is replaced by `each worker = 1 tmux session + n git worktrees (one per repo; n=1 for single-repo tasks) + 1 full claude process`. The "worker" concept and every contract identifier (the `orch-*.sh` script names, `worker-status.md`, `ZYZ_WORKER_STATUS_FILE`, the runtime-config block field names, stdout keys) are retained unchanged — nothing is renamed. Single-`source-repo:` tasks stay byte-for-byte backward compatible.

### Added
- **Multi-repo master-entry schema (numbered flat keys)** in `skills/orchestration-scheduling-task/templates/master-list-task-entry.md` and the SKILL.md frontmatter excerpt: additional repos are declared with `source-repo-2:`, `source-repo-3:`, … (numbering starts at 2, must be contiguous); the unnumbered `source-repo:` is the primary repo (its worktree is the pane cwd). `branch-N:` / `base-N:` / `worktree-N:` may override per repo and otherwise inherit (branch/base from the primary's resolved value; `worktree-N` from the sibling-directory layout). Fully backward compatible with a single `source-repo:` entry.
- **`orch-spawn-worker.sh` builds N worktrees (one per repo) + a single tmux session + 1 claude.** Default multi-repo layout is a **sibling-directory** convention: a shared parent `~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/` with each repo checked out under a directory named after the repo, so `go.work`-style `../<repo>` relative references resolve. Validation runs per repo (missing / non-absolute / non-existent / not-a-git-worktree, plus numbering gaps and worktree paths containing `:`) with `repo <N>`-prefixed diagnostics and exit 5; partial-failure rollback removes already-created worktrees.
- **New `ZYZ_WORKTREES` env** (colon-separated, primary first) exported by spawn for a multi-repo worker so `execute-task` knows its full worktree set; absent = single-worktree (legacy) behavior. The reuse in-band runtime-config block gains an optional `worktrees:` line carrying the same set for a reused multi-repo container.

### Changed
- **Per-repo merge / cleanup with fail-fast + idempotent re-run** in `orch-merge.sh` / `orch-merge-and-cleanup.sh` / `orch-cleanup-worker.sh`: the repo set is sourced from the task's `dispatch.md` resolved numbered field group (single-repo tasks fall back to the master entry), never from the master entry's optional numbered keys, so a multi-repo entry that omits `worktree-N`/`branch-N`/`base-N` is never silently reduced to repo 1. Merge is not cross-repo atomic — it checks all repos first, merges each in turn, writes `state: completed` only after every repo merges, and a re-run skips already-merged repos. gh-path idempotency probes existing PRs via `gh pr list --head <branch> --state all` (not `gh pr view`, which has no `--head`).
- **Container reuse hands over the whole worktree set** in `orch-reuse-worker.sh`: all `reuse-scope` values reuse the old task's entire worktree set (partial single-repo reuse is unsupported); the new `dispatch.md` inherits the numbered field group and the reuse-runtime-config block emits the optional `worktrees:` line.
- **`dispatch.md` numbered field group preserved across Phase-2 rewrites** in `orch-check-worker.sh` (`rewrite_dispatch_atomic`) so the fixed-field rewriter no longer drops `worktree-N` / `source-repo-N` / `branch-N` / `base-N`; both writers (spawn + reuse) emit the group as fully-resolved non-empty values.
- **The "one worker = one worktree" invariant replaced** by `each worker = 1 tmux session + n git worktrees + 1 full claude process` across the orchestration SKILL.md, `prompts/main-agent.md`, orchestration templates, `README.md`, `CLAUDE.md`, `commands/orchestrate-tasks.md`, `docs/conventions/long-running-state.md`, and `skills/git-worktree/SKILL.md`. The worker concept and all identifiers are retained — no rename, no migration. The isolation boundary is restated: workers never touch each other's worktrees (spawn enforces pairwise-disjoint worktree paths), while within a worker there is full write access to all of its own worktrees.
- **`execute-task` multi-worktree write rule** (in the execute-task SKILL.md + prompt, owned by a sibling change): a worker has full write access to every worktree in `ZYZ_WORKTREES` (or the reuse block's `worktrees:` line), and commits / pushes / delivery reports are listed per repo.
- **Historical non-goal noted, not rewritten**: `docs/design/initial-design.md` (2026-05-14) recorded "no multi-project orchestration" as a then-non-goal; that historical document is left unchanged — this release documents the evolution here.
- **Version bump 0.9.2 → 0.10.0** in `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.9.2] — 2026-07-13

This release hardens the design→implementation approval gate so the main agent never self-advances into implementation on user timeout, silence, or absence; it must wait for explicit user approval. The only exception is an explicit prior instruction that specifically authorizes skipping this gate (recorded verbatim to disk); generic trust/autonomy statements and bare goal statements do not count.

### Changed
- **execute-task gate wording hardened** in `skills/execute-task/SKILL.md` and `skills/execute-task/prompts/main-agent.md`: the design→implementation step is now an unconditional hard wait (WAIT indefinitely on timeout/absence, never self-advance); the Automatic Execution Policy's "final approval" escalation clause is reframed as a hard stop that cannot be satisfied-and-passed; the "proceed without asking" / "prefer continuing through non-blocking ambiguity" postures are explicitly carved out from this gate.
- **Skip exception narrowed and made auditable**: only an instruction explicitly authorizing skipping THIS gate qualifies; it must be recorded verbatim in the status file before self-advancing. A material change to the approved approach (Goals, Acceptance Criteria, Implementation Plan, architecture, or Files To Change) re-arms the gate and requires fresh approval.
- **Orchestrated mode**: a new hard rule requires flushing `wait-state=waiting-user` while holding `phase=design`, approving only via pane attach or a question-id'd `answer.md` (orchestrator never relays design approval), and recording the approval/skip to disk before `phase=implementation` so a resuming worker gates on the on-disk record, not `phase` alone. The phase-mapping implementation-dispatch row is annotated "on user approval only — never autonomous." No new `phase` enum value added.
- **New `templates/task-status.md` field** `Design Approval Record` under `## Design Review` to hold the auditable approval/skip record.
- **Version bump 0.9.1 → 0.9.2** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **EXPECTED_VERSION aligned to 0.9.2** in both `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh` (those two edits are made by test-agent; recorded here for completeness).

## [0.9.1] — 2026-07-13

This release adds guidance emphasizing that fix / repair / backfill / migration scripts must be validated locally on fabricated (synthetic) representative data before touching real data. The typical failure mode for such one-off data-mutating scripts is that their first run against real data is also their first test — a logic error there causes irreversible damage. The new guidance lands in the roles that write, test, and plan for these scripts, without becoming a hard delivery gate (it applies only when a task actually produces such a script).

### Changed
- **implementationAgent prompt** (`subagents/implementation-agent.md` + mirror `agents/implementation-agent.md`) gains a Responsibilities bullet requiring local fabricated-data validation of any data-mutating fix / repair / backfill / migration script (normal + boundary + error cases, verifying correctness and idempotency) before it counts as implemented; this validation is a temporary self-check cleaned up before delivery.
- **testAgent prompt** (`subagents/test-agent.md` + mirror `agents/test-agent.md`) gains a Responsibilities bullet to solidify that fabricated-data validation into repeatable tests/fixtures rather than leaving it as a one-off manual self-check.
- **`skills/execute-task/templates/design-doc.md`** Testing Plan gains a reminder (HTML comment) to plan fabricated-data validation for data-mutating scripts (what data to fabricate, how the repaired result is verified, idempotency / rollback considerations).
- **Version bump 0.9.0 → 0.9.1** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **`EXPECTED_VERSION` aligned to 0.9.1** in both `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh`.

## [0.9.0] — 2026-07-09

This release adds a new skill-only artifact **`clean-tmp`**: a cross-platform (macOS + Linux) skill for safely cleaning up the current user's leftover temporary files, adapted from a Linux-only source skill while preserving its full safety contract (inventory → user confirms → delete; never `rm -rf /tmp/*`; named deletion lists only; never touch other users' files; when uncertain, keep). Like `git-worktree`, it is skill-only (no slash command) and triggers via its `description`.

### Added
- **`skills/clean-tmp/SKILL.md`** — cross-platform safe temp-directory cleanup, skill-only like `git-worktree`. Adapted from a Linux-only source into macOS + Linux double-coverage: enumerates temp roots by `$TMPDIR` presence (not OS name) so both `/tmp` and macOS's per-user `$TMPDIR` (`/var/folders/**/T/`) are covered; POSIX inventory via `find -user "$(id -un)"` + `du -sk` (no GNU `-printf`); socket liveness via a dual branch (`ss -lxp` preferred on Linux, `lsof -nP` fallback on macOS/no-ss) with `kill -0` process-alive re-check (replacing Linux-only `/proc/$pid`); "holder undetermined → keep" default so live sockets are never silently deleted; a **root-relative default keep-list** (`claude-*`, `tmux-<uid>`, `mcp-*`, `ssh-*` protected under every enumerated root), correcting the source's false claim that the macOS tmux socket lives in `/tmp` — it is at `$TMPDIR/tmux-<uid>/`, which the repo's tmux-based orchestration workers depend on.

### Changed
- **Version bump 0.8.1 → 0.9.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **README skill enumerations updated in lockstep** — both the `## 当前状态` bullet list and the `## 仓库结构` ASCII tree now list `skills/clean-tmp/SKILL.md`; `docs/conventions/project-structure.md` notes `clean-tmp` as a `SKILL.md`-only utility skill.
- **New static-check test `scripts/test-clean-tmp-skill.sh`** added (macOS bash 3.2 + Linux compatible) verifying skill existence, frontmatter, three-manifest version consistency at 0.9.0, cross-platform/safety lint of the skill body, doc wiring, the CHANGELOG section, and a pack smoke test; `scripts/test-release-0-5-0.sh` `EXPECTED_VERSION` aligned to 0.9.0.

## [0.8.1] — 2026-07-03

This release enables **ultracode (dynamic workflow) in dispatched workers**: the orchestration-scheduling-task skill now launches each worker's `claude` with `--settings '{"ultracode": true}'` in addition to the existing bypass-permission flags, so every worker session runs with dynamic multi-agent workflow orchestration enabled.

### Changed
- **Worker launch command** is now `claude --plugin-dir <plugin-root> --permission-mode bypassPermissions --dangerously-skip-permissions --settings '{"ultracode": true}'` in all places that define it: the L2 driver's `first-dispatch` launch flow and `reuse-dispatch` restart-claude branch (`subagents/orch-driver-agent.md` + mirrored `agents/orch-driver-agent.md`), the L1 orchestrator dispatch-step description (`skills/orchestration-scheduling-task/prompts/main-agent.md`), and the e2e test's simulated launch (`scripts/test-e2e-layered.sh`).
- Recovery `claude --resume` commands are intentionally unchanged (they carry no permission/settings flags).
- **Version bump 0.8.0 → 0.8.1** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `scripts/test-release-0-5-0.sh` `EXPECTED_VERSION` aligned.

## [0.8.0] — 2026-06-26

This release adds **Go build I/O optimization injection** to the `orchestration-scheduling-task` skill. Many parallel workers each running `go build ./...` saturate a single disk because total compile parallelism ≈ (worker count) × (each build's `-p`, default ≈ NumCPU) and all link intermediates write to disk. Each dispatched worker now, by default, gets `GOTMPDIR` pointed at a tmpfs RAM disk and `GOFLAGS=-p=N` lowering per-build concurrency, injected into its pane before claude starts. Cross-platform with graceful auto-degrade (hosts without tmpfs, e.g. macOS, simply skip `GOTMPDIR`); never clobbers user env; never touches `GOCACHE`/`GOMAXPROCS`.

### Added
- **`scripts/orch-build-env.sh`** — a standalone, side-effect-free helper that reads three host env vars and prints ONE shell snippet to stdout (empty when disabled). It does NOT touch tmux; spawn / reuse call it and send-keys the line into the new pane. The emitted snippet bakes candidate values but runs its no-clobber (`[ -z "${GOTMPDIR:-}" ]` / `[ -z "${GOFLAGS:-}" ]`) and existence+writable (`[ -d ] && [ -w ]`, auto-degrade) guards *in the pane*; it `mkdir -p`s `GOTMPDIR` (Go does not auto-create it) and never emits `GOCACHE` or `GOMAXPROCS`.
- **Three tunable env switches** (read on the orchestrator host): `ZYZ_GO_BUILD_OPT` (default on; `0`/`false`/`off`/`no` disables all injection), `ZYZ_GO_BUILD_P` (the N in `GOFLAGS=-p=N`, default `4`, clamped ≤ 64 — illegal or over-cap values fall back to 4, because `-p` is the one knob that can silently re-detonate the I/O incident: total = workers × p), and `ZYZ_GO_TMPFS_DIR` (tmpfs base dir candidate, default `/dev/shm`; a value containing a single quote is rejected to keep the send-keys quoting intact). The probe is existence+writability, NOT a filesystem-type check — pointing it at a plain disk dir writes intermediates to disk (documented footgun).

### Changed
- **`orch-spawn-worker.sh` gains a Step 9b** that, after the `export ZYZ_*` send-keys, runs `orch-build-env.sh` and (if non-empty) send-keys the build-opt line into the pane — non-blocking: a missing/erroring helper yields an empty line and is simply skipped.
- **`orch-reuse-worker.sh` injects the same line in the `worktree` scope branch only** (new session / new pane / new claude, same shape as spawn). The `tmux` / `both` branches do NOT inject — they reuse an already-started claude whose env is frozen, and send-keys'ing shell into a live claude pane is harmful.
- README (new *Go 构建 I/O 优化注入* section: worker × p model, the three switches, auto-degrade, no-clobber, `GOCACHE`/`GOMAXPROCS` untouched, the existence-not-type probe footgun, the tmpfs-OOM risk with `watch -n5 'df -h /dev/shm; free -h'`, and a manual snippet for standalone users), orchestration SKILL.md (plan-step disk I/O caveat), `prompts/main-agent.md` (`## Inputs` env list), and `docs/conventions/project-structure.md` (helper list) updated in lockstep.
- **Version bump 0.7.0 → 0.8.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.7.0] — 2026-06-24

This release adds **container reuse** to the `orchestration-scheduling-task` skill: a new task can reuse a *completed* task's leftover tmux session and/or git worktree instead of building a fresh container.

### Added
- **`scripts/orch-reuse-worker.sh <new-task-id> <list-dir>`** — the reuse counterpart to `orch-spawn-worker.sh`. It reads the new task's master-entry `reuse-from` / `reuse-scope` / `reuse-claude` fields, validates the old task is `completed` in the same list with its container still present, associates the old tmux session and/or worktree per the scope matrix, creates the new task's own `runtime/<new-id>/`, writes the initial `worker-status.md` (phase=design), starts the heartbeat (in-pane daemon for `worktree` scope; a NEW window in the reused session for `tmux`/`both`), and writes the Phase-1 `dispatch.md` (incl. the four reuse fields and, for same-claude reuse, an attach-only `## Recovery` note). Like spawn it is container-only and NEVER starts `claude`. Exit codes mirror spawn's structure, with the 5-precondition split into tmux-free (validated before the tmux/git dependency check) and tmux-dependent (old session alive, after it).
- **Master-entry reuse frontmatter** `reuse-from` (a completed task-id in the same list), `reuse-scope` (`worktree | tmux | both`, default `both`), `reuse-claude` (`true` default | `false`, only meaningful when reusing tmux). Present `reuse-from` routes the dispatch step to `orch-reuse-worker.sh` + an L2 `reuse-dispatch` driver instead of `orch-spawn-worker.sh` + `first-dispatch`.
- **New L2 driver intent `reuse-dispatch`** (the intent enum is now `first-dispatch | intervene | relay-confirmation | reuse-dispatch`) with three branches: same-claude reuse (`reuse-claude-effective=true`, no new claude — sends an in-band runtime-config block + `/execute-task` to the already-running claude after a `capture-pane` readiness confirm), restart-claude reuse (`false` — exits the old claude, confirms a bare shell, relaunches, sends the block), and new-session reuse (`n/a`, `reuse-scope=worktree` — plain first-dispatch with the script-exported clean env, no block).
- **In-band runtime-config block contract in `execute-task` `## Orchestrated Mode`.** A reused, still-running claude cannot see re-exported env, so a `[zyz-worker reuse-runtime-config]` … `[/zyz-worker reuse-runtime-config]` block carrying `task-id` / `worker-status-file` / `question-file` / `answer-file` / `heartbeat-file` OVERRIDES the launch-time `ZYZ_*` env for the whole task lifecycle — including the `task-id` and ALL task-id-derived paths (the detailed `.zyz-worker/tasks/<task-id>/` status dir, commit/branch references). A reuse worker also `touch`es the block's heartbeat file on every flush.

### Changed
- **`dispatch.md` schema gains four Phase-1 reuse fields** `reuse-from` / `reuse-scope` / `reuse-claude-effective` / `heartbeat-window-id`. `orch-spawn-worker.sh` writes them empty (schema unification); `orch-reuse-worker.sh` populates them. `orch-check-worker.sh`'s `rewrite_dispatch_atomic` now reads back and re-emits all four (otherwise the first Phase-2 poll would drop them) and generates a **reuse-aware three-way `## Recovery` body**: same-claude reuse (`reuse-from` set AND `reuse-claude-effective=true`) gets an ATTACH-ONLY body (no independent `claude --resume`, because the session-id is the shared old+new session); plain spawn and independent reuse sessions (`reuse-claude-effective` ∈ {`false`, `n/a`}) keep the attach + `--resume` body.
- **`orch-spawn-worker.sh` pure-spawn semantics are unchanged** other than emitting the four empty reuse fields. It still builds only fresh containers, still rejects collisions (exit 5/6), still never starts claude.
- Orchestration SKILL.md (Core Rules, File Protocols, new `## Container Reuse` section, State Machine note, Crash Recovery reused-container subsection, Maintenance Notes lockstep) and `prompts/main-agent.md` (analyze reuse prerequisite check, dispatch reuse routing branch, gate-step shared-container cleanup warning, Failure Modes, and a Restart hard rule that a `reuse-from` worker is NEVER first-dispatched) updated for the feature. Templates (`master-list-task-entry.md`, `dispatch.md`, `monitor.md`, `worker-status.md`), README, CLAUDE.md, and project-structure.md updated in lockstep.

## [0.6.5] — 2026-06-22

This release **supersedes the 0.6.4 confirmation/done model.** 0.6.4 wrongly made the worker phase `awaiting-confirmation` an absorbing (non-reversible) terminal and removed the worker-level "done" exit entirely. That conflicted with the actual semantics (a worker awaiting confirmation is exactly the state most likely to roll back when the user asks for changes) and left standalone/worker-window confirmation with no terminal of its own.

### Fixed
- **`awaiting-confirmation` is now reversible.** 0.6.4 made it the sole absorbing phase; that was wrong. A worker that self-declared finished and is awaiting confirmation must be able to roll back (e.g. the user's review asks for changes → back to `implementation`).
- **Fixed the `in-progress` definition contradiction.** The orchestration state machine defined `in-progress` as "phase not awaiting-confirmation" while the projection rules projected `awaiting-confirmation` into a state — a direct contradiction. `in-progress` is now "worker in a working phase (`design`..`delivery`) with `wait-state=none`", and `awaiting-confirmation` projects to the new `awaiting-user-confirmation` state.

### Added
- **Worker phase `done` reintroduced as the sole non-reversible absorbing terminal.** It means the USER has confirmed delivery and is written ONLY after explicit user confirmation (worker-window direct, or relayed from L1) — never autonomously, never self-advanced from `awaiting-confirmation`. In standalone mode `phase=done` is itself the terminal.
- **New L1 state `awaiting-user-confirmation`.** The orchestrator projects a worker's `phase=awaiting-confirmation` into `state: awaiting-user-confirmation` (orchestrator-written, not in the user-writable set), distinct from `paused` (mid-task waiting on a Q&A/resource). A worker's `phase=done` mirrors to `state: completed`.
- **Dual confirmation channel, single source of truth (`worker phase=done`).** (A) The user confirms directly in the worker window → the worker writes `phase=done`. (B) The user writes the `confirmed` token in the master entry → L1 dispatches an L2 `orch-driver-agent` with `intent=relay-confirmation` to `send-keys` the confirmation into the worker pane → the worker writes `phase=done` → L1 mirrors `state: completed` on the next poll. L1 never writes `completed` directly from the `confirmed` token; `completed` always mirrors a `phase=done` (the legacy `approved` atomic merge+complete+cleanup remains a deliberate exception, since the worker is cleaned up). The relay is **idempotent** — at most one relay per confirmation, deduplicated via the worker's `monitor.md` `driver-intent`, re-armed only if the worker goes stale. The gate step is now the third L1 site that dispatches an L2 (alongside dispatch/`first-dispatch` and poll/`intervene`).

### Removed
- **`scripts/orch-confirm.sh` is retired.** It directly wrote `state: completed` on the `confirmed` token, which violated the single-source-of-truth invariant; the `confirmed` token now relays to the worker (which writes `phase=done`) instead. References removed from the README scripts tree, `orch-merge.sh`/`orch-merge-and-cleanup.sh` header comments, and the gate-step exit handling.

## [0.6.4] — 2026-06-22

### Changed
- (semantic-breaking) **`state: completed` is now decoupled from merge.** `completed` means user-confirmed delivery — the user wrote `confirmed` (or legacy `approved`) in the master entry `## Pending Merge Approval` section — and the task branch may or may not have been merged to base. This **supersedes** the 0.6.3 contract that "delivery is recorded as `state: completed` only after a successful merge" and that dependency unlock gates on `completed` (post-merge); merge is now a separate, independently-tokened action that may have happened, may happen later, or may never happen (e.g. PR-only or experimental branches). `completed` remains terminal and immutable; post-delivery changes go through a superseding new task.
- (semantic-breaking) **Dependency unlock is now AI-judgment-based, not "completed == merged".** When a `blocked-by` dependency reaches `completed`, the orchestrator judges each downstream task individually — whether the dependency's output is actually available (merged into the downstream task's `base`, or only living on the dependency's own branch) and which branch the downstream worktree should be based on. Downstream may chain off an unmerged dependency's branch by setting its `base:` to that branch, rather than basing on a stale `main`. The judgment and chosen base are recorded in the downstream task's `## Orchestrator Analysis`.
- **Worker may merge to base on explicit user instruction.** The `execute-task` Version Control rule gains an exception: on explicit user instruction (conversation in standalone mode, or a matching `## Pending Merge Approval` token in orchestrated mode), the worker MAY `git merge` the task branch into its base and push (still no force-push / no history rewrite). Autonomy never covers merge to base. In orchestrated mode the orchestrator performs the merge, not the worker, to avoid both layers writing the base concurrently.

### Added
- **`scripts/orch-confirm.sh <task-id> <list-dir>`** — marks `state: completed` on the `confirmed` token, without merging or cleaning up the worktree.
- **`scripts/orch-merge.sh <task-id> <list-dir> <base-branch>`** — merges the task branch into base and pushes on the `merge` / `merge: <base>` token, without changing `state` or cleaning up. Exit codes mirror `orch-merge-and-cleanup.sh` (12 conflict, 13 push-failed, etc.).
- **New `## Pending Merge Approval` tokens** `confirmed` (mark done, no merge/cleanup) and `merge` / `merge: <base>` (merge to base + push, no state change). Legacy `approved` is retained as the combined merge + completed + cleanup path and short-circuits any coexisting tokens this tick.

## [0.6.3] — 2026-06-22

### Changed
- (semantic-breaking) Worker `phase` state machine: removed the worker-written `done` phase; the furthest state a worker self-reaches is now `awaiting-confirmation` (self-declared finished, awaiting user confirmation). The real "done" = delivery is recorded by the orchestrator as master-entry `state: completed` only after a successful merge. Phase may now roll back among design/implementation/testing/review/delivery to reflect real iteration; only `awaiting-confirmation` is absorbing (never rolls back). Dependency unlock continues to gate on `completed` (post-merge) — a worker reaching `awaiting-confirmation` does NOT unlock downstream tasks. Post-delivery changes go through a superseding new task, never a re-open.

### Removed
- The `done` value from the worker `phase` enum (replaced by `awaiting-confirmation`).

### Fixed
- Orchestration cleanup/merge now actually remove `~/`-form worktrees: `scripts/orch-cleanup-worker.sh` and `scripts/orch-merge-and-cleanup.sh` quoted the `~/` strip pattern (`${WORKTREE#"~/"}`) so tilde no longer mis-expands and skips removal.
- Orchestrated-mode contract now requires `worker-status.md` to be valid YAML frontmatter wrapped in `---` fences; `scripts/orch-check-worker.sh` emits `worker-status-malformed=true` for a fence-less file so the orchestrator can diagnose it.

## [0.6.2] — 2026-06-21

### Fixed
- **Orchestration workers no longer fail at dispatch with `Unknown command:
  /execute-task`.** The L2 `orch-driver-agent` sent the bare slash command
  `/execute-task <task-id>` into the worker pane, but in current Claude Code
  (verified v2.1.153) plugin **commands** register namespaced-only
  (`/zyz-worker:execute-task`) while plugin **skills** register bare — and
  because `execute-task` ships as *both* a command (`commands/execute-task.md`)
  and a skill (`skills/execute-task/`), the bare `/execute-task` collides and
  never resolves. Every dispatched worker therefore rejected the command and the
  whole `orchestration-scheduling-task` pipeline died at its first hop. The
  driver now sends the namespaced `/zyz-worker:execute-task <task-id>` at every
  pane-facing point (first-dispatch send, intervene re-send, and the pre-launch
  "already-running" heuristic) in both `agents/orch-driver-agent.md` and its
  mirror `subagents/orch-driver-agent.md`; the Unknown-command *detection* and
  human-facing symptom strings are intentionally left bare. Found during
  real-claude e2e acceptance of 0.6.1.
- **`scripts/test-e2e-layered.sh` gains assertion A5**, which actually sends
  `/zyz-worker:execute-task <task-id>` into the launched worker and asserts the
  pane shows no `Unknown command` within the readiness deadline. The prior A1–A4
  only proved a worker could *bind* a claude session (via a "reply with PONG"
  round-trip); they never sent the real slash command, which is exactly why the
  command-registration break shipped green. A5 closes that acceptance gap (cost:
  one extra LLM round-trip per run).
- **`scripts/test-orchestration-helpers.sh` gains a deterministic guard (T9)**
  that requires the namespaced send token and forbids the bare send token in
  both driver mirrors, and asserts the "Send the command" line is byte-identical
  across them — locking the fix with no API/tmux/claude dependency.

## [0.6.1] — 2026-06-21

### Fixed
- **dispatch.md transcript binding now works for worktree paths containing a
  `.`** (including the default `~/.zyz-worker/worktrees/...`). The orchestrator
  computed `encoded-cwd` as `/`→`-` only, but Claude Code names its
  `~/.claude/projects/<dir>` by replacing BOTH `/` and `.` with `-` and
  squeezing consecutive `-`. So the check helper looked in the wrong directory,
  never found the transcript, `dispatch-bound` stayed `false` forever, and crash
  recovery was degraded. `orch-check-worker.sh` now discovers the transcript by
  its session-id (a globally-unique UUID) via `find ~/.claude/projects -name
  "<sid>.jsonl"`, which is robust regardless of claude's path-encoding rule. The
  `encoded-cwd` computation in `orch-spawn-worker.sh` is also corrected to match
  claude's actual rule so the recorded field (used for diagnostics and the
  recovery command) is accurate. Found during real-claude e2e acceptance of
  0.6.0.
- **`scripts/test-e2e-layered.sh`**: the readiness probe misread the
  bypass-permissions confirmation page's `❯ 1. No, exit` menu arrow as a ready
  prompt, so the page was never cleared and claude stayed stuck; a confirmation
  page is now never treated as "ready". The RESULT line also printed a wrong
  fixed denominator and now prints `N passed, M failed`.

## [0.6.0] — 2026-06-21

### Added
- **Per-task `dispatch.md` crash-recovery state file.** Each worker now records
  the binding between its tmux session/pane and its claude session-id +
  transcript path, so a worker (or its transcript) can be recovered after the
  tmux session, claude process, or orchestrator dies. `orch-spawn-worker.sh`
  writes Phase-1 (deterministic) fields; `orch-check-worker.sh` lazily fills
  Phase-2 (claude-side) fields and regenerates a `## Recovery` block with
  concrete `tmux attach` / `claude --resume … --plugin-dir …` commands once the
  worker has bound. A `## Crash Recovery` section in the orchestration SKILL
  documents the recovery flow and the underlying Claude Code session-file
  timing.
- **3-layer orchestration architecture.** The orchestration-scheduling-task
  skill is now an explicit L1 / L2 / L3 hierarchy: L1 (main agent) orchestrates
  and polls worker state inline (read-only, never touches a pane); a new L2
  `orch-driver-agent` subagent is dispatched on demand to do the heavy pane
  driving for one worker (start claude in bypass mode, clear the confirmation
  pages, run `/execute-task`, or intervene when stuck) and writes only
  `monitor.md`; L3 is the tmux + independent claude running `/execute-task`,
  invisible to the upper layers. User Q&A is never relayed upward — L1 only
  notifies "task X needs you in window Y" and the user attaches directly. The
  SKILL ships a hierarchy diagram and a responsibility-boundary table.
- **`scripts/test-e2e-layered.sh`** — a cross-platform (Linux + macOS) real-claude
  acceptance script that verifies the layered architecture end-to-end: spawn is
  container-only, the parent-shell invariant holds, first-launch is exactly-once
  idempotent, and dispatch-bound binds after the first LLM round-trip.

### Changed
- **execute-task schedules by the dependency graph, not list order.** The main
  agent now maximizes parallelism at every dispatch point: independent SubTasks
  (and any fan-out of reviews/research) that share a single upstream are
  dispatched together once that upstream is done, instead of being serialized by
  their list numbering. Documented as a standing discipline in the SKILL and the
  controller prompt.
- **`ZYZ_MAX_PARALLEL_WORKERS` defaults to `-1` (unlimited).** Set a positive
  integer to cap. Each worker is a full tmux + worktree + claude process, so a
  resource caveat is documented; the cap still counts paused workers as
  occupying a slot.
- Renamed the status-file `## Code Review` section (and the review-agent's
  `## Code And Test Review Standard`) to **Implementation Review**, aligning the
  term with what the phase actually reviews and with the sibling `## Design
  Review` / `## Final Aggregate Review` sections.

### Removed
- **`orch-spawn-worker.sh --auto-start` is removed entirely** (and the
  `ZYZ_AUTO_START_WORKER` env var). It was a defective half-baked launcher: its
  blind `send-keys` did not handle the trust-folder / bypass-risk confirmation
  pages, and its readiness probe was fooled by the confirmation-page menu arrow
  — the root cause of prior first-launch races. Spawn is now container-only and
  never starts claude; the L2 `orch-driver-agent` is the sole launcher and
  handles the confirmation pages and readiness correctly. **Breaking:** any
  caller passing `--auto-start` (a 3rd argument) now gets an argument error
  (exit 2).

## [0.5.2] — 2026-06-20

### Added
- `orchestration-scheduling-task` now self-schedules by default: a bare
  `/orchestrate-tasks <list-dir>` invocation enters "auto-timer mode" and re-arms the
  next tick via in-session `ScheduleWakeup` using the existing 7-branch cadence policy,
  rescheduling with the bare `/orchestrate-tasks <list-dir>` prompt. Previously a bare
  invocation ran a single tick and stopped; only `/loop` wrapping self-scheduled.
- `ZYZ_ORCH_ONCE=1` environment variable: explicit single-shot opt-out that runs one
  tick and returns without self-scheduling. It overrides `/loop` (forces single-shot
  even when wrapped).

### Changed
- Orchestrator startup is now a three-mode precedence (`ZYZ_ORCH_ONCE=1` > `/loop` >
  bare auto-timer default). `/loop` behavior is unchanged. Docs synced across
  `skills/orchestration-scheduling-task/SKILL.md`, `commands/orchestrate-tasks.md`,
  `CLAUDE.md`, and the orchestrator `main-agent.md`. Cadence thresholds and the 7 branch
  anchors are unchanged; self-scheduling uses in-session `ScheduleWakeup` only — no cron,
  no background process, no new file protocol.

## [0.5.1] — 2026-06-20

### Changed
- Semantic upgrade of the implementation vocabulary across the live `execute-task`
  and orchestration surface, reflecting that the implementation role does more than
  write code (it writes prompts, configuration, scripts, static files, and manifest edits).
- Renamed the implementation subagent to `implementation-agent` (both `agents/` and
  `subagents/` copies), including frontmatter `name:`, the camelCase role token in prose,
  and every reference across skills, prompts, templates, commands, and docs.
- Rewrote the `implementation-agent` prompt so its description and artifact wording express
  "implement a task's engineering work" rather than "write code".
- Lifted the workflow phase value to `implementation` across the cross-process phase
  contract (worker-status template, `execute-task` orchestrated-mode field list and
  phase-mapping table, orchestration skill, the 3 agent-prompt enums, and the mock-worker
  test) and across all phase-word prose, headings, and the implementation status-template
  section.
- Renovated the historical design docs under `docs/design/` to the current `execute-task`
  / implementation vocabulary; the older skill-design doc was renamed to
  `docs/design/execute-task-skill-design.md`, and the `/code-development` alias
  mention is retained.

## [0.5.0] — 2026-06-18

### Added
- `orchestration-scheduling-task` skill: scan a master task list, analyze dependencies,
  dispatch parallel tmux/git-worktree workers running `execute-task`, aggregate state
  via files, gate merges on user approval. Includes 6 bash helpers under `scripts/orch-*.sh`,
  slash command `/orchestrate-tasks`, 3 templates, and a full real-tmux integration test suite.
- `execute-task` orchestrated mode: triggered when `ZYZ_WORKER_STATUS_FILE` is set;
  workers self-report `phase` and `wait-state` to a status file the orchestrator reads.
- `docs/conventions/long-running-state.md`: plugin-wide convention that long-running
  tasks must persist progress, decisions, blockers, and next steps to files; context
  windows handle execution only.
- Master entry frontmatter `source-repo:` field (stage C): required, absolute or `~/`-prefixed,
  per-task. Lets one orchestrator dispatch workers across multiple repos from any cwd.
- `scripts/pack.sh`: reads version from `.claude-plugin/plugin.json` and produces
  `dist/zyz-worker-<version>.zip` for local plugin loading or marketplace upload.

### Changed
- Renamed `code-development` skill to `execute-task` (stage A). `/code-development`
  remains as a permanent alias of `/execute-task`; both share a single body.
- `orch-spawn-worker.sh` exit-code precedence reordered to `2 → 4 → 5 → 3 → rest` so
  source-repo validation negative tests can run on tmux-less hosts.
- `<project>` master-entry label now defaults from `basename "$SOURCE_REPO"` when
  omitted, instead of cwd basename (stage C bug fix).
- README opening rewritten to the user's intended preamble; all sections refreshed
  to reflect post-rename and orchestration capability.
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` keywords now
  include both `code-development` (legacy) and `execute-task` (current).

### Removed
- Placeholder `skills/zyz-worker/` removed (stage A; never had behavior).

### Fixed
- Stage C: orchestrator was previously cwd-locked to a single project's git work
  tree via `git rev-parse --show-toplevel`. Now fully cwd-independent.

## [0.4.0] — 2026-06-12

> (reconstructed from commit history; not exhaustive — authoritative source is `git log v0.4.0..v0.5.0`.)

### Added
- `code-development` skill (later renamed to `execute-task`): design-first code
  development workflow with main-agent prompt, code-agent / test-agent / review-agent
  subagents; design / status / final-report / review-report templates.
- `git-worktree` skill: default worktree path `~/.zyz-worker/worktrees/${repo}/${branch}`
  plus `add / list / remove / lock / unlock / prune / repair` sub-commands.
- "Total-goal fidelity" workflow rule: agents must not unilaterally reduce a task's
  scope; any deviation requires explicit user approval.
- "Incremental output" delivery technique: SubAgents may stream partial results
  across multiple tool turns for stability; never lets them defer or simplify
  the requested scope.
- "Autonomous VCS policies" for the design review / accept / reject loop:
  default to automatic decision making with documented escalation thresholds.

### Changed
- Split the design document into multiple files when the design is complex
  (introduced in 0.3.1, formalized here).

[Unreleased]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/somePeopleFireAndWood/zyz-worker/commits/v0.4.0
