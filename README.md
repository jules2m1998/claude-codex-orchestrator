# claude-codex-orchestrator

Claude plans and verifies. Codex writes the code. Neither is trusted to grade
its own homework.

Claude Code cuts a job into verifiable tasks, briefs Codex on one at a time, and
reads every diff that comes back through a subagent — so the diff never enters
the main context. A deterministic watcher reads Codex's event stream live and
kills the run at the first file written outside the declared perimeter, the first
destructive command, or the first touch of a secret. Every run is checkpointed
first, so any of it can be undone.

Everything mechanical is done by shell and Python, for free. The model is only
asked for judgement.

Verified against **codex-cli 0.149.0**.

---

## Install

**macOS / Linux**

```bash
git clone https://github.com/jules2m1998/claude-codex-orchestrator
cd claude-codex-orchestrator
./install.sh
```

**Windows**

The installer is PowerShell; the orchestrator itself is bash, so you need
**Git Bash** (bundled with [Git for Windows](https://git-scm.com/download/win))
or WSL. PowerShell and `cmd` cannot run the scripts.

```powershell
git clone https://github.com/jules2m1998/claude-codex-orchestrator
cd claude-codex-orchestrator
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Then drive it **from Git Bash**, not PowerShell.

If your Git is configured with `core.autocrlf=true`, the shell scripts can be
checked out with CRLF endings, and bash then fails with `bad interpreter: No
such file or directory` — which reads like a missing binary and is not.
`.gitattributes` pins these files to LF, but if you hit it anyway:

```bash
git clone --config core.autocrlf=input https://github.com/jules2m1998/claude-codex-orchestrator
```

`install.ps1` checks for this and warns you.

Both installers back up anything they would overwrite as `*.bak-<timestamp>`,
and verify the result rather than assuming the copy worked.

### Requirements

| | |
|---|---|
| `codex` | on PATH and logged in (`codex login`). Nothing works without it. |
| `python3` (or `python`) | 3.8+. Used for the watcher and the reports. |
| `git` | the checkpoint/rollback machinery is git plumbing. |
| Claude Code | restart it after installing so the slash commands register. |

---

## Use

```
/orch-init                          once per project — writes AGENTS.md
/orchestrate <what you want built>  plan → task loop → close
```

`/orch-init` explores the repo and writes an `AGENTS.md` that Codex loads
automatically on every run. That is the whole economics: each task brief stays
short because the project context is already there, and the conventions stay
identical from one task to the next. Skipping it means paying for the project's
context in every single brief.

`/orchestrate` plans, waits for your explicit approval, then runs one task at a
time. It never writes production code and never commits.

### What you get per task

```
STATUS=DONE | TRIPPED | FAILED | TIMEOUT
FILES=<what actually changed, from the event stream>
OUTSIDE_SCOPE=<paths outside the declared globs>
TESTS=<command -> exit N, run by the harness, not by Codex>
CODEX_REPORT=<assumptions, concerns, files, scope_respected>
```

`assumptions` and `concerns` are where the defects are. The verifier checks each
one against the real code before looking at anything else.

---

## The parts

| Path | Role |
|---|---|
| `orchestrator/bin/codex-run.sh` | One blocking call = checkpoint, run, guard, lint+test, compact report |
| `orchestrator/bin/watch_events.py` | Reads the JSONL stream live and kills at the first violation. No model involved |
| `orchestrator/bin/codex-diff.sh` | Diff since a checkpoint, **untracked files included** |
| `orchestrator/bin/codex-rollback.sh` | Kill, restore the checkpoint, delete what came after |
| `orchestrator/bin/orch-cost.py` | Token accounting: Codex runs + Claude transcript, main context vs subagents |
| `orchestrator/bin/run_capped.py` | Wall-clock cap for lint/test — macOS has no coreutils `timeout` |
| `orchestrator/schema/report.json` | JSON Schema constraining Codex's final message |
| `agents/code-verifier.md` | Subagent that reads the full diff so it never enters the main context |
| `commands/orch-init.md`, `commands/orchestrate.md` | The two slash commands |

---

## Guardrails

Applied deterministically, with no model in the loop. First violation kills the
process tree; typical detection is about a second.

- a file written outside the globs in the task's `.scope`
- destructive commands: `rm -rf`, `git reset --hard`, `git push --force`,
  `git clean`, `git checkout .`, history rewrites, `DROP TABLE`, `chmod 777`,
  `curl|sh`, `sudo`, package publish
- any write outside the repository, or into `~/`
- access to `.env`, `*.pem`, `*.key`, `credentials`, `secrets`, `~/.ssh`,
  `~/.aws`, `.npmrc`, `.netrc` — naming one in order to *exclude* it
  (`git grep -- ':!**/.env'`) is not access and does not trip
- wall-clock timeout (default 900s)

Scope files are one glob per line, `#` for comments. `**` spans directories,
`*` does not, a bare directory name means everything under it, and a line
starting with `!` exempts a path from both the scope and secret checks.

---

## Lint and tests are run by the harness, not by Codex

`codex-run.sh` runs them itself after the model is done and reports the exit
code it saw. Codex asserting that its tests pass is not evidence.

Detection order: `<repo>/.orchestrator/config.sh` → `ORCH_LINT_CMD` /
`ORCH_TEST_CMD` → `package.json` scripts → `Makefile` targets → `pyproject.toml`
→ `*.sln`/`*.slnx`.

**Auto-detection can produce a false green.** A root `test` script that fans out
to workspaces where no package defines `test` exits 0 having run nothing.
Detection reads manifests, and a manifest can lie. Pin the real command:

```bash
# <repo>/.orchestrator/config.sh
ORCH_LINT_CMD='pnpm -r lint'
ORCH_TEST_CMD='dotnet test MySolution.slnx --nologo -v q'
```

---

## The two git traps, and why they are handled

**`git diff <commit>` ignores untracked files — in both directions.** A file
Codex just created is untracked, so it is absent from a plain diff against the
checkpoint — and that file is very often the whole point of the task. A file
that was *already* untracked before the run is inside the checkpoint tree (built
with `git add -A`), so it shows up as a spurious deletion. `codex-diff.sh` runs
`git add -N` over the untracked paths first, then unregisters exactly those — 
never a blanket `git reset`, which would discard whatever you had staged.

**`git read-tree -u --reset` does not delete what came after.** It restores
every path in the checkpoint, but files created afterwards are untracked and it
has nothing to say about paths it does not know. Order is load-bearing:
**read-tree, then clean, then reset** — read-tree puts pre-existing untracked
files back into the index so `clean` spares them, and the final `reset` leaves
them untracked exactly as they were.

A third one, in process handling: the watcher waits on an `exit_code` file
written after the child is reaped, never on `kill -0`. A finished-but-unreaped
process is a zombie, and `kill -0` reports a zombie as alive.

---

## Known limits

- **One agent per working tree.** The checkpoint is `git add -A` over the whole
  repo, so it swallows whatever a concurrent session has in flight, and a
  rollback then discards everything that session wrote afterwards. There is no
  locking. Use a `git worktree` if two need to run.
- **`.gitignore`d files are not in the checkpoint.** `git add -A` honours
  `.gitignore`, so changes to ignored files are neither captured nor restored.
- **The checkpoint flattens the index.** Changes that were *staged* come back as
  merely unstaged. Content is never lost; the distinction is.
- **The JSONL schema is Codex's and can change between versions.** The watcher
  keys on `item.type` ∈ {`file_change`, `command_execution`, `agent_message`}
  and on `turn.failed`. A run reporting `FILES=aucun` while files clearly changed
  is the tell that a `codex update` moved the schema.
- **`file_change` guardrails fire on `item.started`, but the bytes may already be
  on disk.** The kill stops the *next* action — which is why every run is
  checkpointed. `command_execution` trips while the command is still running.
- **Do not add `--ephemeral`.** It stops Codex persisting the session, which
  breaks `--resume`, and the correction loop depends on it.
- `codex exec resume` has no `--sandbox` flag; the sandbox goes through
  `-c sandbox_mode=…` on resume and `--sandbox` on a cold run.
- Reasoning effort is `-c model_reasoning_effort=…`, exposed as `--effort`.
  Unset means your `~/.codex/config.toml` default applies.
- **Windows: the scripts are bash.** Git Bash or WSL. `install.ps1` installs but
  does not run them.

---

## Cost

```bash
~/.claude/orchestrator/bin/orch-cost.py --since <run id> --session <claude uuid>
```

Codex usage comes from `turn.completed.usage` in each run's `events.jsonl`;
Claude usage from its own session transcript, where every assistant entry
carries a `usage` block and an `isSidechain` flag. Both are recorded facts.

**No dollar figure is printed by default, on purpose.** Both CLIs typically
authenticate with a subscription, where tokens consume plan quota and a dollar
amount would be invented. Fill `pricing.json` with per-million rates only if you
are billed per token.

Watch the main-context/subagent split. The verifier reading a whole diff is the
one expense this design refuses to compress; a run where almost nothing went
through subagents is a run that was not really verified.

---

MIT.
