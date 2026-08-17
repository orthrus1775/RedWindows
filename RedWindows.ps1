<#
RedWindows.ps1

A lightweight, winget-first alternative to Commando VM's install.ps1.
Commando VM's package feed relies almost entirely on Chocolatey and hasn't
kept pace with newer tool versions. This installs from winget first (real
package IDs verified against the local winget source), falls back to
downloading a prebuilt asset from a tool's GitHub releases, and only falls
back to a git clone + build from source as a last resort.

This is a curated starting set, not full Commando VM/VM-Packages parity -
add more entries to Get-PackageTable as needed.

Standalone script - no dependency on any other file in this repo. Run
elevated. Packages that fail every available tier are skipped and logged
in the summary rather than stopping the run.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# TEMPORARY: set to $true to pause and require Enter before each stage's reboot,
# so you can validate the box's state before it moves on. Remove before shipping.
$script:EnableStageBreakpoints = $true

# =============================================================================
# Logging / result tracking
# =============================================================================

function Write-Status {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Invoke-NativeQuiet {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    # With $ErrorActionPreference = 'Stop' set globally, redirecting a native command's
    # stderr - via 2>&1, 2>$null, OR *>$null, contrary to the belief baked into some of
    # the call sites below that *>$null is safe - wraps each stderr line into a
    # terminating NativeCommandError. Chatty-but-successful tools (pipx's "creating
    # virtual environment...", go's "go: downloading ...", rustup's "info: downloading
    # component ...") then abort the calling function before it ever reaches its own
    # $LASTEXITCODE check. Relax the preference only for the duration of the call so
    # $LASTEXITCODE still reflects the real outcome afterward.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Add-Result {
    param(
        [string]$Name,
        [ValidateSet('Installed', 'Skipped', 'Failed')]
        [string]$Status,
        [string]$Detail = ''
    )
    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Stage     = $script:CurrentStage
        Name      = $Name
        Status    = $Status
        Detail    = $Detail
    }
    $script:Results.Add($entry)

    # Each stage runs in its own process (the script restarts the machine between stages), so
    # $script:Results alone only ever holds the current stage's entries. Appending every result
    # to disk immediately is what lets Show-Summary report on the whole 3-stage run, and lets
    # this file be read back after the fact to diagnose failures.
    if ($script:ResultsCsv) {
        try {
            $entry | Export-Csv -Path $script:ResultsCsv -Append -NoTypeInformation -Force
        } catch {
            Write-Host "[!] Failed to append to results log: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Used verbatim by functions ported in as-is (e.g. New-RangeAdminUser) that
# expect this helper rather than Write-Status.
function Write-StatusMessage {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $color = switch ($Level) {
        'WARNING' { 'Yellow' }
        'ERROR'   { 'Red' }
        default   { 'Cyan' }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}


function Disable-WindowsDefender {
    Write-Status "`n=== Disabling Windows Defender ===" 'Magenta'
    # Best-effort: Tamper Protection (on by default on modern Windows) silently
    # blocks both of these paths if it's enabled - that's expected, not a bug
    # in this script. Turn Tamper Protection off manually first if these no-op.

    try {
        Set-MpPreference -DisableRealtimeMonitoring $true `
                          -DisableBehaviorMonitoring $true `
                          -DisableBlockAtFirstSeen $true `
                          -DisableIOAVProtection $true `
                          -DisableScriptScanning $true `
                          -DisableArchiveScanning $true `
                          -MAPSReporting Disabled `
                          -SubmitSamplesConsent NeverSend `
                          -ErrorAction Stop
        Write-Status "[+] Set-MpPreference applied" 'Green'
    } catch {
        Write-Status "[!] Set-MpPreference failed (likely Tamper Protection): $($_.Exception.Message)" 'Yellow'
    }

    try {
        Add-MpPreference -ExclusionPath $script:ToolsRoot -ErrorAction Stop
        Write-Status "[+] Exclusion added for $script:ToolsRoot" 'Green'
    } catch {
        Write-Status "[!] Add-MpPreference exclusion failed: $($_.Exception.Message)" 'Yellow'
    }
    try {
        Add-MpPreference -ExclusionPath $script:PayloadRoot -ErrorAction Stop
        Write-Status "[+] Exclusion added for $script:PayloadRoot" 'Green'
    } catch {
        Write-Status "[!] Add-MpPreference exclusion failed: $($_.Exception.Message)" 'Yellow'
    }
    try {
        Add-MpPreference -ExclusionPath $script:AppDataLocal -ErrorAction Stop
        Write-Status "[+] Exclusion added for $script:AppDataLocal" 'Green'
    } catch {
        Write-Status "[!] Add-MpPreference exclusion failed: $($_.Exception.Message)" 'Yellow'
    }
    try {
        Add-MpPreference -ExclusionPath $script:GoUserRoot -ErrorAction Stop
        Write-Status "[+] Exclusion added for $script:GoUserRoot" 'Green'
    } catch {
        Write-Status "[!] Add-MpPreference exclusion failed: $($_.Exception.Message)" 'Yellow'
    }
        try {
        Add-MpPreference -ExclusionPath $script:pipxtools -ErrorAction Stop
        Write-Status "[+] Exclusion added for $script:pipxtools" 'Green'
    } catch {
        Write-Status "[!] Add-MpPreference exclusion failed: $($_.Exception.Message)" 'Yellow'
    }
}

function Disable-ScreenSaver {
    Write-Status "[-] [Screensaver] disabling" 'Cyan'
    try {
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveActive -Value 0 -Type DWord
        powercfg -x -monitor-timeout-ac 0
        powercfg -x -monitor-timeout-dc 0
        Write-Status "[+] [Screensaver] disabled" 'Green'
        Add-Result -Name 'Screensaver' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Screensaver] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Screensaver' -Status Skipped -Detail $_.Exception.Message
    }
}

function Show-FileExtensions {
    Write-Status "[-] [File extensions] enabling" 'Cyan'
    try {
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0 -Type DWord
        Write-Status "[+] [File extensions] enabled" 'Green'
        Add-Result -Name 'File extensions' -Status Installed -Detail 'HideFileExt=0'
    } catch {
        Write-Status "[!] [File extensions] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'File extensions' -Status Skipped -Detail $_.Exception.Message
    }
}

function Set-QuickAccess {
    param(
        [string]$Path = $script:ToolsRoot
    )

    Write-Status "[-] [Quick Access] pinning $Path" 'Cyan'
    try {
        if (-not (Test-Path $Path)) {
            Write-Status "[!] [Quick Access] $Path does not exist - skipping" 'Yellow'
            Add-Result -Name 'Quick Access' -Status Skipped -Detail "$Path not found"
            return
        }

        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace($Path).Self.InvokeVerb('pintohome')

        Write-Status "[+] [Quick Access] pinned $Path" 'Green'
        Add-Result -Name 'Quick Access' -Status Installed -Detail $Path
    } catch {
        Write-Status "[!] [Quick Access] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Quick Access' -Status Skipped -Detail $_.Exception.Message
    }
}

function Set-Background {
    # Pulled from the repo rather than shipped alongside the script - matches this
    # script's standalone/no-local-dependency design (Save-SelfCopy only persists
    # RedWindows.ps1 itself across stage reboots, not other repo files).
    $imageUrl  = 'https://raw.githubusercontent.com/orthrus1775/RedWindows/main/Background.png'
    $imageDir  = Join-Path $env:USERPROFILE 'Documents'
    $imagePath = Join-Path $imageDir 'Background.png'

    Write-Status "[-] [Background] downloading $imageUrl" 'Cyan'
    try {
        if (-not (Test-Path $imageDir)) {
            New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
        }
        Invoke-WebRequest -Uri $imageUrl -OutFile $imagePath -UseBasicParsing
    } catch {
        Write-Status "[!] [Background] download failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Background' -Status Skipped -Detail $_.Exception.Message
        return
    }

    try {
        Add-Type -Namespace RedWindows -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@ -ErrorAction SilentlyContinue

        # WallpaperStyle 10 = Fill - avoids a stretched/tiled look regardless of the image's
        # native resolution vs. the target's display resolution.
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

        $SPI_SETDESKWALLPAPER = 0x0014
        $SPIF_UPDATEINIFILE   = 0x01
        $SPIF_SENDCHANGE      = 0x02
        [RedWindows.Wallpaper]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $imagePath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE) | Out-Null

        Write-Status "[+] [Background] wallpaper set to $imagePath" 'Green'
        Add-Result -Name 'Background' -Status Installed -Detail $imagePath
    } catch {
        Write-Status "[!] [Background] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Background' -Status Skipped -Detail $_.Exception.Message
    }
}

function Disable-WindowsUpdates {
    Write-Status "[-] [Windows Update] disabling automatic updates" 'Cyan'
    try {
        $updates = (New-Object -ComObject 'Microsoft.Update.AutoUpdate').Settings
        if ($updates.ReadOnly) {
            Write-Status "[!] [Windows Update] settings are read-only (GPO-restricted) - skipping" 'Yellow'
            Add-Result -Name 'Windows Update' -Status Skipped -Detail 'read-only (GPO restricted)'
            return
        }

        $updates.NotificationLevel = 1 # Disabled
        $updates.Save()
        $updates.Refresh()
        Write-Status "[+] [Windows Update] automatic updates disabled" 'Green'
        Add-Result -Name 'Windows Update' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Windows Update] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Windows Update' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-SshServer {
    Write-Status "[-] [OpenSSH Server] checking capability" 'Cyan'
    try {
        $serverCap = Get-WindowsCapability -Online | Where-Object Name -eq 'OpenSSH.Server~~~~0.0.1.0'
        if ($serverCap.State -ne 'Installed') {
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
        }

        Start-Service sshd
        Set-Service -Name sshd -StartupType Automatic

        if (!(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        }

        Write-Status "[+] [OpenSSH Server] installed and running" 'Green'
        Add-Result -Name 'OpenSSH Server' -Status Installed -Detail 'capability + sshd + firewall rule'
    } catch {
        Write-Status "[!] [OpenSSH Server] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'OpenSSH Server' -Status Skipped -Detail $_.Exception.Message
    }
}

function Add-PythonFirewallRule {
    Write-Status "[-] [Python firewall] adding Private/Public allow rules" 'Cyan'
    try {
        # Same PATH-staleness issue as Install-PipPackage - Python was just installed via
        # winget earlier in this same Stage 3 process.
        Update-SessionPath
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) {
            Write-Status "[!] [Python firewall] python is not on PATH - skipping" 'Yellow'
            Add-Result -Name 'Python firewall' -Status Skipped -Detail 'python not on PATH'
            return
        }

        if (!(Get-NetFirewallRule -Name 'Python-In-PrivatePublic' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'Python-In-PrivatePublic' -DisplayName 'Python' -Enabled True -Direction Inbound -Profile Private,Public -Program $python.Source -Action Allow | Out-Null
        }
        if (!(Get-NetFirewallRule -Name 'Python-Out-PrivatePublic' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'Python-Out-PrivatePublic' -DisplayName 'Python' -Enabled True -Direction Outbound -Profile Private,Public -Program $python.Source -Action Allow | Out-Null
        }

        Write-Status "[+] [Python firewall] rules added" 'Green'
        Add-Result -Name 'Python firewall' -Status Installed -Detail "allow $($python.Source) (Private,Public)"
    } catch {
        Write-Status "[!] [Python firewall] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Python firewall' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-WindowsUpdates {
    Write-Status "[-] [Windows Update] checking for updates" 'Cyan'
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
        }
        Import-Module PSWindowsUpdate

        # -IgnoreReboot, not -AutoReboot - Complete-Stage restarts once the rest of Stage 1
        # (attacker user, autologin, winget, etc.) has finished, not the moment updates land.
        Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false | Out-Null

        Write-Status "[+] [Windows Update] updates installed" 'Green'
        Add-Result -Name 'Windows Update' -Status Installed -Detail 'PSWindowsUpdate: Install-WindowsUpdate -AcceptAll'
    } catch {
        Write-Status "[!] [Windows Update] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Windows Update' -Status Skipped -Detail $_.Exception.Message
    }
}

function Set-HighPerformancePowerPlan {
    Write-Status "[-] [Power plan] setting high performance" 'Cyan'
    try {
        $highPerf = powercfg -l | ForEach-Object { if ($_.Contains('Ultimate Performance')) { $_.Split()[3] } }
        if (-not $highPerf) {
            $highPerf = powercfg -l | ForEach-Object { if ($_.Contains('High performance')) { $_.Split()[3] } }
        }

        $currPlan = $(powercfg -getactivescheme).Split()[3]
        if ($highPerf -and $currPlan -ne $highPerf) {
            powercfg -setactive $highPerf
        }

        powercfg -change -monitor-timeout-ac 0
        powercfg -change -monitor-timeout-dc 0
        powercfg -change -standby-timeout-ac 0
        powercfg -change -standby-timeout-dc 0
        powercfg -change hibernate-timeout-ac 0
        powercfg -change hibernate-timeout-dc 0

        Write-Status "[+] [Power plan] set to high performance" 'Green'
        Add-Result -Name 'Power plan' -Status Installed -Detail 'high performance'
    } catch {
        Write-Status "[!] [Power plan] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Power plan' -Status Skipped -Detail $_.Exception.Message
    }
}

function New-RangeAdminUser {
    Write-StatusMessage "Creating range_admin user..."

    $Password = ConvertTo-SecureString -String "1qaz2wsx!QAZ@WSX" -AsPlainText -Force
    $Username = "range_admin"

    try {
        # Check if user already exists
        $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-StatusMessage "User $Username already exists, skipping creation" "WARNING"
            return
        }

        # Create the user
        New-LocalUser $Username -Password $Password -FullName "Range Admin" -Description "Range Engineering User"
        Write-StatusMessage "User $Username created successfully"

        # Add to Administrators group
        Add-LocalGroupMember -Group "Administrators" -Member $Username
        Write-StatusMessage "User $Username added to Administrators group"
    }
    catch {
        Write-StatusMessage "Error creating user $Username : $_" "ERROR"
    }
}

function New-AttackerUser {
    Write-Status "[-] [attacker user] creating local user" 'Cyan'

    $username = 'attacker'
    $password = ConvertTo-SecureString -String 'GoCyber2026!!' -AsPlainText -Force

    try {
        $existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-Status "[+] [attacker user] already exists, skipping creation" 'DarkGray'
            Add-Result -Name 'attacker user' -Status Installed -Detail 'already present'
            return
        }

        New-LocalUser $username -Password $password -FullName 'Attacker' -Description 'Red team operator user' | Out-Null
        Write-Status "[+] [attacker user] created" 'Green'

        Add-LocalGroupMember -Group 'Administrators' -Member $username
        Write-Status "[+] [attacker user] added to Administrators group" 'Green'

        Add-Result -Name 'attacker user' -Status Installed -Detail 'local user + Administrators'
    } catch {
        Write-Status "[!] [attacker user] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'attacker user' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-Autologon {
    # Downloaded directly rather than via the winget-installed Sysinternals
    # Suite package - this needs to work in Stage 1, before winget is
    # guaranteed usable in the current session.
    $autologonDir = Join-Path $script:ToolsRoot 'SysInternals'
    $autologonExe = Join-Path $autologonDir 'Autologon64.exe'

    if (Test-Path $autologonExe) {
        return $autologonExe
    }

    New-Item -ItemType Directory -Path $autologonDir -Force | Out-Null
    $zipPath = Join-Path $script:DlRoot 'AutoLogon.zip'

    Write-Status "[-] [Autologon] downloading Sysinternals AutoLogon" 'Cyan'
    try {
        Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/AutoLogon.zip' -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $autologonDir -Force
        Write-Status "[+] [Autologon] extracted to $autologonDir" 'Green'
        return $autologonExe
    } catch {
        Write-Status "[!] [Autologon] download/extract failed: $($_.Exception.Message)" 'Yellow'
        return $null
    }
}

function Set-AutoLogin {
    Write-Status "[-] [Auto-login] configuring for attacker user" 'Cyan'

    $autologonExe = Install-Autologon
    if (-not $autologonExe -or -not (Test-Path $autologonExe)) {
        Write-Status "[!] [Auto-login] Autologon64.exe unavailable - skipping" 'Yellow'
        Add-Result -Name 'Auto-login' -Status Skipped -Detail 'Autologon64.exe unavailable'
        return
    }

    try {
        & $autologonExe attacker . 'GoCyber2026!!' /accepteula | Out-Null
        Write-Status "[+] [Auto-login] configured for 'attacker'" 'Green'
        Add-Result -Name 'Auto-login' -Status Installed -Detail 'attacker'
    } catch {
        Write-Status "[!] [Auto-login] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Auto-login' -Status Skipped -Detail $_.Exception.Message
    }
}

function Disable-AutoLogin {
    Write-Status "[-] [Auto-login] disabling for attacker user" 'Cyan'
    try {
        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '0' -ErrorAction Stop
        # Autologon64.exe stashes the plaintext password here - clear it now that
        # auto-login is no longer needed, rather than leaving it on disk indefinitely.
        Remove-ItemProperty -Path $winlogonPath -Name DefaultPassword -ErrorAction SilentlyContinue

        Write-Status "[+] [Auto-login] disabled" 'Green'
        Add-Result -Name 'Auto-login' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Auto-login] disable failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Auto-login' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-Winget {
    Write-Status "[-] [winget] checking for existing installation" 'Cyan'

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $existing = winget --version 2>$null
        if ($existing) {
            Write-Status "[+] [winget] already installed ($existing)" 'DarkGray'
            Add-Result -Name 'winget' -Status Installed -Detail 'already present'
            return
        }
    }

    Write-Status "[-] [winget] not found, installing" 'Cyan'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'

        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
        Repair-WinGetPackageManager -AllUsers

        $verify = winget --version 2>$null
        if ($verify) {
            Write-Status "[+] [winget] installed ($verify)" 'Green'
            Add-Result -Name 'winget' -Status Installed -Detail $verify
        } else {
            Write-Status "[!] [winget] installed but not yet resolvable in this session - expected, resolves after restart" 'Yellow'
            Add-Result -Name 'winget' -Status Installed -Detail 'installed, pending restart'
        }
    } catch {
        Write-Status "[!] [winget] install failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'winget' -Status Skipped -Detail $_.Exception.Message
    }
}

