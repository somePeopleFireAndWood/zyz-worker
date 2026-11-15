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

有界等待只能写在 `status.md` 中唯一的 `## Agent State` 小节里，格式为 `- Waiting On: instance-key=<key>; since-epoch=<unix>; next-check-epoch=<unix>; reason=<single-line text>`。所有行都必须有效、唯一、未过期，并且不超过 `ZYZ_WAIT_MAX_SEC`。一组有效的等待声明只会压制主 agent 的状态陈旧提醒。

## 主 agent 状态机（纯信号驱动，无 TTL）

与上面的 fixed-pack subagent 协议相互独立，主 agent 自身的存活状态是一个单行文件 `<task-dir>/runtime/main-state`，内容为 `<state> <epoch>`，其中 `<state>` ∈ `working` / `awaiting-user` / `idle` / `ended`。Hook 在经过平台验证的状态转换点写入它：`UserPromptSubmit` 以及主 agent 每一次 `PreToolUse`/`PostToolUse` 心跳 → `working`；原始 `notification_type` 为 `permission_prompt` / `agent_needs_input` / `elicitation_dialog` / `elicitation_url_dialog` / `idle_prompt` 的 `Notification` → `awaiting-user`；`Stop` → `idle`（带覆盖豁免：已有的 `awaiting-user` **不会**被覆盖，这样就不会误判为"已交还给用户"）；`SessionEnd` → `ended`。

L3（watchdog）和 L4（停止门）通过 `zyz_main_state_suppresses` 读取它；当状态为 `awaiting-user` 或 `idle` 时，该函数返回 true。压制判断是纯字符串比较——**epoch 只为诊断而写，绝不会被读出来做时间比较，所以不存在 TTL，等上 15 个小时也绝不会"过期"**。压制期间，归因于主 agent 的 **状态陈旧**发现会被静音（L3 的 stdout 及其 main-origin `stuck` IM；L4 的 状态陈旧阻断子句）。手动的 `Waiting On:` 守卫和这个信号驱动的状态互为补充、按 OR 组合：任意一个生效都会压制 状态陈旧。状态文件缺失或损坏时 fail open，恢复完整告警。归因于 subagent 的发现绝不会被压制（见 L3/L4）。

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

所有 hook 都注册在 `hooks.json` 中（插件启用时自动加载），并且 fail open：任何输入缺失、JSON 解析器缺失（`jq` 或 `python3`）或写入错误，都会静默地以 exit 0 退出——watchdog 绝不能破坏或拖慢它所保护的工作流。除非会话 cwd 中有一个 `.zyz-worker/current-task` 指针（第一行：task id 或任务目录路径），并且它解析到一个已存在的任务目录，否则每个脚本都什么也不做。主 agent 在工作流 §1 启动任务时写入这个指针。

manifest 依次通过宿主提供的 `PLUGIN_ROOT`、编排模式下的 `ZYZ_PLUGIN_ROOT`、`CLAUDE_PLUGIN_ROOT`，最后是 legacy、非规范的 `CODEX_PLUGIN_ROOT` 来解析 hook 脚本。未设置和空值都会落到下一个变量。如果所有 root 都缺失，hook 以 no-op 方式成功；它绝不会去搜索会话 cwd、源码 checkout 或 marketplace 路径。只写一个 `./hooks` 路径是不够的：Codex 0.147.0 会相对于 worker 的 cwd 解析它。工具 matcher 同时接受 Claude 的名字（`Agent`、`Bash`）和 Codex 的名字（`spawn_agent`/`collaboration.spawn_agent`、`exec_command`/`functions.exec`）。Hook 脚本按以下顺序解析基准目录：输入中的 `cwd`，然后 `CODEX_PROJECT_DIR`、`CLAUDE_PROJECT_DIR` 和 `$PWD`。Codex 没有 Claude 的 monitor manifest 生命周期，也没有 async-hook 通知通道，因此 `SessionStart` 会同步运行 `start-watchdog.sh`；这个简短的辅助脚本会把共享扫描器分离到一个按线程区分的临时日志中运行。Codex 的 L0/L1/Stop hook 仍然是会话内的强制执行路径。

设置 `ZYZ_HOOKS_DISABLE=1` 可禁用整个层。

