function Export-AirlockReport {
    <#
    .SYNOPSIS
        Writes report rows, or a tenant summary, to a CSV, HTML or JSON file.
    .DESCRIPTION
        Works with the output of Get-AirlockComplianceReport, Get-AirlockStaleDevice and
        Get-AirlockLicenseUsage. It also accepts the tenant summary shape described below,
        for a planned Get-AirlockTenantSummary that is not built yet. It writes a local
        file and makes no Graph call, so it needs no connection and no permission, and it
        does not change the tenant.

        The format is taken from the file extension (.csv, .html, .htm, .json), or from
        -Format. An existing file is not overwritten unless -Force is given. Missing
        folders are created. The files that were written are returned.

        CSV and JSON are for other tools. CSV is UTF-8 with a byte order mark so Excel
        shows accents correctly, and text that begins with =, +, - or @ gets a leading
        apostrophe so a spreadsheet does not read it as a formula. JSON is a UTF-8
        array of rows without a byte order mark, and a tenant summary is one object.
        HTML is one self-contained page with inline styles only, no scripts and no
        external resources, with every value encoded.

        A set of rows is a single table. A report with no rows gives an empty CSV, an
        empty JSON array, or a page that says there are no rows.

        A tenant summary has four tables. As HTML or JSON it is one file. As CSV it is
        four files next to the path you gave, with -overview, -licenses, -compliance
        and -stale-devices added to the name, because one CSV cannot hold four tables.
        The summary must be exported on its own.
    .PARAMETER InputObject
        The rows to export. Accepts pipeline input.
    .PARAMETER Path
        The file to write.
    .PARAMETER Format
        Csv, Html or Json. Defaults to the one that matches the file extension.
    .PARAMETER Title
        The page title for HTML. Defaults to Airlock report, or Airlock tenant summary.
    .PARAMETER Force
        Overwrite a file that already exists.
    .EXAMPLE
        Get-AirlockStaleDevice -Days 60 | Export-AirlockReport -Path ./reports/stale.csv
    .EXAMPLE
        Get-AirlockLicenseUsage | Export-AirlockReport -Path ./reports/licenses.html -Title 'License usage'
    .EXAMPLE
        Get-AirlockComplianceReport | Export-AirlockReport -Path ./reports/compliance.json -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $InputObject,

        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [ValidateSet('Csv', 'Html', 'Json')]
        [string]$Format,

        [string]$Title,

        [switch]$Force
    )

    begin {
        $items = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($element in @($InputObject)) {
            if ($null -ne $element) {
                $items.Add($element)
            }
        }
    }

    end {
        $resolvedFormat = $Format
        if (-not $PSBoundParameters.ContainsKey('Format')) {
            switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
                '.csv' { $resolvedFormat = 'Csv' }
                '.html' { $resolvedFormat = 'Html' }
                '.htm' { $resolvedFormat = 'Html' }
                '.json' { $resolvedFormat = 'Json' }
                default { throw "The format cannot be told from the extension of '$Path'. Use a .csv, .html or .json file name, or pass -Format Csv, Html or Json." }
            }
        }

        $rows = @($items)
        $summaries = @($rows | Where-Object { $_.PSObject.TypeNames -contains 'Airlock.TenantSummary' })
        if ($summaries.Count -gt 0 -and $rows.Count -gt 1) {
            throw 'A tenant summary must be exported on its own, not together with other rows.'
        }
        $summary = $null
        if ($summaries.Count -eq 1) {
            $summary = $summaries[0]
        }

        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $generatedAt = [datetime]::UtcNow
        if ($summary -and $summary.PSObject.Properties['GeneratedAt'] -and $summary.GeneratedAt -is [datetime]) {
            $generatedAt = $summary.GeneratedAt
        }

        # Work out every file and its content before writing any of them.
        $targets = [System.Collections.Generic.List[object]]::new()
        if ($summary) {
            $sections = @(Get-AirlockSummarySection -Summary $summary)
            $pageTitle = $Title
            if (-not $pageTitle) {
                $pageTitle = 'Airlock tenant summary'
            }

            switch ($resolvedFormat) {
                'Csv' {
                    $folder = [System.IO.Path]::GetDirectoryName($fullPath)
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
                    foreach ($section in $sections) {
                        $targets.Add(@{
                                Path    = [System.IO.Path]::Combine($folder, "$stem-$($section.Key).csv")
                                Content = ConvertTo-AirlockCsvText -Row @($section.Rows)
                            })
                    }
                }
                'Json' {
                    $targets.Add(@{ Path = $fullPath; Content = ConvertTo-AirlockJsonText -Summary $summary })
                }
                'Html' {
                    $meta = @("Tenant $($summary.TenantId)", "Devices are stale after $($summary.StaleDays) days")
                    $targets.Add(@{ Path = $fullPath; Content = ConvertTo-AirlockHtmlText -Title $pageTitle -GeneratedAt $generatedAt -Meta $meta -Section $sections })
                }
            }
        }
        else {
            switch ($resolvedFormat) {
                'Csv' { $content = ConvertTo-AirlockCsvText -Row $rows }
                'Json' { $content = ConvertTo-AirlockJsonText -Row $rows }
                'Html' {
                    $pageTitle = $Title
                    if (-not $pageTitle) {
                        $pageTitle = 'Airlock report'
                    }
                    $section = @{ Title = ''; Note = ''; Failed = $false; Rows = $rows }
                    $content = ConvertTo-AirlockHtmlText -Title $pageTitle -GeneratedAt $generatedAt -Meta @("Rows: $($rows.Count)") -Section @($section)
                }
            }
            $targets.Add(@{ Path = $fullPath; Content = $content })

            if ($rows.Count -eq 0) {
                Write-Information 'The report has no rows, so the file holds no data.' -InformationAction Continue
            }
        }

        foreach ($target in $targets) {
            if (Test-Path -LiteralPath $target.Path -PathType Container) {
                throw "'$($target.Path)' is a folder. Give a file name."
            }
            if ((Test-Path -LiteralPath $target.Path -PathType Leaf) -and -not $Force) {
                throw "The file already exists: $($target.Path). Use -Force to overwrite it."
            }
        }

        # UTF-8 with a byte order mark for CSV so Excel reads accents. None for the rest.
        $withMark = [System.Text.UTF8Encoding]::new($true)
        $withoutMark = [System.Text.UTF8Encoding]::new($false)

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Path, "Write $resolvedFormat report")) {
                continue
            }

            $folder = [System.IO.Path]::GetDirectoryName($target.Path)
            if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $folder -Force
            }

            $encoding = $withoutMark
            if ($resolvedFormat -eq 'Csv') {
                $encoding = $withMark
            }
            [System.IO.File]::WriteAllText($target.Path, [string]$target.Content, $encoding)

            Get-Item -LiteralPath $target.Path
        }
    }
}
