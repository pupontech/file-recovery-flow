# JobState.psm1
#
# Job state schema, atomic snapshot writes, the explicit state machine, the
# exclusive job lock, and resume decisions.
#
# The state snapshot is never the only evidence: the append only event log stays
# authoritative. Every snapshot write is confined to the claimed job folder, is
# refused when it would replace a different job, and is written through an
# explicit writer seam so a failure is reported instead of silently ignored.
#
# The transition table below is the only source of legal transitions. A verified
# stage is never rerun without a new attempt id and an explicit operator decision.

Set-StrictMode -Off

function Get-RecoveryCanonicalStateList {
    return @(
        'NEW',
        'PREFLIGHT_PENDING',
        'PREFLIGHT_PASSED',
        'CASE_READY',
        'SHORT_SCAN_RUNNING',
        'SHORT_SCAN_FINISHED',
        'SHORT_RECOVERY_RUNNING',
        'SHORT_RECOVERY_FINISHED',
        'SHORT_RECOVERY_VERIFIED',
        'LONG_SCAN_RUNNING',
        'LONG_SCAN_FINISHED',
        'LONG_RECOVERY_RUNNING',
        'LONG_RECOVERY_FINISHED',
        'LONG_RECOVERY_VERIFIED',
        'PAUSED',
        'INTERRUPTED_UNKNOWN',
        'FAILED_CLOSED',
        'READY_FOR_HANDOFF',
        'HANDOFF_MANUAL',
        'ABORTED'
    )
}

function ConvertTo-RecoveryArray {
    param([object]$Value)
    if ($null -eq $Value) { return [object[]]@() }
    if ($Value -is [string]) { return [object[]]@($Value) }
    if ($Value -is [System.Collections.IEnumerable]) {
        $buffer = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $buffer.Add($item) | Out-Null }
        return $buffer.ToArray()
    }
    return [object[]]@($Value)
}

function Test-RecoveryCanonicalState {
    param([string]$State)
    if ($null -eq $State) { return $false }
    foreach ($candidate in (Get-RecoveryCanonicalStateList)) {
        if ($candidate -eq $State) { return $true }
    }
    return $false
}

