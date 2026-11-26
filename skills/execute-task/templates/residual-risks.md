# 遗留风险

<!-- 本任务各评审循环遗留下来的行为层面遗留项，见 SKILL.md `## 评审收口`。记三种：每个 `non-blocking:contrived` **类**（不是每个变体）一条；每个未落地的、行为层面或测试层面的 `non-blocking:normal` 发现一条；评审点到上限时用户选择"接受为遗留风险"的每个 `blocking` 一条（`Origin` 里写 `decisions.md` 的编号）。关于设计**文档**本身的发现记入它的评审历史文件，不记在这里。

     本文件是后续加固任务的输入。每条写到让那个任务不用重新推导就能动手；缺字段的条目在交付时算作未结项。后续评审者会拿到本文件的路径，对已登记的项按 id 回应，不重新提出——前提是他们发现的问题，每个产生方都落在该条 `Impact` 已排查过的调用点之内。出现新产生方的变体，或有新证据表明声明域内有东西能触达它，就是一个新发现，单独定级。 -->

## RR-1: <类别，一行>

- Origin: <评审点 id> #<发现编号>（<reviewAgent | cross-harness:<harness> | 角色>）；到上限接受的附 `decisions.md` <A-n>
- Tier: <non-blocking:contrived | non-blocking:normal | blocking>
- Reproduction: <触发它的最小具体构造——代码、输入或状态；如果是一个类，列出见到的每个变体>
- Impact: <为什么今天声明域内没有东西能触达它——列举的调用点（file:line）——以及什么样的改动会让它变得可触达；`blocking` 条目写清楚已知的影响面>
- Hardening Plan: <改什么、改在哪、如何验证过（探针 / 一次性变异 / 测试），或 `none proposed`>
- Status: <open | folded into <后续任务> | fixed in <commit>>
