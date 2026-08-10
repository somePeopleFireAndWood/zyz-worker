---
name: clean-tmp
description: Use when the user wants to safely clean up leftover temporary files, Docker resources (images/volumes/build cache), or language build caches owned by the current user (Linux /tmp; macOS /tmp and $TMPDIR). Dual mode - interactive inventory-then-confirm-then-delete (default), or auto/unattended mode (--auto or explicit authorization) deleting by tightened criteria with a post-run report; never removes live-process sockets or long-lived session dirs. Cross-platform (macOS + Linux). Triggers like "clean /tmp", "清理 tmp", "清临时文件", "定期磁盘整理", "清 docker", "配额超了", "quota 超限", "无人值守清理", "unattended cleanup".
---

# Clean Temp

## 何时加载本 skill

当用户希望「定期、安全地清理当前用户名下的临时目录残留、Docker 资源或编译/包管理缓存」时加载本 skill。典型触发：用户说「清理一下 /tmp」「清临时文件」「tmp 满了帮我看看能删啥」「定期磁盘整理」「清 docker」「配额超了」「quota 超限」「无人值守清理（unattended / auto）」等。

本 skill 是**跨平台**的（macOS + Linux 双通）：

- Linux 上真实临时目录通常就是 `/tmp`。
- macOS 上每个用户有自己的真实临时目录 `$TMPDIR`（形如 `/var/folders/**/T/`），而 `/tmp` 是 `/private/tmp` 的软链、且是**全体用户共享**的空间。

因此本 skill 会枚举「当前用户可能用到的所有临时根」，逐根盘点、逐根清理，而不是写死 `/tmp`。

## 核心安全契约（绝不放宽）

本 skill 有两种运行模式（见下节「模式判定」），安全底线一致。任何一次清理都必须遵守：

1. **删除决策按模式执行**：
   - **交互模式（默认）**：**列清单 → 用户确认 → 删除**。先盘点、分类、写出一份**具名的、逐条可见**的删除预览，交给用户拍板；用户点头之前不删除任何东西。
   - **自动模式**：**列清单 → 按收紧后的 DELETE 判据直接删除 → 事后报告**。完整执行盘点→分类→生成具名清单，把「等确认」替换为「五条件判据全满足才删 + 自动模式事后报告」（见「自动模式 DELETE 判据」「自动模式事后报告」两节）。
2. **绝不 `rm -rf /tmp/*`**（或对任何临时根做通配符批量删除）。永远走**具名清单**——删除命令里出现的每一条路径都必须是盘点时列出的具体条目。**两种模式都不放宽。**
3. **绝不动其他用户的文件**。盘点一律用属主过滤（`-user "$(id -un)"`）。**Linux 与 macOS 上 `/tmp` 都是多用户共享空间**（多用户共享的开发机上最常见），那里可能有别的用户或系统进程的临时文件；属主过滤保证只碰当前用户自己属主的条目，其余一律跳过。**两种模式都不放宽。**
4. **不确定就保留（fail → keep）**。凡是「无法确定持有者」「无法确定是否还在被使用」「不认识的目录/工具」，一律归入「保留 / 需要你拍板」，**绝不静默判定为可删并删除**。宁可留下垃圾，不可误删活文件。**两种模式都不放宽。**

自动模式下，NEEDS-YOUR-CALL（需要你拍板）类条目**一律保留**并在事后报告中列出，留给下次交互处理；自动模式绝不把「不确定」升级为删除。

本 skill 是**给 agent 阅读并按语义执行**的指导性文本，不是一个必须一次跑通的脚本。下面给出的每条命令都尽量可移植；当某条命令在当前宿主上失败、报权限错误或行为异常时，**默认保留相关条目**，不要因为一条探测命令失败就冒进删除。

## 模式判定

- 默认**交互模式**。
- 满足任一即进入**自动模式**：调用参数带 `--auto`；或调用 prompt 明确表述「已授权自动执行 / unattended / 无人值守」。
- **模糊表述不算授权**（如仅说「定期清理」「帮我清一下」）→ 交互模式。授权必须是明确的。

## 第 0 步：枚举临时根

按 **`$TMPDIR` 是否设置**（而非按操作系统名）来决定要清理哪些根——这样 macOS 与「设置了 `TMPDIR` 的 Linux 用户」都能自然覆盖，无需 OS 分支：

