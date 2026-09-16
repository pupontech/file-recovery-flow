# Recovery Workflow Test Matrix

Status: acceptance matrix for the v1 implementation
Scope: deterministic CI/unit coverage plus explicit owner-live gates
Source of requirements: AGENTS.md, README.md, docs/WORKFLOW.md, and the completed research artifacts

This matrix is a contract for the implementation tasks. A deterministic test may
use a fixture, a fake provider, or a recording process runner, but it must not
launch File Scavenger/R-Studio, touch a real recovery disk, or pretend to prove a
vendor GUI result. A live test that lacks its licensed product or required
hardware must report Skip with an explicit reason; it must never report Pass.

## 1. Test lanes and isolation rules

| Lane | Runner | Allowed scope | Required result |
| --- | --- | --- | --- |
| Static-Linux | `pwsh` on Linux | Text bytes, AST contracts, layout, launcher text, PS 7-only scan | Fails on any contract violation; does not call Windows storage/application APIs. |
| Unit | Pester 5.x with injected providers | Pure module behavior and synthetic fixtures under `TestDrive:` | Tests deterministic decisions, state, logs, and recorded calls. No real vendor executable or external process. |
| Windows-5.1 | Windows Server 2022 and 2025, `powershell.exe` | Real Windows PowerShell 5.1 parser, Pester unit/contract tests, launcher through `cmd.exe`, read-only inventory checks | Image, PowerShell, and Pester versions are printed and asserted. |
| Compatibility | Windows 2022, `pwsh` | PSScriptAnalyzer 5.1 syntax/command compatibility | Findings from compatibility rules are errors. |
| Owner-live | Technician machine, licensed products and test media | Vendor GUI, real UIA/MSAA behavior, physical topology, media loss, capacity, source write protection, and end-to-end flow | Evidence record with build, path, timestamps, decisions, logs, and observations. Never CI. |

Non-live tests are excluded from vendor executables and live tags by both path and
policy. `tests/live/**` is the only location permitted to name a vendor executable
or licensed install. Tags `LiveVendor` and `LiveElevation` are excluded from all
CI lanes. A test must fail if `RECOVERY_ALLOW_LIVE_VENDOR` is set in a non-live
lane.

The expected implementation test files are:

```text
tests/Static.Tests.ps1
tests/Unit/Core.Tests.ps1
tests/Unit/Preflight.Tests.ps1
tests/Unit/FileScavenger.Tests.ps1
tests/Unit/RStudio.Tests.ps1
tests/Integration/Launcher.Windows.Tests.ps1
tests/Live/FileScavenger.Live.Tests.ps1
tests/Live/RStudio.Live.Tests.ps1
```

Synthetic fixtures are JSON only and are marked synthetic. Disk fixtures carry
sanitized identity evidence; UI fixtures contain only state supplied by a live
record or documented labels. No fixture may invent a vendor completion signal.

## 2. Static and cross-platform test catalogue

