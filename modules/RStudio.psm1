<#
.SYNOPSIS
R-Studio for Windows launch-only handoff adapter for the recovery workflow.

.DESCRIPTION
This module owns the R-Studio handoff boundary described by
docs/IMPLEMENTATION-SPEC.md section 2.8 and TEST-MATRIX section 6 (R-01 to R-10).

Supported surface (vendor evidence, research/rstudio-official.md):
- R-Tools R-Studio for Windows is disambiguated from R-Studio Agent, R-Studio
  Emergency, and Posit RStudio.
  https://www.r-studio.com/Data_Recovery_Download.shtml
- The only vendor-documented switches used by this workflow are -safe and
  -log <filename>. The documented switch list has no path, folder, project,
  report, scan, recovery, source-selection, destination-selection, or
  window-activation argument, so none is constructed here.
  https://www.r-studio.com/Unformat_Help/r-studioswitches.html
- -safe disables automatic partition search and file-system recognition. It is
  NOT documented as a write-protection switch, so every analysis, scan, marking,
  recovery, and destination action remains a technician action in the main panel.
  https://www.r-studio.com/Unformat_Help/r-studio_main_panel.html
- Administrative privileges are required by the vendor; a failed elevation or
  launch is reported, never retried against another product or path.
  https://www.r-studio.com/Unformat_Help/systemrequirements.html

Unknown / manual boundary: the installed executable path, runtime version,
window behavior, foreground activation result, and main-panel readiness are not
documented vendor contracts. They are recorded as evidence and validated by the
owner-live gate (TEST-MATRIX L-11). This module never selects a source, starts a
scan, marks files, recovers, chooses a destination, or enables a write-capable
vendor feature.

All operating-system and application operations are injected scriptblock seams.
The parameterized seams are the only place a process, shell, window, or UI call
can originate, so unit tests record calls instead of performing them.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RSHandoffState = 'READY_FOR_HANDOFF'
$script:RSProductName = 'RStudio'
$script:RSProductNames = @('RStudio')
$script:RSSafeSwitch = '-safe'
$script:RSLogSwitch = '-log'

# Documented vendor download names for the Emergency media creator and the
# network Agent, plus the installer file itself. None of them is the installed
# GUI application this workflow may launch.
$script:RSInstallerNames = @('rstudio9.exe', 'rstudioemg9.exe', 'rstudioagenten9.exe',
    'rstudioagentportableen9.exe')
$script:RSWrongUtilityTokens = @('agent', 'emg', 'emergency')

# State-object flags that must all be true when they are present in the state
# snapshot handed to the handoff.
$script:RSStateEvidenceFlags = @('FileScavengerCloseVerified', 'OutputVerified',
    'SourceIdentityVerified', 'DestinationIdentityVerified', 'LogDurable', 'StateDurable')

$script:RSForegroundSource = @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@

function Test-RSObjectProperty {
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

function Get-RSObjectPropertyValue {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        if (Test-RSObjectProperty -InputObject $InputObject -Name $name) {
            if ($InputObject -is [System.Collections.IDictionary]) {
                return $InputObject[$name]
            }
            return $InputObject.$name
        }
    }
    return $null
}

function Get-RSFirstNonNullPropertyValue {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        if (Test-RSObjectProperty -InputObject $InputObject -Name $name) {
            if ($InputObject -is [System.Collections.IDictionary]) {
                $value = $InputObject[$name]
            }
            else {
                $value = $InputObject.$name
            }
            if ($null -ne $value -and
                (-not ($value -is [string]) -or -not [string]::IsNullOrWhiteSpace([string]$value))) {
                return $value
            }
        }
    }
    return $null
}

function Test-RSAbsolutePath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # Character validation must run before any System.IO.Path call: on Windows
    # IsPathRooted throws ArgumentException ('Illegal characters in path') for a
    # path containing a quote, and a refusal must never surface as an unhandled
    # exception.
    if (Test-RSPathIllegalCharacter -Path $Path) { return $false }
    try {
        if ([System.IO.Path]::IsPathRooted($Path)) { return $true }
    }
    catch {
        return $false
    }
    # Windows drive-letter and UNC forms are not recognized by IsPathRooted on a
    # non-Windows host, so they are recognized explicitly here.
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\[^\\]+\\') { return $true }
    return $false
}

function Test-RSPathIllegalCharacter {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    foreach ($character in $Path.ToCharArray()) {
        if ([char]::IsControl($character)) { return $true }
    }
    if ($Path.Contains('"')) { return $true }
    if ($Path.Contains('*')) { return $true }
    if ($Path.Contains('?')) { return $true }
    if ($Path -match '[<>|]') { return $true }
    return $false
}

function Get-RSPathLeaf {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $trimmed = $Path.TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($trimmed)) { return '' }
    $parts = $trimmed -split '[\\/]'
    return $parts[$parts.Count - 1]
}

function Get-RSPathParent {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $trimmed = $Path.TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($trimmed)) { return '' }
    $parts = $trimmed -split '[\\/]'
    if ($parts.Count -le 1) { return '' }
    $parentParts = @($parts[0..($parts.Count - 2)])
    return ($parentParts -join '\')
}

function Test-RSPathText {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-RSAbsolutePath -Path $Path)) { return $false }
    if ($Path -match '[\x00-\x1F]') { return $false }
    if ($Path.Contains('"')) { return $false }
    if ($Path.Contains('*')) { return $false }
    if ($Path.Contains('?')) { return $false }
    if ($Path -match '[<>|]') { return $false }
    return $true
}

function ConvertTo-RStudioArgumentString {
    [CmdletBinding()]
    param([AllowNull()][string[]]$Arguments)

    if ($null -eq $Arguments) { return '' }
    $builder = New-Object System.Text.StringBuilder
    $first = $true
    foreach ($argument in $Arguments) {
        $value = $argument
        if ($null -eq $value) { $value = '' }
        if (-not $first) { [void]$builder.Append(' ') }
        $first = $false
        [void]$builder.Append([char]34)
        $backslashes = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq [char]92) {
                $backslashes = $backslashes + 1
                continue
            }
            if ($character -eq [char]34) {
                [void]$builder.Append([char]92, ($backslashes * 2) + 1)
                [void]$builder.Append([char]34)
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$builder.Append([char]92, $backslashes)
                $backslashes = 0
            }
            [void]$builder.Append($character)
        }
        if ($backslashes -gt 0) {
            # Backslashes immediately before the closing quote are doubled.
            [void]$builder.Append([char]92, $backslashes * 2)
        }
        [void]$builder.Append([char]34)
    }
    return $builder.ToString()
}

function New-RStudioManualGate {
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
        GateId                  = $GateId
        Reason                  = $Reason
        Evidence                = $Evidence
        Choices                 = @($Choices)
        SafeDefault             = $SafeDefault
        Scope                   = $Scope
        RequiresOperatorDecision = $true
        AutoContinueAllowed     = $false
    }
}

function New-RSHandoffGate {
    [CmdletBinding()]
    param([hashtable]$Evidence)

    return New-RStudioManualGate -GateId 'G-10' `
        -Reason 'R-Studio is launched in launch-only mode. Confirm the R-Studio main panel on the technician desktop, then perform every source selection, partition search, scan, marking, recovery, and destination action manually.' `
        -Evidence $Evidence `
        -Choices @('Continue', 'Pause', 'Abort') `
        -SafeDefault 'Pause' `
        -Scope 'RStudioMainPanelHandoff'
}

function New-RSObservationGate {
    [CmdletBinding()]
    param([hashtable]$Evidence)

    return New-RStudioManualGate -GateId 'G-05' `
        -Reason 'R-Studio process, window, or main-panel readiness could not be observed from the supplied evidence. Do not infer analysis or recovery progress from process state.' `
        -Evidence $Evidence `
        -Choices @('PanelVisible', 'PanelNotVisible', 'Pause') `
        -SafeDefault 'Pause' `
        -Scope 'RStudioObservation'
}

