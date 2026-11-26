---
argument-hint: [--fast|--standard|--strict] [任务描述]
description: 运行 zyz-worker 的设计先行代码开发工作流。
---

对下面这个任务使用 zyz-worker 的 execute-task 工作流：

```text
$ARGUMENTS
```

档位：上面的内容以 `--fast`、`--standard` 或 `--strict` 开头时，取该档位，其余部分是任务描述；自然语言的"快速档 / 标准档 / 严格档"等同于对应参数。都没有时，由主 agent 在第一条回复里提议一个档位并说明理由（见 SKILL.md `## 档位`）。

加载并遵循主控提示词：

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/prompts/main-agent.md

使用工作流定义：

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/SKILL.md

可用的任务模板：

- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/task-status.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/decisions.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/change-note.md（快速档，代替设计文档）
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/design-doc.md（标准档、严格档）
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/review-report.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/final-report.md

专题细则按 SKILL.md `## 加载与文件` 的表格，从 `${CLAUDE_PLUGIN_ROOT}/skills/execute-task/references/` 按需加载。

需要相应角色时，使用项目 subagent：

- `implementation-agent`（快速档、标准档里也承担同时写代码和测试的 lane）
- `test-agent`
- `review-agent`

重要边界：

- 当前对话的 agent 就是主 agent，始终面向用户，负责协调、写文档、更新任务状态、派发 subagent。
- 主 agent 不亲自评审。快速档里单 lane 的小改动可以由主 agent 直接改并自验证；其余情况主 agent 不写、不改实现和测试代码（边界细节见主控提示词 `## 职责与硬性限制`）。
- 已安装的 skill、插件和工具能提升产出质量时就使用它们，缺少可选能力时不要求用户安装。
