<#
.SYNOPSIS
    Static and cross-platform contract tests for the File Recovery Flow repository.

.DESCRIPTION
    Implements the static lane of tests/TEST-MATRIX.md (S-01 through S-15), the
    launcher contracts S-08/S-09 plus S-13, and the CI topology contracts
    W-05/W-06/W-07, and drives the shared lane configuration file.

    Every check here is read-only. These tests read bytes, parse text, walk
    abstract syntax trees, and read repository files. They never launch a
    process, call a storage or CIM cmdlet, write a file, or name a vendor
    executable, so the same file runs unchanged on Linux with pwsh and on
    Windows with Windows PowerShell 5.1, where the same parser logic becomes
    the authoritative 5.1 gate (S-06).

    Contract IDs are quoted from tests/TEST-MATRIX.md so a failure maps back to
    the requirement it enforces. Ban-list strings are assembled from fragments so
    that the contract text itself never contains the pattern it forbids.
#>

Set-StrictMode -Version 2.0

Describe 'File Recovery Flow static contracts' {

    BeforeAll {
        # ------------------------------------------------------------------
        # Repository location and contract data
        # ------------------------------------------------------------------
        $script:RepositoryRoot = ''
        if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
            $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
        } elseif (-not [string]::IsNullOrEmpty($PSCommandPath)) {
            $script:RepositoryRoot = Split-Path -Path (Split-Path -Path $PSCommandPath -Parent) -Parent
        } else {
            $script:RepositoryRoot = (Get-Location).ProviderPath
        }

        $script:TextFileExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.md', '.txt', '.yml', '.yaml')
        $script:PowerShellFileExtensions = @('.ps1', '.psm1', '.psd1')
        $script:BatchFileExtensions = @('.bat', '.cmd')
        $script:ExcludedDirectoryNames = @('.git', '.test-results', 'artifacts', 'coverage', 'logs', 'recovery-jobs', 'node_modules', '.vscode', '.idea')

        $script:LiveDirectoryPrefix = 'tests/Live/'
        $script:LauncherRelativePath = 'Start-Recovery.bat'
        $script:EntryPointRelativePath = 'RecoveryAutomation.ps1'
        $script:WorkflowRelativePath = '.github/workflows/ci.yml'
        $script:LaneConfigurationRelativePath = 'PesterConfiguration.ps1'
        $script:ThisFileRelativePath = 'tests/Static.Tests.ps1'

        $script:LauncherCommandAllowlist = @('@echo', 'rem', 'set', 'setlocal', 'cd', 'if', 'goto', 'shift', 'powershell.exe', 'pause', 'exit')
        $script:LauncherProhibitedTokens = @('del', 'erase', 'rd', 'rmdir', 'mkdir', 'copy', 'move', 'xcopy', 'robocopy', 'attrib', 'ren', 'rename', 'icacls', 'takeown')
        $script:LauncherElevationTokens = @('runas', 'runasuser', 'verb', 'elevate', 'elevated', 'highest', ('shell' + 'execute'), ('start' + '-process'))

        $script:BannedCommandNames = @(
            'Format-Volume', 'Initialize-Disk', 'Clear-Disk', 'Set-Disk', 'Remove-Partition',
            'New-Partition', 'Resize-Partition', 'Set-Partition', 'Repair-Volume', 'Repair-Partition',
            'Optimize-Volume', 'Add-PartitionAccessPath', 'Remove-PartitionAccessPath', 'New-Volume',
            'Set-Volume', 'Mount-DiskImage', 'Dismount-DiskImage', 'Reset-PhysicalDisk', 'Set-PhysicalDisk',
            'chkdsk', 'diskpart', 'format', 'bcdedit', 'cipher', 'mbr2gpt', 'convert', 'fsutil', 'bootrec', 'sfc'
        )
        $script:RemovalCommandNames = @('Remove-Item', 'rm', 'del', 'erase', 'rd', 'rmdir')
        $script:DynamicCommandNames = @('Invoke-Expression', 'iex')
        $script:ProcessLaunchCommandName = 'Start' + '-Process'
        $script:ContentWriteCommandNames = @('Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Set-Item', 'Clear-Content', 'Export-Clixml', 'Export-Csv', 'Start-Transcript')
        $script:StorageCommandNames = @('Get-Disk', 'Get-Partition', 'Get-Volume', 'Get-PhysicalDisk', 'Get-CimInstance', 'Get-WmiObject')
        $script:SevenOnlyCommandNames = @('Test-Json', 'Get-Error')
        $script:SevenOnlyParameterNames = @('asbytestream', 'ashashtable')
        $script:SevenOnlyEncodingValues = @('utf8nobom', 'utf8bom')
        $script:SevenOnlyUnknownTokens = @('?', '??', '??=')
        $script:SevenOnlyOperatorTokens = @('&&', '||')
        $script:DevicePathPrefixes = @(
            ('\\' + '.\' + 'PhysicalDrive'),
            ('\\' + '?\' + 'Volume'),
            ('\' + 'Device\Harddisk')
        )
        $script:ScreenAutomationPatterns = @(
            ('Send' + 'Keys'),
            ('keybd' + '_event'),
            ('mouse' + '_event'),
            ('SetCursor' + 'Pos'),
            ('Cursor' + '.Position'),
            ('System.Windows.Forms.' + 'SendKeys')
        )
        # S-10 detects usage, not mention: a production module may legitimately list
        # these names in a reject-list, so only an invoked command name or a screen
        # automation type reference is a violation.
        $script:ScreenAutomationCommandNames = @(('Send' + 'Keys'), ('Send' + 'Wait'), ('SetCursor' + 'Pos'), ('mouse' + '_event'), ('keybd' + '_event'))
        $script:ScreenAutomationTypeNames = @(('System.Windows.Forms.' + 'SendKeys'), ('System.Windows.Forms.' + 'Cursor'))
        $script:VendorTokens = @(
            ('Scav' + 'enger'),
            ('R-' + 'Studio'),
            ('RStudio' + '64'),
            ('Que' + 'Tek'),
            ('R-' + 'Tools')
        )
        $script:LiveTagNames = @(('Live' + 'Vendor'), ('Live' + 'Elevation'))
        $script:LiveOptInVariable = ('$env:' + 'RECOVERY_ALLOW_LIVE_VENDOR')
        $script:LiveOptInName = 'RECOVERY_ALLOW_LIVE_VENDOR'
        # Machine-level roots and real vendor artifact locations. Unit and static
        # tests must use synthetic fixture paths instead; a write or read aimed at
        # one of these strings is a live-machine dependency.
        $script:MachineRootMarkers = @(
            ('$env:' + 'ProgramData'),
            ('$env:' + 'ProgramFiles'),
            ('$env:' + 'SystemDrive'),
            ('$env:' + 'SystemRoot'),
            ('$env:' + 'WinDir'),
            ('$env:' + 'windir'),
            ('Program' + ' Files'),
            ('App' + 'Data')
        )
        # Real vendor download/installer or install-layout markers only. Synthetic
        # fixture paths such as 'C:\Fixture\scanner.bin' or 'C:\Missing\r-studio.exe'
        # are permitted in deterministic tests; a real vendor artifact location is not.
        $script:VendorArtifactMarkers = @(
            ('fsu' + '71'),
            ('rstudio' + '64'),
            ('quetek' + '.com'),
            ('r-studio' + '.com')
        )
        # A call operator on an injected provider scriptblock ("& $Provider") is the
        # approved seam pattern of docs/IMPLEMENTATION-SPEC.md section 2. Only a
        # computed command name, or a variable whose name is itself a command name,
        # is treated as dynamic invocation (S-04).
        $script:CommandNameVariablePattern = '^(cmd|command|commandname|exe|executable|executablename|tool|toolname|binary|program|app|application|utility|filepath)$'

        # ------------------------------------------------------------------
        # Read-only helpers
        # ------------------------------------------------------------------
        function Resolve-ContractPath {
            param([Parameter(Mandatory = $true)][string] $RelativePath)
            return (Join-Path -Path $script:RepositoryRoot -ChildPath $RelativePath)
        }

        function Get-ContractByteArray {
            param([Parameter(Mandatory = $true)][string] $RelativePath)
            return [System.IO.File]::ReadAllBytes((Resolve-ContractPath -RelativePath $RelativePath))
        }

        function Get-ContractText {
            param([Parameter(Mandatory = $true)][string] $RelativePath)
            return [System.IO.File]::ReadAllText((Resolve-ContractPath -RelativePath $RelativePath))
        }

        function Get-ContractRepositoryFile {
            param([string[]] $Extension = @())
            $found = New-Object System.Collections.ArrayList
            $pending = New-Object System.Collections.Stack
            $pending.Push($script:RepositoryRoot)
            $separator = [char]92
            $alternate = [char]47
            while ($pending.Count -gt 0) {
                $currentDirectory = [string]$pending.Pop()
                foreach ($filePath in [System.IO.Directory]::GetFiles($currentDirectory)) {
                    $fileExtension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                    if ($Extension.Count -gt 0) {
                        if ($Extension -notcontains $fileExtension) { continue }
                    }
                    $relativePath = $filePath.Substring($script:RepositoryRoot.Length)
                    $relativePath = $relativePath.TrimStart([char[]]@($separator, $alternate))
                    $relativePath = $relativePath.Replace($separator, $alternate)
                    [void]$found.Add($relativePath)
                }
                foreach ($directoryPath in [System.IO.Directory]::GetDirectories($currentDirectory)) {
                    $directoryName = [System.IO.Path]::GetFileName($directoryPath)
                    if ($script:ExcludedDirectoryNames -contains $directoryName) { continue }
                    $pending.Push($directoryPath)
                }
            }
            return $found.ToArray()
        }

        function Test-ContractPathUnder {
            param(
                [Parameter(Mandatory = $true)][string] $RelativePath,
                [Parameter(Mandatory = $true)][string] $Prefix
            )
            return $RelativePath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
        }

        function Get-ContractParseResult {
            param([Parameter(Mandatory = $true)][string] $RelativePath)
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-ContractPath -RelativePath $RelativePath), [ref]$tokens, [ref]$errors)
            $result = New-Object -TypeName PSObject
            $result | Add-Member -MemberType NoteProperty -Name Path -Value $RelativePath
            $result | Add-Member -MemberType NoteProperty -Name Ast -Value $ast
            $result | Add-Member -MemberType NoteProperty -Name Tokens -Value @($tokens)
            $result | Add-Member -MemberType NoteProperty -Name Errors -Value @($errors)
            return $result
        }

        function Get-ContractCommandAst {
            param([Parameter(Mandatory = $true)][string] $RelativePath)
            $parse = Get-ContractParseResult -RelativePath $RelativePath
            if ($null -eq $parse.Ast) { return @() }
            return @($parse.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        }

        function Get-ContractCommandName {
            param([Parameter(Mandatory = $true)] $CommandAst)
            $elements = @($CommandAst.CommandElements)
            if ($elements.Count -eq 0) { return '' }
            $first = $elements[0]
            if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$first.Value }
            if ($first -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return [string]$first.Value }
            return ('<' + $first.GetType().Name + '>')
        }

        function Get-ContractParameterNameList {
            param([Parameter(Mandatory = $true)] $CommandAst)
            $names = New-Object System.Collections.ArrayList
            foreach ($element in @($CommandAst.CommandElements)) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    [void]$names.Add([string]$element.ParameterName)
                }
            }
            return $names.ToArray()
        }

        function Get-ContractParameterValue {
            param(
                [Parameter(Mandatory = $true)] $CommandAst,
                [Parameter(Mandatory = $true)][string] $ParameterName
            )
            $elements = @($CommandAst.CommandElements)
            for ($index = 1; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if (-not ($element -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
                if ([string]$element.ParameterName -ne $ParameterName) { continue }
                if (($index + 1) -ge $elements.Count) { return '' }
                $next = $elements[$index + 1]
                if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$next.Value }
                return ('<' + $next.GetType().Name + '>')
            }
            return $null
        }

        function Get-ContractFirstPositionalValue {
            param([Parameter(Mandatory = $true)] $CommandAst)
            $elements = @($CommandAst.CommandElements)
            for ($index = 1; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$element.Value }
                return ('<' + $element.GetType().Name + '>')
            }
            return ''
        }

        function Find-ContractWord {
            param(
                [Parameter(Mandatory = $true)][string] $Text,
                [string[]] $Word = @()
            )
            $found = New-Object System.Collections.ArrayList
            foreach ($item in $Word) {
                $pattern = '\b' + [regex]::Escape($item) + '\b'
                if ([regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { [void]$found.Add($item) }
            }
            return $found.ToArray()
        }

        function Find-ContractLiteral {
            param(
                [Parameter(Mandatory = $true)][string] $Text,
                [string[]] $Literal = @()
            )
            $found = New-Object System.Collections.ArrayList
            foreach ($item in $Literal) {
                if ($Text.IndexOf($item, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$found.Add($item) }
            }
            return $found.ToArray()
        }

        function Format-ContractViolation {
            param(
                [object[]] $Violation = @(),
                [int] $Maximum = 8
            )
            if ($Violation.Count -eq 0) { return '' }
            $shown = @($Violation | Select-Object -First $Maximum)
            $text = $shown -join '; '
            if ($Violation.Count -gt $Maximum) {
                $text = $text + '; ... and ' + ($Violation.Count - $Maximum) + ' more violation(s)'
            }
            return $text
        }

        function Get-ContractConfigValue {
            param([Parameter(Mandatory = $true)] $Option)
            # Pester 5/6 expose configuration entries as typed option objects; older
            # shapes return the raw value. Unwrap both without failing under strict mode.
            if ($null -eq $Option) { return $null }
            if ($null -ne $Option.PSObject.Properties['Value']) { return $Option.Value }
            return $Option
        }

        function Get-ContractLauncherLine {
            return @((Get-ContractText -RelativePath $script:LauncherRelativePath) -split "`r`n")
        }

        function Get-ContractLauncherFirstToken {
            $tokens = New-Object System.Collections.ArrayList
            foreach ($line in (Get-ContractLauncherLine)) {
                $text = $line.Trim()
                if ([string]::IsNullOrEmpty($text)) { continue }
                if ($text.StartsWith(':')) { continue }
                $parts = @($text -split '\s+')
                [void]$tokens.Add($parts[0].ToLowerInvariant())
            }
            return $tokens.ToArray()
        }

        # ------------------------------------------------------------------
        # Precomputed file sets (read once, read-only)
        # ------------------------------------------------------------------
        $script:TextFiles = @(Get-ContractRepositoryFile -Extension $script:TextFileExtensions)
        $script:BatchFiles = @(Get-ContractRepositoryFile -Extension $script:BatchFileExtensions)
        $script:PowerShellFiles = @(Get-ContractRepositoryFile -Extension $script:PowerShellFileExtensions)

        $script:ProductionPowerShellFiles = @()
        $script:NonLiveTestPowerShellFiles = @()
        $script:LivePowerShellFiles = @()
        $script:UnitAndStaticTestFiles = @()
        foreach ($file in $script:PowerShellFiles) {
            if (Test-ContractPathUnder -RelativePath $file -Prefix 'tests/') {
                if (Test-ContractPathUnder -RelativePath $file -Prefix $script:LiveDirectoryPrefix) {
                    $script:LivePowerShellFiles += $file
                } else {
                    $script:NonLiveTestPowerShellFiles += $file
                    if ((Test-ContractPathUnder -RelativePath $file -Prefix 'tests/Unit/') -or (Test-ContractPathUnder -RelativePath $file -Prefix 'tests/static/')) {
                        $script:UnitAndStaticTestFiles += $file
                    }
                }
            } else {
                $script:ProductionPowerShellFiles += $file
            }
        }
    }

    Context 'S-01 and S-02 text file contracts' {

        It 'S-01: enumerates the guarded text files (non-vacuous coverage)' {
            $script:TextFiles.Count | Should -BeGreaterThan 5
            ($script:TextFiles -contains 'AGENTS.md') | Should -BeTrue
            ($script:TextFiles -contains 'README.md') | Should -BeTrue
            ($script:TextFiles -contains $script:ThisFileRelativePath) | Should -BeTrue
        }

        It 'S-01: every guarded text file is ASCII' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:TextFiles) {
                $bytes = Get-ContractByteArray -RelativePath $file
                for ($index = 0; $index -lt $bytes.Length; $index++) {
                    if ($bytes[$index] -ge 128) {
                        [void]$violations.Add($file + ' byte ' + $index)
                        break
                    }
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-01: no guarded text file starts with a byte order mark' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:TextFiles) {
                $bytes = Get-ContractByteArray -RelativePath $file
                $hasMark = $false
                if ($bytes.Length -ge 3) {
                    if (($bytes[0] -eq 239) -and ($bytes[1] -eq 187) -and ($bytes[2] -eq 191)) { $hasMark = $true }
                }
                if ($bytes.Length -ge 2) {
                    if (($bytes[0] -eq 255) -and ($bytes[1] -eq 254)) { $hasMark = $true }
                    if (($bytes[0] -eq 254) -and ($bytes[1] -eq 255)) { $hasMark = $true }
                }
                if ($hasMark) { [void]$violations.Add($file) }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-02: every batch file uses CRLF endings and ends with CRLF' {
            $script:BatchFiles.Count | Should -BeGreaterThan 0
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:BatchFiles) {
                $bytes = Get-ContractByteArray -RelativePath $file
                $fileViolation = ''
                $index = 0
                while ($index -lt $bytes.Length) {
                    if ($bytes[$index] -eq 13) {
                        if ((($index + 1) -lt $bytes.Length) -and ($bytes[$index + 1] -eq 10)) {
                            $index = $index + 2
                            continue
                        }
                        $fileViolation = 'stray carriage return at byte ' + $index
                        break
                    }
                    if ($bytes[$index] -eq 10) {
                        $fileViolation = 'bare line feed at byte ' + $index
                        break
                    }
                    $index = $index + 1
                }
                if ([string]::IsNullOrEmpty($fileViolation)) {
                    if ($bytes.Length -lt 2) {
                        $fileViolation = 'file is shorter than one CRLF'
                    } elseif (-not (($bytes[$bytes.Length - 2] -eq 13) -and ($bytes[$bytes.Length - 1] -eq 10))) {
                        $fileViolation = 'file does not end with CRLF'
                    }
                }
                if (-not [string]::IsNullOrEmpty($fileViolation)) { [void]$violations.Add($file + ': ' + $fileViolation) }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-02: the launcher is inside the guarded batch file set' {
            ($script:BatchFiles -contains $script:LauncherRelativePath) | Should -BeTrue
        }
    }

    Context 'S-03 and S-04 destructive, dynamic, and device-path contracts' {

        It 'S-06: parses every PowerShell file with the running engine parser' {
            Write-Host ('S-06 parser engine: PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' (' + $PSVersionTable.PSEdition + ')')
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                $parse = Get-ContractParseResult -RelativePath $file
                foreach ($errorItem in $parse.Errors) {
                    [void]$violations.Add($file + ' line ' + $errorItem.Extent.StartLineNumber + ': ' + $errorItem.Message)
                }
            }
            $violations.Count | Should -Be 0 -Because (Format-ContractViolation -Violation $violations)
        }

        It 'S-03: no disk, partition, or native destructive command appears in a PowerShell file' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    if ($script:BannedCommandNames -contains $name) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': ' + $name)
                    }
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-03: the launcher contains no destructive native tool' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $found = @(Find-ContractWord -Text $text -Word $script:BannedCommandNames)
            (Format-ContractViolation -Violation $found) | Should -BeNullOrEmpty
        }

        It 'S-09: the launcher contains no file deletion or modification command' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $found = @(Find-ContractWord -Text $text -Word $script:LauncherProhibitedTokens)
            (Format-ContractViolation -Violation $found) | Should -BeNullOrEmpty
        }

        It 'S-04: no production dynamic invocation or computed command name appears' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    $line = $commandAst.Extent.StartLineNumber
                    if ($script:DynamicCommandNames -contains $name) {
                        [void]$violations.Add($file + ' line ' + $line + ': ' + $name)
                        continue
                    }
                    # The computed-name rule guards production automation only. A test
                    # may invoke a scriptblock returned by its own helper.
                    if ($script:ProductionPowerShellFiles -notcontains $file) { continue }
                    if (-not $name.StartsWith('<')) { continue }
                    $first = @($commandAst.CommandElements)[0]
                    if ($first -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $variableName = [string]$first.VariablePath.UserPath
                        if ($variableName -inotmatch $script:CommandNameVariablePattern) { continue }
                        [void]$violations.Add($file + ' line ' + $line + ': command name held in $' + $variableName)
                        continue
                    }
                    [void]$violations.Add($file + ' line ' + $line + ': computed command name ' + $name)
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-04: no physical-disk or volume device path literal appears' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                $text = Get-ContractText -RelativePath $file
                foreach ($prefix in $script:DevicePathPrefixes) {
                    if ($text.IndexOf($prefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        [void]$violations.Add($file + ': ' + $prefix)
                    }
                }
            }
            $launcherText = Get-ContractText -RelativePath $script:LauncherRelativePath
            foreach ($prefix in $script:DevicePathPrefixes) {
                if ($launcherText.IndexOf($prefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    [void]$violations.Add($script:LauncherRelativePath + ': ' + $prefix)
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-04: production removal commands are literal-path guarded and never recursive' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:ProductionPowerShellFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    if (-not ($script:RemovalCommandNames -contains $name)) { continue }
                    $parameters = @(Get-ContractParameterNameList -CommandAst $commandAst)
                    $lowered = @()
                    foreach ($parameter in $parameters) { $lowered += $parameter.ToLowerInvariant() }
                    if ($lowered -notcontains 'literalpath') {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': ' + $name + ' without -LiteralPath')
                        continue
                    }
                    if (($lowered -contains 'recurse') -or ($lowered -contains 'force')) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': ' + $name + ' with -Recurse or -Force')
                        continue
                    }
                    $value = Get-ContractParameterValue -CommandAst $commandAst -ParameterName 'LiteralPath'
                    if (($null -eq $value) -or ($value.Length -eq 0) -or (-not $value.StartsWith('<'))) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': ' + $name + ' with a literal path')
                    }
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-04: production process launches never use a literal executable path' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:ProductionPowerShellFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    if ($name -ne $script:ProcessLaunchCommandName) { continue }
                    $value = Get-ContractParameterValue -CommandAst $commandAst -ParameterName 'FilePath'
                    if ($null -eq $value) { $value = Get-ContractFirstPositionalValue -CommandAst $commandAst }
                    if ([string]::IsNullOrEmpty($value)) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': launch without an executable argument')
                        continue
                    }
                    if (-not $value.StartsWith('<')) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': literal executable path ' + $value)
                    }
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }
    }

    Context 'S-05 PowerShell 7-only construct contract' {

        It 'S-05: no PowerShell 7-only operator or ternary appears' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                $tokenErrors = $null
                $tokens = [System.Management.Automation.PSParser]::Tokenize((Get-ContractText -RelativePath $file), [ref]$tokenErrors)
                foreach ($tokenError in @($tokenErrors)) {
                    [void]$violations.Add($file + ' tokenizer: ' + $tokenError.Message)
                }
                foreach ($token in @($tokens)) {
                    $typeName = $token.Type.ToString()
                    $content = [string]$token.Content
                    if ($typeName -eq 'Unknown') {
                        if ($script:SevenOnlyUnknownTokens -contains $content) {
                            [void]$violations.Add($file + ' line ' + $token.StartLine + ': PowerShell 7-only token ' + $content)
                        }
                    }
                    if ($typeName -eq 'Operator') {
                        if ($script:SevenOnlyOperatorTokens -contains $content) {
                            [void]$violations.Add($file + ' line ' + $token.StartLine + ': PowerShell 7-only operator ' + $content)
                        }
                    }
                }
                $parse = Get-ContractParseResult -RelativePath $file
                if ($null -ne $parse.Ast) {
                    foreach ($node in @($parse.Ast.FindAll({ param($candidate) $true }, $true))) {
                        if ($node.GetType().Name -eq 'TernaryExpressionAst') {
                            [void]$violations.Add($file + ' line ' + $node.Extent.StartLineNumber + ': ternary expression')
                        }
                    }
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-05: no PowerShell 7-only command, parameter, or encoding value appears' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    if ($script:SevenOnlyCommandNames -contains $name) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': 7-only command ' + $name)
                    }
                    foreach ($parameter in @(Get-ContractParameterNameList -CommandAst $commandAst)) {
                        if ($script:SevenOnlyParameterNames -contains $parameter.ToLowerInvariant()) {
                            [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': 7-only parameter -' + $parameter)
                        }
                    }
                    $encoding = Get-ContractParameterValue -CommandAst $commandAst -ParameterName 'Encoding'
                    if ($null -ne $encoding) {
                        if (-not $encoding.StartsWith('<')) {
                            if ($script:SevenOnlyEncodingValues -contains $encoding.ToLowerInvariant()) {
                                [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': 7-only encoding ' + $encoding)
                            }
                        }
                    }
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }
    }

    Context 'S-08, S-09 and S-13 launcher contract' {

        It 'S-08: the launcher exists at the repository root' {
            (Test-Path -LiteralPath (Resolve-ContractPath -RelativePath $script:LauncherRelativePath) -PathType Leaf) | Should -BeTrue
        }

        It 'S-13: the launcher propagates the entry point exit code with exit /b' {
            $lines = @(Get-ContractLauncherLine)
            $exitLines = @($lines | Where-Object { $_ -match '^\s*exit\s+/b\s' })
            $exitLines.Count | Should -Be 1
            $exitLines[0] | Should -Match '%RECOVERY_EXIT_CODE%'
            $bareExit = @($lines | Where-Object { $_ -match '^\s*exit\s*$' })
            $bareExit.Count | Should -Be 0
        }

        It 'S-13: the launcher captures the exit code immediately after the entry point call' {
            $lines = @(Get-ContractLauncherLine)
            $callIndex = -1
            $captureIndex = -1
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match 'powershell\.exe\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File') { $callIndex = $index }
                if ($lines[$index] -match 'set\s+"RECOVERY_EXIT_CODE=%ERRORLEVEL%"') { $captureIndex = $index }
            }
            $callIndex | Should -BeGreaterThan -1
            $captureIndex | Should -Be ($callIndex + 1)
        }

        It 'S-08: the launcher resolves its own directory and names the entry point' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $text.Contains('%~dp0') | Should -BeTrue
            $text.Contains($script:EntryPointRelativePath) | Should -BeTrue
        }

        It 'S-08: the launcher invokes Windows PowerShell 5.1 with -File' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $text.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File') | Should -BeTrue
            $matches = @([regex]::Matches($text, 'powershell\.exe'))
            $matches.Count | Should -Be 1
        }

        It 'S-08: the launcher never uses pwsh or a -Command invocation' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            ([regex]::IsMatch($text, 'pwsh', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) | Should -BeFalse
            $text.Contains('-Command') | Should -BeFalse
        }

        It 'S-08: the launcher contains no parenthesized command block' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $text.Contains('(') | Should -BeFalse
            $text.Contains(')') | Should -BeFalse
        }

        It 'S-13: the launcher stays thin so it can be reviewed at a glance' {
            @(Get-ContractLauncherLine).Count | Should -BeLessThan 40
        }

        It 'S-09: launcher commands stay inside the thin allowlist' {
            $tokens = @(Get-ContractLauncherFirstToken)
            $tokens.Count | Should -BeGreaterThan 5
            $unexpected = @()
            foreach ($token in $tokens) {
                if ($script:LauncherCommandAllowlist -notcontains $token) { $unexpected += $token }
            }
            (Format-ContractViolation -Violation $unexpected) | Should -BeNullOrEmpty
        }

        It 'S-09: the batch launcher delegates elevation to the entry point' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $text.Contains('-Command') | Should -BeFalse
            $text.Contains('-Verb RunAs') | Should -BeFalse
            $text.Contains('Start-Process') | Should -BeFalse
        }

        It 'S-09: the entry point self-elevates and waits for the elevated child' {
            $text = Get-ContractText -RelativePath $script:EntryPointRelativePath
            $text.Contains('Start-Process') | Should -BeTrue
            $text.Contains('-Verb RunAs') | Should -BeTrue
            $text.Contains('-WorkingDirectory $PSScriptRoot') | Should -BeTrue
            $text.Contains('-Wait') | Should -BeTrue
            $text.Contains('ElevationDeclined') | Should -BeTrue
            $text.Contains(([string][char]92 + [string][char]34)) | Should -BeFalse
        }

        It 'S-09: the relaunch argument helper quotes spaced paths without backslash-quote corruption' {
            $parse = Get-ContractParseResult -RelativePath $script:EntryPointRelativePath
            $functions = @($parse.Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Get-RecoveryAutomationElevationArgumentLine'
                }, $true))
            $functions.Count | Should -Be 1
            $definition = $functions[0].Extent.Text + "`n" + @'
