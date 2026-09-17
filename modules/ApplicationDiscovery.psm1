Set-StrictMode -Version 2.0

$script:SupportedProducts = @('FileScavenger', 'RStudio')
$script:CandidateExecutableNames = @{
    FileScavenger = @('FileScavenger.exe', '64fsu71.exe', '64fsu61.exe', '32fsu71.exe', '32fsu61.exe')
    RStudio = @('RStudio.exe', 'RStudio9.exe')
}

function Test-RecoveryProperty {
    param(
        [object] $Object,
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

function Get-RecoveryProperty {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Default = $null
    )

    if (Test-RecoveryProperty -Object $Object -Name $Name) {
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

function Test-LiteralApplicationPath {
    param([object] $Path)

    if ($null -eq $Path -or -not ($Path -is [string])) {
        return $false
    }
    if ($Path.Length -eq 0 -or $Path.Trim().Length -eq 0) {
        return $false
    }
    if ($Path -match '[\*\?\[\]]') {
        return $false
    }
    if ($Path.Contains('"')) {
        return $false
    }
    foreach ($character in $Path.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return $false
        }
    }
    # The explicit Windows forms are checked first, and IsPathRooted runs inside a
    # guard: on Windows it throws ArgumentException ('Illegal characters in path')
    # for a path the checks above cannot enumerate, and an application identity
    # refusal must never surface as an unhandled exception.
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\[^\\]+\\') { return $true }
    try {
        if ([System.IO.Path]::IsPathRooted($Path)) { return $true }
    }
    catch {
        return $false
    }
    return $false
}

function New-ApplicationIdentityObject {
    param(
        [string] $Path,
        [object] $Info,
        [string] $EvidenceSource,
        [string] $IdentityStatus,
        [string] $ErrorMessage
    )

    $exists = Get-RecoveryProperty -Object $Info -Name 'Exists' -Default $false
    $readable = Get-RecoveryProperty -Object $Info -Name 'Readable' -Default $false
    $fileVersion = Get-RecoveryProperty -Object $Info -Name 'FileVersion'
    $productVersion = Get-RecoveryProperty -Object $Info -Name 'ProductVersion'
    $productName = Get-RecoveryProperty -Object $Info -Name 'ProductName'
    $originalFilename = Get-RecoveryProperty -Object $Info -Name 'OriginalFilename'
    $companyName = Get-RecoveryProperty -Object $Info -Name 'CompanyName'
    $publisher = Get-RecoveryProperty -Object $Info -Name 'Publisher'
    $fileDescription = Get-RecoveryProperty -Object $Info -Name 'FileDescription'
    $fileVersionInfoVerified = Get-RecoveryProperty -Object $Info -Name 'FileVersionInfoVerified'
    $ownerValidated = Get-RecoveryProperty -Object $Info -Name 'OwnerValidated'
    $ownerEvidence = Get-RecoveryProperty -Object $Info -Name 'OwnerEvidence'
    $existsVerified = ($exists -is [bool]) -and [bool]$exists
    $readableVerified = ($readable -is [bool]) -and [bool]$readable

    return [pscustomobject]@{
        Path = $Path
        Product = $null
        FileVersion = $fileVersion
        ProductVersion = $productVersion
        ProductName = $productName
        OriginalFilename = $originalFilename
        CompanyName = $companyName
        Publisher = $publisher
        FileDescription = $fileDescription
        FileVersionInfoVerified = $fileVersionInfoVerified
        OwnerValidated = $ownerValidated
        OwnerEvidence = $ownerEvidence
        Exists = $existsVerified
        Readable = $readableVerified
        EvidenceSource = $EvidenceSource
        IdentityStatus = $IdentityStatus
        Error = $ErrorMessage
    }
}

function Get-DefaultApplicationFileInfo {
    param([string] $Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [pscustomobject]@{
                Path = $Path
                Exists = $false
                Readable = $false
                Error = 'The candidate file was not found.'
            }
        }

        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
        return [pscustomobject]@{
            Path = $item.FullName
            Exists = $true
            Readable = $true
            FileVersion = $versionInfo.FileVersion
            ProductVersion = $versionInfo.ProductVersion
            ProductName = $versionInfo.ProductName
            OriginalFilename = $versionInfo.OriginalFilename
            CompanyName = $versionInfo.CompanyName
            Publisher = $versionInfo.CompanyName
            FileDescription = $versionInfo.FileDescription
            FileVersionInfoVerified = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Path = $Path
            Exists = $false
            Readable = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-RecoveryApplicationIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [scriptblock] $FileInfoProvider = $null
    )

    if (-not (Test-LiteralApplicationPath -Path $Path)) {
        return New-ApplicationIdentityObject -Path $Path -Info ([pscustomobject]@{ Exists = $false; Readable = $false }) -EvidenceSource 'InputValidation' -IdentityStatus 'InvalidPath' -ErrorMessage 'The application path is not a valid literal path.'
    }

    try {
        if ($null -ne $FileInfoProvider) {
            $info = & $FileInfoProvider $Path
            if ($null -eq $info) {
                return New-ApplicationIdentityObject -Path $Path -Info ([pscustomobject]@{ Exists = $false; Readable = $false }) -EvidenceSource 'InjectedFileInfoProvider' -IdentityStatus 'Unreadable' -ErrorMessage 'The injected file-info provider returned no identity.'
            }
            $providerExists = Get-RecoveryProperty -Object $info -Name 'Exists' -Default $false
            $providerReadable = Get-RecoveryProperty -Object $info -Name 'Readable' -Default $false
            $existsVerified = ($providerExists -is [bool]) -and [bool]$providerExists
            $readableVerified = ($providerReadable -is [bool]) -and [bool]$providerReadable
            $hasFileVersion = Test-RecoveryProperty -Object $info -Name 'FileVersion'
            $hasProductVersion = Test-RecoveryProperty -Object $info -Name 'ProductVersion'
            $fileVersionValue = Get-RecoveryProperty -Object $info -Name 'FileVersion'
            $productVersionValue = Get-RecoveryProperty -Object $info -Name 'ProductVersion'
            if (-not $existsVerified) {
                $status = 'Missing'
            }
            elseif (-not $readableVerified) {
                $status = 'Unreadable'
            }
            else {
                $status = 'Observed'
                if ((-not $hasFileVersion -or [string]::IsNullOrWhiteSpace([string] $fileVersionValue)) -and
                    (-not $hasProductVersion -or [string]::IsNullOrWhiteSpace([string] $productVersionValue))) {
                    $status = 'VersionMissing'
                }
            }
            $providerEvidenceSource = Get-RecoveryProperty -Object $info -Name 'EvidenceSource'
            if ([string]::IsNullOrWhiteSpace([string]$providerEvidenceSource)) {
                $providerEvidenceSource = 'InjectedFileInfoProvider'
            }
            return New-ApplicationIdentityObject -Path $Path -Info $info -EvidenceSource ([string]$providerEvidenceSource) -IdentityStatus $status -ErrorMessage (Get-RecoveryProperty -Object $info -Name 'Error')
        }

        $info = Get-DefaultApplicationFileInfo -Path $Path
        $exists = [bool] (Get-RecoveryProperty -Object $info -Name 'Exists' -Default $false)
        $readable = [bool] (Get-RecoveryProperty -Object $info -Name 'Readable' -Default $false)
        if (-not $exists) {
            $status = 'Missing'
        }
        elseif (-not $readable) {
            $status = 'Unreadable'
        }
        else {
            $status = 'Observed'
            $fileVersionValue = Get-RecoveryProperty -Object $info -Name 'FileVersion'
            $productVersionValue = Get-RecoveryProperty -Object $info -Name 'ProductVersion'
            if ([string]::IsNullOrWhiteSpace([string] $fileVersionValue) -and
                [string]::IsNullOrWhiteSpace([string] $productVersionValue)) {
                $status = 'VersionMissing'
            }
        }
        $evidence = 'FileVersionInfo'
        return New-ApplicationIdentityObject -Path $Path -Info $info -EvidenceSource $evidence -IdentityStatus $status -ErrorMessage (Get-RecoveryProperty -Object $info -Name 'Error')
    }
    catch {
        return New-ApplicationIdentityObject -Path $Path -Info ([pscustomobject]@{ Exists = $false; Readable = $false }) -EvidenceSource 'IdentityException' -IdentityStatus 'Unreadable' -ErrorMessage $_.Exception.Message
    }
}

function Get-ApplicationCandidateText {
    param([object] $Candidate)

    $parts = New-Object System.Collections.ArrayList
    foreach ($name in @('Path', 'ProductName', 'OriginalFilename', 'CompanyName', 'FileDescription', 'DisplayName')) {
        $value = Get-RecoveryProperty -Object $Candidate -Name $name
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string] $value)) {
            [void] $parts.Add([string] $value)
        }
    }
    return ($parts -join ' ')
}

