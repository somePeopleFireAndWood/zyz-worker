# Watchdog 强制层细则

`SKILL.md` `## Watchdog 强制层` 列出主 agent 的义务；本文件是各层说明、指针细节和完整的声明用法。设计原则与长期方向见 `docs/design/watchdog-design.md`，脚本与阈值见 `hooks/README.md`。

## 分工

提示词纪律是主要的行为约束，watchdog 是它失守时的确定性兜底。**主 agent 主导**——用阶段和声明告诉插件任务为什么安静、在等什么；**插件是工具，也是监测者与保障者**——它观察主 agent 改不了的事实（工具调用活动、宿主报告的后台任务、API 错误中断、用户是否刚发言），守住主 agent 覆盖不了的不变量：

- 活跃任务既没有执行者（或整个会话长时间没人在动）、也没有声明，就报警；
- 硬失败（API 错误中断）一定报告；
- 每条声明都会自然失效（到点、用户下次发言、或它绑定的后台任务结束），不存在永久静音；
- 宿主报告的事实优先于声明（你说在等的后台任务已经不在列表里，以列表为准）。

它宁可误报一次，但每条告警都写明怎么确认、怎么用声明清掉；照做之后，同一原因不会再响。

## 各层

- **L0 心跳（自动、不可见）。** 主 agent、subagent、teammate 的每次工具调用都会写会话活动记录 `runtime/activity`（不依赖平台能力和角色名，是会话静默的输入）；宿主报告的 API 错误中断（StopFailure）记成 `runtime/api-failures/` 下的一条记录。主 agent 的每次工具调用推进 catalog 的 PACK_HEADER 心跳；动态角色的每次工具调用推进固定的 HEARTBEAT/INFLIGHT 记录。SubagentStart 建立固定且不可变的 IDENTITY/START，并为 implementation/test 建立物理基线；干净的 SubagentStop 写入逻辑上的 DONE。经确认的 API 强杀死亡用 `finalize` 写入另一种逻辑记录 FINALIZED。两种终态记录都优先于迟到的存活信号。
- **L1 新鲜度提醒。** 总状态文件在活动阶段（implementation/testing/review/delivery）变得过时时，PostToolUse hook 向当前上下文注入提醒（对主 agent："立即持久化进度"；对 implementation/test subagent："报告进度 / 更新你的 SubTask 状态文件"）。有频率限制，仅作提示。
- **L2 subagent 退出门。** SubagentStop hook 阻止角色以空的或过短的最终消息结束，指示它先输出一份像样的最终报告。每次停止最多拦截一次，不循环。它还拦下"以等待收尾"的结束：角色在本轮启动过后台任务（后台 Bash、Monitor、nohup/setsid/&），最终消息却以"等待完成通知 / monitor 通知"收尾——subagent 一结束就算完成，没有东西会再唤醒它。每个角色实例最多拦一次（启发式匹配）。
- **L3 后台 watchdog。** Claude Code 使用插件 monitor，把它的 stdout 作为唤醒通知送达。Codex 目前没有异步 hook/monitor 通知通道；它的同步 `SessionStart` hook 以分离方式启动同一个扫描器，输出到按线程划分的临时日志用于诊断，由 L0/L1 和同步的 Stop 门提供会话内强制。这一层降级时工作流依然正确。除了逐角色的发现（死亡角色、跟踪未对账、probe 逾期、无输出、已完成未收取），它还按声明办事：`wait` 到点叫醒你，你不处理就每隔 `remind-sec` 再提醒；`wait --ref` 绑定的后台任务结束了会告诉你；observing 阶段没有排定检查会低频提醒；任务**无执行者**时报警（主 agent 停下 10 分钟后仍是这样就报，空闲也照报，只有声明能让它安静）。两条与平台、角色类型无关的底线：
  - **会话静默**——活跃任务还有活，整个会话（主 agent、subagent、teammate）已 1 小时（`silence-sec`）没有任何工具调用、用户没有发言、状态文件也没写，又没有有效的 `wait` / `user` 声明、也没有打开着的对话框，就叫醒你。宿主后台任务列表里挂着多少条都不算数；首次 1 小时、之后默认每 30 分钟最多一次，可以用 `tune silence-sec=… remind-sec=…` 按任务调整（各最多 24 小时）；排定的唤醒（ScheduleWakeup 等）在到点前后一小时内算计划中的安静。
  - **API 错误中断**——某个 subagent / teammate 的这一轮因 API 错误结束（402 余额、429 限流、5xx……），后台派发的角色的失败结果可能根本送不到你，watchdog 把它告诉你，每条只报一次。

  两条在 macOS 上同样有效，用 `name` 派发的 teammate 也覆盖得到。
