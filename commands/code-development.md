---
argument-hint: [任务描述]
description: /execute-task 的别名。运行 zyz-worker 的设计先行代码开发工作流。
---

对下面这个任务使用 zyz-worker 的 execute-task 工作流：

```text
$ARGUMENTS
```

加载并遵循主控提示词：

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/prompts/main-agent.md

使用工作流定义和模板：

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/SKILL.md

可用的任务模板：

- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/design-doc.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/task-status.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/final-report.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/review-report.md

需要相应角色时，使用项目 subagent：

- `implementation-agent`
- `test-agent`
- `review-agent`

重要边界：

- 当前对话的 agent 就是主 agent，始终面向用户。
- 主 agent 负责协调、写文档、更新任务状态、派发 subagent。
- 主 agent **不得**直接实现代码、修改测试、运行测试或执行评审。
- 已安装的 skill、插件和工具能提升产出质量时就使用它们，但**绝不**要求用户去安装缺失的可选能力。