# =============================================================================
# Staging / continuation across reboots
# =============================================================================

function Get-RedWindowsStage {
    $stageFile = Join-Path $script:ToolsRoot '.redwindows-stage'
    if (Test-Path $stageFile) {
        return [int](Get-Content $stageFile -Raw).Trim()
    }
    return 1
}

function Set-RedWindowsStage {
    param(
        [int]$Stage
    )
    $stageFile = Join-Path $script:ToolsRoot '.redwindows-stage'
    Set-Content -Path $stageFile -Value $Stage -Force
}

function Save-SelfCopy {
    $persistentPath = Join-Path $script:ToolsRoot 'RedWindows.ps1'
    if ($PSCommandPath -and $PSCommandPath -ne $persistentPath) {
        Copy-Item -Path $PSCommandPath -Destination $persistentPath -Force
    }
    return $persistentPath
}

function Register-ContinuationTask {
    param(
        [string]$ScriptPath
    )

    Write-Status "[-] [Continuation task] registering RedWindowsContinue" 'Cyan'
    try {
        $taskName = 'RedWindowsContinue'
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -NoExit -File `"$ScriptPath`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User 'attacker'
        $principal = New-ScheduledTaskPrincipal -UserId 'attacker' -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Resumes RedWindows.ps1 staged install' | Out-Null
        Write-Status "[+] [Continuation task] registered" 'Green'
    } catch {
        Write-Status "[!] [Continuation task] failed: $($_.Exception.Message)" 'Yellow'
    }
}

function Unregister-ContinuationTask {
    try {
        if (Get-ScheduledTask -TaskName 'RedWindowsContinue' -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName 'RedWindowsContinue' -Confirm:$false
        }
    } catch {
        Write-Status "[!] [Continuation task] cleanup failed: $($_.Exception.Message)" 'Yellow'
    }
}

function Wait-ForStageBreakpoint {
    param(
        [string]$Message = 'Validate the box, then press Enter to restart...'
    )
    if ($script:EnableStageBreakpoints) {
        Write-Status "[?] [Breakpoint] $Message" 'Yellow'
        Read-Host | Out-Null
    }
}

function Clear-EventLogs {
    Write-Status "[-] [Event logs] clearing" 'Cyan'
    try {
        $logs = Get-WinEvent -ListLog * -Force -ErrorAction SilentlyContinue
        $cleared = 0
        $failed = 0
        foreach ($log in $logs) {
            # Some logs (e.g. disabled channels, ones with retention locks) refuse to clear.
            # With $ErrorActionPreference = 'Stop' set globally, wevtutil's stderr for those
            # becomes a terminating error even through 2>$null - Invoke-NativeQuiet relaxes
            # that for the call so a single uncooperative log doesn't abort the whole loop.
            Invoke-NativeQuiet { wevtutil.exe cl "$($log.LogName)" *>$null }
            if ($LASTEXITCODE -eq 0) { $cleared++ } else { $failed++ }
        }

        $historyPath = (Get-PSReadLineOption).HistorySavePath
        if ($historyPath -and (Test-Path $historyPath)) {
            Remove-Item -Path $historyPath -Force -ErrorAction SilentlyContinue
        }
        Clear-History -ErrorAction SilentlyContinue

        Write-Status "[+] [Event logs] cleared $cleared/$($logs.Count) logs ($failed could not be cleared), PowerShell history removed" 'Green'
        Add-Result -Name 'Event logs' -Status Installed -Detail "cleared $cleared/$($logs.Count)"
    } catch {
        Write-Status "[!] [Event logs] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Event logs' -Status Skipped -Detail $_.Exception.Message
    }
}

function Optimize-VmDisk {
    $vmwareToolboxCmd = 'C:\Program Files\VMware\VMware Tools\VMwareToolboxCmd.exe'

    Write-Status "[-] [Disk shrink] running VMwareToolboxCmd disk shrink C:\" 'Cyan'
    try {
        if (-not (Test-Path $vmwareToolboxCmd)) {
            Write-Status "[!] [Disk shrink] $vmwareToolboxCmd not found - is VMware Tools installed?" 'Yellow'
            Add-Result -Name 'Disk shrink' -Status Skipped -Detail "$vmwareToolboxCmd not found"
            return $false
        }

        # Capture output (incl. stderr) rather than letting it stream straight to the
        # transcript - under the global $ErrorActionPreference = 'Stop', stderr text would
        # otherwise throw before $LASTEXITCODE is even checked, and without capturing it
        # the actual reason for a failure (e.g. shrink disabled in the vmx) only lives in
        # the transcript instead of the results log.
        $output = (Invoke-NativeQuiet { & $vmwareToolboxCmd disk shrink C:\ 2>&1 } | Out-String).Trim()
        if ($output) { Write-Status $output 'DarkGray' }
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Disk shrink] exited with code $LASTEXITCODE" 'Yellow'
            Add-Result -Name 'Disk shrink' -Status Skipped -Detail "exit ${LASTEXITCODE}: $($output -replace '\s+', ' ')"
            return $false
        }

        Write-Status "[+] [Disk shrink] completed" 'Green'
        Add-Result -Name 'Disk shrink' -Status Installed -Detail 'VMwareToolboxCmd disk shrink C:\'
        return $true
    } catch {
        Write-Status "[!] [Disk shrink] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Disk shrink' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Complete-Installation {
    Unregister-ContinuationTask
    Disable-AutoLogin
    Remove-LocalSupportUser
    Show-Summary
    Start-Sleep -Seconds 300
    Write-Status "`n=== Installation complete - final restart ===" 'Magenta'
    Wait-ForStageBreakpoint
    Start-Sleep -Seconds 300
    Restart-Computer -Force
}

function Complete-Stage {
    param(
        [int]$NextStage
    )

    $selfPath = Save-SelfCopy
    Set-RedWindowsStage -Stage $NextStage
    Register-ContinuationTask -ScriptPath $selfPath

    Write-Status "`n=== Stage complete - restarting to continue as stage $NextStage ===" 'Magenta'
    # Flush the transcript to disk before the forced restart kills this process - the next
    # stage's Start-Transcript -Append picks back up in the same file.
    try { Stop-Transcript | Out-Null } catch {}
    Wait-ForStageBreakpoint -Message "Validate stage before continuing to stage $NextStage, then press Enter to restart..."
    Start-Sleep -Seconds 30
    Restart-Computer -Force
}

# =============================================================================
# Tier 1: winget
# =============================================================================

function Install-WingetPackage {
    param(
        [string]$Name, 
        [string]$Id
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] winget is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] winget install $Id" 'Cyan'

    $existing = winget list --id $Id --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing -match [regex]::Escape($Id)) {
        Write-Status "[+] [$Name] already installed" 'DarkGray'
        Add-Result -Name $Name -Status Installed -Detail 'already present'
        return $true
    }

    # Piped to Out-Host rather than left bare - winget's install output is otherwise
    # unsuppressed stdout, which becomes part of THIS function's own return value. A
    # multi-element array is always truthy in PowerShell regardless of its contents, so
    # Install-AllPackages's `if (& $tier)` would then see [<winget output>, $false] and
    # read it as success even when the install actually failed below.
    winget install --id $Id -e --accept-source-agreements --accept-package-agreements | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Status "[+] [$Name] installed via winget" 'Green'
        Add-Result -Name $Name -Status Installed -Detail "winget:$Id"
        return $true
    }

    Write-Status "[!] [$Name] winget install failed (exit $LASTEXITCODE)" 'Yellow'
    return $false
}

# =============================================================================
# Tier 2: GitHub release asset download
# =============================================================================

function Get-GitHubReleaseAsset {
    param(
        [string]$Name,
        [string]$Repo,          # "owner/repo"
        [string]$AssetPattern,  # wildcard match against release asset file names
        [string]$Tag            # optional - a specific tag instead of the latest release
    )

    $uri = if ($Tag) {
        "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    } else {
        "https://api.github.com/repos/$Repo/releases/latest"
    }

    Write-Status "[-] [$Name] resolving release for $Repo $(if ($Tag) { "(tag: $Tag)" })" 'Cyan'
    try {
        $release = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'RedWindows-installer' }
    } catch {
        Write-Status "[!] [$Name] could not query GitHub releases: $($_.Exception.Message)" 'Yellow'
        return $null
    }

    $asset = $release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    if (-not $asset) {
        Write-Status "[!] [$Name] no release asset matching '$AssetPattern'" 'Yellow'
        return $null
    }

    return $asset
}

function Get-7ZipPath {
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (Test-Path $sevenZip) { return $sevenZip }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-GitHubReleaseAsset {
    param(
        [string]$Name,
        [string]$Repo,          # "owner/repo"
        [string]$AssetPattern,  # wildcard match against release asset file names
        [string]$Tag,           # optional - a specific tag instead of the latest release
        [switch]$ExtractZip,
        # For .7z assets - Expand-Archive can't touch these, so shell out to 7-Zip
        # (installed elsewhere in Get-PackageTable) instead.
        [switch]$Extract7z
    )

    $asset = Get-GitHubReleaseAsset -Name $Name -Repo $Repo -AssetPattern $AssetPattern -Tag $Tag
    if (-not $asset) { return $false }

    $destFile = Join-Path $script:DlRoot $asset.name
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $destFile -UseBasicParsing
    } catch {
        Write-Status "[!] [$Name] download failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $destDir = Join-Path $script:ToolsRoot $Name
    if ($Extract7z) {
        $sevenZip = Get-7ZipPath
        if (-not $sevenZip) {
            Write-Status "[!] [$Name] downloaded but 7-Zip is not available - install 7-Zip to extract this" 'Yellow'
            return $false
        }
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        & $sevenZip x $destFile "-o$destDir" -y *>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$Name] 7z extraction failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
    } elseif ($ExtractZip) {
        try {
            Expand-Archive -Path $destFile -DestinationPath $destDir -Force
        } catch {
            Write-Status "[!] [$Name] extraction failed: $($_.Exception.Message)" 'Yellow'
            return $false
        }
    } else {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -Path $destFile -Destination $destDir -Force
    }

    Write-Status "[+] [$Name] downloaded $($asset.name) -> $destDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "github-release:$Repo/$($asset.name)"
    return $true
}

# =============================================================================
# Tier 3: git clone + build from source
# =============================================================================

function Find-MSBuildExe {
    # vswhere ships with every VS2022 install (fixed path regardless of edition/locale) -
    # use it to find the real Framework-hosted MSBuild.exe, which Fody-weaved legacy
    # projects need (dotnet build hosts MSBuild on .NET Core and can't load Fody's
    # Framework-only task assemblies, e.g. Mono.Cecil).
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $msbuildPath = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
        if ($msbuildPath -and (Test-Path $msbuildPath)) { return $msbuildPath }
    }
    $fallback = 'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\bin\MSBuild.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Find-VsDevCmd {
    # cl.exe/link.exe are never on PATH by default - they only resolve once VsDevCmd.bat has
    # run and populated INCLUDE/LIB/PATH for the MSVC toolchain. Locate it the same way as
    # Find-MSBuildExe, but require the actual C++ workload (a VS install can have MSBuild
    # without the VC.Tools component, e.g. a .NET-only install).
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
        if ($installPath) {
            $vsDevCmd = Join-Path $installPath 'Common7\Tools\VsDevCmd.bat'
            if (Test-Path $vsDevCmd) { return $vsDevCmd }
        }
    }
    $fallback = 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Invoke-InVsDevShell {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string]$Command,
        [string]$Arch = 'x64'
    )

    $vsDevCmd = Find-VsDevCmd
    if (-not $vsDevCmd) {
        Write-Status "[!] VsDevCmd.bat not found - install the 'Desktop development with C++' VS workload" 'Yellow'
        return $false
    }

    # PowerShell can't source a .bat's environment changes directly - chain the cd, the
    # VsDevCmd.bat call, and the actual build command into one cmd.exe invocation so the
    # build command inherits the INCLUDE/LIB/PATH that VsDevCmd.bat sets up.
    $cmdLine = "cd /d `"$WorkingDirectory`" && call `"$vsDevCmd`" -arch=$Arch -no_logo && $Command"
    cmd.exe /c $cmdLine
    return ($LASTEXITCODE -eq 0)
}

function Register-NuGetOrgSource {
    $existing = dotnet nuget list source 2>$null
    if ($existing -match 'nuget\.org') { return }

    Write-Status "[-] [NuGet] registering nuget.org package source" 'Cyan'
    dotnet nuget add source 'https://api.nuget.org/v3/index.json' -n nuget.org *>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [NuGet] failed to register nuget.org source" 'Yellow'
    }
}

