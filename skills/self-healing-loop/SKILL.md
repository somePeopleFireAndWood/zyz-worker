---
name: self-healing-loop
description: 当用户需要一个长期运行、按计划定时执行的 agent 时使用——它在 Claude Code session 内按固定时间运行任务，并且能在唤醒链断开时自我修复。具体做法是用 cron watchdog 加固 session 内的 `/loop`（ScheduleWakeup 自定时）；watchdog 写入哨兵文件，由常驻 Monitor 把它转化为一个新的 turn，并以 headless `claude -p` 作为兜底。在同一个 turn 内安装 watchdog 脚本与 crontab 行、启用哨兵 Monitor 并启动 loop；也支持干净卸载。触发词如 "定时 agent"、"每天定点跑"、"长期定时任务"、"scheduled agent"、"self-healing loop"、"断链自愈"、"唤醒沉睡 session"、"cron watchdog"、"哨兵唤醒"、"loop 断了自己回来".
---

# 自愈式定时 Loop

## 这是什么

这是一套可靠的模式，用于在 Claude Code session 内运行一个**长期运行、按计划定时执行的 agent**。一个裸的 session `/loop`（通过 `ScheduleWakeup` 自行定时）有一个反复出现的失败模式：**一次网络抖动或 LLM API 中断就会让当前 turn 失败，ScheduleWakeup 链随之断开，session 悄无声息地"睡着"——定时工作再也不会触发，也不会自行恢复。**（来自一个真实个人定时 agent 的实测数据：约一周内因唤醒链断开/跳跃漏跑了 4 次。）

本 skill 安装一套**两层"loop + watchdog"架构**来补上这个缺口：

- **loop（活的一半）**——运行在**主 session** 中，用 `ScheduleWakeup` 自行定时。每次唤醒时读取一个共享状态文件，判断是否有任务"到点"，执行到点的任务（需要 LLM 判断的部分），然后续上定时器。
- **watchdog（死的一半）**——一个每 20 分钟运行一次的 `crontab` shell 脚本。它读取**同一个**状态文件，判断今天到点的任务是否已经跑过。发现漏跑时，它**先写入一个哨兵文件来唤醒主 session，让主 session 自己补跑该任务**（保留完整上下文）；只有在宽限期过去仍未完成时，才回退到 headless 的 `claude -p` 运行。

分工原则：**确定性的调度/判据放在脚本里；需要判断力的工作留在 session 里。**

## 一行入口

用户在希望 loop 常驻的那个**主 session** 中运行本 skill：

```
/zyz-worker:self-healing-loop <task description, including "what to do at which time each day">
```

本 skill 在一个 turn 内完成三件事：

1. **安装 watchdog**——把 `templates/watchdog.sh` 复制到项目的 `scripts/`（或用户选定的其他目录），填入参数（任务定义 / 漏跑判据 / 补跑 prompt / 通知渠道 / 哨兵与锁路径），`chmod +x`，并向 `crontab` 添加一行 `*/20 * * * *`。
2. **启用常驻哨兵 Monitor**——在当前 session 中启动一个 `persistent: true` 的 Monitor 轮询哨兵文件；文件一出现，就输出一行（它会成为一条 `<task-notification>` = 一个新的 turn）并删除该文件。
3. **启动 loop**——挂上第一个 `ScheduleWakeup`，进入自定时循环。

此后用户无需任何操作；断链由 watchdog 修复。

### 为什么入口**必须**是 skill（不是 subagent，也不是普通 CLI）

| 形式 | 可用？ | 原因 |
|---|---|---|
| **Skill / slash command** | ✅ 推荐 | 唯一一种*既能*写入脚本、*又能*在当前 session 中启用 Monitor 并启动 loop 的入口 |
| subagent 类型 | ❌ | subagent 是短命的子进程——它无法持有常驻 Monitor；loop 必须活在 `ScheduleWakeup` 能重新唤醒的主循环 session 里 |
| 普通 CLI 脚本 | ⚠️ | 只覆盖 watchdog 那一半；失去了"让 agent 参数化 prompt / 在 session 内启动 loop"的能力 |

## 触发语义（最容易误读的部分——请仔细阅读）

