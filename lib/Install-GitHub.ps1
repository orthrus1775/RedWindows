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
        # Expand-Archive can't handle .7z; shell out to 7-Zip instead.
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
