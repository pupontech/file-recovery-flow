BeforeAll {
    Import-Module (Join-Path (Join-Path $PSScriptRoot '..') '../modules/DiskDetection.psm1') -Force
}

Describe 'Job folder preclaim safety boundary' {
    It 'refuses a denied candidate before creating its folder or claim marker' {
        $root = Join-Path $TestDrive 'denied'
        [void][System.IO.Directory]::CreateDirectory($root)
        $calls = New-Object System.Collections.Generic.List[object]
        $check = {
            param($request)
            $calls.Add($request)
            [pscustomobject]@{ Allowed = $false; ReasonCode = 'SamePhysicalDisk' }
        }.GetNewClosure()

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client' -PreclaimSafetyCheck $check

        $result.Created | Should -BeFalse
        $result.ReasonCode | Should -Be 'SamePhysicalDisk'
        $calls.Count | Should -Be 1
        $calls[0].Stage | Should -Be 'BeforeDirectoryCreate'
        [System.IO.Path]::GetDirectoryName($calls[0].Path) | Should -Be $root
        # The candidate does not exist, so the gate must hand the callback the path
        # that can actually be proven. A gate that only offered the candidate would
        # be unanswerable for every healthy run.
        $calls[0].PathExists | Should -BeFalse
        $calls[0].ProofPath | Should -Be $root
        $calls[0].ProofPathExists | Should -Be $true
        @([System.IO.Directory]::GetFileSystemEntries($root)).Count | Should -Be 0
    }

    It 'rejects unknown or ambiguous callback evidence before any directory write' {
        $checks = @(
            { $null },
            { [pscustomobject]@{ Allowed = 'true' } },
            { [pscustomobject]@{ Allowed = 1 } },
            { [pscustomobject]@{ Success = $true } },
            { [pscustomobject]@{ Allowed = $true }; [pscustomobject]@{ Allowed = $true } },
            { throw 'No topology' }
        )
        foreach ($check in $checks) {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][System.IO.Directory]::CreateDirectory($root)
            $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client' -PreclaimSafetyCheck $check
            $result.Created | Should -BeFalse
            $result.ReasonCode | Should -Be 'PreclaimSafetyUnproven'
            @([System.IO.Directory]::GetFileSystemEntries($root)).Count | Should -Be 0
        }
    }

    It 'checks each collision-free candidate and retains the no-overwrite contract' {
        $root = Join-Path $TestDrive 'collisions'
        [void][System.IO.Directory]::CreateDirectory($root)
        $clock = { [datetime]'2026-09-16T07:00:00Z' }
        $calls = New-Object System.Collections.Generic.List[object]
        $check = { param($request) $calls.Add($request); [pscustomobject]@{ Allowed = $true } }.GetNewClosure()
        $first = New-RecoveryJobFolder -RootPath $root -ClientName 'Client' -Clock $clock -PreclaimSafetyCheck $check
        $bytes = [System.IO.File]::ReadAllText($first.ClaimPath)
        $second = New-RecoveryJobFolder -RootPath $root -ClientName 'Client' -Clock $clock -PreclaimSafetyCheck $check
        $first.Created | Should -BeTrue
        $second.Created | Should -BeTrue
        $second.CollisionIndex | Should -Be 1
        $calls.Count | Should -Be 4
        $calls[2].Path | Should -Be $second.JobFolderPath
        $calls[3].Path | Should -Be $second.JobFolderPath
        [System.IO.File]::ReadAllText($first.ClaimPath) | Should -BeExactly $bytes
    }

    It 'rechecks the actual folder before writing a claim and preserves it on refusal' {
        $root = Join-Path $TestDrive 'changed'
        [void][System.IO.Directory]::CreateDirectory($root)
        $calls = New-Object System.Collections.Generic.List[object]
        $check = {
            param($request)
            $calls.Add($request)
            [pscustomobject]@{ Allowed = ($request.Stage -eq 'BeforeDirectoryCreate'); ReasonCode = 'DestinationChanged' }
        }.GetNewClosure()

        $result = New-RecoveryJobFolder -RootPath $root -ClientName 'Client' -PreclaimSafetyCheck $check

        $result.Created | Should -BeFalse
        $result.ReasonCode | Should -Be 'DestinationChanged'
        $calls.Count | Should -Be 2
        $calls[1].Stage | Should -Be 'BeforeClaimWrite'
        $calls[1].Path | Should -Be $calls[0].Path
        [System.IO.Directory]::Exists($calls[0].Path) | Should -BeTrue
        @([System.IO.Directory]::GetFileSystemEntries($calls[0].Path)).Count | Should -Be 0
    }
}
