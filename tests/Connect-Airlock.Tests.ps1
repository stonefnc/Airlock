BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    $script:EnvNames = @(
        'AIRLOCK_TENANT_ID'
        'AIRLOCK_CLIENT_ID'
        'AIRLOCK_CERT_THUMBPRINT'
        'AIRLOCK_CLIENT_SECRET'
        'AIRLOCK_LOG_DIR'
        'NOT_AIRLOCK_VAR_FOR_TEST'
    )
    $script:SavedEnv = @{}
    foreach ($name in $script:EnvNames) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    function Reset-TestEnv {
        foreach ($name in $script:EnvNames) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    function Set-TestEnv {
        param([hashtable]$Values)
        foreach ($key in $Values.Keys) {
            [Environment]::SetEnvironmentVariable($key, $Values[$key], 'Process')
        }
    }

    # Makes the token carry exactly these application roles.
    function Set-TokenRole {
        param([string[]]$Role, [switch]$OmitRoles)
        $jwt = New-AirlockTestJwt -Role $Role -OmitRoles:$OmitRoles
        $body = {
            [pscustomobject]@{
                RequestMessage = [pscustomobject]@{
                    Headers = [pscustomobject]@{ Authorization = [pscustomobject]@{ Parameter = $jwt } }
                }
            }
        }.GetNewClosure()
        Mock -ModuleName Airlock Invoke-MgGraphRequest -MockWith $body
    }

    # Sets what the Graph context reports as scopes. For app-only sessions this is often empty.
    function Set-ContextScope {
        param([string[]]$Scope)
        $body = { [pscustomobject]@{ Scopes = $Scope } }.GetNewClosure()
        Mock -ModuleName Airlock Get-MgContext -MockWith $body
    }

    $script:EmptyEnvFile = Join-Path -Path $TestDrive -ChildPath 'empty.env'
    Set-Content -LiteralPath $script:EmptyEnvFile -Value '# no settings here'

    $script:TestTenant = '22222222-2222-2222-2222-222222222222'
    $script:TestClient = '11111111-1111-1111-1111-111111111111'

    # Every required permission plus the optional one, so ordinary tests see no warning.
    $script:AllRoles = @(InModuleScope Airlock {
            Get-AirlockRequiredPermission -Command 'New-AirlockUser', 'Remove-AirlockUser'
        }) + 'Files.Read.All'
}

AfterAll {
    foreach ($name in $script:EnvNames) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name], 'Process')
    }
    Remove-AirlockTestStubs
}

Describe 'Read-AirlockEnvFile' {
    BeforeEach {
        Reset-TestEnv
    }

    It 'returns AIRLOCK values and ignores comments, blanks and other names' {
        $file = Join-Path -Path $TestDrive -ChildPath 'load.env'
        Set-Content -LiteralPath $file -Value @(
            '# a comment'
            ''
            'AIRLOCK_TENANT_ID=tenant-from-file'
            'AIRLOCK_CLIENT_ID="quoted-client"'
            "AIRLOCK_CLIENT_SECRET='single-quoted'"
            'NOT_AIRLOCK_VAR_FOR_TEST=should-not-load'
            'no equals sign here'
        )

        $values = InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Read-AirlockEnvFile -Path $Path
        }

        $values['AIRLOCK_TENANT_ID'] | Should -Be 'tenant-from-file'
        $values['AIRLOCK_CLIENT_ID'] | Should -Be 'quoted-client'
        $values['AIRLOCK_CLIENT_SECRET'] | Should -Be 'single-quoted'
        $values.ContainsKey('NOT_AIRLOCK_VAR_FOR_TEST') | Should -BeFalse
    }

    It 'does not put anything into the process environment' {
        $file = Join-Path -Path $TestDrive -ChildPath 'noexport.env'
        Set-Content -LiteralPath $file -Value @('AIRLOCK_TENANT_ID=t', 'AIRLOCK_CLIENT_SECRET=fake-secret-value')

        InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Read-AirlockEnvFile -Path $Path | Out-Null
        }

        $env:AIRLOCK_TENANT_ID | Should -BeNullOrEmpty
        $env:AIRLOCK_CLIENT_SECRET | Should -BeNullOrEmpty
    }

    It 'skips empty values' {
        $file = Join-Path -Path $TestDrive -ChildPath 'blank.env'
        Set-Content -LiteralPath $file -Value 'AIRLOCK_CERT_THUMBPRINT='

        $values = InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Read-AirlockEnvFile -Path $Path
        }

        $values.ContainsKey('AIRLOCK_CERT_THUMBPRINT') | Should -BeFalse
    }

    It 'throws when an explicit path does not exist' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'missing.env'

        {
            InModuleScope Airlock -Parameters @{ Path = $missing } -ScriptBlock {
                param($Path)
                Read-AirlockEnvFile -Path $Path
            }
        } | Should -Throw '*not found*'
    }
}

