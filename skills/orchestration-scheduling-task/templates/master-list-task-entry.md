---
task-id: <task-id>                # 不可变；与去掉 `.md` 后的文件名一致
agent-runtime:                    # 可选，claude | codex；空 = 由主机自动检测
project: <project-name>           # 用户维护；仅作标签；省略时默认 = basename(主 source-repo)
source-repo: ~/workspace/<repo>   # 仓库 1 = 主仓库；必填；支持 ~/；绝对路径或 ~/ 形式。
                                  # 多仓库任务另加连续的 source-repo-2、source-repo-3、…
                                  # （见下面的"多仓库 schema"注释）。单仓库：只有这一行。
state: not-analyzed               # 用户可写：   not-analyzed | blocked | ready | completed
                                  # 仅编排器写： in-progress | paused | awaiting-user-confirmation
                                  # orch-scan-tasks.sh 接受全部 7 个值；
                                  # 用户只应手写前四个之一。
priority: normal                  # low | normal | high
branch: task/<task-id>            # 主仓库的分支；默认 task/<task-id>；需要时可覆盖
base: main                        # 主仓库的合并目标分支；默认 main；需要时可覆盖
worktree: ~/.zyz-worker/worktrees/<project>/task/<task-id>
                                  # 主仓库的 worktree；可选。单仓库的默认值就是这个路径；
                                  # 多仓库默认采用兄弟目录布局（见下文）。路径不得
                                  # 包含冒号 ':'（worktree 集合会用冒号拼接后交给 worker）。
tmux-session: zyz-task-<task-id>  # 任务级，单一值（每个任务一个 tmux session，多仓库也一样）
reuse-from:                       # 可选；本清单中某个任务的 task-id，复用它的容器
                                  # （tmux session 和/或 worktree 集合）。存在 => 这是一个
                                  # 复用任务：由 orch-reuse-worker.sh 关联旧容器，
                                  # 而不是由 orch-spawn-worker.sh 搭建新容器。
                                  # reuse-from 指向的任务必须是 `state: completed`（复用只做
                                  # 关联；绝不推进旧任务）。空 => 普通 spawn。
                                  # 复用总是移交旧任务的整个 worktree 集合（所有
                                  # 仓库）——不存在只复用集合中某一个仓库的部分复用。
reuse-scope: both                 # worktree | tmux | both（设置了 reuse-from 时必填；默认 both）
                                  # worktree = 复用旧 worktree 集合（所有仓库），新 tmux session + 新 claude。
                                  # tmux     = 复用旧 tmux session；新任务运行在旧 pane 的
                                  #            主 worktree 中（cwd 不可改变，因此在 tmux scope 下
                                  #            上面的 `worktree:` 字段会被忽略——要显式复用旧
                                  #            worktree 集合请用 `both`，要全新的 worktree 集合
                                  #            请用普通 spawn）。
                                  # both     = 同时复用旧 worktree 集合和旧 tmux session。
reuse-claude: true                # true（默认）| false；只在复用 tmux（tmux/both）时
                                  # 有意义。true = 复用同一个正在运行的 claude 进程（不
                                  # 重启；新任务的运行时通过 in-band 配置块
                                  # 交给它）。false = 在被复用的 session 中重启 claude。
                                  # worktree scope 下被忽略（总是新的 claude）。
reuse-agent: true                 # 通用的权威写法；reuse-claude 是旧版回退
                                  # 警告：复用任务与 reuse-from 任务共享
                                  # 容器——清理其中任何一个，都会摧毁共享的 session 和
                                  # worktree 集合（所有仓库）。清理前请确保所有共享方都已完成。
blocked-by: []                    # [<task-id>, ...]；用户维护
merged-with: []                   # [<task-id>, ...]；用户维护
deps-tentative: true              # 只有在用户批准分析后，编排器才把它清为 false
last-seen:                        # 仅由编排器写入；每次心跳新鲜时更新
heartbeat-stale-sec: 300          # 可选；按任务覆盖 stale 阈值（秒）
created-at: <yyyy-mm-dd>
updated-at: <yyyy-mm-dd>
---

