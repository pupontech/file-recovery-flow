# Recovery Workflow Implementation Specification

Status: implementation contract for v1
Scope: Windows PowerShell 5.1 technician workflow
Evidence cutoff: 2026-09-16 research artifacts in this repository

This specification reconciles the repository contract with the completed research
artifacts. It owns the implementation decisions below. A worker must not replace a
manual gate with a guessed vendor switch, control name, completion rule, or path.

## 1. Binding decisions

### 1.1 Safety boundary

The selected source is read-only. The workflow must never format, initialize,
repair, run CHKDSK, change partitions or partition tables, delete files, or
overwrite an existing job. It must refuse a destination on any physical disk
that backs the source, including a different volume or mount point on that disk.
These are hard safety contracts from AGENTS.md, README.md, and
`docs/WORKFLOW.md`; no configuration option may weaken them.

All uncertainty is fail-closed:

- Missing or contradictory source identity blocks the next external action.
- An unknown or incomplete destination mapping blocks output work.
- Low space, destination loss, source loss, log failure, state failure, and
  unexpected application state pause or stop; none changes the destination
  automatically.
- A blank, malformed, cancelled, or timed-out operator answer selects the safe
  stop/pause path.
- A process launch, process exit, window title, displayed 100 percent, or file
  growth is an observation, not proof of scan or recovery completion.

### 1.2 Automation decision

No supported unattended File Scavenger contract was verified. The official
research reviewed the 7.1 help tree and vendor pages and found no documented
CLI, batch, project/config, silent/unattended, API/SDK, exit-code, or status-query
surface.[4][12] The two independent File Scavenger artifacts agree that the
safe v1 boundary is local case preparation, verified executable discovery,
process launch/liveness observation, filesystem observation, and explicit manual
gates. The `Macros - Experimental.` menu and binary macro strings are not a
supported interface and must remain manual pending exact-build vendor evidence.

The v1 decision is therefore:

| Capability | v1 disposition | Required behavior |
| --- | --- | --- |
| Configuration, preflight, source/destination identity, path checks, case creation, logging, state, and resume validation | Automated | Use pure functions and injected OS seams. Refuse unsafe or incomplete input. |
| File Scavenger executable discovery, identity capture, and elevation check | Automated verification | Require an explicit or independently verified candidate. Record path, product, file version, and evidence source. Do not treat a download page as proof of an installed build. |
| File Scavenger process launch | Launch-only boundary | Start only the verified executable, with no invented scanner arguments. Record the process identity and present the operator gate. |
| File Scavenger source selection, mode selection, criteria, scan start, result selection, destination selection, and Save | Manual by default | The documented GUI labels may be shown in a gate, but the workflow must not click or invoke them until a technician has validated the exact installed build and a stable UI Automation surface. |
| File Scavenger status and output observation | Evidence collection only | Combine live-validated status observation, process identity, output evidence, and operator review. Never infer completion from one signal. |
| File Scavenger close | Manual/evidence-gated | File > Exit is the documented graceful surface, but UI reachability and acknowledgement are not verified. Force close is allowed only under the guard in section 5. |
| R-Studio for Windows launch | Supported launch-only handoff | Launch an identity-verified executable with `-safe`; add `-log <filename>` only for a safe, writable case log. These are the only normal R-Studio arguments. [17] |
| R-Studio client-folder display | Separate optional Explorer action | Open the already validated client folder as a shell action. Do not pass the folder as an undocumented R-Studio argument. |
| R-Studio source selection, partition search, scan, file marking, recovery, destination choice, analysis, repair, editor, wipe, or write features | Manual | Stop at the main panel and require the technician to perform and confirm all analysis/recovery actions. `-safe` is not a general write-protection guarantee. [17][18][21][22] |

UI Automation is an implementation seam, not a vendor-supported contract. It may
be enabled for a target build only after the owner-live gate records the actual
UIA/MSAA properties, localization behavior, action/result evidence, and failure
behavior. Until then, the adapter returns a named manual gate instead of trying
English captions, screen coordinates, `SendKeys`, undocumented window classes,
or guessed selectors.

### 1.3 Version and evidence scope

The File Scavenger research inspected the direct vendor 64-bit download labelled
7.1 beta (stable), with embedded version resource 7.1.1.13 and SHA-256
`b63592d5677605681f03969c62c821b854445ab1bf00ccc2b5733d1b3d6708ff`.[1][41]
This is an artifact observation, not proof of the version installed on a
technician machine. The exact About version/build must be captured on every live
case; the About surface is documented by QueTek.[15]

The R-Studio download page observed R-Studio for Windows 9.5 build 191810.[16]
This is a download-page observation, not a universal installed-build contract.
The workflow must record the installed executable identity and runtime version
and compare it with an explicit validated-build policy. It must not assume that
an older, newer, portable, Agent, or Emergency executable has the same surface.

The two product names are intentionally disambiguated:

- File Scavenger means QueTek File Scavenger, not a similarly named utility.
- R-Studio means R-Tools R-Studio for Windows, not Posit RStudio, R-Studio
  Agent, or R-Studio Emergency. The vendor download page lists those separate
  utilities.[16]

### 1.4 Terminology mapping

Use the vendor words in operator-facing text and logs:

| Internal concept | Required vendor wording |
| --- | --- |
| Short/fast scan state | `Quick scan` |
| Long/exhaustive scan state | `Long scan` |
| Scan source | `Look in` |
| Search criteria | `Look for` |
| Scan mode selector | `Quick or Long scan` |
| Start scan | `Scan` |
| Suspend/resume | `Pause` |
| Recovery stage | `Step 2: Save` |
| Recovery destination | `Save to` |
| Start recovery | `Save` |
| Preserve folders | `Use folder names` |
| Post-scan status | `Good` or `Poor` |
| Post-recovery status | `Saved`, `Failed`, or `Skipped` |
| Session file | `File Scavenger Session (*.fss)` |
| Long-scan optimization | `Scan journal` / `Scan log` folder |
| Exit | `File > Exit` |

