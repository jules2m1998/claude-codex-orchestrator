#!/usr/bin/env bash
# codex-run.sh — one blocking call = one full Codex execution cycle.
#
#   codex-run.sh <task.md> <scope-file> [--resume] [--sandbox MODE]
#                [--timeout SEC] [--effort LEVEL] [--no-tests]
#
# Checkpoints the tree, runs Codex under a deterministic guardrail watcher,
# then runs lint and tests HERE (never trusting Codex's word for it) and
# prints a ~30 line report. The raw event stream stays on disk.
set -uo pipefail

ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ORCH_HOME/schema/report.json"
WATCHER="$ORCH_HOME/bin/watch_events.py"
CAPPED="$ORCH_HOME/bin/run_capped.py"

die() { echo "codex-run: $*" >&2; exit 2; }

# ------------------------------------------------------------------- arguments
[ $# -ge 2 ] || die "usage: codex-run.sh <task.md> <scope-file> [--resume] [--sandbox MODE] [--timeout SEC] [--effort LEVEL] [--no-tests]"
TASK_FILE="$1"; SCOPE_FILE="$2"; shift 2
RESUME=0; SANDBOX="workspace-write"; TIMEOUT=900; EFFORT=""; RUN_TESTS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --resume)    RESUME=1; shift ;;
    --sandbox)   SANDBOX="${2:-}"; shift 2 ;;
    --timeout)   TIMEOUT="${2:-}"; shift 2 ;;
    --effort)    EFFORT="${2:-}"; shift 2 ;;
    --no-tests)  RUN_TESTS=0; shift ;;
    *)           die "unknown option: $1" ;;
  esac
done
[ -f "$TASK_FILE" ]  || die "task file not found: $TASK_FILE"
[ -f "$SCOPE_FILE" ] || die "scope file not found: $SCOPE_FILE (a task without an explicit scope is never dispatched)"
# Absolutise before we cd to the repo root, or a relative path breaks.
TASK_FILE="$(cd "$(dirname "$TASK_FILE")" && pwd)/$(basename "$TASK_FILE")"
SCOPE_FILE="$(cd "$(dirname "$SCOPE_FILE")" && pwd)/$(basename "$SCOPE_FILE")"
command -v codex >/dev/null 2>&1 || die "codex not on PATH"
# Windows/Git Bash usually ships `python`, not `python3`. Resolve once.
PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || die "python3 (or python) not on PATH"


# --------------------------------------------------------------- 1. repo guard
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository — refusing to run"
cd "$REPO" || die "cannot cd to $REPO"

EXCLUDE="$(git rev-parse --git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF '.orchestrator/' "$EXCLUDE" 2>/dev/null || echo '.orchestrator/' >> "$EXCLUDE"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$REPO/.orchestrator/runs/$RUN_ID"
mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
cp "$TASK_FILE" "$RUN_DIR/task.md"; cp "$SCOPE_FILE" "$RUN_DIR/scope"

# --------------------------------------------------------------- 2. checkpoint
# Orphan commit: reachable only through refs/orchestrator/*, so it never shows
# up in `git log` and never pollutes the user's history.
git add -A -- . >/dev/null 2>&1
TREE="$(git write-tree)" || die "git write-tree failed"
if PARENT="$(git rev-parse --verify -q HEAD)"; then
  CKPT="$(git commit-tree "$TREE" -p "$PARENT" -m "orchestrator checkpoint $RUN_ID")"
else
  CKPT="$(git commit-tree "$TREE" -m "orchestrator checkpoint $RUN_ID (root)")"
fi
git update-ref "refs/orchestrator/$RUN_ID" "$CKPT"
git reset -q
echo "$CKPT" > "$RUN_DIR/checkpoint"
echo "$RUN_ID" > "$REPO/.orchestrator/last_run_id"
echo "$RUN_DIR" > "$REPO/.orchestrator/last_run_dir"

# ------------------------------------------------------------------ 3. prompt
{
  cat "$TASK_FILE"
  echo
  echo "## Perimeter (enforced mechanically, outside your control)"
  echo
  echo "You may only create or modify files matching these globs:"
  echo '```'
  grep -vE '^\s*(#|$)' "$SCOPE_FILE" || true
  echo '```'
  echo
  echo "A watcher reads your event stream live and terminates this run at the first"
  echo "file written outside those globs, the first destructive command (rm -rf,"
  echo "git reset --hard, git clean, git push --force, sudo, curl|sh, DROP TABLE,"
  echo "chmod 777), and any access to .env / *.pem / *.key / credentials / secrets."
  echo "You will not be asked to confirm; the run simply ends and is rolled back."
  echo
  echo "Do not modify any file outside the perimeter. Do not add a dependency"
  echo "without saying so in \`assumptions\`. Do not commit."
  echo
  echo "Answer with the JSON report required by the output schema. \`assumptions\`"
  echo "and \`concerns\` are read first by a reviewer who has the full diff: an empty"
  echo "\`concerns\` list is a claim that every line is certain."
} > "$RUN_DIR/prompt.txt"

