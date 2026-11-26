#!/usr/bin/env bash
#
# review-round.sh — the main agent's review-round ledger (design §10.4).
#
# How many rounds a review point may run, and when a strict-tier point owes a
# convergence check, used to live only in prompts and was mostly not done
# (one design ran 14 rounds until the user stopped it). This script records
# every round and refuses the ones the tier does not allow; review-gate.sh
# then refuses a review-agent dispatch that no recorded round backs. Run by
# the MAIN agent in its own Bash (never by a subagent). Writes only the
# `## 评审收口` rows and the `- Tier:` line of <task-dir>/status.md (plus
# <task-dir>/log/tier.md), atomically, after validating every input.
#
# Usage:
#   review-round.sh open <point> --stage design|impl|aggregate [--kind main|aux]
#                   [--tier standard|strict [--by user]]
#             --tier gives this point a stricter tier than the task's; on an
#             open point it re-tiers it (up only; back down needs --by user).
#             Opening a closed point starts a new set of records.
#   review-round.sh start <point> [--full --reason <text>]
#             prints `round=<n> mode=full|incremental cross-harness=yes|no`;
#             --full forces a full re-review (after a structural fix; counts
#             as a round like any other). Exit 3 with the next step when the
#             round is not allowed (cap reached without a grant -> hand to the
#             user; strict tier without a convergence check -> run `check`;
#             last round has no result; point closed).
#   review-round.sh result <point> --blocking N [--behavior M]
#             M = accepted blocking findings of this round that change product
#             behaviour (M <= N).
#   review-round.sh grant <point> --reason <text>
#             the user approved ONE extra round (the next one).
#   review-round.sh check <point> --outcome continue|class-fix|reorder|escalate --reason <text>
#   review-round.sh close <point> --outcome passed|residual|split [--by user] --reason <text>
#             passed: the latest round has a result with blocking=0;
#             residual / split: the user's choice at the cap, --by user.
#   review-round.sh tier fast|standard|strict --reason <text> [--by user|agent]
#             a downgrade needs --by user.
#   review-round.sh status [<point>]
#             ends with `unclosed: …` or `all review points closed` (delivery
#             requires every registered point closed).
#   <point>: [a-z0-9-]+, e.g. design-main, design-replay, impl-st2, aggregate.
#   --task <task-dir> picks the task; default is this session's primary task
#   (the first line of its task pointer, as for expect.sh).
#
# Caps (total rounds per point, first included):
#             design  impl  aggregate
#   fast        0      2       1
#   standard    2      3       3
#   strict      -      -       -     (a Review-Check before rounds 4, 7, 10, ...)
# A task without a valid `- Tier:` line (from before the tiers) is recorded
# without a cap.
#
# Exit: 0 ok; 2 invalid input; 3 refused by the round rules (stdout says what
# to do next).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || { echo "review-round: cannot load lib.sh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "review-round: python3 is required" >&2; exit 2; }

task=""
args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --task) task="${2:-}"; shift 2 || { echo "review-round: --task needs a dir" >&2; exit 2; } ;;
        *) args+=("$1"); shift ;;
    esac
done
if [ "${#args[@]}" -eq 0 ]; then
    sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

if [ -z "$task" ]; then
    task="$(zyz_task_root "$PWD")"
    if [ -z "$task" ]; then
        echo "review-round: no task pointer resolves for this session — run task-pointer.sh arm <task-dir> first, or pass --task <task-dir>" >&2
        exit 2
    fi
fi
[ -d "$task" ] || { echo "review-round: task dir not found: $task" >&2; exit 2; }
[ -f "$task/status.md" ] || { echo "review-round: $task/status.md does not exist" >&2; exit 2; }

ZYZ_REVIEW_ROUND_CLI="$(zyz_review_round_cli)" \
    exec python3 "$SCRIPT_DIR/review_round.py" "${args[0]}" "$task/status.md" "${args[@]:1}"
