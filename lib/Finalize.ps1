function New-SshKeyPair {
    $sshDir  = Join-Path $env:USERPROFILE '.ssh'
    $keyPath = Join-Path $sshDir 'id_ed25519'

    Write-Status "[-] [SSH keypair] generating ed25519 key" 'Cyan'
    try {
        if (Test-Path $keyPath) {
            Write-Status "[+] [SSH keypair] already exists at $keyPath" 'DarkGray'
            Add-Result -Name 'SSH keypair' -Status Installed -Detail 'already present'
            return $true
        }

        if (-not (Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        }

        # Use '""' for empty -N; PowerShell drops truly-empty native args.
        Invoke-NativeQuiet { ssh-keygen -t ed25519 -f $keyPath -N '""' -q *>$null }
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen exited with code $LASTEXITCODE"
        }

        Write-Status "[+] [SSH keypair] generated $keyPath" 'Green'
        Add-Result -Name 'SSH keypair' -Status Installed -Detail $keyPath
        return $true
    } catch {
        Write-Status "[!] [SSH keypair] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'SSH keypair' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Set-SshCopyIdFunction {
    Write-Status "[-] [ssh-copy-id] adding function to PowerShell profile" 'Cyan'
    try {
        if ((Test-Path $PROFILE) -and (Select-String -Path $PROFILE -Pattern '^function ssh-copy-id' -Quiet)) {
            Write-Status "[+] [ssh-copy-id] already present in $PROFILE" 'DarkGray'
            Add-Result -Name 'ssh-copy-id function' -Status Installed -Detail 'already present'
            return $true
        }

        $profileDir = Split-Path -Path $PROFILE -Parent
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }

        $funcDef = @'

function ssh-copy-id {
    param(
        [string]$Server,
        [string]$IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519.pub",
        [Alias('h')]
        [switch]$Help
    )

    $usage = "Usage: ssh-copy-id <user@host> [-IdentityFile <path>] (default: $IdentityFile)"

    if ($Help -or -not $Server) {
        Write-Host $usage
        return
    }

    if (-not (Test-Path $IdentityFile)) {
        Write-Host "ssh-copy-id: identity file not found: $IdentityFile" -ForegroundColor Yellow
        Write-Host $usage
        return
    }

    try {
        Get-Content $IdentityFile | ssh $Server "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        if ($LASTEXITCODE -ne 0) {
            throw "ssh exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Host "ssh-copy-id: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host $usage
    }
}
'@
        Add-Content -Path $PROFILE -Value $funcDef

        Write-Status "[+] [ssh-copy-id] added to $PROFILE" 'Green'
        Add-Result -Name 'ssh-copy-id function' -Status Installed -Detail $PROFILE
        return $true
    } catch {
        Write-Status "[!] [ssh-copy-id] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'ssh-copy-id function' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Set-TerminalHostsProfileFunction {
    Write-Status "[-] [Set-TerminalHosts] adding function to PowerShell profile" 'Cyan'
    try {
        $scriptPath = Join-Path $script:ToolsRoot 'Set-TerminalHosts.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "$scriptPath not found - run Set-WindowsTerminalConfig first"
        }

        $funcDef = @"

# BEGIN RedWindows Set-TerminalHosts
function Set-TerminalHosts {
    [CmdletBinding()]
    param(
        [string]`$TeamServer,
        [string]`$RD1,
        [string]`$RD2,
        [string]`$RD3,
        [string]`$Payload,
        [string]`$FileServer,
        [string]`$ExfilServer,
        [switch]`$Interactive,
        [Alias('h')][switch]`$Help
    )
    `$scriptPath = '$($scriptPath.Replace("'", "''"))'
    if (-not (Test-Path -LiteralPath `$scriptPath)) {
        Write-Host "Set-TerminalHosts: script not found: `$scriptPath" -ForegroundColor Yellow
        return
    }
    & `$scriptPath @PSBoundParameters
}
# END RedWindows Set-TerminalHosts
"@

        $profilePaths = @(
            (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
            (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
            (Join-Path "C:\Users\$($script:AttackerUsername)" 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
            (Join-Path "C:\Users\$($script:AttackerUsername)" 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
        ) | Select-Object -Unique

        $updated = 0
        foreach ($profilePath in $profilePaths) {
            $profileDir = Split-Path -Path $profilePath -Parent
            if (-not (Test-Path -LiteralPath $profileDir)) {
                New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            }

            if (Test-Path -LiteralPath $profilePath) {
                $existing = Get-Content -LiteralPath $profilePath -Raw
                if ($existing -match '(?s)# BEGIN RedWindows Set-TerminalHosts.*?# END RedWindows Set-TerminalHosts') {
                    $existing = [regex]::Replace($existing, '(?s)# BEGIN RedWindows Set-TerminalHosts.*?# END RedWindows Set-TerminalHosts\r?\n?', '')
                    Set-Content -LiteralPath $profilePath -Value $existing.TrimEnd() -Encoding UTF8
                } elseif ($existing -match '(?m)^function Set-TerminalHosts\b') {
                    # Older wrapper without markers - leave it and append the new marked block.
                }
            }

            Add-Content -LiteralPath $profilePath -Value $funcDef -Encoding UTF8
            $updated++
        }

        if ($updated -eq 0) {
            Write-Status "[+] [Set-TerminalHosts] already present in profile(s)" 'DarkGray'
            Add-Result -Name 'Set-TerminalHosts function' -Status Installed -Detail 'already present'
        } else {
            Write-Status "[+] [Set-TerminalHosts] added to $updated profile(s) - run Set-TerminalHosts in a new shell" 'Green'
            Add-Result -Name 'Set-TerminalHosts function' -Status Installed -Detail "$updated profile(s)"
        }
        return $true
    } catch {
        Write-Status "[!] [Set-TerminalHosts] profile update failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Set-TerminalHosts function' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Set-Rebuild {
    $sourcePath  = Join-Path $script:ToolsRoot 'RedWindows.ps1'
    $rebuildPath = Join-Path $script:ToolsRoot 'Rebuild.ps1'

    Write-Status "[-] [Rebuild script] generating $rebuildPath" 'Cyan'
    try {
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Write-Status "[!] [Rebuild script] $sourcePath not found - skipping" 'Yellow'
            Add-Result -Name 'Rebuild script' -Status Skipped -Detail "$sourcePath not found"
            return $false
        }

        $content = Get-Content -LiteralPath $sourcePath -Raw

        # Interactive rebuilds should survive chatty-tool stderr instead of aborting.
        $content = $content.Replace("`$ErrorActionPreference = 'Stop'", "`$ErrorActionPreference = 'Continue'")

        # Swap staged Main for env init only; lib is already dotsourced at script scope.
        $replacement = '${1}Initialize-Environment'
        $content = $content -replace '(?m)^(\s*)Main\s*$', $replacement

        Set-Content -LiteralPath $rebuildPath -Value $content -NoNewline -Encoding UTF8

        Write-Status "[+] [Rebuild script] generated $rebuildPath" 'Green'
        Add-Result -Name 'Rebuild script' -Status Installed -Detail $rebuildPath
        return $true
    } catch {
        Write-Status "[!] [Rebuild script] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Rebuild script' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Clear-EventLogs {
    Write-Status "[-] [Event logs] clearing" 'Cyan'
    try {
        $logs = Get-WinEvent -ListLog * -Force -ErrorAction SilentlyContinue
        $cleared = 0
        $failed = 0
        foreach ($log in $logs) {
            # wevtutil stderr can terminate under EAP Stop; use Invoke-NativeQuiet.
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

    # VMware Tools expects C:\ (C: alone fails with "Unable to find partition C:").
    Write-Status "[-] [Disk shrink] running VMwareToolboxCmd disk shrink C:\" 'Cyan'
    try {
        if (-not (Test-Path $vmwareToolboxCmd)) {
            Write-Status "[!] [Disk shrink] VMware Tools not found - skipping" 'Yellow'
            Add-Result -Name 'Disk shrink' -Status Skipped -Detail 'VMwareToolboxCmd.exe not found'
            return $false
        }

        # Capture stderr via Invoke-NativeQuiet so EAP Stop doesn't abort before LASTEXITCODE.
        $raw = Invoke-NativeQuiet { & $vmwareToolboxCmd disk shrink 'C:\' 2>&1 }
        $output = ($raw | ForEach-Object { "$_" }) -join ' '
        $output = ($output -replace '\s+', ' ').Trim()
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            if ($output) { Write-Status $output 'DarkGray' }
            Write-Status "[+] [Disk shrink] completed" 'Green'
            Add-Result -Name 'Disk shrink' -Status Installed -Detail 'VMwareToolboxCmd disk shrink C:\'
            return $true
        }

        # Exit 72 / "disabled" is normal for linked clones, snapshots, thick/preallocated disks.
        if ($exitCode -eq 72 -or $output -match 'Shrink disk is disabled|Shrinking is disabled') {
            Write-Status "[!] [Disk shrink] disabled on this VM (linked clone, snapshot, or preallocated disk) - skipping" 'Yellow'
            Add-Result -Name 'Disk shrink' -Status Skipped -Detail 'disabled by VMware (clone/snapshot/preallocated)'
            return $false
        }

        Write-Status "[!] [Disk shrink] exited with code $exitCode - skipping" 'Yellow'
        if ($output) { Write-Status $output 'DarkGray' }
        Add-Result -Name 'Disk shrink' -Status Skipped -Detail "exit $exitCode"
        return $false
    } catch {
        Write-Status "[!] [Disk shrink] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Disk shrink' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Set-WindowsTerminalConfig {
    Write-Status "[-] [Windows Terminal] copying icons and writing settings.json" 'Cyan'
    try {
        $attackerHome = Join-Path 'C:\Users' $script:AttackerUsername
        $picturesDir  = Join-Path $attackerHome 'Pictures'
        $sshKeyPath   = Join-Path $attackerHome '.ssh\id_ed25519'
        $appDataLocal = Join-Path $attackerHome 'AppData\Local'

        $iconsSrc = @(
            (Join-Path $script:RedWindowsRoot 'lib\icons'),
            (Join-Path $script:ToolsRoot 'lib\icons')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        $templatePath = @(
            (Join-Path $script:RedWindowsRoot 'lib\windows-terminal-settings.json'),
            (Join-Path $script:ToolsRoot 'lib\windows-terminal-settings.json')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $iconsSrc) {
            throw 'lib\icons not found under RedWindowsRoot or ToolsRoot'
        }
        if (-not $templatePath) {
            throw 'lib\windows-terminal-settings.json not found'
        }

        if (-not (Test-Path -LiteralPath $picturesDir)) {
            New-Item -ItemType Directory -Path $picturesDir -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $iconsSrc '*') -Destination $picturesDir -Force
        Write-Status "[+] [Windows Terminal] icons -> $picturesDir" 'Green'

        $pkgRoot = Get-ChildItem -Path (Join-Path $appDataLocal 'Packages') -Directory -Filter 'Microsoft.WindowsTerminal_*' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            Select-Object -First 1

        if (-not $pkgRoot) {
            # Terminal may not have been launched yet; create the usual package folder name.
            $pkgRootPath = Join-Path $appDataLocal 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe'
            New-Item -ItemType Directory -Path (Join-Path $pkgRootPath 'LocalState') -Force | Out-Null
            $pkgRoot = Get-Item -LiteralPath $pkgRootPath
            Write-Status "[!] [Windows Terminal] package folder not found - created $pkgRootPath" 'Yellow'
        }

        $localState = Join-Path $pkgRoot.FullName 'LocalState'
        if (-not (Test-Path -LiteralPath $localState)) {
            New-Item -ItemType Directory -Path $localState -Force | Out-Null
        }

        # JSON needs escaped backslashes in string values.
        $sshKeyJson   = $sshKeyPath.Replace('\', '\\')
        $picturesJson = $picturesDir.Replace('\', '\\')
        $json = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
        $json = $json.Replace('__SSH_KEY__', $sshKeyJson).Replace('__PICTURES__', $picturesJson)

        $settingsPath = Join-Path $localState 'settings.json'
        Set-Content -LiteralPath $settingsPath -Value $json -Encoding UTF8 -Force
        Write-Status "[+] [Windows Terminal] wrote $settingsPath" 'Green'

        $hostsSrc = @(
            (Join-Path $script:RedWindowsRoot 'Set-TerminalHosts.ps1'),
            (Join-Path $script:ToolsRoot 'Set-TerminalHosts.ps1')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($hostsSrc) {
            $hostsDst = Join-Path $script:ToolsRoot 'Set-TerminalHosts.ps1'
            Copy-Item -LiteralPath $hostsSrc -Destination $hostsDst -Force
            Write-Status "[+] [Windows Terminal] helper -> $hostsDst" 'Green'
        }

        Add-Result -Name 'Windows Terminal' -Status Installed -Detail $settingsPath
        return $true
    } catch {
        Write-Status "[!] [Windows Terminal] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'Windows Terminal' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Remove-LocalSupportUser {
    # Remove vuln-config support user; only needed between Stage 3 and 4.
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

function Show-Summary {
    Write-Status "`n=== Summary (all stages) ===" 'Magenta'

    # Full run results live in ResultsCsv across stage reboots.
    $allResults = if (Test-Path $script:ResultsCsv) { Import-Csv -Path $script:ResultsCsv } else { $script:Results }
    $allResults | Sort-Object Stage, Status, Name | Format-Table -Property Stage, Name, Status, Detail -AutoSize

    $installed = ($allResults | Where-Object { $_.Status -eq 'Installed' }).Count
    $skipped   = ($allResults | Where-Object { $_.Status -eq 'Skipped' }).Count
    Write-Status "`n$installed installed, $skipped skipped (see above for reasons)." 'White'
    Write-Status "Full transcript: $script:TranscriptFile" 'White'
    Write-Status "Full results log: $script:ResultsCsv" 'White'
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
    }
}
