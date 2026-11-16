# 工程结构约定

`hooks/scripts/agent-runtime-state.sh` 是独立模式下角色状态唯一受支持的面向用户的写入入口；`hooks/scripts/runtime_state.py` 是它无第三方依赖的后端。以哈希为键的逻辑记录存放在 `.zyz-worker/tasks/<task-id>/runtime/` 下的固定 catalog/audit/work pack 中，不得手工编辑。有界等待只记录在整体 `status.md` 唯一的 `## Agent State` 小节里。

本仓库是一个多 CLI 的 agent 插件。它用一套共享资产加上各 CLI 各自的清单，同时面向 Codex 与 Claude Code。

## 根目录布局

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
├── monitors/
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

## 目录职责

### `.claude-plugin/`

Claude Code 插件清单。Claude Code 要把本目录识别为可安装插件，必须有 `.claude-plugin/plugin.json`。保持它最小化：name、description、version、author、repository、license、keywords。

其它插件组件（skill、agent、命令、hook）放在仓库根目录，**不**放在 `.claude-plugin/` 里。

### `.codex-plugin/`

Codex 插件清单。`.codex-plugin/plugin.json` 向 Codex 描述本插件。只写真正已实现的能力；在对应文件和行为存在之前，不要加入 hooks、MCP server 或 apps。

### `.claude/`

项目级的 Claude Code 集成，用于把本仓库**当作项目**使用（在仓库内运行 `claude` 并调用 `/execute-task`（或其别名 `/code-development`））。

- `.claude/agents` 是指向根目录 `agents/` 的符号链接。
- `.claude/commands` 是指向根目录 `commands/` 的符号链接。

这些符号链接让 Claude Code 在两处看到同一批文件：在本仓库内运行时，它们是项目级定义；通过 `claude --plugin-dir` 加载本仓库时，它们是插件组件。

### `agents/`

根级 subagent 定义，在本仓库作为插件加载时由 Claude Code 读取。每个 agent 是一个带 YAML frontmatter 的 Markdown 文件。

已实现：execute-task 的三个角色（`implementation-agent`、`test-agent`、`review-agent`），以及 orchestration skill 的 L2 单 worker pane 驱动（`orch-driver-agent`）。这里的每个文件在 `subagents/` 中都有一份正文完全相同的镜像。

### `commands/`

根级 slash command 定义，在本仓库作为插件加载时由 Claude Code 读取。命令文件引用插件内部资源时应使用 `${CLAUDE_PLUGIN_ROOT}/...`，这样无论当前工作目录在哪里都能正确解析。

### `skills/`

Codex 与 Claude Code 共用的 skill。每个 skill 独占一个目录：

```text
skills/
└── <skill-name>/
    ├── SKILL.md
    ├── references/
    └── templates/
```

`SKILL.md` 是入口。它应当定义：

- 何时应使用该 skill
- 必需的输入
- 执行工作流
- 预期产出
- 失败与升级处理方式
- 必要时针对 Codex 与 Claude Code 的 agent 专属说明

用 `templates/` 存放可复用的输出形态，用 `references/` 存放 skill 可按需加载的辅助资料。

skill 可以是只带 `SKILL.md`（没有 `prompts/` 或 `templates/`）的轻量工具，例如 `git-worktree`。skill 也可以给它的 `SKILL.md` 配一个 `references/` 目录，用来存放按需加载的辅助资料，例如跨平台清理 skill `clean-tmp`（`SKILL.md` + `references/`）。

### `subagents/`

当项目开始建模独立角色（如产品分析、技术设计、实现或测试）时，共享的纯提示词式 subagent 定义放在这里。

这些文件是角色提示词的事实源。`agents/` 中的 Claude Code 原生 subagent 可以复制或扩展这些定义。

### `hooks/`

当项目需要生命周期自动化、校验或基于事件的行为时，hook 定义与 hook 脚本放在这里。

hook 应当小巧、确定，并写明其触发点、输入、输出和失败模式。

已实现：`hooks/hooks.json` 通过双重插件根目录展开与双重工具名匹配器，为 Claude Code 与 Codex 两端注册 execute-task watchdog 层。Codex 还会在 `SessionStart` 时启动共享的后台 watchdog；Claude Code 则使用 `monitors/monitors.json`。所有 hook 都 fail-open，在解析不到本会话的任务指针（`.zyz-worker/sessions/<session-id>`，退回时为 `.zyz-worker/current-task`）时什么也不做。见 `hooks/README.md` 与 [../architecture.md](../architecture.md)。

