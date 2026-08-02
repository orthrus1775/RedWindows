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

# =============================================================================
# Logging / result tracking
# =============================================================================

function Write-Status {
    param([string]$Message, [string]$Color = 'White')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

function Record-Result {
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
    param([string]$Message, [string]$Level = 'INFO')
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
        $defenderPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
        $realtimePolicyKey = "$defenderPolicyKey\Real-Time Protection"
        foreach ($key in @($defenderPolicyKey, $realtimePolicyKey)) {
            if (!(Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        }
        New-ItemProperty -Path $defenderPolicyKey -Name DisableAntiSpyware -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $realtimePolicyKey -Name DisableRealtimeMonitoring -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Status "[+] Defender registry policy keys set" 'Green'
        Record-Result -Name 'Windows Defender' -Status Installed -Detail 'disabled (best-effort)'
    } catch {
        Write-Status "[!] Defender registry policy failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'Windows Defender' -Status Skipped -Detail $_.Exception.Message
    }
}

function Disable-ScreenSaver {
    Write-Status "[-] [Screensaver] disabling" 'Cyan'
    try {
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveActive -Value 0 -Type DWord
        powercfg -x -monitor-timeout-ac 0
        powercfg -x -monitor-timeout-dc 0
        Write-Status "[+] [Screensaver] disabled" 'Green'
        Record-Result -Name 'Screensaver' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Screensaver] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'Screensaver' -Status Skipped -Detail $_.Exception.Message
    }
}

function Disable-WindowsUpdates {
    Write-Status "[-] [Windows Update] disabling automatic updates" 'Cyan'
    try {
        $updates = (New-Object -ComObject 'Microsoft.Update.AutoUpdate').Settings
        if ($updates.ReadOnly) {
            Write-Status "[!] [Windows Update] settings are read-only (GPO-restricted) - skipping" 'Yellow'
            Record-Result -Name 'Windows Update' -Status Skipped -Detail 'read-only (GPO restricted)'
            return
        }

        $updates.NotificationLevel = 1 # Disabled
        $updates.Save()
        $updates.Refresh()
        Write-Status "[+] [Windows Update] automatic updates disabled" 'Green'
        Record-Result -Name 'Windows Update' -Status Installed -Detail 'disabled'
    } catch {
        Write-Status "[!] [Windows Update] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'Windows Update' -Status Skipped -Detail $_.Exception.Message
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
        Record-Result -Name 'OpenSSH Server' -Status Installed -Detail 'capability + sshd + firewall rule'
    } catch {
        Write-Status "[!] [OpenSSH Server] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'OpenSSH Server' -Status Skipped -Detail $_.Exception.Message
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
        Record-Result -Name 'Power plan' -Status Installed -Detail 'high performance'
    } catch {
        Write-Status "[!] [Power plan] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'Power plan' -Status Skipped -Detail $_.Exception.Message
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
            Record-Result -Name 'attacker user' -Status Installed -Detail 'already present'
            return
        }

        New-LocalUser $username -Password $password -FullName 'Attacker' -Description 'Red team operator user' | Out-Null
        Write-Status "[+] [attacker user] created" 'Green'

        Add-LocalGroupMember -Group 'Administrators' -Member $username
        Write-Status "[+] [attacker user] added to Administrators group" 'Green'

        Record-Result -Name 'attacker user' -Status Installed -Detail 'local user + Administrators'
    } catch {
        Write-Status "[!] [attacker user] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'attacker user' -Status Skipped -Detail $_.Exception.Message
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
        Record-Result -Name 'Auto-login' -Status Skipped -Detail 'Autologon64.exe unavailable'
        return
    }

    try {
        & $autologonExe attacker . 'GoCyber2026!!' /accepteula | Out-Null
        Write-Status "[+] [Auto-login] configured for 'attacker'" 'Green'
        Record-Result -Name 'Auto-login' -Status Installed -Detail 'attacker'
    } catch {
        Write-Status "[!] [Auto-login] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'Auto-login' -Status Skipped -Detail $_.Exception.Message
    }
}

function Install-Winget {
    Write-Status "[-] [winget] checking for existing installation" 'Cyan'

    # Get-Command -ErrorAction SilentlyContinue is the safe way to probe for a command that
    # might not exist. Calling `winget` directly when it's not on PATH throws a terminating
    # CommandNotFoundException during command lookup - before `2>$null` redirection even
    # applies - which crashes the whole script under $ErrorActionPreference = 'Stop' since
    # this runs outside any try/catch and Invoke-Stage1 doesn't wrap this call either.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $existing = winget --version 2>$null
        if ($existing) {
            Write-Status "[+] [winget] already installed ($existing)" 'DarkGray'
            Record-Result -Name 'winget' -Status Installed -Detail 'already present'
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
            Record-Result -Name 'winget' -Status Installed -Detail $verify
        } else {
            # Expected - the App Execution Alias for winget.exe usually isn't
            # resolvable in the session that just registered it. That's the
            # whole reason Stage 1 ends with a restart.
            Write-Status "[!] [winget] installed but not yet resolvable in this session - expected, resolves after restart" 'Yellow'
            Record-Result -Name 'winget' -Status Installed -Detail 'installed, pending restart'
        }
    } catch {
        Write-Status "[!] [winget] install failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name 'winget' -Status Skipped -Detail $_.Exception.Message
    }
}

# =============================================================================
# Staging / continuation across reboots
# =============================================================================
# winget needs a fresh session before its PATH alias resolves, and the same
# is true of Git's PATH entry right after a winget install - so this script
# runs in four stages, rebooting into the attacker user's autologon session
# between each one via a scheduled task that re-invokes this same file.
#
# Stage 3 exists for the same reason as Stage 2: Python/Go/Rust/MSYS2/VS2022 all
# write PATH/environment changes that the *current* process won't see. Installing
# them there and rebooting before Stage 4 means the whole Get-PackageTable run
# (pip installs, go/cargo/msbuild builds) sees a fully-resolved environment
# instead of fighting session-PATH staleness one function at a time.

function Get-RedWindowsStage {
    $stageFile = Join-Path $script:ToolsRoot '.redwindows-stage'
    if (Test-Path $stageFile) {
        return [int](Get-Content $stageFile -Raw).Trim()
    }
    return 1
}

