# Shared setup for the Airlock tests. Dot-source this from BeforeAll.
#
# Pester can only mock commands that exist, and the tests must run on a machine
# that has no Graph SDK and no tenant. So every Graph command the module calls is
# stubbed here, with the parameters the module uses. The tests then mock these stubs.

function global:Connect-MgGraph {
    param($TenantId, $ClientId, $CertificateThumbprint, $ClientSecretCredential, [switch]$NoWelcome)
}
function global:Disconnect-MgGraph {
    param()
}
function global:Get-MgContext {
    param()
}

function global:Import-AirlockForTest {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'src', 'Airlock.psd1'
    Import-Module -Name (Resolve-Path -LiteralPath $manifest).Path -Force
}

function global:Remove-AirlockTestStubs {
    $stubNames = @('Connect-MgGraph', 'Disconnect-MgGraph', 'Get-MgContext')
    foreach ($name in $stubNames) {
        Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Item -Path 'Function:\global:Import-AirlockForTest' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Function:\global:Remove-AirlockTestStubs' -ErrorAction SilentlyContinue
    Remove-Module -Name Airlock -Force -ErrorAction SilentlyContinue
}
