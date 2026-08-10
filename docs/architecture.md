# zyz-worker 架构说明

本文讲整体架构与主体原理：插件由哪些部件组成、各自的职责边界、以及它们如何协作。不追求逐行细节——具体契约看各文件自身的 in-file contract 块与对应 SKILL.md。

## 一、一句话概括

zyz-worker 是一个「设计先行」的开发工作流插件，提供两层能力：

- **`/execute-task`** —— 执行**一个**已确认的开发任务：设计 → 实现 → 测试 → 评审 → 交付。
- **`/orchestrate-tasks`** —— 调度**一批**任务：分析依赖、并行派发多个隔离的 worker（每个 worker 就是一个独立跑 `/execute-task` 的 claude 进程）、汇总状态、把合并卡在用户显式审批上。

贯穿两者的核心信条只有一条：**长期任务的状态以文件为单一事实源**（`docs/conventions/long-running-state.md`）。上下文负责执行，文件负责记忆。所有跨进程、跨 agent、跨重启的信息都必须落盘；不在盘上的事实等于不存在。

## 二、部件全景

```text
用户
 │
 ├── /execute-task ────────► execute-task skill
 │                            ├─ 主控提示词  skills/execute-task/prompts/main-agent.md
 │                            ├─ 3 个 subAgent  implementation / test / review
 │                            ├─ 4 个模板  design-doc / task-status / final-report / review-report
 │                            └─ watchdog 强制层  hooks/ + monitors/     ← 确定性兜底
 │
 └── /orchestrate-tasks ───► orchestration-scheduling-task skill
                              ├─ 主控提示词  skills/.../prompts/main-agent.md
                              ├─ 1 个 subAgent  orch-driver-agent (L2)
                              ├─ 5 个模板  master-entry / worker-status / monitor / dispatch / question-answer
                              └─ 10 个 bash helper  scripts/orch-*.sh          ← 确定性动作
```

辅助 skill 两个：`git-worktree`（推导 worktree 默认路径）、`clean-tmp`（跨平台清理临时文件 / Docker / 编译缓存）。二者独立可用，不属于上面两条主链。

## 三、execute-task：一个任务怎么走完

### 3.1 角色与硬边界

四个角色，边界是硬的——这是整个工作流质量的地基：

| 角色 | 身份 | 能做 | 明确不能做 |
|---|---|---|---|
| **主 agent** | 当前与用户对话的 agent（**不是** subAgent） | 协调、写设计文档、维护状态文件、派发角色、与用户交互 | 写实现代码、改测试、跑测试、自己做评审 |
| **implementation-agent** | Claude Code subAgent | 写实现、**跑测试** | 改测试代码 |
| **test-agent** | Claude Code subAgent | 写/维护测试 | **跑测试**、改实现 |
| **review-agent** | Claude Code subAgent | 评审设计/实现/测试 | 改任何文件 |

「写测试的不跑测试，跑测试的不写测试」是刻意的：让测试的作者与执行者分离，避免为了让测试通过而改测试。变异注入沿用同一分离：test-agent **出变异清单**（机制 → 改哪行 → 哪些用例应转红），implementation-agent **执行**并逐条回报 KILLED/SURVIVED——所以「不跑测试」的边界完好。review-agent 是唯一例外地拿到 Bash 的评审角色：它可以只读地复跑关键判定、注入**用完即还原**的互补面变异（必须字节级还原并验证）——因为实测中只读评审对「空转断言」的命中率是零，而作者不能当自己判定结果的唯一裁判。

**「跑了 ≠ 测到了」是 0.16 之后整个测试纪律的核心**（来自一次 20 个 agent 实例、9 个 SubTask 的实战反馈）：`Tested: true` 的定义是「绿 **且** 每条覆盖声明有被杀变异实证」；报绿必须带四项坐标（完整命令/测试库/端口组/进程-源码新鲜度）；失败归因走四步顺序（改动面因果 → 工具层 → 他人在途 → 真回归）；并行 ≥2 路先分配资源租约；评审前冻结工作区；交付前逐条应答 26 项核查清单。原理一句话：**假的成功比假的失败更危险**——验证工具失效时产出的不是报错，而是「看起来像被测对象有问题」的结果。

