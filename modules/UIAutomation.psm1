Set-StrictMode -Version 3.0

function New-RecoveryManualGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$GateId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Evidence,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Choices,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SafeDefault
    )

    $choiceValues = @($Choices | ForEach-Object { [string]$_ })
    if ($choiceValues.Count -eq 0) {
        throw 'A manual gate must provide at least one operator choice.'
    }

    if (-not ($choiceValues -contains $SafeDefault)) {
        throw 'The safe default must be one of the gate choices.'
    }

    return [pscustomobject]@{
        GateId = $GateId
        Reason = $Reason
        Evidence = $Evidence
        Choices = $choiceValues
        SafeDefault = $SafeDefault
        RequiresOperator = $true
        Decision = $null
        Status = 'Pending'
        CreatedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-RecoveryUiProperty {
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
            if ($InputObject.Contains($name)) {
                return $InputObject[$name]
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

function Test-RecoveryUiProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Test-RecoveryUiBoolean {
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

function Test-RecoveryUiDescriptor {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ControlDescriptor
    )

    if ($null -eq $ControlDescriptor) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ControlDescriptorMissing'; Reason = 'No exact-build control descriptor was supplied.' }
    }

    $forbiddenNames = @('X', 'Y', 'Left', 'Top', 'Right', 'Bottom', 'ScreenX', 'ScreenY', 'Coordinates', 'BoundingRectangle', 'Keys', 'KeySequence', 'SendKeys', 'RawKeys', 'Keystrokes', 'Expression', 'SelectorScript', 'ScriptBlock', 'Command')
    foreach ($name in $forbiddenNames) {
        $forbiddenValue = Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @($name)
        if ($null -ne $forbiddenValue) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'UnsupportedUiStrategy'; Reason = ('The descriptor contains the prohibited UI field {0}.' -f $name) }
        }
    }

    if (Test-RecoveryUiBoolean (Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @('Ambiguous'))) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'AmbiguousControl'; Reason = 'The supplied control descriptor is marked ambiguous.' }
    }

    $matchCount = Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @('MatchCount', 'ControlCount', 'MatchesFound')
    if ($null -ne $matchCount) {
        $matchNumber = 0
        if (-not [int]::TryParse(([string]$matchCount), [ref]$matchNumber) -or $matchNumber -ne 1) {
            return [pscustomobject]@{ Valid = $false; ReasonCode = 'AmbiguousControl'; Reason = 'The supplied control descriptor does not identify exactly one control.' }
        }
    }

    $validated = Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @('Validated', 'OwnerValidated', 'EvidenceValidated')
    if (-not (Test-RecoveryUiBoolean $validated)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceRequired'; Reason = 'The control was not validated on the exact installed build.' }
    }

    $buildMatch = Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @('ExactBuildMatch', 'BuildMatched', 'BuildMatch', 'ExactBuildValidated')
    if (-not (Test-RecoveryUiBoolean $buildMatch)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'BuildMismatch'; Reason = 'The control descriptor is not bound to the exact installed build.' }
    }

    $evidenceSource = Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @('EvidenceSource', 'EvidenceReference', 'ValidationSource')
    if ([string]::IsNullOrWhiteSpace([string]$evidenceSource)) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'EvidenceRequired'; Reason = 'The exact-build evidence source is missing.' }
    }

    $stablePropertyNames = @('AutomationId', 'Name', 'ControlType', 'Handle', 'NativeWindowHandle', 'RuntimeId', 'PropertyConditions')
    $hasStableProperty = $false
    foreach ($name in $stablePropertyNames) {
        $stableValue = Get-RecoveryUiProperty -InputObject $ControlDescriptor -Names @($name)
        if ($null -ne $stableValue -and -not [string]::IsNullOrWhiteSpace([string]$stableValue)) {
            $hasStableProperty = $true
            break
        }
    }

    if (-not $hasStableProperty) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ControlDescriptorIncomplete'; Reason = 'The descriptor has no validated UI Automation or Win32 control property.' }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Get-RecoveryAppState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ProcessIdentity,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [scriptblock]$UiProvider
    )

    $base = [ordered]@{
        ProcessIdentity = $ProcessIdentity
        WindowPresent = $false
        Ready = $false
        Controls = @()
        LocalizedControls = @()
        StatusLabels = @()
        Status = @()
        Messages = @()
        ProcessAlive = $false
        ProcessExited = $false
        WindowTitle = $null
        ActiveWork = $false
        ScanRunning = $false
        RecoveryRunning = $false
        Unknown = $true
        Confidence = 'Unknown'
        Error = $null
        ReasonCode = $null
    }

    if ($null -eq $ProcessIdentity) {
        $base.ReasonCode = 'ProcessIdentityMissing'
        return [pscustomobject]$base
    }

    if ($null -eq $UiProvider) {
        $base.ReasonCode = 'UiProviderUnavailable'
        return [pscustomobject]$base
    }

    try {
        $providerOutput = @($UiProvider.Invoke($ProcessIdentity))
    }
    catch {
        $base.ReasonCode = 'UiObservationFailed'
        $base.Error = $_.Exception.Message
        return [pscustomobject]$base
    }

    if ($providerOutput.Count -eq 0) {
        $base.ReasonCode = 'UiObservationUnknown'
        return [pscustomobject]$base
    }
    if ($providerOutput.Count -ne 1) {
        $base.ReasonCode = 'AmbiguousUiObservation'
        $base.Error = 'The UI provider returned more than one application state.'
        return [pscustomobject]$base
    }
    $rawState = $providerOutput[0]

    $windowValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('WindowPresent', 'WindowExists', 'HasWindow')
    $readyValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('Ready', 'IsReady', 'ReadyForAction')
    $controlsValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('Controls', 'LocalizedControls', 'ControlProperties')
    $statusValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('StatusLabels', 'Status', 'StatusValues')
    $messagesValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('Messages', 'MessageArea', 'Warnings')
    $processAliveValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('ProcessAlive', 'IsRunning')
    $processExitedValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('ProcessExited', 'Exited')
    $windowTitleValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('WindowTitle', 'Title')
    $activeWorkValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('ActiveWork', 'WorkActive')
    $scanRunningValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('ScanRunning', 'IsScanning')
    $recoveryRunningValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('RecoveryRunning', 'IsRecovering')
    $unknownValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('Unknown', 'IsUnknown')
    $confidenceValue = Get-RecoveryUiProperty -InputObject $rawState -Names @('Confidence', 'EvidenceConfidence')

    $base.WindowPresent = Test-RecoveryUiBoolean $windowValue
    $base.Ready = Test-RecoveryUiBoolean $readyValue
    $base.Controls = @($controlsValue)
    $base.LocalizedControls = @($controlsValue)
    $base.StatusLabels = @($statusValue)
    $base.Status = @($statusValue)
    $base.Messages = @($messagesValue)
    $base.ProcessAlive = Test-RecoveryUiBoolean $processAliveValue
    $base.ProcessExited = Test-RecoveryUiBoolean $processExitedValue
    $base.WindowTitle = $windowTitleValue
    $base.ActiveWork = Test-RecoveryUiBoolean $activeWorkValue
    $base.ScanRunning = Test-RecoveryUiBoolean $scanRunningValue
    $base.RecoveryRunning = Test-RecoveryUiBoolean $recoveryRunningValue
    $base.Unknown = Test-RecoveryUiBoolean $unknownValue
    if ($null -eq $unknownValue) {
        $base.Unknown = $true
    }
    if ($null -ne $confidenceValue -and -not [string]::IsNullOrWhiteSpace([string]$confidenceValue)) {
        $base.Confidence = [string]$confidenceValue
    }
    else {
        $base.Confidence = 'Observed'
    }
    $base.ReasonCode = $null

    return [pscustomobject]$base
}