The state machine uses `SHORT_*` as the internal alias for the vendor's `Quick
scan`; it must never relabel the vendor operation as a different scan type. The
vendor documents Quick and Long as distinct modes and explicitly separates the
scan step from `Step 2: Save`.[5][6][7]

## 2. Runtime architecture and module contracts

`RecoveryAutomation.ps1` is the only orchestrator. It imports small modules,
passes dependencies through parameters, and owns the ordered workflow. Modules
must not start external work during import. One writer owns each file.

```text
Start-Recovery.bat
  -> RecoveryAutomation.ps1 (Windows PowerShell 5.1)
       -> Configuration.psm1
       -> ApplicationDiscovery.psm1
       -> DiskDetection.psm1
       -> RecoveryLogging.psm1
       -> JobState.psm1
       -> FileScavenger.psm1
            -> UIAutomation.psm1
       -> RStudio.psm1
       -> TechnicianUi.psm1
```

Every OS or application operation is behind one injectable seam. Unit tests pass
fixtures or recording doubles and cannot touch a real disk, launch a vendor
program, or send input to a desktop. Production defaults may be used only by the
Windows integration or owner-live lanes.

### 2.1 Configuration.psm1

Public contract:

- `Read-RecoveryConfiguration -Path <literal path>` reads one JSON configuration
  file and returns a typed, validated object or a structured error. It has no
  write or launch side effects.
- `Resolve-RecoveryConfiguration -Configuration <object> -Overrides <object>`
  applies only named, typed overrides from the allowlist and returns the resolved
  object. Unknown keys, null required values, malformed paths, and conflicting
  safety settings are errors.
- `Test-RecoveryConfiguration -Configuration <object>` returns
  `Valid`, `Errors`, and `Warnings`; it never turns a warning into permission to
  continue.

The v1 schema is deliberately small:

| Field | Required | Rule |
| --- | --- | --- |
| `SchemaVersion` | Yes | Must be `1`. Unknown schema versions stop. |
| `WorkflowVersion` | Yes | Recorded in state and log. |
| `FileScavengerPath` | No | Explicit path override; if absent, discovery must produce exactly one verified candidate or a gate. |
| `RStudioPath` | No | Explicit path override; never interpreted as an Agent or Emergency utility. |
| `ValidatedFileScavengerBuilds` | Yes | Empty means scanner UI automation is manual-only. A build is not accepted from a download URL alone. |
| `ValidatedRStudioBuilds` | Yes | Empty means launch may be offered only as a manual identity gate; no automatic analysis. |
| `DestinationRoot` | No | Must be operator-selected or explicitly supplied, then resolved and separated again. |
| `CapacityReserveBytes` | Yes | A non-negative policy value; unknown or unavailable capacity blocks output work. |
| `MaxJobPathLength` | Yes | Defaults to the documented design budget of 200 characters; lower values are allowed. |
| `ClientName` | No | Never used unsanitized in a path or command. |
| `NoPause` | No | Only controls the launcher prompt, never a safety gate. |
| `AllowSameDiskOverride` | No | Must always be false; a true value is a configuration error. |
| `AllowVendorOverwrite` | No | Must always be false; a true value is a configuration error. |
| `AllowForceClose` | No | Defaults to false and cannot bypass the state/confirmation guard. |

Safe defaults are fail-closed: no source, destination, vendor path, validated
build, or vendor automation map is assumed; same-disk override and overwrite are
never enabled; a missing capacity policy is unknown; and no manual gate defaults
to Continue. Secrets, license keys, credentials, and unnecessary recovered
content names are not accepted in configuration.

### 2.2 ApplicationDiscovery.psm1

Public contract:

- `Find-RecoveryApplication -Product <FileScavenger|RStudio> -ExplicitPath
  <optional path> -CandidateProvider <scriptblock>` returns all candidates with
  `Path`, `Product`, `FileVersion`, `ProductVersion`, `EvidenceSource`, and
  `IdentityStatus`.
- `Resolve-RecoveryApplication -Product <...> -ExplicitPath <optional path>
  -DiscoveryProvider <scriptblock> -ValidatedBuilds <list>` returns exactly one
  verified candidate or a named manual/stop result. Ambiguous candidates never
  fall through to the first result.
- `Get-RecoveryApplicationIdentity -Path <literal path> -FileInfoProvider
  <scriptblock>` reads file/version metadata without launching it.
- `Test-RecoveryElevated -ElevationProvider <scriptblock>` returns a boolean plus
  evidence. The orchestrator treats false or unknown as a preflight gate.

Explicit config paths take precedence but still require identity verification.
Registry uninstall/App Paths evidence and bounded common install-location probes
may produce candidates; they are not proof and are never used to skip product or
version validation. A portable copy requires an explicit path or an owner gate.
The module must reject R-Studio Agent/Emergency candidates and must not silently
try another product or executable after a launch failure. File Scavenger's
administrator requirement is documented by QueTek, and R-Studio's Windows system
requirements also call for administrative privileges.[3][2][24]

`Start-Process -Wait` is not a completion mechanism. The module returns process
path, PID, start time, and process handle information for later identity checks;
completion remains the responsibility of the adapter/state machine.

### 2.3 DiskDetection.psm1

Public contract:

- `Get-RecoveryVolumeInventory -Provider <scriptblock>` returns one object per
  resolvable volume. Each object contains `DriveLetter`, `AccessPaths`,
  `CanonicalPath`, `VolumeGuid` when available, `FileSystemLabel`, `FileSystem`,
  `SizeBytes`, `SizeRemainingBytes`, `PartitionNumber`, `DiskNumber`, a
  `PhysicalDisks` array, `EvidenceSource`, and `IsIndeterminate`.
- `Get-PhysicalDiskIdentity -DiskNumber <number> -Provider <scriptblock>`
  returns `DiskNumber`, `IdentityKey` when a strong key exists, `UniqueId`,
  `UniqueIdFormat`, `SerialNumber`, `Model`, `FriendlyName`, `Manufacturer`,
  `SizeBytes`, `BusType`, `Location`, `PNPDeviceID`, `EvidenceSource`, and
  `IsIndeterminate`.
- `Resolve-RecoveryPathIdentity -Path <literal path> -Provider <scriptblock>`
  resolves the final path, nearest existing ancestor, volume, partition, and
  complete backing physical-disk set. A path that cannot be resolved is not a
  usable identity.
- `Test-DestinationSafety -SourceIdentity <object> -DestinationPath <literal
  path> -Provider <scriptblock>` returns `Allowed`, `Decision`, `ReasonCode`,
  `SourceEvidence`, and `DestinationEvidence`. `ReasonCode` is null only for an
  allowed decision; a blocked result uses one of the exact codes
  `SamePhysicalDisk`, `SameVolume`, `SourceIndeterminate`,
  `DestinationIndeterminate`, `DestinationUnresolved`, or
  `DestinationPathInvalid`.
- Blocking reasons use a deterministic precedence: invalid path, unresolved
  destination path, source indeterminate, destination indeterminate, same
  volume, then same physical disk. The implementation may expose richer
  evidence, but it must return the first applicable reason and never downgrade
  an unknown identity to an allowed result.
- `Get-RecoveryDestinationSpace -Path <literal path> -Provider <scriptblock>`
  returns available bytes, reserve, provider evidence, and `IsUnknown`. Use the
  conservative value when both Storage and .NET values exist; an exception or
  unavailable value is unknown, not zero and not permission to continue.
- `Select-DestinationFolder -PickerProvider <scriptblock> -TypedPathProvider
  <scriptblock>` uses the documented folder picker first and returns the selected
  path plus selection method, or a stop result.
- `Convert-RecoveryName -Name <string>` returns a deterministic ASCII component.
  The result alphabet is `[A-Za-z0-9._-]`, reserved device names and trailing
  spaces/periods are rejected or removed, empty results are errors, and the
  client-name component is capped at 40 characters. The exported
  `Sanitize-RecoveryName` alias remains for callers of the earlier public
  contract; it maps to this approved-verb function without an import warning.
- `New-RecoveryJobFolder -RootPath <literal path> -ClientName <string>
  -Clock <provider> -ClaimProvider <provider> [-PreclaimSafetyCheck <scriptblock>]`
  creates and claims a new case folder without overwriting. The claim uses a
  `CreateNew`-style operation and a bounded suffix sequence (`-001` through
  `-099`); exhaustion stops and asks for another root.
- `-PreclaimSafetyCheck` is the pre-write destination proof. It is invoked once
  per collision-free candidate, twice per candidate folder: stage
  `BeforeDirectoryCreate` immediately before the directory is created, and stage
  `BeforeClaimWrite` immediately before the job-claim marker is written. The
  callback receives `Path`, `PathExists`, `ProofPath`, `ProofPathExists`,
  `RootPath`, and `Stage`. `ProofPath` is the nearest existing ancestor of the
  candidate: the candidate folder does not exist when the first stage runs, so it
  cannot be resolved by the provider and the proof has to be taken on a path that
  can be. The callback must return exactly one result carrying an explicit
  Boolean `Allowed = $true`; absent, non-Boolean, multiple, throwing, or
  unreadable results are refused as `PreclaimSafetyUnproven`, and no directory or
  claim byte is written. The production entry point always supplies this
  callback; a standalone caller that omits it performs no separation proof, and
  the helper must not be used to create a case without a proof.
- A refused candidate is never adopted, merged with, or deleted. A stage-two
  refusal leaves the already-created, still empty candidate directory in place
  (nothing inside another folder is ever read, moved, or removed) and reports the
  refusal reason; the case itself is not created and the claim marker does not
  exist.

The primary provider order is Storage module, Storage namespace CIM, then the
Win32 association fallback. If none can prove the mapping, the result is
indeterminate and the workflow stops. `Get-Volume -FilePath` is the path-to-volume
join; `Get-Partition` supplies `DiskNumber`; disk identity is read from the
corresponding disk object.[25][26][27][29][30] Dynamic disks, Storage Spaces,
File-Backed Virtual, network shares, VHDs, or any topology with incomplete
physical membership are not treated as separate merely because a drive letter
exists.

A member list is complete only when it is proven exhaustive. A volume record that
states `MembersIncomplete = $false` is still refused as incomplete when it also
states a `DeclaredMemberCount` larger than the number of members that were
resolved: a partition-scoped answer that returned fewer disks than the topology
states is a subset, and a subset never proves the absence of a member. An absent
`DeclaredMemberCount` is not a statement at all, so a record that does not carry
one keeps the previous behaviour; a value that cannot be read as a non-negative
count is refused as incomplete rather than treated as an agreement.

A disk number is a session label and must never be the sole persisted identity.
Use a strong `UniqueId`/`UniqueIdFormat` match, or an exact
`SerialNumber + SizeBytes + Model` combination. Missing or contradictory strong
fields produce an indeterminate result and a refusal; matching disk numbers
alone do not prove overlap.[25][29]

The destination path is re-resolved after folder creation and immediately before
each vendor write stage. The same source/destination physical-disk comparison is
used for metadata, log, journal, session, and recovered output paths. No path is
redirected when a check fails.

### 2.4 RecoveryLogging.psm1

Public contract:

- `New-RecoveryLog -Path <literal path> -JobId <string> -Writer <provider>`
  creates a new log only in the claimed job folder and returns a writer handle.
  An existing unclaimed log is a collision, not a file to reuse.
- `Write-RecoveryLogEntry -Writer <object> -Entry <object>` appends one complete
  event with a monotonic sequence, UTC timestamp, job ID, state, stage,
  attempt ID, event type, result, source/destination identity references, gate
  decision, and structured error details where applicable.
- `Sync-RecoveryLog -Writer <object>` flushes the durable event and returns a
  failure rather than silently continuing. The exported `Flush-RecoveryLog`
  alias remains for compatibility.
- `Test-RecoveryLog -Path <literal path>` detects malformed JSONL, missing or
  duplicate sequences, wrong job ID, and truncation.

The event log is append-only and is flushed before an event-authorized external
action and after every boundary event. Log initialization, append, serialization,
or flush failure blocks the next vendor action. The log must not contain
credentials or unnecessary recovered-content data.

Do not use `>`, `>>`, or `Out-File` for machine state. Runtime encodings are
explicit: the v1 log writer emits ASCII-safe JSONL with `ASCII` encoding, using
escaped dynamic values or failing closed if lossless serialization is not
possible; the state writer uses explicit UTF-8 without a BOM so real paths can be
preserved. Committed source, test, documentation, fixture, and launcher text
remains ASCII and BOM-free; `.bat` files use CRLF.

### 2.5 JobState.psm1

Public contract:

- `New-RecoveryJobState -JobId -SourceIdentity -DestinationIdentity
  -ApplicationEvidence -Paths -WorkflowVersion` returns a schema version 1
  state object in `NEW` or `PREFLIGHT_PENDING`.
- `Read-RecoveryJobState -Path <literal path> -Lock <object> [-Clock <provider>]
  [-ExpectedOwner <string>]` parses and validates schema, job ID, required
  properties, event sequence, identity evidence, and state/event consistency.
  Invalid state returns a stop result. The durable lock is a capability, not
  descriptive metadata: the read refuses when the lock lease has expired
  (`LockLeaseExpired`), when the presented owner does not match the owner recorded
  in the lock file (`LockOwnerMismatch`), when an expected owner was supplied that
  is not the durable owner (`LockOwnerMismatch`), and when the lock does not state
  the job id it was acquired for (`LockNotBound`). An unexpired lease owned by the
  caller still reads successfully, so a live worker is not blocked by the new
  checks. Callers that omit `-Clock` are evaluated against UTC now.
- `Write-RecoveryJobState -Path <literal path> -State <object> -Writer
  <provider>` writes a validated snapshot atomically inside the owned case folder.
- `Test-RecoveryStateTransition -From <state> -To <state> -Context <object>`
  returns an allow/deny decision with the required evidence and operator decision
  checks.
- `Set-RecoveryState -State <object> -To <state> -EventWriter <provider>`
  writes the boundary event and snapshot only when the transition is legal.
- `Lock-RecoveryJob -JobPath <literal path> -LockProvider <provider>`
  obtains an exclusive lock before reading resume state. A stale lock is a gate,
  not an invitation to delete it. The exported `Acquire-RecoveryJobLock` alias
  remains for compatibility.
- `Get-RecoveryResumeDecision -State -FreshSourceIdentity -FreshDestinationIdentity
  -FreshSpace` returns `ResumeNext`, `NeedsReview`, or `FailedClosed` and never
  starts a vendor attempt.

The state snapshot records schema/workflow versions, job ID, timestamps, source
and destination identity snapshots, path evidence, capacity policy, application
path/version/evidence, current state/stage/attempt, lock owner/lease, unresolved
fields, and gate decisions. It does not replace the append-only event history.

### 2.6 FileScavenger.psm1

Public contract:

- `Start-FileScavenger -Executable <verified identity> -ProcessRunner <provider>`
  launches the verified executable without scanner arguments and returns process
  identity plus a launch result. It must run only after `CASE_READY` and a fresh
  source/destination check.
- `Get-FileScavengerObservation -AppStateProvider <provider> -OutputProvider
  <provider>` returns process/window evidence, status-panel values when live
  validated, observed artifacts, and confidence. It never marks a state complete
  from process exit, window disappearance, output-folder existence, or 100 percent
  alone.
- `Request-FileScavengerStage -Stage <SHORT_SCAN|SHORT_RECOVERY|LONG_SCAN|LONG_RECOVERY>
  -EvidenceMap <optional exact-build map>` returns a manual gate unless the map
  is present, build-matched, owner-validated, and the action/result contract is
  complete. A validated action still requires state and output evidence.
- `Test-FileScavengerCompletion -Stage <...> -Observation <object>` distinguishes
  `ScanFinished`, `RecoveryFinished`, and `OutputObserved`; no generic Finished
  result is accepted.
- `Request-FileScavengerGracefulClose -Observation -EvidenceMap` attempts the
  documented File > Exit surface only when active work is known to be finished or
  a validated pause/stop path exists. Otherwise it returns a gate.
- `Request-FileScavengerForceClose -State -ProcessIdentity -Confirmation` is
  denied during any scan/recovery/unknown state and requires all force-close
  guards in section 5.

The documented File Scavenger surface includes `Quick scan`, `Long scan`, `Scan`,
`Pause`, `Step 2: Save`, `Save to`, `Save`, session Load/Save, CSV listing, scan
journal, and File > Exit.[5][6][7][9][10][12] The research does not establish
stable UIA properties for those captions. The adapter must use an exact-build
owner map or expose a manual gate; it must not invent control IDs or macro files.

Vendor artifacts are observations, not completion contracts: `Recovery.log` is
documented in the `Save to` folder but its exact runtime naming/format must be
confirmed live; `.fss` is a GUI-saved session; CSV is a displayed-file listing;
and journal folders are drive-specific.[8][9][10] Per-file `Good`/`Poor` and
`Saved`/`Failed`/`Skipped` values must not be assumed to be CSV columns until live
observed. The adapter must never type the same-drive override `Yes`, select
vendor `Overwrite`, persist "do not ask again", accept a journal overwrite
prompt, or silently redirect output.[11][13][14]

### 2.7 UIAutomation.psm1

Public contract:

- `Get-RecoveryAppState -ProcessIdentity -UiProvider <provider>` returns a
  normalized state tree with process identity, window presence, readiness,
  localized control names/properties, status labels/values, and messages.
- `Invoke-RecoveryUiAction -Action -ControlDescriptor -UiProvider <provider>`
  is allowed only for a descriptor loaded from the exact-build live evidence map.
  It rejects coordinates, raw keystroke sequences, arbitrary expressions, and
  unmatched or ambiguous controls.
- `New-RecoveryManualGate -GateId -Reason -Evidence -Choices -SafeDefault`
  returns a displayable gate object. The UI layer records the operator decision;
  it does not decide to continue on timeout.

The documented English captions are evidence for operator terminology, not
stable UIA `Name` values. The candidate caption list for the File Scavenger live
map is `Look for`, `Look in`, `Quick or Long scan`, `Scan`, `Pause`, `Step 2:
Save`, `Save to`, `Use folder names`, `Save`, `Session`, `Load`, `Create a CSV
file`, and `Exit`, plus status labels `Progress`, `Scan status`, and `Recovery
status`.[7][8][12] The list must not be treated as a promise that the native MFC
application exposes those names through UIA/MSAA. A non-English host requires a
validated localized map or a manual gate.

### 2.8 RStudio.psm1

Public contract:

- `Start-RStudioHandoff -Executable <verified identity> -LogPath <optional safe
  path> -ProcessRunner <provider>` constructs exactly `-safe`, optionally
  followed by `-log` and the validated log path, then launches the verified
  R-Studio for Windows executable. It returns the exact argument list, process
  identity, and a main-panel manual gate.
- `Test-RStudioHandoffPreconditions -State -Executable -LogPath` verifies
  `READY_FOR_HANDOFF`, final source/destination identity, safe log location, and
  executable identity. It refuses a missing or unsafe log path.
- `Open-RecoveryClientFolder -Path <validated path> -ExplorerProvider <provider>`
  is a separate optional shell action after path validation. It is not an
  R-Studio startup argument and does not select a source or start recovery.
- `Get-RStudioObservation -ProcessIdentity -UiProvider <provider>` reports
  process/window/main-panel evidence only; it does not invoke analysis.

The vendor switch page documents `-safe` and `-log <filename>` and does not
provide a startup project, folder, scan, recovery, source-selection, or
window-activation argument.[17] The main panel appears at startup, while the
vendor's scan and recovery sequences require further operator actions.[18][19][22]
The R-Studio settings page documents write-capable features that must stay
outside this workflow.[21]

### 2.9 TechnicianUi.psm1

Public contract:

- `Select-DestinationFolder` delegates to DiskDetection's resolver and displays
  the resolved path and physical-disk evidence before case creation.
- `Show-RecoveryManualGate -Gate <object> -InteractionProvider <provider>`
  displays reason, evidence, exact scope, choices, safe default, and records a
  non-blank decision.
- `Show-RecoveryHandoffPanel -ClientName -ClientFolder -Actions` displays the
  client name prominently in an always-on-top Windows UI and exposes explicit
  Close, Copy client name, and Open client folder actions. It must not start a
  scan or recovery.

The primary folder picker is `System.Windows.Forms.FolderBrowserDialog` because
its documented `SelectedPath` member returns a filesystem path. It is configured
without a new-folder affordance; the workflow creates the uniquely claimed job
folder after the physical-disk check.[32] If no picker is available, the typed
path fallback uses the same resolver and safety checks. `Shell.Application`'s
`BrowseForFolder` is not used for the safety decision because the documented
returned `Folder` object has no documented filesystem path property.[38][39]
`IFileOpenDialog` with `FOS_PICKFOLDERS` is an upgrade path, not a v1 dependency.
The launcher must not force `-Mta`; the documented PowerShell default supports
STA behavior for this dialog path.[40]

## 3. Orchestrator order

`RecoveryAutomation.ps1` must execute the following order. A failure or gate at
any step leaves the current state and log durable and prevents later work.

1. Validate Windows PowerShell 5.1 runtime, strict/error policy, configuration,
   and launcher arguments. Log the runtime and policy evidence.
2. Run elevation preflight. Discover and identity-check File Scavenger and
   R-Studio without launching them. Record missing, ambiguous, or unexpected
   products as a gate.
3. Obtain the source through the technician's explicit selection. Resolve its
   canonical path, volume, partition, complete physical-disk set, read-only or
   write-blocker evidence, and identity snapshot.
4. Obtain the destination with the documented folder picker or validated typed
   path. Resolve reparse points/ancestors, volume, partition, complete physical
   disk set, capacity, and destination identity. Refuse any overlap or unknown
   mapping.
5. Sanitize the client name, enforce the path budget, claim a unique job folder,
   acquire the lock, create metadata, and initialize/flush the append-only log.
   No vendor process may launch before `CASE_READY` is durable.
6. Revalidate source, destination, capacity, application identity, and lock.
   Launch File Scavenger with no invented arguments. Present the launch/manual
   gate.
7. The technician performs the File Scavenger `Quick scan` path. Record a
   `SHORT_SCAN_RUNNING` attempt before Scan, then distinct scan-finished evidence.
   Do not proceed merely because the process exits or a progress value reaches
   100 percent.
8. The technician performs `Step 2: Save` for the short result. Revalidate the
   destination immediately before output. Record recovery-finished evidence,
   output observation, and an independent `SHORT_RECOVERY_VERIFIED` decision.
9. Only after short recovery is verified may the technician choose the `Long
   scan` path. Repeat fresh identity/capacity checks and distinct long scan,
   recovery, and output-verification states. Never silently change Quick to Long.
10. After all desired File Scavenger work is verified, attempt graceful File >
    Exit through an exact-build validated surface or present the manual gate.
    Verify process/helper identity and termination; do not force-close active or
    unknown work.
11. Revalidate source and destination identity and the final case state. Set
    `READY_FOR_HANDOFF` only when the close and output evidence are complete.
12. Launch the verified R-Studio executable with `-safe` and optional safe `-log`
    only. Stop at the main panel and set `HANDOFF_MANUAL`. Optionally offer the
    separate Explorer client-folder action. Do not automate R-Studio analysis,
    scan, source selection, file marking, recovery, destination selection, or
    write-capable controls.

## 4. State machine and event contract

### 4.1 Canonical states

Use these exact state values. `SHORT` is the internal alias for vendor `Quick`.

```text
NEW
PREFLIGHT_PENDING
PREFLIGHT_PASSED
CASE_READY
SHORT_SCAN_RUNNING
SHORT_SCAN_FINISHED
SHORT_RECOVERY_RUNNING
SHORT_RECOVERY_FINISHED
SHORT_RECOVERY_VERIFIED
LONG_SCAN_RUNNING
LONG_SCAN_FINISHED
LONG_RECOVERY_RUNNING
LONG_RECOVERY_FINISHED
LONG_RECOVERY_VERIFIED
PAUSED
INTERRUPTED_UNKNOWN
FAILED_CLOSED
READY_FOR_HANDOFF
HANDOFF_MANUAL
ABORTED
```

`*_FINISHED` means the named vendor operation reported an end. `*_VERIFIED`
means separate output/state evidence was reviewed and accepted. There is no
single generic `Complete` state.

### 4.2 Forward transitions

| Current | Allowed next state | Required condition |
| --- | --- | --- |
| `NEW` | `PREFLIGHT_PENDING` | Inputs are being evaluated. |
| `PREFLIGHT_PENDING` | `PREFLIGHT_PASSED`, `PAUSED`, `FAILED_CLOSED` | All required preflight evidence or an explicit gate result. |
| `PREFLIGHT_PASSED` | `CASE_READY`, `FAILED_CLOSED` | Source/destination checks, lock, metadata, and flushed log succeed. |
| `CASE_READY` | `SHORT_SCAN_RUNNING`, `PAUSED`, `FAILED_CLOSED` | Fresh checks pass and launch/manual gate is recorded. |
| `SHORT_SCAN_RUNNING` | `SHORT_SCAN_FINISHED`, `PAUSED`, `INTERRUPTED_UNKNOWN`, `FAILED_CLOSED` | Exact scan completion evidence, known pause/failure, or interruption. |
| `SHORT_SCAN_FINISHED` | `SHORT_RECOVERY_RUNNING`, `PAUSED`, `FAILED_CLOSED` | Technician chooses Step 2 and a fresh destination check passes. |
| `SHORT_RECOVERY_RUNNING` | `SHORT_RECOVERY_FINISHED`, `PAUSED`, `INTERRUPTED_UNKNOWN`, `FAILED_CLOSED` | Exact recovery completion evidence, known pause/failure, or interruption. |
| `SHORT_RECOVERY_FINISHED` | `SHORT_RECOVERY_VERIFIED`, `PAUSED`, `FAILED_CLOSED` | Output and state evidence are independently reviewed. |
| `SHORT_RECOVERY_VERIFIED` | `LONG_SCAN_RUNNING`, `READY_FOR_HANDOFF`, `PAUSED`, `ABORTED` | Technician chooses Long or ends File Scavenger work; fresh checks pass. |
| `LONG_SCAN_RUNNING` | `LONG_SCAN_FINISHED`, `PAUSED`, `INTERRUPTED_UNKNOWN`, `FAILED_CLOSED` | Exact long-scan completion evidence, known pause/failure, or interruption. |
| `LONG_SCAN_FINISHED` | `LONG_RECOVERY_RUNNING`, `PAUSED`, `FAILED_CLOSED` | Technician chooses Step 2 and a fresh destination check passes. |
| `LONG_RECOVERY_RUNNING` | `LONG_RECOVERY_FINISHED`, `PAUSED`, `INTERRUPTED_UNKNOWN`, `FAILED_CLOSED` | Exact recovery completion evidence, known pause/failure, or interruption. |
| `LONG_RECOVERY_FINISHED` | `LONG_RECOVERY_VERIFIED`, `PAUSED`, `FAILED_CLOSED` | Output and state evidence are independently reviewed. |
| `LONG_RECOVERY_VERIFIED` | `READY_FOR_HANDOFF`, `PAUSED`, `ABORTED` | Final identity, close, and output checks pass or the operator stops. |
| `PAUSED` | a new attempt for the same stage, `ABORTED`, `FAILED_CLOSED` | Explicit operator decision, fresh checks, and a new attempt ID. Never automatic. |
| `INTERRUPTED_UNKNOWN` | `PAUSED`, `FAILED_CLOSED` | Review gate; no automatic retry or completion. |
| `READY_FOR_HANDOFF` | `HANDOFF_MANUAL`, `PAUSED`, `FAILED_CLOSED` | Launch-only R-Studio preconditions pass or handoff is blocked. |
| `HANDOFF_MANUAL` | none in v1 | Terminal boundary for this case. |
| `ABORTED` | none | Terminal operator decision. |
| `FAILED_CLOSED` | none | Create a new case or perform a technician-led evidence recovery. |

The orchestrator may use a paused/retry transition only when it records a new
attempt ID and an operator decision naming stage, reason, and scope. A verified
stage is never rerun silently.

### 4.3 Required events

Each event is one JSONL record with `EventId`, `Sequence`, `TimestampUtc`,
`JobId`, `State`, `Stage`, `AttemptId`, `EventType`, `Result`, source and
destination identity references, and structured `Error`/`Decision` fields when
relevant. At minimum, support:

```text
PreflightPassed
SourceIdentityCaptured
DestinationIdentityCaptured
DestinationSeparationVerified
CaseCreated
StageStarted
ScanFinished
RecoveryFinished
OutputObserved
StageVerified
DestinationLowSpace
DestinationLost
SourceIdentityChanged
OperatorGatePresented
OperatorDecision
StagePaused
StageFailed
StageInterruptedUnknown
GracefulCloseRequested
GracefulCloseVerified
ForceCloseRequested
ForceCloseVerified
RStudioLaunchOnlyHandoff
```

Write and flush `StageStarted` before the external action it authorizes. Write
and flush the specific finish, observation, verification, failure, or close event
before advancing. A missing final event, contradictory event, duplicate sequence,
wrong job ID, or process disappearance after `StageStarted` is
`INTERRUPTED_UNKNOWN`, not success.

### 4.4 Resume rules

1. Acquire the exclusive job lock before reading or changing state.
2. Validate schema, job ID, log sequence, event/state consistency, identity
   fields, and required paths.
3. Re-resolve source and destination and compare complete physical identity
   tuples. Recheck access, capacity, and application build evidence.
4. Convert any open `Running` attempt, missing final event, process loss, or
   contradiction to `INTERRUPTED_UNKNOWN`.
5. Resume automatically only from a prior `*_VERIFIED` state to its next allowed
   stage after fresh checks. Never rerun that verified stage.
6. If output exists without verification, preserve it and present inspect/retry/
   abort choices. Never delete or overwrite it to make retry convenient.
7. Corrupt, copied, stale, or identity-mismatched state becomes `FAILED_CLOSED`.

## 5. Safety gates

Every gate displays its ID, trigger, evidence, exact scope, choices, and safe
default, then records the operator and UTC decision. The gate API must not use a
blank or timeout as Continue.

| Gate | Trigger | Continue condition | Safe default |
| --- | --- | --- | --- |
| G-01 Preflight | Missing/ambiguous elevation, required module, application, or config | Technician supplies/verifies the prerequisite and it is recorded | Stop |
| G-02 Source identity | Missing, contradictory, changed, inaccessible, or unprotected source | Complete source and read-only/write-blocker evidence | Stop |
| G-03 Destination separation | Same physical disk, same volume, incomplete mapping, virtual/network ambiguity, or unresolved path | Complete disjoint physical-disk evidence and safe path | Stop |
| G-04 Vendor surface | No exact-build evidence for a control, switch, completion signal, or close mechanism | Technician performs/records live validation or performs it manually | Manual gate; do not guess |
| G-05 Stage completion | Scan/recovery/output/application evidence is incomplete or contradictory | Evidence for the exact named stage is reviewed | Pause |
| G-06 Resume | Prior attempt is running, interrupted, stale, corrupt, or output verification is incomplete | Explicit inspect, retry-with-new-attempt, or abort decision | Do not rerun |
| G-07 Capacity/media | Low space, write error, destination loss, or changed destination identity | Same destination is restored and revalidated with reserve | Pause; never redirect |
| G-08 Close | Graceful close failed or vendor state is unclear | Supported graceful close succeeds; force close meets every guard | Leave active state untouched |
| G-09 Output collision | Existing job/output path or duplicate recovered name | Documented no-overwrite behavior and exact technician decision | Preserve data and pause |
| G-10 Handoff | File Scavenger work, close, or final identity check is incomplete | Final checks pass; R-Studio launch-only boundary is accepted | Do not launch automatic analysis |

The following cases are always blockers or gates rather than fallback behavior:

- Same-disk safety override: never supply `Yes` to the vendor's Overriding code.
- Vendor overwrite mode or "always use this response": never select it in code.
- Scan journal overwrite prompt: never answer it silently.
- Destination removal or changed media: preserve output, record loss, and
  require the same identity before resume.
- Low capacity: stop starting new work, preserve partial output, record the
  measured value/error, and do not move to another path.
- Force close: never use it during scan, recovery, or unknown state.
- R-Studio `Enable Write`, editor writes, wipe, repair, partition changes, or
  automatic analysis: outside the workflow and manual-only.

## 6. Path, identity, and non-overwrite rules

Windows path handling follows the storage research design:

- Resolve volume by `Get-Volume -FilePath` where available, then join through
  partition and disk identity. Mounted folders are valid only when resolved.
- Record every backing disk for a spanning volume. Dynamic disks, Storage Spaces,
  File-Backed Virtual, VHD, network, missing-provider, and contradictory cases
  are indeterminate unless complete membership is proven.[25][27][29][30]
- Compare strong identity fields, never only drive letter, label, friendly name,
  or disk number. Re-read identity before each external application action and
  after a media boundary.[25][29]
- Resolve the final path and existing ancestors, reject unresolved reparse
  redirects, and recheck after creating the client folder.
- Apply documented invalid-name/reserved-name rules, then restrict generated
  client components to ASCII `[A-Za-z0-9._-]`. The .NET invalid-character list
  is not treated as complete by itself.[31][37]
- Keep the sanitized client name at 40 characters or fewer and the full job path
  below the v1 200-character budget. Stop rather than silently truncate.[35]
- `Directory.CreateDirectory` is not a collision guard. Claim the state/marker
  file with `FileMode.CreateNew`; on collision, use a bounded suffix and never
  write into or delete the existing folder.[33][34]
- Metadata, lock, event log, session, journal, and recovered output must be on a
  validated non-source destination. The same physical-disk refusal applies to
  every one of them.

## 7. PowerShell 5.1 and CI contract

The implementation and tests must preserve the repository runtime contract:

- All `.ps1`, `.psm1`, `.psd1`, `.json`, `.md`, and related committed text is
  ASCII and BOM-free. `.bat` is ASCII, CRLF, and ends with CRLF.
- Do not use PowerShell 7-only syntax or parameters: ternary, null-coalescing,
  pipeline-chain operators, `-AsByteStream`, `utf8NoBOM` encoding parameter,
  `Test-Json`, or `Get-Error`.
- The authoritative parser gate runs under real Windows `powershell.exe` 5.1;
  a PowerShell 7 parser alone is insufficient. PSScriptAnalyzer compatibility
  findings are promoted to errors, not warnings.
- Use explicit `-ErrorAction Stop` at I/O boundaries, invariant UTC timestamps,
  explicit JSON depth, schema checks after `ConvertFrom-Json`, and byte-accurate
  writers. Never treat a non-terminating error or `$?` alone as success.
- Static AST contracts reject disk/partition changes, native destructive tools,
  device paths, dynamic invocation, unsafe `Remove-Item`, and unverified
  external process paths. Tests cannot mock a destructive command into safety.
- Use `TestDrive:` for Pester writes. Unit/static tests do not call storage APIs,
  start external processes, reference vendor executable names, or write outside
  the test root.

The CI topology is:

| Lane | Image/shell | Coverage |
| --- | --- | --- |
| `static-linux` | `ubuntu-latest`, `pwsh` | Encoding, BOM, launcher text, AST safety, PS7-only scan, test layout |
| `test-win2022` | `windows-2022`, `powershell` 5.1 | Real 5.1 parser, Pester unit/contract tests, launcher through `cmd.exe`, read-only inventory checks |
| `test-win2025` | `windows-2025`, `powershell` 5.1 | Same suite on the second pinned Windows image |
| `compat-analyze` | `windows-2022`, `pwsh` | PSScriptAnalyzer PS 5.1 syntax/command compatibility with findings as errors |
| `owner-live` | Technician machine | Licensed File Scavenger/R-Studio, real GUI, media, elevation, and end-to-end evidence; never CI |

Pin `windows-2022` and `windows-2025`; do not use `windows-latest`. Pin and
assert the Pester 5.x version. Live tests are excluded by directory and tags
`LiveVendor`/`LiveElevation`; when prerequisites are absent they must report
`Skip`, never `Pass`.

The launcher contract is thin and testable: resolve `%~dp0`, invoke
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File` with exact argument
pass-through, capture and return the script exit code using `exit /b`, and pause
only when the explicit no-pause opt-out is absent. It contains no storage or
copy/delete command. Actual redirected-stdin pause behavior is an open Windows
run check; CI must use the explicit opt-out for bounded tests.