function New-RSCheck {
    [CmdletBinding()]
    param([string]$Name, [string]$Result, [string]$Detail)

    return [pscustomobject]@{ Name = $Name; Result = $Result; Detail = $Detail }
}

function Test-RStudioExecutableIdentity {
    [CmdletBinding()]
    param([AllowNull()][object]$Executable)

    $evidence = @{}
    if ($null -eq $Executable) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableNotProvided'; Detail = 'No executable identity object was supplied.'; Evidence = $evidence }
    }

    $path = Get-RSObjectPropertyValue -InputObject $Executable -Names @('Path', 'ExecutablePath', 'FullName')
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutablePathMissing'; Detail = 'The executable identity has no path.'; Evidence = $evidence }
    }
    $path = [string]$path
    $evidence['ExecutablePath'] = $path

    if (-not (Test-RSPathText -Path $path)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutablePathInvalid'; Detail = 'The executable path is not an absolute path without quoting or wildcard text.'; Evidence = $evidence }
    }

    $leaf = (Get-RSPathLeaf -Path $path)
    $leafLower = $leaf.ToLowerInvariant()
    if ($script:RSInstallerNames -contains $leafLower) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'InstallerNotApplicationExecutable'; Detail = 'The candidate is the vendor installer, not the installed R-Studio for Windows application.'; Evidence = $evidence }
    }
    foreach ($token in $script:RSWrongUtilityTokens) {
        if ($leafLower.Contains($token)) {
            return [pscustomobject]@{ Ok = $false; ReasonCode = 'AgentOrEmergencyExecutable'; Detail = 'The candidate name matches the documented R-Studio Agent or Emergency utility naming.'; Evidence = $evidence }
        }
    }

    $product = Get-RSObjectPropertyValue -InputObject $Executable -Names @('Product')
    if ([string]::IsNullOrWhiteSpace([string]$product)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableProductUnknown'; Detail = 'The candidate has no product identity.'; Evidence = $evidence }
    }
    $product = [string]$product
    $evidence['Product'] = $product
    if (-not ($script:RSProductNames -contains $product)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableProductNotRStudio'; Detail = 'The candidate is not R-Studio for Windows.'; Evidence = $evidence }
    }

    $contradiction = Get-RSObjectPropertyValue -InputObject $Executable -Names @('ContradictionDetected', 'IsContradictory')
    if ($null -ne $contradiction -and
        ($contradiction -isnot [bool] -or [bool]$contradiction)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityUnverified'; Detail = 'The candidate identity contains contradictory evidence.'; Evidence = $evidence }
    }

    $identityStatus = Get-RSObjectPropertyValue -InputObject $Executable -Names @('IdentityStatus')
    $isVerified = Get-RSObjectPropertyValue -InputObject $Executable -Names @('IsVerified')
    $statusVerified = $null
    if (Test-RSObjectProperty -InputObject $Executable -Name 'IdentityStatus') {
        if ($identityStatus -isnot [string]) {
            return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityUnverified'; Detail = 'The candidate identity status is not a string decision.'; Evidence = $evidence }
        }
        $statusVerified = ([string]$identityStatus).ToUpperInvariant() -eq 'VERIFIED'
    }
    if (Test-RSObjectProperty -InputObject $Executable -Name 'IsVerified') {
        if ($isVerified -isnot [bool]) {
            return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityUnverified'; Detail = 'The candidate verification evidence is not a Boolean decision.'; Evidence = $evidence }
        }
        if ($null -ne $statusVerified -and [bool]$isVerified -ne [bool]$statusVerified) {
            return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityUnverified'; Detail = 'The candidate identity status and verification evidence contradict each other.'; Evidence = $evidence }
        }
        $statusVerified = [bool]$isVerified
    }
    if ($statusVerified -ne $true) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityUnverified'; Detail = 'The candidate identity is not recorded as verified.'; Evidence = $evidence }
    }
    $evidence['IdentityStatus'] = 'Verified'

    $fileVersionValue = Get-RSObjectPropertyValue -InputObject $Executable -Names @('FileVersion')
    $productVersion = Get-RSObjectPropertyValue -InputObject $Executable -Names @('ProductVersion')
    $evidenceSourceValue = Get-RSObjectPropertyValue -InputObject $Executable -Names @('EvidenceSource')
    $fileVersion = [string]$fileVersionValue
    $evidenceSource = [string]$evidenceSourceValue
    $companyName = Get-RSFirstNonNullPropertyValue -InputObject $Executable -Names @('CompanyName', 'Publisher', 'PublisherName', 'Vendor')
    $productMetadata = Get-RSFirstNonNullPropertyValue -InputObject $Executable -Names @('ProductName', 'OriginalFilename', 'FileDescription', 'DisplayName')
    if ($null -ne $fileVersionValue) { $evidence['FileVersion'] = [string]$fileVersionValue }
    if ($null -ne $productVersion) { $evidence['ProductVersion'] = [string]$productVersion }
    if ($null -ne $evidenceSourceValue) { $evidence['EvidenceSource'] = [string]$evidenceSourceValue }
    if ($null -ne $companyName) { $evidence['CompanyName'] = [string]$companyName }

    if ($fileVersionValue -isnot [string] -or [string]::IsNullOrWhiteSpace($fileVersion) -or
        $evidenceSourceValue -isnot [string] -or [string]::IsNullOrWhiteSpace($evidenceSource)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityEvidenceUnverified'; Detail = 'The executable identity has no non-empty string file version and evidence source.'; Evidence = $evidence }
    }

    $existsPropertyName = $null
    if (Test-RSObjectProperty -InputObject $Executable -Name 'Exists') { $existsPropertyName = 'Exists' }
    elseif (Test-RSObjectProperty -InputObject $Executable -Name 'PathExists') { $existsPropertyName = 'PathExists' }
    if ($null -eq $existsPropertyName) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableOnDiskUnverified'; Detail = 'The executable identity does not include positive on-disk existence evidence.'; Evidence = $evidence }
    }
    $exists = Get-RSObjectPropertyValue -InputObject $Executable -Names @($existsPropertyName)
    if ($exists -isnot [bool] -or -not [bool]$exists) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableMissingOnDisk'; Detail = 'The verified candidate path does not exist on this machine.'; Evidence = $evidence }
    }

    $readable = Get-RSObjectPropertyValue -InputObject $Executable -Names @('Readable')
    if ($null -ne $readable -and ($readable -isnot [bool] -or -not [bool]$readable)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableUnreadable'; Detail = 'The verified candidate path is not readable.'; Evidence = $evidence }
    }

    $metadataText = (([string]$productMetadata) + ' ' + ([string]$companyName)).ToLowerInvariant()
    if ($metadataText -match 'posit' -or $metadataText -match 'agent' -or $metadataText -match 'emergency') {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableProductNotRTools'; Detail = 'The executable metadata identifies Posit, Agent, or Emergency rather than R-Tools R-Studio for Windows.'; Evidence = $evidence }
    }
    if ($metadataText -notmatch 'r[ -]?studio') {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableProductNotRTools'; Detail = 'The executable metadata does not positively identify R-Studio for Windows.'; Evidence = $evidence }
    }

    $ownerValidated = Get-RSObjectPropertyValue -InputObject $Executable -Names @('OwnerValidated')
    $ownerEvidence = Get-RSObjectPropertyValue -InputObject $Executable -Names @('OwnerEvidence', 'ValidationEvidence')
    $hasOwnerEvidence = ($ownerValidated -is [bool]) -and $ownerValidated -and
        (-not [string]::IsNullOrWhiteSpace([string]$ownerEvidence))
    $fileVersionInfoVerified = Get-RSObjectPropertyValue -InputObject $Executable -Names @('FileVersionInfoVerified', 'VersionInfoVerified')
    $hasFileVersionInfo = ($fileVersionInfoVerified -is [bool]) -and $fileVersionInfoVerified -and
        (@($evidenceSource -split '\+') -contains 'FileVersionInfo')
    $publisherValues = New-Object System.Collections.ArrayList
    foreach ($publisherField in @('CompanyName', 'Publisher', 'PublisherName', 'Vendor')) {
        $publisherValue = Get-RSObjectPropertyValue -InputObject $Executable -Names @($publisherField)
        if ($null -ne $publisherValue -and -not [string]::IsNullOrWhiteSpace([string]$publisherValue)) {
            [void]$publisherValues.Add(([string]$publisherValue).Trim())
        }
    }
    $trustedPublisherPattern = '(?i)^r[ -]?tools(?:\s+technology)?(?:\s*,?\s*inc\.?)?$'
    $hasTrustedPublisher = $false
    $hasConflictingPublisher = $false
    foreach ($publisherValue in @($publisherValues)) {
        if ([string]$publisherValue -match $trustedPublisherPattern) {
            $hasTrustedPublisher = $true
        }
        else {
            $hasConflictingPublisher = $true
        }
    }
    if ($hasConflictingPublisher -or -not (($hasFileVersionInfo -and $hasTrustedPublisher) -or $hasOwnerEvidence)) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'ExecutableIdentityEvidenceUnverified'; Detail = 'The executable lacks positive FileVersionInfo/trusted R-Tools evidence or explicit owner evidence.'; Evidence = $evidence }
    }
    if ($hasOwnerEvidence) { $evidence['OwnerEvidence'] = [string]$ownerEvidence }

    return [pscustomobject]@{ Ok = $true; ReasonCode = $null; Detail = 'Executable identity verified.'; Evidence = $evidence }
}

function Test-RStudioLogPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [scriptblock]$LogPathSafetyValidator
    )

    $evidence = @{ LogPath = $LogPath }
    if ($null -eq $LogPathSafetyValidator) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'LogPathSafetyUnverified'; Detail = 'No log-path safety validator was supplied, so the log destination cannot be proven separate from the source.'; Evidence = $evidence }
    }

    try {
        $validatorResult = & $LogPathSafetyValidator $LogPath
    }
    catch {
        $evidence['LogPathSafetyError'] = $_.Exception.Message
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'LogPathSafetyUnverified'; Detail = 'The log-path safety validator failed.'; Evidence = $evidence }
    }

    if ($null -eq $validatorResult) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'LogPathSafetyUnverified'; Detail = 'The log-path safety validator returned no decision.'; Evidence = $evidence }
    }

    $allowed = Get-RSObjectPropertyValue -InputObject $validatorResult -Names @('Allowed', 'IsSafe')
    if ($null -eq $allowed) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'LogPathSafetyUnverified'; Detail = 'The log-path safety validator returned no decision.'; Evidence = $evidence }
    }

    $reasonCode = Get-RSFirstNonNullPropertyValue -InputObject $validatorResult -Names @('ReasonCode', 'Decision')
    if ($null -ne $reasonCode) { $evidence['LogPathSafetyReasonCode'] = [string]$reasonCode }
    $validatorEvidence = Get-RSObjectPropertyValue -InputObject $validatorResult -Names @('DestinationEvidence', 'Evidence')
    if ($null -ne $validatorEvidence) { $evidence['LogPathSafetyEvidence'] = $validatorEvidence }

    if ($allowed -isnot [bool]) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'LogPathSafetyUnverified'; Detail = 'The log-path safety validator returned a non-Boolean decision.'; Evidence = $evidence }
    }

    if (-not [bool]$allowed) {
        return [pscustomobject]@{ Ok = $false; ReasonCode = 'LogPathUnsafe'; Detail = 'The configured log destination is not proven safe.'; Evidence = $evidence }
    }

    $evidence['LogPathSafetyReasonCode'] = $null
    return [pscustomobject]@{ Ok = $true; ReasonCode = $null; Detail = 'Log destination proven safe.'; Evidence = $evidence }
}

function New-RStudioArgumentList {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$LogPath)

    $evidence = @{}
    $checks = New-Object System.Collections.ArrayList
    $arguments = New-Object System.Collections.ArrayList
    [void]$arguments.Add($script:RSSafeSwitch)
    $includesLog = $false

    if ($null -ne $LogPath -and $LogPath.Length -gt 0) {
        if (-not (Test-RSPathText -Path $LogPath)) {
            [void]$checks.Add((New-RSCheck -Name 'LogArgument' -Result 'Failed' -Detail 'The configured log path is not a valid absolute path.'))
            return [pscustomobject]@{
                Decision    = 'Blocked'
                ReasonCode  = 'LogPathInvalid'
                Arguments   = $null
                IncludesLog = $false
                LogPath     = $null
                Checks      = @($checks)
                Evidence    = $evidence
            }
        }
        [void]$arguments.Add($script:RSLogSwitch)
        [void]$arguments.Add($LogPath)
        $includesLog = $true
        $evidence['LogPath'] = $LogPath
        [void]$checks.Add((New-RSCheck -Name 'LogArgument' -Result 'Passed' -Detail 'The log path is added as the only -log argument.'))
    }
    else {
        [void]$checks.Add((New-RSCheck -Name 'LogArgument' -Result 'Skipped' -Detail 'No log path is configured; only -safe is passed.'))
    }

    return [pscustomobject]@{
        Decision    = 'Ready'
        ReasonCode  = $null
        Arguments   = @($arguments)
        IncludesLog = $includesLog
        LogPath     = $LogPath
        Checks      = @($checks)
        Evidence    = $evidence
    }
}

