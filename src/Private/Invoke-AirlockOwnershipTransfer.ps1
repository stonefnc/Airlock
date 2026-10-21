function Invoke-AirlockOwnershipTransfer {
    <#
    .SYNOPSIS
        Offboarding step: takes the leaver out of the groups they own, without leaving a group ownerless.
    .DESCRIPTION
        This is separate from removing the leaver as a member (RemoveGroup). It is
        optional because it needs the Group.ReadWrite.All application permission. It is
        skipped, with the reason recorded, if that is not granted or if the operator
        passed -SkipStep GroupOwnership.

        For each group the leaver owns, the default (-OwnershipAction TransferToManager)
        is the safe one:
        * If another owner remains, the leaver is removed as an owner and nobody new is
          given ownership.
        * If the leaver is the only owner and the manager is known, the manager is added
          as an owner first (AddGroupOwner) and only then is the leaver removed
          (RemoveGroupOwner). If adding the manager fails, the leaver is left in place.
        * If the leaver is the only owner and there is no manager, ownership is left in
          place and the reason is recorded. Graph does not allow the last owner to be
          removed, and an ownerless group is worse than a disabled owner.
        With -OwnershipAction Remove the manager is never added. Groups with another
        owner are handled the same way, and a sole owner is left in place.

        Groups whose owners cannot be changed through Graph (synced from on-premises,
        mail-enabled distribution lists and mail-enabled security groups) are skipped with
        the reason, using the same rule as membership. Dynamic groups are not skipped,
        because dynamic membership does not affect owners.

        The owned groups are read when the step runs. A failed read is recorded as a
        failure of this step only. Each change goes through Invoke-AirlockStep, so
        -WhatIf shows the plan and one failed group does not stop the others.
        Only groups are covered. Applications and service principals the leaver owns are not.
    .PARAMETER UserId
        The object id of the leaver.
    .PARAMETER Manager
        The result of Get-AirlockManagerInfo for the leaver.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Run,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$UserId,

        [Parameter(Mandatory)]
        $Manager,

        [Parameter(Mandatory)]
        $Options
    )

    $why = Get-AirlockStepSkipReason -Options $Options -Step 'GroupOwnership' -Permission 'Group.ReadWrite.All' -Feature 'group ownership changes'
    if ($why) {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Skipped' -Detail $why
        return
    }

    try {
        $owned = @(Get-MgUserOwnedObjectAsGroup -UserId $UserId -All -Property 'id,displayName,groupTypes,mailEnabled,securityEnabled,onPremisesSyncEnabled' -ErrorAction Stop)
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Failed' -Detail "The groups this user owns could not be read, so no ownership was changed: $($_.Exception.Message)"
        return
    }

    if ($owned.Count -eq 0) {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Skipped' -Detail 'Does not own any group. Applications and service principals the user owns are not checked.'
        return
    }

    try {
        $removeCommand = Resolve-AirlockCommand -Name 'Remove-MgGroupOwnerDirectoryObjectByRef', 'Remove-MgGroupOwnerByRef'
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Failed' -Detail $_.Exception.Message
        return
    }

    $managerKnown = [bool]$Manager.Found
    $managerLabel = [string]$Manager.UserPrincipalName
    if (-not $managerLabel) {
        $managerLabel = [string]$Manager.Id
    }
    $canTransfer = $managerKnown -and $Options.OwnershipAction -eq 'TransferToManager'

    foreach ($group in $owned) {
        $name = [string]$group.DisplayName
        if (-not $name) {
            $name = [string]$group.Id
        }
        $groupId = [string]$group.Id

        $reason = Get-AirlockGroupSkipReason -Group $group -Ownership
        if ($reason) {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Skipped' -Detail "${name}: $reason"
            continue
        }

        try {
            $ownerIds = @(Get-MgGroupOwner -GroupId $groupId -All -ErrorAction Stop | ForEach-Object { [string]$_.Id })
        }
        catch {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Failed' -Detail "${name}: the owners could not be read, so this group was left alone: $($_.Exception.Message)"
            continue
        }

        $others = @($ownerIds | Where-Object { $_ -ne $UserId })

        if ($others.Count -eq 0) {
            if (-not $canTransfer) {
                if ($Options.OwnershipAction -eq 'TransferToManager') {
                    $because = 'there is no manager to hand it to'
                }
                else {
                    $because = '-OwnershipAction is Remove, which never adds an owner'
                }
                Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Skipped' -Detail "${name}: the user is the only owner and $because, so ownership was left in place. A group must keep an owner."
                continue
            }

            $managerRef = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($Manager.Id)" }
            $added = Invoke-AirlockStep -Run $Run -Target $Target -Action 'AddGroupOwner' -Detail "${name}: $managerLabel becomes the owner" -Do {
                New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter $managerRef -ErrorAction Stop
            }
            if ($added.Status -ne 'Applied' -and $added.Status -ne 'WhatIf') {
                Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Status 'Skipped' -Detail "${name}: not removed, because the manager was not added and a group must keep an owner."
                continue
            }
        }

        $null = Invoke-AirlockStep -Run $Run -Target $Target -Action 'RemoveGroupOwner' -Detail $name -Do {
            & $removeCommand -GroupId $groupId -DirectoryObjectId $UserId -ErrorAction Stop
        }
    }
}