function Test-CandidateProductIdentity {
    param(
        [object] $Candidate,
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product
    )

    $metadataParts = New-Object System.Collections.ArrayList
    foreach ($name in @('ProductName', 'OriginalFilename', 'CompanyName', 'Publisher', 'FileDescription', 'DisplayName')) {
        $value = Get-RecoveryProperty -Object $Candidate -Name $name
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string] $value)) {
            [void] $metadataParts.Add([string] $value)
        }
    }
    $metadata = ($metadataParts -join ' ').ToLowerInvariant()
    $pathText = [string] (Get-RecoveryProperty -Object $Candidate -Name 'Path')
    $leafMatch = [regex]::Match($pathText, '(?i)(?:^|[\\/])([^\\/]+)$')
    $leaf = if ($leafMatch.Success) { $leafMatch.Groups[1].Value.ToLowerInvariant() } else { $pathText.ToLowerInvariant() }

    if ($Product -eq 'RStudio') {
        if ($metadata -match 'agent' -or $metadata -match 'emergency' -or
            $leaf -match 'agent' -or $leaf -match 'emergency') {
            return 'UnsupportedUtility'
        }
        if ($leaf -match '(?i)^(?:rstudio9|rstudioemg9|rstudioagenten9|rstudioagentportableen9)\.exe$' -or
            $leaf -match '(?i)(?:installer|setup)') {
            return 'UnsupportedUtility'
        }
        if ($metadata -match 'posit') {
            return 'UnsupportedUtility'
        }
        $fileVersionValue = Get-RecoveryProperty -Object $Candidate -Name 'FileVersion'
        $fileVersion = [string] $fileVersionValue
        $evidenceSourceValue = Get-RecoveryProperty -Object $Candidate -Name 'EvidenceSource'
        $evidenceSource = [string] $evidenceSourceValue
        if ($fileVersionValue -isnot [string] -or [string]::IsNullOrWhiteSpace($fileVersion) -or
            $evidenceSourceValue -isnot [string] -or [string]::IsNullOrWhiteSpace($evidenceSource)) {
            return 'IdentityEvidenceInsufficient'
        }
        $ownerValidated = Get-RecoveryProperty -Object $Candidate -Name 'OwnerValidated'
        $ownerEvidence = Get-RecoveryProperty -Object $Candidate -Name 'OwnerEvidence'
        $fileVersionInfoVerified = Get-RecoveryProperty -Object $Candidate -Name 'FileVersionInfoVerified'
        $hasOwnerEvidence = ($ownerValidated -is [bool]) -and [bool]$ownerValidated -and
            (-not [string]::IsNullOrWhiteSpace([string] $ownerEvidence))
        $hasFileVersionInfo = ($fileVersionInfoVerified -is [bool]) -and [bool]$fileVersionInfoVerified -and
            (@($evidenceSource -split '\+') -contains 'FileVersionInfo')
        $publisherValues = New-Object System.Collections.ArrayList
        foreach ($publisherField in @('CompanyName', 'Publisher', 'PublisherName', 'Vendor')) {
            $publisherValue = Get-RecoveryProperty -Object $Candidate -Name $publisherField
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
            return 'IdentityEvidenceInsufficient'
        }
        $hasPositiveProductMetadata = $false
        foreach ($name in @('ProductName', 'OriginalFilename', 'FileDescription')) {
            $value = [string] (Get-RecoveryProperty -Object $Candidate -Name $name)
            if (-not [string]::IsNullOrWhiteSpace($value) -and
                $value -match '(?i)r[ -]?studio') {
                $hasPositiveProductMetadata = $true
                break
            }
        }
        if (-not $hasPositiveProductMetadata) {
            return 'ProductMismatch'
        }
        if ($metadata -match 'r-studio' -or $metadata -match 'rstudio' -or
            $leaf -match '^rstudio(?:[0-9]+)?\.exe$') {
            return 'Verified'
        }
        return 'ProductMismatch'
    }

    if ($metadata -match 'file scavenger' -or $metadata -match 'filescavenger' -or
        $metadata -match '64fsu' -or $metadata -match '32fsu' -or
        $leaf -match '^(?:filescavenger|64fsu|32fsu).*\.exe$') {
        return 'Verified'
    }
    return 'ProductMismatch'
}

