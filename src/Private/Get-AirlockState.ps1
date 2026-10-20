function Get-AirlockState {
    <#
    .SYNOPSIS
        Returns the current connection details or throws if Connect-Airlock has not run.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:AirlockState) {
        throw 'Not connected. Run Connect-Airlock first.'
    }

    $script:AirlockState
}
