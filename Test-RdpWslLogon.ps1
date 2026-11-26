[CmdletBinding()]
param([Parameter(Mandatory)][string] $Exe, [switch] $InsideWatchdog, [string] $AuditDirectory)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This test requires an isolated hosted runner.'
}
if (!$InsideWatchdog) {
    $audit = Join-Path $env:RUNNER_TEMP ('rw-acceptance-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Type Directory $audit
    $stageFile = Join-Path $audit 'stage'
    $stdout = Join-Path $audit 'stdout'
    $stderr = Join-Path $audit 'stderr'
    $arguments = @('-NoProfile','-NonInteractive','-File',('"' + $PSCommandPath + '"'),'-Exe',('"' + $Exe + '"'),
        '-InsideWatchdog','-AuditDirectory',('"' + $audit + '"'))
    $child = Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $last = ''
    $deadline = [DateTime]::UtcNow.AddSeconds(245)
    while (!$child.WaitForExit(1500) -and [DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $stageFile) {
            $current = [IO.File]::ReadAllText($stageFile)
            if ($current -and $current -ne $last) { $last = $current; Write-Host "Acceptance: $current" }
        }
    }
    if (!$child.HasExited) {
        Write-Host "::error::Independent fixture deadline reached at stage '$last'."
        # Kill just this test process tree. The job VM is discarded afterwards.
        & taskkill.exe /PID $child.Id /T /F | Out-Null
    }
    foreach ($log in @($stdout,$stderr)) {
        if (Test-Path $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
    }
    if (!$child.HasExited -or $child.ExitCode -ne 0) { throw "Independent fixture failed at '$last'." }
    return
}
function Set-FixtureStage([string] $Name) {
    [IO.File]::WriteAllText((Join-Path $AuditDirectory 'stage'), $Name)
    Write-Host $Name
}

. (Join-Path $PSScriptRoot 'Test-Rdp030.ps1') -Exe $Exe -OnlyHelpers
. (Join-Path $PSScriptRoot 'Test-RdpSessionControls.ps1')
. (Join-Path $PSScriptRoot 'Test-FixtureCredentialPrompt.ps1')
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'The WSL RDP fixture requires a disposable hosted Windows runner.'
}
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$distro = 'RemoteWorkspaceFixture-' + [guid]::NewGuid().ToString('N')
$folder = Join-Path $env:RUNNER_TEMP $distro
$endpoint = 'rw-xrdp-fixture.test'
$port = 34389
$hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$originalHosts = [IO.File]::ReadAllBytes($hosts)
$certificate = $null
$app = $null
$server = $null
$imported = $false
function Run-Linux([string[]] $Arguments) {
    & $wsl -d $distro -u root --exec @Arguments
    if ($LASTEXITCODE -ne 0) { throw "WSL fixture command $($Arguments[0]) exited with $LASTEXITCODE." }
}
try {
    $null = New-Item -ItemType Directory -Path $folder
    $tar = $env:RDP_FIXTURE_ROOTFS
    if ([string]::IsNullOrWhiteSpace($tar)) {
        $tar = Join-Path $env:RUNNER_TEMP 'rdp-fixture/test-rdp-rootfs.tar.gz'
    }
    Set-FixtureStage 'Checking the SHA256 of the preprovisioned independent RDP fixture.'
    if ($env:RDP_FIXTURE_SHA256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        (Get-FileHash -LiteralPath $tar -Algorithm SHA256).Hash -ne $env:RDP_FIXTURE_SHA256) {
        throw 'The downloaded preprovisioned fixture must match the Linux job digest.'
    }
    Set-FixtureStage 'Importing the signed-package filesystem into WSL1.'
    & $wsl --import $distro (Join-Path $folder 'root') $tar --version 1
    if ($LASTEXITCODE -ne 0) { throw 'WSL1 distro import failed.' }
    $imported = $true
    Set-FixtureStage 'Provisioning the TLS-only loopback xrdp fixture and two test profiles.'
    # WSL1 mounts Windows drive roots under /mnt/<letter> by default.
    $scriptPath = Join-Path $folder 'fixture.sh'
    $fixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-XrdpFixture.sh')).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($scriptPath, $fixture, [Text.UTF8Encoding]::new($false))
    $linuxPath = '/mnt/' + $scriptPath.Substring(0,1).ToLowerInvariant() + $scriptPath.Substring(2).Replace('\','/')
    Run-Linux -Arguments @('/usr/bin/timeout','240','/bin/bash',$linuxPath)
    $password = 'Qa!' + [guid]::NewGuid().ToString('N') + 'a7'
    Write-Host "::add-mask::$password"
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    "rwalpha:$password`nrwbeta:$password" | & $wsl -d $distro -u root --exec /bin/bash $linuxPath set-passwords
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize disposable credentials.' }

    Set-FixtureStage 'Reading the guest TLS identity.'
    $public = (Run-Linux -Arguments @('/bin/cat','/etc/xrdp/qa-cert.pem')) -join [Environment]::NewLine
    $publicFile = Join-Path $folder 'linux-server.cer'
    [IO.File]::WriteAllText($publicFile, $public, [Text.Encoding]::ASCII)
    Set-FixtureStage 'Trusting the generated fixture TLS certificate.'
    $certificate = Import-Certificate -FilePath $publicFile -CertStoreLocation 'Cert:\LocalMachine\Root'
    Add-Content -LiteralPath $hosts -Value ([Environment]::NewLine + "127.0.0.1 $endpoint") -Encoding ASCII
    $ips = [Net.Dns]::GetHostAddresses($endpoint)
    if ($ips.Count -ne 1 -or ![Net.IPAddress]::IsLoopback($ips[0])) { throw 'Fixture DNS must resolve to loopback.' }
    Set-FixtureStage 'Starting xrdp and sesman under an independent WSL supervisor.'
    $server = Start-Process -FilePath $wsl -ArgumentList @('-d', $distro, '-u','root','--exec','/bin/bash',('"' + $linuxPath + '"'),'serve') `
        -RedirectStandardOutput (Join-Path $folder 'daemon.out') -RedirectStandardError (Join-Path $folder 'daemon.err') -PassThru
    $listening = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (!$listening -and [DateTime]::UtcNow -lt $deadline -and !$server.HasExited) {
        $tcp = [Net.Sockets.TcpClient]::new()
        try {
            $connect = $tcp.ConnectAsync([Net.IPAddress]::Loopback, $port)
            $listening = $connect.Wait(400) -and $tcp.Connected
        } catch { } finally { $tcp.Dispose() }
        if (!$listening) { Start-Sleep -Milliseconds 200 }
    }
    if (!$listening) { throw 'WSL xrdp did not listen on loopback within 15 seconds.' }
    Run-Linux -Arguments @('/bin/bash',$linuxPath,'verify-bind')
    Set-FixtureStage 'Independent xrdp server is ready on loopback with a trusted TLS certificate.'

    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $store)
    $profiles = foreach ($username in @('rwalpha','rwbeta')) {
        "<Profile><Id>$username</Id><Name>$username</Name><Host>$endpoint</Host><Protocol>RDP</Protocol><Port>$port</Port><User>$username</User><PromptForCredentials>true</PromptForCredentials></Profile>"
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $store)
    "<Catalog><Revision>independent-rdp-fixture</Revision><Folders/><Profiles>$profiles</Profiles></Catalog>" |
        Set-Content -LiteralPath $store -Encoding UTF8
    Set-FixtureStage 'Launching the installed client against the independent server.'
    $app = Open-App
    $names = @('rwalpha','rwbeta')
    $controls = Get-FixtureControls $app.Window $names
    foreach ($username in $names) {
        Set-FixtureStage "Opening the $username graphical desktop."
        $controls.Items[$username].Select()
        $controls.Connect.Invoke()
        Set-FixtureStage "Waiting for the Windows sign-in dialog for $username."
        Submit-FixtureCredential $endpoint $username $password
        Set-FixtureStage "Waiting for authenticated display for $username."
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline -and !$ready) {
            Start-Sleep -Milliseconds 350
            & $wsl -d $distro -u root --exec /usr/bin/test -s "/home/$username/.remote-workspace-display"
            $ready = $LASTEXITCODE -eq 0
        }
        if (!$ready) { throw "No authenticated desktop appeared for $username." }
        Write-Host "Independent RDP server confirmed the authenticated graphical desktop for $username."
    }
    Select-FixtureTabs $app.Window $names
    $displays = foreach ($username in $names) {
        Run-Linux -Arguments @('/bin/cat',"/home/$username/.remote-workspace-display")
        $null = Run-Linux -Arguments @('/usr/bin/pgrep','-u',$username,'-x','xmessage')
    }
    if (@($displays | Select-Object -Unique).Count -ne 2) { throw 'The users must have independent graphical desktops.' }
    . (Join-Path $PSScriptRoot 'Test-NativeHost.ps1') -Exe $Exe -OnlyAssertions
    Assert-HostedMstscTabs $app.Window $names
    Set-FixtureStage 'Verified two simultaneous authenticated xrdp desktops hosted in independent mstsc tabs.'
} catch {
    Write-Host ('Independent desktop test failed: ' + $_.Exception.Message)
    if ($imported) {
        & $wsl -d $distro -u root --exec /usr/bin/tail -n 20 /var/log/xrdp.log /var/log/xrdp-sesman.log /tmp/rw-xrdp-console.log /tmp/rw-sesman-console.log
    }
    throw
} finally {
    Set-FixtureStage 'Closing fixture processes and removing temporary state.'
    if ($null -ne $app -and !$app.Process.HasExited) {
        $null = $app.Process.CloseMainWindow()
        if (!$app.Process.WaitForExit(3000)) { Stop-Process -Id $app.Process.Id -Force }
    }
    [IO.File]::WriteAllBytes($hosts, $originalHosts)
    if ($certificate) { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($certificate.Thumbprint)" }
    if ($imported) {
        & $wsl --terminate $distro
        & $wsl --unregister $distro
    }
    if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
}
