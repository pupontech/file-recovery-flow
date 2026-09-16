# Windows Disk Identity and Safe Folder Selection - Research and Design

Task: t_ba4d7e5d (research lane). Artifact owner: dsflash.
Scope: research and design only. No implementation code, no other artifacts touched.

## 1. Purpose and evidence rules

This document fixes the evidence-backed design for two things the recovery workflow needs
before any scanner runs: (a) enumerating volumes and their backing physical disks so a
destination on the source physical disk can be refused, and (b) selecting and sanitizing a
destination folder and creating a unique job folder without screen coordinates.

Evidence rules applied here:

- Claims about the platform cite Microsoft primary documentation by numbered reference [n];
  the Sources block at the end maps each number to its URL.
- Statements that are engineering judgement rather than documented fact are marked [unverified]
  or labelled as a design decision.
- No installed-version observation was made in this lane: the worker environment is Linux with
  no Windows host and no File Scavenger or R-Studio installation, so every statement below is
  documentation evidence. Live behaviour remains a technician gate (see section 8).

## 2. What Windows exposes, layer by layer

### 2.1 Volume layer (letter, label, filesystem, size, free space)

`Get-Volume` returns Volume objects and is the primary volume enumerator in the Storage module.
Its object surface includes DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
SizeRemaining and Size [3]. A drive-letter lookup is a documented example:

    Get-Volume -DriveLetter C
    DriveLetter  FileSystemLabel  FileSystem  HealthStatus  SizeRemaining  Size
    C                             NTFS        Healthy       23.61 GB       465.42 GB

Two further parameter sets matter for safety checks: `Get-Volume -FilePath <path>` resolves the
volume that contains an arbitrary file path, and `Get-Volume -Path` / `-ObjectId` / `-UniqueId`
resolve a volume from a volume device path or identity [3]. `-FilePath` is the documented hook
that lets the workflow turn "the technician picked folder X" into "the volume that backs
folder X" without guessing [3].

The WMI fallback for the same layer is `Win32_LogicalDisk`, which exposes DeviceID (the drive
letter), DriveType, FileSystem, Size, FreeSpace, VolumeName, VolumeSerialNumber, VolumeDirty and
PNPDeviceID [9]. DriveType is the documented way to distinguish a fixed local hard disk (3) from
a removable (2), network (4) or compact disc (5) device, and a null FreeSpace is the documented
signal that no media is present [10]. Note that Win32_LogicalDisk.VolumeSerialNumber is a
per-volume identifier, not an identity of the backing physical disk, so it must never be used
for the same-disk refusal test.

Free-space numbers are not interchangeable. DriveInfo.AvailableFreeSpace is documented to differ
from TotalFreeSpace because it takes disk quotas into account, and reading it can raise
UnauthorizedAccessException or IOException [17]. Design decision: the space gate uses the more
conservative of the Storage-module SizeRemaining [3] and the .NET available-to-current-user value
[17], and treats a thrown exception as "unknown free space", which stops the workflow rather than
permitting a write.

### 2.2 Partition layer (the join between volume and disk)

`Get-Partition -DriveLetter C` returns the partition (and therefore the disk) associated with the
volume for drive letter C; the documented output block is headed `Disk Number: 0` [2]. The
underlying MSFT_Partition object carries DiskNumber with a documented model correspondence to
MSFT_Disk.Number [12]. MSFT_Partition also exposes DriveLetter (null when no letter has been
assigned), AccessPaths (the mount points for the partition, which include drive letters in
addition to mounted folders), GptType, PartitionNumber and Size [12].

Two consequences for this workflow:

- Mounted-folder volumes (no drive letter) are reachable through AccessPaths and through
  `Get-Volume -FilePath` [3][12], so the destination check must not be letter-only.
- A partition that the mount manager does not see (IsHidden) receives no drive letter, no volume
  GUID path and is not enumerated by FindFirstVolume/FindNextVolume [12]; such a partition is
  invisible to a letter-based UI and must be reported as "identity unavailable" rather than
  silently ignored.

`Get-Partition` can also be driven from a disk (`-DiskNumber`, `-Disk`) or a volume object
(`-Volume`) [2], which is how the reverse test (list every partition on the source disk) is
implemented.

