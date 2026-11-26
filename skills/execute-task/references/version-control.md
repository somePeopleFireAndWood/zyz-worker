# 版本控制

`SKILL.md` `## 版本控制` 的细则。zyz-worker 的目标是依据已批准的设计自主完成整个任务，所以版本控制步骤自行执行，不阻断工作流；自主权只覆盖普通的 `git commit` 和 `git push`，不包括破坏性操作和合并到基线分支。

## 自主提交与推送

- 每个 lane（SubTask）完成后提交一次，整体任务完成时再做一次最终提交，不停下来问用户。lane 只做到本地提交；push、开 PR、合并由主 agent 或集成 lane 负责（`SKILL.md` `## 并行模型`）。
- 配置了 remote/upstream 时自主推送，不询问。
- 提交或推送失败（没有 remote、认证问题、hook、冲突或其他原因）时，把失败记入状态文件并继续任务；它不是阻塞项。
- 每次提交都要能编译：bisect、CI 和回滚都依赖它。"一个 lane 一次提交"是为了可读性的约定。多个并行 lane 都往共享装配文件追加、按 lane 分开提交会产生无法编译的提交时，提交最小的可编译单元：一次提交覆盖这些 lane，提交信息列出每个 lane 的范围，并把这一偏离记入状态文件。

## 破坏性操作

- 不自行 force-push、`reset --hard` 或改写已发布的历史。
- **共享工作树上的 `git stash push/pop` 是破坏性的。** 可能存在另一个 agent 的 stash，一次 pop 可能落到错误的状态上（一个有冲突的 `go.mod` 仍然能**构建**，但 `go test` 会在解析模块时失败，看起来就像"他们的代码坏了"）。临时搁置改动用 `git diff > /tmp/<name>.patch` + `git apply -R`。
- **共享工作树上的 `git checkout <file>` / `git restore <file>` 同样是破坏性的。** 它们重置到 HEAD，删掉该文件中所有 agent 的未提交工作，而从未提交过的内容不在任何 git 恢复机制里（没有 reflog、没有 stash、没有 fsck）——一次真实事故就这样丢掉了一段约 5000 字符的安全防护代码，而 `go build` 依然是绿的。只回退你自己的改动，用编辑前做好的备份副本（`cp` 备份 + `mv` 恢复），或用 `git apply -R` 回退你自己的 diff；读取已提交的版本用 `git show HEAD:<file>`。PreToolUse hook `checkout-guard.sh`（L6）会在目标文件有未提交修改时拒绝这种写法，但给角色的指令本来就应该只给安全做法。
- 变异、重构探测这类临时改生产文件的操作，同样从变异前做好的备份副本恢复，逐文件对照备份验证（而不是看"`git status` 干净"，共享工作树本来就不会干净）；无法验证的恢复作为事故报告。
- 工作还是丢了时，按 `references/recovery.md` 从会话记录恢复。

## 合并到基线分支

- 合并只在用户明确指示时做：独立模式下通过对话，编排模式下通过 `## Pending Merge Approval` 中对应的令牌。自主权不涵盖合并到基线分支。合并仍然遵守不 force-push、不改写历史。
- 快速档在合并、打 tag、发布之前等用户（`SKILL.md` `## 档位`）。
- 编排模式下由编排器执行合并，worker 不执行，以免两层同时写基线分支。

## 多 worktree 任务

worker 管理不止一个 worktree 时（`ZYZ_WORKTREES`，冒号分隔、主仓库在前；或带内 reuse-runtime-config 块里覆盖它的 `worktrees:` 行——见 `references/orchestration-mode.md`），每个仓库在自己的 worktree 中、自己的分支上：

- 按仓库独立提交和推送：一个 lane 在它碰过的每个仓库中各提交一次；最终交付提交也按仓库分别创建。
- 用户指示的合并按仓库进行：每个仓库的分支合并到该仓库的基线分支。
- 交付报告按仓库拆分：最终报告的 `## 变更` 列出每个仓库的分支 / 提交 / 推送结果；`## SubTasks > Committed` 对多仓库 lane 分多行记录 `<repo>:<sha>`。
- 隔离存在于 worker 之间：worker 对自己的所有 worktree 有完整写权限，不写入其他 worker 的 worktree。没有 worktree 集合时，行为与单 worktree 相同。