## 8. Owner-only live validation boundary

CI and synthetic fixtures cannot prove licensed vendor GUI behavior, source
write protection, window/UIA properties, timing, real topology, non-admin
behavior, media loss, low-space interruption, or graceful/force close. The owner
or technician must run a disposable/test recovery case with a hardware write
blocker where available, a separately verified destination physical disk, and the
exact intended product builds. Record product/version/build, executable path,
license mode, OS/PowerShell, timestamps, identity snapshots, operator decisions,
logs, screenshots, and observed artifacts in the case record; do not commit
credentials, license keys, or recovered content.

### 8.1 File Scavenger live checklist

The owner must explicitly validate and record:

1. Installed or portable executable identity, About version/build, administrator
   requirement, language, and the exact license/demo mode. Demo mode can save
   only the first 64 kilobytes of each file, so it cannot establish full-output
   success.[3]
2. Process path/start identity, main window readiness, and whether the documented
   captions are exposed through stable UIA/MSAA properties on the exact build.
3. `Look in`, `Look for`, `Quick or Long scan`, `Scan`, `Pause`, `Step 2: Save`,
   `Save to`, `Use folder names`, and `Save` behavior. The operator remains the
   decision-maker even if controls are reachable.[5][7]
4. Distinct scan-finished versus recovery-finished signals; status panel values;
   output inventory; `Recovery.log` exact name/location/format; and whether CSV
   export includes status columns. Do not promote any of these unknowns from
   documented label to completion contract without observation.[8][9]
