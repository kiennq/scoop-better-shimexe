$_VsInstallerDir = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\";
if (Test-Path "$_VsInstallerDir\vswhere.exe") {
    $env:PATH += ";$_VsInstallerDir";
    $installPath = vswhere -latest -property installationPath;
    Import-Module (Join-Path $installPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll") -Force;
    Enter-VsDevShell -VsInstallPath $installPath -SkipAutomaticLocation;
}
