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
}