function ConvertTo-RecoveryCandidate {
    param(
        [object] $Item,
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product,
        [string] $DefaultEvidenceSource,
        [scriptblock] $FileInfoProvider = $null
    )

    $path = $null
    if ($Item -is [string]) {
        $path = [string] $Item
    }
    else {
        $path = Get-RecoveryProperty -Object $Item -Name 'Path'
    }

    if (-not (Test-LiteralApplicationPath -Path $path)) {
        return [pscustomobject]@{
            Path = $path
            Product = $Product
            FileVersion = $null
            ProductVersion = $null
            ProductName = $null
            OriginalFilename = $null
            CompanyName = $null
            FileDescription = $null
            Exists = $false
            Readable = $false
            EvidenceSource = 'InputValidation'
            IdentityStatus = 'InvalidPath'
            Error = 'The candidate path is missing or is not a literal path.'
        }
    }

    $hasMetadata = ($null -eq $FileInfoProvider) -and ($Item -isnot [string]) -and (
        (Test-RecoveryProperty -Object $Item -Name 'FileVersion') -or
        (Test-RecoveryProperty -Object $Item -Name 'ProductVersion') -or
        (Test-RecoveryProperty -Object $Item -Name 'ProductName') -or
        (Test-RecoveryProperty -Object $Item -Name 'IdentityStatus') -or
        (Test-RecoveryProperty -Object $Item -Name 'Exists'))

    if ($hasMetadata) {
        $candidate = New-ApplicationIdentityObject -Path $path -Info $Item -EvidenceSource (Get-RecoveryProperty -Object $Item -Name 'EvidenceSource' -Default $DefaultEvidenceSource) -IdentityStatus (Get-RecoveryProperty -Object $Item -Name 'IdentityStatus' -Default 'Observed') -ErrorMessage (Get-RecoveryProperty -Object $Item -Name 'Error')
    }
    else {
        $identity = Get-RecoveryApplicationIdentity -Path $path -FileInfoProvider $FileInfoProvider
        $candidate = $identity
        $itemEvidenceSource = Get-RecoveryProperty -Object $Item -Name 'EvidenceSource'
        if ($null -ne $itemEvidenceSource -and -not [string]::IsNullOrWhiteSpace([string] $itemEvidenceSource)) {
            if ([string]$candidate.EvidenceSource -match '(?i)fileversioninfo') {
                $candidate.EvidenceSource = ([string]$candidate.EvidenceSource + '+' + [string]$itemEvidenceSource)
            }
            else {
                $candidate.EvidenceSource = [string] $itemEvidenceSource
            }
        }
        elseif ($DefaultEvidenceSource -and ($candidate.EvidenceSource -eq 'FileVersionInfo')) {
            $candidate.EvidenceSource = ([string]$candidate.EvidenceSource + '+' + [string]$DefaultEvidenceSource)
        }
    }

    $candidate.Product = $Product
    $exists = [bool] (Get-RecoveryProperty -Object $candidate -Name 'Exists' -Default $false)
    $readable = [bool] (Get-RecoveryProperty -Object $candidate -Name 'Readable' -Default $false)
    if (-not $exists) {
        $candidate.IdentityStatus = 'Missing'
    }
    elseif (-not $readable) {
        $candidate.IdentityStatus = 'Unreadable'
    }
    elseif ($candidate.IdentityStatus -ne 'UnsupportedUtility') {
        $productStatus = Test-CandidateProductIdentity -Candidate $candidate -Product $Product
        $candidate.IdentityStatus = $productStatus
    }

    return $candidate
}

