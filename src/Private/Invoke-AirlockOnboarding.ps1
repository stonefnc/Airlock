function Complete-AirlockOnboarding {
    <#
    .SYNOPSIS
        Finishes a per-user result from the log entries recorded since StartIndex.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Run,

        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [int]$StartIndex
    )

    $entries = @($Run.Entries | Select-Object -Skip $StartIndex)
    $failed = @($entries | Where-Object { $_.Status -eq 'Failed' })

    $Result.Actions = $entries
    if ($failed.Count -gt 0) {
        $Result.Outcome = 'Failed'
        $Result.Error = $failed[0].Detail
    }
    elseif ($Run.IsWhatIf) {
        $Result.Outcome = 'WhatIf'
    }
    elseif ($Result.Created) {
        $Result.Outcome = 'Created'
    }
    else {
        $Result.Outcome = 'Existing'
    }

    $Result
}

function Invoke-AirlockOnboarding {
    <#
    .SYNOPSIS
        Onboards one user: validate, plan from read-only lookups, then apply.
    .DESCRIPTION
        Nothing is changed until every lookup has succeeded, so a missing group, an
        unknown manager or an unavailable license fails the user before any write.
        Each step checks the current state first, so running it again for the same
        user changes nothing and records Skipped. Returns a result object. It does not
        throw for a problem with one user, the problem is recorded in the result and in
        the run log so a CSV run can carry on with the next row.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Run,

        [Parameter(Mandatory)]
        $Spec,

        [Parameter(Mandatory)]
        $RoleMap,

        [Parameter(Mandatory)]
        [hashtable]$SkuTable,

        [Parameter(Mandatory)]
        [hashtable]$Seen
    )

    $graphRoot = 'https://graph.microsoft.com/v1.0'

    $upn = [string]$Spec.UserPrincipalName
    $target = 'unknown'
    if ($upn) {
        $target = $upn
    }
    elseif ($Spec.RowNumber) {
        $target = "row $($Spec.RowNumber)"
    }

    $startIndex = $Run.Entries.Count
    $result = [pscustomobject]@{
        UserPrincipalName = $upn
        Role              = [string]$Spec.Role
        Outcome           = 'Failed'
        Created           = $false
        OneDrive          = 'NotChecked'
        TemporaryPassword = $null
        Error             = $null
        LogPath           = $Run.LogPath
        Actions           = @()
    }

    # Validate. No Graph calls are made for a row that fails here.
    $problem = $null
    if ([string]::IsNullOrWhiteSpace($upn)) {
        $problem = 'UserPrincipalName is missing.'
    }
    elseif (-not (Test-AirlockUserPrincipalName -Value $upn)) {
        $problem = "UserPrincipalName '$upn' is not a valid user principal name."
    }
    elseif ([string]::IsNullOrWhiteSpace($Spec.DisplayName)) {
        $problem = 'DisplayName is missing.'
    }
    elseif ([string]::IsNullOrWhiteSpace($Spec.Role)) {
        $problem = 'Role is missing.'
    }
    elseif (-not $RoleMap.Roles.ContainsKey([string]$Spec.Role)) {
        $problem = "Role '$($Spec.Role)' is not defined in the roles file."
    }
    elseif ($Spec.Manager -and -not (Test-AirlockUserPrincipalName -Value $Spec.Manager)) {
        $problem = "Manager '$($Spec.Manager)' is not a valid user principal name."
    }
    elseif ($Seen.ContainsKey($upn)) {
        $problem = "UserPrincipalName '$upn' appears more than once in this run."
    }

    if ($problem) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'Validate' -Status 'Failed' -Detail $problem
        return Complete-AirlockOnboarding -Run $Run -Result $result -StartIndex $startIndex
    }
    $Seen[$upn] = $true

    $roleDef = $RoleMap.Roles[[string]$Spec.Role]

    # Plan. Read-only lookups.
    $existing = $null
    $manager = $null
    $currentManagerId = $null
    $groupPlans = @()
    $sku = $null
    $hasLicense = $false

    try {
        $existing = Find-AirlockUser -UserPrincipalName $upn

        if ($Spec.Manager) {
            $manager = Find-AirlockUser -UserPrincipalName $Spec.Manager
            if (-not $manager) {
                throw "Manager '$($Spec.Manager)' was not found."
            }
            if ($existing) {
                try {
                    $currentManager = Get-MgUserManager -UserId $existing.Id -ErrorAction Stop
                    $currentManagerId = [string]$currentManager.Id
                }
                catch {
                    $currentManagerId = $null
                }
            }
        }

        foreach ($groupName in $roleDef.Groups) {
            $escaped = $groupName.Replace("'", "''")
            $hits = @(Get-MgGroup -Filter "displayName eq '$escaped'" -Property 'id,displayName,groupTypes' -ErrorAction Stop)
            if ($hits.Count -eq 0) {
                throw "Group '$groupName' was not found."
            }
            if ($hits.Count -gt 1) {
                throw "Group '$groupName' matches more than one group, so it was not used."
            }

            $group = $hits[0]
            $isDynamic = @($group.GroupTypes) -contains 'DynamicMembership'
            $isMember = $false
            if ($existing -and -not $isDynamic) {
                $memberIds = @(Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop | ForEach-Object { [string]$_.Id })
                $isMember = $memberIds -contains [string]$existing.Id
            }

            $groupPlans += [pscustomobject]@{
                Name      = $groupName
                Id        = [string]$group.Id
                IsDynamic = $isDynamic
                IsMember  = $isMember
            }
        }

        if ($roleDef.LicenseSku) {
            if (-not $SkuTable.ContainsKey($roleDef.LicenseSku)) {
                throw "License SKU '$($roleDef.LicenseSku)' is not available in this tenant."
            }
            $sku = $SkuTable[$roleDef.LicenseSku]

            if ($existing) {
                $hasLicense = @($existing.AssignedLicenses | Where-Object { [string]$_.SkuId -eq $sku.SkuId }).Count -gt 0
            }
            if (-not $hasLicense -and $sku.Remaining -lt 1) {
                throw "No licenses are left for SKU '$($roleDef.LicenseSku)'."
            }

            $knownLocation = $RoleMap.UsageLocation
            if ($existing -and $existing.UsageLocation) {
                $knownLocation = $existing.UsageLocation
            }
            if (-not $hasLicense -and -not $knownLocation) {
                throw 'A usage location is needed to assign a license. Set defaults.usageLocation in the roles file.'
            }
        }
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'Plan' -Status 'Failed' -Detail $_.Exception.Message
        return Complete-AirlockOnboarding -Run $Run -Result $result -StartIndex $startIndex
    }

    # Apply.
    $userId = $null
    if ($existing) {
        $userId = [string]$existing.Id
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'CreateUser' -Status 'Skipped' -Detail 'User already exists'
    }
    else {
        $password = New-AirlockPassword
        $body = @{
            accountEnabled    = $true
            displayName       = $Spec.DisplayName
            userPrincipalName = $upn
            mailNickname      = ($upn.Split('@')[0] -replace '[^A-Za-z0-9._-]', '')
            passwordProfile   = @{
                forceChangePasswordNextSignIn = $true
                password                      = $password
            }
        }
        if ($Spec.GivenName) { $body['givenName'] = $Spec.GivenName }
        if ($Spec.Surname) { $body['surname'] = $Spec.Surname }
        if ($Spec.Department) { $body['department'] = $Spec.Department }
        if ($Spec.JobTitle) { $body['jobTitle'] = $Spec.JobTitle }
        if ($RoleMap.UsageLocation) { $body['usageLocation'] = $RoleMap.UsageLocation }

        $created = Invoke-AirlockStep -Run $Run -Target $target -Action 'CreateUser' -Detail "Role $($Spec.Role)" -Do {
            New-MgUser -BodyParameter $body -ErrorAction Stop
        }

        if ($created.Status -eq 'Applied') {
            if ($created.Result -and $created.Result.Id) {
                $userId = [string]$created.Result.Id
                $result.Created = $true
                $result.TemporaryPassword = ConvertTo-SecureString -String $password -AsPlainText -Force
            }
            else {
                Add-AirlockLogEntry -Run $Run -Target $target -Action 'CreateUser' -Status 'Failed' -Detail 'Graph returned no user id.'
            }
        }
        $password = $null
        $body = $null

        if ($created.Status -eq 'Failed' -or ($created.Status -eq 'Applied' -and -not $userId)) {
            return Complete-AirlockOnboarding -Run $Run -Result $result -StartIndex $startIndex
        }
    }

    if ($existing -and $sku -and -not $hasLicense -and -not $existing.UsageLocation) {
        $location = $RoleMap.UsageLocation
        $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'SetUsageLocation' -Detail $location -Do {
            Update-MgUser -UserId $userId -BodyParameter @{ usageLocation = $location } -ErrorAction Stop
        }
    }

    if ($manager) {
        if ($existing -and $currentManagerId -eq [string]$manager.Id) {
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'SetManager' -Status 'Skipped' -Detail "$($Spec.Manager): already the manager"
        }
        else {
            $managerRef = @{ '@odata.id' = "$graphRoot/users/$($manager.Id)" }
            $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'SetManager' -Detail $Spec.Manager -Do {
                Set-MgUserManagerByRef -UserId $userId -BodyParameter $managerRef -ErrorAction Stop
            }
        }
    }

    foreach ($plan in $groupPlans) {
        if ($plan.IsDynamic) {
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'AddGroup' -Status 'Skipped' -Detail "$($plan.Name): dynamic membership, managed by rule"
        }
        elseif ($plan.IsMember) {
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'AddGroup' -Status 'Skipped' -Detail "$($plan.Name): already a member"
        }
        else {
            $memberRef = @{ '@odata.id' = "$graphRoot/directoryObjects/$userId" }
            $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'AddGroup' -Detail $plan.Name -Do {
                New-MgGroupMemberByRef -GroupId $plan.Id -BodyParameter $memberRef -ErrorAction Stop
            }
        }
    }

    if ($sku) {
        if ($hasLicense) {
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'AssignLicense' -Status 'Skipped' -Detail "$($sku.PartNumber): already assigned"
        }
        else {
            $licenseBody = @{
                addLicenses    = @(@{ skuId = $sku.SkuId })
                removeLicenses = @()
            }
            $licensed = Invoke-AirlockStep -Run $Run -Target $target -Action 'AssignLicense' -Detail $sku.PartNumber -Do {
                Set-MgUserLicense -UserId $userId -BodyParameter $licenseBody -ErrorAction Stop
            }
            if ($licensed.Status -eq 'Applied' -or $licensed.Status -eq 'WhatIf') {
                $sku.Remaining--
            }
        }

        if ($userId) {
            $drive = Get-AirlockOneDriveState -UserId $userId
            $result.OneDrive = $drive.State
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'CheckOneDrive' -Status 'Info' -Detail "$($drive.State). $($drive.Detail)"
        }
        else {
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'CheckOneDrive' -Status 'Info' -Detail 'NotChecked. The user does not exist yet because this is a preview.'
        }
    }
    else {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'AssignLicense' -Status 'Skipped' -Detail 'The role does not assign a license'
    }

    Complete-AirlockOnboarding -Run $Run -Result $result -StartIndex $startIndex
}
