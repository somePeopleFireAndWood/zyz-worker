---
argument-hint: [--fast|--standard|--strict] [任务描述]
description: 运行 zyz-worker 的设计先行代码开发工作流。
---

对下面这个任务使用 zyz-worker 的 execute-task 工作流：

```text
$ARGUMENTS
```

上面的内容以 `--fast`、`--standard` 或 `--strict` 开头时，取该档位，其余部分是任务描述。

当前对话的 agent 就是主 agent。加载并遵循：

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/SKILL.md

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/prompts/main-agent.md

模板在 `${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/`，专题细则在 `${CLAUDE_PLUGIN_ROOT}/skills/execute-task/references/`，用到时再读。角色用项目 subagent `implementation-agent`、`test-agent`、`review-agent`。
