<#
RedWindows.ps1

A lightweight, winget-first alternative to Commando VM's install.ps1.
Commando VM's package feed relies almost entirely on Chocolatey and hasn't
kept pace with newer tool versions. This installs from winget first (real
package IDs verified against the local winget source), falls back to
downloading a prebuilt asset from a tool's GitHub releases, and only falls
back to a git clone + build from source as a last resort.

This is a curated starting set, not full Commando VM/VM-Packages parity -
add more entries to packages.json as needed.

Run elevated from the repo root (RedWindows.ps1 + lib/). Save-SelfCopy
persists the full install tree to C:\Tools\ across stage reboots.
Packages that fail every available tier are skipped and logged in the
summary rather than stopping the run.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# =============================================================================
# Configuration
# =============================================================================

# TEMPORARY: set to $true to pause and require Enter before each stage's reboot,
# so you can validate the box's state before it moves on. Remove before shipping.
$script:EnableStageBreakpoints = $true

$script:AttackerUsername    = 'attacker'
$script:AttackerPassword    = 'GoCyber2026!!'
$script:RangeAdminUsername  = 'range_admin'
$script:RangeAdminPassword  = '1qaz2wsx!QAZ@WSX'

$script:ToolsRoot       = 'C:\Tools'
$script:PayloadRoot     = 'C:\Payloads'

# =============================================================================
# Library loader
# =============================================================================

# Capture at load time - $PSScriptRoot inside functions is unreliable when this
# file is dot-sourced (e.g. Rebuild.ps1) vs run with -File.
$script:RedWindowsRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

# =============================================================================
# Environment + staged install
# =============================================================================

