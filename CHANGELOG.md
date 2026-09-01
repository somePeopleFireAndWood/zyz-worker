# Changelog

All notable changes to zyz-worker are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.18.1] — 2026-09-01

- **Teach the `git-worktree` skill copy-on-miss for untracked-but-required
  files.** A fresh worktree only holds what git tracks, so gitignored local
  files a project needs to build/start/test (`conf/test.yaml`, `.env`, local
  fixtures) are simply absent — and the failure looks like a broken branch
  rather than a missing file. The skill now carries an on-demand procedure:
  resolve the main work tree from `git worktree list --porcelain`, verify the
  path exists there and is untracked (a tracked-but-missing path is a checkout
  problem that copying would mask), refuse to overwrite, then `cp -p` into the
  same relative path and report the copy. Invariants: copy rather than symlink
  (a symlink leaks a worktree's writes into the main tree and every other
  worktree, defeating the isolation); config/fixture files only — reinstall
  dependency trees and rebuild outputs instead; never bulk-copy everything
  gitignored; copied secrets stay untracked; missing in the main work tree too
  is a stop, not a cue to synthesize from a `.example`; and the copies make a
  later `git worktree remove` require `--force`.

## [0.18.0] — 2026-08-28

- **Remove the sibling-worktree fallback from task-pointer resolution (#18).**
  `zyz_task_root` resolves the active task ONLY via the base dir's
  `.zyz-worker/current-task` pointer and the exported `$ZYZ_TASK_DIR`; it no
  longer enumerates sibling git worktrees. Real incident: with two concurrent
  execute-task runs in one repo, a session whose own pointer went missing
  silently attached to the OTHER session's task, and the watchdog then drove
  imperative, authoritative-looking staleness alerts (backed by the Stop
  gate) pushing that session's main agent to write "current progress" into a
  status file it did not own. The fallback traded a deterministic failure
  (no pointer → layer silent, which the §1 armed check already surfaces) for
  a probabilistic wrong attach indistinguishable from a correct one; the
  scenario it covered is handled by the absolute-path pointer contract
  (SKILL.md §1 step 4) plus `$ZYZ_TASK_DIR` for orchestrated spawns. The
  watchdog's NOT ARMED message now states that sibling worktrees are
  deliberately not searched.
- **Recognize terminal-phase synonyms (#18 rec 4).** New `zyz_phase_terminal`
  accepts `done`/`delivered`/`completed`/`closed`/`finished`/`cancelled`/
  `abandoned` (prefix match, so annotated forms like `done(delivered)` count);
  `zyz_task_is_done` uses it, and `zyz_phase_active` excludes terminal phases
  before its active match. Previously `*deliver*` classified a task whose
  phase said `delivered` as ACTIVE, so L1/L3/L4 staleness machinery nagged a
  finished task forever — which is exactly what pushed the #18 session to
  delete its pointer and expose the wrong-attach path.
- **Document alert-ownership discipline (#18 rec 5).** SKILL.md
  `## Watchdog Enforcement` and the main-agent prompt now require verifying
  that a watchdog alert's named path belongs to THIS session's task before
  writing into it; a mismatch is reported to the user, never written through.

- Fix an intermittent false FAIL in `scripts/test-rename-and-conventions.sh`
  T4 Pattern B. The check piped ~28KB of bullet lines into `grep -q` under
  `set -o pipefail`: `-q` exits at the first match (the target bullet sits
  ~4.7KB in) and closes the pipe's read end, so when scheduling left the
  upstream `grep` still writing past the kernel pipe buffer it died of
  SIGPIPE (exit 141) and pipefail turned a real match into a FAIL. The
  downstream grep now drains all input (`>/dev/null` instead of `-q`),
  which removes the race categorically while keeping identical match
  semantics. Observed twice as a first-run-only flake on an unchanged,
  passing file; the suite's other `-q` pipelines are not affected (their
  upstream outputs fit the pipe buffer or their exit status is unused).
- Move review history out of the design document into standalone
  review-history files (#15). The design-doc template no longer has a
  `## Review History` section; each design document `<basename>.md` records
  its review history in the sibling file `<basename>.review-history.md`
  (one per design document, created lazily on the first entry — split
  designs get one per part). Review history only matters to the design
  phase's review loop and human approval; for the implementation phase it
  is noise, so implementation-agent / test-agent dispatches send the
  final-state design document(s) only and never include review-history
  files, which are also excluded from the status file
  `## Metadata > Design Document` list. The status file's
  `## Design Review > Rejected Suggestions` record is unchanged. New
  SKILL.md `## Review History Files` section defines the convention;
  main-agent.md's design/implementation workflows and the plugin's own
  design doc are updated to match, and "discovered during implementation"
  entries now update the design's `## Testing Plan` to its new final state
  while the history entry goes to the review-history file.

- Detect terminal-but-unharvested subagent roles as a mitigation for dropped
  subagent-completion notifications. When a role reaches a terminal state
  (clean DONE or adjudicated FINALIZED) but the main agent stays idle since it
  completed — the symptom of a completion notification that never arrived, with
  the result already on disk — the watchdog layers now flag it instead of
  silently skipping every terminal instance. **L4 stop-gate (`stop-gate-main.sh`,
  primary):** synchronously blocks the idle attempt during an active phase,
  names the completed role and where its result lives, and instructs the main
  agent to read and record it before idling; the block is satisfiable and
  self-clearing (any tool call or status write clears it), honors
  `stop_hook_active`, and shares the existing `runtime/nag/stopgate.last`
  cooldown. **L3 watchdog (`monitors/watchdog.sh`, backup):** the instance loop
  no longer blindly skips terminal instances; a new `unharvested` scan emits one
  rate-limited wake line (own `runtime/nag/watchdog-unharvested-<key>.last`
  cooldown) for the case L4 cannot catch — the role going terminal after the
  main agent already idled. The predicate (`terminal` AND
  `main_heartbeat_epoch <= terminal_epoch` AND `status.md` mtime
  `<= terminal_epoch`) `isinstance(int)`-guards every epoch so a missing value
  skips the instance rather than throwing and aborting the shared loop. Adds a
  read-only, additive `terminal_epoch` field to the fixed-pack observer
  (`runtime_state.py hook-observe`), surfaced on all three terminal paths. This
  is a **mitigation**, not a root-cause fix of the harness notification-delivery
  layer (out of a plugin hook's reach); L4 is primary because it does not ride
  the completion channel that drops events. **Linux-only:** like the dead-role
  scan, the detection is inert on macOS where the observer returns
  `genesis-capability-unavailable`.
- Probe update errors now distinguish malformed challenge syntax
  (`invalid-probe-id`, exit 2) from a syntactically valid but non-current
  challenge (`probe-mismatch`, exit 4), giving callers a stable
  machine-readable validation boundary.
- Resolve standalone execute-task issues #7–#10 with hash-keyed role identity,
  distinct logical DONE/FINALIZED audit state in fixed packs, explicit reconnect
  challenge/ACK, bounded multi-lane `Waiting On`, incremental-output contracts,
  and content-sensitive no-output observation. **Linux-only:** the fixed-pack
  layer requires `statx(STATX_MNT_ID)` mount identity; on macOS it fails closed
  as `genesis-capability-unavailable`, all hooks stay fail-open, and L3/L4
  dead-role detection is disabled (see hooks/README.md `## Degraded
  environments`).
- Add the supported `agent-runtime-state.sh` interface, persistent advisory-lock
  carriers, fixed-slot transition journals, terminal-first hook/watchdog
  consumers, the bounded public `gc-step`, validated runtime bounds, and a
  15-second SubagentStart budget (host timeout raised to 20 s for margin).
- Read Claude Code's `tool_use_id` (falling back to Codex's
  `tool_call_id`/`call_id`) so the fixed-table INFLIGHT feature works on both
  runtimes, add a dispatch grace period before non-armed/stale role instances
  can block the main-agent stop gate or page the watchdog, and align the
  PostToolUse heartbeat timeout with PreToolUse.

## [0.17.0] — 2026-08-10

### Added — full Codex runtime compatibility

- **Dual-runtime worker lifecycle.** New `scripts/orch-agent-runtime.sh` detects Claude Code or Codex, renders runtime-specific launch/resume commands, and discovers Codex sessions from rollout metadata. Spawn, reuse, and check helpers now persist generic runtime/PID/session fields while retaining the legacy Claude aliases for backward compatibility.
- **Real Codex orchestration.** Codex workers can launch in tmux, pass the directory trust prompt, bind their session and transcript, resume after interruption, reuse existing worker containers, and receive an absolute `execute-task` Skill fallback when slash commands are unavailable.
- **Codex-aware MCP isolation.** Interactive Codex does not accept Claude's MCP flags or `codex exec --ignore-user-config`; the worker helper now snapshots enabled Codex MCP servers and emits per-server `enabled=false` overrides for the default isolated mode, failing closed if that snapshot cannot be obtained.
- **Codex hook and watchdog support.** Hook commands resolve `CODEX_PLUGIN_ROOT`, orchestrated `ZYZ_PLUGIN_ROOT`, or legacy `CLAUDE_PLUGIN_ROOT`; payload parsing accepts Codex tool fields; synchronous heartbeat and detached SessionStart watchdog paths cover the Codex host's current lack of Claude-style async monitor wake-ups.
- **Codex adaptation test suite.** `scripts/test-codex-adaptation.sh` covers runtime selection, command rendering, MCP policy, session/transcript binding, recovery output, plugin-root resolution, and an opt-in real Codex/tmux/hook smoke test.
- **Documentation and templates.** Runtime selection, generic dispatch fields, recovery behavior, Codex limitations, worker startup, and cleanup guidance now describe both Claude Code and Codex.

### Fixed — issue #6: `git checkout` on a shared worktree destroyed another agent's uncommitted work

Real incident (2026-08-06): several subagents shared one worktree; an audit agent reverted its throwaway mutation with `git checkout <file>` — which resets to HEAD — and deleted another agent's uncommitted work in that file (~5000 chars of security-guard code plus supporting edits). The damage class is uniquely nasty: never-committed content is in NO git recovery mechanism (no reflog, no stash, no `fsck --lost-found`), and `go build` stayed green because the loss sat behind a runtime type-assertion seam — had that seam been written "skip if absent", the accident would have become a silent security bypass. Recovery succeeded only by replaying the author agent's transcript (`tool_use` inputs hold everything ever written, verbatim).

- **New L6 hook `hooks/scripts/checkout-guard.sh`** (PreToolUse on `^Bash$`, sync): denies `git checkout` / `git restore` whose target currently has uncommitted modifications (`git status --porcelain` decides — clean files, branch names, `-b`, and untracked paths all pass), and the state-moving `git stash` forms (bare/push/save/pop/apply/drop/clear; `list`/`show` pass). The deny reason carries the safe recipe. Same policies as every other layer: applies only when a task pointer resolves (general sessions keep full git freedom), fails open on malformed input / missing parser / non-repo cwd, argument scanning stops at the first shell metacharacter (a following command's words are never misread as targets), and `ZYZ_CHECKOUT_GUARD_DISABLE=1` disables just this guard — parsing shell with shell is heuristic, so the escape hatch is mandatory.
- **Mutation-restore discipline rewritten** in implementation-agent and review-agent (both mirrors), SKILL Role Boundaries, and the review-report template: restore from a **backup copy taken before mutating** (`cp` → `mv` → per-file `cmp`), never via git revert commands. The verification criterion changed too — the old wording said restore until "`git status` clean", which on a shared worktree is a goal that INVITES a checkout, because other agents' legitimate in-flight edits mean status is never clean. "Byte-identical" now explicitly means identical to your own pre-mutation copy, not to HEAD.
- **Both Version Control prohibition lists** extended: `git checkout <file>` / `git restore <file>` on a shared working tree are destructive in the same class as `git stash push/pop`; alternatives spelled out (`git show HEAD:<file>` for read-only, own-diff `git apply -R` for set-asides).
- **Transcript recovery documented** (`SKILL.md ## Resuming An Existing Task`): everything an agent ever wrote is recorded verbatim in its transcript jsonl (`Write.input.content`, `Edit.input.new_string`); recovery = identify the author agent, extract its edits for the lost file, replay in original order — never rebuild from memory, because a subtly-wrong rebuild of guard/adjudication/redaction code is a silent bypass, worse than the visible absence. This is the path that recovered the incident's lost function verbatim.
- **Isolation guidance** in §3.0.3: a lane that temporarily modifies production files (mutation testing, refactor probes) gets its own worktree (`isolation: worktree`) or runs while no other lane has uncommitted work in the files it will touch — its revert step is the single most dangerous write on a shared tree.
- **T12 group** in `scripts/test-watchdog-hooks.sh` (suite now 117): the accident's exact command shape plus five deny variants, seven ordinary-git allow cases, compound-command target isolation, the no-pointer no-op, the per-guard disable, and fail-open. Mutation-tested: removing the porcelain check reds the checkout denials; removing the stash branch reds the stash denials.

## [0.16.1] — 2026-08-03

### Fixed
- **The unarmed-watchdog warning cried wolf in ordinary sessions.** 0.16.0 paired two changes that interact badly: the monitor is armed `when: always` (so it starts in *every* session), and it reported any pointer-resolution miss. In a session that simply is not running `execute-task` — the overwhelming majority — that produced `NOT ARMED: … dead subagents will NOT be reported and the idle gate will NOT hold`, which is alarming, useless, and self-defeating: a warning that fires in normal use trains people to ignore the one that matters. Observed immediately after installing 0.16.0 in this repo, which has 14 finished task directories and no active pointer — the correct state for a repo not running a task.
  The report is now gated on a task **plausibly existing but unresolvable**: some `.zyz-worker/tasks/<id>/` present with a `status.md` whose phase is not `done`. A repo with no task directories, or one whose task directories are all finished, stays silent; the genuine issue-#5 case (live task dir, pointer unreachable) still reports exactly once. Three T11 cases pin all of it, mutation-verified — removing the gate turns the two false-alarm cases red.
- **`grep -c … || echo 0` produced `"0\n0"`** in two test helpers. `grep -c` prints `0` *and* exits 1 on no match, so the fallback appended a second zero and the following `-eq` died with "integer expression expected" — the assertion broke precisely in the case it existed to detect. Found because it made three of the new T11 cases fail while reporting the value they wanted; fixed in `test-watchdog-hooks.sh` and in `test-orchestration-helpers.sh` T12 (latent there: one match today, but it would have failed the same way had the call ever disappeared).
- **Version bump 0.16.0 → 0.16.1** across the three manifests (codex build suffix regenerated); `EXPECTED_VERSION` aligned in the three test scripts.

## [0.16.0] — 2026-08-03

Four field-reported issues (#2–#5), each reproduced by execution before being fixed and pinned by a mutation-tested guard after. Two of them turned out to be the same defect seen from different ends: the watchdog layer was silently inert whenever a task ran in a git worktree (#5), which is also why nobody noticed the status file going a day stale (#4).

### Fixed — issue #5: the watchdog was silently inert whenever the pointer lived in a git worktree

`zyz_task_root` resolved `.zyz-worker/current-task` under exactly one base — the hook payload's `cwd`. The plugin's own `git-worktree` skill places worktrees *outside* the main checkout and deliberately does not `cd` into them, so a task run in such a worktree put its pointer where the session cwd could not see it, and **all six layers returned empty and no-op'd**: no `runtime/` was ever created, two dead subagents went unreported, and the idle gate let the main agent stop. Reproduced against the shipped scripts: the same payload creates `runtime/agents/main.heartbeat` with `cwd` set to the worktree and creates nothing with `cwd` set to the main checkout. Also confirmed as the mechanism behind issue #4's worst symptom — in #4's exact scenario (status.md a day stale) L1 stays silent and L4 allows idle.

- **Bounded fallback in `zyz_task_root`**, in order: the existing single-base hit (hot path, no fork, byte-identical on a hit) → `$ZYZ_TASK_DIR` if exported → sibling git worktrees of the same repo. Reducing a linked worktree to its main checkout already worked; main checkout → sibling worktree was the unreachable direction, and enumerating it is the only route that actually reaches the pointer. Deliberately **not** an unbounded upward walk: the default layout's ancestor chain climbs through `$HOME/.zyz-worker`, where one stray pointer would capture every session under `$HOME`.
- **Ambiguity handled explicitly.** Candidates are ordered newest-first by `status.md` mtime, because `git worktree list` is path-ordered and first-hit-wins would otherwise pick by alphabetical accident; tasks whose phase is `done` are skipped, since pointers are never deleted anywhere in this plugin and stale ones accumulate with worktree count. Residual risk stated rather than hidden: two genuinely concurrent runs in one repo can still attach to the wrong task, so every fallback hit appends to `<task-dir>/runtime/task-root-fallback.log` — a wrong reminder is more confusing than silence, so it must at least be diagnosable.
- **"Unarmed" is now visible.** This is the deeper defect: an inert layer and a healthy quiet one were externally identical, which is how a whole task ran unprotected. `monitors/watchdog.sh` now reports a resolution miss **once** (not per tick), naming the base it probed and stating plainly that dead subagents will not be reported and the idle gate will not hold. The report is gated on a task plausibly EXISTING (some unfinished `.zyz-worker/tasks/<id>/` present) but unresolvable — because this monitor is armed `when: always` and therefore starts in every session, the ungated version fired in ordinary sessions that never ran `execute-task` (observed immediately after install). A warning that cries wolf in normal use is worse than none: it trains people to ignore the one that matters. `SKILL.md` §1 step 4 and the main-agent prompt now require confirming `<task-dir>/runtime/agents/main.heartbeat` exists after a few tool calls (the heartbeat is async, so not on the first), and saying so if it does not.
- **Docs de-ambiguated.** "at the project root" is gone from both loaded documents: the pointer belongs under the **session cwd** (what hooks receive as `cwd`), and if the task dir is not under it, the pointer's contents **must** be an absolute path — a bare id resolves against the pointer's own directory and cannot cross trees. `git rev-parse --show-toplevel` returns the *worktree* root inside a linked worktree, which is exactly why the phrase misled. `skills/git-worktree/SKILL.md` now states that creating a worktree does not move the watchdog's anchor.
- **T10/T11 guards** in `scripts/test-watchdog-hooks.sh` (suite 90 → 96). Every prior fixture wrote the pointer into the same directory it then passed as `cwd`, so the split-base case had no coverage and the missing-pointer no-op was pinned as the only outcome. T10 pins cross-worktree resolution, newest-wins over alphabetical order, `done`-skipping, and that a total miss still yields empty + rc 0 (fail-open preserved). T11 pins the once-only unarmed report. Mutation-tested: removing the fallback or the `done`-skip turns them red.
- **Rejected one claim from the report after testing it.** Issue #5's "another small problem" said `monitors.json` interpolating an unset `${CLAUDE_PROJECT_DIR}` yields an empty `$1` that defeats `${1:-default}`. It does not — `${1:-word}` substitutes when `$1` is unset **or** empty (`${1-word}` is the form that distinguishes them), verified across all nine arg/env combinations. I had briefly "confirmed" this from a misread of my own test output; the mutation test caught it, and the original one-liner is kept with a comment recording why it must not be "fixed". The T11 case now guards the genuinely-broken `${1-word}` variant instead.

### Fixed — issue #4: stale `status.md` made a resumed session misjudge where the work stopped

A 9-SubTask task's main status file froze at "ST1 coded" while all nine SubTasks were implemented, tested, reviewed and pushed; individual `subtasks/*.md` advanced further and one contradicted itself. A resuming session read the main file first, concluded the work was still around ST1–ST5, and had to reconstruct the real interruption point from `git log` plus transcripts — after which every status conclusion needed re-verification. Worse, a still-running subagent left no trace in any status file, so recovery nearly re-dispatched it into the same workspace as the live one (two agents writing the same files); only a process-list and mtime check prevented it.

- **Transitions write through.** §3.B step 6 now states that flipping any `Coded`/`Tested`/`Reviewed` bit is not complete until the **main** status file is written — not batched, not reconciled later, not only in the SubTask file. Mirrored in the main-agent prompt. Two-layer drift (main frozen, SubTask files advancing) is the specific shape that makes recovery expensive, because the main file is what a resuming session reads first and everything downstream inherits its error.
- **New `## Resuming An Existing Task`** section: cross-check the status file against sources that advance by themselves before trusting it — `git log`/`git status` (commits are written by the work itself and cannot lag), `subtasks/*.md` versus the main file, and `runtime/agents/*.heartbeat` to separate "died and lost its work" from "still running". Conflicts are reconciled into the main file immediately, with reconstructed parts marked as such.
- **The live-agent registry the issue asked for already exists** — it is the L0 heartbeat layer, which was inert for exactly the reason issue #5 documents. With #5 fixed, `.start` without `.done` plus an advancing heartbeat *is* the "this role is alive, do not re-dispatch" signal; an absent `runtime/` now means "the watchdog never armed", which the layer itself reports rather than leaving to inference.
- **New `## Status Freshness`** block in the status template (`Updated At`, `Reconciled From Code At`, `Fields Reconstructed From Code`, `Known Divergences`) plus pre-delivery items 18b/18c, so a later reader can tell which entries were recorded live by the actor that did the work and which were rebuilt afterwards.

### Added — issue #2: worker MCP isolation (`ZYZ_WORKER_MCP`)

Every worker is a full `claude` process, and stdio MCP servers spawn per process — they cannot be shared. Workers inheriting the host's global `mcpServers` therefore re-pay the host's entire MCP memory baseline each (measured: ~745 MB/worker for one lark-mcp, ~695 MB of it private per smaps_rollup; 11 workers ≈ 8 GB), for tools most execute-task work never touches. This is the memory-axis sibling of the `ZYZ_GO_BUILD_P` disk-I/O fix: `workers × MCP baseline`, and the knob is the inheritance policy, not the worker count.

- **`scripts/orch-worker-mcp-args.sh`** — prints the MCP-isolation CLI args from `ZYZ_WORKER_MCP`: `none` (default) → `--strict-mcp-config` (worker gets ZERO MCP servers); `inherit` → nothing (legacy full inheritance); `<config-path>` → `--strict-mcp-config --mcp-config '<path>'` (exactly that JSON's servers — the shared-server hook). An invalid path fails CLOSED to `none` with a stderr warning, never silently open to full inheritance; `~/` expands; single quotes rejected (launch-command quoting).
- **`dispatch.md` gains `worker-mcp-args:`** (Phase-1, may be legitimately empty for `inherit`): spawn and reuse snapshot the policy once at container build time; the L2 driver appends it verbatim to the `claude` launch command; `orch-check-worker.sh`'s Phase-2 rewrite preserves it and embeds it in the generated `--resume` recovery command — so a crash-resumed worker keeps the same MCP policy instead of silently re-inheriting everything.
- **⚠️ Behavior change (breaking):** workers no longer inherit the host's MCP servers by default. A task that needs the host's MCP tools must set `ZYZ_WORKER_MCP=inherit` (or point at a scoped config). README documents the shared-server security boundary from the issue thread: no TCP even on 127.0.0.1 (any local user can drive the credential-bearing server), sockets under `$XDG_RUNTIME_DIR`-style 0700 dirs, credentials via `--config <0600>`/env — never argv (`ps`-visible) — and prefer installed binaries over `npx` wrappers (~47 MB/worker of wrapper processes).
- Orchestrator prompt's resource caveat is now quantified (peak ≈ workers × (claude ~500MB + Σ stdio-MCP baselines)) and names the right knob. T8 gains two assertions: `worker-mcp-args` key present, and default policy renders `--strict-mcp-config` (spawn env sanitized so the assertion tests the default, not the caller's env). `test-e2e-layered.sh`'s launch command consumes the snapshot like the real driver.

### Changed — issue #3: 21 process gaps from the 20-agent / 9-SubTask field run

The core insight from the field report: **"ran" ≠ "tested"** — every silent no-op assertion found that round was found by mutation injection, none by careful reading; and a failing verification TOOL produces output that looks exactly like a failing SYSTEM. All 21 items applied across both prompt mirrors (`agents/` + `subagents/`, byte-equal), the SKILL, the main-agent prompt, and the four templates:

- **P0-1 `Tested: true` redefined**: tests pass AND every claimed-covered mechanism has a recorded killed mutation. test-agent authors a `## Mutation Manifest` (mechanism → mutation → cases expected red); implementation-agent executes it (KILLED/SURVIVED per entry, tree restored byte-identical) — the "test-agent must not run tests" boundary is preserved by splitting authorship from execution. Templates carry `Mutations:` / `Mutation evidence:` fields.
- **P0-2 Mutation reachability** (new implementation-agent section): positive evidence the mutation reached the code before interpreting red/green; full process-group kills + port-vacancy polls + no-stale-binary rule for restarts; non-production write paths pair with production invalidation (advance seq / emit event / clear key).
- **P0-3 Coordinates + leases**: every green carries command / test DB / port group / process-vs-source freshness (a green without coordinates is not delivery evidence — judged `changes-requested` on that ground alone); new SKILL §3.0.3 mandates per-lane port-group + test-DB leases at ≥2 lanes, recorded in the new status `## Parallel Resource Leases` table with a single generated-artifacts owner per batch.
- **P0-4 Verdict hygiene** (new implementation-agent section, five mechanical rules): pipeline exit codes from the judged segment (no `cmd | head && echo OK`); no grep-as-success-proof, totals cross-checked; executed-count vs baseline on every `ran:`; read the matched lines behind any grep count; no shell-builtin variable names, failure messages keep raw values.
- **P0-5 Third attribution bucket**: failure attribution ordered change-surface → tooling → concurrent-edit/environment → real regression, replacing the two-bucket forced choice in all three places it appeared; "a rerun proves flaky, only the change surface proves not-mine"; mtime observation or owner confirmation before blaming another lane; stop-loss after the second failed hypothesis-fix.
- **P0-6 Assertion shape rules** (new test-agent section): expected values from independent recorded anchors, never the code-under-test's own rule (the one defect class where more diligence makes assertions worse); templated ids equality-only; every classification arm violable; bidirectional guards.
- **P1-7 review-agent gains Bash**: may rerun checks read-only and inject throwaway complementary-surface mutations, must restore byte-identical and verify, must not leave edits; measured basis — read-only review's hit rate on no-op assertions was zero, and the author is otherwise the sole judge of their own verdicts.
- **P1-8 No-op assertion checklist** (eight forms, each answered with file:line evidence, batching banned) in review-agent + review-report template.
- **P1-9 "What these tests do NOT prove"** required in test-agent output and test-file headers (silence is an overclaim); new `## Which Layer Can Actually Catch This` decision rule — distinguishability of end states at this layer's observation granularity, harden observation before declaring untestable, executable guards at structurally untestable spots, explicit handover naming the capable layer.
- **P1-10 Finding ledger**: status `## Implementation Review` becomes a per-finding table (verdict+evidence / dispatched-to / landed / verified-by); adjudicated→dispatched→landed are three distinguishable states; accepted-but-undispatched is mechanically detectable; re-review requests scan the ledger first.
- **P1-11 Adjudication discipline** (new main-agent section + hard limit): code-level rulings need file:line + predicate; confirming the symptom ≠ confirming the intent ("would this change turn an existing assertion red?"); no handed-down code/SQL forms — state properties, let executing roles choose forms; downstream rejections verified like review findings.
- **P1-12 Freeze before review**: new §3.B step 3.5 — workspace-frozen declaration recorded (with file set) before review dispatch; review-agent records and re-checks mtimes/hashes, mid-review change voids the review; `Frozen At:` in the scoreboard.
- **P1-13 Continuation, not redo**: `## Long-Running Work` rewritten as inventory → resume-point → debris-cleanup (interrupted runs are assumed dirty; stable reproduction = dirty data, not race); `## Restart And Recovery Notes` becomes an append-only event list (the single-slot form could not hold one real run's six timeouts).
- **P1-14 Rule-wide sweeps**: once a finding establishes a rule, sweep all same-shaped sites and return the enumerated list (enumerate the outbound surface, don't recall handled instances); 3+ recurrences → make the wrong form inexpressible via signature change, designed together with its test-driving path.
- **P1-15 `## Weakest Link`** required in implementation-agent, test-agent outputs and the final report — the author's private knowledge of the argument's thinnest point becomes a mandatory field; review treats self-reported tool failures as credibility-raising.
- **P1-16 Shared-file hotspots ≠ serialization**: §3.0.2 no longer serializes on "two items write the same file" — assembly points get declared hotspots with per-lane insertion regions; §3.B step 8 gains the smallest-compilable-unit commit exception (a non-compiling intermediate commit breaks bisect/CI and costs more than deviating from one-SubTask-one-commit); `Committed:` accepts `shared:<sha> (STx+STy)`.
- **P2-17 Statistical tolerances**: criterion derived before results, actual deviation reported (not just "within tolerance" — the format that hides how close to the edge it ran), one reverse injection; the three prove different things and none implies another.
- **P2-18 Bucketing fixtures**: symmetric splits banned where wrong values can land right by chance (50/50 is everyone's default and the lowest-discrimination point); one ~1% narrow bucket; derivation written into the fixture comment so a later "simplification" can't silently destroy discriminating power.
- **P2-19 Guard lifecycle**: record the first real interception in the guard's comment (an interception-less guard reads as noise and gets deleted with its discipline); diagnostic failure messages survive the fix as forward pointers; source-scan guards hold "X says", not "nothing else says Y".
- **P2-20 `git stash push/pop` banned on shared working trees** (both prohibition lists + implementation-agent): another agent's stash may exist, and a conflicted `go.mod` still BUILDS while `go test` breaks at module parse — reading as "their code is broken"; replacement `git diff > patch` + `git apply -R`; bisection requires a clean-environment precondition.
- **P2-21 Test categories derive from the design's Testing Plan**: the fixed unit/e2e/regression/pressure enumeration becomes example slots in all five places it was hardcoded; user-named categories get their own registration line plus a structural-ceiling note — a fixed enum let a user's explicitly-not-skippable category pass the delivery gate silently.
- **Pre-Delivery Checklist** (the field run's live checklist, generalized): 26 items across test effectiveness / verdict hygiene / environment & coordinates / attribution & collaboration / scope & self-disclosure, answered item-by-item with evidence as a delivery gate (§4 step 4).

### Changed
- **Version bump 0.15.0 → 0.16.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.16.0 in `scripts/test-release-0-5-0.sh`, `scripts/test-clean-tmp-skill.sh`, and `scripts/test-watchdog-hooks.sh`.

### Upgrade notes
- **Breaking (issue #2):** workers no longer inherit the host's MCP servers. Set `ZYZ_WORKER_MCP=inherit` for tasks that need the host's MCP tools, or point it at a scoped config file. Default `none` gives each worker zero MCP servers.
- **Behavior change (issue #5):** the pointer belongs under the **session cwd**, not "the project root" — inside a linked worktree those differ. A task whose task dir is not under the session cwd must write an **absolute** path into the pointer. The new sibling-worktree fallback covers the common case, but it is a safety net, not a contract: with two concurrent runs in one repo it can attach to the wrong task (every fallback hit is logged to `<task-dir>/runtime/task-root-fallback.log`).
- **New expectation (issues #4/#5):** after a few tool calls, confirm `<task-dir>/runtime/agents/main.heartbeat` exists. Its absence means the watchdog never armed and no conclusion should rest on it; the monitor now says so once per miss instead of staying silent.

## [0.15.0] — 2026-08-03

Consolidation pass over the whole plugin after the rapid 0.5.0 → 0.14.0 run: an audit of prompts, scripts, hooks, and docs for inconsistency, contradiction, and dead weight, plus a single architecture document. Thirteen classes of real defects fixed — every one reproduced by execution before fixing and pinned by a mutation-tested regression guard after.

### Added
- **`docs/architecture.md`** — the plugin's architecture overview: what each skill / subAgent / script / hook is, its responsibility boundary, and the main operating principles (execute-task's four roles and hard boundaries, the six watchdog layers and why each exists, orchestration's three layers with the file-ownership table, the bash helper contracts, crash-recovery reasoning, the test strategy, and the coupling points that must be changed in pairs). Deliberately architecture-level, not exhaustive — per-file detail stays in the in-file contract blocks and the SKILL.md files. Linked from `README.md` and `docs/conventions/project-structure.md`.
- **`test-agent` mirror guard** in `scripts/test-orchestration-helpers.sh` T10. It was the one role pair of four with no `agents/` ↔ `subagents/` body-equality check, so a bullet added on one side could silently drift on the other.
- **`CONSOL` regression group** in `scripts/test-orchestration-helpers.sh` (7 checks; suite now 430) pinning the three highest-consequence fixes below so they cannot silently return: the `approved`-token boundary (`cleanup-approved` / `not-approved` must not clear the gate), heartbeat-threshold env validation (a malformed value must degrade, not exit 1), and worktree-numbering-gap refusal in all three reader helpers. Pure file reads, so the group runs unconditionally. Each guard was mutation-tested — reintroducing the original bug turns it red.
- **T9 group + a tightened T2 monitor assertion** in `scripts/test-watchdog-hooks.sh` (suite now 90) covering the four watchdog fixes plus the L1 single-nag rule. T2 previously grepped the `on-skill-invoke:` substring, so it passed for the broken bare form — it now parses the `when` value and explicitly *fails* a bare skill name, testing the arming rather than the string. T9 pins design-phase quietness (full classification table), the clearable dead-role marker (both the reason text and the deletion), locale-independent CJK length in both `en_US.UTF-8` and `C`, and exactly-one-L1-nag-per-tool-call.
- **T8 group** in `scripts/test-watchdog-hooks.sh` pinning `zyz_get`'s extraction shapes — plain string, nested path, absent key (must be empty), and the boolean the stop gates compare against the literal `"true"`. It is the single field-extraction path every hook depends on and it has two interchangeable backends; the guard was verified against both by disabling the `jq` path and confirming `python3` produces identical output.

### Fixed
- **The L3 background watchdog could never arm under a normal plugin install** (`monitors/monitors.json`). `when: "on-skill-invoke:execute-task"` is compared as an *exact* string against the emitted skill name, and a plugin-loaded skill emits the **qualified** form. Verified two ways: the 2.1.218 binary arms via `a.when === "on-skill-invoke:" + s`, and `~/.claude.json` `skillUsage` holds **both** `zyz-worker:execute-task` (plugin mode) and bare `execute-task` (project mode) — so no single `on-skill-invoke:` literal can cover both, and the shipped bare form armed only in project mode. The layer that `SKILL.md` bills as "the only one that catches API-error deaths" was therefore inert exactly where it matters. Switched to `when: "always"` (also verified supported in the binary: `s.when==="always"` arms at startup), which sidesteps the plugin-name coupling; `watchdog.sh` is itself gated on the `.zyz-worker/current-task` pointer, so arming it always is equivalent in effect and costs one sleeping process. My own earlier check of this layer was invalid — running `watchdog.sh` by hand validates the script's logic, not that Claude Code arms it.
- **The watchdog fired during the design phase, where both prompts promise silence** (`hooks/scripts/lib.sh`). `zyz_phase_active` matched `*review*`, which also matches `design review` / `designreview`. Verified: `Current Phase: Design Review` plus a stale status file made `stop-gate-main.sh` emit a block. The worst consequence is at §2 step 8 — the one gate the workflow mandates *waiting at indefinitely* for human approval — where the gate pushed the agent to act while the prompt said hold. Any phase naming `design` is now excluded first, before the active-phase patterns.
- **A dead role's block could not be cleared by complying with it** (`hooks/scripts/stop-gate-main.sh`, `stop-gate-subagent.sh`). The block reason said "mark it finished in the status file", but this gate reads only the runtime markers and never `status.md`; a `.start` was cleared solely by the `.done` that `SubagentStop` writes — and `SubagentStop` by design does not fire on the API-error death this gate exists to catch. Verified: the agent complied exactly as instructed and the gate re-blocked; only the cooldown or the platform's block cap escaped. Two changes: a clean `SubagentStop` now **deletes** the role's `.start`/`.heartbeat` (which also stops `runtime/` accumulating one marker triple per dispatch, since `agent_id` is fresh per dispatch), and the block reason now names the exact `rm -f` that clears a marker whose role really did finish.
- **L1 nagged the same invariant twice in one turn** (`hooks/scripts/status-freshness.sh`). `status-freshness.sh` and `post-agent-flush.sh` are both sync `PostToolUse` hooks reading the same status-file mtime with independent cooldowns, so on a stale-status Agent return both injected a "persist the status file" instruction into the same turn — verified, two near-identical `additionalContext` blocks. `status-freshness.sh` now defers when `tool_name` is `Agent`: `post-agent-flush.sh` owns that moment (its message names the just-received subagent result and says to persist it *before* dispatching further work, and its threshold is tighter). Every other tool call still gets the freshness reminder, so no coverage is lost — exactly one L1 nag per tool call now.
- **The L5 scope guard denied legitimate dispatches, including work on the guard itself** (`hooks/scripts/lib.sh`). Two independent causes, both verified by execution before fixing. (1) A prompt that *quotes* a capping phrase was read as *issuing* one, so "Add a test asserting that a dispatch saying \"limit to 3 findings\" is denied" and "Implement the L5 scope guard. It must deny prompts like \"only the top 3 findings\"" were both blocked — writing docs, tests, or changelog entries about this guard is routine in this repo, so the guard obstructed its own maintenance. Caps are now matched against a quote-stripped copy (`zyz_scope_strip_quotes`, handling `"`, backticks, and `'`); single quotes only open a span after whitespace or punctuation, so contractions like `don't be exhaustive` cannot pair up and swallow real text, and negation is still evaluated on the full text so a quoted negation keeps its veto. (2) The count-cap patterns accepted `items` as the capped noun and made the noun optional, so ordinary domain requirements matched: "the API should return no more than 3 items per page" and "the retry budget must cap it at 3 attempts". The noun is now required and limited to `findings|issues|problems`, so a cap must name a review deliverable. Known tradeoff, taken deliberately: a prompt that is *entirely* a quoted cap now passes — a dispatch whose whole body is one quoted string is not a plausible instruction. Patch authored by the hooks auditor; verified, mutation-tested, and applied here.
- **T7's fixture harness could pass vacuously** (`scripts/test-watchdog-hooks.sh`). `sg()` interpolated the prompt straight into a JSON string, so any fixture containing a double quote produced invalid JSON — the guard then failed open and the assertion passed for the wrong reason, which is exactly the shape the new quote-skip fixtures need. It now builds the payload with a real JSON encoder (falling back to raw `printf` only without `python3`), and all 23 pre-existing capped fixtures were confirmed to still deny through the escaped path before the new ones were added. T7's legitimate set grew 21 → 28 with the seven cases above; both halves of the fix were mutation-tested (reverting the quote-strip yields 4 false positives, restoring the loose `items` pattern yields 1).
- **The subagent exit gate blocked valid Chinese final reports** (`hooks/scripts/stop-gate-subagent.sh`). `${#var}` counts characters under a UTF-8 locale but bytes under `LC_ALL=C`, so the threshold meant two different things. Verified: a complete 45-character Chinese report scored 45 against the threshold of 80 and was blocked as "too short", though the same string is 135 bytes and the workflow explicitly supports Chinese output. Now measured in bytes (locale-independent), with the 80 threshold calibrated for them — ~80 ASCII characters or ~26 CJK characters, both genuinely too short. Verified across both locales, with short replies still blocked.
- **`cleanup-approved` cleared the `approved` merge gate.** `orch-merge-and-cleanup.sh` bounded its `approved` token with `[^a-zA-Z0-9_]`, a class that omits `-`, so `cleanup-approved` — and `not-approved` — satisfied the gate. Verified end-to-end: an entry whose `## Pending Merge Approval` held only `cleanup-approved` passed the gate (failing later at exit 11 instead of the gate's exit 10), meaning the narrower cleanup token alone could trigger merge + push + the terminal, immutable `state: completed`. `orch-merge.sh` already used the correct `[^a-zA-Z0-9_-]` class for its own `merge` token — the same idiom had simply drifted between the two. Now aligned, with the reason recorded inline so it cannot regress.
- **`orch-check-worker.sh` exited 1 on a malformed threshold env var.** `ZYZ_HEARTBEAT_STALE_SEC`/`ZYZ_HEARTBEAT_WAITING_USER_SEC` were read unvalidated (while the per-task `heartbeat-stale-sec` frontmatter override *was* validated) and reached an arithmetic context; under `set -u` bash treats a non-numeric value as a variable name and aborts with "unbound variable". Verified `ZYZ_HEARTBEAT_STALE_SEC=abc` → exit 1, a code this helper's contract does not define and the orchestrator has no branch for. Since L1 polls every active worker through this helper on every tick, one typo'd env var silently blinded the whole poll loop. Both knobs now fall back to their defaults.
- **`orch-cleanup-worker.sh --force` exited 128 silently where the contract promises 8.** The `git rev-parse --git-common-dir` result was assigned bare, so under `set -e` a failing call killed the script before the `[ -z "$main_repo" ]` check could report exit 8 — making that branch unreachable for the case it was written for. Verified: a worktree path that exists but is not a git work tree produced rc=128 with no stdout and no stderr at all. The `git status` probe two lines above was already `if`-guarded; the assignment now matches it and reports exit 8 with a diagnostic. (`orch-merge-and-cleanup.sh` has the same shape but is genuinely masked by an earlier git-status check that exits 11 — verified, left unchanged.)
- **Both merge helpers stranded the operator's checkout.** `git checkout "$BASE_BRANCH"` runs in the *main* repo with no save or restore, and the switch was absent from both scripts' documented side effects. Verified: a repo sitting on `my-feature-wip` was silently left on `main` after a successful merge. Both scripts now record each main checkout's pre-merge ref and restore it from an `EXIT` trap, so every exit path (success, conflict 12, push-failure 13) leaves the operator where they were; restore failures are non-fatal and never mask the real exit code.
- **Silent repo-set truncation on a worktree-numbering gap.** `orch-spawn-worker.sh` probes for numbering holes and rejects them with exit 5, but all four *readers* (`orch-merge.sh`, `orch-merge-and-cleanup.sh`, `orch-cleanup-worker.sh`, `orch-reuse-worker.sh`) simply broke at the first empty `worktree-N`. Verified on a 3-repo fixture whose `dispatch.md` had `worktree-3` but no `worktree-2`: `orch-merge.sh` merged only repo 1, skipped repo 3, and still printed `merge-status=success`. Each reader now runs the same gap probe as spawn and fails loudly — a reader must not be more permissive than the writer.
- **Single quotes in worktree/branch values broke out of every `tmux send-keys` payload.** Spawn validated worktree paths for `:` (the `ZYZ_WORKTREES` separator) but not for `'`, while every send-keys payload wraps these values in single quotes. `orch-build-env.sh` already rejects `'` in `ZYZ_GO_TMPFS_DIR` for exactly this reason; spawn now matches that guard for both worktree paths and branch names (exit 5 with a precise diagnostic). The values are user-written in their own master entry, so this is robustness rather than a privilege boundary.
- **`scripts/pack.sh`: false dirty-tree warning and an unreachable exit 4.** The warning claimed the zip "will reflect the git index, not HEAD"; verified false — `git ls-files` chooses *which* paths ship but `zip` reads each from the working tree, so an unstaged edit silently ships in a release archive. Wording corrected. Separately, the documented exit 4 (unparseable version) was unreachable: the inner `grep` fails on a version-less manifest and `pipefail` aborted the assignment first (verified rc=1, no message). Now exits 4 with its diagnostic as documented.
- **`fm_field` divergence across the orchestration helpers.** The frontmatter reader is copy-pasted into six scripts and the copies had drifted: `orch-spawn-worker.sh`, `orch-merge.sh`, `orch-merge-and-cleanup.sh`, and `orch-cleanup-worker.sh` lacked the absent/unreadable-file guard that `orch-check-worker.sh` and `orch-reuse-worker.sh` had. Without it `awk` exits non-zero on a missing file and, under `set -euo pipefail`, kills the caller instead of yielding an empty field. Not reachable today (every such call site is `[ -f ]`-guarded and `MASTER_ENTRY` is validated earlier with exit 4), so this was a latent trap rather than a live bug; all six copies are now behaviorally identical. `docs/architecture.md` records the copy-paste surface so the copies stay in lockstep.
- **Flaky T5 stop-gate fixture** in `scripts/test-watchdog-hooks.sh` (pre-existing, surfaced while verifying the L1 fix). Two cases assert on the gate's *dead-role* branch, but their fixture backdates `status.md` by exactly 20 minutes while the *status-stale* branch fires at age strictly greater than 1200 s — so whether the status-stale text also appeared depended on how many seconds the suite had been running. The result was green in isolation and red inside a longer back-to-back sweep (observed both ways). Those two cases now pin `ZYZ_STOP_STATUS_STALE_SEC` out of range so they test the role branch alone; the status-stale branch keeps its own dedicated assertions.
- **Stale TR-neg exit-precedence fixture** in `scripts/test-orchestration-helpers.sh` (the suite's one pre-existing failure). The case asserts that the tmux-dependent old-session-alive check is only reachable after the `tmux`/`git` dependency gate, but its fixture never created the old task's `dispatch.md` — so the newer (and correctly-ordered) tmux-free guard requiring the old pane coordinates fired first and returned 5 where the case expected 3. The fixture now supplies an old `dispatch.md` with `shell-pid` / `tmux-pane-id`, making it well-formed against *every* tmux-free precondition. `orch-reuse-worker.sh` was correct and is unchanged.

### Changed
- **Watchdog layer audited; no defects found, findings recorded as notes.** The six enforcement layers were checked for hook-contract correctness, deadlock, cost, overlap, reachability, and threshold drift — every claim verified by execution, not by reading. Results: the emitted JSON matches the platform shape for each event type (`PostToolUse`/`PreToolUse` hooks emit `hookSpecificOutput` with the matching `hookEventName`; the two Stop-family gates emit a bare `{decision:"block",reason}` with no event name, as that family expects); all seven hook scripts fail open with exit 0 on malformed JSON, empty stdin, and a missing `current-task` pointer; all three escape hatches work (`ZYZ_HOOKS_DISABLE`, `ZYZ_SCOPE_GUARD_DISABLE`, and `stop_hook_active`); both stop gates are bounded (each checks `stop_hook_active`, so at most one block per stop — no livelock); every documented `ZYZ_*` threshold matches its hardcoded default exactly (no drift); the L3 background monitor is reachable and was confirmed firing against a simulated stale role; and the apparent overlap between layers is a deliberate escalation ladder (status freshness 600 s advisory → 1200 s stop gate → 1800 s monitor wake; role liveness 900 s → 1200 s) rather than redundancy. `hooks/README.md` and `docs/architecture.md` now state these properties so they are not re-derived each time.
- **`zyz_get` caching documented as a dead end.** The per-tool-call hook cost comes from one `jq` process per field read. Memoizing `zyz_get` in a shell variable was implemented and then reverted: every call site is `x="$(zyz_get foo)"`, and command substitution runs in a subshell, so the cache dies before the next call — A/B measurement showed noise, not gain. `lib.sh`, `hooks/README.md`, and the architecture doc now record why, and point at the approach that would work (single-pass extraction inside the hook script). `heartbeat.sh` is already registered `async`, so only the sync `status-freshness.sh` sits in the agent's loop.
- **Doc inventory brought back in line with the shipped tree.** `README.md`'s repository-structure tree was missing six shipped files (both `orch-driver-agent.md` copies, `hooks/scripts/dispatch-scope-guard.sh`, `scripts/orch-build-env.sh`, `scripts/pack.sh`, and the `monitor.md` / `dispatch.md` templates); the L2 driver subagent — a whole architectural layer — appeared in no top-level doc. `subagents/README.md` listed three roles when four exist and now states the mirror contract. `skills/README.md` omitted the `prompts/` directory used by two of the four skills and now lists the current skill set. `docs/conventions/project-structure.md` now names the four `agents/` roles, `pack.sh`, and the L5 scope guard in its hooks description.
- **Helper list unified across the four docs that enumerate it.** `CLAUDE.md`, `commands/orchestrate-tasks.md`, and `docs/conventions/project-structure.md` each omitted a different subset (most often `orch-merge.sh`, which every doc but `README.md` dropped despite the gate step routing the `merge` token to it). All four now list the same nine helpers, and the command doc distinguishes `orch-merge.sh` (merge + push only) from `orch-merge-and-cleanup.sh` (legacy atomic path).
- **Approval-token documentation completed** in `CLAUDE.md` and `commands/orchestrate-tasks.md`. Both described only the legacy `approved` token, omitting `confirmed` / `merge` / `cleanup-approved` / `rejected:` and the invariant that the orchestrator mirrors the worker's `phase=done` into `state: completed` rather than writing it directly.
- **`status.md` filename documented as load-bearing.** All four watchdog consumers (`status-freshness.sh`, `post-agent-flush.sh`, `stop-gate-main.sh`, `monitors/watchdog.sh`) resolve the overall status file as `<task-dir>/status.md`, but no prompt said so — a differently-named status file left the L1/L3/L4 freshness layers silently inert. `skills/execute-task/SKILL.md` §1 step 3 and the watchdog-obligations list now state it.
- **L2 driver `intent` enum corrected in both mirrors.** `agents/orch-driver-agent.md` and `subagents/orch-driver-agent.md` opened by saying L1 dispatches the driver for two intents (`first-dispatch`, `intervene`) while the same files document four sections and the `## Inputs` line lists all four; the sentence now names all four dispatch reasons.
- **`worker-status-malformed=true` is now documented.** `orch-check-worker.sh` has been emitting it (worker-status.md present but fence-less, so every parsed field reads empty) while neither the script's contract, the SKILL, nor the orchestrator prompt mentioned it — a consumer-less signal. All three now describe it, including the trap it guards: all-empty fields are not the same as a genuinely idle worker, so `state:` must not be projected from them. The helper's contract also now documents that `heartbeat-status=missing` covers an unreadable mtime as well as an absent file, and that its threshold env vars are validated.
- **Missing `python3` no longer degrades invisibly** in `orch-check-worker.sh`. Session-id discovery is a `python3` one-liner whose absence is swallowed (`2>/dev/null || true`) — a deliberate fail-open, but it leaves `dispatch-bound` false forever and removes the `claude --resume` recovery path with no clue why. It now warns on stderr while keeping stdout a clean `key=value` report and the exit code 0.
- **`orch-reuse-worker.sh` exit-code contract corrected.** Its header listed "(worktree-scope) new session name already taken" in the tmux-free exit-5 class, but that check needs tmux, runs after the dependency gate, and exits 6.
- **Version bump 0.14.0 → 0.15.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.15.0 in `scripts/test-release-0-5-0.sh`, `scripts/test-clean-tmp-skill.sh`, and `scripts/test-watchdog-hooks.sh`.
- `scripts/test-rename-and-conventions.sh` regained the executable bit every other script in the repo carries.

## [0.14.0] — 2026-08-02

This release closes a **scope-degradation** hole observed in practice: when a role stalled, the main agent reduced what it asked for ("only the total verdict + the 3 most severe findings") so the role could deliver something. The existing Total Goal Fidelity rule did not catch it — that rule guards the user's stated goal and the overall deliverable, while a single role's asked-for scope is a different surface. A review that reported only its worst few findings then passed every downstream gate looking clean, carrying the unreported findings into delivery. Three layers now cover it: a named anti-pattern in the prompts, per-dimension review coverage registration (mirroring the aggregate-testing contract), and a dispatch-side hook that denies scope-capping instructions before they reach the role.

### Added
- **`## Recovering A Stuck Role: Never Trade Scope For A Delivery`** in `skills/execute-task/prompts/main-agent.md` (and a mirror subsection under `## Incremental Output` in `skills/execute-task/SKILL.md`): reducing PER-ROUND output volume is always allowed, reducing the TOTAL deliverable never is. Names the banned phrasings ("just the overall verdict", "only the top 3 findings", "一句话结论也行", "细节可以省") as forbidden in recovery/re-dispatch instructions, allows a capped installment only when the same instruction commits to the remainder, records the standard recovery recipe (same full scope, N labeled steps, one message per step, flush between), states why Total Goal Fidelity does not already cover this surface, and requires sending back a role that proposes or delivers its own reduced scope.
- **Review coverage-dimension registration** — the aggregate-testing per-category contract, applied to review. `skills/execute-task/templates/review-report.md` gains a `## Coverage Dimensions` section (design conformance / correctness / test quality / regression risk, plus one per risk the design `## Risks` calls out), each registered `covered` or `not-covered: <reason>`; an unregistered dimension means the review is not closed regardless of its verdict. Wired into `subagents/review-agent.md` + `agents/review-agent.md` (new `## Coverage Dimensions Are Registered, Not Optional` section + output format), `skills/execute-task/SKILL.md` §3.C step 2 and the §4 delivery gate (new step 3 — unregistered dimension blocks delivery), `templates/task-status.md` `## Final Aggregate Review`, and the main-agent prompt's Delivery section.
- **`hooks/scripts/dispatch-scope-guard.sh` (L5)** — `PreToolUse` hook on matcher `^Agent$`, sync. The only watchdog layer that inspects what a dispatch *asks for*; all others observe after the fact. Denies (via `hookSpecificOutput.permissionDecision: "deny"`, whose reason the model sees and can act on) a dispatch to a zyz-worker role whose prompt caps the deliverable AND carries no continuation commitment ("then continue with the rest", "step 1 of 4", "分维度", "register all dimensions"). Blocked attempts are appended to `<task-dir>/runtime/scope-guard.log`. Fails open, no-ops without the `current-task` pointer, ignores non-role dispatches; `ZYZ_SCOPE_GUARD_DISABLE=1` disables just this guard. New `lib.sh` helpers: `zyz_emit_deny`, `zyz_scope_cap_hit`, `zyz_scope_continuation`.
- **T7 test group** in `scripts/test-watchdog-hooks.sh` (suite now 84 checks): 23 scope-capping phrasings that must be denied and 21 legitimate dispatches that must pass untouched — the false-positive fixture covers negated instructions ("do not just report the verdict", "只要总结论是不够的"), `其余…随后` / `remaining … second pass` staging, and target-scoping ("review just the first SubTask") — plus non-role scoping, both disable switches, bare-vs-scoped role names, the deny JSON shape, the audit log, no-pointer no-op, and fail-open on malformed input. T6 gains doc-wiring checks for the new prompt rules, dimension registration, the final-report coverage lines, the per-SubTask flag condition, and staged-installment tracking.
- **Negation veto + count-cap patterns after independent review.** A review-agent pass on this change found the guard denied the very instruction L1 teaches ("do not just report the verdict — list every finding") and missed a whole family of count caps. Fixed: `zyz_scope_negated` vetoes cap matching when the prompt forbids truncation (English and Chinese; deliberately narrow on bare `不行` so the degradation idiom "实在不行就先给一句话结论" still denies), continuation now recognizes `其余…随后` / `剩余…后续` / `remaining … second pass`, `first` no longer treats target-scoping as output-capping, and the cap list gained `limit/cap/hold to N`, `no more than N`, `at most N`, `blockers/P0/high-severity only`, `don't be exhaustive`, `重点问题就行`, `挑最重要的几条`, `关键的几条就行`. All 44 phrasings are pinned as T7 fixtures.
- **Staged-installment follow-through.** The same review found the continuation exemption was trivially satisfiable — appending "then continue" with no intent passes the guard and reproduces the original bug. The prompts now require recording the step plan in `## Restart And Recovery Notes` and actually collecting every installment; `## Final Aggregate Review` gains an `Outstanding Staged Installments` field, and the §4 gate counts an outstanding installment as an uncovered dimension.
- **Review registration reaches the delivered artifact and the per-SubTask flag.** `templates/final-report.md` `## Review Result` now carries the per-dimension coverage lines (previously only test categories survived into the final report), and §3.B step 6 states that `Reviewed: true` requires a review that registered its dimensions — closing the path where a truncated per-SubTask review flipped the flag before §3.C ever ran.

### Changed
- **`hooks/README.md`** — third hardened rule documented ("recovery never shrinks the ask") plus the full L5 contract, including the note that phrase matching is heuristic by nature, which is why the continuation exemption and the per-guard disable switch exist.
- **`skills/execute-task/SKILL.md` `## Watchdog Enforcement`** — L5 added to the layer list; the `## Long-Running Work` restart rule and the main-agent prompt's monitoring bullet now say restarts happen at the same scope.
- **Version bump 0.13.0 → 0.14.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.14.0 in `scripts/test-release-0-5-0.sh`, `scripts/test-clean-tmp-skill.sh`, and `scripts/test-watchdog-hooks.sh`.

## [0.13.0] — 2026-08-02

This release adds a **watchdog enforcement layer** for the execute-task workflow: the two long-standing prompt-only rules — "the main agent must notice and restart silent/dead subagents" and "status files must be created and kept current" — are now backed by deterministic mechanisms (Claude Code plugin hooks + a background monitor) instead of relying on model compliance. Liveness becomes an automatic side effect of tool calls; stale status triggers injected reminders and stop gates; dead roles (including subagents killed by API errors, where `SubagentStop` never fires) wake the main agent via a background watchdog. All layers fail open, no-op without a `.zyz-worker/current-task` pointer, and can be disabled with `ZYZ_HOOKS_DISABLE=1`; prompt-level duties remain in force as the fallback for degraded environments (managed-policy hook blocks, platforms without monitors).

### Added
- **`hooks/hooks.json`** — plugin hook registrations (active in any session with the plugin enabled): L0 heartbeats (`PreToolUse`/`PostToolUse`, async), L0 dispatch tracking (`SubagentStart`), L1 status-freshness reminders (`PostToolUse` sync, `additionalContext` injection), L1 post-subagent-result flush reminder (`PostToolUse` matcher `^Agent$`), L2 subagent exit gate (`SubagentStop` block on empty/too-short final message), L4 main-agent stop gate (`Stop` block while a dispatched role looks dead or the status file is badly stale during an active phase).
- **`hooks/scripts/`** — `lib.sh` (shared helpers: JSON extraction via jq/python3, atomic writes, task-root resolution through the `current-task` pointer, stale-role scanning, cooldown stamps), `heartbeat.sh`, `subagent-track.sh`, `status-freshness.sh`, `post-agent-flush.sh`, `stop-gate-subagent.sh`, `stop-gate-main.sh`. All macOS bash 3.2 + Linux compatible; every script fails open (exit 0 on any missing input/parser/write error) so the watchdog can never break the workflow it protects. Runtime bookkeeping lands under `<task-dir>/runtime/` (`agents/*.heartbeat|.start|.done`, `nag/*.last`); `.start` + no `.done` + stale heartbeat = dead-or-stuck role. Thresholds tunable via `ZYZ_*` env vars.
- **`monitors/monitors.json` + `monitors/watchdog.sh`** — L3 background watchdog, started on the first execute-task invocation per session (`when: on-skill-invoke:execute-task`). Scans heartbeats and status mtime every 60s (default) and emits one rate-limited notification line per finding — "role X silent N min with no clean finish" / "status file N min stale" — delivered to the main agent, able to wake an idle session. This is the layer that catches API-error-killed subagents. Its role threshold (`ZYZ_WATCHDOG_ROLE_STALE_SEC`, default 1200) is deliberately above the L4 gate's, and its message asks the main agent to VERIFY rather than blindly restart, since L3 cannot cross-check `background_tasks`.
- **`skills/execute-task/SKILL.md` `## Watchdog Enforcement`** — documents the five layers (L0 heartbeats, L1 reminders, L2 exit gate, L3 watchdog, L4 stop gate), the main agent's obligations (write the `current-task` pointer at §1 Start Task; treat `[zyz-worker watchdog]` messages as actionable instructions; keep `Current Phase` accurate), and degraded-environment behavior. §1 Start Task gains the pointer-file step.
- **`scripts/test-watchdog-hooks.sh`** — 63-check static + smoke suite (layout/exec/syntax, manifest validity and registrations, sandboxed behavioral tests of every hook including block/allow/cooldown/no-pointer/disable paths and scoped-vs-bare `agent_type` normalization, doc wiring, three-manifest version consistency).

### Changed
- **`skills/execute-task/prompts/main-agent.md`** — new responsibilities: write/maintain the `current-task` pointer, act immediately on watchdog messages (re-dispatch the named role or flush status — never defer), keep `Current Phase` accurate at every transition.
- **`hooks/README.md`** — rewritten from placeholder to the full per-script contract documentation (trigger point, inputs, outputs, failure behavior, supported agents for each hook + the monitor).
- **`CLAUDE.md`, `README.md`, `docs/conventions/project-structure.md`** — watchdog layer and new `monitors/` directory documented; "hooks not yet implemented" notes removed.
- **`.gitignore`** — ignores local scratch paths (`tmp/`, `.orphaned_at`, `docs/superpowers/`) so the release surface stays clean.
- **Version bump 0.12.0 → 0.13.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `EXPECTED_VERSION` aligned to 0.13.0 in `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh`.

## [0.12.0] — 2026-08-02

This release adds a **PR review handling** policy so the execute-task / worker main agent does not blindly accept external pull-request review feedback. When review results (comments, "changes requested", inline threads, or automated review findings) land on an actual PR, the main agent processes them one at a time and independently verifies whether each raised problem objectively exists. Findings confirmed to exist are fixed through the normal role/test/review gates and acknowledged on the PR; findings that do not hold are declined with a reasoned comment posted on the PR thread. No finding is silently ignored. This is distinct from the plugin's pre-existing internal review-agent loop.

### Added
- **New `## PR Review Handling (External Review Feedback)` section** in `skills/execute-task/prompts/main-agent.md`: do-not-blindly-accept posture, per-finding independent verification (one at a time), route confirmed findings to implementation-agent/test-agent, reject non-holding findings with a concrete reason posted on the PR via the platform CLI (`gh pr`/`gh api`, `glab mr`, or the repo tool), never silently ignore, escalate on Goals/Acceptance-Criteria impact or accept↔reject loops, and record every decision in the status file.
- **Mirror `### PR Review Handling` subsection** in `skills/execute-task/SKILL.md` under the Automatic Execution Policy.
- **New `## PR Review` section** in `skills/execute-task/templates/task-status.md` (PR reference, accepted findings with verification + change, rejected findings with disproving evidence + posted comment, escalated items) so external-review decisions are auditable and survive restart/handoff.

### Changed
- **`skills/orchestration-scheduling-task/SKILL.md` PR flow note** now points at the worker's PR-review-handling behavior and clarifies that a worker acting on PR feedback rolls `phase` back from `awaiting-confirmation`; only write `confirmed` once the resolved PR is satisfactory.
- **Version bump 0.11.0 → 0.12.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.11.0] — 2026-07-28

This release evolves the **`clean-tmp`** skill from an interactive-only `/tmp` cleaner into a **dual-mode (interactive / auto-unattended) cleanup skill with two new cleanup surfaces — Docker resources and language build/package-manager caches** (GitHub issue #1). Interactive mode (the default) keeps the inventory → user-confirms → delete contract unchanged; the new auto mode (`--auto` or explicit unattended authorization) replaces "wait for confirmation" with a tightened five-condition DELETE criterion (owner = current user, mtime > 48h, not protected, no open handles, positive allowlist match) plus a fixed four-block post-run report. The other three safety-contract rules (never wildcard-delete, never touch other users' files, uncertain → keep) are explicitly not relaxed in either mode, and NEEDS-YOUR-CALL items are always kept and reported in auto mode.

### Added
- **Auto (unattended) mode** in `skills/clean-tmp/SKILL.md`: a `模式判定` section (default interactive; `--auto` or an explicit "已授权自动执行 / unattended" prompt statement enters auto mode; vague wording never counts), a five-condition conjunctive DELETE criterion section with fail→keep direction stated per condition, and a fixed four-block `自动模式事后报告` section (deleted list with per-category totals, kept list with reason tags recent/in-use/needs-call/protected/not-on-allowlist, `quota -s`, per-root `df -h` before/after).
- **48-hour dwell threshold** for auto mode: files probed with `find "$p" -maxdepth 0 -mmin -2880`, directories probed recursively with `find "$p" -mmin -2880 -print -quit` (inner mtime; `-print -quit` short-circuit preserves find's exit status so probe failure stays distinguishable from "old enough"), with the mtime-not-atime rationale (atime unreliable on noatime mounts).
- **Cleanup surface A — Docker resources** (gated on auto mode / explicit authorization): `docker system df` pre-probe, `docker image prune -a -f` (with short-loop re-pull cost note), `docker volume prune -f` with accurate volume-protection semantics (volumes referenced by ANY existing container — including stopped ones — survive; risk exists only after the container itself is deleted) and the Docker ≥23 anonymous-vs-named prune scope note, a `--keep-volumes` exclusion-list path via `docker volume ls -q` + per-name `docker volume rm` (scope equivalent to `prune -a`, so the list must be complete or fall back), optional `docker builder prune -f`, daemon-unreachable → skip the whole block (marked, not a failure), and the rootless-docker `~/.local/share/docker` uid-quota motivation.
- **Cleanup surface B — build/package-manager caches**: a six-row tier table (Go build cache delete-over-threshold with `--go-cache-threshold` default `1G` / Go module cache never / pnpm store prune ok / uv cache clean ok / npm interactive-only / playwright browsers needs-your-call), each row gated on `command -v`, cache paths always queried from the tool itself (`go env GOCACHE` / `go env GOMODCACHE` / `uv cache dir`) so macOS paths are not silently missed.
- **`skills/clean-tmp/references/`** — two on-demand reference docs split out of the SKILL.md body: `macos-tmpdir-trap.md` (the `/tmp` → `/private/tmp` symlink trap and the physical-path fix) and `socket-liveness.md` (ss/lsof dual branch, `kill -0` EPERM-vs-ESRCH semantics, `lsof +D`).

### Changed
- **Safety contract rule 1 is now dual-mode** (interactive: inventory → confirm → delete; auto: inventory → tightened criteria → post-run report); rules 2–4 kept and explicitly marked as not relaxed in either mode.
- **Default keep-list expanded from 4 to 6 categories**: adds `vscode-*` / `code-<uuid>` (merged wording, verify-alive-before-delete) and `*.keep` (user-marked keep) to `claude-*` / `tmux-<uid>` / `mcp-*` / `ssh-*`.
- **Multi-user guardrails hardened** in the pitfalls section: never estimate your own usage with an owner-unfiltered `du -sk /tmp/*` (a shared-host lesson — other users' 30GB dirs get miscounted as yours), and the quota perspective (quota counts per-uid files filesystem-wide; assess with `quota -s` + owner-filtered du).
- **Trigger words extended** (frontmatter `description` + `## 何时加载本 skill`): 定期磁盘整理, 清 docker, 配额超了, quota 超限, 无人值守清理 / unattended / auto.
- **README skill bullet and repo-structure tree updated in lockstep** (dual mode + Docker/build-cache surfaces; `references/` files listed under `clean-tmp/`); `docs/conventions/project-structure.md` now cites `git-worktree` alone as the SKILL.md-only example and `clean-tmp` as a `SKILL.md` + `references/` on-demand-loading example.
- **Version bump 0.10.0 → 0.11.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **EXPECTED_VERSION aligned to 0.11.0** in both `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh`, and the clean-tmp test suite gains groups T7–T11 covering the new sections (those edits are made by test-agent; recorded here for completeness).

## [0.10.0] — 2026-07-22

This release makes **a single task spanning multiple repos default to one tmux session + one `claude` managing one git worktree per repo** (each repo on its own branch, with its own commits and push), instead of splitting a multi-repo task across sessions. The "one worker = one worktree" invariant is replaced by `each worker = 1 tmux session + n git worktrees (one per repo; n=1 for single-repo tasks) + 1 full claude process`. The "worker" concept and every contract identifier (the `orch-*.sh` script names, `worker-status.md`, `ZYZ_WORKER_STATUS_FILE`, the runtime-config block field names, stdout keys) are retained unchanged — nothing is renamed. Single-`source-repo:` tasks stay byte-for-byte backward compatible.

### Added
- **Multi-repo master-entry schema (numbered flat keys)** in `skills/orchestration-scheduling-task/templates/master-list-task-entry.md` and the SKILL.md frontmatter excerpt: additional repos are declared with `source-repo-2:`, `source-repo-3:`, … (numbering starts at 2, must be contiguous); the unnumbered `source-repo:` is the primary repo (its worktree is the pane cwd). `branch-N:` / `base-N:` / `worktree-N:` may override per repo and otherwise inherit (branch/base from the primary's resolved value; `worktree-N` from the sibling-directory layout). Fully backward compatible with a single `source-repo:` entry.
- **`orch-spawn-worker.sh` builds N worktrees (one per repo) + a single tmux session + 1 claude.** Default multi-repo layout is a **sibling-directory** convention: a shared parent `~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/` with each repo checked out under a directory named after the repo, so `go.work`-style `../<repo>` relative references resolve. Validation runs per repo (missing / non-absolute / non-existent / not-a-git-worktree, plus numbering gaps and worktree paths containing `:`) with `repo <N>`-prefixed diagnostics and exit 5; partial-failure rollback removes already-created worktrees.
- **New `ZYZ_WORKTREES` env** (colon-separated, primary first) exported by spawn for a multi-repo worker so `execute-task` knows its full worktree set; absent = single-worktree (legacy) behavior. The reuse in-band runtime-config block gains an optional `worktrees:` line carrying the same set for a reused multi-repo container.

### Changed
- **Per-repo merge / cleanup with fail-fast + idempotent re-run** in `orch-merge.sh` / `orch-merge-and-cleanup.sh` / `orch-cleanup-worker.sh`: the repo set is sourced from the task's `dispatch.md` resolved numbered field group (single-repo tasks fall back to the master entry), never from the master entry's optional numbered keys, so a multi-repo entry that omits `worktree-N`/`branch-N`/`base-N` is never silently reduced to repo 1. Merge is not cross-repo atomic — it checks all repos first, merges each in turn, writes `state: completed` only after every repo merges, and a re-run skips already-merged repos. gh-path idempotency probes existing PRs via `gh pr list --head <branch> --state all` (not `gh pr view`, which has no `--head`).
- **Container reuse hands over the whole worktree set** in `orch-reuse-worker.sh`: all `reuse-scope` values reuse the old task's entire worktree set (partial single-repo reuse is unsupported); the new `dispatch.md` inherits the numbered field group and the reuse-runtime-config block emits the optional `worktrees:` line.
- **`dispatch.md` numbered field group preserved across Phase-2 rewrites** in `orch-check-worker.sh` (`rewrite_dispatch_atomic`) so the fixed-field rewriter no longer drops `worktree-N` / `source-repo-N` / `branch-N` / `base-N`; both writers (spawn + reuse) emit the group as fully-resolved non-empty values.
- **The "one worker = one worktree" invariant replaced** by `each worker = 1 tmux session + n git worktrees + 1 full claude process` across the orchestration SKILL.md, `prompts/main-agent.md`, orchestration templates, `README.md`, `CLAUDE.md`, `commands/orchestrate-tasks.md`, `docs/conventions/long-running-state.md`, and `skills/git-worktree/SKILL.md`. The worker concept and all identifiers are retained — no rename, no migration. The isolation boundary is restated: workers never touch each other's worktrees (spawn enforces pairwise-disjoint worktree paths), while within a worker there is full write access to all of its own worktrees.
- **`execute-task` multi-worktree write rule** (in the execute-task SKILL.md + prompt, owned by a sibling change): a worker has full write access to every worktree in `ZYZ_WORKTREES` (or the reuse block's `worktrees:` line), and commits / pushes / delivery reports are listed per repo.
- **Historical non-goal noted, not rewritten**: `docs/design/initial-design.md` (2026-05-14) recorded "no multi-project orchestration" as a then-non-goal; that historical document is left unchanged — this release documents the evolution here.
- **Version bump 0.9.2 → 0.10.0** in `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.9.2] — 2026-07-13

This release hardens the design→implementation approval gate so the main agent never self-advances into implementation on user timeout, silence, or absence; it must wait for explicit user approval. The only exception is an explicit prior instruction that specifically authorizes skipping this gate (recorded verbatim to disk); generic trust/autonomy statements and bare goal statements do not count.

### Changed
- **execute-task gate wording hardened** in `skills/execute-task/SKILL.md` and `skills/execute-task/prompts/main-agent.md`: the design→implementation step is now an unconditional hard wait (WAIT indefinitely on timeout/absence, never self-advance); the Automatic Execution Policy's "final approval" escalation clause is reframed as a hard stop that cannot be satisfied-and-passed; the "proceed without asking" / "prefer continuing through non-blocking ambiguity" postures are explicitly carved out from this gate.
- **Skip exception narrowed and made auditable**: only an instruction explicitly authorizing skipping THIS gate qualifies; it must be recorded verbatim in the status file before self-advancing. A material change to the approved approach (Goals, Acceptance Criteria, Implementation Plan, architecture, or Files To Change) re-arms the gate and requires fresh approval.
- **Orchestrated mode**: a new hard rule requires flushing `wait-state=waiting-user` while holding `phase=design`, approving only via pane attach or a question-id'd `answer.md` (orchestrator never relays design approval), and recording the approval/skip to disk before `phase=implementation` so a resuming worker gates on the on-disk record, not `phase` alone. The phase-mapping implementation-dispatch row is annotated "on user approval only — never autonomous." No new `phase` enum value added.
- **New `templates/task-status.md` field** `Design Approval Record` under `## Design Review` to hold the auditable approval/skip record.
- **Version bump 0.9.1 → 0.9.2** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **EXPECTED_VERSION aligned to 0.9.2** in both `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh` (those two edits are made by test-agent; recorded here for completeness).

## [0.9.1] — 2026-07-13

This release adds guidance emphasizing that fix / repair / backfill / migration scripts must be validated locally on fabricated (synthetic) representative data before touching real data. The typical failure mode for such one-off data-mutating scripts is that their first run against real data is also their first test — a logic error there causes irreversible damage. The new guidance lands in the roles that write, test, and plan for these scripts, without becoming a hard delivery gate (it applies only when a task actually produces such a script).

### Changed
- **implementationAgent prompt** (`subagents/implementation-agent.md` + mirror `agents/implementation-agent.md`) gains a Responsibilities bullet requiring local fabricated-data validation of any data-mutating fix / repair / backfill / migration script (normal + boundary + error cases, verifying correctness and idempotency) before it counts as implemented; this validation is a temporary self-check cleaned up before delivery.
- **testAgent prompt** (`subagents/test-agent.md` + mirror `agents/test-agent.md`) gains a Responsibilities bullet to solidify that fabricated-data validation into repeatable tests/fixtures rather than leaving it as a one-off manual self-check.
- **`skills/execute-task/templates/design-doc.md`** Testing Plan gains a reminder (HTML comment) to plan fabricated-data validation for data-mutating scripts (what data to fabricate, how the repaired result is verified, idempotency / rollback considerations).
- **Version bump 0.9.0 → 0.9.1** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **`EXPECTED_VERSION` aligned to 0.9.1** in both `scripts/test-release-0-5-0.sh` and `scripts/test-clean-tmp-skill.sh`.

## [0.9.0] — 2026-07-09

This release adds a new skill-only artifact **`clean-tmp`**: a cross-platform (macOS + Linux) skill for safely cleaning up the current user's leftover temporary files, adapted from a Linux-only source skill while preserving its full safety contract (inventory → user confirms → delete; never `rm -rf /tmp/*`; named deletion lists only; never touch other users' files; when uncertain, keep). Like `git-worktree`, it is skill-only (no slash command) and triggers via its `description`.

### Added
- **`skills/clean-tmp/SKILL.md`** — cross-platform safe temp-directory cleanup, skill-only like `git-worktree`. Adapted from a Linux-only source into macOS + Linux double-coverage: enumerates temp roots by `$TMPDIR` presence (not OS name) so both `/tmp` and macOS's per-user `$TMPDIR` (`/var/folders/**/T/`) are covered; POSIX inventory via `find -user "$(id -un)"` + `du -sk` (no GNU `-printf`); socket liveness via a dual branch (`ss -lxp` preferred on Linux, `lsof -nP` fallback on macOS/no-ss) with `kill -0` process-alive re-check (replacing Linux-only `/proc/$pid`); "holder undetermined → keep" default so live sockets are never silently deleted; a **root-relative default keep-list** (`claude-*`, `tmux-<uid>`, `mcp-*`, `ssh-*` protected under every enumerated root), correcting the source's false claim that the macOS tmux socket lives in `/tmp` — it is at `$TMPDIR/tmux-<uid>/`, which the repo's tmux-based orchestration workers depend on.

### Changed
- **Version bump 0.8.1 → 0.9.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).
- **README skill enumerations updated in lockstep** — both the `## 当前状态` bullet list and the `## 仓库结构` ASCII tree now list `skills/clean-tmp/SKILL.md`; `docs/conventions/project-structure.md` notes `clean-tmp` as a `SKILL.md`-only utility skill.
- **New static-check test `scripts/test-clean-tmp-skill.sh`** added (macOS bash 3.2 + Linux compatible) verifying skill existence, frontmatter, three-manifest version consistency at 0.9.0, cross-platform/safety lint of the skill body, doc wiring, the CHANGELOG section, and a pack smoke test; `scripts/test-release-0-5-0.sh` `EXPECTED_VERSION` aligned to 0.9.0.

## [0.8.1] — 2026-07-03

This release enables **ultracode (dynamic workflow) in dispatched workers**: the orchestration-scheduling-task skill now launches each worker's `claude` with `--settings '{"ultracode": true}'` in addition to the existing bypass-permission flags, so every worker session runs with dynamic multi-agent workflow orchestration enabled.

### Changed
- **Worker launch command** is now `claude --plugin-dir <plugin-root> --permission-mode bypassPermissions --dangerously-skip-permissions --settings '{"ultracode": true}'` in all places that define it: the L2 driver's `first-dispatch` launch flow and `reuse-dispatch` restart-claude branch (`subagents/orch-driver-agent.md` + mirrored `agents/orch-driver-agent.md`), the L1 orchestrator dispatch-step description (`skills/orchestration-scheduling-task/prompts/main-agent.md`), and the e2e test's simulated launch (`scripts/test-e2e-layered.sh`).
- Recovery `claude --resume` commands are intentionally unchanged (they carry no permission/settings flags).
- **Version bump 0.8.0 → 0.8.1** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated); `scripts/test-release-0-5-0.sh` `EXPECTED_VERSION` aligned.

## [0.8.0] — 2026-06-26

This release adds **Go build I/O optimization injection** to the `orchestration-scheduling-task` skill. Many parallel workers each running `go build ./...` saturate a single disk because total compile parallelism ≈ (worker count) × (each build's `-p`, default ≈ NumCPU) and all link intermediates write to disk. Each dispatched worker now, by default, gets `GOTMPDIR` pointed at a tmpfs RAM disk and `GOFLAGS=-p=N` lowering per-build concurrency, injected into its pane before claude starts. Cross-platform with graceful auto-degrade (hosts without tmpfs, e.g. macOS, simply skip `GOTMPDIR`); never clobbers user env; never touches `GOCACHE`/`GOMAXPROCS`.

### Added
- **`scripts/orch-build-env.sh`** — a standalone, side-effect-free helper that reads three host env vars and prints ONE shell snippet to stdout (empty when disabled). It does NOT touch tmux; spawn / reuse call it and send-keys the line into the new pane. The emitted snippet bakes candidate values but runs its no-clobber (`[ -z "${GOTMPDIR:-}" ]` / `[ -z "${GOFLAGS:-}" ]`) and existence+writable (`[ -d ] && [ -w ]`, auto-degrade) guards *in the pane*; it `mkdir -p`s `GOTMPDIR` (Go does not auto-create it) and never emits `GOCACHE` or `GOMAXPROCS`.
- **Three tunable env switches** (read on the orchestrator host): `ZYZ_GO_BUILD_OPT` (default on; `0`/`false`/`off`/`no` disables all injection), `ZYZ_GO_BUILD_P` (the N in `GOFLAGS=-p=N`, default `4`, clamped ≤ 64 — illegal or over-cap values fall back to 4, because `-p` is the one knob that can silently re-detonate the I/O incident: total = workers × p), and `ZYZ_GO_TMPFS_DIR` (tmpfs base dir candidate, default `/dev/shm`; a value containing a single quote is rejected to keep the send-keys quoting intact). The probe is existence+writability, NOT a filesystem-type check — pointing it at a plain disk dir writes intermediates to disk (documented footgun).

### Changed
- **`orch-spawn-worker.sh` gains a Step 9b** that, after the `export ZYZ_*` send-keys, runs `orch-build-env.sh` and (if non-empty) send-keys the build-opt line into the pane — non-blocking: a missing/erroring helper yields an empty line and is simply skipped.
- **`orch-reuse-worker.sh` injects the same line in the `worktree` scope branch only** (new session / new pane / new claude, same shape as spawn). The `tmux` / `both` branches do NOT inject — they reuse an already-started claude whose env is frozen, and send-keys'ing shell into a live claude pane is harmful.
- README (new *Go 构建 I/O 优化注入* section: worker × p model, the three switches, auto-degrade, no-clobber, `GOCACHE`/`GOMAXPROCS` untouched, the existence-not-type probe footgun, the tmpfs-OOM risk with `watch -n5 'df -h /dev/shm; free -h'`, and a manual snippet for standalone users), orchestration SKILL.md (plan-step disk I/O caveat), `prompts/main-agent.md` (`## Inputs` env list), and `docs/conventions/project-structure.md` (helper list) updated in lockstep.
- **Version bump 0.7.0 → 0.8.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.codex-plugin/plugin.json` (codex build suffix regenerated).

## [0.7.0] — 2026-06-24

This release adds **container reuse** to the `orchestration-scheduling-task` skill: a new task can reuse a *completed* task's leftover tmux session and/or git worktree instead of building a fresh container.

### Added
- **`scripts/orch-reuse-worker.sh <new-task-id> <list-dir>`** — the reuse counterpart to `orch-spawn-worker.sh`. It reads the new task's master-entry `reuse-from` / `reuse-scope` / `reuse-claude` fields, validates the old task is `completed` in the same list with its container still present, associates the old tmux session and/or worktree per the scope matrix, creates the new task's own `runtime/<new-id>/`, writes the initial `worker-status.md` (phase=design), starts the heartbeat (in-pane daemon for `worktree` scope; a NEW window in the reused session for `tmux`/`both`), and writes the Phase-1 `dispatch.md` (incl. the four reuse fields and, for same-claude reuse, an attach-only `## Recovery` note). Like spawn it is container-only and NEVER starts `claude`. Exit codes mirror spawn's structure, with the 5-precondition split into tmux-free (validated before the tmux/git dependency check) and tmux-dependent (old session alive, after it).
- **Master-entry reuse frontmatter** `reuse-from` (a completed task-id in the same list), `reuse-scope` (`worktree | tmux | both`, default `both`), `reuse-claude` (`true` default | `false`, only meaningful when reusing tmux). Present `reuse-from` routes the dispatch step to `orch-reuse-worker.sh` + an L2 `reuse-dispatch` driver instead of `orch-spawn-worker.sh` + `first-dispatch`.
- **New L2 driver intent `reuse-dispatch`** (the intent enum is now `first-dispatch | intervene | relay-confirmation | reuse-dispatch`) with three branches: same-claude reuse (`reuse-claude-effective=true`, no new claude — sends an in-band runtime-config block + `/execute-task` to the already-running claude after a `capture-pane` readiness confirm), restart-claude reuse (`false` — exits the old claude, confirms a bare shell, relaunches, sends the block), and new-session reuse (`n/a`, `reuse-scope=worktree` — plain first-dispatch with the script-exported clean env, no block).
- **In-band runtime-config block contract in `execute-task` `## Orchestrated Mode`.** A reused, still-running claude cannot see re-exported env, so a `[zyz-worker reuse-runtime-config]` … `[/zyz-worker reuse-runtime-config]` block carrying `task-id` / `worker-status-file` / `question-file` / `answer-file` / `heartbeat-file` OVERRIDES the launch-time `ZYZ_*` env for the whole task lifecycle — including the `task-id` and ALL task-id-derived paths (the detailed `.zyz-worker/tasks/<task-id>/` status dir, commit/branch references). A reuse worker also `touch`es the block's heartbeat file on every flush.

### Changed
- **`dispatch.md` schema gains four Phase-1 reuse fields** `reuse-from` / `reuse-scope` / `reuse-claude-effective` / `heartbeat-window-id`. `orch-spawn-worker.sh` writes them empty (schema unification); `orch-reuse-worker.sh` populates them. `orch-check-worker.sh`'s `rewrite_dispatch_atomic` now reads back and re-emits all four (otherwise the first Phase-2 poll would drop them) and generates a **reuse-aware three-way `## Recovery` body**: same-claude reuse (`reuse-from` set AND `reuse-claude-effective=true`) gets an ATTACH-ONLY body (no independent `claude --resume`, because the session-id is the shared old+new session); plain spawn and independent reuse sessions (`reuse-claude-effective` ∈ {`false`, `n/a`}) keep the attach + `--resume` body.
- **`orch-spawn-worker.sh` pure-spawn semantics are unchanged** other than emitting the four empty reuse fields. It still builds only fresh containers, still rejects collisions (exit 5/6), still never starts claude.
- Orchestration SKILL.md (Core Rules, File Protocols, new `## Container Reuse` section, State Machine note, Crash Recovery reused-container subsection, Maintenance Notes lockstep) and `prompts/main-agent.md` (analyze reuse prerequisite check, dispatch reuse routing branch, gate-step shared-container cleanup warning, Failure Modes, and a Restart hard rule that a `reuse-from` worker is NEVER first-dispatched) updated for the feature. Templates (`master-list-task-entry.md`, `dispatch.md`, `monitor.md`, `worker-status.md`), README, CLAUDE.md, and project-structure.md updated in lockstep.

## [0.6.5] — 2026-06-22

This release **supersedes the 0.6.4 confirmation/done model.** 0.6.4 wrongly made the worker phase `awaiting-confirmation` an absorbing (non-reversible) terminal and removed the worker-level "done" exit entirely. That conflicted with the actual semantics (a worker awaiting confirmation is exactly the state most likely to roll back when the user asks for changes) and left standalone/worker-window confirmation with no terminal of its own.

### Fixed
- **`awaiting-confirmation` is now reversible.** 0.6.4 made it the sole absorbing phase; that was wrong. A worker that self-declared finished and is awaiting confirmation must be able to roll back (e.g. the user's review asks for changes → back to `implementation`).
- **Fixed the `in-progress` definition contradiction.** The orchestration state machine defined `in-progress` as "phase not awaiting-confirmation" while the projection rules projected `awaiting-confirmation` into a state — a direct contradiction. `in-progress` is now "worker in a working phase (`design`..`delivery`) with `wait-state=none`", and `awaiting-confirmation` projects to the new `awaiting-user-confirmation` state.

### Added
- **Worker phase `done` reintroduced as the sole non-reversible absorbing terminal.** It means the USER has confirmed delivery and is written ONLY after explicit user confirmation (worker-window direct, or relayed from L1) — never autonomously, never self-advanced from `awaiting-confirmation`. In standalone mode `phase=done` is itself the terminal.
- **New L1 state `awaiting-user-confirmation`.** The orchestrator projects a worker's `phase=awaiting-confirmation` into `state: awaiting-user-confirmation` (orchestrator-written, not in the user-writable set), distinct from `paused` (mid-task waiting on a Q&A/resource). A worker's `phase=done` mirrors to `state: completed`.
- **Dual confirmation channel, single source of truth (`worker phase=done`).** (A) The user confirms directly in the worker window → the worker writes `phase=done`. (B) The user writes the `confirmed` token in the master entry → L1 dispatches an L2 `orch-driver-agent` with `intent=relay-confirmation` to `send-keys` the confirmation into the worker pane → the worker writes `phase=done` → L1 mirrors `state: completed` on the next poll. L1 never writes `completed` directly from the `confirmed` token; `completed` always mirrors a `phase=done` (the legacy `approved` atomic merge+complete+cleanup remains a deliberate exception, since the worker is cleaned up). The relay is **idempotent** — at most one relay per confirmation, deduplicated via the worker's `monitor.md` `driver-intent`, re-armed only if the worker goes stale. The gate step is now the third L1 site that dispatches an L2 (alongside dispatch/`first-dispatch` and poll/`intervene`).

### Removed
- **`scripts/orch-confirm.sh` is retired.** It directly wrote `state: completed` on the `confirmed` token, which violated the single-source-of-truth invariant; the `confirmed` token now relays to the worker (which writes `phase=done`) instead. References removed from the README scripts tree, `orch-merge.sh`/`orch-merge-and-cleanup.sh` header comments, and the gate-step exit handling.

## [0.6.4] — 2026-06-22

### Changed
- (semantic-breaking) **`state: completed` is now decoupled from merge.** `completed` means user-confirmed delivery — the user wrote `confirmed` (or legacy `approved`) in the master entry `## Pending Merge Approval` section — and the task branch may or may not have been merged to base. This **supersedes** the 0.6.3 contract that "delivery is recorded as `state: completed` only after a successful merge" and that dependency unlock gates on `completed` (post-merge); merge is now a separate, independently-tokened action that may have happened, may happen later, or may never happen (e.g. PR-only or experimental branches). `completed` remains terminal and immutable; post-delivery changes go through a superseding new task.
- (semantic-breaking) **Dependency unlock is now AI-judgment-based, not "completed == merged".** When a `blocked-by` dependency reaches `completed`, the orchestrator judges each downstream task individually — whether the dependency's output is actually available (merged into the downstream task's `base`, or only living on the dependency's own branch) and which branch the downstream worktree should be based on. Downstream may chain off an unmerged dependency's branch by setting its `base:` to that branch, rather than basing on a stale `main`. The judgment and chosen base are recorded in the downstream task's `## Orchestrator Analysis`.
- **Worker may merge to base on explicit user instruction.** The `execute-task` Version Control rule gains an exception: on explicit user instruction (conversation in standalone mode, or a matching `## Pending Merge Approval` token in orchestrated mode), the worker MAY `git merge` the task branch into its base and push (still no force-push / no history rewrite). Autonomy never covers merge to base. In orchestrated mode the orchestrator performs the merge, not the worker, to avoid both layers writing the base concurrently.

### Added
- **`scripts/orch-confirm.sh <task-id> <list-dir>`** — marks `state: completed` on the `confirmed` token, without merging or cleaning up the worktree.
- **`scripts/orch-merge.sh <task-id> <list-dir> <base-branch>`** — merges the task branch into base and pushes on the `merge` / `merge: <base>` token, without changing `state` or cleaning up. Exit codes mirror `orch-merge-and-cleanup.sh` (12 conflict, 13 push-failed, etc.).
- **New `## Pending Merge Approval` tokens** `confirmed` (mark done, no merge/cleanup) and `merge` / `merge: <base>` (merge to base + push, no state change). Legacy `approved` is retained as the combined merge + completed + cleanup path and short-circuits any coexisting tokens this tick.

## [0.6.3] — 2026-06-22

### Changed
- (semantic-breaking) Worker `phase` state machine: removed the worker-written `done` phase; the furthest state a worker self-reaches is now `awaiting-confirmation` (self-declared finished, awaiting user confirmation). The real "done" = delivery is recorded by the orchestrator as master-entry `state: completed` only after a successful merge. Phase may now roll back among design/implementation/testing/review/delivery to reflect real iteration; only `awaiting-confirmation` is absorbing (never rolls back). Dependency unlock continues to gate on `completed` (post-merge) — a worker reaching `awaiting-confirmation` does NOT unlock downstream tasks. Post-delivery changes go through a superseding new task, never a re-open.

### Removed
- The `done` value from the worker `phase` enum (replaced by `awaiting-confirmation`).

### Fixed
- Orchestration cleanup/merge now actually remove `~/`-form worktrees: `scripts/orch-cleanup-worker.sh` and `scripts/orch-merge-and-cleanup.sh` quoted the `~/` strip pattern (`${WORKTREE#"~/"}`) so tilde no longer mis-expands and skips removal.
- Orchestrated-mode contract now requires `worker-status.md` to be valid YAML frontmatter wrapped in `---` fences; `scripts/orch-check-worker.sh` emits `worker-status-malformed=true` for a fence-less file so the orchestrator can diagnose it.

## [0.6.2] — 2026-06-21

### Fixed
- **Orchestration workers no longer fail at dispatch with `Unknown command:
  /execute-task`.** The L2 `orch-driver-agent` sent the bare slash command
  `/execute-task <task-id>` into the worker pane, but in current Claude Code
  (verified v2.1.153) plugin **commands** register namespaced-only
  (`/zyz-worker:execute-task`) while plugin **skills** register bare — and
  because `execute-task` ships as *both* a command (`commands/execute-task.md`)
  and a skill (`skills/execute-task/`), the bare `/execute-task` collides and
  never resolves. Every dispatched worker therefore rejected the command and the
  whole `orchestration-scheduling-task` pipeline died at its first hop. The
  driver now sends the namespaced `/zyz-worker:execute-task <task-id>` at every
  pane-facing point (first-dispatch send, intervene re-send, and the pre-launch
  "already-running" heuristic) in both `agents/orch-driver-agent.md` and its
  mirror `subagents/orch-driver-agent.md`; the Unknown-command *detection* and
  human-facing symptom strings are intentionally left bare. Found during
  real-claude e2e acceptance of 0.6.1.
- **`scripts/test-e2e-layered.sh` gains assertion A5**, which actually sends
  `/zyz-worker:execute-task <task-id>` into the launched worker and asserts the
  pane shows no `Unknown command` within the readiness deadline. The prior A1–A4
  only proved a worker could *bind* a claude session (via a "reply with PONG"
  round-trip); they never sent the real slash command, which is exactly why the
  command-registration break shipped green. A5 closes that acceptance gap (cost:
  one extra LLM round-trip per run).
- **`scripts/test-orchestration-helpers.sh` gains a deterministic guard (T9)**
  that requires the namespaced send token and forbids the bare send token in
  both driver mirrors, and asserts the "Send the command" line is byte-identical
  across them — locking the fix with no API/tmux/claude dependency.

## [0.6.1] — 2026-06-21

### Fixed
- **dispatch.md transcript binding now works for worktree paths containing a
  `.`** (including the default `~/.zyz-worker/worktrees/...`). The orchestrator
  computed `encoded-cwd` as `/`→`-` only, but Claude Code names its
  `~/.claude/projects/<dir>` by replacing BOTH `/` and `.` with `-` and
  squeezing consecutive `-`. So the check helper looked in the wrong directory,
  never found the transcript, `dispatch-bound` stayed `false` forever, and crash
  recovery was degraded. `orch-check-worker.sh` now discovers the transcript by
  its session-id (a globally-unique UUID) via `find ~/.claude/projects -name
  "<sid>.jsonl"`, which is robust regardless of claude's path-encoding rule. The
  `encoded-cwd` computation in `orch-spawn-worker.sh` is also corrected to match
  claude's actual rule so the recorded field (used for diagnostics and the
  recovery command) is accurate. Found during real-claude e2e acceptance of
  0.6.0.
- **`scripts/test-e2e-layered.sh`**: the readiness probe misread the
  bypass-permissions confirmation page's `❯ 1. No, exit` menu arrow as a ready
  prompt, so the page was never cleared and claude stayed stuck; a confirmation
  page is now never treated as "ready". The RESULT line also printed a wrong
  fixed denominator and now prints `N passed, M failed`.

## [0.6.0] — 2026-06-21

### Added
- **Per-task `dispatch.md` crash-recovery state file.** Each worker now records
  the binding between its tmux session/pane and its claude session-id +
  transcript path, so a worker (or its transcript) can be recovered after the
  tmux session, claude process, or orchestrator dies. `orch-spawn-worker.sh`
  writes Phase-1 (deterministic) fields; `orch-check-worker.sh` lazily fills
  Phase-2 (claude-side) fields and regenerates a `## Recovery` block with
  concrete `tmux attach` / `claude --resume … --plugin-dir …` commands once the
  worker has bound. A `## Crash Recovery` section in the orchestration SKILL
  documents the recovery flow and the underlying Claude Code session-file
  timing.
- **3-layer orchestration architecture.** The orchestration-scheduling-task
  skill is now an explicit L1 / L2 / L3 hierarchy: L1 (main agent) orchestrates
  and polls worker state inline (read-only, never touches a pane); a new L2
  `orch-driver-agent` subagent is dispatched on demand to do the heavy pane
  driving for one worker (start claude in bypass mode, clear the confirmation
  pages, run `/execute-task`, or intervene when stuck) and writes only
  `monitor.md`; L3 is the tmux + independent claude running `/execute-task`,
  invisible to the upper layers. User Q&A is never relayed upward — L1 only
  notifies "task X needs you in window Y" and the user attaches directly. The
  SKILL ships a hierarchy diagram and a responsibility-boundary table.
- **`scripts/test-e2e-layered.sh`** — a cross-platform (Linux + macOS) real-claude
  acceptance script that verifies the layered architecture end-to-end: spawn is
  container-only, the parent-shell invariant holds, first-launch is exactly-once
  idempotent, and dispatch-bound binds after the first LLM round-trip.

### Changed
- **execute-task schedules by the dependency graph, not list order.** The main
  agent now maximizes parallelism at every dispatch point: independent SubTasks
  (and any fan-out of reviews/research) that share a single upstream are
  dispatched together once that upstream is done, instead of being serialized by
  their list numbering. Documented as a standing discipline in the SKILL and the
  controller prompt.
- **`ZYZ_MAX_PARALLEL_WORKERS` defaults to `-1` (unlimited).** Set a positive
  integer to cap. Each worker is a full tmux + worktree + claude process, so a
  resource caveat is documented; the cap still counts paused workers as
  occupying a slot.
- Renamed the status-file `## Code Review` section (and the review-agent's
  `## Code And Test Review Standard`) to **Implementation Review**, aligning the
  term with what the phase actually reviews and with the sibling `## Design
  Review` / `## Final Aggregate Review` sections.

### Removed
- **`orch-spawn-worker.sh --auto-start` is removed entirely** (and the
  `ZYZ_AUTO_START_WORKER` env var). It was a defective half-baked launcher: its
  blind `send-keys` did not handle the trust-folder / bypass-risk confirmation
  pages, and its readiness probe was fooled by the confirmation-page menu arrow
  — the root cause of prior first-launch races. Spawn is now container-only and
  never starts claude; the L2 `orch-driver-agent` is the sole launcher and
  handles the confirmation pages and readiness correctly. **Breaking:** any
  caller passing `--auto-start` (a 3rd argument) now gets an argument error
  (exit 2).

## [0.5.2] — 2026-06-20

### Added
- `orchestration-scheduling-task` now self-schedules by default: a bare
  `/orchestrate-tasks <list-dir>` invocation enters "auto-timer mode" and re-arms the
  next tick via in-session `ScheduleWakeup` using the existing 7-branch cadence policy,
  rescheduling with the bare `/orchestrate-tasks <list-dir>` prompt. Previously a bare
  invocation ran a single tick and stopped; only `/loop` wrapping self-scheduled.
- `ZYZ_ORCH_ONCE=1` environment variable: explicit single-shot opt-out that runs one
  tick and returns without self-scheduling. It overrides `/loop` (forces single-shot
  even when wrapped).

### Changed
- Orchestrator startup is now a three-mode precedence (`ZYZ_ORCH_ONCE=1` > `/loop` >
  bare auto-timer default). `/loop` behavior is unchanged. Docs synced across
  `skills/orchestration-scheduling-task/SKILL.md`, `commands/orchestrate-tasks.md`,
  `CLAUDE.md`, and the orchestrator `main-agent.md`. Cadence thresholds and the 7 branch
  anchors are unchanged; self-scheduling uses in-session `ScheduleWakeup` only — no cron,
  no background process, no new file protocol.

## [0.5.1] — 2026-06-20

### Changed
- Semantic upgrade of the implementation vocabulary across the live `execute-task`
  and orchestration surface, reflecting that the implementation role does more than
  write code (it writes prompts, configuration, scripts, static files, and manifest edits).
- Renamed the implementation subagent to `implementation-agent` (both `agents/` and
  `subagents/` copies), including frontmatter `name:`, the camelCase role token in prose,
  and every reference across skills, prompts, templates, commands, and docs.
- Rewrote the `implementation-agent` prompt so its description and artifact wording express
  "implement a task's engineering work" rather than "write code".
- Lifted the workflow phase value to `implementation` across the cross-process phase
  contract (worker-status template, `execute-task` orchestrated-mode field list and
  phase-mapping table, orchestration skill, the 3 agent-prompt enums, and the mock-worker
  test) and across all phase-word prose, headings, and the implementation status-template
  section.
- Renovated the historical design docs under `docs/design/` to the current `execute-task`
  / implementation vocabulary; the older skill-design doc was renamed to
  `docs/design/execute-task-skill-design.md`, and the `/code-development` alias
  mention is retained.

## [0.5.0] — 2026-06-18

### Added
- `orchestration-scheduling-task` skill: scan a master task list, analyze dependencies,
  dispatch parallel tmux/git-worktree workers running `execute-task`, aggregate state
  via files, gate merges on user approval. Includes 6 bash helpers under `scripts/orch-*.sh`,
  slash command `/orchestrate-tasks`, 3 templates, and a full real-tmux integration test suite.
- `execute-task` orchestrated mode: triggered when `ZYZ_WORKER_STATUS_FILE` is set;
  workers self-report `phase` and `wait-state` to a status file the orchestrator reads.
- `docs/conventions/long-running-state.md`: plugin-wide convention that long-running
  tasks must persist progress, decisions, blockers, and next steps to files; context
  windows handle execution only.
- Master entry frontmatter `source-repo:` field (stage C): required, absolute or `~/`-prefixed,
  per-task. Lets one orchestrator dispatch workers across multiple repos from any cwd.
- `scripts/pack.sh`: reads version from `.claude-plugin/plugin.json` and produces
  `dist/zyz-worker-<version>.zip` for local plugin loading or marketplace upload.

### Changed
- Renamed `code-development` skill to `execute-task` (stage A). `/code-development`
  remains as a permanent alias of `/execute-task`; both share a single body.
- `orch-spawn-worker.sh` exit-code precedence reordered to `2 → 4 → 5 → 3 → rest` so
  source-repo validation negative tests can run on tmux-less hosts.
- `<project>` master-entry label now defaults from `basename "$SOURCE_REPO"` when
  omitted, instead of cwd basename (stage C bug fix).
- README opening rewritten to the user's intended preamble; all sections refreshed
  to reflect post-rename and orchestration capability.
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` keywords now
  include both `code-development` (legacy) and `execute-task` (current).

### Removed
- Placeholder `skills/zyz-worker/` removed (stage A; never had behavior).

### Fixed
- Stage C: orchestrator was previously cwd-locked to a single project's git work
  tree via `git rev-parse --show-toplevel`. Now fully cwd-independent.

## [0.4.0] — 2026-06-12

> (reconstructed from commit history; not exhaustive — authoritative source is `git log v0.4.0..v0.5.0`.)

### Added
- `code-development` skill (later renamed to `execute-task`): design-first code
  development workflow with main-agent prompt, code-agent / test-agent / review-agent
  subagents; design / status / final-report / review-report templates.
- `git-worktree` skill: default worktree path `~/.zyz-worker/worktrees/${repo}/${branch}`
  plus `add / list / remove / lock / unlock / prune / repair` sub-commands.
- "Total-goal fidelity" workflow rule: agents must not unilaterally reduce a task's
  scope; any deviation requires explicit user approval.
- "Incremental output" delivery technique: SubAgents may stream partial results
  across multiple tool turns for stability; never lets them defer or simplify
  the requested scope.
- "Autonomous VCS policies" for the design review / accept / reject loop:
  default to automatic decision making with documented escalation thresholds.

### Changed
- Split the design document into multiple files when the design is complex
  (introduced in 0.3.1, formalized here).

[Unreleased]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/somePeopleFireAndWood/zyz-worker/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/somePeopleFireAndWood/zyz-worker/commits/v0.4.0
