#!/usr/bin/env python3
"""Token accounting for one orchestration: Codex on one side, Claude on the other.

Both numbers are read from artefacts that already exist — the runs' JSONL event
streams and Claude Code's own session transcript. Nothing is estimated.

Money is deliberately NOT reported unless a pricing file supplies rates. Codex
here authenticates with a subscription (no OPENAI_API_KEY), and Claude Code
usually does too; on a subscription, tokens consume plan quota and a dollar
figure would be invented. Fill pricing.json only if you are billed per token.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

RUN_ID_RE = re.compile(r"^(\d{8})-(\d{6})-\d+$")


def run_started_at(run_id):
    """Run ids are <YYYYmmdd>-<HHMMSS>-<pid>, in local time."""
    m = RUN_ID_RE.match(run_id)
    if not m:
        return None
    return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").astimezone()


def human(n):
    if n >= 1_000_000:
        return "%.1fM" % (n / 1_000_000)
    if n >= 1_000:
        return "%.1fk" % (n / 1_000)
    return str(n)


# ------------------------------------------------------------------ codex side


def codex_usage(repo, since):
    total = {"input": 0, "cached": 0, "cache_write": 0, "output": 0, "reasoning": 0}
    runs, turns, per_run = 0, 0, []
    for run_dir in sorted(glob.glob(os.path.join(repo, ".orchestrator", "runs", "*"))):
        run_id = os.path.basename(run_dir)
        started = run_started_at(run_id)
        if since and started and started < since:
            continue
        events = os.path.join(run_dir, "events.jsonl")
        if not os.path.exists(events):
            continue
        runs += 1
        r = {"run": run_id, "input": 0, "cached": 0, "output": 0, "reasoning": 0, "turns": 0}
        for line in open(events, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") != "turn.completed":
                continue
            u = ev.get("usage") or {}
            turns += 1
            r["turns"] += 1
            total["input"] += u.get("input_tokens", 0)
            total["cached"] += u.get("cached_input_tokens", 0)
            total["cache_write"] += u.get("cache_write_input_tokens", 0)
            total["output"] += u.get("output_tokens", 0)
            total["reasoning"] += u.get("reasoning_output_tokens", 0)
            r["input"] += u.get("input_tokens", 0)
            r["cached"] += u.get("cached_input_tokens", 0)
            r["output"] += u.get("output_tokens", 0)
            r["reasoning"] += u.get("reasoning_output_tokens", 0)
        per_run.append(r)
    return total, runs, turns, per_run


# ----------------------------------------------------------------- claude side


def transcript_dir(repo):
    """Claude Code stores transcripts under a slug of the project path."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(repo))
    return os.path.expanduser("~/.claude/projects/" + slug)


def claude_usage(repo, since, session_id):
    d = transcript_dir(repo)
    if not os.path.isdir(d):
        return None, "no transcript directory at %s" % d
    if session_id:
        path = os.path.join(d, session_id + ".jsonl")
        if not os.path.exists(path):
            return None, "no transcript for session %s" % session_id
    else:
        files = sorted(glob.glob(os.path.join(d, "*.jsonl")), key=os.path.getmtime)
        if not files:
            return None, "no transcript files in %s" % d
        path = files[-1]

    buckets = {
        "main": {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0, "thinking": 0, "turns": 0},
        "sub": {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0, "thinking": 0, "turns": 0},
    }
    models = set()
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            d_ = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d_.get("type") != "assistant":
            continue
        ts = d_.get("timestamp")
        if since and ts:
            try:
                when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if when < since:
                    continue
            except ValueError:
                pass
        msg = d_.get("message") or {}
        u = msg.get("usage") or {}
        if not u:
            continue
        if msg.get("model"):
            models.add(msg["model"])
        # Subagent turns are the whole point of the design: the verifier reads
        # the full diff so the main context never has to.
        b = buckets["sub" if d_.get("isSidechain") else "main"]
        b["turns"] += 1
        b["input"] += u.get("input_tokens", 0)
        b["cache_read"] += u.get("cache_read_input_tokens", 0)
        b["cache_write"] += u.get("cache_creation_input_tokens", 0)
        b["output"] += u.get("output_tokens", 0)
        b["thinking"] += (u.get("output_tokens_details") or {}).get("thinking_tokens", 0)
    return {"path": path, "buckets": buckets, "models": sorted(models)}, None


# --------------------------------------------------------------------- pricing