function Invoke-RecoveryUiAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ControlDescriptor,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [scriptblock]$UiProvider
    )

    $descriptorCheck = Test-RecoveryUiDescriptor -ControlDescriptor $ControlDescriptor
    if (-not $descriptorCheck.Valid) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Blocked'
            Action = $Action
            ReasonCode = $descriptorCheck.ReasonCode
            Reason = $descriptorCheck.Reason
            ProviderResult = $null
        }
    }

    if ($null -eq $UiProvider) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Blocked'
            Action = $Action
            ReasonCode = 'UiProviderUnavailable'
            Reason = 'No UI provider was supplied for the evidence-gated action.'
            ProviderResult = $null
        }
    }

    try {
        $providerOutput = @($UiProvider.Invoke($Action, $ControlDescriptor))
    }
    catch {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Failed'
            Action = $Action
            ReasonCode = 'UiActionFailed'
            Reason = $_.Exception.Message
            ProviderResult = $null
        }
    }

    if ($providerOutput.Count -eq 0) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Unknown'
            Action = $Action
            ReasonCode = 'UiActionUnknown'
            Reason = 'The UI provider did not return an action result.'
            ProviderResult = $null
        }
    }
    if ($providerOutput.Count -ne 1) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Unknown'
            Action = $Action
            ReasonCode = 'UiActionResultAmbiguous'
            Reason = 'The UI provider returned more than one action result, so no single outcome can be verified.'
            ProviderResult = $providerOutput
        }
    }
    $providerResult = $providerOutput[0]

    $providerAmbiguous = Get-RecoveryUiProperty -InputObject $providerResult -Names @('Ambiguous')
    $providerMatchCount = Get-RecoveryUiProperty -InputObject $providerResult -Names @('MatchCount', 'ControlCount', 'MatchesFound')
    if (Test-RecoveryUiBoolean $providerAmbiguous) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Blocked'
            Action = $Action
            ReasonCode = 'AmbiguousControl'
            Reason = 'The UI provider reported an ambiguous control match.'
            ProviderResult = $providerResult
        }
    }
    if ($null -ne $providerMatchCount) {
        $providerMatchNumber = 0
        if (-not [int]::TryParse(([string]$providerMatchCount), [ref]$providerMatchNumber) -or $providerMatchNumber -ne 1) {
            return [pscustomobject]@{
                Allowed = $false
                Result = 'Blocked'
                Action = $Action
                ReasonCode = 'AmbiguousControl'
                Reason = 'The UI provider did not resolve exactly one control.'
                ProviderResult = $providerResult
            }
        }
    }

    $successNames = New-Object System.Collections.ArrayList
    foreach ($name in @('Allowed', 'Success', 'Invoked')) {
        if (Test-RecoveryUiProperty -InputObject $providerResult -Name $name) {
            [void]$successNames.Add($name)
        }
    }
    if ($successNames.Count -eq 0) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Unknown'
            Action = $Action
            ReasonCode = 'UiActionResultUnverified'
            Reason = 'The UI provider returned no explicit success decision.'
            ProviderResult = $providerResult
        }
    }
    if ($successNames.Count -ne 1) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Blocked'
            Action = $Action
            ReasonCode = 'UiActionResultAmbiguous'
            Reason = 'The UI provider returned more than one success decision field.'
            ProviderResult = $providerResult
        }
    }
    $providerAllowed = Get-RecoveryUiProperty -InputObject $providerResult -Names @($successNames[0])
    if ($providerAllowed -isnot [bool] -or -not [bool]$providerAllowed) {
        return [pscustomobject]@{
            Allowed = $false
            Result = 'Failed'
            Action = $Action
            ReasonCode = 'UiActionRejected'
            Reason = 'The UI provider rejected the evidence-gated action.'
            ProviderResult = $providerResult
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Result = 'ActionInvoked'
        Action = $Action
        ReasonCode = $null
        Reason = $null
        ControlDescriptor = $ControlDescriptor
        ProviderResult = $providerResult
    }
}

Export-ModuleMember -Function New-RecoveryManualGate, Get-RecoveryAppState, Invoke-RecoveryUiAction
