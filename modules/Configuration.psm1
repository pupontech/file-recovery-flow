Set-StrictMode -Version 2.0

$script:ConfigurationFields = @(
    'SchemaVersion',
    'WorkflowVersion',
    'FileScavengerPath',
    'RStudioPath',
    'ValidatedFileScavengerBuilds',
    'ValidatedRStudioBuilds',
    'DestinationRoot',
    'CapacityReserveBytes',
    'MaxJobPathLength',
    'ClientName',
    'NoPause',
    'AllowSameDiskOverride',
    'AllowVendorOverwrite',
    'AllowForceClose'
)

$script:OverrideFields = @(
    'FileScavengerPath',
    'RStudioPath',
    'DestinationRoot',
    'CapacityReserveBytes',
    'MaxJobPathLength',
    'ClientName',
    'NoPause',
    'AllowForceClose'
)

function Test-ConfigurationProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ConfigurationProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [object] $Default = $null
    )

    if (Test-ConfigurationProperty -Object $Object -Name $Name) {
        if ($Object -is [System.Collections.IDictionary]) {
            $value = $Object[$Name]
        }
        else {
            $value = $Object.PSObject.Properties[$Name].Value
        }
        return ,$value
    }

    return ,$Default
}

function Get-ConfigurationPropertyNames {
    param([object] $Object)

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            [string] $key
        }
        return
    }

    foreach ($property in $Object.PSObject.Properties) {
        [string] $property.Name
    }
}

function Test-ConfigurationObject {
    param([object] $Object)

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [string]) {
        return $false
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $true
    }

    if ($Object -is [System.Collections.IEnumerable]) {
        return $false
    }

    return ($null -ne $Object.PSObject.Properties)
}

function Test-IntegerValue {
    param([object] $Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }

    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal]) {
        return $true
    }

    if ($Value -is [double] -or $Value -is [single]) {
        if ([double]::IsNaN([double] $Value) -or [double]::IsInfinity([double] $Value)) {
            return $false
        }
        return ([math]::Floor([double] $Value) -eq [double] $Value)
    }

    return $false
}

function ConvertTo-Int64Value {
    param([object] $Value)

    if (-not (Test-IntegerValue -Value $Value)) {
        return [pscustomobject]@{ Valid = $false; Value = $null }
    }

    try {
        $converted = [convert]::ToInt64($Value)
        return [pscustomobject]@{ Valid = $true; Value = $converted }
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Value = $null }
    }
}

function Test-BooleanValue {
    param([object] $Value)

    return ($Value -is [bool])
}

function Test-RecoveryPathValue {
    param([object] $Value)

    if ($null -eq $Value -or -not ($Value -is [string])) {
        return $false
    }

    if ($Value.Length -eq 0 -or $Value.Trim().Length -eq 0) {
        return $false
    }

    if ($Value.IndexOf([char] 0) -ge 0) {
        return $false
    }

    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return $false
        }
    }

    if ($Value -match '[\*\?\[\]]') {
        return $false
    }

    if ($Value -match '^[A-Za-z]:$') {
        return $false
    }

    return $true
}

function Test-RecoveryTextValue {
    param([object] $Value)

    if ($null -eq $Value -or -not ($Value -is [string])) {
        return $false
    }

    if ($Value.Trim().Length -eq 0) {
        return $false
    }

    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return $false
        }
    }

    return $true
}

function Get-ConfigurationBuildListResult {
    param(
        [object] $Value,
        [string] $Name,
        [System.Collections.ArrayList] $Errors
    )

    if ($null -eq $Value -or $Value -is [string] -or
        -not ($Value -is [System.Collections.IEnumerable])) {
        [void] $Errors.Add(('CFG_REQUIRED_ARRAY: {0} must be an array of build identifiers.' -f $Name))
        return @()
    }

    $items = @($Value)
    $result = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        if (-not (Test-RecoveryTextValue -Value $item)) {
            [void] $Errors.Add(('CFG_INVALID_BUILD: {0} contains a non-empty string build identifier requirement.' -f $Name))
            continue
        }
        [void] $result.Add([string] $item)
    }

    return @($result.ToArray())
}

