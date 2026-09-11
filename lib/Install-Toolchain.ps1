function Install-ChooseNim {
    Update-SessionPath
    if (Get-Command nim -ErrorAction SilentlyContinue) {
        Write-Status "[+] [ChooseNim] Nim already installed" 'DarkGray'
        Add-Result -Name 'ChooseNim' -Status Installed -Detail 'already present'
        return $true
    }
    if (-not (Get-Command choosenim -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [ChooseNim] choosenim is not on PATH - install it via winget first" 'Yellow'
        Add-Result -Name 'ChooseNim' -Status Failed -Detail 'choosenim not on PATH'
        return $false
    }

    Write-Status "[-] [ChooseNim] choosenim stable --firstInstall" 'Cyan'
    Invoke-NativeQuiet { choosenim stable --firstInstall 2>$null | Out-Null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [ChooseNim] 'choosenim stable --firstInstall' failed (exit $LASTEXITCODE)" 'Yellow'
        Add-Result -Name 'ChooseNim' -Status Failed -Detail "choosenim stable (exit $LASTEXITCODE)"
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

    # Need both mingw-w64 x64 and x86 toolchains for dual-arch BOF Makefiles.
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
        'Microsoft.VisualStudio.Workload.ManagedDesktop',

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
        'Microsoft.VisualStudio.Component.Roslyn.Compiler',
        'Microsoft.VisualStudio.Component.Roslyn.LanguageServices',

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

    # Zip has one top-level jdk-* folder; move it into place by discovery, not name.
    $extractedRoot = Get-ChildItem -Path $extractTemp -Directory | Select-Object -First 1
    if (-not $extractedRoot) {
        Write-Status "[!] [JDK 17] no top-level folder found in archive" 'Yellow'
        return $false
    }

    if (Test-Path $jdkHome) { Remove-Item -Path $jdkHome -Recurse -Force }
    Move-Item -Path $extractedRoot.FullName -Destination $jdkHome
    Remove-Item -Path $extractTemp -Recurse -Force -ErrorAction SilentlyContinue

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

    # Resolve AMO slug -> signed XPI guid; guessed guids are silently rejected.
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
    # Write policies.json without UTF-8 BOM (Firefox rejects BOM).
    [System.IO.File]::WriteAllText((Join-Path $distDir 'policies.json'), $policyJson, (New-Object System.Text.UTF8Encoding($false)))

    Write-Status "[+] [Firefox Extensions] policies.json written for $($extensionSettings.Count) extension(s) - installs on next Firefox launch" 'Green'
    Add-Result -Name 'Firefox Extensions' -Status Installed -Detail "policies.json:$($Slugs -join ',')"
    return $true
}

function Install-ChromeExtensions {
    param(
        # Chrome extension IDs; ModHeader omitted (pulled for data exfil).
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
        Add-Result -Name 'VulnConfig' -Status Failed -Detail $_.Exception.Message
        return $false
    }

    # Run vuln-config in a child process to avoid function/name collisions.
    Write-Status "[-] [VulnConfig] running vuln-config.ps1 (creates the 'LocalSupport' admin account + intentionally vulnerable services/tasks/registry)" 'Cyan'
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File $destFile
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [VulnConfig] vuln-config.ps1 exited with code $LASTEXITCODE" 'Yellow'
        Add-Result -Name 'VulnConfig' -Status Failed -Detail "exit $LASTEXITCODE"
        return $false
    }

    Write-Status "[+] [VulnConfig] applied" 'Green'
    Add-Result -Name 'VulnConfig' -Status Installed -Detail 'Windows-PrivEsc-Setup/vuln-config.ps1'
    return $true
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

        # build.bat uses relative paths; run from its own directory.
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

function New-CombinedBofCna {
    param(
        [string]$BofRoot = $script:BofRoot,
        [string]$OutputPath = (Join-Path $script:ToolsRoot 'BOF-all.cna')
    )

    Write-Status "[-] [BOF CNA] scanning $BofRoot for .cna files" 'Cyan'
    try {
        if (-not (Test-Path -LiteralPath $BofRoot)) {
            Write-Status "[!] [BOF CNA] $BofRoot not found - skipping" 'Yellow'
            Add-Result -Name 'BOF-all.cna' -Status Skipped -Detail "$BofRoot not found"
            return $false
        }

        $outputFull = [System.IO.Path]::GetFullPath($OutputPath)
        $cnaFiles = @(
            Get-ChildItem -LiteralPath $BofRoot -Filter '*.cna' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { [System.IO.Path]::GetFullPath($_.FullName) -ne $outputFull } |
                Sort-Object FullName
        )

        if ($cnaFiles.Count -eq 0) {
            Write-Status "[!] [BOF CNA] no .cna files under $BofRoot" 'Yellow'
            Add-Result -Name 'BOF-all.cna' -Status Skipped -Detail 'no .cna files found'
            return $false
        }

        # Use include() so each script keeps its own path for script_resource() / relative assets.
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('# Auto-generated by RedWindows - loads all BOF Aggressor scripts under C:\Tools\BOF')
        $lines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $lines.Add("# Scripts: $($cnaFiles.Count)")
        $lines.Add('')

        foreach ($file in $cnaFiles) {
            $posixPath = $file.FullName.Replace('\', '/')
            $lines.Add("include(`"$posixPath`");")
        }

        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $OutputPath -Value ($lines -join "`r`n") -Encoding UTF8 -Force

        Write-Status "[+] [BOF CNA] wrote $($cnaFiles.Count) includes -> $OutputPath" 'Green'
        Add-Result -Name 'BOF-all.cna' -Status Installed -Detail "$($cnaFiles.Count) scripts -> $OutputPath"
        return $true
    } catch {
        Write-Status "[!] [BOF CNA] failed: $($_.Exception.Message)" 'Yellow'
        Add-Result -Name 'BOF-all.cna' -Status Skipped -Detail $_.Exception.Message
        return $false
    }
}

function Install-ConfuseEx {
    Push-Location $script:SharpToolsRoot
    mkdir ConfuserEx-Build
    cd ConfuserEx-Build
    git clone https://github.com/mkaring/ConfuserEx.git
    cd ConfuserEx
    git clone https://github.com/0xd4d/dnlib.git
    dotnet restore Confuser2.sln
    dotnet build Confuser2.sln -c Release
}

function Install-FaceDancerOffline {
    # Prefetch FaceDancer attack-mode crates while install still has internet.
    # Runtime uses CARGO_HOME + vendored sources so payloads build offline.
    Update-SessionPath

    $fdDir = Join-Path $script:ToolsRoot 'FaceDancer'
    $releaseExe = Join-Path $fdDir 'target\release\FaceDancer.exe'
    $rootExe = Join-Path $fdDir 'FaceDancer.exe'
    if (-not (Test-Path -LiteralPath $rootExe)) {
        if (Test-Path -LiteralPath $releaseExe) {
            Copy-Item -LiteralPath $releaseExe -Destination $rootExe -Force
        } else {
            Write-Status "[!] [FaceDancer offline] FaceDancer.exe not found under $fdDir - build FaceDancer first" 'Yellow'
            Add-Result -Name 'FaceDancer offline' -Status Failed -Detail 'FaceDancer.exe missing'
            return $false
        }
    }

    $bundleCandidates = @(
        (Join-Path $script:RedWindowsRoot 'lib\facedancer-offline'),
        (Join-Path $script:ToolsRoot 'lib\facedancer-offline')
    )
    $bundleRoot = $bundleCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $bundleRoot) {
        Write-Status "[!] [FaceDancer offline] lib\facedancer-offline not found" 'Yellow'
        Add-Result -Name 'FaceDancer offline' -Status Failed -Detail 'offline bundle missing'
        return $false
    }

    $crateSrc = Join-Path $bundleRoot 'offline-crate'
    $crateDst = Join-Path $script:ToolsRoot 'facedancer-offline-crate'
    $vendorDir = Join-Path $script:ToolsRoot 'facedancer-vendor'
    $cargoHome = Join-Path $script:ToolsRoot 'facedancer-cargo-home'
    $vendorMarker = Join-Path $vendorDir '.facedancer-vendored'

    Write-Status "[-] [FaceDancer offline] copying stub crate -> $crateDst" 'Cyan'
    if (Test-Path -LiteralPath $crateDst) {
        Remove-Item -LiteralPath $crateDst -Recurse -Force
    }
    Copy-Item -LiteralPath $crateSrc -Destination $crateDst -Recurse -Force

    $vendorPathUnix = ($vendorDir -replace '\\', '/')
    $configToml = @"
# Used via CARGO_HOME so FaceDancer payload builds never contact crates.io.
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$vendorPathUnix"

[net]
offline = true
"@
    New-Item -ItemType Directory -Path $cargoHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cargoHome 'config.toml') -Value $configToml -Encoding UTF8

    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [FaceDancer offline] cargo not on PATH - skipping vendor" 'Yellow'
        Add-Result -Name 'FaceDancer offline' -Status Failed -Detail 'cargo not on PATH'
        return $false
    }

    if (-not (Test-Path -LiteralPath $vendorMarker)) {
        Write-Status "[-] [FaceDancer offline] cargo vendor -> $vendorDir (needs internet once)" 'Cyan'
        Push-Location $crateDst
        try {
            # Offline crate pins 1.85.0 via rust-toolchain.toml.
            Invoke-NativeQuiet { cargo generate-lockfile *>$null }
            if ($LASTEXITCODE -ne 0) {
                Write-Status "[!] [FaceDancer offline] cargo generate-lockfile failed (exit $LASTEXITCODE)" 'Yellow'
                Add-Result -Name 'FaceDancer offline' -Status Failed -Detail "generate-lockfile (exit $LASTEXITCODE)"
                return $false
            }

            if (Test-Path -LiteralPath $vendorDir) {
                Remove-Item -LiteralPath $vendorDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $vendorDir -Force | Out-Null
            cargo vendor --locked $vendorDir
            if ($LASTEXITCODE -ne 0) {
                Write-Status "[!] [FaceDancer offline] cargo vendor failed (exit $LASTEXITCODE)" 'Yellow'
                Add-Result -Name 'FaceDancer offline' -Status Failed -Detail "cargo vendor (exit $LASTEXITCODE)"
                return $false
            }
            Set-Content -LiteralPath $vendorMarker -Value (Get-Date -Format 'o') -Encoding UTF8
        } finally {
            Pop-Location
        }
    } else {
        Write-Status "[+] [FaceDancer offline] vendor cache already present" 'DarkGray'
    }

    $wrapperLines = @(
        '@echo off'
        'rem FaceDancer generates a crate and runs cargo build in %CD%.'
        'rem Use install-time vendored crates; do not hit the network.'
        "set `"PATH=%USERPROFILE%\.cargo\bin;C:\msys64\mingw64\bin;%PATH%`""
        "set `"CARGO_HOME=$cargoHome`""
        'set "CARGO_NET_OFFLINE=true"'
        'set "RUSTUP_AUTO_INSTALL=0"'
        "`"$rootExe`" %*"
    )
    $wrapperPath = Join-Path $fdDir 'FaceDancer.cmd'
    $wrapperTools = Join-Path $script:ToolsRoot 'FaceDancer.cmd'
    Set-Content -LiteralPath $wrapperPath -Value ($wrapperLines -join "`r`n") -Encoding ASCII
    Copy-Item -LiteralPath $wrapperPath -Destination $wrapperTools -Force

    # Prefer the offline wrapper when FaceDancer is invoked from PATH.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @()
    if ($userPath) { $pathEntries = @($userPath -split ';' | Where-Object { $_ }) }
    if ($pathEntries -notcontains $script:ToolsRoot) {
        $newPath = if ($userPath) { "$script:ToolsRoot;$userPath" } else { $script:ToolsRoot }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path = "$script:ToolsRoot;$env:Path"
    }

    Write-Status "[+] [FaceDancer offline] wrapper + vendored crates ready ($wrapperTools)" 'Green'
    Add-Result -Name 'FaceDancer offline' -Status Installed -Detail "vendor:$vendorDir"
    return $true
}

function Install-CrystalKit {
    # Clone lives at C:\Tools\Crystal-Kit (packages.json). Crystal Palace + make
    # are Linux (mingw/nasm); run them in WSL and symlink /opt/Crystal-Kit.
    $kit = Join-Path $script:ToolsRoot 'Crystal-Kit'
    $distro = Get-WslDistroName
    if (-not $distro) {
        Write-Status "[!] [Crystal-Kit] no WSL distro - Crystal Palace/make need Ubuntu" 'Yellow'
        Add-Result -Name 'Crystal-Kit setup' -Status Failed -Detail 'no WSL distro'
        return $false
    }

    if (-not (Test-Path -LiteralPath (Join-Path $kit 'Makefile'))) {
        Write-Status "[-] [Crystal-Kit] repo missing - cloning rasta-mouse/Crystal-Kit" 'Cyan'
        if (-not (Install-GitCloneOnly -Name 'Crystal-Kit' -Repo 'rasta-mouse/Crystal-Kit' -DestRoot $script:ToolsRoot)) {
            Add-Result -Name 'Crystal-Kit setup' -Status Failed -Detail 'git clone failed'
            return $false
        }
    }

    $tgz = Join-Path $kit 'cpdist-latest.tgz'
    $url = 'https://tradecraftgarden.org/download/cpdist-latest.tgz'
    $haveTgz = (Test-Path -LiteralPath $tgz) -and ((Get-Item -LiteralPath $tgz).Length -gt 1MB)
    if (-not $haveTgz) {
        Write-Status "[-] [Crystal Palace] downloading cpdist-latest.tgz" 'Cyan'
        if (-not (Get-RemoteFile -Url $url -Destination $tgz)) {
            Add-Result -Name 'Crystal Palace' -Status Failed -Detail 'download failed'
            return $false
        }
    } else {
        Write-Status "[+] [Crystal Palace] reusing $tgz" 'DarkGray'
    }

    $linuxUser = $script:AttackerUsername
    if (-not $linuxUser) { $linuxUser = 'attacker' }

    $kitUnix = ConvertTo-WslPath $kit
    $setup = @'
set -euo pipefail
cd /
KIT='__KIT__'
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"
touch "$HOME/.bashrc"

ensure_bashrc_line() {
    line="$1"
    grep -qF "$line" "$HOME/.bashrc" || printf '%s\n' "$line" >> "$HOME/.bashrc"
}
ensure_bashrc_line 'export PATH="$HOME/.local/bin:$PATH"'

tar -xzf "$KIT/cpdist-latest.tgz" -C "$KIT"
cd "$KIT/crystalpalace"
chmod +x install
./install

if [ -f "$KIT/crystalpalace/cpl-completion.bash" ]; then
    ensure_bashrc_line "source \"$KIT/crystalpalace/cpl-completion.bash\""
fi
echo "[+] [Crystal Palace] ~/.bashrc PATH + cpl-completion"

cat > link << 'EOF'
#!/usr/bin/env bash
exec "$(dirname "$0")/cpl" link "$@"
EOF
chmod +x link
if [ ! -e "$KIT/crystalpalace/cpl" ] && [ -e "$HOME/.local/bin/cpl" ]; then
    ln -sfn "$HOME/.local/bin/cpl" "$KIT/crystalpalace/cpl"
fi

cd "$KIT"
make
if [ -L /opt/Crystal-Kit ] || [ ! -e /opt/Crystal-Kit ]; then
    sudo -n mkdir -p /opt && sudo -n ln -sfn "$KIT" /opt/Crystal-Kit || true
fi
'@ -replace '__KIT__', $kitUnix

    $setupWin = Join-Path $kit 'redwindows-crystal-setup.sh'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($setupWin, $setup.Replace("`r`n", "`n"), $utf8)
    $setupUnix = ConvertTo-WslPath $setupWin

    Write-Status "[-] [Crystal-Kit] Crystal Palace install + make (WSL $distro as $linuxUser)" 'Cyan'
    $exit = Invoke-WslRoot -Distro $distro -User $linuxUser -Bash "bash '$setupUnix'"
    if ($exit -ne 0) {
        Write-Status "[!] [Crystal-Kit] setup failed (exit $exit)" 'Yellow'
        Add-Result -Name 'Crystal-Kit setup' -Status Failed -Detail "wsl (exit $exit)"
        return $false
    }

    Write-Status "[+] [Crystal-Kit] Crystal Palace + make ready ($kit)" 'Green'
    Add-Result -Name 'Crystal Palace' -Status Installed -Detail 'cpdist-latest + link wrapper'
    Add-Result -Name 'Crystal-Kit setup' -Status Installed -Detail 'make via WSL'
    return $true
}

function Install-Reflectra {
    # Clone lives at C:\Tools\reflectra (packages.json). install.sh is Linux
    # (curl/tar/make + Crystal Palace). Leave upstream build.sh as
    # LINKER=./dist/link and drop a cpl wrapper there (no script edits).
    $kit = Join-Path $script:ToolsRoot 'reflectra'
    $distro = Get-WslDistroName
    if (-not $distro) {
        Write-Status "[!] [reflectra] no WSL distro - install.sh needs Ubuntu" 'Yellow'
        Add-Result -Name 'reflectra setup' -Status Failed -Detail 'no WSL distro'
        return $false
    }

    if (-not (Test-Path -LiteralPath (Join-Path $kit 'install.sh'))) {
        Write-Status "[-] [reflectra] repo missing - cloning k1ng0fn0th1ng/reflectra" 'Cyan'
        if (-not (Install-GitCloneOnly -Name 'reflectra' -Repo 'k1ng0fn0th1ng/reflectra' -DestRoot $script:ToolsRoot)) {
            Add-Result -Name 'reflectra setup' -Status Failed -Detail 'git clone failed'
            return $false
        }
    }

    $linuxUser = $script:AttackerUsername
    if (-not $linuxUser) { $linuxUser = 'attacker' }

    $kitUnix = ConvertTo-WslPath $kit
    $setup = @'
set -euo pipefail
KIT='__KIT__'
cd "$KIT"
chmod +x install.sh build.sh
./install.sh

# build.sh calls ./dist/link. cpl lives in crystalpalace/, not dist/.
mkdir -p "$KIT/dist" "$KIT/crystalpalace"
cat > "$KIT/crystalpalace/link" << 'EOF'
#!/usr/bin/env bash
exec "$(dirname "$0")/cpl" link "$@"
EOF
chmod +x "$KIT/crystalpalace/link"
cat > "$KIT/dist/link" << 'EOF'
#!/usr/bin/env bash
exec "$(dirname "$0")/../crystalpalace/cpl" link "$@"
EOF
chmod +x "$KIT/dist/link"

if [ ! -e "$KIT/crystalpalace/cpl" ] && [ -e "$HOME/.local/bin/cpl" ]; then
    ln -sfn "$HOME/.local/bin/cpl" "$KIT/crystalpalace/cpl"
fi

# Ubuntu 22.04 xxd (2021-10-22) has no -n. build.sh uses: xxd -i -n crystal_loader <bin>
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/xxd" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
real=/usr/bin/xxd
name=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            if [[ $# -lt 2 ]]; then
                echo "xxd: -n requires a name" >&2
                exit 1
            fi
            name="$2"
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
if [[ -z "$name" ]]; then
    exec "$real" "${args[@]}"
fi
"$real" "${args[@]}" | sed -e "s/unsigned char [^[]*/unsigned char ${name}/" -e "s/unsigned int [^[:space:]]*_len/unsigned int ${name}_len/"
EOF
chmod +x "$HOME/.local/bin/xxd"
grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null \
    || printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
'@ -replace '__KIT__', $kitUnix

    $setupWin = Join-Path $kit 'redwindows-reflectra-setup.sh'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($setupWin, $setup.Replace("`r`n", "`n"), $utf8)
    $setupUnix = ConvertTo-WslPath $setupWin

    Write-Status "[-] [reflectra] ./install.sh + dist/link wrapper (WSL $distro as $linuxUser)" 'Cyan'
    $exit = Invoke-WslRoot -Distro $distro -User $linuxUser -Bash "bash '$setupUnix'"
    if ($exit -ne 0) {
        Write-Status "[!] [reflectra] setup failed (exit $exit)" 'Yellow'
        Add-Result -Name 'reflectra setup' -Status Failed -Detail "wsl (exit $exit)"
        return $false
    }

    Write-Status "[+] [reflectra] install.sh completed ($kit)" 'Green'
    Add-Result -Name 'reflectra setup' -Status Installed -Detail 'install.sh + dist/link wrapper via WSL'
    return $true
}
