# DiskDetection.psm1
#
# Physical disk identity, volume join, destination separation, folder selection,
# client name sanitization, and collision safe job folder creation.
#
# Provider seam: a provider is either a script block or an object exposing named
# script block operations. Every operation receives exactly one hashtable
# request. A throw, a missing operation, or an absent result is a failure and is
# never converted into an implicit safe value. Production providers wrap the
# Windows Storage module, the Storage namespace CIM classes, or the Win32
# association classes; unit tests pass recording fixtures.

Set-StrictMode -Off

$script:RecoveryVolumeBusTypeStorageSpaces = 16
$script:RecoveryVolumeBusTypeFileBackedVirtual = 15

function Invoke-RecoveryProviderCall {
    param(
        [object]$Provider,
        [string]$Operation,
        [hashtable]$Arguments
    )
    if ($null -eq $Provider) {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderMissing'; Message = 'No provider was supplied.' }
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
            return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationMissing'; Message = ("The provider does not implement operation '{0}'." -f $Operation) }
        }
        if ($property -isnot [scriptblock]) {
            return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationInvalid'; Message = ("Operation '{0}' is not a script block." -f $Operation) }
        }
        $scriptBlock = $property
    }
    $request = @{ Operation = $Operation }
    if ($null -ne $Arguments) {
        foreach ($key in $Arguments.Keys) {
            $request[$key] = $Arguments[$key]
        }
    }
    try {
        $data = & $scriptBlock $request
    }
    catch {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderFailure'; Message = $_.Exception.Message }
    }
    return [pscustomobject]@{ Success = $true; Data = $data; ReasonCode = $null; Message = $null }
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

function Get-RecoveryMemberValue {
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

function Get-RecoveryProviderName {
    param([object]$Provider)
    if ($null -eq $Provider) { return $null }
    if ($Provider -is [scriptblock]) { return 'ScriptBlock' }
    $name = Get-RecoveryMemberValue -Object $Provider -Name 'Name'
    if ($null -eq $name) { return 'UnnamedProvider' }
    $text = ([string]$name).Trim()
    if ($text.Length -eq 0) { return 'UnnamedProvider' }
    return $text
}

function Get-RecoveryUtcInstant {
    param([object]$Clock)
    if ($null -eq $Clock) { return [datetime]::UtcNow }
    $value = $null
    if ($Clock -is [scriptblock]) {
        try { $value = & $Clock @{ Operation = 'NowUtc' } } catch { $value = $null }
    }
    else {
        $call = Invoke-RecoveryProviderCall -Provider $Clock -Operation 'NowUtc' -Arguments @{}
        if ($call.Success) { $value = $call.Data }
    }
    if ($null -eq $value) { return [datetime]::UtcNow }
    $instant = [datetime]$value
    if ($instant.Kind -eq [System.DateTimeKind]::Local) { return $instant.ToUniversalTime() }
    return $instant
}

function Format-RecoveryUtcTimestamp {
    param(
        [object]$Clock,
        [string]$Format = 'yyyy-MM-ddTHH:mm:ss.fffZ'
    )
    $instant = Get-RecoveryUtcInstant -Clock $Clock
    return $instant.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-RecoveryIdentityText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Get-RecoveryDiskIdentityKey {
    param([object]$Disk)
    $uniqueId = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'UniqueId')
    $uniqueIdFormat = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'UniqueIdFormat')
    $serialNumber = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'SerialNumber')
    $model = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'Model')
    if ($model.Length -eq 0) {
        $model = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'FriendlyName')
    }
    $size = 0
    $sizeValue = Get-RecoveryMemberValue -Object $Disk -Name 'SizeBytes'
    if ($null -ne $sizeValue) {
        $size = [long]$sizeValue
    }
    if ($uniqueId.Length -gt 0 -and $uniqueIdFormat.Length -gt 0) {
        return ('UID|' + $uniqueIdFormat.ToUpperInvariant() + '|' + $uniqueId.ToUpperInvariant())
    }
    if ($serialNumber.Length -gt 0 -and $size -gt 0 -and $model.Length -gt 0) {
        $sizeText = $size.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        return ('SER|' + $serialNumber.ToUpperInvariant() + '|' + $sizeText + '|' + $model.ToUpperInvariant())
    }
    return ''
}

function Get-RecoveryDiskStrongFields {
    # Collects every strong identity field a disk view exposes, so that two
    # provider forms can be compared structurally instead of by one opaque key.
    param([object]$Disk)
    $fields = [pscustomobject]@{
        UniqueId       = ''
        UniqueIdFormat = ''
        SerialNumber   = ''
        Model          = ''
        SizeBytes      = 0
    }
    if ($null -eq $Disk) { return $fields }
    $fields.UniqueId = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'UniqueId')
    $fields.UniqueIdFormat = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'UniqueIdFormat')
    $fields.SerialNumber = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'SerialNumber')
    $model = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'Model')
    if ($model.Length -eq 0) {
        $model = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Disk -Name 'FriendlyName')
    }
    $fields.Model = $model
    $sizeValue = Get-RecoveryMemberValue -Object $Disk -Name 'SizeBytes'
    if ($null -ne $sizeValue) {
        try { $fields.SizeBytes = [long]$sizeValue } catch { $fields.SizeBytes = 0 }
    }
    return $fields
}

function Test-RecoveryDiskStrongForm {
    param([object]$Fields)
    if ($null -eq $Fields) { return $false }
    if ($Fields.UniqueId.Length -eq 0 -or $Fields.UniqueIdFormat.Length -eq 0) { return $false }
    return $true
}

function Test-RecoverySerialForm {
    param([object]$Fields)
    if ($null -eq $Fields) { return $false }
    if ($Fields.SerialNumber.Length -eq 0) { return $false }
    if ($Fields.SizeBytes -le 0) { return $false }
    if ($Fields.Model.Length -eq 0) { return $false }
    return $true
}

