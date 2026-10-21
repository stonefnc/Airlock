BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:RolesFile = Join-Path -Path $TestDrive -ChildPath 'roles.json'
    Set-Content -LiteralPath $script:RolesFile -Value @'
{
  "defaults": { "usageLocation": "US" },
  "roles": {
    "engineer":   { "groups": ["Engineering", "VPN Users", "Source Access"], "licenseSku": "ENTERPRISEPACK" },
    "nolicense":  { "groups": ["Engineering"] },
    "dyn":        { "groups": ["Dynamic Team"], "licenseSku": "ENTERPRISEPACK" },
    "ghostgroup": { "groups": ["No Such Group"], "licenseSku": "ENTERPRISEPACK" },
    "twin":       { "groups": ["Twin"] },
    "nosku":      { "groups": [], "licenseSku": "NOT_A_SKU" },
    "exhausted":  { "groups": [], "licenseSku": "O365_BUSINESS_ESSENTIALS" }
  }
}
'@

    $script:ManagerUpn = 'grace.manager@contoso.example'
    $script:AdaUpn = 'ada.example@contoso.example'

    # An in-memory stand-in for the tenant. The Graph mocks read and write it, which
    # lets the idempotency tests run the command twice against the state it created.
    function Initialize-FakeTenant {
        $global:AirlockTestUsers = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $global:AirlockTestMembers = @{}
        $global:AirlockTestManagers = @{}
        $global:AirlockTestDrive = 'missing'
        $global:AirlockTestFailVpn = $false

        $global:AirlockTestUsers['grace.manager@contoso.example'] = [pscustomobject]@{
            Id                = 'mgr-id'
            UserPrincipalName = 'grace.manager@contoso.example'
            UsageLocation     = 'US'
            AssignedLicenses  = @()
        }

        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith {
            [pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; ConsumedUnits = 2; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
            [pscustomobject]@{ SkuId = 'sku-ess'; SkuPartNumber = 'O365_BUSINESS_ESSENTIALS'; ConsumedUnits = 5; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
        }

        Mock -ModuleName Airlock Get-MgUser -MockWith {
            $upn = $null
            if ($Filter -match "^userPrincipalName eq '(.*)'$") {
                $upn = $Matches[1].Replace("''", "'")
            }
            if ($upn -and $global:AirlockTestUsers.ContainsKey($upn)) {
                $global:AirlockTestUsers[$upn]
            }
        }

        Mock -ModuleName Airlock New-MgUser -MockWith {
            if ($BodyParameter.userPrincipalName -like 'fail.*') {
                throw 'Request_BadRequest: simulated create failure'
            }
            $user = [pscustomobject]@{
                Id                = [guid]::NewGuid().ToString()
                UserPrincipalName = $BodyParameter.userPrincipalName
                UsageLocation     = $BodyParameter.usageLocation
                AssignedLicenses  = @()
            }
            $global:AirlockTestUsers[$BodyParameter.userPrincipalName] = $user
            $user
        }

        Mock -ModuleName Airlock Update-MgUser -MockWith {
            $user = $global:AirlockTestUsers.Values | Where-Object { $_.Id -eq $UserId }
            $user.UsageLocation = $BodyParameter.usageLocation
        }

        Mock -ModuleName Airlock Get-MgUserManager -MockWith {
            if ($global:AirlockTestManagers.ContainsKey($UserId)) {
                [pscustomobject]@{ Id = $global:AirlockTestManagers[$UserId] }
            }
            else {
                throw 'Request_ResourceNotFound: manager not found'
            }
        }

        Mock -ModuleName Airlock Set-MgUserManagerByRef -MockWith {
            $global:AirlockTestManagers[$UserId] = ($BodyParameter['@odata.id'] -split '/')[-1]
        }

        Mock -ModuleName Airlock Get-MgGroup -MockWith {
            $name = $null
            if ($Filter -match "^displayName eq '(.*)'$") {
                $name = $Matches[1].Replace("''", "'")
            }
            switch ($name) {
                'Engineering' { [pscustomobject]@{ Id = 'g-eng'; DisplayName = $name; GroupTypes = @() } }
                'VPN Users' { [pscustomobject]@{ Id = 'g-vpn'; DisplayName = $name; GroupTypes = @() } }
                'Source Access' { [pscustomobject]@{ Id = 'g-src'; DisplayName = $name; GroupTypes = @() } }
                'Dynamic Team' { [pscustomobject]@{ Id = 'g-dyn'; DisplayName = $name; GroupTypes = @('DynamicMembership', 'Unified') } }
                'Twin' {
                    [pscustomobject]@{ Id = 'g-twin-1'; DisplayName = $name; GroupTypes = @() }
                    [pscustomobject]@{ Id = 'g-twin-2'; DisplayName = $name; GroupTypes = @() }
                }
            }
        }

        Mock -ModuleName Airlock Get-MgGroupMember -MockWith {
            if ($global:AirlockTestMembers.ContainsKey($GroupId)) {
                foreach ($id in $global:AirlockTestMembers[$GroupId]) {
                    [pscustomobject]@{ Id = $id }
                }
            }
        }

        Mock -ModuleName Airlock New-MgGroupMemberByRef -MockWith {
            if ($GroupId -eq 'g-vpn' -and $global:AirlockTestFailVpn) {
                throw 'Request_BadRequest: simulated group failure'
            }
            $userId = ($BodyParameter['@odata.id'] -split '/')[-1]
            if (-not $global:AirlockTestMembers.ContainsKey($GroupId)) {
                $global:AirlockTestMembers[$GroupId] = @()
            }
            $global:AirlockTestMembers[$GroupId] += $userId
        }

        Mock -ModuleName Airlock Set-MgUserLicense -MockWith {
            $user = $global:AirlockTestUsers.Values | Where-Object { $_.Id -eq $UserId }
            $user.AssignedLicenses = @($user.AssignedLicenses) + [pscustomobject]@{ SkuId = $BodyParameter.addLicenses[0].skuId }
        }

        Mock -ModuleName Airlock Get-MgUserDefaultDrive -MockWith {
            switch ($global:AirlockTestDrive) {
                'ready' { [pscustomobject]@{ Id = 'drive-1' } }
                'forbidden' { throw 'Forbidden: Access denied' }
                default { throw 'itemNotFound: The resource could not be found' }
            }
        }
    }

    # An existing user who already has everything the engineer role gives.
    function Add-FullyProvisionedAda {
        $global:AirlockTestUsers[$script:AdaUpn] = [pscustomobject]@{
            Id                = 'u-ada'
            UserPrincipalName = $script:AdaUpn
            UsageLocation     = 'US'
            AssignedLicenses  = @([pscustomobject]@{ SkuId = 'sku-e3' })
        }
        $global:AirlockTestMembers['g-eng'] = @('u-ada')
        $global:AirlockTestMembers['g-vpn'] = @('u-ada')
        $global:AirlockTestMembers['g-src'] = @('u-ada')
        $global:AirlockTestManagers['u-ada'] = 'mgr-id'
    }

    function Assert-NoGraphWrites {
        foreach ($name in 'New-MgUser', 'Update-MgUser', 'Set-MgUserManagerByRef', 'New-MgGroupMemberByRef', 'Set-MgUserLicense') {
            Should -Invoke -CommandName $name -ModuleName Airlock -Times 0 -Exactly
        }
    }

    function ConvertTo-PlainText {
        param([securestring]$Secure)
        [System.Net.NetworkCredential]::new('', $Secure).Password
    }
}

AfterAll {
    Remove-Variable -Name AirlockTestUsers, AirlockTestMembers, AirlockTestManagers, AirlockTestDrive, AirlockTestFailVpn -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'New-AirlockPassword' {
    It 'meets complexity and is long enough' {
        $password = InModuleScope Airlock { New-AirlockPassword }

        $password.Length | Should -Be 20
        $password | Should -MatchExactly '[a-z]'
        $password | Should -MatchExactly '[A-Z]'
        $password | Should -MatchExactly '[0-9]'
        $password | Should -MatchExactly '[!#$%&*+=?@-]'
    }

    It 'is different every time' {
        $passwords = InModuleScope Airlock { 1..20 | ForEach-Object { New-AirlockPassword } }

        @($passwords | Select-Object -Unique).Count | Should -Be 20
    }
}

Describe 'Import-AirlockRoleMap' {
    It 'loads roles with a case-insensitive lookup' {
        $map = InModuleScope Airlock -Parameters @{ Path = $script:RolesFile } -ScriptBlock {
            param($Path)
            Import-AirlockRoleMap -Path $Path
        }

        $map.UsageLocation | Should -Be 'US'
        $map.Roles.ContainsKey('ENGINEER') | Should -BeTrue
        $map.Roles['engineer'].Groups | Should -Be @('Engineering', 'VPN Users', 'Source Access')
        $map.Roles['engineer'].LicenseSku | Should -Be 'ENTERPRISEPACK'
        $map.Roles['nolicense'].LicenseSku | Should -Be ''
    }

    It 'throws when the file is missing' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'nope.json'

        {
            InModuleScope Airlock -Parameters @{ Path = $missing } -ScriptBlock {
                param($Path)
                Import-AirlockRoleMap -Path $Path
            }
        } | Should -Throw '*not found*'
    }

    It 'throws when the file is not JSON' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'bad.json'
        Set-Content -LiteralPath $bad -Value '{ this is not json'

        {
            InModuleScope Airlock -Parameters @{ Path = $bad } -ScriptBlock {
                param($Path)
                Import-AirlockRoleMap -Path $Path
            }
        } | Should -Throw '*not valid JSON*'
    }

    It 'throws when there is no roles section' {
        $empty = Join-Path -Path $TestDrive -ChildPath 'noroles.json'
        Set-Content -LiteralPath $empty -Value '{ "defaults": {} }'

        {
            InModuleScope Airlock -Parameters @{ Path = $empty } -ScriptBlock {
                param($Path)
                Import-AirlockRoleMap -Path $Path
            }
        } | Should -Throw "*no 'roles' section*"
    }

    It 'rejects a usage location that is not a country code' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'badloc.json'
        Set-Content -LiteralPath $bad -Value '{ "defaults": { "usageLocation": "USA" }, "roles": {} }'

        {
            InModuleScope Airlock -Parameters @{ Path = $bad } -ScriptBlock {
                param($Path)
                Import-AirlockRoleMap -Path $Path
            }
        } | Should -Throw '*two letter country code*'
    }
}

