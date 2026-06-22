---
name: orchestration-scheduling-task
description: Use when the user wants to drive a master task list — analyze dependencies, dispatch parallel tmux/git-worktree workers running execute-task, aggregate state, gate merges on user approval. Polls automatically by default (in-session self-scheduling); can also be wrapped with /loop, or set to a single-shot via opt-out.
---

# Orchestration Scheduling Task

Use this skill to drive a master list of development tasks. The orchestrator scans the list, analyzes dependencies, dispatches isolated workers (each in its own tmux session + git worktree, each running the `execute-task` skill), aggregates worker state through files, and gates merges on explicit user approval.

The orchestrator does **not** execute tasks itself. It schedules, dispatches, polls, and reports. Each task is executed by a worker — a separate `claude` process inside a dedicated tmux session that runs `/execute-task`.

This skill builds on top of the zyz-worker convention that long-running task state lives in files, not in conversation context. See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md). All cross-process communication between orchestrator and worker happens through files in the master list directory; nothing is exchanged in memory.

## When to use this skill

Load this skill when the user wants any of the following:

- Drive a multi-task development backlog with parallel execution.
- Watch a directory of task definitions and react to user edits as the source of truth.
- Dispatch `execute-task` workers into isolated tmux sessions and git worktrees.
- Aggregate worker progress (phase, wait-state, heartbeat) into a single summary.
- Gate merges and worktree cleanup on explicit user approval.

If the user only wants to run a single confirmed task, use the `execute-task` skill directly. If the user wants to schedule many tasks against a single master list, this skill is the entry point.

## Architecture (3-layer)

Orchestration is a **3-layer call hierarchy**. The split exists because interactively driving a worker's tmux pane (start `claude`, clear the startup confirmation pages, rescue a stuck worker) is token-heavy and noisy; pushing N parallel workers' pane driving into one context would pollute it and depress real parallelism. So that heavy work is isolated per worker, while cheap read-only polling stays inline.

- **L1 — orchestration main agent** (user-facing; single; holds the `<list-dir>` flock). Orchestrates everything: scan, analyze dependencies, plan dispatch, gate merges, notify. Keeps a cheap **inline read-only poll** (`orch-check-worker.sh` — files + `pgrep`, never `capture-pane` / `send-keys`) for each worker's overall-state projection. **Never touches a pane.** Only the one heavy job — interactively driving a pane — is delegated, on demand, to L2.
- **L2 — per-worker `orch-driver-agent` subagent** (short-lived; dispatched on demand, NOT every tick). Does the heavy pane work for exactly one worker: start `claude` in bypass mode, clear the trust-folder and bypass-risk confirmation pages, run `/execute-task`, or intervene when that one worker is stuck. It is the **only** layer that touches a pane interactively (`send-keys` / `capture-pane`). It observes overall state only (`worker-status.md` / `dispatch.md` upward projections), **never reads task internals**, writes **only** `monitor.md`, and returns one line to L1 before exiting.
- **L3 — the tmux window + independent `claude` process running `/execute-task`** (the execution layer). It has its own main agent plus `implementation` / `test` / `review` subagents and runs design → implementation → testing → review → delivery inside its own git worktree. It is **invisible to L1/L2** and driven (not nested) by L2 through `tmux send-keys`.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ L1  orchestration main agent  (user-facing · single · holds list-dir flock) │
│                                                                              │
│  does:      scan → analyze(deps) → plan(dispatch) →                          │
│             poll(inline orch-check-worker.sh, read-only · no pane) →         │
│             dispatch L2 on first-launch / stuck → project → gate →           │
│             notify → report                                                  │
│  can see:   master entries, worker-status.md(projection), dispatch.md,       │
│             heartbeat, monitor.md, the one-line summary L2 returns           │
│  touch pane? NO — L1 calls read-only scripts, never send-keys / capture-pane │
│  cannot touch: L3 internals (design / subtask / impl / test / review /       │
│                question.md body)                                             │
│  with user: orchestration-level interaction + notify "task X needs you in    │
│             window Y" (never relays the Q&A content)                         │
└───────────────┬──────────────────────────────────────────────────────────────┘
                │ on demand (NOT every tick): first launch OR stuck intervention,
                │ dispatch a short-lived driver subagent
                │ pass: task-id + list-dir + pane info (self-contained prompt); get back: one line
                │ multiple workers' L2 dispatched in one batch (single message, multiple Agent calls)
        ┌───────┴───────┬───────────────┬───────────────┐
        ▼               ▼               ▼               ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐  ...(one per worker, on demand)
