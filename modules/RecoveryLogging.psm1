# RecoveryLogging.psm1
#
# Append only, machine readable event log for a recovery case.
#
# The log is one JSONL record per event with a monotonic sequence, a UTC
# timestamp, the job identity, the state/stage/attempt context, the result, the
# source and destination identity references, and structured error or decision
# details. The writer emits ASCII safe JSONL: dynamic values are escaped so a
# non ASCII character can never be silently replaced, and a serialization or
# flush failure blocks the next external action instead of continuing.
#
# Writer seam: a provider is an object exposing Open/Append/Flush/Close script
# blocks. Each operation receives one hashtable request and either returns a
# result or throws. A missing operation, a throw, or a returned false is a
# failure.

Set-StrictMode -Off

function ConvertTo-RecoveryLogProviderDecision {
    # Normalizes one provider operation result into exactly one explicit success
    # decision. A structured result must state Success = $true; a missing or
    # non Boolean success field is ambiguous and is refused, because a refusal
    # that is read as success would authorize the next external action without a
    # durable event.
    param(
        [object]$Operation,
        [object]$Data
    )
    if ($null -eq $Data) {
        return [pscustomobject]@{ Success = $false; ReasonCode = 'ProviderRefused'; Message = ("Operation '{0}' returned no result." -f $Operation) }
    }
    if ($Data -is [bool]) {
        if ($Data) { return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null } }
        return [pscustomobject]@{ Success = $false; ReasonCode = 'ProviderRefused'; Message = ("Operation '{0}' was refused by the writer provider." -f $Operation) }
    }
    $hasSuccess = $false
    $successValue = $null
    $reason = $null
    $message = $null
    if ($Data -is [System.Collections.IDictionary]) {
        if ($Data.Contains('Success')) {
            $hasSuccess = $true
            $successValue = $Data['Success']
        }
        if ($Data.Contains('ReasonCode')) { $reason = $Data['ReasonCode'] }
        if ($Data.Contains('Message')) { $message = $Data['Message'] }
    }
    else {
        $property = $Data.PSObject.Properties['Success']
        if ($null -ne $property) {
            $hasSuccess = $true
            $successValue = $property.Value
        }
        $reasonProperty = $Data.PSObject.Properties['ReasonCode']
        if ($null -ne $reasonProperty) { $reason = $reasonProperty.Value }
        $messageProperty = $Data.PSObject.Properties['Message']
        if ($null -ne $messageProperty) { $message = $messageProperty.Value }
    }
    if (-not $hasSuccess) {
        return [pscustomobject]@{
            Success    = $false
            ReasonCode = 'ProviderResultAmbiguous'
            Message    = ("Operation '{0}' returned a structured result without an explicit Success decision." -f $Operation)
        }
    }
    if ($successValue -isnot [bool]) {
        return [pscustomobject]@{
            Success    = $false
            ReasonCode = 'ProviderResultAmbiguous'
            Message    = ("Operation '{0}' returned a non Boolean Success value." -f $Operation)
        }
    }
    if ($successValue) {
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
    }
    $reasonText = $null
    if ($null -ne $reason -and ([string]$reason).Trim().Length -gt 0) { $reasonText = [string]$reason }
    if (-not $reasonText) { $reasonText = 'ProviderRefused' }
    $messageText = $null
    if ($null -ne $message -and ([string]$message).Trim().Length -gt 0) { $messageText = [string]$message }
    if (-not $messageText) { $messageText = ("Operation '{0}' was refused by the writer provider." -f $Operation) }
    return [pscustomobject]@{ Success = $false; ReasonCode = $reasonText; Message = $messageText }
}

