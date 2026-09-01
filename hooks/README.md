# Hooks

## Role runtime state protocol

Role instances are keyed by a readable 32-byte sanitized prefix plus the full SHA-256 of the raw agent id. The supported state-changing entry point is `hooks/scripts/agent-runtime-state.sh`; never create, edit, or delete `runtime/agents` files by hand.

```text
agent-runtime-state.sh finalize <task-dir> <agent-id> <role> <reason> [replacement-agent-id]
agent-runtime-state.sh probe-create <task-dir> <agent-id> <role>
agent-runtime-state.sh probe-ack <task-dir> <agent-id> <probe-id>
agent-runtime-state.sh probe-status <task-dir> <agent-id>
agent-runtime-state.sh probe-cancel <task-dir> <agent-id> <probe-id> <reason>
agent-runtime-state.sh adopt-legacy <task-dir> <agent-id> <role> confirmed
agent-runtime-state.sh reconcile-start <task-dir> <agent-id> <role> <event-token> confirmed
agent-runtime-state.sh reconcile-stop <task-dir> <agent-id> <role> <event-token> confirmed
agent-runtime-state.sh gc-step <task-dir> <watchdog|lifecycle|manual|system-timer>
```

DONE and FINALIZED are logical fixed-pack records. FINALIZED is auditable
confirmed-death evidence distinct from natural DONE; either terminal record
takes priority over late heartbeat/inflight/probe/no-output state. Probe ACK is
explicit plugin-level observation, not a host delivery receipt; heartbeats
never acknowledge probes.

`probe-ack` and `probe-cancel` reject a malformed probe id before reading or mutating instance state with exit 2 and `error.code="invalid-probe-id"`. A syntactically valid `probe1-<32 lowercase hex>` id that is not the exact current pending challenge instead returns exit 4 and `error.code="probe-mismatch"`. Both errors retain the canonical JSON envelope and never echo or persist the rejected payload beyond the bounded output-only argv fields.

A bounded wait is written only inside the single `## Agent State` section of `status.md` as `- Waiting On: instance-key=<key>; since-epoch=<unix>; next-check-epoch=<unix>; reason=<single-line text>`. All rows must be valid, unique, unexpired, and within `ZYZ_WAIT_MAX_SEC`. A valid set suppresses main status-stale only.

## Public runtime bounds

