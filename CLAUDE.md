# zyz-worker Claude Code Instructions

This repository provides an agent plugin scaffold for Codex and Claude Code.

## Execute Task Workflow

When the user asks to run the execute-task workflow, use the project slash command:

```text
/execute-task <task description>
```

`/code-development` is kept as an alias for the same workflow.

The workflow is defined by:

- `skills/execute-task/SKILL.md`
- `skills/execute-task/prompts/main-agent.md`
- `skills/execute-task/templates/`

The current conversation agent is the main agent. It remains user-facing and coordinates the workflow.

Project-level Claude Code subagents are available in `agents/` (also reachable as `.claude/agents/` via symlink):

- `coding-agent`
- `test-agent`
- `review-agent`

These subagents mirror the shared prompt definitions in `subagents/`.

Do not treat `skills/execute-task/prompts/main-agent.md` as a Claude Code subagent. It is the controller prompt for the current user-facing conversation agent.
