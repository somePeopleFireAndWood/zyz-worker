# Hooks（钩子）

## 角色 runtime 状态协议

角色实例的键由两部分组成：原始 agent id 经过清洗后的可读前缀（32 字节），加上原始 agent id 的完整 SHA-256。唯一受支持的、会改变状态的入口是 `hooks/scripts/agent-runtime-state.sh`；绝不要手工创建、编辑或删除 `runtime/agents` 下的文件。

```text
agent-runtime-state.sh finalize <task-dir> <agent-id> <role> <reason> [replacement-agent-id]
agent-runtime-state.sh probe-create <task-dir> <agent-id> <role>
agent-runtime-state.sh probe-ack <task-dir> <agent-id> <probe-id>
agent-runtime-state.sh probe-status <task-dir> <agent-id>
agent-runtime-state.sh probe-cancel <task-dir> <agent-id> <probe-id> <reason>
agent-runtime-state.sh adopt-legacy <task-dir> <agent-id> <role> confirmed
agent-runtime-state.sh reconcile-start <task-dir> <agent-id> <role> <event-token> confirmed
agent-runtime-state.sh reconcile-stop <task-dir> <agent-id> <role> <event-token> confirmed
agent-runtime-state.sh gc-step <task-dir> <watchdog|lifecycle|manual|system-timer>
```

DONE 和 FINALIZED 是 fixed-pack 中的逻辑记录。FINALIZED 是可审计的"已确认死亡"证据，与自然结束的 DONE 相区分；两种终止记录中任一存在，其优先级都高于迟到的 heartbeat / inflight / probe / no-output 状态。Probe ACK 是插件层面的显式观测，而不是宿主的送达回执；心跳绝不会确认 probe。

`probe-ack` 和 `probe-cancel` 会在读取或修改实例状态之前拒绝格式错误的 probe id，以 exit 2 退出并返回 `error.code="invalid-probe-id"`。语法合法的 `probe1-<32 lowercase hex>` id 如果不是当前待处理的那个确切 challenge，则返回 exit 4 和 `error.code="probe-mismatch"`。两种错误都保留规范的 JSON 信封，并且除了有长度上限、仅用于输出的 argv 字段之外，绝不回显或持久化被拒绝的载荷。

## 声明（#24）：agent 主导，插件兑现

整体设计依据与长期方向见 [../docs/design/watchdog-design.md](../docs/design/watchdog-design.md)：主 agent 是主导者，用声明和阶段表达意图；插件是它的工具，也是监测者与保障者——观察主 agent 改不了的事实，守住它覆盖不了的不变量。

watchdog 不去猜任务为什么安静——那需要穷举场景。主 agent 用 `hooks/scripts/expect.sh` 在 `status.md` 唯一的 `## Agent State` 小节里**声明**意图；`hooks/scripts/expect_state.py` 是唯一的解析器（hook 通过 `lib.sh zyz_expect_eval` 调用它），解析时跳过 HTML 注释（模板就在注释里写着示例行）。行格式：

```text
- Expect: key=<k>; kind=wait; at=<epoch>; ref=<后台任务 id|->; reason=<text>
- Expect: key=<k>; kind=user; since=<epoch>[; watch=yes]; reason=<text>
- Expect: key=<k>; kind=resident; ref=<后台任务 id>; reason=<text>
- Tune: status-stale-sec=<n>; no-executor-sec=<n>; remind-sec=<n>; silence-sec=<n>
```

- **`wait`**：某样东西会在 `at` 之前推进任务。`at` 之前压住状态过期（L1/L3/L4）、无执行者（L3/L4）和会话静默（L3）；只在活跃和 observing 阶段生效（design / awaiting-confirmation 阶段的 wait 到点不会叫醒）；`at` 一到，L3 叫醒主 agent，之后每隔 `remind-sec`（Tune，默认 `ZYZ_WATCHDOG_REMIND_SEC`=1800）再提醒一次；提醒之后会话里仍没有任何动作，才升级成给用户的 IM（见 `### IM 策略`）。标记记在 `runtime/nag/expect-due-<key>`（`<at> <上次提醒> <次数>`），换了 `at` 就重新开始。带 `ref` 时只在那个后台任务还在宿主列表里时有效（L4 看本次 Stop 的列表，L3 看上次 Stop 的快照；没有快照或快照是旧格式时视为未知、照常有效；L1 拿不到列表，一律视为有效）；它消失了，声明不再压制，L3 报一次（`expect-dead-<key>-<ref>`）。后台 subagent 的 id 也与 Agent 工具返回的 agentId 一致（已实测）。`at` 超过 `ZYZ_EXPECT_MAX_SEC`（默认 604800，即 7 天）的行被忽略（`expect.sh` 直接拒写）。
- **`user`**：主 agent 用自然语言向用户提了问题，在等回答（AskUserQuestion 不需要这一行）。写入时 `expect.sh` 在后台给用户发一条 `needs_input` IM（延迟 `ZYZ_NOTIFY_ASK_DELAY_SEC`=60 秒，期间用户已回复就不发）。它只压住"无执行者"和"会话静默"，**不**压住状态过期——设了 user 之后如果还在干活，状态文件照样要保持新鲜。带 `watch=yes`（`set <key> user --watch`）时什么都不压：问题挂着、但还有可独立推进的活，用户照样收到 IM，watchdog 照常盯着。只在用户下一次发言之前有效：`main-state.sh` 在每次 `UserPromptSubmit`、`heartbeat.sh` 在 AskUserQuestion 被回答时把 epoch 写进 `runtime/user-prompt-epoch`，`since` 早于它就失效，所以一行被忘掉的声明不可能永久静音。
- **`resident`**：永不结束、也不推进任务的后台任务。L4 计算执行者时按 id 精确扣除（会话内所有任务的声明都算，后台任务本来就是会话级的）。Bash `run_in_background` / Monitor / CronCreate 返回的 id 与 Stop 输入里 `background_tasks[].id` / `session_crons[].id` 一致——已在 Claude Code 2.1.251 上实测。
- **`Tune`**：按任务调整阈值。L1/L3/L4 一律取 Tune 与本层默认值中**较大**的那个（`zyz_expect_tune`），所以它只能放宽、不能收紧；上限让它关不掉检查：`status-stale-sec` 600..14400、`no-executor-sec` 60..14400、`remind-sec` 300..86400、`silence-sec` 600..86400（会话允许安静多久、之后多久再叫一次，由主 agent 自己定，单次最长 24 小时）。L1 的默认 600 就是下限，所以 L1 可以先做便宜的默认阈值检查、过了再解析。Tune 行不会自动失效，不需要了就 `tune --clear`。
- **评估器不可用时一律放行。** 没有 python3、或 `expect_state.py` 出错时，`zyz_expect_eval` 没有输出，调用方把它当作"未知"而不是"什么都没声明"：observing 检查、声明扫描和无执行者子句都跳过（fail open）。
- **每一行各自独立。** 格式错误或重复 key 的行什么都不做、也不连累别的行，`expect.sh list` 会把它标成 INVALID。
- **不变量（agent 不能覆盖）：** 活跃任务既没有执行者、也没有有效声明就报警；每条声明都会失效；宿主报告的事实优先于声明。
- **兼容旧格式：** `- Waiting On:`（严格语法，仍由 `zyz_status_waiting` 判定压制，1 小时上限 `ZYZ_WAIT_MAX_SEC`；到期提醒走上面的 `wait` 逻辑，epoch 必须为正，`next-check-epoch=0` 的行无效）和 0.29.0 的 `- Awaiting-User:`（等同 `kind=user`）照常有效，`expect.sh clear <key>` 也能删掉它们。

`expect.sh` 写入时持有 `<task-dir>/runtime/expect.lock`（并行调用不会丢行），用解析器给出的位置插入（跳过注释），写完重新解析确认新行确实生效、否则拒写；保留文件原有的换行风格（CRLF 不会被改成 LF）。每次写入都会刷新 status.md 的 mtime，等于重置状态过期计时。用法：`set <key> wait --at <+30m|+2h|+1d|epoch|ISO> [--ref <id>] --reason <text>`、`set <key> user [--watch] --reason <text>`、`set <key> resident --ref <id> --reason <text>`、`clear <key>|--all`、`tune name=value…|--clear`、`list`；`--task <task-dir>` 指定任务，默认是本会话的主任务。它在写入前校验，非法输入以非零退出并给出一行诊断，原子写入（tmpfile + rename）。只由主 agent 运行。

**observing 阶段（#24）。** `Current Phase: observing`（也认 `monitor*` / `watch*` 前缀）表示主体已交付、窗口留着到点观察。它**不是**活跃阶段：状态过期、无执行者、L1 提醒都不响；进入它时（Stop）给用户发一次「已交付」的 IM。但它必须有一个排定的检查（有效或已到点的 `wait`、未到期的旧 `Waiting On`，或有效的 `user`）：没有时 L4 在停下时拦一次（`runtime/nag/stopgate-observing.last`，与 L4 冷却相同），L3 每 `ZYZ_WATCHDOG_OBSERVE_SEC`（默认 10800）提醒一次。

## 主 agent 状态机（纯信号驱动，无 TTL）

与上面的 fixed-pack subagent 协议相互独立，主 agent 自身的存活状态是一个单行文件 `<task-dir>/runtime/main-state`，内容为 `<state> <epoch>`（`awaiting-user` 时再带第三个字段：对话框的归属者，`main` 或某个 agent id），其中 `<state>` ∈ `working` / `awaiting-user` / `idle` / `ended`。Hook 在经过平台验证的状态转换点写入它：`UserPromptSubmit` 以及主 agent 每一次 `PreToolUse`/`PostToolUse` 心跳 → `working`；主 agent 的 `PreToolUse` of `AskUserQuestion`，以及原始 `notification_type` 为 `permission_prompt` / `agent_needs_input` / `elicitation_dialog` / `elicitation_url_dialog` 的 `Notification` → `awaiting-user`；`Stop` 和 `idle_prompt` 的 `Notification` → `idle`；`SessionEnd` → `ended`。

