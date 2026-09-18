# Safety, resumability, and failure-state threat model

Status: implementation research only. This document defines safety boundaries and acceptance checks; it does not claim that a File Scavenger or R-Studio control, command-line switch, or completion signal has been verified.

Scope: a technician-facing Windows PowerShell 5.1 workflow that prepares a recovery case, runs only verified File Scavenger work, and hands the case to R-Studio without destructive operations. The workflow must fail closed when it cannot establish the source identity, destination separation, application state, or recovery outcome.

## 1. Source requirements and evidence boundary

The repository rules and workflow contract establish these requirements:

- `AGENTS.md:4-20` requires a read-only source, physical-disk separation, no destructive disk or file operations, explicit vendor evidence, explicit failure handling, and Windows PowerShell 5.1 compatibility.
- `README.md:3-11` requires a non-destructive job, source/destination physical-disk validation, evidence, no overwrite, and a clear stop on an unsafe destination, unavailable output media, or uncertain application state.
- `docs/WORKFLOW.md:5-14` requires logged preflight, source identity, a folder-browser destination, metadata and an append-only log before scanner work, distinct scan and recovery stages, verified stage ordering, guarded close, launch-only R-Studio handoff, manual gates for unsupported operations, and explicit operator choice before rerunning a completed stage.
- `docs/RESEARCH-INDEX.md:3` requires primary vendor evidence or a reproducible installed-version observation for automation claims.

No live File Scavenger or R-Studio version/build observation is present in the repository. Product landing pages are not evidence of a usable automation surface. Until a technician records the installed version/build, exact control or command surface, observed completion signal, and an end-to-end disposable-case result, scanner controls remain manual gates.

## 2. Safety model

### 2.1 Assets to protect

- Source bytes, filesystem metadata, partition metadata, and the source physical device.
- Recovered output and the evidence needed to distinguish complete, partial, and unknown output.
- The case directory, job metadata, append-only event log, and resume state.
- Operator decisions, vendor version/build evidence, and the audit trail for every gate.
- Physical-disk identity and destination capacity information.
- The technician's time and the ability to resume without silently repeating work.

### 2.2 Trust boundaries

Treat these as untrusted or failure-prone inputs until checked at the point of use:

- Drive letters, mount points, UNC paths, junctions, symbolic links, reparse points, VHDs, and any path typed by an operator.
- Disk numbers, volume labels, and friendly names. They are not sufficient identity on their own and can change after reconnect or reboot.
- Job metadata and state files that may be stale, truncated, copied, edited, or left in a `Running` state by a crash.
- File Scavenger and R-Studio GUI state, process exit, window title, and undocumented controls.
- Free-space readings, because output size is unknown and media can disappear between the reading and the write.
- Process IDs, because a PID can be reused and a process can have child processes or helper processes.
- Operator input, including client names, paths, confirmation text, and requested retries.
- External media, removable devices, network shares, and storage pools whose physical membership cannot be resolved completely.

### 2.3 Security and safety goals

1. The workflow never intentionally writes to the selected source or changes its partitions, filesystem repair state, or disk configuration.
2. Every possible destination is mapped to its physical-disk set. Any overlap with the source set, or any unknown mapping, blocks the job.
3. Output is never redirected, deleted, or overwritten automatically.
4. A stage is complete only when the correct kind of completion has been observed and recorded. Scan completion never means recovery completion.
5. An interrupted or uncertain stage is never silently treated as complete and is never automatically rerun.
6. Every unsupported vendor action becomes a visible, auditable manual gate with a safe default.
7. The job can be resumed only when its identity, source, destination, log, and prior verified stage are still trustworthy.
8. A human can tell from the state and log whether the case is paused, failed, partially recovered, ready for handoff, or still active.

### 2.4 Non-goals

- Proving that an arbitrary vendor GUI obeys a read-only or no-overwrite setting.
- Recovering from an unknown vendor state by guessing a control, command-line switch, or window title.
- Making a disconnected or full destination safe by choosing another destination automatically.
- Repairing, mounting with write intent, formatting, initializing, partitioning, deleting, cleaning, or otherwise changing storage.
- Treating a successful process launch or process exit as proof that a scan or recovery completed.

## 3. Threat model and required response

Severity `Blocker` means the workflow must not start or continue the affected vendor stage. Severity `High` means it must pause or enter an explicit operator gate. There is no automatic recovery action that changes source or destination selection.

