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
