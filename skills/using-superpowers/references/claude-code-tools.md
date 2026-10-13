# Claude Code Tool Notes

Claude Code is the reference harness: skills speak its vocabulary
(`Agent` for a subagent dispatch, todos, `Skill`). These notes cover the
one place Claude Code can run a plan cheaper than the skills' default
shape. It is opt-in by your human partner and changes nothing the skills
require.

## Searching through Bash

When a skill says to search the codebase:

1. Find files with `rg --files -g '<glob>'`.
2. Find content with `rg -n -S '<pattern>' -g '<glob>'`:
   - add `-l` for file names only;
   - add `-m N` to cap the matches per file.
3. Read only the matching line ranges, with `sed -n '<a>,<b>p'` or Read with offset/limit.
4. Use `grep -rn` only where rg is missing.
5. Give broad, multi-directory searches to an Explore subagent.

The sdd-orca workflows give their agents the same recipe.

## Cheaper orchestration for subagent-driven development

In sdd-orca, sdd-orca:subagent-driven-development already runs the whole
loop as the `sdd-orca:sdd-run` workflow. The script holds the task loop,
the review verdicts and the ledger bookkeeping, so the controller session
reads one compact result instead of every dispatch and report. Do not
also wrap it in an orchestrator subagent: that adds a seat and buys
nothing.

Without the Workflow tool (inside a subagent, or with workflows disabled)
the skill falls back to its manual loop. In that case the advice above
the fork still applies: dispatch ONE orchestrator subagent on a mid-tier
model for the whole plan. Its final message must carry the "Rulings I
made" list verbatim.