# <Task Name>

<!--
  master-list-task-entry 模板
  ===========================

  本文件由用户和编排器共同编写。
  - 每个 frontmatter 字段的归属，记载在
    `skills/orchestration-scheduling-task/SKILL.md`（核心规则 + 文件协议）中。
  - `source-repo` 是必填的；编排器可以从任意 cwd 运行
    （包括 `~/`）；每个任务都自带 source-repo（以及可选的
    编号 source-repo-N），因此一份主清单可以跨多个仓库派发 worker
    （按任务、也就是按 worker 隔离）。编排器绝不假定自己的 cwd
    位于任何任务的源仓库之内。
  - 隔离边界：worker 与 worker 之间——任何 worker 都绝不碰另一个
    worker 的 worktree（spawn 通过保持每个 worker 的 worktree 路径集合
    两两不相交来强制执行）。在单个 worker **内部**，该 worker 对自己的
    **所有** worktree（每个仓库一个）拥有完全写权限。"每个 worker 一个
    worktree"**不是**边界；边界在 worker 之间。
  - 编排器通过 tmpfile+rename 写入。
  - 用户在外部编辑器中打开本文件之前，**必须**先 `Ctrl-C` 停掉编排器；
    否则编排器的写入可能与编辑器的保存发生竞争。

  多仓库 schema（扁平的编号键——一个 worker 管理 n 个 worktree）
  ==============================================================
  单个任务可以跨多个仓库。worker 仍然是**一个** tmux session +
  **一个** claude 进程；它只是管理 n 个 git worktree（每个仓库一个）。额外的
  仓库用连续的数字后缀键声明，从 2 开始：

    source-repo:   ~/workspace/tipsy-ab-config       # 仓库 1 = 主仓库（必填）
    source-repo-2: ~/workspace/tipsy-ab-config-sdk   # 仓库 2（可选）
    source-repo-3: ~/workspace/tipsy-ab-config-proto # 仓库 3 …依此类推
    branch:   task/<task-id>    # 主仓库分支；branch-2 / branch-3 … 每个仓库可选
    base:     main              # 主仓库 base；base-2 / base-3 … 每个仓库可选
    worktree: <path>            # 主仓库 worktree；worktree-2 / worktree-3 … 每个仓库可选

  规则：
  - **主仓库**（PRIMARY）= 不带编号的 `source-repo:`。它是仓库 1；它的 worktree 就是
    tmux pane 的 cwd。"哪个仓库是主仓库"通过把它写成不带编号的键来选定
    （默认：第一个）。
  - 编号从 2 开始连续（source-repo-2、source-repo-3、…）。出现空洞
    （例如有 source-repo-3 却没有 source-repo-2）时，spawn 会拒绝
    （exit 5），并给出指明空洞位置的诊断信息。
  - branch-N / base-N / worktree-N 每一项都是**可选的**。默认值：
      branch-N   ← 主仓库的 `branch:` 值（默认所有仓库共用 task/<task-id>；
                   abconfig 的先例 = 两个仓库，同一个分支名）；
      base-N     ← 主仓库的 `base:` 值（默认 main）；
      worktree-N ← 下面的兄弟目录默认布局。
  - project: 仍是任务级的标签；默认 = basename(主 source-repo)。
  - 单仓库条目（只有 `source-repo:`）保持不变——解析、校验、默认值和
    诊断信息都与以前相同（向后兼容）。

  默认 worktree 布局
  ==================
  - 单仓库（不变）：
      ~/.zyz-worker/worktrees/<project>/task/<task-id>
  - 多仓库（新增）：一个任务级的父目录，每个仓库一个子目录（互为兄弟目录）：
      ~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/<repo-name>
    其中 <repo-name> = basename(source-repo-N)。所有仓库共享同一个父目录
    `~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/`，每个
    子目录以对应仓库命名——这就是兄弟目录约定
    （同一父目录，目录名 = 仓库名），它让 `go.work` 中的相对引用
    （`../<repo>`）能够解析。可以用 `worktree-N:` 覆盖任意仓库的路径；一旦
    覆盖，保持兄弟目录约定就是你自己的责任（设计只定义了
    默认布局）。

  约束（spawn 会校验；违反时 exit 5）
  ==================================
  - `worktree` / `worktree-N` 路径**不得**包含冒号 ':'——worktree 集合
    是用冒号拼接的（ZYZ_WORKTREES 环境变量 / reuse-runtime-config 中的 `worktrees:`
    行）。默认布局的路径绝不包含冒号。
  - basename 相同的两个仓库会得到相同的默认 worktree 路径；
    spawn 会拒绝这种情况（两两互异检查，在创建任何 worktree 之前进行），
    并要求你显式设置 `worktree-N:`。

  复用说明：**不存在**部分复用。复用任务会复用一个已完成任务的
  **整个** worktree 集合（所有仓库），绝不会只复用集合中的某一个仓库。如果只想
  共享多仓库容器中的某一个仓库，请改为 spawn 一个全新的 worker，并显式
  设置 `worktree-N:`。
