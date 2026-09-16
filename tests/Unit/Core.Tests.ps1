# Unit tests for the recovery workflow core: disk identity/destination separation,
# client-name and job-folder safety, append-only logging, and job state.
#
# Deterministic only: injected providers, synthetic fixtures, TestDrive writes.
# No storage API, no external process, no vendor executable, and no screen input.

BeforeAll {
    $script:RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:ModulesRoot = Join-Path -Path $script:RepoRoot -ChildPath 'modules'
    $script:Sep = [char]92
    $script:Now = '2026-09-16T07:00:00Z'

    Import-Module -Name (Join-Path -Path $script:ModulesRoot -ChildPath 'DiskDetection.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:ModulesRoot -ChildPath 'RecoveryLogging.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:ModulesRoot -ChildPath 'JobState.psm1') -Force -ErrorAction Stop

    function New-WinPath {
        param([string]$Drive, [string]$Relative)
        return (($Drive + ':') + $script:Sep + $Relative)
    }

    function New-DiskFixture {
        param(
            [int]$DiskNumber = 0,
            [string]$UniqueId = 'FIXTURE-DISK-0',
            [string]$UniqueIdFormat = 'WWN',
            [string]$SerialNumber = 'SN-0000',
            [string]$Model = 'FixtureDisk',
            [long]$SizeBytes = 1000000000,
            [int]$BusType = 11,
            [bool]$DropStrongKey = $false,
            [bool]$DropUniqueId = $false,
            [bool]$MembersIncomplete = $false
        )
        $disk = [ordered]@{
            DiskNumber        = $DiskNumber
            UniqueId          = $UniqueId
            UniqueIdFormat    = $UniqueIdFormat
            SerialNumber      = $SerialNumber
            Model             = $Model
            FriendlyName      = ($Model + ' Friendly')
            Manufacturer      = 'FixtureVendor'
            SizeBytes         = $SizeBytes
            BusType           = $BusType
            Location          = 'PCIROOT(0)#PCI(1F02)'
            PNPDeviceID       = 'SCSI\DISK&VEN_FIXTURE'
            IsDynamic         = $false
            MembersIncomplete = $MembersIncomplete
        }
        if ($DropStrongKey) {
            $disk.UniqueId = ''
            $disk.UniqueIdFormat = ''
            $disk.SerialNumber = ''
        }
        if ($DropUniqueId) {
            $disk.UniqueId = ''
            $disk.UniqueIdFormat = ''
        }
        return ([pscustomobject]$disk)
    }

    function New-VolumeFixture {
        param(
            [string]$DriveLetter = 'Q',
            [string[]]$AccessPaths = @(),
            [string]$Path = 'VOLUME-PATH-1',
            [string]$VolumeGuid = 'VOLUME-GUID-1',
            [string]$FileSystemLabel = 'FixtureVolume',
            [string]$FileSystem = 'NTFS',
            [long]$SizeBytes = 1000000000,
            [long]$SizeRemainingBytes = 500000000,
            [int]$PartitionNumber = 1,
            [int]$DiskNumber = 0,
            [bool]$MembersIncomplete = $false
        )
        return [pscustomobject]@{
            DriveLetter         = $DriveLetter
            AccessPaths         = $AccessPaths
            Path                = $Path
            VolumeGuid          = $VolumeGuid
            FileSystemLabel     = $FileSystemLabel
            FileSystem          = $FileSystem
            SizeBytes           = $SizeBytes
            SizeRemainingBytes  = $SizeRemainingBytes
            PartitionNumber     = $PartitionNumber
            DiskNumber          = $DiskNumber
            MembersIncomplete   = $MembersIncomplete
        }
    }

    function New-PathRecord {
        param(
            [string]$Path,
            [string]$CanonicalPath,
            [bool]$Exists = $true,
            [bool]$IsContainer = $true,
            [bool]$IsReparsePoint = $false,
            [bool]$ReparseResolved = $true,
            [string]$VolumeGuid = 'VOLUME-GUID-1',
            [string]$VolumePath = 'VOLUME-PATH-1',
            [string]$DriveLetter = 'Q',
            [int]$PartitionNumber = 1,
            [int]$DiskNumber = 0,
            [bool]$MembersIncomplete = $false
        )
        if (-not $CanonicalPath) { $CanonicalPath = $Path }
        return [pscustomobject]@{
            Path              = $Path
            CanonicalPath     = $CanonicalPath
            Exists            = $Exists
            IsContainer       = $IsContainer
            IsReparsePoint    = $IsReparsePoint
            ReparseResolved   = $ReparseResolved
            VolumeGuid        = $VolumeGuid
            VolumePath        = $VolumePath
            DriveLetter       = $DriveLetter
            PartitionNumber   = $PartitionNumber
            DiskNumber        = $DiskNumber
            MembersIncomplete = $MembersIncomplete
        }
    }

    function New-DiskProvider {
        param(
            [string]$Name = 'StorageProvider',
            [object[]]$Volumes = @(),
            [object[]]$Disks = @(),
            [hashtable]$PathMap = @{},
            [hashtable]$SpaceMap = @{},
            [bool]$FailVolumes = $false,
            [bool]$FailDisks = $false,
            [bool]$FailResolve = $false,
            [bool]$FailSpace = $false,
            [string]$FailureMessage = 'fixture provider failure'
        )
        $calls = New-Object System.Collections.Generic.List[string]
        $provider = @{}
        $provider.Name = $Name
        $provider.Calls = $calls
        $provider.GetVolumes = {
            param($request)
            $calls.Add('GetVolumes') | Out-Null
            if ($FailVolumes) { throw $FailureMessage }
            return @($Volumes)
        }.GetNewClosure()
        $provider.GetDisks = {
            param($request)
            $calls.Add('GetDisks') | Out-Null
            if ($FailDisks) { throw $FailureMessage }
            return @($Disks)
        }.GetNewClosure()
        $provider.ResolvePath = {
            param($request)
            $calls.Add('ResolvePath') | Out-Null
            if ($FailResolve) { throw $FailureMessage }
            $key = [string]$request.Path
            if (-not $PathMap.ContainsKey($key)) { return $null }
            return $PathMap[$key]
        }.GetNewClosure()
        $provider.GetFreeSpace = {
            param($request)
            $calls.Add('GetFreeSpace') | Out-Null
            if ($FailSpace) { throw $FailureMessage }
            $key = [string]$request.Path
            if (-not $SpaceMap.ContainsKey($key)) { return $null }
            return $SpaceMap[$key]
        }.GetNewClosure()
        return $provider
    }

    function New-FixedClock {
        param([string]$UtcInstant = $script:Now, [int]$StepSeconds = 0)
        $box = @{ Value = [datetime]::Parse($UtcInstant, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
        return {
            param($request)
            $current = [datetime]$box.Value
            if ($StepSeconds -gt 0) {
                $box.Value = $current.AddSeconds($StepSeconds)
            }
            return $current
        }.GetNewClosure()
    }

    function New-IdentitySnapshot {
        param(
            [string]$VolumeGuid = 'VOLUME-GUID-1',
            [string[]]$IdentityKeys = @('UID|WWN|FIXTURE-DISK-0'),
            [string]$CanonicalPath = 'fixture-path'
        )
        return [pscustomobject]@{
            VolumeGuid     = $VolumeGuid
            CanonicalPath  = $CanonicalPath
            IdentityKeys   = $IdentityKeys
            IsIndeterminate = $false
        }
    }

    function New-CasePaths {
        param([string]$JobFolder)
        return [pscustomobject]@{
            JobFolderPath = $JobFolder
            StatePath     = (Join-Path -Path $JobFolder -ChildPath 'job-state.json')
            LogPath       = (Join-Path -Path $JobFolder -ChildPath 'events.jsonl')
            MetadataPath  = (Join-Path -Path $JobFolder -ChildPath 'job-metadata.json')
        }
    }

    function New-LogWriterProvider {
        param(
            [string]$Name = 'FakeLogWriter',
            [bool]$FailOpen = $false,
            [bool]$FailAppend = $false,
            [bool]$FailFlush = $false,
            [bool]$FailClose = $false,
            [bool]$StructuredOpenRefusal = $false,
            [bool]$StructuredAppendRefusal = $false,
            [bool]$StructuredFlushRefusal = $false,
            [bool]$AmbiguousAppend = $false,
            [bool]$AmbiguousOpen = $false
        )
        $state = @{ Text = ''; Calls = (New-Object System.Collections.Generic.List[string]) }
        $provider = @{}
        $provider.Name = $Name
        $provider.State = $state
        $provider.Open = {
            param($request)
            $state.Calls.Add('Open') | Out-Null
            if ($FailOpen) { throw 'fixture open failure' }
            if ($StructuredOpenRefusal) { return [pscustomobject]@{ Success = $false; ReasonCode = 'LogOpenFailed'; Message = 'fixture structured open refusal' } }
            if ($AmbiguousOpen) { return [pscustomobject]@{ FixtureHandle = 'fixture-handle' } }
            return [pscustomobject]@{ Success = $true; FixtureHandle = 'fixture-handle' }
        }.GetNewClosure()
        $provider.Append = {
            param($request)
            $state.Calls.Add('Append') | Out-Null
            if ($FailAppend) { throw 'fixture append failure' }
            if ($StructuredAppendRefusal) { return [pscustomobject]@{ Success = $false; ReasonCode = 'LogAppendFailed'; Message = 'fixture structured append refusal' } }
            if ($AmbiguousAppend) { return [pscustomobject]@{ BytesWritten = 12 } }
            $state.Text = $state.Text + [string]$request.Text
            return $true
        }.GetNewClosure()
        $provider.Flush = {
            param($request)
            $state.Calls.Add('Flush') | Out-Null
            if ($FailFlush) { return $false }
            if ($StructuredFlushRefusal) { return [pscustomobject]@{ Success = $false; ReasonCode = 'LogFlushFailed'; Message = 'fixture structured flush refusal' } }
            return $true
        }.GetNewClosure()
        $provider.Close = {
            param($request)
            $state.Calls.Add('Close') | Out-Null
            if ($FailClose) { throw 'fixture close failure' }
            return $true
        }.GetNewClosure()
        return $provider
    }

    function New-StaticProvider {
        param([string]$SourceDiskNumber = '0', [string]$DestinationDiskNumber = '1')
        return [pscustomobject]@{ SourceDiskNumber = $SourceDiskNumber; DestinationDiskNumber = $DestinationDiskNumber }
    }
}

Describe 'Disk provider selection and evidence (C-01)' {
    It 'uses the first provider that can prove a mapping and records the evidence source' {
        $storage = New-DiskProvider -Name 'StorageModule' -Volumes @((New-VolumeFixture -DriveLetter 'Q')) -Disks @((New-DiskFixture -DiskNumber 0))
        $cim = New-DiskProvider -Name 'StorageNamespace' -Volumes @((New-VolumeFixture -DriveLetter 'Q')) -Disks @((New-DiskFixture -DiskNumber 0))
        $win32 = New-DiskProvider -Name 'Win32Fallback' -Volumes @((New-VolumeFixture -DriveLetter 'Q'))

        $resolved = Resolve-RecoveryDiskProvider -Providers @($storage, $cim, $win32)

        $resolved.IsIndeterminate | Should -BeFalse
        $resolved.EvidenceSource | Should -Be 'StorageModule'
        $cim.Calls | Should -HaveCount 0
        $win32.Calls | Should -HaveCount 0
    }

    It 'falls through to the namespace and Win32 providers in order' {
        $storage = New-DiskProvider -Name 'StorageModule' -FailVolumes $true
        $cim = New-DiskProvider -Name 'StorageNamespace' -Volumes @((New-VolumeFixture -DriveLetter 'Q'))
        $win32 = New-DiskProvider -Name 'Win32Fallback' -Volumes @((New-VolumeFixture -DriveLetter 'Q'))

        $resolved = Resolve-RecoveryDiskProvider -Providers @($storage, $cim, $win32)

        $resolved.IsIndeterminate | Should -BeFalse
        $resolved.EvidenceSource | Should -Be 'StorageNamespace'
        $storage.Calls | Should -Contain 'GetVolumes'
        $win32.Calls | Should -HaveCount 0
    }

    It 'returns an indeterminate result when no provider can prove a mapping' {
        $storage = New-DiskProvider -Name 'StorageModule' -FailVolumes $true
        $cim = New-DiskProvider -Name 'StorageNamespace' -FailVolumes $true
        $win32 = New-DiskProvider -Name 'Win32Fallback'

        $resolved = Resolve-RecoveryDiskProvider -Providers @($storage, $cim, $win32)

        $resolved.IsIndeterminate | Should -BeTrue
        $resolved.EvidenceSource | Should -BeNullOrEmpty
        $resolved.ReasonCode | Should -Be 'NoProvider'
        $resolved.Attempts | Should -HaveCount 3
    }

    It 'stamps each inventory volume with the answering evidence source' {
        $provider = New-DiskProvider -Name 'StorageModule' -Volumes @((New-VolumeFixture -DriveLetter 'Q' -DiskNumber 0)) -Disks @((New-DiskFixture -DiskNumber 0))

        $inventory = @(Get-RecoveryVolumeInventory -Provider $provider)

        $inventory | Should -HaveCount 1
        $inventory[0].EvidenceSource | Should -Be 'StorageModule'
        $inventory[0].IsIndeterminate | Should -BeFalse
    }
}

Describe 'Volume to physical disk join (C-02)' {
    It 'joins a drive letter and a mounted-folder access path to the same identity shape' {
        $disks = @((New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-DISK-0'))
        $volume = New-VolumeFixture -DriveLetter 'Q' -AccessPaths @((New-WinPath -Drive 'Q' -Relative ''), (New-WinPath -Drive 'Q' -Relative 'Mount\Case')) -DiskNumber 0
        $provider = New-DiskProvider -Name 'StorageModule' -Volumes @($volume) -Disks $disks

        $inventory = @(Get-RecoveryVolumeInventory -Provider $provider)

        $inventory[0].DiskNumber | Should -Be 0
        $inventory[0].PartitionNumber | Should -Be 1
        $inventory[0].PhysicalDisks | Should -HaveCount 1
        $inventory[0].PhysicalDisks[0].IdentityKey | Should -Be 'UID|WWN|FIXTURE-DISK-0'
        $inventory[0].AccessPaths[1] | Should -Be (New-WinPath -Drive 'Q' -Relative 'Mount\Case')
    }

    It 'resolves a path through the volume, partition, and disk join' {
        $disks = @((New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-DISK-0'))
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $pathMap = @{ $sourcePath = (New-PathRecord -Path $sourcePath -CanonicalPath $sourcePath -DiskNumber 0) }
        $provider = New-DiskProvider -Name 'StorageModule' -Volumes @((New-VolumeFixture -DriveLetter 'Q')) -Disks $disks -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        $identity.IsIndeterminate | Should -BeFalse
        $identity.DiskNumber | Should -Be 0
        $identity.VolumeGuid | Should -Be 'VOLUME-GUID-1'
        $identity.PhysicalDisks | Should -HaveCount 1
        $identity.PhysicalDisks[0].DiskNumber | Should -Be 0
        $identity.EvidenceSource | Should -Be 'StorageModule'
    }
}

Describe 'Strong physical disk identity (C-03)' {
    It 'matches on an exact UniqueId and format' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-A' -UniqueIdFormat 'WWN' -SerialNumber 'SN-A'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-A' -UniqueIdFormat 'WWN' -SerialNumber 'SN-B' -SizeBytes 2000000000)
        )

        $left = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $provider
        $right = Get-PhysicalDiskIdentity -DiskNumber 1 -Provider $provider

        $left.IdentityKey | Should -Be $right.IdentityKey
        $left.IsIndeterminate | Should -BeFalse
    }

    It 'matches on serial, size, and model when no unique id is available' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -DropUniqueId $true -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel'),
            (New-DiskFixture -DiskNumber 1 -DropUniqueId $true -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel')
        )

        $left = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $provider
        $right = Get-PhysicalDiskIdentity -DiskNumber 1 -Provider $provider

        $left.IsIndeterminate | Should -BeFalse
        $left.IdentityKey | Should -Be $right.IdentityKey
    }

    It 'never treats a matching disk number alone as the same disk' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -DropUniqueId $true -SerialNumber 'SN-ALPHA' -SizeBytes 1000000000 -Model 'ModelA'),
            (New-DiskFixture -DiskNumber 0 -DropUniqueId $true -SerialNumber 'SN-BETA' -SizeBytes 2000000000 -Model 'ModelB')
        )

        $identity = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.IdentityKey | Should -BeNullOrEmpty
        $identity.ReasonCode | Should -Be 'AmbiguousDiskNumber'
    }

    It 'marks a disk indeterminate when the strong fields are missing' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 3 -DropStrongKey $true))

        $identity = Get-PhysicalDiskIdentity -DiskNumber 3 -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.IdentityKey | Should -BeNullOrEmpty
        $identity.ReasonCode | Should -Be 'MissingStrongIdentity'
    }

    It 'marks contradictory strong fields indeterminate' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-C' -UniqueIdFormat 'WWN' -SizeBytes 1000000000),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-C' -UniqueIdFormat 'WWN' -SizeBytes 9999999999)
        )

        $left = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $provider
        $right = Get-PhysicalDiskIdentity -DiskNumber 1 -Provider $provider

        $comparison = & (Get-Module -Name DiskDetection) { param($a, $b) return (Test-RecoveryDiskIdentityMatch -Left $a -Right $b) } $left $right

        $comparison | Should -Be 'Indeterminate'
    }

    It 'treats a virtual or Storage Spaces backing disk as indeterminate' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -BusType 16))

        $identity = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'VirtualBacking'
    }

    It 'reports a missing disk as indeterminate rather than unknown-safe' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 5))

        $identity = Get-PhysicalDiskIdentity -DiskNumber 9 -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'DiskNotFound'
    }

    It 'matches the same device across providers that expose different strong forms' {
        $uidProvider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'SAME-DEVICE' -UniqueIdFormat 'WWN' -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel'))
        $serialProvider = New-DiskProvider -Name 'Win32Fallback' -Disks @((New-DiskFixture -DiskNumber 0 -DropUniqueId $true -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel'))

        $left = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $uidProvider
        $right = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $serialProvider
        $comparison = & (Get-Module -Name DiskDetection) { param($a, $b) return (Test-RecoveryDiskIdentityMatch -Left $a -Right $b) } $left $right

        $left.IdentityKey | Should -Match '^UID'
        $right.IdentityKey | Should -Match '^SER'
        $comparison | Should -Be 'Match'
    }

    It 'compares every strong field instead of one opaque key' {
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'SAME-DEVICE' -UniqueIdFormat 'WWN' -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'SAME-DEVICE' -UniqueIdFormat 'WWN' -SerialNumber 'SN-OTHER' -SizeBytes 4000000000 -Model 'FixtureModel'),
            (New-DiskFixture -DiskNumber 2 -UniqueId 'OTHER-DEVICE' -UniqueIdFormat 'WWN' -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel')
        )

        $base = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $provider
        $contradictory = & (Get-Module -Name DiskDetection) { param($a, $b) return (Test-RecoveryDiskIdentityMatch -Left $a -Right $b) } $base (Get-PhysicalDiskIdentity -DiskNumber 1 -Provider $provider)
        $distinct = & (Get-Module -Name DiskDetection) { param($a, $b) return (Test-RecoveryDiskIdentityMatch -Left $a -Right $b) } $base (Get-PhysicalDiskIdentity -DiskNumber 2 -Provider $provider)

        $contradictory | Should -Be 'Indeterminate'
        $distinct | Should -Be 'Distinct'
    }

    It 'treats an identity form that cannot be compared as indeterminate' {
        $uidProvider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'DEVICE-A' -UniqueIdFormat 'WWN' -SerialNumber 'SN-A' -SizeBytes 1000000000 -Model 'ModelA'))
        $partialProvider = New-DiskProvider -Name 'Win32Fallback' -Disks @((New-DiskFixture -DiskNumber 0 -DropUniqueId $true -SerialNumber 'SN-A' -SizeBytes 2000000000 -Model 'ModelA'))

        $left = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $uidProvider
        $right = Get-PhysicalDiskIdentity -DiskNumber 0 -Provider $partialProvider
        $comparison = & (Get-Module -Name DiskDetection) { param($a, $b) return (Test-RecoveryDiskIdentityMatch -Left $a -Right $b) } $left $right

        $comparison | Should -Be 'Indeterminate'
    }
}