### 2.3 Physical disk layer (the identity that actually matters)

`Get-Disk` returns the disks visible to the operating system as MSFT_Disk objects, excluding
dynamic disks, which are documented as able to span multiple pieces of physical media and are
therefore not returned [1]. MSFT_Disk carries Number, FriendlyName, SerialNumber, UniqueId with
UniqueIdFormat, Model, Manufacturer, FirmwareVersion, Size, BusType, PartitionStyle, Guid (GPT
only), IsOffline, IsReadOnly, IsSystem, IsBoot and Location (a PnP location path) [11].

The single most important documented caveat for this project is on `Number`: "Disk 0 is typically
the boot device. Disk numbers may not necessarily remain the same across restarts." [11] The same
warning is repeated on MSFT_Partition.DiskNumber [12]. Therefore:

- A disk number is a session label, never a persisted identity.
- Any stored job state must record a composite identity and re-verify it before each stage.
- A resumed job whose recorded composite identity no longer matches the machine must stop and
  ask the operator rather than continue against a possibly different disk.

Bus geometry is exposed as BusType on both MSFT_Disk [11] and MSFT_PhysicalDisk [5], with
documented values including USB (7), SATA (11), SAS (10), RAID (8), iSCSI (9), NVMe (17),
Storage Spaces (16) and File Backed Virtual (15) [5][11]. BusType is the documented basis for the
"this is a USB-attached source disk" operator hint [1].

`Get-PhysicalDisk` returns PhysicalDisk objects from every available Storage Management Provider,
and the documentation states plainly that a storage management provider is required to manage
physical disks [4]. MSFT_PhysicalDisk exposes FriendlyName, DeviceId, FirmwareVersion, PartNumber,
Size, BusType, MediaType and SpindleSpeed, and inherits UniqueId/UniqueIdFormat [5]. MediaType is
the documented SSD/HDD discriminator (0 unspecified, 3 HDD, 4 SSD, 5 SCM) [5], and SpindleSpeed is
0 for non-rotational media and 0xFFFFFFFF when a rotating disk speed is unknown [5]. `Get-PhysicalDisk`
also documents `-SerialNumber` and `-FriendlyName` filter parameters and a `-VirtualDisk` parameter
set [4]; the simplified MSFT_PhysicalDisk syntax block does not list a SerialNumber property [5],
so serial must be treated as an optional field that may be absent, not as the primary key.
Engineering caution, not documented: USB bridge chips are widely reported to return blank or
duplicated serials, which is why this design never keys on serial alone [unverified].

### 2.4 WMI fallback path and its association classes

When the Storage module or a storage management provider is unavailable, the documented WMI route
is a three-step traversal in the root\CIMV2 namespace: start from `Win32_DiskDrive`, follow
`Win32_DiskDriveToDiskPartition` (Antecedent Win32_DiskDrive, Dependent Win32_DiskPartition) to
the partitions on that drive, then follow `Win32_LogicalDiskToPartition` (Antecedent
Win32_DiskPartition, Dependent Win32_LogicalDisk) and read the drive letter from
Win32_LogicalDisk.DeviceID [10][6][7]. `Win32_DiskDrive` supplies Model, SerialNumber,
InterfaceType, PNPDeviceID, DeviceID, Index, Size, Partitions, FirmwareRevision and MediaType [8].
The documented permission caveat for this route is remote-only: a user connecting from a remote
computer needs the SC_MANAGER_CONNECT privilege to enumerate Win32_DiskDrive [8]. Local
enumeration in root\CIMV2 is the supported local path [6][7][10].

### 2.5 Availability fallbacks for the enumerators

The Storage namespace classes this design depends on have documented minimums of Windows 8 client
and Windows Server 2012 server [5][11][12], so a pre-Windows 8 machine has no Get-Disk,
Get-Partition, Get-Volume or Get-PhysicalDisk at all. In Windows PE the Storage cmdlets are not
present by default either; they arrive with the WinPE-StorageWMI optional component, which
contains the PowerShell storage-management cmdlets built on the Windows Storage Management API and
whose documented dependencies are WinPE-WMI, WinPE-NetFX, WinPE-Scripting and WinPE-PowerShell,
installed in that order [23]. Design decision: the workflow probes for the Storage module, then
for a raw CIM query in the Storage namespace [11][12], then for the Win32 association traversal
[6][7][10], in that order, and records which provider answered; if none answers, it stops at
a manual gate instead of scanning blind.