5. Long-scan journal placement and per-drive separation, session save/load,
   pause/resume, reboot/resume, and whether the combined path is safe.[9][10]
6. Same-drive safety prompt and `Overriding code`; prove the workflow never
   supplies `Yes`. Observe overwrite modes and journal overwrite prompts; prove
   the workflow never selects a destructive or persistent answer.[11][14]
7. Graceful File > Exit, close confirmation, helper-process behavior, and the
   guarded force-close path after verified recovery only. A force close during
   active or unknown work must be refused.
8. Destination removal, destination replacement at the same drive letter, low
   space, source loss, and output conflicts. The workflow must pause/stop and
   preserve output without redirecting.

### 8.2 R-Studio live checklist

The owner must explicitly validate:

1. The selected executable is R-Studio for Windows, not R-Studio Agent or
   Emergency; record path and installed/runtime version/build. Portable mode
   still requires this identity check.[16][23]
2. Administrative launch behavior, exact `-safe` startup behavior, and optional
   `-log <filename>` output on the validated non-source case path.[17][24]
3. Process/window/main-panel readiness. Confirm no source selection, partition
   search, scan, file marking, recovery, destination selection, or automatic
   analysis occurs before technician action.[18][19][22]
4. The separate Explorer client-folder action, if enabled, does not invoke an
   R-Studio recovery action and refuses an unsafe/unresolved path.
