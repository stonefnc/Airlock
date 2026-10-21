BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:AdaUpn = 'ada.example@contoso.example'
    $script:SamUpn = 'sam.sample@contoso.example'
    $script:ManagerUpn = 'grace.manager@contoso.example'

    # An in-memory tenant behind every Graph call that offboarding makes. Writes are
    # logged in Order, so tests can check what changed and in which order.
    function Initialize-E2E {
        $global:E2E = @{
            Users       = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
            Managers    = @{}
            MemberOf    = @{}
            Roles       = [System.Collections.Generic.List[object]]::new()
            Groups      = @{}
            Owners      = @{}
            Drives      = @{}
            DrivePerms  = @{}
            Order       = [System.Collections.Generic.List[string]]::new()
            RoleDefReads = 0
            Fail        = @{}
        }

        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith {
            [pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; ConsumedUnits = 2; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
        }
        Mock -ModuleName Airlock Get-MgUser -MockWith {
            $upn = $null
            if ($Filter -match "^userPrincipalName eq '(.*)'$") { $upn = $Matches[1].Replace("''", "'") }
            if ($upn -and $global:E2E.Users.ContainsKey($upn)) { $global:E2E.Users[$upn] }
        }
        Mock -ModuleName Airlock Get-MgUserManager -MockWith {
            if ($global:E2E.Managers.ContainsKey($UserId)) { $global:E2E.Managers[$UserId] } else { throw 'Request_ResourceNotFound: the manager does not exist' }
        }
        Mock -ModuleName Airlock Get-MgUserMemberOfAsGroup -MockWith {
            if ($global:E2E.MemberOf.ContainsKey($UserId)) { $global:E2E.MemberOf[$UserId] }
        }
        Mock -ModuleName Airlock Update-MgUser -MockWith {
            $global:E2E.Order.Add('block')
            $user = $global:E2E.Users.Values | Where-Object { $_.Id -eq $UserId }
            $user.AccountEnabled = $BodyParameter.accountEnabled
        }
        Mock -ModuleName Airlock Revoke-MgUserSignInSession -MockWith {
            $global:E2E.Order.Add('revoke')
            $true
        }
        Mock -ModuleName Airlock Set-MgUserLicense -MockWith {
            $global:E2E.Order.Add('license')
            $user = $global:E2E.Users.Values | Where-Object { $_.Id -eq $UserId }
            $user.AssignedLicenses = @()
            $user.LicenseAssignmentStates = @()
        }
        Mock -ModuleName Airlock Remove-MgGroupMemberByRef -MockWith {
            $global:E2E.Order.Add("member:$GroupId")
            $global:E2E.MemberOf[$DirectoryObjectId] = @($global:E2E.MemberOf[$DirectoryObjectId] | Where-Object { $_.Id -ne $GroupId })
        }

        Mock -ModuleName Airlock Get-MgRoleManagementDirectoryRoleAssignment -MockWith {
            if ($global:E2E.Fail.ContainsKey('RoleRead')) { throw 'Authorization_RequestDenied: simulated role read failure' }
            $principal = $null
            if ($Filter -match "^principalId eq '(.*)'$") { $principal = $Matches[1] }
            @($global:E2E.Roles | Where-Object { $_.PrincipalId -eq $principal })
        }
        Mock -ModuleName Airlock Remove-MgRoleManagementDirectoryRoleAssignment -MockWith {
            $global:E2E.Order.Add("role:$UnifiedRoleAssignmentId")
            if (@($global:E2E.Fail['RoleRemove']) -contains $UnifiedRoleAssignmentId) { throw 'Authorization_RequestDenied: simulated role removal failure' }
            $match = $global:E2E.Roles | Where-Object { $_.Id -eq $UnifiedRoleAssignmentId } | Select-Object -First 1
            if ($match) { [void]$global:E2E.Roles.Remove($match) }
        }
        Mock -ModuleName Airlock Get-MgRoleManagementDirectoryRoleDefinition -MockWith {
            $global:E2E.RoleDefReads++
            [pscustomobject]@{ Id = 'role-helpdesk'; DisplayName = 'Helpdesk Administrator' }
        }

        Mock -ModuleName Airlock Get-MgUserOwnedObjectAsGroup -MockWith {
            if ($global:E2E.Fail.ContainsKey('OwnedRead')) { throw 'Authorization_RequestDenied: simulated owned-objects failure' }
            foreach ($id in $global:E2E.Groups.Keys | Sort-Object) {
                if ($global:E2E.Owners[$id] -contains $UserId) { $global:E2E.Groups[$id] }
            }
        }
        Mock -ModuleName Airlock Get-MgGroupOwner -MockWith {
            foreach ($owner in $global:E2E.Owners[$GroupId]) { [pscustomobject]@{ Id = $owner } }
        }
        Mock -ModuleName Airlock New-MgGroupOwnerByRef -MockWith {
            $global:E2E.Order.Add("owner-add:$GroupId")
            $global:E2E.Owners[$GroupId].Add(($BodyParameter['@odata.id'] -split '/')[-1])
        }
        Mock -ModuleName Airlock Remove-MgGroupOwnerDirectoryObjectByRef -MockWith {
            $global:E2E.Order.Add("owner-remove:$GroupId")
            if ($global:E2E.Owners[$GroupId].Count -le 1) { throw 'Request_BadRequest: The last owner of the group cannot be removed.' }
            [void]$global:E2E.Owners[$GroupId].Remove($DirectoryObjectId)
        }

        Mock -ModuleName Airlock Get-MgUserDefaultDrive -MockWith {
            if ($global:E2E.Fail.ContainsKey('DriveLookup')) { throw 'Authorization_RequestDenied: simulated drive lookup failure' }
            if ($global:E2E.Drives.ContainsKey($UserId)) { $global:E2E.Drives[$UserId] } else { throw 'itemNotFound: The resource could not be found' }
        }
        Mock -ModuleName Airlock Get-MgDriveItemPermission -MockWith {
            foreach ($permission in $global:E2E.DrivePerms[$DriveId]) { $permission }
        }
        Mock -ModuleName Airlock Invoke-MgInviteDriveItem -MockWith {
            $global:E2E.Order.Add("drive-invite:$DriveId")
            $recipient = $BodyParameter.recipients[0].objectId
            $global:E2E.DrivePerms[$DriveId].Add([pscustomobject]@{ Id = "p-$recipient"; Roles = @('write'); GrantedToV2 = [pscustomobject]@{ User = [pscustomobject]@{ Id = $recipient } } })
            [pscustomobject]@{ Value = @() }
        }
    }

    function Add-Person {
        param([string]$Upn, [string]$Id, [switch]$WithManager)
        $global:E2E.Users[$Upn] = [pscustomobject]@{
            Id = $Id; UserPrincipalName = $Upn; AccountEnabled = $true; UsageLocation = 'US'
            AssignedLicenses = @()
            LicenseAssignmentStates = @()
        }
        if ($WithManager) {
            $global:E2E.Managers[$Id] = [pscustomobject]@{ Id = 'mgr-id'; UserPrincipalName = $script:ManagerUpn }
        }
    }

    function New-Group {
        param([string]$Id, [string]$Name)
        [pscustomobject]@{ Id = $Id; DisplayName = $Name; GroupTypes = @(); MailEnabled = $false; SecurityEnabled = $true; OnPremisesSyncEnabled = $null }
    }

    # Ada has a manager, a direct license, a membership, a role, a OneDrive, and is the
    # sole owner of one group. Every step has something to do.
    function Add-FullLeaver {
        Add-Person -Upn $script:AdaUpn -Id 'u-ada' -WithManager
        $user = $global:E2E.Users[$script:AdaUpn]
        $user.AssignedLicenses = @([pscustomobject]@{ SkuId = 'sku-e3' })
        $user.LicenseAssignmentStates = @([pscustomobject]@{ SkuId = 'sku-e3'; AssignedByGroup = $null })
        $global:E2E.MemberOf['u-ada'] = @((New-Group -Id 'g-eng' -Name 'Engineering'))
        $global:E2E.Roles.Add([pscustomobject]@{ Id = 'a1'; PrincipalId = 'u-ada'; RoleDefinitionId = 'role-helpdesk'; DirectoryScopeId = '/' })
        $global:E2E.Groups['g-own'] = New-Group -Id 'g-own' -Name 'Project Owners'
        $global:E2E.Owners['g-own'] = [System.Collections.Generic.List[string]]::new()
        $global:E2E.Owners['g-own'].Add('u-ada')
        $global:E2E.Drives['u-ada'] = [pscustomobject]@{ Id = 'drive-1' }
        $global:E2E.DrivePerms['drive-1'] = [System.Collections.Generic.List[object]]::new()
    }

    function Get-Order {
        @($global:E2E.Order)
    }

    function Get-ActionOrder {
        param($Result)
        @($Result.Actions | ForEach-Object { $_.Action } | Select-Object -Unique)
    }

    function Get-Entry {
        param($Result, [string]$Action)
        @($Result.Actions | Where-Object { $_.Action -eq $Action })
    }
}