| Environment | Default | Valid values |
|---|---:|---|
| `ZYZ_WAIT_MAX_SEC` | 3600 | 1..86400 |
| `ZYZ_RECONNECT_ACK_SEC` | 600 | 0 disables create; otherwise 1..86400 |
| `ZYZ_INFLIGHT_GRACE_SEC` | 1800 | 1..86400 |
| `ZYZ_RUNNING_NO_ACK_GRACE_SEC` | 600 | 1..86400 |
| `ZYZ_AGENT_LOCK_ACQUIRE_SEC` | 2 | 1..30 |
| `ZYZ_AGENT_LOCK_STALE_SEC` | 120 | 1..86400 |
| `ZYZ_WATCHDOG_NO_OUTPUT_SEC` | 1800 | 0 disables; otherwise 1..604800 |
| `ZYZ_NO_OUTPUT_MAX_PATHS` | 10000 | 1..1000000 |
| `ZYZ_NO_OUTPUT_MAX_FILE_BYTES` | 16777216 | 1..1073741824 |
| `ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES` | 67108864 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES` | 33554432 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES` | 33554432 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_MAX_RSS_BYTES` | 134217728 | 16777216..1073741824 |
| `ZYZ_NO_OUTPUT_MAX_TEMP_BYTES` | 134217728 | 1..2147483647 |
| `ZYZ_NO_OUTPUT_TEMP_STALE_SEC` | 120 | 1..86400 |
| `ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC` | 8 | 1..8 |
| `ZYZ_SNAPSHOT_GC_INTERVAL_SEC` | 300 | 0 disables watchdog/lifecycle opportunities; otherwise 1..86400 |
| `ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS` | 10000 | 1..1000000 |
| `ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS` | 134217728 | 1..2147483647 |
| `ZYZ_SNAPSHOT_GC_MAX_SEC` | 2 | 1..30 |
| `ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES` | 536870912 | 33554432..2147483647 and less than hard water |
| `ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES` | 1073741824 | 67108864..2147483647, greater than high water, and at least the structural floor |

Values are canonical decimal and range-checked before arithmetic; invalid input uses the documented default with a diagnostic. Only the three stated zero modes exist. The high/hard-water pair falls back atomically to both defaults when either member is invalid or `high >= hard`. SubagentStart has a 15-second host budget. Physical comparison excludes exactly this task's runtime and `.git`; it uses path presence, type, permissions, and bytes rather than Git metadata, and reports unavailable when bounds or platform safety cannot be proven.

Physical snapshots are descriptor-pinned and fail closed. The scanner walks
cwd ancestry and the worktree one component at a time with nofollow opens,
revalidates every name/inode/type/nlink binding, and requires a native per-vnode
mount identity. Only Linux `statx(STATX_MNT_ID)` satisfies that contract today:
on macOS the `getattrlistat` FSID plus opened-fd `fstatfs` cross-check is
computed but then rejected, because a filesystem-wide FSID cannot distinguish a
second same-FSID mount instance or bind boundary — Darwin therefore fails
closed with `genesis-capability-unavailable` (see **Degraded environments**).
Raw paths and canonical records use binary
length-prefixed spill files and an external merge. RLIMIT_AS, observed peak RSS,
temp bytes, deadline, path, manifest, inventory, total-read, and single-file
ceilings are enforced during the real scan. A platform that cannot prove one of
these properties reports snapshot unavailable; it never substitutes `st_dev`.

Snapshot publication uses fixed PUBLICATION_JOURNAL and LIVE_INVENTORY slots,
not standalone control journals or inventory pointers. The live cumulative
inventory binds every catalog-owned data header/record by purpose, generation,
raw-safe basename, type, size, SHA-256, dev/ino/nlink, mtime, and native mount
id. Superseded targets remain owned by a fixed cleanup intent.

Cleanup is exposed only as bounded `gc-step`. Fixed claim packs own immutable
keys, owners, observations, GC journals, checkpoints, pointers, receipts, and
anchor acknowledgements. Artifact cleanup validates an opened nofollow fd
against every inventory identity field and obeys the configured per-pass byte
and entry budgets. Budget exhaustion is canonical `pending`, never guessed
success.

Large verification resumes through authenticated fixed CHECKPOINT and POINTER
slots. A checkpoint persists the target cursor, file offset/expected size,
cumulative counters, and standard SHA-256 state (eight chaining words,
full-block count, partial block bytes). Fixed A/B generations and their header
predecessor chain replace temporary control-file publication.

After the compacted live inventory, receipt publication uses `will/did-receipt`.
The authentication key is then removed through `will/did-key-delete`; only the
final `committed` journal makes the receipt consumable by terminal compaction.
A killed pass resumes exact journal-owned prior/after sets, and terminal output
remains honestly `pending`, `blocked`, or `compacted`. Lock owners,
prepared-owner GC, publication, reconciliation, terminal, and legacy-adoption
transactions likewise persist `will-*` before an effect and `did-*` afterward.
Do not edit these artifacts manually; replay the same supported public command.

Scanner scratch state has its own owner protocol. A complete owner is first
written as `.snapshot-owner.prepare.<64hex>`, fsynced, and atomically committed
as `.snapshot-owner.<64hex>` before the separate mode-0700
`.snapshot-tmp.<64hex>` directory exists. The owner binds strong process birth,
host/boot, task/root/runtime/baseline identities and native runtime mount. The
parent polls terminal/cancel state and removes its exact owner/temp on normal
completion, error, TERM, or timeout. A later hook may reclaim only an old,
same-host/boot owner whose PID is provably dead/reused and whose current
task/root/runtime/baseline bindings still match. Its authenticated
`<nonce>.snapshot-temp-gc-journal` walks descriptor-only postorder, persists the
raw path and identity at `will-entry-delete-N`, and confirms
`did-entry-delete-N`; symlinks are unlinked themselves, special files are never
opened, nested mounts block cleanup, and at most 10,000 entries are deleted per
pass. Owner/temp-only, malformed, future, cross-host/boot, live, or changed
bindings remain for audit rather than being guessed safe.

Start/stop hooks select their event only while holding the instance lock after
validating the complete bounded retained-event inventory. Randomness is 16
bytes from Python `secrets`, with only an exact `/dev/urandom` read as fallback;
collisions retry eight times. A held-lock primary failure may append a bounded
logical start-unarmed or stop-uncommitted entry to DIAGNOSTICS. The matching
`reconcile-start`/`reconcile-stop` verifies its three identity fields and all
target slot generations/digests, resumes each fixed journal boundary, and
appends an immutable RESOLVED_START or RESOLVED_STOP receipt. Tokenless
lock/randomness/inventory/collision or double-write failure has no disk identity
and no reconcile path.

Legacy adoption locks the sanitized old source before the full-hash target,
copies the original start evidence bytes/timestamp into fixed target records,
and commits the migration receipt in fixed slots before removing bounded legacy
source triggers.

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

The manifest resolves hook scripts through the host-provided `PLUGIN_ROOT`,
then the orchestrated `ZYZ_PLUGIN_ROOT`, then `CLAUDE_PLUGIN_ROOT`, and finally
the legacy, non-canonical `CODEX_PLUGIN_ROOT`. Unset and empty values both fall
through to the next variable. If every root is missing, the hook succeeds as a
no-op; it never searches the session cwd, a source checkout, or a marketplace
path. A bare `./hooks` path is not sufficient: Codex 0.147.0 resolves it from
the worker cwd. Tool
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

- `.snapshot-gc-owned.v1/.catalog-global-pack.v1` — authenticated catalog,
  schedule, counters, and the main `main_heartbeat_epoch` record.
- fixed per-instance audit/work packs — logical IDENTITY, START, HEARTBEAT,
  DONE, FINALIZED, probe, diagnostic, receipt, baseline-inventory, and inflight
  records. Record names are not standalone pathnames and are read only through
  the shared parser.
- `runtime/nag/*.last` — cooldown stamps (epoch) for rate-limiting.

## scripts/lib.sh

- Trigger point: sourced by every hook and monitor script; never executed.
- Inputs: `ZYZ_HOOK_INPUT` (raw hook JSON) set by the caller.
- Outputs: helper functions only (JSON field extraction, mtime, atomic
  writes, task-root resolution, additionalContext / block-decision JSON
  emission, and authenticated fixed-pack observation).
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
- Outputs: none on stdout; updates PACK_HEADER for main or the instance-local
  fixed HEARTBEAT/INFLIGHT records for a dynamic role.
- Failure behavior: fail open, exit 0 always.
- Supported agents: all.

## scripts/subagent-track.sh — L0

- Trigger point: `SubagentStart`, matcher
  `^(zyz-worker:)?(implementation-agent|test-agent|review-agent)$`.
- Inputs: hook JSON on stdin (`cwd`, `agent_id`, `agent_type`).
- Outputs: none on stdout; commits fixed IDENTITY/START journal state and, for
  implementation/test roles when capability permits, a fixed LIVE_INVENTORY
  baseline publication.
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
- Outputs: on a clean stop, commits logical DONE, closes active/probe/inflight
  state, and advances terminal handoff/cleanup through fixed records. When the
  final message is shorter than the minimum, emits
  `{"decision":"block","reason":...}` once, instructing the role to emit a
  proper final report; no terminal record is committed until the accepted stop.
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
  phase, the authenticated observer reports a non-terminal role with stale
  liveness or unarmed tracking and it is not listed as a running background
  subagent task, or the status file is badly stale. The reason names the exact
  roles to check.
  Rate-limited via `runtime/nag/stopgate.last`.
- **Terminal-but-unharvested check (primary layer).** Alongside those reasons,
  L4 also blocks the idle attempt when a role reached a terminal state
  (clean DONE or adjudicated FINALIZED, per the observer's authority) but the
  main agent has been idle since it completed — the symptom of a dropped
  subagent-completion notification, where the result is already on disk but the
  main agent never processed it. Predicate (all three, per instance): `terminal`
  is true AND `main_heartbeat_epoch <= terminal_epoch` (the main agent's last
  tool call predates the completion) AND `status.md` mtime `<= terminal_epoch`
  (no status written since). The `<=` is intentional fail-toward-flag at exact
  equality. Every epoch is `isinstance(int)`-guarded — a missing top-level
  `main_heartbeat_epoch` exits the filter, a missing per-instance
  `terminal_epoch` skips that instance — so an unavailable epoch never throws.
  The block reason names the completed role and where its result lives (its
  subtask status file / durable log) and instructs: read the result and record
  it before idling. It is **satisfiable and self-clearing** — reading the result
  plus any status write advances `main_heartbeat_epoch`/mtime past
  `terminal_epoch`, so the condition fails on the next stop and the block
  disappears; it honors `stop_hook_active` and shares the single
  `runtime/nag/stopgate.last` 600s cooldown token with the stale-role block
  (within one window either can suppress the other — accepted). This is L4 as the
  **primary** layer: a synchronous Stop-hook check that does not ride the
  unreliable completion-notification channel, so it catches the common case
  (role finished, notification dropped, main agent tries to go idle) with
  certainty. It is a **mitigation** — it reduces the main agent's dependence on
  the dropped completion path, not a root-cause fix of the harness delivery
  layer. Like every observer-based check it is **inert on macOS** (observer
  returns `genesis-capability-unavailable`) and active on Linux — the same
  boundary as the dead-role scan.
- **"Active phase" excludes anything naming `design`.** `*review*` alone would
  match `design review`, which would make this gate block the main agent from
  idling at §2 step 8 — the one gate the workflow mandates waiting at
  indefinitely for human approval — while the prompts promise silence during
  design. `zyz_phase_active` applies the `design` exclusion first.
- **The block must be satisfiable by compliance.** The gate never asks callers
  to hand-edit runtime. A clean role submits DONE through SubagentStop; a role
  confirmed dead by platform/probe evidence is finalized with the supported
  helper before redispatch; a persisted start/stop diagnostic is handled only
  by its exact `reconcile-*` event token.
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

The instance loop no longer blindly skips terminal instances: non-terminal
ones take the existing stale-liveness / tracking-unarmed / probe-overdue /
no-output branches, and terminal ones take the new **terminal-but-unharvested
scan (backup layer)**. It fires when a role reached a terminal state but the
main agent has been idle since — same predicate as L4 (`terminal` AND
`main_heartbeat_epoch <= terminal_epoch` AND `status.md` mtime
`<= terminal_epoch`, same `isinstance(int)` guards, same intentional `<=`
boundary). Because the new terminal branch shares the loop's single
`try/except`, the epoch guards are load-bearing: without them a `None <= int`
would throw and abort the whole loop, dropping every other instance's event —
so a missing epoch `continue`s that instance and leaves the rest intact. On a
match it emits one `unharvested` notification line naming the completed role
and its result location, rate-limited via a per-key
`runtime/nag/watchdog-unharvested-<key>.last` (its own cooldown, distinct from
the other watchdog keys). This is the **backup** to L4: it covers the case L4
cannot — the role goes terminal *after* the main agent has already idled (L4
already let that stop through), so only the timer can then wake it. The message
states it is a backup signal; the detection rides the watchdog notification
path, which this session's observation shows is more reliable than the
completion path but is not guaranteed (hence L4 synchronous is primary). Like
the dead-role scan it is **inert on macOS** and active on Linux.

## Degraded environments

Plugin hooks may be blocked by managed policy, and monitors are
unavailable on some platforms/versions. The workflow's prompt-level duties
(`## Long-Running Work`, the flush rules in `## Core Rules`) remain in
force regardless and become the only enforcement there — the watchdog is a
backstop, not a replacement.

**macOS (Darwin) is a degraded platform for the fixed-pack tracking layer.**
The catalog genesis requires a native per-vnode mount identity, and macOS
exposes no API that can distinguish a second same-FSID mount instance, so
every tracked-state operation (`hook-start`, `hook-stop`, `hook-heartbeat`,
`hook-observe`, `finalize`, probes, `gc-step`) fails closed with
`genesis-capability-unavailable` on Darwin. Consequences: no instance state
is written, and the L3 watchdog and L4 stop gate have no role observations —
**dead-role detection is disabled on macOS**, including the API-error-kill
case. Everything stays fail-open (nothing blocks, crashes, or slows beyond
the ~100 ms hook startup), and the still-functioning layers are the
status-file staleness branches (L1/L3/L4), the L2 short-final-message gate,
and prompt discipline. The main-agent prompt requires verifying
`main_heartbeat_epoch` at task start and declaring the watchdog inert when
unverifiable — on macOS that check honestly fails and the disclosure fires
every task. Linux hosts (including containers) are fully supported.