function Get-RecoveryTransitionTable {
    $table = @{}
    $entries = @(
        @{ Key = 'NEW|PREFLIGHT_PENDING'; Evidence = $null; Decision = $false },
        @{ Key = 'PREFLIGHT_PENDING|PREFLIGHT_PASSED'; Evidence = 'PreflightPassed'; Decision = $false },
        @{ Key = 'PREFLIGHT_PENDING|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'PREFLIGHT_PENDING|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'PREFLIGHT_PASSED|CASE_READY'; Evidence = 'CaseCreated'; Decision = $false },
        @{ Key = 'PREFLIGHT_PASSED|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'CASE_READY|SHORT_SCAN_RUNNING'; Evidence = 'LaunchGateRecorded'; Decision = $false },
        @{ Key = 'CASE_READY|INTERRUPTED_UNKNOWN'; Evidence = 'LaunchAttemptUncertain'; Decision = $false; RequiresLaunchAttempt = $true },
        @{ Key = 'CASE_READY|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'CASE_READY|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_SCAN_RUNNING|SHORT_SCAN_FINISHED'; Evidence = 'ScanFinished'; Decision = $false },
        @{ Key = 'SHORT_SCAN_RUNNING|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_SCAN_RUNNING|INTERRUPTED_UNKNOWN'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_SCAN_RUNNING|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_SCAN_FINISHED|SHORT_RECOVERY_RUNNING'; Evidence = 'RecoveryDestinationChecked'; Decision = $false },
        @{ Key = 'SHORT_SCAN_FINISHED|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_SCAN_FINISHED|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_RUNNING|SHORT_RECOVERY_FINISHED'; Evidence = 'RecoveryFinished'; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_RUNNING|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_RUNNING|INTERRUPTED_UNKNOWN'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_RUNNING|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_FINISHED|SHORT_RECOVERY_VERIFIED'; Evidence = 'OutputObserved'; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_FINISHED|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_FINISHED|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_VERIFIED|LONG_SCAN_RUNNING'; Evidence = 'LongScanApproved'; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_VERIFIED|READY_FOR_HANDOFF'; Evidence = 'FileScavengerWorkVerified'; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_VERIFIED|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'SHORT_RECOVERY_VERIFIED|ABORTED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_SCAN_RUNNING|LONG_SCAN_FINISHED'; Evidence = 'ScanFinished'; Decision = $false },
        @{ Key = 'LONG_SCAN_RUNNING|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_SCAN_RUNNING|INTERRUPTED_UNKNOWN'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_SCAN_RUNNING|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_SCAN_FINISHED|LONG_RECOVERY_RUNNING'; Evidence = 'RecoveryDestinationChecked'; Decision = $false },
        @{ Key = 'LONG_SCAN_FINISHED|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_SCAN_FINISHED|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_RUNNING|LONG_RECOVERY_FINISHED'; Evidence = 'RecoveryFinished'; Decision = $false },
        @{ Key = 'LONG_RECOVERY_RUNNING|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_RUNNING|INTERRUPTED_UNKNOWN'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_RUNNING|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_FINISHED|LONG_RECOVERY_VERIFIED'; Evidence = 'OutputObserved'; Decision = $false },
        @{ Key = 'LONG_RECOVERY_FINISHED|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_FINISHED|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_VERIFIED|READY_FOR_HANDOFF'; Evidence = 'FinalChecksPassed'; Decision = $false },
        @{ Key = 'LONG_RECOVERY_VERIFIED|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'LONG_RECOVERY_VERIFIED|ABORTED'; Evidence = $null; Decision = $false },
        @{ Key = 'INTERRUPTED_UNKNOWN|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'INTERRUPTED_UNKNOWN|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'PAUSED|SHORT_SCAN_RUNNING'; Evidence = 'RetryApproved'; Decision = $true },
        @{ Key = 'PAUSED|SHORT_RECOVERY_RUNNING'; Evidence = 'RetryApproved'; Decision = $true },
        @{ Key = 'PAUSED|LONG_SCAN_RUNNING'; Evidence = 'RetryApproved'; Decision = $true },
        @{ Key = 'PAUSED|LONG_RECOVERY_RUNNING'; Evidence = 'RetryApproved'; Decision = $true },
        @{ Key = 'PAUSED|ABORTED'; Evidence = $null; Decision = $false },
        @{ Key = 'PAUSED|FAILED_CLOSED'; Evidence = $null; Decision = $false },
        @{ Key = 'READY_FOR_HANDOFF|HANDOFF_MANUAL'; Evidence = 'RStudioLaunchVerified'; Decision = $false },
        @{ Key = 'READY_FOR_HANDOFF|INTERRUPTED_UNKNOWN'; Evidence = 'LaunchAttemptUncertain'; Decision = $false; RequiresLaunchAttempt = $true },
        @{ Key = 'READY_FOR_HANDOFF|PAUSED'; Evidence = $null; Decision = $false },
        @{ Key = 'READY_FOR_HANDOFF|FAILED_CLOSED'; Evidence = $null; Decision = $false }
    )
    foreach ($entry in $entries) {
        $requiresLaunchAttempt = $false
        if ($entry.ContainsKey('RequiresLaunchAttempt')) { $requiresLaunchAttempt = [bool]$entry.RequiresLaunchAttempt }
        $table[$entry.Key] = [pscustomobject]@{ Evidence = $entry.Evidence; Decision = $entry.Decision; RequiresLaunchAttempt = $requiresLaunchAttempt }
    }
    return $table
}

function Get-RecoveryStateMemberValue {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RecoveryStateClockResult {
    param([object]$Clock)
    if ($null -eq $Clock) {
        return [pscustomobject]@{ IsValid = $true; Instant = [datetime]::UtcNow; ReasonCode = $null }
    }
    $value = $null
    try {
        if ($Clock -is [scriptblock]) {
            $value = & $Clock @{ Operation = 'NowUtc' }
        }
        else {
            $property = $Clock.PSObject.Properties['NowUtc']
            if ($null -ne $property) {
                $candidate = $property.Value
                if ($candidate -is [scriptblock]) {
                    $value = & $candidate @{ Operation = 'NowUtc' }
                }
                else {
                    $value = $candidate
                }
            }
        }
    }
    catch {
        return [pscustomobject]@{ IsValid = $false; Instant = $null; ReasonCode = 'ClockInvalid' }
    }
    if ($null -eq $value -or $value -is [System.Array]) {
        return [pscustomobject]@{ IsValid = $false; Instant = $null; ReasonCode = 'ClockInvalid' }
    }
    if ($value -is [datetime]) {
        $instant = [datetime]$value
    }
    elseif ($value -is [datetimeoffset]) {
        $instant = $value.UtcDateTime
    }
    elseif ($value -is [string]) {
        $parsed = [datetime]::MinValue
        $text = ([string]$value).Trim()
        # An explicitly zoned string keeps its zone offset; the fallback covers the
        # zoneless local form a DateTime cast produces on the round trip through a
        # string parameter.
        $zoned = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$zoned)) {
            $parsed = $zoned.UtcDateTime
        }
        elseif (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
            return [pscustomobject]@{ IsValid = $false; Instant = $null; ReasonCode = 'ClockInvalid' }
        }
        $instant = $parsed
    }
    else {
        return [pscustomobject]@{ IsValid = $false; Instant = $null; ReasonCode = 'ClockInvalid' }
    }
    if ($instant.Kind -eq [System.DateTimeKind]::Local) { $instant = $instant.ToUniversalTime() }
    return [pscustomobject]@{ IsValid = $true; Instant = $instant; ReasonCode = $null }
}

function Get-RecoveryStateUtcInstant {
    param([object]$Clock)
    $clockResult = Get-RecoveryStateClockResult -Clock $Clock
    if (-not $clockResult.IsValid) { return $null }
    return $clockResult.Instant
}

function Format-RecoveryStateTimestamp {
    param([object]$Clock)
    $instant = Get-RecoveryStateUtcInstant -Clock $Clock
    if ($null -eq $instant) { return $null }
    return $instant.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RecoveryStateIdentityKeys {
    param([object]$Identity)
    $keys = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Identity) { return [object[]]@() }
    $identityKeys = Get-RecoveryStateMemberValue -Object $Identity -Name 'IdentityKeys'
    foreach ($key in (ConvertTo-RecoveryArray -Value $identityKeys)) {
        if ($null -eq $key) { continue }
        $text = ([string]$key).Trim()
        if ($text.Length -gt 0) { $keys.Add($text.ToUpperInvariant()) | Out-Null }
    }
    if ($keys.Count -eq 0) {
        foreach ($disk in (ConvertTo-RecoveryArray -Value (Get-RecoveryStateMemberValue -Object $Identity -Name 'PhysicalDisks'))) {
            if ($null -eq $disk) { continue }
            $key = Get-RecoveryStateMemberValue -Object $disk -Name 'IdentityKey'
            if ($null -eq $key) { continue }
            $text = ([string]$key).Trim()
            if ($text.Length -gt 0) { $keys.Add($text.ToUpperInvariant()) | Out-Null }
        }
    }
    return $keys.ToArray()
}

function Compare-RecoveryIdentitySnapshot {
    param(
        [object]$Recorded,
        [object]$Fresh
    )
    if ($null -eq $Recorded -or $null -eq $Fresh) { return 'Indeterminate' }
    if ((Get-RecoveryStateMemberValue -Object $Recorded -Name 'IsIndeterminate') -eq $true) { return 'Indeterminate' }
    if ((Get-RecoveryStateMemberValue -Object $Fresh -Name 'IsIndeterminate') -eq $true) { return 'Indeterminate' }
    $recordedKeys = @(Get-RecoveryStateIdentityKeys -Identity $Recorded)
    $freshKeys = @(Get-RecoveryStateIdentityKeys -Identity $Fresh)
    if ($recordedKeys.Count -eq 0 -or $freshKeys.Count -eq 0) { return 'Indeterminate' }
    $recordedText = (($recordedKeys | Sort-Object) -join '|')
    $freshText = (($freshKeys | Sort-Object) -join '|')
    if (-not $recordedText.Equals($freshText, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Changed' }
    # Identity keys alone do not identify a volume. Two different volumes can
    # publish the same member key, so every dimension the two snapshots can state
    # is compared: a snapshot that describes this path only through its keys must
    # never be read as the snapshot of a different volume that shares those keys.
    foreach ($name in @('VolumeGuid', 'VolumePath', 'CanonicalPath', 'Path')) {
        $verdict = Compare-RecoveryStateIdentityField -Recorded $Recorded -Fresh $Fresh -Name $name
        if ($verdict -eq 'Changed') { return 'Changed' }
    }
    $diskVerdict = Compare-RecoveryStateIdentityDisks -Recorded $Recorded -Fresh $Fresh
    if ($diskVerdict -eq 'Changed') { return 'Changed' }
    return 'Match'
}

function ConvertTo-RecoveryStateIdentityValue {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Array]) { return '' }
    return ([string]$Value).Trim()
}

function Compare-RecoveryStateIdentityField {
    # One identity dimension is a conflict only when both snapshots state it as a
    # single non-empty value and the two values disagree. A dimension one side
    # cannot state is incomplete evidence: it is never read as agreement with a
    # different value, and it is not a contradiction of the value the other side
    # states. Two snapshots that both state the same volume, path, and member key
    # are the same identity even when one of them describes fewer optional
    # fields, which is exactly the pair a resume produces.
    param(
        [object]$Recorded,
        [object]$Fresh,
        [string]$Name
    )
    $recordedValue = ConvertTo-RecoveryStateIdentityValue (Get-RecoveryStateMemberValue -Object $Recorded -Name $Name)
    $freshValue = ConvertTo-RecoveryStateIdentityValue (Get-RecoveryStateMemberValue -Object $Fresh -Name $Name)
    if ($recordedValue.Length -eq 0 -or $freshValue.Length -eq 0) { return 'Match' }
    if ($recordedValue.Equals($freshValue, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Match' }
    return 'Changed'
}

function Compare-RecoveryStateIdentityDisks {
    # The physical member set is a mandatory part of the identity when either
    # snapshot states one: the same keys with a different member count, a
    # non-Boolean or absent single-disk member state, or a member described
    # through different evidence are all conflicts.
    param(
        [object]$Recorded,
        [object]$Fresh
    )
    $recordedDisks = @(ConvertTo-RecoveryArray -Value (Get-RecoveryStateMemberValue -Object $Recorded -Name 'PhysicalDisks'))
    $freshDisks = @(ConvertTo-RecoveryArray -Value (Get-RecoveryStateMemberValue -Object $Fresh -Name 'PhysicalDisks'))
    if ($recordedDisks.Count -eq 0 -and $freshDisks.Count -eq 0) { return 'Match' }
    if ($recordedDisks.Count -eq 0 -or $freshDisks.Count -eq 0) { return 'Changed' }
    if ($recordedDisks.Count -ne $freshDisks.Count) { return 'Changed' }
    # A member number is only a conflict when both snapshots state one for that
    # member and the two numbers differ. Counts are not compared on their own: a
    # snapshot that describes its member through the identity key is incomplete,
    # not contradictory, so a single member stated without a number is compared
    # through its key and its disk evidence.
    $recordedNumbers = @(Get-RecoveryStateDiskNumbers -Disks $recordedDisks)
    $freshNumbers = @(Get-RecoveryStateDiskNumbers -Disks $freshDisks)
    if ($recordedNumbers.Count -eq $freshNumbers.Count -and $recordedNumbers.Count -gt 0) {
        $recordedNumberText = (($recordedNumbers | Sort-Object) -join '|')
        $freshNumberText = (($freshNumbers | Sort-Object) -join '|')
        if (-not $recordedNumberText.Equals($freshNumberText, [System.StringComparison]::Ordinal)) { return 'Changed' }
    }
    elseif ($recordedNumbers.Count -gt 1 -or $freshNumbers.Count -gt 1) {
        # One side states several member numbers where the other states none or
        # one: the member sets cannot be the same set described twice.
        return 'Changed'
    }
    $recordedKeys = @((Get-RecoveryStateIdentityKeys -Identity $Recorded) | Sort-Object)
    $freshKeys = @((Get-RecoveryStateIdentityKeys -Identity $Fresh) | Sort-Object)
    if ($recordedKeys.Count -ne $freshKeys.Count) { return 'Changed' }
    for ($index = 0; $index -lt $recordedKeys.Count; $index++) {
        if (-not ([string]$recordedKeys[$index]).Equals([string]$freshKeys[$index], [System.StringComparison]::OrdinalIgnoreCase)) { return 'Changed' }
    }
    foreach ($diskIndex in 0..($recordedDisks.Count - 1)) {
        $recordedDisk = $recordedDisks[$diskIndex]
        $freshDisk = $freshDisks[$diskIndex]
        if ($null -eq $recordedDisk -or $null -eq $freshDisk) { return 'Changed' }
        foreach ($name in @('IdentityKey', 'UniqueId', 'UniqueIdFormat', 'SerialNumber')) {
            $verdict = Compare-RecoveryStateIdentityField -Recorded $recordedDisk -Fresh $freshDisk -Name $name
            if ($verdict -eq 'Changed') { return 'Changed' }
        }
        foreach ($name in @('IsIndeterminate', 'DiskNumber')) {
            $recordedProperty = $recordedDisk.PSObject.Properties[$name]
            $freshProperty = $freshDisk.PSObject.Properties[$name]
            if ($null -eq $recordedProperty -and $null -eq $freshProperty) { continue }
            if ($name -eq 'IsIndeterminate') {
                # A member state that cannot be stated as one Boolean is not proof
                # of a single-disk member, so it is a conflict; a member that omits
                # the flag entirely is compared through its key like any other
                # member that states less.
                if ($null -ne $recordedProperty -and $null -ne $freshProperty) {
                    if ($recordedProperty.Value -isnot [bool] -or $freshProperty.Value -isnot [bool]) { return 'Changed' }
                    if ($recordedProperty.Value -ne $freshProperty.Value) { return 'Changed' }
                    continue
                }
                $stated = $recordedProperty
                if ($null -eq $stated) { $stated = $freshProperty }
                if ($stated.Value -isnot [bool]) { return 'Changed' }
                if ($stated.Value -eq $true) { return 'Changed' }
            }
            else {
                # DiskNumber is compared only when both snapshots state it: a
                # snapshot that identifies its member through the key alone is
                # incomplete, not contradictory, and a disagreement between two
                # stated member numbers is still a change.
                if ($null -eq $recordedProperty -or $null -eq $freshProperty) { continue }
                if ([string]$recordedProperty.Value -ne [string]$freshProperty.Value) { return 'Changed' }
            }
        }
    }
    return 'Match'
}

function Get-RecoveryStateDiskNumbers {
    # Only a member that actually states a member number contributes one. A member
    # that identifies itself through its key alone is an incomplete statement, not
    # a statement of the empty number: an empty placeholder used to make a member
    # without a number compare unequal to the same member with one, which refused
    # legitimate resume pairs.
    param([object[]]$Disks)
    $numbers = New-Object System.Collections.Generic.List[string]
    foreach ($disk in $Disks) {
        if ($null -eq $disk) { continue }
        $value = Get-RecoveryStateMemberValue -Object $disk -Name 'DiskNumber'
        if ($null -eq $value -or $value -is [bool]) { continue }
        $text = ([string]$value).Trim()
        if ($text.Length -eq 0) { continue }
        $numbers.Add($text) | Out-Null
    }
    return $numbers.ToArray()
}

function Test-RecoveryJobStateShape {
    param([object]$State)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $State) {
        $errors.Add('The state object is missing.') | Out-Null
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    $schemaVersion = Get-RecoveryStateMemberValue -Object $State -Name 'SchemaVersion'
    # A schema version the state cannot state as the number 1 is an invalid state,
    # not an exception: casting a non-numeric value threw out of the shape check.
    $schemaNumber = -1
    $schemaParsed = $false
    if ($null -ne $schemaVersion -and -not ($schemaVersion -is [bool])) {
        if ($schemaVersion -is [string]) { $schemaParsed = [int]::TryParse(([string]$schemaVersion).Trim(), [ref]$schemaNumber) }
        else {
            try { $schemaNumber = [int]$schemaVersion; $schemaParsed = $true } catch { $schemaParsed = $false }
        }
    }
    if (-not $schemaParsed -or $schemaNumber -ne 1) {
        $errors.Add('SchemaVersion must be 1.') | Out-Null
    }
    $jobId = Get-RecoveryStateMemberValue -Object $State -Name 'JobId'
    if ($null -eq $jobId -or ([string]$jobId).Trim().Length -eq 0) {
        $errors.Add('JobId is required.') | Out-Null
    }
    $workflowVersion = Get-RecoveryStateMemberValue -Object $State -Name 'WorkflowVersion'
    if ($null -eq $workflowVersion -or ([string]$workflowVersion).Trim().Length -eq 0) {
        $errors.Add('WorkflowVersion is required.') | Out-Null
    }
    $stateName = Get-RecoveryStateMemberValue -Object $State -Name 'State'
    if (-not (Test-RecoveryCanonicalState -State ([string]$stateName))) {
        $errors.Add('State is not a canonical state value.') | Out-Null
    }
    if ($null -eq (Get-RecoveryStateMemberValue -Object $State -Name 'SourceIdentity')) {
        $errors.Add('SourceIdentity is required.') | Out-Null
    }
    if ($null -eq (Get-RecoveryStateMemberValue -Object $State -Name 'DestinationIdentity')) {
        $errors.Add('DestinationIdentity is required.') | Out-Null
    }
    $paths = Get-RecoveryStateMemberValue -Object $State -Name 'Paths'
    foreach ($name in @('JobFolderPath', 'StatePath', 'LogPath')) {
        $value = Get-RecoveryStateMemberValue -Object $paths -Name $name
        if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
            $errors.Add(("Paths.{0} is required." -f $name)) | Out-Null
        }
    }
    return [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function New-RecoveryJobState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$JobId,
        [Parameter(Mandatory = $true)][object]$SourceIdentity,
        [Parameter(Mandatory = $true)][object]$DestinationIdentity,
        [Parameter(Mandatory = $true)][object]$ApplicationEvidence,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$WorkflowVersion,
        [string]$State = 'NEW',
        [object]$Clock = $null,
        [int]$SchemaVersion = 1
    )
    if ($null -eq $JobId -or ([string]$JobId).Trim().Length -eq 0) {
        throw [System.ArgumentException]::new('A job id is required.')
    }
    if ($null -eq $SourceIdentity -or $null -eq $DestinationIdentity) {
        throw [System.ArgumentException]::new('Source and destination identity snapshots are required.')
    }
    if ($null -eq $WorkflowVersion -or ([string]$WorkflowVersion).Trim().Length -eq 0) {
        throw [System.ArgumentException]::new('A workflow version is required.')
    }
    foreach ($name in @('JobFolderPath', 'StatePath', 'LogPath')) {
        $value = Get-RecoveryStateMemberValue -Object $Paths -Name $name
        if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
            throw [System.ArgumentException]::new(("The state paths must include '{0}'." -f $name))
        }
    }
    if (-not (Test-RecoveryCanonicalState -State $State)) {
        throw [System.ArgumentException]::new(("'{0}' is not a canonical recovery state." -f $State))
    }
    $timestamp = Format-RecoveryStateTimestamp -Clock $Clock
    return [pscustomobject]@{
        SchemaVersion        = $SchemaVersion
        WorkflowVersion      = ([string]$WorkflowVersion).Trim()
        JobId                = ([string]$JobId).Trim()
        CreatedUtc           = $timestamp
        UpdatedUtc           = $timestamp
        State                = $State
        Stage                = $null
        AttemptId            = $null
        AttemptStartedUtc    = $null
        SourceIdentity       = $SourceIdentity
        DestinationIdentity  = $DestinationIdentity
        ApplicationEvidence  = $ApplicationEvidence
        Paths                = $Paths
        CapacityPolicy       = $null
        Lock                 = $null
        LastEventSequence    = 0
        GateDecisions        = @()
        UnresolvedFields     = @()
    }
}

function Get-RecoveryDefaultStateWriterProvider {
    $provider = @{}
    $provider.Name = 'AtomicUtf8SnapshotWriter'
    $provider.Write = {
        param($request)
        $path = [string]$request.Path
        $directory = [System.IO.Path]::GetDirectoryName($path)
        if (-not $directory -or -not [System.IO.Directory]::Exists($directory)) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'WriteFailed'; Message = 'The snapshot directory does not exist.' }
        }
        $bytes = $request.Bytes
        if ($null -eq $bytes) {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            $bytes = $encoding.GetBytes([string]$request.Text)
        }
        $tempName = '.' + [System.IO.Path]::GetFileName($path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $tempPath = Join-Path -Path $directory -ChildPath $tempName
        try {
            $stream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            }
            finally {
                $stream.Dispose()
            }
        }
        catch {
            if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) }
            return [pscustomobject]@{ Success = $false; ReasonCode = 'WriteFailed'; Message = $_.Exception.Message }
        }
        try {
            if ([System.IO.File]::Exists($path)) {
                [System.IO.File]::Replace($tempPath, $path, [System.Management.Automation.Language.NullString]::Value)
            }
            else {
                [System.IO.File]::Move($tempPath, $path)
            }
        }
        catch {
            if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) }
            return [pscustomobject]@{ Success = $false; ReasonCode = 'WriteFailed'; Message = $_.Exception.Message }
        }
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null; BytesWritten = $bytes.Length }
    }
    return $provider
}