角色定义存在**两份**：`agents/*.md`（带 YAML frontmatter，Claude Code 真正注册的 subAgent）与 `subagents/*.md`（无 frontmatter 的共享镜像，供 Codex 等其它端或无 subAgent 运行时的环境当角色提示词用）。两份的正文由测试逐字节比对，改一边必须改另一边。

### 3.2 主线流程

```text
§1 启动    建任务目录 + status.md + 写 .zyz-worker/current-task 指针（给 watchdog 上膛）
   ↓
§2 设计    与用户共同产出设计文档 → review-agent 自动循环评审直到无异议
   ↓       ★ 唯一的人工闸门：必须等到用户明确批准才能进实现
§3 实现    implementation-agent 与 test-agent **默认并行**（都从设计文档取活）
   ↓       → 跑测试 + 跑变异清单 → 失败**四步归因**（改动面因果 → 工具层 →
   ↓          他人在途/环境 → 才是真回归）→ 冻结工作区 → review → 循环
   ↓       可选拆 SubTask；按**依赖图**而非列表顺序调度；并行 ≥2 路先分资源租约
§3.C 汇总  汇总测试（类别由设计 `## Testing Plan` 派生）+ 汇总评审（4 个覆盖维度）
   ↓
§4 交付    核对 Total Goal → 校验注册完整 → 逐条答完 26 项交付前清单 →
   ↓          提交推送 → 出最终报告
   ↓       → awaiting-confirmation，等用户确认才 done
```

### 3.3 几个刻意的设计决策

这些是插件多轮迭代中沉淀下来的、值得单独讲的原理：

**a) 设计→实现闸门是硬等待，不是「问一下」。** 沉默、超时、用户不在，都只能继续等，绝不自行推进。唯一例外是用户事先明确说过「跳过审批」，且该原话被逐字记录进 `## Design Review > Design Approval Record`。这条针对的失效模式是：agent 把「用户没回」当成默许，然后一路跑到交付。

**b) 「注册制」而不是「必须全做」。** 汇总测试的每个类别、汇总评审的每个维度，都必须显式写成 `ran/skipped: <原因>` 或 `covered/not-covered: <原因>`。允许跳过（e2e 烧配额可以跳），但**不允许静默省略**。未注册的类别/维度直接阻塞交付。原理：真正危险的不是「没做」，而是「没做但看起来做了」。

**c) 增量输出 ≠ 缩减范围。** 允许把大产出拆成多条消息（提升 API 稳定性），但禁止在恢复卡死角色时压缩交付要求。「只给最严重 3 条」「一句话结论就行」这类措辞被明确列为禁止项——因为一个只报了 3 条问题的评审，看起来和干净的评审一模一样，剩下的问题会一路混进交付。这条由 L5 hook 在派发前机械拦截。

**d) 外部 PR 评审要逐条独立验证。** 收到 PR 上的评审意见时不盲从：逐条独立核实问题是否客观存在，成立的修、不成立的在 PR 上回帖说明理由。每条必须落到「已修」或「已明确拒绝并回帖」，不允许「不回也不改」。

**e) 版本控制自治且非阻塞。** 提交/推送自己做，不问用户；失败就记录进状态文件继续走，绝不阻塞。但 merge 到 base 永远需要用户显式指令，破坏性操作（force-push / reset --hard / 改历史）一律禁止。

## 四、watchdog 强制层：为什么需要，怎么分层

### 4.1 动机

