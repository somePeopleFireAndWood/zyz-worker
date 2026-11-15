---
task-id: <task-id>                 # 不可变；本 driver 状态所属的 worker
last-driver-iso: <iso>             # L2 driver 上次运行的 ISO 时间戳
driver-intent: first-dispatch      # first-dispatch | intervene | relay-confirmation | reuse-dispatch
                                   # 注意：这里持久化的 frontmatter 键是 `driver-intent`；
                                   # 而 L1->L2 派发输入中承载相同取值的字段
                                   # 名为 `intent`（例如 intent=first-dispatch）。这种两个名字
                                   # 分立的做法（输入用 `intent`，持久化用 `driver-intent`）是
                                   # 有意为之——不要为了一致而把其中任何一个改名。
                                   # `relay-confirmation` 由 L1 的闸门步骤派发，用于把
                                   # 用户确认转交进 worker pane（让 worker
                                   # 推进到 phase=done）；L1 读取这个值来保证转交
                                   # 幂等（每次确认至多转交一次）。
                                   # `reuse-dispatch` 由 L1 的派发步骤针对容器
                                   # 被复用的 worker（主条目设置了 `reuse-from`）派发；
                                   # 它是 first-dispatch 的变体——同一 claude（不开新 claude）、
                                   # 重启 claude，或新 session——详见 driver agent。
claude-started: false              # true | false；就绪探测一通过就立即设为 true
                                   # （不要等到 tick 结束）
agent-started: false               # 通用的权威别名，适用于 Claude 或 Codex
needs-user: false                  # true | false；只有当该 worker 的
                                   # worker-status.md 中 wait-state=waiting-user 时才设为 true。
                                   # waiting-subagent / waiting-resource 不设（它们是正常的
                                   # 内部等待——不设 needs-user，也不 notify）。
needs-user-window:                 # tmux session 名；只有 needs-user=true 时才非空
needs-attention: false             # true | false；L2 检测到 worker 卡住/异常
                                   # （包括 `/execute-task` 被以 Unknown command 拒绝）
attention-reason:                  # 自由文本；只有 needs-attention=true 时才非空
last-summary:                      # L2 返回给 L1 的一行摘要（持久化副本）
---

# Driver State

<!--
  monitor.md 模板
  ===============

  写入方：L2 orch-driver-agent（一个短生命周期、按需派发的 subagent，由 L1
  编排器派发去驱动**一个** worker 的 tmux pane——first-dispatch、
  intervene 或 relay-confirmation）。它用 Bash 原子写入本文件（`cat > tmp && mv -f`，
  与其他辅助脚本相同——不需要 Edit/Write），并增量刷写：
  成功启动之后、每次 send-keys 介入之后，以及观察结束时。
  不是只在 tick 结束时写一次。

  读取方：L1 编排器。L1 读取 monitor.md，把每个 worker 的
  整体状态投影到它的主条目中。

  文件名**有意**保持为 `monitor.md`。agent 之所以叫"driver"
  （orch-driver-agent），是因为在混合架构中 L2 只做繁重的
  pane 驱动工作，而不是纯粹的监控——但**文件**有意保留 `monitor.md`
  这个名字，以免测试/模板中的路径引用随之变动。**不要**
  把它改名为 driver.md。

  L2 **只**写这一个文件。它**绝不**写 worker-status.md（那个文件归
  L3——即 execute-task worker——所有，L3 每次刷写都会原子地重新渲染它，
  所以 L2 在那里写的任何内容都会被覆盖）。L2 也绝不写
  主条目（归 L1 所有）。

  L1 **绝不**写 monitor.md。L1 只读它。特别地，notify 的
  判断依据是**实时**轮询得到的 wait-state（来自 orch-check-worker.sh），
  **而不是**本文件里可能已经过期的 `needs-user` 标志——所以用户已经回答之后
  这里残留的过期 `needs-user=true` 是无害的（它只是 L2 的
  草稿记录；下一次 L2 派发会从新的轮询结果重新推导它）。这条
  单一写入方规则（L2 写，L1 读）让归属边界保持清晰，
  也不存在写入竞争。

  原子写入（tmpfile + rename）。绝不原地编辑。

  生命周期：与 runtime/<task-id>/ 下的其他内容一起，
  由 orch-cleanup-worker.sh / orch-merge-and-cleanup.sh 归档（而非删除），
  这两个脚本会把 runtime/<task-id>/ 整体移入 runtime/.archive/<task-id>-<ts>/。

  L1/L2/L3 分层架构的边界，参见 `docs/conventions/long-running-state.md`
  以及编排 SKILL.md。
-->

## Last Action

<!--
  L2 **本次**运行做了什么：启动了 claude / 点掉了启动确认页
  （信任文件夹、bypass 风险）/ send-keys 介入 / 仅观察。
  只记录 driver 层面的整体动作——**不**记录任何 L3 内部执行细节。
-->

## Notes

<!--
  L2 追加的简短观察。只记整体状态——**不**记 L3 内部细节
  （不记设计文档 / subtask / 实现 / 测试 / 评审 / question.md 正文）。
-->
