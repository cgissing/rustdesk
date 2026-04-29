param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef,
    [string]$BranchName = "",
    [string]$PatchBranch = "no-auto-api-server-probe",
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & git -C $SourceRoot @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed"
    }
}

$status = & git -C $SourceRoot status --porcelain
if ($status) {
    throw "Working tree is not clean. Commit or stash changes before preparing a release branch."
}

if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $safeRef = $UpstreamRef -replace '[^A-Za-z0-9._-]+', '-'
    $BranchName = "custom-$safeRef"
}

Invoke-Git fetch origin $UpstreamRef
Invoke-Git switch --create $BranchName FETCH_HEAD

$base = (& git -C $SourceRoot merge-base origin/master $PatchBranch).Trim()
if ([string]::IsNullOrWhiteSpace($base)) {
    throw "Could not find merge-base between origin/master and $PatchBranch"
}

Invoke-Git cherry-pick "$base..$PatchBranch"

& (Join-Path $PSScriptRoot 'apply-no-auto-api-probe.ps1') -SourceRoot $SourceRoot
if ($LASTEXITCODE -ne 0) {
    throw "API patch verification failed"
}

Write-Host "Prepared $BranchName from $UpstreamRef with custom RustDesk patches."