def load_pricing(path):
    if not os.path.exists(path):
        return {}
    try:
        raw = json.load(open(path, encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    # Keys starting with `_` are notes and examples in the template file, not models.
    return {k: v for k, v in raw.items() if isinstance(v, dict) and not k.startswith("_")}


def money(rates, model, **tok):
    """USD, from per-million rates. Returns None if any needed rate is missing."""
    r = rates.get(model)
    if not r:
        return None
    total = 0.0
    for kind, n in tok.items():
        if not n:
            continue
        rate = r.get(kind)
        if rate is None:
            return None
        total += n * float(rate) / 1_000_000
    return total


# ------------------------------------------------------------------------ main


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", help="run id (20260823-030747-1234) or ISO timestamp; default: everything")
    ap.add_argument("--session", help="Claude session uuid; default: most recently written transcript")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--pricing", default=os.path.expanduser("~/.claude/orchestrator/pricing.json"))
    args = ap.parse_args()

    repo = subprocess.run(["git", "-C", args.repo, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip()
    if not repo:
        print("orch-cost: not inside a git repository", file=sys.stderr)
        return 2

    since = None
    if args.since:
        since = run_started_at(args.since)
        if since is None:
            try:
                since = datetime.fromisoformat(args.since.replace("Z", "+00:00"))
            except ValueError:
                print("orch-cost: cannot parse --since %r" % args.since, file=sys.stderr)
                return 2
        if since.tzinfo is None:
            since = since.astimezone()

    rates = load_pricing(args.pricing)
    codex_model = "unknown"
    cfg = os.path.expanduser("~/.codex/config.toml")
    if os.path.exists(cfg):
        for line in open(cfg, encoding="utf-8"):
            if line.strip().startswith("model ="):
                codex_model = line.split("=", 1)[1].strip().strip('"')
                break

    print("=" * 62)
    print("TOKEN REPORT" + ("  (since %s)" % args.since if args.since else "  (all runs in this repo)"))

    ct, runs, turns, per_run = codex_usage(repo, since)
    fresh = ct["input"] - ct["cached"]
    print("\nCODEX  model=%s  runs=%d  turns=%d" % (codex_model, runs, turns))
    print("  input %s (fresh %s, cached %s)   output %s (reasoning %s)"
          % (human(ct["input"]), human(fresh), human(ct["cached"]),
             human(ct["output"]), human(ct["reasoning"])))
    cusd = money(rates, codex_model, input=fresh, cache_read=ct["cached"],
                 cache_write=ct["cache_write"], output=ct["output"])
    if cusd is not None:
        print("  $%.4f" % cusd)
    if len(per_run) > 1:
        for r in per_run:
            print("    %s  in %s (cached %s)  out %s" % (
                r["run"], human(r["input"]), human(r["cached"]), human(r["output"])))

    cl, err = claude_usage(repo, since, args.session)
    if err:
        print("\nCLAUDE  unavailable: %s" % err)
    else:
        m, s = cl["buckets"]["main"], cl["buckets"]["sub"]
        print("\nCLAUDE  model=%s" % (", ".join(cl["models"]) or "unknown"))
        for label, b in (("main context", m), ("subagents  ", s)):
            if not b["turns"]:
                continue
            print("  %s  turns=%-4d input %s  cache read %s  cache write %s  output %s (thinking %s)"
                  % (label, b["turns"], human(b["input"]), human(b["cache_read"]),
                     human(b["cache_write"]), human(b["output"]), human(b["thinking"])))
        model = cl["models"][0] if cl["models"] else None
        tot = money(rates, model,
                    input=m["input"] + s["input"],
                    cache_read=m["cache_read"] + s["cache_read"],
                    cache_write=m["cache_write"] + s["cache_write"],
                    output=m["output"] + s["output"]) if model else None
        if tot is not None:
            print("  $%.4f" % tot)
        if s["turns"]:
            billed = m["cache_read"] + m["cache_write"] + m["output"]
            moved = s["cache_read"] + s["cache_write"] + s["output"]
            if billed + moved:
                print("  %.0f%% of Claude's tokens went through subagents rather than the main context."
                      % (100.0 * moved / (billed + moved)))

    if not rates:
        print("\n  Tokens only. Both CLIs here authenticate with a subscription, so tokens")
        print("  consume plan quota, not dollars. Fill ~/.claude/orchestrator/pricing.json")
        print("  with per-million rates to also print a cost — only meaningful on API billing.")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())
