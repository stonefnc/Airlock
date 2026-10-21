function Get-AirlockGroupSkipReason {
    <#
    .SYNOPSIS
        Says why a group's membership or ownership cannot be changed through Graph, or returns $null.
    .DESCRIPTION
        Onboarding and offboarding use this one function so they agree. A group is
        skipped when it is:
        * a dynamic membership group, whose members are set by rule. This only applies
          to membership. Owners of a dynamic group can be changed, so with -Ownership
          this reason is not given.
        * synced from an on-premises directory, which must be changed there.
        * mail-enabled and not a Microsoft 365 group. That covers distribution lists
          and mail-enabled security groups, which are managed in Exchange.
        Microsoft 365 groups are mail-enabled too, but they carry the Unified group
        type and can be changed through Graph.
        The group needs GroupTypes, MailEnabled and OnPremisesSyncEnabled, so ask Graph
        for groupTypes, mailEnabled and onPremisesSyncEnabled when you read it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Group,

        [switch]$Ownership
    )

    $types = @($Group.GroupTypes)

    if (-not $Ownership -and $types -contains 'DynamicMembership') {
        return 'dynamic membership, managed by rule'
    }

    if ($Group.OnPremisesSyncEnabled -eq $true) {
        if ($Ownership) {
            return 'synced from on-premises, change the owner there'
        }
        return 'synced from on-premises, change the member there'
    }

    if ($Group.MailEnabled -eq $true -and $types -notcontains 'Unified') {
        if ($Ownership) {
            return 'mail-enabled distribution list or mail-enabled security group, ownership is managed in Exchange'
        }
        return 'mail-enabled distribution list or mail-enabled security group, membership is managed in Exchange'
    }

    $null
}