`awaiting-user` 的含义是**一个用户对话框此刻正打开着**。所以（0.32.0 起）：`Stop` 一律写 `idle`——这一轮结束意味着任何对话框都已关闭（之前「已有 awaiting-user 时 Stop 不覆盖」的豁免会在权限被拒后留下一个过期的「对话框开着」）；`idle_prompt`（"上一轮已结束约 60 秒、其间用户没有任何操作、屏幕上也没有对话框"）写 `idle`，不再写 `awaiting-user`——它说的是「停下了、用户不在」，不是一个打开着的对话框；当成对话框，主 agent 每次停下、用户走开后都会被当成「在等用户」，会话静默就永远不响。

L3（watchdog）和 L4（停止门）通过 `zyz_main_state_suppresses` 读取它；当状态为 `awaiting-user` 或 `idle` 时，该函数返回 true。压制判断是纯字符串比较——**epoch 只为诊断而写，压制判断从不读它，所以不存在 TTL，等上 15 个小时也绝不会"过期"**。压制期间，归因于主 agent 的 **状态陈旧**发现会被静音（L3 的 stdout 及其 main-origin `stuck` IM；L4 的 状态陈旧阻断子句）。手动的 `Waiting On:` 守卫和这个信号驱动的状态互为补充、按 OR 组合：任意一个生效都会压制 状态陈旧。状态文件缺失或损坏时 fail open，恢复完整告警。归因于 subagent 的发现绝不会被压制（见 L3/L4）。

会话静默（见下一节）用 `zyz_user_dialog_open` 判断对话框是否还开着：状态为 `awaiting-user` 即为开着，同样只比较字符串、不读 epoch。关闭它的只能是对话框的**归属者**自己的下一步——`awaiting-user` 行的第三个字段记着归属者：主 agent 的对话框（AskUserQuestion、没有 `agent_id` 的通知）由主 agent 的下一次工具调用、Stop 或用户发言改写 main-state 而关闭；subagent / teammate 的权限确认（通知带 `agent_id`）由**它自己**的下一次工具调用关闭（`zyz_dialog_close_by`）。别的 agent 的活动不关闭它：主 agent 在 AskUserQuestion 里等用户、后台角色照常干活，是正常形态。所以一次被批准的权限确认不会让会话永久静音，后台角色的活动也不会把主 agent 打开着的对话框误判为已关闭。主 agent 回答完 AskUserQuestion（它的 PostToolUse）也记一次 `runtime/user-prompt-epoch`——用户回答就是用户发言，`kind=user` 声明随之失效。

## 会话静默与 API 错误中断（0.32.0）：与平台、角色类型无关的底线

上面的逐角色检查依赖 fixed-pack（macOS 上不可用）和三种角色名的 matcher（用 `name` 派发的 agent team teammate，`agent_type` 是它的名字，匹配不上）。0.32.0 之前，它们之外只剩"无执行者"，而它只看 Stop 时宿主报告的后台任务列表——列表里挂着已经不会再推进任务的条目时（死掉的 teammate、跑完却没人看的任务），它永远不响。真实事故（11-19）：一个评审 teammate 04:14 撞上 402 死掉，宿主列表里还挂着 16 条，整个会话 6.5 小时没有任何工具调用，没有一层发声。底线检查只依赖所有平台都有的两个事实：

- **会话活动**。`heartbeat.sh` 在主 agent、每个 subagent、每个 teammate 的每次工具调用时写 `runtime/activity`（`<epoch> <main|agent_id>`；subagent 的记在主任务下）。`zyz_roots_last_progress` 取本会话所有任务的 `runtime/activity`、`runtime/user-prompt-epoch` 与 `status.md` mtime 中最新的那个，作为「会话最后一次进展」。
- **API 错误中断**。`api-failure.sh`（StopFailure）把每次因 API 错误结束的一轮记成 `runtime/api-failures/<epoch>-<pid>-<rand>.rec`（一行，制表符分隔：`<epoch> <agent_id|-> <agent_type|-> <error> <details>`；`agent_id` 缺省即主 agent 自己）。宿主忽略 StopFailure hook 的输出，所以落盘记录是这个事件到达主 agent 的唯一途径——此前它只发了一条 IM。

L3 据此出两条告警：

- **会话静默**（`scan_declarations` 第 (5) 项）：任务处于活跃阶段且还有活（判据同无执行者），会话最后一次进展已过去 `silence-sec`（Tune，默认 `ZYZ_WATCHDOG_SILENCE_SEC`=3600），没有打开着的对话框（`zyz_user_dialog_open`），没有有效的 `wait` / `user` / 旧格式 `Waiting On`，也没有已到点的 `wait`（它有自己的提醒）。上次 Stop 时宿主排着一个唤醒（`session_crons` 里非 resident 的条目：ScheduleWakeup / CronCreate / loop）时，在 `silence-sec + 3600` 秒内视为计划中的安静；超过仍报（ScheduleWakeup 最远一小时，永远不来或一天后才来的唤醒仍要声明 `wait`）。**不**看宿主后台任务列表、**不**看 main-state 的 `idle`、**不**看 fixed-pack 的在跑角色数。无执行者的条件成立时（含它还在冷却中）不报会话静默，二者共用同一组压制。命中时输出一行通知，按 `runtime/nag/watchdog-silence.last` 每 `remind-sec` 最多一次（两者都可以由主 agent 用 Tune 放宽到 24 小时）；主 agent 被叫醒后会话里仍没有任何动作，才升级成一条给用户的 IM（见 `### IM 策略`）。文字里附上会话最后一次进展之后主 agent 自己的 API 错误（常常正是它停下的原因）。
- **API 错误中断**（`scan_failures`）：本会话所有任务下（记录写在写入当时的主任务下，主任务可能已变）待报告的 subagent / teammate 记录，在本会话还有未完成任务时（含 design 阶段——设计评审的通道死了，设计同样在空等），合并成一行通知主 agent，随后移到 `reported/`，每条只报一次。按 `runtime/nag/watchdog-api-failure.last` 限频（`ZYZ_WATCHDOG_FAILURE_COOLDOWN_SEC`，默认 600）：冷却内到来的记录留着、下次合并报告，这样持续的上游错误不会把「重派 → 又死 → 立刻叫醒」变成快速循环。主 agent 自己那一轮的记录**不**在这里报（刚失败就叫醒它，持续错误时会以轮询间隔反复失败），直接归档，由会话静默按 `remind-sec` 的节奏带出；`api-failure.sh` 同时把 main-state 记为 `idle`（这一轮已结束），否则状态过期每 15 分钟还会再叠一次唤醒。格式不对的记录同样只归档、不报告。不受声明压制（事实优先于声明）；不发 IM——subagent 的失败由主 agent 处理，主 agent 自己的失败由 notify.sh 在 StopFailure 时发 `failed`。超过 7 天的记录（已报告的，或因任务都已完成而没人消费的）由 `api-failure.sh` 清理，任务重开时不会报出陈旧的失败。告警措辞不断言「结果一定送不到」——前台派发的角色会把错误直接返回给主 agent，它可能已经处理过，所以要它先核实、没处理过才重派。

两条告警的文字都写明确认办法和清除办法（I5）：静默的通道按续做重派；确实在等一个不调用工具的东西（长跑的后台任务、外部批跑、长时间推理的 teammate）就 `wait --at`，等用户就 `user`，本来就会长时间安静就自己定静默时长 `tune silence-sec=… remind-sec=…`（各最多 24 小时），已交付就改阶段；同一个 API 错误反复出现时先 `wait` 并告诉用户，而不是立刻重派。

已知局限（如实说明）：teammate 的工具调用 hook 按会话 id 解析指针，如果某个宿主版本给它传了不同的会话 id，它的活动看不见，会话静默会多报（用 `wait` 清掉）；subagent 的权限确认通知如果不带 `agent_id`，会被记成主 agent 的对话框，主 agent 停着时它要等主 agent 下一次动作或用户发言才关闭，其间会话静默不响；StopFailure 不带 `agent_id` 的 subagent 记录会被当成主 agent 的（Claude Code 2.1.251 的实现里 subagent 的 StopFailure 带 `agent_id`）。多任务会话里每个活跃任务各报一条会话静默：每个任务都要各自说明为什么安静。

## 公开的 runtime 上限

| 环境变量 | 默认值 | 有效取值 |
|---|---:|---|
| `ZYZ_WAIT_MAX_SEC` | 3600 | 1..86400 |
| `ZYZ_RECONNECT_ACK_SEC` | 600 | 0 表示禁止 create；否则为 1..86400 |
| `ZYZ_INFLIGHT_GRACE_SEC` | 1800 | 1..86400 |
| `ZYZ_RUNNING_NO_ACK_GRACE_SEC` | 600 | 1..86400 |
| `ZYZ_AGENT_LOCK_ACQUIRE_SEC` | 2 | 1..30 |
| `ZYZ_AGENT_LOCK_STALE_SEC` | 120 | 1..86400 |
| `ZYZ_WATCHDOG_NO_OUTPUT_SEC` | 1800 | 0 表示禁用；否则为 1..604800 |
| `ZYZ_NO_OUTPUT_MAX_PATHS` | 10000 | 1..1000000 |
| `ZYZ_NO_OUTPUT_MAX_FILE_BYTES` | 16777216 | 1..1073741824 |
| `ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES` | 67108864 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES` | 33554432 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES` | 33554432 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_MAX_RSS_BYTES` | 134217728 | 16777216..1073741824 |
| `ZYZ_NO_OUTPUT_MAX_TEMP_BYTES` | 134217728 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_TEMP_STALE_SEC` | 120 | 1..86400 |
| `ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC` | 8 | 1..8 |
| `ZYZ_SNAPSHOT_GC_INTERVAL_SEC` | 300 | 0 表示禁用 watchdog/lifecycle 时机；否则为 1..86400 |
| `ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS` | 10000 | 1..1000000 |
| `ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS` | 134217728 | 1..2147483647 |
| `ZYZ_SNAPSHOT_GC_MAX_SEC` | 2 | 1..30 |
| `ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES` | 536870912 | 33554432..2147483647，且小于 hard water |
| `ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES` | 1073741824 | 67108864..2147483647，大于 high water，且不低于结构性下限 |

