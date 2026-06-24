# zyz-worker

我是周钰喆，一名光荣的工人，隶属于伟大的工人阶级。我会和同志们一起解放全人类，最后解放我自己。

这个插件是我实际工作时用到的方法、技能。希望能帮助到同志们的生产、工作。

zyz-worker 的一条核心信条是：**长期任务的状态以文件为单一事实源**，上下文负责执行、文件负责记忆。详见 [docs/conventions/long-running-state.md](docs/conventions/long-running-state.md)。

## 当前状态

- Claude Code 插件清单位于 `.claude-plugin/plugin.json`
- Codex 插件清单位于 `.codex-plugin/plugin.json`
- Claude Code 项目说明位于 `CLAUDE.md`
- Slash command 位于 `commands/execute-task.md`（主名）与 `commands/code-development.md`（alias，与主名内容等价）
- 多任务调度 Slash command 位于 `commands/orchestrate-tasks.md`
- SubAgent 位于 `agents/`
- `.claude/agents` 与 `.claude/commands` 是指向根级目录的符号链接，方便在本仓库内直接以项目模式使用 Claude Code
- Execute Task Skill 位于 `skills/execute-task/SKILL.md`
- Orchestration Scheduling Task Skill 位于 `skills/orchestration-scheduling-task/SKILL.md`
- git-worktree Skill 位于 `skills/git-worktree/SKILL.md`
- Execute Task 主控提示词位于 `skills/execute-task/prompts/main-agent.md`
- Orchestration 主控提示词位于 `skills/orchestration-scheduling-task/prompts/main-agent.md`
- Orchestration bash helpers 位于 `scripts/orch-*.sh`（其中 `orch-reuse-worker.sh` 用于「复用已完成任务的 tmux/worktree 创建新任务」——见下方 *容器复用*）
- 提示词式 SubAgent 定义位于 `subagents/`
- 长期任务状态文件约定位于 `docs/conventions/long-running-state.md`
- 初始设计占位文档位于 `docs/design/initial-design.md`
- execute-task Skill 设计文档位于 `docs/design/execute-task-skill-design.md`
- 工程结构约定位于 `docs/conventions/project-structure.md`
- 暂未实现 hooks、MCP server 或真实 SubAgent 运行时

## 多项目 orchestration（multi-project orchestration）

`orchestration-scheduling-task` skill 与 `/orchestrate-tasks` 支持单一 orchestrator 同时调度跨多个项目的任务（multi-project orchestration）。要点：

- orchestrator 可以在任意 cwd 启动，包括 `~/` 或任何非 git 目录；它不假设自己 cwd 在被调度项目的 git repo 内。
- 一份 master list（`<list-dir>/tasks/*.md`）里可以混合来自不同项目的 task，每个 task 各自在自己的 master entry frontmatter 里声明 `source-repo: <绝对路径或 ~/ 开头的路径>`。
- `source-repo` 是**必须**字段，由用户写；orchestrator 不自动推断。`~/workspace/foo` 与 `~/workspace/bar` 这种跨 repo 调度由此原生支持。
- spawn helper 会对 `source-repo` 做 4 道校验：缺字段、非绝对路径、路径不存在、不是 git work tree —— 任何一道失败都直接以 exit 5 + 精确诊断字符串退出，task 留在 `not-analyzed`。
- 软警示：**不要**把某个 task 的 `source-repo:` 指向 zyz-worker 插件仓库自身，除非你的本意就是在插件源码内派发一个 worker。无意中指向插件 repo 会导致 worker 在插件仓库里建分支与 worktree，与正常项目开发混淆。

三层调度架构（spawn → L2 启动真 claude → parent-shell invariant → exactly-once 幂等 → dispatch-bound 绑定）的端到端验收脚本是 `scripts/test-e2e-layered.sh`（可移植，Linux/macOS 均可）。运行：`bash scripts/test-e2e-layered.sh`（`--keep` 保留 fixture 供调试）。它需要 `tmux`/`git`/`claude` 都在 PATH 且 `claude` 已登录，并且会**消耗 API 配额**（A4 触发一次真实 LLM 往返）。这是真 claude 验收，与纯脚本单元测 `scripts/test-orchestration-helpers.sh` 分开。

## 容器复用（container reuse）

`/orchestrate-tasks` 支持「复用一个**已完成**任务遗留的 tmux session 和/或 git worktree 来创建新任务」，而不是再走一遍标准 spawn（重新 `git worktree add` + 新 session）。新任务在自己的 master entry frontmatter 里声明：