Runtime 簿记数据存放在 `<task-dir>/runtime/` 下：

- `.snapshot-gc-owned.v1/.catalog-global-pack.v1`——经过认证的 catalog、调度、计数器，以及主 agent 的 `main_heartbeat_epoch` 记录。
- 固定的逐实例 audit/work pack——逻辑上的 IDENTITY、START、HEARTBEAT、DONE、FINALIZED、probe、诊断、回执、baseline-inventory 和 inflight 记录。记录名不是独立的路径名，只能通过共享解析器读取。
- `runtime/nag/*.last`——用于限频的冷却时间戳（epoch）。

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
- 输出：stdout 无输出；为主 agent 更新 PACK_HEADER，为动态角色更新实例本地的固定 HEARTBEAT/INFLIGHT 记录。
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
- 输入：stdin 上的 hook JSON；`ZYZ_STATUS_STALE_SEC`（默认 600）、`ZYZ_STATUS_NAG_COOLDOWN_SEC`（默认 300）。
- 输出：当总状态文件在活跃阶段陈旧时，输出 `hookSpecificOutput.additionalContext`，提醒当前上下文（主 agent，或 implementation/test subagent）把进度持久化。按受众通过 `runtime/nag/<audience>.last` 限频。
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

## scripts/stop-gate-subagent.sh — L2

- 触发点：`SubagentStop`，与 subagent-track 使用相同的角色 matcher。**不保证**在 API 错误导致死亡时触发——这个缺口由 L3 覆盖。没有 `current-task` 指针时什么也不做（这个门在 execute-task 工作流之外永远不生效）。
- 输入：stdin 上的 hook JSON（`stop_hook_active`、`last_assistant_message`）；`ZYZ_SUBAGENT_MIN_FINAL_CHARS`（默认 80，按**字节**计）。
- 输出：正常停止时，提交逻辑 DONE，关闭 active/probe/inflight 状态，并通过固定记录推进终止交接/清理。当最终消息短于最小值时，输出一次 `{"decision":"block","reason":...}`，要求该角色给出一份合格的最终报告；在被接受的那次停止之前，不会提交任何终止记录。
- 阈值刻意按字节计：`${#var}` 在 UTF-8 locale 下数的是字符，在 `LC_ALL=C` 下数的却是字节，所以一份完整的 45 个汉字的中文报告被量成 45，低于阈值 80 而被阻断。80 字节约等于 80 个 ASCII 字符或约 26 个 CJK 字符——两者都确实太短。
- 失败行为：fail open（允许停止）；`stop_hook_active` 为 true 时绝不阻断；内置的 8 次阻断上限同样适用。
- 支持的 agent：zyz-worker 角色（通过 matcher）。

## scripts/stop-gate-main.sh — L4

