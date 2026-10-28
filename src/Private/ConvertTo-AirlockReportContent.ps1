function ConvertTo-AirlockReportText {
    <#
    .SYNOPSIS
        Turns one report value into plain text for a CSV cell or an HTML cell.
    .DESCRIPTION
        Dates are written as UTC in ISO 8601, booleans as true and false, lists as comma
        separated text, and a null as an empty string. Numbers use the invariant culture
        so a report reads the same on every machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }
        return 'false'
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return (@($Value | ForEach-Object { ConvertTo-AirlockReportText -Value $_ }) -join ', ')
    }

    [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
}

function Get-AirlockReportColumn {
    <#
    .SYNOPSIS
        Returns the column names of a set of report rows, in the order first seen.
    .DESCRIPTION
        Rows from different sources can have different properties, so the columns are
        the union of every row's properties.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Row = @()
    )

    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Row) {
        if ($null -eq $item) {
            continue
        }
        foreach ($property in $item.PSObject.Properties) {
            if (-not $seen.Contains($property.Name)) {
                $seen.Add($property.Name)
            }
        }
    }

    $seen.ToArray()
}

function ConvertTo-AirlockCsvText {
    <#
    .SYNOPSIS
        Renders report rows as CSV text.
    .DESCRIPTION
        Text that begins with =, +, - or @ is written with a leading apostrophe so a
        spreadsheet does not read it as a formula. Only values that are text are changed,
        so a negative number stays a number. No rows gives an empty string, because
        there is nothing to take the column names from.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Row = @()
    )

    $rows = @($Row | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        return ''
    }

    $columns = @(Get-AirlockReportColumn -Row $rows)
    $flat = foreach ($item in $rows) {
        $cells = [ordered]@{}
        foreach ($column in $columns) {
            $value = Get-AirlockPropertyValue -InputObject $item -Path $column
            $text = ConvertTo-AirlockReportText -Value $value
            if ($value -is [string]) {
                $text = Protect-AirlockCsvValue -Value $text
            }
            $cells[$column] = $text
        }
        [pscustomobject]$cells
    }

    (@($flat | ConvertTo-Csv -NoTypeInformation) -join "`r`n") + "`r`n"
}

function ConvertTo-AirlockPlainValue {
    <#
    .SYNOPSIS
        Turns report data into plain dictionaries, arrays and values that serialise cleanly to JSON.
    .DESCRIPTION
        Dates become UTC ISO 8601 text. Objects become ordered dictionaries. Numbers,
        booleans and text are kept as they are, so JSON numbers stay numbers.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetime]) {
        return ConvertTo-AirlockReportText -Value $Value
    }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $map[[string]$key] = ConvertTo-AirlockPlainValue -Value $Value[$key]
        }
        return $map
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value) {
            $list.Add((ConvertTo-AirlockPlainValue -Value $element))
        }
        return , $list.ToArray()
    }

    $map = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $map[$property.Name] = ConvertTo-AirlockPlainValue -Value $property.Value
    }
    $map
}

function ConvertTo-AirlockJsonText {
    <#
    .SYNOPSIS
        Renders report rows, or a summary object, as JSON text.
    .DESCRIPTION
        A set of rows is always a JSON array, even for one row or none. A summary
        object is a JSON object.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Row = @(),

        $Summary
    )

    if ($null -ne $Summary) {
        return (ConvertTo-Json -InputObject (ConvertTo-AirlockPlainValue -Value $Summary) -Depth 10) + "`n"
    }

    $plain = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Row | Where-Object { $null -ne $_ })) {
        $plain.Add((ConvertTo-AirlockPlainValue -Value $item))
    }

    # Written out here because ConvertTo-Json renders an empty array differently
    # between PowerShell versions.
    if ($plain.Count -eq 0) {
        return "[]`n"
    }

    (ConvertTo-Json -InputObject $plain.ToArray() -Depth 10) + "`n"
}

function ConvertTo-AirlockHtmlTable {
    <#
    .SYNOPSIS
        Renders report rows as an HTML table. Every value is HTML encoded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]]$Row = @()
    )

    $rows = @($Row | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        return '<p class="none">No rows.</p>'
    }

    $columns = @(Get-AirlockReportColumn -Row $rows)
    $text = @{}
    foreach ($column in $columns) {
        $text[$column] = @($rows | ForEach-Object { ConvertTo-AirlockReportText -Value (Get-AirlockPropertyValue -InputObject $_ -Path $column) })
    }

    $html = [System.Text.StringBuilder]::new()
    [void]$html.AppendLine('<table>')
    [void]$html.Append('<thead><tr>')
    foreach ($column in $columns) {
        [void]$html.Append('<th>' + [System.Net.WebUtility]::HtmlEncode($column) + '</th>')
    }
    [void]$html.AppendLine('</tr></thead>')
    [void]$html.AppendLine('<tbody>')

    for ($i = 0; $i -lt $rows.Count; $i++) {
        [void]$html.Append('<tr>')
        foreach ($column in $columns) {
            $cell = [string]$text[$column][$i]
            $class = ''
            if ($cell -match '^-?\d+(\.\d+)?$') {
                $class = ' class="num"'
                if ($cell.StartsWith('-')) {
                    $class = ' class="num neg"'
                }
            }
            [void]$html.Append("<td$class>" + [System.Net.WebUtility]::HtmlEncode($cell) + '</td>')
        }
        [void]$html.AppendLine('</tr>')
    }

    [void]$html.AppendLine('</tbody>')
    [void]$html.Append('</table>')
    $html.ToString()
}

