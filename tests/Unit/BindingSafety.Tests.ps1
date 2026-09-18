BeforeAll {
    $script:RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/JobState.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/RecoveryLogging.psm1') -Force -Global
    # Case logs are opened with a shared read handle, so a leaked writer makes
    # Pester's TestDrive cleanup fail on Windows: every log opened here is
    # released by the file level AfterAll.
    $script:BindingLogWriters = New-Object System.Collections.Generic.List[object]

    # The clock seam is a script block or an object that states NowUtc. A bare
    # DateTime states neither, so it is refused like any other unusable clock
    # instead of being read as a wall clock instant.
    function New-BindingClock {
        param([string]$UtcInstant = '2026-09-16T07:00:00Z')
        return [pscustomobject]@{ NowUtc = [datetime]::Parse($UtcInstant, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
    }

    function New-BindingClaimFolder {
        param([string]$Name = 'clock-case')
        $folder = Join-Path -Path $TestDrive -ChildPath $Name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $claim = @{ ClaimId = 'CLAIM-BINDING'; ClientName = 'BindingFixture'; FolderName = $Name; CreatedUtc = '2026-09-16T07:00:00Z'; CollisionIndex = 0 } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
        return $folder
    }

    function New-ProductionIdentity {
        param(
            [string]$Path = 'C:\Source',
            [string]$CanonicalPath = 'C:\Source',
            [string]$VolumeGuid = 'VOLUME-SOURCE',
            [string]$VolumePath = 'VOLUME-PATH-SOURCE',
            [string]$IdentityKey = 'UID|WWN|SOURCE'
        )
        return [pscustomobject]@{
            Path             = $Path
            CanonicalPath    = $CanonicalPath
            Resolved         = $true
            Exists           = $true
            IsContainer      = $true
            VolumeGuid       = $VolumeGuid
            VolumePath       = $VolumePath
            DiskNumber       = 1
            PhysicalDisks    = @([pscustomobject]@{ IdentityKey = $IdentityKey; IsIndeterminate = $false })
            IdentityKeys     = @($IdentityKey)
            IsIndeterminate  = $false
        }
    }

    function New-DecisionState {
        param([object]$SourceIdentity = (New-ProductionIdentity), [object]$DestinationIdentity = (New-ProductionIdentity -Path 'D:\Destination' -CanonicalPath 'D:\Destination' -VolumeGuid 'VOLUME-DEST' -VolumePath 'VOLUME-PATH-DEST' -IdentityKey 'UID|WWN|DEST'))
        return New-RecoveryJobState -JobId 'BINDING-DECISION-1' -SourceIdentity $SourceIdentity -DestinationIdentity $DestinationIdentity -ApplicationEvidence @{} -Paths ([pscustomobject]@{ JobFolderPath = $TestDrive; StatePath = (Join-Path -Path $TestDrive -ChildPath 'state.json'); LogPath = (Join-Path -Path $TestDrive -ChildPath 'events.jsonl') }) -WorkflowVersion '1.0' -Clock (New-BindingClock) -State 'SHORT_RECOVERY_VERIFIED'
    }

    function New-ResumeShapeIdentity {
        # The exact shape the resume entry point records and re-resolves: the
        # recorded member states the key and the disk evidence but no member
        # number, and the fresh member adds the member number.
        param(
            [string]$Path = 'C:\ResumeSource',
            [string]$VolumeGuid = 'RESUME-SOURCE-VOLUME',
            [string]$VolumePath = 'RESUME-SOURCE-VOLUME-PATH',
            [string]$Key = 'FIXTURE-SOURCE',
            [bool]$WithDiskNumber = $false
        )
        $member = [ordered]@{
            IdentityKey    = ('UID|WWN|' + $Key)
            UniqueId       = $Key
            UniqueIdFormat = 'WWN'
            IsIndeterminate = $false
        }
        if ($WithDiskNumber) { $member['DiskNumber'] = 21 }
        return [pscustomobject]@{
            Path            = $Path
            CanonicalPath   = $Path
            Resolved        = $true
            Exists          = $true
            IsContainer     = $true
            VolumeGuid      = $VolumeGuid
            VolumePath      = $VolumePath
            DiskNumber      = 21
            IdentityKeys    = @('UID|WWN|' + $Key)
            PhysicalDisks   = @([pscustomobject]$member)
            IsIndeterminate = $false
        }
    }

    function New-DurableIdentityState {
        param(
            [string]$FolderName = 'identity-case',
            [string]$StateName = 'CASE_READY',
            [string]$Stage = 'CASE',
            [string]$AttemptId = 'ATTEMPT-0'
        )
        $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $claim = @{ ClaimId = 'CLAIM-BINDING'; ClientName = 'BindingFixture'; FolderName = $FolderName; CreatedUtc = '2026-09-16T07:00:00Z'; CollisionIndex = 0 } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
        $paths = [pscustomobject]@{
            JobFolderPath = $folder
            StatePath     = Join-Path -Path $folder -ChildPath 'job-state.json'
            LogPath       = Join-Path -Path $folder -ChildPath 'events.jsonl'
        }
        $log = New-RecoveryLog -Path $paths.LogPath -JobId 'BINDING-001' -Clock (New-BindingClock)
        if ($null -ne $log -and $log.Success -eq $true -and $null -ne $log.Writer) { $script:BindingLogWriters.Add($log.Writer) | Out-Null }
        $lock = Lock-RecoveryJob -JobPath $folder -Owner 'binding-owner' -JobId 'BINDING-001' -LeaseMinutes 30 -Clock (New-BindingClock)
        $eventWriter = { param($event) return (Write-RecoveryLogEntry -Writer $log.Writer -Entry $event).Success }.GetNewClosure()
        $state = New-RecoveryJobState -JobId 'BINDING-001' -SourceIdentity (New-ProductionIdentity) -DestinationIdentity (New-ProductionIdentity -Path 'D:\Destination' -CanonicalPath 'D:\Destination' -VolumeGuid 'VOLUME-DEST' -VolumePath 'VOLUME-PATH-DEST' -IdentityKey 'UID|WWN|DEST') -ApplicationEvidence @{} -Paths $paths -WorkflowVersion '1.0' -State $StateName -Clock (New-BindingClock)
        $state.Stage = $Stage
        $state.AttemptId = $AttemptId
        return [pscustomobject]@{ Folder = $folder; Paths = $paths; State = $state; Log = $log; Lock = $lock; EventWriter = $eventWriter }
    }
}

Describe 'Binding safety clock refusal' {
    It 'refuses a throwing clock with a named result instead of using wall clock time' {
        $folder = New-BindingClaimFolder
        $throwingClock = { throw 'clock fixture failure' }

        $result = Lock-RecoveryJob -JobPath $folder -Clock $throwingClock -Owner 'binding-worker' -JobId 'BINDING-1'

        $result.Acquired | Should -BeFalse
        $result.ReasonCode | Should -Be 'ClockInvalid'
        Test-Path -LiteralPath (Join-Path -Path $folder -ChildPath 'job.lock') | Should -BeFalse
    }

    It 'refuses an array-valued or unparsable clock with the same named result' {
        foreach ($clock in @(
            { return @([datetime]'2026-09-16T07:00:00Z', [datetime]'2026-09-16T07:01:00Z') }
            { return 'not-a-utc-instant' }
        )) {
            $folder = New-BindingClaimFolder -Name ([guid]::NewGuid().ToString('N'))
            $result = Lock-RecoveryJob -JobPath $folder -Clock $clock -Owner 'binding-worker' -JobId 'BINDING-2'

            $result.Acquired | Should -BeFalse
            $result.ReasonCode | Should -Be 'ClockInvalid'
            Test-Path -LiteralPath (Join-Path -Path $folder -ChildPath 'job.lock') | Should -BeFalse
        }
    }
}

Describe 'Binding safety identity comparison' {
    It 'refuses a production-shaped source whose volume changed while the key stayed the same' {
        $recorded = New-ProductionIdentity
        $fresh = New-ProductionIdentity -VolumeGuid 'VOLUME-SOURCE-CHANGED'
        $state = New-DecisionState -SourceIdentity $recorded
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity $fresh -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'SourceIdentityChanged'
    }

    It 'fails closed when the fresh snapshot states no identity keys at all' {
        $state = New-DecisionState
        $fresh = New-ProductionIdentity
        $fresh.IdentityKeys = @()
        $fresh.PhysicalDisks = @()
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity $fresh -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'IdentityIndeterminate'
    }

    It 'fails closed when the recorded snapshot carries no identity keys at all' {
        $empty = New-ProductionIdentity
        $empty.IdentityKeys = @()
        $empty.PhysicalDisks = @()
        $state = New-DecisionState -SourceIdentity $empty
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-ProductionIdentity) -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'IdentityIndeterminate'
    }

    It 'fails closed when a snapshot carries no identity keys that could be compared' {
        $recorded = New-ProductionIdentity
        $recorded.IdentityKeys = @('   ')
        $recorded.PhysicalDisks = @([pscustomobject]@{ IdentityKey = ''; IsIndeterminate = $false })
        $state = New-DecisionState -SourceIdentity $recorded
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-ProductionIdentity) -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'IdentityIndeterminate'
    }

    It 'fails closed when the member key disagrees with the top level key of the same snapshot' {
        $recorded = New-ProductionIdentity
        $recorded.PhysicalDisks = @([pscustomobject]@{ IdentityKey = 'UID|WWN|OTHER'; IsIndeterminate = $false })
        $state = New-DecisionState -SourceIdentity $recorded
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity (New-ProductionIdentity) -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'SourceIdentityChanged'
    }

    It 'fails closed when the physical member of a resume pair is a different disk' {
        $recorded = New-ResumeShapeIdentity
        $fresh = New-ResumeShapeIdentity -Key 'REPLACED-SOURCE' -WithDiskNumber $true
        $state = New-DecisionState -SourceIdentity $recorded
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity $fresh -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'SourceIdentityChanged'
    }

    It 'accepts a resume pair whose recorded member omits the number the fresh member states' {
        $recorded = New-ResumeShapeIdentity
        $fresh = New-ResumeShapeIdentity -WithDiskNumber $true
        $state = New-DecisionState -SourceIdentity $recorded
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity $fresh -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'ResumeNext'
    }

    It 'fails closed when both snapshots state different member numbers for one key' {
        $recorded = New-ResumeShapeIdentity -WithDiskNumber $true
        $fresh = New-ResumeShapeIdentity -WithDiskNumber $true
        $fresh.PhysicalDisks = @([pscustomobject]@{ IdentityKey = 'UID|WWN|FIXTURE-SOURCE'; UniqueId = 'FIXTURE-SOURCE'; UniqueIdFormat = 'WWN'; IsIndeterminate = $false; DiskNumber = 22 })
        $state = New-DecisionState -SourceIdentity $recorded
        $space = [pscustomobject]@{ IsUnknown = $false; IsSufficient = $true; AvailableBytes = 5000000 }

        $decision = Get-RecoveryResumeDecision -State $state -FreshSourceIdentity $fresh -FreshDestinationIdentity $state.DestinationIdentity -FreshSpace $space

        $decision.Decision | Should -Be 'FailedClosed'
        $decision.ReasonCode | Should -Be 'SourceIdentityChanged'
    }
}

