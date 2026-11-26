[CmdletBinding()]
param([Parameter(Mandatory)][string] $Exe, [switch] $OnlyAssertions)

# Assertions may also be dot-sourced after a test server has authenticated both users.
if (-not (Get-Command Find-Name -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Test-Rdp030.ps1') -Exe $Exe -OnlyHelpers
}
. (Join-Path $PSScriptRoot 'Test-RdpSessionControls.ps1')

if (-not ('HostedDesktopWindows' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class HostedDesktopWindows {
    private delegate bool Callback(IntPtr window, IntPtr data);
    [DllImport("user32")] private static extern bool EnumChildWindows(IntPtr parent, Callback callback, IntPtr data);
    [DllImport("user32")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
    [DllImport("user32", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int n);
    [DllImport("user32")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32")] private static extern bool GetClientRect(IntPtr window, out Rect bounds);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }

    public static int[] VisibleShells(IntPtr app) {
        var pids = new List<int>();
        EnumChildWindows(app, delegate(IntPtr window, IntPtr data) {
            if (!IsWindowVisible(window)) return true;
            var cls = new StringBuilder(96);
            GetClassName(window, cls, cls.Capacity);
            if (!String.Equals(cls.ToString(), "TscShellContainerClass", StringComparison.Ordinal)) return true;
            int pid;
            Rect rect;
            GetWindowThreadProcessId(window, out pid);
            if (!GetClientRect(window, out rect) || rect.Right - rect.Left < 100 || rect.Bottom - rect.Top < 100)
                return true;
            try {
                using (var p = Process.GetProcessById(pid)) {
                    if (String.Equals(p.ProcessName, "mstsc", StringComparison.OrdinalIgnoreCase))
                        pids.Add(pid);
                }
            } catch (ArgumentException) { }
            return true;
        }, IntPtr.Zero);
        return pids.ToArray();
    }
}
'@
}

function Get-NativeTabStrip($Window) {
    # Do not traverse a remote desktop's own UI Automation provider.
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    $queue = New-Object Collections.Queue
    $queue.Enqueue($Window)
    while ($queue.Count) {
        $child = $walker.GetFirstChild($queue.Dequeue())
        while ($null -ne $child) {
            if ($child.Current.AutomationId -eq 'SessionTabs') { return $child }
            if ($child.Current.NativeWindowHandle -eq 0) { $queue.Enqueue($child) }
            $child = $walker.GetNextSibling($child)
        }
    }
    throw 'Session tab strip was not found.'
}

function Get-TabNamed($Tabs, [string]$Name) {
    Find-Name $Tabs $Name -Type ([Windows.Automation.ControlType]::ListItem)
}

function Wait-ActiveNativeShell($Window, [int] $Expected = 0, [int] $Exclude = 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $owners = @([HostedDesktopWindows]::VisibleShells([IntPtr]$Window.Current.NativeWindowHandle))
        if ($owners.Count -eq 1 -and $owners[0] -ne $Exclude -and (!$Expected -or $owners[0] -eq $Expected)) { return $owners[0] }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected one visible, non-empty mstsc-owned TscShellContainerClass beneath the app HWND. Found $($owners.Count)."
}

function Assert-HostedMstscTabs($Window, [string[]]$Names) {
    if ($Names.Count -ne 2) { throw 'This verification requires two differentiated profiles.' }
    $tabs = Get-NativeTabStrip $Window
    $tabA = Get-TabNamed $tabs $Names[0]
    $tabB = Get-TabNamed $tabs $Names[1]
    $selA = $tabA.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    $selB = $tabB.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    $selA.Select()
    $ownerA = Wait-ActiveNativeShell $Window
    $selB.Select()
    $ownerB = Wait-ActiveNativeShell $Window -Exclude $ownerA
    if ($ownerA -eq $ownerB -or !$selB.Current.IsSelected) { throw 'The tabs did not switch between independent mstsc windows.' }
    foreach ($owner in @($ownerA,$ownerB)) {
        $mstsc = Get-CimInstance Win32_Process -Filter "ProcessId=$owner"
        if ($mstsc.ParentProcessId -ne $Window.Current.ProcessId -or
            $mstsc.ExecutablePath -ne (Join-Path $env:SystemRoot 'System32\mstsc.exe')) {
            throw 'The hosted HWND belongs to an unexpected process.'
        }
    }
    $selA.Select()
    if ((Wait-ActiveNativeShell $Window -Expected $ownerA) -ne $ownerA) { throw 'The first desktop did not survive switching.' }
    $selB.Select()
    if ((Wait-ActiveNativeShell $Window -Expected $ownerB) -ne $ownerB) { throw 'The second desktop did not survive switching.' }
    Invoke-ControlId $tabA 'CloseSessionTab'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $a = Find-Name $tabs $Names[0] -Optional -Type ([Windows.Automation.ControlType]::ListItem)
        if (!$a) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($a -or !$selB.Current.IsSelected -or (Wait-ActiveNativeShell $Window -Expected $ownerB) -ne $ownerB) {
        throw 'Closing the background tab changed the active desktop.'
    }
    Write-Host 'HOSTED_MSTSC_HWND=PASS two genuine child desktop windows, switched both ways, retained selected native client after background close.'
}

if ($OnlyAssertions) { return }
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Use a disposable hosted Windows runner for the launch test.'
}
$listeners = @()
$app = $null
$names = @('Local Native One','Local Native Two')
$childIds = @()
$backup = if (Test-Path -LiteralPath $store) { [IO.File]::ReadAllBytes($store) } else { $null }
try {
    $records = foreach ($name in $names) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $listeners += $listener
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        "<Profile><Id>$([guid]::NewGuid())</Id><Name>$name</Name><Host>127.0.0.1</Host><Port>$port</Port><Protocol>RDP</Protocol><PromptForCredentials>true</PromptForCredentials></Profile>"
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $store)
    "<Catalog><Revision>focused-native-qa</Revision><Folders/><Profiles>$records</Profiles></Catalog>" | Set-Content -LiteralPath $store -Encoding UTF8
    $app = Open-App
    $restore = Find-Name $app.Window 'Развернуть подключения' -Optional -Type ([Windows.Automation.ControlType]::Button)
    if ($restore) { $restore.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $restore = Find-Name $app.Window 'Развернуть свойства' -Optional -Type ([Windows.Automation.ControlType]::Button)
    if ($restore) { $restore.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $controls = Get-FixtureControls $app.Window $names
    foreach ($name in $names) {
        $controls.Items[$name].Select()
        $controls.Connect.Invoke()
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        do {
            $found = @(Get-CimInstance Win32_Process -Filter "Name='mstsc.exe' AND ParentProcessId=$($app.Process.Id)" | Where-Object {
                $_.ProcessId -notin $childIds -and $_.ExecutablePath -eq (Join-Path $env:SystemRoot 'System32\mstsc.exe')
            })
            if ($found.Count -eq 1) { break }
            Start-Sleep -Milliseconds 150
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($found.Count -ne 1) { throw "Expected one newly launched native client for $name." }
        if ($found[0].CommandLine -notmatch '"([^"]+\.rdp)"') { throw 'Native client did not receive its RDP settings file.' }
        $settings = [IO.File]::ReadAllText($Matches[1])
        $port = $listeners[$childIds.Count].LocalEndpoint.Port
        if ($settings -notmatch "(?m)^full address:s:127\.0\.0\.1:${port}\r?$" -or
            $settings -notmatch '(?m)^prompt for credentials:i:1\r?$' -or $settings -match '(?im)^password ') {
            throw 'Native client target, credential prompt or password-file handling does not match the test profile.'
        }
        $childIds += [int]$found[0].ProcessId
    }

    $tabs = Get-NativeTabStrip $app.Window
    $tabA = Get-TabNamed $tabs $names[0]
    $tabB = Get-TabNamed $tabs $names[1]
    $selB = $tabB.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    if (!$selB.Current.IsSelected) { throw 'Second tab was not selected.' }
    $visible = @([HostedDesktopWindows]::VisibleShells([IntPtr]$app.Window.Current.NativeWindowHandle))
    if ($visible.Count -gt 0) {
        Assert-HostedMstscTabs $app.Window $names
    } else {
        Invoke-ControlId $tabA 'CloseSessionTab'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            if (!(Find-Name $tabs $names[0] -Optional -Type ([Windows.Automation.ControlType]::ListItem))) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if ((Find-Name $tabs $names[0] -Optional -Type ([Windows.Automation.ControlType]::ListItem)) -or
            !$selB.Current.IsSelected -or !(Get-Process -Id $childIds[1] -ErrorAction SilentlyContinue)) {
            throw 'Closing the first pending connection affected the second client.'
        }
        Write-Host 'HOSTED_MSTSC_HWND=NOT_OBSERVED pre-login fixture; strict window verification requires a desktop.'
    }
    Write-Host 'NATIVE_MSTSC_LAUNCH=PASS two owned mstsc.exe processes, two tabs and independent background close.'
} finally {
    if ($app -and !$app.Process.HasExited) { Stop-App $app }
    foreach ($listener in $listeners) { $listener.Stop() }
    # Any unacknowledged synthetic credential prompts end with the disposable VM.
    if ($null -eq $backup) { Remove-Item -LiteralPath $store -ErrorAction SilentlyContinue }
    else { [IO.File]::WriteAllBytes($store, $backup) }
}