提示词纪律会滑坡。实测的三类失效：主 agent 忘记刷状态文件、派了角色但结果被静默丢弃、活没干完就结束回合。更麻烦的是 subagent 被 API 错误杀掉时 `SubagentStop` 根本不触发——纯提示词无法察觉。

所以 0.13.0 加了一层确定性兜底。**原则：提示词纪律仍是主行为，watchdog 只是兜底**；整层缺失（策略禁用 hooks、平台不支持 monitors）工作流也照常跑。

### 4.2 七层

| 层 | 载体 | 触发点 | 干什么 |
|---|---|---|---|
| **L0 心跳** | `heartbeat.sh` + `subagent-track.sh` | 每次工具调用（Pre/PostToolUse，异步）；SubagentStart | 把「存活」变成干活的**副作用**，而不是需要记得做的事。`.start` 有、`.done` 无、心跳过期 = 角色死了或卡住 |
| **L1 新鲜度提醒** | `status-freshness.sh`、`post-agent-flush.sh` | PostToolUse | 状态文件在活跃阶段过期时注入提醒；收到 subagent 结果后提醒先落盘再派下一个。纯建议，带冷却。**每次工具调用只出一条**：Agent 返回归 `post-agent-flush`（措辞更具体、阈值更紧），其余归 `status-freshness` |
| **L2 子 agent 退出门** | `stop-gate-subagent.sh` | SubagentStop | 最终消息过短就拦一次，要求先给正式报告（主 agent 才有东西可落盘）。最多拦一次，不会循环 |
| **L3 后台看门狗** | `monitors/watchdog.sh` | 会话启动即常驻（`when: always`） | 定时扫心跳与状态文件 mtime，发现问题输出一行通知**唤醒**主 agent。这是唯一能抓住「被 API 错误杀死」的层 |
| **L4 主 agent 停止门** | `stop-gate-main.sh` | Stop | 派出的角色看起来死了、或状态文件严重过期时，阻止主 agent 就这么闲下来 |
| **L5 派发范围守卫** | `dispatch-scope-guard.sh` | PreToolUse (`^Agent$`) | 唯一**事前**层：检查派发提示词是否在压缩角色交付范围，是则 deny（除非同一提示词承诺了补齐剩余部分）。启发式匹配，三重防过度拦截：否决式表述免疫、引号内容不算下达指令、上限必须挂在评审交付物名词上 |
| **L6 共享树回退守卫** | `checkout-guard.sh` | PreToolUse (`^Bash$`) | 拦截会摧毁**他人未提交成果**的 git 回退：`checkout/restore` 指向有未提交改动的文件、以及移动状态的 `stash` 形态。deny 消息里给出安全替代（改前 cp 备份、`git show HEAD:<file>` 只读、`git apply -R`）。源自真实事故：变异测试回退用 checkout 连带删掉另一 agent 约 5000 字符守卫代码，且 build 全绿 |

### 4.3 关键机制