| Test ID | Test | Deterministic assertion | Lane |
| --- | --- | --- | --- |
| S-01 | Text encoding contract | Every committed `.ps1`, `.psm1`, `.psd1`, `.json`, `.md`, `.txt`, `.yml`, and `.yaml` byte is ASCII; no UTF-8/UTF-16 BOM exists. | Static-Linux, Windows-5.1 |
| S-02 | Batch line contract | Every `.bat`/`.cmd` line uses CRLF and the file ends in CRLF; the file is ASCII and contains no disallowed command. | Static-Linux, Windows-5.1 |
| S-03 | Destructive AST deny list | Parser walk rejects disk/partition changes (`Format-Volume`, `Initialize-Disk`, `Clear-Disk`, `Set-Disk`, `Remove-Partition`, `New-Partition`, `Resize-Partition`, `Set-Partition`, `Repair-Volume`, `Repair-Partition`, `Optimize-Volume`, `New-Volume`, `Set-Volume`, `Mount-DiskImage`, `Dismount-DiskImage`, `Reset-PhysicalDisk`, `Set-PhysicalDisk`) and native destructive tools (`chkdsk`, `diskpart`, `format`, `bcdedit`, `cipher`, `mbr2gpt`, `convert`, `fsutil`, `bootrec`, `sfc`). | Static-Linux |
| S-04 | Dynamic invocation deny list | AST scan rejects `Invoke-Expression`, `iex`, expression/variable command names, device paths, unsafe `Remove-Item`, and unverified `Start-Process` paths. | Static-Linux |
| S-05 | PowerShell 7-only scan | Static scan rejects ternary, null-coalescing, pipeline-chain operators, `Test-Json`, `-AsByteStream`, `-Encoding utf8NoBOM`, and other known PS 7-only constructs. | Static-Linux |
| S-06 | Real 5.1 parser | Every production and test PowerShell file parses with `powershell.exe` 5.1 and reports file/line errors. A pwsh-only parse is insufficient. | Windows-5.1 |
| S-07 | Compatibility analyzer | PSScriptAnalyzer runs `PSUseCompatibleSyntax` for target 5.1 and `PSUseCompatibleCommands` for the selected 5.1 profile; findings are promoted to errors. | Compatibility |
| S-08 | Launcher allowlist | Launcher contains only the approved thin command set, resolves `%~dp0`, invokes `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`, passes exact arguments, captures the return code, and ends with `exit /b`. | Static-Linux |
| S-09 | Launcher path safety | Launcher has no storage-modifying command, file deletion, copy-to-source behavior, or unsafe vendor argument construction. | Static-Linux |
| S-10 | No coordinate automation | Production and test code contains no screen-coordinate clicks, `SendKeys`, guessed window class, or raw key sequence as a vendor control strategy. | Static-Linux |
| S-11 | Non-live isolation | `tests/unit/**` and `tests/static/**` contain no `Start-Process`, storage cmdlet, Windows drive-root literal, vendor executable name, or live tag. | Static-Linux |
| S-12 | Live isolation | CI discovery excludes `tests/live/**` and tags `LiveVendor`/`LiveElevation`; absence of a product produces Skip, not Pass. | Static-Linux, Windows-5.1 |
| S-13 | Failure exit contract | A forced script/preflight failure reaches `cmd.exe` as the documented non-zero code; a blocked or paused state cannot silently return success. | Windows-5.1 |
| S-14 | Pester pin | Each Windows lane loads the pinned Pester 5.x version and fails if Pester 3 or an unexpected version is selected. | Windows-5.1 |
| S-15 | Test write root | Every test write is under `TestDrive:` or the runner temporary root; no test writes `$env:ProgramData`, a drive root, or a source fixture. | Static-Linux, Windows-5.1 |

The static deny list is a presence contract, not an execution test. It remains
required even though the Windows-hosted runners run as administrators. A
throwaway violation test must demonstrate that S-01, S-02, S-03, S-04, and S-05
actually fail before the violation is reverted.

## 3. Core deterministic behavior catalogue

The core tests use recorded disk objects and injected providers. They must cover
both the Storage-provider path and the Win32 fallback result shape without
calling either provider on Linux.

