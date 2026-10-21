function Invoke-AirlockStep {
    <#
    .SYNOPSIS
        Runs one change behind ShouldProcess and records the outcome in the run log.
    .DESCRIPTION
        If the caller used -WhatIf the script block is not run and the entry is recorded
        as WhatIf. If the caller declined a -Confirm prompt, the entry is recorded as
        Declined, which is kept apart from Skipped (already done) so a declined step is
        never mistaken for a finished one. If the script block throws, the entry is
        recorded as Failed and the error is not rethrown, so the caller can decide what
        to do next. Returns an object with Status and Result.
        The script block sees the caller's variables through normal PowerShell scoping.

        With -RetryOnReplication, an error that says the object does not exist is
        retried a few times with a growing pause. Use it only for a user that was
        created a moment ago, because a new Entra object can take several seconds to
        become visible to the calls that follow. If it still fails, the entry says so
        and tells the operator to run the command again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Run,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Action,

        [string]$Detail = '',

        [Parameter(Mandatory)]
        [scriptblock]$Do,

        [switch]$RetryOnReplication
    )

    $stepDescription = $Action
    if ($Detail) {
        $stepDescription = "$Action ($Detail)"
    }

    if (-not $Run.Cmdlet.ShouldProcess($Target, $stepDescription)) {
        if ($Run.IsWhatIf) {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'WhatIf' -Detail $Detail
            return [pscustomobject]@{ Status = 'WhatIf'; Result = $null }
        }
        Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'Declined' -Detail "Declined at the confirmation prompt. $Detail".Trim()
        return [pscustomobject]@{ Status = 'Declined'; Result = $null }
    }

    $replicationPattern = 'does not exist|do not exist|don''t exist|ResourceNotFound|NotFound|\b404\b|not found'
    $pauses = @(2, 4, 8, 16)
    $retries = 0
    $stepOutput = $null

    while ($true) {
        try {
            $stepOutput = & $Do
            break
        }
        catch {
            $stepError = $_.Exception.Message
            $looksLikeReplication = $RetryOnReplication -and ($stepError -match $replicationPattern)

            if ($looksLikeReplication -and $retries -lt $pauses.Count) {
                Start-Sleep -Seconds $pauses[$retries]
                $retries++
                continue
            }

            if ($looksLikeReplication) {
                $stepError = "$stepError The user was created a moment ago, so this may be Entra replication delay. Run the command again to finish."
            }
            Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'Failed' -Detail $stepError
            return [pscustomobject]@{ Status = 'Failed'; Result = $null }
        }
    }

    if ($retries -gt 0) {
        $Detail = "$Detail (succeeded after $retries retries)".Trim()
    }
    Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'Applied' -Detail $Detail
    [pscustomobject]@{ Status = 'Applied'; Result = $stepOutput }
}
