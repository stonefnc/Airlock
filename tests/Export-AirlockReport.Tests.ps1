BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    # A fixed instant so date output can be checked exactly.
    $script:Moment = [datetime]::new(2026, 10, 1, 12, 30, 45, [System.DateTimeKind]::Utc)

    function New-Rows {
        @(
            [pscustomobject]@{ DeviceName = 'PC-1'; Platform = 'Windows'; Count = 3; Healthy = $true; LastSync = $script:Moment }
            [pscustomobject]@{ DeviceName = 'PH-2'; Platform = 'iOS'; Count = -2; Healthy = $false; LastSync = $null }
        )
    }

    function Read-Bytes {
        param([string]$Path)
        , [System.IO.File]::ReadAllBytes($Path)
    }

    # Builds the shape Get-AirlockTenantSummary returns, without needing Graph.
    function New-FixtureSummary {
        param([switch]$FailCompliance)
        [pscustomobject]@{
            PSTypeName    = 'Airlock.TenantSummary'
            GeneratedAt   = $script:Moment
            TenantId      = '22222222-2222-2222-2222-222222222222'
            StaleDays     = 30
            Overview      = @(
                [pscustomobject]@{ Section = 'Licenses'; Metric = 'SKUs'; Value = 2 }
                [pscustomobject]@{ Section = 'Licenses'; Metric = 'Available units'; Value = -2 }
            )
            LicenseUsage  = @(
                [pscustomobject]@{ PartNumber = 'ENTERPRISEPACK'; SkuId = 'sku-e3'; Total = 10; Assigned = 12; Available = -2 }
            )
            Compliance    = $(if ($FailCompliance) { @() } else { @([pscustomobject]@{ Platform = 'Windows'; DeviceCount = 4; Compliant = 3; NonCompliant = 1; InGracePeriod = 0; Unknown = 0; Other = 0 }) })
            StaleDevices  = @(
                [pscustomobject]@{ DeviceName = 'OLD-PC'; Platform = 'Windows'; Owner = 'ada.example@contoso.example'; LastSyncDateTime = $script:Moment; DaysSinceCheckIn = 45 }
            )
            SectionStatus = @(
                [pscustomobject]@{ Section = 'LicenseUsage'; Status = 'Ok'; Error = $null; Rows = 1 }
                [pscustomobject]@{ Section = 'Compliance'; Status = $(if ($FailCompliance) { 'Failed' } else { 'Ok' }); Error = $(if ($FailCompliance) { 'Authorization_RequestDenied: simulated' } else { $null }); Rows = $(if ($FailCompliance) { 0 } else { 1 }) }
                [pscustomobject]@{ Section = 'StaleDevices'; Status = 'Ok'; Error = $null; Rows = 1 }
            )
        }
    }
}

AfterAll {
    Remove-AirlockTestStubs
}

Describe 'ConvertTo-AirlockReportText' {
    It 'writes <Case> as <Expected>' -ForEach @(
        @{ Case = 'null'; Value = $null; Expected = '' }
        @{ Case = 'true'; Value = $true; Expected = 'true' }
        @{ Case = 'false'; Value = $false; Expected = 'false' }
        @{ Case = 'a negative number'; Value = -4; Expected = '-4' }
        @{ Case = 'a decimal'; Value = 3.5; Expected = '3.5' }
        @{ Case = 'a list'; Value = @(1, 2, 3); Expected = '1, 2, 3' }
        @{ Case = 'text'; Value = 'ada.example@contoso.example'; Expected = 'ada.example@contoso.example' }
    ) {
        InModuleScope Airlock -Parameters @{ Value = $Value } -ScriptBlock {
            param($Value)
            ConvertTo-AirlockReportText -Value $Value
        } | Should -Be $Expected
    }

    It 'writes a date as UTC ISO 8601, whatever the kind of the date' {
        $local = $script:Moment.ToLocalTime()

        foreach ($date in $script:Moment, $local) {
            InModuleScope Airlock -Parameters @{ Date = $date } -ScriptBlock {
                param($Date)
                ConvertTo-AirlockReportText -Value $Date
            } | Should -Be '2026-10-01T12:30:45Z'
        }
    }
}

