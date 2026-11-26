$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:RUNNER_TEMP 'installer'
$encoded = [IO.File]::ReadAllBytes((Join-Path $folder 'encrypted-deliverables.bin'))
$key = [Convert]::FromBase64String($env:OUTPUT_AES_KEY_BASE64)
$clear = [byte[]]::new($encoded.Length - 28)
$aes = [Security.Cryptography.AesGcm]::new($key,16)
try {
    $aes.Decrypt([byte[]]$encoded[0..11], [byte[]]$encoded[28..($encoded.Length - 1)],
        [byte[]]$encoded[12..27], $clear, [byte[]]::new(0))
} finally { $aes.Dispose() }
$zip = Join-Path $folder 'verified.zip'
[IO.File]::WriteAllBytes($zip,$clear)
Expand-Archive -LiteralPath $zip -DestinationPath $folder
$msi = @(Get-ChildItem -LiteralPath $folder -Filter '*.msi')
if ($msi.Count -ne 1) { throw 'Expected exactly one installer.' }
$sum = (Get-Content (Join-Path $folder 'SHA256SUMS.txt') -Raw).Trim()
if ($sum -ne ((Get-FileHash -LiteralPath $msi[0].FullName).Hash + '  ' + $msi[0].Name)) { throw 'Installer hash mismatch.' }
$proc = Start-Process msiexec.exe -ArgumentList ('/i "' + $msi[0].FullName + '" /qn /norestart') -Wait -PassThru
if ($proc.ExitCode -notin 0,3010) { throw "Installer exit $($proc.ExitCode)." }
