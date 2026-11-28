# 实现备注

<!-- 设计评审留给实现阶段的细节，写第一条时创建。和 `decisions.md` 一起随每个 lane 派发，也附给实现评审、汇总评审、跨 harness 评审和严格档的 test-agent；评审者逐条核对是否落地。本文件不改设计，设计正文仍是规格：某一条和设计冲突时，lane 停下这一块并报告主 agent。读完即删除本注释。 -->

## 实现备注

<!-- 设计评审里的非阻断发现不进设计正文（`references/design-doc-discipline.md`）。其中实现者确实需要的细节记在这里，每条注明来源发现的编号。只写照着做就行的细节；要加新机制（新增表、接口、状态，或跨模块的规则）才能解决的不写在这里，先重新核对等级（`references/review-closure.md` §5）。没有就写 none。 -->

### N-1: <一句话>

- 来源: <评审点>#<发现编号>（第 <n> 轮，<reviewAgent | cross-harness:<harness>>）
- 涉及: <设计章节 / 模块 / 文件>
- 要点: <实现时要做到什么>
- 落地: <lane id → commit/file；主 agent 按实现评审的核对结果填>