5. The workflow never enables `Enable Write`, editor writes, wipe, repair, or
   other destructive controls; settings and low-space prompts remain manual.[18][21]

### 8.3 Environment and release gate

At least once per release, the owner also validates the true double-click path,
localized/manual gates, non-admin behavior, destination and source physical
identity on real removable media, junction/reparse handling, concurrent lock,
crash/resume, output collision, destination removal, low space, graceful close,
and the visible handoff panel. A live gate that lacks a licensed product or the
required hardware must be visibly skipped, not converted into a synthetic pass.

## 9. Implementation acceptance criteria

The implementation phase is complete only when all of the following are true:

- Module exports and state/event names match this document, or a deliberate
  change is recorded before code is written and all dependent tests are updated.
- Every stage has a start event, distinct finish event, output observation, and
  verification decision. Scan completion cannot authorize recovery handoff.
- Source/destination identity, path, capacity, lock, metadata, and log checks are
  fresh at every external boundary and fail closed on unknown values.
- New jobs cannot collide with existing folders or files; existing bytes remain
  unchanged in tests.
- File Scavenger has no invented CLI/config/macro path. Its scanner actions,
  close, and completion semantics remain manual unless exact-build live evidence
  is captured.
- R-Studio launch arguments are exactly the documented launch-only set, with no
  automatic analysis or recovery action.