Describe 'Get-AirlockConfig' {
    BeforeEach {
        Reset-TestEnv
    }

    It 'throws and names AIRLOCK_TENANT_ID when it is missing' {
        Set-TestEnv @{ AIRLOCK_CLIENT_ID = $script:TestClient; AIRLOCK_CERT_THUMBPRINT = 'ABC123' }

        { InModuleScope Airlock { Get-AirlockConfig } } | Should -Throw '*AIRLOCK_TENANT_ID*'
    }

    It 'throws and names AIRLOCK_CLIENT_ID when it is missing' {
        Set-TestEnv @{ AIRLOCK_TENANT_ID = $script:TestTenant; AIRLOCK_CERT_THUMBPRINT = 'ABC123' }

        { InModuleScope Airlock { Get-AirlockConfig } } | Should -Throw '*AIRLOCK_CLIENT_ID*'
    }

    It 'rejects a client ID that is not a GUID' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID       = $script:TestTenant
            AIRLOCK_CLIENT_ID       = 'not-a-guid'
            AIRLOCK_CERT_THUMBPRINT = 'ABC123'
        }

        { InModuleScope Airlock { Get-AirlockConfig } } | Should -Throw '*must be a GUID*'
    }

    It 'throws when neither a certificate nor a secret is set' {
        Set-TestEnv @{ AIRLOCK_TENANT_ID = $script:TestTenant; AIRLOCK_CLIENT_ID = $script:TestClient }

        { InModuleScope Airlock { Get-AirlockConfig } } | Should -Throw '*AIRLOCK_CERT_THUMBPRINT or AIRLOCK_CLIENT_SECRET*'
    }

    It 'prefers the certificate when both credentials are set' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID       = $script:TestTenant
            AIRLOCK_CLIENT_ID       = $script:TestClient
            AIRLOCK_CERT_THUMBPRINT = 'ABC123'
            AIRLOCK_CLIENT_SECRET   = 'fake-secret-value'
        }

        $config = InModuleScope Airlock { Get-AirlockConfig }

        $config.AuthMethod | Should -Be 'Certificate'
    }

    It 'uses the secret when no certificate is set' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID     = $script:TestTenant
            AIRLOCK_CLIENT_ID     = $script:TestClient
            AIRLOCK_CLIENT_SECRET = 'fake-secret-value'
        }

        $config = InModuleScope Airlock { Get-AirlockConfig }

        $config.AuthMethod | Should -Be 'Secret'
    }

    It 'trims the secret' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID     = $script:TestTenant
            AIRLOCK_CLIENT_ID     = $script:TestClient
            AIRLOCK_CLIENT_SECRET = "  fake-secret-value`r`n"
        }

        (InModuleScope Airlock { Get-AirlockConfig }).ClientSecret | Should -Be 'fake-secret-value'
    }

    It 'cleans a thumbprint copied from a certificate viewer' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID       = $script:TestTenant
            AIRLOCK_CLIENT_ID       = $script:TestClient
            AIRLOCK_CERT_THUMBPRINT = ([string][char]0x200E) + 'ab cd ef 12  34 '
        }

        (InModuleScope Airlock { Get-AirlockConfig }).CertificateThumbprint | Should -Be 'abcdef1234'
    }

    It 'treats a thumbprint that is only spaces as not set' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID       = $script:TestTenant
            AIRLOCK_CLIENT_ID       = $script:TestClient
            AIRLOCK_CERT_THUMBPRINT = '   '
        }

        { InModuleScope Airlock { Get-AirlockConfig } } | Should -Throw '*Neither is set*'
    }

    It 'uses file values when no environment variable is set, and the environment wins when both are' {
        Set-TestEnv @{ AIRLOCK_TENANT_ID = 'from-environment' }

        $config = InModuleScope Airlock {
            Get-AirlockConfig -FileValues @{
                AIRLOCK_TENANT_ID       = 'from-file'
                AIRLOCK_CLIENT_ID       = '11111111-1111-1111-1111-111111111111'
                AIRLOCK_CERT_THUMBPRINT = 'FILE123'
            }
        }

        $config.TenantId | Should -Be 'from-environment'
        $config.ClientId | Should -Be '11111111-1111-1111-1111-111111111111'
        $config.CertificateThumbprint | Should -Be 'FILE123'
    }

    It 'does not put the secret in an error message' {
        Set-TestEnv @{ AIRLOCK_CLIENT_ID = $script:TestClient; AIRLOCK_CLIENT_SECRET = 'fake-secret-value' }

        $message = try { InModuleScope Airlock { Get-AirlockConfig } } catch { $_.Exception.Message }

        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match 'fake-secret-value'
    }

    It 'honours AIRLOCK_LOG_DIR and defaults to a logs folder' {
        Set-TestEnv @{
            AIRLOCK_TENANT_ID       = $script:TestTenant
            AIRLOCK_CLIENT_ID       = $script:TestClient
            AIRLOCK_CERT_THUMBPRINT = 'ABC123'
        }

        $default = InModuleScope Airlock { Get-AirlockConfig }
        Split-Path -Leaf $default.LogDirectory | Should -Be 'logs'

        $env:AIRLOCK_LOG_DIR = Join-Path -Path $TestDrive -ChildPath 'custom-logs'
        $custom = InModuleScope Airlock { Get-AirlockConfig }
        $custom.LogDirectory | Should -Be (Join-Path -Path $TestDrive -ChildPath 'custom-logs')
    }
}

