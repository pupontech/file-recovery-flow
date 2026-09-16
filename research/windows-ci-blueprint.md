# Windows CI and PowerShell 5.1 verification blueprint

- Lane: research artifact only. Author task: `t_3d8e3d86` (profile dsflash2).
- Repository revision read: `f9d9474` (`chore: initialize file recovery flow project`).
- All external sources retrieved 2026-09-16 (UTC). Retrieval method: direct fetch of primary
  Markdown sources (GitHub `actions/runner-images`, `github/docs`, `MicrosoftDocs/PowerShell-Docs`,
  `PowerShell/PSScriptAnalyzer`, `pester/Pester`) plus local execution on the Linux workstation.
- This artifact is a design proposal. It creates no workflow file, no test file, and no production
  code. Every command, path, and configuration key below is either cited from a primary source or
  verified locally; items that are not yet verified are listed in section 14 as open questions.

## 1. Scope and non-goals

In scope:

1. A test/CI topology that satisfies `AGENTS.md`: Linux parser/static gates, Windows-hosted real
   behavior on `windows-2022` and `windows-2025`, Pester behavior tests, static safety contracts.
2. The PowerShell 5.1 compatibility traps that will otherwise pass on Linux and fail on a
   technician machine, and how each one is detected in CI.
3. A seam design that lets application process/UI state and disk identity be tested with doubles
   that cannot touch a real disk.
4. An explicit owner-only live validation gate for licensed File Scavenger and R-Studio.

Out of scope (owned by other lanes, do not duplicate here):

- Vendor automation surface (CLI switches, config files, UI control names): see
  `research/file-scavenger-official.md`, `research/file-scavenger-cross-check.md`,
  `research/rstudio-official.md`. This blueprint deliberately names no vendor switch or control.
- Storage/volume enumeration details and the folder-browser design: see
  `research/windows-storage-ui-design.md`. This blueprint only fixes the seam boundary that the
  storage design must expose to be testable.
- Safety state machine and invariant list: see `research/safety-resumability.md`. This blueprint
  turns those invariants into test contracts; it does not redefine them.

## 2. Evidence base

### 2.1 Runner images (primary: `actions/runner-images` READMEs)

| Item | `windows-2022` | `windows-2025` |
|---|---|---|
| OS reported | Windows Server 2022, 10.0.20348 Build 5499 | Windows Server 2025, 10.0.26100 Build 33296 |
| Image version | `20260907.297.1` | `20260907.255.1` |
| PowerShell (7.x) | 7.6.5 | 7.6.5 |
| Pester modules present | 3.4.0 and 5.9.0 | 3.4.0 and 5.9.0 |
| PSScriptAnalyzer | 1.25.0 | 1.25.0 |
| .NET Framework | 4.7.2, 4.8, 4.8.1 | 4.8, 4.8.1 |
| Windows PowerShell 5.1 | inbox OS component (`powershell.exe`) | inbox OS component (`powershell.exe`) |

Sources: `https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md`,
`https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md`.

Label mapping (primary: `github/docs`, `data/reusables/actions/supported-github-runners.md`):
`windows-latest` and `windows-2025` both resolve to the Windows Server 2025 image; `windows-2022`
resolves to the Server 2022 image. Consequence: pinning the image with `windows-2025` and
`windows-2022` rather than `windows-latest` is required, because the project contract names those
two operating systems explicitly.

Runner privilege model (primary: `github/docs`, `content/actions/reference/runners/github-hosted-runners.md`):
"Windows virtual machines are configured to run as administrators with User Account Control (UAC)
disabled." Consequence: in CI a destructive cmdlet would simply succeed, and the "not elevated"
branch is not reachable. Safety in CI must come from static contracts and from the destination
guard refusing the runner's own system disk, not from lack of privilege. See traps 12 and 15.

### 2.2 Local runtime observations (Linux workstation, this task)

Executed against the local `pwsh` 7.6.5 (PSEdition Core, Debian GNU/Linux 13):

```
PSVersion        : 7.6.5
PSEdition        : Core
IsInputRedirected: True
Host name        : ConsoleHost
PARSE ternary            errors=0     ($x = $true ? "a" : "b")
PARSE null-coalesce      errors=0     ($x = $null ?? "d")
PARSE null-cond-assign   errors=0     ($h.k ??= "v")
PARSE pipechain          errors=0     (Write-Output 1 && Write-Output 2)
PARSE dotnet::new        errors=0     ([System.Text.UTF8Encoding]::new($false) | Out-Null)
CMD   Get-Disk           available=False
CMD   Get-Partition      available=False
CMD   Get-Volume         available=False
CMD   Get-PhysicalDisk   available=False
CMD   Get-CimInstance    available=False
CMD   Get-WmiObject      available=False
CMD   Test-Json          available=True
CMD   Add-Content        available=True
Set-Content -Encoding utf8 first bytes: 70 6C 61 69 6E   (no BOM)
```

Three conclusions, each load-bearing for the design:

1. A PowerShell 7 parser accepts every PowerShell 7-only syntax form with zero parse errors. A
   Linux-only "parse the files" gate therefore proves nothing about 5.1 compatibility. The 5.1
   syntax gate must execute on Windows against the real 5.1 parser (section 7).