- **上膛靠指针。** 所有 hook 都先找 session cwd 下的 `.zyz-worker/current-task`；解析不到，整层静默 no-op。主 agent 在 §1 写它。**踩过的坑**：本插件自己的 `git-worktree` skill 把 worktree 建在主 checkout 之外且不 cd 进去，于是任务在 worktree 里跑、指针也写在那里，而 session cwd 在主 checkout——**六层全部空转**（`runtime/` 从未创建、两个死掉的 subagent 无人上报、空闲闸门放行），而且外部完全看不出来。现已加**有界兜底**：单 base 命中（热路径不变）→ `$ZYZ_TASK_DIR` → 同仓库的兄弟 worktree（按 `status.md` mtime 取最新、跳过 `phase: done`、每次兜底命中记一行日志）。刻意**不做**无界向上遍历：默认布局的祖先链会经过 `$HOME/.zyz-worker`，一个游离指针就能捕获 `$HOME` 下所有 session。
- **「未武装」必须可见。** 一个没上膛的看门狗和一个健康安静的看门狗从外部无法区分。§1 要求在工具调用后确认 `runtime/agents/main.heartbeat` 存在；两端均使用同步心跳 hook，避免 Codex 当前跳过 async hook 导致整层假装已武装。
- **`.start` 有、`.done` 无、心跳仍在推进 = 该角色还活着，不要重派。** 这条同时是「存活 agent 登记表」——恢复会话据此区分「死了产出丢了」与「还在跑」，避免把新 agent 派进同一工作区与存活的原 agent 撞车。`runtime/` 整个不存在则意味着看门狗从未上膛，此时没有任何存活证据可用。
- **全部 fail-open。** 缺输入、缺 JSON 解析器（jq/python3）、写失败，一律静默 exit 0（畸形 JSON、空 stdin、无指针三种输入均已实测退出 0）。兜底层绝不能拖慢或弄坏它保护的流程。
- **输出形状按事件类型区分。** `PostToolUse` / `PreToolUse` 这类注入或拦截，输出 `hookSpecificOutput` 且其中 `hookEventName` 必须与注册的事件一致（前者带 `additionalContext`，后者带 `permissionDecision`）；而 Stop / SubagentStop 两个停止门禁输出的是**不带**事件名的 `{decision:"block",reason}`——这是该事件族的约定，不是漏写。
- **四个逃生开关。** `ZYZ_HOOKS_DISABLE=1` 关整层、`ZYZ_SCOPE_GUARD_DISABLE=1` 只关 L5、`ZYZ_CHECKOUT_GUARD_DISABLE=1` 只关 L6（两者的匹配都是启发式的——用 shell 解析 shell 无法完美——必须留单独开关）、`stop_hook_active` 让已被拦过的停止直接放行。
- **阈值分层且可调。** L3 的角色静默阈值（1200s）刻意高于 L4（900s），因为 L3 无法交叉验证 `background_tasks`，而健康角色可能长时间只思考不调工具——所以 L3 的措辞是「请核实」而不是「立即重启」。全部通过 `ZYZ_*` 环境变量可调，`ZYZ_HOOKS_DISABLE=1` 关掉整层。
- **多层管同一条不变量不是冗余，是递进升级阶梯。** 状态文件新鲜度有三层管：600s 注入提醒（纯建议）→ 1200s 停止门禁（拦住 idle）→ 1800s 后台监视器（唤醒会话）。角色存活有两层：900s 停止门禁 → 1200s 监视器。每层阈值不同、触发点不同、手段强度不同（提醒 < 阻止 < 唤醒），后一层只在前一层已经失效时才够到。看起来重复的地方，实际是「先轻后重」。
- **两个停止门禁都不会死锁。** 二者都先检查 `stop_hook_active`：该标志为真意味着本次停止已经被拦过一次，此时直接放行。所以每次停止最多拦一次，不存在反复阻止的活锁；再叠加冷却戳限流。
- **同步层性能要可控。** 当前 Codex 会跳过 async hook，因此心跳与 `status-freshness.sh` 都是同步的。成本来自 `zyz_get` 每读一个字段起一个 `jq` 进程；真要降本应在 hook 脚本里一次性取全部字段，不要在命令替换子 shell 中做无效缓存。
- **`when: always` 而不是 `on-skill-invoke:`（踩过的坑）。** 后者按**精确字符串**与「发出的 skill 名」比对，而同一个 skill 以插件加载时发出的是**带限定名**的 `zyz-worker:execute-task`、以项目模式使用时发出的是裸名 `execute-task`——一个字面量覆盖不了两种安装方式，原先写的裸名在正常插件安装下**从未 arm 过**。`watchdog.sh` 本身以指针为门，所以恒久 arm 与按需 arm 效果等价，代价只是一个休眠进程。教训：手动跑脚本只验证脚本逻辑，**不验证宿主是否真的把它挂上**。
- **门禁的指令必须是「能被执行后清掉触发条件」的。** L4 只读 `runtime/` 标记、从不读 `status.md`，所以早期那句「在状态文件里标记它已完成」是**无法满足**的指令：照做了标记还在、门禁继续拦，只能等冷却或平台的连续拦截上限超时。现在改为：干净退出的 SubagentStop 直接**删掉** `.start`/`.heartbeat`（顺带解决 `runtime/` 每派发一次就多留一组标记的累积问题，因为 `agent_id` 每次都是新的随机值），而拦截理由里直接给出该删哪个文件的 `rm -f`。
- **长度阈值按字节量，不按 `${#var}`。** bash 的 `${#var}` 在 UTF-8 locale 下数字符、在 `LC_ALL=C` 下数字节——同一条消息两种读数。一份完整的 45 字中文报告按字符只有 45、低于阈值 80 会被当成「太短」拦掉，而它其实有 135 字节。已改为数字节（与 locale 无关），阈值按字节校准。
- **启发式守卫必须防「误伤自己」。** L5 靠措辞匹配，最初把**引用**某句上限措辞当成**下达**该措辞——于是「写个测试断言 `"limit to 3 findings"` 会被拒」这类工作被守卫自己拦住，而在本仓库里给这个守卫写文档/测试/CHANGELOG 恰恰是常规工作。现在上限只在**去掉引号内容后**的文本里匹配（否决式表述仍读全文，所以引号里的否决依然有效），且上限必须挂在 `findings|issues|problems` 这类评审交付物名词上——否则「每页不超过 3 条 items」「重试上限 3 次」这种正常业务需求也会被拦。留了一个明知的取舍：整条提示词就是一句带引号的上限时会放过。
- **测试载荷必须正确转义，否则会「假绿」。** T7 原先把提示词直接拼进 JSON 字符串，一旦 fixture 里含 `"` 就产出非法 JSON，守卫 fail-open 放过，断言于是「通过」了——但通过的原因是错的。现在用真正的 JSON 编码器构造载荷，并且在加新 fixture 前先确认 23 条既有的上限 fixture 经转义路径仍然被拒。
- **簿记与任务状态分离。** `<task-dir>/runtime/` 下的心跳、`.start`/`.done`、冷却戳都是 watchdog 自己的簿记，不是任务状态，不要手改。

