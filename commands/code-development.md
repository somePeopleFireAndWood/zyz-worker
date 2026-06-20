---
argument-hint: [task description]
description: Alias for /execute-task. Run the zyz-worker design-first code development workflow.
---

Use the zyz-worker execute-task workflow for this task:

```text
$ARGUMENTS
```

Load and follow the main controller prompt:

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/prompts/main-agent.md

Use the workflow definition and templates:

@${CLAUDE_PLUGIN_ROOT}/skills/execute-task/SKILL.md

Available task templates:

- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/design-doc.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/task-status.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/final-report.md
- @${CLAUDE_PLUGIN_ROOT}/skills/execute-task/templates/review-report.md

Use the project subagents when their role is needed:

- `implementation-agent`
- `test-agent`
- `review-agent`

Important boundaries:

- The current conversation agent is the main agent and stays user-facing.
- The main agent coordinates, documents, updates task status, and dispatches subagents.
- The main agent must not directly implement code, modify tests, run tests, or perform review.
- Use existing installed skills, plugins, and tools when they improve output quality, but never require the user to install missing optional capabilities.