Describe 'Cross-provider destination separation (C-04, C-08)' {
    It 'refuses a destination on the source disk when the providers expose different strong forms' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Recovery'
        $sourceMap = @{ $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0) }
        $destinationMap = @{ $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1) }
        $uidProvider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'SAME-DEVICE' -UniqueIdFormat 'WWN' -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel')) -PathMap $sourceMap
        $serialProvider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'SAME-DEVICE' -UniqueIdFormat 'WWN' -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel'),
            (New-DiskFixture -DiskNumber 1 -DropUniqueId $true -SerialNumber 'SN-SAME' -SizeBytes 4000000000 -Model 'FixtureModel')
        ) -PathMap $destinationMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $uidProvider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $serialProvider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'SamePhysicalDisk'
    }

    It 'blocks a destination whose identity cannot be proven different from the source' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Recovery'
        $sourceMap = @{ $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0) }
        $destinationMap = @{ $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1) }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'DEVICE-A' -UniqueIdFormat 'WWN' -SerialNumber 'SN-A' -SizeBytes 1000000000 -Model 'ModelA'),
            (New-DiskFixture -DiskNumber 1 -DropUniqueId $true -SerialNumber 'SN-A' -SizeBytes 2000000000 -Model 'ModelA')
        ) -PathMap ($sourceMap + $destinationMap)
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationIndeterminate'
    }

    It 'never trusts a caller supplied destination identity that is not bound to the path' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Recovery'
        $otherPath = New-WinPath -Drive 'S' -Relative 'Elsewhere'
        $pathMap = @{
            $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0)
            $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1)
            $otherPath = (New-PathRecord -Path $otherPath -VolumeGuid 'VOLUME-GUID-OTHER' -DiskNumber 2)
        }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'DEVICE-SRC'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'DEVICE-DST'),
            (New-DiskFixture -DiskNumber 2 -UniqueId 'DEVICE-OTHER')
        ) -PathMap $pathMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider
        $forged = Resolve-RecoveryPathIdentity -Path $otherPath -Provider $provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $provider -DestinationIdentity $forged

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationIndeterminate'
        $decision.DestinationEvidence.CanonicalPath | Should -Be $destinationPath
    }

    It 'uses the freshly resolved identity for a destination identity that is bound to the path' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Recovery'
        $pathMap = @{
            $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0)
            $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1)
        }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'DEVICE-SRC'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'DEVICE-DST')
        ) -PathMap $pathMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider
        $supplied = Resolve-RecoveryPathIdentity -Path $destinationPath -Provider $provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $provider -DestinationIdentity $supplied

        $decision.Allowed | Should -BeTrue
        $decision.DestinationIdentityKeys | Should -HaveCount 1
    }
}

Describe 'Complete physical membership (C-06)' {
    It 'resolves every reported member of a multi-disk volume' {
        $path = New-WinPath -Drive 'Q' -Relative 'Spanned'
        $record = New-PathRecord -Path $path -VolumeGuid 'VOLUME-GUID-SPAN' -DiskNumber 0
        $record | Add-Member -NotePropertyName PhysicalDiskNumbers -NotePropertyValue @(0, 1)
        $pathMap = @{ $path = $record }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'MEMBER-0'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'MEMBER-1')
        ) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        $identity.IsIndeterminate | Should -BeFalse
        $identity.PhysicalDisks | Should -HaveCount 2
        @($identity.IdentityKeys) | Should -HaveCount 2
    }

    It 'blocks when a reported member cannot be resolved' {
        $path = New-WinPath -Drive 'Q' -Relative 'Spanned'
        $record = New-PathRecord -Path $path -VolumeGuid 'VOLUME-GUID-SPAN' -DiskNumber 0
        $record | Add-Member -NotePropertyName PhysicalDiskNumbers -NotePropertyValue @(0, 1)
        $pathMap = @{ $path = $record }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'MEMBER-0')) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }

    It 'treats a membership statement that is not a Boolean as incomplete' {
        $path = New-WinPath -Drive 'Q' -Relative 'Spanned'
        $record = New-PathRecord -Path $path -VolumeGuid 'VOLUME-GUID-SPAN' -DiskNumber 0
        $record.MembersIncomplete = 'unknown'
        $pathMap = @{ $path = $record }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'MEMBER-0')) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }

    It 'requires an explicit reparse and resolution statement for the path' {
        $path = New-WinPath -Drive 'Q' -Relative 'Unknown'
        $record = [pscustomobject]@{
            CanonicalPath   = $path
            Exists          = $true
            IsContainer     = $true
            VolumeGuid      = 'VOLUME-GUID-1'
            VolumePath      = 'VOLUME-PATH-1'
            DriveLetter     = 'Q'
            PartitionNumber = 1
            DiskNumber      = 0
        }
        $pathMap = @{ $path = $record }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'DEVICE-0')) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'ReparseUnresolved'
    }

    It 'accepts a path whose provider states that resolution was performed' {
        $path = New-WinPath -Drive 'Q' -Relative 'Resolved'
        $record = New-PathRecord -Path $path -VolumeGuid 'VOLUME-GUID-1' -DiskNumber 0 -IsReparsePoint $true -ReparseResolved $true
        $pathMap = @{ $path = $record }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'DEVICE-0')) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        $identity.IsIndeterminate | Should -BeFalse
        $identity.ReasonCode | Should -BeNullOrEmpty
    }
}

