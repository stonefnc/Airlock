function Protect-AirlockCsvValue {
    <#
    .SYNOPSIS
        Stops a spreadsheet from treating a log value as a formula.
    .DESCRIPTION
        Values that start with =, +, - or @, or with a tab or carriage return, get a
        leading apostrophe. Log values include names and error text that come from the
        tenant, and the log is meant to be opened in a spreadsheet and attached to tickets.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -match '^[=+\-@\t\r]') {
        return "'" + $Value
    }

    $Value
}

function Write-AirlockLog {
    <#
    .SYNOPSIS
        Writes the change log for a run to its CSV file.
    .DESCRIPTION
        One row per log entry, columns Timestamp, RunId, Command, Target, Action,
        Status, Detail. The file is written even when the command ran with -WhatIf,
        because a preview is exactly the log you want to attach to an approval.
        If the file cannot be written a warning is issued and nothing is thrown, so a
        full disk or a locked folder never hides the results of the run.
        Returns the path of the file, or $null if it could not be written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Run
    )

    # Writing the log is not one of the changes -WhatIf is meant to prevent. Without
    # this, the caller's -WhatIf would be inherited and silently skip the file.
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'

    try {
        $directory = Split-Path -Parent $Run.LogPath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
        }

        $rows = @(foreach ($entry in $Run.Entries) {
                [pscustomobject][ordered]@{
                    Timestamp = $entry.Timestamp
                    RunId     = $entry.RunId
                    Command   = $entry.Command
                    Target    = Protect-AirlockCsvValue -Value $entry.Target
                    Action    = $entry.Action
                    Status    = $entry.Status
                    Detail    = Protect-AirlockCsvValue -Value $entry.Detail
                }
            })

        if ($rows.Count -eq 0) {
            Set-Content -LiteralPath $Run.LogPath -Value '"Timestamp","RunId","Command","Target","Action","Status","Detail"' -Encoding UTF8 -ErrorAction Stop
        }
        else {
            $rows | Export-Csv -LiteralPath $Run.LogPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "The change log could not be written to $($Run.LogPath): $($_.Exception.Message)"
        return $null
    }

    Write-Information "Change log written to $($Run.LogPath)" -InformationAction Continue
    $Run.LogPath
}