Describe 'Import-AirlockUserCsv' {
    It 'reads rows, trims values and numbers them from the header line' {
        $file = Join-Path -Path $TestDrive -ChildPath 'ok.csv'
        Set-Content -LiteralPath $file -Value @(
            'userprincipalname,DisplayName,Role'
            ' a@contoso.example , Aaa ,engineer'
            'b@contoso.example,Bbb,sales'
        )

        $rows = InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Import-AirlockUserCsv -Path $Path
        }

        @($rows).Count | Should -Be 2
        $rows[0].UserPrincipalName | Should -Be 'a@contoso.example'
        $rows[0].DisplayName | Should -Be 'Aaa'
        $rows[0].RowNumber | Should -Be 2
        $rows[1].RowNumber | Should -Be 3
        $rows[0].Manager | Should -Be ''
    }

    It 'throws when a required column is missing' {
        $file = Join-Path -Path $TestDrive -ChildPath 'nocol.csv'
        Set-Content -LiteralPath $file -Value @('UserPrincipalName,DisplayName', 'a@contoso.example,Aaa')

        {
            InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
                param($Path)
                Import-AirlockUserCsv -Path $Path
            }
        } | Should -Throw '*missing required column*Role*'
    }

    It 'throws when the file has no data rows' {
        $file = Join-Path -Path $TestDrive -ChildPath 'norows.csv'
        Set-Content -LiteralPath $file -Value 'UserPrincipalName,DisplayName,Role'

        {
            InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
                param($Path)
                Import-AirlockUserCsv -Path $Path
            }
        } | Should -Throw '*no data rows*'
    }

    It 'throws when the file does not exist' {
        $file = Join-Path -Path $TestDrive -ChildPath 'absent.csv'

        {
            InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
                param($Path)
                Import-AirlockUserCsv -Path $Path
            }
        } | Should -Throw '*not found*'
    }
}

