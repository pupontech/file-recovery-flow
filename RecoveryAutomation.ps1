[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('ConfigPath')]
    [string]$RecoveryConfigPath = '',
    [switch]$NoPause,
    [switch]$DryRun,
    [string]$SourcePath = '',
    [string]$DestinationPath = '',
    [string]$ClientName = '',
    [object]$ConfigurationOverrides = $null,
    [object]$DiskProvider = $null,
    [scriptblock]$SourceSelector = $null,
    [scriptblock]$SourceProtectionProvider = $null,
    [scriptblock]$DestinationPickerProvider = $null,
    [scriptblock]$TypedDestinationProvider = $null,
    [scriptblock]$FileScavengerDiscoveryProvider = $null,
    [scriptblock]$RStudioDiscoveryProvider = $null,
    [scriptblock]$ApplicationFileInfoProvider = $null,
    [scriptblock]$ElevationProvider = $null,
    [scriptblock]$RuntimeProvider = $null,
    [scriptblock]$VendorProcessRunner = $null,
    [scriptblock]$FileScavengerProcessRunner = $null,
    [scriptblock]$RStudioProcessRunner = $null,
    [scriptblock]$FileScavengerUiProvider = $null,
    [scriptblock]$FileScavengerOutputProvider = $null,
    [scriptblock]$RStudioUiProvider = $null,
    [scriptblock]$RStudioFreshEvidenceProvider = $null,
    [scriptblock]$RStudioActivationProvider = $null,
    [scriptblock]$InteractionProvider = $null,
    [object]$LogWriterProvider = $null,
    [object]$StateWriterProvider = $null,
    [object]$ClaimProvider = $null,
    [object]$LockProvider = $null,
    [object]$Clock = $null,
    [object]$FileScavengerEvidenceMap = $null,
    [object]$RStudioEvidenceMap = $null,
    [object]$OperatorEvidenceProvider = $null,
    [object]$ValidatedFileScavengerBuilds = $null,
    [object]$ValidatedRStudioBuilds = $null
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-RecoveryAutomationHostElevated {
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') {
        return $true
    }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-RecoveryAutomationElevationArgumentLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$ConfigPath = '',
        [string]$SourcePath = '',
        [string]$DestinationPath = '',
        [string]$ClientName = '',
        [switch]$NoPause,
        [switch]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'The entry point path is required for an elevated relaunch.'
    }
    # A value containing a double quote cannot be quoted for the child process: the
    # child would re-parse the remainder as extra switches. Such a value is refused
    # instead of being forwarded, because forwarding it would either fail or change
    # the meaning of the elevated run.
    foreach ($candidate in @(
            [pscustomobject]@{ Name = 'ScriptPath'; Value = $ScriptPath }
            [pscustomobject]@{ Name = 'ConfigPath'; Value = $ConfigPath }
            [pscustomobject]@{ Name = 'SourcePath'; Value = $SourcePath }
            [pscustomobject]@{ Name = 'DestinationPath'; Value = $DestinationPath }
            [pscustomobject]@{ Name = 'ClientName'; Value = $ClientName })) {
        if (-not [string]::IsNullOrEmpty([string]$candidate.Value) -and ([string]$candidate.Value).Contains('"')) {
            throw ('The value supplied for ' + $candidate.Name + ' contains a double quote, which cannot be forwarded through the elevated relaunch.')
        }
    }
    # The elevated child is a new process, so every documented technician input
    # is re-declared here. A value that is not re-passed is silently lost for the
    # whole elevated run, which is why each one is quoted and forwarded explicitly.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $arguments += @('-ConfigPath', ('"' + $ConfigPath + '"'))
    }
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $arguments += @('-SourcePath', ('"' + $SourcePath + '"'))
    }
    if (-not [string]::IsNullOrWhiteSpace($DestinationPath)) {
        $arguments += @('-DestinationPath', ('"' + $DestinationPath + '"'))
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientName)) {
        $arguments += @('-ClientName', ('"' + $ClientName + '"'))
    }
    if ($NoPause) { $arguments += '-NoPause' }
    if ($DryRun) { $arguments += '-DryRun' }
    return ($arguments -join ' ')
}

function Get-RecoveryAutomationHostExecutablePath {
    [CmdletBinding()]
    param()

    # The elevated relaunch must use the shell that is actually running, so a
    # launch from pwsh relaunches pwsh and a launch from Windows PowerShell
    # relaunches powershell.exe. A fixed $PSHOME\powershell.exe path is wrong for
    # the first case and can point at a runtime that is not installed for the
    # second.
    $hostPath = $null
    try { $hostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $hostPath = $null }
    if (-not [string]::IsNullOrWhiteSpace($hostPath) -and [System.IO.File]::Exists($hostPath)) {
        return $hostPath
    }
    try {
        $processPath = (Get-Process -Id $PID).Path
        if (-not [string]::IsNullOrWhiteSpace($processPath) -and [System.IO.File]::Exists($processPath)) {
            return $processPath
        }
    }
    catch { }
    return [System.IO.Path]::Combine($PSHOME, 'powershell.exe')
}