| Test ID | Test | Deterministic assertion | Lane |
| --- | --- | --- | --- |
| C-01 | Provider order and evidence | Inventory tries Storage, Storage namespace, then Win32 fallback; it records which provider answered and stops when none can prove a mapping. | Unit |
| C-02 | Volume-to-disk join | `Get-Volume -FilePath`-equivalent fixture joins through partition and disk; drive-letter and mounted-folder paths resolve to the same identity shape. | Unit |
| C-03 | Strong physical identity | Exact `UniqueId`/`UniqueIdFormat`, or exact `SerialNumber + SizeBytes + Model`, identifies a disk; disk number alone never does. Missing or contradictory strong fields set `IsIndeterminate`. | Unit |
| C-04 | Same-disk refusal | Source Disk 0 and destination Disk 0 on different volumes returns `Allowed = false`, `Decision = Blocked`, `ReasonCode = SamePhysicalDisk`, and makes no vendor call. | Unit |
| C-05 | Same-volume refusal | Source and destination resolving to the same volume returns `SameVolume` (before the overlapping physical-disk reason) and makes no output or vendor call. | Unit |
| C-06 | Unknown mapping refusal | Dynamic, Storage Spaces, File-Backed Virtual, VHD, network, missing provider, incomplete member set, or contradictory identity returns `SourceIndeterminate` or `DestinationIndeterminate`; it never returns Allowed. | Unit |
| C-07 | Unresolved path refusal | Missing container, inaccessible path, unresolved reparse target, or failed volume resolution returns `DestinationUnresolved` or `DestinationPathInvalid`; no redirect occurs. | Unit |
| C-08 | Disjoint physical disks | Two complete, strongly identified physical-disk sets with an empty intersection return `Allowed = true`; source and destination evidence are retained. | Unit |
| C-09 | Fresh identity checks | A changed source or destination identity before a stage blocks the stage and records the mismatch; a reused drive letter is never accepted. | Unit |
| C-10 | Capacity policy | The space seam uses the conservative available value, treats exceptions/unavailable values as unknown, and pauses/blocks below reserve. It never substitutes zero or another path. | Unit |
| C-11 | Reparse and root containment | Junction, symbolic-link, mount-point, traversal, and ancestor fixtures are canonicalized/re-resolved; an unresolved redirect is blocked and a resolved path must remain inside the reviewed root. | Unit |
| C-12 | Name sanitization | Invalid characters, control characters, reserved device names, trailing spaces/periods, empty names, and Unicode are converted or rejected into deterministic `[A-Za-z0-9._-]` components without silent merging. | Unit |
| C-13 | Path budget | Client component is at most 40 characters and the composed job path is below the configured 200-character v1 budget; over-budget input stops rather than truncates silently. | Unit |
| C-14 | Collision-safe job creation | A pre-existing job folder or claim file leaves sentinel bytes unchanged; `CreateNew`-style claim selects a bounded suffix or stops after exhaustion and never deletes/reuses the old folder. | Unit |
| C-15 | Log initialization | Missing/unflushable log blocks the first vendor launch. An existing unclaimed log is a collision. | Unit |
| C-16 | Append-only log | Each event has a unique ID, monotonic sequence, UTC timestamp, job/state/stage/attempt, result, identity references, and structured error/decision details. Existing event bytes are unchanged. | Unit |
| C-17 | Log encoding | Runtime log writer uses explicit encoding, emits no BOM, preserves or safely escapes dynamic values, and fails closed instead of lossy replacement. | Unit, Windows-5.1 |
| C-18 | State JSON round trip | State written at explicit JSON depth parses back with all nested identities, gates, stage, and event references present; malformed JSON/comments/duplicate or missing required fields are rejected. | Unit, Windows-5.1 |
| C-19 | State snapshot ownership | Atomic snapshot replacement is confined to the claimed job folder; it cannot replace another job's snapshot or event history. | Unit |
| C-20 | Lock exclusivity | First worker obtains the lock; second worker cannot read/launch the same job concurrently. A stale lock requires an explicit gate and is not deleted automatically. | Unit |
| C-21 | Case-before-vendor ordering | Recording fake asserts that metadata, lock, initial event, and flushed log exist before any File Scavenger launch call. | Unit |
| C-22 | Log failure stops | Append, serialization, sequence, or flush failure prevents the next external action and records the stop reason when possible. | Unit |
| C-23 | Source/output separation | Output, state, metadata, lock, event log, session, journal, and recovered-output paths are rejected if they resolve to the source physical-disk set. | Unit |

Storage identity and folder behavior in these cases follows the documented
Windows object relationships and path APIs.[25][26][27][29][30] Folder-name and
collision tests follow the documented invalid-name, `CreateNew`, directory, and
path-length constraints.[31][33][34][35][37]

## 4. Configuration and application preflight matrix

