function Read-AirlockEnvFile {
    <#
    .SYNOPSIS
        Reads AIRLOCK_* settings from a .env file and returns them as a hashtable.
    .DESCRIPTION
        Nothing is written to the process environment. The values, including the
        client secret, stay in memory and are passed to Get-AirlockConfig, so they are
        not inherited by child processes. Lines that are blank, comments, or not
        AIRLOCK_* names are ignored. Empty values are skipped.
        With no -Path, ./.env and then the repository root .env are tried and a
        missing file gives an empty result. An explicit -Path that does not exist is
        an error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path
    )

    $values = @{}

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $candidates = @(
            (Join-Path -Path (Get-Location).Path -ChildPath '.env'),
            (Join-Path -Path $moduleRoot -ChildPath '.env')
        )
        $Path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $Path) {
            return $values
        }
    }
    elseif (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Environment file not found: $Path"
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith('#')) {
            continue
        }

        $index = $text.IndexOf('=')
        if ($index -lt 1) {
            continue
        }

        $name = $text.Substring(0, $index).Trim()
        $value = $text.Substring($index + 1).Trim()

        if ($name -notmatch '^AIRLOCK_[A-Z0-9_]+$') {
            continue
        }

        $quoted = $value.Length -ge 2 -and (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))
        if ($quoted) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ([string]::IsNullOrEmpty($value)) {
            continue
        }

        $values[$name] = $value
    }

    $values
}