function Set-RedWindowsStage {
    param([int]$Stage)
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
    param([string]$ScriptPath)

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

function Complete-Stage {
    param([int]$NextStage)

    $selfPath = Save-SelfCopy
    Set-RedWindowsStage -Stage $NextStage
    Register-ContinuationTask -ScriptPath $selfPath

    Write-Status "`n=== Stage complete - restarting to continue as stage $NextStage ===" 'Magenta'
    # Flush the transcript to disk before the forced restart kills this process - the next
    # stage's Start-Transcript -Append picks back up in the same file.
    try { Stop-Transcript | Out-Null } catch {}
    Restart-Computer -Force
}

# =============================================================================
# Tier 1: winget
# =============================================================================

function Install-WingetPackage {
    param([string]$Name, [string]$Id)

    # Same CommandNotFoundException risk as Install-Winget (see its comment) - this function
    # is also called directly and unwrapped from Invoke-Stage2 (installing Git), not just via
    # the try/catch-protected tier closures in Install-AllPackages, so it needs its own guard.
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] winget is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] winget install $Id" 'Cyan'
    # 2>$null here, not 2>&1 - merging a native command's stderr into the success stream turns
    # any line it writes there into a terminating error under $ErrorActionPreference = 'Stop',
    # even a completely benign one, before $LASTEXITCODE is ever checked. See Install-Pipx for
    # the confirmed case (pip's harmless PATH warning killed the whole tier this way).
    $existing = winget list --id $Id --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing -match [regex]::Escape($Id)) {
        Write-Status "[+] [$Name] already installed" 'DarkGray'
        Record-Result -Name $Name -Status Installed -Detail 'already present'
        return $true
    }

    winget install --id $Id -e --silent --accept-source-agreements --accept-package-agreements *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Status "[+] [$Name] installed via winget" 'Green'
        Record-Result -Name $Name -Status Installed -Detail "winget:$Id"
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

