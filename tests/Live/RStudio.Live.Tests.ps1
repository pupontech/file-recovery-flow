<#
.SYNOPSIS
    Owner-live gate for the R-Studio launch-only handoff (TEST-MATRIX record L-11).

.DESCRIPTION
    This file is the visible manual gate for the R-Studio handoff that the
    deterministic lanes cannot prove: the installed identity of the Windows product,
    the exact launch arguments on the wire, the main-panel boundary, and the
    exclusion of every write-capable or automatic action.

    What this file does and does not do
    -----------------------------------
    * It never starts, drives, or simulates R-Studio. No vendor process is created
      here and no vendor control is invoked here.
    * A technician performs the handoff on a licensed machine with the validated
      case, and records the observations in one evidence JSON file. This file
      verifies that the record is complete, internally consistent, and free of the
      observations that would mean the launch-only boundary was crossed.
    * Completeness of a record is not proof of vendor behavior: the assertions prove
      that the owner evidence exists, is unambiguous, and does not contradict
      itself. The owner remains the authority on what was observed.
    * Without the licensed product or an evidence record, every test reports Skip
      with the reason. Nothing here can report Pass without a real record, and a
      skipped test means the owner gate is still open.

    Running the gate (technician machine, elevated session)
    -------------------------------------------------------
    1. Verify the File Scavenger work and the close are verified before handoff
       (state READY_FOR_HANDOFF), then launch the verified executable with exactly
       -safe and, only when a safe case log is configured, -log <path>.
    2. Stop at the main panel. Do not select a source, run partition search, scan,
       mark files, start recovery, choose a destination, or enable a write-capable
       feature.
    3. Record the evidence JSON described below; keep it outside the repository.
    4. Set the environment for the session:
         RECOVERY_ALLOW_LIVE_VENDOR=1
         RECOVERY_LIVE_RSTUDIO_PATH=<verified executable path>
         RECOVERY_LIVE_EVIDENCE=<path to the evidence JSON>
    5. Run:
         $config = & ./PesterConfiguration.ps1 -Lane Live
         Invoke-Pester -Configuration $config
       The lane selects the LiveVendor and LiveElevation tags and never runs in CI.

    Required owner evidence (exact fields)
    --------------------------------------
    recordVersion            1
    product                  the Windows product name as shown by the build; must be
                             the R-Studio for Windows utility, not the Agent or
                             Emergency utility
    identity.executablePath  full path of the executable that was launched
    identity.productVersion / .fileVersion  version resource values of that file
    identity.utilityKind     windows | agent | emergency
    identity.licenseMode     licensed | demo
    identity.windowsVersion  Windows build string
    identity.powershellVersion  Windows PowerShell version used
    identity.elevated        true | false (the vendor requires administrative
                             privileges; false is a handoff gate, never a pass)
    identity.operator        technician name or initials
    identity.recordedUtc     ISO-8601 UTC timestamp of the recording
    launch.argumentVector    the exact argument vector passed to the executable:
                             [-safe] or [-safe, -log, <case log path>] and nothing else
    launch.processPath / .processId / .startTime  the process identity that was
                             observed after launch
    launch.mainPanelObservedUtc  ISO-8601 UTC timestamp of the observed main panel
    boundary.sourceSelectedAutomatically        must be false
    boundary.partitionSearchStartedAutomatically must be false
    boundary.scanStartedAutomatically           must be false
    boundary.filesMarkedAutomatically           must be false
    boundary.recoveryStartedAutomatically       must be false
    boundary.destinationSelectedAutomatically   must be false
    boundary.analysisStartedAutomatically       must be false
    boundary.writeCapableControlsEnabled        must be false
    clientFolderAction.used            true | false (the separate Explorer action)
    clientFolderAction.invokedRecoveryAction    must be false
    clientFolderAction.refusedUnsafePath        recorded when an unsafe path was tried
    logPath.logPath                    the -log path, when -log was used
    logPath.writable                   true | false
    logPath.samePhysicalDisksAsSource  must be false; the case log may never live on
                             the source physical-disk set
    handoff.state                      the state recorded at handoff (READY_FOR_HANDOFF)
    handoff.technicianActionRequired   must be true; analysis and recovery stay manual

    Lane: owner-live only. Never CI, never a synthetic pass.
#>

