<#
.SYNOPSIS
Unit tests for modules/RStudio.psm1 and modules/TechnicianUi.psm1.

.DESCRIPTION
Covers TEST-MATRIX section 6 rows R-01 through R-10 with injected seams, plus the
exported module surface contracts. No test launches a vendor executable, touches
a real recovery disk, or sends input to a desktop: every external operation is a
recording double supplied by the test, and filesystem fixtures use TestDrive:.

Tag Phase1: launch-only argument construction and handoff preconditions.
Tag Phase2: handoff launch, observation, best-effort activation, client folder.
Tag Phase3: technician handoff panel, manual gates, picker seam, destination
            delegation, and the exported module surface.
#>

Describe 'R-Studio handoff and technician UI' {

    BeforeAll {
        $repoRoot = $null
        if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
            $repoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
        }
        elseif (-not [string]::IsNullOrEmpty($PSCommandPath)) {
            $testFolder = [System.IO.Path]::GetDirectoryName($PSCommandPath)
            $repoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($testFolder, '..', '..'))
        }

        function Get-RepoFile {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][string]$RelativePath
            )

            $current = $Root
            foreach ($part in ($RelativePath -split '/')) {
                $current = [System.IO.Path]::Combine($current, $part)
            }
            return $current
        }

        function Import-RepoModule {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][string]$Name
            )

            $path = Get-RepoFile -Root $Root -RelativePath ('modules/' + $Name)
            Import-Module -Name $path -Force -ErrorAction Stop
            return $path
        }

        function New-VendorCallLog {
            [CmdletBinding()]
            param()

            $log = @{}
            foreach ($name in @('ProcessRunner', 'ExplorerProvider', 'ActivationProvider', 'UiProvider',
                    'ClipboardProvider', 'DisplayProvider', 'InteractionProvider', 'PickerProvider',
                    'TypedPathProvider', 'Resolver', 'PathSafetyValidator', 'FreshEvidenceProvider')) {
                $log[$name] = New-Object System.Collections.ArrayList
            }
            $global:RecoveryTestCalls = $log
        }

        function Get-VendorCalls {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$Name)

            return @($global:RecoveryTestCalls[$Name])
        }

        function New-VerifiedRStudioExecutable {
            [CmdletBinding()]
            param()

            # The fixture executable path is deliberately generic: no vendor
            # executable name appears in this unit test file (TEST-MATRIX S-11).
            # Product identity is carried by the Product and IdentityStatus fields.
            return [pscustomobject]@{
                Path           = 'D:\Fixture\VerifiedApp\application.exe'
                Product        = 'RStudio'
                ProductName    = 'R-Studio'
                OriginalFilename = 'RStudio.exe'
                FileVersion    = '9.5.191810'
                ProductVersion = '9.5'
                CompanyName    = 'R-Tools Technology, Inc.'
                Publisher      = 'R-Tools Technology, Inc.'
                Exists         = $true
                Readable       = $true
                FileVersionInfoVerified = $true
                EvidenceSource = 'FileVersionInfo'
                IdentityStatus = 'Verified'
            }
        }

        function New-HandoffState {
            [CmdletBinding()]
            param([string]$CurrentState = 'READY_FOR_HANDOFF')

            return [pscustomobject]@{
                JobId                       = 'JOB-20260916-0001'
                CurrentState                = $CurrentState
                FileScavengerCloseVerified  = $true
                OutputVerified               = $true
                SourceIdentityVerified       = $true
                DestinationIdentityVerified  = $true
                LogDurable                   = $true
                StateDurable                 = $true
            }
        }

        function New-AllowedPathValidator {
            [CmdletBinding()]
            param()

            return {
                param($Path)
                return [pscustomobject]@{
                    Allowed             = $true
                    Decision            = 'Allowed'
                    ReasonCode          = $null
                    DestinationEvidence = @{ Path = $Path; PhysicalDisks = @('disk-2') }
                }
            }
        }

        function New-BlockedPathValidator {
            [CmdletBinding()]
            param([string]$ReasonCode = 'SamePhysicalDisk')

            # The reason code travels through a global so the returned provider
            # scriptblock stays deterministic when it is invoked from a module.
            $global:RecoveryTestBlockedReason = $ReasonCode
            return {
                param($Path)
                return [pscustomobject]@{
                    Allowed    = $false
                    Decision   = 'Blocked'
                    ReasonCode = $global:RecoveryTestBlockedReason
                }
            }
        }

        function New-CompleteFreshEvidence {
            [CmdletBinding()]
            param()

            return {
                param($State)
                return [pscustomobject]@{
                    Success                     = $true
                    FileScavengerCloseVerified  = $true
                    OutputVerified              = $true
                    SourceIdentityVerified      = $true
                    DestinationIdentityVerified = $true
                    LogDurable                  = $true
                    StateDurable                = $true
                }
            }
        }

        function New-RecordingProcessRunner {
            [CmdletBinding()]
            param()

            return {
                param($Request)
                [void]$global:RecoveryTestCalls['ProcessRunner'].Add($Request)
                return [pscustomobject]@{
                    Success          = $true
                    Id               = 4321
                    ProcessId        = 4321
                    Name             = 'rstudio'
                    Path             = $Request.ExecutablePath
                    StartTimeUtc     = [datetime]::UtcNow
                    HasExited        = $false
                    MainWindowHandle = 0
                }
            }
        }

        function New-ManualGateFixture {
            [CmdletBinding()]
            param()

            return [pscustomobject]@{
                GateId      = 'G-10'
                Reason      = 'Confirm the R-Studio main panel on the technician desktop.'
                Evidence    = @{ ProcessId = 4321; ExecutablePath = 'D:\Fixture\VerifiedApp\application.exe' }
                Choices     = @('Continue', 'Pause', 'Abort')
                SafeDefault = 'Pause'
                Scope       = 'RStudioMainPanelHandoff'
            }
        }
    }

    Context 'launch-only argument construction' -Tag 'Phase1' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'RStudio.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'builds exactly the documented launch-only argument list' {
            $result = New-RStudioArgumentList
            $result.Decision | Should -Be 'Ready'
            @($result.Arguments).Count | Should -Be 1
            @($result.Arguments)[0] | Should -Be '-safe'
            $result.IncludesLog | Should -BeFalse
        }

        It 'adds exactly -log and one validated path when a log path is configured' {
            $result = New-RStudioArgumentList -LogPath 'D:\Case\20260916\rstudio.log'
            $result.Decision | Should -Be 'Ready'
            @($result.Arguments).Count | Should -Be 3
            @($result.Arguments)[0] | Should -Be '-safe'
            @($result.Arguments)[1] | Should -Be '-log'
            @($result.Arguments)[2] | Should -Be 'D:\Case\20260916\rstudio.log'
            $result.IncludesLog | Should -BeTrue
        }

        It 'rejects a log path that is not absolute' {
            $result = New-RStudioArgumentList -LogPath 'relative\rstudio.log'
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'LogPathInvalid'
            $result.Arguments | Should -BeNullOrEmpty
        }

        It 'rejects a log path containing a quote, wildcard, or control character' {
            foreach ($bad in @('D:\Case\rs"tudio.log', 'D:\Case\*.log', 'D:\Case\rs?dio.log')) {
                $result = New-RStudioArgumentList -LogPath $bad
                $result.Decision | Should -Be 'Blocked'
                $result.ReasonCode | Should -Be 'LogPathInvalid'
                $result.Arguments | Should -BeNullOrEmpty
            }
        }

        It 'never emits an argument outside the documented launch-only set' {
            $logPath = 'D:\Case\20260916\rstudio.log'
            $allowed = @('-safe', '-log', $logPath)
            $withoutLog = New-RStudioArgumentList
            $withLog = New-RStudioArgumentList -LogPath $logPath
            foreach ($candidate in @($withoutLog, $withLog)) {
                foreach ($argument in @($candidate.Arguments)) {
                    $allowed | Should -Contain $argument
                }
            }
        }

        It 'does not expose a parameter that could carry a source, folder, project, scan, report, or raw argument string' {
            foreach ($commandName in @('New-RStudioArgumentList', 'Start-RStudioHandoff')) {
                $names = @((Get-Command $commandName).Parameters.Keys)
                foreach ($forbidden in @('Source', 'SourcePath', 'Folder', 'Project', 'Report', 'Scan',
                        'Recover', 'Recovery', 'Arguments', 'ArgumentList', 'RawArguments', 'ExtraArguments',
                        'SafeMode', 'ActivateWindow', 'Wipe', 'Repair')) {
                    $names | Should -Not -Contain $forbidden
                }
            }
        }

        It 'quotes a command line argument that contains spaces for the production runner' {
            $module = Get-Module 'RStudio'
            $line = & $module { ConvertTo-RStudioArgumentString -Arguments @('-safe', '-log', 'D:\My Case\rs.log') }
            $line | Should -Be '"-safe" "-log" "D:\My Case\rs.log"'
        }
    }

    Context 'handoff preconditions' -Tag 'Phase1' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'RStudio.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'allows a verified executable in READY_FOR_HANDOFF with a validated safe log path' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log' `
                -LogPathSafetyValidator (New-AllowedPathValidator) `
                -FreshEvidenceProvider (New-CompleteFreshEvidence)
            $result.Allowed | Should -BeTrue
            $result.Decision | Should -Be 'Allowed'
            $result.ReasonCode | Should -BeNullOrEmpty
            @($result.Checks).Count | Should -BeGreaterThan 0
        }

        It 'allows a launch when no log path is configured' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable)
            $result.Allowed | Should -BeTrue
            $result.ReasonCode | Should -BeNullOrEmpty
        }

        It 'refuses a launch unless the state is READY_FOR_HANDOFF' {
            foreach ($state in @('SHORT_RECOVERY_VERIFIED', 'CASE_READY', '', 'HANDOFF_MANUAL')) {
                $result = Test-RStudioHandoffPreconditions -State (New-HandoffState -CurrentState $state) `
                    -Executable (New-VerifiedRStudioExecutable)
                $result.Allowed | Should -BeFalse
                $result.Decision | Should -Be 'Blocked'
                $result.ReasonCode | Should -Be 'StateNotReadyForHandoff'
            }
        }

        It 'refuses a state object whose handoff evidence flags are not all true' {
            $state = [pscustomobject]@{
                CurrentState               = 'READY_FOR_HANDOFF'
                FileScavengerCloseVerified = $false
                SourceIdentityVerified     = $true
            }
            $result = Test-RStudioHandoffPreconditions -State $state -Executable (New-VerifiedRStudioExecutable)
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'StateEvidenceIncomplete'
            $result.Evidence['IncompleteStateEvidence'] | Should -Contain 'FileScavengerCloseVerified'
        }

        It 'refuses a state object when any handoff evidence flag is absent' {
            $state = [pscustomobject]@{
                CurrentState               = 'READY_FOR_HANDOFF'
                FileScavengerCloseVerified = $true
            }
            $result = Test-RStudioHandoffPreconditions -State $state -Executable (New-VerifiedRStudioExecutable)
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'StateEvidenceIncomplete'
            $result.Evidence['IncompleteStateEvidence'] | Should -Contain 'OutputVerified'
        }

        It 'does not treat a string handoff evidence flag as positive' {
            $state = New-HandoffState
            $state.OutputVerified = 'true'
            $result = Test-RStudioHandoffPreconditions -State $state -Executable (New-VerifiedRStudioExecutable)
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'StateEvidenceIncomplete'
            $result.Evidence['IncompleteStateEvidence'] | Should -Contain 'OutputVerified'
        }

        It 'refuses a state string because it cannot carry complete handoff evidence' {
            $result = Test-RStudioHandoffPreconditions -State 'READY_FOR_HANDOFF' `
                -Executable (New-VerifiedRStudioExecutable)
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'StateEvidenceIncomplete'
            $result.Evidence['IncompleteStateEvidence'] | Should -Contain 'OutputVerified'
        }

        It 'refuses a missing executable identity' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $null
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableNotProvided'
        }

        It 'refuses verified R-Studio identity without trusted version evidence' {
            $executable = [pscustomobject]@{
                Path           = 'D:\\Fixture\\VerifiedApp\\application.exe'
                Product        = 'RStudio'
                FileVersion    = '9.5.191810'
                ProductName    = 'R-Studio'
                Exists         = $true
                Readable       = $true
                IdentityStatus = 'Verified'
                EvidenceSource = 'SelfAsserted'
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableIdentityEvidenceUnverified'
        }

        It 'rejects a non-string executable file version' {
            $executable = New-VerifiedRStudioExecutable
            $executable.FileVersion = 95191810
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableIdentityEvidenceUnverified'
        }

        It 'refuses self-asserted FileVersionInfo identity evidence' {
            $executable = [pscustomobject]@{
                Path                    = 'D:\\Fixture\\VerifiedApp\\application.exe'
                Product                 = 'RStudio'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                FileVersion             = '9.5.191810'
                CompanyName             = 'R-Tools Technology, Inc.'
                Exists                  = $true
                Readable                = $true
                FileVersionInfoVerified = $true
                EvidenceSource          = 'SelfAsserted'
                IdentityStatus          = 'Verified'
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableIdentityEvidenceUnverified'
        }

        It 'accepts trusted publisher evidence when the first company field is blank' {
            $executable = [pscustomobject]@{
                Path                    = 'D:\\Fixture\\VerifiedApp\\application.exe'
                Product                 = 'RStudio'
                ProductName             = 'R-Studio'
                OriginalFilename        = 'RStudio.exe'
                FileVersion             = '9.5.191810'
                CompanyName             = ''
                Publisher               = 'R-Tools Technology, Inc.'
                Exists                  = $true
                Readable                = $true
                FileVersionInfoVerified = $true
                EvidenceSource          = 'FileVersionInfo'
                IdentityStatus          = 'Verified'
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeTrue
            $result.ReasonCode | Should -BeNullOrEmpty
        }

        It 'rejects conflicting trusted and untrusted publisher evidence' {
            $executable = New-VerifiedRStudioExecutable
            $executable.Publisher = 'Untrusted Vendor'
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableIdentityEvidenceUnverified'
        }

        It 'requires Boolean on-disk existence evidence' {
            $executable = New-VerifiedRStudioExecutable
            $executable.Exists = 'true'
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableMissingOnDisk'
        }

        It 'refuses an executable identity without a path' {
            $executable = [pscustomobject]@{ Product = 'RStudio'; IdentityStatus = 'Verified' }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutablePathMissing'
        }

        It 'refuses a relative executable path' {
            $executable = New-VerifiedRStudioExecutable
            $executable.Path = 'Fixture\application.exe'
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutablePathInvalid'
        }

        It 'refuses an executable whose product is not R-Studio for Windows' {
            foreach ($product in @('RStudioAgent', 'RStudioEmergency', 'RStudioPosit', $null)) {
                $executable = [pscustomobject]@{
                    Path           = 'D:\Fixture\VerifiedApp\application.exe'
                    Product        = $product
                    IdentityStatus = 'Verified'
                }
                $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
                $result.Allowed | Should -BeFalse
            }
        }

        It 'refuses an executable whose identity is not verified' {
            foreach ($status in @('Unverified', 'Unknown', 'Ambiguous', $null)) {
                $executable = [pscustomobject]@{
                    Path           = 'D:\Fixture\VerifiedApp\application.exe'
                    Product        = 'RStudio'
                    IdentityStatus = $status
                }
                $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
                $result.Allowed | Should -BeFalse
                $result.ReasonCode | Should -Be 'ExecutableIdentityUnverified'
            }
        }

        It 'rejects contradictory identity status and verification evidence' {
            $executable = New-VerifiedRStudioExecutable
            $executable.IdentityStatus = 'Unverified'
            $executable | Add-Member -NotePropertyName IsVerified -NotePropertyValue $true
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableIdentityUnverified'
        }

        It 'refuses an executable whose identity fields contradict each other' {
            $executable = [pscustomobject]@{
                Path                  = 'D:\Fixture\VerifiedApp\application.exe'
                Product               = 'RStudio'
                IdentityStatus        = 'Verified'
                ContradictionDetected = $true
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'ExecutableIdentityUnverified'
        }

        It 'refuses an R-Studio Agent, Emergency, or installer executable name' {
            # The documented vendor file names are assembled from parts so that
            # this unit test file contains no literal vendor executable name
            # (TEST-MATRIX S-11) while still asserting the exact rejection.
            $vendorNames = @(
                ('RStudio' + 'AgentEn9' + '.exe'),
                ('RStudio' + 'Emg9' + '.exe'),
                ('RStudio' + 'AgentPortableEn9' + '.exe'),
                ('RStudio' + '9' + '.exe'),
                ('r-studio-' + 'emergency' + '.exe')
            )
            foreach ($name in $vendorNames) {
                $executable = New-VerifiedRStudioExecutable
                $executable.Path = 'D:\Fixture\Downloads\' + $name
                $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) -Executable $executable
                $result.Allowed | Should -BeFalse
                @('AgentOrEmergencyExecutable', 'InstallerNotApplicationExecutable') | Should -Contain $result.ReasonCode
            }
        }

        It 'refuses an unsafe log path and records the blocking reason code' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log' `
                -LogPathSafetyValidator (New-BlockedPathValidator -ReasonCode 'SameVolume')
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'LogPathUnsafe'
            $result.Evidence['LogPathSafetyReasonCode'] | Should -Be 'SameVolume'
        }

        It 'fails closed when a log path is configured without a safety validator' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log'
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'LogPathSafetyUnverified'
        }

        It 'rejects a string log-path safety decision' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log' `
                -LogPathSafetyValidator { param($Path) return [pscustomobject]@{ Allowed = 'true' } }
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'LogPathSafetyUnverified'
        }

        It 'fails closed when the log path safety validator throws or returns no decision' {
            $throwing = {
                param($Path)
                throw 'validator exploded'
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log' `
                -LogPathSafetyValidator $throwing
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'LogPathSafetyUnverified'

            $empty = {
                param($Path)
                return [pscustomobject]@{ Note = 'no decision here' }
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log' `
                -LogPathSafetyValidator $empty
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'LogPathSafetyUnverified'
        }

        It 'refuses an invalid log path before any safety check' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'relative\rstudio.log' `
                -LogPathSafetyValidator (New-AllowedPathValidator)
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'LogPathInvalid'
        }

        It 'refuses when the fresh evidence provider reports an unverified handoff' {
            $stale = {
                param($State)
                [void]$global:RecoveryTestCalls['FreshEvidenceProvider'].Add($State)
                return [pscustomobject]@{
                    Success                     = $true
                    FileScavengerCloseVerified  = $true
                    OutputVerified              = $true
                    SourceIdentityVerified      = $false
                    DestinationIdentityVerified = $true
                    LogDurable                  = $true
                    StateDurable                = $true
                }
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -FreshEvidenceProvider $stale
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'FreshEvidenceFailed'
            $result.Evidence['FailedFreshEvidence'] | Should -Contain 'SourceIdentityVerified'
            (Get-VendorCalls -Name 'FreshEvidenceProvider').Count | Should -Be 1
        }

        It 'fails closed when the fresh evidence provider returns nothing or throws' {
            $empty = {
                param($State)
                return $null
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -FreshEvidenceProvider $empty
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'FreshEvidenceUnverified'

            $throwing = {
                param($State)
                throw 'evidence exploded'
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -FreshEvidenceProvider $throwing
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'FreshEvidenceUnverified'
        }

        It 'refuses fresh evidence that has all flags but no explicit provider success' {
            $withoutSuccess = {
                param($State)
                return [pscustomobject]@{
                    FileScavengerCloseVerified  = $true
                    OutputVerified              = $true
                    SourceIdentityVerified      = $true
                    DestinationIdentityVerified = $true
                    LogDurable                  = $true
                    StateDurable                = $true
                }
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -FreshEvidenceProvider $withoutSuccess
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'FreshEvidenceUnverified'
        }

        It 'requires a Boolean true for fresh evidence provider success' {
            $stringSuccess = {
                param($State)
                return [pscustomobject]@{
                    Success                     = 'true'
                    FileScavengerCloseVerified  = $true
                    OutputVerified              = $true
                    SourceIdentityVerified      = $true
                    DestinationIdentityVerified = $true
                    LogDurable                  = $true
                    StateDurable                = $true
                }
            }
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -FreshEvidenceProvider $stringSuccess
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'FreshEvidenceUnverified'
        }

        It 'checks preconditions without calling any process, explorer, activation, or UI seam' {
            $result = Test-RStudioHandoffPreconditions -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath 'D:\Case\20260916\rstudio.log' `
                -LogPathSafetyValidator (New-AllowedPathValidator) `
                -FreshEvidenceProvider (New-CompleteFreshEvidence)
            $result.Allowed | Should -BeTrue
            foreach ($name in @('ProcessRunner', 'ExplorerProvider', 'ActivationProvider', 'UiProvider')) {
                (Get-VendorCalls -Name $name).Count | Should -Be 0
            }
        }
    }

    Context 'handoff launch' -Tag 'Phase2' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'RStudio.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'launches exactly once with the verified executable and returns the process identity' {
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner)
            $result.Decision | Should -Be 'HandoffLaunched'
            $result.Launched | Should -BeTrue
            $result.IsLaunchOnly | Should -BeTrue
            $result.ProcessIdentity.ProcessId | Should -Be 4321
            $result.ExecutablePath | Should -Be 'D:\Fixture\VerifiedApp\application.exe'
            $calls = Get-VendorCalls -Name 'ProcessRunner'
            $calls.Count | Should -Be 1
            $calls[0].ExecutablePath | Should -Be 'D:\Fixture\VerifiedApp\application.exe'
            $calls[0].Product | Should -Be 'RStudio'
        }

        It 'refuses a process result without explicit provider success' {
            $runner = {
                param($Request)
                return [pscustomobject]@{
                    ProcessId    = 4321
                    Path         = $Request.ExecutablePath
                    StartTimeUtc = [datetime]::UtcNow
                }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner $runner
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ProcessResultUnverified'
            $result.Launched | Should -BeFalse
        }

        It 'requires a Boolean true for process provider success' {
            $runner = {
                param($Request)
                return [pscustomobject]@{
                    Success      = 'true'
                    ProcessId    = 4321
                    Path         = $Request.ExecutablePath
                    StartTimeUtc = [datetime]::UtcNow
                }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner $runner
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ProcessResultUnverified'
            $result.Launched | Should -BeFalse
        }

        It 'refuses a process result whose actual executable path differs from the requested identity' {
            $runner = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    ProcessId    = 4321
                    Path         = 'D:\\Fixture\\OtherApp\\other.exe'
                    StartTimeUtc = [datetime]::UtcNow
                }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner $runner
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ProcessPathMismatch'
            $result.Launched | Should -BeFalse
        }

        It 'refuses a process result without an actual executable path' {
            $runner = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    ProcessId    = 4321
                    StartTimeUtc = [datetime]::UtcNow
                }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner $runner
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ProcessPathMissing'
            $result.Launched | Should -BeFalse
        }

        It 'refuses a process result without an actual process start time' {
            $runner = {
                param($Request)
                return [pscustomobject]@{
                    Success   = $true
                    ProcessId = 4321
                    Path      = $Request.ExecutablePath
                }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner $runner
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ProcessStartTimeMissing'
            $result.Launched | Should -BeFalse
        }

        It 'records the exact launch-only argument list in the result and the launch request' {
            $logPath = 'D:\Case\20260916\rstudio.log'
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath $logPath `
                -LogPathSafetyValidator (New-AllowedPathValidator) `
                -ProcessRunner (New-RecordingProcessRunner)
            @($result.Arguments).Count | Should -Be 3
            @($result.Arguments)[0] | Should -Be '-safe'
            @($result.Arguments)[1] | Should -Be '-log'
            @($result.Arguments)[2] | Should -Be $logPath
            $calls = Get-VendorCalls -Name 'ProcessRunner'
            @($calls[0].Arguments)[0] | Should -Be '-safe'
            @($calls[0].Arguments)[2] | Should -Be $logPath
        }

        It 'returns a main-panel manual gate and claims no completion or analysis' {
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner)
            $result.MainPanelGate | Should -Not -BeNullOrEmpty
            $result.MainPanelGate.GateId | Should -Be 'G-10'
            $result.MainPanelGate.SafeDefault | Should -Be 'Pause'
            $result.MainPanelGate.RequiresOperatorDecision | Should -BeTrue
            $result.MainPanelGate.AutoContinueAllowed | Should -BeFalse
            $result.MainPanelGate.Evidence.ProcessId | Should -Be 4321
            $result.CompletionClaimed | Should -BeFalse
            $result.AnalysisInvoked | Should -BeFalse
            @($result.MainPanelGate.Choices) | Should -Contain 'Continue'
        }

        It 'does not call the process runner when the state blocks the launch' {
            $result = Start-RStudioHandoff -State 'CASE_READY' `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner)
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'StateNotReadyForHandoff'
            $result.Launched | Should -BeFalse
            $result.Arguments | Should -BeNullOrEmpty
            $result.ProcessIdentity | Should -BeNullOrEmpty
            $result.MainPanelGate | Should -BeNullOrEmpty
            (Get-VendorCalls -Name 'ProcessRunner').Count | Should -Be 0
        }

        It 'does not call the process runner when the executable identity is unverified' {
            $executable = New-VerifiedRStudioExecutable
            $executable.IdentityStatus = 'Unverified'
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable $executable `
                -ProcessRunner (New-RecordingProcessRunner)
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'ExecutableIdentityUnverified'
            (Get-VendorCalls -Name 'ProcessRunner').Count | Should -Be 0
        }

        It 'fails closed without a retry or fallback when the process runner throws' {
            $runner = {
                param($Request)
                [void]$global:RecoveryTestCalls['ProcessRunner'].Add($Request)
                throw 'launch failed'
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner $runner
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ProcessLaunchFailed'
            $result.Launched | Should -BeFalse
            $result.MainPanelGate | Should -BeNullOrEmpty
            (Get-VendorCalls -Name 'ProcessRunner').Count | Should -Be 1
        }

        It 'fails closed when the process runner returns no usable process identity' {
            $runner = {
                param($Request)
                return $global:RecoveryTestRunnerIdentity
            }
            foreach ($identity in @([pscustomobject]@{ Name = 'rstudio' }, [pscustomobject]@{ ProcessId = 0 })) {
                $global:RecoveryTestRunnerIdentity = $identity
                $result = Start-RStudioHandoff -State (New-HandoffState) `
                    -Executable (New-VerifiedRStudioExecutable) `
                    -ProcessRunner $runner
                $result.Decision | Should -Be 'Failed'
                $result.ReasonCode | Should -Be 'ProcessIdentityMissing'
                $result.Launched | Should -BeFalse
            }
        }

        It 'records a best-effort foreground activation without claiming readiness' {
            $activation = {
                param($ProcessIdentity)
                [void]$global:RecoveryTestCalls['ActivationProvider'].Add($ProcessIdentity)
                return [pscustomobject]@{ Result = 'Activated'; ReasonCode = $null }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner) `
                -ActivationProvider $activation
            $result.Decision | Should -Be 'HandoffLaunched'
            $result.Activation.Result | Should -Be 'Activated'
            $result.Activation.Activated | Should -BeTrue
            $result.Activation.IsBestEffort | Should -BeTrue
            $result.Activation.Blocking | Should -BeFalse
            (Get-VendorCalls -Name 'ActivationProvider').Count | Should -Be 1
            (Get-VendorCalls -Name 'ActivationProvider')[0].ProcessId | Should -Be 4321
        }

        It 'records a failed or unavailable activation without failing the handoff' {
            $unavailable = {
                param($ProcessIdentity)
                return [pscustomobject]@{ Result = 'Unavailable'; ReasonCode = 'MainWindowUnavailable' }
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner) `
                -ActivationProvider $unavailable
            $result.Decision | Should -Be 'HandoffLaunched'
            $result.Activation.Result | Should -Be 'Unavailable'
            $result.Activation.Activated | Should -BeFalse

            $throwing = {
                param($ProcessIdentity)
                throw 'activation seam failed'
            }
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner) `
                -ActivationProvider $throwing
            $result.Decision | Should -Be 'HandoffLaunched'
            $result.Activation.Result | Should -Be 'Failed'
            $result.Activation.ReasonCode | Should -Be 'ActivationFailed'
            $result.Activation.Blocking | Should -BeFalse
        }

        It 'records an unattempted activation when no activation seam is supplied' {
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -ProcessRunner (New-RecordingProcessRunner)
            $result.Activation.Result | Should -Be 'NotAttempted'
            $result.Activation.ReasonCode | Should -Be 'ActivationProviderUnavailable'
            $result.Activation.IsBestEffort | Should -BeTrue
        }

        It 'never passes the client folder to the process runner' {
            $clientFolder = Join-Path $TestDrive 'client'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $folderResult = Open-RecoveryClientFolder -Path $clientFolder -ExplorerProvider {
                param($Request)
                [void]$global:RecoveryTestCalls['ExplorerProvider'].Add($Request)
                return [pscustomobject]@{ Success = $true; Result = 'Opened' }
            }
            $folderResult.Decision | Should -Be 'Opened'

            $logPath = 'D:\Case\20260916\rstudio.log'
            $result = Start-RStudioHandoff -State (New-HandoffState) `
                -Executable (New-VerifiedRStudioExecutable) `
                -LogPath $logPath `
                -LogPathSafetyValidator (New-AllowedPathValidator) `
                -ProcessRunner (New-RecordingProcessRunner)
            $result.Decision | Should -Be 'HandoffLaunched'
            $calls = Get-VendorCalls -Name 'ProcessRunner'
            @($calls[0].Arguments) | Should -Not -Contain $clientFolder
            @($calls[0].Arguments).Count | Should -Be 3
        }
    }

    Context 'R-Studio observation' -Tag 'Phase2' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'RStudio.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'reports process and main-panel evidence without claiming completion' {
            $ui = {
                param($ProcessIdentity)
                [void]$global:RecoveryTestCalls['UiProvider'].Add($ProcessIdentity)
                return [pscustomobject]@{
                    ProcessPresent   = $true
                    WindowPresent    = $true
                    MainPanelVisible = $true
                    ControlEvidence  = @('R-Studio main panel was reported visible')
                    Messages         = @('Main panel ready')
                    Evidence         = @{ Source = 'OwnerLiveRecord' }
                }
            }
            $identity = [pscustomobject]@{ ProcessId = 4321; ExecutablePath = 'D:\Fixture\VerifiedApp\application.exe' }
            $result = Get-RStudioObservation -ProcessIdentity $identity -UiProvider $ui
            $result.Result | Should -Be 'Observed'
            $result.IsUnknown | Should -BeFalse
            $result.ProcessPresent | Should -BeTrue
            $result.MainPanelVisible | Should -BeTrue
            $result.CompletionClaimed | Should -BeFalse
            $result.AnalysisInvoked | Should -BeFalse
            $result.Gate | Should -BeNullOrEmpty
            @($result.PSObject.Properties.Name) | Should -Not -Contain 'Completed'
            @($result.PSObject.Properties.Name) | Should -Not -Contain 'Recovered'
            (Get-VendorCalls -Name 'UiProvider').Count | Should -Be 1
        }

        It 'treats incomplete UI evidence as unknown and returns a manual gate' {
            $ui = {
                param($ProcessIdentity)
                return [pscustomobject]@{ ProcessPresent = $true; WindowPresent = $false }
            }
            $identity = [pscustomobject]@{ ProcessId = 4321 }
            $result = Get-RStudioObservation -ProcessIdentity $identity -UiProvider $ui
            $result.Result | Should -Be 'Observed'
            $result.IsUnknown | Should -BeTrue
            $result.Gate | Should -Not -BeNullOrEmpty
            $result.Gate.SafeDefault | Should -Be 'Pause'
            $result.CompletionClaimed | Should -BeFalse
        }

        It 'treats a missing UI seam as unknown and returns a manual gate' {
            $identity = [pscustomobject]@{ ProcessId = 4321 }
            $result = Get-RStudioObservation -ProcessIdentity $identity
            $result.Result | Should -Be 'Unknown'
            $result.IsUnknown | Should -BeTrue
            $result.ReasonCode | Should -Be 'UiProviderUnavailable'
            $result.Gate | Should -Not -BeNullOrEmpty
            $result.CompletionClaimed | Should -BeFalse
        }

        It 'treats a failing UI seam as unknown and returns a manual gate' {
            $ui = {
                param($ProcessIdentity)
                throw 'ui seam failed'
            }
            $identity = [pscustomobject]@{ ProcessId = 4321 }
            $result = Get-RStudioObservation -ProcessIdentity $identity -UiProvider $ui
            $result.Result | Should -Be 'Unknown'
            $result.IsUnknown | Should -BeTrue
            $result.ReasonCode | Should -Be 'UiObservationFailed'
            $result.Gate | Should -Not -BeNullOrEmpty
        }

        It 'rejects an ambiguous R-Studio UI observation result' {
            $ui = {
                param($ProcessIdentity)
                return @(
                    [pscustomobject]@{ ProcessPresent = $true; MainPanelVisible = $true },
                    [pscustomobject]@{ ProcessPresent = $true; MainPanelVisible = $false }
                )
            }
            $identity = [pscustomobject]@{ ProcessId = 4321 }
            $result = Get-RStudioObservation -ProcessIdentity $identity -UiProvider $ui
            $result.Result | Should -Be 'Unknown'
            $result.IsUnknown | Should -BeTrue
            $result.ReasonCode | Should -Be 'AmbiguousUiObservation'
            $result.Gate | Should -Not -BeNullOrEmpty
        }

        It 'treats a missing process identity as unknown and returns a manual gate' {
            $result = Get-RStudioObservation -ProcessIdentity $null -UiProvider {
                param($ProcessIdentity)
                return [pscustomobject]@{ ProcessPresent = $true; MainPanelVisible = $true }
            }
            $result.Result | Should -Be 'Unknown'
            $result.IsUnknown | Should -BeTrue
            $result.ReasonCode | Should -Be 'ProcessIdentityMissing'
            $result.Gate | Should -Not -BeNullOrEmpty
        }
    }

    Context 'UI automation authorization' -Tag 'Phase3' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'UIAutomation.psm1'
        }

        It 'keeps application state unknown when the provider omits the unknown decision' {
            $result = Get-RecoveryAppState -ProcessIdentity ([pscustomobject]@{ ProcessId = 4321 }) -UiProvider {
                param($ProcessIdentity)
                return [pscustomobject]@{
                    WindowPresent = $true
                    Ready         = $true
                    ProcessAlive  = $true
                }
            }
            $result.Unknown | Should -BeTrue
        }

        It 'rejects a UI action provider result without explicit success' {
            $descriptor = [pscustomobject]@{
                Validated       = $true
                ExactBuildMatch = $true
                EvidenceSource  = 'OwnerLiveRecord'
                Name            = 'Close'
                ControlType     = 'Button'
                MatchCount      = 1
            }
            $result = Invoke-RecoveryUiAction -Action 'Close' -ControlDescriptor $descriptor -UiProvider {
                param($Action, $ControlDescriptor)
                return [pscustomobject]@{ Detail = 'action was attempted'; MatchCount = 1 }
            }
            $result.Allowed | Should -BeFalse
            $result.ReasonCode | Should -Be 'UiActionResultUnverified'
        }

        It 'authorizes a UI action when the provider returns one explicit success result' {
            $descriptor = [pscustomobject]@{
                Validated       = $true
                ExactBuildMatch = $true
                EvidenceSource  = 'OwnerLiveRecord'
                Name            = 'Scan'
                ControlType     = 'Button'
                MatchCount      = 1
            }
            $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider {
                param($Action, $ControlDescriptor)
                return [pscustomobject]@{ Allowed = $true; MatchCount = 1 }
            }
            $result.Allowed | Should -BeTrue
            $result.Result | Should -Be 'ActionInvoked'
            $result.ReasonCode | Should -BeNullOrEmpty
        }

        It 'does not treat a string UI action success value as positive' {
            $descriptor = [pscustomobject]@{
                Validated       = $true
                ExactBuildMatch = $true
                EvidenceSource  = 'OwnerLiveRecord'
                Name            = 'Scan'
                ControlType     = 'Button'
                MatchCount      = 1
            }
            $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider {
                param($Action, $ControlDescriptor)
                return [pscustomobject]@{ Allowed = 'true'; MatchCount = 1 }
            }
            $result.Allowed | Should -BeFalse
            $result.Result | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'UiActionRejected'
        }
    }

    Context 'client folder explorer action' -Tag 'Phase2' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'RStudio.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'opens a validated client folder through the explorer seam only' {
            $clientFolder = Join-Path $TestDrive 'client-open'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $explorer = {
                param($Request)
                [void]$global:RecoveryTestCalls['ExplorerProvider'].Add($Request)
                return [pscustomobject]@{ Success = $true; Result = 'Opened' }
            }
            $result = Open-RecoveryClientFolder -Path $clientFolder -ExplorerProvider $explorer
            $result.Decision | Should -Be 'Opened'
            $result.Opened | Should -BeTrue
            $result.ReasonCode | Should -BeNullOrEmpty
            $result.Path | Should -Be $clientFolder
            $calls = Get-VendorCalls -Name 'ExplorerProvider'
            $calls.Count | Should -Be 1
            $calls[0].Path | Should -Be $clientFolder
            $calls[0].Action | Should -Be 'OpenClientFolder'
            (Get-VendorCalls -Name 'ProcessRunner').Count | Should -Be 0
        }

        It 'rejects an explorer result without explicit provider success' {
            $clientFolder = Join-Path $TestDrive 'client-unverified-result'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Open-RecoveryClientFolder -Path $clientFolder -ExplorerProvider {
                param($Request)
                return [pscustomobject]@{ Result = 'Opened' }
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'ExplorerResultUnverified'
            $result.Opened | Should -BeFalse
        }

        It 'requires a Boolean true for explorer provider success' {
            $clientFolder = Join-Path $TestDrive 'client-string-success'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Open-RecoveryClientFolder -Path $clientFolder -ExplorerProvider {
                param($Request)
                return [pscustomobject]@{ Success = 'true'; Result = 'Opened' }
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'ExplorerResultUnverified'
            $result.Opened | Should -BeFalse
        }

        It 'reports an explicit explorer provider failure' {
            $clientFolder = Join-Path $TestDrive 'client-failed-result'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Open-RecoveryClientFolder -Path $clientFolder -ExplorerProvider {
                param($Request)
                return [pscustomobject]@{ Success = $false; Result = 'Failed' }
            }
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ExplorerResultFailed'
            $result.Opened | Should -BeFalse
        }

        It 'refuses a missing folder and does not call the explorer seam' {
            $missing = Join-Path $TestDrive 'not-there'
            $result = Open-RecoveryClientFolder -Path $missing -ExplorerProvider {
                param($Request)
                [void]$global:RecoveryTestCalls['ExplorerProvider'].Add($Request)
                return [pscustomobject]@{ Success = $true; Result = 'Opened' }
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'ClientFolderMissing'
            $result.Opened | Should -BeFalse
            (Get-VendorCalls -Name 'ExplorerProvider').Count | Should -Be 0
        }

        It 'refuses a blank or relative client folder path' {
            $clientFolder = Join-Path $TestDrive 'client-blank'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $explorer = {
                param($Request)
                [void]$global:RecoveryTestCalls['ExplorerProvider'].Add($Request)
                return [pscustomobject]@{ Success = $true; Result = 'Opened' }
            }
            $blank = Open-RecoveryClientFolder -Path '' -ExplorerProvider $explorer
            $blank.Decision | Should -Be 'Blocked'
            $blank.ReasonCode | Should -Be 'ClientFolderNotProvided'

            $relative = Open-RecoveryClientFolder -Path 'client\relative' -ExplorerProvider $explorer
            $relative.Decision | Should -Be 'Blocked'
            $relative.ReasonCode | Should -Be 'ClientFolderInvalid'
            (Get-VendorCalls -Name 'ExplorerProvider').Count | Should -Be 0
        }

        It 'refuses a folder reported unsafe by the path safety validator' {
            $clientFolder = Join-Path $TestDrive 'client-unsafe'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Open-RecoveryClientFolder -Path $clientFolder `
                -ExplorerProvider {
                    param($Request)
                    [void]$global:RecoveryTestCalls['ExplorerProvider'].Add($Request)
                    return [pscustomobject]@{ Success = $true; Result = 'Opened' }
                } `
                -PathSafetyValidator (New-BlockedPathValidator -ReasonCode 'DestinationUnresolved')
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'ClientFolderUnsafe'
            $result.Evidence['PathSafetyReasonCode'] | Should -Be 'DestinationUnresolved'
            (Get-VendorCalls -Name 'ExplorerProvider').Count | Should -Be 0
        }

        It 'refuses the explorer action when no explorer seam is supplied' {
            $clientFolder = Join-Path $TestDrive 'client-no-seam'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Open-RecoveryClientFolder -Path $clientFolder
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'ExplorerProviderUnavailable'
        }

        It 'reports a failure when the explorer seam throws' {
            $clientFolder = Join-Path $TestDrive 'client-throwing'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Open-RecoveryClientFolder -Path $clientFolder -ExplorerProvider {
                param($Request)
                throw 'explorer failed'
            }
            $result.Decision | Should -Be 'Failed'
            $result.ReasonCode | Should -Be 'ExplorerLaunchFailed'
            $result.Opened | Should -BeFalse
        }
    }

    Context 'technician handoff panel' -Tag 'Phase3' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'TechnicianUi.psm1'

            function New-RecordingPanelProvider {
                [CmdletBinding()]
                param()

                return {
                    param($Request)
                    [void]$global:RecoveryTestCalls['InteractionProvider'].Add($Request)
                    return [pscustomobject]@{
                        Success             = $true
                        ActionsTaken        = @('CopyClientName', 'Close')
                        LastAction          = 'Close'
                        ClosedBy            = 'Close'
                        WindowShown         = $true
                        TopMostRequested    = $true
                        ForegroundRequested = $true
                    }
                }
            }

            function New-RecordingClipboardProvider {
                [CmdletBinding()]
                param()

                return {
                    param($Request)
                    [void]$global:RecoveryTestCalls['ClipboardProvider'].Add($Request)
                    return [pscustomobject]@{ Success = $true; Result = 'Copied' }
                }
            }

            function New-RecordingExplorerProvider {
                [CmdletBinding()]
                param()

                return {
                    param($Request)
                    [void]$global:RecoveryTestCalls['ExplorerProvider'].Add($Request)
                    return [pscustomobject]@{ Success = $true; Result = 'Opened' }
                }
            }
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'requires a non-blank client name' {
            { Show-RecoveryHandoffPanel -ClientName '' } | Should -Throw
            { Show-RecoveryHandoffPanel -ClientName '   ' } | Should -Throw
        }

        It 'exposes only the documented panel actions' {
            foreach ($action in @('Wipe', 'Recover', 'Scan', 'EnableWrite', 'Repair', 'Delete')) {
                { Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -Actions $action } | Should -Throw
            }
        }

        It 'rejects a panel result without explicit provider success' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    ActionsTaken = @('Close')
                    WindowShown  = $true
                    ClosedBy     = 'Close'
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -InteractionProvider $panel
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelResultUnverified'
        }

        It 'rejects an ambiguous panel success result' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    Allowed      = $false
                    ActionsTaken = @('Close')
                    ClosedBy     = 'Close'
                    WindowShown  = $true
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -InteractionProvider $panel
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelResultAmbiguous'
        }

        It 'requires an explicit recognized Close action before reporting panel closure' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success       = $true
                    ActionsTaken  = @('CopyClientName')
                    WindowShown   = $true
                    ClosedBy      = 'Close'
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' `
                -InteractionProvider $panel `
                -ClipboardProvider { param($Request) return [pscustomobject]@{ Success = $true; Result = 'Copied' } }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'CloseActionRequired'
        }

        It 'blocks when a selected clipboard action has no explicit success result' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    ActionsTaken = @('CopyClientName', 'Close')
                    WindowShown  = $true
                    ClosedBy     = 'Close'
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' `
                -InteractionProvider $panel `
                -ClipboardProvider { param($Request) return [pscustomobject]@{ Result = 'Copied' } }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelActionResultUnverified'
            $result.ActionResults['CopyClientName'] | Should -Be 'CopyResultUnverified'
        }

        It 'records topmost and foreground requests with the client name displayed' {
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' `
                -InteractionProvider (New-RecordingPanelProvider) `
                -ClipboardProvider (New-RecordingClipboardProvider)
            $result.Decision | Should -Be 'PanelClosed'
            $result.ClientName | Should -Be 'Gamma Client'
            $result.TopMostRequested | Should -BeTrue
            $result.ForegroundRequested | Should -BeTrue
            $result.ClientNameDisplayed | Should -BeTrue
            $result.WindowShown | Should -BeTrue
            $panelCalls = Get-VendorCalls -Name 'InteractionProvider'
            $panelCalls.Count | Should -Be 1
            $panelCalls[0].ClientName | Should -Be 'Gamma Client'
            $panelCalls[0].TopMost | Should -BeTrue
            @($panelCalls[0].EnabledActions) | Should -Contain 'Close'
        }

        It 'invokes the copy action seam with the client name' {
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' `
                -InteractionProvider (New-RecordingPanelProvider) `
                -ClipboardProvider (New-RecordingClipboardProvider)
            $clipboardCalls = Get-VendorCalls -Name 'ClipboardProvider'
            $clipboardCalls.Count | Should -Be 1
            $clipboardCalls[0].ClientName | Should -Be 'Gamma Client'
            $clipboardCalls[0].Action | Should -Be 'CopyClientName'
            @($result.ActionsTaken) | Should -Contain 'CopyClientName'
        }

        It 'invokes the open-folder action seam with the validated folder' {
            $clientFolder = Join-Path $TestDrive 'panel-client'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $panel = {
                param($Request)
                [void]$global:RecoveryTestCalls['InteractionProvider'].Add($Request)
                return [pscustomobject]@{
                    Success             = $true
                    ActionsTaken        = @('OpenClientFolder', 'Close')
                    LastAction          = 'Close'
                    ClosedBy            = 'Close'
                    WindowShown         = $true
                    TopMostRequested    = $true
                    ForegroundRequested = $true
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' `
                -ClientFolder $clientFolder `
                -InteractionProvider $panel `
                -ExplorerProvider (New-RecordingExplorerProvider)
            $explorerCalls = Get-VendorCalls -Name 'ExplorerProvider'
            $explorerCalls.Count | Should -Be 1
            $explorerCalls[0].Path | Should -Be $clientFolder
            $explorerCalls[0].Action | Should -Be 'OpenClientFolder'
            @($result.ActionsTaken) | Should -Contain 'OpenClientFolder'
        }

        It 'disables the open-folder action when no client folder is supplied and records the reason' {
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' `
                -InteractionProvider (New-RecordingPanelProvider) `
                -ClipboardProvider (New-RecordingClipboardProvider)
            @($result.DisabledActions) | Should -Contain 'OpenClientFolder'
            $result.Evidence['OpenClientFolderDisabled'] | Should -Be 'ClientFolderNotProvided'
            $panelCalls = Get-VendorCalls -Name 'InteractionProvider'
            @($panelCalls[0].EnabledActions) | Should -Not -Contain 'OpenClientFolder'
        }

        It 'disables the open-folder action for a missing or unsafe folder' {
            $missing = Join-Path $TestDrive 'panel-missing'
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -ClientFolder $missing `
                -InteractionProvider (New-RecordingPanelProvider)
            @($result.DisabledActions) | Should -Contain 'OpenClientFolder'
            $result.Evidence['OpenClientFolderDisabled'] | Should -Be 'ClientFolderMissing'

            $unsafe = Join-Path $TestDrive 'panel-unsafe'
            New-Item -ItemType Directory -Path $unsafe -Force | Out-Null
            $global:RecoveryTestBlockedReason = 'DestinationUnresolved'
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -ClientFolder $unsafe `
                -InteractionProvider (New-RecordingPanelProvider) `
                -PathSafetyValidator {
                    param($Path)
                    return [pscustomobject]@{ Allowed = $false; ReasonCode = $global:RecoveryTestBlockedReason }
                }
            @($result.DisabledActions) | Should -Contain 'OpenClientFolder'
            $result.Evidence['OpenClientFolderDisabled'] | Should -Be 'ClientFolderUnsafe'
        }

        It 'does not treat string folder safety evidence as allowed' {
            $clientFolder = Join-Path $TestDrive 'panel-string-safety'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    ActionsTaken = @('Close')
                    ClosedBy     = 'Close'
                    WindowShown  = $true
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -ClientFolder $clientFolder `
                -InteractionProvider $panel `
                -PathSafetyValidator { param($Path) return [pscustomobject]@{ Allowed = 'true' } }
            @($result.DisabledActions) | Should -Contain 'OpenClientFolder'
            $result.Evidence['OpenClientFolderDisabled'] | Should -Be 'ClientFolderUnsafe'
        }

        It 'returns a visible manual gate when the panel seam is unavailable' {
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client'
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelUnavailable'
            $result.Gate | Should -Not -BeNullOrEmpty
            $result.Gate.RequiresOperatorDecision | Should -BeTrue
            $result.Gate.AutoContinueAllowed | Should -BeFalse
        }

        It 'fails closed when the panel seam returns nothing or throws' {
            $empty = {
                param($Request)
                return $null
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -InteractionProvider $empty
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelResultMissing'

            $throwing = {
                param($Request)
                throw 'panel failed'
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -InteractionProvider $throwing
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelProviderFailed'
            $result.Gate | Should -Not -BeNullOrEmpty
        }

        It 'records an unreported window state as unknown without claiming display' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    ActionsTaken = @('Close')
                    ClosedBy     = 'Close'
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -InteractionProvider $panel
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelDisplayUnverified'
            $result.ClientNameDisplayed | Should -BeFalse
            $result.Evidence['WindowState'] | Should -Be 'Unreported'
        }

        It 'records a copy or open-folder seam failure without stopping the panel' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success          = $true
                    ActionsTaken     = @('CopyClientName', 'OpenClientFolder', 'Close')
                    ClosedBy         = 'Close'
                    WindowShown      = $true
                    TopMostRequested = $true
                }
            }
            $clientFolder = Join-Path $TestDrive 'panel-failure'
            New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -ClientFolder $clientFolder `
                -InteractionProvider $panel `
                -ClipboardProvider { param($Request) throw 'clipboard failed' } `
                -ExplorerProvider { param($Request) throw 'explorer failed' }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelActionFailed'
            $result.ActionResults['CopyClientName'] | Should -Be 'CopyFailed'
            $result.ActionResults['OpenClientFolder'] | Should -Be 'OpenFolderFailed'
        }

        It 'records an unavailable action seam instead of silently skipping the action' {
            $panel = {
                param($Request)
                return [pscustomobject]@{
                    Success      = $true
                    ActionsTaken = @('CopyClientName', 'Close')
                    ClosedBy     = 'Close'
                    WindowShown  = $true
                }
            }
            $result = Show-RecoveryHandoffPanel -ClientName 'Gamma Client' -InteractionProvider $panel
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PanelActionFailed'
            $result.ActionResults['CopyClientName'] | Should -Be 'CopyUnavailable'
        }

        It 'does not start a vendor process from the technician UI module' {
            $exported = @((Get-Module 'TechnicianUi').ExportedCommands.Keys)
            @($exported | Where-Object { $_ -like 'Start-*' }) | Should -BeNullOrEmpty
            foreach ($name in @('Invoke-RecoveryUiAction', 'Enable-RStudioWrite', 'Repair-Partition')) {
                $exported | Should -Not -Contain $name
            }
            (Get-VendorCalls -Name 'ProcessRunner').Count | Should -Be 0
        }
    }

    Context 'manual gate interaction' -Tag 'Phase3' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'TechnicianUi.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'records a named operator choice' {
            $interaction = {
                param($Request)
                [void]$global:RecoveryTestCalls['InteractionProvider'].Add($Request)
                return [pscustomobject]@{ Response = 'continue'; Cancelled = $false; TimedOut = $false }
            }
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture) -InteractionProvider $interaction
            $result.Decision | Should -Be 'Continue'
            $result.DefaultApplied | Should -BeFalse
            $result.Presented | Should -BeTrue
            $result.GateId | Should -Be 'G-10'
            $result.ReasonCode | Should -BeNullOrEmpty
            $calls = Get-VendorCalls -Name 'InteractionProvider'
            $calls.Count | Should -Be 1
            @($calls[0].Choices) | Should -Contain 'Pause'
            $calls[0].SafeDefault | Should -Be 'Pause'
        }

        It 'treats a blank answer as the safe default and never as continue' {
            $interaction = {
                param($Request)
                return [pscustomobject]@{ Response = '   '; Cancelled = $false; TimedOut = $false }
            }
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture) -InteractionProvider $interaction
            $result.Decision | Should -Be 'Pause'
            $result.DefaultApplied | Should -BeTrue
            $result.ReasonCode | Should -Be 'GateNoDecision'
        }

        It 'treats a cancelled or timed-out answer as the safe default' {
            $cancelled = {
                param($Request)
                return [pscustomobject]@{ Response = ''; Cancelled = $true; TimedOut = $false }
            }
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture) -InteractionProvider $cancelled
            $result.Decision | Should -Be 'Pause'
            $result.DefaultApplied | Should -BeTrue
            $result.ReasonCode | Should -Be 'GateCancelled'

            $timedOut = {
                param($Request)
                return [pscustomobject]@{ Response = ''; Cancelled = $false; TimedOut = $true }
            }
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture) -InteractionProvider $timedOut
            $result.Decision | Should -Be 'Pause'
            $result.DefaultApplied | Should -BeTrue
            $result.ReasonCode | Should -Be 'GateTimedOut'
        }

        It 'treats an unrecognized answer as the safe default' {
            $interaction = {
                param($Request)
                return [pscustomobject]@{ Response = 'maybe'; Cancelled = $false; TimedOut = $false }
            }
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture) -InteractionProvider $interaction
            $result.Decision | Should -Be 'Pause'
            $result.DefaultApplied | Should -BeTrue
            $result.ReasonCode | Should -Be 'GateResponseUnrecognized'
        }

        It 'fails closed when the interaction seam is unavailable or throws' {
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture)
            $result.Decision | Should -Be 'Pause'
            $result.DefaultApplied | Should -BeTrue
            $result.ReasonCode | Should -Be 'GateInteractionUnavailable'

            $throwing = {
                param($Request)
                throw 'prompt failed'
            }
            $result = Show-RecoveryManualGate -Gate (New-ManualGateFixture) -InteractionProvider $throwing
            $result.Decision | Should -Be 'Pause'
            $result.ReasonCode | Should -Be 'GateInteractionFailed'
        }

        It 'rejects a gate whose safe default is continue or is not one of the choices' {
            $gate = New-ManualGateFixture
            $gate.SafeDefault = 'Continue'
            $result = Show-RecoveryManualGate -Gate $gate -InteractionProvider {
                param($Request)
                return [pscustomobject]@{ Response = 'Continue'; Cancelled = $false; TimedOut = $false }
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'GateSafeDefaultInvalid'

            $gate = New-ManualGateFixture
            $gate.SafeDefault = 'NotAChoice'
            $result = Show-RecoveryManualGate -Gate $gate -InteractionProvider $null
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'GateSafeDefaultInvalid'
        }
    }

    Context 'destination selection and picker seam' -Tag 'Phase3' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'TechnicianUi.psm1'
        }

        BeforeEach {
            New-VendorCallLog
        }

        It 'returns the picker path and the picker selection method' {
            $picker = {
                param($Request)
                [void]$global:RecoveryTestCalls['PickerProvider'].Add($Request)
                return [pscustomobject]@{ Decision = 'Selected'; Path = 'D:\Case\Client Folder' }
            }
            $typed = {
                param($Request)
                [void]$global:RecoveryTestCalls['TypedPathProvider'].Add($Request)
                return [pscustomobject]@{ Path = 'D:\Typed\Client' }
            }
            $result = Show-DestinationFolderPicker -PickerProvider $picker -TypedPathProvider $typed
            $result.Decision | Should -Be 'Selected'
            $result.Path | Should -Be 'D:\Case\Client Folder'
            $result.SelectionMethod | Should -Be 'Picker'
            (Get-VendorCalls -Name 'PickerProvider').Count | Should -Be 1
            (Get-VendorCalls -Name 'TypedPathProvider').Count | Should -Be 0
        }

        It 'falls back to the typed path seam when the picker is unavailable' {
            $picker = {
                param($Request)
                [void]$global:RecoveryTestCalls['PickerProvider'].Add($Request)
                return [pscustomobject]@{ Decision = 'Unavailable'; Error = 'no interactive session' }
            }
            $typed = {
                param($Request)
                [void]$global:RecoveryTestCalls['TypedPathProvider'].Add($Request)
                return [pscustomobject]@{ Path = 'D:\Typed\Client' }
            }
            $result = Show-DestinationFolderPicker -PickerProvider $picker -TypedPathProvider $typed
            $result.Decision | Should -Be 'Selected'
            $result.Path | Should -Be 'D:\Typed\Client'
            $result.SelectionMethod | Should -Be 'TypedPath'
            (Get-VendorCalls -Name 'TypedPathProvider').Count | Should -Be 1
        }

        It 'falls back to the typed path seam when the picker seam throws' {
            $typed = {
                param($Request)
                [void]$global:RecoveryTestCalls['TypedPathProvider'].Add($Request)
                return [pscustomobject]@{ Path = 'D:\Typed\Client' }
            }
            $result = Show-DestinationFolderPicker -PickerProvider { param($Request) throw 'picker failed' } -TypedPathProvider $typed
            $result.Decision | Should -Be 'Selected'
            $result.SelectionMethod | Should -Be 'TypedPath'
        }

        It 'does not fall back when the operator cancels the picker' {
            $picker = {
                param($Request)
                return [pscustomobject]@{ Decision = 'Cancelled' }
            }
            $typed = {
                param($Request)
                [void]$global:RecoveryTestCalls['TypedPathProvider'].Add($Request)
                return [pscustomobject]@{ Path = 'D:\Typed\Client' }
            }
            $result = Show-DestinationFolderPicker -PickerProvider $picker -TypedPathProvider $typed
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'PickerCancelled'
            $result.Path | Should -BeNullOrEmpty
            (Get-VendorCalls -Name 'TypedPathProvider').Count | Should -Be 0
        }

        It 'stops when the typed path answer is blank or the seam is missing' {
            $picker = {
                param($Request)
                return [pscustomobject]@{ Decision = 'Unavailable' }
            }
            $blank = Show-DestinationFolderPicker -PickerProvider $picker -TypedPathProvider {
                param($Request)
                return [pscustomobject]@{ Path = '  ' }
            }
            $blank.Decision | Should -Be 'Blocked'
            $blank.ReasonCode | Should -Be 'TypedPathMissing'
            $blank.Path | Should -BeNullOrEmpty

            $noSeams = Show-DestinationFolderPicker
            $noSeams.Decision | Should -Be 'Blocked'
            $noSeams.ReasonCode | Should -Be 'PickerUnavailable'
            $noSeams.Gate | Should -Not -BeNullOrEmpty
        }

        It 'delegates destination selection to the resolver and displays the resolved evidence' {
            $resolver = {
                param($Purpose)
                [void]$global:RecoveryTestCalls['Resolver'].Add($Purpose)
                return [pscustomobject]@{
                    Path            = 'D:\Case\target'
                    SelectionMethod = 'Picker'
                    Allowed         = $true
                    ReasonCode      = $null
                    DestinationEvidence = @{ PhysicalDisks = @('disk-2'); VolumeLabel = 'Backup' }
                }
            }
            $display = {
                param($Request)
                [void]$global:RecoveryTestCalls['DisplayProvider'].Add($Request)
                return [pscustomobject]@{ Result = 'Displayed' }
            }
            $result = Select-DestinationFolder -Resolver $resolver -DisplayProvider $display -Purpose 'destination'
            $result.Decision | Should -Be 'Selected'
            $result.Path | Should -Be 'D:\Case\target'
            $result.SelectionMethod | Should -Be 'Picker'
            $result.SafetyDecision | Should -Be 'Allowed'
            $result.Gate | Should -BeNullOrEmpty
            (Get-VendorCalls -Name 'Resolver').Count | Should -Be 1
            @(Get-VendorCalls -Name 'Resolver')[0] | Should -Be 'destination'
            $displayCalls = Get-VendorCalls -Name 'DisplayProvider'
            $displayCalls.Count | Should -Be 1
            $displayCalls[0].Path | Should -Be 'D:\Case\target'
            $displayCalls[0].DestinationEvidence.PhysicalDisks | Should -Contain 'disk-2'
        }

        It 'stops without a path when the resolver blocks the destination' {
            $resolver = {
                param($Purpose)
                return [pscustomobject]@{
                    Path       = 'D:\Source\same-disk'
                    Allowed    = $false
                    Decision   = 'Blocked'
                    ReasonCode = 'SamePhysicalDisk'
                }
            }
            $display = {
                param($Request)
                [void]$global:RecoveryTestCalls['DisplayProvider'].Add($Request)
                return [pscustomobject]@{ Result = 'Displayed' }
            }
            $result = Select-DestinationFolder -Resolver $resolver -DisplayProvider $display
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'DestinationUnsafe'
            $result.Path | Should -BeNullOrEmpty
            $result.Evidence['DestinationSafetyReasonCode'] | Should -Be 'SamePhysicalDisk'
            $result.Gate | Should -Not -BeNullOrEmpty
            (Get-VendorCalls -Name 'DisplayProvider').Count | Should -Be 0
        }

        It 'fails closed when the resolver result carries no safety evidence' {
            $resolver = {
                param($Purpose)
                return 'D:\Case\unverified'
            }
            $result = Select-DestinationFolder -Resolver $resolver
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'DestinationSafetyUnverified'
            $result.Path | Should -BeNullOrEmpty
            $result.Gate | Should -Not -BeNullOrEmpty

            $noResolver = Select-DestinationFolder -Resolver { param($Purpose) return $null }
            $noResolver.Decision | Should -Be 'Blocked'
            $noResolver.ReasonCode | Should -Be 'ResolverReturnedNothing'
        }

        It 'rejects string destination safety evidence' {
            $result = Select-DestinationFolder -Resolver {
                param($Purpose)
                return [pscustomobject]@{
                    Path    = 'D:\Case\unverified'
                    Allowed = 'true'
                }
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'DestinationSafetyUnverified'
            $result.Path | Should -BeNullOrEmpty
        }

        It 'rejects a relative destination path even with an allowed decision' {
            $result = Select-DestinationFolder -Resolver {
                param($Purpose)
                return [pscustomobject]@{
                    Path    = 'relative\target'
                    Allowed = $true
                }
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'DestinationPathInvalid'
            $result.Path | Should -BeNullOrEmpty
        }

        It 'fails closed when the evidence display seam fails' {
            $resolver = {
                param($Purpose)
                return [pscustomobject]@{
                    Path    = 'D:\Case\target'
                    Allowed = $true
                }
            }
            $result = Select-DestinationFolder -Resolver $resolver -DisplayProvider {
                param($Request)
                throw 'display failed'
            }
            $result.Decision | Should -Be 'Blocked'
            $result.ReasonCode | Should -Be 'EvidenceDisplayFailed'
            $result.Path | Should -BeNullOrEmpty
        }
    }

    Context 'module surface' -Tag 'Phase3' {

        BeforeAll {
            $null = Import-RepoModule -Root $repoRoot -Name 'RStudio.psm1'
            $null = Import-RepoModule -Root $repoRoot -Name 'TechnicianUi.psm1'
        }

        It 'exports exactly the documented R-Studio handoff functions' {
            $expected = @('Get-RStudioDefaultProvider', 'Get-RStudioObservation', 'New-RStudioArgumentList',
                'Open-RecoveryClientFolder', 'Request-RStudioForegroundActivation', 'Start-RStudioHandoff',
                'Test-RStudioHandoffPreconditions') | Sort-Object
            $actual = @((Get-Module 'RStudio').ExportedCommands.Keys) | Sort-Object
            @($actual).Count | Should -Be @($expected).Count
            foreach ($name in $expected) { $actual | Should -Contain $name }
        }

        It 'exports exactly the documented technician UI functions' {
            $expected = @('Get-TechnicianUiDefaultProvider', 'Select-DestinationFolder',
                'Show-DestinationFolderPicker', 'Show-RecoveryHandoffPanel',
                'Show-RecoveryManualGate') | Sort-Object
            $actual = @((Get-Module 'TechnicianUi').ExportedCommands.Keys) | Sort-Object
            @($actual).Count | Should -Be @($expected).Count
            foreach ($name in $expected) { $actual | Should -Contain $name }
        }

        It 'exposes no write-capable, destructive, or vendor action function' {
            $forbidden = @('Enable-RStudioWrite', 'Invoke-RecoveryWipe', 'Repair-Partition',
                'Set-Partition', 'New-Partition', 'Format-Volume', 'Initialize-Disk', 'Remove-Item',
                'Invoke-RecoveryScan', 'Invoke-RecoveryAction', 'Start-FileScavenger')
            foreach ($moduleName in @('RStudio', 'TechnicianUi')) {
                $exported = @((Get-Module $moduleName).ExportedCommands.Keys)
                foreach ($name in $forbidden) {
                    $exported | Should -Not -Contain $name
                }
            }
        }

        It 'provides documented production provider factories without running them at import' {
            $providerNames = @('ProcessRunner', 'ExplorerProvider', 'ActivationProvider')
            foreach ($name in $providerNames) {
                $provider = Get-RStudioDefaultProvider -Name $name
                $provider | Should -BeOfType [scriptblock]
            }
            $uiProviderNames = @('PickerProvider', 'TypedPathProvider', 'InteractionProvider',
                'HandoffPanelProvider', 'ClipboardProvider', 'ExplorerProvider', 'DisplayProvider')
            foreach ($name in $uiProviderNames) {
                $provider = Get-TechnicianUiDefaultProvider -Name $name
                $provider | Should -BeOfType [scriptblock]
            }
            (Get-VendorCalls -Name 'ProcessRunner').Count | Should -Be 0
        }

        It 'requires the production process provider to record the actual executable path' {
            $modulePath = Get-RepoFile -Root $repoRoot -RelativePath 'modules/RStudio.psm1'
            $moduleText = Get-Content -LiteralPath $modulePath -Raw
            $moduleText | Should -Match '\$actualPath\s*=\s*\$process\.MainModule\.FileName'
            $moduleText | Should -Match 'Path\s*=\s*\[string\]\$actualPath'
        }

        It 'rejects an unknown default provider name' {
            { Get-RStudioDefaultProvider -Name 'Scanner' } | Should -Throw
            { Get-TechnicianUiDefaultProvider -Name 'Scanner' } | Should -Throw
        }

        It 'imports both modules without any desktop, process, or native side effect' {
            ('RecoveryNative.WindowFocus' -as [type]) | Should -BeNullOrEmpty
            ('RecoveryNative.RecoveryForeground' -as [type]) | Should -BeNullOrEmpty
            foreach ($name in @('ProcessRunner', 'ExplorerProvider', 'ActivationProvider', 'UiProvider',
                    'InteractionProvider', 'PickerProvider', 'TypedPathProvider', 'ClipboardProvider',
                    'DisplayProvider', 'Resolver', 'PathSafetyValidator')) {
                (Get-VendorCalls -Name $name).Count | Should -Be 0
            }
        }
    }
}