function ConvertTo-AirlockHtmlText {
    <#
    .SYNOPSIS
        Renders one or more report sections as a single self-contained HTML page.
    .DESCRIPTION
        The page has inline styles only, no scripts and no external resources, and a
        content security policy that forbids them, because the file is meant to be
        opened from a download or attached to a ticket. A section is a hashtable with
        Title, optional Note and Rows. Every value is HTML encoded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [datetime]$GeneratedAt,

        [string[]]$Meta = @(),

        [Parameter(Mandatory)]
        [object[]]$Section
    )

    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Title)
    $stamp = ConvertTo-AirlockReportText -Value $GeneratedAt

    $html = [System.Text.StringBuilder]::new()
    [void]$html.AppendLine('<!doctype html>')
    [void]$html.AppendLine('<html lang="en">')
    [void]$html.AppendLine('<head>')
    [void]$html.AppendLine('<meta charset="utf-8">')
    [void]$html.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$html.AppendLine('<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">')
    [void]$html.AppendLine("<title>$encodedTitle</title>")
    [void]$html.AppendLine('<style>')
    [void]$html.AppendLine(':root { color-scheme: light dark; }')
    [void]$html.AppendLine('body { font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; margin: 24px; }')
    [void]$html.AppendLine('h1 { font-size: 22px; margin: 0 0 4px; }')
    [void]$html.AppendLine('h2 { font-size: 16px; margin: 28px 0 4px; }')
    [void]$html.AppendLine('.meta, .note, .none { color: #666; margin: 2px 0 8px; }')
    [void]$html.AppendLine('.failed { color: #b00020; }')
    [void]$html.AppendLine('table { border-collapse: collapse; margin: 8px 0 8px; }')
    [void]$html.AppendLine('th, td { border: 1px solid #8886; padding: 6px 10px; text-align: left; vertical-align: top; }')
    [void]$html.AppendLine('th { background: #8882; }')
    [void]$html.AppendLine('td.num { text-align: right; font-variant-numeric: tabular-nums; }')
    [void]$html.AppendLine('td.neg { color: #b00020; }')
    [void]$html.AppendLine('@media (prefers-color-scheme: dark) { .meta, .note, .none { color: #aaa; } .failed, td.neg { color: #ff8a80; } }')
    [void]$html.AppendLine('</style>')
    [void]$html.AppendLine('</head>')
    [void]$html.AppendLine('<body>')
    [void]$html.AppendLine("<h1>$encodedTitle</h1>")
    [void]$html.AppendLine('<p class="meta">Generated ' + [System.Net.WebUtility]::HtmlEncode($stamp) + '</p>')
    foreach ($line in $Meta) {
        [void]$html.AppendLine('<p class="meta">' + [System.Net.WebUtility]::HtmlEncode($line) + '</p>')
    }

    foreach ($entry in $Section) {
        $heading = [string]$entry.Title
        if ($heading) {
            [void]$html.AppendLine('<h2>' + [System.Net.WebUtility]::HtmlEncode($heading) + '</h2>')
        }
        $note = [string]$entry.Note
        if ($note) {
            $noteClass = 'note'
            if ($entry.ContainsKey('Failed') -and $entry.Failed) {
                $noteClass = 'failed'
            }
            [void]$html.AppendLine("<p class=""$noteClass"">" + [System.Net.WebUtility]::HtmlEncode($note) + '</p>')
        }
        if (-not ($entry.ContainsKey('Failed') -and $entry.Failed)) {
            [void]$html.AppendLine((ConvertTo-AirlockHtmlTable -Row @($entry.Rows)))
        }
    }

    [void]$html.AppendLine('</body>')
    [void]$html.AppendLine('</html>')
    $html.ToString()
}

function Get-AirlockSummarySection {
    <#
    .SYNOPSIS
        Splits a tenant summary into named sections for the HTML page and the CSV files.
    .DESCRIPTION
        Returns hashtables with Key (used in file names), Title, Note, Failed and Rows.
        A section that could not be read is marked Failed with the reason as its note,
        so a missing table is never mistaken for an empty one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Summary
    )

    $definitions = @(
        @{ Key = 'overview'; Title = 'Overview'; Name = $null; Rows = @($Summary.Overview) }
        @{ Key = 'licenses'; Title = 'License usage'; Name = 'LicenseUsage'; Rows = @($Summary.LicenseUsage) }
        @{ Key = 'compliance'; Title = 'Device compliance by platform'; Name = 'Compliance'; Rows = @($Summary.Compliance) }
        @{ Key = 'stale-devices'; Title = "Devices not checked in for more than $($Summary.StaleDays) days"; Name = 'StaleDevices'; Rows = @($Summary.StaleDevices) }
    )

    foreach ($definition in $definitions) {
        $failed = $false
        $note = ''
        if ($definition.Name) {
            $status = @($Summary.SectionStatus | Where-Object { $_.Section -eq $definition.Name })[0]
            if ($status -and $status.Status -ne 'Ok') {
                $failed = $true
                $note = "This section could not be read: $($status.Error)"
            }
        }

        @{
            Key    = $definition.Key
            Title  = $definition.Title
            Note   = $note
            Failed = $failed
            Rows   = $definition.Rows
        }
    }
}