│ L2  driver    │ │ L2  driver    │ │ L2  driver    │
│ subagent      │ │ subagent      │ │ subagent      │
│ (worker A)    │ │ (worker B)    │ │ (worker C)    │
│ short-lived · │ │               │ │               │
│ on-demand     │ │               │ │               │
│ (heavy work   │ │               │ │               │
│  only):       │ │               │ │               │
│ · first-disp: │ │               │ │               │
│   idempotent  │ │               │ │               │
│   pre-launch  │ │               │ │               │
│   check →     │ │               │ │               │
│   send-keys   │ │               │ │               │
│   start claude│ │               │ │               │
│   (bypass; in │ │               │ │               │
│   recorded    │ │               │ │               │
│   pane, no    │ │               │ │               │
│   reparent) + │ │               │ │               │
│   clear conf. │ │               │ │               │
│   pages +     │ │               │ │               │
│   /execute-   │ │               │ │               │
│   task        │ │               │ │               │
│ · intervene:  │ │               │ │               │
│   conservative│ │               │ │               │
│   send-keys   │ │               │ │               │
│   rescue      │ │               │ │               │
│ · relay-conf: │ │               │ │               │
│   send-keys a │ │               │ │               │
│   user        │ │               │ │               │
│   confirmation│ │               │ │               │
│   into pane   │ │               │ │               │
│ · set needs-  │ │               │ │               │
│   user (only  │ │               │ │               │
│   waiting-    │ │               │ │               │
│   user)       │ │               │ │               │
│ · write       │ │               │ │               │
│   monitor.md  │ │               │ │               │
│ · return one  │ │               │ │               │
│   line        │ │               │ │               │
│ can see:      │ │               │ │               │
│ worker-status/│ │               │ │               │
│ dispatch      │ │               │ │               │
│ (projection), │ │               │ │               │
│ a pane glance │ │               │ │               │
│ does NOT write│ │               │ │               │
│ worker-status,│ │               │ │               │
│ does NOT read │ │               │ │               │
│ L3 internals  │ │               │ │               │
└───────┬───────┘ └───────┬───────┘ └───────┬───────┘
        │ tmux send-keys / capture-pane (out-of-process driving, NOT agent nesting)
        ▼               ▼               ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────┐
│ L3  tmux win  │ │ L3  tmux win  │ │ L3  tmux win  │
│ zyz-task-A    │ │ zyz-task-B    │ │ zyz-task-C    │
│               │ │               │ │               │
│ independent   │ │ independent   │ │ independent   │
│ claude proc   │ │ claude proc   │ │ claude proc   │
│ (bypass)      │ │               │ │               │
│ runs          │ │               │ │               │
│ /execute-task │ │               │ │               │
│               │ │               │ │               │
│ execute-task  │ │               │ │               │
│ has its own:  │ │               │ │               │
│  · main agent │ │               │ │               │
│  · impl-agent │ │               │ │               │
│  · test-agent │ │               │ │               │
│  · review-agt │ │               │ │               │
│               │ │               │ │               │
│ works in its  │ │               │ │               │
│ own git       │ │               │ │               │
│ worktree ·    │ │               │ │               │
│ invisible to  │ │               │ │               │
│ upper layers  │ │               │ │               │
└───────┬───────┘ └───────────────┘ └───────────────┘
        │ when execute-task needs a user decision
        ▼
┌───────────────────────────────────────────────────────────┐
│ user  ── attach to tmux window ──> talks to L3's claude    │
│         directly                                           │
│                                                            │
│  L1 only notifies "window Y needs you"; it never relays    │
│  the Q&A content. After attaching, the user interacts with │
│  L3 directly; the Q&A never passes through L1/L2.          │
└───────────────────────────────────────────────────────────┘

