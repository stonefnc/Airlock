function Import-AirlockUserCsv {
    <#
    .SYNOPSIS
        Reads a user CSV into normalised user specifications.
    .DESCRIPTION
        Throws when the file is missing, has no rows, or lacks a required column
        (UserPrincipalName, DisplayName, Role). Header names are matched without
        regard to case. Values are trimmed. Individual bad rows are not rejected
        here, they are reported per row when each user is processed.
        RowNumber is the line number in the file, counting the header as line 1.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CSV file not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw "CSV file has no data rows: $Path"
    }

    $headers = @($rows[0].PSObject.Properties.Name)
    $required = @('UserPrincipalName', 'DisplayName', 'Role')
    $missing = @($required | Where-Object { $_ -notin $headers })
    if ($missing.Count -gt 0) {
        throw ('CSV file is missing required column(s): {0}' -f ($missing -join ', '))
    }

    $known = @('UserPrincipalName', 'DisplayName', 'Role', 'GivenName', 'Surname', 'Manager', 'Department', 'JobTitle')
    $columns = @{}
    foreach ($name in $known) {
        $columns[$name] = $headers | Where-Object { $_ -eq $name } | Select-Object -First 1
    }

    $number = 1
    foreach ($row in $rows) {
        $number++
        $spec = [ordered]@{ RowNumber = $number }
        foreach ($name in $known) {
            $value = ''
            if ($columns[$name]) {
                $raw = $row.($columns[$name])
                if ($null -ne $raw) {
                    $value = ([string]$raw).Trim()
                }
            }
            $spec[$name] = $value
        }
        [pscustomobject]$spec
    }
}
