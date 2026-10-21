BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    function New-FakeDevice {
        param([string]$Name, [datetime]$LastSync, [string]$Os = 'Windows', [string]$Owner = 'ada.example@contoso.example')
        [pscustomobject]@{
            DeviceName        = $Name
            OperatingSystem   = $Os
            ComplianceState   = 'compliant'
            UserPrincipalName = $Owner
            LastSyncDateTime  = $LastSync
        }
    }
}

AfterAll {
    Remove-AirlockTestStubs
}

Describe 'Get-AirlockStaleDevice' {
    BeforeEach {
        Set-AirlockTestConnection -Command 'Get-AirlockStaleDevice'
    }

    It 'uses 30 days by default and applies the boundary' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'JUST-INSIDE' ([datetime]::UtcNow.AddDays(-30).AddMinutes(5))
            New-FakeDevice 'JUST-PAST' ([datetime]::UtcNow.AddDays(-30).AddMinutes(-5))
            New-FakeDevice 'FRESH' ([datetime]::UtcNow.AddDays(-1))
        }

        $result = @(Get-AirlockStaleDevice)

        $result.Count | Should -Be 1
        $result[0].DeviceName | Should -Be 'JUST-PAST'
        $result[0].DaysSinceCheckIn | Should -Be 30
    }

    It 'honours the Days parameter' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'PC-10' ([datetime]::UtcNow.AddDays(-10))
            New-FakeDevice 'PC-40' ([datetime]::UtcNow.AddDays(-40))
        }

        @(Get-AirlockStaleDevice -Days 7).Count | Should -Be 2
        @(Get-AirlockStaleDevice -Days 20).Count | Should -Be 1
        @(Get-AirlockStaleDevice -Days 90).Count | Should -Be 0
    }

    It 'returns device, platform, owner and days, longest silent first' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'PC-A' ([datetime]::UtcNow.AddDays(-45)) -Os 'Windows' -Owner 'ada.example@contoso.example'
            New-FakeDevice 'PH-B' ([datetime]::UtcNow.AddDays(-90)) -Os 'iOS' -Owner ''
        }

        $result = @(Get-AirlockStaleDevice)

        @($result.DeviceName) | Should -Be @('PH-B', 'PC-A')
        $result[0].Platform | Should -Be 'iOS'
        $result[0].Owner | Should -Be ''
        $result[0].DaysSinceCheckIn | Should -Be 90
        $result[1].Owner | Should -Be 'ada.example@contoso.example'
    }

    It 'lists a device that never checked in, first, with null days' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'OLD' ([datetime]::UtcNow.AddDays(-100))
            New-FakeDevice 'NEVER' ([datetime]::MinValue)
        }

        $result = @(Get-AirlockStaleDevice)

        $result.Count | Should -Be 2
        $result[0].DeviceName | Should -Be 'NEVER'
        $result[0].DaysSinceCheckIn | Should -BeNullOrEmpty
        $result[0].LastSyncDateTime | Should -BeNullOrEmpty
    }

    It 'returns nothing when there are no managed devices' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith { }

        @(Get-AirlockStaleDevice).Count | Should -Be 0
    }

    It 'rejects a Days value below 1' {
        { Get-AirlockStaleDevice -Days 0 } | Should -Throw
    }

    It 'throws a clear message when Graph fails' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith { throw 'Authorization_RequestDenied: simulated' }

        { Get-AirlockStaleDevice } | Should -Throw '*Could not read managed devices*Authorization_RequestDenied*'
    }

    It 'requires a connection that named the command' {
        Set-AirlockTestConnection -Command 'New-AirlockUser'

        { Get-AirlockStaleDevice } | Should -Throw '*Connect-Airlock was not run with -Command Get-AirlockStaleDevice*'
    }
}