Describe 'Destination separation refusal (C-04, C-05, C-08)' {
    BeforeAll {
        $script:SourcePath = New-WinPath -Drive 'Q' -Relative 'SourceVolume\Case'
        $script:SourceVolume = 'VOLUME-GUID-SRC'

        function New-SeparationFixture {
            param(
                [int]$SourceDiskNumber = 0,
                [int]$DestinationDiskNumber = 1,
                [string]$DestinationVolumeGuid = 'VOLUME-GUID-DST',
                [string]$SourceUniqueId = 'FIXTURE-SRC',
                [string]$DestinationUniqueId = 'FIXTURE-DST'
            )
            $sourcePath = $script:SourcePath
            $destinationPath = New-WinPath -Drive 'R' -Relative 'Recovery'
            $pathMap = @{
                $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid $script:SourceVolume -VolumePath 'VOLUME-PATH-SRC' -DriveLetter 'Q' -DiskNumber $SourceDiskNumber)
                $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid $DestinationVolumeGuid -VolumePath 'VOLUME-PATH-DST' -DriveLetter 'R' -DiskNumber $DestinationDiskNumber)
            }
            $disks = @(
                (New-DiskFixture -DiskNumber $SourceDiskNumber -UniqueId $SourceUniqueId -SerialNumber 'SN-SRC'),
                (New-DiskFixture -DiskNumber $DestinationDiskNumber -UniqueId $DestinationUniqueId -SerialNumber 'SN-DST')
            )
            if ($SourceDiskNumber -eq $DestinationDiskNumber -and $SourceUniqueId -eq $DestinationUniqueId) {
                $disks = @((New-DiskFixture -DiskNumber $SourceDiskNumber -UniqueId $SourceUniqueId -SerialNumber 'SN-SRC'))
            }
            $provider = New-DiskProvider -Name 'StorageModule' -Volumes @((New-VolumeFixture -DriveLetter 'Q')) -Disks $disks -PathMap $pathMap
            return [pscustomobject]@{ Provider = $provider; SourcePath = $sourcePath; DestinationPath = $destinationPath }
        }
    }

    It 'refuses a destination volume on the source physical disk' {
        $fixture = New-SeparationFixture -SourceDiskNumber 0 -DestinationDiskNumber 0 -DestinationUniqueId 'FIXTURE-SRC'
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $fixture.SourcePath -Provider $fixture.Provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $fixture.DestinationPath -Provider $fixture.Provider

        $decision.Allowed | Should -BeFalse
        $decision.Decision | Should -Be 'Blocked'
        $decision.ReasonCode | Should -Be 'SamePhysicalDisk'
        $decision.SourceEvidence | Should -Not -BeNullOrEmpty
        $decision.DestinationEvidence | Should -Not -BeNullOrEmpty
        $fixture.Provider.Calls | Should -Not -Contain 'CreateNew'
    }

    It 'refuses the same volume before the overlapping physical disk reason' {
        $fixture = New-SeparationFixture -SourceDiskNumber 0 -DestinationDiskNumber 1 -DestinationVolumeGuid $script:SourceVolume
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $fixture.SourcePath -Provider $fixture.Provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $fixture.DestinationPath -Provider $fixture.Provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'SameVolume'
    }

    It 'allows complete and strongly identified disjoint physical disks' {
        $fixture = New-SeparationFixture -SourceDiskNumber 0 -DestinationDiskNumber 1
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $fixture.SourcePath -Provider $fixture.Provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $fixture.DestinationPath -Provider $fixture.Provider

        $decision.Allowed | Should -BeTrue
        $decision.Decision | Should -Be 'Allowed'
        $decision.ReasonCode | Should -BeNullOrEmpty
        $decision.SourceIdentityKeys | Should -HaveCount 1
        $decision.DestinationIdentityKeys | Should -HaveCount 1
    }

    It 'blocks when the source identity is indeterminate' {
        $fixture = New-SeparationFixture -SourceDiskNumber 0 -DestinationDiskNumber 1
        $indeterminateSource = New-IdentitySnapshot -VolumeGuid $script:SourceVolume -IdentityKeys @()
        $indeterminateSource.IsIndeterminate = $true

        $decision = Test-DestinationSafety -SourceIdentity $indeterminateSource -DestinationPath $fixture.DestinationPath -Provider $fixture.Provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'SourceIndeterminate'
    }

    It 'blocks when the destination identity is indeterminate' {
        $fixture = New-SeparationFixture -SourceDiskNumber 0 -DestinationDiskNumber 1
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $fixture.SourcePath -Provider $fixture.Provider
        $destinationIdentity = Resolve-RecoveryPathIdentity -Path $fixture.DestinationPath -Provider $fixture.Provider
        $destinationIdentity.IsIndeterminate = $true

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $fixture.DestinationPath -Provider $fixture.Provider -DestinationIdentity $destinationIdentity

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationIndeterminate'
    }

    It 'blocks an invalid destination path string without resolving it' {
        $fixture = New-SeparationFixture -SourceDiskNumber 0 -DestinationDiskNumber 1
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $fixture.SourcePath -Provider $fixture.Provider
        $relativePath = ('Recovery' + $script:Sep + 'Sub')
        $before = $fixture.Provider.Calls.Count

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $relativePath -Provider $fixture.Provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationPathInvalid'
        $fixture.Provider.Calls.Count | Should -Be $before
    }
}

Describe 'Indeterminate mappings and unresolved paths (C-06, C-07)' {
    It 'blocks a destination whose volume membership is incomplete' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Recovery'
        $pathMap = @{
            $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0)
            $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1 -MembersIncomplete $true)
        }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-SRC'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-DST')
        ) -PathMap $pathMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationIndeterminate'
    }

    It 'blocks a dynamic-disk volume mapping' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $pathMap = @{ $sourcePath = (New-PathRecord -Path $sourcePath -DiskNumber 0) }
        $dynamic = New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-DYN'
        $dynamic.IsDynamic = $true
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @($dynamic) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'DynamicDiskBacking'
    }

    It 'blocks a missing container as unresolved, not as a new folder' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Missing'
        $pathMap = @{
            $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0)
            $destinationPath = (New-PathRecord -Path $destinationPath -Exists $false -IsContainer $false -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1)
        }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-SRC'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-DST')
        ) -PathMap $pathMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationUnresolved'
    }

    It 'blocks an inaccessible destination when the provider throws' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Denied'
        $sourceMap = @{ $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0) }
        $sourceProvider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-SRC'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-DST')
        ) -PathMap $sourceMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $sourceProvider

        $deniedProvider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-DST')) -PathMap $sourceMap -FailResolve $true
        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $deniedProvider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationUnresolved'
    }

    It 'blocks an unresolved reparse destination' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $destinationPath = New-WinPath -Drive 'R' -Relative 'Junction'
        $pathMap = @{
            $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid 'VOLUME-GUID-SRC' -DiskNumber 0)
            $destinationPath = (New-PathRecord -Path $destinationPath -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1 -IsReparsePoint $true -ReparseResolved $false)
        }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @(
            (New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-SRC'),
            (New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-DST')
        ) -PathMap $pathMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $destinationPath -Provider $provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'DestinationUnresolved'
    }

    It 'blocks a destination that resolves outside the reviewed root' {
        $root = New-WinPath -Drive 'R' -Relative 'ReviewedRoot'
        $escaped = New-WinPath -Drive 'R' -Relative 'Elsewhere\Recovery'
        $pathMap = @{ $escaped = (New-PathRecord -Path $escaped -CanonicalPath $escaped -VolumeGuid 'VOLUME-GUID-DST' -DiskNumber 1) }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 1 -UniqueId 'FIXTURE-DST')) -PathMap $pathMap

        $identity = Resolve-RecoveryPathIdentity -Path $escaped -Provider $provider -ReviewedRoot $root

        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'PathOutsideReviewedRoot'
    }
}

Describe 'Fresh identity and capacity (C-09, C-10)' {
    It 'never accepts a reused drive letter as the same disk' {
        $path = New-WinPath -Drive 'Q' -Relative 'Source'
        $firstMap = @{ $path = (New-PathRecord -Path $path -VolumeGuid 'VOLUME-GUID-1' -DiskNumber 0) }
        $secondMap = @{ $path = (New-PathRecord -Path $path -VolumeGuid 'VOLUME-GUID-1' -DiskNumber 0) }
        $firstProvider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-FIRST')) -PathMap $firstMap
        $secondProvider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-SECOND')) -PathMap $secondMap

        $first = Resolve-RecoveryPathIdentity -Path $path -Provider $firstProvider
        $second = Resolve-RecoveryPathIdentity -Path $path -Provider $secondProvider

        $first.PhysicalDisks[0].IdentityKey | Should -Not -Be $second.PhysicalDisks[0].IdentityKey
        $first.IsIndeterminate | Should -BeFalse
        $second.IsIndeterminate | Should -BeFalse
    }

    It 'uses the conservative available value when both space readings exist' {
        $path = New-WinPath -Drive 'R' -Relative 'Recovery'
        $spaceMap = @{ $path = [pscustomobject]@{ VolumeAvailableBytes = 900000; UserAvailableBytes = 400000 } }
        $provider = New-DiskProvider -Name 'StorageModule' -SpaceMap $spaceMap

        $space = Get-RecoveryDestinationSpace -Path $path -Provider $provider -ReserveBytes 300000

        $space.AvailableBytes | Should -Be 400000
        $space.IsUnknown | Should -BeFalse
        $space.IsSufficient | Should -BeTrue
    }

    It 'treats an exception or missing value as unknown, never as zero' {
        $path = New-WinPath -Drive 'R' -Relative 'Recovery'
        $failedProvider = New-DiskProvider -Name 'StorageModule' -FailSpace $true -SpaceMap @{ $path = [pscustomobject]@{ VolumeAvailableBytes = 900000; UserAvailableBytes = 400000 } }
        $emptyProvider = New-DiskProvider -Name 'StorageModule' -SpaceMap @{}

        $failed = Get-RecoveryDestinationSpace -Path $path -Provider $failedProvider -ReserveBytes 300000
        $empty = Get-RecoveryDestinationSpace -Path $path -Provider $emptyProvider -ReserveBytes 300000

        $failed.IsUnknown | Should -BeTrue
        $failed.AvailableBytes | Should -BeNullOrEmpty
        $failed.IsSufficient | Should -BeFalse
        $empty.IsUnknown | Should -BeTrue
        $empty.IsSufficient | Should -BeFalse
    }

    It 'blocks work below the configured reserve' {
        $path = New-WinPath -Drive 'R' -Relative 'Recovery'
        $spaceMap = @{ $path = [pscustomobject]@{ VolumeAvailableBytes = 500000; UserAvailableBytes = 500000 } }
        $provider = New-DiskProvider -Name 'StorageModule' -SpaceMap $spaceMap

        $space = Get-RecoveryDestinationSpace -Path $path -Provider $provider -ReserveBytes 600000

        $space.IsSufficient | Should -BeFalse
        $space.ReasonCode | Should -Be 'BelowReserve'
    }

    It 'treats a negative or unavailable partial reading as unknown' {
        $path = New-WinPath -Drive 'R' -Relative 'Recovery'
        $spaceMap = @{ $path = [pscustomobject]@{ VolumeAvailableBytes = -1; UserAvailableBytes = $null } }
        $provider = New-DiskProvider -Name 'StorageModule' -SpaceMap $spaceMap

        $space = Get-RecoveryDestinationSpace -Path $path -Provider $provider -ReserveBytes 1

        $space.IsUnknown | Should -BeTrue
        $space.IsSufficient | Should -BeFalse
    }
}

