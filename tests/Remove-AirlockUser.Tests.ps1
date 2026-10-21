BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:AdaUpn = 'ada.example@contoso.example'
    $script:ManagerUpn = 'grace.manager@contoso.example'

    function New-FakeGroup {
        param(
            [string]$Id,
            [string]$Name,
            [string[]]$Types = @(),
            [bool]$MailEnabled = $false,
            [bool]$SecurityEnabled = $true,
            [bool]$OnPremisesSync = $false
        )
        [pscustomobject]@{
            Id                    = $Id
            DisplayName           = $Name
            GroupTypes            = $Types
            MailEnabled           = $MailEnabled
            SecurityEnabled       = $SecurityEnabled
            OnPremisesSyncEnabled = $OnPremisesSync
        }
    }

    function Add-FakeUser {
        param(
            [string]$Upn,
            [string]$Id,
            [bool]$Enabled = $true,
            [string[]]$DirectSkus = @(),
            [string[]]$GroupSkus = @(),
            [switch]$OmitStates
        )
        $licenses = @()
        $states = @()
        foreach ($sku in $DirectSkus) {
            $licenses += [pscustomobject]@{ SkuId = $sku }
            $states += [pscustomobject]@{ SkuId = $sku; AssignedByGroup = $null; State = 'Active' }
        }
        foreach ($sku in $GroupSkus) {
            if ($DirectSkus -notcontains $sku) {
                $licenses += [pscustomobject]@{ SkuId = $sku }
            }
            $states += [pscustomobject]@{ SkuId = $sku; AssignedByGroup = 'g-licensing'; State = 'Active' }
        }

        $user = [pscustomobject]@{
            Id                = $Id
            UserPrincipalName = $Upn
            AccountEnabled    = $Enabled
            UsageLocation     = 'US'
            AssignedLicenses  = $licenses
        }
        if (-not $OmitStates) {
            $user | Add-Member -NotePropertyName LicenseAssignmentStates -NotePropertyValue $states
        }
        $global:OffUsers[$Upn] = $user
    }

    # An in-memory stand-in for the tenant. The Graph mocks read and write it, which
    # lets the idempotency tests run the command twice against the state it changed.
    function Initialize-FakeTenant {
        $global:OffUsers = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $global:OffMemberOf = @{}
        $global:OffManagers = @{}
        $global:OffFail = @{}

        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith {
            [pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; ConsumedUnits = 2; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
            [pscustomobject]@{ SkuId = 'sku-ess'; SkuPartNumber = 'O365_BUSINESS_ESSENTIALS'; ConsumedUnits = 1; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
        }

        Mock -ModuleName Airlock Get-MgUser -MockWith {
            $upn = $null
            if ($Filter -match "^userPrincipalName eq '(.*)'$") {
                $upn = $Matches[1].Replace("''", "'")
            }
            if ($upn -and $global:OffUsers.ContainsKey($upn)) {
                $global:OffUsers[$upn]
            }
        }

        Mock -ModuleName Airlock Get-MgUserManager -MockWith {
            if ($global:OffFail.ContainsKey('ManagerRead')) {
                throw 'Internal server error while reading the manager'
            }
            if ($global:OffManagers.ContainsKey($UserId)) {
                $global:OffManagers[$UserId]
            }
            else {
                throw 'Request_ResourceNotFound: the manager does not exist'
            }
        }

        Mock -ModuleName Airlock Get-MgUserMemberOfAsGroup -MockWith {
            if ($global:OffMemberOf.ContainsKey($UserId)) {
                $global:OffMemberOf[$UserId]
            }
        }

        Mock -ModuleName Airlock Update-MgUser -MockWith {
            if ($global:OffFail.ContainsKey('Block')) {
                throw 'Authorization_RequestDenied: simulated block failure'
            }
            $user = $global:OffUsers.Values | Where-Object { $_.Id -eq $UserId }
            $user.AccountEnabled = $BodyParameter.accountEnabled
        }

        Mock -ModuleName Airlock Revoke-MgUserSignInSession -MockWith {
            if ($global:OffFail.ContainsKey('Revoke')) {
                throw 'Authorization_RequestDenied: simulated revoke failure'
            }
            $true
        }

        Mock -ModuleName Airlock Set-MgUserLicense -MockWith {
            if ($global:OffFail.ContainsKey('License')) {
                throw 'Request_BadRequest: simulated license failure'
            }
            $user = $global:OffUsers.Values | Where-Object { $_.Id -eq $UserId }
            $ids = @($BodyParameter.removeLicenses)
            $user.AssignedLicenses = @($user.AssignedLicenses | Where-Object { $ids -notcontains $_.SkuId })
            if ($user.PSObject.Properties['LicenseAssignmentStates']) {
                $user.LicenseAssignmentStates = @($user.LicenseAssignmentStates | Where-Object { -not ($ids -contains $_.SkuId -and -not $_.AssignedByGroup) })
            }
        }

        Mock -ModuleName Airlock Remove-MgGroupMemberByRef -MockWith {
            if ($global:OffFail.ContainsKey("Group:$GroupId")) {
                throw 'Request_BadRequest: simulated group failure'
            }
            $global:OffMemberOf[$DirectoryObjectId] = @($global:OffMemberOf[$DirectoryObjectId] | Where-Object { $_.Id -ne $GroupId })
        }
    }

    # A typical leaver: enabled, one direct license, three ordinary groups, a manager.
    function Add-TypicalLeaver {
        Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada' -DirectSkus @('sku-e3')
        $global:OffMemberOf['u-ada'] = @(
            (New-FakeGroup -Id 'g-eng' -Name 'Engineering')
            (New-FakeGroup -Id 'g-vpn' -Name 'VPN Users')
            (New-FakeGroup -Id 'g-src' -Name 'Source Access')
        )
        $global:OffManagers['u-ada'] = [pscustomobject]@{ Id = 'mgr-id'; UserPrincipalName = $script:ManagerUpn }
    }

    function Assert-NoGraphWrites {
        foreach ($name in 'Update-MgUser', 'Revoke-MgUserSignInSession', 'Set-MgUserLicense', 'Remove-MgGroupMemberByRef') {
            Should -Invoke -CommandName $name -ModuleName Airlock -Times 0 -Exactly
        }
    }
}

AfterAll {
    Remove-Variable -Name OffUsers, OffMemberOf, OffManagers, OffFail -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'Test-AirlockUserPrincipalName' {
    It 'accepts <Value>' -ForEach @(
        @{ Value = 'ada.example@contoso.example' }
        @{ Value = 'a_b-c+d@sub.contoso.example' }
        @{ Value = "o'brien@contoso.example" }
    ) {
        InModuleScope Airlock -Parameters @{ Value = $Value } -ScriptBlock {
            param($Value)
            Test-AirlockUserPrincipalName -Value $Value
        } | Should -BeTrue
    }

    It 'rejects <Value>' -ForEach @(
        @{ Value = '' }
        @{ Value = '   ' }
        @{ Value = 'not-an-email' }
        @{ Value = 'a@b' }
        @{ Value = '@contoso.example' }
        @{ Value = 'a b@contoso.example' }
        @{ Value = 'a@contoso.example, b@contoso.example' }
        @{ Value = 'a"@contoso.example' }
    ) {
        InModuleScope Airlock -Parameters @{ Value = $Value } -ScriptBlock {
            param($Value)
            Test-AirlockUserPrincipalName -Value $Value
        } | Should -BeFalse
    }

    It 'treats null as invalid' {
        InModuleScope Airlock { Test-AirlockUserPrincipalName -Value $null } | Should -BeFalse
    }
}

Describe 'Get-AirlockGroupSkipReason' {
    It 'says why <Case> cannot be changed' -ForEach @(
        @{ Case = 'a dynamic group'; Types = @('DynamicMembership'); Mail = $false; Sync = $null; Reason = 'dynamic' }
        @{ Case = 'a dynamic Microsoft 365 group'; Types = @('DynamicMembership', 'Unified'); Mail = $true; Sync = $null; Reason = 'dynamic' }
        @{ Case = 'an on-premises synced group'; Types = @(); Mail = $false; Sync = $true; Reason = 'on-premises' }
        @{ Case = 'a distribution list'; Types = @(); Mail = $true; Sync = $null; Reason = 'Exchange' }
        @{ Case = 'a mail-enabled security group'; Types = @(); Mail = $true; Sync = $null; Reason = 'Exchange' }
    ) {
        $actual = InModuleScope Airlock -Parameters @{ Types = $Types; Mail = $Mail; Sync = $Sync } -ScriptBlock {
            param($Types, $Mail, $Sync)
            Get-AirlockGroupSkipReason -Group ([pscustomobject]@{ GroupTypes = $Types; MailEnabled = $Mail; SecurityEnabled = $true; OnPremisesSyncEnabled = $Sync })
        }

        $actual | Should -Match $Reason
    }

    It 'allows <Case>' -ForEach @(
        @{ Case = 'a plain security group'; Types = @(); Mail = $false; Sync = $null }
        @{ Case = 'a Microsoft 365 group, which is mail-enabled'; Types = @('Unified'); Mail = $true; Sync = $null }
        @{ Case = 'a group whose sync flag is false'; Types = @(); Mail = $false; Sync = $false }
    ) {
        InModuleScope Airlock -Parameters @{ Types = $Types; Mail = $Mail; Sync = $Sync } -ScriptBlock {
            param($Types, $Mail, $Sync)
            Get-AirlockGroupSkipReason -Group ([pscustomobject]@{ GroupTypes = $Types; MailEnabled = $Mail; SecurityEnabled = $true; OnPremisesSyncEnabled = $Sync })
        } | Should -BeNullOrEmpty
    }
}

Describe 'Remove-AirlockUser' {
    BeforeEach {
        Initialize-FakeTenant
        Set-AirlockTestConnection
    }

    Context 'connection' {
        It 'requires Connect-Airlock first' {
            InModuleScope Airlock { $script:AirlockState = $null }

            { Remove-AirlockUser -UserPrincipalName $script:AdaUpn } | Should -Throw '*Connect-Airlock*'
            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'requires that the permissions for this command were checked' {
            Set-AirlockTestConnection -Command 'New-AirlockUser'

            { Remove-AirlockUser -UserPrincipalName $script:AdaUpn } | Should -Throw '*-Command Remove-AirlockUser*'
        }
    }

    Context 'offboarding a user' {
        It 'blocks sign-in, revokes sessions, removes the license and every group' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            $result.Error | Should -BeNullOrEmpty

            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $UserId -eq 'u-ada' -and $BodyParameter.accountEnabled -eq $false
            }
            Should -Invoke -CommandName Revoke-MgUserSignInSession -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $UserId -eq 'u-ada' }
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $UserId -eq 'u-ada' -and @($BodyParameter.removeLicenses) -contains 'sku-e3' -and @($BodyParameter.addLicenses).Count -eq 0
            }
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly -ParameterFilter { $DirectoryObjectId -eq 'u-ada' }

            $global:OffUsers[$script:AdaUpn].AccountEnabled | Should -BeFalse
            @($global:OffUsers[$script:AdaUpn].AssignedLicenses).Count | Should -Be 0
            @($global:OffMemberOf['u-ada']).Count | Should -Be 0
        }

        It 'does the steps in a safe order and records the OneDrive recipient first' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $order = @($result.Actions | ForEach-Object { $_.Action } | Select-Object -Unique)
            $order | Should -Be @('RecordOneDriveRecipient', 'BlockSignIn', 'RevokeSessions', 'RemoveLicense', 'RemoveGroup')
        }

        It 'records the manager as the OneDrive recipient' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.OneDriveRecipient | Should -Be $script:ManagerUpn
            $entry = $result.Actions | Where-Object { $_.Action -eq 'RecordOneDriveRecipient' }
            $entry.Status | Should -Be 'Info'
            $entry.Detail | Should -Match ([regex]::Escape($script:ManagerUpn))
            $entry.Detail | Should -Match 'manually'
        }

        It 'reads the manager address from AdditionalProperties when that is where Graph puts it' {
            Add-TypicalLeaver
            $global:OffManagers['u-ada'] = [pscustomobject]@{ Id = 'mgr-id'; AdditionalProperties = @{ userPrincipalName = $script:ManagerUpn } }

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.OneDriveRecipient | Should -Be $script:ManagerUpn
        }

        It 'still offboards a user with no manager and says so' {
            Add-TypicalLeaver
            $global:OffManagers.Remove('u-ada')

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            $result.OneDriveRecipient | Should -BeNullOrEmpty
            ($result.Actions | Where-Object { $_.Action -eq 'RecordOneDriveRecipient' }).Detail | Should -Match 'No manager is set'
        }

        It 'still offboards when the manager cannot be read' {
            Add-TypicalLeaver
            $global:OffFail['ManagerRead'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            ($result.Actions | Where-Object { $_.Action -eq 'RecordOneDriveRecipient' }).Detail | Should -Match 'could not be read'
        }

        It 'does not delete the account' {
            Add-TypicalLeaver

            Remove-AirlockUser -UserPrincipalName $script:AdaUpn | Out-Null

            $global:OffUsers.ContainsKey($script:AdaUpn) | Should -BeTrue
        }

        It 'records a timestamped entry with the run id and command for every action' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            @($result.Actions | Select-Object -ExpandProperty RunId -Unique).Count | Should -Be 1
            $result.Actions | ForEach-Object {
                $_.Command | Should -Be 'Remove-AirlockUser'
                $_.Target | Should -Be $script:AdaUpn
                [datetime]::Parse($_.Timestamp) | Should -BeOfType [datetime]
            }
        }

        It 'puts the license name in the log' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            ($result.Actions | Where-Object { $_.Action -eq 'RemoveLicense' }).Detail | Should -Be 'ENTERPRISEPACK'
        }

        It 'falls back to the SKU id when license names cannot be read' {
            Add-TypicalLeaver
            Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith { throw 'Forbidden: simulated' }

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            ($result.Actions | Where-Object { $_.Action -eq 'RemoveLicense' }).Detail | Should -Be 'sku-e3'
        }

        It 'treats licenses as direct when Graph returns no assignment states' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada' -DirectSkus @('sku-e3') -OmitStates

            Remove-AirlockUser -UserPrincipalName $script:AdaUpn | Out-Null

            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
        }
    }

    Context 'WhatIf' {
        It 'changes nothing and records every planned change as WhatIf' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -WhatIf

            Assert-NoGraphWrites
            $result.Outcome | Should -Be 'WhatIf'

            $planned = @($result.Actions | Where-Object { $_.Status -eq 'WhatIf' } | ForEach-Object { $_.Action })
            $planned | Should -Contain 'BlockSignIn'
            $planned | Should -Contain 'RevokeSessions'
            $planned | Should -Contain 'RemoveLicense'
            ($planned | Where-Object { $_ -eq 'RemoveGroup' }).Count | Should -Be 3
            @($result.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0

            $global:OffUsers[$script:AdaUpn].AccountEnabled | Should -BeTrue
            @($global:OffUsers[$script:AdaUpn].AssignedLicenses).Count | Should -Be 1
            @($global:OffMemberOf['u-ada']).Count | Should -Be 3
        }

        It 'still records the OneDrive recipient because that only reads' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -WhatIf

            $result.OneDriveRecipient | Should -Be $script:ManagerUpn
        }

        It 'changes nothing for several users from the pipeline' {
            Add-TypicalLeaver
            Add-FakeUser -Upn 'sam.sample@contoso.example' -Id 'u-sam' -DirectSkus @('sku-ess')
            $global:OffMemberOf['u-sam'] = @((New-FakeGroup -Id 'g-sales' -Name 'Sales'))
            $file = Join-Path -Path $TestDrive -ChildPath 'leavers.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,Reason'
                'ada.example@contoso.example,left'
                'sam.sample@contoso.example,left'
            )

            $results = @(Import-Csv -LiteralPath $file | Remove-AirlockUser -WhatIf)

            Assert-NoGraphWrites
            $results.Count | Should -Be 2
            @($results | Where-Object { $_.Outcome -eq 'WhatIf' }).Count | Should -Be 2
        }
    }

    Context 'idempotency' {
        It 'changes nothing the second time and reports AlreadyOffboarded' {
            Add-TypicalLeaver

            $first = Remove-AirlockUser -UserPrincipalName $script:AdaUpn
            $second = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $first.Outcome | Should -Be 'Offboarded'
            $second.Outcome | Should -Be 'AlreadyOffboarded'

            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Revoke-MgUserSignInSession -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly

            @($second.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
            ($second.Actions | Where-Object { $_.Action -eq 'BlockSignIn' }).Status | Should -Be 'Skipped'
            ($second.Actions | Where-Object { $_.Action -eq 'RevokeSessions' }).Status | Should -Be 'Skipped'
            ($second.Actions | Where-Object { $_.Action -eq 'RemoveLicense' }).Status | Should -Be 'Skipped'
            ($second.Actions | Where-Object { $_.Action -eq 'RemoveGroup' }).Status | Should -Be 'Skipped'
        }

        It 'finishes the job when an earlier run only got as far as blocking sign-in' {
            Add-TypicalLeaver
            $global:OffUsers[$script:AdaUpn].AccountEnabled = $false

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Revoke-MgUserSignInSession -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
        }

        It 'removes only the group that is left after a partial run' {
            Add-TypicalLeaver
            $global:OffUsers[$script:AdaUpn].AccountEnabled = $false
            $global:OffUsers[$script:AdaUpn].AssignedLicenses = @()
            $global:OffUsers[$script:AdaUpn].LicenseAssignmentStates = @()
            $global:OffMemberOf['u-ada'] = @((New-FakeGroup -Id 'g-src' -Name 'Source Access'))

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'g-src' }
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'reports AlreadyOffboarded for a blocked user with nothing left' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada' -Enabled $false

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'AlreadyOffboarded'
            Assert-NoGraphWrites
        }
    }

    Context 'licenses and groups that cannot be removed directly' {
        It 'leaves a license that comes from a group and says why' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada' -GroupSkus @('sku-e3')

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 0 -Exactly
            $entry = $result.Actions | Where-Object { $_.Action -eq 'RemoveLicense' }
            $entry.Status | Should -Be 'Skipped'
            $entry.Detail | Should -Match 'assigned through a group'
        }

        It 'removes only the direct part when a license is both direct and from a group' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada' -DirectSkus @('sku-e3') -GroupSkus @('sku-e3')

            Remove-AirlockUser -UserPrincipalName $script:AdaUpn | Out-Null

            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                @($BodyParameter.removeLicenses) -contains 'sku-e3'
            }
        }

        It 'removes several direct licenses in one call' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada' -DirectSkus @('sku-e3', 'sku-ess')

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                @($BodyParameter.removeLicenses).Count -eq 2
            }
            ($result.Actions | Where-Object { $_.Action -eq 'RemoveLicense' }).Detail | Should -Be 'ENTERPRISEPACK, O365_BUSINESS_ESSENTIALS'
        }

        It 'skips dynamic, on-premises synced and distribution list groups and removes the rest' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada'
            $global:OffMemberOf['u-ada'] = @(
                (New-FakeGroup -Id 'g-sec' -Name 'Plain Security')
                (New-FakeGroup -Id 'g-m365' -Name 'Team Site' -Types @('Unified') -MailEnabled $true -SecurityEnabled $false)
                (New-FakeGroup -Id 'g-dyn' -Name 'Dynamic Team' -Types @('DynamicMembership'))
                (New-FakeGroup -Id 'g-sync' -Name 'Synced Group' -OnPremisesSync $true)
                (New-FakeGroup -Id 'g-dl' -Name 'Staff List' -MailEnabled $true -SecurityEnabled $false)
                (New-FakeGroup -Id 'g-mailsec' -Name 'Mail Security' -MailEnabled $true -SecurityEnabled $true)
            )

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 2 -Exactly
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'g-sec' }
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'g-m365' }

            $skipped = @($result.Actions | Where-Object { $_.Action -eq 'RemoveGroup' -and $_.Status -eq 'Skipped' })
            $skipped.Count | Should -Be 4
            ($skipped | Where-Object { $_.Detail -match 'Mail Security' }).Detail | Should -Match 'Exchange'
            ($skipped | Where-Object { $_.Detail -match 'Dynamic Team' }).Detail | Should -Match 'dynamic'
            ($skipped | Where-Object { $_.Detail -match 'Synced Group' }).Detail | Should -Match 'on-premises'
            ($skipped | Where-Object { $_.Detail -match 'Staff List' }).Detail | Should -Match 'Exchange'
            $result.Outcome | Should -Be 'Offboarded'
        }

        It 'records that there were no groups to remove' {
            Add-FakeUser -Upn $script:AdaUpn -Id 'u-ada'

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            ($result.Actions | Where-Object { $_.Action -eq 'RemoveGroup' }).Detail | Should -Match 'Not a member of any group'
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 0 -Exactly
        }
    }

    Context 'failures' {
        It 'fails a user that does not exist and changes nothing' {
            $result = Remove-AirlockUser -UserPrincipalName 'ghost@contoso.example'

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match "was not found"
            Assert-NoGraphWrites
        }

        It 'fails an invalid user principal name without calling Graph' {
            $result = Remove-AirlockUser -UserPrincipalName 'not-an-email'

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'not a valid user principal name'
            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'fails a blank user principal name' {
            $result = Remove-AirlockUser -UserPrincipalName ''

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'UserPrincipalName is missing'
            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'still revokes sessions, removes licenses and groups when blocking fails' {
            Add-TypicalLeaver
            $global:OffFail['Block'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'simulated block failure'
            Should -Invoke -CommandName Revoke-MgUserSignInSession -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
        }

        It 'carries on after one group cannot be removed' {
            Add-TypicalLeaver
            $global:OffFail['Group:g-vpn'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
            $failed = @($result.Actions | Where-Object { $_.Status -eq 'Failed' })
            $failed.Count | Should -Be 1
            $failed[0].Action | Should -Be 'RemoveGroup'
            @($global:OffMemberOf['u-ada']).Count | Should -Be 1
        }

        It 'reports a failed license removal but still removes the groups' {
            Add-TypicalLeaver
            $global:OffFail['License'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'simulated license failure'
            Should -Invoke -CommandName Remove-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
        }

        It 'fails the user, and changes nothing, when the group memberships cannot be read' {
            Add-TypicalLeaver
            Mock -ModuleName Airlock Get-MgUserMemberOfAsGroup -MockWith { throw 'Authorization_RequestDenied: simulated read failure' }

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'simulated read failure'
            Assert-NoGraphWrites
        }
    }

    Context 'declined confirmation' {
        It 'reports Declined, not AlreadyOffboarded, and changes nothing' {
            Add-TypicalLeaver

            $result = InModuleScope Airlock -ScriptBlock {
                $cmdlet = [pscustomobject]@{}
                $cmdlet | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $false }
                $run = New-AirlockRun -Command 'Remove-AirlockUser' -Cmdlet $cmdlet -LogDirectory 'unused'
                Invoke-AirlockOffboarding -Run $run -UserPrincipalName 'ada.example@contoso.example' `
                    -SkuNames ([hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)) `
                    -Seen ([hashtable]::new([System.StringComparer]::OrdinalIgnoreCase))
            }

            $result.Outcome | Should -Be 'Declined'
            Assert-NoGraphWrites
            @($result.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
            ($result.Actions | Where-Object { $_.Action -eq 'BlockSignIn' }).Status | Should -Be 'Declined'
            ($result.Actions | Where-Object { $_.Action -eq 'RemoveLicense' }).Status | Should -Be 'Declined'
            @($result.Actions | Where-Object { $_.Action -eq 'RemoveGroup' -and $_.Status -eq 'Declined' }).Count | Should -Be 3
            $global:OffUsers[$script:AdaUpn].AccountEnabled | Should -BeTrue
        }
    }

    Context 'change log' {
        It 'writes one CSV for the run, including the OneDrive recipient row' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.LogPath | Should -Exist
            $rows = @(Import-Csv -LiteralPath $result.LogPath)
            $rows.Count | Should -Be $result.Actions.Count
            @($rows | ForEach-Object { $_.Command } | Select-Object -Unique) | Should -Be 'Remove-AirlockUser'
            $recipient = $rows | Where-Object { $_.Action -eq 'RecordOneDriveRecipient' }
            $recipient.Status | Should -Be 'Info'
            $recipient.Detail | Should -Match ([regex]::Escape($script:ManagerUpn))
        }

        It 'writes the log with the finished users even when the run ends with an unexpected error' {
            Add-TypicalLeaver
            $dir = Join-Path -Path $TestDrive -ChildPath 'crash-logs'
            Set-AirlockTestConnection -LogDirectory $dir
            Mock -ModuleName Airlock Test-AirlockUserPrincipalName -MockWith {
                if ($Value -like 'boom@*') { throw 'unexpected terminating error' }
                $true
            }

            { Remove-AirlockUser -UserPrincipalName $script:AdaUpn, 'boom@contoso.example' } | Should -Throw '*unexpected terminating error*'

            $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.csv')
            $files.Count | Should -Be 1
            $rows = @(Import-Csv -LiteralPath $files[0].FullName)
            @($rows | Where-Object { $_.Target -eq 'ada.example@contoso.example' -and $_.Action -eq 'BlockSignIn' -and $_.Status -eq 'Applied' }).Count | Should -Be 1
        }

        It 'writes one log file, not one per pipeline item' {
            Add-TypicalLeaver
            Add-FakeUser -Upn 'sam.sample@contoso.example' -Id 'u-sam'
            $dir = Join-Path -Path $TestDrive -ChildPath 'pipeline-logs'
            Set-AirlockTestConnection -LogDirectory $dir

            $null = @('ada.example@contoso.example', 'sam.sample@contoso.example') | Remove-AirlockUser

            @(Get-ChildItem -LiteralPath $dir -Filter '*.csv').Count | Should -Be 1
        }

        It 'writes no log when the command is refused before the run starts' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'refused-logs'
            Set-AirlockTestConnection -Command 'New-AirlockUser' -LogDirectory $dir

            { Remove-AirlockUser -UserPrincipalName $script:AdaUpn } | Should -Throw '*-Command Remove-AirlockUser*'

            Test-Path -LiteralPath $dir | Should -BeFalse
        }

        It 'writes the log for a WhatIf run and records the plan as WhatIf' {
            Add-TypicalLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -WhatIf

            $result.LogPath | Should -Exist
            $rows = @(Import-Csv -LiteralPath $result.LogPath)
            @($rows | Where-Object { $_.Status -eq 'WhatIf' }).Count | Should -Be 6
            @($rows | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
        }

        It 'writes a single file for several users from the pipeline' {
            Add-TypicalLeaver
            Add-FakeUser -Upn 'sam.sample@contoso.example' -Id 'u-sam'

            $results = @('ada.example@contoso.example', 'sam.sample@contoso.example', 'ghost@contoso.example' | Remove-AirlockUser)

            @($results | ForEach-Object { $_.LogPath } | Select-Object -Unique).Count | Should -Be 1
            $rows = @(Import-Csv -LiteralPath $results[0].LogPath)
            @($rows | ForEach-Object { $_.Target } | Select-Object -Unique).Count | Should -Be 3
            ($rows | Where-Object { $_.Target -eq 'ghost@contoso.example' }).Status | Should -Be 'Failed'
        }

        It 'still returns the results when the log folder cannot be used' {
            Add-TypicalLeaver
            $blocker = Join-Path -Path $TestDrive -ChildPath 'blocker-file'
            Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
            Set-AirlockTestConnection -LogDirectory (Join-Path -Path $blocker -ChildPath 'logs')

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -WarningVariable logWarning -WarningAction SilentlyContinue

            $result.Outcome | Should -Be 'Offboarded'
            ($logWarning -join ' ') | Should -Match 'could not be written'
        }
    }

    Context 'several users' {
        It 'processes an array and carries on past a user that cannot be found' {
            Add-TypicalLeaver
            Add-FakeUser -Upn 'sam.sample@contoso.example' -Id 'u-sam' -DirectSkus @('sku-ess')
            $global:OffMemberOf['u-sam'] = @((New-FakeGroup -Id 'g-sales' -Name 'Sales'))

            $results = @(Remove-AirlockUser -UserPrincipalName $script:AdaUpn, 'ghost@contoso.example', 'sam.sample@contoso.example')

            $results.Count | Should -Be 3
            $results[0].Outcome | Should -Be 'Offboarded'
            $results[1].Outcome | Should -Be 'Failed'
            $results[2].Outcome | Should -Be 'Offboarded'
            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 2 -Exactly
        }

        It 'treats a repeated user principal name in one run as an error and does not process it twice' {
            Add-TypicalLeaver

            $results = @(Remove-AirlockUser -UserPrincipalName $script:AdaUpn, $script:AdaUpn.ToUpper())

            $results[0].Outcome | Should -Be 'Offboarded'
            $results[1].Outcome | Should -Be 'Failed'
            $results[1].Error | Should -Match 'appears more than once'
            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 1 -Exactly
        }

        It 'gives each user its own run entries but one run id' {
            Add-TypicalLeaver
            Add-FakeUser -Upn 'sam.sample@contoso.example' -Id 'u-sam'

            $results = @(Remove-AirlockUser -UserPrincipalName $script:AdaUpn, 'sam.sample@contoso.example')

            @($results[0].Actions | Where-Object { $_.Target -ne $script:AdaUpn }).Count | Should -Be 0
            @($results[1].Actions | Where-Object { $_.Target -ne 'sam.sample@contoso.example' }).Count | Should -Be 0
            $ids = @($results | ForEach-Object { $_.Actions } | ForEach-Object { $_.RunId } | Select-Object -Unique)
            $ids.Count | Should -Be 1
        }
    }
}
