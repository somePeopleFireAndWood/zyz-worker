# Hooks

Deterministic watchdog layer for the execute-task workflow. It hardens three
rules that prompt discipline alone cannot guarantee:

1. **Silent/dead subagents get noticed.** Liveness becomes a mechanical side
   effect of tool calls, and dead roles are surfaced to the main agent.
2. **Status files stay fresh.** Stale status triggers injected reminders,
   exit gates, and stop gates instead of relying on the model remembering.
3. **Recovery never shrinks the ask.** A dispatch that caps what a role must
   deliver is denied before it reaches the role (L5) — reducing per-round
   output volume is fine, reducing the total deliverable is not.

All hooks are registered in `hooks.json` (loaded automatically when the
plugin is enabled) and fail open: any missing input, missing JSON parser
(`jq` or `python3`), or write error exits 0 silently — the watchdog must
never break or slow the workflow it protects. Every script no-ops unless
the session cwd contains a `.zyz-worker/current-task` pointer (first line:
task id, or a task-directory path) resolving to an existing task directory.
The main agent writes that pointer at workflow §1 Start Task.

Set `ZYZ_HOOKS_DISABLE=1` to disable the entire layer.

Runtime bookkeeping lives under `<task-dir>/runtime/`:

- `runtime/agents/<key>.heartbeat` — stamped on every tool call (`<key>` =
  sanitized agent_id, or `main`)
- `runtime/agents/<key>.start` / `.done` — role dispatched / role finished
  cleanly. `.start` + no `.done` + stale heartbeat = dead-or-stuck role.
- `runtime/nag/*.last` — cooldown stamps (epoch) for rate-limiting.

## scripts/lib.sh

- Trigger point: sourced by every hook and monitor script; never executed.
- Inputs: `ZYZ_HOOK_INPUT` (raw hook JSON) set by the caller.
- Outputs: helper functions only (JSON field extraction, mtime, atomic
  writes, task-root resolution, additionalContext / block-decision JSON
  emission, stale-role scanning).
- Failure behavior: every helper prints nothing and returns success on
  missing input; callers fail open.
- Supported agents: all. macOS bash 3.2 + Linux compatible.

## scripts/heartbeat.sh — L0

- Trigger point: `PreToolUse` + `PostToolUse`, matcher `*`, async.
  Fires in the main agent and inside every subagent.
- Inputs: hook JSON on stdin (`cwd`, `agent_id?`, `agent_type?`);
  `CLAUDE_PROJECT_DIR` fallback.
- Outputs: none on stdout; stamps `runtime/agents/<key>.heartbeat`.
- Failure behavior: fail open, exit 0 always.
- Supported agents: all.

## scripts/subagent-track.sh — L0

- Trigger point: `SubagentStart`, matcher
  `^(zyz-worker:)?(implementation-agent|test-agent|review-agent)$`.
- Inputs: hook JSON on stdin (`cwd`, `agent_id`, `agent_type`).
- Outputs: none on stdout; stamps `runtime/agents/<key>.start`.
- Failure behavior: fail open.
- Supported agents: zyz-worker roles (via matcher).

## scripts/status-freshness.sh — L1

- Trigger point: `PostToolUse`, matcher `*`, sync (context must land next
  to the tool result).
- Inputs: hook JSON on stdin; `ZYZ_STATUS_STALE_SEC` (default 600),
  `ZYZ_STATUS_NAG_COOLDOWN_SEC` (default 300).
- Outputs: `hookSpecificOutput.additionalContext` reminding the current
  context (main agent, or implementation/test subagent) to persist
  progress, when the overall status file is stale during an active phase.
  Rate-limited per audience via `runtime/nag/<audience>.last`.
- Failure behavior: fail open; advisory only, never blocks.
- Supported agents: main agent, implementation-agent, test-agent
  (review-agent is excluded — it must not write files).

## scripts/post-agent-flush.sh — L1

- Trigger point: `PostToolUse`, matcher `^Agent$`, sync (main agent only;
  exits when `agent_id` is present or the launch was `async_launched`).
- Inputs: hook JSON on stdin; `ZYZ_POST_RESULT_FLUSH_SEC` (default 120),
  `ZYZ_POST_RESULT_COOLDOWN_SEC` (default 60).
- Outputs: `additionalContext` telling the main agent to persist the
  just-received subagent result into the status file before dispatching
  further work.
- Failure behavior: fail open.
- Supported agents: main agent.

## scripts/dispatch-scope-guard.sh — L5

