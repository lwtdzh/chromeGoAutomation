param(
    [int]$TestJobs = 12,
    [int]$ProxyTestTimeout = 4
)

$ErrorActionPreference = "Stop"

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BashExe = "C:\Program Files\Git\bin\bash.exe"
$SshKey = "C:\Users\Administrator\.ssh\id_ed25519_lwtdzh"
$LogDir = Join-Path $RepoDir "logs"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDir "daily-$Timestamp.log"
$ResultFile = Join-Path $RepoDir "result.list"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Output $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-LoggedProcess {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $stdoutFile = Join-Path $LogDir "process-$Timestamp-$([guid]::NewGuid().ToString('N')).out"
    $stderrFile = Join-Path $LogDir "process-$Timestamp-$([guid]::NewGuid().ToString('N')).err"
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $RepoDir -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        foreach ($file in @($stdoutFile, $stderrFile)) {
            if (Test-Path -LiteralPath $file) {
                $content = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    Add-Content -LiteralPath $LogFile -Value $content -Encoding UTF8
                }
            }
        }
        if ($AllowedExitCodes -notcontains $process.ExitCode) {
            throw "$FilePath exited with code $($process.ExitCode)"
        }
        return $process.ExitCode
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "Starting chromeGoAutomation daily run"
Set-Location $RepoDir

$env:TEST_JOBS = $TestJobs.ToString()
$env:PROXY_TEST_TIMEOUT = $ProxyTestTimeout.ToString()
$env:GIT_SSH_COMMAND = "ssh -i C:/Users/Administrator/.ssh/id_ed25519_lwtdzh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

if (-not (Test-Path -LiteralPath $BashExe)) {
    throw "Git Bash was not found: $BashExe"
}
if (-not (Test-Path -LiteralPath $SshKey)) {
    throw "SSH key was not found: $SshKey"
}

Write-Log "Running validation script"
$startedAtUtc = (Get-Date).ToUniversalTime()
try {
    Invoke-LoggedProcess -FilePath $BashExe -Arguments '-lc "./chromego-filter-then-push-github.sh --no-push"'
} catch {
    $result = Get-Item -LiteralPath $ResultFile -ErrorAction SilentlyContinue
    $totalLine = if ($result) { Select-String -LiteralPath $ResultFile -Pattern '^# Total: [1-9][0-9]*' -Quiet } else { $false }
    if (-not $result -or $result.LastWriteTimeUtc -lt $startedAtUtc -or -not $totalLine) {
        throw
    }
    Write-Log "Validation command returned a nonzero exit code after writing a fresh result.list; continuing to commit the generated result."
}

git config user.name lwtdzh
git config user.email lwtdzh@users.noreply.github.com
git add result.list

git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Log "No result.list changes to commit"
} else {
    $commitMessage = "Update validated result list - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Write-Log "Committing result.list"
    Invoke-LoggedProcess -FilePath "git" -Arguments "commit -m `"$commitMessage`""

    Write-Log "Pushing to origin/main"
    Invoke-LoggedProcess -FilePath "git" -Arguments "push origin main"
}

Write-Log "Daily run finished"