- `reuse-from: <old-task-id>` —— 要复用其容器的旧任务（必须是**同一 list** 内、`state: completed` 的任务）。
- `reuse-scope: worktree | tmux | both` —— 复用粒度（默认 `both`）。`worktree`=复用旧 worktree + 新 session + 新 claude；`tmux`=复用旧 session（新任务跑在旧 pane 的 worktree 里，cwd 不可变，`worktree:` 字段被忽略）；`both`=复用旧 worktree + 旧 session。
- `reuse-claude: true | false` —— 仅在复用 tmux 时有意义。`true`（默认）=复用同一个正在运行的 claude 进程（不重启，新任务运行时通过 *带内运行时配置块* 交给它）；`false`=在复用的 session 里重启 claude。`worktree` scope 下被忽略（一定是新 claude）。

落地为独立脚本 `scripts/orch-reuse-worker.sh <new-id> <list-dir>`（与 `orch-spawn-worker.sh` 并列；同样只关联/创建容器、写 Phase-1 `dispatch.md`、**从不**启动 claude）。复用只做容器关联，**绝不**推进或改写旧任务（旧任务始终 `completed`）。dispatch 步会据 `reuse-from` 路由到该脚本并派发 L2 `intent=reuse-dispatch`。**注意**：复用任务与其 `reuse-from` 旧任务**共享容器**，对任一方跑 cleanup 会同时销毁共享的 session/worktree——确保所有共享方都已 `completed` 再清理。详见 `skills/orchestration-scheduling-task/SKILL.md` `## Container Reuse`。

## 安装与使用

当前 `zyz-worker` 还没有发布到 Codex 或 Claude Code 的官方 marketplace。现阶段推荐按本地插件/项目配置方式安装。

### Codex

Codex 通过 `.codex-plugin/plugin.json` 和 `skills/` 识别本插件。

本地安装建议放到个人插件目录：

```bash
mkdir -p ~/plugins
git clone https://github.com/somePeopleFireAndWood/zyz-worker.git ~/plugins/zyz-worker
```

如果已经有本地 checkout，也可以使用符号链接：

```bash
mkdir -p ~/plugins
ln -s /path/to/zyz-worker ~/plugins/zyz-worker
```

然后在个人 marketplace 文件 `~/.agents/plugins/marketplace.json` 中加入插件条目。新建文件时可以使用下面的完整示例；如果该文件已经存在，只需要把 `zyz-worker` 这一项追加到 `plugins` 数组中。

```json
{
  "name": "personal",
  "interface": {
    "displayName": "Personal"
  },
  "plugins": [
    {
      "name": "zyz-worker",
      "source": {
        "source": "local",
        "path": "./plugins/zyz-worker"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
```

完成后，在 Codex 的插件界面中搜索并安装 `zyz-worker`。如果插件没有立即出现，重启或刷新 Codex 后再检查插件列表。

安装后，`execute-task` Skill 会通过 `skills/execute-task/SKILL.md` 生效。

### Claude Code

`zyz-worker` 是符合 Claude Code 插件规范的项目，可以作为插件被加载，也可以作为项目直接使用。

#### 方式 1：作为插件加载（推荐用于多项目复用）

最快的方式是使用 `--plugin-dir` 直接加载本地 checkout：

```bash
git clone https://github.com/somePeopleFireAndWood/zyz-worker.git ~/plugins/zyz-worker
claude --plugin-dir ~/plugins/zyz-worker
```

进入 Claude Code 后运行：

```text
/zyz-worker:execute-task <你的开发任务描述>
```

`/zyz-worker:code-development` 仍然可用，作为别名调起同一套工作流。

也可以一次加载多个插件，比如和 superpowers 一起使用：

```bash
claude --plugin-dir ~/plugins/zyz-worker --plugin-dir ~/plugins/superpowers
```

