# Install the orchestrator into %USERPROFILE%\.claude — Windows PowerShell 5+.
#
# NOTE: this script only installs. Running the orchestrator itself needs a bash
# shell, because codex-run.sh, codex-diff.sh and codex-rollback.sh are bash.
# Git for Windows ships Git Bash, which is enough; WSL works too.
#   Run from:  Git Bash   ->  ~/.claude/orchestrator/bin/codex-run.sh ...
#   Not from:  PowerShell / cmd
$ErrorActionPreference = 'Stop'

$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE '.claude' }

function Say($m) { Write-Host "  $m" }

Write-Host "Installing into $dest"

# --- preflight -------------------------------------------------------------
# No `??` here: that is PowerShell 7 syntax, and Windows ships 5.1 by default.
$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) { throw "python3 (or python) is required and was not found on PATH" }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git is required and was not found on PATH"
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
  Say "WARNING: no 'bash' on PATH. The scripts are bash and will not run from"
  Say "         PowerShell. Install Git for Windows and use Git Bash."
}
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Say "WARNING: codex is not on PATH. Install it and run 'codex login' first."
}

# --- back up anything we would overwrite -----------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Backup($path) {
  if (Test-Path $path) {
    $bak = "$path.bak-$stamp"
    Move-Item $path $bak
    Say "backed up $(Split-Path -Leaf $path) -> $(Split-Path -Leaf $bak)"
  }
}

New-Item -ItemType Directory -Force -Path (Join-Path $dest 'agents')   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'commands') | Out-Null
Backup (Join-Path $dest 'orchestrator')
Backup (Join-Path $dest 'agents\code-verifier.md')
Backup (Join-Path $dest 'commands\orch-init.md')
Backup (Join-Path $dest 'commands\orchestrate.md')

# --- copy -------------------------------------------------------------------
Copy-Item (Join-Path $src 'orchestrator') (Join-Path $dest 'orchestrator') -Recurse
Copy-Item (Join-Path $src 'agents\code-verifier.md')  (Join-Path $dest 'agents')
Copy-Item (Join-Path $src 'commands\orch-init.md')    (Join-Path $dest 'commands')
Copy-Item (Join-Path $src 'commands\orchestrate.md')  (Join-Path $dest 'commands')
Copy-Item (Join-Path $src 'README.md') (Join-Path $dest 'orchestrator\README.md')

# --- verify -----------------------------------------------------------------
$missing = @()
foreach ($f in 'codex-run.sh','codex-diff.sh','codex-rollback.sh','watch_events.py','run_capped.py','orch-cost.py') {
  if (-not (Test-Path (Join-Path $dest "orchestrator\bin\$f"))) { $missing += $f }
}
if ($missing.Count) { throw "installation incomplete, missing: $($missing -join ', ')" }

# CRLF in a .sh file makes bash fail with "bad interpreter". .gitattributes
# should have prevented it; check rather than assume the clone honoured it.
$runner = Join-Path $dest 'orchestrator\bin\codex-run.sh'
if ([IO.File]::ReadAllBytes($runner) -contains 13) {
  Say "WARNING: codex-run.sh contains CRLF line endings. bash will refuse it."
  Say "         Re-clone with: git clone --config core.autocrlf=input <repo>"
}

Write-Host ""
Say "Installed. Restart Claude Code so it picks up the new slash commands,"
Say "then run /orch-init once in your project, and /orchestrate after that."
Say "Run the scripts from Git Bash, not PowerShell."
