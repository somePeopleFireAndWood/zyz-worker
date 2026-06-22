---
name: execute-task
description: Use when the user wants help executing a single confirmed development task with a design-first workflow, a user-facing main agent, prompt-only subagents, task status tracking, implementation, tests, review, and final delivery.
---

# Execute Task

Use this skill to help a user execute a single confirmed code development task — design through delivery. This is zyz-worker's "execute one task" skill; higher-level multi-task orchestration belongs to the `orchestration-scheduling-task` skill in this same plugin and is out of scope here. The workflow is design-first, user-led during design, and coordinated by the current conversation agent using a main-agent prompt plus prompt-only subagent roles.

This skill does not require hooks, scripts, MCP servers, background services, or a real subagent runtime. The main-agent prompt applies to the current user-facing conversation agent. If the current agent environment can launch subagents, use the prompts in `../../subagents/` for implementationAgent, testAgent, and reviewAgent. If it cannot, use those files as role instructions and preserve the same responsibility boundaries in the conversation.

## Main Agent Loading

When this skill is used, the current user-facing conversation agent is the main agent.

First load and follow the full main-agent controller prompt from:

```text
prompts/main-agent.md
```

That file is not a subagent. It defines how the current conversation agent coordinates the workflow and talks with the user.

If the full prompt cannot be loaded, continue with these built-in main-agent rules:

- Stay user-facing and coordinate the task through design, implementation, testing, review, and delivery.
- Lead a user-driven design process and maintain a Markdown design document.
- Maintain a task status file throughout the workflow.
- Dispatch or simulate implementationAgent, testAgent, and reviewAgent with the design document path and current status summary.
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
- implementationAgent: `../../subagents/implementation-agent.md`
- testAgent: `../../subagents/test-agent.md`
- reviewAgent: `../../subagents/review-agent.md`

Use these templates when creating task artifacts:

- Design document: `templates/design-doc.md`
- Task status: `templates/task-status.md`
- Final report: `templates/final-report.md`
- Review report: `templates/review-report.md`

## Core Rules

- The user leads design. The agent helps clarify, structure, document, and execute.
- The user's stated requirements are always the final, complete target. The overall task must end fully meeting that target, however large, heavy, or broad it is.
- Every code task starts with a Markdown design document, regardless of task size.
- The design document is not required to be a single file. For complex tasks, split it into multiple focused documents by domain, module, layer, or step so each document stays internally focused and loads cleanly into the model's context. Simple tasks may keep a single document.
- When the design is split, record every document path in the status file `## Metadata > Design Document` (one per line) and add a top-level index document that lists and links the parts, so downstream roles can discover the full set.
- The design document is the source of truth for implementation, testing, and review.
- The design document must be clear enough that implementationAgent, testAgent, and reviewAgent can proceed without asking the user again unless there is a blocking issue.
- Maintain a task status file for the full workflow: design, implementation, testing, review, and delivery.
- There must always be exactly one overall task status file that records overall state and progress. Each SubTask may optionally keep its own SubTask-status file recording that SubTask's implementation, test, review, and auto-fix progress, but the single overall status file is mandatory.
- Status and progress must be persisted to the status files. Do not report progress only in the conversation. Whenever a SubTask completes (or any phase changes), write the update into the overall task status file and the relevant SubTask-status file (if one exists) before moving on.
- Use existing installed skills, plugins, or tools when they improve document or code quality, but never require the user to install missing optional capabilities.
- Prefer continuing through non-blocking ambiguity with documented assumptions. Stop and ask the user only when continuing would risk data loss, irreversible changes, or a serious mismatch with the design.
- The design document and the final report default to the same language as the user in this conversation. Other artifacts (task status, review reports, prompt files) stay in their current language.
- Long-running tasks must persist progress, decisions, blockers, and the next step into the task status file; the conversation context is for execution only. See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md).

## Automatic Execution Policy

By default, do not ask the user. Inside the workflow loops, each role decides for itself:

- During design review, the main agent decides whether to accept or reject each review-agent finding. Rejected findings are recorded with reasons in the design document `## Review History` and the status file `## Design Review > Rejected Suggestions`.
- During implementation review, the role responsible for the changed artifact (implementation-agent for implementation, test-agent for tests) decides whether to accept or reject each finding. Rejected findings are recorded in the status file `## Implementation Review > Rejected Suggestions`, prefixed with the originating SubTask ID when SubTasks are used.
- When a test fails, implementation-agent decides whether the failure is an implementation bug or an invalid test, then implementation-agent fixes implementation bugs and test-agent fixes invalid tests.