Describe 'R-Studio launch-only handoff owner-live gate (L-11)' {

    BeforeAll {
        $script:LiveOptInName = 'RECOVERY_ALLOW_LIVE_VENDOR'
        $script:ProductPathVariableName = 'RECOVERY_LIVE_RSTUDIO_PATH'
        $script:EvidencePathVariableName = 'RECOVERY_LIVE_EVIDENCE'
        $script:SafeSwitch = '-safe'
        $script:LogSwitch = '-log'

        function Get-LiveEnvironmentValue {
            param([Parameter(Mandatory = $true)][string] $Name)
            return [System.Environment]::GetEnvironmentVariable($Name)
        }

        function Test-LiveHost {
            return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
        }

        function Test-LiveElevated {
            # Read-only elevation check. It opens no vendor process and reads no disk.
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
            return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        function Get-SectionValue {
            param(
                $Record,
                [Parameter(Mandatory = $true)][string] $Section,
                [Parameter(Mandatory = $true)][string] $Name
            )
            if ($null -eq $Record) { return $null }
            $sectionProperty = $Record.PSObject.Properties[$Section]
            if ($null -eq $sectionProperty) { return $null }
            $sectionValue = $sectionProperty.Value
            if ($null -eq $sectionValue) { return $null }
            $fieldProperty = $sectionValue.PSObject.Properties[$Name]
            if ($null -eq $fieldProperty) { return $null }
            return $fieldProperty.Value
        }

        function Get-MissingEvidenceField {
            param(
                $Record,
                [Parameter(Mandatory = $true)][string] $Section,
                [Parameter(Mandatory = $true)][string[]] $Field
            )
            $missing = New-Object System.Collections.ArrayList
            foreach ($name in $Field) {
                $value = Get-SectionValue -Record $Record -Section $Section -Name $name
                if ($null -eq $value) { [void]$missing.Add($Section + '.' + $name); continue }
                if ($value -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($value)) { [void]$missing.Add($Section + '.' + $name) }
                }
            }
            return @($missing.ToArray())
        }

        function Get-MissingTopLevelField {
            param(
                $Record,
                [Parameter(Mandatory = $true)][string[]] $Field
            )
            $missing = New-Object System.Collections.ArrayList
            foreach ($name in $Field) {
                if ($null -eq $Record) { [void]$missing.Add($name); continue }
                $property = $Record.PSObject.Properties[$name]
                if ($null -eq $property) { [void]$missing.Add($name); continue }
                if ($null -eq $property.Value) { [void]$missing.Add($name); continue }
                if ($property.Value -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($property.Value)) { [void]$missing.Add($name) }
                }
            }
            return @($missing.ToArray())
        }

        # ------------------------------------------------------------------
        # Required evidence shape, derived from TEST-MATRIX record L-11 and
        # IMPLEMENTATION-SPEC sections 2.8 and 8.2.
        # ------------------------------------------------------------------
        $script:EvidenceSections = [ordered]@{
            identity           = @('executablePath', 'productVersion', 'fileVersion', 'utilityKind', 'licenseMode', 'windowsVersion', 'powershellVersion', 'elevated', 'operator', 'recordedUtc')
            launch             = @('argumentVector', 'processPath', 'processId', 'startTime', 'mainPanelObservedUtc')
            boundary           = @('sourceSelectedAutomatically', 'partitionSearchStartedAutomatically', 'scanStartedAutomatically', 'filesMarkedAutomatically', 'recoveryStartedAutomatically', 'destinationSelectedAutomatically', 'analysisStartedAutomatically', 'writeCapableControlsEnabled')
            clientFolderAction = @('used', 'invokedRecoveryAction')
            handoff            = @('state', 'technicianActionRequired')
        }
        $script:RequiredTopLevelFields = @('recordVersion', 'product')
        $script:MatrixRequiredEvidence = @(
            'executablePath', 'productVersion', 'fileVersion', 'utilityKind', 'licenseMode', 'elevated',
            'argumentVector', 'processPath', 'processId', 'startTime', 'mainPanelObservedUtc',
            'sourceSelectedAutomatically', 'partitionSearchStartedAutomatically', 'scanStartedAutomatically',
            'filesMarkedAutomatically', 'recoveryStartedAutomatically', 'destinationSelectedAutomatically',
            'analysisStartedAutomatically', 'writeCapableControlsEnabled',
            'invokedRecoveryAction', 'state', 'technicianActionRequired'
        )
        # Every automatic or write-capable observation must be recorded false.
        $script:ForbiddenBoundaryFields = @(
            'sourceSelectedAutomatically', 'partitionSearchStartedAutomatically', 'scanStartedAutomatically',
            'filesMarkedAutomatically', 'recoveryStartedAutomatically', 'destinationSelectedAutomatically',
            'analysisStartedAutomatically', 'writeCapableControlsEnabled'
        )
        $script:AllowedUtilityKinds = @('windows')
        $script:SecretFieldPattern = '"[A-Za-z0-9_]*(licenseKey|licenseString|serialNumber|activationCode|password|credential|secret|token)[A-Za-z0-9_]*"\s*:'
        $script:OpenManualGates = @(
            'G-04 vendor surface: the main panel and every analysis control stay manually driven',
            'G-10 handoff: the launch-only boundary is owner-observed and accepts no automatic analysis',
            'L-11: source selection, partition search, scan, marking, recovery, and destination choice remain technician actions',
            'L-11: write-capable settings, editors, wipe, repair, and partition actions stay outside the workflow'
        )

        # ------------------------------------------------------------------
        # Prerequisite evaluation
        # ------------------------------------------------------------------
        $script:ProductSkipReason = ''
        $script:EvidenceSkipReason = ''
        $script:ProductPath = ''
        $script:EvidencePath = ''
        $script:EvidenceText = ''
        $script:EvidenceRecord = $null

        if ((Get-LiveEnvironmentValue -Name $script:LiveOptInName) -ne '1') {
            $script:ProductSkipReason = $script:LiveOptInName + ' is not set to 1, so the licensed-vendor opt-in for this owner gate is absent'
            $script:EvidenceSkipReason = $script:ProductSkipReason
        } elseif (-not (Test-LiveHost)) {
            $script:ProductSkipReason = 'this owner gate observes a licensed Windows build on a technician machine; this run is on ' + [System.Environment]::OSVersion.VersionString
        }

        if ([string]::IsNullOrEmpty($script:EvidenceSkipReason)) {
            $script:ProductPath = Get-LiveEnvironmentValue -Name $script:ProductPathVariableName
            if ([string]::IsNullOrEmpty($script:ProductPath)) {
                $script:ProductSkipReason = $script:ProductPathVariableName + ' is not set to the verified executable path'
            } elseif (-not (Test-Path -LiteralPath $script:ProductPath -PathType Leaf)) {
                $script:ProductSkipReason = 'the verified executable path recorded in ' + $script:ProductPathVariableName + ' does not exist on this machine'
            }

            $script:EvidencePath = Get-LiveEnvironmentValue -Name $script:EvidencePathVariableName
            if ([string]::IsNullOrEmpty($script:EvidencePath)) {
                $script:EvidenceSkipReason = $script:EvidencePathVariableName + ' is not set to the owner evidence record'
            } elseif (-not (Test-Path -LiteralPath $script:EvidencePath -PathType Leaf)) {
                $script:EvidenceSkipReason = 'the owner evidence record was not found at the path in ' + $script:EvidencePathVariableName
            } else {
                try {
                    $script:EvidenceText = [System.IO.File]::ReadAllText($script:EvidencePath)
                    $script:EvidenceRecord = ConvertFrom-Json -InputObject $script:EvidenceText -ErrorAction Stop
                } catch {
                    $script:EvidenceSkipReason = 'the owner evidence record is not valid JSON: ' + $_.Exception.Message
                }
            }
        }

        function Get-EvidenceSectionSkipReason {
            param([Parameter(Mandatory = $true)][string] $Section)
            if (-not [string]::IsNullOrEmpty($script:EvidenceSkipReason)) { return $script:EvidenceSkipReason }
            if ($null -eq $script:EvidenceRecord) { return $script:EvidenceSkipReason }
            if ($null -eq $script:EvidenceRecord.PSObject.Properties[$Section]) {
                return ('the owner evidence record has no ' + $Section + ' section, so this observation was not part of the recorded handoff')
            }
            return ''
        }
    }

    Context 'L-11 installed identity and elevation evidence' -Tag 'LiveVendor' {

        It 'L-11: the recorded executable exists and reports a product identity (read-only, no launch)' {
            if (-not [string]::IsNullOrEmpty($script:ProductSkipReason)) { Set-ItResult -Skipped -Because $script:ProductSkipReason; return }

            (Test-Path -LiteralPath $script:ProductPath -PathType Leaf) | Should -BeTrue
            $fileInfo = New-Object -TypeName System.IO.FileInfo -ArgumentList $script:ProductPath
            $fileInfo.VersionInfo.ProductVersion | Should -Not -BeNullOrEmpty -Because 'the handoff must name a build; a bare file name is not identity evidence'
            $fileInfo.VersionInfo.FileVersion | Should -Not -BeNullOrEmpty
            Write-Host ('L-11 observed product version: ' + $fileInfo.VersionInfo.ProductVersion + ' / file version: ' + $fileInfo.VersionInfo.FileVersion)
        }

        It 'L-11: the technician session is elevated, as the vendor requirements document' -Tag 'LiveElevation' {
            if (-not [string]::IsNullOrEmpty($script:ProductSkipReason)) { Set-ItResult -Skipped -Because $script:ProductSkipReason; return }
            if (-not (Test-LiveHost)) { Set-ItResult -Skipped -Because 'the elevation check requires a Windows session'; return }

            (Test-LiveElevated) | Should -BeTrue -Because 'the vendor documents an administrative requirement for the Windows product; the handoff must fail closed rather than launch without it'
        }

        It 'L-11: the recorded utility is the Windows product, never the Agent or Emergency utility' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'identity'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'identity' -Field $script:EvidenceSections['identity'])
            ($missing -join ', ') | Should -BeNullOrEmpty -Because 'the identity section must record the exact path, build, utility, license mode, environment, and operator'
            $utilityKind = [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'utilityKind')
            ($script:AllowedUtilityKinds -contains $utilityKind) | Should -BeTrue -Because 'the handoff accepts only the R-Studio for Windows utility, so its recorded kind must be windows and not agent or emergency'
            @('licensed', 'demo') -contains [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'licenseMode') | Should -BeTrue
            if ($script:ProductPath -ne '') {
                [string]::Equals([string](Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'executablePath'), $script:ProductPath, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue -Because 'the evidenced path must be the executable this session validated'
            }
        }
    }

    Context 'L-11 launch argument and process evidence' -Tag 'LiveVendor' {

        It 'L-11: the recorded argument vector is exactly the documented launch-only set' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'launch'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $argumentVector = @(Get-SectionValue -Record $script:EvidenceRecord -Section 'launch' -Name 'argumentVector')
            $argumentVector.Count | Should -BeGreaterThan 0 -Because 'the launch evidence must carry the actual argument vector'
            $argumentVector[0] | Should -Be $script:SafeSwitch -Because 'the documented safety switch is the first argument of the launch-only handoff'
            if ($argumentVector.Count -eq 1) {
                Write-Host 'L-11 handoff argument vector: -safe'
            } else {
                $argumentVector.Count | Should -Be 3 -Because 'the only other documented shape is -safe followed by the log switch and one case log path'
                $argumentVector[1] | Should -Be $script:LogSwitch
                [string]::IsNullOrWhiteSpace([string]$argumentVector[2]) | Should -BeFalse -Because 'the log switch must carry one validated case log path'
                Write-Host ('L-11 handoff argument vector: -safe -log ' + [string]$argumentVector[2])
            }
        }

        It 'L-11: the process identity observed after launch is recorded' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'launch'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'launch' -Field $script:EvidenceSections['launch'])
            ($missing -join ', ') | Should -BeNullOrEmpty
            Write-Host ('L-11 observed process: ' + [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'launch' -Name 'processPath') + ' pid ' + [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'launch' -Name 'processId'))
        }

        It 'L-11: a log switch is used only with a safe, writable, non-source case log path' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'launch'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $argumentVector = @(Get-SectionValue -Record $script:EvidenceRecord -Section 'launch' -Name 'argumentVector')
            if ($argumentVector.Count -ne 3) {
                Set-ItResult -Skipped -Because 'the recorded handoff did not use the optional log switch, so no log path safety can be asserted'
                return
            }
            $logReason = Get-EvidenceSectionSkipReason -Section 'logPath'
            if (-not [string]::IsNullOrEmpty($logReason)) {
                # A handoff that used the log switch must carry log-path safety
                # evidence. Its absence is an incomplete record, not an inapplicable
                # check, so it fails the gate instead of skipping it.
                $logReason | Should -BeNullOrEmpty -Because 'a handoff that used -log must record the case log path, its writability, and that it is not on the source physical-disk set'
                return
            }

            [string]::IsNullOrWhiteSpace([string](Get-SectionValue -Record $script:EvidenceRecord -Section 'logPath' -Name 'logPath')) | Should -BeFalse
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'logPath' -Name 'writable') | Should -BeTrue -Because 'an unwritable log path must block the launch instead of being accepted'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'logPath' -Name 'samePhysicalDisksAsSource') | Should -BeFalse -Because 'the case log may never be written to the source physical-disk set'
        }
    }

    Context 'L-11 main-panel boundary and write-capable exclusion' -Tag 'LiveVendor' {

        It 'L-11: the main panel was reached and the technician action remained required' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'handoff'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'handoff' -Field $script:EvidenceSections['handoff'])
            ($missing -join ', ') | Should -BeNullOrEmpty
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'handoff' -Name 'technicianActionRequired') | Should -BeTrue -Because 'the workflow stops at the main panel; analysis and recovery are never automatic'
            Write-Host ('L-11 handoff state: ' + [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'handoff' -Name 'state'))
        }

        It 'L-11: no automatic source selection, partition search, scan, marking, recovery, or destination choice occurred' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'boundary'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'boundary' -Field $script:EvidenceSections['boundary'])
            ($missing -join ', ') | Should -BeNullOrEmpty -Because 'every automatic boundary observation must be recorded explicitly, including the false ones'
            $violations = New-Object System.Collections.ArrayList
            foreach ($fieldName in $script:ForbiddenBoundaryFields) {
                if ((Get-SectionValue -Record $script:EvidenceRecord -Section 'boundary' -Name $fieldName) -ne $false) {
                    [void]$violations.Add('boundary.' + $fieldName)
                }
            }
            ($violations -join ', ') | Should -BeNullOrEmpty -Because 'the launch-only boundary requires all of these observations to be false'
        }

        It 'L-11: write-capable controls stayed disabled and no wipe, repair, or partition action was exposed' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'boundary'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            (Get-SectionValue -Record $script:EvidenceRecord -Section 'boundary' -Name 'writeCapableControlsEnabled') | Should -BeFalse -Because 'enabling write access, editor writes, wipe, repair, or partition features is outside the workflow'
        }

        It 'L-11: the separate Explorer client-folder action invoked no recovery action' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'clientFolderAction'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'clientFolderAction' -Field $script:EvidenceSections['clientFolderAction'])
            ($missing -join ', ') | Should -BeNullOrEmpty
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'clientFolderAction' -Name 'invokedRecoveryAction') | Should -BeFalse -Because 'opening the validated client folder must not start or drive any vendor recovery action'
            if ((Get-SectionValue -Record $script:EvidenceRecord -Section 'clientFolderAction' -Name 'used') -eq $true) {
                (Get-SectionValue -Record $script:EvidenceRecord -Section 'clientFolderAction' -Name 'refusedUnsafePath') | Should -Not -BeNullOrEmpty -Because 'an unsafe or unresolved client folder path must be refused and recorded'
            }
        }
    }

    Context 'Evidence record and open-gate contracts' -Tag 'LiveVendor' {

        It 'the declared evidence schema covers every observation the test matrix requires' {
            $declared = New-Object System.Collections.ArrayList
            foreach ($sectionName in $script:EvidenceSections.Keys) {
                foreach ($fieldName in $script:EvidenceSections[$sectionName]) { [void]$declared.Add([string]$fieldName) }
            }
            $undeclared = New-Object System.Collections.ArrayList
            foreach ($requiredName in $script:MatrixRequiredEvidence) {
                if ($declared -notcontains $requiredName) { [void]$undeclared.Add($requiredName) }
            }
            ($undeclared -join ', ') | Should -BeNullOrEmpty -Because 'a required observation cannot be dropped from the documented schema without failing this gate'
        }

        It 'the evidence record identifies the product and the recording, with no credentials' {
            if (-not [string]::IsNullOrEmpty($script:EvidenceSkipReason)) { Set-ItResult -Skipped -Because $script:EvidenceSkipReason; return }

            $missing = @(Get-MissingTopLevelField -Record $script:EvidenceRecord -Field $script:RequiredTopLevelFields)
            ($missing -join ', ') | Should -BeNullOrEmpty -Because 'the record must declare its version and the product it describes'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'operator') | Should -Not -BeNullOrEmpty -Because 'an unattributed record cannot be reviewed'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'recordedUtc') | Should -Not -BeNullOrEmpty
            $secretMatches = @([regex]::Matches($script:EvidenceText, $script:SecretFieldPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
            ($secretMatches.Count) | Should -Be 0 -Because 'license keys, credentials, and tokens must never be committed to a live evidence record'
        }

        It 'the open manual gates for the handoff are listed and non-empty' {
            $script:OpenManualGates.Count | Should -BeGreaterThan 0
            $joined = $script:OpenManualGates -join ' '
            foreach ($gateId in @('G-04', 'G-10', 'L-11')) {
                $joined.Contains($gateId) | Should -BeTrue -Because ('gate ' + $gateId + ' must stay visible until exact-build evidence closes it')
            }
            Write-Host ('R-Studio handoff owner gates still open: ' + $script:OpenManualGates.Count)
        }
    }
}
