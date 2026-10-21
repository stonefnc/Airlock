BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:Upn = 'ada.example@contoso.example'
    $script:UserId = 'u-ada'

    # A run whose cmdlet answers ShouldProcess as the test says: $true to go ahead,
    # $false for -WhatIf or a declined -Confirm prompt.
    function New-StepRun {
        param([bool]$Answer = $true, [bool]$IsWhatIf = $false)
        $cmdlet = [pscustomobject]@{ Answer = $Answer }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $this.Answer }
        InModuleScope Airlock -Parameters @{ Cmdlet = $cmdlet; IsWhatIf = $IsWhatIf } -ScriptBlock {
            param($Cmdlet, $IsWhatIf)
            New-AirlockRun -Command 'Remove-AirlockUser' -Cmdlet $Cmdlet -IsWhatIf $IsWhatIf -LogDirectory 'unused'
        }
    }

    function Invoke-RoleStep {
        param($Run, [string[]]$SkipStep = @(), [string[]]$OptionalMissing = @(), [hashtable]$RoleNames = @{})
        InModuleScope Airlock -Parameters @{ Run = $Run; SkipStep = $SkipStep; OptionalMissing = $OptionalMissing; RoleNames = $RoleNames } -ScriptBlock {
            param($Run, $SkipStep, $OptionalMissing, $RoleNames)
            $options = [pscustomobject]@{ SkipStep = $SkipStep; OptionalPermissionsMissing = $OptionalMissing; OwnershipAction = 'TransferToManager' }
            Invoke-AirlockRoleRemoval -Run $Run -Target 'ada.example@contoso.example' -UserId 'u-ada' -Options $options -RoleNames $RoleNames
        }
    }

    function Add-Assignment {
        param([string]$Id, [string]$RoleId, [string]$Scope = '/', [string]$Principal = 'u-ada')
        $global:RoleFake.Assignments.Add([pscustomobject]@{ Id = $Id; PrincipalId = $Principal; RoleDefinitionId = $RoleId; DirectoryScopeId = $Scope })
    }

    function Initialize-RoleFake {
        $global:RoleFake = @{
            Assignments = [System.Collections.Generic.List[object]]::new()
            FailRead    = $false
            FailRemove  = @()
        }

        Mock -ModuleName Airlock Get-MgRoleManagementDirectoryRoleAssignment -MockWith {
            if ($global:RoleFake.FailRead) { throw 'Authorization_RequestDenied: simulated read failure' }
            $principal = $null
            if ($Filter -match "^principalId eq '(.*)'$") { $principal = $Matches[1] }
            @($global:RoleFake.Assignments | Where-Object { $_.PrincipalId -eq $principal })
        }

        Mock -ModuleName Airlock Remove-MgRoleManagementDirectoryRoleAssignment -MockWith {
            if ($global:RoleFake.FailRemove -contains $UnifiedRoleAssignmentId) { throw 'Authorization_RequestDenied: simulated removal failure' }
            $match = $global:RoleFake.Assignments | Where-Object { $_.Id -eq $UnifiedRoleAssignmentId } | Select-Object -First 1
            if ($match) { [void]$global:RoleFake.Assignments.Remove($match) }
        }

        Mock -ModuleName Airlock Get-MgRoleManagementDirectoryRoleDefinition -MockWith {
            [pscustomobject]@{ Id = 'role-helpdesk'; DisplayName = 'Helpdesk Administrator' }
            [pscustomobject]@{ Id = 'role-user-admin'; DisplayName = 'User Administrator' }
        }
    }
}

AfterAll {
    Remove-Variable -Name RoleFake -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'Get-AirlockRoleNameTable' {
    BeforeEach {
        Initialize-RoleFake
    }

    It 'maps role definition ids to names' {
        $table = InModuleScope Airlock { Get-AirlockRoleNameTable }

        $table['role-helpdesk'] | Should -Be 'Helpdesk Administrator'
        $table['ROLE-USER-ADMIN'] | Should -Be 'User Administrator'
    }

    It 'returns an empty table and does not throw when the read fails' {
        Mock -ModuleName Airlock Get-MgRoleManagementDirectoryRoleDefinition -MockWith { throw 'Forbidden: simulated' }

        $table = InModuleScope Airlock { Get-AirlockRoleNameTable }

        $table.Count | Should -Be 0
    }
}

Describe 'Invoke-AirlockRoleRemoval' {
    BeforeEach {
        Initialize-RoleFake
    }

    Context 'removing roles' {
        It 'removes every active role the user holds and records each by name' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            Add-Assignment -Id 'a2' -RoleId 'role-user-admin'
            $run = New-StepRun

            Invoke-RoleStep -Run $run -RoleNames @{ 'role-helpdesk' = 'Helpdesk Administrator'; 'role-user-admin' = 'User Administrator' }

            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $UnifiedRoleAssignmentId -eq 'a1' }
            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $UnifiedRoleAssignmentId -eq 'a2' }
            $global:RoleFake.Assignments.Count | Should -Be 0
            @($run.Entries | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 2
            @($run.Entries | ForEach-Object { $_.Action } | Select-Object -Unique) | Should -Be @('RemoveDirectoryRole')
            ($run.Entries | ForEach-Object { $_.Detail }) | Should -Contain 'Helpdesk Administrator'
            ($run.Entries | ForEach-Object { $_.Detail }) | Should -Contain 'User Administrator'
            $run.Entries[0].Target | Should -Be $script:Upn
        }

        It 'reads only this user''s assignments and leaves other people''s alone' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            Add-Assignment -Id 'b1' -RoleId 'role-user-admin' -Principal 'u-someone-else'
            $run = New-StepRun

            Invoke-RoleStep -Run $run

            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $Filter -eq "principalId eq 'u-ada'" }
            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly
            @($global:RoleFake.Assignments | ForEach-Object { $_.Id }) | Should -Be @('b1')
        }

        It 'shows the scope when an assignment is scoped to something other than the whole directory' {
            Add-Assignment -Id 'a1' -RoleId 'role-user-admin' -Scope '/administrativeUnits/au-1'
            $run = New-StepRun

            Invoke-RoleStep -Run $run -RoleNames @{ 'role-user-admin' = 'User Administrator' }

            $run.Entries[0].Detail | Should -Be 'User Administrator (scope /administrativeUnits/au-1)'
        }

        It 'falls back to the role definition id when the name is not known' {
            Add-Assignment -Id 'a1' -RoleId 'role-mystery'
            $run = New-StepRun

            Invoke-RoleStep -Run $run

            $run.Entries[0].Detail | Should -Be 'role-mystery'
        }
    }

    Context 'WhatIf' {
        It 'removes nothing, records each role as WhatIf, and still reads the assignments' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            Add-Assignment -Id 'a2' -RoleId 'role-user-admin'
            $run = New-StepRun -Answer $false -IsWhatIf $true

            Invoke-RoleStep -Run $run

            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            @($run.Entries | Where-Object { $_.Status -eq 'WhatIf' }).Count | Should -Be 2
            @($run.Entries | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
            $global:RoleFake.Assignments.Count | Should -Be 2
        }

        It 'records Declined, not Skipped, when the prompt is declined, and removes nothing' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            $run = New-StepRun -Answer $false -IsWhatIf $false

            Invoke-RoleStep -Run $run

            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Declined'
        }
    }

    Context 'idempotency' {
        It 'does nothing the second time and says the user holds no roles' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            $first = New-StepRun
            $second = New-StepRun

            Invoke-RoleStep -Run $first
            Invoke-RoleStep -Run $second

            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly
            @($second.Entries).Count | Should -Be 1
            $second.Entries[0].Status | Should -Be 'Skipped'
            $second.Entries[0].Detail | Should -Match 'no active directory role'
            $second.Entries[0].Detail | Should -Match 'PIM'
        }

        It 'finishes the remaining roles after a partial earlier run' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            Add-Assignment -Id 'a2' -RoleId 'role-user-admin'
            $global:RoleFake.FailRemove = @('a1')
            $first = New-StepRun
            Invoke-RoleStep -Run $first
            $global:RoleFake.FailRemove = @()
            $second = New-StepRun

            Invoke-RoleStep -Run $second

            @($first.Entries | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 1
            @($second.Entries | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 1
            $global:RoleFake.Assignments.Count | Should -Be 0
        }
    }

    Context 'skipping' {
        It 'does nothing and does not read Graph when the operator passes -SkipStep DirectoryRoles' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            $run = New-StepRun

            Invoke-RoleStep -Run $run -SkipStep 'DirectoryRoles'

            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match '-SkipStep DirectoryRoles'
        }

        It 'does nothing and does not read Graph when RoleManagement.ReadWrite.Directory is not granted' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            $run = New-StepRun

            Invoke-RoleStep -Run $run -OptionalMissing 'RoleManagement.ReadWrite.Directory'

            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'RoleManagement.ReadWrite.Directory is not granted'
        }

        It 'is not stopped by a different permission being missing' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            $run = New-StepRun

            Invoke-RoleStep -Run $run -OptionalMissing 'Files.ReadWrite.All', 'Group.ReadWrite.All'

            $run.Entries[0].Status | Should -Be 'Applied'
        }

        It 'records a user with no roles as Skipped and removes nothing' {
            $run = New-StepRun

            Invoke-RoleStep -Run $run

            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
        }
    }

    Context 'Graph failures' {
        It 'records a failed read as a Failed entry, removes nothing and does not throw' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            $global:RoleFake.FailRead = $true
            $run = New-StepRun

            { Invoke-RoleStep -Run $run } | Should -Not -Throw

            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'could not be read'
            $run.Entries[0].Detail | Should -Match 'simulated read failure'
        }

        It 'records one failed removal and still removes the other roles' {
            Add-Assignment -Id 'a1' -RoleId 'role-helpdesk'
            Add-Assignment -Id 'a2' -RoleId 'role-user-admin'
            $global:RoleFake.FailRemove = @('a1')
            $run = New-StepRun

            { Invoke-RoleStep -Run $run } | Should -Not -Throw

            Should -Invoke -CommandName Remove-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 2 -Exactly
            $failed = @($run.Entries | Where-Object { $_.Status -eq 'Failed' })
            $failed.Count | Should -Be 1
            $failed[0].Detail | Should -Match 'simulated removal failure'
            @($run.Entries | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 1
            @($global:RoleFake.Assignments | ForEach-Object { $_.Id }) | Should -Be @('a1')
        }
    }
}
