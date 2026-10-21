function Add-AirlockLogEntry {
    <#
    .SYNOPSIS
        Records one change log entry on a run.
    .DESCRIPTION
        Status is one of Applied, Skipped (already in place or not changeable), WhatIf,
        Failed, Info (a check that changes nothing) or Declined (the operator said no
        at a confirmation prompt). Never pass secrets such as passwords in Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Run,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('Applied', 'Skipped', 'WhatIf', 'Failed', 'Info', 'Declined')]
        [string]$Status,

        [string]$Detail = ''
    )

    $entry = [pscustomobject]@{
        Timestamp = [datetime]::UtcNow.ToString('o')
        RunId     = $Run.RunId
        Command   = $Run.Command
        Target    = $Target
        Action    = $Action
        Status    = $Status
        Detail    = $Detail
    }

    $Run.Entries.Add($entry)
}