function Add-LegacyReferenceAssemblies {
    param(
        [string]$CloneDir
    )

    $packMap = @{
        'v3.5'   = 'net35'
        'v4.0'   = 'net40'
        'v4.5'   = 'net45'
        'v4.5.1' = 'net451'
        'v4.5.2' = 'net452'
        'v4.6'   = 'net46'
        'v4.6.1' = 'net461'
        'v4.6.2' = 'net462'
        'v4.7'   = 'net47'
        'v4.7.1' = 'net471'
        'v4.7.2' = 'net472'
        'v4.8'   = 'net48'
        'v4.8.1' = 'net481'
    }
    $refVersion = '1.0.3'

    try {
        Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw
            if ($content -match 'Microsoft\.NETFramework\.ReferenceAssemblies') { return }

            $tfvMatch = [regex]::Match($content, '<TargetFrameworkVersion>(v[\d\.]+)</TargetFrameworkVersion>')
            if (-not $tfvMatch.Success) { return }
            $tfm = $packMap[$tfvMatch.Groups[1].Value]
            if (-not $tfm) { return }

            $packageId = "Microsoft.NETFramework.ReferenceAssemblies.$tfm"
            $itemGroup = @"
  <ItemGroup>
    <PackageReference Include="$packageId" Version="$refVersion">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers</IncludeAssets>
    </PackageReference>
  </ItemGroup>

"@
            $closeTagIndex = $content.LastIndexOf('</Project>')
            if ($closeTagIndex -lt 0) { return }
            Set-Content -Path $_.FullName -Value $content.Insert($closeTagIndex, $itemGroup) -NoNewline
            Write-Status "[-] [$($_.BaseName)] pinned to $($tfvMatch.Groups[1].Value) - added $packageId reference" 'DarkGray'
        }
    } catch {
        Write-Status "[!] legacy reference-assemblies patch failed: $($_.Exception.Message)" 'Yellow'
    }
}

function Repair-WinRTHintPaths {
    param(
        [string]$CloneDir
    )

    # Some tools (e.g. SharpClipHistory) hardcode a HintPath to a specific Windows SDK
    # WinRT contract version (Windows Kits\10\References\<sdkver>\<contract>\<cver>\...winmd).
    # If that exact SDK isn't installed, the reference silently fails to resolve and the
    # build picks up a conflicting WinRT projection elsewhere, causing a type-forwarder
    # cycle. Repoint stale HintPaths at whatever contract version is actually installed.
    $refRoot = 'C:\Program Files (x86)\Windows Kits\10\References'
    if (-not (Test-Path $refRoot)) { return }

    $pattern = 'Windows Kits\\10\\References\\(?<sdkver>[\d.]+)\\(?<contract>[\w.]+)\\(?<cver>[\d.]+)\\(?<contract2>[\w.]+)\.winmd'
    $installedSdkDirs = Get-ChildItem -Path $refRoot -Directory -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Name } -Descending

    try {
        Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw
            $changed = $false

            foreach ($match in [regex]::Matches($content, $pattern)) {
                $sdkver    = $match.Groups['sdkver'].Value
                $contract  = $match.Groups['contract'].Value
                $cver      = $match.Groups['cver'].Value
                $contract2 = $match.Groups['contract2'].Value
                $oldSuffix = "$sdkver\$contract\$cver\$contract2.winmd"

                if (Test-Path (Join-Path $refRoot $oldSuffix)) { continue }

                $newSuffix = $null
                foreach ($sdkDir in $installedSdkDirs) {
                    $contractDir = Join-Path $sdkDir.FullName $contract
                    if (-not (Test-Path $contractDir)) { continue }
                    $bestVer = Get-ChildItem -Path $contractDir -Directory -ErrorAction SilentlyContinue |
                        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
                    if (-not $bestVer) { continue }
                    if (Test-Path (Join-Path $bestVer.FullName "$contract2.winmd")) {
                        $newSuffix = "$($sdkDir.Name)\$contract\$($bestVer.Name)\$contract2.winmd"
                        break
                    }
                }

                if (-not $newSuffix) {
                    Write-Status "[!] [$($_.BaseName)] no installed SDK provides $contract - build may fail" 'Yellow'
                    continue
                }

                $content = $content.Replace($oldSuffix, $newSuffix)
                $changed = $true
                Write-Status "[-] [$($_.BaseName)] $contract`: $sdkver -> $(($newSuffix -split '\\')[0])" 'DarkGray'
            }

            if ($changed) {
                Set-Content -Path $_.FullName -Value $content -NoNewline
            }
        }
    } catch {
        Write-Status "[!] WinRT HintPath repair failed: $($_.Exception.Message)" 'Yellow'
    }
}

function Test-HasLegacyPackageReferences {
    param(
        [string]$CloneDir
    )

    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match '\\packages\\[A-Za-z0-9_.\-]+?\.\d+\.\d+\.\d+'
    })
}

function Test-HasComReferences {
    param(
        [string]$CloneDir
    )

    # <COMReference> (the ResolveComReference task, e.g. SharpRDP's MSTSCLib ActiveX
    # reference) can't run under dotnet build's .NET-Core-hosted MSBuild either.
    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match '<COMReference\b'
    })
}

function Test-HasResxResources {
    param(
        [string]$CloneDir
    )

    # The classic GenerateResource task needs an x86 task host that dotnet build's
    # .NET-Core-hosted MSBuild can't spawn (e.g. Whisker's DSInternals Resources.resx),
    # regardless of the project's own PlatformTarget.
    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match '<EmbeddedResource\b[^>]*\.resx"'
    })
}

function Test-IsClassicProject {
    param(
        [string]$CloneDir
    )

    # Old-style (non-SDK) .csproj files are far more reliable under the real Framework
    # MSBuild.exe than dotnet build's SDK-hosted MSBuild, which has repeatedly shown gaps
    # for these beyond the specific patterns above - e.g. ThreatCheck's plain
    # <PackageReference> resolved into project.assets.json fine but never made it onto
    # the compile line under `dotnet build`. Treat any non-SDK-style project as legacy.
    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -notmatch '<Project\s+Sdk='
    })
}

function Repair-StandInCosturaFody {
    param(
        [string]$CloneDir
    )

    # StandIn pins Costura.Fody 1.6.2, which packages.config itself flags
    # requireReinstallation="true" - it's incompatible with the Fody 2.5.0 it's also
    # pinned to (Mono.Cecil version mismatch at weave time: "Could not load file or
    # assembly 'Mono.Cecil, Version=0.10.0.0...'"). Bump both to a known-good pair
    # (Costura.Fody 4.1.0 / Fody 6.0.0) and repoint the hardcoded paths accordingly.
    $target = Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match 'Costura\.Fody\.1\.6\.2'
    } | Select-Object -First 1
    if (-not $target) { return }

    Write-Status "[-] [$($target.BaseName)] pinned Costura.Fody 1.6.2 is broken - bumping to Costura.Fody 4.1.0 / Fody 6.0.0" 'DarkGray'

    $content = Get-Content -Path $target.FullName -Raw
    $content = $content.Replace(
        'Costura.Fody.1.6.2\lib\portable-net+sl+win+wpa+wp\Costura.dll',
        'Costura.Fody.4.1.0\lib\net40\Costura.dll'
    )
    $content = $content.Replace('Fody.2.5.0\build\Fody.targets', 'Fody.6.0.0\build\Fody.targets')
    $content = $content.Replace(
        'Costura.Fody.1.6.2\build\portable-net+sl+win+wpa+wp\Costura.Fody.targets',
        'Costura.Fody.4.1.0\build\Costura.Fody.props'
    )
    Set-Content -Path $target.FullName -Value $content -NoNewline
}

function Restore-LegacyHintPathPackages {
    param(
        [string]$CloneDir
    )

    # Some tools (e.g. SharPersist) reference NuGet packages via plain <Reference HintPath>
    # pointing into a ..\packages\<Id>.<Version>\ folder but never shipped a packages.config,
    # so nothing ever restores them. Derive the package id/version straight from the
    # HintPath and nuget-install whatever's missing.
    $pattern = 'packages\\(?<pkg>[A-Za-z0-9_.\-]+?)\.(?<ver>\d+\.\d+\.\d+(?:\.\d+)?)\\'
    $seen = @{}

    Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content -Path $_.FullName -Raw
        $packagesDir = Join-Path $_.DirectoryName '..\packages'

        foreach ($match in [regex]::Matches($content, $pattern)) {
            $pkgId  = $match.Groups['pkg'].Value
            $pkgVer = $match.Groups['ver'].Value
            $key = "$pkgId.$pkgVer"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            if (Test-Path (Join-Path $packagesDir $key)) { continue }

            Write-Status "[-] [$($_.BaseName)] restoring dangling reference $key (no packages.config)" 'Cyan'
            nuget install $pkgId -Version $pkgVer -OutputDirectory $packagesDir -NonInteractive *>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Status "[!] [$($_.BaseName)] nuget install $key failed (exit $LASTEXITCODE)" 'Yellow'
            }
        }
    }
}

function Restore-PackagesConfigFolders {
    param(
        [string]$CloneDir
    )

    # Modern nuget.exe (7.x) runs `nuget restore` through the MSBuild-based restore
    # engine, which for these old non-SDK projects writes obj\project.assets.json /
    # .nuget.g.props|targets but silently never populates the classic
    # <ProjectDir>\packages\<Id>.<Version>\ folder that packages.config-era .csproj
    # files hardcode into <Reference HintPath>, <Import Project>, and
    # EnsureNuGetPackageBuildImports <Error Condition="!Exists(...)"> checks (seen on
    # SharpSCCM: every packages.config entry, not just build-tool-only ones like
    # ILMerge/dnMerge, was missing from packages\ despite "nuget restore" reporting
    # success). `nuget install <packages.config>` uses the classic restore path and
    # reliably extracts every listed package next to its packages.config.
    Get-ChildItem -Path $CloneDir -Filter 'packages.config' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $packagesDir = Join-Path $_.DirectoryName 'packages'
        Write-Status "[-] [$($_.Directory.BaseName)] nuget install $($_.Name) -> $packagesDir" 'Cyan'
        nuget install $_.FullName -OutputDirectory $packagesDir -NonInteractive *>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$($_.Directory.BaseName)] nuget install packages.config failed (exit $LASTEXITCODE)" 'Yellow'
        }
    }
}

function Resolve-GitCloneUrl {
    # Lets $Repo be either a "owner/repo" shorthand (resolved against github.com)
    # or a full URL (e.g. a Gitea instance) passed through as-is.
    param(
        [string]$Repo
    )

    if ($Repo -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return $Repo
    }
    return "https://github.com/$Repo.git"
}

function Invoke-GitCloneOrUpdate {
    # Shared clone/fetch/pull step for the Install-FromSource*/Install-GitCloneOnly family.
    # Retries transient failures (e.g. DNS blips) instead of leaving a half-cloned directory
    # behind that a later "pull" silently fails against - and actually checks $LASTEXITCODE,
    # since a failed git process doesn't throw so a bare try/catch here would swallow it.
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [string]$CloneDir,
        [string]$Ref,
        [int]$MaxAttempts = 3,
        [int]$RetryDelaySeconds = 15
    )

    $existed = Test-Path $CloneDir

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($existed) {
                if ($Ref) {
                    Write-Status "[-] [$Name] git fetch" 'Cyan'
                    Invoke-NativeQuiet { git -C $CloneDir fetch *>$null }
                } else {
                    Write-Status "[-] [$Name] git pull" 'Cyan'
                    Invoke-NativeQuiet { git -C $CloneDir pull *>$null }
                }
            } else {
                Write-Status "[-] [$Name] git clone $Repo -> $CloneDir" 'Cyan'
                Invoke-NativeQuiet { git clone (Resolve-GitCloneUrl -Repo $Repo) $CloneDir *>$null }
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Status "[!] [$Name] git clone/fetch/pull exited with code $LASTEXITCODE" 'Yellow'
            } elseif ($Ref) {
                Write-Status "[-] [$Name] checking out pinned ref $Ref" 'Cyan'
                Invoke-NativeQuiet { git -C $CloneDir checkout $Ref *>$null }
                if ($LASTEXITCODE -eq 0) {
                    return $true
                }
                Write-Status "[!] [$Name] failed to checkout pinned ref '$Ref' (exit $LASTEXITCODE)" 'Yellow'
            } else {
                return $true
            }
        } catch {
            Write-Status "[!] [$Name] git clone failed: $($_.Exception.Message)" 'Yellow'
        }

        # A failed first-time clone can still leave a partial directory behind, which would
        # make the next attempt take the "pull" branch above against a non-repo folder.
        if (-not $existed -and (Test-Path $CloneDir)) {
            Remove-Item -Path $CloneDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Status "[!] [$Name] clone attempt $attempt/$MaxAttempts failed - retrying in ${RetryDelaySeconds}s" 'Yellow'
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    Write-Status "[x] [$Name] git clone/update failed after $MaxAttempts attempts" 'Red'
    return $false
}

function Update-GitSubmodules {
    param(
        [string]$Name,
        [string]$CloneDir
    )

    Write-Status "[-] [$Name] git submodule update --init --recursive" 'Cyan'
    Invoke-NativeQuiet { git -C $CloneDir submodule update --init --recursive *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] git submodule update failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }
    return $true
}

function Install-FromSourceDotNet {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        [string]$SlnPath,
        [string]$Platform,
        [string]$Ref,
        [switch]$SubModule
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir -Ref $Ref)) {
        return $false
    }
    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }
    $headSha = (git -C $cloneDir rev-parse --short HEAD 2>$null)
    Write-Status "[-] [$Name] at commit $headSha" 'Cyan'

    Add-LegacyReferenceAssemblies -CloneDir $cloneDir
    Repair-WinRTHintPaths -CloneDir $cloneDir
    Repair-StandInCosturaFody -CloneDir $cloneDir

    # Same PATH-staleness issue as Install-PipPackage - the .NET SDK was just installed via
    # winget earlier in this same Stage 3 process.
    Update-SessionPath
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] cloned but the .NET SDK is not available - install it to build this" 'Yellow'
        return $false
    }

    Register-NuGetOrgSource

    if ($SlnPath) {
        $projectFile = Join-Path $cloneDir $SlnPath
        if (-not (Test-Path $projectFile)) {
            Write-Status "[!] [$Name] specified SlnPath '$SlnPath' not found under $cloneDir" 'Yellow'
            return $false
        }
        $projectFile = Get-Item $projectFile
    } else {
        # Most repos have exactly one .sln; a few (e.g. Net-GPPPassword) ship only a .csproj.
        $projectFile = Get-ChildItem -Path $cloneDir -Filter '*.sln' -Recurse | Select-Object -First 1
        if (-not $projectFile) {
            $projectFile = Get-ChildItem -Path $cloneDir -Filter '*.csproj' -Recurse | Select-Object -First 1
        }
        if (-not $projectFile) {
            Write-Status "[!] [$Name] no .sln or .csproj found under $cloneDir" 'Yellow'
            return $false
        }
    }
    Write-Status "[-] [$Name] using project file $($projectFile.FullName)" 'Cyan'

    $packagesConfig = Get-ChildItem -Path $cloneDir -Filter 'packages.config' -Recurse -ErrorAction SilentlyContinue
    $hasLegacyHintPaths = Test-HasLegacyPackageReferences -CloneDir $cloneDir
    $hasComReferences = Test-HasComReferences -CloneDir $cloneDir
    $hasResxResources = Test-HasResxResources -CloneDir $cloneDir
    $isClassicProject = Test-IsClassicProject -CloneDir $cloneDir
    $useMsbuildExe = $false
    if ($packagesConfig -or $hasLegacyHintPaths -or $hasComReferences -or $hasResxResources -or $isClassicProject) {
        Write-Status "[-] [$Name] legacy project (packages.config: $([bool]$packagesConfig), HintPath refs: $hasLegacyHintPaths, COM refs: $hasComReferences, .resx: $hasResxResources, non-SDK: $isClassicProject)" 'Cyan'
        Get-ChildItem -Path $cloneDir -Include 'obj', 'bin' -Recurse -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        if (Get-Command nuget -ErrorAction SilentlyContinue) {
            if ($hasLegacyHintPaths) { Restore-LegacyHintPathPackages -CloneDir $cloneDir }

            Write-Status "[-] [$Name] nuget restore $($projectFile.Name)" 'Cyan'
            nuget restore $projectFile.FullName -NonInteractive -Verbosity normal
            if ($LASTEXITCODE -ne 0) {
                Write-Status "[!] [$Name] nuget restore failed (exit $LASTEXITCODE)" 'Yellow'
                return $false
            }

            if ($packagesConfig) { Restore-PackagesConfigFolders -CloneDir $cloneDir }
        } else {
            Write-Status "[!] [$Name] legacy project but nuget is not on PATH - build will likely fail" 'Yellow'
        }

        $msbuildExe = Find-MSBuildExe
        if ($msbuildExe) {
            $useMsbuildExe = $true
        } else {
            Write-Status "[!] [$Name] legacy project but MSBuild.exe not found (needs Visual Studio) - falling back to dotnet build, may fail" 'Yellow'
        }
    }

    if ($useMsbuildExe) {
        $buildArgs = @($projectFile.FullName, '/p:Configuration=Release', '/verbosity:minimal')
        if ($Platform) { $buildArgs += "/p:Platform=$Platform" }

        Write-Status "[-] [$Name] building: $msbuildExe $($buildArgs -join ' ')" 'Cyan'
        & $msbuildExe @buildArgs
    } else {
        $buildArgs = @($projectFile.FullName, '-c', 'Release', '--verbosity', 'minimal')
        if ($Platform) { $buildArgs += "-p:Platform=$Platform" }

        Write-Status "[-] [$Name] building: dotnet build $($buildArgs -join ' ')" 'Cyan'
        dotnet build @buildArgs
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] build failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] built from source at $cloneDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build:$Repo"
    return $true
}