function Invoke-RecoveryAutomationSelfElevation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$ConfigPath = '',
        [string]$SourcePath = '',
        [string]$DestinationPath = '',
        [string]$ClientName = '',
        [switch]$NoPause,
        [switch]$DryRun,
        [switch]$SkipElevation
    )

    # A dry run starts no vendor process and touches no recovery media, so it is not
    # elevated: prompting for UAC to run a read-only diagnostic would train the
    # technician to approve elevation when nothing needs it. Everything that reaches
    # a vendor application or a disk still requires real elevation.
    if ($SkipElevation) {
        return [pscustomobject]@{
            ShouldExit = $false
            Success = $true
            ExitCode = 0
            ReasonCode = $null
            Message = $null
        }
    }

    if ($env:OS -ne 'Windows_NT' -or (Test-RecoveryAutomationHostElevated)) {
        return [pscustomobject]@{
            ShouldExit = $false
            Success = $true
            ExitCode = 0
            ReasonCode = $null
            Message = $null
        }
    }

    try {
        $powershellPath = Get-RecoveryAutomationHostExecutablePath
        $argumentLine = Get-RecoveryAutomationElevationArgumentLine -ScriptPath $ScriptPath `
            -ConfigPath $ConfigPath -NoPause:$NoPause -DryRun:$DryRun `
            -SourcePath $SourcePath -DestinationPath $DestinationPath -ClientName $ClientName
        $child = Start-Process -FilePath $powershellPath -ArgumentList $argumentLine `
            -Verb RunAs -WorkingDirectory $PSScriptRoot -Wait -PassThru -ErrorAction Stop
        if ($null -eq $child) {
            return [pscustomobject]@{
                ShouldExit = $true
                Success = $false
                ExitCode = 3
                ReasonCode = 'ElevationLaunchFailed'
                Message = 'The elevated Windows PowerShell process could not be started.'
            }
        }
        $childExitCode = 3
        if ($null -ne $child.ExitCode) { $childExitCode = [int]$child.ExitCode }
        return [pscustomobject]@{
            ShouldExit = $true
            Success = $true
            ExitCode = $childExitCode
            ReasonCode = $null
            Message = $null
        }
    }
    catch {
        $reason = 'ElevationDeclined'
        if ($_.Exception.Message -like '*cannot be forwarded through the elevated relaunch*') {
            # A value the relaunch cannot quote safely is a refusal, not a declined
            # UAC prompt: the technician has to change the input.
            $reason = 'ElevationInputRefused'
        }
        return [pscustomobject]@{
            ShouldExit = $true
            Success = $false
            ExitCode = 3
            ReasonCode = $reason
            Message = ('Administrator elevation was not granted. No vendor or recovery-media operation was attempted. ' + $_.Exception.Message)
        }
    }
}

function Import-RecoveryAutomationModules {
    [CmdletBinding()]
    param()

    $moduleNames = @('Configuration.psm1', 'ApplicationDiscovery.psm1',
        'DiskDetection.psm1', 'RecoveryLogging.psm1', 'JobState.psm1',
        'UIAutomation.psm1', 'FileScavenger.psm1', 'RStudio.psm1',
        'TechnicianUi.psm1')
    foreach ($moduleName in $moduleNames) {
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath ('modules\' + $moduleName)
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }
}

function Get-RecoveryAutomationEffectiveClientName {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ConfigurationResult,
        [AllowNull()][string]$ParameterValue,
        [scriptblock]$NameProvider = $null,
        [AllowNull()][string]$PathLabel = 'case'
    )

    # One precedence rule, used by both the real run and the diagnostic path: the
    # explicit argument wins, then the configuration file, then the technician
    # prompt. Nothing is ever inferred from the media.
    if (-not [string]::IsNullOrWhiteSpace([string]$ParameterValue)) { return [string]$ParameterValue }
    $configured = $null
    if ($null -ne $ConfigurationResult) {
        $configuredConfiguration = Get-RecoveryAutomationValue -InputObject $ConfigurationResult -Names @('Configuration')
        if ($null -ne $configuredConfiguration) {
            $configured = [string](Get-RecoveryAutomationValue -InputObject $configuredConfiguration -Names @('ClientName'))
        }
        if ([string]::IsNullOrWhiteSpace($configured)) {
            $configured = [string](Get-RecoveryAutomationValue -InputObject $ConfigurationResult -Names @('ClientName'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }
    if ($null -eq $NameProvider) { return '' }
    try {
        $answer = [string](& $NameProvider ([pscustomobject]@{ Purpose = 'ClientName'; PathLabel = $PathLabel }))
    }
    catch {
        return ''
    }
    if ($null -eq $answer) { return '' }
    return $answer
}

function Get-RecoveryAutomationEffectiveDestinationText {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ConfigurationResult,
        [AllowNull()][string]$ParameterValue,
        [bool]$ParameterBound = $false
    )

    if ($ParameterBound) { return [string]$ParameterValue }
    if ($null -eq $ConfigurationResult) { return '' }
    $configuredConfiguration = Get-RecoveryAutomationValue -InputObject $ConfigurationResult -Names @('Configuration')
    if ($null -ne $configuredConfiguration) {
        $configuredRoot = [string](Get-RecoveryAutomationValue -InputObject $configuredConfiguration -Names @('DestinationRoot'))
        if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) { return $configuredRoot }
    }
    return [string](Get-RecoveryAutomationValue -InputObject $ConfigurationResult -Names @('DestinationRoot'))
}

function New-RecoveryAutomationResult {
    [CmdletBinding()]
    param(
        [bool]$Success,
        [int]$ExitCode,
        [string]$Mode,
        [string]$ReasonCode,
        [string]$Message,
        [object]$ConfigurationResult,
        [bool]$VendorLaunchAttempted,
        [bool]$RecoveryMediaTouched,
        [object]$Runtime = $null,
        [object]$Applications = $null,
        [object]$SourceIdentity = $null,
        [object]$DestinationIdentity = $null,
        [object]$Capacity = $null,
        [object]$Case = $null,
        [object]$Gate = $null,
        [object]$Handoff = $null,
        [object]$State = $null
    )

    return [pscustomobject]@{
        Success               = $Success
        ExitCode              = $ExitCode
        Mode                  = $Mode
        ReasonCode            = $ReasonCode
        Message               = $Message
        ConfigurationValid    = if ($null -ne $ConfigurationResult) { [bool]$ConfigurationResult.Valid } else { $false }
        Configuration         = if ($null -ne $ConfigurationResult) { $ConfigurationResult.Configuration } else { $null }
        ConfigurationResult   = $ConfigurationResult
        VendorLaunchAttempted = $VendorLaunchAttempted
        RecoveryMediaTouched  = $RecoveryMediaTouched
        Runtime               = $Runtime
        Applications          = $Applications
        SourceIdentity        = $SourceIdentity
        DestinationIdentity   = $DestinationIdentity
        Capacity              = $Capacity
        Case                  = $Case
        Gate                  = $Gate
        Handoff               = $Handoff
        StateObject           = $State
        CurrentState          = if ($null -ne $State) { $State.State } else { $null }
        JobFolderPath         = if ($null -ne $Case) { $Case.JobFolderPath } else { $null }
        StatePath             = if ($null -ne $Case) { $Case.StatePath } else { $null }
        LogPath               = if ($null -ne $Case) { $Case.LogPath } else { $null }
        Events                = @()
    }
}

function Get-RecoveryAutomationConfigPath {
    [CmdletBinding()]
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    return (Join-Path -Path $PSScriptRoot -ChildPath 'config.json')
}

function Get-RecoveryAutomationValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $InputObject) { return $null }
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name)) { return $InputObject[$name] }
        }
        else {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property) { return $property.Value }
        }
    }
    return $null
}

function Test-RecoveryAutomationBoolean {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $parsed = $false
    if ([bool]::TryParse(([string]$Value), [ref]$parsed)) { return $parsed }
    return $false
}

function ConvertTo-RecoveryAutomationHashtable {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = @{}
    if ($null -eq $InputObject) { return $result }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { $result[[string]$key] = $InputObject[$key] }
        return $result
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Invoke-RecoveryAutomationProvider {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Operation,
        [hashtable]$Arguments = @{}
    )

    if ($null -eq $Provider) {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderMissing'; Message = 'The requested provider was not supplied.' }
    }
    $operationProvider = $null
    if ($Provider -is [scriptblock]) {
        $operationProvider = $Provider
    }
    elseif ($Provider -is [System.Collections.IDictionary]) {
        if ($Provider.Contains($Operation)) { $operationProvider = $Provider[$Operation] }
    }
    else {
        $member = $Provider.PSObject.Properties[$Operation]
        if ($null -ne $member) { $operationProvider = $member.Value }
    }
    if ($operationProvider -isnot [scriptblock]) {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationMissing'; Message = ("Provider operation '{0}' is unavailable." -f $Operation) }
    }
    $request = @{ Operation = $Operation }
    foreach ($key in $Arguments.Keys) { $request[$key] = $Arguments[$key] }
    try {
        return [pscustomobject]@{ Success = $true; Data = @(& $operationProvider ([pscustomobject]$request)); ReasonCode = $null; Message = $null }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderFailure'; Message = $_.Exception.Message }
    }
}

function Get-RecoveryAutomationRuntimeEvidence {
    [CmdletBinding()]
    param([scriptblock]$Provider = $null)

    if ($null -ne $Provider) {
        try {
            $raw = & $Provider
            if ($raw -is [bool]) {
                return [pscustomobject]@{ Compatible = [bool]$raw; Evidence = 'Runtime provider Boolean result.'; PowerShellMajor = $null; PSEdition = $null }
            }
            $compatible = Get-RecoveryAutomationValue -InputObject $raw -Names @('Compatible', 'Supported', 'Valid', 'IsSupported')
            return [pscustomobject]@{
                Compatible = (Test-RecoveryAutomationBoolean $compatible)
                Evidence = Get-RecoveryAutomationValue -InputObject $raw -Names @('Evidence', 'Message', 'Reason')
                PowerShellMajor = Get-RecoveryAutomationValue -InputObject $raw -Names @('PowerShellMajor', 'Major')
                PSEdition = Get-RecoveryAutomationValue -InputObject $raw -Names @('PSEdition', 'Edition')
            }
        }
        catch {
            return [pscustomobject]@{ Compatible = $false; Evidence = $_.Exception.Message; PowerShellMajor = $null; PSEdition = $null }
        }
    }

    $major = [int]$PSVersionTable.PSVersion.Major
    $edition = 'Desktop'
    if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = [string]$PSVersionTable.PSEdition }
    $hostIsWindows = ([string]$env:OS -eq 'Windows_NT')
    $compatible = ($hostIsWindows -and $major -eq 5 -and $edition -eq 'Desktop')
    $evidence = 'Requires Windows PowerShell 5.1 Desktop on Windows.'
    if (-not $compatible) { $evidence = ('Detected PowerShell {0} {1} on a non-supported runtime.' -f $major, $edition) }
    return [pscustomobject]@{ Compatible = $compatible; Evidence = $evidence; PowerShellMajor = $major; PSEdition = $edition }
}

function New-RecoveryAutomationWindowsDiskProvider {
    [CmdletBinding()]
    param(
        # Read-only storage query seams. Production leaves them empty and the
        # documented read-only Windows Storage cmdlets answer. Tests inject
        # Get-Volume, Get-Partition, Get-Disk, and Get-Item shaped fixtures so the
        # topology this provider publishes can be inspected without a Windows
        # host, a vendor product, or a writable storage stack. A seam replaces one
        # read only; every safety decision stays here, in modules/DiskDetection.psm1,
        # and in the entry point.
        [scriptblock]$VolumeQuery = $null,
        [scriptblock]$PartitionQuery = $null,
        [scriptblock]$DiskQuery = $null,
        [scriptblock]$ItemQuery = $null
    )

    # A provider closure is created with GetNewClosure(), so it runs in its own
    # dynamic module: it can use captured variables but not the functions defined
    # in this script. Field reads, seam calls, and the membership rule therefore
    # live in the three captured script blocks below, which keeps the provider
    # identical whether it runs from the launcher or from a dot-sourced test scope.
    $fieldReader = {
        param([object]$Record, [string]$Name)
        if ($null -eq $Record) { return $null }
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains($Name)) { return $Record[$Name] }
            return $null
        }
        $property = $Record.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }
    $fieldPresenceReader = {
        param([object]$Record, [string]$Name)
        # An absent property and a property that is present but empty are
        # different statements: the first proves nothing at all, the second is a
        # value the provider chose to publish.
        if ($null -eq $Record) { return $false }
        if ($Record -is [System.Collections.IDictionary]) { return $Record.Contains($Name) }
        return ($null -ne $Record.PSObject.Properties[$Name])
    }
    $seamInvoker = {
        param([object]$Seam, [hashtable]$Request)
        # A missing or failing read is never a safe value: it returns nothing and
        # the caller must treat the topology as unresolved.
        if ($null -eq $Seam) { return $null }
        try { return (& $Seam $Request) } catch { return $null }
    }
    $seamProbe = {
        param([object]$Seam, [hashtable]$Request)
        # The same read, but the caller can tell an empty answer apart from a
        # failed one. An empty answer is a statement about the device; a failed
        # read states nothing at all, and the two must never be conflated.
        if ($null -eq $Seam) { return @{ Ok = $false; Value = $null } }
        try { return @{ Ok = $true; Value = (& $Seam $Request) } } catch { return @{ Ok = $false; Value = $null } }
    }
    $membershipReader = {
        param([object]$Volume, [object]$PartitionQuery, [object]$FieldReader, [object]$SeamInvoker, [object]$FieldPresenceReader)
        # Physical membership of one volume. It is complete only when the provider
        # proves it: either the volume itself lists its members, or the
        # volume-scoped partition query (docs/IMPLEMENTATION-SPEC.md section 2.3,
        # Get-Partition -Volume) returns every partition of the volume, which is
        # the volume-to-disk join. A drive-letter-only view can never prove a
        # single member, because a spanned, striped, or Storage Spaces volume
        # presents the same letter on more than one disk. Anything unproven is
        # reported incomplete so the module and the entry point refuse the path
        # instead of comparing a partial topology.
        $membership = [pscustomobject]@{
            DiskNumbers = @()
            PartitionNumber = $null
            Incomplete = $true
            IncompleteReason = 'VolumeUnresolved'
        }
        if ($null -eq $Volume) { return $membership }
        $volumeGuid = [string](& $FieldReader $Volume 'UniqueId')
        $letter = [string](& $FieldReader $Volume 'DriveLetter')

        $numbers = New-Object System.Collections.Generic.List[int]
        $declared = New-Object System.Collections.Generic.List[object]
        $declaredUnparsed = $false
        $declaredPresent = $false
        foreach ($name in @('PhysicalDiskNumbers', 'DiskNumbers')) {
            if ($null -eq $FieldPresenceReader) { break }
            if (-not (& $FieldPresenceReader $Volume $name)) { continue }
            $declaredPresent = $true
            foreach ($value in @(& $FieldReader $Volume $name)) {
                if ($null -eq $value) { $declaredUnparsed = $true; continue }
                $declared.Add($value) | Out-Null
            }
            break
        }
        foreach ($value in $declared) {
            $parsed = 0
            if ([int]::TryParse([string]$value, [ref]$parsed)) {
                if (-not $numbers.Contains($parsed)) { $numbers.Add($parsed) | Out-Null }
            }
            else {
                $declaredUnparsed = $true
            }
        }
        if ($declaredPresent -and $declaredUnparsed) {
            # A member list the provider could not state in full proves nothing:
            # keeping only the members that happened to parse would authorize a
            # subset of an unknown topology.
            $membership.DiskNumbers = $numbers.ToArray()
            $membership.Incomplete = $true
            $membership.IncompleteReason = 'MemberValueUnparsed'
            return $membership
        }
        if ($numbers.Count -gt 0) {
            $membership.DiskNumbers = $numbers.ToArray()
            $membership.Incomplete = $false
            $membership.IncompleteReason = $null
            return $membership
        }

        $volumeScoped = @(& $SeamInvoker $PartitionQuery @{ Operation = 'PartitionsForVolume'; Volume = $Volume; VolumeGuid = $volumeGuid; DriveLetter = $letter })
        $volumeScopedUnparsed = $false
        foreach ($partition in $volumeScoped) {
            if ($null -eq $partition) { continue }
            $numberValue = & $FieldReader $partition 'DiskNumber'
            if ($null -eq $numberValue) { $volumeScopedUnparsed = $true; continue }
            $parsed = 0
            if ([int]::TryParse([string]$numberValue, [ref]$parsed)) {
                if (-not $numbers.Contains($parsed)) { $numbers.Add($parsed) | Out-Null }
            }
            else {
                $volumeScopedUnparsed = $true
            }
        }
        if ($volumeScopedUnparsed) {
            $membership.DiskNumbers = $numbers.ToArray()
            $membership.Incomplete = $true
            $membership.IncompleteReason = 'PartitionMemberUnparsed'
            return $membership
        }
        if ($numbers.Count -gt 0) {
            $membership.DiskNumbers = $numbers.ToArray()
            $membership.Incomplete = $false
            $membership.IncompleteReason = $null
            if ($numbers.Count -eq 1) {
                $membership.PartitionNumber = & $FieldReader $volumeScoped[0] 'PartitionNumber'
            }
            return $membership
        }

        if (-not [string]::IsNullOrWhiteSpace($letter)) {
            # Recorded as evidence only. A letter is an access path, not proof of a
            # one-disk topology, so membership stays incomplete.
            $membership.IncompleteReason = 'DriveLetterOnlyMembership'
            $letterScoped = @(& $SeamInvoker $PartitionQuery @{ Operation = 'PartitionsForDriveLetter'; DriveLetter = $letter })
            foreach ($partition in $letterScoped) {
                if ($null -eq $partition) { continue }
                $numberValue = & $FieldReader $partition 'DiskNumber'
                if ($null -eq $numberValue) { continue }
                $parsed = 0
                if ([int]::TryParse([string]$numberValue, [ref]$parsed)) {
                    if (-not $numbers.Contains($parsed)) { $numbers.Add($parsed) | Out-Null }
                }
            }
            if ($numbers.Count -gt 0) { $membership.DiskNumbers = $numbers.ToArray() }
        }
        return $membership
    }

    $diskTopologyReader = {
        param([object]$Probe, [object]$FieldReader)
        # Positive disk-topology evidence from documented partition fields.
        #
        # The documented MSFT_Disk schema has no dynamic-disk statement at all
        # (MSFT_Disk fields: PartitionStyle, Signature, Guid, IsOffline,
        # IsReadOnly, IsSystem, IsClustered, IsBoot, BootFromDisk, BusType, ...).
        # A dynamic disk is instead made of Logical Disk Manager partitions, and
        # the documented MSFT_Partition GptType values name them explicitly:
        # 'LDM Metadata' 5808c8aa-7e8f-42e0-85d2-e1e90434cfb3 (a Logical Disk
        # Manager metadata partition on a dynamic disk) and 'LDM Data'
        # af9b60a0-1431-4f62-bc68-3311714a69ad (an LDM data partition on a
        # dynamic disk); the MBR form is PARTITION_LDM 0x42.
        #
        # So a disk whose partitions state their types and contain no LDM member
        # is evidenced as an ordinary basic disk, and an unreadable or silent
        # partition view stays unproven instead of being read as safe.
        $evidence = [pscustomobject]@{
            Stated     = $false
            HasLdm     = $false
            PartitionCount = 0
            Reason     = 'PartitionViewUnavailable'
        }
        if ($null -eq $Probe -or $Probe.Ok -ne $true) {
            # The partition view failed or was never available. That states
            # nothing about the disk, so completeness stays withheld.
            $evidence.Stated = $false
            $evidence.Reason = 'PartitionViewUnavailable'
            return $evidence
        }
        $listed = @()
        if ($null -ne $Probe.Value) { $listed = @($Probe.Value) }
        if ($listed.Count -eq 0) {
            # An empty answer proves a disk with no LDM member only when the disk
            # itself agrees that it has no partitions. Otherwise the empty answer
            # is ambiguous (an uninitialised disk and a silently skipped read look
            # identical), so it is reported as unproven.
            $evidence.Stated = $false
            $evidence.Reason = 'PartitionListEmptyWithoutCount'
            return $evidence
        }
        foreach ($partition in $listed) {
            if ($null -eq $partition) { continue }
            $evidence.PartitionCount = $evidence.PartitionCount + 1
            $gptType = & $FieldReader $partition 'GptType'
            $mbrType = & $FieldReader $partition 'MbrType'
            # A blank string is not a statement: a partition that publishes an
            # empty GptType and no MbrType used to count as a proven non-LDM
            # partition, which made an unknown type look like a known one.
            $gptStated = -not [string]::IsNullOrWhiteSpace([string]$gptType)
            $mbrText = [string]$mbrType
            $mbrStated = -not [string]::IsNullOrWhiteSpace($mbrText)
            if (-not $gptStated -and -not $mbrStated) {
                $evidence.Stated = $false
                $evidence.Reason = 'PartitionTypeUnstated'
                return $evidence
            }
            if ($gptStated) {
                $gptText = ([string]$gptType).Trim().Trim('{', '}').ToLowerInvariant()
                if ($gptText -eq '5808c8aa-7e8f-42e0-85d2-e1e90434cfb3' -or $gptText -eq 'af9b60a0-1431-4f62-bc68-3311714a69ad') {
                    $evidence.HasLdm = $true
                }
            }
            if ($mbrStated) {
                $parsedMbr = -1
                if ([int]::TryParse($mbrText, [ref]$parsedMbr)) {
                    if ($parsedMbr -eq 0x42) { $evidence.HasLdm = $true }
                }
                else {
                    $evidence.Stated = $false
                    $evidence.Reason = 'PartitionTypeUnstated'
                    return $evidence
                }
            }
        }
        $evidence.Stated = $true
        $evidence.Reason = 'PartitionTypesRead'
        return $evidence
    }

    $pathChainReader = {
        param([string]$Path, [object]$ItemQuery, [object]$FieldReader, [object]$SeamInvoker)
        # Reparse resolution. A directory can be reached through a junction, a
        # mount point, or a symbolic link, and the reviewed path is only proven
        # when every component on the way was resolved. The documented Windows
        # PowerShell 5.1 surface for that is Get-Item with -Force, which reports
        # the ReparsePoint attribute plus LinkType and Target for a link, so the
        # chain is walked one component at a time and any component that states
        # neither a link nor a resolved target leaves the chain unproven.
        $result = [pscustomobject]@{
            Resolved    = $false
            ReparseCount = 0
            Evidence    = 'PathChainUnavailable'
            Description = ''
        }
        if ([string]::IsNullOrWhiteSpace($Path)) { return $result }
        $current = $Path
        $depth = 0
        $chain = New-Object System.Collections.Generic.List[string]
        while ($depth -lt 8) {
            $depth = $depth + 1
            $item = & $SeamInvoker $ItemQuery @{ Operation = 'ItemByPath'; Path = $current }
            if ($null -eq $item) {
                $result.Evidence = 'PathComponentUnavailable'
                return $result
            }
            $attributes = [string](& $FieldReader $item 'Attributes')
            $isReparse = $attributes.Contains('ReparsePoint')
            if ($isReparse) {
                $result.ReparseCount = $result.ReparseCount + 1
                $target = & $FieldReader $item 'Target'
                if ($null -eq $target) { $target = & $FieldReader $item 'LinkTarget' }
                if ($null -eq $target -or [string]::IsNullOrWhiteSpace([string]$target)) {
                    $result.Evidence = 'ReparseTargetUnavailable'
                    return $result
                }
                $targetText = [string]$target
                if ($targetText.StartsWith('\\?\')) { $targetText = $targetText.Substring(4) }
                $chain.Add($targetText) | Out-Null
                $current = $targetText
                continue
            }
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrEmpty($parent)) {
                $result.Resolved = $true
                $result.Evidence = 'ReparseChainResolved'
                $result.Description = [string]::Join(' -> ', $chain.ToArray())
                return $result
            }
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
                $result.Resolved = $true
                $result.Evidence = 'ReparseChainResolved'
                $result.Description = [string]::Join(' -> ', $chain.ToArray())
                return $result
            }
            $nextParent = & $SeamInvoker $ItemQuery @{ Operation = 'ItemByPath'; Path = $parent }
            if ($null -eq $nextParent) {
                # The provider cannot walk the ancestor chain, so resolution is
                # unproven rather than assumed.
                $result.Evidence = 'PathAncestorUnavailable'
                return $result
            }
            $parentAttributes = [string](& $FieldReader $nextParent 'Attributes')
            if ($parentAttributes.Contains('ReparsePoint')) {
                $parentTarget = & $FieldReader $nextParent 'Target'
                if ($null -eq $parentTarget) { $parentTarget = & $FieldReader $nextParent 'LinkTarget' }
                if ($null -eq $parentTarget -or [string]::IsNullOrWhiteSpace([string]$parentTarget)) {
                    $result.Evidence = 'ReparseTargetUnavailable'
                    return $result
                }
                $result.ReparseCount = $result.ReparseCount + 1
                $parentTargetText = [string]$parentTarget
                if ($parentTargetText.StartsWith('\\?\')) { $parentTargetText = $parentTargetText.Substring(4) }
                $chain.Add($parentTargetText) | Out-Null
                $current = $parentTargetText
                continue
            }
            $current = $parent
        }
        $result.Evidence = 'ReparseDepthExceeded'
        return $result
    }

    if ($null -eq $VolumeQuery) {
        $VolumeQuery = {
            param($request)
            $operation = [string]$request['Operation']
            if ($operation -eq 'ListVolumes') { return @(Get-Volume -ErrorAction Stop) }
            if ($operation -eq 'VolumeForPath') { return @(Get-Volume -FilePath ([string]$request['Path']) -ErrorAction Stop) }
            throw ('Unsupported volume query operation: ' + $operation)
        }
    }
    if ($null -eq $PartitionQuery) {
        $PartitionQuery = {
            param($request)
            $operation = [string]$request['Operation']
            if ($operation -eq 'PartitionsForVolume') {
                $volume = $request['Volume']
                if ($null -eq $volume) { return @() }
                return @(Get-Partition -Volume $volume -ErrorAction Stop)
            }
            if ($operation -eq 'PartitionsForDriveLetter') {
                $letter = [string]$request['DriveLetter']
                if ([string]::IsNullOrWhiteSpace($letter)) { return @() }
                return @(Get-Partition -DriveLetter $letter -ErrorAction Stop)
            }
            if ($operation -eq 'PartitionsForDisk') {
                $diskNumber = [int]$request['DiskNumber']
                return @(Get-Partition -DiskNumber $diskNumber -ErrorAction Stop)
            }
            throw ('Unsupported partition query operation: ' + $operation)
        }
    }
    if ($null -eq $DiskQuery) {
        $DiskQuery = {
            param($request)
            return @(Get-Disk -Number ([int]$request['DiskNumber']) -ErrorAction Stop)
        }
    }
    if ($null -eq $ItemQuery) {
        $ItemQuery = {
            param($request)
            return (Get-Item -LiteralPath ([string]$request['Path']) -Force -ErrorAction Stop)
        }
    }

    $provider = @{}
    $provider.Name = 'WindowsStorageReadOnly'
    $provider.GetVolumes = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($volume in @(& $seamInvoker $VolumeQuery @{ Operation = 'ListVolumes' })) {
            if ($null -eq $volume) { continue }
            # A volume without a drive letter is still reported: a mounted-folder
            # volume can share physical storage with the source, and dropping it
            # would hide that overlap instead of blocking it.
            $letter = [string](& $fieldReader $volume 'DriveLetter')
            $membership = & $membershipReader $volume $PartitionQuery $fieldReader $seamInvoker $fieldPresenceReader
            $canonical = ''
            if (-not [string]::IsNullOrWhiteSpace($letter)) { $canonical = $letter + ':\' }
            $diskNumber = $null
            if ((-not $membership.Incomplete) -and (@($membership.DiskNumbers).Count -eq 1)) { $diskNumber = @($membership.DiskNumbers)[0] }
            [void]$items.Add([pscustomobject]@{
                DriveLetter = $letter
                AccessPaths = @((& $fieldReader $volume 'Path'))
                CanonicalPath = $canonical
                Path = & $fieldReader $volume 'Path'
                VolumeGuid = & $fieldReader $volume 'UniqueId'
                FileSystemLabel = & $fieldReader $volume 'FileSystemLabel'
                FileSystem = & $fieldReader $volume 'FileSystem'
                SizeBytes = & $fieldReader $volume 'Size'
                SizeRemainingBytes = & $fieldReader $volume 'SizeRemaining'
                PartitionNumber = $membership.PartitionNumber
                DiskNumber = $diskNumber
                PhysicalDiskNumbers = @($membership.DiskNumbers)
                MembersIncomplete = $membership.Incomplete
                MembershipEvidence = $membership.IncompleteReason
            })
        }
        return $items.ToArray()
    }.GetNewClosure()
    $provider.GetDisks = {
        param($request)
        $number = [int]$request['DiskNumber']
        $matches = @(& $seamInvoker $DiskQuery @{ Operation = 'DiskByNumber'; DiskNumber = $number })
        $disk = $null
        foreach ($candidate in $matches) {
            if ($null -eq $candidate) { continue }
            $candidateNumber = & $fieldReader $candidate 'Number'
            if ($null -eq $candidateNumber) { $candidateNumber = & $fieldReader $candidate 'DiskNumber' }
            if ($null -eq $candidateNumber) { continue }
            if ([int]$candidateNumber -eq $number) { $disk = $candidate; break }
        }
        if ($null -eq $disk) { return @() }
        # Dynamic-disk evidence, in order of strength: a disk view that states the
        # dynamic flag decides on its own; otherwise the partition view is asked
        # for LDM membership, because a dynamic disk is built out of LDM
        # partitions. A view that proves neither is not evidence of a basic disk,
        # so completeness is withheld and the module reports MembersIncomplete
        # (indeterminate) instead of a safe mapping.
        $dynamicValue = & $fieldReader $disk 'IsDynamic'
        $busValue = & $fieldReader $disk 'BusType'
        if ($null -eq $busValue) { $busValue = & $fieldReader $disk 'BusTypeString' }
        $dynamicStated = ($null -ne $dynamicValue) -and ($dynamicValue -is [bool])
        $busStated = ($null -ne $busValue)
        $partitionStyleValue = & $fieldReader $disk 'PartitionStyle'
        $partitionStyleStated = ($null -ne $partitionStyleValue)
        $declaredPartitionCount = & $fieldReader $disk 'NumberOfPartitions'
        $isDynamic = $null
        $basicDiskEvidence = $null
        if ($dynamicStated) {
            $isDynamic = [bool]$dynamicValue
            if ($isDynamic) { $basicDiskEvidence = 'DiskViewStatesDynamic' }
            else { $basicDiskEvidence = 'DiskViewStatesBasic' }
        }
        else {
            $partitionEvidence = [pscustomobject]@{ Stated = $false; HasLdm = $false; PartitionCount = 0; Reason = 'PartitionViewUnavailable' }
            if ($partitionStyleStated) {
                $probe = & $seamProbe $PartitionQuery @{ Operation = 'PartitionsForDisk'; DiskNumber = $number }
                $partitionEvidence = & $diskTopologyReader $probe $fieldReader
                if ($partitionEvidence.Stated) {
                    if ($null -eq $declaredPartitionCount) {
                        $partitionEvidence.Stated = $false
                        $partitionEvidence.Reason = 'PartitionCountUnstated'
                    }
                    else {
                        $declaredCount = -1
                        if ([int]::TryParse([string]$declaredPartitionCount, [ref]$declaredCount)) {
                            # A partition view that reports fewer partitions than
                            # the disk itself declares cannot prove the absence of
                            # an LDM member, so it stays unproven.
                            if ($declaredCount -gt $partitionEvidence.PartitionCount) {
                                $partitionEvidence.Stated = $false
                                $partitionEvidence.Reason = 'PartitionCountMismatch'
                            }

                        }
                        else {
                            $partitionEvidence.Stated = $false
                            $partitionEvidence.Reason = 'PartitionCountUnstated'
                        }
                    }
                }
            }
            if ($partitionEvidence.Stated) {
                $isDynamic = [bool]$partitionEvidence.HasLdm
                if ($partitionEvidence.HasLdm) { $basicDiskEvidence = 'LdmPartitionPresent' }
                else { $basicDiskEvidence = 'NoLdmPartitionPresent' }
            }
        }
        $topologyProven = $false
        if ($dynamicStated) { $topologyProven = $true }
        elseif ($partitionStyleStated -and ($null -ne $isDynamic)) { $topologyProven = $true }
        return [pscustomobject]@{
            DiskNumber = & $fieldReader $disk 'Number'
            UniqueId = & $fieldReader $disk 'UniqueId'
            UniqueIdFormat = [string](& $fieldReader $disk 'UniqueIdFormat')
            SerialNumber = & $fieldReader $disk 'SerialNumber'
            Model = & $fieldReader $disk 'Model'
            FriendlyName = & $fieldReader $disk 'FriendlyName'
            Manufacturer = & $fieldReader $disk 'Manufacturer'
            SizeBytes = & $fieldReader $disk 'Size'
            BusType = if ($busStated) { [int]$busValue } else { $null }
            Location = & $fieldReader $disk 'Location'
            PNPDeviceID = & $fieldReader $disk 'PNPDeviceID'
            HealthStatus = & $fieldReader $disk 'HealthStatus'
            OperationalStatus = & $fieldReader $disk 'OperationalStatus'
            IsDynamic = $isDynamic
            PartitionStyle = if ($partitionStyleStated) { $partitionStyleValue } else { $null }
            BasicDiskEvidence = $basicDiskEvidence
            MembersIncomplete = ((-not $topologyProven) -or (-not $busStated))
        }
    }.GetNewClosure()
    $provider.ResolvePath = {
        param($request)
        $path = [string]$request['Path']
        $record = [pscustomobject]@{
            CanonicalPath = $path
            Exists = $false
            IsContainer = $false
            IsReparsePoint = $true
            ReparseResolved = $false
            ReparseCount = 0
            ReparseEvidence = 'PathChainUnavailable'
            VolumeGuid = $null
            VolumePath = $null
            DriveLetter = $null
            PartitionNumber = $null
            DiskNumber = $null
            PhysicalDiskNumbers = @()
            MembersIncomplete = $true
            MembershipEvidence = 'VolumeUnresolved'
        }
        $item = & $seamInvoker $ItemQuery @{ Operation = 'ItemByPath'; Path = $path }
        if ($null -ne $item) {
            $canonical = [string](& $fieldReader $item 'FullName')
            if (-not [string]::IsNullOrWhiteSpace($canonical)) { $record.CanonicalPath = $canonical }
            $record.Exists = $true
            $record.IsContainer = ((& $fieldReader $item 'PSIsContainer') -eq $true)
            $record.IsReparsePoint = ([string](& $fieldReader $item 'Attributes')).Contains('ReparsePoint')
            # Existence is not resolution. Every component of the path is walked
            # before the path may be treated as the reviewed location.
            $chain = & $pathChainReader $path $ItemQuery $fieldReader $seamInvoker
            $record.ReparseResolved = [bool]$chain.Resolved
            $record.ReparseCount = [int]$chain.ReparseCount
            $record.ReparseEvidence = [string]$chain.Evidence
        }
        $volume = $null
        foreach ($candidate in @(& $seamInvoker $VolumeQuery @{ Operation = 'VolumeForPath'; Path = $path })) {
            if ($null -ne $candidate) { $volume = $candidate; break }
        }
        if ($null -ne $volume) {
            $record.VolumeGuid = & $fieldReader $volume 'UniqueId'
            $record.VolumePath = & $fieldReader $volume 'Path'
            $record.DriveLetter = [string](& $fieldReader $volume 'DriveLetter')
            $membership = & $membershipReader $volume $PartitionQuery $fieldReader $seamInvoker $fieldPresenceReader
            $record.PhysicalDiskNumbers = @($membership.DiskNumbers)
            $record.PartitionNumber = $membership.PartitionNumber
            $record.MembersIncomplete = $membership.Incomplete
            $record.MembershipEvidence = $membership.IncompleteReason
            if ((-not $membership.Incomplete) -and (@($membership.DiskNumbers).Count -eq 1)) {
                $record.DiskNumber = @($membership.DiskNumbers)[0]
            }
        }
        return $record
    }.GetNewClosure()
    $provider.GetFreeSpace = {
        param($request)
        $volume = $null
        foreach ($candidate in @(& $seamInvoker $VolumeQuery @{ Operation = 'VolumeForPath'; Path = [string]$request['Path'] })) {
            if ($null -ne $candidate) { $volume = $candidate; break }
        }
        if ($null -eq $volume) { throw 'The volume backing the path could not be resolved for a capacity reading.' }
        $remaining = & $fieldReader $volume 'SizeRemaining'
        if ($null -eq $remaining) { throw 'The volume did not report remaining capacity.' }
        return [pscustomobject]@{
            VolumeAvailableBytes = [int64]$remaining
            UserAvailableBytes = [int64]$remaining
        }
    }.GetNewClosure()
    return $provider
}

function ConvertTo-RecoveryAutomationExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][ValidateSet('FileScavenger', 'RStudio')][string]$Product
    )

    $path = [string](Get-RecoveryAutomationValue -InputObject $Candidate -Names @('Path', 'ExecutablePath', 'FullName'))
    $fileVersion = [string](Get-RecoveryAutomationValue -InputObject $Candidate -Names @('FileVersion', 'ProductVersion', 'Version'))
    $productVersion = [string](Get-RecoveryAutomationValue -InputObject $Candidate -Names @('ProductVersion', 'FileVersion', 'Version'))
    $productName = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('ProductName', 'Name')
    if ([string]::IsNullOrWhiteSpace([string]$productName)) {
        if ($Product -eq 'FileScavenger') { $productName = 'File Scavenger' } else { $productName = 'R-Studio' }
    }
    $canonicalProduct = $Product
    if ($Product -eq 'FileScavenger') { $canonicalProduct = 'File Scavenger' }
    return [pscustomobject]@{
        Path = $path
        ExecutablePath = $path
        Product = $canonicalProduct
        ProductName = [string]$productName
        FileVersion = $fileVersion
        ProductVersion = $productVersion
        Version = $productVersion
        Exists = $true
        Readable = $true
        IdentityStatus = 'Verified'
        BuildStatus = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('BuildStatus')
        EvidenceSource = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('EvidenceSource', 'Evidence')
        OriginalFilename = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('OriginalFilename')
        CompanyName = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('CompanyName')
        Publisher = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('Publisher')
        FileDescription = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('FileDescription')
        FileVersionInfoVerified = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('FileVersionInfoVerified')
        OwnerValidated = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('OwnerValidated')
        OwnerEvidence = Get-RecoveryAutomationValue -InputObject $Candidate -Names @('OwnerEvidence')
    }
}

function Get-RecoveryAutomationSourceSelection {
    [CmdletBinding()]
    param(
        [string]$ExplicitPath = '',
        [scriptblock]$Selector = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [pscustomobject]@{ Selected = $true; Path = $ExplicitPath.Trim(); Evidence = 'Explicit source path.'; Raw = $null; ReasonCode = $null }
    }
    if ($null -eq $Selector) {
        return [pscustomobject]@{ Selected = $false; Path = $null; Evidence = 'No source selector was supplied.'; Raw = $null; ReasonCode = 'SourceNotSelected' }
    }
    try {
        $raw = & $Selector ([pscustomobject]@{ Purpose = 'SourceSelection' })
    }
    catch {
        return [pscustomobject]@{ Selected = $false; Path = $null; Evidence = $_.Exception.Message; Raw = $null; ReasonCode = 'SourceSelectionFailed' }
    }
    if ($raw -is [string]) {
        $path = ([string]$raw).Trim()
        if ($path.Length -gt 0) { return [pscustomobject]@{ Selected = $true; Path = $path; Evidence = 'Source selector result.'; Raw = $raw; ReasonCode = $null } }
    }
    else {
        $pathValue = Get-RecoveryAutomationValue -InputObject $raw -Names @('Path', 'SelectedPath', 'SourcePath')
        if ($null -ne $pathValue -and -not [string]::IsNullOrWhiteSpace([string]$pathValue)) {
            $selectedValue = Get-RecoveryAutomationValue -InputObject $raw -Names @('Selected', 'Accepted')
            if ($null -eq $selectedValue -or (Test-RecoveryAutomationBoolean $selectedValue)) {
                return [pscustomobject]@{ Selected = $true; Path = ([string]$pathValue).Trim(); Evidence = Get-RecoveryAutomationValue -InputObject $raw -Names @('Evidence', 'Reason'); Raw = $raw; ReasonCode = $null }
            }
        }
    }
    return [pscustomobject]@{ Selected = $false; Path = $null; Evidence = (Get-RecoveryAutomationSelectorEvidence -Raw $raw); Raw = $raw; ReasonCode = 'SourceNotSelected' }
}

function Get-RecoveryAutomationSelectorEvidence {
    [CmdletBinding()]
    param([AllowNull()][object]$Raw)

    # The selector's own evidence text is preserved for the technician when the
    # selection fails, so a cancelled or unavailable picker is distinguishable
    # from a selector that was never supplied.
    $evidence = Get-RecoveryAutomationValue -InputObject $Raw -Names @('Evidence', 'Reason', 'Message')
    if ($null -eq $evidence -or [string]::IsNullOrWhiteSpace([string]$evidence)) {
        return 'The source selector returned no usable path.'
    }
    return [string]$evidence
}

function Test-RecoveryAutomationSourceProtection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object]$Selection,
        [scriptblock]$Provider = $null
    )

    # Every verified result carries an EvidenceKind so the record distinguishes
    # an explicit operator attestation from a measured read-only/write-blocker
    # observation. The default front door can only ever produce an attestation;
    # a measurement has to arrive through a provider that reports one.
    $selectionValues = @(
        Get-RecoveryAutomationValue -InputObject $Selection -Names @('ReadOnlyVerified', 'WriteBlocked', 'SourceProtected', 'HardwareWriteBlocked')
    )
    foreach ($value in $selectionValues) {
        if (Test-RecoveryAutomationBoolean $value) {
            return [pscustomobject]@{ Verified = $true; Evidence = 'Source selection included read-only/write-blocker evidence.'; EvidenceKind = 'SelectionDeclared'; ReasonCode = $null; Raw = $Selection }
        }
    }
    if ($null -eq $Provider) {
        return [pscustomobject]@{ Verified = $false; Evidence = 'No read-only or write-blocker evidence was supplied.'; EvidenceKind = 'Unspecified'; ReasonCode = 'SourceProtectionUnverified'; Raw = $null }
    }
    try {
        $raw = & $Provider ([pscustomobject]@{ Purpose = 'SourceProtection'; Path = $Path; Selection = $Selection })
    }
    catch {
        return [pscustomobject]@{ Verified = $false; Evidence = $_.Exception.Message; EvidenceKind = 'Unspecified'; ReasonCode = 'SourceProtectionCheckFailed'; Raw = $null }
    }
    if ($raw -is [bool]) {
        return [pscustomobject]@{ Verified = [bool]$raw; Evidence = 'Source protection provider Boolean result.'; EvidenceKind = 'ProviderDeclared'; ReasonCode = if ($raw) { $null } else { 'SourceProtectionUnverified' }; Raw = $raw }
    }
    $verified = Get-RecoveryAutomationValue -InputObject $raw -Names @('Verified', 'ReadOnlyVerified', 'WriteBlocked', 'SourceProtected', 'HardwareWriteBlocked')
    $evidence = Get-RecoveryAutomationValue -InputObject $raw -Names @('Evidence', 'Message', 'Reason')
    $reportedKind = Get-RecoveryAutomationValue -InputObject $raw -Names @('EvidenceKind', 'AttestationKind', 'Kind')
    $evidenceKind = 'ProviderDeclared'
    if ($null -ne $reportedKind -and -not [string]::IsNullOrWhiteSpace([string]$reportedKind)) {
        $kindText = [string]$reportedKind
        if ($kindText.ToLowerInvariant().Contains('attest')) { $evidenceKind = 'OperatorAttestation' }
        elseif ($kindText.ToLowerInvariant().Contains('measured')) { $evidenceKind = 'MeasuredState' }
        else { $evidenceKind = $kindText }
    }
    $isVerified = Test-RecoveryAutomationBoolean $verified
    return [pscustomobject]@{ Verified = $isVerified; Evidence = $evidence; EvidenceKind = $evidenceKind; ReasonCode = if ($isVerified) { $null } else { 'SourceProtectionUnverified' }; Raw = $raw }
}

function Get-RecoveryAutomationFrontDoorWiring {
    [CmdletBinding()]
    param(
        [scriptblock]$SourceSelector = $null,
        [scriptblock]$SourceProtectionProvider = $null,
        [scriptblock]$DestinationPickerProvider = $null,
        [scriptblock]$TypedDestinationProvider = $null,
        [scriptblock]$InteractionProvider = $null,
        [scriptblock]$ClientNameProvider = $null
    )

    # The default front door wires the documented interactive seams when none
    # were injected, so a launcher double-click is a usable workflow instead of
    # a dead end. Injection always wins. Nothing here decides a safety question:
    # every provider answers through the same validation an injected seam uses.
    # Source protection stays an explicit technician step - the default provider
    # records an operator attestation, never a measured observation.
    Import-RecoveryAutomationModules

    $evidence = New-Object System.Collections.ArrayList
    $plan = @(
        [pscustomobject]@{ Name = 'SourceSelector'; Value = $SourceSelector; DefaultName = 'SourceSelectorProvider' },
        [pscustomobject]@{ Name = 'SourceProtectionProvider'; Value = $SourceProtectionProvider; DefaultName = 'SourceProtectionAttestationProvider' },
        [pscustomobject]@{ Name = 'DestinationPickerProvider'; Value = $DestinationPickerProvider; DefaultName = 'PickerProvider' },
        [pscustomobject]@{ Name = 'TypedDestinationProvider'; Value = $TypedDestinationProvider; DefaultName = 'TypedPathProvider' },
        [pscustomobject]@{ Name = 'InteractionProvider'; Value = $InteractionProvider; DefaultName = 'InteractionProvider' },
        [pscustomobject]@{ Name = 'ClientNameProvider'; Value = $ClientNameProvider; DefaultName = 'ClientNameProvider' }
    )
    $resolved = @{}
    foreach ($entry in $plan) {
        $source = 'InteractiveDefault'
        $provider = $entry.Value
        if ($null -ne $provider) {
            $source = 'Injected'
        }
        else {
            $provider = TechnicianUi\Get-TechnicianUiDefaultProvider -Name $entry.DefaultName
        }
        $resolved[$entry.Name] = $provider
        [void]$evidence.Add([pscustomobject]@{ Name = $entry.Name; Source = $source; DefaultName = $entry.DefaultName })
    }
    return [pscustomobject]@{
        SourceSelector            = $resolved['SourceSelector']
        SourceProtectionProvider  = $resolved['SourceProtectionProvider']
        DestinationPickerProvider = $resolved['DestinationPickerProvider']
        TypedDestinationProvider  = $resolved['TypedDestinationProvider']
        InteractionProvider       = $resolved['InteractionProvider']
        ClientNameProvider        = $resolved['ClientNameProvider']
        Evidence                  = $evidence.ToArray()
    }
}

function Write-RecoveryAutomationMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Metadata
    )

    $result = [pscustomobject]@{ Success = $false; Path = $Path; ReasonCode = $null; Message = $null }
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not $directory -or -not [System.IO.Directory]::Exists($directory)) {
        $result.ReasonCode = 'MetadataPathInvalid'
        $result.Message = 'The metadata directory does not exist.'
        return $result
    }
    try {
        $text = $Metadata | ConvertTo-Json -Depth 12 -Compress
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        $result.Success = $true
        return $result
    }
    catch {
        $result.ReasonCode = 'MetadataWriteFailed'
        $result.Message = $_.Exception.Message
        return $result
    }
}

function Invoke-RecoveryAutomationGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GateId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowNull()][object]$Evidence,
        [Parameter(Mandatory = $true)][object[]]$Choices,
        [Parameter(Mandatory = $true)][string]$SafeDefault,
        [scriptblock]$InteractionProvider = $null
    )

    $gate = UIAutomation\New-RecoveryManualGate -GateId $GateId -Reason $Reason -Evidence $Evidence -Choices $Choices -SafeDefault $SafeDefault
    $presentation = TechnicianUi\Show-RecoveryManualGate -Gate $gate -InteractionProvider $InteractionProvider
    $decision = [string]$presentation.Decision
    $continues = ($decision -ieq 'Continue' -or $decision -ieq 'Proceed' -or $decision -ieq 'Allowed')
    return [pscustomobject]@{ Gate = $gate; Presentation = $presentation; Decision = $decision; Continues = $continues; ReasonCode = $presentation.ReasonCode }
}

function Write-RecoveryAutomationEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Writer,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$EventType,
        [string]$Result = 'Recorded',
        [string]$Stage = $null,
        [string]$AttemptId = $null,
        [AllowNull()][object]$Decision = $null,
        [AllowNull()][object]$ErrorDetail = $null,
        [AllowNull()][object]$Gate = $null
    )

    $event = [pscustomobject]@{
        JobId = [string]$State.JobId
        State = [string]$State.State
        Stage = $Stage
        AttemptId = $AttemptId
        EventType = $EventType
        Result = $Result
        SourceIdentity = $State.SourceIdentity
        DestinationIdentity = $State.DestinationIdentity
        Decision = $Decision
        Error = $ErrorDetail
        Gate = $Gate
    }
    $writeResult = RecoveryLogging\Write-RecoveryLogEntry -Writer $Writer -Entry $event
    if ($null -ne $writeResult -and $writeResult.Success -eq $true) {
        $reportedSequence = Get-RecoveryAutomationValue -InputObject $writeResult -Names @('Sequence')
        if ($null -ne $reportedSequence) {
            $sequence = 0
            if ([int]::TryParse([string]$reportedSequence, [ref]$sequence) -and $sequence -gt [int]$State.LastEventSequence) {
                [void]($State.LastEventSequence = $sequence)
            }
        }
    }
    return $writeResult
}

function New-RecoveryAutomationStateWriter {
    [CmdletBinding()]
    param([AllowNull()][object]$Provider)

    if ($null -eq $Provider) { return $null }
    $wrapper = @{}
    $wrapper.Name = 'StrictRecoveryStateWriter'
    $wrapper.Write = {
        param($request)
        $operation = $null
        if ($Provider -is [scriptblock]) {
            $operation = $Provider
        }
        elseif ($Provider -is [System.Collections.IDictionary]) {
            if ($Provider.Contains('Write')) { $operation = $Provider['Write'] }
        }
        else {
            $property = $Provider.PSObject.Properties['Write']
            if ($null -ne $property) { $operation = $property.Value }
        }
        if ($operation -isnot [scriptblock]) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ProviderOperationMissing'; Message = 'The state writer does not expose a Write operation.' }
        }
        try {
            $outputs = @(& $operation $request)
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ProviderFailure'; Message = $_.Exception.Message }
        }
        if ($outputs.Count -ne 1) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ProviderResultAmbiguous'; Message = 'The state writer did not return exactly one result.' }
        }
        $value = $outputs[0]
        if ($value -is [bool]) {
            return [pscustomobject]@{ Success = [bool]$value; ReasonCode = if ($value) { $null } else { 'ProviderRefused' }; Message = $null }
        }
        $successProperty = $null
        if ($value -is [System.Collections.IDictionary]) {
            if ($value.Contains('Success')) { $successProperty = $value['Success'] }
        }
        else {
            $property = $value.PSObject.Properties['Success']
            if ($null -ne $property) { $successProperty = $property.Value }
        }
        if ($successProperty -isnot [bool]) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ProviderResultAmbiguous'; Message = 'The state writer result did not contain a Boolean Success value.' }
        }
        return $value
    }.GetNewClosure()
    return $wrapper
}

function Invoke-RecoveryAutomationEvidenceProvider {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Purpose,
        [AllowEmptyString()][string]$Stage = '',
        [AllowNull()][object]$State = $null,
        [AllowNull()][object]$ProcessIdentity = $null
    )

    $result = [pscustomobject]@{ Present = $false; Value = $null; ReasonCode = 'ProviderMissing'; Message = 'No operator evidence provider was supplied.' }
    if ($null -eq $Provider) { return $result }
    $operation = $null
    if ($Provider -is [scriptblock]) {
        $operation = $Provider
    }
    elseif ($Provider -is [System.Collections.IDictionary]) {
        foreach ($name in @($Purpose, 'GetEvidence', 'Observe', 'GetObservation', $Stage)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$name) -and $Provider.Contains($name)) {
                $candidate = $Provider[$name]
                if ($candidate -is [scriptblock]) { $operation = $candidate; break }
                if ($null -ne $candidate) {
                    return [pscustomobject]@{ Present = $true; Value = $candidate; ReasonCode = $null; Message = $null }
                }
            }
        }
        if ($null -eq $operation) {
            $knownEvidence = $false
            foreach ($name in @('ScanFinished', 'RecoveryFinished', 'OutputObserved', 'OutputVerificationPassed', 'GracefulCloseVerified', 'ProcessTerminated')) {
                if ($Provider.Contains($name)) { $knownEvidence = $true; break }
            }
            if ($knownEvidence) {
                return [pscustomobject]@{ Present = $true; Value = $Provider; ReasonCode = $null; Message = $null }
            }
        }
    }
    else {
        foreach ($name in @($Purpose, 'GetEvidence', 'Observe', 'GetObservation', $Stage)) {
            if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }
            $property = $Provider.PSObject.Properties[$name]
            if ($null -eq $property) { continue }
            $candidate = $property.Value
            if ($candidate -is [scriptblock]) { $operation = $candidate; break }
            if ($null -ne $candidate) {
                return [pscustomobject]@{ Present = $true; Value = $candidate; ReasonCode = $null; Message = $null }
            }
        }
        if ($null -eq $operation) {
            foreach ($name in @('ScanFinished', 'RecoveryFinished', 'OutputObserved', 'OutputVerificationPassed', 'GracefulCloseVerified', 'ProcessTerminated')) {
                if ($null -ne $Provider.PSObject.Properties[$name]) {
                    return [pscustomobject]@{ Present = $true; Value = $Provider; ReasonCode = $null; Message = $null }
                }
            }
        }
    }
    if ($null -eq $operation) {
        $result.ReasonCode = 'ProviderOperationMissing'
        $result.Message = ("The operator evidence provider has no operation for '{0}'." -f $Purpose)
        return $result
    }
    $request = [pscustomobject]@{
        Purpose = $Purpose
        Stage = $Stage
        State = $State
        ProcessIdentity = $ProcessIdentity
    }
    try {
        $outputs = @(& $operation $request)
    }
    catch {
        $result.ReasonCode = 'ProviderFailure'
        $result.Message = $_.Exception.Message
        return $result
    }
    if ($outputs.Count -eq 0) {
        $result.ReasonCode = 'ProviderResultMissing'
        $result.Message = 'The operator evidence provider returned no observation.'
        return $result
    }
    if ($outputs.Count -ne 1) {
        $result.ReasonCode = 'ProviderResultAmbiguous'
        $result.Message = 'The operator evidence provider returned more than one observation.'
        return $result
    }
    $result.Present = $true
    $result.Value = $outputs[0]
    $result.ReasonCode = $null
    $result.Message = $null
    return $result
}

function Merge-RecoveryAutomationObservation {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Base,
        [AllowNull()][object]$Overlay
    )

    if ($null -eq $Base) { return $Overlay }
    if ($null -eq $Overlay) { return $Base }
    foreach ($property in $Overlay.PSObject.Properties) {
        $existing = $Base.PSObject.Properties[$property.Name]
        if ($null -ne $existing) {
            $existing.Value = $property.Value
        }
        else {
            $Base | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    return $Base
}

function Get-RecoveryAutomationFileScavengerObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [AllowNull()][object]$ProcessIdentity,
        [scriptblock]$UiProvider = $null,
        [scriptblock]$OutputProvider = $null,
        [AllowNull()][object]$OperatorEvidenceProvider = $null,
        [AllowEmptyString()][string]$Stage = ''
    )

    $operator = Invoke-RecoveryAutomationEvidenceProvider -Provider $OperatorEvidenceProvider `
        -Purpose 'FileScavengerObservation' -Stage $Stage -State $State -ProcessIdentity $ProcessIdentity
    $operatorValue = $null
    if ($operator.Present) { $operatorValue = $operator.Value }
    $outputAdapter = $OutputProvider
    if ($null -eq $outputAdapter -and $operator.Present) {
        $outputAdapter = {
            return $operatorValue
        }.GetNewClosure()
    }
    elseif ($null -ne $outputAdapter) {
        $outputSource = $outputAdapter
        $outputAdapter = {
            param($request)
            return (& $outputSource ([pscustomobject]@{ Purpose = 'OutputObservation'; Stage = $Stage; State = $State; ProcessIdentity = $ProcessIdentity }))
        }.GetNewClosure()
    }
    $observation = FileScavenger\Get-FileScavengerObservation -ProcessIdentity $ProcessIdentity `
        -AppStateProvider $UiProvider -OutputProvider $outputAdapter
    if ($operator.Present) {
        $observation = Merge-RecoveryAutomationObservation -Base $observation -Overlay $operatorValue
    }
    if (-not $operator.Present -and $null -ne $operator.ReasonCode) {
        $observation | Add-Member -NotePropertyName OperatorEvidenceReasonCode -NotePropertyValue $operator.ReasonCode -Force
        $observation | Add-Member -NotePropertyName OperatorEvidenceMessage -NotePropertyValue $operator.Message -Force
    }
    return $observation
}

function Save-RecoveryAutomationGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][object]$LogWriter,
        [Parameter(Mandatory = $true)][object]$GateResult,
        [Parameter(Mandatory = $true)][AllowNull()][object]$StateWriter,
        [AllowEmptyString()][string]$Stage = '',
        [AllowEmptyString()][string]$AttemptId = ''
    )

    $presented = $GateResult.Presentation
    $gate = $GateResult.Gate
    $decision = [string]$GateResult.Decision
    $presentedEvent = Write-RecoveryAutomationEvent -Writer $LogWriter -State $State `
        -EventType 'OperatorGatePresented' -Result 'Presented' -Stage $Stage -AttemptId $AttemptId `
        -Decision $decision -Gate $gate
    if ($null -eq $presentedEvent -or $presentedEvent.Success -ne $true) {
        return [pscustomobject]@{ Success = $false; ReasonCode = 'GateEventWriteFailed'; Message = 'The operator gate presentation was not durably recorded.' }
    }
    $decisionEvent = Write-RecoveryAutomationEvent -Writer $LogWriter -State $State `
        -EventType 'OperatorDecision' -Result 'Recorded' -Stage $Stage -AttemptId $AttemptId `
        -Decision $decision -Gate $gate
    if ($null -eq $decisionEvent -or $decisionEvent.Success -ne $true) {
        return [pscustomobject]@{ Success = $false; ReasonCode = 'GateEventWriteFailed'; Message = 'The operator gate decision was not durably recorded.' }
    }
    $existingDecisions = @()
    if ($null -ne $State.PSObject.Properties['GateDecisions']) { $existingDecisions = @($State.GateDecisions) }
    $State.GateDecisions = @($existingDecisions + @($presented))
    $snapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
    if ($null -eq $snapshot -or $snapshot.Success -ne $true) {
        return [pscustomobject]@{ Success = $false; ReasonCode = 'GateStateWriteFailed'; Message = 'The operator gate decision was not durably snapshotted.' }
    }
    return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null; Presentation = $presented }
}

function Test-RecoveryAutomationFreshSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$DiskProvider,
        [AllowNull()][object]$SourceSelection,
        [AllowNull()][object]$PreviousProtection,
        [scriptblock]$SourceProtectionProvider = $null,
        [int64]$ReserveBytes = 0,
        [switch]$RequireFreshProtectionProvider
    )

    $source = DiskDetection\Resolve-RecoveryPathIdentity -Path $SourcePath -Provider $DiskProvider
    $destination = DiskDetection\Resolve-RecoveryPathIdentity -Path $DestinationPath -Provider $DiskProvider
    $separation = DiskDetection\Test-DestinationSafety -SourceIdentity $source -DestinationPath $DestinationPath `
        -Provider $DiskProvider -DestinationIdentity $destination
    $space = DiskDetection\Get-RecoveryDestinationSpace -Path $DestinationPath -Provider $DiskProvider -ReserveBytes $ReserveBytes
    $selection = $SourceSelection
    if ($null -eq $selection -and $null -ne $PreviousProtection) { $selection = $PreviousProtection.Raw }
    # This function is invoked through ${function:Test-RecoveryAutomationFreshSafety}
    # .GetNewClosure(), which gives its body its own dynamic module: a call to a
    # script-scope function such as Test-RecoveryAutomationSourceProtection fails
    # with CommandNotFoundException here, which is why the protection classification
    # is resolved by a captured script block instead of by calling the shared
    # function. The classification below must stay identical to the shared function,
    # including EvidenceKind, which is what separates an operator attestation from a
    # measured read-only observation in the record that authorizes the handoff.
    # Self-contained on purpose: this body runs inside a closure, so it cannot call
    # any script-scope helper (Get-RecoveryAutomationValue, Test-RecoveryAutomationBoolean)
    # or the shared Test-RecoveryAutomationSourceProtection. Property access is
    # written out, and the classification must stay identical to the shared
    # function, including EvidenceKind, which is what separates an operator
    # attestation from a measured read-only observation in the record that
    # authorizes the handoff.
    $protectionResolver = {
        param([string]$Path, [AllowNull()][object]$Selection, [scriptblock]$Provider)

        $readValue = {
            param([object]$Object, [string[]]$Names)
            foreach ($name in $Names) {
                if ($null -eq $Object) { return $null }
                if ($Object -is [System.Collections.IDictionary]) {
                    if ($Object.Contains($name)) { return $Object[$name] }
                    continue
                }
                $property = $Object.PSObject.Properties[$name]
                if ($null -ne $property) { return $property.Value }
            }
            return $null
        }
        $readBoolean = {
            param([object]$Value)
            if ($null -eq $Value) { return $false }
            if ($Value -is [bool]) { return [bool]$Value }
            $parsed = $false
            if ([bool]::TryParse(([string]$Value), [ref]$parsed)) { return $parsed }
            return $false
        }

        foreach ($name in @('ReadOnlyVerified', 'WriteBlocked', 'SourceProtected', 'HardwareWriteBlocked')) {
            if (& $readBoolean (& $readValue $Selection @($name))) {
                return [pscustomobject]@{ Verified = $true; Evidence = 'Source selection included read-only/write-blocker evidence.'; EvidenceKind = 'SelectionDeclared'; ReasonCode = $null; Raw = $Selection }
            }
        }
        if ($null -eq $Provider) {
            return [pscustomobject]@{ Verified = $false; Evidence = 'No read-only or write-blocker evidence was supplied.'; EvidenceKind = 'Unspecified'; ReasonCode = 'SourceProtectionUnverified'; Raw = $null }
        }
        try {
            $raw = & $Provider ([pscustomobject]@{ Purpose = 'SourceProtection'; Path = $Path; Selection = $Selection })
        }
        catch {
            return [pscustomobject]@{ Verified = $false; Evidence = $_.Exception.Message; EvidenceKind = 'Unspecified'; ReasonCode = 'SourceProtectionCheckFailed'; Raw = $null }
        }
        if ($raw -is [bool]) {
            return [pscustomobject]@{ Verified = [bool]$raw; Evidence = 'Source protection provider Boolean result.'; EvidenceKind = 'ProviderDeclared'; ReasonCode = if ($raw) { $null } else { 'SourceProtectionUnverified' }; Raw = $raw }
        }
        $verified = & $readValue $raw @('Verified', 'ReadOnlyVerified', 'WriteBlocked', 'SourceProtected', 'HardwareWriteBlocked')
        $evidence = & $readValue $raw @('Evidence', 'Message', 'Reason')
        $reportedKind = & $readValue $raw @('EvidenceKind', 'AttestationKind', 'Kind')
        $evidenceKind = 'ProviderDeclared'
        if ($null -ne $reportedKind -and -not [string]::IsNullOrWhiteSpace([string]$reportedKind)) {
            $kindText = ([string]$reportedKind).ToLowerInvariant()
            if ($kindText.Contains('attest')) { $evidenceKind = 'OperatorAttestation' }
            elseif ($kindText.Contains('measured')) { $evidenceKind = 'MeasuredState' }
            else { $evidenceKind = [string]$reportedKind }
        }
        $isVerified = & $readBoolean $verified
        return [pscustomobject]@{ Verified = $isVerified; Evidence = $evidence; EvidenceKind = $evidenceKind; ReasonCode = if ($isVerified) { $null } else { 'SourceProtectionUnverified' }; Raw = $raw }
    }.GetNewClosure()
    if ($RequireFreshProtectionProvider -and $null -eq $SourceProtectionProvider) {
        $protection = [pscustomobject]@{
            Verified = $false
            Evidence = 'A fresh source-protection provider is required before an external vendor action.'
            EvidenceKind = 'Unspecified'
            ReasonCode = 'SourceProtectionUnverified'
            Raw = $null
        }
    }
    elseif ($RequireFreshProtectionProvider) {
        $protection = & $protectionResolver $SourcePath $null $SourceProtectionProvider
    }
    else {
        $protection = & $protectionResolver $SourcePath $selection $SourceProtectionProvider
    }
    $reason = $null
    if ($source.Resolved -ne $true -or $source.IsIndeterminate -eq $true) { $reason = 'SourceIndeterminate' }
    elseif (-not $protection.Verified) { $reason = $protection.ReasonCode }
    elseif (-not $separation.Allowed) { $reason = $separation.ReasonCode }
    elseif ($space.IsUnknown -or -not $space.IsSufficient) { $reason = $space.ReasonCode }
    return [pscustomobject]@{
        Passed = [string]::IsNullOrWhiteSpace([string]$reason)
        ReasonCode = $reason
        SourceIdentity = $source
        DestinationIdentity = $destination
        Separation = $separation
        Capacity = $space
        Protection = $protection
    }
}