function Write-RecoveryJobState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path,
        [Parameter(Mandatory = $true)][object]$State,
        [object]$Writer = $null
    )
    $result = [pscustomobject]@{ Success = $false; Path = $null; BytesWritten = 0; ReasonCode = $null; Message = $null }
    if ($null -eq $Path) { $result.ReasonCode = 'SnapshotPathInvalid'; return $result }
    $pathText = ([string]$Path).Trim()
    $result.Path = $pathText
    if ($pathText.Length -eq 0) { $result.ReasonCode = 'SnapshotPathInvalid'; return $result }
    $shape = Test-RecoveryJobStateShape -State $State
    if (-not $shape.IsValid) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = (@($shape.Errors) -join ' ')
        return $result
    }
    $jobFolder = [string](Get-RecoveryStateMemberValue -Object (Get-RecoveryStateMemberValue -Object $State -Name 'Paths') -Name 'JobFolderPath')
    $jobFolderText = Get-RecoveryStateDirectoryText -Path $jobFolder
    $targetText = Get-RecoveryStateParentText -Path $pathText
    if ($jobFolderText.Length -eq 0 -or -not $jobFolderText.Equals($targetText, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.ReasonCode = 'SnapshotOutsideJobFolder'
        $result.Message = 'The snapshot path is outside the claimed job folder.'
        return $result
    }
    if ([System.IO.File]::Exists($pathText)) {
        $existingJobId = $null
        $existingReadable = $true
        try {
            $existingText = [System.IO.File]::ReadAllText($pathText, (New-Object System.Text.UTF8Encoding($false)))
            $existing = $existingText | ConvertFrom-Json -ErrorAction Stop
            $existingJobId = [string](Get-RecoveryStateMemberValue -Object $existing -Name 'JobId')
        }
        catch {
            $existingJobId = $null
            $existingReadable = $false
        }
        if ($existingReadable -and $null -eq $existingJobId) { $existingReadable = $false }
        if ($existingReadable -and $existingJobId.Trim().Length -eq 0) { $existingReadable = $false }
        if (-not $existingReadable) {
            # A snapshot that cannot be attributed to a job is preserved for
            # inspection: replacing it would destroy the only evidence of the
            # failure that produced it.
            $result.ReasonCode = 'SnapshotUnreadable'
            $result.Message = 'An existing snapshot that cannot be attributed to a job is never replaced.'
            return $result
        }
        $jobId = [string](Get-RecoveryStateMemberValue -Object $State -Name 'JobId')
        if ($existingJobId -ne $jobId) {
            $result.ReasonCode = 'SnapshotJobMismatch'
            $result.Message = 'An existing snapshot belongs to a different job and is never replaced.'
            return $result
        }
    }
    $text = $null
    try {
        $text = $State | ConvertTo-Json -Depth 12
    }
    catch {
        $result.ReasonCode = 'StateSerializeFailed'
        $result.Message = $_.Exception.Message
        return $result
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($text)
    if ($null -eq $Writer) { $Writer = Get-RecoveryDefaultStateWriterProvider }
    $call = Invoke-RecoveryStateProviderCall -Provider $Writer -Operation 'Write' -Arguments @{ Path = $pathText; Bytes = $bytes; Text = $text; State = $State }
    if (-not $call.Success) {
        if ($call.ReasonCode -eq 'ProviderRefused') { $result.ReasonCode = 'WriteFailed' } else { $result.ReasonCode = 'WriteFailed' }
        $result.Message = $call.Message
        return $result
    }
    $providerResult = $call.Data
    if ((Get-RecoveryStateMemberValue -Object $providerResult -Name 'Success') -eq $false) {
        $reason = Get-RecoveryStateMemberValue -Object $providerResult -Name 'ReasonCode'
        if ($reason) { $result.ReasonCode = [string]$reason } else { $result.ReasonCode = 'WriteFailed' }
        $result.Message = [string](Get-RecoveryStateMemberValue -Object $providerResult -Name 'Message')
        return $result
    }
    $result.Success = $true
    $result.BytesWritten = $bytes.Length
    return $result
}

function Get-RecoveryStateDirectoryText {
    param([string]$Path)
    if ($null -eq $Path) { return '' }
    $text = ([string]$Path).Trim().TrimEnd([char[]]@('\', '/'))
    return $text
}

function Get-RecoveryStateParentText {
    param([string]$Path)
    if ($null -eq $Path) { return '' }
    $parent = [System.IO.Path]::GetDirectoryName(([string]$Path).Trim())
    if (-not $parent) { return '' }
    return $parent.TrimEnd([char[]]@('\', '/'))
}

function Invoke-RecoveryStateProviderCall {
    param(
        [object]$Provider,
        [string]$Operation,
        [hashtable]$Arguments
    )
    if ($null -eq $Provider) {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderMissing'; Message = 'No writer provider was supplied.' }
    }
    $scriptBlock = $null
    if ($Provider -is [scriptblock]) {
        $scriptBlock = $Provider
    }
    else {
        $property = $null
        if ($Provider -is [System.Collections.IDictionary]) {
            if ($Provider.Contains($Operation)) { $property = $Provider[$Operation] }
        }
        else {
            $member = $Provider.PSObject.Properties[$Operation]
            if ($null -ne $member) { $property = $member.Value }
        }
        if ($null -eq $property) {
            return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationMissing'; Message = ("The writer provider does not implement operation '{0}'." -f $Operation) }
        }
        if ($property -isnot [scriptblock]) {
            return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationInvalid'; Message = ("Operation '{0}' is not a script block." -f $Operation) }
        }
        $scriptBlock = $property
    }
    $request = @{ Operation = $Operation }
    if ($null -ne $Arguments) {
        foreach ($key in $Arguments.Keys) { $request[$key] = $Arguments[$key] }
    }
    try {
        $data = & $scriptBlock $request
    }
    catch {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderFailure'; Message = $_.Exception.Message }
    }
    return [pscustomobject]@{ Success = $true; Data = $data; ReasonCode = $null; Message = $null }
}

function Get-RecoveryStateUtcNow {
    # Single clock seam for lease decisions. A supplied clock that is missing,
    # array-valued, throwing, or unparsable returns no instant; callers must
    # report ClockInvalid rather than silently replacing it with wall-clock time.
    param([object]$Clock = $null)
    return Get-RecoveryStateUtcInstant -Clock $Clock
}

function Get-RecoveryStateBindingCheck {
    # Binds a resume read or decision to its lock, claim marker, and log history:
    # the lock file must belong to this job folder and record the same job and
    # claim, and the log must end at the state's last event sequence with a last
    # event that agrees about job, state, stage, attempt, identities, and gate.
    param(
        [object]$State,
        [object]$Lock = $null,
        [bool]$RequireLock = $false,
        [switch]$LockOnly,
        [object]$Clock = $null,
        [string]$ExpectedOwner = ''
    )
    $result = [pscustomobject]@{ IsBound = $false; ReasonCode = $null; Message = $null; LastEvent = $null; LastSequence = 0; LockPath = $null; ClaimPath = $null }
    if ($null -eq $State) {
        $result.ReasonCode = 'StateInvalid'
        return $result
    }
    $paths = Get-RecoveryStateMemberValue -Object $State -Name 'Paths'
    $jobFolder = [string](Get-RecoveryStateMemberValue -Object $paths -Name 'JobFolderPath')
    $jobFolderText = Get-RecoveryStateDirectoryText -Path $jobFolder
    $logPath = [string](Get-RecoveryStateMemberValue -Object $paths -Name 'LogPath')
    $jobId = [string](Get-RecoveryStateMemberValue -Object $State -Name 'JobId')
    # The durable sequence is read defensively: a state whose sequence cannot be
    # stated as a number is invalid, not an exception inside the binding check.
    $sequenceValue = Get-RecoveryStateMemberValue -Object $State -Name 'LastEventSequence'
    $expectedSequence = -1
    $sequenceParsed = $false
    if ($null -ne $sequenceValue -and -not ($sequenceValue -is [bool])) {
        if ($sequenceValue -is [string]) { $sequenceParsed = [int]::TryParse(([string]$sequenceValue).Trim(), [ref]$expectedSequence) }
        else {
            try { $expectedSequence = [int]$sequenceValue; $sequenceParsed = $true } catch { $sequenceParsed = $false }
        }
    }
    if (-not $sequenceParsed) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = 'The state does not carry a durable event sequence.'
        return $result
    }
    if ($jobFolderText.Length -eq 0) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = 'The state does not identify its job folder.'
        return $result
    }
    if ($RequireLock) {
        if ($null -eq $Lock -or (Get-RecoveryStateMemberValue -Object $Lock -Name 'Acquired') -ne $true) {
            $result.ReasonCode = 'LockRequired'
            $result.Message = 'An exclusive job lock is required before reading resume state.'
            return $result
        }
        $lockPath = ([string](Get-RecoveryStateMemberValue -Object $Lock -Name 'LockPath')).Trim()
        if ($lockPath.Length -eq 0) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock does not record which lock file it holds.'
            return $result
        }
        $expectedLockPath = Join-Path -Path $jobFolderText -ChildPath 'job.lock'
        if (-not (Get-RecoveryStateDirectoryText -Path $lockPath).Equals((Get-RecoveryStateDirectoryText -Path $expectedLockPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock file is not the lock of this job folder.'
            return $result
        }
        if (-not [System.IO.File]::Exists($lockPath)) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The recorded lock file does not exist.'
            return $result
        }
        $lockContent = $null
        try {
            $lockContent = ([System.IO.File]::ReadAllText($lockPath, (New-Object System.Text.UTF8Encoding($false)))) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock file cannot be parsed.'
            return $result
        }
        $lockOwner = [string](Get-RecoveryStateMemberValue -Object $lockContent -Name 'Owner')
        $lockFolder = [string](Get-RecoveryStateMemberValue -Object $lockContent -Name 'JobFolderPath')
        $lockLease = Get-RecoveryStateMemberValue -Object $lockContent -Name 'LeaseExpiresUtc'
        $lockClaim = [string](Get-RecoveryStateMemberValue -Object $lockContent -Name 'ClaimId')
        $lockJobId = [string](Get-RecoveryStateMemberValue -Object $lockContent -Name 'JobId')
        if ($lockOwner.Trim().Length -eq 0) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock does not record its owner.'
            return $result
        }
        if (-not (Get-RecoveryStateDirectoryText -Path $lockFolder).Equals($jobFolderText, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock belongs to a different job folder.'
            return $result
        }
        $leaseParsed = $false
        if ($null -ne $lockLease) {
            try {
                $null = [datetime]::Parse([string]$lockLease, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                $leaseParsed = $true
            }
            catch { $leaseParsed = $false }
        }
        if (-not $leaseParsed) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock does not record a readable lease.'
            return $result
        }
        if ($jobId.Trim().Length -gt 0 -and $lockJobId.Trim().Length -gt 0 -and $lockJobId -ne $jobId) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock belongs to a different job id.'
            return $result
        }
        $claimPath = Join-Path -Path $jobFolderText -ChildPath 'job-claim.json'
        $result.ClaimPath = $claimPath
        $result.LockPath = $lockPath
        if ($lockClaim.Trim().Length -eq 0) {
            $result.ReasonCode = 'ClaimNotBound'
            $result.Message = 'The lock does not record the claim it was acquired under.'
            return $result
        }
        if (-not [System.IO.File]::Exists($claimPath)) {
            $result.ReasonCode = 'ClaimNotBound'
            $result.Message = 'The job folder claim marker is missing.'
            return $result
        }
        $claimContent = $null
        try {
            $claimContent = ([System.IO.File]::ReadAllText($claimPath, (New-Object System.Text.UTF8Encoding($false)))) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $result.ReasonCode = 'ClaimNotBound'
            $result.Message = 'The job folder claim marker cannot be parsed.'
            return $result
        }
        $claimId = [string](Get-RecoveryStateMemberValue -Object $claimContent -Name 'ClaimId')
        if ($claimId.Trim().Length -eq 0 -or -not $claimId.Equals($lockClaim, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.ReasonCode = 'ClaimNotBound'
            $result.Message = 'The lock claim does not match the job folder claim marker.'
            return $result
        }
        # A recorded lease is only meaningful when it is compared with the clock.
        # Without this the durable lock outlives its own expiry and an expired
        # worker can still read resume state.
        $leaseInstant = [datetime]::Parse([string]$lockLease, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $nowInstant = Get-RecoveryStateUtcNow -Clock $Clock
        if ($null -eq $nowInstant) {
            $result.ReasonCode = 'ClockInvalid'
            $result.Message = 'The supplied clock did not produce one readable UTC instant.'
            return $result
        }
        if ($nowInstant -ge $leaseInstant) {
            $result.ReasonCode = 'LockLeaseExpired'
            $result.Message = 'The job lock lease has expired, so this read is refused until the lock is reacquired.'
            return $result
        }
        # The durable owner is a capability, not a description: the caller must
        # present the same owner the lock file records (and the expected owner
        # when the caller knows it), so a forged or stale lock object cannot
        # authorize a resume read.
        $suppliedOwner = [string](Get-RecoveryStateMemberValue -Object $Lock -Name 'Owner')
        if ($suppliedOwner.Trim().Length -eq 0 -or -not $suppliedOwner.Trim().Equals($lockOwner.Trim(), [System.StringComparison]::Ordinal)) {
            $result.ReasonCode = 'LockOwnerMismatch'
            $result.Message = 'The presented lock owner does not match the durable lock owner.'
            return $result
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedOwner)) {
            if (-not $ExpectedOwner.Trim().Equals($lockOwner.Trim(), [System.StringComparison]::Ordinal)) {
                $result.ReasonCode = 'LockOwnerMismatch'
                $result.Message = 'The durable lock is owned by another worker.'
                return $result
            }
        }
        # The lock must state the job it was acquired for. An empty job id used
        # to be accepted as a wildcard, which let a lock from one case bind to
        # the state of another.
        if ($lockJobId.Trim().Length -eq 0) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock does not record the job id it was acquired for.'
            return $result
        }
        if ($jobId.Trim().Length -gt 0 -and -not $lockJobId.Trim().Equals($jobId.Trim(), [System.StringComparison]::Ordinal)) {
            $result.ReasonCode = 'LockNotBound'
            $result.Message = 'The lock belongs to a different job id.'
            return $result
        }
    }
    if (-not $LockOnly -and $jobId.Trim().Length -eq 0) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = 'The state does not identify its job id.'
        return $result
    }
    if (-not $LockOnly -and ($expectedSequence -gt 0 -or [System.IO.File]::Exists($logPath))) {
        $check = Get-RecoveryStateLogCheck -LogPath $logPath -JobId $jobId -ExpectedLastSequence $expectedSequence
        $result.LastSequence = $check.LastSequence
        $result.LastEvent = $check.LastEvent
        if (-not $check.Success) {
            $result.ReasonCode = $check.ReasonCode
            $result.Message = $check.Message
            return $result
        }
        if ($expectedSequence -gt 0) {
            $lastEvent = $check.LastEvent
            if ($null -eq $lastEvent) {
                $result.ReasonCode = 'LogStateMismatch'
                $result.Message = 'The log has no last event to bind the state to.'
                return $result
            }
            foreach ($pair in @(@('JobId', $jobId), @('State', [string](Get-RecoveryStateMemberValue -Object $State -Name 'State')), @('Stage', [string](Get-RecoveryStateMemberValue -Object $State -Name 'Stage')), @('AttemptId', [string](Get-RecoveryStateMemberValue -Object $State -Name 'AttemptId')))) {
                $eventValue = [string](Get-RecoveryStateMemberValue -Object $lastEvent -Name $pair[0])
                if (-not $eventValue.Equals($pair[1], [System.StringComparison]::OrdinalIgnoreCase)) {
                    $result.ReasonCode = 'LogStateMismatch'
                    $result.Message = ("The last log event disagrees with the state about '{0}'." -f $pair[0])
                    return $result
                }
            }
            foreach ($name in @('SourceIdentity', 'DestinationIdentity')) {
                $eventIdentity = Get-RecoveryStateMemberValue -Object $lastEvent -Name $name
                if ($null -eq $eventIdentity) { continue }
                $stateIdentity = Get-RecoveryStateMemberValue -Object $State -Name $name
                if ((Compare-RecoveryIdentitySnapshot -Recorded $eventIdentity -Fresh $stateIdentity) -ne 'Match') {
                    $result.ReasonCode = 'LogStateMismatch'
                    $result.Message = ("The last log event disagrees with the state about '{0}'." -f $name)
                    return $result
                }
            }
            $eventGate = Get-RecoveryStateMemberValue -Object $lastEvent -Name 'Gate'
            $gateDecisions = ConvertTo-RecoveryArray -Value (Get-RecoveryStateMemberValue -Object $State -Name 'GateDecisions')
            if ($null -ne $eventGate -and $gateDecisions.Count -gt 0) {
                $lastDecision = $gateDecisions[$gateDecisions.Count - 1]
                $eventGateId = [string](Get-RecoveryStateMemberValue -Object $eventGate -Name 'GateId')
                $decisionGateId = [string](Get-RecoveryStateMemberValue -Object $lastDecision -Name 'GateId')
                if ($eventGateId.Trim().Length -gt 0 -and $decisionGateId.Trim().Length -gt 0) {
                    if (-not $eventGateId.Equals($decisionGateId, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $result.ReasonCode = 'LogStateMismatch'
                        $result.Message = 'The last log event gate disagrees with the recorded gate decisions.'
                        return $result
                    }
                }
            }
        }
    }
    $result.IsBound = $true
    $result.ReasonCode = $null
    return $result
}

function Get-RecoveryStateLogCheck {
    param(
        [string]$LogPath,
        [string]$JobId,
        [int]$ExpectedLastSequence
    )
    $result = [pscustomobject]@{ Success = $false; ReasonCode = 'LogValidatorUnavailable'; Message = $null; LastEvent = $null; LastSequence = 0 }
    if ($null -eq $LogPath -or $LogPath.Trim().Length -eq 0) {
        $result.ReasonCode = 'LogPathMissing'
        $result.Message = 'The state does not record its event log path.'
        return $result
    }
    $check = $null
    try {
        $check = RecoveryLogging\Test-RecoveryLog -Path $LogPath -JobId $JobId -ExpectedLastSequence $ExpectedLastSequence
    }
    catch {
        $result.ReasonCode = 'LogValidatorUnavailable'
        $result.Message = $_.Exception.Message
        return $result
    }
    if ($null -eq $check) {
        $result.ReasonCode = 'LogValidatorUnavailable'
        $result.Message = 'The log validator returned no result.'
        return $result
    }
    $result.LastEvent = Get-RecoveryStateMemberValue -Object $check -Name 'LastEvent'
    $result.LastSequence = [int](Get-RecoveryStateMemberValue -Object $check -Name 'LastSequence')
    if ((Get-RecoveryStateMemberValue -Object $check -Name 'IsValid') -ne $true) {
        $result.ReasonCode = 'LogStateMismatch'
        $result.Message = ((@(Get-RecoveryStateMemberValue -Object $check -Name 'Errors') | ForEach-Object { [string]$_ }) -join ' ')
        return $result
    }
    $result.Success = $true
    $result.ReasonCode = $null
    return $result
}

function Read-RecoveryJobState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path,
        [object]$Lock = $null,
        [object]$Clock = $null,
        [string]$ExpectedOwner = ''
    )
    $result = [pscustomobject]@{ Success = $false; State = $null; ReasonCode = $null; Errors = @(); Message = $null; Binding = $null }
    if ($null -eq $Path) { $result.ReasonCode = 'StateMissing'; return $result }
    $pathText = ([string]$Path).Trim()
    if ($pathText.Length -eq 0) { $result.ReasonCode = 'StateMissing'; return $result }
    # The lock is validated against the folder that owns the requested state
    # path before the snapshot is trusted, so an acquired-but-unrelated lock is
    # never used to read resume state.
    $preliminary = [pscustomobject]@{
        JobId             = ''
        LastEventSequence = 0
        Paths             = [pscustomobject]@{ JobFolderPath = (Get-RecoveryStateParentText -Path $pathText); LogPath = '' }
    }
    $binding = Get-RecoveryStateBindingCheck -State $preliminary -Lock $Lock -RequireLock $true -LockOnly -Clock $Clock -ExpectedOwner $ExpectedOwner
    if (-not $binding.IsBound) {
        $result.ReasonCode = $binding.ReasonCode
        $result.Message = $binding.Message
        return $result
    }
    if (-not [System.IO.File]::Exists($pathText)) { $result.ReasonCode = 'StateMissing'; return $result }
    $text = $null
    try {
        $text = [System.IO.File]::ReadAllText($pathText, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        $result.ReasonCode = 'StateMalformed'
        $result.Message = $_.Exception.Message
        return $result
    }
    $state = $null
    try {
        $state = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $result.ReasonCode = 'StateMalformed'
        $result.Message = $_.Exception.Message
        return $result
    }
    $shape = Test-RecoveryJobStateShape -State $state
    if (-not $shape.IsValid) {
        $result.ReasonCode = 'StateInvalid'
        $result.Errors = @($shape.Errors)
        $result.Message = (@($shape.Errors) -join ' ')
        return $result
    }
    $binding = Get-RecoveryStateBindingCheck -State $state -Lock $Lock -RequireLock $true -Clock $Clock -ExpectedOwner $ExpectedOwner
    $result.Binding = $binding
    if (-not $binding.IsBound) {
        $result.ReasonCode = $binding.ReasonCode
        $result.Message = $binding.Message
        return $result
    }
    $result.Success = $true
    $result.State = $state
    return $result
}

function Test-RecoveryStateTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$From,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$To,
        [hashtable]$Context = $null
    )
    $result = [pscustomobject]@{
        Allowed          = $false
        ReasonCode       = $null
        RequiredEvidence = $null
        RequiresDecision = $false
        From             = $From
        To               = $To
        Message          = $null
    }
    if (-not (Test-RecoveryCanonicalState -State $From) -or -not (Test-RecoveryCanonicalState -State $To)) {
        $result.ReasonCode = 'UnknownState'
        $result.Message = 'Both the current and the next state must be canonical states.'
        return $result
    }
    $table = Get-RecoveryTransitionTable
    $key = $From + '|' + $To
    if (-not $table.ContainsKey($key)) {
        $result.ReasonCode = 'IllegalTransition'
        $result.Message = ("The transition from '{0}' to '{1}' is not allowed." -f $From, $To)
        return $result
    }
    $edge = $table[$key]
    $result.RequiredEvidence = $edge.Evidence
    $result.RequiresDecision = $edge.Decision
    $evidence = $null
    $decision = $null
    $attemptId = $null
    $launchAttemptUncertain = $null
    if ($null -ne $Context) {
        if ($Context.ContainsKey('Evidence')) { $evidence = $Context['Evidence'] }
        if ($Context.ContainsKey('OperatorDecision')) { $decision = $Context['OperatorDecision'] }
        if ($Context.ContainsKey('NewAttemptId')) { $attemptId = $Context['NewAttemptId'] }
        if ($Context.ContainsKey('LaunchAttemptUncertain')) { $launchAttemptUncertain = $Context['LaunchAttemptUncertain'] }
    }
    # A launch outcome that cannot be proven either way records a durable unknown.
    # The attempt context must be stated as the literal Boolean true: an absent,
    # string, or otherwise non-Boolean value is not evidence that a launch was
    # attempted, so this edge can never be used as a generic bypass into
    # INTERRUPTED_UNKNOWN.
    if ($edge.RequiresLaunchAttempt) {
        $stated = (($launchAttemptUncertain -is [bool]) -and ($launchAttemptUncertain -eq $true))
        if (-not $stated) {
            $result.ReasonCode = 'LaunchAttemptUncertaintyNotStated'
            $result.Message = 'This transition requires an explicit statement that a launch was attempted and its outcome is unknown.'
            return $result
        }
    }
    if ($edge.Evidence) {
        if ($null -eq $evidence -or ([string]$evidence).Trim() -ne $edge.Evidence) {
            $result.ReasonCode = 'MissingEvidence'
            $result.Message = ("This transition requires the '{0}' evidence." -f $edge.Evidence)
            return $result
        }
    }
    if ($edge.Decision) {
        if ($null -eq $decision -or ([string]$decision).Trim().Length -eq 0 -or $null -eq $attemptId -or ([string]$attemptId).Trim().Length -eq 0) {
            $result.ReasonCode = 'OperatorDecisionRequired'
            $result.Message = 'This transition requires an operator decision and a new attempt id.'
            return $result
        }
    }
    $result.Allowed = $true
    return $result
}

