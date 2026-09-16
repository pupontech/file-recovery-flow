Final release review after the B-8R repair

Scope, method, and what was and was not observed

This is the release decision for the revision that carries the B-8R production disk-provider repair. It
reads the original review (review/final-safety-review.md), the prior post-fix review
(review/post-fix-safety-review.md), the B-8R result handed off by task t_d4a8a29a, the current source,
and the durable lane reports. Only this file is written; no code, test, document, configuration, or git
state was modified.

Method:
- Independent lane execution by the reviewer in this workspace, on the frozen revision hashed below,
  through PesterConfiguration.ps1 (Pester 6.1.0 resolved; 5.9.0 also present).
- Independent parser, encoding, and destructive-command scans written and run by the reviewer, separate
  from the lane implementations, so the lanes are not the only witness.
- Line-by-line audit of the five fix items the prior review demanded for B-8R, plus a fresh read of the
  same-physical-disk refusal path end to end.

Not observed here, and not claimed anywhere in this artifact: any Windows host, Windows PowerShell 5.1,
Windows CI, File Scavenger, R-Studio, or real recovery media. The entry point refuses to run on this
runtime by design (runtime gate RecoveryAutomation.ps1:224-231 requires Windows_NT, major version 5, and
the Desktop edition), so the lanes exercise the production code through its documented provider seams.

Revision under review (sha256, first 16 hex)

RecoveryAutomation.ps1                          30773249c19e07fc
modules/ApplicationDiscovery.psm1               c420e4d8468c6f82
modules/Configuration.psm1                      50e6308f0d61ac40
modules/DiskDetection.psm1                      d653a4bd7d21a89b
modules/FileScavenger.psm1                      202fdb92425caaae
modules/JobState.psm1                           24cbe8fbba0fbb74
modules/RecoveryLogging.psm1                    4bc07b8b21e9e16f
modules/RStudio.psm1                            2554b2b76e662a2d
modules/TechnicianUi.psm1                       4915f519f31472e8
modules/UIAutomation.psm1                       928edc72e39db90c
tests/Static.Tests.ps1                          e5cf1b409bec2734
tests/Integration/RecoveryAutomation.Tests.ps1  94ee83ab813f2b09

The revision was frozen for this review: hashes taken before and after the lane runs are identical, and
the only files newer than the working tree's initial state are the two B-8R files
(RecoveryAutomation.ps1, 2026-09-16 14:21:48; tests/Integration/RecoveryAutomation.Tests.ps1,
14:19:33). RecoveryAutomation.ps1, DiskDetection.psm1, the integration file, and the static contract all
match the hashes the B-8R handoff published, so the module-side guards referenced by the review were
unchanged while this verification ran.

Independently verified evidence

Lanes, run by the reviewer on the hashed revision (exit code in parentheses):
- Static lane: 50 passed, 0 failed, 0 skipped (exit 0). Durable report
  .test-results/pester-static.xml total=50 failures=0, 2026-09-16 14:26.
- Unit lane: 301 passed, 0 failed, 0 skipped (exit 0). .test-results/pester-unit.xml total=301
  failures=0.
- Integration lane: 16 passed, 0 failed, 12 skipped (exit 0). .test-results/pester-integration.xml
  total=28 failures=0 skipped=12. The 28 cases split as 13 in
  tests/Integration/RecoveryAutomation.Tests.ps1 and 15 in tests/Integration/Launcher.Windows.Tests.ps1;
  12 launcher cases skip with a recorded harness reason on this Linux host (the cmd.exe launcher
  contract needs Windows) and the remaining 3 still execute. The skips are reason-recorded skips, not
  silently passing tests.

Parser: an independent scan (reviewer-written, outside the test lanes) parsed all 20 .ps1/.psm1 files
with the running engine parser (PowerShell 7.6.5) and reported 0 errors, exit 0. This corroborates the
static lane's S-06 contract (tests/Static.Tests.ps1:425).

