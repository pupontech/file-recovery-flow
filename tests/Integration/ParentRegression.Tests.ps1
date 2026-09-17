<#
.SYNOPSIS
    Regression contracts for the front-door, storage-provider, path-guard, and
    log-record defects that produced the Windows CI evidence.

.DESCRIPTION
    Every case here is a regression test for a confirmed defect:

      * The real -File entry point dropped -SourcePath, -DestinationPath, and
        -ClientName, so the documented technician run could not start.
      * The production disk provider required an IsDynamic statement that the
        documented MSFT_Disk schema does not define, so a real Windows disk view
        could never satisfy it.
      * A malformed member list and a reparse point were treated as proven
        membership and a proven resolved target.
      * A path containing a quote threw instead of refusing.
      * A live event log could not be read while its writer was open.

    Method: the entry point declares parameters and exits, and Pester runs each
    block in its own scope, so the production surface is exercised through child
    PowerShell processes that report JSON. That also means these contracts hold
    for the artifact a technician actually runs.

    Scope note: no session-wide strict mode is set here. Set-StrictMode affects
    the whole session, so setting it in one test file would change how every
    later file runs.
#>

$ErrorActionPreference = 'Stop'

Describe 'Front door forwards the documented technician arguments' {

    BeforeAll {
        $script:IntegrationRoot = $PSScriptRoot
        $script:RepositoryRoot = (Resolve-Path -LiteralPath ([System.IO.Path]::Combine(([System.IO.Path]::Combine($PSScriptRoot, '..')), '..'))).ProviderPath
        $script:EntryPoint = [System.IO.Path]::Combine($script:RepositoryRoot, 'RecoveryAutomation.ps1')

        function Invoke-EntryPointProcess {
            # The argument line is written as command-line text so each switch is
            # passed by name and each value is quoted exactly once.
            param([string]$ArgumentLine)
            $command = "'###JSON###'; (& '" + $script:EntryPoint + "' " + $ArgumentLine + " | ConvertTo-Json -Depth 8 -Compress)"
            $output = & (Get-Process -Id $PID).Path @('-NoProfile', '-Command', $command) 2>&1
            return (ConvertFrom-ParentRegressionMarker -Text ($output | Out-String))
        }

        function Invoke-EntryPointScript {
            param([string]$Body)
            $scriptPath = [System.IO.Path]::Combine($script:IntegrationRoot, ('parent-regression-' + [guid]::NewGuid().ToString('N') + '.ps1'))
            $prefix = '$script:EntryPointPath = "' + $script:EntryPoint + '"' + [char]10 + '. "' + $script:EntryPoint + '"' + [char]10
            [System.IO.File]::WriteAllText($scriptPath, ($prefix + $Body), (New-Object System.Text.UTF8Encoding($false)))
            try {
                $command = "'###JSON###'; (& '" + $scriptPath + "' | ConvertTo-Json -Depth 12 -Compress)"
                $output = & (Get-Process -Id $PID).Path @('-NoProfile', '-Command', $command) 2>&1
                return (ConvertFrom-ParentRegressionMarker -Text ($output | Out-String))
            }
            finally {
                if ([System.IO.File]::Exists($scriptPath)) { [System.IO.File]::Delete($scriptPath) }
            }
        }

        function Get-EntryPointSourceText {
            return [System.IO.File]::ReadAllText($script:EntryPoint)
        }

        function ConvertFrom-ParentRegressionMarker {
            param([string]$Text)
            $start = $Text.IndexOf('###JSON###')
            if ($start -lt 0) { throw ('No marked result object was produced: ' + $Text) }
            $json = $Text.Substring($start + 10)
            $brace = $json.IndexOf('{')
            if ($brace -lt 0) { throw ('No result object followed the marker: ' + $Text) }
            return ($json.Substring($brace) | ConvertFrom-Json)
        }
    }

    It 'carries -ClientName and -DestinationPath into the resolved configuration' {
        $result = Invoke-EntryPointProcess -ArgumentLine "-DryRun -NoPause -ClientName 'Front Door Client' -DestinationPath 'D:\Recovery Root'"
        $result.ExitCode | Should -Be 0
        $result.Configuration.ClientName | Should -Be 'Front Door Client'
        $result.Configuration.DestinationRoot | Should -Be 'D:\Recovery Root'
    }

    It 'reports every supplied input in its diagnostic result' {
        $result = Invoke-EntryPointProcess -ArgumentLine "-DryRun -NoPause -SourcePath 'E:\Evidence' -DestinationPath 'D:\Recovery Root' -ClientName 'Front Door Client'"
        $result.ExitCode | Should -Be 0
        $result.RequestedInputs.SourcePath | Should -Be 'E:\Evidence'
        $result.RequestedInputs.DestinationPath | Should -Be 'D:\Recovery Root'
        $result.RequestedInputs.ClientName | Should -Be 'Front Door Client'
    }

    It 'leaves every input absent when the caller supplied none' {
        $result = Invoke-EntryPointProcess -ArgumentLine '-DryRun -NoPause'
        $result.ExitCode | Should -Be 0
        $result.RequestedInputs.SourcePath | Should -BeNullOrEmpty
        $result.RequestedInputs.DestinationPath | Should -BeNullOrEmpty
        $result.RequestedInputs.ClientName | Should -BeNullOrEmpty
    }

    It 'threads the explicit arguments through the elevation argument line' {
        $result = Invoke-EntryPointScript -Body @'
$line = Get-RecoveryAutomationElevationArgumentLine -ScriptPath 'C:\case\RecoveryAutomation.ps1' -ConfigPath 'C:\case\config.json' -SourcePath 'E:\Evidence' -DestinationPath 'D:\Recovery Root' -ClientName 'Front Door Client' -NoPause
[pscustomobject]@{ Line = $line; HasHostProbe = ([System.IO.File]::ReadAllText($PSCommandPath)).Length -gt 0 }
'@
        $result.Line | Should -Match '-SourcePath'
        $result.Line | Should -Match 'E:\\Evidence'
        $result.Line | Should -Match '-DestinationPath'
        $result.Line | Should -Match 'D:\\Recovery Root'
        $result.Line | Should -Match '-ClientName'
        $result.Line | Should -Match 'Front Door Client'
        $result.Line | Should -Match '-NoPause'
        $result.Line | Should -Match '-ConfigPath'
    }

    It 'never points the vendor log switch at the JSONL case event log' {
        $source = Get-EntryPointSourceText
        $source | Should -Match 'rstudio-host\.log'
        # The handoff must not hand the case event log to a vendor switch.
        ([regex]::Matches($source, '-LogPath \$Case\.LogPath')).Count | Should -Be 0
    }

    It 'relaunches UAC elevation with the running PowerShell host through the host resolver' {
        $result = Invoke-EntryPointScript -Body @'
$entrySource = [System.IO.File]::ReadAllText($script:EntryPointPath)
[pscustomobject]@{
    CurrentProcessProbe = [bool]($entrySource -match 'GetCurrentProcess\(\)')
    HostResolverAssignments = @([regex]::Matches($entrySource, '\$powershellPath = Get-RecoveryAutomationHostExecutablePath')).Count
    FixedPshomeUses = @([regex]::Matches($entrySource, 'Combine\(\s*\$PSHOME')).Count
}
'@
        $result.CurrentProcessProbe | Should -BeTrue
        $result.HostResolverAssignments | Should -BeGreaterThan 0
        $result.FixedPshomeUses | Should -BeLessOrEqual 1
    }
}

Describe 'Production storage provider accepts the documented Windows disk view' {

    BeforeAll {
        $script:RepositoryRoot = (Resolve-Path -LiteralPath ([System.IO.Path]::Combine(([System.IO.Path]::Combine($PSScriptRoot, '..')), '..'))).ProviderPath
        $script:EntryPoint = [System.IO.Path]::Combine($script:RepositoryRoot, 'RecoveryAutomation.ps1')

        function Invoke-EntryPointScript {
            param([string]$Body)
            $scriptPath = [System.IO.Path]::Combine($PSScriptRoot, ('parent-regression-' + [guid]::NewGuid().ToString('N') + '.ps1'))
            $prefix = '. "' + $script:EntryPoint + '"' + [char]10
            [System.IO.File]::WriteAllText($scriptPath, ($prefix + $Body), (New-Object System.Text.UTF8Encoding($false)))
            try {
                $command = "'###JSON###'; (& '" + $scriptPath + "' | ConvertTo-Json -Depth 12 -Compress)"
                $output = & (Get-Process -Id $PID).Path @('-NoProfile', '-Command', $command) 2>&1
                $text = ($output | Out-String)
                $start = $text.IndexOf('###JSON###')
                if ($start -lt 0) { throw ('The probe produced no marked result: ' + $text) }
                return ($text.Substring($start + 10) | ConvertFrom-Json)
            }
            finally {
                if ([System.IO.File]::Exists($scriptPath)) { [System.IO.File]::Delete($scriptPath) }
            }
        }
    }

    It 'derives dynamic-disk evidence from the documented disk and partition fields' {
        # MSFT_Disk has no IsDynamic field. Its documented fields are Number,
        # UniqueId, UniqueIdFormat, SerialNumber, Model, Size, BusType,
        # PartitionStyle, Signature, Guid, IsOffline, IsReadOnly, IsSystem,
        # IsClustered, IsBoot, BootFromDisk, and friends; a dynamic disk is made
        # of LDM partitions, documented on MSFT_Partition as GptType 'LDM
        # Metadata' 5808c8aa-7e8f-42e0-85d2-e1e90434cfb3 and 'LDM Data'
        # af9b60a0-1431-4f62-bc68-3311714a69ad.
        $result = Invoke-EntryPointScript -Body @'
function New-DiskView { param([bool]$WithStyle, [bool]$WithDynamic)
    $disk = [pscustomobject]@{
        Number = 0; UniqueId = 'FIXTURE-UNIQUE-ID'; UniqueIdFormat = 3; SerialNumber = 'FIXTURE-SERIAL'
        Model = 'Fixture Model'; FriendlyName = 'Fixture Disk'; Manufacturer = 'Fixture Vendor'
        Size = 500107862016; BusType = 17; OperationalStatus = @('OK'); HealthStatus = 0
        NumberOfPartitions = 2
    }
    if ($WithStyle) { $disk | Add-Member -NotePropertyName PartitionStyle -NotePropertyValue 2 -Force }
    if ($WithDynamic) { $disk | Add-Member -NotePropertyName IsDynamic -NotePropertyValue $true -Force }
    return $disk
}
function Get-DiskRecord { param($Disk, $Partitions)
    $provider = New-RecoveryAutomationWindowsDiskProvider -DiskQuery { param($request) $Disk } -PartitionQuery { param($request) $Partitions }
    return @(& $provider.GetDisks @{ DiskNumber = 0 })[0]
}
$basicPartitions = @(
    [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1; GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
    [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 2; GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' }
)
$ldmPartitions = @(
    [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1; GptType = '5808c8aa-7e8f-42e0-85d2-e1e90434cfb3' }
    [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 2; GptType = 'af9b60a0-1431-4f62-bc68-3311714a69ad' }
)
$unstatedType = @([pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1 })
$mbrLdm = @(
    [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1; MbrType = 0x42 }
    [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 2; MbrType = 0x07 }
)
$documentedNoPartitions = Get-DiskRecord -Disk (New-DiskView -WithStyle $true -WithDynamic $false) -Partitions @()
$basic = Get-DiskRecord -Disk (New-DiskView -WithStyle $true -WithDynamic $false) -Partitions $basicPartitions
$dynamicStated = Get-DiskRecord -Disk (New-DiskView -WithStyle $false -WithDynamic $true) -Partitions @()
$ldm = Get-DiskRecord -Disk (New-DiskView -WithStyle $true -WithDynamic $false) -Partitions $ldmPartitions
$unstated = Get-DiskRecord -Disk (New-DiskView -WithStyle $true -WithDynamic $false) -Partitions $unstatedType
$mbr = Get-DiskRecord -Disk (New-DiskView -WithStyle $true -WithDynamic $false) -Partitions $mbrLdm
[pscustomobject]@{
    DocumentedNoPartitionEvidence = [bool]$documentedNoPartitions.MembersIncomplete
    BasicComplete = -not [bool]$basic.MembersIncomplete
    BasicEvidence = [string]$basic.BasicDiskEvidence
    BasicIsDynamic = [bool]$basic.IsDynamic
    DynamicStatedComplete = -not [bool]$dynamicStated.MembersIncomplete
    DynamicStatedIsDynamic = [bool]$dynamicStated.IsDynamic
    LdmIsDynamic = [bool]$ldm.IsDynamic
    LdmEvidence = [string]$ldm.BasicDiskEvidence
    LdmComplete = -not [bool]$ldm.MembersIncomplete
    UnstatedTypeIncomplete = [bool]$unstated.MembersIncomplete
    MbrLdmIsDynamic = [bool]$mbr.IsDynamic
}
'@
        $result.DocumentedNoPartitionEvidence | Should -BeTrue -Because 'a documented view without partition evidence is not proof of a basic disk'
        $result.BasicComplete | Should -BeTrue
        $result.BasicEvidence | Should -Be 'NoLdmPartitionPresent'
        $result.BasicIsDynamic | Should -BeFalse
        $result.DynamicStatedComplete | Should -BeTrue
        $result.DynamicStatedIsDynamic | Should -BeTrue
        $result.LdmIsDynamic | Should -BeTrue
        $result.LdmEvidence | Should -Be 'LdmPartitionPresent'
        $result.LdmComplete | Should -BeTrue
        $result.UnstatedTypeIncomplete | Should -BeTrue
        $result.MbrLdmIsDynamic | Should -BeTrue
    }

    It 'never authorizes a subset of a member list it could not parse in full, and never invents reparse resolution' {
        $result = Invoke-EntryPointScript -Body @'
$volumeQuery = { param($request) [pscustomobject]@{ UniqueId = 'fixture-volume'; DriveLetter = 'D'; PhysicalDiskNumbers = @(1, 'INVALID-MEMBER') } }
$provider = New-RecoveryAutomationWindowsDiskProvider -VolumeQuery $volumeQuery -ItemQuery { param($request) $null } -PartitionQuery { param($request) @() }
$record = & $provider.ResolvePath @{ Path = 'D:\case' }

$cleanVolumeQuery = { param($request) [pscustomobject]@{ UniqueId = 'fixture-volume'; DriveLetter = 'D'; PhysicalDiskNumbers = @(1) } }
$junctionItemQuery = { param($request) [pscustomobject]@{ FullName = 'D:\fixture-junction'; PSIsContainer = $true; Attributes = 'Directory, ReparsePoint' } }
$junctionProvider = New-RecoveryAutomationWindowsDiskProvider -VolumeQuery $cleanVolumeQuery -ItemQuery $junctionItemQuery -PartitionQuery { param($request) @() }
$junction = & $junctionProvider.ResolvePath @{ Path = 'D:\fixture-junction' }

$absentMemberVolumeQuery = { param($request) [pscustomobject]@{ UniqueId = 'fixture-volume'; DriveLetter = 'D' } }
$absentProvider = New-RecoveryAutomationWindowsDiskProvider -VolumeQuery $absentMemberVolumeQuery -ItemQuery { param($request) $null } -PartitionQuery { param($request) @() }
$absent = & $absentProvider.ResolvePath @{ Path = 'D:\case' }
[pscustomobject]@{
    SubsetIncomplete = [bool]$record.MembersIncomplete
    SubsetEvidence = [string]$record.MembershipEvidence
    JunctionIsReparse = [bool]$junction.IsReparsePoint
    JunctionResolved = [bool]$junction.ReparseResolved
    JunctionEvidence = [string]$junction.ReparseEvidence
    AbsentMembersIncomplete = [bool]$absent.MembersIncomplete
    AbsentMembersEvidence = [string]$absent.MembershipEvidence
}
'@
        $result.SubsetIncomplete | Should -BeTrue
        $result.SubsetEvidence | Should -Be 'MemberValueUnparsed'
        $result.JunctionIsReparse | Should -BeTrue
        $result.JunctionResolved | Should -BeFalse
        $result.JunctionEvidence | Should -Be 'ReparseTargetUnavailable'
        $result.AbsentMembersIncomplete | Should -BeTrue
        $result.AbsentMembersEvidence | Should -Be 'DriveLetterOnlyMembership'
    }
}

Describe 'Path guards refuse instead of throwing' {

    BeforeAll {
        $script:RepositoryRoot = (Resolve-Path -LiteralPath ([System.IO.Path]::Combine(([System.IO.Path]::Combine($PSScriptRoot, '..')), '..'))).ProviderPath
        $script:ModulesRoot = [System.IO.Path]::Combine($script:RepositoryRoot, 'modules')

        function Invoke-ModuleGuardProbe {
            param([string]$Body)
            $moduleRoot = $script:ModulesRoot
            $scriptPath = [System.IO.Path]::Combine($PSScriptRoot, ('parent-guard-' + [guid]::NewGuid().ToString('N') + '.ps1'))
            $prefix = 'Import-Module -Name "' + $moduleRoot + '\RStudio.psm1" -Force' + [char]10 +
                'Import-Module -Name "' + $moduleRoot + '\TechnicianUi.psm1" -Force' + [char]10 +
                'Import-Module -Name "' + $moduleRoot + '\ApplicationDiscovery.psm1" -Force' + [char]10
            [System.IO.File]::WriteAllText($scriptPath, ($prefix + $Body), (New-Object System.Text.UTF8Encoding($false)))
            try {
                $command = "'###JSON###'; (& '" + $scriptPath + "' | ConvertTo-Json -Depth 12 -Compress)"
                $output = & (Get-Process -Id $PID).Path @('-NoProfile', '-Command', $command) 2>&1
                $text = ($output | Out-String)
                $start = $text.IndexOf('###JSON###')
                if ($start -lt 0) { throw ('The guard probe produced no marked result: ' + $text) }
                return ($text.Substring($start + 10) | ConvertFrom-Json)
            }
            finally {
                if ([System.IO.File]::Exists($scriptPath)) { [System.IO.File]::Delete($scriptPath) }
            }
        }
    }

    It 'refuses a log path containing a quote, a wildcard, or a control character instead of throwing' {
        $result = Invoke-ModuleGuardProbe -Body @'
$quoted = New-RStudioArgumentList -LogPath 'C:\case\bad"name.log'
$wildcard = New-RStudioArgumentList -LogPath 'C:\case\bad*.log'
$control = New-RStudioArgumentList -LogPath ("C:\case\bad" + [char]1 + ".log")
$accepted = New-RStudioArgumentList -LogPath 'C:\case\good name.log'
[pscustomobject]@{
    QuotedDecision = [string]$quoted.Decision
    QuotedReason = [string]$quoted.ReasonCode
    QuotedArguments = $null -eq $quoted.Arguments
    WildcardDecision = [string]$wildcard.Decision
    ControlDecision = [string]$control.Decision
    AcceptedDecision = [string]$accepted.Decision
}
'@
        $result.QuotedDecision | Should -Be 'Blocked'
        $result.QuotedReason | Should -Be 'LogPathInvalid'
        $result.QuotedArguments | Should -BeTrue
        $result.WildcardDecision | Should -Be 'Blocked'
        $result.ControlDecision | Should -Be 'Blocked'
        $result.AcceptedDecision | Should -Be 'Ready'
    }

    It 'refuses a technician UI and an application path containing a quote without throwing' {
        $result = Invoke-ModuleGuardProbe -Body @'
$uiModule = Get-Module -Name TechnicianUi
$appModule = Get-Module -Name ApplicationDiscovery
$uiQuoted = & $uiModule { Test-TUPathText -Path 'C:\case\bad"name' }
$uiClean = & $uiModule { Test-TUPathText -Path 'C:\case\clean name' }
$appQuoted = & $appModule { Test-LiteralApplicationPath -Path 'C:\vendor\bad"name.exe' }
$appClean = & $appModule { Test-LiteralApplicationPath -Path 'C:\vendor\clean name.exe' }
$appRelative = & $appModule { Test-LiteralApplicationPath -Path 'vendor\tool.exe' }
[pscustomobject]@{
    UiQuoted = [bool]$uiQuoted; UiClean = [bool]$uiClean
    AppQuoted = [bool]$appQuoted; AppClean = [bool]$appClean; AppRelative = [bool]$appRelative
}
'@
        $result.UiQuoted | Should -BeFalse
        $result.UiClean | Should -BeTrue
        $result.AppQuoted | Should -BeFalse
        $result.AppClean | Should -BeTrue
        $result.AppRelative | Should -BeFalse
    }
}

Describe 'A live event log stays readable while its writer is open' {

    BeforeAll {
        $script:RepositoryRoot = (Resolve-Path -LiteralPath ([System.IO.Path]::Combine(([System.IO.Path]::Combine($PSScriptRoot, '..')), '..'))).ProviderPath
        $script:ModulesRoot = [System.IO.Path]::Combine($script:RepositoryRoot, 'modules')

        function Invoke-LogLivenessProbe {
            $moduleRoot = $script:ModulesRoot
            $scriptPath = [System.IO.Path]::Combine($PSScriptRoot, ('parent-log-' + [guid]::NewGuid().ToString('N') + '.ps1'))
            $body = 'Import-Module -Name "' + $moduleRoot + '\RecoveryLogging.psm1" -Force' + [char]10 + @'
$root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('recovery-live-log-' + [guid]::NewGuid().ToString('N')))
$null = [System.IO.Directory]::CreateDirectory($root)
$logPath = [System.IO.Path]::Combine($root, 'events.jsonl')
$failures = @()
$log = New-RecoveryLog -Path $logPath -JobId 'LiveLogClient_20260917-000000'
if (-not $log.Success) { $failures += ('open:' + [string]$log.ReasonCode) }
$write = Write-RecoveryLogEntry -Writer $log.Writer -Entry ([pscustomobject]@{
    JobId = 'LiveLogClient_20260917-000000'; State = 'CASE_READY'; Stage = 'PREFLIGHT'
    AttemptId = 'live-log-001'; EventType = 'CaseReady'; Result = 'Recorded' })
if (-not $write.Success) { $failures += ('write:' + [string]$write.ReasonCode) }
$validation = Test-RecoveryLog -Path $logPath -JobId 'LiveLogClient_20260917-000000'
$second = Write-RecoveryLogEntry -Writer $log.Writer -Entry ([pscustomobject]@{
    JobId = 'LiveLogClient_20260917-000000'; State = 'CASE_READY'; Stage = 'PREFLIGHT'
    AttemptId = 'live-log-002'; EventType = 'CaseReady'; Result = 'Recorded' })
if (-not $second.Success) { $failures += ('second:' + [string]$second.ReasonCode) }
$afterAppend = Test-RecoveryLog -Path $logPath -JobId 'LiveLogClient_20260917-000000'
$readable = $false
try { $readable = ([System.IO.File]::ReadAllBytes($logPath)).Length -gt 0 } catch { $failures += ('read:' + $_.Exception.Message) }
$sync = Sync-RecoveryLog -Writer $log.Writer
if (-not $sync.Success) { $failures += ('sync:' + [string]$sync.ReasonCode) }
$removed = $false
try { [System.IO.Directory]::Delete($root, $true); $removed = $true } catch { $failures += ('delete:' + $_.Exception.Message) }
[pscustomobject]@{
    Failures = @($failures)
    ValidationValid = [bool]$validation.IsValid
    ValidationReason = [string]$validation.ReasonCode
    ValidationCount = [int]$validation.EventCount
    AfterAppendValid = [bool]$afterAppend.IsValid
    AfterAppendCount = [int]$afterAppend.EventCount
    FileReadable = [bool]$readable
    Removable = [bool]$removed
}
'@
            [System.IO.File]::WriteAllText($scriptPath, $body, (New-Object System.Text.UTF8Encoding($false)))
            try {
                $command = "'###JSON###'; (& '" + $scriptPath + "' | ConvertTo-Json -Depth 12 -Compress)"
                $output = & (Get-Process -Id $PID).Path @('-NoProfile', '-Command', $command) 2>&1
                $text = ($output | Out-String)
                $start = $text.IndexOf('###JSON###')
                if ($start -lt 0) { throw ('The log probe produced no marked result: ' + $text) }
                return ($text.Substring($start + 10) | ConvertFrom-Json)
            }
            finally {
                if ([System.IO.File]::Exists($scriptPath)) { [System.IO.File]::Delete($scriptPath) }
            }
        }
    }

    It 'validates and reads the case record while the writer is still live' {
        $result = Invoke-LogLivenessProbe
        @($result.Failures) | Should -HaveCount 0
        $result.ValidationValid | Should -BeTrue -Because 'a live case record must be readable; a sharing refusal is not a valid log'
        $result.ValidationCount | Should -Be 1
        $result.AfterAppendValid | Should -BeTrue
        $result.AfterAppendCount | Should -Be 2
        $result.FileReadable | Should -BeTrue
        $result.Removable | Should -BeTrue
    }
}
