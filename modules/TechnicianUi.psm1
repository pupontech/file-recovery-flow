<#
.SYNOPSIS
Technician-facing UI seams for the recovery workflow: destination selection,
manual gates, the client handoff panel, and the documented Windows pickers.

.DESCRIPTION
This module owns the technician UI surface described by
docs/IMPLEMENTATION-SPEC.md section 2.9 and TEST-MATRIX section 6 (R-08 to R-10).

Supported surface (vendor and platform evidence):
- The primary folder picker is System.Windows.Forms.FolderBrowserDialog, whose
  documented SelectedPath member returns the selected filesystem path. The
  new-folder affordance is disabled because the workflow claims the unique job
  folder itself.
  https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.folderbrowserdialog
- Shell.Application BrowseForFolder is not used for a safety decision: the
  documented returned Folder object exposes no filesystem path property.
  https://learn.microsoft.com/en-us/windows/win32/shell/folder
- Windows PowerShell 3.0 and later run in a single-threaded apartment by
  default, so the launcher must not pass -Mta for this dialog path.
  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1
- The destination decision itself is never made here: this module displays the
  resolver evidence and stops. The physical-disk refusal belongs to the
  destination resolver (DiskDetection.psm1) and remains fail-closed.

Unknown / manual boundary: the exact rendered appearance, DPI behavior, focus
result, and localization of the handoff panel and the folder dialog are not
vendor-documented contracts. They are validated on the technician machine by the
owner-live gate (TEST-MATRIX L-02 and L-11). This module starts no vendor process
and enables no write-capable vendor feature.

Every operating-system call is injected as a scriptblock seam. Documented
production seams are returned as scriptblocks by Get-TechnicianUiDefaultProvider
and are executed only when the orchestrator passes them in; nothing runs at
import time.

Note: docs/IMPLEMENTATION-SPEC.md lists Select-DestinationFolder in both
DiskDetection.psm1 (section 2.3) and this module (section 2.9). This module keeps
the interactive evidence-display behavior and delegates the selection and safety
decision to an injected resolver, so the orchestrator must import exactly one
implementation of that name.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TUAllowedPanelActions = @('Close', 'CopyClientName', 'OpenClientFolder')
$script:TUContinueChoice = 'CONTINUE'

$script:TUForegroundSource = @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@

function Test-TUObjectProperty {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [string]) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }
    $names = @($InputObject.PSObject.Properties.Name)
    return ($names -contains $Name)
}

function Get-TUObjectPropertyValue {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        if (Test-TUObjectProperty -InputObject $InputObject -Name $name) {
            if ($InputObject -is [System.Collections.IDictionary]) {
                $value = $InputObject[$name]
            }
            else {
                $value = $InputObject.$name
            }
            if ($null -ne $value) { return $value }
        }
    }
    return $null
}

function Test-TUProviderActionResult {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ProviderResult,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedResult
    )

    if ($null -eq $ProviderResult) {
        return [pscustomobject]@{
            Status     = 'Missing'
            ReasonCode = 'PanelActionResultMissing'
            Reason     = 'The action provider returned no result.'
        }
    }

    $successNames = New-Object System.Collections.ArrayList
    foreach ($name in @('Success', 'Allowed', 'Invoked')) {
        if (Test-TUObjectProperty -InputObject $ProviderResult -Name $name) {
            [void]$successNames.Add($name)
        }
    }
    if ($successNames.Count -eq 0) {
        return [pscustomobject]@{
            Status     = 'Unverified'
            ReasonCode = 'PanelActionResultUnverified'
            Reason     = 'The action provider returned no explicit success decision.'
        }
    }
    if ($successNames.Count -ne 1) {
        return [pscustomobject]@{
            Status     = 'Ambiguous'
            ReasonCode = 'PanelActionResultAmbiguous'
            Reason     = 'The action provider returned more than one success decision field.'
        }
    }

    $successValue = Get-TUObjectPropertyValue -InputObject $ProviderResult -Names @($successNames[0])
    if ($successValue -isnot [bool] -or -not [bool]$successValue) {
        return [pscustomobject]@{
            Status     = 'Failed'
            ReasonCode = 'PanelActionFailed'
            Reason     = 'The action provider did not positively authorize the requested action.'
        }
    }

    $reportedResult = Get-TUObjectPropertyValue -InputObject $ProviderResult -Names @('Result', 'Decision', 'Status')
    if ($null -ne $reportedResult -and -not [string]::Equals(([string]$reportedResult).Trim(), $ExpectedResult, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Status     = 'Failed'
            ReasonCode = 'PanelActionFailed'
            Reason     = ('The action provider reported an unexpected result for {0}.' -f $Action)
        }
    }

    return [pscustomobject]@{
        Status     = 'Succeeded'
        ReasonCode = $null
        Reason     = $null
    }
}

function Test-TUAbsolutePath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $true }
    # Windows drive-letter and UNC forms are not recognized by IsPathRooted on a
    # non-Windows host, so they are recognized explicitly here.
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\[^\\]+\\') { return $true }
    return $false
}

function Test-TUPathText {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-TUAbsolutePath -Path $Path)) { return $false }
    if ($Path -match '[\x00-\x1F]') { return $false }
    if ($Path.Contains('"')) { return $false }
    if ($Path.Contains('*')) { return $false }
    if ($Path.Contains('?')) { return $false }
    if ($Path -match '[<>|]') { return $false }
    return $true
}

function New-TechnicianUiManualGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GateId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [hashtable]$Evidence,
        [string[]]$Choices,
        [string]$SafeDefault,
        [string]$Scope = 'ManualOnly'
    )

    if ($null -eq $Evidence) { $Evidence = @{} }
    return [pscustomobject]@{
        GateId                   = $GateId
        Reason                   = $Reason
        Evidence                 = $Evidence
        Choices                  = @($Choices)
        SafeDefault              = $SafeDefault
        Scope                    = $Scope
        RequiresOperatorDecision = $true
        AutoContinueAllowed      = $false
    }
}

