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
    [IO.File]::WriteAllBytes($archive, [Convert]::FromBase64String($env:SOURCE_ZIP_BASE64))
    try {
        $digest = Get-FileHash -LiteralPath $archive -Algorithm SHA256
        Write-Host "Source archive checksum $($digest.Hash)"
        Expand-Archive -LiteralPath $archive -DestinationPath $base
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

    Push-Location -LiteralPath $source
    try {
        & $msbuild '.\installer\RemoteWorkspace.wixproj' /restore /m /nologo /v:minimal /p:Configuration=Release
        if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE." }
    } finally { Pop-Location }

    $msis = @(Get-ChildItem -LiteralPath (Join-Path $source 'installer\bin') -Filter 'Remote-Workspace-x64.msi' -File -Recurse)
    if ($msis.Count -ne 1) { throw "Expected exactly one MSI, found $($msis.Count)." }
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $installer = Join-Path $dist 'Remote-Workspace-0.3.0-x64.msi'
    Copy-Item -LiteralPath $msis[0].FullName -Destination $installer
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Value "$hash  Remote-Workspace-0.3.0-x64.msi" -Encoding ascii

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
    Write-Host 'Windows Installer verification passed.'
    return
}

$exe = Join-Path $env:ProgramFiles 'Remote Workspace\RemoteWorkspace.exe'
& (Join-Path $PSScriptRoot 'Test-Rdp030.ps1') -Exe $exe
