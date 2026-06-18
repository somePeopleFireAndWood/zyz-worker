---
name: orchestration-scheduling-task
description: Use when the user wants to drive a master task list — analyze dependencies, dispatch parallel tmux/git-worktree workers running execute-task, aggregate state, gate merges on user approval. Typically paired with /loop for periodic state polling.
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

## Main Agent Loading

When this skill is used, the current user-facing conversation agent is the orchestrator (main agent). First load and follow the full controller prompt from:

```text
prompts/main-agent.md
```

That file is not a subagent. It defines how the current conversation agent coordinates the orchestration loop and talks with the user.

## Prompt Files

Load these files when needed:

- Main agent controller prompt: `prompts/main-agent.md` (load first when the skill starts).

There is no orchestration-scheduling-task subagent. The orchestrator dispatches `execute-task` workers, which in turn use the project subagents `coding-agent`, `test-agent`, `review-agent`.

Use these templates when creating master-list artifacts:

- Master list task entry: `templates/master-list-task-entry.md`
- Worker status: `templates/worker-status.md`
- Async question/answer: `templates/question-answer.md`

## Core Rules

- **Long-running state lives in files.** The master list directory `<list-dir>` is the single source of truth. Conversation context never replaces a file. Every orchestrator decision must be derivable from disk content; if a fact is not on disk, it does not exist. See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md).
- **Only one orchestrator at a time per master list.** The orchestrator acquires `<list-dir>/.orchestrator.lock` via `flock` at startup. Starting a second orchestrator against the same list fails. The lock guards orchestrator-vs-orchestrator concurrency; user edits to master entries are guarded procedurally (user must `Ctrl-C` the orchestrator first — see below).
- **Master entries are co-written with the user.** The orchestrator writes via `tmpfile + rename`. **Before the user edits a master entry in an external editor, the user must `Ctrl-C` the orchestrator** so the flock releases. Restart the orchestrator once the edit is saved.
- **Each worker writes only its own runtime files.** A worker writes `worker-status.md`, `question.md`, and uses `heartbeat` via the daemon. The orchestrator reads but never writes a worker's runtime files (except for archival during cleanup). The orchestrator writes the master entry; the worker never writes the master entry.
- **Heuristic analysis is always tentative.** Dependency, project, merge-with suggestions written by the orchestrator carry `deps-tentative: true` in the master entry frontmatter until the user flips it to `false`.
- **No automatic merge or cleanup.** `## Pending Merge Approval` must contain the literal token `approved` before the orchestrator invokes `orch-merge-and-cleanup.sh`. Stale-worker cleanup requires `cleanup-approved`.
- **`task-id` is whitelisted.** Helper scripts reject any `task-id` that does not match `^[a-zA-Z0-9_-]+$`. The `tmux` session, git branch, worktree path, and runtime dir all embed the literal `task-id`.
- **Worker tmux session name is fixed-prefix `zyz-task-<task-id>`.** Default git branch is `task/<task-id>`. Default merge base is `main`; override via master entry frontmatter `base:` field.
- **Heartbeat thresholds default to 300 s** (fresh / suspect / stale tiers per §A.6 of the design spec). When the worker reports `wait-state=waiting-user`, the threshold widens to 900 s. Do not drop below 120 s except on a strictly local (non-network) filesystem.
- **Orchestrated Mode handshake with `execute-task`.** The orchestrator exports `ZYZ_WORKER_STATUS_FILE`, `ZYZ_TASK_ID`, `ZYZ_QUESTION_FILE`, `ZYZ_ANSWER_FILE`, `ZYZ_HEARTBEAT_FILE` into the worker's tmux session. The worker's `execute-task` skill detects `ZYZ_WORKER_STATUS_FILE` and writes phase/wait-state to it. The orchestrator only sees what the worker flushes; in-context memory does not count.

## Workflow

The orchestrator runs a loop. Each tick (manual invocation or `/loop` wakeup) performs:

1. **scan** — `scripts/orch-scan-tasks.sh <list-dir>` lists every task entry, its declared `state`, and (for in-progress/paused tasks) the worker-reported phase + wait-state. Missing or illegal `state` values are treated as `not-analyzed`.
2. **analyze** — For `not-analyzed` tasks, run dependency / project / merge-with analysis. Write tentative results into the master entry `## Orchestrator Analysis` section. **If `## Description` is empty, leave `state: not-analyzed` and write `needs Description` into the analysis section; do not dispatch.**
3. **plan** — Decide which `ready` tasks to dispatch this tick (up to the configured max parallel workers). Move `blocked` tasks whose dependencies are now met to `ready`.
4. **dispatch** — For each task selected to dispatch, call `scripts/orch-spawn-worker.sh <task-id> <list-dir>` to create the worktree, tmux session, and in-pane heartbeat daemon. The default does **not** auto-start `claude`; the user attaches to the tmux session and starts `claude` + `/execute-task` manually unless `--auto-start` is used.
5. **poll** — For each `in-progress` or `paused` task, call `scripts/orch-check-worker.sh <task-id> <list-dir>` and project worker state into the master entry. On `heartbeat-status=fresh`, update `last-seen`. On stale (heartbeat stale OR phase-since unchanged for 5 ticks), write the stale summary into `## Notes` and shorten the cadence; do not silently change the master entry `state`.
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
| heartbeat | `<list-dir>/runtime/<task-id>/heartbeat` | in-pane heartbeat daemon | orchestrator |
| question | `<list-dir>/runtime/<task-id>/question.md` | worker | user |
| answer | `<list-dir>/runtime/<task-id>/answer.md` | user | worker |
| lock | `<list-dir>/.orchestrator.lock` | orchestrator (flock) | orchestrator |
| SUMMARY | `<list-dir>/SUMMARY.md` | orchestrator | user |

