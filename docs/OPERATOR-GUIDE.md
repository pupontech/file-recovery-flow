# Technician Operator Guide

Audience: a repair or data-recovery technician running one case on a Windows machine.
This guide describes what the tool does, what it refuses to do, and what it expects
you to do by hand in File Scavenger and R-Studio.

Two documents sit beside this one:

- `docs/IMPLEMENTATION-SPEC.md` - the normative contract (states, gates, reason codes).
- `docs/LIVE-VALIDATION.md` - the owner-live record you must complete on a real case
  before production use. CI cannot prove vendor behavior; only that record can.

## 1. What this tool is

The workflow prepares a non-destructive recovery case, proves that the destination is
not on the source physical disk, records durable evidence, launches the verified
vendor applications, and gates every vendor operation it cannot prove. It is
launch-and-record, not unattended recovery. You perform the scans and the recovery in
the vendor GUI.

Hard rules that no configuration can weaken:

- The source is read-only. The tool never formats, initializes, repairs, runs CHKDSK,
  changes partitions or partition tables, deletes files, or overwrites an existing job.
- A destination on the same physical disk as the source is refused, including a
  different volume, letter, or mount point on that disk.
- When identity is unknown or contradictory, the tool stops. It never guesses and
  never redirects output to another path.
- No File Scavenger command-line switch, macro, or control name is invented. Where no
  exact-build evidence exists, you get a named manual gate instead.

## 2. Prerequisites

- Windows with Windows PowerShell 5.1 (`powershell.exe`). PowerShell 7 is not the
  supported runtime for the workflow.
- An account with administrators privileges. Both vendor products require it.
- A licensed File Scavenger install or portable copy, and a licensed R-Studio for
  Windows install or portable copy. Record both versions before the case:
  File Scavenger `Help > About`; the R-Studio version display.
- Demo or trial licensing is not acceptable for a real case. File Scavenger demo mode
  saves only the first 64 kilobytes of each file, so a run can look successful while
  the output is truncated.
- A destination physical disk that is not the source disk, with enough free space for
  the expected output plus the configured reserve.
- A hardware write blocker (or equivalent read-only method) for the source where the
  case allows it. A software flag alone is not proof of write protection.
- The client name you intend to use. It is sanitized into a folder name; see section 6.

### 2.1 Verify the checkout before you start

`Start-Recovery.bat` is only a launcher. It runs `RecoveryAutomation.ps1` from the same
folder. Confirm that the following are present next to the batch file:

    Start-Recovery.bat        thin launcher (thin: it starts one script and nothing else)
    RecoveryAutomation.ps1    workflow entry point
    config.json               configuration (points at the vendor executables and policy)
    modules\                  workflow modules imported by the entry point
    docs\                     this guide, the spec, the live checklist

If the entry point or the modules folder is missing, the launcher can only fail. Do not
compensate by driving the vendor applications by hand and calling it a workflow run -
that produces no case evidence and bypasses every safety check. Fix the checkout or
stop.

### 2.2 Configuration

The workflow reads one JSON configuration file (schema version 1). The normal file is
`config.json` next to the launcher; `-ConfigPath` selects another one. An unknown key,
an unknown schema version, a malformed path, and a conflicting safety setting are
errors, not warnings.

| Field | Required | What you set it to |
| --- | --- | --- |
| `SchemaVersion` | Yes | `1`. Anything else stops the run. |
| `WorkflowVersion` | Yes | The workflow revision string recorded in the case state and log. |
| `FileScavengerPath` | No | The explicit File Scavenger executable path. With no value, discovery must produce exactly one verified candidate or you get a gate. |
| `RStudioPath` | No | The explicit R-Studio for Windows executable path. It is never interpreted as an Agent or Emergency utility. |
| `ValidatedFileScavengerBuilds` | Yes | Builds you have validated on a live case. Empty means every File Scavenger UI action stays a manual gate. A download URL is not a validated build. |
| `ValidatedRStudioBuilds` | Yes | Same rule for R-Studio. Empty means the handoff is offered only as a manual identity gate. |
| `DestinationRoot` | No | The destination root. It is still resolved and separated from the source before use. |
| `CapacityReserveBytes` | Yes | Your free-space reserve. An unavailable capacity reading is treated as unknown and blocks output work. |
| `MaxJobPathLength` | No | Defaults to the 200-character design budget. Lower is allowed; higher is not a fix for a long path. |
| `ClientName` | No | Never used unsanitized in a path or a command. |
| `NoPause` | No | Controls only the launcher closing prompt, never a safety gate. |
| `AllowSameDiskOverride` | No | Must be `false`. `true` is a configuration error. |
| `AllowVendorOverwrite` | No | Must be `false`. `true` is a configuration error. |
| `AllowForceClose` | No | Defaults to `false` and cannot bypass the state and confirmation guards. |