| 阶段 | 由谁触发 | 需要人工吗？ |
|---|---|---|
| **首次安装** | 用户运行一次本 skill | ✅ 一次手动操作，必不可少 |
| **每日按时执行** | loop 自己的 `ScheduleWakeup` | ❌ 不需要 |
| **从断链/睡着的链中恢复** | watchdog（cron）写入哨兵 → 常驻 Monitor 产生一个 turn | ❌ 不需要 |
| **主 session 进程被杀之后** | watchdog 用 headless `claude -p` 补跑一次今天的任务 | ❌ 业务不会漏；但常驻 loop **不会**自动恢复——恢复它需要人再运行一次本 skill（或 `--resume`） |

**要点：**

- 用户如果从不运行本 skill，loop 和 cron 行都不会自己冒出来。**没有任何东西会自动触发，这是有意设计的**——cron 是系统级副作用，loop 会持续消耗 token，而任务定义只有用户能提供；这些都不应该悄悄开启。
- **"自愈"的含义是：它覆盖"session 断链睡着"，而并不覆盖"进程被直接杀掉"**。后者由 headless 兜底在*业务连续性*层面覆盖，但恢复常驻 loop 仍需手动重新启动一次。这条边界在这里以及每个生成的产物中都如实写明——不要让用户以为 loop 在 `kill -9` 之后会自己复活。

## 用教训换来的设计经验（每次安装都要落实）

### 1. 唤醒渠道：pull 还是 push——这决定成败

- ❌ **跨 session 的 `SendMessage` 无法唤醒睡着的 session**。它是 *pull* 式的：消息只是投进收件箱，要等接收方*下一个工具轮次*才会被取走；断链的 session 不再产生工具轮次 → 消息永远堆积。（实测数据：watchdog 发出了 **9** 条唤醒消息；主 session 被激活 **0** 次。）
- ✅ **哨兵文件 + 主 session 侧的常驻 Monitor 可以唤醒它**。Monitor 事件是 *push* 式的：文件一出现就直接产生一个 turn。（实测数据：多次成功，其中一次主 session **根本没有挂起任何 ScheduleWakeup**——真正睡着的状态——也被准时唤醒。）

> "睡着" = 进程活着，但模型没有被调用。要唤醒它需要三个条件同时满足：**push 式事件源 + 该事件能产生 turn + 进程没死**。进程如果死了，只有 headless 能用。

完整分析见 `references/wakeup-channel.md`。

### 2. Monitor 的生命周期是这套机制的薄弱点——要主动处理

Monitor 可能被杀掉（session 重启 / `/clear` / 上下文压缩 / harness 回收），而且**不会自愈**。它一死，哨兵渠道就断了（watchdog 照写文件，但没人读）。因此：**每次 loop 唤醒时，都自检 Monitor 是否还活着，不在了就立即重新启用**；headless 保留为最终兜底。

### 3. 不要依据不稳定的字段判断 session 是否存活

早期版本在唤醒前用 `claude agents --json` 的 `cwd` 字段判断主 session 是否存活——这个字段不稳定，导致了误判。最终规则：**无条件写入哨兵**（活的 session 会响应；死的 session 在宽限期后由 headless 兜底）。不做存活预检。

### 4. 幂等 + 互斥

- **幂等**：watchdog 的"已经跑过"判据是"状态文件中该任务那一行是否包含今天的日期"；补跑会写这一行，因此天然防止重复。
- **互斥**：用带过期锁超时自动清理的 `mkdir` 锁，防止 cron 周期重入。

## 本 skill 安装的文件

| 文件 | 作用 | 来源模板 |
|---|---|---|
| `<REPO>/scripts/<name>-watchdog.sh` | cron 每 20 分钟一次的 watchdog | `templates/watchdog.sh` |
| `<REPO>/data/loop_state.md` | loop 与 watchdog 共享的唯一事实来源 | `templates/loop_state.md` |
| 一行 `crontab` `*/20 * * * * …` | 调度 watchdog | （由本 skill 添加） |
| （session 内）常驻 Monitor | 哨兵 → turn | `templates/monitor-sentinel.sh` |
| `<REPO>/scripts/<name>-uninstall.sh` | 干净卸载 | `templates/uninstall.sh` |

各模板通用的约定：