```bash
# 收集要盘点的临时根：始终包含 /tmp；若 $TMPDIR 已设置，一并纳入。
# 关键：每个根都用 `cd ... && pwd -P` 解析成【物理路径】再入表——macOS 上 /tmp 是
# /private/tmp 的软链，find/ls 物理模式不跟随软链【起点】，直接扫软链根会【静默返回空】
# （欠报、绝不误删的方向，但盘点被架空，仍须修掉）。详见 references/macos-tmpdir-trap.md。
# add_root 顺带去重：/tmp 与 $TMPDIR 解析后若同为 /private/tmp，只保留一份。
add_root() {
  r="$(cd "$1" 2>/dev/null && pwd -P)" || return 0   # 解析失败（目录不存在等）→ 跳过，不入表
  case " $ROOTS " in *" $r "*) ;; *) ROOTS="${ROOTS:+$ROOTS }$r" ;; esac
}
ROOTS=""
add_root /tmp
[ -n "${TMPDIR:-}" ] && add_root "$TMPDIR"
```

- Linux：`$TMPDIR` 通常未设置，`ROOTS` 就是 `/tmp`（本身就是物理路径）。
- macOS：交互 shell 恒有 `$TMPDIR`，解析后 `ROOTS` = `/private/tmp`（即 `/tmp` 的物理路径）+ per-user 真实临时目录。两端 `/tmp` 都是多用户共享空间，格外注意属主过滤。

后续所有步骤对 `ROOTS` 里的**每一个根**独立执行一遍。

## 自动模式 DELETE 判据（五条件合取，宁可漏删）

自动模式下，一个条目**同时满足全部五条**才可删除。任一条件不满足或探测失败 → 保留，并标注原因（recent / in-use / needs-call / protected / not-on-allowlist）。**每条判据的失败方向都是 fail → keep**——自动模式没有用户兜底，方向写反就是事故。

1. **属主 = 当前用户**：盘点已用 `find -user "$(id -un)"` 保证；属主查不出来 → 保留。
2. **mtime > 48 小时**：mtime 距今不足 **48 小时**的条目视为可能仍在使用，一律保留。选 mtime 而非 atime：atime 在 noatime/relatime 挂载上不可靠（多数服务器默认 noatime，读文件不更新 atime）。find 探测失败（权限等）≠ 够老 → 保留。
3. **非保护模式**：命中「默认保留清单」→ 保留（protected）。
4. **无打开句柄**：`lsof +D "$dir"` / `lsof -nP "$f"` 查无占用才算无人用。lsof 失败/超时 ≠ 无占用 → 视为可能占用 → 保留。
5. **命中「已知一次性产物」允许名单**（正性匹配才删；不在名单上 → 不删，not-on-allowlist）：`local-review-*`、`*.test`、`*.bin`、review 工作区目录、构建缓存临时目录（如 `go-build*`、`pip-*`、`npm-*`）、`tmp.*`（mktemp 产物）。名单条目必须是已知一次性产物形态，仅在临时根顶层生效；用户可在授权时扩充。允许名单（正性匹配）与默认保留清单（负性排除）双向夹逼。

48h 探测的可移植实现（`-mmin`/`-maxdepth` 非严格 POSIX，但 GNU 与 macOS BSD find 均支持）：

```bash
# 普通文件：条目自身 mtime 是否在 48h 内——输出非空即 recent → 保留。
# 注意 fail→keep 方向：find 本身失败（权限等）时同样保留，
# 不能把「无输出」一律当作「够老可删」。
if ! out="$(find "$p" -maxdepth 0 -mmin -2880 2>/dev/null)"; then
  keep "$p" "probe-failed"
elif [ -n "$out" ]; then
  keep "$p" "recent (<48h)"
fi

# 目录：递归探测——目录自身 mtime 只反映【直接子项】的增删，深层文件被
# 周期性写入不会更新顶层 mtime，-maxdepth 0 会把仍在活跃使用的目录误判为
# 「够老」。因此对目录去掉 -maxdepth 0，内部【任一】条目 48h 内改动过即
# 整个目录判 recent → 保留。短路用 find 自身的 -print -quit（GNU 与
# macOS BSD find 均支持）而不是管道 | head -n 1：管道会让退出码变成 head
# 的（几乎恒为 0），find 自身失败（如 mode-000 不可读目录）被静默吞掉，
# probe-failed 分支永远走不到——fail→keep 就被架空了。-print -quit 保留
# find 的退出码，三种结果（失败→keep、命中→keep、干净为空→够老）可区分。
if [ -d "$p" ]; then
  if ! out="$(find "$p" -mmin -2880 -print -quit 2>/dev/null)"; then
    keep "$p" "probe-failed"
  elif [ -n "$out" ]; then
    keep "$p" "recent (<48h, inner mtime)"
  fi
fi
```

