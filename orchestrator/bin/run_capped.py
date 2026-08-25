#!/usr/bin/env python3
"""Run a shell command with a wall-clock cap. macOS has no coreutils `timeout`."""
import os
import subprocess
import sys

secs = float(sys.argv[1])
cmd = sys.argv[2]
try:
    shell = ["cmd", "/c", cmd] if os.name == "nt" else ["/bin/sh", "-lc", cmd]
    p = subprocess.run(shell, timeout=secs, capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired as e:
    for stream, out in ((e.stdout, sys.stdout), (e.stderr, sys.stderr)):
        if stream:
            out.write(stream.decode() if isinstance(stream, bytes) else stream)
    sys.stderr.write("\n[run_capped] TIMEOUT after %ss\n" % int(secs))
    sys.exit(124)