| ID | Threat or failure | Consequence | Required control and safe response | Test fixture |
| --- | --- | --- | --- | --- |
| T-01 | A drive letter is reused after reconnect or reboot. | The workflow reads a different device. | Capture a source identity tuple and revalidate it before every vendor stage and after a reconnect. Block on any mismatch. | Reassign the source letter to a different volume. |
| T-02 | Vendor software or a helper writes to the source. | Evidence or source data is modified. | Use a hardware write blocker when available; inspect, do not change, disk state; prohibit destructive cmdlets and commands; keep unverified vendor behavior behind a live manual gate. A software read-only flag alone is not proof. | Disposable source with write monitoring and a vendor live-test record. |
| T-03 | Destination is another partition or mount point on a source disk. | Recovered data competes with or modifies the source device. | Resolve the destination path to all physical disks, not only a drive letter. Reject any set intersection. | Source `Disk 0`, destination `Disk 0` on another volume. |
| T-04 | Destination topology is unknown, such as a network share, Storage Spaces volume, dynamic disk, RAID member, or VHD. | Separation cannot be proven. | Fail closed or require a named manual gate with complete member-disk evidence. Do not claim separation from a volume label or one disk number. | Destination whose physical membership cannot be enumerated. |
| T-05 | A junction, symbolic link, reparse point, or mount point redirects the selected folder. | Writes land outside the reviewed destination. | Canonicalize and re-resolve the final path and existing ancestors. If final path resolution is unavailable, block. Recheck after creating the client folder. | Destination containing a junction to the source volume. |
| T-06 | A pre-existing job folder or output file has the same name. | An old case or recovered file is overwritten or mixed with this case. | New job creation must use collision-resistant creation and fail if the target exists. Never pass an overwrite or force option. Require a manual gate for any vendor duplicate-file behavior. | Pre-create the expected job path and a sentinel output file. |
| T-07 | Space is insufficient or is consumed by another process. | Recovery stops part-way or corrupts output. | Check capacity before each stage and during recovery; use a documented reserve and conservative estimate; pause on threshold or write error. Preserve existing output and do not redirect. | Start below threshold; consume space during a synthetic recovery. |
| T-08 | Destination media is removed, offline, or loses access. | Output status becomes uncertain. | Request graceful stop only if active state is known and the verified vendor surface supports it; otherwise mark destination loss and operator review. Do not select another path. Resume only after the same destination identity is present. | Remove destination before and during each stage, then reattach a different disk at the same letter. |
| T-09 | Source media is removed, changes identity, or becomes unreadable. | Further reads may target the wrong device or fail ambiguously. | Stop vendor work, record the exact error, and enter `SOURCE_UNAVAILABLE` or `SOURCE_IDENTITY_CHANGED`. Never retry against a changed identity. | Disconnect and replace source while paused. |
| T-10 | Scan completion is mistaken for recovery completion. | Long work starts without recovered output, or the case is handed off incomplete. | Model scan and recovery as separate states and events. Require distinct evidence for `ScanFinished`, `RecoveryFinished`, and output verification. | Vendor/test double reports scan done but no recovery done. |
| T-11 | A process exits, hangs, or loses its window during a stage. | Completion and output are unknown. | Process launch and exit are only observations. Mark active or unknown state as `NEEDS_REVIEW`; do not infer completion from PID, title, or exit code. | Kill or hang the test process at each stage boundary. |
| T-12 | Power loss or script termination leaves a stage marked `Running`. | Resume could repeat or skip work. | Write a start event before external work and a verified completion event after it. On resume, any open attempt becomes `INTERRUPTED_UNKNOWN`; require explicit retry or abort. | Terminate between every journal event pair. |
| T-13 | State or metadata is truncated, edited, copied, or from another job. | Resume uses the wrong source, destination, or stage. | Validate schema, job ID, event sequence, source tuple, destination tuple, and log integrity. Lock the job. Reject missing or conflicting fields. | Truncate JSON, copy metadata between jobs, and edit disk identity. |
| T-14 | Two technicians run the same job concurrently. | Both launch vendor work or write output. | Acquire an exclusive job lock before reading resume state; record owner and lease details; fail closed when a live lock cannot be distinguished from a stale one. | Launch two instances against one job directory. |
| T-15 | A manual or guessed vendor control performs an unreviewed action. | The workflow may scan, recover, close, or alter state incorrectly. | Record direct vendor evidence and build; otherwise show a gate. Never invent control names, switches, or success conditions. | Remove the evidence fixture or use an unsupported installed build. |
| T-16 | A path or client name is used for command injection or path traversal. | Arbitrary programs or locations are accessed. | Use literal process paths and controlled argument construction; do not invoke `cmd.exe` for untrusted input. Sanitize folder components, preserve the original in metadata if needed, and verify the final path remains under the reviewed root. | Names containing quotes, `..`, wildcards, CR/LF, and reserved device names. |
| T-17 | The log cannot be written or flushed. | Later decisions cannot be audited or safely resumed. | Treat log initialization or append failure as a blocker. Do not continue vendor work without a durable event record. | Deny log-directory access or fill the metadata volume. |
| T-18 | Force close terminates active recovery. | Partial output and vendor state become unknown. | Force close is permitted only after verified recovery completion and an explicit operator decision. It is forbidden during `ScanRunning`, `RecoveryRunning`, or any unknown state. | Request force close in each state, including a hung active recovery. |
| T-19 | R-Studio is launched with automatic analysis or destructive options. | The handoff exceeds the safety boundary. | Handoff is launch-only unless an exact supported surface is separately verified. Do not automate analysis, repair, or changes. Record the manual operator boundary. | Inspect the actual launch arguments and require a manual next step. |
| T-20 | A log or state update is mistaken for an output verification. | A case is marked complete without usable recovered data. | Keep stage state, vendor evidence, output inventory, and verification result separate. A log entry saying `Finished` is not sufficient by itself. | Write a completion event while the destination contains no expected output. |