取值必须是规范的十进制数，并在参与运算前做范围检查；输入无效时使用文档中的默认值，并给出诊断信息。只存在上面写明的三种取 0 的模式。high/hard-water 这一对中只要有一个无效，或者 `high >= hard`，就会原子地同时回退到两者的默认值。SubagentStart 的宿主预算是 15 秒。物理比较恰好排除本任务的 runtime 和 `.git`；它比较的是路径是否存在、类型、权限和字节内容，而不是 Git 元数据；当无法证明上限或平台安全性时，报告为不可用。

物理快照固定在文件描述符上，并且 fail closed。扫描器以 nofollow 方式逐个路径分量打开，遍历 cwd 的祖先链和 worktree，重新校验每一个 name/inode/type/nlink 绑定，并要求原生的逐 vnode 挂载标识。目前只有 Linux 的 `statx(STATX_MNT_ID)` 满足这一契约：在 macOS 上，`getattrlistat` 的 FSID 加上已打开 fd 的 `fstatfs` 交叉校验虽然会被计算，但随后会被拒绝，因为文件系统级的 FSID 无法区分第二个同 FSID 的挂载实例或 bind 边界——因此 Darwin 会以 `genesis-capability-unavailable` fail closed（见 **降级环境**）。原始路径和规范记录使用二进制、带长度前缀的溢出文件和外部归并。RLIMIT_AS、观测到的峰值 RSS、临时字节数、截止时间、路径数、manifest、inventory、总读取量和单文件上限，都在真实扫描过程中强制执行。无法证明其中任一属性的平台会报告快照不可用；它绝不会改用 `st_dev` 来顶替。

快照发布使用固定的 PUBLICATION_JOURNAL 和 LIVE_INVENTORY 槽位，而不是独立的控制 journal 或 inventory 指针。实时的累积 inventory 按用途、代次、原始安全的 basename、类型、大小、SHA-256、dev/ino/nlink、mtime 和原生挂载 id，绑定 catalog 所拥有的每一个数据头/记录。被取代的目标仍归一个固定的清理意图所有。

清理只以有界的 `gc-step` 形式对外提供。固定的 claim pack 拥有不可变的键、owner、观测、GC journal、checkpoint、指针、回执和锚点确认。制品清理会用 inventory 中的每一个标识字段去校验一个以 nofollow 方式打开的 fd，并遵守配置的每轮字节与条目预算。预算耗尽时返回规范的 `pending`，绝不猜测为成功。

大文件校验通过经过认证的固定 CHECKPOINT 和 POINTER 槽位续跑。一个 checkpoint 会持久化目标游标、文件偏移/预期大小、累计计数器，以及标准的 SHA-256 状态（八个链接字、完整块计数、部分块字节）。固定的 A/B 代次及其头部前驱链，取代了临时控制文件的发布方式。

在压缩后的实时 inventory 之后，回执发布使用 `will/did-receipt`。随后通过 `will/did-key-delete` 删除认证密钥；只有最终的 `committed` journal 才会让回执可以被终止压缩消费。被杀掉的一轮会按 journal 所拥有的确切 prior/after 集合续跑，终止输出如实保持为 `pending`、`blocked` 或 `compacted`。锁 owner、prepared-owner GC、发布、对账、终止和 legacy 迁移等事务，同样都在产生副作用之前持久化 `will-*`、之后持久化 `did-*`。不要手工编辑这些制品；重新执行同一条受支持的公开命令即可。

扫描器的临时状态有自己的 owner 协议。一个完整的 owner 先写成 `.snapshot-owner.prepare.<64hex>`，fsync 后原子地提交为 `.snapshot-owner.<64hex>`，之后才会创建单独的、权限为 0700 的 `.snapshot-tmp.<64hex>` 目录。owner 绑定了强进程出生标识、host/boot、task/root/runtime/baseline 标识以及原生 runtime 挂载。父进程轮询终止/取消状态，并在正常完成、出错、TERM 或超时时删除它自己那一份确切的 owner/temp。之后的 hook 只能回收这样的 owner：它是旧的、同 host/boot 的，其 PID 可证明已死亡或被复用，且当前的 task/root/runtime/baseline 绑定仍然匹配。它的认证 `<nonce>.snapshot-temp-gc-journal` 只基于描述符做后序遍历，在 `will-entry-delete-N` 处持久化原始路径和标识，并确认 `did-entry-delete-N`；符号链接只删除链接本身，特殊文件绝不会被打开，嵌套挂载会阻止清理，每轮最多删除 10,000 个条目。只有 owner 或只有 temp 的、格式错误的、来自未来的、跨 host/boot 的、仍存活的或绑定已变化的条目，都保留下来供审计，而不是被猜测为安全。

Start/stop hook 只有在持有实例锁、并校验完整的有界保留事件 inventory 之后，才会选择自己的事件。随机数是来自 Python `secrets` 的 16 字节，只有精确读取 `/dev/urandom` 作为后备；冲突时重试八次。持锁期间的主路径失败，可能会向 DIAGNOSTICS 追加一条有界的逻辑 start-unarmed 或 stop-uncommitted 条目。对应的 `reconcile-start`/`reconcile-stop` 会校验它的三个标识字段以及所有目标槽位的代次/摘要，在每个固定 journal 边界续跑，并追加一份不可变的 RESOLVED_START 或 RESOLVED_STOP 回执。没有 token 的锁/随机数/inventory/冲突失败或双写失败，在磁盘上没有标识，也没有对账路径。

Legacy 迁移会先锁住经过清洗的旧来源，再锁住全哈希目标；把原始的 start 证据字节/时间戳复制进固定的目标记录；在固定槽位中提交迁移回执之后，才移除有界的 legacy 来源触发器。

这是 execute-task 工作流的确定性 watchdog 层。它加固了三条单靠提示词纪律无法保证的规则：

1. **静默/死亡的 subagent 会被发现。** 存活状态成为工具调用的机械副作用，死亡的角色会被报告给主 agent。
2. **状态文件保持新鲜。** 状态陈旧时会触发注入式提醒、退出门和停止门，而不是依赖模型自己记得。
3. **恢复绝不缩小要求。** 限缩角色必须交付内容的派发，会在到达角色之前被拒绝（L5）——缩减每轮输出量可以，缩减总交付不行。

所有 hook 都注册在 `hooks.json` 中（插件启用时自动加载），并且 fail open：任何输入缺失、JSON 解析器缺失（`jq` 或 `python3`）或写入错误，都会静默地以 exit 0 退出——watchdog 绝不能破坏或拖慢它所保护的工作流。除非能解析到**本会话的**任务指针，否则每个脚本都什么也不做。主 agent 在工作流 §1 启动任务时用 `scripts/task-pointer.sh arm` 写入这个指针。

**任务指针按会话区分（#23）。** 解析顺序（`zyz_task_roots`，先看会话 cwd，再看会话项目目录 `$CODEX_PROJECT_DIR` / `$CLAUDE_PROJECT_DIR`）：

1. `.zyz-worker/sessions/<session-id>`——本会话自己的指针，一行一个任务（task id、相对于该目录的路径，或绝对路径；悬空行跳过）。第一行是**主任务**。
2. `.zyz-worker/current-task`——旧的共享指针，只看第一行。**只在拿不到任何会话 id 时**才会读（也只有这时 `task-pointer.sh arm` 才会写它）。有会话 id、却没有自己的会话指针的会话，就是没有在这里 arm 过 execute-task：`current-task` 说明不了是哪个会话写的（0.28.0 之前的会话、别的会话在拿不到 id 时的 arm、残留文件），过去读它会让普通会话挂到目录最后指向的任务上，收到状态过期、会话静默、Stop 拦截和 IM（11-04 tipsy-ab-config 的事故：一个从没跑过 execute-task 的会话收到 5 次 watchdog 通知，最后用户让它把 watchdog 关掉）。仍靠 `current-task` 启用的旧会话，用 `task-pointer.sh arm` 重新 arm 一次即可；`task-pointer.sh show` 会标出被忽略的 `current-task`。
3. `$ZYZ_TASK_DIR`——显式覆盖：在 `claude` / `codex` 启动前导出到这个进程的环境里（按进程，不按目录）。

除此之外**不做任何搜索**（#18）：不搜同级 worktree，也不按"最新"或"未完成"去挑别的会话的指针——"哪个任务属于我"只能由会话身份决定。会话 id 的来源：hook 输入里的 `session_id`（已在 Claude Code 2.1.251 和 codex-cli 0.151.0 上实测：在 subagent 的 hook 里它仍是**父**会话的 id，并且等于 `$CLAUDE_CODE_SESSION_ID` / `$CODEX_THREAD_ID`）；没有 hook 输入时（watchdog）依次取 `$ZYZ_SESSION_ID`（Codex 的 `start-watchdog.sh` 设置）、`$CLAUDE_CODE_SESSION_ID`、`$CODEX_THREAD_ID`，Claude 的 monitor 还会额外认 `~/.claude/sessions/$CLAUDE_PID.json` 里的实时 id（monitor 的环境在启动时就固定了）。