function Invoke-RecoveryLogProviderCall {
    param(
        [object]$Provider,
        [string]$Operation,
        [hashtable]$Arguments,
        [bool]$RequireExplicitSuccess = $true
    )
    if ($null -eq $Provider) {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderMissing'; Message = 'No writer provider was supplied.' }
    }
    if ($Provider -is [scriptblock]) {
        $scriptBlock = $Provider
    }
    else {
        $property = $null
        if ($Provider -is [System.Collections.IDictionary]) {
            if ($Provider.Contains($Operation)) { $property = $Provider[$Operation] }
        }
        else {
            $member = $Provider.PSObject.Properties[$Operation]
            if ($null -ne $member) { $property = $member.Value }
        }
        if ($null -eq $property) {
            return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationMissing'; Message = ("The writer provider does not implement operation '{0}'." -f $Operation) }
        }
        if ($property -isnot [scriptblock]) {
            return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderOperationInvalid'; Message = ("Operation '{0}' is not a script block." -f $Operation) }
        }
        $scriptBlock = $property
    }
    $request = @{ Operation = $Operation }
    if ($null -ne $Arguments) {
        foreach ($key in $Arguments.Keys) { $request[$key] = $Arguments[$key] }
    }
    try {
        $data = & $scriptBlock $request
    }
    catch {
        return [pscustomobject]@{ Success = $false; Data = $null; ReasonCode = 'ProviderFailure'; Message = $_.Exception.Message }
    }
    if (-not $RequireExplicitSuccess) {
        return [pscustomobject]@{ Success = $true; Data = $data; ReasonCode = $null; Message = $null }
    }
    $decision = ConvertTo-RecoveryLogProviderDecision -Operation $Operation -Data $data
    return [pscustomobject]@{ Success = $decision.Success; Data = $data; ReasonCode = $decision.ReasonCode; Message = $decision.Message }
}


function ConvertTo-RecoveryArray {
    param([object]$Value)
    if ($null -eq $Value) { return [object[]]@() }
    if ($Value -is [string]) { return [object[]]@($Value) }
    if ($Value -is [System.Collections.IEnumerable]) {
        $buffer = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $buffer.Add($item) | Out-Null }
        return $buffer.ToArray()
    }
    return [object[]]@($Value)
}