function Install-GitCloneOnly {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        # Installs the repo's requirements.txt via pip after cloning - needed for script
        # tools (e.g. SuperMega) that ship Python dependencies alongside the source.
        [switch]$PipRequirements,
        [switch]$SubModule
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir)) {
        return $false
    }

    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    if ($PipRequirements) {
        $reqFile = Join-Path $cloneDir 'requirements.txt'
        if (Test-Path $reqFile) {
            Update-SessionPath
            if (Get-Command python -ErrorAction SilentlyContinue) {
                Write-Status "[-] [$Name] pip install -r requirements.txt" 'Cyan'
                Invoke-NativeQuiet { python -m pip install --quiet --upgrade -r $reqFile *>$null }
                if ($LASTEXITCODE -ne 0) {
                    Write-Status "[!] [$Name] pip install -r requirements.txt failed (exit $LASTEXITCODE)" 'Yellow'
                }
            } else {
                Write-Status "[!] [$Name] python is not on PATH - skipping requirements.txt" 'Yellow'
            }
        }
    }

    Write-Status "[+] [$Name] cloned to $cloneDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "git-clone:$Repo"
    return $true
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$Destination
    )

    $destDir = Split-Path -Path $Destination -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Write-Status "[-] [Download] $Url -> $Destination" 'Cyan'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        Write-Status "[+] [Download] saved $Destination" 'Green'
        return $true
    } catch {
        Write-Status "[!] [Download] failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Install-FromSourceGo {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        # Build-time env vars - needed for repos that require cross-compile settings
        # (e.g. go-cookie-monster needs CGO_ENABLED/GOARCH/GOOS set explicitly).
        [hashtable]$Env,
        [switch]$SubModule
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir)) {
        return $false
    }

    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    Update-SessionPath
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] cloned but the go toolchain is not on PATH - install Go first" 'Yellow'
        return $false
    }

    $outExe = Join-Path $cloneDir "$Name.exe"
    Write-Status "[-] [$Name] go build" 'Cyan'
    Push-Location $cloneDir
    $savedEnv = @{}
    try {
        foreach ($key in $Env.Keys) {
            $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key)
            Set-Item -Path "Env:$key" -Value $Env[$key]
        }

        # go build routinely writes non-fatal notices (module downloads, deprecation
        # warnings) to stderr - see the Invoke-NativeQuiet comment for why *>$null alone
        # isn't enough to keep those from aborting the script under $ErrorActionPreference
        # = 'Stop'.
        Invoke-NativeQuiet { go build -o $outExe . *>$null }
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$Name] go build failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
    } finally {
        foreach ($key in $savedEnv.Keys) {
            if ($null -eq $savedEnv[$key]) {
                Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path "Env:$key" -Value $savedEnv[$key]
            }
        }
        Pop-Location
    }

    Write-Status "[+] [$Name] built from source at $outExe" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build-go:$Repo"
    return $true
}

function Install-GoInstall {
    param(
        [string]$Name,
        [string]$Package  # e.g. "github.com/OJ/gobuster/v3@latest"
    )

    Update-SessionPath
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] go toolchain is not on PATH - install Go first" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] go install $Package" 'Cyan'
    Invoke-NativeQuiet { go install $Package *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] go install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] installed via go install" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "go-install:$Package"
    return $true
}

function Install-FromSourceRust {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        [string]$Target,
        [switch]$SubModule
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir)) {
        return $false
    }

    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    Update-SessionPath
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        Write-Status "[!] [$Name] cloned but cargo is not on PATH - install Rust first" 'Yellow'
        return $false
    }

    $cargoArgs = @('build', '--release')
    $outDir = "$cloneDir\target\release"
    if ($Target) {
        $rustup = Get-Command rustup -ErrorAction SilentlyContinue
        if (-not $rustup) {
            Write-Status "[!] [$Name] cloned but rustup is not on PATH - install Rust first" 'Yellow'
            return $false
        }
        Invoke-NativeQuiet { & $rustup.Source target add $Target *>$null }
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$Name] rustup target add $Target failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
        # $cargoArgs += @('--target', $Target)
        # $outDir = "$cloneDir\target\$Target\release"

    }

    Write-Status "[-] [$Name] cargo $($cargoArgs -join ' ')" 'Cyan'
    Push-Location $cloneDir
    try {
        cargo build --target $Target --release
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$Name] cargo build failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
    } finally {
        Pop-Location
    }

    Write-Status "[+] [$Name] built from source at $outDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build-rust:$Repo"
    return $true
}

function Install-FromSourceCMake {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        [string]$Configuration = 'Release',
        [string]$Ref,
        [switch]$SubModule,

        # CMake generator (e.g. 'Ninja', 'Visual Studio 17 2022') - left unset to use
        # whatever cmake picks as the default for the environment.
        [string]$Generator,
        # Generator platform/arch for multi-arch generators, e.g. -A x64 with the VS generators.
        [string]$Architecture,
        # Extra -D defines to pass through to the configure step, e.g. @('-DUPX_CONSOLE=ON').
        [string[]]$CMakeArgs,
        # Specific target to build instead of the generator's default ("all"/"ALL_BUILD").
        [string]$Target,
        [switch]$Clean
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir -Ref $Ref)) {
        return $false
    }
    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    Update-SessionPath
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] cloned but cmake is not on PATH - install CMake first" 'Yellow'
        return $false
    }

    $buildDir = Join-Path $cloneDir "build\$($Configuration.ToLower())"
    if ($Clean -and (Test-Path $buildDir)) {
        Write-Status "[-] [$Name] cleaning previous build dir $buildDir" 'Yellow'
        Remove-Item -Recurse -Force $buildDir
    }
    if (-not (Test-Path $buildDir)) {
        New-Item -ItemType Directory -Path $buildDir | Out-Null
    }

    $configureArgs = @('-S', $cloneDir, '-B', $buildDir, "-DCMAKE_BUILD_TYPE=$Configuration")
    if ($Generator) { $configureArgs += @('-G', $Generator) }
    if ($Architecture) { $configureArgs += @('-A', $Architecture) }
    if ($CMakeArgs) { $configureArgs += $CMakeArgs }

    Write-Status "[-] [$Name] cmake $($configureArgs -join ' ')" 'Cyan'
    cmake @configureArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] cmake configure failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    $buildArgs = @('--build', $buildDir, '--config', $Configuration, '--parallel')
    if ($Target) { $buildArgs += @('--target', $Target) }

    Write-Status "[-] [$Name] cmake $($buildArgs -join ' ')" 'Cyan'
    cmake @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] cmake build failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] built from source at $buildDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build-cmake:$Repo"
    return $true
}

function Install-FromSourceBof {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        [string]$Ref,
        [switch]$SubModule,
        # Relative path (from the clone root) to the build script - BOFs invoke cl.exe/link.exe
        # directly rather than going through a .sln, so there's no MSBuild project to target.
        [string]$BuildScript = 'make.bat',
        [string]$Arch = 'x64'
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir -Ref $Ref)) {
        return $false
    }
    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    $buildScriptPath = Join-Path $cloneDir $BuildScript
    if (-not (Test-Path $buildScriptPath)) {
        Write-Status "[!] [$Name] build script '$BuildScript' not found under $cloneDir" 'Yellow'
        return $false
    }

    # Run from the build script's own directory, not the clone root - these scripts
    # (e.g. Unhook-BOF's make.bat) commonly reference source files by a path relative to
    # themselves rather than %~dp0, so they only work when invoked from where they live.
    $buildScriptDir  = Split-Path $buildScriptPath -Parent
    $buildScriptLeaf = Split-Path $buildScriptPath -Leaf

    Write-Status "[-] [$Name] running $BuildScript in a VS Developer shell ($Arch)" 'Cyan'
    if (-not (Invoke-InVsDevShell -WorkingDirectory $buildScriptDir -Command "$buildScriptLeaf" -Arch $Arch)) {
        Write-Status "[!] [$Name] $BuildScript failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] built from source at $cloneDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build-bof:$Repo"
    return $true
}

function Install-FromSourceBofMake {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        [string]$Ref,
        [switch]$SubModule,
        # Relative path (from the clone root) to the directory containing the Makefile -
        # several BOF repos nest it (e.g. 'src').
        [string]$MakeDir = '',
        [string]$MakeTarget,

        # x86_64-w64-mingw32-gcc/strip are what mingw-w64-x86_64-toolchain actually installs
        # under C:\msys64\mingw64\bin - most BOF Makefiles reference these exact names for
        # their x64 compiler variable, but only ship the unprefixed 'strip.exe', not
        # 'x86_64-w64-mingw32-strip'. Passed as blanket make command-line overrides below;
        # make silently ignores overrides for variables a given Makefile never references,
        # so this is safe across repos with different variable-naming conventions
        # (CC vs CC_x64, STRIP vs STRIP_x64).
        [string]$Cc64 = 'x86_64-w64-mingw32-gcc',
        [string]$Strip64 = 'strip',

        # i686-w64-mingw32-gcc is what mingw-w64-i686-toolchain installs under
        # C:\msys64\mingw32\bin - the x86 half of BOF Makefiles that build both
        # architectures (CC_x86/STRIP_x86) needs this the same way the x64 half needs
        # Cc64/Strip64 above. strip.exe is unprefixed here too, but it shares its name
        # with mingw64\bin's strip.exe, which comes first on PATH - so this needs the
        # full path rather than a bare name that would silently resolve to the wrong one.
        [string]$Cc32 = 'i686-w64-mingw32-gcc',
        [string]$Strip32 = 'C:\msys64\mingw32\bin\strip.exe',

        # Older BOF source routinely trips checks GCC 14+ promotes from warning to hard
        # error by default in C mode (e.g. passing a SIZE_T* where beacon.h declares int*) -
        # demote those back to warnings so pre-GCC14-era repos still build.
        [string[]]$ExtraCFlags = @(
            '-Wno-error=incompatible-pointer-types',
            '-Wno-error=implicit-function-declaration',
            '-Wno-error=int-conversion'
        ),

        # Some repos bundle many independent BOFs, one per subfolder, rather than a single
        # buildable tool (e.g. CS-Situational-Awareness-BOF has ~70 under src\SA). Build
        # every Makefile found under -MakeDir instead of just one, tracking each subfolder
        # as its own result so a handful of failures don't obscure everything else that
        # built fine.
        [switch]$Recursive
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir -Ref $Ref)) {
        return $false
    }
    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    $searchRoot = if ($MakeDir) { Join-Path $cloneDir $MakeDir } else { $cloneDir }
    if (-not (Test-Path $searchRoot)) {
        Write-Status "[!] [$Name] MakeDir '$MakeDir' not found under $cloneDir" 'Yellow'
        return $false
    }

    Update-SessionPath
    if (-not (Get-Command mingw32-make -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] mingw32-make not on PATH - install the MSYS2 toolchain first" 'Yellow'
        return $false
    }

    $ccOverride64 = "$Cc64 $($ExtraCFlags -join ' ')"
    $ccOverride32 = "$Cc32 $($ExtraCFlags -join ' ')"
    $makeArgs = @()
    if ($MakeTarget) { $makeArgs += $MakeTarget }
    $makeArgs += "CC=$ccOverride64", "CC_x64=$ccOverride64", "CC_x86=$ccOverride32", "STRIP=$Strip64", "STRIP_x64=$Strip64", "STRIP_x86=$Strip32"

    if ($Recursive) {
        $makefiles = Get-ChildItem -Path $searchRoot -Recurse -Include 'Makefile', 'makefile', 'GNUmakefile' -File -ErrorAction SilentlyContinue
        if (-not $makefiles) {
            Write-Status "[!] [$Name] no Makefiles found under $searchRoot" 'Yellow'
            return $false
        }

        $succeeded = 0
        foreach ($mf in $makefiles) {
            $relDir = $mf.DirectoryName.Substring($searchRoot.Length).Trim('\') -replace '\\', '/'
            $subName = if ($relDir) { "$Name/$relDir" } else { $Name }

            Write-Status "[-] [$subName] mingw32-make $($makeArgs -join ' ')" 'Cyan'
            Push-Location $mf.DirectoryName
            try {
                mingw32-make @makeArgs
            } finally {
                Pop-Location
            }

            if ($LASTEXITCODE -eq 0) {
                Write-Status "[+] [$subName] built" 'Green'
                Add-Result -Name $subName -Status Installed -Detail "source-build-bof-make:$Repo"
                $succeeded++
            } else {
                Write-Status "[!] [$subName] failed (exit $LASTEXITCODE)" 'Yellow'
                Add-Result -Name $subName -Status Skipped -Detail "source-build-bof-make:$Repo (exit $LASTEXITCODE)"
            }
        }

        Write-Status "[+] [$Name] built $succeeded/$($makefiles.Count) under $searchRoot" 'Green'
        return ($succeeded -gt 0)
    }

    if (-not (Test-Path (Join-Path $searchRoot 'Makefile'))) {
        Write-Status "[!] [$Name] no Makefile found at $searchRoot" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] mingw32-make $($makeArgs -join ' ') (in $searchRoot)" 'Cyan'
    Push-Location $searchRoot
    try {
        mingw32-make @makeArgs
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] mingw32-make failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] built from source at $searchRoot" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build-bof-make:$Repo"
    return $true
}

