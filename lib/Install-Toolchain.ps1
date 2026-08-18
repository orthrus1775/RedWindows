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