Get-RecoveryAutomationElevationArgumentLine -ScriptPath 'C:\Recovery Jobs\RecoveryAutomation.ps1' -ConfigPath 'C:\Recovery Jobs\client config.json' -NoPause -DryRun
'@
            $argumentLine = & ([scriptblock]::Create($definition))

            $argumentLine | Should -Match '"C:\\Recovery Jobs\\RecoveryAutomation\.ps1"'
            $argumentLine | Should -Match '"C:\\Recovery Jobs\\client config\.json"'
            $argumentLine | Should -Match '-NoPause'
            $argumentLine | Should -Match '-DryRun'
            $argumentLine.Contains(([string][char]92 + [string][char]34)) | Should -BeFalse
        }

        It 'S-09: the launcher pauses only behind the explicit opt-out' {
            $lines = @(Get-ContractLauncherLine)
            $pauseLines = @($lines | Where-Object { $_ -match '(^|\s)pause(\s|$)' })
            $pauseLines.Count | Should -Be 1
            $pauseLines[0] | Should -Match 'if not defined RECOVERY_NO_PAUSE pause'
        }

        It 'S-09: the launcher never names a vendor product or vendor executable' {
            $text = Get-ContractText -RelativePath $script:LauncherRelativePath
            $found = @(Find-ContractLiteral -Text $text -Literal $script:VendorTokens)
            (Format-ContractViolation -Violation $found) | Should -BeNullOrEmpty
        }
    }

    Context 'S-10 coordinate-free automation contract' {

        It 'S-10: no screen-coordinate or keystroke automation is invoked' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:PowerShellFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    if ($script:ScreenAutomationCommandNames -contains $name) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': command ' + $name)
                    }
                }
                $parse = Get-ContractParseResult -RelativePath $file
                if ($null -eq $parse.Ast) { continue }
                foreach ($node in @($parse.Ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.TypeExpressionAst] }, $true))) {
                    $typeName = [string]$node.TypeName.FullName
                    if ($script:ScreenAutomationTypeNames -contains $typeName) {
                        [void]$violations.Add($file + ' line ' + $node.Extent.StartLineNumber + ': type ' + $typeName)
                    }
                }
            }
            $launcherText = Get-ContractText -RelativePath $script:LauncherRelativePath
            foreach ($item in @(Find-ContractLiteral -Text $launcherText -Literal $script:ScreenAutomationPatterns)) {
                [void]$violations.Add($script:LauncherRelativePath + ': ' + $item)
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }
    }

    Context 'S-11 and S-12 isolation contracts' {

        It 'S-12: this lane runs without the live-vendor opt-in' {
            [string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable($script:LiveOptInName)) | Should -BeTrue
        }

        It 'S-11: unit and static tests contain no process launch, storage cmdlet, or live tag' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:UnitAndStaticTestFiles) {
                foreach ($commandAst in (Get-ContractCommandAst -RelativePath $file)) {
                    $name = Get-ContractCommandName -CommandAst $commandAst
                    if ($name -eq $script:ProcessLaunchCommandName) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': ' + $name)
                    }
                    if ($script:StorageCommandNames -contains $name) {
                        [void]$violations.Add($file + ' line ' + $commandAst.Extent.StartLineNumber + ': storage cmdlet ' + $name)
                    }
                }
                $text = Get-ContractText -RelativePath $file
                $tagPattern = '-Tag\s+(' + (($script:LiveTagNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
                if ([regex]::IsMatch($text, $tagPattern)) {
                    [void]$violations.Add($file + ': declares a live tag')
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-11: unit and static tests contain no machine root or real vendor artifact reference' {
            $textViolations = New-Object System.Collections.ArrayList
            foreach ($file in $script:UnitAndStaticTestFiles) {
                $text = Get-ContractText -RelativePath $file
                foreach ($item in @(Find-ContractLiteral -Text $text -Literal $script:MachineRootMarkers)) {
                    [void]$textViolations.Add($file + ': ' + $item)
                }
                foreach ($item in @(Find-ContractLiteral -Text $text -Literal $script:VendorArtifactMarkers)) {
                    [void]$textViolations.Add($file + ': ' + $item)
                }
                if ([regex]::IsMatch($text, '-Tag\s+(' + (($script:LiveTagNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')')) {
                    [void]$textViolations.Add($file + ': declares a live tag')
                }
                if ($text.IndexOf($script:LiveOptInVariable, [System.StringComparison]::Ordinal) -ge 0) {
                    [void]$textViolations.Add($file + ': references the live-vendor opt-in variable')
                }
            }
            (Format-ContractViolation -Violation $textViolations) | Should -BeNullOrEmpty
        }

        It 'S-12: live test files live only under tests/Live' {
            foreach ($file in $script:LivePowerShellFiles) {
                (Test-ContractPathUnder -RelativePath $file -Prefix $script:LiveDirectoryPrefix) | Should -BeTrue
            }
            $misplaced = @()
            foreach ($file in $script:NonLiveTestPowerShellFiles) {
                if (Test-ContractPathUnder -RelativePath $file -Prefix $script:LiveDirectoryPrefix) { $misplaced += $file }
            }
            (Format-ContractViolation -Violation $misplaced) | Should -BeNullOrEmpty
        }
    }

    Context 'S-15 test write-root contract' {

        It 'S-15: no non-live test references a machine-level location' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($file in $script:NonLiveTestPowerShellFiles) {
                $text = Get-ContractText -RelativePath $file
                foreach ($item in @(Find-ContractLiteral -Text $text -Literal $script:MachineRootMarkers)) {
                    [void]$violations.Add($file + ': ' + $item)
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }

        It 'S-15: this contract file performs no content write' {
            $violations = New-Object System.Collections.ArrayList
            foreach ($commandAst in (Get-ContractCommandAst -RelativePath $script:ThisFileRelativePath)) {
                $name = Get-ContractCommandName -CommandAst $commandAst
                if ($script:ContentWriteCommandNames -contains $name) {
                    [void]$violations.Add('line ' + $commandAst.Extent.StartLineNumber + ': ' + $name)
                }
                if ($script:RemovalCommandNames -contains $name) {
                    [void]$violations.Add('line ' + $commandAst.Extent.StartLineNumber + ': ' + $name)
                }
            }
            (Format-ContractViolation -Violation $violations) | Should -BeNullOrEmpty
        }
    }

    Context 'W-05, W-06 and W-07 CI workflow contract' {

        It 'W-05: the workflow exists and declares the pinned Windows lanes' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            $text.Contains('static-linux') | Should -BeTrue
            $text.Contains('compat-analyze') | Should -BeTrue
            ([regex]::IsMatch($text, 'windows-2022')) | Should -BeTrue
            ([regex]::IsMatch($text, 'windows-2025')) | Should -BeTrue
            ([regex]::IsMatch($text, 'ubuntu-latest')) | Should -BeTrue
        }

        It 'W-05: no lane runs on the floating windows-latest image' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            ([regex]::IsMatch($text, 'runs-on:\s+windows-latest')) | Should -BeFalse
            ([regex]::IsMatch($text, '(?m)^\s*-?\s*windows-latest\s*$')) | Should -BeFalse
        }

        It 'W-05: every run step declares its shell explicitly' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            $runCount = @([regex]::Matches($text, '(?m)^\s+run:\s')).Count
            $shellCount = @([regex]::Matches($text, '(?m)^\s+shell:\s')).Count
            $runCount | Should -BeGreaterThan 3
            $shellCount | Should -Be $runCount
        }

        It 'W-05: the Windows lane asserts the real Windows PowerShell 5.1 runtime' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            $text.Contains('PSVersionTable.PSVersion.Major') | Should -BeTrue
            $text.Contains('PSEdition') | Should -BeTrue
            $text.Contains('Win32_OperatingSystem') | Should -BeTrue
        }

        It 'W-05: the workflow runs the launcher through cmd.exe' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            ([regex]::IsMatch($text, '(?m)^\s+shell:\s+cmd\s*$')) | Should -BeTrue
            $text.Contains($script:LauncherRelativePath) | Should -BeTrue
        }

        It 'W-05 and S-14: the workflow pins and asserts the Pester version' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            $text.Contains('PESTER_MINIMUM_VERSION') | Should -BeTrue
            ([regex]::IsMatch($text, '\[version\]\$env:PESTER_MINIMUM_VERSION')) | Should -BeTrue
            ([regex]::IsMatch($text, 'Import-Module -Name Pester')) | Should -BeTrue
            ([regex]::IsMatch($text, 'Version\.Major -ne 5')) | Should -BeTrue
        }

        It 'W-05: action steps are pinned to a released reference' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            $lines = @($text -split "`n")
            $unpinned = @()
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if (-not $trimmed.StartsWith('uses:')) { continue }
                $reference = $trimmed.Substring('uses:'.Length).Trim()
                if (-not ([regex]::IsMatch($reference, '@v[0-9]+(\.[0-9]+)*$') -or [regex]::IsMatch($reference, '@[0-9a-f]{40}$'))) {
                    $unpinned += $reference
                }
            }
            (Format-ContractViolation -Violation $unpinned) | Should -BeNullOrEmpty
        }

        It 'W-06: the workflow never installs, launches, or names a vendor product' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            $found = @(Find-ContractLiteral -Text $text -Literal $script:VendorTokens)
            (Format-ContractViolation -Violation $found) | Should -BeNullOrEmpty
            ([regex]::IsMatch($text, '\.exe', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) | Should -BeFalse
        }

        It 'W-06: the workflow excludes the live tags from every non-live lane' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            foreach ($tag in $script:LiveTagNames) {
                $text.Contains($tag) | Should -BeTrue
            }
            $text.Contains($script:LaneConfigurationRelativePath) | Should -BeTrue
        }

        It 'W-07: the workflow uploads the Pester report for diagnostics' {
            $text = Get-ContractText -RelativePath $script:WorkflowRelativePath
            ([regex]::IsMatch($text, 'uses:\s+actions/upload-artifact@')) | Should -BeTrue
            $text.Contains('.test-results') | Should -BeTrue
            ([regex]::IsMatch($text, '(?m)^\s+if:\s+always\(\)')) | Should -BeTrue
        }
    }

    Context 'Shared Pester lane configuration contract' {

        BeforeAll {
            $script:LaneConfigurationPath = Join-Path -Path $script:RepositoryRoot -ChildPath $script:LaneConfigurationRelativePath
            $script:LaneResultRoot = Join-Path -Path $TestDrive -ChildPath 'lane-results'
        }

        It 'S-14: the lane configuration file exists' {
            (Test-Path -LiteralPath $script:LaneConfigurationPath -PathType Leaf) | Should -BeTrue
        }

        It 'S-14: a Pester 5.x or newer engine is available to this lane' {
            $available = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object -Property Version -Descending)
            $available.Count | Should -BeGreaterThan 0
            Write-Host ('Resolved Pester candidates: ' + (($available | ForEach-Object { $_.Version.ToString() }) -join ', '))
        }

        It 'lane Static resolves the static contract file with Run.Exit and NUnit output' {
            $config = & $script:LaneConfigurationPath -Lane Static -TestResultDirectory $script:LaneResultRoot
            $paths = @(Get-ContractConfigValue -Option $config.Run.Path)
            $paths.Count | Should -Be 1
            ([string]$paths[0]).EndsWith('Static.Tests.ps1') | Should -BeTrue
            (Get-ContractConfigValue -Option $config.Run.Exit) | Should -BeTrue
            (Get-ContractConfigValue -Option $config.TestResult.Enabled) | Should -BeTrue
            ([string](Get-ContractConfigValue -Option $config.TestResult.OutputFormat)) | Should -Be 'NUnitXml'
            ([string](Get-ContractConfigValue -Option $config.TestResult.OutputPath)).EndsWith('.xml') | Should -BeTrue
        }

        It 'the non-live lanes exclude the live tags and the live directory' {
            $config = & $script:LaneConfigurationPath -Lane All -TestResultDirectory $script:LaneResultRoot
            $excludedTags = @(Get-ContractConfigValue -Option $config.Filter.ExcludeTag)
            foreach ($tag in $script:LiveTagNames) {
                ($excludedTags -contains $tag) | Should -BeTrue
            }
            $excludedPaths = @(Get-ContractConfigValue -Option $config.Run.ExcludePath)
            $excludedPaths.Count | Should -BeGreaterThan 0
            $liveExcluded = $false
            foreach ($excludedPath in $excludedPaths) {
                if ([string]$excludedPath -like '*Live*') { $liveExcluded = $true }
            }
            $liveExcluded | Should -BeTrue
        }

        It 'lane Live selects the live tags and otherwise fails closed' {
            $liveDirectory = Join-Path -Path $script:RepositoryRoot -ChildPath 'tests'
            $liveDirectory = Join-Path -Path $liveDirectory -ChildPath 'Live'
            if (-not (Test-Path -LiteralPath $liveDirectory -PathType Container)) {
                $refused = $false
                try { $null = & $script:LaneConfigurationPath -Lane Live -TestResultDirectory $script:LaneResultRoot } catch { $refused = $true }
                $refused | Should -BeTrue
                return
            }
            $config = & $script:LaneConfigurationPath -Lane Live -TestResultDirectory $script:LaneResultRoot
            $selectedTags = @(Get-ContractConfigValue -Option $config.Filter.Tag)
            foreach ($tag in $script:LiveTagNames) {
                ($selectedTags -contains $tag) | Should -BeTrue
            }
        }

        It 'a non-live lane refuses to run when the live-vendor opt-in is set' {
            $previous = [System.Environment]::GetEnvironmentVariable($script:LiveOptInName)
            try {
                [System.Environment]::SetEnvironmentVariable($script:LiveOptInName, '1')
                $refused = $false
                try { $null = & $script:LaneConfigurationPath -Lane Static -TestResultDirectory $script:LaneResultRoot } catch { $refused = $true }
                $refused | Should -BeTrue
            } finally {
                [System.Environment]::SetEnvironmentVariable($script:LiveOptInName, $previous)
            }
        }
    }


    Context 'Pre-write case safety wiring (C-23 follow-up)' {
        # The folder helper keeps an optional proof callback for the documented
        # standalone contract, so nothing stops a future edit from dropping the
        # argument at the one call site that creates a real case. That edit would
        # silently restore the defect this gate exists to close, with every test
        # still green. These contracts pin the wiring itself.
        It 'the entry point proves the candidate path before the case folder or claim is written' {
            $entryPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'RecoveryAutomation.ps1'
            $text = [System.IO.File]::ReadAllText($entryPath, (New-Object System.Text.UTF8Encoding($false)))

            $text.Contains('New-RecoveryJobFolder -RootPath') | Should -BeTrue
            $text.Contains('-PreclaimSafetyCheck $preclaimSafetyCheck') | Should -BeTrue
            $text.Contains('$preclaimSafetyCheck = {') | Should -BeTrue
        }

        It 'the folder helper proves the candidate path at both write stages' {
            $modulePath = Join-Path -Path $script:RepositoryRoot -ChildPath 'modules/DiskDetection.psm1'
            $text = [System.IO.File]::ReadAllText($modulePath, (New-Object System.Text.UTF8Encoding($false)))

            $text.Contains('function Invoke-RecoveryPreclaimSafety') | Should -BeTrue
            $text.Contains("-Stage 'BeforeDirectoryCreate'") | Should -BeTrue
            $text.Contains("-Stage 'BeforeClaimWrite'") | Should -BeTrue
            $text.Contains('[scriptblock]$PreclaimSafetyCheck') | Should -BeTrue
        }

        It 'the pre-claim gate refuses anything but one explicit Boolean approval' {
            $modulePath = Join-Path -Path $script:RepositoryRoot -ChildPath 'modules/DiskDetection.psm1'
            $text = [System.IO.File]::ReadAllText($modulePath, (New-Object System.Text.UTF8Encoding($false)))

            $text.Contains('if ($allowed -is [bool] -and $allowed) {') | Should -BeTrue
            $text.Contains("'PreclaimSafetyUnproven'") | Should -BeTrue
            # The gate must publish a path that can actually be resolved: the
            # candidate folder does not exist when the first stage runs.
            $text.Contains('ProofPath = $proofPath') | Should -BeTrue
        }
    }
}
