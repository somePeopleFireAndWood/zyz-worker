# Automation TODO

本文档跟踪 zyz-worker 仓库可做但尚未做的自动化、校验、CI、打包项。按"何时做"分层。立即不做的项也保留，避免后续重复讨论。

来源：多端插件结构改造讨论（2026-05），决定先把结构改对，自动化按阶段引入。

## 现在不做

结构改造完成后只做人工验证：

- 跑一遍 `README.md` 给出的两种用法（本仓库内 `/code-development`、`--plugin-dir .` 后 `/zyz-worker:code-development`）。
- `find` / `grep` 检查 `subagents/` 引用已清空。

## 阶段一：第一次外部分发前

最低发布门槛。把这三项实现并跑通后再向他人分发或上 marketplace。

### A. 插件结构 lint

- 路径：`scripts/validate-plugin.sh`
- 检查项：
  - `.claude-plugin/plugin.json` 存在且 JSON 可解析
  - `.codex-plugin/plugin.json` 存在且 JSON 可解析
  - `agents/*.md` 至少一份，且每份带 YAML frontmatter（含 `name`、`description`）
  - `commands/code-development.md` 存在
  - `skills/<name>/SKILL.md` 全部存在
  - 两个 `plugin.json` 的 `name` 字段使用 kebab-case
  - 文档中所有 `@path` 引用对应文件真实存在（先覆盖 `commands/` 和 `.claude/commands/` 下的 `.md`）
- 依赖：`bash` + `jq`
- 预估：30-60 行 shell

### D. SKILL.md frontmatter 校验

- 并入 `scripts/validate-plugin.sh`
- 检查项：
  - 每个 `skills/*/SKILL.md` 都有 `name` 和 `description` frontmatter 字段
  - `name` 字段值等于其所在目录名
- 预估：~15 行

### F. 打包脚本

- 路径：`scripts/pack.sh`
- 行为：
  - 产出 `dist/zyz-worker-<version>.zip`，版本从 `.claude-plugin/plugin.json` 的 `version` 读
  - 自动跳过 `.git`、`dist`、`node_modules`、`docs/superpowers/`、`.claude/settings.local.json`
  - 给 `claude --plugin-dir foo.zip` 和 marketplace 发布用
- 预估：~10 行

## 阶段二：接受外部 PR 后

外部贡献会带来漂移，靠 CI 兜住。

### B. 两端清单字段一致性

- 并入 `scripts/validate-plugin.sh`
- 校验 `.claude-plugin/plugin.json` 与 `.codex-plugin/plugin.json` 的以下字段必须一致：`name`、`version`、`description`、`author`、`license`
- 预估：~20 行 jq diff

### C. agents/ 和 .claude/agents/ 镜像校验

- 并入 `scripts/validate-plugin.sh`
- 校验：
  - 对每个 `agents/<x>.md`，必须存在 `.claude/agents/<x>.md`
  - 两份文件的 frontmatter 字段值完全一致（`name`、`description`、`tools`）
  - `.claude/agents/<x>.md` 的正文必须是单行 `@agents/<x>.md`
- 预估：~20 行（awk 或 python）

### E. README / CLAUDE.md 路径检查

- 并入 `scripts/validate-plugin.sh`
- 用 grep 抓出文档中所有反引号包裹的路径片段（如 `\`skills/code-development/SKILL.md\``），验证文件真实存在
- 限定扫描范围：`README.md`、`CLAUDE.md`、`docs/conventions/*.md`
- 预估：~30 行

### G. GitHub Actions CI

- 路径：`.github/workflows/validate.yml`
- 触发：push 与 PR
- 动作：跑 `scripts/validate-plugin.sh`，任一项失败则 fail
- 预估：~20 行 yaml

## 大概不做

成本/收益不划算，除非具体需求出现。

### H. 角色/skill 生成器

- 例如 `scripts/new-agent.sh <name>` 自动创建 `agents/<name>.md` 和 `.claude/agents/<name>.md` 镜像
- 当前角色只有 3 个，新增频率极低
- 真要加角色时手动创建 + 跑 lint 即可

### I. 端到端集成测试

- 例如 spawn `claude --plugin-dir . -p "/zyz-worker:code-development noop"` 验证真能调度
- 需要真实 LLM 调用或复杂 mock，CI 成本高
- 仅在 skill 行为本身出现回归风险时再考虑

## 维护

- 阶段一/二的每项完成后，在对应行尾追加 `（已完成 YYYY-MM-DD，commit <sha>）`
- 新增自动化想法先加到本文档的"大概不做"段，定期回顾是否升级
