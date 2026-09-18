BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
    $script:EntryPoint = Join-Path -Path $script:RepoRoot -ChildPath 'RecoveryAutomation.ps1'
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/RecoveryLogging.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/JobState.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/RStudio.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/FileScavenger.psm1') -Force -Global
    . $script:EntryPoint

    function New-LifecycleState {
        param([string]$StateName = 'READY_FOR_HANDOFF')
        $folder = Join-Path -Path $TestDrive -ChildPath ('handoff-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $paths = [pscustomobject]@{
            JobFolderPath = $folder
            StatePath = Join-Path -Path $folder -ChildPath 'job-state.json'
            LogPath = Join-Path -Path $folder -ChildPath 'events.jsonl'
        }
        $source = [pscustomobject]@{ CanonicalPath = 'C:\Source'; Path = 'C:\Source'; Resolved = $true; IsIndeterminate = $false; IdentityKeys = @('SOURCE') }
        $destination = [pscustomobject]@{ CanonicalPath = $folder; Path = $folder; Resolved = $true; IsIndeterminate = $false; IdentityKeys = @('DESTINATION') }
        $state = New-RecoveryJobState -JobId 'LIFECYCLE-001' -SourceIdentity $source -DestinationIdentity $destination `
            -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0.0' -State $StateName
        $state.Stage = 'HANDOFF'
        $state.AttemptId = 'LIFECYCLE-001-handoff-001'
        # The handoff boundary refuses a state whose documented evidence flags are
        # not all explicitly true; without them the launch never leaves the
        # precondition gate and the unknown-outcome paths would not be reached.
        foreach ($flag in @('FileScavengerCloseVerified', 'OutputVerified', 'SourceIdentityVerified', 'DestinationIdentityVerified', 'LogDurable', 'StateDurable')) {
            $state | Add-Member -NotePropertyName $flag -NotePropertyValue $true -Force
        }
        $state | Add-Member -NotePropertyName Lock -NotePropertyValue ([pscustomobject]@{
            Acquired = $true
            JobId = 'LIFECYCLE-001'
            Owner = 'RecoveryAutomation/LIFECYCLE-001'
            LockPath = Join-Path -Path $folder -ChildPath 'job.lock'
        }) -Force
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        return $state
    }

    function New-LifecycleEventWriter {
        param([System.Collections.ArrayList]$Events)
        return {
            param($event)
            [void]$Events.Add($event)
            return [pscustomobject]@{ Success = $true; Sequence = $Events.Count }
        }.GetNewClosure()
    }

    function New-FileScavengerEntrypointFixture {
        $sourcePath = Join-Path -Path $TestDrive -ChildPath ('source-' + [guid]::NewGuid().ToString('N'))
        $destinationPath = Join-Path -Path $TestDrive -ChildPath ('destination-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $filePath = Join-Path -Path $TestDrive -ChildPath ('file-scavenger-' + [guid]::NewGuid().ToString('N') + '.bin')
        $rStudioPath = Join-Path -Path $TestDrive -ChildPath ('r-studio-' + [guid]::NewGuid().ToString('N') + '.bin')
        Set-Content -LiteralPath $filePath -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath $rStudioPath -Value 'fixture' -Encoding ASCII
        $disks = @(
            [pscustomobject]@{ DiskNumber = 41; UniqueId = 'LIFECYCLE-SOURCE'; UniqueIdFormat = 'WWN'; SerialNumber = 'LIFECYCLE-SOURCE'; Model = 'Source'; SizeBytes = 1000000 }
            [pscustomobject]@{ DiskNumber = 42; UniqueId = 'LIFECYCLE-DEST'; UniqueIdFormat = 'WWN'; SerialNumber = 'LIFECYCLE-DEST'; Model = 'Destination'; SizeBytes = 2000000 }
        )
        $diskProvider = @{
            Name = 'LifecycleFixture'
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
                    DiskNumber = if ($isSource) { 41 } else { 42 }
                    PartitionNumber = 1
                    VolumeGuid = if ($isSource) { 'LIFECYCLE-SOURCE-VOLUME' } else { 'LIFECYCLE-DEST-VOLUME' }
                    VolumePath = if ($isSource) { 'LIFECYCLE-SOURCE-PATH' } else { 'LIFECYCLE-DEST-PATH' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = { param($request) return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 } }
        }
        $candidateProvider = {
            param($product, $explicitPath)
            if ($product -eq 'FileScavenger') {
                return [pscustomobject]@{
                    Path = $explicitPath; Exists = $true; Readable = $true
                    FileVersion = '7.1.1.13'; ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'; OriginalFilename = 'file-scavenger.bin'
                    EvidenceSource = 'LifecycleFixture'
                }
            }
            return [pscustomobject]@{
                Path = $explicitPath; Exists = $true; Readable = $true
                FileVersion = '9.5.191810'; ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'; OriginalFilename = 'r-studio.bin'
                CompanyName = 'R-Tools Technology Inc.'; OwnerValidated = $true
                OwnerEvidence = 'LifecycleFixture'; EvidenceSource = 'FileVersionInfo: LifecycleFixture'
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            ConfigPath = Join-Path -Path $TestDrive -ChildPath 'lifecycle-config.json'
            SourcePath = $sourcePath; DestinationPath = $destinationPath
            FilePath = $filePath; RStudioPath = $rStudioPath
            DiskProvider = $diskProvider; CandidateProvider = $candidateProvider
        }
    }

    function New-LifecycleClock {
        $box = @{ Value = [datetime]::Parse('2026-09-16T07:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
        return { param($request) return [datetime]$box.Value }.GetNewClosure()
    }

    function New-LifecycleDiskProvider {
        param(
            [string]$SourcePath,
            [string]$DestinationRoot,
            [string]$SourceKey = 'LIFECYCLE-RESUME-SOURCE',
            [string]$DestinationKey = 'LIFECYCLE-RESUME-DEST'
        )
        $disks = @(
            [pscustomobject]@{ DiskNumber = 51; UniqueId = $SourceKey; UniqueIdFormat = 'WWN'; SerialNumber = ('SERIAL-' + $SourceKey); Model = 'ResumeSource'; SizeBytes = 1000000 }
            [pscustomobject]@{ DiskNumber = 52; UniqueId = $DestinationKey; UniqueIdFormat = 'WWN'; SerialNumber = ('SERIAL-' + $DestinationKey); Model = 'ResumeDestination'; SizeBytes = 2000000 }
        )
        return @{
            Name = 'LifecycleResumeFixture'
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
                $isSource = $path.Equals([string]$SourcePath, [System.StringComparison]::OrdinalIgnoreCase)
                return [pscustomobject]@{
                    CanonicalPath = $path
                    Exists = $true
                    IsContainer = $true
                    ReparseResolved = $true
                    IsReparsePoint = $false
                    MembersIncomplete = $false
                    DiskNumber = if ($isSource) { 51 } else { 52 }
                    PartitionNumber = 1
                    VolumeGuid = if ($isSource) { 'LIFECYCLE-RESUME-SOURCE-VOLUME' } else { 'LIFECYCLE-RESUME-DEST-VOLUME' }
                    VolumePath = if ($isSource) { 'LIFECYCLE-RESUME-SOURCE-PATH' } else { 'LIFECYCLE-RESUME-DEST-PATH' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = { param($request) return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 } }.GetNewClosure()
        }
    }

    function New-LifecycleResumeCase {
        # A case folder exactly as the workflow writes it: somewhere under the
        # proven destination root, with a claim marker, a log whose sequence the
        # state records, and the requested durable state.
        param(
            [Parameter(Mandatory = $true)][string]$DestinationRoot,
            [Parameter(Mandatory = $true)][string]$SourcePath,
            [string]$StateName = 'SHORT_RECOVERY_VERIFIED'
        )
        $folder = Join-Path -Path $DestinationRoot -ChildPath ('Client_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        [void][System.IO.Directory]::CreateDirectory($folder)
        $leaf = [System.IO.Path]::GetFileName($folder)
        $claim = @{
            ClaimId = 'CLAIM-LIFECYCLE-001'; ClientName = 'LifecycleClient'; FolderName = $leaf
            CreatedUtc = '2026-09-16T07:00:00Z'; CollisionIndex = 0
        } | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
        $paths = [pscustomobject]@{
            JobFolderPath = $folder
            StatePath = Join-Path -Path $folder -ChildPath 'job-state.json'
            LogPath = Join-Path -Path $folder -ChildPath 'events.jsonl'
        }
        $clock = New-LifecycleClock
        $log = New-RecoveryLog -Path $paths.LogPath -JobId $leaf -Clock $clock
        $eventWriter = { param($event) return (Write-RecoveryLogEntry -Writer $log.Writer -Entry $event).Success }.GetNewClosure()
        $sourceIdentity = [pscustomobject]@{
            Path = $SourcePath; CanonicalPath = $SourcePath; Resolved = $true; Exists = $true; IsContainer = $true
            VolumeGuid = 'LIFECYCLE-RESUME-SOURCE-VOLUME'; VolumePath = 'LIFECYCLE-RESUME-SOURCE-PATH'; DriveLetter = $null
            IdentityKeys = @('UID|WWN|LIFECYCLE-RESUME-SOURCE')
            PhysicalDisks = @([pscustomobject]@{ IdentityKey = 'UID|WWN|LIFECYCLE-RESUME-SOURCE'; UniqueId = 'LIFECYCLE-RESUME-SOURCE'; UniqueIdFormat = 'WWN'; SizeBytes = 1000000; Model = 'ResumeSource' })
            IsIndeterminate = $false; ReasonCode = $null
        }
        $destinationIdentity = [pscustomobject]@{
            Path = $folder; CanonicalPath = $folder; Resolved = $true; Exists = $true; IsContainer = $true
            VolumeGuid = 'LIFECYCLE-RESUME-DEST-VOLUME'; VolumePath = 'LIFECYCLE-RESUME-DEST-PATH'; DriveLetter = $null
            IdentityKeys = @('UID|WWN|LIFECYCLE-RESUME-DEST')
            PhysicalDisks = @([pscustomobject]@{ IdentityKey = 'UID|WWN|LIFECYCLE-RESUME-DEST'; UniqueId = 'LIFECYCLE-RESUME-DEST'; UniqueIdFormat = 'WWN'; SizeBytes = 2000000; Model = 'ResumeDestination' })
            IsIndeterminate = $false; ReasonCode = $null
        }
        $state = New-RecoveryJobState -JobId $leaf -SourceIdentity $sourceIdentity -DestinationIdentity $destinationIdentity `
            -ApplicationEvidence ([pscustomobject]@{ FileScavenger = $null; RStudio = $null }) -Paths $paths `
            -WorkflowVersion '1.0.0' -State 'PREFLIGHT_PENDING' -Clock $clock
        $steps = @(
            @{ To = 'PREFLIGHT_PASSED'; Evidence = 'PreflightPassed' }
            @{ To = 'CASE_READY'; Evidence = 'CaseCreated' }
            @{ To = 'SHORT_SCAN_RUNNING'; Evidence = 'LaunchGateRecorded'; Stage = 'SHORT_SCAN'; Suffix = 'short-scan' }
            @{ To = 'SHORT_SCAN_FINISHED'; Evidence = 'ScanFinished' }
            @{ To = 'SHORT_RECOVERY_RUNNING'; Evidence = 'RecoveryDestinationChecked'; Stage = 'SHORT_RECOVERY'; Suffix = 'short-recovery' }
            @{ To = 'SHORT_RECOVERY_FINISHED'; Evidence = 'RecoveryFinished' }
            @{ To = 'SHORT_RECOVERY_VERIFIED'; Evidence = 'OutputObserved' }
            @{ To = 'READY_FOR_HANDOFF'; Evidence = 'FileScavengerWorkVerified'; Stage = 'CLOSE' }
        )
        foreach ($step in $steps) {
            if ([string]$state.State -eq $StateName) { break }
            $context = @{ Evidence = $step.Evidence }
            if ($step.ContainsKey('Stage')) { $context['Stage'] = $step.Stage }
            if ($step.ContainsKey('Suffix')) { $context['AttemptId'] = ($leaf + '-' + $step.Suffix + '-001') }
            $transition = Set-RecoveryState -State $state -To $step.To -EventWriter $eventWriter -StateWriter $null -Context $context -Clock $clock
            if (-not $transition.Success) {
                throw ('Resume fixture could not reach ' + $step.To + ': ' + [string]$transition.ReasonCode + ' ' + [string]$transition.Message)
            }
        }
        if ([string]$state.State -ne $StateName) {
            throw ('Resume fixture could not reach ' + $StateName + '; it is at ' + [string]$state.State)
        }
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        return [pscustomobject]@{ Folder = $folder; Leaf = $leaf; Paths = $paths; State = $state }
    }

    function Invoke-LifecycleResume {
        param(
            [Parameter(Mandatory = $true)][object]$Case,
            [Parameter(Mandatory = $true)][object]$DiskProvider,
            [Parameter(Mandatory = $true)][string]$ConfigPath,
            [scriptblock]$InteractionProvider = $null
        )
        $parameters = @{
            ConfigPath = $ConfigPath
            NoPause = $true
            ResumeJobPath = $Case.Folder
            DiskProvider = $DiskProvider
            RuntimeProvider = { return @{ Compatible = $true; Evidence = 'LifecycleFixture' } }
            ElevationProvider = { return $true }
            Clock = (New-LifecycleClock)
        }
        if ($null -ne $InteractionProvider) { $parameters['InteractionProvider'] = $InteractionProvider }
        else { $parameters['InteractionProvider'] = { param($request) return 'Stop' } }
        # Every vendor seam refuses: a resume must not launch, drive, or close a
        # vendor process, and a test that let one through would hide a regression.
        $parameters['VendorProcessRunner'] = { param($request) throw 'a resume must not launch or drive a vendor process' }
        $parameters['FileScavengerProcessRunner'] = { param($request) throw 'a resume must not launch or drive a vendor process' }
        return Invoke-RecoveryAutomation @parameters
    }

    function Get-LifecycleStateOnDisk {
        param([Parameter(Mandatory = $true)][string]$StatePath)
        return ([System.IO.File]::ReadAllText($StatePath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
    }

    # The durable-unknown tests need the INTERRUPTED_UNKNOWN edge the parent lane
    # must add to modules/JobState.psm1 (Get-RecoveryTransitionTable rebuilds the
    # table per call, so a test cannot inject it). Until that lands, the edge is
    # supplied by a shim installed INSIDE the JobState module scope: JobState's own
    # Set-RecoveryState calls Test-RecoveryStateTransition unqualified from module
    # scope, so only a module-scope override reaches it. The shim answers only for
    # the requested unknown edges and forwards every other question to the real
    # function, which it captured first.
    $script:LifecycleAllowUnknownEdges = $false
    $script:LifecycleRealTransitionFunction = $null


    function Disable-LifecycleUnknownStateEdges {
        $module = Get-Module 'JobState'
        . $module {
            if ($null -ne $script:LifecycleRealTransitionFunction) {
                Set-Item -Path 'Function:Test-RecoveryStateTransition' -Value $script:LifecycleRealTransitionFunction
                $script:LifecycleRealTransitionFunction = $null
            }
        }
    }
}

Describe 'RecoveryAutomation lifecycle outcome wiring' {
    AfterEach {
        # The unknown-edge shim is opt-in per test: every other test keeps proving
        # behaviour under the transition table the repository actually ships.
        Disable-LifecycleUnknownStateEdges
    }
    It 'never reports an uncertain File Scavenger launch as a clean failure' {
        $fixture = New-FileScavengerEntrypointFixture
        Set-Content -LiteralPath $fixture.ConfigPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $runs = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$runs.Add($path)
            return [pscustomobject]@{ Success = $false; Path = $path; Pid = 7711; StartTime = '2026-01-01T00:00:00Z'; Alive = $true }
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $fixture.ConfigPath -NoPause `
            -SourcePath $fixture.SourcePath -DestinationPath $fixture.DestinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $fixture.FilePath; RStudioPath = $fixture.RStudioPath; ClientName = 'Lifecycle' } `
            -SourceProtectionProvider { return $true } -DiskProvider $fixture.DiskProvider `
            -FileScavengerDiscoveryProvider $fixture.CandidateProvider -RStudioDiscoveryProvider $fixture.CandidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'LifecycleFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $runner

        $result.Success | Should -BeFalse
        # The launch outcome is carried as an unknown, never as a launch and never
        # as a clean 'LaunchOutcomeUnknown'/'ProcessResultUnverified' failure the
        # technician could retry: the attempt is described by the contract below.
        $result.StateObject.LaunchOutcomeContract.Result | Should -Be 'InterruptedUnknown'
        $result.StateObject.LaunchOutcomeContract.Confidence | Should -Be 'Unknown'
        $result.StateObject.LaunchOutcomeContract.IdentityConfidence | Should -Be 'Candidate'
        $result.StateObject.LaunchOutcomeContract.RetryAllowed | Should -BeFalse
        $result.StateObject.LaunchOutcomeContract.CloseAllowed | Should -BeFalse
        $result.StateObject.LaunchOutcomeContract.VendorActionAllowed | Should -BeFalse
        $result.StateObject.LaunchOutcomeContract.RequestedState | Should -Be 'INTERRUPTED_UNKNOWN'
        $result.StateObject.LaunchOutcomeContract.EventType | Should -Be 'StageInterruptedUnknown'
        # The candidate identity is retained for review rather than discarded.
        $result.StateObject.ProcessIdentity.Pid | Should -Be 7711
        $result.StateObject.ProcessIdentity.IdentityStatus | Should -Be 'Candidate'
        $result.VendorLaunchAttempted | Should -BeTrue
        $runs | Should -HaveCount 1
        # No clean failure event was recorded, and the run did not walk on into a
        # scan stage or the workflow.
        $result.Mode | Should -Be 'FileScavenger'
        $result.CurrentState | Should -Not -Be 'SHORT_SCAN_RUNNING'
        $logText = Get-Content -LiteralPath $result.LogPath -Raw
        $logText | Should -Match 'StageInterruptedUnknown'
        $logText | Should -Not -Match 'StageFailed'
        $logText | Should -Not -Match 'SHORT_SCAN_RUNNING'
    }

    It 'records the canonical unknown launch state durably when the state module allows it' {
        $fixture = New-FileScavengerEntrypointFixture
        Set-Content -LiteralPath $fixture.ConfigPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $runs = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$runs.Add($path)
            return [pscustomobject]@{ Success = $false; Path = $path; Pid = 7711; StartTime = '2026-01-01T00:00:00Z'; Alive = $true }
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $fixture.ConfigPath -NoPause `
            -SourcePath $fixture.SourcePath -DestinationPath $fixture.DestinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $fixture.FilePath; RStudioPath = $fixture.RStudioPath; ClientName = 'Lifecycle' } `
            -SourceProtectionProvider { return $true } -DiskProvider $fixture.DiskProvider `
            -FileScavengerDiscoveryProvider $fixture.CandidateProvider -RStudioDiscoveryProvider $fixture.CandidateProvider `
            -ValidatedFileScavengerBuilds @('7.1.1.13') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'LifecycleFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner $runner

        $result.Success | Should -BeFalse
        # The runner stated a failure, so the adapter names it RunnerReportedFailure;
        # the run still records an unknown launch because the runner was invoked and
        # a process may exist, which is the property under test here.
        $result.ReasonCode | Should -Be 'RunnerReportedFailure'
        $result.CurrentState | Should -Be 'INTERRUPTED_UNKNOWN'
        $result.StateObject.InterruptedUnknownDurable | Should -BeTrue
        $result.StateObject.ProcessIdentity.Pid | Should -Be 7711
        # The durable record, not just the in-memory one, holds the unknown state.
        (Get-LifecycleStateOnDisk -StatePath $result.StatePath).State | Should -Be 'INTERRUPTED_UNKNOWN'
        $runs | Should -HaveCount 1
        $logText = Get-Content -LiteralPath $result.LogPath -Raw
        $logText | Should -Match 'StageInterruptedUnknown'
        $logText | Should -Not -Match 'StageFailed'
    }

    It 'keeps a pre-launch File Scavenger refusal distinct from an unknown launch' {
        $fixture = New-FileScavengerEntrypointFixture
        Set-Content -LiteralPath $fixture.ConfigPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $runs = New-Object System.Collections.ArrayList
        # The run declares a validated File Scavenger build that the staged
        # executable does not match, so the vendor boundary refuses before the
        # process runner is ever reached. This is the pre-launch refusal case.
        $result = Invoke-RecoveryAutomation -ConfigPath $fixture.ConfigPath -NoPause `
            -SourcePath $fixture.SourcePath -DestinationPath $fixture.DestinationPath `
            -ConfigurationOverrides @{ FileScavengerPath = $fixture.FilePath; RStudioPath = $fixture.RStudioPath; ClientName = 'Lifecycle' } `
            -SourceProtectionProvider { return $true } -DiskProvider $fixture.DiskProvider `
            -FileScavengerDiscoveryProvider $fixture.CandidateProvider -RStudioDiscoveryProvider $fixture.CandidateProvider `
            -ValidatedFileScavengerBuilds @('9.9.9.9') -ValidatedRStudioBuilds @('9.5.191810') `
            -RuntimeProvider { return @{ Compatible = $true; Evidence = 'LifecycleFixture' } } `
            -ElevationProvider { return $true } -FileScavengerProcessRunner ({ param($path) [void]$runs.Add($path); return [pscustomobject]@{ Success = $true; Path = $path; Pid = 7712; StartTime = '2026-01-01T00:00:00Z'; Alive = $true } })

        $result.Success | Should -BeFalse
        # A refusal that never reached the process runner is not a vendor launch
        # attempt and never becomes an interrupted-unknown state.
        $result.CurrentState | Should -BeNullOrEmpty
        $result.VendorLaunchAttempted | Should -BeFalse
        $result.ReasonCode | Should -Not -Be 'InterruptedUnknownStateNotDurable'
        $result.ReasonCode | Should -Not -Be 'ProcessResultUnverified'
        $runs | Should -HaveCount 0
    }

    It 'never reports an uncertain R-Studio handoff as a failed launch' {
        $state = New-LifecycleState
        $events = New-Object System.Collections.ArrayList
        $writer = New-LifecycleEventWriter -Events $events
        $executable = [pscustomobject]@{
            Path = 'D:\Fixture\RStudio\application.exe'; Product = 'RStudio'; ProductName = 'R-Studio'
            OriginalFilename = 'RStudio.exe'; FileVersion = '9.5.191810'; ProductVersion = '9.5'
            CompanyName = 'R-Tools Technology, Inc.'; Publisher = 'R-Tools Technology, Inc.'
            Exists = $true; Readable = $true; FileVersionInfoVerified = $true
            EvidenceSource = 'FileVersionInfo'; IdentityStatus = 'Verified'
        }
        $runnerCalls = New-Object System.Collections.ArrayList
        $runner = {
            param($request)
            [void]$runnerCalls.Add($request)
            return [pscustomobject]@{ ProcessId = 7722; Path = $request.ExecutablePath; StartTimeUtc = '2026-01-01T00:00:00Z'; HasExited = $false }
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomationHandoff -State $state -Executable $executable `
            -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        # R-Studio may be running, so this is never a plain 'ProcessResultUnverified'
        # failure: the outcome is an unknown handoff review with the candidate
        # identity retained, no retry, and no forced close.
        $result.Preconditions.ReasonCode | Should -BeNullOrEmpty
        $result.Launched | Should -BeFalse
        $result.State.LaunchOutcome.Result | Should -Be 'HandoffReview'
        $result.State.LaunchOutcome.IdentityConfidence | Should -Be 'Candidate'
        $result.State.LaunchOutcome.Confidence | Should -Be 'Unknown'
        $result.State.ProcessIdentity.ProcessId | Should -Be 7722
        $runnerCalls | Should -HaveCount 1
        # The attempt is durably INTERRUPTED_UNKNOWN rather than left at the
        # pre-launch state: the state module now allows that edge when the caller
        # states the launch uncertainty.
        $result.State.State | Should -Be 'INTERRUPTED_UNKNOWN'
        $result.State.InterruptedUnknownDurable | Should -BeTrue
        @($events | Where-Object { $_.EventType -eq 'StageFailed' }) | Should -HaveCount 0
        # The launch-only authorization event is written before the runner is
        # invoked (that ordering is the contract); no event may claim the handoff
        # landed in HANDOFF_MANUAL.
        @($events | Where-Object { $_.EventType -eq 'RStudioLaunchOnlyHandoff' }) | Should -HaveCount 1
        @($events | Where-Object { $_.State -eq 'HANDOFF_MANUAL' }) | Should -HaveCount 0
        (Get-LifecycleStateOnDisk -StatePath $state.Paths.StatePath).State | Should -Be 'INTERRUPTED_UNKNOWN'
    }

    It 'records the unknown handoff state durably when the state module allows it' {
        $state = New-LifecycleState
        $events = New-Object System.Collections.ArrayList
        $writer = New-LifecycleEventWriter -Events $events
        $executable = [pscustomobject]@{
            Path = 'D:\Fixture\RStudio\application.exe'; Product = 'RStudio'; ProductName = 'R-Studio'
            OriginalFilename = 'RStudio.exe'; FileVersion = '9.5.191810'; ProductVersion = '9.5'
            CompanyName = 'R-Tools Technology, Inc.'; Publisher = 'R-Tools Technology, Inc.'
            Exists = $true; Readable = $true; FileVersionInfoVerified = $true
            EvidenceSource = 'FileVersionInfo'; IdentityStatus = 'Verified'
        }
        $runner = {
            param($request)
            return [pscustomobject]@{ ProcessId = 7722; Path = $request.ExecutablePath; StartTimeUtc = '2026-01-01T00:00:00Z'; HasExited = $false }
        }

        $result = Invoke-RecoveryAutomationHandoff -State $state -Executable $executable `
            -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.ReasonCode | Should -Be 'ProcessResultUnverified'
        $result.State.State | Should -Be 'INTERRUPTED_UNKNOWN'
        $result.State.InterruptedUnknownDurable | Should -BeTrue
        (Get-LifecycleStateOnDisk -StatePath $state.Paths.StatePath).State | Should -Be 'INTERRUPTED_UNKNOWN'
        @($events | Where-Object { $_.EventType -eq 'StageInterruptedUnknown' }) | Should -HaveCount 1
        @($events | Where-Object { $_.EventType -eq 'StageFailed' }) | Should -HaveCount 0
    }

    It 'does not claim a durable handoff transition after a state persistence failure' {
        $state = New-LifecycleState
        $events = New-Object System.Collections.ArrayList
        $writer = New-LifecycleEventWriter -Events $events
        $stateWriter = @{ Write = { param($request) return [pscustomobject]@{ Success = $false; ReasonCode = 'FixtureStateWriteRefused'; Message = 'fixture refusal' } } }
        $executable = [pscustomobject]@{
            Path = 'D:\Fixture\RStudio\application.exe'; Product = 'RStudio'; ProductName = 'R-Studio'
            OriginalFilename = 'RStudio.exe'; FileVersion = '9.5.191810'; ProductVersion = '9.5'
            CompanyName = 'R-Tools Technology, Inc.'; Publisher = 'R-Tools Technology, Inc.'
            Exists = $true; Readable = $true; FileVersionInfoVerified = $true
            EvidenceSource = 'FileVersionInfo'; IdentityStatus = 'Verified'
        }
        $runner = { param($request) return [pscustomobject]@{ Success = $true; ProcessId = 7733; Path = $request.ExecutablePath; StartTimeUtc = '2026-01-01T00:00:00Z'; HasExited = $false } }

        $result = Invoke-RecoveryAutomationHandoff -State $state -Executable $executable `
            -ProcessRunner $runner -EventWriter $writer -StateWriter $stateWriter

        $result.Allowed | Should -BeFalse
        # The started vendor process is never reported as a clean failure, and the
        # handoff never claims the HANDOFF_MANUAL transition landed: the run stops
        # on the failed durability attempt with the unknown record on disk.
        $result.Launched | Should -BeFalse
        $result.State.HandoffTransitionVerification.Succeeded | Should -BeFalse
        $result.State.ProcessIdentity.ProcessId | Should -Be 7733
        # This writer refuses every write, so even the unknown record cannot be made
        # durable: the run must say so and must not claim a durable transition.
        $result.State.InterruptedUnknownDurable | Should -BeFalse
        # The refusal is named, the case keeps its previous state, and no event
        # claims the handoff landed in HANDOFF_MANUAL.
        $result.ReasonCode | Should -Be 'HandoffInterruptedUnknownNotDurable'
        (Get-LifecycleStateOnDisk -StatePath $state.Paths.StatePath).State | Should -Be 'READY_FOR_HANDOFF'
        # The unknown attempt is still recorded as an event; only the durable state
        # transition could not land, and no event claims HANDOFF_MANUAL was reached.
        @($events | Where-Object { $_.EventType -eq 'StageInterruptedUnknown' }) | Should -HaveCount 1
        @($events | Where-Object { $_.State -eq 'HANDOFF_MANUAL' -and $_.EventType -ne 'RStudioLaunchOnlyHandoff' }) | Should -HaveCount 0
    }

    It 'records a durable unknown handoff when only the handoff snapshot fails' {
        $state = New-LifecycleState
        $events = New-Object System.Collections.ArrayList
        $writer = New-LifecycleEventWriter -Events $events
        # Only the HANDOFF_MANUAL snapshot is refused; the unknown record can still
        # be written, which is the case a started vendor process must land in.
        $stateWriter = @{ Write = {
                param($request)
                if ([string]$request.State.State -eq 'HANDOFF_MANUAL') {
                    return [pscustomobject]@{ Success = $false; ReasonCode = 'FixtureStateWriteRefused'; Message = 'fixture refusal' }
                }
                [System.IO.File]::WriteAllText([string]$request.Path, ([string]$request.Text), (New-Object System.Text.UTF8Encoding($false)))
                return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
            } }
        $executable = [pscustomobject]@{
            Path = 'D:\Fixture\RStudio\application.exe'; Product = 'RStudio'; ProductName = 'R-Studio'
            OriginalFilename = 'RStudio.exe'; FileVersion = '9.5.191810'; ProductVersion = '9.5'
            CompanyName = 'R-Tools Technology, Inc.'; Publisher = 'R-Tools Technology, Inc.'
            Exists = $true; Readable = $true; FileVersionInfoVerified = $true
            EvidenceSource = 'FileVersionInfo'; IdentityStatus = 'Verified'
        }
        $runner = { param($request) return [pscustomobject]@{ Success = $true; ProcessId = 7744; Path = $request.ExecutablePath; StartTimeUtc = '2026-01-01T00:00:00Z'; HasExited = $false } }

        $result = Invoke-RecoveryAutomationHandoff -State $state -Executable $executable `
            -ProcessRunner $runner -EventWriter $writer -StateWriter $stateWriter

        $result.Allowed | Should -BeFalse
        $result.Launched | Should -BeFalse
        $result.State.ProcessIdentity.ProcessId | Should -Be 7744
        $result.State.InterruptedUnknownDurable | Should -BeTrue
        (Get-LifecycleStateOnDisk -StatePath $state.Paths.StatePath).State | Should -Be 'INTERRUPTED_UNKNOWN'
        @($events | Where-Object { $_.EventType -eq 'StageInterruptedUnknown' }) | Should -HaveCount 1
        # The refused HANDOFF_MANUAL snapshot is never reported as a landed handoff.
        $result.State.HandoffTransitionVerification.Succeeded | Should -BeFalse
    }

    It 'resumes a verified short recovery without approving or claiming a long scan' {
        $root = Join-Path -Path $TestDrive -ChildPath 'resume-root-a'
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'resume-source-a'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        $configPath = Join-Path -Path $TestDrive -ChildPath 'resume-config-a.json'
        Set-Content -LiteralPath $configPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $provider = New-LifecycleDiskProvider -SourcePath $sourcePath -DestinationRoot $root
        $case = New-LifecycleResumeCase -DestinationRoot $root -SourcePath $sourcePath -StateName 'SHORT_RECOVERY_VERIFIED'

        $result = Invoke-LifecycleResume -Case $case -DiskProvider $provider -ConfigPath $configPath

        $result.Success | Should -BeFalse
        $result.Mode | Should -Be 'Resume'
        $result.ReasonCode | Should -Be 'ResumeNextStageNotAuthorized'
        $result.ExitCode | Should -Be 8
        # The verified stage the resume read is preserved: the case does not claim
        # to be scanning, and no attempt id is invented for a scan nobody started.
        $result.CurrentState | Should -Be 'SHORT_RECOVERY_VERIFIED'
        $stateOnDisk = Get-LifecycleStateOnDisk -StatePath $case.Paths.StatePath
        $stateOnDisk.State | Should -Be 'SHORT_RECOVERY_VERIFIED'
        $stateOnDisk.AttemptId | Should -Be ($case.Leaf + '-short-recovery-001')
        $logText = [System.IO.File]::ReadAllText($case.Paths.LogPath, (New-Object System.Text.UTF8Encoding($false)))
        $logText | Should -Not -Match 'LONG_SCAN_RUNNING'
        $logText | Should -Not -Match ($case.Leaf + '-long-scan-001')
        $logText | Should -Not -Match 'LongScanApproved'
        @([regex]::Matches($logText, 'RecoveryFinished')).Count | Should -Be 1
    }

    It 'leaves an open attempt durably INTERRUPTED_UNKNOWN before the attempt prompt' {
        $root = Join-Path -Path $TestDrive -ChildPath 'resume-root-b'
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'resume-source-b'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        $configPath = Join-Path -Path $TestDrive -ChildPath 'resume-config-b.json'
        Set-Content -LiteralPath $configPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $provider = New-LifecycleDiskProvider -SourcePath $sourcePath -DestinationRoot $root
        $case = New-LifecycleResumeCase -DestinationRoot $root -SourcePath $sourcePath -StateName 'SHORT_SCAN_RUNNING'
        $prompts = New-Object System.Collections.ArrayList
        $stateAtPrompt = New-Object System.Collections.ArrayList
        $statePath = $case.Paths.StatePath
        $interaction = {
            param($request)
            [void]$prompts.Add([string]$request.GateId)
            $snapshot = ([System.IO.File]::ReadAllText($statePath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
            [void]$stateAtPrompt.Add([string]$snapshot.State)
            return 'Stop'
        }.GetNewClosure()

        $result = Invoke-LifecycleResume -Case $case -DiskProvider $provider -ConfigPath $configPath -InteractionProvider $interaction

        $result.Success | Should -BeFalse
        $result.CurrentState | Should -Be 'INTERRUPTED_UNKNOWN'
        $prompts | Should -HaveCount 1
        $prompts[0] | Should -Be 'G-06'
        # The durable unknown record exists before the technician is asked
        # anything, so an interrupted run can never be mistaken for a scan that
        # is still making progress.
        $stateAtPrompt[0] | Should -Be 'INTERRUPTED_UNKNOWN'
        $stateOnDisk = Get-LifecycleStateOnDisk -StatePath $statePath
        $stateOnDisk.State | Should -Be 'INTERRUPTED_UNKNOWN'
        $stateOnDisk.AttemptId | Should -Be ($case.Leaf + '-short-scan-001')
        $logText = [System.IO.File]::ReadAllText($case.Paths.LogPath, (New-Object System.Text.UTF8Encoding($false)))
        $logText | Should -Match 'StageInterruptedUnknown'
        $logText | Should -Not -Match ($case.Leaf + '-short-scan-002')
    }

    It 'changes nothing when an unknown launch cannot be made durable' {
        $root = Join-Path -Path $TestDrive -ChildPath 'resume-root-c'
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'resume-source-c'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        $configPath = Join-Path -Path $TestDrive -ChildPath 'resume-config-c.json'
        Set-Content -LiteralPath $configPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $provider = New-LifecycleDiskProvider -SourcePath $sourcePath -DestinationRoot $root
        $case = New-LifecycleResumeCase -DestinationRoot $root -SourcePath $sourcePath -StateName 'SHORT_SCAN_RUNNING'
        $stateBefore = [System.IO.File]::ReadAllBytes($case.Paths.StatePath)
        $logBefore = [System.IO.File]::ReadAllBytes($case.Paths.LogPath)
        # A lock that names another job makes the binding read fail, so the
        # unknown transition must not be claimed as durable.
        Lock-RecoveryJob -JobPath $case.Folder -Clock (New-LifecycleClock) -Owner 'OtherTool' -JobId 'OTHER-JOB' | Out-Null

        $result = Invoke-LifecycleResume -Case $case -DiskProvider $provider -ConfigPath $configPath

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Not -Be 'InterruptedUnknownStateNotDurable'
        [System.IO.File]::ReadAllBytes($case.Paths.StatePath) | Should -Be $stateBefore
        [System.IO.File]::ReadAllBytes($case.Paths.LogPath) | Should -Be $logBefore
    }

    It 'still refuses an illegal resume hop instead of routing around it' {
        $root = Join-Path -Path $TestDrive -ChildPath 'resume-root-d'
        $sourcePath = Join-Path -Path $TestDrive -ChildPath 'resume-source-d'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
        $configPath = Join-Path -Path $TestDrive -ChildPath 'resume-config-d.json'
        Set-Content -LiteralPath $configPath -Value '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}' -Encoding ASCII
        $provider = New-LifecycleDiskProvider -SourcePath $sourcePath -DestinationRoot $root
        $case = New-LifecycleResumeCase -DestinationRoot $root -SourcePath $sourcePath -StateName 'CASE_READY'

        $result = Invoke-LifecycleResume -Case $case -DiskProvider $provider -ConfigPath $configPath

        # The only route out of CASE_READY is the documented launch gate, and it
        # stays a gate: an uncontinued decision leaves the case exactly where it
        # was instead of advancing it into a running stage.
        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'ManualGatePending'
        $result.CurrentState | Should -Be 'CASE_READY'
        $stateOnDisk = Get-LifecycleStateOnDisk -StatePath $case.Paths.StatePath
        $stateOnDisk.State | Should -Be 'CASE_READY'
        $stateOnDisk.AttemptId | Should -BeNullOrEmpty
    }

    It 'requires the unknown launch edge to exist and to demand no evidence' {
        # The lifecycle fix needs a durable INTERRUPTED_UNKNOWN edge from every
        # state where a vendor launch is possible (the parent lane owns
        # modules/JobState.psm1). The edge exists and is deliberately guarded: the
        # caller must state, as a literal Boolean, that a launch attempt happened
        # and its outcome is uncertain. An unguarded edge could be used as a generic
        # bypass into INTERRUPTED_UNKNOWN, and no evidence is invented by the
        # caller because the uncertainty is the fact being recorded.
        foreach ($from in @('SHORT_SCAN_RUNNING', 'CASE_READY', 'READY_FOR_HANDOFF')) {
            $withoutContext = Test-RecoveryStateTransition -From $from -To 'INTERRUPTED_UNKNOWN'
            if ($from -eq 'SHORT_SCAN_RUNNING') {
                # A running attempt already carries the uncertainty: its edge stays
                # open, exactly as it was before this round.
                $withoutContext.Allowed | Should -BeTrue
                $withoutContext.RequiresDecision | Should -BeFalse
            }
            else {
                $withoutContext.Allowed | Should -BeFalse
                $withoutContext.ReasonCode | Should -Be 'LaunchAttemptUncertaintyNotStated'
            }
            $withContext = Test-RecoveryStateTransition -From $from -To 'INTERRUPTED_UNKNOWN' `
                -Context @{ Evidence = 'LaunchAttemptUncertain'; LaunchAttemptUncertain = $true }
            $withContext.Allowed | Should -BeTrue
            $withContext.RequiresDecision | Should -BeFalse
            # A string, a number, or a false flag is not the stated uncertainty.
            # The running-state edge is unguarded, so this applies only to the
            # edges that require the stated attempt.
            if ($from -ne 'SHORT_SCAN_RUNNING') {
                foreach ($notBoolean in @('true', 1, $false)) {
                    $refused = Test-RecoveryStateTransition -From $from -To 'INTERRUPTED_UNKNOWN' `
                        -Context @{ Evidence = 'LaunchAttemptUncertain'; LaunchAttemptUncertain = $notBoolean }
                    $refused.Allowed | Should -BeFalse
                    $refused.ReasonCode | Should -Be 'LaunchAttemptUncertaintyNotStated'
                }
            }
        }
    }
}