function Install-FromSourceNative {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        # Relative path (from the clone root) to the .sln/.slnx/.vcxproj to build. Required -
        # unlike Install-FromSourceDotNet, native repos routinely ship several solutions
        # (bundled dependency libraries, alternate variants) and there's no safe way to
        # guess which one is "the" project to build.
        [Parameter(Mandatory)]
        [string]$SlnPath,
        [string]$Platform,
        [string]$Configuration = 'Release',
        [string]$Ref,

        # Overrides for old repos pinned to a Windows SDK / toolset that's no longer the
        # VS default - left unset (i.e. not passed to MSBuild) unless the caller needs them.
        [string]$WindowsSdkVersion,
        [string]$PlatformToolset,

        [string]$MsBuildPath,
        [switch]$SubModule
    )

    $cloneDir = Join-Path $DestRoot $Name
    if (-not (Invoke-GitCloneOrUpdate -Name $Name -Repo $Repo -CloneDir $cloneDir -Ref $Ref)) {
        return $false
    }
    if ($SubModule -and -not (Update-GitSubmodules -Name $Name -CloneDir $cloneDir)) {
        return $false
    }

    $projectFile = Join-Path $cloneDir $SlnPath
    if (-not (Test-Path $projectFile)) {
        Write-Status "[!] [$Name] specified SlnPath '$SlnPath' not found under $cloneDir" 'Yellow'
        return $false
    }

    $msbuildExe = $MsBuildPath
    if (-not $msbuildExe) { $msbuildExe = Find-MSBuildExe }
    if (-not $msbuildExe -or -not (Test-Path $msbuildExe)) {
        Write-Status "[!] [$Name] MSBuild.exe not found (needs Visual Studio with the C++ Desktop workload)" 'Yellow'
        return $false
    }

    # No NuGet restore step here - native C/C++ projects here don't use packages.config
    # or PackageReference; dependencies are either vendored in-repo or resolved by the
    # MSVC toolset/Windows SDK components installed alongside MSBuild.
    $buildArgs = @($projectFile, "/p:Configuration=$Configuration", '/verbosity:minimal')
    if ($Platform) { $buildArgs += "/p:Platform=$Platform" }
    if ($WindowsSdkVersion) { $buildArgs += "/p:WindowsTargetPlatformVersion=$WindowsSdkVersion" }
    if ($PlatformToolset) { $buildArgs += "/p:PlatformToolset=$PlatformToolset" }

    Write-Status "[-] [$Name] building: $msbuildExe $($buildArgs -join ' ')" 'Cyan'
    & $msbuildExe @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] build failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] built from source at $cloneDir" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "source-build-native:$Repo"
    return $true
}

function Install-PipPackage {
    param(
        [string]$Name,
        [string]$PipName
    )

    Update-SessionPath
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] python is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] pip install $PipName" 'Cyan'

    Invoke-NativeQuiet { python -m pip install --quiet --upgrade $PipName *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] pip install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] installed via pip" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "pip:$PipName"
    return $true
}

function Install-Pipx {
    # See the comment in Install-PipPackage - same PATH-staleness issue applies here.
    Update-SessionPath
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [pipx] python is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [pipx] pip install pipx" 'Cyan'

    # Same stderr-becomes-terminating-error issue Invoke-NativeQuiet's comment describes -
    # pip's "WARNING: The script pipx.exe is installed in '...' which is not on PATH" line
    # goes to stderr on a fresh install and would otherwise abort this function before
    # ensurepath ever runs, leaving pipx.exe on disk but unreachable from PATH.
    Invoke-NativeQuiet { python -m pip install pipx *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [pipx] pip install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Invoke-NativeQuiet { python -m pipx ensurepath *>$null }

    Write-Status "[+] [pipx] installed via pip" 'Green'
    Add-Result -Name 'pipx' -Status Installed -Detail 'pip:pipx'
    return $true
}

function Install-PipxPackage {
    param(
        [string]$Name,
        [string]$PipxUrl
    )

    Update-SessionPath
    if (-not (Get-Command pipx -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] pipx is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] pipx install $PipxUrl" 'Cyan'

    Invoke-NativeQuiet { pipx install $PipxUrl *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] pipx install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] installed via pipx" 'Green'
    Add-Result -Name $Name -Status Installed -Detail "pipx:$PipxUrl"
    return $true
}

function Install-ChooseNim {
    Update-SessionPath
    if (-not (Get-Command choosenim -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [ChooseNim] choosenim is not on PATH - install it via winget first" 'Yellow'
        return $false
    }

    Write-Status "[-] [ChooseNim] choosenim stable --firstInstall" 'Cyan'
    Invoke-NativeQuiet { choosenim stable --firstInstall 2>$null | Out-Null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [ChooseNim] 'choosenim stable --firstInstall' failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [ChooseNim] Nim installed, .nimble\bin added to PATH" 'Green'
    Add-Result -Name 'ChooseNim' -Status Installed -Detail 'choosenim stable --firstInstall'
    return $true
}

function Install-Msys2 {
    $destRoot = 'C:\'
    $msys2Dir = 'C:\msys64'

    if (Test-Path $msys2Dir) {
        Write-Status "[+] [MSYS2] already installed at $msys2Dir" 'DarkGray'
        Add-Result -Name 'MSYS2' -Status Installed -Detail 'already present'
        return $true
    }

    $asset = Get-GitHubReleaseAsset -Name 'MSYS2' -Repo 'msys2/msys2-installer' -AssetPattern '*base-x86_64-latest.sfx.exe' -Tag 'nightly-x86_64'
    if (-not $asset) { return $false }

    $destFile = Join-Path $script:DlRoot $asset.name
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $destFile -UseBasicParsing
    } catch {
        Write-Status "[!] [MSYS2] download failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    Write-Status "[-] [MSYS2] extracting to $msys2Dir" 'Cyan'
    & $destFile -y "-o$destRoot"
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $msys2Dir)) {
        Write-Status "[!] [MSYS2] extraction failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [MSYS2] extracted to $msys2Dir" 'Green'
    Add-Result -Name 'MSYS2' -Status Installed -Detail "github-release:msys2/msys2-installer/$($asset.name)"
    return $true
}

function Install-MsysToolchain {
    $bash = 'C:\msys64\usr\bin\bash.exe'
    if (-not (Test-Path $bash)) {
        Write-Status "[!] [MSYS2 toolchain] bash.exe not found - install MSYS2 first" 'Yellow'
        return $false
    }

    $mingw64Gcc = 'C:\msys64\mingw64\bin\gcc.exe'
    $mingw32Gcc = 'C:\msys64\mingw32\bin\gcc.exe'
    if ((Test-Path $mingw64Gcc) -and (Test-Path $mingw32Gcc)) {
        Write-Status "[+] [MSYS2 toolchain] already installed" 'DarkGray'
        Add-Result -Name 'MSYS2 toolchain' -Status Installed -Detail 'already present'
        return $true
    }

    Write-Status "[-] [MSYS2 toolchain] pacman -Syu (core update pass 1/2)" 'Cyan'
    C:\msys64\usr\bin\bash.exe -lc 'pacman -Syu --noconfirm --needed' | Out-Null
    Write-Status "[-] [MSYS2 toolchain] pacman -Syu (core update pass 2/2)" 'Cyan'
    C:\msys64\usr\bin\bash.exe -lc 'pacman -Syu --noconfirm --needed' | Out-Null

    # BOF Makefiles (e.g. C2-Tool-Collection) build both x64 and x86 objects per source
    # file, so both mingw-w64 toolchains are required - x86_64-only left i686-w64-mingw32-gcc
    # unresolved and broke the x86 half of every such build.
    Write-Status "[-] [MSYS2 toolchain] installing base-devel, mingw-w64 x86_64/i686 gcc/cmake/qt6" 'Cyan'
    C:\msys64\usr\bin\bash.exe -lc 'pacman -S --noconfirm --needed base-devel mingw-w64-x86_64-toolchain mingw-w64-i686-toolchain mingw-w64-x86_64-cmake mingw-w64-x86_64-qt6' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [MSYS2 toolchain] pacman install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    if (-not (Test-Path $mingw64Gcc) -or -not (Test-Path $mingw32Gcc)) {
        Write-Status "[!] [MSYS2 toolchain] pacman succeeded but gcc.exe not found at $mingw64Gcc or $mingw32Gcc" 'Yellow'
        return $false
    }

    $mingwBins = @('C:\msys64\mingw64\bin', 'C:\msys64\mingw32\bin', 'C:\msys64\usr\bin')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    foreach ($mingwBin in $mingwBins) {
        if ($pathEntries -notcontains $mingwBin) {
            $userPath = if ($userPath) { "$userPath;$mingwBin" } else { $mingwBin }
            $pathEntries += $mingwBin
            $env:Path += ";$mingwBin"
        }
    }
    [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')

    Write-Status "[+] [MSYS2 toolchain] installed, mingw64/mingw32/usr bin added to user PATH" 'Green'
    Add-Result -Name 'MSYS2 toolchain' -Status Installed -Detail 'base-devel + mingw-w64-x86_64/i686-toolchain, x86_64-cmake/qt6'
    return $true
}

function Install-NimPackages {
    $nimPackages = @(
        'winim',
        'nimcrypto',
        'docopt',
        'psutil',
        'nimprotect',
        'supersnappy',
        'argparse',
        'ptr_math',
        'strenc',
        'libp2p',
        'ws',
        'zippy',
        'iputils',
        'socks5',
        'daemon',
        'tiny_sqlite',
        'dnsclient'
    )

    Update-SessionPath
    if (-not (Get-Command nimble -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [Nim packages] nimble is not on PATH - install Nim first" 'Yellow'
        return $false
    }

    foreach ($pkg in $nimPackages) {
        Write-Status "[-] [Nim packages] nimble install $pkg" 'Cyan'
        nimble install -y $pkg 
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Nim packages] $pkg failed (exit $LASTEXITCODE)" 'Yellow'
            Add-Result -Name "Nim package: $pkg" -Status Skipped -Detail "nimble install failed (exit $LASTEXITCODE)"
            continue
        }
        Write-Status "[+] [Nim packages] $pkg installed" 'Green'
        Add-Result -Name "Nim package: $pkg" -Status Installed -Detail 'nimble'
    }
}

function Enable-NetFx35Feature {

    Write-Status "[-] [.NET Framework 3.5] enabling Windows feature" 'Cyan'
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3
        if ($feature.State -eq 'Enabled') {
            Write-Status "[+] [.NET Framework 3.5] already enabled" 'DarkGray'
            Add-Result -Name '.NET Framework 3.5' -Status Installed -Detail 'already enabled'
            return $true
        }

        Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart | Out-Null
        Write-Status "[+] [.NET Framework 3.5] enabled" 'Green'
        Add-Result -Name '.NET Framework 3.5' -Status Installed -Detail 'Windows feature enabled'
        return $true
    } catch {
        Write-Status "[!] [.NET Framework 3.5] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name '.NET Framework 3.5' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Install-VS2022Components {
    $vsInstaller   = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
    $vsInstallPath = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community"

    if (!(Test-Path $vsInstaller)) {
        Write-Status "[!] [VS2022 components] vs_installer setup.exe not found at $vsInstaller" 'Yellow'
        return $false
    }

    $vsComponents = @(
        'Microsoft.VisualStudio.Workload.NativeDesktop',

        # MSVC toolsets
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64', # v142 (VS2019) toolset - versioned id, not VC.v142.x86.x64
        'Microsoft.VisualStudio.Component.VC.v141.x86.x64',
        'Microsoft.VisualStudio.Component.VC.140',

        # Windows SDKs
        'Microsoft.VisualStudio.Component.Windows11SDK.26100',
        'Microsoft.VisualStudio.Component.Windows11SDK.22621',
        'Microsoft.VisualStudio.Component.Windows10SDK.19041',

        # C++ tools
        'Microsoft.VisualStudio.Component.VC.CMake.Project',
        'Microsoft.VisualStudio.Component.VC.ATL',
        'Microsoft.VisualStudio.Component.VC.ATLMFC',
        'Microsoft.VisualStudio.Component.VC.CLI.Support',
        'Microsoft.VisualStudio.Component.VC.Modules.x86.x64',
        'Microsoft.VisualStudio.Component.VC.ASAN',
        'Microsoft.VisualStudio.Component.Vcpkg', # not VC.Vcpkg - that id doesn't exist
        'Microsoft.VisualStudio.Component.VC.Redist.14.Latest',
        'Microsoft.VisualStudio.Component.CppBuildInsights', # not VC.BuildInsights
        'Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Llvm.Clang',

        # Build tools
        'Microsoft.Component.MSBuild', 

        # .NET
        'Microsoft.Net.Component.4.8.SDK',
        'Microsoft.Net.Component.4.7.2.TargetingPack',

        'Microsoft.Net.Component.3.5.DeveloperTools',
        'Microsoft.Net.Component.4.6.1.TargetingPack'
    )

    $modifyArgs = @('modify', '--installPath', $vsInstallPath, '--quiet', '--norestart') +
        ($vsComponents | ForEach-Object { @('--add', $_) })

    Write-Status "[-] [VS2022 components] adding $($vsComponents.Count) components" 'Cyan'
    & $vsInstaller @modifyArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [VS2022 components] modify exited with code $LASTEXITCODE" 'Yellow'
        return $false
    }

    Write-Status "[+] [VS2022 components] added" 'Green'
    Add-Result -Name 'VS2022 Components' -Status Installed -Detail "$($vsComponents.Count) components"
    return $true
}

