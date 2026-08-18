# Logging / result tracking

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

    # With $ErrorActionPreference = 'Stop' set globally, redirecting a native command's
    # stderr - via 2>&1, 2>$null, OR *>$null, contrary to the belief baked into some of
    # the call sites below that *>$null is safe - wraps each stderr line into a
    # terminating NativeCommandError. Chatty-but-successful tools (pipx's "creating
    # virtual environment...", go's "go: downloading ...", rustup's "info: downloading
    # component ...") then abort the calling function before it ever reaches its own
    # $LASTEXITCODE check. Relax the preference only for the duration of the call so
    # $LASTEXITCODE still reflects the real outcome afterward.
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
    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Stage     = $script:CurrentStage
        Name      = $Name
        Status    = $Status
        Detail    = $Detail
    }
    $script:Results.Add($entry)

    # Each stage runs in its own process (the script restarts the machine between stages), so
    # $script:Results alone only ever holds the current stage's entries. Appending every result
    # to disk immediately is what lets Show-Summary report on the whole 3-stage run, and lets
    # this file be read back after the fact to diagnose failures.
    if ($script:ResultsCsv) {
        try {
            $entry | Export-Csv -Path $script:ResultsCsv -Append -NoTypeInformation -Force
        } catch {
            Write-Host "[!] Failed to append to results log: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
