Set-StrictMode -Version 3.0

$uiModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'UIAutomation.psm1'
Import-Module -Name $uiModulePath -ErrorAction Stop

function Get-FsProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]::Equals([string]$key, $name, [StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
        }
        else {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property) {
                return $property.Value
            }
        }
    }

    return $null
}

function Get-FsValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Sources,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($source in @($Sources)) {
        if ($null -eq $source) {
            continue
        }

        foreach ($name in $Names) {
            if ($source -is [System.Collections.IDictionary]) {
                foreach ($key in $source.Keys) {
                    if ([string]::Equals([string]$key, $name, [StringComparison]::OrdinalIgnoreCase)) {
                        return [pscustomobject]@{ Found = $true; Value = $source[$key] }
                    }
                }
            }
            else {
                $property = $source.PSObject.Properties[$name]
                if ($null -ne $property) {
                    return [pscustomobject]@{ Found = $true; Value = $property.Value }
                }
            }
        }
    }

    return [pscustomobject]@{ Found = $false; Value = $null }
}

function Test-FsBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $parsed = $false
    if ([bool]::TryParse(([string]$Value), [ref]$parsed)) {
        return $parsed
    }

    return $false
}

function Get-FsBooleanEvidence {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    # Tri-state read of one safety indicator. 'True' and 'False' are explicit
    # decisions; 'Unproven' means the value is present but cannot be read as a
    # boolean at all, so a caller must treat it as unverified evidence rather
    # than as an inactive flag.
    if ($null -eq $Value) {
        return 'Unproven'
    }
    if ($Value -is [bool]) {
        if ($Value) {
            return 'True'
        }
        return 'False'
    }

    $parsed = $false
    if ([bool]::TryParse((([string]$Value)).Trim(), [ref]$parsed)) {
        if ($parsed) {
            return 'True'
        }
        return 'False'
    }

    $number = 0
    if ([int]::TryParse((([string]$Value)).Trim(), [ref]$number)) {
        if ($number -eq 0) {
            return 'False'
        }
        return 'True'
    }

    return 'Unproven'
}

function Get-FsStateName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$State
    )

    if ($null -eq $State) {
        return $null
    }
    if ($State -is [string]) {
        return ([string]$State).ToUpperInvariant()
    }

    $stateName = Get-FsProperty -InputObject $State -Names @('CurrentState', 'WorkflowState', 'StateName', 'State')
    if ($stateName -is [string]) {
        return ([string]$stateName).ToUpperInvariant()
    }

    return $null
}

function New-FsResult {
    [CmdletBinding()]
    param(
        [bool]$Allowed,
        [string]$Result,
        [string]$ReasonCode,
        [string]$Reason,
        [object]$Error,
        [object]$Evidence
    )

    return [pscustomobject]@{
        Allowed = $Allowed
        Result = $Result
        ReasonCode = $ReasonCode
        Reason = $Reason
        Error = $Error
        Evidence = $Evidence
    }
}

function New-FsManualGateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GateId,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [object]$Evidence,

        [Parameter(Mandatory = $true)]
        [object[]]$Choices,

        [Parameter(Mandatory = $true)]
        [string]$SafeDefault,

        [string]$Stage
    )

    $gate = New-RecoveryManualGate -GateId $GateId -Reason $Reason -Evidence $Evidence -Choices $Choices -SafeDefault $SafeDefault
    return [pscustomobject]@{
        Allowed = $false
        Result = 'ManualGate'
        ReasonCode = $GateId
        Reason = $Reason
        Stage = $Stage
        RequiresOperator = $true
        ManualGate = $gate
        Gate = $gate
        Error = $null
        Evidence = $Evidence
    }
}

function Test-FsVerifiedExecutable {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Executable
    )

    if ($null -eq $Executable) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ExecutableMissing'; Reason = 'A verified File Scavenger executable identity is required.' }
    }

    $path = Get-FsProperty -InputObject $Executable -Names @('Path', 'ExecutablePath')
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ExecutablePathMissing'; Reason = 'The verified executable path is missing.' }
    }

    $product = Get-FsProperty -InputObject $Executable -Names @('Product', 'ProductName')
    if (-not [string]::Equals([string]$product, 'File Scavenger', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ExecutableProductMismatch'; Reason = 'The executable identity is not File Scavenger.' }
    }

    $identityStatus = Get-FsProperty -InputObject $Executable -Names @('IdentityStatus')
    $identityVerified = Test-FsBoolean (Get-FsProperty -InputObject $Executable -Names @('IdentityVerified', 'Verified'))
    if (-not [string]::Equals([string]$identityStatus, 'Verified', [StringComparison]::OrdinalIgnoreCase) -and -not $identityVerified) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ExecutableUnverified'; Reason = 'The executable identity has not been verified.' }
    }

    $version = Get-FsProperty -InputObject $Executable -Names @('ProductVersion', 'FileVersion', 'Version')
    if ([string]::IsNullOrWhiteSpace([string]$version)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ExecutableVersionMissing'; Reason = 'The verified executable version is missing.' }
    }

    $evidenceSource = Get-FsProperty -InputObject $Executable -Names @('EvidenceSource', 'EvidenceReference', 'IdentityEvidence')
    if ([string]::IsNullOrWhiteSpace([string]$evidenceSource)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ExecutableEvidenceMissing'; Reason = 'The executable identity evidence source is missing.' }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Test-FsLaunchPreconditions {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$State,

        [AllowNull()]
        [object]$Preconditions
    )

    $stateName = Get-FsStateName -State $State
    if (-not [string]::Equals($stateName, 'CASE_READY', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'StateNotCaseReady'; Reason = 'File Scavenger can launch only from CASE_READY.' }
    }

    $statePreconditions = Get-FsProperty -InputObject $State -Names @('Preconditions', 'Preflight', 'FreshChecks')
    $sources = @($Preconditions, $statePreconditions, $State)
    $required = @(
        @('LogFlushed', 'LogDurable', 'InitialLogFlushed'),
        @('LockOwned', 'JobLockOwned'),
        @('ElevationPassed', 'IsElevated', 'Elevated'),
        @('FreshSafetyCheckPassed', 'FreshDiskCheckPassed', 'FreshIdentityCheckPassed', 'SourceDestinationCheckFresh', 'FreshChecksPassed')
    )
    $labels = @('log flush', 'job lock', 'elevation', 'fresh source/destination check')

    for ($index = 0; $index -lt $required.Count; $index++) {
        $value = Get-FsValue -Sources $sources -Names $required[$index]
        if (-not $value.Found) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'LaunchPreconditionMissing'; Reason = ('Required {0} evidence is missing.' -f $labels[$index]) }
        }
        if (-not (Test-FsBoolean $value.Value)) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'LaunchPreconditionFailed'; Reason = ('Required {0} evidence did not pass.' -f $labels[$index]) }
        }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Invoke-FsDefaultProcessRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Path
    $startInfo.Arguments = ''
    $startInfo.UseShellExecute = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'The verified File Scavenger process did not start.'
    }

    return [pscustomobject]@{
        Path = $Path
        Pid = $process.Id
        StartTime = $process.StartTime
        Handle = $null
        Process = $process
        Arguments = @()
    }
}

