---
description: Write the AGENTS.md that Codex reads on every run (once per project)
argument-hint: "[extra context about the project]"
allowed-tools: Bash, Read, Write, Grep, Glob
disable-model-invocation: true
---

Repo: !`git rev-parse --show-toplevel 2>/dev/null || echo 'NOT A GIT REPO'`
Existing: !`ls AGENTS.md CLAUDE.md 2>/dev/null || echo 'none'`
Tree: !`git ls-files 2>/dev/null | head -80`
Extra context from the user: $ARGUMENTS

Run this **once per project**. It writes the `AGENTS.md` that Codex loads
automatically on every single run. Everything you put there is context that no
individual task brief ever has to repeat — that is the whole economics of this
setup, and it is also what keeps the conventions identical from one task to the
next.

## 1. Explore, for real

Do not skim. Establish, by reading actual files:

- **Architecture** — the real module/layer boundaries, what depends on what, and
  where the entry point is. Draw it as a short list, not prose.
- **Conventions as practised** — naming, file layout, error handling, logging,
  async style, test style. Take these from the code, not from a README that may
  be aspirational. When the code contradicts the docs, the code wins and you say
  so.
- **Commands** — the exact build, lint, format and test invocations. Run them if
  cheap. A command you have not verified goes in with the word "unverified".
- **Traps** — the things that silently break: generated files, code that mirrors
  another file and must be kept in sync, tests that pass for the wrong reason,
  environment-dependent behaviour.
- **Off limits** — generated output, vendored code, migrations already applied,
  anything the user tells you not to touch.

If the repo already has a `CLAUDE.md`, mine it — it usually holds hard-won facts
— but re-verify each claim against the code before carrying it over.

## 2. Draft AGENTS.md

Dense and factual. Every line must be checkable against this repository.

Ban: "write clean code", "follow best practices", "add tests where appropriate",
and anything else that would be equally true of any repo on earth. If a sentence
survives being pasted into an unrelated project, delete it.

Suggested spine (adapt to what this repo actually is):

```markdown
# <project>

<Two sentences: what it is, what it runs on.>

## Architecture
## Commands
## Conventions
## Testing
## Gotchas
## Do not touch
```

Aim for 60–150 lines. Longer means you are padding; shorter means you did not
explore enough.

## 3. Show it and wait

**Print the full proposed AGENTS.md and stop.** Do not write the file until the
user validates it. They know things about this repo that the code does not say,
and this file is the single point where that knowledge enters every future run.

## 4. On validation

- Write `AGENTS.md` at the repo root.
- Write or rewrite `CLAUDE.md` as a pointer, so the two files can never drift:

```markdown
# <project>

Conventions, architecture, commands and traps live in [AGENTS.md](AGENTS.md).
Read it first; it is the single source and both Claude and Codex load it.

<Only Claude-specific instructions below this line — nothing that also applies
to Codex, or it will drift.>
```

- Add `.orchestrator/` to `.git/info/exclude` (never to the versioned
  `.gitignore` — this is local tooling, not a project decision).
- Write `.orchestrator/config.sh` pinning the commands that are the *real*
  gate, whenever auto-detection would get them wrong:

```bash
ORCH_LINT_CMD='<the command that actually lints>'
ORCH_TEST_CMD='<the command that actually runs the tests>'
```

  Check this deliberately. A root `test` script that delegates to workspaces
  where nothing defines `test` exits 0 having run nothing — `codex-run.sh` would
  report a green it never earned. Run each candidate command once and look at
  what it prints before pinning it.
- Tell the user the project is ready for `/orchestrate`.
