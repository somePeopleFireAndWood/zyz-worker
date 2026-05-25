---
argument-hint: [task description]
description: Run the zyz-worker design-first code development workflow
---

Use the zyz-worker code-development workflow for this task:

```text
$ARGUMENTS
```

Load and follow the main controller prompt:

@skills/code-development/prompts/main-agent.md

Use the workflow definition and templates:

@skills/code-development/SKILL.md

Available task templates:

- @skills/code-development/templates/design-doc.md
- @skills/code-development/templates/task-status.md
- @skills/code-development/templates/final-report.md
- @skills/code-development/templates/review-report.md

Use the project subagents when their role is needed:

- `coding-agent`
- `test-agent`
- `review-agent`

Important boundaries:

- The current conversation agent is the main agent and stays user-facing.
- The main agent coordinates, documents, updates task status, and dispatches subagents.
- The main agent must not directly implement code, modify tests, run tests, or perform review.
- Use existing installed skills, plugins, and tools when they improve output quality, but never require the user to install missing optional capabilities.