function New-ConfigurationResult {
    param(
        [bool] $Valid,
        [object] $Configuration,
        [object[]] $Errors,
        [object[]] $Warnings,
        [string] $Path
    )

    $errorCodes = New-Object System.Collections.ArrayList
    foreach ($errorRecord in @($Errors)) {
        if ($null -eq $errorRecord) {
            continue
        }
        $text = [string] $errorRecord
        $separator = $text.IndexOf(':')
        if ($separator -gt 0) {
            $code = $text.Substring(0, $separator)
            if ($errorCodes -notcontains $code) {
                [void] $errorCodes.Add($code)
            }
        }
    }

    $result = [ordered]@{
        Valid = $Valid
        Status = if ($Valid) { 'Valid' } else { 'Invalid' }
        Configuration = $Configuration
        Errors = @($Errors)
        ErrorCodes = @($errorCodes.ToArray())
        ErrorCode = if ($errorCodes.Count -gt 0) { $errorCodes[0] } else { $null }
        Warnings = @($Warnings)
        Path = $Path
    }

    if ($null -ne $Configuration) {
        foreach ($property in $Configuration.PSObject.Properties) {
            if (-not $result.Contains($property.Name)) {
                $result[$property.Name] = $property.Value
            }
        }
    }

    return [pscustomobject] $result
}

function ConvertTo-NormalizedConfiguration {
    param([object] $Object)

    $configuration = [ordered]@{
        SchemaVersion = [int] (Get-ConfigurationProperty -Object $Object -Name 'SchemaVersion')
        WorkflowVersion = [string] (Get-ConfigurationProperty -Object $Object -Name 'WorkflowVersion')
        FileScavengerPath = Get-ConfigurationProperty -Object $Object -Name 'FileScavengerPath'
        RStudioPath = Get-ConfigurationProperty -Object $Object -Name 'RStudioPath'
        ValidatedFileScavengerBuilds = @((Get-ConfigurationProperty -Object $Object -Name 'ValidatedFileScavengerBuilds'))
        ValidatedRStudioBuilds = @((Get-ConfigurationProperty -Object $Object -Name 'ValidatedRStudioBuilds'))
        DestinationRoot = Get-ConfigurationProperty -Object $Object -Name 'DestinationRoot'
        CapacityReserveBytes = [int64] (Get-ConfigurationProperty -Object $Object -Name 'CapacityReserveBytes')
        MaxJobPathLength = 200
        ClientName = Get-ConfigurationProperty -Object $Object -Name 'ClientName'
        NoPause = $false
        AllowSameDiskOverride = $false
        AllowVendorOverwrite = $false
        AllowForceClose = $false
    }

    if (Test-ConfigurationProperty -Object $Object -Name 'MaxJobPathLength') {
        $configuration.MaxJobPathLength = [int] (Get-ConfigurationProperty -Object $Object -Name 'MaxJobPathLength')
    }
    if (Test-ConfigurationProperty -Object $Object -Name 'NoPause') {
        $configuration.NoPause = [bool] (Get-ConfigurationProperty -Object $Object -Name 'NoPause')
    }
    if (Test-ConfigurationProperty -Object $Object -Name 'AllowSameDiskOverride') {
        $configuration.AllowSameDiskOverride = [bool] (Get-ConfigurationProperty -Object $Object -Name 'AllowSameDiskOverride')
    }
    if (Test-ConfigurationProperty -Object $Object -Name 'AllowVendorOverwrite') {
        $configuration.AllowVendorOverwrite = [bool] (Get-ConfigurationProperty -Object $Object -Name 'AllowVendorOverwrite')
    }
    if (Test-ConfigurationProperty -Object $Object -Name 'AllowForceClose') {
        $configuration.AllowForceClose = [bool] (Get-ConfigurationProperty -Object $Object -Name 'AllowForceClose')
    }

    return [pscustomobject] $configuration
}