function Test-RStudioHandoffPreconditions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$State,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Executable,
        [AllowNull()][AllowEmptyString()][string]$LogPath,
        [scriptblock]$LogPathSafetyValidator,
        [scriptblock]$FreshEvidenceProvider
    )

    $checks = New-Object System.Collections.ArrayList
    $evidence = @{}
    $reasonCode = $null

    $stateName = $null
    if ($State -is [string]) {
        $stateName = $State
    }
    else {
        $rawStateName = Get-RSObjectPropertyValue -InputObject $State -Names @('CurrentState', 'State', 'StateName')
        if ($null -ne $rawStateName) { $stateName = [string]$rawStateName }
    }
    $normalizedState = ''
    if ($null -ne $stateName) { $normalizedState = $stateName.ToUpperInvariant() }
    $evidence['State'] = $normalizedState

    if ($normalizedState -ne $script:RSHandoffState) {
        $reasonCode = 'StateNotReadyForHandoff'
        [void]$checks.Add((New-RSCheck -Name 'HandoffState' -Result 'Failed' -Detail 'The case state is not READY_FOR_HANDOFF.'))
    }
    else {
        [void]$checks.Add((New-RSCheck -Name 'HandoffState' -Result 'Passed' -Detail 'The case state is READY_FOR_HANDOFF.'))
    }

    if ($null -eq $reasonCode) {
        $incomplete = New-Object System.Collections.ArrayList
        if ($null -eq $State -or $State -is [string]) {
            foreach ($flag in $script:RSStateEvidenceFlags) {
                [void]$incomplete.Add($flag)
            }
        }
        else {
            foreach ($flag in $script:RSStateEvidenceFlags) {
                if (-not (Test-RSObjectProperty -InputObject $State -Name $flag)) {
                    [void]$incomplete.Add($flag)
                    continue
                }
                $value = $State.$flag
                if ($value -isnot [bool] -or -not [bool]$value) { [void]$incomplete.Add($flag) }
            }
        }
        if ($incomplete.Count -gt 0) {
            $reasonCode = 'StateEvidenceIncomplete'
            $evidence['IncompleteStateEvidence'] = @($incomplete)
            [void]$checks.Add((New-RSCheck -Name 'HandoffEvidence' -Result 'Failed' -Detail 'The state object does not carry complete handoff evidence.'))
        }
        else {
            [void]$checks.Add((New-RSCheck -Name 'HandoffEvidence' -Result 'Passed' -Detail 'All required handoff evidence flags are true in the state object.'))
        }
    }

    if ($null -eq $reasonCode) {
        $executableResult = Test-RStudioExecutableIdentity -Executable $Executable
        foreach ($key in $executableResult.Evidence.Keys) {
            $evidence['Executable' + $key] = $executableResult.Evidence[$key]
        }
        if (-not $executableResult.Ok) {
            $reasonCode = $executableResult.ReasonCode
            [void]$checks.Add((New-RSCheck -Name 'ExecutableIdentity' -Result 'Failed' -Detail $executableResult.Detail))
        }
        else {
            [void]$checks.Add((New-RSCheck -Name 'ExecutableIdentity' -Result 'Passed' -Detail $executableResult.Detail))
        }
    }

    if ($null -eq $reasonCode -and $null -ne $LogPath -and $LogPath.Length -gt 0) {
        if (-not (Test-RSPathText -Path $LogPath)) {
            $reasonCode = 'LogPathInvalid'
            [void]$checks.Add((New-RSCheck -Name 'LogPath' -Result 'Failed' -Detail 'The configured log path is not a valid absolute path.'))
        }
        else {
            $logResult = Test-RStudioLogPathSafety -LogPath $LogPath -LogPathSafetyValidator $LogPathSafetyValidator
            foreach ($key in $logResult.Evidence.Keys) {
                $evidence[$key] = $logResult.Evidence[$key]
            }
            if (-not $logResult.Ok) {
                $reasonCode = $logResult.ReasonCode
                [void]$checks.Add((New-RSCheck -Name 'LogPath' -Result 'Failed' -Detail $logResult.Detail))
            }
            else {
                [void]$checks.Add((New-RSCheck -Name 'LogPath' -Result 'Passed' -Detail $logResult.Detail))
            }
        }
    }

    if ($null -eq $reasonCode) {
        if ($null -eq $FreshEvidenceProvider) {
            $evidence['FreshEvidenceSource'] = 'NotProvided'
            [void]$checks.Add((New-RSCheck -Name 'FreshHandoffEvidence' -Result 'Skipped' -Detail 'No fresh evidence provider was supplied; the durable READY_FOR_HANDOFF state is the recorded evidence.'))
        }
        else {
            $freshResult = $null
            try {
                $freshResult = & $FreshEvidenceProvider $State
            }
            catch {
                $evidence['FreshEvidenceError'] = $_.Exception.Message
                $reasonCode = 'FreshEvidenceUnverified'
                [void]$checks.Add((New-RSCheck -Name 'FreshHandoffEvidence' -Result 'Failed' -Detail 'The fresh evidence provider failed.'))
            }
            if ($null -eq $reasonCode -and $null -eq $freshResult) {
                $reasonCode = 'FreshEvidenceUnverified'
                [void]$checks.Add((New-RSCheck -Name 'FreshHandoffEvidence' -Result 'Failed' -Detail 'The fresh evidence provider returned no evidence.'))
            }
            if ($null -eq $reasonCode) {
                if (-not (Test-RSObjectProperty -InputObject $freshResult -Name 'Success') -or
                    $freshResult.Success -isnot [bool] -or -not [bool]$freshResult.Success) {
                    $reasonCode = 'FreshEvidenceUnverified'
                    [void]$checks.Add((New-RSCheck -Name 'FreshHandoffEvidence' -Result 'Failed' -Detail 'The fresh evidence provider did not return an explicit Success=true result.'))
                }
            }
            if ($null -eq $reasonCode) {
                $failed = New-Object System.Collections.ArrayList
                foreach ($flag in $script:RSStateEvidenceFlags) {
                    if (-not (Test-RSObjectProperty -InputObject $freshResult -Name $flag)) {
                        [void]$failed.Add($flag)
                        continue
                    }
                    $value = $freshResult.$flag
                    if ($value -isnot [bool] -or -not [bool]$value) { [void]$failed.Add($flag) }
                }
                if ($failed.Count -gt 0) {
                    $reasonCode = 'FreshEvidenceFailed'
                    $evidence['FailedFreshEvidence'] = @($failed)
                    [void]$checks.Add((New-RSCheck -Name 'FreshHandoffEvidence' -Result 'Failed' -Detail 'Fresh handoff evidence is incomplete.'))
                }
                else {
                    $evidence['FreshEvidenceSource'] = 'Provider'
                    [void]$checks.Add((New-RSCheck -Name 'FreshHandoffEvidence' -Result 'Passed' -Detail 'Fresh handoff evidence is complete and explicitly successful.'))
                }
            }
        }
    }

    $allowed = $false
    $decision = 'Blocked'
    if ($null -eq $reasonCode) {
        $allowed = $true
        $decision = 'Allowed'
    }

    return [pscustomobject]@{
        Allowed        = $allowed
        Decision       = $decision
        ReasonCode     = $reasonCode
        Checks         = @($checks)
        Evidence       = $evidence
        EvaluatedAtUtc = [datetime]::UtcNow
    }
}

function Request-RStudioForegroundActivation {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ProcessIdentity,
        [scriptblock]$ActivationProvider
    )

    $evidence = @{}
    if ($null -eq $ProcessIdentity) {
        return [pscustomobject]@{
            Result        = 'Unavailable'
            Activated     = $false
            ReasonCode    = 'ProcessIdentityMissing'
            Detail        = 'No verified process identity is available for a foreground request.'
            IsBestEffort  = $true
            Blocking      = $false
            Evidence      = $evidence
        }
    }

    if ($null -eq $ActivationProvider) {
        return [pscustomobject]@{
            Result       = 'NotAttempted'
            Activated    = $false
            ReasonCode   = 'ActivationProviderUnavailable'
            Detail       = 'No activation seam was supplied; the foreground request was not attempted.'
            IsBestEffort = $true
            Blocking     = $false
            Evidence     = $evidence
        }
    }

    try {
        $providerResult = & $ActivationProvider $ProcessIdentity
    }
    catch {
        $evidence['ActivationError'] = $_.Exception.Message
        return [pscustomobject]@{
            Result       = 'Failed'
            Activated    = $false
            ReasonCode   = 'ActivationFailed'
            Detail       = 'The foreground activation seam failed.'
            IsBestEffort = $true
            Blocking     = $false
            Evidence     = $evidence
        }
    }

    $result = Get-RSObjectPropertyValue -InputObject $providerResult -Names @('Result', 'Decision')
    $reasonCode = Get-RSObjectPropertyValue -InputObject $providerResult -Names @('ReasonCode')
    $providerEvidence = Get-RSObjectPropertyValue -InputObject $providerResult -Names @('Evidence', 'Detail')
    if ($null -ne $providerEvidence) { $evidence['ActivationEvidence'] = $providerEvidence }

    if ($null -eq $result) {
        return [pscustomobject]@{
            Result       = 'Unavailable'
            Activated    = $false
            ReasonCode   = 'ActivationResultUnknown'
            Detail       = 'The foreground activation seam returned no result.'
            IsBestEffort = $true
            Blocking     = $false
            Evidence     = $evidence
        }
    }

    $result = [string]$result
    $activated = ($result.ToUpperInvariant() -eq 'ACTIVATED')
    if ($null -eq $reasonCode) { $reasonCode = $null }
    return [pscustomobject]@{
        Result       = $result
        Activated    = $activated
        ReasonCode   = $reasonCode
        Detail       = 'Foreground activation is a best-effort convenience and never proof of readiness.'
        IsBestEffort = $true
        Blocking     = $false
        Evidence     = $evidence
    }
}

