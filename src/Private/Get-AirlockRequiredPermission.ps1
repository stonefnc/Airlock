function Get-AirlockRequiredPermission {
    <#
    .SYNOPSIS
        Returns the Microsoft Graph application permissions each Airlock command needs.
    .DESCRIPTION
        This table is the source for the connection check in Connect-Airlock and for
        docs/permissions.md. Keep the two in step.
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
            'Files.Read.All'
        )
        'Remove-AirlockUser' = @(
            'User.ReadWrite.All'
            'User.RevokeSessions.All'
            'Directory.Read.All'
            'GroupMember.ReadWrite.All'
            'LicenseAssignment.ReadWrite.All'
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
