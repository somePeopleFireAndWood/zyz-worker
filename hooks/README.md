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

The manifest resolves hook scripts through `CODEX_PLUGIN_ROOT`, then the
orchestrated `ZYZ_PLUGIN_ROOT`, then `CLAUDE_PLUGIN_ROOT`. A bare `./hooks`
path is not sufficient: Codex 0.147.0 resolves it from the worker cwd. Tool
matchers accept both Claude names (`Agent`, `Bash`) and
Codex names (`spawn_agent`/`collaboration.spawn_agent`,
`exec_command`/`functions.exec`). Hook scripts resolve the base directory from
input `cwd`, then `CODEX_PROJECT_DIR`, `CLAUDE_PROJECT_DIR`, and `$PWD`. Codex
has no Claude monitor manifest lifecycle or async-hook notification channel, so
`SessionStart` synchronously runs `start-watchdog.sh`; that short helper detaches
the shared scanner to a per-thread temp log. Codex L0/L1/Stop hooks remain the
in-session enforcement path.

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
- Cost note: `zyz_get` spawns one `jq` (or `python3`) per field read, and the
  hot-path hooks read 2-3 fields per tool call. Heartbeats are synchronous
  because current Codex versions skip async hooks; `status-freshness.sh` is
  also sync. Do **not** try to fix this by memoizing
  `zyz_get` in a shell variable — every call site is `x="$(zyz_get foo)"` and
  command substitution runs in a subshell, so the cache never survives to the
  next call (tried, measured, no gain; see the note in `lib.sh`). The working
  approach is a single-pass extraction inside the hook script itself.
- Failure behavior: every helper prints nothing and returns success on
  missing input; callers fail open.
- Supported agents: all. macOS bash 3.2 + Linux compatible.

## scripts/heartbeat.sh — L0

- Trigger point: `PreToolUse` + `PostToolUse`, matcher `*`, synchronous for cross-runtime compatibility.
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
  to the tool result). **Defers when `tool_name` is `Agent`** — that moment
  belongs to `post-agent-flush.sh`, which reads the same mtime and would
  otherwise inject a second, near-identical reminder into the same turn
  (their cooldowns are independent, so neither suppresses the other).
- Inputs: hook JSON on stdin; `ZYZ_STATUS_STALE_SEC` (default 600),
  `ZYZ_STATUS_NAG_COOLDOWN_SEC` (default 300).
- Outputs: `hookSpecificOutput.additionalContext` reminding the current
  context (main agent, or implementation/test subagent) to persist
  progress, when the overall status file is stale during an active phase.
  Rate-limited per audience via `runtime/nag/<audience>.last`.
