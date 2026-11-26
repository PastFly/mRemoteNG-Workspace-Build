[CmdletBinding()]
param([Parameter(Mandatory)][string] $Exe)

Write-Host 'Loading installed-app UI automation helpers.'
. (Join-Path $PSScriptRoot 'Test-Rdp030.ps1') -Exe $Exe -OnlyHelpers
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'The RDP fixture is limited to disposable hosted Windows runners.'
}
Write-Host 'Checking firewall state and test listener configuration.'
if (Get-NetFirewallProfile | Where-Object { !($_.Enabled -eq 'True') }) {
    throw 'The loopback test requires active Windows Firewall profiles.'
}

$hostname = 'workspace-rdp-fixture.test'
$port = 3389
$accountNames = @('RW030Alpha', 'RW030Beta')
$firewallName = 'Remote Workspace test - block external RDP'
$terminalKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$listenerKey = Join-Path $terminalKey 'WinStations\RDP-Tcp'
$originalDeny = (Get-ItemProperty -LiteralPath $terminalKey -Name fDenyTSConnections).fDenyTSConnections
$originalListener = Get-ItemProperty -LiteralPath $listenerKey
$originalCertificate = $originalListener.PSObject.Properties['SSLCertificateSHA1Hash']
$hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
$originalHosts = [IO.File]::ReadAllBytes($hosts)
$certificate = $null
$rdpSettings = $null
$enabledForTest = $false
$testStart = Get-Date
$app = $null
$createdUsers = [System.Collections.Generic.List[string]]::new()

try {
    Write-Host 'Applying external-address block rules before configuring the test endpoint.'
    $externalAddresses = @(Get-NetIPAddress -AddressState Preferred | ForEach-Object {
        $value = [Net.IPAddress]::Parse(($_.IPAddress -split '%')[0])
        if (![Net.IPAddress]::IsLoopback($value) -and $value -ne [Net.IPAddress]::Any -and
            $value -ne [Net.IPAddress]::IPv6Any) { $value.ToString() }
    } | Select-Object -Unique)
    if ($externalAddresses.Count -eq 0) { throw 'Failed to enumerate non-loopback addresses.' }

    $rule = @{
        DisplayName = $firewallName
        Direction = 'Inbound'
        Protocol = 'TCP'
        LocalPort = $port
        Action = 'Block'
        Profile = 'Any'
        LocalAddress = $externalAddresses
    }
    New-NetFirewallRule @rule | Out-Null
    $rule.Protocol = 'UDP'
    New-NetFirewallRule @rule | Out-Null
    Add-Content -LiteralPath $hosts -Value ([Environment]::NewLine + "127.0.0.1 $hostname") -Encoding ASCII
    if (!([Net.Dns]::GetHostAddresses($hostname) | Where-Object { $_.ToString() -eq '127.0.0.1' })) {
        throw 'The fixture name did not resolve to loopback.'
    }

    Write-Host 'Creating the short-lived non-CA TLS certificate for the fixture.'
    $certOptions = @{
        DnsName = $hostname
        CertStoreLocation = 'Cert:\LocalMachine\My'
        Provider = 'Microsoft RSA SChannel Cryptographic Provider'
        KeySpec = 'KeyExchange'
        KeyLength = 2048
        HashAlgorithm = 'SHA256'
        Type = 'SSLServerAuthentication'
        NotAfter = (Get-Date).AddDays(2)
    }
    $certificate = New-SelfSignedCertificate @certOptions
    $constraints = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }
    if ($null -ne $constraints -and $constraints.CertificateAuthority) { throw 'Expected a non-CA TLS certificate.' }
    $keyId = $certificate.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
    $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $keyId
    & icacls.exe $keyPath /grant '*S-1-5-20:(R)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant the local RDP service access to the test key.' }
    $publicPath = Join-Path $env:RUNNER_TEMP 'rw030-loopback-public.cer'
    Export-Certificate -Cert $certificate -FilePath $publicPath | Out-Null
    # CurrentUser's root store can show an interactive consent dialog even on an
    # elevated runner. Only this end-entity certificate is trusted during the test.
    Write-Host 'Installing the fixture certificate into the disposable machine trust store.'
    Import-Certificate -FilePath $publicPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    $thumbBytes = [byte[]] ($certificate.Thumbprint -split '([a-fA-F0-9]{2})' | Where-Object { $_ } |
        ForEach-Object { [Convert]::ToByte($_, 16) })
    New-ItemProperty -LiteralPath $listenerKey -Name SSLCertificateSHA1Hash -Value $thumbBytes -PropertyType Binary -Force | Out-Null

    Write-Host 'Creating two non-admin local fixture accounts.'
    $password = "Qa!$(New-Guid)7"
    Write-Host "::add-mask::$password"
    $secure = ConvertTo-SecureString -AsPlainText -Force $password
    $group = Get-LocalGroup -SID 'S-1-5-32-555'
    foreach ($user in $accountNames) {
        $localAccount = New-LocalUser -Name $user -Password $secure -Description 'Disposable loopback RDP fixture'
        $createdUsers.Add($user)
        Add-LocalGroupMember -Group $group.Name -Member $localAccount
    }

    Write-Host 'Applying Remote Desktop Services configuration without a firewall exception.'
    $rdpSettings = Get-CimInstance -Namespace root/CIMV2/TerminalServices -ClassName Win32_TerminalServiceSetting -OperationTimeoutSec 12
    $answer = Invoke-CimMethod -InputObject $rdpSettings -MethodName SetAllowTSConnections -Arguments @{
        AllowTSConnections = [uint32]1; ModifyFirewallException = [uint32]0
    } -OperationTimeoutSec 12
    if ($answer.ReturnValue -ne 0) { throw "SetAllowTSConnections returned $($answer.ReturnValue)." }
    $enabledForTest = $true
    $service = Get-Service TermService
    if ($service.Status -eq 'Stopped') { $service.Start() }
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    Write-Host 'TermService is running. Waiting for a response at the loopback address.'
    $portReady = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(18)
    while (!$portReady -and [DateTime]::UtcNow -lt $deadline) {
        $tcp = [Net.Sockets.TcpClient]::new()
        try {
            $connection = $tcp.ConnectAsync([Net.IPAddress]::Loopback, $port)
            if ($connection.Wait(600) -and $tcp.Connected) { $portReady = $true }
        } catch { } finally { $tcp.Dispose() }
        if (!$portReady) { Start-Sleep -Milliseconds 250 }
    }
    if (!$portReady) { throw 'The Windows RDP loopback listener did not become reachable in 18 seconds.' }
    Write-Host 'The isolated Windows RDP listener and its test certificate are ready.'

    $credential = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::Unicode.GetBytes($password), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
    Write-Host "::add-mask::$credential"
    @"
