#Requires -Version 5.1
<#
.SYNOPSIS
  Set host/IP/domain values on RedWindows Windows Terminal profiles.

.DESCRIPTION
  Updates Team Server, RD1-RD3, Payload (ssh) and File/Exfil Server (https) profiles
  in the current user's Windows Terminal settings.json.

  With no parameters, runs an interactive menu. Pass any of the host parameters to
  update non-interactively (omit a parameter to leave that profile unchanged).

.EXAMPLE
  Set-TerminalHosts
.EXAMPLE
  Set-TerminalHosts -TeamServer 10.0.0.5 -RD1 10.0.0.11 -FileServer files.lab.local
.EXAMPLE
  C:\Tools\Set-TerminalHosts.ps1 -Payload 10.0.0.50 -ExfilServer exfil.lab.local
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Scripted')]
    [string]$TeamServer,

    [Parameter(ParameterSetName = 'Scripted')]
    [string]$RD1,

    [Parameter(ParameterSetName = 'Scripted')]
    [string]$RD2,

    [Parameter(ParameterSetName = 'Scripted')]
    [string]$RD3,

    [Parameter(ParameterSetName = 'Scripted')]
    [string]$Payload,

    [Parameter(ParameterSetName = 'Scripted')]
    [string]$FileServer,

    [Parameter(ParameterSetName = 'Scripted')]
    [string]$ExfilServer,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Name $MyInvocation.MyCommand.Path -Full
    return
}

function Get-TerminalSettingsPath {
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    $pkg = Get-ChildItem -Path $packages -Directory -Filter 'Microsoft.WindowsTerminal_*' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if (-not $pkg) {
        throw "Windows Terminal package folder not found under $packages"
    }
    $path = Join-Path $pkg.FullName 'LocalState\settings.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "settings.json not found at $path"
    }
    return $path
}

function Get-ProfileHost {
    param(
        [string]$CommandLine,
        [ValidateSet('ssh', 'https')]
        [string]$Kind
    )
    if ($Kind -eq 'ssh') {
        if ($CommandLine -match 'attacker@(\S+)') { return $Matches[1] }
    } else {
        if ($CommandLine -match 'https://([^"\s]+)') { return $Matches[1] }
    }
    return $null
}

function Set-ProfileHost {
    param(
        [string]$CommandLine,
        [ValidateSet('ssh', 'https')]
        [string]$Kind,
        [string]$HostValue
    )
    if ($Kind -eq 'ssh') {
        return [regex]::Replace($CommandLine, 'attacker@\S+', "attacker@$HostValue")
    }
    return [regex]::Replace($CommandLine, 'https://[^"\s]+', "https://$HostValue")
}

function Normalize-HostValue {
    param(
        [string]$Value,
        [ValidateSet('ssh', 'https')]
        [string]$Kind
    )
    $Value = $Value.Trim()
    if ($Kind -eq 'https') {
        $Value = $Value -replace '^https?://', '' -replace '/$', ''
    }
    return $Value
}

$targets = @(
    [pscustomobject]@{ Name = 'Team Server';  Kind = 'ssh';   Param = 'TeamServer' }
    [pscustomobject]@{ Name = 'RD1';           Kind = 'ssh';   Param = 'RD1' }
    [pscustomobject]@{ Name = 'RD2';           Kind = 'ssh';   Param = 'RD2' }
    [pscustomobject]@{ Name = 'RD3';           Kind = 'ssh';   Param = 'RD3' }
    [pscustomobject]@{ Name = 'Payload';       Kind = 'ssh';   Param = 'Payload' }
    [pscustomobject]@{ Name = 'File Server';   Kind = 'https'; Param = 'FileServer' }
    [pscustomobject]@{ Name = 'Exfil Server';  Kind = 'https'; Param = 'ExfilServer' }
)

$scriptedValues = @{
    TeamServer  = $TeamServer
    RD1         = $RD1
    RD2         = $RD2
    RD3         = $RD3
    Payload     = $Payload
    FileServer  = $FileServer
    ExfilServer = $ExfilServer
}
$hasScriptedArgs = @($scriptedValues.Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0

$settingsPath = Get-TerminalSettingsPath
Write-Host "Settings: $settingsPath" -ForegroundColor Cyan

$raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
$settings = $raw | ConvertFrom-Json
$profiles = @($settings.profiles.list)

function Update-ProfileValue {
    param(
        [pscustomobject]$Target,
        [string]$Value
    )

    $profile = $profiles | Where-Object { $_.name -eq $Target.Name } | Select-Object -First 1
    if (-not $profile) {
        Write-Host "[!] Profile '$($Target.Name)' not found in settings.json - skip" -ForegroundColor Yellow
        return $false
    }
    if (-not $profile.commandline) {
        Write-Host "[!] Profile '$($Target.Name)' has no commandline - skip" -ForegroundColor Yellow
        return $false
    }

    $value = Normalize-HostValue -Value $Value -Kind $Target.Kind
    $profile.commandline = Set-ProfileHost -CommandLine $profile.commandline -Kind $Target.Kind -HostValue $value
    Write-Host "[+] $($Target.Name) -> $($profile.commandline)" -ForegroundColor Green
    return $true
}

function Update-OneInteractive {
    param([pscustomobject]$Target)

    $profile = $profiles | Where-Object { $_.name -eq $Target.Name } | Select-Object -First 1
    if (-not $profile -or -not $profile.commandline) {
        Write-Host "[!] Profile '$($Target.Name)' missing or has no commandline - skip" -ForegroundColor Yellow
        return
    }

    $current = Get-ProfileHost -CommandLine $profile.commandline -Kind $Target.Kind
    $hint = if ($Target.Kind -eq 'ssh') { 'IP or hostname' } else { 'domain or URL host (no https://)' }
    $prompt = "  $($Target.Name) [$hint]"
    if ($current) { $prompt += " (current: $current)" }
    $prompt += ': '

    $value = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "  (unchanged)" -ForegroundColor DarkGray
        return
    }

    [void](Update-ProfileValue -Target $Target -Value $value)
}

function Save-TerminalSettings {
    $jsonOut = $settings | ConvertTo-Json -Depth 100
    $jsonOut = $jsonOut -replace '\\/', '/'

    $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
    Set-Content -LiteralPath $settingsPath -Value $jsonOut -Encoding UTF8 -Force
    Write-Host ""
    Write-Host "Saved $settingsPath" -ForegroundColor Green
    Write-Host "Backup  $backup" -ForegroundColor DarkGray
    Write-Host "Restart Windows Terminal (or open a new window) to pick up changes." -ForegroundColor Cyan
}

if ($hasScriptedArgs) {
    $changed = $false
    foreach ($t in $targets) {
        $val = $scriptedValues[$t.Param]
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        if (Update-ProfileValue -Target $t -Value $val) { $changed = $true }
    }
    if (-not $changed) {
        Write-Host "No matching profiles updated." -ForegroundColor Yellow
        return
    }
    Save-TerminalSettings
    return
}

function Show-Menu {
    Write-Host ""
    Write-Host "Select a profile to update (blank Enter skips when prompted for a host):" -ForegroundColor Magenta
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $t = $targets[$i]
        $p = $profiles | Where-Object { $_.name -eq $t.Name } | Select-Object -First 1
        $current = if ($p) { Get-ProfileHost -CommandLine $p.commandline -Kind $t.Kind } else { '(missing)' }
        Write-Host ("  [{0}] {1,-14}  {2}" -f ($i + 1), $t.Name, $current)
    }
    Write-Host "  [A] Set all"
    Write-Host "  [Q] Quit / save"
}

while ($true) {
    Show-Menu
    $choice = Read-Host 'Choice'
    if ([string]::IsNullOrWhiteSpace($choice)) { continue }

    switch -Regex ($choice.Trim()) {
        '^[Qq]$' { break }
        '^[Aa]$' {
            foreach ($t in $targets) { Update-OneInteractive -Target $t }
        }
        '^\d+$' {
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $targets.Count) {
                Write-Host 'Invalid number.' -ForegroundColor Yellow
                continue
            }
            Update-OneInteractive -Target $targets[$idx]
        }
        default {
            Write-Host 'Invalid choice.' -ForegroundColor Yellow
        }
    }

    if ($choice -match '^[Qq]$') { break }
}

Save-TerminalSettings