function Test-RecoveryDiskIdentityMatch {
    # Compares two physical disk views structurally: a unique id/format pair, or
    # serial plus size plus model. A contradiction, or a comparison the two
    # provider forms cannot support, is indeterminate instead of a silent
    # distinct verdict, because an indeterminate answer must block the workflow.
    param(
        [object]$Left,
        [object]$Right
    )
    if ($null -eq $Left -or $null -eq $Right) { return 'Indeterminate' }
    if ((Get-RecoveryMemberValue -Object $Left -Name 'IsIndeterminate') -eq $true) { return 'Indeterminate' }
    if ((Get-RecoveryMemberValue -Object $Right -Name 'IsIndeterminate') -eq $true) { return 'Indeterminate' }
    $leftFields = Get-RecoveryDiskStrongFields -Disk $Left
    $rightFields = Get-RecoveryDiskStrongFields -Disk $Right
    $leftUnique = Test-RecoveryDiskStrongForm -Fields $leftFields
    $rightUnique = Test-RecoveryDiskStrongForm -Fields $rightFields
    if ($leftUnique -and $rightUnique) {
        if (-not $leftFields.UniqueIdFormat.Equals($rightFields.UniqueIdFormat, [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'Indeterminate'
        }
        if (-not $leftFields.UniqueId.Equals($rightFields.UniqueId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'Distinct'
        }
        if ($leftFields.SerialNumber.Length -gt 0 -and $rightFields.SerialNumber.Length -gt 0) {
            if (-not $leftFields.SerialNumber.Equals($rightFields.SerialNumber, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Indeterminate' }
        }
        if ($leftFields.SizeBytes -gt 0 -and $rightFields.SizeBytes -gt 0 -and $leftFields.SizeBytes -ne $rightFields.SizeBytes) { return 'Indeterminate' }
        if ($leftFields.Model.Length -gt 0 -and $rightFields.Model.Length -gt 0) {
            if (-not $leftFields.Model.Equals($rightFields.Model, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Indeterminate' }
        }
        return 'Match'
    }
    $leftSerial = Test-RecoverySerialForm -Fields $leftFields
    $rightSerial = Test-RecoverySerialForm -Fields $rightFields
    if (-not $leftSerial -or -not $rightSerial) {
        # Neither a shared unique id form nor a complete serial form on both
        # sides: the two views cannot be proven to describe the same device.
        return 'Indeterminate'
    }
    if (-not $leftFields.SerialNumber.Equals($rightFields.SerialNumber, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Distinct' }
    if ($leftFields.SizeBytes -ne $rightFields.SizeBytes) { return 'Indeterminate' }
    if (-not $leftFields.Model.Equals($rightFields.Model, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Indeterminate' }
    return 'Match'
}


function Test-RecoveryPathRooted {
    param([string]$Path)
    if ($Path.Length -eq 0) { return $false }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\') { return $true }
    if ($Path -match '^[\\/]') { return $true }
    return $false
}

function Test-RecoveryPathCharacters {
    param([string]$Path)
    foreach ($character in $Path.ToCharArray()) {
        $code = [int][char]$character
        if ($code -lt 32) { return $false }
        if ($code -eq 127) { return $false }
        if ('"<>|*?'.IndexOf($character) -ge 0) { return $false }
    }
    return $true
}

function Get-RecoveryCanonicalComparable {
    param([string]$Path)
    if ($null -eq $Path) { return '' }
    $text = $Path.Trim()
    while ($text.Length -gt 1 -and ($text.EndsWith('\') -or $text.EndsWith('/'))) {
        $text = $text.Substring(0, $text.Length - 1)
    }
    return $text
}

function Resolve-RecoveryDiskProvider {
    [CmdletBinding()]
    param(
        [object[]]$Providers
    )
    $attempts = New-Object System.Collections.Generic.List[string]
    $list = ConvertTo-RecoveryArray -Value $Providers
    if ($list.Count -eq 0) {
        return [pscustomobject]@{ Provider = $null; EvidenceSource = $null; IsIndeterminate = $true; ReasonCode = 'NoProvider'; Attempts = @() }
    }
    foreach ($provider in $list) {
        $name = Get-RecoveryProviderName -Provider $provider
        $call = Invoke-RecoveryProviderCall -Provider $provider -Operation 'GetVolumes' -Arguments @{}
        if (-not $call.Success) {
            $attempts.Add(($name + ':failed')) | Out-Null
            continue
        }
        $volumes = ConvertTo-RecoveryArray -Value $call.Data
        if ($volumes.Count -eq 0) {
            $attempts.Add(($name + ':empty')) | Out-Null
            continue
        }
        $attempts.Add(($name + ':answered')) | Out-Null
        return [pscustomobject]@{ Provider = $provider; EvidenceSource = $name; IsIndeterminate = $false; ReasonCode = $null; Attempts = $attempts.ToArray() }
    }
    return [pscustomobject]@{ Provider = $null; EvidenceSource = $null; IsIndeterminate = $true; ReasonCode = 'NoProvider'; Attempts = $attempts.ToArray() }
}

function Get-PhysicalDiskIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][object]$Provider,
        [string]$EvidenceSource = $null
    )
    $source = $EvidenceSource
    if (-not $source) { $source = Get-RecoveryProviderName -Provider $Provider }
    $result = [pscustomobject]@{
        DiskNumber      = $DiskNumber
        IdentityKey     = $null
        UniqueId        = $null
        UniqueIdFormat  = $null
        SerialNumber    = $null
        Model           = $null
        FriendlyName    = $null
        Manufacturer    = $null
        SizeBytes       = $null
        BusType         = $null
        Location        = $null
        PNPDeviceID     = $null
        EvidenceSource  = $source
        IsIndeterminate = $true
        ReasonCode      = $null
    }
    $call = Invoke-RecoveryProviderCall -Provider $Provider -Operation 'GetDisks' -Arguments @{ DiskNumber = $DiskNumber }
    if (-not $call.Success) {
        $result.ReasonCode = 'ProviderFailure'
        return $result
    }
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($disk in (ConvertTo-RecoveryArray -Value $call.Data)) {
        if ($null -eq $disk) { continue }
        $number = Get-RecoveryMemberValue -Object $disk -Name 'DiskNumber'
        if ($null -eq $number) { continue }
        if ([int]$number -eq $DiskNumber) { $matches.Add($disk) | Out-Null }
    }
    if ($matches.Count -eq 0) {
        $result.ReasonCode = 'DiskNotFound'
        return $result
    }
    if ($matches.Count -gt 1) {
        $result.ReasonCode = 'AmbiguousDiskNumber'
        return $result
    }
    $disk = $matches[0]
    $result.UniqueId = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'UniqueId')
    $result.UniqueIdFormat = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'UniqueIdFormat')
    $result.SerialNumber = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'SerialNumber')
    $result.Model = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'Model')
    $result.FriendlyName = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'FriendlyName')
    $result.Manufacturer = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'Manufacturer')
    $result.Location = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'Location')
    $result.PNPDeviceID = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'PNPDeviceID')
    $sizeValue = Get-RecoveryMemberValue -Object $disk -Name 'SizeBytes'
    if ($null -ne $sizeValue) { $result.SizeBytes = [long]$sizeValue }
    $busTypeValue = Get-RecoveryMemberValue -Object $disk -Name 'BusType'
    if ($null -ne $busTypeValue) { $result.BusType = [int]$busTypeValue }

    $isDynamic = Get-RecoveryMemberValue -Object $disk -Name 'IsDynamic'
    if ($isDynamic -eq $true) {
        $result.ReasonCode = 'DynamicDiskBacking'
        return $result
    }
    if ($null -ne $result.BusType) {
        if ($result.BusType -eq $script:RecoveryVolumeBusTypeStorageSpaces -or $result.BusType -eq $script:RecoveryVolumeBusTypeFileBackedVirtual) {
            $result.ReasonCode = 'VirtualBacking'
            return $result
        }
    }
    $membersIncomplete = Get-RecoveryMemberValue -Object $disk -Name 'MembersIncomplete'
    if ($membersIncomplete -eq $true) {
        $result.ReasonCode = 'MembersIncomplete'
        return $result
    }
    $key = Get-RecoveryDiskIdentityKey -Disk $disk
    if ($key.Length -eq 0) {
        $result.ReasonCode = 'MissingStrongIdentity'
        return $result
    }
    $result.IdentityKey = $key
    $result.IsIndeterminate = $false
    $result.ReasonCode = $null
    return $result
}

function Get-RecoveryVolumeInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Provider
    )
    $source = Get-RecoveryProviderName -Provider $Provider
    $call = Invoke-RecoveryProviderCall -Provider $Provider -Operation 'GetVolumes' -Arguments @{}
    if (-not $call.Success) { return @() }
    $inventory = New-Object System.Collections.Generic.List[object]
    foreach ($volume in (ConvertTo-RecoveryArray -Value $call.Data)) {
        if ($null -eq $volume) { continue }
        $diskNumber = Get-RecoveryMemberValue -Object $volume -Name 'DiskNumber'
        $partitionNumber = Get-RecoveryMemberValue -Object $volume -Name 'PartitionNumber'
        $canonical = Get-RecoveryMemberValue -Object $volume -Name 'CanonicalPath'
        if (-not $canonical) { $canonical = Get-RecoveryMemberValue -Object $volume -Name 'Path' }
        $entry = [pscustomobject]@{
            DriveLetter        = Get-RecoveryMemberValue -Object $volume -Name 'DriveLetter'
            AccessPaths        = @(Get-RecoveryMemberValue -Object $volume -Name 'AccessPaths')
            CanonicalPath      = ConvertTo-RecoveryIdentityText $canonical
            VolumePath         = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $volume -Name 'Path')
            VolumeGuid         = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $volume -Name 'VolumeGuid')
            FileSystemLabel    = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $volume -Name 'FileSystemLabel')
            FileSystem         = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $volume -Name 'FileSystem')
            SizeBytes          = Get-RecoveryMemberValue -Object $volume -Name 'SizeBytes'
            SizeRemainingBytes = Get-RecoveryMemberValue -Object $volume -Name 'SizeRemainingBytes'
            PartitionNumber    = $partitionNumber
            DiskNumber         = $diskNumber
            PhysicalDisks      = @()
            EvidenceSource     = $source
            IsIndeterminate    = $false
            ReasonCode         = $null
        }
        if (Test-RecoveryMembershipIncomplete -Record $volume) {
            $entry.IsIndeterminate = $true
            $entry.ReasonCode = 'MembersIncomplete'
            $inventory.Add($entry) | Out-Null
            continue
        }
        $memberNumbers = @(Get-RecoveryPhysicalDiskNumbers -Record $volume)
        if ($memberNumbers.Count -eq 0) {
            $entry.IsIndeterminate = $true
            $entry.ReasonCode = 'VolumeUnresolved'
            $inventory.Add($entry) | Out-Null
            continue
        }
        $members = New-Object System.Collections.Generic.List[object]
        $membersComplete = $true
        foreach ($memberNumber in $memberNumbers) {
            $memberIdentity = Get-PhysicalDiskIdentity -DiskNumber ([int]$memberNumber) -Provider $Provider -EvidenceSource $source
            $members.Add($memberIdentity) | Out-Null
            if ($memberIdentity.IsIndeterminate) {
                $membersComplete = $false
                if ($entry.ReasonCode -eq $null) {
                    if ($memberNumbers.Count -gt 1) { $entry.ReasonCode = 'MembersIncomplete' } else { $entry.ReasonCode = $memberIdentity.ReasonCode }
                }
            }
        }
        $entry.PhysicalDisks = $members.ToArray()
        if (-not $membersComplete) {
            $entry.IsIndeterminate = $true
        }
        $inventory.Add($entry) | Out-Null
    }
    return $inventory.ToArray()
}