function Get-CommonApplicationCandidates {
    param(
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product
    )

    $paths = New-Object System.Collections.ArrayList
    if ($env:ProgramFiles) {
        [void] $paths.Add($env:ProgramFiles)
    }
    if ($env:ProgramFiles -and $env:ProgramFiles -ne ${env:ProgramFiles(x86)}) {
        if (${env:ProgramFiles(x86)}) {
            [void] $paths.Add(${env:ProgramFiles(x86)})
        }
    }
    if ($env:ProgramW6432 -and $paths -notcontains $env:ProgramW6432) {
        [void] $paths.Add($env:ProgramW6432)
    }

    $result = New-Object System.Collections.ArrayList
    foreach ($root in $paths) {
        $folders = @()
        if ($Product -eq 'FileScavenger') {
            $folders = @('File Scavenger', 'FileScavenger', 'QueTek\File Scavenger')
        }
        else {
            $folders = @('R-Studio', 'R-Tools\R-Studio')
        }
        foreach ($folder in $folders) {
            $folderPath = Join-Path $root $folder
            foreach ($name in $script:CandidateExecutableNames[$Product]) {
                [void] $result.Add([pscustomobject]@{
                    Path = Join-Path $folderPath $name
                    EvidenceSource = 'CommonInstallLocation'
                })
            }
        }
    }
    return @($result.ToArray())
}

function ConvertTo-RegistryExecutablePath {
    param(
        [object] $Value,
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product
    )

    if ($null -eq $Value) {
        return @()
    }
    $text = [string] $Value
    if ($text.Trim().Length -eq 0) {
        return @()
    }

    $matches = New-Object System.Collections.ArrayList
    $displayMatch = [regex]::Match($text, '^\s*"?([^",]+\.exe)"?(?:,\s*\d+)?\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($displayMatch.Success) {
        [void] $matches.Add($displayMatch.Groups[1].Value)
    }
    elseif ($text -match '(?i)\.exe$') {
        [void] $matches.Add($text.Trim().Trim('"'))
    }
    else {
        foreach ($name in $script:CandidateExecutableNames[$Product]) {
            [void] $matches.Add((Join-Path $text $name))
        }
    }
    return @($matches.ToArray())
}