归属规则：主 agent 相关的 hook（主心跳、main-state、status-freshness 的主 agent 提醒、L4 停止门、notify 的 awaiting-user 记录）作用于本会话的**每一个**任务，多个任务的拦截理由合并成一次；subagent 相关的 hook（subagent-track、subagent 心跳与提醒、L2、L5 日志、L6、post-agent-flush）把记录存在主任务下；IM 每个事件只发一条，冷却记在主任务下。

**subagent 类发现按会话、不按任务归属。** 主任务只是记账位置：hook 输入里没有任何字段说明某个 subagent 是为哪个任务派发的。因此 L3 和 L4 的 subagent 类发现（静默 / 跟踪未对账 / probe 逾期 / 无输出 / 已完成未收取）：只要本会话**任一**任务处于活跃阶段就会检查；"已完成未收取"比较的是本会话**所有**任务中最新的 `status.md` mtime（结果可能已写进别的任务）；多任务会话里消息不断言归属，而是列出全部任务、请主 agent 按派发记录判断，并单独写明记账目录（`finalize` 用它）；IM 的 `task_id` 是全部任务（`notify.sh --task-id`）。单任务会话的措辞不变。

manifest 依次通过宿主提供的 `PLUGIN_ROOT`、编排模式下的 `ZYZ_PLUGIN_ROOT`、`CLAUDE_PLUGIN_ROOT`，最后是 legacy、非规范的 `CODEX_PLUGIN_ROOT` 来解析 hook 脚本。未设置和空值都会落到下一个变量。如果所有 root 都缺失，hook 以 no-op 方式成功；它绝不会去搜索会话 cwd、源码 checkout 或 marketplace 路径。只写一个 `./hooks` 路径是不够的：Codex 0.147.0 会相对于 worker 的 cwd 解析它。工具 matcher 同时接受 Claude 的名字（`Agent`、`Bash`）和 Codex 的名字（`spawn_agent`/`collaboration.spawn_agent`、`exec_command`/`functions.exec`）。Hook 脚本按以下顺序解析基准目录：输入中的 `cwd`，然后 `CODEX_PROJECT_DIR`、`CLAUDE_PROJECT_DIR` 和 `$PWD`。Codex 没有 Claude 的 monitor manifest 生命周期，也没有 async-hook 通知通道，因此 `SessionStart` 会同步运行 `start-watchdog.sh`；这个简短的辅助脚本会把共享扫描器分离到一个按线程区分的临时日志中运行。Codex 的 L0/L1/Stop hook 仍然是会话内的强制执行路径。

设置 `ZYZ_HOOKS_DISABLE=1` 可禁用整个层。

Runtime 簿记数据存放在 `<task-dir>/runtime/` 下：

- `.snapshot-gc-owned.v1/.catalog-global-pack.v1`——经过认证的 catalog、调度、计数器，以及主 agent 的 `main_heartbeat_epoch` 记录。
- 固定的逐实例 audit/work pack——逻辑上的 IDENTITY、START、HEARTBEAT、DONE、FINALIZED、probe、诊断、回执、baseline-inventory 和 inflight 记录。记录名不是独立的路径名，只能通过共享解析器读取。
- `runtime/nag/*.last`——用于限频的冷却时间戳（epoch）。`expect-due-<key>` / `expect-dead-<key>-<ref>` 是声明提醒的标记（见上）；`subagent-waiting-<agent-id>` 是 L2 “以等待收尾”检查的逐实例一次性标记。
- `runtime/stop-snapshot`——`<epoch> <executor-count|unknown> <running-ids|-|unknown>`，L4 在每次 `Stop` 时写入（不论是否拦截、包括 `stop_hook_active` 时），记录宿主报告的执行者数量（已扣除 resident）和在跑的后台任务 id（L3 据此判断 `wait --ref` 绑定的任务是否已结束）；主 agent 的下一次工具调用（`heartbeat.sh`）或下一次用户发言（`main-state.sh`）会删掉它。所以它存在，就说明主 agent 自那次 Stop 之后什么都没做——L3 的“无执行者”扫描只读它，因为 monitor 看不到 `background_tasks`。
- `runtime/user-prompt-epoch`——最近一次 `UserPromptSubmit` 的 epoch（`kind=user` 声明的失效点）。
- `runtime/activity`——`<epoch> <main|agent_id>`，本会话最近一次工具调用（任何 agent），`heartbeat.sh` 写；会话静默的输入。
- `runtime/api-failures/*.rec` / `runtime/api-failures/reported/*.rec`——StopFailure 记录（待报告 / 已报告），`api-failure.sh` 写、watchdog 移动。

## scripts/lib.sh

- 触发点：被每个 hook 和 monitor 脚本 source；从不直接执行。
- 输入：由调用方设置的 `ZYZ_HOOK_INPUT`（原始 hook JSON）。
- 输出：只提供辅助函数（JSON 字段提取、mtime、原子写入、task-root 解析、additionalContext / block-decision JSON 输出，以及经过认证的 fixed-pack 观测）。
- 成本说明：`zyz_get` 每读一个字段就启动一个 `jq`（或 `python3`），热路径上的 hook 每次工具调用要读 2-3 个字段。心跳是同步的，因为当前版本的 Codex 会跳过 async hook；`status-freshness.sh` 也是同步的。**不要**试图通过把 `zyz_get` 缓存到 shell 变量里来解决这个问题——每个调用点都是 `x="$(zyz_get foo)"`，而命令替换在子 shell 中运行，所以缓存根本活不到下一次调用（试过、测过，没有收益；见 `lib.sh` 中的说明）。可行的做法是在 hook 脚本内部一次性完成提取。
- 失败行为：输入缺失时，每个辅助函数都不输出任何内容并返回成功；调用方 fail open。
- 支持的 agent：全部。兼容 macOS bash 3.2 和 Linux。

## scripts/heartbeat.sh — L0

- 触发点：`PreToolUse` + `PostToolUse`，matcher `*`，为跨 runtime 兼容而同步执行。在主 agent 和每个 subagent 内部都会触发。
- 输入：stdin 上的 hook JSON（`cwd`、`agent_id?`、`agent_type?`）；后备为 `CLAUDE_PROJECT_DIR`。
- 输出：stdout 无输出；为主 agent 更新 PACK_HEADER，为动态角色更新实例本地的固定 HEARTBEAT/INFLIGHT 记录；为每个调用者（主 agent、subagent、teammate）写 `runtime/activity`（会话静默的输入，不依赖 fixed-pack 能力和角色名）。主 agent 先写活动再写 main-state，所以 AskUserQuestion 打开的对话框不会早于打开它的那次调用。
- 失败行为：fail open，始终 exit 0。
- 支持的 agent：全部。

## scripts/subagent-track.sh — L0

- 触发点：`SubagentStart`，matcher 为 `^(zyz-worker:)?(implementation-agent|test-agent|review-agent)$`。
- 输入：stdin 上的 hook JSON（`cwd`、`agent_id`、`agent_type`）。
- 输出：stdout 无输出；提交固定的 IDENTITY/START journal 状态；对于 implementation/test 角色，在能力允许时还会发布一份固定的 LIVE_INVENTORY 基线。
- 失败行为：fail open。
- 支持的 agent：zyz-worker 角色（通过 matcher）。

## scripts/status-freshness.sh — L1

- 触发点：`PostToolUse`，matcher `*`，同步（上下文必须紧挨着工具结果落地）。**当 `tool_name` 为 `Agent` 时让位**——那个时刻归 `post-agent-flush.sh` 负责；它读的是同一个 mtime，否则会在同一轮里再注入一条几乎相同的提醒（两者的冷却相互独立，谁也压不住谁）。
- 输入：stdin 上的 hook JSON；`ZYZ_STATUS_STALE_SEC`（默认 600）、`ZYZ_STATUS_NAG_COOLDOWN_SEC`（默认 300）；任务的 `Tune: status-stale-sec` 可以放宽主 agent 的阈值，有效的 `wait` / `user` 声明压住主 agent 的提醒。
- 输出：当总状态文件在活跃阶段陈旧时，输出 `hookSpecificOutput.additionalContext`，提醒当前上下文（主 agent，或 implementation/test subagent）把进度持久化。按受众通过 `runtime/nag/<audience>.last` 限频。
- **未启用提示（唯一保留的"没 arm"提醒）。** 本会话解析不到任何任务、而**主 agent 自己**在用 Write / Edit / MultiEdit 修改某个未结束任务的 `.zyz-worker/tasks/<id>/status.md` 时：第一次只在 `<任务>/runtime/nag/unarmed-<session-id>` 记下时间（正常启动时 status.md 先写、几秒后才 arm）；`ZYZ_UNARMED_GRACE_SEC`（默认 300）秒之后再改，仍然没 arm，才注入一次提示，给出 `task-pointer.sh arm <任务目录>`，并说明任务若属于别的会话就忽略。每个会话每个任务只提示一次。证据只来自本会话自己的写入：目录里的任务、别的会话的指针、残留的 `current-task` 都不算；subagent 的写入、Bash / Read 调用也不算。Codex 的文件编辑不经过这里，所以 Codex 上没有这条提示（只会少报）。
- 失败行为：fail open；仅作提醒，绝不阻断。
- 支持的 agent：主 agent、implementation-agent、test-agent（review-agent 被排除——它不拥有需要刷新的状态文件；它的 Bash 权限只用于只读重跑和必须还原的临时变异，绝不用于写交付物）。

## scripts/post-agent-flush.sh — L1

