BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    # A run object without a real cmdlet. The log writer never calls ShouldProcess.
    function New-TestRun {
        param([string]$Directory, [string]$Command = 'New-AirlockUser', [bool]$IsWhatIf = $false)
        InModuleScope Airlock -Parameters @{ Directory = $Directory; Command = $Command; IsWhatIf = $IsWhatIf } -ScriptBlock {
            param($Directory, $Command, $IsWhatIf)
            New-AirlockRun -Command $Command -Cmdlet ([pscustomobject]@{}) -IsWhatIf $IsWhatIf -LogDirectory $Directory
        }
    }

    function Add-TestEntry {
        param($Run, [string]$Target = 'ada.example@contoso.example', [string]$Action = 'AddGroup', [string]$Status = 'Applied', [string]$Detail = 'Engineering')
        InModuleScope Airlock -Parameters @{ Run = $Run; Target = $Target; Action = $Action; Status = $Status; Detail = $Detail } -ScriptBlock {
            param($Run, $Target, $Action, $Status, $Detail)
            Add-AirlockLogEntry -Run $Run -Target $Target -Action $Action -Status $Status -Detail $Detail
        }
    }

    function Write-TestLog {
        param($Run)
        InModuleScope Airlock -Parameters @{ Run = $Run } -ScriptBlock {
            param($Run)
            Write-AirlockLog -Run $Run
        }
    }
}

AfterAll {
    Remove-AirlockTestStubs
}

Describe 'New-AirlockRun' {
    It 'builds a unique, descriptive log path inside the log directory' {
        $dir = Join-Path -Path $TestDrive -ChildPath 'paths'

        $first = New-TestRun -Directory $dir -Command 'Remove-AirlockUser'
        $second = New-TestRun -Directory $dir -Command 'Remove-AirlockUser'

        (Split-Path -Parent $first.LogPath) | Should -Be $dir
        (Split-Path -Leaf $first.LogPath) | Should -Match '^airlock-remove-airlockuser-\d{8}-\d{6}-[0-9a-f]{8}\.csv$'
        $second.LogPath | Should -Not -Be $first.LogPath
        (Split-Path -Leaf $first.LogPath) | Should -Match $first.RunId.Substring(0, 8)
    }

    It 'defaults to a logs folder under the current directory' {
        $run = New-TestRun -Directory ''

        (Split-Path -Leaf (Split-Path -Parent $run.LogPath)) | Should -Be 'logs'
    }
}