function Test-RecoveryConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Configuration
    )

    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $source = $Configuration

    if ((Test-ConfigurationProperty -Object $Configuration -Name 'Configuration') -and
        (Test-ConfigurationProperty -Object $Configuration -Name 'Valid')) {
        $nested = Get-ConfigurationProperty -Object $Configuration -Name 'Configuration'
        if ($null -ne $nested) {
            $source = $nested
        }
    }

    if (-not (Test-ConfigurationObject -Object $source)) {
        [void] $errors.Add('CFG_NOT_OBJECT: Configuration must be a JSON object.')
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors $errors.ToArray() -Warnings $warnings.ToArray() -Path $null
    }

    foreach ($propertyName in @(Get-ConfigurationPropertyNames -Object $source)) {
        if ($script:ConfigurationFields -notcontains $propertyName) {
            [void] $errors.Add(('CFG_UNKNOWN_FIELD: Unknown configuration field ''{0}''.' -f $propertyName))
        }
    }

    foreach ($required in @('SchemaVersion', 'WorkflowVersion', 'ValidatedFileScavengerBuilds', 'ValidatedRStudioBuilds', 'CapacityReserveBytes')) {
        if (-not (Test-ConfigurationProperty -Object $source -Name $required)) {
            [void] $errors.Add(('CFG_REQUIRED_FIELD: {0} is required.' -f $required))
        }
        elseif ($null -eq (Get-ConfigurationProperty -Object $source -Name $required)) {
            [void] $errors.Add(('CFG_NULL_REQUIRED: {0} cannot be null.' -f $required))
        }
    }

    if (Test-ConfigurationProperty -Object $source -Name 'SchemaVersion') {
        $schema = Get-ConfigurationProperty -Object $source -Name 'SchemaVersion'
        if (-not (Test-IntegerValue -Value $schema) -or [int64] $schema -ne 1) {
            [void] $errors.Add('CFG_SCHEMA_VERSION: SchemaVersion must be the integer 1.')
        }
    }

    if (Test-ConfigurationProperty -Object $source -Name 'WorkflowVersion') {
        if (-not (Test-RecoveryTextValue -Value (Get-ConfigurationProperty -Object $source -Name 'WorkflowVersion'))) {
            [void] $errors.Add('CFG_WORKFLOW_VERSION: WorkflowVersion must be a non-empty string.')
        }
    }

    $fileBuilds = @()
    if (Test-ConfigurationProperty -Object $source -Name 'ValidatedFileScavengerBuilds') {
        $fileBuilds = @(Get-ConfigurationBuildListResult -Value (Get-ConfigurationProperty -Object $source -Name 'ValidatedFileScavengerBuilds') -Name 'ValidatedFileScavengerBuilds' -Errors $errors)
        if ($fileBuilds.Count -eq 0) {
            [void] $warnings.Add('CFG_MANUAL_FILE_SCAVENGER: No validated File Scavenger build is configured; vendor UI work remains manual-only.')
        }
    }

    $rStudioBuilds = @()
    if (Test-ConfigurationProperty -Object $source -Name 'ValidatedRStudioBuilds') {
        $rStudioBuilds = @(Get-ConfigurationBuildListResult -Value (Get-ConfigurationProperty -Object $source -Name 'ValidatedRStudioBuilds') -Name 'ValidatedRStudioBuilds' -Errors $errors)
        if ($rStudioBuilds.Count -eq 0) {
            [void] $warnings.Add('CFG_MANUAL_RSTUDIO: No validated R-Studio build is configured; launch requires a manual identity gate.')
        }
    }

    foreach ($pathName in @('FileScavengerPath', 'RStudioPath', 'DestinationRoot')) {
        if (Test-ConfigurationProperty -Object $source -Name $pathName) {
            $value = Get-ConfigurationProperty -Object $source -Name $pathName
            if ($null -ne $value -and -not (Test-RecoveryPathValue -Value $value)) {
                [void] $errors.Add(('CFG_INVALID_PATH: {0} must be a non-empty literal path without wildcard characters.' -f $pathName))
            }
        }
    }

    if (Test-ConfigurationProperty -Object $source -Name 'CapacityReserveBytes') {
        $capacity = Get-ConfigurationProperty -Object $source -Name 'CapacityReserveBytes'
        $capacityValue = ConvertTo-Int64Value -Value $capacity
        if (-not $capacityValue.Valid -or $capacityValue.Value -lt 0) {
            [void] $errors.Add('CFG_CAPACITY: CapacityReserveBytes must be a non-negative integer.')
        }
    }

    if (Test-ConfigurationProperty -Object $source -Name 'MaxJobPathLength') {
        $maxPath = Get-ConfigurationProperty -Object $source -Name 'MaxJobPathLength'
        $maxPathValue = ConvertTo-Int64Value -Value $maxPath
        if (-not $maxPathValue.Valid -or $maxPathValue.Value -lt 1 -or $maxPathValue.Value -gt [int32]::MaxValue) {
            [void] $errors.Add('CFG_PATH_LENGTH: MaxJobPathLength must be a positive 32-bit integer.')
        }
    }

    if (Test-ConfigurationProperty -Object $source -Name 'ClientName') {
        $clientName = Get-ConfigurationProperty -Object $source -Name 'ClientName'
        if ($null -ne $clientName -and -not (Test-RecoveryTextValue -Value $clientName)) {
            [void] $errors.Add('CFG_CLIENT_NAME: ClientName must be a non-empty string when provided.')
        }
    }

    foreach ($booleanName in @('NoPause', 'AllowSameDiskOverride', 'AllowVendorOverwrite', 'AllowForceClose')) {
        if (Test-ConfigurationProperty -Object $source -Name $booleanName) {
            $booleanValue = Get-ConfigurationProperty -Object $source -Name $booleanName
            if (-not (Test-BooleanValue -Value $booleanValue)) {
                [void] $errors.Add(('CFG_BOOLEAN: {0} must be a Boolean value.' -f $booleanName))
            }
        }
    }

    if ((Test-ConfigurationProperty -Object $source -Name 'AllowSameDiskOverride') -and
        [bool] (Get-ConfigurationProperty -Object $source -Name 'AllowSameDiskOverride')) {
        [void] $errors.Add('CFG_SAFETY_OVERRIDE: AllowSameDiskOverride must always be false.')
    }

    if ((Test-ConfigurationProperty -Object $source -Name 'AllowVendorOverwrite') -and
        [bool] (Get-ConfigurationProperty -Object $source -Name 'AllowVendorOverwrite')) {
        [void] $errors.Add('CFG_SAFETY_OVERRIDE: AllowVendorOverwrite must always be false.')
    }

    if ($errors.Count -gt 0) {
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors $errors.ToArray() -Warnings $warnings.ToArray() -Path $null
    }

    $normalized = ConvertTo-NormalizedConfiguration -Object $source
    return New-ConfigurationResult -Valid $true -Configuration $normalized -Errors @() -Warnings $warnings.ToArray() -Path $null
}