如果希望持久启用（无需每次加 `--plugin-dir`），可以将本仓库声明为本地 marketplace 并通过 `/plugin` 安装。具体步骤参考 [Claude Code 插件文档](https://code.claude.com/docs/en/plugins)。

#### 方式 2：作为项目直接使用

在本仓库内启动 Claude Code，会通过 `CLAUDE.md`、`.claude/agents`、`.claude/commands` 直接生效（后两者是指向根级 `agents/`、`commands/` 的符号链接）：

```bash
git clone https://github.com/somePeopleFireAndWood/zyz-worker.git
cd zyz-worker
claude
```

然后运行：

```text
/execute-task <你的开发任务描述>
```

`/code-development` 仍然可用，作为别名调起同一套工作流。

#### 方式 3：复制到目标项目（不推荐）

如果只想在某个目标项目中使用这套工作流，可以复制以下内容到目标项目根：

```text
CLAUDE.md
.claude/agents/
.claude/commands/
skills/execute-task/
subagents/
```

注意：复制方式不再共享后续更新，建议优先选择方式 1。

#### 关于主 Agent 与 SubAgent

主 agent 不是 Claude Code SubAgent。主 agent 是当前与用户对话的 Agent 在执行 `/execute-task`（或 `/zyz-worker:execute-task`，以及别名 `/code-development` / `/zyz-worker:code-development`）时采用的主控提示词；真正注册为 Claude Code SubAgent 的是 `agents/` 下的 `implementation-agent`、`test-agent` 和 `review-agent`。

## 初步概念

`zyz-worker` 计划模拟一个小型 Agent Team，用于辅助软件交付。当用户给出一个已经确认的开发任务后，插件应帮助 Agent 产出从需求到测试所需的中间结果，并推动任务向完成状态前进。

当前概念流程如下：

```text
已确认任务
  -> 产品需求拆解
  -> 技术实现设计
  -> 实现
  -> 测试验证
  -> 完成总结
```

## 仓库结构

```text
.
├── .claude-plugin/
│   └── plugin.json
├── .codex-plugin/
│   └── plugin.json
├── .claude/
│   ├── agents/   -> ../agents   (symlink)
│   └── commands/ -> ../commands (symlink)
├── agents/
│   ├── implementation-agent.md
│   ├── review-agent.md
│   └── test-agent.md
├── commands/
│   ├── execute-task.md
│   ├── code-development.md
│   └── orchestrate-tasks.md
├── assets/
│   └── README.md
├── docs/
│   ├── conventions/
│   │   ├── long-running-state.md
│   │   └── project-structure.md
│   └── design/
│       ├── execute-task-skill-design.md
│       └── initial-design.md
├── hooks/
│   └── README.md
├── scripts/
│   ├── README.md
│   ├── orch-scan-tasks.sh
│   ├── orch-spawn-worker.sh
│   ├── orch-reuse-worker.sh
│   ├── orch-check-worker.sh
│   ├── orch-heartbeat-daemon.sh
│   ├── orch-cleanup-worker.sh
│   ├── orch-merge.sh
│   └── orch-merge-and-cleanup.sh
├── skills/
│   ├── README.md
│   ├── execute-task/
│   │   ├── SKILL.md
│   │   ├── prompts/
│   │   │   └── main-agent.md
│   │   └── templates/
│   │       ├── design-doc.md
│   │       ├── final-report.md
│   │       ├── review-report.md
│   │       └── task-status.md
│   ├── orchestration-scheduling-task/
│   │   ├── SKILL.md
│   │   ├── prompts/
│   │   │   └── main-agent.md
│   │   └── templates/
│   │       ├── master-list-task-entry.md
│   │       ├── worker-status.md
│   │       └── question-answer.md
│   └── git-worktree/
│       └── SKILL.md
├── subagents/
│   ├── README.md
│   ├── implementation-agent.md
│   ├── review-agent.md
│   └── test-agent.md
├── CLAUDE.md
├── LICENSE
└── README.md
```

## 目录约定

第一版保持轻量结构，不提前引入运行时。约定如下：

- `.claude-plugin/` 保存 Claude Code 插件清单。
- `.codex-plugin/` 保存 Codex 插件声明。
- `agents/` 保存 Claude Code 插件级 SubAgent 定义。
- `commands/` 保存 Claude Code 插件级 slash command；引用插件内资源时使用 `${CLAUDE_PLUGIN_ROOT}/...`。例如 `commands/execute-task.md`。
- `.claude/agents/` 与 `.claude/commands/` 是指向根级目录的符号链接，便于以项目模式直接使用本仓库。
- `skills/` 保存可被两端共用的能力，每个 Skill 独立一个目录。
- `skills/<skill-name>/references/` 保存按需加载的参考资料。
- `skills/<skill-name>/prompts/` 保存当前 Skill 内部使用的主控提示词或辅助提示词。
- `skills/<skill-name>/templates/` 保存可复用的输出模板。
- `subagents/` 保存可被主控 Agent 调度的提示词式子角色定义；当前不实现真实 SubAgent 运行时。
- `hooks/` 预留给后续生命周期自动化。
- `scripts/` 保存本仓库的校验、打包、测试等自动化脚本。
- `docs/conventions/` 保存跨目录的工程约定。

多端清单是关键：Claude Code 通过 `.claude-plugin/plugin.json` 识别本仓库，Codex 通过 `.codex-plugin/plugin.json` 识别本仓库，两端共享根级的 `skills/` 与 `subagents/`。

## 后续开发方向

本项目会保持小步演进。后续可能补充：

- `skills/` 下的具体工作流说明
- 用于仓库检查、验证和自动化的脚本
- 产品需求拆解文档模板
- 技术实现设计文档模板
- 如有明确需要，再增加 hooks、MCP server 或 app manifest
