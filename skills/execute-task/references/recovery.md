# 恢复与续做

## 恢复进行中的任务

接手一个已经在进行的任务时（会话冻结或重启过），`status.md` 只在有人写的时候才前进，可能已经过时。先和会自己前进的来源核对：

1. 任务分支的 `git log` / `git status`：lane 标着 `Coded: false` 却已有实现它的提交，是状态文件落后。
2. `lanes/<id>.md`、`decisions.md`、`log/`，以及 `review-round.sh status`。
3. 角色是否还活着：ListAgents、后台任务列表。还活着的不重新派发，否则两个 agent 会写同一批文件。

有出入时把核对后的状态写回 `status.md`，标明哪些是按代码重建的。会话恢复后重新运行 `task-pointer.sh arm`。

## 从会话记录恢复未提交的工作

从未提交过的内容不在 reflog、stash 或 `git fsck` 里，但 agent 写过的每一次 Write / Edit 都逐字留在会话记录里：

```text
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl                     主 agent
~/.claude/projects/<encoded-cwd>/<session-id>/subagents/agent-*.jsonl   subagent
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl                           Codex
```

Write 的 `input.content` 是完整文件，Edit 带 `input.old_string` / `input.new_string`。找到写过丢失内容的那个 agent，把它对这些文件的 Write / Edit 按原顺序重放。

## 长期运行工作

角色卡住、中断或长时间没有响应时，续做而不是重做：

1. **盘点**：从磁盘（`git status`、资源租约表）列出它已经写了哪些文件、建了哪些测试数据、占了哪些端口。
2. **续做**：把盘点结果作为起点发回，写明"继续，不要重新创建以下产物"。具名的 lane 用 SendMessage，它从自己的会话记录接着做。
3. **清理**：被中断的运行可能留下写了一半的测试数据，重跑前先清掉。

每次恢复在 `<task-dir>/log/restarts.md` 追加一行。另见 [docs/conventions/long-running-state.md](../../../docs/conventions/long-running-state.md)。

## 恢复卡住的角色：不拿范围换交付

- 可以缩小每一轮的输出量：分成带标签的几步、每步落盘、先做一部分。不缩小总的交付：分步时写明共几步，把计划记进 `log/restarts.md`，每一步都收齐。
- L5 派发范围守卫会拒绝给交付设上限的派发（"只报最重要的 3 条""只给总体结论""只报阻断项"之类）。被拒绝时按完整范围分步重派。
- **增量复审不属于缩范围。** 它的范围由评审点规则定义，派发带 `mode=incremental` 标记，L5 放行。
- 分步之后仍然做不完时告诉用户哪些做了、哪些没做，不把部分结果记为完成。