Escalate to the user only when:

- the decision would cause data loss, an irreversible change, or a serious deviation from the agreed Goals / Acceptance Criteria;
- the design phase reaches the final human approval step (one explicit user touch before implementation starts);
- the same finding flips between accept and reject across three or more automated iterations without convergence.

The design phase's review loop (§2 step 7 below) iterates automatically — no user input between iterations — until review-agent reports no changes needed. Only §2 step 8 (final human approval before implementation) is a user touch.

## Total Goal Fidelity

The user always describes the final, complete target. The final deliverable of the overall task must satisfy that target in full.

- Do not unilaterally narrow, simplify, defer, or substitute an "experimental placeholder" for any part of the user's stated goal at the overall-task level.
- Phrases like "deferred to next milestone", "in-memory only for now, replace later", "experimental placeholder", or "ship a simplified version first and iterate" describe intermediate states only. They may appear inside SubTask execution, never as the final state of the overall task.
- SubTasks may be implemented step by step or via TODO-style staging. That is expected. But once all SubTasks are done, the overall task must completely fulfill the user's goal.
- To prevent the overall goal from being forgotten or drifting, record it explicitly. Write the user's full target into the design document `## Goals` and copy a concise statement of it into the status file `## Total Goal`. Every phase checks final output against this record before delivery.
- If genuinely fulfilling the full goal is impossible (true blocker, contradiction, or it would cause data loss / irreversible change), escalate to the user instead of silently shipping a reduced version.

## Incremental Output

Agents (the main agent and every subagent) do not have to produce a complete result in a single response. Producing a large artifact over multiple passes and edits is allowed and encouraged.

- Split large implementation, test, document, or report writing into several smaller outputs or successive edits rather than one oversized response.
- This improves model and API stability, reduces the chance of truncated or failed responses, and avoids context anxiety from trying to emit everything at once.
- Multi-pass output is a delivery technique, not a license to defer scope. It does not relax Total Goal Fidelity: the final state must still completely fulfill the user's goal.

## Version Control

zyz-worker is designed to complete the whole task autonomously from the design document, so version-control steps run on their own and never block the workflow.

- Commit autonomously. Create a commit after each completed SubTask, and a final commit for the overall task. Do not stop to ask the user whether to commit.
- Push autonomously when a remote/upstream is configured. Do not stop to ask the user whether to push.
- Commit and push are non-blocking. If a commit or push fails (no remote, auth, hook, conflict, or any other reason), record the failure in the status file and continue the task. A failed commit or push is never a blocker and must not interrupt or pause the workflow.
- Still respect destructive-action safety: do not force-push, reset --hard, or rewrite published history on your own. Autonomy here covers ordinary `git commit` and `git push`, not destructive operations.
- On explicit user instruction (via conversation in standalone mode, or via a matching `## Pending Merge Approval` token in orchestrated mode), the worker MAY also `git merge` the task branch into its base and push the result — this still respects the no-force-push / no-history-rewrite limit. Autonomy never covers merge to base; only user-instructed merges are allowed. In orchestrated mode the orchestrator performs the merge (the worker does not), to avoid both layers writing the base concurrently.

## Role Boundaries

The main agent is the current user-facing conversation agent. It coordinates and records. It must not directly write implementation code, modify tests, run tests, or perform review.

implementationAgent writes implementation and runs tests. It must not modify test code.

testAgent writes and maintains test code. It must not run tests.

reviewAgent reviews design, implementation, and tests. It must not modify files directly.

If the platform cannot enforce these boundaries technically, enforce them procedurally by separating role outputs and clearly labeling which role is acting.

## Workflow

### 1. Start Task

1. Create or identify a task id.
2. Create a task directory, preferably `.zyz-worker/tasks/<task-id>/`.
3. Create a status file from `templates/task-status.md`. This is the single mandatory overall task status file.
4. Record the task name, phase, known inputs, open questions, and current assumptions.
5. Record the user's full, final goal in the status file `## Total Goal` so the overall target cannot drift later (see Total Goal Fidelity).

### 2. Design

1. Work with the user to produce a Markdown design document from `templates/design-doc.md`. Decide whether one document is enough or whether the design should be split into multiple focused documents (by domain, module, layer, or step). Prefer splitting when the task touches several domains/modules/layers, the Implementation Plan has many steps, or a single document would grow long enough to dilute model context. When splitting, create a short index document that lists and links every part, and reuse the template (in full or partial form) for each part.
2. Ask the user about unclear requirements, constraints, non-goals, acceptance criteria, risky implementation details, and important tests.
3. When the design draft is ready, use reviewAgent to review it.
4. The main agent decides accept-or-reject for each review-agent finding based on the design and Goals. Do not present findings to the user.
5. Record rejected findings with reasons in the design document `## Review History` and the status file `## Design Review > Rejected Suggestions`.
6. Update the design document and status file. If a finding implies a goal-level or acceptance-criteria-level change, escalate to the user instead of unilaterally rewriting Goals.
7. Repeat review until reviewAgent says no changes are needed.
   This loop runs automatically without user input; only step 8 below is a user touch.
