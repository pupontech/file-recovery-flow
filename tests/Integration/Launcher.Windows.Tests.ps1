<#
.SYNOPSIS
    Windows launcher integration contracts for Start-Recovery.bat (W-01 .. W-04, W-08).

.DESCRIPTION
    Exercises the real batch launcher through a real cmd.exe and implements the
    launcher rows of tests/TEST-MATRIX.md section 7 and the launcher contract of
    docs/IMPLEMENTATION-SPEC.md section 7:

      W-01 Location independence  the launcher resolves %~dp0 from a foreign working
                                  directory and reaches the entry point next to it.
      W-02 Argument fidelity      the dry-run entry point receives the exact argument
                                  sequence supplied to the batch file, in order.
      W-03 No-pause mode          -NoPause and RECOVERY_NO_PAUSE=1 both terminate a
                                  run without waiting for a redirected stdin.
      W-04 Exit-code propagation  a non-zero entry-point code reaches the invoking
                                  cmd.exe unchanged through exit /b, and a failure
                                  cannot return success.
      W-08 First Windows pause    the run without the explicit opt-out records
                                  whether a redirected stdin satisfies the closing
                                  prompt, instead of assuming either answer.

    Boundaries this file never crosses (AGENTS.md, TEST-MATRIX section 1):
      * No vendor application is installed, launched, named, or simulated here, and
        no vendor executable is referenced by name. The only processes started are
        cmd.exe and Windows PowerShell, running either the launcher or the entry
        point in its bounded -DryRun mode.
      * No disk, partition, volume, or CIM command is used. Nothing here proves or
        claims a real recovery result.
      * Every write lands under the Pester TestDrive root. The repository tree is
        read-only to this file: the launcher is copied into the scratch harness
        byte-for-byte, and that byte identity is asserted so the exercised copy can
        never silently become a different file.
      * The harness entry point is a synthetic fixture written into TestDrive. It
        records its own argument vector and returns a controlled exit code. It
        launches nothing and writes only its record file.

    Lane: Windows-5.1 (tests/TEST-MATRIX.md section 7). On a non-Windows host every
    example that needs cmd.exe reports Skip with that reason instead of a synthetic
    Pass. The entry-point presence contract and the diagnostic-detector contract run
    everywhere, so the file is never vacuous.

    The dry-run switch is not invented here: the orchestrator entry point is required
    to support -ConfigPath, -NoPause, and a bounded -DryRun path by its own task
    contract (kanban t_eaa58213) and by IMPLEMENTATION-SPEC section 7, and the CI
    workflow drives the launcher exactly this way (.github/workflows/ci.yml).
#>

Set-StrictMode -Version 2.0

