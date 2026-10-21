function Connect-Airlock {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with app-only authentication.
    .DESCRIPTION
        Reads AIRLOCK_TENANT_ID, AIRLOCK_CLIENT_ID and either AIRLOCK_CERT_THUMBPRINT
        or AIRLOCK_CLIENT_SECRET from the environment, or from a .env file. Values in
        the file are not copied into the process environment.

        App-only sign-in cannot request scopes. The permissions are fixed on the app
        registration and arrive in the access token as application roles. This command
        reads the roles from the token and stops before any change is made if the
        token lacks a permission that the named commands need. If the roles cannot be
        read at all, a warning says so and the permissions are not checked, so a
        missing permission shows up as an error on the first call that needs it.
    .PARAMETER Command
        The Airlock commands you plan to run in this session.
    .PARAMETER EnvPath
        Path to a .env file. Defaults to ./.env, then the repository root.
    .EXAMPLE
        Connect-Airlock -Command New-AirlockUser
    .EXAMPLE
        Connect-Airlock -Command New-AirlockUser, Remove-AirlockUser
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The client secret is read from the environment or a .env file as text. It is wrapped once to build the credential Connect-MgGraph requires and is not kept.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('New-AirlockUser', 'Remove-AirlockUser', 'Get-AirlockLicenseUsage', 'Get-AirlockComplianceReport', 'Get-AirlockStaleDevice')]
        [string[]]$Command,

        [string]$EnvPath
    )

    # Never carry an earlier connection into a new attempt, whatever happens below.
    $script:AirlockState = $null

    $fileValues = Read-AirlockEnvFile -Path $EnvPath
    $config = Get-AirlockConfig -FileValues $fileValues
    $fileValues = $null
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
    $config.ClientSecret = $null

    $granted = Get-AirlockGrantedPermission
    $permissionsChecked = $granted.Source -ne 'Unknown'
    $optionalMissing = @()

    if ($permissionsChecked) {
        $missing = @($required | Where-Object { $_ -notin $granted.Permissions })
        if ($missing.Count -gt 0) {
            Disconnect-MgGraph | Out-Null
            $list = $missing -join ', '
            throw "The app registration is missing required application permissions: $list. Grant them with admin consent. See docs/permissions.md."
        }

        $optionalMissing = @(Get-AirlockOptionalPermission -Command $Command | Where-Object { $_.Permission -notin $granted.Permissions })
        if ($optionalMissing.Count -gt 0) {
            $notes = ($optionalMissing | ForEach-Object { "$($_.Permission): $($_.WithoutIt)" }) -join ' / '
            Write-Warning "Optional permission not granted. $notes."
        }
    }
    else {
        Write-Warning 'The permissions granted to the app could not be read, so they were not checked. A missing permission will show up as an error on the first call that needs it.'
    }

    $script:AirlockState = [pscustomobject]@{
        TenantId           = $config.TenantId
        ClientId           = $config.ClientId
        AuthMethod         = $config.AuthMethod
        Commands           = @($Command)
        Permissions        = $required
        PermissionsChecked = $permissionsChecked
        PermissionSource   = $granted.Source
        OptionalPermissionsMissing = @($optionalMissing | ForEach-Object { $_.Permission })
        LogDirectory       = $config.LogDirectory
        ConnectedAt        = [datetime]::UtcNow
    }

    $script:AirlockState
}