function New-RecoveryAutomationStageResult {
    [CmdletBinding()]
    param(
        [bool]$Success,
        [object]$State,
        [string]$Stage,
        [string]$ReasonCode,
        [string]$Message,
        [object]$Gate = $null,
        [object]$Observation = $null,
        [object]$Completion = $null,
        [object]$StageRequest = $null
    )
    return [pscustomobject]@{
        Success = $Success
        State = $State
        Stage = $Stage
        ReasonCode = $ReasonCode
        Message = $Message
        Gate = $Gate
        Observation = $Observation
        Completion = $Completion
        StageRequest = $StageRequest
    }
}

function Invoke-RecoveryAutomationStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][object]$LogWriter,
        [Parameter(Mandatory = $true)][AllowNull()][object]$StateWriter,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$DiskProvider,
        [Parameter(Mandatory = $true)][AllowNull()][object]$SourceSelection,
        [AllowNull()][object]$PreviousProtection,
        [scriptblock]$SourceProtectionProvider = $null,
        [int64]$ReserveBytes = 0,
        [AllowNull()][object]$Executable,
        [AllowNull()][object]$EvidenceMap,
        [scriptblock]$UiProvider = $null,
        [scriptblock]$OutputProvider = $null,
        [AllowNull()][object]$OperatorEvidenceProvider = $null,
        [scriptblock]$InteractionProvider = $null,
        [scriptblock]$EventWriter = $null,
        [object]$Clock = $null
    )

    $fresh = Test-RecoveryAutomationFreshSafety -SourcePath $SourcePath -DestinationPath $DestinationPath `
        -DiskProvider $DiskProvider -SourceSelection $SourceSelection -PreviousProtection $PreviousProtection `
        -SourceProtectionProvider $SourceProtectionProvider -ReserveBytes $ReserveBytes -RequireFreshProtectionProvider
    if (-not $fresh.Passed) {
        $eventType = 'StageFailed'
        if ($fresh.ReasonCode -eq 'DestinationLowSpace' -or $fresh.ReasonCode -eq 'CapacityLow' -or $fresh.ReasonCode -eq 'CapacityUnknown') { $eventType = 'DestinationLowSpace' }
        elseif ($fresh.ReasonCode -eq 'DestinationLost') { $eventType = 'DestinationLost' }
        elseif ($fresh.ReasonCode -eq 'SourceProtectionUnverified' -or $fresh.ReasonCode -eq 'SourceProtectionCheckFailed') { $eventType = 'SourceIdentityChanged' }
        try { [void](Write-RecoveryAutomationEvent -Writer $LogWriter -State $State -EventType $eventType -Result 'Failed' -Stage $Stage -AttemptId $State.AttemptId -ErrorDetail $fresh.ReasonCode) } catch { }
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode $fresh.ReasonCode -Message 'Fresh source, destination, capacity, or protection evidence failed before the vendor action.'
    }

    $State.SourceIdentity = $fresh.SourceIdentity
    $State.SourceIdentity | Add-Member -NotePropertyName ReadOnlyVerified -NotePropertyValue $fresh.Protection.Verified -Force
    $State.SourceIdentity | Add-Member -NotePropertyName ReadOnlyEvidence -NotePropertyValue $fresh.Protection.Evidence -Force
    $State.DestinationIdentity = $fresh.DestinationIdentity
    $State.CapacityPolicy = $fresh.Capacity
    $State.SourceProtection = $fresh.Protection
    if ($null -ne $State.PSObject.Properties['Preconditions']) {
        $State.Preconditions.FreshSafetyCheckPassed = $true
    }
    $stageSnapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
    if ($null -eq $stageSnapshot -or $stageSnapshot.Success -ne $true) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'FreshSafetyStateWriteFailed' -Message 'Fresh source, destination, capacity, and protection evidence could not be durably snapshotted.'
    }

    $stageCheckState = $State
    if ($Stage -eq 'SHORT_SCAN' -and [string]$State.State -eq 'SHORT_SCAN_RUNNING') {
        $stageCheckState = $State.PSObject.Copy()
        $stageCheckState.State = 'CASE_READY'
    }
    $stageRequest = FileScavenger\Request-FileScavengerStage -Stage $Stage -EvidenceMap $EvidenceMap `
        -State $stageCheckState -Executable $Executable
    if (-not $stageRequest.Allowed) {
        $manualGate = $stageRequest.ManualGate
        if ($null -eq $manualGate) { $manualGate = $stageRequest.Gate }
        if ($null -eq $manualGate) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode $stageRequest.ReasonCode -Message ([string]$stageRequest.Reason) -StageRequest $stageRequest
        }
        $gateResult = Invoke-RecoveryAutomationGate -GateId ([string]$manualGate.GateId) `
            -Reason ([string]$manualGate.Reason) -Evidence $manualGate.Evidence `
            -Choices @($manualGate.Choices) -SafeDefault ([string]$manualGate.SafeDefault) `
            -InteractionProvider $InteractionProvider
        $gateSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter `
            -GateResult $gateResult -StateWriter $StateWriter -Stage $Stage -AttemptId ([string]$State.AttemptId)
        if (-not $gateSave.Success) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode $gateSave.ReasonCode -Message $gateSave.Message -Gate $gateResult -StageRequest $stageRequest
        }
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'ManualGatePending' -Message 'The File Scavenger stage requires a recorded manual or exact-build action.' `
            -Gate $gateResult -StageRequest $stageRequest
    }

    if ($Stage -eq 'SHORT_SCAN' -and [string]$State.State -eq 'SHORT_SCAN_RUNNING') {
        $authorization = Write-RecoveryAutomationEvent -Writer $LogWriter -State $State -EventType 'StageStarted' `
            -Result 'ActionAuthorized' -Stage $Stage -AttemptId ([string]$State.AttemptId)
        if ($null -eq $authorization -or $authorization.Success -ne $true) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode 'StageAuthorizationNotDurable' -Message 'The Quick scan action authorization was not durably recorded.' -StageRequest $stageRequest
        }
        $authorizationSnapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
        if ($null -eq $authorizationSnapshot -or $authorizationSnapshot.Success -ne $true) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode 'StageAuthorizationStateWriteFailed' -Message 'The Quick scan action authorization snapshot failed.' -StageRequest $stageRequest
        }
    }
    else {
        $targetState = $null
        if ($Stage -eq 'SHORT_RECOVERY') { $targetState = 'SHORT_RECOVERY_RUNNING' }
        elseif ($Stage -eq 'LONG_SCAN') { $targetState = 'LONG_SCAN_RUNNING' }
        elseif ($Stage -eq 'LONG_RECOVERY') { $targetState = 'LONG_RECOVERY_RUNNING' }
        if ($null -eq $targetState) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode 'InvalidStage' -Message 'The requested stage cannot be started.' -StageRequest $stageRequest
        }
        $State.Stage = $Stage
        $attemptNumber = 1
        $existingAttempt = [string]$State.AttemptId
        if ($existingAttempt -match '(\d+)$') {
            try { $attemptNumber = [int]$Matches[1] + 1 } catch { $attemptNumber = 1 }
        }
        $State.AttemptId = ([string]$State.JobId + '-' + $Stage.ToLowerInvariant().Replace('_', '-') + '-' + $attemptNumber.ToString('000'))
        $transitionEvidence = 'RecoveryDestinationChecked'
        if ($Stage -eq 'LONG_SCAN') { $transitionEvidence = 'LongScanApproved' }
        $startTransition = JobState\Set-RecoveryState -State $State -To $targetState -EventWriter $EventWriter `
            -StateWriter $StateWriter -Context @{ Evidence = $transitionEvidence; Stage = $Stage; AttemptId = $State.AttemptId; EventType = 'StageStarted' } -Clock $Clock
        if (-not $startTransition.Success) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode $startTransition.ReasonCode -Message ([string]$startTransition.Message) -StageRequest $stageRequest
        }
    }

    if ($null -eq $UiProvider) {
        $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-04' `
            -Reason 'The exact-build File Scavenger control surface is not available; perform this vendor action manually.' `
            -Evidence $stageRequest -Choices @('Perform manually', 'Stop') -SafeDefault 'Stop' `
            -InteractionProvider $InteractionProvider
        $gateSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter `
            -GateResult $gateResult -StateWriter $StateWriter -Stage $Stage -AttemptId ([string]$State.AttemptId)
        if (-not $gateSave.Success) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode $gateSave.ReasonCode -Message $gateSave.Message -Gate $gateResult -StageRequest $stageRequest
        }
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'ManualGatePending' -Message 'No File Scavenger UI action provider was supplied.' -Gate $gateResult -StageRequest $stageRequest
    }

    $actionResult = UIAutomation\Invoke-RecoveryUiAction -Action ([string]$stageRequest.Action) `
        -ControlDescriptor $stageRequest.ControlDescriptor -UiProvider $UiProvider
    if (-not $actionResult.Allowed) {
        try { [void](Write-RecoveryAutomationEvent -Writer $LogWriter -State $State -EventType 'StageFailed' -Result 'Failed' -Stage $Stage -AttemptId $State.AttemptId -ErrorDetail $actionResult.ReasonCode) } catch { }
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode $actionResult.ReasonCode -Message ([string]$actionResult.Reason) -StageRequest $stageRequest
    }

    $observation = Get-RecoveryAutomationFileScavengerObservation -State $State -ProcessIdentity $State.ProcessIdentity `
        -UiProvider $UiProvider -OutputProvider $OutputProvider -OperatorEvidenceProvider $OperatorEvidenceProvider -Stage $Stage
    $completion = FileScavenger\Test-FileScavengerCompletion -Stage $Stage -Observation $observation
    if (-not $completion.Completed) {
        $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-05' `
            -Reason ([string]$completion.Reason) -Evidence $completion -Choices @('Pause', 'Inspect evidence', 'Stop') -SafeDefault 'Pause' `
            -InteractionProvider $InteractionProvider
        $gateSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter `
            -GateResult $gateResult -StateWriter $StateWriter -Stage $Stage -AttemptId ([string]$State.AttemptId)
        if (-not $gateSave.Success) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode $gateSave.ReasonCode -Message $gateSave.Message -Gate $gateResult -Observation $observation -Completion $completion
        }
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'StageCompletionPending' -Message 'The named File Scavenger completion evidence is incomplete.' `
            -Gate $gateResult -Observation $observation -Completion $completion
    }

    $finishedState = $null
    if ($Stage -eq 'SHORT_SCAN') { $finishedState = 'SHORT_SCAN_FINISHED' }
    elseif ($Stage -eq 'SHORT_RECOVERY') { $finishedState = 'SHORT_RECOVERY_FINISHED' }
    elseif ($Stage -eq 'LONG_SCAN') { $finishedState = 'LONG_SCAN_FINISHED' }
    elseif ($Stage -eq 'LONG_RECOVERY') { $finishedState = 'LONG_RECOVERY_FINISHED' }
    $finishEvidence = 'ScanFinished'
    if ($Stage -like '*RECOVERY') { $finishEvidence = 'RecoveryFinished' }
    if ($Stage -like '*RECOVERY') {
        $State | Add-Member -NotePropertyName RecoveryFinishedEvidence -NotePropertyValue $observation -Force
    }
    $finishTransition = JobState\Set-RecoveryState -State $State -To $finishedState -EventWriter $EventWriter `
        -StateWriter $StateWriter -Context @{ Evidence = $finishEvidence; Stage = $Stage; AttemptId = $State.AttemptId; EventType = if ($finishEvidence -eq 'ScanFinished') { 'ScanFinished' } else { 'RecoveryFinished' } } -Clock $Clock
    if (-not $finishTransition.Success) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode $finishTransition.ReasonCode -Message ([string]$finishTransition.Message) -Observation $observation -Completion $completion
    }

    if ($Stage -notlike '*RECOVERY') {
        $reviewGate = Invoke-RecoveryAutomationGate -GateId 'G-05' `
            -Reason 'The named scan-finished evidence must be reviewed before Step 2: Save.' -Evidence $completion `
            -Choices @('Continue', 'Pause', 'Stop') -SafeDefault 'Pause' -InteractionProvider $InteractionProvider
        $reviewSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter `
            -GateResult $reviewGate -StateWriter $StateWriter -Stage $Stage -AttemptId ([string]$State.AttemptId)
        if (-not $reviewSave.Success) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode $reviewSave.ReasonCode -Message $reviewSave.Message -Gate $reviewGate -Observation $observation -Completion $completion
        }
        if (-not $reviewGate.Continues) {
            return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
                -ReasonCode 'StageReviewPending' -Message 'The scan result was not approved for the next stage.' -Gate $reviewGate -Observation $observation -Completion $completion
        }
        return New-RecoveryAutomationStageResult -Success $true -State $State -Stage $Stage `
            -ReasonCode $null -Message 'Named scan completion evidence was recorded and reviewed.' -Observation $observation -Completion $completion
    }

    $State | Add-Member -NotePropertyName OutputObservation -NotePropertyValue $observation -Force
    $State | Add-Member -NotePropertyName OutputVerified -NotePropertyValue $false -Force
    $outputEvent = Write-RecoveryAutomationEvent -Writer $LogWriter -State $State -EventType 'OutputObserved' `
        -Result 'Observed' -Stage $Stage -AttemptId ([string]$State.AttemptId)
    if ($null -eq $outputEvent -or $outputEvent.Success -ne $true) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'OutputEventWriteFailed' -Message 'The output observation was not durably recorded.' -Observation $observation -Completion $completion
    }
    $outputSnapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
    if ($null -eq $outputSnapshot -or $outputSnapshot.Success -ne $true) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'OutputStateWriteFailed' -Message 'The output observation snapshot failed.' -Observation $observation -Completion $completion
    }
    $verifyGate = Invoke-RecoveryAutomationGate -GateId 'G-05' `
        -Reason 'Review the independently observed recovered output and approve the named recovery stage.' `
        -Evidence ([pscustomobject]@{ Completion = $completion; Observation = $observation }) `
        -Choices @('Continue', 'Inspect evidence', 'Stop') -SafeDefault 'Inspect evidence' -InteractionProvider $InteractionProvider
    $verifySave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter `
        -GateResult $verifyGate -StateWriter $StateWriter -Stage $Stage -AttemptId ([string]$State.AttemptId)
    if (-not $verifySave.Success) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode $verifySave.ReasonCode -Message $verifySave.Message -Gate $verifyGate -Observation $observation -Completion $completion
    }
    if (-not $completion.Verified -or -not $verifyGate.Continues) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode 'OutputVerificationPending' -Message 'Recovery output was not independently verified and approved.' `
            -Gate $verifyGate -Observation $observation -Completion $completion
    }
    $State.OutputVerified = $true
    $State | Add-Member -NotePropertyName FileScavengerWorkVerified -NotePropertyValue $true -Force
    $verifiedState = 'SHORT_RECOVERY_VERIFIED'
    if ($Stage -eq 'LONG_RECOVERY') { $verifiedState = 'LONG_RECOVERY_VERIFIED' }
    $verifiedEvidence = 'OutputObserved'
    if ($Stage -eq 'LONG_RECOVERY') { $verifiedEvidence = 'OutputObserved' }
    $verifiedTransition = JobState\Set-RecoveryState -State $State -To $verifiedState -EventWriter $EventWriter `
        -StateWriter $StateWriter -Context @{ Evidence = $verifiedEvidence; Stage = $Stage; AttemptId = $State.AttemptId; EventType = 'StageVerified' } -Clock $Clock
    if (-not $verifiedTransition.Success) {
        return New-RecoveryAutomationStageResult -Success $false -State $State -Stage $Stage `
            -ReasonCode $verifiedTransition.ReasonCode -Message ([string]$verifiedTransition.Message) -Gate $verifyGate -Observation $observation -Completion $completion
    }
    return New-RecoveryAutomationStageResult -Success $true -State $State -Stage $Stage `
        -ReasonCode $null -Message 'Recovery completion and independently observed output were verified.' `
        -Gate $verifyGate -Observation $observation -Completion $completion
}

