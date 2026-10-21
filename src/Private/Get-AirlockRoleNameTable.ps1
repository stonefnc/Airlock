function Get-AirlockRoleNameTable {
    <#
    .SYNOPSIS
        Reads Entra directory role names into a lookup by role definition id.
    .DESCRIPTION
        The names are for the change log only. If the read fails the table is empty
        and the log shows role definition ids instead, so this never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $table = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        foreach ($definition in @(Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction Stop)) {
            $table[[string]$definition.Id] = [string]$definition.DisplayName
        }
    }
    catch {
        Write-Verbose "Role names could not be read: $($_.Exception.Message)"
    }

    $table
}
