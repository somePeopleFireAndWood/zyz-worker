# Review Report

## Scope

<!-- Include the reviewed files' mtimes/hashes recorded at review START and re-checked at FINISH. If any changed mid-review, this report is VOID — report for re-dispatch, do not patch findings. Do not sign off on a moving target. -->

## Coverage Dimensions

(Register EVERY dimension before this review counts as closed. Each is either
`covered` — you actually examined it and its findings are in `## Findings` —
or `not-covered: <concrete reason>`. An unregistered or silently omitted
dimension means the review is NOT closed, regardless of the `Result` below.
This mirrors the per-category registration for aggregate testing: it is a
registration requirement, not a must-cover-everything requirement.)

For a design-phase review (no implementation or tests exist yet), the
implementation-oriented dimensions are registered `n/a: design phase`.

- Design Conformance: (covered | not-covered: <reason>) — checked in BOTH directions element by element: nothing the design requires is missing, nothing contradicts it. Name the design section and the `file:line` for each divergence; divergences are BLOCKING.
- Correctness: (covered | not-covered: <reason> | n/a: design phase)
- Test Quality: (covered | not-covered: <reason> | n/a: design phase)
- Regression Risk: (covered | not-covered: <reason> | n/a: design phase)
- Risk-Specific: (one line per dimension the design `## Risks` calls out — e.g. performance, capacity, security, data migration — each covered | not-covered: <reason>; or `n/a: no such risk recorded`)

## Result

- Status: (`changes-requested` exactly when at least one finding below is `blocking`; otherwise `no-changes-needed`)
- Reviewer: (`reviewAgent`, or `cross-harness:<harness>` for a cross-harness review session)

## Findings

<!-- Numbered, ordered by severity. Numbering feeds the main agent's finding ledger and ## Next Review Input below. -->

<!-- Every review kind: label each finding with its tier (see reviewAgent `## Finding Tiers` and SKILL.md `## Review Convergence`), judged against the design's `## Scope Boundary`:
     - `blocking` — reachable on an input the declared domain or a current caller produces; name the path (caller file:line or domain clause).
     - `non-blocking:normal` — a real improvement, no wrong behavior on any reachable input. A design-document finding whose ONLY consequence is that a future editor of the document might be misled is this tier (reviewAgent `### Document-Hygiene Findings Are Non-Blocking`); its destination is the review-history file, not an edit to the design body.
     - `non-blocking:contrived` — only outside the declared domain (2+ stacked unnatural changes, or an adversarial object/state no in-domain input produces) AND no current caller reaches it. Carry: a minimal reproduction, the enumerated callers, and any hardening plan with how you verified it. Variants of one class are ONE finding.
     Add `recurring: <class> (rounds …)` to a new variant of a class already fixed at this review point, with what a class-level fix would cover.
     Non-blocking findings do not hold back `no-changes-needed`. Reachability into the artifact is the dividing line, not severity of wording or strangeness of the construction. A tier is a verdict, NOT a license to report less: every finding still appears here with its own evidence. -->

## Independent Reproduction

<!-- Which of the author's verdicts you re-derived by running the decisive checks read-only, and how your own probe aligned against the author's recorded output (byte-for-byte before use as a criterion). A review that only audits the report co-signs the author's tool failures. n/a for a design-phase review. -->

## Injected Mutations

<!-- Complementary-surface mutations you injected (your own targets, not the author's): each with target, expected-red cases, KILLED/SURVIVED — and the restoration verification: per-file `cmp` against the backup copy you took BEFORE mutating. NOT "git status clean" — a shared worktree carries other agents' legitimate in-flight edits, and NEVER restore via git checkout/restore (resets to HEAD, destroys others' uncommitted work). n/a for a design-phase review. -->

## No-Op Assertion Checklist

<!-- All eight forms (see reviewAgent ## No-Op Assertion Checklist), each answered with the evidence read (file:line + actual predicate). Batching into "the rest are fine" is prohibited — these forms are precisely the ones careful reading does not catch. n/a for a design-phase review. -->

## Required Changes

## Suggestions

## Rejected Suggestions Reviewed

## Residual Risk

<!-- The non-blocking findings this round leaves behind, each written as a residual-risk register entry (`templates/residual-risks.md` fields: tier and class, reproduction, impact — why nothing in-domain reaches it and what would make it reachable — hardening plan or `none proposed`). Items already in the register are referenced by entry id, not repeated. -->

## Next Review Input

<!-- Include the numbered findings expected to have LANDED by the next review, so the next pass verifies landing instead of assuming it. List the BLOCKING findings here. Add the `non-blocking:normal` findings the main agent chose to land in the one extra normal-fix round, if it opens one. Every other non-blocking finding is recorded instead: in the review-history file for a design-document finding, in the residual-risk register for behavior or tests. Those findings are not going to land, so listing them would make the next pass verify a landing that was never intended and re-raise it every round. Name them separately as "recorded, not landing". -->
