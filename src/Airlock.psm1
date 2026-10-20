#Requires -Version 7.0
Set-StrictMode -Version Latest

$publicPath = Join-Path -Path $PSScriptRoot -ChildPath 'Public'
$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'

$private = @(Get-ChildItem -Path $privatePath -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path $publicPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

foreach ($file in @($private) + @($public)) {
    . $file.FullName
}

Export-ModuleMember -Function $public.BaseName