The only layer that inspects what a dispatch *asks for*; every other layer
observes after the fact. It exists because the recovery path has its own
failure mode: when a role stalls, the tempting fix is to shrink the ask so
it can finish, and a review that reported only its worst few findings then
passes every downstream gate looking clean.

- Trigger point: `PreToolUse`, matcher `^Agent$`, sync (a deny decision
  requires sync). Only inspects dispatches whose `subagent_type` is a
  zyz-worker role; anything else passes untouched.
- Inputs: hook JSON on stdin (`tool_input.prompt`,
  `tool_input.subagent_type`); `ZYZ_SCOPE_GUARD_DISABLE=1` disables just
  this guard, `ZYZ_HOOKS_DISABLE=1` the whole layer.
- Outputs: a `PreToolUse` deny (`hookSpecificOutput.permissionDecision:
  "deny"` — deny reasons are shown to the model, so it can correct and
  retry) when the prompt caps the deliverable ("only the top 3 findings",
  "just the overall verdict", "只要总结论", "最严重 3 条", "一句话结论",
  "skip the details") AND carries no commitment to deliver the remainder
  ("then continue", "the rest in later messages", "step 1 of 4", "分步",
  "分维度", "register all dimensions"). The reason tells the main agent to
  re-dispatch at full scope split into labeled steps. Blocked attempts are
  appended to `<task-dir>/runtime/scope-guard.log`.
- Failure behavior: fail open (allow) on missing input/parser/pointer.
  Matching is heuristic by nature, hence the continuation-commitment
  exemption and the per-guard disable switch; the suite's T7 group pins 10
  capped phrasings that must deny and 10 legitimate ones that must pass.
- Supported agents: main agent dispatching implementation-agent /
  test-agent / review-agent.

## scripts/stop-gate-subagent.sh — L2

- Trigger point: `SubagentStop`, same role matcher as subagent-track.
  NOT guaranteed to fire on API-error death — L3 covers that gap. No-op
  without the `current-task` pointer (the gate never applies outside an
  execute-task workflow).
- Inputs: hook JSON on stdin (`stop_hook_active`,
  `last_assistant_message`); `ZYZ_SUBAGENT_MIN_FINAL_CHARS` (default 80).
- Outputs: on a clean stop, stamps `runtime/agents/<key>.done`. When the
  final message is shorter than the minimum, emits
  `{"decision":"block","reason":...}` once, instructing the role to emit a
  proper final report (the `.done` stamp is deferred to the next stop).
- Failure behavior: fail open (allow stop); never blocks when
  `stop_hook_active` is true; built-in 8-block cap applies.
- Supported agents: zyz-worker roles (via matcher).

## scripts/stop-gate-main.sh — L4

- Trigger point: `Stop` (main agent finished responding).
- Inputs: hook JSON on stdin (`stop_hook_active`, `background_tasks`);
  `ZYZ_ROLE_STALE_SEC` (default 900), `ZYZ_ROLE_STALE_HORIZON_SEC`
  (default 21600), `ZYZ_STOP_STATUS_STALE_SEC` (default 1200),
  `ZYZ_STOP_GATE_COOLDOWN_SEC` (default 600).
- Outputs: `{"decision":"block","reason":...}` when, during an active
  phase, a dispatched role looks dead (`.start`, no `.done`, stale
  heartbeat, and not listed as a running background subagent task) or the
  status file is badly stale. The reason names the exact roles to check.
  Rate-limited via `runtime/nag/stopgate.last`.
- Failure behavior: fail open (allow stop).
- Supported agents: main agent.

## ../monitors/watchdog.sh — L3

See `monitors/monitors.json`: a background monitor started on the first
execute-task invocation in a session. Scans heartbeats and status mtime
every `ZYZ_WATCHDOG_INTERVAL_SEC` (default 60) and emits one notification
line per finding (silent role / stale status), which wakes the main agent
even when the session is idle. This is the layer that catches subagents
killed by API errors, where `SubagentStop` never fires. Thresholds:
`ZYZ_WATCHDOG_ROLE_STALE_SEC` (default 1200 — deliberately above the L4
gate's, since L3 cannot cross-check `background_tasks` and a healthy role
may reason without tool calls; its message asks the main agent to VERIFY,
not blindly restart), `ZYZ_WATCHDOG_STATUS_STALE_SEC` (default 1800),
cooldown `ZYZ_WATCHDOG_COOLDOWN_SEC` (default 900).

## Degraded environments

Plugin hooks may be blocked by managed policy, and monitors are
unavailable on some platforms/versions. The workflow's prompt-level duties
(`## Long-Running Work`, the flush rules in `## Core Rules`) remain in
force regardless and become the only enforcement there — the watchdog is a
backstop, not a replacement.