- 触发点：`Stop`（主 agent 完成一次响应）。
- 输入：stdin 上的 hook JSON（`stop_hook_active`、`background_tasks`）；`ZYZ_ROLE_STALE_SEC`（默认 900）、`ZYZ_ROLE_STALE_HORIZON_SEC`（默认 21600）、`ZYZ_STOP_STATUS_STALE_SEC`（默认 1200）、`ZYZ_STOP_GATE_COOLDOWN_SEC`（默认 600）。
- 输出：在活跃阶段，如果经过认证的观测器报告某个非终止角色的存活信号陈旧或跟踪尚未建立，且它并不在运行中的后台 subagent 任务列表里，或者状态文件严重陈旧，就输出 `{"decision":"block","reason":...}`。理由会列出需要检查的确切角色。通过 `runtime/nag/stopgate.last` 限频。
- **终止但未收取检查（主层）。** 除了上述理由之外，当某个角色已到达终止状态（按观测器的权威判定，为正常 DONE 或已裁决的 FINALIZED），但主 agent 自它完成以来一直空闲时，L4 也会阻断这次空闲——这是 subagent 完成通知丢失的症状：结果已经落盘，主 agent 却从未处理。判定条件（逐实例，三者同时满足）：`terminal` 为 true，**并且** `main_heartbeat_epoch <= terminal_epoch`（主 agent 最后一次工具调用早于完成时间），**并且** `status.md` 的 mtime `<= terminal_epoch`（此后没有写过状态）。用 `<=` 是有意为之：恰好相等时倾向于报出。每个 epoch 都有 `isinstance(int)` 守卫——缺少顶层 `main_heartbeat_epoch` 时退出过滤，缺少某个实例的 `terminal_epoch` 时跳过该实例——所以不可用的 epoch 绝不会抛异常。阻断理由会写明已完成的角色以及它的结果在哪里（它的 subtask 状态文件 / 持久日志），并指示：先读取结果并记录下来，再进入空闲。它**可以被满足且会自行解除**——读取结果再加上任意一次状态写入，都会把 `main_heartbeat_epoch`/mtime 推进到 `terminal_epoch` 之后，于是下一次停止时条件不再成立，阻断随之消失；它遵守 `stop_hook_active`，并与 角色陈旧阻断共用同一个 `runtime/nag/stopgate.last` 600 秒冷却令牌（在同一个窗口内，两者可能互相压制——这是被接受的）。这是作为**主层**的 L4：一次同步的 Stop-hook 检查，不依赖不可靠的完成通知通道，所以能确定地捕获常见情况（角色已结束、通知丢失、主 agent 想进入空闲）。它是一项**缓解措施**——减少主 agent 对已丢失的完成路径的依赖，而不是从根本上修复 harness 的投递层。和所有基于观测器的检查一样，它**在 macOS 上失效**（观测器返回 `genesis-capability-unavailable`），在 Linux 上生效——与死亡角色扫描的边界相同。
- **"活跃阶段"排除任何带有 `design` 字样的阶段。** 单用 `*review*` 会匹配上 `design review`，导致这个门在 §2 第 8 步阻止主 agent 进入空闲——那是工作流唯一要求无限期等待人工批准的闸门——而提示词承诺在设计期间保持安静。`zyz_phase_active` 会先应用 `design` 排除。
- **状态陈旧受双重门控（主 agent 状态机）。** 状态陈旧归因子句只有在手动 `Waiting On:` 守卫（`zyz_status_waiting`）和信号驱动的 main-state 压制（`zyz_main_state_suppresses`，主 agent 处于 `awaiting-user` / `idle` 时为 true）都未生效时才会触发——所以这个门绝不会仅仅因为主 agent 正当地停下来等用户或交还控制权而阻止空闲。角色陈旧子句和未收取子句归因于 subagent，**不**受门控：即使处于压制状态，L4 仍会阻断并点名死亡/未收取的 subagent（A 方案）。L4 只读 main-state；main-state.sh（同样挂在 `Stop` 上）只写它，所以两者与执行顺序无关；又因为 `idle` 和 `awaiting-user` 对 状态陈旧 的压制完全相同，无论哪个先运行，阻断理由都一样。
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

- 触发点（全部注册为 `async: true`，所以 IM 延迟绝不会拖慢工作流；每个还带有一个 `timeout` 兜底）：
  - `Notification`（matcher `*`；由脚本映射 `notification_type`）：`permission_prompt` / `agent_needs_input` / `elicitation_dialog` / `elicitation_url_dialog` → **needs_input**；`agent_completed` / `idle_prompt` → **completed**；其它类型一律忽略。这些只在用户离开时才触发（权限确认约 6 秒，空闲结束后约 60 秒），所以正在打字的用户不会收到提醒。与 IM 类别无关，原始 `notification_type` 为 `permission_prompt` / `agent_needs_input` / `elicitation_dialog` / `elicitation_url_dialog` / `idle_prompt` 的 Notification 还会把主 agent 状态记录为 `awaiting-user`（在配置门之前，所以即使没有配置 IM，状态机也能工作）。判断读的是原始类型而不是折叠后的类别，所以 `idle_prompt`（在 IM 中折叠为 `completed`）仍会记录为 `awaiting-user`。
  - `StopFailure` → **failed**（API 错误导致的终止：rate_limit / authentication / overloaded / server_error——错误文本作为消息内容）。
  - `SessionEnd` → **session_end**（仅限正常关闭；默认关闭）。
  - `../monitors/watchdog.sh` 在发现角色静默 / 状态陈旧 / 完成未收取时直接调用 `notify.sh --event stuck --task-root <dir> --message <m> [--origin main|subagent]` → **stuck**。
  - `main-state.sh` 在活跃阶段的某次 `Stop` 写入了 `idle` 时直接调用 `notify.sh --event idle --task-root <dir>` → **idle**（"agent 已停下并交还给你"）。活跃阶段过滤和"确实写入了 idle（而不是因豁免而跳过）"这一条件都在 main-state.sh 中；notify.sh 只负责配置门控、冷却和发送。