## 4. Physical identity and destination separation

### 4.1 Identity data to capture

Capture enough information to detect a changed device, while recognizing that no single field is a durable identity across every Windows storage stack. At minimum, record the values exposed by the host for:

- Source and destination canonical path, volume GUID/path where available, drive letter if present, volume serial, filesystem, size, and label.
- Every mapped physical disk number, device path, unique ID, serial, bus/type, size, and partition offset that can be resolved.
- The mapping method and the fields that were unavailable. An absent identity field is evidence of uncertainty, not a reason to compare fewer fields silently.
- A timestamped identity snapshot before case creation and a fresh snapshot before every scan, recovery, close, and handoff boundary.

Use a set of physical disks for a source or destination. A volume that spans multiple members must include every member. The separation invariant is:

`sourcePhysicalDiskSet is not empty AND destinationPhysicalDiskSet is not empty AND intersection(sourcePhysicalDiskSet, destinationPhysicalDiskSet) is empty`

If a disk set cannot be proven complete, the result is `UNKNOWN`, not `SEPARATE`. Network paths and virtual storage need an explicit documented policy; they must not pass just because Windows reports a drive letter.

Disk number alone is not an identity. Prefer a stable combination of device path, unique ID, serial, size, and partition/volume information, and revalidate after media events. If the host exposes contradictory values, stop rather than selecting the most convenient value.

### 4.2 Destination path controls

1. Let the operator choose a destination with a Windows folder browser, then display the resolved path and physical-disk evidence for confirmation.
2. Resolve the nearest existing ancestor when the final client folder does not exist. Recheck after creating it.
3. Reject a path that cannot be canonicalized, is inaccessible, is a reparse redirect whose target cannot be inspected, or is on a disk that cannot be mapped.
4. Create a unique client/job folder with a collision-resistant job ID and a non-overwriting create operation. An existing folder is not an invitation to reuse it.
5. Keep the output root and metadata root explicit. Do not silently move metadata to the source, a temporary drive, or a different destination if the reviewed path fails.
6. Recheck physical identity and access immediately before a vendor write stage. A check performed only during preflight is stale as soon as removable media or storage topology changes.

## 5. Read-only source boundary

Read-only is a layered control, not a single property:

- Prefer a hardware write blocker and record its use. The workflow cannot prove a vendor application will honor a UI option merely by displaying it.
- Inspect source state and topology only. Do not call commands that set read-only state, mount with write intent, repair, initialize, format, clean, resize, delete, or modify partitions.
- Keep source file handles and paths out of any output-writing helper. A source path should be an input to read/identity code only.
- Use a static safety contract to reject destructive cmdlets and native commands in workflow code, while recognizing that a static deny list is not a substitute for a live vendor test.
- Revalidate source identity and access before every external application action. If identity is missing, changed, or inaccessible, stop before launching the next action.
- Record a post-stage source check where the hardware and test setup can support it. CI can test call selection and state handling but cannot prove a licensed vendor GUI did not write to a real disk.

A failed read is not permission to repair the source. It is a paused case requiring a technician decision outside this workflow.

## 6. Capacity, destination loss, and output integrity

### 6.1 Capacity policy

Recovery output size is not known in advance. The implementation must define a configurable policy before launch, including:

- A minimum free-space reserve that is never consumed automatically.
- A conservative per-stage estimate when the vendor exposes one, with an explicit `estimate unknown` result when it does not.
- The check interval or event used while recovery is active.
- The behavior when a capacity query fails, returns an unavailable value, or changes sharply.

Use available space rather than only total free space. A preflight reading is advisory and must not be treated as a reservation. Check before metadata creation, before each scan/recovery stage, periodically during recovery where possible, and after every output error.

When the reserve is reached or a write returns a full-volume error:

1. Stop starting new work.
2. Request a graceful vendor stop only if the active state and documented stop surface are known.
3. Preserve all output already written; do not delete partial files to make room.
4. Append a `DESTINATION_LOW_SPACE` or `DESTINATION_WRITE_FAILED` event with the measured value and exact error.
5. Pause or fail closed. Do not redirect to another path.
6. Require explicit operator review before resuming, and revalidate the same destination identity and available space.

### 6.2 Destination loss

A missing path, access-denied result, I/O error, or changed volume identity is destination loss until proven otherwise. It must not be converted to an empty directory or a new drive letter. If the media returns, it must match the recorded destination identity and reviewed canonical path. A different device at the same path is a new destination and cannot resume the old job.

If loss happens during active recovery, output completeness and vendor state may be unknown. Do not mark the stage complete, do not automatically retry, and do not force-close the application merely to make the script return. Require a gate with choices such as inspect output, gracefully stop if supported, abort the case, or perform a separately documented retry.

### 6.3 No overwrite and no cleanup

