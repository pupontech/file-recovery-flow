Post-fix safety review (independent re-verification)

Scope and method

This review re-checks the file-recovery-flow implementation after the targeted repairs that followed
review/final-safety-review.md. It reads the original review, the current source, the durable test
results, and re-runs the non-live test lanes in this workspace. Only this file is written; no code,
test, document, configuration, or git state was modified.

Method:
- Independent lane execution in this workspace (see "Verified green evidence"): the reviewer ran the
  lanes, not the implementers.
- Source audit of every prior blocker class against the current bytes, with file:line evidence.
- No Windows host, no File Scavenger, and no R-Studio was available in this environment, and the
  entry point refuses to run on Linux PowerShell 7 because of the documented runtime gate
  (RecoveryAutomation.ps1:224-231 requires Windows NT, major version 5, Desktop edition). The lanes
  therefore exercise the production code through its documented seams, and live vendor behavior stays
  an owner gate. This limitation is disclosed rather than glossed over.

Revision under review (sha256, first 16 hex)

RecoveryAutomation.ps1                0cdf2bc28a3a73eb
modules/ApplicationDiscovery.psm1     c420e4d8468c6f82
modules/Configuration.psm1            50e6308f0d61ac40
modules/DiskDetection.psm1            d653a4bd7d21a89b
modules/FileScavenger.psm1            202fdb92425caaeb
modules/JobState.psm1                 24cbe8fbba0fbb74
modules/RecoveryLogging.psm1          4bc07b8b21e9e16f
modules/RStudio.psm1                  2554b2b76e662a2d
modules/TechnicianUi.psm1             4915f519f31472e8
modules/UIAutomation.psm1             928edc72e39db90c
tests/Unit/Core.Tests.ps1             cee62d909dc1fa97
tests/Unit/FileScavenger.Tests.ps1    2751d3d4dcd79857
tests/Unit/Preflight.Tests.ps1        c2667544ac774bcb
tests/Unit/RStudio.Tests.ps1          aee010128f7b30b5
tests/Static.Tests.ps1                e5cf1b409bec2734
tests/Integration/RecoveryAutomation.Tests.ps1  d76bfe4036ecbdb9

Every module and test file on disk is older than the result files in .test-results
(newest source edit 2026-09-16 14:08:02 local, newest lane report 14:09:54 local), so the recorded
green results belong to the revision hashed above.

Verified green evidence

The reviewer re-ran the lanes through ./PesterConfiguration.ps1 (Pester 6.1.0 resolved):

- Static lane: Tests Passed: 50, Failed: 0, Skipped: 0 (exit code 0).
- Unit lane: Tests Passed: 301, Failed: 0, Skipped: 0 (exit code 0).
- Integration lane: Tests Passed: 11, Failed: 0, Skipped: 12 (the 12 skips are the Windows-only
  launcher cases), exit code 0.