### 2.6 Identity composite (design decision)

Because no single documented field is sufficient, the workflow computes an identity record per
physical disk with these fields, each tagged with the source that produced it:

| Field | Source | Notes |
| --- | --- | --- |
| DiskNumber | MSFT_Disk.Number [11] / Get-Partition output [2] | Session label only; re-read every run [11] |
| UniqueId + UniqueIdFormat | MSFT_Disk [11] | Preferred stable key when present |
| SerialNumber | MSFT_Disk [11] / Win32_DiskDrive [8] | Optional; may be absent [4][5] |
| Model / FriendlyName / Manufacturer | MSFT_Disk [11] / Win32_DiskDrive [8] | Trailing spaces possible in friendly names [1] |
| Size (bytes) | MSFT_Disk [11] | Disambiguates look-alike models |
| BusType | MSFT_Disk [11] / MSFT_PhysicalDisk [5] | USB vs SATA vs Storage Spaces hint |
| Location | MSFT_Disk [11] | PnP location path (null for Hyper-V/VHD) [11] |
| PNPDeviceID | Win32_DiskDrive [8] | Fallback path only |

Two disks are treated as the same physical disk only when a strong field matches exactly
(UniqueId, or SerialNumber plus Size plus Model); matching on DiskNumber alone is explicitly
forbidden by [11]. When the strong fields are unavailable on either side, the comparison returns
"indeterminate" and the workflow refuses (section 4).

## 3. Mapped volumes and indeterminate backings

Some configurations have no single backing physical disk, and the documentation says so:

- Dynamic disks are not returned by Get-Disk at all, because they can span multiple pieces of
  physical media [1].
- Storage Spaces and File-Backed Virtual appear as BusType values on MSFT_Disk [11], and the
  physical members behind them are only reachable through the storage-pool/virtual-disk parameter
  sets of `Get-PhysicalDisk -VirtualDisk` [4].
- A storage management provider is required before physical disks can be managed at all [4], and
  the SMP is the documented bridge between management applications and the underlying storage
  subsystems [26].

Design decision: if the source or destination volume resolves to a disk with BusType Storage
Spaces or File Backed Virtual [11], or if `Get-Disk` returns no matching disk for a partition that
`Get-Partition` reported [1][2], the workflow reports "backing disk indeterminate", lists whatever
evidence it could collect, and refuses to start. This is a manual operator gate, not an automatic
resolution.

## 4. Same-physical-disk refusal (algorithm)

The refusal test is fail-closed: unknown is treated as same-disk-unsafe.

1. Resolve the source volume to its backing disks: partition (Get-Partition -DriveLetter, or the
   partition behind the volume) [2] -> DiskNumber [12] -> MSFT_Disk identity record [11].
   In the WMI fallback, the same result comes from the association traversal [6][7][10].
2. Resolve the chosen destination folder to its volume with `Get-Volume -FilePath` [3], then to
   its partition and disk by the same join [2][12]. This works for drive letters and for
   mounted-folder volumes [12].
3. Build the identity record for both sides using the composite in section 2.6 [11][8].
4. Refuse when any of the following holds, with a distinct machine-readable reason code:
   - a strong identity field matches on both sides (same physical disk) [11];
   - the destination volume is the source volume (same volume GUID/letter) [3];
   - either side is indeterminate (missing strong fields, dynamic disk, Storage Spaces or
     File-Backed Virtual backing, no storage management provider) [1][4][11];
   - the destination path does not exist as a container or cannot be resolved to a volume [3][17].
5. Never redirect to another destination automatically. `docs/WORKFLOW.md` forbids it and
   `AGENTS.md` forbids it; the operator picks a different folder.
6. Record both identity records in the job state next to the refusal or acceptance decision, so
   the decision is auditable from the job log alone.

Side effect of this design: the destination may live on a different physical disk reached by a
mounted folder rather than a letter [12], and that is acceptable as long as step 2 resolves it.

## 5. Folder selection without screen coordinates

Three documented mechanisms were evaluated. None uses screen coordinates, and the ranking below
is a design decision on documented capability.