<Catalog>
  <Revision>loopback-fixture</Revision>
  <Folders/>
  <Profiles>
    <Profile><Id>rdp-live-a</Id><FolderId></FolderId><Name>RDP Live Alpha</Name><Host>$hostname</Host><Protocol>RDP</Protocol><Port>$port</Port><User>$($accountNames[0])</User><Domain>$env:COMPUTERNAME</Domain><ProtectedPassword>$credential</ProtectedPassword></Profile>
    <Profile><Id>rdp-live-b</Id><FolderId></FolderId><Name>RDP Live Beta</Name><Host>$hostname</Host><Protocol>RDP</Protocol><Port>$port</Port><User>$($accountNames[1])</User><Domain>$env:COMPUTERNAME</Domain><ProtectedPassword>$credential</ProtectedPassword></Profile>
  </Profiles>
</Catalog>
"@ | Set-Content -LiteralPath $store -Encoding UTF8

    Write-Host 'Launching Remote Workspace for the authenticated test.'
    $app = Open-App
    $window = $app.Window
    foreach ($name in @('RDP Live Alpha', 'RDP Live Beta')) {
        Write-Host "Opening the $name tab."
        $item = Find-Name $window $name -Type ([Windows.Automation.ControlType]::TreeItem)
        $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Invoke-Control $window 'Подключиться'
        $loggedIn = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(35)
        while (!$loggedIn -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 350
            $loggedIn = $null -ne (Find-Name $window "Сеанс активен · $hostname · $port" -Optional)
        }
        if (!$loggedIn) {
            $id = [Windows.Automation.PropertyCondition]::new(
                [Windows.Automation.AutomationElement]::AutomationIdProperty, 'RdpStatus')
            $status = $window.FindAll($tree, $id) | ForEach-Object { $_.Current.Name }
            throw "$name did not complete Windows logon. RDP status: $($status -join ' | ')"
        }
        Write-Host "$name completed Windows logon."
    }
    $null = Find-Name $window 'RDP Live Alpha' -Type ([Windows.Automation.ControlType]::ListItem)
    $null = Find-Name $window 'RDP Live Beta' -Type ([Windows.Automation.ControlType]::ListItem)
    $sessions = (& quser.exe) -join [Environment]::NewLine
    if ($sessions -notmatch '(?im)^\s*>?\s*rw030alpha\s+.*\bActive\b' -or
        $sessions -notmatch '(?im)^\s*>?\s*rw030beta\s+.*\bActive\b') {
        throw 'Windows did not report two simultaneous active fixture sessions.'
    }
    Write-Host 'Verified two simultaneous authenticated RDP sessions on the isolated Windows Server.'
} catch {
    Write-Host ('Fixture stage failed: ' + $_.Exception.Message)
    foreach ($channel in @('Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
        'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational',
        'Microsoft-Windows-TerminalServices-RDPClient/Operational')) {
        $events = @(Get-WinEvent -FilterHashtable @{LogName=$channel; StartTime=$testStart} -MaxEvents 10 -ErrorAction SilentlyContinue)
        if ($events.Count) { Write-Host ("$channel event IDs: " + ($events.Id -join ', ')) }
    }
    throw
} finally {
    Write-Host 'Cleaning up the scoped test accounts, certificate and listener.'
    if ($null -ne $app -and !$app.Process.HasExited) {
        $null = $app.Process.CloseMainWindow()
        if (!$app.Process.WaitForExit(5000)) { Stop-Process -Id $app.Process.Id -Force }
    }
    if ($enabledForTest -and $originalDeny -eq 1) {
        $null = Invoke-CimMethod -InputObject $rdpSettings -MethodName SetAllowTSConnections -Arguments @{
            AllowTSConnections = [uint32]0; ModifyFirewallException = [uint32]0
        } -OperationTimeoutSec 12 -ErrorAction SilentlyContinue
    }
    Set-ItemProperty -LiteralPath $terminalKey -Name fDenyTSConnections -Value $originalDeny -ErrorAction SilentlyContinue
    if ($originalCertificate) {
        Set-ItemProperty -LiteralPath $listenerKey -Name SSLCertificateSHA1Hash -Value $originalCertificate.Value -ErrorAction SilentlyContinue
    } else {
        Remove-ItemProperty -LiteralPath $listenerKey -Name SSLCertificateSHA1Hash -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllBytes($hosts, $originalHosts)
    Remove-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue
    if ($certificate) {
        Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue
    }
    foreach ($user in $createdUsers) { Remove-LocalUser -Name $user -ErrorAction SilentlyContinue }
}