AfterAll {
    Remove-Variable -Name E2E -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'Remove-AirlockUser optional steps, end to end' {
    BeforeEach {
        Initialize-E2E
        Set-AirlockTestConnection
    }

    Context 'a full offboarding' {
        It 'runs every step in the safe order and leaves the user offboarded' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            Get-Order | Should -Be @('block', 'revoke', 'role:a1', 'drive-invite:drive-1', 'owner-add:g-own', 'owner-remove:g-own', 'license', 'member:g-eng')
            Get-ActionOrder -Result $result | Should -Be @(
                'RecordOneDriveRecipient', 'BlockSignIn', 'RevokeSessions'
                'RemoveDirectoryRole', 'HandOverOneDrive', 'AddGroupOwner', 'RemoveGroupOwner'
                'RemoveLicense', 'RemoveGroup'
            )
            $global:E2E.Users[$script:AdaUpn].AccountEnabled | Should -BeFalse
            $global:E2E.Roles.Count | Should -Be 0
            @($global:E2E.Owners['g-own']) | Should -Be @('mgr-id')
            @($global:E2E.DrivePerms['drive-1'] | ForEach-Object { $_.GrantedToV2.User.Id }) | Should -Be @('mgr-id')
            @($global:E2E.MemberOf['u-ada']).Count | Should -Be 0
            @($result.Actions | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 0
        }

        It 'removes the roles before anything else is taken away, and hands the OneDrive over before the license goes' {
            Add-FullLeaver

            Remove-AirlockUser -UserPrincipalName $script:AdaUpn | Out-Null

            $order = @(Get-Order)
            $order.IndexOf('role:a1') | Should -BeLessThan $order.IndexOf('license')
            $order.IndexOf('drive-invite:drive-1') | Should -BeLessThan $order.IndexOf('license')
            $order.IndexOf('revoke') | Should -BeLessThan $order.IndexOf('role:a1')
            $order.IndexOf('owner-add:g-own') | Should -BeLessThan $order.IndexOf('owner-remove:g-own')
        }

        It 'records the role name in the log' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            (Get-Entry -Result $result -Action 'RemoveDirectoryRole')[0].Detail | Should -Be 'Helpdesk Administrator'
        }

        It 'writes every new action to the change log file' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $rows = @(Import-Csv -LiteralPath $result.LogPath)
            $rows.Count | Should -Be $result.Actions.Count
            foreach ($action in 'RemoveDirectoryRole', 'HandOverOneDrive', 'AddGroupOwner', 'RemoveGroupOwner') {
                @($rows | Where-Object { $_.Action -eq $action -and $_.Status -eq 'Applied' }).Count | Should -Be 1
            }
        }
    }

    Context 'WhatIf' {
        It 'changes nothing, reads each step, and plans every new change' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -WhatIf

            $result.Outcome | Should -Be 'WhatIf'
            @(Get-Order).Count | Should -Be 0
            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Get-MgUserOwnedObjectAsGroup -ModuleName Airlock -Times 1 -Exactly
            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 1 -Exactly
            foreach ($action in 'RemoveDirectoryRole', 'HandOverOneDrive', 'AddGroupOwner', 'RemoveGroupOwner') {
                (Get-Entry -Result $result -Action $action)[0].Status | Should -Be 'WhatIf'
            }
            @($result.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
            $global:E2E.Roles.Count | Should -Be 1
            @($global:E2E.Owners['g-own']) | Should -Be @('u-ada')
            $global:E2E.DrivePerms['drive-1'].Count | Should -Be 0
        }

        It 'still writes the change log with the planned steps' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -WhatIf

            $rows = @(Import-Csv -LiteralPath $result.LogPath)
            @($rows | Where-Object { $_.Status -eq 'WhatIf' -and $_.Action -eq 'HandOverOneDrive' }).Count | Should -Be 1
        }
    }

    Context 'idempotency' {
        It 'does nothing the second time and reports AlreadyOffboarded' {
            Add-FullLeaver
            $first = Remove-AirlockUser -UserPrincipalName $script:AdaUpn
            $writesAfterFirst = @(Get-Order).Count

            $second = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $first.Outcome | Should -Be 'Offboarded'
            $second.Outcome | Should -Be 'AlreadyOffboarded'
            @(Get-Order).Count | Should -Be $writesAfterFirst
            @($second.Actions | Where-Object { $_.Status -eq 'Applied' }).Count | Should -Be 0
            foreach ($action in 'RemoveDirectoryRole', 'HandOverOneDrive', 'RemoveGroupOwner') {
                (Get-Entry -Result $second -Action $action)[0].Status | Should -Be 'Skipped'
            }
        }

        It 'finishes a partial run: the failed role is removed on the second run and nothing is repeated' {
            Add-FullLeaver
            $global:E2E.Fail['RoleRemove'] = @('a1')
            $first = Remove-AirlockUser -UserPrincipalName $script:AdaUpn
            $global:E2E.Fail.Remove('RoleRemove')
            $second = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $first.Outcome | Should -Be 'Failed'
            $second.Outcome | Should -Be 'Offboarded'
            (Get-Entry -Result $second -Action 'RemoveDirectoryRole')[0].Status | Should -Be 'Applied'
            $global:E2E.Roles.Count | Should -Be 0
            @($global:E2E.DrivePerms['drive-1']).Count | Should -Be 1
            @(Get-Order | Where-Object { $_ -eq 'drive-invite:drive-1' }).Count | Should -Be 1
            @(Get-Order | Where-Object { $_ -eq 'owner-add:g-own' }).Count | Should -Be 1
        }
    }

    Context 'a failure in one step does not stop the others' {
        It 'a failed role removal still lets the OneDrive, ownership, license and membership steps run' {
            Add-FullLeaver
            $global:E2E.Fail['RoleRemove'] = @('a1')

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            (Get-Entry -Result $result -Action 'RemoveDirectoryRole')[0].Status | Should -Be 'Failed'
            Get-Order | Should -Contain 'drive-invite:drive-1'
            Get-Order | Should -Contain 'owner-remove:g-own'
            Get-Order | Should -Contain 'license'
            Get-Order | Should -Contain 'member:g-eng'
        }

        It 'a failed read of the owned groups, which app-only access may not allow, still lets the others run' {
            Add-FullLeaver
            $global:E2E.Fail['OwnedRead'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            $entry = (Get-Entry -Result $result -Action 'RemoveGroupOwner')[0]
            $entry.Status | Should -Be 'Failed'
            $entry.Detail | Should -Match 'could not be read'
            Get-Order | Should -Contain 'role:a1'
            Get-Order | Should -Contain 'drive-invite:drive-1'
            Get-Order | Should -Contain 'license'
            @($global:E2E.Owners['g-own']) | Should -Be @('u-ada')
        }

        It 'a failed OneDrive lookup still lets the others run' {
            Add-FullLeaver
            $global:E2E.Fail['DriveLookup'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            (Get-Entry -Result $result -Action 'HandOverOneDrive')[0].Status | Should -Be 'Failed'
            Get-Order | Should -Contain 'role:a1'
            Get-Order | Should -Contain 'owner-remove:g-own'
            Get-Order | Should -Contain 'license'
            Get-Order | Should -Not -Contain 'drive-invite:drive-1'
        }

        It 'a failed read of the roles still lets the others run' {
            Add-FullLeaver
            $global:E2E.Fail['RoleRead'] = $true

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Failed'
            Get-Order | Should -Contain 'drive-invite:drive-1'
            Get-Order | Should -Contain 'owner-remove:g-own'
            Get-Order | Should -Contain 'member:g-eng'
        }
    }

    Context 'nothing to do, or nobody to hand to' {
        It 'records each of the three steps as Skipped for a user with no roles, no OneDrive and no owned groups' {
            Add-Person -Upn $script:AdaUpn -Id 'u-ada' -WithManager

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            (Get-Entry -Result $result -Action 'RemoveDirectoryRole')[0].Status | Should -Be 'Skipped'
            (Get-Entry -Result $result -Action 'HandOverOneDrive')[0].Status | Should -Be 'Skipped'
            (Get-Entry -Result $result -Action 'HandOverOneDrive')[0].Detail | Should -Match 'no OneDrive'
            (Get-Entry -Result $result -Action 'RemoveGroupOwner')[0].Status | Should -Be 'Skipped'
        }

        It 'with no manager skips the handover, leaves a sole-owned group in place, and still removes the roles' {
            Add-FullLeaver
            $global:E2E.Managers.Clear()

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            (Get-Entry -Result $result -Action 'HandOverOneDrive')[0].Detail | Should -Match 'No manager is set'
            (Get-Entry -Result $result -Action 'RemoveGroupOwner')[0].Detail | Should -Match 'no manager'
            @($global:E2E.Owners['g-own']) | Should -Be @('u-ada')
            Get-Order | Should -Not -Contain 'drive-invite:drive-1'
            Get-Order | Should -Contain 'role:a1'
        }
    }

    Context '-SkipStep' {
        It 'skips <Step> on request, records why, and reads nothing for it' -ForEach @(
            @{ Step = 'DirectoryRoles'; Action = 'RemoveDirectoryRole'; Marker = 'role:a1' }
            @{ Step = 'OneDriveHandover'; Action = 'HandOverOneDrive'; Marker = 'drive-invite:drive-1' }
            @{ Step = 'GroupOwnership'; Action = 'RemoveGroupOwner'; Marker = 'owner-remove:g-own' }
        ) {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -SkipStep $Step

            $entry = (Get-Entry -Result $result -Action $Action)[0]
            $entry.Status | Should -Be 'Skipped'
            $entry.Detail | Should -Match "-SkipStep $Step"
            Get-Order | Should -Not -Contain $Marker
            $result.Outcome | Should -Be 'Offboarded'
        }

        It 'reads no role names and no roles when the role step is skipped' {
            Add-FullLeaver

            Remove-AirlockUser -UserPrincipalName $script:AdaUpn -SkipStep DirectoryRoles | Out-Null

            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleDefinition -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
        }

        It 'can skip all three at once and still does the rest' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -SkipStep DirectoryRoles, GroupOwnership, OneDriveHandover

            Get-Order | Should -Be @('block', 'revoke', 'license', 'member:g-eng')
            $result.Outcome | Should -Be 'Offboarded'
        }

        It 'rejects a step name it does not know' {
            { Remove-AirlockUser -UserPrincipalName $script:AdaUpn -SkipStep 'Everything' } | Should -Throw
        }
    }

    Context '-OwnershipAction' {
        It 'with Remove, never adds the manager and leaves a sole owner in place, saying why' {
            Add-FullLeaver

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn -OwnershipAction Remove

            Get-Order | Should -Not -Contain 'owner-add:g-own'
            @($global:E2E.Owners['g-own']) | Should -Be @('u-ada')
            (Get-Entry -Result $result -Action 'RemoveGroupOwner')[0].Detail | Should -Match '-OwnershipAction is Remove'
        }

        It 'with Remove, still removes the user where another owner remains' {
            Add-FullLeaver
            $global:E2E.Owners['g-own'].Add('u-sam')

            Remove-AirlockUser -UserPrincipalName $script:AdaUpn -OwnershipAction Remove | Out-Null

            @($global:E2E.Owners['g-own']) | Should -Be @('u-sam')
            Get-Order | Should -Not -Contain 'owner-add:g-own'
        }

        It 'rejects a value it does not know' {
            { Remove-AirlockUser -UserPrincipalName $script:AdaUpn -OwnershipAction 'Delete' } | Should -Throw
        }
    }

    Context 'optional permissions that are not granted' {
        It 'skips all three steps, names each permission, reads nothing for them, and still offboards' {
            Add-FullLeaver
            Set-AirlockTestConnection -OptionalPermissionsMissing 'RoleManagement.ReadWrite.Directory', 'Group.ReadWrite.All', 'Files.ReadWrite.All'

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            $result.Outcome | Should -Be 'Offboarded'
            (Get-Entry -Result $result -Action 'RemoveDirectoryRole')[0].Detail | Should -Match 'RoleManagement.ReadWrite.Directory is not granted'
            (Get-Entry -Result $result -Action 'RemoveGroupOwner')[0].Detail | Should -Match 'Group.ReadWrite.All is not granted'
            (Get-Entry -Result $result -Action 'HandOverOneDrive')[0].Detail | Should -Match 'Files.ReadWrite.All is not granted'
            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleDefinition -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleAssignment -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Get-MgUserOwnedObjectAsGroup -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Get-MgUserDefaultDrive -ModuleName Airlock -Times 0 -Exactly
            Get-Order | Should -Be @('block', 'revoke', 'license', 'member:g-eng')
        }

        It 'skips only the step whose permission is missing' {
            Add-FullLeaver
            Set-AirlockTestConnection -OptionalPermissionsMissing 'Group.ReadWrite.All'

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            (Get-Entry -Result $result -Action 'RemoveGroupOwner')[0].Status | Should -Be 'Skipped'
            Get-Order | Should -Contain 'role:a1'
            Get-Order | Should -Contain 'drive-invite:drive-1'
            Get-Order | Should -Not -Contain 'owner-remove:g-own'
        }

        It 'runs the steps when no optional permission is reported missing' {
            Add-FullLeaver
            Set-AirlockTestConnection -OptionalPermissionsMissing @()

            $result = Remove-AirlockUser -UserPrincipalName $script:AdaUpn

            Get-Order | Should -Contain 'role:a1'
            $result.Outcome | Should -Be 'Offboarded'
        }
    }

    Context 'several users' {
        It 'reads the role names once for the whole run and applies every step to each user' {
            Add-FullLeaver
            Add-Person -Upn $script:SamUpn -Id 'u-sam' -WithManager
            $global:E2E.Roles.Add([pscustomobject]@{ Id = 'b1'; PrincipalId = 'u-sam'; RoleDefinitionId = 'role-helpdesk'; DirectoryScopeId = '/' })

            $results = @($script:AdaUpn, $script:SamUpn | Remove-AirlockUser)

            $results.Count | Should -Be 2
            @($results | Where-Object { $_.Outcome -eq 'Offboarded' }).Count | Should -Be 2
            Should -Invoke -CommandName Get-MgRoleManagementDirectoryRoleDefinition -ModuleName Airlock -Times 1 -Exactly
            Get-Order | Should -Contain 'role:a1'
            Get-Order | Should -Contain 'role:b1'
            (Get-Entry -Result $results[1] -Action 'RemoveDirectoryRole')[0].Detail | Should -Be 'Helpdesk Administrator'
        }
    }
}
