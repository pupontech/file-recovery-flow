$moduleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) '..\modules'
Import-Module (Join-Path $moduleRoot 'Configuration.psm1') -Force
Import-Module (Join-Path $moduleRoot 'ApplicationDiscovery.psm1') -Force

Describe 'Recovery configuration preflight' {
    It 'accepts the minimum schema and returns a normalized configuration' {
        $path = Join-Path $TestDrive 'config.json'
        $json = @'
{
  "SchemaVersion": 1,
  "WorkflowVersion": "1.0.0",
  "ValidatedFileScavengerBuilds": [],
  "ValidatedRStudioBuilds": [],
  "CapacityReserveBytes": 1048576
}
'@
        Set-Content -LiteralPath $path -Value $json -Encoding ASCII

        $result = Read-RecoveryConfiguration -Path $path

        $result.Valid | Should -BeTrue
        $result.Configuration.SchemaVersion | Should -Be 1
        $result.Configuration.WorkflowVersion | Should -Be '1.0.0'
        $result.Configuration.MaxJobPathLength | Should -Be 200
        $result.Configuration.AllowSameDiskOverride | Should -BeFalse
        $result.Configuration.AllowVendorOverwrite | Should -BeFalse
        $result.Configuration.AllowForceClose | Should -BeFalse
    }
}

Describe 'Recovery configuration validation' {
    It 'rejects unknown fields and immutable safety overrides' {
        $configuration = [pscustomobject]@{
            SchemaVersion = 1
            WorkflowVersion = '1.0.0'
            ValidatedFileScavengerBuilds = @()
            ValidatedRStudioBuilds = @()
            CapacityReserveBytes = 0
            UnexpectedSetting = $true
            AllowSameDiskOverride = $true
        }

        $result = Test-RecoveryConfiguration -Configuration $configuration
        $result.Valid | Should -BeFalse
        ($result.Errors -join '|') | Should -Match 'CFG_UNKNOWN_FIELD'
        ($result.Errors -join '|') | Should -Match 'CFG_SAFETY_OVERRIDE'
    }

    It 'applies only typed mutable overrides without changing safety defaults' {
        $configuration = [pscustomobject]@{
            SchemaVersion = 1
            WorkflowVersion = '1.0.0'
            ValidatedFileScavengerBuilds = @('7.1.1.13')
            ValidatedRStudioBuilds = @('9.5.191810')
            CapacityReserveBytes = 1048576
        }

        $resolved = Resolve-RecoveryConfiguration -Configuration $configuration -Overrides ([pscustomobject]@{
            NoPause = $true
            CapacityReserveBytes = 2097152
        })

        $resolved.Valid | Should -BeTrue
        $resolved.Configuration.NoPause | Should -BeTrue
        $resolved.Configuration.CapacityReserveBytes | Should -Be 2097152
        $resolved.Configuration.AllowSameDiskOverride | Should -BeFalse
        $resolved.Configuration.AllowVendorOverwrite | Should -BeFalse

        $rejected = Resolve-RecoveryConfiguration -Configuration $configuration -Overrides ([pscustomobject]@{
            AllowVendorOverwrite = $true
        })
        $rejected.Valid | Should -BeFalse
        ($rejected.Errors -join '|') | Should -Match 'CFG_IMMUTABLE_OVERRIDE'
    }

    It 'returns a named error for malformed JSON' {
        $path = Join-Path $TestDrive 'malformed.json'
        Set-Content -LiteralPath $path -Value '{ not json' -Encoding ASCII

        $result = Read-RecoveryConfiguration -Path $path

        $result.Valid | Should -BeFalse
        ($result.Errors -join '|') | Should -Match 'CFG_INVALID_JSON'
    }

    It 'accepts dictionary inputs for configuration and overrides' {
        $configuration = @{
            SchemaVersion = 1
            WorkflowVersion = '1.0.0'
            ValidatedFileScavengerBuilds = @()
            ValidatedRStudioBuilds = @()
            CapacityReserveBytes = 0
        }

        $result = Test-RecoveryConfiguration -Configuration $configuration
        $result.Valid | Should -BeTrue
        $resolved = Resolve-RecoveryConfiguration -Configuration $configuration -Overrides @{ NoPause = $true }
        $resolved.Valid | Should -BeTrue
        $resolved.Configuration.NoPause | Should -BeTrue
    }
}

