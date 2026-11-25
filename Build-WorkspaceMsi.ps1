[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string] $Program, [string[]] $Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path $Program -Leaf) failed with exit code $LASTEXITCODE."
    }
}

$commit = '068f5942e73a0b4e3c461d861216788ac5a4958a'
$source = Join-Path $env:RUNNER_TEMP 'mremoteng-workspace-source'
$patch = Join-Path $PSScriptRoot 'mRemoteNG-1.76.20-Workspace.patch'
Invoke-Checked 'git' @('clone', '--branch', 'v1.76.20', '--depth', '1', '--single-branch', '--config', 'core.autocrlf=false', 'https://github.com/mRemoteNG/mRemoteNG.git', $source)
$actualCommit = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $commit) {
    throw "Unexpected mRemoteNG commit: $actualCommit"
}
Invoke-Checked 'git' @('-C', $source, 'apply', '--check', '--whitespace=nowarn', $patch)
Invoke-Checked 'git' @('-C', $source, 'apply', '--whitespace=nowarn', $patch)

$programFilesX86 = ${env:ProgramFiles(x86)}
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1
if (!$vsRoot) { throw 'Visual Studio MSBuild was not found.' }
$msbuild = Join-Path $vsRoot 'MSBuild\Current\Bin\MSBuild.exe'
$wix = Join-Path $programFilesX86 'MSBuild\Microsoft\WiX\v3.x'
$wixTargets = Join-Path $wix 'Wix.targets'
$wixCaTargets = Join-Path $wix 'Wix.CA.targets'
$wixInstallDir = $env:WIX
if (!$wixInstallDir) { $wixInstallDir = Join-Path $programFilesX86 'WiX Toolset v3.14' }
$heat = Join-Path $wixInstallDir 'bin\heat.exe'
foreach ($file in @($msbuild, $wixTargets, $wixCaTargets, $heat)) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Build dependency not found: $file" }
}
$env:WIX = $wixInstallDir.TrimEnd('\') + '\'

$frameworkPackages = Join-Path $env:RUNNER_TEMP 'mremoteng-framework-packages'
$frameworkRoot = Join-Path $env:RUNNER_TEMP 'mremoteng-framework-targeting'
$frameworkFolder = Join-Path $frameworkRoot '.NETFramework'
New-Item -ItemType Directory -Path $frameworkFolder | Out-Null
$frameworkVersions = [ordered]@{ net20 = 'v2.0'; net46 = 'v4.6' }
foreach ($framework in $frameworkVersions.Keys) {
    $package = "Microsoft.NETFramework.ReferenceAssemblies.$framework"
    Invoke-Checked 'nuget' @('install', $package, '-Version', '1.0.3', '-ExcludeVersion', '-NonInteractive', '-OutputDirectory', $frameworkPackages)
    $packPath = Join-Path $frameworkPackages "$package\build\.NETFramework\$($frameworkVersions[$framework])"
    if (!(Test-Path -LiteralPath $packPath -PathType Container)) { throw "Reference assemblies not found: $packPath" }
    Copy-Item -LiteralPath $packPath -Destination $frameworkFolder -Recurse
}

# Citrix ICA is a registered COM reference in the original x86 project.
# Use the receiver bundled and installed by the pinned upstream build.
$receiver = Join-Path $source 'mRemoteV1\Resources\CitrixReceiver.exe'
$citrix = Start-Process -FilePath $receiver -ArgumentList @('/silent', 'DONOTSTARTCC=1', 'ENABLE_SSON=No') -Wait -PassThru
if ($citrix.ExitCode -notin 0, 3010) {
    throw "Citrix Receiver installation failed with exit code $($citrix.ExitCode)."
}

$solution = Join-Path $source 'mRemoteV1.sln'
Invoke-Checked 'nuget' @('restore', $solution, '-NonInteractive')
Invoke-Checked $msbuild @($solution, '/nologo', '/t:Build', '/p:Configuration=Release Installer', '/p:Platform=x86', "/p:TargetFrameworkRootPath=$frameworkRoot", "/p:WixTargetsPath=$wixTargets", "/p:WixCATargetsPath=$wixCaTargets")

$packages = @(Get-ChildItem -LiteralPath (Join-Path $source 'Release') -Filter '*.msi' -File)
if ($packages.Count -ne 1) { throw "Expected one MSI, found $($packages.Count)." }
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist | Out-Null
$fileName = 'mRemoteNG-1.76.20-Workspace-x86.msi'
$installerPath = Join-Path $dist $fileName
Copy-Item -LiteralPath $packages[0].FullName -Destination $installerPath

$installPath = Join-Path $env:RUNNER_TEMP 'mremoteng-msi-smoke'
$installLog = Join-Path $env:RUNNER_TEMP 'mremoteng-msi-install.log'
$msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
$installArguments = "/i `"$installerPath`" /qn /norestart /l*v `"$installLog`" INSTALLDIR=`"$installPath`""
$install = Start-Process -FilePath $msiexec -ArgumentList $installArguments -Wait -PassThru
if ($install.ExitCode -notin 0, 3010) {
    if (Test-Path -LiteralPath $installLog) {
        Select-String -LiteralPath $installLog -Pattern 'Return value 3' -Context 12, 2 | Select-Object -Last 4 | Out-Host
    }
    throw "Smoke installation failed with exit code $($install.ExitCode)."
}

$installedExe = Join-Path $installPath 'mRemoteNG.exe'
$compiledExe = Join-Path $source 'mRemoteV1\bin\Release\mRemoteNG.exe'
$installedHash = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
if ($installedHash -ne (Get-FileHash -LiteralPath $compiledExe -Algorithm SHA256).Hash) {
    throw 'The installed application differs from the compiled executable.'
}
$installedTheme = Join-Path $installPath 'Themes\darcula.vstheme'
$sourceTheme = Join-Path $source 'mRemoteV1\Resources\Themes\darcula.vstheme'
if ((Get-FileHash -LiteralPath $installedTheme -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sourceTheme -Algorithm SHA256).Hash) {
    throw 'The installed theme differs from the Workspace theme.'
}
Write-Host 'Installer smoke check passed. The installed EXE and Workspace theme match the build.'

$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii -Value "$hash  $fileName"