| Test ID | Test | Deterministic assertion | Lane |
| --- | --- | --- | --- |
| P-01 | Configuration schema | Schema version, workflow version, typed fields, required validated-build lists, and capacity policy are checked; unknown schema/fields and malformed JSON stop. | Unit |
| P-02 | Safe defaults | Missing source, destination, executable, build allowlist, capacity, or UI map does not become an implicit value; same-disk override, vendor overwrite, and automatic analysis remain false. | Unit |
| P-03 | Explicit override allowlist | Valid typed overrides replace only named values; attempts to set `AllowSameDiskOverride`, `AllowVendorOverwrite`, or another immutable safety rule are rejected. | Unit |
| P-04 | Application identity | Candidate path must exist and match the requested product/version evidence. File Scavenger and R-Studio identity fields are recorded without launching. | Unit |
| P-05 | Candidate precedence | Explicit path/config path is considered first, then bounded discovery evidence; multiple valid candidates produce an ambiguity gate, not first-result selection. | Unit |
| P-06 | Wrong R-Studio utility | R-Studio Agent and Emergency candidates are rejected for the R-Studio for Windows handoff. | Unit |
| P-07 | Portable path | Portable product copies require explicit path and identity verification; no universal install path is assumed. | Unit |
| P-08 | Missing application | Missing, unreadable, unexpected version, or identity mismatch produces a named preflight error and no launch call. | Unit |
| P-09 | Elevation seam | True, false, and unknown elevation provider results are deterministic; false/unknown produces G-01 and no vendor call. | Unit |
| P-10 | Runtime evidence | Windows lane asserts actual PowerShell major version, OS image, and Pester version before executing behavior tests. | Windows-5.1 |
| P-11 | Real preflight inventory | Windows runner can read its own working-directory volume and inventory through the read-only seam; it never uses the runner system disk as an output destination. | Windows-5.1 |
| P-12 | Installed product/admin behavior | Actual product path, About/runtime version, administrator requirement, and license/build behavior are recorded. | Owner-live |

The File Scavenger vendor documents an administrator requirement and About version
surface.[3][15] R-Studio's Windows requirements likewise require administrative
privileges, while its download page lists separate Windows, Agent, and Emergency
utilities.[16][24]

## 5. File Scavenger adapter matrix

The official research establishes GUI terminology and file artifacts but no
supported unattended command-line/config/API contract.[4][12] The documented
labels and artifacts therefore test how the adapter exposes evidence and gates,
not permission to invent automation.

| Test ID | Test | Deterministic assertion | Lane |
| --- | --- | --- | --- |
| F-01 | Launch-only argument set | Recording process runner receives the verified executable and no scanner switch, source path, destination path, macro, config, or session path argument. Process path/PID/start identity is retained. | Unit |
| F-02 | Launch preconditions | File Scavenger launch is refused unless state is `CASE_READY`, log is flushed, lock is owned, app identity is verified, elevation passed, and fresh disk checks pass. | Unit |
| F-03 | No supported automation contract | With no exact-build evidence map, scan, criteria, source, destination, result selection, Save, and close requests return named G-04 manual gates. | Unit |
| F-04 | Exact-build map requirement | A UI action is accepted only when a build-matched owner map contains the actual control properties and action/result evidence; absent, ambiguous, localized, or mismatched descriptors are rejected. | Unit |
| F-05 | Coordinate-free action | UI provider receives a documented control descriptor/handle only; coordinates, `SendKeys`, and guessed names are rejected. | Unit |
| F-06 | Scan/recovery distinction | `ScanFinished` cannot create `RecoveryFinished`, `RecoveryVerified`, close success, long-stage readiness, or handoff readiness. | Unit |
| F-07 | Process exit is not completion | Process exit, window disappearance, output-folder existence, or 100 percent alone yields unknown/manual review, never a verified stage. | Unit |
| F-08 | Quick/Long state mapping | Internal `SHORT_*` states are recorded as vendor `Quick scan`; `LONG_*` states are recorded as vendor `Long scan`. No silent mode switch occurs. | Unit |
| F-09 | Manual stage order | Quick scan cannot be skipped to Long; short recovery must be verified before Long scan; Long recovery must follow verified Long scan. | Unit |
| F-10 | Output evidence separation | Recovery log/status, output inventory, session `.fss`, CSV, and journal observations are recorded separately from vendor completion. Unknown CSV status columns and exact `Recovery.log` semantics remain unknown until live evidence. | Unit |
| F-11 | Same-drive override | Adapter never supplies `Yes` to `Overriding code`, even when the vendor presents the prompt. | Unit |
| F-12 | Overwrite/journal prompts | Adapter never selects vendor `Overwrite`, persistent "do not ask again", or a journal-overwrite answer; each becomes G-09/manual. | Unit |
| F-13 | Pause/stop uncertainty | Destination loss, low space, source identity change, UI ambiguity, or unknown application state pauses/stops and preserves output without redirect. | Unit |
| F-14 | Graceful close guard | File > Exit is requested only after validated safe state or a documented pause/stop path; failure returns G-08 and does not force-kill. | Unit |
| F-15 | Force close guard | Force close is denied during scan, recovery, or `INTERRUPTED_UNKNOWN`; it requires verified recovery completion, job-bound process identity, explicit confirmation, and logged post-close verification. | Unit |
| F-16 | Live GUI and completion evidence | Exact UIA/MSAA properties, status values, `Recovery.log`, CSV columns, `.fss` resume, journal, close, and pause/resume behavior are recorded on the exact licensed build. | Owner-live |

