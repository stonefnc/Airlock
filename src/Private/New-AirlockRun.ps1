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

        [bool]$IsWhatIf = $false
    )

    [pscustomobject]@{
        RunId     = [guid]::NewGuid().ToString()
        Command   = $Command
        StartedAt = [datetime]::UtcNow
        IsWhatIf  = $IsWhatIf
        Cmdlet    = $Cmdlet
        Entries   = [System.Collections.Generic.List[object]]::new()
    }
}
