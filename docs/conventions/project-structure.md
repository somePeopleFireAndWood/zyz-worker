# Project Structure Convention

This repository is a multi-CLI agent plugin. It targets both Codex and Claude Code with a single set of shared assets and per-CLI manifests.

## Root Layout

```text
.
├── .claude-plugin/
│   └── plugin.json
├── .codex-plugin/
│   └── plugin.json
├── .claude/
│   ├── agents/   -> ../agents (symlink)
│   └── commands/ -> ../commands (symlink)
├── agents/
├── commands/
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
├── CLAUDE.md
├── LICENSE
└── README.md
```

## Directory Responsibilities

### `.claude-plugin/`

Claude Code plugin manifest. `.claude-plugin/plugin.json` is required for Claude Code to recognize this directory as an installable plugin. Keep it minimal: name, description, version, author, repository, license, keywords.

Other plugin components (skills, agents, commands, hooks) live at the repository root, **not** inside `.claude-plugin/`.

### `.codex-plugin/`

Codex plugin manifest. `.codex-plugin/plugin.json` describes the plugin to Codex. Keep it focused on capabilities that are actually implemented; do not add hooks, MCP servers, or apps until the matching files and behavior exist.

### `.claude/`

Project-level Claude Code integration for using this repository **as a project** (running `claude` inside the repo and invoking `/execute-task` (or its alias `/code-development`)).

- `.claude/agents` is a symlink to the root `agents/` directory.
- `.claude/commands` is a symlink to the root `commands/` directory.

The symlinks let Claude Code see the same files in two places: as project-level definitions when running inside this repo, and as plugin components when this repository is loaded via `claude --plugin-dir`.

### `agents/`

Root-level subagent definitions consumed by Claude Code when this repository is loaded as a plugin. Each agent is a Markdown file with YAML frontmatter.

### `commands/`

Root-level slash command definitions consumed by Claude Code when this repository is loaded as a plugin. Command files should reference plugin-internal resources via `${CLAUDE_PLUGIN_ROOT}/...` so they resolve regardless of the current working directory.

### `skills/`

Shared skills consumed by both Codex and Claude Code. Each skill gets its own directory:

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

Shared prompt-only subagent definitions belong here when the project starts modeling separate roles such as product analysis, technical design, implementation, or testing.

These are sources of truth for the role prompts. Claude Code native subagents in `agents/` may copy or extend these definitions.

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

This repository follows the multi-CLI plugin pattern: shared assets at the root, per-CLI manifests in dotted directories.

- Claude Code reads `.claude-plugin/plugin.json` and looks for `agents/`, `commands/`, `skills/`, `hooks/` at the repository root.
- Codex reads `.codex-plugin/plugin.json` and looks for `skills/` at the repository root.
- The repository can also be used as a Claude Code project (without plugin install) via `CLAUDE.md` and the `.claude/` symlinks.

Shared workflows should stay agent-neutral by default. Add agent-specific sections only when behavior, file placement, or runtime expectations differ.

## Cross-cutting Conventions

- Long-running task state lives in files. See [long-running-state.md](./long-running-state.md).