- Never use a force or overwrite option for job creation, metadata, logs, or recovered output.
- A pre-existing job directory blocks new-job creation. Resuming an existing job is a separate, identity-checked operation and appends to its journal rather than replacing its history.
- An output-name conflict must be visible. If a vendor's collision behavior is not documented and live-tested, pause for a manual decision; do not assume skip, rename, or overwrite semantics.
- Do not delete partial output, stale output, or an old job to recover space. Preservation is safer than an automatic cleanup policy.
- Before synthetic tests, place sentinel files in the destination and verify their bytes, size, and timestamp remain unchanged after every path and collision test.

## 7. Scan, recovery, close, and handoff state machine

### 7.1 State vocabulary

Use separate state and evidence fields. A single `status` string is not enough to distinguish an application process, a scan, a recovery, and output verification.

Recommended top-level states:

- `NEW`: no work has started.
- `PREFLIGHT_PENDING`: inputs are being checked.
- `PREFLIGHT_PASSED`: source, destination, disk separation, and application prerequisites passed.
- `CASE_READY`: job metadata, lock, and append-only log exist and are durable.
- `SHORT_SCAN_RUNNING` / `SHORT_SCAN_FINISHED`.
- `SHORT_RECOVERY_RUNNING` / `SHORT_RECOVERY_FINISHED` / `SHORT_RECOVERY_VERIFIED`.
- `LONG_SCAN_RUNNING` / `LONG_SCAN_FINISHED`.
- `LONG_RECOVERY_RUNNING` / `LONG_RECOVERY_FINISHED` / `LONG_RECOVERY_VERIFIED`.
- `PAUSED`: a known recoverable condition requires an operator decision.
- `INTERRUPTED_UNKNOWN`: an attempt ended without reliable completion evidence.
- `FAILED_CLOSED`: the workflow stopped because a safety or durability invariant failed.
- `READY_FOR_HANDOFF`: File Scavenger work is verified finished and the case is ready for the allowed R-Studio launch-only handoff.
- `HANDOFF_MANUAL`: R-Studio was presented to the operator; further analysis is outside the automated boundary.
- `ABORTED`: the operator chose not to continue. This is terminal for this job unless a separately documented new case is created.

`*_FINISHED` means the vendor reports that the named operation ended. `*_VERIFIED` means the workflow has separate evidence that the expected output and state are safe to proceed. Do not collapse these values into one generic `Complete` flag.

### 7.2 Required forward order

The minimum safe order is:

`CASE_READY -> SHORT_SCAN_RUNNING -> SHORT_SCAN_FINISHED -> SHORT_RECOVERY_RUNNING -> SHORT_RECOVERY_FINISHED -> SHORT_RECOVERY_VERIFIED -> LONG_SCAN_RUNNING -> LONG_SCAN_FINISHED -> LONG_RECOVERY_RUNNING -> LONG_RECOVERY_FINISHED -> LONG_RECOVERY_VERIFIED -> READY_FOR_HANDOFF -> HANDOFF_MANUAL`

A long scan cannot start until short recovery is verified complete. A long recovery cannot start until the long scan is verified finished. If a product workflow has a different sequence, the deviation requires an explicit design decision and vendor evidence; it must not be inferred from a button order.

### 7.3 Stage evidence

For each attempt, persist distinct events for:

1. `StageStarted`, including stage name, attempt ID, source and destination identity snapshots, application PID/process identity, version/build, and operator decision if any.
2. `ScanFinished` or `RecoveryFinished`, never a generic `Finished` event.
3. `OutputObserved`, including the reviewed output root and a safe inventory/verification result. Do not claim full recovery from a directory that merely exists.
4. `StageVerified`, including the evidence source and the operator or automatic rule that accepted it.
5. `StagePaused`, `StageFailed`, or `StageInterruptedUnknown` with the exact reason.

A process exit without the appropriate event is unknown. A scan completion event without a recovery completion event cannot authorize close, handoff, or the next recovery stage.

### 7.4 Resume semantics

On every resume attempt:

1. Acquire the job lock before reading or changing state.
2. Validate schema version, job ID, log sequence, state/event consistency, and required identity fields.
3. Re-resolve source and destination and compare the complete reviewed identity tuples. Check destination access and capacity.
4. Confirm that the application version/build and vendor evidence still match the recorded attempt, or require a manual gate.
5. Interpret any open `Running` attempt, missing final event, process disappearance, or contradictory event as `INTERRUPTED_UNKNOWN`, never as complete.
6. Resume automatically only from a prior `*_VERIFIED` state whose identity and safety checks still pass.
7. Never rerun a verified stage automatically. A retry requires a new attempt ID and an explicit operator decision event naming the stage, reason, and scope of the retry.
8. If a stage ended after output was written but before verification, keep the output, mark the stage unknown, and require inspection or an explicit retry policy. Do not delete or overwrite existing output to make the retry convenient.
9. If the state is corrupt, missing, or from a different source/destination, enter `FAILED_CLOSED` and require a new case or a technician-led recovery of the evidence.

A resume is not a continuation of an untrusted process. It is a fresh preflight against an existing, immutable case identity followed by the next allowed transition.

## 8. Graceful close and guarded force close

### 8.1 Graceful close