function Initialize-Environment {
    $script:ToolsRoot       = 'C:\Tools'
    $script:PayloadRoot     = 'C:\Payloads'
    $script:cobaltstrike    = Join-Path $script:ToolsRoot 'cobaltstrike'
    $script:UserProfileRoot = $env:USERPROFILE
    $script:AppDataLocal    = Join-Path $script:UserProfileRoot 'AppData\Local'
    $script:GoUserRoot      = Join-Path $script:UserProfileRoot 'go'
    $script:pipxtools       = Join-Path $script:UserProfileRoot '.local'
    $script:DlRoot          = Join-Path $script:ToolsRoot 'downloads'
    $script:BofRoot         = Join-Path $script:ToolsRoot 'BOF'
    $script:SharpToolsRoot  = Join-Path $script:ToolsRoot 'SharpTools'
    $script:NightmareEclipse = Join-Path $script:ToolsRoot 'NightmareEclipse'
    $script:CloudRoot       = Join-Path $script:ToolsRoot 'Cloud'
    $script:PotatoRoot      = Join-Path $script:ToolsRoot 'PotatoFarm'
    $script:NimModsRoot     = Join-Path $script:ToolsRoot 'nimmods'
    $script:LogRoot         = Join-Path $script:ToolsRoot 'logs'
    $script:TranscriptFile  = Join-Path $script:LogRoot 'RedWindows-transcript.log'
    $script:ResultsCsv      = Join-Path $script:LogRoot 'RedWindows-results.csv'
    $script:Results         = New-Object System.Collections.Generic.List[object]
    $script:CurrentStage    = 0

    $allDirs = @(
        $script:ToolsRoot, $script:PayloadRoot, $script:DlRoot, $script:LogRoot,
        $script:BofRoot, $script:SharpToolsRoot, $script:CloudRoot, $script:PotatoRoot, $script:NimModsRoot,
        $script:pipxtools, $script:AppDataLocal, $script:GoUserRoot, $script:NightmareEclipse, $script:cobaltstrike
    )
    foreach ($dir in $allDirs) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    try {
        Start-Transcript -Path $script:TranscriptFile -Append -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "[!] Could not start transcript logging: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Status "`n=== Initializing environment ===" 'Magenta'
    Write-Status "[+] Tools root: $script:ToolsRoot" 'Green'
    Write-Status "[+] Transcript: $script:TranscriptFile" 'Green'
    Write-Status "[+] Results log: $script:ResultsCsv" 'Green'
    Enable-NumLock
}

function Invoke-Stage1 {
    $script:CurrentStage = 1
    Write-Status "`n=== Stage 1: attacker user, autologin, host prep, winget ===" 'Magenta'

    New-AttackerUser
    Set-AutoLogin

    Disable-WindowsDefender
    Disable-ScreenSaver
    Show-FileExtensions
    Disable-WindowsUpdates
    Install-SshServer
    Set-HighPerformancePowerPlan
    New-RangeAdminUser

    Install-WindowsUpdates

    Install-Winget

    Complete-Stage -NextStage 2
}

function Invoke-Stage2 {
    $script:CurrentStage = 2
    Write-Status "`n=== Stage 2: install Git, Rust, ChooseNim ===" 'Magenta'

    Disable-WindowsDefender

    # Git also needs a fresh session for its PATH entry to resolve, so it
    # gets its own stage rather than running inside Install-AllPackages.
    Install-WingetPackage 'Git'       'Git.Git'
    Install-WingetPackage 'Rust'      'Rustlang.Rustup'
    Install-WingetPackage 'ChooseNim' 'NimLang.ChooseNim'
    Install-WingetPackage 'Python 3.13' 'Python.Python.3.13'
    Add-PythonFirewallRule
    Complete-Stage -NextStage 3
}

function Invoke-Stage3 {
    $script:CurrentStage = 3
    Write-Status "`n=== Stage 3: core dev environment (Nim, Python, Go, .NET SDK, VS2022) ===" 'Magenta'

    Disable-WindowsDefender
    Install-VulnConfig
    Install-ChooseNim
    Install-WingetPackage 'Go' 'GoLang.Go'
    Install-WingetPackage '.NET SDK' 'Microsoft.DotNet.SDK.8'
    Install-WingetPackage 'NuGet' 'Microsoft.NuGet'
    Install-WingetPackage 'Visual Studio 2022 Community' 'Microsoft.VisualStudio.2022.Community'
    Install-Pipx

    Complete-Stage -NextStage 4
}

function Invoke-Stage4 {
    $script:CurrentStage = 4
    Write-Status "`n=== Stage 4: VS2022 components, MSYS2, Nim packages, remaining packages ===" 'Magenta'

    Disable-WindowsDefender

    # Runs here rather than in Stage 3 - VS2022 needs the fresh session that Complete-Stage's
    # restart provides before its component installer/ServiceHub will start cleanly.
    Install-VS2022Components
    Enable-NetFx35Feature

    Install-Msys2
    Install-MsysToolchain
    Install-NimPackages

    Install-AllPackages
    Install-ConfuseEx
    Install-Client
    Set-QuickAccess
    Set-QuickAccess -Path $script:PayloadRoot
    Set-Background

    Complete-Stage -NextStage 5
}

function Invoke-Stage5 {
    $script:CurrentStage = 5
    Write-Status "`n=== Stage 5: cleanup and finalize ===" 'Magenta'

    New-SshKeyPair
    Set-SshCopyIdFunction
    Set-Rebuild
    Clear-EventLogs
    Optimize-VmDisk

    Complete-Installation
    try { Stop-Transcript | Out-Null } catch {}
}

function Main {
    Initialize-Environment

    $stage = Get-RedWindowsStage
    Write-Status "`n=== RedWindows: resuming at stage $stage ===" 'Magenta'

    switch ($stage) {
        1 { Invoke-Stage1 }
        2 { Invoke-Stage2 }
        3 { Invoke-Stage3 }
        4 { Invoke-Stage4 }
        5 { Invoke-Stage5 }
        default {
            Write-Status "[!] Unknown stage '$stage' - resetting to stage 1" 'Yellow'
            Set-RedWindowsStage -Stage 1
            Invoke-Stage1
        }
    }
}

# Dot-source lib at *script* scope. Loading from inside a function (or ForEach-Object)
# puts helpers in a child scope, so Initialize-Environment cannot see Write-Status.
$script:RedWindowsLibRoot = Join-Path $script:RedWindowsRoot 'lib'
if (-not (Test-Path -LiteralPath $script:RedWindowsLibRoot)) {
    throw "RedWindows lib folder not found at '$script:RedWindowsLibRoot'. Clone/download the full repo (RedWindows.ps1 + lib/ + packages.json)."
}
foreach ($file in (Get-ChildItem -Path $script:RedWindowsLibRoot -Filter '*.ps1' | Sort-Object Name)) {
    . $file.FullName
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