function Get-RecoveryPhysicalDiskNumbers {
    # Every physical member number the provider reports for one volume or path.
    # A multi-disk (spanned, striped, or Storage Spaces) volume reports more than
    # one member; the legacy single DiskNumber is still accepted.
    param([object]$Record)
    $numbers = New-Object System.Collections.Generic.List[int]
    $listed = Get-RecoveryMemberValue -Object $Record -Name 'PhysicalDiskNumbers'
    if ($null -eq $listed) { $listed = Get-RecoveryMemberValue -Object $Record -Name 'DiskNumbers' }
    foreach ($value in (ConvertTo-RecoveryArray -Value $listed)) {
        if ($null -eq $value) { continue }
        try { $number = [int]$value } catch { continue }
        if (-not $numbers.Contains($number)) { $numbers.Add($number) | Out-Null }
    }
    if ($numbers.Count -eq 0) {
        $single = Get-RecoveryMemberValue -Object $Record -Name 'DiskNumber'
        if ($null -ne $single) {
            try { $numbers.Add([int]$single) | Out-Null } catch { }
        }
    }
    return $numbers.ToArray()
}

function Test-RecoveryMembershipIncomplete {
    # Membership is only complete when the provider states it as the literal
    # Boolean false. An absent statement is not a claim, and a non Boolean
    # statement is never read as completeness: an absent field used to be read as
    # "complete", which made a record that never mentioned membership authorize a
    # destination comparison, so absence now fails closed like the sibling guards
    # for Resolved, Exists, and the reparse pair.
    param([object]$Record)
    $value = Get-RecoveryMemberValue -Object $Record -Name 'MembersIncomplete'
    if ($null -eq $value) { return $true }
    if ($value -isnot [bool]) { return $true }
    if ([bool]$value) { return $true }
    # A stated-complete record is still a subset when the topology says more
    # members exist than were actually resolved: a spanned, striped, or Storage
    # Spaces volume whose read returned only some of its disks must never be
    # compared as if the remaining disks were known to be absent.
    $declared = Get-RecoveryMemberValue -Object $Record -Name 'DeclaredMemberCount'
    if ($null -eq $declared) { return $false }
    $declaredCount = -1
    if (-not [int]::TryParse([string]$declared, [ref]$declaredCount)) { return $true }
    if ($declaredCount -lt 0) { return $true }
    if ($declaredCount -gt (@(Get-RecoveryPhysicalDiskNumbers -Record $Record)).Count) { return $true }
    return $false
}

