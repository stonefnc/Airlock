function Test-AirlockUserPrincipalName {
    <#
    .SYNOPSIS
        Returns $true if the text looks like a user principal name.
    .DESCRIPTION
        This is a shape check before any value is used in a Graph filter, not a
        guarantee that the user exists. An apostrophe is allowed and is escaped by
        the callers that build filters.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $Value -match '^[A-Za-z0-9._%+!#^~''-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
}
