[CmdletBinding()]
param([Parameter(Mandatory)][string] $Exe)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Data
$tree = [Windows.Automation.TreeScope]::Descendants
$nameProperty = [Windows.Automation.AutomationElement]::NameProperty
$desktop = [Windows.Automation.AutomationElement]::RootElement
$store = Join-Path $env:LOCALAPPDATA 'Remote Workspace\catalog.xml'

function Find-Name {
    param($Scope, [string] $Name, [switch] $Optional)
    $condition = [Windows.Automation.PropertyCondition]::new($nameProperty, $Name)
    for ($attempt = 0; $attempt -lt $(if ($Optional) { 1 } else { 60 }); $attempt++) {
        $element = $Scope.FindFirst($tree, $condition)
        if ($null -ne $element) { return $element }
        if (!$Optional) { Start-Sleep -Milliseconds 200 }
    }
    if (!$Optional) { throw "Missing UI element: $Name" }
}

function Invoke-Control {
    param($Scope, [string] $Name)
    (Find-Name $Scope $Name).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Set-Control {
    param($Scope, [string] $Name, [string] $Value)
    (Find-Name $Scope $Name).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
}

function Find-Dialog {
    param($Process, [string] $Title)
    $a = [Windows.Automation.PropertyCondition]::new($nameProperty, $Title)
    $b = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $Process.Id)
    $condition = [Windows.Automation.AndCondition]::new($a, $b)
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $found = $desktop.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
        if ($null -ne $found) { return $found }
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

function Read-CatalogDocument {
    param([string] $Marker)
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        if (Test-Path -LiteralPath $store) {
            $text = Get-Content -LiteralPath $store -Raw
            if ($text -match [regex]::Escape($Marker)) { return [xml] $text }
        }
        Start-Sleep -Milliseconds 250
    } until ([DateTime]::UtcNow -ge $deadline)
    throw "The saved catalog did not contain $Marker."
}

function Initialize-SqlFixture {
    $instanceName = 'RemoteWorkspaceFixture'
    $tool = Get-Command 'SqlLocalDB.exe' -ErrorAction SilentlyContinue
    $sqlLocalDb = if ($tool) { $tool.Source } else {
        Get-ChildItem -Path "$env:ProgramFiles\Microsoft SQL Server\*\Tools\Binn\SqlLocalDB.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (!$sqlLocalDb) { throw 'SQL Server LocalDB tooling is missing on the Windows runner.' }
    & $sqlLocalDb versions | Out-Host
    & $sqlLocalDb create $instanceName -s | Out-Host
    if ($LASTEXITCODE -ne 0) {
        & $sqlLocalDb info $instanceName | Out-Host
        $log = Join-Path $env:LOCALAPPDATA "Microsoft\Microsoft SQL Server Local DB\Instances\$instanceName\error.log"
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 35 | Out-Host }
        throw 'The test SQL Server instance failed to start.'
    }
    $instance = "(localdb)\$instanceName"
    $db = 'RemoteWorkspaceSmoke'
    $connection = [Data.SqlClient.SqlConnection]::new("Data Source=$instance;Initial Catalog=master;Integrated Security=True;Connect Timeout=35")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'CREATE DATABASE [RemoteWorkspaceSmoke]'
        [void] $command.ExecuteNonQuery()
        $connection.ChangeDatabase($db)
        $command.CommandText = @'
CREATE TABLE dbo.tblCons (
 ID int NOT NULL, ConstantID varchar(128) NULL, ParentID varchar(128) NULL,
 PositionID int NOT NULL, [Type] varchar(32) NOT NULL, [Name] varchar(128) NOT NULL,
 Hostname varchar(512) NULL, Protocol varchar(32) NOT NULL, Port int NOT NULL,
 Username varchar(512) NULL, DomainName varchar(512) NULL, Description varchar(1024) NULL,
 RDGatewayHostname varchar(512) NULL, RedirectSmartCards bit NOT NULL,
 InheritRedirectSmartCards bit NOT NULL, ConnectToConsole bit NOT NULL,
 RedirectDiskDrives bit NOT NULL, RedirectPrinters bit NOT NULL);
INSERT dbo.tblCons VALUES
 (1,'folder','0',1,'Container','Imported root',NULL,'RDP',3389,NULL,NULL,NULL,NULL,0,0,0,0,0),
 (2,'child','folder',2,'Container','Imported child',NULL,'RDP',3389,NULL,NULL,NULL,NULL,0,0,0,0,0),
 (3,'node','child',3,'Connection','SQL fixture','fixture.example','RDP',3389,'qa',NULL,NULL,NULL,1,0,1,0,1);
'@
        [void] $command.ExecuteNonQuery()
    } finally {
        $connection.Dispose()
    }
    [pscustomobject]@{ Instance = $instance; Database = $db }
}

