---
name: git-worktree
description: 当用户或其他 agent 需要对 git worktree 执行 `git worktree add`（创建）、list、move、remove、lock、unlock、prune 或 repair 时使用。调用 `git worktree add` 而未显式给出目标路径时，提供默认目标路径 `~/.zyz-worker/worktrees/${repo}/${branch}`。还覆盖未被 git 跟踪、却是必需的本地文件（例如 `conf/test.yaml`、`.env`）——新建的 worktree 里没有它们，必须从主工作树复制过来。
---

# Git Worktree

## 何时使用本 skill

只要当前对话需要创建、查看、移动、删除、锁定、解锁、prune 或修复 git worktree，就加载本 skill。典型触发场景是用户（或上级 agent）说出类似"给分支 X 开一个 worktree""创建一个 worktree""列出所有 worktree""删除位于 … 的 worktree"的话，或以其他方式提到 `git worktree` 子命令。

当 agent 需要为新建的 worktree 找一个稳定、约定俗成的位置，而不是在仓库旁边或 `/tmp` 下临时编一个路径时，本 skill 也是正确的入口。

## `git worktree add` 的默认位置

当用户没有为 `git worktree add` 显式指定目标路径时，按如下规则推导目标：

```text
~/.zyz-worker/worktrees/${PROJECT}/${BRANCH}
```

其中：

- `PROJECT = basename "$(git rev-parse --show-toplevel)"`——原样使用。不要去掉 `.git` 后缀，也不要做任何清洗。仓库根目录名字面上就是 `cool.git` 时，项目名就是 `cool.git`。
- `BRANCH` 是用户给出或 agent 选定的分支名，原样使用。分支名里含 `/` 时（例如 `feature/foo`），它自然形成多级子目录：`~/.zyz-worker/worktrees/${PROJECT}/feature/foo`。不要把 `/` 替换成其他字符。
- `$HOME` 由 shell 解析。不要硬编码家目录的绝对路径。

用户已显式给出目标路径时，原样使用该路径——不要悄悄把它改写成默认位置。

无论目标来自默认规则还是来自用户，调用 `git worktree add` 之前都要先用 `mkdir -p "$(dirname "$TARGET")"` 创建父目录。目录已存在时 `mkdir -p` 什么也不做，而 `git worktree add` 本身仍要求 `$TARGET` 不存在，所以这一步不会有覆盖现有 worktree 的风险。

## 子命令

### add

`git worktree add` 的操作步骤：

1. 解析仓库根目录和项目名。用户已提供显式目标路径时，跳过默认路径推导，但下面的冲突预检和 `mkdir -p` 步骤照常保留。用户未提供目标时，按默认规则推导 `$TARGET`。
2. 运行下面两项轻量预检（`test -e`，以及对 `git worktree list --porcelain` 做 `grep -Fxq` 匹配）。任一预检命中，就停下来并给出具体的下一步（换路径、运行 `git worktree remove "$TARGET"`，或加 `--force`）；不要让用户去读 git 的原始报错。
3. 用 `mkdir -p "$(dirname "$TARGET")"` 创建父目录——默认路径和用户提供的路径都适用。
4. 运行 `git worktree add "$TARGET" "$BRANCH"`。分支尚不存在时，由 agent 根据用户意图决定是加 `-b <branch>`（新建分支）还是用 `--detach`（游离 HEAD）。
5. `add` 成功后输出 `$TARGET`，以便调用方 agent 在需要时 `cd` 进去。不要自动 `cd` 进新 worktree。

伪代码（POSIX shell）：

```bash
# Only derive $TARGET this way if the user did not specify a target.
REPO_ROOT="$(git rev-parse --show-toplevel)" \
  || { echo "not in a git worktree (or in a bare repo)"; exit 1; }
PROJECT="$(basename "$REPO_ROOT")"
BRANCH="<branch name given by the user or chosen by the agent>"
TARGET="$HOME/.zyz-worker/worktrees/$PROJECT/$BRANCH"

# Normalize: resolve $TARGET to an absolute path before pre-checks so relative
# paths, `~`, or `./..` cannot slip past the duplicate check. If the parent
# directory does not yet exist (common on the first default-path `add`), keep
# $TARGET as-is — the later `mkdir -p` will create the directory tree and the
# pre-checks below still operate on the unnormalized value.
PARENT_DIR="$(dirname "$TARGET")"
if [ -d "$PARENT_DIR" ]; then
  TARGET="$(cd "$PARENT_DIR" && pwd)/$(basename "$TARGET")"
fi

# Pre-check 1: any existing file/dir at $TARGET is a conflict.
test -e "$TARGET" && { echo "target exists: $TARGET"; exit 1; }

# Pre-check 2: exact whole-line match against existing registered worktrees.
git worktree list --porcelain | awk '/^worktree /{print $2}' \
  | grep -Fxq "$TARGET" && { echo "already registered: $TARGET"; exit 1; }

# Ensure the parent directory exists (no-op if already present; runs for both
# the default path and any user-supplied path).
mkdir -p "$(dirname "$TARGET")"

git worktree add "$TARGET" "$BRANCH"
```

