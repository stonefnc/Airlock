function Get-AirlockSkuTable {
    <#
    .SYNOPSIS
        Reads the tenant's license SKUs into a lookup by SKU part number.
    .DESCRIPTION
        Each entry has SkuId, PartNumber and Remaining (purchased units minus consumed
        units). Callers lower Remaining as they assign licenses so a large CSV cannot
        run past the number of licenses available.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $table = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sku in @(Get-MgSubscribedSku -All -ErrorAction Stop)) {
        $table[[string]$sku.SkuPartNumber] = [pscustomobject]@{
            SkuId      = [string]$sku.SkuId
            PartNumber = [string]$sku.SkuPartNumber
            Remaining  = [int]$sku.PrepaidUnits.Enabled - [int]$sku.ConsumedUnits
        }
    }

    $table
}
