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
summary rather than stopping the run. Stages 1-3 are an exception: any
Failed install keeps the current stage and reboots so the next pass can
detect already-installed packages and retry what is still missing.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host "[RedWindows] starting from $PSCommandPath" -ForegroundColor Cyan

# =============================================================================
# Configuration
# =============================================================================

# TEMPORARY: pause for Enter before each stage reboot. Set $false for unattended runs.
$script:EnableStageBreakpoints = $false

$script:AttackerUsername    = 'attacker'
$script:AttackerPassword    = 'GoCyber2026!!'
$script:RangeAdminUsername  = 'range_admin'
$script:RangeAdminPassword  = '1qaz2wsx!QAZ@WSX'

$script:ToolsRoot       = 'C:\Tools'
$script:PayloadRoot     = 'C:\Payloads'

# =============================================================================
# Library loader
# =============================================================================

# Capture at load time; $PSScriptRoot inside functions is unreliable when dotsourced.
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
    $script:StageHadFailure = $false

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
    Install-VaultEncFile
    Set-UsCentralTimeZone
    Enable-NumLock
}

function Invoke-Stage1 {
    $script:CurrentStage = 1
    $script:StageHadFailure = $false
    Write-Status "`n=== Stage 1: attacker user, autologin, host prep, winget ===" 'Magenta'

    try {
        New-AttackerUser
        Set-AutoLogin

        Disable-WindowsDefender
        Disable-ScreenSaver
        Show-FileExtensions
        Disable-WindowsUpdates
        Install-SshServer
        Set-HighPerformancePowerPlan
        New-RangeAdminUser

        Install-Winget

        Complete-Stage -NextStage 2
    } catch {
        Write-Status "[!] Stage 1 terminating error: $($_.Exception.Message)" 'Red'
        Add-Result -Name 'Stage 1' -Status Failed -Detail $_.Exception.Message
        Restart-CurrentStage -Reason $_.Exception.Message
    }
}

function Invoke-Stage2 {
    $script:CurrentStage = 2
    $script:StageHadFailure = $false
    Write-Status "`n=== Stage 2: install Git, Rust, ChooseNim ===" 'Magenta'

    try {
        Disable-WindowsDefender

        # Git needs a fresh session for PATH; keep it out of Install-AllPackages.
        $null = Install-WingetPackage 'Git'       'Git.Git'
        $null = Install-WingetPackage 'Rust'      'Rustlang.Rustup'
        $null = Install-WingetPackage 'ChooseNim' 'NimLang.ChooseNim'
        $null = Install-WingetPackage 'Python 3.13' 'Python.Python.3.13'
        Add-PythonFirewallRule
        Complete-Stage -NextStage 3
    } catch {
        Write-Status "[!] Stage 2 terminating error: $($_.Exception.Message)" 'Red'
        Add-Result -Name 'Stage 2' -Status Failed -Detail $_.Exception.Message
        Restart-CurrentStage -Reason $_.Exception.Message
    }
}

function Invoke-Stage3 {
    $script:CurrentStage = 3
    $script:StageHadFailure = $false
    Write-Status "`n=== Stage 3: core dev environment (Nim, Python, Go, .NET SDK, VS2022) ===" 'Magenta'

    try {
        Disable-WindowsDefender
        Install-VulnConfig
        Install-ChooseNim
        $null = Install-WingetPackage 'Go' 'GoLang.Go'
        $null = Install-WingetPackage '.NET SDK' 'Microsoft.DotNet.SDK.8'
        $null = Install-WingetPackage 'NuGet' 'Microsoft.NuGet'
        $null = Install-WingetPackage 'Visual Studio 2022 Community' 'Microsoft.VisualStudio.2022.Community'
        Install-Pipx

        Complete-Stage -NextStage 4
    } catch {
        Write-Status "[!] Stage 3 terminating error: $($_.Exception.Message)" 'Red'
        Add-Result -Name 'Stage 3' -Status Failed -Detail $_.Exception.Message
        Restart-CurrentStage -Reason $_.Exception.Message
    }
}

function Invoke-Stage4 {
    $script:CurrentStage = 4
    Write-Status "`n=== Stage 4: VS2022 components, MSYS2, Nim packages, remaining packages ===" 'Magenta'

    Disable-WindowsDefender

    # VS2022 needs the fresh session from Complete-Stage's restart before components install cleanly.
    Install-VS2022Components
    Enable-NetFx35Feature

    Install-Msys2
    Install-MsysToolchain
    Install-NimPackages

    Install-AllPackages
    Install-ConfuseEx
    Install-Client
    New-CombinedBofCna
    Set-QuickAccess
    Set-QuickAccess -Path $script:PayloadRoot
    Set-Background

    Complete-Stage -NextStage 5
}

function Invoke-Stage5 {
    $script:CurrentStage = 5
    Write-Status "`n=== Stage 5: Windows Update, cleanup and finalize ===" 'Magenta'

    Install-WindowsUpdates
    New-SshKeyPair
    Set-SshCopyIdFunction
    Set-VaultEncProfileFunction
    Set-WindowsTerminalConfig
    Set-TerminalHostsProfileFunction
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

# Dot-source lib at script scope; loading inside a function hides helpers from other functions.
$script:RedWindowsLibRoot = Join-Path $script:RedWindowsRoot 'lib'
Write-Host "[RedWindows] loading lib from $script:RedWindowsLibRoot" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $script:RedWindowsLibRoot)) {
    $msg = "RedWindows lib folder not found at '$script:RedWindowsLibRoot'. Copy Desktop\RedWindows\lib and packages.json to C:\Tools\ then re-run."
    Write-Host "[!] $msg" -ForegroundColor Red
    try { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show($msg, 'RedWindows') } catch {}
    throw $msg
}
foreach ($file in (Get-ChildItem -Path $script:RedWindowsLibRoot -Filter '*.ps1' | Sort-Object Name)) {
    . $file.FullName
}
Write-Host "[RedWindows] lib loaded ($((Get-ChildItem $script:RedWindowsLibRoot -Filter '*.ps1').Count) files)" -ForegroundColor Green

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