function Get-RegistryApplicationCandidates {
    param(
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product
    )

    $result = New-Object System.Collections.ArrayList
    if ($env:OS -ne 'Windows_NT') {
        return @()
    }

    $uninstallRoots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        try {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }
            foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
                try {
                    $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                    $displayName = [string] (Get-RecoveryProperty -Object $properties -Name 'DisplayName')
                    $displayIcon = Get-RecoveryProperty -Object $properties -Name 'DisplayIcon'
                    $installLocation = Get-RecoveryProperty -Object $properties -Name 'InstallLocation'
                    $identityText = (($displayName + ' ' + $key.PSChildName).ToLowerInvariant())
                    $matchesProduct = $false
                    if ($Product -eq 'RStudio') {
                        $matchesProduct = ($identityText -match 'r-studio' -or $identityText -match 'rstudio') -and
                            $identityText -notmatch 'agent' -and $identityText -notmatch 'emergency'
                    }
                    else {
                        $matchesProduct = ($identityText -match 'file scavenger' -or $identityText -match 'quetek')
                    }
                    if (-not $matchesProduct) {
                        continue
                    }
                    foreach ($candidatePath in @(ConvertTo-RegistryExecutablePath -Value $displayIcon -Product $Product)) {
                        [void] $result.Add([pscustomobject]@{ Path = $candidatePath; EvidenceSource = 'Registry:Uninstall' })
                    }
                    foreach ($candidatePath in @(ConvertTo-RegistryExecutablePath -Value $installLocation -Product $Product)) {
                        [void] $result.Add([pscustomobject]@{ Path = $candidatePath; EvidenceSource = 'Registry:Uninstall' })
                    }
                }
                catch {
                    continue
                }
            }
        }
        catch {
            continue
        }
    }

    $appPathRoots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    )
    foreach ($root in $appPathRoots) {
        try {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }
            foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
                $keyName = [string] $key.PSChildName
                $isExpectedName = $false
                foreach ($name in $script:CandidateExecutableNames[$Product]) {
                    if ($keyName -ieq $name) {
                        $isExpectedName = $true
                        break
                    }
                }
                if (-not $isExpectedName) {
                    continue
                }
                try {
                    $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                    $defaultValue = Get-RecoveryProperty -Object $properties -Name '(default)'
                    if ($null -eq $defaultValue) {
                        $defaultValue = Get-RecoveryProperty -Object $properties -Name $keyName
                    }
                    foreach ($candidatePath in @(ConvertTo-RegistryExecutablePath -Value $defaultValue -Product $Product)) {
                        [void] $result.Add([pscustomobject]@{ Path = $candidatePath; EvidenceSource = 'Registry:AppPaths' })
                    }
                }
                catch {
                    continue
                }
            }
        }
        catch {
            continue
        }
    }

    return @($result.ToArray())
}

