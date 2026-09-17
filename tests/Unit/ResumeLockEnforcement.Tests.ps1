BeforeAll {
    # Resolve the module paths from this file's location, never from the current
    # directory: Pester discovery does not run from the repository root.
    $script:RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    # -Global so the fixture helpers and the test bodies resolve the module
    # commands from any scope under Pester.
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/RecoveryLogging.psm1') -Force -Global
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'modules/JobState.psm1') -Force -Global

    $script:Now = '2026-09-16T07:00:00Z'

    function New-LockClock {
        param([string]$UtcInstant = $script:Now)
        $instant = [datetime]::Parse($UtcInstant, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $box = @{ Value = $instant }
        return { param($request) return [datetime]$box.Value }.GetNewClosure()
    }

    # A case folder exactly as the workflow creates it: claim marker first, then
    # the lock, then the state snapshot that the read has to validate.
    function New-CaseFixture {
        param(
            [string]$FolderName = 'case-a',
            [string]$JobId = 'CASE-FIXTURE-001',
            [string]$Owner = 'RecoveryAutomation/fixture',
            [string]$AcquireInstant = $script:Now,
            [int]$LeaseMinutes = 30
        )
        $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
        [void][System.IO.Directory]::CreateDirectory($folder)
        $claimId = 'CLAIM-FIXTURE-001'
        $claim = @{ ClaimId = $claimId; ClientName = 'FixtureClient'; FolderName = $FolderName; CreatedUtc = $AcquireInstant; CollisionIndex = 0 } | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'job-claim.json'), $claim, (New-Object System.Text.UTF8Encoding($false)))
        $lock = Lock-RecoveryJob -JobPath $folder -Clock (New-LockClock -UtcInstant $AcquireInstant) -Owner $Owner -JobId $JobId -LeaseMinutes $LeaseMinutes
        $paths = [pscustomobject]@{
            JobFolderPath = $folder
            StatePath     = Join-Path -Path $folder -ChildPath 'job-state.json'
            LogPath       = Join-Path -Path $folder -ChildPath 'events.jsonl'
        }
        $log = New-RecoveryLog -Path $paths.LogPath -JobId $JobId -Clock (New-LockClock -UtcInstant $AcquireInstant)
        $eventWriter = { param($event) return (Write-RecoveryLogEntry -Writer $log.Writer -Entry $event).Success }.GetNewClosure()
        # Production identity shape: a resolved path snapshot that publishes the
        # member identity keys the log comparison binds against.
        $sourceIdentity = [pscustomobject]@{ Path = 'C:\Source'; CanonicalPath = 'C:\Source'; Resolved = $true; Exists = $true; IsContainer = $true; VolumeGuid = 'V-SOURCE'; VolumePath = 'V-SOURCE-PATH'; IdentityKeys = @('UID|WWN|FIXTURE-SRC'); IsIndeterminate = $false }
        $destinationIdentity = [pscustomobject]@{ Path = 'D:\Dest'; CanonicalPath = 'D:\Dest'; Resolved = $true; Exists = $true; IsContainer = $true; VolumeGuid = 'V-DEST'; VolumePath = 'V-DEST-PATH'; IdentityKeys = @('UID|WWN|FIXTURE-DST'); IsIndeterminate = $false }
        $state = New-RecoveryJobState -JobId $JobId -SourceIdentity $sourceIdentity `
            -DestinationIdentity $destinationIdentity `
            -ApplicationEvidence ([pscustomobject]@{ FileScavenger = $null; RStudio = $null }) -Paths $paths -WorkflowVersion '1.0.0' -State 'PREFLIGHT_PENDING' -Clock (New-LockClock -UtcInstant $AcquireInstant)
        $state | Add-Member -NotePropertyName Lock -NotePropertyValue $lock -Force
        # One recorded transition, exactly as the workflow records its first
        # durable step: the event is written before the snapshot and the state
        # sequence ends at the log's last sequence.
        $transition = Set-RecoveryState -State $state -To 'PREFLIGHT_PASSED' -EventWriter $eventWriter `
            -StateWriter $null -Context @{ Evidence = 'PreflightPassed' } -Clock (New-LockClock -UtcInstant $AcquireInstant)
        if (-not $transition.Success) { throw ('Fixture transition failed: ' + [string]$transition.ReasonCode) }
        Write-RecoveryJobState -Path $paths.StatePath -State $state | Out-Null
        return [pscustomobject]@{ Folder = $folder; Lock = $lock; State = $state; Paths = $paths; Log = $log; JobId = $JobId; ClaimId = $claimId; Transition = $transition }
    }
}

Describe 'Resume state read enforces the lock lease and owner' {
    It 'refuses a resume read after the lease expired' {
        $fixture = New-CaseFixture -FolderName 'case-stale' -AcquireInstant '2026-09-16T07:00:00Z' -LeaseMinutes 1
        $lockBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $fixture.Folder -ChildPath 'job.lock'))

        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $fixture.Lock `
            -Clock (New-LockClock -UtcInstant '2026-09-16T09:00:00Z')

        $read.Success | Should -BeFalse
        $read.State | Should -BeNullOrEmpty
        $read.ReasonCode | Should -Be 'LockLeaseExpired'
        [System.IO.File]::ReadAllBytes((Join-Path -Path $fixture.Folder -ChildPath 'job.lock')) | Should -Be $lockBytes
    }

    It 'accepts a resume read while the lease is still live' {
        $fixture = New-CaseFixture -FolderName 'case-live' -AcquireInstant '2026-09-16T07:00:00Z' -LeaseMinutes 120

        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $fixture.Lock `
            -Clock (New-LockClock -UtcInstant '2026-09-16T08:00:00Z')

        $read.Success | Should -BeTrue
        $read.State.JobId | Should -Be $fixture.JobId
    }

    It 'refuses a resume read presented with a different owner' {
        $fixture = New-CaseFixture -FolderName 'case-owner' -Owner 'technician-a'
        $forged = $fixture.Lock.PSObject.Copy()
        $forged.Owner = 'technician-b'

        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $forged `
            -Clock (New-LockClock -UtcInstant '2026-09-16T07:10:00Z')

        $read.Success | Should -BeFalse
        $read.ReasonCode | Should -Be 'LockOwnerMismatch'
    }

    It 'refuses a resume read when the lock records no job id' {
        $fixture = New-CaseFixture -FolderName 'case-nojobid'
        $lockPath = Join-Path -Path $fixture.Folder -ChildPath 'job.lock'
        $content = ([System.IO.File]::ReadAllText($lockPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
        $content.JobId = ''
        [System.IO.File]::WriteAllText($lockPath, ($content | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))

        $read = Read-RecoveryJobState -Path $fixture.Paths.StatePath -Lock $fixture.Lock `
            -Clock (New-LockClock -UtcInstant '2026-09-16T07:10:00Z')

        $read.Success | Should -BeFalse
        $read.ReasonCode | Should -Be 'LockNotBound'
    }
}
