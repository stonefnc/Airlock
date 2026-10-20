function Find-AirlockUser {
    <#
    .SYNOPSIS
        Looks up a user by user principal name. Returns $null when there is no such user.
    .DESCRIPTION
        Uses a filter rather than a direct lookup so that a missing user is an empty
        result and not an error that has to be told apart from a real failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )

    $escaped = $UserPrincipalName.Replace("'", "''")
    $found = @(Get-MgUser -Filter "userPrincipalName eq '$escaped'" -Property 'id,userPrincipalName,assignedLicenses,usageLocation' -ErrorAction Stop)
    if ($found.Count -eq 0) {
        return $null
    }

    $found[0]
}
