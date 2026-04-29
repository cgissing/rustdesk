param(
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $SourceRoot 'src\common.rs'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "src\common.rs not found under $SourceRoot"
}

$source = Get-Content -LiteralPath $commonPath -Raw

$patchedBlock = @'
    if !custom.is_empty() {
        return "".to_owned();
    }
    "https://admin.rustdesk.com".to_owned()
'@

if ($source.Contains($patchedBlock)) {
    Write-Host 'API server patch already present.'
    exit 0
}

$oldBlockPattern = '(?s)    if !custom\.is_empty\(\) \{\s+let mut api = custom;\s+if !api\.contains\("://"\) \{\s+api = format!\("http://\{\}", api\);\s+\}\s+if let Ok\(mut url\) = Url::parse\(&api\) \{\s+if let Some\(port\) = url\.port\(\) \{\s+if port > 2 \{\s+url\.set_port\(Some\(port - 2\)\)\.ok\(\);\s+api = url\.to_string\(\);\s+\}\s+\}\s+\}\s+return api;\s+\}\s+"https://admin\.rustdesk\.com"\.to_owned\(\)'

if ($source -notmatch $oldBlockPattern) {
    throw 'Expected API server inference block was not found and patched block is not present.'
}

$updated = [regex]::Replace($source, $oldBlockPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $patchedBlock }, 1)
Set-Content -LiteralPath $commonPath -Value $updated -Encoding UTF8
Write-Host 'Applied API server patch: custom rendezvous server no longer infers API server.'