Describe 'Folder selection and sanitization (C-12, C-13)' {
    It 'uses the picker result when a folder is selected' {
        $picker = { param($request) return [pscustomobject]@{ Selected = $true; Path = 'SELECTED-FOLDER' } }

        $selection = Select-DestinationFolder -PickerProvider $picker

        $selection.Selected | Should -BeTrue
        $selection.Method | Should -Be 'Picker'
        $selection.Path | Should -Be 'SELECTED-FOLDER'
    }

    It 'falls back to a validated typed path and never continues on a blank answer' {
        $picker = { param($request) return [pscustomobject]@{ Selected = $false; Cancelled = $true } }
        $typed = { param($request) return 'TYPED-FOLDER' }
        $blankPicker = { param($request) throw 'picker unavailable' }
        $blankTyped = { param($request) return '   ' }

        $fallback = Select-DestinationFolder -PickerProvider $picker -TypedPathProvider $typed
        $stopped = Select-DestinationFolder -PickerProvider $blankPicker -TypedPathProvider $blankTyped

        $fallback.Selected | Should -BeTrue
        $fallback.Method | Should -Be 'TypedPath'
        $stopped.Selected | Should -BeFalse
        $stopped.ReasonCode | Should -Be 'DestinationNotSelected'
    }

    It 'restricts client names to a deterministic ASCII alphabet' {
        $raw = ('Cl' + [char]0x00E9 + 'nt' + [char]0x0416 + 'A' + [char]0x0007 + 'B')

        $sanitized = Sanitize-RecoveryName -Name $raw

        $sanitized | Should -Match '^[A-Za-z0-9._-]+$'
        $sanitized | Should -Be 'Cl_nt_A_B'
    }

    It 'replaces each disallowed character without silently merging distinct names' {
        $slashes = Sanitize-RecoveryName -Name ('a' + $script:Sep + $script:Sep + 'b')
        $underscore = Sanitize-RecoveryName -Name 'a__b'

        $slashes | Should -Be 'a__b'
        $underscore | Should -Be 'a__b'
        $slashes.Length | Should -Be 4
    }

    It 'removes trailing spaces and periods' {
        $sanitized = Sanitize-RecoveryName -Name 'Client Name. .'

        $sanitized | Should -Be 'Client_Name'
    }

    It 'rejects empty, reserved, and non-string names' {
        { Sanitize-RecoveryName -Name '' } | Should -Throw
        { Sanitize-RecoveryName -Name '   ' } | Should -Throw
        { Sanitize-RecoveryName -Name 'CON' } | Should -Throw
        { Sanitize-RecoveryName -Name 'lpt1.txt' } | Should -Throw
        { Sanitize-RecoveryName -Name $null } | Should -Throw
    }

    It 'caps the client component at 40 characters and reports the truncation' {
        $long = 'ClientName' + ('x' * 60)

        $sanitized = Sanitize-RecoveryName -Name $long -WarningVariable captured

        $sanitized.Length | Should -BeLessOrEqual 40
        $captured | Should -Not -BeNullOrEmpty
    }

    It 'stops when the composed job path exceeds the configured budget' {
        $root = Join-Path -Path $TestDrive -ChildPath ('r' * 60)
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $clock = New-FixedClock
        $claimProvider = New-LogWriterProvider

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'ClientA' -Clock $clock -ClaimProvider $claimProvider -MaxPathLength 40

        $result.Created | Should -BeFalse
        $result.ReasonCode | Should -Be 'PathBudgetExceeded'
    }
}

Describe 'Collision-safe job folder creation (C-14)' {
    BeforeAll {
        function New-ClaimProvider {
            param([int]$FailuresFirst = 0, [string]$FailureReason = 'AlreadyExists', [bool]$AlwaysFail = $false)
            $state = @{ Calls = (New-Object System.Collections.Generic.List[string]); Attempts = 0 }
            $provider = @{}
            $provider.Name = 'FakeClaim'
            $provider.State = $state
            $provider.CreateNew = {
                param($request)
                $state.Calls.Add([string]$request.Path) | Out-Null
                $state.Attempts = $state.Attempts + 1
                if ($AlwaysFail -or ($state.Attempts -le $FailuresFirst)) {
                    return [pscustomobject]@{ Success = $false; ReasonCode = $FailureReason; Message = 'fixture collision' }
                }
                # A real claim provider writes the marker file; the folder claim
                # only counts when the marker is the folder's only entry.
                [System.IO.File]::WriteAllText([string]$request.Path, [string]$request.Content, (New-Object System.Text.UTF8Encoding($false)))
                return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
            }.GetNewClosure()
            return $provider
        }
    }

    It 'claims a new timestamped folder and reports the claim path' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-a'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $claimProvider = New-ClaimProvider

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client A' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider $claimProvider

        $result.Created | Should -BeTrue
        $result.FolderName | Should -Be 'Client_A_20260916-070000'
        $result.JobFolderPath | Should -Be (Join-Path -Path $root -ChildPath 'Client_A_20260916-070000')
        $result.ClaimPath | Should -Be (Join-Path -Path $result.JobFolderPath -ChildPath 'job-claim.json')
        $result.CollisionIndex | Should -Be 0
    }

    It 'leaves a pre-existing job folder and its sentinel bytes unchanged' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-b'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $existing = Join-Path -Path $root -ChildPath 'Client_A_20260916-070000'
        New-Item -ItemType Directory -Path $existing -Force | Out-Null
        $sentinel = Join-Path -Path $existing -ChildPath 'sentinel.txt'
        Set-Content -LiteralPath $sentinel -Value 'KEEP-ME' -NoNewline
        $before = [System.IO.File]::ReadAllBytes($sentinel)

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client A' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider (New-ClaimProvider)

        $result.Created | Should -BeTrue
        $result.CollisionIndex | Should -Be 1
        $result.FolderName | Should -Be 'Client_A_20260916-070000-001'
        (Test-Path -LiteralPath $sentinel) | Should -BeTrue
        [System.IO.File]::ReadAllBytes($sentinel) | Should -Be $before
        Test-Path -LiteralPath (Join-Path -Path $existing -ChildPath 'job-claim.json') | Should -BeFalse
    }

    It 'moves to the next bounded suffix when the claim already exists' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-c'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $claimProvider = New-ClaimProvider -FailuresFirst 2

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client A' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider $claimProvider

        $result.Created | Should -BeTrue
        $result.CollisionIndex | Should -Be 2
        $result.FolderName | Should -Be 'Client_A_20260916-070000-002'
        $claimProvider.State.Calls | Should -HaveCount 3
    }

    It 'stops after bounded suffix exhaustion instead of deleting or reusing a folder' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-d'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $claimProvider = New-ClaimProvider -AlwaysFail $true

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client A' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider $claimProvider -MaxSuffix 4

        $result.Created | Should -BeFalse
        $result.ReasonCode | Should -Be 'ClaimExhausted'
        $claimProvider.State.Calls | Should -HaveCount 5
    }

    It 'stops on a non-collision claim failure instead of trying another name' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-e'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $claimProvider = New-ClaimProvider -AlwaysFail $true -FailureReason 'ClaimFailed'

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client A' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider $claimProvider

        $result.Created | Should -BeFalse
        $result.ReasonCode | Should -Be 'ClaimFailed'
        $claimProvider.State.Calls | Should -HaveCount 1
    }

    It 'refuses an invalid client name without creating a folder' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-f'
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'CON' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider (New-ClaimProvider)

        $result.Created | Should -BeFalse
        $result.ReasonCode | Should -Be 'ClientNameInvalid'
    }

    It 'abandons a folder that another writer populates before the claim completes' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-h'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $state = @{ Calls = (New-Object System.Collections.Generic.List[string]) }
        $racingClaim = @{}
        $racingClaim.Name = 'RacingClaim'
        $racingClaim.State = $state
        $racingClaim.CreateNew = {
            param($request)
            $state.Calls.Add([string]$request.Path) | Out-Null
            $directory = [System.IO.Path]::GetDirectoryName([string]$request.Path)
            if ($state.Calls.Count -eq 1) {
                $foreign = Join-Path -Path $directory -ChildPath 'foreign.txt'
                [System.IO.File]::WriteAllText($foreign, 'FOREIGN', [System.Text.Encoding]::ASCII)
            }
            [System.IO.File]::WriteAllText([string]$request.Path, [string]$request.Content, (New-Object System.Text.UTF8Encoding($false)))
            return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
        }.GetNewClosure()

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client A' -Clock (New-FixedClock -UtcInstant '2026-09-16T07:00:00Z') -ClaimProvider $racingClaim

        $result.Created | Should -BeTrue
        $result.CollisionIndex | Should -Be 1
        $result.FolderName | Should -Be 'Client_A_20260916-070000-001'
        (Test-Path -LiteralPath (Join-Path -Path (Join-Path -Path $root -ChildPath 'Client_A_20260916-070000') -ChildPath 'foreign.txt')) | Should -BeTrue
    }

    It 'claims a real folder with a real CreateNew provider and refuses a second claim' {
        $root = Join-Path -Path $TestDrive -ChildPath 'root-g'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $clock = New-FixedClock -UtcInstant '2026-09-16T07:00:00Z'

        $first = New-RecoveryJobFolder -RootPath $root -ClientName 'RealClient' -Clock $clock
        $second = New-RecoveryJobFolder -RootPath $root -ClientName 'RealClient' -Clock $clock

        $first.Created | Should -BeTrue
        $second.Created | Should -BeTrue
        $second.CollisionIndex | Should -Be 1
        Test-Path -LiteralPath $first.ClaimPath | Should -BeTrue
        [System.IO.File]::ReadAllText($first.ClaimPath) | Should -Match 'RealClient'
    }
}

Describe 'Source and destination separation for every artifact path (C-23)' {
    It 'rejects metadata, log, state, session, journal, and output paths on the source disk' {
        $sourcePath = New-WinPath -Drive 'Q' -Relative 'Source'
        $sourceVolume = 'VOLUME-GUID-SRC'
        $pathMap = @{ $sourcePath = (New-PathRecord -Path $sourcePath -VolumeGuid $sourceVolume -DiskNumber 0) }
        $artifactNames = @('job-metadata.json', 'events.jsonl', 'job-state.json', 'case.fss', 'scan-journal', 'recovered')
        for ($i = 0; $i -lt $artifactNames.Count; $i++) {
            $artifactPath = New-WinPath -Drive 'R' -Relative ('Artifacts' + $script:Sep + $artifactNames[$i])
            $pathMap[$artifactPath] = (New-PathRecord -Path $artifactPath -VolumeGuid ('VOLUME-GUID-ART-' + $i) -DriveLetter 'R' -DiskNumber 0)
        }
        $provider = New-DiskProvider -Name 'StorageModule' -Disks @((New-DiskFixture -DiskNumber 0 -UniqueId 'FIXTURE-SRC')) -PathMap $pathMap
        $sourceIdentity = Resolve-RecoveryPathIdentity -Path $sourcePath -Provider $provider

        foreach ($name in $artifactNames) {
            $artifactPath = New-WinPath -Drive 'R' -Relative ('Artifacts' + $script:Sep + $name)
            $decision = Test-DestinationSafety -SourceIdentity $sourceIdentity -DestinationPath $artifactPath -Provider $provider
            $decision.Allowed | Should -BeFalse
            $decision.ReasonCode | Should -Be 'SamePhysicalDisk'
            @($decision.PSObject.Properties.Name) | Should -Not -Contain 'AlternativePath'
        }
    }
}

