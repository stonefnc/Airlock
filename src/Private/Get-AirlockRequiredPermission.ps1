function Get-AirlockRequiredPermission {
    <#
    .SYNOPSIS
        Returns the Microsoft Graph application permissions each Airlock command needs.
    .DESCRIPTION
        This table is the source for the connection check in Connect-Airlock and for
        docs/permissions.md. Keep the two in step. Permissions that a command can do
        without are listed by Get-AirlockOptionalPermission instead.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Command
    )

    $table = @{
        'New-AirlockUser'    = @(
            'User.ReadWrite.All'
            'Group.Read.All'
            'GroupMember.ReadWrite.All'
            'LicenseAssignment.Read.All'
            'LicenseAssignment.ReadWrite.All'
        )
        'Remove-AirlockUser' = @(
            'User.ReadWrite.All'
            'User.RevokeSessions.All'
            'Directory.Read.All'
            'GroupMember.ReadWrite.All'
            'LicenseAssignment.ReadWrite.All'
        )
        'Get-AirlockLicenseUsage' = @(
            'LicenseAssignment.Read.All'
        )
        'Get-AirlockComplianceReport' = @(
            'DeviceManagementManagedDevices.Read.All'
        )
        'Get-AirlockStaleDevice' = @(
            'DeviceManagementManagedDevices.Read.All'
        )
    }

    $result = foreach ($name in $Command) {
        if (-not $table.ContainsKey($name)) {
            throw "Unknown Airlock command '$name'."
        }
        $table[$name]
    }

    @($result | Sort-Object -Unique)
}

function Get-AirlockOptionalPermission {
    <#
    .SYNOPSIS
        Returns the permissions a command can do without, and what is lost without them.
    .DESCRIPTION
        A missing optional permission never stops Connect-Airlock. It produces one
        warning, and the command skips the feature that needs it.
        The offboarding permissions here are all higher privilege than the rest and
        are optional on purpose: directory role removal, group ownership changes and
        the OneDrive handover only happen if the app registration was given the
        permission, so granting it is an explicit decision.
        Files.Read.All is optional because Microsoft documents the OneDrive lookup as
        not supported for application permissions, so a tenant must still be able to
        onboard users without it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Command
    )

    $table = @{
        'New-AirlockUser'    = @(
            [pscustomobject]@{ Permission = 'Files.Read.All'; WithoutIt = 'New-AirlockUser skips the OneDrive check and reports it as NotChecked' }
        )
        'Remove-AirlockUser' = @(
            [pscustomobject]@{ Permission = 'RoleManagement.ReadWrite.Directory'; WithoutIt = 'Remove-AirlockUser does not remove directory roles' }
            [pscustomobject]@{ Permission = 'Group.ReadWrite.All'; WithoutIt = 'Remove-AirlockUser does not transfer or remove group ownership' }
            [pscustomobject]@{ Permission = 'Files.ReadWrite.All'; WithoutIt = 'Remove-AirlockUser does not hand the OneDrive to the manager' }
        )
        'Get-AirlockLicenseUsage' = @()
        'Get-AirlockComplianceReport' = @()
        'Get-AirlockStaleDevice' = @()
    }

    $result = foreach ($name in $Command) {
        if (-not $table.ContainsKey($name)) {
            throw "Unknown Airlock command '$name'."
        }
        $table[$name]
    }

    @($result | Sort-Object -Property Permission -Unique)
}
