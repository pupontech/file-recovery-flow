Set-StrictMode -Version 3.0

$moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$uiModulePath = Join-Path -Path $moduleRoot -ChildPath 'modules/UIAutomation.psm1'
$scavengerModulePath = Join-Path -Path $moduleRoot -ChildPath 'modules/FileScavenger.psm1'

Import-Module -Name $uiModulePath -Force -ErrorAction Stop
Import-Module -Name $scavengerModulePath -Force -ErrorAction Stop

Describe 'UI Automation safety seam' {
    It 'creates a manual gate with a non-continuing safe default' {
        $gate = New-RecoveryManualGate -GateId 'G-04' -Reason 'No exact-build vendor evidence' -Evidence ([pscustomobject]@{ Source = 'research' }) -Choices @('Manual', 'Stop') -SafeDefault 'Stop'

        $gate.GateId | Should -Be 'G-04'
        $gate.RequiresOperator | Should -BeTrue
        $gate.SafeDefault | Should -Be 'Stop'
        $gate.Decision | Should -BeNullOrEmpty
        $gate.Status | Should -Be 'Pending'
    }

    It 'normalizes application state supplied by the injected UI provider' {
        $processIdentity = [pscustomobject]@{
            Path = 'fixture-file-scavenger.exe'
            Pid = 42
            StartTime = '2026-09-16T09:00:00.0000000Z'
        }
        $calls = New-Object System.Collections.ArrayList
        $provider = {
            param($identity)
            [void]$calls.Add($identity)
            return [pscustomobject]@{
                WindowPresent = $true
                Ready = $true
                Controls = @([pscustomobject]@{ Name = 'validated control'; ControlType = 'Button' })
                StatusLabels = @([pscustomobject]@{ Name = 'Progress'; Value = '0' })
                Messages = @('ready')
            }
        }.GetNewClosure()

        $state = Get-RecoveryAppState -ProcessIdentity $processIdentity -UiProvider $provider

        $state.WindowPresent | Should -BeTrue
        $state.Ready | Should -BeTrue
        $state.Controls.Count | Should -Be 1
        $state.StatusLabels.Count | Should -Be 1
        $state.ProcessIdentity.Pid | Should -Be 42
        $calls.Count | Should -Be 1
    }

    It 'rejects a coordinate or raw-key descriptor before calling the provider' {
        $providerCalls = 0
        $provider = {
            $script:providerCalls++
            return [pscustomobject]@{ Allowed = $true }
        }.GetNewClosure()
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            Name = 'Scan'
            ControlType = 'Button'
            X = 10
            Y = 20
        }

        $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider $provider

        $result.Allowed | Should -BeFalse
        $result.ReasonCode | Should -Be 'UnsupportedUiStrategy'
        $providerCalls | Should -Be 0
    }

    It 'invokes an exact-build descriptor through the injected provider' {
        $calls = New-Object System.Collections.ArrayList
        $provider = {
            param($action, $descriptor)
            [void]$calls.Add([pscustomobject]@{ Action = $action; Descriptor = $descriptor })
            return [pscustomobject]@{ Allowed = $true; MatchCount = 1 }
        }.GetNewClosure()
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            Name = 'Scan'
            ControlType = 'Button'
            MatchCount = 1
        }

        $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider $provider

        $result.Allowed | Should -BeTrue
        $result.Result | Should -Be 'ActionInvoked'
        $calls.Count | Should -Be 1
        $calls[0].Action | Should -Be 'Scan'
    }

    It 'unwraps exactly one provider result instead of inspecting the invocation collection' {
        $returned = [pscustomobject]@{ Allowed = $true; MatchCount = 1 }
        $calls = New-Object System.Collections.ArrayList
        $provider = {
            param($action, $descriptor)
            [void]$calls.Add([pscustomobject]@{ Action = $action })
            return $returned
        }.GetNewClosure()
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            Name = 'Scan'
            ControlType = 'Button'
            MatchCount = 1
        }

        $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider $provider

        $result.Allowed | Should -BeTrue
        $result.Result | Should -Be 'ActionInvoked'
        $result.ProviderResult.GetType().FullName | Should -Be 'System.Management.Automation.PSCustomObject'
        ($result.ProviderResult -is [System.Collections.IEnumerable]) | Should -BeFalse
        $calls.Count | Should -Be 1
    }

    It 'rejects a provider that returns no action result as unknown' {
        $provider = {
            param($action, $descriptor)
        }
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            Name = 'Scan'
            ControlType = 'Button'
            MatchCount = 1
        }

        $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider $provider

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'Unknown'
        $result.ReasonCode | Should -Be 'UiActionUnknown'
    }

    It 'rejects more than one provider action result as an ambiguous unknown' {
        $provider = {
            param($action, $descriptor)
            [pscustomobject]@{ Allowed = $true; MatchCount = 1 }
            [pscustomobject]@{ Allowed = $true; MatchCount = 1 }
        }
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            Name = 'Scan'
            ControlType = 'Button'
            MatchCount = 1
        }

        $result = Invoke-RecoveryUiAction -Action 'Scan' -ControlDescriptor $descriptor -UiProvider $provider

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'Unknown'
        $result.ReasonCode | Should -Be 'UiActionResultAmbiguous'
    }
}

