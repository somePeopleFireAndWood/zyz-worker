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
encoded-cwd: <"/"→"-" form of pwd -P of worktree>
                                  # used to locate ~/.claude/projects/<encoded-cwd>/
claude-pid:                       # Phase-2; filled by orch-check-worker.sh
claude-session-id:                # Phase-2; filled by orch-check-worker.sh
transcript-path:                  # Phase-2; filled by orch-check-worker.sh
first-seen-iso:                   # Phase-2; set when the trio above first completes
---

# Dispatch Info

<!--
  dispatch.md template
  ====================

  Writer (Phase-1): orch-spawn-worker.sh, as the LAST step of its preflight
  (immediately before the optional auto-start `claude` send-keys). The Phase-1
  fields are deterministic and never empty:
    task-id, spawn-iso, tmux-session, tmux-window-id, tmux-pane-id, shell-pid,
    worktree, source-repo, branch, base, plugin-root, encoded-cwd.
  dispatch.md presence therefore means "spawn ran preflight to completion"
  (or a pre-feature spawn). Absence means a pre-feature spawn OR a crash
  mid-preflight.

  Writer (Phase-2): orch-check-worker.sh, lazily, on subsequent polls. It fills:
    claude-pid          — newest direct child of shell-pid named `claude`
    claude-session-id   — .sessionId from ~/.claude/sessions/<claude-pid>.json
    transcript-path     — ~/.claude/projects/<encoded-cwd>/<claude-session-id>.jsonl
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
  set. Until then it holds the placeholder spawn wrote. The generated body
  contains the concrete `tmux attach -t <session>` and
  `cd <worktree> && claude --resume <claude-session-id> --plugin-dir <plugin-root>`
  recovery commands (all <…> tokens substituted with real values; no angle
  brackets remain in the rendered body).
-->

(awaiting claude startup; orch-check-worker.sh populates this on the first poll where claude has registered AND first LLM round-trip has produced a transcript)
