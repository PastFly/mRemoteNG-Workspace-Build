[CmdletBinding()]
param([Parameter(Mandatory)][string] $Exe)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Security
$tree = [Windows.Automation.TreeScope]::Descendants
$nameProperty = [Windows.Automation.AutomationElement]::NameProperty
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CatalogTestWindows {
    private delegate bool Callback(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Callback callback, IntPtr param);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);

    public static IntPtr Find(int process, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, param) => {
            int pid;
            GetWindowThreadProcessId(window, out pid);
            if (pid != process || !IsWindowVisible(window)) return true;
            var value = new StringBuilder(256);
            GetWindowText(window, value, value.Capacity);
            if (!String.Equals(value.ToString(), title, StringComparison.Ordinal)) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$store = Join-Path $env:LOCALAPPDATA 'Remote Workspace\catalog.xml'

function Find-Name {
    param($Scope, [string] $Name, [switch] $Optional, [Windows.Automation.ControlType] $Type)
    $condition = [Windows.Automation.PropertyCondition]::new($nameProperty, $Name)
    if ($Type) {
        $typed = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)
        $condition = [Windows.Automation.AndCondition]::new([Windows.Automation.Condition[]]@($condition, $typed))
    }
    for ($attempt = 0; $attempt -lt $(if ($Optional) { 1 } else { 60 }); $attempt++) {
        $element = $Scope.FindFirst($tree, $condition)
        if ($null -ne $element) { return $element }
        if (!$Optional) { Start-Sleep -Milliseconds 200 }
    }
    if (!$Optional) { throw "Missing UI element: $Name" }
}

function Invoke-Control {
    param($Scope, [string] $Name)
    (Find-Name $Scope $Name -Type ([Windows.Automation.ControlType]::Button)).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Set-Control {
    param($Scope, [string] $Name, [string] $Value)
    (Find-Name $Scope $Name -Type ([Windows.Automation.ControlType]::Edit)).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
}

function Find-Dialog {
    param($Process, [string] $Title)
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $handle = [CatalogTestWindows]::Find($Process.Id, $Title)
        if ($handle -ne [IntPtr]::Zero) { return [Windows.Automation.AutomationElement]::FromHandle($handle) }
        if ($Process.HasExited) { throw "App exited with code $($Process.ExitCode) while waiting for $Title." }
        Start-Sleep -Milliseconds 200
    }
    throw "Dialog did not appear: $Title"
}

function Open-App {
    $process = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
    try {
        $window = Find-Dialog $process 'Remote Workspace'
        [pscustomobject]@{ Process = $process; Window = $window }
    } catch {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
        throw
    }
}

function Stop-App {
    param($App)
    if (!$App.Process.HasExited -and (!$App.Process.CloseMainWindow() -or !$App.Process.WaitForExit(10000))) {
        Stop-Process -Id $App.Process.Id -Force
        throw 'The installed app did not close cleanly.'
    }
}


function Select-Item {
    param($Window, [string] $Name, [Windows.Automation.ControlType] $Type)
    $item = Find-Name $Window $Name -Type $Type
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $item
}

function Wait-Tcp {
    param($Listener, [string] $Name)
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        if ($Listener.Pending()) { return $Listener.AcceptTcpClient() }
        Start-Sleep -Milliseconds 200
    }
    throw "$Name did not initiate its own RDP transport."
}

$one = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
$two = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
$one.Start()
$two.Start()
$first = $null
$second = $null
$app = $null
try {
    New-Item -Path (Split-Path -Parent $store) -ItemType Directory -Force | Out-Null
    $credential = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::Unicode.GetBytes('Ephemeral-QA-Password-7w!'), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser))
    $portOne = ([Net.IPEndPoint] $one.LocalEndpoint).Port
    $portTwo = ([Net.IPEndPoint] $two.LocalEndpoint).Port
    @"
<Catalog>
  <Revision>fixture</Revision>
  <Folders>
    <Folder><Id>qa-source</Id><ParentId></ParentId><Name>QA Source</Name><SmartCardPolicy>true</SmartCardPolicy><SmartCardPolicySet>true</SmartCardPolicySet></Folder>
    <Folder><Id>qa-target</Id><ParentId></ParentId><Name>QA Target</Name></Folder>
  </Folders>
  <Profiles>
    <Profile><Id>qa-one</Id><FolderId>qa-source</FolderId><Name>QA RDP One</Name><Host>127.0.0.1</Host><Protocol>RDP</Protocol><Port>$portOne</Port><User>Fixture</User><ProtectedPassword>$credential</ProtectedPassword><InheritSmartCards>true</InheritSmartCards></Profile>
    <Profile><Id>qa-two</Id><FolderId>qa-source</FolderId><Name>QA RDP Two</Name><Host>127.0.0.1</Host><Protocol>RDP</Protocol><Port>$portTwo</Port><User>Fixture</User><ProtectedPassword>$credential</ProtectedPassword></Profile>
  </Profiles>
</Catalog>
"@ | Set-Content -LiteralPath $store -Encoding UTF8
    $app = Open-App
    $window = $app.Window
    Write-Host 'Application with the RDP ActiveX dependencies launched.'
    $treeItem = [Windows.Automation.ControlType]::TreeItem
    $tabItem = [Windows.Automation.ControlType]::ListItem
    $branch = Find-Name $window 'QA Source' -Type $treeItem
    $branch.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $null = Select-Item $window 'QA RDP One' $treeItem
    $null = Find-Name $window 'Разрешено · из папки'
    Invoke-Control $window 'Подключиться'
    $first = Wait-Tcp $one 'First RDP tab'
    $null = Select-Item $window 'QA RDP Two' $treeItem
    Invoke-Control $window 'Подключиться'
    $second = Wait-Tcp $two 'Second RDP tab'
    $null = Select-Item $window 'QA RDP One' $tabItem
    $null = Select-Item $window 'QA RDP Two' $tabItem
    Write-Host 'Two independent native RDP connection attempts opened sockets, and both tabs were selectable.'
    Invoke-Control $window 'Скрыть свойства'
    $null = Find-Name $window 'Показать свойства' -Type ([Windows.Automation.ControlType]::Button)
    Invoke-Control $window 'Показать свойства'
    Invoke-Control $window 'Закрыть вкладку'
    Invoke-Control $window 'Закрыть вкладку'
    $null = Find-Name $window 'Откройте подключение'
    Set-Control $window 'Поиск подключений' 'QA RDP Two'
    $null = Find-Name $window 'Подключения: 1 из 2'
    Set-Control $window 'Поиск подключений' ''
    $null = Find-Name $window 'Подключения: 2 из 2'
    Stop-App $app
    Write-Host 'Windows checks passed: RDP transports and tab switching, smart-card inheritance, collapsible inspector and tree search.'
} catch {
    Write-Host "Test failure: $_"
    if ($null -ne $app -and !$app.Process.HasExited) {
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)
        $app.Window.FindAll($tree, $condition) | ForEach-Object { $_.Current.Name } | Out-Host
    }
    throw
} finally {
    if ($null -ne $first) { $first.Dispose() }
    if ($null -ne $second) { $second.Dispose() }
    $one.Stop()
    $two.Stop()
    if ($null -ne $app -and !$app.Process.HasExited) { Stop-Process -Id $app.Process.Id -Force -ErrorAction SilentlyContinue }
}