function Write-RecoveryAutomationEventSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Writer,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][AllowNull()][object]$StateWriter,
        [Parameter(Mandatory = $true)][string]$EventType,
        [string]$Result = 'Recorded',
        [string]$Stage = $null,
        [string]$AttemptId = $null,
        [AllowNull()][object]$Decision = $null,
        [AllowNull()][object]$ErrorDetail = $null,
        [AllowNull()][object]$Gate = $null
    )

    $eventResult = Write-RecoveryAutomationEvent -Writer $Writer -State $State -EventType $EventType `
        -Result $Result -Stage $Stage -AttemptId $AttemptId -Decision $Decision -ErrorDetail $ErrorDetail -Gate $Gate
    if ($null -eq $eventResult -or $eventResult.Success -ne $true) {
        return [pscustomobject]@{ Success = $false; ReasonCode = 'EventWriteFailed'; Message = 'The recovery event was not durably recorded.'; Event = $eventResult }
    }
    $snapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
    if ($null -eq $snapshot -or $snapshot.Success -ne $true) {
        return [pscustomobject]@{ Success = $false; ReasonCode = 'EventStateWriteFailed'; Message = 'The state snapshot after the recovery event failed.'; Event = $eventResult; Snapshot = $snapshot }
    }
    return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null; Event = $eventResult; Snapshot = $snapshot }
}

function Update-RecoveryAutomationFreshState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][AllowNull()][object]$StateWriter,
        [Parameter(Mandatory = $true)][object]$Fresh
    )

    $State.SourceIdentity = $Fresh.SourceIdentity
    $State.SourceIdentity | Add-Member -NotePropertyName ReadOnlyVerified -NotePropertyValue $Fresh.Protection.Verified -Force
    $State.SourceIdentity | Add-Member -NotePropertyName ReadOnlyEvidence -NotePropertyValue $Fresh.Protection.Evidence -Force
    $State.DestinationIdentity = $Fresh.DestinationIdentity
    $State.CapacityPolicy = $Fresh.Capacity
    $State.SourceProtection = $Fresh.Protection
    if ($null -eq $State.PSObject.Properties['Preconditions'] -or $null -eq $State.Preconditions) {
        $State | Add-Member -NotePropertyName Preconditions -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -eq $State.Preconditions.PSObject.Properties['FreshSafetyCheckPassed']) {
        $State.Preconditions | Add-Member -NotePropertyName FreshSafetyCheckPassed -NotePropertyValue $true -Force
    }
    else {
        $State.Preconditions.FreshSafetyCheckPassed = $true
    }
    $snapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
    return $snapshot
}

function Test-RecoveryAutomationCloseEvidence {
    [CmdletBinding()]
    param([AllowNull()][object]$Observation)

    $closeVerified = Test-RecoveryAutomationBoolean (Get-RecoveryAutomationValue -InputObject $Observation -Names @('GracefulCloseVerified', 'CloseVerified'))
    $terminated = Test-RecoveryAutomationBoolean (Get-RecoveryAutomationValue -InputObject $Observation -Names @('ProcessTerminated', 'ProcessExitedAfterClose'))
    $unknown = Test-RecoveryAutomationBoolean (Get-RecoveryAutomationValue -InputObject $Observation -Names @('Unknown', 'StateUnknown'))
    $active = Test-RecoveryAutomationBoolean (Get-RecoveryAutomationValue -InputObject $Observation -Names @('ActiveWork', 'ScanRunning', 'RecoveryRunning'))
    return [pscustomobject]@{
        Verified = ($closeVerified -and $terminated -and -not $unknown -and -not $active)
        GracefulCloseVerified = $closeVerified
        ProcessTerminated = $terminated
        Unknown = $unknown
        ActiveWork = $active
        Observation = $Observation
        ReasonCode = if ($closeVerified -and $terminated -and -not $unknown -and -not $active) { $null } else { 'CloseStateUnknownOrActive' }
    }
}

function Invoke-RecoveryAutomationClose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][object]$LogWriter,
        [Parameter(Mandatory = $true)][AllowNull()][object]$StateWriter,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$DiskProvider,
        [scriptblock]$SourceProtectionProvider = $null,
        [int64]$ReserveBytes = 0,
        [AllowNull()][object]$EvidenceMap,
        [scriptblock]$UiProvider = $null,
        [scriptblock]$OutputProvider = $null,
        [AllowNull()][object]$OperatorEvidenceProvider = $null,
        [scriptblock]$InteractionProvider = $null,
        [scriptblock]$EventWriter = $null,
        [object]$Clock = $null
    )

    $fresh = Test-RecoveryAutomationFreshSafety -SourcePath $SourcePath -DestinationPath $DestinationPath `
        -DiskProvider $DiskProvider -SourceSelection $null -PreviousProtection $State.SourceProtection `
        -SourceProtectionProvider $SourceProtectionProvider -ReserveBytes $ReserveBytes -RequireFreshProtectionProvider
    if (-not $fresh.Passed) {
        $failure = Write-RecoveryAutomationEventSnapshot -Writer $LogWriter -State $State -Case $Case -StateWriter $StateWriter `
            -EventType 'StageFailed' -Result 'Failed' -Stage ([string]$State.Stage) -AttemptId ([string]$State.AttemptId) -ErrorDetail $fresh.ReasonCode
        $reason = $fresh.ReasonCode
        if ($null -eq $failure -or -not $failure.Success) { $reason = $failure.ReasonCode }
        return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = $reason; Message = 'Fresh close safety evidence failed.'; Gate = $null; Observation = $null }
    }
    $freshSnapshot = Update-RecoveryAutomationFreshState -State $State -Case $Case -StateWriter $StateWriter -Fresh $fresh
    if ($null -eq $freshSnapshot -or $freshSnapshot.Success -ne $true) {
        return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = 'FreshSafetyStateWriteFailed'; Message = 'Fresh close safety evidence could not be snapshotted.'; Gate = $null; Observation = $null }
    }

    $processIdentity = Get-RecoveryAutomationValue -InputObject $State -Names @('ProcessIdentity', 'ApplicationProcessIdentity')
    $beforeObservation = Get-RecoveryAutomationFileScavengerObservation -State $State -ProcessIdentity $processIdentity `
        -UiProvider $UiProvider -OutputProvider $OutputProvider -OperatorEvidenceProvider $OperatorEvidenceProvider -Stage 'CLOSE'
    $closeRequest = FileScavenger\Request-FileScavengerGracefulClose -Observation $beforeObservation `
        -EvidenceMap $EvidenceMap -UiProvider $UiProvider
    if (-not $closeRequest.Allowed) {
        $manualGate = Get-RecoveryAutomationValue -InputObject $closeRequest -Names @('ManualGate', 'Gate')
        if ($null -eq $manualGate) {
            return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = $closeRequest.ReasonCode; Message = ([string]$closeRequest.Reason); Gate = $null; Observation = $beforeObservation }
        }
        $gateResult = Invoke-RecoveryAutomationGate -GateId ([string]$manualGate.GateId) -Reason ([string]$manualGate.Reason) `
            -Evidence $manualGate.Evidence -Choices @($manualGate.Choices) -SafeDefault ([string]$manualGate.SafeDefault) `
            -InteractionProvider $InteractionProvider
        $gateSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter -GateResult $gateResult `
            -StateWriter $StateWriter -Stage 'CLOSE' -AttemptId ([string]$State.AttemptId)
        if (-not $gateSave.Success) {
            return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = $gateSave.ReasonCode; Message = $gateSave.Message; Gate = $gateResult; Observation = $beforeObservation }
        }
        return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = 'ManualGatePending'; Message = 'File Scavenger close requires a recorded manual or exact-build action.'; Gate = $gateResult; Observation = $beforeObservation }
    }

    $afterObservation = Get-RecoveryAutomationFileScavengerObservation -State $State -ProcessIdentity $processIdentity `
        -UiProvider $UiProvider -OutputProvider $OutputProvider -OperatorEvidenceProvider $OperatorEvidenceProvider -Stage 'CLOSE'
    $closeEvidence = Test-RecoveryAutomationCloseEvidence -Observation $afterObservation
    if (-not $closeEvidence.Verified) {
        $manualGate = [pscustomobject]@{
            GateId = 'G-08'
            Reason = 'The graceful close action did not produce explicit termination evidence; leave the vendor state untouched.'
            Evidence = $closeEvidence
            Choices = @('Retry graceful close', 'Leave active state untouched', 'Stop')
            SafeDefault = 'Leave active state untouched'
        }
        $gateResult = Invoke-RecoveryAutomationGate -GateId $manualGate.GateId -Reason $manualGate.Reason -Evidence $manualGate.Evidence `
            -Choices $manualGate.Choices -SafeDefault $manualGate.SafeDefault -InteractionProvider $InteractionProvider
        $gateSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter -GateResult $gateResult `
            -StateWriter $StateWriter -Stage 'CLOSE' -AttemptId ([string]$State.AttemptId)
        if (-not $gateSave.Success) {
            return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = $gateSave.ReasonCode; Message = $gateSave.Message; Gate = $gateResult; Observation = $afterObservation }
        }
        return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = 'CloseVerificationPending'; Message = 'Graceful close and process termination evidence remain unverified.'; Gate = $gateResult; Observation = $afterObservation }
    }

    $closeEvent = Write-RecoveryAutomationEventSnapshot -Writer $LogWriter -State $State -Case $Case -StateWriter $StateWriter `
        -EventType 'GracefulCloseVerified' -Result 'Verified' -Stage ([string]$State.Stage) -AttemptId ([string]$State.AttemptId)
    if (-not $closeEvent.Success) {
        return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = $closeEvent.ReasonCode; Message = $closeEvent.Message; Gate = $null; Observation = $afterObservation }
    }
    $State | Add-Member -NotePropertyName FileScavengerCloseVerified -NotePropertyValue $true -Force
    $State | Add-Member -NotePropertyName GracefulCloseVerified -NotePropertyValue $true -Force
    $targetState = [string]$State.State
    $evidenceName = 'FileScavengerWorkVerified'
    if ($targetState -eq 'LONG_RECOVERY_VERIFIED') { $evidenceName = 'FinalChecksPassed' }
    $transition = JobState\Set-RecoveryState -State $State -To 'READY_FOR_HANDOFF' -EventWriter $EventWriter -StateWriter $StateWriter `
        -Context @{ Evidence = $evidenceName; Stage = 'CLOSE'; AttemptId = $State.AttemptId; EventType = 'GracefulCloseVerified' } -Clock $Clock
    if (-not $transition.Success) {
        return [pscustomobject]@{ Success = $false; State = $State; ReasonCode = $transition.ReasonCode; Message = ([string]$transition.Message); Gate = $null; Observation = $afterObservation }
    }
    return [pscustomobject]@{ Success = $true; State = $State; ReasonCode = $null; Message = 'File Scavenger closed with explicit termination evidence.'; Gate = $null; Observation = $afterObservation }
}