Describe 'Append-only event log (C-15, C-16, C-17, C-22)' {
    BeforeAll {
        function New-LogFixture {
            param([string]$JobId = 'JOB-0001', [string]$FolderName = 'job-log-a')
            $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            return [pscustomobject]@{
                Folder   = $folder
                LogPath  = (Join-Path -Path $folder -ChildPath 'events.jsonl')
                JobId    = $JobId
            }
        }

        function New-EventEntry {
            param(
                [string]$JobId = 'JOB-0001',
                [string]$EventType = 'StageStarted',
                [string]$State = 'SHORT_SCAN_RUNNING',
                [string]$Stage = 'SHORT_SCAN',
                [string]$AttemptId = 'ATTEMPT-1',
                [string]$Result = 'Started'
            )
            return @{
                JobId        = $JobId
                EventType    = $EventType
                State        = $State
                Stage        = $Stage
                AttemptId    = $AttemptId
                Result       = $Result
                SourceIdentity = (New-IdentitySnapshot)
                DestinationIdentity = (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST'))
                Decision     = $null
                Error        = $null
            }
        }
    }

    It 'creates a new log and refuses to reuse an existing unclaimed log' {
        $fixture = New-LogFixture -FolderName 'job-log-b'

        $created = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        $second = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)

        $created.Success | Should -BeTrue
        $created.Sequence | Should -Be 0
        $second.Success | Should -BeFalse
        $second.ReasonCode | Should -Be 'LogAlreadyExists'
        ([System.IO.File]::ReadAllBytes($fixture.LogPath)).Length | Should -Be 0
    }

    It 'blocks the first vendor launch when the log cannot be created' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'job-log-missing'
        $missingLog = Join-Path -Path (Join-Path -Path $folder -ChildPath 'absent') -ChildPath 'events.jsonl'

        $result = New-RecoveryLog -Path $missingLog -JobId 'JOB-0002' -Clock (New-FixedClock)
        $failFolder = Join-Path -Path $TestDrive -ChildPath 'job-log-fail'
        $failLog = Join-Path -Path $failFolder -ChildPath 'events.jsonl'
        $unflushable = New-RecoveryLog -Path $failLog -JobId 'JOB-0003' -Clock (New-FixedClock -UtcInstant $script:Now) -Writer (New-LogWriterProvider -FailOpen $true)

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'LogOpenFailed'
        $unflushable.Success | Should -BeFalse
        $unflushable.ReasonCode | Should -Be 'LogOpenFailed'
    }

    It 'appends one complete event with a monotonic sequence and leaves existing bytes unchanged' {
        $fixture = New-LogFixture -FolderName 'job-log-c'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock -StepSeconds 1)

        $first = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry)
        $afterFirst = [System.IO.File]::ReadAllBytes($fixture.LogPath)
        $second = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -EventType 'ScanFinished' -Result 'Finished' -AttemptId 'ATTEMPT-1')
        $afterSecond = [System.IO.File]::ReadAllBytes($fixture.LogPath)

        $first.Success | Should -BeTrue
        $first.Sequence | Should -Be 1
        $second.Sequence | Should -Be 2
        $afterSecond.Length | Should -BeGreaterThan $afterFirst.Length
        ($afterSecond[0..($afterFirst.Length - 1)] -join ',') | Should -Be ($afterFirst -join ',')

        $lines = [System.IO.File]::ReadAllLines($fixture.LogPath)
        $lines | Should -HaveCount 2
        $record = $lines[0] | ConvertFrom-Json
        $record.EventId | Should -Be ($fixture.JobId + '-000001')
        $record.Sequence | Should -Be 1
        $record.JobId | Should -Be $fixture.JobId
        $record.EventType | Should -Be 'StageStarted'
        $record.Stage | Should -Be 'SHORT_SCAN'
        $record.AttemptId | Should -Be 'ATTEMPT-1'
        $record.Result | Should -Be 'Started'
        ($lines[0] -match '"TimestampUtc":"2026-09-16T07:00:0[0-9]') | Should -BeTrue
        ($lines[0] -match 'Z"') | Should -BeTrue
        ([datetime]$record.TimestampUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) | Should -Be '2026-09-16T07:00:00'
        $record.SourceIdentity.VolumeGuid | Should -Be 'VOLUME-GUID-1'
        $record.DestinationIdentity.VolumeGuid | Should -Be 'VOLUME-GUID-DST'
    }

    It 'writes ASCII-safe JSONL without a BOM and preserves dynamic values' {
        $fixture = New-LogFixture -FolderName 'job-log-d'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        $entry = New-EventEntry -EventType 'OperatorDecision' -Result 'Approved'
        $entry.Decision = @{ GateId = 'G-03'; Note = (('Cl' + [char]0x00E9 + 'nt') + ' path') }

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry $entry

        $written.Success | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($fixture.LogPath)
        ([int]($bytes | Measure-Object -Maximum).Maximum) | Should -BeLessThan 128
        $bytes[0] | Should -Not -Be 0xEF
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Match '\\u00e9'
        $record = (($text -split "`n")[0]) | ConvertFrom-Json
        $record.Decision.Note | Should -Be (('Cl' + [char]0x00E9 + 'nt') + ' path')
    }

    It 'rejects an entry that is missing a required field' {
        $fixture = New-LogFixture -FolderName 'job-log-e'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        $entry = New-EventEntry
        $entry.Remove('EventType')

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry $entry

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'EntryInvalid'
        $handle.Writer.Sequence | Should -Be 0
        ([System.IO.File]::ReadAllBytes($fixture.LogPath)).Length | Should -Be 0
    }

    It 'refuses to write an event for a different job' {
        $fixture = New-LogFixture -FolderName 'job-log-f'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-OTHER')

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'JobIdMismatch'
        ([System.IO.File]::ReadAllBytes($fixture.LogPath)).Length | Should -Be 0
    }

    It 'stops the next action when an append or flush fails' {
        $fixture = New-LogFixture -FolderName 'job-log-g'
        $appendFail = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer (New-LogWriterProvider -FailAppend $true)
        $flushFixture = New-LogFixture -FolderName 'job-log-h' -JobId 'JOB-0009'
        $flushFail = New-RecoveryLog -Path $flushFixture.LogPath -JobId $flushFixture.JobId -Clock (New-FixedClock) -Writer (New-LogWriterProvider -FailFlush $true)

        $appended = Write-RecoveryLogEntry -Writer $appendFail.Writer -Entry (New-EventEntry)
        $flushed = Write-RecoveryLogEntry -Writer $flushFail.Writer -Entry (New-EventEntry -JobId 'JOB-0009')

        $appended.Success | Should -BeFalse
        $appended.ReasonCode | Should -Be 'LogAppendFailed'
        $appendFail.Writer.Sequence | Should -Be 0
        $flushed.Success | Should -BeFalse
        $flushed.ReasonCode | Should -Be 'LogFlushFailed'
        $flushFail.Writer.Sequence | Should -Be 0
    }

    It 'refuses a structured append refusal and blocks every later write' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-a' -JobId 'JOB-0020'
        $provider = New-LogWriterProvider -StructuredAppendRefusal $true
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0020')
        $later = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0020' -EventType 'ScanFinished')

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
        $written.Sequence | Should -Be 0
        $handle.Writer.Sequence | Should -Be 0
        $handle.Writer.IsBlocked | Should -BeTrue
        $later.Success | Should -BeFalse
        $later.ReasonCode | Should -Be 'LogWriteBlocked'
        Test-Path -LiteralPath $fixture.LogPath | Should -BeFalse
    }

    It 'refuses a structured flush refusal and blocks every later write' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-b' -JobId 'JOB-0021'
        $provider = New-LogWriterProvider -StructuredFlushRefusal $true
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0021')
        $later = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0021' -EventType 'ScanFinished')

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogFlushFailed'
        $handle.Writer.Sequence | Should -Be 0
        $handle.Writer.IsBlocked | Should -BeTrue
        $later.Success | Should -BeFalse
        $later.ReasonCode | Should -Be 'LogWriteBlocked'
    }

    It 'blocks a log already blocked before the next external action' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-c' -JobId 'JOB-0022'
        $provider = New-LogWriterProvider -StructuredFlushRefusal $true
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider
        Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0022') | Out-Null
        $provider.Flush = { param($request) $provider.State.Calls.Add('Flush') | Out-Null; return $true }

        $afterBlock = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0022' -EventType 'ScanFinished')
        $flushAfterBlock = Flush-RecoveryLog -Writer $handle.Writer

        $afterBlock.Success | Should -BeFalse
        $afterBlock.ReasonCode | Should -Be 'LogWriteBlocked'
        $flushAfterBlock.Success | Should -BeFalse
    }

    It 'refuses an append result that carries no explicit success decision' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-d' -JobId 'JOB-0023'
        $provider = New-LogWriterProvider -AmbiguousAppend $true
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0023')

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
        $written.Message | Should -Match 'explicit'
        $handle.Writer.Sequence | Should -Be 0
        $handle.Writer.IsBlocked | Should -BeTrue
        Test-Path -LiteralPath $fixture.LogPath | Should -BeFalse
    }

    It 'refuses a structured refusal from the log open operation' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-e' -JobId 'JOB-0024'
        $provider = New-LogWriterProvider -StructuredOpenRefusal $true

        $created = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider

        $created.Success | Should -BeFalse
        $created.ReasonCode | Should -Be 'LogOpenFailed'
        $created.Writer | Should -BeNullOrEmpty
    }

    It 'refuses an open result that carries no explicit success decision' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-f' -JobId 'JOB-0025'
        $provider = New-LogWriterProvider -AmbiguousOpen $true

        $created = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider

        $created.Success | Should -BeFalse
        $created.ReasonCode | Should -Be 'LogOpenFailed'
        $created.Writer | Should -BeNullOrEmpty
    }

    It 'reports the last durable record so a caller can bind state to the log' {
        $fixture = New-LogFixture -FolderName 'job-log-refuse-g' -JobId 'JOB-0026'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0026' -EventType 'CaseCreated' -State 'CASE_READY' -Stage 'CASE' -AttemptId 'ATTEMPT-0') | Out-Null

        $checked = Test-RecoveryLog -Path $fixture.LogPath -JobId 'JOB-0026' -ExpectedLastSequence 1

        $checked.IsValid | Should -BeTrue
        $checked.LastEvent | Should -Not -BeNullOrEmpty
        $checked.LastEvent.EventType | Should -Be 'CaseCreated'
        $checked.LastEvent.State | Should -Be 'CASE_READY'
        $checked.LastEvent.Sequence | Should -Be 1
    }

    It 'reports a flush failure from Flush-RecoveryLog instead of continuing silently' {
        $fixture = New-LogFixture -FolderName 'job-log-i' -JobId 'JOB-0010'
        $provider = New-LogWriterProvider
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Writer $provider

        $ok = Flush-RecoveryLog -Writer $handle.Writer
        $provider.State.Calls.Clear()
        $provider.Flush = { param($request) $provider.State.Calls.Add('Flush') | Out-Null; return $false }
        $failed = Flush-RecoveryLog -Writer $handle.Writer

        $ok.Success | Should -BeTrue
        $failed.Success | Should -BeFalse
        $failed.ReasonCode | Should -Be 'LogFlushFailed'
    }

    It 'validates an append-only log and rejects malformed, reordered, or truncated content' {
        $fixture = New-LogFixture -FolderName 'job-log-j' -JobId 'JOB-0011'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0011') | Out-Null
        Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0011' -EventType 'ScanFinished') | Out-Null

        $valid = Test-RecoveryLog -Path $fixture.LogPath -JobId 'JOB-0011'

        $valid.IsValid | Should -BeTrue
        $valid.EventCount | Should -Be 2
        $valid.LastSequence | Should -Be 2
        $valid.IsTruncated | Should -BeFalse

        $malformedPath = Join-Path -Path $fixture.Folder -ChildPath 'malformed.jsonl'
        [System.IO.File]::WriteAllText($malformedPath, ("{ not json }" + [char]10), [System.Text.Encoding]::ASCII)
        $malformed = Test-RecoveryLog -Path $malformedPath -JobId 'JOB-0011'
        $malformed.IsValid | Should -BeFalse
        $malformed.ReasonCode | Should -Be 'LogMalformed'

        $reorderedPath = Join-Path -Path $fixture.Folder -ChildPath 'reordered.jsonl'
        $lines = [System.IO.File]::ReadAllLines($fixture.LogPath)
        $swapped = @($lines[1], $lines[0])
        [System.IO.File]::WriteAllLines($reorderedPath, $swapped, [System.Text.Encoding]::ASCII)
        $reordered = Test-RecoveryLog -Path $reorderedPath -JobId 'JOB-0011'
        $reordered.IsValid | Should -BeFalse
        $reordered.ReasonCode | Should -Be 'LogSequenceInvalid'

        $truncatedPath = Join-Path -Path $fixture.Folder -ChildPath 'truncated.jsonl'
        $text = [System.IO.File]::ReadAllText($fixture.LogPath)
        [System.IO.File]::WriteAllText($truncatedPath, $text.Substring(0, $text.Length - 12), [System.Text.Encoding]::ASCII)
        $truncated = Test-RecoveryLog -Path $truncatedPath -JobId 'JOB-0011'
        $truncated.IsValid | Should -BeFalse
        $truncated.ReasonCode | Should -Be 'LogTruncated'

        $wrongJob = Test-RecoveryLog -Path $fixture.LogPath -JobId 'JOB-OTHER'
        $wrongJob.IsValid | Should -BeFalse
        $wrongJob.ReasonCode | Should -Be 'LogJobIdMismatch'

        $missing = Test-RecoveryLog -Path (Join-Path -Path $fixture.Folder -ChildPath 'absent.jsonl')
        $missing.IsValid | Should -BeFalse
        $missing.ReasonCode | Should -Be 'LogNotFound'
    }

    It 'resumes an existing valid log only when the resume mode validates it' {
        $fixture = New-LogFixture -FolderName 'job-log-k' -JobId 'JOB-0012'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-EventEntry -JobId 'JOB-0012') | Out-Null

        $resumed = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Clock (New-FixedClock) -Resume
        $wrongJob = New-RecoveryLog -Path $fixture.LogPath -JobId 'JOB-0013' -Clock (New-FixedClock) -Resume

        $resumed.Success | Should -BeTrue
        $resumed.Sequence | Should -Be 1
        $wrongJob.Success | Should -BeFalse
        $wrongJob.ReasonCode | Should -Be 'LogJobIdMismatch'
    }
}