- Static contracts, Windows 5.1 parser/compatibility gates, both pinned Windows
  runner jobs, launcher integration, and unit tests are green. Live tests remain
  explicitly skipped in CI and are listed in the owner record.

## Evidence register

Repository evidence is authoritative for project requirements and synthesis:

- `AGENTS.md`: mission, non-negotiable safety, PowerShell 5.1, encoding, UI,
  logging, and review rules.
- `README.md`: product boundary, safety boundary, planned entry points, and
  verification split.
- `docs/WORKFLOW.md`: ten acceptance requirements and owner-live gate.
- `research/file-scavenger-official.md`: primary QueTek research, GUI/artifact
  surface, unsupported automation, version/license limits, and manual gates.
- `research/file-scavenger-cross-check.md`: independent QueTek/manual/binary
  cross-check, terminology, observables, safety behavior, and unresolved live
  questions.
- `research/rstudio-official.md`: R-Tools Windows launch-only contract,
  documented switches, artifacts, and manual analysis boundary.
- `research/windows-storage-ui-design.md`: Windows identity join, fail-closed
  disk separation, folder picker, sanitization, collision, and path budget.
- `research/safety-resumability.md`: threat model, state machine, events, gates,
  resume, close, handoff, and invariants.
- `research/windows-ci-blueprint.md`: PS 5.1 traps, seam design, static/Windows
  lanes, launcher contracts, and owner-live limits.

