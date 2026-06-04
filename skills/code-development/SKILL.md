---
name: code-development
description: Use when the user wants help completing a code development task with a design-first workflow, a user-facing main agent, prompt-only subagents, task status tracking, implementation, tests, review, and final delivery.
---

# Code Development

Use this skill to help a user complete a code development task. The workflow is design-first, user-led during design, and coordinated by the current conversation agent using a main-agent prompt plus prompt-only subagent roles.

This skill does not require hooks, scripts, MCP servers, background services, or a real subagent runtime. The main-agent prompt applies to the current user-facing conversation agent. If the current agent environment can launch subagents, use the prompts in `../../subagents/` for codingAgent, testAgent, and reviewAgent. If it cannot, use those files as role instructions and preserve the same responsibility boundaries in the conversation.

## Main Agent Loading

When this skill is used, the current user-facing conversation agent is the main agent.

First load and follow the full main-agent controller prompt from:

```text
prompts/main-agent.md
```

That file is not a subagent. It defines how the current conversation agent coordinates the workflow and talks with the user.

If the full prompt cannot be loaded, continue with these built-in main-agent rules:

- Stay user-facing and coordinate the task through design, coding, testing, review, and delivery.
- Lead a user-driven design process and maintain a Markdown design document.
- Maintain a task status file throughout the workflow.
- Dispatch or simulate codingAgent, testAgent, and reviewAgent with the design document path and current status summary.
- Monitor role progress and restart or re-issue role prompts when a role is stuck, interrupted, or silent for too long.
- Use currently installed skills, plugins, or tools when they improve design documents, status files, or final reports, but never require missing optional capabilities.
- Do not write implementation code.
- Do not modify implementation code.
- Do not write or modify test code.
- Do not run tests.
- Do not perform review yourself.
- If role boundaries cannot be enforced technically, enforce them procedurally and clearly label role handoffs.

## Prompt Files

Load these files only when their role is needed:

- Main agent controller prompt: `prompts/main-agent.md` (load first when the skill starts)
- codingAgent: `../../subagents/coding-agent.md`
- testAgent: `../../subagents/test-agent.md`
- reviewAgent: `../../subagents/review-agent.md`

Use these templates when creating task artifacts:

- Design document: `templates/design-doc.md`
- Task status: `templates/task-status.md`
- Final report: `templates/final-report.md`
- Review report: `templates/review-report.md`

## Core Rules

- The user leads design. The agent helps clarify, structure, document, and execute.
- Every code task starts with a Markdown design document, regardless of task size.
- The design document is not required to be a single file. For complex tasks, split it into multiple focused documents by domain, module, layer, or step so each document stays internally focused and loads cleanly into the model's context. Simple tasks may keep a single document.
- When the design is split, record every document path in the status file `## Metadata > Design Document` (one per line) and add a top-level index document that lists and links the parts, so downstream roles can discover the full set.
- The design document is the source of truth for implementation, testing, and review.
- The design document must be clear enough that codingAgent, testAgent, and reviewAgent can proceed without asking the user again unless there is a blocking issue.
- Maintain a task status file for the full workflow: design, coding, testing, review, and delivery.
- Use existing installed skills, plugins, or tools when they improve document or code quality, but never require the user to install missing optional capabilities.
- Prefer continuing through non-blocking ambiguity with documented assumptions. Stop and ask the user only when continuing would risk data loss, irreversible changes, or a serious mismatch with the design.
- The design document and the final report default to the same language as the user in this conversation. Other artifacts (task status, review reports, prompt files) stay in their current language.

## Automatic Execution Policy

By default, do not ask the user. Inside the workflow loops, each role decides for itself:

- During design review, the main agent decides whether to accept or reject each review-agent finding. Rejected findings are recorded with reasons in the design document `## Review History` and the status file `## Design Review > Rejected Suggestions`.
- During coding review, the role responsible for the changed artifact (coding-agent for implementation, test-agent for tests) decides whether to accept or reject each finding. Rejected findings are recorded in the status file `## Code Review > Rejected Suggestions`, prefixed with the originating SubTask ID when SubTasks are used.
- When a test fails, coding-agent decides whether the failure is an implementation bug or an invalid test, then coding-agent fixes implementation bugs and test-agent fixes invalid tests.

Escalate to the user only when:

- the decision would cause data loss, an irreversible change, or a serious deviation from the agreed Goals / Acceptance Criteria;
- the design phase reaches the final human approval step (one explicit user touch before coding starts);
- the same finding flips between accept and reject across three or more automated iterations without convergence.

The design phase's review loop (§2 step 7 below) iterates automatically — no user input between iterations — until review-agent reports no changes needed. Only §2 step 8 (final human approval before coding) is a user touch.

## Role Boundaries

The main agent is the current user-facing conversation agent. It coordinates and records. It must not directly write implementation code, modify tests, run tests, or perform review.

codingAgent writes implementation and runs tests. It must not modify test code.

testAgent writes and maintains test code. It must not run tests.

reviewAgent reviews design, implementation, and tests. It must not modify files directly.

If the platform cannot enforce these boundaries technically, enforce them procedurally by separating role outputs and clearly labeling which role is acting.

## Workflow

### 1. Start Task

1. Create or identify a task id.
2. Create a task directory, preferably `.zyz-worker/tasks/<task-id>/`.
3. Create a status file from `templates/task-status.md`.
4. Record the task name, phase, known inputs, open questions, and current assumptions.

### 2. Design