Defaults are fail-closed: no source, destination, vendor path, validated build, or
automation map is assumed. Never put license keys, credentials, or recovered content in
the configuration file or anywhere else in the repository.

## 3. Start the workflow

Double-click `Start-Recovery.bat`. That is the normal path.

What the launcher does (it does nothing else):

1. Resolves its own folder with `%~dp0`, so the current directory does not matter.
2. Passes every argument you give it straight through to the entry point.
3. Runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <folder>\RecoveryAutomation.ps1`
   with those arguments. Windows PowerShell 5.1 is requested explicitly; the entry
   point self-elevates through UAC when needed, waits for the elevated child, and
   propagates its exit code.
4. Keeps the console open at the end so you can read the result, unless you suppress
   the closing prompt with `-NoPause` or by setting `RECOVERY_NO_PAUSE=1`.
5. Returns the entry point's exit code unchanged through `exit /b`.

Read the console before you close it. The launcher contains no storage, copy, or delete
command; every safety check lives in the entry point.

Reading the result:

- A non-zero exit code means the workflow stopped. Preflight and configuration
  failures, including a missing or invalid `config.json` and a missing module, return
  a non-zero code before any vendor process starts. The console text and the job event
  log say why.
- Exit code 0 means the script completed its ordered steps. It is not proof that a scan
  or a recovery succeeded. Only the recorded stage evidence and your own output review
  prove that.
- A pause or a stop is a normal, successful outcome of a safety check. It is not a bug
  in the case. Do not improvise a workaround, and do not answer a gate you do not
  understand.

Entry point arguments: `Start-Recovery.bat` forwards everything it receives, so the
supported switches are exactly the parameters declared in `RecoveryAutomation.ps1`.
The launcher's own argument handling recognises only `-NoPause`, and it does not
consume anything else. Read the entry point's param block in your checkout before you
script the launcher. The switches the workflow and its CI lanes use are:

| Argument | Effect |
| --- | --- |
| `-ConfigPath <path>` | Use an explicit configuration file instead of the default one. |
| `-NoPause` | Suppress the launcher's closing prompt. Equivalent to `RECOVERY_NO_PAUSE=1`. |
| `-DryRun` | Bounded diagnostic path used by CI: it validates and reports without starting a vendor process and without touching real recovery media. It is not a way to skip a safety check in a real case. |

Running the batch file with no arguments is always valid and is the normal case.

## 4. What the workflow asks you for, in order

1. Preflight: runtime, configuration, elevation, and discovery of File Scavenger and
   R-Studio, without launching either product. Missing, ambiguous, or unexpected
   products become a gate.
2. Source selection. You name the source; the tool resolves its canonical path, volume,
   partition, complete physical-disk set, and identity snapshot. Record the
   read-only or write-blocker evidence.
3. Destination selection through the Windows folder browser (or a typed path through
   the same checks). The tool resolves the destination the same way and compares the
   full physical-disk sets.
4. Client name, path budget, and case creation: a uniquely claimed job folder, the
   lock, the metadata, and the flushed event log. No vendor process starts before the
   case is durable.
5. Revalidation, then the File Scavenger launch and the manual gate that follows it.
6. Quick scan, `Step 2: Save`, and verification as separate recorded steps.
7. Optional Long scan, only after the short recovery result is verified.
8. Graceful close, then the launch-only R-Studio handoff.

Every step is fail-closed. A failure at any step leaves the case state and the log
durable and prevents later work.

## 5. Source and destination

### 5.1 Source

The source is the drive you are recovering from. Treat it as read-only for the whole
case: no writes, no repairs, no defragmentation, no drive-letter changes. If you need
the disk attached to another machine, keep the blocker in place.

### 5.2 Destination

Pick a folder on a different physical disk. The Windows folder browser returns the
path; the tool then resolves the real target (reparse points, ancestors, volume,
partition, backing disks) and decides.

Refusals, in the order the tool applies them:

| Reason code | Meaning | What you do |
| --- | --- | --- |
| `DestinationPathInvalid` | The path text is not a usable absolute path. | Reselect a real folder. |
| `DestinationUnresolved` | The path or its volume cannot be resolved (missing container, unreachable share, unresolved reparse target). | Attach the media and reselect. |
| `SourceIndeterminate` | The source's physical-disk set cannot be proven. | Reattach the source or use a topology the tool can prove; do not force it. |
| `DestinationIndeterminate` | The destination's backing disks cannot be proven (dynamic disk, Storage Spaces, file-backed virtual, VHD, network, incomplete member set). | Choose a plain local disk. |
| `SameVolume` | Source and destination resolve to the same volume. | Choose another volume. |
| `SamePhysicalDisk` | Source and destination share any backing physical disk, even at different volumes or mount points. | Choose another physical disk. |

Notes that matter in practice:

- Disk numbers are session labels, not identity. The tool compares strong identity
  fields (unique disk id, or serial number plus size plus model). Reusing a drive
  letter, or the same disk number after a change, does not prove anything.
- An unknown mapping is a refusal, never an allowance.
- There is no supported override. `AllowSameDiskOverride` must always be false, and a
  configuration that sets it is an error. Never type the vendor's same-drive
  "Overriding code" `Yes` either: that is an operator-only decision outside this
  workflow, and the vendor describes it as a risk of permanent data loss.
- The refusal applies to every path the workflow writes: metadata, lock, event log,
  session, journal, and recovered output.

## 6. Client name and job folder

The client name becomes a folder name, so it is sanitized deterministically:

- Allowed characters are `A-Z a-z 0-9 . _ -`. Anything else becomes `_`.
- Trailing spaces and periods are trimmed.
- Reserved Windows device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`,
  `LPT1`-`LPT9`) are rejected.
