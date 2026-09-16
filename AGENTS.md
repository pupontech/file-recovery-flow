# File Recovery Flow - Agent Rules

## Mission
Build a technician-facing Windows recovery workflow that prepares a safe case, runs only verified File Scavenger automation, then hands off to R-Studio without destructive operations.

## Non-negotiable safety
- Treat the selected source as read-only.
- Never format, initialize, repair, run CHKDSK, modify partitions, change partition tables, delete files, or overwrite an existing job.
- Refuse a destination on the same physical disk as the source.
- Never invent File Scavenger or R-Studio command-line switches or control names. Record vendor evidence and expose unsupported operations as a manual gate.
- Do not silently continue after a launch, scan, recovery, destination, or verification failure.
- Destination loss and low space must pause or stop safely; never redirect output automatically.

## Runtime contract
- Windows PowerShell 5.1 is the minimum supported shell unless a task explicitly proves otherwise.
- Keep committed text files pure ASCII and without a BOM. Use CRLF for .bat files.
- Avoid PowerShell 7-only syntax, including ternary operators, null-coalescing operators, null-conditional operators, and three-argument positional Join-Path.
- Do not rely on screen coordinates. Prefer documented vendor interfaces, UI Automation control properties, Win32 handles, and explicit manual gates.
- Keep all application logic in PowerShell; launchers stay thin.
- Use explicit paths and error handling. Log major actions with timestamps and keep machine-readable job state.

## Workflow
- Use strict TDD for behavior: write one failing test, run it RED, implement the minimum, run it GREEN, then refactor.
- Use Pester-compatible tests where practical and add static contracts for PS 5.1, ASCII, BOM, launcher, and safety invariants.
- Verify on Linux with parser/static tests and on GitHub-hosted Windows runners for real Windows behavior. Live File Scavenger/R-Studio testing remains an owner/technician gate.
- One writer owns each file. Read-only research/review lanes write only their named artifact.
- Never run git clean, git reset --hard, git checkout ., git stash, or force-push. Preserve unrelated work.
- Workers must not commit or push unless their task explicitly says so. The orchestrator owns integration, review, and publication.

## Evidence requirements
- Vendor automation research must include direct URLs, observed version/build, exact supported surface, and a clear unknown/manual boundary.
- A child agent's completion is a claim. The parent must inspect diffs, rerun tests, and verify GitHub/CI state before reporting success.
