# zyz-worker

`zyz-worker` 是一个面向 Codex、Claude Code 等 Agent CLI 的插件工程。

这个插件的目标是帮助用户完成一条完整的工作链路。当前版本先聚焦一个场景：**完成一个已经确认的代码开发任务**。

规划中的基础流程是：

1. 产品需求拆解
2. 技术实现设计文档
3. 编码实现
4. 测试验证

当前仓库只是初始化脚手架。具体的工作流、提示词、脚本、Agent 分工和运行行为会在后续版本中继续补充。

## 当前状态

- Claude Code 插件清单位于 `.claude-plugin/plugin.json`
- Codex 插件清单位于 `.codex-plugin/plugin.json`
- Claude Code 项目说明位于 `CLAUDE.md`
- Slash command 位于 `commands/code-development.md`
- SubAgent 位于 `agents/`
- `.claude/agents` 与 `.claude/commands` 是指向根级目录的符号链接，方便在本仓库内直接以项目模式使用 Claude Code
- 占位 Skill 位于 `skills/zyz-worker/SKILL.md`
- 代码开发 Skill 位于 `skills/code-development/SKILL.md`
- 代码开发主控提示词位于 `skills/code-development/prompts/main-agent.md`
- 提示词式 SubAgent 定义位于 `subagents/`
- 初始设计占位文档位于 `docs/design/initial-design.md`
- 代码开发 Skill 设计文档位于 `docs/design/code-development-skill-design.md`
- 工程结构约定位于 `docs/conventions/project-structure.md`
- 暂未实现 hooks、脚本、MCP server 或真实 SubAgent 运行时

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

安装后，`code-development` Skill 会通过 `skills/code-development/SKILL.md` 生效。

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
/zyz-worker:code-development <你的开发任务描述>
```

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
/code-development <你的开发任务描述>
```

#### 方式 3：复制到目标项目（不推荐）

如果只想在某个目标项目中使用这套工作流，可以复制以下内容到目标项目根：

```text
CLAUDE.md
.claude/agents/
.claude/commands/
skills/code-development/
subagents/
```

注意：复制方式不再共享后续更新，建议优先选择方式 1。

#### 关于主 Agent 与 SubAgent

主 agent 不是 Claude Code SubAgent。主 agent 是当前与用户对话的 Agent 在执行 `/code-development`（或 `/zyz-worker:code-development`）时采用的主控提示词；真正注册为 Claude Code SubAgent 的是 `agents/` 下的 `coding-agent`、`test-agent` 和 `review-agent`。

## 初步概念

`zyz-worker` 计划模拟一个小型 Agent Team，用于辅助软件交付。当用户给出一个已经确认的开发任务后，插件应帮助 Agent 产出从需求到测试所需的中间结果，并推动任务向完成状态前进。

当前概念流程如下：

```text
已确认任务
  -> 产品需求拆解
  -> 技术实现设计
  -> 编码实现
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
│   ├── coding-agent.md
│   ├── review-agent.md
│   └── test-agent.md
├── commands/
│   └── code-development.md
├── assets/
│   └── README.md
├── docs/
│   ├── conventions/
│   │   └── project-structure.md
│   └── design/
│       ├── code-development-skill-design.md
│       └── initial-design.md
├── hooks/
│   └── README.md
├── scripts/
│   └── README.md
├── skills/
│   ├── README.md
│   ├── code-development/
│   │   ├── SKILL.md
│   │   ├── prompts/
│   │   │   └── main-agent.md
│   │   └── templates/
│   │       ├── design-doc.md
│   │       ├── final-report.md
│   │       ├── review-report.md
│   │       └── task-status.md
│   └── zyz-worker/
│       ├── SKILL.md
│       ├── references/
│       │   └── README.md
│       └── templates/
│           └── README.md
├── subagents/
│   ├── README.md
│   ├── coding-agent.md
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
- `commands/` 保存 Claude Code 插件级 slash command；引用插件内资源时使用 `${CLAUDE_PLUGIN_ROOT}/...`。
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
