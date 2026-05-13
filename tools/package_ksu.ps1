param(
    [string]$KoPath = "kernel\nohello.ko",
    [string]$Output = "out\nohello-ksu.zip",
    [string]$TargetPath = "/data/local/tmp/nohello",
    [ValidateSet("0", "1")]
    [string]$HideDirents = "1"
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

if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null

Copy-Item -Path (Join-Path $TemplateDir "*") -Destination $StageDir -Recurse -Force
Copy-Item -LiteralPath $KoPath -Destination (Join-Path $StageDir "nohello.ko") -Force
Set-Content -LiteralPath (Join-Path $StageDir "target_path.conf") -Value $TargetPath -NoNewline -Encoding ASCII
Set-Content -LiteralPath (Join-Path $StageDir "hide_dirents.conf") -Value $HideDirents -NoNewline -Encoding ASCII

if (Test-Path -LiteralPath $Output) {
    Remove-Item -LiteralPath $Output -Force
}

Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $Output -Force

Write-Host "Created KernelSU package: $Output"
Write-Host "Target path: $TargetPath"
Write-Host "Hide dirents: $HideDirents"
