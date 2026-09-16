# File Recovery Flow

File Recovery Flow is a Windows PowerShell workflow for computer repair and data-recovery technicians. It prepares a non-destructive recovery job, validates source/destination physical-disk separation, records evidence, automates File Scavenger only through verified interfaces, and hands the case to R-Studio.

## Status

The repository is under active implementation. Vendor automation research and safety contracts are required before any File Scavenger control logic is added. Unsupported or unverified vendor operations must remain explicit manual gates.

## Safety boundary

This tool must never format, initialize, repair, run CHKDSK, modify partitions, change partition tables, delete recovered data, overwrite an existing job, or write recovered files to the source physical disk. It must stop clearly on unsafe destinations, unavailable output media, or uncertain application state.

## Planned entry point

- `Start-Recovery.bat` - thin double-click launcher.
- `RecoveryAutomation.ps1` - Windows PowerShell 5.1-compatible workflow entry point.
- `modules/` - small testable PowerShell modules.
- `tests/` - Pester and static contract tests.
- `docs/` - vendor evidence, operator workflow, and live-test checklist.

## Verification

Linux checks cover PowerShell parsing, ASCII/no-BOM rules, static safety contracts, and synthetic behavior. GitHub Actions Windows runners cover `cmd.exe` launcher execution, Windows PowerShell 5.1 compatibility, and Pester tests. Real File Scavenger and R-Studio integration remains a technician-owned live-machine validation gate because it requires licensed installed applications and must not be faked in CI.