function New-RecoveryAutomationWorkflowResult {
    [CmdletBinding()]
    param(
        [bool]$Success,
        [object]$State,
        [string]$ReasonCode,
        [string]$Message,
        [object]$Gate = $null,
        [object]$Stage = $null,
        [object]$Handoff = $null
    )
    return [pscustomobject]@{ Success = $Success; State = $State; ReasonCode = $ReasonCode; Message = $Message; Gate = $Gate; Stage = $Stage; Handoff = $Handoff }
}

function Invoke-RecoveryAutomationWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][object]$LogWriter,
        [Parameter(Mandatory = $true)][AllowNull()][object]$StateWriter,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$DiskProvider,
        [Parameter(Mandatory = $true)][object]$Applications,
        [Parameter(Mandatory = $true)][object]$FileScavengerExecutable,
        [Parameter(Mandatory = $true)][object]$RStudioExecutable,
        [scriptblock]$SourceProtectionProvider = $null,
        [int64]$ReserveBytes = 0,
        [AllowNull()][object]$FileScavengerEvidenceMap,
        [scriptblock]$FileScavengerUiProvider = $null,
        [scriptblock]$FileScavengerOutputProvider = $null,
        [AllowNull()][object]$OperatorEvidenceProvider = $null,
        [scriptblock]$InteractionProvider = $null,
        [scriptblock]$EventWriter = $null,
        [scriptblock]$RStudioProcessRunner = $null,
        [scriptblock]$RStudioFreshEvidenceProvider = $null,
        [scriptblock]$RStudioActivationProvider = $null,
        [object]$Clock = $null
    )

    if ($null -eq $EventWriter) {
        return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode 'EventWriterMissing' -Message 'A durable event writer is required for every workflow boundary.'
    }

    $stageParameters = @{
        State = $State
        Case = $Case
        LogWriter = $LogWriter
        StateWriter = $StateWriter
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
        DiskProvider = $DiskProvider
        SourceSelection = $null
        PreviousProtection = $State.SourceProtection
        SourceProtectionProvider = $SourceProtectionProvider
        ReserveBytes = $ReserveBytes
        Executable = $FileScavengerExecutable
        EvidenceMap = $FileScavengerEvidenceMap
        UiProvider = $FileScavengerUiProvider
        OutputProvider = $FileScavengerOutputProvider
        OperatorEvidenceProvider = $OperatorEvidenceProvider
        InteractionProvider = $InteractionProvider
        EventWriter = $EventWriter
        Clock = $Clock
    }

    $currentState = [string]$State.State
    $choiceGate = $null
    if ($currentState -eq 'CASE_READY' -or $currentState -eq 'SHORT_SCAN_RUNNING') {
        $stageParameters['Stage'] = 'SHORT_SCAN'
        $stageResult = Invoke-RecoveryAutomationStage @stageParameters
        if (-not $stageResult.Success) { return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $stageResult.ReasonCode -Message $stageResult.Message -Gate $stageResult.Gate -Stage $stageResult }
        $currentState = [string]$State.State
    }
    if ($currentState -eq 'SHORT_SCAN_FINISHED') {
        $stageParameters['Stage'] = 'SHORT_RECOVERY'
        $stageResult = Invoke-RecoveryAutomationStage @stageParameters
        if (-not $stageResult.Success) { return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $stageResult.ReasonCode -Message $stageResult.Message -Gate $stageResult.Gate -Stage $stageResult }
        $currentState = [string]$State.State
    }

    if ($currentState -eq 'SHORT_RECOVERY_VERIFIED') {
        $choiceGate = Invoke-RecoveryAutomationGate -GateId 'G-05' `
            -Reason 'Choose whether to continue with the optional Long scan or finish File Scavenger before handoff.' `
            -Evidence ([pscustomobject]@{ State = $State.State; OutputVerified = $State.OutputVerified }) `
            -Choices @('Continue', 'Finish File Scavenger', 'Stop') -SafeDefault 'Finish File Scavenger' `
            -InteractionProvider $InteractionProvider
        $choiceSave = Save-RecoveryAutomationGate -State $State -Case $Case -LogWriter $LogWriter -GateResult $choiceGate `
            -StateWriter $StateWriter -Stage 'SHORT_RECOVERY' -AttemptId ([string]$State.AttemptId)
        if (-not $choiceSave.Success) {
            return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $choiceSave.ReasonCode -Message $choiceSave.Message -Gate $choiceGate
        }
        $choiceText = ([string]$choiceGate.Decision).Trim().ToUpperInvariant()
        if ($choiceText -eq 'CONTINUE') {
            $stageParameters['Stage'] = 'LONG_SCAN'
            $stageResult = Invoke-RecoveryAutomationStage @stageParameters
            if (-not $stageResult.Success) { return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $stageResult.ReasonCode -Message $stageResult.Message -Gate $stageResult.Gate -Stage $stageResult }
            $stageParameters['Stage'] = 'LONG_RECOVERY'
            $stageResult = Invoke-RecoveryAutomationStage @stageParameters
            if (-not $stageResult.Success) { return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $stageResult.ReasonCode -Message $stageResult.Message -Gate $stageResult.Gate -Stage $stageResult }
            $currentState = [string]$State.State
        }
        elseif ($choiceText -ne 'FINISH FILE SCAVENGER') {
            return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode 'ManualGatePending' -Message 'The Long scan decision did not authorize another stage.' -Gate $choiceGate
        }
        else {
            $currentState = [string]$State.State
        }
    }

    if ($currentState -eq 'LONG_RECOVERY_VERIFIED' -or ($currentState -eq 'SHORT_RECOVERY_VERIFIED' -and ([string]$choiceGate.Decision).Trim().ToUpperInvariant() -eq 'FINISH FILE SCAVENGER')) {
        $closeResult = Invoke-RecoveryAutomationClose -State $State -Case $Case -LogWriter $LogWriter -StateWriter $StateWriter `
            -SourcePath $SourcePath -DestinationPath $DestinationPath -DiskProvider $DiskProvider `
            -SourceProtectionProvider $SourceProtectionProvider -ReserveBytes $ReserveBytes -EvidenceMap $FileScavengerEvidenceMap `
            -UiProvider $FileScavengerUiProvider -OutputProvider $FileScavengerOutputProvider `
            -OperatorEvidenceProvider $OperatorEvidenceProvider -InteractionProvider $InteractionProvider `
            -EventWriter $EventWriter -Clock $Clock
        if (-not $closeResult.Success) {
            return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $closeResult.ReasonCode -Message $closeResult.Message -Gate $closeResult.Gate
        }
        $currentState = [string]$State.State
    }

    if ($currentState -ne 'READY_FOR_HANDOFF') {
        return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode 'ManualGatePending' -Message 'The documented workflow has not reached READY_FOR_HANDOFF.'
    }

    foreach ($flag in @('FileScavengerCloseVerified', 'OutputVerified', 'SourceIdentityVerified', 'DestinationIdentityVerified', 'LogDurable', 'StateDurable')) {
        $State | Add-Member -NotePropertyName $flag -NotePropertyValue $true -Force
    }
    $handoffSnapshot = JobState\Write-RecoveryJobState -Path $Case.StatePath -State $State -Writer $StateWriter
    if ($null -eq $handoffSnapshot -or $handoffSnapshot.Success -ne $true) {
        return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode 'HandoffStateWriteFailed' -Message 'Final handoff evidence could not be durably snapshotted.'
    }

    $freshSafetyProvider = ${function:Test-RecoveryAutomationFreshSafety}.GetNewClosure()
    $freshStateUpdater = ${function:Update-RecoveryAutomationFreshState}.GetNewClosure()
    $freshEvidence = {
        param($handoffState)
        $fresh = & $freshSafetyProvider -SourcePath $SourcePath -DestinationPath $DestinationPath `
            -DiskProvider $DiskProvider -SourceSelection $null -PreviousProtection $handoffState.SourceProtection `
            -SourceProtectionProvider $SourceProtectionProvider -ReserveBytes $ReserveBytes -RequireFreshProtectionProvider
        if (-not $fresh.Passed) {
            return [pscustomobject]@{ Success = $false; ReasonCode = $fresh.ReasonCode; Evidence = $fresh }
        }
        $snapshot = & $freshStateUpdater -State $handoffState -Case $Case -StateWriter $StateWriter -Fresh $fresh
        if ($null -eq $snapshot -or $snapshot.Success -ne $true) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'FreshSafetyStateWriteFailed'; Evidence = $snapshot }
        }
        if ($null -ne $RStudioFreshEvidenceProvider) {
            try {
                $custom = @(& $RStudioFreshEvidenceProvider $handoffState)
                if ($custom.Count -ne 1 -or $null -eq $custom[0]) {
                    return [pscustomobject]@{ Success = $false; ReasonCode = 'FreshEvidenceUnverified'; Evidence = 'The R-Studio fresh-evidence provider did not return exactly one result.' }
                }
                $customValue = $custom[0]
                $customSuccess = Get-RecoveryAutomationValue -InputObject $customValue -Names @('Success')
                if ($customSuccess -isnot [bool] -or -not $customSuccess) {
                    return [pscustomobject]@{ Success = $false; ReasonCode = 'FreshEvidenceUnverified'; Evidence = $customValue }
                }
                foreach ($flag in @('FileScavengerCloseVerified', 'OutputVerified', 'SourceIdentityVerified', 'DestinationIdentityVerified', 'LogDurable', 'StateDurable')) {
                    $flagValue = Get-RecoveryAutomationValue -InputObject $customValue -Names @($flag)
                    if ($flagValue -isnot [bool] -or -not $flagValue) {
                        return [pscustomobject]@{ Success = $false; ReasonCode = 'FreshEvidenceFailed'; Evidence = $customValue }
                    }
                }
            }
            catch {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'FreshEvidenceUnverified'; Evidence = $_.Exception.Message }
            }
        }
        return [pscustomobject]@{
            Success = $true
            FileScavengerCloseVerified = $true
            OutputVerified = $true
            SourceIdentityVerified = $true
            DestinationIdentityVerified = $true
            LogDurable = $true
            StateDurable = $true
            SourceIdentity = $fresh.SourceIdentity
            DestinationIdentity = $fresh.DestinationIdentity
            Capacity = $fresh.Capacity
            SourceProtection = $fresh.Protection
        }
    }.GetNewClosure()
    # The vendor log is a dedicated file inside the case folder.
    #
    # R-Studio documents -log <filename> as 'writes the R-Studio log into the
    # specified file', and the case event log is an append-only JSONL record with
    # one JSON object per event. Pointing the vendor switch at events.jsonl mixed
    # vendor text into the case record: the next validation would read it as
    # malformed JSONL, and the one-writer-per-file contract was broken while the
    # case was live. The vendor log therefore gets its own file, and the validator
    # allows exactly that file and nothing else.
    $vendorLogPath = [System.IO.Path]::Combine([string]$Case.JobFolderPath, 'rstudio-host.log')
    $logValidator = {
        param($path)
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            return [pscustomobject]@{ Allowed = $false; ReasonCode = 'LogPathUnsafe'; Evidence = 'No vendor log path was supplied.' }
        }
        if (-not [string]::Equals([string]$path, $vendorLogPath, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Allowed = $false; ReasonCode = 'LogPathUnsafe'; Evidence = 'The vendor log must be the dedicated R-Studio log file inside the case folder.' }
        }
        if ([string]::Equals($vendorLogPath, [string]$Case.LogPath, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Allowed = $false; ReasonCode = 'LogPathUnsafe'; Evidence = 'The vendor log must never be the JSONL case event log.' }
        }
        if (-not [System.IO.Directory]::Exists([string]$Case.JobFolderPath)) {
            return [pscustomobject]@{ Allowed = $false; ReasonCode = 'LogPathUnsafe'; Evidence = 'The case folder for the vendor log does not exist.' }
        }
        return [pscustomobject]@{ Allowed = $true; Evidence = 'The vendor log path is the dedicated R-Studio log file inside the case folder.' }
    }.GetNewClosure()
    $handoffResult = Invoke-RecoveryAutomationHandoff -State $State -Executable $RStudioExecutable -LogPath $vendorLogPath `
        -ProcessRunner $RStudioProcessRunner -LogPathSafetyValidator $logValidator -FreshEvidenceProvider $freshEvidence `
        -ActivationProvider $RStudioActivationProvider -EventWriter $EventWriter -StateWriter $StateWriter -Clock $Clock
    if (-not $handoffResult.Allowed) {
        return New-RecoveryAutomationWorkflowResult -Success $false -State $State -ReasonCode $handoffResult.ReasonCode -Message $handoffResult.Message -Handoff $handoffResult
    }
    return New-RecoveryAutomationWorkflowResult -Success $true -State $State -ReasonCode $null -Message 'The case reached READY_FOR_HANDOFF and R-Studio was launched only at the documented manual boundary.' -Handoff $handoffResult
}

