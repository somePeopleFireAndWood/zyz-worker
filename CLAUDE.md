# zyz-worker Claude Code Instructions

This repository provides an agent plugin scaffold for Codex and Claude Code.

## Code Development Workflow

When the user asks to run the code-development workflow, use the project slash command:

```text
/code-development <task description>
```

The workflow is defined by:

- `skills/code-development/SKILL.md`
- `skills/code-development/prompts/main-agent.md`
- `skills/code-development/templates/`

The current conversation agent is the main agent. It remains user-facing and coordinates the workflow.

Project-level Claude Code subagents are available in `.claude/agents/`:

- `coding-agent`
- `test-agent`
- `review-agent`

These subagents mirror the shared prompt definitions in `subagents/`.

Do not treat `skills/code-development/prompts/main-agent.md` as a Claude Code subagent. It is the controller prompt for the current user-facing conversation agent.
