# 任务状态

本文件只放当前状态，是唯一必需的总状态文件，文件名 `status.md` 不能改（watchdog 按它解析）。其它记录放在别处：用户决定 → `decisions.md`；给实现者的备注 → `impl-notes.md`；重启与恢复、档位变更、已关闭的发现 → `log/restarts.md`、`log/tier.md`、`log/review-ledger.md`；lane 报告 → `lanes/<id>.md`。

## 元数据

- 任务 ID:
- 任务名称:
- 设计文档: （标准档、严格档写设计文档路径，不列评审历史文件；快速档写 `change-note.md`）
- Current Phase:
- Tier:
<!-- Current Phase 取值：design / implementation / testing / review / delivery / observing / awaiting-confirmation / done。observing = 主体已交付、保留窗口做定时观察，用 expect.sh 排定下一次检查。
     Tier 取值：fast / standard / strict，任务开始时填写；之后的变更用 `review-round.sh tier` 写入（同时记 `log/tier.md`），降档由用户决定。留空 = 无档位，hook fail open。 -->
- 创建时间:
- 更新时间:

## 总目标

（原样记录用户完整的最终目标，或写一份忠实的摘要。任务结束时完全达成它：不收窄、不推迟、不用占位代替。）

## 进度

- 已完成:
- 进行中:
- 待处理:
- 阻塞:

## Agent State

- 主 agent:
- lanes: （具名 lane teammate → 当前在做什么；没有则 none）
- implementationAgent:
- testAgent:
- reviewAgent:

<!-- 声明由 `<plugin-root>/hooks/scripts/expect.sh` 写入，不要手写；watchdog 按声明判断任务为什么安静。expect.sh 写出来的行形如：
- Expect: key=recon; kind=wait; at=<unix>; ref=-; reason=<到时看什么>
- Tune: status-stale-sec=<n>; no-executor-sec=<n>; remind-sec=<n>; silence-sec=<n>
kind：wait = 某样东西会在 at 之前推进任务（--ref 绑定后台任务 id）；user = 停下来等用户（--watch 时问题挂着、继续推进别的）；resident = 常驻但不推进任务的后台任务，不算执行者。tune 只能放宽阈值。旧格式 `- Waiting On:` / `- Awaiting-User:` 行仍然有效。细则见 SKILL.md `## Watchdog 强制层`。 -->

## 设计评审

- 最近一次评审结果: （评审点 + 轮次 + 结论；轮次明细看 `## 评审收口`）
- 设计批准记录: （快速档记改法确认，原文要点同时写进 `change-note.md`。记用户原话要点 + 时间，或事先给出的跳过本次闸门的指令原文；空 = 未批准，不进入实现。已批准方案有实质改动时重新记录。）

## SubTasks

（拆成 lane 时填写，lane 即 SubTask；不拆分时留空。每个 lane 一块，字段名保持原样，hook 按 `- SubTask ID:` / `- Committed:` 解析。）

- SubTask ID:
- 摘要:
- 文件白名单:
- Coded: （实现完成后为 true）
- Tested: （测试通过，且记录了档位要求的证据后为 true：各档都要负对照（新测试在旧代码上失败）；标准档另要设计标为"关键"的机制的被杀死变异；严格档每个声称覆盖的机制都要）
- Mutations: （机制 → 变异 → KILLED/SURVIVED，已恢复且逐字节一致；无要求时写 n/a）
- Reviewed: （本 lane 的评审点有 `Review-Close` 后为 true，见 `## 评审收口`；非阻断发现已落地或已登记）
- Frozen At: （派发评审时的冻结时间戳 + 文件集）
- Committed: （commit sha；多仓库每行一个 `<repo>:<sha>`；共享装配文件一起提交记 `shared:<sha> (STx+STy)`；失败记原因，不阻断）
- 报告: （`lanes/<id>.md`）
- 备注:

共享文件热点: （并行 lane 往同一批装配文件追加内容时，派发时声明：文件 → lane → 插入区域；没有则留空）

## 并行资源租约

（≥2 个会跑测试的 lane 并发之前填写，每个 lane 一行。端口冲突会悄悄测到别人的服务，所以分配完整端口组，含 metrics/pprof。）

- lane | 端口（HTTP/gRPC/metrics/pprof） | 测试数据库 | 负责生成的产物（每批恰好一个 lane 重建共享 bundle/dist）

## 测试

