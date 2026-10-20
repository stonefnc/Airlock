function Import-AirlockEnv {
    <#
    .SYNOPSIS
        Loads AIRLOCK_* settings from a .env file into the process environment.
    .DESCRIPTION
        Variables that are already set to a non-empty value are never overwritten,
        so real environment variables take precedence over the file. Lines that are
        blank, comments, or not AIRLOCK_* names are ignored. Empty values are skipped.
        With no -Path, ./.env and then the repository root .env are tried and a
        missing file is not an error. An explicit -Path that does not exist is.
    #>
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $candidates = @(
            (Join-Path -Path (Get-Location).Path -ChildPath '.env'),
            (Join-Path -Path $moduleRoot -ChildPath '.env')
        )
        $Path = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $Path) {
            return
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

        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}