function Get-RecoveryLogMemberValue {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RecoveryLogProviderName {
    param([object]$Provider)
    if ($null -eq $Provider) { return $null }
    if ($Provider -is [scriptblock]) { return 'ScriptBlock' }
    $name = Get-RecoveryLogMemberValue -Object $Provider -Name 'Name'
    if ($null -eq $name) { return 'UnnamedProvider' }
    $text = ([string]$name).Trim()
    if ($text.Length -eq 0) { return 'UnnamedProvider' }
    return $text
}

function Get-RecoveryLogUtcInstant {
    param([object]$Clock)
    if ($null -eq $Clock) { return [datetime]::UtcNow }
    $value = $null
    if ($Clock -is [scriptblock]) {
        try { $value = & $Clock @{ Operation = 'NowUtc' } } catch { $value = $null }
    }
    else {
        # The clock is not a durability gate: a timestamp that cannot be proven is
        # replaced by the system UTC instant instead of blocking the log.
        $call = Invoke-RecoveryLogProviderCall -Provider $Clock -Operation 'NowUtc' -Arguments @{} -RequireExplicitSuccess $false
        if ($call.Success) { $value = $call.Data }
    }
    if ($null -eq $value) { return [datetime]::UtcNow }
    $instant = [datetime]$value
    if ($instant.Kind -eq [System.DateTimeKind]::Local) { return $instant.ToUniversalTime() }
    return $instant
}

function Format-RecoveryLogTimestamp {
    param([object]$Clock)
    $instant = Get-RecoveryLogUtcInstant -Clock $Clock
    return $instant.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-RecoveryAsciiJson {
    param([object]$Value)
    $text = [string]$Value
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $text.ToCharArray()) {
        $code = [int][char]$character
        if ($code -gt 126 -or ($code -lt 32 -and $code -ne 9 -and $code -ne 10 -and $code -ne 13)) {
            $builder.Append(('\u{0:x4}' -f $code)) | Out-Null
        }
        else {
            $builder.Append($character) | Out-Null
        }
    }
    return $builder.ToString()
}

function Read-RecoveryLogBytes {
    # Reads the case log while its writer may still hold it open.
    #
    # The writer keeps one append handle for the life of the case, so the log is
    # readable only when both handles agree. File.ReadAllBytes asks for
    # FileShare.Read, which refuses another handle that has write access, so on
    # Windows it fails with a sharing violation as long as the case is running;
    # the same call silently succeeds on Linux, where .NET does not enforce
    # sharing. This helper asks for FileShare.ReadWrite instead, so the case
    # record stays readable while the case is live, and it still refuses to
    # invent content: any failure returns $null and the caller fails closed.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path)

    $pathText = ([string]$Path).Trim()
    if ($pathText.Length -eq 0) { return $null }
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($pathText, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    }
    catch {
        # No writer is holding the file: fall back to the plain read, so a closed
        # or absent log behaves exactly as it did before.
        try { return [System.IO.File]::ReadAllBytes($pathText) } catch { return $null }
    }
    try {
        $length = [int]$stream.Length
        $buffer = New-Object byte[] $length
        $read = 0
        while ($read -lt $length) {
            $chunk = $stream.Read($buffer, $read, $length - $read)
            if ($chunk -le 0) { break }
            $read = $read + $chunk
        }
        if ($read -lt $length) { return $null }
        return $buffer
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-RecoveryLogTailHash {
    # Hash of the trailing window of the case record. The window is bounded so the
    # check stays cheap while the case runs, and it is compared before every append:
    # a changed length is caught by the offset, and a same-length rewrite is caught
    # here. The residual limitation (a rewrite confined to bytes outside the window
    # with an unchanged length) is recorded in the operator guide.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Length = 256
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    if ($Length -le 0) { $Length = 256 }
    $stream = $null
    try {
        $info = New-Object System.IO.FileInfo($Path)
        $count = [int]$info.Length
        if ($count -gt $Length) { $count = $Length }
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($count -gt 0) { [void]$stream.Seek(-1 * [int64]$count, [System.IO.SeekOrigin]::End) }
        $buffer = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $chunk = $stream.Read($buffer, $read, $count - $read)
            if ($chunk -le 0) { break }
            $read = $read + $chunk
        }
        if ($read -lt $count) { return '' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($buffer)
        }
        finally {
            $sha.Dispose()
        }
        $builder = New-Object System.Text.StringBuilder
        foreach ($byte in $hash) { [void]$builder.Append($byte.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture)) }
        return $builder.ToString()
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-RecoveryDefaultLogWriterProvider {
    $provider = @{}
    $provider.Name = 'AsciiJsonlFileWriter'
    $provider.Open = {
        param($request)
        $path = [string]$request.Path
        $directory = [System.IO.Path]::GetDirectoryName($path)
        if (-not $directory) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogOpenFailed'; Message = 'The log path has no parent directory.' }
        }
        if (-not [System.IO.Directory]::Exists($directory)) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogOpenFailed'; Message = 'The log directory does not exist.' }
        }
        $mode = 'CreateNew'
        if ([string]$request.Mode -eq 'Append') { $mode = 'Append' }
        # The log is not held open between events.
        #
        # A held append handle keeps every other reader out on Windows: .NET
        # readers ask for FileShare.Read, which refuses an open writer, so the
        # case record could not be read while the case ran (event log validation,
        # resume binding, and any technician editor all failed with a sharing
        # violation), and a temporary directory holding the file could not be
        # removed. Each event is instead appended and flushed on its own, so the
        # case record stays readable and removable at every moment while
        # append-only integrity is still enforced by the recorded offset below.
        $offset = 0
        try {
            if ($mode -eq 'CreateNew') {
                $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                $stream.Dispose()
            }
            elseif (-not [System.IO.File]::Exists($path)) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'LogOpenFailed'; Message = 'The log to append to does not exist.' }
            }
            else {
                $offset = [int](New-Object System.IO.FileInfo($path)).Length
            }
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogOpenFailed'; Message = $_.Exception.Message }
        }
        $tailLength = 256
        return [pscustomobject]@{
            Success = $true
            ReasonCode = $null
            Message = $null
            Stream = $null
            Path = $path
            Mode = $mode
            Offset = $offset
            # The trailing window is hashed after every append, so a rewrite that
            # keeps the byte length but changes the record is refused as well.
            TailLength = $tailLength
            TailHash = Get-RecoveryLogTailHash -Path $path -Length $tailLength
        }
    }
    $provider.Append = {
        param($request)
        $handle = $request.Handle
        $providerHandle = $null
        if ($null -ne $handle) { $providerHandle = $handle.ProviderHandle }
        if ($null -eq $providerHandle) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogAppendFailed'; Message = 'The log is not open.' }
        }
        $path = [string]$providerHandle.Path
        $expectedOffset = [int]$providerHandle.Offset
        $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$request.Text)
        $stream = $null
        try {
            $info = New-Object System.IO.FileInfo($path)
            if ($info.Length -ne $expectedOffset) {
                # The file changed since the last append (truncated, replaced, or
                # written by another process). An append-only record must refuse
                # instead of writing into a history it no longer owns.
                return [pscustomobject]@{ Success = $false; ReasonCode = 'LogAppendFailed'; Message = 'The log length changed since the previous append; the record is not append-only.' }
            }
            $tailHash = Get-RecoveryLogTailHash -Path $path -Length ([int]$providerHandle.TailLength)
            if ($tailHash -ne [string]$providerHandle.TailHash) {
                # The length is unchanged but the tail is not the tail that was
                # written. A same-length rewrite would otherwise be accepted and the
                # case would keep appending on top of edited history.
                return [pscustomobject]@{ Success = $false; ReasonCode = 'LogAppendFailed'; Message = 'The log tail does not match the last append; the record was changed out of band.' }
            }
            $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogAppendFailed'; Message = $_.Exception.Message }
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        $providerHandle.Offset = $expectedOffset + $bytes.Length
        $providerHandle.TailHash = Get-RecoveryLogTailHash -Path $path -Length ([int]$providerHandle.TailLength)
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
    }
    $provider.Flush = {
        param($request)
        $handle = $request.Handle
        $providerHandle = $null
        if ($null -ne $handle) { $providerHandle = $handle.ProviderHandle }
        if ($null -eq $providerHandle) {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogFlushFailed'; Message = 'The log is not open.' }
        }
        # Every append already flushed to disk, so there is no buffered state to
        # push. The operation stays a real check: an unreadable record is a
        # refusal rather than a claimed durable log.
        try {
            if (-not [System.IO.File]::Exists([string]$providerHandle.Path)) {
                return [pscustomobject]@{ Success = $false; ReasonCode = 'LogFlushFailed'; Message = 'The log file is missing.' }
            }
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogFlushFailed'; Message = $_.Exception.Message }
        }
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
    }
    $provider.Close = {
        param($request)
        $handle = $request.Handle
        if ($null -eq $handle) {
            return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
        }
        try {
            $stream = $null
            if ($null -ne $handle.ProviderHandle) { $stream = $handle.ProviderHandle.Stream }
            if ($null -ne $stream) { $stream.Dispose() }
            $handle.IsOpen = $false
        }
        catch {
            return [pscustomobject]@{ Success = $false; ReasonCode = 'LogCloseFailed'; Message = $_.Exception.Message }
        }
        return [pscustomobject]@{ Success = $true; ReasonCode = $null; Message = $null }
    }
    return $provider
}