Graceful close must be attempted first when the workflow has verified that the vendor operation is finished or has a documented stop path for a known safe pause. The close mechanism, completion signal, and version/build must come from direct vendor evidence or a reproducible live observation. `Start-Process -Wait`, a window title, or a process exit is not a vendor completion proof.

After graceful close, verify:

- the expected process and any known helper process have exited;
- the application state is not still performing scan or recovery work;
- the stage has the correct `*_FINISHED` and `*_VERIFIED` events; and
- the source and destination identities still match before handoff.

If the application refuses to close or its state is uncertain, pause and expose the condition. Do not escalate to a generic process kill.

### 8.2 Force close gate

Force close is a last resort and is allowed only when all of the following are true:

- the current state is not `*_SCAN_RUNNING`, `*_RECOVERY_RUNNING`, or `INTERRUPTED_UNKNOWN`;
- a separate evidence event proves the active recovery is finished, not merely that a scan finished;
- a technician explicitly confirms the force-close decision and records the reason;
- the process identity is tied to this job, not just a reused PID; and
- the action and post-close verification are appended to the log before handoff.

If any condition is false, force close is forbidden. In particular, an unresponsive GUI during active or unknown recovery must remain a manual technician decision outside the automation boundary. Killing a process does not make output complete and must never be used to manufacture a successful state.

## 9. Metadata, journal, and durable state

### 9.1 Metadata created before scanner work

Before launching vendor work, create a unique case directory and durable metadata containing at least:

- schema version and unique job ID;
- creation time in UTC, host identity, workflow version, and operator identity according to the project's privacy policy;
- source path as selected, canonical path if available, volume identity, physical-disk set, size, filesystem, and read-only/write-blocker evidence;
- destination path as selected, canonical path, volume identity, physical-disk set, output root, and capacity policy;
- preflight results and every unresolved field;
- File Scavenger and R-Studio executable path, observed version/build, evidence reference, and allowed surface. Unknown fields remain unknown;
- current state, current stage, attempt ID, and lock/owner information.

Do not put credentials, tokens, or unnecessary recovered-content data in metadata. Client names and source paths can be sensitive; preserve only what is required to resume and audit, with deterministic sanitization for folder names.

### 9.2 Append-only event log

Use an append-only, machine-readable log. Each event should have a unique event ID, UTC timestamp, job ID, state/stage, attempt ID, event type, result, source and destination identity references, operator decision reference, and structured error details when applicable. Include sequence numbers so truncation or reordering can be detected.

Flush each event before starting the external action it authorizes and after each boundary event. A log open, append, or flush failure is a safety failure. Do not continue and hope a later event repairs the gap.

The state snapshot may be rewritten atomically inside the owned job directory, but the event history must not be discarded. Write a temporary snapshot in the same directory, validate it, and replace only the owned snapshot with explicit existence and error handling. Do not use snapshot replacement as permission to overwrite recovered output or a pre-existing job.

### 9.3 Event examples

The exact schema is an implementation decision, but it must represent the distinction below without overloading a generic `success` value:

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

Each event type should have a documented required-field set and safe behavior when an optional field is absent.

## 10. Operator decision gates

Every gate must display the reason, evidence, safe default, and exact scope of the decision. Blank, malformed, or timed-out input must not mean continue. Record the operator, UTC time, job ID, stage, decision, reason, and evidence reference.

| Gate | Trigger | Continue condition | Safe default |
| --- | --- | --- | --- |
| G-01 Preflight | Elevation, executable discovery, or required module is missing or ambiguous. | Technician verifies the prerequisite outside the workflow. | Stop. |
| G-02 Source identity | Source disk/volume identity is missing, contradictory, changed, or not read-only protected. | Complete identity and write-protection evidence is available. | Stop. |
| G-03 Destination separation | Destination maps to a source disk or mapping is unknown/incomplete. | Complete disjoint physical-disk evidence is recorded. | Stop. |
| G-04 Vendor surface | A control, switch, completion signal, or close mechanism is not supported by direct evidence for the observed build. | Technician performs and records a live validation, or performs the step manually. | Manual gate; do not guess. |
| G-05 Stage completion | Scan, recovery, output verification, or app state is incomplete or contradictory. | Evidence for the exact named stage is reviewed. | Pause. |
| G-06 Resume | The prior attempt was running, interrupted, stale, corrupt, or output verification is incomplete. | Technician explicitly chooses inspect, retry with a new attempt, or abort. | Do not rerun. |
| G-07 Capacity/media | Low space, write error, destination loss, or changed destination identity. | The same destination is restored and revalidated, with enough reserve. | Pause; never redirect. |
| G-08 Close | Graceful close failed or vendor state is unclear. | Graceful close is retried only with a supported mechanism; force close only meets every guard. | Leave active state untouched and escalate. |
| G-09 Output collision | Existing job/output path or duplicate recovered filename is found. | A no-overwrite behavior is documented and the technician approves the exact scope. | Preserve existing data and pause. |
| G-10 Handoff | File Scavenger work is verified and R-Studio may be presented. | Source/destination identity and close checks pass. | Do not launch automatic analysis. |

