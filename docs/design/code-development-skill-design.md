# 代码开发 Skill 设计

## 目标

代码开发 Skill 用于帮助用户更好地完成代码开发任务。

该 Skill 面向已经明确要进行代码开发的场景。无论任务是独立服务、完整模块，还是少量代码改动，都必须先完成设计文档，再进入编码、测试、审核和交付。

本设计文档记录第一版 Skill 的产品与工作流设计。第一版实现采用纯提示词方式：实现 `SKILL.md`、主控提示词、模板和 subAgent 角色提示词，不实现 hook、脚本、MCP server 或真实 subAgent 运行时。

## 核心原则

- 用户主导设计，Agent 协助整理、追问、补全和执行。
- 所有开发都以设计文档为准。
- 设计文档必须正确、清晰、自洽、完整，使后续 codingAgent、testAgent、reviewAgent 能完全遵循文档完成开发、测试和审核，尽量无需再次向用户提问。
- 主agent 负责任务推进和调度，不直接写代码、改代码、测试或 review。
- codingAgent、testAgent、reviewAgent 各自有明确职责边界。
- 任务状态文件贯穿设计、编码、测试、审核和交付全流程，用于记录进度和支持中断恢复。
- coding 环节尽量不中途提问。遇到非阻塞歧义时，Agent 应选择合理方案并继续；只有会导致数据破坏或无法继续时才停止并向用户提问。
- 可以使用当前 Agent 已有的其他 skill、插件或工具提升文档和代码质量，但这些能力只能作为可选增强，不能成为必需依赖。

## Agent 组成

第一版包含以下 Agent 角色：

- 主agent
- codingAgent
- testAgent
- reviewAgent

其中主agent 不是 subAgent。主agent 是当前与用户对话的 Agent 在执行该 Skill 时采用的主控角色；codingAgent、testAgent、reviewAgent 才是可被调度或模拟的提示词式 subAgent。

`skills/code-development/SKILL.md` 必须内置主agent 的核心规则，并明确完整主控提示词位于 `skills/code-development/prompts/main-agent.md`。这样即使执行环境没有自动读取额外 prompt 文件，主agent 也能遵守基本职责边界；当环境支持读取引用文件时，应优先加载完整主控提示词。

### 主agent

主agent 是用户的主要交互对象，负责任务组织、文档维护和子 Agent 调度。

职责：

- 记录任务状态和整体进度。
- 在设计环节协助用户将本次代码开发整理为 Markdown 格式的设计文档。
- 保证设计过程由用户主导，主agent 负责追问、归纳、结构化和落文档。
- 在整理设计文档、任务状态文件和交付报告时，可以主动检查并使用当前 Agent 已安装的文档类、工程类 skill 或插件提升产出质量。
- 调度 subAgent 时，可以提醒 subAgent 优先利用当前环境已有的可选 skill、插件或工具，但不得把这些能力作为硬依赖。
- 在 coding 环节调度 codingAgent、testAgent、reviewAgent 完成代码开发。
- 维护任务状态文件，记录当前执行阶段、已完成事项、待完成事项、阻塞点、测试状态和审核状态。
- 判断 subAgent 状态。如果 subAgent 卡住、中断或长时间没有产出，需要评估是否重启 subAgent，并在任务状态文件中记录处理结果。

限制：

- 主agent 不允许直接写代码。
- 主agent 不允许直接改代码。
- 主agent 不允许直接编写或修改测试。
- 主agent 不允许直接执行测试。
- 主agent 不允许直接进行 review。

说明：

- 用户原始描述中提到的 `designDocAgent`，第一版不作为独立 Agent。设计文档协助职责先由主agent 承担。后续如果设计文档工作复杂度上升，可以再拆出独立 designDocAgent。

### codingAgent

codingAgent 根据设计文档完成工程开发。

工程开发范围包括：

- 代码
- 提示词
- 静态文件
- 配置文件
- 与实现目标直接相关的其他工程文件

职责：

- 根据设计文档实现工程代码和相关工程内容。
- 在实现代码、提示词、静态文件或配置文件时，可以主动使用当前 Agent 已安装的工程实践类、语言类、框架类、测试类 skill 或插件提升实现质量。
- 如果当前环境存在适合当前任务的可选能力，例如 llmdoc、superpowers 或其他专项插件，codingAgent 可以使用它们辅助理解设计、检查实现方案、提升代码质量或优化开发流程。
- 在实现复杂函数或复杂逻辑且没有正确性把握时，可以编写临时自测代码验证实现。
- 临时自测代码不得作为最终交付内容保留，开发完成后必须删除。
- 在实现过程中，如果发现重要测试点、回归点或工程验收点未被设计文档覆盖，应通知主agent。
- 主agent 收到补充测试点后，应更新设计文档，并通知 testAgent 补充测试代码。
- codingAgent 完成 coding 后，负责执行测试代码，包括单元测试、e2e 测试、压力测试、回归测试等。
- codingAgent 可以运行测试代码，以便直接获得报错信息，减少不必要的信息传递和上下文重复。
- codingAgent 执行测试时必须注意测试环境，例如本地启动、容器中启动、远程执行等。

