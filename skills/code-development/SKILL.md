---
name: code-development
description: Use when the user wants help completing a code development task with a design-first workflow, a user-facing main agent, prompt-only subagents, task status tracking, implementation, tests, review, and final delivery.
---

# Code Development

Use this skill to help a user complete a code development task. The workflow is design-first, user-led during design, and coordinated by the current conversation agent using a main-agent prompt plus prompt-only subagent roles.

This skill does not require hooks, scripts, MCP servers, background services, or a real subagent runtime. The main-agent prompt applies to the current user-facing conversation agent. If the current agent environment can launch subagents, use the prompts in `../../subagents/` for codingAgent, testAgent, and reviewAgent. If it cannot, use those files as role instructions and preserve the same responsibility boundaries in the conversation.

## Prompt Files

Load these files only when their role is needed:

- Main agent controller prompt: `prompts/main-agent.md`
- codingAgent: `../../subagents/coding-agent.md`
- testAgent: `../../subagents/test-agent.md`
- reviewAgent: `../../subagents/review-agent.md`

Use these templates when creating task artifacts:

- Design document: `templates/design-doc.md`
- Task status: `templates/task-status.md`
- Final report: `templates/final-report.md`
- Review report: `templates/review-report.md`

## Core Rules

- The user leads design. The agent helps clarify, structure, document, and execute.
- Every code task starts with a Markdown design document, regardless of task size.
- The design document is the source of truth for implementation, testing, and review.
- The design document must be clear enough that codingAgent, testAgent, and reviewAgent can proceed without asking the user again unless there is a blocking issue.
- Maintain a task status file for the full workflow: design, coding, testing, review, and delivery.
- Use existing installed skills, plugins, or tools when they improve document or code quality, but never require the user to install missing optional capabilities.
- Prefer continuing through non-blocking ambiguity with documented assumptions. Stop and ask the user only when continuing would risk data loss, irreversible changes, or a serious mismatch with the design.

## Role Boundaries

The main agent is the current user-facing conversation agent. It coordinates and records. It must not directly write implementation code, modify tests, run tests, or perform review.

codingAgent writes implementation and runs tests. It must not modify test code.

testAgent writes and maintains test code. It must not run tests.

reviewAgent reviews design, implementation, and tests. It must not modify files directly.

If the platform cannot enforce these boundaries technically, enforce them procedurally by separating role outputs and clearly labeling which role is acting.

## Workflow

### 1. Start Task

1. Create or identify a task id.
2. Create a task directory, preferably `.zyz-worker/tasks/<task-id>/`.
3. Create a status file from `templates/task-status.md`.
4. Record the task name, phase, known inputs, open questions, and current assumptions.

### 2. Design

1. Work with the user to produce a Markdown design document from `templates/design-doc.md`.
2. Ask the user about unclear requirements, constraints, non-goals, acceptance criteria, risky implementation details, and important tests.
3. When the design draft is ready, use reviewAgent to review it.
4. Present every review suggestion to the user.
5. Let the user accept the suggestion or reject it with a reason.
6. Update the design document and status file.
7. Repeat review until reviewAgent says no changes are needed.
8. Ask the user for final human approval before coding.

Do not enter coding until both reviewAgent and the user approve the design.

### 3. Coding And Testing

1. Provide codingAgent and testAgent with the design document path and task status summary.
2. Have codingAgent implement the engineering changes.
3. Have testAgent write or update tests from the design document.
4. If codingAgent finds missing test points, it reports them to the main agent.
5. The main agent updates the design document and asks testAgent to add the tests.
6. After implementation and tests are ready, codingAgent runs the tests.
7. If tests fail, codingAgent decides whether the failure is an implementation bug or an invalid test.
8. codingAgent fixes implementation bugs.
9. testAgent fixes invalid or incomplete tests.
10. Repeat until tests pass or a blocking issue requires the user.

### 4. Review

1. After tests pass, use reviewAgent to review implementation and test changes.
2. codingAgent handles implementation review findings.
3. testAgent handles test review findings.
4. If a role rejects a review finding, it must provide a concrete reason.
5. Run tests again after any implementation or test change.
6. Repeat review until reviewAgent says no changes are needed.

### 5. Deliver

1. Update the status file with final phase, completed work, test results, review result, assumptions, and known risks.
2. Produce a final report from `templates/final-report.md`.
3. Ask the user whether to delete the task status files.

## Long-Running Work

During long coding phases, the main agent should keep the status file current. Record the active role, latest output, blocked items, next action, and restart notes.

If a subagent is stuck, interrupted, or silent for too long, the main agent should restart that role if the platform supports it. If no real subagent runtime exists, resume from the status file and re-issue the relevant role prompt with the latest design and status summary.

## Optional Skills And Plugins

Before writing design docs, implementation, tests, or review reports, check whether the current agent already has relevant skills, plugins, or tools available.

Examples:

- Use documentation skills or plugins, such as llmdoc, to improve design document quality if already available.
- Use engineering workflow skills or plugins, such as superpowers, to improve implementation or review quality if already available.
- Use language, framework, testing, browser, document, or spreadsheet skills when the task naturally needs them.

Do not block, fail, or ask the user to install anything when these optional capabilities are unavailable.

When optional capabilities are used, record them briefly in the task status file or final report.