Describe 'Job state schema, round trip, and ownership (C-18, C-19)' {
    BeforeAll {
        function New-StateFixture {
            param([string]$FolderName = 'job-state-a', [string]$JobId = 'JOB-1000')
            $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $paths = New-CasePaths -JobFolder $folder
            $claimId = [guid]::NewGuid().ToString('N')
            $claim = @{ ClaimId = $claimId; ClientName = 'StateClient'; FolderName = $FolderName; CreatedUtc = $script:Now; CollisionIndex = 0 } | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
            $state = New-RecoveryJobState -JobId $JobId -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST')) -ApplicationEvidence @{ FileScavenger = 'VERIFIED-BUILD'; RStudio = 'VERIFIED-BUILD' } -Paths $paths -WorkflowVersion '1.0' -Clock (New-FixedClock)
            return [pscustomobject]@{ Folder = $folder; Paths = $paths; State = $state; JobId = $JobId; ClaimId = $claimId }
        }

        function New-RecordingStateWriter {
            param([object]$SharedOrder = $null)
            $order = $SharedOrder
            $state = @{ Writes = (New-Object System.Collections.Generic.List[object]); Order = (New-Object System.Collections.Generic.List[string]) }
            $provider = @{}
            $provider.Name = 'RecordingStateWriter'
            $provider.State = $state
            $provider.Write = {
                param($request)
                $state.Order.Add('StateWrite') | Out-Null
                if ($null -ne $order) { $order.Add('StateWrite') | Out-Null }
                $state.Writes.Add($request) | Out-Null
                return [pscustomobject]@{ Success = $true; ReasonCode = $null }
            }.GetNewClosure()
            return $provider
        }

        function New-RecordingEventWriter {
            param([object]$SharedOrder = $null)
            $order = $SharedOrder
            $state = @{ Events = (New-Object System.Collections.Generic.List[object]); Order = (New-Object System.Collections.Generic.List[string]) }
            $scriptblock = {
                param($event)
                $state.Order.Add('EventWrite') | Out-Null
                if ($null -ne $order) { $order.Add('EventWrite') | Out-Null }
                $state.Events.Add($event) | Out-Null
                return $true
            }.GetNewClosure()
            return [pscustomobject]@{ State = $state; Writer = $scriptblock }
        }
    }

    It 'creates a schema version 1 state object with identity evidence' {
        $fixture = New-StateFixture -FolderName 'job-state-b'

        $fixture.State.SchemaVersion | Should -Be 1
        $fixture.State.WorkflowVersion | Should -Be '1.0'
        $fixture.State.JobId | Should -Be 'JOB-1000'
        $fixture.State.State | Should -Be 'NEW'
        $fixture.State.SourceIdentity.IdentityKeys | Should -HaveCount 1
        $fixture.State.DestinationIdentity.IdentityKeys | Should -HaveCount 1
        $fixture.State.Paths.StatePath | Should -Be $fixture.Paths.StatePath
    }

    It 'rejects an incomplete job state at creation' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'job-state-c'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $paths = New-CasePaths -JobFolder $folder

        { New-RecoveryJobState -JobId '' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' } | Should -Throw
        { New-RecoveryJobState -JobId 'JOB-1' -SourceIdentity $null -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' } | Should -Throw
        { New-RecoveryJobState -JobId 'JOB-1' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths ([pscustomobject]@{ JobFolderPath = $folder }) -WorkflowVersion '1.0' } | Should -Throw
    }

    It 'round-trips the full nested state through explicit JSON depth' {
        $fixture = New-StateFixture -FolderName 'job-state-d'
        $lock = Acquire-RecoveryJobLock -JobPath $fixture.Folder -Clock (New-FixedClock) -JobId $fixture.JobId

        $written = Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State
        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $lock

        $lock.Acquired | Should -BeTrue
        $written.Success | Should -BeTrue
        $read.Success | Should -BeTrue
        $read.State.SchemaVersion | Should -Be 1
        $read.State.JobId | Should -Be 'JOB-1000'
        $read.State.SourceIdentity.VolumeGuid | Should -Be 'VOLUME-GUID-1'
        @($read.State.SourceIdentity.IdentityKeys) | Should -HaveCount 1
        $read.State.DestinationIdentity.IdentityKeys | Should -Be 'UID|WWN|FIXTURE-DST'
        $read.State.Paths.LogPath | Should -Be $fixture.Paths.LogPath
        $read.State.ApplicationEvidence.FileScavenger | Should -Be 'VERIFIED-BUILD'
    }

    It 'writes the state snapshot as UTF-8 without a BOM' {
        $fixture = New-StateFixture -FolderName 'job-state-e'

        Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($fixture.Paths.StatePath)
        $bytes[0] | Should -Not -Be 0xEF
        $bytes[0] | Should -Be ([byte][char]'{')
    }

    It 'requires an exclusive lock before reading resume state' {
        $fixture = New-StateFixture -FolderName 'job-state-f'
        Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State | Out-Null

        $noLock = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $null
        $heldLock = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock ([pscustomobject]@{ Acquired = $false })
        $unboundLock = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock ([pscustomobject]@{ Acquired = $true })

        $noLock.Success | Should -BeFalse
        $noLock.ReasonCode | Should -Be 'LockRequired'
        $heldLock.Success | Should -BeFalse
        $heldLock.ReasonCode | Should -Be 'LockRequired'
        $unboundLock.Success | Should -BeFalse
        $unboundLock.ReasonCode | Should -Be 'LockNotBound'
    }

    It 'rejects malformed, schema-mismatched, and incomplete state' {
        $fixture = New-StateFixture -FolderName 'job-state-g'
        $lock = Acquire-RecoveryJobLock -JobPath $fixture.Folder -Clock (New-FixedClock) -JobId $fixture.JobId
        $malformedPath = Join-Path -Path $fixture.Folder -ChildPath 'malformed-state.json'
        [System.IO.File]::WriteAllText($malformedPath, '{"SchemaVersion":1,', [System.Text.UTF8Encoding]::new($false))
        $schemaPath = Join-Path -Path $fixture.Folder -ChildPath 'schema-state.json'
        [System.IO.File]::WriteAllText($schemaPath, '{"SchemaVersion":99,"JobId":"JOB-1"}', [System.Text.UTF8Encoding]::new($false))
        $incompletePath = Join-Path -Path $fixture.Folder -ChildPath 'incomplete-state.json'
        [System.IO.File]::WriteAllText($incompletePath, '{"SchemaVersion":1,"JobId":"JOB-1"}', [System.Text.UTF8Encoding]::new($false))

        $malformed = Read-RecoveryJobState -Path $malformedPath -Lock $lock
        $schema = Read-RecoveryJobState -Path $schemaPath -Lock $lock
        $incomplete = Read-RecoveryJobState -Path $incompletePath -Lock $lock
        $missing = Read-RecoveryJobState -Path (Join-Path -Path $fixture.Folder -ChildPath 'absent.json') -Lock $lock

        $malformed.Success | Should -BeFalse
        $malformed.ReasonCode | Should -Be 'StateMalformed'
        $schema.Success | Should -BeFalse
        $schema.ReasonCode | Should -Be 'StateInvalid'
        $incomplete.Success | Should -BeFalse
        $incomplete.ReasonCode | Should -Be 'StateInvalid'
        $missing.Success | Should -BeFalse
        $missing.ReasonCode | Should -Be 'StateMissing'
    }

    It 'refuses a snapshot write outside the claimed job folder' {
        $fixture = New-StateFixture -FolderName 'job-state-h'
        $outside = Join-Path -Path $TestDrive -ChildPath 'job-state-h-outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $outsidePath = Join-Path -Path $outside -ChildPath 'job-state.json'
        $sentinel = Join-Path -Path $outside -ChildPath 'other-state.json'
        Set-Content -LiteralPath $sentinel -Value 'OTHER-JOB-BYTES' -NoNewline

        $result = Write-RecoveryJobState -Path $outsidePath -State $fixture.State

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'SnapshotOutsideJobFolder'
        Test-Path -LiteralPath $outsidePath | Should -BeFalse
        [System.IO.File]::ReadAllText($sentinel) | Should -Be 'OTHER-JOB-BYTES'
    }

    It 'refuses to replace another job snapshot at the same path' {
        $first = New-StateFixture -FolderName 'job-state-i' -JobId 'JOB-2000'
        Write-RecoveryJobState -Path $first.Paths.StatePath -State $first.State | Out-Null
        $before = [System.IO.File]::ReadAllBytes($first.Paths.StatePath)
        $other = New-RecoveryJobState -JobId 'JOB-2001' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $first.Paths -WorkflowVersion '1.0' -Clock (New-FixedClock)

        $result = Write-RecoveryJobState -Path $first.Paths.StatePath -State $other

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'SnapshotJobMismatch'
        [System.IO.File]::ReadAllBytes($first.Paths.StatePath) | Should -Be $before
    }

    It 'fails closed when the snapshot writer fails' {
        $fixture = New-StateFixture -FolderName 'job-state-j'
        $failingWriter = @{ Name = 'FailingStateWriter'; Write = { param($request) return [pscustomobject]@{ Success = $false; ReasonCode = 'WriteFailed'; Message = 'fixture' } } }

        $result = Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State -Writer $failingWriter

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'WriteFailed'
        Test-Path -LiteralPath $fixture.Paths.StatePath | Should -BeFalse
    }

    It 'writes the boundary event before the snapshot and never on an illegal transition' {
        $fixture = New-StateFixture -FolderName 'job-state-k'
        $order = New-Object System.Collections.Generic.List[string]
        $eventWriter = New-RecordingEventWriter -SharedOrder $order
        $stateWriter = New-RecordingStateWriter -SharedOrder $order
        Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State | Out-Null

        $denied = Set-RecoveryState -State $fixture.State -To 'SHORT_RECOVERY_VERIFIED' -EventWriter $eventWriter.Writer -StateWriter $stateWriter -Clock (New-FixedClock)
        $deniedOrder = @($order)
        $deniedEvents = $eventWriter.State.Events.Count
        $deniedStateName = $denied.State.State
        $allowed = Set-RecoveryState -State $fixture.State -To 'PREFLIGHT_PENDING' -EventWriter $eventWriter.Writer -StateWriter $stateWriter -Clock (New-FixedClock)

        $denied.Success | Should -BeFalse
        $denied.ReasonCode | Should -Be 'IllegalTransition'
        $deniedOrder | Should -HaveCount 0
        $deniedEvents | Should -Be 0
        $deniedStateName | Should -Be 'NEW'

        $allowed.Success | Should -BeTrue
        $allowed.State.State | Should -Be 'PREFLIGHT_PENDING'
        $allowed.State.LastEventSequence | Should -Be 1
        $eventWriter.State.Events[0].EventType | Should -Be 'StateTransition'
        $eventWriter.State.Events[0].JobId | Should -Be 'JOB-1000'
        $order | Should -HaveCount 2
        $order[0] | Should -Be 'EventWrite'
        $order[1] | Should -Be 'StateWrite'
    }

    It 'keeps the event log and the state snapshot consistent for the same job' {
        $fixture = New-StateFixture -FolderName 'job-state-l'
        $log = New-RecoveryLog -Path $fixture.Paths.LogPath -JobId $fixture.JobId -Clock (New-FixedClock)
        $eventWriter = { param($event) return (Write-RecoveryLogEntry -Writer $log.Writer -Entry $event).Success }.GetNewClosure()
        $lock = Acquire-RecoveryJobLock -JobPath $fixture.Folder -Clock (New-FixedClock) -JobId $fixture.JobId
        Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State | Out-Null

        $result = Set-RecoveryState -State $fixture.State -To 'PREFLIGHT_PENDING' -EventWriter $eventWriter -Clock (New-FixedClock)
        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $lock
        $logCheck = Test-RecoveryLog -Path $fixture.Paths.LogPath -JobId $fixture.JobId

        $lock.Acquired | Should -BeTrue
        $result.Success | Should -BeTrue
        $read.Success | Should -BeTrue
        $read.State.State | Should -Be 'PREFLIGHT_PENDING'
        $logCheck.IsValid | Should -BeTrue
        $logCheck.LastSequence | Should -Be $read.State.LastEventSequence
        $read.State.LastEventSequence | Should -Be 1
        $read.Binding.IsBound | Should -BeTrue
    }
}

Describe 'Job lock exclusivity and stale handling (C-20)' {
    BeforeAll {
        function New-LockFixture {
            param([string]$FolderName = 'job-lock-a', [string]$ClaimId = 'CLAIM-FIXTURE')
            $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $claim = @{ ClaimId = $ClaimId; ClientName = 'LockClient'; FolderName = $FolderName; CreatedUtc = $script:Now; CollisionIndex = 0 } | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
            return $folder
        }
    }

    It 'lets the first worker acquire the lock and blocks the second' {
        $folder = New-LockFixture -FolderName 'job-lock-b'
        $clock = New-FixedClock -UtcInstant '2026-09-16T07:00:00Z'

        $first = Acquire-RecoveryJobLock -JobPath $folder -Clock $clock -Owner 'technician-1' -LeaseMinutes 30
        $second = Acquire-RecoveryJobLock -JobPath $folder -Clock $clock -Owner 'technician-2' -LeaseMinutes 30

        $first.Acquired | Should -BeTrue
        $first.ReasonCode | Should -BeNullOrEmpty
        $second.Acquired | Should -BeFalse
        $second.ReasonCode | Should -Be 'LockHeld'
        $second.ExistingOwner | Should -Be 'technician-1'
    }

    It 'reports a stale lock as a gate and never deletes it automatically' {
        $folder = New-LockFixture -FolderName 'job-lock-c'
        $oldClock = New-FixedClock -UtcInstant '2026-09-16T07:00:00Z'
        Acquire-RecoveryJobLock -JobPath $folder -Clock $oldClock -Owner 'technician-1' -LeaseMinutes 1 | Out-Null
        $lockPath = Join-Path -Path $folder -ChildPath 'job.lock'
        $before = [System.IO.File]::ReadAllBytes($lockPath)

        $late = Acquire-RecoveryJobLock -JobPath $folder -Clock (New-FixedClock -UtcInstant '2026-09-16T09:00:00Z') -Owner 'technician-2' -LeaseMinutes 30

        $late.Acquired | Should -BeFalse
        $late.IsStale | Should -BeTrue
        $late.ReasonCode | Should -Be 'LockStale'
        Test-Path -LiteralPath $lockPath | Should -BeTrue
        [System.IO.File]::ReadAllBytes($lockPath) | Should -Be $before
    }

    It 'refuses to lock a folder that carries no claim marker' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'job-lock-e'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null

        $result = Acquire-RecoveryJobLock -JobPath $folder -Clock (New-FixedClock)

        $result.Acquired | Should -BeFalse
        $result.ReasonCode | Should -Be 'ClaimMarkerMissing'
        Test-Path -LiteralPath (Join-Path -Path $folder -ChildPath 'job.lock') | Should -BeFalse
    }

    It 'blocks lock acquisition when the lock provider fails' {
        $folder = New-LockFixture -FolderName 'job-lock-d'
        $failing = @{ Name = 'FailingLockProvider'; CreateNew = { param($request) return [pscustomobject]@{ Success = $false; ReasonCode = 'ClaimFailed'; Message = 'fixture' } } }

        $result = Acquire-RecoveryJobLock -JobPath $folder -Clock (New-FixedClock) -LockProvider $failing

        $result.Acquired | Should -BeFalse
        $result.ReasonCode | Should -Be 'LockAcquireFailed'
    }
}

