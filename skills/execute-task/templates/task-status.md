# Task Status

This is the single mandatory overall task status file. Each SubTask may optionally keep its own SubTask-status file; this overall file must always exist and stay current.

## Metadata

- Task ID:
- Task Name:
- Design Document:
- Current Phase:
- Created At:
- Updated At:

## Total Goal

(Record the user's full, final target verbatim or as a faithful summary. The overall task must end fully meeting this. Do not narrow, defer, or replace any part of it with a placeholder at the overall-task level.)

## Progress

- Completed:
- In Progress:
- Pending:
- Blocked:

## User Decisions

- Decision:
- Reason:

## Agent State

- Main Agent:
- implementationAgent:
- testAgent:
- reviewAgent:

## Optional Capabilities Used

- Capability:
- Used For:

## Design Review

- Latest Review Result:
- Open Issues:
- Rejected Suggestions:
- Design Approval Record: (before entering implementation, record ONE of: (a) the explicit user approval — what the user said + when/where; or (b) the verbatim explicit prior skip instruction authorizing skipping THIS design→implementation gate. Empty means NOT approved — do not enter implementation. A material change to the approved approach re-arms the gate and requires a fresh entry here.)

## SubTasks

(Fill only when the main agent splits the task into SubTasks. Leave empty otherwise.)

Each SubTask may optionally have its own SubTask-status file tracking its implementation, test, review, and auto-fix progress. Record that file's path in the SubTask's `Notes` when one exists. Update this scoreboard whenever a SubTask completes — do not leave progress only in the conversation.

Per-SubTask scoreboard:

- SubTask ID:
- Summary:
- Coded: (true once implementation is complete)
- Tested: (true once this SubTask's tests pass)
- Reviewed: (true once review-agent reports no changes for this SubTask; rejected findings allowed if reasons are recorded)
- Committed: (commit sha for this SubTask's autonomous commit, or the failure reason if the commit/push failed — failure is non-blocking. For a multi-repo SubTask that touched more than one worktree, record one `<repo>:<sha>` per line, one line per repo committed.)
- SubTask Status File: (path if this SubTask keeps its own status file; optional)
- Rejected Suggestions: (list each rejection with reason, one per line)
- Notes:

## Implementation

- Implementation Status:
- Important Notes:
- Discovered Test Points:

## Testing

- Test Command:
- Test Environment:
- Latest Result:
- Failing Cases:

## Implementation Review

- Latest Review Result:
- Required Changes:
- Rejected Suggestions:

## Final Aggregate Testing

(Filled at §3.C after all SubTasks or the single no-split iteration complete. Each required category must be registered before delivery — see §4 delivery gate.)

- Unit: (ran: <result> | skipped: <reason>)
- E2E: (ran: <result> | skipped: <reason>)
- Regression: (ran: <result> | skipped: <reason>)
- Pressure: (ran: <result> | skipped: <reason> | n/a: no perf/capacity risk)
- Test Command(s):
- Failing Cases:

## Final Aggregate Review

(Filled at §3.C after aggregate testing converges.)

- Reviewer Verdict:
- Cross-SubTask Findings:
- Required Changes:
- Rejected Suggestions:

## Restart And Recovery Notes

- Restarted Role:
- Reason:
- Recovery Input:
- Next Action:

## Next Actions

- Next:
