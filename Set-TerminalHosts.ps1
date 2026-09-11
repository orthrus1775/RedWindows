#Requires -Version 5.1
<#
.SYNOPSIS
  Create or update RedWindows Windows Terminal profiles.

.DESCRIPTION
  Modifies the current user's settings.json. Built-in profiles (Team Server,
  RD1-RD3, Payload, File Server, Exfil Server) already have guid, icon,
  commandline, and tab title defaults. Pass only the IP or hostname to use
  those defaults. Any extra flag overrides that default for this run:

    Set-TerminalHosts -TeamServer 192.168.10.25
    Set-TerminalHosts -TeamServer 192.168.10.25 -Icon C:\path\to\icon.png

  A new name such as RD4 is not built in, so you must pass -CommandLine
  (and may pass -Guid, -Icon, -TabTitle):

    Set-TerminalHosts -Name RD4 10.0.0.14 -CommandLine 'ssh -i ... attacker@10.0.0.14'

  Existing Terminal-generated profiles (Ubuntu, VS, Azure, Git) are left alone.
  With no parameters, runs an interactive menu.

.EXAMPLE
  Set-TerminalHosts -TeamServer 192.168.10.25
.EXAMPLE
  Set-TerminalHosts -TeamServer 192.168.10.25 -Icon C:\path\to\icon.png
.EXAMPLE
  Set-TerminalHosts -TeamServer 192.168.10.25 -RD1 10.0.0.11 -FileServer files.lab.local
.EXAMPLE
  Set-TerminalHosts -Name RD1 10.0.0.11
.EXAMPLE
  Set-TerminalHosts -Name RD4 10.0.0.14 -CommandLine 'ssh -i C:\Users\attacker\.ssh\id_ed25519 attacker@10.0.0.14' -Icon bug.png
.EXAMPLE
  C:\Tools\Set-TerminalHosts.ps1 -Payload 10.0.0.50 -ExfilServer exfil.lab.local
#>
[CmdletBinding(DefaultParameterSetName = 'Menu')]
param(
    [string]$TeamServer,
    [string]$RD1,
    [string]$RD2,
    [string]$RD3,
    [string]$Payload,
    [string]$FileServer,
    [string]$ExfilServer,

    [string]$Name,

    [Parameter(Position = 0)]
    [Alias('IP')]
    [string]$Destination,

    [string]$CommandLine,
    [string]$Guid,
    [string]$Icon,
    [string]$TabTitle,

    [Parameter(ParameterSetName = 'Menu')]
    [switch]$Interactive,

    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Name $MyInvocation.MyCommand.Path -Full
    return
}

$script:BuiltInNames = @(
    'Team Server'
    'RD1'
    'RD2'
    'RD3'
    'Payload'
    'File Server'
    'Exfil Server'
    'Command Prompt Admin'
)

$script:HostTargets = @(
    [pscustomobject]@{ Name = 'Team Server';  Kind = 'ssh';   Param = 'TeamServer' }
    [pscustomobject]@{ Name = 'RD1';           Kind = 'ssh';   Param = 'RD1' }
    [pscustomobject]@{ Name = 'RD2';           Kind = 'ssh';   Param = 'RD2' }
    [pscustomobject]@{ Name = 'RD3';           Kind = 'ssh';   Param = 'RD3' }
    [pscustomobject]@{ Name = 'Payload';       Kind = 'ssh';   Param = 'Payload' }
    [pscustomobject]@{ Name = 'File Server';   Kind = 'https'; Param = 'FileServer' }
    [pscustomobject]@{ Name = 'Exfil Server';  Kind = 'https'; Param = 'ExfilServer' }
)

function Get-TerminalSettingsPath {
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    $pkg = Get-ChildItem -Path $packages -Directory -Filter 'Microsoft.WindowsTerminal_*' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if (-not $pkg) {
        $pkgPath = Join-Path $packages 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'
        New-Item -ItemType Directory -Path (Join-Path $pkgPath 'LocalState') -Force | Out-Null
        $pkg = Get-Item -LiteralPath $pkgPath
        Write-Host "[!] Windows Terminal package folder not found - created $pkgPath" -ForegroundColor Yellow
    }
    $localState = Join-Path $pkg.FullName 'LocalState'
    if (-not (Test-Path -LiteralPath $localState)) {
        New-Item -ItemType Directory -Path $localState -Force | Out-Null
    }
    return (Join-Path $localState 'settings.json')
}

function Get-SshKeyPath {
    Join-Path $env:USERPROFILE '.ssh\id_ed25519'
}

function Get-PicturesDir {
    Join-Path $env:USERPROFILE 'Pictures'
}

function Set-NoteProperty {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Format-TerminalGuid {
    param([string]$Value)
    $g = [guid]$Value.Trim().Trim('{}')
    return "{$g}"
}

function Get-NewTerminalGuid {
    return ([guid]::NewGuid().ToString('B'))
}

function Resolve-BuiltInName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $aliases = @{
        'TeamServer'           = 'Team Server'
        'Team Server'          = 'Team Server'
        'RD1'                  = 'RD1'
        'RD2'                  = 'RD2'
        'RD3'                  = 'RD3'
        'Payload'              = 'Payload'
        'FileServer'           = 'File Server'
        'File Server'          = 'File Server'
        'ExfilServer'          = 'Exfil Server'
        'Exfil Server'         = 'Exfil Server'
        'CommandPromptAdmin'   = 'Command Prompt Admin'
        'Command Prompt Admin' = 'Command Prompt Admin'
    }
    return $aliases[$Name]
}

function Get-CommandKind {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    if ($CommandLine -match '^\s*ssh\b' -or $CommandLine -match 'attacker@') { return 'ssh' }
    if ($CommandLine -match 'https://') { return 'https' }
    return $null
}

function Get-ProfileHost {
    param(
        [string]$CommandLine,
        [ValidateSet('ssh', 'https')]
        [string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    if ($Kind -eq 'ssh') {
        if ($CommandLine -match 'attacker@(.+)$') {
            $h = $Matches[1].Trim()
            if ($h -match '^(?<ip>\d{1,3}(?:\.\d{1,3}){3})') { return $Matches['ip'] }
            $h = $h -replace '[<>]', ''
            return (($h -split '\s+') | Select-Object -First 1)
        }
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
        return [regex]::Replace($CommandLine, 'attacker@.+$', "attacker@$HostValue")
    }
    return [regex]::Replace($CommandLine, 'https://[^"\s]+', "https://$HostValue")
}

function Set-HostValue {
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

function Resolve-IconPath {
    param([string]$Icon)
    if ([string]::IsNullOrWhiteSpace($Icon)) { return $null }
    if (Test-Path -LiteralPath $Icon) {
        return [System.IO.Path]::GetFullPath($Icon)
    }
    $pictures = Join-Path (Get-PicturesDir) $Icon
    if (Test-Path -LiteralPath $pictures) {
        return [System.IO.Path]::GetFullPath($pictures)
    }
    $root = $PSScriptRoot
    if ($root) {
        $fromLib = Join-Path $root "lib\icons\$Icon"
        if (Test-Path -LiteralPath $fromLib) {
            return [System.IO.Path]::GetFullPath($fromLib)
        }
    }
    $toolsIcon = "C:\Tools\lib\icons\$Icon"
    if (Test-Path -LiteralPath $toolsIcon) {
        return [System.IO.Path]::GetFullPath($toolsIcon)
    }
    return $Icon
}

function Get-FallbackIcon {
    $pictures = Get-PicturesDir
    $preferred = @(
        'server.png'
        'bug.png'
        'bug1.png'
        'malware.png'
        'skull.png'
        'hack.png'
        'folder.ico'
    )
    foreach ($name in $preferred) {
        $path = Join-Path $pictures $name
        if (Test-Path -LiteralPath $path) { return $path }
    }
    $hit = Get-ChildItem -Path $pictures -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '\.(png|ico|jpg|jpeg|gif|svg)$' -and $_.Name -ne 'ubuntu.png' } |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function New-StyledProfile {
    param(
        [string]$Name,
        [string]$Guid,
        [string]$CommandLine,
        [string]$Icon,
        [string]$TabTitle,
        [Nullable[bool]]$Elevate
    )
    $p = [pscustomobject]@{
        altGrAliasing     = $true
        antialiasingMode  = 'grayscale'
        closeOnExit       = 'automatic'
        colorScheme       = 'Campbell'
        commandline       = $CommandLine
        cursorShape       = 'bar'
        font              = [pscustomobject]@{ face = 'Cascadia Mono'; size = 12 }
        guid              = $Guid
        hidden            = $false
        historySize       = 9001
        icon              = $Icon
        name              = $Name
        padding           = '8, 8, 8, 8'
        snapOnInput       = $true
        startingDirectory = '%USERPROFILE%'
        useAcrylic        = $false
    }
    if ($null -ne $Elevate) {
        $p | Add-Member -NotePropertyName elevate -NotePropertyValue ([bool]$Elevate)
    }
    if (-not [string]::IsNullOrWhiteSpace($TabTitle)) {
        $p | Add-Member -NotePropertyName tabTitle -NotePropertyValue $TabTitle
    }
    return $p
}

function Get-BuiltInProfileSpec {
    param([Parameter(Mandatory)][string]$Name)

    $key = Get-SshKeyPath
    $pic = Get-PicturesDir
    $ssh = { param($placeholder) "ssh -i $key attacker@$placeholder" }
    $firefox = { param($url) "powershell.exe -NoExit -Command `"& 'C:\Program Files\Mozilla Firefox\firefox.exe' $url`"" }

    switch ($Name) {
        'Team Server' {
            return [pscustomobject]@{
                Name        = 'Team Server'
                Guid        = '{f9fe7517-78e6-4e16-9ad8-a5da5c55fcf7}'
                Icon        = (Join-Path $pic 'server.png')
                CommandLine = & $ssh '<TeamServerIP>'
                TabTitle    = 'Team Server'
                Styled      = $false
                Elevate     = $null
            }
        }
        'RD1' {
            return [pscustomobject]@{
                Name        = 'RD1'
                Guid        = '{1ef26d6d-0463-4578-f285-a26a34e97bfb}'
                Icon        = (Join-Path $pic 'bug.png')
                CommandLine = & $ssh '<RD1IP>'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $false
            }
        }
        'RD2' {
            return [pscustomobject]@{
                Name        = 'RD2'
                Guid        = '{1ef26d6d-0463-786a-a345-a26a34e97bfb}'
                Icon        = (Join-Path $pic 'bug1.png')
                CommandLine = & $ssh '<RD2IP>'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $false
            }
        }
        'RD3' {
            return [pscustomobject]@{
                Name        = 'RD3'
                Guid        = '{1ef26d6d-0463-7b6a-b466-a26a34e97bfb}'
                Icon        = (Join-Path $pic 'malware.png')
                CommandLine = & $ssh '<RD3IP>'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $false
            }
        }
        'Payload' {
            return [pscustomobject]@{
                Name        = 'Payload'
                Guid        = '{1ef26d6d-0463-45b6-a285-a26a34e97bfb}'
                Icon        = (Join-Path $pic 'skull.png')
                CommandLine = & $ssh '<PayloadIP>'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $false
            }
        }
        'File Server' {
            return [pscustomobject]@{
                Name        = 'File Server'
                Guid        = '{9761a2e2-7948-44f9-a9a0-d56a1e49b8a6}'
                Icon        = (Join-Path $pic 'folder.ico')
                CommandLine = & $firefox 'https://domain_of_file_server.com'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $null
            }
        }
        'Exfil Server' {
            return [pscustomobject]@{
                Name        = 'Exfil Server'
                Guid        = '{9761a2e2-7948-84f9-b9a0-d56c1e49b8a6}'
                Icon        = (Join-Path $pic 'hack.png')
                CommandLine = & $firefox 'https://domain_of_file_exfil_server.com'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $null
            }
        }
        'Command Prompt Admin' {
            return [pscustomobject]@{
                Name        = 'Command Prompt Admin'
                Guid        = '{c06e383f-080a-427d-b2d3-3062541d054e}'
                Icon        = 'ms-appx:///ProfileIcons/{0caa0dad-35be-5f56-a8ff-afceeeaa6101}.png'
                CommandLine = '%SystemRoot%\System32\cmd.exe'
                TabTitle    = $null
                Styled      = $true
                Elevate     = $true
            }
        }
        default { return $null }
    }
}

function Get-BuiltInProfile {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Icon,
        [string]$CommandLine,
        [string]$Guid,
        [string]$TabTitle
    )

    $spec = Get-BuiltInProfileSpec -Name $Name
    if (-not $spec) {
        throw "No built-in defaults for profile '$Name'"
    }

    $iconPath = if (-not [string]::IsNullOrWhiteSpace($Icon)) { Resolve-IconPath $Icon } else { $spec.Icon }
    $cmd = if (-not [string]::IsNullOrWhiteSpace($CommandLine)) { $CommandLine } else { $spec.CommandLine }
    $guidValue = if (-not [string]::IsNullOrWhiteSpace($Guid)) { Format-TerminalGuid $Guid } else { $spec.Guid }
    $title = if (-not [string]::IsNullOrWhiteSpace($TabTitle)) { $TabTitle } else { $spec.TabTitle }

    if ($spec.Styled) {
        return (New-StyledProfile -Name $spec.Name -Guid $guidValue -CommandLine $cmd -Icon $iconPath -TabTitle $title -Elevate $spec.Elevate)
    }

    $profile = [pscustomobject]@{
        commandline = $cmd
        guid        = $guidValue
        hidden      = $false
        icon        = $iconPath
        name        = $spec.Name
    }
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        $profile | Add-Member -NotePropertyName tabTitle -NotePropertyValue $title
    }
    return $profile
}

function Get-CustomProfileHelp {
    param([string]$Name)
    $built = $script:BuiltInNames -join ', '
    return @"
'$Name' is not a built-in profile. Built-in names: $built.

To add it, pass:
  -CommandLine   (required)
  -Guid          (optional; random if omitted)
  -Icon          (optional; Pictures default if omitted)
  -TabTitle      (optional; defaults to -Name)

Example:
  Set-TerminalHosts -Name $Name 10.0.0.14 -CommandLine 'ssh -i $env:USERPROFILE\.ssh\id_ed25519 attacker@10.0.0.14' -Icon bug.png
"@
}

function Get-MinimalTerminalSettings {
    return [pscustomobject]@{
        '$help'          = 'https://aka.ms/terminal-documentation'
        '$schema'        = 'https://aka.ms/terminal-profiles-schema'
        actions          = @()
        copyFormatting   = 'none'
        copyOnSelect     = $false
        defaultProfile   = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
        keybindings      = @(
            [pscustomobject]@{ id = 'Terminal.CopyToClipboard'; keys = 'ctrl+c' }
            [pscustomobject]@{ id = 'Terminal.PasteFromClipboard'; keys = 'ctrl+v' }
            [pscustomobject]@{ id = 'Terminal.DuplicatePaneAuto'; keys = 'alt+shift+d' }
        )
        newTabMenu       = @(
            [pscustomobject]@{ type = 'remainingProfiles' }
        )
        profiles         = [pscustomobject]@{
            defaults = [pscustomobject]@{}
            list     = @()
        }
        schemes          = @()
        themes           = @()
    }
}

function Get-ProfileList {
    param($Settings)
    $list = [System.Collections.Generic.List[object]]::new()
    if ($Settings.profiles -and $Settings.profiles.list) {
        foreach ($p in @($Settings.profiles.list)) {
            [void]$list.Add($p)
        }
    }
    return $list
}

function Find-Profile {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Name
    )
    return $List | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Add-BuiltInProfile {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Name,
        [string]$Icon,
        [string]$CommandLine,
        [string]$Guid,
        [string]$TabTitle
    )
    $existing = Find-Profile -List $List -Name $Name
    if ($existing) {
        Set-ProfileFields -Profile $existing -CommandLine $CommandLine -Guid $Guid -Icon $Icon -TabTitle $TabTitle
        return $existing
    }

    $created = Get-BuiltInProfile -Name $Name -Icon $Icon -CommandLine $CommandLine -Guid $Guid -TabTitle $TabTitle
    [void]$List.Add($created)
    Write-Host "[+] Created '$Name' from built-in defaults" -ForegroundColor Green
    return $created
}

function Set-ProfileFields {
    param(
        $Profile,
        [string]$CommandLine,
        [string]$Guid,
        [string]$Icon,
        [string]$TabTitle,
        [switch]$IsNew,
        [switch]$IsBuiltIn
    )
    if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
        Set-NoteProperty -Object $Profile -Name commandline -Value $CommandLine
    }
    if (-not [string]::IsNullOrWhiteSpace($Guid)) {
        Set-NoteProperty -Object $Profile -Name guid -Value (Format-TerminalGuid $Guid)
    } elseif ($IsNew -and -not $IsBuiltIn) {
        Set-NoteProperty -Object $Profile -Name guid -Value (Get-NewTerminalGuid)
    }
    if (-not [string]::IsNullOrWhiteSpace($Icon)) {
        Set-NoteProperty -Object $Profile -Name icon -Value (Resolve-IconPath $Icon)
    } elseif ($IsNew -and -not $IsBuiltIn -and -not $Profile.icon) {
        $fallback = Get-FallbackIcon
        if ($fallback) {
            Set-NoteProperty -Object $Profile -Name icon -Value $fallback
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($TabTitle)) {
        Set-NoteProperty -Object $Profile -Name tabTitle -Value $TabTitle
    } elseif ($IsNew -and -not $Profile.PSObject.Properties['tabTitle']) {
        Set-NoteProperty -Object $Profile -Name tabTitle -Value $Profile.name
    }
}

function Set-BuiltInHost {
    param(
        $Profile,
        [pscustomobject]$Target,
        [string]$Value
    )
    if (-not $Profile.commandline) {
        throw "Profile '$($Target.Name)' has no commandline"
    }
    $value = Set-HostValue -Value $Value -Kind $Target.Kind
    $Profile.commandline = Set-ProfileHost -CommandLine $Profile.commandline -Kind $Target.Kind -HostValue $value
    Write-Host "[+] $($Target.Name) -> $($Profile.commandline)" -ForegroundColor Green
}

function Apply-DestinationToCommandLine {
    param(
        $Profile,
        [string]$Destination
    )
    if ([string]::IsNullOrWhiteSpace($Destination) -or -not $Profile.commandline) { return }
    $kind = Get-CommandKind -CommandLine $Profile.commandline
    if (-not $kind) { return }
    $value = Set-HostValue -Value $Destination -Kind $kind
    $Profile.commandline = Set-ProfileHost -CommandLine $Profile.commandline -Kind $kind -HostValue $value
}

function Add-NamedProfile {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Name,
        [string]$Destination,
        [string]$CommandLine,
        [string]$Guid,
        [string]$Icon,
        [string]$TabTitle
    )
    $builtInName = Resolve-BuiltInName -Name $Name
    if ($builtInName) {
        $termProfile = Add-BuiltInProfile -List $List -Name $builtInName -Icon $Icon -CommandLine $CommandLine -Guid $Guid -TabTitle $TabTitle
        $target = $script:HostTargets | Where-Object { $_.Name -eq $builtInName } | Select-Object -First 1
        if ($target -and -not [string]::IsNullOrWhiteSpace($Destination)) {
            Set-BuiltInHost -Profile $termProfile -Target $target -Value $Destination
        }
        if (-not [string]::IsNullOrWhiteSpace($CommandLine) -and -not [string]::IsNullOrWhiteSpace($Destination)) {
            Apply-DestinationToCommandLine -Profile $termProfile -Destination $Destination
        }
        return $termProfile
    }

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        throw (Get-CustomProfileHelp -Name $Name)
    }

    $existing = Find-Profile -List $List -Name $Name
    if (-not $existing) {
        $title = if (-not [string]::IsNullOrWhiteSpace($TabTitle)) { $TabTitle } else { $Name }
        $existing = [pscustomobject]@{
            commandline = $CommandLine
            guid        = if (-not [string]::IsNullOrWhiteSpace($Guid)) { Format-TerminalGuid $Guid } else { Get-NewTerminalGuid }
            hidden      = $false
            name        = $Name
            tabTitle    = $title
        }
        $iconValue = if (-not [string]::IsNullOrWhiteSpace($Icon)) {
            Resolve-IconPath $Icon
        } else {
            Get-FallbackIcon
        }
        if ($iconValue) {
            $existing | Add-Member -NotePropertyName icon -NotePropertyValue $iconValue
        }
        Apply-DestinationToCommandLine -Profile $existing -Destination $Destination
        [void]$List.Add($existing)
        Write-Host "[+] Created '$Name'" -ForegroundColor Green
        Write-Host "    $($existing.commandline)" -ForegroundColor DarkGray
        return $existing
    }

    Set-ProfileFields -Profile $existing -CommandLine $CommandLine -Guid $Guid -Icon $Icon -TabTitle $TabTitle -IsNew:$false
    Apply-DestinationToCommandLine -Profile $existing -Destination $Destination
    Write-Host "[+] Updated '$Name'" -ForegroundColor Green
    if ($existing.commandline) {
        Write-Host "    $($existing.commandline)" -ForegroundColor DarkGray
    }
    return $existing
}

$scriptedValues = @{
    TeamServer  = $TeamServer
    RD1         = $RD1
    RD2         = $RD2
    RD3         = $RD3
    Payload     = $Payload
    FileServer  = $FileServer
    ExfilServer = $ExfilServer
}
$hasScriptedHosts = @($scriptedValues.Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
$hasName = -not [string]::IsNullOrWhiteSpace($Name)
$hasDestination = -not [string]::IsNullOrWhiteSpace($Destination)
$hasProfileOverrides = @($CommandLine, $Guid, $Icon, $TabTitle) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if ($hasProfileOverrides -and -not $hasName -and -not $hasScriptedHosts) {
    throw '-TeamServer, -RD1, -RD2, -RD3, -Payload, -FileServer, -ExfilServer, or -Name is required when using -CommandLine, -Guid, -Icon, or -TabTitle'
}
if ($hasDestination -and -not $hasName -and -not $hasScriptedHosts) {
    throw '-Name is required when passing a destination IP without -TeamServer, -RD1, -RD2, -RD3, -Payload, -FileServer, or -ExfilServer'
}

$runMenu = $Interactive -or (-not $hasScriptedHosts -and -not $hasName)

$settingsPath = Get-TerminalSettingsPath
Write-Host "Settings: $settingsPath" -ForegroundColor Cyan

if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Write-Host "[!] settings.json not found - creating a minimal file" -ForegroundColor Yellow
    $settings = Get-MinimalTerminalSettings
}
if (-not $settings.profiles) {
    Set-NoteProperty -Object $settings -Name profiles -Value ([pscustomobject]@{ defaults = [pscustomobject]@{}; list = @() })
}

$profiles = Get-ProfileList -Settings $settings

function Save-TerminalSettings {
    $settings.profiles.list = @($profiles.ToArray())
    $jsonOut = $settings | ConvertTo-Json -Depth 100
    $jsonOut = $jsonOut -replace '\\/', '/'

    if (Test-Path -LiteralPath $settingsPath) {
        $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
        Write-Host "Backup  $backup" -ForegroundColor DarkGray
    }
    Set-Content -LiteralPath $settingsPath -Value $jsonOut -Encoding UTF8 -Force
    Write-Host ""
    Write-Host "Saved $settingsPath" -ForegroundColor Green
    Write-Host "Restart Windows Terminal (or open a new window) to pick up changes." -ForegroundColor Cyan
}

$changed = $false

if ($hasScriptedHosts) {
    foreach ($t in $script:HostTargets) {
        $val = $scriptedValues[$t.Param]
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        $termProfile = Add-BuiltInProfile -List $profiles -Name $t.Name -Icon $Icon -CommandLine $CommandLine -Guid $Guid -TabTitle $TabTitle
        Set-BuiltInHost -Profile $termProfile -Target $t -Value $val
        $changed = $true
    }
}

if ($hasName) {
    [void](Add-NamedProfile -List $profiles -Name $Name -Destination $Destination -CommandLine $CommandLine -Guid $Guid -Icon $Icon -TabTitle $TabTitle)
    $changed = $true
}

if (-not $runMenu) {
    if (-not $changed) {
        Write-Host "No profiles updated." -ForegroundColor Yellow
        return
    }
    Save-TerminalSettings
    return
}

function Update-OneInteractive {
    param([pscustomobject]$Target)

    $termProfile = Find-Profile -List $profiles -Name $Target.Name
    $current = if ($termProfile) { Get-ProfileHost -CommandLine $termProfile.commandline -Kind $Target.Kind } else { $null }
    $hint = if ($Target.Kind -eq 'ssh') { 'IP or hostname' } else { 'domain or URL host (no https://)' }
    $prompt = "  $($Target.Name) [$hint]"
    if ($current) {
        $prompt += " (current: $current)"
    } elseif (-not $termProfile) {
        $prompt += " (will use built-in defaults)"
    }
    $prompt += ': '

    $value = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "  (unchanged)" -ForegroundColor DarkGray
        return
    }

    if (-not $termProfile) {
        $termProfile = Add-BuiltInProfile -List $profiles -Name $Target.Name
    }
    Set-BuiltInHost -Profile $termProfile -Target $Target -Value $value
}

function Show-Menu {
    Write-Host ""
    Write-Host "Select a profile to update (blank Enter skips when prompted for a host):" -ForegroundColor Magenta
    for ($i = 0; $i -lt $script:HostTargets.Count; $i++) {
        $t = $script:HostTargets[$i]
        $p = Find-Profile -List $profiles -Name $t.Name
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
            foreach ($t in $script:HostTargets) { Update-OneInteractive -Target $t }
        }
        '^\d+$' {
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $script:HostTargets.Count) {
                Write-Host 'Invalid number.' -ForegroundColor Yellow
                continue
            }
            Update-OneInteractive -Target $script:HostTargets[$idx]
        }
        default {
            Write-Host 'Invalid choice.' -ForegroundColor Yellow
        }
    }

    if ($choice -match '^[Qq]$') { break }
}

Save-TerminalSettings