function Import-Fixture {
    param($Window, $Fixture)
    Invoke-Control $Window 'Подключить SQL Server'
    Set-Control $Window 'Сервер SQL' $Fixture.Instance
    Set-Control $Window 'База SQL' $Fixture.Database
    $trust = (Find-Name $Window 'Доверять сертификату для этой загрузки').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if ($trust.Current.ToggleState -ne [Windows.Automation.ToggleState]::Off) { throw 'Certificate validation is not on by default.' }
    $trust.Toggle()
    Invoke-Control $Window 'Загрузить каталог'
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        if ($null -eq (Find-Name $Window 'Загрузить каталог' -Optional)) { return }
        Start-Sleep -Milliseconds 400
    } until ([DateTime]::UtcNow -ge $deadline)
    $condition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)
    $texts = $Window.FindAll($tree, $condition) | ForEach-Object { $_.Current.Name }
    throw "The SQL importer did not complete. Visible text: $($texts -join ' | ')"
}

$app = Open-App
try {
    $window = $app.Window
    Invoke-Control $window 'Создать папку'
    $editor = Find-Dialog $app.Process 'Новая папка'
    Set-Control $editor 'Название папки' 'QA Root'
    Invoke-Control $editor 'Сохранить'
    $null = Read-CatalogDocument 'QA Root'

    Invoke-Control $window 'Создать папку'
    $editor = Find-Dialog $app.Process 'Новая папка'
    Set-Control $editor 'Название папки' 'QA Nested'
    Invoke-Control $editor 'Сохранить'
    $doc = Read-CatalogDocument 'QA Nested'
    $root = $doc.Catalog.Folders.SelectSingleNode("Folder[Name='QA Root']")
    $nested = $doc.Catalog.Folders.SelectSingleNode("Folder[Name='QA Nested']")
    if (!$root -or !$nested -or $nested.ParentId -ne $root.Id) { throw 'The new folder hierarchy was not saved.' }

    Invoke-Control $window 'Создать подключение'
    $editor = Find-Dialog $app.Process 'Новое подключение'
    Set-Control $editor 'Название подключения' 'QA profile'
    Set-Control $editor 'Имя хоста или IP' 'rdp-fixture.example'
    Invoke-Control $editor 'Сохранить'
    $doc = Read-CatalogDocument 'rdp-fixture.example'
    $profile = $doc.Catalog.Profiles.SelectSingleNode("Profile[Name='QA profile']")
    if (!$profile -or $profile.FolderId -ne $nested.Id -or $profile.Protocol -ne 'RDP') { throw 'New connection was not saved.' }

    Invoke-Control $window 'Изменить подключение'
    $editor = Find-Dialog $app.Process 'Редактирование подключения'
    $box = Find-Name $editor 'Протокол'
    $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $choice = Find-Name $box 'SSH2'
    $choice.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $box.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
    Set-Control $editor 'Имя хоста или IP' 'ssh-fixture.example'
    Invoke-Control $editor 'Сохранить'
    $doc = Read-CatalogDocument 'ssh-fixture.example'
    $profile = $doc.Catalog.Profiles.SelectSingleNode("Profile[Name='QA profile']")
    if ($profile.Protocol -ne 'SSH2' -or $profile.Port -ne '22') { throw 'Protocol and port edits were not saved.' }

    Write-Host "Windows catalog checks passed through protocol edit."
    $fixture = Initialize-SqlFixture
    Import-Fixture $window $fixture
    $doc = Read-CatalogDocument '<Host>fixture.example</Host>'
    $imported = $doc.Catalog.Profiles.SelectSingleNode("Profile[Name='SQL fixture']")
    $child = $doc.Catalog.Folders.SelectSingleNode("Folder[Name='Imported child']")
    if (!$imported -or !$child -or $imported.FolderId -ne $child.Id -or $imported.SmartCards -ne 'true') {
        throw 'SQL import did not preserve folder and smart-card settings.'
    }
    Import-Fixture $window $fixture
    $doc = Read-CatalogDocument 'SQL fixture'
    if (@($doc.Catalog.Profiles.SelectNodes("Profile[Name='SQL fixture']")).Count -ne 1) { throw 'Repeat import produced duplicates.' }
    Stop-App $app
    $app = Open-App
    $window = $app.Window
    Set-Control $window 'Поиск подключений' 'ssh-fixture.example'
    $null = Find-Name $window 'Показано 1 из 2'
    Set-Control $window 'Поиск подключений' ''
    $null = Find-Name $window 'Показано 2 из 2'
    Write-Host 'Windows checks passed: nested folders, profile creation, protocol and port editing, SQL import, repeat import, search and persistence across restart.'
} finally {
    if (!$app.Process.HasExited) { Stop-App $app }
}
