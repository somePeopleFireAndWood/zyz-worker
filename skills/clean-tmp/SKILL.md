---
name: clean-tmp
description: Use when the user wants to safely clean up leftover temporary files in the temp directories of the current user (Linux /tmp; macOS /tmp and $TMPDIR), following an inventory-then-delete flow that never removes live-process sockets or long-lived session dirs. Cross-platform (macOS + Linux). Triggers like "clean /tmp", "清理 tmp", "清临时文件".
---

# Clean Temp

## 何时加载本 skill

当用户希望「定期、安全地清理当前用户在临时目录下的残留」时加载本 skill。典型触发：用户说「清理一下 /tmp」「清临时文件」「tmp 满了帮我看看能删啥」「clean up my temp dir」等。

本 skill 是**跨平台**的（macOS + Linux 双通）：

- Linux 上真实临时目录通常就是 `/tmp`。
- macOS 上每个用户有自己的真实临时目录 `$TMPDIR`（形如 `/var/folders/**/T/`），而 `/tmp` 是 `/private/tmp` 的软链、且是**全体用户共享**的空间。

因此本 skill 会枚举「当前用户可能用到的所有临时根」，逐根盘点、逐根清理，而不是写死 `/tmp`。

## 核心安全契约（绝不放宽）

本 skill 是**交互式、需用户确认**的一次性清理流程，不是无人值守的自动删除。任何一次清理都必须遵守：

1. **列清单 → 用户确认 → 删除**。先盘点、分类、写出一份**具名的、逐条可见**的删除预览，交给用户拍板；用户点头之前不删除任何东西。
2. **绝不 `rm -rf /tmp/*`**（或对任何临时根做通配符批量删除）。永远走**具名清单**——删除命令里出现的每一条路径都必须是盘点时列出、用户确认过的具体条目。
3. **绝不动其他用户的文件**。盘点一律用属主过滤（`-user "$(id -un)"`）。这在**多用户共享的开发机**上是最常见的场景——**Linux 与 macOS 上 `/tmp` 都是多用户共享空间**，那里可能有别的用户或系统进程的临时文件；属主过滤 `-user "$(id -un)"` 保证只碰当前用户自己属主的条目，其余一律跳过。
4. **不确定就保留（fail → keep）**。凡是「无法确定持有者」「无法确定是否还在被使用」「不认识的目录/工具」，一律归入「保留 / 需要你拍板」，**绝不静默判定为可删并删除**。宁可留下垃圾，不可误删活文件。

本 skill 是**给 agent 阅读并按语义执行**的指导性文本，不是一个必须一次跑通的脚本。下面给出的每条命令都尽量可移植；当某条命令在当前宿主上失败、报权限错误或行为异常时，**默认保留相关条目**并把它标注为「需要你拍板」，不要因为一条探测命令失败就冒进删除。

## 第 0 步：枚举临时根

按 **`$TMPDIR` 是否设置**（而非按操作系统名）来决定要清理哪些根——这样 macOS 与「设置了 `TMPDIR` 的 Linux 用户」都能自然覆盖，无需 OS 分支：

```bash
# 收集要盘点的临时根：始终包含 /tmp；若 $TMPDIR 已设置，一并纳入。
# 关键：每个根都用 `cd ... && pwd -P` 解析成【物理路径】再入表，而不是留字面量。
# 原因（macOS 软链陷阱）：macOS 上 /tmp 是 /private/tmp 的软链，而 find/ls 默认走物理模式，
#   `find /tmp -maxdepth 1 -mindepth 1 ...` 不会跟随软链【起点】——它只看到 depth-0
#   （被 -mindepth 1 排除）→ 返回【空且退出码 0】，既不报错也盘点不到任何东西。此时
#   "探测失败→保留+告知" 的安全网根本不触发，agent 会误以为 /tmp 是空的（Goal 2 / AC#1
#   的 macOS /tmp 覆盖被静默架空）。把根解析成物理路径后，find/ls 直接作用在 /private/tmp，
#   问题消失。这是【欠报，绝不误删】的方向，但仍须修掉。
# add_root 顺带去重：/tmp 与 $TMPDIR 解析后若同为 /private/tmp，只保留一份。
add_root() {
  r="$(cd "$1" 2>/dev/null && pwd -P)" || return 0   # 解析失败（目录不存在等）→ 跳过，不入表
  case " $ROOTS " in *" $r "*) ;; *) ROOTS="${ROOTS:+$ROOTS }$r" ;; esac
}
ROOTS=""
add_root /tmp
[ -n "${TMPDIR:-}" ] && add_root "$TMPDIR"
```

