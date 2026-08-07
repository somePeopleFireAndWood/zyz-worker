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
- SubAgent 位于 `agents/`：execute-task 的 `implementation-agent` / `test-agent` / `review-agent`，以及 orchestration 的 L2 驱动 `orch-driver-agent`
- `.claude/agents` 与 `.claude/commands` 是指向根级目录的符号链接，方便在本仓库内直接以项目模式使用 Claude Code
- Execute Task Skill 位于 `skills/execute-task/SKILL.md`
- Orchestration Scheduling Task Skill 位于 `skills/orchestration-scheduling-task/SKILL.md`
- git-worktree Skill 位于 `skills/git-worktree/SKILL.md`
- clean-tmp Skill 位于 `skills/clean-tmp/SKILL.md`（跨平台安全清理临时目录 + Docker/编译缓存清理面，交互/自动双模式；细节参考资料在 `references/`）
- Execute Task 主控提示词位于 `skills/execute-task/prompts/main-agent.md`
- Orchestration 主控提示词位于 `skills/orchestration-scheduling-task/prompts/main-agent.md`
- Orchestration bash helpers 位于 `scripts/orch-*.sh`（其中 `orch-reuse-worker.sh` 用于「复用已完成任务的 tmux/worktree 创建新任务」——见下方 *容器复用*）
- 提示词式 SubAgent 定义位于 `subagents/`
- Watchdog hooks（execute-task 确定性监督层：心跳、状态新鲜度、退出/停止门禁）位于 `hooks/hooks.json` 与 `hooks/scripts/`，详见 `hooks/README.md`
- Watchdog 后台监视器位于 `monitors/monitors.json` 与 `monitors/watchdog.sh`（execute-task 触发时启动，发现角色静默/状态过期时唤醒主 agent）
- 整体架构说明位于 `docs/architecture.md`（各 skill / subAgent / 脚本 / hook 的职责与主体原理）
- 长期任务状态文件约定位于 `docs/conventions/long-running-state.md`
- 初始设计占位文档位于 `docs/design/initial-design.md`
- execute-task Skill 设计文档位于 `docs/design/execute-task-skill-design.md`
- 工程结构约定位于 `docs/conventions/project-structure.md`
- 暂未实现 MCP server 或真实 SubAgent 运行时

## 多项目 orchestration（multi-project orchestration）

`orchestration-scheduling-task` skill 与 `/orchestrate-tasks` 支持单一 orchestrator 同时调度跨多个项目的任务（multi-project orchestration）。要点：

- orchestrator 可以在任意 cwd 启动，包括 `~/` 或任何非 git 目录；它不假设自己 cwd 在被调度项目的 git repo 内。
- 一份 master list（`<list-dir>/tasks/*.md`）里可以混合来自不同项目的 task，每个 task 各自在自己的 master entry frontmatter 里声明 `source-repo: <绝对路径或 ~/ 开头的路径>`。
- `source-repo` 是**必须**字段，由用户写；orchestrator 不自动推断。`~/workspace/foo` 与 `~/workspace/bar` 这种跨 repo 调度由此原生支持。
- **单任务跨多仓（默认行为）**：一个 task 涉及多个仓库时，默认就是**一个 tmux session + 一个 claude 管理该任务名下的多个仓库 worktree**（每仓一个 worktree + 各自分支 / 各自提交推送），不再默认按仓拆成多个 session。附加仓用编号键 `source-repo-2:`、`source-repo-3:`… 声明（编号从 2 起、必须连续）；无编号的 `source-repo:` 为主仓（primary，其 worktree = pane cwd）。`branch-N:` / `base-N:` / `worktree-N:` 可逐仓覆盖，省略时按默认继承（分支/基线继承主仓解析值，worktree 走兄弟目录布局：同一父目录、目录名 = 仓库名，`go.work` 的 `../<repo>` 相对引用可解析）。只写单个 `source-repo:` 的条目与旧行为逐字节兼容。
- spawn helper 会对**每个** `source-repo[-N]` 做 4 道校验：缺字段、非绝对路径、路径不存在、不是 git work tree —— 任何一道失败都直接以 exit 5 + 精确诊断字符串退出（多仓诊断带 `repo <N>` 前缀），task 留在 `not-analyzed`；编号空洞（有 `-3` 无 `-2`）与 worktree 路径含 `:`（`ZYZ_WORKTREES` 分隔符）同样 exit 5。多仓时 spawn 建 N 个 worktree + 仅 1 个 tmux session + 1 个 claude；merge / cleanup / reuse 按仓逐个处理（仓集从 `dispatch.md` 的已解析编号字段组读取），merge 非原子、fail-fast、重跑幂等（已合仓跳过）。
- 软警示：**不要**把某个 task 的 `source-repo:` 指向 zyz-worker 插件仓库自身，除非你的本意就是在插件源码内派发一个 worker。无意中指向插件 repo 会导致 worker 在插件仓库里建分支与 worktree，与正常项目开发混淆。
- **隔离边界**：worker 与 worker 之间互不触碰对方的 worktree（spawn 以各 worktree 路径两两不相交强制）；worker 内部对名下**所有** worktree 有完整写权。即 `each worker = 1 tmux session + n git worktrees (one per repo; n=1 for single-repo tasks) + 1 full claude process`（保留 worker 概念与全部标识符，仅 worktree 数量不再限定为 1）。

