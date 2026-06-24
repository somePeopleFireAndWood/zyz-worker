---
task-id: <task-id>
spawn-iso: <iso>                   # ISO timestamp of when spawn wrote this file
tmux-session: <session name>      # e.g. zyz-task-<task-id>
tmux-window-id: <e.g. @4>         # snapshot at spawn time; may go stale if the
                                  # user manually adds/removes windows
tmux-pane-id: <e.g. %6>           # snapshot at spawn time; may go stale
shell-pid: <int>                  # pane shell pid; parent of the claude process
worktree: <absolute path>         # the git worktree the worker runs in
source-repo: <absolute path>      # the project git work tree the worktree was cut from
branch: <branch name>             # the task branch
base: <base branch>               # base the branch was created from
plugin-root: <absolute path>      # passed as `claude --plugin-dir` on resume
encoded-cwd: <claude-projects-dir form of pwd -P of worktree>
                                  # both "/" and "." -> "-", then consecutive
                                  # "-" squeezed; matches ~/.claude/projects/<dir>.
                                  # Diagnostics only — transcript discovery is by
                                  # session-id (see Phase-2 note below).
reuse-from:                       # Phase-1; empty = plain spawn (orch-spawn-worker.sh),
                                  # non-empty = the old task-id whose container this task
                                  # reuses (orch-reuse-worker.sh). Snapshot of the new task's
                                  # master-entry `reuse-from`; the master entry is the
                                  # authoritative source — this is a derived copy for the
                                  # driver + crash recovery.
reuse-scope:                      # Phase-1; worktree | tmux | both | (empty for plain spawn)
reuse-claude-effective:           # Phase-1; true | false | n/a (n/a under worktree scope, where
                                  # it is always a new claude). Drives the reuse-aware
                                  # `## Recovery` body below and the L2 reuse-dispatch branch.
heartbeat-window-id:              # Phase-1; the tmux window id of the same-session new-window
                                  # heartbeat daemon (same-claude reuse only); empty for plain
                                  # spawn / new-session reuse. DIAGNOSTICS ONLY — cleanup kills
                                  # the whole session and orch-heartbeat-daemon.sh's
                                  # `tmux has-session` watchdog tears this window's daemon down
                                  # with it. Do NOT derive kill logic from this field.
claude-pid:                       # Phase-2; filled by orch-check-worker.sh
claude-session-id:                # Phase-2; filled by orch-check-worker.sh
transcript-path:                  # Phase-2; filled by orch-check-worker.sh
first-seen-iso:                   # Phase-2; set when the trio above first completes
---

# Dispatch Info

<!--
  dispatch.md template
  ====================

  Writer (Phase-1): orch-spawn-worker.sh (plain spawn) OR orch-reuse-worker.sh
  (container reuse), as the LAST step of preflight. Both are container-only —
  they never start claude (the L2 orch-driver-agent is the sole launcher). The
  Phase-1 fields are deterministic and never empty:
    task-id, spawn-iso, tmux-session, tmux-window-id, tmux-pane-id, shell-pid,
    worktree, source-repo, branch, base, plugin-root, encoded-cwd.
  The four reuse fields (reuse-from, reuse-scope, reuse-claude-effective,
  heartbeat-window-id) are ALSO Phase-1: empty for a plain spawn, populated for
  a reuse. Both writers emit the same field set, so check's Phase-2 rewrite has
  one fixed key list to preserve.
  dispatch.md presence therefore means "spawn/reuse ran preflight to completion"
  (or a pre-feature spawn). Absence means a pre-feature spawn OR a crash
  mid-preflight.

  Writer (Phase-2): orch-check-worker.sh, lazily, on subsequent polls. It fills:
    claude-pid          — newest direct child of shell-pid named `claude`
    claude-session-id   — .sessionId from ~/.claude/sessions/<claude-pid>.json
    transcript-path     — ~/.claude/projects/<dir>/<claude-session-id>.jsonl,
                          discovered by session-id (a unique UUID) via
                          `find ~/.claude/projects -name "<sid>.jsonl"`, NOT by
                          reconstructing <dir> from encoded-cwd
                          (only once that file actually exists)
    first-seen-iso      — set on the poll where all three above first become set
  These stay empty until claude registers and the first LLM round-trip writes a
  transcript. Once a Phase-2 field is non-empty, no later poll rewrites it
  (idempotent). A user can force a re-bind by clearing the Phase-2 fields.

  Reader: the orchestrator (and the human operator, for crash recovery —
  `cat`/`less` this file to see the `## Recovery` commands below).

  Write atomically (tmpfile + rename). Never edit in place.

  Lifecycle: archived (not deleted) by orch-cleanup-worker.sh /
  orch-merge-and-cleanup.sh as part of the wholesale move of
  runtime/<task-id>/ into runtime/.archive/<task-id>-<ts>/.

  See `docs/conventions/long-running-state.md` and the orchestration SKILL.md
  `## Crash Recovery` section.
-->

## Recovery

<!--
  Populated by orch-check-worker.sh the first time all three Phase-2 fields are
  set. Until then it holds the placeholder spawn/reuse wrote. The generated body
  is reuse-aware (three-way), based on the stored reuse-from / reuse-claude-effective:
  - plain spawn (reuse-from empty) and independent reuse sessions
    (reuse-claude-effective in {false, n/a}): the concrete `tmux attach -t <session>`
    and `cd <worktree> && claude --resume <claude-session-id> --plugin-dir <plugin-root>`
    recovery commands;
  - same-claude reuse (reuse-from set AND reuse-claude-effective=true): an
    ATTACH-ONLY body — `tmux attach -t <session>` only, with an explicit warning
    NOT to run an independent `claude --resume` (the session-id is the shared
    old+new session; resuming it from two dispatch.md files is a footgun).
  All <…> tokens are substituted with real values; no angle brackets remain in
  the rendered body.
-->

(awaiting claude startup; orch-check-worker.sh populates this on the first poll where claude has registered AND first LLM round-trip has produced a transcript)