Encoding: an independent byte scan of all 40 text files under the repository with the code, document,
configuration, and launcher extensions (.ps1, .psm1, .bat, .md, .json, .yml, .txt), excluding .git and
.test-results, found 0 non-ASCII bytes and 0 byte order marks, and Start-Recovery.bat is CRLF throughout.
The scan includes this artifact and the two earlier reviews. This corroborates the static lane's S-01
and S-02 contracts, whose guarded set is built by extension over the repository
(tests/Static.Tests.ps1:320, :344-421).

Destructive commands: the reviewer's own pattern scan for the disk/partition-changing cmdlets and native
tools matches only the deny-list literals inside the test files themselves
(tests/Static.Tests.ps1:56-63, tests/Unit/Core.Tests.ps1:2106, tests/Unit/RStudio.Tests.ps1:1924). No
production file contains one. The only storage calls in product code are the read-only reads in
RecoveryAutomation.ps1:358-390 (Get-Volume, Get-Partition, Get-Disk, Get-Item). The launcher
(Start-Recovery.bat:23, :26) starts one script with powershell.exe -File, captures the exit code
immediately, and contains no destructive, elevation, or vendor token.

B-8R closure: the five required items, checked against the current bytes

1. Read the disk's real dynamic state - CLOSED. RecoveryAutomation.ps1:445 reads IsDynamic from the disk
   view, :448 requires it to be a Boolean for the value to count as stated, and :464 publishes IsDynamic
   only when stated; an absent or non-Boolean value withholds completeness (:465). The module's
   dynamic-disk guard (modules/DiskDetection.psm1:364-368) is therefore reachable in production, which
   the prior review showed it was not.
2. Never emit complete membership unconditionally - CLOSED. Volume membership is published from the
   computed membership object (RecoveryAutomation.ps1:421), the disk view withholds it unless both the
   dynamic statement and the bus type were stated (:465), and the path record defaults to incomplete
   (:483, resolved at :506). An independent search finds no unconditional MembersIncomplete = $false
   anywhere in production code; the only occurrences are test fixtures
   (tests/Unit/Core.Tests.ps1:33,74,104; tests/Integration/RecoveryAutomation.Tests.ps1:84,189,304,410).
3. Enumerate every backing member and stop treating the first partition as the whole membership -
   CLOSED. The membership rule (RecoveryAutomation.ps1:273-352) accepts only two proofs: a member list
   the volume itself declares (:296-313), or the volume-scoped partition join (:315-333,
   Get-Partition -Volume at :370). A drive-letter-only enumeration is recorded as evidence but stays
   incomplete with reason DriveLetterOnlyMembership (:335-350), because a spanned, striped, or Storage
   Spaces volume presents the same letter on more than one disk. PhysicalDiskNumbers is published for
   every resolvable member (:420, :504) and DiskNumber only when exactly one member is proven (:407,
   :508-510), so a multi-disk volume never claims a single disk. A letterless or mounted-folder volume
   stays in the inventory (:399-402) and is never queried through an empty drive letter (the guard at
   :339-350 plus the blank-letter refusal at :373-375; the test asserts no letter query happened).
4. Build the documented provider order - NOT CLOSED; carried as the Windows-live gate, see below.
5. Add RED-first regression tests that fail before the fix - CLOSED. Five integration tests drive the
   real entry point (Invoke-RecoveryAutomation) through injected read-only seams:
   tests/Integration/RecoveryAutomation.Tests.ps1:895 (dynamic source -> exit 4, SourceIndeterminate,
   DynamicDiskBacking, zero vendor calls), :926 (destination on member 2 of a spanned volume sharing the
   source disk -> exit 5, SamePhysicalDisk, 2 source members and 2 destination members, zero vendor
   calls), :959 (letterless mounted-folder volume resolves through its members), :984 (unresolvable
   letterless volume -> MembersIncomplete, Resolved but indeterminate, not ProviderFailure), :1015 (a
   disk view that omits the dynamic statement is never claimed complete). These are not vacuous: the
   vendor runner throws if it is ever reached (:876-880) and each test asserts VendorLaunchAttempted
   false plus a call count of zero, so the refusal is proven to happen before any external action.