三层调度架构（spawn → L2 启动真 claude → parent-shell invariant → exactly-once 幂等 → dispatch-bound 绑定）的端到端验收脚本是 `scripts/test-e2e-layered.sh`（可移植，Linux/macOS 均可）。运行：`bash scripts/test-e2e-layered.sh`（`--keep` 保留 fixture 供调试）。它需要 `tmux`/`git`/`claude` 都在 PATH 且 `claude` 已登录，并且会**消耗 API 配额**（A4 触发一次真实 LLM 往返）。这是真 claude 验收，与纯脚本单元测 `scripts/test-orchestration-helpers.sh` 分开。

## 容器复用（container reuse）

`/orchestrate-tasks` 支持「复用一个**已完成**任务遗留的 tmux session 和/或 git worktree 来创建新任务」，而不是再走一遍标准 spawn（重新 `git worktree add` + 新 session）。新任务在自己的 master entry frontmatter 里声明：

- `reuse-from: <old-task-id>` —— 要复用其容器的旧任务（必须是**同一 list** 内、`state: completed` 的任务）。
- `reuse-scope: worktree | tmux | both` —— 复用粒度（默认 `both`）。复用交接的是旧任务的**整个 worktree 集合**（多仓时全部仓，不支持只复用其中某一仓）。`worktree`=复用旧 worktree 集合 + 新 session + 新 claude；`tmux`=复用旧 session（新任务跑在旧 pane 的主仓 worktree 里，cwd 不可变，`worktree:` 字段被忽略，其余仓随集合整体交接）；`both`=复用旧 worktree 集合 + 旧 session。多仓复用时通过带内运行时配置块的可选 `worktrees:` 行（冒号分隔、主仓在前）把整套 worktree 交给 claude。
- `reuse-claude: true | false` —— 仅在复用 tmux 时有意义。`true`（默认）=复用同一个正在运行的 claude 进程（不重启，新任务运行时通过 *带内运行时配置块* 交给它）；`false`=在复用的 session 里重启 claude。`worktree` scope 下被忽略（一定是新 claude）。

落地为独立脚本 `scripts/orch-reuse-worker.sh <new-id> <list-dir>`（与 `orch-spawn-worker.sh` 并列；同样只关联/创建容器、写 Phase-1 `dispatch.md`、**从不**启动 claude）。复用只做容器关联，**绝不**推进或改写旧任务（旧任务始终 `completed`）。dispatch 步会据 `reuse-from` 路由到该脚本并派发 L2 `intent=reuse-dispatch`。**注意**：复用任务与其 `reuse-from` 旧任务**共享容器**，对任一方跑 cleanup 会同时销毁共享的 session/worktree（多仓时为整套 worktree）——确保所有共享方都已 `completed` 再清理。详见 `skills/orchestration-scheduling-task/SKILL.md` `## Container Reuse`。

## Worker MCP 隔离（ZYZ_WORKER_MCP）

orchestration 下每个 worker 是一个完整 `claude` 进程，而 **stdio 型 MCP server 是每 claude 进程各 spawn 一份、无法跨进程共享**——若 worker 全量继承宿主 `~/.claude.json` 的全局 `mcpServers`，内存开销随 worker 数线性放大（实测单个 lark-mcp 基线 **~745 MB/worker**，其中 ~695 MB 为私有内存，11 个 worker 累计 ~8 GB；该基线是 `require` 全量 zod schema 的启动成本，与存活时长无关，`preset.light` / 压 heap 上限均无效）。这与 `ZYZ_GO_BUILD_P` 治过的 `workers × go build -p` 是同一形态的问题——`workers × MCP 基线`，正确的旋钮是**继承策略**而不是 worker 数。

