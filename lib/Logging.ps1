function Write-Status {
    param(
        [string]$Message,
        [string]$Color = 'White',
        [string]$Level
    )
    if ($Level) {
        $Color = switch ($Level) {
            'WARNING' { 'Yellow' }
            'ERROR'   { 'Red' }
            default   { 'Cyan' }
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" -ForegroundColor $Color
    } else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
    }
}

function Write-StatusMessage {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    Write-Status -Message $Message -Level $Level
}

function Invoke-NativeQuiet {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    # EAP Stop turns native stderr into terminating errors; relax only for this call.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Add-Result {
    param(
        [string]$Name,
        [ValidateSet('Installed', 'Skipped', 'Failed')]
        [string]$Status,
        [string]$Detail = ''
    )

    if ($null -eq $script:Results) {
        $script:Results = New-Object System.Collections.Generic.List[object]
    }
    if ($null -eq $script:CurrentStage) {
        $script:CurrentStage = 0
    }

    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Stage     = $script:CurrentStage
        Name      = $Name
        Status    = $Status
        Detail    = $Detail
    }
    $script:Results.Add($entry)

    # Stages 1-3 use this to decide retry-vs-advance in Complete-Stage.
    if ($Status -eq 'Failed') {
        $script:StageHadFailure = $true
    }

    # Persist each result to CSV; in-memory list is per-stage only (reboots).
    if ($script:ResultsCsv) {
        try {
            $entry | Export-Csv -Path $script:ResultsCsv -Append -NoTypeInformation -Force
        } catch {
            Write-Host "[!] Failed to append to results log: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