关键不变量：

- `$BRANCH` 原样嵌入路径；分支名里的 `/` 会成为目录分隔符，由 `mkdir -p` 创建中间目录。
- 不要替换 `/`，也不要去掉 `refs/heads/` 前缀——输入的是分支名，不是 ref。
- `$HOME` 由 shell 解析；本 skill 中绝不硬编码家目录的绝对路径。
- 查重步骤先把 `$TARGET` 规范化为绝对路径（仅当父目录已存在时；否则使用未规范化的值），再对 `git worktree list --porcelain | awk '/^worktree /{print $2}'` 的输出做整行精确匹配 `grep -Fxq`。
- `git rev-parse --show-toplevel` 以非零退出（不在 git worktree 中，或处于 bare 仓库）时，立即中止。不要回退到 `pwd`，也不要把空字符串喂给 `basename`；上面的 `||` 守卫就是为了防止这种情况。
- `PROJECT` 就是 `basename` 的字面结果，原样使用。不去 `.git` 后缀，不做清洗。

### list

运行 `git worktree list`（可加 `--porcelain` 得到机器可读的输出），列出当前仓库登记的所有 worktree。

### remove

运行 `git worktree remove "$TARGET"` 删除一个 worktree。如果该 worktree 的工作树里还有脏数据或未跟踪数据导致无法删除，加 `--force` 跳过安全检查。

### move

运行 `git worktree move "$SOURCE" "$DESTINATION"` 迁移一个现有 worktree。目标位于尚不存在的目录中时，先用 `mkdir -p "$(dirname "$DESTINATION")"` 创建父目录，做法与 `add` 流程一致。

### lock

运行 `git worktree lock "$TARGET" [--reason <text>]`，防止 worktree 被自动 prune（适用于位于可移动介质上、或其他暂时无法访问路径上的 worktree）。

### unlock

运行 `git worktree unlock "$TARGET"` 解除之前加的锁，使该 worktree 可以再次被正常 prune 或删除。

### prune

运行 `git worktree prune` 清理那些工作目录已在 git 之外被删掉的 worktree 的管理元数据。若有多个 worktree 被外部删除、在 `.git/worktrees/` 中留下残余元数据，运行 `git worktree prune` 使状态重新一致。

### repair

主仓库或某个 worktree 被移动后，运行 `git worktree repair [<path>...]` 修复主仓库与各 worktree 之间的双向链接。

## 未被跟踪但必需的文件（缺失时复制）

worktree 里只会有所检出分支上被 git 跟踪的内容。项目构建、启动或测试需要、却有意不纳入 git 管理的文件——例如 `conf/test.yaml` 这样的本地配置、`.env`、列在 `.gitignore` 中的凭据或 fixture 文件——因此在新建的 worktree 里**并不存在**，尽管它们在主工作树里存在，而且一切"看起来"都已检出。

规则：在 worktree 内工作时遇到这类缺失文件，就从主工作树把它复制到 worktree 中相同的相对路径，然后继续。不要让用户手动放置，也不要靠修改代码或测试、让它们去别处找文件来绕过。

按需触发，不要预先处理。不要把所有被 gitignore 的东西批量复制过去——那样会把 `node_modules/`、`.venv/`、`target/`、`dist/` 和构建缓存一并卷进来。只有当具体信号指向具体路径时才复制：

- 运行/构建/测试因文件缺失报错而失败（`no such file or directory`、`config not found`、加载器报出了具体路径）；
- 配置或代码引用的路径在 worktree 中不存在，但在主工作树中存在。

操作步骤：

```bash
# Main work tree = first entry of `git worktree list --porcelain`.
MAIN_ROOT="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
REL="conf/test.yaml"   # path relative to the repo root, from the error message

# 1. It must exist in the main work tree.
test -f "$MAIN_ROOT/$REL" || { echo "not present in main work tree either: $REL"; exit 1; }

# 2. It must be untracked there. A tracked path missing from the worktree is a
#    checkout/branch problem, not a missing local file — copying would mask it.
git -C "$MAIN_ROOT" ls-files --error-unmatch "$REL" >/dev/null 2>&1 \
  && { echo "tracked by git: $REL — investigate the checkout, do not copy"; exit 1; }

# 3. Never overwrite what the worktree already has.
test -e "$REL" && { echo "already present in worktree: $REL"; exit 0; }

# 4. Copy, preserving mode and timestamps.
mkdir -p "$(dirname "$REL")"
cp -p "$MAIN_ROOT/$REL" "$REL"
echo "copied untracked file from main work tree: $MAIN_ROOT/$REL -> $(pwd)/$REL"
```