function New-TechnicianUiBlockedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [string]$Reason,
        [hashtable]$Evidence,
        [string]$GateId,
        [string[]]$Choices,
        [string]$SafeDefault,
        [string]$Scope
    )

    if ($null -eq $Evidence) { $Evidence = @{} }
    $gate = $null
    if (-not [string]::IsNullOrEmpty($GateId)) {
        if ($null -eq $Choices) { $Choices = @('Stop') }
        if ([string]::IsNullOrEmpty($SafeDefault)) { $SafeDefault = 'Stop' }
        $gate = New-TechnicianUiManualGate -GateId $GateId -Reason $Reason -Evidence $Evidence `
            -Choices $Choices -SafeDefault $SafeDefault -Scope $Scope
    }
    return [pscustomobject]@{
        Decision   = 'Blocked'
        ReasonCode = $ReasonCode
        Reason     = $Reason
        Path       = $null
        Gate       = $gate
        Evidence   = $Evidence
    }
}

function Select-DestinationFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Resolver,
        [scriptblock]$DisplayProvider,
        [string]$Purpose = 'Recovery destination'
    )

    $evidence = @{ Purpose = $Purpose }
    $resolverResult = $null
    try {
        $resolverResult = & $Resolver $Purpose
    }
    catch {
        $evidence['ResolverError'] = $_.Exception.Message
        return New-TechnicianUiBlockedResult -ReasonCode 'ResolverFailed' `
            -Reason 'The destination resolver failed. The destination cannot be proven safe.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSeparation'
    }

    if ($null -eq $resolverResult) {
        return New-TechnicianUiBlockedResult -ReasonCode 'ResolverReturnedNothing' `
            -Reason 'The destination resolver returned no selection.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSeparation'
    }

    $path = $null
    if ($resolverResult -is [string]) { $path = $resolverResult }
    else { $path = Get-TUObjectPropertyValue -InputObject $resolverResult -Names @('Path', 'SelectedPath') }

    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        return New-TechnicianUiBlockedResult -ReasonCode 'ResolverReturnedNoPath' `
            -Reason 'The destination resolver returned no usable path.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSeparation'
    }
    $path = [string]$path
    $evidence['Path'] = $path
    if (-not (Test-TUPathText -Path $path)) {
        return New-TechnicianUiBlockedResult -ReasonCode 'DestinationPathInvalid' `
            -Reason 'The destination resolver returned a path that is not an absolute literal path.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSelection'
    }

    $selectionMethod = Get-TUObjectPropertyValue -InputObject $resolverResult -Names @('SelectionMethod', 'Method')
    if ($null -ne $selectionMethod) { $evidence['SelectionMethod'] = [string]$selectionMethod }

    $allowed = Get-TUObjectPropertyValue -InputObject $resolverResult -Names @('Allowed', 'IsSafe')
    if ($null -eq $allowed) {
        return New-TechnicianUiBlockedResult -ReasonCode 'DestinationSafetyUnverified' `
            -Reason 'The destination resolver returned no physical-disk separation decision.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSeparation'
    }

    if ($allowed -isnot [bool]) {
        return New-TechnicianUiBlockedResult -ReasonCode 'DestinationSafetyUnverified' `
            -Reason 'The destination resolver returned a non-Boolean physical-disk separation decision.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSeparation'
    }

    $safetyReason = Get-TUObjectPropertyValue -InputObject $resolverResult -Names @('ReasonCode')
    $destinationEvidence = Get-TUObjectPropertyValue -InputObject $resolverResult -Names @('DestinationEvidence', 'Evidence')
    if ($null -ne $destinationEvidence) { $evidence['DestinationEvidence'] = $destinationEvidence }

    if ($allowed -ne $true) {
        if ($null -ne $safetyReason) { $evidence['DestinationSafetyReasonCode'] = [string]$safetyReason }
        return New-TechnicianUiBlockedResult -ReasonCode 'DestinationUnsafe' `
            -Reason 'The selected destination is not proven separate from the source.' `
            -Evidence $evidence -GateId 'G-03' -Choices @('Reselect', 'Stop') -SafeDefault 'Stop' `
            -Scope 'DestinationSeparation'
    }

    $displayEvidence = $null
    if ($null -ne $DisplayProvider) {
        $displayRequest = [pscustomobject]@{
            Purpose             = $Purpose
            Path                = $path
            SelectionMethod     = $selectionMethod
            SafetyDecision      = 'Allowed'
            ReasonCode          = $null
            DestinationEvidence = $destinationEvidence
        }
        try {
            $displayEvidence = & $DisplayProvider $displayRequest
        }
        catch {
            $evidence['DisplayError'] = $_.Exception.Message
            return New-TechnicianUiBlockedResult -ReasonCode 'EvidenceDisplayFailed' `
                -Reason 'The destination evidence could not be displayed to the technician.' `
                -Evidence $evidence -GateId 'UI-EvidenceDisplay' -Choices @('RetryDisplay', 'Stop') `
                -SafeDefault 'Stop' -Scope 'DestinationEvidence'
        }
    }
    else {
        $evidence['DisplayProvider'] = 'NotProvided'
    }

    return [pscustomobject]@{
        Decision            = 'Selected'
        ReasonCode          = $null
        Path                = $path
        SelectionMethod     = $selectionMethod
        SafetyDecision      = 'Allowed'
        SafetyEvidence      = $destinationEvidence
        DisplayEvidence     = $displayEvidence
        Gate                = $null
        Evidence            = $evidence
        SelectedAtUtc       = [datetime]::UtcNow
    }
}

function Show-DestinationFolderPicker {
    [CmdletBinding()]
    param(
        [scriptblock]$PickerProvider,
        [scriptblock]$TypedPathProvider,
        [string]$Description = 'Select the recovery destination root folder.'
    )

    $evidence = @{}
    $request = [pscustomobject]@{
        Description         = $Description
        ShowNewFolderButton = $false
        Purpose             = 'DestinationRoot'
    }

    $pickerPath = $null
    $pickerError = $null
    if ($null -ne $PickerProvider) {
        $pickerResult = $null
        try {
            $pickerResult = & $PickerProvider $request
        }
        catch {
            $pickerError = $_.Exception.Message
            $evidence['PickerError'] = $pickerError
        }

        if ($null -ne $pickerResult) {
            if ($pickerResult -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($pickerResult)) { $pickerPath = $pickerResult }
            }
            else {
                $candidate = Get-TUObjectPropertyValue -InputObject $pickerResult -Names @('Path', 'SelectedPath')
                $pickerDecision = Get-TUObjectPropertyValue -InputObject $pickerResult -Names @('Decision', 'Result')
                if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                    $pickerPath = [string]$candidate
                }
                elseif ($null -ne $pickerDecision -and ([string]$pickerDecision).ToUpperInvariant() -eq 'CANCELLED') {
                    $evidence['PickerDecision'] = 'Cancelled'
                    return New-TechnicianUiBlockedResult -ReasonCode 'PickerCancelled' `
                        -Reason 'The technician cancelled the destination folder selection.' `
                        -Evidence $evidence
                }
                elseif ($null -ne $pickerDecision) {
                    $evidence['PickerDecision'] = [string]$pickerDecision
                }
            }
        }
        elseif ($null -eq $pickerError) {
            $evidence['PickerDecision'] = 'Unavailable'
        }
    }
    else {
        $evidence['PickerDecision'] = 'Unavailable'
    }

    if (-not [string]::IsNullOrWhiteSpace($pickerPath)) {
        return [pscustomobject]@{
            Decision        = 'Selected'
            ReasonCode      = $null
            Path            = $pickerPath
            SelectionMethod = 'Picker'
            Gate            = $null
            Evidence        = $evidence
            SelectedAtUtc   = [datetime]::UtcNow
        }
    }

    if ($null -eq $TypedPathProvider) {
        return New-TechnicianUiBlockedResult -ReasonCode 'PickerUnavailable' `
            -Reason 'No interactive folder picker or typed-path prompt is available. The destination must be selected manually.' `
            -Evidence $evidence -GateId 'UI-FolderPicker' -Choices @('RetryPicker', 'Stop') `
            -SafeDefault 'Stop' -Scope 'DestinationSelection'
    }

    $typedResult = $null
    try {
        $typedResult = & $TypedPathProvider $request
    }
    catch {
        $evidence['TypedPathError'] = $_.Exception.Message
        return New-TechnicianUiBlockedResult -ReasonCode 'TypedPathUnavailable' `
            -Reason 'The typed destination path prompt failed.' `
            -Evidence $evidence -GateId 'UI-FolderPicker' -Choices @('RetryPicker', 'Stop') `
            -SafeDefault 'Stop' -Scope 'DestinationSelection'
    }

    $typedPath = $null
    if ($typedResult -is [string]) { $typedPath = $typedResult }
    else { $typedPath = Get-TUObjectPropertyValue -InputObject $typedResult -Names @('Path', 'SelectedPath') }

    if ([string]::IsNullOrWhiteSpace([string]$typedPath)) {
        return New-TechnicianUiBlockedResult -ReasonCode 'TypedPathMissing' `
            -Reason 'No destination path was supplied. The destination cannot be reviewed.' `
            -Evidence $evidence -GateId 'UI-FolderPicker' -Choices @('RetryPicker', 'Stop') `
            -SafeDefault 'Stop' -Scope 'DestinationSelection'
    }

    return [pscustomobject]@{
        Decision        = 'Selected'
        ReasonCode      = $null
        Path            = [string]$typedPath
        SelectionMethod = 'TypedPath'
        Gate            = $null
        Evidence        = $evidence
        SelectedAtUtc   = [datetime]::UtcNow
    }
}