- **L4 主 agent 停止门。** 经认证的观察器报告某个非终态角色存活信号过期 / 跟踪未启用、且它不作为正在运行的后台任务存在时，或状态文件在活动阶段严重过时时，Stop hook 阻止主 agent 进入空闲，拦截理由写明要检查的角色。它还拦下**无执行者**的停止：任务在活跃阶段还有活（非 delivery 阶段，或还有未提交的 SubTask），宿主报告没有任何在跑的 subagent / 后台任务 / 排定的唤醒（插件 monitor 不算），也没有未结束的已派发角色，状态文件里又没有有效的 `wait` / `user` 声明（`resident` 的常驻后台任务不算执行者）。主 agent 处于空闲本身就是症状，不能用来豁免。observing 阶段的任务没有排定检查就停下时，也会被拦一次。
- **L5 派发范围守卫。** Agent 工具上的 PreToolUse hook 检查一次派发要求了什么，是唯一在事前起作用的一层。给角色的交付物设上限的提示词（"只报最重要的 3 条发现" / "only the top 3 findings"、"只给总体结论" / "just the overall verdict"、"只要总结论"、"一句话结论"）会被拒绝，除非同一提示词承诺交付其余部分（"然后继续做剩余部分" / "then continue with the rest"、"第 1 步，共 4 步" / "step 1 of 4"、"分维度"）。中英文措辞都识别。派发给 review-agent、带 `mode=incremental` 标记（`review-point=<id> round=<n> mode=incremental`），且 `review-round.sh` 确实记录了这一轮（n ≥ 2、是最新一轮、不是 `start --full` 的全量轮）时放行，因为增量复审的范围由评审点规则定义，不是缩范围。匹配是启发式的；`ZYZ_SCOPE_GUARD_DISABLE=1` 只关闭这一个守卫。另见 `references/recovery.md`。
- **评审闸门（`review-gate.sh`）。** 同为 Agent 工具上的 PreToolUse hook，只处理 review-agent 派发：任务有 `Tier:` 时，检查派发 prompt 里的 `review-point=… round=… mode=…` 行是否存在、是否和 `review-round.sh` 已 `start` 的最新一轮一致，以及单独一行的 `Tier:` 是否等于该评审点的生效档位，缺失或不一致时拒绝并写明要先运行的命令。没有任务或没有 `Tier:` 时 fail open；`ZYZ_REVIEW_GATE_DISABLE=1` 只关闭这一个闸门。
- **L6 共享 worktree 的 checkout 守卫。** Bash 上的 PreToolUse hook 在目标有未提交修改时拒绝 `git checkout <file>` / `git restore <file>`，也拒绝会移动状态的 `git stash` 写法；拒绝消息附安全做法（编辑前 `cp` 备份 + `mv` 恢复；只读用 `git show HEAD:<file>`；临时搁置用 `git diff` + `git apply -R`）。匹配是启发式的；`ZYZ_CHECKOUT_GUARD_DISABLE=1` 只关闭这一个守卫。原因见 `references/version-control.md`。
- **L7 IM 通知（只在需要人时发）。** 任务还在执行时不给用户发 IM——主 agent 停下、subagent 走一步、subagent 因 API 错误中断，都由 watchdog 叫醒主 agent。只有这几种情况通知用户：主 agent 在提问（用自然语言提问后 `set <key> user`；用户 60 秒内已回答就不发）；任务交付（进入 `awaiting-confirmation` / `observing` / `done`，每次进入一次）；主 agent 自己这一轮因 API 错误中断；watchdog 叫醒主 agent 之后会话里仍没有动作（升级，同一段停摆只发一次）。每条 IM 的标题带会话名称。所以声明和阶段直接决定用户会不会被打扰。

