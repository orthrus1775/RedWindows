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

        # '""' (not '') - PowerShell drops truly-empty native-exe arguments, so this is
        # the standard workaround to get ssh-keygen an empty -N passphrase non-interactively.
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

        # Swap the staged Main run for env init only. Lib is already dotsourced at
        # script scope when this file loads, so Import-RedWindowsLib is not needed.
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