Describe 'Export-AirlockReport' {
    BeforeEach {
        InModuleScope Airlock { $script:AirlockState = $null }
    }

    Context 'choosing the format' {
        It 'takes it from the extension <Extension>' -ForEach @(
            @{ Extension = 'csv'; Start = '"DeviceName"' }
            @{ Extension = 'html'; Start = '<!doctype html>' }
            @{ Extension = 'htm'; Start = '<!doctype html>' }
            @{ Extension = 'json'; Start = '[' }
        ) {
            $path = Join-Path -Path $TestDrive -ChildPath "format-$Extension.$Extension"

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            ([System.IO.File]::ReadAllText($path)).TrimStart().StartsWith($Start) | Should -BeTrue
        }

        It 'lets -Format override the extension' {
            $path = Join-Path -Path $TestDrive -ChildPath 'override.txt'

            New-Rows | Export-AirlockReport -Path $path -Format Json | Out-Null

            @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Count | Should -Be 2
        }

        It 'refuses an extension it does not know and says what to do' {
            { New-Rows | Export-AirlockReport -Path (Join-Path -Path $TestDrive -ChildPath 'report.txt') } |
                Should -Throw '*cannot be told from the extension*-Format*'
        }

        It 'rejects a format it does not know' {
            { New-Rows | Export-AirlockReport -Path (Join-Path -Path $TestDrive -ChildPath 'x.csv') -Format Xml } | Should -Throw
        }
    }

    Context 'CSV' {
        It 'writes a header and one row per object that Import-Csv reads back' {
            $path = Join-Path -Path $TestDrive -ChildPath 'rows.csv'

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            $rows = @(Import-Csv -LiteralPath $path)
            $rows.Count | Should -Be 2
            @($rows[0].PSObject.Properties.Name) | Should -Be @('DeviceName', 'Platform', 'Count', 'Healthy', 'LastSync')
            $rows[0].DeviceName | Should -Be 'PC-1'
            $rows[0].Count | Should -Be '3'
            $rows[0].Healthy | Should -Be 'true'
            $rows[0].LastSync | Should -Be '2026-10-01T12:30:45Z'
            $rows[1].LastSync | Should -Be ''
            $rows[1].Count | Should -Be '-2'
        }

        It 'writes UTF-8 with a byte order mark so Excel reads accents' {
            $path = Join-Path -Path $TestDrive -ChildPath 'bom.csv'
            $name = 'Zo' + [char]0x00EB + ' M' + [char]0x00FC + 'ller'

            [pscustomobject]@{ Owner = $name } | Export-AirlockReport -Path $path | Out-Null

            $bytes = Read-Bytes -Path $path
            $bytes[0] | Should -Be 0xEF
            $bytes[1] | Should -Be 0xBB
            $bytes[2] | Should -Be 0xBF
            @(Import-Csv -LiteralPath $path)[0].Owner | Should -Be $name
        }

        It 'stops a spreadsheet reading text <Value> as a formula' -ForEach @(
            @{ Value = '=HYPERLINK("http://example.invalid")' }
            @{ Value = '+1+1' }
            @{ Value = '-2+3' }
            @{ Value = '@SUM(A1)' }
        ) {
            $path = Join-Path -Path $TestDrive -ChildPath 'formula.csv'

            [pscustomobject]@{ DeviceName = $Value } | Export-AirlockReport -Path $path -Force | Out-Null

            @(Import-Csv -LiteralPath $path)[0].DeviceName | Should -Be ("'" + $Value)
        }

        It 'leaves a negative number alone, because it is a number and not text' {
            $path = Join-Path -Path $TestDrive -ChildPath 'negative.csv'

            [pscustomobject]@{ Available = -2 } | Export-AirlockReport -Path $path | Out-Null

            @(Import-Csv -LiteralPath $path)[0].Available | Should -Be '-2'
        }

        It 'round trips commas, quotes and line breaks' {
            $path = Join-Path -Path $TestDrive -ChildPath 'quoting.csv'
            $value = "Group ""A, B"" failed`nsecond line"

            [pscustomobject]@{ Detail = $value } | Export-AirlockReport -Path $path | Out-Null

            @(Import-Csv -LiteralPath $path)[0].Detail | Should -Be $value
        }

        It 'uses the union of the columns when the rows differ' {
            $path = Join-Path -Path $TestDrive -ChildPath 'union.csv'
            $rows = @([pscustomobject]@{ A = 1 }, [pscustomobject]@{ B = 2 }, [pscustomobject]@{ A = 3; C = 4 })

            $rows | Export-AirlockReport -Path $path | Out-Null

            $read = @(Import-Csv -LiteralPath $path)
            @($read[0].PSObject.Properties.Name) | Should -Be @('A', 'B', 'C')
            $read[1].A | Should -Be ''
            $read[1].B | Should -Be '2'
            $read[2].C | Should -Be '4'
        }

        It 'writes an empty file for a report with no rows' {
            $path = Join-Path -Path $TestDrive -ChildPath 'empty.csv'

            @() | Export-AirlockReport -Path $path | Out-Null

            Test-Path -LiteralPath $path | Should -BeTrue
            ([System.IO.File]::ReadAllText($path)).Trim().Length | Should -Be 0
        }
    }

    Context 'JSON' {
        It 'is always an array, even for one row' {
            $path = Join-Path -Path $TestDrive -ChildPath 'one.json'

            [pscustomobject]@{ A = 1 } | Export-AirlockReport -Path $path | Out-Null

            $text = [System.IO.File]::ReadAllText($path).TrimStart()
            $text.StartsWith('[') | Should -BeTrue
            @($text | ConvertFrom-Json).Count | Should -Be 1
        }

        It 'is an empty array for no rows' {
            $path = Join-Path -Path $TestDrive -ChildPath 'none.json'

            @() | Export-AirlockReport -Path $path | Out-Null

            ([System.IO.File]::ReadAllText($path)).Trim() | Should -Be '[]'
        }

        It 'keeps numbers and booleans as JSON types, writes null as null and dates as UTC text' {
            $path = Join-Path -Path $TestDrive -ChildPath 'types.json'

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            $text = Get-Content -LiteralPath $path -Raw
            $text | Should -Match '"Count":\s*3,'
            $text | Should -Match '"Count":\s*-2,'
            $text | Should -Not -Match '"Count":\s*"'
            $text | Should -Match '"Healthy":\s*true,'
            $text | Should -Match '"Healthy":\s*false,'
            $text | Should -Match '"LastSync":\s*null'
            $text | Should -Match '"LastSync":\s*"2026-10-01T12:30:45Z"'
            $rows = @($text | ConvertFrom-Json)
            $rows.Count | Should -Be 2
            $rows[1].LastSync | Should -BeNullOrEmpty
        }

        It 'has no byte order mark, which JSON consumers do not expect' {
            $path = Join-Path -Path $TestDrive -ChildPath 'nobom.json'

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            (Read-Bytes -Path $path)[0] | Should -Be ([byte][char]'[')
        }
    }

    Context 'HTML' {
        It 'is one complete page with the table, the title and the row count' {
            $path = Join-Path -Path $TestDrive -ChildPath 'page.html'

            New-Rows | Export-AirlockReport -Path $path -Title 'Device report' | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match '^<!doctype html>'
            $html | Should -Match '<title>Device report</title>'
            $html | Should -Match '<h1>Device report</h1>'
            $html | Should -Match '<th>DeviceName</th>'
            $html | Should -Match '<td>PC-1</td>'
            $html | Should -Match 'Rows: 2'
            $html | Should -Match '</html>\s*$'
        }

        It 'HTML encodes every value, so a hostile value cannot add markup or script' {
            $path = Join-Path -Path $TestDrive -ChildPath 'encoded.html'
            $hostile = '<script>alert(1)</script><img src=x onerror=alert(2)>"&'

            [pscustomobject]@{ DeviceName = $hostile; Owner = 'a&b' } | Export-AirlockReport -Path $path -Title '<b>t</b>' | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Not -Match '<script'
            $html | Should -Not -Match '<img'
            $html | Should -Not -Match '<b>t</b>'
            $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
            $html | Should -Match 'a&amp;b'
            $html | Should -Match '<title>&lt;b&gt;t&lt;/b&gt;</title>'
        }

        It 'carries a content security policy and loads nothing from outside' {
            $path = Join-Path -Path $TestDrive -ChildPath 'csp.html'

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match 'Content-Security-Policy'
            $html | Should -Match "default-src 'none'"
            $html | Should -Not -Match '<script|<link|src=|http://|https://'
        }

        It 'right-aligns numbers and marks negative ones' {
            $path = Join-Path -Path $TestDrive -ChildPath 'numbers.html'

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match '<td class="num">3</td>'
            $html | Should -Match '<td class="num neg">-2</td>'
        }

        It 'says there are no rows instead of drawing an empty table' {
            $path = Join-Path -Path $TestDrive -ChildPath 'norows.html'

            @() | Export-AirlockReport -Path $path | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match 'No rows\.'
            $html | Should -Not -Match '<table>'
        }
    }

    Context 'files' {
        It 'returns the file it wrote' {
            $path = Join-Path -Path $TestDrive -ChildPath 'returned.csv'

            $result = New-Rows | Export-AirlockReport -Path $path

            $result | Should -BeOfType [System.IO.FileInfo]
            $result.FullName | Should -Be $path
        }

        It 'refuses to overwrite a file and leaves it untouched' {
            $path = Join-Path -Path $TestDrive -ChildPath 'existing.csv'
            Set-Content -LiteralPath $path -Value 'keep me'

            { New-Rows | Export-AirlockReport -Path $path } | Should -Throw '*already exists*-Force*'

            (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'keep me'
        }

        It 'overwrites with -Force' {
            $path = Join-Path -Path $TestDrive -ChildPath 'forced.csv'
            Set-Content -LiteralPath $path -Value 'old'

            New-Rows | Export-AirlockReport -Path $path -Force | Out-Null

            @(Import-Csv -LiteralPath $path).Count | Should -Be 2
        }

        It 'creates missing folders' {
            $path = Join-Path -Path $TestDrive -ChildPath 'a\b\c\deep.json'

            New-Rows | Export-AirlockReport -Path $path | Out-Null

            Test-Path -LiteralPath $path | Should -BeTrue
        }

        It 'writes nothing and returns nothing under -WhatIf, and does not touch an existing file' {
            $path = Join-Path -Path $TestDrive -ChildPath 'whatif.csv'
            $missing = Join-Path -Path $TestDrive -ChildPath 'whatif-new\out.csv'
            Set-Content -LiteralPath $path -Value 'keep me'

            $first = New-Rows | Export-AirlockReport -Path $missing -WhatIf
            $second = New-Rows | Export-AirlockReport -Path $path -Force -WhatIf

            $first | Should -BeNullOrEmpty
            $second | Should -BeNullOrEmpty
            Test-Path -LiteralPath $missing | Should -BeFalse
            Test-Path -LiteralPath (Split-Path -Parent $missing) | Should -BeFalse
            (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'keep me'
        }

        It 'reports a folder given as the path' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'a-folder.csv'
            New-Item -ItemType Directory -Path $folder | Out-Null

            { New-Rows | Export-AirlockReport -Path $folder } | Should -Throw '*is a folder*'
        }

        It 'resolves a relative path against the current location' {
            Push-Location -LiteralPath $TestDrive
            try {
                New-Rows | Export-AirlockReport -Path './relative.csv' | Out-Null
            }
            finally {
                Pop-Location
            }

            Test-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'relative.csv') | Should -BeTrue
        }

        It 'gives the same result from the pipeline and from -InputObject' {
            $viaPipeline = Join-Path -Path $TestDrive -ChildPath 'pipeline.csv'
            $viaParameter = Join-Path -Path $TestDrive -ChildPath 'parameter.csv'
            $rows = New-Rows

            $rows | Export-AirlockReport -Path $viaPipeline | Out-Null
            Export-AirlockReport -InputObject $rows -Path $viaParameter | Out-Null

            (Get-Content -LiteralPath $viaPipeline -Raw) | Should -Be (Get-Content -LiteralPath $viaParameter -Raw)
        }

        It 'needs no connection and calls no Graph command' {
            Mock -ModuleName Airlock Get-MgUser -MockWith { }
            Mock -ModuleName Airlock Invoke-MgGraphRequest -MockWith { }
            $path = Join-Path -Path $TestDrive -ChildPath 'offline.csv'

            { New-Rows | Export-AirlockReport -Path $path } | Should -Not -Throw

            Should -Invoke -CommandName Get-MgUser -ModuleName Airlock -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-MgGraphRequest -ModuleName Airlock -Times 0 -Exactly
        }
    }

    Context 'a tenant summary' {
        It 'is one JSON object with every table, the statuses and the date as text' {
            $path = Join-Path -Path $TestDrive -ChildPath 'summary.json'

            New-FixtureSummary | Export-AirlockReport -Path $path | Out-Null

            $text = [System.IO.File]::ReadAllText($path)
            $text.TrimStart().StartsWith('{') | Should -BeTrue
            $text | Should -Match '"GeneratedAt":\s*"2026-10-01T12:30:45Z"'
            $text | Should -Match '"StaleDays":\s*30,'
            $object = $text | ConvertFrom-Json
            $object.TenantId | Should -Be '22222222-2222-2222-2222-222222222222'
            $object.StaleDays | Should -Be 30
            @($object.LicenseUsage).Count | Should -Be 1
            $object.LicenseUsage[0].Available | Should -Be -2
            @($object.Compliance).Count | Should -Be 1
            @($object.StaleDevices).Count | Should -Be 1
            @($object.SectionStatus | Where-Object { $_.Status -eq 'Ok' }).Count | Should -Be 3
        }

        It 'is one HTML page with a section for each table' {
            $path = Join-Path -Path $TestDrive -ChildPath 'summary.html'

            New-FixtureSummary | Export-AirlockReport -Path $path | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match '<h1>Airlock tenant summary</h1>'
            foreach ($heading in 'Overview', 'License usage', 'Device compliance by platform', 'Devices not checked in for more than 30 days') {
                $html | Should -Match "<h2>$heading</h2>"
            }
            $html | Should -Match '<td>ENTERPRISEPACK</td>'
            $html | Should -Match '<td class="num neg">-2</td>'
            $html | Should -Match '22222222-2222-2222-2222-222222222222'
            $html | Should -Not -Match '<script'
        }

        It 'says in the page that a section could not be read, and shows no table for it' {
            $path = Join-Path -Path $TestDrive -ChildPath 'failed.html'

            New-FixtureSummary -FailCompliance | Export-AirlockReport -Path $path | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match 'This section could not be read: Authorization_RequestDenied: simulated'
            $html | Should -Match '<p class="failed">'
            [regex]::Matches($html, '<table>').Count | Should -Be 3
        }

        It 'is four CSV files next to the path, named for each section' {
            $path = Join-Path -Path $TestDrive -ChildPath 'out\summary.csv'

            $files = @(New-FixtureSummary | Export-AirlockReport -Path $path)

            @($files | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('summary-compliance.csv', 'summary-licenses.csv', 'summary-overview.csv', 'summary-stale-devices.csv')
            $licenses = @(Import-Csv -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'out\summary-licenses.csv'))
            $licenses[0].PartNumber | Should -Be 'ENTERPRISEPACK'
            $licenses[0].Available | Should -Be '-2'
            @(Import-Csv -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'out\summary-stale-devices.csv'))[0].LastSyncDateTime | Should -Be '2026-10-01T12:30:45Z'
        }

        It 'writes none of the four CSV files if one of them already exists' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'clash'
            New-Item -ItemType Directory -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'summary-licenses.csv') -Value 'keep me'

            { New-FixtureSummary | Export-AirlockReport -Path (Join-Path -Path $folder -ChildPath 'summary.csv') } | Should -Throw '*already exists*'

            @(Get-ChildItem -LiteralPath $folder).Count | Should -Be 1
        }

        It 'writes none of the four CSV files under -WhatIf' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'whatif-summary'

            $result = New-FixtureSummary | Export-AirlockReport -Path (Join-Path -Path $folder -ChildPath 'summary.csv') -WhatIf

            $result | Should -BeNullOrEmpty
            Test-Path -LiteralPath $folder | Should -BeFalse
        }

        It 'refuses a summary exported together with other rows' {
            { @((New-FixtureSummary), [pscustomobject]@{ A = 1 }) | Export-AirlockReport -Path (Join-Path -Path $TestDrive -ChildPath 'mixed.json') } |
                Should -Throw '*on its own*'
        }
    }

    Context 'with the real reports, against mocked Graph' {
        BeforeEach {
            Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith {
                [pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; ConsumedUnits = 12; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
                [pscustomobject]@{ SkuId = 'sku-ess'; SkuPartNumber = 'O365_BUSINESS_ESSENTIALS'; ConsumedUnits = 1; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
            }
            Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
                [pscustomobject]@{ DeviceName = 'PC-OLD'; OperatingSystem = 'Windows'; ComplianceState = 'noncompliant'; UserPrincipalName = 'ada.example@contoso.example'; LastSyncDateTime = [datetime]::UtcNow.AddDays(-60) }
                [pscustomobject]@{ DeviceName = 'PC-NEW'; OperatingSystem = 'Windows'; ComplianceState = 'compliant'; UserPrincipalName = ''; LastSyncDateTime = [datetime]::UtcNow.AddDays(-1) }
                [pscustomobject]@{ DeviceName = 'PH-1'; OperatingSystem = 'iOS'; ComplianceState = 'compliant'; UserPrincipalName = 'sam.sample@contoso.example'; LastSyncDateTime = [datetime]::UtcNow.AddDays(-2) }
            }
        }

        It 'exports the license usage report to CSV with the negative availability intact' {
            Set-AirlockTestConnection -Command 'Get-AirlockLicenseUsage'
            $path = Join-Path -Path $TestDrive -ChildPath 'licenses.csv'

            Get-AirlockLicenseUsage | Export-AirlockReport -Path $path | Out-Null

            $rows = @(Import-Csv -LiteralPath $path)
            @($rows[0].PSObject.Properties.Name) | Should -Be @('PartNumber', 'SkuId', 'Total', 'Assigned', 'Available')
            ($rows | Where-Object { $_.PartNumber -eq 'ENTERPRISEPACK' }).Available | Should -Be '-2'
        }

        It 'exports the compliance report to HTML' {
            Set-AirlockTestConnection -Command 'Get-AirlockComplianceReport'
            $path = Join-Path -Path $TestDrive -ChildPath 'compliance.html'

            Get-AirlockComplianceReport | Export-AirlockReport -Path $path -Title 'Compliance' | Out-Null

            $html = [System.IO.File]::ReadAllText($path)
            $html | Should -Match '<th>NonCompliant</th>'
            $html | Should -Match '<td>Windows</td>'
            $html | Should -Match '<td>iOS</td>'
        }

        It 'exports the stale device report to JSON, with the days as numbers' {
            Set-AirlockTestConnection -Command 'Get-AirlockStaleDevice'
            $path = Join-Path -Path $TestDrive -ChildPath 'stale.json'

            Get-AirlockStaleDevice -Days 30 | Export-AirlockReport -Path $path | Out-Null

            $text = Get-Content -LiteralPath $path -Raw
            $rows = @($text | ConvertFrom-Json)
            $rows.Count | Should -Be 1
            $rows[0].DeviceName | Should -Be 'PC-OLD'
            $rows[0].DaysSinceCheckIn | Should -BeGreaterOrEqual 59
            $text | Should -Match '"DaysSinceCheckIn":\s*\d+'
            $text | Should -Not -Match '"DaysSinceCheckIn":\s*"'
        }

        It 'exports a stale device report with no stale devices as a valid empty file' {
            Set-AirlockTestConnection -Command 'Get-AirlockStaleDevice'
            $path = Join-Path -Path $TestDrive -ChildPath 'none-stale.json'

            Get-AirlockStaleDevice -Days 365 | Export-AirlockReport -Path $path | Out-Null

            ([System.IO.File]::ReadAllText($path)).Trim() | Should -Be '[]'
        }
    }
}
