function ConvertFrom-AirlockJwtPayload {
    <#
    .SYNOPSIS
        Decodes the payload (claims) of a JSON web token. Returns $null if it is not one.
    .DESCRIPTION
        This only reads the claims. It does not validate the signature, because the
        token was just issued to this process and is used only to see which
        application roles it carries. The token itself must never be logged or stored.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) {
        return $null
    }

    try {
        $text = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($text.Length % 4) {
            1 { return $null }
            2 { $text += '==' }
            3 { $text += '=' }
        }
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text))
        $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $null
    }
}

function Get-AirlockGrantedPermission {
    <#
    .SYNOPSIS
        Finds out which application permissions the signed-in app actually has.
    .DESCRIPTION
        The application roles are in the "roles" claim of the access token. The Graph
        SDK does not hand the token over, but it attaches it to every request, so one
        harmless request is made and the token is read back from that request.
        If the token cannot be read, the scopes on the Graph context are used. For an
        app-only session these are often empty. If neither source gives an answer,
        Source is Unknown and the caller must not treat the permissions as missing.
        Returns Source (Token, Context or Unknown) and Permissions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/users?$top=1&$select=id' -OutputType HttpResponseMessage -ErrorAction Stop
        $token = $response.RequestMessage.Headers.Authorization.Parameter
        if ($response -is [System.IDisposable]) {
            $response.Dispose()
        }

        $claims = ConvertFrom-AirlockJwtPayload -Token $token
        $token = $null
        if ($null -ne $claims) {
            $roles = @()
            if ($claims.PSObject.Properties['roles'] -and $null -ne $claims.roles) {
                $roles = @($claims.roles | ForEach-Object { [string]$_ })
            }
            return [pscustomobject]@{ Source = 'Token'; Permissions = $roles }
        }
    }
    catch {
        Write-Verbose "The token could not be read: $($_.Exception.Message)"
    }

    $context = Get-MgContext
    if ($null -ne $context -and $context.PSObject.Properties['Scopes'] -and $null -ne $context.Scopes -and @($context.Scopes).Count -gt 0) {
        return [pscustomobject]@{ Source = 'Context'; Permissions = @($context.Scopes | ForEach-Object { [string]$_ }) }
    }

    [pscustomobject]@{ Source = 'Unknown'; Permissions = @() }
}
