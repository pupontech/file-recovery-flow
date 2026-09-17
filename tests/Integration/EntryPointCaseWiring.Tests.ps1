BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
    $script:EntryPoint = Join-Path -Path $script:RepoRoot -ChildPath 'RecoveryAutomation.ps1'
    . $script:EntryPoint
    $script:ConfigPath = Join-Path -Path $TestDrive -ChildPath 'case-wiring-config.json'
    $configText = '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}'
    Set-Content -LiteralPath $script:ConfigPath -Value $configText -Encoding ASCII

    function New-CaseWiringApplicationProvider {
        # One candidate provider for both products: identity evidence only, no
        # launch. The runs below inject every seam they need, so no real product,
        # process, or storage read is involved.
        return {
            param($product, $explicitPath)
            if ($product -eq 'FileScavenger') {
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.13'
                    ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'file-scavenger-wiring.bin'
                    EvidenceSource = 'CaseWiringFixture'
                }
            }
            return [pscustomobject]@{
                Path = $explicitPath
                Exists = $true
                Readable = $true
                FileVersion = '9.5.191810'
                ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'
                OriginalFilename = 'r-studio-wiring.bin'
                CompanyName = 'R-Tools Technology Inc.'
                OwnerValidated = $true
                OwnerEvidence = 'CaseWiringFixture'
                EvidenceSource = 'FileVersionInfo: CaseWiringFixture'
            }
        }.GetNewClosure()
    }

    function New-CaseWiringDiskRecord {
        param([int]$DiskNumber, [string]$UniqueId, [string]$Model, [int64]$SizeBytes)
        return [pscustomobject]@{
            DiskNumber = $DiskNumber
            UniqueId = $UniqueId
            UniqueIdFormat = 'WWN'
            SerialNumber = ('SERIAL-' + $UniqueId)
            Model = $Model
            SizeBytes = $SizeBytes
        }
    }

    function New-CaseWiringRun {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][object]$DiskProvider,
            [Parameter(Mandatory = $true)][string]$SourcePath,
            [Parameter(Mandatory = $true)][string]$DestinationPath,
            [string]$ClientName = 'Wiring Client',
            [scriptblock]$VendorRunner = $null
        )
        $filePath = Join-Path -Path $TestDrive -ChildPath 'file-scavenger-wiring.bin'
        $rStudioPath = Join-Path -Path $TestDrive -ChildPath 'r-studio-wiring.bin'
        Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII
        $candidateProvider = New-CaseWiringApplicationProvider
        if ($null -eq $VendorRunner) {
            $VendorRunner = { param($request) throw 'this run must not launch a vendor process' }
        }

        return Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $SourcePath -DestinationPath $DestinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $filePath; RStudioPath = $rStudioPath; ClientName = $ClientName } `
            -SourceProtectionProvider { return $true } -DiskProvider $DiskProvider `
            -FileScavengerDiscoveryProvider $candidateProvider -RStudioDiscoveryProvider $candidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'CaseWiringFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $VendorRunner
    }
}

