#!/usr/bin/env pwsh
#Requires -Version 7

<#
.SYNOPSIS
    Build shim.exe using Zig.
.PARAMETER BuildMode
    The build mode. Valid values are Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
    Default is ReleaseSmall
.PARAMETER Target
    The target architecture. Valid values are: 'x86-windows-gnu', 'x86-windows-msvc', 'x86_64-windows-gnu', 'x86_64-windows-msvc', 'aarch64-windows-gnu', 'aarch64-windows-msvc'
    Default is undefined (all valid targets)
.PARAMETER Zip
    Generate checksums and pack the artifacts into a zip file for distribution
#>
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$BuildMode = "ReleaseSmall",
    [ValidateSet(
        'x86-windows-gnu',
        'x86-windows-msvc',
        'x86_64-windows-gnu',
        'x86_64-windows-msvc',
        'aarch64-windows-gnu',
        'aarch64-windows-msvc')]
    [string]$Target,
    [switch]$Zip = $false
)

$oldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Stop"

Write-Host "Target: $($Target)";
Write-Host "BuildMode: $($BuildMode)"
Write-Host "Zip: $($Zip)"

if (-not [bool](Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Host "Zig is not installed. Please install Zig before running this script." -ForegroundColor Yellow
    exit 1
}

Remove-Item -Path "$PSScriptRoot\zig-out" -Recurse -Force -ErrorAction SilentlyContinue

Push-Location $PSScriptRoot

$targets = @{
    'x86-windows-gnu'      = 'shim-ia32.exe'
    'x86-windows-msvc'     = 'shim-ia32-msvc.exe'
    'x86_64-windows-gnu'   = 'shim-amd64.exe'
    'x86_64-windows-msvc'  = 'shim-amd64-msvc.exe'
    'aarch64-windows-gnu'  = 'shim-aarch64.exe'
    'aarch64-windows-msvc' = 'shim-aarch64-msvc.exe'
}

if ($Target)
{
    Write-Host "Build shim.exe for $($Target) with optimize $($BuildMode)..." -ForegroundColor Cyan
    Start-Process -FilePath "zig" -ArgumentList "build -Dtarget=$($Target) -Doptimize=$($BuildMode)" -Wait -NoNewWindow
    Rename-Item -Path "$PSScriptRoot\zig-out\bin\shim.exe" -NewName "$PSScriptRoot\zig-out\bin\$($targets[$Target])"
}

if ($Zip) {
    Write-Host "Generate checksums..." -ForegroundColor Cyan

    if ($Target) {
        $sha256 = (Get-FileHash "$PSScriptRoot\zig-out\bin\$($targets[$Target])" -Algorithm SHA256).Hash.ToLower()
        "$sha256 $($targets[$Target])" | Out-File "$PSScriptRoot\zig-out\bin\$($targets[$Target]).sha256"
        $sha512 = (Get-FileHash "$PSScriptRoot\zig-out\bin\$($targets[$Target])" -Algorithm SHA512).Hash.ToLower()
        "$sha512  $($targets[$Target])" | Out-File "$PSScriptRoot\zig-out\bin\$($targets[$Target]).sha512"
    }

    Write-Host "Packaging..." -ForegroundColor Cyan

    $version = (Get-Content "$PSScriptRoot\..\version").Trim()
    Compress-Archive -Path "$PSScriptRoot\zig-out\bin\shim-*" -DestinationPath "$PSScriptRoot\zig-out\shimexe-$version.zip"

    $sha256 = (Get-FileHash "$PSScriptRoot\zig-out\shimexe-$version.zip" -Algorithm SHA256).Hash.ToLower()
    "$sha256 shimexe-$version.zip" | Out-File "$PSScriptRoot\zig-out\shimexe-$version.zip.sha256"
}

Write-Host "Artifacts available in $PSScriptRoot\zig-out" -ForegroundColor Green

Pop-Location

$ErrorActionPreference = $oldErrorActionPreference