- 最近一次: （命令 | 数据库 / 端口 | 进程启动时间 vs 最新源文件 mtime | 结果，附实际用例数 / 包数 vs 基线 | 失败的归因：我方 / 工具 / 并发编辑 / 真实回归 + 证据）

## 评审收口

<!-- 本节只放 `review-round.sh` 写入的机器行（登记、轮次、额外轮授权、收口检查、关闭），不要手写，也不要放表格；命令、上限和闸门见 SKILL.md `## 评审收口`。到上限或提前停、交用户三选一时，用户的选择记入 `decisions.md`。真实的行由脚本追加在本节，不在注释里。`blocking` = 本轮被接受的 blocking 条数，`rejected` = 评审者报为 blocking、被裁决者拒绝或降级的条数，`induced` = 本轮 blocking 里由上一轮修订带出的条数，`pending` = 这个评审点此刻仍在等用户回答的 blocking 条数（含更早轮次提出的），`delta` = design 评审点本轮评审的修订量（+增行/-删行，第 2 轮起）；`passed` 关闭要求最近一轮 blocking=0、rejected=0 且 pending 不大于 0。示例：
- Review: point=design-main; stage=design; kind=main; round=3; started=1764120000; blocking=2; rejected=0; behavior=2; induced=1; pending=0; delta=+12/-30
- Review-Grant: point=impl-st2; round=4; at=1764200000; reason=用户批准再开一轮：剩余 blocking 涉及数据删除
- Review-Check: point=impl-st2; round=3; outcome=class-fix; at=1764190000; reason=同一类缺陷第三次出现，改做类级修复
- Review-Close: point=design-main; round=3; outcome=residual; at=1764123000; reason=用户：剩余 2 条接受为遗留风险
- Review-Close: point=impl-st1; round=2; outcome=passed; at=1764210000; reason=第 2 轮 blocking=0、rejected=0、pending=0
-->

## 发现台账

（只放当前未关闭的发现，来源 reviewAgent / 跨 harness / PR 评审都在这张表里。被接受的发现 `dispatched-to` 为空就是还没派发，先派发再开下一轮。被拒绝的发现带着理由留在表里，直到所在评审点关闭；评审点关闭后，它的行整行移到 `log/review-ledger.md`。）

- 跨 harness 运行: （每次一行：评审点 | 轮次 | harness | 状态 ok / empty / failed / timeout / none / disabled / skipped | tree-stable | 报告路径；非 ok 照记，不阻断）

| finding | 来源 | verdict + evidence | dispatched-to + when | landed (commit/file) | verified-by |
|---|---|---|---|---|---|

<!-- finding 写 `<评审点>#<N> 一句话`；来源写 reviewAgent / 跨 harness:<harness> / PR:<URL 或编号>；跨 harness 和 PR 的发现先独立核实再裁决。 -->

- 补证请求: （评审点#N | 缺什么 | 作者 | 核对结果；补证不开新的一轮）
- 记入评审历史的非阻断发现: （设计评审的 `non-blocking:normal` 发现都记在评审历史文件、不进设计正文：条数 + `<design-doc-basename>.review-history.md`；其中写进 `impl-notes.md` 的条数）
- 遗留风险清单: （`residual-risks.md` 路径 + 按级别计数；或 none）

## 最终汇总测试

（标准档、严格档：全部 lane 完成后填写。类别来自设计 `## 测试计划`，单元 / 回归 / e2e 是底线；设计点名的额外类别各占一行，不并入相近栏位。快速档只填 `负对照` 和 `测试命令`。）

- 单元测试: (ran: <result> | skipped: <reason>)
- E2E: (ran: <result> | skipped: <reason>)
- 回归测试: (ran: <result> | skipped: <reason>)
- 压力测试: (ran: <result> | skipped: <reason> | n/a: no perf/capacity risk)
- <设计测试计划中的类别>: （每个额外类别一行）
- 负对照: （哪些测试在旧代码上失败、新代码上通过）
- 变异证据: （标准档：标为"关键"的机制；严格档：每个带覆盖声明的类别；killed/survived 计数，或 `none: <reason>`）
- 测试命令: （附坐标：数据库 / 端口 / 进程与源码的新鲜度）
- 失败用例:

## 最终汇总评审

（标准档、严格档：汇总测试收敛后填写；每个维度记 `covered` 或 `not-covered: <reason>`，有一个没登记，评审就没有结束。快速档多 lane 时只填 `契约一致性检查`，单 lane 时整节写 n/a。）