Describe 'Get-AirlockRequiredPermission' {
    It 'returns the permissions for one command' {
        $permissions = InModuleScope Airlock { Get-AirlockRequiredPermission -Command 'Remove-AirlockUser' }

        $permissions | Should -Contain 'User.RevokeSessions.All'
        $permissions | Should -Not -Contain 'LicenseAssignment.Read.All'
    }

    It 'returns a sorted union without duplicates for several commands' {
        $permissions = InModuleScope Airlock {
            Get-AirlockRequiredPermission -Command 'New-AirlockUser', 'Remove-AirlockUser'
        }

        $permissions.Count | Should -Be (@($permissions | Select-Object -Unique)).Count
        $permissions | Should -Be @($permissions | Sort-Object)
        $permissions | Should -Contain 'LicenseAssignment.Read.All'
        $permissions | Should -Contain 'User.RevokeSessions.All'
    }

    It 'does not require Files.Read.All for any command' {
        $permissions = InModuleScope Airlock {
            Get-AirlockRequiredPermission -Command 'New-AirlockUser', 'Remove-AirlockUser'
        }

        $permissions | Should -Not -Contain 'Files.Read.All'
    }

    It 'throws for an unknown command' {
        { InModuleScope Airlock { Get-AirlockRequiredPermission -Command 'Nope' } } | Should -Throw '*Unknown Airlock command*'
    }
}

Describe 'Get-AirlockOptionalPermission' {
    It 'lists Files.Read.All for onboarding, with what is lost without it' {
        $optional = @(InModuleScope Airlock { Get-AirlockOptionalPermission -Command 'New-AirlockUser' })

        $optional.Count | Should -Be 1
        $optional[0].Permission | Should -Be 'Files.Read.All'
        $optional[0].WithoutIt | Should -Match 'OneDrive'
    }

    It 'lists nothing for offboarding' {
        @(InModuleScope Airlock { Get-AirlockOptionalPermission -Command 'Remove-AirlockUser' }).Count | Should -Be 0
    }

    It 'throws for an unknown command' {
        { InModuleScope Airlock { Get-AirlockOptionalPermission -Command 'Nope' } } | Should -Throw '*Unknown Airlock command*'
    }
}

Describe 'ConvertFrom-AirlockJwtPayload' {
    It 'reads the roles claim of a token' {
        $jwt = New-AirlockTestJwt -Role 'User.ReadWrite.All', 'Group.Read.All'

        $claims = InModuleScope Airlock -Parameters @{ Jwt = $jwt } -ScriptBlock {
            param($Jwt)
            ConvertFrom-AirlockJwtPayload -Token $Jwt
        }

        @($claims.roles) | Should -Be @('User.ReadWrite.All', 'Group.Read.All')
    }

    It 'returns nothing for <Name>' -ForEach @(
        @{ Name = 'an empty string'; Token = '' }
        @{ Name = 'text that is not a token'; Token = 'not-a-token' }
        @{ Name = 'a token with a payload that is not base64'; Token = 'aaa.%%%%.ccc' }
        @{ Name = 'a token with a payload that is not JSON'; Token = 'aaa.bm90LWpzb24.ccc' }
        @{ Name = 'a payload of impossible length'; Token = 'aaa.abcde.ccc' }
    ) {
        InModuleScope Airlock -Parameters @{ Token = $Token } -ScriptBlock {
            param($Token)
            ConvertFrom-AirlockJwtPayload -Token $Token
        } | Should -BeNullOrEmpty
    }
}