-->

## Description

<!--
  由用户编写。描述用户对这个任务期望达成的目标。如果本节
  为空，编排器会保持 `state: not-analyzed`，并在下面的
  `## Orchestrator Analysis` 中写入 `needs Description`。在本节填写之前，
  编排器**不会**派发 worker。
-->

## Orchestrator Analysis

<!--
  由编排器编写。编排器在这里写下暂定的分析：
  - 这个任务涉及哪个项目 / 哪些仓库
  - 它依赖哪些其他任务
  - 哪些任务可以与它合并
  - 这个任务当前是否可以派发

  在用户把 frontmatter 中的 `deps-tentative` 设为 `false` 之前，
  这些结论都是暂定的。
-->

## Pending Merge Approval

<!--
  worker 报告 `phase=awaiting-confirmation` 之后由编排器编写。编排器
  在这里记录 PR URL 或本地合并命令。

  交付与合并是解耦的：把任务标为完成（`state: completed`）与
  把它的分支合并到 base 是**彼此独立**、各自需要令牌的动作。
  编排器绝不自主发起其中任何一个——每个动作都需要用户
  在本节写入对应的令牌。令牌（路由顺序 merge → confirm → cleanup）：

  - `confirmed` —— 记录用户的确认；编排器把它转交给
    worker（派发一个 L2 `relay-confirmation`），worker 随即推进到 `phase=done`；
    之后编排器再镜像出 `state: completed`（它**不会**直接写
    `completed`）。**不**合并到 base。**不**清理 worktree。这是最常见的
    "完成但不合并"情形。通过 PR 收尾时使用它（见下面的 PR 流程说明）。
  - `merge`（或 `merge: <base>`）—— 把任务分支合并到 base 并 push。**不**
    改变 `state`。**不**清理 worktree。令牌中的 `<base>` 会
    覆盖 frontmatter 的 `base:` 字段（默认 `main`）。对于多仓库
    任务，它会把**每个**仓库的分支合并到该仓库的 base（逐仓库、非原子
    ——参见编排 SKILL.md 的 `## 状态机`）；令牌中的 `<base>` 会
    统一覆盖所有仓库的 base（各仓库各自的 base 通过 `base-N:` 设置）。
  - `approved` —— **旧版**组合路径：合并 + 写入 `state: completed` + 清理
    worktree 集合（所有仓库），原子执行（等价于 `confirmed` + `merge`
    + `cleanup-approved`）。`approved` 会短路：只要它存在，同一 tick 写入的
    `confirmed` / `merge` / `cleanup-approved` 都会被**忽略**
    （不会作为子集合并执行）。
  - `cleanup-approved` —— 授权清理 worktree（在 `confirmed` 之后使用，或
    通过 `## Notes` 用于 stale worker）。与 `confirmed`/`merge` 相互独立。对于多仓库
    任务，会删除整个 worktree 集合（所有仓库）。
  - `rejected: <reason>` —— 把任务退回 `blocked`；原因会被复制到
    `## Notes`。

  注意：`confirmed` 和 `merge` **不会**清理 worktree。如果你希望删除
  worktree，还要再写 `cleanup-approved`（或使用旧版 `approved`）。

  PR 流程：要通过 PR 收尾，先让 worker 到达 `phase=awaiting-confirmation`，
  自己（在 zyz-worker 之外）开 PR、评审并合并，然后在这里写入 `confirmed`
  （**不是** `merge`）。编排器把确认转交给 worker，由 worker
  写入 `phase=done`；编排器随后镜像出 `state: completed`，不执行
  任何 git 合并。如果 PR 评审返回了修改请求，worker 会按照
  它的 PR 评审处理策略逐条评估——修复经核实确实存在的发现，对不成立的发现
  在 PR 上发布有理有据的拒绝说明——并可能把 `phase`
  从 `awaiting-confirmation` 回滚；只有在处理后的 PR 令人
  满意时，才写入 `confirmed`。参见
  `skills/orchestration-scheduling-task/SKILL.md` 中 `## 状态机` → "PR 流程"。

  这道闸门是强制性的。没有本节中明确且对应的令牌，编排器绝不改变状态、
  绝不合并、也绝不清理 worktree。
