# Functional tests for shim.exe
# Usage: ./run-tests.ps1 -ShimExe <path-to-shim.exe>

param(
    [Parameter(Mandatory=$true)]
    [string]$ShimExe
)

$ErrorActionPreference = "Stop"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Message = "")
    if ($Passed) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:TestsPassed++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Message) { Write-Host "         $Message" -ForegroundColor Red }
        $script:TestsFailed++
    }
}

function New-TestEnvironment {
    $testDir = Join-Path $env:TEMP "shim-tests-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    return $testDir
}

function Remove-TestEnvironment {
    param([string]$TestDir)
    if (Test-Path $TestDir) {
        Remove-Item -Path $TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Verify shim.exe exists
if (-not (Test-Path $ShimExe)) {
    Write-Error "Shim executable not found: $ShimExe"
    exit 1
}

$ShimExe = (Resolve-Path $ShimExe).Path
Write-Host "Running tests with: $ShimExe" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Test 1: Basic shim functionality
# ============================================================================
Write-Host "Test 1: Basic shim functionality" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = C:\Windows\System32\cmd.exe`nargs = /c echo SHIM_BASIC_OK"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    Write-TestResult "Basic shim execution" ($output -match "SHIM_BASIC_OK") "Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 2: Path with spaces (quoted)
# ============================================================================
Write-Host "Test 2: Path with spaces handling" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    $spacedDir = "$testDir\path with spaces"
    New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
    
    Set-Content -Path "$spacedDir\app.cmd" -Value "@echo off`necho SPACES_OK"
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = $spacedDir\app.cmd"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    Write-TestResult "Path with spaces" ($output -match "SPACES_OK") "Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 3: Environment variable expansion in path (%SystemRoot%)
# ============================================================================
Write-Host "Test 3: Environment variable expansion in path" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = %SystemRoot%\System32\cmd.exe`nargs = /c echo ENVPATH_OK"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    Write-TestResult "%SystemRoot% expansion in path" ($output -match "ENVPATH_OK") "Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 4: Environment variable expansion in path (%TEMP%)
# ============================================================================
Write-Host "Test 4: %TEMP% expansion in path" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    # Create a batch file in TEMP
    $tempBatch = "$env:TEMP\shim-test-temp.cmd"
    Set-Content -Path $tempBatch -Value "@echo off`necho TEMP_PATH_OK"
    
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = %TEMP%\shim-test-temp.cmd"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    Write-TestResult "%TEMP% expansion in path" ($output -match "TEMP_PATH_OK") "Output: $output"
    
    Remove-Item $tempBatch -Force -ErrorAction SilentlyContinue
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 5: Custom environment variables
# ============================================================================
Write-Host "Test 5: Custom environment variables" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Set-Content -Path "$testDir\echoenv.cmd" -Value "@echo off`necho MYVAR=%SHIM_TEST_VAR%"
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = $testDir\echoenv.cmd`nSHIM_TEST_VAR = HelloFromShim"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    Write-TestResult "Custom env var set" ($output -match "MYVAR=HelloFromShim") "Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 6: Environment variable expansion in custom variables
# ============================================================================
Write-Host "Test 6: Env var expansion in custom variables" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Set-Content -Path "$testDir\echoenv.cmd" -Value "@echo off`necho EXPANDED=%SHIM_EXPANDED%"
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = $testDir\echoenv.cmd`nSHIM_EXPANDED = %USERNAME%_suffix"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    $expected = "$env:USERNAME" + "_suffix"
    Write-TestResult "Env expansion in custom var" ($output -match "EXPANDED=$expected") "Expected: EXPANDED=$expected, Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 7: Multiple custom environment variables
# ============================================================================
Write-Host "Test 7: Multiple custom environment variables" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Set-Content -Path "$testDir\echoenv.cmd" -Value "@echo off`necho VAR1=%VAR1%`necho VAR2=%VAR2%`necho VAR3=%VAR3%"
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = $testDir\echoenv.cmd`nVAR1 = first`nVAR2 = second`nVAR3 = third"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    $pass = ($output -match "VAR1=first") -and ($output -match "VAR2=second") -and ($output -match "VAR3=third")
    Write-TestResult "Multiple env vars" $pass "Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 8: Args with %~dp0 placeholder
# ============================================================================
Write-Host "Test 8: Args with %~dp0 placeholder" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = C:\Windows\System32\cmd.exe`nargs = /c echo %~dp0"

    $output = & "$testDir\test.exe" 2>&1 | Out-String
    # %~dp0 should be replaced with the shim's directory
    $shimDir = $testDir.Replace('\', '\\')
    Write-TestResult "Args %~dp0 expansion" ($output -match [regex]::Escape($testDir)) "Expected dir: $testDir, Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Test 9: Pass-through arguments
# ============================================================================
Write-Host "Test 9: Pass-through arguments" -ForegroundColor Yellow

$testDir = New-TestEnvironment
try {
    Set-Content -Path "$testDir\echoargs.cmd" -Value "@echo off`necho ARGS=%*"
    Copy-Item $ShimExe "$testDir\test.exe"
    Set-Content -Path "$testDir\test.shim" -Value "path = $testDir\echoargs.cmd"

    $output = & "$testDir\test.exe" arg1 arg2 "arg with spaces" 2>&1 | Out-String
    $pass = ($output -match "arg1") -and ($output -match "arg2") -and ($output -match "arg with spaces")
    Write-TestResult "Pass-through arguments" $pass "Output: $output"
} finally {
    Remove-TestEnvironment $testDir
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Test Summary: $script:TestsPassed passed, $script:TestsFailed failed" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($script:TestsFailed -gt 0) {
    exit 1
}
exit 0