## 11. Implementation checklist

### Preflight and case creation

- [ ] Require Windows PowerShell 5.1 or a deliberately tested compatible host; log the actual edition and version.
- [ ] Discover File Scavenger and R-Studio explicitly and log path plus observed version/build. Do not treat an executable path as evidence of supported automation.
- [ ] Require the expected privilege level and log a failed or ambiguous elevation check.
- [ ] Resolve and capture the source volume and complete physical-disk set.
- [ ] Capture the destination using a Windows folder browser and resolve its complete physical-disk set.
- [ ] Reject source/destination overlap and unknown/incomplete mappings.
- [ ] Recheck reparse points, mount points, canonical paths, and path accessibility.
- [ ] Apply the capacity policy and verify metadata/log space before output work.
- [ ] Create a unique case directory with a non-overwriting create operation; refuse a collision.
- [ ] Write and flush metadata, lock, and the initial event log before any scanner action.

### Source safety

- [ ] Keep source paths out of output-writing routines.
- [ ] Use read-only identity/inspection operations only; never add format, initialize, repair, CHKDSK, partition, cleanup, delete, or overwrite behavior as a fallback.
- [ ] Require write-blocker evidence where the live vendor workflow cannot prove read-only behavior.
- [ ] Revalidate source identity before every stage and after every media/process boundary.
- [ ] Make an identity mismatch a terminal safety failure for the attempt, not a prompt to pick the nearest matching drive letter.

### Stage execution

- [ ] Model scan and recovery as distinct stages and event types.
- [ ] Record a flushed `StageStarted` event before each external action.
- [ ] Verify exact vendor evidence for each completion signal; never infer from a generic process exit or window title.
- [ ] Refuse long scan until short recovery is verified; refuse long recovery until long scan is verified.
- [ ] Check destination identity, access, and available space before each stage and during active recovery where possible.
- [ ] Pause on low space, destination loss, source loss, write failure, or unknown vendor state.
- [ ] Preserve partial output and the complete journal; never redirect or delete automatically.
- [ ] Record output observation separately from vendor completion.

### Resume and concurrency

- [ ] Acquire an exclusive job lock before reading resume state.
- [ ] Validate schema, job ID, identity snapshots, event sequence, state transitions, and log parseability.
- [ ] Convert open or contradictory attempts to `INTERRUPTED_UNKNOWN`.
- [ ] Resume only from a verified prior stage after fresh identity and capacity checks.
- [ ] Require a new attempt ID and explicit operator decision for every retry of a completed or unknown stage.
- [ ] Never overwrite recovered files, old metadata history, or a pre-existing job directory.
- [ ] Treat stale-lock cleanup as an explicit lease/owner decision, not as automatic deletion.

### Close and handoff

- [ ] Attempt graceful close first using only a documented or live-verified mechanism.
- [ ] Verify application and helper-process state after close.
- [ ] Guard force close against active recovery, scan-only completion, unknown state, unrelated PIDs, and missing operator confirmation.
- [ ] Require final source/destination identity checks before handoff.
- [ ] Launch R-Studio only within the documented launch-only boundary; leave analysis, repair, and other unsupported actions manual.

### Observability and testability

- [ ] Use UTC timestamps, stable event IDs, attempt IDs, and sequence numbers.
- [ ] Flush the event log and fail closed on log errors.
- [ ] Redact credentials and unnecessary content names from logs while retaining enough identity to audit the case.
- [ ] Add static contracts for PowerShell 5.1 syntax, ASCII/no-BOM committed files, launcher thinness, destructive command absence, and safety transitions.
- [ ] Add Pester-compatible tests for each invariant below and use a disposable live case for vendor behavior.

## 12. Concrete testable invariants

These are acceptance invariants for implementation and review. Each must have at least one synthetic/static test and, where marked live, a technician validation.

