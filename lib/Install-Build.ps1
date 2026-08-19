function Find-MSBuildExe {
    # Prefer Framework MSBuild.exe via vswhere (needed for Fody/legacy tasks).
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
    # Locate VsDevCmd.bat via vswhere + C++ workload (MSBuild alone isn't enough).
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

    # Chain VsDevCmd.bat + build in one cmd.exe so INCLUDE/LIB/PATH apply.
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

    # Repoint stale WinRT HintPaths to an installed SDK contract version.
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

    # COMReference needs Framework MSBuild (ResolveComReference).
    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match '<COMReference\b'
    })
}

function Test-HasResxResources {
    param(
        [string]$CloneDir
    )

    # .resx GenerateResource needs Framework MSBuild's x86 task host.
    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match '<EmbeddedResource\b[^>]*\.resx"'
    })
}

function Test-IsClassicProject {
    param(
        [string]$CloneDir
    )

    # Non-SDK .csproj: use Framework MSBuild.exe, not dotnet build.
    return [bool](Get-ChildItem -Path $CloneDir -Filter '*.csproj' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -notmatch '<Project\s+Sdk='
    })
}

function Repair-StandInCosturaFody {
    param(
        [string]$CloneDir
    )

    # StandIn: bump Costura.Fody/Fody to a compatible pair.
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

    # Restore packages referenced only via HintPath (no packages.config).
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

    # nuget restore (7.x) skips classic packages; use nuget install packages.config.
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
    # Accept owner/repo shorthand or a full clone URL.
    param(
        [string]$Repo
    )

    if ($Repo -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return $Repo
    }
    return "https://github.com/$Repo.git"
}

function Invoke-GitCloneOrUpdate {
    # Shared clone/update with retries; check LASTEXITCODE (git doesn't throw).
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

        # Remove partial clone dirs so retries don't hit a non-repo folder.
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

    # Refresh PATH; package was just installed via winget in this process.
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
        # Prefer .sln; fall back to a lone .csproj when no solution exists.
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
        # After clone, pip install requirements.txt when present.
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
        # Build-time env vars for cross-compile (e.g. CGO_ENABLED/GOARCH/GOOS).
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

        # go build stderr is chatty; Invoke-NativeQuiet avoids EAP Stop aborts.
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

        # CMake generator (default if unset).
        [string]$Generator,
        # Generator -A arch for multi-arch generators (e.g. VS + x64).
        [string]$Architecture,
        # Extra -D defines for configure (e.g. @('-DUPX_CONSOLE=ON')).
        [string[]]$CMakeArgs,
        # Specific --target instead of the generator default.
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
        # Relative path to the BOF build script (cl/link, not MSBuild).
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

    # build.bat uses relative paths; run from its own directory.
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
        # Relative path to the Makefile directory (e.g. 'src').
        [string]$MakeDir = '',
        [string]$MakeTarget,

        # Override CC/STRIP to mingw-w64 names actually installed under msys64.
        [string]$Cc64 = 'x86_64-w64-mingw32-gcc',
        [string]$Strip64 = 'strip',

        # x86 strip needs a full path; bare strip.exe resolves to mingw64 first on PATH.
        [string]$Cc32 = 'i686-w64-mingw32-gcc',
        [string]$Strip32 = 'C:\msys64\mingw32\bin\strip.exe',

        # Soften GCC 14+ errors that break older BOF C sources.
        [string[]]$ExtraCFlags = @(
            '-Wno-error=incompatible-pointer-types',
            '-Wno-error=implicit-function-declaration',
            '-Wno-error=int-conversion'
        ),

        # Recursive: build each BOF subfolder (e.g. CS-Situational-Awareness-BOF).
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
        # Required: native repos often ship multiple solutions; don't guess.
        [Parameter(Mandatory)]
        [string]$SlnPath,
        [string]$Platform,
        [string]$Configuration = 'Release',
        [string]$Ref,

        # Optional SDK/toolset overrides for repos pinned to old VS defaults.
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

    # No NuGet restore; native deps are vendored or from the MSVC/SDK install.
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
    # Refresh PATH; package was just installed via winget in this process.
    Update-SessionPath
    if (Get-Command pipx -ErrorAction SilentlyContinue) {
        Write-Status "[+] [pipx] already installed" 'DarkGray'
        Add-Result -Name 'pipx' -Status Installed -Detail 'already present'
        return $true
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Status "[!] [pipx] python is not on PATH - skipping" 'Yellow'
        Add-Result -Name 'pipx' -Status Failed -Detail 'python not on PATH'
        return $false
    }

    Write-Status "[-] [pipx] pip install pipx" 'Cyan'

    # pip stderr can terminate under EAP Stop; use Invoke-NativeQuiet before ensurepath.
    Invoke-NativeQuiet { python -m pip install pipx *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Status "[!] [pipx] pip install failed (exit $LASTEXITCODE)" 'Yellow'
        Add-Result -Name 'pipx' -Status Failed -Detail "pip install pipx (exit $LASTEXITCODE)"
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