function ConvertTo-RStudioStartTimeUtc {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime()
    }
    if ($Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).UtcDateTime
    }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Get-RStudioLivenessDecision {
    <#
    .SYNOPSIS
        Reads the runner's explicit liveness statement.

    .DESCRIPTION
        A launched handoff is only claimed when the runner states whether the
        process it started is alive. 'Alive', 'IsAlive', and 'Running' state
        liveness positively; 'HasExited', 'Exited', and 'IsExited' state it
        negatively. A statement that cannot be read as a Boolean, a stated death,
        or two statements that contradict each other are all refusals, so a
        possibly-started but uncertain launch is never reported as an ordinary
        launch failure that could invite a retry.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$RunnerResult)

    $aliveStated = $false
    $notAliveStated = $false
    $livenessStated = $false
    $unclear = $false

    foreach ($name in @('Alive', 'IsAlive', 'Running')) {
        if (-not (Test-RSObjectProperty -InputObject $RunnerResult -Name $name)) {
            continue
        }
        $value = Get-RSObjectPropertyValue -InputObject $RunnerResult -Names @($name)
        $livenessStated = $true
        if ($value -isnot [bool]) {
            $unclear = $true
            continue
        }
        if ([bool]$value) {
            $aliveStated = $true
        }
        else {
            $notAliveStated = $true
        }
    }
    foreach ($name in @('HasExited', 'Exited', 'IsExited')) {
        if (-not (Test-RSObjectProperty -InputObject $RunnerResult -Name $name)) {
            continue
        }
        $value = Get-RSObjectPropertyValue -InputObject $RunnerResult -Names @($name)
        $livenessStated = $true
        if ($value -isnot [bool]) {
            $unclear = $true
            continue
        }
        if ([bool]$value) {
            $notAliveStated = $true
        }
        else {
            $aliveStated = $true
        }
    }

    if (-not $livenessStated) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessLivenessUnstated'; Reason = 'The process runner did not state whether the started process is alive.' }
    }
    if ($unclear) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessLivenessUnclear'; Reason = 'The process runner stated liveness as a non-Boolean value.' }
    }
    if ($aliveStated -and $notAliveStated) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessLivenessContradictory'; Reason = 'The process runner stated both that the process is alive and that it is not.' }
    }
    if ($notAliveStated) {
        return [pscustomobject]@{ Valid = $false; ReasonCode = 'ProcessNotAlive'; Reason = 'The process runner stated that the process is not running.' }
    }

    return [pscustomobject]@{ Valid = $true; ReasonCode = $null; Reason = $null }
}

function Get-RStudioHandoffLaunchOutcome {
    <#
    .SYNOPSIS
        Invokes the handoff process runner and classifies its single result.

    .DESCRIPTION
        The runner output is normalized to exactly one result, and that result
        must state an explicit Boolean success, the executable path it actually
        started (matching the verified executable), a usable start time, and an
        explicit, non-contradictory liveness statement before the handoff counts
        as launched.

        Every other shape is a handoff-review outcome: the runner was invoked, so
        an R-Studio process may exist. The candidate identity is retained when
        the result identifies a process, the launch is not claimed, and the caller
        permits no automatic retry and no forced close.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ProcessRunner,
        [Parameter(Mandatory = $true)][object]$Request,
        [AllowNull()][AllowEmptyString()][string]$ExecutablePath
    )

    $outcome = [pscustomobject]@{
        Decision          = 'HandoffReview'
        ReasonCode        = $null
        Launched          = $false
        ProcessIdentity   = $null
        RunnerInvoked     = $false
        Error             = $null
        Evidence          = @{}
    }

    try {
        $runnerOutput = @(& $ProcessRunner $Request)
        $outcome.RunnerInvoked = $true
    }
    catch {
        $outcome.ReasonCode = 'ProcessLaunchFailed'
        $outcome.Error = $_.Exception.Message
        $outcome.Evidence['LaunchError'] = $_.Exception.Message
        $outcome.Evidence['LaunchResult'] = 'The process runner failed while starting R-Studio; a vendor process may be running.'
        return $outcome
    }

    if ($runnerOutput.Count -eq 0) {
        $outcome.ReasonCode = 'ProcessIdentityMissing'
        $outcome.Evidence['LaunchResult'] = 'The process runner returned no process identity.'
        return $outcome
    }
    if ($runnerOutput.Count -ne 1) {
        $outcome.ReasonCode = 'AmbiguousProcessIdentity'
        $outcome.Evidence['LaunchResult'] = 'The process runner returned more than one process identity, so the started process cannot be identified.'
        return $outcome
    }

    $runnerResult = $runnerOutput[0]

    $processId = Get-RSFirstNonNullPropertyValue -InputObject $runnerResult -Names @('ProcessId', 'Id')
    $numericProcessId = 0
    if ($null -ne $processId) {
        try { $numericProcessId = [int]$processId }
        catch { $numericProcessId = 0 }
    }

    $actualPath = Get-RSFirstNonNullPropertyValue -InputObject $runnerResult -Names @('Path', 'ExecutablePath', 'MainModulePath')
    $startTime = ConvertTo-RStudioStartTimeUtc -Value (Get-RSFirstNonNullPropertyValue -InputObject $runnerResult -Names @('StartTimeUtc', 'StartTime'))
    $processName = [string](Get-RSObjectPropertyValue -InputObject $runnerResult -Names @('Name', 'ProcessName'))
    $mainWindowHandle = Get-RSObjectPropertyValue -InputObject $runnerResult -Names @('MainWindowHandle')

    # A candidate identity is whatever the runner actually reported. It is kept
    # for review even when the launch cannot be trusted, and it never claims a
    # verification that did not happen.
    if ($numericProcessId -gt 0) {
        $outcome.ProcessIdentity = [pscustomobject]@{
            Product          = $script:RSProductName
            ExecutablePath   = [string]$actualPath
            ProcessId        = $numericProcessId
            Name             = $processName
            StartTimeUtc     = $startTime
            MainWindowHandle = $mainWindowHandle
            IdentityStatus   = 'Candidate'
        }
    }

    if ($numericProcessId -le 0) {
        $outcome.ReasonCode = 'ProcessIdentityMissing'
        $outcome.Evidence['LaunchResult'] = 'The process runner returned an unusable process identity.'
        return $outcome
    }

    if (-not (Test-RSObjectProperty -InputObject $runnerResult -Name 'Success') -or
        $runnerResult.Success -isnot [bool] -or -not [bool]$runnerResult.Success) {
        $outcome.ReasonCode = 'ProcessResultUnverified'
        $outcome.Evidence['LaunchResult'] = 'The process runner did not return an explicit Success=true result.'
        return $outcome
    }

    if ([string]::IsNullOrWhiteSpace([string]$actualPath)) {
        $outcome.ReasonCode = 'ProcessPathMissing'
        $outcome.Evidence['LaunchResult'] = 'The process runner returned no actual executable path.'
        return $outcome
    }
    if (-not [string]::Equals(([string]$actualPath).Trim(), ([string]$ExecutablePath).Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        $outcome.ReasonCode = 'ProcessPathMismatch'
        $outcome.Evidence['RequestedExecutablePath'] = $ExecutablePath
        $outcome.Evidence['ActualExecutablePath'] = [string]$actualPath
        return $outcome
    }

    if ($null -eq $startTime) {
        $outcome.ReasonCode = 'ProcessStartTimeMissing'
        $outcome.Evidence['LaunchResult'] = 'The process runner returned no usable process start time.'
        return $outcome
    }

    $liveness = Get-RStudioLivenessDecision -RunnerResult $runnerResult
    if (-not $liveness.Valid) {
        $outcome.ReasonCode = $liveness.ReasonCode
        $outcome.Evidence['LaunchResult'] = $liveness.Reason
        return $outcome
    }

    $outcome.Decision = 'HandoffLaunched'
    $outcome.Launched = $true
    $outcome.ProcessIdentity = [pscustomobject]@{
        Product          = $script:RSProductName
        ExecutablePath   = [string]$actualPath
        ProcessId        = $numericProcessId
        Name             = $processName
        StartTimeUtc     = $startTime
        MainWindowHandle = $mainWindowHandle
    }
    return $outcome
}

