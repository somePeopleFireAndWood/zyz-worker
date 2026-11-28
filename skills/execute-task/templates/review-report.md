# 评审报告

## 结果

- 评审者: （`reviewAgent`；跨 harness 评审会话写 `cross-harness:<harness>`）
- 派发标记: review-point=<id> round=<n> mode=<full|incremental>（原样回显；派发里没有时写 `missing`）
- Tier: <fast | standard | strict>（回显派发里的 `Tier:` 行）
- 状态: <changes-requested | no-changes-needed>（当且仅当下面至少有一条 `blocking` 时为 `changes-requested`）
- 评审对象: （文件或 diff 基准）

## 场景走查

<!-- mode=full。设计 `## 场景` 的每一条一行（快速档用 `change-note.md` 的"怎么验证"）；实现评审附了 `impl-notes.md` 时，属于本评审点的实现备注每条加一行（`实现备注 N-x`：已落地 / 未落地）。mode=incremental 写 n/a。 -->

| 场景 / 实现备注 | 走通 / 走不通（已落地 / 未落地） | 位置 |
|---|---|---|

## 修复落地核实

<!-- mode=incremental；mode=full 写 n/a。上一轮被接受的每条 blocking 一行；没落地的沿用原编号，在 ## 发现 里仍记 blocking。修复 diff 带出的新问题直接记进 ## 发现。 -->

| 上轮编号 | 状态（已落地 / 部分落地 / 未落地） | 证据 |
|---|---|---|

## 发现

<!-- 每条发现都记在这里，等级只决定去向：`blocking` / `non-blocking:normal` / `non-blocking:contrived`，含义见 reviewAgent `## 等级`。`blocking` 写出走到它的那条正常流程和出错的那一步，或它违背的设计条款。来源从第 2 轮起填 `原有` 或 `上一轮修订带出`，第 1 轮写 `-`。要用户决定的在等级后加 `requires-user-decision` 并写出选项。没落地的实现备注按同样的等级记在这里。 -->

| # | 等级 | 来源 | 位置 | 走到它的流程与出错的一步 |
|---|---|---|---|---|

## 补证请求

<!-- 结论缺命令、输出或位置。不算发现，不影响状态；作者补上，不开新一轮。没有写 none。 -->

| # | 缺什么 | 补在哪里 |
|---|---|---|

## 已复核的被拒绝建议

<!-- mode=incremental：上一轮被拒绝或降级的每条 blocking 一行；没有写 none。 -->

| 上轮编号 | 结论（认可拒绝 / 重新提出 → ## 发现 #<n>） | 依据 |
|---|---|---|
