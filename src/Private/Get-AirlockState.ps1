function Get-AirlockState {
    <#
    .SYNOPSIS
        Returns the current connection details or throws if Connect-Airlock has not run.
    .DESCRIPTION
        With -Command, also throws if that command was not named in Connect-Airlock,
        because the permissions for it would not have been checked.
    #>
    [CmdletBinding()]
    param(
        [string]$Command
    )

    if ($null -eq $script:AirlockState) {
        throw 'Not connected. Run Connect-Airlock first.'
    }

    if ($Command -and $script:AirlockState.Commands -notcontains $Command) {
        throw "Connect-Airlock was not run with -Command $Command. Run it again to check the permissions this command needs."
    }

    $script:AirlockState
}
