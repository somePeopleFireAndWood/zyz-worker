---
argument-hint: '[任务描述，含「每天几点做什么」] | uninstall <name>'
description: 在本会话中安装一个自愈式定时循环（session loop + cron watchdog + 哨兵唤醒），或卸载一个已安装的循环。
---

在**本**会话中安装（或拆除）一个自愈式定时循环：

```text
$ARGUMENTS
```

加载并遵循 skill 说明：
`skills/self-healing-loop/SKILL.md`（位于已安装的 zyz-worker 插件中）。

- 给出任务描述时：解析出各项任务及其到点时间，然后在同一轮内完成三个安装步骤
  ——安装 watchdog 脚本 + crontab 行（先展示确切的 crontab 行并取得用户明确确认；
  这是系统级改动）、挂上常驻的哨兵 Monitor、用第一次 `ScheduleWakeup` 启动循环。
  然后报告安装路径、触发语义表，以及自愈边界（能覆盖断链/沉睡的循环，**不能**
  覆盖被杀掉的进程）。
- 给出 `uninstall <name>` 时：停掉会话内的循环和 Monitor，然后运行生成的
  `<name>-uninstall.sh`，移除 crontab 行以及哨兵/锁文件。