function Get-FsProcessIdentityFromResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$RunnerResult,

        [Parameter(Mandatory = $true)]
        [object]$Executable,

        [AllowNull()]
        [object]$State
    )

    $nested = Get-FsProperty -InputObject $RunnerResult -Names @('ProcessIdentity')
    if ($null -ne $nested) {
        $RunnerResult = $nested
    }

    $path = Get-FsProperty -InputObject $RunnerResult -Names @('Path', 'ProcessPath', 'ExecutablePath')
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        $path = Get-FsProperty -InputObject $Executable -Names @('Path', 'ExecutablePath')
    }

    $pidValue = Get-FsProperty -InputObject $RunnerResult -Names @('Pid', 'PID', 'Id', 'ProcessId')
    $pidNumber = 0
    if ($null -eq $pidValue -or -not [int]::TryParse(([string]$pidValue), [ref]$pidNumber) -or $pidNumber -le 0) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessIdentityMissing'; Reason = 'The process runner did not return a valid process ID.' }
    }

    $startTime = Get-FsProperty -InputObject $RunnerResult -Names @('StartTime', 'ProcessStartTime')
    if ($null -eq $startTime -or [string]::IsNullOrWhiteSpace([string]$startTime)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessStartTimeMissing'; Reason = 'The process runner did not return a process start time.' }
    }

    $jobId = Get-FsProperty -InputObject $State -Names @('JobId', 'JobIdentity')
    return [pscustomobject]@{
        Valid = $true
        Identity = [pscustomobject]@{
            Path = [string]$path
            Pid = $pidNumber
            StartTime = $startTime
            Handle = Get-FsProperty -InputObject $RunnerResult -Names @('Handle', 'ProcessHandle')
            JobId = $jobId
            Product = 'File Scavenger'
            IdentityStatus = 'Verified'
        }
        ReasonCode = $null
        Reason = $null
    }
}

function Get-FsWriterResultDecision {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    $undecided = [pscustomobject]@{ Decided = $false; Success = $false; Blocked = $false; Reason = 'The event writer did not report an explicit durability result.' }

    if ($null -eq $Value) {
        return $undecided
    }
    if ($Value -is [bool]) {
        return [pscustomobject]@{ Decided = $true; Success = [bool]$Value; Blocked = $false; Reason = $null }
    }
    if ($Value -is [string] -or $Value -is [char]) {
        $parsed = $false
        if ([bool]::TryParse((([string]$Value)).Trim(), [ref]$parsed)) {
            return [pscustomobject]@{ Decided = $true; Success = $parsed; Blocked = $false; Reason = $null }
        }
        return $undecided
    }

    # Every accepted success field and every nested provider result must agree
    # before the event counts as durable. A structured refusal (nested Data,
    # Result, or IsBlocked) is a refusal, never a silent success.
    $containers = New-Object System.Collections.ArrayList
    [void]$containers.Add($Value)
    foreach ($name in @('Data', 'Result', 'Write', 'Append', 'Flush', 'Event', 'Entry', 'Provider')) {
        $nested = Get-FsProperty -InputObject $Value -Names @($name)
        if ($null -ne $nested -and $nested -isnot [string] -and $nested -isnot [bool]) {
            [void]$containers.Add($nested)
        }
    }

    $decisions = New-Object System.Collections.ArrayList
    $blocked = $false
    $blockedReason = $null
    foreach ($container in $containers) {
        foreach ($name in @('Success', 'Succeeded', 'IsSuccess', 'Ok', 'Written', 'Accepted')) {
            $fieldValue = Get-FsProperty -InputObject $container -Names @($name)
            if ($null -ne $fieldValue) {
                [void]$decisions.Add((Test-FsBoolean $fieldValue))
            }
        }
        foreach ($name in @('IsBlocked', 'Blocked', 'IsFailed', 'Failed')) {
            $fieldValue = Get-FsProperty -InputObject $container -Names @($name)
            if ($null -ne $fieldValue -and (Test-FsBoolean $fieldValue)) {
                $blocked = $true
                $blockedReason = ('The event writer reported the {0} field as set.' -f $name)
            }
        }
    }

    if ($blocked) {
        return [pscustomobject]@{ Decided = $true; Success = $false; Blocked = $true; Reason = $blockedReason }
    }
    if ($decisions.Count -eq 0) {
        return $undecided
    }

    $success = $true
    foreach ($decision in $decisions) {
        if (-not $decision) {
            $success = $false
        }
    }
    if (-not $success) {
        return [pscustomobject]@{ Decided = $true; Success = $false; Blocked = $false; Reason = 'The event writer reported that the event was not durably recorded.' }
    }

    return [pscustomobject]@{ Decided = $true; Success = $true; Blocked = $false; Reason = $null }
}

function Write-FsDurableEvent {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [scriptblock]$EventWriter,

        [Parameter(Mandatory = $true)]
        [object]$Event
    )

    if ($null -eq $EventWriter) {
        return [pscustomobject]@{
            Attempted = $false
            Succeeded = $false
            ReasonCode = 'EventWriterRequired'
            Reason = 'A durable event writer is required before any external action can be authorized.'
            Error = $null
            Decision = $null
        }
    }

    try {
        $output = @($EventWriter.Invoke($Event))
    }
    catch {
        return [pscustomobject]@{
            Attempted = $true
            Succeeded = $false
            ReasonCode = 'EventWriteFailed'
            Reason = 'The durable event writer failed while recording the event.'
            Error = $_.Exception.Message
            Decision = $null
        }
    }

    if ($output.Count -eq 0) {
        return [pscustomobject]@{
            Attempted = $true
            Succeeded = $false
            ReasonCode = 'EventWriterResultMissing'
            Reason = 'The event writer returned no durability result.'
            Error = $null
            Decision = $null
        }
    }
    if ($output.Count -ne 1) {
        return [pscustomobject]@{
            Attempted = $true
            Succeeded = $false
            ReasonCode = 'EventWriterResultAmbiguous'
            Reason = 'The event writer did not return exactly one durability result.'
            Error = $null
            Decision = $null
        }
    }

    $decision = Get-FsWriterResultDecision -Value $output[0]
    if (-not $decision.Decided) {
        return [pscustomobject]@{
            Attempted = $true
            Succeeded = $false
            ReasonCode = 'EventWriterResultAmbiguous'
            Reason = $decision.Reason
            Error = $null
            Decision = $decision
        }
    }
    if (-not $decision.Success) {
        $reasonCode = 'EventWriteRefused'
        if ($decision.Blocked) {
            $reasonCode = 'EventWriteBlocked'
        }
        return [pscustomobject]@{
            Attempted = $true
            Succeeded = $false
            ReasonCode = $reasonCode
            Reason = $decision.Reason
            Error = $decision.Reason
            Decision = $decision
        }
    }

    return [pscustomobject]@{
        Attempted = $true
        Succeeded = $true
        ReasonCode = $null
        Reason = $null
        Error = $null
        Decision = $decision
    }
}