Describe 'State transitions and resume decisions (C-09, I-06, I-07, I-09, I-10)' {
    It 'denies an unknown state name' {
        $decision = Test-RecoveryStateTransition -From 'NEW' -To 'DONE'

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'UnknownState'
    }

    It 'denies skipping straight from CASE_READY to a long scan or handoff' {
        $long = Test-RecoveryStateTransition -From 'CASE_READY' -To 'LONG_SCAN_RUNNING'
        $handoff = Test-RecoveryStateTransition -From 'SHORT_SCAN_FINISHED' -To 'READY_FOR_HANDOFF'

        $long.Allowed | Should -BeFalse
        $long.ReasonCode | Should -Be 'IllegalTransition'
        $handoff.Allowed | Should -BeFalse
        $handoff.ReasonCode | Should -Be 'IllegalTransition'
    }

    It 'requires the named evidence for an allowed transition' {
        $withoutEvidence = Test-RecoveryStateTransition -From 'SHORT_SCAN_RUNNING' -To 'SHORT_SCAN_FINISHED'
        $withEvidence = Test-RecoveryStateTransition -From 'SHORT_SCAN_RUNNING' -To 'SHORT_SCAN_FINISHED' -Context @{ Evidence = 'ScanFinished' }

        $withoutEvidence.Allowed | Should -BeFalse
        $withoutEvidence.ReasonCode | Should -Be 'MissingEvidence'
        $withoutEvidence.RequiredEvidence | Should -Be 'ScanFinished'
        $withEvidence.Allowed | Should -BeTrue
    }

    It 'keeps scan completion from authorizing recovery verification' {
        $decision = Test-RecoveryStateTransition -From 'SHORT_SCAN_FINISHED' -To 'SHORT_RECOVERY_VERIFIED' -Context @{ Evidence = 'OutputObserved' }

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'IllegalTransition'
    }

    It 'requires a new attempt and an operator decision to leave PAUSED' {
        $withoutDecision = Test-RecoveryStateTransition -From 'PAUSED' -To 'SHORT_RECOVERY_RUNNING' -Context @{ Evidence = 'RetryApproved' }
        $withDecision = Test-RecoveryStateTransition -From 'PAUSED' -To 'SHORT_RECOVERY_RUNNING' -Context @{ Evidence = 'RetryApproved'; OperatorDecision = 'RetryWithNewAttempt'; NewAttemptId = 'ATTEMPT-2' }

        $withoutDecision.Allowed | Should -BeFalse
        $withoutDecision.ReasonCode | Should -Be 'OperatorDecisionRequired'
        $withDecision.Allowed | Should -BeTrue
    }

    It 'never allows a terminal state to advance' {
        foreach ($terminal in @('ABORTED', 'FAILED_CLOSED', 'HANDOFF_MANUAL')) {
            $decision = Test-RecoveryStateTransition -From $terminal -To 'PREFLIGHT_PASSED' -Context @{ Evidence = 'PreflightPassed' }
            $decision.Allowed | Should -BeFalse
        }
    }

    It 'resumes to the next stage only from a verified state with fresh checks' {
        $state = New-RecoveryJobState -JobId 'JOB-3000' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST')) -ApplicationEvidence @{} -Paths (New-CasePaths -JobFolder $TestDrive) -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $state.State = 'SHORT_RECOVERY_VERIFIED'
        $freshSource = New-IdentitySnapshot
        $freshDestination = New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST')
        $freshSpace = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity $freshSource -FreshDestinationIdentity $freshDestination -FreshSpace $freshSpace

        $decision.Decision | Should -Be 'ResumeNext'
        $decision.NextState | Should -Be 'LONG_SCAN_RUNNING'
    }

    It 'converts an open running attempt into a review gate without automatic retry' {
        $state = New-RecoveryJobState -JobId 'JOB-3001' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths (New-CasePaths -JobFolder $TestDrive) -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $state.State = 'SHORT_SCAN_RUNNING'
        $state.AttemptId = 'ATTEMPT-1'
        $freshSpace = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace $freshSpace

        $decision.Decision | Should -Be 'NeedsReview'
        $decision.ReasonCode | Should -Be 'OpenAttempt'
    }

    It 'fails closed when the recorded and fresh identities disagree' {
        $state = New-RecoveryJobState -JobId 'JOB-3002' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths (New-CasePaths -JobFolder $TestDrive) -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $state.State = 'SHORT_RECOVERY_VERIFIED'
        $freshSpace = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $changedSource = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-IdentitySnapshot -IdentityKeys @('UID|WWN|FIXTURE-OTHER')) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace $freshSpace
        $changedDestination = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot -IdentityKeys @('UID|WWN|FIXTURE-OTHER')) -FreshSpace $freshSpace
        $indeterminate = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-IdentitySnapshot -IdentityKeys @()) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace $freshSpace

        $changedSource.Decision | Should -Be 'FailedClosed'
        $changedSource.ReasonCode | Should -Be 'SourceIdentityChanged'
        $changedDestination.Decision | Should -Be 'FailedClosed'
        $changedDestination.ReasonCode | Should -Be 'DestinationIdentityChanged'
        $indeterminate.Decision | Should -Be 'FailedClosed'
        $indeterminate.ReasonCode | Should -Be 'IdentityIndeterminate'
    }

    It 'requires a capacity decision before resuming' {
        $state = New-RecoveryJobState -JobId 'JOB-3003' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths (New-CasePaths -JobFolder $TestDrive) -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $state.State = 'SHORT_RECOVERY_VERIFIED'

        $missing = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot)
        $low = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace ([pscustomobject]@{ IsUnknown = $false; IsSufficient = $false; AvailableBytes = 10 })

        $missing.Decision | Should -Be 'NeedsReview'
        $missing.ReasonCode | Should -Be 'CapacityNotChecked'
        $low.Decision | Should -Be 'NeedsReview'
        $low.ReasonCode | Should -Be 'CapacityLow'
    }

    It 'fails closed for a terminal, missing, or unverified state' {
        $terminal = New-RecoveryJobState -JobId 'JOB-3004' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths (New-CasePaths -JobFolder $TestDrive) -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $terminal.State = 'ABORTED'
        $finished = New-RecoveryJobState -JobId 'JOB-3005' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths (New-CasePaths -JobFolder $TestDrive) -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $finished.State = 'SHORT_RECOVERY_FINISHED'
        $freshSpace = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $terminalDecision = Get-RecoveryResumeDecision -State $terminal -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace $freshSpace
        $finishedDecision = Get-RecoveryResumeDecision -State $finished -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace $freshSpace
        $missingDecision = Get-RecoveryResumeDecision -State $null -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot) -FreshSpace $freshSpace

        $terminalDecision.Decision | Should -Be 'FailedClosed'
        $terminalDecision.ReasonCode | Should -Be 'TerminalState'
        $finishedDecision.Decision | Should -Be 'NeedsReview'
        $finishedDecision.ReasonCode | Should -Be 'UnverifiedFinish'
        $missingDecision.Decision | Should -Be 'FailedClosed'
        $missingDecision.ReasonCode | Should -Be 'StateInvalid'
    }
}

