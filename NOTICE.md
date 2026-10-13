# Notice

sdd-orca is a fork of [obra/superpowers](https://github.com/obra/superpowers) by Jesse Vincent. The fork point is version 6.4.1, commit `5bf4e78011075bcfc0dc295f0724994cd123ee71`. Upstream is MIT-licensed; its copyright notice is kept in [LICENSE](LICENSE).

## What is upstream, unchanged except for the namespace

- **Skills.** All 15 skills under `skills/`, with their scripts, prompt templates and references. Every `superpowers:` skill reference is renamed `sdd-orca:` so the plugin's skills point at each other.
- **Hooks.** `hooks/run-hook.cmd` and `hooks/session-start`. The SessionStart text names sdd-orca.
- **Kept paths.** On-disk paths stay as upstream has them, so existing repositories keep working:
  - `.superpowers/sdd/<plan>/` workspaces;
  - `docs/superpowers/specs` and `docs/superpowers/plans`.

## What sdd-orca changed

- `skills/subagent-driven-development/SKILL.md` is new. It runs the plan through the `sdd-orca:sdd-run` workflow. The upstream skill body is kept verbatim (minus frontmatter) as `manual-loop.md`, for sessions without the Workflow tool.
- `skills/writing-plans/SKILL.md`: the "Subagent-driven" execution option describes the workflow run and the optional Devin implementer.
- `skills/using-superpowers/references/claude-code-tools.md`: the "Cheaper orchestration" section now says not to wrap the workflow in an orchestrator subagent. That advice is limited to the manual-loop fallback.
- `hooks/hooks.json` adds a `PreToolUse` hook (`hooks/redirect-sdd`). It redirects `superpowers:subagent-driven-development` to the sdd-orca skill when both plugins are enabled. Upstream's Cursor hook file is not included.

## What sdd-orca added

- `workflows/`: `sdd-run`, `review-gate`, `sweep`, `verify-facts`.
- `bin/sdd-devin`: the Devin CLI job wrapper.
- `settings/recommended.json` and `scripts/install-settings.sh`.
- `tools/usage/`: transcript cost analysis scripts.
- `tests/`.

## Not included from upstream

The repository's Codex, Gemini, Cursor, OpenCode and Copilot packaging, its docs, its tests and its release notes are not included. See upstream for those.