Same-physical-disk refusal, re-read end to end: every source member is compared against every
destination member (modules/DiskDetection.psm1:755-774), any structural match returns SamePhysicalDisk,
any comparison the two identity forms cannot support returns DestinationIndeterminate, and an
indeterminate destination (including incomplete membership, :729-732) is never Allowed. The entry point
returns exit 4 for an indeterminate source (RecoveryAutomation.ps1:2020-2029) and exit 5 for a refused
destination (:2069-2075, re-checked on the claimed folder at :2114-2119). Nothing is redirected or
retried on another path after a refusal.

Remaining gap: the documented provider order (not a source blocker)

docs/IMPLEMENTATION-SPEC.md:258-265 requires the primary provider order Storage module, then Storage
namespace CIM, then the Win32 association fallback, with an indeterminate result and a stop when none
can prove the mapping. The implementation still builds one Storage-module-backed provider
(RecoveryAutomation.ps1:2017, function at :234-529; Get-Volume/Get-Partition/Get-Disk/Get-Item at
:358-390). This is the item the B-8R card's handoff left open, and it is correctly left open.

Why it is not a source blocker: the single provider now fails closed instead of fail-open. A missing or
failing read yields nothing (RecoveryAutomation.ps1:266-272), nothing means membership is unproven
(:287), unproven publishes MembersIncomplete = $true (:421, :465, :506), the module reads only a literal
Boolean false as complete (modules/DiskDetection.psm1:479-488) and returns MembersIncomplete with
IsIndeterminate true (:571-574, and :375-379 for the disk view), the destination path is then refused as
DestinationIndeterminate rather than Allowed, and the entry point stops with exit 4 or 5 before any
vendor action. The technician sees exactly the refusal docs/OPERATOR-GUIDE.md:180-181 documents.

Residual risk to name plainly (why this is a testing ZIP and not a production release): if a real
Windows host's Get-Partition -Volume silently returned a partial member list for a spanned or Storage
Spaces volume instead of throwing, the provider would take that partial set as a complete proof. The
safety of that assumption cannot be settled from Linux, which is precisely why the live gate below is
mandatory and why the CIM association fallback (MSFT_DiskToPartition / MSFT_PartitionToVolume) stays the
required follow-up if the live run shows under-reporting.

