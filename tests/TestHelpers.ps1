# Shared setup for the Airlock tests. Dot-source this from BeforeAll.
#
# Pester can only mock commands that exist, and the tests must run on a machine
# that has no Graph SDK and no tenant. So every Graph command the module calls is
# stubbed here, with the parameters the module uses. The tests then mock these stubs.
# Each stub uses CmdletBinding so that common parameters such as -ErrorAction bind.

function global:Connect-MgGraph {
    [CmdletBinding()]
    param($TenantId, $ClientId, $CertificateThumbprint, $ClientSecretCredential, [switch]$NoWelcome)
}
function global:Disconnect-MgGraph {
    [CmdletBinding()]
    param()
}
function global:Get-MgContext {
    [CmdletBinding()]
    param()
}
function global:Invoke-MgGraphRequest {
    [CmdletBinding()]
    param($Method, $Uri, $OutputType)
}

# Builds an unsigned token whose payload carries the given application roles. It is
# only ever read by the module's claim decoder, never sent anywhere.
function global:New-AirlockTestJwt {
    param([string[]]$Role = @(), [switch]$OmitRoles)

    $encode = {
        param($text)
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $payload = @{ aud = 'https://graph.microsoft.com'; appid = '11111111-1111-1111-1111-111111111111' }
    if (-not $OmitRoles) {
        $payload['roles'] = @($Role)
    }
    '{0}.{1}.{2}' -f (& $encode '{"alg":"RS256","typ":"JWT"}'), (& $encode ($payload | ConvertTo-Json -Compress)), 'c2lnbmF0dXJl'
}

function global:Get-MgUser {
    [CmdletBinding()]
    param($UserId, $Filter, $Property, [switch]$All)
}
function global:New-MgUser {
    [CmdletBinding()]
    param($BodyParameter)
}
function global:Update-MgUser {
    [CmdletBinding()]
    param($UserId, $BodyParameter)
}
function global:Get-MgUserManager {
    [CmdletBinding()]
    param($UserId)
}
function global:Set-MgUserManagerByRef {
    [CmdletBinding()]
    param($UserId, $BodyParameter)
}
function global:Get-MgGroup {
    [CmdletBinding()]
    param($Filter, $Property, [switch]$All)
}
function global:Get-MgGroupMember {
    [CmdletBinding()]
    param($GroupId, [switch]$All)
}
function global:New-MgGroupMemberByRef {
    [CmdletBinding()]
    param($GroupId, $BodyParameter)
}
function global:Get-MgSubscribedSku {
    [CmdletBinding()]
    param([switch]$All)
}
function global:Get-MgDeviceManagementManagedDevice {
    [CmdletBinding()]
    param([switch]$All)
}
function global:Set-MgUserLicense {
    [CmdletBinding()]
    param($UserId, $BodyParameter)
}
function global:Get-MgUserDefaultDrive {
    [CmdletBinding()]
    param($UserId)
}
function global:Revoke-MgUserSignInSession {
    [CmdletBinding()]
    param($UserId)
}
function global:Get-MgUserMemberOfAsGroup {
    [CmdletBinding()]
    param($UserId, $Property, [switch]$All)
}
function global:Remove-MgGroupMemberByRef {
    [CmdletBinding()]
    param($GroupId, $DirectoryObjectId)
}

function global:Import-AirlockForTest {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'src', 'Airlock.psd1'
    Import-Module -Name (Resolve-Path -LiteralPath $manifest).Path -Force
}

# Puts the module into a connected state without calling Graph.
function global:Set-AirlockTestConnection {
    param(
        [string[]]$Command = @('New-AirlockUser', 'Remove-AirlockUser'),
        [string]$LogDirectory,
        [string[]]$OptionalPermissionsMissing = @()
    )

    # Logs go to the Pester TestDrive unless a test names a folder, so a test run
    # never writes into the repository.
    if (-not $LogDirectory) {
        $drive = Get-Variable -Name TestDrive -ValueOnly -ErrorAction SilentlyContinue
        if (-not $drive) {
            $drive = [System.IO.Path]::GetTempPath()
        }
        $LogDirectory = Join-Path -Path $drive -ChildPath 'airlock-logs'
    }

    InModuleScope Airlock -Parameters @{ Command = $Command; LogDirectory = $LogDirectory; OptionalMissing = $OptionalPermissionsMissing } -ScriptBlock {
        param($Command, $LogDirectory, $OptionalMissing)
        $script:AirlockState = [pscustomobject]@{
            TenantId     = '22222222-2222-2222-2222-222222222222'
            ClientId     = '11111111-1111-1111-1111-111111111111'
            AuthMethod   = 'Certificate'
            Commands     = @($Command)
            Permissions  = @()
            PermissionsChecked         = $true
            PermissionSource           = 'Token'
            OptionalPermissionsMissing = @($OptionalMissing)
            LogDirectory = $LogDirectory
            ConnectedAt  = [datetime]::UtcNow
        }
    }
}

function global:Remove-AirlockTestStubs {
    $stubNames = @(
        'Connect-MgGraph'
        'Disconnect-MgGraph'
        'Get-MgContext'
        'Invoke-MgGraphRequest'
        'New-AirlockTestJwt'
        'Get-MgUser'
        'New-MgUser'
        'Update-MgUser'
        'Get-MgUserManager'
        'Set-MgUserManagerByRef'
        'Get-MgGroup'
        'Get-MgGroupMember'
        'New-MgGroupMemberByRef'
        'Get-MgSubscribedSku'
        'Get-MgDeviceManagementManagedDevice'
        'Set-MgUserLicense'
        'Get-MgUserDefaultDrive'
        'Revoke-MgUserSignInSession'
        'Get-MgUserMemberOfAsGroup'
        'Remove-MgGroupMemberByRef'
        'Import-AirlockForTest'
        'Set-AirlockTestConnection'
        'Remove-AirlockTestStubs'
    )
    foreach ($name in $stubNames) {
        Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Module -Name Airlock -Force -ErrorAction SilentlyContinue
}