function Start-FileScavenger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Executable,

        [AllowNull()]
        [object]$State,

        [AllowNull()]
        [object]$Preconditions,

        [AllowNull()]
        [scriptblock]$ProcessRunner,

        [AllowNull()]
        [scriptblock]$EventWriter
    )

    $identityCheck = Test-FsVerifiedExecutable -Executable $Executable
    if (-not $identityCheck.Valid) {
        $failure = New-FsResult -Allowed $false -Result 'Blocked' -ReasonCode $identityCheck.ReasonCode -Reason $identityCheck.Reason -Error $null -Evidence $Executable
        $failure | Add-Member -NotePropertyName Started -NotePropertyValue $false
        $failure | Add-Member -NotePropertyName Arguments -NotePropertyValue @()
        return $failure
    }

    $preconditionCheck = Test-FsLaunchPreconditions -State $State -Preconditions $Preconditions
    if (-not $preconditionCheck.Valid) {
        $failure = New-FsResult -Allowed $false -Result 'Blocked' -ReasonCode $preconditionCheck.ReasonCode -Reason $preconditionCheck.Reason -Error $null -Evidence $State
        $failure | Add-Member -NotePropertyName Started -NotePropertyValue $false
        $failure | Add-Member -NotePropertyName Arguments -NotePropertyValue @()
        return $failure
    }

    $executablePath = [string](Get-FsProperty -InputObject $Executable -Names @('Path', 'ExecutablePath'))
    if ($null -eq $ProcessRunner) {
        $ProcessRunner = ${function:Invoke-FsDefaultProcessRunner}
    }

    # A durable log writer requires JobId, EventType, State, and Result on every
    # event. The launch may only be authorized from CASE_READY (already proven by
    # Test-FsLaunchPreconditions), so that is the state these events record until
    # the caller advances the workflow after the launch event is durable.
    $acknowledgedStateName = Get-FsStateName -State $State
    if ([string]::IsNullOrWhiteSpace([string]$acknowledgedStateName)) {
        $acknowledgedStateName = 'CASE_READY'
    }
    $acknowledgedAttemptId = Get-FsProperty -InputObject $State -Names @('AttemptId', 'Attempt', 'StageAttemptId')

    # The launch authorization event is written and flushed before the process
    # runner is called. Without a durable record of the authorized launch the
    # launcher refuses to start the vendor process at all.
    $authorizationEvent = [pscustomobject]@{
        EventType = 'StageStarted'
        Stage = 'LAUNCH'
        State = $acknowledgedStateName
        AttemptId = $acknowledgedAttemptId
        Result = 'LaunchAuthorized'
        ExecutablePath = $executablePath
    }
    $authorizationWrite = Write-FsDurableEvent -EventWriter $EventWriter -Event $authorizationEvent
    if (-not $authorizationWrite.Succeeded) {
        $authorizationReasonCode = 'LaunchAuthorizationNotDurable'
        $authorizationReason = 'The launch authorization event could not be durably recorded, so File Scavenger was not started.'
        if ($authorizationWrite.ReasonCode -eq 'EventWriterRequired') {
            $authorizationReasonCode = 'EventWriterRequired'
            $authorizationReason = $authorizationWrite.Reason
        }
        $failure = New-FsResult -Allowed $false -Result 'Blocked' -ReasonCode $authorizationReasonCode -Reason $authorizationReason `
            -Error ([pscustomobject]@{ Type = $authorizationWrite.ReasonCode; Message = $authorizationWrite.Error }) -Evidence $authorizationEvent
        $failure | Add-Member -NotePropertyName Started -NotePropertyValue $false
        $failure | Add-Member -NotePropertyName Arguments -NotePropertyValue @()
        $failure | Add-Member -NotePropertyName AuthorizationEvent -NotePropertyValue $authorizationWrite
        return $failure
    }

    try {
        $runnerOutput = @($ProcessRunner.Invoke($executablePath))
    }
    catch {
        $eventResult = Write-FsDurableEvent -EventWriter $EventWriter -Event ([pscustomobject]@{ EventType = 'StageFailed'; Stage = 'LAUNCH'; Result = 'Failed'; Error = $_.Exception.Message })
        return [pscustomobject]@{
            Allowed = $false
            Started = $false
            Result = 'Failed'
            ReasonCode = 'LaunchFailed'
            Reason = $_.Exception.Message
            Error = [pscustomobject]@{ Type = $_.Exception.GetType().FullName; Message = $_.Exception.Message; LogWrite = $eventResult }
            Arguments = @()
            AuthorizationEvent = $authorizationWrite
        }
    }

    if ($runnerOutput.Count -eq 0) {
        return [pscustomobject]@{
            Allowed = $false
            Started = $false
            Result = 'Failed'
            ReasonCode = 'LaunchFailed'
            Reason = 'The process runner returned no process identity.'
            Error = [pscustomobject]@{ Type = 'ProcessIdentityMissing'; Message = 'No process identity was returned.' }
            Arguments = @()
        }
    }
    if ($runnerOutput.Count -ne 1) {
        return [pscustomobject]@{
            Allowed = $false
            Started = $false
            Result = 'Failed'
            ReasonCode = 'AmbiguousProcessIdentity'
            Reason = 'The process runner returned more than one process identity.'
            Error = [pscustomobject]@{ Type = 'AmbiguousProcessIdentity'; Message = 'Multiple process identities were returned.' }
            Arguments = @()
        }
    }

    $runnerResult = $runnerOutput[0]
    $reportedArguments = Get-FsProperty -InputObject $runnerResult -Names @('Arguments', 'ArgumentList', 'ScannerArguments')
    if ($null -ne $reportedArguments) {
        $reported = @($reportedArguments)
        if ($reported.Count -gt 0 -and -not ([string]::IsNullOrWhiteSpace([string]$reported[0]) -and $reported.Count -eq 1)) {
            return [pscustomobject]@{
                Allowed = $false
                Started = $false
                Result = 'Failed'
                ReasonCode = 'UnexpectedLaunchArguments'
                Reason = 'The process runner reported scanner arguments; launch is refused.'
                Error = [pscustomobject]@{ Type = 'UnexpectedLaunchArguments'; Message = 'Only the verified executable path may be passed.' }
                Arguments = @()
            }
        }
    }

    $processIdentity = Get-FsProcessIdentityFromResult -RunnerResult $runnerResult -Executable $Executable -State $State
    if (-not $processIdentity.Valid) {
        return [pscustomobject]@{
            Allowed = $false
            Started = $false
            Result = 'Failed'
            ReasonCode = $processIdentity.ReasonCode
            Reason = $processIdentity.Reason
            Error = [pscustomobject]@{ Type = $processIdentity.ReasonCode; Message = $processIdentity.Reason }
            Arguments = @()
        }
    }

    $candidatePath = [string](Get-FsProperty -InputObject $Executable -Names @('Path', 'ExecutablePath'))
    if (-not [string]::Equals($processIdentity.Identity.Path, $candidatePath, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Allowed = $false
            Started = $false
            Result = 'Failed'
            ReasonCode = 'ProcessPathMismatch'
            Reason = 'The started process path does not match the verified executable path.'
            Error = [pscustomobject]@{ Type = 'ProcessPathMismatch'; Message = 'A different process identity was returned.' }
            Arguments = @()
        }
    }

    $eventResult = Write-FsDurableEvent -EventWriter $EventWriter -Event ([pscustomobject]@{
            EventType = 'StageStarted'
            Stage = 'LAUNCH'
            State = $acknowledgedStateName
            AttemptId = $acknowledgedAttemptId
            Result = 'Launched'
            ProcessIdentity = $processIdentity.Identity
        })
    if (-not $eventResult.Succeeded) {
        # The vendor process is already running, so this is never a clean launch
        # failure: the identity is retained, the interrupted-unknown event is
        # attempted, and the outcome fails closed for operator review.
        $unknownEvent = [pscustomobject]@{
            EventType = 'StageInterruptedUnknown'
            Stage = 'LAUNCH'
            State = $acknowledgedStateName
            AttemptId = $acknowledgedAttemptId
            Result = 'InterruptedUnknown'
            ProcessIdentity = $processIdentity.Identity
            Error = $eventResult.ReasonCode
        }
        $unknownWrite = Write-FsDurableEvent -EventWriter $EventWriter -Event $unknownEvent
        return [pscustomobject]@{
            Allowed = $false
            Started = $true
            Result = 'InterruptedUnknown'
            ReasonCode = 'LaunchEventNotDurable'
            Reason = 'The launched File Scavenger process could not be recorded durably; the attempt is interrupted-unknown and requires review.'
            Error = [pscustomobject]@{ Type = 'LaunchEventNotDurable'; Message = $eventResult.Error; LogWrite = $eventResult }
            Arguments = @()
            Executable = $Executable
            ProcessIdentity = $processIdentity.Identity
            AuthorizationEvent = $authorizationWrite
            LaunchEvent = $eventResult
            UnknownEvent = $unknownWrite
            RequiresOperator = $true
            NeedsReview = $true
            SuggestedState = 'INTERRUPTED_UNKNOWN'
            ManualGate = $null
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Started = $true
        Result = 'Launched'
        ReasonCode = $null
        Reason = $null
        Error = $null
        Executable = $Executable
        ProcessIdentity = $processIdentity.Identity
        Arguments = @()
        RequiresOperator = $true
        ManualGate = $null
        AuthorizationEvent = $authorizationWrite
        LaunchEvent = $eventResult
        EventWriter = $eventResult
    }
}

function Get-FileScavengerObservation {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ProcessIdentity,

        [AllowNull()]
        [scriptblock]$AppStateProvider,

        [AllowNull()]
        [scriptblock]$OutputProvider
    )

    if ($null -eq $ProcessIdentity) {
        $ProcessIdentity = [pscustomobject]@{ Path = $null; Pid = $null; StartTime = $null }
    }
    $processIdentity = $ProcessIdentity
    $appState = Get-RecoveryAppState -ProcessIdentity $processIdentity -UiProvider $AppStateProvider
    $baseUnknown = [bool]$appState.Unknown
    $outputUnknown = $false
    $outputError = $null
    $rawOutput = $null

    if ($null -eq $OutputProvider) {
        $outputUnknown = $true
    }
    else {
        try {
            $outputResult = @($OutputProvider.Invoke())
            if ($outputResult.Count -eq 1) {
                $rawOutput = $outputResult[0]
            }
            elseif ($outputResult.Count -eq 0) {
                $outputUnknown = $true
            }
            else {
                $outputUnknown = $true
                $outputError = 'The output provider returned more than one observation.'
            }
        }
        catch {
            $outputUnknown = $true
            $outputError = $_.Exception.Message
        }
    }

    $artifacts = Get-FsProperty -InputObject $rawOutput -Names @('ObservedArtifacts', 'Artifacts', 'OutputInventory', 'Inventory')
    $outputObservedValue = Get-FsProperty -InputObject $rawOutput -Names @('OutputObserved', 'InventoryObserved', 'OutputEvidenceObserved')
    $outputObserved = Test-FsBoolean $outputObservedValue
    if ($null -ne $artifacts -and @($artifacts).Count -gt 0) {
        $outputObserved = $true
    }

    $recoveryLog = Get-FsProperty -InputObject $rawOutput -Names @('RecoveryLog', 'RecoveryLogEvidence')
    $sessionFiles = Get-FsProperty -InputObject $rawOutput -Names @('SessionFiles', 'FssFiles')
    $csvFiles = Get-FsProperty -InputObject $rawOutput -Names @('CsvFiles', 'CsvEvidence')
    $journal = Get-FsProperty -InputObject $rawOutput -Names @('Journal', 'JournalEvidence')
    $outputRoot = Get-FsProperty -InputObject $rawOutput -Names @('OutputRoot', 'SaveTo')

    $observationUnknown = $baseUnknown -or $outputUnknown
    $reasonCode = $null
    if ($null -ne $outputError) {
        $reasonCode = 'OutputObservationFailed'
    }
    elseif ($observationUnknown) {
        $reasonCode = 'ApplicationObservationUnknown'
    }

    return [pscustomobject]@{
        ProcessIdentity = $appState.ProcessIdentity
        ApplicationState = $appState
        WindowPresent = $appState.WindowPresent
        Ready = $appState.Ready
        Controls = $appState.Controls
        LocalizedControls = $appState.LocalizedControls
        StatusLabels = $appState.StatusLabels
        Status = $appState.Status
        Messages = $appState.Messages
        ObservedArtifacts = @($artifacts)
        OutputObserved = $outputObserved
        OutputRoot = $outputRoot
        RecoveryLog = $recoveryLog
        SessionFiles = @($sessionFiles)
        CsvFiles = @($csvFiles)
        Journal = $journal
        ProcessExited = Test-FsBoolean (Get-FsProperty -InputObject $appState -Names @('ProcessExited', 'Exited'))
        ProcessAlive = Test-FsBoolean (Get-FsProperty -InputObject $appState -Names @('ProcessAlive', 'IsRunning'))
        WindowTitle = Get-FsProperty -InputObject $appState -Names @('WindowTitle', 'Title')
        Unknown = $observationUnknown
        Confidence = if ($observationUnknown) { 'Unknown' } else { 'EvidenceCollected' }
        ReasonCode = $reasonCode
        Error = $outputError
    }
}

function Get-FsStageDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage
    )

    $normalized = $Stage.ToUpperInvariant()
    switch ($normalized) {
        'SHORT_SCAN' {
            return [pscustomobject]@{ Stage = $normalized; VendorStage = 'Quick scan'; Action = 'Scan'; ExpectedCompletion = 'ScanFinished' }
        }
        'SHORT_RECOVERY' {
            return [pscustomobject]@{ Stage = $normalized; VendorStage = 'Step 2: Save'; Action = 'Save'; ExpectedCompletion = 'RecoveryFinished' }
        }
        'LONG_SCAN' {
            return [pscustomobject]@{ Stage = $normalized; VendorStage = 'Long scan'; Action = 'Scan'; ExpectedCompletion = 'ScanFinished' }
        }
        'LONG_RECOVERY' {
            return [pscustomobject]@{ Stage = $normalized; VendorStage = 'Step 2: Save'; Action = 'Save'; ExpectedCompletion = 'RecoveryFinished' }
        }
        default {
            return $null
        }
    }
}

function Test-FsStageOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [AllowNull()]
        [object]$State
    )

    if ($null -eq $State) {
        return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
    }

    $stateName = Get-FsStateName -State $State
    $expected = $null
    switch ($Stage.ToUpperInvariant()) {
        'SHORT_SCAN' { $expected = @('CASE_READY') }
        'SHORT_RECOVERY' { $expected = @('SHORT_SCAN_FINISHED') }
        'LONG_SCAN' { $expected = @('SHORT_RECOVERY_VERIFIED') }
        'LONG_RECOVERY' { $expected = @('LONG_SCAN_FINISHED') }
    }

    if ($null -eq $expected -or $expected -notcontains $stateName) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'StageOrderViolation'; Reason = ('Stage {0} is not allowed from state {1}.' -f $Stage, $stateName) }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Test-FsUiDescriptor {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Descriptor
    )

    if ($null -eq $Descriptor) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ControlDescriptorMissing'; Reason = 'The exact-build control descriptor is missing.' }
    }

    foreach ($name in @('X', 'Y', 'Left', 'Top', 'Right', 'Bottom', 'ScreenX', 'ScreenY', 'Coordinates', 'BoundingRectangle', 'Keys', 'KeySequence', 'SendKeys', 'RawKeys', 'Keystrokes', 'Expression', 'SelectorScript', 'ScriptBlock', 'Command')) {
        $value = Get-FsProperty -InputObject $Descriptor -Names @($name)
        if ($null -ne $value) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'UnsupportedUiStrategy'; Reason = ('The descriptor contains the prohibited UI field {0}.' -f $name) }
        }
    }

    if (Test-FsBoolean (Get-FsProperty -InputObject $Descriptor -Names @('Ambiguous'))) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'AmbiguousControl'; Reason = 'The control descriptor is ambiguous.' }
    }

    $matchCount = Get-FsProperty -InputObject $Descriptor -Names @('MatchCount', 'ControlCount', 'MatchesFound')
    if ($null -ne $matchCount) {
        $matchNumber = 0
        if (-not [int]::TryParse(([string]$matchCount), [ref]$matchNumber) -or $matchNumber -ne 1) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'AmbiguousControl'; Reason = 'The descriptor does not resolve exactly one control.' }
        }
    }

    if (-not (Test-FsBoolean (Get-FsProperty -InputObject $Descriptor -Names @('Validated', 'OwnerValidated', 'EvidenceValidated')))) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceRequired'; Reason = 'The control is not owner-validated.' }
    }
    if (-not (Test-FsBoolean (Get-FsProperty -InputObject $Descriptor -Names @('ExactBuildMatch', 'BuildMatched', 'BuildMatch', 'ExactBuildValidated')))) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'BuildMismatch'; Reason = 'The control is not bound to the exact installed build.' }
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-FsProperty -InputObject $Descriptor -Names @('EvidenceSource', 'EvidenceReference', 'ValidationSource')))) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceRequired'; Reason = 'The control evidence source is missing.' }
    }

    $hasStableProperty = $false
    foreach ($name in @('AutomationId', 'Name', 'ControlType', 'Handle', 'NativeWindowHandle', 'RuntimeId', 'PropertyConditions')) {
        $value = Get-FsProperty -InputObject $Descriptor -Names @($name)
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            $hasStableProperty = $true
            break
        }
    }
    if (-not $hasStableProperty) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ControlDescriptorIncomplete'; Reason = 'The descriptor has no stable control property.' }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Get-FsMapRootCheck {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$EvidenceMap,

        [AllowNull()]
        [object]$Executable
    )

    if ($null -eq $EvidenceMap) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceRequired'; Reason = 'No exact-build evidence map was supplied.' }
    }

    $product = Get-FsProperty -InputObject $EvidenceMap -Names @('Product', 'ProductName')
    if (-not [string]::Equals([string]$product, 'File Scavenger', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceProductMismatch'; Reason = 'The evidence map is not for File Scavenger.' }
    }
    if (-not (Test-FsBoolean (Get-FsProperty -InputObject $EvidenceMap -Names @('OwnerValidated', 'Validated', 'EvidenceValidated')))) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceRequired'; Reason = 'The evidence map is not owner-validated.' }
    }

    $build = Get-FsProperty -InputObject $EvidenceMap -Names @('Build', 'ProductVersion', 'FileVersion', 'ExactBuild')
    if ($build -is [bool]) {
        $build = Get-FsProperty -InputObject $EvidenceMap -Names @('Build', 'ProductVersion', 'FileVersion', 'ValidatedBuild')
    }
    if ([string]::IsNullOrWhiteSpace([string]$build)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'BuildEvidenceMissing'; Reason = 'The exact installed build is missing from the evidence map.' }
    }

    if ($null -ne $Executable) {
        $executableVersion = Get-FsProperty -InputObject $Executable -Names @('ProductVersion', 'FileVersion', 'Version')
        if (-not [string]::Equals([string]$build, [string]$executableVersion, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'BuildMismatch'; Reason = 'The evidence map does not match the executable build.' }
        }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null; Build = [string]$build }
}

function Get-FsMapStageEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$EvidenceMap,

        [Parameter(Mandatory = $true)]
        [string]$Stage
    )

    $containers = @(
        (Get-FsProperty -InputObject $EvidenceMap -Names @('Stages', 'StageMap', 'Actions', 'Controls')),
        $EvidenceMap
    )
    foreach ($container in $containers) {
        if ($null -eq $container) {
            continue
        }
        $entry = Get-FsProperty -InputObject $container -Names @($Stage)
        if ($null -ne $entry) {
            return $entry
        }
    }
    return $null
}

function Get-FsMapCloseDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$EvidenceMap
    )

    $closeEntry = Get-FsProperty -InputObject $EvidenceMap -Names @('GracefulClose', 'Close', 'Exit', 'CloseAction')
    if ($null -eq $closeEntry) {
        $actions = Get-FsProperty -InputObject $EvidenceMap -Names @('Actions', 'Controls')
        $closeEntry = Get-FsProperty -InputObject $actions -Names @('GracefulClose', 'Close', 'Exit')
    }
    if ($null -eq $closeEntry) {
        return $null
    }

    $descriptor = Get-FsProperty -InputObject $closeEntry -Names @('ControlDescriptor', 'Descriptor', 'Control')
    if ($null -ne $descriptor) {
        return $descriptor
    }
    return $closeEntry
}

function Request-FileScavengerStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [AllowNull()]
        [object]$EvidenceMap,

        [AllowNull()]
        [object]$State,

        [AllowNull()]
        [object]$Executable
    )

    $definition = Get-FsStageDefinition -Stage $Stage
    if ($null -eq $definition) {
        return New-FsManualGateResult -GateId 'G-04' -Reason 'The requested File Scavenger stage is not recognized.' -Evidence ([pscustomobject]@{ Stage = $Stage }) -Choices @('Stop') -SafeDefault 'Stop' -Stage $Stage
    }

    $orderCheck = Test-FsStageOrder -Stage $definition.Stage -State $State
    if (-not $orderCheck.Valid) {
        return New-FsManualGateResult -GateId 'G-05' -Reason $orderCheck.Reason -Evidence ([pscustomobject]@{ Stage = $definition.Stage; State = Get-FsStateName -State $State }) -Choices @('Stop', 'Review stage order') -SafeDefault 'Stop' -Stage $definition.Stage
    }

    $rootCheck = Get-FsMapRootCheck -EvidenceMap $EvidenceMap -Executable $Executable
    if (-not $rootCheck.Valid) {
        return New-FsManualGateResult -GateId 'G-04' -Reason $rootCheck.Reason -Evidence ([pscustomobject]@{ Stage = $definition.Stage; ReasonCode = $rootCheck.ReasonCode; VendorStage = $definition.VendorStage }) -Choices @('Perform manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop' -Stage $definition.Stage
    }

    $entry = Get-FsMapStageEntry -EvidenceMap $EvidenceMap -Stage $definition.Stage
    if ($null -eq $entry) {
        return New-FsManualGateResult -GateId 'G-04' -Reason 'The exact-build evidence map has no entry for this stage.' -Evidence ([pscustomobject]@{ Stage = $definition.Stage; Build = $rootCheck.Build }) -Choices @('Perform manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop' -Stage $definition.Stage
    }

    $action = Get-FsProperty -InputObject $entry -Names @('Action', 'VendorAction')
    if (-not [string]::Equals([string]$action, $definition.Action, [StringComparison]::OrdinalIgnoreCase)) {
        return New-FsManualGateResult -GateId 'G-04' -Reason 'The stage action in the evidence map is missing or not the documented vendor action.' -Evidence ([pscustomobject]@{ Stage = $definition.Stage; ExpectedAction = $definition.Action; ObservedAction = $action }) -Choices @('Perform manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop' -Stage $definition.Stage
    }

    $descriptor = Get-FsProperty -InputObject $entry -Names @('ControlDescriptor', 'Descriptor', 'Control')
    $descriptorCheck = Test-FsUiDescriptor -Descriptor $descriptor
    if (-not $descriptorCheck.Valid) {
        return New-FsManualGateResult -GateId 'G-04' -Reason $descriptorCheck.Reason -Evidence ([pscustomobject]@{ Stage = $definition.Stage; ReasonCode = $descriptorCheck.ReasonCode }) -Choices @('Perform manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop' -Stage $definition.Stage
    }

    $completionEvidence = Get-FsProperty -InputObject $entry -Names @('ResultEvidence', 'CompletionEvidence', 'Evidence')
    if ($null -eq $completionEvidence) {
        return New-FsManualGateResult -GateId 'G-04' -Reason 'The stage action has no observed result/completion evidence contract.' -Evidence ([pscustomobject]@{ Stage = $definition.Stage; Action = $definition.Action }) -Choices @('Perform manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop' -Stage $definition.Stage
    }

    return [pscustomobject]@{
        Allowed = $true
        Result = 'ActionReady'
        ReasonCode = $null
        Reason = $null
        Stage = $definition.Stage
        VendorStage = $definition.VendorStage
        Action = $definition.Action
        ControlDescriptor = $descriptor
        CompletionEvidence = $completionEvidence
        Build = $rootCheck.Build
        RequiresOperator = $true
        ManualGate = $null
        Arguments = @()
    }
}

function Get-FsCompletionSignal {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $value = Get-FsProperty -InputObject $Observation -Names $Names
    if ($null -eq $value) {
        return $false
    }
    if ($value -is [bool]) {
        return [bool]$value
    }
    if ($value -is [string]) {
        return @('Finished', 'Complete', 'Completed', 'Done', 'Saved') -contains $value
    }

    $nested = Get-FsProperty -InputObject $value -Names @('Observed', 'Confirmed', 'Validated', 'Complete', 'Completed', 'Finished')
    return Test-FsBoolean $nested
}

function Get-FsOutputObserved {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation
    )

    $explicit = Get-FsProperty -InputObject $Observation -Names @('OutputObserved', 'OutputEvidenceObserved', 'InventoryObserved')
    if (Test-FsBoolean $explicit) {
        return $true
    }

    $evidence = Get-FsProperty -InputObject $Observation -Names @('OutputEvidence', 'OutputInventoryEvidence')
    if ($null -ne $evidence -and (Test-FsBoolean (Get-FsProperty -InputObject $evidence -Names @('Observed', 'Reviewed', 'Validated')))) {
        return $true
    }

    $artifacts = Get-FsProperty -InputObject $Observation -Names @('ObservedArtifacts', 'Artifacts', 'OutputInventory')
    if ($null -ne $artifacts -and @($artifacts).Count -gt 0) {
        return $true
    }

    return $false
}

function Test-FileScavengerCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Observation
    )

    $definition = Get-FsStageDefinition -Stage $Stage
    if ($null -eq $definition) {
        return [pscustomobject]@{ Allowed = $false; Completed = $false; Verified = $false; Result = 'Unknown'; Completion = 'Unknown'; Stage = $Stage; OutputObserved = $false; ReasonCode = 'InvalidStage'; Reason = 'The requested stage is not recognized.' }
    }

    $scanFinished = Get-FsCompletionSignal -Observation $Observation -Names @('ScanFinished', 'ScanCompleted', 'ScanCompletionConfirmed', 'ScanFinishedEvidence')
    $recoveryFinished = Get-FsCompletionSignal -Observation $Observation -Names @('RecoveryFinished', 'RecoveryCompleted', 'RecoveryCompletionConfirmed', 'RecoveryFinishedEvidence')
    $genericFinished = Get-FsCompletionSignal -Observation $Observation -Names @('Finished', 'Completed', 'Complete')
    $processExited = Test-FsBoolean (Get-FsProperty -InputObject $Observation -Names @('ProcessExited', 'Exited'))
    $windowPresent = Get-FsProperty -InputObject $Observation -Names @('WindowPresent', 'WindowExists')
    $progress = Get-FsProperty -InputObject $Observation -Names @('Progress', 'ProgressPercent')
    $outputObserved = Get-FsOutputObserved -Observation $Observation

    $expectedCompletion = $definition.ExpectedCompletion
    $completion = $false
    $result = 'Unknown'
    $reasonCode = 'CompletionEvidenceMissing'
    $reason = 'No exact named completion evidence was supplied.'

    if ($expectedCompletion -eq 'ScanFinished' -and $scanFinished) {
        $completion = $true
        $result = 'ScanFinished'
        $reasonCode = $null
        $reason = $null
    }
    elseif ($expectedCompletion -eq 'RecoveryFinished' -and $recoveryFinished) {
        $completion = $true
        $result = 'RecoveryFinished'
        $reasonCode = $null
        $reason = $null
    }
    elseif ($outputObserved) {
        $result = 'OutputObserved'
        $reasonCode = 'CompletionEvidenceMissing'
        $reason = 'Output was observed without the named vendor stage completion evidence.'
    }
    elseif ($processExited -or ($null -eq $windowPresent -or -not (Test-FsBoolean $windowPresent)) -or $null -ne $progress -or $genericFinished) {
        $reasonCode = 'CompletionEvidenceInsufficient'
        $reason = 'Process, window, progress, generic completion, or output-folder evidence alone cannot complete a stage.'
    }

    $verificationValue = Get-FsProperty -InputObject $Observation -Names @('OutputVerificationPassed', 'OutputVerified', 'StageVerified')
    $verified = $completion -and $definition.ExpectedCompletion -eq 'RecoveryFinished' -and $outputObserved -and (Test-FsBoolean $verificationValue)
    if ($verified) {
        $result = 'RecoveryVerified'
    }

    return [pscustomobject]@{
        Allowed = $completion
        Completed = $completion
        Verified = $verified
        Result = $result
        Completion = $result
        Stage = $definition.Stage
        VendorStage = $definition.VendorStage
        OutputObserved = $outputObserved
        ScanFinished = $scanFinished
        RecoveryFinished = $recoveryFinished
        ReasonCode = $reasonCode
        Reason = $reason
        Evidence = [pscustomobject]@{
            ProcessExited = $processExited
            WindowPresent = $windowPresent
            Progress = $progress
            GenericFinished = $genericFinished
        }
    }
}

function Get-FsObservationSources {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation
    )

    $sources = New-Object System.Collections.ArrayList
    if ($null -eq $Observation) {
        return $sources.ToArray()
    }
    [void]$sources.Add($Observation)
    foreach ($name in @('ApplicationState', 'NormalizedState', 'AppState', 'Application', 'State')) {
        $nested = Get-FsProperty -InputObject $Observation -Names @($name)
        if ($null -ne $nested -and $nested -isnot [string] -and $nested -isnot [bool]) {
            [void]$sources.Add($nested)
        }
    }
    return $sources.ToArray()
}

function Get-FsEvidenceDecision {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Sources,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    # OR semantics: every alias in every source is evaluated. A single true
    # indicator blocks the close, so a false first-match alias can never mask a
    # true sibling such as ScanRunning or RecoveryRunning. A value that is
    # present but cannot be read as a boolean is reported as unproven, which the
    # close guard also treats as blocking instead of reading it as inactive.
    $decision = [pscustomobject]@{
        True = $false
        Unproven = $false
        Name = $null
        Value = $null
    }

    foreach ($source in @($Sources)) {
        if ($null -eq $source) {
            continue
        }
        foreach ($name in $Names) {
            foreach ($value in @(Get-FsAllProperties -InputObject $source -Name $name)) {
                $evidence = Get-FsBooleanEvidence -Value $value
                if ($evidence -eq 'True') {
                    $decision.True = $true
                    $decision.Name = $name
                    $decision.Value = $value
                    return $decision
                }
                if ($evidence -eq 'Unproven' -and -not $decision.Unproven) {
                    $decision.Unproven = $true
                    $decision.Name = $name
                    $decision.Value = $value
                }
            }
        }
    }

    return $decision
}

function Get-FsAllProperties {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $values = New-Object System.Collections.ArrayList
    if ($null -eq $InputObject) {
        return $values.ToArray()
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$values.Add($InputObject[$key])
            }
        }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ([string]::Equals($property.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$values.Add($property.Value)
            }
        }
    }

    return $values.ToArray()
}

function Test-FsActiveOrUnknownObservation {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation
    )

    $sources = Get-FsObservationSources -Observation $Observation
    $activityNames = @(
        'ActiveWork', 'WorkActive', 'Active',
        'ScanRunning', 'IsScanning', 'ScanInProgress',
        'RecoveryRunning', 'IsRecovering', 'RecoveryInProgress',
        'Busy', 'IsBusy', 'WorkInProgress', 'InProgress'
    )
    $unknownNames = @('Unknown', 'IsUnknown', 'ObservationUnknown', 'UnknownState', 'StateUnknown', 'IsStateUnknown', 'EvidenceUnknown')
    $reasonCode = $null
    $reason = $null

    $activityDecision = Get-FsEvidenceDecision -Sources $sources -Names $activityNames
    if ($activityDecision.True) {
        $reasonCode = 'CloseStateUnknownOrActive'
        $reason = 'File Scavenger work is reported as active; graceful close is refused.'
    }
    elseif ($activityDecision.Unproven) {
        $reasonCode = 'CloseStateUnknownOrActive'
        $reason = ('The File Scavenger activity indicator {0} is present but cannot be read as a boolean; graceful close is refused.' -f $activityDecision.Name)
    }
    if ($null -eq $reasonCode) {
        $unknownDecision = Get-FsEvidenceDecision -Sources $sources -Names $unknownNames
        if ($unknownDecision.True) {
            $reasonCode = 'CloseStateUnknownOrActive'
            $reason = 'File Scavenger state is reported as unknown; graceful close is refused.'
        }
        elseif ($unknownDecision.Unproven) {
            $reasonCode = 'CloseStateUnknownOrActive'
            $reason = ('The File Scavenger state indicator {0} is present but cannot be read as a boolean; graceful close is refused.' -f $unknownDecision.Name)
        }
    }
    if ($null -eq $reasonCode) {
        foreach ($source in $sources) {
            $confidence = Get-FsProperty -InputObject $source -Names @('Confidence', 'EvidenceConfidence', 'StateConfidence')
            if (-not [string]::IsNullOrWhiteSpace([string]$confidence) -and [string]::Equals((([string]$confidence)).Trim(), 'Unknown', [StringComparison]::OrdinalIgnoreCase)) {
                $reasonCode = 'CloseStateUnknownOrActive'
                $reason = 'File Scavenger evidence confidence is unknown; graceful close is refused.'
                break
            }
        }
    }
    if ($null -eq $reasonCode) {
        foreach ($source in $sources) {
            $stateName = Get-FsStateName -State $source
            if ([string]::IsNullOrWhiteSpace([string]$stateName)) {
                continue
            }
            if ($stateName -eq 'INTERRUPTED_UNKNOWN' -or $stateName -eq 'FAILED_CLOSED') {
                $reasonCode = 'CloseStateUnknownOrActive'
                $reason = ('Workflow state {0} is unknown or failed-closed; graceful close is refused.' -f $stateName)
                break
            }
            if ($stateName.EndsWith('_RUNNING', [StringComparison]::Ordinal)) {
                $reasonCode = 'CloseStateUnknownOrActive'
                $reason = ('Workflow state {0} reports active work; graceful close is refused.' -f $stateName)
                break
            }
        }
    }

    return [pscustomobject]@{
        Blocked = ($null -ne $reasonCode)
        ReasonCode = $reasonCode
        Reason = $reason
    }
}

function Test-FsSafeCloseObservation {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation
    )

    $stateName = Get-FsStateName -State $Observation

    $activity = Test-FsActiveOrUnknownObservation -Observation $Observation
    if ($activity.Blocked) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = $activity.ReasonCode; Reason = $activity.Reason }
    }

    if ($stateName -eq 'SHORT_RECOVERY_VERIFIED' -or $stateName -eq 'LONG_RECOVERY_VERIFIED') {
        return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
    }
    if ($stateName -eq 'PAUSED' -and (Test-FsBoolean (Get-FsProperty -InputObject $Observation -Names @('PauseValidated', 'StopValidated', 'SafeStopValidated')))) {
        return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
    }

    $recoveryFinished = Get-FsCompletionSignal -Observation $Observation -Names @('RecoveryFinished', 'RecoveryCompleted', 'RecoveryCompletionConfirmed', 'RecoveryFinishedEvidence')
    $recoveryVerified = Test-FsBoolean (Get-FsProperty -InputObject $Observation -Names @('RecoveryVerified', 'OutputVerificationPassed', 'OutputVerified'))
    if ($recoveryFinished -and $recoveryVerified) {
        return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
    }

    return [pscustomobject]@{ Valid = $false; ReasonCode = 'RecoveryNotVerified'; Reason = 'A scan-finished observation is not sufficient for close; recovery must be verified.' }
}

function Request-FileScavengerGracefulClose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Observation,

        [AllowNull()]
        [object]$EvidenceMap,

        [AllowNull()]
        [scriptblock]$UiProvider
    )

    $safeCheck = Test-FsSafeCloseObservation -Observation $Observation
    if (-not $safeCheck.Valid) {
        return New-FsManualGateResult -GateId 'G-08' -Reason $safeCheck.Reason -Evidence ([pscustomobject]@{ ReasonCode = $safeCheck.ReasonCode; Observation = $Observation }) -Choices @('Leave active state untouched', 'Pause and review', 'Stop') -SafeDefault 'Leave active state untouched'
    }

    $mapCheck = Get-FsMapRootCheck -EvidenceMap $EvidenceMap -Executable $null
    if (-not $mapCheck.Valid) {
        return New-FsManualGateResult -GateId 'G-04' -Reason 'File > Exit is not reachable through an exact-build validated evidence map.' -Evidence ([pscustomobject]@{ ReasonCode = $mapCheck.ReasonCode }) -Choices @('Exit manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop'
    }

    $descriptor = Get-FsMapCloseDescriptor -EvidenceMap $EvidenceMap
    $descriptorCheck = Test-FsUiDescriptor -Descriptor $descriptor
    if (-not $descriptorCheck.Valid) {
        return New-FsManualGateResult -GateId 'G-04' -Reason $descriptorCheck.Reason -Evidence ([pscustomobject]@{ ReasonCode = $descriptorCheck.ReasonCode }) -Choices @('Exit manually', 'Validate exact-build surface', 'Stop') -SafeDefault 'Stop'
    }

    $actionResult = $null
    if ($null -ne $UiProvider) {
        $actionResult = Invoke-RecoveryUiAction -Action 'Exit' -ControlDescriptor $descriptor -UiProvider $UiProvider
        if (-not $actionResult.Allowed) {
            return New-FsManualGateResult -GateId 'G-08' -Reason 'The validated File > Exit action failed or was rejected.' -Evidence ([pscustomobject]@{ ActionResult = $actionResult }) -Choices @('Retry graceful close', 'Leave active state untouched', 'Stop') -SafeDefault 'Leave active state untouched'
        }
    }

    $closeVerifiedValue = Get-FsProperty -InputObject $Observation -Names @('GracefulCloseVerified', 'CloseVerified')
    $processTerminatedValue = Get-FsProperty -InputObject $Observation -Names @('ProcessTerminated', 'ProcessExitedAfterClose')
    $verified = (Test-FsBoolean $closeVerifiedValue) -and (Test-FsBoolean $processTerminatedValue)
    return [pscustomobject]@{
        Allowed = $true
        Attempted = $true
        Result = if ($verified) { 'GracefulCloseVerified' } else { 'GracefulCloseRequested' }
        ReasonCode = $null
        Reason = $null
        Action = 'Exit'
        ControlDescriptor = $descriptor
        ProcessIdentity = Get-FsProperty -InputObject $Observation -Names @('ProcessIdentity')
        CloseVerified = $verified
        RequiresVerification = -not $verified
        ActionResult = $actionResult
        ManualGate = $null
    }
}

function Test-FsProcessIdentityBinding {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$State,

        [AllowNull()]
        [object]$ProcessIdentity
    )

    if ($null -eq $ProcessIdentity) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessIdentityMissing'; Reason = 'A job-bound process identity is required.' }
    }

    $path = Get-FsProperty -InputObject $ProcessIdentity -Names @('Path', 'ProcessPath', 'ExecutablePath')
    $pidValue = Get-FsProperty -InputObject $ProcessIdentity -Names @('Pid', 'PID', 'Id', 'ProcessId')
    $startTime = Get-FsProperty -InputObject $ProcessIdentity -Names @('StartTime', 'ProcessStartTime')
    if ([string]::IsNullOrWhiteSpace([string]$path) -or $null -eq $pidValue -or [string]::IsNullOrWhiteSpace([string]$startTime)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessIdentityIncomplete'; Reason = 'Path, PID, and start time are required for force close.' }
    }

    $recorded = Get-FsProperty -InputObject $State -Names @('ProcessIdentity', 'ApplicationProcessIdentity')
    if ($null -ne $recorded) {
        $recordedPath = Get-FsProperty -InputObject $recorded -Names @('Path', 'ProcessPath', 'ExecutablePath')
        $recordedPid = Get-FsProperty -InputObject $recorded -Names @('Pid', 'PID', 'Id', 'ProcessId')
        $recordedStart = Get-FsProperty -InputObject $recorded -Names @('StartTime', 'ProcessStartTime')
        if (-not [string]::Equals([string]$path, [string]$recordedPath, [StringComparison]::OrdinalIgnoreCase) -or [string]$pidValue -ne [string]$recordedPid -or [string]$startTime -ne [string]$recordedStart) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessIdentityMismatch'; Reason = 'The process identity is not the identity recorded for this job.' }
        }
        return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
    }

    $jobId = Get-FsProperty -InputObject $State -Names @('JobId', 'JobIdentity')
    $processJobId = Get-FsProperty -InputObject $ProcessIdentity -Names @('JobId', 'JobIdentity')
    if ([string]::IsNullOrWhiteSpace([string]$jobId) -or [string]::IsNullOrWhiteSpace([string]$processJobId) -or [string]$jobId -ne [string]$processJobId) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessIdentityUnbound'; Reason = 'The process identity is not bound to the recovery job.' }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Request-FileScavengerForceClose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ProcessIdentity,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Confirmation
    )

    $stateName = Get-FsStateName -State $State
    if ($stateName -eq 'SHORT_SCAN_RUNNING' -or $stateName -eq 'SHORT_RECOVERY_RUNNING' -or $stateName -eq 'LONG_SCAN_RUNNING' -or $stateName -eq 'LONG_RECOVERY_RUNNING' -or $stateName -eq 'INTERRUPTED_UNKNOWN' -or [string]::IsNullOrWhiteSpace([string]$stateName)) {
        return [pscustomobject]@{ Allowed = $false; Result = 'Blocked'; ReasonCode = 'ForceCloseActiveOrUnknown'; Reason = 'Force close is forbidden during active or unknown work.'; GuardSatisfied = $false; RequiresOperator = $true }
    }

    if ($stateName -ne 'SHORT_RECOVERY_VERIFIED' -and $stateName -ne 'LONG_RECOVERY_VERIFIED') {
        return [pscustomobject]@{ Allowed = $false; Result = 'Blocked'; ReasonCode = 'RecoveryNotVerified'; Reason = 'Force close requires a verified recovery state, not scan completion alone.'; GuardSatisfied = $false; RequiresOperator = $true }
    }

    $recoveryEvidence = Get-FsValue -Sources @($State, (Get-FsProperty -InputObject $State -Names @('StageEvidence', 'Evidence'))) -Names @('RecoveryFinished', 'RecoveryFinishedEvidence', 'RecoveryCompletionVerified', 'RecoveryVerified', 'ActiveRecoveryFinished')
    if (-not $recoveryEvidence.Found -or -not (Test-FsBoolean $recoveryEvidence.Value)) {
        return [pscustomobject]@{ Allowed = $false; Result = 'Blocked'; ReasonCode = 'RecoveryEvidenceMissing'; Reason = 'A separate recovery-finished evidence record is required before force close.'; GuardSatisfied = $false; RequiresOperator = $true }
    }

    $binding = Test-FsProcessIdentityBinding -State $State -ProcessIdentity $ProcessIdentity
    if (-not $binding.Valid) {
        return [pscustomobject]@{ Allowed = $false; Result = 'Blocked'; ReasonCode = $binding.ReasonCode; Reason = $binding.Reason; GuardSatisfied = $false; RequiresOperator = $true }
    }

    $confirmed = Test-FsBoolean $Confirmation
    if (-not $confirmed -and [string]$Confirmation -ne 'CONFIRM_FORCE_CLOSE') {
        return [pscustomobject]@{ Allowed = $false; Result = 'Blocked'; ReasonCode = 'ConfirmationRequired'; Reason = 'An explicit force-close confirmation is required.'; GuardSatisfied = $false; RequiresOperator = $true }
    }

    return [pscustomobject]@{
        Allowed = $true
        Result = 'ForceCloseRequested'
        ReasonCode = $null
        Reason = $null
        GuardSatisfied = $true
        RequiresOperator = $true
        RequiresOperatorExecution = $true
        Action = 'ForceClose'
        ProcessIdentity = $ProcessIdentity
        AuditRequired = $true
        PostCloseVerificationRequired = $true
        ManualGate = $null
    }
}

Export-ModuleMember -Function Start-FileScavenger, Get-FileScavengerObservation, Request-FileScavengerStage, Test-FileScavengerCompletion, Request-FileScavengerGracefulClose, Request-FileScavengerForceClose
