BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
    $script:EntryPoint = Join-Path -Path $script:RepoRoot -ChildPath 'RecoveryAutomation.ps1'
    $script:ConfigPath = Join-Path -Path $TestDrive -ChildPath 'dry-run-config.json'
    $configText = '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}'
    Set-Content -LiteralPath $script:ConfigPath -Value $configText -Encoding ASCII
    if (Test-Path -LiteralPath $script:EntryPoint -PathType Leaf) {
        . $script:EntryPoint
    }
    $script:ConfigPath = Join-Path -Path $TestDrive -ChildPath 'dry-run-config.json'
}

Describe 'RecoveryAutomation bounded entrypoint' {
    It 'does not overwrite a caller variable named configPath when dot sourced for tests' {
        $configPath = 'caller-owned-value'
        . $script:EntryPoint
        $configPath | Should -Be 'caller-owned-value'
    }

    It 'validates configuration and exits a dry run without touching vendor or recovery-media seams' {
        $vendorCalls = New-Object System.Collections.Generic.List[string]
        $mediaCalls = New-Object System.Collections.Generic.List[string]
        $vendorRunner = {
            param($request)
            $vendorCalls.Add('vendor') | Out-Null
            throw 'dry run must not launch a vendor process'
        }.GetNewClosure()
        $mediaProvider = {
            param($request)
            $mediaCalls.Add([string]$request.Operation) | Out-Null
            throw 'dry run must not query recovery media'
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -DryRun -NoPause `
            -VendorProcessRunner $vendorRunner -DiskProvider $mediaProvider

        $result.Success | Should -BeTrue
        $result.ExitCode | Should -Be 0
        $result.Mode | Should -Be 'DryRun'
        $result.ConfigurationValid | Should -BeTrue
        $result.VendorLaunchAttempted | Should -BeFalse
        $result.RecoveryMediaTouched | Should -BeFalse
        $vendorCalls | Should -HaveCount 0
        $mediaCalls | Should -HaveCount 0
    }

    It 'applies the explicit no-pause launcher option without changing safety settings' {
        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -DryRun -NoPause

        $result.Success | Should -BeTrue
        $result.Configuration.NoPause | Should -BeTrue
        $result.Configuration.AllowSameDiskOverride | Should -BeFalse
        $result.Configuration.AllowVendorOverwrite | Should -BeFalse
    }

    It 'refuses a destination on the source physical disk before any vendor launch' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null

        $sourceDisk = [pscustomobject]@{
            DiskNumber = 4
            UniqueId = 'SOURCE-DISK'
            UniqueIdFormat = 'WWN'
            SerialNumber = 'SOURCE-SERIAL'
            Model = 'FixtureSource'
            SizeBytes = 1000000
        }
        $sameDiskProvider = @{
            Name = 'IntegrationFixture'
            GetDisks = {
                param($request)
                return @($sourceDisk)
            }.GetNewClosure()
            ResolvePath = {
                param($request)
                return [pscustomobject]@{
                    CanonicalPath = [string]$request.Path
                    Exists = $true
                    IsContainer = $true
                    ReparseResolved = $true
                    IsReparsePoint = $false
                    MembersIncomplete = $false
                    DiskNumber = 4
                    PartitionNumber = 1
                    VolumeGuid = if ($request.Path -eq $sourcePath) { 'SOURCE-VOLUME' } else { 'DESTINATION-VOLUME' }
                    VolumePath = 'SOURCE-VOLUME-PATH'
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }
        }
        $filePath = Join-Path -Path $TestDrive -ChildPath 'file-scavenger.bin'
        $rStudioPath = Join-Path -Path $TestDrive -ChildPath 'r-studio.bin'
        Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII
        $candidateProvider = {
            param($product, $explicitPath)
            if ($product -eq 'FileScavenger') {
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.13'
                    ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'file-scavenger.bin'
                    EvidenceSource = 'IntegrationFixture'
                }
            }
            return [pscustomobject]@{
                Path = $explicitPath
                Exists = $true
                Readable = $true
                FileVersion = '9.5.191810'
                ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'
                OriginalFilename = 'r-studio.bin'
                CompanyName = 'R-Tools Technology Inc.'
                OwnerValidated = $true
                OwnerEvidence = 'IntegrationFixture'
                EvidenceSource = 'FileVersionInfo: IntegrationFixture'
            }
        }.GetNewClosure()
        $vendorCalls = New-Object System.Collections.Generic.List[string]
        $vendorRunner = {
            param($request)
            $vendorCalls.Add([string]$request.Purpose) | Out-Null
            throw 'same-disk refusal must happen before vendor launch'
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $sourcePath -DestinationPath $destinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $filePath; RStudioPath = $rStudioPath } `
            -SourceProtectionProvider { return $true } `
            -DiskProvider $sameDiskProvider `
            -FileScavengerDiscoveryProvider $candidateProvider `
            -RStudioDiscoveryProvider $candidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') `
            -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
            -ElevationProvider { return $true } `
            -VendorProcessRunner $vendorRunner

        $result.Success | Should -BeFalse
        $result.ExitCode | Should -Not -Be 0
        $result.ReasonCode | Should -Be 'SamePhysicalDisk'
        $result.VendorLaunchAttempted | Should -BeFalse
        $result.RecoveryMediaTouched | Should -BeTrue
        $vendorCalls | Should -HaveCount 0
    }

    It 'creates a durable case before launching File Scavenger without scanner arguments' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-safe'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-safe'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $filePath = Join-Path -Path $TestDrive -ChildPath 'file-scavenger-safe.bin'
        $rStudioPath = Join-Path -Path $TestDrive -ChildPath 'r-studio-safe.bin'
        Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII

        $disks = @(
            [pscustomobject]@{ DiskNumber = 4; UniqueId = 'SOURCE-DISK'; UniqueIdFormat = 'WWN'; SerialNumber = 'SOURCE-SERIAL'; Model = 'Source'; SizeBytes = 1000000 }
            [pscustomobject]@{ DiskNumber = 5; UniqueId = 'DESTINATION-DISK'; UniqueIdFormat = 'WWN'; SerialNumber = 'DESTINATION-SERIAL'; Model = 'Destination'; SizeBytes = 2000000 }
        )
        $diskProvider = @{
            Name = 'IntegrationFixtureSeparateDisks'
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
                    VolumeGuid = if ($isSource) { 'SOURCE-VOLUME' } else { 'DESTINATION-VOLUME' }
                    VolumePath = if ($isSource) { 'SOURCE-VOLUME-PATH' } else { 'DESTINATION-VOLUME-PATH' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
        }
        $candidateProvider = {
            param($product, $explicitPath)
            if ($product -eq 'FileScavenger') {
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.13'
                    ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'file-scavenger-safe.bin'
                    EvidenceSource = 'IntegrationFixture'
                }
            }
            return [pscustomobject]@{
                Path = $explicitPath
                Exists = $true
                Readable = $true
                FileVersion = '9.5.191810'
                ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'
                OriginalFilename = 'r-studio-safe.bin'
                CompanyName = 'R-Tools Technology Inc.'
                OwnerValidated = $true
                OwnerEvidence = 'IntegrationFixture'
                EvidenceSource = 'FileVersionInfo: IntegrationFixture'
            }
        }.GetNewClosure()
        $launches = New-Object System.Collections.Generic.List[string]
        $fileRunner = {
            param($path)
            $launches.Add([string]$path) | Out-Null
            return [pscustomobject]@{ Path = $path; Pid = 4811; StartTime = '2026-01-01T00:00:00Z' }
        }.GetNewClosure()

        $protectionCalls = New-Object System.Collections.Generic.List[string]
        $sourceProtection = {
            param($request)
            $protectionCalls.Add('checked') | Out-Null
            return $true
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $sourcePath -DestinationPath $destinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $filePath; RStudioPath = $rStudioPath; ClientName = 'Client Alpha' } `
            -SourceProtectionProvider $sourceProtection -DiskProvider $diskProvider `
            -FileScavengerDiscoveryProvider $candidateProvider -RStudioDiscoveryProvider $candidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $fileRunner

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'ManualGatePending'
        $result.CurrentState | Should -Be 'SHORT_SCAN_RUNNING'
        $result.VendorLaunchAttempted | Should -BeTrue
        $launches | Should -HaveCount 1
        $launches[0] | Should -Be $filePath
        $result.JobFolderPath | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path -Path $result.JobFolderPath -ChildPath 'job-claim.json') -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path -Path $result.JobFolderPath -ChildPath 'job.lock') -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath $result.StatePath -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath $result.LogPath -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path -Path $result.JobFolderPath -ChildPath 'case-metadata.json') -PathType Leaf) | Should -BeTrue
        $logText = Get-Content -LiteralPath $result.LogPath -Raw
        $logText | Should -Match 'SourceIdentityCaptured'
        $logText | Should -Match 'StageStarted'
        $logText | Should -Not -Match 'ScannerArguments'
        $protectionCalls.Count | Should -BeGreaterThan 1
    }

    It 'fails closed when the post-launch G-04 gate snapshot cannot be written' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-gate-write'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-gate-write'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $filePath = Join-Path -Path $TestDrive -ChildPath 'file-scavenger-gate-write.bin'
        $rStudioPath = Join-Path -Path $TestDrive -ChildPath 'r-studio-gate-write.bin'
        Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII

        $disks = @(
            [pscustomobject]@{ DiskNumber = 4; UniqueId = 'SOURCE-DISK-GATE'; UniqueIdFormat = 'WWN'; SerialNumber = 'SOURCE-SERIAL-GATE'; Model = 'Source'; SizeBytes = 1000000 }
            [pscustomobject]@{ DiskNumber = 5; UniqueId = 'DESTINATION-DISK-GATE'; UniqueIdFormat = 'WWN'; SerialNumber = 'DESTINATION-SERIAL-GATE'; Model = 'Destination'; SizeBytes = 2000000 }
        )
        $diskProvider = @{
            Name = 'IntegrationFixtureGateWrite'
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
                    VolumeGuid = if ($isSource) { 'SOURCE-VOLUME-GATE' } else { 'DESTINATION-VOLUME-GATE' }
                    VolumePath = if ($isSource) { 'SOURCE-VOLUME-PATH-GATE' } else { 'DESTINATION-VOLUME-PATH-GATE' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
        }
        $candidateProvider = {
            param($product, $explicitPath)
            if ($product -eq 'FileScavenger') {
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.13'
                    ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'file-scavenger-gate-write.bin'
                    EvidenceSource = 'IntegrationFixture'
                }
            }
            return [pscustomobject]@{
                Path = $explicitPath
                Exists = $true
                Readable = $true
                FileVersion = '9.5.191810'
                ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'
                OriginalFilename = 'r-studio-gate-write.bin'
                CompanyName = 'R-Tools Technology Inc.'
                OwnerValidated = $true
                OwnerEvidence = 'IntegrationFixture'
                EvidenceSource = 'FileVersionInfo: IntegrationFixture'
            }
        }.GetNewClosure()
        $fileRunner = {
            param($path)
            return [pscustomobject]@{ Path = $path; Pid = 4812; StartTime = '2026-01-01T00:00:00Z' }
        }.GetNewClosure()
        $stateWrites = New-Object System.Collections.Generic.List[string]
        $stateWriter = @{
            Write = {
                param($request)
                $gateCount = @($request.State.GateDecisions).Count
                $stateWrites.Add(([string]$request.State.State + ':' + [string]$gateCount)) | Out-Null
                if ([string]$request.State.State -eq 'SHORT_SCAN_RUNNING' -and $gateCount -gt 0) {
                    return $null
                }
                return [pscustomobject]@{ Success = $true }
            }.GetNewClosure()
        }

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $sourcePath -DestinationPath $destinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $filePath; RStudioPath = $rStudioPath; ClientName = 'Gate Write Client' } `
            -SourceProtectionProvider { return $true } -DiskProvider $diskProvider `
            -FileScavengerDiscoveryProvider $candidateProvider -RStudioDiscoveryProvider $candidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $fileRunner `
            -StateWriterProvider $stateWriter

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'GateStateWriteFailed'
        $result.CurrentState | Should -Be 'SHORT_SCAN_RUNNING'
        $stateWrites | Should -Contain 'SHORT_SCAN_RUNNING:1'
    }

    It 'drives the documented short and long recovery path before the launch-only handoff' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-forward'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-forward'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $filePath = Join-Path -Path $TestDrive -ChildPath 'file-scavenger-forward.bin'
        $rStudioPath = Join-Path -Path $TestDrive -ChildPath 'r-studio-forward.bin'
        Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII

        $disks = @(
            [pscustomobject]@{ DiskNumber = 4; UniqueId = 'SOURCE-DISK-FORWARD'; UniqueIdFormat = 'WWN'; SerialNumber = 'SOURCE-SERIAL-FORWARD'; Model = 'Source'; SizeBytes = 1000000; PartitionStyle = 2; MembersIncomplete = $false }
            [pscustomobject]@{ DiskNumber = 5; UniqueId = 'DESTINATION-DISK-FORWARD'; UniqueIdFormat = 'WWN'; SerialNumber = 'DESTINATION-SERIAL-FORWARD'; Model = 'Destination'; SizeBytes = 2000000; PartitionStyle = 2; MembersIncomplete = $false }
        )
        $diskProvider = @{
            Name = 'IntegrationFixtureForward'
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
                    VolumeGuid = if ($isSource) { 'SOURCE-VOLUME-FORWARD' } else { 'DESTINATION-VOLUME-FORWARD' }
                    VolumePath = if ($isSource) { 'SOURCE-VOLUME-PATH-FORWARD' } else { 'DESTINATION-VOLUME-PATH-FORWARD' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }
        }
        $candidateProvider = {
            param($product, $explicitPath)
            if ($product -eq 'FileScavenger') {
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.13'
                    ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'file-scavenger-forward.bin'
                    EvidenceSource = 'IntegrationFixture'
                }
            }
            return [pscustomobject]@{
                Path = $explicitPath
                Exists = $true
                Readable = $true
                FileVersion = '9.5.191810'
                ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'
                OriginalFilename = 'r-studio-forward.bin'
                CompanyName = 'R-Tools Technology Inc.'
                OwnerValidated = $true
                OwnerEvidence = 'IntegrationFixture'
                EvidenceSource = 'FileVersionInfo: IntegrationFixture'
            }
        }.GetNewClosure()
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'IntegrationFixture'
            AutomationId = 'forward-control'
        }
        $fileScavengerMap = @{
            Product = 'File Scavenger'
            OwnerValidated = $true
            Build = '7.1.1.13'
            Stages = @{
                SHORT_SCAN = @{ Action = 'Scan'; ControlDescriptor = $descriptor; ResultEvidence = @{ Source = 'IntegrationFixture' } }
                SHORT_RECOVERY = @{ Action = 'Save'; ControlDescriptor = $descriptor; ResultEvidence = @{ Source = 'IntegrationFixture' } }
                LONG_SCAN = @{ Action = 'Scan'; ControlDescriptor = $descriptor; ResultEvidence = @{ Source = 'IntegrationFixture' } }
                LONG_RECOVERY = @{ Action = 'Save'; ControlDescriptor = $descriptor; ResultEvidence = @{ Source = 'IntegrationFixture' } }
            }
            GracefulClose = @{ ControlDescriptor = $descriptor }
        }
        $uiActions = New-Object System.Collections.Generic.List[string]
        $fileScavengerUi = {
            param($first, $second)
            if ($null -ne $second) {
                $uiActions.Add([string]$first) | Out-Null
                return [pscustomobject]@{ Invoked = $true }
            }
            return [pscustomobject]@{
                WindowPresent = $true
                Ready = $true
                ProcessAlive = $true
                ProcessExited = $false
                ActiveWork = $false
                ScanRunning = $false
                RecoveryRunning = $false
                Unknown = $false
                Confidence = 'Observed'
            }
        }.GetNewClosure()
        $closeObservationCount = New-Object System.Collections.Generic.List[int]
        $operatorEvidence = @{
            GetEvidence = {
                param($request)
                if ([string]$request.Stage -eq 'CLOSE') {
                    $closeObservationCount.Add(1)
                    if ($closeObservationCount.Count -gt 1) {
                        return [pscustomobject]@{
                            State = 'LONG_RECOVERY_VERIFIED'
                            RecoveryFinished = $true
                            RecoveryVerified = $true
                            OutputVerified = $true
                            OutputObserved = $true
                            GracefulCloseVerified = $true
                            ProcessTerminated = $true
                            ActiveWork = $false
                            Unknown = $false
                            WindowPresent = $false
                            ObservedArtifacts = @('forward-output')
                        }
                    }
                    return [pscustomobject]@{
                        State = 'LONG_RECOVERY_VERIFIED'
                        RecoveryFinished = $true
                        RecoveryVerified = $true
                        OutputVerified = $true
                        OutputObserved = $true
                        GracefulCloseVerified = $false
                        ProcessTerminated = $false
                        ActiveWork = $false
                        Unknown = $false
                        WindowPresent = $true
                        ObservedArtifacts = @('forward-output')
                    }
                }
                if ([string]$request.Stage -eq 'SHORT_SCAN' -or [string]$request.Stage -eq 'LONG_SCAN') {
                    return [pscustomobject]@{
                        State = [string]$request.Stage + '_RUNNING'
                        ScanFinished = $true
                        OutputObserved = $false
                        WindowPresent = $true
                        Unknown = $false
                    }
                }
                return [pscustomobject]@{
                    State = [string]$request.Stage + '_RUNNING'
                    RecoveryFinished = $true
                    RecoveryVerified = $true
                    OutputVerified = $true
                    OutputObserved = $true
                    WindowPresent = $true
                    Unknown = $false
                    ObservedArtifacts = @('forward-output')
                }
            }.GetNewClosure()
        }
        $responses = New-Object System.Collections.Generic.List[string]
        foreach ($response in @('Continue', 'Continue', 'Continue', 'Continue', 'Continue', 'Continue')) {
            $responses.Add($response) | Out-Null
        }
        $interaction = {
            param($request)
            if ($responses.Count -eq 0) { return 'Stop' }
            $response = $responses[0]
            $responses.RemoveAt(0)
            return $response
        }.GetNewClosure()
        $fileRunner = {
            param($path)
            return [pscustomobject]@{ Path = $path; Pid = 4821; StartTime = '2026-01-01T00:00:00Z' }
        }.GetNewClosure()
        $handoffRunner = {
            param($request)
            return [pscustomobject]@{ Success = $true; ProcessId = 7321; StartTimeUtc = '2026-01-01T00:00:00Z'; Name = 'RStudio'; Path = $rStudioPath }
        }.GetNewClosure()
        $protectionCalls = New-Object System.Collections.Generic.List[string]
        $sourceProtection = {
            param($request)
            $protectionCalls.Add([string]$request.Purpose) | Out-Null
            return $true
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $sourcePath -DestinationPath $destinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $filePath; RStudioPath = $rStudioPath; ClientName = 'Forward Client' } `
            -SourceProtectionProvider $sourceProtection -DiskProvider $diskProvider `
            -FileScavengerDiscoveryProvider $candidateProvider -RStudioDiscoveryProvider $candidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $fileRunner `
            -RStudioProcessRunner $handoffRunner -FileScavengerEvidenceMap $fileScavengerMap `
            -FileScavengerUiProvider $fileScavengerUi -OperatorEvidenceProvider $operatorEvidence `
            -InteractionProvider $interaction

        $result.Success | Should -BeTrue
        $result.CurrentState | Should -Be 'HANDOFF_MANUAL'
        $result.Handoff.Launched | Should -BeTrue
        @($uiActions) | Should -Be @('Scan', 'Save', 'Scan', 'Save', 'Exit')
        $responses | Should -HaveCount 0
        $protectionCalls.Count | Should -BeGreaterThan 6
        $logText = Get-Content -LiteralPath $result.LogPath -Raw
        $logText | Should -Match 'LONG_RECOVERY_VERIFIED'
        $logText | Should -Match 'GracefulCloseVerified'
        $logText | Should -Match 'RStudioLaunchOnlyHandoff'
        $savedState = Get-Content -LiteralPath $result.StatePath -Raw | ConvertFrom-Json
        $savedState.State | Should -Be 'HANDOFF_MANUAL'
        $savedState.LastEventSequence | Should -Be ((Get-Content -LiteralPath $result.LogPath).Count)
    }

    It 'hands off to R-Studio with only the documented launch arguments after READY_FOR_HANDOFF' {
        Import-RecoveryAutomationModules
        $jobPath = Join-Path -Path $TestDrive -ChildPath 'handoff-job'
        New-Item -ItemType Directory -Path $jobPath -Force | Out-Null
        $statePaths = [pscustomobject]@{
            JobFolderPath = $jobPath
            StatePath = Join-Path -Path $jobPath -ChildPath 'job-state.json'
            LogPath = Join-Path -Path $jobPath -ChildPath 'events.jsonl'
        }
        $identity = [pscustomobject]@{
            Resolved = $true
            IsIndeterminate = $false
            VolumeGuid = 'VOLUME-1'
            IdentityKeys = @('DISK-1')
            PhysicalDisks = @([pscustomobject]@{ IdentityKey = 'DISK-1' })
        }
        $state = JobState\New-RecoveryJobState -JobId 'handoff-job' -SourceIdentity $identity `
            -DestinationIdentity ([pscustomobject]@{
                Resolved = $true
                IsIndeterminate = $false
                VolumeGuid = 'VOLUME-2'
                IdentityKeys = @('DISK-2')
                PhysicalDisks = @([pscustomobject]@{ IdentityKey = 'DISK-2' })
            }) `
            -ApplicationEvidence ([pscustomobject]@{}) -Paths $statePaths -WorkflowVersion '1.0.0' `
            -State 'READY_FOR_HANDOFF'
        $state | Add-Member -NotePropertyName FileScavengerCloseVerified -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName OutputVerified -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName SourceIdentityVerified -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName DestinationIdentityVerified -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName LogDurable -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName StateDurable -NotePropertyValue $true -Force
        $executable = [pscustomobject]@{
            Path = Join-Path -Path $TestDrive -ChildPath 'RStudio.exe'
            Product = 'RStudio'
            ProductName = 'R-Studio'
            IdentityStatus = 'Verified'
            Exists = $true
            OriginalFilename = 'RStudio.exe'
            FileVersion = '9.5.191810'
            ProductVersion = '9.5.191810'
            CompanyName = 'R-Tools Technology Inc.'
            OwnerValidated = $true
            OwnerEvidence = 'IntegrationFixture'
            EvidenceSource = 'IntegrationFixture'
        }
        Set-Content -LiteralPath $executable.Path -Value 'fixture' -Encoding ASCII
        $logPath = $statePaths.LogPath
        $handoffArguments = New-Object System.Collections.Generic.List[object]
        $events = New-Object System.Collections.Generic.List[object]
        $handoffRunner = {
            param($request)
            $handoffArguments.Add(@($request.Arguments)) | Out-Null
            return [pscustomobject]@{ Success = $true; ProcessId = 7311; StartTimeUtc = '2026-01-01T00:00:00Z'; Name = 'RStudio'; Path = $executable.Path }
        }.GetNewClosure()
        $eventWriter = {
            param($event)
            $events.Add($event) | Out-Null
            return $true
        }.GetNewClosure()
        $stateWriter = @{
            Write = {
                param($request)
                return @{ Success = $true }
            }
        }
        $logValidator = {
            param($path)
            return [pscustomobject]@{ Allowed = $true; Evidence = 'IntegrationFixture' }
        }

        $result = Invoke-RecoveryAutomationHandoff -State $state -Executable $executable `
            -LogPath $logPath -ProcessRunner $handoffRunner -LogPathSafetyValidator $logValidator `
            -EventWriter $eventWriter -StateWriter $stateWriter
        $result.Allowed | Should -BeTrue
        $result.Handoff.Launched | Should -BeTrue
        $result.Handoff.AnalysisInvoked | Should -BeFalse
        $result.State.State | Should -Be 'HANDOFF_MANUAL'
        $handoffArguments | Should -HaveCount 1
        @($handoffArguments[0]) | Should -Be @('-safe', '-log', $logPath)
        @($events | ForEach-Object { $_.EventType }) | Should -Contain 'RStudioLaunchOnlyHandoff'
    }
}

