#!/usr/bin/env bash
# codex-diff.sh <checkpoint_sha|run_dir> [--stat]
#
# THE TRAP: `git diff <commit>` compares the commit to the INDEX for tracked
# paths only. Untracked paths are simply absent from the comparison, and that
# cuts both ways against an orchestrator checkpoint:
#   - a file Codex just CREATED is untracked, so it does not appear at all —
#     and it is very often the entire point of the task;
#   - a file that was already untracked BEFORE the run is inside the checkpoint
#     tree (the checkpoint is built with `git add -A`), so it shows up as a
#     spurious DELETION.
# `git add -N` registers every untracked path as intent-to-add, which fixes both
# at once. We then unregister exactly those paths — never a blanket `git reset`,
# which would also discard whatever the user had staged.
#
# NUL-safe throughout: `$(git ls-files -z)` would silently drop the separators,
# so the list goes through a temp file and never through command substitution.
set -uo pipefail

die() { echo "codex-diff: $*" >&2; exit 2; }
[ $# -ge 1 ] || die "usage: codex-diff.sh <checkpoint_sha|run_dir> [--stat]"

REF="$1"; shift
STAT=0
[ "${1:-}" = "--stat" ] && STAT=1

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO" || die "cannot cd to $REPO"

if [ -d "$REF" ] && [ -f "$REF/checkpoint" ]; then REF="$(cat "$REF/checkpoint")"; fi
git rev-parse --verify -q "$REF^{commit}" >/dev/null || die "not a commit: $REF"

# `mktemp -t name` is BSD syntax; GNU mktemp needs XXXXXX in the template and
# fails with "too few X's". This form works on both.
LIST="$(mktemp "${TMPDIR:-/tmp}/codexdiff.XXXXXX")"
cleanup() {
  if [ -s "$LIST" ]; then xargs -0 git reset -q -- < "$LIST" >/dev/null 2>&1; fi
  rm -f "$LIST"
}
trap cleanup EXIT INT TERM

git ls-files -o --exclude-standard -z -- . ':(exclude).orchestrator' > "$LIST"
if [ -s "$LIST" ]; then xargs -0 git add -N -- < "$LIST" >/dev/null 2>&1; fi

if [ "$STAT" -eq 1 ]; then
  git --no-pager diff --stat "$REF" -- . ':(exclude).orchestrator'
else
  git --no-pager diff "$REF" -- . ':(exclude).orchestrator'
fi
