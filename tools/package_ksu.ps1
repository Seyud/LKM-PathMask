param(
    [string]$KoPath = "kernel\nohello.ko",
    [string]$Output = "out\nohello-ksu.zip",
    [string]$TargetPath = "/data/local/tmp/nohello",
    [ValidateSet("0", "1")]
    [string]$HideDirents = "1",
    [ValidateSet("global", "deny")]
    [string]$ScopeMode = "global",
    [string]$DenyPackage = "",
    [string]$DenyUid = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$TemplateDir = Join-Path $RepoRoot "ksu-module"
$StageDir = Join-Path $RepoRoot "out\ksu-stage"

if (-not [System.IO.Path]::IsPathRooted($KoPath)) {
    $KoPath = Join-Path $RepoRoot $KoPath
}

if (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path $RepoRoot $Output
}

if (-not (Test-Path -LiteralPath $KoPath)) {
    throw "Missing kernel module: $KoPath"
}

if (-not (Test-Path -LiteralPath $TemplateDir)) {
    throw "Missing KernelSU template: $TemplateDir"
}

$TargetList = $TargetPath -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $TargetList) {
    throw "No target paths were provided"
}

$DenyPackageList = $DenyPackage -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$DenyUidList = $DenyUid -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }

if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null

Copy-Item -Path (Join-Path $TemplateDir "*") -Destination $StageDir -Recurse -Force
Copy-Item -LiteralPath $KoPath -Destination (Join-Path $StageDir "nohello.ko") -Force
Set-Content -LiteralPath (Join-Path $StageDir "target_path.conf") -Value $TargetList -Encoding ASCII
Set-Content -LiteralPath (Join-Path $StageDir "hide_dirents.conf") -Value $HideDirents -NoNewline -Encoding ASCII
Set-Content -LiteralPath (Join-Path $StageDir "scope_mode.conf") -Value $ScopeMode -NoNewline -Encoding ASCII
Set-Content -LiteralPath (Join-Path $StageDir "deny_packages.conf") -Value $DenyPackageList -Encoding ASCII
Set-Content -LiteralPath (Join-Path $StageDir "deny_uids.conf") -Value $DenyUidList -Encoding ASCII

if (Test-Path -LiteralPath $Output) {
    Remove-Item -LiteralPath $Output -Force
}

Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $Output -Force

Write-Host "Created KernelSU package: $Output"
Write-Host "Target paths: $($TargetList -join ', ')"
Write-Host "Hide dirents: $HideDirents"
Write-Host "Scope mode: $ScopeMode"
Write-Host "Deny packages: $($DenyPackageList -join ', ')"
Write-Host "Deny UIDs: $($DenyUidList -join ', ')"