function Start-RStudioHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$State,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Executable,
        [AllowNull()][AllowEmptyString()][string]$LogPath,
        [scriptblock]$ProcessRunner,
        [scriptblock]$LogPathSafetyValidator,
        [scriptblock]$FreshEvidenceProvider,
        [scriptblock]$ActivationProvider
    )

    $preconditions = Test-RStudioHandoffPreconditions -State $State -Executable $Executable `
        -LogPath $LogPath -LogPathSafetyValidator $LogPathSafetyValidator `
        -FreshEvidenceProvider $FreshEvidenceProvider

    $executablePath = Get-RSFirstNonNullPropertyValue -InputObject $Executable -Names @('Path', 'ExecutablePath', 'FullName')
    if ($null -ne $executablePath) { $executablePath = [string]$executablePath }

    $arguments = $null
    $argumentString = $null
    $normalizedIdentity = $null
    $activation = $null
    $mainPanelGate = $null
    $launched = $false
    $runnerInvoked = $false
    $requiresHandoffReview = $false
    $decision = 'Blocked'
    $reasonCode = $preconditions.ReasonCode
    $evidence = @{ PreconditionDecision = $preconditions.Decision }

    if ($preconditions.Allowed) {
        $argumentResult = New-RStudioArgumentList -LogPath $LogPath
        if ($argumentResult.Decision -ne 'Ready') {
            $decision = 'Blocked'
            $reasonCode = $argumentResult.ReasonCode
            $evidence['ArgumentDecision'] = $argumentResult.Decision
            $argumentResult = $null
        }
        else {
            $arguments = @($argumentResult.Arguments)
            $argumentString = ConvertTo-RStudioArgumentString -Arguments $arguments
            $evidence['Arguments'] = $arguments
            $evidence['ArgumentString'] = $argumentString

            if ($null -eq $ProcessRunner) {
                $decision = 'Blocked'
                $reasonCode = 'ProcessRunnerUnavailable'
                $evidence['ArgumentDecision'] = 'RunnerMissing'
            }
            else {
                $request = [pscustomobject]@{
                    Product        = $script:RSProductName
                    Purpose        = 'LaunchOnlyHandoff'
                    ExecutablePath = $executablePath
                    Arguments      = $arguments
                    ArgumentString = $argumentString
                    UseShellExecute = $false
                }
                $launchOutcome = Get-RStudioHandoffLaunchOutcome -ProcessRunner $ProcessRunner -Request $request -ExecutablePath $executablePath
                $runnerInvoked = [bool]$launchOutcome.RunnerInvoked
                foreach ($key in @($launchOutcome.Evidence.Keys)) {
                    $evidence[$key] = $launchOutcome.Evidence[$key]
                }
                $normalizedIdentity = $launchOutcome.ProcessIdentity

                if ($launchOutcome.Launched) {
                    $activation = Request-RStudioForegroundActivation -ProcessIdentity $normalizedIdentity -ActivationProvider $ActivationProvider
                    $gateEvidence = @{
                        ExecutablePath = [string]$normalizedIdentity.ExecutablePath
                        Arguments      = $arguments
                        ProcessId      = $normalizedIdentity.ProcessId
                        StartTimeUtc   = $normalizedIdentity.StartTimeUtc
                    }
                    $mainPanelGate = New-RSHandoffGate -Evidence $gateEvidence
                    $launched = $true
                    $decision = 'HandoffLaunched'
                    $reasonCode = $null
                    $evidence['ProcessId'] = $normalizedIdentity.ProcessId
                    $evidence['ActualExecutablePath'] = [string]$normalizedIdentity.ExecutablePath
                    $evidence['ProcessStartTimeUtc'] = $normalizedIdentity.StartTimeUtc
                    $evidence['LaunchOnly'] = $true
                }
                else {
                    # A possibly-started but uncertain launch is never reported as
                    # an ordinary failure: the runner was invoked, so an R-Studio
                    # process may exist. The candidate identity is retained and the
                    # outcome requires an operator review before anything else.
                    $decision = 'HandoffReview'
                    $reasonCode = $launchOutcome.ReasonCode
                    $requiresHandoffReview = $true
                    $evidence['HandoffReview'] = $true
                }
            }
        }
    }

    return [pscustomobject]@{
        Task                  = 'RStudioLaunchOnlyHandoff'
        Decision              = $decision
        ReasonCode            = $reasonCode
        Launched              = $launched
        IsLaunchOnly          = $true
        AnalysisInvoked       = $false
        CompletionClaimed     = $false
        RequiresHandoffReview = $requiresHandoffReview
        RetryAllowed          = $false
        ForcedCloseAllowed    = $false
        RunnerInvoked         = $runnerInvoked
        VendorProcessPossible = $runnerInvoked
        Product               = $script:RSProductName
        ExecutablePath        = $executablePath
        Arguments         = $arguments
        ArgumentString    = $argumentString
        ProcessIdentity   = $normalizedIdentity
        Activation        = $activation
        MainPanelGate     = $mainPanelGate
        Preconditions     = $preconditions
        Evidence          = $evidence
        CompletedAtUtc    = [datetime]::UtcNow
    }
}

