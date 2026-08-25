#!/usr/bin/env bash
# codex-rollback.sh <run_dir> [--dry-run]
#
# Restores the working tree to the run's checkpoint.
#
# THE TRAP: `git read-tree -u --reset <ckpt>` restores every path recorded in
# the checkpoint, but it does NOT delete files created afterwards — those are
# untracked, and read-tree has nothing to say about paths it does not know.
# Without the `git clean -fd` that follows, Codex's new files survive a
# "rollback". Conversely the files that were already untracked BEFORE the run
# are inside the checkpoint tree (it was built with `git add -A`), so read-tree
# puts them back into the index and `clean` spares them; the final `git reset`
# then returns the index to HEAD and they are untracked again, exactly as they
# were. Order is load-bearing: read-tree, then clean, then reset.
# `.orchestrator/` sits in .git/info/exclude, so plain `clean -fd` (no -x)
# leaves the run logs alone.
set -uo pipefail

die() { echo "codex-rollback: $*" >&2; exit 2; }
[ $# -ge 1 ] || die "usage: codex-rollback.sh <run_dir> [--dry-run]"
RUN_DIR="$1"; shift
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

[ -d "$RUN_DIR" ] || die "no such run dir: $RUN_DIR"
[ -f "$RUN_DIR/checkpoint" ] || die "no checkpoint recorded in $RUN_DIR"
CKPT="$(cat "$RUN_DIR/checkpoint")"

# Windows/Git Bash usually ships `python`, not `python3`. Resolve once.
PY="$(command -v python3 || command -v python)"
[ -n "$PY" ] || die "python3 (or python) not on PATH"


REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO" || die "cannot cd to $REPO"
git rev-parse --verify -q "$CKPT^{commit}" >/dev/null || die "checkpoint commit is gone: $CKPT"

# What would `clean` actually remove? Only untracked paths that are NOT in the
# checkpoint tree — running `git clean -nd` before read-tree would wrongly list
# every pre-existing untracked file as doomed.
doomed() {
  "$PY" - "$CKPT" <<'PY'
import subprocess, sys
ckpt = sys.argv[1]
def z(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    return {p for p in out.split("\0") if p}
untracked = z(["git", "ls-files", "-o", "--exclude-standard", "-z",
               "--", ".", ":(exclude).orchestrator"])
inckpt = z(["git", "ls-tree", "-r", "-z", "--name-only", ckpt])
for p in sorted(untracked - inckpt):
    print(p)
PY
}

if [ "$DRY" -eq 1 ]; then
  echo "--- would restore from $CKPT ---"
  "$(dirname "${BASH_SOURCE[0]}")/codex-diff.sh" "$CKPT" --stat
  echo "--- would delete (untracked, created after the checkpoint) ---"
  doomed | sed 's/^/  /'
  echo "--- would preserve (untracked, already there before the run) ---"
  git ls-files -o --exclude-standard -- . ':(exclude).orchestrator' \
    | grep -vxF -f <(doomed) 2>/dev/null | sed 's/^/  /'
  RUNNING=no; [ -f "$RUN_DIR/exit_code" ] || RUNNING=yes
  echo "--- codex still running: $RUNNING (a real rollback would kill it) ---"
  exit 0
fi

# 1. make sure nothing is still writing to the tree. Only when the run has not
#    reported an exit code: `exit_code` is written by the wrapper AFTER it reaps
#    the child, so its presence is the one reliable proof the process is gone.
if [ ! -f "$RUN_DIR/exit_code" ] && [ -f "$RUN_DIR/codex.pid" ]; then
  PID="$(cat "$RUN_DIR/codex.pid")"
  if [ -n "$PID" ]; then
    pkill -TERM -P "$PID" 2>/dev/null
    kill -TERM "$PID" 2>/dev/null
    sleep 1
    pkill -KILL -P "$PID" 2>/dev/null
    kill -KILL "$PID" 2>/dev/null
    echo "killed live process tree $PID"
  fi
fi

git read-tree -u --reset "$CKPT" || die "read-tree failed"
git clean -fdq -e .orchestrator
git reset -q
echo "rolled back to $CKPT"
git --no-pager status --short