2. The storage and CIM command surface used by discovery is absent on Linux. Static and unit lanes
   on Linux cannot exercise it at all, which is exactly why it must sit behind a seam (section 9).
3. `Set-Content -Encoding utf8` writes no BOM on 7.x, while the 5.1 documentation states that `UTF8`
   in Windows PowerShell "Uses UTF-8 (with BOM)" (section 2.3). Any output that must be ASCII and
   BOM-free is a cross-version hazard, and the same source code will behave differently per engine.

### 2.3 Encoding facts (primary: `MicrosoftDocs/PowerShell-Docs`, `reference/5.1/.../about_Character_Encoding.md`)

Verbatim facts from the 5.1 article:

- "In Windows PowerShell, any Unicode encoding, except `UTF7`, always creates a BOM."
- "In PowerShell 5.1, the **Encoding** parameter supports the following values: `Ascii`,
  `BigEndianUnicode`, `BigEndianUTF32`, `Byte`, `Default`, `Oem`, `String`, `Unicode`, `Unknown`,
  `UTF32`, `UTF7`, `UTF8` (Uses UTF-8 (with BOM))." There is no `utf8NoBOM` value in 5.1.
- "`Out-File` and the redirection operators `>` and `>>` create UTF-16LE, which notably differs
  from `Set-Content` and `Add-Content`."
- "When the target file is empty or does not exist, `Set-Content` and `Add-Content` use `Default`
  encoding" (the ANSI legacy code page).
- "In the absence of an explicit **Encoding** parameter, `Add-Content` detects the existing
  encoding and automatically applies it to the new content. If the existing content has no BOM,
  `Default` ANSI encoding is used."
- "PowerShell (v6 and higher) defaults to `utf8NoBOM` for all text output."
- "Creating PowerShell scripts on a Unix-like platform ... results in a file encoded using
  `UTF8NoBOM`. These files work fine in PowerShell, but may break in Windows PowerShell if the file
  contains non-Ascii characters."

The 7.x article (`reference/7.5/.../about_Character_Encoding.md`) documents `utf8NoBOM` as the
default and adds the 7-only encodings. Consequence: the repository rule "pure ASCII and no BOM" is
not just a style rule, it is the only encoding choice that behaves identically on 5.1 and 7.x.
See trap 2.

### 2.4 Pester facts (primary: `pester/Pester` manifest and README)

- Image inventory is 3.4.0 plus 5.9.0 on both Windows images, so "the version that loads" is a
  pinning decision, not an accident. See trap 13.
- `5.9.0` tag manifest (`src/Pester.psd1`): `ModuleVersion = '5.9.0'`,
  `PowerShellVersion = '3.0'`. The manifest floor means 5.9.0 can load on Windows PowerShell 5.1.
- Current `main` manifest (Pester 6.2.0): `PowerShellVersion = '5.1'`.
- README (main): "It is compatible with Windows PowerShell 5.1 and PowerShell 7.4 and newer."

### 2.5 Compatibility-analysis facts (primary: `PowerShell/PSScriptAnalyzer`, `docs/Rules/*.md`)

- `PSUseCompatibleSyntax`: "identifies syntax elements that are incompatible with targeted
  PowerShell versions", configured with `TargetVersions` (e.g. `@('5.1')`). It also states it
  "cannot identify syntax elements incompatible with PowerShell 3 or 4 when run from those
  PowerShell versions because they aren't able to parse the incompatible syntaxes" - the same
  blindness applies to a 5.1 target checked by a 7 parser, so pair the rule with a real 5.1 parse.
- `PSUseCompatibleCommands`: "identifies commands that are not available on a targeted PowerShell
  platform", configured with `TargetProfiles`. Bundled PS 5.1 profiles are Windows Server 2016 and
  Windows Server 2019 only (`win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`);
  there is no bundled Server 2022/2025 profile. Custom profiles are generated with the
  `PSCompatibilityCollector` module shipped in the same repository.
- Both rules default to `Enable = $false` and are warnings, so "no analyzer findings" is only true
  if the job is told to treat them as errors.

### 2.6 Other cited facts

- `ConvertTo-Json` (`reference/5.1/.../ConvertTo-Json.md`): "-Depth ... The value can be any number
  from `1` to `100`. The default value is `2`. `ConvertTo-Json` emits a warning if the number of
  levels in an input object exceeds this number."
- `ConvertFrom-Json` (`reference/5.1/.../ConvertFrom-Json.md`): the 5.1 syntax has only
  `-InputObject` (no `-AsHashtable`, no `-Depth`); "In Windows PowerShell 5.1, `ConvertFrom-Json`
  returns an error when it encounters a JSON comment"; duplicate keys do not error - "only the last
  key is used by this cmdlet".
- `Set-StrictMode` (`reference/5.1/.../Set-StrictMode.md`): versions `1.0`, `2.0`, `3.0`, `Off`;
  off is the default, so uninitialized variables are `$null`, missing properties return `$null`,
  and invalid array indexes return `$null`.
- `about_Execution_Policies` (`reference/5.1/...`): `MachinePolicy` and `UserPolicy` are set by
  Group Policy and cannot be changed by the cmdlet; otherwise precedence is
  `Process` > `CurrentUser` > `LocalMachine`.
