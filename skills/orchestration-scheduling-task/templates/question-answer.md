# 异步问答模板

worker 与用户通过 `<list-dir>/runtime/<task-id>/` 下的两个文件
交换异步问答：

- `question.md` —— 由 worker 写入，由用户读取
- `answer.md` —— 由用户写入，由 worker 读取；消费之后，
  worker 会把它重命名为 `answer.md.consumed.<question-id>` 以便审计。

编排器不写这两个文件中的任何一个。它唯一的职责，是在每个 tick 的对话摘要和
`<list-dir>/SUMMARY.md` 中呈现"任务 X 正在等待用户"。

本文档是合二为一的两份模板。按适用情况复制其中一份。

---

## `question.md` 模板（写入方：worker）

```markdown
---
task-id: <task-id>
question-id: 1                    # 单调递增；第一个问题为 1
asked-at: <iso>
---

## Question

<!-- 自由文本的问题。准确说明 worker 需要什么才能继续推进。 -->

## Options

<!--
  可选。如果问题只有一小组结构化的选项，在这里用项目符号列表
  列出，每行一个选项。问题是开放式的时候，省略本节。
-->
```

在写 `question.md` 之前，worker 先刷写 `worker-status.md`，其中包含
`wait-state: waiting-user`、非空的 `waiting-reason`，以及一个
`expected-resume-by` 时间戳。这样编排器就知道该任务
正在等待用户，并采用 `waiting-user` 的心跳阈值
（默认 900 秒）。

---

## `answer.md` 模板（写入方：用户）

```markdown
---
task-id: <task-id>
question-id: 1                    # 必须与 worker 所提问题的 question-id 一致
answered-at: <iso>
---

## Answer

<!-- 自由文本的回答。 -->
```

worker 怎么检测到它：写完 `question.md` 之后，worker 在后台轮询回答文件（例如后台 Bash 运行
`until [ -f <answer-file> ]; do sleep 30; done`）。回答写在对话之外，不会有任何东西
把 worker 叫醒；这个后台任务在回答到达时结束，它的结束通知会唤醒 worker，它在跑的
时候也让 watchdog 知道任务并没有被搁置。

worker 检测到 `answer.md` 时：

1. 读取它。
2. 更新 `worker-status.md`：`wait-state: none`，并清空
   `waiting-reason` / `expected-resume-by`。
3. 把 `answer.md` 重命名为 `answer.md.consumed.<question-id>`，这样它不会被
   误重复消费，审计记录也能在清理后保留下来。
