BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest
}

AfterAll {
    Remove-AirlockTestStubs
}

Describe 'Get-AirlockStepSkipReason' {
    It 'allows the step when nothing is missing and nothing is skipped' {
        $reason = InModuleScope Airlock {
            Get-AirlockStepSkipReason -Options ([pscustomobject]@{ SkipStep = @(); OptionalPermissionsMissing = @() }) `
                -Step 'DirectoryRoles' -Permission 'RoleManagement.ReadWrite.Directory' -Feature 'directory role removal'
        }

        $reason | Should -BeNullOrEmpty
    }

    It 'skips the step on request, and says so' {
        $reason = InModuleScope Airlock {
            Get-AirlockStepSkipReason -Options ([pscustomobject]@{ SkipStep = @('GroupOwnership'); OptionalPermissionsMissing = @() }) `
                -Step 'GroupOwnership' -Permission 'Group.ReadWrite.All' -Feature 'group ownership changes'
        }

        $reason | Should -Match '-SkipStep GroupOwnership'
    }

    It 'skips the step when its permission is not granted, and names the permission and the feature' {
        $reason = InModuleScope Airlock {
            Get-AirlockStepSkipReason -Options ([pscustomobject]@{ SkipStep = @(); OptionalPermissionsMissing = @('Files.ReadWrite.All') }) `
                -Step 'OneDriveHandover' -Permission 'Files.ReadWrite.All' -Feature 'the OneDrive handover'
        }

        $reason | Should -Match 'Files.ReadWrite.All is not granted'
        $reason | Should -Match 'the OneDrive handover was skipped'
    }

    It 'is not affected by a different missing permission or a different skipped step' {
        $reason = InModuleScope Airlock {
            Get-AirlockStepSkipReason -Options ([pscustomobject]@{ SkipStep = @('OneDriveHandover'); OptionalPermissionsMissing = @('Group.ReadWrite.All') }) `
                -Step 'DirectoryRoles' -Permission 'RoleManagement.ReadWrite.Directory' -Feature 'directory role removal'
        }

        $reason | Should -BeNullOrEmpty
    }

    It 'lets the step run when the permissions could not be read, because nothing is reported missing' {
        $reason = InModuleScope Airlock {
            Get-AirlockStepSkipReason -Options ([pscustomobject]@{ SkipStep = @(); OptionalPermissionsMissing = @() }) `
                -Step 'OneDriveHandover' -Permission 'Files.ReadWrite.All' -Feature 'the OneDrive handover'
        }

        $reason | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-AirlockCommand' {
    It 'returns the first name that exists' {
        $name = InModuleScope Airlock {
            Resolve-AirlockCommand -Name 'Remove-MgGroupOwnerDirectoryObjectByRef', 'Remove-MgGroupOwnerByRef'
        }

        $name | Should -Be 'Remove-MgGroupOwnerDirectoryObjectByRef'
    }

    It 'falls back to a later name when the first does not exist' {
        $name = InModuleScope Airlock {
            Resolve-AirlockCommand -Name 'Remove-MgThisCommandDoesNotExist', 'Remove-MgGroupOwnerByRef'
        }

        $name | Should -Be 'Remove-MgGroupOwnerByRef'
    }

    It 'throws a message that lists every name tried when none exists' {
        {
            InModuleScope Airlock {
                Resolve-AirlockCommand -Name 'Remove-MgNoSuchOne', 'Remove-MgNoSuchTwo'
            }
        } | Should -Throw '*Remove-MgNoSuchOne, Remove-MgNoSuchTwo*2.0.0*'
    }
}

Describe 'Get-AirlockGroupSkipReason -Ownership' {
    It 'still gives a dynamic group a reason for membership' {
        InModuleScope Airlock {
            Get-AirlockGroupSkipReason -Group ([pscustomobject]@{ GroupTypes = @('DynamicMembership'); MailEnabled = $false; SecurityEnabled = $true; OnPremisesSyncEnabled = $null })
        } | Should -Match 'dynamic'
    }

    It 'does not skip a dynamic group for ownership, because its owners can be changed' {
        InModuleScope Airlock {
            Get-AirlockGroupSkipReason -Ownership -Group ([pscustomobject]@{ GroupTypes = @('DynamicMembership'); MailEnabled = $false; SecurityEnabled = $true; OnPremisesSyncEnabled = $null })
        } | Should -BeNullOrEmpty
    }

    It 'skips an on-premises synced group for ownership and says to change the owner there' {
        InModuleScope Airlock {
            Get-AirlockGroupSkipReason -Ownership -Group ([pscustomobject]@{ GroupTypes = @(); MailEnabled = $false; SecurityEnabled = $true; OnPremisesSyncEnabled = $true })
        } | Should -Match 'change the owner there'
    }

    It 'skips a distribution list and a mail-enabled security group for ownership, naming Exchange' {
        foreach ($security in $true, $false) {
            InModuleScope Airlock -Parameters @{ Security = $security } -ScriptBlock {
                param($Security)
                Get-AirlockGroupSkipReason -Ownership -Group ([pscustomobject]@{ GroupTypes = @(); MailEnabled = $true; SecurityEnabled = $Security; OnPremisesSyncEnabled = $null })
            } | Should -Match 'ownership is managed in Exchange'
        }
    }

    It 'allows a Microsoft 365 group for ownership' {
        InModuleScope Airlock {
            Get-AirlockGroupSkipReason -Ownership -Group ([pscustomobject]@{ GroupTypes = @('Unified'); MailEnabled = $true; SecurityEnabled = $false; OnPremisesSyncEnabled = $null })
        } | Should -BeNullOrEmpty
    }
}