The lock guards only orchestrator-vs-orchestrator concurrency. User-vs-orchestrator concurrency is handled procedurally: the user must `Ctrl-C` the orchestrator before editing a master entry.

### Master entry frontmatter (excerpt)

```yaml
task-id: <task-id>            # immutable
project: <project name>       # user maintained
state: not-analyzed           # not-analyzed | blocked | ready | in-progress | paused | completed
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

Legal user-written values for `state:` are `not-analyzed | blocked | ready | completed`. The orchestrator writes `in-progress | paused` on its own.

### Worker status frontmatter (excerpt)

```yaml
task-id: <task-id>
phase: design | coding | testing | review | delivery | done | error
phase-since: <iso>
wait-state: none | waiting-user | waiting-subagent | waiting-resource
waiting-reason: <free text; non-empty when wait-state != none>
expected-resume-by: <iso; non-empty when wait-state != none>
last-flush: <iso>
```

The worker flushes status before any suspend, before dispatching a subagent, and on every phase transition. The orchestrator reads but never writes `worker-status.md`.

## State Machine

Six explicit states + one orchestrator-derived state (`stale`):

| State | Meaning | Set by |
|---|---|---|
| `not-analyzed` | Task is new; orchestrator has not analyzed it yet. | template default / scan |
| `blocked` | Dependencies unmet, or worker reported `phase=error`. | orchestrator |
| `ready` | No blockers; dispatchable. | orchestrator |
| `in-progress` | Worker dispatched; tmux session alive; heartbeat fresh; phase not done/error. | orchestrator |
| `paused` | Worker dispatched; `wait-state != none`. | orchestrator (projects worker's wait-state) |
| `completed` | Implementation done; merge passed; cleanup done. | orchestrator |
| `stale` (derived) | Heartbeat past stale threshold OR `phase-since` unchanged for 5 ticks. Master entry `state:` is **not** rewritten; stale is reported via the `## Notes` section and the `last-seen` field. | orchestrator |

Transitions (informal):

- `not-analyzed` → `ready` (analysis ok, no blockers) | `blocked` (analysis ok but deps unmet)
- `blocked` → `ready` (deps met or error resolved)
- `ready` → `in-progress` (orchestrator dispatches)
- `in-progress` → `paused` (worker writes `wait-state != none`) | `completed` (worker writes `phase=done` and user approves merge) | `blocked` (worker writes `phase=error`)
- `paused` → `in-progress` (worker writes `wait-state=none`)

Full state machine and the phase mapping table for `execute-task` workflow positions live in the design spec (§A and §D.5 of `.zyz-worker/tasks/orchestration-scheduling-task/design-spec.md`).

## Long-Running State

This skill enforces the zyz-worker [long-running-state convention](../../docs/conventions/long-running-state.md) end-to-end:

- The master list directory **is** the state. The orchestrator must derive every decision from disk content.
- The worker writes `worker-status.md` before any suspend.
- The heartbeat daemon writes the `heartbeat` file every 30 s while alive (it dies with the tmux session — no manual `pkill` needed).
- The orchestrator writes `SUMMARY.md` once per tick.

If the orchestrator's conversation context is dropped or compacted, restarting `/orchestrate-tasks <list-dir>` rebuilds full situational awareness from disk alone.

## Optional Skills And Plugins

Before scanning, analyzing, dispatching, or summarizing, check whether the current agent already has relevant skills, plugins, or tools available:

- Use git-related skills (e.g., the `git-worktree` skill in this plugin) to derive default worktree paths.
- Use the `/loop` slash command (Claude Code) to drive periodic ticks with dynamic intervals; see the cadence policy in `prompts/main-agent.md`.
- Use documentation, engineering workflow, or testing skills (`llmdoc`, `superpowers`, …) if available; record usage in the SUMMARY.

Do not block, fail, or ask the user to install anything when these optional capabilities are unavailable.

## Maintenance Notes

This skill is coupled to `execute-task`. If `execute-task` ever introduces a new phase, the orchestrated-mode contract here must be updated in lockstep:

- The `phase:` enum in the worker status template must be extended.
- The phase mapping table (design-spec §D.5) must be extended.
- This SKILL.md and `prompts/main-agent.md` should mention the new phase explicitly.