## 任务指针

- 在**会话 cwd 下**运行 `<plugin-root>/hooks/scripts/task-pointer.sh arm <任务目录>`。会话 cwd 是本次对话运行所在的目录，也就是 hooks 收到的 `cwd`，不是 `git rev-parse --show-toplevel`：在链接 worktree 内两者不同，`git-worktree` skill 创建的 worktree 在主检出目录之外，指针放错地方就会落在会话 cwd 看不到的位置。
- **指针按会话区分（#23）。** 有会话 id 时，脚本把任务目录的绝对路径追加到 `.zyz-worker/sessions/<session-id>`（一行一个任务，重复 arm 不重复写）。会话 id 取自本会话所在的 harness：Claude Code 是 `$CLAUDE_CODE_SESSION_ID`，Codex 是 `$CODEX_THREAD_ID`——两者都已实测与 hooks 收到的 `session_id` 一致，并且在 subagent 的 hooks 里仍是父会话的 id。脚本按最近的 `claude`/`codex` 祖先进程判定 harness，因为这两个变量会泄漏进嵌套启动的另一个 harness。拿不到会话 id 时脚本才退回写共享的 `.zyz-worker/current-task`，并在 stderr 上提示；不要手工写 `current-task`。
- 只有主 agent 写指针：Codex sub-agent 的 shell 里 `$CODEX_THREAD_ID` 是它自己的子线程 id，写出来的指针属于错误的会话。
- 本会话同时推进多个任务时，对每个任务各 arm 一次，第一行是**主任务**：subagent 的心跳、运行时跟踪和派发守卫的记录都存在主任务下。hooks 无法知道某个 subagent 是为哪个任务派发的，所以多任务时 subagent 类告警会列出本会话的全部任务，由你按派发记录判断归属，再到所属任务的目录读结果、写进所属任务的 `status.md`；只有 `agent-runtime-state.sh finalize` 等 runtime 命令的 `<task-dir>` 用告警里写明的记账目录。任务结束后可以 `task-pointer.sh disarm <任务目录>`；终态任务留在指针里也不再触发强制。会话恢复（`--resume`、`/clear` 后继续）时会话 id 可能变了，要重新 arm。
- 解析器只看本会话的会话指针；只有拿不到任何会话 id 时才回落到共享的 `current-task`（有会话 id 却没 arm 的会话不会被目录里残留的 `current-task` 挂到别人的任务上，watchdog 对它完全安静），此外只认进程启动前导出的 `$ZYZ_TASK_DIR`。它不搜索同级 git worktree，也不读别的会话的指针：早先这样做的兜底逻辑曾把一个会话挂到并发会话的任务上（#18）。因此缺少指针时 watchdog 确定性地保持沉默，"确认已启用"就是用来发现这种情况的。`task-pointer.sh show` 列出 hooks 为本会话解析到的全部任务。

## 主 agent 对 watchdog 的义务（细节）