- 触发点：`PostToolUse`，matcher `^Agent$`，同步（仅主 agent；当存在 `agent_id` 或这次启动是 `async_launched` 时直接退出）。
- 输入：stdin 上的 hook JSON；`ZYZ_POST_RESULT_FLUSH_SEC`（默认 120）、`ZYZ_POST_RESULT_COOLDOWN_SEC`（默认 60）。
- 输出：`additionalContext`，告诉主 agent 在派发后续工作之前，先把刚收到的 subagent 结果持久化到状态文件。
- 失败行为：fail open。
- 支持的 agent：主 agent。

## scripts/dispatch-scope-guard.sh — L5

这是唯一一个检查派发*要求了什么*的层；其它所有层都是事后观测。它之所以存在，是因为恢复路径有它自己的失败模式：当某个角色停滞时，诱人的修法是缩小要求让它能结束，于是一份只报告了最严重几条发现的评审，就会看起来干干净净地通过下游每一道闸门。

- 触发点：`PreToolUse`，matcher `^Agent$`，同步（deny 决定要求同步）。只检查 `subagent_type` 是 zyz-worker 角色的派发；其它一律原样放行。
- 输入：stdin 上的 hook JSON（`tool_input.prompt`、`tool_input.subagent_type`）；`ZYZ_SCOPE_GUARD_DISABLE=1` 只禁用这个守卫，`ZYZ_HOOKS_DISABLE=1` 禁用整个层。
- 输出：当提示词限缩了交付物（"only the top 3 findings"、"just the overall verdict"、"只要总结论"、"最严重 3 条"、"一句话结论"、"skip the details"），**并且**没有承诺交付其余部分（"then continue"、"the rest in later messages"、"step 1 of 4"、"分步"、"分维度"、"register all dimensions"）时，输出一个 `PreToolUse` deny（`hookSpecificOutput.permissionDecision: "deny"`——deny 理由会展示给模型，所以它可以纠正后重试）。理由会告诉主 agent 以完整范围重新派发，并拆成带标签的步骤。被拦下的尝试会追加到 `<task-dir>/runtime/scope-guard.log`。
- 三道防止过度匹配的保护，全部由 T7 钉住：
  1. **否定否决**——禁止截断的提示词（"do not just report the verdict"、"只要总结论是不够的"）永远不算限缩。它在引号剥离之前、基于**完整**文本判断，所以被引用的否定句依然保有否决权。
  2. **引号剥离**——限缩匹配针对的是一份把 `"…"`、`` `…` `` 和 `'…'` 片段清空后的副本，因此一个*引用*限缩短语的提示词（关于这个守卫本身的文档、测试、changelog 工作——在这里很常见）不会被当成在*发出*限缩。`'` 只有在空白或标点之后才会开启一个片段，所以英文缩写不会吞掉真实文本。有意的取舍：一个*完全*由被引用的限缩短语构成的提示词会被放行。
  3. **限缩必须指向一个评审交付物**（`findings|issues|problems`）。没有这一条，普通的领域需求也会被匹配上——"no more than 3 items per page"、"cap it at 3 attempts"。
- 失败行为：输入/解析器/指针缺失时 fail open（放行）。匹配天然是启发式的，因此才有上面的豁免和逐守卫的禁用开关；T7 钉住了 23 种必须被拒绝的限缩写法和 28 种必须放行的正当写法。T7 的载荷构造器会对提示词做 JSON 转义——如果直接插值一个包含 `"` 的 fixture，会得到非法 JSON，守卫随之 fail open，断言就会空转通过。
- 支持的 agent：派发 implementation-agent / test-agent / review-agent 的主 agent。

## scripts/task-pointer.sh

- 触发点：由**主 agent** 在自己的 Bash 中运行（execute-task §1 第 4 步）；从不由 hook 调用，也绝不交给 subagent（Codex sub-agent 的 shell 里 `$CODEX_THREAD_ID` 是它自己的子线程 id）。
- 用法：`task-pointer.sh arm <task-dir>` 把任务目录的绝对路径追加到 `.zyz-worker/sessions/<session-id>`（重复 arm 不重复写）；`disarm <task-dir>` 移除该行（文件空了就删掉）；`show` 打印会话 id、指针文件和 hooks 为本会话解析到的全部任务；`session-id` 只打印会话 id。`--base <dir>` 默认 `$PWD`（必须是会话 cwd），`--session-id <id>` / `$ZYZ_SESSION_ID` 可以显式指定。
- 会话 id：按最近的 `claude` / `codex` 祖先进程判定 harness，再取 `$CLAUDE_CODE_SESSION_ID`（外加 `~/.claude/sessions/<pid>.json` 里与之不同的实时 id）或 `$CODEX_THREAD_ID`。之所以看祖先进程而不是看变量是否存在，是因为这两个变量都会泄漏进嵌套启动的另一个 harness（例如由 Claude 会话启动的编排 worker 里跑的 Codex）。
- 失败行为：拿不到会话 id 时退回写共享的 `.zyz-worker/current-task`，并在 stderr 上提示它会被同目录下的其它会话覆盖、而且能拿到会话 id 的 hooks 不会读它；用法错误或任务目录不存在时以 exit 2 退出。绝不触碰其它会话的指针。`show` 在有会话 id 时会用一行 `ignored:` 标出目录里残留的 `current-task`。

## scripts/stop-gate-subagent.sh — L2

- 触发点：`SubagentStop`，与 subagent-track 使用相同的角色 matcher。**不保证**在 API 错误导致死亡时触发——这个缺口由 L3 覆盖。解析不到任务指针时什么也不做（这个门在 execute-task 工作流之外永远不生效）。
- 输入：stdin 上的 hook JSON（`stop_hook_active`、`last_assistant_message`）；`ZYZ_SUBAGENT_MIN_FINAL_CHARS`（默认 80，按**字节**计）。
- 输出：正常停止时，提交逻辑 DONE，关闭 active/probe/inflight 状态，并通过固定记录推进终止交接/清理。当最终消息短于最小值时，输出一次 `{"decision":"block","reason":...}`，要求该角色给出一份合格的最终报告；在被接受的那次停止之前，不会提交任何终止记录。
- **以等待收尾（#24）。** 最终消息的末尾几行匹配“等待完成通知 / monitor 通知 / 后台任务”一类措辞（中英文），**并且**该角色自己的会话记录（`agent_transcript_path`）里有后台启动的证据（`run_in_background: true` 的工具调用、Monitor、命令里的 `nohup` / `setsid` / 结尾 `&`）时，拦一次：subagent 一结束本轮就算完成，monitor 和后台进程都不会再唤醒它，主 agent 也不知道要去等——真实事故里，一次 60 分钟的全量用例跑绿了，却没人看，任务空等了约 30 分钟。拦截理由要求它前台等到结果，或者在最终报告里写明后台任务的 id、命令、输出路径、预计完成时间并明确交给主 agent。明确交给主 agent 跟进的移交报告（提到主 agent / main agent / hand off）不拦——那正是拦截要求它写的东西。宿主不提供会话记录时（Codex），只按措辞判断。每个角色实例最多拦一次（`runtime/nag/subagent-waiting-<agent-id>`），并且**在 `stop_hook_active` 时也会检查**——事故中那句“等待通知”正是角色对“最终消息过短”拦截的回应。被拦时不提交 DONE。
- 阈值刻意按字节计：`${#var}` 在 UTF-8 locale 下数的是字符，在 `LC_ALL=C` 下数的却是字节，所以一份完整的 45 个汉字的中文报告被量成 45，低于阈值 80 而被阻断。80 字节约等于 80 个 ASCII 字符或约 26 个 CJK 字符——两者都确实太短。
- 失败行为：fail open（允许停止）；`stop_hook_active` 为 true 时“过短”检查绝不阻断，“以等待收尾”检查由逐实例标记限定为一次；内置的 8 次阻断上限同样适用。
- 支持的 agent：zyz-worker 角色（通过 matcher）。

## scripts/api-failure.sh — L0（事实记录）

- 触发点：`StopFailure`，排在 `notify.sh` 之后，同步（timeout 10）。宿主在一轮因 API 错误结束时用它代替 Stop / SubagentStop，主会话、subagent、in-process teammate 里都会触发（后两者带公共字段 `agent_id` / `agent_type`）。宿主忽略它的输出。
- 输入：stdin 上的 hook JSON（`cwd`、`agent_id?`、`agent_type?`、`error`、`error_details?`、`last_assistant_message?`），一次解析取全部字段。
- 输出：stdout 无输出；在主任务下写一条 `runtime/api-failures/<epoch>-<pid>-<rand>.rec`（字段见 `## 会话静默与 API 错误中断`；空白折叠、`details` 截断到 300 字符、`agent_id` 不在安全字符集内时记为 `-`）；顺带清理 `reported/` 下 7 天前的记录。
- 失败行为：fail open——缺输入 / 指针 / python3、事件名不是 StopFailure、写失败，一律 exit 0、无副作用。
- 支持的 agent：全部。

## scripts/teammate-track.sh — L0（事实记录）