- **stuck 的来源拆分（F2）。** `--origin`（默认 `main`）决定一条 `stuck` IM 能否穿过 main-state 压制：**main-origin** 的 stuck（watchdog 的状态陈旧发现）在主 agent 处于 `awaiting-user` / `idle` 时被丢弃（`exit 0`），而 **subagent-origin** 的 stuck（一个真正死亡/静默的角色）会绕过这道门、总是发送，所以离线的用户依然会被叫到。needs_input IM 不受门控——只有 main-origin 的 stuck 才受。
- 输入：stdin 上的 hook JSON（hook 模式）或 `--event/--title/--message/--task-root/--base/--session-id/--origin`（直接调用模式）；配置文件 `~/.zyz-worker/notify.json`（可用 `$ZYZ_NOTIFY_CONFIG` 覆盖）。
- 配置键：`enabled`（bool）、`command`（字符串；以 `ZYZ_NOTIFY_*` 环境变量和 stdin 上的 JSON 对象两种形式接收事件）、`events`（可选白名单——缺省时默认集合为 `needs_input`/`completed`/`failed`/`stuck`/`idle`，即排除 `session_end`；在这里加上或去掉 `idle`，即可控制"已停下并交还"这条提醒）、`cooldown_sec`（可选，默认 30；按类别计——`idle` 类别通过 `runtime/nag/notify-idle.last` 冷却）、`include_message`（可选，默认 true——设为 false 时只发送类别/任务，不带任何自由文本消息内容）。
- 作用范围：与其它所有 hook 一样，除非能解析到 `.zyz-worker/current-task` 指针，否则什么也不做，所以普通的交互式会话永远不会收到通知。
- 失败行为：fail open——输入/配置/解析器/指针缺失、配置被禁用、事件被过滤或冷却生效时，以 exit 0 退出且没有任何副作用；用户命令失败绝不会向上传播。
- **覆盖边界（如实说明）：** 真正的整个进程死亡——`kill -9`、OOM、关闭终端、网络/SSH 断开——不会触发任何 hook，还会把 watchdog monitor 一起带走，所以**不在**覆盖范围内。`stuck` 捕获的是会话内的情况（进程仍存活，但某个角色静默了 / 工作流停滞了）。要可靠地检测宿主机崩溃，需要一个完全外部的守护进程（未来可能加入）。
- 禁用：`ZYZ_NOTIFY_DISABLE=1` 只关闭通知器；`ZYZ_HOOKS_DISABLE=1` 关闭整个层。
- 支持的 agent：主 agent（Notification/StopFailure/SessionEnd 是主会话事件），以及 watchdog monitor（stuck）和 main-state.sh（idle）。

## ../monitors/watchdog.sh — L3

见 `monitors/monitors.json`：这是一个以 `when: "always"` 启用的后台 monitor（所以它随会话启动），并以 `.zyz-worker/current-task` 指针自我门控，在有任务处于活跃状态之前一直处于失效状态。它刻意**不**使用 `on-skill-invoke:execute-task`：这个值是与发出的 skill 名做精确字符串比较的，而同一个 skill 在插件安装方式下发出的是 `zyz-worker:execute-task`，在项目模式下发出的却是裸的 `execute-task`——一个字面量无法在两种情况下都生效；裸写法曾经发布过一段时间，在正常安装下从未生效过。它每隔 `ZYZ_WATCHDOG_INTERVAL_SEC`（默认 60）扫描一次心跳和状态文件 mtime，每个发现输出一行通知（角色静默 / 状态陈旧），即使会话处于空闲也能唤醒主 agent。这就是捕获被 API 错误杀死的 subagent 的那一层——那种情况下 `SubagentStop` 永远不会触发。阈值：`ZYZ_WATCHDOG_ROLE_STALE_SEC`（默认 1200——刻意高于 L4 门的阈值，因为 L3 无法交叉核对 `background_tasks`，而健康的角色也可能在不调用工具的情况下推理一段时间；它的消息要求主 agent 先**核实**，而不是盲目重启）、`ZYZ_WATCHDOG_STATUS_STALE_SEC`（默认 1800），冷却 `ZYZ_WATCHDOG_COOLDOWN_SEC`（默认 900）。