QueTek documents Quick/Long, `Scan`, `Pause`, `Step 2: Save`, `Save to`,
`Save`, sessions, CSV listing, and scan journals, but the research marks UIA
reachability, exact log/CSV semantics, macro behavior, and several combined
resume behaviors as live unknowns.[5][6][7][8][9][10][12]

## 6. R-Studio handoff and technician UI matrix

The normal R-Studio boundary is the documented launch-only surface: `-safe` and
optional `-log <filename>` only, then a manual main-panel handoff.[17][18][19][22]

| Test ID | Test | Deterministic assertion | Lane |
| --- | --- | --- | --- |
| R-01 | Handoff state guard | R-Studio launch is refused unless File Scavenger work is verified, close is verified, final identities pass, log/state are durable, and state is `READY_FOR_HANDOFF`. | Unit |
| R-02 | Exact safe arguments | Recording runner receives exactly `-safe`, with no source, destination, scan, project, report, folder, analysis, recovery, or window-activation argument. | Unit |
| R-03 | Optional log safety | When configured, `-log` is followed by one validated non-source case-log path; missing/unsafe/unwritable path blocks and no launch occurs. | Unit |
| R-04 | Process identity | Returned process path, PID, start time, and product identity are retained; a process exit does not imply analysis/recovery completion. | Unit |
| R-05 | Main-panel gate | Launch returns a manual main-panel/readiness gate and does not select a drive, invoke Find partition, scan, mark, recover, or choose a destination. | Unit |
| R-06 | Separate Explorer action | Optional client-folder open is a separate recording call after path validation; passing the client folder to R-Studio is rejected. | Unit |
| R-07 | No write-capable action | Adapter exposes no `Enable Write`, editor, wipe, repair, partition, or recovery action. | Static-Linux, Unit |
| R-08 | Handoff panel actions | Technician UI exposes only explicit Close, Copy client name, and Open client folder actions; those actions do not start a vendor process or recovery. | Unit |
| R-09 | Always-on-top panel | UI seam records topmost/foreground request and client-name display without screen coordinates; failure becomes a visible UI/manual gate. | Unit |
| R-10 | Folder picker path | FolderBrowserDialog seam returns `SelectedPath`; typed-path fallback uses the same resolver. Shell `BrowseForFolder` object without a documented path property is not used for safety. | Unit |
| R-11 | Live R-Studio behavior | Exact installed path/build, `-safe`, optional `-log`, main panel, no automatic analysis, separate Explorer action, and write-capable exclusions are observed on a licensed build. | Owner-live |

The vendor documents the R-Studio main panel and requires further operator actions
for scan/recovery; its settings document write-capable features that remain
outside the workflow.[18][19][21][22] The Windows folder picker contract relies on
the documented `SelectedPath` property, while the Shell Folder return object's
filesystem path is not documented.[32][38][39]

