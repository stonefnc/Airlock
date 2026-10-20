function Get-AirlockRandomIndex {
    <#
    .SYNOPSIS
        Returns an unbiased random integer from 0 to Count - 1 using the system CSPRNG.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65536)]
        [int]$Count
    )

    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object byte[] 4
        $range = 4294967296L
        $limit = $range - ($range % $Count)
        do {
            $generator.GetBytes($buffer)
            $value = [long][BitConverter]::ToUInt32($buffer, 0)
        } while ($value -ge $limit)

        [int]($value % $Count)
    }
    finally {
        $generator.Dispose()
    }
}

function New-AirlockPassword {
    <#
    .SYNOPSIS
        Generates a random temporary password.
    .DESCRIPTION
        The password has at least one lower case letter, upper case letter, digit and
        symbol, and avoids characters that are easy to misread. It is returned as plain
        text for the caller to pass to Graph and then discard. It must never be logged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(12, 64)]
        [int]$Length = 20
    )

    $sets = @(
        'abcdefghijkmnopqrstuvwxyz'
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        '23456789'
        '!#$%&*+-=?@'
    )
    $all = -join $sets

    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $sets) {
        $chars.Add($set[(Get-AirlockRandomIndex -Count $set.Length)])
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($all[(Get-AirlockRandomIndex -Count $all.Length)])
    }

    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-AirlockRandomIndex -Count ($i + 1)
        $swap = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $swap
    }

    -join $chars
}