function Test-RecoveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path,
        [string]$JobId = $null,
        [int]$ExpectedLastSequence = -1
    )
    $result = [pscustomobject]@{
        IsValid        = $false
        EventCount     = 0
        LastSequence   = 0
        JobId          = $null
        IsTruncated    = $false
        LastEvent      = $null
        Errors         = @()
        ReasonCode     = $null
    }
    if ($null -eq $Path) { $result.ReasonCode = 'LogNotFound'; return $result }
    $pathText = ([string]$Path).Trim()
    if ($pathText.Length -eq 0) { $result.ReasonCode = 'LogNotFound'; return $result }
    if (-not [System.IO.File]::Exists($pathText)) {
        $result.ReasonCode = 'LogNotFound'
        return $result
    }
    $bytes = Read-RecoveryLogBytes -Path $pathText
    if ($null -eq $bytes) {
        # The log exists but could not be read. That is a refusal, never a valid
        # empty log: a caller must not treat an unreadable case record as proof.
        $result.ReasonCode = 'LogUnreadable'
        return $result
    }
    if ($bytes.Length -eq 0) {
        $result.IsValid = $true
        $result.ReasonCode = $null
        return $result
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $text = $encoding.GetString($bytes)
    if (-not $text.EndsWith([string][char]10)) {
        $result.IsTruncated = $true
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($text -split [string][char]10)) {
        $lines.Add([string]$part) | Out-Null
    }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }
    $errors = New-Object System.Collections.Generic.List[string]
    if ($result.IsTruncated) {
        if ($lines.Count -gt 0) {
            $lines.RemoveAt($lines.Count - 1)
        }
        $errors.Add('The log does not end with a complete record.') | Out-Null
        $result.ReasonCode = 'LogTruncated'
    }
    $expected = 1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Trim().Length -eq 0) {
            $errors.Add(("Line {0} is blank." -f ($index + 1))) | Out-Null
            $result.ReasonCode = 'LogMalformed'
            break
        }
        $record = $null
        try {
            $record = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $errors.Add(("Line {0} is not valid JSON." -f ($index + 1))) | Out-Null
            $result.ReasonCode = 'LogMalformed'
            break
        }
        $recordJobId = [string](Get-RecoveryLogMemberValue -Object $record -Name 'JobId')
        if ($JobId -and $recordJobId -ne $JobId) {
            $errors.Add(("Line {0} belongs to job '{1}'." -f ($index + 1), $recordJobId)) | Out-Null
            $result.ReasonCode = 'LogJobIdMismatch'
            break
        }
        $sequence = Get-RecoveryLogMemberValue -Object $record -Name 'Sequence'
        # A sequence the record cannot state as a number is a malformed record, not
        # an exception: casting 'not-a-number' threw out of the validator and the
        # caller reported an unhandled workflow error instead of the named refusal.
        $sequenceNumber = -1
        $sequenceParsed = $false
        if ($null -ne $sequence -and -not ($sequence -is [bool])) {
            if ($sequence -is [string]) {
                $sequenceParsed = [int]::TryParse(([string]$sequence).Trim(), [ref]$sequenceNumber)
            }
            else {
                try {
                    $sequenceNumber = [int]$sequence
                    $sequenceParsed = $true
                }
                catch {
                    $sequenceParsed = $false
                }
            }
        }
        if (-not $sequenceParsed -or $sequenceNumber -ne $expected) {
            $errors.Add(("Line {0} has sequence '{1}' instead of '{2}'." -f ($index + 1), $sequence, $expected)) | Out-Null
            $result.ReasonCode = 'LogSequenceInvalid'
            break
        }
        $result.EventCount = $result.EventCount + 1
        $result.LastSequence = $expected
        $result.JobId = $recordJobId
        $result.LastEvent = $record
        $expected = $expected + 1
    }
    if ($null -eq $result.ReasonCode -and $ExpectedLastSequence -ge 0 -and $result.LastSequence -ne $ExpectedLastSequence) {
        $errors.Add(("The log ends at sequence '{0}' instead of '{1}'." -f $result.LastSequence, $ExpectedLastSequence)) | Out-Null
        $result.ReasonCode = 'LogSequenceInvalid'
    }
    $result.Errors = $errors.ToArray()
    if ($null -eq $result.ReasonCode) {
        $result.IsValid = $true
    }
    return $result
}

function New-RecoveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$JobId,
        [object]$Writer = $null,
        [object]$Clock = $null,
        [switch]$Resume
    )
    $result = [pscustomobject]@{
        Success    = $false
        Writer     = $null
        Path       = $null
        JobId      = $null
        Sequence   = 0
        Encoding   = 'ASCII'
        ReasonCode = $null
        Message    = $null
    }
    if ($null -eq $Path) { $result.ReasonCode = 'LogPathInvalid'; return $result }
    $pathText = ([string]$Path).Trim()
    $result.Path = $pathText
    if ($pathText.Length -eq 0) { $result.ReasonCode = 'LogPathInvalid'; return $result }
    if ($null -eq $JobId -or ([string]$JobId).Trim().Length -eq 0) { $result.ReasonCode = 'JobIdInvalid'; return $result }
    $jobText = ([string]$JobId).Trim()
    $result.JobId = $jobText
    $directory = [System.IO.Path]::GetDirectoryName($pathText)
    if (-not $directory -or -not [System.IO.Directory]::Exists($directory)) {
        $result.ReasonCode = 'LogOpenFailed'
        $result.Message = 'The log directory does not exist.'
        return $result
    }
    $mode = 'CreateNew'
    $sequence = 0
    if ($Resume) {
        $existing = Test-RecoveryLog -Path $pathText -JobId $jobText
        if (-not $existing.IsValid) {
            $result.ReasonCode = $existing.ReasonCode
            $result.Message = 'The existing log cannot be resumed.'
            return $result
        }
        $mode = 'Append'
        $sequence = $existing.LastSequence
    }
    elseif ([System.IO.File]::Exists($pathText)) {
        $result.ReasonCode = 'LogAlreadyExists'
        $result.Message = 'An existing unclaimed log is a collision and is never reused.'
        return $result
    }
    if ($null -eq $Writer) { $Writer = Get-RecoveryDefaultLogWriterProvider }
    $call = Invoke-RecoveryLogProviderCall -Provider $Writer -Operation 'Open' -Arguments @{ Path = $pathText; Mode = $mode; JobId = $jobText }
    if (-not $call.Success) {
        $result.ReasonCode = 'LogOpenFailed'
        $result.Message = $call.Message
        return $result
    }
    if ($null -eq $call.Data) {
        $result.ReasonCode = 'LogOpenFailed'
        $result.Message = 'The writer provider returned no log handle.'
        return $result
    }
    $providerHandle = $call.Data
    if ((Get-RecoveryLogMemberValue -Object $providerHandle -Name 'Success') -eq $false) {
        $result.ReasonCode = 'LogOpenFailed'
        $result.Message = [string](Get-RecoveryLogMemberValue -Object $providerHandle -Name 'Message')
        return $result
    }
    $handle = [pscustomobject]@{
        Path           = $pathText
        JobId          = $jobText
        Sequence       = $sequence
        IsOpen         = $true
        IsBlocked      = $false
        Provider       = $Writer
        ProviderName   = Get-RecoveryLogProviderName -Provider $Writer
        ProviderHandle = $providerHandle
        Encoding       = 'ASCII'
        Clock          = $Clock
    }
    $result.Success = $true
    $result.Writer = $handle
    $result.Sequence = $sequence
    return $result
}

function Write-RecoveryLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Writer,
        [Parameter(Mandatory = $true)][object]$Entry
    )
    $result = [pscustomobject]@{
        Success    = $false
        Sequence   = 0
        EventId    = $null
        Event      = $null
        ReasonCode = $null
        Message    = $null
    }
    if ($null -eq $Writer -or (Get-RecoveryLogMemberValue -Object $Writer -Name 'IsOpen') -ne $true) {
        $result.ReasonCode = 'LogNotOpen'
        return $result
    }
    if ((Get-RecoveryLogMemberValue -Object $Writer -Name 'IsBlocked') -eq $true) {
        $result.ReasonCode = 'LogWriteBlocked'
        $result.Message = 'A previous append or flush failure blocked this log.'
        return $result
    }
    if ($null -eq $Entry) {
        $result.ReasonCode = 'EntryInvalid'
        return $result
    }
    foreach ($required in @('JobId', 'EventType', 'State', 'Result')) {
        $value = Get-RecoveryLogMemberValue -Object $Entry -Name $required
        if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
            $result.ReasonCode = 'EntryInvalid'
            $result.Message = ("The event is missing the required field '{0}'." -f $required)
            return $result
        }
    }
    $jobId = ([string](Get-RecoveryLogMemberValue -Object $Entry -Name 'JobId')).Trim()
    if ($jobId -ne ([string](Get-RecoveryLogMemberValue -Object $Writer -Name 'JobId'))) {
        $result.ReasonCode = 'JobIdMismatch'
        $result.Message = 'The event belongs to a different job than this log.'
        return $result
    }
    $sequence = ([int](Get-RecoveryLogMemberValue -Object $Writer -Name 'Sequence')) + 1
    $eventId = $jobId + '-' + $sequence.ToString('000000', [System.Globalization.CultureInfo]::InvariantCulture)
    $clock = Get-RecoveryLogMemberValue -Object $Writer -Name 'Clock'
    $timestamp = Format-RecoveryLogTimestamp -Clock $clock
    $record = @{
        EventId             = $eventId
        Sequence            = $sequence
        TimestampUtc        = $timestamp
        JobId               = $jobId
        State               = Get-RecoveryLogMemberValue -Object $Entry -Name 'State'
        Stage               = Get-RecoveryLogMemberValue -Object $Entry -Name 'Stage'
        AttemptId           = Get-RecoveryLogMemberValue -Object $Entry -Name 'AttemptId'
        EventType           = Get-RecoveryLogMemberValue -Object $Entry -Name 'EventType'
        Result              = Get-RecoveryLogMemberValue -Object $Entry -Name 'Result'
        SourceIdentity      = Get-RecoveryLogMemberValue -Object $Entry -Name 'SourceIdentity'
        DestinationIdentity = Get-RecoveryLogMemberValue -Object $Entry -Name 'DestinationIdentity'
        Gate                = Get-RecoveryLogMemberValue -Object $Entry -Name 'Gate'
        Error               = Get-RecoveryLogMemberValue -Object $Entry -Name 'Error'
        Decision            = Get-RecoveryLogMemberValue -Object $Entry -Name 'Decision'
    }
    $json = $null
    try {
        $json = ConvertTo-RecoveryAsciiJson -Value ($record | ConvertTo-Json -Depth 12 -Compress)
    }
    catch {
        $result.ReasonCode = 'LogSerializeFailed'
        $result.Message = $_.Exception.Message
        return $result
    }
    $path = [string](Get-RecoveryLogMemberValue -Object $Writer -Name 'Path')
    $append = Invoke-RecoveryLogProviderCall -Provider (Get-RecoveryLogMemberValue -Object $Writer -Name 'Provider') -Operation 'Append' -Arguments @{ Handle = $Writer; Path = $path; Text = ($json + [string][char]10) }
    if (-not $append.Success) {
        $result.ReasonCode = 'LogAppendFailed'
        $result.Message = $append.Message
        $Writer.IsBlocked = $true
        return $result
    }
    $flush = Invoke-RecoveryLogProviderCall -Provider (Get-RecoveryLogMemberValue -Object $Writer -Name 'Provider') -Operation 'Flush' -Arguments @{ Handle = $Writer; Path = $path }
    if (-not $flush.Success) {
        $result.ReasonCode = 'LogFlushFailed'
        $result.Message = $flush.Message
        $Writer.IsBlocked = $true
        return $result
    }
    $Writer.Sequence = $sequence
    $result.Success = $true
    $result.Sequence = $sequence
    $result.EventId = $eventId
    $result.Event = $record
    return $result
}

function Sync-RecoveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Writer
    )
    $result = [pscustomobject]@{ Success = $false; Sequence = 0; ReasonCode = $null; Message = $null }
    if ($null -eq $Writer -or (Get-RecoveryLogMemberValue -Object $Writer -Name 'IsOpen') -ne $true) {
        $result.ReasonCode = 'LogNotOpen'
        return $result
    }
    if ((Get-RecoveryLogMemberValue -Object $Writer -Name 'IsBlocked') -eq $true) {
        $result.Sequence = [int](Get-RecoveryLogMemberValue -Object $Writer -Name 'Sequence')
        $result.ReasonCode = 'LogWriteBlocked'
        $result.Message = 'A previous append or flush failure blocked this log.'
        return $result
    }
    $path = [string](Get-RecoveryLogMemberValue -Object $Writer -Name 'Path')
    $flush = Invoke-RecoveryLogProviderCall -Provider (Get-RecoveryLogMemberValue -Object $Writer -Name 'Provider') -Operation 'Flush' -Arguments @{ Handle = $Writer; Path = $path }
    $result.Sequence = [int](Get-RecoveryLogMemberValue -Object $Writer -Name 'Sequence')
    if (-not $flush.Success) {
        # A flush refusal blocks the log: the caller must never treat the log as
        # durable after a refusal, so every later write is refused as well.
        $Writer.IsBlocked = $true
        $result.ReasonCode = 'LogFlushFailed'
        $result.Message = $flush.Message
        return $result
    }
    $result.Success = $true
    return $result
}

Set-Alias -Name Flush-RecoveryLog -Value Sync-RecoveryLog -Scope Local

function Close-RecoveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Writer
    )

    # Releases the logical writer. Each event is appended and flushed on its own,
    # so no file handle is held between events and this close ends the writer's
    # state rather than unlocking a file. Closing an already closed log is not an
    # error (cleanup paths may run more than once), and a refused close is always
    # reported.
    $result = [pscustomobject]@{
        Success    = $false
        Path       = $null
        ReasonCode = $null
        Message    = $null
    }
    if ($null -eq $Writer) {
        $result.ReasonCode = 'LogCloseFailed'
        $result.Message = 'No log writer was supplied to close.'
        return $result
    }
    $path = [string](Get-RecoveryLogMemberValue -Object $Writer -Name 'Path')
    $result.Path = $path
    if ((Get-RecoveryLogMemberValue -Object $Writer -Name 'IsOpen') -ne $true) {
        $result.Success = $true
        return $result
    }
    $close = Invoke-RecoveryLogProviderCall -Provider (Get-RecoveryLogMemberValue -Object $Writer -Name 'Provider') -Operation 'Close' -Arguments @{ Handle = $Writer; Path = $path }
    if (-not $close.Success) {
        $result.ReasonCode = 'LogCloseFailed'
        $result.Message = $close.Message
        return $result
    }
    $Writer.IsOpen = $false
    $result.Success = $true
    return $result
}

Export-ModuleMember -Function @(
    'Sync-RecoveryLog',
    'Close-RecoveryLog',
    'New-RecoveryLog',
    'Test-RecoveryLog',
    'Write-RecoveryLogEntry'
) -Alias @(
    'Flush-RecoveryLog'
)
