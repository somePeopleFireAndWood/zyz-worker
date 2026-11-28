# 版本控制

## 提交与推送

- 每个 lane 完成后提交一次，任务完成时再做一次最终提交，不问用户。lane 只做到本地提交；push、开 PR 归主 agent 或集成 lane。
- 配置了 remote 就推送。提交或推送失败时记进 `status.md`，继续任务。
- 每次提交都能编译。几个并行 lane 都往同一个装配文件追加、分开提交编译不过时，合成一次提交，提交信息列出各 lane 的范围。

## 共享工作树上不用的命令

工作树与其它 agent 共享，下面这些会毁掉别人未提交的改动，而未提交的内容 git 里找不回来：

- `git stash push/pop`：可能 pop 到别人的 stash 上。
- `git checkout <file>`、`git restore <file>`：把文件重置到 HEAD，连同别人在这个文件里的改动一起丢掉。
- `git add -A`：把别人的改动带进你的提交。
- force-push、`reset --hard`、改写已发布的历史。

替代做法：

- 回退自己的改动：编辑前 `cp` 备份、之后 `mv` 恢复；或 `git diff > /tmp/<name>.patch` 加 `git apply -R`。
- 读已提交的版本：`git show HEAD:<file>`。
- 提交：只 `git add` 自己改的路径。

`checkout-guard.sh`（PreToolUse hook）会在目标文件有未提交修改时拒绝 `git checkout <file>` / `git restore <file>` 和 `git stash`。工作还是丢了时按 `references/recovery.md` 从会话记录恢复。

## 合并到基线分支

- 只在用户明确指示时做：独立模式下在对话里，编排模式下由编排器在收到 `## Pending Merge Approval` 的令牌后执行，worker 不合并。
- 快速档在合并、打 tag、发布之前问用户。

## 多 worktree 任务

任务涉及多个仓库时（`ZYZ_WORKTREES`，冒号分隔、主仓库在前；或 reuse-runtime-config 块里的 `worktrees:` 行，见 `references/orchestration-mode.md`），每个仓库在自己的 worktree 和分支上：

- 按仓库分别提交、推送、合并。
- `## SubTasks` 的 `Committed:` 每行一个 `<repo>:<sha>`；最终报告的 `## 变更` 按仓库列出分支、提交和推送结果。
- 只写自己名下的 worktree，不写其它 worker 的。
