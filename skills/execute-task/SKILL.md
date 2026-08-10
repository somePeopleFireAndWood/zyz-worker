---
name: execute-task
description: Use when the user wants help executing a single confirmed development task with a design-first workflow, a user-facing main agent, prompt-only subagents, task status tracking, implementation, tests, review, and final delivery.
---

# Execute Task

Use this skill to help a user execute a single confirmed code development task — design through delivery. This is zyz-worker's "execute one task" skill; higher-level multi-task orchestration belongs to the `orchestration-scheduling-task` skill in this same plugin and is out of scope here. The workflow is design-first, user-led during design, and coordinated by the current conversation agent using a main-agent prompt plus prompt-only subagent roles.

This skill does not require hooks, scripts, MCP servers, background services, or a real subagent runtime. The main-agent prompt applies to the current user-facing conversation agent. If the current agent environment can launch subagents, use the prompts in `../../subagents/` for implementationAgent, testAgent, and reviewAgent. If it cannot, use those files as role instructions and preserve the same responsibility boundaries in the conversation. When the plugin's watchdog hooks and monitor are available they mechanically harden this workflow (see `## Watchdog Enforcement`), but their absence never blocks it.

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
- The design document must be clear enough that implementationAgent, testAgent, and reviewAgent can proceed without asking the user again unless there is a blocking issue. This "proceed without asking" license applies only AFTER the human approval at §2 step 8 has actually been given (or a recorded explicit prior skip instruction) — never on the user's silence at the gate.
- Maintain a task status file for the full workflow: design, implementation, testing, review, and delivery.
- There must always be exactly one overall task status file that records overall state and progress. Each SubTask may optionally keep its own SubTask-status file recording that SubTask's implementation, test, review, and auto-fix progress, but the single overall status file is mandatory.
- Status and progress must be persisted to the status files. Do not report progress only in the conversation. Whenever a SubTask completes (or any phase changes), write the update into the overall task status file and the relevant SubTask-status file (if one exists) before moving on.
- Use existing installed skills, plugins, or tools when they improve document or code quality, but never require the user to install missing optional capabilities.
- Prefer continuing through non-blocking ambiguity with documented assumptions. Stop and ask the user only when continuing would risk data loss, irreversible changes, or a serious mismatch with the design. In addition, the design→implementation approval gate (§2 step 8) is an unconditional stop-and-wait regardless of reversibility — see the Automatic Execution Policy; documenting an assumption never satisfies it.
- The design document and the final report default to the same language as the user in this conversation. Other artifacts (task status, review reports, prompt files) stay in their current language.
- Long-running tasks must persist progress, decisions, blockers, and the next step into the task status file; the conversation context is for execution only. See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md).

## Automatic Execution Policy

By default, do not ask the user. Inside the workflow loops, each role decides for itself:

- During design review, the main agent decides whether to accept or reject each review-agent finding. Rejected findings are recorded with reasons in the design document `## Review History` and the status file `## Design Review > Rejected Suggestions`.
- During implementation review, the role responsible for the changed artifact (implementation-agent for implementation, test-agent for tests) decides whether to accept or reject each finding. Rejected findings are recorded in the status file `## Implementation Review > Rejected Suggestions`, prefixed with the originating SubTask ID when SubTasks are used.
- When a test fails, implementation-agent attributes it in order — change-surface causality, tooling failure, someone else's in-flight edit / environment, and only then a real regression (its `## Test Failure Handling`) — then implementation-agent fixes implementation bugs and test-agent fixes invalid tests. Under parallel execution the third bucket is the most frequent; forcing every failure into "my bug or their bad test" makes agents fix correct code.

Escalate to the user only when:

- the decision would cause data loss, an irreversible change, or a serious deviation from the agreed Goals / Acceptance Criteria;
- the design phase reaches the final human approval step (one explicit user touch before implementation starts) — this is a hard stop the agent must WAIT at, not an escalation it can satisfy-and-move-past;
- the same finding flips between accept and reject across three or more automated iterations without convergence.

The design phase's review loop (§2 step 7 below) iterates automatically — no user input between iterations — until review-agent reports no changes needed. Only §2 step 8 (final human approval before implementation) is a user touch. This design-approval gate is a hard stop, not an escalation the agent can satisfy-and-move-past: absent explicit user approval (or a recorded explicit prior skip instruction), the workflow holds at the design phase indefinitely and does not enter implementation. The "By default, do not ask the user" posture above and the "prefer continuing through non-blocking ambiguity" guidance do NOT apply to this gate.

### PR Review Handling (external review feedback)

This is separate from the internal review-agent loop. When the main agent receives **PR review results** — review comments, "changes requested" verdicts, inline threads, or automated findings posted on an actual pull request (by humans, maintainers, bots, or CI/LLM review tools) — it must NOT blindly accept and apply every item. External review is advisory, not a command. The main agent processes the findings **one at a time**, and for each one **independently verifies whether the problem objectively exists** before deciding, then splits the feedback into two buckets:

- **Confirmed to objectively exist** (independently reproduced or traced — a real bug, genuine defect, or a sound improvement consistent with Goals and the approved design) are routed to the responsible role (implementation-agent or test-agent), fixed, verified through the normal test + review gates, and acknowledged on the PR thread.
- **Does not hold** (after verification: misreading, factually wrong, cannot be reproduced, contradicting the approved design or Goals, or out of scope) are NOT applied. The main agent instead posts a comment on the PR — on the specific thread when possible — declining/rejecting the change and stating the concrete reason.