function Test-RecoveryReparseResolved {
    # A path may be used only when the provider states that path resolution was
    # performed (ReparseResolved = $true) or that the path is not a reparse
    # point (IsReparsePoint = $false). Anything else is unresolved.
    param([object]$Record)
    $isReparse = Get-RecoveryMemberValue -Object $Record -Name 'IsReparsePoint'
    $resolved = Get-RecoveryMemberValue -Object $Record -Name 'ReparseResolved'
    if ($resolved -eq $true) { return $true }
    if ($isReparse -eq $false) { return $true }
    return $false
}

function Resolve-RecoveryPathIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path,
        [Parameter(Mandatory = $true)][object]$Provider,
        [string]$ReviewedRoot = $null
    )
    $source = Get-RecoveryProviderName -Provider $Provider
    $result = [pscustomobject]@{
        Path            = $null
        CanonicalPath   = $null
        Resolved        = $false
        Exists          = $false
        IsContainer     = $false
        VolumeGuid      = $null
        VolumePath      = $null
        DriveLetter     = $null
        PartitionNumber = $null
        DiskNumber      = $null
        PhysicalDisks   = @()
        IdentityKeys    = @()
        EvidenceSource  = $source
        IsIndeterminate = $true
        ReasonCode      = 'PathInvalid'
    }
    if ($null -eq $Path) { return $result }
    $pathText = ([string]$Path).Trim()
    $result.Path = $pathText
    if ($pathText.Length -eq 0) {
        $result.ReasonCode = 'PathInvalid'
        return $result
    }
    if (-not (Test-RecoveryPathRooted -Path $pathText)) {
        $result.ReasonCode = 'PathNotRooted'
        return $result
    }
    if (-not (Test-RecoveryPathCharacters -Path $pathText)) {
        $result.ReasonCode = 'PathInvalid'
        return $result
    }
    $call = Invoke-RecoveryProviderCall -Provider $Provider -Operation 'ResolvePath' -Arguments @{ Path = $pathText }
    if (-not $call.Success) {
        $result.ReasonCode = 'ProviderFailure'
        return $result
    }
    $record = $call.Data
    if ($null -eq $record) {
        $result.ReasonCode = 'DestinationUnresolved'
        return $result
    }
    $canonical = Get-RecoveryMemberValue -Object $record -Name 'CanonicalPath'
    if (-not $canonical) { $canonical = $pathText }
    $result.CanonicalPath = ConvertTo-RecoveryIdentityText $canonical
    $exists = Get-RecoveryMemberValue -Object $record -Name 'Exists'
    $isContainer = Get-RecoveryMemberValue -Object $record -Name 'IsContainer'
    # Existence is only evidence when the provider states it as a literal
    # Boolean. A non Boolean statement (for example the string 'false') is not
    # proof that the path exists, and reading it as one would let a path whose
    # existence was never proven pass the separation checks.
    if ($exists -is [bool]) { $result.Exists = [bool]$exists }
    if ($isContainer -is [bool]) { $result.IsContainer = [bool]$isContainer }
    if (-not $result.Exists -or -not $result.IsContainer) {
        $result.ReasonCode = 'PathMissing'
        return $result
    }
    if (-not (Test-RecoveryReparseResolved -Record $record)) {
        # An absent or non Boolean resolution statement is not proof that the
        # path target was resolved, so a junction or an unresolved path can
        # never be treated as the reviewed location.
        $result.ReasonCode = 'ReparseUnresolved'
        return $result
    }
    $result.Resolved = $true
    if (Test-RecoveryMembershipIncomplete -Record $record) {
        $result.ReasonCode = 'MembersIncomplete'
        return $result
    }
    if ($ReviewedRoot) {
        $root = Get-RecoveryCanonicalComparable -Path ([string]$ReviewedRoot)
        $canonicalComparable = Get-RecoveryCanonicalComparable -Path $result.CanonicalPath
        if ($root.Length -gt 0) {
            $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
            $inside = $canonicalComparable.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $inside) {
                $inside = $canonicalComparable.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
            }
            if (-not $inside) {
                $result.ReasonCode = 'PathOutsideReviewedRoot'
                return $result
            }
        }
    }
    $memberNumbers = @(Get-RecoveryPhysicalDiskNumbers -Record $record)
    if ($memberNumbers.Count -eq 0) {
        $result.ReasonCode = 'VolumeUnresolved'
        return $result
    }
    $result.DiskNumber = [int]$memberNumbers[0]
    $result.VolumeGuid = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $record -Name 'VolumeGuid')
    $result.VolumePath = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $record -Name 'VolumePath')
    $result.DriveLetter = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $record -Name 'DriveLetter')
    $partitionNumber = Get-RecoveryMemberValue -Object $record -Name 'PartitionNumber'
    if ($null -ne $partitionNumber) { $result.PartitionNumber = [int]$partitionNumber }

    # Resolve every physical member the provider reports. A volume that spans
    # several disks must be proven disjoint as a set: one unresolved or missing
    # member is an incomplete topology and blocks the workflow.
    $members = New-Object System.Collections.Generic.List[object]
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($memberNumber in $memberNumbers) {
        $identity = Get-PhysicalDiskIdentity -DiskNumber ([int]$memberNumber) -Provider $Provider -EvidenceSource $source
        $members.Add($identity) | Out-Null
        if ($identity.IsIndeterminate) {
            $result.PhysicalDisks = $members.ToArray()
            if ($memberNumbers.Count -gt 1) { $result.ReasonCode = 'MembersIncomplete' } else { $result.ReasonCode = $identity.ReasonCode }
            return $result
        }
        $keys.Add([string]$identity.IdentityKey) | Out-Null
    }
    $result.PhysicalDisks = $members.ToArray()
    $result.IdentityKeys = $keys.ToArray()
    $result.IsIndeterminate = $false
    $result.ReasonCode = $null
    return $result
}

