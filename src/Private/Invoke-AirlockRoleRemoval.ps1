function Invoke-AirlockRoleRemoval {
    <#
    .SYNOPSIS
        Offboarding step: removes the user's active Entra directory role assignments.
    .DESCRIPTION
        This is the highest privilege thing Airlock does, so it is optional. It needs the
        RoleManagement.ReadWrite.Directory application permission and is skipped, with
        the reason recorded, if that is not granted or if the operator passed
        -SkipStep DirectoryRoles.

        The assignments are read when the step runs. A failed read is recorded as a
        failure of this step only. Each assignment is then removed on its own through
        Invoke-AirlockStep, so -WhatIf shows exactly which roles would go and one failed
        removal does not stop the others. A user who holds no roles, including one
        whose roles were already removed by an earlier run, is recorded as Skipped.

        Only active assignments are covered. Eligible (PIM) assignments are not read or
        removed. Blocking sign-in already stops the account using them.
    .PARAMETER UserId
        The object id of the leaver.
    .PARAMETER RoleNames
        Role definition id to display name, for the log. Optional.
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
        $Options,

        [hashtable]$RoleNames = @{}
    )

    $why = Get-AirlockStepSkipReason -Options $Options -Step 'DirectoryRoles' -Permission 'RoleManagement.ReadWrite.Directory' -Feature 'directory role removal'
    if ($why) {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveDirectoryRole' -Status 'Skipped' -Detail $why
        return
    }

    try {
        $assignments = @(Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$UserId'" -All -ErrorAction Stop)
    }
    catch {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveDirectoryRole' -Status 'Failed' -Detail "The directory role assignments could not be read, so none were removed: $($_.Exception.Message)"
        return
    }

    if ($assignments.Count -eq 0) {
        Add-AirlockLogEntry -Run $Run -Target $Target -Action 'RemoveDirectoryRole' -Status 'Skipped' -Detail 'Holds no active directory role assignments. Eligible (PIM) assignments are not checked.'
        return
    }

    foreach ($assignment in $assignments) {
        $roleId = [string]$assignment.RoleDefinitionId
        $label = $roleId
        if ($RoleNames.ContainsKey($roleId)) {
            $label = $RoleNames[$roleId]
        }
        if ($assignment.DirectoryScopeId -and $assignment.DirectoryScopeId -ne '/') {
            $label = "$label (scope $($assignment.DirectoryScopeId))"
        }

        $assignmentId = [string]$assignment.Id
        $null = Invoke-AirlockStep -Run $Run -Target $Target -Action 'RemoveDirectoryRole' -Detail $label -Do {
            Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId $assignmentId -ErrorAction Stop
        }
    }
}