function Get-RecoveryEventTypeForState {
    param([string]$State)
    switch ($State) {
        'PREFLIGHT_PASSED' { return 'PreflightPassed' }
        'CASE_READY' { return 'CaseCreated' }
        'SHORT_SCAN_RUNNING' { return 'StageStarted' }
        'LONG_SCAN_RUNNING' { return 'StageStarted' }
        'SHORT_RECOVERY_RUNNING' { return 'StageStarted' }
        'LONG_RECOVERY_RUNNING' { return 'StageStarted' }
        'SHORT_SCAN_FINISHED' { return 'ScanFinished' }
        'LONG_SCAN_FINISHED' { return 'ScanFinished' }
        'SHORT_RECOVERY_FINISHED' { return 'RecoveryFinished' }
        'LONG_RECOVERY_FINISHED' { return 'RecoveryFinished' }
        'SHORT_RECOVERY_VERIFIED' { return 'StageVerified' }
        'LONG_RECOVERY_VERIFIED' { return 'StageVerified' }
        'PAUSED' { return 'StagePaused' }
        'FAILED_CLOSED' { return 'StageFailed' }
        'INTERRUPTED_UNKNOWN' { return 'StageInterruptedUnknown' }
        'ABORTED' { return 'OperatorDecision' }
        'READY_FOR_HANDOFF' { return 'GracefulCloseVerified' }
        'HANDOFF_MANUAL' { return 'RStudioLaunchOnlyHandoff' }
        default { return 'StateTransition' }
    }
}