Communication media (all via files + return value; no cross-agent memory sharing;
the user attaches to a pane directly):
  L1 ←→ files(<list-dir>/...) ←→ L2   [L2 writes state files, L1 reads]
  L1 ←  return value(one line) ←  L2   [L2 returns on exit]
  L2 ←→ tmux(send-keys/capture) ←→ L3  [out-of-process driving]
  L3 ←→ files(in worktree + worker-status.md)  [L3's own execution state]
  user ←→ tmux attach ←→ L3            [Q&A, never through L1/L2]
```

### Responsibility boundary table

| Layer | Can see | Cannot touch | Can write | With user |
|---|---|---|---|---|
| **L1 main agent** | master entries, `worker-status.md` (projection), `dispatch.md`, `heartbeat`, `monitor.md`, L2's one-line summary | L3 internals (design / subtask / impl / test / review), L3↔user Q&A body, a worker's raw pane content | master entries, `SUMMARY.md`, notifications | orchestration-level interaction + notify "window Y needs you" (never relays content) |
| **L2 driver subagent** | the one worker it drives: its `worker-status.md`, `dispatch.md` (upward projection), and a `capture-pane` glance when needed | that worker's L3 internals (design / subtask / impl / test / review / `question.md` body), other workers, master-entry decisions | that worker's `monitor.md` (and `send-keys` into the recorded pane to intervene) | not user-facing; only records a "needs-user" marker into `monitor.md` |
| **L3 execute-task** | everything in its own worktree, its own `worker-status.md` | other workers, the master list, the existence of L1/L2 | `worker-status.md`, `question.md`, code/docs in the worktree | direct Q&A with the user when attached |
| **user** | everything (may attach to any window) | — | master entries, answers (typed directly into the pane) | orchestration-level + attach into a window for direct Q&A with L3 |

### Key invariants

- **Only L2 touches a pane interactively** (`send-keys` / `capture-pane`). L1 may call the read-only `orch-check-worker.sh` for a projection but never touches a pane; L3 is driven, not a peer.
- **`worker-status.md` and `dispatch.md` are L3's upward projection** of overall state, not "internals" — L1 and L2 may both read them (they are the authoritative overall-state source).
- **"Internal" means** L3's design doc, subtask status, implementation / test / review files, and the **body** of `question.md`. L1 and L2 never read these.
- **L1/L2 never relay Q&A.** The execute-task phase confirmations and blocking decisions stay between L3 and the user. L1 only notifies "task X needs you in window Y"; the user attaches and answers L3 directly. The Q&A never passes through L1/L2.
- **notify keys off the live poll wait-state, never off `monitor.md`.** L1 never writes `monitor.md`; a stale `needs-user=true` left there by an earlier L2 is harmless scratch state (re-derived from a fresh poll the next time an L2 is actually dispatched).

## Main Agent Loading

When this skill is used, the current user-facing conversation agent is the orchestrator (main agent). First load and follow the full controller prompt from:

```text
prompts/main-agent.md
```

That file is not a subagent. It defines how the current conversation agent coordinates the orchestration loop and talks with the user.

## Prompt Files

Load these files when needed:

- Main agent controller prompt: `prompts/main-agent.md` (load first when the skill starts).

The orchestration-scheduling-task skill has no main-agent subagent, but it does own one project-level subagent: the **L2 driver**, `agents/orch-driver-agent.md` (mirrored in `subagents/orch-driver-agent.md`, the same dual layout as the execute-task subagents). L1 dispatches it on demand to drive one worker's pane (see Architecture above). The orchestrator also dispatches `execute-task` workers, which in turn use the project subagents `implementation-agent`, `test-agent`, `review-agent`.

Use these templates when creating master-list artifacts:

- Master list task entry: `templates/master-list-task-entry.md`
- Worker status: `templates/worker-status.md`
- Driver state (L2-owned): `templates/monitor.md`
- Async question/answer: `templates/question-answer.md`

## Core Rules

- **Long-running state lives in files.** The master list directory `<list-dir>` is the single source of truth. Conversation context never replaces a file. Every orchestrator decision must be derivable from disk content; if a fact is not on disk, it does not exist. See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md).
- **The orchestrator is cwd-independent; each task carries its own `source-repo`.** The orchestrator may be started from `~/` or any directory (not necessarily a git repo). Each master entry's `source-repo:` frontmatter field is mandatory and points at the absolute path of that task's project git work tree; all git operations for the task are scoped to `git -C "$SOURCE_REPO"`. One master list can therefore dispatch workers across multiple repos.
- **Only one orchestrator at a time per master list.** The orchestrator acquires `<list-dir>/.orchestrator.lock` via `flock` at startup. Starting a second orchestrator against the same list fails. The lock guards orchestrator-vs-orchestrator concurrency; user edits to master entries are guarded procedurally (user must `Ctrl-C` the orchestrator first — see below).
- **Master entries are co-written with the user.** The orchestrator writes via `tmpfile + rename`. **Before the user edits a master entry in an external editor, the user must `Ctrl-C` the orchestrator** so the flock releases. Restart the orchestrator once the edit is saved.
- **Each worker writes only its own runtime files.** A worker writes `worker-status.md`, `question.md`, and uses `heartbeat` via the daemon. The orchestrator reads but never writes a worker's runtime files (except for archival during cleanup). The orchestrator writes the master entry; the worker never writes the master entry.
- **Heuristic analysis is always tentative.** Dependency, project, merge-with suggestions written by the orchestrator carry `deps-tentative: true` in the master entry frontmatter until the user flips it to `false`.
- **No automatic state change, merge, or cleanup.** Any delivery action requires the matching explicit user token in `## Pending Merge Approval`; the orchestrator never initiates them autonomously. Tokens: `confirmed` (relay the user's confirmation to the worker so it writes `phase=done`, which the orchestrator then mirrors to `state: completed`; no direct state write, no merge/cleanup), `merge` / `merge: <base>` (merge to base + push, no state change), legacy `approved` (merge + completed + cleanup, atomic — short-circuits any coexisting tokens this tick), `cleanup-approved` (worktree cleanup), `rejected: <reason>` (send back to blocked). Stale-worker cleanup still requires `cleanup-approved`.
- **`task-id` is whitelisted.** Helper scripts reject any `task-id` that does not match `^[a-zA-Z0-9_-]+$`. The `tmux` session, git branch, worktree path, and runtime dir all embed the literal `task-id`.
- **Worker tmux session name is fixed-prefix `zyz-task-<task-id>`.** Default git branch is `task/<task-id>`. Default merge base is `main`; override via master entry frontmatter `base:` field.
- **Heartbeat thresholds default to 300 s** (fresh / suspect / stale tiers per §A.6 of the design spec). When the worker reports `wait-state=waiting-user`, the threshold widens to 900 s. Do not drop below 120 s except on a strictly local (non-network) filesystem.
- **Orchestrated Mode handshake with `execute-task`.** The orchestrator exports `ZYZ_WORKER_STATUS_FILE`, `ZYZ_TASK_ID`, `ZYZ_QUESTION_FILE`, `ZYZ_ANSWER_FILE`, `ZYZ_HEARTBEAT_FILE` into the worker's tmux session. The worker's `execute-task` skill detects `ZYZ_WORKER_STATUS_FILE` and writes phase/wait-state to it. The orchestrator only sees what the worker flushes; in-context memory does not count.

## Workflow

The orchestrator runs a loop. Each tick (manual invocation, auto-timer self-schedule, or `/loop` wakeup) performs:

1. **scan** — `scripts/orch-scan-tasks.sh <list-dir>` lists every task entry, its declared `state`, and (for in-progress/paused tasks) the worker-reported phase + wait-state. Missing or illegal `state` values are treated as `not-analyzed`.
2. **analyze** — For `not-analyzed` tasks, run dependency / project / merge-with analysis. Write tentative results into the master entry `## Orchestrator Analysis` section. **If `## Description` is empty, leave `state: not-analyzed` and write `needs Description` into the analysis section; do not dispatch.**
3. **plan** — Decide which `ready` tasks to dispatch this tick. The parallel cap is `ZYZ_MAX_PARALLEL_WORKERS` (**default `-1` = unlimited**; set a positive integer to cap — at `-1` no cap is applied and every `ready` task is dispatchable). Move `blocked` tasks whose dependencies are now met to `ready`. **Resource caveat:** each worker = 1 tmux session + 1 git worktree + 1 full `claude` process (running the entire `execute-task` workflow including its own subagents) — far heavier than execute-task's prompt-only subagents. With no cap, watch API quota / memory / disk; set a positive cap to limit.
4. **dispatch** — For each task selected to dispatch, the orchestrator works in two stages. First call `scripts/orch-spawn-worker.sh <task-id> <list-dir>` to build the **container only**: the worktree, tmux session, in-pane heartbeat daemon, and `dispatch.md` Phase-1 fields. Spawn **never** starts `claude` (there is no `--auto-start`). Then **dispatch an L2 `orch-driver-agent` subagent with `intent=first-dispatch`** to do the heavy pane work — start `claude` in bypass mode, clear the confirmation pages, readiness-probe, and run `/execute-task`. When several new workers are dispatched at once, their L2 drivers are launched in one batch (single message, multiple `Agent` calls).
5. **poll** — For each `in-progress` or `paused` task, the orchestrator **inline** calls `scripts/orch-check-worker.sh <task-id> <list-dir>` (read-only: files + `pgrep`, never touches a pane) and projects worker state into the master entry. This inline poll runs for **every** active worker every tick (including throttled ones) and is the sole detection point for "user answered, worker left `waiting-user`". L1 dispatches an L2 driver with `intent=intervene` **only** for a worker the poll shows stuck/abnormal (session dead but should be alive, heartbeat stale while `phase-since` is unchanged for several ticks, Unknown-command signs); healthy workers get **no** L2. On `heartbeat-status=fresh`, update `last-seen`. On stale, write the stale summary into `## Notes` and shorten the cadence; do not silently change the master entry `state`.
6. **handle errors** — If a worker reports `phase=error`, set the master entry `state: blocked`, copy the worker's `## Last Output Summary` into the master entry `## Notes`, and shorten cadence.
7. **gate** — For tasks whose `## Pending Merge Approval` section contains `approved`, call `scripts/orch-merge-and-cleanup.sh <task-id> <list-dir> <base-branch>`.
8. **report** — Write a short summary to the conversation window and (re)write `<list-dir>/SUMMARY.md` listing all tasks and their current view.

For full workflow detail, decision branches, failure modes, and cadence policy, load `prompts/main-agent.md`.

## File Protocols

The orchestrator and workers communicate through a small set of files in `<list-dir>`. Path summary:

| File | Path | Writer | Reader |
|---|---|---|---|
| master entry | `<list-dir>/tasks/<task-id>.md` | orchestrator + user | orchestrator + user |
| worker status | `<list-dir>/runtime/<task-id>/worker-status.md` | worker (execute-task) | orchestrator |
| monitor | `<list-dir>/runtime/<task-id>/monitor.md` | L2 orch-driver-agent | orchestrator (L1) |
| dispatch | `<list-dir>/runtime/<task-id>/dispatch.md` | spawn (Phase-1) + check (Phase-2) | orchestrator + operator |
| heartbeat | `<list-dir>/runtime/<task-id>/heartbeat` | in-pane heartbeat daemon | orchestrator |
| question | `<list-dir>/runtime/<task-id>/question.md` | worker | user |
| answer | `<list-dir>/runtime/<task-id>/answer.md` | user | worker |
| lock | `<list-dir>/.orchestrator.lock` | orchestrator (flock) | orchestrator |
| SUMMARY | `<list-dir>/SUMMARY.md` | orchestrator | user |

The lock guards only orchestrator-vs-orchestrator concurrency. User-vs-orchestrator concurrency is handled procedurally: the user must `Ctrl-C` the orchestrator before editing a master entry.

### Master entry frontmatter (excerpt)

```yaml
task-id: <task-id>            # immutable
project: <project name>       # user maintained; label only; default = basename source-repo when omitted
source-repo: ~/workspace/<repo>  # required; absolute path or ~/-prefixed; supports ~/ expansion
state: not-analyzed           # not-analyzed | blocked | ready | in-progress | paused | awaiting-user-confirmation | completed
priority: normal              # low | normal | high
branch: task/<task-id>        # default; user can override
base: main                    # merge base; user can override
worktree: ~/.zyz-worker/worktrees/<project>/task/<task-id>
tmux-session: zyz-task-<task-id>
blocked-by: []                # user maintained
merged-with: []               # user maintained
deps-tentative: true          # orchestrator clears to false only when user approves analysis
last-seen: <iso>              # orchestrator-only
heartbeat-stale-sec: 300      # optional override
created-at: <date>
updated-at: <date>
```

Legal user-written values for `state:` are `not-analyzed | blocked | ready | completed`. The orchestrator writes `in-progress | paused | awaiting-user-confirmation` on its own (`awaiting-user-confirmation` is orchestrator-projected from the worker's phase, never user-written).

### Worker status frontmatter (excerpt)

```yaml
task-id: <task-id>
phase: design | implementation | testing | review | delivery | awaiting-confirmation | done | error
phase-since: <iso>
wait-state: none | waiting-user | waiting-subagent | waiting-resource
waiting-reason: <free text; non-empty when wait-state != none>
expected-resume-by: <iso; non-empty when wait-state != none>
last-flush: <iso>
```

The worker flushes status before any suspend, before dispatching a subagent, and on every phase transition. The orchestrator reads but never writes `worker-status.md`.

## State Machine

Seven explicit states + one orchestrator-derived state (`stale`):

| State | Meaning | Set by |
|---|---|---|
| `not-analyzed` | Task is new; orchestrator has not analyzed it yet. | template default / scan |
| `blocked` | Dependencies unmet, or worker reported `phase=error`. | orchestrator |
| `ready` | No blockers; dispatchable. | orchestrator |
| `in-progress` | Worker dispatched; tmux session alive; heartbeat fresh; worker in a working phase (`design`..`delivery`) with `wait-state=none`. | orchestrator |
| `paused` | Worker dispatched; `wait-state != none`. | orchestrator (projects worker's wait-state) |
| `awaiting-user-confirmation` | Worker reached `phase=awaiting-confirmation` (self-declared finished, awaiting the user's confirmation). Distinct from `paused` (which is mid-task waiting on a Q&A/resource). | orchestrator (projects worker phase) |
| `completed` | Delivery confirmed: the worker reached `phase=done` (user confirmed — worker-window direct, or via an L1-relayed confirmation) and the orchestrator mirrored it; OR the legacy `approved` token ran the atomic merge+complete+cleanup. Merge to base may or may not have happened (done is decoupled from merge). Terminal and immutable; post-delivery changes go through a NEW superseding task. | orchestrator |
| `stale` (derived) | Heartbeat past stale threshold OR `phase-since` unchanged for 5 ticks. Master entry `state:` is **not** rewritten; stale is reported via the `## Notes` section and the `last-seen` field. | orchestrator |

Transitions (informal):

- `not-analyzed` → `ready` (analysis ok, no blockers) | `blocked` (analysis ok but deps unmet)
- `blocked` → `ready` (deps met or error resolved)
- `ready` → `in-progress` (orchestrator dispatches)
- `in-progress` → `paused` (worker writes `wait-state != none`) | `awaiting-user-confirmation` (worker writes `phase=awaiting-confirmation`) | `blocked` (worker writes `phase=error`)
- `paused` → `in-progress` (worker writes `wait-state=none`)
- `awaiting-user-confirmation` → `in-progress` (worker rolls back, e.g. the user asked for changes) | `completed` (worker writes `phase=done` after the user confirms — directly in the worker window, or via the L1 `confirmed`→relay path — and the orchestrator mirrors `phase=done` into `completed`; OR the legacy `approved` atomic path)

A worker reaching `phase=awaiting-confirmation` projects to `state: awaiting-user-confirmation`. `completed` is reached only when the worker writes `phase=done` (after user confirmation) and the orchestrator mirrors it — or via the legacy `approved` atomic path; never directly from the `confirmed` token. `completed` is terminal and immutable; it is what the orchestrator reasons about when judging whether downstream tasks may start (see the Dependency Unlock guidance in `prompts/main-agent.md`). Post-delivery changes go through a NEW superseding task; never re-open or roll back `completed`.

Full state machine and the phase mapping table for `execute-task` workflow positions live in the design spec (§A and §D.5 of `.zyz-worker/tasks/orchestration-scheduling-task/design-spec.md`).

### PR flow (merge handled outside the orchestrator)

Not every branch merges to `main`, and some require PR + human review. Native PR creation is out of scope. To finish a task via PR: let the worker reach `phase=awaiting-confirmation`, open and review/merge the PR yourself (outside zyz-worker), then write `confirmed` (NOT `merge`) in `## Pending Merge Approval` so the orchestrator records `state: completed` without running any git merge. The orchestrator never opens or merges PRs.

## Long-Running State

This skill enforces the zyz-worker [long-running-state convention](../../docs/conventions/long-running-state.md) end-to-end:

- The master list directory **is** the state. The orchestrator must derive every decision from disk content.
- The worker writes `worker-status.md` before any suspend.
- The heartbeat daemon writes the `heartbeat` file every 30 s while alive (it dies with the tmux session — no manual `pkill` needed).
- The orchestrator writes `SUMMARY.md` once per tick.

If the orchestrator's conversation context is dropped or compacted, restarting `/orchestrate-tasks <list-dir>` rebuilds full situational awareness from disk alone.

## Crash Recovery

Every worker writes a `dispatch.md` into its runtime directory at `<list-dir>/runtime/<task-id>/dispatch.md`. The file binds the worker's tmux session/pane to its claude session-id and transcript path, so you can recover after a tmux session, claude process, or orchestrator crash. The spawn helper writes the Phase-1 (deterministic, spawn-time) fields as the last preflight step; `orch-check-worker.sh` lazily fills the Phase-2 (claude-side) fields — `claude-pid`, `claude-session-id`, `transcript-path`, `first-seen-iso` — on subsequent polls, and regenerates the `## Recovery` body with concrete commands once all three of the first trio are populated.

Run `bash scripts/orch-check-worker.sh <task-id> <list-dir>` and read its stdout: it now emits a `dispatch-bound=true|false|<empty>` line (`true` = Phase-2 trio populated; `false` = dispatch.md present but trio incomplete; empty = dispatch.md absent) and a `session-alive=true|false` line (whether the tmux session still exists). Together these two lines tell you which recovery case below applies. To pull a single field out of dispatch.md directly, use the same `awk` pattern the helpers use:

```text
awk -F': ' '/^<field>:/{sub(/^ +/,"",$2); print $2; exit}' <list-dir>/runtime/<task-id>/dispatch.md
```

This simplified form assumes the spawn/check-written format (no inline `#` comments, no `: ` inside values); for general frontmatter parsing the helpers' `fm_field` is more robust.

The four recovery cases:

1. **tmux session still alive** (`tmux has-session -t <tmux-session>` exits 0; equivalently `session-alive=true`):
   - Attach and resume work in the existing pane: `tmux attach -t <tmux-session>`.

2. **tmux session dead but `transcript-path` populated** (`session-alive=false`, `dispatch-bound=true`):
   - Read `dispatch.md ## Recovery` for the exact substituted commands.
   - Run `cd <worktree> && claude --resume <claude-session-id> --plugin-dir <plugin-root>`. Claude reads the JSONL at the recorded `transcript-path` and resumes the conversation. The `--plugin-dir` keeps `/execute-task` registered in the resumed session — **omitting it re-triggers the "Unknown command: /execute-task" failure**, because the resumed transcript restores the conversation but not the plugin registration.

3. **dispatch.md has Phase-1 fields but no Phase-2** (`dispatch-bound=false` — claude never bound; usually `/execute-task` was rejected at the slash-command layer, the spawn was killed before claude registered, or claude never made a first LLM round-trip):
   - There is no useful claude state to resume. Treat it as a fresh task: clean up the worktree with `scripts/orch-cleanup-worker.sh <task-id> <list-dir>` and re-dispatch from the master entry.

4. **dispatch.md missing entirely** (`dispatch-bound=` empty): two possible causes — (i) a pre-feature worker spawned before this change, or (ii) a spawn that crashed before reaching the dispatch.md write step. Use `session-alive` to disambiguate:
   - `session-alive=true` → attach and continue per case 1. The worker may still be usable.
   - `session-alive=false` → no recovery info was recorded; treat the runtime as unsalvageable. Clean up and re-dispatch from the master entry.

   (If you need a timestamp of the most recent worker activity, read `worker-status.md` `last-flush`. The orchestrator reads but never writes `worker-status.md`.)

### Crash semantics

Map the observable state of a runtime directory to an interpretation as follows:

| dispatch.md | Phase-2 state | session-alive | Interpretation |
|---|---|---|---|
| present | empty | alive | claude not yet started or not bound; the normal first-launch transient for an L2-driven worker before L2 has started `claude` (spawn never starts `claude` — there is no `--auto-start`) |
| present | empty | dead | worker died before binding (claude never got far) |
| present | partial | alive/dead | claude registered but no LLM round-trip yet (most likely `/execute-task` was rejected and the user never typed anything) |
| present | full | alive/dead | normal bound worker; recover via case 1 (alive) or case 2 (dead) |
| absent | n/a | alive | spawn crashed mid-preflight before the dispatch.md write (spawn writes only the INITIAL `worker-status.md` at its Step 6, so that file may still be present); attend manually |
| absent | n/a | dead | pre-feature worker, no recovery info; treat per case 4 |

**Scope note**: Auto-detecting these states and auto-setting the master entry to `state: error` is OUT OF SCOPE for this feature. This section is documentation-only guidance for a human operator — the orchestrator poll loop does NOT automatically detect or act on these crash states.

### How dispatch.md binding works (and why Phase-2 is lazy)

Phase-2 binding is lazy because of *when* Claude Code persists its session files. On the verified host (Claude Code v2.1.152, macOS), Claude writes BOTH of these only after the session's first successful LLM round-trip — never at startup:

- `~/.claude/sessions/<pid>.json` — the session pointer. Its filename `<pid>` equals the claude process PID, and it carries `{sessionId, cwd, ...}`. `orch-check-worker.sh` reads `sessionId` from it.
- `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` — the full transcript. `encoded-cwd` is the worktree's PHYSICAL path (`pwd -P`, so symlinks like macOS `/var → /private/var` resolve) with both `/` and `.` replaced by `-`, then consecutive `-` squeezed into one. `orch-check-worker.sh` does NOT reconstruct this directory name to locate the transcript: it discovers the JSONL by session-id (a globally-unique UUID) via `find ~/.claude/projects -name "<sessionId>.jsonl"`, so discovery is robust to claude's exact path-encoding rule. The recorded `encoded-cwd` field is kept honest for diagnostics and the recovery command path, but binding does not depend on it.

Consequences a recovery operator should understand:

- A worker's claude process can EXIST (so `claude-pid` binds via `pgrep -P <shell-pid> -n -x claude`) for seconds-to-minutes before its `session-id` and `transcript-path` are discoverable on disk. This is the `present | partial` row above and the normal `dispatch-bound=false` transient — not an error.
- `claude --resume <session-id>` only has a transcript to resume from once that first round-trip has happened. Before then there is genuinely nothing to recover (case 3).
- The claude process is a DIRECT child of the pane shell, which is why `pgrep -P <shell-pid>` finds it. If a future Claude Code version changes when these files are flushed or how the process is parented, re-verify before relying on the timing.

## Optional Skills And Plugins

Before scanning, analyzing, dispatching, or summarizing, check whether the current agent already has relevant skills, plugins, or tools available:

- Use git-related skills (e.g., the `git-worktree` skill in this plugin) to derive default worktree paths.
- The orchestrator already auto-polls by default: each tick self-schedules the next via `ScheduleWakeup` with dynamic intervals (see the cadence policy in `prompts/main-agent.md`). Wrapping with the `/loop` slash command (Claude Code) is an optional explicit alternative; either way the same cadence policy drives the interval.
- Use documentation, engineering workflow, or testing skills (`llmdoc`, `superpowers`, …) if available; record usage in the SUMMARY.

Do not block, fail, or ask the user to install anything when these optional capabilities are unavailable.

## Maintenance Notes

This skill is coupled to `execute-task`. If `execute-task` ever introduces a new phase, the orchestrated-mode contract here must be updated in lockstep:

- The `phase:` enum in the worker status template must be extended.
- The phase mapping table (design-spec §D.5) must be extended.
- This SKILL.md and `prompts/main-agent.md` should mention the new phase explicitly.

If the `dispatch.md` schema changes, update these in lockstep: the `templates/dispatch.md` template, the Phase-1 write in `scripts/orch-spawn-worker.sh`, the Phase-2 lazy fill in `scripts/orch-check-worker.sh`, the `## Crash Recovery` section above, and the T8 cases in `scripts/test-orchestration-helpers.sh` (which encode the field list and the recovery-command shape).

If the **3-layer architecture** changes (the L1/L2/L3 boundaries, the L2 driver's contract, or where pane driving lives), keep these in lockstep: the driver agent definition (`agents/orch-driver-agent.md` **and** its mirror `subagents/orch-driver-agent.md`), the `templates/monitor.md` driver-state template, the L1 loop in `prompts/main-agent.md`, the Architecture / File Protocols / crash-semantics sections in this SKILL.md, and the T-tests in `scripts/test-orchestration-helpers.sh`. In particular: spawn is container-only (it never starts `claude`; the L2 driver is the sole launcher), `monitor.md` is L2-owned / L1-read-only, and notify keys off the live poll wait-state. The L2 driver is dispatched from **three** L1 sites — **dispatch** (`intent=first-dispatch`), **poll** (`intent=intervene`, only for a stuck worker), and **gate** (`intent=relay-confirmation`, to relay a user confirmation into the worker pane). If the L2 driver's contract or its `intent` enum changes, keep all three dispatch sites and the `intent` enum (driver files + `templates/monitor.md` `driver-intent`) in lockstep.

The notify mechanism is deliberately a structured signature `(task-id, window, reason)` where `reason ∈ {needs-user, needs-attention, error}`. This version only prints to the conversation window and `SUMMARY.md`; that signature is the **future-webhook extension point** — a webhook / IM channel mounts there. There is intentionally no `orch-notify.sh` script (notify is L1's own conversation output); if a channel is added later, keep the signature fixed and wire the new channel behind it.
