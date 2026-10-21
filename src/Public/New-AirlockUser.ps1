function New-AirlockUser {
    <#
    .SYNOPSIS
        Onboards one user or a CSV of users in Microsoft Entra ID.
    .DESCRIPTION
        For each user this creates the account if it does not exist, sets the manager,
        adds the groups mapped to the user's role, assigns the license mapped to the
        role, and checks whether OneDrive has been provisioned.

        The command is idempotent. Running it again for a user that already exists
        creates nothing twice, and every step that is already in place is recorded as
        Skipped. All lookups happen before the first change, so a role, group, manager
        or license problem fails that user without changing anything.

        A new account gets a random temporary password and must change it at first
        sign-in. The password is returned once on the result as a SecureString and is
        never written to the change log.

        Returns one result object per user. Problems with one user, or one CSV row,
        are reported on its result and do not stop the other users.

        Every run writes one change log CSV, also under -WhatIf. Its path is on each
        result as LogPath.
    .PARAMETER UserPrincipalName
        Sign-in name of the new user, for example ada.example@contoso.example.
    .PARAMETER DisplayName
        Display name of the new user.
    .PARAMETER Role
        A role defined in the roles file. It decides the groups and the license.
    .PARAMETER Manager
        User principal name of the manager. The manager must already exist.
    .PARAMETER CsvPath
        Path to a CSV of users. Required columns are UserPrincipalName, DisplayName
        and Role. Optional columns are GivenName, Surname, Manager, Department and JobTitle.
    .PARAMETER RolesPath
        Path to the role map. Defaults to ./config/roles.json, then the repository
        config/roles.json.
    .EXAMPLE
        New-AirlockUser -UserPrincipalName ada.example@contoso.example -DisplayName 'Ada Example' -Role engineer -WhatIf
    .EXAMPLE
        New-AirlockUser -CsvPath ./config/users.example.csv -RolesPath ./config/roles.json
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Single')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single')]
        [string]$UserPrincipalName,

        [Parameter(Mandatory, ParameterSetName = 'Single')]
        [string]$DisplayName,

        [Parameter(Mandatory, ParameterSetName = 'Single')]
        [string]$Role,

        [Parameter(ParameterSetName = 'Single')]
        [string]$GivenName,

        [Parameter(ParameterSetName = 'Single')]
        [string]$Surname,

        [Parameter(ParameterSetName = 'Single')]
        [string]$Manager,

        [Parameter(ParameterSetName = 'Single')]
        [string]$Department,

        [Parameter(ParameterSetName = 'Single')]
        [string]$JobTitle,

        [Parameter(Mandatory, ParameterSetName = 'Csv')]
        [string]$CsvPath,

        [string]$RolesPath
    )

    $state = Get-AirlockState -Command 'New-AirlockUser'

    $roleMap = Import-AirlockRoleMap -Path $RolesPath

    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        $specs = @(Import-AirlockUserCsv -Path $CsvPath)
    }
    else {
        $specs = @([pscustomobject]@{
                RowNumber         = $null
                UserPrincipalName = $UserPrincipalName.Trim()
                DisplayName       = $DisplayName.Trim()
                Role              = $Role.Trim()
                GivenName         = "$GivenName".Trim()
                Surname           = "$Surname".Trim()
                Manager           = "$Manager".Trim()
                Department        = "$Department".Trim()
                JobTitle          = "$JobTitle".Trim()
            })
    }

    $run = New-AirlockRun -Command 'New-AirlockUser' -Cmdlet $PSCmdlet -IsWhatIf ([bool]$WhatIfPreference) -LogDirectory $state.LogDirectory
    $skuTable = Get-AirlockSkuTable
    $seen = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        foreach ($spec in $specs) {
            Invoke-AirlockOnboarding -Run $run -Spec $spec -RoleMap $roleMap -SkuTable $skuTable -Seen $seen
        }
    }
    finally {
        $null = Write-AirlockLog -Run $run
    }
}
