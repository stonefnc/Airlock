function Get-AirlockStaleDevice {
    <#
    .SYNOPSIS
        Lists Intune managed devices that have not checked in for more than N days.
    .DESCRIPTION
        Read only. Nothing in the tenant is changed. A device is stale when its last
        sync is older than -Days days. A device that has never checked in is always
        listed, with null LastSyncDateTime and DaysSinceCheckIn. Returns DeviceName,
        Platform, Owner, LastSyncDateTime and DaysSinceCheckIn (whole days, rounded
        down), longest silent first. Owner is empty when Intune has no primary user.
        The caller formats the output.
    .PARAMETER Days
        Age in days past which a device counts as stale. Defaults to 30.
    .EXAMPLE
        Get-AirlockStaleDevice -Days 60 | Format-Table
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 3650)]
        [int]$Days = 30
    )

    $null = Get-AirlockState -Command 'Get-AirlockStaleDevice'

    $now = [datetime]::UtcNow
    $cutoff = $now.AddDays(-$Days)

    $stale = foreach ($device in @(Get-AirlockManagedDevice)) {
        if ($null -eq $device.LastSyncDateTime) {
            $age = $null
        }
        elseif ($device.LastSyncDateTime -lt $cutoff) {
            $age = [int][math]::Floor(($now - $device.LastSyncDateTime).TotalDays)
        }
        else {
            continue
        }

        [pscustomobject]@{
            DeviceName        = $device.DeviceName
            Platform          = $device.Platform
            Owner             = $device.Owner
            LastSyncDateTime  = $device.LastSyncDateTime
            DaysSinceCheckIn  = $age
        }
    }

    # Never checked in sorts first because it is the longest silent.
    @($stale) | Sort-Object -Property @{ Expression = { if ($null -eq $_.DaysSinceCheckIn) { [int]::MaxValue } else { $_.DaysSinceCheckIn } }; Descending = $true }, DeviceName
}