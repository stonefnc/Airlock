function Get-AirlockComplianceReport {
    <#
    .SYNOPSIS
        Reports Intune device compliance grouped by platform.
    .DESCRIPTION
        Read only. Nothing in the tenant is changed. Returns one object per platform
        with DeviceCount, Compliant, NonCompliant, InGracePeriod, Unknown and Other,
        sorted by Platform. Other counts the remaining Intune states such as
        conflict, error and configManager, so the counts add up to DeviceCount.
        A tenant with no managed devices returns nothing. The caller formats the output.
    .EXAMPLE
        Get-AirlockComplianceReport | Format-Table
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $null = Get-AirlockState -Command 'Get-AirlockComplianceReport'

    $devices = @(Get-AirlockManagedDevice)
    foreach ($group in ($devices | Group-Object -Property Platform | Sort-Object -Property Name)) {
        $count = { param($state) @($group.Group | Where-Object { $_.ComplianceState -eq $state }).Count }
        $compliant = & $count 'compliant'
        $nonCompliant = & $count 'noncompliant'
        $grace = & $count 'inGracePeriod'
        $unknown = & $count 'unknown'

        [pscustomobject]@{
            Platform      = $group.Name
            DeviceCount   = $group.Count
            Compliant     = $compliant
            NonCompliant  = $nonCompliant
            InGracePeriod = $grace
            Unknown       = $unknown
            Other         = $group.Count - $compliant - $nonCompliant - $grace - $unknown
        }
    }
}