- **确认已启用。** 几次工具调用之后，用只读的 fixed-pack 观察器确认经过认证的 `main_heartbeat_epoch` 存在并且在推进。不去探测或创建独立的主心跳 inode：主心跳的权威来源是 catalog 的 PACK_HEADER。观察器无法验证时，在状态文件中和对用户说明 watchdog 未生效——未启用的 watchdog 与健康而安静的 watchdog 看起来毫无区别，曾有一整个任务在所有层都失效的情况下跑完，两个死掉的 subagent 都没有被报告。
- **告警当指令。** "角色 X 已静默 N 分钟且没有正常结束"：现在检查该角色的结果，用最新的设计和状态摘要重新派发它（工作实际已完成就记为完成）。"状态文件已有 N 分钟没有更新"：先刷新状态文件，再继续派发。不推迟到下一个交付里程碑。
- **核实归属。** 告警点名的状态文件或任务目录属于本会话的任务（会话指针、退回时的 `current-task`，或 `$ZYZ_TASK_DIR`）时才可执行。属于同级 worktree 中并发会话的任务、过时的指针或设错的环境变量时，不往里写——那等于伪造另一个任务的事实来源——而是向用户报告不匹配。watchdog 既可能漏掉真实问题（#9），也曾报告过别人的问题（#18）；它是兜底，不是神谕。
- **阶段。** 催你行动的检查（状态过期、无执行者、停止门）只在活动执行阶段生效，design 和 awaiting-confirmation 阶段等待用户是正确的。design 阶段派出的角色（设计评审）照样有人盯：逐角色的发现照报；你停下时有执行者在跑、此后整个会话静默满 `silence-sec` 会叫醒你；想更早知道就在派发后声明 `set <key> wait --at <预计完成时间> [--ref <agentId>]`，到点叫醒你。等用户批准设计时用 `user` 声明。主体已交付、只是留着窗口到点观察（例如发布后次日对账）时，阶段写 `observing`，并用 `expect.sh set <key> wait --at <时间>` 排定检查。
- **运行时记录。** `<task-dir>/runtime/` 下的标记是 watchdog 的记账数据，不手工编辑。用 `probe-create`，重连时带上它的确切 id；只有观察到它的接收方角色才运行 `probe-ack`；心跳不是 ACK。对沉默的角色创建探针并把确切 id 交给它，等待期间用 `wait --at <截止时间>` 声明，评审之前 `clear`。平台证据和探针证据确认角色已死亡时，重新派发之前先调用 `finalize`。
- **停下之前确认还有执行者。** 答案是一个**核实过**的执行者：仍在运行的 subagent 或后台任务（用 ListAgents / 后台任务列表 / `ps` 核实，而不是凭印象说"某条通道还在跑"），或一个排定的唤醒；否则继续派发下一步，或声明在等什么。subagent 以"等待通知"收尾时，它启动的后台进程没有人看——由你用自己的后台等待（后台 Bash 轮询它的退出状态 / 输出文件，或 Monitor）盯住它，它结束时会唤醒你，也算一个执行者；要等很久就再 `set <key> wait --at <预计完成时间> --ref <后台任务 id>`。
- **会话静默、API 错误中断。** 它们说的是任务很可能已经停摆。先逐条核实在等的通道（ListAgents、后台任务的输出文件、`ps`、角色的会话记录）；死掉的角色按 `references/recovery.md` 的三步续做重派（teammate 可以直接 SendMessage 让它从会话记录接着做）；确实在正当地等就用声明说清楚（`wait --at` / `user`），不声明过一阵还会再响。同一个 API 错误反复出现（`billing_error`、`authentication_failed`、`rate_limit`）时不立刻重派：告诉用户，并 `set <key> wait --at +30m` 过一段时间再试。

## 声明：让 watchdog 按你的意图工作

watchdog 不去猜任务为什么安静。除上面的不变量之外，什么时候叫醒你、等什么、多久算异常，都由你来声明，插件到点兑现；声明写在 `status.md` 的 `## Agent State` 里，会话恢复后（重新 arm 之后）依然有效。

用 `<plugin-root>/hooks/scripts/expect.sh` 声明（主 agent 自己运行，不交给 subagent；默认作用于本会话的主任务，`--task <任务目录>` 可指定）。它校验每一行再原子写入，手写的行有一个错字就会悄无声息地失效，所以不手写：

