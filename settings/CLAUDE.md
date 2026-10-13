<!-- sdd-orca:begin -->
## Context hygiene (sdd-orca)

Every turn re-reads the whole context, so anything that enters it is paid for again on every later turn.

**Waiting, without polling:** background shells, subagents, workflows and Monitor watches re-invoke you when they finish. Start them, end your turn, and act on the notification. Do not loop `sleep` plus status checks, and do not re-read a task's output file to see whether it is done. For external state that sends no notification (CI, deploys), make one blocking call with a timeout (`gh run watch`, `orca terminal wait`), or schedule one wake-up sized to how long the work really takes.

**Command output:** ask commands for only what you need, for example:
- `-q`/`--quiet`;
- `--json` with a `jq` filter;
- `| tail -n 40`, `grep -c`, `wc -l`.

For builds, tests, installs and logs, write the output to a log file. Then print the exit code and only the failing lines:

```sh
cmd > "$LOG" 2>&1; echo "rc=$?"; grep -nE 'FAIL|ERROR' "$LOG" | head -40
```

Read large files by line range; never print whole lockfiles, minified bundles, binaries or JSON dumps. Hand wide reads (many files, long logs) to a subagent or workflow and keep only its conclusion.
<!-- sdd-orca:end -->
