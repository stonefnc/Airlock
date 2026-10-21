BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    function New-FakeDevice {
        param([string]$Name, [string]$Os, [string]$State)
        [pscustomobject]@{
            DeviceName        = $Name
            OperatingSystem   = $Os
            ComplianceState   = $State
            UserPrincipalName = 'ada.example@contoso.example'
            LastSyncDateTime  = [datetime]::UtcNow
        }
    }
}

AfterAll {
    Remove-AirlockTestStubs
}

Describe 'Get-AirlockComplianceReport' {
    BeforeEach {
        Set-AirlockTestConnection -Command 'Get-AirlockComplianceReport'
    }

    It 'groups devices by platform and counts each compliance state' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'PC-01' 'Windows' 'compliant'
            New-FakeDevice 'PC-02' 'Windows' 'noncompliant'
            New-FakeDevice 'PC-03' 'Windows' 'inGracePeriod'
            New-FakeDevice 'PC-04' 'Windows' 'unknown'
            New-FakeDevice 'PH-01' 'iOS' 'compliant'
            New-FakeDevice 'PH-02' 'iOS' 'compliant'
            New-FakeDevice 'PH-03' 'Android' 'noncompliant'
            New-FakeDevice 'MB-01' 'macOS' 'conflict'
        }

        $result = @(Get-AirlockComplianceReport)

        @($result.Platform) | Should -Be @('Android', 'iOS', 'macOS', 'Windows')
        $win = $result | Where-Object Platform -eq 'Windows'
        $win.DeviceCount | Should -Be 4
        $win.Compliant | Should -Be 1
        $win.NonCompliant | Should -Be 1
        $win.InGracePeriod | Should -Be 1
        $win.Unknown | Should -Be 1
        $win.Other | Should -Be 0
        ($result | Where-Object Platform -eq 'iOS').Compliant | Should -Be 2
        ($result | Where-Object Platform -eq 'Android').NonCompliant | Should -Be 1
    }

    It 'counts states outside the four named ones as Other' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'MB-01' 'macOS' 'conflict'
            New-FakeDevice 'MB-02' 'macOS' 'error'
        }

        $mac = Get-AirlockComplianceReport
        $mac.DeviceCount | Should -Be 2
        $mac.Other | Should -Be 2
    }

    It 'reports a device with no operating system under Unknown' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith {
            New-FakeDevice 'X-01' '' 'compliant'
        }

        (Get-AirlockComplianceReport).Platform | Should -Be 'Unknown'
    }

    It 'returns nothing when there are no managed devices' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith { }

        @(Get-AirlockComplianceReport).Count | Should -Be 0
    }

    It 'throws a clear message when Graph fails' {
        Mock -ModuleName Airlock Get-MgDeviceManagementManagedDevice -MockWith { throw 'Authorization_RequestDenied: simulated' }

        { Get-AirlockComplianceReport } | Should -Throw '*Could not read managed devices*Authorization_RequestDenied*'
    }

    It 'requires a connection that named the command' {
        Set-AirlockTestConnection -Command 'New-AirlockUser'

        { Get-AirlockComplianceReport } | Should -Throw '*Connect-Airlock was not run with -Command Get-AirlockComplianceReport*'
    }
}