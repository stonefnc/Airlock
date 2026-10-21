function Get-AirlockManagerInfo {
    <#
    .SYNOPSIS
        Reads a user's manager. Never throws.
    .DESCRIPTION
        Returns an object with Found, Id, UserPrincipalName and Error. A user with no
        manager is Found = $false with no Error. A failed read is Found = $false with
        the message in Error, so the caller can say so without stopping.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )

    $none = [pscustomobject]@{ Found = $false; Id = $null; UserPrincipalName = $null; Error = $null }

    try {
        $manager = Get-MgUserManager -UserId $UserId -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'ResourceNotFound|NotFound|\b404\b|not found|does not exist') {
            return $none
        }
        $none.Error = $message
        return $none
    }

    if ($null -eq $manager) {
        return $none
    }

    $upn = $null
    if ($manager.PSObject.Properties['UserPrincipalName'] -and $manager.UserPrincipalName) {
        $upn = [string]$manager.UserPrincipalName
    }
    elseif ($manager.PSObject.Properties['AdditionalProperties'] -and $manager.AdditionalProperties -and $manager.AdditionalProperties.ContainsKey('userPrincipalName')) {
        $upn = [string]$manager.AdditionalProperties['userPrincipalName']
    }

    [pscustomobject]@{
        Found             = $true
        Id                = [string]$manager.Id
        UserPrincipalName = $upn
        Error             = $null
    }
}
