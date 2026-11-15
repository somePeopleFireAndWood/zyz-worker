# Loop 状态 — <name>

session 内的 loop 与 cron watchdog 共享的唯一事实来源。双方都读取本文件；loop 完成一个任务时写入一行，watchdog 的幂等检查是"该任务那一行是否包含今天的日期"。

**loop 运行期间不要手动编辑本文件**，除非你清楚自己在做什么——watchdog 每 20 分钟读取一次，loop 每次唤醒时也会读取。

## 任务

| 任务 | 计划 | 上次运行 | 备注 |
|---|---|---|---|
| T1 | <e.g. daily 16:05> | <YYYY-MM-DD HH:MM> | <status / result pointer> |
| T2 | <e.g. weekdays 07:35> | <YYYY-MM-DD HH:MM> | <status / result pointer> |

行格式不能随意改动，脚本依赖它：watchdog 匹配 `^| <task-id> `，并在该行中查找今天的 `YYYY-MM-DD`。保持行首 `| T1 ` 的形态不变。

## 运行日志

- <YYYY-MM-DD HH:MM> — <task> — <ok / back-filled by loop / headless back-fill> — <detail>