1. Work with the user to produce a Markdown design document from `templates/design-doc.md`. Decide whether one document is enough or whether the design should be split into multiple focused documents (by domain, module, layer, or step). Prefer splitting when the task touches several domains/modules/layers, the Implementation Plan has many steps, or a single document would grow long enough to dilute model context. When splitting, create a short index document that lists and links every part, and reuse the template (in full or partial form) for each part.
2. Ask the user about unclear requirements, constraints, non-goals, acceptance criteria, risky implementation details, and important tests.
3. When the design draft is ready, use reviewAgent to review it.
4. The main agent decides accept-or-reject for each review-agent finding based on the design and Goals. Do not present findings to the user.
5. Record rejected findings with reasons in the design document `## Review History` and the status file `## Design Review > Rejected Suggestions`.
6. Update the design document and status file. If a finding implies a goal-level or acceptance-criteria-level change, escalate to the user instead of unilaterally rewriting Goals.
7. Repeat review until reviewAgent says no changes are needed.
   This loop runs automatically without user input; only step 8 below is a user touch.
8. Ask the user for final human approval before coding.

Do not enter coding until both reviewAgent and the user approve the design.

### 3. Coding And Testing

#### 3.0 Decide whether to split

The main agent decides on its own whether to split the task into SubTasks. Splitting is optional; do not ask the user. Consider splitting when:

- the change spans 3 or more directories or layers;
- the Implementation Plan lists 4 or more steps;
- the task includes independently verifiable sub-capabilities.

Not splitting is also valid for simple tasks.

#### 3.A No-split path

When the task is not split, run a single iteration:

1. coding-agent implements the engineering changes.
2. test-agent writes or updates tests from the design document.
3. coding-agent runs the tests.
4. If tests fail, coding-agent classifies the failure; coding-agent fixes implementation bugs and test-agent fixes invalid tests.
5. After tests pass, review-agent reviews implementation and tests. Each role decides accept-or-reject for findings affecting its artifact.
6. Repeat 3-5 until tests pass and review-agent reports no changes.

Then proceed to §3.C aggregate testing and aggregate review.

#### 3.B Split path

When split, the main agent records SubTasks in the status file `## SubTasks` section. For each SubTask:

1. coding-agent implements that SubTask's engineering changes.
2. test-agent writes or updates tests for that SubTask.
3. coding-agent runs that SubTask's tests.
4. If tests fail, coding-agent classifies and the responsible role fixes; loop until tests pass.
5. review-agent reviews the SubTask's implementation and tests. Each role decides accept-or-reject and records rejections (prefixed with SubTask ID) in `## Code Review > Rejected Suggestions`.
6. Loop 3-5 until tests pass and review-agent reports no changes for this SubTask.
7. Set the SubTask's `Coded`, `Tested`, `Reviewed` flags to true:
   - `Coded: true` when implementation is complete.
   - `Tested: true` when this SubTask's tests pass.
   - `Reviewed: true` when review-agent reports no changes for this SubTask (rejected findings allowed if reasons are recorded).

Do not start SubTask N+1 until SubTask N has all three flags true, unless the main agent records SubTask N as "blocked, deferred" with all of the following:

- a written rationale showing no later SubTask has a static dependency on SubTask N's code path (per the design's Implementation Plan and Files To Change);
- an entry added to `## Progress > Blocked` and the SubTask's `Notes`.

SubTasks default to sequential execution. Parallel SubTask execution is allowed only when the main agent records explicit no-dependency rationale in `## SubTasks > Notes`.

#### 3.C Aggregate testing and aggregate review

When all SubTasks (or the single no-split iteration) are complete, run:

1. Aggregate testing by coding-agent, covering at minimum: unit tests, end-to-end tests, regression tests. Add pressure tests when the design's `## Risks` calls out performance or capacity risk. Record the executed categories and result in the status file `## Final Aggregate Testing`.
2. Aggregate review by review-agent across all SubTasks for consistency, contracts, and regression. Each role decides accept-or-reject for findings affecting its artifact; rejections recorded as in §3.B. Record the verdict in the status file `## Final Aggregate Review`.
3. Loop aggregate test and aggregate review until both converge.

The final report's `## Tests` section must enumerate the aggregate categories actually executed (unit / e2e / regression / pressure if applicable). The final report's `## Review Result` section must record the aggregate review verdict separately from per-SubTask verdicts when SubTasks were used.

### 4. Deliver

1. Update the status file with final phase, completed work, test results, review result, assumptions, and known risks.
2. Produce a final report from `templates/final-report.md`.
3. Ask the user whether to delete the task status files.

## Long-Running Work

During long coding phases, the main agent should keep the status file current. Record the active role, latest output, blocked items, next action, and restart notes.

If a subagent is stuck, interrupted, or silent for too long, the main agent should restart that role if the platform supports it. If no real subagent runtime exists, resume from the status file and re-issue the relevant role prompt with the latest design and status summary.

## Optional Skills And Plugins

Before writing design docs, implementation, tests, or review reports, check whether the current agent already has relevant skills, plugins, or tools available.

Examples:

- Use documentation skills or plugins, such as llmdoc, to improve design document quality if already available.
- Use engineering workflow skills or plugins, such as superpowers, to improve implementation or review quality if already available.
- Use language, framework, testing, browser, document, or spreadsheet skills when the task naturally needs them.

Do not block, fail, or ask the user to install anything when these optional capabilities are unavailable.

When optional capabilities are used, record them briefly in the task status file or final report.