## 7. Launcher and CI matrix

| Test ID | Test | Deterministic assertion | Lane |
| --- | --- | --- | --- |
| W-01 | Location independence | Execute the real batch file from a different working directory; `%~dp0` still locates `RecoveryAutomation.ps1`. | Windows-5.1 |
| W-02 | Argument fidelity | Dry-run entry point receives the exact argument sequence supplied to the batch file. | Windows-5.1 |
| W-03 | No-pause mode | `RECOVERY_NO_PAUSE=1` or explicit no-pause option terminates a dry run without waiting for stdin. | Windows-5.1 |
| W-04 | Exit-code propagation | Forced script failure reaches the invoking `cmd.exe` through `exit /b`; a bare `exit` is rejected by S-08. | Windows-5.1 |
| W-05 | CI lane topology | Workflow contains pinned static-Linux, Windows 2022, Windows 2025, compatibility, and explicit excluded owner-live boundaries. | Static-Linux |
| W-06 | No live vendor CI | No CI step installs, launches, or fakes File Scavenger/R-Studio; live tests are skipped/excluded and visible in the run record. | Static-Linux, Windows-5.1 |
| W-07 | Artifact upload | Failed Pester/static lanes produce the configured diagnostic report without writing outside workspace/temp roots. | Windows-5.1 |
| W-08 | First Windows pause check | The initial Windows run records whether redirected stdin makes `pause` return; if not, CI relies only on explicit no-pause behavior. | Windows-5.1 |

The launcher must call Windows PowerShell 5.1 explicitly and remain a thin
location/exit-code wrapper. The two pinned Windows images and owner-live split
follow the CI research blueprint.

## 8. Workflow requirement mapping

These rows map every numbered requirement in `docs/WORKFLOW.md` to one or more
tests or an owner-only gate. The requirement text is reproduced only as a short
label; the implementation specification is the normative behavior.

| Requirement | Requirement label | Deterministic coverage | Owner-only coverage or boundary |
| --- | --- | --- | --- |
| WFR-01 | Explicit/logged elevation, File Scavenger discovery, and R-Studio discovery | P-01 through P-10; C-15/C-16; W-05 | P-12 records the actual installed products, versions, and elevation behavior. |
| WFR-02 | Source exposes volume and physical-disk identity | C-01 through C-09, C-23, P-11 | Real topology and write-blocker evidence are L-01/L-02. |
| WFR-03 | Folder browser, sanitized unique client folder, separate physical disk | C-07, C-11 through C-14, C-23, R-10 | Actual picker, reparse behavior, and two-disk case are L-02/L-07. |
| WFR-04 | Metadata, append-only log, and resumable state before scanner work | C-15 through C-22, C-21 | L-03 confirms durable evidence around a real vendor launch. |
| WFR-05 | Short/Quick and Long scan/recovery stages distinct | F-06, F-08, F-09, state transition tests, I-06/I-07 | L-03 validates the exact vendor GUI sequence. |
| WFR-06 | No long stage until preceding recovery verified | F-09 and state graph tests | L-03 validates actual technician/vendor behavior. |
| WFR-07 | Graceful close first; guarded force close only after active recovery finished | F-14/F-15 and I-15 | L-04 validates real close prompt/process/helper behavior. |
| WFR-08 | R-Studio launch allowed; destructive/automatic analysis forbidden | R-01 through R-07 | R-11 validates actual `-safe` startup and manual boundary. |
| WFR-09 | Unsupported vendor operation is a visible manual gate | F-03/F-04/F-10 through F-13, R-05/R-07, S-10 | L-03/L-04/L-11 may promote a specific exact-build map; otherwise gate remains. |
| WFR-10 | Resume never reruns completed stage without operator choice | C-18 through C-22 plus I-09/I-10 | L-07 validates real interrupted media/application behavior; no live result may weaken this rule. |

## 9. Safety invariant mapping