function Find-RecoveryApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product,
        [string] $ExplicitPath = $null,
        [scriptblock] $CandidateProvider = $null,
        [scriptblock] $FileInfoProvider = $null
    )

    $rawCandidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($ExplicitPath)) {
        [void] $rawCandidates.Add([pscustomobject]@{ Path = $ExplicitPath; EvidenceSource = 'ExplicitPath' })
    }

    if ($null -ne $CandidateProvider) {
        try {
            foreach ($candidate in @(& $CandidateProvider $Product)) {
                if ($null -ne $candidate) {
                    [void] $rawCandidates.Add($candidate)
                }
            }
        }
        catch {
            [void] $rawCandidates.Add([pscustomobject]@{ Path = $ExplicitPath; EvidenceSource = 'CandidateProviderError'; Error = $_.Exception.Message; Exists = $false; Readable = $false })
        }
    }
    else {
        if ([string]::IsNullOrEmpty($ExplicitPath)) {
            foreach ($candidate in @(Get-RegistryApplicationCandidates -Product $Product)) {
                [void] $rawCandidates.Add($candidate)
            }
            foreach ($candidate in @(Get-CommonApplicationCandidates -Product $Product)) {
                [void] $rawCandidates.Add($candidate)
            }
        }
    }

    $results = New-Object System.Collections.ArrayList
    foreach ($item in @($rawCandidates.ToArray())) {
        $candidate = ConvertTo-RecoveryCandidate -Item $item -Product $Product -DefaultEvidenceSource 'CandidateProvider' -FileInfoProvider $FileInfoProvider
        $duplicateIndex = -1
        for ($index = 0; $index -lt $results.Count; $index++) {
            $existing = $results[$index]
            if (-not [string]::IsNullOrEmpty([string] $candidate.Path) -and
                [string] $existing.Path -ieq [string] $candidate.Path) {
                $duplicateIndex = $index
                break
            }
        }
        if ($duplicateIndex -ge 0) {
            $existing = $results[$duplicateIndex]
            $existingVersion = [string] (Get-RecoveryProperty -Object $existing -Name 'FileVersion')
            $candidateVersion = [string] (Get-RecoveryProperty -Object $candidate -Name 'FileVersion')
            $existingProduct = [string] (Get-RecoveryProperty -Object $existing -Name 'ProductName')
            $candidateProduct = [string] (Get-RecoveryProperty -Object $candidate -Name 'ProductName')
            if (($existing.IdentityStatus -ne 'Verified' -and $candidate.IdentityStatus -eq 'Verified') -or
                ([string]::IsNullOrWhiteSpace($existingVersion) -and -not [string]::IsNullOrWhiteSpace($candidateVersion)) -or
                ([string]::IsNullOrWhiteSpace($existingProduct) -and -not [string]::IsNullOrWhiteSpace($candidateProduct))) {
                $results[$duplicateIndex] = $candidate
            }
        }
        else {
            [void] $results.Add($candidate)
        }
    }

    return @($results.ToArray())
}

function New-ApplicationResolutionResult {
    param(
        [bool] $Success,
        [string] $Status,
        [string] $Decision,
        [string] $ReasonCode,
        [string] $GateId,
        [object] $Candidate,
        [object[]] $Candidates,
        [string[]] $Errors
    )

    return [pscustomobject]@{
        Success = $Success
        Status = $Status
        Decision = $Decision
        ReasonCode = $ReasonCode
        GateId = $GateId
        Candidate = $Candidate
        Candidates = @($Candidates)
        Errors = @($Errors)
        Product = if ($null -ne $Candidate) { $Candidate.Product } else { $null }
        Path = if ($null -ne $Candidate) { $Candidate.Path } else { $null }
        FileVersion = if ($null -ne $Candidate) { $Candidate.FileVersion } else { $null }
        ProductVersion = if ($null -ne $Candidate) { $Candidate.ProductVersion } else { $null }
        ProductName = if ($null -ne $Candidate) { $Candidate.ProductName } else { $null }
        IdentityStatus = if ($null -ne $Candidate) { $Candidate.IdentityStatus } else { $null }
        BuildStatus = if ($null -ne $Candidate) { Get-RecoveryProperty -Object $Candidate -Name 'BuildStatus' } else { $null }
        EvidenceSource = if ($null -ne $Candidate) { $Candidate.EvidenceSource } else { $null }
    }
}

function Test-ValidatedApplicationBuild {
    param(
        [object] $Candidate,
        [object[]] $ValidatedBuilds
    )

    $builds = @($ValidatedBuilds)
    if ($builds.Count -eq 0) {
        return 'Unvalidated'
    }

    $fileVersion = [string] (Get-RecoveryProperty -Object $Candidate -Name 'FileVersion')
    $productVersion = [string] (Get-RecoveryProperty -Object $Candidate -Name 'ProductVersion')
    foreach ($build in $builds) {
        if ($null -eq $build -or $build -isnot [string]) {
            continue
        }
        if ([string] $build -ceq $fileVersion -or [string] $build -ceq $productVersion) {
            return 'Validated'
        }
    }
    return 'UnexpectedVersion'
}