Describe 'File Scavenger launch boundary' {
    It 'launches only a verified executable and passes no scanner arguments' {
        $calls = New-Object System.Collections.ArrayList
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{
                Path = $path
                Pid = 99
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Handle = 'fixture-handle'
                Success = $true
                Alive = $true
            }
        }.GetNewClosure()
        $writer = {
            param($event)
            [void]$events.Add($event)
            return $true
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            FileVersion = '7.1.1.13'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeTrue
        $result.Result | Should -Be 'Launched'
        $result.Arguments.Count | Should -Be 0
        $result.ProcessIdentity.Pid | Should -Be 99
        $calls.Count | Should -Be 1
        $calls[0] | Should -Be 'fixture-scavenger.exe'
        $events.Count | Should -Be 2
    }

    It 'refuses to launch when no durable event writer is supplied' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 105; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner

        $result.Allowed | Should -BeFalse
        $result.Started | Should -BeFalse
        $result.ReasonCode | Should -Be 'EventWriterRequired'
        $calls.Count | Should -Be 0
    }

    It 'records the launch authorization event before the process runner is called' {
        $order = New-Object System.Collections.ArrayList
        $writer = {
            param($event)
            [void]$order.Add('event:' + [string]$event.Result)
            return $true
        }.GetNewClosure()
        $runner = {
            param($path)
            [void]$order.Add('runner')
            return [pscustomobject]@{ Success = $true; Path = $path; Pid = 99; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeTrue
        ($order -join '|') | Should -Be 'event:LaunchAuthorized|runner|event:Launched'
        $result.ProcessIdentity.Pid | Should -Be 99
    }

    It 'refuses to launch when the authorization event is refused by the writer' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 106; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $writer = {
            param($event)
            return $false
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.Started | Should -BeFalse
        $result.ReasonCode | Should -Be 'LaunchAuthorizationNotDurable'
        $result.AuthorizationEvent.Succeeded | Should -BeFalse
        $calls.Count | Should -Be 0
    }

    It 'refuses a structured writer result whose nested data reports failure' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 107; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $writer = {
            param($event)
            return [pscustomobject]@{ Success = $true; Data = [pscustomobject]@{ Success = $false } }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.ReasonCode | Should -Be 'LaunchAuthorizationNotDurable'
        $calls.Count | Should -Be 0
    }

    It 'refuses a structured writer result whose flush reports a failure' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 111; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $writer = {
            param($event)
            return [pscustomobject]@{
                Success = $true
                Append = [pscustomobject]@{ Success = $true }
                Flush = [pscustomobject]@{ Success = $false }
            }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.Started | Should -BeFalse
        $result.ReasonCode | Should -Be 'LaunchAuthorizationNotDurable'
        $result.AuthorizationEvent.Succeeded | Should -BeFalse
        $calls.Count | Should -Be 0
    }

    It 'refuses a writer result that reports a blocked log' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 108; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $writer = {
            param($event)
            return [pscustomobject]@{ Success = $true; IsBlocked = $true }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.ReasonCode | Should -Be 'LaunchAuthorizationNotDurable'
        $calls.Count | Should -Be 0
    }

    It 'refuses a writer that returns no durability result' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 109; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $writer = {
            param($event)
            [void]$event
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.ReasonCode | Should -Be 'LaunchAuthorizationNotDurable'
        $result.AuthorizationEvent.ReasonCode | Should -Be 'EventWriterResultMissing'
        $calls.Count | Should -Be 0
    }

    It 'accepts a structured writer result that reports explicit success' {
        $events = New-Object System.Collections.ArrayList
        $writer = {
            param($event)
            [void]$events.Add($event)
            return [pscustomobject]@{ Success = $true; Sequence = 7 }
        }.GetNewClosure()
        $runner = {
            param($path)
            return [pscustomobject]@{ Success = $true; Path = $path; Pid = 110; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeTrue
        $result.Started | Should -BeTrue
        $events.Count | Should -Be 2
        $result.LaunchEvent.Succeeded | Should -BeTrue
    }

    It 'records the workflow state and event type a durable log writer requires in both launch events' {
        $events = New-Object System.Collections.ArrayList
        $writer = {
            param($event)
            [void]$events.Add($event)
            return $true
        }.GetNewClosure()
        $runner = {
            param($path)
            return [pscustomobject]@{ Success = $true; Path = $path; Pid = 99; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            AttemptId = 'fixture-job-001-short-scan-001'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeTrue
        $events.Count | Should -Be 2
        foreach ($event in $events) {
            $event.EventType | Should -Be 'StageStarted'
            $event.State | Should -Be 'CASE_READY'
            $event.Stage | Should -Be 'LAUNCH'
            $event.AttemptId | Should -Be 'fixture-job-001-short-scan-001'
            ([string]$event.Result).Length | Should -BeGreaterThan 0
        }
    }

    It 'retains the started process identity and fails closed when the launch event cannot be recorded' {
        $events = New-Object System.Collections.ArrayList
        $writer = {
            param($event)
            [void]$events.Add($event)
            if ($events.Count -gt 1) { return $false }
            return $true
        }.GetNewClosure()
        $runner = {
            param($path)
            return [pscustomobject]@{ Success = $true; Path = $path; Pid = 99; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $result.Allowed | Should -BeFalse
        $result.Started | Should -BeTrue
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'LaunchEventNotDurable'
        $result.ProcessIdentity.Pid | Should -Be 99
        $result.ProcessIdentity.Path | Should -Be 'fixture-scavenger.exe'
        $result.SuggestedState | Should -Be 'INTERRUPTED_UNKNOWN'
        $result.RequiresOperator | Should -BeTrue
        $result.NeedsReview | Should -BeTrue
    }

    It 'records the interrupted-unknown event with the retained identity when the launch event fails' {
        $events = New-Object System.Collections.ArrayList
        $writer = {
            param($event)
            [void]$events.Add($event)
            if ($events.Count -gt 1) { return $false }
            return $true
        }.GetNewClosure()
        $runner = {
            param($path)
            return [pscustomobject]@{ Success = $true; Path = $path; Pid = 99; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'CASE_READY'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner -EventWriter $writer

        $events.Count | Should -Be 3
        $events[2].EventType | Should -Be 'StageInterruptedUnknown'
        $events[2].ProcessIdentity.Pid | Should -Be 99
        $result.UnknownEvent.Attempted | Should -BeTrue
        $result.UnknownEvent.Succeeded | Should -BeFalse
    }

    It 'blocks launch when a required durable precondition is missing' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{ Path = $path; Pid = 101; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }.GetNewClosure()
        $executable = [pscustomobject]@{
            Path = 'fixture-scavenger.exe'
            Product = 'File Scavenger'
            ProductVersion = '7.1.1.13'
            EvidenceSource = 'owner-live-record'
            IdentityStatus = 'Verified'
        }
        $state = [pscustomobject]@{
            CurrentState = 'SHORT_SCAN_FINISHED'
            LogFlushed = $true
            LockOwned = $true
            ElevationPassed = $true
            FreshSafetyCheckPassed = $true
        }

        $result = Start-FileScavenger -Executable $executable -State $state -ProcessRunner $runner

        $result.Allowed | Should -BeFalse
        $result.ReasonCode | Should -Be 'StateNotCaseReady'
        $result.Started | Should -BeFalse
        $calls.Count | Should -Be 0
    }
}

Describe 'File Scavenger evidence-gated stages' {
    It 'returns a G-04 manual gate when no exact-build map exists' {
        $result = Request-FileScavengerStage -Stage 'SHORT_SCAN'

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'ManualGate'
        $result.ManualGate.GateId | Should -Be 'G-04'
        $result.ManualGate.SafeDefault | Should -Not -Be 'Continue'
        $result.Evidence.VendorStage | Should -Be 'Quick scan'
    }

    It 'prepares a mapped stage action without inventing launch arguments' {
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            AutomationId = 'fixture-scan-control'
            ControlType = 'Button'
            MatchCount = 1
        }
        $map = [pscustomobject]@{
            Product = 'File Scavenger'
            OwnerValidated = $true
            Build = '7.1.1.13'
            Stages = @{
                SHORT_SCAN = [pscustomobject]@{
                    Action = 'Scan'
                    ControlDescriptor = $descriptor
                    ResultEvidence = [pscustomobject]@{ Observed = $true; Source = 'owner-live-record' }
                }
            }
        }
        $executable = [pscustomobject]@{ ProductVersion = '7.1.1.13' }
        $state = [pscustomobject]@{ CurrentState = 'CASE_READY' }

        $result = Request-FileScavengerStage -Stage 'SHORT_SCAN' -EvidenceMap $map -State $state -Executable $executable

        $result.Allowed | Should -BeTrue
        $result.Result | Should -Be 'ActionReady'
        $result.VendorStage | Should -Be 'Quick scan'
        $result.Action | Should -Be 'Scan'
        $result.Arguments.Count | Should -Be 0
    }

    It 'refuses Long scan until short recovery is verified' {
        $state = [pscustomobject]@{ CurrentState = 'SHORT_SCAN_FINISHED' }

        $result = Request-FileScavengerStage -Stage 'LONG_SCAN' -State $state

        $result.Allowed | Should -BeFalse
        $result.ManualGate.GateId | Should -Be 'G-05'
        $result.Evidence.Stage | Should -Be 'LONG_SCAN'
    }
}

Describe 'File Scavenger completion evidence' {
    It 'keeps scan completion separate from recovery completion' {
        $result = Test-FileScavengerCompletion -Stage 'SHORT_SCAN' -Observation ([pscustomobject]@{
            ScanFinished = $true
            RecoveryFinished = $false
            WindowPresent = $true
        })

        $result.Allowed | Should -BeTrue
        $result.Completed | Should -BeTrue
        $result.Result | Should -Be 'ScanFinished'
        $result.Verified | Should -BeFalse
        $result.RecoveryFinished | Should -BeFalse
    }

    It 'does not infer completion from process exit, window loss, progress, or output alone' {
        $result = Test-FileScavengerCompletion -Stage 'SHORT_RECOVERY' -Observation ([pscustomobject]@{
            ProcessExited = $true
            WindowPresent = $false
            Progress = 100
            OutputObserved = $true
        })

        $result.Allowed | Should -BeFalse
        $result.Completed | Should -BeFalse
        $result.Result | Should -Be 'OutputObserved'
        $result.Verified | Should -BeFalse
    }

    It 'requires recovery output verification before reporting a verified recovery' {
        $result = Test-FileScavengerCompletion -Stage 'SHORT_RECOVERY' -Observation ([pscustomobject]@{
            RecoveryFinished = $true
            OutputObserved = $true
            OutputVerificationPassed = $true
            WindowPresent = $true
        })

        $result.Allowed | Should -BeTrue
        $result.Completed | Should -BeTrue
        $result.Result | Should -Be 'RecoveryVerified'
        $result.Verified | Should -BeTrue
    }
}

Describe 'File Scavenger observation seam' {
    It 'keeps application status and output artifacts as separate observations' {
        $appProvider = {
            return [pscustomobject]@{
                WindowPresent = $true
                Ready = $true
                ProcessAlive = $true
                WindowTitle = 'File Scavenger fixture'
                Unknown = $false
                StatusLabels = @([pscustomobject]@{ Name = 'Scan status'; Value = 'waiting' })
                Messages = @('ready')
            }
        }
        $outputProvider = {
            return [pscustomobject]@{
                OutputObserved = $true
                RecoveryLog = [pscustomobject]@{ Observed = $true }
                ObservedArtifacts = @('fixture-output.bin')
                SessionFiles = @('fixture-session.fss')
                CsvFiles = @('fixture-list.csv')
                Journal = [pscustomobject]@{ Observed = $false }
            }
        }

        $observation = Get-FileScavengerObservation -AppStateProvider $appProvider -OutputProvider $outputProvider

        $observation.Unknown | Should -BeFalse
        $observation.ProcessAlive | Should -BeTrue
        $observation.WindowTitle | Should -Be 'File Scavenger fixture'
        $observation.StatusLabels.Count | Should -Be 1
        $observation.OutputObserved | Should -BeTrue
        $observation.RecoveryLog.Observed | Should -BeTrue
        $observation.SessionFiles.Count | Should -Be 1
        $observation.CsvFiles.Count | Should -Be 1
    }

    It 'returns unknown when an observation provider is unavailable' {
        $observation = Get-FileScavengerObservation

        $observation.Unknown | Should -BeTrue
        $observation.ReasonCode | Should -Be 'ApplicationObservationUnknown'
        $observation.OutputObserved | Should -BeFalse
    }

    It 'refuses close when the application state cannot prove that no work is active' {
        $identity = [pscustomobject]@{ Path = 'fixture-scavenger.exe'; Pid = 77; StartTime = '2026-09-16T09:00:00.0000000Z' }
        $appProvider = {
            return [pscustomobject]@{
                WindowPresent = $true
                Ready = $true
            }
        }

        $observation = Get-FileScavengerObservation -ProcessIdentity $identity -AppStateProvider $appProvider

        $observation.Unknown | Should -BeTrue
        $observation.ApplicationState.Unknown | Should -BeTrue

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.ManualGate.GateId | Should -Be 'G-08'
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }
}

Describe 'File Scavenger close guards' {
    It 'does not close while recovery state is unknown or active' {
        $result = Request-FileScavengerGracefulClose -Observation ([pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_RUNNING'
            Unknown = $false
            ActiveWork = $true
        })

        $result.Allowed | Should -BeFalse
        $result.ManualGate.GateId | Should -Be 'G-08'
        $result.ManualGate.SafeDefault | Should -Be 'Leave active state untouched'
    }

    It 'requests documented Exit only from verified recovery with an exact-build map' {
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            AutomationId = 'fixture-exit-control'
            ControlType = 'MenuItem'
            MatchCount = 1
        }
        $map = [pscustomobject]@{
            Product = 'File Scavenger'
            OwnerValidated = $true
            Build = '7.1.1.13'
            GracefulClose = [pscustomobject]@{ Action = 'Exit'; ControlDescriptor = $descriptor }
        }
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = $false
            ActiveWork = $false
            ProcessIdentity = [pscustomobject]@{ Path = 'fixture-scavenger.exe'; Pid = 77; StartTime = '2026-09-16T09:00:00.0000000Z' }
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation -EvidenceMap $map

        $result.Allowed | Should -BeTrue
        $result.Result | Should -Be 'GracefulCloseRequested'
        $result.Action | Should -Be 'Exit'
        $result.CloseVerified | Should -BeFalse
        $result.RequiresVerification | Should -BeTrue
    }

    It 'blocks close when a nested scan flag is true while active work is reported false' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = $false
            ActiveWork = $false
            ApplicationState = [pscustomobject]@{
                ActiveWork = $false
                ScanRunning = $true
                RecoveryRunning = $false
                Unknown = $false
            }
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.ManualGate.GateId | Should -Be 'G-08'
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'blocks close when the observation itself reports recovery running while active work is false' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = $false
            ActiveWork = $false
            RecoveryRunning = $true
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'blocks close when the nested application state is unknown while the observation claims otherwise' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = $false
            ActiveWork = $false
            ApplicationState = [pscustomobject]@{
                ActiveWork = $false
                ScanRunning = $false
                RecoveryRunning = $false
                Unknown = $true
            }
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'blocks close when the application confidence is unknown even though the flags are false' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = $false
            ActiveWork = $false
            ApplicationState = [pscustomobject]@{
                ActiveWork = $false
                ScanRunning = $false
                RecoveryRunning = $false
                Unknown = $false
                Confidence = 'Unknown'
            }
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'blocks close on a contradictory running state even when every activity flag is false' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_RUNNING'
            Unknown = $false
            ActiveWork = $false
            ScanRunning = $false
            RecoveryRunning = $false
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'blocks close when an activity indicator is present but cannot be read as a boolean' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = $false
            ActiveWork = $false
            ApplicationState = [pscustomobject]@{
                ActiveWork = $false
                ScanRunning = 'Yes'
                RecoveryRunning = $false
                Unknown = $false
                Confidence = 'Observed'
            }
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.ManualGate.GateId | Should -Be 'G-08'
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'blocks close when the unknown indicator is present but cannot be read as a boolean' {
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            Unknown = 'Unknown'
            ActiveWork = $false
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation

        $result.Allowed | Should -BeFalse
        $result.ManualGate.GateId | Should -Be 'G-08'
        $result.Evidence.ReasonCode | Should -Be 'CloseStateUnknownOrActive'
    }

    It 'allows close when a verified recovery reports no activity through the nested application state' {
        $descriptor = [pscustomobject]@{
            Validated = $true
            ExactBuildMatch = $true
            EvidenceSource = 'owner-live-record'
            AutomationId = 'fixture-exit-control'
            ControlType = 'MenuItem'
            MatchCount = 1
        }
        $map = [pscustomobject]@{
            Product = 'File Scavenger'
            OwnerValidated = $true
            Build = '7.1.1.13'
            GracefulClose = [pscustomobject]@{ Action = 'Exit'; ControlDescriptor = $descriptor }
        }
        $observation = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            ProcessIdentity = [pscustomobject]@{ Path = 'fixture-scavenger.exe'; Pid = 77; StartTime = '2026-09-16T09:00:00.0000000Z' }
            ApplicationState = [pscustomobject]@{
                ActiveWork = $false
                ScanRunning = $false
                RecoveryRunning = $false
                Unknown = $false
                Confidence = 'Observed'
            }
        }

        $result = Request-FileScavengerGracefulClose -Observation $observation -EvidenceMap $map

        $result.Allowed | Should -BeTrue
        $result.Result | Should -Be 'GracefulCloseRequested'
    }

    It 'denies force close during active recovery and permits only a confirmed bound request after verification' {
        $activeState = [pscustomobject]@{ CurrentState = 'SHORT_RECOVERY_RUNNING' }
        $identity = [pscustomobject]@{ Path = 'fixture-scavenger.exe'; Pid = 77; StartTime = '2026-09-16T09:00:00.0000000Z' }

        $active = Request-FileScavengerForceClose -State $activeState -ProcessIdentity $identity -Confirmation $true

        $active.Allowed | Should -BeFalse
        $active.ReasonCode | Should -Be 'ForceCloseActiveOrUnknown'

        $verifiedState = [pscustomobject]@{
            CurrentState = 'SHORT_RECOVERY_VERIFIED'
            RecoveryFinished = $true
            JobId = 'fixture-job-001'
            ProcessIdentity = $identity
        }
        $verified = Request-FileScavengerForceClose -State $verifiedState -ProcessIdentity $identity -Confirmation $true

        $verified.Allowed | Should -BeTrue
        $verified.Result | Should -Be 'ForceCloseRequested'
        $verified.GuardSatisfied | Should -BeTrue
        $verified.PostCloseVerificationRequired | Should -BeTrue
    }
}

Describe 'File Scavenger launch outcome verification' {

    BeforeAll {
        function New-LaunchExecutable {
            [CmdletBinding()]
            param()

            return [pscustomobject]@{
                Path           = 'fixture-scavenger.exe'
                Product        = 'File Scavenger'
                ProductVersion = '7.1.1.13'
                EvidenceSource = 'owner-live-record'
                IdentityStatus = 'Verified'
            }
        }

        function New-LaunchState {
            [CmdletBinding()]
            param([string]$CurrentState = 'CASE_READY')

            return [pscustomobject]@{
                CurrentState           = $CurrentState
                LogFlushed             = $true
                LockOwned              = $true
                ElevationPassed        = $true
                FreshSafetyCheckPassed = $true
            }
        }

        function New-LaunchEventRecorder {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][object]$Target)

            return {
                param($event)
                [void]$Target.Add($event)
                return $true
            }.GetNewClosure()
        }
    }

    It 'refuses a runner result that states an explicit Boolean failure and retains the reported identity' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $false
                Path      = $path
                Pid       = 4201
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'RunnerReportedFailure'
        $result.Started | Should -BeTrue
        $result.SuggestedState | Should -Be 'INTERRUPTED_UNKNOWN'
        $result.ProcessIdentity.Pid | Should -Be 4201
        $result.ProcessIdentity.Path | Should -Be 'fixture-scavenger.exe'
        @($events | Where-Object { [string]$_.Result -eq 'Launched' }).Count | Should -Be 0
    }

    It 'refuses a runner result that reports the process already exited' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $true
                Path      = $path
                Pid       = 4202
                StartTime = '2026-09-16T09:00:00.0000000Z'
                HasExited = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'ProcessNotAlive'
        $result.ProcessIdentity.Pid | Should -Be 4202
        @($events | Where-Object { [string]$_.Result -eq 'Launched' }).Count | Should -Be 0
    }

    It 'refuses a runner result that states no liveness at all' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $true
                Path      = $path
                Pid       = 4203
                StartTime = '2026-09-16T09:00:00.0000000Z'
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'ProcessLivenessUnstated'
        $result.ProcessIdentity.Pid | Should -Be 4203
    }

    It 'refuses contradictory liveness statements' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $true
                Path      = $path
                Pid       = 4204
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
                HasExited = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'ProcessLivenessContradictory'
        $result.ProcessIdentity.Pid | Should -Be 4204
    }

    It 'refuses a non-Boolean success statement' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = 'true'
                Path      = $path
                Pid       = 4205
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'RunnerSuccessNotBoolean'
    }

    It 'refuses an absent success statement' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Path      = $path
                Pid       = 4206
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'RunnerSuccessMissing'
    }

    It 'never falls back to the requested path when the runner reports no executable path' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $true
                Pid       = 4207
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'ProcessPathMissing'
        # The identity keeps only what the runner reported: the PID identifies the
        # process, while the path stays empty instead of being filled in from the
        # requested executable.
        $result.ProcessIdentity.Pid | Should -Be 4207
        $result.ProcessIdentity.Path | Should -BeNullOrEmpty
    }

    It 'refuses a runner result whose reported path does not match the verified executable' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $true
                Path      = 'fixture-other.exe'
                Pid       = 4208
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'ProcessPathMismatch'
        $result.Started | Should -BeTrue
        $result.ProcessIdentity.Path | Should -Be 'fixture-other.exe'
    }

    It 'refuses a runner result that reports scanner arguments as an interrupted-unknown outcome' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success   = $true
                Path      = $path
                Pid       = 4209
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive     = $true
                Arguments = @('-undocumented-switch')
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'UnexpectedLaunchArguments'
        $result.ProcessIdentity.Pid | Should -Be 4209
    }

    It 'treats zero runner results as an interrupted-unknown outcome' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$path
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'ProcessIdentityMissing'
        $result.Started | Should -BeFalse
        $result.RunnerInvoked | Should -BeTrue
        $result.VendorProcessPossible | Should -BeTrue
        $result.SuggestedState | Should -Be 'INTERRUPTED_UNKNOWN'
    }

    It 'treats multiple runner results as an interrupted-unknown outcome' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return @(
                [pscustomobject]@{ Success = $true; Path = $path; Pid = 4210; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
                [pscustomobject]@{ Success = $true; Path = $path; Pid = 4211; StartTime = '2026-09-16T09:00:00.0000000Z'; Alive = $true }
            )
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'AmbiguousProcessIdentity'
        $result.ProcessIdentity | Should -BeNullOrEmpty
        $result.VendorProcessPossible | Should -BeTrue
    }

    It 'treats a throwing runner as an interrupted-unknown outcome' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            throw ('launch failed for ' + [string]$path)
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'InterruptedUnknown'
        $result.ReasonCode | Should -Be 'LaunchOutcomeUnknown'
        $result.VendorProcessPossible | Should -BeTrue
        $result.ProcessIdentity | Should -BeNullOrEmpty
        @($events | Where-Object { $_.EventType -eq 'StageInterruptedUnknown' }).Count | Should -Be 1
    }

    It 'emits one durable interrupted-unknown event with the retained identity and no launch event' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success = $true
                Path    = $path
                Pid     = 4212
                StartTime = '2026-09-16T09:00:00.0000000Z'
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $events.Count | Should -Be 2
        $events[1].EventType | Should -Be 'StageInterruptedUnknown'
        $events[1].Stage | Should -Be 'LAUNCH'
        $events[1].Result | Should -Be 'InterruptedUnknown'
        $events[1].ProcessIdentity.Pid | Should -Be 4212
        @($events | Where-Object { [string]$_.Result -eq 'Launched' }).Count | Should -Be 0
        $result.UnknownEvent.Attempted | Should -BeTrue
        $result.UnknownEvent.Succeeded | Should -BeTrue
        $result.LaunchEvent | Should -BeNullOrEmpty
    }

    It 'allows no retry, no close, and no later vendor action for an ambiguous result' {
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            return [pscustomobject]@{
                Success = $true
                Path    = $path
                Pid     = 4213
                StartTime = '2026-09-16T09:00:00.0000000Z'
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState) `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.RetryAllowed | Should -BeFalse
        $result.CloseAllowed | Should -BeFalse
        $result.VendorActionAllowed | Should -BeFalse
        $result.RequiresOperator | Should -BeTrue
        $result.NeedsReview | Should -BeTrue
        $result.ManualGate | Should -BeNullOrEmpty
    }

    It 'keeps a pre-launch refusal distinguishable from an interrupted-unknown outcome' {
        $events = New-Object System.Collections.ArrayList
        $calls = New-Object System.Collections.ArrayList
        $events = New-Object System.Collections.ArrayList
        $runner = {
            param($path)
            [void]$calls.Add($path)
            return [pscustomobject]@{
                Success = $true
                Path    = $path
                Pid     = 4214
                StartTime = '2026-09-16T09:00:00.0000000Z'
                Alive   = $true
            }
        }.GetNewClosure()

        $result = Start-FileScavenger -Executable (New-LaunchExecutable) -State (New-LaunchState -CurrentState 'SHORT_SCAN_FINISHED') `
            -ProcessRunner $runner -EventWriter (New-LaunchEventRecorder -Target $events)

        $result.Allowed | Should -BeFalse
        $result.Result | Should -Be 'Blocked'
        $result.RunnerInvoked | Should -BeFalse
        $result.VendorProcessPossible | Should -BeFalse
        $result.SuggestedState | Should -BeNullOrEmpty
        $result.UnknownEvent | Should -BeNullOrEmpty
        $result.ProcessIdentity | Should -BeNullOrEmpty
        $calls.Count | Should -Be 0
    }
}