该阈值只属于自动模式；交互模式仍靠用户确认兜底（清单里展示 mtime 供参考）。

## 四步工作流

对每个临时根 `$root`，依次：**盘点 → 分类 → 写清单 → 按模式执行**。

### 第 1 步：盘点（属主过滤 + 大小 + 磁盘）

只看**当前用户自己**在该根下的一层条目（不递归进子目录做删除决策）：

```bash
# 只列当前用户拥有的顶层条目（不用 GNU 专属的 -printf）。
find "$root" -maxdepth 1 -mindepth 1 -user "$(id -un)" 2>/dev/null

# 需要更可读的属主/时间信息时，配合 ls：
ls -la "$root"

# 逐条目的占用大小用 du -sk（KB 为单位），只对上面的属主清单逐条跑。
# 该根所在挂载点的磁盘用量（临时目录可能不在 / 挂载，尤其 macOS 的 $TMPDIR）：
df -h "$root"
```

- **属主过滤是硬性要求**：`-user "$(id -un)"` 保证只碰自己的文件，别的用户的条目一律不进清单。
- `-printf` 是 GNU-only，macOS 的 BSD `find` 不支持——本 skill 一律不用它，改用 `-user` 过滤 + `du -sk` 取大小。
- 若某条命令报权限错误，把相关条目标注为「无法盘点 → 保留」。

### 第 2 步：分类（活/僵/不确定）

把盘点出的条目按风险分级。**默认保留清单**（见下）里的东西直接归「保留」；其余重点判断「是否还有活进程在用」。

**socket 活性判断要点**（完整的双分支示例与退出码语义详见 `references/socket-liveness.md`）：

- Linux 优先用 `ss -lxp` 解析 unix socket 的持有者 pid；macOS / 无 ss 时回退 `lsof -nP`。
- 拿到候选 pid 后用 POSIX 的 `kill -0` 复核存活：EPERM（not permitted）= 进程**还活着**（属他人 uid，无权发信号）→ ALIVE，保留；只有 ESRCH（no such process）才允许归入 STALE 候选。不能把「`kill -0` 非零」一律当作 gone。
- **持有者无法确定**（`ss`/`lsof` 都查不到、或命令失败）→ **默认 KEEP，归入「需要你拍板」，绝不静默判 STALE 删除**。
- 目录占用用 `lsof +D "$dir"` 探测；命令失败或超时（macOS 上可能较慢）→ 默认保留该目录。

### 第 3 步：写清单（具名）

产出一份逐条可见的清单，至少分三栏：

- **建议删除（DELETE）**：具名条目 + 大小 + 判定理由（自动模式下 = 五条件全满足的条目）。
- **保留（KEEP）**：命中默认保留清单，或活进程仍在用，或任一判据不满足（附原因标签）。
- **需要你拍板（NEEDS YOUR CALL）**：无法确定持有者/占用、不认识的工具目录等。自动模式下这栏一律保留并写进事后报告。

清单必须是**具名**的——每条都是确定的路径，绝不出现 `/tmp/*` 这类通配删除。

### 第 4 步：执行（按模式）

- **交互模式**：把清单作为预览交给用户，**用户明确确认后**，才对被认可的条目逐条删除（如 `rm -rf -- "<具体路径>"`，路径来自清单、绝不通配）。用户没点头就不删。
- **自动模式**：对 DELETE 栏（五条件判据全满足）的条目逐条删除（同样具名、绝不通配），KEEP 与 NEEDS-YOUR-CALL 全部保留；随后输出「自动模式事后报告」。

## Docker 资源回收（仅自动模式 / 明确授权时执行）

**动机**：rootless docker 的镜像/容器/卷数据在 `~/.local/share/docker`，**计入当前用户的 uid quota**——这是实际发生过的 quota 超限事故的主因之一，也是这块清理面存在的理由。

**执行前提**：处于自动模式，或用户在交互中明确授权清 Docker。仅「清理 /tmp」的交互请求不自动触发 Docker 清理，但 daemon 可达时应在盘点报告里附 `docker system df` 结果提示可回收量。

**前置探测**：`docker system df` 报告镜像/容器/卷/构建缓存的可回收量。`docker info` 或 `docker system df` 失败（无 daemon / 无权限 / 无 docker CLI）→ **整块跳过并在报告中标注**，不算失败（fail→keep 哲学：docker 探测失败 ≠ 可清）。