## 五、orchestration：三层调度

### 5.1 为什么分三层

交互式驱动一个 worker 的 tmux pane（起 claude、过启动确认页、救活卡住的 worker）**又重又吵**：需要反复 `capture-pane` 看屏、`send-keys` 发键。如果把 N 个并行 worker 的 pane 驱动全塞进一个上下文，这个上下文会被瞬间污染，真实并行度反而被拖垮。

所以：**把唯一那件重活隔离到每 worker 一个短命 subagent，廉价的只读轮询留在主循环内联。**

### 5.2 三层职责

| 层 | 是什么 | 能碰 pane 吗 | 职责 |
|---|---|---|---|
| **L1 orchestrator** | 用户面对的主 agent，单例，持 `<list-dir>` flock | **绝不** | scan → analyze(依赖) → plan → dispatch → poll(内联只读) → project → gate → notify → report |
| **L2 orch-driver-agent** | 短命 subAgent，**按需**派发（不是每 tick） | **唯一能碰** | 就一个 worker：起 claude（bypass 模式）、过确认页、发 `/execute-task`、卡住时保守干预、写 `monitor.md`、返回一行 |
| **L3 worker** | 独立 tmux window + 独立 claude 进程跑 `/execute-task` | 被驱动 | 自带主 agent + 三个 subAgent，在自己的 worktree 里走完整流程。对 L1/L2 **不可见** |

一个 worker = **1 个 tmux session + n 个 git worktree（每仓一个，单仓时 n=1）+ 1 个完整 claude 进程**。

### 5.3 通信全靠文件

