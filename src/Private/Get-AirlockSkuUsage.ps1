function Get-AirlockSkuUsage {
    <#
    .SYNOPSIS
        Reads each license SKU's purchased and consumed units from Microsoft Graph.
    .DESCRIPTION
        Returns one object per SKU with SkuId, PartNumber, Total, Assigned and
        Available. Total is the enabled prepaid units and Assigned is the consumed
        units. Available is Total minus Assigned and goes negative if a tenant has
        assigned more licenses than it owns. Read only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    try {
        $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    }
    catch {
        throw "Could not read license usage from Microsoft Graph: $($_.Exception.Message)"
    }

    foreach ($sku in $skus) {
        $total = [int]$sku.PrepaidUnits.Enabled
        $assigned = [int]$sku.ConsumedUnits
        [pscustomobject]@{
            SkuId      = [string]$sku.SkuId
            PartNumber = [string]$sku.SkuPartNumber
            Total      = $total
            Assigned   = $assigned
            Available  = $total - $assigned
        }
    }
}