function Get-RStudioObservation {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ProcessIdentity,
        [scriptblock]$UiProvider
    )

    $evidence = @{}
    if ($null -ne $ProcessIdentity) {
        $processId = Get-RSObjectPropertyValue -InputObject $ProcessIdentity -Names @('ProcessId', 'Id')
        if ($null -ne $processId) { $evidence['ProcessId'] = $processId }
    }

    if ($null -eq $ProcessIdentity) {
        $gate = New-RSObservationGate -Evidence @{ Reason = 'No process identity was supplied.' }
        return [pscustomobject]@{
            Result            = 'Unknown'
            IsUnknown         = $true
            ReasonCode        = 'ProcessIdentityMissing'
            ProcessPresent    = $false
            WindowPresent     = $false
            MainPanelVisible  = $false
            ControlEvidence   = @()
            Messages          = @('No R-Studio process identity was supplied for observation.')
            CompletionClaimed = $false
            AnalysisInvoked   = $false
            Gate              = $gate
            Evidence          = $evidence
            ObservedAtUtc     = [datetime]::UtcNow
        }
    }

    if ($null -eq $UiProvider) {
        $gate = New-RSObservationGate -Evidence @{ Reason = 'No UI observation seam was supplied.' }
        return [pscustomobject]@{
            Result            = 'Unknown'
            IsUnknown         = $true
            ReasonCode        = 'UiProviderUnavailable'
            ProcessPresent    = $null
            WindowPresent     = $null
            MainPanelVisible  = $null
            ControlEvidence   = @()
            Messages          = @('The UI observation seam was not supplied, so R-Studio readiness is unknown.')
            CompletionClaimed = $false
            AnalysisInvoked   = $false
            Gate              = $gate
            Evidence          = $evidence
            ObservedAtUtc     = [datetime]::UtcNow
        }
    }

    $uiOutput = @()
    try {
        $uiOutput = @(& $UiProvider $ProcessIdentity)
    }
    catch {
        $evidence['ObservationError'] = $_.Exception.Message
        $gate = New-RSObservationGate -Evidence @{ Reason = 'The UI observation seam failed.' }
        return [pscustomobject]@{
            Result            = 'Unknown'
            IsUnknown         = $true
            ReasonCode        = 'UiObservationFailed'
            ProcessPresent    = $null
            WindowPresent     = $null
            MainPanelVisible  = $null
            ControlEvidence   = @()
            Messages          = @('The UI observation seam failed; readiness is unknown.')
            CompletionClaimed = $false
            AnalysisInvoked   = $false
            Gate              = $gate
            Evidence          = $evidence
            ObservedAtUtc     = [datetime]::UtcNow
        }
    }

    if ($uiOutput.Count -eq 0) {
        $gate = New-RSObservationGate -Evidence @{ Reason = 'The UI observation seam returned no state.' }
        return [pscustomobject]@{
            Result            = 'Unknown'
            IsUnknown         = $true
            ReasonCode        = 'UiObservationMissing'
            ProcessPresent    = $null
            WindowPresent     = $null
            MainPanelVisible  = $null
            ControlEvidence   = @()
            Messages          = @('The UI observation seam returned no state; readiness is unknown.')
            CompletionClaimed = $false
            AnalysisInvoked   = $false
            Gate              = $gate
            Evidence          = $evidence
            ObservedAtUtc     = [datetime]::UtcNow
        }
    }
    if ($uiOutput.Count -ne 1) {
        $evidence['ObservationResultCount'] = $uiOutput.Count
        $gate = New-RSObservationGate -Evidence @{ Reason = 'The UI observation seam returned more than one state.' }
        return [pscustomobject]@{
            Result            = 'Unknown'
            IsUnknown         = $true
            ReasonCode        = 'AmbiguousUiObservation'
            ProcessPresent    = $null
            WindowPresent     = $null
            MainPanelVisible  = $null
            ControlEvidence   = @()
            Messages          = @('The UI observation seam returned more than one state; readiness is unknown.')
            CompletionClaimed = $false
            AnalysisInvoked   = $false
            Gate              = $gate
            Evidence          = $evidence
            ObservedAtUtc     = [datetime]::UtcNow
        }
    }
    $uiResult = $uiOutput[0]

    $processPresent = Get-RSObjectPropertyValue -InputObject $uiResult -Names @('ProcessPresent')
    $windowPresent = Get-RSObjectPropertyValue -InputObject $uiResult -Names @('WindowPresent')
    $mainPanelVisible = Get-RSObjectPropertyValue -InputObject $uiResult -Names @('MainPanelVisible')
    $controls = Get-RSObjectPropertyValue -InputObject $uiResult -Names @('ControlEvidence', 'Controls')
    $messages = Get-RSObjectPropertyValue -InputObject $uiResult -Names @('Messages')
    $providerEvidence = Get-RSObjectPropertyValue -InputObject $uiResult -Names @('Evidence')
    if ($null -ne $providerEvidence) { $evidence['UiEvidence'] = $providerEvidence }
    if ($null -ne $processPresent) { $evidence['ProcessPresent'] = $processPresent }
    if ($null -ne $windowPresent) { $evidence['WindowPresent'] = $windowPresent }
    if ($null -ne $mainPanelVisible) { $evidence['MainPanelVisible'] = $mainPanelVisible }

    $isUnknown = $true
    if ($processPresent -eq $true -and $mainPanelVisible -eq $true) { $isUnknown = $false }

    # Process, window, or main-panel evidence is an observation only. It never
    # becomes a completion or analysis claim.
    $evidence['CompletionClaimed'] = $false
    $gate = $null
    if ($isUnknown) { $gate = New-RSObservationGate -Evidence $evidence }

    return [pscustomobject]@{
        Result            = 'Observed'
        IsUnknown         = $isUnknown
        ReasonCode        = $null
        ProcessPresent    = $processPresent
        WindowPresent     = $windowPresent
        MainPanelVisible  = $mainPanelVisible
        ControlEvidence   = @($controls)
        Messages          = @($messages)
        CompletionClaimed = $false
        AnalysisInvoked   = $false
        Gate              = $gate
        Evidence          = $evidence
        ObservedAtUtc     = [datetime]::UtcNow
    }
}

