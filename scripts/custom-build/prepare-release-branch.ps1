param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef,
    [string]$BranchName = "",
    [string]$UpstreamRemote = "origin",
    [string]$UpstreamBaseBranch = "master",
    [string]$PatchRemote = "origin",
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

function Get-GitOutput {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $SourceRoot @Args 2>$null)
        if ($LASTEXITCODE -ne 0) {
            return ""
        }
        return ($output -join "`n").Trim()
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function Resolve-GitCommit {
    param([Parameter(Mandatory = $true)][string]$Ref)

    $candidates = @("FETCH_HEAD", $Ref)
    if ($Ref -notmatch '^refs/') {
        $candidates += @("refs/tags/$Ref", "refs/remotes/$UpstreamRemote/$Ref", "$UpstreamRemote/$Ref")
    }

    foreach ($candidate in $candidates) {
        $commit = Get-GitOutput rev-parse --verify "$candidate^{commit}"
        if (-not [string]::IsNullOrWhiteSpace($commit)) {
            return $commit
        }
    }

    return ""
}

function Ensure-FullHistory {
    $isShallow = Get-GitOutput rev-parse --is-shallow-repository
    if ($isShallow -eq "true") {
        Write-Host "Repository is shallow; fetching full branch history from $UpstreamRemote."
        Invoke-Git fetch --unshallow --no-tags $UpstreamRemote "+refs/heads/*:refs/remotes/$UpstreamRemote/*"
    }
}

function Fetch-UpstreamRef {
    param([Parameter(Mandatory = $true)][string]$Ref)

    if ($Ref -match '^refs/tags/') {
        Invoke-Git fetch --no-tags $UpstreamRemote $Ref
        return
    }

    $tagRef = "refs/tags/$Ref"
    $tagExists = @(& git -C $SourceRoot ls-remote --exit-code --tags $UpstreamRemote $Ref 2>$null)
    if ($LASTEXITCODE -eq 0 -and $tagExists) {
        Invoke-Git fetch --no-tags $UpstreamRemote $tagRef
        return
    }

    Invoke-Git fetch --no-tags $UpstreamRemote $Ref
}

function Ensure-UpstreamBaseBranch {
    $upstreamBaseRef = "refs/remotes/$UpstreamRemote/$UpstreamBaseBranch"
    $commit = Get-GitOutput rev-parse --verify "$upstreamBaseRef^{commit}"
    if ([string]::IsNullOrWhiteSpace($commit)) {
        Invoke-Git fetch --no-tags $UpstreamRemote "+refs/heads/${UpstreamBaseBranch}:$upstreamBaseRef"
    }
    return $upstreamBaseRef
}

$status = & git -C $SourceRoot status --porcelain
if ($status) {
    throw "Working tree is not clean. Commit or stash changes before preparing a release branch."
}

if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $safeRef = $UpstreamRef -replace '[^A-Za-z0-9._-]+', '-'
    $BranchName = "custom-$safeRef"
}

Ensure-FullHistory

Fetch-UpstreamRef $UpstreamRef
$upstreamTip = Resolve-GitCommit $UpstreamRef
if ([string]::IsNullOrWhiteSpace($upstreamTip)) {
    throw "Could not resolve $UpstreamRemote/$UpstreamRef"
}

$patchFetchSpec = "${PatchBranch}:refs/remotes/$PatchRemote/$PatchBranch"
Invoke-Git fetch $PatchRemote $patchFetchSpec
$patchRef = "refs/remotes/$PatchRemote/$PatchBranch"

$upstreamBaseRef = Ensure-UpstreamBaseBranch
$base = Get-GitOutput merge-base $upstreamBaseRef $patchRef
if ([string]::IsNullOrWhiteSpace($base)) {
    throw "Could not find merge-base between $upstreamBaseRef and $PatchRemote/$PatchBranch"
}

$customCommits = @(& git -C $SourceRoot rev-list --reverse "$base..$patchRef")
if ($LASTEXITCODE -ne 0) {
    throw "git rev-list --reverse $base..$patchRef failed"
}
if (-not $customCommits) {
    throw "No custom commits found between $base and $patchRef"
}

Invoke-Git switch --create $BranchName $upstreamTip

Invoke-Git cherry-pick @customCommits

& (Join-Path $PSScriptRoot 'apply-no-auto-api-probe.ps1') -SourceRoot $SourceRoot
if ($LASTEXITCODE -ne 0) {
    throw "API patch verification failed"
}

Write-Host "Prepared $BranchName from $UpstreamRef with custom RustDesk patches."