function Show-RecoveryManualGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Gate,
        [scriptblock]$InteractionProvider
    )

    $evidence = @{}
    if ($null -eq $Gate) {
        return [pscustomobject]@{
            Decision        = 'Blocked'
            ReasonCode      = 'GateInvalid'
            Presented       = $false
            DefaultApplied  = $false
            OperatorResponse = $null
            GateId          = $null
            Gate            = $null
            Evidence        = $evidence
            DecidedAtUtc    = [datetime]::UtcNow
        }
    }

    $gateId = Get-TUObjectPropertyValue -InputObject $Gate -Names @('GateId')
    $reason = Get-TUObjectPropertyValue -InputObject $Gate -Names @('Reason')
    $choices = @(Get-TUObjectPropertyValue -InputObject $Gate -Names @('Choices'))
    $safeDefault = Get-TUObjectPropertyValue -InputObject $Gate -Names @('SafeDefault')
    $scope = Get-TUObjectPropertyValue -InputObject $Gate -Names @('Scope')
    $gateEvidence = Get-TUObjectPropertyValue -InputObject $Gate -Names @('Evidence')

    if ([string]::IsNullOrWhiteSpace([string]$gateId) -or [string]::IsNullOrWhiteSpace([string]$reason)) {
        return [pscustomobject]@{
            Decision         = 'Blocked'
            ReasonCode       = 'GateInvalid'
            Presented        = $false
            DefaultApplied   = $false
            OperatorResponse = $null
            GateId           = $gateId
            Gate             = $Gate
            Evidence         = $evidence
            DecidedAtUtc     = [datetime]::UtcNow
        }
    }

    $gateId = [string]$gateId
    if ($choices.Count -eq 0) {
        return [pscustomobject]@{
            Decision         = 'Blocked'
            ReasonCode       = 'GateChoicesMissing'
            Presented        = $false
            DefaultApplied   = $false
            OperatorResponse = $null
            GateId           = $gateId
            Gate             = $Gate
            Evidence         = $evidence
            DecidedAtUtc     = [datetime]::UtcNow
        }
    }

    # A safe default that is missing, not one of the choices, or "Continue" would
    # let a blank or timed-out answer authorize progress. It is rejected instead.
    $safeDefaultText = ''
    if ($null -ne $safeDefault) { $safeDefaultText = [string]$safeDefault }
    $normalizedDefault = $safeDefaultText.Trim().ToUpperInvariant()
    $defaultInChoices = $false
    $canonicalDefault = $null
    foreach ($choice in $choices) {
        if (([string]$choice).Trim().ToUpperInvariant() -eq $normalizedDefault -and -not [string]::IsNullOrEmpty($normalizedDefault)) {
            $defaultInChoices = $true
            $canonicalDefault = [string]$choice
        }
    }
    if (-not $defaultInChoices -or $normalizedDefault -eq $script:TUContinueChoice) {
        return [pscustomobject]@{
            Decision         = 'Blocked'
            ReasonCode       = 'GateSafeDefaultInvalid'
            Presented        = $false
            DefaultApplied   = $false
            OperatorResponse = $null
            GateId           = $gateId
            Gate             = $Gate
            Evidence         = $evidence
            DecidedAtUtc     = [datetime]::UtcNow
        }
    }

    $request = [pscustomobject]@{
        GateId      = $gateId
        Reason      = [string]$reason
        Evidence    = $gateEvidence
        Scope       = $scope
        Choices     = $choices
        SafeDefault = $canonicalDefault
    }

    $rawResponse = $null
    $cancelled = $false
    $timedOut = $false
    $reasonCode = $null
    $decision = $canonicalDefault
    $defaultApplied = $true

    if ($null -eq $InteractionProvider) {
        $reasonCode = 'GateInteractionUnavailable'
        $evidence['GatePresentation'] = 'No interaction seam was supplied.'
    }
    else {
        $interactionResult = $null
        try {
            $interactionResult = & $InteractionProvider $request
        }
        catch {
            $evidence['GateInteractionError'] = $_.Exception.Message
            $reasonCode = 'GateInteractionFailed'
        }

        if ($null -eq $reasonCode) {
            if ($null -eq $interactionResult) {
                $reasonCode = 'GateNoDecision'
            }
            elseif ($interactionResult -is [string]) {
                $rawResponse = $interactionResult
            }
            else {
                $rawResponse = Get-TUObjectPropertyValue -InputObject $interactionResult -Names @('Response', 'Answer', 'Decision')
                $cancelledValue = Get-TUObjectPropertyValue -InputObject $interactionResult -Names @('Cancelled', 'Canceled')
                $timedOutValue = Get-TUObjectPropertyValue -InputObject $interactionResult -Names @('TimedOut')
                if ($cancelledValue -eq $true) { $cancelled = $true }
                if ($timedOutValue -eq $true) { $timedOut = $true }
            }

            if ($cancelled) {
                $reasonCode = 'GateCancelled'
            }
            elseif ($timedOut) {
                $reasonCode = 'GateTimedOut'
            }
            else {
                $responseText = ''
                if ($null -ne $rawResponse) { $responseText = ([string]$rawResponse).Trim() }
                if ([string]::IsNullOrEmpty($responseText)) {
                    $reasonCode = 'GateNoDecision'
                }
                else {
                    $normalizedResponse = $responseText.ToUpperInvariant()
                    $matched = $false
                    foreach ($choice in $choices) {
                        if (([string]$choice).Trim().ToUpperInvariant() -eq $normalizedResponse) {
                            $decision = [string]$choice
                            $matched = $true
                        }
                    }
                    if ($matched) {
                        $defaultApplied = $false
                        $reasonCode = $null
                    }
                    else {
                        $reasonCode = 'GateResponseUnrecognized'
                    }
                }
            }
        }
    }

    $evidence['GateId'] = $gateId
    $evidence['SafeDefault'] = $canonicalDefault
    if ($null -ne $scope) { $evidence['Scope'] = [string]$scope }
    if ($null -ne $rawResponse) { $evidence['OperatorResponse'] = [string]$rawResponse }
    $evidence['DefaultApplied'] = $defaultApplied

    return [pscustomobject]@{
        Decision         = $decision
        ReasonCode       = $reasonCode
        Presented        = $true
        DefaultApplied   = $defaultApplied
        OperatorResponse = $rawResponse
        GateId           = $gateId
        Gate             = $Gate
        Evidence         = $evidence
        DecidedAtUtc     = [datetime]::UtcNow
    }
}

