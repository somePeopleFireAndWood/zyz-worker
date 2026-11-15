---
task-id: <task-id>
phase: design                     # design | implementation | testing | review | delivery | awaiting-confirmation | done | error
                                  # `phase` 可以在 design/implementation/testing/review/delivery/awaiting-confirmation 之间回滚，
                                  # 以反映真实的迭代（例如用户评审一个处于 awaiting-confirmation 的 worker 时要求
                                  # 修改 → 回滚到 implementation）。唯一不可逆的 phase 是 `done`：一旦
                                  # 写入，它就是吸收性终态。`done` 表示用户确认了交付——
                                  # worker 只有在用户明确确认之后才写入它，绝不自主写入。
                                  # `awaiting-confirmation`（自我声明已完成，等待确认）是可逆的。
phase-since: <iso>                # 进入当前 `phase` 时的 ISO 时间戳
wait-state: none                  # none | waiting-user | waiting-subagent | waiting-resource
                                  # `wait-state` 与 `phase` 相互正交。
waiting-reason:                   # 自由文本；只有 `wait-state != none` 时才非空
expected-resume-by:               # ISO 时间戳；只有 `wait-state != none` 时才非空；
                                  # 编排器把它用作软超时的启发式依据
last-flush: <iso>                 # 本次刷写的 ISO 时间戳
---

# Worker Status

<!--
  worker-status.md 模板
  =====================

  写入方：在本任务 tmux session 中运行 `execute-task` 的、选定的 Claude Code 或 Codex worker。
  读取方：编排器。

  原子写入（tmpfile + rename）。绝不原地编辑。

  刷写触发点（依据设计规格 §A.5）：
    1. 进入新的 `phase`（包括 `phase=awaiting-confirmation`、`phase=done` 和 `phase=error`）。
    2. 把 `wait-state` 从 `none` 设为非 `none` 值（挂起）。
    3. 把 `wait-state` 设回 `none`（恢复）。
    4. 派发 SubAgent 之前。
    5. 收到 SubAgent 结果之后（无论成功还是失败）。

  编排器只能看到本文件写了什么。上下文里的记忆
  不算数。参见 `docs/conventions/long-running-state.md`。

  复用说明：在**被复用的**容器上启动的 worker（reuse-dispatch）可能会在
  pane 中收到一个 in-band 运行时配置块，它会**覆盖**启动时的
  ZYZ_* 环境变量。存在该配置块时，本文件的权威路径是配置块中的
  `worker-status-file:`（位于 runtime/<new-task-id>/ 下），而不是由
  继承来的 ZYZ_WORKER_STATUS_FILE 推导出的任何路径。这样的 worker 还会
  在每次刷写时 `touch` 一下配置块中的 `heartbeat-file`。参见 execute-task 的
  `## 编排模式`。
-->

## Current Activity

<!--
  用一到三句话描述 worker 此刻正在做什么。
-->

## Last Output Summary

<!--
  用五到十行总结最近一轮工具调用 / SubAgent 报告。
  当 `phase=error` 时，把失败摘要复制到这里——编排器在把任务
  转为 `blocked` 时，会把本节摘录到主条目的 `## Notes` 中。
-->

## Next Action

<!--
  一句话：不在等待时，worker 接下来要做什么。
-->
