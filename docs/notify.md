# IM 停止通知（`notify.sh`）

当长时间运行的 `execute-task` / `orchestrate-tasks` 工作流**需要你**时——在问你问题、任务交付了、主 agent 因 API 错误停了、或者卡住了且主 agent 叫不醒——zyz-worker 可以通过 IM 提醒你，省得你一直盯着会话。任务还在正常执行时（主 agent 停下等 subagent、subagent 走了一步）**不发**：那由 watchdog 叫醒主 agent，不打扰你。

它只提供**一种机制：自定义命令。** 插件负责检测事件，然后运行你配置的 shell 命令，并把事件数据交给它。消息发往哪里由你决定（飞书、Telegram、Slack、企业微信、钉钉、webhook、`notify-send`，什么都行）。常见目标的现成配置见下文，复制即可使用。

## 启用

创建 `~/.zyz-worker/notify.json`：

```json
{
  "enabled": true,
  "command": "…see recipes below…",
  "events": ["needs_input", "completed", "failed", "stuck"],
  "cooldown_sec": 30,
  "include_message": true
}
```

密钥（bot token、webhook URL）只保存在你 home 目录下的这个文件里——它们永远不会进入仓库或 git。每次事件都会重新读取该文件，所以改动立即生效。

| 键 | 必填 | 默认值 | 含义 |
|---|---|---|---|
| `enabled` | 是 | — | 总开关；`false` 关闭所有通知 |
| `command` | 是 | — | 每次事件运行的 shell 命令（payload 见下文） |
| `events` | 否 | `["needs_input","completed","failed","stuck"]` | 要发送哪些类别；**省略则使用默认集合**（注意 `session_end` **不**在其中） |
| `cooldown_sec` | 否 | `30` | **同一类别**的两次通知之间的最小间隔秒数 |
| `include_message` | 否 | `true` | 为 `false` 时，自由文本 `message` 会被清空（你仍会收到类别、task id 和 phase——不会有任何内容离开本机） |

## 何时触发

| 类别 | 触发条件 | 你的场景 |
|---|---|---|
| `needs_input` | 有对话框在等你（权限确认 / elicitation / "agent needs input"）；主 agent 用 AskUserQuestion 提问；主 agent 用自然语言提问并声明了 `expect.sh set <key> user`（含 `--watch`：问题挂着、它同时继续做别的）；主 agent 在设计阶段停下、没有在跑的执行者（多半在等你批准设计） | 需要你回答问题 / 授权 / 批准 |
| `completed` | 任务进入交付阶段：`awaiting-confirmation`、`observing`、`done`（每次进入只发一次） | 任务交付了、等你确认 |
| `failed` | **主 agent 自己**因 API 错误终止（限流、认证、余额、过载、服务端错误）——没有东西会让它继续 | 需要你处理的异常中断 |
| `stuck` | watchdog 报告了一个问题（会话静默、无执行者、到点没处理、角色死亡……）并叫醒了主 agent，至少 10 分钟后会话里仍没有任何动作；同一段停摆只发一次 | 主 agent 叫不醒或叫醒了也没处理 |
| `session_end` | 会话正常关闭（logout / quit / clear / resume）——**默认关闭** | 会话正常结束 |

提问类的 `needs_input`（AskUserQuestion、`user` 声明）延迟 60 秒再发（`ZYZ_NOTIFY_ASK_DELAY_SEC`），这期间你已经回答了就不发；权限确认由宿主在你离开约 6 秒后才通知。subagent / teammate 因 API 错误中断、主 agent 普通的停下、宿主的 `idle_prompt` 都**不**发 IM——它们是主 agent 的事，watchdog 会叫醒它；主 agent 处理不了时你会收到 `stuck`。0.32.0 之前的 `idle` 类别（每次停下都发）已删除，配置里写了也不会发。通知只在 `execute-task` / `orchestrate-tasks` 工作流内部触发（必须能解析到本会话的任务指针 `.zyz-worker/sessions/<session-id>`，或退回时的 `.zyz-worker/current-task`）——普通的交互式会话不受影响。

每条通知的标题前面都有**会话名称** `【<会话名>】`，方便你直接找到该打开哪个会话：Claude Code 用 `/rename` 起的名字，没有就用它自动生成的标题；Codex 用线程名。`include_message:false` 时不带名称（它来自对话内容），改用会话 id 的前 8 位。