function Install-GitHubReleaseAsset {
    param(
        [string]$Name,
        [string]$Repo,          # "owner/repo"
        [string]$AssetPattern,  # wildcard match against release asset file names
        [string]$Tag,           # optional - a specific tag instead of the latest release
        [switch]$ExtractZip
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

    $destDir = Join-Path $script:BinRoot $Name
    if ($ExtractZip) {
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
    Record-Result -Name $Name -Status Installed -Detail "github-release:$Repo/$($asset.name)"
    return $true
}

# =============================================================================
# Tier 3: git clone + build from source
# =============================================================================

function Get-MSBuildPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe 2>$null | Select-Object -First 1
        if ($vsPath) { return $vsPath }
    }
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Add-LegacyReferenceAssemblies {
    param([string]$CloneDir)

    # VS2022's installer no longer offers targeting packs for v3.5/v4.0/v4.5/v4.5.1/v4.5.2
    # (see Install-VS2022Components), so old-style csproj files pinned to those
    # TargetFrameworkVersions fail to restore/build. The Microsoft.NETFramework.ReferenceAssemblies
    # NuGet packages ship the same reference assemblies and work with PackageReference-based
    # restore regardless of SDK-style vs legacy csproj, so patch one in wherever it's needed.
    $packMap = @{
        'v3.5'   = 'net35'
        'v4.0'   = 'net40'
        'v4.5'   = 'net45'
        'v4.5.1' = 'net451'
        'v4.5.2' = 'net452'
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

function Install-FromSourceDotNet {
    param(
        [string]$Name,
        [string]$Repo,
        [string]$DestRoot = $script:ToolsRoot,
        # Relative path (from $cloneDir) to a specific .sln/.csproj - needed for repos where a
        # recursive *.sln search would find no solution at all, or would find the wrong one
        # among several (e.g. KeeThief ships 3 unrelated .sln files alongside the real one).
        [string]$SlnPath,
        # MSBuild /p:Platform override - needed for repos that pin their Release config to a
        # specific platform (e.g. SharpMapExec/SharpSCCM build Release|x64 only, not AnyCPU).
        [string]$Platform
    )

    $cloneDir = Join-Path $DestRoot $Name
    Write-Status "[-] [$Name] git clone $Repo" 'Cyan'
    try {
        if (Test-Path $cloneDir) {
            git -C $cloneDir pull --quiet
        } else {
            git clone --quiet "https://github.com/$Repo.git" $cloneDir
        }
    } catch {
        Write-Status "[!] [$Name] git clone failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    Add-LegacyReferenceAssemblies -CloneDir $cloneDir

    $msbuild = Get-MSBuildPath
    if (-not $msbuild) {
        Write-Status "[!] [$Name] cloned but MSBuild is not available - install Visual Studio Build Tools to build it" 'Yellow'
        return $false
    }

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

    $msbuildArgs = @($projectFile.FullName, '/p:Configuration=Release', '/t:Restore,Build', '/verbosity:quiet')
    if ($Platform) { $msbuildArgs += "/p:Platform=$Platform" }

    Write-Status "[-] [$Name] building $($projectFile.Name)" 'Cyan'
    & $msbuild @msbuildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] build failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] built from source at $cloneDir" 'Green'
    Record-Result -Name $Name -Status Installed -Detail "source-build:$Repo"
    return $true
}

function Install-GitCloneOnly {
    param([string]$Name, [string]$Repo, [string]$DestRoot = $script:ToolsRoot)

    $cloneDir = Join-Path $DestRoot $Name
    Write-Status "[-] [$Name] git clone $Repo (script tool, no build needed)" 'Cyan'
    try {
        if (Test-Path $cloneDir) {
            git -C $cloneDir pull --quiet
        } else {
            git clone --quiet "https://github.com/$Repo.git" $cloneDir
        }
    } catch {
        Write-Status "[!] [$Name] git clone failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] cloned to $cloneDir" 'Green'
    Record-Result -Name $Name -Status Installed -Detail "git-clone:$Repo"
    return $true
}

function Update-SessionPath {
    # winget/rustup/etc. write their PATH additions to the registry (Machine/User scope), but
    # a process that's already running - like this script, mid-Stage-3 - won't see them until
    # something re-reads and re-joins those values into the live $env:Path.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Install-FromSourceGo {
    param([string]$Name, [string]$Repo, [string]$DestRoot = $script:ToolsRoot)

    $cloneDir = Join-Path $DestRoot $Name
    Write-Status "[-] [$Name] git clone $Repo" 'Cyan'
    try {
        if (Test-Path $cloneDir) {
            git -C $cloneDir pull --quiet
        } else {
            git clone --quiet "https://github.com/$Repo.git" $cloneDir
        }
    } catch {
        Write-Status "[!] [$Name] git clone failed: $($_.Exception.Message)" 'Yellow'
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
    try {
        # *>$null, not 2>&1 - see the comment in Install-WingetPackage. go build routinely
        # writes non-fatal notices (module downloads, deprecation warnings) to stderr.
        go build -o $outExe . *>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$Name] go build failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
    } finally {
        Pop-Location
    }

    Write-Status "[+] [$Name] built from source at $outExe" 'Green'
    Record-Result -Name $Name -Status Installed -Detail "source-build-go:$Repo"
    return $true
}

function Install-FromSourceRust {
    param([string]$Name, [string]$Repo, [string]$DestRoot = $script:ToolsRoot)

    $cloneDir = Join-Path $DestRoot $Name
    Write-Status "[-] [$Name] git clone $Repo" 'Cyan'
    try {
        if (Test-Path $cloneDir) {
            git -C $cloneDir pull --quiet
        } else {
            git clone --quiet "https://github.com/$Repo.git" $cloneDir
        }
    } catch {
        Write-Status "[!] [$Name] git clone failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    Update-SessionPath
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        Write-Status "[!] [$Name] cloned but cargo is not on PATH - install Rust first" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] cargo build --release" 'Cyan'
    Push-Location $cloneDir
    try {
        # *>$null, not 2>&1 - see the comment in Install-WingetPackage. cargo writes its normal
        # build progress ("Compiling foo v0.1.0", etc.) to stderr by design on every build,
        # success or not, so 2>&1 here would fail this tier unconditionally.
        & $cargo.Source build --release *>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [$Name] cargo build failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
    } finally {
        Pop-Location
    }

    Write-Status "[+] [$Name] built from source at $cloneDir\target\release" 'Green'
    Record-Result -Name $Name -Status Installed -Detail "source-build-rust:$Repo"
    return $true
}

function Install-PipPackage {
    param([string]$Name, [string]$PipName)

    # Python is installed via winget earlier in this same Stage 3 process. Without refreshing
    # $env:Path here, bare `python` resolves to the Windows Store's App Execution Alias stub
    # (not the real interpreter winget just installed) and errors with "Python was not found" -
    # same class of just-installed-this-session PATH staleness as the Go/Rust build tiers.
    Update-SessionPath
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] python is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [$Name] pip install $PipName" 'Cyan'
    # *>$null, not 2>&1 - see the comment in Install-WingetPackage. pip routinely writes
    # harmless warnings to stderr (e.g. "script X is not on PATH") that would otherwise fail
    # this tier even on an install that fully succeeded.
    python -m pip install --quiet --upgrade $PipName *>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [$Name] pip install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [$Name] installed via pip" 'Green'
    Record-Result -Name $Name -Status Installed -Detail "pip:$PipName"
    return $true
}

function Install-Pipx {
    # See the comment in Install-PipPackage - same PATH-staleness issue applies here.
    Update-SessionPath
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [pipx] python is not on PATH - skipping" 'Yellow'
        return $false
    }

    Write-Status "[-] [pipx] pip install --user pipx" 'Cyan'
    # *>$null, not 2>&1 - see the comment in Install-PipPackage/Install-WingetPackage. This
    # exact line is what was actually killing pipx (and, by the same path, Impacket/NetExec
    # further down the table): pip's harmless "script X is not on PATH" warning on stderr was
    # getting promoted to a terminating error under $ErrorActionPreference = 'Stop' before
    # $LASTEXITCODE was ever checked, even though the pip install itself succeeded.
    python -m pip install --quiet --upgrade --user pipx *>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [pipx] pip install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    python -m pipx ensurepath *>$null

    Write-Status "[+] [pipx] installed via pip" 'Green'
    Record-Result -Name 'pipx' -Status Installed -Detail 'pip:pipx'
    return $true
}

# =============================================================================
# Bespoke installers (don't fit the winget/GitHub-release/source-build shape)
# =============================================================================

function Install-Rust {
    $rustup    = Join-Path $script:DlRoot 'rustup-init.exe'
    $rustc     = Join-Path $env:USERPROFILE '.cargo\bin\rustc.exe'
    $rustupDir = Join-Path $env:USERPROFILE '.rustup'

    if (Test-Path $rustc) {
        Write-Status "[+] [Rust] already installed" 'DarkGray'
        Record-Result -Name 'Rust' -Status Installed -Detail 'already present'
        return $true
    }

    if (Test-Path $rustupDir) {
        Remove-Item -Path $rustupDir -Recurse -Force
    }

    Write-Status "[-] [Rust] downloading rustup-init.exe" 'Cyan'
    try {
        Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $rustup -UseBasicParsing
    } catch {
        Write-Status "[!] [Rust] download failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    & $rustup -q -y
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [Rust] rustup-init failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    Write-Status "[+] [Rust] installed via rustup" 'Green'
    Record-Result -Name 'Rust' -Status Installed -Detail 'rustup-init'
    return $true
}

function Install-Msys2 {
    $destRoot = 'C:\'
    $msys2Dir = 'C:\msys64'

    if (Test-Path $msys2Dir) {
        Write-Status "[+] [MSYS2] already installed at $msys2Dir" 'DarkGray'
        Record-Result -Name 'MSYS2' -Status Installed -Detail 'already present'
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
    Record-Result -Name 'MSYS2' -Status Installed -Detail "github-release:msys2/msys2-installer/$($asset.name)"
    return $true
}

function Install-MsysToolchain {
    # MSYS2's usr\bin\bash.exe runs a one-shot command non-interactively with no window to
    # babysit - unlike ucrt64.exe/mingw64.exe, which are just launchers for an interactive
    # mintty/conhost shell and aren't meant to be scripted against.
    $bash = 'C:\msys64\usr\bin\bash.exe'
    if (-not (Test-Path $bash)) {
        Write-Status "[!] [MSYS2 toolchain] bash.exe not found - install MSYS2 first" 'Yellow'
        return $false
    }

    # mingw-w64-x86_64-* (classic MinGW64), not mingw-w64-ucrt-x86_64-* (UCRT64) - this matches
    # the x86_64-w64-mingw32-gcc naming the BOF-building repos in this script's docs expect.
    $mingwGcc = 'C:\msys64\mingw64\bin\gcc.exe'
    if (Test-Path $mingwGcc) {
        Write-Status "[+] [MSYS2 toolchain] already installed" 'DarkGray'
        Record-Result -Name 'MSYS2 toolchain' -Status Installed -Detail 'already present'
        return $true
    }

    # The first -Syu pass often updates pacman/msys2-runtime itself and, in the interactive
    # shell, prompts you to close and reopen the terminal before continuing. Each bash.exe
    # invocation here is already a fresh process, so running it a second time is the
    # non-interactive equivalent of that restart.
    #
    Write-Status "[-] [MSYS2 toolchain] pacman -Syu (core update pass 1/2)" 'Cyan'
    C:\msys64\usr\bin\bash.exe -lc 'pacman -Syu --noconfirm --needed' | Out-Null
    Write-Status "[-] [MSYS2 toolchain] pacman -Syu (core update pass 2/2)" 'Cyan'
    C:\msys64\usr\bin\bash.exe -lc 'pacman -Syu --noconfirm --needed' | Out-Null

    Write-Status "[-] [MSYS2 toolchain] installing base-devel, mingw-w64 gcc/cmake/qt6" 'Cyan'
    C:\msys64\usr\bin\bash.exe -lc 'pacman -S --noconfirm --needed base-devel mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake mingw-w64-x86_64-qt6' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [MSYS2 toolchain] pacman install failed (exit $LASTEXITCODE)" 'Yellow'
        return $false
    }

    if (-not (Test-Path $mingwGcc)) {
        Write-Status "[!] [MSYS2 toolchain] pacman succeeded but gcc.exe not found at $mingwGcc" 'Yellow'
        return $false
    }

    # Add mingw64\bin to user PATH (and this session) so gcc/cmake resolve for later steps
    # (Nim's build, ad-hoc BOF compilation) without needing an MSYS2 shell at all.
    $mingwBin = 'C:\msys64\mingw64\bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    if ($pathEntries -notcontains $mingwBin) {
        $newPath = if ($userPath) { "$userPath;$mingwBin" } else { $mingwBin }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path += ";$mingwBin"
    }

    Write-Status "[+] [MSYS2 toolchain] installed, $mingwBin added to user PATH" 'Green'
    Record-Result -Name 'MSYS2 toolchain' -Status Installed -Detail 'base-devel + mingw-w64-x86_64-toolchain/cmake/qt6'
    return $true
}

function Install-NimFromSource {
    $nimHome = Join-Path $script:ToolsRoot 'Nim'
    $nimExe  = Join-Path $nimHome 'bin\nim.exe'

    if (Test-Path $nimExe) {
        Write-Status "[+] [Nim] already built at $nimHome" 'DarkGray'
        Record-Result -Name 'Nim' -Status Installed -Detail 'already present'
        return $true
    }

    # The csources_v2 C bootstrap step needs a C compiler on PATH - gcc (e.g.
    # from MSYS2's mingw-w64 packages, not installed by Install-Msys2 itself)
    # or MSVC's cl.exe (needs a Developer shell, not just VS installed).
    $hasCompiler = (Get-Command gcc -ErrorAction SilentlyContinue) -or (Get-Command cl -ErrorAction SilentlyContinue)
    if (-not $hasCompiler) {
        Write-Status "[!] [Nim] no C compiler (gcc/cl) on PATH - install MSYS2's mingw-w64 gcc or run from a VS Developer shell first" 'Yellow'
        return $false
    }

    Write-Status "[-] [Nim] cloning nim-lang/Nim" 'Cyan'
    try {
        if (Test-Path $nimHome) {
            git -C $nimHome pull --quiet
        } else {
            git clone --quiet https://github.com/nim-lang/Nim.git $nimHome
        }
    } catch {
        Write-Status "[!] [Nim] git clone failed: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $csourcesDir = Join-Path $nimHome 'csources_v2'
    if (-not (Test-Path $csourcesDir)) {
        Write-Status "[-] [Nim] cloning csources_v2 (C bootstrap sources)" 'Cyan'
        try {
            git clone --quiet --depth 1 https://github.com/nim-lang/csources_v2.git $csourcesDir
        } catch {
            Write-Status "[!] [Nim] csources_v2 clone failed: $($_.Exception.Message)" 'Yellow'
            return $false
        }
    }

    Write-Status "[-] [Nim] building bootstrap compiler (csources_v2\build.bat)" 'Cyan'
    Push-Location $csourcesDir
    try {
        & '.\build.bat'
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Nim] csources build.bat failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }
    } finally {
        Pop-Location
    }

    Write-Status "[-] [Nim] bootstrapping koch and building the release compiler" 'Cyan'
    Push-Location $nimHome
    try {
        & (Join-Path $nimHome 'bin\nim.exe') c koch
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Nim] 'nim c koch' failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }

        & (Join-Path $nimHome 'koch.exe') boot -d:release
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Nim] 'koch boot' failed (exit $LASTEXITCODE)" 'Yellow'
            return $false
        }

        & (Join-Path $nimHome 'koch.exe') tools
        if ($LASTEXITCODE -ne 0) {
            Write-Status "[!] [Nim] 'koch tools' failed (exit $LASTEXITCODE) - core compiler still built, continuing" 'Yellow'
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $nimExe)) {
        Write-Status "[!] [Nim] build finished but nim.exe not found at $nimExe" 'Yellow'
        return $false
    }

    $nimBin = Join-Path $nimHome 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) { $userPath -split ';' } else { @() }
    if ($pathEntries -notcontains $nimBin) {
        $newPath = if ($userPath) { "$userPath;$nimBin" } else { $nimBin }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path += ";$nimBin"
    }

    Write-Status "[+] [Nim] built from source at $nimHome, added to user PATH" 'Green'
    Record-Result -Name 'Nim' -Status Installed -Detail 'source-build:nim-lang/Nim'
    return $true
}