没有任何跨 agent 的内存共享：

```text
L1 ←→ 文件(<list-dir>/…) ←→ L2      L2 写状态文件，L1 读
L1 ←   返回值(一行)      ←  L2      L2 退出时返回
L2 ←→ tmux(send-keys/capture) ←→ L3  进程外驱动，不是 agent 嵌套
L3 ←→ 文件(自己的 worktree + worker-status.md)
用户 ←→ tmux attach ←→ L3            Q&A 直连，绝不经过 L1/L2
```

文件所有权是单写者的，这是避免写竞争的关键：

| 文件 | 写者 | 读者 |
|---|---|---|
| master entry `tasks/<id>.md` | orchestrator + 用户 | 二者 |
| `worker-status.md` | **仅 L3** | L1 / L2 |
| `monitor.md` | **仅 L2** | L1 |
| `dispatch.md` | spawn(Phase-1) + check(Phase-2) | L1 / 运维 |
| `heartbeat` | pane 内心跳守护进程 | L1 |
| `question.md` / `answer.md` | worker / 用户 | 用户 / worker |

### 5.4 几个刻意的边界

**a) L1 从不代答。** worker 需要用户时，L1 只播报「task X 需要你去 window Y」，**绝不转发问题内容**。用户自己 attach 上去跟 L3 直接对话。理由：转发 Q&A 会把 L3 的任务内部细节泄进 L1 上下文，也会让用户的回答经过一次有损转述。

**b) 什么叫「内部」。** L3 的设计文档、SubTask 状态、实现/测试/评审文件、`question.md` 的**正文**，L1 和 L2 都不读。而 `worker-status.md` / `dispatch.md` 是 L3 的**向上投影**（阶段、等待态、绑定信息），两层都可读——它们是权威的整体状态源。

**c) 一切交付动作都要显式 token。** orchestrator 绝不自行 merge / 改状态 / 清理。用户在 `## Pending Merge Approval` 写 token：`confirmed`（转达确认→worker 自己写 `phase=done`→L1 镜像成 `completed`）、`merge`（只合不改状态）、`approved`（遗留的原子三合一）、`cleanup-approved`（清 worktree）、`rejected: <原因>`。

**d) `completed` 只能镜像，不能直写。** worker 写 `phase=done` 是唯一来源，L1 只做镜像。这条是为了守住单一事实源——0.6.5 专门retire 了一个直写 `state: completed` 的脚本。

**e) 交付与合并解耦。** `completed` 不再意味着已合并到 base。所以下游任务解锁时不能只看 `completed`，要逐个判断依赖的产出是否真的可用（合进了本任务的 base，还是只活在依赖自己的分支上），必要时把 `base:` 改成依赖的分支来串联。

### 5.5 bash helper：确定性动作层

提示词负责判断，脚本负责动作。10 个 helper，统一约定：`set -euo pipefail` + in-file contract 块；task-id 白名单 `^[A-Za-z0-9_-]+$` 违规 exit 2；缺 tmux/git exit 3；stdout 输出结构化 `key=value`，人类消息走 stderr。

