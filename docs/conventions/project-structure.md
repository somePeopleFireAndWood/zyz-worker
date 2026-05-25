# Project Structure Convention

This repository is an agent plugin project. It starts with Codex plugin support and keeps the structure open for Claude Code compatibility, skills, subagents, hooks, scripts, templates, and assets.

## Root Layout

```text
.
├── .codex-plugin/
│   └── plugin.json
├── assets/
├── docs/
│   ├── conventions/
│   └── design/
├── hooks/
├── scripts/
├── skills/
│   └── <skill-name>/
│       ├── SKILL.md
│       ├── references/
│       └── templates/
├── subagents/
├── LICENSE
└── README.md
```

## Directory Responsibilities

### `.codex-plugin/`

Codex plugin metadata lives here. Keep `.codex-plugin/plugin.json` focused on capabilities that are actually implemented.

Do not add hooks, MCP servers, apps, or other runtime declarations to `plugin.json` until the matching files and behavior exist.

### `skills/`

Each skill gets its own directory:

```text
skills/
└── <skill-name>/
    ├── SKILL.md
    ├── references/
    └── templates/
```

`SKILL.md` is the entry point. It should define:

- when the skill should be used
- required inputs
- execution workflow
- expected outputs
- failure and escalation behavior
- agent-specific notes for Codex and Claude Code when needed

Use `templates/` for reusable output shapes and `references/` for supporting material that the skill may load on demand.

### `subagents/`

Subagent definitions belong here when the project starts modeling separate roles such as product analysis, technical design, implementation, or testing.

For the first version, prefer expressing the workflow in one skill unless a separate subagent removes real complexity.

### `hooks/`

Hook definitions and hook scripts belong here when the project needs lifecycle automation, validation, or event-based behavior.

Hooks should be small, deterministic, and documented with their trigger point, inputs, outputs, and failure mode.

### `scripts/`

Repository-local automation belongs here. Good candidates include validation, formatting, packaging, smoke tests, and documentation checks.

Scripts should be safe to run repeatedly and should not depend on user-specific absolute paths unless documented.

### `docs/`

Design notes, conventions, and implementation plans belong here.

- `docs/design/` stores product and technical design documents.
- `docs/conventions/` stores repository-wide engineering and plugin structure conventions.

### `assets/`

Static plugin assets belong here, such as icons, screenshots, example images, or brand resources.

Keep generated or large binary assets out of the repository unless they are needed by the plugin.

## Agent Compatibility

Codex-specific metadata belongs in `.codex-plugin/`.

Claude Code compatibility should be represented in the relevant skill, subagent, or hook documentation until this repository introduces a dedicated Claude Code manifest or packaging convention.

Shared workflows should stay agent-neutral by default. Add agent-specific sections only when behavior, file placement, or runtime expectations differ.
