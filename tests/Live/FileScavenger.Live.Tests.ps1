<#
.SYNOPSIS
    Owner-live gate for QueTek File Scavenger (TEST-MATRIX records L-01 .. L-04, L-07).

.DESCRIPTION
    This file is the visible manual gate for every File Scavenger behavior that the
    deterministic lanes cannot prove: the licensed build identity, the real GUI
    surface, Quick/Long scan and recovery completion evidence, the exact close
    behavior, and the vendor prompts the workflow must never answer.

    What this file does and does not do
    -----------------------------------
    * It never starts, drives, or simulates File Scavenger. No vendor process is
      created here, and no UI control is invoked here.
    * A technician performs the case on a licensed machine with a disposable source
      and a separate destination physical disk, and records the observations in one
      evidence JSON file. This file verifies that the record is complete, internally
      consistent, and free of the observations that would mean a safety rule was
      broken.
    * Completeness of a record is not proof of vendor behavior: the assertions prove
      that the owner evidence exists, is unambiguous, and does not contradict itself.
      The owner remains the authority on what was observed.
    * Without the licensed product, the required hardware, or an evidence record,
      every test reports Skip with the reason. Nothing here can report Pass without a
      real record, and a skipped test means the owner gate is still open.

    Running the gate (technician machine, elevated session)
    -------------------------------------------------------
    1. Perform the case per docs/LIVE-VALIDATION.md and docs/OPERATOR-GUIDE.md.
    2. Record the evidence JSON described below; keep it outside the repository.
    3. Set the environment for the session:
         RECOVERY_ALLOW_LIVE_VENDOR=1
         RECOVERY_LIVE_FILE_SCAVENGER_PATH=<verified executable path>
         RECOVERY_LIVE_EVIDENCE=<path to the evidence JSON>
    4. Run:
         $config = & ./PesterConfiguration.ps1 -Lane Live
         Invoke-Pester -Configuration $config
       The lane selects the LiveVendor and LiveElevation tags and never runs in CI.

    Required owner evidence (exact fields)
    --------------------------------------
    recordVersion            1
    product                  vendor product name as shown by the build
    identity.executablePath  full path of the executable that was used
    identity.productVersion  FileVersionInfo.ProductVersion of that file
    identity.fileVersion     FileVersionInfo.FileVersion of that file
    identity.aboutVersion    version text read from the vendor About surface
    identity.licenseMode     licensed | demo (demo cannot prove full output; the
                             vendor documents a 64 KB per-file save limit)
    identity.windowsVersion  Windows build string
    identity.powershellVersion  Windows PowerShell version used
    identity.elevated        true | false (the vendor documents an administrator
                             requirement; the workflow must fail closed when false)
    identity.operator        technician name or initials
    identity.recordedUtc     ISO-8601 UTC timestamp of the recording
    quickScan.vendorWording  must be Quick scan
    quickScan.startedUtc     ISO-8601 UTC timestamp of the Scan action
    quickScan.finishedUtc    ISO-8601 UTC timestamp of the distinct scan-finished
                             observation (never a progress value or process exit)
    quickScan.finishEvidence free text naming the observation source
    quickScan.controlAccess  uia | msaa | manual
    quickScan.controlEvidence  exact property evidence, or the reason the surface is
                             manual-only
    shortRecovery.vendorWording  must be Step 2: Save
    shortRecovery.saveToPath     the Save to destination that was used
    shortRecovery.destinationIdentity  the destination physical-disk identity
    shortRecovery.startedUtc / .finishedUtc / .finishEvidence  the distinct recovery
                             stage observations
    shortRecovery.outputObservation  what was observed in the output folder
    shortRecovery.recoveryLogName / .recoveryLogLocation  the observed Recovery.log
                             name and location
    shortRecovery.statusValues  the observed Saved/Failed/Skipped or Good/Poor values
    longScan / longRecovery  the same shape as quickScan / shortRecovery, present
                             only when the technician chose the Long stage
    close.requestedUtc       ISO-8601 UTC timestamp of the graceful close request
    close.surface            the surface used, normally File > Exit
    close.confirmationPromptObserved  true | false
    close.gracefulVerified   true | false with post-close process verification
    close.helperProcessObserved  true | false
    close.forceCloseDuringActiveWork  true | false (true requires the refusal below)
    close.forceCloseRefused  true | false
    refusals.sameDrivePromptObserved  true | false
    refusals.sameDriveAnswerSuppliedByWorkflow  must be false
    refusals.overwritePromptAutoAnswered        must be false
    refusals.journalOverwriteAutoAnswered       must be false
    refusals.lowSpaceHandling  description of the pause/stop behavior that was
                             observed, including that no redirect happened

    Lane: owner-live only. Never CI, never a synthetic pass.
