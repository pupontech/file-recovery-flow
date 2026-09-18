BeforeAll {
    Import-Module (Join-Path (Join-Path $PSScriptRoot '..') '../modules/DiskDetection.psm1') -Force
}

Describe 'Destination separation requires a stated source member' {
    BeforeAll {
        function New-SeparationProvider {
            param($DiskNumber = 5)
            $provider = @{}
            $provider.Name = 'SeparationFixture'
            $provider.GetDisks = {
                param($request)
                return @([pscustomobject]@{
                    DiskNumber = $DiskNumber
                    UniqueId = ('DISK-' + [string]$DiskNumber)
                    UniqueIdFormat = 'WWN'
                    SerialNumber = ('SERIAL-' + [string]$DiskNumber)
                    Model = ('Model' + [string]$DiskNumber)
                    SizeBytes = 1000000
                })
            }.GetNewClosure()
            $provider.ResolvePath = {
                param($request)
                return [pscustomobject]@{
                    CanonicalPath = [string]$request.Path
                    Exists = $true
                    IsContainer = $true
                    ReparseResolved = $true
                    IsReparsePoint = $false
                    MembersIncomplete = $false
                    DiskNumber = $DiskNumber
                    PartitionNumber = 1
                    VolumeGuid = ('VOLUME-' + [string]$DiskNumber)
                    VolumePath = ('VOLUME-PATH-' + [string]$DiskNumber)
                    DriveLetter = $null
                }
            }.GetNewClosure()
            $provider.GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
            return $provider
        }

        # A source identity that was resolved and whose disk was never stated: the
        # source sits on the same physical disk as the destination fixture below,
        # but no member is published, so a separation comparison can never approve.
        function New-SourceWithoutMembers {
            [pscustomobject]@{
                Path = 'C:\source'
                CanonicalPath = 'C:\source'
                Resolved = $true
                Exists = $true
                IsContainer = $true
                VolumeGuid = $null
                VolumePath = 'VOLUME-PATH-SOURCE'
                DriveLetter = 'C'
                PartitionNumber = 1
                DiskNumber = 5
                PhysicalDisks = @()
                IdentityKeys = @()
                IsIndeterminate = $false
                ReasonCode = $null
            }
        }

        function New-SourceWithMembers {
            $source = New-SourceWithoutMembers
            # Mirrors the production shape: the same member key is published both
            # as the identity key list and on the member record itself.
            $source.IdentityKeys = @('UID|WWN|DISK-5')
            $source.PhysicalDisks = @([pscustomobject]@{
                UniqueId = 'DISK-5'
                UniqueIdFormat = 'WWN'
                SerialNumber = 'SERIAL-5'
                Model = 'Model5'
                SizeBytes = 1000000
                IdentityKey = 'UID|WWN|DISK-5'
            })
            return $source
        }
    }

    It 'refuses a destination when the source states no physical member' {
        $provider = New-SeparationProvider -DiskNumber 5

        $decision = Test-DestinationSafety -SourceIdentity (New-SourceWithoutMembers) `
            -DestinationPath 'D:\Recovery' -Provider $provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'SourceIndeterminate'
    }

    It 'still refuses the same disk when the source member is stated' {
        $provider = New-SeparationProvider -DiskNumber 5

        $decision = Test-DestinationSafety -SourceIdentity (New-SourceWithMembers) `
            -DestinationPath 'D:\Recovery' -Provider $provider

        $decision.Allowed | Should -BeFalse
        $decision.ReasonCode | Should -Be 'SamePhysicalDisk'
    }
}

Describe 'A partial member list is never read as complete membership' {
    BeforeAll {
        # A volume view that resolved one member while the topology stated that
        # more members exist. Keeping only the members that happened to resolve
        # would authorize a comparison of a partial disk set.
        function New-PartialMemberRecord {
            [pscustomobject]@{
                CanonicalPath = 'D:\Recovery'
                Exists = $true
                IsContainer = $true
                ReparseResolved = $true
                IsReparsePoint = $false
                MembersIncomplete = $false
                PhysicalDiskNumbers = @(5)
                DeclaredMemberCount = 7
                DiskNumber = 5
                PartitionNumber = 1
                VolumeGuid = 'VOLUME-PARTIAL'
                VolumePath = 'VOLUME-PATH-PARTIAL'
                DriveLetter = 'D'
            }
        }

        function New-CompleteMemberRecord {
            $record = New-PartialMemberRecord
            $record.DeclaredMemberCount = 1
            return $record
        }

        function New-PartialMemberProvider {
            param([object]$Record)
            $provider = @{}
            $provider.Name = 'PartialMemberFixture'
            $provider.ResolvePath = { param($request) return $Record }.GetNewClosure()
            $provider.GetDisks = {
                param($request)
                return @([pscustomobject]@{
                    DiskNumber = 5
                    UniqueId = 'DISK-5'
                    UniqueIdFormat = 'WWN'
                    SerialNumber = 'SERIAL-5'
                    Model = 'Model5'
                    SizeBytes = 1000000
                })
            }.GetNewClosure()
            $provider.GetFreeSpace = {
                param($request)
                return [pscustomobject]@{ VolumeAvailableBytes = 1000000000; UserAvailableBytes = 1000000000 }
            }.GetNewClosure()
            return $provider
        }
    }

    It 'reports an incomplete topology when the stated member count is larger' {
        $identity = Resolve-RecoveryPathIdentity -Path 'D:\Recovery' -Provider (New-PartialMemberProvider -Record (New-PartialMemberRecord))

        $identity.Resolved | Should -Be $true
        $identity.IsIndeterminate | Should -Be $true
        $identity.ReasonCode | Should -Be 'MembersIncomplete'
    }

    It 'keeps a member list complete when the stated count agrees' {
        $identity = Resolve-RecoveryPathIdentity -Path 'D:\Recovery' -Provider (New-PartialMemberProvider -Record (New-CompleteMemberRecord))

        $identity.Resolved | Should -Be $true
        $identity.IsIndeterminate | Should -BeFalse
        $identity.ReasonCode | Should -BeNullOrEmpty
    }
}