function Get-RecoveryIdentityKeys {
    param([object]$Identity)
    if ($null -eq $Identity) { return [object[]]@() }
    $keys = New-Object System.Collections.Generic.List[string]
    if ($Identity -is [string]) {
        if (([string]$Identity).Trim().Length -gt 0) { $keys.Add(([string]$Identity).Trim()) | Out-Null }
        return $keys.ToArray()
    }
    $identityKeys = Get-RecoveryMemberValue -Object $Identity -Name 'IdentityKeys'
    foreach ($key in (ConvertTo-RecoveryArray -Value $identityKeys)) {
        $text = ConvertTo-RecoveryIdentityText $key
        if ($text.Length -gt 0) { $keys.Add($text) | Out-Null }
    }
    if ($keys.Count -eq 0) {
        $disks = Get-RecoveryMemberValue -Object $Identity -Name 'PhysicalDisks'
        foreach ($disk in (ConvertTo-RecoveryArray -Value $disks)) {
            if ($null -eq $disk) { continue }
            $key = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $disk -Name 'IdentityKey')
            if ($key.Length -gt 0) { $keys.Add($key) | Out-Null }
        }
    }
    return $keys.ToArray()
}

function Test-RecoveryIdentityBinding {
    # A caller supplied identity is only usable when it binds exactly to the
    # path that was just resolved: same canonical path, volume, physical member
    # set, and identity keys. Any missing or contradictory binding field is a
    # refusal, because a snapshot that does not describe this path could hide an
    # overlap with the source.
    param(
        [object]$Supplied,
        [object]$Fresh
    )
    if ($null -eq $Supplied -or $null -eq $Fresh) { return $false }
    if ($Fresh.Resolved -ne $true) { return $false }
    # A supplied snapshot that claims to be unresolved or indeterminate is
    # contradictory caller evidence and is never accepted as a binding.
    if ((Get-RecoveryMemberValue -Object $Supplied -Name 'Resolved') -ne $true) { return $false }
    if ((Get-RecoveryMemberValue -Object $Supplied -Name 'IsIndeterminate') -eq $true) { return $false }
    $suppliedPath = Get-RecoveryCanonicalComparable -Path ([string](Get-RecoveryMemberValue -Object $Supplied -Name 'CanonicalPath'))
    $freshPath = Get-RecoveryCanonicalComparable -Path ([string](Get-RecoveryMemberValue -Object $Fresh -Name 'CanonicalPath'))
    if ($suppliedPath.Length -eq 0 -or -not $suppliedPath.Equals($freshPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($name in @('VolumeGuid', 'VolumePath')) {
        $suppliedValue = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Supplied -Name $name)
        $freshValue = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $Fresh -Name $name)
        if ($freshValue.Length -eq 0) { continue }
        if (-not $suppliedValue.Equals($freshValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $suppliedNumber = Get-RecoveryMemberValue -Object $Supplied -Name 'DiskNumber'
    $freshNumber = Get-RecoveryMemberValue -Object $Fresh -Name 'DiskNumber'
    if ($null -eq $suppliedNumber -or $null -eq $freshNumber) { return $false }
    if ([int]$suppliedNumber -ne [int]$freshNumber) { return $false }
    $suppliedKeys = @(Get-RecoveryIdentityKeys -Identity $Supplied) | Sort-Object
    $freshKeys = @(Get-RecoveryIdentityKeys -Identity $Fresh) | Sort-Object
    if ($suppliedKeys.Count -eq 0 -or $freshKeys.Count -eq 0) { return $false }
    if ((-not $suppliedKeys.Count.Equals($freshKeys.Count))) { return $false }
    for ($i = 0; $i -lt $freshKeys.Count; $i++) {
        if (-not ([string]$suppliedKeys[$i]).Equals([string]$freshKeys[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Test-DestinationSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$SourceIdentity,
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$Provider,
        [object]$DestinationIdentity = $null
    )
    $decision = [pscustomobject]@{
        Allowed                 = $false
        Decision                = 'Blocked'
        ReasonCode              = 'DestinationPathInvalid'
        SourceEvidence          = $SourceIdentity
        DestinationEvidence     = $null
        DestinationBinding      = 'NotSupplied'
        SourceIdentityKeys      = @(Get-RecoveryIdentityKeys -Identity $SourceIdentity)
        DestinationIdentityKeys = @()
    }
    if ($null -eq $DestinationPath) { return $decision }
    $pathText = ([string]$DestinationPath).Trim()
    if ($pathText.Length -eq 0) { return $decision }
    if (-not (Test-RecoveryPathRooted -Path $pathText)) { return $decision }
    if (-not (Test-RecoveryPathCharacters -Path $pathText)) { return $decision }

    # The supplied identity is never trusted: the path is always resolved here,
    # and a caller supplied snapshot is only accepted when it binds exactly to
    # the fresh resolution of this path.
    $fresh = Resolve-RecoveryPathIdentity -Path $pathText -Provider $Provider
    $decision.DestinationEvidence = $fresh
    if ($null -ne $DestinationIdentity) {
        $decision | Add-Member -NotePropertyName SuppliedDestinationEvidence -NotePropertyValue $DestinationIdentity -Force
        if (-not (Test-RecoveryIdentityBinding -Supplied $DestinationIdentity -Fresh $fresh)) {
            $decision.DestinationBinding = 'Unbound'
            $decision.ReasonCode = 'DestinationIndeterminate'
            return $decision
        }
        $decision.DestinationBinding = 'Bound'
    }
    if ($fresh.Resolved -ne $true) {
        $decision.ReasonCode = 'DestinationUnresolved'
        return $decision
    }
    if ($fresh.IsIndeterminate -eq $true) {
        $decision.ReasonCode = 'DestinationIndeterminate'
        return $decision
    }
    $decision.DestinationIdentityKeys = @(Get-RecoveryIdentityKeys -Identity $fresh)
    # A source identity is only usable when it positively states that it was
    # resolved: the literal Boolean true. An absent or non Boolean statement is
    # not a claim of resolution, and treating it as one would let a source whose
    # physical identity was never proven compare against the destination.
    $sourceResolved = Get-RecoveryMemberValue -Object $SourceIdentity -Name 'Resolved'
    $sourceResolvedIsLiteral = (($sourceResolved -is [bool]) -and ($sourceResolved -eq $true))
    if ($null -eq $SourceIdentity -or (Get-RecoveryMemberValue -Object $SourceIdentity -Name 'IsIndeterminate') -eq $true -or -not $sourceResolvedIsLiteral) {
        $decision.ReasonCode = 'SourceIndeterminate'
        return $decision
    }
    $sourceKeys = @($decision.SourceIdentityKeys)
    $destinationKeys = @($decision.DestinationIdentityKeys)
    if ($sourceKeys.Count -eq 0) {
        $decision.ReasonCode = 'SourceIndeterminate'
        return $decision
    }
    if ($destinationKeys.Count -eq 0) {
        $decision.ReasonCode = 'DestinationIndeterminate'
        return $decision
    }
    $sourceVolume = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $SourceIdentity -Name 'VolumeGuid')
    $destinationVolume = ConvertTo-RecoveryIdentityText (Get-RecoveryMemberValue -Object $fresh -Name 'VolumeGuid')
    if ($sourceVolume.Length -gt 0 -and $sourceVolume.Equals($destinationVolume, [System.StringComparison]::OrdinalIgnoreCase)) {
        $decision.ReasonCode = 'SameVolume'
        return $decision
    }
    # Compare every source member against every destination member structurally:
    # a match is an overlap, and a comparison the two provider forms cannot
    # support is indeterminate and therefore blocked.
    $indeterminate = $false
    foreach ($sourceMember in (ConvertTo-RecoveryArray -Value (Get-RecoveryMemberValue -Object $SourceIdentity -Name 'PhysicalDisks'))) {
        if ($null -eq $sourceMember) { continue }
        foreach ($destinationMember in (ConvertTo-RecoveryArray -Value (Get-RecoveryMemberValue -Object $fresh -Name 'PhysicalDisks'))) {
            if ($null -eq $destinationMember) { continue }
            $verdict = Test-RecoveryDiskIdentityMatch -Left $sourceMember -Right $destinationMember
            if ($verdict -eq 'Match') {
                $decision.ReasonCode = 'SamePhysicalDisk'
                return $decision
            }
            if ($verdict -eq 'Indeterminate') { $indeterminate = $true }
        }
    }
    if ($indeterminate) {
        $decision.ReasonCode = 'DestinationIndeterminate'
        return $decision
    }
    $decision.Allowed = $true
    $decision.Decision = 'Allowed'
    $decision.ReasonCode = $null
    return $decision
}

function Get-RecoveryDestinationSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path,
        [Parameter(Mandatory = $true)][object]$Provider,
        [long]$ReserveBytes = 0
    )
    $source = Get-RecoveryProviderName -Provider $Provider
    $result = [pscustomobject]@{
        Path           = $null
        AvailableBytes = $null
        ReserveBytes   = $ReserveBytes
        IsUnknown      = $true
        IsSufficient   = $false
        EvidenceSource = $source
        ReasonCode     = 'CapacityUnknown'
    }
    if ($null -eq $Path) { return $result }
    $pathText = ([string]$Path).Trim()
    $result.Path = $pathText
    if ($pathText.Length -eq 0) { return $result }
    $call = Invoke-RecoveryProviderCall -Provider $Provider -Operation 'GetFreeSpace' -Arguments @{ Path = $pathText }
    if (-not $call.Success) { return $result }
    $record = $call.Data
    if ($null -eq $record) { return $result }
    $candidates = New-Object System.Collections.Generic.List[long]
    $volumeValue = Get-RecoveryMemberValue -Object $record -Name 'VolumeAvailableBytes'
    $userValue = Get-RecoveryMemberValue -Object $record -Name 'UserAvailableBytes'
    # A reading the provider cannot state as a size is unknown capacity, not an
    # exception: casting 'n/a' threw and the entry point reported the whole run as
    # an unhandled workflow error instead of the documented capacity refusal.
    foreach ($value in @($volumeValue, $userValue)) {
        if ($null -eq $value) { continue }
        $parsedBytes = [long]0
        $parsed = $false
        if ($value -is [bool]) { continue }
        if ($value -is [string]) {
            $parsed = [long]::TryParse(([string]$value).Trim(), [ref]$parsedBytes)
        }
        else {
            try {
                $parsedBytes = [long]$value
                $parsed = $true
            }
            catch {
                $parsed = $false
            }
        }
        if ($parsed -and $parsedBytes -ge 0) { $candidates.Add($parsedBytes) | Out-Null }
    }
    if ($candidates.Count -eq 0) {
        $result.IsUnknown = $true
        $result.IsSufficient = $false
        $result.ReasonCode = 'CapacityUnknown'
        return $result
    }
    $available = [long]::MaxValue
    foreach ($candidate in $candidates) {
        if ($candidate -lt $available) { $available = $candidate }
    }
    $result.AvailableBytes = $available
    $result.IsUnknown = $false
    if ($available -lt $ReserveBytes) {
        $result.IsSufficient = $false
        $result.ReasonCode = 'BelowReserve'
        return $result
    }
    $result.IsSufficient = $true
    $result.ReasonCode = $null
    return $result
}

function Select-DestinationFolder {
    [CmdletBinding()]
    param(
        # A null picker is not an error: the typed path is a first-class
        # documented selection method, so a caller that only wired the typed
        # provider still gets a selection attempt.
        [Parameter()][AllowNull()][object]$PickerProvider = $null,
        [object]$TypedPathProvider = $null
    )
    $result = [pscustomobject]@{ Selected = $false; Path = $null; Method = $null; ReasonCode = 'DestinationNotSelected'; Message = $null }

    $pick = Invoke-RecoveryProviderCall -Provider $PickerProvider -Operation 'Pick' -Arguments @{}
    if ($pick.Success -and $null -ne $pick.Data) {
        $selected = $null
        $path = $null
        if ($pick.Data -is [string]) {
            $path = ([string]$pick.Data).Trim()
            if ($path.Length -gt 0) { $selected = $true }
        }
        else {
            $flag = Get-RecoveryMemberValue -Object $pick.Data -Name 'Selected'
            $pathValue = Get-RecoveryMemberValue -Object $pick.Data -Name 'Path'
            if ($null -ne $pathValue) { $path = ([string]$pathValue).Trim() }
            if ($flag -eq $true -and $path -and $path.Length -gt 0) { $selected = $true }
        }
        if ($selected) {
            $result.Selected = $true
            $result.Path = $path
            $result.Method = 'Picker'
            $result.ReasonCode = $null
            return $result
        }
    }
    if ($null -eq $TypedPathProvider) { return $result }
    $typed = Invoke-RecoveryProviderCall -Provider $TypedPathProvider -Operation 'ReadPath' -Arguments @{}
    if ($typed.Success -and $null -ne $typed.Data) {
        $pathText = ''
        if ($typed.Data -is [string]) { $pathText = ([string]$typed.Data).Trim() }
        else {
            $pathValue = Get-RecoveryMemberValue -Object $typed.Data -Name 'Path'
            if ($null -ne $pathValue) { $pathText = ([string]$pathValue).Trim() }
        }
        if ($pathText.Length -gt 0) {
            $result.Selected = $true
            $result.Path = $pathText
            $result.Method = 'TypedPath'
            $result.ReasonCode = $null
            return $result
        }
    }
    return $result
}

function Test-RecoveryReservedDeviceName {
    param([string]$Name)
    $base = $Name
    $dot = $base.IndexOf('.')
    if ($dot -ge 0) { $base = $base.Substring(0, $dot) }
    return ($base -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')
}

function Convert-RecoveryName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Name,
        [int]$MaxLength = 40
    )
    if ($null -eq $Name) {
        throw [System.ArgumentException]::new('A client name is required.')
    }
    $text = ([string]$Name).TrimEnd([char[]]@(' ', '.', [char]9, [char]10, [char]13))
    if ($text.Trim().Length -eq 0) {
        throw [System.ArgumentException]::new('The client name is empty after removing trailing spaces and periods.')
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $text.ToCharArray()) {
        $code = [int][char]$character
        $allowed = $false
        if ($code -ge 48 -and $code -le 57) { $allowed = $true }
        elseif ($code -ge 65 -and $code -le 90) { $allowed = $true }
        elseif ($code -ge 97 -and $code -le 122) { $allowed = $true }
        elseif ($character -eq '_' -or $character -eq '-' -or $character -eq '.') { $allowed = $true }
        if ($allowed) { $builder.Append($character) | Out-Null }
        else { $builder.Append('_') | Out-Null }
    }
    $sanitized = $builder.ToString().TrimEnd([char[]]@('.', ' '))
    if ($sanitized.Length -eq 0) {
        throw [System.ArgumentException]::new('The client name has no usable characters.')
    }
    if (Test-RecoveryReservedDeviceName -Name $sanitized) {
        throw [System.ArgumentException]::new(("The client name '{0}' is a reserved Windows device name." -f $sanitized))
    }
    if ($sanitized.Length -gt $MaxLength) {
        Write-Warning ("The client name was truncated from {0} to {1} characters for the job folder." -f $sanitized.Length, $MaxLength)
        $sanitized = $sanitized.Substring(0, $MaxLength).TrimEnd([char[]]@('.', ' ', '_'))
        if ($sanitized.Length -eq 0) {
            throw [System.ArgumentException]::new('The client name has no usable characters after truncation.')
        }
    }
    return $sanitized
}

function Get-RecoveryDefaultClaimProvider {
    $provider = @{}
    $provider.Name = 'FileCreateNewClaim'
    $provider.CreateNew = {
        param($request)
        $path = [string]$request.Path
        $directory = [System.IO.Path]::GetDirectoryName($path)
        if ($directory -and -not [System.IO.Directory]::Exists($directory)) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'ClaimFailed'; Message = 'The claim directory does not exist.' }
        }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([System.IO.File]::Exists($path)) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'AlreadyExists'; Message = 'The claim file already exists.' }
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
    return $provider
}