Describe 'Binding safety launch uncertainty transitions' {
    It 'refuses a durable unknown transition without stated launch uncertainty context' {
        $withoutContext = Test-RecoveryStateTransition -From 'CASE_READY' -To 'INTERRUPTED_UNKNOWN' -Context @{ Evidence = 'LaunchAttemptUncertain' }
        $handoffWithoutContext = Test-RecoveryStateTransition -From 'READY_FOR_HANDOFF' -To 'INTERRUPTED_UNKNOWN' -Context @{ Evidence = 'LaunchAttemptUncertain' }
        $stringContext = Test-RecoveryStateTransition -From 'CASE_READY' -To 'INTERRUPTED_UNKNOWN' -Context @{ Evidence = 'LaunchAttemptUncertain'; LaunchAttemptUncertain = 'true' }

        $withoutContext.Allowed | Should -BeFalse
        $withoutContext.ReasonCode | Should -Be 'LaunchAttemptUncertaintyNotStated'
        $handoffWithoutContext.Allowed | Should -BeFalse
        $handoffWithoutContext.ReasonCode | Should -Be 'LaunchAttemptUncertaintyNotStated'
        $stringContext.Allowed | Should -BeFalse
        $stringContext.ReasonCode | Should -Be 'LaunchAttemptUncertaintyNotStated'
    }

    It 'allows a durable unknown transition from CASE_READY and READY_FOR_HANDOFF with explicit uncertainty' {
        $fromCase = Test-RecoveryStateTransition -From 'CASE_READY' -To 'INTERRUPTED_UNKNOWN' -Context @{ Evidence = 'LaunchAttemptUncertain'; LaunchAttemptUncertain = $true }
        $fromHandoff = Test-RecoveryStateTransition -From 'READY_FOR_HANDOFF' -To 'INTERRUPTED_UNKNOWN' -Context @{ Evidence = 'LaunchAttemptUncertain'; LaunchAttemptUncertain = $true }

        $fromCase.Allowed | Should -BeTrue
        $fromCase.RequiredEvidence | Should -Be 'LaunchAttemptUncertain'
        $fromHandoff.Allowed | Should -BeTrue
    }

    It 'writes the uncertainty context event and the durable unknown snapshot' {
        $fixture = New-DurableIdentityState -FolderName 'binding-uncertain'
        Write-RecoveryJobState -Path $fixture.Paths.StatePath -State $fixture.State | Out-Null

        $denied = Set-RecoveryState -State $fixture.State -To 'INTERRUPTED_UNKNOWN' -EventWriter $fixture.EventWriter -Context @{ Evidence = 'LaunchAttemptUncertain' }
        $deniedState = $fixture.State.State
        $allowed = Set-RecoveryState -State $fixture.State -To 'INTERRUPTED_UNKNOWN' -EventWriter $fixture.EventWriter `
            -Context @{ Evidence = 'LaunchAttemptUncertain'; LaunchAttemptUncertain = $true; Stage = 'LAUNCH'; AttemptId = 'ATTEMPT-1'; EventType = 'StageInterruptedUnknown'; Reason = 'LaunchOutcomeUnproven' }
        $check = Test-RecoveryLog -Path $fixture.Paths.LogPath -JobId 'BINDING-001'
        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $fixture.Lock -Clock (New-BindingClock -UtcInstant '2026-09-16T07:05:00Z')

        $denied.Success | Should -BeFalse
        $denied.ReasonCode | Should -Be 'LaunchAttemptUncertaintyNotStated'
        $deniedState | Should -Be 'CASE_READY'
        $allowed.Success | Should -BeTrue
        $allowed.State.State | Should -Be 'INTERRUPTED_UNKNOWN'
        $allowed.Event.EventType | Should -Be 'StageInterruptedUnknown'
        $allowed.Event.AttemptId | Should -Be 'ATTEMPT-1'
        $allowed.Event.Reason | Should -Be 'LaunchOutcomeUnproven'
        $check.LastEvent.State | Should -Be 'INTERRUPTED_UNKNOWN'
        $check.LastEvent.EventType | Should -Be 'StageInterruptedUnknown'
        $fixture.Lock.Acquired | Should -BeTrue
        $read.Success | Should -BeTrue
        $read.State.State | Should -Be 'INTERRUPTED_UNKNOWN'
    }

    It 'still refuses an unguarded transition into a running stage from CASE_READY' {
        $decision = Test-RecoveryStateTransition -From 'CASE_READY' -To 'LONG_SCAN_RUNNING' -Context @{ LaunchAttemptUncertain = $true }

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'IllegalTransition'
    }
}

AfterAll {
    foreach ($writer in $script:BindingLogWriters.ToArray()) {
        try { [void](RecoveryLogging\Close-RecoveryLog -Writer $writer) } catch { }
    }
    $script:BindingLogWriters.Clear()
}
