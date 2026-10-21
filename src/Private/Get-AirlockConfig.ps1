function Get-AirlockSetting {
    <#
    .SYNOPSIS
        Returns one setting, preferring a non-empty environment variable over the .env file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [hashtable]$FileValues = @{}
    )

    $fromEnvironment = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrEmpty($fromEnvironment)) {
        return $fromEnvironment
    }

    if ($FileValues.ContainsKey($Name)) {
        return [string]$FileValues[$Name]
    }

    $null
}

function Get-AirlockConfig {
    <#
    .SYNOPSIS
        Reads and validates Airlock settings.
    .DESCRIPTION
        Environment variables take precedence over values read from a .env file
        (see Read-AirlockEnvFile), and nothing is exported to the environment.
        Returns an object with TenantId, ClientId, AuthMethod, CertificateThumbprint,
        ClientSecret and LogDirectory. When both a certificate thumbprint and a client
        secret are set, the certificate is used. The secret and the thumbprint are
        trimmed, and the thumbprint also loses any spaces and invisible marks that
        come with copying it from a certificate viewer. Error messages name the
        missing variable and never include secret values.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable]$FileValues = @{}
    )

    $tenantId = Get-AirlockSetting -Name 'AIRLOCK_TENANT_ID' -FileValues $FileValues
    $clientId = Get-AirlockSetting -Name 'AIRLOCK_CLIENT_ID' -FileValues $FileValues
    $thumbprint = Get-AirlockSetting -Name 'AIRLOCK_CERT_THUMBPRINT' -FileValues $FileValues
    $secret = Get-AirlockSetting -Name 'AIRLOCK_CLIENT_SECRET' -FileValues $FileValues
    $logDirectory = Get-AirlockSetting -Name 'AIRLOCK_LOG_DIR' -FileValues $FileValues

    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        throw 'AIRLOCK_TENANT_ID is not set. Set it in .env or as an environment variable.'
    }
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        throw 'AIRLOCK_CLIENT_ID is not set. Set it in .env or as an environment variable.'
    }

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($clientId.Trim(), [ref]$parsed)) {
        throw 'AIRLOCK_CLIENT_ID must be a GUID.'
    }

    if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
        $thumbprint = $thumbprint -replace '[\s‎‏‪-‮]', ''
    }
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        $secret = $secret.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
        $method = 'Certificate'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($secret)) {
        $method = 'Secret'
    }
    else {
        throw 'Set AIRLOCK_CERT_THUMBPRINT or AIRLOCK_CLIENT_SECRET. Neither is set.'
    }

    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Join-Path -Path (Get-Location).Path -ChildPath 'logs'
    }

    [pscustomobject]@{
        TenantId              = $tenantId.Trim()
        ClientId              = $clientId.Trim()
        AuthMethod            = $method
        CertificateThumbprint = $thumbprint
        ClientSecret          = $secret
        LogDirectory          = $logDirectory
    }
}
