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

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Output $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
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
& $BashExe -lc "./chromego-filter-then-push-github.sh --no-push" *>&1 | Tee-Object -FilePath $LogFile -Append
if ($LASTEXITCODE -ne 0) {
    throw "Validation script failed with exit code $LASTEXITCODE"
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
    git commit -m $commitMessage *>&1 | Tee-Object -FilePath $LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed with exit code $LASTEXITCODE"
    }

    Write-Log "Pushing to origin/main"
    git push origin main *>&1 | Tee-Object -FilePath $LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed with exit code $LASTEXITCODE"
    }
}

Write-Log "Daily run finished"