Describe 'Recovery application discovery preflight' {
    It 'captures application identity through an injected file-info provider' {
        $path = Join-Path $TestDrive 'scanner-fixture.bin'
        Set-Content -LiteralPath $path -Value 'fixture' -Encoding ASCII
        $fileInfoProvider = {
            param($candidatePath)
            [pscustomobject]@{
                Path = $candidatePath
                Exists = $true
                Readable = $true
                FileVersion = '7.1.1.13'
                ProductVersion = '7.1.1.13'
                ProductName = 'File Scavenger'
                OriginalFilename = 'scanner-fixture.bin'
                CompanyName = 'QueTek'
                FileDescription = 'File Scavenger'
            }
        }

        $identity = Get-RecoveryApplicationIdentity -Path $path -FileInfoProvider $fileInfoProvider

        $identity.Path | Should -Be $path
        $identity.FileVersion | Should -Be '7.1.1.13'
        $identity.ProductVersion | Should -Be '7.1.1.13'
        $identity.IdentityStatus | Should -Be 'Observed'
        $identity.EvidenceSource | Should -Match 'Injected'
    }

    It 'does not report observed identity when existence evidence is not Boolean' {
        $path = Join-Path $TestDrive 'scanner-string-state.bin'
        $identity = Get-RecoveryApplicationIdentity -Path $path -FileInfoProvider {
            param($candidatePath)
            [pscustomobject]@{
                Path            = $candidatePath
                Exists          = 'true'
                Readable        = 'true'
                FileVersion     = '7.1.1.13'
                ProductVersion  = '7.1.1.13'
                ProductName     = 'File Scavenger'
                EvidenceSource  = 'InjectedFileInfo'
            }
        }

        $identity.Exists | Should -BeFalse
        $identity.Readable | Should -BeFalse
        $identity.IdentityStatus | Should -Be 'Missing'
    }

    It 'resolves one explicit verified candidate and keeps version evidence' {
        $path = Join-Path $TestDrive 'scanner-fixture.bin'
        Set-Content -LiteralPath $path -Value 'fixture' -Encoding ASCII
        $candidateProvider = {
            param($product)
            [pscustomobject]@{
                Path = $path
                Exists = $true
                Readable = $true
                FileVersion = '7.1.1.13'
                ProductVersion = '7.1.1.13'
                ProductName = 'File Scavenger'
                OriginalFilename = 'scanner-fixture.bin'
                CompanyName = 'QueTek'
                FileDescription = 'File Scavenger'
                EvidenceSource = 'Fixture'
            }
        }

        $result = Resolve-RecoveryApplication -Product FileScavenger -ExplicitPath $path -DiscoveryProvider {
            param($product, $explicitPath)
            Find-RecoveryApplication -Product $product -ExplicitPath $explicitPath -CandidateProvider $candidateProvider
        } -ValidatedBuilds @('7.1.1.13')

        $result.Status | Should -Be 'Verified'
        $result.Success | Should -BeTrue
        $result.Candidate.Path | Should -Be $path
        $result.Candidate.FileVersion | Should -Be '7.1.1.13'
    }

    It 'returns a manual gate when the build is not validated' {
        $candidateProvider = {
            param($product)
            [pscustomobject]@{
                Path = 'C:\\Fixture\\scanner.bin'
                Exists = $true
                Readable = $true
                FileVersion = '7.1.1.13'
                ProductVersion = '7.1.1.13'
                ProductName = 'File Scavenger'
                OriginalFilename = 'scanner.bin'
            }
        }
        $result = Resolve-RecoveryApplication -Product FileScavenger -DiscoveryProvider {
            param($product)
            Find-RecoveryApplication -Product $product -CandidateProvider $candidateProvider
        } -ValidatedBuilds @()

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'ManualGate'
        $result.GateId | Should -Be 'G-01'
    }

    It 'rejects the Agent and Emergency R-Studio utilities' {
        $candidateProvider = {
            param($product)
            @(
                [pscustomobject]@{
                    Path = 'C:\\Fixture\\network-helper.bin'
                    Exists = $true
                    Readable = $true
                    FileVersion = '9.5.191810'
                    ProductVersion = '9.5.191810'
                    ProductName = 'R-Studio Agent'
                    OriginalFilename = 'network-helper.bin'
                },
                [pscustomobject]@{
                    Path = 'C:\\Fixture\\emergency-helper.bin'
                    Exists = $true
                    Readable = $true
                    FileVersion = '9.5.191810'
                    ProductVersion = '9.5.191810'
                    ProductName = 'R-Studio Emergency'
                    OriginalFilename = 'emergency-helper.bin'
                }
            )
        }

        $found = @(Find-RecoveryApplication -Product RStudio -CandidateProvider $candidateProvider)
        $found.Count | Should -Be 2
        ($found.IdentityStatus -contains 'UnsupportedUtility') | Should -BeTrue
        ($found.ProductName -contains 'R-Studio') | Should -BeFalse
    }

    It 'does not select a different candidate when an explicit path is missing' {
        $result = Resolve-RecoveryApplication -Product RStudio -ExplicitPath 'C:\\Missing\\r-studio.exe' -DiscoveryProvider {
            param($product, $explicitPath)
            [pscustomobject]@{
                Path = 'C:\\Fixture\\valid.bin'
                Exists = $true
                Readable = $true
                FileVersion = '9.5.191810'
                ProductVersion = '9.5.191810'
                ProductName = 'R-Studio'
                OriginalFilename = 'valid.bin'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'MissingApplication'
    }
}

Describe 'Recovery elevation preflight' {
    It 'allows an explicitly elevated provider result' {
        $result = Test-RecoveryElevated -ElevationProvider { $true }

        $result.IsElevated | Should -BeTrue
        $result.Decision | Should -Be 'Allowed'
        $result.GateId | Should -BeNullOrEmpty
    }

    It 'gates false and unknown elevation results' {
        $notElevated = Test-RecoveryElevated -ElevationProvider { $false }
        $unknown = Test-RecoveryElevated -ElevationProvider { return $null }

        $notElevated.IsElevated | Should -BeFalse
        $notElevated.Decision | Should -Be 'ManualGate'
        $notElevated.GateId | Should -Be 'G-01'
        $unknown.IsElevated | Should -BeNullOrEmpty
        $unknown.Decision | Should -Be 'ManualGate'
        $unknown.GateId | Should -Be 'G-01'
    }
}

Describe 'Recovery application discovery ambiguity' {
    It 'rejects a candidate that self-asserts verified R-Studio identity without trusted evidence' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path            = 'C:\\Fixture\\RStudio.exe'
                Product         = 'RStudio'
                Exists          = $true
                Readable        = $true
                FileVersion     = '9.5.191810'
                ProductVersion  = '9.5.191810'
                ProductName     = 'R-Studio'
                OriginalFilename = 'RStudio.exe'
                EvidenceSource  = 'SelfAsserted'
                IdentityStatus  = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }

    It 'accepts explicit owner evidence when FileVersionInfo publisher evidence is unavailable' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path            = 'C:\\Fixture\\portable-rstudio.exe'
                Exists          = $true
                Readable        = $true
                FileVersion     = '9.5.191810'
                ProductVersion  = '9.5.191810'
                ProductName     = 'R-Studio'
                OriginalFilename = 'RStudio.exe'
                EvidenceSource  = 'OwnerLiveRecord'
                OwnerValidated  = $true
                OwnerEvidence   = 'Owner recorded the exact installed build.'
                IdentityStatus  = 'Observed'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeTrue
        $result.Status | Should -Be 'Verified'
        $result.Candidate.EvidenceSource | Should -Be 'OwnerLiveRecord'
    }

    It 'rejects the R-Studio installer name even when its metadata looks trusted' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path            = 'C:\\Fixture\\RStudio9.exe'
                Exists          = $true
                Readable        = $true
                FileVersion     = '9.5.191810'
                ProductVersion  = '9.5.191810'
                ProductName     = 'R-Studio'
                OriginalFilename = 'RStudio9.exe'
                CompanyName     = 'R-Tools Technology, Inc.'
                EvidenceSource  = 'FileVersionInfo'
                IdentityStatus  = 'Observed'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'UnsupportedUtility'
    }

    It 'rejects R-Studio identity when the file version evidence is blank' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path            = 'C:\\Fixture\\RStudio.exe'
                Exists          = $true
                Readable        = $true
                FileVersion     = ''
                ProductVersion  = '9.5.191810'
                ProductName     = 'R-Studio'
                OriginalFilename = 'RStudio.exe'
                CompanyName     = 'R-Tools Technology, Inc.'
                EvidenceSource  = 'FileVersionInfo'
                IdentityStatus  = 'Observed'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }

    It 'rejects a same-named R-Studio executable without positive product metadata' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'ProductMismatch'
    }

    It 'rejects an R-Studio candidate without explicit on-disk existence evidence' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'MissingApplication'
    }

    It 'rejects self-asserted FileVersionInfo evidence for R-Studio' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'SelfAsserted'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }

    It 'does not treat string existence evidence as a positive file result' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            return [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = 'false'
                Readable                = 'true'
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'MissingApplication'
    }

    It 'does not choose the first of multiple verified candidates' {
        $candidateProvider = {
            param($product)
            @(
                [pscustomobject]@{
                    Path = 'C:\\Fixture\\scanner-one.exe'
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.13'
                    ProductVersion = '7.1.1.13'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'scanner-one.exe'
                },
                [pscustomobject]@{
                    Path = 'C:\\Fixture\\scanner-two.exe'
                    Exists = $true
                    Readable = $true
                    FileVersion = '7.1.1.14'
                    ProductVersion = '7.1.1.14'
                    ProductName = 'File Scavenger'
                    OriginalFilename = 'scanner-two.exe'
                }
            )
        }

        $result = Resolve-RecoveryApplication -Product FileScavenger -DiscoveryProvider {
            param($product)
            Find-RecoveryApplication -Product $product -CandidateProvider $candidateProvider
        } -ValidatedBuilds @('7.1.1.13', '7.1.1.14')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Ambiguous'
        $result.ReasonCode | Should -Be 'AmbiguousApplication'
        @($result.Candidates).Count | Should -Be 2
    }

    It 'stops on a discovered identity with an unexpected version' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path = 'C:\\Portable\\rstudio.exe'
                Exists = $true
                Readable = $true
                FileVersion = '8.0.0'
                ProductVersion = '8.0.0'
                ProductName = 'R-Studio'
                OriginalFilename = 'RStudio.exe'
                CompanyName = 'R-Tools Technology, Inc.'
                EvidenceSource = 'FileVersionInfo'
                FileVersionInfoVerified = $true
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'UnexpectedVersion'
    }

    It 'rejects R-Studio when company and publisher evidence conflict' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'Untrusted Vendor'
                Publisher               = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }

    It 'rejects string FileVersionInfo evidence for R-Studio' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = 'true'
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }

    It 'rejects a relative R-Studio application path' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path                    = 'RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'InvalidApplicationPath'
    }

    It 'rejects a non-string R-Studio file version' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = 95191810
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }

    It 'revalidates discovery metadata with the file-info provider' {
        $script:fileInfoCalls = 0
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -FileInfoProvider {
            param($path)
            $script:fileInfoCalls = $script:fileInfoCalls + 1
            [pscustomobject]@{
                Path                    = $path
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'Posit RStudio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'Posit Software, PBC'
                EvidenceSource          = 'FileVersionInfo'
                FileVersionInfoVerified = $true
            }
        } -ValidatedBuilds @('9.5.191810')

        $script:fileInfoCalls | Should -Be 1
        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'UnsupportedUtility'
    }

    It 'rejects an evidence source that only contains the FileVersionInfo token' {
        $result = Resolve-RecoveryApplication -Product RStudio -DiscoveryProvider {
            param($product)
            [pscustomobject]@{
                Path                    = 'C:\\Fixture\\RStudio.exe'
                Exists                  = $true
                Readable                = $true
                FileVersion             = '9.5.191810'
                ProductVersion          = '9.5.191810'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                CompanyName             = 'R-Tools Technology, Inc.'
                EvidenceSource          = 'NotFileVersionInfo'
                FileVersionInfoVerified = $true
                IdentityStatus          = 'Verified'
            }
        } -ValidatedBuilds @('9.5.191810')

        $result.Success | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
        $result.ReasonCode | Should -Be 'IdentityEvidenceInsufficient'
    }
}