### 5.1 Primary: System.Windows.Forms.FolderBrowserDialog

`System.Windows.Forms.FolderBrowserDialog` is a documented .NET class that prompts the user to
select a folder and that cannot be inherited [14]. Its documented members are the ones this
workflow needs: Description, RootFolder (a SpecialFolder), SelectedPath, ShowNewFolderButton and
ShowDialog() returning a DialogResult [14]. Crucially, SelectedPath is the documented way to read
the selection as a path [14], which avoids the Shell Folder problem in 5.2 entirely.

Threading: the class is a Windows Forms common dialog and the documented example runs it under
[STAThreadAttribute] [14]. Windows PowerShell 3.0 and later defaults `powershell.exe` to a
single-threaded apartment [16], so a PS 5.1 launcher that does not pass `-Mta` is already in the
supported apartment. Design decision: the launcher must not force `-Mta`, and a failure to show
the dialog is treated as "no picker available", falling back to 5.4 rather than retrying blindly.

ShowNewFolderButton should be disabled. Design decision: letting the workflow create the unique
job folder (section 6) keeps the folder name deterministic and lets the collision guard run
before any scanner sees the destination; operator-created destination subfolders would bypass
that guard.

### 5.2 Alternative: Shell.Application.BrowseForFolder

`Shell.BrowseForFolder(Hwnd, sTitle, iOptions, vRootFolder)` is documented as creating a dialog
that lets the user select a folder and returning the selected folder's Folder object; Hwnd may be
zero, iOptions is a combination of the BROWSEINFO ulFlags values, and vRootFolder optionally
limits how far up the tree the user can browse [15].

The blocker is the return value. The Folder object page documents exactly four properties
(Application, Parent, ParentFolder, Title) and no filesystem path property [25]. There is no
documented, vendor-blessed way to turn the returned object into a filesystem path. Verdict: not
suitable as the primary destination picker for a safety-critical check; the `.Self.Path` idiom
seen in the field is undocumented on that page and is therefore treated as a manual/unverified
surface, in line with `AGENTS.md` ("never invent ... control names").

### 5.3 Alternative: IFileOpenDialog with FOS_PICKFOLDERS

The Common Item Dialog path is documented: to let users pick folders with IFileOpenDialog, call
SetOptions with the FOS_PICKFOLDERS flag set and make sure FOS_FORCEFILESYSTEM is clear [20].
This is the modern picker and it is documented to support folder selection, but consuming it from
Windows PowerShell 5.1 requires COM interop (Add-Type) rather than a script-level API. Design
decision: record it as the upgrade path if FolderBrowserDialog proves inadequate in technician
testing (for example if a "New Folder" affordance or a shell rail is required); do not build it
for v1.

### 5.4 Fallback: typed path, validated

If no interactive picker is available (non-interactive session, dialog failure, PS host not in
STA), the workflow asks for a typed path and validates it with the same resolver as 5.1: the path
must exist as a container, must resolve to a volume through `Get-Volume -FilePath` [3], and must
pass the refusal test in section 4. A typed path that fails any of these stops the workflow.
This keeps the manual gate manual instead of inventing a picker.

## 6. Path sanitization and the unique job folder

### 6.1 Sanitization rules (documented constraints)

Windows file and directory names may not contain < > : " / \ | ? * or the ASCII NUL character, nor
characters 1 through 31, nor "any other character that the target file system does not allow"; and
the names CON, PRN, AUX, NUL, COM1-COM9, LPT1-LPT9 (including with an extension, and including the
superscript digit variants) are reserved and must not be used as a file name [13]. Names must not
end with a space or a period, and case must not be assumed to be significant [13]. Because a
directory is a file with a directory attribute, all of these rules apply to folder names too [13].

`System.IO.Path.GetInvalidFileNameChars()` exists but its own documentation warns that the
returned array "is not guaranteed to contain the complete set of characters that are invalid in
file and directory names" and that the full set can vary by file system [21]. Design decision:
the sanitizer unions the documented reserved set from [13] with the .NET array [21], then applies
the rules that neither source enforces automatically (reserved device names, trailing dot or
space, empty result), and finally restricts the output alphabet to [A-Za-z0-9._-]. The restricted
alphabet is a deliberate simplification: it removes case-folding, codepage and shell-quoting
ambiguity from a name that will end up in logs, job state and command lines.

