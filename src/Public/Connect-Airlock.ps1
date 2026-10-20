function Connect-Airlock {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with app-only authentication.
    .DESCRIPTION
        Reads AIRLOCK_TENANT_ID, AIRLOCK_CLIENT_ID and either AIRLOCK_CERT_THUMBPRINT
        or AIRLOCK_CLIENT_SECRET from the environment, loading a .env file first
        if one is found. App-only sign-in cannot request scopes. The permissions
        are fixed on the app registration and arrive in the token as application
        roles, so this command checks that the token carries every permission the
        named commands need and fails before any change is attempted if one is missing.
    .PARAMETER Command
        The Airlock commands you plan to run in this session.
    .PARAMETER EnvPath
        Path to a .env file. Defaults to ./.env, then the repository root.
    .EXAMPLE
        Connect-Airlock -Command New-AirlockUser
    .EXAMPLE
        Connect-Airlock -Command New-AirlockUser, Remove-AirlockUser
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('New-AirlockUser', 'Remove-AirlockUser')]
        [string[]]$Command,

        [string]$EnvPath
    )

    Import-AirlockEnv -Path $EnvPath
    $config = Get-AirlockConfig
    $required = Get-AirlockRequiredPermission -Command $Command

    if ($config.AuthMethod -eq 'Certificate') {
        Connect-MgGraph -TenantId $config.TenantId -ClientId $config.ClientId `
            -CertificateThumbprint $config.CertificateThumbprint -NoWelcome | Out-Null
    }
    else {
        $secureSecret = ConvertTo-SecureString -String $config.ClientSecret -AsPlainText -Force
        $credential = [pscredential]::new($config.ClientId, $secureSecret)
        Connect-MgGraph -TenantId $config.TenantId -ClientSecretCredential $credential -NoWelcome | Out-Null
    }

    $context = Get-MgContext
    $granted = @()
    if ($null -ne $context -and $null -ne $context.Scopes) {
        $granted = @($context.Scopes)
    }

    $missing = @($required | Where-Object { $_ -notin $granted })
    if ($missing.Count -gt 0) {
        Disconnect-MgGraph | Out-Null
        $script:AirlockState = $null
        $list = $missing -join ', '
        throw "The app registration is missing required application permissions: $list. Grant them with admin consent. See docs/permissions.md."
    }

    $script:AirlockState = [pscustomobject]@{
        TenantId     = $config.TenantId
        ClientId     = $config.ClientId
        AuthMethod   = $config.AuthMethod
        Commands     = @($Command)
        Permissions  = $required
        LogDirectory = $config.LogDirectory
        ConnectedAt  = [datetime]::UtcNow
    }

    $script:AirlockState
}
