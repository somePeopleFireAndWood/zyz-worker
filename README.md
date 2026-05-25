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

- 插件声明文件位于 `.codex-plugin/plugin.json`
- 占位 Skill 位于 `skills/zyz-worker/SKILL.md`
- 代码开发 Skill 位于 `skills/code-development/SKILL.md`
- 代码开发主控提示词位于 `skills/code-development/prompts/main-agent.md`
- 提示词式 SubAgent 定义位于 `subagents/`
- 初始设计占位文档位于 `docs/design/initial-design.md`
- 代码开发 Skill 设计文档位于 `docs/design/code-development-skill-design.md`
- 工程结构约定位于 `docs/conventions/project-structure.md`
- 暂未实现 hooks、脚本、MCP server 或真实 SubAgent 运行时

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
├── .codex-plugin/
│   └── plugin.json
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
├── LICENSE
└── README.md
```

## 目录约定

第一版保持轻量结构，不提前引入运行时。约定如下：

- `.codex-plugin/` 保存 Codex 插件声明。
- `skills/` 保存可被 Agent 加载的能力，每个 Skill 独立一个目录。
- `skills/<skill-name>/references/` 保存按需加载的参考资料。
- `skills/<skill-name>/prompts/` 保存当前 Skill 内部使用的主控提示词或辅助提示词。
- `skills/<skill-name>/templates/` 保存可复用的输出模板。
- `subagents/` 保存可被主控 Agent 调度的提示词式子角色定义；当前不实现真实 SubAgent 运行时。
- `hooks/` 预留给后续生命周期自动化。
- `scripts/` 保存本仓库的校验、打包、测试等自动化脚本。
- `docs/conventions/` 保存跨目录的工程约定。

Codex 侧当前通过 `.codex-plugin/plugin.json` 表达。Claude Code 侧先在 Skill、Subagent 或 Hook 文档中记录兼容说明，等具体发布/加载方式明确后再增加专门配置。

## 后续开发方向

本项目会保持小步演进。后续可能补充：

- `skills/` 下的具体工作流说明
- 用于仓库检查、验证和自动化的脚本
- 产品需求拆解文档模板
- 技术实现设计文档模板
- 如有明确需要，再增加 hooks、MCP server 或 app manifest
