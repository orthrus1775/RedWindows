function Install-WingetPackage {
    param(
        [string]$Name, 
        [string]$Id
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [$Name] winget is not on PATH - skipping" 'Yellow'
        Add-Result -Name $Name -Status Failed -Detail 'winget not on PATH'
        return $false
    }

    Write-Status "[-] [$Name] winget install $Id" 'Cyan'

    $existing = winget list --id $Id --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing -match [regex]::Escape($Id)) {
        Write-Status "[+] [$Name] already installed" 'DarkGray'
        Add-Result -Name $Name -Status Installed -Detail 'already present'
        return $true
    }

    # Pipe to Out-Host so winget stdout isn't part of the return value (always-truthy).
    winget install --id $Id -e --accept-source-agreements --accept-package-agreements | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Status "[+] [$Name] installed via winget" 'Green'
        Add-Result -Name $Name -Status Installed -Detail "winget:$Id"
        return $true
    }

    Write-Status "[!] [$Name] winget install failed (exit $LASTEXITCODE)" 'Yellow'
    Add-Result -Name $Name -Status Failed -Detail "winget:$Id (exit $LASTEXITCODE)"
    return $false
}