- 覆盖 — 设计一致性: (covered | not-covered: <reason>)
- 覆盖 — 正确性: (covered | not-covered: <reason>)
- 覆盖 — 测试质量: (covered | not-covered: <reason>)
- 覆盖 — 回归风险: (covered | not-covered: <reason>)
- 覆盖 — 风险专项: （设计 `## 风险` 点名的每个维度一行；或 `n/a: no such risk recorded`）
- 契约一致性检查: （快速档多 lane）
- 未收齐的分步交付: （none，或 `log/restarts.md` 里已承诺、尚未收到的每一期；未收齐算未覆盖）
- 评审者结论:
- 跨 SubTask 发现:

## 状态新鲜度

- 按代码核对: （恢复时最后一次与 `git log` / `lanes/*.md` / 固定包观察器交叉核对的时间；哪些字段是从提交或会话记录重建的；仍未解决的分歧及以哪方为准）

## 交付前检查清单

（交付前逐项作答并附证据；有一项未答就不交付，"其余都没问题"不算回答。(∥) = 仅当 ≥2 个 lane 并发时适用。规则本身在角色提示词里：test-agent `## 断言形态规则`、review-agent `## 空转断言清单`、implementation-agent `## 结论卫生` / `## 测试失败处理`。）

快速档：

1. 负对照：新测试在旧代码上失败、在新代码上通过的证据。
2. 按项目惯例的构建和测试结果（用例数 vs 基线）。
3. 那 1 轮实现评审（及至多 1 轮复核）的每条发现都有处置，跨 harness 结果已记录；每个已登记的评审点都有 `Review-Close`。
4. `change-note.md` 的"怎么验证"逐条兑现。
5. 合并、打 tag、发布之前问用户；`decisions.md` 的按推荐执行的决定已列给用户。

标准档、严格档：

1. 测试有效性：负对照已记录；变异按档位覆盖（各 lane `Mutations:` 与 `## 最终汇总测试 > 变异证据` 交叉核对），每个变异有正面证据表明打中了被测代码，SURVIVED 排除了五种原因（输入碰巧 / 冗余分支 / 断言无关 / 变异没打中 / fixture 两边取同一个值）。
2. 断言形态已按 test-agent 的规则审计；写下了"这些测试不能证明什么"、机制层面的原因，以及哪一层能证明。
3. 结论卫生：每个结论符合 implementation-agent `## 结论卫生`；每个 `ran:` 带实际用例数 / 包数 vs 基线和坐标（数据库 / 端口 / 进程与源码新鲜度）。
4. 环境：长期进程在最新源文件之后启动（重启按 杀进程组 → 轮询端口空闲 → 健康检查）；非生产写入路径改动的状态做了配对的生产侧失效；被中断运行的脏数据已清理（`log/restarts.md`）。
5. (∥) 每个 lane 持有自己在 `## 并行资源租约` 的那一行、确认连的是自己的实例；全量变绿前后都有编译干净检查；每次评审都在冻结的工作区上进行（`Frozen At`）。
6. 归因：每个失败按 implementation-agent 的四步顺序归因；重跑只用来证明不稳定，不用来证明清白；"别人的包坏了"附 mtime 观察或所有者确认。
7. 评审：每个已登记的评审点都有 `Review-Close`（`review-round.sh status` 核对），`residual` / `split` 的用户选择已记入 `decisions.md`；`impl-notes.md` 的实现备注逐条有落地记录；`decisions.md` 的「等待回答的问题」里没有仍在等回答的条目（有的话先问完，或写明用户同意带着交付）；`## 发现台账` 里没有被接受却 `dispatched-to` 为空的行；严格档每满三轮有 `Review-Check`。
8. 范围：本轮确立的每条规则都扫过了所有同形态位置，附逐位置结论；声称覆盖或不变量的注释与代码现状一致。
9. 披露：最终报告 `## 最薄弱环节` 已填；移入加固的 blocking 都已落地；遗留风险清单每条字段齐全，最终报告 `## 已知风险` / `## 后续工作` 指向它；按推荐执行的决定已列给用户。
10. 一致性：本文件与 `git log`、`lanes/*.md` 一致（`## 状态新鲜度` 已记录核对）；watchdog 已启用——没启用就直说，这里没有任何结论可以依赖它。
11. 反复出现的类：评审中标为 `recurring: <class>` 的每个类，都由一个类级修复（附落地的 commit/file）或单独一条遗留风险清单条目（RR-n）回应。

## 下一步行动

- 下一步:
