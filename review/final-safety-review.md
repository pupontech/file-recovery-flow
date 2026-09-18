Final safety/integration review

Scope

Fresh-eyes source review of the PowerShell entry point and all modules, with the implementation specification, operator guide, workflow contract, live-validation checklist, research index, and unit/integration/live/static test files read for cross-checking. This review is evidence-based from the source; no vendor application or real recovery media was exercised. The review is timeboxed per the operator note. Only this review artifact is written.

Release decision

BLOCKED. The implementation has several fail-open paths and the normal entry point cannot reach the R-Studio handoff or the later File Scavenger states. A green synthetic test run would not close these findings because the affected paths are provider/refusal/error combinations that the current tests do not cover, and live vendor behavior remains an owner gate.

Blockers (fix before merge or release)

1. BLOCKER - The normal workflow dead-ends immediately after launching File Scavenger; the R-Studio handoff is unreachable.

Evidence:
- `RecoveryAutomation.ps1:1033-1076` launches File Scavenger, records `SHORT_SCAN_RUNNING`, presents G-04, and returns. There is no call from `Invoke-RecoveryAutomation` to `Request-FileScavengerStage`, `Test-FileScavengerCompletion`, either close function, or `Invoke-RecoveryAutomationHandoff`.
- `RecoveryAutomation.ps1:500-610` defines the handoff helper, but source search finds only its definition and a test call; the production workflow never invokes it.
- The state table in `JobState.psm1:74-119` contains the later states, but no production driver advances through them.

Impact: pressing Continue at G-04 does not continue a workflow; it returns success while the case remains in `SHORT_SCAN_RUNNING`. The documented short recovery, long scan, close, final checks, and R-Studio handoff cannot be performed through the entry point, and the case cannot reach a verified handoff state.

Concrete fix: implement a durable operator/resume command path that loads and validates the locked case, records each gate and boundary event, performs fresh identity/capacity/read-only checks before every vendor write stage, and advances only through the existing legal transitions. Alternatively, explicitly narrow the product contract to launch-only and remove claims that the entry point performs the full workflow; do not report the current launch-only return as completion of the workflow.

2. BLOCKER - File Scavenger launch is authorized and executed before its launch event is written; a missing event writer is treated as success.

Evidence:
- `modules/FileScavenger.psm1:330-350` returns `Succeeded = $true` when `EventWriter` is null.
- `modules/FileScavenger.psm1:397-410` invokes the process runner before any `StageStarted` event.
- `modules/FileScavenger.psm1:479-490` writes the launch event only after the process has started. If that write fails, the function returns `Started = $false` even though the vendor process may still be running.

Impact: the required audit record is not durable before the external action. A log failure leaves an untracked vendor process and the caller can neither safely resume nor know whether a second launch would duplicate work.

Concrete fix: require a durable event writer; write and flush a launch-authorization/`StageStarted` event before invoking the process runner, then record the returned PID/path/start time in a second flushed event. If the post-launch event fails, mark the case `INTERRUPTED_UNKNOWN`/failed-closed and retain the process identity; never return a clean launch failure that hides a running process.

3. BLOCKER - Structured append/flush refusals from the default log writer are ignored.

Evidence:
- `modules/RecoveryLogging.psm1:52-61` marks the provider call successful unless the provider throws or returns the literal Boolean `$false`.
- The default provider explicitly returns objects with `Success = $false` on append/flush errors at `modules/RecoveryLogging.psm1:164-195`.
- `modules/RecoveryLogging.psm1:466-480` checks only the outer wrapper's `append.Success` and `flush.Success`; it never checks `append.Data.Success` or `flush.Data.Success`.

Impact: a disposed/unusable stream can return a structured refusal, yet the log writer advances its sequence and reports success. The workflow can therefore authorize later external actions without a durable event, directly violating the append-only log and fail-closed requirements.

Concrete fix: normalize every provider result to one explicit Boolean success value, requiring `Data.Success -eq $true` for structured results and rejecting missing/ambiguous success fields. Set `IsBlocked` on every append or flush refusal and make all callers stop before the next external action.

4. BLOCKER - State event sequence diverges from the actual log sequence, and resume does not detect the divergence.

Evidence:
- `RecoveryAutomation.ps1:978-980` writes three initial log events directly. They consume log sequences 1-3, but do not update `state.LastEventSequence`.
- `modules/JobState.psm1:650-705` creates the next state event from the stale state counter and advances the snapshot using that counter. The first state transition therefore claims sequence 1 while the log entry is sequence 4; the next claims 2 while the log entry is 5.
- `modules/JobState.psm1:479-522` reads only the shallow shape. It does not load/validate the event log, compare the expected last sequence, or check event/state consistency.

Impact: duplicate/mismatched event IDs and a snapshot that cannot identify the actual last durable event make resume decisions unreliable. A corrupted or partially advanced case can be treated as resumable without proving the log history.

Concrete fix: make the log writer's returned sequence the single source of truth and update the state snapshot with that exact sequence after each event. Before resume, validate the log with the job ID and expected last sequence, then verify the last event, state, stage, attempt, identity references, and gate decisions agree. Any mismatch must stop as `INTERRUPTED_UNKNOWN`/`NeedsReview`.

5. BLOCKER - The G-04 gate snapshot write is ignored and the function returns success anyway.

Evidence:
- `RecoveryAutomation.ps1:1058-1063` presents the gate, adds `GateDecisions`, and discards the result of `Write-RecoveryJobState`.
- `RecoveryAutomation.ps1:1064-1076` returns `Success = $true` and exit code 8 regardless of whether the gate decision or snapshot was durably written.

Impact: a state-durability failure is hidden after the vendor process has started. The operator can receive a successful result with no durable gate decision, while the case remains indistinguishable from an interrupted active attempt.

Concrete fix: check and propagate the snapshot result. Record `OperatorGatePresented` and `OperatorDecision` as flushed events, and refuse to return a successful handoff/paused result unless both events and the snapshot are durable. Validate the state writer before launch or transition to an explicit unknown state if post-launch persistence fails.

6. BLOCKER - Read-only/source protection is checked only once and is then dropped before launch.

Evidence:
- `RecoveryAutomation.ps1:767-778` performs the source-protection check only during initial source selection.
- The fresh pre-launch checks at `RecoveryAutomation.ps1:1008-1029` re-resolve source/destination identity and capacity but never re-run `SourceProtectionProvider`.
- `RecoveryAutomation.ps1:1027` replaces `state.SourceIdentity` with the fresh identity, which has no `ReadOnlyVerified`/`ReadOnlyEvidence` fields; `modules/FileScavenger.psm1:215-250` does not require source-protection evidence in launch preconditions.

Impact: source write protection can change between preflight and launch, or the persisted evidence can disappear, without blocking the vendor launch. A software flag or stale hardware state can therefore be mistaken for a read-only source.

Concrete fix: revalidate the source write blocker immediately before every vendor action, require explicit Boolean success plus evidence, preserve it on the fresh identity/state, and include it in `Test-FsLaunchPreconditions`. A missing, changed, or contradictory result must block/pause and be logged.

7. BLOCKER - Physical-disk overlap can be allowed when the two providers expose different strong identity forms.

Evidence:
- `modules/DiskDetection.psm1:133-154` chooses either a `UID|...` key or a `SER|...` key; it does not retain both comparable forms.
- `modules/DiskDetection.psm1:558-581` decides overlap solely by string intersection of those keys.

Impact: if the source snapshot has a unique ID but the destination snapshot for the same disk falls back to serial+size+model, the key strings differ and the destination can be allowed on the source physical disk. The same issue affects resume comparisons in `modules/JobState.psm1:168-205`.

Concrete fix: retain all available strong fields and compare identity structurally: matching unique ID/format, or matching serial+size+model, with contradictory fields and missing cross-provider evidence treated as indeterminate. Do not represent mutually exclusive identity forms as the only persisted key.

8. BLOCKER - The default disk provider does not resolve complete backing-disk membership and falsely labels incomplete topology as complete.

Evidence:
- `RecoveryAutomation.ps1:240-260` inventories only drive-letter volumes and selects the first partition for each volume.
- `RecoveryAutomation.ps1:283-301` resolves a path through one drive-letter partition and sets `MembersIncomplete = $false`; it does not resolve mounted-folder/no-drive-letter paths or all members of a spanned volume.
- `modules/DiskDetection.psm1:323-375` and `:467-480` call `Get-PhysicalDiskIdentity` for one `DiskNumber` only.
- The main entry point at `RecoveryAutomation.ps1:780` creates only this `WindowsStorageReadOnly` provider; it does not construct the specification's Storage-module, Storage-namespace, and Win32 association fallback chain.

Impact: a destination on a second member of a spanned or otherwise multi-disk volume can be judged disjoint when it shares the source disk. Mounted-folder and unlettered volume paths are not safely supported, while the provider asserts complete membership. This violates the hard same-physical-disk invariant.

Concrete fix: implement the documented provider order and return every physical member from the volume/partition associations. Mark dynamic, Storage Spaces, file-backed virtual, VHD, network, mounted/unresolved, and incomplete membership as indeterminate unless the complete physical topology is proven. Never set `MembersIncomplete = $false` by default.

9. BLOCKER - Destination safety helpers fail open on incomplete/tampered identity objects and unresolved reparse metadata.

Evidence:
- `modules/DiskDetection.psm1:538-552` trusts a caller-supplied `DestinationIdentity` without proving that it belongs to `DestinationPath`.
- `modules/DiskDetection.psm1:554-567` rejects a source only when `Resolved -eq $false`; a missing `Resolved` or `IsIndeterminate` field can pass if non-empty identity keys are supplied.
- `modules/DiskDetection.psm1:440-445` rejects a reparse point only when `ReparseResolved` is explicitly `$false`; an absent/unknown value is accepted.
- `RecoveryAutomation.ps1:285-301` sets `ReparseResolved = $true` after `Get-Item` without recording or checking the actual reparse target. `RecoveryAutomation.ps1:858-876` creates the job folder before the final child-path identity check.

Impact: public safety functions can allow an identity object that is not bound to the path or whose resolution is unknown. A junction/reparse or time-of-check race can cause directory creation on an unintended or source location before the final refusal.

Concrete fix: always resolve the supplied path inside the safety function and compare canonical path, volume, complete physical set, existence, and container status; require `Resolved -eq $true` and `IsIndeterminate -eq $false` explicitly. Treat missing reparse resolution as unsafe. Complete the final child-path check before any output-folder creation, or use an atomic safe claim mechanism that cannot create on an unresolved target.

10. BLOCKER - Application discovery can select Posit RStudio or an arbitrary same-named executable as R-Tools R-Studio.

Evidence:
- `modules/ApplicationDiscovery.psm1:232-241` marks RStudio verified if metadata merely contains `rstudio` or the leaf matches `RStudio*.exe`; this includes Posit RStudio and a same-named executable with weak/missing product metadata.
- Registry discovery uses the same generic token at `modules/ApplicationDiscovery.psm1:406-450` and has no R-Tools publisher/company requirement.
- `modules/ApplicationDiscovery.psm1:318-328` accepts a discovery item that self-reports matching `Product` and `IdentityStatus = Verified` without re-running product identity validation.
- `modules/RStudio.psm1:278-315` checks the caller's canonical `Product` and verification flag but does not require a non-empty version, evidence source, trusted publisher, or a positively verified on-disk identity.

Impact: the workflow can launch the wrong RStudio product or a malicious/incorrect executable named `RStudio.exe`, violating the explicit Agent/Emergency/Posit distinction and the exact-build evidence boundary.

Concrete fix: require FileVersionInfo plus trusted R-Tools company/publisher or owner-recorded exact-build evidence; positively reject Posit, Agent, Emergency, installer, and portable utility identities. Never allow a discovery candidate to self-assert verification, and require version/evidence/path existence in the final launch check.

11. BLOCKER - R-Studio handoff evidence is optional when it must be complete, and process identity is incomplete.

Evidence:
- `modules/RStudio.psm1:438-454` checks each `RSStateEvidenceFlags` member only if the property is present. A state with none of the required flags passes.
- `modules/RStudio.psm1:510-531` accepts fresh evidence when any one recognized flag is present; it does not require all six flags.
- `modules/RStudio.psm1:632-763` treats a runner result containing only a positive PID as a verified launch and fills the requested executable path into the identity; it does not require/verify actual process path and start time.
- `RecoveryAutomation.ps1:550-564` also treats any non-null authorization result lacking `Success`/`Allowed` as successful (`value -ne $false`).

Impact: an incomplete or malformed state/provider result can authorize R-Studio launch, and a PID without binding identity can be confused with another process. This defeats the final source/destination/close/output/log/state gate.

Concrete fix: require every handoff evidence flag explicitly and positively, require final identity/version/evidence and fresh source/destination/log/state checks, and reject missing/ambiguous provider success fields. Verify the launched process's actual executable path and start time against the requested identity before returning `Launched`.

12. BLOCKER - Resume state is not bound to the lock/claim and corrupt snapshots can be overwritten.

Evidence:
- `modules/JobState.psm1:479-522` accepts any object with `Lock.Acquired = $true`; it does not bind the lock to the requested state path, job folder, job ID, or immutable claim.
- `modules/JobState.psm1:207-243` validates only a shallow set of fields and does not validate identity evidence, paths, event sequence, or state/event consistency despite the contract.
- `modules/JobState.psm1:374-390` allows replacement when an existing snapshot is malformed (`existingJobId` remains null) or has the same job ID.

Impact: a caller can read a state file under an acquired-but-unrelated lock, and a corrupt existing state can be replaced rather than preserved for inspection. Resume can therefore operate on unproven case evidence and destroy the artifact needed to diagnose the failure.

Concrete fix: require the lock file's parsed owner, job folder, lease, and claim marker to bind exactly to the state path and job ID. Validate the state, log, identity snapshots, and event/state consistency before returning it. Refuse any malformed or unexpected existing snapshot; preserve it and route to `NeedsReview`.

Additional high-severity correctness gates

13. HIGH - UI action authorization accepts a provider result with no explicit success field.

`modules/UIAutomation.psm1:335-379` returns `Allowed = $true` when the provider result is non-null but has no `Allowed`, `Success`, or `Invoked` value. `Get-RecoveryAppState` also changes an absent `Unknown` value to false at `modules/UIAutomation.psm1:229-268`. A malformed UI result can therefore authorize an action or be recorded as observed. Require exactly one positive success decision and treat absent/contradictory state as unknown/manual.

14. HIGH - The File Scavenger close guard can ignore a true secondary activity flag.

`modules/FileScavenger.psm1:Test-FsSafeCloseObservation` (the active-work/unknown checks in the close-guard implementation) use first-property lookup for aliases such as `ActiveWork`, `ScanRunning`, and `RecoveryRunning`. The normalized app state contains `ActiveWork` even when a more specific running flag is true, so a false `ActiveWork` can mask `ScanRunning`/`RecoveryRunning`. Evaluate all activity and unknown indicators with OR semantics; any true or contradictory value must block close.

15. HIGH - Job-folder claiming is not atomic and can claim a pre-existing non-empty folder.

`modules/DiskDetection.psm1:825-854` uses `Test-Path`, then idempotent `Directory.CreateDirectory`, then creates the claim marker. A race can populate the directory between the check and claim, and an already-created non-empty directory can be claimed if the marker is absent. This violates the no-merge/no-overwrite rule. Use a claim protocol that proves the directory was newly created and empty, or refuse any directory whose contents are not exactly the newly created claim marker; preserve collision data.

16. HIGH - The handoff panel reports closure without requiring an explicit Close action and ignores action-provider failures.

`modules/TechnicianUi.psm1:669-777` always returns `Decision = 'PanelClosed'` after the interaction provider returns, even if the window was closed by the title-bar close control or no recognized Close action was taken. `modules/TechnicianUi.psm1:725-747` marks clipboard/explorer actions as Copied/Opened whenever the provider does not throw, ignoring a structured failure result. `modules/RStudio.psm1:982-1021` similarly returns `Opened = $true` without requiring a positive explorer result. Require an explicit recognized Close decision and explicit provider success; otherwise return a gate/failure.

Verification note

This artifact records source-confirmed blockers and concrete fixes. No claim is made here that Windows PowerShell, Pester, CI, File Scavenger, R-Studio, or real media testing passed. After fixes, add regression tests for every listed refusal/fail-open combination and rerun the Linux static/unit suites plus the Windows 5.1 and owner-live gates.