function Enable-NetFx35Feature {
    # VS2022's ".NET Framework 3.5 developer tools" component lets projects target 3.5, but
    # the CLR 2.0 runtime it needs (and that e.g. KeeThief's ILMerge post-build step hardcodes
    # a path to) only exists once this Windows feature itself is enabled.
    Write-Status "[-] [.NET Framework 3.5] enabling Windows feature" 'Cyan'
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3
        if ($feature.State -eq 'Enabled') {
            Write-Status "[+] [.NET Framework 3.5] already enabled" 'DarkGray'
            Record-Result -Name '.NET Framework 3.5' -Status Installed -Detail 'already enabled'
            return $true
        }

        Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart | Out-Null
        Write-Status "[+] [.NET Framework 3.5] enabled" 'Green'
        Record-Result -Name '.NET Framework 3.5' -Status Installed -Detail 'Windows feature enabled'
        return $true
    } catch {
        Write-Status "[!] [.NET Framework 3.5] failed: $($_.Exception.Message)" 'Yellow'
        Record-Result -Name '.NET Framework 3.5' -Status Skipped -Detail $_.Exception.Message
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
        # Workloads
        # (no separate VCTools workload - it's a Build Tools SKU id and isn't in Community's
        # product graph; NativeDesktop already pulls in the C++ toolchain)
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
        'Microsoft.Component.MSBuild', # not VisualStudio.Component.MSBuild
        # Note: TestTools.BuildTools has no equivalent in Community's product graph
        # (it's a Build Tools SKU-only id); dropped.

        # Note: Windows10SDK.17763 is no longer offered by the VS2022 installer (current
        # channel only ships 19041/22621/26100+). SharpClipHistory hardcodes winmd paths
        # under 17763, so it needs the standalone Windows 10 SDK (17763) installer instead;
        # that's a known, accepted gap (see Build_Instructions.md).

        # .NET
        'Microsoft.Net.Component.4.8.SDK',
        'Microsoft.Net.Component.4.7.2.TargetingPack',

        # Older targeting packs needed by GhostPack-style source-build tools
        # (SharpDPAPI/SharpDump/Sharp-SMBExec/SharpGPOAbuse/SharpUp/DotNetToJScript/KeeThief -> 3.5,
        # ForgeCert/StandIn/SpoolSample/SharpMapExec/SharpRDP/Sharp-WMIExec -> 4.5,
        # sharpsh/Group3r -> 4.5.1, SharpView -> 4.5.2, GadgetToJScript -> 4.6.1).
        # Note: as of the current channel, VS2022's installer offers no targeting pack for
        # 4.0 and has dropped 4.5/4.5.1/4.5.2 too (4.6.1 is now the oldest one offered).
        # Add-LegacyReferenceAssemblies covers that gap for source-built tools by patching
        # in the matching Microsoft.NETFramework.ReferenceAssemblies NuGet package instead.
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
    Record-Result -Name 'VS2022 Components' -Status Installed -Detail "$($vsComponents.Count) components"
    return $true
}

