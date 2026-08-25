#!/usr/bin/env python3
"""Deterministic guardrail watcher for codex-run.sh.

Tails the Codex JSONL event stream and kills the run at the FIRST violation.
Never calls a model: every rule here is a regex or a path comparison.

Event shapes (codex-cli 0.149.0, verified):
  {"type":"thread.started","thread_id":"..."}
  {"type":"turn.started"}
  {"type":"item.started"|"item.completed","item":{"type":"file_change",
       "changes":[{"path":"<absolute>","kind":"add|update|delete"}],"status":...}}
  {"type":"item.started"|"item.completed","item":{"type":"command_execution",
       "command":"/bin/zsh -lc '...'","aggregated_output":"...","exit_code":0|null}}
  {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
  {"type":"turn.completed","usage":{...}}  |  {"type":"turn.failed","error":{...}}

We inspect item.started too, so a destructive command is caught while it is
still in_progress rather than after it has finished.
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

POLL = 0.15

# ---------------------------------------------------------------- glob → regex


def glob_to_re(pat):
    """Translate a repo-relative glob to a regex. `**` spans directories, `*` does not."""
    pat = pat.strip().rstrip("/")
    if not pat:
        return None
    # A bare directory ("src/api") means everything under it.
    if not any(c in pat for c in "*?["):
        pat = pat + "/**"
    out, i, n = [], 0, len(pat)
    while i < n:
        c = pat[i]
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("/**", i) and i + 3 == n:
            out.append("(?:/.*)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def load_scope(path):
    """Returns (allow_regexes, exempt_regexes). Lines starting with `!` are exemptions."""
    allow, exempt = [], []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("!"):
                r = glob_to_re(line[1:])
                if r:
                    exempt.append((line, r))
            else:
                r = glob_to_re(line)
                if r:
                    allow.append((line, r))
    return allow, exempt


# ------------------------------------------------------------------- rulebook

DESTRUCTIVE = [
    ("rm -rf", re.compile(r"\brm\s+(?:-[^\s]+\s+)*-[^\s]*[rf]")),
    ("git reset --hard", re.compile(r"\bgit\s+(?:-\S+\s+)*reset\b[^&|;]*--hard")),
    ("git push --force", re.compile(r"\bgit\s+(?:-\S+\s+)*push\b[^&|;]*(?:--force|--delete|\s-f\b)")),
    ("git clean", re.compile(r"\bgit\s+(?:-\S+\s+)*clean\b")),
    ("git checkout .", re.compile(r"\bgit\s+(?:-\S+\s+)*(?:checkout|restore)\s+(?:--\s+)?\.(?:\s|$|['\"])")),
    ("git history rewrite", re.compile(r"\bgit\s+(?:-\S+\s+)*(?:filter-branch|filter-repo)\b|\bgit\s+(?:-\S+\s+)*update-ref\s+-d\b")),
    ("DROP TABLE/DATABASE", re.compile(r"\bDROP\s+(?:TABLE|DATABASE|SCHEMA)\b", re.I)),
    ("chmod 777", re.compile(r"\bchmod\s+(?:-\S+\s+)*[0-7]*777\b")),
    ("curl | sh", re.compile(r"\b(?:curl|wget)\b[^\n]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b")),
    ("sudo", re.compile(r"(?:^|[\s;|&(])sudo\s")),
    ("write outside repo", re.compile(r">\s*(?:~/|/etc/|/usr/|/System/|/Library/)|\b(?:mv|cp|rm)\s+[^\n]*\s~/")),
    ("package publish", re.compile(r"\b(?:npm|pnpm|yarn)\s+publish\b|\bdotnet\s+nuget\s+push\b")),
]

# A path can appear either on its own (file_change) or embedded in a shell
# command, so the boundaries have to accept whitespace and quotes, not just `/`.
_B = r"(?:^|[\s/'\"=:(])"
_E = r"(?:$|[\s./'\";|)&,])"
SECRET_PATH = re.compile(
    _B + r"\.env(?!\.example|\.sample|\.template)" + _E
    + r"|\.(?:pem|key|p12|pfx|keystore)" + _E
    + r"|" + _B + r"id_(?:rsa|ed25519|ecdsa)"
    + r"|" + _B + r"credentials?" + _E
    + r"|" + _B + r"secrets?" + _E
    + r"|" + _B + r"\.(?:npmrc|netrc|pgpass|aws|ssh)(?:$|/)"
    + r"|authorized_keys",
    re.I,
)
SECRET_SAFE = re.compile(r"\.(?:example|sample|template|dist|md)$|(?:^|/)secrets?\.(?:cs|ts|py|go|rs)$", re.I)


# Naming a secret in order to EXCLUDE it is the opposite of accessing it. A
# `git grep -- ':!**/.env'` that carefully skips secrets used to be killed by the
# rule meant to protect them, five minutes into a real run. Strip exclusion
# patterns before scanning; `cat .env` still trips.
EXCLUSION = re.compile(
    r':\(exclude\)\S+'          # git :(exclude)pathspec
    r'|:!\S+'                    # git :!pathspec
    r'|(?<![\w-])!(?=[\w*./])\S+'  # bare !pattern, as it appears inside quotes
    r'|--(?:exclude|ignore)(?:-dir|-from|-file)?[= ]\s*\S+'
    r"|-g\s+['\"]!\S+?['\"]"      # ripgrep -g '!pattern'
)


def secret_hit(text):
    stripped = EXCLUSION.sub(" ", text)
    if SECRET_SAFE.search(stripped):
        return False
    return bool(SECRET_PATH.search(stripped))


# ---------------------------------------------------------------- process kill


IS_WINDOWS = os.name == "nt"


def kill_tree(pid):
    """Kill the process AND its children. Codex spawns shells; killing only the
    parent leaves the shell running and the guardrail unenforced."""
    if pid is None:
        return
    if IS_WINDOWS:
        # No pkill, no SIGKILL. taskkill /T walks the tree, /F forces it.
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        subprocess.run(["pkill", "-%d" % sig, "-P", str(pid)], capture_output=True)
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        if sig is signal.SIGTERM:
            time.sleep(1.0)


def read_pid(path):
    try:
        return int(open(path, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------- main loop


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--scope", required=True)
    ap.add_argument("--timeout", type=float, default=900.0)
    args = ap.parse_args()

    run_dir, repo = args.run_dir, os.path.realpath(args.repo)
    events = os.path.join(run_dir, "events.jsonl")
    pid_file = os.path.join(run_dir, "codex.pid")
    exit_file = os.path.join(run_dir, "exit_code")

    allow, exempt = load_scope(args.scope)

    state = {
        "status": "DONE",
        "trip": None,
        "files": {},
        "outside_scope": [],
        "cmds": 0,
        "thread_id": None,
        "agent_message": None,
        "turn_error": None,
    }
    started = time.time()
    pos = 0
    buf = ""
    draining = False
    drain_deadline = None

    def trip(rule, detail, event_line):
        state["status"] = "TRIPPED"
        state["trip"] = {
            "rule": rule,
            "detail": detail,
            "event": event_line[:600],
            "at": round(time.time() - started, 1),
        }
        kill_tree(read_pid(pid_file))

    def rel(path):
        rp = os.path.realpath(path)
        if rp == repo:
            return "."
        if rp.startswith(repo + os.sep):
            return rp[len(repo) + 1 :]
        return None

    def exempted(relpath):
        return any(r.match(relpath) for _, r in exempt)

    def check_file(path, kind, line):
        r = rel(path)
        if r is None:
            trip("write outside repo", path, line)
            return
        if r.startswith(".orchestrator/"):
            return
        state["files"][r] = kind if r not in state["files"] else state["files"][r]
        if exempted(r):
            return
        if secret_hit(r):
            trip("secret file touched", r, line)
            return
        if allow and not any(rx.match(r) for _, rx in allow):
            if r not in state["outside_scope"]:
                state["outside_scope"].append(r)
            trip("file outside scope", r, line)

    def check_cmd(cmd, line):
        for name, rx in DESTRUCTIVE:
            if rx.search(cmd):
                trip("destructive command: " + name, cmd[:300], line)
                return
        if secret_hit(cmd) and not exempted(cmd):
            trip("secret access in command", cmd[:300], line)

    while True:
        # --- drain whatever new bytes exist -------------------------------
        progressed = False
        if os.path.exists(events):
            with open(events, "r", encoding="utf-8", errors="replace") as fh:
                fh.seek(pos)
                chunk = fh.read()
                pos = fh.tell()
            if chunk:
                progressed = True
                buf += chunk
                lines = buf.split("\n")
                buf = lines.pop()
                for line in lines:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    et = ev.get("type")
                    if et == "thread.started":
                        state["thread_id"] = ev.get("thread_id")
                    elif et == "turn.failed":
                        state["turn_error"] = json.dumps(ev.get("error"))[:400]
                        if state["status"] == "DONE":
                            state["status"] = "FAILED"
                    elif et in ("item.started", "item.completed"):
                        item = ev.get("item") or {}
                        it = item.get("type")
                        if it == "file_change":
                            for ch in item.get("changes") or []:
                                check_file(ch.get("path", ""), ch.get("kind", "?"), line)
                                if state["trip"]:
                                    break
                        elif it == "command_execution":
                            if et == "item.started":
                                state["cmds"] += 1
                            check_cmd(item.get("command", ""), line)
                        elif it == "agent_message" and et == "item.completed":
                            state["agent_message"] = item.get("text")
                    if state["trip"]:
                        break
        # --- termination conditions ---------------------------------------
        now = time.time()

        # Arm the drain exactly once, or the deadline slides forever and the
        # watcher never returns.
        if not draining:
            if state["trip"]:
                draining, drain_deadline = True, now + 5.0   # killed: give the
                # wrapper time to reap the child and write exit_code
            elif os.path.exists(exit_file):
                draining, drain_deadline = True, now + 1.5
            elif now - started > args.timeout:
                state["status"] = "TIMEOUT"
                state["trip"] = {
                    "rule": "timeout",
                    "detail": "exceeded %ss" % int(args.timeout),
                    "event": "",
                    "at": round(now - started, 1),
                }
                kill_tree(read_pid(pid_file))
                draining, drain_deadline = True, now + 5.0

        if draining:
            # Normal exit: the wrapper reaped the child, so the JSONL file is
            # complete on disk; one quiet pass means we have read all of it.
            if os.path.exists(exit_file) and not progressed:
                break
            # Hard stop: killed, and the wrapper never got round to writing an
            # exit code. Never probe the PID instead — a reaped-but-unwaited
            # child is a zombie and `kill -0` reports a zombie as alive.
            if now > drain_deadline:
                break

        time.sleep(POLL)

    # --- final verdict -----------------------------------------------------
    codex_exit = None
    try:
        codex_exit = int(open(exit_file, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        pass
    state["codex_exit"] = codex_exit
    state["elapsed"] = round(time.time() - started, 1)
    if state["status"] == "DONE" and codex_exit not in (0, None):
        state["status"] = "FAILED"
    if state["status"] == "DONE" and codex_exit is None:
        state["status"] = "FAILED"
        state["turn_error"] = state["turn_error"] or "codex produced no exit code"

    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=1)
    print(state["status"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