限制：

- codingAgent 不能直接修改测试代码。
- 测试代码只能由 testAgent 编辑。

测试失败处理：

- 如果测试没有通过，codingAgent 先评估失败原因。
- 如果失败原因是客观存在的工程代码问题，codingAgent 修复工程代码。
- 如果失败原因是测试内容不合理，codingAgent 拒绝修改工程代码，并通知 testAgent 修改测试样例或测试内容。
- 拒绝修改时必须说明原因，供 testAgent 或 reviewAgent 后续判断。

Review 意见处理：

- 如果 reviewAgent 认为工程代码应该修改，codingAgent 先评估审查意见。
- 如果审查意见指出的是客观存在的问题，codingAgent 修复工程代码。
- 如果审查意见不合理，codingAgent 拒绝修改，并通知 reviewAgent 拒绝修改的原因。

### testAgent

testAgent 根据设计文档和 codingAgent 的反馈编写和维护测试代码。

测试范围包括：

- 单元测试
- e2e 测试
- 必要时的压力测试
- 必要时的回归测试
- 设计文档中指定的其他验证方式

职责：

- 根据设计文档编写测试代码。
- 根据 codingAgent 在实现中发现的新测试点，补充或修改测试代码。
- 根据 reviewAgent 的审查意见，补充或修改测试代码。
- 当 codingAgent 或 reviewAgent 认为测试代码需要修改时，先评估修改意见是否合理。
- 如果修改意见对应客观存在的问题，testAgent 修改测试代码。
- 如果修改意见不合理，testAgent 拒绝修改，并通知提出方拒绝修改的原因。

限制：

- testAgent 负责开发和维护测试代码。
- testAgent 不负责运行测试代码。
- 测试运行由 codingAgent 执行。

### reviewAgent

reviewAgent 负责独立审查，避免主agent 自审带来的偏袒性和倾向性。

职责：

- 在设计环节审查设计文档。
- 在 coding 环节审查工程内容，包括代码、提示词、静态文件、配置文件等。
- 在 coding 环节审查测试代码。
- 根据主 agent、codingAgent、testAgent 对审查意见的修改或拒绝原因，执行新的 review。

设计文档审查标准：

- 没有错误。
- 没有模糊点。
- 没有遗漏。
- 没有冲突。
- 足够完整、完备。
- 后续 coding 环节无需再向用户提问即可执行。

代码与测试审查标准：

- 实现是否符合设计文档。
- 测试是否覆盖设计文档要求的验收点、边界条件和重要回归点。
- 工程代码和测试代码是否存在明显缺陷、风险或不一致。
- 拒绝修改的原因是否成立。

Review 循环：

- 主 agent、codingAgent、testAgent 可能接受审查意见并修改。
- 主 agent、codingAgent、testAgent 也可能拒绝审查意见，并给出拒绝原因。
- 接受和拒绝可能同时存在。
- reviewAgent 必须基于修改后的文档或代码，以及拒绝修改的原因，执行新的 review。
- 只有当 reviewAgent 判断无需修改时，当前 review 循环结束。

## 执行流程

### 阶段一：设计环节

设计环节由用户主导，主agent 协助完成设计文档。

要求：

- 无论任务大小，都必须先进行设计。
- 设计文档使用 Markdown 格式。
- 一期开发可以不是完整完善的工程，但设计中必须写明当前版本实现什么、不实现什么。
- 设计文档不仅包含高层级架构、接口、模块、模型，也可以包含重要、容易出错、需要注意的算法内容、代码细节、测试内容、测试点和定制化实现方式。

设计文档目标：

- 正确。
- 清晰。
- 自洽。
- 完整。
- 能让后续 codingAgent、testAgent、reviewAgent 完全遵循设计文档完成开发、测试和审核，尽量无需再向用户提问。

流程：

