function Get-AirlockOneDriveState {
    <#
    .SYNOPSIS
        Reports whether a user's OneDrive has been provisioned.
    .DESCRIPTION
        Returns State of Ready, Pending or Unknown. Pending means Graph says the drive
        does not exist yet, which is normal shortly after a license is assigned.
        Unknown means the check itself failed, for example for lack of permission.
        This check is best effort and never throws, so it cannot block onboarding.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )

    try {
        $drive = Get-MgUserDefaultDrive -UserId $UserId -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'itemNotFound|ResourceNotFound|NotFound|\b404\b|not found') {
            return [pscustomobject]@{ State = 'Pending'; Detail = 'OneDrive is not provisioned yet' }
        }
        return [pscustomobject]@{ State = 'Unknown'; Detail = "OneDrive check failed: $message" }
    }

    if ($null -eq $drive) {
        return [pscustomobject]@{ State = 'Pending'; Detail = 'OneDrive is not provisioned yet' }
    }

    [pscustomobject]@{ State = 'Ready'; Detail = 'OneDrive is provisioned' }
}