| ID | Invariant | Expected assertion |
| --- | --- | --- |
| I-01 | Source identity is mandatory. | Missing, contradictory, or changed source identity prevents external stage launch. |
| I-02 | Source and destination physical sets are disjoint. | Any overlap or unknown mapping returns a blocking result; no destination write starts. |
| I-03 | Source is never a destination. | No output path, temp path, metadata path, or log path resolves to a source disk. |
| I-04 | Case creation is non-overwriting. | Existing job path or metadata causes a failure; it is not replaced. |
| I-05 | Durable case exists before scanner work. | A missing or unflushable metadata/log/lock prevents vendor launch. |
| I-06 | Scan and recovery are separate. | `ScanFinished` alone cannot produce `RecoveryVerified`, close success, or handoff readiness. |
| I-07 | Stage ordering is enforced. | Long scan is rejected without verified short recovery; long recovery is rejected without verified long scan. |
| I-08 | Only verified stages advance. | A process exit, title, or generic success cannot create a verified stage event. |
| I-09 | Interrupted attempts do not auto-resume. | Crash after `StageStarted` creates `INTERRUPTED_UNKNOWN`; no external retry occurs without a decision. |
| I-10 | Completed stages do not rerun silently. | A verified stage remains complete until an explicit retry decision creates a new attempt ID. |
| I-11 | Destination loss never redirects. | Missing/full/inaccessible output causes pause or failure; the path and disk identity never change automatically. |
| I-12 | Returned media must be the same media. | A different disk at the old path fails identity validation and cannot resume. |
| I-13 | Low space is fail-safe. | Threshold crossing blocks new work, preserves existing output, and records the measured condition. |
| I-14 | Output conflicts do not overwrite. | Sentinel bytes remain unchanged; conflicts pause unless a verified no-overwrite behavior is explicitly selected. |
| I-15 | Force close is guarded. | Force close is rejected during scan, recovery, or unknown state and requires explicit confirmation after verified recovery. |
| I-16 | Handoff follows close. | R-Studio launch-only handoff is rejected until File Scavenger work and close are verified. |
| I-17 | Unsupported controls are visible. | Missing vendor evidence creates a named manual gate and no guessed command/control is issued. |
| I-18 | Log failure blocks work. | Append/flush/sequence failure stops before the next external action. |
| I-19 | Concurrent execution is prevented. | A second process cannot acquire the job lock or launch vendor work. |
| I-20 | State is tamper-evident enough to stop safely. | Invalid schema, conflicting identity, bad sequence, or copied job ID enters `FAILED_CLOSED`. |
| I-21 | Paths cannot escape the reviewed root. | Reparse/path traversal/reserved-name fixtures are rejected or resolved to a path inside the reviewed destination. |
| I-22 | Source protection is live-validated. | A technician test with a write-blocked disposable source records the actual File Scavenger behavior; CI does not claim this proof. |

## 13. Verification matrix

| Scenario | Expected state/action | Evidence to assert |
| --- | --- | --- |
| Different physical disks, normal preflight | `CASE_READY` | Disjoint disk sets and flushed initial events. |
| Same physical disk, different drive letters | Block at destination gate | No vendor process launch and no output creation. |
| Unknown or incomplete physical mapping | Block or manual gate | No claim of separation. |
| Destination junction points to source | Block | Resolved target and error are logged. |
| Existing job directory | Reject new job | Existing bytes remain unchanged. |
| Existing output sentinel | Pause on collision | Sentinel hash/size remain unchanged. |
| Destination low before stage | `PAUSED` | No stage start event after the capacity failure. |
| Destination fills during recovery | Pause/fail closed | Partial output preserved, no redirect, exact I/O error logged. |
| Destination removed during scan | `DESTINATION_LOST`/`PAUSED` | No automatic new path and no false completion. |
| Destination returns as different disk | Resume rejected | Identity mismatch logged. |
| Source identity changes | `FAILED_CLOSED` | No further external action. |
| Scan reports finished, recovery not started | Scan-finished state only | Long stage and handoff both rejected. |
| Recovery finishes, output verification fails | `PAUSED` or `FAILED_CLOSED` | No `*_VERIFIED` event and no handoff. |
| Process exits after stage start with no completion event | `INTERRUPTED_UNKNOWN` | No automatic retry or completion. |
| Crash after verified stage | Resume at next allowed stage only | Prior stage not rerun; new lock and fresh identity checks. |
| Crash during recovery | `INTERRUPTED_UNKNOWN` | Explicit inspect/retry/abort gate. |
| Graceful close succeeds after verified recovery | Ready for handoff | Process/helper verification and close events. |
| Force close requested during active recovery | Reject force close | No kill action; operator gate remains. |
| Force close after verified recovery and confirmation | Guarded close | PID/process identity, reason, and post-close event recorded. |
| Log append or flush fails | Fail closed | No later vendor action. |
| Two workers open one job | Second worker blocked | Lock event and no duplicate launch. |
| Unsupported File Scavenger control | Manual gate | No guessed switch/control is invoked. |
| R-Studio handoff | Launch-only | No automatic scan, analysis, repair, or destructive action. |

## 14. Windows PowerShell 5.1 pitfalls