Rules: verify each finding independently against the actual code/design/tests before deciding, one at a time (a finding is not correct merely because of who or what raised it, and findings are never batch-accepted); never silently ignore a finding — every item ends as accepted-and-fixed or explicitly-rejected-with-a-posted-reason; escalate to the user when a finding would change Goals or Acceptance Criteria, or when the same finding loops accept↔reject three or more times without convergence; record every decision in the status file `## PR Review`. Use the platform PR CLI (`gh pr`/`gh api`, `glab mr`, or the repo's configured tool) to post comments; posting is visible to others, so keep it professional. See `prompts/main-agent.md` `## PR Review Handling` for the full contract.

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

### Recovering a stuck role: never trade scope for a delivery

A stalled or timed-out role creates pressure to "just get something out of it". The specific failure to avoid is **reducing what was asked for so the role can finish**. Reducing the per-round output volume is always allowed; reducing the total deliverable requirement never is.

- Allowed: split the work into labeled steps or dimensions and take one per message; smaller successive edits; riskiest part first; less context to re-read.
- Forbidden in any recovery or re-dispatch instruction: "just the overall verdict", "only the top 3 findings", "most severe N is enough", "a one-line conclusion is fine", "skip the details", "只要总结论", "最严重 3 条就行", "一句话结论也行", plus count caps ("limit to 3 findings", "no more than 3", "blockers only", "重点问题就行").
- Staging is not a loophole: a capped first installment is acceptable only as real staging — commit to the remainder, record the step plan in `## Restart And Recovery Notes`, and actually collect every installment. An untracked promise to continue is a scope reduction wearing a disguise.
- This is a distinct surface from Total Goal Fidelity, which guards the user's stated goal and the overall deliverable. A single role's asked-for scope — a review's coverage, a test suite's breadth, an implementation step's completeness — can be shrunk without tripping that rule, and the incomplete result then passes every downstream gate looking clean.
- Standard recipe: re-dispatch at the same full scope with an explicit N-step split, one message per step, flushing each step before the next; for a review, split along the coverage dimensions (see §3.C). Record the recovery event and step plan in the status file `## Restart And Recovery Notes`.
- A role that proposes or delivers its own reduced scope is sent back with the step-split recipe, not accepted. If it genuinely cannot complete the scope after retries, escalate to the user with what is and is not covered — never record a partial result as complete.

## Version Control

zyz-worker is designed to complete the whole task autonomously from the design document, so version-control steps run on their own and never block the workflow.

- Commit autonomously. Create a commit after each completed SubTask, and a final commit for the overall task. Do not stop to ask the user whether to commit.
- Push autonomously when a remote/upstream is configured. Do not stop to ask the user whether to push.
- Commit and push are non-blocking. If a commit or push fails (no remote, auth, hook, conflict, or any other reason), record the failure in the status file and continue the task. A failed commit or push is never a blocker and must not interrupt or pause the workflow.
- Still respect destructive-action safety: do not force-push, reset --hard, or rewrite published history on your own. On a shared working tree (parallel-agent worktrees), `git stash push/pop` is also treated as destructive — another agent's stash may be present and a pop can land on the wrong state (a conflicted `go.mod` still BUILDS but breaks `go test` at module parse, which reads as "their code is broken"); use `git diff > /tmp/<name>.patch` + `git apply -R` for temporary set-asides. **`git checkout <file>` / `git restore <file>` on a shared working tree are destructive in the same way**: they reset to HEAD and delete every agent's uncommitted work in that file, and never-committed content is in no git recovery mechanism (no reflog, no stash, no fsck) — a real incident lost a ~5000-char security guard this way while `go build` stayed green. Revert only your own change, from a backup copy taken before editing (or `git apply -R` of your own diff); read the committed version with `git show HEAD:<file>`. A PreToolUse hook (`checkout-guard.sh`) denies the dangerous form when the target has uncommitted modifications. Autonomy here covers ordinary `git commit` and `git push`, not destructive operations.
- On explicit user instruction (via conversation in standalone mode, or via a matching `## Pending Merge Approval` token in orchestrated mode), the worker MAY also `git merge` the task branch into its base and push the result — this still respects the no-force-push / no-history-rewrite limit. Autonomy never covers merge to base; only user-instructed merges are allowed. In orchestrated mode the orchestrator performs the merge (the worker does not), to avoid both layers writing the base concurrently. For a multi-worktree task each repo merges on its own branch into its own base — the merge is per-repo (see the multi-worktree rules under `## Orchestrated Mode`).

## Role Boundaries

The main agent is the current user-facing conversation agent. It coordinates and records. It must not directly write implementation code, modify tests, run tests, or perform review.

implementationAgent writes implementation and runs tests. It must not modify test code.

testAgent writes and maintains test code. It must not run tests.

reviewAgent reviews design, implementation, and tests. It must not leave any modified file as a deliverable. It MAY, however, run tests read-only and inject throwaway mutations to measure discriminating power — this workflow grants that boundary change explicitly (it is why `agents/review-agent.md` carries `Bash`). The conditions are hard: every injected edit is restored **from a backup copy taken before mutating** (never via `git checkout`/`git restore`, which reset to HEAD and on a shared worktree delete other agents' uncommitted work — a real incident lost ~5000 chars of guard code that way with the build staying green), verified per-file against that backup (not "`git status` clean", which a shared tree legitimately never is), and an unverifiable restoration is reported as an incident rather than swallowed. The reason for the grant: a read-only review can check whether an argument is self-consistent but not whether its inputs were real, so auditing a report without re-deriving it co-signs the author's tool failures — and measured, reading alone caught none of the silently-empty assertions that mutation injection caught.

Under this grant reviewAgent is a test-running lane like any other, so when it runs tests concurrently with an implementation lane it needs its own resource lease (§3.0.3) — never the lane's ports or test DB, or the two will silently probe each other's processes.

If the platform cannot enforce these boundaries technically, enforce them procedurally by separating role outputs and clearly labeling which role is acting.

## Workflow

### 1. Start Task

1. Create or identify a task id.
2. Create a task directory, preferably `.zyz-worker/tasks/<task-id>/`.
3. Create a status file from `templates/task-status.md`, named `status.md` inside the task directory. This is the single mandatory overall task status file. The filename `status.md` is load-bearing: the watchdog layer resolves the overall status file as `<task-dir>/status.md`, so a differently-named file leaves L1/L3/L4 freshness enforcement silently inert (see `## Watchdog Enforcement`).
4. Write the task id (a single line) into the pointer file `.zyz-worker/current-task` **under the session cwd** — the directory this conversation is running in, which is what the hooks receive as `cwd`. "Project root" is ambiguous here and has caused a real outage: `git rev-parse --show-toplevel` returns the *worktree* root inside a linked worktree, so a task run in a worktree created by the `git-worktree` skill (which places worktrees OUTSIDE the main checkout and does not cd into them) ends up with its pointer somewhere the session cwd is not inside.
   - **If the task directory is not under the session cwd, the pointer's contents MUST be an ABSOLUTE path to the task directory.** A bare id (or a relative path) is resolved against the directory holding the pointer, so it cannot reach across trees.
   - The resolver does try sibling git worktrees of the same repo as a fallback, but that is a safety net with a real ambiguity (two concurrent runs in one repo can attach to the wrong task); a correctly-placed pointer is still the contract.
   - This pointer is what the plugin's watchdog hooks and monitor use to locate the active task; without a resolvable pointer the entire watchdog layer silently no-ops (see `## Watchdog Enforcement`).
   - **Verify the layer actually armed.** After a few tool calls (the heartbeat hook is async, so it is not written on the very first one), confirm `<task-dir>/runtime/agents/main.heartbeat` exists. If it does not, the watchdog is inert: say so explicitly in the status file and to the user rather than proceeding as if protected — an unarmed watchdog is indistinguishable from a healthy quiet one, which is how a full task once ran with every layer inert and two dead subagents unreported.
5. Record the task name, phase, known inputs, open questions, and current assumptions.
6. Record the user's full, final goal in the status file `## Total Goal` so the overall target cannot drift later (see Total Goal Fidelity).

### 2. Design

1. Work with the user to produce a Markdown design document from `templates/design-doc.md`. Decide whether one document is enough or whether the design should be split into multiple focused documents (by domain, module, layer, or step). Prefer splitting when the task touches several domains/modules/layers, the Implementation Plan has many steps, or a single document would grow long enough to dilute model context. When splitting, create a short index document that lists and links every part, and reuse the template (in full or partial form) for each part.
2. Ask the user about unclear requirements, constraints, non-goals, acceptance criteria, risky implementation details, and important tests.
3. When the design draft is ready, use reviewAgent to review it.
4. The main agent decides accept-or-reject for each review-agent finding based on the design and Goals. Do not present findings to the user.
5. Record rejected findings with reasons in the design document `## Review History` and the status file `## Design Review > Rejected Suggestions`.
6. Update the design document and status file. If a finding implies a goal-level or acceptance-criteria-level change, escalate to the user instead of unilaterally rewriting Goals.
7. Repeat review until reviewAgent says no changes are needed.
   This loop runs automatically without user input; only step 8 below is a user touch.
8. Wait for explicit final human approval before implementation. The main agent MUST NOT proceed to §3 until the user has given **explicit user approval** — an affirmative, unambiguous go-ahead to enter implementation (a reply to a Goals/Acceptance-Criteria escalation during design is NOT such a go-ahead). On user timeout, silence, or absence, WAIT indefinitely and NEVER self-advance into implementation. The ONLY exception is an **explicit prior skip instruction**: an instruction that explicitly authorizes skipping THIS design→implementation approval (e.g. "design then implement and release directly", "skip approval"). Generic expressions of trust or autonomy ("work autonomously", "I trust you", "I'll be away") do NOT count, and a bare goal statement ("release a version") does NOT count. Before invoking the exception, record the verbatim skip instruction into the status file `## Design Review > Design Approval Record`; do not self-advance on an unrecorded exception.

Do not enter implementation until both reviewAgent and the user approve the design. Never self-advance from design to implementation on timeout, silence, or user absence — proceed only on explicit user approval, or when the user gave an explicit prior instruction to skip this gate that has been recorded verbatim in the status file `## Design Review > Design Approval Record`.

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
- Run items sequentially only when there is a real data dependency (item B consumes item A's concrete output). Record that reason if it is not obvious.
- A shared FILE is not by itself a serialization reason. Assembly points (`main.go` wiring, service facades) are naturally appended to by several parallel SubTasks; serializing on them collapses genuinely independent work into a chain. Instead, declare the hotspot at dispatch time: list the shared files and give each lane its own insertion region; each agent appends only within its region and never reorders others' code. Serialize only when two items would REWRITE the same logic, not merely touch the same file.
- Parallelism is a scheduling technique only; it never relaxes Total Goal Fidelity, the per-item review/test gates, or the dependency correctness below.

#### 3.0.3 Parallel resource leases (mandatory at ≥2 concurrent lanes)

Under parallel execution, "green" is a claim about an environment, and shared environments make both false reds and — worse — false greens. Two measured failure classes: parallel lanes truncating shared dev-DB tables produce waves of spurious failures that look like real regressions (deadlocks, vanishing rows, "green → 3 red → green" on the same command); and a port collision does not even error — a wrong port env name is silently ignored, the process binds the default port, and the probe happily tests SOMEONE ELSE'S server (a DB collision fails loudly; a port collision fails silently).

Before dispatching ≥2 concurrent lanes, the main agent assigns leases and records them in the status file `## Parallel Resource Leases`:

- Each lane gets an exclusive FULL port group (HTTP / gRPC / metrics / pprof — pprof is the most-missed) and its own test database.
- Sharing a dev DB across lanes is prohibited; full-table cleanup (TRUNCATE and friends) against any shared DB is prohibited.
- After starting a service, the lane must positively confirm it is talking to its own instance (probe an identifying endpoint), not assume.
- Exactly one lane per batch owns regenerating shared build artifacts (bundle/dist); generated-file churn from a non-owner lane turns formatting checks red for reasons unrelated to any code change.
- **Mutation execution does not run concurrently with other lanes' edits to the same files.** A lane that temporarily modifies production files (mutation testing, large-scale refactor probes) either gets its own worktree (`isolation: worktree` at dispatch, when available) or runs while no other lane has uncommitted work in the files it will touch — its revert step is the single most dangerous write on a shared tree (see Version Control: the checkout accident class). Backup-copy discipline is mandatory either way; isolation removes the shared-write hazard at the root.

#### 3.A No-split path

When the task is not split, run a single iteration:

1. implementation-agent implements the engineering changes, and test-agent writes or updates tests from the design document. Run these two in parallel by default (see §3.0.1).
2. implementation-agent runs the tests, and executes test-agent's mutation manifest (each coverage claim's mutation applied → named cases red → restored byte-identical).
3. If tests fail, implementation-agent attributes the failure FIRST — change-surface causality, then tooling, then concurrent edits/environment, then real regression (see its `## Test Failure Handling`) — and only then fixes: implementation-agent fixes implementation bugs and test-agent fixes invalid tests. The parallel-execution case (someone else's in-flight edit) is a real third bucket, not a variant of "invalid test".
4. After tests pass, obtain implementation-agent's workspace-frozen declaration, record it in the status file, then review-agent reviews implementation and tests. Each role decides accept-or-reject for findings affecting its artifact.
5. Repeat 2-4 until tests pass (with mutations killed) and review-agent reports no changes.

Then proceed to §3.C aggregate testing and aggregate review. Per-iteration test runs (§3.A step 2 / §3.B step 2) are not the aggregate gate; before delivery every category must be registered ran-or-skipped at §3.C and verified at §4.

#### 3.B Split path

When split, the main agent records SubTasks in the status file `## SubTasks` section. For each SubTask:

1. implementation-agent implements that SubTask's engineering changes, and test-agent writes or updates tests for that SubTask. Run these two in parallel by default (see §3.0.1).
2. implementation-agent runs that SubTask's tests, and executes test-agent's mutation manifest for the SubTask (each coverage claim's mutation applied → named cases red → restored byte-identical).
3. If tests fail, implementation-agent attributes first (change-surface → tooling → concurrent edits → real regression, per its `## Test Failure Handling`) and the responsible role fixes; loop until tests pass.
3.5. **Freeze.** Before dispatching review, obtain that lane's implementation-agent workspace-frozen declaration and record it (with the frozen file set) in the status file; the reviewed files must not change during the review. review-agent records mtimes/hashes at start and re-checks at finish — a mid-review change voids the review, which is reported for re-dispatch, not patched. Without this, in parallel execution the review's conclusion may describe a tree that no longer exists.
4. review-agent reviews the SubTask's implementation and tests. Each role decides accept-or-reject and records rejections (prefixed with SubTask ID) in `## Implementation Review > Rejected Suggestions`.
5. Loop 2-4 until tests pass (with mutations killed) and review-agent reports no changes for this SubTask.
6. Set the SubTask's `Coded`, `Tested`, `Reviewed` flags to true. **Flipping any one of these bits is not complete until the MAIN status file is written — the write is part of the transition, not a follow-up.** Do not batch several flips and reconcile later, and do not update only the SubTask's own file: a main file that says "not done" while `subtasks/*.md` say "done" is the single most expensive failure mode for a recovering session, because the main file is the first thing it reads. Observed: a 9-SubTask task whose main file froze at ST1 while all nine were implemented, tested, reviewed and pushed — recovery misjudged the interruption point and had to reconstruct it from `git log` plus transcripts, and treated every status conclusion as untrustworthy.
   - `Coded: true` when implementation is complete.
   - `Tested: true` when this SubTask's tests pass **and every mechanism claimed as covered has a recorded killed mutation** (from the executed manifest). Green alone is "ran", not "tested" — measured reality: the no-op assertions that green hides are found by mutation injection and not by review.
   - `Reviewed: true` when review-agent reports no changes for this SubTask (rejected findings allowed if reasons are recorded) AND that review registered every coverage dimension (§3.C step 2). A review whose dimensions are unregistered — for example one that only reported its worst few findings — does not satisfy this flag. Like the per-iteration test runs, this per-SubTask review is not the aggregate registration gate; §3.C and §4 still apply.
7. Update the overall task status file (and this SubTask's status file, if one exists) to reflect the completed SubTask before moving on. Do not leave the progress only in the conversation.
8. After a SubTask is complete, autonomously create one git commit for that SubTask's changes (one commit per completed SubTask). See Version Control — commit and push without asking, and never let a commit or push failure interrupt the task. **Exception — shared assembly files:** when a batch of parallel SubTasks all append to shared wiring files and per-SubTask commits would create commits that DO NOT COMPILE (one SubTask's wiring without the sibling's), commit the smallest compilable unit instead: one commit covering those SubTasks, its message listing each SubTask's scope, and the deviation recorded in the status file. "One SubTask, one commit" is a readability convention; "every commit compiles" is a hard constraint (bisect, CI, and rollback all depend on it).

Do not start SubTask N+1 until SubTask N has all three flags true, unless the main agent records SubTask N as "blocked, deferred" with all of the following:

- a written rationale showing no later SubTask has a static dependency on SubTask N's code path (per the design's Implementation Plan and Files To Change);
- an entry added to `## Progress > Blocked` and the SubTask's `Notes`.

SubTasks are scheduled by their dependency graph, not by their list order (see §3.0.2). Dispatch independent SubTasks — those with no unmet dependency on each other — together in one batch. The dependency-correctness rule above still holds for each chain: do not start a SubTask until the SubTasks it actually depends on have all three flags true. So in a typical fan-out where ST2 and ST3 both depend only on ST1, run ST1 first, then dispatch ST2 and ST3 in parallel once ST1 is done — do not serialize ST2 then ST3 just because the list numbers them in order. Record a real data dependency in `## SubTasks > Notes` when it forces two SubTasks to run sequentially; a shared assembly file is declared as a hotspot with per-lane insertion regions (§3.0.2), not treated as a dependency.

#### 3.C Aggregate testing and aggregate review

When all SubTasks (or the single no-split iteration) are complete, run:

1. Aggregate testing by implementation-agent must account for every category the design's `## Testing Plan` calls for — the standing set is unit tests, end-to-end tests, regression tests (plus pressure tests when the design's `## Risks` calls out performance or capacity risk), but the Testing Plan's own categories are authoritative: a category the user named (frontend tests, per-SDK e2e, …) gets its own registration line rather than being squeezed into the nearest standing slot, and each registered category carries a one-line note of that layer's structural coverage ceiling. For each category, record it in the status file `## Final Aggregate Testing` per-category checklist as either `ran` (with its result) or `skipped` (with a non-empty reason). This is a registration requirement, not a "must run all" requirement: a cost-bearing category may be skipped, but it must never be silently omitted. A fixed enumeration would let a user-named, explicitly-not-skippable category pass the delivery gate silently just because the template had no slot for it.
2. Aggregate review by review-agent across all SubTasks for consistency, contracts, and regression. Review coverage is registered per dimension exactly as test categories are: **design conformance, correctness, test quality, regression risk**, plus one dimension per risk the design's `## Risks` calls out. Each dimension is registered as `covered` or `not-covered: <reason>` in the review report's `## Coverage Dimensions` section and mirrored into the status file `## Final Aggregate Review`. A review with an unregistered dimension is NOT closed, whatever verdict it reports — this is what prevents a review that only reported its worst few findings from passing as complete. Each role decides accept-or-reject for findings affecting its artifact; rejections recorded as in §3.B. Record the verdict in the status file `## Final Aggregate Review`.
3. Loop aggregate test and aggregate review until both converge.

The final report's `## Tests` section must enumerate the aggregate categories actually executed — the same Testing-Plan-derived list registered at §3.C step 1 (unit / e2e / regression / pressure are the standing examples; a user-named category gets its own line), each with a one-line note of that layer's structural coverage ceiling. The final report's `## Review Result` section must record the aggregate review verdict separately from per-SubTask verdicts when SubTasks were used.

### 4. Deliver

1. Verify the final output against the recorded Total Goal (design `## Goals` and status `## Total Goal`). Confirm nothing from the user's stated target was silently narrowed, deferred, or replaced with a placeholder. If any gap remains, either close it or escalate to the user — do not deliver a reduced version as final.
2. Verify `## Final Aggregate Testing` (populated at §3.C) registers **every required category** (the design `## Testing Plan`'s categories — at minimum unit / e2e / regression, plus pressure when `## Risks` demands it, plus any user-named category) as either `ran` (with result) or `skipped` (with a non-empty reason), each carrying its one-line structural-coverage-ceiling note. The ceiling matters because same-named layers are not substitutes: frontend unit tests and browser e2e have opposite structural limits (one cannot reach real backend contracts, the other cannot enumerate precision cases), so "we did e2e" never covers what the unit layer owed. If any required category is unregistered, do not deliver — run it or record an explicit skip reason first. A cost-bearing test (e.g. e2e consuming API quota) may be skipped, but the reason must be recorded; in orchestrated or standalone mode, ask the user before skipping a cost-bearing test when feasible — never silently omit a category.
3. Verify `## Final Aggregate Review` registers **every coverage dimension** (design conformance / correctness / test quality / regression risk; plus one per risk `## Risks` calls out) as either `covered` or `not-covered` with a non-empty reason. If any dimension is unregistered, do not deliver — get it covered or record an explicit reason first. Same contract as the testing gate above: a dimension may go uncovered for a stated reason, but it must never be silently omitted. Also check `## Restart And Recovery Notes` for any staged delivery whose later installments never arrived; an outstanding installment is an uncovered dimension, not a completed one.
4. Verify the status file `## Pre-Delivery Checklist` is answered item by item with evidence (test effectiveness incl. mutation evidence, verdict hygiene, environment coordinates, attribution/collaboration, scope sweeps and the `## Weakest Link` self-disclosure). An unanswered item blocks delivery exactly as an unregistered test category does; "the rest are fine" is not an answer.
5. Update the status file with final phase, completed work, test results, review result, assumptions, and known risks.
6. Autonomously create a final commit for the overall task and push if a remote is configured (see Version Control — do not ask, do not block on failure).
7. Produce a final report from `templates/final-report.md`. After shipping the final report the worker enters `phase=awaiting-confirmation` and WAITS for the user to confirm delivery; it does not self-advance.
8. Advance to `phase=done` ONLY when the user confirms — either directly in the worker window/conversation (standalone or attached), or via an L1-relayed confirmation message arriving in the pane. The worker never self-advances to `done`. On user confirmation, flush `phase=done` (atomically, valid frontmatter) in orchestrated mode. `done` is the sole non-reversible absorbing terminal.
9. Ask the user whether to delete the task status files.

## Resuming An Existing Task

When picking up a task that was already in flight (a frozen or restarted session), the status file is the FIRST thing you read — and it is the thing most likely to be stale, because it only advances when somebody remembers to write it. Before trusting any of it, cross-check it against sources that advance by themselves:

1. **`git log` / `git status`** for the task's branch. Commits are written by the work itself, so they cannot lag the way the status file can. A `Coded: false` SubTask with commits implementing it means the status file is behind, not that the work is missing.
2. **`subtasks/*.md` against the main file.** These are written by different actors at different times; when they disagree, the more advanced one is usually right, and a SubTask file can also contradict *itself* (one section marking a piece complete while a later line still lists it as pending).
3. **`<task-dir>/runtime/agents/*.heartbeat`** to tell "lost" from "still running". A `.start` with no `.done` and a heartbeat that is still advancing means that role is ALIVE — re-dispatching it would put two agents in the same workspace writing the same files. A heartbeat that stopped long ago means it really is gone. This is what the L0 layer is for; if `runtime/` does not exist at all, the watchdog never armed (see §1 step 4) and you have no liveness evidence — say so rather than guessing.

If the cross-check finds a conflict, write the reconciled state into the main status file immediately and mark plainly which parts were reconstructed from code rather than recorded. Do not silently continue from a file you have just proven wrong; the next reader will trust it exactly as much as you did.

### Recovering destroyed uncommitted work from transcripts

When uncommitted work is lost (a checkout/stash accident, a crashed editor, a deleted file that never reached a commit), git has nothing: never-committed content is in no reflog, no stash, and `git fsck --lost-found` cannot see it. But **everything an agent ever wrote is recorded verbatim in its transcript**:

```text
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl              (main agent)
~/.claude/projects/<encoded-cwd>/<session-id>/subagents/agent-*.jsonl   (subagents)
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl                    (Codex events)
```

Each `tool_use` entry for Write carries the full file in `input.content`; each Edit carries `input.old_string`/`input.new_string`. Recovery procedure: identify WHICH agent wrote the lost content (the status file's agent state, or grep the transcripts for a distinctive identifier from the lost code), extract its Edit/Write inputs for the affected file, and **replay them in original order** — do not reconstruct from memory. This matters most for security-sensitive code (guards, adjudicators, redaction): a from-memory rebuild that is subtly wrong is a silent bypass, which is worse than the visible absence. Verify the replay with the tests that exposed the loss. This path recovered a ~5000-char guard function verbatim in the incident that motivated it.

## Long-Running Work

During long implementation phases, the main agent should keep the status file current. Record the active role, latest output, blocked items, next action, and restart notes.

**The status file is only worth what its last write is worth.** Every state transition writes through to the main file as part of the transition (§3.B step 6); it is never a separate bookkeeping pass to be done "when there is a pause". Two-layer drift — main file frozen while `subtasks/*.md` advance — is the specific shape that makes a recovering session misjudge where the work stopped.

If a subagent is stuck, interrupted, or silent for too long, the main agent restarts that role as a **continuation, never a redo**. Under long multi-instance runs, timeouts are the norm, not the exception; default-redo costs O(lanes × timeouts) repeated work AND leaves dirty data that masquerades as regressions. Three steps:

1. **Inventory first.** List what the interrupted role already produced on disk — files written, test DBs/fixtures/migrations created, ports held — using `git status` plus the resource-lease table. The inventory must come from disk, not from the interrupted context (which is gone).
2. **Resume, don't rebuild.** Put the inventory into the restart prompt as the continuation point, with an explicit "continue; do not recreate the following artifacts".
3. **Clean the debris.** An interrupted run must be assumed to have left dirty data (half-written fixture rows with fixed ids cause primary-key collisions that look exactly like implementation regressions — the tell: a rerun reproduces them stably, so it is not a race). Clean before rerunning.

Record each event as a new row in the status file `## Restart And Recovery Notes` (it is an append-only event list, not a single-slot form). If no real subagent runtime exists, resume from the status file and re-issue the relevant role prompt with the latest design and status summary. Restart at the same scope — see `## Incremental Output > Recovering a stuck role: never trade scope for a delivery`.

See also [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md) — long-running tasks must persist state to files, not context.

## Watchdog Enforcement

The two rules above — "restart silent roles" and "keep the status file current" — are also enforced mechanically by the plugin's hooks (`hooks/hooks.json`) and background monitor (`monitors/monitors.json`). Prompt discipline remains the primary behavior; the watchdog is the deterministic backstop for when it slips. The layers:

- **L0 heartbeats (automatic, invisible).** Every tool call — in the main agent and inside every subagent — stamps `<task-dir>/runtime/agents/<agent>.heartbeat`. SubagentStart stamps `.start`; a clean SubagentStop stamps `.done`. Liveness is therefore a side effect of working, never a thing a model must remember to do. A `.start` with no `.done` and no fresh heartbeat is the definition of a dead-or-stuck role.
- **L1 freshness reminders.** When the overall status file goes stale during an active phase (implementation/testing/review/delivery), a PostToolUse hook injects a reminder into the current context (main agent: "persist progress now"; implementation/test subagents: "report progress / update your SubTask-status file"). Rate-limited; advisory only.
- **L2 subagent exit gate.** A SubagentStop hook blocks a role from finishing with an empty or too-short final message and instructs it to emit a proper final report first (so the main agent always has something to persist). One block maximum per stop; never loops.
- **L3 background watchdog.** Claude Code uses the plugin monitor and can deliver its stdout as wake-up notifications. Codex currently has no async-hook/monitor notification channel; its synchronous `SessionStart` hook detaches the same scanner to a per-thread temp log for diagnostics, while L0/L1 and the synchronous Stop gate provide deterministic in-session enforcement. The workflow remains correct if this layer is degraded.
- **L4 main-agent stop gate.** A Stop hook prevents the main agent from going idle while a dispatched role looks dead (`.start`, no `.done`, stale heartbeat, and not present as a running background task) or while the status file is badly stale in an active phase. The block reason names the exact roles to check.
- **L5 dispatch scope guard.** A PreToolUse hook on the Agent tool inspects what a dispatch *asks for* — the only layer acting before the fact. A prompt that caps a role's deliverable ("only the top 3 findings", "just the overall verdict", "只要总结论", "一句话结论") is denied unless the same prompt commits to delivering the remainder ("then continue with the rest", "step 1 of 4", "分维度"). This closes the recovery-path failure where a stalled role's scope gets shrunk so it can finish — see `## Incremental Output > Recovering a stuck role`. Matching is heuristic; `ZYZ_SCOPE_GUARD_DISABLE=1` turns just this guard off.
- **L6 shared-worktree checkout guard.** A PreToolUse hook on Bash denies `git checkout <file>` / `git restore <file>` when the target has uncommitted modifications, and the state-moving `git stash` forms. These reset shared working-tree state to HEAD and destroy OTHER agents' uncommitted work unrecoverably (no reflog / stash / fsck holds never-committed content) — a real incident lost a ~5000-char security guard this way with `go build` staying green. The deny message carries the safe recipe (pre-edit `cp` backup + `mv` restore; `git show HEAD:<file>` for read-only; `git diff` + `git apply -R` for set-asides). Matching is heuristic; `ZYZ_CHECKOUT_GUARD_DISABLE=1` turns just this guard off. If work is lost anyway, see `## Resuming An Existing Task > Recovering destroyed uncommitted work from transcripts`.

Main-agent obligations toward the watchdog:

- Write the `.zyz-worker/current-task` pointer at §1 Start Task (and update it if the active task changes). No pointer → no watchdog.
- Name the overall status file `status.md` inside the task directory. The watchdog resolves it as `<task-dir>/status.md` and reads its `Current Phase` label; any other filename makes the freshness layers (L1/L3/L4) no-op silently.
- Treat any `[zyz-worker watchdog]` notification or injected context as an actionable instruction, not noise: re-dispatch the named role with the latest design and status summary, or flush the status file, immediately — do not defer to the next delivery milestone.
- Keep the status file's `Current Phase` field accurate; the watchdog only enforces during active execution phases and deliberately stays quiet during design and awaiting-confirmation (where waiting on the user is correct).
- The runtime markers under `<task-dir>/runtime/` are watchdog bookkeeping, not task state. Do not hand-edit them; they may be deleted with the task directory after delivery.

Degraded environments: hooks and monitors may be unavailable (plugin hooks disabled by policy, monitors unsupported on this platform or version). Everything still works — the prompt-level monitoring duties in `## Long-Running Work` and the flush rules in `## Core Rules` remain in force and become the only enforcement. The watchdog never replaces those duties; it only backstops them. All thresholds are tunable via `ZYZ_*` env vars (see `hooks/README.md`); `ZYZ_HOOKS_DISABLE=1` turns the whole layer off.

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

- `phase` — one of `design | implementation | testing | review | delivery | awaiting-confirmation | done | error`
- `phase-since` — ISO timestamp of when the current `phase` was entered
- `wait-state` — one of `none | waiting-user | waiting-subagent | waiting-resource`
- `waiting-reason` — free text, non-empty only when `wait-state != none`
- `expected-resume-by` — ISO timestamp, non-empty only when `wait-state != none`
- `last-flush` — ISO timestamp of this write

Hard rules in orchestrated mode:

- **Flush before any suspend.** Before suspending, before dispatching a subagent, after receiving a subagent result, and on entering any new workflow phase, write `ZYZ_WORKER_STATUS_FILE` atomically (tmpfile + rename). Never edit the file in place.
- **`worker-status.md` must be a valid YAML frontmatter document.** Write all required snapshot fields enclosed in a single pair of `---` fences, with the very first line of the file being `---`, the fields next, and a closing `---` line. A bare field dump without fences (e.g. a file that starts directly with `phase: review`) is malformed: the orchestrator's frontmatter parser reads nothing and cannot see this worker's progress. The shipped `skills/orchestration-scheduling-task/templates/worker-status.md` template already has the correct shape — match it.
- **`phase` may roll back, except `done` which is absorbing.** `phase` MAY move both forward and backward among `design`, `implementation`, `testing`, `review`, `delivery`, and `awaiting-confirmation` to reflect real iteration — e.g. a review of an `awaiting-confirmation` worker that asks for changes rolls the phase back to `implementation`. The ONLY non-reversible phase is `done`: once written it is the **absorbing** terminal and is never changed to an earlier phase. `done` means the **user has confirmed delivery**; the worker writes `done` ONLY after explicit user confirmation (in the worker window in standalone mode, or relayed from L1 in orchestrated mode) — NEVER autonomously, and never self-advanced from `awaiting-confirmation` without user confirmation. `awaiting-confirmation` means the worker self-declares finished and is waiting for that confirmation, and remains reversible. `error` remains reversible — after the error is fixed, resume to a working phase.
- **`wait-state` is orthogonal to `phase`.** Set `wait-state` independently from `phase`. Set `wait-state=waiting-user`/`waiting-subagent`/`waiting-resource` with a non-empty `waiting-reason` before suspending; set `wait-state=none` immediately on resume.
- **Confirmation advances the worker to `done`.** After producing the final report the worker enters `phase=awaiting-confirmation` (self-declared finished) and WAITS. It advances to `phase=done` ONLY when the user confirms — either directly in the worker window/conversation, or via an L1-relayed confirmation message that arrives in the pane (the orchestrator dispatches an `orch-driver-agent` with `intent=relay-confirmation` when the user wrote the `confirmed` token). The worker never self-advances to `done`. On user confirmation the worker flushes `phase=done` (atomically, valid frontmatter); the orchestrator mirrors that into `state: completed` on the next poll.
- **Design→implementation is a hard user-approval gate.** Before entering implementation the worker MUST flush `wait-state=waiting-user` (holding `phase=design`) and MUST NOT write `phase=implementation` or dispatch implementation-agent until explicit user approval arrives. Legal approval channels are ONLY: the user attached to the worker pane, or a matching `answer.md` (the worker first emits a question-id'd approval request to `ZYZ_QUESTION_FILE`; only an `answer.md` answering that id counts — a stale or unrelated answer does not). The orchestrator never relays design approval. The worker records the approval event (or the verbatim explicit prior skip instruction) into the on-disk `.zyz-worker/tasks/<task-id>/status.md` `## Design Review > Design Approval Record` BEFORE writing `phase=implementation`; a resuming or rehydrated worker enters implementation ONLY if that on-disk record is present — never on `phase` alone.
- **Async user Q&A goes through files.** Use `ZYZ_QUESTION_FILE` and `ZYZ_ANSWER_FILE` when the user is not attached to the tmux pane. After consuming an `answer.md`, rename it to `answer.md.consumed.<question-id>`.
- **Two status files, not one.** Orchestrated mode keeps the existing `.zyz-worker/tasks/<task-id>/status.md` as the worker's detailed task status (used by execute-task workflow), and adds `worker-status.md` at the path in `ZYZ_WORKER_STATUS_FILE` as the orchestrator-facing snapshot. The two files do not replace each other.
- **In-band runtime-config block OVERRIDES launch-time env (container-reuse contract).** When a worker is dispatched onto a REUSED container (the orchestration `reuse-dispatch` path), it may receive an in-band runtime-config block in its conversation — a structured, human-readable message fenced by `[zyz-worker reuse-runtime-config]` … `[/zyz-worker reuse-runtime-config]` carrying `task-id`, `worker-status-file`, `question-file`, `answer-file`, `heartbeat-file`, and — for a multi-repo reused container only — an OPTIONAL `worktrees:` line. This happens because a reused, still-running claude process cannot see freshly re-exported env (a Bash subprocess inherits the env claude started with, not later `export`s in the pane). The contract:
  - **Once this block is received, its values are authoritative for the whole task lifecycle and override the launch-time env.** Use the block's `task-id` as this task's orchestrated-mode task identity **in place of the inherited `ZYZ_TASK_ID`**, and the block's `worker-status-file` / `question-file` / `answer-file` / `heartbeat-file` in place of `ZYZ_WORKER_STATUS_FILE` / `ZYZ_QUESTION_FILE` / `ZYZ_ANSWER_FILE` / `ZYZ_HEARTBEAT_FILE`.
  - **The override applies to ALL task-id-derived paths**, not just the snapshot/Q&A/heartbeat files: the detailed task status directory `.zyz-worker/tasks/<task-id>/` (the "Two status files" one above), and any commit message / branch reference that embeds the task-id, all use the block's `task-id`. A worker that ignores this would write its detailed status into the OLD task's directory and use the wrong task-id — that is the failure this contract prevents.
  - **A `worktrees:` line in the block is the authoritative worktree set (overrides `ZYZ_WORKTREES`).** When the block carries `worktrees: <wt1>:<wt2>:…` (colon-separated, primary worktree first), treat that as this task's authoritative set of worktrees, overriding any launch-time `ZYZ_WORKTREES` — the worker manages all listed worktrees (see the multi-worktree rules below). When the block OMITS the `worktrees:` line, fall back to the launch-time env: `ZYZ_WORKTREES` if it is set, otherwise the single cwd (current single-worktree behavior). Worktree paths never contain a colon, so the colon is an unambiguous separator.
  - **A reuse worker also `touch`es the block's `heartbeat-file` on every flush** (every `worker-status.md` write), as a second liveness signal alongside the orchestrator's same-session new-window heartbeat daemon. (The primary heartbeat is the daemon; this touch is the backup.)
  - If no such block is received, behave exactly as before — the launch-time `ZYZ_*` env is authoritative (standard spawn).

- **Multi-worktree awareness and per-repo delivery (multi-repo tasks).** A single worker (one tmux session + one claude process) may manage n git worktrees, one per repo:
  - **Worktree-set discovery.** If `ZYZ_WORKTREES` (colon-separated, primary worktree first) is set — or the reuse-runtime-config block carries a `worktrees:` line (which overrides `ZYZ_WORKTREES`, per the block contract above) — the worker manages ALL listed worktrees. If neither is present, the worker manages the single cwd worktree (unchanged single-repo behavior). The first entry is the primary worktree (the pane cwd).
  - **Write-permission boundary.** The worker has FULL write access to every one of its own worktrees. It MUST NOT write into any other worker's worktree. Isolation is between workers, not between a worker and its own repos: within one worker, all its worktrees are writable; across workers, worktree sets are disjoint (spawn enforces this).
  - **Per-repo commits, push, and delivery.** Each repo lives on its own branch in its own worktree; commit and push per-repo (a SubTask commits in each repo it touched; the final delivery commit is created per-repo). Merge to base is per-repo too (each repo's branch into that repo's base — orchestrator-driven in orchestrated mode). Delivery reporting is split by repo: the final report `## Changes` section lists per-repo (repo / branch / commits / push result), and the task-status `## SubTasks > Committed` field records `<repo>:<sha>` on multiple lines for a multi-repo SubTask.

Phase mapping (when each phase value must be written to `worker-status.md`):

| execute-task workflow position | phase to write | flush moment |
|---|---|---|
| §1 Start Task | `design` | when initializing the task status file |
| §2 Design (all of it, including review loops) | `design` | once on entry; on each return to main agent |
| §3.A step 1 / §3.B step 1 — implementation-agent dispatched | `implementation` (on user approval only — never autonomous; see the design→implementation hard-gate rule) | before dispatching the subagent |
| §3.A step 2 / §3.B step 2 — test-agent / running tests | `testing` | before dispatching / before running |
| §3.A step 4 / §3.B step 3.5+4 — workspace frozen, then review-agent dispatched | `review` | before dispatching |
| §3.A step 5 / §3.B step 5 — review → implementation revisions loop | `review` (held by default; MAY roll back to `implementation` if it genuinely returns to substantial implementation work — rollback is allowed) | no flush |
| §3.C aggregate testing | `testing` | on entry |
| §3.C aggregate review | `review` | on entry |
| §4 Deliver | `delivery` | on entry |
| final report shipped (worker's furthest self-reachable state) | `awaiting-confirmation` | last write |
| user confirms delivery (worker window, or relayed from L1) | `done` | on user confirmation only — never autonomous |
| unrecoverable error | `error` (set `wait-state=none`) | immediately |

The worker writes `phase=done` ONLY after explicit user confirmation (never autonomously); `done` is the sole non-reversible absorbing terminal. In orchestrated mode the orchestrator mirrors a worker's `phase=done` into master-entry `state: completed`; in standalone mode `phase=done` is itself the terminal. Merge to base remains a separate, independently-tokened action that may or may not happen (decoupled from done) — see `skills/orchestration-scheduling-task/SKILL.md` `## State Machine`.

If `ZYZ_WORKER_STATUS_FILE` is unset, ignore this entire section — the skill runs in standalone mode and behaves exactly as the rest of the document describes.

### Maintenance note

This section is coupled to the `orchestration-scheduling-task` skill's contract. If the execute-task workflow gains a new phase, extend the `phase` enum here and in `skills/orchestration-scheduling-task/templates/worker-status.md`, and extend the phase mapping table here in lockstep.
