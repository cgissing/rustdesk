param(
    [string]$UpstreamRef = "",
    [string]$BranchName = "",
    [string]$PatchBranch = "no-auto-api-server-probe",
    [string]$PatchRemote = "",
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$UpstreamRemote = "upstream",
    [string]$PushRemote = "origin",
    [string]$CustomUpdateRepo = "cgissing/rustdesk",
    [bool]$PublishRelease = $true,
    [bool]$RebuildExisting = $false,
    [switch]$DryRun,
    [switch]$NoDispatch,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$BuildWorkflowFile = "custom-windows-exe.yml"
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & git -C $SourceRoot @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed"
    }
}

function Get-LatestRustDeskReleaseTag {
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'cgissing-rustdesk-custom-build'
    }
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $headers['Authorization'] = "Bearer $GitHubToken"
    }
    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' `
        -Headers $headers
    if ([string]::IsNullOrWhiteSpace($release.tag_name)) {
        throw 'GitHub latest release response did not include tag_name.'
    }
    return $release.tag_name
}

function Invoke-BuildWorkflowDispatch {
    param([Parameter(Mandatory = $true)][string]$Ref)

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        throw 'Repository is required for workflow dispatch. Set -Repository or GITHUB_REPOSITORY.'
    }
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        throw 'GitHubToken is required for workflow dispatch. Set -GitHubToken or GITHUB_TOKEN.'
    }

    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'Authorization' = "Bearer $GitHubToken"
        'User-Agent' = 'cgissing-rustdesk-custom-build'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $body = @{
        ref = $Ref
        inputs = @{
            rustdesk_ref = $Ref
            custom_update_repo = $CustomUpdateRepo
            publish_release = $PublishRelease.ToString().ToLowerInvariant()
        }
    } | ConvertTo-Json -Depth 5

    $uri = "https://api.github.com/repos/$Repository/actions/workflows/$BuildWorkflowFile/dispatches"
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body -ContentType 'application/json'
    Write-Host "Dispatched $BuildWorkflowFile for $Ref in $Repository."
}

function Add-StepSummary {
    param([string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Text
    }
}

$status = & git -C $SourceRoot status --porcelain
if ($status) {
    throw "Working tree is not clean. Refusing to prepare an upstream release branch."
}

if ([string]::IsNullOrWhiteSpace($PatchRemote)) {
    $PatchRemote = $PushRemote
}

if ([string]::IsNullOrWhiteSpace($UpstreamRef)) {
    $UpstreamRef = Get-LatestRustDeskReleaseTag
    Write-Host "Detected latest upstream RustDesk release: $UpstreamRef"
}

if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $safeRef = $UpstreamRef -replace '^refs/tags/', ''
    $safeRef = $safeRef -replace '[^A-Za-z0-9._-]+', '-'
    $BranchName = "custom-$safeRef"
}

if (-not (& git -C $SourceRoot remote | Where-Object { $_ -eq $UpstreamRemote })) {
    Invoke-Git remote add $UpstreamRemote https://github.com/rustdesk/rustdesk.git
}

$patchFetchSpec = "${PatchBranch}:refs/remotes/$PatchRemote/$PatchBranch"
Invoke-Git fetch $PatchRemote $patchFetchSpec
Invoke-Git fetch $UpstreamRemote --tags --prune

$existingBranchOutput = @(& git -C $SourceRoot ls-remote --heads $PushRemote $BranchName)
if ($LASTEXITCODE -ne 0) {
    throw "git ls-remote --heads $PushRemote $BranchName failed"
}
$existingBranch = ($existingBranchOutput -join "`n").Trim()
if ($existingBranch) {
    Write-Host "Branch $BranchName already exists on $PushRemote."
    Add-StepSummary "Branch ``$BranchName`` already exists for upstream ref ``$UpstreamRef``."
    if (-not $RebuildExisting) {
        Write-Host 'RebuildExisting is false; no build was dispatched.'
        Add-StepSummary 'No build was dispatched because rebuild_existing is false.'
        exit 0
    }
    if ($DryRun) {
        Write-Host "Dry run: would dispatch build for existing branch $BranchName."
        exit 0
    }
    if (-not $NoDispatch) {
        Invoke-BuildWorkflowDispatch -Ref $BranchName
        Add-StepSummary "Dispatched build workflow for existing branch ``$BranchName``."
    }
    exit 0
}

if ($DryRun) {
    Write-Host "Dry run: would create $BranchName from $UpstreamRemote/$UpstreamRef, push to $PushRemote, and dispatch build."
    exit 0
}

& (Join-Path $PSScriptRoot 'prepare-release-branch.ps1') `
    -UpstreamRef $UpstreamRef `
    -BranchName $BranchName `
    -UpstreamRemote $UpstreamRemote `
    -PatchRemote $PatchRemote `
    -PatchBranch $PatchBranch `
    -SourceRoot $SourceRoot
if ($LASTEXITCODE -ne 0) {
    throw "prepare-release-branch.ps1 failed"
}

Invoke-Git push $PushRemote $BranchName
Add-StepSummary "Created and pushed branch ``$BranchName`` from upstream ref ``$UpstreamRef``."

if (-not $NoDispatch) {
    Invoke-BuildWorkflowDispatch -Ref $BranchName
    Add-StepSummary "Dispatched build workflow for ``$BranchName``."
}
