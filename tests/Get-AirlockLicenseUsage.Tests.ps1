BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest
}

AfterAll {
    Remove-AirlockTestStubs
}

Describe 'Get-AirlockLicenseUsage' {
    BeforeEach {
        Set-AirlockTestConnection -Command 'Get-AirlockLicenseUsage'
    }

    It 'reports total, assigned and available units per SKU, sorted by part number' {
        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith {
            [pscustomobject]@{ SkuId = 'sku-e3'; SkuPartNumber = 'ENTERPRISEPACK'; ConsumedUnits = 2; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
            [pscustomobject]@{ SkuId = 'sku-ess'; SkuPartNumber = 'O365_BUSINESS_ESSENTIALS'; ConsumedUnits = 5; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
        }

        $result = @(Get-AirlockLicenseUsage)

        $result.Count | Should -Be 2
        $result[0].PartNumber | Should -Be 'ENTERPRISEPACK'
        $result[0].Total | Should -Be 10
        $result[0].Assigned | Should -Be 2
        $result[0].Available | Should -Be 8
        $result[1].PartNumber | Should -Be 'O365_BUSINESS_ESSENTIALS'
        $result[1].Available | Should -Be 0
    }

    It 'shows a negative Available when more licenses are assigned than owned' {
        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith {
            [pscustomobject]@{ SkuId = 'sku-x'; SkuPartNumber = 'EXAMPLE_SKU'; ConsumedUnits = 7; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
        }

        (Get-AirlockLicenseUsage).Available | Should -Be -2
    }

    It 'returns nothing when the tenant has no SKUs' {
        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith { }

        @(Get-AirlockLicenseUsage).Count | Should -Be 0
    }

    It 'throws a clear message when Graph fails' {
        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith { throw 'Authorization_RequestDenied: simulated' }

        { Get-AirlockLicenseUsage } | Should -Throw '*Could not read license usage*Authorization_RequestDenied*'
    }

    It 'does not write to the tenant' {
        Mock -ModuleName Airlock Get-MgSubscribedSku -MockWith { }
        Mock -ModuleName Airlock Set-MgUserLicense -MockWith { }

        $null = Get-AirlockLicenseUsage

        Should -Invoke -ModuleName Airlock Set-MgUserLicense -Times 0
    }

    It 'requires a connection that named the command' {
        Set-AirlockTestConnection -Command 'New-AirlockUser'

        { Get-AirlockLicenseUsage } | Should -Throw '*Connect-Airlock was not run with -Command Get-AirlockLicenseUsage*'
    }
}