- An empty or unusable name is rejected.
- More than 40 characters is truncated, with a visible warning. It is never silently
  cut in the middle of the composed path.

The job folder is claimed under the destination root as `<client>-001`, then `-002`
through `-099` on collision. Claiming uses a create-new operation on a claim marker, so
an existing folder is never reused, merged, or deleted. If every suffix is taken, the
workflow stops and asks for another root. Directory creation alone is not treated as a
collision guard.

The composed job path must stay below the configured budget (200 characters by
default). An over-budget path stops the case; it is never truncated silently.

## 7. Job folder contents

Treat the job folder as the case record:

| Item | Role | Rule |
| --- | --- | --- |
| `job-claim.json` | Claim marker that proves this folder was created by this job. | Immutable. Never edit or copy it into another case. |
| `job.lock` | Exclusive job lock. | If it looks stale, that is a gate, not an invitation to delete it. |
| State snapshot (JSON) | Current state, stage, attempt, identity snapshots, gates. | Written atomically, UTF-8 without a BOM, confined to this job folder. Never hand-edit it. |
| Event log (JSONL) | Append-only history: one record per event with a monotonic sequence and a UTC timestamp. | Never truncate, reorder, or rewrite it. The entry point flushes it before and after every external action. |
| Vendor outputs, session, journal | Recovered files, session file, scan journal. | Only ever on the validated non-source destination. Never delete partial output to make a retry convenient. |

The workflow records both a state snapshot and an event history; the snapshot never
replaces the history. It contains no credentials, no license keys, and no unnecessary
recovered-content data. Keep licenses and keys out of the case folder entirely.

The claim marker and the lock file use the fixed names above. The entry point names the
state snapshot and the event log; read the paths it reports in the console, or list the
job folder, rather than assuming a file name.

## 8. The File Scavenger stage boundary (you drive the product)

