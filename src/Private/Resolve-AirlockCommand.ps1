function Resolve-AirlockCommand {
    <#
    .SYNOPSIS
        Returns the first of several command names that exists in this session.
    .DESCRIPTION
        The Graph PowerShell SDK has renamed some commands between releases. Pass the
        documented name first and the older or alternative names after it. If none of
        them exists the error says which names were tried and how to fix it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Name
    )

    foreach ($candidate in $Name) {
        if (Get-Command -Name $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    throw ('None of these Graph commands is available: {0}. Install the Microsoft Graph PowerShell SDK version 2.0.0 or later.' -f ($Name -join ', '))
}
