<#
.SYNOPSIS
Unit tests for the append-only case log content guard in modules/RecoveryLogging.psm1.

.DESCRIPTION
The case log is an append-only record. While the case is live the writer compares
the recorded length and a digest of the whole record before every append, so a
same-length rewrite of any part of the history is refused and the refusal blocks
every later write. Before this lane the digest covered only the trailing 256-byte
window, so a same-length rewrite of older history was accepted and the case kept
appending on top of edited history.

No vendor application, storage device, or process is touched: every fixture is a
plain file under TestDrive: and the module is imported from the repository.

Honest limitation pinned by these tests: a log that was rewritten BEFORE it was
resumed has no trusted prior state, so the resume path takes the content it finds
as its starting point. The guard proves that the content is unchanged since the
writer opened it, not that the history was never edited before that moment.
#>

Set-StrictMode -Version 3.0

$moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$loggingModulePath = Join-Path -Path $moduleRoot -ChildPath 'modules/RecoveryLogging.psm1'

Import-Module -Name $loggingModulePath -Force -ErrorAction Stop

Describe 'Recovery log content integrity guard' {

    BeforeAll {
        function New-IntegrityLogFixture {
            [CmdletBinding()]
            param(
                [string]$FolderName = 'integrity-log',
                [string]$JobId = 'INTEG-0001'
            )

            $folder = Join-Path -Path $TestDrive -ChildPath $FolderName
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            return [pscustomobject]@{
                Folder  = $folder
                LogPath = (Join-Path -Path $folder -ChildPath 'events.jsonl')
                JobId   = $JobId
            }
        }

        function New-IntegrityEntry {
            [CmdletBinding()]
            param(
                [string]$JobId = 'INTEG-0001',
                [string]$Result = 'Recorded',
                [string]$EventType = 'StageStarted'
            )

            return @{
                JobId     = $JobId
                State     = 'CASE_READY'
                Stage     = 'PREFLIGHT'
                EventType = $EventType
                Result    = $Result
            }
        }

        function Add-IntegrityRecords {
            # Records carry a padded result so the record is larger than the
            # 256-byte window the previous guard hashed, and so the file holds a
            # region that the old window never covered.
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][object]$Writer,
                [Parameter(Mandatory = $true)][string]$JobId,
                [int]$Count = 4
            )

            for ($index = 1; $index -le $Count; $index++) {
                $padding = 'P' * 200
                $written = Write-RecoveryLogEntry -Writer $Writer -Entry (New-IntegrityEntry -JobId $JobId -EventType ('StageStarted' + $padding))
                $written.Success | Should -BeTrue
            }
        }

        function Write-SameLengthByteFlip {
            # Changes one byte of the record without changing the file length, the
            # way an out-of-band edit of the history looks to the writer.
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [int]$Offset = 10
            )

            $bytes = [System.IO.File]::ReadAllBytes($Path)
            $original = $bytes[$Offset]
            $replacement = [byte]0x7A
            if ($original -eq $replacement) { $replacement = [byte]0x79 }
            $bytes[$Offset] = $replacement
            [System.IO.File]::WriteAllBytes($Path, $bytes)
            return $bytes.Length
        }
    }

    It 'refuses a same-length rewrite outside the trailing window while the log is live' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-prefix' -JobId 'INTEG-0002'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        $handle.Success | Should -BeTrue
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId

        $lengthBefore = (New-Object System.IO.FileInfo($fixture.LogPath)).Length
        $lengthBefore | Should -BeGreaterThan 512
        $lengthAfterFlip = Write-SameLengthByteFlip -Path $fixture.LogPath -Offset 10
        $lengthAfterFlip | Should -Be $lengthBefore

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
        $handle.Writer.IsBlocked | Should -BeTrue
        (New-Object System.IO.FileInfo($fixture.LogPath)).Length | Should -Be $lengthBefore
    }

    It 'refuses a same-length rewrite inside the last record' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-tail' -JobId 'INTEG-0003'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId

        $length = (New-Object System.IO.FileInfo($fixture.LogPath)).Length
        [void](Write-SameLengthByteFlip -Path $fixture.LogPath -Offset ($length - 40))

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
        $handle.Writer.IsBlocked | Should -BeTrue
    }

    It 'refuses an out-of-band length change' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-length' -JobId 'INTEG-0004'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId

        [System.IO.File]::AppendAllText($fixture.LogPath, '{"EventId":"out-of-band"}' + [char]10)

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
        $handle.Writer.IsBlocked | Should -BeTrue
    }

    It 'blocks every later write after a content refusal' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-blocked' -JobId 'INTEG-0005'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId
        [void](Write-SameLengthByteFlip -Path $fixture.LogPath -Offset 10)

        $refused = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)
        $later = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)
        $flushed = Sync-RecoveryLog -Writer $handle.Writer

        $refused.ReasonCode | Should -Be 'LogAppendFailed'
        $later.Success | Should -BeFalse
        $later.ReasonCode | Should -Be 'LogWriteBlocked'
        $flushed.Success | Should -BeFalse
        $flushed.ReasonCode | Should -Be 'LogWriteBlocked'
    }

    It 'verifies the whole content of a log larger than the read buffer' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-large' -JobId 'INTEG-0006'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        $handle.Success | Should -BeTrue
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId -Count 600

        $length = (New-Object System.IO.FileInfo($fixture.LogPath)).Length
        $length | Should -BeGreaterThan 131072
        [void](Write-SameLengthByteFlip -Path $fixture.LogPath -Offset 10)

        $written = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
    }

    It 'still appends and resumes a log whose history was not changed' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-clean' -JobId 'INTEG-0007'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        $handle.Success | Should -BeTrue
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId

        $next = Write-RecoveryLogEntry -Writer $handle.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)
        $next.Success | Should -BeTrue
        $next.Sequence | Should -Be 5

        $resumed = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Resume
        $resumed.Success | Should -BeTrue
        $resumed.Sequence | Should -Be 5

        $afterResume = Write-RecoveryLogEntry -Writer $resumed.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)
        $afterResume.Success | Should -BeTrue
        $afterResume.Sequence | Should -Be 6

        $audit = Test-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        $audit.IsValid | Should -BeTrue
        $audit.LastSequence | Should -Be 6
    }

    It 'refuses a same-length rewrite made after a resume' {
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-resume-live' -JobId 'INTEG-0008'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId
        $resumed = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Resume
        $resumed.Success | Should -BeTrue

        [void](Write-SameLengthByteFlip -Path $fixture.LogPath -Offset 10)

        $written = Write-RecoveryLogEntry -Writer $resumed.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)

        $written.Success | Should -BeFalse
        $written.ReasonCode | Should -Be 'LogAppendFailed'
    }

    It 'accepts a log whose pre-resume history was rewritten, because a resume has no trusted prior state' {
        # This is the honest negative case: the content guard proves the record has
        # not changed since the writer opened it. A rewrite that happened before
        # the resume is invisible, because there is no earlier digest to compare
        # against. The limitation is pinned here so it cannot silently disappear.
        $fixture = New-IntegrityLogFixture -FolderName 'integrity-preresume' -JobId 'INTEG-0009'
        $handle = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId
        Add-IntegrityRecords -Writer $handle.Writer -JobId $fixture.JobId

        # Flip a byte inside a quoted value: the record stays valid JSON with the
        # same length, and the sequence numbers are untouched.
        $bytes = [System.IO.File]::ReadAllBytes($fixture.LogPath)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $needle = 'Recorded'
        $offset = $text.IndexOf($needle)
        $offset | Should -BeGreaterThan 0
        $bytes[$offset] = [byte][char]'X'
        [System.IO.File]::WriteAllBytes($fixture.LogPath, $bytes)

        $rewritten = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($fixture.LogPath))
        $rewritten.Substring($offset, $needle.Length) | Should -Be 'Xecorded'

        $resumed = New-RecoveryLog -Path $fixture.LogPath -JobId $fixture.JobId -Resume

        $resumed.Success | Should -BeTrue
        $afterResume = Write-RecoveryLogEntry -Writer $resumed.Writer -Entry (New-IntegrityEntry -JobId $fixture.JobId)
        $afterResume.Success | Should -BeTrue
        $afterResume.Sequence | Should -Be 5
    }

    It 'keeps the content guard streamed, buffer-bounded, and free of a length cast' {
        $module = Get-Module -Name 'RecoveryLogging'
        $module | Should -Not -BeNullOrEmpty
        $modulePath = [string]$module.Path
        $modulePath | Should -Not -BeNullOrEmpty
        $moduleText = [System.IO.File]::ReadAllText($modulePath)

        $moduleText | Should -Match 'function Get-RecoveryLogContentHash'
        $moduleText | Should -Not -Match 'Get-RecoveryLogTailHash'
        $moduleText | Should -Not -Match 'TailLength'

        $start = $moduleText.IndexOf('function Get-RecoveryLogContentHash')
        $start | Should -BeGreaterThan 0
        $nextFunction = $moduleText.IndexOf('function ', $start + 1)
        $nextFunction | Should -BeGreaterThan $start
        $hashFunction = $moduleText.Substring($start, $nextFunction - $start)

        # The digest is produced by a fixed-size streaming buffer: no whole-file
        # allocation and no [int] cast of a file length that could truncate.
        $hashFunction | Should -Not -Match 'ReadAllBytes'
        $hashFunction | Should -Not -Match '\[int\]'
        $hashFunction | Should -Match '65536'

        # Both the open (create and resume) and the append paths use it.
        $providerStart = $moduleText.IndexOf('function Get-RecoveryDefaultLogWriterProvider')
        $providerText = $moduleText.Substring($providerStart)
        $providerText | Should -Match 'Get-RecoveryLogContentHash'

        # The module must state the guarantee it actually provides: a consistency
        # guard for a single cooperative writer, not tamper-proof storage and not
        # immutable history. Comment markers are stripped so a statement split
        # across comment lines is still read as one sentence.
        $normalized = (@($moduleText -split [string][char]10 | ForEach-Object { $_ -replace '^\s*#\s?', '' })) -join ' '
        $normalized | Should -Match 'not\s+tamper-proof'
        $normalized | Should -Match 'single cooperative writer'
    }
}