| helper | 职责 |
|---|---|
| `orch-scan-tasks.sh` | 只读列出所有任务条目及其 state/phase/wait-state |
| `orch-spawn-worker.sh` | **只建容器**：每仓一个 worktree + 1 个 tmux session + pane 内心跳 + Phase-1 `dispatch.md`。**从不起 claude** |
| `orch-reuse-worker.sh` | 复用某个**已完成**任务的 session/worktree 集合来承接新任务，而不新建容器；同样从不起 claude |
| `orch-build-env.sh` | 打印 Go 构建 I/O 优化片段（`GOTMPDIR` 走 tmpfs + `GOFLAGS=-p`），由 spawn/reuse 注入 pane |
| `orch-worker-mcp-args.sh` | 打印 worker 的 MCP 隔离 CLI 参数（`ZYZ_WORKER_MCP` 策略；默认 `--strict-mcp-config` = 零 MCP），spawn/reuse 快照进 `dispatch.md`，L2 启动命令与恢复 `--resume` 同用一份快照 |
| `orch-check-worker.sh` | 只读探测（文件 + `pgrep`，**不碰 pane**）；顺带惰性补全 `dispatch.md` 的 Phase-2 绑定字段 |
| `orch-heartbeat-daemon.sh` | pane 内常驻，定期刷 `heartbeat`；session 消失即自退 |
| `orch-merge.sh` | 只合并 + 推送，不改 state、不清理 |
| `orch-merge-and-cleanup.sh` | 遗留原子路径：合并 + 写 `completed` + 清理 |
| `orch-cleanup-worker.sh` | 杀 session、删 worktree、归档 runtime 目录（默认 dry-run） |

**spawn 只建容器、L2 才起 claude** 是这层最重要的不变量。理由：起 claude 需要过启动确认页、需要判断就绪，这是「看屏 + 发键」的循环，脚本做不可靠（早期版本的 `--auto-start` 就是因此被废弃的）。而 claude 必须**恰好起一次**——L2 靠开工前 `capture-pane` 看屏做幂等，L1 靠 `monitor.md` 的 `claude-started` 与 `dispatch-bound` 在重启后避免重复起。

### 5.6 崩溃恢复的原理

`dispatch.md` 把 tmux session/pane 绑定到选定 agent runtime 的 session-id 与 transcript 路径。**Phase-2 字段惰性填充**：Claude 从 PID pointer + `~/.claude/projects` 发现，Codex 从 `~/.codex/sessions/**/rollout-*.jsonl` 首行 `session_meta` 按物理 cwd 和 spawn 时间发现。generic 字段是 `agent-pid` / `agent-session-id`，同时保留 Claude 命名别名以兼容旧数据。

四种恢复情形按 `session-alive` × `dispatch-bound` 两个信号区分：session 活着就 attach；session 死了但绑定完整就 `claude --resume`（**必须带 `--plugin-dir`**，否则 transcript 恢复了但插件没注册，`/execute-task` 会变成 Unknown command）；只有 Phase-1 则无可恢复状态，清理重派；`dispatch.md` 整个缺失则看 session 是否还活着来判断。

### 5.7 调度节奏

L1 每 tick 按 7 分支决策树选下次唤醒间隔（120s 逼近完工 / 180s 有 stale / 270s 等用户 / 600s 全健康 / 120s 有未分析 / 1800s 全空闲 / 120s 未知待查），然后**在会话内**用 `ScheduleWakeup` 自我调度。默认裸 `/orchestrate-tasks` 就是自动轮询；`/loop` 是可选的显式替代；`ZYZ_ORCH_ONCE=1` 强制单次。刻意避开 300s（提示缓存边界）。

## 六、多端与打包

同一套根级资产供两端复用，各端只有自己的清单：Claude Code 读 `.claude-plugin/plugin.json` 并在根级找 `agents/` `commands/` `skills/` `hooks/`；Codex 读 `.codex-plugin/plugin.json` 并只用根级 `skills/`。`.claude/agents` 与 `.claude/commands` 是指向根级目录的符号链接，让本仓库既能当插件加载、也能直接当项目使用。

Codex worker 通过 `scripts/orch-agent-runtime.sh` 使用 `codex -C` / `codex resume`，Claude 使用 `claude --plugin-dir` / `claude --resume`。hooks 命令按 `CODEX_PLUGIN_ROOT` → orchestrated `ZYZ_PLUGIN_ROOT` → `CLAUDE_PLUGIN_ROOT` 解析（Codex 0.147.0 会把裸 `./hooks` 相对 worker cwd 解析），并同时匹配两端工具名；Codex `SessionStart` 同步 hook 只负责快速拉起脱离的诊断 scanner，不宣称具有 Claude monitor 的会话唤醒能力。