The following rows map the invariants from `research/safety-resumability.md` to
deterministic tests and identify the additional owner gate where synthetic tests
cannot prove real hardware or vendor behavior.

| Invariant | Required assertion | Deterministic test(s) | Owner-only gate |
| --- | --- | --- | --- |
| I-01 | Source identity is mandatory | C-03, C-09, P-02, F-02 | L-01 real source snapshot. |
| I-02 | Source/destination physical sets are disjoint | C-04 through C-08, C-23 | L-02 real source/destination disks. |
| I-03 | Source is never a destination | C-23, S-03/S-04 | L-02 write-blocker and path monitoring. |
| I-04 | Case creation is non-overwriting | C-14, C-19 | None beyond real filesystem release check. |
| I-05 | Durable case exists before scanner work | C-15, C-21, C-22 | L-03 real launch record. |
| I-06 | Scan and recovery are separate | F-06/F-07/F-10 and state tests | L-03 exact vendor completion observations. |
| I-07 | Stage ordering is enforced | F-09 and transition tests | L-03 real Quick/Long procedure. |
| I-08 | Only verified stages advance | F-07, C-16/C-18 | L-03 status/output evidence. |
| I-09 | Interrupted attempts do not auto-resume | C-18, C-20, resume tests | L-07 crash/media interruption. |
| I-10 | Verified stages do not rerun silently | resume and new-attempt tests | L-07 real resume choice. |
| I-11 | Destination loss never redirects | C-07/C-10/C-23, F-13 | L-07 removal during real recovery. |
| I-12 | Returned media is the same media | C-03/C-09 | L-02/L-07 reattach different disk at same letter. |
| I-13 | Low space is fail-safe | C-10, F-13 | L-07 real low-space/write error. |
| I-14 | Output conflicts do not overwrite | C-14, C-23, F-12 | L-04 real vendor duplicate-name prompt. |
| I-15 | Force close is guarded | F-14/F-15 and state tests | L-04 active/finished GUI close. |
| I-16 | Handoff follows close | R-01, C-18, state tests | R-11 real main-panel handoff. |
| I-17 | Unsupported controls are visible | F-03/F-04, R-05/R-07 | L-03/L-11 exact-build evidence only. |
| I-18 | Log failure blocks work | C-15/C-17/C-22 | L-03 durable media/log check. |
| I-19 | Concurrent execution is prevented | C-20 | L-07 two-technician case if available. |
| I-20 | State is tamper-evident enough to stop | C-18/C-19, resume tests | None; live must not bypass the check. |
| I-21 | Paths cannot escape reviewed root | C-07/C-11/C-12/C-13 | L-02 actual junction/mount behavior. |
| I-22 | Source protection is live-validated | Static source boundary and C-23 prove call/path selection only | L-01 hardware write blocker and vendor observation. |

## 10. Owner-live validation records

Owner-live tests must be real, disposable, and build-specific. Each record must
include the exact executable path, product/version/build, license/demo mode,
Windows/PowerShell version, source/destination identity snapshots, operator
decisions, timestamps, logs, screenshots or UIA property evidence, and output
verification. Do not commit credentials, license keys, or recovered content.

### L-01 File Scavenger identity and source safety

- Verify the executable and About version on the intended installed/portable
  build; record administrator and license/demo behavior.
- Use a write-blocked disposable source where available and a separate physical
  destination. Record source state before/after; a software flag alone is not
  proof.
- Prove the workflow never supplies the same-drive `Yes` override.

### L-02 File Scavenger UI and storage topology

- Observe actual UIA/MSAA properties, names, handles, localization, readiness,
  and action results for `Look in`, `Look for`, `Quick or Long scan`, `Scan`,
  `Pause`, `Step 2: Save`, `Save to`, `Use folder names`, `Save`, and `Exit`.
- Validate folder picker display/return path, mounted folders, reparse paths,
  source/destination physical identity, and removable-disk behavior.

### L-03 File Scavenger stage evidence

- Run Quick scan, short recovery, and Long scan/recovery only with explicit
  technician choices. Record distinct scan/recovery finish evidence and output
  verification.