### 6.2 Length budget

MAX_PATH is documented as 260 characters, and the same page states that when an API creates a
directory the specified path cannot be so long that an 8.3 file name cannot be appended (the
directory name cannot exceed MAX_PATH minus 12) [19]. Design decision: cap the sanitized client
name component at 40 characters, keep the full job folder path under 200 characters, and fail
loudly if the composed path exceeds the budget instead of truncating silently.

### 6.3 Unique job folder without ever overwriting

`Directory.CreateDirectory` is not a uniqueness check: it is documented that if the directory
already exists the method does not create a new one but returns a DirectoryInfo for the existing
directory [22]. Therefore directory creation cannot be the guard against overwriting an existing
job, and `New-Item -ItemType Directory` inherits the same semantics.

Design decision: the collision guard is a marker file created with FileMode.CreateNew, which is
documented to throw IOException when the file already exists [18]. Sequence:

1. Compose `<sanitized-client-name>_<yyyyMMdd-HHmmss>` under the picked folder.
2. Create the directory (idempotent by design [22]).
3. Immediately claim it by opening the job state file with FileMode.CreateNew [18].
4. If the claim throws because the file exists, the folder belongs to an existing job: do not
   write into it, do not overwrite it, and do not delete it (`AGENTS.md`). Move to the next
   candidate name with a numeric suffix, bounded (for example -001 through -099).
5. If the bounded list is exhausted, stop and ask the operator for a different destination root.

Because the marker write is a real write, it doubles as the final filesystem validation: if the
target filesystem rejects the name or the space is gone, the claim fails and the workflow stops
rather than continuing with an unsanitized or truncated path [13][19][22].

### 6.4 Space gate

Before the first scanner stage, compare the conservative free-space value from section 2.1 [3][17]
against the job's estimated requirement. If the value is unknown or insufficient, pause and
report; never redirect output to another volume (`AGENTS.md`).

## 7. Recommended implementation shape (no code in this lane)

Contracts for the implementation tasks that follow this research:

- `Get-RecoveryVolumeInventory` -> one object per volume: DriveLetter (or null) [12], AccessPaths
  [12], FileSystemLabel/FileSystem/Size/SizeRemaining [3], PartitionNumber [12], DiskNumber [12],
  and the nested disk identity record from section 2.6 [11]; plus an `EvidenceSource` field naming
  which provider produced it (Storage module [1][3][4], Storage namespace CIM [11][12], or
  Win32 fallback [10]).
- `Get-PhysicalDiskIdentity -DiskNumber <n>` -> the identity record, with `IsIndeterminate` set
  when a strong field is missing [11][8].
- `Test-DestinationSafety -SourceIdentity <r> -DestinationPath <p>` -> decision object with
  `Allowed` (bool), `ReasonCode` (one of: SamePhysicalDisk, SameVolume, SourceIndeterminate,
  DestinationIndeterminate, DestinationUnresolved, DestinationPathInvalid) and the evidence for
  both sides [3][11][12].
- `Select-DestinationFolder` -> documented picker first [14], typed-path fallback validated by the
  same resolver [3]; returns a path or a stop reason.
- `New-RecoveryJobFolder -RootPath <p> -ClientName <s>` -> sanitized name [13][21], length-checked
  [19], atomically claimed [18][22], bounded collision loop.
- Job state records the identity records and the decision, and re-verifies them on resume because
  disk numbers can change across restarts [11].

Manual gates this design exposes instead of guessing:

1. No Storage module (pre-Windows 8 / pre-Server 2012 surface) [5][11][12] and no usable Win32
   fallback [10].
2. Storage module present but no storage management provider, so `Get-PhysicalDisk` yields no
   physical disks [4][26].
3. Storage Spaces / File-Backed Virtual / dynamic-disk backing, where one volume has multiple or
   hidden backing disks [1][4][11].
4. Missing or duplicated serial/UniqueId on a USB bridge (identity indeterminate) [5][unverified].
5. No interactive picker available (non-interactive session or MTA host) [14][16].
6. Free space unknown or insufficient [3][17].

## 8. Verification plan for the implementation tasks