- `PowerShell/PowerShell` `CHANGELOG/7.0.md`: "Support ternary operator in PowerShell language
  (#10367)"; null-coalescing engine work in 7.0. These constructs do not exist in 5.1.
- `about_Operators` (7.5): documents pipeline chain operators `&&` and `||`; not present in 5.1.

## 3. Gate model: what CI can and cannot prove

CI proves (must be enforced by a failing job, not by convention):

| Claim | Gate |
|---|---|
| Committed text files are ASCII, BOM-free, and `.bat` uses CRLF | static job, section 6 |
| No production or test file can invoke a destructive disk/partition operation | static AST contract, section 6 |
| Every `.ps1`/`.psm1`/`.psd1` parses under Windows PowerShell 5.1 | Windows 5.1 job, section 7 |
| The double-click launcher runs under `cmd.exe`, resolves its own directory, and propagates exit codes | Windows integration job, section 10 |
| Behavior of guards, state machine, resume, logging is correct under fixtures | Pester unit/contract tests, section 8 |
| The destination guard refuses an unsafe destination, including the machine's own system disk | Pester test against read-only real inventory on Windows, plus fixture tests |
| Live vendor paths are never faked | tag policy plus explicit skips, section 13 |

CI cannot prove (owner gate, section 13; these must stay visible as skipped, never as passing):

- Licensed File Scavenger or R-Studio GUI behavior, control names, timing, completion signals.
- Behavior on a non-elevated session (GitHub Windows runners are always administrator with UAC
  disabled).
- Real disk/partition topology variation across technician machines; only recorded fixtures exist.
- Long-running scan/recovery duration, disk-full mid-recovery, destination removal mid-recovery,
  and true double-click interaction on a real desktop.
- Graceful-close/force-close behavior against a real application process.

## 4. Proposed repository layout

Final names are owned by the implementer, but the split is a decision, because `AGENTS.md` requires
one writer per file and Pester lane selection depends on directory boundaries.

```
.github/workflows/ci.yml                 # static+linux, windows-2022, windows-2025 jobs
tests/
  static/
    Encoding.Contract.Tests.ps1          # ASCII, BOM, CRLF, UTF-16 signature checks
    Safety.Contract.Tests.ps1            # banned-command AST scan over modules/ + launcher
    Ps51.Syntax.Tests.ps1                # PS7-only construct scan (fast Linux feedback)
    Launcher.Contract.Tests.ps1          # .bat content/allowlist/exit-code contracts
    TestLayout.Contract.Tests.ps1        # no real paths, no vendor exe refs in non-live tests
  unit/
    <One file per production module>.Tests.ps1
  integration/
    Launcher.Windows.Tests.ps1           # executes the real .bat through cmd.exe (dry-run only)
    Preflight.Windows.Tests.ps1          # read-only real inventory assertions, no writes
  live/
    FileScavenger.Live.Tests.ps1         # tagged LiveVendor, excluded from CI
    RStudio.Live.Tests.ps1               # tagged LiveVendor, excluded from CI
  fixtures/
    disk/*.json                          # recorded, sanitized inventory samples
    ui/*.json                            # synthetic application/UI state trees
    state/*.json                         # job-state samples for reader/writer round trips
  tools/
    Invoke-CiTests.ps1                   # single entry point for all lanes
    Test-TextFileContract.ps1            # ASCII/BOM/CRLF checker implementation
    Invoke-Ps51SyntaxGate.ps1            # 5.1 parse + analyzer compatibility run
    Get-BannedCommandScan.ps1            # AST scan
  PesterConfiguration.psd1               # shared configuration object for every lane
tools/
  Record-DiskFixture.ps1                 # lab-machine fixture recorder (owner-run, read-only)
modules/
  ...                                    # production modules, one writer per file
```

Rules for this layout:

- `tests/static/` must contain no `Start-Process`, no storage cmdlets, and no fixture recording; it
  must be runnable on Linux with `pwsh` only.
- `tests/unit/` may use cmdlets that exist only on Windows, but only through a seam (section 9).
  Any unit test that requires a real disk is a defect, not a test.
- `tests/live/` is the only place allowed to reference a vendor executable path or a licensed
  install; CI must exclude it by directory and by tag.
- `TestDrive:` (Pester) is the only writable root used by tests. Any test that writes to
  `$env:ProgramData`, `C:\`, or a drive root must be rejected in review.

## 5. Job topology

Four CI jobs, all on `ubuntu-latest`/`windows-2022`/`windows-2025` with explicit images, plus one
non-CI owner gate.

| Job | Image | Shell | Purpose |
|---|---|---|---|
| `static-linux` | `ubuntu-latest` | `pwsh` | ASCII/no-BOM/CRLF, AST safety contracts, PS7-only construct scan, launcher content contracts. Fast feedback; no Windows API use. |
| `test-win2022` | `windows-2022` | `powershell` (5.1) | PS 5.1 parse gate, Pester unit+contract tests, real `.bat` integration, read-only real inventory assertions. |
| `test-win2025` | `windows-2025` | `powershell` (5.1) | Same suite as `test-win2022`; catches image/OS drift. |
| `compat-analyze` | `windows-2022` | `pwsh` | PSScriptAnalyzer with `PSUseCompatibleSyntax` (5.1) and `PSUseCompatibleCommands` (5.1 profile), findings as errors. |
| `owner-live` | technician machine | n/a | Manual, licensed applications, never in CI (section 13). |

Notes on the topology:

- `shell: powershell` is Windows PowerShell 5.1 and `shell: pwsh` is PowerShell 7; both are present
  on both images. Every run step must declare its shell explicitly so that a future image default
  change cannot silently move a 5.1 step to 7.
- Do not use `windows-latest`; it currently equals `windows-2025`, and the project contract names
  both operating systems.
- Pin every action (for example the checkout action) to a released major tag; never a floating
  branch. Record the pinned version in the workflow comments.
- Set `timeout-minutes` on every run step that executes the launcher. A launcher that blocks on an
  interactive prompt would otherwise consume the 360-minute default job timeout.
- Upload Pester NUnit output and the static checker report as job artifacts so a red job is
  diagnosable without a rerun.
- Optional in v1: Pester code coverage over `modules/` only, with a floor. Coverage must never be
  accepted in place of a safety contract test.

## 6. Static contract suite (Linux lane)

### 6.1 Text-file contract checker

One implementation (`tests/tools/Test-TextFileContract.ps1`), executed with `pwsh` on Linux and with
either engine on Windows, so the same logic gates every platform.

Checks per file, over the tracked set (`.ps1 .psm1 .psd1 .psm1 .bat .cmd .md .txt .yml .yaml .json`
plus an explicit list of extensionless tracked files):

1. Encoding: read all bytes; fail if any byte is `>= 0x80`.
2. BOM: fail if the file starts with `EF BB BF` (UTF-8 BOM), `FF FE` (UTF-16LE), or `FE FF`
   (UTF-16BE).
3. `.bat`/`.cmd` only: fail on any LF not preceded by CR, and fail if the file does not end with
   CRLF.
4. Determinism: report the path and byte offset of the first violation; exit non-zero on any
   violation.

Deliberate policy decision: no allowlist. The repository rule is "pure ASCII and without a BOM"; a
future non-ASCII need is a change to `AGENTS.md`, not a skip entry that quietly widens the rule.
Binary fixtures must not exist; all fixtures are JSON text (section 9.4).

While this artifact was written, non-ASCII output was checked with `file` and a byte-range scan
against the artifact itself, which is the same check the checker performs.

### 6.2 Banned-operation AST contract

Parse every `.ps1`/`.psm1`/`.psd1` under `modules/`, `RecoveryAutomation.ps1`, and `tests/` with
`[System.Management.Automation.Language.Parser]::ParseFile(...)`, walk every `CommandAst`, and
resolve the command name (including `-Name` values, splatted names, and `%`/alias forms). Fail when:

- A command name matches the destructive or disk-state-changing set: `Format-Volume`,
  `Initialize-Disk`, `Clear-Disk`, `Set-Disk`, `Remove-Partition`, `New-Partition`,
  `Resize-Partition`, `Set-Partition`, `Repair-Volume`, `Repair-Partition`, `Optimize-Volume`,
  `Add-PartitionAccessPath`, `Remove-PartitionAccessPath`, `New-Volume`, `Set-Volume`,
  `Mount-DiskImage`, `Dismount-DiskImage`, `Reset-PhysicalDisk`, `Set-PhysicalDisk`, and the
  external tools `chkdsk`, `diskpart`, `format`, `bcdedit`, `cipher`, `mbr2gpt`, `convert`,
  `fsutil`, `bootrec`, `sfc`. Matching is on the resolved command name, so read-only neighbours
  such as `Format-Hex`, `Get-Volume`, and `Get-Disk` are unaffected.
- A command name is an ambiguity or dynamic call: `Invoke-Expression`, `iex`, or a `CommandAst`
  whose first element is an expression/variable rather than a literal name (for example `& $cmd`).
- A string literal matches `\\.\PhysicalDrive\d*`, `\\\?\Volume`, or `\Device\Harddisk`.
- `Remove-Item` appears anywhere without an explicit `-LiteralPath`/`-Path` whose value is not a
  variable or a path built from a job-root parameter (reviewed by hand if flagged).
- `Start-Process` is invoked with a path that is not produced by the verified vendor-executable
  discovery function (allowlist by AST shape rather than by string).

Also fail when `tests/unit/**` or `tests/static/**` contains a Windows drive-root literal
(`^[A-Za-z]:\\`) or a reference to a vendor executable name; those belong in `tests/live/` only.

Why AST and not text search: the project must remain provably non-destructive against accidental
renames, alias forms, and commands hidden in helper functions. AST scanning also makes the contract
enforceable in review ("the scan fails") instead of aspirational.

### 6.3 PowerShell 7-only construct scan

A fast, Linux-runnable scan that reports the constructs known to be 7-only, using the AST plus token
kinds: ternary (`? :`), null-coalescing (`??`, `??=`), pipeline chains (`&&`, `||`), and the
7-only cmdlets/parameters listed in trap table entries 1, 3, 4, 15, 16. This is a duplicate gate by
design: Linux feedback is seconds, and the authoritative gate (section 7) runs on Windows.

## 7. Windows PowerShell 5.1 syntax and availability gate

Two independent checks on `windows-2022` and `windows-2025`:

1. Real 5.1 parse gate (authoritative). Run through `powershell.exe` (not `pwsh`) and, for each
   `.ps1`/`.psm1`/`.psd1`, call
   `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)`
   and fail on any error, printing file, line, and message. This is the only gate that can catch
   syntax the 7 parser silently accepts (verified in section 2.2).
2. PSScriptAnalyzer compatibility gate. Run the analyzer under `pwsh` with
   `PSUseCompatibleSyntax` enabled with `TargetVersions = @('5.1')` and `PSUseCompatibleCommands`
   enabled with a 5.1 profile. The bundled 5.1 profile
   (`win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`,
   Windows Server 2019) is a documented starting point; a Server 2022/2025 profile must be
   generated with the `PSCompatibilityCollector` module if the team wants OS-accurate command
   availability. Findings must be promoted to errors in the job (both rules default to
   `Enable = $false` and `Severity = Warning`).

Additionally, the Windows jobs must assert their own environment, so a silent image change is
visible rather than assumed:

- `$PSVersionTable.PSVersion.Major` equals 5 for every 5.1 step.
- The OS caption/build matches the expected image (read-only; `Get-CimInstance` is available on
  Windows).
- The loaded Pester module version is the pinned one (trap 13).

Keep production code free of the storage/CIM command surface outside the storage seam: unit tests
on Linux cannot reference it at all (verified in section 2.2).

## 8. Pester layout, pinning, and tags

- Pin the version explicitly in the lane runner: import Pester with a minimum/required version of
  5.x and assert it. Do not rely on default resolution: the image carries 3.4.0 and 5.9.0, and
  Pester 3 has a different invocation model and different assertion semantics (trap 13).
- Drive every lane from one `PesterConfiguration` object (`New-PesterConfiguration`) rather than
  ad-hoc parameters, so lane differences are data, not code. The exact configuration property names
  must be confirmed against the installed Pester help (`Get-Help New-PesterConfiguration -Full`)
  before the runner is committed; this artifact does not assert unverified key names (section 14).
- Required lane behavior: fail the job on any failed test and on any non-zero exit; emit NUnit XML
  for artifact upload; print the resolved Pester, PowerShell, and OS versions in the job log.
- Tags: `Static`, `Unit`, `Integration`, `LiveVendor`, `LiveElevation`. CI runs
  `-ExcludeTag LiveVendor,LiveElevation`. Tags are part of the contract: a live-tagged test must
  never be reachable from a CI lane, and a test that skips for a missing license must be `Skip`
  (visible), never `Pass`.
- Strict mode: at least one lane runs the whole suite with `Set-StrictMode -Version 3.0` active for
  production modules to catch typo-to-`$null` bugs (trap 5). If that proves too invasive for
  third-party interaction, record the decision and add a contract test that the shipped entry point
  sets strict mode.
- TDD workflow (from `AGENTS.md`): one failing test first, run it RED in the narrowest lane, then
  the minimum implementation, then GREEN, then refactor. The static contracts are written before
  the modules they guard, so the first CI run of a new module is already constrained.

## 9. Synthetic seams

The seam list below is the design decision this artifact contributes. Every OS-touching operation in
the workflow must be reachable through exactly one of these functions, so that a test double can
replace it without a real disk, a real application, or a real clock.

| Seam (production) | Reads/writes | Test double | Guarantee that no real device is touched |
|---|---|---|---|
| `Get-RecoveryVolumeInventory` | Volumes, partitions, physical disks (read-only) | Fixture-backed function returning recorded, sanitized objects | Fixture file read only; no storage cmdlet is called |
| `Test-RecoveryElevated` | Process token elevation | Injected value | No OS call |
| `Get-RecoveryDestinationSpace` | Free space on the destination path | Fixture/injected number | No disk query; supports low-space and lost-destination cases deterministically |
| `Test-RecoveryDestinationSeparation` | Compares source and destination physical disk identity | Fixture inventory | Pure function over data; the same function is also used against real read-only inventory in the integration lane |
| `Start-RecoveryVendorProcess` | Launches a verified vendor executable | Recording fake | Fake never starts a process; assertions are on recorded argument sets |
| `Get-RecoveryVendorAppState` | Application process/window state (documented interfaces only) | Synthetic state tree from `tests/fixtures/ui/*.json` | No application, no window, no screen coordinates |
| `Get-RecoveryClock` | Current time for logs and state | Fixed/stepped clock | Deterministic timestamps; no culture-dependent formatting |
| `Write-RecoveryLogEntry` | Append-only ASCII log | Path under `TestDrive:` | Writes only inside the test drive |
| `Write-RecoveryJobState` | Machine-readable job state (JSON) | Path under `TestDrive:` | Writes only inside the test drive |

### 9.1 Injection style

Preference order for new code:

1. Parameter injection: the public function takes the dependency as a parameter with a production
   default (`-InventoryProvider`, `-Clock`, `-ProcessRunner`). Tests pass a double explicitly. This
   works with no Pester scoping rules and no module internals.
2. `Mock` with `-ModuleName`/`InModuleScope` for existing internal functions that must be
   intercepted. This works only for commands resolved in the module scope; it cannot intercept
   anything in a child process.

Consequence to design around: any behavior that must be doubled cannot live in a separate process.
For vendor interaction that genuinely requires a child process, the launcher boundary itself is the
seam and the test asserts on recorded arguments/state, never on real execution.

### 9.2 Rules that keep doubles safe

- No production module may contain a test-mode branch (`if ($IsTest)`). Seams are parameters.
- No test may mock a destructive command "into existence"; the banned set from section 6.2 stays
  banned, so a mock cannot create the impression that the workflow formats or repairs anything.
- Every test that writes goes through `TestDrive:`; every production write function takes its root
  from a parameter that the tests override.
- A dedicated contract test asserts that no file under `tests/unit` or `tests/static` calls a
  storage-modifying cmdlet or starts an external process, and that no non-live test references a
  vendor executable name.
- Tests must fail loudly if a double is missing: production defaults must refuse to run when they
  detect a non-interactive test context without an explicit provider. The implementer should assert
  `$env:RECOVERY_ALLOW_LIVE_VENDOR` is unset in non-live lanes and treat its presence as a test
  failure, so a mis-tagged test cannot reach a licensed application.

### 9.3 Fixture policy

- Recorded fixtures (disk inventory) come from `tools/Record-DiskFixture.ps1`, run by the owner on a
  lab machine, read-only, writing JSON. Each fixture file records: capture date, OS build, PowerShell
  version, and the read-only commands used. Serial numbers and volumes must be sanitized before
  commit; the scrub step is part of the recorder, not a manual afterward.
- Synthetic fixtures (UI/application state trees, state samples) are hand-authored JSON derived from
  the vendor research artifacts, and must be marked as synthetic in the file itself. If the vendor
  research has no evidence for a state, the fixture must not invent one; the corresponding test
  should be a live test that skips in CI.
- Fixtures are text only, which keeps them inside the ASCII/no-BOM contract.

## 10. Windows launcher (`.bat`) CI contract

The launcher is the only component that is invoked by a human double-click, so it is tested by
executing the real file with `cmd.exe` on both Windows images.

Required launcher behavior (all testable):

1. Resolve its own directory: `cd /d "%~dp0"` (or use `%~dp0` directly in the `powershell.exe`
   path). A launcher that relies on the inherited working directory is a defect; T3 below proves it.
2. Invoke Windows PowerShell 5.1 explicitly:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RecoveryAutomation.ps1" %*`.
   Do not use `pwsh` and do not use `-Command` (trap 7).
3. Propagate the exit code: capture `%ERRORLEVEL%` immediately after the PowerShell call, and end
   with `exit /b %RC%`. Never a bare `exit`, which terminates the calling `cmd.exe` shell process and
   can hide the code from the CI step.
4. Pause only for an interactive session: honor an explicit opt-out (`RECOVERY_NO_PAUSE=1`, and/or a
   `-NoPause` argument passed through to the script), and do not pause in CI lanes.
5. Contain only an allowlist of commands: `@echo off`, `set`, `cd`, `if`, `goto`, `call`/direct
   invocation of `powershell.exe`, `echo`, `pause`, `exit /b`. No `del`, `format`, `diskpart`,
   `chkdsk`, `bcdedit`, `attrib`, `robocopy` copy semantics into the source, or `rmdir`.
6. Remain pure ASCII with CRLF line endings (section 6.1).

Integration tests (`tests/integration/Launcher.Windows.Tests.ps1`):

- T1 Upper bound on interactivity: run the launcher in a help/dry-run mode with a step timeout and
  assert it terminates within a few seconds and returns 0. This is the guard against a `pause` that
  blocks CI.
- T2 Exit-code fidelity: force a known failure inside the script (for example an invalid argument or
  a preflight refusal against a synthetic inventory) and assert the exact non-zero code reaches
  `%ERRORLEVEL%` of `cmd.exe`.
- T3 Location independence: execute the launcher from a different working directory (for example the
  runner temp root) and assert it still locates the script and exits 0.
- T4 Argument pass-through: assert the script received the exact argument list the launcher was given
  (the dry-run mode echoes the bound parameters, which is logged evidence, not a vendor claim).
- T5 No-op safety: assert that a normal dry-run makes no file system change outside `TestDrive:` or
  the runner temp root (compare a directory snapshot before/after).
- T6 Static content contract: the allowlist check from section 10.5 runs on Linux as part of the
  static lane, so a launcher change is caught even before the Windows job starts.

Open behavioral question to settle in the first Windows run (section 14): whether `pause` returns
immediately when stdin is redirected from `NUL`. If it does not, the launcher contract must depend
only on the explicit opt-out, and true double-click pause behavior moves entirely to the owner gate.

## 11. PowerShell 5.1 trap table

| # | Trap | Symptom if missed | Detection in this design | Mitigation |
|---|---|---|---|---|
| 1 | 7-only language constructs (`? :`, `??`, `??=`, `&&`, `||`) | Linux parser gate is green; 5.1 fails at parse time on the technician machine | 7-only AST scan (6.3) + `PSUseCompatibleSyntax` TargetVersions 5.1 + real 5.1 parse (7.1) | Keep the target at 5.1; never ship 7-only syntax |
| 2 | Encoding/BOM divergence (`Out-File`/`>` = UTF-16LE in 5.1; `Set-Content`/`Add-Content` = ANSI for new files; `UTF8` = BOM in 5.1; no `utf8NoBOM`) | Logs and job state become UTF-16 or BOM'd, breaking the ASCII/no-BOM rule and any downstream parser | Text-file contract (6.1) plus a Windows-job round-trip test that reads produced artifacts byte-wise | Logs: `Add-Content -Encoding ASCII` always explicit. State: `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`. Never `>`/`Out-File` for machine state |
| 3 | `ConvertTo-Json -Depth` default 2 | Nested job state silently truncated, with only a warning; resume reads a half state | Round-trip test with a deep state object; assert warning count is zero and no property is missing | Always pass an explicit `-Depth` and assert the round trip |
| 4 | `ConvertFrom-Json` 5.1 differences (no `-AsHashtable`, no `-Depth`, comments are an error, duplicate keys keep the last value) | Reader works on 7 and throws or returns `PSCustomObject` where a hashtable was assumed; comments in a state file break resume on 5.1 | Unit tests that read the exact state-file samples with the 5.1 lane; type assertions on the parsed object | No comments in state JSON; helper accessor for property probing; never assume hashtable semantics |
| 5 | Strict mode is off by default | A misspelled variable/property yields `$null` and takes a wrong (possibly unsafe) branch silently | Whole suite run under `Set-StrictMode -Version 3.0`; contract test that the entry point sets it | Enable strict mode in the entry point and modules; probe `PSObject.Properties['x']` instead of direct member access on deserialized JSON |
| 6 | Classes defined in modules are not visible after `Import-Module` in 5.1 | Type resolution failure at runtime; `using module` cannot be used from a `cmd.exe`-launched `-File` script | The 5.1 lane must exercise every public entry point | Avoid classes/enums in v1 production modules; use functions and `PSCustomObject`. If a class is unavoidable, it must not cross the launcher boundary |
| 7 | `$PSScriptRoot`/`$PSCommandPath` empty under `-Command` | Module discovery fails depending on how the script was launched | Launcher integration test executes the real launcher (`-File`), never `-Command` | Launcher uses `-File`; modules resolve paths with `$PSScriptRoot` inside the `.psm1` |
| 8 | Exit-code propagation (`exit` vs `exit /b`; scripts that error without `exit` may return 0) | A failed recovery stage looks successful to the operator and to CI | T2 in section 10; a Windows-job assertion that a forced failure returns the documented code | Explicit `exit N` in the entry script; `exit /b %RC%` in the launcher |
| 9 | ExecutionPolicy precedence (`MachinePolicy`/`UserPolicy` win; GPO cannot be overridden by the cmdlet) | Launcher silently blocked or forced to a policy that refuses the script | Preflight logging of `Get-ExecutionPolicy -List`; integration test asserting the launcher runs | `-ExecutionPolicy Bypass` on the `powershell.exe` command line; on failure, require a clear message naming the blocking scope |
| 10 | Storage/CIM cmdlets exist only on Windows | Linux lanes cannot run unit tests for discovery; tests that call them fail on Linux | Contract test rejecting storage/CIM cmdlets in Linux-run lanes; section 2.2 local observation | Keep them inside the storage seam; Linux lanes only run parser/static tests |
| 11 | Culture-dependent formatting of dates/numbers | Logs and state files differ per machine; comparison tests flake | Tests executed with a non-invariant current culture set in one dedicated test to prove invariance | Use the round-trip format (`-Format 'o'`) and explicit invariant culture for machine-readable values |
| 12 | CI is always elevated with UAC disabled | The "not elevated" refusal path is never exercised; a destructive mistake would succeed in CI | Not detectable in CI. The destination guard is still tested against the runner's own system disk (read-only) | Elevation is a seam; the non-elevated behavior is verified in the owner gate on a real non-admin session |
| 13 | Pester 3.4.0 and 5.9.0 both present on the image | Tests written for Pester 5 run under a different engine, or vice versa, with confusing failures | Smoke assertion of the loaded Pester version in every lane | Pin with a minimum/required version when importing Pester and assert the version in the job log |
| 14 | Interactive-host assumptions (`$Host.UI.RawUI`, console size, `Read-Host`) | Script hangs or throws in CI, or on a minimized console | Integration tests with a step timeout; static scan forbidding console-size reads | No console UI, no coordinates; prompts only as explicit operator gates, and never in the automated path |
| 15 | 7-only cmdlets/parameters (`Test-Json`, `-AsByteStream`, `-Encoding utf8NoBOM`, `Get-Error`) | Works in dev on 7, fails on the technician machine | 7-only construct scan; Windows 5.1 lane | Use `ConvertFrom-Json` in try/catch for validation; `ReadAllBytes`/`ReadAllText` for byte-accurate IO |
| 16 | Long destination paths (MAX_PATH) | Recovery writes fail deep into a job folder long after the scan | Unit test with a deep synthetic path under `TestDrive:`; path-length budget assertion in the path builder | Enforce a documented path-length budget and surface a manual gate instead of failing mid-recovery |
| 17 | `Add-Content` auto-detects existing file encoding (ANSI when the file has no BOM) | Append-only log changes encoding mid-file, corrupting the ASCII contract | Byte-level test: append to an existing ASCII log and assert the result stays ASCII with no BOM | Always pass `-Encoding ASCII` explicitly |

## 12. Non-destructive guarantees that tests must encode

Independently of the safety state machine (owned by `research/safety-resumability.md`), CI must make
these facts mechanically checkable:

1. No code path in the repository can format, initialize, repair, resize, or repartition: enforced by
   the AST contract (6.2), which fails the build on presence, not on execution.
2. No code path writes to a physical-disk or volume device path: enforced by device-path string
   detection in the same contract.
3. The destination guard refuses a destination on the same physical disk as the source: unit test on
   fixture inventories plus an integration test that feeds the machine's real, read-only inventory
   and asserts the guard refuses its own system disk.
4. Source is only ever opened read-only: contract test that source paths are only passed to read
   operations in the storage seam, and that no production function exposes a write parameter that
   accepts a source path.
5. An existing job is never overwritten: state-writer unit test that a second job creation into an
   existent job folder fails without modifying the existing files (compare content hashes).
6. Low space and lost destination pause or stop instead of redirecting: unit tests drive the space
   and destination seams to those states and assert the resulting state transition and log entry.
7. A completed stage is never silently re-run: state-machine unit tests for resume semantics
   (invariants come from the safety lane).

## 13. Owner-only live validation gate

Nothing in CI may simulate, stub, or claim File Scavenger or R-Studio behavior. The live gate is a
separate, owner-run procedure with its own record.

Rules:

- `tests/live/**` is excluded from every CI lane by directory and by `-ExcludeTag LiveVendor,
  LiveElevation`.
- Live tests must self-skip with an explicit message when the licensed product or the required
  elevation state is absent. Skips are reported, so the gap is visible in the run record; a live test
  that "passes" without the product is a defect.
- Live evidence (product display/file version, install path, build, timestamped log, screenshots,
  operator notes) is recorded in the case folder, never committed (`logs/` and `recovery-jobs/` are
  gitignored).
- The live checklist must cover at minimum: File Scavenger discovery and version reporting, short
  scan, long scan, per-stage recovery where the vendor supports it, graceful close, guarded force
  close after confirmed completion, R-Studio launch for handoff with no automatic analysis, destination
  removal mid-recovery, low-space mid-recovery, and resume of an interrupted job.
- The double-click experience (window title, pause prompt, visible failure message) is verified by a
  human at least once per release, because CI executes the launcher with redirected standard input.
- Any vendor operation without primary-source evidence stays a manual gate in the workflow; the
  operational decision belongs to the vendor research lanes, not to this design.

## 14. Open questions and unverified items

1. `pause` behavior with stdin redirected from `NUL` in `cmd.exe` is not verified in this task.
   Settle by running T1 in the first Windows CI run. Fall back to the explicit opt-out only.
2. Exact Pester 5.x properties for "exit with non-zero on failure" were not confirmed from primary
   source in this task (the 5.9.0 source layout differs from the current `main` branch). Confirm with
   `Get-Help New-PesterConfiguration -Full` in the lane before committing the runner.
3. Whether a custom Server 2022/2025 `PSUseCompatibleCommands` profile is worth generating, versus
   using the bundled Windows Server 2019 5.1 profile. The bundled profile is documented and
   conservative; generating one requires the `PSCompatibilityCollector` module and a lab machine.
4. Whether the strict-mode suite can run against the entire module set without breaking on
   third-party interaction; if not, scope it to the seams and record the exception.
5. Whether the storage seam from `research/windows-storage-ui-design.md` exposes exactly the
   inventory fields the fixtures must carry. The seam boundary here assumes volume->physical-disk
   mapping, free space, and identity fields are all available through one function.
6. GitHub runner image contents drift continuously (image versions above are dated 2026-09-07).
   Re-verify the Pester/PowerShell inventory and the OS build whenever a Windows job fails for
   environmental reasons, and never assume `windows-latest` equals a specific OS.

## 15. Implementation order and acceptance criteria

TDD order, each step one writer and one file:

1. `tests/tools/Test-TextFileContract.ps1` + `tests/static/Encoding.Contract.Tests.ps1` (RED against
   a deliberately violated fixture, then GREEN).
2. `tests/tools/Get-BannedCommandScan.ps1` + `tests/static/Safety.Contract.Tests.ps1`.
3. `.github/workflows/ci.yml` with the `static-linux` job only; prove the Linux lane is green and
   that it fails on an injected violation.
4. `windows-2022`/`windows-2025` jobs with the 5.1 parse gate and the Pester smoke test (version
   assertions), then Pester unit tests as modules appear.
5. Launcher + `tests/integration/Launcher.Windows.Tests.ps1` with T1-T5, launched by `cmd` in the
   Windows jobs.
6. `compat-analyze` job once modules exist, with findings as errors.
7. Live test skeletons (skipping) plus the owner checklist, so the gap is visible from day one.

Acceptance criteria for the CI work (a claim is only acceptable with the run linked):

- Static lane fails on: a non-ASCII byte, a BOM, a `LF`-only `.bat`, an added `Format-Volume`, an
  added `Invoke-Expression`, and a 7-only ternary. Each demonstrated with an injected violation in a
  throwaway branch and then reverted.
- Windows lanes show the real 5.1 parser gate executed under `powershell.exe`, with the OS build,
  PowerShell version, and Pester version printed.
- The launcher is executed through `cmd.exe` on both images and propagates a forced non-zero code.
- No live test runs in any CI lane, and the skipped live tests appear in the run record.
- No CI step writes outside the workspace or the runner temp directory.
