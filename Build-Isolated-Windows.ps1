[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Extract', 'Build', 'Exercise', 'Encrypt')][string] $Phase)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$base = Join-Path $env:RUNNER_TEMP 'remote-workspace-build'
$source = Join-Path $base 'remote-workspace-new'
$dist = Join-Path $base 'dist'

if ($Phase -eq 'Extract') {
    if ([string]::IsNullOrWhiteSpace($env:SOURCE_ZIP_BASE64)) { throw 'The source archive was not supplied.' }
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $archive = Join-Path $base 'source.zip'
    [IO.File]::WriteAllBytes($archive, [Convert]::FromBase64String(($env:SOURCE_ZIP_BASE64 + $env:SOURCE_ZIP_CONTINUED)))
    try {
        $digest = Get-FileHash -LiteralPath $archive -Algorithm SHA256
        Write-Host "Source archive checksum $($digest.Hash)"
        Expand-Archive -LiteralPath $archive -DestinationPath $base
        if ($env:UPGRADE_SOURCE) {
            [IO.File]::WriteAllBytes($archive, [Convert]::FromBase64String($env:UPGRADE_SOURCE))
            Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $base 'previous')
        }
    } finally {
        Remove-Item -LiteralPath $archive
    }
    return
}

if ($Phase -eq 'Encrypt') {
    $key = [Convert]::FromBase64String($env:OUTPUT_AES_KEY_BASE64)
    if ($key.Length -ne 32) { throw 'An AES-256 key is required.' }
    $package = Join-Path $base 'deliverables.zip'
    Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $package -CompressionLevel Optimal
    $plain = [IO.File]::ReadAllBytes($package)
    $nonce = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
    $tag = [byte[]]::new(16)
    $ciphertext = [byte[]]::new($plain.Length)
    $aes = [Security.Cryptography.AesGcm]::new($key, 16)
    try {
        $aes.Encrypt($nonce, $plain, $ciphertext, $tag, [byte[]]::new(0))
        $out = [IO.File]::Create((Join-Path $PSScriptRoot 'encrypted-deliverables.bin'))
        try {
            $out.Write($nonce, 0, $nonce.Length)
            $out.Write($tag, 0, $tag.Length)
            $out.Write($ciphertext, 0, $ciphertext.Length)
        } finally { $out.Dispose() }
    } finally { $aes.Dispose() }
    return
}

if ($Phase -eq 'Build') {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\Current\Bin\amd64\MSBuild.exe' | Select-Object -First 1
    if (!$msbuild) { throw 'Visual Studio MSBuild was not found.' }

    function Build-Package([string] $folder) {
        Push-Location -LiteralPath $folder
        try {
            & $msbuild '.\installer\RemoteWorkspace.wixproj' /restore /m /nologo /v:minimal /p:Configuration=Release | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE." }
        } finally { Pop-Location }
        $files = @(Get-ChildItem -LiteralPath (Join-Path $folder 'installer\bin') -Filter 'Remote-Workspace-x64.msi' -File -Recurse)
        if ($files.Count -ne 1) { throw "Expected one MSI, found $($files.Count)." }
        return $files[0]
    }
    $previous = Join-Path $base 'previous\remote-workspace-new'
    if (Test-Path -LiteralPath $previous) {
        $old = Build-Package $previous
        $installOld = Start-Process msiexec.exe -ArgumentList ('/i "' + $old.FullName + '" /qn /norestart') -Wait -PassThru
        if ($installOld.ExitCode -notin 0,3010) { throw "Previous MSI failed with exit code $($installOld.ExitCode)." }
        $catalogFile = Join-Path $env:LOCALAPPDATA 'Remote Workspace\catalog.xml'
        New-Item -ItemType Directory -Path (Split-Path -Parent $catalogFile) -Force | Out-Null
        Set-Content -LiteralPath $catalogFile -Value '<Catalog><Revision>upgrade-fixture</Revision><Folders/><Profiles/></Catalog>'
        $catalogHash = (Get-FileHash $catalogFile).Hash
    }
    $msis = @(Build-Package $source)
    [xml]$definition = Get-Content -LiteralPath (Join-Path $source 'installer\Package.wxs') -Raw
    $version = $definition.Wix.Package.Version
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid installer version.' }
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $packageName = "Remote-Workspace-$version-x64.msi"
    $installer = Join-Path $dist $packageName
    Copy-Item -LiteralPath $msis[0].FullName -Destination $installer
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Value "$hash  $packageName" -Encoding ascii

    $installLog = Join-Path $base 'install.log'
    $installArguments = "/i `"$installer`" /qn /norestart /L*v `"$installLog`""
    $install = Start-Process -FilePath "$env:WINDIR\System32\msiexec.exe" -ArgumentList $installArguments -Wait -PassThru
    if ($install.ExitCode -notin 0, 3010) {
        Select-String -LiteralPath $installLog -Pattern 'Return value 3' -Context 15, 4 | Select-Object -Last 4 | Out-Host
        throw "MSI installation failed with exit code $($install.ExitCode)."
    }
    $exe = Join-Path $env:ProgramFiles 'Remote Workspace\RemoteWorkspace.exe'
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The MSI did not install the x64 application.' }
    foreach ($dependency in @('Interop.MSTSCLib.dll', 'AxInterop.MSTSCLib.dll')) {
        if (!(Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) $dependency))) {
            throw "The MSI did not install $dependency."
        }
    }
    $registered = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'Remote Workspace' })
    if ($registered.Count -ne 1) { throw 'Expected one uninstall entry for Remote Workspace.' }
    if ($registered[0].DisplayVersion -ne $version) { throw 'Unexpected installed version.' }
    if (Test-Path -LiteralPath $previous) {
        if ((Get-FileHash $catalogFile).Hash -ne $catalogHash) { throw 'Upgrade changed the local catalog.' }
        Write-Host 'Upgrade preserved the local catalog and registered the new version.'
    }
    Write-Host 'Windows Installer verification passed.' 
    return
}

$exe = Join-Path $env:ProgramFiles 'Remote Workspace\RemoteWorkspace.exe'
& (Join-Path $PSScriptRoot 'Test-Rdp030.ps1') -Exe $exe
