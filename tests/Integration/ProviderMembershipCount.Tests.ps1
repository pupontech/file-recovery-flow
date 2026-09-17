BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
    $script:EntryPoint = Join-Path -Path $script:RepoRoot -ChildPath 'RecoveryAutomation.ps1'
    . $script:EntryPoint
    Import-Module (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'modules') -ChildPath 'DiskDetection.psm1') -Force -Global

    function New-MembershipProvider {
        # Injected seams for the production read-only Windows provider. The volume
        # view may state a member count; the disk view is kept internally
        # consistent (its declared partition count matches the partitions its own
        # view returns) so that member identity resolution stays complete and the
        # only variable under test is the stated member count.
        param(
            [object]$DeclaredCount = $null,
            [int]$DeclaredCountStated = 1,
            [int]$DiskPartitionCount = 1,
            [object[]]$DiskPartitions = $null
        )
        $volume = [pscustomobject]@{
            UniqueId = 'membership-volume'
            DriveLetter = 'Z'
            Path = 'Z:\'
            FileSystemLabel = 'Membership'
            FileSystem = 'NTFS'
            Size = 1000000
            SizeRemaining = 500000
        }
        if ($DeclaredCountStated -eq 1) {
            $volume | Add-Member -NotePropertyName DeclaredMemberCount -NotePropertyValue $DeclaredCount -Force
        }
        $volumePartitions = @([pscustomobject]@{
                DiskNumber = 4; PartitionNumber = 1; GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; Size = 1000000
            })
        if ($null -eq $DiskPartitions) { $DiskPartitions = $volumePartitions }
        $volumeQuery = { param($request) return $volume }.GetNewClosure()
        $partitionQuery = {
            param($request)
            $operation = [string]$request.Operation
            if ($operation -eq 'PartitionsForVolume') { return $volumePartitions }
            if ($operation -eq 'PartitionsForDriveLetter') { return $volumePartitions }
            if ($operation -eq 'PartitionsForDisk') { return $diskPartitions }
            throw ('Unsupported partition query operation: ' + $operation)
        }.GetNewClosure()
        $diskQuery = {
            param($request)
            return @([pscustomobject]@{
                    Number = 4
                    UniqueId = 'MEMBERSHIP-DISK'
                    UniqueIdFormat = 'WWN'
                    SerialNumber = 'SERIAL-MEMBERSHIP-DISK'
                    Model = 'MembershipDisk'
                    Size = 1000000
                    NumberOfPartitions = $DiskPartitionCount
                    BusType = 17
                    PartitionStyle = 2
                })
        }.GetNewClosure()
        $itemQuery = {
            param($request)
            return [pscustomobject]@{ FullName = [string]$request.Path; PSIsContainer = $true; Attributes = 'Directory' }
        }.GetNewClosure()
        return New-RecoveryAutomationWindowsDiskProvider -VolumeQuery $volumeQuery -PartitionQuery $partitionQuery `
            -DiskQuery $diskQuery -ItemQuery $itemQuery
    }
}

Describe 'Provider declared member count' {
    It 'reports an incomplete topology when one member answers a larger stated member count' {
        $provider = New-MembershipProvider -DeclaredCount 3
        $path = Join-Path -Path $TestDrive -ChildPath 'stated-count'

        $record = & $provider.ResolvePath @{ Path = $path }
        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider
        $volumes = @(& $provider.GetVolumes @{})

        # The provider resolved one member and stated the count it was given. It is
        # the completeness guard, not the provider, that refuses the subset.
        @($record.PhysicalDiskNumbers) | Should -HaveCount 1
        [int]$record.DeclaredMemberCount | Should -Be 3
        $record.MembersIncomplete | Should -BeFalse
        $volumes.Count | Should -Be 1
        [int]$volumes[0].DeclaredMemberCount | Should -Be 3
        # A one-member answer against a larger stated count is never an allow.
        $identity.Resolved | Should -Be $true
        $identity.IsIndeterminate | Should -Be $true
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }

    It 'keeps membership complete when the stated member count agrees' {
        $provider = New-MembershipProvider -DeclaredCount 1
        $path = Join-Path -Path $TestDrive -ChildPath 'agreeing-count'

        $record = & $provider.ResolvePath @{ Path = $path }
        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        @($record.PhysicalDiskNumbers) | Should -HaveCount 1
        [int]$record.DeclaredMemberCount | Should -Be 1
        $identity.Resolved | Should -Be $true
        $identity.IsIndeterminate | Should -BeFalse
        $identity.ReasonCode | Should -BeNullOrEmpty
    }

    It 'does not publish a member count from a disk partition count' {
        # The ordinary host shape: one volume of a disk that carries three
        # partitions, which the disk view itself accounts for. A disk's
        # NumberOfPartitions counts the partitions of every volume on that disk, so
        # publishing it as this volume's member count would refuse every ordinary
        # volume. The provider must leave the field unstated.
        $diskPartitions = @(
            [pscustomobject]@{ DiskNumber = 4; PartitionNumber = 1; GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'; Size = 1000000 }
            [pscustomobject]@{ DiskNumber = 4; PartitionNumber = 2; GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; Size = 1000000 }
            [pscustomobject]@{ DiskNumber = 4; PartitionNumber = 3; GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; Size = 1000000 }
        )
        $provider = New-MembershipProvider -DeclaredCountStated 0 -DiskPartitionCount 3 -DiskPartitions $diskPartitions
        $path = Join-Path -Path $TestDrive -ChildPath 'ordinary-disk'

        $record = & $provider.ResolvePath @{ Path = $path }
        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider
        $volumes = @(& $provider.GetVolumes @{})

        $record.PSObject.Properties['DeclaredMemberCount'] | Should -BeNullOrEmpty
        $volumes[0].PSObject.Properties['DeclaredMemberCount'] | Should -BeNullOrEmpty
        $record.MembersIncomplete | Should -BeFalse
        # The member disk identity itself stays resolvable, so an ordinary volume of
        # a multi-partition disk is not reported as a partial member list.
        $identity.Resolved | Should -Be $true
        $identity.IsIndeterminate | Should -BeFalse
        $identity.ReasonCode | Should -BeNullOrEmpty
    }

    It 'refuses a stated member count it cannot read' {
        $provider = New-MembershipProvider -DeclaredCount 'several'
        $path = Join-Path -Path $TestDrive -ChildPath 'unreadable-count'

        $record = & $provider.ResolvePath @{ Path = $path }
        $identity = Resolve-RecoveryPathIdentity -Path $path -Provider $provider

        $record.MembersIncomplete | Should -BeTrue
        $record.MembershipEvidence | Should -Be 'DeclaredMemberCountUnparsed'
        $record.PSObject.Properties['DeclaredMemberCount'] | Should -BeNullOrEmpty
        $identity.Resolved | Should -Be $true
        $identity.IsIndeterminate | Should -Be $true
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }
}