- **镜像**：`docker image prune -a -f`——删所有未被任何容器引用的镜像。成本提示：短周期 loop（如每 2 小时）下反复 prune 会导致常用基础镜像反复重拉，属预期行为，仅作提醒。
- **卷**：默认 `docker volume prune -f`。**卷保护语义要记准**：被**任何现存容器**（无论运行中还是已停止）引用的卷都不会被 prune/rm 删除——风险仅在**容器本身已被删除**、具名卷失去引用之后。版本语义差异：Docker ≥23 的 `volume prune` 默认只删匿名卷，加 `-a` 才含具名卷。**若环境存在「容器已删但数据要保留」的具名卷**（如测试数据库）：用户在授权时声明排除名单（或调用参数 `--keep-volumes=<name1,name2,…>`），此时不用 prune，改为枚举 `docker volume ls -q` → 逐名跳过排除项 → 对其余非活跃卷逐个 `docker volume rm <name>`（与契约第 2 条「具名清单删除」同哲学）。**注意**：该枚举路径的删除范围等价于 `prune -a`（含所有失去引用的具名卷），排除名单在使用前必须被视为完备——没把握列全就退回默认 prune 或交互确认。
- **构建缓存**（可选，同样 gated）：`docker builder prune -f`。

事后报告记录 prune 前后 `docker system df` 对比。

## 编译/包管理缓存

按「删了可重建，但重建成本不同」分级。**每类的执行前提是对应 CLI 存在**（`command -v go/pnpm/uv/npm`）；CLI 不存在 → 跳过该行，不算失败。**缓存路径一律通过工具自身查询**（`go env GOCACHE` / `go env GOMODCACHE` / `uv cache dir`），不硬编码 Linux 路径——macOS 上默认缓存目录不同（`~/Library/Caches/...`），硬编码会让阈值探测在 macOS 上静默失效；表中字面路径仅作示意。

| 缓存 | 路径/命令 | 自动模式默认 | 理由 |
|---|---|---|---|
| Go build 缓存 | `go env GOCACHE`（Linux 通常 `~/.cache/go-build`，macOS `~/Library/Caches/go-build`）；`go clean -cache` | **超过阈值（默认 1G）删** | 纯编译产物，重建快；服务全在容器内跑时宿主缓存无用 |
| Go module 缓存 | `go env GOMODCACHE`（通常 `~/go/pkg/mod`）；`go clean -modcache` | **不删** | 重建 = 重新下载全部依赖，慢且耗流量 |
| pnpm store | `pnpm store prune` | 可删 | prune 只删无引用项，安全 |
| uv 缓存 | `uv cache dir`（Linux 通常 `~/.cache/uv`）；`uv cache clean` | 可删 | 可重建 |
| npm 缓存 | `~/.npm`；`npm cache clean --force` | **交互模式才删** | npm 官方不推荐常清 |
| playwright/puppeteer 浏览器 | `~/.cache/ms-playwright` 等，删目录 | **不删（needs-your-call）** | 重下载大且可能破坏测试环境 |

- **Go build 阈值判定**：`du -sk "$(go env GOCACHE)"` 与阈值比较；阈值可参数化（`--go-cache-threshold 1G`，默认 1G）。du 失败 → 保留。
- 交互模式下该表同样出现在预览里（标注每行建议），由用户逐行拍板；自动模式按「自动模式默认」列执行。

## 默认保留清单（按每个枚举根相对保护）

以下六类在 **`ROOTS` 里的每一个根下**都受保护——`/tmp` 下要护，`$TMPDIR` 下同样要护。它们是运行时活套接字/会话目录或用户显式标记，误删会打断正在跑的进程：

| 模式（相对每个 `$root`） | 说明 |
|---|---|
| `$root/claude-*` | Claude 运行时/会话目录，正在跑的 agent 在用。 |
| `$root/codex-*` | Codex 运行时/会话目录，正在跑的 agent 在用。 |
| `$root/tmux-<uid>` | tmux server 的 socket 目录（`<uid>` 为当前用户 id）。 |
| `$root/mcp-*` | MCP server 运行时 socket/目录，**永远跳过**。 |
| `$root/ssh-*` | SSH agent-forwarding socket，删了会断掉 agent 转发。 |
| `$root/vscode-*`、`$root/code-<uuid>` | VS Code / IDE runtime（两种命名同源，合并表述）：删前必须 `ss`/`lsof` + `kill -0` 验活，查不到持有者 → 保留。 |
| `$root/*.keep` | 用户显式标记保留的条目。 |