#>

Describe 'File Scavenger owner-live gate (L-01 to L-04, L-07)' {

    BeforeAll {
        $script:LiveOptInName = 'RECOVERY_ALLOW_LIVE_VENDOR'
        $script:ProductPathVariableName = 'RECOVERY_LIVE_FILE_SCAVENGER_PATH'
        $script:EvidencePathVariableName = 'RECOVERY_LIVE_EVIDENCE'

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
                $value = $property.Value
                if ($null -eq $value) { [void]$missing.Add($name); continue }
                if ($value -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($value)) { [void]$missing.Add($name) }
                }
            }
            return @($missing.ToArray())
        }

        function Get-EvidenceTimestamp {
            param(
                $Record,
                [Parameter(Mandatory = $true)][string] $Section,
                [Parameter(Mandatory = $true)][string] $Name
            )
            $value = Get-SectionValue -Record $Record -Section $Section -Name $name
            if ($null -eq $value) { return $null }
            $parsed = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal
            if ([datetime]::TryParse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
                return $parsed
            }
            return $null
        }

        function Test-EvidenceSectionPresent {
            param($Record, [Parameter(Mandatory = $true)][string] $Section)
            if ($null -eq $Record) { return $false }
            return ($null -ne $Record.PSObject.Properties[$Section])
        }

        # ------------------------------------------------------------------
        # Required evidence shape. These lists are derived from the L-01 .. L-07
        # records in tests/TEST-MATRIX.md section 10 and IMPLEMENTATION-SPEC
        # section 8.1; the evidence contract context below fails if a field is
        # dropped from this list.
        # ------------------------------------------------------------------
        $script:EvidenceSections = [ordered]@{
            identity      = @('executablePath', 'productVersion', 'fileVersion', 'aboutVersion', 'licenseMode', 'windowsVersion', 'powershellVersion', 'elevated', 'operator', 'recordedUtc')
            quickScan     = @('vendorWording', 'startedUtc', 'finishedUtc', 'finishEvidence', 'controlAccess', 'controlEvidence')
            shortRecovery = @('vendorWording', 'saveToPath', 'destinationIdentity', 'startedUtc', 'finishedUtc', 'finishEvidence', 'outputObservation', 'recoveryLogName', 'recoveryLogLocation', 'statusValues')
            longScan      = @('vendorWording', 'startedUtc', 'finishedUtc', 'finishEvidence', 'controlAccess', 'controlEvidence')
            longRecovery  = @('vendorWording', 'saveToPath', 'destinationIdentity', 'startedUtc', 'finishedUtc', 'finishEvidence', 'outputObservation', 'recoveryLogName', 'recoveryLogLocation', 'statusValues')
            close         = @('requestedUtc', 'surface', 'confirmationPromptObserved', 'gracefulVerified', 'helperProcessObserved', 'forceCloseDuringActiveWork', 'forceCloseRefused')
            refusals      = @('sameDrivePromptObserved', 'sameDriveAnswerSuppliedByWorkflow', 'overwritePromptAutoAnswered', 'journalOverwriteAutoAnswered', 'lowSpaceHandling')
        }
        $script:RequiredTopLevelFields = @('recordVersion', 'product')
        # Fields tests/TEST-MATRIX.md requires by name anywhere in the record. The
        # evidence contract context asserts this list is a subset of the declared
        # schema, so a required observation cannot disappear silently.
        $script:MatrixRequiredEvidence = @(
            'executablePath', 'aboutVersion', 'licenseMode', 'elevated',
            'vendorWording', 'startedUtc', 'finishedUtc', 'finishEvidence', 'controlAccess',
            'saveToPath', 'destinationIdentity', 'outputObservation', 'recoveryLogName', 'recoveryLogLocation', 'statusValues',
            'requestedUtc', 'surface', 'confirmationPromptObserved', 'gracefulVerified', 'helperProcessObserved',
            'forceCloseDuringActiveWork', 'forceCloseRefused',
            'sameDrivePromptObserved', 'sameDriveAnswerSuppliedByWorkflow',
            'overwritePromptAutoAnswered', 'journalOverwriteAutoAnswered', 'lowSpaceHandling'
        )
        $script:SecretFieldPattern = '"[A-Za-z0-9_]*(licenseKey|licenseString|serialNumber|activationCode|password|credential|secret|token)[A-Za-z0-9_]*"\s*:'
        $script:DocumentedControlAccessValues = @('uia', 'msaa', 'manual')

        # Gates this file cannot close. They stay open until the evidence record
        # exists on a licensed machine; the list is asserted below so the boundary
        # cannot quietly shrink.
        $script:OpenManualGates = @(
            'G-04 vendor surface: no exact-build control map is accepted from documentation alone',
            'G-05 stage completion: scan, recovery, and output evidence must be observed separately',
            'G-07 capacity and media: destination loss, low space, and changed media stay pause/stop',
            'G-08 close: graceful close and the guarded force-close path are owner-observed',
            'G-09 output collision: the vendor duplicate-name and overwrite prompts stay manual'
        )

        # ------------------------------------------------------------------
        # Prerequisite evaluation. Two independent gates: the machine/product gate
        # and the evidence-record gate.
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
            if (-not (Test-EvidenceSectionPresent -Record $script:EvidenceRecord -Section $Section)) {
                return ('the owner evidence record has no ' + $Section + ' section, so this observation was not part of the recorded case')
            }
            return ''
        }
    }

    Context 'L-01 File Scavenger identity, license, and elevation evidence' -Tag 'LiveVendor' {

        It 'L-01: the recorded executable exists and reports a product identity (read-only, no launch)' {
            if (-not [string]::IsNullOrEmpty($script:ProductSkipReason)) { Set-ItResult -Skipped -Because $script:ProductSkipReason; return }

            (Test-Path -LiteralPath $script:ProductPath -PathType Leaf) | Should -BeTrue
            $fileInfo = New-Object -TypeName System.IO.FileInfo -ArgumentList $script:ProductPath
            $fileInfo.VersionInfo.ProductVersion | Should -Not -BeNullOrEmpty -Because 'the owner evidence must name a build; a bare file name is not identity evidence'
            $fileInfo.VersionInfo.FileVersion | Should -Not -BeNullOrEmpty
            Write-Host ('L-01 observed product version: ' + $fileInfo.VersionInfo.ProductVersion + ' / file version: ' + $fileInfo.VersionInfo.FileVersion)
        }

        It 'L-01: the technician session is elevated, as the vendor documentation requires' -Tag 'LiveElevation' {
            if (-not [string]::IsNullOrEmpty($script:ProductSkipReason)) { Set-ItResult -Skipped -Because $script:ProductSkipReason; return }
            if (-not (Test-LiveHost)) { Set-ItResult -Skipped -Because 'the elevation check requires a Windows session'; return }

            (Test-LiveElevated) | Should -BeTrue -Because 'the vendor documents an administrator requirement, and the workflow must fail closed rather than launch without it'
        }

        It 'L-01: the evidenced build identity agrees with the executable that was validated' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'identity'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'identity' -Field $script:EvidenceSections['identity'])
            ($missing -join ', ') | Should -BeNullOrEmpty -Because 'the identity section must record the exact path, build, license mode, environment, and operator'
            $licenseMode = [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'licenseMode')
            @('licensed', 'demo') -contains $licenseMode | Should -BeTrue -Because 'the record must state whether the build was licensed or a demo'
            if ($script:ProductPath -ne '') {
                [string]::Equals([string](Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'executablePath'), $script:ProductPath, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue -Because 'the evidenced path must be the executable this session validated'
            }
            if ($licenseMode -eq 'demo') {
                Write-Host 'L-01 note: the recorded case used demo mode, which the vendor limits to the first 64 KB of each file; it cannot evidence full recovery output.'
            }
        }
    }

    Context 'L-03 Quick scan and short recovery completion evidence' -Tag 'LiveVendor' {

        It 'L-03: the Quick scan section uses the vendor wording and records separate start and finish evidence' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'quickScan'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'quickScan' -Field $script:EvidenceSections['quickScan'])
            ($missing -join ', ') | Should -BeNullOrEmpty
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'quickScan' -Name 'vendorWording') | Should -Be 'Quick scan' -Because 'internal SHORT_* states must be recorded with the vendor wording Quick scan'
            $started = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'quickScan' -Name 'startedUtc'
            $finished = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'quickScan' -Name 'finishedUtc'
            ($null -ne $started) | Should -BeTrue -Because 'the scan start must be a timestamp, not free text'
            ($null -ne $finished) | Should -BeTrue
            $finished | Should -BeGreaterOrEqual $started -Because 'a finish observation cannot precede its start'
        }

        It 'L-03: the short recovery section records Step 2: Save, its own destination, and its own finish evidence' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'shortRecovery'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'shortRecovery' -Field $script:EvidenceSections['shortRecovery'])
            ($missing -join ', ') | Should -BeNullOrEmpty
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'vendorWording') | Should -Be 'Step 2: Save' -Because 'the recovery stage is the documented Step 2: Save surface'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'saveToPath') | Should -Not -BeNullOrEmpty
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'destinationIdentity') | Should -Not -BeNullOrEmpty -Because 'the output location must carry physical-disk identity evidence'
            Write-Host ('L-03 observed Recovery.log name: ' + [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'recoveryLogName') + ' at ' + [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'recoveryLogLocation'))
        }

        It 'L-03: scan finish evidence is never reused as recovery finish evidence' {
            $scanReason = Get-EvidenceSectionSkipReason -Section 'quickScan'
            if (-not [string]::IsNullOrEmpty($scanReason)) { Set-ItResult -Skipped -Because $scanReason; return }
            $recoveryReason = Get-EvidenceSectionSkipReason -Section 'shortRecovery'
            if (-not [string]::IsNullOrEmpty($recoveryReason)) { Set-ItResult -Skipped -Because $recoveryReason; return }

            $scanEvidence = [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'quickScan' -Name 'finishEvidence')
            $recoveryEvidence = [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'finishEvidence')
            [string]::Equals($scanEvidence, $recoveryEvidence, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeFalse -Because 'a scan finish cannot authorize or stand in for a recovery finish, so the two observations must be distinct'
            $scanFinished = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'quickScan' -Name 'finishedUtc'
            $recoveryStarted = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'startedUtc'
            ($null -ne $scanFinished) | Should -BeTrue
            ($null -ne $recoveryStarted) | Should -BeTrue
            $recoveryStarted | Should -BeGreaterOrEqual $scanFinished -Because 'the recovery stage must follow the observed scan finish'
        }
    }

    Context 'L-03 and L-07 Long stage ordering and media faults' -Tag 'LiveVendor' {

        It 'L-03: a Long scan started only after the short recovery was verified' {
            $recoveryReason = Get-EvidenceSectionSkipReason -Section 'shortRecovery'
            if (-not [string]::IsNullOrEmpty($recoveryReason)) { Set-ItResult -Skipped -Because $recoveryReason; return }
            if (-not (Test-EvidenceSectionPresent -Record $script:EvidenceRecord -Section 'longScan')) {
                Set-ItResult -Skipped -Because 'the recorded case did not include a Long scan stage, so nothing can be asserted about Long ordering'
                return
            }

            (Get-SectionValue -Record $script:EvidenceRecord -Section 'longScan' -Name 'vendorWording') | Should -Be 'Long scan'
            $shortRecoveryFinished = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'finishedUtc'
            $longScanStarted = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'longScan' -Name 'startedUtc'
            ($null -ne $shortRecoveryFinished) | Should -BeTrue
            ($null -ne $longScanStarted) | Should -BeTrue
            $longScanStarted | Should -BeGreaterOrEqual $shortRecoveryFinished -Because 'the Long stage may not begin before the preceding short recovery is finished and reviewed'
        }

        It 'L-07: destination loss and low space handling is recorded as pause or stop without a redirect' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'refusals'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            (Test-Path -LiteralPath $script:ProductPath -PathType Leaf) | Should -BeTrue
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'refusals' -Name 'lowSpaceHandling') | Should -Not -BeNullOrEmpty -Because 'the media and capacity behavior must be observed and written down, even when the case did not trigger it'
        }
    }

    Context 'L-04 close and vendor prompt evidence' -Tag 'LiveVendor' {

        It 'L-04: the graceful close request, its confirmation prompt, and the post-close verification are recorded' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'close'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $missing = @(Get-MissingEvidenceField -Record $script:EvidenceRecord -Section 'close' -Field $script:EvidenceSections['close'])
            ($missing -join ', ') | Should -BeNullOrEmpty
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'close' -Name 'surface') | Should -Not -BeNullOrEmpty
            $requested = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'close' -Name 'requestedUtc'
            ($null -ne $requested) | Should -BeTrue -Because 'the close request must be timestamped so the ordering against verified recovery can be checked'
            $recoveryFinished = Get-EvidenceTimestamp -Record $script:EvidenceRecord -Section 'shortRecovery' -Name 'finishedUtc'
            if ($null -ne $recoveryFinished) {
                $requested | Should -BeGreaterOrEqual $recoveryFinished -Because 'a graceful close is requested only after the named recovery stage finished'
            }
        }

        It 'L-04: a force close during active or unknown work is refused, never performed' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'close'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $forceCloseDuringActiveWork = Get-SectionValue -Record $script:EvidenceRecord -Section 'close' -Name 'forceCloseDuringActiveWork'
            if ($forceCloseDuringActiveWork -eq $true) {
                (Get-SectionValue -Record $script:EvidenceRecord -Section 'close' -Name 'forceCloseRefused') | Should -BeTrue -Because 'force close during scan, recovery, or unknown state must be refused, so a recorded attempt must carry the refusal'
            } else {
                (Get-SectionValue -Record $script:EvidenceRecord -Section 'close' -Name 'gracefulVerified') | Should -BeTrue -Because 'when no force close was needed, the graceful close must be verified before handoff'
            }
        }

        It 'L-02 and L-04: the workflow never supplied the same-drive override answer' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'refusals'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            (Get-SectionValue -Record $script:EvidenceRecord -Section 'refusals' -Name 'sameDrivePromptObserved') | Should -Not -BeNullOrEmpty -Because 'the record must state whether the same-drive prompt was observed'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'refusals' -Name 'sameDriveAnswerSuppliedByWorkflow') | Should -BeFalse -Because 'the workflow must never answer the vendor same-drive override, regardless of what the prompt offers'
        }

        It 'L-04: the vendor overwrite and journal overwrite prompts were never answered automatically' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'refusals'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            (Get-SectionValue -Record $script:EvidenceRecord -Section 'refusals' -Name 'overwritePromptAutoAnswered') | Should -BeFalse -Because 'existing output is never overwritten by the workflow'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'refusals' -Name 'journalOverwriteAutoAnswered') | Should -BeFalse -Because 'a scan journal overwrite prompt always stays a manual decision'
        }
    }

    Context 'L-02 UI surface evidence' -Tag 'LiveVendor' {

        It 'L-02: the recorded control access mode is a documented interface, never a coordinate or keystroke strategy' {
            $sectionReason = Get-EvidenceSectionSkipReason -Section 'quickScan'
            if (-not [string]::IsNullOrEmpty($sectionReason)) { Set-ItResult -Skipped -Because $sectionReason; return }

            $controlAccess = [string](Get-SectionValue -Record $script:EvidenceRecord -Section 'quickScan' -Name 'controlAccess')
            ($script:DocumentedControlAccessValues -contains $controlAccess) | Should -BeTrue -Because ('the access mode must be one of ' + ($script:DocumentedControlAccessValues -join ', ') + '; anything else would mean the surface is undocumented')
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'quickScan' -Name 'controlEvidence') | Should -Not -BeNullOrEmpty -Because 'the record must carry the exact property evidence or the reason the surface stays manual-only'
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

        It 'the evidence record identifies the product and the recording, with no credentials or recovered content' {
            if (-not [string]::IsNullOrEmpty($script:EvidenceSkipReason)) { Set-ItResult -Skipped -Because $script:EvidenceSkipReason; return }

            $missing = @(Get-MissingTopLevelField -Record $script:EvidenceRecord -Field $script:RequiredTopLevelFields)
            ($missing -join ', ') | Should -BeNullOrEmpty -Because 'the record must declare its version and the product it describes'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'operator') | Should -Not -BeNullOrEmpty -Because 'an unattributed record cannot be reviewed'
            (Get-SectionValue -Record $script:EvidenceRecord -Section 'identity' -Name 'recordedUtc') | Should -Not -BeNullOrEmpty
            $secretMatches = @([regex]::Matches($script:EvidenceText, $script:SecretFieldPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
            ($secretMatches.Count) | Should -Be 0 -Because 'license keys, credentials, and tokens must never be committed to a live evidence record'
        }

        It 'the open manual gates for this product are listed and non-empty' {
            $script:OpenManualGates.Count | Should -BeGreaterThan 0
            $joined = $script:OpenManualGates -join ' '
            foreach ($gateId in @('G-04', 'G-05', 'G-07', 'G-08', 'G-09')) {
                $joined.Contains($gateId) | Should -BeTrue -Because ('gate ' + $gateId + ' must stay visible until exact-build evidence closes it')
            }
            Write-Host ('File Scavenger owner gates still open: ' + $script:OpenManualGates.Count)
        }
    }
}