function Set-RecoveryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$To,
        [object]$EventWriter = $null,
        [object]$StateWriter = $null,
        [hashtable]$Context = $null,
        [object]$Clock = $null
    )
    $result = [pscustomobject]@{ Success = $false; State = $State; Event = $null; ReasonCode = $null; Message = $null }
    $shape = Test-RecoveryJobStateShape -State $State
    if (-not $shape.IsValid) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = (@($shape.Errors) -join ' ')
        return $result
    }
    $from = [string](Get-RecoveryStateMemberValue -Object $State -Name 'State')
    $transition = Test-RecoveryStateTransition -From $from -To $To -Context $Context
    if (-not $transition.Allowed) {
        $result.ReasonCode = $transition.ReasonCode
        $result.Message = $transition.Message
        return $result
    }
    if ($null -eq $EventWriter) {
        $result.ReasonCode = 'EventWriterMissing'
        $result.Message = 'A boundary event writer is required before the state may advance.'
        return $result
    }
    $stage = Get-RecoveryStateMemberValue -Object $State -Name 'Stage'
    $attemptId = Get-RecoveryStateMemberValue -Object $State -Name 'AttemptId'
    $eventType = Get-RecoveryEventTypeForState -State $To
    $decision = $null
    $errorDetail = $null
    $reason = $null
    if ($null -ne $Context) {
        if ($Context.ContainsKey('Stage') -and $Context['Stage']) { $stage = $Context['Stage'] }
        if ($Context.ContainsKey('AttemptId') -and $Context['AttemptId']) { $attemptId = $Context['AttemptId'] }
        if ($Context.ContainsKey('EventType') -and $Context['EventType']) { $eventType = [string]$Context['EventType'] }
        if ($Context.ContainsKey('Decision')) { $decision = $Context['Decision'] }
        if ($Context.ContainsKey('Error')) { $errorDetail = $Context['Error'] }
        if ($Context.ContainsKey('Reason')) { $reason = $Context['Reason'] }
    }
    $sequence = ([int](Get-RecoveryStateMemberValue -Object $State -Name 'LastEventSequence')) + 1
    $jobId = [string](Get-RecoveryStateMemberValue -Object $State -Name 'JobId')
    $event = @{
        EventId             = $jobId + '-' + $sequence.ToString('000000', [System.Globalization.CultureInfo]::InvariantCulture)
        Sequence            = $sequence
        TimestampUtc        = Format-RecoveryStateTimestamp -Clock $Clock
        JobId               = $jobId
        State               = $To
        Stage               = $stage
        AttemptId           = $attemptId
        EventType           = $eventType
        Result              = 'Recorded'
        SourceIdentity      = Get-RecoveryStateMemberValue -Object $State -Name 'SourceIdentity'
        DestinationIdentity = Get-RecoveryStateMemberValue -Object $State -Name 'DestinationIdentity'
        Gate                = $null
        Error               = $errorDetail
        Decision            = $decision
        Reason              = $reason
    }
    $eventOk = $false
    $eventResult = $null
    if ($EventWriter -is [scriptblock]) {
        $value = $null
        try { $value = & $EventWriter $event } catch { $value = $null }
        if ($value -is [bool]) {
            $eventOk = [bool]$value
        }
        elseif ($null -ne $value) {
            $eventOk = ((Get-RecoveryStateMemberValue -Object $value -Name 'Success') -eq $true)
            $eventResult = $value
        }
    }
    else {
        $call = Invoke-RecoveryStateProviderCall -Provider $EventWriter -Operation 'Write' -Arguments @{ Event = $event; JobId = $jobId; Sequence = $sequence }
        if ($call.Success) { $eventResult = $call.Data }
        if ($null -ne $eventResult) { $eventOk = ((Get-RecoveryStateMemberValue -Object $eventResult -Name 'Success') -eq $true) }
    }
    if (-not $eventOk) {
        $result.ReasonCode = 'EventWriteFailed'
        $result.Message = 'The boundary event could not be written, so the state did not advance.'
        return $result
    }
    # The event log is the single source of truth for the sequence: when the
    # writer reports the sequence it durably committed, the snapshot adopts that
    # exact value instead of the value it predicted.
    if ($null -ne $eventResult) {
        $reportedSequence = Get-RecoveryStateMemberValue -Object $eventResult -Name 'Sequence'
        if ($null -ne $reportedSequence) {
            $reported = 0
            if (-not [int]::TryParse([string]$reportedSequence, [ref]$reported) -or $reported -lt $sequence) {
                $result.ReasonCode = 'EventSequenceMismatch'
                $result.Message = ("The event writer reported sequence '{0}' for an event that must follow '{1}'." -f $reportedSequence, $sequence)
                return $result
            }
            $sequence = $reported
            $event['Sequence'] = $sequence
            $event['EventId'] = $jobId + '-' + $sequence.ToString('000000', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    $updated = $State.PSObject.Copy()
    $updated.State = $To
    $updated.UpdatedUtc = Format-RecoveryStateTimestamp -Clock $Clock
    $updated.LastEventSequence = $sequence
    $updated.Stage = $stage
    $updated.AttemptId = $attemptId
    $paths = Get-RecoveryStateMemberValue -Object $updated -Name 'Paths'
    $statePath = Get-RecoveryStateMemberValue -Object $paths -Name 'StatePath'
    $write = Write-RecoveryJobState -Path $statePath -State $updated -Writer $StateWriter
    if (-not $write.Success) {
        $result.ReasonCode = 'SnapshotWriteFailed'
        $result.Message = $write.Message
        return $result
    }
    $State.State = $updated.State
    $State.UpdatedUtc = $updated.UpdatedUtc
    $State.LastEventSequence = $updated.LastEventSequence
    $State.Stage = $updated.Stage
    $State.AttemptId = $updated.AttemptId
    $result.Success = $true
    $result.Event = $event
    $result.State = $State
    return $result
}

function Get-RecoveryDefaultLockProvider {
    $provider = @{}
    $provider.Name = 'ExclusiveLockFile'
    $provider.CreateNew = {
        param($request)
        $path = [string]$request.Path
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([System.IO.File]::Exists($path)) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'AlreadyExists'; Message = 'The lock file already exists.' }
            }
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ClaimFailed'; Message = $_.Exception.Message }
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ClaimFailed'; Message = $_.Exception.Message }
        }
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            $bytes = $encoding.GetBytes([string]$request.Content)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ClaimFailed'; Message = $_.Exception.Message }
        }
        finally {
            $stream.Dispose()
        }
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
    }
    $provider.ReadAllText = {
        param($request)
        $path = [string]$request.Path
        if (-not [System.IO.File]::Exists($path)) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LockMissing'; Message = 'The lock file is missing.' }
        }
        try {
            $text = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LockUnreadable'; Message = $_.Exception.Message }
        }
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null; Text = $text }
    }
    return $provider
}