**main-state 门控 + 来源拆分。** 每轮扫描都会读取主 agent 状态文件（`zyz_main_state_suppresses`，在 `awaiting-user` / `idle` 时为 true）。压制期间，**状态陈旧**发现会被静音——它的 stdout 行和它的 main-origin `stuck` IM 都会——因为它归因于主 agent，而主 agent 此时正当地没有在工作。这是纯字符串比较（不看 epoch，没有 TTL），所以用户等上几个小时也绝不会让它重新触发。**subagent** 类发现（stale / tracking / probe / no-output / unharvested）**绝不**受压制门控（A 方案）：它们的 stdout 总会输出，它们的 `stuck` IM 带有 `--origin subagent`，所以即使处于压制状态、即使用户离线，notify.sh 也会把它们转发给用户。状态陈旧的 `stuck` 使用 `--origin main`（默认值），notify.sh 在压制状态下会丢弃它。状态文件缺失或损坏时 fail open，恢复完整告警。

实例循环不再盲目跳过终止实例：非终止实例走现有的存活信号陈旧、跟踪未建立、probe 逾期、无输出这几个分支，终止实例则走新的**终止但未收取扫描（备份层）**。当某个角色已到达终止状态、但主 agent 此后一直空闲时触发——判定条件与 L4 相同（`terminal` **并且** `main_heartbeat_epoch <= terminal_epoch` **并且** `status.md` mtime `<= terminal_epoch`，相同的 `isinstance(int)` 守卫，相同的有意使用的 `<=` 边界）。由于新的终止分支与循环共用同一个 `try/except`，这些 epoch 守卫是承重的：没有它们，`None <= int` 会抛异常并中止整个循环，丢掉其它所有实例的事件——所以缺少 epoch 时只会对该实例 `continue`，其余实例不受影响。命中时，它输出一行 `unharvested` 通知，点名已完成的角色及其结果位置，并通过按键区分的 `runtime/nag/watchdog-unharvested-<key>.last` 限频（它有自己的冷却，独立于 watchdog 的其它键）。这是 L4 的**备份**：它覆盖 L4 覆盖不到的情况——角色是在主 agent **已经**进入空闲*之后*才进入终止状态的（L4 已经放行了那次停止），这时只有定时器能把主 agent 唤醒。消息会说明这是一个备份信号；检测走的是 watchdog 通知路径，本会话的观察表明它比完成通知路径更可靠，但并不保证（因此同步的 L4 才是主层）。和死亡角色扫描一样，它**在 macOS 上失效**，在 Linux 上生效。

## 降级环境

插件 hook 可能被托管策略阻止，monitor 在某些平台/版本上也不可用。无论如何，工作流在提示词层面的职责（`## 长期运行工作`、`## 核心规则` 中的刷新规则）依然有效，并在那些环境中成为唯一的强制手段——watchdog 是兜底，而不是替代。

**对 fixed-pack 跟踪层而言，macOS（Darwin）是降级平台。** catalog genesis 需要原生的逐 vnode 挂载标识，而 macOS 没有任何 API 能区分第二个同 FSID 的挂载实例，所以在 Darwin 上，每一个跟踪状态操作（`hook-start`、`hook-stop`、`hook-heartbeat`、`hook-observe`、`finalize`、probe、`gc-step`）都会以 `genesis-capability-unavailable` fail closed。后果是：不会写入任何实例状态，L3 watchdog 和 L4 停止门都拿不到角色观测——**在 macOS 上，死亡角色检测处于禁用状态**，包括被 API 错误杀死的情况。一切仍保持 fail-open（不会阻断、崩溃，除了约 100 毫秒的 hook 启动开销之外也不会拖慢），仍在工作的层是状态文件陈旧分支（L1/L3/L4）、L2 的最终消息过短门，以及提示词纪律。主 agent 提示词要求在任务开始时核实 `main_heartbeat_epoch`，无法核实时声明 watchdog 失效——在 macOS 上这项检查会如实失败，于是每个任务都会给出这条披露。Linux 宿主（包括容器）完全受支持。