# ------------------------------------------------------------------- 4. launch
CODEX_ARGS=(exec)
if [ "$RESUME" -eq 1 ]; then
  THREAD=""
  [ -f "$REPO/.orchestrator/last_thread" ] && THREAD="$(cat "$REPO/.orchestrator/last_thread")"
  # Resume by explicit id when we know it: `--last` picks the newest session in
  # this cwd, which may be an unrelated interactive one.
  if [ -n "$THREAD" ]; then CODEX_ARGS+=(resume "$THREAD" -); else CODEX_ARGS+=(resume --last -); fi
  # `codex exec resume` has no --sandbox flag; the config key is the only way in.
  CODEX_ARGS+=(-c "sandbox_mode=$SANDBOX")
else
  CODEX_ARGS+=(- --sandbox "$SANDBOX")
fi
[ -n "$EFFORT" ] && CODEX_ARGS+=(-c "model_reasoning_effort=$EFFORT")
CODEX_ARGS+=(--json --output-schema "$SCHEMA" -o "$RUN_DIR/last_message.json")

START_TS=$(date +%s)
(
  codex "${CODEX_ARGS[@]}" < "$RUN_DIR/prompt.txt" \
      > "$RUN_DIR/events.jsonl" 2> "$RUN_DIR/stderr.log" &
  CPID=$!
  echo "$CPID" > "$RUN_DIR/codex.pid"
  wait "$CPID"
  # Written only once the child is REAPED. The watcher waits on this file and
  # never on `kill -0`: a finished-but-unreaped child is a zombie, and kill -0
  # reports a zombie as alive, so a PID probe would wait forever.
  echo "$?" > "$RUN_DIR/exit_code"
) &
WRAPPER=$!

# ---------------------------------------------------------- 5. blocking watch
"$PY" "$WATCHER" --run-dir "$RUN_DIR" --repo "$REPO" \
        --scope "$SCOPE_FILE" --timeout "$TIMEOUT" >/dev/null
wait "$WRAPPER" 2>/dev/null
ELAPSED=$(( $(date +%s) - START_TS ))

THREAD_ID="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("thread_id") or "")' "$RUN_DIR/summary.json" 2>/dev/null || true)"
[ -n "$THREAD_ID" ] && echo "$THREAD_ID" > "$REPO/.orchestrator/last_thread"
STATUS="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$RUN_DIR/summary.json" 2>/dev/null || echo FAILED)"

# ------------------------------------------- 6. ground truth: lint + tests here
# Per-repo override, sourced before detection. Auto-detection guesses from
# manifests and a manifest can lie: a root `test` script that fans out to
# workspaces where nothing defines `test` exits 0 having run nothing, which the
# report would show as green. When detection is not trustworthy for a repo,
# `.orchestrator/config.sh` sets ORCH_LINT_CMD / ORCH_TEST_CMD explicitly.
[ -f "$REPO/.orchestrator/config.sh" ] && . "$REPO/.orchestrator/config.sh"

detect() { # $1 = lint|test  -> prints the command, or nothing
  local kind="$1"
  local override; override="$(eval "echo \${ORCH_$(echo "$kind" | tr a-z A-Z)_CMD:-}")"
  if [ -n "$override" ]; then echo "$override"; return; fi
  if [ -f package.json ]; then
    local pm=npm
    [ -f pnpm-lock.yaml ] && pm=pnpm; [ -f yarn.lock ] && pm=yarn; [ -f bun.lockb ] && pm=bun
    if "$PY" -c "import json,sys;s=json.load(open('package.json')).get('scripts',{});sys.exit(0 if sys.argv[1] in s else 1)" "$kind" 2>/dev/null; then
      echo "$pm run $kind"; return
    fi
  fi
  if [ -f Makefile ] && grep -qE "^${kind}:" Makefile; then echo "make $kind"; return; fi
  if [ -f pyproject.toml ]; then
    if [ "$kind" = lint ] && command -v ruff >/dev/null 2>&1; then echo "ruff check ."; return; fi
    if [ "$kind" = test ] && command -v pytest >/dev/null 2>&1; then echo "pytest -q"; return; fi
  fi
  local sln; sln="$(ls -1 ./*.slnx ./*.sln 2>/dev/null | head -1)"
  if [ -n "$sln" ] && [ "$kind" = test ]; then echo "dotnet test $sln --nologo -v q"; return; fi
  if [ -n "$sln" ] && [ "$kind" = lint ]; then echo "dotnet build $sln --nologo -v q"; return; fi
}

