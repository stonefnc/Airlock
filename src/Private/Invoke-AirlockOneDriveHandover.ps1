function Get-AirlockPropertyValue {
    <#
    .SYNOPSIS
        Reads a nested property, returning $null if any part of the path is missing.
    .DESCRIPTION
        Graph objects differ in which properties they carry, and this module runs in
        strict mode, so a plain dotted path would throw on a missing one.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string[]]$Path
    )

    $current = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $current) {
            return $null
        }
        $property = $current.PSObject.Properties[$name]
        if ($null -eq $property) {
            return $null
        }
        $current = $property.Value
    }

    $current
}

function Test-AirlockDriveAccess {
    <#
    .SYNOPSIS
        Says whether a drive permission already gives a user write access.
    .DESCRIPTION
        A permission counts if it carries the write or owner role and names the user,
        directly or through a list of identities. Read-only access does not count.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $Permission,

        [Parameter(Mandatory)]
        [string]$UserId
    )

    $roles = @(Get-AirlockPropertyValue -InputObject $Permission -Path 'Roles')
    if ($roles -notcontains 'write' -and $roles -notcontains 'owner') {
        return $false
    }

    foreach ($path in @(@('GrantedToV2', 'User', 'Id'), @('GrantedTo', 'User', 'Id'))) {
        if ([string](Get-AirlockPropertyValue -InputObject $Permission -Path $path) -eq $UserId) {
            return $true
        }
    }

    foreach ($identity in @(Get-AirlockPropertyValue -InputObject $Permission -Path 'GrantedToIdentitiesV2')) {
        if ([string](Get-AirlockPropertyValue -InputObject $identity -Path @('User', 'Id')) -eq $UserId) {
            return $true
        }
    }

    $false
}

function Invoke-AirlockOneDriveHandover {
    <#
    .SYNOPSIS
        Offboarding step: gives the leaver's manager write access to the leaver's OneDrive.
    .DESCRIPTION
        This is a handover of access, not a transfer of ownership, and not a copy of the
        files: Graph has no call that transfers ownership of a OneDrive. The manager is
        invited with the write role on the root folder of the leaver's drive, which
        the rest of the OneDrive inherits. The invitation is granted directly and no
        email is sent.

        The step is optional because it needs the Files.ReadWrite.All application
        permission, which is write access to files across the tenant. It is skipped,
        with the reason recorded, if that is not granted or if the operator passed
        -SkipStep OneDriveHandover.

        It is also skipped, with the reason, when the leaver has no manager, when the
        manager could not be read, or when the leaver has no OneDrive. It runs before the
        licenses are removed, because removing a license is what starts the clock on a
        OneDrive being cleaned up.

        Idempotent: the current access on the root folder is read first, and a manager who
        already has write or owner access is recorded as Skipped. Any other failed read
        is recorded as a failure of this step only, and nothing is shared when the
        current access could not be checked. The invitation goes through
        Invoke-AirlockStep, so -WhatIf reads but does not share and a declined prompt
        is recorded as Declined.
    .PARAMETER UserId
        The object id of the leaver.
    .PARAMETER Manager
        The result of Get-AirlockManagerInfo for the leaver.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Run,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$UserId,

        [Parameter(Mandatory)]
        $Manager,

        [Parameter(Mandatory)]
        $Options
    )

    $why = Get-AirlockStepSkipReason -Options $Options -Step 'OneDriveHandover' -Permission 'Files.ReadWrite.All' -Feature 'the OneDrive handover'
    if ($why) {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Skipped' -Detail $why
        return
    }

    if (-not $Manager.Found) {
        if ($Manager.Error) {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Skipped' -Detail "The manager could not be read, so the OneDrive was not shared: $($Manager.Error)"
        }
        else {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Skipped' -Detail 'No manager is set, so there is nobody to hand the OneDrive to.'
        }
        return
    }

    $managerLabel = [string]$Manager.UserPrincipalName
    if (-not $managerLabel) {
        $managerLabel = [string]$Manager.Id
    }
    $managerId = [string]$Manager.Id

    try {
        $drive = Get-MgUserDefaultDrive -UserId $UserId -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'itemNotFound|ResourceNotFound|NotFound|404|not found') {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Skipped' -Detail 'The user has no OneDrive, so there is nothing to hand over.'
        }
        else {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Failed' -Detail "The OneDrive could not be looked up, so it was not shared: $message"
        }
        return
    }

    if ($null -eq $drive -or -not $drive.Id) {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Skipped' -Detail 'The user has no OneDrive, so there is nothing to hand over.'
        return
    }
    $driveId = [string]$drive.Id

    try {
        $permissions = @(Get-MgDriveItemPermission -DriveId $driveId -DriveItemId 'root' -All -ErrorAction Stop)
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Failed' -Detail "The current access to the OneDrive could not be read, so it was not shared: $($_.Exception.Message)"
        return
    }

    foreach ($permission in $permissions) {
        if (Test-AirlockDriveAccess -Permission $permission -UserId $managerId) {
            Add-AirlockLogEntry -Run $Run -Target $Target -Action 'HandOverOneDrive' -Status 'Skipped' -Detail "$managerLabel already has write access to the OneDrive."
            return
        }
    }

    $body = @{
        recipients     = @(@{ objectId = $managerId })
        roles          = @('write')
        requireSignIn  = $true
        sendInvitation = $false
    }

    $null = Invoke-AirlockStep -Run $Run -Target $Target -Action 'HandOverOneDrive' -Detail "$managerLabel gets write access to the OneDrive" -Do {
        $response = Invoke-MgInviteDriveItem -DriveId $driveId -DriveItemId 'root' -BodyParameter $body -ErrorAction Stop

        # A partial success comes back as a normal response with an error on the recipient.
        $granted = @($response)
        $value = Get-AirlockPropertyValue -InputObject $response -Path 'Value'
        if ($null -ne $value) {
            $granted = @($value)
        }
        foreach ($item in $granted) {
            $problem = Get-AirlockPropertyValue -InputObject $item -Path 'Error'
            if ($problem) {
                $problemText = [string](Get-AirlockPropertyValue -InputObject $problem -Path 'Message')
                throw "The invitation was not accepted for the manager: $problemText"
            }
        }
    }
}