Describe 'New-AirlockUser' {
    BeforeEach {
        Initialize-FakeTenant
        Set-AirlockTestConnection
    }

    Context 'connection' {
        It 'requires Connect-Airlock first' {
            InModuleScope Airlock { $script:AirlockState = $null }

            { New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada' -Role engineer -RolesPath $script:RolesFile } |
                Should -Throw '*Connect-Airlock*'
            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'requires that the permissions for this command were checked' {
            Set-AirlockTestConnection -Command 'Remove-AirlockUser'

            { New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada' -Role engineer -RolesPath $script:RolesFile } |
                Should -Throw '*-Command New-AirlockUser*'
        }
    }

    Context 'creating a user' {
        It 'creates the user, sets the manager, adds every group and assigns the license' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -GivenName 'Ada' -Surname 'Example' -Department 'Engineering' -JobTitle 'Engineer' `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Created'
            $result.Created | Should -BeTrue

            Should -Invoke -CommandName New-MgUser -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $BodyParameter.userPrincipalName -eq 'ada.example@contoso.example' -and
                $BodyParameter.displayName -eq 'Ada Example' -and
                $BodyParameter.mailNickname -eq 'ada.example' -and
                $BodyParameter.accountEnabled -eq $true -and
                $BodyParameter.usageLocation -eq 'US' -and
                $BodyParameter.givenName -eq 'Ada' -and
                $BodyParameter.surname -eq 'Example' -and
                $BodyParameter.department -eq 'Engineering' -and
                $BodyParameter.jobTitle -eq 'Engineer' -and
                $BodyParameter.passwordProfile.forceChangePasswordNextSignIn -eq $true -and
                $BodyParameter.passwordProfile.password.Length -ge 12
            }
            Should -Invoke -CommandName New-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $BodyParameter.addLicenses[0].skuId -eq 'sku-e3' -and @($BodyParameter.removeLicenses).Count -eq 0
            }
            Should -Invoke -CommandName Set-MgUserManagerByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $BodyParameter['@odata.id'] -eq 'https://graph.microsoft.com/v1.0/users/mgr-id'
            }
            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 0 -Exactly

            $actions = $result.Actions | Where-Object { $_.Status -eq 'Applied' } | ForEach-Object { $_.Action }
            ($actions | Where-Object { $_ -eq 'AddGroup' }).Count | Should -Be 3
            $actions | Should -Contain 'CreateUser'
            $actions | Should -Contain 'SetManager'
            $actions | Should -Contain 'AssignLicense'
        }

        It 'returns the temporary password once as a SecureString and never logs it' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role nolicense -RolesPath $script:RolesFile

            $result.TemporaryPassword | Should -BeOfType [securestring]
            $plain = ConvertTo-PlainText -Secure $result.TemporaryPassword
            $plain.Length | Should -BeGreaterOrEqual 12

            ($result.Actions | ConvertTo-Json -Depth 4) | Should -Not -Match ([regex]::Escape($plain))
            ($result | Select-Object -Property * -ExcludeProperty TemporaryPassword | ConvertTo-Json -Depth 4) | Should -Not -Match ([regex]::Escape($plain))
        }

        It 'records a timestamped entry with the run id and command for every action' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile

            $result.Actions.Count | Should -BeGreaterThan 0
            @($result.Actions | Select-Object -ExpandProperty RunId -Unique).Count | Should -Be 1
            $result.Actions | ForEach-Object {
                $_.Command | Should -Be 'New-AirlockUser'
                $_.Target | Should -Be $script:AdaUpn
                [datetime]::Parse($_.Timestamp) | Should -BeOfType [datetime]
            }
        }

        It 'skips the license and OneDrive check for a role without a license' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role nolicense -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Created'
            $result.OneDrive | Should -Be 'NotChecked'
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 0 -Exactly
        }
    }

    Context 'WhatIf' {
        It 'changes nothing for a new user and records every change as WhatIf' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile -WhatIf

            Assert-NoGraphWrites
            $result.Outcome | Should -Be 'WhatIf'
            $result.Created | Should -BeFalse
            $result.TemporaryPassword | Should -BeNullOrEmpty

            $planned = $result.Actions | Where-Object { $_.Status -eq 'WhatIf' } | ForEach-Object { $_.Action }
            $planned | Should -Contain 'CreateUser'
            $planned | Should -Contain 'SetManager'
            $planned | Should -Contain 'AssignLicense'
            ($planned | Where-Object { $_ -eq 'AddGroup' }).Count | Should -Be 3
            @($result.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
        }

        It 'does not check OneDrive for a user that does not exist yet' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile -WhatIf

            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 0 -Exactly
            $result.OneDrive | Should -Be 'NotChecked'
        }

        It 'changes nothing for an existing partly provisioned user and plans only what is missing' {
            Add-FullyProvisionedAda
            $global:AirlockTestMembers['g-vpn'] = @()
            $global:AirlockTestUsers[$script:AdaUpn].AssignedLicenses = @()

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile -WhatIf

            Assert-NoGraphWrites
            $planned = @($result.Actions | Where-Object { $_.Status -eq 'WhatIf' })
            $planned.Count | Should -Be 2
            ($planned | ForEach-Object { $_.Action }) | Should -Contain 'AddGroup'
            ($planned | ForEach-Object { $_.Action }) | Should -Contain 'AssignLicense'
            ($planned | Where-Object { $_.Action -eq 'AddGroup' }).Detail | Should -Be 'VPN Users'
        }

        It 'changes nothing for a CSV' {
            $file = Join-Path -Path $TestDrive -ChildPath 'whatif.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role'
                'one@contoso.example,One,engineer'
                'two@contoso.example,Two,nolicense'
            )

            $results = New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile -WhatIf

            Assert-NoGraphWrites
            @($results).Count | Should -Be 2
            @($results | Where-Object { $_.Outcome -eq 'WhatIf' }).Count | Should -Be 2
        }

        It 'does not let the license count run out silently in a preview' {
            $file = Join-Path -Path $TestDrive -ChildPath 'preview-licenses.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role'
                (1..9 | ForEach-Object { "u$_@contoso.example,U$_,engineer" })
            )

            $results = @(New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile -WhatIf)

            @($results | Where-Object { $_.Outcome -eq 'WhatIf' }).Count | Should -Be 8
            $results[8].Outcome | Should -Be 'Failed'
            $results[8].Error | Should -Match 'No licenses are left'
            Assert-NoGraphWrites
        }
    }

    Context 'idempotency' {
        It 'does nothing the second time' {
            $first = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile
            $second = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile

            $first.Outcome | Should -Be 'Created'
            $second.Outcome | Should -Be 'Existing'
            $second.Created | Should -BeFalse
            $second.TemporaryPassword | Should -BeNullOrEmpty

            Should -Invoke -CommandName New-MgUser -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName New-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Set-MgUserManagerByRef -ModuleName Airlock -Times 1 -Exactly

            @($second.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
            @($second.Actions | Where-Object { $_.Status -eq 'Skipped' }).Count | Should -BeGreaterOrEqual 6
            $global:AirlockTestMembers['g-eng'].Count | Should -Be 1
        }

        It 'makes no changes for a user that already has everything' {
            Add-FullyProvisionedAda

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile

            Assert-NoGraphWrites
            $result.Outcome | Should -Be 'Existing'
            @($result.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
        }

        It 'adds only the group that is missing' {
            Add-FullyProvisionedAda
            $global:AirlockTestMembers['g-src'] = @()

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Existing'
            Should -Invoke -CommandName New-MgGroupMemberByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'g-src' }
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName New-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'sets a usage location on an existing user before assigning the license' {
            Add-FullyProvisionedAda
            $global:AirlockTestUsers[$script:AdaUpn].UsageLocation = $null
            $global:AirlockTestUsers[$script:AdaUpn].AssignedLicenses = @()

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile

            Should -Invoke -CommandName Update-MgUser -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
                $UserId -eq 'u-ada' -and $BodyParameter.usageLocation -eq 'US'
            }
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
            $result.Outcome | Should -Be 'Existing'
        }

        It 'sets the manager when it differs' {
            Add-FullyProvisionedAda
            $global:AirlockTestManagers['u-ada'] = 'someone-else'

            New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile | Out-Null

            Should -Invoke -CommandName Set-MgUserManagerByRef -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $UserId -eq 'u-ada' }
        }

        It 'does not try to add a user to a dynamic group' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role dyn -RolesPath $script:RolesFile

            Should -Invoke -CommandName New-MgGroupMemberByRef -ModuleName Airlock -Times 0 -Exactly
            $entry = $result.Actions | Where-Object { $_.Action -eq 'AddGroup' }
            $entry.Status | Should -Be 'Skipped'
            $entry.Detail | Should -Match 'dynamic'
        }
    }

    Context 'missing role and bad lookups' {
        It 'fails a user whose role is not in the roles file and changes nothing' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role wizard -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match "Role 'wizard' is not defined"
            Assert-NoGraphWrites
            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
        }

        It 'matches the role without regard to case' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role ENGINEER -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Created'
        }

        It 'fails before creating anything when a group does not exist' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role ghostgroup -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match "Group 'No Such Group' was not found"
            Assert-NoGraphWrites
        }

        It 'fails before creating anything when a group name is ambiguous' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role twin -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'more than one group'
            Assert-NoGraphWrites
        }

        It 'fails before creating anything when the manager does not exist' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager 'nobody@contoso.example' -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match "Manager 'nobody@contoso.example' was not found"
            Assert-NoGraphWrites
        }

        It 'fails before creating anything when the license SKU is not in the tenant' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role nosku -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'not available in this tenant'
            Assert-NoGraphWrites
        }

        It 'fails before creating anything when no licenses are left' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role exhausted -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'No licenses are left'
            Assert-NoGraphWrites
        }

        It 'fails a user with an invalid user principal name without calling Graph' {
            $result = New-AirlockUser -UserPrincipalName 'not-an-email' -DisplayName 'Nobody' -Role engineer -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Error | Should -Match 'not a valid user principal name'
            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
            Assert-NoGraphWrites
        }

        It 'treats a quote in the name as data, not as part of the filter' {
            $upn = "o'brien@contoso.example"

            New-AirlockUser -UserPrincipalName $upn -DisplayName "O'Brien" -Role nolicense -RolesPath $script:RolesFile | Out-Null

            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -ParameterFilter { $Filter -eq "userPrincipalName eq 'o''brien@contoso.example'" }
        }
    }

    Context 'failures while applying' {
        It 'stops that user when the create fails and does not run later steps' {
            $result = New-AirlockUser -UserPrincipalName 'fail.user@contoso.example' -DisplayName 'Fail User' -Role engineer -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Created | Should -BeFalse
            $result.Error | Should -Match 'simulated create failure'
            Should -Invoke -CommandName New-MgGroupMemberByRef -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 0 -Exactly
        }

        It 'carries on after one group fails but reports the user as Failed' {
            $global:AirlockTestFailVpn = $true

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile

            $result.Outcome | Should -Be 'Failed'
            $result.Created | Should -BeTrue
            Should -Invoke -CommandName New-MgGroupMemberByRef -ModuleName Airlock -Times 3 -Exactly
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 1 -Exactly
            $failed = @($result.Actions | Where-Object { $_.Status -eq 'Failed' })
            $failed.Count | Should -Be 1
            $failed[0].Action | Should -Be 'AddGroup'
        }
    }

    Context 'OneDrive check' {
        It 'reports Ready when the drive exists' {
            Add-FullyProvisionedAda
            $global:AirlockTestDrive = 'ready'

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile

            $result.OneDrive | Should -Be 'Ready'
        }

        It 'reports Pending, not a failure, when the drive is not provisioned yet' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile

            $result.OneDrive | Should -Be 'Pending'
            $result.Outcome | Should -Be 'Created'
            ($result.Actions | Where-Object { $_.Action -eq 'CheckOneDrive' }).Status | Should -Be 'Info'
        }

        It 'reports Unknown and still succeeds when the check is not permitted' {
            $global:AirlockTestDrive = 'forbidden'

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile

            $result.OneDrive | Should -Be 'Unknown'
            $result.Outcome | Should -Be 'Created'
            ($result.Actions | Where-Object { $_.Action -eq 'CheckOneDrive' }).Detail | Should -Match 'Forbidden'
        }
    }

    Context 'change log' {
        It 'writes one CSV for the run and puts its path on the result' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -Manager $script:ManagerUpn -RolesPath $script:RolesFile

            $result.LogPath | Should -Exist
            $rows = @(Import-Csv -LiteralPath $result.LogPath)
            $rows.Count | Should -Be $result.Actions.Count
            @($rows | ForEach-Object { $_.Command } | Select-Object -Unique) | Should -Be 'New-AirlockUser'
            @($rows | ForEach-Object { $_.RunId } | Select-Object -Unique).Count | Should -Be 1
            ($rows | Where-Object { $_.Action -eq 'CreateUser' }).Status | Should -Be 'Applied'
            @($rows | Where-Object { $_.Action -eq 'AddGroup' -and $_.Status -eq 'Applied' }).Count | Should -Be 3
        }

        It 'never writes the temporary password to the file' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile
            $plain = ConvertTo-PlainText -Secure $result.TemporaryPassword

            $plain.Length | Should -BeGreaterOrEqual 12
            (Get-Content -LiteralPath $result.LogPath -Raw) | Should -Not -Match ([regex]::Escape($plain))
        }

        It 'writes the log for a WhatIf run and records the plan as WhatIf' {
            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer -RolesPath $script:RolesFile -WhatIf

            $result.LogPath | Should -Exist
            $rows = @(Import-Csv -LiteralPath $result.LogPath)
            @($rows | Where-Object { $_.Status -eq 'WhatIf' }).Count | Should -BeGreaterThan 0
            @($rows | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
        }

        It 'writes one file for a whole CSV run with a row per action for every user' {
            $file = Join-Path -Path $TestDrive -ChildPath 'logged.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role'
                'one@contoso.example,One,nolicense'
                'two@contoso.example,Two,wizard'
            )

            $results = @(New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile)

            @($results | ForEach-Object { $_.LogPath } | Select-Object -Unique).Count | Should -Be 1
            $rows = @(Import-Csv -LiteralPath $results[0].LogPath)
            $rows.Count | Should -Be (($results | ForEach-Object { $_.Actions.Count } | Measure-Object -Sum).Sum)
            ($rows | Where-Object { $_.Target -eq 'two@contoso.example' }).Status | Should -Be 'Failed'
        }

        It 'still returns the results when the log folder cannot be used' {
            $blocker = Join-Path -Path $TestDrive -ChildPath 'blocker-file'
            Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
            Set-AirlockTestConnection -LogDirectory (Join-Path -Path $blocker -ChildPath 'logs')

            $result = New-AirlockUser -UserPrincipalName $script:AdaUpn -DisplayName 'Ada Example' -Role engineer `
                -RolesPath $script:RolesFile -WarningVariable logWarning -WarningAction SilentlyContinue

            $result.Outcome | Should -Be 'Created'
            ($logWarning -join ' ') | Should -Match 'could not be written'
            $result.LogPath | Should -Not -Exist
        }
    }

    Context 'CSV input' {
        It 'processes good rows and reports bad rows without stopping' {
            $file = Join-Path -Path $TestDrive -ChildPath 'mixed.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role,Manager'
                'one@contoso.example,One,engineer,grace.manager@contoso.example'
                'two@contoso.example,Two,wizard,'
                'not-an-email,Three,engineer,'
                'one@contoso.example,One Again,engineer,'
                ',Missing Upn,engineer,'
                'six@contoso.example,,engineer,'
                'seven@contoso.example,Seven,engineer,not-an-email'
                'eight@contoso.example,Eight,nolicense,'
            )

            $results = @(New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile)

            $results.Count | Should -Be 8
            $results[0].Outcome | Should -Be 'Created'
            $results[1].Error | Should -Match "Role 'wizard' is not defined"
            $results[2].Error | Should -Match 'not a valid user principal name'
            $results[3].Error | Should -Match 'appears more than once'
            $results[4].Error | Should -Match 'UserPrincipalName is missing'
            $results[5].Error | Should -Match 'DisplayName is missing'
            $results[6].Error | Should -Match "Manager 'not-an-email' is not a valid"
            $results[7].Outcome | Should -Be 'Created'

            Should -Invoke -CommandName New-MgUser -ModuleName Airlock -Times 2 -Exactly
        }

        It 'identifies a row with no user principal name by its line number' {
            $file = Join-Path -Path $TestDrive -ChildPath 'rownum.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role'
                'one@contoso.example,One,nolicense'
                ',Blank,nolicense'
            )

            $results = @(New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile)

            $results[1].Actions[0].Target | Should -Be 'row 3'
        }

        It 'carries on after a row fails to apply' {
            $file = Join-Path -Path $TestDrive -ChildPath 'applyfail.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role'
                'fail.first@contoso.example,First,nolicense'
                'second@contoso.example,Second,nolicense'
            )

            $results = @(New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile)

            $results[0].Outcome | Should -Be 'Failed'
            $results[1].Outcome | Should -Be 'Created'
        }

        It 'throws before any change when a required column is missing' {
            $file = Join-Path -Path $TestDrive -ChildPath 'nocolumn.csv'
            Set-Content -LiteralPath $file -Value @('UserPrincipalName,DisplayName', 'one@contoso.example,One')

            { New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile } | Should -Throw '*missing required column*'
            Assert-NoGraphWrites
        }

        It 'throws before any change when the CSV does not exist' {
            { New-AirlockUser -CsvPath (Join-Path -Path $TestDrive -ChildPath 'absent.csv') -RolesPath $script:RolesFile } | Should -Throw '*not found*'
            Assert-NoGraphWrites
        }

        It 'does not exceed the licenses available across rows' {
            $file = Join-Path -Path $TestDrive -ChildPath 'licenses.csv'
            Set-Content -LiteralPath $file -Value @(
                'UserPrincipalName,DisplayName,Role'
                (1..9 | ForEach-Object { "u$_@contoso.example,U$_,engineer" })
            )

            $results = @(New-AirlockUser -CsvPath $file -RolesPath $script:RolesFile)

            @($results | Where-Object { $_.Outcome -eq 'Created' }).Count | Should -Be 8
            $results[8].Outcome | Should -Be 'Failed'
            Should -Invoke -CommandName Set-MgUserLicense -ModuleName Airlock -Times 8 -Exactly
        }
    }
}
