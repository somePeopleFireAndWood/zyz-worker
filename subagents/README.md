# Subagents

本目录存放纯提示词形式的 subagent 定义，涵盖由 execute-task 主 agent 派发的各个角色，外加编排技能的 L2 驱动角色。

这些文件并不实现任何运行时、钩子、脚本或后台服务。它们是角色提示词，任何支持 subagent 的 agent 环境都可以使用；在没有真正的 subagent 运行环境时，也可以把它们复制进角色交接内容中。

当前角色：

- `implementation-agent.md`
- `test-agent.md`
- `review-agent.md`
- `orch-driver-agent.md`——orchestration-scheduling-task 技能的 L2 驱动角色，每个 worker
  对应一个，负责驱动其 pane（不是 execute-task 的角色；由编排器派发，而不是由
  execute-task 主 agent 派发）

每个文件都镜像 `agents/` 中对应的规范 Claude Code subagent 定义。
两份副本的正文保持逐字节相同（唯一有意保留的差异是 `agents/` 的
YAML frontmatter 和角色介绍那一行），因此对一边的修改必须同步到另一边。

主 agent 不是 subagent。它的控制器提示词位于 `skills/execute-task/prompts/main-agent.md`，适用于当前面向用户的对话 agent。
