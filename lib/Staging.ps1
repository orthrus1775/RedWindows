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
    $persistentScript = Join-Path $script:ToolsRoot 'RedWindows.ps1'
    $persistentLib = Join-Path $script:ToolsRoot 'lib'

    $scriptSource = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not $scriptSource) { return $persistentScript }

    $repoRoot = Split-Path -Parent $scriptSource
    $libSource = Join-Path $repoRoot 'lib'

    if ($scriptSource -ne $persistentScript) {
        Copy-Item -Path $scriptSource -Destination $persistentScript -Force
    }

    if (Test-Path $libSource) {
        if (Test-Path $persistentLib) {
            Remove-Item -Path $persistentLib -Recurse -Force
        }
        Copy-Item -Path $libSource -Destination $persistentLib -Recurse -Force
    }

    $packagesSource = Join-Path $repoRoot 'packages.json'
    if (Test-Path -LiteralPath $packagesSource) {
        Copy-Item -Path $packagesSource -Destination (Join-Path $script:ToolsRoot 'packages.json') -Force
    }

    return $persistentScript
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
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $script:AttackerUsername
        $principal = New-ScheduledTaskPrincipal -UserId $script:AttackerUsername -LogonType Interactive -RunLevel Highest
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
    # Flush transcript before forced restart; next stage appends to the same file.
    try { Stop-Transcript | Out-Null } catch {}
    Wait-ForStageBreakpoint -Message "Validate stage before continuing to stage $NextStage, then press Enter to restart..."
    Start-Sleep -Seconds 30
    Restart-Computer -Force
}