关键不变量：

- **复制，不要建软链。** 指回主工作树的软链会让 worktree 中的写入泄漏到主工作树，以及共享它的所有其他 worktree，破坏 worktree 存在的意义——隔离。只有用户明确要求时，或针对大型只读缓存，才使用软链。
- **复制文件，不复制依赖树。** 缺失的如果是已安装的依赖目录或构建产物，就在 worktree 内安装/构建，而不是复制。只复制小型的配置、fixture 和凭据文件。
- **每次复制都要报告。** 打印一行写明源和目标（如上所示），让用户知道这个 worktree 已不再是纯粹的检出；任务属于长期运行时，还要把它记进任务状态文件。悄无声息的复制会制造"worktree 里能跑、CI 里挂掉"的谜案。
- **复制过来的机密保持未跟踪。** 这些文件被 gitignore 是有原因的；复制后要确认 `git status --porcelain` 没有列出该路径（即 worktree 的 `.gitignore` 同样覆盖了它），并且绝不暂存或提交它。
- **主工作树里也没有，就停下。** 不要根据 `.example` 模板或凭猜测凭空造出这个文件；报告情况，让用户来提供。
- 复制过来的文件属于未跟踪数据，因此之后对该 worktree 执行 `git worktree remove` 时需要加 `--force`（见 `### remove`）。

## 失败模式

- **目标路径已存在。** `$TARGET` 处的任何文件或目录（包括空目录）都会触发预检 1。不要悄悄覆盖；报告冲突，并建议换一个路径或显式加 `--force`。若漏过了预检，git 的典型原始报错是：`fatal: '<path>' already exists`。
- **目标路径已是登记过的 worktree。** 规范化后的 `$TARGET` 与 `git worktree list --porcelain` 的 worktree 条目中某一行完全一致时，预检 2 命中。建议先执行 `git worktree remove "$TARGET"`，或换一个路径。git 的典型原始报错：`fatal: '<path>' is already checked out at '...'`。
- **不在 git 工作树内。** `git rev-parse --show-toplevel` 以非零退出。中止，并告诉用户先 `cd` 到一个 git 工作树再重试。不要回退到 `pwd`。
- **bare 仓库。** 在 bare 仓库中，`git rev-parse --show-toplevel` 同样以非零退出（stderr 包含 `fatal: this operation must be run in a work tree`）。这种情况下，请用户提供显式目标路径，而不是依赖默认规则。
- **新建的 worktree 无法构建、启动或运行测试。** 通常是因为某个未跟踪的本地文件只存在于主工作树中（`conf/test.yaml`、`.env`、本地 fixture）。不要断定分支坏了；针对报错指出的具体路径，执行上面的「缺失时复制」流程。
- **非法分支名。** 本 skill 不会清洗含有 git 本身拒绝的字符的分支名。`git worktree add` 会把底层的 git 错误暴露出来。注意，在 git 拒绝该分支名之前，`mkdir -p` 可能已经创建了无害的中间目录（例如 `<project>/..`）；这是预期的副作用，不是 bug。

## 长期运行注意事项

git worktree 提供的是隔离的执行检出，不是记录任务状态的地方。一个任务可以持有多个 worktree（它涉及的每个仓库一个），但它们都只是执行隔离，不是状态。任务进度、决策和阻塞项要持久化到 `.zyz-worker/tasks/<task-id>/` 下的任务状态文件中（或派发方 agent 提供的路径）。参见 [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md)。

**创建 worktree 不会移动 watchdog 的锚点。** `execute-task` 的 watchdog 通过 **session cwd** 下的 `.zyz-worker/current-task` 定位活动任务——而本 skill 刻意不 `cd` 进新 worktree，所以 session cwd 保持原处。如果任务在这里创建的 worktree 中运行，就把指针保留在 session cwd 下，并在指针里写指向任务目录的**绝对**路径。没有回退机制：解析器刻意不搜索兄弟 worktree（早先的回退机制曾把会话挂到并发会话的任务上——issue #18），所以一个 session cwd 看不到的指针，会让整个 watchdog 层失效，而表面上看起来一切正常。§1 的"确认已启用"检查正是用来发现这种情况的。
