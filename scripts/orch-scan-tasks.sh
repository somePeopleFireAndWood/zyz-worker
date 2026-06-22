#!/usr/bin/env bash
#
# orch-scan-tasks.sh — list every task entry in a master list directory and
# report its current declared `state` (plus phase/wait-state/last-seen for
# in-progress/paused tasks).
#
# Contract:
#   Inputs:
#     $1  <list-dir>           absolute or relative path to the master list directory
#
#   Side effects:
#     None. Read-only.
#
#   Output (stdout):
#     One line per task in <list-dir>/tasks/*.md (excluding README.md / SUMMARY.md).
#     Each line is whitespace-separated key=value pairs:
#       task-id=<id> state=<state> phase=<phase> wait-state=<state> last-seen=<iso-or-dash>
#     Missing fields are reported as `-`.
#     A `state:` field that is missing, unparseable, or not one of
#     (not-analyzed | blocked | ready | in-progress | paused |
#      awaiting-user-confirmation | completed)
#     is reported as `state=not-analyzed`.
#
#   Errors (stderr):
#     Human-readable messages.
#
#   Exit codes:
#     0  success (including empty list)
#     2  argument error / invalid task-id encountered
#     3  missing required dependency (no relevant deps here, but kept for symmetry)
#     4  <list-dir>/tasks/ does not exist or is not readable
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <list-dir>" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

LIST_DIR="$1"

if [ -z "$LIST_DIR" ]; then
    usage
    exit 2
fi

# Dependency check (design §E top: every helper must `command -v tmux git`).
for dep in tmux git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: missing dependency: $dep" >&2
        exit 3
    fi
done

TASKS_DIR="$LIST_DIR/tasks"

if [ ! -d "$TASKS_DIR" ] || [ ! -r "$TASKS_DIR" ]; then
    echo "error: <list-dir>/tasks/ does not exist or is not readable: $TASKS_DIR" >&2
    exit 4
fi

# Extract a single frontmatter field from a markdown file.
# Frontmatter is the block delimited by leading `---` and the next `---`.
# Usage: fm_field <file> <key>
# Prints the value (everything after `key:`), trimmed of leading/trailing
# whitespace and surrounding quotes. Prints empty on miss.
fm_field() {
    local file="$1"
    local key="$2"
    # Use awk to read only the frontmatter block (between the first two `---`).
    awk -v k="$key" '
        BEGIN { in_fm = 0; fence = 0 }
        /^---[[:space:]]*$/ {
            fence++
            if (fence == 1) { in_fm = 1; next }
            if (fence == 2) { exit }
        }
        in_fm == 1 {
            # Match "key:" at start, capture everything after first colon.
            if (match($0, "^[[:space:]]*" k "[[:space:]]*:")) {
                v = substr($0, RSTART + RLENGTH)
                # Strip leading whitespace.
                sub(/^[[:space:]]+/, "", v)
                # Strip trailing whitespace.
                sub(/[[:space:]]+$/, "", v)
                # Strip a trailing inline comment beginning with " #".
                sub(/[[:space:]]+#.*$/, "", v)
                # Strip surrounding single or double quotes.
                if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
                else if (v ~ /^'\''.*'\''$/) { v = substr(v, 2, length(v) - 2) }
                print v
                exit
            }
        }
    ' "$file"
}

is_legal_task_id() {
    # task-id whitelist: [A-Za-z0-9_-]+
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_legal_state_value() {
    case "$1" in
        not-analyzed|blocked|ready|in-progress|paused|awaiting-user-confirmation|completed) return 0 ;;
        *) return 1 ;;
    esac
}

# Sort the file list to make output deterministic.
shopt -s nullglob
files=("$TASKS_DIR"/*.md)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
    # Empty list is a normal outcome.
    exit 0
fi

# Sort the files for stable output.
IFS=$'\n' read -r -d '' -a sorted_files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort && printf '\0') || true

for f in "${sorted_files[@]}"; do
    base="$(basename "$f")"
    # Skip housekeeping files.
    case "$base" in
        README.md|SUMMARY.md) continue ;;
    esac

    # task-id is the basename without `.md`; fall back to frontmatter if needed.
    fname_id="${base%.md}"
    fm_id="$(fm_field "$f" task-id)"
    task_id="${fm_id:-$fname_id}"

    if ! is_legal_task_id "$task_id"; then
        echo "error: illegal task-id '$task_id' in $f (must match [A-Za-z0-9_-]+)" >&2
        exit 2
    fi

    state="$(fm_field "$f" state)"
    if [ -z "$state" ] || ! is_legal_state_value "$state"; then
        state="not-analyzed"
    fi

    last_seen="$(fm_field "$f" last-seen)"
    [ -z "$last_seen" ] && last_seen="-"

    phase="-"
    wait_state="-"

    if [ "$state" = "in-progress" ] || [ "$state" = "paused" ] || [ "$state" = "awaiting-user-confirmation" ]; then
        ws_file="$LIST_DIR/runtime/$task_id/worker-status.md"
        if [ -f "$ws_file" ] && [ -r "$ws_file" ]; then
            p="$(fm_field "$ws_file" phase)"
            ws="$(fm_field "$ws_file" wait-state)"
            [ -n "$p" ] && phase="$p"
            [ -n "$ws" ] && wait_state="$ws"
        else
            phase="unknown"
            wait_state="unknown"
        fi
    fi

    printf 'task-id=%s state=%s phase=%s wait-state=%s last-seen=%s\n' \
        "$task_id" "$state" "$phase" "$wait_state" "$last_seen"
done

exit 0