- Linux CI: Markdown/ASCII checks are trivial, but the real static contracts belong to the code
  tasks - PowerShell 5.1 parse checks, ASCII/no-BOM checks and safety-contract checks, per
  `AGENTS.md`.
- Pester: enumerate with mocked Storage-module and WMI output (including the indeterminate cases
  in section 3) and assert the refusal reason codes in section 4.
- Windows runner: assert that the Storage-module enumeration path returns at least one disk and
  that `Get-Volume -FilePath` round-trips for the runner's own working directory [3], so the
  destination resolver is exercised for real rather than mocked.
- Technician gate: a live case with a USB-attached source disk and a second physical destination
  disk, to confirm that the refusal fires for the same disk and does not fire for the other one.
  This cannot be proven in CI.

## 9. Known unknowns and manual boundary

Recorded explicitly because `AGENTS.md` requires it, rather than filled with guesses:

1. Elevation requirement of the Storage module enumeration cmdlets. The reference pages for
   Get-Disk, Get-Partition, Get-Volume and Get-PhysicalDisk do not state a privilege requirement
   [1][3][4], and this research found no Microsoft page stating that enumeration alone requires
   elevation. Community reports of access-denied on unelevated Storage cmdlets were seen but not
   corroborated by a primary source, so they are not relied on here [unverified]. The workflow
   keeps elevation as an explicit preflight gate (as `docs/WORKFLOW.md` requires) and checks it
   with the documented `WindowsPrincipal.IsInRole(WindowsBuiltInRole.Administrator)` test [24].
   What would settle it: a documented privilege note on the Storage cmdlet pages, or a
   reproducible observation on a clean Windows 10/11 machine.
2. Serial-number uniqueness and stability across USB bridges and dual-bay enclosures
   [unverified]. The design tolerates it by refusing when strong identity fields are missing or
   ambiguous [11].
3. The filesystem path of the Folder object returned by `Shell.BrowseForFolder` is not documented
   on the Folder object page [25]. What would settle it: a Microsoft page documenting the
   property, which is why that picker is not used for the safety gate.
4. Whether the MTA apartment state actually prevents the folder dialog from appearing was not
   verified [unverified]; the design avoids the question by not forcing `-Mta` [16] and by having
   a typed-path fallback [3].
5. Vendor (File Scavenger, R-Studio) behaviour is out of scope for this lane and remains a
   separate evidence lane and a technician gate.

Sources are listed below; numbering follows the inline citations. All references were retrieved
on 2026-09-16 from learn.microsoft.com.

## Sources

[1] https://learn.microsoft.com/en-us/powershell/module/storage/get-disk?view=windowsserver2025-ps
[2] https://learn.microsoft.com/en-us/powershell/module/storage/get-partition?view=windowsserver2025-ps
[3] https://learn.microsoft.com/en-us/powershell/module/storage/get-volume?view=windowsserver2025-ps
[4] https://learn.microsoft.com/en-us/powershell/module/storage/get-physicaldisk?view=windowsserver2025-ps
[5] https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-physicaldisk
[6] https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logicaldisktopartition
[7] https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrivetodiskpartition
[8] https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-diskdrive
[9] https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logicaldisk
[10] https://learn.microsoft.com/en-us/windows/win32/wmisdk/wmi-tasks--disks-and-file-systems
[11] https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-disk
[12] https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition
[13] https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
[14] https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.folderbrowserdialog
[15] https://learn.microsoft.com/en-us/windows/win32/shell/shell-browseforfolder
[16] https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1
[17] https://learn.microsoft.com/en-us/dotnet/api/system.io.driveinfo.availablefreespace
[18] https://learn.microsoft.com/en-us/dotnet/api/system.io.filemode
[19] https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
[20] https://learn.microsoft.com/en-us/windows/win32/shell/library-be-library-aware
[21] https://learn.microsoft.com/en-us/dotnet/api/system.io.path.getinvalidfilenamechars
[22] https://learn.microsoft.com/en-us/dotnet/api/system.io.directory.createdirectory
[23] https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference
[24] https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsprincipal.isinrole?view=netframework-4.8.1
[25] https://learn.microsoft.com/en-us/windows/win32/shell/folder
[26] https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/windows-storage-management-api-portal