Describe 'File Recovery Flow launcher integration contracts' {

    BeforeAll {
        # ------------------------------------------------------------------
        # Repository location and contract paths
        # ------------------------------------------------------------------
        $script:LauncherFileName = 'Start-Recovery.bat'
        $script:EntryPointFileName = 'RecoveryAutomation.ps1'
        $script:LaneConfigurationFileName = 'PesterConfiguration.ps1'

        # This file lives two levels below the repository root (tests/Integration), so
        # the root is resolved by walking up to the directory that carries both the
        # launcher and the shared lane configuration. That keeps the contract valid if
        # the file is ever moved inside tests/.
        $searchDirectory = ''
        if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
            $searchDirectory = $PSScriptRoot
        } elseif (-not [string]::IsNullOrEmpty($PSCommandPath)) {
            $searchDirectory = Split-Path -Path $PSCommandPath -Parent
        } else {
            $searchDirectory = (Get-Location).ProviderPath
        }

        $script:RepositoryRoot = ''
        $remainingLevels = 6
        while (($remainingLevels -gt 0) -and (-not [string]::IsNullOrEmpty($searchDirectory))) {
            $launcherMarker = Join-Path -Path $searchDirectory -ChildPath $script:LauncherFileName
            $configurationMarker = Join-Path -Path $searchDirectory -ChildPath $script:LaneConfigurationFileName
            if ((Test-Path -LiteralPath $launcherMarker -PathType Leaf) -and (Test-Path -LiteralPath $configurationMarker -PathType Leaf)) {
                $script:RepositoryRoot = $searchDirectory
                break
            }
            $parentDirectory = Split-Path -Path $searchDirectory -Parent
            if ([string]::IsNullOrEmpty($parentDirectory)) { break }
            if ($parentDirectory -eq $searchDirectory) { break }
            $searchDirectory = $parentDirectory
            $remainingLevels = $remainingLevels - 1
        }

        $script:LauncherPath = ''
        $script:EntryPointPath = ''
        if (-not [string]::IsNullOrEmpty($script:RepositoryRoot)) {
            $script:LauncherPath = Join-Path -Path $script:RepositoryRoot -ChildPath $script:LauncherFileName
            $script:EntryPointPath = Join-Path -Path $script:RepositoryRoot -ChildPath $script:EntryPointFileName
        }

        # Windows PowerShell 5.1 executable. On the pinned Windows lane this file runs
        # under powershell.exe, so $PSHOME already points at the 5.1 installation.
        $script:WindowsPowerShellExecutable = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'

        # $IsWindows does not exist in Windows PowerShell 5.1, so the host check uses
        # System.PlatformID, which is correct on 5.1 and on PowerShell 7 alike.
        $script:IsWindowsHost = $false
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $script:IsWindowsHost = $true
        }
        # COMSPEC is the documented location of the command interpreter. A
        # machine-level root literal is deliberately avoided so the non-live
        # test write-root contract (S-15) keeps holding.
        $script:CmdExecutable = [System.Environment]::GetEnvironmentVariable('ComSpec')
        if ([string]::IsNullOrEmpty($script:CmdExecutable)) {
            $script:CmdExecutable = ''
            if ($script:IsWindowsHost) { $script:CmdExecutable = 'cmd.exe' }
        }

        $script:LauncherHarnessSkipReason = ''
        if (-not $script:IsWindowsHost) {
            $script:LauncherHarnessSkipReason = 'the cmd.exe launcher contract requires a Windows host; this run is on ' + [System.Environment]::OSVersion.VersionString
        } elseif ([string]::IsNullOrEmpty($script:CmdExecutable)) {
            $script:LauncherHarnessSkipReason = 'cmd.exe could not be resolved from the COMSPEC environment variable on this host'
        } elseif (-not (Test-Path -LiteralPath $script:LauncherPath -PathType Leaf)) {
            $script:LauncherHarnessSkipReason = $script:LauncherFileName + ' is not present in the repository root'
        }

        # ------------------------------------------------------------------
        # Read-only and scratch-only helpers
        # ------------------------------------------------------------------
        function Write-HarnessTextFile {
            param(
                [Parameter(Mandatory = $true)][string] $Path,
                [Parameter(Mandatory = $true)][string] $Text
            )
            Set-Content -LiteralPath $Path -Value $Text -Encoding ASCII -ErrorAction Stop
        }

        function New-HarnessEmptyFile {
            param([Parameter(Mandatory = $true)][string] $Path)
            [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] 0))
        }

        function New-HarnessDirectory {
            param([Parameter(Mandatory = $true)][string] $Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
                $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
            }
            return $Path
        }

        # The synthetic entry point. It is a test fixture: it records the argument
        # vector it actually received and returns the exit code named by
        # RECOVERY_HARNESS_EXIT. It starts no process and reads no real disk identity.
        $script:HarnessEntryPointText = @'
# Synthetic launcher harness entry point for tests/Integration/Launcher.Windows.Tests.ps1.
# Test fixture only: written into a Pester TestDrive scratch directory, launches nothing,
# and writes only the record file named by RECOVERY_HARNESS_RECORD.
param(
    [switch] $DryRun,
    [switch] $NoPause,
    [string] $ConfigPath,
    [string] $CaseLabel
)

$recordLines = New-Object System.Collections.ArrayList
[void]$recordLines.Add('pscommandpath=' + $PSCommandPath)
[void]$recordLines.Add('currentdirectory=' + (Get-Location).ProviderPath)
[void]$recordLines.Add('dryrun=' + [string][bool]$DryRun)
[void]$recordLines.Add('nopause=' + [string][bool]$NoPause)
[void]$recordLines.Add('configpath=' + $ConfigPath)
[void]$recordLines.Add('caselabel=' + $CaseLabel)
$rawArgumentList = @([System.Environment]::GetCommandLineArgs())
[void]$recordLines.Add('rawcount=' + $rawArgumentList.Count)
foreach ($rawItem in $rawArgumentList) { [void]$recordLines.Add('raw=' + $rawItem) }
$boundArgumentList = @($args)
[void]$recordLines.Add('argcount=' + $boundArgumentList.Count)
foreach ($boundItem in $boundArgumentList) { [void]$recordLines.Add('arg=' + $boundItem) }
[System.IO.File]::WriteAllLines($env:RECOVERY_HARNESS_RECORD, @($recordLines.ToArray()))

