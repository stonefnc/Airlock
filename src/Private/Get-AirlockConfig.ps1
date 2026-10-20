function Get-AirlockConfig {
    <#
    .SYNOPSIS
        Reads and validates Airlock settings from the process environment.
    .DESCRIPTION
        Returns an object with TenantId, ClientId, AuthMethod, CertificateThumbprint,
        ClientSecret and LogDirectory. When both a certificate thumbprint and a client
        secret are set, the certificate is used. Error messages name the missing
        variable and never include secret values.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $tenantId = $env:AIRLOCK_TENANT_ID
    $clientId = $env:AIRLOCK_CLIENT_ID
    $thumbprint = $env:AIRLOCK_CERT_THUMBPRINT
    $secret = $env:AIRLOCK_CLIENT_SECRET
    $logDirectory = $env:AIRLOCK_LOG_DIR

    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        throw 'AIRLOCK_TENANT_ID is not set. Set it in .env or as an environment variable.'
    }
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        throw 'AIRLOCK_CLIENT_ID is not set. Set it in .env or as an environment variable.'
    }

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($clientId, [ref]$parsed)) {
        throw 'AIRLOCK_CLIENT_ID must be a GUID.'
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