- 仍按 **`$TMPDIR` 是否设置**（而非 OS 名）决定要不要纳入 per-user 真实临时目录；这里只是把每个根都解析成物理路径。
- Linux：`$TMPDIR` 通常未设置，`ROOTS` 就是 `/tmp`（本身就是物理路径）。
- macOS：交互 shell 恒有 `$TMPDIR`（`/var/folders/**/T/`），解析后 `ROOTS` = `/private/tmp`（即 `/tmp` 的物理路径）+ 该 per-user 真实临时目录。**Linux 与 macOS 上 `/tmp` 都是多用户共享空间**（共享开发机上尤其常见），格外注意属主过滤；macOS 特有的是 `/tmp` → `/private/tmp` 软链、且 per-user 真实临时目录落在 `$TMPDIR`。

后续所有步骤对 `ROOTS` 里的**每一个根**独立执行一遍。

## 四步工作流

对每个临时根 `$root`，依次：**盘点 → 分类 → 写预览 → 等用户拍板**。

### 第 1 步：盘点（属主过滤 + 大小 + 磁盘）

只看**当前用户自己**在该根下的一层条目（不递归进子目录做删除决策）：

```bash
# 只列当前用户拥有的顶层条目（POSIX，不用 GNU 专属的 -printf）。
find "$root" -maxdepth 1 -mindepth 1 -user "$(id -un)" 2>/dev/null

# 需要更可读的属主/时间信息时，配合 ls：
ls -la "$root"

# 逐条目的占用大小用 du -sk（POSIX，KB 为单位；不要用 GNU 专属的 find -printf %s）：
du -sk "$root"/* 2>/dev/null

# 该根所在挂载点的磁盘用量（临时目录可能不在 / 挂载，尤其 macOS 的 $TMPDIR）：
df -h "$root"
```

要点：

- **属主过滤是硬性要求**：`-user "$(id -un)"` 保证只碰自己的文件。**Linux 与 macOS 上 `/tmp` 都是多用户共享空间**（共享开发机上更是如此），别的用户的条目一律不进清单。
- `-printf` 是 GNU-only，macOS 的 BSD `find` 不支持——本 skill 一律不用它，改用 `-user` 过滤 + `du -sk` 取大小。
- 若某条命令报权限错误，把相关条目标注为「无法盘点 → 保留」。

### 第 2 步：分类（活/僵/不确定）

把盘点出的条目按风险分级。**默认保留清单**（见下）里的东西直接归「保留」；其余重点判断「是否还有活进程在用」。

#### socket 活性判断（双分支 + 进程存活复核）

对疑似 unix socket 或含 socket 的运行时目录，判断持有它的进程是否还活着：

```bash
# 分支 A（Linux 优先）：ss 对 unix socket 路径 → pid 的解析比 lsof 可靠。
if command -v ss >/dev/null 2>&1; then
  ss -lxp | grep -F "$sock"        # 从输出里解析出持有者 pid
# 分支 B（macOS / 无 ss 回退）：lsof。
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP "$sock"                 # 列出打开该 socket 的进程 pid（经典 lsof 视非选项参数为待查名，不用 --）
fi

# 拿到候选 pid 后，用 POSIX 的 kill -0 复核该进程是否存活
# （替代 Linux-only 的 /proc/$pid 存在性判断，两端一致）：
# 拿到候选 pid 后，用 POSIX 的 kill -0 复核该进程是否存活
# （替代 Linux-only 的 /proc/$pid 存在性判断，两端一致）。
# 注意 kill -0 的两种失败要分开看：
#   - ESRCH（no such process）→ 进程【确实没了】→ gone；
#   - EPERM（operation not permitted）→ 进程【还活着】，只是属于别的 uid、你无权发信号 → 仍算 ALIVE。
# 所以不能把「kill -0 非零」一律当作 gone；否则会把活进程误判为 STALE。
if kill -0 "$pid" 2>/dev/null; then
  echo "ALIVE: keep"                       # 信号可达 → 活着
elif kill -0 "$pid" 2>&1 | grep -qi 'not permitted'; then
  echo "ALIVE (EPERM: 他人进程仍在): keep"  # 权限错误 = 进程存在 → 保留
else
  echo "GONE (ESRCH): 才可考虑 STALE"        # 唯有确认 no such process 才算真没了
fi
```

**关键安全规则**：

- 只有当「明确解析出持有者 pid **且** `kill -0` 确认该进程已不存在（ESRCH / no such process）」时，才可把该 socket 归为 STALE（僵尸）候选。`kill -0` 报权限错误（EPERM / not permitted）说明进程【还活着】只是属于他人 uid → 一律 ALIVE，保留。
- **持有者无法确定**（`ss`/`lsof` 都查不到、或命令失败）→ **默认 KEEP，归入「需要你拍板」，绝不静默判 STALE 删除**。lsof 有时查不到活 socket 的持有者，冒进删除会杀掉活链路。

#### 目录占用判断

```bash
# 判断某目录内是否仍有被打开的文件/进程占用（两端都有 lsof +D）：
lsof +D "$dir" 2>/dev/null
```

- macOS 上 `lsof +D` 可能较慢或需要额外权限；**命令失败或超时时，默认保留该目录**，不要因为「查不到占用」就当空目录删。

