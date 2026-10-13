<!-- sdd-orca:begin -->
## Context hygiene (sdd-orca)

Every turn re-reads the whole context, so anything that enters it is paid for again on every later turn.

**Waiting, without polling.** Never loop `sleep` plus status checks, and never re-read a task's output file to see whether it is done. Pick the waiting tool by what you are waiting for:

- **A long command** (build, test suite, install, deploy script): run it with Bash `run_in_background: true`, end your turn, and act on its completion notification.
- **One condition** (a file appears, a port opens, a log line shows up): use Monitor, or Bash `run_in_background`, with a command that exits when the condition holds. The condition must also match failure, so a crash does not look like silence. For example: `until grep -qE 'Ready|ERROR|Traceback' app.log; do sleep 1; done; grep -m1 -E 'Ready|ERROR|Traceback' app.log`
- **A stream of events** (each error line, each CI step): use Monitor with a filter that matches both success and failure signals (`grep -E --line-buffered`).
- **External state with no notification** (CI, a remote deploy): make one blocking call with a timeout in the background (`gh run watch`, `orca terminal wait`). Otherwise, run a Monitor poll loop at 30s or slower that exits on every terminal state.

Subagents and workflows notify you when they finish; wait for that.

**Searching.** Find first, then read narrowly.

- **Files by name:** `rg --files -g '*auth*'` respects `.gitignore`, so prefer it to `find`. For tracked files only, use `git ls-files '<path>'`.
- **Content:** `rg -n -S 'pattern' <dir> -g '*.go'`, or `-t go` instead of the glob. Useful flags:
  - `-l` lists file names only;
  - `-c` prints counts;
  - `-m 5` caps matches per file;
  - `-C 2` adds context lines;
  - `--max-columns 200` trims minified lines.

  Add `| head -50` when there may be many results. Without rg, use `grep -rnE --include='*.go' 'pattern' <dir>`.
- **Then read only the lines you need:** `sed -n '120,180p' <file>`, or Read with offset/limit.
- **Long searches:** when a search takes more than about three rounds, or spans many directories, hand it to an Explore subagent and keep only its conclusion.

**Command output:** ask commands for only what you need, for example:
- `-q`/`--quiet`;
- `--json` with a `jq` filter;
- `| tail -n 40`, `grep -c`, `wc -l`.

For builds, tests, installs and logs, write the output to a log file. Then print the exit code and only the failing lines:

```sh
cmd > "$LOG" 2>&1; echo "rc=$?"; grep -nE 'FAIL|ERROR' "$LOG" | head -40
```

Never print whole lockfiles, minified bundles, binaries or JSON dumps. Hand wide reads (many files, long logs) to a subagent or workflow and keep only its conclusion.
<!-- sdd-orca:end -->