派发 worker 时的 MCP 继承策略由 `ZYZ_WORKER_MCP` 控制（`scripts/orch-worker-mcp-args.sh` 产出 CLI 片段，spawn/reuse 快照进 `dispatch.md` 的 `worker-mcp-args:` 字段，L2 启动命令与崩溃恢复的 `--resume` 命令都用同一份快照）：

| 值 | 效果 |
|---|---|
| `none`（**默认**） | 启动加 `--strict-mcp-config`：worker **零 MCP**，每个 stdio server 省 ~745 MB/worker。**行为变更**：≤0.15.0 的 worker 会全量继承；依赖 MCP 的既有任务需显式设 `inherit` |
| `inherit` | 旧行为：不加任何 flag，worker 全量继承宿主全局 `mcpServers` |
| `<config-path>` | `--strict-mcp-config --mcp-config '<path>'`：worker 只拿该 JSON 里声明的 server（共享 server 的接入点）。路径非法时**收敛回 `none`**（fail closed，stderr 告警），绝不静默退回全量继承 |

**共享 server 的安全边界（用 `<config-path>` 前必读）**：把一个烤了凭据的 MCP server 起成常驻进程共享给多个 worker 时——(1) **不要用 TCP 端口**（127.0.0.1 也不行：本机所有用户都能连，等于把凭据使用权开放给同机他人），socket 应放在 `$XDG_RUNTIME_DIR` 这类 0700 属主目录内，worker 侧经 stdio 桥接；(2) 凭据走 `--config <0600 文件>` 或环境变量，**不要放进 argv**（`ps` 全机可见）；(3) `XDG_RUNTIME_DIR` 不存在（cron / 非 login session）时应显式失败而非回退 TCP。收益量级：N×745MB → 1×~834MB + N×~15MB 桥进程。本插件当前只提供 `<config-path>` 这个接入点，不代起共享 server。

另：若 worker 确需 stdio MCP，配置里用**已安装二进制的绝对路径**而非 `npx -y <pkg>`——npx 会额外留两层常驻包装进程（~47 MB/worker）。

## Go 构建 I/O 优化注入（Go build I/O optimization）

多个 worker 并行在各自 worktree（多仓 worker 则是名下多个 worktree）里跑 `go build ./...` 时，**总编译并行 ≈ worker 数 × 每个 build 的 `-p`**（`-p` 默认 = NumCPU，常为 16）。worker 不限本身没问题，真正会把单块磁盘 I/O 打满的是「每个 build 又各自十几路链接、且中间产物全写同一块盘」这个二次放大。

为消除这个雪崩，orchestrator **默认**在派发每个 worker 时，向其 tmux pane 注入两项 Go 构建 env（注入发生在 L2 启动 claude **之前**，故 claude 派生的 `go build` 子进程继承之）：

- `GOTMPDIR` 指向一块 tmpfs 内存盘（默认 `/dev/shm/zyz-gobuild`）——把链接中间产物从磁盘移到内存盘。
- `GOFLAGS=-p=N`（默认 `N=4`）——压低单个 build 的编译/链接并发。

注入由独立 helper `scripts/orch-build-env.sh` 产出片段、由 `orch-spawn-worker.sh`（标准 spawn）与 `orch-reuse-worker.sh` 的 `worktree` scope 分支送进 pane（same/restart-claude 复用一个已启动的 claude，其 env 已冻结，故**不**注入）。

### 可调开关（在 orchestrator 宿主侧读取）

| env | 默认 | 作用 |
|---|---|---|
| `ZYZ_GO_BUILD_OPT` | 开启 | 设 `0` / `false` / `off` / `no`（大小写不敏感）关闭全部构建优化注入 |
| `ZYZ_GO_BUILD_P` | `4` | 注入的 `GOFLAGS=-p=N` 的 N（单 build 编译并发）；非正整数或 **> 64** 一律回落 `4`（`-p` 是唯一能把事故重新引爆的旋钮，故钳上限） |
| `ZYZ_GO_TMPFS_DIR` | `/dev/shm` | tmpfs 基目录候选；运行期探测其**存在且可写**才设 `GOTMPDIR` |

### 关键语义

- **总并行 = worker × p，靠调小 `p` 控盘**，而不是靠减少 worker 数。
- **自动降级（跨平台）**：探测是在 pane 内做「目录存在且可写」，探测不到（如 **macOS 无 `/dev/shm`**）就**跳过 `GOTMPDIR`**、绝不指向不存在的目录（Go 不会自动创建 `GOTMPDIR`，指向不存在目录会让 build 失败）；`GOFLAGS=-p` 在任何平台都注入。
- **绝不覆盖用户 env**：pane 里若已有 `GOTMPDIR` / `GOFLAGS`（含你在宿主 shell 里先 `export` 再起 orchestrator 的情形），注入逻辑跳过对应项，你的值永远胜出。
- **`GOCACHE` 保持默认**（磁盘持久化，跨 build 复用），**永不**设 `GOMAXPROCS`。
- **探测是「存在且可写」，不是「文件系统类型 = tmpfs」**（脚枪提示）：把 `ZYZ_GO_TMPFS_DIR` 指向一个普通磁盘目录也会「探测成功」并把中间产物**写到磁盘上**——这是用户自负的风险。

