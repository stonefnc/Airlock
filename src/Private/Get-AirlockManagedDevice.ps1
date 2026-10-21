function Get-AirlockManagedDevice {
    <#
    .SYNOPSIS
        Reads Intune managed devices from Microsoft Graph.
    .DESCRIPTION
        Returns one object per device with DeviceName, Platform, ComplianceState,
        Owner and LastSyncDateTime. Platform comes from the operatingSystem property
        and is Unknown when Graph leaves it empty. LastSyncDateTime is null for a
        device that has never checked in. Read only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    try {
        $devices = @(Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop)
    }
    catch {
        throw "Could not read managed devices from Microsoft Graph: $($_.Exception.Message)"
    }

    foreach ($device in $devices) {
        $platform = [string]$device.OperatingSystem
        if ([string]::IsNullOrWhiteSpace($platform)) {
            $platform = 'Unknown'
        }

        # Intune reports a device that never checked in as the minimum date.
        $lastSync = $null
        if ($device.LastSyncDateTime -and ([datetime]$device.LastSyncDateTime).Year -gt 1) {
            $lastSync = ([datetime]$device.LastSyncDateTime).ToUniversalTime()
        }

        [pscustomobject]@{
            DeviceName       = [string]$device.DeviceName
            Platform         = $platform
            ComplianceState  = [string]$device.ComplianceState
            Owner            = [string]$device.UserPrincipalName
            LastSyncDateTime = $lastSync
        }
    }
}