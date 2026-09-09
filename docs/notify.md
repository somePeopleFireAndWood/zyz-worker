# IM stop-notifications (`notify.sh`)

zyz-worker can ping you over IM when a long-running `execute-task` /
`orchestrate-tasks` workflow **stops** — it needs your input, it finished, it
hit an API error, or a role stalled — so you don't have to babysit the session.

It ships **one mechanism: a custom command.** The plugin detects the event and
runs a shell command you configure, handing it the event data. You decide where
the message goes (Feishu, Telegram, Slack, 企业微信, 钉钉, a webhook, `notify-send`,
anything). Ready-to-paste recipes for the common targets are below.

## Enable it

Create `~/.zyz-worker/notify.json`:

```json
{
  "enabled": true,
  "command": "…see recipes below…",
  "events": ["needs_input", "completed", "failed", "stuck"],
  "cooldown_sec": 30,
  "include_message": true
}
```

Secrets (bot tokens, webhook URLs) live only in this file under your home
directory — they never enter the repo or git. The file is read fresh on every
event, so edits take effect immediately.

| key | required | default | meaning |
|---|---|---|---|
| `enabled` | yes | — | master switch; `false` disables all notifications |
| `command` | yes | — | shell command run on each event (see payload below) |
| `events` | no | `["needs_input","completed","failed","stuck"]` | which categories to send; **omit to get the default set** (note `session_end` is NOT in it) |
| `cooldown_sec` | no | `30` | minimum seconds between two notifications **of the same category** |
| `include_message` | no | `true` | when `false`, the free-text `message` is blanked (you still get the category, task id, and phase — no content leaves the machine) |

## When it fires

| category | fires on | your scenario |
|---|---|---|
| `needs_input` | Claude waiting on a permission prompt / an elicitation / "agent needs input" | 需要你回答问题 / 授权 |
| `completed` | the agent finished and went idle (`agent_completed` / `idle_prompt`) | 任务完成、停下等你 |
| `failed` | an API-error termination (rate limit, auth, overloaded, server error) | 可捕获的异常中断 |
| `stuck` | the watchdog saw a role go silent / status go stale / a completion unharvested | agent 卡死 / 子代理疑似死亡 |
| `session_end` | the session closed gracefully (logout / quit / clear / resume) — **off by default** | 会话正常结束 |

`needs_input` / `completed` fire only when you have actually stepped away
(~6 seconds for a permission prompt, ~60 seconds after an idle finish), so an
actively-typing session is never spammed. Notifications fire only inside an
`execute-task` / `orchestrate-tasks` workflow (a `.zyz-worker/current-task`
pointer must resolve) — ordinary interactive sessions are left alone.

**What it cannot catch:** a true whole-process death — `kill -9`, OOM, closing
the terminal, a dropped SSH/network connection — runs no hook and takes the
watchdog down with it. The `stuck` category covers a role stalling while the
process is still alive; catching host death reliably would require a separate
always-on daemon (not shipped).

## The payload your command receives

Both as environment variables and as a JSON object on **stdin**:

| env var | JSON field | example |
|---|---|---|
| `ZYZ_NOTIFY_EVENT` | `event` | `needs_input` |
| `ZYZ_NOTIFY_TITLE` | `title` | `Agent needs your input` |
| `ZYZ_NOTIFY_MESSAGE` | `message` | `Claude needs your permission` (blank if `include_message:false`) |
| `ZYZ_NOTIFY_TASK_ID` | `task_id` | `add-oauth-login` |
| `ZYZ_NOTIFY_PHASE` | `phase` | `implementation` |
| `ZYZ_NOTIFY_CWD` | `cwd` | the task directory |
| `ZYZ_NOTIFY_SESSION_ID` | `session_id` | Claude session id |
| `ZYZ_NOTIFY_HOST` | `host` | machine hostname |
| `ZYZ_NOTIFY_TIMESTAMP` | `timestamp` | ISO 8601 |

Keep the command fast and fire-and-forget (a `curl` is fine). It runs
asynchronously and is time-boxed, but a command that blocks forever still wastes
that budget.

## Recipes

### Feishu / Lark custom-bot webhook

Create a group bot in Feishu, copy its webhook URL, and paste this `command`
(replace the URL). It sends the built title + message as a text card:

```json
{
  "enabled": true,
  "events": ["needs_input", "completed", "failed", "stuck"],
  "command": "curl -s -m 8 -H 'Content-Type: application/json' -d \"{\\\"msg_type\\\":\\\"text\\\",\\\"content\\\":{\\\"text\\\":\\\"[$ZYZ_NOTIFY_EVENT] $ZYZ_NOTIFY_TITLE — task $ZYZ_NOTIFY_TASK_ID ($ZYZ_NOTIFY_PHASE)\\n$ZYZ_NOTIFY_MESSAGE\\\"}}\" https://open.feishu.cn/open-apis/bot/v2/hook/XXXXXXXX >/dev/null"
}
```

If your bot has signature verification enabled, disable it (simplest) or wrap
the signing in a small script and point `command` at that script instead.

### Telegram bot

Create a bot with @BotFather, get its token, and your chat id (message the bot,
then read `https://api.telegram.org/bot<TOKEN>/getUpdates`):

```json
{
  "enabled": true,
  "events": ["needs_input", "completed", "failed", "stuck"],
  "command": "curl -s -m 8 -d chat_id=<CHAT_ID> --data-urlencode \"text=[$ZYZ_NOTIFY_EVENT] $ZYZ_NOTIFY_TITLE — task $ZYZ_NOTIFY_TASK_ID ($ZYZ_NOTIFY_PHASE)\n$ZYZ_NOTIFY_MESSAGE\" https://api.telegram.org/bot<TOKEN>/sendMessage >/dev/null"
}
```

### Generic webhook (Slack / 钉钉 / 企业微信 / your own endpoint)

Forward the full JSON payload (arriving on stdin) verbatim:

```json
{
  "enabled": true,
  "command": "curl -s -m 8 -H 'Content-Type: application/json' --data-binary @- https://your.endpoint/hook >/dev/null"
}
```

### Point at a script (most flexible)

When your target needs signing, retries, or richer formatting, put the logic in
a script and let `command` invoke it — it inherits the `ZYZ_NOTIFY_*` env and
the JSON on stdin:

```json
{ "enabled": true, "command": "~/.zyz-worker/notify-send.sh" }
```

## Turning it off

- Remove or set `"enabled": false` in `~/.zyz-worker/notify.json`.
- Or set `ZYZ_NOTIFY_DISABLE=1` in the environment (just the notifier), or
  `ZYZ_HOOKS_DISABLE=1` (the whole watchdog layer).