### `monitors/`

插件后台监视器。`monitors/monitors.json` 声明常驻进程，其 stdout 的每一行都会作为通知投递给主 agent。已实现：`watchdog.sh`，以 `when: "always"`（会话启动时）上膛，并以本会话的任务指针自我门控；它报告静默/死亡的 subagent 角色以及过期的状态文件，让主 agent 无需记着轮询也能介入。不要把它收窄成 `on-skill-invoke:<skill>`——该写法会按精确字符串与发出的 skill 名比对，而插件安装下发出的是限定名（`zyz-worker:execute-task`），项目模式下发出的是裸名（`execute-task`），任何单个字面量都无法在两种情况下都上膛。

### `scripts/`

仓库本地的自动化脚本放在这里。合适的候选包括校验、格式化、打包、冒烟测试和文档检查。

脚本应当可以安全地重复运行，除非有文档说明，否则不应依赖特定用户的绝对路径。

这里还实现了：`pack.sh`（构建 `dist/zyz-worker-<version>.zip`，以 `git ls-files` 作为唯一的装箱清单，以 `.claude-plugin/plugin.json` 作为版本来源），以及 `test-*.sh` 测试套件（见 [../architecture.md](../architecture.md) 中的测试策略表）。

**编排 helper（`scripts/orch-*.sh`）。** `orchestration-scheduling-task` skill 调用一小组固定的 bash helper——`orch-scan-tasks.sh`、`orch-spawn-worker.sh`、`orch-reuse-worker.sh`、`orch-build-env.sh`、`orch-worker-mcp-args.sh`、`orch-check-worker.sh`、`orch-heartbeat-daemon.sh`、`orch-cleanup-worker.sh`、`orch-merge.sh`、`orch-merge-and-cleanup.sh`。它们放在本目录，并遵循以下约定：

- `#!/usr/bin/env bash` + `set -euo pipefail` + 文件顶部的 in-file contract 块。
- 所有 `task-id` 输入都按 `^[A-Za-z0-9_-]+$` 校验；不合法 → exit 2。
- 缺少必需的外部命令（`tmux`、`git`）→ exit 3。
- 在 stdout 输出结构化的 `key=value` 行；给人看的消息走 stderr。
- 每个 helper 都要 `chmod +x`，以便编排器直接调用。
- 由编排器提示词调用这些 helper；不要在提示词文本里重新实现它们的逻辑。

### `<list-dir>/runtime/<task-id>/`

编排调度器派发 worker 时，每个任务的运行时状态存放在 `<list-dir>/runtime/<task-id>/` 下。约定如下：

- `worker-status.md` —— 由 worker 写入、面向编排器的快照。
- `heartbeat` —— 单行 ISO 时间戳，由 pane 内的心跳守护进程刷新。
- `question.md` / `answer.md` —— 用户↔worker 的异步问答；已消费的回答会被重命名为 `answer.md.consumed.<question-id>`。

`<list-dir>` 本身默认为 `.zyz-worker/orchestration/<list-name>/`，是编排器的单一事实源（`<list-dir>/tasks/<task-id>.md` 下的主条目，加上 `<list-dir>/SUMMARY.md`、`<list-dir>/.orchestrator.lock` 以及上面的 runtime 子树）。完整的文件协议见 `skills/orchestration-scheduling-task/SKILL.md`。

### `docs/`

设计笔记、约定和实施计划放在这里。

- `docs/design/` 存放产品与技术设计文档。
- `docs/conventions/` 存放仓库范围的工程约定与插件结构约定。

### `assets/`

插件的静态资产放在这里，例如图标、截图、示例图片或品牌资源。

除非插件确实需要，否则不要把生成的或大型的二进制资产放进仓库。

## Agent 兼容性

本仓库遵循多 CLI 插件模式：共享资产放在根目录，各 CLI 的清单放在以点开头的目录中。

- Claude Code 读取 `.claude-plugin/plugin.json`，并在仓库根目录查找 `agents/`、`commands/`、`skills/`、`hooks/`。
- Codex 读取 `.codex-plugin/plugin.json`，并在仓库根目录查找 `skills/`。
- 本仓库也可以通过 `CLAUDE.md` 与 `.claude/` 符号链接，作为 Claude Code 项目使用（无需安装插件）。

共享工作流默认应保持与 agent 无关。只有在行为、文件位置或运行时预期存在差异时，才添加 agent 专属的小节。

## 横切约定

- 长期任务的状态存放在文件中。见 [long-running-state.md](./long-running-state.md)。
