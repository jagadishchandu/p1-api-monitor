<#
.SYNOPSIS
    Copies every NAME=value line of a .env file into the environment of the current PowerShell session.
    The app (monitor.py) reads only environment variables, so use this before a local run.

.EXAMPLE
    . .\Load-EnvToSession.ps1               # loads .env from this folder
    . .\Load-EnvToSession.ps1 -Path .\prod.env
    python monitor.py --check-once

    Dot-source it (note the leading dot). Otherwise the variables are set in a child scope and are lost.
#>
param(
    [string]$Path = ".env"
)

if (-not (Test-Path -LiteralPath $Path)) {
    throw "No file at $Path. Copy .env.example to .env and fill it in."
}

$count = 0
foreach ($raw in Get-Content -LiteralPath $Path) {
    $line = $raw.Trim()
    if ($line -eq "" -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
    if ($line.StartsWith("export ")) { $line = $line.Substring(7).Trim() }

    $name, $value = $line.Split("=", 2)
    $name  = $name.Trim()
    $value = $value.Trim()
    # Remove matching single or double quotes around the value
    if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and ($value[0] -eq "'" -or $value[0] -eq '"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    Set-Item -Path "env:$name" -Value $value
    $count++
}

Write-Host "Loaded $count variable(s) from $Path into this session. Values are not printed." -ForegroundColor Green
