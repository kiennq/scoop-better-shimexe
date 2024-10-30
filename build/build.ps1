#!/usr/bin/env pwsh
#Requires -Version 7

<#
.SYNOPSIS
    Build shim.exe using Zig.
.PARAMETER BuildMode
    The build mode. Valid values are Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
    Default is ReleaseSmall
.PARAMETER Target
    The target architecture. Valid values are x86-windows-gnu, x86_64-windows-gnu, aarch64-windows-gnu
    Default is undefined (all valid targets)
.PARAMETER Zip
    Generate checksums and pack the artifacts into a zip file for distribution
#>
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$BuildMode = "ReleaseSmall",
    [ValidateSet('x86-windows-gnu', 'x86_64-windows-gnu', 'aarch64-windows-gnu')]
    [string]$Target,
    [switch]$Zip = $false
)

$oldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Stop"

if (-not [bool](Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Host "Zig is not installed. Please install Zig before running this script." -ForegroundColor Yellow
    exit 1
}

Remove-Item -Path "$PSScriptRoot\zig-out" -Recurse -Force -ErrorAction SilentlyContinue

Push-Location $PSScriptRoot

if (-not $Target -or $Target -eq 'x86-windows-gnu') {
    Write-Host "Build shim.exe for x86-windows-gnu target..." -ForegroundColor Cyan
    Start-Process -FilePath "zig" -ArgumentList "build -Dtarget=x86-windows-gnu -Doptimize=$BuildMode" -Wait -NoNewWindow
    Rename-Item -Path "$PSScriptRoot\zig-out\bin\shim.exe" -NewName "$PSScriptRoot\zig-out\bin\shim-ia32.exe"
}

if (-not $Target -or $Target -eq 'x86_64-windows-gnu') {
    Write-Host "Build shim.exe for x86_64-windows-gnu target..." -ForegroundColor Cyan
    Start-Process -FilePath "zig" -ArgumentList "build -Dtarget=x86_64-windows-gnu -Doptimize=$BuildMode" -Wait -NoNewWindow
    Rename-Item -Path "$PSScriptRoot\zig-out\bin\shim.exe" -NewName "$PSScriptRoot\zig-out\bin\shim-amd64.exe"
}

if (-not $Target -or $Target -eq 'aarch64-windows-gnu') {
    Write-Host "Build shim.exe for aarch64-windows-gnu target..." -ForegroundColor Cyan
    Start-Process -FilePath "zig" -ArgumentList "build -Dtarget=aarch64-windows-gnu -Doptimize=$BuildMode" -Wait -NoNewWindow
    Rename-Item -Path "$PSScriptRoot\zig-out\bin\shim.exe" -NewName "$PSScriptRoot\zig-out\bin\shim-aarch64.exe"
}

if ($Zip) {
    Write-Host "Generate checksums..." -ForegroundColor Cyan

    # shim-ia32.exe
    if (-not $Target -or $Target -eq 'x86-windows-gnu') {
        $sha256 = (Get-FileHash "$PSScriptRoot\zig-out\bin\shim-ia32.exe" -Algorithm SHA256).Hash.ToLower()
        "$sha256 shim-ia32.exe" | Out-File "$PSScriptRoot\zig-out\bin\shim-ia32.exe.sha256"
        $sha512 = (Get-FileHash "$PSScriptRoot\zig-out\bin\shim-ia32.exe" -Algorithm SHA512).Hash.ToLower()
        "$sha512 shim-ia32.exe" | Out-File "$PSScriptRoot\zig-out\bin\shim-ia32.exe.sha512"
    }

    # shim-amd64.exe
    if (-not $Target -or $Target -eq 'x86_64-windows-gnu') {
        $sha256 = (Get-FileHash "$PSScriptRoot\zig-out\bin\shim-amd64.exe" -Algorithm SHA256).Hash.ToLower()
        "$sha256 shim-amd64.exe" | Out-File "$PSScriptRoot\zig-out\bin\shim-amd64.exe.sha256"
        $sha512 = (Get-FileHash "$PSScriptRoot\zig-out\bin\shim-amd64.exe" -Algorithm SHA512).Hash.ToLower()
        "$sha512 shim-amd64.exe" | Out-File "$PSScriptRoot\zig-out\bin\shim-amd64.exe.sha512"
    }

    # shim-aarch64.exe
    if (-not $Target -or $Target -eq 'aarch64-windows-gnu') {
        $sha256 = (Get-FileHash "$PSScriptRoot\zig-out\bin\shim-aarch64.exe" -Algorithm SHA256).Hash.ToLower()
        "$sha256 shim-aarch64.exe" | Out-File "$PSScriptRoot\zig-out\bin\shim-aarch64.exe.sha256"
        $sha512 = (Get-FileHash "$PSScriptRoot\zig-out\bin\shim-aarch64.exe" -Algorithm SHA512).Hash.ToLower()
        "$sha512 shim-aarch64.exe" | Out-File "$PSScriptRoot\zig-out\bin\shim-aarch64.exe.sha512"
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