function Invoke-RecoveryAutomationHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Executable,
        [AllowNull()][AllowEmptyString()][string]$LogPath,
        [scriptblock]$ProcessRunner = $null,
        [scriptblock]$LogPathSafetyValidator = $null,
        [scriptblock]$FreshEvidenceProvider = $null,
        [scriptblock]$ActivationProvider = $null,
        [scriptblock]$EventWriter = $null,
        [object]$StateWriter = $null,
        [object]$Clock = $null
    )

    $blocked = [pscustomobject]@{
        Allowed = $false
        Handoff = $null
        State = $State
        ReasonCode = $null
        Message = $null
        LaunchAttempted = $false
        Launched = $false
        AnalysisInvoked = $false
    }
    $preconditions = RStudio\Test-RStudioHandoffPreconditions -State $State -Executable $Executable `
        -LogPath $LogPath -LogPathSafetyValidator $LogPathSafetyValidator -FreshEvidenceProvider $FreshEvidenceProvider
    if (-not $preconditions.Allowed) {
        $blocked.ReasonCode = $preconditions.ReasonCode
        $blocked.Message = 'R-Studio handoff preconditions were not satisfied.'
        $blocked | Add-Member -NotePropertyName Preconditions -NotePropertyValue $preconditions -Force
        return $blocked
    }
    if ($null -eq $EventWriter) {
        $blocked.ReasonCode = 'EventWriterMissing'
        $blocked.Message = 'A durable launch authorization event writer is required before handoff.'
        $blocked | Add-Member -NotePropertyName Preconditions -NotePropertyValue $preconditions -Force
        return $blocked
    }
    $authorizationEvent = [pscustomobject]@{
        JobId = [string]$State.JobId
        State = [string]$State.State
        Stage = 'HANDOFF'
        AttemptId = $null
        EventType = 'RStudioLaunchOnlyHandoff'
        Result = 'Authorized'
        SourceIdentity = $State.SourceIdentity
        DestinationIdentity = $State.DestinationIdentity
        Decision = 'LaunchOnly'
        Error = $null
        Gate = $null
    }
    try {
        $authorizationResult = & $EventWriter $authorizationEvent
    }
    catch {
        $authorizationResult = $false
    }
    $authorizationOk = $false
    if ($authorizationResult -is [bool]) {
        $authorizationOk = [bool]$authorizationResult
    }
    elseif ($null -ne $authorizationResult) {
        $authorizationValue = Get-RecoveryAutomationValue -InputObject $authorizationResult -Names @('Success', 'Allowed')
        if ($authorizationValue -is [bool]) { $authorizationOk = [bool]$authorizationValue }
    }
    if (-not $authorizationOk) {
        $blocked.ReasonCode = 'EventWriteFailed'
        $blocked.Message = 'The R-Studio launch authorization event could not be recorded.'
        $blocked | Add-Member -NotePropertyName Preconditions -NotePropertyValue $preconditions -Force
        return $blocked
    }
    $handoff = RStudio\Start-RStudioHandoff -State $State -Executable $Executable -LogPath $LogPath `
        -ProcessRunner $ProcessRunner -LogPathSafetyValidator $LogPathSafetyValidator `
        -FreshEvidenceProvider $FreshEvidenceProvider -ActivationProvider $ActivationProvider
    $blocked.LaunchAttempted = $true
    if (-not $handoff.Launched) {
        try { [void](& $EventWriter ([pscustomobject]@{
                    JobId = [string]$State.JobId
                    State = [string]$State.State
                    Stage = 'HANDOFF'
                    AttemptId = $null
                    EventType = 'StageFailed'
                    Result = 'Failed'
                    SourceIdentity = $State.SourceIdentity
                    DestinationIdentity = $State.DestinationIdentity
                    Decision = $null
                    Error = $handoff.ReasonCode
                    Gate = $null
                })) } catch { }
        $blocked.ReasonCode = $handoff.ReasonCode
        $blocked.Message = 'R-Studio launch failed or returned no verified process identity.'
        $blocked.Handoff = $handoff
        $blocked | Add-Member -NotePropertyName Preconditions -NotePropertyValue $preconditions -Force
        return $blocked
    }
    $State | Add-Member -NotePropertyName ProcessIdentity -NotePropertyValue $handoff.ProcessIdentity -Force
    $State | Add-Member -NotePropertyName Handoff -NotePropertyValue $handoff -Force
    $State.Stage = 'HANDOFF'
    $State.AttemptId = [string]$State.JobId + '-handoff-001'
    $transition = JobState\Set-RecoveryState -State $State -To 'HANDOFF_MANUAL' -EventWriter $EventWriter `
        -StateWriter $StateWriter -Context @{ Evidence = 'RStudioLaunchVerified'; Stage = 'HANDOFF'; AttemptId = $State.AttemptId; EventType = 'RStudioLaunchOnlyHandoff' } -Clock $Clock
    if (-not $transition.Success) {
        $blocked.ReasonCode = $transition.ReasonCode
        $blocked.Message = 'R-Studio started, but the handoff state could not be durably recorded.'
        $blocked.Handoff = $handoff
        $blocked | Add-Member -NotePropertyName Preconditions -NotePropertyValue $preconditions -Force
        return $blocked
    }
    return [pscustomobject]@{
        Allowed = $true
        Handoff = $handoff
        State = $State
        ReasonCode = $null
        Message = 'R-Studio was launched with launch-only arguments and the workflow stopped at the main-panel gate.'
        LaunchAttempted = $true
        Launched = [bool]$handoff.Launched
        AnalysisInvoked = [bool]$handoff.AnalysisInvoked
        Preconditions = $preconditions
    }
}

