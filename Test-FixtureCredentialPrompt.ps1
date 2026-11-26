# Only drive an isolated test endpoint's own Windows credential dialog.
function Submit-FixtureCredential([string] $Endpoint, [string] $Username, [string] $Password) {
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
        $Endpoint -ne 'rw-xrdp-fixture.test' -or $Username -notin @('rwalpha','rwbeta') -or
        $Password -notmatch '^Qa![a-f0-9]{32}a7$' -or
        @([Net.Dns]::GetHostAddresses($Endpoint) | Where-Object { ![Net.IPAddress]::IsLoopback($_) }).Count -ne 0) {
        throw 'Sign-in automation is restricted to the isolated loopback fixture.'
    }
    $scope = [Windows.Automation.TreeScope]::Descendants
    $all = [Windows.Automation.Condition]::TrueCondition
    $root = [Windows.Automation.AutomationElement]::RootElement
    $choicesShown = $false
    $switched = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(24)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $windows = $root.FindAll([Windows.Automation.TreeScope]::Children,$all)
        foreach ($window in $windows) {
            if ($window.Current.Name -ne 'Windows Security') { continue }
            $process = Get-Process -Id $window.Current.ProcessId -ErrorAction SilentlyContinue
            if (!$process -or $process.Path -notin @((Join-Path $env:windir 'System32\CredentialUIBroker.exe'),
                    (Join-Path $env:windir 'System32\mstsc.exe'))) { continue }
            try { $elements = @($window.FindAll($scope,$all)) }
            catch [System.Windows.Automation.ElementNotAvailableException] { continue }
            $mentionsFixture = $elements | Where-Object {
                $_.Current.ControlType -eq [Windows.Automation.ControlType]::Text -and
                $_.Current.Name -match '(?i)(?<![\w.-])rw-xrdp-fixture\.test(?![\w-]|\.[\w.-])'
            } | Select-Object -First 1
            if (!$mentionsFixture) { continue }
            $edits = @($elements | Where-Object {
                $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and
                $_.Current.IsEnabled -and !$_.Current.IsOffscreen
            })
            $userField = $edits | Where-Object { !$_.Current.IsPassword } | Select-Object -First 1
            $passwordField = $edits | Where-Object { $_.Current.IsPassword } | Select-Object -First 1
            if (!$userField -or !$passwordField) {
                $other = $elements | Where-Object { $_.Current.Name -eq 'Use a different account' -and !$_.Current.IsOffscreen } | Select-Object -First 1
                if ($other -and !$switched) {
                    Invoke-FixtureChoice $other
                    $switched = $true
                    break
                }
                $more = $elements | Where-Object { $_.Current.Name -eq 'More choices' -and !$_.Current.IsOffscreen } | Select-Object -First 1
                if ($more -and !$choicesShown) { Invoke-FixtureChoice $more; $choicesShown = $true }
                break
            }
            $userField.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Username)
            $passwordField.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Password)
            $ok = $elements | Where-Object {
                $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and
                $_.Current.Name -eq 'OK' -and $_.Current.IsEnabled
            } | Select-Object -First 1
            if (!$ok) { throw 'The isolated credential prompt did not enable its submit button.' }
            Invoke-FixtureChoice $ok
            Write-Host "Submitted synthetic account $Username through the system credential prompt."
            return
        }
    }
    throw "The expected Windows credential dialog for $Endpoint did not expose both input fields."
}

function Invoke-FixtureChoice($Element) {
    $pattern = $null
    if ($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) {
        $pattern.Invoke()
    } elseif ($Element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)) {
        $pattern.Select()
    } else { throw 'The fixture credential dialog did not expose an actionable control.' }
}
