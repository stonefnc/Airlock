function Remove-AirlockUser {
    <#
    .SYNOPSIS
        Offboards one or more users in Microsoft Entra ID. The account is not deleted.
    .DESCRIPTION
        For each user this records the manager who receives the OneDrive content,
        blocks sign-in, revokes active sessions, removes directly assigned licenses
        and removes group memberships.

        The command is idempotent. A user who is already offboarded is reported as
        AlreadyOffboarded and nothing is changed. Revoking sessions cannot be checked,
        so it only runs when something else is still to be done for the user.

        Some memberships cannot be changed through Graph and are skipped with the
        reason recorded: dynamic membership groups, groups synced from on-premises
        directory, and mail-enabled distribution lists. A license that comes from a
        group is removed with the group membership and is not removed directly.

        The OneDrive handover is not done by this command. The manager is recorded in
        the change log and on the result as OneDriveRecipient so it can be completed
        from the ticket.

        Returns one result object per user. A problem with one user does not stop the
        others, and a failed step does not stop the remaining steps for that user.

        Every run writes one change log CSV, also under -WhatIf. Its path is on each
        result as LogPath.
    .PARAMETER UserPrincipalName
        One or more user principal names. Accepts pipeline input, including objects
        that have a UserPrincipalName property such as rows from Import-Csv.
    .EXAMPLE
        Remove-AirlockUser -UserPrincipalName ada.example@contoso.example -WhatIf
    .EXAMPLE
        Import-Csv ./leavers.csv | Remove-AirlockUser -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [string[]]$UserPrincipalName
    )

    begin {
        $state = Get-AirlockState -Command 'Remove-AirlockUser'

        $run = New-AirlockRun -Command 'Remove-AirlockUser' -Cmdlet $PSCmdlet -IsWhatIf ([bool]$WhatIfPreference) -LogDirectory $state.LogDirectory
        $seen = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

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
    }

    process {
        foreach ($upn in $UserPrincipalName) {
            Invoke-AirlockOffboarding -Run $run -UserPrincipalName $upn -SkuNames $skuNames -Seen $seen
        }
    }

    end {
        $null = Write-AirlockLog -Run $run
    }
}
