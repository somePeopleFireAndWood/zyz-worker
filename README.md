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
- 初始设计占位文档位于 `docs/design/initial-design.md`
- 暂未实现真实功能

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
├── docs/
│   └── design/
│       └── initial-design.md
├── skills/
│   └── zyz-worker/
│       └── SKILL.md
├── LICENSE
└── README.md
```

## 后续开发方向

本项目会保持小步演进。后续可能补充：

- `skills/` 下的具体工作流说明
- 用于仓库检查、验证和自动化的脚本
- 产品需求拆解文档模板
- 技术实现设计文档模板
- 如有明确需要，再增加 hooks、MCP server 或 app manifest