These match the durable reports on disk (.test-results/pester-static.xml total 50 failures 0,
pester-unit.xml total 301 failures 0, pester-integration.xml total 23 failures 0 skipped 12).
The Static lane includes the ASCII/BOM, PS 5.1 syntax, destructive-AST deny-list, launcher, and CI
topology contracts, so the safety invariants are statically enforced by a lane that passed on this
exact revision. tests/Integration/RecoveryAutomation.Tests.ps1:378 ("drives the documented short and
long recovery path before the launch-only handoff") and :597 ("hands off to R-Studio with only the
documented launch arguments after READY_FOR_HANDOFF") both passed, which is the executable proof that
the orchestrator now reaches the manual gate and the launch-only handoff.

Prior blocker classes

1. Orchestrator dead end - CLOSED. The entry point calls the workflow driver
   (RecoveryAutomation.ps1:2182) after the G-04 gate is durably recorded, and the driver walks
   SHORT_SCAN, SHORT_RECOVERY, G-05, LONG_SCAN, LONG_RECOVERY, close, and handoff
   (RecoveryAutomation.ps1:1377-1434). Reaching anything other than READY_FOR_HANDOFF returns
   ManualGatePending (1432-1433), and a stopped G-04 gate returns ManualGatePending with exit code 8
   instead of a success (2173-2179). Invoke-RecoveryAutomationHandoff is reachable and is called at
   1501; it ends in the HANDOFF_MANUAL transition (1610-1618). A clean success is returned only after
   the launch-only handoff is verified (1504-1507, 2193).
2. Launch before durable authorization - CLOSED. Write-FsDurableEvent refuses a missing writer with
   EventWriterRequired (modules/FileScavenger.psm1:454-462); Start-FileScavenger writes and flushes
   the launch-authorization StageStarted event before invoking the process runner
   (modules/FileScavenger.psm1:590-612 precedes 614-615). A post-launch event failure is never a clean
   failure: the identity is retained, an interrupted-unknown event is attempted, and the result is
   Started = true with Result = InterruptedUnknown, RequiresOperator = true, NeedsReview = true,
   SuggestedState = INTERRUPTED_UNKNOWN (modules/FileScavenger.psm1:697-736). Only the verified
   executable path is passed and scanner arguments are refused (FileScavenger.psm1:655-668, 748).
3. Structured log refusals ignored - CLOSED. ConvertTo-RecoveryLogProviderDecision normalizes every
   provider result to one explicit Boolean decision and refuses a missing or non-Boolean Success field
   (modules/RecoveryLogging.psm1:19-83). Append and flush refusals set IsBlocked on the writer
   (RecoveryLogging.psm1:540-552) and every later write and flush is refused while blocked
   (RecoveryLogging.psm1:486-490, 571-576).
4. Log/state sequence divergence - CLOSED. The event-writer closure adopts the sequence the log writer
   reports, rejects a missing sequence (EventSequenceMissing) or a non-advancing one
   (EventSequenceInvalid), and snapshots the state with that exact sequence
   (RecoveryAutomation.ps1:2030-2046). Resume validates the log against the state binding before
   deciding (modules/JobState.psm1:1184-1199).
5. Ignored G-04 snapshot write - CLOSED. The gate presentation event, the operator decision event, and
   the state snapshot are each checked and propagate GateEventWriteFailed / GateStateWriteFailed before
   any success return (RecoveryAutomation.ps1:2145-2172).
6. Source protection checked once - CLOSED. Read-only evidence is preserved on the fresh identity
   (RecoveryAutomation.ps1:1814-1815, 1926) and re-probed immediately before launch, with a recorded
   SourceIdentityChanged event and a fail-closed return (2096-2106).
7. Weak cross-provider disk identity - CLOSED. Test-RecoveryDiskIdentityMatch compares identity
   structure (unique id/format, or serial+size+model) and returns Indeterminate on contradiction or
   missing evidence (modules/DiskDetection.psm1:200-244); Test-DestinationSafety treats an
   indeterminate comparison as blocked (DiskDetection.psm1:758-774).
8. Backing-disk membership - PARTIALLY CLOSED, provider half still open. See
   "Remaining blocker" below.
9. Fail-open destination/reparse helpers - CLOSED. Test-DestinationSafety always re-resolves the path
   itself and accepts a supplied identity only when Test-RecoveryIdentityBinding proves canonical path,
   volume, disk number, and identity-key equality; unknown resolution is refused
   (modules/DiskDetection.psm1:648-685, 711-732). Resolve-RecoveryPathIdentity requires an explicit
   Boolean reparse resolution (DiskDetection.psm1:490-500, 563-569), an existing container, a resolved
   volume, and complete membership (555-594), and the job folder is re-checked after creation
   (RecoveryAutomation.ps1:1894-1904).
10. Wrong RStudio product - CLOSED. Candidate identity requires file version info plus a trusted
    R-Tools company/publisher match, or owner-recorded evidence, and positively rejects a conflicting
    publisher or missing product metadata (modules/ApplicationDiscovery.psm1:287-320); injected
    existence/readability evidence is accepted only as Boolean true, otherwise the identity is Missing
    (preflight regression tests/Unit/Preflight.Tests.ps1:131-149, green).
11. Optional handoff evidence - CLOSED. All six handoff flags are required to be true, both in the
    durable state and in fresh evidence (modules/RStudio.psm1:532-552, 618-633, 56), and a launched
    process must match the requested executable path and carry a start time,
    otherwise ProcessPathMismatch / ProcessStartTimeMissing is returned (RStudio.psm1:833-854).
    The launch authorization event is written before Start-RStudioHandoff and is validated as an
    explicit Boolean success (RecoveryAutomation.ps1:1543-1581).
12. Resume unbound to lock/claim - CLOSED. Get-RecoveryStateBindingCheck requires the lock to bind to
    the state path and the job, including a non-empty claim marker that matches the job folder claim
    (modules/JobState.psm1:491-620, ClaimNotBound at 586-607); Get-RecoveryResumeDecision starts at
    FailedClosed and refuses a log/state mismatch (JobState.psm1:1162-1199); an unreadable or
    foreign-job snapshot is preserved instead of replaced
    (JobState.psm1:374-401, SnapshotUnreadable / SnapshotJobMismatch).
13. HIGH, UI action success - CLOSED. Exactly one provider result is inspected; zero results are
    UiActionUnknown, more than one are UiActionResultAmbiguous, absent or contradictory decisions are
    UiActionResultUnverified, and Allowed = true is only reached on an explicit positive decision
    (modules/UIAutomation.psm1:328-428), with the RED/GREEN regression tests at
    tests/Unit/FileScavenger.Tests.ps1:97,123,143.
14. HIGH, close guard masking - CLOSED. The close guard delegates to Test-FsActiveOrUnknownObservation,
    which evaluates every activity alias (ActiveWork, ScanRunning, RecoveryRunning, Busy, and the
    InProgress family) and every unknown alias with OR semantics, blocking on any true or unreadable
    indicator (modules/FileScavenger.psm1:1360-1418), and requires a verified recovery before close
    (FileScavenger.psm1:1441-1454).
15. HIGH, non-atomic job folder claim - CLOSED. A directory is created and then probed: any directory
    that already holds entries is left untouched and the next suffix is tried
    (modules/DiskDetection.psm1:1029-1046), with the claim marker written as the first and only content.
16. HIGH, panel close and action results - CLOSED. An explicit recognized Close action is required
    (CloseActionRequired), any other close mechanism is refused (CloseActionUnverified), and clipboard
    and explorer actions require an explicit provider success, otherwise the panel returns a blocked
    result (modules/TechnicianUi.psm1:818-849, 872-947).

Destructive operations and invented vendor automation

- The static lane passed on this revision, including the AST deny-list for disk/partition-changing
  cmdlets and native tools (tests/Static.Tests.ps1:52-62; the deny list covers Format-Volume,
  Initialize-Disk, Clear-Disk, Set-Disk, partition create/resize/remove, Repair-Volume, chkdsk,
  diskpart, format, bcdedit, fsutil, and friends) and the dynamic-invocation deny list. No source file
  invokes those operations; the only storage calls in the product code are read-only Get-Volume,
  Get-Partition, Get-Disk, and Get-Item (RecoveryAutomation.ps1:242-306).
- No vendor command-line switch is invented: the File Scavenger launch passes an empty argument list
  (RecoveryAutomation.ps1:2142, Argument = @(); modules/FileScavenger.psm1:748) and refuses any
  runner-reported scanner arguments (FileScavenger.psm1:655-668). R-Studio is launch-only as well
  (RStudio.psm1:897-1056 set AnalysisInvoked = false on every return), and the unsupported steps stay
  manual gates (G-04 at RecoveryAutomation.ps1:2140-2143, G-05 at 1391-1395).

Owner-live gaps

docs/LIVE-VALIDATION.md is present and still the owner/technician record: it carries the live status
header (line 3), the L-01 identity/source-safety, L-02 UI surface and storage topology, L-03 stage
evidence, L-04 prompts and close, L-07 media/capacity/resume, and L-11 R-Studio launch-only sections,
plus the per-release environment checks and sign-off block (lines 24-267). The automated lanes exclude
the live tags and the live directory and refuse to run when the vendor opt-in is set
(tests/Static.Tests.ps1 lane-configuration contracts, green), so no automated lane can reach a licensed
application. The remaining owner-live items are therefore correctly separated from the release
decision, and the review makes no claim that Windows PowerShell 5.1, Windows CI, File Scavenger, or
R-Studio behavior was observed here.

Remaining blocker

BLOCKER B-8R - The production disk provider still asserts complete, non-dynamic physical membership
without proving it, so the same-physical-disk invariant can still be satisfied by a false claim.

Evidence:
- RecoveryAutomation.ps1:259, :280, :301 set MembersIncomplete = $false unconditionally in the GetVolumes,
  GetDisks, and ResolvePath closures of New-RecoveryAutomationWindowsDiskProvider (function at
  RecoveryAutomation.ps1:234-313).
- RecoveryAutomation.ps1:279 sets IsDynamic = $false unconditionally instead of reading the disk's own
  value, so the module's dynamic-disk guard (modules/DiskDetection.psm1:364-368, DynamicDiskBacking) is
  unreachable in production: the module only sees IsDynamic = true in a test fixture
  (tests/Unit/Core.Tests.ps1:47 and :757).
- RecoveryAutomation.ps1:244 and :287 derive membership from
  Get-Partition -DriveLetter <letter> | Select-Object -First 1, which yields exactly one disk number and
  never emits PhysicalDiskNumbers, so a volume backed by more than one disk is reported as a single-member,
  complete topology. modules/DiskDetection.psm1:457-477 consumes exactly that claim
  (PhysicalDiskNumbers / DiskNumbers, else the single DiskNumber), and DiskDetection.psm1:423-451 marks a
  volume indeterminate only when the provider says so.
- Only this provider is constructed (RecoveryAutomation.ps1:1801), while docs/IMPLEMENTATION-SPEC.md:258-265
  requires the Storage-module, Storage-namespace CIM, then Win32-association provider order, and states
  that dynamic disks, Storage Spaces, File-Backed Virtual, network shares, VHDs, and any topology with
  incomplete physical membership are not treated as separate merely because a drive letter exists. The
  documentation the operator relies on (docs/OPERATOR-GUIDE.md:181, DestinationIndeterminate for dynamic
  disks, Storage Spaces, virtual, VHD, network, or incomplete member sets) is therefore not produced by
  the code that runs in production.

Impact: on a machine whose source sits on one member of a dynamic/spanned (or otherwise multi-disk)
volume and whose destination is a folder on another member of that same volume, the provider reports one
member per path, MembersIncomplete = $false, and IsDynamic = $false. Test-DestinationSafety then compares
disk A against disk B, finds no structural match, and returns Allowed (DiskDetection.psm1:759-778). That
is the exact failure mode the original blocker 8 described: a destination on the same physical storage as
the source is authorized. The module-level guards are correct; the provider feeding them is not, and no
test covers the provider, so the green lanes cannot detect it.

Exact fix (owner: the module/entry-point writer):
1. RecoveryAutomation.ps1:279 - read the disk's real value (Get-Disk exposes IsDynamic) instead of the
   hardcoded $false. When the value cannot be read, do not claim completeness.
2. RecoveryAutomation.ps1:259, :280, :301 - never emit MembersIncomplete = $false unconditionally. Emit it
   only after the complete member set is proven; otherwise emit $true. Enumerate every backing disk
   (Get-Partition -Volume <volume>, or the MSFT_DiskToPartition / MSFT_PartitionToVolume associations)
   and publish PhysicalDiskNumbers = @(<all member disk numbers>).
3. RecoveryAutomation.ps1:244, :287 - stop treating the first drive-letter partition as the whole
   membership. A volume with no drive letter or with a mounted-folder access path must be marked
   incomplete/indeterminate in the inventory rather than skipped (243) or resolved through an empty
   drive letter.
4. RecoveryAutomation.ps1:1801 - construct the documented provider order from
   docs/IMPLEMENTATION-SPEC.md:258-265 and return an indeterminate mapping when none of the providers can
   prove it, instead of a single best-effort provider.
5. Add regression tests that fail before the fix: (a) a production-provider seam where the fabricated
   Get-Disk reports IsDynamic = true must surface DynamicDiskBacking and end as SourceIndeterminate /
   DestinationIndeterminate, never Allowed; (b) a fabricated multi-member volume must surface
   PhysicalDiskNumbers and a destination on member 2 must be refused with SamePhysicalDisk; (c) a
   letterless/mounted-folder destination must return DestinationIndeterminate, not a generic
   ProviderFailure (today Resolve-RecoveryPathIdentity would report ProviderFailure at
   DiskDetection.psm1:543-545 when Get-Partition throws on an empty drive letter).
   New-RecoveryAutomationWindowsDiskProvider currently has no test in tests/ at all, which is why the
   lanes stay green with this defect present.

Non-blocking observations

- modules/JobState.psm1:417 has an if/else whose two branches assign the same value
  ('WriteFailed'); harmless, but it should be a single assignment so the intent is legible.
- modules/FileScavenger.psm1:631-652 return failure objects without the AuthorizationEvent /
  LaunchEvent diagnostics that the neighboring branches carry. Fail-closed behavior is unaffected.
- Review/*.md files are inside the static lane's ASCII scan, so this artifact is written as pure ASCII
  without a BOM, consistent with the S-01 contract that the lane enforces.

Release decision

BLOCKED. Sixteen of the seventeen prior blocker classes are fail-closed in the current source and the
orchestrator demonstrably reaches the tested manual gate and the launch-only handoff path, but blocker
B-8R (the production disk provider's unconditional complete/non-dynamic membership claim and single-member
resolution) is a direct, source-visible violation of the documented same-physical-disk invariant and of
the original blocker 8 fix requirement. It is the only item preventing a RELEASE_READY decision; the
remaining owner-live items in docs/LIVE-VALIDATION.md are gates by design and are not the reason for this
verdict.

After the fix above lands with its RED/GREEN regression tests, this review's blocker list is empty and
the release can be re-decided on a fresh green Static/Unit/Integration run plus the owner-live sign-off.