The workflow launches File Scavenger and hands you the gate. The documented GUI words
below are the ones you will see; internal state names map to them, so the log may say
`SHORT_*` for the vendor's `Quick scan`.

Sequence for a normal case:

1. `Look in` - select the source volume or disk the workflow validated. If the
   destination disk is visible here, something is wrong; stop.
2. `Look for` - enter your criteria (extension, name, `*`, comma-separated patterns,
   exclusions).
3. `Quick or Long scan` - choose `Quick scan` first. Quick scan uses the file system
   structure and is the documented first step for accidental deletion and broken
   spans. `Long scan` reads every sector and is for reformatted, repartitioned, or
   corrupted drives.
4. `Scan` - start it. Then wait. The status panel shows progress, scan status, and
   messages.
5. `Step 2: Save` - only after the scan finishes. Select the files or folders to
   recover. Set `Save to` to the case folder on the validated destination. Decide
   `Use folder names` explicitly. Then `Save`.

Boundary rules:

- Scan completion and recovery completion are different events. A finished scan is not
  finished recovery, and neither one advances the workflow by itself.
- `Step 2: Save` output goes to a folder on the validated non-source destination. The
  workflow re-validates the destination immediately before each output stage.
- Per-file status is `Good` or `Poor` after the scan and `Saved`, `Failed`, or `Skipped`
  after recovery. The vendor does not guarantee intact content, so open a sample of the
  recovered files before you report success to anyone.
- File Scavenger writes `Recovery.log` into the `Save to` folder while it saves. Treat
  its exact name, rotation, and format as build-specific until you record them in
  `docs/LIVE-VALIDATION.md`.
- A `Long scan` is only offered after the short recovery result is verified. Quick is
  never silently switched to Long, and the long stage repeats the fresh identity and
  capacity checks.
- `Pause` suspends a running scan or save and lets you resume or abort. Use it instead
  of killing the process.

Never do these while the workflow is running (each is a stop/manual gate, not a
convenience):

- Never type `Yes` into the same-drive safety `Overriding code`.
- Never choose the vendor `Overwrite` mode, and never persist "do not ask this
  question again".
- Never answer the scan-journal overwrite prompt silently.
- Never use the `Macros - Experimental.` menu, and never author or load macro files.
  The macro surface is undocumented and unsupported by this workflow.
- Never change the destination to "somewhere that has room". Missing space is a pause,
  and the workflow never redirects output.

## 9. Graceful close and force close

- Close gracefully with `File > Exit` after you confirm scanning and saving are
  finished. A confirmation prompt ("Close File Scavenger?") may appear; answer it
  yourself and confirm the process and any helper processes are gone.
- Force close is a guarded last resort and only after recovery is verified finished.
  The workflow refuses force close during a scan, during recovery, or while the
  application state is unknown. The guards are: verified recovery completion, a
  process identity bound to this job, an explicit confirmation from you, and a logged
  post-close verification.
- If the guard refuses, leave the active state untouched, stop, and record the
  situation. A force close during active or unknown work can corrupt output that was
  otherwise recoverable.

## 10. R-Studio handoff (launch only)

When the File Scavenger work, the close, and the final identity checks are done, the
workflow sets the case to ready for handoff and launches the verified R-Studio for
Windows executable with exactly one argument: `-safe`. It adds `-log <filename>` only
when a case log path on a safe, writable, non-source location is configured.

- `-safe` suppresses automatic partition search and file system recognition. You must
  then use `Find partition` manually. It is not a general write-protection guarantee.
- Do not expect the workflow to pass a folder, project, scan, report, or window
  argument. No such argument is documented by the vendor and none is used.
- Confirm the executable is R-Studio for Windows, not R-Studio Agent and not R-Studio
  Emergency. Portable copies need the same explicit path and identity check.
- The workflow stops at the R-Studio main panel. Everything after that is yours:
  source selection, partition search, scan, file marking, recovery, destination
  choice, and any analysis.
- The client folder can be opened in Explorer from the workflow panel as a separate
  action. That is a shell action, not an R-Studio argument, and it starts no recovery.
- Never enable `Enable Write`, editor writes, wipe, repair, or partition changes in
  this workflow. Those are outside its boundary.