function Show-RecoveryHandoffPanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ClientName,
        [AllowNull()][AllowEmptyString()][string]$ClientFolder,
        [ValidateSet('Close', 'CopyClientName', 'OpenClientFolder')][string[]]$Actions = @('Close', 'CopyClientName', 'OpenClientFolder'),
        [scriptblock]$InteractionProvider,
        [scriptblock]$ClipboardProvider,
        [scriptblock]$ExplorerProvider,
        [scriptblock]$PathSafetyValidator,
        [string]$Title = 'File Recovery - Client Handoff'
    )

    if ([string]::IsNullOrWhiteSpace($ClientName)) {
        throw 'The client name must not be blank: the handoff panel exists to display it to the technician.'
    }

    $evidence = @{}
    $enabled = New-Object System.Collections.ArrayList
    foreach ($action in @($Actions)) {
        if (-not $enabled.Contains($action)) { [void]$enabled.Add($action) }
    }
    $disabled = New-Object System.Collections.ArrayList

    if ($enabled.Contains('OpenClientFolder')) {
        $folderUsable = $true
        if ([string]::IsNullOrWhiteSpace($ClientFolder)) {
            $folderUsable = $false
            $evidence['OpenClientFolderDisabled'] = 'ClientFolderNotProvided'
        }
        elseif (-not (Test-TUPathText -Path $ClientFolder)) {
            $folderUsable = $false
            $evidence['OpenClientFolderDisabled'] = 'ClientFolderInvalid'
        }
        else {
            $exists = $false
            try {
                $exists = Test-Path -LiteralPath $ClientFolder -PathType Container -ErrorAction Stop
            }
            catch {
                $evidence['ContainerCheckError'] = $_.Exception.Message
            }
            if (-not $exists) {
                $folderUsable = $false
                $evidence['OpenClientFolderDisabled'] = 'ClientFolderMissing'
            }
            elseif ($null -ne $PathSafetyValidator) {
                $safetyAllowed = $null
                try {
                    $safetyResult = & $PathSafetyValidator $ClientFolder
                    $safetyAllowed = Get-TUObjectPropertyValue -InputObject $safetyResult -Names @('Allowed', 'IsSafe')
                }
                catch {
                    $evidence['PathSafetyError'] = $_.Exception.Message
                }
                if ($null -eq $safetyAllowed) {
                    $folderUsable = $false
                    $evidence['OpenClientFolderDisabled'] = 'ClientFolderSafetyUnverified'
                }
                elseif ($safetyAllowed -isnot [bool] -or -not [bool]$safetyAllowed) {
                    $folderUsable = $false
                    $evidence['OpenClientFolderDisabled'] = 'ClientFolderUnsafe'
                }
            }
        }
        if (-not $folderUsable) {
            [void]$enabled.Remove('OpenClientFolder')
            [void]$disabled.Add('OpenClientFolder')
        }
    }

    $panelRequest = [pscustomobject]@{
        Title               = $Title
        Purpose             = 'ClientNameHandoff'
        ClientName          = $ClientName
        ClientFolder        = $ClientFolder
        TopMost             = $true
        RequireExplicitAction = $true
        EnabledActions      = @($enabled)
        DisabledActions     = @($disabled)
    }

    if ($null -eq $InteractionProvider) {
        $result = New-TechnicianUiBlockedResult -ReasonCode 'PanelUnavailable' `
            -Reason 'The client handoff panel is not available. The technician must confirm the client name and case folder manually.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
        $result.Evidence['ClientName'] = $ClientName
        $result.Evidence['EnabledActions'] = @($enabled)
        $result.Evidence['DisabledActions'] = @($disabled)
        return $result
    }

    $panelResult = $null
    try {
        $panelResult = & $InteractionProvider $panelRequest
    }
    catch {
        $evidence['PanelError'] = $_.Exception.Message
        $result = New-TechnicianUiBlockedResult -ReasonCode 'PanelProviderFailed' `
            -Reason 'The client handoff panel failed to display.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
        $result.Evidence['ClientName'] = $ClientName
        return $result
    }

    if ($null -eq $panelResult) {
        return New-TechnicianUiBlockedResult -ReasonCode 'PanelResultMissing' `
            -Reason 'The client handoff panel returned no result. The operator decision is unknown.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }

    $panelSuccessProperties = New-Object System.Collections.ArrayList
    foreach ($successName in @('Success', 'Allowed', 'Invoked')) {
        if (Test-TUObjectProperty -InputObject $panelResult -Name $successName) {
            [void]$panelSuccessProperties.Add($successName)
        }
    }
    if ($panelSuccessProperties.Count -eq 0) {
        $evidence['ClientName'] = $ClientName
        return New-TechnicianUiBlockedResult -ReasonCode 'PanelResultUnverified' `
            -Reason 'The client handoff panel did not return an explicit Success=true result.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }
    if ($panelSuccessProperties.Count -ne 1) {
        $evidence['ClientName'] = $ClientName
        return New-TechnicianUiBlockedResult -ReasonCode 'PanelResultAmbiguous' `
            -Reason 'The client handoff panel returned more than one success decision field.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }
    $panelSuccess = Get-TUObjectPropertyValue -InputObject $panelResult -Names @($panelSuccessProperties[0])
    if ($panelSuccess -isnot [bool] -or -not [bool]$panelSuccess) {
        $evidence['ClientName'] = $ClientName
        return New-TechnicianUiBlockedResult -ReasonCode 'PanelResultFailed' `
            -Reason 'The client handoff panel reported failure.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }

    $actionsTaken = @()
    if ($panelResult -is [string]) {
        $actionsTaken = @($panelResult)
    }
    else {
        $rawActions = Get-TUObjectPropertyValue -InputObject $panelResult -Names @('ActionsTaken', 'Actions')
        if ($null -ne $rawActions) { $actionsTaken = @($rawActions) }
        if ($actionsTaken.Count -eq 0) {
            $lastAction = Get-TUObjectPropertyValue -InputObject $panelResult -Names @('LastAction')
            if ($null -ne $lastAction -and -not [string]::IsNullOrWhiteSpace([string]$lastAction)) {
                $actionsTaken = @([string]$lastAction)
            }
        }
    }

    $windowShown = $false
    $topMostRequested = $true
    $foregroundRequested = $false
    $closedBy = $null
    if (-not ($panelResult -is [string])) {
        $rawWindowShown = Get-TUObjectPropertyValue -InputObject $panelResult -Names @('WindowShown', 'Shown')
        if ($null -ne $rawWindowShown) { $windowShown = ($rawWindowShown -eq $true) }
        else { $evidence['WindowState'] = 'Unreported' }

        $rawTopMost = Get-TUObjectPropertyValue -InputObject $panelResult -Names @('TopMostRequested')
        if ($null -ne $rawTopMost) { $topMostRequested = ($rawTopMost -eq $true) }

        $rawForeground = Get-TUObjectPropertyValue -InputObject $panelResult -Names @('ForegroundRequested')
        if ($null -ne $rawForeground) { $foregroundRequested = ($rawForeground -eq $true) }

        $rawClosedBy = Get-TUObjectPropertyValue -InputObject $panelResult -Names @('ClosedBy')
        if ($null -ne $rawClosedBy) { $closedBy = [string]$rawClosedBy }
    }
    else {
        $evidence['WindowState'] = 'Unreported'
    }

    $closeActionFound = $false
    foreach ($action in @($actionsTaken)) {
        if ([string]::Equals(([string]$action).Trim(), 'Close', [System.StringComparison]::OrdinalIgnoreCase) -and
            $enabled.Contains('Close')) {
            $closeActionFound = $true
            break
        }
    }
    if (-not $closeActionFound) {
        $evidence['ClientName'] = $ClientName
        $evidence['ActionsTaken'] = @($actionsTaken)
        return New-TechnicianUiBlockedResult -ReasonCode 'CloseActionRequired' `
            -Reason 'The handoff panel did not report an explicit recognized Close action.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }
    if ($null -ne $closedBy -and -not [string]::IsNullOrWhiteSpace($closedBy) -and
        -not [string]::Equals($closedBy.Trim(), 'Close', [System.StringComparison]::OrdinalIgnoreCase)) {
        $evidence['ClientName'] = $ClientName
        $evidence['ClosedBy'] = $closedBy
        return New-TechnicianUiBlockedResult -ReasonCode 'CloseActionUnverified' `
            -Reason 'The handoff panel reported a close mechanism other than the recognized Close action.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }
    if (-not $windowShown) {
        $evidence['ClientName'] = $ClientName
        return New-TechnicianUiBlockedResult -ReasonCode 'PanelDisplayUnverified' `
            -Reason 'The handoff panel did not return positive window-display evidence.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
    }

    $actionResults = @{}
    $refusedActions = New-Object System.Collections.ArrayList
    $actionFailure = $false
    $actionFailureReasonCode = $null
    foreach ($action in $actionsTaken) {
        $actionName = [string]$action
        if (-not ($script:TUAllowedPanelActions -contains $actionName)) {
            [void]$refusedActions.Add($actionName)
            $actionResults[$actionName] = 'ActionRefused'
            $actionFailure = $true
            if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = 'PanelActionUnrecognized' }
            continue
        }
        if (-not $enabled.Contains($actionName)) {
            if ($actionName -eq 'OpenClientFolder') { $actionResults[$actionName] = 'OpenFolderDisabled' }
            else { $actionResults[$actionName] = 'ActionDisabled' }
            $actionFailure = $true
            if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = 'PanelActionDisabled' }
            continue
        }

        switch ($actionName) {
            'Close' {
                $actionResults[$actionName] = 'Closed'
            }
            'CopyClientName' {
                if ($null -eq $ClipboardProvider) {
                    $actionResults[$actionName] = 'CopyUnavailable'
                    $actionFailure = $true
                    if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = 'PanelActionFailed' }
                }
                else {
                    try {
                        $providerOutput = @(& $ClipboardProvider ([pscustomobject]@{ Action = 'CopyClientName'; ClientName = $ClientName }))
                        if ($providerOutput.Count -eq 0) {
                            $actionCheck = Test-TUProviderActionResult -ProviderResult $null `
                                -Action $actionName -ExpectedResult 'Copied'
                        }
                        elseif ($providerOutput.Count -ne 1) {
                            $actionCheck = [pscustomobject]@{
                                Status = 'Ambiguous'
                                ReasonCode = 'PanelActionResultAmbiguous'
                                Reason = 'The clipboard provider returned more than one action result.'
                            }
                        }
                        else {
                            $actionCheck = Test-TUProviderActionResult -ProviderResult $providerOutput[0] `
                                -Action $actionName -ExpectedResult 'Copied'
                        }
                        if ($actionCheck.Status -eq 'Succeeded') {
                            $actionResults[$actionName] = 'Copied'
                        }
                        else {
                            switch ($actionCheck.Status) {
                                'Missing' { $actionResults[$actionName] = 'CopyResultMissing' }
                                'Unverified' { $actionResults[$actionName] = 'CopyResultUnverified' }
                                'Ambiguous' { $actionResults[$actionName] = 'CopyResultAmbiguous' }
                                default { $actionResults[$actionName] = 'CopyFailed' }
                            }
                            $actionFailure = $true
                            if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = $actionCheck.ReasonCode }
                        }
                    }
                    catch {
                        $evidence['ClipboardError'] = $_.Exception.Message
                        $actionResults[$actionName] = 'CopyFailed'
                        $actionFailure = $true
                        if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = 'PanelActionFailed' }
                    }
                }
            }
            'OpenClientFolder' {
                if ($null -eq $ExplorerProvider) {
                    $actionResults[$actionName] = 'OpenFolderUnavailable'
                    $actionFailure = $true
                    if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = 'PanelActionFailed' }
                }
                else {
                    try {
                        $providerOutput = @(& $ExplorerProvider ([pscustomobject]@{ Action = 'OpenClientFolder'; Path = $ClientFolder }))
                        if ($providerOutput.Count -eq 0) {
                            $actionCheck = Test-TUProviderActionResult -ProviderResult $null `
                                -Action $actionName -ExpectedResult 'Opened'
                        }
                        elseif ($providerOutput.Count -ne 1) {
                            $actionCheck = [pscustomobject]@{
                                Status = 'Ambiguous'
                                ReasonCode = 'PanelActionResultAmbiguous'
                                Reason = 'The explorer provider returned more than one action result.'
                            }
                        }
                        else {
                            $actionCheck = Test-TUProviderActionResult -ProviderResult $providerOutput[0] `
                                -Action $actionName -ExpectedResult 'Opened'
                        }
                        if ($actionCheck.Status -eq 'Succeeded') {
                            $actionResults[$actionName] = 'Opened'
                        }
                        else {
                            switch ($actionCheck.Status) {
                                'Missing' { $actionResults[$actionName] = 'OpenFolderResultMissing' }
                                'Unverified' { $actionResults[$actionName] = 'OpenFolderResultUnverified' }
                                'Ambiguous' { $actionResults[$actionName] = 'OpenFolderResultAmbiguous' }
                                default { $actionResults[$actionName] = 'OpenFolderFailed' }
                            }
                            $actionFailure = $true
                            if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = $actionCheck.ReasonCode }
                        }
                    }
                    catch {
                        $evidence['ExplorerError'] = $_.Exception.Message
                        $actionResults[$actionName] = 'OpenFolderFailed'
                        $actionFailure = $true
                        if ($null -eq $actionFailureReasonCode) { $actionFailureReasonCode = 'PanelActionFailed' }
                    }
                }
            }
        }
    }

    if ($refusedActions.Count -gt 0) { $evidence['RefusedActions'] = @($refusedActions) }

    if ($actionFailure) {
        $evidence['ClientName'] = $ClientName
        $evidence['ActionResults'] = $actionResults
        $blocked = New-TechnicianUiBlockedResult -ReasonCode $actionFailureReasonCode `
            -Reason 'One or more handoff panel actions did not return a positive provider result.' `
            -Evidence $evidence -GateId 'UI-HandoffPanel' -Choices @('RetryPanel', 'Stop') `
            -SafeDefault 'Stop' -Scope 'ClientHandoff'
        $blocked | Add-Member -NotePropertyName ClientName -NotePropertyValue $ClientName -Force
        $blocked | Add-Member -NotePropertyName ClientFolder -NotePropertyValue $ClientFolder -Force
        $blocked | Add-Member -NotePropertyName ActionsTaken -NotePropertyValue @($actionsTaken) -Force
        $blocked | Add-Member -NotePropertyName EnabledActions -NotePropertyValue @($enabled) -Force
        $blocked | Add-Member -NotePropertyName DisabledActions -NotePropertyValue @($disabled) -Force
        $blocked | Add-Member -NotePropertyName ActionResults -NotePropertyValue $actionResults -Force
        $blocked | Add-Member -NotePropertyName WindowShown -NotePropertyValue $windowShown -Force
        $blocked | Add-Member -NotePropertyName ClientNameDisplayed -NotePropertyValue $windowShown -Force
        $blocked | Add-Member -NotePropertyName TopMostRequested -NotePropertyValue $topMostRequested -Force
        $blocked | Add-Member -NotePropertyName ForegroundRequested -NotePropertyValue $foregroundRequested -Force
        $blocked | Add-Member -NotePropertyName ClosedBy -NotePropertyValue $closedBy -Force
        return $blocked
    }

    return [pscustomobject]@{
        Decision            = 'PanelClosed'
        ReasonCode          = $null
        ClientName          = $ClientName
        ClientFolder        = $ClientFolder
        ActionsTaken        = @($actionsTaken)
        EnabledActions      = @($enabled)
        DisabledActions     = @($disabled)
        ActionResults       = $actionResults
        WindowShown         = $windowShown
        ClientNameDisplayed = $windowShown
        TopMostRequested    = $topMostRequested
        ForegroundRequested = $foregroundRequested
        ClosedBy            = $closedBy
        Gate                = $null
        Evidence            = $evidence
        ClosedAtUtc         = [datetime]::UtcNow
    }
}

function Get-TechnicianUiDefaultProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PickerProvider', 'TypedPathProvider', 'InteractionProvider', 'HandoffPanelProvider',
            'ClipboardProvider', 'ExplorerProvider', 'DisplayProvider', 'SourceSelectorProvider',
            'SourceProtectionAttestationProvider', 'ClientNameProvider')]
        [string]$Name
    )

    switch ($Name) {
        'PickerProvider' {
            return {
                param($Request)
                try {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                }
                catch {
                    return [pscustomobject]@{ Decision = 'Unavailable'; Error = $_.Exception.Message }
                }
                try {
                    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                    $dialog.Description = $Request.Description
                    $dialog.ShowNewFolderButton = $false
                    $dialogResult = $dialog.ShowDialog()
                    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
                        return [pscustomobject]@{ Decision = 'Cancelled' }
                    }
                    if ([string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
                        return [pscustomobject]@{ Decision = 'Cancelled' }
                    }
                    return [pscustomobject]@{
                        Decision        = 'Selected'
                        Path            = $dialog.SelectedPath
                        SelectionMethod = 'Picker'
                    }
                }
                catch {
                    return [pscustomobject]@{ Decision = 'Unavailable'; Error = $_.Exception.Message }
                }
            }
        }
        'TypedPathProvider' {
            return {
                param($Request)
                $answer = Read-Host -Prompt ($Request.Description + ' Type the full folder path')
                return [pscustomobject]@{ Path = $answer; SelectionMethod = 'TypedPath' }
            }
        }
        'InteractionProvider' {
            return {
                param($Request)
                Write-Host ''
                Write-Host ('Gate: ' + $Request.GateId)
                if ($null -ne $Request.Scope) { Write-Host ('Scope: ' + [string]$Request.Scope) }
                Write-Host ('Reason: ' + $Request.Reason)
                if ($null -ne $Request.Evidence) {
                    foreach ($key in @($Request.Evidence.Keys)) {
                        Write-Host ('  ' + [string]$key + ': ' + [string]$Request.Evidence[$key])
                    }
                }
                Write-Host ('Choices: ' + (@($Request.Choices) -join ', '))
                Write-Host ('Safe default: ' + $Request.SafeDefault)
                $answer = Read-Host -Prompt 'Enter one of the listed choices'
                return [pscustomobject]@{ Response = $answer; Cancelled = $false; TimedOut = $false }
            }
        }
        'SourceSelectorProvider' {
            # Explicit technician source input for the default front door. The
            # documented folder browser answers first; the typed prompt is the
            # fallback, exactly like destination selection. The selector never
            # infers, enumerates, or scans a device, and it never claims
            # read-only protection: source protection evidence is a separate,
            # explicit step (SourceProtectionAttestationProvider).
            return {
                param($Request)
                $picker = Get-TechnicianUiDefaultProvider -Name 'PickerProvider'
                $typed = Get-TechnicianUiDefaultProvider -Name 'TypedPathProvider'
                $pickerRequest = [pscustomobject]@{
                    Description         = 'Select the read-only source to recover from.'
                    ShowNewFolderButton = $false
                    Purpose             = 'SourceSelection'
                }
                $pickerResult = $null
                try { $pickerResult = & $picker $pickerRequest } catch { $pickerResult = $null }
                if ($null -ne $pickerResult) {
                    if ($pickerResult -is [string]) {
                        if (-not [string]::IsNullOrWhiteSpace($pickerResult)) {
                            return [pscustomobject]@{ Selected = $true; Path = ([string]$pickerResult).Trim(); SelectionMethod = 'Picker'; Evidence = 'Technician selected the source in the folder browser.' }
                        }
                    }
                    else {
                        $pickerPath = Get-TUObjectPropertyValue -InputObject $pickerResult -Names @('Path', 'SelectedPath')
                        $pickerDecision = Get-TUObjectPropertyValue -InputObject $pickerResult -Names @('Decision', 'Result')
                        if (-not [string]::IsNullOrWhiteSpace([string]$pickerPath)) {
                            return [pscustomobject]@{ Selected = $true; Path = ([string]$pickerPath).Trim(); SelectionMethod = 'Picker'; Evidence = 'Technician selected the source in the folder browser.' }
                        }
                        if ($null -ne $pickerDecision -and ([string]$pickerDecision).ToUpperInvariant() -eq 'CANCELLED') {
                            return [pscustomobject]@{ Selected = $false; Path = $null; SelectionMethod = 'Picker'; Evidence = 'The technician cancelled the source folder selection.' }
                        }
                    }
                }
                $typedResult = $null
                try { $typedResult = & $typed ([pscustomobject]@{ Description = 'Source selection.' }) } catch { $typedResult = $null }
                $typedPath = $null
                if ($typedResult -is [string]) { $typedPath = [string]$typedResult }
                elseif ($null -ne $typedResult) { $typedPath = Get-TUObjectPropertyValue -InputObject $typedResult -Names @('Path') }
                if (-not [string]::IsNullOrWhiteSpace([string]$typedPath)) {
                    return [pscustomobject]@{ Selected = $true; Path = ([string]$typedPath).Trim(); SelectionMethod = 'TypedPath'; Evidence = 'Technician typed the source path.' }
                }
                return [pscustomobject]@{ Selected = $false; Path = $null; SelectionMethod = $null; Evidence = 'No source path was provided through the folder browser or the typed prompt.' }
            }
        }
        'SourceProtectionAttestationProvider' {
            # Explicit, fail-closed operator attestation for source protection.
            # It never measures the interface, never opens the device, and never
            # claims measured state: the recorded evidence is labeled an operator
            # attestation and is deliberately distinguishable from a measured
            # read-only or write-blocker observation. Anything other than the
            # exact confirmation word is a refusal.
            return {
                param($Request)
                Write-Host ''
                Write-Host ('Source protection evidence for: ' + [string]$Request.Path)
                Write-Host 'This records an OPERATOR ATTESTATION, not a measurement.'
                Write-Host 'Confirm only if a hardware write blocker (or a documented read-only state) protects this source.'
                $answer = Read-Host -Prompt 'Type ATTEST to record the operator attestation, or anything else to refuse'
                if ([string]$answer -eq 'ATTEST') {
                    return [pscustomobject]@{
                        Verified     = $true
                        EvidenceKind = 'OperatorAttestation'
                        Evidence     = 'Operator attestation: a hardware write blocker or documented read-only state protects the selected source.'
                    }
                }
                return [pscustomobject]@{
                    Verified     = $false
                    EvidenceKind = 'OperatorAttestation'
                    Evidence     = 'The operator did not confirm source protection, so no protection evidence is recorded.'
                }
            }
        }
        'ClientNameProvider' {
            # Explicit technician client input. The answer is returned as typed;
            # sanitizing and validation stay in the case-creation path
            # (Convert-RecoveryName), which remains fail-closed for empty,
            # reserved, or unusable names.
            return {
                param($Request)
                Write-Host ''
                Write-Host 'A client name is required before a job folder can be claimed.'
                $answer = Read-Host -Prompt 'Type the client name for this case'
                if ([string]::IsNullOrWhiteSpace([string]$answer)) {
                    return [pscustomobject]@{ ClientName = $null; Cancelled = $true; Evidence = 'No client name was entered.' }
                }
                return [pscustomobject]@{ ClientName = ([string]$answer).Trim(); Cancelled = $false; Evidence = 'Client name entered by the technician.' }
            }
        }
        'DisplayProvider' {
            return {
                param($Request)
                Write-Host ''
                Write-Host ('Destination review (' + [string]$Request.Purpose + ')')
                Write-Host ('  Path: ' + [string]$Request.Path)
                Write-Host ('  Selection method: ' + [string]$Request.SelectionMethod)
                Write-Host ('  Physical-disk separation: ' + [string]$Request.SafetyDecision)
                if ($null -ne $Request.DestinationEvidence) {
                    foreach ($key in @($Request.DestinationEvidence.Keys)) {
                        Write-Host ('  ' + [string]$key + ': ' + [string]$Request.DestinationEvidence[$key])
                    }
                }
                return [pscustomobject]@{ Result = 'Displayed' }
            }
        }
        'ClipboardProvider' {
            return {
                param($Request)
                Set-Clipboard -Value $Request.ClientName -ErrorAction Stop
                return [pscustomobject]@{ Success = $true; Result = 'Copied'; ClientName = $Request.ClientName }
            }
        }
        'ExplorerProvider' {
            return {
                param($Request)
                if ($null -eq $Request) { throw 'The client folder request is missing.' }
                $fileName = 'explorer.exe'
                if (-not [string]::IsNullOrEmpty($env:SystemRoot)) {
                    $fileName = [System.IO.Path]::Combine($env:SystemRoot, 'explorer.exe')
                }
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = $fileName
                $startInfo.Arguments = '"' + ([string]$Request.Path).Replace('"', '') + '"'
                $startInfo.UseShellExecute = $false
                $process = [System.Diagnostics.Process]::Start($startInfo)
                return [pscustomobject]@{
                    Success  = $true
                    Id       = $process.Id
                    FileName = $fileName
                    Path     = $Request.Path
                    Result   = 'Opened'
                }
            }
        }
        'HandoffPanelProvider' {
            return {
                param($Request)
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                [System.Windows.Forms.Application]::EnableVisualStyles()

                $state = @{
                    ActionsTaken        = New-Object System.Collections.ArrayList
                    ClosedBy            = $null
                    ForegroundRequested = $false
                }
                # Captured by GetNewClosure below: a closure keeps its own scope, so
                # the module-scope P/Invoke source is copied into a local first.
                $foregroundSource = $script:TUForegroundSource

                $form = New-Object System.Windows.Forms.Form
                $form.Text = [string]$Request.Title
                $form.TopMost = $true
                $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
                $form.MinimizeBox = $false
                $form.MaximizeBox = $false
                $form.ShowInTaskbar = $true
                $form.AutoSize = $true
                $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink

                $layout = New-Object System.Windows.Forms.FlowLayoutPanel
                $layout.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
                $layout.WrapContents = $false
                $layout.AutoSize = $true
                $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
                $layout.Padding = New-Object System.Windows.Forms.Padding(16)
                $form.Controls.Add($layout)

                $caption = New-Object System.Windows.Forms.Label
                $caption.Text = 'Client case'
                $caption.AutoSize = $true
                $caption.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular)
                $layout.Controls.Add($caption)

                $nameLabel = New-Object System.Windows.Forms.Label
                $nameLabel.Text = [string]$Request.ClientName
                $nameLabel.AutoSize = $true
                $nameLabel.Font = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
                $layout.Controls.Add($nameLabel)

                $folderLabel = New-Object System.Windows.Forms.Label
                if ([string]::IsNullOrWhiteSpace([string]$Request.ClientFolder)) {
                    $folderLabel.Text = 'No client folder is attached to this handoff.'
                }
                else {
                    $folderLabel.Text = 'Case folder: ' + [string]$Request.ClientFolder
                }
                $folderLabel.AutoSize = $true
                $layout.Controls.Add($folderLabel)

                $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
                $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
                $buttons.AutoSize = $true
                $buttons.WrapContents = $false
                $layout.Controls.Add($buttons)

                foreach ($action in @($Request.EnabledActions)) {
                    $button = New-Object System.Windows.Forms.Button
                    $button.AutoSize = $true
                    switch ([string]$action) {
                        'Close' { $button.Text = 'Close' }
                        'CopyClientName' { $button.Text = 'Copy client name' }
                        'OpenClientFolder' { $button.Text = 'Open client folder' }
                        default { $button.Text = 'Close' }
                    }
                    $capturedAction = [string]$action
                    $handler = {
                        [void]$state.ActionsTaken.Add($capturedAction)
                        if ($capturedAction -eq 'Close') {
                            $state.ClosedBy = 'Close'
                            $form.Close()
                        }
                    }.GetNewClosure()
                    $button.Add_Click($handler)
                    if ([string]$action -eq 'Close') { $form.CancelButton = $button }
                    $buttons.Controls.Add($button)
                }

                $shownHandler = {
                    $form.Activate()
                    try {
                        if ($null -eq ('RecoveryNative.WindowFocus' -as [type])) {
                            Add-Type -Name 'WindowFocus' -Namespace 'RecoveryNative' `
                                -MemberDefinition $foregroundSource -ErrorAction Stop
                        }
                        $handle = $form.Handle
                        [void][RecoveryNative.WindowFocus]::ShowWindow($handle, 9)
                        [void][RecoveryNative.WindowFocus]::SetForegroundWindow($handle)
                        $state.ForegroundRequested = $true
                    }
                    catch {
                        # Foreground activation is best effort and never a failure
                        # of the handoff panel itself.
                        $state.ForegroundRequested = $false
                    }
                }.GetNewClosure()
                $form.add_Shown($shownHandler)

                $form.ShowDialog() | Out-Null
                $form.Dispose()

                $lastAction = $null
                if ($state.ActionsTaken.Count -gt 0) { $lastAction = [string]$state.ActionsTaken[$state.ActionsTaken.Count - 1] }
                return [pscustomobject]@{
                    Success             = $true
                    ActionsTaken        = @($state.ActionsTaken)
                    LastAction          = $lastAction
                    ClosedBy            = $state.ClosedBy
                    WindowShown         = $true
                    TopMostRequested    = $true
                    ForegroundRequested = [bool]$state.ForegroundRequested
                }
            }
        }
    }
}

Export-ModuleMember -Function @('Select-DestinationFolder', 'Show-DestinationFolderPicker',
    'Show-RecoveryManualGate', 'Show-RecoveryHandoffPanel', 'Get-TechnicianUiDefaultProvider')
