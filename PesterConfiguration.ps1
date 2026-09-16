<#
.SYNOPSIS
    Builds the shared Pester configuration for one File Recovery Flow test lane.

.DESCRIPTION
    Every CI lane and the local developer loop drive Pester through this file so
    that lane differences are data instead of duplicated code
    (docs/IMPLEMENTATION-SPEC.md section 7, tests/TEST-MATRIX.md section 1).

    Lanes:
      Static       tests/Static.Tests.ps1 only: encoding, AST safety, launcher,
                   and CI topology contracts.
      Unit         tests/Unit.
      Integration  tests/Integration.
      Live         tests/Live with the LiveVendor/LiveElevation tags selected.
                   Owner machine only; never a CI lane.
      All          every non-live lane together, with the live directory and the
                   live tags excluded. This is the default.

    Safety rules enforced here:
      * Pester 5.x or newer is required. Pester 3/4 has different assertion and
        invocation semantics, so it is refused instead of silently accepted.
      * A lane that resolves to zero test files fails closed instead of reporting
        a green run in which nothing executed.
      * A non-live lane refuses to start while RECOVERY_ALLOW_LIVE_VENDOR is set,
        so a mis-tagged test cannot reach a licensed application.
      * Run.Exit is enabled so a failing lane returns a non-zero process code to
        launcher, CI step, and developer shell alike.
      * NUnit XML results are always written for diagnostics.

    This file is test infrastructure. It never launches a vendor application,
    never calls a storage cmdlet, and writes only the lane result report.

.PARAMETER Lane
    Lane to configure: Static, Unit, Integration, Live, or All.

.PARAMETER TestResultDirectory
    Directory that receives the NUnit XML report. Defaults to the gitignored
    <repository>/.test-results directory.

.EXAMPLE
    $config = & ./PesterConfiguration.ps1 -Lane Static
    Invoke-Pester -Configuration $config

.EXAMPLE
    $config = & ./PesterConfiguration.ps1 -Lane All
    Invoke-Pester -Configuration $config
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Static', 'Unit', 'Integration', 'Live', 'All')]
    [string] $Lane = 'All',

    [Parameter()]
    [string] $TestResultDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$minimumPesterVersion = [version]'5.0.0'
$liveTagNameList = @('LiveVendor', 'LiveElevation')

# ---------------------------------------------------------------------------
# Repository root: this file lives at the repository root.
# ---------------------------------------------------------------------------
$repositoryRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($repositoryRoot)) {
    $repositoryRoot = (Get-Location).ProviderPath
}
$repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot -ErrorAction Stop).ProviderPath

# ---------------------------------------------------------------------------
# Resolve Pester 5.x or newer explicitly instead of accepting whatever version
# the image happens to have loaded first.
# ---------------------------------------------------------------------------
$loadedPester = Get-Module -Name Pester | Sort-Object -Property Version -Descending | Select-Object -First 1
if (($null -eq $loadedPester) -or ($loadedPester.Version -lt $minimumPesterVersion)) {
    $availablePester = @(Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge $minimumPesterVersion } |
        Sort-Object -Property Version -Descending)
    if ($availablePester.Count -eq 0) {
        throw ('Pester ' + $minimumPesterVersion.ToString() + ' or newer is required, but no satisfying version is installed. Install it explicitly; this lane will not fall back to Pester 3/4 assertion semantics.')
    }
    $selectedPester = @($availablePester)[0]
    Import-Module -Name Pester -RequiredVersion $selectedPester.Version -ErrorAction Stop
    $loadedPester = Get-Module -Name Pester | Where-Object { $_.Version -eq $selectedPester.Version } | Select-Object -First 1
}
if ($null -eq $loadedPester) {
    throw 'Pester could not be loaded into this session.'
}
if ($loadedPester.Version -lt $minimumPesterVersion) {
    throw ('Pester ' + $loadedPester.Version.ToString() + ' is loaded, which is older than the required ' + $minimumPesterVersion.ToString() + '.')
}
Write-Verbose ('Pester ' + $loadedPester.Version.ToString() + ' selected for lane ' + $Lane + '.')

# ---------------------------------------------------------------------------
# Isolation: only the owner Live lane may run with the vendor opt-in.
# ---------------------------------------------------------------------------
if ($Lane -ne 'Live') {
    if (-not [string]::IsNullOrEmpty($env:RECOVERY_ALLOW_LIVE_VENDOR)) {
        throw ('RECOVERY_ALLOW_LIVE_VENDOR is set, so lane ' + $Lane + ' refuses to run. The vendor opt-in belongs to the owner Live lane on a technician machine with licensed products.')
    }
}

# ---------------------------------------------------------------------------
# Lane definition. Missing lane directories are dropped, and an empty result is
# an error: a lane must never report success with nothing executed.
# ---------------------------------------------------------------------------
$testsRoot = [System.IO.Path]::Combine($repositoryRoot, 'tests')
$liveRoot = [System.IO.Path]::Combine($testsRoot, 'Live')
$staticContractFile = [System.IO.Path]::Combine($testsRoot, 'Static.Tests.ps1')

$candidatePaths = @()
$excludedPaths = @()
$selectedTags = @()
$excludedTags = @()

switch ($Lane) {
    'Static' {
        $candidatePaths = @($staticContractFile)
    }
    'Unit' {
        $candidatePaths = @([System.IO.Path]::Combine($testsRoot, 'Unit'))
    }
    'Integration' {
        $candidatePaths = @([System.IO.Path]::Combine($testsRoot, 'Integration'))
    }
    'Live' {
        $candidatePaths = @($liveRoot)
        $selectedTags = $liveTagNameList
    }
    'All' {
        $candidatePaths = @($testsRoot)
    }
}

if ($Lane -ne 'Live') {
    $excludedPaths = @($liveRoot)
    $excludedTags = $liveTagNameList
    foreach ($artifactPath in @([System.IO.Path]::Combine($repositoryRoot, '.git'), [System.IO.Path]::Combine($repositoryRoot, '.test-results'))) {
        $excludedPaths += $artifactPath
    }
}

$resolvedPaths = @()
foreach ($candidate in $candidatePaths) {
    if (Test-Path -LiteralPath $candidate) { $resolvedPaths += $candidate }
}
if ($resolvedPaths.Count -eq 0) {
    throw ('Lane ' + $Lane + ' resolved to no test files, so nothing would execute. Checked: ' + ($candidatePaths -join ', '))
}

# ---------------------------------------------------------------------------
# Result reporting.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($TestResultDirectory)) {
    $TestResultDirectory = [System.IO.Path]::Combine($repositoryRoot, '.test-results')
}
if (-not (Test-Path -LiteralPath $TestResultDirectory -PathType Container)) {
    $null = New-Item -Path $TestResultDirectory -ItemType Directory -Force -ErrorAction Stop
}
$resultFilePath = [System.IO.Path]::Combine($TestResultDirectory, ('pester-' + $Lane.ToLowerInvariant() + '.xml'))

# ---------------------------------------------------------------------------
# Configuration object.
# ---------------------------------------------------------------------------
$configuration = New-PesterConfiguration
$configuration.Run.Path = $resolvedPaths
$configuration.Run.Exit = $true
$configuration.Run.ExcludePath = $excludedPaths
$configuration.Filter.ExcludeTag = $excludedTags
$configuration.Filter.Tag = $selectedTags
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = $resultFilePath

return $configuration