function Resolve-RecoveryApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('FileScavenger', 'RStudio')]
        [string] $Product,
        [string] $ExplicitPath = $null,
        [scriptblock] $DiscoveryProvider = $null,
        [object[]] $ValidatedBuilds = @(),
        [scriptblock] $FileInfoProvider = $null
    )

    $hasExplicit = -not [string]::IsNullOrEmpty($ExplicitPath)
    $discovered = New-Object System.Collections.ArrayList
    if ($null -ne $DiscoveryProvider) {
        try {
            foreach ($candidate in @(& $DiscoveryProvider $Product $ExplicitPath)) {
                if ($null -ne $candidate) {
                    if (Test-RecoveryProperty -Object $candidate -Name 'Candidates') {
                        foreach ($nested in @($candidate.Candidates)) {
                            if ($null -ne $nested) {
                                [void] $discovered.Add($nested)
                            }
                        }
                    }
                    else {
                        [void] $discovered.Add($candidate)
                    }
                }
            }
        }
        catch {
            return New-ApplicationResolutionResult -Success $false -Status 'Stopped' -Decision 'Stop' -ReasonCode 'DiscoveryFailed' -GateId 'G-01' -Candidate $null -Candidates @() -Errors @($_.Exception.Message)
        }
    }
    else {
        foreach ($candidate in @(Find-RecoveryApplication -Product $Product -ExplicitPath $ExplicitPath -FileInfoProvider $FileInfoProvider)) {
            [void] $discovered.Add($candidate)
        }
    }

    $candidates = New-Object System.Collections.ArrayList
    if ($hasExplicit) {
        $matching = $null
        foreach ($item in @($discovered.ToArray())) {
            $itemPath = Get-RecoveryProperty -Object $item -Name 'Path'
            if ($null -ne $itemPath -and [string] $itemPath -ieq $ExplicitPath) {
                $matching = $item
                break
            }
        }
        if ($null -ne $matching) {
            [void] $candidates.Add((ConvertTo-RecoveryCandidate -Item $matching -Product $Product -DefaultEvidenceSource 'ExplicitPath' -FileInfoProvider $FileInfoProvider))
        }
        else {
            [void] $candidates.Add((ConvertTo-RecoveryCandidate -Item ([pscustomobject]@{ Path = $ExplicitPath; EvidenceSource = 'ExplicitPath' }) -Product $Product -DefaultEvidenceSource 'ExplicitPath' -FileInfoProvider $FileInfoProvider))
        }
    }
    else {
        foreach ($item in @($discovered.ToArray())) {
            [void] $candidates.Add((ConvertTo-RecoveryCandidate -Item $item -Product $Product -DefaultEvidenceSource 'Discovery' -FileInfoProvider $FileInfoProvider))
        }
    }

    if ($candidates.Count -eq 0) {
        return New-ApplicationResolutionResult -Success $false -Status 'Stopped' -Decision 'Stop' -ReasonCode 'MissingApplication' -GateId 'G-01' -Candidate $null -Candidates @() -Errors @('No application candidate was discovered.')
    }

    $eligible = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $hasUnexpectedVersion = $false
    foreach ($candidate in $candidates) {
        if ($candidate.IdentityStatus -eq 'Verified') {
            $versionStatus = Test-ValidatedApplicationBuild -Candidate $candidate -ValidatedBuilds $ValidatedBuilds
            $candidate | Add-Member -NotePropertyName BuildStatus -NotePropertyValue $versionStatus -Force
            if ($versionStatus -eq 'Validated' -or $versionStatus -eq 'Unvalidated') {
                [void] $eligible.Add($candidate)
            }
            else {
                $hasUnexpectedVersion = $true
                [void] $errors.Add(('UnexpectedVersion: {0}' -f $candidate.Path))
            }
        }
        else {
            [void] $errors.Add(('{0}: {1}' -f $candidate.IdentityStatus, $candidate.Path))
        }
    }

    if ($eligible.Count -eq 0) {
        $reasonCode = 'MissingApplication'
        if ($candidates[0].IdentityStatus -eq 'UnsupportedUtility') {
            $reasonCode = 'UnsupportedUtility'
        }
        elseif ($candidates[0].IdentityStatus -eq 'ProductMismatch') {
            $reasonCode = 'ProductMismatch'
        }
        elseif ($hasUnexpectedVersion) {
            $reasonCode = 'UnexpectedVersion'
        }
        elseif ($candidates[0].IdentityStatus -eq 'Unreadable') {
            $reasonCode = 'UnreadableApplication'
        }
        elseif ($candidates[0].IdentityStatus -eq 'InvalidPath') {
            $reasonCode = 'InvalidApplicationPath'
        }
        elseif ($candidates[0].IdentityStatus -eq 'IdentityEvidenceInsufficient') {
            $reasonCode = 'IdentityEvidenceInsufficient'
        }
        return New-ApplicationResolutionResult -Success $false -Status 'Stopped' -Decision 'Stop' -ReasonCode $reasonCode -GateId 'G-01' -Candidate $null -Candidates $candidates.ToArray() -Errors $errors.ToArray()
    }

    if ($eligible.Count -gt 1) {
        return New-ApplicationResolutionResult -Success $false -Status 'Ambiguous' -Decision 'ManualGate' -ReasonCode 'AmbiguousApplication' -GateId 'G-01' -Candidate $null -Candidates $eligible.ToArray() -Errors @('More than one verified application candidate was found.')
    }

    $selected = $eligible[0]
    if ($selected.BuildStatus -eq 'Unvalidated') {
        return New-ApplicationResolutionResult -Success $false -Status 'ManualGate' -Decision 'ManualGate' -ReasonCode 'BuildNotValidated' -GateId 'G-01' -Candidate $selected -Candidates $candidates.ToArray() -Errors @('The installed product identity is observed, but its build is not in the validated build list.')
    }

    return New-ApplicationResolutionResult -Success $true -Status 'Verified' -Decision 'Allowed' -ReasonCode $null -GateId $null -Candidate $selected -Candidates $candidates.ToArray() -Errors @()
}