### 第 3 步：写预览（具名清单）

产出一份逐条可见的预览，至少分三栏：

- **建议删除（DELETE）**：具名条目 + 大小 + 判定理由（例如「僵尸 socket，持有者 pid 12345 已不存在」）。
- **保留（KEEP）**：命中默认保留清单，或活进程仍在用。
- **需要你拍板（NEEDS YOUR CALL）**：无法确定持有者/占用、不认识的工具目录等。

预览必须是**具名清单**——每条都是确定的路径，绝不出现 `/tmp/*` 这类通配删除。

### 第 4 步：等用户拍板

把预览交给用户。**用户明确确认后**，才对「建议删除」里被用户认可的条目逐条执行删除（例如 `rm -rf -- "<具体路径>"`，路径来自清单、绝不是通配）。用户没点头就不删。

## 默认保留清单（按每个枚举根相对保护）

以下四类在 **`ROOTS` 里的每一个根下**都受保护——`/tmp` 下要护，`$TMPDIR` 下同样要护。它们是运行时活套接字/会话目录，误删会打断正在跑的进程：

| 模式（相对每个 `$root`） | 说明 |
|---|---|
| `$root/claude-*` | Claude 运行时/会话目录，正在跑的 agent 在用。 |
| `$root/tmux-<uid>` | tmux server 的 socket 目录（`<uid>` 为当前用户 id）。 |
| `$root/mcp-*` | MCP server 运行时 socket/目录，**永远跳过**。 |
| `$root/ssh-*` | SSH agent-forwarding socket，删了会断掉 agent 转发。 |

**关于 tmux socket 的位置（重要，勿再犯旧错）**：tmux 的 socket 目录由 `TMUX_TMPDIR` → `TMPDIR` → `/tmp` 依次推导。因为 **macOS 恒有 `$TMPDIR`**，macOS 上活的 tmux server socket 正常位于 **`$TMPDIR/tmux-<uid>/`**，而**不是** `/tmp/tmux-<uid>`。所以只保护 `/tmp/tmux-<uid>` 会漏掉真正的活 tmux socket——本仓库的 orchestration worker 就跑在 tmux 里，这是最危险的漏网。**必须对每个枚举根都保护 `tmux-<uid>`。** 命中保留清单的条目，若仍要进一步确认，一律用 `ss`/`lsof` + `kill -0` 复核活性，活的坚决保留。

**额外保留模式**：若用户在对话中提到额外要保留的路径/模式，一并纳入保留清单。

## 常见陷阱（「不要做什么」护栏）

全部保留自原始 skill，并补跨平台注解：

- **`mcp-*` 永远跳过**：无论在哪个根下，MCP server 的运行时目录一律不动。
- **`code-<uuid>` 先验活再说**：VS Code / IDE 的临时目录形如 `code-<uuid>`；删前必须 `ss`/`lsof` + `kill -0` 确认无活进程，查不到持有者→保留。
- **`ssh-*` 是 agent-forwarding socket**：删了会断掉 SSH agent 转发，永远保留。
- **不熟悉的 IDE / 工具目录宁可保留**：遇到不认识的目录名（各类编辑器、语言工具链、构建缓存），当「需要你拍板」，不擅自删。
- **绝不 `rm -rf /tmp/*`**：永远具名清单删除，绝不通配批量删。
- **不清其他用户的文件**：盘点一律 `-user "$(id -un)"` 过滤。
- **`/tmp` 是多用户共享空间（Linux 与 macOS 都是）**：共享开发机上 `/tmp` 常有多个用户的临时文件；跨用户清理禁令在 `/tmp` 上尤其要严格——只清自己属主的条目。macOS 额外之处在于 `/tmp` → `/private/tmp` 是软链，per-user 真实临时目录落在 `$TMPDIR`。
- **不确定持有者 → 保留**：`ss`/`lsof` 查不到、命令失败、权限不足，一律 KEEP + 标「需要你拍板」，绝不静默删。

## 完成后

一次清理执行后：

- 列出**残留条目**（被保留的 / 用户选择不删的），让用户知道当前状态。
- 对每个根重新跑 `df -h "$root"`，展示清理前后磁盘用量变化。
- 提醒用户：若本次确认了某些新的「以后也总是要保留」的路径/模式，可以把它们保存到记忆（memory）里，下次清理自动纳入默认保留清单。

## 失败与升级行为

- 任一探测命令（`find` / `du` / `ss` / `lsof` / `df`）失败、超时或报权限错误：把相关条目标注为「保留 / 需要你拍板」，继续处理其余条目，绝不因单点失败而冒进删除。
- BSD 与 GNU 的 `find` / `stat` / `df` / `lsof` 细节有差异：本 skill 的措辞一律偏向安全侧（不确定就保留）。遇到无法可靠判定的情形，把决定权交回用户。
- 本 skill 不做破坏性 git 操作、不改系统配置、不引入后台常驻或定时器；「定期」由用户按需再次调用体现。
