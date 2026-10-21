BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:Upn = 'ada.example@contoso.example'
    $script:ManagerUpn = 'grace.manager@contoso.example'

    function New-StepRun {
        param([bool]$Answer = $true, [bool]$IsWhatIf = $false)
        $cmdlet = [pscustomobject]@{ Answer = $Answer }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $this.Answer }
        InModuleScope Airlock -Parameters @{ Cmdlet = $cmdlet; IsWhatIf = $IsWhatIf } -ScriptBlock {
            param($Cmdlet, $IsWhatIf)
            New-AirlockRun -Command 'Remove-AirlockUser' -Cmdlet $Cmdlet -IsWhatIf $IsWhatIf -LogDirectory 'unused'
        }
    }

    function New-Manager {
        param([bool]$Found = $true, [string]$ErrorText = $null)
        [pscustomobject]@{
            Found             = $Found
            Id                = $(if ($Found) { 'mgr-id' } else { $null })
            UserPrincipalName = $(if ($Found) { $script:ManagerUpn } else { $null })
            Error             = $ErrorText
        }
    }

    function Invoke-DriveStep {
        param($Run, $Manager = (New-Manager), [string[]]$SkipStep = @(), [string[]]$OptionalMissing = @())
        InModuleScope Airlock -Parameters @{ Run = $Run; Manager = $Manager; SkipStep = $SkipStep; OptionalMissing = $OptionalMissing } -ScriptBlock {
            param($Run, $Manager, $SkipStep, $OptionalMissing)
            $options = [pscustomobject]@{ SkipStep = $SkipStep; OptionalPermissionsMissing = $OptionalMissing; OwnershipAction = 'TransferToManager' }
            Invoke-AirlockOneDriveHandover -Run $Run -Target 'ada.example@contoso.example' -UserId 'u-ada' -Manager $Manager -Options $options
        }
    }

    # An existing permission on the drive root, shaped the way Graph returns it.
    function New-DrivePermission {
        param([string]$UserId, [string[]]$Roles = @('write'), [ValidateSet('V2', 'Deprecated', 'Identities')][string]$Shape = 'V2')
        switch ($Shape) {
            'V2' { [pscustomobject]@{ Id = "p-$UserId"; Roles = $Roles; GrantedToV2 = [pscustomobject]@{ User = [pscustomobject]@{ Id = $UserId } } } }
            'Deprecated' { [pscustomobject]@{ Id = "p-$UserId"; Roles = $Roles; GrantedTo = [pscustomobject]@{ User = [pscustomobject]@{ Id = $UserId } } } }
            'Identities' { [pscustomobject]@{ Id = "p-$UserId"; Roles = $Roles; GrantedToIdentitiesV2 = @([pscustomobject]@{ User = [pscustomobject]@{ Id = 'someone' } }, [pscustomobject]@{ User = [pscustomobject]@{ Id = $UserId } }) } }
        }
    }

    function Initialize-DriveFake {
        $global:DriveFake = @{
            Drive        = [pscustomobject]@{ Id = 'drive-1' }
            DriveError   = $null
            Permissions  = [System.Collections.Generic.List[object]]::new()
            FailList     = $false
            FailInvite   = $false
            PartialError = $false
            Bodies       = [System.Collections.Generic.List[object]]::new()
        }

        Mock -ModuleName Airlock Get-MgUserDefaultDrive -MockWith {
            if ($global:DriveFake.DriveError) { throw $global:DriveFake.DriveError }
            $global:DriveFake.Drive
        }

        Mock -ModuleName Airlock Get-MgDriveItemPermission -MockWith {
            if ($global:DriveFake.FailList) { throw 'Authorization_RequestDenied: simulated permission-list failure' }
            foreach ($permission in $global:DriveFake.Permissions) { $permission }
        }

        Mock -ModuleName Airlock Invoke-MgInviteDriveItem -MockWith {
            if ($global:DriveFake.FailInvite) { throw 'Authorization_RequestDenied: simulated invite failure' }
            $global:DriveFake.Bodies.Add($BodyParameter)
            $recipient = $BodyParameter.recipients[0].objectId
            $granted = [pscustomobject]@{ Id = "p-$recipient"; Roles = @($BodyParameter.roles); GrantedToV2 = [pscustomobject]@{ User = [pscustomobject]@{ Id = $recipient } } }
            if ($global:DriveFake.PartialError) {
                $granted | Add-Member -NotePropertyName Error -NotePropertyValue ([pscustomobject]@{ Code = 'notAllowed'; Message = 'simulated partial failure' })
                return [pscustomobject]@{ Value = @($granted) }
            }
            $global:DriveFake.Permissions.Add($granted)
            [pscustomobject]@{ Value = @($granted) }
        }
    }
}

AfterAll {
    Remove-Variable -Name DriveFake -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'Get-AirlockPropertyValue' {
    It 'reads a nested property' {
        InModuleScope Airlock {
            Get-AirlockPropertyValue -InputObject ([pscustomobject]@{ A = [pscustomobject]@{ B = [pscustomobject]@{ C = 'deep' } } }) -Path 'A', 'B', 'C'
        } | Should -Be 'deep'
    }

    It 'returns nothing, without throwing under strict mode, when a part of the path is missing' {
        InModuleScope Airlock {
            Set-StrictMode -Version Latest
            Get-AirlockPropertyValue -InputObject ([pscustomobject]@{ A = [pscustomobject]@{ B = 1 } }) -Path 'A', 'Missing', 'C'
        } | Should -BeNullOrEmpty
    }

    It 'returns nothing for a null input or a null link in the chain' {
        InModuleScope Airlock { Get-AirlockPropertyValue -InputObject $null -Path 'A' } | Should -BeNullOrEmpty
        InModuleScope Airlock { Get-AirlockPropertyValue -InputObject ([pscustomobject]@{ A = $null }) -Path 'A', 'B' } | Should -BeNullOrEmpty
    }
}

Describe 'Test-AirlockDriveAccess' {
    It 'is <Expected> for <Case>' -ForEach @(
        @{ Case = 'write access in the current shape'; Shape = 'V2'; Roles = @('write'); Expected = $true }
        @{ Case = 'owner access'; Shape = 'V2'; Roles = @('owner'); Expected = $true }
        @{ Case = 'write access in the deprecated shape'; Shape = 'Deprecated'; Roles = @('write'); Expected = $true }
        @{ Case = 'write access inside a list of identities'; Shape = 'Identities'; Roles = @('write'); Expected = $true }
        @{ Case = 'read-only access'; Shape = 'V2'; Roles = @('read'); Expected = $false }
        @{ Case = 'no roles at all'; Shape = 'V2'; Roles = @(); Expected = $false }
    ) {
        $permission = New-DrivePermission -UserId 'mgr-id' -Roles $Roles -Shape $Shape

        InModuleScope Airlock -Parameters @{ Permission = $permission } -ScriptBlock {
            param($Permission)
            Test-AirlockDriveAccess -Permission $Permission -UserId 'mgr-id'
        } | Should -Be $Expected
    }

    It 'is false when the access belongs to somebody else' {
        $permission = New-DrivePermission -UserId 'someone-else'

        InModuleScope Airlock -Parameters @{ Permission = $permission } -ScriptBlock {
            param($Permission)
            Test-AirlockDriveAccess -Permission $Permission -UserId 'mgr-id'
        } | Should -BeFalse
    }

    It 'is false for a sharing link permission that names nobody' {
        $permission = [pscustomobject]@{ Id = 'link'; Roles = @('write'); Link = [pscustomobject]@{ Type = 'edit' } }

        InModuleScope Airlock -Parameters @{ Permission = $permission } -ScriptBlock {
            param($Permission)
            Test-AirlockDriveAccess -Permission $Permission -UserId 'mgr-id'
        } | Should -BeFalse
    }
}

Describe 'Invoke-AirlockOneDriveHandover' {
    BeforeEach {
        Initialize-DriveFake
    }

    Context 'handing over' {
        It 'gives the manager write access to the root of the leaver''s drive, directly and with no email' {
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $UserId -eq 'u-ada' }
            Should -Invoke -CommandName Get-MgDriveItemPermission -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $DriveId -eq 'drive-1' -and $DriveItemId -eq 'root' }
            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $DriveId -eq 'drive-1' -and $DriveItemId -eq 'root' -and
                $BodyParameter.recipients[0].objectId -eq 'mgr-id' -and
                @($BodyParameter.roles) -contains 'write' -and @($BodyParameter.roles).Count -eq 1 -and
                $BodyParameter.sendInvitation -eq $false -and $BodyParameter.requireSignIn -eq $true
            }
            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Action | Should -Be 'HandOverOneDrive'
            $run.Entries[0].Status | Should -Be 'Applied'
            $run.Entries[0].Detail | Should -Match ([regex]::Escape($script:ManagerUpn))
            $run.Entries[0].Target | Should -Be $script:Upn
        }

        It 'still hands over when the only existing access is read-only, or belongs to someone else' {
            $global:DriveFake.Permissions.Add((New-DrivePermission -UserId 'mgr-id' -Roles 'read'))
            $global:DriveFake.Permissions.Add((New-DrivePermission -UserId 'someone-else' -Roles 'write'))
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 1 -Exactly
            $run.Entries[0].Status | Should -Be 'Applied'
        }

        It 'uses the manager id when the manager has no user principal name on record' {
            $manager = [pscustomobject]@{ Found = $true; Id = 'mgr-id'; UserPrincipalName = $null; Error = $null }
            $run = New-StepRun

            Invoke-DriveStep -Run $run -Manager $manager

            $run.Entries[0].Detail | Should -Match 'mgr-id'
        }
    }

    Context 'idempotency' {
        It 'does nothing when the manager already has <Case>' -ForEach @(
            @{ Case = 'write access'; Shape = 'V2'; Roles = @('write') }
            @{ Case = 'owner access'; Shape = 'V2'; Roles = @('owner') }
            @{ Case = 'write access in the deprecated shape'; Shape = 'Deprecated'; Roles = @('write') }
            @{ Case = 'write access through a list of identities'; Shape = 'Identities'; Roles = @('write') }
        ) {
            $global:DriveFake.Permissions.Add((New-DrivePermission -UserId 'mgr-id' -Roles $Roles -Shape $Shape))
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'already has write access'
        }

        It 'shares once, and the second run finds the access and does nothing' {
            $first = New-StepRun
            $second = New-StepRun

            Invoke-DriveStep -Run $first
            Invoke-DriveStep -Run $second

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 1 -Exactly
            $first.Entries[0].Status | Should -Be 'Applied'
            $second.Entries[0].Status | Should -Be 'Skipped'
        }
    }

    Context 'WhatIf and declined prompts' {
        It 'reads the drive and the access but shares nothing under -WhatIf, and logs the plan' {
            $run = New-StepRun -Answer $false -IsWhatIf $true

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Get-MgDriveItemPermission -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'WhatIf'
            $run.Entries[0].Detail | Should -Match ([regex]::Escape($script:ManagerUpn))
            $global:DriveFake.Permissions.Count | Should -Be 0
        }

        It 'records Declined, not Skipped, when the prompt is declined' {
            $run = New-StepRun -Answer $false -IsWhatIf $false

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Declined'
        }
    }

    Context 'nothing to hand over, or nobody to hand it to' {
        It 'skips, with the reason, when there is no manager, and makes no Graph call' {
            $run = New-StepRun

            Invoke-DriveStep -Run $run -Manager (New-Manager -Found $false)

            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'No manager is set'
        }

        It 'skips, with the reason, when the manager could not be read' {
            $run = New-StepRun

            Invoke-DriveStep -Run $run -Manager (New-Manager -Found $false -ErrorText 'Internal server error')

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'manager could not be read'
            $run.Entries[0].Detail | Should -Match 'Internal server error'
        }

        It 'skips when Graph says the user has no OneDrive' {
            $global:DriveFake.DriveError = 'itemNotFound: The resource could not be found'
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Get-MgDriveItemPermission -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'no OneDrive'
        }

        It 'skips when Graph returns no drive at all' {
            $global:DriveFake.Drive = $null
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'no OneDrive'
        }
    }

    Context 'skipping the step' {
        It 'does nothing and calls nothing when the operator passes -SkipStep OneDriveHandover' {
            $run = New-StepRun

            Invoke-DriveStep -Run $run -SkipStep 'OneDriveHandover'

            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match '-SkipStep OneDriveHandover'
        }

        It 'does nothing and calls nothing when Files.ReadWrite.All is not granted' {
            $run = New-StepRun

            Invoke-DriveStep -Run $run -OptionalMissing 'Files.ReadWrite.All'

            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'Files.ReadWrite.All is not granted'
        }

        It 'is not stopped by a different permission being missing' {
            $run = New-StepRun

            Invoke-DriveStep -Run $run -OptionalMissing 'Group.ReadWrite.All', 'RoleManagement.ReadWrite.Directory'

            $run.Entries[0].Status | Should -Be 'Applied'
        }
    }

    Context 'Graph failures' {
        It 'records a failed drive lookup as a failure of this step and shares nothing' {
            $global:DriveFake.DriveError = 'Authorization_RequestDenied: simulated lookup failure'
            $run = New-StepRun

            { Invoke-DriveStep -Run $run } | Should -Not -Throw

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'could not be looked up'
            $run.Entries[0].Detail | Should -Match 'simulated lookup failure'
        }

        It 'does not read a refusal as "no OneDrive" just because its request id contains 404' {
            $global:DriveFake.DriveError = 'Authorization_RequestDenied: Insufficient privileges. Request-Id: 9a1f2c3d-4040-4b7e-8a11-0123456789ab'
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'could not be looked up'
        }

        It 'still reads a plain 404 status as "no OneDrive"' {
            $global:DriveFake.DriveError = 'Response status code does not indicate success: 404.'
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'no OneDrive'
        }

        It 'shares nothing when the current access cannot be read, because it cannot check what is already there' {
            $global:DriveFake.FailList = $true
            $run = New-StepRun

            { Invoke-DriveStep -Run $run } | Should -Not -Throw

            Should -Invoke -CommandName Invoke-MgInviteDriveItem -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'could not be read'
        }

        It 'records a failed invitation without throwing' {
            $global:DriveFake.FailInvite = $true
            $run = New-StepRun

            { Invoke-DriveStep -Run $run } | Should -Not -Throw

            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'simulated invite failure'
        }

        It 'records a partial success, where Graph answers normally but refuses the recipient, as Failed' {
            $global:DriveFake.PartialError = $true
            $run = New-StepRun

            Invoke-DriveStep -Run $run

            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'not accepted for the manager'
            $run.Entries[0].Detail | Should -Match 'simulated partial failure'
        }
    }
}