- `<REPO>` 项目根目录；`<STATE>` = `<REPO>/data/loop_state.md`
- `<SIGNAL>` = `/tmp/<name>-wake-signal`（哨兵文件）
- `<LOCK>` = `/tmp/<name>-watchdog.lock`
- `<NOTIFY>` 通知渠道——**默认复用插件已有的 IM 层**（`~/.zyz-worker/notify.json` 中的 `command`，见 `docs/notify.md`），这样用户只需配置一次通知；否则使用用户提供的 shell 命令。
- 任何"到某个时间点执行"的任务（每天、交易日、仅工作日……）都命名为 `T1`、`T2`、……

## 安装步骤（本 skill 在 turn 内完成的工作）

1. **解析用户以 `$ARGUMENTS` 传入的任务描述**，拆成一个或多个任务，每个任务包含：id（`T1`…）、到点时间（以及日期过滤，例如工作日 / 交易日）、要做的工作、补跑 prompt（供 headless 使用）以及通知目标。其中任何一项含糊，都要在动 `crontab` 之前先问用户。
2. **选定 `<name>`**（kebab-case，由任务推导），并解析 `<REPO>`、`<STATE>`、`<SIGNAL>`、`<LOCK>` 路径。确认 `<REPO>/scripts/` 与 `<REPO>/data/` 存在（必要时创建）。
3. **用参数渲染 `templates/watchdog.sh`**，写入 `<REPO>/scripts/<name>-watchdog.sh`，`chmod +x`。
4. **`<STATE>` 尚不存在时，把 `templates/loop_state.md` 渲染到 `<STATE>`**。
5. **把 `templates/uninstall.sh` 渲染到 `<REPO>/scripts/<name>-uninstall.sh`**，`chmod +x`。
6. **添加 crontab 行**——读取当前 crontab，（幂等地——不要重复添加已存在的相同行）追加 `*/20 * * * * <REPO>/scripts/<name>-watchdog.sh`，并带上 `# zyz-worker self-healing-loop:<name>` 标签注释以便卸载时找到它，然后安装。**这是系统级改动——写入 crontab 之前，先展示确切的那一行，并取得用户的明确确认。**
7. **用 `templates/monitor-sentinel.sh` 启用常驻 Monitor**（Monitor 带 `persistent: true`）。
8. **挂上第一个 `ScheduleWakeup`**，并向用户报告：已安装的路径、crontab 行、触发语义表，以及自愈的边界。

## Loop 每个 turn 的逻辑（每次 ScheduleWakeup / 每次 WATCHDOG-WAKE）

```
1. 读取 <STATE>，获取当前时间，逐个任务判断它今天是否已到点且尚未运行。
2. 若已到点：执行该任务（需要 LLM 判断的部分）→ 通知 → 写入 <STATE>
   （在该任务那一行插入今天的记录，使 watchdog 保持幂等）。
3. 自检常驻 Monitor 是否还活着；不在了就立即重新启用
   （否则哨兵渠道就断了）。
4. 挂上下一个 ScheduleWakeup：临近下一个任务时间时用短延迟，以便准确落在它之前；
   空闲时用长心跳以节省 token。
```

选择 `delaySeconds` 的方式与 ScheduleWakeup 工具指引一致：只有在正向下一个任务时间点逼近时才保持在 270s 以内；否则使用较长（1200s 以上）的空闲心跳，免得每隔几分钟就白白耗掉缓存。

## 卸载

`<REPO>/scripts/<name>-uninstall.sh` 会删除带标签的 crontab 行、删除哨兵文件/锁，并打印提醒：用户还必须停掉 session 内的 loop + Monitor（Ctrl-C 停掉 loop，或用 `/tasks` 停掉 Monitor），因为它们活在本脚本无法触及的 session 里。也可以用 `uninstall <name>` 调用本 skill，在 session 内完成卸载（它能直接停掉 Monitor 和 loop，然后运行该脚本完成 crontab/文件清理）。

## 长期运行状态

loop 的持久状态是 `<STATE>`（`<REPO>/data/loop_state.md`）——与 watchdog 共享的唯一事实来源。上下文中的记忆在断链或进程死亡后不会保留，因此每次任务执行都**必须**在同一个 turn 内写入 `<STATE>`；loop "做了"却没记录的任务会被 watchdog 重跑（结果正确，只是浪费），更糟的情况是没做却被读成已完成。参见 [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md)。
