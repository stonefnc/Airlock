function Invoke-AirlockStep {
    <#
    .SYNOPSIS
        Runs one change behind ShouldProcess and records the outcome in the run log.
    .DESCRIPTION
        If the caller used -WhatIf (or declined -Confirm) the script block is not run
        and the entry is recorded as WhatIf (or Skipped). If the script block throws,
        the entry is recorded as Failed and the error is not rethrown, so the caller
        can decide what to do next. Returns an object with Status and Result.
        The script block sees the caller's variables through normal PowerShell scoping.
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
        [scriptblock]$Do
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
        Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'Skipped' -Detail "Declined at the confirmation prompt. $Detail".Trim()
        return [pscustomobject]@{ Status = 'Skipped'; Result = $null }
    }

    try {
        $stepOutput = & $Do
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'Failed' -Detail $_.Exception.Message
        return [pscustomobject]@{ Status = 'Failed'; Result = $null }
    }

    Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status 'Applied' -Detail $Detail
    [pscustomobject]@{ Status = 'Applied'; Result = $stepOutput }
}
