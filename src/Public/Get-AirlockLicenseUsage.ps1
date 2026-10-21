function Get-AirlockLicenseUsage {
    <#
    .SYNOPSIS
        Reports total, assigned and available license units for each SKU in the tenant.
    .DESCRIPTION
        Read only. Nothing in the tenant is changed. Returns one object per SKU with
        PartNumber, SkuId, Total, Assigned and Available, sorted by PartNumber. The
        caller formats the output. A tenant with no SKUs returns nothing.
    .EXAMPLE
        Get-AirlockLicenseUsage | Format-Table PartNumber, Total, Assigned, Available
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $null = Get-AirlockState -Command 'Get-AirlockLicenseUsage'

    Get-AirlockSkuUsage | Sort-Object -Property PartNumber | Select-Object -Property PartNumber, SkuId, Total, Assigned, Available
}
