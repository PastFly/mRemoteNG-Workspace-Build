# Cache the WPF tree items and the connect button before starting the first
# native control. Querying a complete UIA subtree containing a live desktop
# can cross into the remote session and block for a minute.
function Get-FixtureControls($Window, [string[]] $Names) {
    $items = @{}
    foreach ($name in $Names) {
        $item = Find-Name $Window $name -Type ([Windows.Automation.ControlType]::TreeItem)
        $items[$name] = $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    }
    $items[$Names[0]].Select()
    $button = Find-Name $Window 'Подключиться' -Type ([Windows.Automation.ControlType]::Button)
    [pscustomobject]@{ Items=$items; Connect=$button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern) }
}

function Select-FixtureTabs($Window, [string[]] $Names) {
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($Window)
    $tabs = $null
    while ($queue.Count -gt 0 -and !$tabs) {
        $child = $walker.GetFirstChild($queue.Dequeue())
        while ($null -ne $child) {
            if ($child.Current.AutomationId -eq 'SessionTabs') { $tabs = $child; break }
            if ($child.Current.NativeWindowHandle -eq 0) { $queue.Enqueue($child) }
            $child = $walker.GetNextSibling($child)
        }
    }
    if (!$tabs) { throw 'WPF tab strip not found.' }
    foreach ($name in $Names) {
        $item = Find-Name $tabs $name -Type ([Windows.Automation.ControlType]::ListItem)
        $selection = $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
        $selection.Select()
        if (!$selection.Current.IsSelected) { throw "The $name tab was not selected." }
    }
}
