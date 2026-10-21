function New-AirlockRun {
    <#
    .SYNOPSIS
        Creates the context object for one command run.
    .DESCRIPTION
        Holds the run identifier, the calling cmdlet (so steps can honour -WhatIf and
        -Confirm) and the list of change log entries recorded so far.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        $Cmdlet,

        [bool]$IsWhatIf = $false,

        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path -Path (Get-Location).Path -ChildPath 'logs'
    }

    $runId = [guid]::NewGuid().ToString()
    $startedAt = [datetime]::UtcNow
    $fileName = 'airlock-{0}-{1}-{2}.csv' -f $Command.ToLowerInvariant(), $startedAt.ToString('yyyyMMdd-HHmmss'), $runId.Substring(0, 8)

    [pscustomobject]@{
        RunId     = $runId
        Command   = $Command
        StartedAt = $startedAt
        IsWhatIf  = $IsWhatIf
        Cmdlet    = $Cmdlet
        LogPath   = Join-Path -Path $LogDirectory -ChildPath $fileName
        Entries   = [System.Collections.Generic.List[object]]::new()
    }
}