- 触发点：`PostToolUse`（matcher 同 post-agent-flush，派发工具）、`SubagentStart`（matcher `*`）、`TeammateIdle`，同步、无输出。
- 作用：记下 agent teams 的每个 teammate 这一轮是否结束，供 L4 / L3 的无执行者检查扣除空闲 teammate。全部记录在本会话主任务的 `runtime/teammates/` 下：`<name>.state`（`busy|idle <epoch>`，最后写的为准）、`<name>.keys`（它在 `background_tasks` 里可能出现的描述：派发时的 `description`，以及 prompt 前 50 个 UTF-16 单元加 `...`——2.1.251 实际列出的是后者）、`owned/<后台任务 id>`（这个后台任务是哪个 teammate 起的）。
- 事实来源（Claude Code 2.1.251 实测）：派发返回 `tool_response.status = teammate_spawned` → busy；teammate 每次开始一轮（派发、被 SendMessage 叫醒）都触发 `SubagentStart`，`agent_id` 是 `a<name>-<hex>`、`agent_type` 是名字 → busy；它的每次工具调用（`heartbeat.sh`）→ busy，Bash 的 `tool_response.backgroundTaskId` / Monitor 的 `tool_response.taskId` 记进 `owned/`；一轮结束触发 `TeammateIdle {teammate_name}` → idle。普通 subagent 的 `agent_id` 是 `a<hex>`，不会被当成 teammate。
- 扣除规则（`lib.sh zyz_teammate_entries`）：`teammate` 条目按描述对上记录过的 teammate，对上的全部空闲才扣除（多个 teammate 描述相同时，有一个在忙就都算执行者）；`shell` 条目由空闲 teammate 起的才扣除；对不上的照旧算执行者。快照的 id 字段不变（`wait --ref` 仍认为它们在跑），对上的条目另存 `runtime/stop-teammates`；L3 据此在 Stop 之后再判断一次：当时在忙、之后空闲满 `no-executor-sec` 的 teammate（及其后台任务）也不再算（它的空闲通知没送到主 agent，正是 L3 要兜的情形）。
- 已知局限：用户直接在界面里给 teammate 发的消息插件看不见，但它一旦调用工具就会被记成 busy；只思考不调用工具的那段时间会多拦一次（按 §2 由声明清掉）。Codex 没有 teammate，也没有 `TeammateIdle`。
- 失败行为：fail open；没有指针、没有 python3、写入失败时什么都不记，于是 teammate 照旧算执行者。

## scripts/stop-gate-main.sh — L4

- 触发点：`Stop`（主 agent 完成一次响应）。
- 输入：stdin 上的 hook JSON（`stop_hook_active`、`background_tasks`、`session_crons`）；`ZYZ_ROLE_STALE_SEC`（默认 900）、`ZYZ_ROLE_STALE_HORIZON_SEC`（默认 21600）、`ZYZ_STOP_STATUS_STALE_SEC`（默认 1200）、`ZYZ_STOP_GATE_COOLDOWN_SEC`（默认 600）。
- 输出：在活跃阶段，如果经过认证的观测器报告某个非终止角色的存活信号陈旧或跟踪尚未建立，且它并不在运行中的后台 subagent 任务列表里，或者状态文件严重陈旧，就输出 `{"decision":"block","reason":...}`。理由会列出需要检查的确切角色。通过 `runtime/nag/stopgate.last` 限频。
- **终止但未收取检查（主层）。** 除了上述理由之外，当某个角色已到达终止状态（按观测器的权威判定，为正常 DONE 或已裁决的 FINALIZED），但主 agent 自它完成以来一直空闲时，L4 也会阻断这次空闲——这是 subagent 完成通知丢失的症状：结果已经落盘，主 agent 却从未处理。判定条件（逐实例，三者同时满足）：`terminal` 为 true，**并且** `main_heartbeat_epoch <= terminal_epoch`（主 agent 最后一次工具调用早于完成时间），**并且** `status.md` 的 mtime `<= terminal_epoch`（此后没有写过状态）。用 `<=` 是有意为之：恰好相等时倾向于报出。每个 epoch 都有 `isinstance(int)` 守卫——缺少顶层 `main_heartbeat_epoch` 时退出过滤，缺少某个实例的 `terminal_epoch` 时跳过该实例——所以不可用的 epoch 绝不会抛异常。阻断理由会写明已完成的角色以及它的结果在哪里（它的 subtask 状态文件 / 持久日志），并指示：先读取结果并记录下来，再进入空闲。它**可以被满足且会自行解除**——读取结果再加上任意一次状态写入，都会把 `main_heartbeat_epoch`/mtime 推进到 `terminal_epoch` 之后，于是下一次停止时条件不再成立，阻断随之消失；它遵守 `stop_hook_active`，并与 角色陈旧阻断共用同一个 `runtime/nag/stopgate.last` 600 秒冷却令牌（在同一个窗口内，两者可能互相压制——这是被接受的）。这是作为**主层**的 L4：一次同步的 Stop-hook 检查，不依赖不可靠的完成通知通道，所以能确定地捕获常见情况（角色已结束、通知丢失、主 agent 想进入空闲）。它是一项**缓解措施**——减少主 agent 对已丢失的完成路径的依赖，而不是从根本上修复 harness 的投递层。和所有基于观测器的检查一样，它**在 macOS 上失效**（观测器返回 `genesis-capability-unavailable`），在 Linux 上生效——与死亡角色扫描的边界相同。
- **无执行者检查（#24）。** 前面每一条都只看**某个角色**有没有异常，于是有一种整体状态谁都不管：任务还有活，却没有任何执行者。真实事故：implementation-agent 在后台启动 60 分钟的全量用例后以“等待通知”收尾、被记为 DONE；用例跑绿时没有任何东西唤醒它；主 agent 一直在处理别的通道，所以“已完成未收取”不成立、状态文件也是新的；最后主 agent 说“数仓还在跑”然后停下，Stop 门放行，任务空等约 30 分钟。判定（逐任务，同时满足）：本任务处于活跃阶段且**还有活**（非 delivery 阶段，或 `## SubTasks` 记分板里还有 `Committed` 为空 / 占位 / 否定的行——列表和表格两种写法都解析）；宿主报告的 `background_tasks` 里没有未结束的任务、`session_crons` 为空（插件 monitor 不算执行者：本 watchdog 自己就以一个 `running` 的 shell 任务出现在列表里，已在 Claude Code 2.1.251 上实测；判据是命令路径含 `/monitors/watchdog.sh`，或同时含 `/plugins/` 和 `/monitors/`）；观察器看不到任何未结束、且在 horizon 内的已派发角色（会话级求和；观察器不可用时这一项不参与）；状态文件里没有有效的 `wait` / `user` 声明（见 `## 声明`）；声明为 `resident` 的后台任务不算执行者。**不**受 main-state 门控——空闲正是症状，不能当豁免。输入里没有 `background_tasks` 数组（Codex、任务注册表不可达）时视为未知，fail open。阻断理由点名未提交的 SubTask，并给出三条出路：派发下一步；核实你以为在跑的通道（ps / ListAgents / 后台任务输出）；或者用 `expect.sh` 声明在等什么。与其它子句共用 `stopgate.last` 冷却。三个 `## Agent State` 解析器都跳过 HTML 注释里的行——状态模板就在这个小节的注释里写着两种声明的示例行，否则它们会被当成格式错误的声明，让真实声明全部失效（这一点同样修正了 `Waiting On` 的旧问题）。记分板解析：`Committed` 的值里出现 commit sha（7–40 位十六进制，含多仓库写法里缩进的 `<repo>:<sha>` 续行、Markdown 链接、"本地 commit xxx"）就算已提交；空值、模板占位和否定词算未提交；其它文字（记录下来的提交失败）不算未提交。
- **无执行者检查的已知局限（如实说明）。** (1) **没有声明为 `resident` 的**常驻条目（主 agent 自己的 `tail -f` 类 Monitor、`run_in_background` 起的开发服务器、路径里不含 `/plugins/` 加 `/monitors/` 的其它插件 monitor、无关的循环 cron）一直在 `background_tasks` / `session_crons` 里，检查因此不会触发——只会漏报；声明之后就按 id 扣除。(2) 已结束的后台 subagent / shell 会从 `background_tasks` 里**消失**（已实测）；状态词表（`complet|fail|kill|stop|cancel|idle|done|error|exit|finish`）只是兜底。agent teams 的 teammate 只要还在就以 `running` 列出，空闲也一样；而空闲的 teammate 不会被它自己起的后台任务结束叫醒，完成通知一直排在它的队列里，直到有人给它发消息（Claude Code 2.1.251 实测，见 `scripts/fixtures/teammate-live-2.1.251.jsonl`；11-17 的事故里排了 30 分钟）。所以**空闲 teammate 和它起的后台任务都不算执行者**：`teammate-track.sh` / `heartbeat.sh` 记下每个 teammate 这一轮是否结束、它起了哪些后台任务，本门据此扣除（见 `## scripts/teammate-track.sh`）。插件没见过的 teammate（会话 arm 之前就派出的、描述对不上的）仍算执行者，只会漏报，由会话静默兜底。(3) `Awaiting-User` / `user` 声明的失效依赖 `UserPromptSubmit` 只在用户发言时触发。实测 Claude Code 2.1.251 在后台任务完成通知唤醒主 agent 时也触发它（`prompt` 是 `<task-notification>…`），所以声明会被这种唤醒提前作废，代价是多拦一次（会自愈）。(4) 被本门拦下的那次 Stop，`main-state.sh` 仍会照常写 `idle`（两个 hook 并行运行）；它只在交付阶段或 design 阶段才发 IM：执行阶段被拦的 Stop 不发；observing 阶段因没有排定检查被拦时，那次 Stop 仍会发一次「已交付」（每次进入只发一次，补上 `wait` 再停不会重复）。
- **"活跃阶段"排除任何带有 `design` 字样的阶段。** 单用 `*review*` 会匹配上 `design review`，导致这个门在 §2 第 8 步阻止主 agent 进入空闲——那是工作流唯一要求无限期等待人工批准的闸门——而提示词承诺在设计期间保持安静。`zyz_phase_active` 会先应用 `design` 排除。
- **状态陈旧受双重门控（主 agent 状态机）。** 状态陈旧归因子句只有在 agent 的声明（旧 `Waiting On:` 行，或有效的 `wait` / `user` 声明）和信号驱动的 main-state 压制（`zyz_main_state_suppresses`，主 agent 处于 `awaiting-user` / `idle` 时为 true）都未生效时才会触发——所以这个门绝不会仅仅因为主 agent 正当地停下来等用户或交还控制权而阻止空闲。角色陈旧子句和未收取子句归因于 subagent，**不**受门控：即使处于压制状态，L4 仍会阻断并点名死亡/未收取的 subagent（A 方案）。L4 只读 main-state；main-state.sh（同样挂在 `Stop` 上）只写它，所以两者与执行顺序无关；又因为 `idle` 和 `awaiting-user` 对 状态陈旧 的压制完全相同，无论哪个先运行，阻断理由都一样。
- **阻断必须能通过遵守规则来解除。** 这个门绝不要求调用方手工编辑 runtime。正常结束的角色通过 SubagentStop 提交 DONE；经平台/probe 证据确认死亡的角色，在重新派发之前用受支持的辅助命令 finalize；持久化的 start/stop 诊断只能通过它确切的 `reconcile-*` 事件 token 来处理。
- 失败行为：fail open（允许停止）。
- 支持的 agent：主 agent。