8. Ask the user for final human approval before implementation.

Do not enter implementation until both reviewAgent and the user approve the design.

### 3. Implementation And Testing

#### 3.0 Decide whether to split

The main agent decides on its own whether to split the task into SubTasks. Splitting is optional; do not ask the user. Consider splitting when:

- the change spans 3 or more directories or layers;
- the Implementation Plan lists 4 or more steps;
- the task includes independently verifiable sub-capabilities.

Not splitting is also valid for simple tasks.

#### 3.0.1 Implementation and testing run in parallel by default

In most cases implementation-agent and test-agent can work at the same time: both derive their work from the approved design document, so test-agent does not need to wait for the implementation to exist before writing tests. Dispatch them together (in a single batch) unless the design makes the tests depend on a concrete implementation detail that is not yet settled. Their outputs still converge at the test-run step (implementation-agent runs tests after both finish).

#### 3.0.2 Maximize parallelism: schedule by the dependency graph, not the list order

This is a general scheduling discipline, not limited to the implementation/test pair. At every dispatch point — before sending any subagent, review, or research request — the main agent must first ask: *of all the work that is not yet done, which items have no unmet dependency on each other right now?* Send every such ready, independent item in a single batch (one message with multiple tool calls), then wait.

The common failure this prevents: treating the order things are written down (SubTask 1, 2, 3; step a, b, c) as if it were a dependency order, and so doing them one at a time. List order is not dependency order. Two SubTasks that both depend only on a third are independent of *each other* and must be dispatched together once that third is done — even though the list shows them sequentially. The same holds for multiple independent reviews, multiple research lookups, or any fan-out of work.

Concretely:

- Derive dependencies from the design's Implementation Plan and Files To Change (who reads/writes whose output), never from the numbering.
- When a blocking item completes, re-scan *all* remaining work and release every item it was the last blocker for — in one batch, not one at a time.
- Run items sequentially only when there is a real data dependency (item B consumes item A's concrete output) or a shared-state hazard (two items writing the same file). Record that reason if it is not obvious.
- Parallelism is a scheduling technique only; it never relaxes Total Goal Fidelity, the per-item review/test gates, or the dependency correctness below.

#### 3.A No-split path

When the task is not split, run a single iteration:

1. implementation-agent implements the engineering changes, and test-agent writes or updates tests from the design document. Run these two in parallel by default (see §3.0.1).
2. implementation-agent runs the tests.
3. If tests fail, implementation-agent classifies the failure; implementation-agent fixes implementation bugs and test-agent fixes invalid tests.
4. After tests pass, review-agent reviews implementation and tests. Each role decides accept-or-reject for findings affecting its artifact.
5. Repeat 2-4 until tests pass and review-agent reports no changes.

Then proceed to §3.C aggregate testing and aggregate review. Per-iteration test runs (§3.A step 2 / §3.B step 2) are not the aggregate gate; before delivery every category must be registered ran-or-skipped at §3.C and verified at §4.

#### 3.B Split path

When split, the main agent records SubTasks in the status file `## SubTasks` section. For each SubTask:

1. implementation-agent implements that SubTask's engineering changes, and test-agent writes or updates tests for that SubTask. Run these two in parallel by default (see §3.0.1).
2. implementation-agent runs that SubTask's tests.
3. If tests fail, implementation-agent classifies and the responsible role fixes; loop until tests pass.
4. review-agent reviews the SubTask's implementation and tests. Each role decides accept-or-reject and records rejections (prefixed with SubTask ID) in `## Implementation Review > Rejected Suggestions`.
5. Loop 2-4 until tests pass and review-agent reports no changes for this SubTask.
6. Set the SubTask's `Coded`, `Tested`, `Reviewed` flags to true:
   - `Coded: true` when implementation is complete.
   - `Tested: true` when this SubTask's tests pass.
   - `Reviewed: true` when review-agent reports no changes for this SubTask (rejected findings allowed if reasons are recorded).
7. Update the overall task status file (and this SubTask's status file, if one exists) to reflect the completed SubTask before moving on. Do not leave the progress only in the conversation.
8. After a SubTask is complete, autonomously create one git commit for that SubTask's changes (one commit per completed SubTask). See Version Control — commit and push without asking, and never let a commit or push failure interrupt the task.

Do not start SubTask N+1 until SubTask N has all three flags true, unless the main agent records SubTask N as "blocked, deferred" with all of the following:

- a written rationale showing no later SubTask has a static dependency on SubTask N's code path (per the design's Implementation Plan and Files To Change);
- an entry added to `## Progress > Blocked` and the SubTask's `Notes`.

SubTasks are scheduled by their dependency graph, not by their list order (see §3.0.2). Dispatch independent SubTasks — those with no unmet dependency on each other — together in one batch. The dependency-correctness rule above still holds for each chain: do not start a SubTask until the SubTasks it actually depends on have all three flags true. So in a typical fan-out where ST2 and ST3 both depend only on ST1, run ST1 first, then dispatch ST2 and ST3 in parallel once ST1 is done — do not serialize ST2 then ST3 just because the list numbers them in order. Record a real data dependency or shared-file hazard in `## SubTasks > Notes` when it forces two SubTasks to run sequentially.

#### 3.C Aggregate testing and aggregate review

When all SubTasks (or the single no-split iteration) are complete, run:

1. Aggregate testing by implementation-agent must account for every category — unit tests, end-to-end tests, regression tests (plus pressure tests when the design's `## Risks` calls out performance or capacity risk). For each category, record it in the status file `## Final Aggregate Testing` per-category checklist as either `ran` (with its result) or `skipped` (with a non-empty reason). This is a registration requirement, not a "must run all" requirement: a cost-bearing category may be skipped, but it must never be silently omitted.
2. Aggregate review by review-agent across all SubTasks for consistency, contracts, and regression. Each role decides accept-or-reject for findings affecting its artifact; rejections recorded as in §3.B. Record the verdict in the status file `## Final Aggregate Review`.
3. Loop aggregate test and aggregate review until both converge.

The final report's `## Tests` section must enumerate the aggregate categories actually executed (unit / e2e / regression / pressure if applicable). The final report's `## Review Result` section must record the aggregate review verdict separately from per-SubTask verdicts when SubTasks were used.

### 4. Deliver

1. Verify the final output against the recorded Total Goal (design `## Goals` and status `## Total Goal`). Confirm nothing from the user's stated target was silently narrowed, deferred, or replaced with a placeholder. If any gap remains, either close it or escalate to the user — do not deliver a reduced version as final.
2. Verify `## Final Aggregate Testing` (populated at §3.C) registers **every required category** (unit / e2e / regression; plus pressure when `## Risks` demands it) as either `ran` (with result) or `skipped` (with a non-empty reason). If any required category is unregistered, do not deliver — run it or record an explicit skip reason first. A cost-bearing test (e.g. e2e consuming API quota) may be skipped, but the reason must be recorded; in orchestrated or standalone mode, ask the user before skipping a cost-bearing test when feasible — never silently omit a category.
3. Update the status file with final phase, completed work, test results, review result, assumptions, and known risks.
4. Autonomously create a final commit for the overall task and push if a remote is configured (see Version Control — do not ask, do not block on failure).
5. Produce a final report from `templates/final-report.md`.
6. Ask the user whether to delete the task status files.

## Long-Running Work

During long implementation phases, the main agent should keep the status file current. Record the active role, latest output, blocked items, next action, and restart notes.

If a subagent is stuck, interrupted, or silent for too long, the main agent should restart that role if the platform supports it. If no real subagent runtime exists, resume from the status file and re-issue the relevant role prompt with the latest design and status summary.

See also [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md) — long-running tasks must persist state to files, not context.

## Optional Skills And Plugins

Before writing design docs, implementation, tests, or review reports, check whether the current agent already has relevant skills, plugins, or tools available.

Examples:

- Use documentation skills or plugins, such as llmdoc, to improve design document quality if already available.
- Use engineering workflow skills or plugins, such as superpowers, to improve implementation or review quality if already available.
- Use language, framework, testing, browser, document, or spreadsheet skills when the task naturally needs them.

Do not block, fail, or ask the user to install anything when these optional capabilities are unavailable.

When optional capabilities are used, record them briefly in the task status file or final report.

## Orchestrated Mode

When the environment variable `ZYZ_WORKER_STATUS_FILE` is set, this skill runs in orchestrated mode — i.e. it has been dispatched by the `orchestration-scheduling-task` skill into its own tmux session. In this mode the main agent (and every subagent through it) MUST flush a small status snapshot to that file path so the orchestrator can see what this worker is doing.

The required fields in `worker-status.md` are:

- `phase` — one of `design | implementation | testing | review | delivery | awaiting-confirmation | error`
- `phase-since` — ISO timestamp of when the current `phase` was entered
- `wait-state` — one of `none | waiting-user | waiting-subagent | waiting-resource`
- `waiting-reason` — free text, non-empty only when `wait-state != none`
- `expected-resume-by` — ISO timestamp, non-empty only when `wait-state != none`
- `last-flush` — ISO timestamp of this write

Hard rules in orchestrated mode:

- **Flush before any suspend.** Before suspending, before dispatching a subagent, after receiving a subagent result, and on entering any new workflow phase, write `ZYZ_WORKER_STATUS_FILE` atomically (tmpfile + rename). Never edit the file in place.
- **`worker-status.md` must be a valid YAML frontmatter document.** Write all required snapshot fields enclosed in a single pair of `---` fences, with the very first line of the file being `---`, the fields next, and a closing `---` line. A bare field dump without fences (e.g. a file that starts directly with `phase: review`) is malformed: the orchestrator's frontmatter parser reads nothing and cannot see this worker's progress. The shipped `skills/orchestration-scheduling-task/templates/worker-status.md` template already has the correct shape — match it.
- **`phase` may roll back, except `awaiting-confirmation` which is absorbing.** `phase` MAY move both forward and backward among `design`, `implementation`, `testing`, `review`, `delivery`, and `awaiting-confirmation` to reflect real iteration — e.g. a review that returns to substantial implementation work rolls the phase back from `review` to `implementation`. The ONLY non-reversible phase is `awaiting-confirmation`: once written, never change it to an earlier phase. It is the **absorbing** state, meaning the worker self-declares finished and is awaiting user confirmation; the worker never self-reaches any later state. `error` remains reversible — after the error is fixed, resume to a working phase.
- **`wait-state` is orthogonal to `phase`.** Set `wait-state` independently from `phase`. Set `wait-state=waiting-user`/`waiting-subagent`/`waiting-resource` with a non-empty `waiting-reason` before suspending; set `wait-state=none` immediately on resume.
- **Async user Q&A goes through files.** Use `ZYZ_QUESTION_FILE` and `ZYZ_ANSWER_FILE` when the user is not attached to the tmux pane. After consuming an `answer.md`, rename it to `answer.md.consumed.<question-id>`.
- **Two status files, not one.** Orchestrated mode keeps the existing `.zyz-worker/tasks/<task-id>/status.md` as the worker's detailed task status (used by execute-task workflow), and adds `worker-status.md` at the path in `ZYZ_WORKER_STATUS_FILE` as the orchestrator-facing snapshot. The two files do not replace each other.

Phase mapping (when each phase value must be written to `worker-status.md`):

| execute-task workflow position | phase to write | flush moment |
|---|---|---|
| §1 Start Task | `design` | when initializing the task status file |
| §2 Design (all of it, including review loops) | `design` | once on entry; on each return to main agent |
| §3.A step 1 / §3.B step 1 — implementation-agent dispatched | `implementation` | before dispatching the subagent |
| §3.A step 2 / §3.B step 2 — test-agent / running tests | `testing` | before dispatching / before running |
| §3.A step 5 / §3.B step 5 — review-agent dispatched | `review` | before dispatching |
| §3.B step 6 — review → implementation revisions loop | `review` (held by default; MAY roll back to `implementation` if it genuinely returns to substantial implementation work — rollback is allowed) | no flush |
| §3.C aggregate testing | `testing` | on entry |
| §3.C aggregate review | `review` | on entry |
| §4 Deliver | `delivery` | on entry |
| final report shipped (worker's furthest self-reachable state) | `awaiting-confirmation` | last write |
| unrecoverable error | `error` (set `wait-state=none`) | immediately |

The worker never writes a "done" phase. The real "done" = delivery is recorded by the orchestrator (L1) as master-entry `state: completed` on explicit user confirmation; merge to base is a separate, independently-tokened action that may or may not happen — see `skills/orchestration-scheduling-task/SKILL.md` `## State Machine`.

If `ZYZ_WORKER_STATUS_FILE` is unset, ignore this entire section — the skill runs in standalone mode and behaves exactly as the rest of the document describes.

### Maintenance note

This section is coupled to the `orchestration-scheduling-task` skill's contract. If the execute-task workflow gains a new phase, extend the `phase` enum here and in `skills/orchestration-scheduling-task/templates/worker-status.md`, and extend the phase mapping table here in lockstep.
