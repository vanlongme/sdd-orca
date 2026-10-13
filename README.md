# sdd-orca

A Claude Code plugin for spending fewer tokens on agentic coding. It contains:

- **The [superpowers](https://github.com/obra/superpowers) skills (6.4.1), forked.** `subagent-driven-development` now starts a single **Workflow** run in place of the manual implementer/reviewer loop in your main session.
- **Four workflows:**
  - `sdd-run`: execute an implementation plan;
  - `review-gate`: verified review of a commit range;
  - `sweep`: one task over many directories;
  - `verify-facts`: check claims against official sources.
- **An optional Devin CLI implementer.** Cheap tasks can run on Devin; reviews stay on Claude.
- **Recommended settings**, plus an installer that merges them into your user settings.
- **Usage analysis scripts** for your own `~/.claude/projects` transcripts.

> Vietnamese summary below. / Tóm tắt tiếng Việt ở cuối trang.

## Why

The author measured their own Claude Code usage over seven weeks (API-equivalent cost, cache reads included):

- **80%** of cost was the main session loop. Subagents were only 20%.
- About **60%** of cost was cache reads. Every turn re-reads the whole context, and the median main-loop context was ~315k tokens.
- About **15%** of main-loop cost was polling: `sleep`, reading task output, and wake-ups on task notifications.
- Sessions that coordinated an external coding agent (Devin through an orchestrator) were about **37%** of Claude usage. About a third of their calls were status checks made at 390–570k context.

The fix is structural: move the loop out of the long-lived session. A Workflow script runs the per-task agents. Each agent starts fresh with a small context and gets a model sized to the task. Your session starts the run once and reads one compact result.

## Install

```text
/plugin marketplace add vanlongme/sdd-orca
/plugin install sdd-orca@sdd-orca
```

If you also have upstream `superpowers` installed, disable it (`/plugin` → superpowers → disable). Otherwise both plugins inject their SessionStart context. While both are enabled, a bundled `PreToolUse` hook still redirects `superpowers:subagent-driven-development` to the sdd-orca skill.

Recommended settings (optional; this backs up your file first, and `--dry-run` previews the merge):

```bash
bash ~/.claude/plugins/marketplaces/sdd-orca/scripts/install-settings.sh --dry-run
bash ~/.claude/plugins/marketplaces/sdd-orca/scripts/install-settings.sh
```

The merge (`settings/recommended.json`) sets these values and keeps everything else. The installer also adds the context-hygiene rules to `~/.claude/CLAUDE.md` (see below).

| Setting | Value | Why |
|---|---|---|
| `autoCompactWindow` | `400000` | compact long sessions before cache reads dominate |
| `workflowSizeGuideline` | `medium` | keep workflows under ~10 agents unless asked |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `sonnet` | default subagent model; workflows still pick per step |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` / `..._HAIKU_MODEL` | `claude-sonnet-5-5` / `claude-haiku-5-5` | pin the aliases the workflows use |
| `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` | `4` | bound parallel agents (and rate-limit bursts) |
| `bashOutputMaxChars` | `12000` | inline Bash output limit (default 30000). Longer output is saved to a file; Claude receives a preview and the path. |
| `promptCacheTtl` | `"1h"` | keep the main conversation's cache warm across breaks. Already the automatic choice on a Claude subscription. On API-key billing, 1-hour cache writes cost 2× input. |
| `effortLevel` | `"high"` | thinking is output tokens, the most expensive kind; switch to `/effort xhigh` only for a hard design or debugging session |
| `fallbackModel` | `["sonnet"]` | keep working on Sonnet when the primary model is overloaded or unavailable |
| `cleanupPeriodDays` | `90` | keep transcripts long enough to re-measure with `tools/usage` (default 30) |
| `subagentPromptCacheTtl` | `"5m"` | short-lived subagents and workflow agents rarely outlive 5 minutes, so pay only for 5-minute cache writes |

The recommended settings grant no permissions. The Devin allow rule is a separate opt-in: `--with-devin` (see below).

### CLAUDE.md rules

`settings/CLAUDE.md` holds a short block of rules (~390 words, ~500 tokens per session). The installer puts it into `~/.claude/CLAUDE.md` between `<!-- sdd-orca:begin -->` and `<!-- sdd-orca:end -->` markers:

- **The first time,** it appends the block.
- **On reinstall,** it replaces the block in place and keeps the rest of your file.
- **Before changing the file,** it makes a backup.
- **With `--no-claude-md`,** it leaves the file alone.

The rules address the habits that cost the most in the measurements above:

- **Polling.** Run long commands with `run_in_background` and act on the completion notification. Wait for a condition with Monitor (or a background Bash) running an `until` loop that also matches failure states. Watch event streams with a filtered Monitor. Never loop `sleep` plus status checks.
- **Searching.** Find files with `rg --files -g`, find content with `rg -n -S` (`-l`, `-m`, `-g`/`-t`), and read only the line ranges you need with `sed -n`. Fall back to `grep -rn`, and hand broad searches to an Explore subagent. The workflow agents get the same recipe in their prompts.
- **Long command output in context.** Ask commands for quiet or filtered output. Send builds, tests and logs to a file and print only the exit code and failing lines. Hand wide reads to a subagent.

Requirements:
- Claude Code with the Workflow tool;
- `git`, `jq` and `bash`;
- `node` ≥ 18 for the tests;
- for Devin, the `devin` CLI, logged in.

## Use

### Plans (`sdd-run`)

Write a plan with `sdd-orca:writing-plans` and choose **Subagent-driven**, or ask Claude to execute an existing plan. The `sdd-orca:subagent-driven-development` skill then:

1. sets up a worktree;
2. starts the `sdd-orca:sdd-run` workflow once;
3. waits without polling;
4. reports from the result.

Inside the workflow, for each task, in order:

- **Preflight.** Conflict scan, task briefs and a ledger in `.superpowers/sdd/<plan>/`.
- **Implement.** The implementer depends on the task's tier: transcribe → haiku, integrate → sonnet, design → opus. Devin is optional.
- **Review.** A spec + quality review (sonnet; opus for design tasks), with commit ranges named by private refs `refs/sdd/<plan>/…`. No SHA ever passes through a model.
- **Fix.** Up to 3 fix rounds; the last round goes one model tier up.
- **Adjudicate.** An opus adjudicator decides findings that the plan itself mandates, and findings that hit the round cap. Each decision becomes a `Ruling:` line in the ledger.

After the last task, one whole-branch review, one fix wave and your verify command (for example `make check`) run once.

Rerunning the same plan resumes: tasks already marked complete in the ledger are skipped.

Arguments: `plan`, `cwd`, `base`, `spec`, `verify`, `implementer` (`claude`|`devin`), `implModel`, `maxFixRounds`, `only`, `from`. See the skill for the full table.

### The other workflows

You opt in by typing the slash command:

```text
/sdd-orca:review-gate main                     # finders per dimension (sonnet) + adversarial verifier per finding (opus)
/sdd-orca:review-gate {"base":"main","preset":"multi-tenant"}
/sdd-orca:sweep {"items":["services/a","services/b"],"task":"check README drift","mode":"report"}
/sdd-orca:verify-facts {"claims":["Go 1.26 is the current stable release"]}
```

- `review-gate` returns only the findings that survive verification. Refuted findings, and findings left unverified by the cap, are reported separately, never dropped.
- `sweep` has two modes:
  - **report**: reads items in parallel, then produces one synthesis;
  - **edit**: one commit per item, in sequence, stopping at the first blocked item.
- `verify-facts` gives each claim a verdict, with URLs and quotes.

## Devin as the implementer (optional)

Ask for it explicitly, for example "execute this plan with Devin". The run then works like this:

- **Devin's share.** Transcribe- and integrate-tier tasks, and their early fix rounds, go to the Devin CLI.
- **Claude's share.** Design-tier tasks, the escalated last fix round, every review and the final fix wave stay on Claude.
- **The wrapper.** A haiku agent drives `bin/sdd-devin` (on the Bash PATH while the plugin is enabled). It:
  1. writes Devin's prompt from fixed text, passing model-written context and findings only as file paths;
  2. starts the job with a timeout;
  3. waits on the job in bounded steps.
- **Watching in Orca.** When the [Orca](https://github.com/stablyai/orca) desktop runtime is reachable, each job opens Devin's interactive TUI in an Orca terminal tab of the worktree, titled `sdd task N #k`. You watch it live and can type guidance into it. Without Orca, `devin -p` runs as a detached background job.
- **How a job ends.** Devin ends the job by writing its `STATUS:` line to `<job>/status`. The wrapper then stops the idle TUI and renames the tab with the outcome; the tab stays open for review. If Devin sits idle with no status, it gets one nudge; if it then stays idle, the job is reported `BLOCKED`.
- **Repository registration.** The wrapper registers the repository in Orca if Orca does not know it yet.
- **What reaches the shell.** The only text typed into the tab's shell is `bash '<job>/run.sh'`. Paths containing control characters are rejected outright. Paths containing quote, escape or expansion characters run detached instead.

| Variable | Default | Meaning |
|---|---|---|
| `SDD_DEVIN_MODEL` | `swe-2-high` | Devin model |
| `SDD_DEVIN_MODE` | `dangerous` | `--permission-mode`. A headless run cannot answer permission prompts. |
| `SDD_DEVIN_SANDBOX` | `0` | `1` adds `--sandbox` |
| `SDD_DEVIN_TIMEOUT` | `5400` | seconds before the job is killed |
| `SDD_DEVIN_ORCA` | `auto` | `auto`: an Orca tab when Orca is reachable, otherwise detached; `1`: require Orca; `0`: always detached |
| `SDD_DEVIN_ORCA_ADD_REPO` | `1` | `0` stops the wrapper from registering an unknown repository in Orca |
| `SDD_DEVIN_IDLE_SECS` | `180` | in Orca mode, idle seconds before the nudge, and again before giving up |

Setup: `bash …/scripts/install-settings.sh --with-devin` adds the allow rule `Bash(sdd-devin:*)`. Without the rule, Claude Code's auto mode refuses to let an agent launch another coding agent.

**Risks you accept with `--with-devin`:**
- The rule is narrow in syntax but not in effect. Any agent in your sessions can start Devin with its permission checks bypassed, and you are not asked. That includes an agent steered by prompt-injected text in a repository, plan or issue. In effect, those agents get unsandboxed code execution.
- Opt in only on machines and repositories you trust.
- Remove the rule when you are not running Devin plans.
- Devin works in your worktree with checks bypassed, so use a worktree, not your main checkout.
- The wrapper always runs `devin` from `PATH` and has no executable override, so the rule cannot be pointed at another program.

**Pricing:** check your Devin plan before you rely on it. Devin's docs state that SWE-2 is free for self-serve plans only through **2026-10-15**, with per-token pricing afterwards. Under a Claude Max plan, the default Claude haiku/sonnet implementers add no extra cost.

## Verification

```bash
bash tests/run.sh
```

- **`tests/sdd-devin.test.sh`** (77 checks) runs the wrapper against a fake `devin` and a fake `orca` in a throwaway git repo. It covers:
  - input validation, and that no environment variable can swap in another executable;
  - Orca mode: repository registration, tab creation, interactive mode, the status file, the nudge, giving up, stop, and the fallback to detached mode;
  - that no path with control or shell-quoting characters is ever typed into an Orca shell;
  - argv and prompt contents;
  - relative paths;
  - the STATUS contract;
  - non-zero exit, timeout, `RUNNING`, and `stop` killing the whole session.
- **`tests/hooks.test.sh`** covers the redirect hook (deny shape, pass-through cases, fail-open, `SDD_MANUAL=1`) and the SessionStart output.
- **`tests/install-settings.test.sh`** (40 checks) covers:
  - merge semantics;
  - no permissions by default;
  - the opt-in allow-list union;
  - backups that never overwrite each other;
  - idempotence;
  - refusing a non-object file;
  - the CLAUDE.md block, which is appended once, replaced in place, keeps the surrounding text, and causes a refusal with unbalanced markers before any file is written.
- **`tests/brainstorm-server.test.sh`** checks that the brainstorm companion's `/tmp` session directory is random, owner-only and removed on stop.
- **`tests/sdd-dryrun.mjs`** runs `sdd-run` with every agent mocked: 21 scenarios covering routing, escalation, adjudication, resume, refs, the ledger, the Devin routing and input guards.
- **`tests/workflows-dryrun.mjs`** does the same for `review-gate`, `sweep` and `verify-facts`.

The mocks prove the control flow, not model behaviour. `sdd-run` itself was run live twice on a small throwaway plan, with 13 agents per run, a clean ledger and verify passing. The Devin path has been tested only against the fake CLI.

## Usage analysis (optional)

`tools/usage/` holds the read-only scripts behind the numbers above. They read your local transcripts and price them at API-equivalent rates:

```bash
python3 -I tools/usage/analyze.py ~/.claude/projects /tmp/usage.json
python3 -I tools/usage/report.py /tmp/usage.json      # also report2.py, report3.py
```

Keep the output private; it summarizes your own sessions.

## Credits

- Forked from [obra/superpowers](https://github.com/obra/superpowers) 6.4.1 by Jesse Vincent, under the MIT license. See [NOTICE.md](NOTICE.md) for exactly what changed.
- The manual SDD loop is preserved at `skills/subagent-driven-development/manual-loop.md`.

License: MIT ([LICENSE](LICENSE)).

---

## Tiếng Việt

**sdd-orca** là plugin Claude Code giúp giảm token khi lập trình bằng agent:

- **Bộ skill superpowers (fork).** `subagent-driven-development` không còn chạy vòng implementer/reviewer thủ công trong session chính nữa, mà khởi chạy **một lần** workflow `sdd-run`.
- **Bốn workflow:**
  - `sdd-run`: chạy plan;
  - `review-gate`: review có kiểm chứng;
  - `sweep`: chạy một việc trên nhiều thư mục;
  - `verify-facts`: kiểm chứng thông tin bằng nguồn chính thức.
- **Devin CLI tùy chọn** làm implementer cho task rẻ.
- **Bộ settings khuyến nghị**, kèm script cài đặt.

**Lý do (số liệu đo thật):**
- **80%** chi phí nằm ở vòng lặp session chính.
- **~15%** chi phí là polling.
- Các session điều phối Devin chiếm **~37%** usage Claude.

Workflow đưa vòng lặp ra khỏi session dài. Mỗi agent bắt đầu với context nhỏ và chạy model vừa đủ cho task.

**Cài đặt:**
1. Chạy `/plugin marketplace add vanlongme/sdd-orca`, rồi `/plugin install sdd-orca@sdd-orca`.
2. Tắt plugin superpowers gốc.
3. Chạy `bash …/scripts/install-settings.sh --dry-run` để xem trước. Bỏ `--dry-run` để ghi (có backup). Settings khuyến nghị không cấp quyền nào.
4. Script cũng thêm khối rule vào `~/.claude/CLAUDE.md`. Dùng `--no-claude-md` nếu muốn bỏ qua. Nội dung rule:
   - dùng `run_in_background` và chờ notification;
   - chờ điều kiện bằng Monitor với vòng `until`, bắt cả trạng thái lỗi, thay cho `sleep`;
   - không đổ output dài vào context;
   - tìm file bằng `rg --files -g`, tìm nội dung bằng `rg -n -S` (dùng `-l`, `-m`, `-g`), đọc đúng khoảng dòng bằng `sed -n`; dùng `grep -rn` khi không có rg; giao các tìm kiếm rộng cho subagent Explore.

**Settings mới thêm:**
- `bashOutputMaxChars: 12000`: output Bash quá 12k ký tự được lưu ra file; Claude chỉ nhận đoạn xem trước kèm đường dẫn.
- `promptCacheTtl: "1h"`: cache của session chính.
- `subagentPromptCacheTtl: "5m"`: cache của subagent và workflow.
- `effortLevel: "high"`: chỉ bật `/effort xhigh` khi cần thiết kế hoặc debug khó.
- `fallbackModel: ["sonnet"]`: chuyển sang Sonnet khi Opus quá tải.
- `cleanupPeriodDays: 90`: giữ transcript đủ lâu để đo lại usage.

**Devin:**
- Yêu cầu rõ "chạy plan bằng Devin".
- Cần CLI `devin` đã đăng nhập, và chủ động thêm rule `Bash(sdd-devin:*)` bằng `--with-devin`.
- Rule này cho phép mọi agent khởi chạy Devin ở chế độ bỏ qua kiểm tra quyền mà không hỏi bạn. Điều đó bao gồm cả agent bị prompt-injection từ nội dung repo hay plan. Chỉ bật trên máy và repo tin cậy, và gỡ rule khi không dùng.
- Devin chạy với quyền `dangerous` trong worktree, nên luôn dùng worktree.
- Khi Orca đang chạy, mỗi job Devin mở TUI trong một tab Orca của worktree (`sdd task N #k`). Bạn xem trực tiếp và có thể gõ hướng dẫn cho Devin.
- SWE-2 chỉ miễn phí cho gói self-serve đến **15/10/2026**. Sau đó hãy kiểm tra giá trước khi dùng.

**Kiểm thử:** chạy `bash tests/run.sh`.
