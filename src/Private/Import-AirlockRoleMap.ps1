function Import-AirlockRoleMap {
    <#
    .SYNOPSIS
        Loads and validates the role-to-group map.
    .DESCRIPTION
        With no -Path, ./config/roles.json and then the repository config/roles.json
        are tried. Returns an object with UsageLocation and a case-insensitive Roles
        table. Each role has Name, Groups (display names) and LicenseSku (SKU part
        number, or empty when the role assigns no license).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $candidates = @(
            (Join-Path -Path (Get-Location).Path -ChildPath 'config/roles.json'),
            (Join-Path -Path $moduleRoot -ChildPath 'config/roles.json')
        )
        $Path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $Path) {
            throw 'No roles file found. Copy config/roles.example.json to config/roles.json or pass -RolesPath.'
        }
    }
    elseif (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Roles file not found: $Path"
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Roles file is not valid JSON: $Path"
    }

    if ($null -eq $json -or -not $json.PSObject.Properties['roles'] -or $null -eq $json.roles) {
        throw "Roles file has no 'roles' section: $Path"
    }

    $usageLocation = $null
    if ($json.PSObject.Properties['defaults'] -and $null -ne $json.defaults -and $json.defaults.PSObject.Properties['usageLocation']) {
        $usageLocation = [string]$json.defaults.usageLocation
        if ($usageLocation -notmatch '^[A-Za-z]{2}$') {
            throw "defaults.usageLocation must be a two letter country code: $Path"
        }
        $usageLocation = $usageLocation.ToUpperInvariant()
    }

    $roles = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $json.roles.PSObject.Properties) {
        $definition = $property.Value

        $groups = @()
        if ($null -ne $definition -and $definition.PSObject.Properties['groups']) {
            $groups = @($definition.groups)
        }
        foreach ($group in $groups) {
            if ($group -isnot [string] -or [string]::IsNullOrWhiteSpace($group)) {
                throw "Role '$($property.Name)' has a group that is not a name: $Path"
            }
        }

        $sku = ''
        if ($null -ne $definition -and $definition.PSObject.Properties['licenseSku'] -and $null -ne $definition.licenseSku) {
            $sku = [string]$definition.licenseSku
        }

        $roles[$property.Name] = [pscustomobject]@{
            Name       = $property.Name
            Groups     = [string[]]@($groups | ForEach-Object { $_.Trim() })
            LicenseSku = $sku.Trim()
        }
    }

    [pscustomobject]@{
        Path          = $Path
        UsageLocation = $usageLocation
        Roles         = $roles
    }
}