## scripts/checkout-guard.sh — L6

共享 worktree 的回退守卫。它源于一次真实事故：一个审计 agent 用 `git checkout <file>`——这会重置到 HEAD——来回退它的临时变异，结果删掉了另一个 agent 在同一文件中未提交的工作（约 5000 个字符的安全守卫代码）。从未提交过的内容不在**任何** git 恢复机制里，而且由于丢失的代码挂在一个运行时类型断言接缝之后，构建一直是绿的；恢复只能靠重放作者 agent 的会话记录。

- 触发点：`PreToolUse`，matcher `^Bash$`，同步（deny 要求同步）。只在会话有活跃任务指针时生效——普通（非任务）会话保留完整的 git 自由。
- 输入：stdin 上的 hook JSON（`cwd`、`tool_input.command`）；`ZYZ_CHECKOUT_GUARD_DISABLE=1` 只禁用这个守卫（用 shell 解析 shell 天然是启发式的，所以逐守卫的逃生口是必需的——与 L5 的策略相同），`ZYZ_HOOKS_DISABLE=1` 禁用整个层。
- 输出：当命令是 (a) `git checkout` / `git restore`，且指定的文件当前有**未提交的**修改（由 `git status --porcelain` 判定；干净的文件、分支名、`-b` 和未跟踪的路径都放行），或 (b) 会移动状态的 `git stash` 形式（bare / push / save / pop / apply / drop / clear——`list`/`show` 放行）时，输出一个 `PreToolUse` deny。deny 理由附带安全做法：变异前先 cp 备份、恢复时 mv 移回；用 `git show HEAD:<file>` 读取已提交的版本；用 `git diff > patch` + `git apply -R` 临时搁置改动。
- 失败行为：输入/解析器/指针缺失、没有 git、cwd 不在仓库内或 JSON 格式错误时，fail open（放行）。参数扫描在遇到第一个 shell 元字符时停止，所以后续命令中的词绝不会被误读为 checkout 目标。
- 支持的 agent：全部——事故中的那条命令来自一个 subagent。

## scripts/notify.sh — L7

IM 停止通知器。把"agent 停下来了"这类事件转发给用户配置的命令（飞书 / Telegram / 任意 webhook / 任意 shell），这样当工作流需要用户、已完成、失败或停滞时，用户都会收到提醒。配置 schema 以及可直接粘贴的飞书 / Telegram / webhook 配置示例见 [../docs/notify.md](../docs/notify.md)。

### IM 策略（0.32.0）

**只在任务需要人、或任务交给人的时候发 IM；任务还在执行时一律不发，由 watchdog 叫醒主 agent。** 0.32.0 之前每次主 agent 停下都发一条 `idle`，subagent 走一步、主 agent 收到结果正常推进，用户也会被打扰；watchdog 的每条发现也同时发 IM。现在：

| 类别 | 何时发 | 谁发 |
|---|---|---|
| `needs_input` | 有对话框打开（权限确认、MCP elicitation、`agent_needs_input`）；主 agent 调用 AskUserQuestion；主 agent `expect.sh set <key> user`（用自然语言提问，含 `--watch`）；主 agent 在 design 阶段停下、宿主报告没有执行者、也没有 `user` 声明（多半是停在设计批准闸门却忘了声明） | Notification hook；`heartbeat.sh`、`expect.sh`（都延迟 `ZYZ_NOTIFY_ASK_DELAY_SEC`=60 秒，期间用户已回复就不发）；`main-state.sh`（Stop） |
| `completed` | 任务进入交付阶段：`awaiting-confirmation`、`observing`、终态（`done` 等）。每次进入只发一次（`runtime/nag/handoff-phase` 记着上次宣布的阶段，回到其它阶段即清除） | `main-state.sh`（Stop） |
| `failed` | **主 agent 自己**这一轮因 API 错误结束——没有任何东西会让它继续。subagent / teammate 的失败不发，由 watchdog 告诉主 agent | StopFailure hook |
| `stuck` | **升级**：watchdog 向主 agent 报过某个发现，至少 `ZYZ_WATCHDOG_ESCALATE_SEC`（默认 600）秒之后再报时，会话里仍没有任何动作（工具调用、用户发言、状态写入都没有）——主 agent 叫不醒或叫醒了没处理。同一段静默每个任务只发一次（`runtime/nag/watchdog-escalate`），有了任何进展就重新开始 | `monitors/watchdog.sh` |
| `session_end` | 会话正常关闭（默认关闭） | SessionEnd hook |

`idle_prompt` Notification（停下约 60 秒、用户没有操作）和 `agent_completed` 不再发 IM；`idle` 类别已删除（配置里写了也不会发）。`user --watch` 就是用户说的「有问题要问、但还有别的活可以继续」：发 IM，watchdog 照常监控。

每条 IM 都带**会话名称**：标题前缀 `【<会话名>】`，以及 `ZYZ_NOTIFY_SESSION_NAME` / JSON 字段 `session_name`。名称取自 `lib.sh zyz_session_name`：Claude Code 是 transcript 里最后一条 `custom-title`（`/rename` 的名字），没有就最后一条 `ai-title`，再没有就 `~/.claude/sessions/*.json` 的 `name`；Codex 是 `~/.codex/session_index.jsonl` 最后一条 `thread_name`。名称从对话内容派生，所以随 `include_message` 一起关闭——关闭时标题前缀改用会话 id 的前 8 位。

- 触发点（hook 注册为 `async: true`，所以 IM 延迟绝不会拖慢工作流；每个还带有一个 `timeout` 兜底）：
  - `Notification`（matcher `*`；由脚本映射 `notification_type`）：`permission_prompt` / `agent_needs_input` / `elicitation_dialog` / `elicitation_url_dialog` → **needs_input**，同时把主 agent 状态记为 `awaiting-user`（通知带 `agent_id` 时归属者是那个 subagent）；`idle_prompt` 只把状态记为 `idle`、不发 IM；其它类型一律忽略。状态写入在配置门之前，所以即使没有配置 IM，状态机也能工作。
  - `StopFailure` → **failed**，仅限没有 `agent_id` 的（主 agent 自己的）记录。同一事件还由 `api-failure.sh` 记录下来，由 watchdog 告诉主 agent（见 `## 会话静默与 API 错误中断`）。
  - `SessionEnd` → **session_end**（仅限正常关闭；默认关闭）。
  - 直接调用：`heartbeat.sh`（AskUserQuestion）、`expect.sh`（`set … user`）→ `--event needs_input --delay <秒> --unless-user-since <epoch>`；`main-state.sh`（Stop）→ `--event completed` 或 design 阶段的 `--event needs_input`；`../monitors/watchdog.sh` → `--event stuck --origin main|subagent|stall`（仅升级时）。
- **stuck 的来源拆分（F2）。** `--origin`（默认 `main`）决定一条 `stuck` IM 能否穿过 main-state 压制：**main-origin** 的 stuck（watchdog 的状态陈旧发现）在主 agent 处于 `awaiting-user` / `idle` 时被丢弃（`exit 0`），而 **subagent-origin**（一个真正死亡/静默的角色）和 **stall-origin**（#24：任务已没有任何执行者 / 会话静默 / 到点无人处理）会绕过这道门——此时主 agent 空闲正是要报告的症状。
- 输入：stdin 上的 hook JSON（hook 模式，读 `session_id` / `transcript_path` 取会话名）或 `--event/--title/--message/--task-root/--base/--session-id/--transcript/--origin/--task-id/--delay/--unless-user-since`（直接调用模式；`--delay` 先睡再发，调用方放到后台；`--unless-user-since` 在任务的 `runtime/user-prompt-epoch` 晚于给定 epoch 时丢弃——用户已经回答了）；配置文件 `~/.zyz-worker/notify.json`（可用 `$ZYZ_NOTIFY_CONFIG` 覆盖）。
- 配置键：`enabled`（bool）、`command`（字符串；以 `ZYZ_NOTIFY_*` 环境变量和 stdin 上的 JSON 对象两种形式接收事件）、`events`（可选白名单——缺省时默认集合为 `needs_input`/`completed`/`failed`/`stuck`，即排除 `session_end`）、`cooldown_sec`（可选，默认 30；按类别计，`runtime/nag/notify-<类别>.last`）、`include_message`（可选，默认 true——设为 false 时只发送类别/任务，不带任何自由文本消息内容）。
- 作用范围：与其它所有 hook 一样，除非能解析到本会话的任务指针，否则什么也不做，所以普通的交互式会话永远不会收到通知。
- 失败行为：fail open——输入/配置/解析器/指针缺失、配置被禁用、事件被过滤或冷却生效时，以 exit 0 退出且没有任何副作用；用户命令失败绝不会向上传播。
- **覆盖边界（如实说明）：** 真正的整个进程死亡——`kill -9`、OOM、关闭终端、网络/SSH 断开——不会触发任何 hook，还会把 watchdog monitor 一起带走，所以**不在**覆盖范围内。`stuck` 捕获的是会话内的情况（进程仍存活，但某个角色静默了 / 工作流停滞了）。要可靠地检测宿主机崩溃，需要一个完全外部的守护进程（未来可能加入）。
- 禁用：`ZYZ_NOTIFY_DISABLE=1` 只关闭通知器；`ZYZ_HOOKS_DISABLE=1` 关闭整个层。
- 支持的 agent：主 agent（Notification/StopFailure/SessionEnd 是主会话事件；subagent 的 StopFailure 被忽略），以及 heartbeat.sh / expect.sh（needs_input）、main-state.sh（completed / needs_input）和 watchdog monitor（stuck）。