Describe 'Write-AirlockLog' {
    It 'writes one row per entry with the documented columns, in order' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'rows')
        Add-TestEntry -Run $run -Action 'CreateUser' -Status 'Applied' -Detail 'Role engineer'
        Add-TestEntry -Run $run -Action 'AddGroup' -Status 'Skipped' -Detail 'Engineering: already a member'

        $path = Write-TestLog -Run $run

        $path | Should -Be $run.LogPath
        Test-Path -LiteralPath $path | Should -BeTrue
        $header = (Get-Content -LiteralPath $path -TotalCount 1)
        $header | Should -Be '"Timestamp","RunId","Command","Target","Action","Status","Detail"'

        $rows = @(Import-Csv -LiteralPath $path)
        $rows.Count | Should -Be 2
        $rows[0].Action | Should -Be 'CreateUser'
        $rows[1].Status | Should -Be 'Skipped'
        $rows[1].Detail | Should -Be 'Engineering: already a member'
        @($rows | Select-Object -ExpandProperty RunId -Unique).Count | Should -Be 1
        $rows[0].RunId | Should -Be $run.RunId
        $rows[0].Command | Should -Be 'New-AirlockUser'
        [datetime]::Parse($rows[0].Timestamp) | Should -BeOfType [datetime]
    }

    It 'creates the log folder when it does not exist' {
        $dir = Join-Path -Path $TestDrive -ChildPath 'a\b\c'
        $run = New-TestRun -Directory $dir
        Add-TestEntry -Run $run

        Write-TestLog -Run $run | Out-Null

        Test-Path -LiteralPath $run.LogPath | Should -BeTrue
    }

    It 'writes a header only file when there are no entries' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'empty')

        Write-TestLog -Run $run | Out-Null

        @(Get-Content -LiteralPath $run.LogPath).Count | Should -Be 1
        @(Import-Csv -LiteralPath $run.LogPath).Count | Should -Be 0
    }

    It 'writes UTF-8 with a byte order mark so Excel reads non-ASCII names' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'bom')
        $name = 'Zo' + [char]0x00EB + ' M' + [char]0x00FC + 'ller ' + [char]0x00D8 + 'stergaard'
        Add-TestEntry -Run $run -Target 'zoe.muller@contoso.example' -Detail $name

        Write-TestLog -Run $run | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($run.LogPath)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
        @(Import-Csv -LiteralPath $run.LogPath)[0].Detail | Should -Be $name
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Match ([regex]::Escape($name))
    }

    It 'writes the byte order mark on a header only file too' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'bomempty')

        Write-TestLog -Run $run | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($run.LogPath)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'round trips commas, quotes and line breaks in a value' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'quoting')
        $detail = "Group ""A, B"" failed`nsecond line"
        Add-TestEntry -Run $run -Status 'Failed' -Detail $detail

        Write-TestLog -Run $run | Out-Null

        @(Import-Csv -LiteralPath $run.LogPath)[0].Detail | Should -Be $detail
    }

    It 'stops a spreadsheet reading a value as a formula' -ForEach @(
        @{ Value = '=HYPERLINK("http://example.invalid")' }
        @{ Value = '+1+1' }
        @{ Value = '-2+3' }
        @{ Value = '@SUM(A1)' }
    ) {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'formula')
        Add-TestEntry -Run $run -Target $Value -Detail $Value

        Write-TestLog -Run $run | Out-Null

        $row = @(Import-Csv -LiteralPath $run.LogPath)[0]
        $row.Target | Should -Be ("'" + $Value)
        $row.Detail | Should -Be ("'" + $Value)
    }

    It 'leaves ordinary values alone' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'plain')
        Add-TestEntry -Run $run -Target 'ada.example@contoso.example' -Detail 'Dynamic Team: dynamic membership, managed by rule'

        Write-TestLog -Run $run | Out-Null

        $row = @(Import-Csv -LiteralPath $run.LogPath)[0]
        $row.Target | Should -Be 'ada.example@contoso.example'
        $row.Detail | Should -Be 'Dynamic Team: dynamic membership, managed by rule'
    }

    It 'still writes the file when the caller is running with -WhatIf' {
        $run = New-TestRun -Directory (Join-Path -Path $TestDrive -ChildPath 'whatif') -IsWhatIf $true
        Add-TestEntry -Run $run -Status 'WhatIf'

        $path = InModuleScope Airlock -Parameters @{ Run = $run } -ScriptBlock {
            param($Run)
            $WhatIfPreference = $true
            Write-AirlockLog -Run $Run
        }

        $path | Should -Be $run.LogPath
        Test-Path -LiteralPath $run.LogPath | Should -BeTrue
        @(Import-Csv -LiteralPath $run.LogPath)[0].Status | Should -Be 'WhatIf'
    }

    It 'warns and returns nothing, instead of throwing, when the folder cannot be used' {
        $blocker = Join-Path -Path $TestDrive -ChildPath 'blocker'
        Set-Content -LiteralPath $blocker -Value 'this is a file, not a folder'
        $run = New-TestRun -Directory (Join-Path -Path $blocker -ChildPath 'logs')
        Add-TestEntry -Run $run

        $outcome = InModuleScope Airlock -Parameters @{ Run = $run } -ScriptBlock {
            param($Run)
            $path = Write-AirlockLog -Run $Run -WarningVariable logWarning -WarningAction SilentlyContinue
            [pscustomobject]@{ Path = $path; Warning = ($logWarning -join ' ') }
        }

        $outcome.Path | Should -BeNullOrEmpty
        $outcome.Warning | Should -Match 'could not be written'
        Test-Path -LiteralPath $run.LogPath | Should -BeFalse
    }
}