function Open-RecoveryClientFolder {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [scriptblock]$ExplorerProvider,
        [scriptblock]$PathSafetyValidator
    )

    $evidence = @{}
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            Decision   = 'Blocked'
            ReasonCode = 'ClientFolderNotProvided'
            Path       = $null
            Opened     = $false
            Evidence   = $evidence
        }
    }
    $evidence['Path'] = $Path

    if (-not (Test-RSPathText -Path $Path)) {
        return [pscustomobject]@{
            Decision   = 'Blocked'
            ReasonCode = 'ClientFolderInvalid'
            Path       = $Path
            Opened     = $false
            Evidence   = $evidence
        }
    }

    $exists = $false
    try {
        $exists = Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop
    }
    catch {
        $evidence['ContainerCheckError'] = $_.Exception.Message
    }
    if (-not $exists) {
        return [pscustomobject]@{
            Decision   = 'Blocked'
            ReasonCode = 'ClientFolderMissing'
            Path       = $Path
            Opened     = $false
            Evidence   = $evidence
        }
    }

    if ($null -ne $PathSafetyValidator) {
        $validatorResult = $null
        try {
            $validatorResult = & $PathSafetyValidator $Path
        }
        catch {
            $evidence['PathSafetyError'] = $_.Exception.Message
            return [pscustomobject]@{
                Decision   = 'Blocked'
                ReasonCode = 'ClientFolderSafetyUnverified'
                Path       = $Path
                Opened     = $false
                Evidence   = $evidence
            }
        }
        $allowed = Get-RSObjectPropertyValue -InputObject $validatorResult -Names @('Allowed', 'IsSafe')
        if ($null -eq $allowed) {
            return [pscustomobject]@{
                Decision   = 'Blocked'
                ReasonCode = 'ClientFolderSafetyUnverified'
                Path       = $Path
                Opened     = $false
                Evidence   = $evidence
            }
        }
        $safetyReason = Get-RSObjectPropertyValue -InputObject $validatorResult -Names @('ReasonCode')
        if ($null -ne $safetyReason) { $evidence['PathSafetyReasonCode'] = [string]$safetyReason }
        if ($allowed -ne $true) {
            return [pscustomobject]@{
                Decision   = 'Blocked'
                ReasonCode = 'ClientFolderUnsafe'
                Path       = $Path
                Opened     = $false
                Evidence   = $evidence
            }
        }
    }

    if ($null -eq $ExplorerProvider) {
        return [pscustomobject]@{
            Decision   = 'Blocked'
            ReasonCode = 'ExplorerProviderUnavailable'
            Path       = $Path
            Opened     = $false
            Evidence   = $evidence
        }
    }

    $request = [pscustomobject]@{
        Action = 'OpenClientFolder'
        Purpose = 'SeparateExplorerAction'
        Path   = $Path
    }
    $providerResult = $null
    try {
        $providerResult = & $ExplorerProvider $request
    }
    catch {
        $evidence['ExplorerError'] = $_.Exception.Message
        return [pscustomobject]@{
            Decision   = 'Failed'
            ReasonCode = 'ExplorerLaunchFailed'
            Path       = $Path
            Opened     = $false
            Evidence   = $evidence
        }
    }

    if (-not (Test-RSObjectProperty -InputObject $providerResult -Name 'Success') -or
        $providerResult.Success -isnot [bool]) {
        return [pscustomobject]@{
            Decision       = 'Blocked'
            ReasonCode     = 'ExplorerResultUnverified'
            Path           = $Path
            Opened         = $false
            ExplorerResult = $providerResult
            Evidence       = $evidence
        }
    }
    if (-not $providerResult.Success) {
        return [pscustomobject]@{
            Decision       = 'Failed'
            ReasonCode     = 'ExplorerResultFailed'
            Path           = $Path
            Opened         = $false
            ExplorerResult = $providerResult
            Evidence       = $evidence
        }
    }
    $reportedResult = Get-RSObjectPropertyValue -InputObject $providerResult -Names @('Result', 'Decision', 'Status')
    if ($null -ne $reportedResult -and ([string]$reportedResult).ToUpperInvariant() -ne 'OPENED') {
        return [pscustomobject]@{
            Decision       = 'Failed'
            ReasonCode     = 'ExplorerResultFailed'
            Path           = $Path
            Opened         = $false
            ExplorerResult = $providerResult
            Evidence       = $evidence
        }
    }

    $evidence['SeparateFromVendorArguments'] = $true
    return [pscustomobject]@{
        Decision       = 'Opened'
        ReasonCode     = $null
        Path           = $Path
        Opened         = $true
        ExplorerResult = $providerResult
        Evidence       = $evidence
        OpenedAtUtc    = [datetime]::UtcNow
    }
}

function Get-RStudioDefaultProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ProcessRunner', 'ExplorerProvider', 'ActivationProvider')]
        [string]$Name
    )

    switch ($Name) {
        'ProcessRunner' {
            return {
                param($Request)
                if ($null -eq $Request) { throw 'The R-Studio launch request is missing.' }
                $executablePath = Get-RSFirstNonNullPropertyValue -InputObject $Request -Names @('ExecutablePath', 'Path')
                if ([string]::IsNullOrWhiteSpace([string]$executablePath)) {
                    throw 'The R-Studio launch request has no verified executable path.'
                }
                $argumentString = Get-RSObjectPropertyValue -InputObject $Request -Names @('ArgumentString')
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = [string]$executablePath
                if ($null -ne $argumentString) { $startInfo.Arguments = [string]$argumentString }
                $startInfo.UseShellExecute = $false
                $workingDirectory = Get-RSPathParent -Path ([string]$executablePath)
                if (-not [string]::IsNullOrEmpty($workingDirectory)) {
                    $startInfo.WorkingDirectory = $workingDirectory
                }
                $process = [System.Diagnostics.Process]::Start($startInfo)
                $startTime = $null
                $actualPath = $null
                $hasExited = $false
                $windowHandle = 0
                try {
                    $actualPath = $process.MainModule.FileName
                    $startTime = $process.StartTime.ToUniversalTime()
                    $hasExited = $process.HasExited
                    $windowHandle = $process.MainWindowHandle.ToInt64()
                }
                catch {
                    # A process that has already exited or denies module access
                    # exposes incomplete identity. The missing observations are
                    # recorded as-is and the handoff rejects them.
                    $startTime = $null
                    $actualPath = $null
                }
                return [pscustomobject]@{
                    Success          = $true
                    Id               = $process.Id
                    ProcessId        = $process.Id
                    Name             = $process.ProcessName
                    Path             = [string]$actualPath
                    MainModulePath   = [string]$actualPath
                    StartTimeUtc     = $startTime
                    HasExited        = $hasExited
                    MainWindowHandle = $windowHandle
                }
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
                $startInfo.Arguments = ConvertTo-RStudioArgumentString -Arguments @($Request.Path)
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
        'ActivationProvider' {
            return {
                param($ProcessIdentity)
                $handleValue = [int64]0
                if ($null -ne $ProcessIdentity) {
                    $rawHandle = Get-RSObjectPropertyValue -InputObject $ProcessIdentity -Names @('MainWindowHandle')
                    if ($null -ne $rawHandle) {
                        try { $handleValue = [int64]$rawHandle }
                        catch { $handleValue = [int64]0 }
                    }
                    if ($handleValue -eq 0) {
                        $rawProcessId = Get-RSObjectPropertyValue -InputObject $ProcessIdentity -Names @('ProcessId', 'Id')
                        if ($null -ne $rawProcessId) {
                            $numericProcessId = 0
                            try { $numericProcessId = [int]$rawProcessId }
                            catch { $numericProcessId = 0 }
                            if ($numericProcessId -gt 0) {
                                try {
                                    $process = [System.Diagnostics.Process]::GetProcessById($numericProcessId)
                                    $process.Refresh()
                                    $handleValue = $process.MainWindowHandle.ToInt64()
                                }
                                catch {
                                    # The process is gone or its window handle is not
                                    # available. This stays a best-effort result.
                                    $handleValue = 0
                                }
                            }
                        }
                    }
                }
                if ($handleValue -eq 0) {
                    return [pscustomobject]@{
                        Result     = 'Unavailable'
                        ReasonCode = 'MainWindowUnavailable'
                        Evidence   = 'No main window handle was available for the verified R-Studio process.'
                    }
                }
                if ($null -eq ('RecoveryNative.RecoveryForeground' -as [type])) {
                    Add-Type -Name 'RecoveryForeground' -Namespace 'RecoveryNative' `
                        -MemberDefinition $script:RSForegroundSource -ErrorAction Stop
                }
                $handle = New-Object System.IntPtr($handleValue)
                [void][RecoveryNative.RecoveryForeground]::ShowWindow($handle, 9)
                $activated = [RecoveryNative.RecoveryForeground]::SetForegroundWindow($handle)
                if ($activated) {
                    return [pscustomobject]@{
                        Result     = 'Activated'
                        ReasonCode = $null
                        Evidence   = 'SetForegroundWindow accepted the request for the verified process window.'
                    }
                }
                return [pscustomobject]@{
                    Result     = 'Failed'
                    ReasonCode = 'ForegroundRequestRefused'
                    Evidence   = 'Windows refused the foreground request. The technician must activate the window manually.'
                }
            }
        }
    }
}

Export-ModuleMember -Function @('New-RStudioArgumentList', 'Test-RStudioHandoffPreconditions',
    'Start-RStudioHandoff', 'Get-RStudioObservation', 'Request-RStudioForegroundActivation',
    'Open-RecoveryClientFolder', 'Get-RStudioDefaultProvider')