| 场景 | 命令 |
|---|---|
| 一个后台任务（含后台 subagent）会推进任务，但要跑很久 | `set lane-a wait --at +90m --ref <后台任务 id 或 agentId> --reason 全量用例` |
| 等外部的东西（批跑、部署、别人的回复） | `set batch wait --at 2026-11-19T09:00 --reason 等 T+1 批跑完成` |
| observing 阶段到点去看 | `set recon wait --at +1d --reason 核对 dws 与源表行数和金额` |
| 用自然语言向用户提问后停下（含设计批准闸门、轮次上限交用户） | `set q user --reason 等用户裁决接口方案`（在提问的同一条回复里、结束这一轮之前声明；它会给用户发 IM，`--reason` 就是 IM 内容；用户下次发言后自动失效；只压"无执行者"和"会话静默"，继续干活时状态文件仍要保持新鲜。提问一律用自然语言，不使用 AskUserQuestion 工具） |
| 有问题要问用户，但同时还有可以独立推进的活 | `set q user --watch --reason 命名用 A 还是 B`——用户照样收到 IM，但什么都不压，watchdog 照常盯着你在推进的那部分 |
| 编排模式下等 `answer.md` 异步回复 | 不用 `user`（用户回复不经过对话，声明不会失效）：后台运行 `until [ -f <answer-file> ]; do sleep 30; done`，它就是执行者，回答一到就唤醒你 |
| 常驻后台任务（开发服务器、`tail -f` Monitor、无关的 cron） | `set srv resident --ref <id> --reason e2e 用的 dev server` |
| 这个任务本来就慢（长批跑），或者会长时间安静 | `tune status-stale-sec=3600 no-executor-sec=1800 remind-sec=3600 silence-sec=7200`——`silence-sec`（安静多久叫醒你）和 `remind-sec`（之后多久再叫）各最多 86400（24 小时） |
| 在等一个长时间不调用工具的东西（长跑后台任务、长时间推理的 teammate、外部批跑） | `set lane-a wait --at +90m [--ref <id>] --reason …`（一次性，到点叫醒你），或 `tune silence-sec=<秒>` 放宽静默阈值——否则 1 小时后会收到「会话静默」，之后每 30 分钟再来一次 |

- `wait` 到点之前压住"状态过期""无执行者"和"会话静默"（只在活跃和 observing 阶段生效）；`user` 压住"无执行者"和"会话静默"（`--watch` 时什么都不压）；`wait` 到点叫醒你，你不处理就每隔 `remind-sec`（默认 30 分钟）再提醒，提醒之后仍没有动作才通知用户。看完就 `clear <key>`；还要再等就用新的 `--at` 重新 `set`。`--at` 最远 7 天（`ZYZ_EXPECT_MAX_SEC`）。
- `resident` 用的是 Bash（`run_in_background`）/ Monitor / CronCreate 返回的 id——它和宿主报告的后台任务 id 一致（已实测）。凡是自己不会结束、也不推进任务的后台任务都要声明，否则它会一直被当成执行者，让"无执行者"检查永远不触发。
- `tune` 只能放宽阈值（每一层取它与默认值中较大的那个），关不掉检查（状态过期和无执行者最多放宽到 4 小时，会话静默和再提醒间隔最多 24 小时）；不需要了就 `tune --clear`。每次 `expect.sh` 写入都会刷新状态文件的修改时间。
- `list` 列出所有声明及其状态（valid / due / lapsed / INVALID）。旧格式的 `- Waiting On:` / `- Awaiting-User:` 行仍然有效，`clear` 也能删掉它们。

## 降级环境

hooks 和 monitor 可能不可用（插件 hooks 被策略禁用、当前平台或版本不支持 monitor）。一切仍然可以工作——`references/recovery.md` 中的监控与续做职责和 `SKILL.md` `## 核心规则` 中的写盘规则依然有效，并成为唯一的强制手段。所有阈值都可以通过 `ZYZ_*` 环境变量调节（见 `hooks/README.md`）；`ZYZ_HOOKS_DISABLE=1` 关闭整个强制层。