`scripts/pack.sh` 以 `git ls-files` 为唯一装箱清单（天然排除未跟踪与 gitignore 的内容），版本号取自 `.claude-plugin/plugin.json`。

## 七、测试策略

六个套件，全部是「跑完不早退」的风格，最后汇总通过数。前五个是纯静态/单元测，不需要网络与 API 配额，可随时全跑：

| 套件 | 覆盖 |
|---|---|
| `test-orchestration-helpers.sh` | 最大的一份。helper 的退出码契约、`dispatch.md` 字段集、复用前置校验与**退出码优先级**、多仓 merge、文档关键串、`agents/`↔`subagents/` 四对镜像逐字节相等 |
| `test-watchdog-hooks.sh` | hook 布局与语法、`hooks.json`/`monitors.json` 注册项、各 hook 行为烟测、L5 的应拦/应放行措辞矩阵（含否决与计数上限族）、三份清单版本一致 |
| `test-rename-and-conventions.sh` | 命名与目录约定：不留旧名残留、slash command 别名正文等价、long-running-state 约束块在各角色文件就位 |
| `test-release-0-5-0.sh` | 发布门禁：三份清单版本一致、打包产物内容、tag 内容 |
| `test-clean-tmp-skill.sh` | clean-tmp skill 的静态与烟测、文档接线 |
| `test-e2e-layered.sh` | 真 claude 端到端验收（**消耗 API 配额**，需 tmux/git/claude 就位），验证 spawn → L2 起真 claude → 父 shell 不变量 → exactly-once 幂等 → dispatch-bound 绑定 |

一个重要惯例：**文档串也被测试钉住**。SKILL.md 的分支名、README 的目录树条目、模板的枚举值都有 grep 断言——因为这套插件的「行为」很大一部分就写在提示词里，提示词漂移就是行为漂移。

## 八、扩展时要成对改的地方

多轮迭代反复踩到的耦合点，改动时必须同步：

- **新增 phase**：execute-task SKILL.md 的枚举 + 阶段映射表、orchestration 的 `worker-status.md` 模板、两边的 SKILL/主控提示词。
- **改 `dispatch.md` 字段**：模板、spawn 与 reuse 两个 Phase-1 写入点、check 的 Phase-2 回写（必须原样保留复用字段与编号仓字段组，否则首次轮询就会丢）、merge/cleanup/reuse 的仓集读取、崩溃恢复章节、T8 测试。
- **改 L2 的 `intent` 枚举**：`agents/` 与 `subagents/` 两份驱动定义（`## Inputs` 行 + 各 `## intent=…` 小节）、`templates/monitor.md` 模板的 `driver-intent`、L1 的每个派发点、对应测试。
- **改角色提示词**：`agents/<role>.md` 与 `subagents/<role>.md` 必须同改（正文被逐字节比对）。
- **改 watchdog 阈值/路径**：脚本、`hooks/README.md`、execute-task SKILL.md 的 `## Watchdog Enforcement` 三处口径要一致。

**已知的复制粘贴面。** helper 之间没有共享库（刻意的：每个脚本要能被单独调用、单独读懂），代价是几个小函数在多个脚本里各存一份——`fm_field`（frontmatter 取值，6 份）与 tilde 展开（9 处内联）。这些副本**必须保持行为一致**：`fm_field` 曾出现过分歧（一部分副本缺少「文件不存在则返回空」的守卫，在 `set -e` 下会直接杀掉调用者），已统一。改其中任一份时，同步改全部。

两个刻意保留的命名反直觉之处，不要「顺手统一」：L2 的 agent 叫 driver 但它写的文件仍叫 `monitor.md`（避免测试/模板路径大规模改动）；L1→L2 的输入字段叫 `intent`，落盘的 frontmatter 键叫 `driver-intent`（两名分立是有意的）。
