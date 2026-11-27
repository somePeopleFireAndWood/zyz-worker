# 任务状态

本文件只放当前状态，文件名 `status.md` 不能改（watchdog 按它解析）。用户决定记 `decisions.md`，给实现者的备注记 `impl-notes.md`，lane 报告在 `lanes/<id>.md`，重启、档位变更和已关闭的发现记 `log/`。

## 元数据

- 任务 ID:
- 任务名称:
- 设计文档: （设计文档路径，不列评审历史文件；快速档写 `change-note.md`）
- Current Phase:
- Tier:
<!-- Current Phase 取值：design / implementation / testing / review / delivery / observing / awaiting-confirmation / done。
     Tier 取值：fast / standard / strict；之后的变更用 `review-round.sh tier` 写入。留空 = 无档位。 -->
- 创建时间:
- 更新时间:

## 总目标

（原样记录用户完整的最终目标。）

## 进度

- 已完成:
- 进行中:
- 待处理:
- 阻塞:

## Agent State

- 主 agent:
- lanes: （lane → 当前在做什么；没有写 none）
- implementationAgent:
- testAgent:
- reviewAgent:

<!-- 声明行由 `hooks/scripts/expect.sh` 写入本节，不手写。expect.sh 写出来的行形如：
- Expect: key=recon; kind=wait; at=<unix>; ref=-; reason=<到时看什么>
- Tune: status-stale-sec=<n>; no-executor-sec=<n>; remind-sec=<n>; silence-sec=<n>
-->

## 设计评审

- 最近一次评审结果:
- 设计批准记录: （用户原话要点 + 时间，或事先给出的跳过本次闸门的指令原文；快速档记改法确认。空 = 未批准，不进入实现。）

## SubTasks

（lane 即 SubTask，每个 lane 一块；不拆分时留空。字段名保持原样，hook 按 `- SubTask ID:` / `- Committed:` 解析。）

- SubTask ID:
- 摘要:
- 文件白名单:
- Coded: （实现完成后为 true）
- Tested: （测试通过且负对照有记录后为 true）
- Reviewed: （本 lane 的评审点有 `Review-Close` 后为 true）
- Committed: （commit sha；多仓库每行一个 `<repo>:<sha>`）
- 报告: （`lanes/<id>.md`）

## 并行资源租约

（两个以上会跑测试的 lane 并发之前填，每个 lane 一行。）

- lane | 端口 | 测试数据库

## 评审收口

<!-- 本节只放 `review-round.sh` 写入的行，不手写。示例：
- Review: point=design-main; stage=design; kind=main; round=3; started=1764120000; blocking=2; rejected=0; behavior=2; induced=1; pending=0; delta=+12/-30
- Review-Grant: point=impl-st2; round=4; at=1764200000; reason=用户批准再开一轮
- Review-Check: point=impl-st2; round=3; outcome=continue; at=1764190000; reason=严格档收口检查：blocking 逐轮减少
- Review-Close: point=design-main; round=3; outcome=residual; at=1764123000; reason=用户：剩余 2 条接受为遗留问题
- Review-Close: point=impl-st1; round=2; outcome=passed; at=1764210000; reason=第 2 轮 blocking=0、rejected=0、pending=0
-->

## 发现台账

（只放未关闭的发现，每条一行；评审点关闭后移到 `log/review-ledger.md`。）

- <评审点>#<N> 一句话 | 来源 | 接受或拒绝 + 理由 | 派给谁 | 落在哪里
- 跨 harness 运行: （评审点 | 轮次 | harness | 状态 | 报告路径）

## 最终汇总测试

（类别来自设计 `## 测试计划`，每个类别一行；快速档只填负对照和测试命令。）

- 单元测试: (ran: <result> | skipped: <reason>)
- 回归测试: (ran: <result> | skipped: <reason>)
- E2E: (ran: <result> | skipped: <reason>)
- 负对照:
- 测试命令:

## 最终汇总评审

- 评审者结论:
- 跨 lane 发现:

## 交付前检查清单

1. `## 总目标` 没被收窄。
2. 测试计划各类别跑了，或写明了跳过理由；负对照有记录。
3. 每个已登记的评审点都已关闭（`review-round.sh status`）。
4. 没有未处置的 blocking。
5. `decisions.md` 里没有仍在等回答的问题。
6. 合并、打 tag、发布之前问用户。

## 下一步行动

- 下一步:
