---
task-id: <task-id>
spawn-iso: <iso>                   # spawn 写入本文件时的 ISO 时间戳
tmux-session: <session name>      # 例如 zyz-task-<task-id>
tmux-window-id: <e.g. @4>         # spawn 时的快照；如果用户手动增删 window，
                                  # 可能会过时
tmux-pane-id: <e.g. %6>           # spawn 时的快照；可能会过时
shell-pid: <int>                  # pane shell 的 pid；是所选 agent 进程的父进程
worktree: <absolute path>         # 仓库 1（主仓库）的 worktree = tmux pane 的 cwd。多仓库任务
                                  # 另加 worktree-2、worktree-3、…（每个仓库一个）；见下面的
                                  # 编号字段组。单仓库任务只有这一行。
source-repo: <absolute path>      # 仓库 1（主仓库）的项目 git 工作树，worktree 从它切出
branch: <branch name>             # 仓库 1（主仓库）的任务分支
base: <base branch>               # 仓库 1（主仓库）的 base，任务分支从它创建
# --- 可选的编号字段组（仅多仓库；每个额外仓库一个连续的块，从 2 开始）---
# worktree-2: <absolute path>     # 仓库 2 的 worktree
# source-repo-2: <absolute path>  # 仓库 2 的项目 git 工作树
# branch-2: <branch name>         # 仓库 2 的任务分支（完全解析——绝不留空）
# base-2: <base branch>           # 仓库 2 的 base
# …worktree-3/source-repo-3/branch-3/base-3，依此类推。仅当任务跨越 >1 个仓库时才写入。
# 编号字段组的所有值都是 spawn/reuse 计算出的完全解析值（已套用默认值），
# 因为生命周期脚本（merge/cleanup）把本文件当作权威的仓库集合来读取。
plugin-root: <absolute path>      # resume 时作为 `claude --plugin-dir` 传入
encoded-cwd: <claude-projects-dir form of pwd -P of worktree>
                                  # "/" 和 "." 都替换为 "-"，再把连续的
                                  # "-" 压缩成一个；与 ~/.claude/projects/<dir> 对应。
                                  # 仅用于诊断——transcript 是通过
                                  # session-id 发现的（见下面关于 Phase-2 的说明）。
agent-runtime: <claude|codex>     # Phase-1；所选的 worker 运行时
worker-runtime-args: <cli args or empty> # Phase-1；特定于运行时的配置隔离参数
worker-mcp-args: <cli args or empty>     # worker-runtime-args 的旧别名
                                  # Phase-1；来自 orch-worker-mcp-args.sh 的 MCP 继承快照
                                  # （ZYZ_WORKER_MCP 策略），在搭建容器时
                                  # 取一次。L2 driver 把它原样追加到
                                  # `claude` 启动命令后面，Phase-2 `## Recovery`
                                  # 中的 --resume 命令也会嵌入它——这样崩溃后
                                  # resume 的 worker 仍保持相同的 MCP 策略，而不会
                                  # 悄悄地重新继承主机的全部 mcpServers。
                                  # `none`：Claude 渲染为 --strict-mcp-config；
                                  # Codex 针对派发时的 MCP server 快照
                                  # 渲染出显式的 enabled=false 覆盖项。
                                  # `inherit` 渲染为空。
reuse-from:                       # Phase-1；空 = 普通 spawn（orch-spawn-worker.sh），
                                  # 非空 = 本任务所复用容器的旧 task-id
                                  # （orch-reuse-worker.sh）。是新任务主条目中
                                  # `reuse-from` 的快照；主条目才是权威
                                  # 来源——这里只是派生的副本，供
                                  # driver 和崩溃恢复使用。
reuse-scope:                      # Phase-1；worktree | tmux | both |（普通 spawn 时为空）
reuse-claude-effective:           # Phase-1；true | false | n/a（worktree scope 下为 n/a，此时
                                  # 总是新的 claude）。决定下面感知复用的
                                  # `## Recovery` 正文，以及 L2 的 reuse-dispatch 分支。
reuse-agent-effective:            # 通用的权威别名；值与上一项相同
heartbeat-window-id:              # Phase-1；同一 session 中新开 window 里那个心跳守护进程的
                                  # tmux window id（仅同一 claude 复用）；普通 spawn /
                                  # 新 session 复用时为空。仅用于诊断——清理会杀掉
                                  # 整个 session，而 orch-heartbeat-daemon.sh 的
                                  # `tmux has-session` watchdog 会把这个 window 的守护进程
                                  # 一并拆掉。不要根据这个字段推导 kill 逻辑。
agent-pid:                        # Phase-2；由 orch-check-worker.sh 填入
agent-session-id:                 # Phase-2；由 orch-check-worker.sh 填入
claude-pid:                       # Phase-2；agent-pid 的旧别名
claude-session-id:                # Phase-2；agent-session-id 的旧别名
transcript-path:                  # Phase-2；由 orch-check-worker.sh 填入
first-seen-iso:                   # Phase-2；在上面三项首次全部填好时设置
---