function Install-Jdk17 {
    $jdkUrl  = 'https://download.java.net/java/GA/jdk17.0.1/2a2082e5a09d4267845be086888add4f/12/GPL/openjdk-17.0.1_windows-x64_bin.zip'
    $jdkHome = 'C:\Program Files\jdk-17.0.2'
    $jdkBin  = Join-Path $jdkHome 'bin'

    if (Test-Path (Join-Path $jdkBin 'javac.exe')) {
        Write-Status "[+] [JDK 17] already installed at $jdkHome" 'DarkGray'
        Add-Result -Name 'JDK 17' -Status Installed -Detail 'already present'
        return $true
    }

    $destFile = Join-Path $script:DlRoot 'openjdk-17.0.2_windows-x64_bin.zip'
    Write-Status "[-] [JDK 17] downloading $jdkUrl" 'Cyan'
    try {
        Invoke-WebRequest -Uri $jdkUrl -OutFile $destFile -UseBasicParsing
    } catch {
        Write-Status "[!] [JDK 17] download failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $extractTemp = Join-Path $script:DlRoot 'jdk-17.0.2-extract'
    if (Test-Path $extractTemp) { Remove-Item -Path $extractTemp -Recurse -Force }

    Write-Status "[-] [JDK 17] extracting archive" 'Cyan'
    try {
        Expand-Archive -Path $destFile -DestinationPath $extractTemp -Force
    } catch {
        Write-Status "[!] [JDK 17] extraction failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    # The zip contains a single top-level "jdk-17.0.2" folder - move it into
    # place rather than assuming the exact name, in case Oracle ever changes it.
    $extractedRoot = Get-ChildItem -Path $extractTemp -Directory | Select-Object -First 1
    if (-not $extractedRoot) {
        Write-Status "[!] [JDK 17] no top-level folder found in archive" 'Yellow'
        return $false
    }

    if (Test-Path $jdkHome) { Remove-Item -Path $jdkHome -Recurse -Force }
    Move-Item -Path $extractedRoot.FullName -Destination $jdkHome
    Remove-Item -Path $extractTemp -Recurse -Force -ErrorAction SilentlyContinue

    # Equivalent of Control Panel > Environment Variables > User "Path" > New
    Write-Status "[-] [JDK 17] adding $jdkBin to user PATH" 'Cyan'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    if ($pathEntries -notcontains $jdkBin) {
        $newPath = if ($userPath) { "$userPath;$jdkBin" } else { $jdkBin }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path += ";$jdkBin"
    }

    Write-Status "[+] [JDK 17] installed at $jdkHome, added to user PATH" 'Green'
    Add-Result -Name 'JDK 17' -Status Installed -Detail "manual-download:$jdkUrl"
    return $true
}

function Install-FirefoxExtensions {
    param(
        [string[]]$Slugs = @(
            'darkreader', 'foxyproxy-standard', 'wappalyzer', 'cookie-editor',
            'user-agent-string-switcher', 'multi-account-containers', 'retire-js', 'shodan-addon'
        )
    )

    $firefoxExe = Get-ChildItem -Path "$env:ProgramFiles\Mozilla Firefox", "${env:ProgramFiles(x86)}\Mozilla Firefox" `
        -Filter 'firefox.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $firefoxExe) {
        Write-Status "[!] [Firefox Extensions] firefox.exe not found - skipping" 'Yellow'
        Add-Result -Name 'Firefox Extensions' -Status Skipped -Detail 'firefox.exe not found'
        return $false
    }

    # policies.json force-installs by add-on guid, not by AMO slug, so each slug is
    # resolved through the AMO API first. The guid is embedded in the signed xpi -
    # a wrong/guessed guid here would just make Firefox silently reject the install.
    $extensionSettings = [ordered]@{}
    foreach ($slug in $Slugs) {
        Write-Status "[-] [Firefox Extensions] resolving add-on id for $slug" 'Cyan'
        try {
            $meta = Invoke-RestMethod -Uri "https://addons.mozilla.org/api/v5/addons/addon/$slug/" -Headers @{ 'User-Agent' = 'RedWindows-installer' }
        } catch {
            Write-Status "[!] [Firefox Extensions] failed to resolve $slug : $($_.Exception.Message)" 'Yellow'
            continue
        }
        if (-not $meta.guid) {
            Write-Status "[!] [Firefox Extensions] no guid returned for $slug" 'Yellow'
            continue
        }
        $extensionSettings[$meta.guid] = @{
            installation_mode = 'force_installed'
            install_url       = "https://addons.mozilla.org/firefox/downloads/latest/$slug/latest.xpi"
        }
    }

    if ($extensionSettings.Count -eq 0) {
        Write-Status "[!] [Firefox Extensions] none resolved - skipping" 'Yellow'
        Add-Result -Name 'Firefox Extensions' -Status Skipped -Detail 'no extensions resolved'
        return $false
    }

    $distDir = Join-Path $firefoxExe.DirectoryName 'distribution'
    if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

    $policy = @{ policies = @{ ExtensionSettings = $extensionSettings } }
    $policyJson = $policy | ConvertTo-Json -Depth 10
    # Set-Content -Encoding UTF8 writes a BOM on Windows PowerShell 5.1 - Firefox's JSON
    # parser silently rejects a BOM-prefixed policies.json (the whole file fails to parse,
    # not just the unrecognized bytes), so write it out without one explicitly.
    [System.IO.File]::WriteAllText((Join-Path $distDir 'policies.json'), $policyJson, (New-Object System.Text.UTF8Encoding($false)))

    Write-Status "[+] [Firefox Extensions] policies.json written for $($extensionSettings.Count) extension(s) - installs on next Firefox launch" 'Green'
    Add-Result -Name 'Firefox Extensions' -Status Installed -Detail "policies.json:$($Slugs -join ',')"
    return $true
}

function Install-ChromeExtensions {
    param(
        # Chrome Web Store extension IDs - verified directly against each listing's
        # publisher/user count before adding (ModHeader was deliberately left out: its
        # popular listing was pulled by Google/Microsoft in July 2026 after researchers
        # found it exfiltrating browsing history, and every replacement listing since
        # is unverified).
        [string[]]$ExtensionIds = @(
            'eimadpbcbfnmbkopoojfekhnkhdbieeh', # Dark Reader
            'gcknhkkoolaabfmlnjonogaaifnjlfnp', # FoxyProxy
            'gppongmhjkpfnbhagpmjfkannfbllamg', # Wappalyzer
            'ookdjilphngeeeghgngjabigmpepanpl', # Cookie Editor
            'bhchdcejhohfmigjafbampogmaanbfkg', # User-Agent Switcher and Manager
            'ciilcijdmepbaiocfaacfcmcnkdhjnag', # Retire.js
            'jjalcfnidlmpjhdfepjhjbhnhkbgleap'  # Shodan
        )
    )

    Write-Status "[-] [Chrome Extensions] configuring ExtensionInstallForcelist policy" 'Cyan'
    try {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
        if (-not (Test-Path $policyPath)) {
            New-Item -Path $policyPath -Force | Out-Null
        }

        $i = 1
        foreach ($id in $ExtensionIds) {
            Set-ItemProperty -Path $policyPath -Name "$i" -Value "$id;https://clients2.google.com/service/update2/crx"
            $i++
        }

        Write-Status "[+] [Chrome Extensions] $($ExtensionIds.Count) extension(s) set to force-install - installs on next Chrome launch" 'Green'
        Add-Result -Name 'Chrome Extensions' -Status Installed -Detail "ExtensionInstallForcelist:$($ExtensionIds -join ',')"
        return $true
    } catch {
        Write-Status "[!] [Chrome Extensions] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Chrome Extensions' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Install-VulnConfig {
    $scriptUrl = 'https://raw.githubusercontent.com/orthrus1775/Windows-PrivEsc-Setup/master/vuln-config.ps1'
    $destFile  = Join-Path $script:DlRoot 'vuln-config.ps1'

    Write-Status "[-] [VulnConfig] downloading vuln-config.ps1" 'Cyan'
    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $destFile -UseBasicParsing
    } catch {
        Write-Status "[!] [VulnConfig] download failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'VulnConfig' -Status Skipped -Detail $_.Exception.Message
        return $false
    }

    # Runs as its own process rather than dot-sourced - the script defines its own helper
    # functions (Test-IsAdministrator, Set-WorkingDirectories, etc.) and unconditionally
    # self-executes Invoke-WinVulnsSetup at the bottom, so isolating it in a child process
    # avoids colliding with RedWindows' own function/variable names in this session.
    Write-Status "[-] [VulnConfig] running vuln-config.ps1 (creates the 'LocalSupport' admin account + intentionally vulnerable services/tasks/registry)" 'Cyan'
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File $destFile
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [VulnConfig] vuln-config.ps1 exited with code $LASTEXITCODE" 'Yellow'
        Add-Result -Name 'VulnConfig' -Status Skipped -Detail "exit $LASTEXITCODE"
        return $false
    }

    Write-Status "[+] [VulnConfig] applied" 'Green'
    Add-Result -Name 'VulnConfig' -Status Installed -Detail 'Windows-PrivEsc-Setup/vuln-config.ps1'
    return $true
}

function Remove-LocalSupportUser {
    # vuln-config.ps1 (Install-VulnConfig, Stage 3) creates this account as one of its
    # intentional privesc vectors - it's only needed for the vulnerable-config window
    # between Stage 3 and Stage 4, not for the finished box.
    Write-Status "[-] [LocalSupport user] removing (created by vuln-config.ps1)" 'Cyan'
    try {
        $existingUser = Get-LocalUser -Name 'LocalSupport' -ErrorAction SilentlyContinue
        if (-not $existingUser) {
            Write-Status "[+] [LocalSupport user] not present - skipping" 'DarkGray'
            Add-Result -Name 'LocalSupport user' -Status Skipped -Detail 'not present'
            return
        }

        if (Get-LocalGroupMember -Group 'Administrators' -Member 'LocalSupport' -ErrorAction SilentlyContinue) {
            Remove-LocalGroupMember -Group 'Administrators' -Member 'LocalSupport'
        }
        Remove-LocalUser -Name 'LocalSupport'

        Write-Status "[+] [LocalSupport user] removed from Administrators and deleted" 'Green'
        Add-Result -Name 'LocalSupport user' -Status Installed -Detail 'removed from Administrators + deleted'
    } catch {
        Write-Status "[!] [LocalSupport user] removal failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'LocalSupport user' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-Client {
    $batPath = 'C:\Tools\AdaptixC2\AdaptixClient\build.bat'

    Write-Status "[-] [Client] running $batPath" 'Cyan'
    try {
        if (-not (Test-Path $batPath)) {
            Write-Status "[!] [Client] $batPath not found - skipping" 'Yellow'
            Add-Result -Name 'Client' -Status Skipped -Detail "$batPath not found"
            return $false
        }

        $content = Get-Content -Path $batPath -Raw

        $content = $content -replace '%%PATH%%', '%PATH%'

        $content = $content -replace '(?im)^\s*pause\s*$', '%WINDIR%\System32\timeout.exe /T 30 /NOBREAK'
        Set-Content -Path $batPath -Value $content -NoNewline

        # build.bat doesn't cd to its own folder, so it inherits whatever CWD this was
        # launched from (e.g. C:\Windows\system32 for the autologon scheduled task) and
        # its relative cmake/dist paths resolve against the wrong directory.
        Push-Location (Split-Path -Path $batPath -Parent)
        try {
            cmd.exe /c "`"$batPath`""
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Client] $batPath exited with code $LASTEXITCODE" 'Yellow'
            Add-Result -Name 'Client' -Status Skipped -Detail "exit $LASTEXITCODE"
            return $false
        }

        Write-Status "[+] [Client] $batPath completed" 'Green'
        Add-Result -Name 'Client' -Status Installed -Detail $batPath
        return $true
    } catch {
        Write-Status "[!] [Client] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Client' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

# =============================================================================
# Package table
# =============================================================================
# Each entry declares its own install tiers in order; the first one that
# succeeds wins. Add more entries here to expand coverage over time.

function Get-PackageTable {
    return @(
        # --- Recon / network ---
        @{ Name = 'Nmap';               Tiers = @({ Install-WingetPackage 'Nmap' 'Insecure.Nmap' }) }
        @{ Name = 'Wireshark';          Tiers = @({ Install-WingetPackage 'Wireshark' 'WiresharkFoundation.Wireshark' }) }
        @{ Name = 'PuTTY';              Tiers = @({ Install-WingetPackage 'PuTTY' 'PuTTY.PuTTY' }) }
        @{ Name = 'MobaXterm';          Tiers = @({ Install-WingetPackage 'MobaXterm' 'Mobatek.MobaXterm' }) }

        # --- Core utilities ---
        @{ Name = 'Sysinternals Suite'; Tiers = @({ Install-WingetPackage 'Sysinternals Suite' '9P7KNL5RWT25' }) }
        @{ Name = '7-Zip';              Tiers = @({ Install-WingetPackage '7-Zip' '7zip.7zip' }) }
        #@{ Name = 'Python 3.13';        Tiers = @({ Install-WingetPackage 'Python 3.13' 'Python.Python.3.13' }) }
        #@{ Name = 'Go';                 Tiers = @({ Install-WingetPackage 'Go' 'GoLang.Go' }) }
        @{ Name = 'Gitleaks';           Tiers = @({ Install-WingetPackage 'Gitleaks' 'Gitleaks.Gitleaks' }) }
        @{ Name = 'vscode';            Tiers = @({ Install-WingetPackage 'vscode' 'Microsoft.VisualStudioCode' }) }
        @{ Name = 'Windows Terminal';   Tiers = @({ Install-WingetPackage 'Windows Terminal' 'Microsoft.WindowsTerminal' }) }
        @{ Name = 'Notepad++';          Tiers = @({ Install-WingetPackage 'Notepad++' 'Notepad++.Notepad++' }) }
        @{ Name = 'DB Browser SQLite';  Tiers = @({ Install-WingetPackage 'DB Browser SQLite' 'DBBrowserForSQLite.DBBrowserForSQLite' }) }
        @{ Name = 'KeePass';            Tiers = @({ Install-WingetPackage 'KeePass' 'DominikReichl.KeePass' }) }
        @{ Name = 'Adobe Acrobat Reader'; Tiers = @({ Install-WingetPackage 'Adobe Acrobat Reader' 'Adobe.Acrobat.Reader.64-bit' }) }
        # @{ Name = 'pipx';               Tiers = @({ Install-Pipx }) }
        @{ Name = 'JDK 17.0.2';       Tiers = @({ Install-Jdk17 }) }

        # --- Browsers ---
        @{ Name = 'Firefox';            Tiers = @({ Install-WingetPackage 'Firefox' 'Mozilla.Firefox.ESR' }) }
        @{ Name = 'Firefox Extensions'; Tiers = @({ Install-FirefoxExtensions }) }
        @{ Name = 'Google Chrome';      Tiers = @({ Install-WingetPackage 'Google Chrome' 'Google.Chrome' }) }
        @{ Name = 'Chrome Extensions';  Tiers = @({ Install-ChromeExtensions }) }

        # --- Web proxy / testing ---
        @{ Name = 'Burp Suite Community'; Tiers = @({ Install-WingetPackage 'Burp Suite Community' 'PortSwigger.BurpSuite.Community' }) }
        @{ Name = 'Fiddler Classic';       Tiers = @({ Install-WingetPackage 'Fiddler Classic' 'Telerik.Fiddler.Classic' }) }

        # --- Password / hash cracking ---
        @{ Name = 'Hashcat';   Tiers = @({ Install-GitHubReleaseAsset -Name 'Hashcat' -Repo 'hashcat/hashcat' -AssetPattern '*.7z' -Extract7z }) }

        @{ Name = 'SharpHound'; Tiers = @({ Install-GitHubReleaseAsset -Name 'SharpHound' -Repo 'SpecterOps/SharpHound' -DestRoot $script:SharpToolsRoot -AssetPattern '*.zip' -ExtractZip }) }
        @{ Name = 'Rubeus';     Tiers = @({ Install-FromSourceDotNet -Name 'Rubeus' -Repo 'GhostPack/Rubeus' -DestRoot $script:SharpToolsRoot }) }

        @{ Name = 'Certify';    Tiers = @({ Install-FromSourceDotNet -Name 'Certify' -Repo 'GhostPack/Certify' -DestRoot $script:SharpToolsRoot -Ref 'bee728d' }) }
        @{ Name = 'PowerSploit'; Tiers = @({ Install-GitCloneOnly -Name 'PowerSploit' -Repo 'PowerShellMafia/PowerSploit' }) }
        @{ Name = 'Responder'; Tiers = @({ Install-GitCloneOnly -Name 'Responder' -Repo 'lgandx/Responder' }) }
        @{ Name = 'ShadowHound'; Tiers = @({ Install-GitCloneOnly -Name 'ShadowHound' -Repo 'Friends-Security/ShadowHound' }) }

        # --- Python-based tooling (needs Python installed above first) ---
        @{ Name = 'Impacket';  Tiers = @({ Install-PipxPackage -Name 'Impacket' -PipxUrl 'impacket' }) }
        @{ Name = 'NetExec';   Tiers = @({ Install-PipxPackage -Name 'NetExec' -PipxUrl 'git+https://github.com/Pennyw0rth/NetExec' }) }
        @{ Name = 'bloodyAD';   Tiers = @({ Install-PipxPackage -Name 'bloodyAD' -PipxUrl 'git+https://github.com/CravateRouge/bloodyAD.git' }) }

        # --- DevTools (pinned releases, ported from lab-workstation.yml) ---
        @{ Name = 'FaceDancer';      Tiers = @({ Install-FromSourceRust -Name 'FaceDancer' -Repo 'Tylous/FaceDancer' -Target 'x86_64-pc-windows-gnu' }) }
        
        @{ Name = 'swarmer';         Tiers = @({ Install-GitHubReleaseAsset -Name 'swarmer' -Repo 'praetorian-inc/swarmer' -AssetPattern 'swarmer.exe' -Tag 'v0.1.8' }) }
        @{ Name = 'HiveSwarming';    Tiers = @({ Install-GitHubReleaseAsset -Name 'HiveSwarming' -Repo 'stormshield/HiveSwarming' -AssetPattern 'HiveSwarming.exe' -Tag 'v1.6' }) }

        # --- [BOF]-tagged tools from verify-packages.md -> C:\Tools\BOF ---
        @{ Name = 'bof-collection';                 Tiers = @({ Install-FromSourceBofMake -Name 'bof-collection' -Repo 'orthrus1775/BOF_Collection' -DestRoot $script:BofRoot -Recursive }) }
        @{ Name = 'BOF-patchit';                     Tiers = @({ Install-GitCloneOnly -Name 'BOF-patchit' -Repo 'ScriptIdiot/BOF-patchit' -DestRoot $script:BofRoot }) }
        @{ Name = 'BofRoast';                        Tiers = @({ Install-FromSourceBofMake -Name 'BofRoast' -Repo 'cube0x0/BofRoast' -DestRoot $script:BofRoot -MakeDir 'BofRoast' }) }
        @{ Name = 'C2-Tool-Collection';              Tiers = @({ Install-FromSourceBofMake -Name 'C2-Tool-Collection' -Repo 'outflanknl/C2-Tool-Collection' -DestRoot $script:BofRoot -MakeDir 'BOF' -Recursive }) }
        @{ Name = 'CredManBOF';                      Tiers = @({ Install-GitCloneOnly -Name 'CredManBOF' -Repo 'jsecu/CredManBOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'CS-Remote-OPs-BOF';               Tiers = @({ Install-GitCloneOnly -Name 'CS-Remote-OPs-BOF' -Repo 'trustedsec/CS-Remote-OPs-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'CS-Situational-Awareness-BOF';    Tiers = @({ Install-GitCloneOnly -Name 'CS-Situational-Awareness-BOF' -Repo 'trustedsec/CS-Situational-Awareness-BOF' -DestRoot $script:BofRoot -MakeDir 'src\SA' -Recursive }) }
        @{ Name = 'DelegationBOF';                   Tiers = @({ Install-FromSourceBofMake -Name 'DelegationBOF' -Repo 'orthrus1775/DelegationBOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'HandleKatz_BOF';                  Tiers = @({ Install-FromSourceBofMake -Name 'HandleKatz_BOF' -Repo 'EspressoCake/HandleKatz_BOF' -DestRoot $script:BofRoot -MakeDir 'src' }) }
        @{ Name = 'HOLLOW';                          Tiers = @({ Install-GitCloneOnly -Name 'HOLLOW' -Repo 'boku7/HOLLOW' -DestRoot $script:BofRoot }) }
        @{ Name = 'injectAmsiBypass';                Tiers = @({ Install-GitCloneOnly -Name 'injectAmsiBypass' -Repo 'boku7/injectAmsiBypass' -DestRoot $script:BofRoot }) }
        @{ Name = 'injectEtwBypass';                 Tiers = @({ Install-GitCloneOnly -Name 'injectEtwBypass' -Repo 'boku7/injectEtwBypass' -DestRoot $script:BofRoot }) }
        @{ Name = 'Kerbeus-BOF';                     Tiers = @({ Install-FromSourceBofMake -Name 'Kerbeus-BOF' -Repo 'orthrus1775/Kerbeus-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'nanorobeus';                      Tiers = @({ Install-FromSourceBofMake -Name 'nanorobeus' -Repo 'orthrus1775/nanorobeus' -DestRoot $script:BofRoot }) }
        @{ Name = 'No-Consolation';                  Tiers = @({ Install-FromSourceBofMake -Name 'No-Consolation' -Repo 'fortra/No-Consolation' -DestRoot $script:BofRoot }) }
        @{ Name = 'OperatorsKit';                    Tiers = @({ Install-FromSourceBof -Name 'OperatorsKit' -Repo 'REDMED-X/OperatorsKit' -DestRoot $script:BofRoot -BuildScript 'compile-all.bat' }) }
        @{ Name = 'PatchlessInlineExecute-Assembly'; Tiers = @({ Install-FromSourceBof -Name 'PatchlessInlineExecute-Assembly' -Repo 'VoldeSec/PatchlessInlineExecute-Assembly' -DestRoot $script:BofRoot -BuildScript 'src\compile.bat' }) }
        @{ Name = 'reg_export-BOF';                  Tiers = @({ Install-FromSourceBofMake -Name 'reg_export-BOF' -Repo 'Valkyrie-Security/reg_export-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'PoolPartyBof';                    Tiers = @({ Install-FromSourceBofMake -Name 'PoolPartyBof' -Repo '0xEr3bus/PoolPartyBof' -DestRoot $script:BofRoot }) }
        @{ Name = 'SCShell';                         Tiers = @({ Install-FromSourceBofMake -Name 'SCShell' -Repo 'Mr-Un1k0d3r/SCShell' -DestRoot $script:BofRoot -MakeDir 'CS-BOF' }) }
        @{ Name = 'ServiceMove-BOF';                 Tiers = @({ Install-FromSourceBofMake -Name 'ServiceMove-BOF' -Repo 'netero1010/ServiceMove-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'secinject';                       Tiers = @({ Install-FromSourceBofMake -Name 'secinject' -Repo 'apokryptein/secinject' -DestRoot $script:BofRoot -MakeDir 'src' }) }
        @{ Name = 'tgtdelegation';                   Tiers = @({ Install-FromSourceBofMake -Name 'tgtdelegation' -Repo 'connormcgarr/tgtdelegation' -DestRoot $script:BofRoot }) }
        # Verified end-to-end (compile error + strip lookup fixed via CC_x64/STRIP_x64 overrides).
        @{ Name = 'ThreadlessInject-BOF';            Tiers = @({ Install-FromSourceBofMake -Name 'ThreadlessInject-BOF' -Repo 'iilegacyyii/ThreadlessInject-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'Unhook-BOF';                      Tiers = @({ Install-FromSourceBof -Name 'Unhook-BOF' -Repo 'rsmudge/unhook-bof' -DestRoot $script:BofRoot }) }

        # --- [Sharp]/[SharpTool]-tagged tools -> C:\Tools\SharpTools (build via MSBuild) ---
        @{ Name = 'ADSearch';           Tiers = @({ Install-FromSourceDotNet -Name 'ADSearch' -Repo 'tomcarver16/ADSearch' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Net-GPPPassword';    Tiers = @({ Install-FromSourceDotNet -Name 'Net-GPPPassword' -Repo 'outflanknl/Net-GPPPassword' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'nopowershell';       Tiers = @({ Install-FromSourceDotNet -Name 'nopowershell' -Repo 'bitsadmin/nopowershell' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'RestrictedAdmin';    Tiers = @({ Install-FromSourceDotNet -Name 'RestrictedAdmin' -Repo 'GhostPack/RestrictedAdmin' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Sharp-SMBExec';      Tiers = @({ Install-FromSourceDotNet -Name 'Sharp-SMBExec' -Repo 'checkymander/Sharp-SMBExec' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpClipHistory';   Tiers = @({ Install-FromSourceDotNet -Name 'SharpClipHistory' -Repo 'ReversecLabs/SharpClipHistory' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpCollection';    Tiers = @({ Install-GitCloneOnly -Name 'SharpCollection' -Repo 'Flangvik/SharpCollection' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpDPAPI';         Tiers = @({ Install-FromSourceDotNet -Name 'SharpDPAPI' -Repo 'GhostPack/SharpDPAPI' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpDump';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpDump' -Repo 'GhostPack/SharpDump' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharPersist';        Tiers = @({ Install-FromSourceDotNet -Name 'SharPersist' -Repo 'mandiant/SharPersist' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpExec';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpExec' -Repo 'checkymander/Sharp-WMIExec' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpGPOAbuse';      Tiers = @({ Install-FromSourceDotNet -Name 'SharpGPOAbuse' -Repo 'ReversecLabs/SharpGPOAbuse' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpLAPS';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpLAPS' -Repo 'swisskyrepo/SharpLAPS' -DestRoot $script:SharpToolsRoot }) }
        # Release config is pinned to x64 in this repo, not AnyCPU.
        @{ Name = 'SharpMapExec';       Tiers = @({ Install-FromSourceDotNet -Name 'SharpMapExec' -Repo 'cube0x0/SharpMapExec' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpRDP';           Tiers = @({ Install-FromSourceDotNet -Name 'SharpRDP' -Repo '0xthirteen/SharpRDP' -DestRoot $script:SharpToolsRoot }) }
        # Release config is pinned to x64 in this repo, not AnyCPU.
        @{ Name = 'SharpSCCM';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpSCCM' -Repo 'Mayyhem/SharpSCCM' -DestRoot $script:SharpToolsRoot -Platform 'x64' }) }
        @{ Name = 'SharpSecDump';       Tiers = @({ Install-FromSourceDotNet -Name 'SharpSecDump' -Repo 'G0ldenGunSec/SharpSecDump' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'sharpsh';            Tiers = @({ Install-FromSourceDotNet -Name 'sharpsh' -Repo 'thelikes/sharpsh' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpUp';            Tiers = @({ Install-FromSourceDotNet -Name 'SharpUp' -Repo 'GhostPack/SharpUp' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpView';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpView' -Repo 'tevora-threat/SharpView' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpWMI';           Tiers = @({ Install-FromSourceDotNet -Name 'SharpWMI' -Repo 'GhostPack/SharpWMI' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SQLRecon';           Tiers = @({ Install-FromSourceDotNet -Name 'SQLRecon' -Repo 'skahwah/SQLRecon' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'StandIn';            Tiers = @({ Install-FromSourceDotNet -Name 'StandIn' -Repo 'FuzzySecurity/StandIn' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Whisker';            Tiers = @({ Install-FromSourceDotNet -Name 'Whisker' -Repo 'eladshamir/Whisker' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'DotNetToJScript';    Tiers = @({ Install-FromSourceDotNet -Name 'DotNetToJScript' -Repo 'tyranid/DotNetToJScript' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'ForgeCert';          Tiers = @({ Install-FromSourceDotNet -Name 'ForgeCert' -Repo 'GhostPack/ForgeCert' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'GadgetToJScript';    Tiers = @({ Install-FromSourceDotNet -Name 'GadgetToJScript' -Repo 'med0x2e/GadgetToJScript' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Group3r';            Tiers = @({ Install-FromSourceDotNet -Name 'Group3r' -Repo 'Group3r/Group3r' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'KeeThief';           Tiers = @({ Install-FromSourceDotNet -Name 'KeeThief' -Repo 'GhostPack/KeeThief' -DestRoot $script:SharpToolsRoot -SlnPath 'KeeTheft\KeeTheft.sln' }) }
        @{ Name = 'LdapSignCheck';      Tiers = @({ Install-FromSourceDotNet -Name 'LdapSignCheck' -Repo 'cube0x0/LdapSignCheck' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'KrbRelayUp';         Tiers = @({ Install-FromSourceDotNet -Name 'KrbRelayUp' -Repo 'Dec0ne/KrbRelayUp' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SauronEye';          Tiers = @({ Install-FromSourceDotNet -Name 'SauronEye' -Repo 'vivami/SauronEye' -DestRoot $script:SharpToolsRoot }) }
        # The repo's .sln (MS-RPRN.sln) also includes an unrelated native C++ RPC sample
        # project (MS-RPRN.vcxproj) that needs the Desktop C++ workload we don't install -
        # target the C# project directly instead. It only builds as x64, not AnyCPU.
        @{ Name = 'SpoolSample';        Tiers = @({ Install-FromSourceDotNet -Name 'SpoolSample' -Repo 'leechristensen/SpoolSample' -DestRoot $script:SharpToolsRoot -SlnPath 'SpoolSample\SpoolSample.csproj' -Platform 'x64' }) }
        @{ Name = 'ThreatCheck';        Tiers = @({ Install-FromSourceDotNet -Name 'ThreatCheck' -Repo 'rasta-mouse/ThreatCheck' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'BadAssMacros';       Tiers = @({ Install-FromSourceDotNet -Name 'BadAssMacros' -Repo 'Inf0secRabbit/BadAssMacros' -DestRoot $script:SharpToolsRoot }) }

        # --- [Cloud]-tagged tools -> C:\Tools\Cloud ---
        @{ Name = 'MicroBurst';     Tiers = @({ Install-GitCloneOnly -Name 'MicroBurst' -Repo 'NetSPI/MicroBurst' -DestRoot $script:CloudRoot }) }
        @{ Name = 'TeamFiltration'; Tiers = @({ Install-FromSourceDotNet -Name 'TeamFiltration' -Repo 'Flangvik/TeamFiltration' -DestRoot $script:CloudRoot }) }
        @{ Name = 'ADConnectDump';  Tiers = @({ Install-FromSourceDotNet -Name 'ADConnectDump' -Repo 'dirkjanm/adconnectdump' -DestRoot $script:CloudRoot }) }

        # --- [Potato]-tagged privesc tools -> C:\Tools\PotatoFarm ---
        @{ Name = 'Hot-Potato';     Tiers = @({ Install-FromSourceDotNet -Name 'Hot-Potato' -Repo 'davidmbillie/Hot-Potato' -DestRoot $script:PotatoRoot }) }
        # RottenPotato bundles NHttp and SharpCifs as separate .sln's it links against
        # rather than solution-referenced projects (its README has them built, then
        # ILMerge'd together) - build all three, in dependency order, before Potato.sln.
        @{ Name = 'RottenPotato';   Tiers = @({
            $nhttp = Install-FromSourceDotNet -Name 'RottenPotato' -Repo 'foxglovesec/RottenPotato' -DestRoot $script:PotatoRoot -SlnPath 'NHttp\NHttp.sln'
            $cifs  = Install-FromSourceDotNet -Name 'RottenPotato' -Repo 'foxglovesec/RottenPotato' -DestRoot $script:PotatoRoot -SlnPath 'SharpCifs\SharpCifs.sln'
            $main  = Install-FromSourceDotNet -Name 'RottenPotato' -Repo 'foxglovesec/RottenPotato' -DestRoot $script:PotatoRoot -SlnPath 'Potato\Potato.sln'
            $nhttp -and $cifs -and $main
        }) }
        @{ Name = 'juicy-potato';   Tiers = @({ Install-FromSourceNative -Name 'juicy-potato' -Repo 'ohpe/juicy-potato' -DestRoot $script:PotatoRoot -SlnPath 'JuicyPotato\JuicyPotato.sln' }) }
        @{ Name = 'RoguePotato';    Tiers = @({ Install-FromSourceNative -Name 'RoguePotato' -Repo 'antonioCoco/RoguePotato' -DestRoot $script:PotatoRoot -SlnPath 'RoguePotato.sln' }) }
        @{ Name = 'SweetPotato';    Tiers = @({ Install-FromSourceDotNet -Name 'SweetPotato' -Repo 'CCob/SweetPotato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'GenericPotato';  Tiers = @({ Install-FromSourceDotNet -Name 'GenericPotato' -Repo 'micahvandeusen/GenericPotato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'GodPotato';      Tiers = @({ Install-GitCloneOnly -Name 'GodPotato' -Repo 'BeichenDream/GodPotato' -DestRoot $script:PotatoRoot }) }

        # --- Nim modules -> C:\Tools\nimmods ---
        @{ Name = 'nim-rev-shell';  Tiers = @({ Install-GitCloneOnly -Name 'nim-rev-shell' -Repo 'Sn1r/Nim-Reverse-Shell' -DestRoot $script:NimModsRoot }) }
        @{ Name = 'offensivenim';   Tiers = @({ Install-GitCloneOnly -Name 'offensivenim' -Repo 'byt3bl33d3r/OffensiveNim' -DestRoot $script:NimModsRoot }) }
        @{ Name = 'nimcrypt2';      Tiers = @({ Install-GitCloneOnly -Name 'nimcrypt2' -Repo 'icyguider/Nimcrypt2' -DestRoot $script:NimModsRoot }) }
        @{ Name = 'nim-registry';   Tiers = @({ Install-GitCloneOnly -Name 'nim-registry' -Repo 'miere43/nim-registry' -DestRoot $script:NimModsRoot }) }
        @{ Name = 'nimbus';         Tiers = @({ Install-GitCloneOnly -Name 'nimbus' -Repo 'D3Ext/Nimbus' -DestRoot $script:NimModsRoot }) }
        @{ Name = 'partyloader';    Tiers = @({ Install-GitCloneOnly -Name 'partyloader' -Repo 'itaymigdal/PartyLoader' -DestRoot $script:NimModsRoot }) }

        # --- Install From Source -> default C:\Tools\ ---
        # Repo ships two variants (EXE loader + DLL loaded via rundll32) as separate solutions -
        # build both, same pattern as RottenPotato/RedTeamGrimoire above.
        @{ Name = 'Dumpert';                  Tiers = @({
            $exe = Install-FromSourceNative -Name 'Dumpert' -Repo 'outflanknl/Dumpert' -SlnPath 'Dumpert\Outflank-Dumpert.sln'
            $dll = Install-FromSourceNative -Name 'Dumpert' -Repo 'outflanknl/Dumpert' -SlnPath 'Dumpert-DLL\Outflank-Dumpert-DLL.sln'
            $exe -and $dll
        }) }
        @{ Name = 'IIS-Raid';                 Tiers = @({ Install-FromSourceNative -Name 'IIS-Raid' -Repo '0x09AL/IIS-Raid' -SlnPath 'module\IIS-Backdoor.sln' }) }
        @{ Name = 'PortBender';               Tiers = @({ Install-FromSourceNative -Name 'PortBender' -Repo 'praetorian-inc/PortBender' -SlnPath 'src\PortBender\PortBender.sln' }) }
        # RedTeamGrimoire bundles two unrelated tools (Charon, Doppelganger), each shipped as
        # several variants (legacy, no-CRT, XObolos) with their own .sln/.vcxproj under one repo -
        # build each variant against the shared clone, same pattern as RottenPotato above.
        # Release config is pinned to x64 in this repo, not AnyCPU.
        # Charon_ExternalPayloadVersion ships no .sln/.vcxproj (source-only) - not buildable here.
        @{ Name = 'RedTeamGrimoire';          Tiers = @({
            $charonLegacy  = Install-FromSourceNative -Name 'RedTeamGrimoire' -Repo 'vari-sh/RedTeamGrimoire' -SlnPath 'Charon\Charon_v1_Legacy\Charon\Charon.vcxproj' -Platform x64 -PlatformToolset 'v143'
            $doppelXObolos = Install-FromSourceNative -Name 'RedTeamGrimoire' -Repo 'vari-sh/RedTeamGrimoire' -SlnPath 'Doppelganger\DoppelgangerXObolos\Doppelganger.sln' -Platform x64 -PlatformToolset 'v143'
            $doppelNoCrt   = Install-FromSourceNative -Name 'RedTeamGrimoire' -Repo 'vari-sh/RedTeamGrimoire' -SlnPath 'Doppelganger\Doppelganger_noCRT\Doppelganger.sln' -Platform x64 -PlatformToolset 'v143'
            $doppelLegacy  = Install-FromSourceNative -Name 'RedTeamGrimoire' -Repo 'vari-sh/RedTeamGrimoire' -SlnPath 'Doppelganger\Doppelganger_v1_Legacy\Doppelganger.sln' -Platform x64 -PlatformToolset 'v143'
            $charonLegacy -and $doppelXObolos -and $doppelNoCrt -and $doppelLegacy
        }) }
        @{ Name = 'StreamDivert';             Tiers = @({ Install-FromSourceNative -Name 'StreamDivert' -Repo 'jellever/StreamDivert' -SlnPath 'StreamDivert.sln' }) }

        # --- Untagged repos from verify-packages.md -> default C:\Tools\ ---
        @{ Name = 'AdaptixC2';                Tiers = @({ Install-GitCloneOnly -Name 'AdaptixC2' -Repo 'Adaptix-Framework/AdaptixC2' }) }
        @{ Name = 'Crystal-Kit';              Tiers = @({ Install-GitCloneOnly -Name 'Crystal-Kit' -Repo 'rasta-mouse/Crystal-Kit' }) }
        @{ Name = 'C2-Profiles';              Tiers = @({ Install-GitCloneOnly -Name 'Crystal-Kit' -Repo 'BC-SECURITY/Malleable-C2-Profiles' }) }
        @{ Name = 'BloodHound-Custom-Queries'; Tiers = @({ Install-GitCloneOnly -Name 'BloodHound-Custom-Queries' -Repo 'CompassSecurity/BloodHoundQueries' }) }
        @{ Name = 'Crystal-Loaders';          Tiers = @({ Install-GitCloneOnly -Name 'Crystal-Loaders' -Repo 'rasta-mouse/Crystal-Loaders' }) }
        @{ Name = 'CS-Loader';                Tiers = @({ Install-GitCloneOnly -Name 'CS-Loader' -Repo 'Gality369/CS-Loader' }) }       
        @{ Name = 'EvilClippy';               Tiers = @({ Install-GitCloneOnly -Name 'EvilClippy' -Repo 'outflanknl/EvilClippy' }) }
        @{ Name = 'Freeze';                   Tiers = @({ Install-FromSourceRust -Name 'Freeze' -Repo 'Tylous/Freeze.rs' -Target 'x86_64-pc-windows-gnu' }) }
        @{ Name = 'Get-LAPSPasswords';        Tiers = @({ Install-GitCloneOnly -Name 'Get-LAPSPasswords' -Repo 'kfosaaen/Get-LAPSPasswords' }) }
        @{ Name = 'go-cookie-monster';        Tiers = @({ Install-FromSourceGo -Name 'go-cookie-monster' -Repo 'c2biz/go-cookie-monster' -Env @{ CGO_ENABLED = '1'; GOARCH = 'amd64'; GOOS = 'windows' } }) }
        @{ Name = 'GoBuster';                 Tiers = @({ Install-GoInstall -Name 'GoBuster' -Package 'github.com/OJ/gobuster/v3@latest' }) }
        @{ Name = 'GoWitness';                Tiers = @({ Install-GoInstall -Name 'GoWitness' -Package 'github.com/sensepost/gowitness@latest' }) }
        
        @{ Name = 'Invoke-DOSfuscation';      Tiers = @({ Install-GitCloneOnly -Name 'Invoke-DOSfuscation' -Repo 'danielbohannon/Invoke-DOSfuscation' }) }
        @{ Name = 'Invoke-Obfuscation';       Tiers = @({ Install-GitCloneOnly -Name 'Invoke-Obfuscation' -Repo 'danielbohannon/Invoke-Obfuscation' }) }
        @{ Name = 'Kerbrute';                 Tiers = @({ Install-GoInstall -Name 'Kerbrute' -Package 'github.com/ropnop/kerbrute@latest' }) }
        @{ Name = 'LDAPNomNom';               Tiers = @({ Install-GoInstall -Name 'LDAPNomNom' -Package 'github.com/lkarlslund/ldapnomnom@latest' }) }
        @{ Name = 'MailSniper';               Tiers = @({ Install-GitCloneOnly -Name 'MailSniper' -Repo 'dafthack/MailSniper' }) }
        @{ Name = 'MFASweep';                 Tiers = @({ Install-GitCloneOnly -Name 'MFASweep' -Repo 'dafthack/MFASweep' }) }
        @{ Name = 'PetitPotam';               Tiers = @({ Install-GitCloneOnly -Name 'PetitPotam' -Repo 'topotam/PetitPotam' }) }
        @{ Name = 'PowerMad';                 Tiers = @({ Install-GitCloneOnly -Name 'PowerMad' -Repo 'Kevin-Robertson/Powermad' }) }
        @{ Name = 'PowerUpSQL';               Tiers = @({ Install-GitCloneOnly -Name 'PowerUpSQL' -Repo 'NetSPI/PowerUpSQL' }) }
        @{ Name = 'PSPKIAudit';               Tiers = @({ Install-GitCloneOnly -Name 'PSPKIAudit' -Repo 'GhostPack/PSPKIAudit' }) }
        @{ Name = 'RustHound-CE';             Tiers = @({ Install-FromSourceRust -Name 'RustHound-CE' -Repo 'g0h4n/RustHound-CE' -Target 'x86_64-pc-windows-gnu' }) }
        @{ Name = 'rustyneedle';              Tiers = @({ Install-FromSourceRust -Name 'rustyneedle' -Repo 'mttaggart/rustyneedle' -Target 'x86_64-pc-windows-gnu' }) }
        @{ Name = 'Stracciatella';            Tiers = @({ Install-GitCloneOnly -Name 'Stracciatella' -Repo 'mgeeky/Stracciatella' }) }
        @{ Name = 'SuperMega';                Tiers = @({ Install-GitCloneOnly -Name 'SuperMega' -Repo 'dobin/SuperMega' -PipRequirements }) }
        @{ Name = 'upx';                      Tiers = @({ Install-FromSourceCMake -Name 'upx' -Repo 'upx/upx' -SubModule -Generator 'Visual Studio 17 2022' -Architecture x64 }) }
        @{ Name = 'ShieldBreak';              Tiers = @({ Install-GitCloneOnly -Name 'ShieldBreak' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/ShieldBreak.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'GreatXML';                 Tiers = @({ Install-GitCloneOnly -Name 'GreatXML' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/GreatXML.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'GreenPlasma';              Tiers = @({ Install-GitCloneOnly -Name 'GreenPlasma' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/GreenPlasma.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'UnDefend';                 Tiers = @({ Install-GitCloneOnly -Name 'UnDefend' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/UnDefend.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'BlueHammer';               Tiers = @({ Install-GitCloneOnly -Name 'BlueHammer' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/BlueHammer.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'YellowKey.';               Tiers = @({ Install-GitCloneOnly -Name 'YellowKey.' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/YellowKey.git '  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'MiniPlasma';               Tiers = @({ Install-GitCloneOnly -Name 'MiniPlasma' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/MiniPlasma.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'RedSun';                   Tiers = @({ Install-GitCloneOnly -Name 'RedSun' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/RedSun.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'ShieldBreak';              Tiers = @({ Install-GitCloneOnly -Name 'ShieldBreak' -Repo 'https://git.churchofmalware.org/Nightmare_Eclipse/ShieldBreak.git'  -DestRoot $script:NightmareEclipse }) }
        @{ Name = 'RegPwn';                   Tiers = @({ Install-FromSourceNative -Name 'RegPwn' -Repo 'mdsecactivebreach/RegPwn' -DestRoot $script:SharpToolsRoot -SlnPath 'RegPwn\RegPwn.sln' }) }
        @{ Name = 'RegPwnBOF';                Tiers = @({ Install-GitCloneOnly -Name 'RegPwnBOF' -Repo 'Flangvik/RegPwnBOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'eicar.com';                Tiers = @({ Get-RemoteFile -Url 'https://secure.eicar.org/eicar_com.zip' -Destination (Join-Path $script:ToolsRoot 'eicar_com.zip') }) }
        @{ Name = 'eicar.txt';                Tiers = @({ Get-RemoteFile -Url 'https://secure.eicar.org/eicar.com.txt' -Destination (Join-Path $script:ToolsRoot 'eicar_com.txt') }) }
        @{ Name = 'eicar.com2';               Tiers = @({ Get-RemoteFile -Url 'https://secure.eicar.org/eicar_com2.zip' -Destination (Join-Path $script:ToolsRoot 'eicar_com-2.zip') }) }
        # UACME bundles several independent UAC-bypass methods, each its own .vcxproj under
        # Source\ rather than one buildable tool - build each variant against the shared
        # clone, same pattern as RedTeamGrimoire above.
        @{ Name = 'UACME';                    Tiers = @({
            $akagi    = Install-FromSourceNative -Name 'UACME' -Repo 'hfiref0x/UACME' -SlnPath 'Source\Akagi\uacme.vcxproj'
            $akatsuki = Install-FromSourceNative -Name 'UACME' -Repo 'hfiref0x/UACME' -SlnPath 'Source\Akatsuki\Akatsuki.vcxproj'
            $fubuki   = Install-FromSourceNative -Name 'UACME' -Repo 'hfiref0x/UACME' -SlnPath 'Source\Fubuki\dll.vcxproj'
            $naka     = Install-FromSourceNative -Name 'UACME' -Repo 'hfiref0x/UACME' -SlnPath 'Source\Naka\Naka.vcxproj'
            $yuubari  = Install-FromSourceNative -Name 'UACME' -Repo 'hfiref0x/UACME' -SlnPath 'Source\Yuubari\Yuubari.vcxproj'
            $akagi -and $akatsuki -and $fubuki -and $naka -and $yuubari
        }) }
    )
}   


function Show-Summary {
    Write-Status "`n=== Summary (all stages) ===" 'Magenta'

    # $script:Results only holds this process's entries; every stage runs in its own process
    # (the machine reboots between them), so the full run's results live in $script:ResultsCsv.
    $allResults = if (Test-Path $script:ResultsCsv) { Import-Csv -Path $script:ResultsCsv } else { $script:Results }
    $allResults | Sort-Object Stage, Status, Name | Format-Table -Property Stage, Name, Status, Detail -AutoSize

    $installed = ($allResults | Where-Object { $_.Status -eq 'Installed' }).Count
    $skipped   = ($allResults | Where-Object { $_.Status -eq 'Skipped' }).Count
    Write-Status "`n$installed installed, $skipped skipped (see above for reasons)." 'White'
    Write-Status "Full transcript: $script:TranscriptFile" 'White'
    Write-Status "Full results log: $script:ResultsCsv" 'White'
}


function Initialize-Environment {
    $script:ToolsRoot      = 'C:\Tools'
    $script:PayloadRoot    = 'C:\Payloads'
    $script:cobaltstrike   = = Join-Path $script:ToolsRoot 'cobaltstrike'
    $script:UserProfileRoot = $env:USERPROFILE
    $script:AppDataLocal    = Join-Path $script:UserProfileRoot 'AppData\Local'
    $script:GoUserRoot      = Join-Path $script:UserProfileRoot 'go'
    $script:pipxtools = Join-Path $script:UserProfileRoot '.local'
    $script:DlRoot         = Join-Path $script:ToolsRoot 'downloads'
    $script:BofRoot        = Join-Path $script:ToolsRoot 'BOF'
    $script:SharpToolsRoot = Join-Path $script:ToolsRoot 'SharpTools'
    $script:NightmareEclipse = Join-Path $script:ToolsRoot 'NightmareEclipse'
    $script:CloudRoot      = Join-Path $script:ToolsRoot 'Cloud'
    $script:PotatoRoot     = Join-Path $script:ToolsRoot 'PotatoFarm'
    $script:NimModsRoot    = Join-Path $script:ToolsRoot 'nimmods'
    $script:LogRoot        = Join-Path $script:ToolsRoot 'logs'
    $script:TranscriptFile = Join-Path $script:LogRoot 'RedWindows-transcript.log'
    $script:ResultsCsv     = Join-Path $script:LogRoot 'RedWindows-results.csv'
    $script:Results        = New-Object System.Collections.Generic.List[object]
    $script:CurrentStage   = 0


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
    Install-Client
    Set-QuickAccess
    Set-QuickAccess -Path $script:PayloadRoot
    Set-Background

    Complete-Stage -NextStage 5
}

function Invoke-Stage5 {
    $script:CurrentStage = 5
    Write-Status "`n=== Stage 5: cleanup and finalize ===" 'Magenta'

    Clear-EventLogs
    Optimize-VmDisk

    Complete-Installation
    try { Stop-Transcript | Out-Null } catch {}
}

function Install-AllPackages {
    $packages = Get-PackageTable

    Write-Status "`n=== RedWindows: installing $($packages.Count) packages ===" 'Magenta'

    foreach ($pkg in $packages) {
        $name = $pkg.Name
        $done = $false

        for ($attempt = 1; $attempt -le 3 -and -not $done; $attempt++) {
            foreach ($tier in $pkg.Tiers) {
                try {
                    if (& $tier) { $done = $true; break }
                } catch {}
            }

            if (-not $done -and $attempt -lt 3) {
                Write-Status "[!] [$name] attempt $attempt/3 failed - retrying" 'Yellow'
                Start-Sleep -Seconds 10
            }
        }

        if (-not $done) {
            Write-Status "[x] [$name] all install tiers failed after 3 attempts - skipping" 'Red'
            Add-Result -Name $name -Status Skipped -Detail 'Failed'
        } else {
            Start-Sleep -Seconds 3
        }
        # Wait-ForStageBreakpoint -Message "[$name] done (success=$done) - press Enter for next package..."
    }
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

Main
