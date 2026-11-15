# 技能

每个 skill 独占一个目录，以 `SKILL.md` 作为入口。

推荐布局：

```text
skills/
└── <skill-name>/
    ├── SKILL.md
    ├── prompts/
    ├── references/
    └── templates/
```

`prompts/` 存放 skill 自己的主控提示词或辅助提示词。`references/` 存放只在需要时才加载的辅助资料。`templates/` 存放可复用的文档或输出格式。每个子目录都是可选的——轻量 skill 可以只带一个 `SKILL.md`。

现有 skill：

- `execute-task/` —— 设计先行的单任务工作流（`SKILL.md` + `prompts/` + `templates/`）
- `orchestration-scheduling-task/` —— 基于主清单的多任务调度（`SKILL.md` + `prompts/` + `templates/`）
- `git-worktree/` —— worktree 创建/列出/移动/删除的辅助约定（只有 `SKILL.md`）
- `clean-tmp/` —— 跨平台的临时文件 / Docker / 编译缓存清理（`SKILL.md` + `references/`）