### tmpfs 撑爆风险与观察命令

无上限 worker 并行编译时，tmpfs 占用 ≈ 同时活跃的各 build 中间产物之和，**有撑爆风险**（撑爆 = 吃物理内存，会导致 build 失败 + 加剧内存压力）。本插件**不**在代码里给 tmpfs 设独立 size 上限（那属于资源感知派发的范畴，另开任务）。请用以下命令观察：

```sh
watch -n5 'df -h /dev/shm; free -h'
```

真冲高了可以给 tmpfs 设独立上限、把 `ZYZ_GO_TMPFS_DIR` 退回磁盘目录、或直接 `ZYZ_GO_BUILD_OPT=0` 关闭注入。

### standalone（非 orchestrated）用户手动设置

standalone `execute-task` 是单 worker、用户直接起 claude、不经过 spawn，故代码**不**注入。需要同等优化的话，在起 claude 前手动 `export` 即可（注意 `GOTMPDIR` 须存在且可写）：

```sh
mkdir -p /dev/shm/zyz-gobuild && export GOTMPDIR=/dev/shm/zyz-gobuild
export GOFLAGS=-p=4
```

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
│   ├── orch-driver-agent.md
│   ├── review-agent.md
│   └── test-agent.md
├── commands/
│   ├── execute-task.md
│   ├── code-development.md
│   └── orchestrate-tasks.md
├── assets/
│   └── README.md
├── docs/
│   ├── architecture.md
│   ├── conventions/
│   │   ├── long-running-state.md
│   │   └── project-structure.md
│   └── design/
│       ├── execute-task-skill-design.md
│       └── initial-design.md
├── hooks/
│   ├── README.md
│   ├── hooks.json
│   └── scripts/
│       ├── lib.sh
│       ├── heartbeat.sh
│       ├── subagent-track.sh
│       ├── status-freshness.sh
│       ├── post-agent-flush.sh
│       ├── dispatch-scope-guard.sh
│       ├── checkout-guard.sh
│       ├── stop-gate-subagent.sh
│       └── stop-gate-main.sh
├── monitors/
│   ├── monitors.json
│   └── watchdog.sh
├── scripts/
│   ├── README.md
│   ├── orch-scan-tasks.sh
│   ├── orch-spawn-worker.sh
│   ├── orch-reuse-worker.sh
│   ├── orch-build-env.sh
│   ├── orch-worker-mcp-args.sh
│   ├── orch-check-worker.sh
│   ├── orch-heartbeat-daemon.sh
│   ├── orch-cleanup-worker.sh
│   ├── orch-merge.sh
│   ├── orch-merge-and-cleanup.sh
│   └── pack.sh
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
│   │       ├── monitor.md
│   │       ├── dispatch.md
│   │       └── question-answer.md
│   ├── git-worktree/
│   │   └── SKILL.md
│   └── clean-tmp/
│       ├── SKILL.md
│       └── references/
│           ├── macos-tmpdir-trap.md
│           └── socket-liveness.md
├── subagents/
│   ├── README.md
│   ├── implementation-agent.md
│   ├── orch-driver-agent.md
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
- `hooks/` 保存 execute-task watchdog hooks（`hooks.json` + `scripts/`），随插件启用自动生效；详见 `hooks/README.md`。
- `monitors/` 保存插件后台监视器（`monitors.json` + `watchdog.sh`），execute-task skill 首次触发时启动。
- `scripts/` 保存本仓库的校验、打包、测试等自动化脚本。
- `docs/conventions/` 保存跨目录的工程约定。

多端清单是关键：Claude Code 通过 `.claude-plugin/plugin.json` 识别本仓库，Codex 通过 `.codex-plugin/plugin.json` 识别本仓库，两端共享根级的 `skills/` 与 `subagents/`。

## 后续开发方向

本项目会保持小步演进。后续可能补充：

- `skills/` 下的具体工作流说明
- 用于仓库检查、验证和自动化的脚本
- 产品需求拆解文档模板
- 技术实现设计文档模板
- 如有明确需要，再增加 MCP server 或 app manifest