## ../monitors/watchdog.sh — L3

见 `monitors/monitors.json`：这是一个以 `when: "always"` 启用的后台 monitor（所以它随会话启动），并以本会话的任务指针自我门控，在有任务处于活跃状态之前一直处于失效状态；会话指针里列出的每个任务都分别扫描、分别报告（冷却标记也按任务记在各自的 `runtime/nag/` 下）。**本会话没有 arm 任何任务时它完全安静**：因为它随每个会话启动，目录里能看到的东西（未结束的任务目录、别的会话的指针、残留的 `current-task`）都说明不了本会话在跑 execute-task。0.32.1 及之前，只要存在一个未完成、且没有被任何会话指针认领的任务目录，它就会报一次"未启用"——在留有废弃任务的仓库里打开的每个普通会话都会收到这条误报；现在改由 `status-freshness.sh` 按本会话自己的写入提示（见上）。它刻意**不**使用 `on-skill-invoke:execute-task`：这个值是与发出的 skill 名做精确字符串比较的，而同一个 skill 在插件安装方式下发出的是 `zyz-worker:execute-task`，在项目模式下发出的却是裸的 `execute-task`——一个字面量无法在两种情况下都生效；裸写法曾经发布过一段时间，在正常安装下从未生效过。它每隔 `ZYZ_WATCHDOG_INTERVAL_SEC`（默认 60）扫描一次心跳和状态文件 mtime，每个发现输出一行通知（角色静默 / 状态陈旧 / 会话静默 / API 错误中断 / 声明相关），即使会话处于空闲也能唤醒主 agent。会话静默与 API 错误中断见 `## 会话静默与 API 错误中断`，阈值 `ZYZ_WATCHDOG_SILENCE_SEC`（默认 3600）、`ZYZ_WATCHDOG_FAILURE_COOLDOWN_SEC`（默认 600）。这就是捕获被 API 错误杀死的 subagent 的那一层——那种情况下 `SubagentStop` 永远不会触发。阈值：`ZYZ_WATCHDOG_ROLE_STALE_SEC`（默认 1200——刻意高于 L4 门的阈值，因为 L3 无法交叉核对 `background_tasks`，而健康的角色也可能在不调用工具的情况下推理一段时间；它的消息要求主 agent 先**核实**，而不是盲目重启）、`ZYZ_WATCHDOG_STATUS_STALE_SEC`（默认 1800），冷却 `ZYZ_WATCHDOG_COOLDOWN_SEC`（默认 900）。

**main-state 门控 + 来源拆分。** 每轮扫描都会读取主 agent 状态文件（`zyz_main_state_suppresses`，在 `awaiting-user` / `idle` 时为 true）。压制期间，**状态陈旧**发现会被静音——它的 stdout 行和它的 main-origin `stuck` IM 都会——因为它归因于主 agent，而主 agent 此时正当地没有在工作。这是纯字符串比较（不看 epoch，没有 TTL），所以用户等上几个小时也绝不会让它重新触发。**subagent** 类发现（stale / tracking / probe / no-output / unharvested）**绝不**受压制门控（A 方案）：它们的 stdout 总会输出，升级时的 `stuck` IM 带有 `--origin subagent`，所以即使处于压制状态、即使用户离线，notify.sh 也会把它们转发给用户。所有发现的 IM 都只在升级时发：先叫醒主 agent，主 agent 没有动作才通知用户（`notify_stuck`，见 `### IM 策略`）。状态陈旧的 `stuck` 使用 `--origin main`（默认值），notify.sh 在压制状态下会丢弃它。状态文件缺失或损坏时 fail open，恢复完整告警。

实例循环不再盲目跳过终止实例：非终止实例走现有的存活信号陈旧、跟踪未建立、probe 逾期、无输出这几个分支，终止实例则走新的**终止但未收取扫描（备份层）**。当某个角色已到达终止状态、但主 agent 此后一直空闲时触发——判定条件与 L4 相同（`terminal` **并且** `main_heartbeat_epoch <= terminal_epoch` **并且** `status.md` mtime `<= terminal_epoch`，相同的 `isinstance(int)` 守卫，相同的有意使用的 `<=` 边界）。由于新的终止分支与循环共用同一个 `try/except`，这些 epoch 守卫是承重的：没有它们，`None <= int` 会抛异常并中止整个循环，丢掉其它所有实例的事件——所以缺少 epoch 时只会对该实例 `continue`，其余实例不受影响。命中时，它输出一行 `unharvested` 通知，点名已完成的角色及其结果位置，并通过按键区分的 `runtime/nag/watchdog-unharvested-<key>.last` 限频（它有自己的冷却，独立于 watchdog 的其它键）。这是 L4 的**备份**：它覆盖 L4 覆盖不到的情况——角色是在主 agent **已经**进入空闲*之后*才进入终止状态的（L4 已经放行了那次停止），这时只有定时器能把主 agent 唤醒。消息会说明这是一个备份信号；检测走的是 watchdog 通知路径，本会话的观察表明它比完成通知路径更可靠，但并不保证（因此同步的 L4 才是主层）。和死亡角色扫描一样，它**在 macOS 上失效**，在 Linux 上生效。

**声明扫描（#24，`scan_declarations`）。** 每轮对本会话每个活跃或 observing 的任务：(1) 到点的 `wait`：叫醒主 agent，之后按 `remind-sec` 再提醒，提醒后无人处理才升级成 stall IM；(2) `wait --ref` 绑定的后台任务在上次 Stop 的列表里已经没有了：报一次；(3) observing 却没有排定检查：每 `ZYZ_WATCHDOG_OBSERVE_SEC` 提醒一次；(4) **无执行者**（L4 的定时兜底）：任务处于活跃阶段且还有活（判据同 L4）；`runtime/stop-snapshot` 存在（主 agent 自上次 Stop 以来没有任何工具调用、用户也没有发言）、记录的执行者数为 0、且已过去至少 `no-executor-sec`（Tune，默认 `ZYZ_WATCHDOG_NO_EXECUTOR_SEC`=600）秒；本会话没有未结束的已派发角色；没有有效的 `wait` / `user` 声明；也没有已到点的 `wait`（它已有更具体的提醒）。命中时输出一行通知（措辞同 L4），按 `runtime/nag/watchdog-no-executor.last` 冷却限频。所有这些发现的 IM 都只在升级时发（`notify_stuck`）。它覆盖 L4 漏掉的情况：Stop 落在 L4 冷却期内，或者 Stop 时还有执行者、之后才结束。Stop 时在忙的 teammate 之后结束这一轮、空闲满 `no-executor-sec`，它（和它起的后台任务）也从快照的计数里扣除（`runtime/stop-teammates`）。这四项都**不**看 main-state：主 agent 停下后状态就是 `idle`，用它压制等于永不报警，所以只有声明能让它安静；它们升级时的 IM 都用 `--origin stall`，绕过 notify.sh 的空闲压制。快照记为 `unknown`（Codex）时 (4) 保持安静。已知盲区：Stop 时执行者数 ≥1，而那个执行者结束后的完成通知又没有送达主 agent，快照会停在非零值，(4) 不会报——在 Linux 上"已完成未收取"检查兜住 subagent 这一半。(2) 也兜不住：快照只在 Stop 时写一次，只能发现"Stop 时就已经不在了"的任务；那个执行者结束后的完成通知本身会唤醒主 agent，丢失时才会落进这个盲区。

## 降级环境

插件 hook 可能被托管策略阻止，monitor 在某些平台/版本上也不可用。无论如何，工作流在提示词层面的职责（`## 长期运行工作`、`## 核心规则` 中的刷新规则）依然有效，并在那些环境中成为唯一的强制手段——watchdog 是兜底，而不是替代。

**对 fixed-pack 跟踪层而言，macOS（Darwin）是降级平台。** catalog genesis 需要原生的逐 vnode 挂载标识，而 macOS 没有任何 API 能区分第二个同 FSID 的挂载实例，所以在 Darwin 上，每一个跟踪状态操作（`hook-start`、`hook-stop`、`hook-heartbeat`、`hook-observe`、`finalize`、probe、`gc-step`）都会以 `genesis-capability-unavailable` fail closed。后果是：不会写入任何实例状态，L3 watchdog 和 L4 停止门都拿不到角色观测——**在 macOS 上，死亡角色检测处于禁用状态**，包括被 API 错误杀死的情况。一切仍保持 fail-open（不会阻断、崩溃，除了约 100 毫秒的 hook 启动开销之外也不会拖慢），仍在工作的层是状态文件陈旧分支（L1/L3/L4）、无执行者与声明相关的检查、0.32.0 起的会话静默与 API 错误中断（被 API 错误杀死的角色在 macOS 上由后者报告）、L2 的最终消息过短门，以及提示词纪律。主 agent 提示词要求在任务开始时核实 `main_heartbeat_epoch`，无法核实时声明 watchdog 失效——在 macOS 上这项检查会如实失败，于是每个任务都会给出这条披露。Linux 宿主（包括容器）完全受支持。
