# Live Validation Checklist (owner / technician only)

Status: owner-live gate record for the v1 workflow
Scope: licensed vendor behavior, real hardware, real media, and the end-to-end case
Owner: the technician who runs the case. Not a CI artifact.

CI and synthetic tests prove only deterministic behavior: text encodings, AST safety
contracts, provider-seam decisions, state/log/transition rules, and launcher text.
They do not prove anything about the vendor applications. Nothing in this file may be
recorded as passed on the strength of a CI run, a synthetic UI fixture, a recorded
process runner, or a passing dry run.

Every row is answered with one of:

- PASS - observed on the exact build recorded below, with evidence stored in the case.
- FAIL - observed behavior differs from the requirement in AGENTS.md, docs/WORKFLOW.md,
  or docs/IMPLEMENTATION-SPEC.md.
- SKIP - prerequisite missing (no license, no second physical disk, no write blocker,
  no test media). A SKIP leaves the gate open. A SKIP is never a pass.

Never commit credentials, license keys, activation data, or recovered content. Store
the raw evidence in the case folder and reference it in this record by path.

## 0. Case record header

Fill this before starting. The build fields are what the checklist is bound to; a
different build invalidates every PASS recorded here.

    Date (UTC):
    Technician / owner:
    Machine (make/model, host name):
    Windows edition and build (winver, full string):
    Windows PowerShell version ($PSVersionTable.PSVersion):
    Elevation of the technician account (yes/no, evidence):
    Source device (model, capacity, interface):
    Source write blocker or hardware read-only method:
    Destination physical disk (model, capacity, interface):
    Disposable test data set used (describe; never production data):
    Workflow revision in the checkout (git commit or file hash of the tree):
    Case job id and job folder path:

Vendor identity (both products, both required):

    File Scavenger executable path:
    File Scavenger product / file version:
    File Scavenger About version/build (Help > About, as displayed):
    File Scavenger license mode (demo / Standard / Premium / Professional / Company):
    File Scavenger language of the UI (as installed):
    R-Studio executable path:
    R-Studio product / file version:
    R-Studio About or version report (as displayed):
    R-Studio edition and license mode:
    R-Studio utility check (R-Studio for Windows, not Agent, not Emergency):
    Evidence source for each identity (explicit path, registry, operator-supplied):

Two product rules are absolute:

1. The build recorded here is the only build this record is valid for. A version that
   is not in the configured validated build list stays a manual gate in the workflow.
2. File Scavenger in demo mode saves only the first 64 kilobytes of each file. A demo
   run can look successful while the output is truncated, so it cannot establish
   end-to-end recovery success.

## 1. L-01 File Scavenger identity and source safety

- [ ] 1.1 Executable identity recorded from the file version resource and matched to
      Help > About on the running process.
- [ ] 1.2 Administrator requirement confirmed: the product runs only for an account
      with administrators privileges, and the workflow preflight reports it.
- [ ] 1.3 License mode recorded, including whether any advanced feature (RAID, virtual
      disk, advanced file system) is unavailable in this mode.
- [ ] 1.4 Source state captured before the case: volume identity, physical-disk
      identity, size, file system, and the read-only or write-blocker evidence.
- [ ] 1.5 Source state captured after the case and compared with 1.4. A changed byte,
      timestamp, or allocation count is a FAIL of the read-only contract.
      Evidence: image hash or filesystem-level comparison, plus write-blocker logs.
- [ ] 1.6 The workflow never supplies the vendor same-drive override. The vendor may
      present its own safety check with an "Overriding code" that requires typing
      "Yes". Record the prompt if it appears and confirm the workflow did not answer
      it and did not type anything into the product.
- [ ] 1.7 A software flag alone is not proof of write protection. Note explicitly
      whether a hardware write blocker was used.

## 2. L-02 File Scavenger UI surface and storage topology

UIA/MSAA evidence is required here, not a description from memory. Capture the raw
property dump for each control you claim is reachable (for example with the Windows
UI Automation inspection tool or the Accessibility Insights tree), and keep the file
in the case folder.

- [ ] 2.1 Main window readiness: the process is started, up, and the main window is
      present. Record the process path, PID, start time, and window title.
- [ ] 2.2 For each documented caption below, record whether it is exposed through a
      stable UIA/MSAA Name (or other property) on this exact build, plus the raw
      property dump and the control type:
      `Look in`, `Look for`, `Quick or Long scan`, `Scan`, `Pause`,
      `Step 2: Save`, `Save to`, `Use folder names`, `Save`, `Session`, `Load`,
      `Create a CSV file`, `Exit`, and the status labels `Progress`,
      `Scan status`, `Recovery status`.
- [ ] 2.3 Localization: confirm whether the exposed names follow the Windows UI
      language or the product language setting. A non-English host needs its own
      validated map; otherwise the workflow must stay on the manual gate.
- [ ] 2.4 If the documented captions are NOT exposed with stable properties, record
      that as the finding. That result keeps the File Scavenger surface manual and is
      a valid, useful outcome; it is not a failure of the checklist.
- [ ] 2.5 No coordinate clicking, no SendKeys, no guessed window class, and no raw key
      sequence was used at any point. Confirm by inspection of the case notes.
- [ ] 2.6 Folder picker: the workflow displays the Windows folder browser and returns
      the selected path. Record what the picker showed and the path it returned.
- [ ] 2.7 Source and destination physical identity as the workflow reported them:
      volume, partition, physical disk, and the identity fields used. Confirm the
      refusal decision text was correct for at least one deliberately bad destination
      (same physical disk, different volume) and one deliberately unknown case.
- [ ] 2.8 Mounted-folder, junction, and reparse-point paths: record how the workflow
      resolved or refused each one.

## 3. L-03 File Scavenger stage evidence (Quick, Step 2: Save, Long)

The vendor documents Quick scan and Long scan as distinct modes and separates the
scan step from `Step 2: Save`. Scan completion and recovery completion are different
events and must be recorded separately.

- [ ] 3.1 Quick scan run with an explicit technician choice; the source, mode, and
      `Look for` criteria recorded exactly as entered.
- [ ] 3.2 Scan-finished evidence recorded. State clearly which signal was used:
      the status panel, the vendor's own status label or value, the operator's
      confirmation, or a combination. A displayed 100 percent, a process exit, or a
      vanished window is not, by itself, scan completion.
- [ ] 3.3 `Step 2: Save` performed with `Save to` pointing at the validated case
      folder on the destination disk, `Use folder names` decision recorded, and
      `Save` started.
- [ ] 3.4 Recovery-finished evidence recorded separately from 3.2, with the same
      naming of the signals used.
- [ ] 3.5 Output observed after recovery: folder and file inventory, total bytes,
      and per-file status values as displayed. Record the status vocabulary exactly
      (`Good` / `Poor` after scan; `Saved` / `Failed` / `Skipped` after recovery).
- [ ] 3.6 Recovered content validated independently: open a sample of recovered files
      and record what was compared. The vendor does not guarantee intact content, so
      a `Saved` status is not proof of usable output.
- [ ] 3.7 `Recovery.log` in the `Save to` folder: record the exact file name,
      location, rotation behavior if any, and format, plus whether it is written for
      a scan-only run or only when files are saved. If the file is absent or differs
      from the documentation, record that.
- [ ] 3.8 CSV export via `Create a CSV file`: record the exact column list and state
      explicitly whether per-file status columns are present.
- [ ] 3.9 Session file `File Scavenger Session (*.fss)`: perform a Session Save,
      record the path, then load it and record whether the file list returns without a
      rescan. Confirm the session file is not on the source disk.
- [ ] 3.10 Long scan performed only after the short recovery result was verified.
      Record the fresh identity and capacity checks that preceded it.
- [ ] 3.11 Long-scan journal: record whether journaling was used, the exact folder
      chosen, that it is not on the source disk, and that each scanned drive uses its
      own folder.
- [ ] 3.12 Pause and resume: pause a running scan or save, resume it, and record what
      the status panel showed at each step.
- [ ] 3.13 Long-scan pause plus session save plus reboot plus resume: record whether
      the combined sequence works, or record it as unknown. Do not promote an
      undocumented combination to a supported contract.
- [ ] 3.14 Any behavior not observed stays unknown. Unknowns do not become
      assumptions in code; they stay manual gates.

## 4. L-04 File Scavenger prompts and close

- [ ] 4.1 `Pause` behavior on a running scan and on a running save, recorded.
- [ ] 4.2 `File > Exit` after the technician confirms all work is finished. Record
      whether a confirmation prompt appeared (the close confirmation observed in the
      build strings is "Close File Scavenger?") and how it was answered.
- [ ] 4.3 Post-close verification: the product process is gone, and any helper or
      child process is also gone or accounted for. Record how long termination took.
- [ ] 4.4 Force close refusal: with a scan or recovery running, or with unknown
      application state, confirm the workflow refuses to force close and says so.
- [ ] 4.5 Force close after verified recovery only: record the confirmation text the
      workflow required, the job-bound process identity check, and the post-close
      verification event that was logged.
- [ ] 4.6 Overwrite mode: cause a name conflict in the destination and record the
      prompt. Confirm the workflow never selects `Overwrite`, never selects `Skip`,
      and never persists "do not ask this question again".
- [ ] 4.7 Scan-journal overwrite prompt ("A scan journal already exists in the
      folder. Do you want to overwrite it?") recorded, with confirmation that the
      workflow did not answer it.
- [ ] 4.8 The `Macros - Experimental.` menu was not used and no macro file was
      authored, shipped, or loaded. The macro path stays unsupported.

## 5. L-07 Media, capacity, and resume faults

- [ ] 5.1 Destination removed during work: the workflow paused or stopped, preserved
      all output already written, logged the loss, and did not redirect to another
      path. Record the event type and message.
- [ ] 5.2 Destination restored: the same device was reattached and revalidated before
      resume. Record the identity comparison.
- [ ] 5.3 A DIFFERENT device attached at the same drive letter: the workflow refused
      to treat it as the same destination. Record the refusal reason code.
- [ ] 5.4 Low space: induce it, then record the measured available value, the
      configured reserve, the recorded event, that already-written output was kept,
      and that the workflow did not switch destination.
- [ ] 5.5 Capacity query failure or unavailable value: record that the workflow
      treated it as unknown and blocked output work rather than substituting zero.
- [ ] 5.6 Source disconnected during work: record the pause or stop, and that no
      vendor action was started afterwards.
- [ ] 5.7 Interrupted run: kill the workflow process (not the vendor product) mid
      stage, then restart. Record the state found on resume, the decision returned
      (`ResumeNext`, `NeedsReview`, `FailedClosed`), and that no verified stage was
      rerun silently.
- [ ] 5.8 Output present without verification: record that the output was preserved
      and that the offered choices were inspect, retry with a new attempt ID, or
      abort. Confirm nothing was deleted or overwritten to make a retry convenient.
- [ ] 5.9 Concurrent execution: start the same job twice and record that the second
      attempt was blocked by the lock. Do not delete a stale lock automatically; a
      stale lock is a gate.
- [ ] 5.10 Destination on the same physical disk as the source (different volume):
      record the refusal and the reason code (`SameVolume` or `SamePhysicalDisk`),
      and confirm no vendor write action was attempted.
- [ ] 5.11 Real removable media: record the physical identity of the source and the
      destination as the workflow resolved them from live hardware.

## 6. L-11 R-Studio launch-only handoff

- [ ] 6.1 Product identity confirmed as R-Studio for Windows, not the Agent and not
      the Emergency utility. Portable copies need the same explicit path and identity
      check.
- [ ] 6.2 Launch arguments recorded exactly as they reached the process: `-safe`, and
      `-log <filename>` only when the case log path is on a safe, writable,
      non-source location. No other switch, no client folder, no project, no report,
      no scan or recovery argument, no window-activation argument.
- [ ] 6.3 Log path failure: point `-log` at an unsafe or unwritable path and record
      that the workflow blocked with no launch instead of retrying another path.
- [ ] 6.4 `-safe` startup behavior recorded: automatic partition search and file
      system recognition are suppressed and `Find partition` must be used manually.
      Note that `-safe` is not a general write-protection guarantee.
- [ ] 6.5 Main panel readiness recorded (process path, PID, start time, window or
      panel evidence). Confirm that launching alone performed no source selection,
      partition search, scan, file marking, recovery, destination selection, or
      analysis.
- [ ] 6.6 Separate Explorer action: open the already validated client folder from the
      workflow panel. Confirm the folder was not passed to R-Studio and that opening
      it did not start or enable any recovery action.
- [ ] 6.7 Handoff panel actions recorded: Close, Copy client name, Open client folder.
      Confirm no action started a scan or a recovery.
- [ ] 6.8 Write-capable controls confirmed untouched: no `Enable Write`, no
      text/hexadecimal editor write, no wipe, no repair, no partition change, no
      automatic analysis.

## 7. Environment and release-level checks (at least once per release)

- [ ] 7.1 True double-click path: launch by double-clicking `Start-Recovery.bat` from
      Explorer, from a different working directory, and from a path containing spaces.
      Record the console output and the exit code the batch file returned.
- [ ] 7.2 No-pause behavior: record whether the closing prompt waits for a keypress
      in a normal console and whether a redirected console returns without waiting.
- [ ] 7.3 Non-admin behavior: record the preflight message when the technician
      account is not elevated, and confirm no vendor process was started.
- [ ] 7.4 Localized host: record the behavior of every manual gate on a non-English
      Windows install.
- [ ] 7.5 Missing or ambiguous prerequisites: record the gate text for a missing
      File Scavenger, a missing R-Studio, two valid candidates, and a build that is
      not in the validated list.
- [ ] 7.6 Crash and resume across a real case: record the state, log, and lock state
      after an unexpected shutdown.
- [ ] 7.7 Output collision across two runs of the same client name: record that the
      second job claimed a new suffix folder and that the first job's bytes were
      unchanged.
- [ ] 7.8 Case evidence reviewed: the job folder contains the claim marker, the lock
      file, the state snapshot, the append-only event log, and the recorded vendor
      outputs, and the log shows the start event before, and the finish or
      verification event after, every external action.

## 8. Sign-off

    Every PASS above is bound to the build recorded in section 0.
    Every SKIP leaves an open gate and is listed here with its reason:

    Skipped item / reason:
    Skipped item / reason:

    Open unknowns carried forward (do not convert them into assumptions):

    Technician signature / date:
    Reviewer signature / date:

CI status is intentionally not part of this record. A green CI run says nothing about
the vendor behavior, the hardware, the media, or the source write protection recorded
above, and it must never be used to close an open gate in this checklist.