- Failure behavior: fail open; advisory only, never blocks.
- Supported agents: main agent, implementation-agent, test-agent
  (review-agent is excluded — it owns no status file to flush; its Bash
  access is for read-only reruns and throwaway mutations that must be
  restored, never for deliverable writes).

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
- Three guards against over-matching, all pinned by T7:
  1. **Negation veto** — a prompt that forbids truncation ("do not just report
     the verdict", "只要总结论是不够的") is never a cap. Evaluated on the FULL
     text, before quote-stripping, so a quoted negation keeps its veto.
  2. **Quote-stripping** — caps are matched against a copy with `"…"`,
     `` `…` ``, and `'…'` spans blanked out, so a prompt that *quotes* a
     capping phrase (docs, tests, changelog work about this guard — routine
     here) is not read as *issuing* one. A `'` only opens a span after
     whitespace or punctuation, so contractions cannot swallow real text.
     Deliberate tradeoff: a prompt that is *entirely* a quoted cap passes.
  3. **The cap must name a review deliverable** (`findings|issues|problems`).
     Without this, ordinary domain requirements matched — "no more than 3
     items per page", "cap it at 3 attempts".
- Failure behavior: fail open (allow) on missing input/parser/pointer.
  Matching is heuristic by nature, hence the exemptions above and the
  per-guard disable switch; T7 pins 23 capped phrasings that must deny and 28
  legitimate ones that must pass. T7's payload builder JSON-escapes the
  prompt — raw interpolation of a fixture containing `"` yields invalid JSON,
  the guard fails open, and the assertion passes vacuously.
- Supported agents: main agent dispatching implementation-agent /
  test-agent / review-agent.

## scripts/stop-gate-subagent.sh — L2

- Trigger point: `SubagentStop`, same role matcher as subagent-track.
  NOT guaranteed to fire on API-error death — L3 covers that gap. No-op
  without the `current-task` pointer (the gate never applies outside an
  execute-task workflow).
- Inputs: hook JSON on stdin (`stop_hook_active`,
  `last_assistant_message`); `ZYZ_SUBAGENT_MIN_FINAL_CHARS` (default 80,
  measured in BYTES).
- Outputs: on a clean stop, stamps `runtime/agents/<key>.done` **and deletes
  that role's `.start`/`.heartbeat`** — clearing the stale-scan trigger rather
  than adding a third file that suppresses it, which is what keeps `runtime/`
  from growing a marker triple per dispatch and what makes an L4 dead-role
  block clearable at all. When the final message is shorter than the minimum,
  emits `{"decision":"block","reason":...}` once, instructing the role to emit
  a proper final report (the markers are left alone until the next stop).
- The threshold is in bytes on purpose: `${#var}` counts characters under a
  UTF-8 locale but bytes under `LC_ALL=C`, so a complete 45-character Chinese
  report measured 45 against a threshold of 80 and got blocked. 80 bytes is
  ~80 ASCII characters or ~26 CJK characters — both genuinely too short.
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
- **"Active phase" excludes anything naming `design`.** `*review*` alone would
  match `design review`, which would make this gate block the main agent from
  idling at §2 step 8 — the one gate the workflow mandates waiting at
  indefinitely for human approval — while the prompts promise silence during
  design. `zyz_phase_active` applies the `design` exclusion first.
- **The block must be satisfiable by compliance.** This gate reads only the
  runtime markers, never `status.md`, so the reason names the exact `rm -f` of
  the role's `.start`/`.heartbeat` alongside the re-dispatch option. An earlier
  version said "mark it finished in the status file", which the gate could not
  see: the agent complied, the marker stayed, and it re-blocked until the
  cooldown or the platform block cap timed out. A `.start` is otherwise cleared
  only by a clean `SubagentStop` — the event that does not fire on the
  API-error death this gate exists to catch.
- Failure behavior: fail open (allow stop).
- Supported agents: main agent.

## scripts/checkout-guard.sh — L6

The shared-worktree revert guard. Exists because of a real accident: an
audit agent reverted its throwaway mutation with `git checkout <file>` —
which resets to HEAD — and deleted another agent's uncommitted work in the
same file (~5000 chars of security-guard code). Never-committed content is
in NO git recovery mechanism, and the build stayed green because the loss
sat behind a runtime type-assertion seam; recovery required replaying the
author agent's transcript.

- Trigger point: `PreToolUse`, matcher `^Bash$`, sync (a deny requires
  sync). Applies only when the session has an active task pointer — general
  (non-task) sessions keep full git freedom.
- Inputs: hook JSON on stdin (`cwd`, `tool_input.command`);
  `ZYZ_CHECKOUT_GUARD_DISABLE=1` disables just this guard (parsing shell
  with shell is heuristic by nature, so a per-guard escape hatch is
  mandatory — same policy as L5), `ZYZ_HOOKS_DISABLE=1` the whole layer.
- Outputs: a `PreToolUse` deny when the command is (a) `git checkout` /
  `git restore` naming a file that currently has UNCOMMITTED modifications
  (`git status --porcelain` decides; clean files, branch names, `-b`, and
  untracked paths all pass), or (b) a state-moving `git stash` form (bare /
  push / save / pop / apply / drop / clear — `list`/`show` pass). The deny
  reason carries the safe recipe: cp-backup before mutating + mv to
  restore, `git show HEAD:<file>` to read the committed version,
  `git diff > patch` + `git apply -R` for set-asides.
- Failure behavior: fail open (allow) on missing input/parser/pointer,
  git absent, non-repo cwd, or malformed JSON. Argument scanning stops at
  the first shell metacharacter so a following command's words are never
  misread as checkout targets.
- Supported agents: all — the incident's command came from a subagent.

## ../monitors/watchdog.sh — L3

See `monitors/monitors.json`: a background monitor armed with
`when: "always"` (so it starts with the session) and self-gated on the
`.zyz-worker/current-task` pointer, which makes it inert until a task is
active. It is deliberately NOT `on-skill-invoke:execute-task`: that value is
compared as an exact string against the emitted skill name, and the same
skill emits `zyz-worker:execute-task` under a plugin install but bare
`execute-task` in project mode — one literal cannot arm in both, and the
bare form shipped for a while and never armed under a normal install.
Scans heartbeats and status mtime
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
