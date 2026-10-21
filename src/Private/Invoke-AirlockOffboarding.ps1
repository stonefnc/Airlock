function Complete-AirlockOffboarding {
    <#
    .SYNOPSIS
        Finishes a per-user offboarding result from the log entries recorded since StartIndex.
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
    $applied = @($entries | Where-Object { $_.Status -eq 'Applied' })

    $Result.Actions = $entries
    if ($failed.Count -gt 0) {
        $Result.Outcome = 'Failed'
        $Result.Error = $failed[0].Detail
    }
    elseif ($Run.IsWhatIf) {
        $Result.Outcome = 'WhatIf'
    }
    elseif ($applied.Count -gt 0) {
        $Result.Outcome = 'Offboarded'
    }
    else {
        $Result.Outcome = 'AlreadyOffboarded'
    }

    $Result
}

function Invoke-AirlockOffboarding {
    <#
    .SYNOPSIS
        Offboards one user: look up, record the manager, then apply.
    .DESCRIPTION
        Steps, in order: record the manager who receives the OneDrive, block sign-in,
        revoke sessions, remove directly assigned licenses, remove group memberships.
        Each step checks the current state first, so a second run changes nothing and
        records Skipped. Revoking sessions cannot be checked, so it runs only when
        something else is still to be done for the user. A failed step is recorded and
        the remaining steps still run, because a half offboarded account is the worse
        outcome. The account is not deleted.
        Returns a result object and does not throw for a problem with one user.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Run,

        [AllowEmptyString()]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [hashtable]$SkuNames,

        [Parameter(Mandatory)]
        [hashtable]$Seen
    )

    $upn = $UserPrincipalName.Trim()
    $target = 'unknown'
    if ($upn) {
        $target = $upn
    }

    $startIndex = $Run.Entries.Count
    $result = [pscustomobject]@{
        UserPrincipalName = $upn
        Outcome           = 'Failed'
        OneDriveRecipient = $null
        Error             = $null
        Actions           = @()
    }

    $problem = $null
    if ([string]::IsNullOrWhiteSpace($upn)) {
        $problem = 'UserPrincipalName is missing.'
    }
    elseif (-not (Test-AirlockUserPrincipalName -Value $upn)) {
        $problem = "UserPrincipalName '$upn' is not a valid user principal name."
    }
    elseif ($Seen.ContainsKey($upn)) {
        $problem = "UserPrincipalName '$upn' appears more than once in this run."
    }

    if ($problem) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'Validate' -Status 'Failed' -Detail $problem
        return Complete-AirlockOffboarding -Run $Run -Result $result -StartIndex $startIndex
    }
    $Seen[$upn] = $true

    # Look up. Read-only.
    $user = $null
    $manager = $null
    $memberships = @()
    $directSkus = @()
    $inheritedSkus = @()

    try {
        $user = Find-AirlockUser -UserPrincipalName $upn
        if (-not $user) {
            throw "User '$upn' was not found."
        }

        $manager = Get-AirlockManagerInfo -UserId ([string]$user.Id)

        $groups = @(Get-MgUserMemberOfAsGroup -UserId $user.Id -All -Property 'id,displayName,groupTypes,mailEnabled,securityEnabled,onPremisesSyncEnabled' -ErrorAction Stop)
        foreach ($group in $groups) {
            $types = @($group.GroupTypes)
            $reason = $null
            if ($types -contains 'DynamicMembership') {
                $reason = 'dynamic membership, managed by rule'
            }
            elseif ($group.OnPremisesSyncEnabled -eq $true) {
                $reason = 'synced from on-premises, remove the member there'
            }
            elseif ($group.MailEnabled -eq $true -and $group.SecurityEnabled -ne $true -and $types -notcontains 'Unified') {
                $reason = 'mail-enabled distribution list, remove the member in Exchange'
            }

            $name = [string]$group.DisplayName
            if (-not $name) {
                $name = [string]$group.Id
            }
            $memberships += [pscustomobject]@{
                Name   = $name
                Id     = [string]$group.Id
                Reason = $reason
            }
        }

        $states = @()
        if ($user.PSObject.Properties['LicenseAssignmentStates'] -and $user.LicenseAssignmentStates) {
            $states = @($user.LicenseAssignmentStates)
        }
        foreach ($license in @($user.AssignedLicenses)) {
            $skuId = [string]$license.SkuId
            $skuLabel = $skuId
            if ($SkuNames.ContainsKey($skuId)) {
                $skuLabel = $SkuNames[$skuId]
            }

            $rows = @($states | Where-Object { [string]$_.SkuId -eq $skuId })
            $directRows = @($rows | Where-Object { -not $_.AssignedByGroup })
            if ($rows.Count -eq 0 -or $directRows.Count -gt 0) {
                $directSkus += [pscustomobject]@{ SkuId = $skuId; Label = $skuLabel }
            }
            else {
                $inheritedSkus += [pscustomobject]@{ SkuId = $skuId; Label = $skuLabel }
            }
        }
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'Plan' -Status 'Failed' -Detail $_.Exception.Message
        return Complete-AirlockOffboarding -Run $Run -Result $result -StartIndex $startIndex
    }

    $userId = [string]$user.Id

    # Record who receives the OneDrive. The handover itself is a manual step.
    if ($manager.Found) {
        $recipient = $manager.UserPrincipalName
        if (-not $recipient) {
            $recipient = $manager.Id
        }
        $result.OneDriveRecipient = $recipient
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RecordOneDriveRecipient' -Status 'Info' -Detail "$recipient. The manager receives the OneDrive content. Hand it over manually."
    }
    elseif ($manager.Error) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RecordOneDriveRecipient' -Status 'Info' -Detail "The manager could not be read: $($manager.Error)"
    }
    else {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RecordOneDriveRecipient' -Status 'Info' -Detail 'No manager is set. Choose who receives the OneDrive content.'
    }

    $removable = @($memberships | Where-Object { -not $_.Reason })
    $isBlocked = $user.AccountEnabled -eq $false
    $needsRevoke = (-not $isBlocked) -or ($directSkus.Count -gt 0) -or ($removable.Count -gt 0)

    # Block sign-in.
    if ($isBlocked) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'BlockSignIn' -Status 'Skipped' -Detail 'Sign-in is already blocked'
    }
    else {
        $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'BlockSignIn' -Do {
            Update-MgUser -UserId $userId -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
        }
    }

    # Revoke sessions.
    if ($needsRevoke) {
        $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'RevokeSessions' -Do {
            Revoke-MgUserSignInSession -UserId $userId -ErrorAction Stop
        }
    }
    else {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RevokeSessions' -Status 'Skipped' -Detail 'Nothing left to offboard, so sessions were not revoked again'
    }

    # Remove licenses that were assigned directly.
    if ($directSkus.Count -gt 0) {
        $licenseBody = @{
            addLicenses    = @()
            removeLicenses = @($directSkus | ForEach-Object { $_.SkuId })
        }
        $labels = ($directSkus | ForEach-Object { $_.Label }) -join ', '
        $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'RemoveLicense' -Detail $labels -Do {
            Set-MgUserLicense -UserId $userId -BodyParameter $licenseBody -ErrorAction Stop
        }
    }
    elseif ($inheritedSkus.Count -eq 0) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RemoveLicense' -Status 'Skipped' -Detail 'No licenses are assigned'
    }
    foreach ($inherited in $inheritedSkus) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RemoveLicense' -Status 'Skipped' -Detail "$($inherited.Label): assigned through a group, it is removed with the group membership"
    }

    # Remove group memberships.
    if ($memberships.Count -eq 0) {
        Add-AirlockLogEntry -Run $Run -Target $target -Action 'RemoveGroup' -Status 'Skipped' -Detail 'Not a member of any group'
    }
    foreach ($membership in $memberships) {
        if ($membership.Reason) {
            Add-AirlockLogEntry -Run $Run -Target $target -Action 'RemoveGroup' -Status 'Skipped' -Detail "$($membership.Name): $($membership.Reason)"
        }
        else {
            $null = Invoke-AirlockStep -Run $Run -Target $target -Action 'RemoveGroup' -Detail $membership.Name -Do {
                Remove-MgGroupMemberByRef -GroupId $membership.Id -DirectoryObjectId $userId -ErrorAction Stop
            }
        }
    }

    Complete-AirlockOffboarding -Run $Run -Result $result -StartIndex $startIndex
}
