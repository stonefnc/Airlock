function Get-AirlockStepSkipReason {
    <#
    .SYNOPSIS
        Says why an optional offboarding step must not run, or returns $null if it may.
    .DESCRIPTION
        An optional step is skipped when the operator asked for that with -SkipStep, or
        when Connect-Airlock saw that the app lacks the permission the step needs.
        If Connect-Airlock could not read the permissions at all, nothing is reported
        as missing, so the step is attempted and a refusal from Graph is recorded as
        a failure for that step only.
        Options needs SkipStep and OptionalPermissionsMissing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Options,

        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [string]$Permission,

        [Parameter(Mandatory)]
        [string]$Feature
    )

    if (@($Options.SkipStep) -contains $Step) {
        return "Skipped on request with -SkipStep $Step."
    }

    if (@($Options.OptionalPermissionsMissing) -contains $Permission) {
        return "$Permission is not granted to the app, so $Feature was skipped."
    }

    $null
}