function Read-RecoveryConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-RecoveryPathValue -Value $Path)) {
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors @('CFG_INVALID_PATH: Configuration path must be a non-empty literal path without wildcard characters.') -Warnings @() -Path $Path
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors @('CFG_NOT_FOUND: Configuration file was not found.') -Warnings @() -Path $Path
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors @(('CFG_INVALID_JSON: Configuration JSON could not be parsed: {0}' -f $_.Exception.Message)) -Warnings @() -Path $Path
    }

    $result = Test-RecoveryConfiguration -Configuration $parsed
    if (-not $result.Valid) {
        $result.Path = $Path
        return $result
    }

    return New-ConfigurationResult -Valid $true -Configuration $result.Configuration -Errors $result.Errors -Warnings $result.Warnings -Path $Path
}

function Resolve-RecoveryConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Configuration,
        [object] $Overrides = $null
    )

    $baseResult = Test-RecoveryConfiguration -Configuration $Configuration
    if (-not $baseResult.Valid) {
        return $baseResult
    }

    $base = $baseResult.Configuration
    if ($null -eq $Overrides) {
        return New-ConfigurationResult -Valid $true -Configuration $base -Errors @() -Warnings $baseResult.Warnings -Path $null
    }

    if (-not (Test-ConfigurationObject -Object $Overrides)) {
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors @('CFG_OVERRIDE_OBJECT: Overrides must be a JSON object.') -Warnings $baseResult.Warnings -Path $null
    }

    $errors = New-Object System.Collections.ArrayList
    $resolved = [ordered]@{}
    foreach ($property in $base.PSObject.Properties) {
        $resolved[$property.Name] = $property.Value
    }

    foreach ($propertyName in @(Get-ConfigurationPropertyNames -Object $Overrides)) {
        $name = [string] $propertyName
        if ($name -eq 'AllowSameDiskOverride' -or $name -eq 'AllowVendorOverwrite') {
            [void] $errors.Add(('CFG_IMMUTABLE_OVERRIDE: {0} cannot be overridden.' -f $name))
            continue
        }
        if ($script:OverrideFields -notcontains $name) {
            [void] $errors.Add(('CFG_UNKNOWN_OVERRIDE: Override ''{0}'' is not in the allowlist.' -f $name))
            continue
        }
        $resolved[$name] = Get-ConfigurationProperty -Object $Overrides -Name $name
    }

    if ($errors.Count -gt 0) {
        return New-ConfigurationResult -Valid $false -Configuration $null -Errors $errors.ToArray() -Warnings $baseResult.Warnings -Path $null
    }

    $resolvedResult = Test-RecoveryConfiguration -Configuration ([pscustomobject] $resolved)
    if (-not $resolvedResult.Valid) {
        return $resolvedResult
    }

    return New-ConfigurationResult -Valid $true -Configuration $resolvedResult.Configuration -Errors @() -Warnings $resolvedResult.Warnings -Path $null
}

Export-ModuleMember -Function @(
    'Read-RecoveryConfiguration',
    'Resolve-RecoveryConfiguration',
    'Test-RecoveryConfiguration'
)
