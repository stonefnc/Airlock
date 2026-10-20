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

    function Set-GrantedScope {
        param([string[]]$Scope)
        $body = { [pscustomobject]@{ Scopes = $Scope } }.GetNewClosure()
        Mock -ModuleName Airlock Get-MgContext -MockWith $body
    }

    $script:EmptyEnvFile = Join-Path -Path $TestDrive -ChildPath 'empty.env'
    Set-Content -LiteralPath $script:EmptyEnvFile -Value '# no settings here'

    $script:TestTenant = '22222222-2222-2222-2222-222222222222'
    $script:TestClient = '11111111-1111-1111-1111-111111111111'

    $script:AllScopes = InModuleScope Airlock {
        Get-AirlockRequiredPermission -Command 'New-AirlockUser', 'Remove-AirlockUser'
    }
}

AfterAll {
    foreach ($name in $script:EnvNames) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name], 'Process')
    }
    Remove-AirlockTestStubs
}

Describe 'Import-AirlockEnv' {
    BeforeEach {
        Reset-TestEnv
    }

    It 'loads AIRLOCK values and ignores comments, blanks and other names' {
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

        InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Import-AirlockEnv -Path $Path
        }

        $env:AIRLOCK_TENANT_ID | Should -Be 'tenant-from-file'
        $env:AIRLOCK_CLIENT_ID | Should -Be 'quoted-client'
        $env:AIRLOCK_CLIENT_SECRET | Should -Be 'single-quoted'
        $env:NOT_AIRLOCK_VAR_FOR_TEST | Should -BeNullOrEmpty
    }

    It 'does not overwrite a variable that is already set' {
        $file = Join-Path -Path $TestDrive -ChildPath 'precedence.env'
        Set-Content -LiteralPath $file -Value 'AIRLOCK_TENANT_ID=from-file'
        $env:AIRLOCK_TENANT_ID = 'from-environment'

        InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Import-AirlockEnv -Path $Path
        }

        $env:AIRLOCK_TENANT_ID | Should -Be 'from-environment'
    }

    It 'skips empty values' {
        $file = Join-Path -Path $TestDrive -ChildPath 'blank.env'
        Set-Content -LiteralPath $file -Value 'AIRLOCK_CERT_THUMBPRINT='

        InModuleScope Airlock -Parameters @{ Path = $file } -ScriptBlock {
            param($Path)
            Import-AirlockEnv -Path $Path
        }

        $env:AIRLOCK_CERT_THUMBPRINT | Should -BeNullOrEmpty
    }

    It 'throws when an explicit path does not exist' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'missing.env'

        {
            InModuleScope Airlock -Parameters @{ Path = $missing } -ScriptBlock {
                param($Path)
                Import-AirlockEnv -Path $Path
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
        $permissions | Should -Not -Contain 'Files.Read.All'
    }

    It 'returns a sorted union without duplicates for several commands' {
        $permissions = InModuleScope Airlock {
            Get-AirlockRequiredPermission -Command 'New-AirlockUser', 'Remove-AirlockUser'
        }

        $permissions.Count | Should -Be (@($permissions | Select-Object -Unique)).Count
        $permissions | Should -Be @($permissions | Sort-Object)
        $permissions | Should -Contain 'Files.Read.All'
        $permissions | Should -Contain 'User.RevokeSessions.All'
    }

    It 'throws for an unknown command' {
        { InModuleScope Airlock { Get-AirlockRequiredPermission -Command 'Nope' } } | Should -Throw '*Unknown Airlock command*'
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
        Set-GrantedScope -Scope $script:AllScopes
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

    It 'reads settings from a .env file' {
        Reset-TestEnv
        $file = Join-Path -Path $TestDrive -ChildPath 'connect.env'
        Set-Content -LiteralPath $file -Value @(
            "AIRLOCK_TENANT_ID=$($script:TestTenant)"
            "AIRLOCK_CLIENT_ID=$($script:TestClient)"
            'AIRLOCK_CERT_THUMBPRINT=FROMFILE1'
        )

        Connect-Airlock -Command New-AirlockUser -EnvPath $file | Out-Null

        Should -Invoke -CommandName Connect-MgGraph -ModuleName Airlock -Times 1 -Exactly -ParameterFilter {
            $CertificateThumbprint -eq 'FROMFILE1'
        }
    }

    It 'returns connection details without any secret' {
        Set-TestEnv @{ AIRLOCK_CLIENT_SECRET = 'fake-secret-value' }

        $result = Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile

        $result.TenantId | Should -Be $script:TestTenant
        $result.ClientId | Should -Be $script:TestClient
        $result.AuthMethod | Should -Be 'Certificate'
        $result.Permissions | Should -Contain 'User.ReadWrite.All'
        ($result | ConvertTo-Json -Depth 3) | Should -Not -Match 'fake-secret-value'
    }

    It 'stores state that later commands can read' {
        Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile | Out-Null

        $state = InModuleScope Airlock { Get-AirlockState }

        $state.ClientId | Should -Be $script:TestClient
    }

    It 'checks only the permissions of the named command' {
        Set-GrantedScope -Scope @(
            'User.ReadWrite.All'
            'User.RevokeSessions.All'
            'Directory.Read.All'
            'GroupMember.ReadWrite.All'
            'LicenseAssignment.ReadWrite.All'
        )

        $result = Connect-Airlock -Command Remove-AirlockUser -EnvPath $script:EmptyEnvFile

        $result.Permissions | Should -Not -Contain 'Files.Read.All'
    }

    It 'fails early, names the missing permission, disconnects and clears state' {
        Set-GrantedScope -Scope @($script:AllScopes | Where-Object { $_ -ne 'Files.Read.All' })

        { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } |
            Should -Throw '*Files.Read.All*'

        Should -Invoke -CommandName Disconnect-MgGraph -ModuleName Airlock -Times 1 -Exactly
        { InModuleScope Airlock { Get-AirlockState } } | Should -Throw '*Connect-Airlock*'
    }

    It 'fails when the token carries no roles at all' {
        Mock -ModuleName Airlock Get-MgContext -MockWith { [pscustomobject]@{ Scopes = $null } }

        { Connect-Airlock -Command New-AirlockUser -EnvPath $script:EmptyEnvFile } |
            Should -Throw '*missing required application permissions*'
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