TEST_LINES=""; TEST_SUMMARY=""; FAILED_SEEN=0
if [ "$RUN_TESTS" -eq 1 ] && [ "$STATUS" != "TRIPPED" ]; then
  for kind in lint test; do
    CMD="$(detect "$kind")"
    [ -z "$CMD" ] && { TEST_SUMMARY="${TEST_SUMMARY}${kind}: (none detected)\n"; continue; }
    "$PY" "$CAPPED" 900 "$CMD" > "$RUN_DIR/$kind.out" 2>&1
    RC=$?
    TEST_SUMMARY="${TEST_SUMMARY}${kind}: ${CMD} -> exit ${RC}\n"
    if [ "$RC" -ne 0 ]; then
      TEST_LINES="$(tail -25 "$RUN_DIR/$kind.out")"; FAILED_SEEN=1
    elif [ "$FAILED_SEEN" -eq 0 ]; then
      # green: the exit code is the evidence, a short tail is enough to prove
      # the command really ran and was not a no-op.
      TEST_LINES="$(tail -8 "$RUN_DIR/$kind.out" 2>/dev/null || true)"
    fi
  done
else
  TEST_SUMMARY="skipped ($([ "$STATUS" = TRIPPED ] && echo 'run tripped' || echo '--no-tests'))\n"
fi

# --------------------------------------------------------------- 7. the report
export RUN_ID RUN_DIR CKPT STATUS ELAPSED TEST_SUMMARY TEST_LINES
"$PY" - <<'PYEOF'
import json, os, textwrap

rd = os.environ["RUN_DIR"]
try:
    s = json.load(open(os.path.join(rd, "summary.json")))
except Exception:
    s = {}

def line(k, v):
    print("%s=%s" % (k, v))

print("=" * 62)
line("RUN", os.environ["RUN_ID"])
line("RUN_DIR", rd)
line("CHECKPOINT", os.environ["CKPT"])
line("STATUS", os.environ["STATUS"])

trip = s.get("trip")
if trip:
    line("TRIP", "%s | %s" % (trip.get("rule"), trip.get("detail")))
    ev = (trip.get("event") or "").strip()
    if ev:
        print("      event: " + ev[:300])
if s.get("turn_error"):
    line("ERROR", s["turn_error"][:300])

files = s.get("files") or {}
if files:
    shown = ", ".join("%s (%s)" % (p, k) for p, k in sorted(files.items())[:25])
    print("\n".join(textwrap.wrap("FILES=" + shown, 100, subsequent_indent="      ")))
    if len(files) > 25:
        print("      ... and %d more (see summary.json)" % (len(files) - 25))
else:
    line("FILES", "aucun")
line("OUTSIDE_SCOPE", ", ".join(s.get("outside_scope") or []) or "aucun")
line("CMDS", s.get("cmds", 0))
line("ELAPSED", os.environ["ELAPSED"] + "s")

print("TESTS:")
for l in os.environ["TEST_SUMMARY"].split("\\n"):
    if l.strip():
        print("  " + l.strip())
tl = os.environ.get("TEST_LINES", "").strip()
if tl:
    print("  --- last 25 lines ---")
    for l in tl.splitlines()[-25:]:
        print("  | " + l[:160])

print("CODEX_REPORT:")
p = os.path.join(rd, "last_message.json")
rep = None
if os.path.exists(p) and os.path.getsize(p):
    raw = open(p, encoding="utf-8").read().strip()
    try:
        rep = json.loads(raw)
    except Exception:
        print("  (unparseable) " + raw[:800])
if rep is None and not os.path.exists(p):
    print("  (none - Codex produced no final message)")
if rep is not None:
    def bullets(label, items, cap):
        if not items:
            print("  %s: (none)" % label)
            return
        print("  %s:" % label)
        for x in items[:cap]:
            for i, w in enumerate(textwrap.wrap(str(x), 92)):
                print("    " + ("- " if i == 0 else "  ") + w)
        if len(items) > cap:
            print("    ... +%d more" % (len(items) - cap))
    print("  scope_respected=%s  tests_added=%s"
          % (rep.get("scope_respected"), ", ".join(rep.get("tests_added") or []) or "(none)"))
    for f in (rep.get("files_changed") or [])[:12]:
        print("  ~ %s (%s) - %s" % (f.get("path"), f.get("kind"), (f.get("why") or "")[:70]))
    bullets("assumptions", rep.get("assumptions") or [], 8)
    bullets("concerns", rep.get("concerns") or [], 8)
    # Codex's claim vs what the event stream actually showed.
    claimed = {f.get("path") for f in (rep.get("files_changed") or [])}
    observed = set(files)
    missing, extra = sorted(observed - claimed), sorted(claimed - observed)
    if missing or extra:
        print("  CLAIM_MISMATCH: unreported=%s  reported-but-unseen=%s"
              % (", ".join(missing) or "-", ", ".join(extra) or "-"))
print("=" * 62)
PYEOF

case "$STATUS" in
  DONE)    exit 0 ;;
  TRIPPED) exit 3 ;;
  TIMEOUT) exit 4 ;;
  *)       exit 1 ;;
esac