function Install-Jdk17 {
    $jdkUrl  = 'https://download.java.net/java/GA/jdk17.0.2/dfd4a8d0985749f896bed50d7138ee7f/8/GPL/openjdk-17.0.2_windows-x64_bin.zip'
    $jdkHome = 'C:\Program Files\jdk-17.0.2'
    $jdkBin  = Join-Path $jdkHome 'bin'

    if (Test-Path (Join-Path $jdkBin 'javac.exe')) {
        Write-Status "[+] [JDK 17] already installed at $jdkHome" 'DarkGray'
        Record-Result -Name 'JDK 17' -Status Installed -Detail 'already present'
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
    Record-Result -Name 'JDK 17' -Status Installed -Detail "manual-download:$jdkUrl"
    return $true
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
        @{ Name = 'Sysinternals Suite'; Tiers = @({ Install-WingetPackage 'Sysinternals Suite' 'Microsoft.Sysinternals.Suite' }) }
        @{ Name = '7-Zip';              Tiers = @({ Install-WingetPackage '7-Zip' '7zip.7zip' }) }
        @{ Name = 'Git';                Tiers = @({ Install-WingetPackage 'Git' 'Git.Git' }) }
        @{ Name = 'Python 3.13';        Tiers = @({ Install-WingetPackage 'Python 3.13' 'Python.Python.3.13' }) }
        @{ Name = 'Go';                 Tiers = @({ Install-WingetPackage 'Go' 'GoLang.Go' }) }
        @{ Name = 'Gitleaks';           Tiers = @({ Install-WingetPackage 'Gitleaks' 'Gitleaks.Gitleaks' }) }
        @{ Name = 'VS Code';            Tiers = @({ Install-WingetPackage 'VS Code' 'Microsoft.VisualStudioCode' }) }
        @{ Name = 'Windows Terminal';   Tiers = @({ Install-WingetPackage 'Windows Terminal' 'Microsoft.WindowsTerminal' }) }
        @{ Name = 'Notepad++';          Tiers = @({ Install-WingetPackage 'Notepad++' 'Notepad++.Notepad++' }) }
        @{ Name = 'DB Browser SQLite';  Tiers = @({ Install-WingetPackage 'DB Browser SQLite' 'DBBrowserForSQLite.DBBrowserForSQLite' }) }
        @{ Name = 'KeePass';            Tiers = @({ Install-WingetPackage 'KeePass' 'DominikReichl.KeePass' }) }
        @{ Name = 'Adobe Acrobat Reader'; Tiers = @({ Install-WingetPackage 'Adobe Acrobat Reader' 'Adobe.Acrobat.Reader.64-bit' }) }
        @{ Name = 'pipx';               Tiers = @({ Install-Pipx }) }
        @{ Name = 'Rust';               Tiers = @({ Install-Rust }) }
        @{ Name = 'MSYS2';              Tiers = @({ Install-Msys2 }) }
        @{ Name = 'MSYS2 Toolchain';    Tiers = @({ Install-MsysToolchain }) }
        @{ Name = 'Nim';                Tiers = @({ Install-NimFromSource }) }
        # @{ Name = 'JDK 17.0.2';       Tiers = @({ Install-Jdk17 }) }
        @{ Name = 'Visual Studio 2022 Community'; Tiers = @({
            if (Install-WingetPackage 'Visual Studio 2022 Community' 'Microsoft.VisualStudio.2022.Community') {
                Install-VS2022Components
                Enable-NetFx35Feature
                $true
            } else {
                $false
            }
          }) }

        # --- Web proxy / testing ---
        @{ Name = 'Burp Suite Community'; Tiers = @({ Install-WingetPackage 'Burp Suite Community' 'PortSwigger.BurpSuite.Community' }) }
        @{ Name = 'Fiddler Classic';       Tiers = @({ Install-WingetPackage 'Fiddler Classic' 'Telerik.Fiddler.Classic' }) }

        # --- Password / hash cracking ---
        @{ Name = 'Hashcat';   Tiers = @({ Install-GitHubReleaseAsset -Name 'Hashcat' -Repo 'hashcat/hashcat' -AssetPattern '*.7z' }) }

        # --- CyberChef (static app, no build needed) ---
        @{ Name = 'CyberChef'; Tiers = @({ Install-GitHubReleaseAsset -Name 'CyberChef' -Repo 'gchq/CyberChef' -AssetPattern '*.zip' -ExtractZip }) }

        # --- AD / post-exploitation tradecraft ---
        @{ Name = 'SharpHound'; Tiers = @({ Install-GitHubReleaseAsset -Name 'SharpHound' -Repo 'SpecterOps/SharpHound' -AssetPattern '*.zip' -ExtractZip }) }
        @{ Name = 'Rubeus';     Tiers = @({ Install-FromSourceDotNet -Name 'Rubeus' -Repo 'GhostPack/Rubeus' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Certify';    Tiers = @({ Install-FromSourceDotNet -Name 'Certify' -Repo 'GhostPack/Certify' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'PowerSploit'; Tiers = @({ Install-GitCloneOnly -Name 'PowerSploit' -Repo 'PowerShellMafia/PowerSploit' }) }
        @{ Name = 'Responder'; Tiers = @({ Install-GitCloneOnly -Name 'Responder' -Repo 'lgandx/Responder' }) }

        # --- Python-based tooling (needs Python installed above first) ---
        @{ Name = 'Impacket';  Tiers = @({ Install-PipPackage -Name 'Impacket' -PipName 'impacket' }) }
        @{ Name = 'NetExec';   Tiers = @({ Install-PipPackage -Name 'NetExec' -PipName 'netexec' }) }

        # --- DevTools (pinned releases, ported from lab-workstation.yml) ---
        @{ Name = 'FaceDancer';      Tiers = @({ Install-GitHubReleaseAsset -Name 'FaceDancer' -Repo 'Tylous/FaceDancer' -AssetPattern 'FaceDancer_Windows_amd64.exe' -Tag 'v2.0' }) }
        @{ Name = 'RedTeamGrimoire'; Tiers = @({ Install-GitCloneOnly -Name 'RedTeamGrimoire' -Repo 'vari-sh/RedTeamGrimoire' }) }
        @{ Name = 'swarmer';         Tiers = @({ Install-GitHubReleaseAsset -Name 'swarmer' -Repo 'praetorian-inc/swarmer' -AssetPattern 'swarmer.exe' -Tag 'v0.1.8' }) }
        @{ Name = 'HiveSwarming';    Tiers = @({ Install-GitHubReleaseAsset -Name 'HiveSwarming' -Repo 'stormshield/HiveSwarming' -AssetPattern 'HiveSwarming.exe' -Tag 'v1.6' }) }

        # --- [BOF]-tagged tools from verify-packages.md -> C:\Tools\BOF ---
        @{ Name = 'bof-collection';                 Tiers = @({ Install-GitCloneOnly -Name 'bof-collection' -Repo 'rvrsh3ll/BOF_Collection' -DestRoot $script:BofRoot }) }
        @{ Name = 'BOF-patchit';                     Tiers = @({ Install-GitCloneOnly -Name 'BOF-patchit' -Repo 'ScriptIdiot/BOF-patchit' -DestRoot $script:BofRoot }) }
        @{ Name = 'BofRoast';                        Tiers = @({ Install-GitCloneOnly -Name 'BofRoast' -Repo 'cube0x0/BofRoast' -DestRoot $script:BofRoot }) }
        @{ Name = 'C2-Tool-Collection';              Tiers = @({ Install-GitCloneOnly -Name 'C2-Tool-Collection' -Repo 'outflanknl/C2-Tool-Collection' -DestRoot $script:BofRoot }) }
        @{ Name = 'CredManBOF';                      Tiers = @({ Install-GitCloneOnly -Name 'CredManBOF' -Repo 'jsecu/CredManBOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'CS-Situational-Awareness-BOF';    Tiers = @({ Install-GitCloneOnly -Name 'CS-Situational-Awareness-BOF' -Repo 'trustedsec/CS-Situational-Awareness-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'DelegationBOF';                   Tiers = @({ Install-GitCloneOnly -Name 'DelegationBOF' -Repo 'Crypt0s/DelegationBOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'HandleKatz_BOF';                  Tiers = @({ Install-GitCloneOnly -Name 'HandleKatz_BOF' -Repo 'EspressoCake/HandleKatz_BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'HOLLOW';                          Tiers = @({ Install-GitCloneOnly -Name 'HOLLOW' -Repo 'boku7/HOLLOW' -DestRoot $script:BofRoot }) }
        @{ Name = 'nanorobeus';                      Tiers = @({ Install-GitCloneOnly -Name 'nanorobeus' -Repo 'wavvs/nanorobeus' -DestRoot $script:BofRoot }) }
        @{ Name = 'No-Consolation';                  Tiers = @({ Install-GitCloneOnly -Name 'No-Consolation' -Repo 'fortra/No-Consolation' -DestRoot $script:BofRoot }) }
        @{ Name = 'OperatorsKit';                    Tiers = @({ Install-GitCloneOnly -Name 'OperatorsKit' -Repo 'REDMED-X/OperatorsKit' -DestRoot $script:BofRoot }) }
        @{ Name = 'PatchlessInlineExecute-Assembly'; Tiers = @({ Install-GitCloneOnly -Name 'PatchlessInlineExecute-Assembly' -Repo 'VoldeSec/PatchlessInlineExecute-Assembly' -DestRoot $script:BofRoot }) }
        @{ Name = 'reg_export-BOF';                  Tiers = @({ Install-GitCloneOnly -Name 'reg_export-BOF' -Repo 'Valkyrie-Security/reg_export-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'PoolPartyBof';                    Tiers = @({ Install-GitCloneOnly -Name 'PoolPartyBof' -Repo '0xEr3bus/PoolPartyBof' -DestRoot $script:BofRoot }) }
        @{ Name = 'SCShell';                         Tiers = @({ Install-GitCloneOnly -Name 'SCShell' -Repo 'Mr-Un1k0d3r/SCShell' -DestRoot $script:BofRoot }) }
        @{ Name = 'secinject';                       Tiers = @({ Install-GitCloneOnly -Name 'secinject' -Repo 'apokryptein/secinject' -DestRoot $script:BofRoot }) }
        @{ Name = 'tgtdelegation';                   Tiers = @({ Install-GitCloneOnly -Name 'tgtdelegation' -Repo 'connormcgarr/tgtdelegation' -DestRoot $script:BofRoot }) }
        @{ Name = 'ThreadlessInject-BOF';            Tiers = @({ Install-GitCloneOnly -Name 'ThreadlessInject-BOF' -Repo 'iilegacyyii/ThreadlessInject-BOF' -DestRoot $script:BofRoot }) }
        @{ Name = 'Unhook-BOF';                      Tiers = @({ Install-GitCloneOnly -Name 'Unhook-BOF' -Repo 'rsmudge/unhook-bof' -DestRoot $script:BofRoot }) }

        # --- [Sharp]/[SharpTool]-tagged tools -> C:\Tools\SharpTools (build via MSBuild) ---
        @{ Name = 'ADSearch';           Tiers = @({ Install-FromSourceDotNet -Name 'ADSearch' -Repo 'tomcarver16/ADSearch' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Net-GPPPassword';    Tiers = @({ Install-FromSourceDotNet -Name 'Net-GPPPassword' -Repo 'outflanknl/Net-GPPPassword' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'nopowershell';       Tiers = @({ Install-FromSourceDotNet -Name 'nopowershell' -Repo 'bitsadmin/nopowershell' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'RestrictedAdmin';    Tiers = @({ Install-FromSourceDotNet -Name 'RestrictedAdmin' -Repo 'GhostPack/RestrictedAdmin' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Sharp-SMBExec';      Tiers = @({ Install-FromSourceDotNet -Name 'Sharp-SMBExec' -Repo 'checkymander/Sharp-SMBExec' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpClipHistory';   Tiers = @({ Install-FromSourceDotNet -Name 'SharpClipHistory' -Repo 'ReversecLabs/SharpClipHistory' -DestRoot $script:SharpToolsRoot }) }
        # SharpCollection is a meta-repo of many prebuilt tools + its own build
        # script, not a single .sln - clone only, don't try to MSBuild it.
        @{ Name = 'SharpCollection';    Tiers = @({ Install-GitCloneOnly -Name 'SharpCollection' -Repo 'Flangvik/SharpCollection' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpDPAPI';         Tiers = @({ Install-FromSourceDotNet -Name 'SharpDPAPI' -Repo 'GhostPack/SharpDPAPI' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpDump';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpDump' -Repo 'GhostPack/SharpDump' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharPersist';        Tiers = @({ Install-FromSourceDotNet -Name 'SharPersist' -Repo 'mandiant/SharPersist' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpExec';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpExec' -Repo 'checkymander/Sharp-WMIExec' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpGPOAbuse';      Tiers = @({ Install-FromSourceDotNet -Name 'SharpGPOAbuse' -Repo 'ReversecLabs/SharpGPOAbuse' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SharpLAPS';          Tiers = @({ Install-FromSourceDotNet -Name 'SharpLAPS' -Repo 'swisskyrepo/SharpLAPS' -DestRoot $script:SharpToolsRoot }) }
        # Release config is pinned to x64 in this repo, not AnyCPU.
        @{ Name = 'SharpMapExec';       Tiers = @({ Install-FromSourceDotNet -Name 'SharpMapExec' -Repo 'cube0x0/SharpMapExec' -DestRoot $script:SharpToolsRoot -Platform 'x64' }) }
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
        # C# tools reclassified out of the general/untagged batch below
        @{ Name = 'DotNetToJScript';    Tiers = @({ Install-FromSourceDotNet -Name 'DotNetToJScript' -Repo 'tyranid/DotNetToJScript' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'ForgeCert';          Tiers = @({ Install-FromSourceDotNet -Name 'ForgeCert' -Repo 'GhostPack/ForgeCert' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'GadgetToJScript';    Tiers = @({ Install-FromSourceDotNet -Name 'GadgetToJScript' -Repo 'med0x2e/GadgetToJScript' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'Group3r';            Tiers = @({ Install-FromSourceDotNet -Name 'Group3r' -Repo 'Group3r/Group3r' -DestRoot $script:SharpToolsRoot }) }
        # Moderate confidence these two are C#, not just PowerShell - worth a
        # quick check after cloning if the build step skips.
        # KeeThief ships 3 unrelated .sln files (vendored KeePass source, a native
        # DecryptionShellcode project) alongside the real one - pin the path explicitly so a
        # recursive *.sln search doesn't grab the wrong one.
        @{ Name = 'KeeThief';           Tiers = @({ Install-FromSourceDotNet -Name 'KeeThief' -Repo 'GhostPack/KeeThief' -DestRoot $script:SharpToolsRoot -SlnPath 'KeeTheft\KeeTheft.sln' }) }
        @{ Name = 'LdapSignCheck';      Tiers = @({ Install-FromSourceDotNet -Name 'LdapSignCheck' -Repo 'cube0x0/LdapSignCheck' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'KrbRelayUp';         Tiers = @({ Install-FromSourceDotNet -Name 'KrbRelayUp' -Repo 'Dec0ne/KrbRelayUp' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SauronEye';          Tiers = @({ Install-FromSourceDotNet -Name 'SauronEye' -Repo 'vivami/SauronEye' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'SpoolSample';        Tiers = @({ Install-FromSourceDotNet -Name 'SpoolSample' -Repo 'leechristensen/SpoolSample' -DestRoot $script:SharpToolsRoot }) }
        @{ Name = 'ThreatCheck';        Tiers = @({ Install-FromSourceDotNet -Name 'ThreatCheck' -Repo 'rasta-mouse/ThreatCheck' -DestRoot $script:SharpToolsRoot }) }

        # --- [Cloud]-tagged tools -> C:\Tools\Cloud ---
        @{ Name = 'MicroBurst';     Tiers = @({ Install-GitCloneOnly -Name 'MicroBurst' -Repo 'NetSPI/MicroBurst' -DestRoot $script:CloudRoot }) }
        @{ Name = 'TeamFiltration'; Tiers = @({ Install-GitCloneOnly -Name 'TeamFiltration' -Repo 'Flangvik/TeamFiltration' -DestRoot $script:CloudRoot }) }
        @{ Name = 'ADConnectDump';  Tiers = @({ Install-GitCloneOnly -Name 'ADConnectDump' -Repo 'dirkjanm/adconnectdump' -DestRoot $script:CloudRoot }) }

        # --- [Potato]-tagged privesc tools -> C:\Tools\PotatoFarm ---
        @{ Name = 'Hot-Potato';     Tiers = @({ Install-GitCloneOnly -Name 'Hot-Potato' -Repo 'davidmbillie/Hot-Potato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'RottenPotato';   Tiers = @({ Install-GitCloneOnly -Name 'RottenPotato' -Repo 'foxglovesec/RottenPotato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'juicy-potato';   Tiers = @({ Install-GitCloneOnly -Name 'juicy-potato' -Repo 'ohpe/juicy-potato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'RoguePotato';    Tiers = @({ Install-GitCloneOnly -Name 'RoguePotato' -Repo 'antonioCoco/RoguePotato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'SweetPotato';    Tiers = @({ Install-GitCloneOnly -Name 'SweetPotato' -Repo 'CCob/SweetPotato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'GenericPotato';  Tiers = @({ Install-GitCloneOnly -Name 'GenericPotato' -Repo 'micahvandeusen/GenericPotato' -DestRoot $script:PotatoRoot }) }
        @{ Name = 'GodPotato';      Tiers = @({ Install-GitCloneOnly -Name 'GodPotato' -Repo 'BeichenDream/GodPotato' -DestRoot $script:PotatoRoot }) }

        # --- Untagged repos from verify-packages.md -> default C:\Tools\src ---
        @{ Name = 'AdaptixC2';                Tiers = @({ Install-GitCloneOnly -Name 'AdaptixC2' -Repo 'Adaptix-Framework/AdaptixC2' }) }
        @{ Name = 'BadAssMacros';             Tiers = @({ Install-GitCloneOnly -Name 'BadAssMacros' -Repo 'Inf0secRabbit/BadAssMacros' }) }
        @{ Name = 'BloodHound-Custom-Queries'; Tiers = @({ Install-GitCloneOnly -Name 'BloodHound-Custom-Queries' -Repo 'CompassSecurity/BloodHoundQueries' }) }
        @{ Name = 'Crystal-Loaders';          Tiers = @({ Install-GitCloneOnly -Name 'Crystal-Loaders' -Repo 'rasta-mouse/Crystal-Loaders' }) }
        @{ Name = 'CS-Loader';                Tiers = @({ Install-GitCloneOnly -Name 'CS-Loader' -Repo 'Gality369/CS-Loader' }) }
        @{ Name = 'Dumpert';                  Tiers = @({ Install-GitCloneOnly -Name 'Dumpert' -Repo 'outflanknl/Dumpert' }) }
        @{ Name = 'EvilClippy';               Tiers = @({ Install-GitCloneOnly -Name 'EvilClippy' -Repo 'outflanknl/EvilClippy' }) }
        @{ Name = 'Freeze';                   Tiers = @({ Install-FromSourceGo -Name 'Freeze' -Repo 'Tylous/Freeze' }) }
        @{ Name = 'Get-LAPSPasswords';        Tiers = @({ Install-GitCloneOnly -Name 'Get-LAPSPasswords' -Repo 'kfosaaen/Get-LAPSPasswords' }) }
        @{ Name = 'go-cookie-monster';        Tiers = @({ Install-FromSourceGo -Name 'go-cookie-monster' -Repo 'c2biz/go-cookie-monster' }) }
        @{ Name = 'GoBuster';                 Tiers = @({ Install-FromSourceGo -Name 'GoBuster' -Repo 'OJ/gobuster' }) }
        @{ Name = 'GoWitness';                Tiers = @({ Install-FromSourceGo -Name 'GoWitness' -Repo 'sensepost/gowitness' }) }
        @{ Name = 'IIS-Raid';                 Tiers = @({ Install-GitCloneOnly -Name 'IIS-Raid' -Repo '0x09AL/IIS-Raid' }) }
        @{ Name = 'injectAmsiBypass';         Tiers = @({ Install-GitCloneOnly -Name 'injectAmsiBypass' -Repo 'boku7/injectAmsiBypass' }) }
        @{ Name = 'injectEtwBypass';          Tiers = @({ Install-GitCloneOnly -Name 'injectEtwBypass' -Repo 'boku7/injectEtwBypass' }) }
        @{ Name = 'Invoke-DOSfuscation';      Tiers = @({ Install-GitCloneOnly -Name 'Invoke-DOSfuscation' -Repo 'danielbohannon/Invoke-DOSfuscation' }) }
        @{ Name = 'Invoke-Obfuscation';       Tiers = @({ Install-GitCloneOnly -Name 'Invoke-Obfuscation' -Repo 'danielbohannon/Invoke-Obfuscation' }) }
        @{ Name = 'Kerbeus-BOF';              Tiers = @({ Install-GitCloneOnly -Name 'Kerbeus-BOF' -Repo 'RalfHacker/Kerbeus-BOF' }) }
        @{ Name = 'Kerbrute';                 Tiers = @({ Install-FromSourceGo -Name 'Kerbrute' -Repo 'ropnop/kerbrute' }) }
        @{ Name = 'LDAPNomNom';               Tiers = @({ Install-FromSourceGo -Name 'LDAPNomNom' -Repo 'lkarlslund/ldapnomnom' }) }
        @{ Name = 'MailSniper';               Tiers = @({ Install-GitCloneOnly -Name 'MailSniper' -Repo 'dafthack/MailSniper' }) }
        @{ Name = 'MFASweep';                 Tiers = @({ Install-GitCloneOnly -Name 'MFASweep' -Repo 'dafthack/MFASweep' }) }
        @{ Name = 'PetitPotam';               Tiers = @({ Install-GitCloneOnly -Name 'PetitPotam' -Repo 'topotam/PetitPotam' }) }
        @{ Name = 'PortBender';               Tiers = @({ Install-GitCloneOnly -Name 'PortBender' -Repo 'praetorian-inc/PortBender' }) }
        @{ Name = 'PowerMad';                 Tiers = @({ Install-GitCloneOnly -Name 'PowerMad' -Repo 'Kevin-Robertson/Powermad' }) }
        @{ Name = 'PowerUpSQL';               Tiers = @({ Install-GitCloneOnly -Name 'PowerUpSQL' -Repo 'NetSPI/PowerUpSQL' }) }
        @{ Name = 'PSPKIAudit';               Tiers = @({ Install-GitCloneOnly -Name 'PSPKIAudit' -Repo 'GhostPack/PSPKIAudit' }) }
        @{ Name = 'RustHound-CE';             Tiers = @({ Install-FromSourceRust -Name 'RustHound-CE' -Repo 'g0h4n/RustHound-CE' }) }
        @{ Name = 'rustyneedle';              Tiers = @({ Install-FromSourceRust -Name 'rustyneedle' -Repo 'mttaggart/rustyneedle' }) }
        @{ Name = 'ServiceMove-BOF';          Tiers = @({ Install-GitCloneOnly -Name 'ServiceMove-BOF' -Repo 'netero1010/ServiceMove-BOF' }) }
        @{ Name = 'Stracciatella';            Tiers = @({ Install-GitCloneOnly -Name 'Stracciatella' -Repo 'mgeeky/Stracciatella' }) }
        @{ Name = 'StreamDivert';             Tiers = @({ Install-GitCloneOnly -Name 'StreamDivert' -Repo 'jellever/StreamDivert' }) }
        @{ Name = 'SuperMega';                Tiers = @({ Install-GitCloneOnly -Name 'SuperMega' -Repo 'dobin/SuperMega' }) }
        @{ Name = 'upx';                      Tiers = @({ Install-GitCloneOnly -Name 'upx' -Repo 'upx/upx' }) }
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
    $script:BinRoot        = Join-Path $script:ToolsRoot 'bin'
    $script:DlRoot         = Join-Path $script:ToolsRoot 'downloads'
    $script:BofRoot        = Join-Path $script:ToolsRoot 'BOF'
    $script:SharpToolsRoot = Join-Path $script:ToolsRoot 'SharpTools'
    $script:CloudRoot      = Join-Path $script:ToolsRoot 'Cloud'
    $script:PotatoRoot     = Join-Path $script:ToolsRoot 'PotatoFarm'
    $script:LogRoot        = Join-Path $script:ToolsRoot 'logs'
    $script:TranscriptFile = Join-Path $script:LogRoot 'RedWindows-transcript.log'
    $script:ResultsCsv     = Join-Path $script:LogRoot 'RedWindows-results.csv'
    $script:Results        = New-Object System.Collections.Generic.List[object]
    $script:CurrentStage   = 0

    # Generic clone/build targets (Install-GitCloneOnly/Install-FromSourceDotNet
    # without an explicit -DestRoot) land directly in $script:ToolsRoot - no
    # separate "src" subfolder.
    $allDirs = @(
        $script:ToolsRoot, $script:BinRoot, $script:DlRoot, $script:LogRoot,
        $script:BofRoot, $script:SharpToolsRoot, $script:CloudRoot, $script:PotatoRoot
    )
    foreach ($dir in $allDirs) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Started here (before Write-Status is first called for this run) so the transcript
    # captures everything - it's -Append'd across the reboots between stages, so this ends up
    # one continuous log of the whole 3-stage run rather than 3 separate fragments.
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
    Disable-WindowsUpdates
    Install-SshServer
    Set-HighPerformancePowerPlan
    New-RangeAdminUser

    # Installed last - its own PATH alias needs a fresh session, which is
    # exactly what the restart below provides.
    Install-Winget

    Complete-Stage -NextStage 2
}

function Invoke-Stage2 {
    $script:CurrentStage = 2
    Write-Status "`n=== Stage 2: install Git ===" 'Magenta'

    # Git also needs a fresh session for its PATH entry to resolve, so it
    # gets its own stage rather than running inside Install-AllPackages.
    Install-WingetPackage 'Git' 'Git.Git' | Out-Null

    Complete-Stage -NextStage 3
}

function Invoke-Stage3 {
    $script:CurrentStage = 3
    Write-Status "`n=== Stage 3: core dev environment (Python, Go, Rust, MSYS2, Nim, VS2022) ===" 'Magenta'

    # Same entries also exist in Get-PackageTable (Stage 4) - each of those functions already
    # detects "already installed/built" and returns early, so running them here first (and
    # again later) is harmless, exactly like Git's duplication between Stage 2 and the table.
    Install-WingetPackage 'Python 3.13' 'Python.Python.3.13' | Out-Null
    Install-WingetPackage 'Go' 'GoLang.Go' | Out-Null

    # VS2022's C++ workload/Windows SDK go in before Rust so rustup-init finds an existing
    # MSVC toolchain instead of warning "installing msvc toolchain without its prerequisites".
    if (Install-WingetPackage 'Visual Studio 2022 Community' 'Microsoft.VisualStudio.2022.Community') {
        Install-VS2022Components
        Enable-NetFx35Feature
    }

    Install-Rust | Out-Null
    Install-Msys2 | Out-Null
    Install-MsysToolchain | Out-Null
    Install-NimFromSource | Out-Null

    Complete-Stage -NextStage 4
}

function Invoke-Stage4 {
    $script:CurrentStage = 4
    Write-Status "`n=== Stage 4: remaining packages ===" 'Magenta'

    Install-AllPackages
    Unregister-ContinuationTask
    Show-Summary
    try { Stop-Transcript | Out-Null } catch {}
}

function Install-AllPackages {
    $packages = Get-PackageTable

    Write-Status "`n=== RedWindows: installing $($packages.Count) packages ===" 'Magenta'

    foreach ($pkg in $packages) {
        $name = $pkg.Name
        $done = $false

        foreach ($tier in $pkg.Tiers) {
            try {
                if (& $tier) { $done = $true; break }
            } catch {
                Write-Status "[!] [$name] tier threw: $($_.Exception.Message)" 'Yellow'
            }
        }

        if (-not $done) {
            Write-Status "[x] [$name] all install tiers failed - skipping" 'Red'
            Record-Result -Name $name -Status Skipped -Detail 'no tier succeeded'
        }
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
        default {
            Write-Status "[!] Unknown stage '$stage' - resetting to stage 1" 'Yellow'
            Set-RedWindowsStage -Stage 1
            Invoke-Stage1
        }
    }
}

Main
