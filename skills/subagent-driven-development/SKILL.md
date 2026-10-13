---
name: subagent-driven-development
description: Use when executing implementation plans with independent tasks in the current session, including whenever a plan header or sdd-orca:writing-plans asks for subagent-driven development
---

# Subagent-Driven Development (workflow-run)

This skill runs the SDD v6 loop as the `sdd-orca:sdd-run` workflow. The workflow does all of the following:

1. preflight and conflict scan;
2. per-task briefs;
3. implementation, either by tiered Claude implementers or by the Devin CLI;
4. a spec + quality review for each task;
5. fixes, with escalation;
6. adjudication of plan conflicts and capped findings;
7. one whole-branch review and one verification.

It uses this skill's own scripts and prompt templates. The session only sets up, starts the run once, and reads one compact result.

Running the loop inside a workflow keeps per-task reports and diffs out of the session's context. That context is otherwise re-read on every turn.

Invoking this skill is the user's opt-in to running the `sdd-orca:sdd-run` workflow for this plan.

## Steps

1. **Workspace.** Use sdd-orca:using-git-worktrees to create or verify an isolated workspace. Never start on main/master without the user's explicit consent. Note the worktree's absolute path.
2. **Arguments.**
   - `plan`: the plan path.
   - `cwd`: the worktree's absolute path.
   - `base`: the branch this work will merge into (usually `main`).
   - `spec`: include it when the plan names one.
   - `verify`: the repository's committed check command, from AGENTS.md / CLAUDE.md / Makefile / package scripts. Omit it when there is none.
   - `sddDir`: `${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development`.
   - `implementer`: add `"devin"` only when the user asked for Devin and `sdd-devin` is set up (see below).
3. **Start.** Call the Workflow tool with `name: "sdd-orca:sdd-run"` and those `args`. If that name does not resolve, use `scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/sdd-run.js"`.
   - The ledger skips tasks that are already complete, so a rerun of the same plan resumes on its own.
   - Pass `from` or `only` only when the user asks.
   - After a crash in the same session, pass `resumeFromRunId`.
4. **Wait.** You are re-invoked when the workflow finishes. Do not sleep, poll or re-read its progress; `/workflows` shows live progress to the user.
5. **Report from the result.**
   - **Ledger repair:** if `ledgerPending` is non-empty, append those lines to the ledger yourself first. Replace each `{REF:<ref>}` with `git rev-parse --short <ref>`.
   - **Stopped:** give the task, the reason and the ledger path. Ask the user only when the reason is destructive, security-sensitive, a side effect outside the worktree, or a plan so broken that every path forward is a guess.
   - **Rulings I made:** run `grep -n 'Ruling:' <ledger>` and paste every line verbatim, in order. These are the decisions taken on the user's behalf. Never summarize them.
   - **Final review:** `final.ready`, each `final.residual` line, the `declined` list, the verify result with its summary, and `deferredMinors`.
6. **Finish.**
   - If `final.ready` and verification passed (or no verify command was set), delete the plan workspace (`rm -rf <workspace>`).
   - In the same case, delete the private range refs: `git for-each-ref --format='%(refname)' <refs> | xargs -r -n1 git update-ref -d`.
   - Then use sdd-orca:finishing-a-development-branch.
   - Otherwise keep both the workspace and the refs, and present the residuals.

## Devin as the implementer

With `implementer: "devin"`, transcribe- and integrate-tier tasks and their early fix rounds run on the Devin CLI. Design-tier tasks, the escalated last fix round, every review and the final fix wave stay on Claude.

A small Claude agent drives the plugin's `sdd-devin` wrapper. The wrapper writes Devin's prompt itself, runs `devin -p` as a detached job, and the agent waits on it.

Requirements:
- the `devin` CLI is installed and logged in;
- the user has opted in to the allow rule `Bash(sdd-devin:*)` (for example with `scripts/install-settings.sh --with-devin`). Without it, auto mode refuses to let a workflow agent start another coding agent. Never add the rule yourself: it lets any agent start Devin with its checks bypassed.

The model is set by `SDD_DEVIN_MODEL` (default `swe-2-high`). Check the Devin plan's pricing for that model before relying on it.

## When the Workflow tool is unavailable

This happens, for example, inside a subagent or with workflows disabled. Read `${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development/manual-loop.md` and follow it. It is the upstream manual loop, and it uses the same scripts and templates.

## Arguments

| Arg | Default | Use |
|---|---|---|
| `plan` | required | plan .md path |
| `cwd` | session dir | worktree path; always pass it when the worktree is not the session directory |
| `base` | `main` | merge target for the final review |
| `spec` | named in plan | binding authority for rulings |
| `verify` | none | runs exactly once after the final review |
| `implementer` | `claude` | `devin` hands transcribe/integrate tasks to the Devin CLI |
| `implModel` | `auto` | Claude implementer model; `auto` picks by task tier: transcribe = haiku, integrate = sonnet, design = opus |
| `maxFixRounds` | 3 | 1–5; the last round goes to a fresh Claude implementer one tier up |
| `only` / `from` | — | task numbers |
| `sddDir` | auto-detected | this skill's directory (scripts + templates) |

## Common mistakes

| Mistake | Instead |
|---|---|
| Dispatching implementers or reviewers yourself after the workflow returns | The workflow already reviewed every task. Rerun with `only`, or bring the residuals to the user. |
| Waiting with sleep, polling or reading output files | Wait for the completion notification. Each wake-up re-reads this session's whole context. |
| Summarizing the rulings | Paste the ledger's `Ruling:` lines verbatim. |
| Omitting `cwd` after creating a worktree elsewhere | Agents would edit the session's checkout instead. |
| Starting on main/master | Get explicit consent, or create a worktree. |