- Observe status panel values, `Recovery.log` exact name/location/format,
  `Good`/`Poor` and `Saved`/`Failed`/`Skipped` values, CSV columns, `.fss`
  session save/load, and scan journal placement. Unknowns remain gates.

### L-04 File Scavenger close and prompts

- Validate pause/resume/reboot, File > Exit, close confirmation, helper process,
  force-close refusal during active/unknown work, overwrite modes, journal
  overwrite prompts, and force close after verified recovery only.

### L-07 Media and resume faults

- Remove/restore destination during work, reattach a different disk at the same
  drive letter, induce low space, disconnect source, interrupt the process, and
  run the concurrent-lock case where safe. Verify pause/stop, preserved output,
  no redirect, identity recheck, and explicit retry/abort choices.

### L-11 R-Studio launch-only handoff

- Verify R-Studio for Windows rather than Agent/Emergency, record installed path
  and build, launch with exact `-safe` and optional safe `-log` behavior, and
  confirm the main panel appears without automatic source selection, partition
  search, scan, marking, recovery, destination selection, or analysis.
- Validate separate Explorer client-folder action and confirm no write-capable
  setting, editor, wipe, repair, or partition action is enabled.

## 11. Acceptance and skip policy

A CI run is green only when all applicable deterministic tests pass and the static
contracts pass. A live test is not applicable to CI and must appear as excluded
or skipped with its reason. A skipped live test means the owner gate remains open;
it is not evidence that vendor behavior works.

The implementation cannot claim a completed recovery from a passing launch test,
passing process-exit test, synthetic UI tree, existing output directory, or
simulated vendor executable. The final acceptance record must distinguish:

- deterministic safety and state behavior proven by tests;
- Windows 5.1 and launcher behavior proven by pinned runners; and
- vendor, hardware, GUI, timing, and source-write behavior proven only by the
  owner-live record.

## Sources

[3] https://www.quetek.com/faq.htm
[4] https://www.quetek.com/fs71man/FS_toc.htm
[5] https://www.quetek.com/fs71man/afxc36xx.htm
[6] https://www.quetek.com/fs71man/afxc9y91.htm
[7] https://www.quetek.com/fs71man/afxc0ynh.htm
[8] https://www.quetek.com/fs71man/afxc6s2v.htm
[9] https://www.quetek.com/fs71man/afxc0zmt.htm
[10] https://www.quetek.com/fs71man/afxc078l.htm
[12] https://www.quetek.com/fs71man/afxc92b7.htm
[15] https://www.quetek.com/fs71man/afxc3ol4.htm
[16] https://www.r-studio.com/Data_Recovery_Download.shtml
[17] https://www.r-studio.com/Unformat_Help/r-studioswitches.html
[18] https://www.r-studio.com/Unformat_Help/basicfilerecovery.html
[19] https://www.r-studio.com/Unformat_Help/discscan.html
[21] https://www.r-studio.com/Unformat_Help/r-studio_settings.html
[22] https://www.r-studio.com/Unformat_Help/r-studio_main_panel.html
[24] https://www.r-studio.com/Unformat_Help/systemrequirements.html
[25] https://learn.microsoft.com/en-us/powershell/module/storage/get-disk?view=windowsserver2025-ps
[26] https://learn.microsoft.com/en-us/powershell/module/storage/get-partition?view=windowsserver2025-ps
[27] https://learn.microsoft.com/en-us/powershell/module/storage/get-volume?view=windowsserver2025-ps
[29] https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-disk
[30] https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
[31] https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
[32] https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.folderbrowserdialog
[33] https://learn.microsoft.com/en-us/dotnet/api/system.io.filemode
[34] https://learn.microsoft.com/en-us/dotnet/api/system.io.directory.createdirectory
[35] https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
[37] https://learn.microsoft.com/en-us/dotnet/api/system.io.path.getinvalidfilenamechars
[38] https://learn.microsoft.com/en-us/windows/win32/shell/folder
[39] https://learn.microsoft.com/en-us/windows/win32/shell/shell-browseforfolder