function Invoke-RecoveryAutomation {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = '',
        [switch]$NoPause,
        [switch]$DryRun,
        [string]$SourcePath = '',
        [string]$DestinationPath = '',
        [string]$ClientName = '',
        [object]$ConfigurationOverrides = $null,
        [object]$DiskProvider = $null,
        [scriptblock]$SourceSelector = $null,
        [scriptblock]$SourceProtectionProvider = $null,
        [scriptblock]$DestinationPickerProvider = $null,
        [scriptblock]$TypedDestinationProvider = $null,
        [scriptblock]$FileScavengerDiscoveryProvider = $null,
        [scriptblock]$RStudioDiscoveryProvider = $null,
        [scriptblock]$ApplicationFileInfoProvider = $null,
        [scriptblock]$ElevationProvider = $null,
        [scriptblock]$RuntimeProvider = $null,
        [scriptblock]$VendorProcessRunner = $null,
        [scriptblock]$FileScavengerProcessRunner = $null,
        [scriptblock]$RStudioProcessRunner = $null,
        [scriptblock]$FileScavengerUiProvider = $null,
        [scriptblock]$FileScavengerOutputProvider = $null,
        [scriptblock]$RStudioUiProvider = $null,
        [scriptblock]$RStudioFreshEvidenceProvider = $null,
        [scriptblock]$RStudioActivationProvider = $null,
        [scriptblock]$InteractionProvider = $null,
        [scriptblock]$ClientNameProvider = $null,
        [object]$LogWriterProvider = $null,
        [object]$StateWriterProvider = $null,
        [object]$ClaimProvider = $null,
        [object]$LockProvider = $null,
        [object]$Clock = $null,
        [object]$FileScavengerEvidenceMap = $null,
        [object]$RStudioEvidenceMap = $null,
        [object]$OperatorEvidenceProvider = $null,
        [object]$ValidatedFileScavengerBuilds = $null,
        [object]$ValidatedRStudioBuilds = $null
    )

    $state = $null
    $logHandle = $null
    $case = $null
    $launchAttempted = $false
    $mediaTouched = $false
    $applications = $null
    $configurationResult = $null
    $runtime = $null
    $sourceIdentity = $null
    $destinationIdentity = $null
    $capacity = $null
    $stateWriter = $null
    try {
        Import-RecoveryAutomationModules
    }
    catch {
        return New-RecoveryAutomationResult -Success $false -ExitCode 2 -Mode 'Preflight' `
            -ReasonCode 'RequiredModuleMissing' -Message $_.Exception.Message `
            -ConfigurationResult $null -VendorLaunchAttempted $false -RecoveryMediaTouched $false
    }

    try {
        [void]($stateWriter = New-RecoveryAutomationStateWriter -Provider $StateWriterProvider)
        $resolvedConfigPath = Get-RecoveryAutomationConfigPath -Path $ConfigPath
        $configurationResult = Configuration\Read-RecoveryConfiguration -Path $resolvedConfigPath
        if (-not $configurationResult.Valid) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 2 -Mode 'Preflight' `
                -ReasonCode $configurationResult.ErrorCode -Message (($configurationResult.Errors) -join ' ') `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false
        }

        $configurationObject = [ordered]@{}
        foreach ($property in $configurationResult.Configuration.PSObject.Properties) {
            $configurationObject[$property.Name] = $property.Value
        }
        if ($PSBoundParameters.ContainsKey('ValidatedFileScavengerBuilds')) {
            $configurationObject['ValidatedFileScavengerBuilds'] = @($ValidatedFileScavengerBuilds)
        }
        if ($PSBoundParameters.ContainsKey('ValidatedRStudioBuilds')) {
            $configurationObject['ValidatedRStudioBuilds'] = @($ValidatedRStudioBuilds)
        }

        $overrides = ConvertTo-RecoveryAutomationHashtable -InputObject $ConfigurationOverrides
        if ($NoPause) { $overrides['NoPause'] = $true }
        if ($PSBoundParameters.ContainsKey('DestinationPath')) { $overrides['DestinationRoot'] = $DestinationPath }
        if ($PSBoundParameters.ContainsKey('ClientName')) { $overrides['ClientName'] = $ClientName }
        $resolvedConfigurationResult = Configuration\Resolve-RecoveryConfiguration `
            -Configuration ([pscustomobject]$configurationObject) -Overrides $overrides
        if (-not $resolvedConfigurationResult.Valid) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 2 -Mode 'Preflight' `
                -ReasonCode $resolvedConfigurationResult.ErrorCode -Message (($resolvedConfigurationResult.Errors) -join ' ') `
                -ConfigurationResult $resolvedConfigurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false
        }
        $configurationResult = $resolvedConfigurationResult

        $runtime = Get-RecoveryAutomationRuntimeEvidence -Provider $RuntimeProvider
        if ($DryRun) {
            # The diagnostic path reports the inputs the caller actually supplied,
            # so a technician can prove that the arguments survived the launcher
            # and the elevation boundary before a real case is opened. Absent
            # values stay absent: a dry run never prompts and never invents one.
            $requestedInputs = [pscustomobject]@{
                SourcePath      = if ($PSBoundParameters.ContainsKey('SourcePath')) { [string]$SourcePath } else { '' }
                DestinationPath = Get-RecoveryAutomationEffectiveDestinationText -ConfigurationResult $configurationResult `
                    -ParameterValue $DestinationPath -ParameterBound ($PSBoundParameters.ContainsKey('DestinationPath'))
                ClientName      = Get-RecoveryAutomationEffectiveClientName -ConfigurationResult $configurationResult `
                    -ParameterValue $ClientName
                ConfigPath      = $resolvedConfigPath
            }
            $dryRunMessage = 'Configuration and runtime diagnostics completed; no vendor or recovery-media operation was attempted.'
            $dryRunResult = New-RecoveryAutomationResult -Success $true -ExitCode 0 -Mode 'DryRun' `
                -ReasonCode $null -Message $dryRunMessage -ConfigurationResult $configurationResult `
                -VendorLaunchAttempted $false -RecoveryMediaTouched $false -Runtime $runtime
            $dryRunResult | Add-Member -NotePropertyName RequestedInputs -NotePropertyValue $requestedInputs -Force
            return $dryRunResult
        }
        if (-not $runtime.Compatible) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 2 -Mode 'Preflight' `
                -ReasonCode 'RuntimeUnsupported' -Message ([string]$runtime.Evidence) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false -Runtime $runtime
        }

        $elevation = ApplicationDiscovery\Test-RecoveryElevated -ElevationProvider $ElevationProvider
        if ($elevation.IsElevated -ne $true) {
            $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-01' `
                -Reason 'Administrator elevation is required before either vendor application may be used.' `
                -Evidence $elevation -Choices @('Verify elevation', 'Stop') -SafeDefault 'Stop' `
                -InteractionProvider $InteractionProvider
            return New-RecoveryAutomationResult -Success $false -ExitCode 3 -Mode 'Preflight' `
                -ReasonCode $elevation.ReasonCode -Message ([string]$elevation.Evidence) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false `
                -Runtime $runtime -Applications ([pscustomobject]@{ Elevation = $elevation }) -Gate $gateResult
        }

        $fsResolution = ApplicationDiscovery\Resolve-RecoveryApplication -Product 'FileScavenger' `
            -ExplicitPath ([string]$configurationResult.Configuration.FileScavengerPath) `
            -DiscoveryProvider $FileScavengerDiscoveryProvider `
            -ValidatedBuilds @($configurationResult.Configuration.ValidatedFileScavengerBuilds) `
            -FileInfoProvider $ApplicationFileInfoProvider
        $rStudioResolution = ApplicationDiscovery\Resolve-RecoveryApplication -Product 'RStudio' `
            -ExplicitPath ([string]$configurationResult.Configuration.RStudioPath) `
            -DiscoveryProvider $RStudioDiscoveryProvider `
            -ValidatedBuilds @($configurationResult.Configuration.ValidatedRStudioBuilds) `
            -FileInfoProvider $ApplicationFileInfoProvider
        $applications = [pscustomobject]@{ Elevation = $elevation; FileScavenger = $fsResolution; RStudio = $rStudioResolution }
        if (-not $fsResolution.Success -or -not $rStudioResolution.Success) {
            $failedResolution = $fsResolution
            if ($fsResolution.Success) { $failedResolution = $rStudioResolution }
            $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-01' `
                -Reason 'A required vendor executable is missing, ambiguous, unexpected, or not validated for this exact build.' `
                -Evidence $applications -Choices @('Verify the executable and build', 'Stop') -SafeDefault 'Stop' `
                -InteractionProvider $InteractionProvider
            return New-RecoveryAutomationResult -Success $false -ExitCode 3 -Mode 'Preflight' `
                -ReasonCode $failedResolution.ReasonCode -Message (($failedResolution.Errors) -join ' ') `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false `
                -Runtime $runtime -Applications $applications -Gate $gateResult
        }

        $sourceSelection = Get-RecoveryAutomationSourceSelection -ExplicitPath $SourcePath -Selector $SourceSelector
        if (-not $sourceSelection.Selected) {
            $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-02' `
                -Reason 'A technician-selected source path is required; no source is inferred.' `
                -Evidence $sourceSelection -Choices @('Select source', 'Stop') -SafeDefault 'Stop' `
                -InteractionProvider $InteractionProvider
            return New-RecoveryAutomationResult -Success $false -ExitCode 4 -Mode 'Source' `
                -ReasonCode $sourceSelection.ReasonCode -Message ([string]$sourceSelection.Evidence) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false `
                -Runtime $runtime -Applications $applications -Gate $gateResult
        }
        $protection = Test-RecoveryAutomationSourceProtection -Path ([string]$sourceSelection.Path) `
            -Selection $sourceSelection.Raw -Provider $SourceProtectionProvider
        if (-not $protection.Verified) {
            $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-02' `
                -Reason 'The selected source has no verified read-only or write-blocker evidence.' `
                -Evidence $protection -Choices @('Record write-blocker evidence', 'Stop') -SafeDefault 'Stop' `
                -InteractionProvider $InteractionProvider
            return New-RecoveryAutomationResult -Success $false -ExitCode 4 -Mode 'Source' `
                -ReasonCode $protection.ReasonCode -Message ([string]$protection.Evidence) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $false `
                -Runtime $runtime -Applications $applications -Gate $gateResult
        }

        if ($null -eq $DiskProvider) { $DiskProvider = New-RecoveryAutomationWindowsDiskProvider }
        $sourceIdentity = DiskDetection\Resolve-RecoveryPathIdentity -Path ([string]$sourceSelection.Path) -Provider $DiskProvider
        $mediaTouched = $true
        if ($sourceIdentity.Resolved -ne $true -or $sourceIdentity.IsIndeterminate -eq $true) {
            $sourceReason = 'SourceIndeterminate'
            if ($sourceIdentity.ReasonCode -eq 'PathInvalid' -or $sourceIdentity.ReasonCode -eq 'PathNotRooted' -or $sourceIdentity.ReasonCode -eq 'PathMissing') {
                $sourceReason = 'SourcePathInvalid'
            }
            return New-RecoveryAutomationResult -Success $false -ExitCode 4 -Mode 'Source' `
                -ReasonCode $sourceReason -Message ([string]$sourceIdentity.ReasonCode) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity
        }
        $sourceIdentity | Add-Member -NotePropertyName ReadOnlyVerified -NotePropertyValue $protection.Verified -Force
        $sourceIdentity | Add-Member -NotePropertyName ReadOnlyEvidence -NotePropertyValue $protection.Evidence -Force

        $destinationText = Get-RecoveryAutomationEffectiveDestinationText -ConfigurationResult $configurationResult `
            -ParameterValue $DestinationPath -ParameterBound ($PSBoundParameters.ContainsKey('DestinationPath'))
        if ([string]::IsNullOrWhiteSpace([string]$destinationText)) {
            $picker = $null
            $typedPicker = $null
            if ($null -ne $DestinationPickerProvider) {
                $picker = @{ Pick = { param($request) & $DestinationPickerProvider $request }.GetNewClosure() }
            }
            if ($null -ne $TypedDestinationProvider) {
                $typedPicker = @{ ReadPath = { param($request) & $TypedDestinationProvider $request }.GetNewClosure() }
            }
            # The typed path is a first-class documented selection method: it is
            # tried whenever either provider is available, not only when a
            # graphical picker happens to be wired.
            if ($null -ne $picker -or $null -ne $typedPicker) {
                $selection = DiskDetection\Select-DestinationFolder -PickerProvider $picker -TypedPathProvider $typedPicker
                if ($selection.Selected) { $destinationText = $selection.Path }
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$destinationText)) {
            $gateResult = Invoke-RecoveryAutomationGate -GateId 'G-03' `
                -Reason 'A destination folder must be selected and resolved before any case output is created.' `
                -Evidence ([pscustomobject]@{ DestinationPath = $destinationText }) `
                -Choices @('Select destination', 'Stop') -SafeDefault 'Stop' -InteractionProvider $InteractionProvider
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Destination' `
                -ReasonCode 'DestinationNotSelected' -Message 'No destination path was selected.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity -Gate $gateResult
        }

        $destinationIdentity = DiskDetection\Resolve-RecoveryPathIdentity -Path ([string]$destinationText) -Provider $DiskProvider
        $mediaTouched = $true
        $separation = DiskDetection\Test-DestinationSafety -SourceIdentity $sourceIdentity `
            -DestinationPath ([string]$destinationText) -Provider $DiskProvider -DestinationIdentity $destinationIdentity
        if (-not $separation.Allowed) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Destination' `
                -ReasonCode $separation.ReasonCode -Message 'The destination is not proven safe for this source.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity
        }
        $capacity = DiskDetection\Get-RecoveryDestinationSpace -Path ([string]$destinationText) -Provider $DiskProvider `
            -ReserveBytes ([int64]$configurationResult.Configuration.CapacityReserveBytes)
        if ($capacity.IsUnknown -or -not $capacity.IsSufficient) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Destination' `
                -ReasonCode $capacity.ReasonCode -Message 'Destination capacity is unknown or below the configured reserve.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity
        }

        $effectiveClientName = $ClientName
        if ([string]::IsNullOrWhiteSpace($effectiveClientName)) { $effectiveClientName = [string]$configurationResult.Configuration.ClientName }
        if ([string]::IsNullOrWhiteSpace($effectiveClientName) -and $null -ne $ClientNameProvider) {
            # Explicit technician input: the default front door asks instead of
            # inventing a name. Validation is unchanged and still fail-closed:
            # an empty, cancelled, reserved, or unusable answer ends in the same
            # ClientNameInvalid path, and sanitizing stays in New-RecoveryJobFolder.
            $clientPrompt = $null
            try {
                $clientPrompt = & $ClientNameProvider ([pscustomobject]@{ Purpose = 'ClientName'; Configuration = $configurationResult.Configuration })
            }
            catch {
                $clientPrompt = $null
            }
            if ($null -ne $clientPrompt) {
                if ($clientPrompt -is [string]) {
                    $effectiveClientName = ([string]$clientPrompt).Trim()
                }
                else {
                    $cancelled = Get-RecoveryAutomationValue -InputObject $clientPrompt -Names @('Cancelled')
                    $promptedName = Get-RecoveryAutomationValue -InputObject $clientPrompt -Names @('ClientName', 'Name', 'Answer')
                    if ((Test-RecoveryAutomationBoolean $cancelled) -ne $true -and $null -ne $promptedName) {
                        $effectiveClientName = ([string]$promptedName).Trim()
                    }
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($effectiveClientName)) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Case' `
                -ReasonCode 'ClientNameInvalid' -Message 'A client name is required before a job folder can be claimed.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity
        }
        # The destination root was proven separate above, but the case folder that
        # is about to be generated is a different path and is proven separately
        # before the folder or its claim marker can exist. Getting this wrong is how
        # a claim marker used to appear on media that was never proven separate.
        $diskProviderForClaimCheck = $DiskProvider
        $sourceForClaimCheck = $sourceIdentity
        $preclaimSafetyCheck = {
            param($request)
            $candidateIdentity = DiskDetection\Resolve-RecoveryPathIdentity -Path ([string]$request.Path) -Provider $diskProviderForClaimCheck
            $candidateSeparation = DiskDetection\Test-DestinationSafety -SourceIdentity $sourceForClaimCheck `
                -DestinationPath ([string]$request.Path) -Provider $diskProviderForClaimCheck -DestinationIdentity $candidateIdentity
            return [pscustomobject]@{ Allowed = [bool]$candidateSeparation.Allowed; ReasonCode = $candidateSeparation.ReasonCode }
        }.GetNewClosure()
        $folderResult = DiskDetection\New-RecoveryJobFolder -RootPath ([string]$destinationText) `
            -ClientName $effectiveClientName -Clock $Clock -ClaimProvider $ClaimProvider `
            -PreclaimSafetyCheck $preclaimSafetyCheck `
            -MaxPathLength ([int]$configurationResult.Configuration.MaxJobPathLength)
        $case = [pscustomobject]@{ JobFolderPath = $folderResult.JobFolderPath; ClaimPath = $folderResult.ClaimPath; StatePath = $null; LogPath = $null; MetadataPath = $null; FolderResult = $folderResult }
        if (-not $folderResult.Created) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Case' `
                -ReasonCode $folderResult.ReasonCode -Message ([string]$folderResult.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case
        }
        $case.StatePath = Join-Path -Path $folderResult.JobFolderPath -ChildPath 'job-state.json'
        $case.LogPath = Join-Path -Path $folderResult.JobFolderPath -ChildPath 'events.jsonl'
        $case.MetadataPath = Join-Path -Path $folderResult.JobFolderPath -ChildPath 'case-metadata.json'

        $finalDestinationIdentity = DiskDetection\Resolve-RecoveryPathIdentity -Path $folderResult.JobFolderPath -Provider $DiskProvider
        $mediaTouched = $true
        $finalSeparation = DiskDetection\Test-DestinationSafety -SourceIdentity $sourceIdentity `
            -DestinationPath $folderResult.JobFolderPath -Provider $DiskProvider -DestinationIdentity $finalDestinationIdentity
        if (-not $finalSeparation.Allowed) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Case' `
                -ReasonCode $finalSeparation.ReasonCode -Message 'The claimed job folder is not proven safe for this source.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $finalDestinationIdentity -Capacity $capacity -Case $case
        }
        $finalCapacity = DiskDetection\Get-RecoveryDestinationSpace -Path $folderResult.JobFolderPath -Provider $DiskProvider `
            -ReserveBytes ([int64]$configurationResult.Configuration.CapacityReserveBytes)
        if ($finalCapacity.IsUnknown -or -not $finalCapacity.IsSufficient) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Case' `
                -ReasonCode $finalCapacity.ReasonCode -Message 'Capacity changed before case creation.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $finalDestinationIdentity -Capacity $finalCapacity -Case $case
        }
        $destinationIdentity = $finalDestinationIdentity
        $capacity = $finalCapacity

        $jobId = [System.IO.Path]::GetFileName($folderResult.JobFolderPath)
        $state = JobState\New-RecoveryJobState -JobId $jobId -SourceIdentity $sourceIdentity `
            -DestinationIdentity $destinationIdentity -ApplicationEvidence $applications `
            -Paths ([pscustomobject]@{ JobFolderPath = $folderResult.JobFolderPath; StatePath = $case.StatePath; LogPath = $case.LogPath }) `
            -WorkflowVersion ([string]$configurationResult.Configuration.WorkflowVersion) -State 'PREFLIGHT_PENDING' -Clock $Clock
        $state | Add-Member -NotePropertyName CapacityPolicy -NotePropertyValue $capacity -Force
        $state | Add-Member -NotePropertyName DestinationRootIdentity -NotePropertyValue $separation.DestinationEvidence -Force
        $state | Add-Member -NotePropertyName ClientName -NotePropertyValue $folderResult.ClientName -Force
        $state | Add-Member -NotePropertyName MetadataPath -NotePropertyValue $case.MetadataPath -Force
        $state | Add-Member -NotePropertyName SourceProtection -NotePropertyValue $protection -Force

        $lock = JobState\Lock-RecoveryJob -JobPath $folderResult.JobFolderPath -LockProvider $LockProvider -Clock $Clock `
            -Owner ('RecoveryAutomation/' + $jobId)
        if (-not $lock.Acquired) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                -ReasonCode $lock.ReasonCode -Message ([string]$lock.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
        }
        $state.Lock = $lock
        $state | Add-Member -NotePropertyName Preconditions -NotePropertyValue ([pscustomobject]@{
                LogFlushed = $false
                LockOwned = $true
                ElevationPassed = $true
                FreshSafetyCheckPassed = $false
            }) -Force
        $stateWrite = JobState\Write-RecoveryJobState -Path $case.StatePath -State $state -Writer $stateWriter
        if (-not $stateWrite.Success) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                -ReasonCode $stateWrite.ReasonCode -Message ([string]$stateWrite.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
        }
        $metadata = [pscustomobject]@{
            SchemaVersion = 1
            WorkflowVersion = $configurationResult.Configuration.WorkflowVersion
            JobId = $jobId
            ClientName = $folderResult.ClientName
            SourceIdentity = $sourceIdentity
            DestinationIdentity = $destinationIdentity
            CapacityPolicy = $capacity
            ApplicationEvidence = $applications
            Paths = $case
        }
        $metadataWrite = Write-RecoveryAutomationMetadata -Path $case.MetadataPath -Metadata $metadata
        if (-not $metadataWrite.Success) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                -ReasonCode $metadataWrite.ReasonCode -Message ([string]$metadataWrite.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
        }
        $logResult = RecoveryLogging\New-RecoveryLog -Path $case.LogPath -JobId $jobId -Writer $LogWriterProvider -Clock $Clock
        if (-not $logResult.Success) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                -ReasonCode $logResult.ReasonCode -Message ([string]$logResult.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
        }
        $logHandle = $logResult.Writer
        $readEventValue = {
            param($InputObject, [string[]]$Names)
            foreach ($name in $Names) {
                if ($null -eq $InputObject) { return $null }
                if ($InputObject -is [System.Collections.IDictionary]) {
                    if ($InputObject.Contains($name)) { return $InputObject[$name] }
                }
                else {
                    $property = $InputObject.PSObject.Properties[$name]
                    if ($null -ne $property) { return $property.Value }
                }
            }
            return $null
        }.GetNewClosure()
        $eventWriter = {
            param($event)
            try {
                $eventState = [string](& $readEventValue $event @('State'))
                if ([string]::IsNullOrWhiteSpace($eventState)) { $eventState = [string]$state.State }
                $eventStage = [string](& $readEventValue $event @('Stage'))
                $eventAttemptId = [string](& $readEventValue $event @('AttemptId'))
            }
            catch {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'EventWriteFailed'; Message = $_.Exception.Message }
            }
            $entry = [pscustomobject]@{
                JobId = $state.JobId
                State = $eventState
                Stage = $eventStage
                AttemptId = $eventAttemptId
                EventType = [string](& $readEventValue $event @('EventType'))
                Result = [string](& $readEventValue $event @('Result'))
                SourceIdentity = $state.SourceIdentity
                DestinationIdentity = $state.DestinationIdentity
                Decision = & $readEventValue $event @('Decision')
                Error = & $readEventValue $event @('Error')
                Gate = & $readEventValue $event @('Gate')
            }

            $priorSequence = [int]$state.LastEventSequence
            $write = $null
            try {
                $write = RecoveryLogging\Write-RecoveryLogEntry -Writer $logHandle -Entry $entry
            }
            catch {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'EventWriteFailed'; Message = $_.Exception.Message }
            }
            if ($null -eq $write -or $write.Success -ne $true) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'EventWriteFailed'; Message = 'The event log write was refused.' }
            }
            $reportedSequence = & $readEventValue $write @('Sequence')
            if ($null -eq $reportedSequence) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'EventSequenceMissing'; Message = 'The event writer did not report its durable sequence.' }
            }
            $sequence = 0
            if (-not [int]::TryParse([string]$reportedSequence, [ref]$sequence) -or $sequence -le $priorSequence) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'EventSequenceInvalid'; Message = 'The event writer returned an invalid durable sequence.' }
            }
            [void]($state.LastEventSequence = $sequence)
            try { $snapshot = JobState\Write-RecoveryJobState -Path $case.StatePath -State $state -Writer $stateWriter }
            catch {
                throw
            }
            if ($null -eq $snapshot -or $snapshot.Success -ne $true) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'EventStateWriteFailed'; Message = 'The state snapshot after the event write failed.' }
            }
            return $write
        }.GetNewClosure()
        foreach ($eventName in @('SourceIdentityCaptured', 'DestinationIdentityCaptured', 'DestinationSeparationVerified')) {
            $eventResult = Write-RecoveryAutomationEvent -Writer $logHandle -State $state -EventType $eventName
            if (-not $eventResult.Success) {
                return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                    -ReasonCode $eventResult.ReasonCode -Message ([string]$eventResult.Message) `
                    -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                    -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                    -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
            }
        }
        $preflightTransition = JobState\Set-RecoveryState -State $state -To 'PREFLIGHT_PASSED' -EventWriter $eventWriter `
            -StateWriter $stateWriter -Context @{ Evidence = 'PreflightPassed' } -Clock $Clock
        if (-not $preflightTransition.Success) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                -ReasonCode $preflightTransition.ReasonCode -Message ([string]$preflightTransition.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
        }
        $state.Preconditions.LogFlushed = $true
        $caseTransition = JobState\Set-RecoveryState -State $state -To 'CASE_READY' -EventWriter $eventWriter `
            -StateWriter $stateWriter -Context @{ Evidence = 'CaseCreated' } -Clock $Clock
        if (-not $caseTransition.Success) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 6 -Mode 'Case' `
                -ReasonCode $caseTransition.ReasonCode -Message ([string]$caseTransition.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
                -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
        }

        $freshSourceIdentity = DiskDetection\Resolve-RecoveryPathIdentity -Path ([string]$sourceSelection.Path) -Provider $DiskProvider
        $freshDestinationIdentity = DiskDetection\Resolve-RecoveryPathIdentity -Path $folderResult.JobFolderPath -Provider $DiskProvider
        $mediaTouched = $true
        $freshSeparation = DiskDetection\Test-DestinationSafety -SourceIdentity $freshSourceIdentity `
            -DestinationPath $folderResult.JobFolderPath -Provider $DiskProvider -DestinationIdentity $freshDestinationIdentity
        $freshCapacity = DiskDetection\Get-RecoveryDestinationSpace -Path $folderResult.JobFolderPath -Provider $DiskProvider `
            -ReserveBytes ([int64]$configurationResult.Configuration.CapacityReserveBytes)
        if (-not $freshSeparation.Allowed -or $freshCapacity.IsUnknown -or -not $freshCapacity.IsSufficient) {
            $freshReason = $freshSeparation.ReasonCode
            if ($freshSeparation.Allowed) { $freshReason = $freshCapacity.ReasonCode }
            $failureEvent = Write-RecoveryAutomationEvent -Writer $logHandle -State $state -EventType 'StageFailed' `
                -Result 'Failed' -Stage 'PREFLIGHT' -ErrorDetail $freshReason
            return New-RecoveryAutomationResult -Success $false -ExitCode 5 -Mode 'Preflight' `
                -ReasonCode $freshReason -Message 'Fresh source, destination, or capacity checks failed before launch.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $freshSourceIdentity `
                -DestinationIdentity $freshDestinationIdentity -Capacity $freshCapacity -Case $case -State $state
        }
        $freshProtection = Test-RecoveryAutomationSourceProtection -Path ([string]$sourceSelection.Path) `
            -Selection $protection.Raw -Provider $SourceProtectionProvider
        if (-not $freshProtection.Verified) {
            $failureEvent = Write-RecoveryAutomationEvent -Writer $logHandle -State $state -EventType 'SourceIdentityChanged' `
                -Result 'Failed' -Stage 'PREFLIGHT' -ErrorDetail $freshProtection.ReasonCode
            return New-RecoveryAutomationResult -Success $false -ExitCode 4 -Mode 'Preflight' `
                -ReasonCode $freshProtection.ReasonCode -Message 'Fresh source protection evidence failed before launch.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $false -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $freshSourceIdentity `
                -DestinationIdentity $freshDestinationIdentity -Capacity $freshCapacity -Case $case -State $state
        }
        $state.Preconditions.FreshSafetyCheckPassed = $true
        $state.SourceIdentity = $freshSourceIdentity
        $state.DestinationIdentity = $freshDestinationIdentity
        $state.CapacityPolicy = $freshCapacity
        $state.SourceProtection = $freshProtection
        $fsExecutable = ConvertTo-RecoveryAutomationExecutable -Candidate $fsResolution.Candidate -Product 'FileScavenger'
        $fsRunner = $FileScavengerProcessRunner
        if ($null -eq $fsRunner) { $fsRunner = $VendorProcessRunner }
        $startResult = FileScavenger\Start-FileScavenger -Executable $fsExecutable -State $state `
            -Preconditions $state.Preconditions -ProcessRunner $fsRunner -EventWriter $eventWriter
        $launchAttempted = $true
        if (-not $startResult.Allowed -or -not $startResult.Started) {
            $failureEvent = Write-RecoveryAutomationEvent -Writer $logHandle -State $state -EventType 'StageFailed' `
                -Result 'Failed' -Stage 'LAUNCH' -ErrorDetail $startResult.ReasonCode
            return New-RecoveryAutomationResult -Success $false -ExitCode 7 -Mode 'FileScavenger' `
                -ReasonCode $startResult.ReasonCode -Message ([string]$startResult.Reason) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
                -DestinationIdentity $state.DestinationIdentity -Capacity $freshCapacity -Case $case -State $state
        }
        $state | Add-Member -NotePropertyName ProcessIdentity -NotePropertyValue $startResult.ProcessIdentity -Force
        $state.Stage = 'SHORT_SCAN'
        $state.AttemptId = $jobId + '-short-scan-001'
        $state.AttemptStartedUtc = $startResult.ProcessIdentity.StartTime
        $runningTransition = JobState\Set-RecoveryState -State $state -To 'SHORT_SCAN_RUNNING' -EventWriter $eventWriter `
            -StateWriter $stateWriter -Context @{ Evidence = 'LaunchGateRecorded'; Stage = 'SHORT_SCAN'; AttemptId = $state.AttemptId; EventType = 'StageStarted' } -Clock $Clock
        if (-not $runningTransition.Success) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 7 -Mode 'FileScavenger' `
                -ReasonCode $runningTransition.ReasonCode -Message ([string]$runningTransition.Message) `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
                -DestinationIdentity $state.DestinationIdentity -Capacity $freshCapacity -Case $case -State $state
        }
        $launchGate = Invoke-RecoveryAutomationGate -GateId 'G-04' `
            -Reason 'File Scavenger is launch-only here. Perform source selection, Quick scan, and Step 2: Save manually; no undocumented switch or click is supplied.' `
            -Evidence ([pscustomobject]@{ Executable = $fsExecutable; ProcessIdentity = $startResult.ProcessIdentity; Arguments = @() }) `
            -Choices @('Continue', 'Stop') -SafeDefault 'Stop' -InteractionProvider $InteractionProvider
        $state | Add-Member -NotePropertyName GateDecisions -NotePropertyValue @($launchGate.Presentation) -Force
        $gatePresentedEvent = Write-RecoveryAutomationEvent -Writer $logHandle -State $state `
            -EventType 'OperatorGatePresented' -Result 'Presented' -Stage 'SHORT_SCAN' `
            -AttemptId $state.AttemptId -Decision $launchGate.Decision -Gate $launchGate.Gate
        if ($null -eq $gatePresentedEvent -or $gatePresentedEvent.Success -ne $true) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 8 -Mode 'FileScavenger' `
                -ReasonCode 'GateEventWriteFailed' -Message 'The File Scavenger gate presentation could not be durably recorded.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
                -DestinationIdentity $state.DestinationIdentity -Capacity $freshCapacity -Case $case -Gate $launchGate -State $state
        }
        $operatorDecisionEvent = Write-RecoveryAutomationEvent -Writer $logHandle -State $state `
            -EventType 'OperatorDecision' -Result 'Recorded' -Stage 'SHORT_SCAN' `
            -AttemptId $state.AttemptId -Decision $launchGate.Decision -Gate $launchGate.Gate
        if ($null -eq $operatorDecisionEvent -or $operatorDecisionEvent.Success -ne $true) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 8 -Mode 'FileScavenger' `
                -ReasonCode 'GateEventWriteFailed' -Message 'The File Scavenger gate decision could not be durably recorded.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
                -DestinationIdentity $state.DestinationIdentity -Capacity $freshCapacity -Case $case -Gate $launchGate -State $state
        }
        $gateStateWrite = JobState\Write-RecoveryJobState -Path $case.StatePath -State $state -Writer $stateWriter
        if ($null -eq $gateStateWrite -or $gateStateWrite.Success -ne $true) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 8 -Mode 'FileScavenger' `
                -ReasonCode 'GateStateWriteFailed' -Message 'The File Scavenger gate decision could not be durably snapshotted.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
                -DestinationIdentity $state.DestinationIdentity -Capacity $freshCapacity -Case $case -Gate $launchGate -State $state
        }
        if (-not $launchGate.Continues) {
            return New-RecoveryAutomationResult -Success $false -ExitCode 8 -Mode 'FileScavenger' `
                -ReasonCode 'ManualGatePending' -Message 'File Scavenger was launched; the workflow stopped at its manual gate.' `
                -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
                -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
                -DestinationIdentity $state.DestinationIdentity -Capacity $freshCapacity -Case $case -Gate $launchGate -State $state
        }

        $rStudioExecutable = ConvertTo-RecoveryAutomationExecutable -Candidate $rStudioResolution.Candidate -Product 'RStudio'
        $workflowResult = Invoke-RecoveryAutomationWorkflow -State $state -Case $case -LogWriter $logHandle -StateWriter $stateWriter `
            -SourcePath ([string]$sourceSelection.Path) -DestinationPath $folderResult.JobFolderPath -DiskProvider $DiskProvider `
            -Applications $applications -FileScavengerExecutable $fsExecutable -RStudioExecutable $rStudioExecutable `
            -SourceProtectionProvider $SourceProtectionProvider `
            -ReserveBytes ([int64]$configurationResult.Configuration.CapacityReserveBytes) `
            -FileScavengerEvidenceMap $FileScavengerEvidenceMap -FileScavengerUiProvider $FileScavengerUiProvider `
            -FileScavengerOutputProvider $FileScavengerOutputProvider -OperatorEvidenceProvider $OperatorEvidenceProvider `
            -InteractionProvider $InteractionProvider -EventWriter $eventWriter -RStudioProcessRunner $RStudioProcessRunner `
            -RStudioFreshEvidenceProvider $RStudioFreshEvidenceProvider -RStudioActivationProvider $RStudioActivationProvider -Clock $Clock
        $workflowExitCode = 8
        $workflowMode = 'FileScavenger'
        if ($workflowResult.Success) { $workflowExitCode = 0; $workflowMode = 'Handoff' }
        $workflowHandoff = $workflowResult.Handoff
        if ($null -eq $workflowHandoff) { $workflowHandoff = $null }
        return New-RecoveryAutomationResult -Success $workflowResult.Success -ExitCode $workflowExitCode -Mode $workflowMode `
            -ReasonCode $workflowResult.ReasonCode -Message $workflowResult.Message `
            -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
            -Runtime $runtime -Applications $applications -SourceIdentity $state.SourceIdentity `
            -DestinationIdentity $state.DestinationIdentity -Capacity $state.CapacityPolicy -Case $case `
            -Gate $workflowResult.Gate -Handoff $workflowHandoff -State $state
    }
    catch {
        if ($null -ne $logHandle -and $null -ne $state) {
            try { [void](Write-RecoveryAutomationEvent -Writer $logHandle -State $state -EventType 'StageFailed' -Result 'Failed' -ErrorDetail $_.Exception.Message) } catch { }
        }
        return New-RecoveryAutomationResult -Success $false -ExitCode 9 -Mode 'Failed' `
            -ReasonCode 'UnhandledWorkflowError' -Message $_.Exception.Message `
            -ConfigurationResult $configurationResult -VendorLaunchAttempted $launchAttempted -RecoveryMediaTouched $mediaTouched `
            -Runtime $runtime -Applications $applications -SourceIdentity $sourceIdentity `
            -DestinationIdentity $destinationIdentity -Capacity $capacity -Case $case -State $state
    }
    finally {
        # The case log is opened with FileShare.Read, so on Windows the events
        # file stays locked until this close runs. Every return path above,
        # including early refusals and the unhandled-error path, releases the
        # handle so the case folder can be archived, moved, or cleaned up.
        if ($null -ne $logHandle) {
            try {
                $closeResult = RecoveryLogging\Close-RecoveryLog -Writer $logHandle
                if ($null -eq $closeResult -or $closeResult.Success -ne $true) {
                    Write-Warning 'The case event log handle could not be closed cleanly.'
                }
            }
            catch {
                Write-Warning ('The case event log handle could not be closed cleanly: ' + $_.Exception.Message)
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # The front door forwards every documented technician input. A value that is
    # not forwarded is lost for the whole run.
    $elevationLaunch = Invoke-RecoveryAutomationSelfElevation -ScriptPath $PSCommandPath `
        -ConfigPath $RecoveryConfigPath -NoPause:$NoPause -DryRun:$DryRun -SkipElevation:$DryRun `
        -SourcePath $SourcePath -DestinationPath $DestinationPath -ClientName $ClientName
    if ($elevationLaunch.ShouldExit) {
        if ($elevationLaunch.Success) {
            exit $elevationLaunch.ExitCode
        }
        $elevationResult = New-RecoveryAutomationResult -Success $false -ExitCode $elevationLaunch.ExitCode `
            -Mode 'Elevation' -ReasonCode $elevationLaunch.ReasonCode -Message $elevationLaunch.Message `
            -ConfigurationResult $null -VendorLaunchAttempted $false -RecoveryMediaTouched $false
        Write-Output $elevationResult
        exit $elevationResult.ExitCode
    }

    # Default front door: wire the documented interactive seams when nothing was
    # injected so the launcher is a usable workflow, then forward every value the
    # caller actually supplied. An unsupplied value is never forwarded as an
    # empty override, so the configuration fallback survives.
    $frontDoorWiring = Get-RecoveryAutomationFrontDoorWiring `
        -SourceSelector $SourceSelector -SourceProtectionProvider $SourceProtectionProvider `
        -DestinationPickerProvider $DestinationPickerProvider -TypedDestinationProvider $TypedDestinationProvider `
        -InteractionProvider $InteractionProvider
    $frontDoorArguments = @{
        ConfigPath                = $RecoveryConfigPath
        NoPause                   = $NoPause.IsPresent
        DryRun                    = $DryRun.IsPresent
        SourceSelector            = $frontDoorWiring.SourceSelector
        SourceProtectionProvider  = $frontDoorWiring.SourceProtectionProvider
        DestinationPickerProvider = $frontDoorWiring.DestinationPickerProvider
        TypedDestinationProvider  = $frontDoorWiring.TypedDestinationProvider
        InteractionProvider       = $frontDoorWiring.InteractionProvider
        ClientNameProvider        = $frontDoorWiring.ClientNameProvider
    }
    foreach ($boundName in @($PSBoundParameters.Keys)) {
        if ($boundName -eq 'RecoveryConfigPath') { continue }
        $boundValue = $PSBoundParameters[$boundName]
        if ($boundValue -is [string] -and [string]::IsNullOrWhiteSpace($boundValue)) { continue }
        $frontDoorArguments[$boundName] = $boundValue
    }
    $entryResult = Invoke-RecoveryAutomation @frontDoorArguments
    if ($null -ne $entryResult) {
        $entryResult | Add-Member -NotePropertyName FrontDoorWiring -NotePropertyValue @($frontDoorWiring.Evidence) -Force
    }
    Write-Output $entryResult
    exit $entryResult.ExitCode
}