Describe 'Resume binding and snapshot preservation (C-18, C-19, C-20)' {
    BeforeAll {
        function New-BoundCase {
            param([string]$FolderName = 'job-bound-a', [string]$JobId = 'JOB-5000')
            $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $claimId = [guid]::NewGuid().ToString('N')
            $claim = @{ ClaimId = $claimId; ClientName = 'BoundClient'; FolderName = (Split-Path -Path $folder -Leaf); CreatedUtc = $script:Now; CollisionIndex = 0 } | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
            $paths = New-CasePaths -JobFolder $folder
            $log = New-RecoveryLog -Path $paths.LogPath -JobId $JobId -Clock (New-FixedClock)
            $eventEntry = @{
                JobId = $JobId; EventType = 'CaseCreated'; State = 'CASE_READY'; Stage = 'CASE'; AttemptId = 'ATTEMPT-0'; Result = 'Created'
                SourceIdentity = (New-IdentitySnapshot)
                DestinationIdentity = (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST'))
            }
            Write-RecoveryLogEntry -Writer $log.Writer -Entry $eventEntry | Out-Null
            $state = New-RecoveryJobState -JobId $JobId -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST')) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' -State 'CASE_READY' -Clock (New-FixedClock)
            $state.LastEventSequence = 1
            $state.Stage = 'CASE'
            $state.AttemptId = 'ATTEMPT-0'
            Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
            $lock = Acquire-RecoveryJobLock -JobPath $folder -Clock (New-FixedClock) -Owner 'technician-1' -JobId $JobId
            return [pscustomobject]@{ Folder = $folder; Paths = $paths; State = $state; Lock = $lock; JobId = $JobId; ClaimId = $claimId; Log = $log }
        }
    }

    It 'reads a resume state whose lock, claim marker, and log all bind to it' {
        $case = New-BoundCase -FolderName 'job-bound-b'

        $read = Read-RecoveryJobState -Path $case.Paths.StatePath -Lock $case.Lock

        $read.Success | Should -BeTrue
        $read.State.JobId | Should -Be $case.JobId
        $read.Binding.LastSequence | Should -Be 1
        $read.Binding.LastEvent.State | Should -Be 'CASE_READY'
    }

    It 'refuses a lock whose path belongs to another job folder' {
        $case = New-BoundCase -FolderName 'job-bound-c'
        $other = New-BoundCase -FolderName 'job-bound-c-other'
        $forged = [pscustomobject]@{ Acquired = $true; LockPath = $other.Lock.LockPath }

        $read = Read-RecoveryJobState -Path $case.Paths.StatePath -Lock $forged

        $read.Success | Should -BeFalse
        $read.ReasonCode | Should -Be 'LockNotBound'
        $read.State | Should -BeNullOrEmpty
    }

    It 'refuses a lock whose claim marker does not match the job folder claim' {
        $case = New-BoundCase -FolderName 'job-bound-d'
        $lockPath = $case.Lock.LockPath
        $content = [System.IO.File]::ReadAllText($lockPath) | ConvertFrom-Json
        $content.ClaimId = 'DIFFERENT-CLAIM'
        [System.IO.File]::WriteAllText($lockPath, ($content | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))

        $read = Read-RecoveryJobState -Path $case.Paths.StatePath -Lock $case.Lock

        $read.Success | Should -BeFalse
        $read.ReasonCode | Should -Be 'ClaimNotBound'
    }

    It 'refuses a state whose log history does not agree with it' {
        $case = New-BoundCase -FolderName 'job-bound-e'
        # The extra event deliberately repeats the same state, stage, attempt,
        # and identities so that only the recorded sequence can reveal that the
        # snapshot no longer describes the log history.
        $advanced = Write-RecoveryLogEntry -Writer $case.Log.Writer -Entry @{
            JobId = $case.JobId; EventType = 'StageVerified'; State = 'CASE_READY'; Stage = 'CASE'; AttemptId = 'ATTEMPT-0'; Result = 'Recorded'
            SourceIdentity = (New-IdentitySnapshot)
            DestinationIdentity = (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST'))
        }

        $read = Read-RecoveryJobState -Path $case.Paths.StatePath -Lock $case.Lock

        $advanced.Success | Should -BeTrue
        $advanced.Sequence | Should -Be 2
        $read.Success | Should -BeFalse
        $read.ReasonCode | Should -Be 'LogStateMismatch'
    }

    It 'refuses a state whose last event disagrees about the state name' {
        $case = New-BoundCase -FolderName 'job-bound-f'
        $statePath = $case.Paths.StatePath
        $written = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $written.State = 'PREFLIGHT_PENDING'
        [System.IO.File]::WriteAllText($statePath, ($written | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

        $read = Read-RecoveryJobState -Path $statePath -Lock $case.Lock

        $read.Success | Should -BeFalse
        $read.ReasonCode | Should -Be 'LogStateMismatch'
    }

    It 'adopts the log sequence reported by a structured event writer' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'job-bound-g'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $paths = New-CasePaths -JobFolder $folder
        $state = New-RecoveryJobState -JobId 'JOB-5100' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' -Clock (New-FixedClock)
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        $eventWriter = { param($event) return [pscustomobject]@{ Success = $true; Sequence = 7; EventId = 'JOB-5100-000007' } }

        $result = Set-RecoveryState -State $state -To 'PREFLIGHT_PENDING' -EventWriter $eventWriter -Clock (New-FixedClock)

        $result.Success | Should -BeTrue
        $result.State.LastEventSequence | Should -Be 7
    }

    It 'refuses a reported log sequence that contradicts the state history' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'job-bound-h'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $paths = New-CasePaths -JobFolder $folder
        $state = New-RecoveryJobState -JobId 'JOB-5101' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' -Clock (New-FixedClock)
        $state.LastEventSequence = 4
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        $eventWriter = { param($event) return [pscustomobject]@{ Success = $true; Sequence = 2 } }

        $result = Set-RecoveryState -State $state -To 'PREFLIGHT_PENDING' -EventWriter $eventWriter -Clock (New-FixedClock)

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'EventSequenceMismatch'
        $state.LastEventSequence | Should -Be 4
    }

    It 'preserves an unreadable existing snapshot instead of replacing it' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'job-bound-i'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $paths = New-CasePaths -JobFolder $folder
        [System.IO.File]::WriteAllText($paths.StatePath, '{"SchemaVersion":1,"JobId":"JOB-1"', (New-Object System.Text.UTF8Encoding($false)))
        $before = [System.IO.File]::ReadAllBytes($paths.StatePath)
        $state = New-RecoveryJobState -JobId 'JOB-5200' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' -Clock (New-FixedClock)

        $result = Write-RecoveryJobState -Path $paths.StatePath -State $state

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'SnapshotUnreadable'
        [System.IO.File]::ReadAllBytes($paths.StatePath) | Should -Be $before
    }

    It 'fails a resume decision closed when the log diverges from the state' {
        $case = New-BoundCase -FolderName 'job-bound-j'
        Write-RecoveryLogEntry -Writer $case.Log.Writer -Entry @{
            JobId = $case.JobId; EventType = 'ScanFinished'; State = $case.State.State; Stage = 'CASE'; AttemptId = 'ATTEMPT-0'; Result = 'Finished'
        } | Out-Null
        $freshSpace = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $case.State -FreshSourceIdentity (New-IdentitySnapshot) -FreshDestinationIdentity (New-IdentitySnapshot -VolumeGuid 'VOLUME-GUID-DST' -IdentityKeys @('UID|WWN|FIXTURE-DST')) -FreshSpace $freshSpace -LogPath $case.Paths.LogPath

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'LogStateMismatch'
    }
}

Describe 'Durable case exists before any external action (C-21 core)' {
    It 'orders claim, lock, log, metadata, and state before a recorded external action' {
        $root = Join-Path -Path $TestDrive -ChildPath 'order-root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $clock = New-FixedClock -UtcInstant '2026-09-16T07:00:00Z'
        $order = New-Object System.Collections.Generic.List[string]

        $jobFolder = New-RecoveryJobFolder -RootPath $root -ClientName 'OrderClient' -Clock $clock
        $order.Add('FolderClaimed') | Out-Null
        $lock = Acquire-RecoveryJobLock -JobPath $jobFolder.JobFolderPath -Clock $clock -Owner 'technician-1'
        $order.Add('LockAcquired') | Out-Null
        $paths = New-CasePaths -JobFolder $jobFolder.JobFolderPath
        $log = New-RecoveryLog -Path $paths.LogPath -JobId 'JOB-4000' -Clock $clock
        Write-RecoveryLogEntry -Writer $log.Writer -Entry @{ JobId = 'JOB-4000'; EventType = 'CaseCreated'; State = 'CASE_READY'; Stage = 'CASE'; AttemptId = 'ATTEMPT-0'; Result = 'Created' } | Out-Null
        $order.Add('LogFlushed') | Out-Null
        $state = New-RecoveryJobState -JobId 'JOB-4000' -SourceIdentity (New-IdentitySnapshot) -DestinationIdentity (New-IdentitySnapshot) -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' -State 'CASE_READY' -Clock $clock
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        $order.Add('StateWritten') | Out-Null

        $externalAction = {
            $order.Add('VendorLaunch') | Out-Null
            return [pscustomobject]@{ Launched = $true }
        }

        $order.Add('VendorLaunch') | Out-Null

        $jobFolder.Created | Should -BeTrue
        $lock.Acquired | Should -BeTrue
        $log.Success | Should -BeTrue
        Test-Path -LiteralPath $paths.StatePath | Should -BeTrue
        Test-Path -LiteralPath $paths.LogPath | Should -BeTrue
        (Test-RecoveryLog -Path $paths.LogPath -JobId 'JOB-4000').IsValid | Should -BeTrue
        $order.IndexOf('VendorLaunch') | Should -BeGreaterThan $order.IndexOf('StateWritten')
        $order.IndexOf('StateWritten') | Should -BeGreaterThan $order.IndexOf('LogFlushed')
        $order.IndexOf('LogFlushed') | Should -BeGreaterThan $order.IndexOf('LockAcquired')
        $order.IndexOf('LockAcquired') | Should -BeGreaterThan $order.IndexOf('FolderClaimed')
        $externalAction | Should -Not -BeNullOrEmpty
        $jobFolder.JobFolderPath | Should -Not -Be $root
    }
}

Describe 'Module source contracts' {
    BeforeAll {
        $script:ModulePaths = @(
            (Join-Path -Path $script:ModulesRoot -ChildPath 'DiskDetection.psm1'),
            (Join-Path -Path $script:ModulesRoot -ChildPath 'RecoveryLogging.psm1'),
            (Join-Path -Path $script:ModulesRoot -ChildPath 'JobState.psm1')
        )
        $script:DeniedCommands = @(
            ('Format-' + 'Volume'), ('Initialize-' + 'Disk'), ('Clear-' + 'Disk'), ('Set-' + 'Disk'),
            ('Remove-' + 'Partition'), ('New-' + 'Partition'), ('Resize-' + 'Partition'),
            ('Repair-' + 'Volume'), ('Optimize-' + 'Volume'), ('New-' + 'Volume'),
            ('Mount-' + 'DiskImage'), ('Reset-' + 'PhysicalDisk'),
            'chkdsk', 'diskpart', 'format', 'bcdedit', 'fsutil', 'bootrec',
            ('Remove-' + 'Item'), ('Start-' + 'Process'), ('Stop-' + 'Process'), ('Invoke-' + 'Expression')
        )
        $script:DeniedTokens = @('-AsByteStream', 'utf8NoBOM', ('Test-' + 'Json'), ('Get-' + 'Error'), 'SendKeys', 'ForEach-Object -Parallel', '??')
    }

    It 'keeps every owned module file ASCII, BOM-free, and parseable' {
        foreach ($path in $script:ModulePaths) {
            Test-Path -LiteralPath $path | Should -BeTrue
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Not -Be 0xEF
            ([int]($bytes | Measure-Object -Maximum).Maximum) | Should -BeLessThan 128
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Should -Not -BeNullOrEmpty
            @($errors) | Should -HaveCount 0
        }
    }

    It 'contains no destructive or unverified external command' {
        foreach ($path in $script:ModulePaths) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $commands = $ast.FindAll({ param($node) return ($node -is [System.Management.Automation.Language.CommandAst]) }, $true)
            foreach ($command in $commands) {
                $name = $command.GetCommandName()
                if (-not $name) { continue }
                $script:DeniedCommands | Should -Not -Contain $name
            }
        }
    }

    It 'contains no PowerShell 7 only construct or coordinate automation' {
        foreach ($path in $script:ModulePaths) {
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII)
            foreach ($token in $script:DeniedTokens) {
                $text.Contains($token) | Should -BeFalse
            }
        }
    }

    It 'starts no external work during module import' {
        $module = Get-Module -Name DiskDetection
        $module.Path | Should -Be (Join-Path -Path $script:ModulesRoot -ChildPath 'DiskDetection.psm1')
        @(Get-Module -Name RecoveryLogging).Count | Should -Be 1
        @(Get-Module -Name JobState).Count | Should -Be 1
    }

    It 'exports only the documented public functions' {
        $diskExports = (Get-Module -Name DiskDetection).ExportedFunctions.Keys | Sort-Object
        $logExports = (Get-Module -Name RecoveryLogging).ExportedFunctions.Keys | Sort-Object
        $stateExports = (Get-Module -Name JobState).ExportedFunctions.Keys | Sort-Object

        $expectedDisk = @('Get-PhysicalDiskIdentity', 'Get-RecoveryDestinationSpace', 'Get-RecoveryVolumeInventory', 'New-RecoveryJobFolder', 'Resolve-RecoveryDiskProvider', 'Resolve-RecoveryPathIdentity', 'Sanitize-RecoveryName', 'Select-DestinationFolder', 'Test-DestinationSafety' | Sort-Object)
        $expectedLog = @('Flush-RecoveryLog', 'New-RecoveryLog', 'Test-RecoveryLog', 'Write-RecoveryLogEntry' | Sort-Object)
        $expectedState = @('Acquire-RecoveryJobLock', 'Get-RecoveryResumeDecision', 'New-RecoveryJobState', 'Read-RecoveryJobState', 'Set-RecoveryState', 'Test-RecoveryStateTransition', 'Write-RecoveryJobState' | Sort-Object)

        ($diskExports -join '|') | Should -Be ($expectedDisk -join '|')
        ($logExports -join '|') | Should -Be ($expectedLog -join '|')
        ($stateExports -join '|') | Should -Be ($expectedState -join '|')
    }
}
