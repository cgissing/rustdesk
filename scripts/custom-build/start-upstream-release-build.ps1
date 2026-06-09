param(
    [string]$UpstreamRef = "",
    [string]$BranchName = "",
    [string]$PatchBranch = "no-auto-api-server-probe",
    [string]$PatchRemote = "",
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$UpstreamRemote = "upstream",
    [string]$PushRemote = "origin",
    [string]$SourceRepository = "rustdesk/rustdesk",
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
        ref = $PatchBranch
        inputs = @{
            rustdesk_ref = $Ref
            source_repository = $SourceRepository
            custom_update_repo = $CustomUpdateRepo
            publish_release = $PublishRelease.ToString().ToLowerInvariant()
        }
    } | ConvertTo-Json -Depth 5

    $uri = "https://api.github.com/repos/$Repository/actions/workflows/$BuildWorkflowFile/dispatches"
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body -ContentType 'application/json'
    Write-Host "Dispatched $BuildWorkflowFile on $PatchBranch for $SourceRepository@$Ref in $Repository."
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

if ([string]::IsNullOrWhiteSpace($UpstreamRef)) {
    $UpstreamRef = Get-LatestRustDeskReleaseTag
    Write-Host "Detected latest upstream RustDesk release: $UpstreamRef"
}

$releaseTag = $UpstreamRef -replace '^refs/tags/', ''
$existingReleaseTagOutput = @(& git -C $SourceRoot ls-remote --tags $PushRemote $releaseTag)
if ($LASTEXITCODE -ne 0) {
    throw "git ls-remote --tags $PushRemote $releaseTag failed"
}
$existingReleaseTag = ($existingReleaseTagOutput -join "`n").Trim()
if ($existingReleaseTag -and -not $RebuildExisting) {
    Write-Host "Release tag $releaseTag already exists on $PushRemote."
    Add-StepSummary "Release tag ``$releaseTag`` already exists; no branch or build was dispatched."
    exit 0
}

if ($DryRun) {
    Write-Host "Dry run: would dispatch $BuildWorkflowFile for $SourceRepository@$UpstreamRef on workflow ref $PatchBranch."
    exit 0
}

if (-not $NoDispatch) {
    Invoke-BuildWorkflowDispatch -Ref $UpstreamRef
    Add-StepSummary "Dispatched build workflow for ``$SourceRepository@$UpstreamRef``."
} else {
    Add-StepSummary "NoDispatch is true; build workflow was not dispatched for ``$SourceRepository@$UpstreamRef``."
}
