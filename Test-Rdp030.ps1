[CmdletBinding()]
param([Parameter(Mandatory)][string] $Exe, [switch] $OnlyHelpers)
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

    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scancode, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern uint GetPixel(IntPtr dc, int x, int y);
    public static uint[] RowPixels(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        try {
            uint[] pixels = new uint[96];
            for (int i = 0; i < pixels.Length; i++) {
                pixels[i] = GetPixel(dc, x + 2 * (i % 16), y + 2 * (i / 16));
                if (pixels[i] == 0xffffffff) throw new InvalidOperationException("Could not sample folder row.");
            }
            return pixels;
        } finally { ReleaseDC(IntPtr.Zero, dc); }
    }
    public static int Brightness(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        try {
            uint color = GetPixel(dc, x, y);
            if (color == 0xffffffff) throw new InvalidOperationException("Could not sample visible desktop.");
            return (int)((color & 255) + ((color >> 8) & 255) + ((color >> 16) & 255));
        } finally { ReleaseDC(IntPtr.Zero, dc); }
    }

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

function Find-ControlId {
    param($Window, [string] $Id)
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $control = $Window.FindFirst($tree, $condition)
    if ($null -eq $control) { throw "Missing UI element with AutomationId $Id" }
    return $control
}

function Invoke-ControlId {
    param($Window, [string] $Id)
    (Find-ControlId $Window $Id).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Wait-InspectorState {
    param($Window, [int] $Visible, [string] $Stage)
    $expected = if ($Visible) { 'Скрыть свойства' } else { 'Показать свойства' }
    $button = Find-ControlId $Window 'InspectorToggle'
    $key = 'HKEY_CURRENT_USER\Software\Remote Workspace\Appearance'
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $label = $button.Current.Name
        $stored = [Microsoft.Win32.Registry]::GetValue($key, 'InspectorVisible', '<missing>')
        if ($label -eq $expected -and [string]$stored -eq [string]$Visible) {
            Write-Host "$Stage inspector state confirmed: label '$label', HKCU InspectorVisible=$stored."
            return
        }
        Start-Sleep -Milliseconds 120
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Stage inspector mismatch: expected '$expected', HKCU=$Visible. Actual '$label', HKCU=$stored."
}

function Maximize-Window {
    param($Window)
    [void] [CatalogTestWindows]::SetForegroundWindow([IntPtr]$Window.Current.NativeWindowHandle)
    $Window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState(
        [Windows.Automation.WindowVisualState]::Maximized)
    Start-Sleep -Milliseconds 350
}

function Resize-Panel {
    param($Window, [string] $Id, [int] $Delta)
    $splitter = Find-ControlId $Window $Id
    $bounds = $splitter.Current.BoundingRectangle
    $x = [int]($bounds.X + $bounds.Width / 2)
    $y = [int]($bounds.Top + $bounds.Height / 3)
    [void] [CatalogTestWindows]::SetCursorPos($x, $y)
    [CatalogTestWindows]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    try {
        foreach ($step in 1..6) {
            [void] [CatalogTestWindows]::SetCursorPos(($x + $Delta * $step / 6), $y)
            Start-Sleep -Milliseconds 60
        }
    } finally {
        [CatalogTestWindows]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 200
    $position = $splitter.Current.BoundingRectangle.X
    if (($position - $bounds.X) * [Math]::Sign($Delta) -lt 12) {
        throw "$Id did not move with the pointer ($($bounds.X) to $position)."
    }
    return $position
}

function Get-StageBrightness {
    param($Window)
    $bounds = (Find-ControlId $Window 'TreeSplitter').Current.BoundingRectangle
    return [CatalogTestWindows]::Brightness(($bounds.Right + 20), ($bounds.Top + 90))
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

function Move-TreeItem {
    param($Window, $Source, $Target, [switch]$Cancel)
    [void] [CatalogTestWindows]::SetForegroundWindow([IntPtr] $Window.Current.NativeWindowHandle)
    $from = $Source.Current.BoundingRectangle
    $to = $Target.Current.BoundingRectangle
    $x1 = [int] ($from.X + 30)
    $y1 = [int] ($from.Y + ($from.Height / 2))
    $x2 = [int] ($to.X + 30)
    $y2 = [int] ($to.Y + ($to.Height / 2))
    [void] [CatalogTestWindows]::SetCursorPos($x1, $y1)
    Start-Sleep -Milliseconds 180
    # Sample across the folder label, away from the mouse cursor and drag icon.
    $patchX = $x2 + 27
    $patchY = $y2 - 5
    $before = [CatalogTestWindows]::RowPixels($patchX, $patchY)
    [CatalogTestWindows]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    try {
        for ($step = 1; $step -le 8; $step++) {
            [void] [CatalogTestWindows]::SetCursorPos($x1 + (($x2 - $x1) * $step / 8), $y1 + (($y2 - $y1) * $step / 8))
            Start-Sleep -Milliseconds 65
        }
        $status = Find-ControlId $Window 'Status'
        $feedback = $status.Current.Name
        if ($feedback -notlike '*QA RDP One*QA Target*') {
            throw "Drag destination hint missing before drop: $feedback"
        }
        $after = [CatalogTestWindows]::RowPixels($patchX, $patchY)
        $changed = 0
        for ($index = 0; $index -lt $before.Length; $index++) {
            if ($before[$index] -ne $after[$index]) { $changed++ }
        }
        if ($changed -lt 8) { throw "The destination row did not repaint during drag ($changed changed pixels)." }
        Write-Host "Destination row repainted during drag ($changed of $($before.Length) sampled pixels changed)."
        if ($Cancel) {
            [CatalogTestWindows]::keybd_event(27, 0, 0, [UIntPtr]::Zero)
            [CatalogTestWindows]::keybd_event(27, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 100
        }
    } finally {
        [CatalogTestWindows]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    }
}

function Open-TreeContextMenu {
    param($Window, $Item, $ProcessId)
    [void] [CatalogTestWindows]::SetForegroundWindow([IntPtr] $Window.Current.NativeWindowHandle)
    $bounds = $Item.Current.BoundingRectangle
    [void] [CatalogTestWindows]::SetCursorPos($bounds.X + 30, $bounds.Y + ($bounds.Height / 2))
    Start-Sleep -Milliseconds 150
    [CatalogTestWindows]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero)
    [CatalogTestWindows]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero)
    $byName = [Windows.Automation.PropertyCondition]::new($nameProperty, 'Дублировать')
    $byId = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
    $byType = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::MenuItem)
    $filter = [Windows.Automation.AndCondition]::new([Windows.Automation.Condition[]] @($byName, $byId, $byType))
    for ($attempt = 0; $attempt -lt 24; $attempt++) {
        $menu = [Windows.Automation.AutomationElement]::RootElement.FindFirst($tree, $filter)
        if ($null -ne $menu) {
            $menu.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            return
        }
        Start-Sleep -Milliseconds 180
    }
    throw 'The profile context menu did not open on right-click.'
}

if ($OnlyHelpers) { return }

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
    <Folder><Id>qa-nested</Id><ParentId>qa-source</ParentId><Name>QA Nested</Name></Folder>
    <Folder><Id>qa-target</Id><ParentId></ParentId><Name>QA Target</Name></Folder>
  </Folders>
  <Profiles>
    <Profile><Id>qa-one</Id><FolderId>qa-source</FolderId><Name>QA RDP One</Name><Host>127.0.0.1</Host><Protocol>RDP</Protocol><Port>$portOne</Port><User>Fixture</User><ProtectedPassword>$credential</ProtectedPassword><InheritSmartCards>true</InheritSmartCards></Profile>
    <Profile><Id>qa-two</Id><FolderId>qa-nested</FolderId><Name>QA RDP Two</Name><Host>127.0.0.1</Host><Protocol>RDP</Protocol><Port>$portTwo</Port><User>Fixture</User><ProtectedPassword>$credential</ProtectedPassword></Profile>
  </Profiles>
</Catalog>
"@ | Set-Content -LiteralPath $store -Encoding UTF8
    $app = Open-App
    $window = $app.Window
    Write-Host 'Application with the RDP ActiveX dependencies launched.'
    $treeItem = [Windows.Automation.ControlType]::TreeItem
    $tabItem = [Windows.Automation.ControlType]::ListItem
    Maximize-Window $window
    Invoke-ControlId $window 'ExpandAllButton'
    $null = Find-Name $window 'QA RDP Two' -Type $treeItem
    Invoke-ControlId $window 'CollapseAllButton'
    $branch = Find-Name $window 'QA Source' -Type $treeItem
    $expand = $branch.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($expand.Current.ExpandCollapseState -ne [Windows.Automation.ExpandCollapseState]::Collapsed) {
        throw 'Collapse all left a folder open.'
    }
    $expand.Expand()
    $nested = Find-Name $window 'QA Nested' -Type $treeItem
    if ($nested.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
            [Windows.Automation.ExpandCollapseState]::Collapsed) { throw 'Collapse all left a nested folder open.' }
    Invoke-ControlId $window 'ExpandAllButton'
    $null = Find-Name $window 'QA RDP Two' -Type $treeItem
    Write-Host 'Expand all and collapse all changed both levels of the tree.'

    $light = Get-StageBrightness $window
    Invoke-ControlId $window 'ThemeToggle'
    Start-Sleep -Milliseconds 250
    $dark = Get-StageBrightness $window
    if ($light - $dark -lt 180) { throw "Dark theme did not repaint the session workspace ($light to $dark)." }
    $leftPosition = Resize-Panel $window 'TreeSplitter' -26
    $rightPosition = Resize-Panel $window 'InspectorSplitter' 26
    Write-Host 'Dark theme repainted the workspace and both side panels resized via their splitters.'
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
    $sourceBranch = Find-Name $window 'QA Source' -Type $treeItem
    $sourceBranch.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $source = Find-Name $window 'QA RDP One' -Type $treeItem
    $destination = Find-Name $window 'QA Target' -Type $treeItem
    Move-TreeItem $window $source $destination -Cancel
    $document = [xml] (Get-Content -LiteralPath $store -Raw)
    if ($document.Catalog.Profiles.SelectSingleNode("Profile[Id='qa-one']").FolderId -ne 'qa-source' -or
        (Find-ControlId $window 'Status').Current.Name -like '*QA RDP One*QA Target*') {
        throw 'Cancelling a drag changed the folder or left the destination hint visible.'
    }
    Move-TreeItem $window $source $destination
    $deadline = [DateTime]::UtcNow.AddSeconds(7)
    do {
        Start-Sleep -Milliseconds 250
        $document = [xml] (Get-Content -LiteralPath $store -Raw)
        $moved = $document.Catalog.Profiles.SelectSingleNode("Profile[Id='qa-one']")
    } until ($moved.FolderId -eq 'qa-target' -or [DateTime]::UtcNow -gt $deadline)
    if ($moved.FolderId -ne 'qa-target') { throw 'Mouse drag did not persist the destination folder.' }
    $source = Find-Name $window 'QA RDP One' -Type $treeItem
    Open-TreeContextMenu $window $source $app.Process.Id
    $null = Find-Name $window 'QA RDP One (копия)' -Type $treeItem
    Write-Host 'Dragging persisted the new folder, and right-click duplicate created a second profile.'
    Invoke-Control $window 'Скрыть свойства'
    Wait-InspectorState $window 0 'Before closing'
    Stop-App $app
    $app = Open-App
    $window = $app.Window
    Maximize-Window $window
    Wait-InspectorState $window 0 'After restarting'
    if ([Math]::Abs((Get-StageBrightness $window) - $dark) -gt 30) { throw 'The dark theme was lost on restart.' }
    Invoke-Control $window 'Показать свойства'
    Wait-InspectorState $window 1 'After restoring'
    Start-Sleep -Milliseconds 200
    if ([Math]::Abs((Find-ControlId $window 'TreeSplitter').Current.BoundingRectangle.X - $leftPosition) -gt 4 -or
        [Math]::Abs((Find-ControlId $window 'InspectorSplitter').Current.BoundingRectangle.X - $rightPosition) -gt 4) {
        throw 'The resized side panels did not restore their saved widths after restart.'
    }
    Invoke-ControlId $window 'ThemeToggle'
    Start-Sleep -Milliseconds 200
    if ([Math]::Abs((Get-StageBrightness $window) - $light) -gt 30) { throw 'Switching back to light did not repaint the workspace.' }
    Stop-App $app
    Write-Host 'Windows UI checks passed: theme switch and restart, splitter resizing and restoration, drag destination feedback, Escape and completed drop.'
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
