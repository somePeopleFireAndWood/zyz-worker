# 实现备注

<!-- 设计评审留给实现阶段的内容，写第一条时创建。和 `decisions.md` 一起随每个 lane 派发，由实现评审验证。只有下面两节，没有内容的一节写 none。设计正文仍是规格：本文件不改设计；某一条和设计冲突时，lane 停下这一块并报告主 agent。读完即删除本注释。 -->

## 实现备注

<!-- 设计评审里的非阻断发现不进设计正文（`references/design-doc-discipline.md`）。其中实现者确实需要的细节记在这里，每条注明来源发现的编号。只写照着做就行的细节；要加新机制（新增表、接口、状态，或跨模块的规则）才能解决的不写在这里，先重新核对等级（`references/review-closure.md` §5）。 -->

### N-1: <一句话>

- 来源: <评审点>#<发现编号>（第 <n> 轮，<reviewAgent | cross-harness:<harness>>）
- 涉及: <设计章节 / 模块 / 文件>
- 要点: <实现时要做到什么>
- 落地: <lane id → commit/file；实现评审核对后填>

## 带进实现的 blocking

<!-- 评审点停下交给用户时，用户选择"带着进实现"的剩余 blocking（`review-round.sh close <point> --outcome carried --by user`，选择记在 `decisions.md`）。每条写成一个必须通过的测试项。lane 写出对应的测试，在报告里逐条回应；主 agent 交付前逐条核对已落地，有一条是 open 就不交付。 -->

### C-1: <一句话>

- 来源: <评审点>#<发现编号>（第 <n> 轮）；`decisions.md` <A-n>
- 问题: <按原样实现，在什么情况下会出错>
- 必须通过的测试: <输入或场景 → 期望行为；测试在哪一层（单元 / 回归 / e2e）>
- 负责的 lane: <lane id>
- 落地: <测试名 + commit/file；还没落地写 open>
- 核对: <主 agent 交付前核对的结果与证据（测试存在并通过）>