Owner and CI gates that remain open (kept explicitly out of this decision's evidence)

- Live File Scavenger and R-Studio: docs/LIVE-VALIDATION.md is unchanged and remains the owner and
  technician record (L-01 identity and source safety at :64, L-02 UI surface and storage topology at :84
  including 2.7 source/destination physical identity and 2.8 mounted-folder and reparse paths, L-03 stage
  evidence at :117, L-04 prompts and close at :162, L-07 media/capacity/resume at :184, and the
  per-release environment and sign-off block). No automated lane can reach a licensed product: the
  non-live lanes exclude the live directory and the live tags and refuse to start when
  RECOVERY_ALLOW_LIVE_VENDOR is set, which the static lane verifies and which passed.
- L-02 is the gate that decides the provider-order item above: confirm on a real host that
  Get-Partition -Volume returns every member partition for basic, dynamic/spanned and Storage Spaces
  volumes, and that a dynamic or Storage Spaces source is reported as indeterminate. If it does not, the
  CIM fallback must be implemented before the workflow is used outside testing.
- Windows PowerShell 5.1 evidence: unexecuted. The repository has a single commit
  (f9d94742f90e74416b62e0c6e5519a5ada958948), origin/main is the same commit, every source file is still
  untracked, and the GitHub Actions API reports total_count 0 runs for pupontech/file-recovery-flow. The
  lanes declared in .github/workflows/ci.yml (static-linux at :43, test-windows on windows-2022 and
  windows-2025 at :90, compat-analyze at :212-281 running PSUseCompatibleSyntax and
  PSUseCompatibleCommands against the bundled 5.1 profiles with findings as errors) have therefore never
  run against this revision. The Linux parse under PowerShell 7.6.5 plus the static S-05 contract
  (tests/Static.Tests.ps1:557, :591) are a proxy for 5.1 compatibility, not proof of it, and the real 5.1
  launch path (Start-Recovery.bat:23) belongs to that unexecuted gate.
- The release ZIP must not be described as having passed those gates. It is a testing package for a
  technician machine with a disposable case, per docs/WORKFLOW.md and docs/LIVE-VALIDATION.md.

Non-blocking observations and record-keeping notes

- review/post-fix-safety-review.md:26 records modules/FileScavenger.psm1 as 202fdb92425caaeb; the file on
  disk hashes to 202fdb92425caaae in this review. Its modification time (2026-09-16 12:28:25) precedes
  both review artifacts, and no writer touched it during this review, so this is a transcription
  discrepancy in the recorded value, not a post-review source change. The hashes in this artifact
  supersede it.
- Reviewer harness caution for future reviewers: running a lane from a caller script that sets
  Set-StrictMode -Version 2.0 makes 15 cases in tests/Unit/RStudio.Tests.ps1 fail with
  PropertyNotFoundException "The property 'Count' cannot be found on this object" (a scalar's .Count
  under strict mode 2). Those failures are an artifact of the caller scope, not a source defect: with a
  clean caller scope the unit lane is 301/301, exit 0. Recorded here so the artifact is not mistaken for
  a blocker.
- modules/JobState.psm1:417 keeps an if/else whose two branches assign the same value ('WriteFailed').
  Cosmetic; fail-closed behavior is unaffected.
- modules/FileScavenger.psm1:631-652 return failure objects without the AuthorizationEvent / LaunchEvent
  diagnostics their neighboring branches carry. Cosmetic; fail-closed behavior is unaffected.
- docs/LIVE-VALIDATION.md L-02 would be the natural home for one explicit checklist line covering the
  provider order and the CIM fallback; the requirement itself is already recorded in
  docs/IMPLEMENTATION-SPEC.md:258-265. Documentation-only, not a blocker, and not edited here.

Release decision

RELEASE_READY_FOR_TESTING_ZIP.

No source blocker remains on the hashed revision. The only item the prior review left open against B-8R
that is still open is the documented provider order, and the repaired code fails closed on it: the
single provider withholds completeness whenever it cannot prove membership, the module refuses an
unproven topology, the same-physical-disk invariant is enforced over every member pair, and every
refusal stops the workflow before an external action. The three non-live lanes are green (static 50/50,
unit 301/301, integration 16 passed with 12 Windows skips), the encoding, parser and destructive-command
contracts are green both through the lanes and through this reviewer's independent scans, and the
twelve skipped tests are Windows-only launcher cases that are visible rather than silently passing.

Conditions carried with this verdict:
- The gates in the previous section stay open and must clear before the ZIP is treated as anything more
  than a testing package: live File Scavenger and R-Studio validation, the L-02 storage-topology check
  that decides the provider-order item, and the unexecuted Windows PowerShell 5.1 CI lanes.
- If L-02 shows that the volume-scoped join cannot prove a multi-member topology, the CIM association
  fallback is the required follow-up before wider use; until then the workflow stops rather than
  authorizing a destination it cannot prove is separate.

Constraints respected by this review: only review/final-release-review.md was written; no code, test,
document, or configuration file was edited; no commit, push, or destructive git command was run. The
lane re-runs regenerated only the gitignored .test-results XML reports. This artifact is pure ASCII with
LF line endings and no byte order mark, consistent with the S-01 contract that the static lane enforces,
and the static lane was re-run after it was written (50 passed, 0 failed, exit 0).