**关于 tmux socket 的位置（重要，勿再犯旧错）**：tmux 的 socket 目录由 `TMUX_TMPDIR` → `TMPDIR` → `/tmp` 依次推导。因为 **macOS 恒有 `$TMPDIR`**，macOS 上活的 tmux server socket 正常位于 **`$TMPDIR/tmux-<uid>/`**，而**不是** `/tmp/tmux-<uid>`。所以只保护 `/tmp/tmux-<uid>` 会漏掉真正的活 tmux socket——本仓库的 orchestration worker 就跑在 tmux 里，这是最危险的漏网。**必须对每个枚举根都保护 `tmux-<uid>`。** 命中保留清单的条目，若仍要进一步确认，一律用 `ss`/`lsof` + `kill -0` 复核活性，活的坚决保留。

**额外保留模式**：若用户在对话中提到额外要保留的路径/模式，一并纳入保留清单。

## 常见陷阱（「不要做什么」护栏）

- **`mcp-*` 永远跳过**：无论在哪个根下，MCP server 的运行时目录一律不动。
- **`vscode-*` / `code-<uuid>` 先验活再说**：VS Code / IDE 的临时目录已并入默认保留清单同一行；删前必须 `ss`/`lsof` + `kill -0` 确认无活进程，查不到持有者 → 保留。
- **`ssh-*` 是 agent-forwarding socket**：删了会断掉 SSH agent 转发，永远保留。
- **不熟悉的 IDE / 工具目录宁可保留**：遇到不认识的目录名（各类编辑器、语言工具链、构建缓存），当「需要你拍板」，不擅自删。
- **绝不 `rm -rf /tmp/*`**：永远具名清单删除，绝不通配批量删。
- **不清其他用户的文件**：盘点一律 `-user "$(id -un)"` 过滤。
- **`/tmp` 是多用户共享空间（Linux 与 macOS 都是）**：共享开发机上 `/tmp` 常有多个用户的临时文件；跨用户清理禁令在 `/tmp` 上尤其要严格——只清自己属主的条目。macOS 额外之处在于 `/tmp` → `/private/tmp` 是软链，per-user 真实临时目录落在 `$TMPDIR`。
- **不要用不带属主过滤的 `du -sk /tmp/*` 评估自己的占用**：共享机上会把他人文件（可达数十 GB）误算成自己的，导致误判清理收益（实测教训：/tmp 里 30GB 的 review 目录实际属于其他用户）。正确姿势：先 `find "$root" -maxdepth 1 -mindepth 1 -user "$(id -un)"` 拿属主清单，再对清单逐条 `du -sk`。
- **quota 视角**：配额按 uid 统计**全文件系统**的文件（home + /tmp 中属主文件都算），清理评估应以 `quota -s` + 属主过滤的 du 为准。
- **不确定持有者 → 保留**：`ss`/`lsof` 查不到、命令失败、权限不足，一律 KEEP + 标「需要你拍板」，绝不静默删。

## 自动模式事后报告

自动模式执行完毕后，固定输出四块：

1. **已删清单**：按类别汇总（/tmp 条目 / Docker / 编译缓存）+ 逐条路径与大小 + 总回收量。
2. **保留清单**：逐条附原因标签 recent / in-use / needs-call / protected / not-on-allowlist；NEEDS-YOUR-CALL 条目在此列出，留给下次交互处理。
3. **`quota -s` 输出**（命令不存在则标注跳过）。
4. **每根 `df -h "$root"` 前后对比**（Docker 面另附 prune 前后 `docker system df` 对比）。

## 完成后

一次清理执行后：

- 列出**残留条目**（被保留的 / 用户选择不删的），让用户知道当前状态（自动模式下该信息已含在事后报告的保留清单里）。
- 对每个根重新跑 `df -h "$root"`，展示清理前后磁盘用量变化。
- 提醒用户：若本次确认了某些新的「以后也总是要保留」的路径/模式，可以把它们保存到记忆（memory）里，下次清理自动纳入默认保留清单。

## 失败与升级行为

- 任一探测命令（`find` / `du` / `ss` / `lsof` / `df`）失败、超时或报权限错误：把相关条目标注为「保留 / 需要你拍板」，继续处理其余条目，绝不因单点失败而冒进删除。
- **docker daemon 不可达**（`docker info` / `docker system df` 失败）：整个 Docker 块跳过并在报告中标注，不算失败。
- **自动模式绝不升级为交互挂起**：无人值守场景没有人可问——任何不确定 → 保留 + 写进事后报告，留给下次交互处理；这正是自动模式判据收紧的原因。
- BSD 与 GNU 的 `find` / `stat` / `df` / `lsof` 细节有差异：本 skill 的措辞一律偏向安全侧（不确定就保留）。交互模式下无法可靠判定的情形，把决定权交回用户。
- 本 skill 不做破坏性 git 操作、不改系统配置、不引入后台常驻或定时器；「定期」由用户的 loop/cron 外部驱动。