function Invoke-RecoveryPreclaimSafety {
    param([scriptblock]$Check, [string]$Path, [string]$RootPath, [string]$Stage)
    # Optional for standalone folder callers; the production orchestrator supplies
    # this gate. Only one explicit Boolean approval can authorize each write.
    if ($null -eq $Check) { return [pscustomobject]@{ Allowed = $true; ReasonCode = $null; Message = $null } }
    try {
        $checks = @(& $Check ([pscustomobject]@{ Path = $Path; RootPath = $RootPath; Stage = $Stage }))
    }
    catch { return [pscustomobject]@{ Allowed = $false; ReasonCode = 'PreclaimSafetyUnproven'; Message = $_.Exception.Message } }
    $allowed = $null
    if ($checks.Count -eq 1) { $allowed = Get-RecoveryMemberValue -Object $checks[0] -Name 'Allowed' }
    if ($allowed -is [bool] -and $allowed) {
        return [pscustomobject]@{ Allowed = $true; ReasonCode = $null; Message = $null }
    }
    $reasonCode = 'PreclaimSafetyUnproven'
    if ($checks.Count -eq 1 -and $allowed -is [bool]) {
        $reason = Get-RecoveryMemberValue -Object $checks[0] -Name 'ReasonCode'
        if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { $reasonCode = [string]$reason }
    }
    return [pscustomobject]@{ Allowed = $false; ReasonCode = $reasonCode; Message = 'Fresh destination proof was refused before a case write.' }
}

