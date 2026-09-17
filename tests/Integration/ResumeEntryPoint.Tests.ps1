BeforeAll {
    # Resolve everything from this file's location: Pester discovery does not run
    # from the repository root.
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
    $script:ModulesRoot = Join-Path -Path $script:RepoRoot -ChildPath 'modules'
    Import-Module (Join-Path -Path $script:ModulesRoot -ChildPath 'RecoveryLogging.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:ModulesRoot -ChildPath 'JobState.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:ModulesRoot -ChildPath 'DiskDetection.psm1') -Force -Global
    $script:EntryPoint = Join-Path -Path $script:RepoRoot -ChildPath 'RecoveryAutomation.ps1'
    . $script:EntryPoint
    $script:ConfigPath = Join-Path -Path $TestDrive -ChildPath 'resume-config.json'
    $configText = '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0}'
    Set-Content -LiteralPath $script:ConfigPath -Value $configText -Encoding ASCII

    $script:Now = '2026-09-16T07:00:00Z'

    function New-ResumeClock {
        param([string]$UtcInstant = $script:Now)
        $instant = [datetime]::Parse($UtcInstant, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $box = @{ Value = $instant }
        return { param($request) return [datetime]$box.Value }.GetNewClosure()
    }

    function New-ResumeCase {
        # A case folder exactly as the workflow writes it: claim marker, a log
        # whose sequence the state records, and the requested durable state.
        param(
            [string]$FolderName = '',
            [string]$StateName = 'SHORT_RECOVERY_VERIFIED',
            [switch]$KeepLock,
            [string]$SourceKey = 'FIXTURE-SOURCE',
            [string]$DestinationKey = 'FIXTURE-DEST',
            [string]$SourcePath = 'C:\ResumeSource'
        )
        # TestDrive is shared by the cases in this file, so every case is its own
        # folder: a second fixture in the same folder would be a claim collision.
        if ([string]::IsNullOrWhiteSpace($FolderName)) {
            $FolderName = 'ResumeClient_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        }
        $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
        [void][System.IO.Directory]::CreateDirectory($folder)
        $leaf = [System.IO.Path]::GetFileName($folder)
        $claim = @{
            ClaimId        = 'CLAIM-RESUME-001'
            ClientName     = 'ResumeClient'
            FolderName     = $leaf
            CreatedUtc     = $script:Now
            CollisionIndex = 0
        } | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
        $paths = [pscustomobject]@{
            JobFolderPath = $folder
            StatePath     = Join-Path -Path $folder -ChildPath 'job-state.json'
            LogPath       = Join-Path -Path $folder -ChildPath 'events.jsonl'
        }
        $log = New-RecoveryLog -Path $paths.LogPath -JobId $leaf -Clock (New-ResumeClock)
        $eventWriter = { param($event) return (Write-RecoveryLogEntry -Writer $log.Writer -Entry $event).Success }.GetNewClosure()
        # Production identity shape: the member key the provider publishes again on
        # a resume, plus the source path the state tells the resume to re-resolve.
        $sourceIdentity = [pscustomobject]@{
            Path            = $SourcePath
            CanonicalPath   = $SourcePath
            Resolved        = $true
            Exists          = $true
            IsContainer     = $true
            VolumeGuid      = 'RESUME-SOURCE-VOLUME'
            VolumePath      = 'RESUME-SOURCE-VOLUME-PATH'
            DriveLetter     = $null
            IdentityKeys    = @('UID|WWN|' + $SourceKey)
            PhysicalDisks   = @([pscustomobject]@{ IdentityKey = ('UID|WWN|' + $SourceKey); UniqueId = $SourceKey; UniqueIdFormat = 'WWN'; SizeBytes = 1000000; Model = 'ResumeSource' })
            IsIndeterminate = $false
            ReasonCode      = $null
        }
        $destinationIdentity = [pscustomobject]@{
            Path            = $folder
            CanonicalPath   = $folder
            Resolved        = $true
            Exists          = $true
            IsContainer     = $true
            VolumeGuid      = 'RESUME-DESTINATION-VOLUME'
            VolumePath      = 'RESUME-DESTINATION-VOLUME-PATH'
            DriveLetter     = $null
            IdentityKeys    = @('UID|WWN|' + $DestinationKey)
            PhysicalDisks   = @([pscustomobject]@{ IdentityKey = ('UID|WWN|' + $DestinationKey); UniqueId = $DestinationKey; UniqueIdFormat = 'WWN'; SizeBytes = 2000000; Model = 'ResumeDestination' })
            IsIndeterminate = $false
            ReasonCode      = $null
        }
        $state = New-RecoveryJobState -JobId $leaf -SourceIdentity $sourceIdentity `
            -DestinationIdentity $destinationIdentity `
            -ApplicationEvidence ([pscustomobject]@{ FileScavenger = $null; RStudio = $null }) -Paths $paths `
            -WorkflowVersion '1.0.0' -State 'PREFLIGHT_PENDING' -Clock (New-ResumeClock)
        $steps = @(
            @{ To = 'PREFLIGHT_PASSED'; Evidence = 'PreflightPassed' }
            @{ To = 'CASE_READY'; Evidence = 'CaseCreated' }
            @{ To = 'SHORT_SCAN_RUNNING'; Evidence = 'LaunchGateRecorded'; Stage = 'SHORT_SCAN'; Suffix = 'short-scan' }
            @{ To = 'SHORT_SCAN_FINISHED'; Evidence = 'ScanFinished' }
            @{ To = 'SHORT_RECOVERY_RUNNING'; Evidence = 'RecoveryDestinationChecked'; Stage = 'SHORT_RECOVERY'; Suffix = 'short-recovery' }
            @{ To = 'SHORT_RECOVERY_FINISHED'; Evidence = 'RecoveryFinished' }
            @{ To = 'SHORT_RECOVERY_VERIFIED'; Evidence = 'OutputObserved' }
            @{ To = 'ABORTED'; Evidence = $null }
        )
        foreach ($step in $steps) {
            if ([string]$state.State -eq $StateName) { break }
            $context = @{ Evidence = $step.Evidence }
            if ($step.ContainsKey('Stage')) { $context['Stage'] = $step.Stage }
            if ($step.ContainsKey('Suffix')) { $context['AttemptId'] = ($leaf + '-' + $step.Suffix + '-001') }
            $transition = Set-RecoveryState -State $state -To $step.To -EventWriter $eventWriter -StateWriter $null `
                -Context $context -Clock (New-ResumeClock)
            if (-not $transition.Success) {
                throw ('Resume fixture could not reach ' + $step.To + ': ' + [string]$transition.ReasonCode + ' ' + [string]$transition.Message)
            }
        }
        if ([string]$state.State -ne $StateName) {
            throw ('Resume fixture could not reach ' + $StateName + '; it is at ' + [string]$state.State)
        }
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        # A resume acquires the case lock itself. A case whose worker crashed left
        # no lock file behind, because a resume never deletes one.
        if ($KeepLock) {
            Lock-RecoveryJob -JobPath $folder -Clock (New-ResumeClock) -Owner ('RecoveryAutomation/' + $leaf) `
                -JobId $leaf -LeaseMinutes 120 | Out-Null
        }
        return [pscustomobject]@{ Folder = $folder; Leaf = $leaf; Paths = $paths; State = $state; Log = $log }
    }

    function New-ResumeDiskProvider {
        param(
            [string]$SourceKey = 'FIXTURE-SOURCE',
            [string]$DestinationKey = 'FIXTURE-DEST',
            [int]$SourceDisk = 21,
            [int]$DestinationDisk = 22,
            [string]$SourcePath = 'C:\ResumeSource'
        )
        $disks = @(
            [pscustomobject]@{ DiskNumber = $SourceDisk; UniqueId = $SourceKey; UniqueIdFormat = 'WWN'; SerialNumber = ('SERIAL-' + $SourceKey); Model = 'ResumeSource'; SizeBytes = 1000000 }
            [pscustomobject]@{ DiskNumber = $DestinationDisk; UniqueId = $DestinationKey; UniqueIdFormat = 'WWN'; SerialNumber = ('SERIAL-' + $DestinationKey); Model = 'ResumeDestination'; SizeBytes = 2000000 }
        )
        return @{
            Name = 'ResumeFixture'
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
                $diskNumber = $DestinationDisk
                if ($isSource) { $diskNumber = $SourceDisk }
                return [pscustomobject]@{
                    CanonicalPath = $path
                    Exists = $true
                    IsContainer = $true
                    ReparseResolved = $true
                    IsReparsePoint = $false
                    MembersIncomplete = $false
                    DiskNumber = $diskNumber
                    PartitionNumber = 1
                    VolumeGuid = if ($isSource) { 'RESUME-SOURCE-VOLUME' } else { 'RESUME-DESTINATION-VOLUME' }
                    VolumePath = if ($isSource) { 'RESUME-SOURCE-VOLUME-PATH' } else { 'RESUME-DESTINATION-VOLUME-PATH' }
                    DriveLetter = $null
                }
            }.GetNewClosure()
            GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
        }
    }

    function New-ResumeRunRecorder {
        # Every seam that could reach a vendor process, a picker, or a launch is
        # recorded and refused, so a test can prove a resume took no such action.
        $record = New-Object System.Collections.Generic.List[string]
        $boom = {
            param($request)
            $record.Add('vendor') | Out-Null
            throw 'a resume must not launch or drive a vendor process'
        }.GetNewClosure()
        return [pscustomobject]@{ Calls = $record; Refuse = $boom }
    }
}

Describe 'Resume entry point' {
    It 'resumes a verified short recovery into the long scan without launching a vendor process' {
        $case = New-ResumeCase -StateName 'SHORT_RECOVERY_VERIFIED'
        $provider = New-ResumeDiskProvider
        $recorder = New-ResumeRunRecorder
        $interaction = { param($request) return 'Stop' }

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause -ResumeJobPath $case.Folder `
            -DiskProvider $provider -RuntimeProvider { return @{ Compatible = $true; Evidence = 'ResumeFixture' } } `
            -ElevationProvider { return $true } -InteractionProvider $interaction `
            -VendorProcessRunner $recorder.Refuse -FileScavengerProcessRunner $recorder.Refuse `
            -Clock (New-ResumeClock)

        $result.Success | Should -BeFalse
        $result.Mode | Should -Be 'Resume'
        $result.ReasonCode | Should -Be 'ManualGatePending'
        $result.CurrentState | Should -Be 'LONG_SCAN_RUNNING'
        $result.VendorLaunchAttempted | Should -BeFalse
        $recorder.Calls | Should -HaveCount 0
        $result.JobFolderPath | Should -Be $case.Folder
        $stateOnDisk = ([System.IO.File]::ReadAllText($case.Paths.StatePath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
        $stateOnDisk.State | Should -Be 'LONG_SCAN_RUNNING'
        $stateOnDisk.Stage | Should -Be 'LONG_SCAN'
        $stateOnDisk.AttemptId | Should -Be ($case.Leaf + '-long-scan-001')
        $logText = [System.IO.File]::ReadAllText($case.Paths.LogPath, (New-Object System.Text.UTF8Encoding($false)))
        # The routed stage is durably recorded as a new attempt for the long scan.
        $logText | Should -Match '"State":"LONG_SCAN_RUNNING"'
        $logText | Should -Match ($case.Leaf + '-long-scan-001')
        # The verified short recovery stage is never rerun: its own evidence is
        # the one recorded before the resume.
        @([regex]::Matches($logText, 'RecoveryFinished')).Count | Should -Be 1
        @([regex]::Matches($logText, '"SHORT_RECOVERY_RUNNING"')).Count | Should -Be 1
        # The state a resume leaves behind must still be readable through the same
        # binding gate, otherwise the case would be unresumable afterwards.
        $lockPath = Join-Path -Path $case.Folder -ChildPath 'job.lock'
        (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -BeTrue
        $lock = ([System.IO.File]::ReadAllText($lockPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
        [string]$lock.JobId | Should -Be $case.Leaf
    }

    It 'records an open attempt as INTERRUPTED_UNKNOWN before any operator prompt' {
        $case = New-ResumeCase -StateName 'SHORT_SCAN_RUNNING'
        $provider = New-ResumeDiskProvider
        $recorder = New-ResumeRunRecorder
        $statePath = $case.Paths.StatePath
        $prompts = New-Object System.Collections.Generic.List[string]
        $stateAtPrompt = New-Object System.Collections.Generic.List[string]
        $interaction = {
            param($request)
            $prompts.Add([string]$request.GateId) | Out-Null
            $snapshot = ([System.IO.File]::ReadAllText($statePath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
            $stateAtPrompt.Add([string]$snapshot.State) | Out-Null
            return 'Stop'
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause -ResumeJobPath $case.Folder `
            -DiskProvider $provider -RuntimeProvider { return @{ Compatible = $true; Evidence = 'ResumeFixture' } } `
            -ElevationProvider { return $true } -InteractionProvider $interaction `
            -VendorProcessRunner $recorder.Refuse -Clock (New-ResumeClock)

        $result.Success | Should -BeFalse
        $result.Mode | Should -Be 'Resume'
        $result.CurrentState | Should -Be 'INTERRUPTED_UNKNOWN'
        $recorder.Calls | Should -HaveCount 0
        # The durable transition happened before the technician was asked anything.
        $prompts.Count | Should -Be 1
        $prompts[0] | Should -Be 'G-06'
        $stateAtPrompt[0] | Should -Be 'INTERRUPTED_UNKNOWN'
        $stateOnDisk = ([System.IO.File]::ReadAllText($statePath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
        $stateOnDisk.State | Should -Be 'INTERRUPTED_UNKNOWN'
        $logText = [System.IO.File]::ReadAllText($case.Paths.LogPath, (New-Object System.Text.UTF8Encoding($false)))
        $logText | Should -Match 'StageInterruptedUnknown'
        $logText | Should -Match 'INTERRUPTED_UNKNOWN'
        # The interrupted stage is never re-run and no new attempt id is invented.
        $logText | Should -Not -Match 'SHORT_SCAN_RUNNING.*StageStarted.*short-scan-002'
    }

    It 'refuses a resume from a terminal state without changing the case record' {
        $case = New-ResumeCase -StateName 'ABORTED'
        $provider = New-ResumeDiskProvider
        $stateBytes = [System.IO.File]::ReadAllBytes($case.Paths.StatePath)
        $logBytes = [System.IO.File]::ReadAllBytes($case.Paths.LogPath)
        $claimBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $case.Folder -ChildPath 'job-claim.json'))

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause -ResumeJobPath $case.Folder `
            -DiskProvider $provider -RuntimeProvider { return @{ Compatible = $true; Evidence = 'ResumeFixture' } } `
            -ElevationProvider { return $true } -Clock (New-ResumeClock)

        $result.Success | Should -BeFalse
        $result.Mode | Should -Be 'Resume'
        $result.ReasonCode | Should -Be 'TerminalState'
        $result.CurrentState | Should -Be 'ABORTED'
        [System.IO.File]::ReadAllBytes($case.Paths.StatePath) | Should -Be $stateBytes
        [System.IO.File]::ReadAllBytes($case.Paths.LogPath) | Should -Be $logBytes
        [System.IO.File]::ReadAllBytes((Join-Path -Path $case.Folder -ChildPath 'job-claim.json')) | Should -Be $claimBytes
        # The only file the refusal adds is the lock the resume acquired, which is
        # the acquisition the resume contract mandates; no state, log, metadata, or
        # claim byte is written.
        $entries = @([System.IO.Directory]::GetFileSystemEntries($case.Folder) | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) } | Sort-Object)
        ($entries -join ',') | Should -Be (@('events.jsonl', 'job-claim.json', 'job-state.json', 'job.lock') -join ',')
        (Test-Path -LiteralPath (Join-Path -Path $case.Folder -ChildPath 'case-metadata.json')) | Should -BeFalse
    }

    It 'refuses a resume whose recorded source identity no longer matches' {
        $case = New-ResumeCase -StateName 'SHORT_RECOVERY_VERIFIED'
        $provider = New-ResumeDiskProvider -SourceKey 'REPLACED-SOURCE'
        $stateBytes = [System.IO.File]::ReadAllBytes($case.Paths.StatePath)
        $logBytes = [System.IO.File]::ReadAllBytes($case.Paths.LogPath)

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause -ResumeJobPath $case.Folder `
            -DiskProvider $provider -RuntimeProvider { return @{ Compatible = $true; Evidence = 'ResumeFixture' } } `
            -ElevationProvider { return $true } -Clock (New-ResumeClock)

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'SourceIdentityChanged'
        $result.ExitCode | Should -Be 4
        [System.IO.File]::ReadAllBytes($case.Paths.StatePath) | Should -Be $stateBytes
        [System.IO.File]::ReadAllBytes($case.Paths.LogPath) | Should -Be $logBytes
    }

    It 'refuses a resume while the case lock lease is still live' {
        $case = New-ResumeCase -StateName 'SHORT_RECOVERY_VERIFIED' -KeepLock
        $provider = New-ResumeDiskProvider
        $stateBytes = [System.IO.File]::ReadAllBytes($case.Paths.StatePath)
        $logBytes = [System.IO.File]::ReadAllBytes($case.Paths.LogPath)

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause -ResumeJobPath $case.Folder `
            -DiskProvider $provider -RuntimeProvider { return @{ Compatible = $true; Evidence = 'ResumeFixture' } } `
            -ElevationProvider { return $true } -Clock (New-ResumeClock)

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'LockHeld'
        [System.IO.File]::ReadAllBytes($case.Paths.StatePath) | Should -Be $stateBytes
        [System.IO.File]::ReadAllBytes($case.Paths.LogPath) | Should -Be $logBytes
    }

    It 'refuses a resume path that is not an existing case folder' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-case'
        $provider = New-ResumeDiskProvider

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -NoPause -ResumeJobPath $missing `
            -DiskProvider $provider -RuntimeProvider { return @{ Compatible = $true; Evidence = 'ResumeFixture' } } `
            -ElevationProvider { return $true } -Clock (New-ResumeClock)

        $result.Success | Should -BeFalse
        $result.ReasonCode | Should -Be 'ResumeCaseFolderMissing'
        (Test-Path -LiteralPath $missing) | Should -BeFalse
    }

    It 'reports the resume path in a dry run without touching a case, a vendor, or media' {
        $calls = New-Object System.Collections.Generic.List[string]
        $mediaProvider = {
            param($request)
            $calls.Add([string]$request.Operation) | Out-Null
            throw 'a dry run must not query recovery media'
        }.GetNewClosure()

        $result = Invoke-RecoveryAutomation -ConfigPath $script:ConfigPath -DryRun -NoPause `
            -ResumeJobPath 'D:\cases\Client_20260916-070000' -DiskProvider $mediaProvider

        $result.Success | Should -BeTrue
        $result.Mode | Should -Be 'DryRun'
        $result.RequestedInputs.ResumeJobPath | Should -Be 'D:\cases\Client_20260916-070000'
        $result.VendorLaunchAttempted | Should -BeFalse
        $calls | Should -HaveCount 0
    }

    It 'forwards the resume path through the elevated relaunch argument line' {
        $line = Get-RecoveryAutomationElevationArgumentLine -ScriptPath 'C:\case\RecoveryAutomation.ps1' `
            -ResumeJobPath 'D:\cases\Client_20260916-070000' -NoPause

        $line | Should -Match '-ResumeJobPath'
        $line | Should -Match 'D:\\cases\\Client_20260916-070000'
        $line | Should -Match '-NoPause'
        # A value the child process cannot be given safely is refused, not
        # forwarded in a form that would change the meaning of the run.
        { Get-RecoveryAutomationElevationArgumentLine -ScriptPath 'C:\case\RecoveryAutomation.ps1' -ResumeJobPath 'D:\cases\bad"case' } | Should -Throw
    }
}