function Lock-RecoveryJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$JobPath,
        [object]$LockProvider = $null,
        [string]$Owner = 'local-technician',
        [AllowEmptyString()][string]$JobId = '',
        [object]$Clock = $null,
        [int]$LeaseMinutes = 30
    )
    $result = [pscustomobject]@{
        Acquired        = $false
        IsStale         = $false
        ReasonCode      = $null
        LockPath        = $null
        JobFolderPath   = $null
        ClaimId         = $null
        JobId           = $null
        Owner           = $Owner
        ExistingOwner   = $null
        LeaseExpiresUtc = $null
        Message         = $null
    }
    if ($null -eq $JobPath) { $result.ReasonCode = 'LockAcquireFailed'; return $result }
    $jobFolder = ([string]$JobPath).Trim()
    if ($jobFolder.Length -eq 0) { $result.ReasonCode = 'LockAcquireFailed'; return $result }
    if (-not [System.IO.Directory]::Exists($jobFolder)) {
        $result.ReasonCode = 'LockAcquireFailed'
        $result.Message = 'The job folder does not exist.'
        return $result
    }
    $result.JobFolderPath = $jobFolder
    if ($JobId -and $JobId.Trim().Length -gt 0) { $result.JobId = $JobId.Trim() }
    # The lock is only meaningful on a folder that carries the claim marker it
    # was created with: a lock without a claim binds nothing and is refused.
    $claimPath = Join-Path -Path $jobFolder -ChildPath 'job-claim.json'
    $claimId = $null
    if ([System.IO.File]::Exists($claimPath)) {
        try {
            $claimContent = ([System.IO.File]::ReadAllText($claimPath, (New-Object System.Text.UTF8Encoding($false)))) | ConvertFrom-Json -ErrorAction Stop
            $claimId = [string](Get-RecoveryStateMemberValue -Object $claimContent -Name 'ClaimId')
        }
        catch {
            $claimId = $null
        }
    }
    if ($null -eq $claimId -or $claimId.Trim().Length -eq 0) {
        $result.ReasonCode = 'ClaimMarkerMissing'
        $result.Message = 'The job folder has no readable claim marker, so it cannot be locked.'
        return $result
    }
    $result.ClaimId = $claimId
    $lockPath = Join-Path -Path $jobFolder -ChildPath 'job.lock'
    $result.LockPath = $lockPath
    $now = Get-RecoveryStateUtcInstant -Clock $Clock
    if ($null -eq $now) {
        $result.ReasonCode = 'ClockInvalid'
        $result.Message = 'The supplied clock did not produce one readable UTC instant.'
        return $result
    }
    $expires = $now.AddMinutes($LeaseMinutes)
    $result.LeaseExpiresUtc = $expires.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($null -eq $LockProvider) { $LockProvider = Get-RecoveryDefaultLockProvider }
    $content = (@{
        Owner           = $Owner
        JobId           = $result.JobId
        ClaimId         = $claimId
        AcquiredUtc     = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        LeaseExpiresUtc = $result.LeaseExpiresUtc
        JobFolderPath   = $jobFolder
    } | ConvertTo-Json -Depth 4 -Compress)
    $call = Invoke-RecoveryStateProviderCall -Provider $LockProvider -Operation 'CreateNew' -Arguments @{ Path = $lockPath; Content = $content }
    if ($call.Success) {
        $providerResult = $call.Data
        if ((Get-RecoveryStateMemberValue -Object $providerResult -Name 'Success') -eq $true -or $providerResult -is [bool]) {
            $accepted = $false
            if ($providerResult -is [bool]) { $accepted = [bool]$providerResult }
            else { $accepted = $true }
            if ($accepted) {
                $result.Acquired = $true
                return $result
            }
        }
        $reason = Get-RecoveryStateMemberValue -Object $providerResult -Name 'ReasonCode'
        if ($reason -ne 'AlreadyExists') {
            $result.ReasonCode = 'LockAcquireFailed'
            $result.Message = [string](Get-RecoveryStateMemberValue -Object $providerResult -Name 'Message')
            return $result
        }
    }
    else {
        $result.ReasonCode = 'LockAcquireFailed'
        $result.Message = $call.Message
        return $result
    }
    $existingText = $null
    $read = Invoke-RecoveryStateProviderCall -Provider $LockProvider -Operation 'ReadAllText' -Arguments @{ Path = $lockPath }
    if ($read.Success -and $null -ne $read.Data) {
        $existingText = [string](Get-RecoveryStateMemberValue -Object $read.Data -Name 'Text')
    }
    elseif ([System.IO.File]::Exists($lockPath)) {
        try { $existingText = [System.IO.File]::ReadAllText($lockPath, (New-Object System.Text.UTF8Encoding($false))) } catch { $existingText = $null }
    }
    if (-not $existingText) {
        $result.ReasonCode = 'LockUnreadable'
        $result.Message = 'A lock file exists but its lease cannot be read; the lock is not deleted automatically.'
        return $result
    }
    $existing = $null
    try { $existing = $existingText | ConvertFrom-Json -ErrorAction Stop } catch { $existing = $null }
    if ($null -eq $existing) {
        $result.ReasonCode = 'LockUnreadable'
        $result.Message = 'A lock file exists but cannot be parsed; the lock is not deleted automatically.'
        return $result
    }
    $result.ExistingOwner = [string](Get-RecoveryStateMemberValue -Object $existing -Name 'Owner')
    $existingExpiry = $null
    $expiryText = Get-RecoveryStateMemberValue -Object $existing -Name 'LeaseExpiresUtc'
    if ($expiryText) {
        try { $existingExpiry = [datetime]::Parse([string]$expiryText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $existingExpiry = $null }
    }
    if ($null -eq $existingExpiry) {
        $result.ReasonCode = 'LockUnreadable'
        $result.Message = 'The lock lease cannot be compared; the lock is not deleted automatically.'
        return $result
    }
    if ($existingExpiry -lt $now) {
        $result.IsStale = $true
        $result.ReasonCode = 'LockStale'
        $result.Message = 'The existing lock lease has expired. Removing a stale lock is an explicit operator decision.'
        return $result
    }
    $result.ReasonCode = 'LockHeld'
    $result.Message = 'Another worker holds this job lock.'
    return $result
}

