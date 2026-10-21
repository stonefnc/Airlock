function Remove-AirlockUser {
    <#
    .SYNOPSIS
        Offboards one or more users in Microsoft Entra ID. The account is not deleted.
    .DESCRIPTION
        For each user this records the manager, blocks sign-in, revokes active sessions,
        removes directory roles, gives the manager access to the OneDrive, takes the
        user out of the groups they own, removes directly assigned licenses and removes
        group memberships, in that order.

        Three of those steps are optional because each needs a higher privilege
        application permission that you must grant on purpose:
        * Directory role removal needs RoleManagement.ReadWrite.Directory.
        * The OneDrive handover needs Files.ReadWrite.All.
        * Group ownership changes need Group.ReadWrite.All.
        Connect-Airlock warns once if any is missing, and each missing one is recorded
        as Skipped with the reason for every user. -SkipStep skips a step on request
        even when the permission is granted.

        The command is idempotent. A user who is already offboarded is reported as
        AlreadyOffboarded and nothing is changed. Revoking sessions cannot be checked,
        so it only runs when something else is still to be done for the user.

        Some memberships cannot be changed through Graph and are skipped with the
        reason recorded: dynamic membership groups, groups synced from on-premises
        directory, and mail-enabled groups that are not Microsoft 365 groups. A license
        that comes from a group is removed with the group membership and is not
        removed directly.

        Group ownership is handled apart from membership. Where the user is one of
        several owners they are removed as an owner. Where they are the only owner the
        manager is added as owner first and the user is removed after. With no manager,
        or with -OwnershipAction Remove, a sole owner is left in place, because a group
        must keep an owner.

        The OneDrive handover grants the manager write access. It does not transfer
        ownership or copy files. It is skipped if there is no manager or no OneDrive.

        Directory roles that are only eligible (Privileged Identity Management) are not
        removed, and applications or service principals the user owns are not changed.

        Returns one result object per user. A problem with one user does not stop the
        others, and a failed step does not stop the remaining steps for that user.

        Every run writes one change log CSV, also under -WhatIf. Its path is on each
        result as LogPath. The log is written even if the run is stopped part way or
        ends with an unexpected error.

        Names are collected from the pipeline first and processed once the input ends,
        so results appear together at the end and not one at a time.
    .PARAMETER UserPrincipalName
        One or more user principal names. Accepts pipeline input, including objects
        that have a UserPrincipalName property such as rows from Import-Csv.
    .PARAMETER SkipStep
        Optional steps to skip: DirectoryRoles, GroupOwnership, OneDriveHandover.
    .PARAMETER OwnershipAction
        TransferToManager (the default) adds the manager as owner only where the user is
        the sole owner. Remove never adds the manager. Either way a group is never left
        without an owner.
    .EXAMPLE
        Remove-AirlockUser -UserPrincipalName ada.example@contoso.example -WhatIf
    .EXAMPLE
        Import-Csv ./leavers.csv | Remove-AirlockUser -WhatIf
    .EXAMPLE
        Remove-AirlockUser -UserPrincipalName ada.example@contoso.example -SkipStep OneDriveHandover -OwnershipAction Remove -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [string[]]$UserPrincipalName,

        [ValidateSet('DirectoryRoles', 'GroupOwnership', 'OneDriveHandover')]
        [string[]]$SkipStep = @(),

        [ValidateSet('TransferToManager', 'Remove')]
        [string]$OwnershipAction = 'TransferToManager'
    )

    begin {
        $state = Get-AirlockState -Command 'Remove-AirlockUser'

        $run = New-AirlockRun -Command 'Remove-AirlockUser' -Cmdlet $PSCmdlet -IsWhatIf ([bool]$WhatIfPreference) -LogDirectory $state.LogDirectory
        $seen = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.List[string]]::new()

        # Names for the log only. If this fails the log shows SKU ids instead.
        $skuNames = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        try {
            foreach ($entry in (Get-AirlockSkuTable).Values) {
                $skuNames[$entry.SkuId] = $entry.PartNumber
            }
        }
        catch {
            Write-Verbose "License names could not be read: $($_.Exception.Message)"
        }

        # The three optional steps. Each is skipped, with the reason recorded for every
        # user, if the operator asked for that or the app lacks its permission.
        $options = [pscustomobject]@{
            SkipStep                   = @($SkipStep)
            OwnershipAction            = $OwnershipAction
            OptionalPermissionsMissing = @($state.OptionalPermissionsMissing)
        }

        # Role names are for the log only, so read them once, and only if the step can run.
        $roleNames = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $roleStepOff = Get-AirlockStepSkipReason -Options $options -Step 'DirectoryRoles' -Permission 'RoleManagement.ReadWrite.Directory' -Feature 'directory role removal'
        if (-not $roleStepOff) {
            $roleNames = Get-AirlockRoleNameTable
        }
    }

    process {
        # Only collect here. The work is done in end{}, inside try/finally, because the
        # change log must be written even when the run is stopped with Ctrl+C or hits
        # an unexpected terminating error. An end block that is not wrapped would be
        # skipped, and a finally block per pipeline item would write one file per user.
        foreach ($upn in $UserPrincipalName) {
            $queue.Add([string]$upn)
        }
    }

    end {
        try {
            foreach ($upn in $queue) {
                Invoke-AirlockOffboarding -Run $run -UserPrincipalName $upn -SkuNames $skuNames -Seen $seen -Options $options -RoleNames $roleNames
            }
        }
        finally {
            $null = Write-AirlockLog -Run $run
        }
    }
}