**它捕获不到的情况：** 真正的整个进程死亡——`kill -9`、OOM、关闭终端、SSH/网络连接断开——不会运行任何 hook，而且会把 watchdog 一起带走。`stuck` 类别覆盖的是进程仍然存活、但任务停滞且主 agent 没有处理的情况；要可靠地捕获宿主机死亡，需要一个单独的常驻守护进程（未提供）。

## 你的命令收到的 payload

同时以环境变量和 **stdin** 上的 JSON 对象两种形式提供：

| 环境变量 | JSON 字段 | 示例 |
|---|---|---|
| `ZYZ_NOTIFY_EVENT` | `event` | `needs_input` |
| `ZYZ_NOTIFY_TITLE` | `title` | `【combo v3】Agent 需要你的输入` |
| `ZYZ_NOTIFY_MESSAGE` | `message` | `Claude needs your permission`（`include_message:false` 时为空） |
| `ZYZ_NOTIFY_TASK_ID` | `task_id` | `add-oauth-login` |
| `ZYZ_NOTIFY_PHASE` | `phase` | `implementation` |
| `ZYZ_NOTIFY_CWD` | `cwd` | 任务目录 |
| `ZYZ_NOTIFY_SESSION_ID` | `session_id` | Claude 会话 id / Codex 线程 id |
| `ZYZ_NOTIFY_SESSION_NAME` | `session_name` | `combo v3`（会话名称；`include_message:false` 或取不到时为空） |
| `ZYZ_NOTIFY_HOST` | `host` | 机器主机名 |
| `ZYZ_NOTIFY_TIMESTAMP` | `timestamp` | ISO 8601 |

命令要快，发出即走（一条 `curl` 就够了）。它是异步运行的，并且有时间上限，但一条永远阻塞的命令仍会白白耗掉这份时间预算。

## 配置示例

### 飞书 / Lark 自定义机器人 webhook

在飞书里创建一个群机器人，复制它的 webhook URL，然后粘贴下面这条 `command`（替换掉 URL）。它会把生成的标题和消息作为一张文本卡片发出：

```json
{
  "enabled": true,
  "events": ["needs_input", "completed", "failed", "stuck"],
  "command": "curl -s -m 8 -H 'Content-Type: application/json' -d \"{\\\"msg_type\\\":\\\"text\\\",\\\"content\\\":{\\\"text\\\":\\\"[$ZYZ_NOTIFY_EVENT] $ZYZ_NOTIFY_TITLE — task $ZYZ_NOTIFY_TASK_ID ($ZYZ_NOTIFY_PHASE)\\n$ZYZ_NOTIFY_MESSAGE\\\"}}\" https://open.feishu.cn/open-apis/bot/v2/hook/XXXXXXXX >/dev/null"
}
```

如果你的机器人开启了签名校验，要么把它关掉（最简单），要么把签名逻辑包进一个小脚本，再让 `command` 指向这个脚本。

### Telegram bot

用 @BotFather 创建一个 bot，拿到它的 token 和你的 chat id（先给 bot 发一条消息，然后读取 `https://api.telegram.org/bot<TOKEN>/getUpdates`）：

```json
{
  "enabled": true,
  "events": ["needs_input", "completed", "failed", "stuck"],
  "command": "curl -s -m 8 -d chat_id=<CHAT_ID> --data-urlencode \"text=[$ZYZ_NOTIFY_EVENT] $ZYZ_NOTIFY_TITLE — task $ZYZ_NOTIFY_TASK_ID ($ZYZ_NOTIFY_PHASE)\n$ZYZ_NOTIFY_MESSAGE\" https://api.telegram.org/bot<TOKEN>/sendMessage >/dev/null"
}
```

### 通用 webhook（Slack / 钉钉 / 企业微信 / 你自己的端点）

把完整的 JSON payload（从 stdin 传入）原样转发：

```json
{
  "enabled": true,
  "command": "curl -s -m 8 -H 'Content-Type: application/json' --data-binary @- https://your.endpoint/hook >/dev/null"
}
```

### 指向一个脚本（最灵活）

当目标需要签名、重试或更丰富的格式时，把逻辑写进脚本，让 `command` 去调用它——脚本会继承 `ZYZ_NOTIFY_*` 环境变量和 stdin 上的 JSON：

```json
{ "enabled": true, "command": "~/.zyz-worker/notify-send.sh" }
```

## 关闭

- 删除 `~/.zyz-worker/notify.json`，或在其中设置 `"enabled": false`。
- 或者在环境中设置 `ZYZ_NOTIFY_DISABLE=1`（只关闭通知器），或 `ZYZ_HOOKS_DISABLE=1`（关闭整个 watchdog 层）。
