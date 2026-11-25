[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installPath = Join-Path $env:RUNNER_TEMP 'mremoteng-msi-smoke'
$exe = Join-Path $installPath 'mRemoteNG.exe'
$source = Join-Path $env:RUNNER_TEMP 'mremoteng-workspace-source'
$profile = Join-Path $env:APPDATA 'mRemoteNG'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$legacyLayout = Join-Path $profile 'pnlLayout.xml'
Set-Content -LiteralPath $legacyLayout -Encoding ascii -Value '<legacy-layout />'
$legacyHash = (Get-FileHash -LiteralPath $legacyLayout).Hash

# The screenshot uses the upstream test fixture and no network sessions.
$fixture = [xml](Get-Content -LiteralPath (Join-Path $source 'mRemoteNGTests\Resources\confCons_v2_6.xml') -Raw)
$index = 0
foreach ($node in $fixture.SelectNodes('//Node')) {
    $index++
    $node.SetAttribute('Name', ('Demo group {0}' -f $index))
    if ($node.GetAttribute('Type') -eq 'Connection') {
        $node.SetAttribute('Name', ('demo-rdp-{0:00}' -f $index))
        $node.SetAttribute('Hostname', '192.0.2.10')
        $node.SetAttribute('Connected', 'False')
    }
}
$fixture.Save((Join-Path $profile 'confCons.xml'))

$configPath = "$exe.config"
$config = [xml](Get-Content -LiteralPath $configPath -Raw)
$preferences = [ordered]@{
    DoUpgrade = 'False'; CheckForUpdatesAsked = 'True'; CheckForUpdatesOnStartup = 'False'
    UseSQLServer = 'False'; OpenConsFromLastSession = 'False'; SingleClickOnConnectionOpensIt = 'False'
    StartupComponentsCheck = 'False'; ThemeName = 'darcula'; ThemingActive = 'True'
    MainFormLocation = '0, 0'; MainFormSize = '1000, 700'; CreateEmptyPanelOnStartUp = 'True'
    OverrideUICulture = 'ru'
}
foreach ($name in $preferences.Keys) {
    $node = $config.SelectSingleNode("/configuration/userSettings/mRemoteNG.Settings/setting[@name='$name']/value")
    if ($null -eq $node) { throw "UI test setting not found: $name" }
    $node.InnerText = $preferences[$name]
}
$config.Save($configPath)

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WorkspaceWindowCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr target, uint flags);
}
'@

$visual = Join-Path $PSScriptRoot 'visual'
New-Item -ItemType Directory -Path $visual -Force | Out-Null
$process = Start-Process -FilePath $exe -WorkingDirectory $installPath -PassThru
try {
    $rect = New-Object 'WorkspaceWindowCapture+Rect'
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw "mRemoteNG closed during startup with exit code $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.MainWindowTitle -like 'mRemoteNG*' -and
            [WorkspaceWindowCapture]::GetWindowRect($process.MainWindowHandle, [ref] $rect) -and
            ($rect.Right - $rect.Left) -ge 900) { break }
    }
    if (($rect.Right - $rect.Left) -lt 900) { throw 'Did not find the main mRemoteNG window.' }

    Start-Sleep -Seconds 2
    $bitmap = New-Object Drawing.Bitmap (($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top), [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $g.GetHdc()
        try {
            $captured = [WorkspaceWindowCapture]::PrintWindow($process.MainWindowHandle, $dc, 2)
        } finally {
            $g.ReleaseHdc($dc)
        }
        if (!$captured) { throw 'Could not capture the mRemoteNG window.' }
        $bitmap.Save((Join-Path $visual 'mRemoteNG-Workspace-Windows.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $g.Dispose()
        $bitmap.Dispose()
    }

    if (!$process.CloseMainWindow() -or !$process.WaitForExit(15000)) {
        throw 'mRemoteNG did not close after the layout check.'
    }
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
}

if ((Get-FileHash -LiteralPath $legacyLayout).Hash -ne $legacyHash) { throw 'Old dock layout was modified.' }
$layout = [xml](Get-Content -LiteralPath (Join-Path $profile 'pnlLayout.Workspace.xml') -Raw)
foreach ($expected in @(@('ConnectionTreeWindow', 'DockLeft'), @('ConfigWindow', 'DockRight'))) {
    $component = $layout.SelectSingleNode("/DockPanel/Contents/Content[contains(@PersistString, '$($expected[0])')]")
    if ($null -eq $component -or $component.GetAttribute('IsHidden') -ne 'False') {
        throw "Missing workspace panel: $($expected[0])"
    }
    $id = $component.GetAttribute('ID')
    $pane = $layout.SelectSingleNode("/DockPanel/Panes/Pane[@DockState='$($expected[1])']/Contents/Content[@RefID='$id']")
    if ($null -eq $pane) { throw "Workspace panel $($expected[0]) is not $($expected[1])." }
}
Write-Host 'Workspace UI check passed. Connections are docked left, properties right, and the previous layout was preserved.'
