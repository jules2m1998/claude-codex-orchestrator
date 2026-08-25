#!/usr/bin/env bash
# Install the orchestrator into ~/.claude. macOS, Linux, and Windows via Git Bash.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_HOME:-$HOME/.claude}"

say()  { printf '  %s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

echo "Installing into $DEST"

# --- preflight ------------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is required"
PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || die "python3 (or python) is required"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
  || die "python 3.8+ is required (found $("$PY" -V 2>&1))"

if ! command -v codex >/dev/null 2>&1; then
  say "WARNING: codex is not on PATH. Install it and run 'codex login' before"
  say "         using /orchestrate — nothing here works without it."
fi

# --- back up anything we would overwrite ----------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
backup() {
  [ -e "$1" ] || return 0
  mv "$1" "$1.bak-$STAMP" && say "backed up $(basename "$1") -> $(basename "$1").bak-$STAMP"
}

mkdir -p "$DEST/agents" "$DEST/commands" || die "cannot create $DEST"
backup "$DEST/orchestrator"
backup "$DEST/agents/code-verifier.md"
backup "$DEST/commands/orch-init.md"
backup "$DEST/commands/orchestrate.md"

# --- copy ------------------------------------------------------------------
cp -R "$SRC/orchestrator" "$DEST/orchestrator" || die "copy failed"
cp "$SRC/agents/code-verifier.md" "$DEST/agents/" || die "copy failed"
cp "$SRC/commands/orch-init.md" "$SRC/commands/orchestrate.md" "$DEST/commands/" || die "copy failed"
cp "$SRC/README.md" "$DEST/orchestrator/README.md" || die "copy failed"
chmod +x "$DEST/orchestrator/bin/"*.sh "$DEST/orchestrator/bin/"*.py 2>/dev/null

# --- verify ----------------------------------------------------------------
fail=0
for f in codex-run.sh codex-diff.sh codex-rollback.sh watch_events.py run_capped.py orch-cost.py; do
  [ -f "$DEST/orchestrator/bin/$f" ] || { say "MISSING $f"; fail=1; }
done
bash -n "$DEST/orchestrator/bin/codex-run.sh" || fail=1
"$PY" -c "import ast,sys;[ast.parse(open(p).read()) for p in sys.argv[1:]]" \
  "$DEST/orchestrator/bin/watch_events.py" "$DEST/orchestrator/bin/orch-cost.py" || fail=1
[ "$fail" -eq 0 ] || die "installation is incomplete — see the messages above"

echo
say "Installed. Restart Claude Code so it picks up the new slash commands,"
say "then run /orch-init once in your project, and /orchestrate after that."
say "Docs: $DEST/orchestrator/README.md"