function Get-DefaultElevationEvidence {
    try {
        if ($env:OS -ne 'Windows_NT') {
            return [pscustomobject]@{ IsElevated = $null; Evidence = 'Non-Windows host; Windows elevation provider unavailable.' }
        }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return [pscustomobject]@{
            IsElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            Evidence = 'WindowsPrincipal Administrator role'
        }
    }
    catch {
        return [pscustomobject]@{ IsElevated = $null; Evidence = $_.Exception.Message }
    }
}

function Test-RecoveryElevated {
    [CmdletBinding()]
    param([scriptblock] $ElevationProvider = $null)

    try {
        if ($null -eq $ElevationProvider) {
            $raw = Get-DefaultElevationEvidence
        }
        else {
            $raw = & $ElevationProvider
        }

        $value = $null
        $evidence = 'Elevation provider returned no value.'
        if ($raw -is [bool]) {
            $value = [bool] $raw
            $evidence = 'Boolean elevation provider result.'
        }
        elseif ($null -ne $raw) {
            if (Test-RecoveryProperty -Object $raw -Name 'IsElevated') {
                $propertyValue = Get-RecoveryProperty -Object $raw -Name 'IsElevated'
                if ($propertyValue -is [bool]) {
                    $value = [bool] $propertyValue
                }
            }
            elseif (Test-RecoveryProperty -Object $raw -Name 'Elevated') {
                $propertyValue = Get-RecoveryProperty -Object $raw -Name 'Elevated'
                if ($propertyValue -is [bool]) {
                    $value = [bool] $propertyValue
                }
            }
            elseif (Test-RecoveryProperty -Object $raw -Name 'Value') {
                $propertyValue = Get-RecoveryProperty -Object $raw -Name 'Value'
                if ($propertyValue -is [bool]) {
                    $value = [bool] $propertyValue
                }
            }
            $evidenceValue = Get-RecoveryProperty -Object $raw -Name 'Evidence'
            if ($null -ne $evidenceValue) {
                $evidence = [string] $evidenceValue
            }
        }

        if ($value -eq $true) {
            return [pscustomobject]@{
                IsElevated = $true
                Elevated = $true
                RequiresElevation = $false
                Decision = 'Allowed'
                GateId = $null
                ReasonCode = $null
                Evidence = $evidence
            }
        }
        if ($value -eq $false) {
            return [pscustomobject]@{
                IsElevated = $false
                Elevated = $false
                RequiresElevation = $true
                Decision = 'ManualGate'
                GateId = 'G-01'
                ReasonCode = 'ElevationRequired'
                Evidence = $evidence
            }
        }
        return [pscustomobject]@{
            IsElevated = $null
            Elevated = $null
            RequiresElevation = $true
            Decision = 'ManualGate'
            GateId = 'G-01'
            ReasonCode = 'ElevationUnknown'
            Evidence = $evidence
        }
    }
    catch {
        return [pscustomobject]@{
            IsElevated = $null
            Elevated = $null
            RequiresElevation = $true
            Decision = 'ManualGate'
            GateId = 'G-01'
            ReasonCode = 'ElevationUnknown'
            Evidence = $_.Exception.Message
        }
    }
}

function Get-RecoveryElevationHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $ElevationResult
    )

    $isElevated = Get-RecoveryProperty -Object $ElevationResult -Name 'IsElevated'
    if ($isElevated -eq $true) {
        return [pscustomobject]@{
            CanContinue = $true
            Action = 'Continue'
            GateId = $null
            ReasonCode = $null
            Evidence = Get-RecoveryProperty -Object $ElevationResult -Name 'Evidence'
        }
    }
    return [pscustomobject]@{
        CanContinue = $false
        Action = 'ManualElevationGate'
        GateId = 'G-01'
        ReasonCode = Get-RecoveryProperty -Object $ElevationResult -Name 'ReasonCode'
        Evidence = Get-RecoveryProperty -Object $ElevationResult -Name 'Evidence'
    }
}

Export-ModuleMember -Function @(
    'Find-RecoveryApplication',
    'Resolve-RecoveryApplication',
    'Get-RecoveryApplicationIdentity',
    'Test-RecoveryElevated',
    'Get-RecoveryElevationHandoff'
)