Describe 'Entry point case creation wiring' {
    It 'records the case job id on the job lock the entry point acquires' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-lock-binding'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-lock-binding'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $disks = @(
            (New-CaseWiringDiskRecord -DiskNumber 4 -UniqueId 'LOCK-SOURCE-DISK' -Model 'Source' -SizeBytes 1000000)
            (New-CaseWiringDiskRecord -DiskNumber 5 -UniqueId 'LOCK-DESTINATION-DISK' -Model 'Destination' -SizeBytes 2000000)
        )
        $diskProvider = @{
            Name = 'CaseWiringLockFixture'
            GetDisks = {
                param($request)
                foreach ($disk in $disks) {
                    if ([int]$disk.DiskNumber -eq [int]$request.DiskNumber) { return $disk }
                }
                return $null
            }.GetNewClosure()
            ResolvePath = {
                param($request)
                $isSource = ([string]$request.Path -eq [string]$sourcePath)
                return [pscustomobject]@{
                    CanonicalPath = [string]$request.Path
                    Exists = $true
                    IsContainer = $true
                    ReparseResolved = $true
                    IsReparsePoint = $false
                    MembersIncomplete = $false
                    DiskNumber = if ($isSource) { 4 } else { 5 }
                    PartitionNumber = 1
                    VolumeGuid = if ($isSource) { 'LOCK-SOURCE-VOLUME' } else { 'LOCK-DESTINATION-VOLUME' }
                    VolumePath = if ($isSource) { 'LOCK-SOURCE-VOLUME-PATH' } else { 'LOCK-DESTINATION-VOLUME-PATH' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
        }
        $launches = New-Object System.Collections.Generic.List[string]
        $fileRunner = {
            param($path)
            $launches.Add([string]$path) | Out-Null
            return [pscustomobject]@{ Path = $path; Pid = 4901; StartTime = '2026-01-01T00:00:00Z' }
        }.GetNewClosure()

        $result = New-CaseWiringRun -DiskProvider $diskProvider -SourcePath $sourcePath `
            -DestinationPath $destinationPath -VendorRunner $fileRunner

        $result.JobFolderPath | Should -Not -BeNullOrEmpty
        $lockPath = Join-Path -Path $result.JobFolderPath -ChildPath 'job.lock'
        (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -BeTrue
        $lock = ([System.IO.File]::ReadAllText($lockPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
        $expectedJobId = [System.IO.Path]::GetFileName($result.JobFolderPath)
        # The lease, owner, and claim already bound the lock to the case folder;
        # without the job id the durable lock cannot contradict the state, so the
        # resume read refuses it as LockNotBound.
        [string]$lock.JobId | Should -Be $expectedJobId
        [string]$lock.Owner | Should -Be ('RecoveryAutomation/' + $expectedJobId)
    }

    It 're-proves the exact candidate folder before the claim marker can be written' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-claim-stage'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-claim-stage'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $disks = @(
            (New-CaseWiringDiskRecord -DiskNumber 4 -UniqueId 'STAGE-SOURCE-DISK' -Model 'Source' -SizeBytes 1000000)
            (New-CaseWiringDiskRecord -DiskNumber 5 -UniqueId 'STAGE-DESTINATION-DISK' -Model 'Destination' -SizeBytes 2000000)
        )
        # The topology answers with the destination disk while the candidate folder
        # does not exist yet, and starts reporting the source volume for that same
        # path once it does. Only a proof taken again for that exact path,
        # immediately before the claim marker is written, can refuse the write.
        $state = @{ CandidateResolutions = 0; CandidatePaths = New-Object System.Collections.Generic.List[string] }
        $diskProvider = @{
            Name = 'CaseWiringClaimStageFixture'
            GetDisks = {
                param($request)
                foreach ($disk in $disks) {
                    if ([int]$disk.DiskNumber -eq [int]$request.DiskNumber) { return $disk }
                }
                return $null
            }.GetNewClosure()
            ResolvePath = {
                param($request)
                $path = [string]$request.Path
                $isSource = ($path -eq [string]$sourcePath)
                $isRoot = ($path -eq [string]$destinationPath)
                $diskNumber = 5
                if ($isSource) {
                    $diskNumber = 4
                }
                elseif ($isRoot) {
                    $diskNumber = 5
                }
                elseif ([System.IO.Directory]::Exists($path)) {
                    $state.CandidateResolutions = $state.CandidateResolutions + 1
                    $state.CandidatePaths.Add($path) | Out-Null
                    $diskNumber = 4
                }
                else {
                    $state.CandidateResolutions = $state.CandidateResolutions + 1
                    $state.CandidatePaths.Add($path) | Out-Null
                    $diskNumber = 5
                }
                return [pscustomobject]@{
                    CanonicalPath = $path
                    Exists = $true
                    IsContainer = $true
                    ReparseResolved = $true
                    IsReparsePoint = $false
                    MembersIncomplete = $false
                    DiskNumber = $diskNumber
                    PartitionNumber = 1
                    VolumeGuid = if ($diskNumber -eq 4) { 'STAGE-SOURCE-VOLUME' } else { 'STAGE-DESTINATION-VOLUME' }
                    VolumePath = if ($diskNumber -eq 4) { 'STAGE-SOURCE-VOLUME-PATH' } else { 'STAGE-DESTINATION-VOLUME-PATH' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
        }

        $result = New-CaseWiringRun -DiskProvider $diskProvider -SourcePath $sourcePath `
            -DestinationPath $destinationPath -ClientName 'Claim Stage Client'

        $result.Success | Should -BeFalse
        # The candidate folder is reported on the source volume once it exists, so
        # the second proof refuses the claim even though the destination root was
        # proven separate a moment earlier.
        $result.ReasonCode | Should -Be 'SameVolume'
        $result.ExitCode | Should -Be 5
        $result.VendorLaunchAttempted | Should -BeFalse
        # Four proofs of that same candidate path: the identity before the
        # directory and the fresh resolution inside its separation check, then the
        # same pair again immediately before the claim marker. The second pair is
        # what refused the write.
        $state.CandidateResolutions | Should -Be 4
        @($state.CandidatePaths | Sort-Object -Unique).Count | Should -Be 1
        [string]$state.CandidatePaths[3] | Should -Be $state.CandidatePaths[1]
        ([System.IO.Directory]::GetFileSystemEntries($destinationPath)).Count | Should -Be 1
        $candidateFolder = [string]$state.CandidatePaths[1]
        @([System.IO.Directory]::GetFileSystemEntries($candidateFolder)).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path -Path $candidateFolder -ChildPath 'job-claim.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path -Path $candidateFolder -ChildPath 'job-state.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path -Path $candidateFolder -ChildPath 'events.jsonl')) | Should -BeFalse
    }
}
