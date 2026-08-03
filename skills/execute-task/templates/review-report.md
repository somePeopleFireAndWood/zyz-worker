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

- Design Conformance: (covered | not-covered: <reason>)
- Correctness: (covered | not-covered: <reason> | n/a: design phase)
- Test Quality: (covered | not-covered: <reason> | n/a: design phase)
- Regression Risk: (covered | not-covered: <reason> | n/a: design phase)
- Risk-Specific: (one line per dimension the design `## Risks` calls out — e.g. performance, capacity, security, data migration — each covered | not-covered: <reason>; or `n/a: no such risk recorded`)

## Result

- Status:
- Reviewer:

## Findings

<!-- Numbered, ordered by severity. Numbering feeds the main agent's finding ledger and ## Next Review Input below. -->

## Independent Reproduction

<!-- Which of the author's verdicts you re-derived by running the decisive checks read-only, and how your own probe aligned against the author's recorded output (byte-for-byte before use as a criterion). A review that only audits the report co-signs the author's tool failures. n/a for a design-phase review. -->

## Injected Mutations

<!-- Complementary-surface mutations you injected (your own targets, not the author's): each with target, expected-red cases, KILLED/SURVIVED — and the tree-restoration verification (git status clean / empty diff). n/a for a design-phase review. -->

## No-Op Assertion Checklist

<!-- All eight forms (see reviewAgent ## No-Op Assertion Checklist), each answered with the evidence read (file:line + actual predicate). Batching into "the rest are fine" is prohibited — these forms are precisely the ones careful reading does not catch. n/a for a design-phase review. -->

## Required Changes

## Suggestions

## Rejected Suggestions Reviewed

## Residual Risk

## Next Review Input

<!-- Include the numbered findings expected to have LANDED by the next review, so the next pass verifies landing instead of assuming it. -->
