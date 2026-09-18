# Runtime regression tests for the default front door of RecoveryAutomation.ps1:
# explicit CLI forwarding through the real entry point, interactive provider
# wiring, and the explicit technician evidence seams.
#
# Deterministic only: TestDrive fixtures and in-process invocation of the real
# entry point. No process launch, no storage cmdlet, no vendor application, no
# recovery-media operation, and no screen input: the prompt seams are shadowed
# with a global Read-Host function for the duration of each test.

BeforeAll {
    $script:RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:EntryPoint = Join-Path -Path $script:RepoRoot -ChildPath 'RecoveryAutomation.ps1'
    $script:ConfigPath = Join-Path -Path $TestDrive -ChildPath 'runtime-regression-config.json'
    $configText = '{"SchemaVersion":1,"WorkflowVersion":"1.0.0","ValidatedFileScavengerBuilds":[],"ValidatedRStudioBuilds":[],"CapacityReserveBytes":0,"ClientName":"Configured Client"}'
    [System.IO.File]::WriteAllText($script:ConfigPath, $configText, (New-Object System.Text.ASCIIEncoding))

    if (Test-Path -LiteralPath $script:EntryPoint -PathType Leaf) {
        . $script:EntryPoint
    }

    # The front door self-elevates on Windows. Invoking it in-process is only
    # meaningful when the current host can already act as the elevated process;
    # otherwise the invocation returns the bounded ElevationDeclined result and
    # the hosted Windows lanes would assert against the wrong path.
    $script:FrontDoorRunnable = $true
    if ($env:OS -eq 'Windows_NT') {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $script:FrontDoorRunnable = [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # Runs one body with Read-Host answered by a fixed string. The shadow is
    # global so module-scoped provider closures resolve it, and it is removed in
    # finally so no other test can see it.
    function script:Invoke-WithPromptAnswer {
        param(
            [AllowEmptyString()][string]$Answer,
            [Parameter(Mandatory = $true)][scriptblock]$Body
        )
        function global:Read-Host {
            param([string]$Prompt)
            return $Answer
        }
        try { return (& $Body) }
        finally { Remove-Item -LiteralPath 'Function:\global:Read-Host' -Force -ErrorAction SilentlyContinue }
    }

    # The front door relaunches itself through UAC on a non-elevated Windows
    # host. That relaunch is an owner-live gate (docs/LIVE-VALIDATION.md), so the
    # in-process front-door assertions only run where no relaunch is needed.
    function script:Assert-FrontDoorRunnable {
        if (-not $script:FrontDoorRunnable) {
            Set-ItResult -Skipped -Because 'the front door relaunches through UAC on a non-elevated Windows host'
            return $false
        }
        return $true
    }
}

Describe 'Front door forwarding and the elevated relaunch line' {

    It 'forwards the explicit client name and destination path through the real entry point' {
        if (-not (Assert-FrontDoorRunnable)) { return }
        $result = & $script:EntryPoint -ConfigPath $script:ConfigPath -NoPause -DryRun `
            -ClientName 'CLI forwarding probe' -DestinationPath 'D:\Recovery'

        $result.Success | Should -BeTrue
        $result.Mode | Should -Be 'DryRun'
        $result.Configuration.ClientName | Should -Be 'CLI forwarding probe'
        $result.Configuration.DestinationRoot | Should -Be 'D:\Recovery'
    }

    It 'keeps the configured client name when the command line does not override it' {
        if (-not (Assert-FrontDoorRunnable)) { return }
        $result = & $script:EntryPoint -ConfigPath $script:ConfigPath -NoPause -DryRun

        $result.Success | Should -BeTrue
        $result.Configuration.ClientName | Should -Be 'Configured Client'
    }

    It 'carries explicit technician inputs through the elevated relaunch argument line' {
        $line = Get-RecoveryAutomationElevationArgumentLine -ScriptPath 'C:\Recovery Jobs\RecoveryAutomation.ps1' `
            -ConfigPath 'C:\Recovery Jobs\client config.json' `
            -SourcePath 'E:\Evidence Disk' -DestinationPath 'D:\Recovery Output' -ClientName 'Probe Client' `
            -NoPause -DryRun

        $line.Contains('-SourcePath') | Should -BeTrue
        $line.Contains('"E:\Evidence Disk"') | Should -BeTrue
        $line.Contains('-DestinationPath') | Should -BeTrue
        $line.Contains('"D:\Recovery Output"') | Should -BeTrue
        $line.Contains('-ClientName') | Should -BeTrue
        $line.Contains('"Probe Client"') | Should -BeTrue
    }

    It 'omits unsupplied technician inputs from the elevated relaunch argument line' {
        $line = Get-RecoveryAutomationElevationArgumentLine -ScriptPath 'C:\Recovery Jobs\RecoveryAutomation.ps1' -NoPause -DryRun

        $line.Contains('-SourcePath') | Should -BeFalse
        $line.Contains('-DestinationPath') | Should -BeFalse
        $line.Contains('-ClientName') | Should -BeFalse
    }
}

Describe 'Default front-door provider wiring' {

    It 'resolves interactive defaults when no provider was injected' {
        $wiring = Get-RecoveryAutomationFrontDoorWiring

        $wiring.SourceSelector | Should -BeOfType [scriptblock]
        $wiring.SourceProtectionProvider | Should -BeOfType [scriptblock]
        $wiring.DestinationPickerProvider | Should -BeOfType [scriptblock]
        $wiring.TypedDestinationProvider | Should -BeOfType [scriptblock]
        $wiring.InteractionProvider | Should -BeOfType [scriptblock]
        $wiring.ClientNameProvider | Should -BeOfType [scriptblock]

        $names = @($wiring.Evidence | ForEach-Object { [string]$_.Name })
        foreach ($name in @('SourceSelector', 'SourceProtectionProvider', 'DestinationPickerProvider',
                'TypedDestinationProvider', 'InteractionProvider', 'ClientNameProvider')) {
            $names | Should -Contain $name
        }
        $sources = @($wiring.Evidence | ForEach-Object { [string]$_.Source })
        $sources | Should -Not -Contain 'Missing'
    }

    It 'preserves explicitly injected providers unchanged' {
        $customSelector = { param($request) return 'E:\Injected Source' }
        $customInteraction = { param($request) return 'Stop' }

        $wiring = Get-RecoveryAutomationFrontDoorWiring -SourceSelector $customSelector -InteractionProvider $customInteraction

        (& $wiring.SourceSelector $null) | Should -Be 'E:\Injected Source'
        (& $wiring.InteractionProvider $null) | Should -Be 'Stop'
        ($wiring.Evidence | Where-Object { $_.Name -eq 'SourceSelector' }).Source | Should -Be 'Injected'
        ($wiring.Evidence | Where-Object { $_.Name -eq 'InteractionProvider' }).Source | Should -Be 'Injected'
    }

    It 'records the interactive wiring on the front-door result' {
        if (-not (Assert-FrontDoorRunnable)) { return }
        $result = & $script:EntryPoint -ConfigPath $script:ConfigPath -NoPause -DryRun

        $result.Success | Should -BeTrue
        $wiringEvidence = @($result.FrontDoorWiring)
        $wiringEvidence.Count | Should -BeGreaterThan 0
        $selectorEntry = $wiringEvidence | Where-Object { $_.Name -eq 'SourceSelector' }
        $null -ne $selectorEntry | Should -BeTrue
        $selectorEntry.Source | Should -Be 'InteractiveDefault'
    }

    It 'records injected front-door providers as injected on the result' {
        if (-not (Assert-FrontDoorRunnable)) { return }
        $customSelector = { param($request) return 'E:\Injected Source' }

        $result = & $script:EntryPoint -ConfigPath $script:ConfigPath -NoPause -DryRun -SourceSelector $customSelector

        $selectorEntry = @($result.FrontDoorWiring) | Where-Object { $_.Name -eq 'SourceSelector' }
        $selectorEntry.Source | Should -Be 'Injected'
    }
}

Describe 'Explicit technician evidence seams' {
    BeforeAll {
        Import-Module -Name (Join-Path -Path $script:RepoRoot -ChildPath 'modules/TechnicianUi.psm1') -Force -ErrorAction Stop
        $script:ProtectionRequest = [pscustomobject]@{
            Purpose   = 'SourceProtection'
            Path      = 'E:\Evidence Disk'
            Selection = $null
        }
        $script:SelectionRequest = [pscustomobject]@{
            Purpose     = 'SourceSelection'
            Description = 'Select the read-only source.'
        }
        $script:ClientRequest = [pscustomobject]@{ Purpose = 'ClientName' }
    }

    It 'records a source protection operator attestation distinctly from a measured state' {
        $provider = Get-TechnicianUiDefaultProvider -Name 'SourceProtectionAttestationProvider'

        $raw = Invoke-WithPromptAnswer -Answer 'ATTEST' -Body { & $provider $script:ProtectionRequest }

        $raw.Verified | Should -BeTrue
        $raw.EvidenceKind | Should -Be 'OperatorAttestation'
        ([string]$raw.Evidence).ToLowerInvariant().Contains('attestation') | Should -BeTrue
        ([string]$raw.Evidence).ToLowerInvariant().Contains('measured') | Should -BeFalse

        $protection = Invoke-WithPromptAnswer -Answer 'ATTEST' -Body {
            Test-RecoveryAutomationSourceProtection -Path 'E:\Evidence Disk' -Selection $null -Provider $provider
        }
        $protection.Verified | Should -BeTrue
        $protection.EvidenceKind | Should -Be 'OperatorAttestation'
        $protection.EvidenceKind | Should -Not -Be 'MeasuredState'
    }

    It 'refuses source protection input that is not the explicit attestation' {
        $provider = Get-TechnicianUiDefaultProvider -Name 'SourceProtectionAttestationProvider'

        $raw = Invoke-WithPromptAnswer -Answer 'yes the blocker is attached' -Body { & $provider $script:ProtectionRequest }

        $raw.Verified | Should -BeFalse

        $protection = Invoke-WithPromptAnswer -Answer 'yes the blocker is attached' -Body {
            Test-RecoveryAutomationSourceProtection -Path 'E:\Evidence Disk' -Selection $null -Provider $provider
        }
        $protection.Verified | Should -BeFalse
        $protection.ReasonCode | Should -Be 'SourceProtectionUnverified'
    }

    It 'selects the source through the typed fallback when the folder browser is unavailable' -Skip:($env:OS -eq 'Windows_NT') {
        $provider = Get-TechnicianUiDefaultProvider -Name 'SourceSelectorProvider'

        $raw = Invoke-WithPromptAnswer -Answer 'E:\Fixture Source' -Body { & $provider $script:SelectionRequest }

        $raw.Selected | Should -BeTrue
        $raw.Path | Should -Be 'E:\Fixture Source'
        $raw.SelectionMethod | Should -Be 'TypedPath'

        $selection = Invoke-WithPromptAnswer -Answer 'E:\Fixture Source' -Body {
            Get-RecoveryAutomationSourceSelection -ExplicitPath '' -Selector $provider
        }
        $selection.Selected | Should -BeTrue
        $selection.Path | Should -Be 'E:\Fixture Source'
    }

    It 'fails closed when the source selector yields no usable path' -Skip:($env:OS -eq 'Windows_NT') {
        $provider = Get-TechnicianUiDefaultProvider -Name 'SourceSelectorProvider'

        $raw = Invoke-WithPromptAnswer -Answer '' -Body { & $provider $script:SelectionRequest }
        $raw.Selected | Should -BeFalse

        $selection = Invoke-WithPromptAnswer -Answer '' -Body {
            Get-RecoveryAutomationSourceSelection -ExplicitPath '' -Selector $provider
        }
        $selection.Selected | Should -BeFalse
        $selection.ReasonCode | Should -Be 'SourceNotSelected'
    }

    It 'prompts for an explicit client name and rejects empty input' {
        $provider = Get-TechnicianUiDefaultProvider -Name 'ClientNameProvider'

        $answered = Invoke-WithPromptAnswer -Answer '  Acme Case  ' -Body { & $provider $script:ClientRequest }
        $answered.ClientName | Should -Be 'Acme Case'
        $answered.Cancelled | Should -BeFalse

        $empty = Invoke-WithPromptAnswer -Answer '' -Body { & $provider $script:ClientRequest }
        $empty.Cancelled | Should -BeTrue
        [string]::IsNullOrWhiteSpace([string]$empty.ClientName) | Should -BeTrue
    }
}

Describe 'Case event log handle regression' {
    BeforeAll {
        Import-Module -Name (Join-Path -Path $script:RepoRoot -ChildPath 'modules/RecoveryLogging.psm1') -Force -ErrorAction Stop
    }

    It 'keeps the open case log readable, refuses an out-of-band change, and refuses writes afterwards' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'close-regression.jsonl'
        $created = RecoveryLogging\New-RecoveryLog -Path $logPath -JobId 'CLOSE-REGRESSION-1'

        $created.Success | Should -BeTrue
        $created.Writer.IsOpen | Should -BeTrue

        # The case log is not held open between events, so a reader and the case
        # itself can both see it: an exclusive open while the case is live is the
        # condition that made the Windows lane, Pester TestDrive cleanup, and any
        # technician editor fail with a sharing violation.
        $seenWhileOpen = $false
        $reader = $null
        try {
            $reader = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $seenWhileOpen = $true
        }
        catch { $seenWhileOpen = $false }
        if ($null -ne $reader) { $reader.Dispose() }
        $seenWhileOpen | Should -BeTrue

        # Append-only integrity is enforced by the recorded offset instead of a
        # held handle: an out-of-band change to the record is refused, and the
        # refusal blocks every later write.
        $entry = @{
            JobId = 'CLOSE-REGRESSION-1'
            State = 'CASE_READY'
            Stage = 'PREFLIGHT'
            EventType = 'StageStarted'
            Result = 'Recorded'
        }
        $first = RecoveryLogging\Write-RecoveryLogEntry -Writer $created.Writer -Entry $entry
        $first.Success | Should -BeTrue
        [System.IO.File]::AppendAllText($logPath, '{"EventId":"tampered"}' + [char]10)
        $tampered = RecoveryLogging\Write-RecoveryLogEntry -Writer $created.Writer -Entry $entry
        $tampered.Success | Should -BeFalse
        $tampered.ReasonCode | Should -Be 'LogAppendFailed'
        $created.Writer.IsBlocked | Should -BeTrue

        $closed = RecoveryLogging\Close-RecoveryLog -Writer $created.Writer
        $closed.Success | Should -BeTrue
        $created.Writer.IsOpen | Should -BeFalse

        # After the close, the same exclusive open succeeds and later writes are
        # refused instead of silently succeeding against a released handle.
        $reopened = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $reopened.Dispose()

        $entry = @{
            JobId = 'CLOSE-REGRESSION-1'
            State = 'CASE_READY'
            Stage = 'PREFLIGHT'
            EventType = 'StageStarted'
            Result = 'Recorded'
        }
        $write = RecoveryLogging\Write-RecoveryLogEntry -Writer $created.Writer -Entry $entry
        $write.Success | Should -BeFalse
        $write.ReasonCode | Should -Be 'LogNotOpen'

        # A second close is harmless: cleanup paths may run more than once.
        (RecoveryLogging\Close-RecoveryLog -Writer $created.Writer).Success | Should -BeTrue
    }

    It 'reports a refused close instead of claiming success' {
        $logPath = Join-Path -Path $TestDrive -ChildPath 'close-refused.jsonl'
        $provider = @{
            Name = 'CloseRefusalFixture'
            Open = { param($request) return [pscustomobject]@{ Success = $true; FixtureHandle = 'fixture' } }
            Append = { param($request) return $true }
            Flush = { param($request) return $true }
            Close = { param($request) return [pscustomobject]@{ Success = $false; ReasonCode = 'LogCloseFailed'; Message = 'fixture close refusal' } }
        }
        $created = RecoveryLogging\New-RecoveryLog -Path $logPath -JobId 'CLOSE-REGRESSION-2' -Writer $provider
        $created.Success | Should -BeTrue

        $closed = RecoveryLogging\Close-RecoveryLog -Writer $created.Writer
        $closed.Success | Should -BeFalse
        $closed.ReasonCode | Should -Be 'LogCloseFailed'
        $created.Writer.IsOpen | Should -BeTrue
    }
}

Describe 'Destination safety fail-closed inputs' {
    BeforeAll {
        Import-Module -Name (Join-Path -Path $script:RepoRoot -ChildPath 'modules/DiskDetection.psm1') -Force -ErrorAction Stop
        $script:SeparateDiskProvider = @{
            ResolvePath = {
                param($request)
                return [pscustomobject]@{
                    CanonicalPath = [string]$request.Path
                    Exists = $true
                    IsContainer = $true
                    IsReparsePoint = $false
                    VolumeGuid = 'DESTINATION-VOLUME'
                    PhysicalDiskNumbers = @(2)
                    MembersIncomplete = $false
                }
            }.GetNewClosure()
            GetDisks = {
                param($request)
                return [pscustomobject]@{
                    DiskNumber = [int]$request.DiskNumber
                    UniqueId = 'DESTINATION-DISK'
                    UniqueIdFormat = 'NAA'
                    SerialNumber = 'DESTINATION-SERIAL'
                    SizeBytes = 1
                    Model = 'Destination'
                    MembersIncomplete = $false
                    IsDynamic = $false
                }
            }.GetNewClosure()
        }
    }

    It 'refuses a source identity that does not positively state its resolution' {
        $source = [pscustomobject]@{
            IsIndeterminate = $false
            VolumeGuid      = 'SOURCE-VOLUME'
            IdentityKeys    = @('UID|WWN|SOURCE-DISK')
            PhysicalDisks   = @([pscustomobject]@{
                    IdentityKey    = 'UID|WWN|SOURCE-DISK'
                    UniqueId       = 'SOURCE-DISK'
                    UniqueIdFormat = 'NAA'
                    SerialNumber   = 'SOURCE-SERIAL'
                    SizeBytes      = 1
                    Model          = 'Source'
                })
        }

        $decision = Test-DestinationSafety -SourceIdentity $source -DestinationPath 'D:\out' -Provider $script:SeparateDiskProvider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'SourceIndeterminate'
    }

    It 'does not read non-Boolean provider flags as an existing container' {
        $provider = @{
            ResolvePath = {
                param($request)
                return [pscustomobject]@{
                    CanonicalPath        = [string]$request.Path
                    Exists               = 'false'
                    IsContainer          = 'false'
                    IsReparsePoint       = $false
                    VolumeGuid           = 'VOLUME-1'
                    PhysicalDiskNumbers  = @(1)
                    MembersIncomplete    = $false
                }
            }.GetNewClosure()
            GetDisks = {
                param($request)
                return [pscustomobject]@{
                    DiskNumber        = [int]$request.DiskNumber
                    UniqueId          = 'DISK-1'
                    UniqueIdFormat    = 'NAA'
                    SerialNumber      = 'SERIAL-1'
                    SizeBytes         = 1
                    Model             = 'Fixture'
                    MembersIncomplete = $false
                    IsDynamic         = $false
                }
            }.GetNewClosure()
        }

        $identity = Resolve-RecoveryPathIdentity -Path 'D:\out' -Provider $provider

        $identity.Resolved | Should -BeFalse
        $identity.Exists | Should -BeFalse
        $identity.IsContainer | Should -BeFalse
        $identity.ReasonCode | Should -Be 'PathMissing'
    }
}
