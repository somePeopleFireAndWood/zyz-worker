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
- Tested: (true once this SubTask's tests pass AND every mechanism claimed as covered has a recorded killed mutation — green alone is "ran", not "tested")
- Mutations: (per manifest entry: mechanism → mutation → KILLED/SURVIVED; restore verified byte-identical)
- Reviewed: (true once review-agent reports no changes for this SubTask; rejected findings allowed if reasons are recorded)
- Frozen At: (workspace-freeze timestamp + frozen file set, recorded before review was dispatched — makes `Reviewed: true` traceable to the exact tree it reviewed)
- Committed: (commit sha for this SubTask's autonomous commit, or the failure reason if the commit/push failed — failure is non-blocking. For a multi-repo SubTask that touched more than one worktree, record one `<repo>:<sha>` per line, one line per repo committed. When parallel SubTasks shared assembly files and were committed as one compilable unit, record `shared:<sha> (STx+STy+…)`.)
- SubTask Status File: (path if this SubTask keeps its own status file; optional)
- Rejected Suggestions: (list each rejection with reason, one per line)
- Notes:

Shared-file hotspots: (declared at dispatch time when parallel SubTasks append to the same assembly files — file → lanes → per-lane insertion region; empty when none)

## Parallel Resource Leases

(Mandatory before dispatching ≥2 concurrent lanes that run tests. One row per lane. A DB collision fails loudly; a port collision silently tests someone else's server — hence the full port group including metrics/pprof.)

- agent/lane | ports (HTTP/gRPC/metrics/pprof) | test-db | owns-generated-artifacts (exactly one lane per batch owns rebuilding shared bundles/dist)

## Implementation

- Implementation Status:
- Important Notes:
- Discovered Test Points:

## Testing

- Test Command: (full command incl. parallelism/serialization flags)
- Test Environment: (test DB + port set — the coordinates that make a "green" re-checkable)
- Process/Source Freshness: (started-at of the process under test vs newest source mtime)
- Latest Result: (with executed case/package count vs baseline)
- Attribution: (for any failure: mine / tooling / concurrent-edit / real-regression + the evidence)
- Failing Cases:

## Implementation Review

(Per-finding ledger — "adjudicated", "dispatched", and "landed" must be distinguishable; an accepted finding with `dispatched-to` and `landed` both empty is NOT dispatched, and must be dispatched before requesting any re-review. Reporting a finding as landed when it never was is worse than not fixing it: the next round stops checking.)

- Latest Review Result:
- Findings ledger: (one row per finding: finding | verdict(accept/reject) + evidence | dispatched-to + when | landed(commit/file) | verified-by)
- Required Changes:
- Rejected Suggestions:

## PR Review

(External pull-request review feedback — comments, "changes requested", inline threads, or automated review findings posted on an actual PR. Do NOT blindly accept: process each finding one at a time, independently verify whether the problem objectively exists, then record it here. Every item must end as accepted-and-fixed or explicitly-rejected-with-a-posted-reason — never silently ignored.)

- PR Reference: (URL or number)
- Accepted Findings: (one per line — the finding + how you verified it objectively exists + what changed and where + the acknowledgement posted/thread resolved)
- Rejected Findings: (one per line — the finding + the concrete evidence it does not hold + the PR comment posted declining it)
- Escalated To User: (findings that would change Goals/Acceptance Criteria, or that looped accept↔reject 3+ times)

## Final Aggregate Testing

(Filled at §3.C after all SubTasks or the single no-split iteration complete. Each required category must be registered before delivery — see §4 delivery gate. The category list derives from the design `## Testing Plan` — the lines below are the standing examples, NOT a closed enumeration; add one line per user-named category (frontend tests, per-SDK e2e, …) rather than squeezing it into the nearest slot, and note each layer's structural coverage ceiling in one phrase.)

- Unit: (ran: <result> | skipped: <reason>)
- E2E: (ran: <result> | skipped: <reason>)
- Regression: (ran: <result> | skipped: <reason>)
- Pressure: (ran: <result> | skipped: <reason> | n/a: no perf/capacity risk)
- <design-Testing-Plan category>: (one line per additional category the design names)
- Mutation Evidence: (per category with coverage claims: killed/survived tally, or `none: <reason>`)
- Test Command(s): (with coordinates: DB / ports / process-vs-source freshness)
- Failing Cases:

## Final Aggregate Review

(Filled at §3.C after aggregate testing converges. Coverage dimensions are registered the same way test categories are: each is `covered` or `not-covered: <reason>`. An unregistered dimension means the review is not closed, whatever the verdict says — a review that only reported its worst few findings must not pass as complete.)

- Coverage — Design Conformance: (covered | not-covered: <reason>)
- Coverage — Correctness: (covered | not-covered: <reason>)
- Coverage — Test Quality: (covered | not-covered: <reason>)
- Coverage — Regression Risk: (covered | not-covered: <reason>)
- Coverage — Risk-Specific: (one line per dimension the design `## Risks` calls out, each covered | not-covered: <reason>; or `n/a: no such risk recorded`)
- Outstanding Staged Installments: (none | list each promised-but-not-yet-received installment from `## Restart And Recovery Notes` — an outstanding installment counts as uncovered, not complete)
- Reviewer Verdict:
- Cross-SubTask Findings:
- Required Changes:
- Rejected Suggestions:

## Restart And Recovery Notes

(Append-only EVENT LIST — one row per timeout/interruption/restart, never a single-slot form; long multi-lane runs hit many. Restarts are continuations: inventory what the interrupted role already left on disk BEFORE re-dispatching, and assume an interrupted run left dirty data that needs cleaning — stale fixture rows reproduce stably and masquerade as regressions.)

- when | role | reason | artifacts already on disk (from `git status` + lease table) | resume-point | cleanup done

## Pre-Delivery Checklist

(Answer EVERY item before §4 delivery — per item, with evidence; an unanswered item blocks delivery the same way an unregistered test category does. Batching into "the rest are fine" is prohibited. Items marked (∥) apply only when ≥2 lanes ran concurrently.)

A. Test effectiveness
1. Every mechanism claimed covered has a killed mutation on record (mutate → red → restore byte-identical)? List them. An unevidenced "covered" claim does not stand.
2. Every mutation has positive evidence it REACHED the code under test (sentinel/log/probe)? For each survived mutation, the five causes ruled out one by one: lucky input / redundant arm / assertion unrelated to mechanism / mutation missed the mechanism / fixture gives both sides the same value?
3. Every assertion's expected value comes from an independent anchor (recorded real-system output), not from the same rule the code under test uses?
4. Every classification arm has a violable expectation (not just total-classification)?
5. Bidirectional rules guarded in both directions?
6. Guard/counter assertions proven able to go red (before/after delta, event forced once)?
7. "What these tests do NOT prove" written down with the mechanism-level reason and the layer that could prove it?

B. Verdict hygiene
8. Every pipeline verdict takes its exit code from the judged segment (no `cmd | head && echo OK`)?
9. No grep-as-success-proof; failures enumerated from structured output with totals cross-checked (pass + skip = total)?
10. Every `ran:` result reports executed case/package count vs baseline?
11. Every grep-count used as evidence had its matched lines read, not just `-c`?
12. No shell builtin/reserved names as variables; failure messages carry raw observed values, not only counts?

C. Environment and coordinates
13. Every "green" reported with all four coordinates (full command / test DB / port group / process-start vs source-mtime)?
14. (∥) Each lane held an exclusive full port group (incl. metrics/pprof) and its own test DB, and positively confirmed it was talking to its own instance?
15. Long-lived processes under test started AFTER the newest source file; restarts did kill-group → port-vacant poll → health check → no stale-binary reuse?
16. Any state changed via non-production write paths (raw SQL / direct file / cache poke) had the paired production invalidation performed (advance seq / emit event / clear key)?
17. (∥) Full-suite greens carry before-and-after compile-cleanliness checks (tree not swapped mid-run)?
18. Interrupted runs' dirty data cleaned before rerun?

D. Attribution and collaboration
19. Every failure attributed in order (change-surface causality → tooling → concurrent edit → real regression), rerun used only to prove flakiness, never innocence?
20. Any "their package is broken" report carries the mtime observation or the owner's confirmation?
21. After a second failed hypothesis-fix on the same failure, switched to printing intermediates inside the failing artifact?
22. Finding ledger scanned: no accepted finding with empty `dispatched-to`?
23. (∥) Reviews were against frozen workspaces; reviewed-file mtimes/hashes matched before and after each review?

E. Scope and self-disclosure
24. Every rule established this round swept across ALL same-shaped sites with an enumerated per-site verdict list (enumerate the outbound surface, don't recall handled instances)?
25. Any comments claiming coverage/invariants updated to match what the code now actually does?
26. `## Weakest Link` filled in — most-likely no-op spot, why suspected, current guard, more direct observation point (or why this is the observation ceiling)?

## Next Actions

- Next:
