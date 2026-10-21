BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:Upn = 'ada.example@contoso.example'
    $script:UserId = 'u-ada'
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
        param([bool]$Found = $true)
        [pscustomobject]@{ Found = $Found; Id = $(if ($Found) { 'mgr-id' } else { $null }); UserPrincipalName = $(if ($Found) { $script:ManagerUpn } else { $null }); Error = $null }
    }

    function Invoke-OwnerStep {
        param(
            $Run,
            $Manager = (New-Manager),
            [string]$Action = 'TransferToManager',
            [string[]]$SkipStep = @(),
            [string[]]$OptionalMissing = @()
        )
        InModuleScope Airlock -Parameters @{ Run = $Run; Manager = $Manager; Action = $Action; SkipStep = $SkipStep; OptionalMissing = $OptionalMissing } -ScriptBlock {
            param($Run, $Manager, $Action, $SkipStep, $OptionalMissing)
            $options = [pscustomobject]@{ SkipStep = $SkipStep; OptionalPermissionsMissing = $OptionalMissing; OwnershipAction = $Action }
            Invoke-AirlockOwnershipTransfer -Run $Run -Target 'ada.example@contoso.example' -UserId 'u-ada' -Manager $Manager -Options $options
        }
    }

    function Add-OwnedGroup {
        param(
            [string]$Id,
            [string]$Name,
            [string[]]$Owners = @('u-ada'),
            [string[]]$Types = @(),
            [bool]$Mail = $false,
            [bool]$Sync = $false
        )
        $global:OwnerFake.Groups[$Id] = [pscustomobject]@{
            Id = $Id; DisplayName = $Name; GroupTypes = $Types; MailEnabled = $Mail; SecurityEnabled = $true; OnPremisesSyncEnabled = $Sync
        }
        $global:OwnerFake.Owners[$Id] = [System.Collections.Generic.List[string]]::new()
        foreach ($owner in $Owners) { $global:OwnerFake.Owners[$Id].Add($owner) }
    }

    function Initialize-OwnerFake {
        $global:OwnerFake = @{
            Groups      = @{}
            Owners      = @{}
            Calls       = [System.Collections.Generic.List[string]]::new()
            FailOwned   = $false
            FailOwners  = @()
            FailAdd     = $false
            FailRemove  = @()
        }

        Mock -ModuleName Airlock Get-MgUserOwnedObjectAsGroup -MockWith {
            if ($global:OwnerFake.FailOwned) { throw 'Authorization_RequestDenied: simulated owned-objects failure' }
            foreach ($id in $global:OwnerFake.Groups.Keys | Sort-Object) {
                if ($global:OwnerFake.Owners[$id] -contains $UserId) { $global:OwnerFake.Groups[$id] }
            }
        }

        Mock -ModuleName Airlock Get-MgGroupOwner -MockWith {
            $global:OwnerFake.Calls.Add("owners:$GroupId")
            if ($global:OwnerFake.FailOwners -contains $GroupId) { throw 'Authorization_RequestDenied: simulated owner-list failure' }
            foreach ($owner in $global:OwnerFake.Owners[$GroupId]) { [pscustomobject]@{ Id = $owner } }
        }

        Mock -ModuleName Airlock New-MgGroupOwnerByRef -MockWith {
            $global:OwnerFake.Calls.Add("add:$GroupId")
            if ($global:OwnerFake.FailAdd) { throw 'Authorization_RequestDenied: simulated add failure' }
            $global:OwnerFake.Owners[$GroupId].Add(($BodyParameter['@odata.id'] -split '/')[-1])
        }

        Mock -ModuleName Airlock Remove-MgGroupOwnerDirectoryObjectByRef -MockWith {
            $global:OwnerFake.Calls.Add("remove:$GroupId")
            if ($global:OwnerFake.FailRemove -contains $GroupId) { throw 'Authorization_RequestDenied: simulated removal failure' }
            if ($global:OwnerFake.Owners[$GroupId].Count -le 1) { throw 'Request_BadRequest: The last owner of the group cannot be removed.' }
            [void]$global:OwnerFake.Owners[$GroupId].Remove($DirectoryObjectId)
        }

        Mock -ModuleName Airlock Remove-MgGroupOwnerByRef -MockWith {
            $global:OwnerFake.Calls.Add("old-remove:$GroupId")
            [void]$global:OwnerFake.Owners[$GroupId].Remove($DirectoryObjectId)
        }
    }

    function Get-OwnerIds {
        param([string]$GroupId)
        @($global:OwnerFake.Owners[$GroupId])
    }
}

AfterAll {
    Remove-Variable -Name OwnerFake -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'Invoke-AirlockOwnershipTransfer' {
    BeforeEach {
        Initialize-OwnerFake
    }

    Context 'the safe default' {
        It 'removes the user as an owner where another owner remains, and does not add the manager' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('u-sam')
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $GroupId -eq 'g-eng' -and $DirectoryObjectId -eq 'u-ada'
            }
            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Action | Should -Be 'RemoveGroupOwner'
            $run.Entries[0].Status | Should -Be 'Applied'
            $run.Entries[0].Detail | Should -Be 'Engineering'
            $run.Entries[0].Target | Should -Be $script:Upn
        }

        It 'adds the manager first and then removes the user when the user is the only owner' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('mgr-id')
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $GroupId -eq 'g-eng' -and $BodyParameter['@odata.id'] -eq 'https://graph.microsoft.com/v1.0/users/mgr-id'
            }
            @($global:OwnerFake.Calls | Where-Object { $_ -match '^(add|remove):' }) | Should -Be @('add:g-eng', 'remove:g-eng')
            @($run.Entries | ForEach-Object { $_.Action }) | Should -Be @('AddGroupOwner', 'RemoveGroupOwner')
            @($run.Entries | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('Applied')
            $run.Entries[0].Detail | Should -Match ([regex]::Escape($script:ManagerUpn))
        }

        It 'leaves the user in place, with the reason, when they are the only owner and there is no manager' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -Manager (New-Manager -Found $false)

            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('u-ada')
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'only owner'
            $run.Entries[0].Detail | Should -Match 'no manager'
            $run.Entries[0].Detail | Should -Match 'A group must keep an owner'
        }

        It 'treats a manager who already owns the group as the remaining owner and adds nobody' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'mgr-id'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 0 -Exactly
            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('mgr-id')
        }

        It 'never asks Graph to remove a last owner, which Graph would refuse' {
            Add-OwnedGroup -Id 'g-a' -Name 'Alpha' -Owners 'u-ada'
            Add-OwnedGroup -Id 'g-b' -Name 'Beta' -Owners 'u-ada', 'u-sam'
            Add-OwnedGroup -Id 'g-c' -Name 'Gamma' -Owners 'u-ada'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -Manager (New-Manager -Found $false)

            @($run.Entries | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 0
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'g-b' }
        }
    }

    Context '-OwnershipAction Remove' {
        It 'removes the user where another owner remains and never adds the manager' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -Action 'Remove'

            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('u-sam')
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 0 -Exactly
        }

        It 'leaves a sole owner in place even though there is a manager, and says why' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -Action 'Remove'

            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('u-ada')
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match '-OwnershipAction is Remove'
        }
    }

    Context 'several groups' {
        It 'handles each group on its own: shared, sole, and one that cannot be changed' {
            Add-OwnedGroup -Id 'g-shared' -Name 'Shared' -Owners 'u-ada', 'u-sam'
            Add-OwnedGroup -Id 'g-sole' -Name 'Sole' -Owners 'u-ada'
            Add-OwnedGroup -Id 'g-sync' -Name 'Synced' -Owners 'u-ada' -Sync $true
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Get-OwnerIds -GroupId 'g-shared' | Should -Be @('u-sam')
            Get-OwnerIds -GroupId 'g-sole' | Should -Be @('mgr-id')
            Get-OwnerIds -GroupId 'g-sync' | Should -Be @('u-ada')
            $skipped = @($run.Entries | Where-Object { $_.Status -eq 'Skipped' })
            $skipped.Count | Should -Be 1
            $skipped[0].Detail | Should -Match 'Synced'
            $skipped[0].Detail | Should -Match 'change the owner there'
            @($run.Entries | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 3
        }

        It 'skips a mail-enabled group for ownership without reading its owners' {
            Add-OwnedGroup -Id 'g-dl' -Name 'Staff List' -Owners 'u-ada', 'u-sam' -Mail $true
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Should -Invoke -CommandName Get-MgGroupOwner -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'ownership is managed in Exchange'
        }

        It 'does change the owners of a dynamic membership group' {
            Add-OwnedGroup -Id 'g-dyn' -Name 'Dynamic Team' -Owners 'u-ada', 'u-sam' -Types 'DynamicMembership', 'Unified' -Mail $true
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Get-OwnerIds -GroupId 'g-dyn' | Should -Be @('u-sam')
        }

        It 'does not own any group: records Skipped and calls nothing else' {
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'Does not own any group'
            Should -Invoke -CommandName Get-MgGroupOwner -ModuleName Airlock -Times 0 -Exactly
        }
    }

    Context 'WhatIf and declined prompts' {
        It 'changes nothing under -WhatIf, plans both changes for a sole owner, and still reads' {
            Add-OwnedGroup -Id 'g-sole' -Name 'Sole' -Owners 'u-ada'
            Add-OwnedGroup -Id 'g-shared' -Name 'Shared' -Owners 'u-ada', 'u-sam'
            $run = New-StepRun -Answer $false -IsWhatIf $true

            Invoke-OwnerStep -Run $run

            Should -Invoke -CommandName Get-MgUserOwnedObjectAsGroup -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Get-MgGroupOwner -ModuleName Airlock -Times 2 -Exactly
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 0 -Exactly
            @($run.Entries | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('WhatIf')
            @($run.Entries | ForEach-Object { $_.Action }) | Should -Be @('RemoveGroupOwner', 'AddGroupOwner', 'RemoveGroupOwner')
            Get-OwnerIds -GroupId 'g-sole' | Should -Be @('u-ada')
            Get-OwnerIds -GroupId 'g-shared' | Should -Be @('u-ada', 'u-sam')
        }

        It 'records Declined and does not remove the user when adding the manager was declined' {
            Add-OwnedGroup -Id 'g-sole' -Name 'Sole' -Owners 'u-ada'
            $run = New-StepRun -Answer $false -IsWhatIf $false

            Invoke-OwnerStep -Run $run

            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Declined'
            $run.Entries[1].Status | Should -Be 'Skipped'
            $run.Entries[1].Detail | Should -Match 'must keep an owner'
        }
    }

    Context 'idempotency' {
        It 'does nothing the second time' {
            Add-OwnedGroup -Id 'g-sole' -Name 'Sole' -Owners 'u-ada'
            Invoke-OwnerStep -Run (New-StepRun)
            $second = New-StepRun

            Invoke-OwnerStep -Run $second

            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 1 -Exactly
            $second.Entries.Count | Should -Be 1
            $second.Entries[0].Status | Should -Be 'Skipped'
        }

        It 'finishes the job when an earlier run added the manager but could not remove the user' {
            Add-OwnedGroup -Id 'g-sole' -Name 'Sole' -Owners 'u-ada'
            $global:OwnerFake.FailRemove = @('g-sole')
            $first = New-StepRun
            Invoke-OwnerStep -Run $first
            $global:OwnerFake.FailRemove = @()
            $second = New-StepRun

            Invoke-OwnerStep -Run $second

            @($first.Entries | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 1
            Get-OwnerIds -GroupId 'g-sole' | Should -Be @('mgr-id')
            Should -Invoke -CommandName New-MgGroupOwnerByRef -ModuleName Airlock -Times 1 -Exactly
            @($second.Entries | ForEach-Object { $_.Action }) | Should -Be @('RemoveGroupOwner')
            $second.Entries[0].Status | Should -Be 'Applied'
        }
    }

    Context 'skipping' {
        It 'does nothing and does not read Graph when the operator passes -SkipStep GroupOwnership' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -SkipStep 'GroupOwnership'

            Should -Invoke -CommandName Get-MgUserOwnedObjectAsGroup -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match '-SkipStep GroupOwnership'
        }

        It 'does nothing and does not read Graph when Group.ReadWrite.All is not granted' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -OptionalMissing 'Group.ReadWrite.All'

            Should -Invoke -CommandName Get-MgUserOwnedObjectAsGroup -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Skipped'
            $run.Entries[0].Detail | Should -Match 'Group.ReadWrite.All is not granted'
        }

        It 'is not stopped by a different permission being missing' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            $run = New-StepRun

            Invoke-OwnerStep -Run $run -OptionalMissing 'Files.ReadWrite.All', 'RoleManagement.ReadWrite.Directory'

            $run.Entries[0].Status | Should -Be 'Applied'
        }
    }

    Context 'Graph failures' {
        It 'records a failed read of the owned groups as one Failed entry and does not throw' {
            $global:OwnerFake.FailOwned = $true
            $run = New-StepRun

            { Invoke-OwnerStep -Run $run } | Should -Not -Throw

            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'could not be read'
            $run.Entries[0].Detail | Should -Match 'simulated owned-objects failure'
        }

        It 'records a failed owner list for one group and still processes the others' {
            Add-OwnedGroup -Id 'g-a' -Name 'Alpha' -Owners 'u-ada', 'u-sam'
            Add-OwnedGroup -Id 'g-b' -Name 'Beta' -Owners 'u-ada', 'u-sam'
            $global:OwnerFake.FailOwners = @('g-a')
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            $failed = @($run.Entries | Where-Object { $_.Status -eq 'Failed' })
            $failed.Count | Should -Be 1
            $failed[0].Detail | Should -Match 'Alpha'
            Get-OwnerIds -GroupId 'g-a' | Should -Be @('u-ada', 'u-sam')
            Get-OwnerIds -GroupId 'g-b' | Should -Be @('u-sam')
        }

        It 'leaves the user as owner when adding the manager fails, and does not try to remove them' {
            Add-OwnedGroup -Id 'g-sole' -Name 'Sole' -Owners 'u-ada'
            $global:OwnerFake.FailAdd = $true
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 0 -Exactly
            Get-OwnerIds -GroupId 'g-sole' | Should -Be @('u-ada')
            $run.Entries[0].Action | Should -Be 'AddGroupOwner'
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[1].Status | Should -Be 'Skipped'
            $run.Entries[1].Detail | Should -Match 'must keep an owner'
        }

        It 'records one failed removal and still processes the next group' {
            Add-OwnedGroup -Id 'g-a' -Name 'Alpha' -Owners 'u-ada', 'u-sam'
            Add-OwnedGroup -Id 'g-b' -Name 'Beta' -Owners 'u-ada', 'u-sam'
            $global:OwnerFake.FailRemove = @('g-a')
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            $failed = @($run.Entries | Where-Object { $_.Status -eq 'Failed' })
            $failed.Count | Should -Be 1
            $failed[0].Detail | Should -Match 'simulated removal failure'
            Get-OwnerIds -GroupId 'g-b' | Should -Be @('u-sam')
        }
    }

    Context 'SDK command names' {
        It 'uses the older command when the documented one is not available' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            Mock -ModuleName Airlock Resolve-AirlockCommand -MockWith { 'Remove-MgGroupOwnerByRef' }
            $run = New-StepRun

            Invoke-OwnerStep -Run $run

            Should -Invoke -CommandName Remove-MgGroupOwnerByRef -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Remove-MgGroupOwnerDirectoryObjectByRef -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Status | Should -Be 'Applied'
        }

        It 'records a clear failure, changes nothing, and does not throw when no removal command exists' {
            Add-OwnedGroup -Id 'g-eng' -Name 'Engineering' -Owners 'u-ada', 'u-sam'
            Mock -ModuleName Airlock Resolve-AirlockCommand -MockWith { throw 'None of these Graph commands is available: A, B. Install the Microsoft Graph PowerShell SDK version 2.0.0 or later.' }
            $run = New-StepRun

            { Invoke-OwnerStep -Run $run } | Should -Not -Throw

            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'None of these Graph commands'
            Get-OwnerIds -GroupId 'g-eng' | Should -Be @('u-ada', 'u-sam')
        }
    }
}