Describe 'RecoveryAutomation production disk provider topology' {

    BeforeAll {
        # Get-Volume, Get-Partition, Get-Disk, and Get-Item shaped fixtures. The
        # production provider is built through its read-only query seams so the
        # topology it publishes can be inspected without a Windows host. The
        # seams replace only the four storage reads; every safety decision stays
        # in the production provider, the module, and the entry point.

        function New-TopologyVolume {
            param(
                [string]$DriveLetter = 'F',
                [string]$UniqueId = 'VOLUME-GUID-F',
                [string]$Path = 'VOLUME-PATH-F'
            )
            return [pscustomobject]@{
                DriveLetter     = $DriveLetter
                Path            = $Path
                UniqueId        = $UniqueId
                FileSystemLabel = 'TopologyFixture'
                FileSystem      = 'NTFS'
                Size            = 4000000000
                SizeRemaining   = 3000000000
            }
        }

        function New-TopologyPartition {
            param(
                [int]$DiskNumber = 4,
                [int]$PartitionNumber = 1,
                [string]$DriveLetter = 'F'
            )
            return [pscustomobject]@{
                DiskNumber      = $DiskNumber
                PartitionNumber = $PartitionNumber
                DriveLetter     = $DriveLetter
                Size            = 1000000000
            }
        }

        function New-TopologyDisk {
            param(
                [int]$Number = 4,
                [bool]$IsDynamic = $false,
                [int]$BusType = 11,
                [bool]$DropDynamicStatement = $false
            )
            $disk = [ordered]@{
                Number            = $Number
                UniqueId          = 'DISK-GUID-' + [string]$Number
                UniqueIdFormat    = 'WWN'
                SerialNumber      = 'SERIAL-' + [string]$Number
                Model             = 'TopologyDisk' + [string]$Number
                FriendlyName      = 'Topology Disk ' + [string]$Number
                Manufacturer      = 'FixtureVendor'
                Size              = 1000000000
                BusType           = $BusType
                Location          = 'PCIROOT(0)#PCI(1F02)'
                PNPDeviceID       = 'SCSI\DISK&VEN_FIXTURE'
                IsDynamic         = $IsDynamic
                HealthStatus      = 'Healthy'
                OperationalStatus = 'Online'
            }
            if ($DropDynamicStatement) { $disk.Remove('IsDynamic') }
            return ([pscustomobject]$disk)
        }

        function New-TopologyItem {
            param([string]$Path)
            return [pscustomobject]@{
                FullName      = $Path
                PSIsContainer = $true
                Attributes    = 'Directory'
            }
        }

        function New-TopologyQueryLog {
            return (New-Object System.Collections.Generic.List[string])
        }

        function New-TopologyProvider {
            param(
                [object[]]$VolumeIndex = @(),
                [object[]]$VolumePartitions = @(),
                [object[]]$LetterPartitions = @(),
                [object[]]$Disks = @(),
                [object[]]$Items = @(),
                [object]$QueryLog = $null
            )
            $volumeQuery = {
                param($request)
                $operation = [string]$request['Operation']
                if ($null -ne $QueryLog) { $QueryLog.Add('VolumeQuery:' + $operation) | Out-Null }
                if ($operation -eq 'ListVolumes') {
                    $listed = New-Object System.Collections.Generic.List[object]
                    foreach ($entry in $VolumeIndex) { $listed.Add($entry.Volume) | Out-Null }
                    return $listed.ToArray()
                }
                if ($operation -eq 'VolumeForPath') {
                    $path = [string]$request['Path']
                    foreach ($entry in $VolumeIndex) {
                        if (([string]$entry.Path).Equals($path, [System.StringComparison]::OrdinalIgnoreCase)) { return @($entry.Volume) }
                    }
                    return @()
                }
                throw ('Unsupported volume query operation: ' + $operation)
            }.GetNewClosure()
            $partitionQuery = {
                param($request)
                $operation = [string]$request['Operation']
                if ($operation -eq 'PartitionsForVolume') {
                    $volumeGuid = [string]$request['VolumeGuid']
                    if ($null -ne $QueryLog) { $QueryLog.Add('PartitionsForVolume:' + $volumeGuid) | Out-Null }
                    foreach ($entry in $VolumePartitions) {
                        if (([string]$entry.VolumeGuid).Equals($volumeGuid, [System.StringComparison]::OrdinalIgnoreCase)) { return @($entry.Partitions) }
                    }
                    return @()
                }
                if ($operation -eq 'PartitionsForDriveLetter') {
                    $letter = [string]$request['DriveLetter']
                    if ($null -ne $QueryLog) { $QueryLog.Add('PartitionsForDriveLetter:' + $letter) | Out-Null }
                    foreach ($entry in $LetterPartitions) {
                        if (([string]$entry.DriveLetter).Equals($letter, [System.StringComparison]::OrdinalIgnoreCase)) { return @($entry.Partitions) }
                    }
                    return @()
                }
                throw ('Unsupported partition query operation: ' + $operation)
            }.GetNewClosure()
            $diskQuery = {
                param($request)
                $number = [int]$request['DiskNumber']
                if ($null -ne $QueryLog) { $QueryLog.Add('DiskQuery:' + [string]$number) | Out-Null }
                $found = New-Object System.Collections.Generic.List[object]
                foreach ($disk in $Disks) {
                    if ([int]$disk.Number -eq $number) { $found.Add($disk) | Out-Null }
                }
                return $found.ToArray()
            }.GetNewClosure()
            $itemQuery = {
                param($request)
                $path = [string]$request['Path']
                if ($null -ne $QueryLog) { $QueryLog.Add('ItemQuery') | Out-Null }
                foreach ($item in $Items) {
                    if (([string]$item.FullName).Equals($path, [System.StringComparison]::OrdinalIgnoreCase)) { return $item }
                }
                return $null
            }.GetNewClosure()
            return New-RecoveryAutomationWindowsDiskProvider -VolumeQuery $volumeQuery `
                -PartitionQuery $partitionQuery -DiskQuery $diskQuery -ItemQuery $itemQuery
        }

        function New-TopologyApplicationProvider {
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
                        OriginalFilename = 'file-scavenger-topology.bin'
                        EvidenceSource = 'IntegrationFixture'
                    }
                }
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '9.5.191810'
                    ProductVersion = '9.5.191810'
                    ProductName = 'R-Studio'
                    OriginalFilename = 'r-studio-topology.bin'
                    CompanyName = 'R-Tools Technology Inc.'
                    OwnerValidated = $true
                    OwnerEvidence = 'IntegrationFixture'
                    EvidenceSource = 'FileVersionInfo: IntegrationFixture'
                }
            }.GetNewClosure()
        }

        function Invoke-TopologyRun {
            param(
                [object]$Provider,
                [string]$SourcePath,
                [string]$DestinationPath,
                [string]$ClientName = 'Topology Client'
            )
            $filePath = Join-Path -Path $TestDrive -ChildPath 'file-scavenger-topology.bin'
            $rStudioPath = Join-Path -Path $TestDrive -ChildPath 'r-studio-topology.bin'
            Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
            Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII
            $candidateProvider = New-TopologyApplicationProvider
            $vendorCalls = New-Object System.Collections.Generic.List[string]
            $vendorRunner = {
                param($request)
                $vendorCalls.Add([string]$request.Purpose) | Out-Null
                throw 'a refused topology must not reach a vendor process launch'
            }.GetNewClosure()

            $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
                -SourcePath $SourcePath -DestinationPath $DestinationPath `
                -ConfigurationOverrides @{ FileScavengerPath = $filePath; RStudioPath = $rStudioPath; ClientName = $ClientName } `
                -SourceProtectionProvider { return $true } -DiskProvider $Provider `
                -FileScavengerDiscoveryProvider $candidateProvider -RStudioDiscoveryProvider $candidateProvider `
                -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
                -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
                -ElevationProvider { return $true } -VendorProcessRunner $vendorRunner

            return [pscustomobject]@{ Result = $result; VendorCalls = $vendorCalls }
        }
    }

    It 'refuses a source on a disk that reports dynamic membership instead of asserting a basic disk' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-dynamic'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-dynamic'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null

        $provider = New-TopologyProvider `
            -VolumeIndex @(
                @{ Path = $sourcePath; Volume = (New-TopologyVolume -DriveLetter 'F' -UniqueId 'VOLUME-DYNAMIC-SOURCE' -Path 'VOLUME-PATH-DYNAMIC-SOURCE') }
                @{ Path = $destinationPath; Volume = (New-TopologyVolume -DriveLetter 'G' -UniqueId 'VOLUME-DYNAMIC-DESTINATION' -Path 'VOLUME-PATH-DYNAMIC-DESTINATION') }
            ) `
            -VolumePartitions @(
                @{ VolumeGuid = 'VOLUME-DYNAMIC-SOURCE'; Partitions = @((New-TopologyPartition -DiskNumber 4 -PartitionNumber 1 -DriveLetter 'F')) }
                @{ VolumeGuid = 'VOLUME-DYNAMIC-DESTINATION'; Partitions = @((New-TopologyPartition -DiskNumber 5 -PartitionNumber 1 -DriveLetter 'G')) }
            ) `
            -Disks @(
                (New-TopologyDisk -Number 4 -IsDynamic $true)
                (New-TopologyDisk -Number 5 -IsDynamic $false)
            ) `
            -Items @((New-TopologyItem -Path $sourcePath), (New-TopologyItem -Path $destinationPath))

        $run = Invoke-TopologyRun -Provider $provider -SourcePath $sourcePath -DestinationPath $destinationPath

        $run.Result.Success | Should -BeFalse
        $run.Result.ExitCode | Should -Be 4
        $run.Result.ReasonCode | Should -Be 'SourceIndeterminate'
        $run.Result.VendorLaunchAttempted | Should -BeFalse
        @($run.VendorCalls) | Should -HaveCount 0
        @($run.Result.SourceIdentity.PhysicalDisks)[0].ReasonCode | Should -Be 'DynamicDiskBacking'
    }

    It 'refuses a destination on a second member of a multi-member volume that shares the source disk' {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'source-spanned'
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'destination-spanned'
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null

        $provider = New-TopologyProvider `
            -VolumeIndex @(
                @{ Path = $sourcePath; Volume = (New-TopologyVolume -DriveLetter 'S' -UniqueId 'VOLUME-SPANNED-SOURCE' -Path 'VOLUME-PATH-SPANNED-SOURCE') }
                @{ Path = $destinationPath; Volume = (New-TopologyVolume -DriveLetter 'T' -UniqueId 'VOLUME-SPANNED-DESTINATION' -Path 'VOLUME-PATH-SPANNED-DESTINATION') }
            ) `
            -VolumePartitions @(
                @{ VolumeGuid = 'VOLUME-SPANNED-SOURCE'; Partitions = @((New-TopologyPartition -DiskNumber 4 -PartitionNumber 1 -DriveLetter 'S'), (New-TopologyPartition -DiskNumber 5 -PartitionNumber 2 -DriveLetter 'S')) }
                @{ VolumeGuid = 'VOLUME-SPANNED-DESTINATION'; Partitions = @((New-TopologyPartition -DiskNumber 5 -PartitionNumber 1 -DriveLetter 'T'), (New-TopologyPartition -DiskNumber 6 -PartitionNumber 2 -DriveLetter 'T')) }
            ) `
            -Disks @(
                (New-TopologyDisk -Number 4)
                (New-TopologyDisk -Number 5)
                (New-TopologyDisk -Number 6)
            ) `
            -Items @((New-TopologyItem -Path $sourcePath), (New-TopologyItem -Path $destinationPath))

        $run = Invoke-TopologyRun -Provider $provider -SourcePath $sourcePath -DestinationPath $destinationPath -ClientName 'Spanned Client'

        $run.Result.Success | Should -BeFalse
        $run.Result.ExitCode | Should -Be 5
        $run.Result.ReasonCode | Should -Be 'SamePhysicalDisk'
        $run.Result.VendorLaunchAttempted | Should -BeFalse
        @($run.VendorCalls) | Should -HaveCount 0
        @($run.Result.SourceIdentity.PhysicalDisks) | Should -HaveCount 2
        @($run.Result.DestinationIdentity.PhysicalDisks) | Should -HaveCount 2
    }

    It 'resolves a letterless mounted-folder volume through every member the provider can see' {
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'mounted-folder-destination'
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null

        $provider = New-TopologyProvider `
            -VolumeIndex @(
                @{ Path = $destinationPath; Volume = (New-TopologyVolume -DriveLetter '' -UniqueId 'VOLUME-MOUNTED-FOLDER' -Path 'VOLUME-PATH-MOUNTED-FOLDER') }
            ) `
            -VolumePartitions @(
                @{ VolumeGuid = 'VOLUME-MOUNTED-FOLDER'; Partitions = @((New-TopologyPartition -DiskNumber 8 -PartitionNumber 1 -DriveLetter '')) }
            ) `
            -Disks @((New-TopologyDisk -Number 8)) `
            -Items @((New-TopologyItem -Path $destinationPath))

        $records = @(& $provider.GetVolumes @{ Operation = 'GetVolumes' })
        $records | Should -HaveCount 1
        $records[0].DriveLetter | Should -Be ''
        $records[0].MembersIncomplete | Should -BeFalse
        @($records[0].PhysicalDiskNumbers) | Should -Be @(8)

        $record = & $provider.ResolvePath @{ Operation = 'ResolvePath'; Path = $destinationPath }
        $record.MembersIncomplete | Should -BeFalse
        @($record.PhysicalDiskNumbers) | Should -Be @(8)
    }

    It 'marks an unresolvable letterless volume indeterminate instead of a provider failure' {
        $destinationPath = Join-Path -Path $TestDrive -ChildPath 'unresolved-folder-destination'
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $log = New-TopologyQueryLog

        $provider = New-TopologyProvider `
            -VolumeIndex @(
                @{ Path = $destinationPath; Volume = (New-TopologyVolume -DriveLetter '' -UniqueId 'VOLUME-UNRESOLVED' -Path 'VOLUME-PATH-UNRESOLVED') }
            ) `
            -VolumePartitions @() `
            -LetterPartitions @() `
            -Disks @() `
            -Items @((New-TopologyItem -Path $destinationPath)) `
            -QueryLog $log

        $record = & $provider.ResolvePath @{ Operation = 'ResolvePath'; Path = $destinationPath }
        $record.MembersIncomplete | Should -BeTrue
        @($record.PhysicalDiskNumbers) | Should -HaveCount 0
        ($log -contains 'PartitionsForDriveLetter:') | Should -BeFalse

        $records = @(& $provider.GetVolumes @{ Operation = 'GetVolumes' })
        $records | Should -HaveCount 1
        $records[0].MembersIncomplete | Should -BeTrue

        Import-RecoveryAutomationModules
        $identity = DiskDetection\Resolve-RecoveryPathIdentity -Path $destinationPath -Provider $provider
        $identity.Resolved | Should -BeTrue
        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }

    It 'never claims complete membership when the disk view omits the dynamic statement' {
        $provider = New-TopologyProvider `
            -Disks @((New-TopologyDisk -Number 7 -DropDynamicStatement $true))

        $records = @(& $provider.GetDisks @{ Operation = 'GetDisks'; DiskNumber = 7 })
        $records | Should -HaveCount 1
        $records[0].MembersIncomplete | Should -BeTrue
        $records[0].IsDynamic | Should -BeNullOrEmpty

        Import-RecoveryAutomationModules
        $identity = DiskDetection\Get-PhysicalDiskIdentity -DiskNumber 7 -Provider $provider
        $identity.IsIndeterminate | Should -BeTrue
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }
}

Describe 'Default front door and case cleanup (runtime regression)' {

    BeforeAll {
        $script:FrontDoorRunnable = $true
        if ($env:OS -eq 'Windows_NT') {
            $frontDoorIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $frontDoorPrincipal = New-Object System.Security.Principal.WindowsPrincipal($frontDoorIdentity)
            $script:FrontDoorRunnable = [bool]$frontDoorPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        function New-FrontDoorFixture {
            param([string]$Name)
            $sourcePath = Join-Path -Path $TestDrive -ChildPath ('frontdoor-source-' + $Name)
            $destinationPath = Join-Path -Path $TestDrive -ChildPath ('frontdoor-destination-' + $Name)
            New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
            $filePath = Join-Path -Path $TestDrive -ChildPath ('frontdoor-file-scavenger-' + $Name + '.bin')
            $rStudioPath = Join-Path -Path $TestDrive -ChildPath ('frontdoor-r-studio-' + $Name + '.bin')
            Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
            Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII

            $disks = @(
                [pscustomobject]@{ DiskNumber = 4; UniqueId = 'FRONTDOOR-SOURCE-DISK'; UniqueIdFormat = 'WWN'; SerialNumber = 'FRONTDOOR-SOURCE-SERIAL'; Model = 'Source'; SizeBytes = 1000000 }
                [pscustomobject]@{ DiskNumber = 5; UniqueId = 'FRONTDOOR-DESTINATION-DISK'; UniqueIdFormat = 'WWN'; SerialNumber = 'FRONTDOOR-DESTINATION-SERIAL'; Model = 'Destination'; SizeBytes = 2000000 }
            )
            $diskProvider = @{
                Name = 'FrontDoorFixture'
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
                        VolumeGuid = if ($isSource) { 'FRONTDOOR-SOURCE-VOLUME' } else { 'FRONTDOOR-DESTINATION-VOLUME' }
                        VolumePath = if ($isSource) { 'FRONTDOOR-SOURCE-VOLUME-PATH' } else { 'FRONTDOOR-DESTINATION-VOLUME-PATH' }
                        DriveLetter = $null
                    }
                }.GetNewClosure()
                GetFreeSpace = {
                    param($request)
                    return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
                }.GetNewClosure()
            }
            $candidateProvider = {
                param($product, $explicitPath)
                if ($product -eq 'FileScavenger') {
                    return [pscustomobject]@{
                        Path = $explicitPath
                        Exists = $true
                        Readable = $true
                        FileVersion = '7.1.1.13'
                        ProductVersion = '7.1.1.13'
                        ProductName = 'File Scavenger'
                        OriginalFilename = 'frontdoor-file-scavenger.bin'
                        EvidenceSource = 'IntegrationFixture'
                    }
                }
                return [pscustomobject]@{
                    Path = $explicitPath
                    Exists = $true
                    Readable = $true
                    FileVersion = '9.5.191810'
                    ProductVersion = '9.5.191810'
                    ProductName = 'R-Studio'
                    OriginalFilename = 'frontdoor-r-studio.bin'
                    CompanyName = 'R-Tools Technology Inc.'
                    OwnerValidated = $true
                    OwnerEvidence = 'IntegrationFixture'
                    EvidenceSource = 'FileVersionInfo: IntegrationFixture'
                }
            }.GetNewClosure()
            $fileRunner = {
                param($path)
                return [pscustomobject]@{ Path = $path; Pid = 4871; StartTime = '2026-01-01T00:00:00Z' }
            }.GetNewClosure()

            return [pscustomobject]@{
                SourcePath        = $sourcePath
                DestinationPath   = $destinationPath
                FilePath          = $filePath
                RStudioPath       = $rStudioPath
                DiskProvider      = $diskProvider
                CandidateProvider = $candidateProvider
                FileRunner        = $fileRunner
            }
        }
    }

    It 'selects the destination from the typed provider when no graphical picker is wired' {
        $fixture = New-FrontDoorFixture -Name 'typed'
        $typedCalls = New-Object System.Collections.Generic.List[string]
        $typedProvider = {
            param($request)
            $typedCalls.Add('ReadPath') | Out-Null
            return $fixture.DestinationPath
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $fixture.SourcePath `
            -ConfigurationOverrides @{ FileScavengerPath = $fixture.FilePath; RStudioPath = $fixture.RStudioPath; ClientName = 'Typed Client' } `
            -SourceProtectionProvider { return $true } -DiskProvider $fixture.DiskProvider `
            -FileScavengerDiscoveryProvider $fixture.CandidateProvider -RStudioDiscoveryProvider $fixture.CandidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $fixture.FileRunner `
            -TypedDestinationProvider $typedProvider

        $result.ReasonCode | Should -Not -Be 'DestinationNotSelected'
        $result.ReasonCode | Should -Be 'ManualGatePending'
        $typedCalls.Count | Should -Be 1
        $result.JobFolderPath | Should -Not -BeNullOrEmpty
        ([string]$result.JobFolderPath).StartsWith([string]$fixture.DestinationPath) | Should -BeTrue
    }

    It 'releases the case event log handle when the workflow returns' {
        $fixture = New-FrontDoorFixture -Name 'logclose'

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause `
            -SourcePath $fixture.SourcePath -DestinationPath $fixture.DestinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $fixture.FilePath; RStudioPath = $fixture.RStudioPath; ClientName = 'Log Close Client' } `
            -SourceProtectionProvider { return $true } -DiskProvider $fixture.DiskProvider `
            -FileScavengerDiscoveryProvider $fixture.CandidateProvider -RStudioDiscoveryProvider $fixture.CandidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'IntegrationFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $fixture.FileRunner

        $result.ReasonCode | Should -Be 'ManualGatePending'
        (Test-Path -LiteralPath $result.LogPath -PathType Leaf) | Should -BeTrue

        # The case log is opened with FileShare.Read. An exclusive open only
        # succeeds once the workflow released the writer handle, which is the
        # exact condition Pester TestDrive cleanup needs on Windows.
        $exclusive = $null
        $opened = $false
        try {
            $exclusive = [System.IO.File]::Open([string]$result.LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $opened = $true
        }
        finally {
            if ($null -ne $exclusive) { $exclusive.Dispose() }
        }
        $opened | Should -BeTrue
    }

    It 'forwards technician inputs and records interactive wiring through the real entry point' {
        if (-not $script:FrontDoorRunnable) {
            Set-ItResult -Skipped -Because 'the front door relaunches through UAC on a non-elevated Windows host'
            return
        }

        $result = & $script:EntryPoint -ConfigPath $script:ConfigPath -NoPause -DryRun `
            -ClientName 'CLI forwarding probe' -DestinationPath 'D:\Recovery'

        $result.Success | Should -BeTrue
        $result.Mode | Should -Be 'DryRun'
        $result.Configuration.ClientName | Should -Be 'CLI forwarding probe'
        $result.Configuration.DestinationRoot | Should -Be 'D:\Recovery'
        $selectorEntry = @($result.FrontDoorWiring) | Where-Object { $_.Name -eq 'SourceSelector' }
        $null -ne $selectorEntry | Should -BeTrue
        $selectorEntry.Source | Should -Be 'InteractiveDefault'
    }
}