Describe 'Connect-Airlock' {
    BeforeEach {
        Reset-TestEnv
        Set-TestEnv @{
            AIRLOCK_TENANT_ID       = $script:TestTenant
            AIRLOCK_CLIENT_ID       = $script:TestClient
            AIRLOCK_CERT_THUMBPRINT = 'ABC123'
        }
        Mock -ModuleName Airlock Connect-MgGraph -MockWith { }
        Mock -ModuleName Airlock Disconnect-MgGraph -MockWith { }
        Set-TokenRole -Role $script:AllRoles
        Set-ContextScope -Scope @()
    }

    It 'connects with the certificate' {
        Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile | Out-Null

        Should -Invoke -CommandName Connect-MgGraph -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
            $CertificateThumbprint -eq 'ABC123' -and
            $TenantId -eq '22222222-2222-2222-2222-222222222222' -and
            $ClientId -eq '11111111-1111-1111-1111-111111111111' -and
            -not $ClientSecretCredential
        }
    }

    It 'connects with a client secret credential when no certificate is set' {
        Set-TestEnv @{ AIRLOCK_CERT_THUMBPRINT = $null; AIRLOCK_CLIENT_SECRET = 'fake-secret-value' }

        Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile | Out-Null

        Should -Invoke -CommandName Connect-MgGraph -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
            $ClientSecretCredential -is [pscredential] -and
            $ClientSecretCredential.UserName -eq '11111111-1111-1111-1111-111111111111' -and
            -not $CertificateThumbprint
        }
    }

    It 'reads settings from a .env file and does not export them to the environment' {
        Reset-TestEnv
        $file = Join-Path -Path $TestDrive -ChildPath 'connect.env'
        Set-Content -LiteralPath $file -Value @(
            "AIRLOCK_TENANT_ID=$($script:TestTenant)"
            "AIRLOCK_CLIENT_ID=$($script:TestClient)"
            'AIRLOCK_CLIENT_SECRET=fake-secret-value'
        )

        Connect-Airlock -Command New-AirlockUser -EnvPath $file | Out-Null

        Should -Invoke -CommandName Connect-MgGraph -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
            $ClientSecretCredential.UserName -eq '11111111-1111-1111-1111-111111111111'
        }
        $env:AIRLOCK_CLIENT_SECRET | Should -BeNullOrEmpty
        $env:AIRLOCK_TENANT_ID | Should -BeNullOrEmpty
    }

    It 'returns connection details without any secret or token' {
        Set-TestEnv @{ AIRLOCK_CLIENT_SECRET = 'fake-secret-value' }

        $result = Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile

        $result.TenantId | Should -Be $script:TestTenant
        $result.ClientId | Should -Be $script:TestClient
        $result.AuthMethod | Should -Be 'Certificate'
        $result.Permissions | Should -Contain 'User.ReadWrite.All'
        $json = $result | ConvertTo-Json -Depth 3
        $json | Should -Not -Match 'fake-secret-value'
        $json | Should -Not -Match 'eyJ'
    }

    It 'stores state that later commands can read' {
        Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile | Out-Null

        $state = InModuleScope Airlock { Get-AirlockState }

        $state.ClientId | Should -Be $script:TestClient
    }

    Context 'checking permissions' {
        It 'succeeds from the token roles even when the context scopes are empty' {
            Set-ContextScope -Scope @()

            $result = Connect-Airlock -Command New-AirlockUser, Remove-AirlockUser -EnvPath $script:EmptyEnvFile

            $result.PermissionsChecked | Should -BeTrue
            $result.PermissionSource | Should -Be 'Token'
            Should -Invoke -CommandName Disconnect-MgGraph -ModuleName Airlock -Times 0 -Exactly
        }

        It 'checks only the permissions of the named command' {
            Set-TokenRole -Role @(
                'User.ReadWrite.All'
                'User.RevokeSessions.All'
                'Directory.Read.All'
                'GroupMember.ReadWrite.All'
                'LicenseAssignment.ReadWrite.All'
            )

            $result = Connect-Airlock -Command Remove-AirlockUser -EnvPath $script:EmptyEnvFile

            $result.Permissions | Should -Not -Contain 'LicenseAssignment.Read.All'
        }

        It 'fails early, names the missing permission, disconnects and clears state' {
            Set-TokenRole -Role @($script:AllRoles | Where-Object { $_ -ne 'LicenseAssignment.Read.All' })

            { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } |
                Should -Throw '*LicenseAssignment.Read.All*'

            Should -Invoke -CommandName Disconnect-MgGraph -ModuleName Airlock -Times 1 -Exactly
            { InModuleScope Airlock { Get-AirlockState } } | Should -Throw '*Connect-Airlock*'
        }

        It 'connects without Files.Read.All, warns once, and records it as missing' {
            Set-TokenRole -Role @($script:AllRoles | Where-Object { $_ -ne 'Files.Read.All' })

            $result = Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile -WarningVariable connectWarning -WarningAction SilentlyContinue

            $result.PermissionsChecked | Should -BeTrue
            @($result.OptionalPermissionsMissing) | Should -Be @('Files.Read.All')
            $result.Permissions | Should -Not -Contain 'Files.Read.All'
            @($connectWarning).Count | Should -Be 1
            ($connectWarning -join ' ') | Should -Match 'Files.Read.All'
            ($connectWarning -join ' ') | Should -Match 'NotChecked'
            Should -Invoke -CommandName Disconnect-MgGraph -ModuleName Airlock -Times 0 -Exactly
        }

        It 'does not warn when the optional permission is granted' {
            $result = Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile -WarningVariable connectWarning -WarningAction SilentlyContinue

            @($result.OptionalPermissionsMissing).Count | Should -Be 0
            @($connectWarning).Count | Should -Be 0
        }

        It 'does not warn about an optional permission for a command that does not use it' {
            Set-TokenRole -Role @($script:AllRoles | Where-Object { $_ -ne 'Files.Read.All' })

            $result = Connect-Airlock -Command Remove-AirlockUser -EnvPath $script:EmptyEnvFile -WarningVariable connectWarning -WarningAction SilentlyContinue

            @($result.OptionalPermissionsMissing).Count | Should -Be 0
            @($connectWarning).Count | Should -Be 0
        }

        It 'fails when the token has no roles claim at all' {
            Set-TokenRole -OmitRoles

            { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } |
                Should -Throw '*missing required application permissions*'
        }

        It 'falls back to the context scopes when the token cannot be read' {
            Mock -ModuleName Airlock Invoke-MgGraphRequest -MockWith { throw 'Forbidden: simulated' }
            Set-ContextScope -Scope $script:AllRoles

            $result = Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile

            $result.PermissionSource | Should -Be 'Context'
            $result.PermissionsChecked | Should -BeTrue
        }

        It 'does not guess when a token cannot be read and the scopes are missing a permission' {
            Mock -ModuleName Airlock Invoke-MgGraphRequest -MockWith { throw 'Forbidden: simulated' }
            Set-ContextScope -Scope @('User.ReadWrite.All')

            { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } |
                Should -Throw '*missing required application permissions*'
        }

        It 'warns, does not check and still connects when the permissions cannot be read at all' {
            Mock -ModuleName Airlock Invoke-MgGraphRequest -MockWith { throw 'Forbidden: simulated' }
            Set-ContextScope -Scope @()

            $result = Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile -WarningVariable connectWarning -WarningAction SilentlyContinue

            $result.PermissionsChecked | Should -BeFalse
            $result.PermissionSource | Should -Be 'Unknown'
            ($connectWarning -join ' ') | Should -Match 'could not be read'
            Should -Invoke -CommandName Disconnect-MgGraph -ModuleName Airlock -Times 0 -Exactly
        }

        It 'treats a response that is not a token as unreadable' {
            Mock -ModuleName Airlock Invoke-MgGraphRequest -MockWith {
                [pscustomobject]@{ RequestMessage = [pscustomobject]@{ Headers = [pscustomobject]@{ Authorization = [pscustomobject]@{ Parameter = 'garbage' } } } }
            }
            Set-ContextScope -Scope $script:AllRoles

            (Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile).PermissionSource | Should -Be 'Context'
        }
    }

    Context 'state and configuration' {
        It 'clears an earlier connection before trying again, even if the new attempt fails early' {
            Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile | Out-Null
            Set-TestEnv @{ AIRLOCK_CERT_THUMBPRINT = $null }

            { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } | Should -Throw
            { InModuleScope Airlock { Get-AirlockState } } | Should -Throw '*Connect-Airlock*'
        }

        It 'does not call Graph when configuration is incomplete' {
            Set-TestEnv @{ AIRLOCK_CERT_THUMBPRINT = $null }

            { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } | Should -Throw

            Should -Invoke -CommandName Connect-MgGraph -ModuleName Airlock -Times 0 -Exactly
        }

        It 'rejects an unknown command name' {
            { Connect-Airlock -Command 'Get-Everything' -EnvPath $script:EmptyEnvFile } | Should -Throw
        }
    }
}