The numbered primary URLs below are the sources cited by the research artifacts;
this specification does not add vendor claims beyond those artifacts.

## Sources

[1] https://www.quetek.com/download.htm
[2] https://www.quetek.com/prod02.htm
[3] https://www.quetek.com/faq.htm
[4] https://www.quetek.com/fs71man/FS_toc.htm
[5] https://www.quetek.com/fs71man/afxc36xx.htm
[6] https://www.quetek.com/fs71man/afxc9y91.htm
[7] https://www.quetek.com/fs71man/afxc0ynh.htm
[8] https://www.quetek.com/fs71man/afxc6s2v.htm
[9] https://www.quetek.com/fs71man/afxc0zmt.htm
[10] https://www.quetek.com/fs71man/afxc078l.htm
[11] https://www.quetek.com/fs71man/afxc83mt.htm
[12] https://www.quetek.com/fs71man/afxc92b7.htm
[13] https://www.quetek.com/fs71man/afxc7j77.htm
[14] https://www.quetek.com/fs71man/afxc11b9.htm
[15] https://www.quetek.com/fs71man/afxc3ol4.htm
[16] https://www.r-studio.com/Data_Recovery_Download.shtml
[17] https://www.r-studio.com/Unformat_Help/r-studioswitches.html
[18] https://www.r-studio.com/Unformat_Help/basicfilerecovery.html
[19] https://www.r-studio.com/Unformat_Help/discscan.html
[21] https://www.r-studio.com/Unformat_Help/r-studio_settings.html
[22] https://www.r-studio.com/Unformat_Help/r-studio_main_panel.html
[23] https://www.r-studio.com/Data-Recovery-Install-Register-Activate.html
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
[40] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1
[41] https://www.quetek.com/bin/64fsu71.exe