function New-RecoveryJobFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$RootPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$ClientName,
        [object]$Clock = $null,
        [object]$ClaimProvider = $null,
        [int]$MaxPathLength = 200,
        [int]$MaxSuffix = 99,
        [string]$ClaimFileName = 'job-claim.json',
        [scriptblock]$PreclaimSafetyCheck = $null
    )
    $result = [pscustomobject]@{
        Created        = $false
        JobFolderPath  = $null
        FolderName     = $null
        ClientName     = $null
        CollisionIndex = $null
        ClaimPath      = $null
        ClaimId        = $null
        PathLength     = $null
        ReasonCode     = $null
        Message        = $null
    }
    if ($null -eq $RootPath) { $result.ReasonCode = 'RootPathMissing'; return $result }
    $rootText = ([string]$RootPath).Trim()
    if ($rootText.Length -eq 0) { $result.ReasonCode = 'RootPathMissing'; return $result }
    if (-not (Test-RecoveryPathRooted -Path $rootText) -or -not (Test-RecoveryPathCharacters -Path $rootText)) {
        $result.ReasonCode = 'RootPathInvalid'
        return $result
    }
    if (-not (Test-Path -LiteralPath $rootText -PathType Container)) {
        $result.ReasonCode = 'RootPathMissing'
        return $result
    }
    try {
        $sanitized = Convert-RecoveryName -Name $ClientName -MaxLength 40
    }
    catch {
        $result.ReasonCode = 'ClientNameInvalid'
        $result.Message = $_.Exception.Message
        return $result
    }
    $result.ClientName = $sanitized
    $timestamp = Format-RecoveryUtcTimestamp -Clock $Clock -Format 'yyyyMMdd-HHmmss'
    $baseName = $sanitized + '_' + $timestamp
    if ($null -eq $ClaimProvider) { $ClaimProvider = Get-RecoveryDefaultClaimProvider }
    $claimId = [guid]::NewGuid().ToString('N')
    $index = 0
    while ($index -le $MaxSuffix) {
        $folderName = $baseName
        if ($index -gt 0) { $folderName = $baseName + '-' + $index.ToString('000', [System.Globalization.CultureInfo]::InvariantCulture) }
        $folderPath = Join-Path -Path $rootText -ChildPath $folderName
        if ($folderPath.Length -gt $MaxPathLength) {
            $result.ReasonCode = 'PathBudgetExceeded'
            $result.Message = ("The composed job path is {0} characters and exceeds the {1} character budget." -f $folderPath.Length, $MaxPathLength)
            return $result
        }
        if (Test-Path -LiteralPath $folderPath -PathType Container) {
            $index = $index + 1
            continue
        }
        $preclaim = Invoke-RecoveryPreclaimSafety -Check $PreclaimSafetyCheck -Path $folderPath -RootPath $rootText -Stage 'BeforeDirectoryCreate'
        if (-not $preclaim.Allowed) {
            $result.ReasonCode = $preclaim.ReasonCode
            $result.Message = $preclaim.Message
            return $result
        }
        try {
            [void][System.IO.Directory]::CreateDirectory($folderPath)
        }
        catch {
            $result.ReasonCode = 'FolderCreateFailed'
            $result.Message = $_.Exception.Message
            return $result
        }
        # A directory that already holds anything belongs to somebody else: it is
        # never merged with, and nothing inside it is read, moved, or deleted.
        if (@([System.IO.Directory]::GetFileSystemEntries($folderPath)).Count -gt 0) {
            $index = $index + 1
            continue
        }
        $preclaim = Invoke-RecoveryPreclaimSafety -Check $PreclaimSafetyCheck -Path $folderPath -RootPath $rootText -Stage 'BeforeClaimWrite'
        if (-not $preclaim.Allowed) {
            $result.ReasonCode = $preclaim.ReasonCode
            $result.Message = $preclaim.Message
            return $result
        }
        $claimPath = Join-Path -Path $folderPath -ChildPath $ClaimFileName
        $createdUtc = Format-RecoveryUtcTimestamp -Clock $Clock
        $content = (@{
            ClaimId        = $claimId
            ClientName     = $sanitized
            FolderName     = $folderName
            CreatedUtc     = $createdUtc
            CollisionIndex = $index
        } | ConvertTo-Json -Depth 4 -Compress)
        $call = Invoke-RecoveryProviderCall -Provider $ClaimProvider -Operation 'CreateNew' -Arguments @{ Path = $claimPath; Content = $content }
        if (-not $call.Success) {
            $result.ReasonCode = 'ClaimFailed'
            $result.Message = $call.Message
            return $result
        }
        $claimOk = $false
        $claimReason = $null
        if ($call.Data -is [bool]) {
            $claimOk = [bool]$call.Data
        }
        elseif ($null -ne $call.Data) {
            if ((Get-RecoveryMemberValue -Object $call.Data -Name 'Success') -eq $true) { $claimOk = $true }
            $claimReason = Get-RecoveryMemberValue -Object $call.Data -Name 'ReasonCode'
        }
        if ($claimOk) {
            # The claim only counts when the folder now contains exactly the
            # claim marker that was just written. A second writer that populated
            # the folder makes this claim unusable, and the folder is preserved
            # for inspection instead of merged with.
            $claimEntries = New-Object System.Collections.Generic.List[string]
            foreach ($entryPath in [System.IO.Directory]::GetFileSystemEntries($folderPath)) {
                $claimEntries.Add([System.IO.Path]::GetFileName([string]$entryPath)) | Out-Null
            }
            if ($claimEntries.Count -ne 1 -or -not $claimEntries[0].Equals($ClaimFileName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $index = $index + 1
                continue
            }
            $result.Created = $true
            $result.JobFolderPath = $folderPath
            $result.FolderName = $folderName
            $result.CollisionIndex = $index
            $result.ClaimPath = $claimPath
            $result.ClaimId = $claimId
            $result.PathLength = $folderPath.Length
            $result.ReasonCode = $null
            return $result
        }
        if ($claimReason -ne 'AlreadyExists') {
            if ($claimReason) { $result.ReasonCode = [string]$claimReason } else { $result.ReasonCode = 'ClaimFailed' }
            $result.Message = ("The claim of '{0}' was refused." -f $claimPath)
            return $result
        }
        $index = $index + 1
    }
    $result.ReasonCode = 'ClaimExhausted'
    $result.Message = ("No collision free job folder was available below '{0}' after {1} attempts." -f $rootText, ($MaxSuffix + 1))
    return $result
}

Set-Alias -Name Sanitize-RecoveryName -Value Convert-RecoveryName -Scope Local

Export-ModuleMember -Function @(
    'Get-PhysicalDiskIdentity',
    'Get-RecoveryDestinationSpace',
    'Get-RecoveryVolumeInventory',
    'New-RecoveryJobFolder',
    'Resolve-RecoveryDiskProvider',
    'Resolve-RecoveryPathIdentity',
    'Convert-RecoveryName',
    'Select-DestinationFolder',
    'Test-DestinationSafety'
) -Alias @(
    'Sanitize-RecoveryName'
)
