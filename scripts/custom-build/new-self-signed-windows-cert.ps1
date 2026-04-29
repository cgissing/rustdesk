param(
    [string]$OutputDirectory = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'custom-signing'),
    [string]$Subject = 'CN=RustDesk Custom Build',
    [string]$PasswordFile = 'pfx-password.txt',
    [string]$PfxFile = 'rustdesk-custom-build.pfx',
    [string]$Base64File = 'rustdesk-custom-build.pfx.base64.txt'
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$passwordBytes = [byte[]](1..48 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 })
$passwordPlain = [Convert]::ToBase64String($passwordBytes)
$securePassword = ConvertTo-SecureString -String $passwordPlain -Force -AsPlainText

$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears(10)

$pfxPath = Join-Path $OutputDirectory $PfxFile
$passwordPath = Join-Path $OutputDirectory $PasswordFile
$base64Path = Join-Path $OutputDirectory $Base64File

Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePassword | Out-Null
[System.IO.File]::WriteAllText($passwordPath, $passwordPlain, [System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText($base64Path, [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfxPath)), [System.Text.Encoding]::ASCII)

Write-Host "Created PFX: $pfxPath"
Write-Host "Created password file: $passwordPath"
Write-Host "Created GitHub secret base64 file: $base64Path"
Write-Host 'Use CUSTOM_WINDOWS_PFX_BASE64 for the base64 file contents and CUSTOM_WINDOWS_PFX_PASSWORD for the password.'