1. 主agent 与用户交谈，理解用户需求、设计和约束。
2. 主agent 将用户输入整理为 Markdown 设计文档。
3. 如果有不清楚的点，主agent 反问用户。
4. 设计文档初稿完成后，主agent 启动独立 reviewAgent 审查设计文档。
5. reviewAgent 按设计文档审查标准检查是否存在错误、模糊、遗漏、冲突或不完备。
6. 主agent 自行决定接受或拒绝 reviewAgent 的每条建议（默认不询问用户）。
7. 接受时主agent 更新设计文档；拒绝时主agent 在设计文档的 `## Review History` 与 task status 的 `## Design Review > Rejected Suggestions` 记录拒绝原因。
8. 仅当 reviewAgent 的建议会改动 Goals 或 Acceptance Criteria 时，主agent 才回到用户征求决策。
9. reviewAgent 基于修改后的文档和拒绝原因执行新的 review。
10. 当 reviewAgent 判断无需修改时，设计 review 循环结束。
11. 主agent 提醒用户进行人工审查。
12. 用户人工审查通过后，进入 coding 环节。

### 阶段二：Coding 环节

coding 环节由主agent 调度 codingAgent、testAgent、reviewAgent 完成。

#### 并行开发

- codingAgent 根据设计文档开发工程代码和相关工程内容。
- testAgent 根据设计文档开发测试代码。
- codingAgent 与 testAgent 可以并行工作。
- 如果 codingAgent 在开发中发现设计文档遗漏的重要测试点，应通知主agent。
- 主agent 在设计文档 `## Review History` 与 task status 中追加 "discovered during coding" 条目，并通知 testAgent 补充测试代码；仅当新测试点暗示 Goals 或 Acceptance Criteria 变更时，才重新触发设计评审或回到用户。

#### 测试执行

- codingAgent 与 testAgent 都完成后，codingAgent 执行测试。
- 测试可包括单元测试、e2e 测试、压力测试、回归测试等。
- codingAgent 执行测试前应确认测试环境，例如本地、容器或远程。
- codingAgent 可以重复执行测试，以便直接获得报错信息并修复工程代码。
- codingAgent 不得修改测试代码。

#### Bug 修复

- 如果测试全部通过，进入 review。
- 如果测试失败，codingAgent 判断失败原因。
- 如果是工程代码问题，codingAgent 修复工程代码后重新执行测试。
- 如果是测试代码问题，codingAgent 通知 testAgent 修改测试。
- testAgent 修改测试后，codingAgent 重新执行测试。
- 该循环持续到测试全部通过，或出现必须向用户确认的阻塞问题。

#### 审核

- 测试全部通过后，主agent 启动 reviewAgent。
- reviewAgent 审查工程内容和测试代码。
- reviewAgent 输出需要修改的问题，或给出无需修改结论。
- codingAgent 和 testAgent 分别评估与自身职责相关的审查意见。
- 如果审查意见合理，相关 Agent 完成修改。
- 如果审查意见不合理，相关 Agent 拒绝修改，并给出拒绝原因。

#### 审核后修改与再测试

- 如果工程代码或测试代码发生修改，必须重新执行测试。
- 测试由 codingAgent 执行。
- 测试全部通过后，reviewAgent 基于最新代码、测试代码和拒绝修改原因执行新的 review。
- 当测试全部通过，且 reviewAgent 判断无需修改时，coding 环节完成。

#### 长时间任务与异常恢复

coding 环节可能执行很长时间，且中途可能不稳定。

主agent 必须：

- 持续维护任务状态文件。
- 记录当前执行到了哪个阶段。
- 记录已完成内容。
- 记录还需要完成的内容。
- 记录当前 subAgent 状态。
- 如果 subAgent 卡住、中断或长时间没有产出，评估是否重启 subAgent。
- 如果重启 subAgent，需要把重启原因、恢复依据和下一步动作写入任务状态文件。

### 阶段三：交付环节

最终报告必须列出：

- 完成项。
- 未完成项。
- 假设。
- 关键选择。
- 文件改动。
- 测试结果。
- review 结果。
- 已知风险或后续建议。

交付报告完成后，主agent 询问用户是否需要删除任务状态文件。

## 任务状态文件

任务状态文件由主agent 维护，贯穿设计环节、coding 环节和交付环节。

用途：

- 记录任务当前阶段。
- 记录当前进度。
- 记录已完成事项。
- 记录待完成事项。
- 记录阻塞问题。
- 记录用户确认点。
- 记录设计文档路径。
- 记录测试计划和测试结果。
- 记录 review 循环状态。
- 记录 subAgent 状态。
- 支持任务中断后的快速恢复和继续执行。

建议保存位置：

```text
.zyz-worker/tasks/<task-id>/status.md
```

说明：

- `<task-id>` 由主agent 根据任务名称、日期或短 hash 生成。
- 状态文件属于过程文件，不一定需要进入最终提交。
- 交付环节结束时，主agent 应询问用户是否删除任务状态文件。

建议结构：