# Dispatch Info

<!--
  dispatch.md 模板
  ================

  写入方（Phase-1）：orch-spawn-worker.sh（普通 spawn）或 orch-reuse-worker.sh
  （容器复用），作为预检的**最后**一步写入。两者都只搭建容器——
  绝不启动 claude（L2 orch-driver-agent 是唯一的启动者）。Phase-1 字段是
  确定性的，且绝不为空：
    task-id, spawn-iso, tmux-session, tmux-window-id, tmux-pane-id, shell-pid,
    worktree, source-repo, branch, base, plugin-root, encoded-cwd.
  `worker-mcp-args` 也属于 Phase-1，但**可以**合法地为空（这正是
  ZYZ_WORKER_MCP=inherit 渲染出来的形式）。
  对于多仓库任务，写入方**还会**输出编号字段组
    worktree-N, source-repo-N, branch-N, base-N   （N = 2..仓库数），
  每个额外仓库一个连续的块，值都是完全解析后的值（已套用默认值）。
  上面不带编号的 worktree/source-repo/branch/base 是仓库 1（主仓库）；
  主 worktree 就是 pane 的 cwd。单仓库任务完全省略编号字段组。这些编号字段是
  生命周期脚本（merge/cleanup/reuse）读回的权威仓库集合——因此 check 的
  Phase-2 重写**必须**在固定键列表之外一并保留它们。
  四个复用字段（reuse-from, reuse-scope, reuse-claude-effective,
  heartbeat-window-id）**同样**属于 Phase-1：普通 spawn 时为空，复用时填入。
  两个写入方输出相同的字段集，因此 check 的 Phase-2 重写只需保留
  一份固定的键列表。
  因此 dispatch.md 存在，意味着"spawn/reuse 已把预检完整跑完"
  （或者是本功能之前的旧 spawn）。不存在，则意味着本功能之前的旧 spawn，
  或在预检中途崩溃。

  写入方（Phase-2）：orch-check-worker.sh，在后续轮询中惰性写入。它填入：
    claude-pid          — shell-pid 下最新的、名为 `claude` 的直接子进程
    claude-session-id   — ~/.claude/sessions/<claude-pid>.json 中的 .sessionId
    transcript-path     — ~/.claude/projects/<dir>/<claude-session-id>.jsonl，
                          通过 session-id（唯一的 UUID）用
                          `find ~/.claude/projects -name "<sid>.jsonl"` 发现，
                          **而不是**根据 encoded-cwd 重建 <dir>
                          （仅在该文件确实存在之后才填）
    first-seen-iso      — 在上面三项首次全部填好的那次轮询中设置
  在 claude 完成注册、且第一次 LLM 往返写出 transcript 之前，这些字段一直为空。
  某个 Phase-2 字段一旦非空，之后的轮询就不会再改写它（幂等）。
  用户可以清空 Phase-2 字段来强制重新绑定。

  读取方：编排器（以及做崩溃恢复的人工运维者——
  `cat`/`less` 这个文件即可看到下面 `## Recovery` 里的命令）。

  原子写入（tmpfile + rename）。绝不原地编辑。

  生命周期：由 orch-cleanup-worker.sh / orch-merge-and-cleanup.sh 归档（而非删除），
  作为把 runtime/<task-id>/ 整体移入 runtime/.archive/<task-id>-<ts>/
  的一部分。

  参见 `docs/conventions/long-running-state.md` 以及编排 SKILL.md 的
  `## 崩溃恢复` 一节。
-->

## Recovery

<!--
  由 orch-check-worker.sh 在三个 Phase-2 字段首次全部填好时写入。
  在此之前，这里保留 spawn/reuse 写入的占位文本。生成的正文
  感知复用（分三种情况），依据存储的 reuse-from / reuse-claude-effective：
  - 普通 spawn（reuse-from 为空）以及拥有独立 session 的复用
    （reuse-claude-effective 为 false 或 n/a）：给出具体的 `tmux attach -t <session>`
    和 `cd <worktree> && claude --resume <claude-session-id> --plugin-dir <plugin-root>`
    恢复命令。这里的 `cd <worktree>` 始终是**主** worktree
    （仓库 1 = pane 的 cwd）；多仓库 worker 从这里访问它的其他 worktree
    （它们由同一个 claude 统一管理）；
  - 同一 claude 复用（reuse-from 已设置**且** reuse-claude-effective=true）：
    **只含 attach** 的正文——只有 `tmux attach -t <session>`，并明确警告
    **不要**运行独立的 `claude --resume`（该 session-id 是新旧任务共享的
    session；从两个 dispatch.md 文件分别 resume 它是一个陷阱）。
  所有 <…> 占位符都会被替换为真实值；渲染后的正文中不会残留尖括号。
-->

（等待 claude 启动；在 claude 已注册、且第一次 LLM 往返已生成会话记录后的首次轮询中，由 orch-check-worker.sh 填写本节）
