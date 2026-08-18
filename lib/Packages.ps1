# Package catalog loader - declarative entries live in packages.json

function Resolve-PackageDestRoot {
    param([string]$Alias)

    switch ($Alias) {
        { [string]::IsNullOrWhiteSpace($_) -or $_ -eq 'Tools' } { return $script:ToolsRoot }
        'SharpTools' { return $script:SharpToolsRoot }
        'BOF' { return $script:BofRoot }
        'Cloud' { return $script:CloudRoot }
        'Potato' { return $script:PotatoRoot }
        'NimMods' { return $script:NimModsRoot }
        'NightmareEclipse' { return $script:NightmareEclipse }
        default { return $Alias }
    }
}

function ConvertTo-PackageTier {
    param(
        [psobject]$TierSpec,
        [string]$PackageName
    )

    $type = [string]$TierSpec.type
    switch ($type) {
        'winget' {
            $id = [string]$TierSpec.id
            return { Install-WingetPackage -Name $PackageName -Id $id }.GetNewClosure()
        }
        'clone' {
            $repo = [string]$TierSpec.repo
            $destRoot = Resolve-PackageDestRoot $TierSpec.destRoot
            $pipRequirements = [bool]$TierSpec.pipRequirements
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{ Name = $PackageName; Repo = $repo; DestRoot = $destRoot }
                if ($pipRequirements) { $params.PipRequirements = $true }
                if ($subModule) { $params.SubModule = $true }
                Install-GitCloneOnly @params
            }.GetNewClosure()
        }
        'dotnet' {
            $repo = [string]$TierSpec.repo
            $destRoot = Resolve-PackageDestRoot $TierSpec.destRoot
            $slnPath = [string]$TierSpec.slnPath
            $platform = [string]$TierSpec.platform
            $ref = [string]$TierSpec.ref
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{ Name = $PackageName; Repo = $repo; DestRoot = $destRoot }
                if ($slnPath) { $params.SlnPath = $slnPath }
                if ($platform) { $params.Platform = $platform }
                if ($ref) { $params.Ref = $ref }
                if ($subModule) { $params.SubModule = $true }
                Install-FromSourceDotNet @params
            }.GetNewClosure()
        }
        'native' {
            $repo = [string]$TierSpec.repo
            $slnPath = [string]$TierSpec.slnPath
            $destRoot = Resolve-PackageDestRoot $TierSpec.destRoot
            $platform = [string]$TierSpec.platform
            $platformToolset = [string]$TierSpec.platformToolset
            $configuration = if ($TierSpec.configuration) { [string]$TierSpec.configuration } else { 'Release' }
            $ref = [string]$TierSpec.ref
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{
                    Name          = $PackageName
                    Repo          = $repo
                    SlnPath       = $slnPath
                    DestRoot      = $destRoot
                    Configuration = $configuration
                }
                if ($platform) { $params.Platform = $platform }
                if ($ref) { $params.Ref = $ref }
                if ($platformToolset) { $params.PlatformToolset = $platformToolset }
                if ($subModule) { $params.SubModule = $true }
                Install-FromSourceNative @params
            }.GetNewClosure()
        }
        'bofMake' {
            $repo = [string]$TierSpec.repo
            $destAlias = if ($TierSpec.destRoot) { [string]$TierSpec.destRoot } else { 'BOF' }
            $destRoot = Resolve-PackageDestRoot $destAlias
            $makeDir = [string]$TierSpec.makeDir
            $recursive = [bool]$TierSpec.recursive
            $ref = [string]$TierSpec.ref
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{ Name = $PackageName; Repo = $repo; DestRoot = $destRoot }
                if ($makeDir) { $params.MakeDir = $makeDir }
                if ($ref) { $params.Ref = $ref }
                if ($subModule) { $params.SubModule = $true }
                if ($recursive) { $params.Recursive = $true }
                Install-FromSourceBofMake @params
            }.GetNewClosure()
        }
        'bof' {
            $repo = [string]$TierSpec.repo
            $destAlias = if ($TierSpec.destRoot) { [string]$TierSpec.destRoot } else { 'BOF' }
            $destRoot = Resolve-PackageDestRoot $destAlias
            $buildScript = [string]$TierSpec.buildScript
            $ref = [string]$TierSpec.ref
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{ Name = $PackageName; Repo = $repo; DestRoot = $destRoot }
                if ($buildScript) { $params.BuildScript = $buildScript }
                if ($ref) { $params.Ref = $ref }
                if ($subModule) { $params.SubModule = $true }
                Install-FromSourceBof @params
            }.GetNewClosure()
        }
        'rust' {
            $repo = [string]$TierSpec.repo
            $target = [string]$TierSpec.target
            $destRoot = Resolve-PackageDestRoot $TierSpec.destRoot
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{ Name = $PackageName; Repo = $repo; DestRoot = $destRoot }
                if ($target) { $params.Target = $target }
                if ($subModule) { $params.SubModule = $true }
                Install-FromSourceRust @params
            }.GetNewClosure()
        }
        'go' {
            $repo = [string]$TierSpec.repo
            $destRoot = Resolve-PackageDestRoot $TierSpec.destRoot
            $envMap = $null
            if ($TierSpec.env) {
                $envMap = @{}
                foreach ($prop in $TierSpec.env.PSObject.Properties) {
                    $envMap[$prop.Name] = [string]$prop.Value
                }
            }
            return {
                $params = @{ Name = $PackageName; Repo = $repo; DestRoot = $destRoot }
                if ($envMap) { $params.Env = $envMap }
                Install-FromSourceGo @params
            }.GetNewClosure()
        }
        'goInstall' {
            $package = [string]$TierSpec.package
            return { Install-GoInstall -Name $PackageName -Package $package }.GetNewClosure()
        }
        'cmake' {
            $repo = [string]$TierSpec.repo
            $generator = [string]$TierSpec.generator
            $architecture = [string]$TierSpec.architecture
            $subModule = [bool]$TierSpec.subModule
            return {
                $params = @{ Name = $PackageName; Repo = $repo }
                if ($generator) { $params.Generator = $generator }
                if ($architecture) { $params.Architecture = $architecture }
                if ($subModule) { $params.SubModule = $true }
                Install-FromSourceCMake @params
            }.GetNewClosure()
        }
        'pipx' {
            $pipxUrl = [string]$TierSpec.pipxUrl
            return { Install-PipxPackage -Name $PackageName -PipxUrl $pipxUrl }.GetNewClosure()
        }
        'release' {
            $repo = [string]$TierSpec.repo
            $assetPattern = [string]$TierSpec.assetPattern
            $tag = [string]$TierSpec.tag
            $extractZip = [bool]$TierSpec.extractZip
            $extract7z = [bool]$TierSpec.extract7z
            return {
                $params = @{ Name = $PackageName; Repo = $repo; AssetPattern = $assetPattern }
                if ($tag) { $params.Tag = $tag }
                if ($extractZip) { $params.ExtractZip = $true }
                if ($extract7z) { $params.Extract7z = $true }
                Install-GitHubReleaseAsset @params
            }.GetNewClosure()
        }
        'remoteFile' {
            $url = [string]$TierSpec.url
            $destination = ([string]$TierSpec.destination).Replace('{ToolsRoot}', $script:ToolsRoot)
            return { Get-RemoteFile -Url $url -Destination $destination }.GetNewClosure()
        }
        'function' {
            $fnName = [string]$TierSpec.name
            return { & $fnName }.GetNewClosure()
        }
        'multi' {
            $steps = @($TierSpec.steps | ForEach-Object { ConvertTo-PackageTier -TierSpec $_ -PackageName $PackageName })
            return {
                $allOk = $true
                foreach ($step in $steps) {
                    if (-not (& $step)) { $allOk = $false }
                }
                $allOk
            }.GetNewClosure()
        }
        default {
            throw "Unknown package tier type '$type' for package '$PackageName'"
        }
    }
}

function Get-PackageTable {
    $catalogPath = Join-Path $script:RedWindowsRoot 'packages.json'
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        $catalogPath = Join-Path $script:ToolsRoot 'packages.json'
    }
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        throw "packages.json not found (looked under RedWindowsRoot and ToolsRoot)"
    }

    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result = @()
    foreach ($pkg in @($catalog.packages)) {
        if ($pkg.enabled -eq $false) { continue }

        $tiers = @()
        foreach ($tierSpec in @($pkg.tiers)) {
            $tiers += ,(ConvertTo-PackageTier -TierSpec $tierSpec -PackageName $pkg.name)
        }

        $result += @{
            Name  = $pkg.name
            Tiers = $tiers
        }
    }
    return $result
}