function Get-RecoveryResumeDecision {
    [CmdletBinding()]
    param(
        [object]$State = $null,
        [object]$FreshSourceIdentity = $null,
        [object]$FreshDestinationIdentity = $null,
        [object]$FreshSpace = $null,
        [object]$EventWriter = $null,
        [AllowEmptyString()][string]$LogPath = ''
    )
    $result = [pscustomobject]@{ Decision = 'FailedClosed'; ReasonCode = $null; NextState = $null; Stage = $null; Message = $null }
    if ($null -eq $State) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = 'No validated state was supplied.'
        return $result
    }
    $shape = Test-RecoveryJobStateShape -State $State
    if (-not $shape.IsValid) {
        $result.ReasonCode = 'StateInvalid'
        $result.Message = (@($shape.Errors) -join ' ')
        return $result
    }
    if ($LogPath -and $LogPath.Trim().Length -gt 0) {
        # Resume requires the case evidence to bind: the log must end at the
        # recorded sequence with a last event that agrees with this snapshot.
        $statePaths = Get-RecoveryStateMemberValue -Object $State -Name 'Paths'
        $stateLogPath = Get-RecoveryStateDirectoryText -Path ([string](Get-RecoveryStateMemberValue -Object $statePaths -Name 'LogPath'))
        if (-not (Get-RecoveryStateDirectoryText -Path $LogPath).Equals($stateLogPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.ReasonCode = 'LogStateMismatch'
            $result.Message = 'The supplied log is not the log recorded in the state.'
            return $result
        }
        $binding = Get-RecoveryStateBindingCheck -State $State -RequireLock $false
        if (-not $binding.IsBound) {
            $result.ReasonCode = $binding.ReasonCode
            $result.Message = $binding.Message
            return $result
        }
    }
    $current = [string](Get-RecoveryStateMemberValue -Object $State -Name 'State')
    $result.Stage = Get-RecoveryStateMemberValue -Object $State -Name 'Stage'
    if ($current -eq 'ABORTED' -or $current -eq 'FAILED_CLOSED' -or $current -eq 'HANDOFF_MANUAL') {
        $result.ReasonCode = 'TerminalState'
        $result.Message = ("'{0}' is terminal; a new case is required." -f $current)
        return $result
    }
    $sourceComparison = Compare-RecoveryIdentitySnapshot -Recorded (Get-RecoveryStateMemberValue -Object $State -Name 'SourceIdentity') -Fresh $FreshSourceIdentity
    if ($sourceComparison -eq 'Indeterminate') {
        $result.ReasonCode = 'IdentityIndeterminate'
        $result.Message = 'The fresh source identity cannot be proven against the recorded identity.'
        return $result
    }
    if ($sourceComparison -eq 'Changed') {
        $result.ReasonCode = 'SourceIdentityChanged'
        $result.Message = 'The source identity changed since the case was recorded.'
        return $result
    }
    $destinationComparison = Compare-RecoveryIdentitySnapshot -Recorded (Get-RecoveryStateMemberValue -Object $State -Name 'DestinationIdentity') -Fresh $FreshDestinationIdentity
    if ($destinationComparison -eq 'Indeterminate') {
        $result.ReasonCode = 'IdentityIndeterminate'
        $result.Message = 'The fresh destination identity cannot be proven against the recorded identity.'
        return $result
    }
    if ($destinationComparison -eq 'Changed') {
        $result.ReasonCode = 'DestinationIdentityChanged'
        $result.Message = 'The destination identity changed since the case was recorded.'
        return $result
    }
    if ($null -eq $FreshSpace) {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'CapacityNotChecked'
        $result.Message = 'Available destination space must be rechecked before any resume.'
        return $result
    }
    if ((Get-RecoveryStateMemberValue -Object $FreshSpace -Name 'IsUnknown') -eq $true) {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'CapacityUnknown'
        $result.Message = 'The available destination space is unknown.'
        return $result
    }
    if ((Get-RecoveryStateMemberValue -Object $FreshSpace -Name 'IsSufficient') -ne $true) {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'CapacityLow'
        $result.Message = 'The destination does not hold the configured reserve.'
        return $result
    }
    if ($current -eq 'SHORT_SCAN_RUNNING' -or $current -eq 'SHORT_RECOVERY_RUNNING' -or $current -eq 'LONG_SCAN_RUNNING' -or $current -eq 'LONG_RECOVERY_RUNNING') {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'OpenAttempt'
        $result.Message = 'The latest attempt has no verified completion; it becomes INTERRUPTED_UNKNOWN and is never retried automatically.'
        if ($null -ne $EventWriter) {
            $event = @{
                EventId      = $null
                Sequence     = $null
                TimestampUtc = (Format-RecoveryStateTimestamp -Clock $null)
                JobId        = Get-RecoveryStateMemberValue -Object $State -Name 'JobId'
                State        = $current
                Stage        = $result.Stage
                AttemptId    = Get-RecoveryStateMemberValue -Object $State -Name 'AttemptId'
                EventType    = 'StageInterruptedUnknown'
                Result       = 'NeedsReview'
                Reason       = $result.ReasonCode
            }
            if ($EventWriter -is [scriptblock]) {
                try { [void](& $EventWriter $event) } catch { }
            }
        }
        return $result
    }
    if ($current -eq 'SHORT_RECOVERY_VERIFIED') {
        $result.Decision = 'ResumeNext'
        $result.NextState = 'LONG_SCAN_RUNNING'
        return $result
    }
    if ($current -eq 'LONG_RECOVERY_VERIFIED') {
        $result.Decision = 'ResumeNext'
        $result.NextState = 'READY_FOR_HANDOFF'
        return $result
    }
    if ($current -eq 'CASE_READY') {
        $result.Decision = 'ResumeNext'
        $result.NextState = 'SHORT_SCAN_RUNNING'
        return $result
    }
    if ($current -eq 'PREFLIGHT_PASSED') {
        $result.Decision = 'ResumeNext'
        $result.NextState = 'CASE_READY'
        return $result
    }
    if ($current -eq 'NEW') {
        $result.Decision = 'ResumeNext'
        $result.NextState = 'PREFLIGHT_PENDING'
        return $result
    }
    if ($current -eq 'PREFLIGHT_PENDING') {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'PreflightIncomplete'
        return $result
    }
    if ($current -eq 'PAUSED') {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'Paused'
        return $result
    }
    if ($current -eq 'INTERRUPTED_UNKNOWN') {
        $result.Decision = 'NeedsReview'
        $result.ReasonCode = 'InterruptedUnknown'
        return $result
    }
    $result.Decision = 'NeedsReview'
    $result.ReasonCode = 'UnverifiedFinish'
    $result.Message = ("'{0}' has no independently verified output yet." -f $current)
    return $result
}

Set-Alias -Name Acquire-RecoveryJobLock -Value Lock-RecoveryJob -Scope Local

Export-ModuleMember -Function @(
    'Lock-RecoveryJob',
    'Get-RecoveryResumeDecision',
    'New-RecoveryJobState',
    'Read-RecoveryJobState',
    'Set-RecoveryState',
    'Test-RecoveryStateTransition',
    'Write-RecoveryJobState'
) -Alias @(
    'Acquire-RecoveryJobLock'
)