-->

## Notes

<!--
  自由格式。用户和编排器都可以在这里追加内容：
  - 编排器一侧：stale 摘要、错误摘录、attach 指引、
    `cleanup-approved` 触发记录、合并结果、push 失败。
  - 用户一侧：补充说明、手工编辑记录、针对 stale worker 的
    `cleanup-approved` 令牌。

  这是一个 `body`（正文）小节，不是 frontmatter 字段——绝不要在上面的
  frontmatter 中放 `notes:`。
-->

<!--
  多仓库示例条目（仅 frontmatter——供参考）
  ========================================
  一个跨两个兄弟仓库的任务（tipsy-ab-config + 它的 SDK），由
  **一个** worker 管理 = 一个 tmux session + 两个 git worktree + 一个 claude 进程。
  两个仓库默认都使用分支 `task/ab-config-env-field` 和 base `main`，因此
  严格来说只有 source-repo-2 这一行是必需的；branch-2/base-2/worktree-2
  只是为了清晰而列出，其实可以省略（它们会取文档所述的默认值）。

    ---
    task-id: ab-config-env-field
    project: tipsy-ab-config
    source-repo:   ~/workspace/tipsy-ab-config       # 仓库 1 = 主仓库；pane 的 cwd
    source-repo-2: ~/workspace/tipsy-ab-config-sdk    # 仓库 2
    state: ready
    priority: normal
    branch: task/ab-config-env-field                  # 主仓库分支
    branch-2: task/ab-config-env-field                # 仓库 2 分支（= 默认值；可省略）
    base: main                                        # 主仓库 base
    base-2: main                                      # 仓库 2 base（= 默认值；可省略）
    # 省略了 worktree / worktree-2 -> 采用默认兄弟目录布局：
    #   ~/.zyz-worker/worktrees/tipsy-ab-config/task/ab-config-env-field/tipsy-ab-config
    #   ~/.zyz-worker/worktrees/tipsy-ab-config/task/ab-config-env-field/tipsy-ab-config-sdk
    tmux-session: zyz-task-ab-config-env-field        # 两个仓库共用一个 session
    created-at: 2026-07-22
    updated-at: 2026-07-22
    ---
-->
