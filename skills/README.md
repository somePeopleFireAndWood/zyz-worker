# Skills

Each skill lives in its own directory and uses `SKILL.md` as the entry point.

Recommended layout:

```text
skills/
└── <skill-name>/
    ├── SKILL.md
    ├── prompts/
    ├── references/
    └── templates/
```

Use `prompts/` for the skill's own controller or helper prompts. Use `references/` for supporting material that should be loaded only when needed. Use `templates/` for reusable document or output formats. Every subdirectory is optional — a lightweight skill may ship only `SKILL.md`.

Current skills:

- `execute-task/` — the design-first single-task workflow (`SKILL.md` + `prompts/` + `templates/`)
- `orchestration-scheduling-task/` — multi-task scheduling over a master list (`SKILL.md` + `prompts/` + `templates/`)
- `git-worktree/` — worktree create/list/move/remove helper conventions (`SKILL.md` only)
- `clean-tmp/` — cross-platform temp / Docker / build-cache cleanup (`SKILL.md` + `references/`)