```markdown
# Task Status

## Metadata

- Task ID:
- Task Name:
- Design Document:
- Current Phase:
- Created At:
- Updated At:

## Progress

- Completed:
- In Progress:
- Pending:
- Blocked:

## User Decisions

- Decision:
- Reason:

## Agent State

- Main Agent:
- codingAgent:
- testAgent:
- reviewAgent:

## Design Review

- Latest Review Result:
- Open Issues:
- Rejected Suggestions:

## Coding

- Implementation Status:
- Important Notes:
- Discovered Test Points:

## Testing

- Test Command:
- Test Environment:
- Latest Result:
- Failing Cases:

## Code Review

- Latest Review Result:
- Required Changes:
- Rejected Suggestions:

## Next Actions

- Next:
```

## 设计文档建议结构

每个代码开发任务都应生成独立设计文档。

建议保存位置：

```text
.zyz-worker/tasks/<task-id>/design.md
```

建议结构：

```markdown
# <Task Name> Design

## Background

## Goals

## Non-Goals

## User Requirements

## Current State

## Proposed Design

## Implementation Plan

## Important Details

## Files To Change

## Testing Plan

## Acceptance Criteria

## Risks

## Open Questions

## User Decisions

## Review History
```

## 子 Agent 协作规则

- 主agent 向 subAgent 分配任务时，必须提供设计文档路径和任务状态摘要。
- subAgent 的输出应包含完成内容、未完成内容、发现的问题、需要其他 Agent 处理的事项。
- subAgent 不能越权修改其他 Agent 负责的内容。
- codingAgent 不能修改测试代码。
- testAgent 不能运行测试代码。
- reviewAgent 不能直接修改代码、测试或设计文档，只输出审查结论。
- 主agent 不能直接实现、测试或 review，只负责协调、记录和更新设计文档。

## 可选能力增强

在写设计文档、实现代码、编写测试或执行 review 时，相关 Agent 可以选择使用当前运行环境中已经可用的其他 skill、插件或工具来提升质量。

示例：

- 使用文档类 skill 或插件提升设计文档的结构、清晰度和完整性，例如 llmdoc。
- 使用工程实践类 skill 或插件辅助代码设计、实现检查或工作流执行，例如 superpowers。
- 使用当前 Agent 已经具备的语言、框架、测试、浏览器、文档、表格等专项能力完成对应任务。

约束：

- 这些能力是可选增强，不是该 Skill 的必需依赖。
- 如果当前 Agent 没有安装或启用相关 skill、插件或工具，流程必须继续执行。
- 不要求用户为了运行该 Skill 额外安装 llmdoc、superpowers 或其他插件。
- 不得因为缺少可选增强能力而阻塞设计、coding、测试、review 或交付。
- 如果使用了可选能力增强，应在任务状态文件或最终报告中简要记录使用了哪些能力，以及它们影响了哪些产出。

## 阻塞与提问规则

设计环节：

- 如果需求、约束或验收标准不清楚，主agent 可以向用户提问。
- 设计文档 review 中的修改建议由主agent 自行决定接受或拒绝；只在涉及 Goals / Acceptance Criteria 时才回到用户。

coding 环节：

- 默认不中途提问。
- 非阻塞歧义由相关 Agent 做合理选择并继续。
- 如果问题会导致数据破坏、不可逆操作、严重偏离设计文档或无法继续，主agent 应停止流程并向用户提问。

## 第一版非目标

- 不实现真实 subAgent 运行时，只提供主控提示词和提示词式 subAgent 定义。
- 不实现 hooks。
- 不实现脚本。
- 不实现后台服务。
- 不引入 MCP server。
- 不强制选择某种编程语言。
- 不处理多个独立项目的并行调度。
- 不做自主产品发现或需求池管理。

## 后续实现建议

第一版实现将该 Skill 表达为一个 `SKILL.md` 工作流，并提供主控提示词和提示词式 subAgent 定义，而不是立即实现真实 subAgent 运行时。

Claude Code 适配：

- `CLAUDE.md` 作为项目级说明，会在 Claude Code 启动项目时加载。
- `.claude/commands/code-development.md` 提供 `/code-development` 项目命令，用于启动该工作流。
- `.claude/agents/coding-agent.md`、`.claude/agents/test-agent.md`、`.claude/agents/review-agent.md` 是 Claude Code 原生项目级 subAgent 定义。
- 主agent 不放入 `.claude/agents/`，因为主agent 是当前与用户对话的控制角色。

建议演进顺序：

1. 使用 `skills/code-development/SKILL.md` 和 `subagents/` 中的提示词验证工作流。
2. 根据真实任务反馈调整设计文档模板、任务状态文件模板和角色提示词。
3. 增加 subAgent 规格文档。
4. 在有稳定执行模式后，再考虑 hooks、脚本或真实 subAgent 运行时。
5. 根据 Codex 和 Claude Code 的实际加载方式，补充 agent-specific 适配说明。