$harnessExitCode = 0
if (-not [string]::IsNullOrEmpty($env:RECOVERY_HARNESS_EXIT)) {
    $harnessExitCode = [int]$env:RECOVERY_HARNESS_EXIT
}
Write-Output ('RECOVERY_HARNESS_ENTRY_POINT exit=' + $harnessExitCode)
exit $harnessExitCode
'@

        function New-LauncherHarness {
            param(
                [Parameter(Mandatory = $true)][string] $Name,
                [switch] $WithoutEntryPoint
            )
            $root = New-HarnessDirectory -Path (Join-Path -Path $TestDrive -ChildPath $Name)
            $launcherDirectory = New-HarnessDirectory -Path (Join-Path -Path $root -ChildPath 'launcher')
            $foreignDirectory = New-HarnessDirectory -Path (Join-Path -Path $root -ChildPath 'foreign-working-directory')
            $scratchDirectory = New-HarnessDirectory -Path (Join-Path -Path $root -ChildPath 'scratch')

            # Byte-identical copy of the reviewed launcher. The copy is asserted against
            # the repository file in the location contract below.
            $launcherCopyPath = Join-Path -Path $launcherDirectory -ChildPath $script:LauncherFileName
            [System.IO.File]::WriteAllBytes($launcherCopyPath, [System.IO.File]::ReadAllBytes($script:LauncherPath))

            $entryPointCopyPath = Join-Path -Path $launcherDirectory -ChildPath $script:EntryPointFileName
            if (-not $WithoutEntryPoint) {
                Write-HarnessTextFile -Path $entryPointCopyPath -Text $script:HarnessEntryPointText
            }

            $standardInputPath = Join-Path -Path $scratchDirectory -ChildPath 'standard-input.empty'
            New-HarnessEmptyFile -Path $standardInputPath

            $harness = New-Object -TypeName PSObject
            $harness | Add-Member -MemberType NoteProperty -Name Root -Value $root
            $harness | Add-Member -MemberType NoteProperty -Name LauncherDirectory -Value $launcherDirectory
            $harness | Add-Member -MemberType NoteProperty -Name LauncherPath -Value $launcherCopyPath
            $harness | Add-Member -MemberType NoteProperty -Name EntryPointPath -Value $entryPointCopyPath
            $harness | Add-Member -MemberType NoteProperty -Name ForeignDirectory -Value $foreignDirectory
            $harness | Add-Member -MemberType NoteProperty -Name ScratchDirectory -Value $scratchDirectory
            $harness | Add-Member -MemberType NoteProperty -Name StandardInputPath -Value $standardInputPath
            return $harness
        }

        function Invoke-HarnessCommand {
            param(
                [Parameter(Mandatory = $true)][string] $FilePath,
                [string[]] $CommandArguments = @(),
                [Parameter(Mandatory = $true)][string] $WorkingDirectory,
                [Parameter(Mandatory = $true)][string] $StandardInputPath,
                [Parameter(Mandatory = $true)][string] $ScratchDirectory,
                [string] $FileNamePrefix = 'run',
                [int] $TimeoutSeconds = 60,
                [string] $RecordPath = '',
                [int] $EntryPointExitCode = 0,
                [bool] $SetNoPauseVariable = $true
            )
            $standardOutputPath = Join-Path -Path $ScratchDirectory -ChildPath ($FileNamePrefix + '.stdout.txt')
            $standardErrorPath = Join-Path -Path $ScratchDirectory -ChildPath ($FileNamePrefix + '.stderr.txt')

            $previousRecord = [System.Environment]::GetEnvironmentVariable('RECOVERY_HARNESS_RECORD')
            $previousExit = [System.Environment]::GetEnvironmentVariable('RECOVERY_HARNESS_EXIT')
            $previousNoPause = [System.Environment]::GetEnvironmentVariable('RECOVERY_NO_PAUSE')
            try {
                if ([string]::IsNullOrEmpty($RecordPath)) {
                    [System.Environment]::SetEnvironmentVariable('RECOVERY_HARNESS_RECORD', $null)
                } else {
                    [System.Environment]::SetEnvironmentVariable('RECOVERY_HARNESS_RECORD', $RecordPath)
                }
                [System.Environment]::SetEnvironmentVariable('RECOVERY_HARNESS_EXIT', ([string]$EntryPointExitCode))
                if ($SetNoPauseVariable) {
                    [System.Environment]::SetEnvironmentVariable('RECOVERY_NO_PAUSE', '1')
                } else {
                    [System.Environment]::SetEnvironmentVariable('RECOVERY_NO_PAUSE', $null)
                }

                $startedUtc = [System.DateTime]::UtcNow
                $process = Start-Process -FilePath $FilePath -ArgumentList $CommandArguments -WorkingDirectory $WorkingDirectory -PassThru -NoNewWindow -RedirectStandardInput $StandardInputPath -RedirectStandardOutput $standardOutputPath -RedirectStandardError $standardErrorPath -ErrorAction Stop
                $completed = $process.WaitForExit($TimeoutSeconds * 1000)
                $timedOut = $false
                if (-not $completed) {
                    $timedOut = $true
                    try { $process.Kill() } catch { }
                    $process.WaitForExit()
                }
                $elapsedSeconds = ([System.DateTime]::UtcNow - $startedUtc).TotalSeconds

                $result = New-Object -TypeName PSObject
                $result | Add-Member -MemberType NoteProperty -Name TimedOut -Value $timedOut
                $result | Add-Member -MemberType NoteProperty -Name ElapsedSeconds -Value $elapsedSeconds
                $result | Add-Member -MemberType NoteProperty -Name CommandLine -Value ($FilePath + ' ' + ($CommandArguments -join ' '))
                $result | Add-Member -MemberType NoteProperty -Name WorkingDirectory -Value $WorkingDirectory
                if ($timedOut) {
                    $result | Add-Member -MemberType NoteProperty -Name ExitCode -Value $null
                } else {
                    $result | Add-Member -MemberType NoteProperty -Name ExitCode -Value $process.ExitCode
                }
                $result | Add-Member -MemberType NoteProperty -Name StandardOutput -Value (Get-HarnessFileText -Path $standardOutputPath)
                $result | Add-Member -MemberType NoteProperty -Name StandardError -Value (Get-HarnessFileText -Path $standardErrorPath)
                return $result
            } finally {
                [System.Environment]::SetEnvironmentVariable('RECOVERY_HARNESS_RECORD', $previousRecord)
                [System.Environment]::SetEnvironmentVariable('RECOVERY_HARNESS_EXIT', $previousExit)
                [System.Environment]::SetEnvironmentVariable('RECOVERY_NO_PAUSE', $previousNoPause)
            }
        }

        function Get-HarnessFileText {
            param([Parameter(Mandatory = $true)][string] $Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
            try {
                return [System.IO.File]::ReadAllText($Path)
            } catch {
                return ''
            }
        }

        function Read-HarnessRecord {
            param([Parameter(Mandatory = $true)][string] $Path)
            $rawArgumentList = New-Object System.Collections.ArrayList
            $boundArgumentList = New-Object System.Collections.ArrayList
            $values = @{}
            foreach ($line in @([System.IO.File]::ReadAllLines($Path))) {
                $separatorIndex = $line.IndexOf('=')
                if ($separatorIndex -lt 1) { continue }
                $key = $line.Substring(0, $separatorIndex)
                $value = $line.Substring($separatorIndex + 1)
                if ($key -eq 'raw') { [void]$rawArgumentList.Add($value); continue }
                if ($key -eq 'arg') { [void]$boundArgumentList.Add($value); continue }
                $values[$key] = $value
            }
            $record = New-Object -TypeName PSObject
            $record | Add-Member -MemberType NoteProperty -Name RawArguments -Value @($rawArgumentList.ToArray())
            $record | Add-Member -MemberType NoteProperty -Name BoundArguments -Value @($boundArgumentList.ToArray())
            $record | Add-Member -MemberType NoteProperty -Name Values -Value $values
            return $record
        }

        function Compare-HarnessArgumentVector {
            param(
                [string[]] $Actual = @(),
                [string[]] $Expected = @()
            )
            if ($Actual.Count -ne $Expected.Count) {
                return ('received ' + $Actual.Count + ' argument(s) but expected ' + $Expected.Count + '; received [' + ($Actual -join ' | ') + ']')
            }
            for ($index = 0; $index -lt $Expected.Count; $index++) {
                if (-not [string]::Equals($Actual[$index], $Expected[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
                    return ('argument ' + $index + ' is "' + $Actual[$index] + '" but expected "' + $Expected[$index] + '"')
                }
            }
            return ''
        }

        # Detects the two launcher-level failures this file must never misread as a
        # successful run: a host that could not find the entry point, and a host that
        # rejected the dry-run switch. Every pattern stays anchored either on the
        # entry point file name or on a host parameter-binding phrase, so a legitimate
        # preflight message about a missing configuration file cannot trigger it.
        function Test-HarnessFailureDiagnostic {
            param(
                [string] $Text = '',
                [string] $EntryPointPath = ''
            )
            if ([string]::IsNullOrEmpty($Text)) { return $false }
            if ([regex]::IsMatch($Text, 'parameter cannot be found')) { return $true }
            if ([regex]::IsMatch($Text, 'is not recognized as')) { return $true }
            if ([string]::IsNullOrEmpty($EntryPointPath)) { return $false }
            $entryPointName = [System.IO.Path]::GetFileName($EntryPointPath)
            if ([string]::IsNullOrEmpty($entryPointName)) { return $false }
            $escapedName = [regex]::Escape($entryPointName)
            foreach ($failureTerm in @('does not exist', 'not a valid path', 'inaccessible', 'cannot find', 'could not find')) {
                if ([regex]::IsMatch($Text, $escapedName + '.*' + $failureTerm)) { return $true }
                if ([regex]::IsMatch($Text, $failureTerm + '.*' + $escapedName)) { return $true }
            }
            return $false
        }

        function Get-HarnessRunDescription {
            param([Parameter(Mandatory = $true)] $Run)
            $exitText = 'none'
            if ($null -ne $Run.ExitCode) { $exitText = [string]$Run.ExitCode }
            return ('command: ' + $Run.CommandLine + ' | working directory: ' + $Run.WorkingDirectory + ' | exit code: ' + $exitText + ' | timed out: ' + [string]$Run.TimedOut + ' | stdout: ' + $Run.StandardOutput.Trim() + ' | stderr: ' + $Run.StandardError.Trim())
        }

        # ------------------------------------------------------------------
        # Harness instance used by the launcher contexts
        # ------------------------------------------------------------------
        $script:Harness = $null
        if ([string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) {
            $script:Harness = New-LauncherHarness -Name 'launcher-harness'
        }
    }

    Context 'W-04 launcher failure detector and W-01 entry point presence' {

        It 'W-01: this lane resolves the repository root and the launcher from its own location' {
            [string]::IsNullOrEmpty($script:RepositoryRoot) | Should -BeFalse -Because 'the launcher contract must locate the repository by walking up from its own directory, not from the current directory of the runner'
            (Test-Path -LiteralPath $script:LauncherPath -PathType Leaf) | Should -BeTrue -Because ('the launcher must be present at ' + $script:LauncherPath)
        }

        It 'W-04: the failure detector recognises a host missing-script report and ignores normal output' {
            $missingScriptReport = 'The argument ' + $script:EntryPointPath + ' does not exist. The argument is missing or invalid, or the file is inaccessible.'
            (Test-HarnessFailureDiagnostic -Text $missingScriptReport -EntryPointPath $script:EntryPointPath) | Should -BeTrue
            (Test-HarnessFailureDiagnostic -Text ('The parameter DryRun is unavailable: a parameter cannot be found that matches parameter name DryRun.') -EntryPointPath $script:EntryPointPath) | Should -BeTrue
            (Test-HarnessFailureDiagnostic -Text ('The term xyz is not recognized as the name of a cmdlet.') -EntryPointPath $script:EntryPointPath) | Should -BeTrue
            (Test-HarnessFailureDiagnostic -Text 'RECOVERY_HARNESS_ENTRY_POINT exit=0' -EntryPointPath $script:EntryPointPath) | Should -BeFalse
            # A preflight message about a missing configuration file must not be read as
            # a launcher failure.
            (Test-HarnessFailureDiagnostic -Text ('The configuration file C:\case\config.json does not exist.') -EntryPointPath $script:EntryPointPath) | Should -BeFalse
            (Test-HarnessFailureDiagnostic -Text '' -EntryPointPath $script:EntryPointPath) | Should -BeFalse
        }

        It 'W-01: the repository exposes the entry point the launcher executes' {
            (Test-Path -LiteralPath $script:EntryPointPath -PathType Leaf) | Should -BeTrue -Because ($script:LauncherFileName + ' resolves %~dp0' + $script:EntryPointFileName + ' and runs it with powershell.exe -File, so the documented launch path cannot work without that file at ' + $script:EntryPointPath)
        }
    }

    Context 'W-01 to W-04 launcher harness with a synthetic entry point' {

        It 'W-01: the reviewed launcher bytes run from a foreign working directory and reach the adjacent entry point' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-location.txt'
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments @('/d', '/c', ('"' + $script:Harness.LauncherPath + '"'), '-DryRun', '-NoPause') -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'location' -TimeoutSeconds 60 -RecordPath $recordPath -EntryPointExitCode 0

            $run.TimedOut | Should -BeFalse -Because ('the launcher run must terminate: ' + (Get-HarnessRunDescription -Run $run))
            (Test-Path -LiteralPath $recordPath -PathType Leaf) | Should -BeTrue -Because ('the entry point next to the launcher must be located through %~dp0 even though the working directory is ' + $script:Harness.ForeignDirectory + ': ' + (Get-HarnessRunDescription -Run $run))

            $record = Read-HarnessRecord -Path $recordPath
            [string]::Equals([string]$record.Values['pscommandpath'], $script:Harness.EntryPointPath, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue -Because ('the executed entry point must be the one beside the launcher copy, not a file in the working directory; the entry point reported ' + [string]$record.Values['pscommandpath'])

            $record.Values['dryrun'] | Should -Be 'True'
            $record.Values['nopause'] | Should -Be 'True'

            # The harness must exercise the reviewed launcher itself, not a paraphrase.
            $copyHash = (Get-FileHash -LiteralPath $script:Harness.LauncherPath -Algorithm SHA256).Hash
            $repositoryHash = (Get-FileHash -LiteralPath $script:LauncherPath -Algorithm SHA256).Hash
            $copyHash | Should -Be $repositoryHash -Because 'the harness launcher copy must be byte-identical to the reviewed repository launcher'
        }

        It 'W-02: the entry point receives exactly the launcher options plus the supplied arguments, in order' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-arguments.txt'
            $suppliedArguments = @('-DryRun', '-NoPause')
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments (@('/d', '/c', ('"' + $script:Harness.LauncherPath + '"')) + $suppliedArguments) -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'arguments' -TimeoutSeconds 60 -RecordPath $recordPath -EntryPointExitCode 0

            $run.TimedOut | Should -BeFalse -Because (Get-HarnessRunDescription -Run $run)
            (Test-Path -LiteralPath $recordPath -PathType Leaf) | Should -BeTrue -Because (Get-HarnessRunDescription -Run $run)

            $record = Read-HarnessRecord -Path $recordPath
            $expectedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Harness.EntryPointPath) + $suppliedArguments
            $difference = Compare-HarnessArgumentVector -Actual $record.RawArguments -Expected $expectedArguments
            $difference | Should -BeNullOrEmpty -Because 'the launcher must pass its own documented options and the caller argument sequence unchanged'
        }

        It 'W-02: a quoted argument containing spaces survives the pass-through as exactly one argument' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-quoted.txt'
            $configPath = 'C:\Recovery Fixture\case config.json'
            $caseLabel = 'client one'
            $suppliedArguments = @('-DryRun', '-NoPause', '-ConfigPath', ('"' + $configPath + '"'), '-CaseLabel', ('"' + $caseLabel + '"'))
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments (@('/d', '/c', ('"' + $script:Harness.LauncherPath + '"')) + $suppliedArguments) -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'quoted' -TimeoutSeconds 60 -RecordPath $recordPath -EntryPointExitCode 0

            $run.TimedOut | Should -BeFalse -Because (Get-HarnessRunDescription -Run $run)
            (Test-Path -LiteralPath $recordPath -PathType Leaf) | Should -BeTrue -Because (Get-HarnessRunDescription -Run $run)

            $record = Read-HarnessRecord -Path $recordPath
            $expectedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Harness.EntryPointPath, '-DryRun', '-NoPause', '-ConfigPath', $configPath, '-CaseLabel', $caseLabel)
            $difference = Compare-HarnessArgumentVector -Actual $record.RawArguments -Expected $expectedArguments
            $difference | Should -BeNullOrEmpty -Because 'a quoted path or label must not be split into several arguments or re-quoted'
            $record.Values['configpath'] | Should -Be $configPath
            $record.Values['caselabel'] | Should -Be $caseLabel
        }

        It 'W-03: -NoPause terminates the run without waiting for redirected input' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-nopause-option.txt'
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments @('/d', '/c', ('"' + $script:Harness.LauncherPath + '"'), '-NoPause') -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'nopause-option' -TimeoutSeconds 30 -RecordPath $recordPath -EntryPointExitCode 0 -SetNoPauseVariable $false

            $run.TimedOut | Should -BeFalse -Because ('-NoPause must suppress the closing prompt so an automated caller cannot block on a redirected console: ' + (Get-HarnessRunDescription -Run $run))
            $run.ExitCode | Should -Be 0 -Because (Get-HarnessRunDescription -Run $run)
        }

        It 'W-03: RECOVERY_NO_PAUSE=1 alone terminates the run without waiting for redirected input' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-nopause-variable.txt'
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments @('/d', '/c', ('"' + $script:Harness.LauncherPath + '"'), '-DryRun') -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'nopause-variable' -TimeoutSeconds 30 -RecordPath $recordPath -EntryPointExitCode 0 -SetNoPauseVariable $true

            $run.TimedOut | Should -BeFalse -Because ('RECOVERY_NO_PAUSE=1 must suppress the closing prompt even without the -NoPause argument: ' + (Get-HarnessRunDescription -Run $run))
            $run.ExitCode | Should -Be 0 -Because (Get-HarnessRunDescription -Run $run)
        }

        It 'W-04: a non-zero entry point exit code reaches the invoking cmd.exe unchanged' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-exit.txt'
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments @('/d', '/c', ('"' + $script:Harness.LauncherPath + '"'), '-DryRun', '-NoPause') -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'exit-propagation' -TimeoutSeconds 30 -RecordPath $recordPath -EntryPointExitCode 7

            $run.TimedOut | Should -BeFalse -Because (Get-HarnessRunDescription -Run $run)
            $run.ExitCode | Should -Be 7 -Because ('exit /b must return the entry point code unchanged; ' + (Get-HarnessRunDescription -Run $run))
        }

        It 'W-04: a missing entry point cannot return success' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $brokenHarness = New-LauncherHarness -Name 'launcher-harness-missing-entrypoint' -WithoutEntryPoint
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments @('/d', '/c', ('"' + $brokenHarness.LauncherPath + '"'), '-DryRun', '-NoPause') -WorkingDirectory $brokenHarness.ForeignDirectory -StandardInputPath $brokenHarness.StandardInputPath -ScratchDirectory $brokenHarness.ScratchDirectory -FileNamePrefix 'missing-entrypoint' -TimeoutSeconds 30 -RecordPath '' -EntryPointExitCode 0

            $run.TimedOut | Should -BeFalse -Because (Get-HarnessRunDescription -Run $run)
            $run.ExitCode | Should -Not -Be 0 -Because ('a launch that cannot reach the entry point must not report success; ' + (Get-HarnessRunDescription -Run $run))
            # Two independent visible signals: a recognised host diagnostic, or at least
            # an error text that names the entry point the launcher tried to run.
            $combinedOutput = $run.StandardError + $run.StandardOutput
            $detectedDiagnostic = Test-HarnessFailureDiagnostic -Text $combinedOutput -EntryPointPath $brokenHarness.EntryPointPath
            $namesEntryPoint = $combinedOutput.IndexOf($script:EntryPointFileName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            Write-Host ('W-04 missing-entry-point observation: detectedDiagnostic=' + [string]$detectedDiagnostic + ' outputNamesEntryPoint=' + [string]$namesEntryPoint + ' exitCode=' + [string]$run.ExitCode)
            ($detectedDiagnostic -or $namesEntryPoint) | Should -BeTrue -Because ('the failure must be visible in the host output rather than only in the exit code: ' + (Get-HarnessRunDescription -Run $run))
        }

        It 'W-08: the closing prompt with redirected input is observed rather than assumed' {
            if (-not [string]::IsNullOrEmpty($script:LauncherHarnessSkipReason)) { Set-ItResult -Skipped -Because $script:LauncherHarnessSkipReason; return }

            $recordPath = Join-Path -Path $script:Harness.ScratchDirectory -ChildPath 'record-pause-observation.txt'
            $run = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments @('/d', '/c', ('"' + $script:Harness.LauncherPath + '"'), '-DryRun') -WorkingDirectory $script:Harness.ForeignDirectory -StandardInputPath $script:Harness.StandardInputPath -ScratchDirectory $script:Harness.ScratchDirectory -FileNamePrefix 'pause-observation' -TimeoutSeconds 20 -RecordPath $recordPath -EntryPointExitCode 0 -SetNoPauseVariable $false

            $observation = ''
            if ($run.TimedOut) {
                $observation = 'the closing prompt waited for a keypress even with stdin redirected to an empty file'
            } else {
                $observation = 'the closing prompt returned immediately with stdin redirected to an empty file'
                $run.ExitCode | Should -Be 0 -Because ('a completed non-opt-out run must still return the entry point code; ' + (Get-HarnessRunDescription -Run $run))
            }
            Write-Host ('W-08 observation: ' + $observation)

            # In both outcomes the entry point must have run before the prompt, so the
            # observation describes the closing prompt and not a failed launch.
            (Test-Path -LiteralPath $recordPath -PathType Leaf) | Should -BeTrue -Because ('the launcher must execute the entry point before any closing prompt; ' + (Get-HarnessRunDescription -Run $run))
            ($observation.Length -gt 0) | Should -BeTrue
        }
    }

    Context 'W-01 to W-04 repository launcher and entry point dry run' {

        BeforeAll {
            $script:DryRunSkipReason = $script:LauncherHarnessSkipReason
            $script:DryRunForeignDirectory = ''
            $script:RepositoryLauncherRun = $null
            $script:RepositoryDirectRun = $null
            $script:LauncherHashBefore = ''

            if ([string]::IsNullOrEmpty($script:DryRunSkipReason)) {
                if (-not (Test-Path -LiteralPath $script:WindowsPowerShellExecutable -PathType Leaf)) {
                    $script:DryRunSkipReason = 'this contract compares the launcher invocation with a direct Windows PowerShell 5.1 invocation, and ' + $script:WindowsPowerShellExecutable + ' is not available here'
                }
            }

            if ([string]::IsNullOrEmpty($script:DryRunSkipReason)) {
                $script:LauncherHashBefore = (Get-FileHash -LiteralPath $script:LauncherPath -Algorithm SHA256).Hash
                $dryRunRoot = New-HarnessDirectory -Path (Join-Path -Path $TestDrive -ChildPath 'repository-dry-run')
                $script:DryRunForeignDirectory = New-HarnessDirectory -Path (Join-Path -Path $dryRunRoot -ChildPath 'foreign-working-directory')
                $dryRunScratchDirectory = New-HarnessDirectory -Path (Join-Path -Path $dryRunRoot -ChildPath 'scratch')
                $dryRunStandardInputPath = Join-Path -Path $dryRunScratchDirectory -ChildPath 'standard-input.empty'
                New-HarnessEmptyFile -Path $dryRunStandardInputPath

                $dryRunArguments = @('-DryRun', '-NoPause')
                $script:RepositoryLauncherRun = Invoke-HarnessCommand -FilePath $script:CmdExecutable -CommandArguments (@('/d', '/c', ('"' + $script:LauncherPath + '"')) + $dryRunArguments) -WorkingDirectory $script:DryRunForeignDirectory -StandardInputPath $dryRunStandardInputPath -ScratchDirectory $dryRunScratchDirectory -FileNamePrefix 'repository-launcher' -TimeoutSeconds 150 -RecordPath '' -EntryPointExitCode 0
                $script:RepositoryDirectRun = Invoke-HarnessCommand -FilePath $script:WindowsPowerShellExecutable -CommandArguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:EntryPointPath + '"')) + $dryRunArguments) -WorkingDirectory $script:RepositoryRoot -StandardInputPath $dryRunStandardInputPath -ScratchDirectory $dryRunScratchDirectory -FileNamePrefix 'repository-direct' -TimeoutSeconds 150 -RecordPath '' -EntryPointExitCode 0
            }
        }

        It 'W-01: the repository launcher completes a dry run started from a foreign working directory' {
            if (-not [string]::IsNullOrEmpty($script:DryRunSkipReason)) { Set-ItResult -Skipped -Because $script:DryRunSkipReason; return }

            $script:RepositoryLauncherRun.TimedOut | Should -BeFalse -Because ('the documented -DryRun path must be bounded and must not wait for input: ' + (Get-HarnessRunDescription -Run $script:RepositoryLauncherRun))
            $combinedOutput = $script:RepositoryLauncherRun.StandardError + $script:RepositoryLauncherRun.StandardOutput
            (Test-HarnessFailureDiagnostic -Text $combinedOutput -EntryPointPath $script:EntryPointPath) | Should -BeFalse -Because ('the launcher must reach ' + $script:EntryPointPath + ' from ' + $script:DryRunForeignDirectory + '; the host reported: ' + (Get-HarnessRunDescription -Run $script:RepositoryLauncherRun))
        }

        It 'W-03: the direct entry point dry run also terminates within the bound' {
            if (-not [string]::IsNullOrEmpty($script:DryRunSkipReason)) { Set-ItResult -Skipped -Because $script:DryRunSkipReason; return }

            $script:RepositoryDirectRun.TimedOut | Should -BeFalse -Because ('the entry point dry run must terminate with the same bounded behavior the launcher lane depends on: ' + (Get-HarnessRunDescription -Run $script:RepositoryDirectRun))
        }

        It 'W-04: the launcher returns the entry point exit code for a dry run' {
            if (-not [string]::IsNullOrEmpty($script:DryRunSkipReason)) { Set-ItResult -Skipped -Because $script:DryRunSkipReason; return }

            $launcherOutput = $script:RepositoryLauncherRun.StandardError + $script:RepositoryLauncherRun.StandardOutput
            $directOutput = $script:RepositoryDirectRun.StandardError + $script:RepositoryDirectRun.StandardOutput
            (Test-HarnessFailureDiagnostic -Text $launcherOutput -EntryPointPath $script:EntryPointPath) | Should -BeFalse -Because (Get-HarnessRunDescription -Run $script:RepositoryLauncherRun)
            (Test-HarnessFailureDiagnostic -Text $directOutput -EntryPointPath $script:EntryPointPath) | Should -BeFalse -Because (Get-HarnessRunDescription -Run $script:RepositoryDirectRun)
            Write-Host ('Repository dry run: launcher exit code ' + [string]$script:RepositoryLauncherRun.ExitCode + ', direct entry point exit code ' + [string]$script:RepositoryDirectRun.ExitCode)
            (($null -ne $script:RepositoryLauncherRun.ExitCode) -and ($null -ne $script:RepositoryDirectRun.ExitCode)) | Should -BeTrue -Because 'both runs must report a process exit code'
            $script:RepositoryLauncherRun.ExitCode | Should -Be $script:RepositoryDirectRun.ExitCode -Because ('the launcher must return the entry point exit code unchanged rather than normalize it; ' + (Get-HarnessRunDescription -Run $script:RepositoryLauncherRun))
        }

        It 'the integration lane never modifies the repository launcher' {
            if (-not [string]::IsNullOrEmpty($script:DryRunSkipReason)) { Set-ItResult -Skipped -Because $script:DryRunSkipReason; return }

            (Test-Path -LiteralPath $script:LauncherPath -PathType Leaf) | Should -BeTrue
            (Get-FileHash -LiteralPath $script:LauncherPath -Algorithm SHA256).Hash | Should -Be $script:LauncherHashBefore
        }
    }
}