The handoff panel shows the client name prominently and offers exactly three actions:
Close, Copy client name, and Open client folder. None of them starts a scan or a
recovery.

## 11. Stopping, pausing, and resuming

- Pause or stop is always safe. Output already written is preserved. Nothing is
  deleted to make room or to simplify a retry.
- Resume acquires the exclusive lock, validates the state, the log sequence, the
  identity of the source and the destination, the capacity, and the application build,
  and then compares everything against the recorded case.
- Resume continues only from a verified stage to its next stage. A verified stage is
  never rerun silently. Rerunning one requires your explicit decision, a new attempt
  ID, and the recorded reason.
- An open attempt, a missing final event, a lost process, or any contradiction is
  converted to `INTERRUPTED_UNKNOWN`, which is a review gate. It is neither a success
  nor an automatic retry.
- If output exists without verification, it is preserved. You choose: inspect it,
  retry with a new attempt, or abort.
- State that is corrupt, copied, stale, or identity-mismatched ends in `FAILED_CLOSED`.
  Start a new case. Do not hand-edit the state to continue.

## 12. Low space, destination loss, and media faults

- Low space: the workflow uses the conservative available value, treats an unavailable
  value as unknown (never as zero), and pauses or stops below the configured reserve.
  It preserves partial output, records the measured value, and does not move the
  destination.
- Destination loss (removed media, access denied, I/O error, changed identity): the
  workflow treats it as loss until proven otherwise, pauses, and does not convert a
  missing path into an empty folder or a new drive letter.
- Reattaching media: the device must match the recorded destination identity. A
  different device at the same path is a new destination and cannot resume the old
  job.
- Source loss: stop. Do not start a vendor action until the source identity is proven
  again and the checks are fresh.

## 13. Deliberately unsupported

These are out of scope by design. None of them is a missing feature to work around by
hand while claiming a workflow run:

- Any File Scavenger command line, batch mode, project or config file, silent or
  unattended mode, API/SDK, exit-code contract, or status query. None is documented by
  the vendor, so none is used or invented.
- File Scavenger macros (`Macros - Experimental.`) and macro files.
- Screen-coordinate clicking, `SendKeys`, or guessed control names for either vendor
  application. The workflow uses documented interfaces, UI Automation on a
  live-validated exact build, or a manual gate.
- Selecting vendor `Overwrite` mode, persisting "do not ask again", or answering the
  same-drive override or the journal overwrite prompt.
- R-Studio Agent, R-Studio Emergency, and any Posit RStudio product. The handoff is
  R-Studio for Windows only.
- Automatic R-Studio analysis, scanning, marking, recovery, destination selection, and
  every write-capable R-Studio feature.
- Network shares, dynamic disks, Storage Spaces, file-backed virtual disks, VHDs, and
  spanning or incomplete topologies as destinations. The mapping is indeterminate, so
  the case is refused rather than guessed.
- CD/DVD destinations (the vendor stages these through the boot drive).
- Any form of write, repair, or cleanup on the source: format, initialize, CHKDSK,
  partition or partition-table changes, file deletion.
- Overwriting an existing job folder, and deleting recovered or partial output.
- Using the CI pipelines as evidence of vendor behavior. Synthetic and CI tests prove
  the deterministic safety layer only.

## 14. Case evidence to keep

Keep, in the job folder: the claim marker, the lock file's final state, the state
snapshot, the append-only event log, the vendor outputs, the session file and journal
if used, and your notes from sections 1 to 7 of `docs/LIVE-VALIDATION.md`. Add
screenshots or property dumps where the live checklist asks for them.

Never keep credentials, license keys, activation data, or recovered content in the
repository. The case folder is evidence; the repository is source.

## 15. When something stops

1. Read the gate: it names the gate ID, the trigger, the evidence, the exact scope, the
   choices, and the safe default.
2. Choose the safe default unless you can supply the missing evidence.
3. Do not continue past a failed safety check, do not reselect the destination to a
   path you have not validated, and do not force-close a vendor application to make the
   script return.
4. Record what you did in the case notes, so the next technician and the owner-live
   record can see it.