- Windows PowerShell 5.1 and PowerShell 7 are different products. Test the actual `powershell.exe` path and edition; do not claim compatibility from a `pwsh` parse alone.
- Do not use PowerShell 7 syntax: ternary operators, null-coalescing operators, null-conditional operators, or three-argument positional `Join-Path`. Use explicit parameters and ordinary `if` blocks.
- The Storage module and its `Get-Disk`, `Get-Partition`, and `Get-Volume` views may be unavailable, incomplete, privilege-sensitive, or unable to describe a virtual/network topology. Treat missing properties as unknown and provide a tested fallback or block.
- Do not compare only `DiskNumber`, drive letter, label, or friendly name. They can change or be reused. Record the mapping method and fail on contradictory identity fields.
- `Get-Volume` does not by itself prove the physical disk behind a path, and mounted folders/reparse points are not equivalent to a simple drive-letter path. Resolve the final handle/path and its ancestors or use an explicit manual gate.
- `Test-Path` can return false for inaccessible paths and has race windows. A false result is not proof that a path is absent or safe to create.
- `DriveInfo.AvailableFreeSpace` can differ from total free space and can throw for offline or unsupported media. Catch the error and fail closed; do not substitute a guessed zero or another drive.
- Drive-letter and free-space checks are not reservations. Recheck immediately before writes and during long recovery.
- `Start-Process -Wait` waits for a process, not for a GUI's scan/recovery state. It may not include child processes. Capture the returned process object and exit code, but still require vendor completion evidence.
- `Stop-Process -Force` is not a graceful close and can leave output and state unknown. Never use it as a generic timeout handler.
- A PID can be reused. Verify process path, start time, and job association where possible before any close action.
- Native command exit status is not the same as PowerShell success. Use `-ErrorAction Stop` for cmdlets, inspect `$LASTEXITCODE` for native commands, and check `ExitCode` on a `Start-Process -PassThru` process. Do not rely on `$?` alone.
- PowerShell has non-terminating errors by default. Set an intentional error policy and test every external I/O boundary; do not let a failed identity or log query fall through as an empty result.
- `ConvertTo-Json` defaults to a shallow depth, and PowerShell can unwrap a one-item array. Set depth explicitly, wrap collections with `@(...)`, and validate the resulting shape after round-trip parsing.
- `ConvertFrom-Json` does not validate the required schema. Check required properties, types, event sequence, and duplicate/conflicting identity values before resuming.
- `Out-File` and `Set-Content` encoding defaults in Windows PowerShell 5.1 are easy to misuse. Explicitly choose the runtime log encoding, and use a writer that can produce the project's required no-BOM form. Do not assume `-Encoding UTF8` has the same behavior in PowerShell 5.1 and newer PowerShell.
- Committed text must remain ASCII and without a BOM. A runtime log or metadata file may need UTF-8 for real paths, but its encoding must be explicit and tested separately from committed source.
- `Move-Item` and overwrite behavior vary by provider and may not provide an atomic replace with the expected collision semantics. Use same-directory temporary files, explicit existence checks, and a tested .NET file operation for the state snapshot.
- `FileSystemWatcher` can drop or coalesce events and cannot prove that a vendor recovery is complete. Use it only as a hint; re-read state and revalidate identity/capacity before decisions.
- `Get-CimInstance` association queries can be slow, incomplete, or different for dynamic disks, Storage Spaces, RAID, and VHDs. Log the exact association result and block when the full physical set is not known.
- `Get-PhysicalDisk` describes physical disks in a Storage Spaces context and is not automatically a complete replacement for volume-to-partition-to-disk mapping.
- Local time and localized output are unsafe for audit correlation. Store UTC timestamps in an invariant, round-trippable format and store stable numeric/ID properties rather than localized display strings.
- `Read-Host` and GUI input need explicit validation for empty, ambiguous, and cancel results. Blank confirmation must choose the safe path.
- Elevation through `Start-Process -Verb RunAs` can lose the working directory, argument quoting, and job context. Pass an explicit job identity and re-run preflight after elevation.
- Hard termination skips `finally` blocks. Use an exclusive lock with a recorded owner/lease and a deliberate stale-lock gate; do not assume lock cleanup always ran.
- Client names and paths can contain Unicode, quotes, trailing dots/spaces, reserved device names, and invalid filename characters. Use deterministic sanitization plus a job ID, never string concatenation into a shell command, and never silently merge two sanitized names.
- `Join-Path` and path normalization do not by themselves resolve reparse points or prove that a path remains under a root. Compare canonical final paths and reject unresolved redirects.

## 15. Primary references and manual boundary

Repository sources:

- `AGENTS.md`
- `README.md`
- `docs/WORKFLOW.md`
- `docs/RESEARCH-INDEX.md`

Microsoft references for implementation review:

- Windows PowerShell 5.1 overview: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_5.1?view=powershell-5.1
- `Get-Disk`: https://learn.microsoft.com/en-us/powershell/module/storage/get-disk?view=windowsserver2025-ps
- `Get-Partition`: https://learn.microsoft.com/en-us/powershell/module/storage/get-partition?view=windowsserver2025-ps
- `Get-Volume`: https://learn.microsoft.com/en-us/powershell/module/storage/get-volume?view=windowsserver2025-ps
- `DriveInfo.AvailableFreeSpace`: https://learn.microsoft.com/en-us/dotnet/api/system.io.driveinfo.availablefreespace?view=netframework-4.8.1
- `DriveInfo.TotalFreeSpace`: https://learn.microsoft.com/en-us/dotnet/api/system.io.driveinfo.totalfreespace?view=netframework-4.8.1
- `Start-Process`: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1

Vendor references are discovery starting points, not automation evidence:

- File Scavenger product page: https://www.quetek.com/prod02.htm
- R-Studio product page: https://www.r-studio.com/data-recovery-software/
- R-Studio scan help: https://www.r-studio.com/Unformat_Help/discscan.html

The implementation must add a direct vendor manual URL or a reproducible installed-version observation before claiming any File Scavenger control, switch, close mechanism, or completion signal. Until then, File Scavenger scan/recovery/close actions and R-Studio analysis remain explicit manual gates. Only the launch-only handoff permitted by `docs/WORKFLOW.md` may be automated without further vendor evidence.
