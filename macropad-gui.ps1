<#
.SYNOPSIS
    Visual configurator for the CH57x/CH552 macro pad (USB 1189:8840).

.DESCRIPTION
    A WPF front end over src\MacroPad.psm1. It adds no protocol code of its own:
    every write goes through the same Read-PadConfigFile / Write-PadConfig path
    the CLI uses, so the two tools cannot disagree about what a binding means.

    The in-memory model is just binding strings in config.json syntax, which is
    what makes that reuse possible.

.PARAMETER Config
    Config file to open on startup. Defaults to config.json beside this script.

.PARAMETER SelfTest
    Build the window and validate the config without displaying anything, then
    exit. Catches XAML and wiring errors without needing a human.

.EXAMPLE
    .\macropad-gui.ps1
#>
[CmdletBinding()]
param(
    [string] $Config,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Import-Module (Join-Path $PSScriptRoot 'src\MacroPad.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'src\WpfKeyMap.ps1')

# Slot order, matching the physical layout. Also the config.json field order.
$script:SlotOrder = @(
    'key1', 'key2', 'key3', 'key4',
    'key5', 'key6', 'key7', 'key8',
    'key9', 'key10', 'key11', 'key12',
    'knob1.ccw', 'knob1.press', 'knob1.cw',
    'knob2.ccw', 'knob2.press', 'knob2.cw'
)

# Mouse slots do not survive a read from the device, so they come back marked
# with this rather than silently blank -- otherwise Read Device followed by
# Apply would quietly wipe whatever mouse bindings were on the pad.
$script:UnreadableMarker = '(not readable)'

$script:MouseChoices = @(
    'click', 'click(left)', 'click(right)', 'click(middle)',
    'wheelup', 'wheeldown', 'wheel(1)', 'wheel(-1)',
    'move(10,0)', 'move(0,10)', 'drag(left,10,0)'
)

# --- Model -----------------------------------------------------------------

function New-EmptyModel {
    $layers = @()
    for ($i = 0; $i -lt 3; $i++) {
        $slots = [ordered]@{}
        foreach ($name in $script:SlotOrder) { $slots[$name] = '' }
        $layers += , $slots
    }
    $layers
}

function ConvertTo-ConfigObject {
    param($Model)

    $layers = @()
    foreach ($slots in $Model) {
        $buttons = @()
        for ($i = 1; $i -le 12; $i++) { $buttons += [string]$slots["key$i"] }

        $knobs = @()
        foreach ($k in 1, 2) {
            $knobs += [ordered]@{
                ccw   = [string]$slots["knob$k.ccw"]
                press = [string]$slots["knob$k.press"]
                cw    = [string]$slots["knob$k.cw"]
            }
        }
        $layers += [ordered]@{ buttons = $buttons; knobs = $knobs }
    }
    [ordered]@{ layers = $layers }
}

function Import-ModelFromFile {
    param([string] $Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $stripped = [regex]::Replace($raw, '(?m)^\s*//.*$', '')
    $json = $stripped | ConvertFrom-Json

    $model = New-EmptyModel
    $layerIndex = 0
    foreach ($layerNode in @($json.layers)) {
        if ($layerIndex -ge 3) { break }
        $slots = $model[$layerIndex]

        if ($null -ne $layerNode.PSObject.Properties['buttons']) {
            $entries = @($layerNode.buttons)
            for ($i = 0; $i -lt $entries.Count -and $i -lt 12; $i++) {
                $slots["key$($i + 1)"] = ConvertTo-BindingText -Value $entries[$i]
            }
        }
        if ($null -ne $layerNode.PSObject.Properties['knobs']) {
            $knobNodes = @($layerNode.knobs)
            for ($k = 0; $k -lt $knobNodes.Count -and $k -lt 2; $k++) {
                foreach ($action in 'ccw', 'press', 'cw') {
                    $node = $knobNodes[$k]
                    if ($null -ne $node.PSObject.Properties[$action]) {
                        $slots["knob$($k + 1).$action"] = ConvertTo-BindingText -Value $node.$action
                    }
                }
            }
        }
        $layerIndex++
    }
    $model
}

function ConvertTo-BindingText {
    # A macro arrives as a JSON array; the editor shows it comma-separated.
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        return (@($Value) -join ',')
    }
    [string]$Value
}

function Test-SlotBinding {
    <#
    .SYNOPSIS
        Validate one binding string. Returns @{ Ok; Message }.
    #>
    param([string] $Text)

    if ($Text -eq $script:UnreadableMarker) {
        return @{
            Ok = $false
            Message = 'This mouse binding could not be read back from the pad. Set it or clear it before applying.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Ok = $true; Message = 'unbound' }
    }
    try {
        $parsed = ConvertTo-PadBinding -Value $Text -Context 'binding'
        return @{ Ok = $true; Message = "valid - $($parsed.Type)" }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
}

# --- UI state --------------------------------------------------------------

$ui = @{
    Model        = New-EmptyModel
    Layer        = 0
    Slot         = 'key1'
    SlotButtons  = @{}
    Path         = $null
    Dirty        = $false
    Capturing    = $false
    Suppress     = $false      # guards TextChanged while we set text ourselves
}

# --- Window ----------------------------------------------------------------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Macro Pad Configurator" Width="980" Height="660"
        WindowStartupLocation="CenterScreen" Background="#FFF4F4F6">
  <DockPanel Margin="12">

    <Border DockPanel.Dock="Top" Padding="10,8" Margin="0,0,0,10"
            Background="White" BorderBrush="#FFD8D8DE" BorderThickness="1" CornerRadius="4">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Layer" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <RadioButton x:Name="RbLayer1" Content="1" GroupName="Layer" IsChecked="True" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <RadioButton x:Name="RbLayer2" Content="2" GroupName="Layer" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <RadioButton x:Name="RbLayer3" Content="3" GroupName="Layer" Margin="0,0,20,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="LblFile" Text="(new)" Foreground="#FF666677" VerticalAlignment="Center"/>
        <TextBlock x:Name="LblDirty" Text="" Foreground="#FFCC5500" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>

    <Border DockPanel.Dock="Bottom" Padding="10,8" Margin="0,10,0,0"
            Background="White" BorderBrush="#FFD8D8DE" BorderThickness="1" CornerRadius="4">
      <StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
          <Button x:Name="BtnRead"    Content="Read Device"  Padding="12,5" Margin="0,0,8,0"/>
          <Button x:Name="BtnOpen"    Content="Open..."      Padding="12,5" Margin="0,0,8,0"/>
          <Button x:Name="BtnSave"    Content="Save"         Padding="12,5" Margin="0,0,8,0"/>
          <Button x:Name="BtnSaveAs"  Content="Save As..."   Padding="12,5" Margin="0,0,8,0"/>
          <Button x:Name="BtnApply"   Content="Apply to Pad" Padding="12,5" Margin="0,0,8,0" FontWeight="Bold"/>
          <Button x:Name="BtnRestore" Content="Restore..."   Padding="12,5"/>
        </StackPanel>
        <TextBlock x:Name="LblStatus" Text="Ready." Foreground="#FF444455" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="330"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Padding="12" Background="White"
              BorderBrush="#FFD8D8DE" BorderThickness="1" CornerRadius="4">
        <StackPanel>
          <UniformGrid x:Name="KeyGrid" Rows="3" Columns="4"/>
          <TextBlock Text="Knob 1" FontWeight="Bold" Margin="4,16,0,4"/>
          <StackPanel x:Name="Knob1Panel" Orientation="Horizontal"/>
          <TextBlock Text="Knob 2" FontWeight="Bold" Margin="4,14,0,4"/>
          <StackPanel x:Name="Knob2Panel" Orientation="Horizontal"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" Margin="10,0,0,0" Padding="12" Background="White"
              BorderBrush="#FFD8D8DE" BorderThickness="1" CornerRadius="4">
        <StackPanel>
          <TextBlock Text="Selected slot" Foreground="#FF666677"/>
          <TextBlock x:Name="LblSelected" Text="key1" FontSize="18" FontWeight="Bold" Margin="0,2,0,12"/>

          <TextBlock Text="Binding" Foreground="#FF666677"/>
          <TextBox x:Name="TxtBinding" Padding="6,4" Margin="0,2,0,6" FontFamily="Consolas" FontSize="13"/>

          <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
            <ToggleButton x:Name="BtnCapture" Content="Press keys..." Padding="10,5" Margin="0,0,8,0"
                          ToolTip="Click, then press a combination. Windows intercepts some chords (alt+tab, win+l, ctrl+alt+del) so they cannot be captured - use the pickers or type them instead."/>
            <Button x:Name="BtnClear" Content="Clear" Padding="10,5"/>
          </StackPanel>

          <TextBlock Text="Media key" Foreground="#FF666677"/>
          <ComboBox x:Name="CmbMedia" Margin="0,2,0,10"/>

          <TextBlock Text="Mouse action" Foreground="#FF666677"/>
          <ComboBox x:Name="CmbMouse" Margin="0,2,0,10"/>

          <Border Background="#FFF7F7FA" BorderBrush="#FFE0E0E6" BorderThickness="1"
                  CornerRadius="3" Padding="8" Margin="0,4,0,0">
            <TextBlock x:Name="LblValidation" Text="" TextWrapping="Wrap" FontSize="12"/>
          </Border>

          <TextBlock Margin="0,12,0,0" FontSize="11" Foreground="#FF888899" TextWrapping="Wrap"
                     Text="Macros: comma-separate up to 5 keys, e.g. h,e,l,l,o - Media keys cannot take modifiers."/>
        </StackPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load(
    (New-Object System.Xml.XmlNodeReader ([xml]$xaml)))

foreach ($name in 'RbLayer1', 'RbLayer2', 'RbLayer3', 'LblFile', 'LblDirty',
                  'BtnRead', 'BtnOpen', 'BtnSave', 'BtnSaveAs', 'BtnApply', 'BtnRestore',
                  'LblStatus', 'KeyGrid', 'Knob1Panel', 'Knob2Panel',
                  'LblSelected', 'TxtBinding', 'BtnCapture', 'BtnClear',
                  'CmbMedia', 'CmbMouse', 'LblValidation') {
    $ui[$name] = $window.FindName($name)
}

# --- UI helpers ------------------------------------------------------------

function Set-Status {
    param([string] $Text, [string] $Color = '#FF444455')
    $ui.LblStatus.Text = $Text
    $ui.LblStatus.Foreground = $Color
}

function Update-UiNow {
    # WPF's equivalent of DoEvents: lets the window repaint mid-operation.
    $frame = New-Object Windows.Threading.DispatcherFrame
    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        [action]{ $frame.Continue = $false }) | Out-Null
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Set-Dirty {
    param([bool] $Value)
    $ui.Dirty = $Value
    $ui.LblDirty.Text = if ($Value) { 'unsaved changes' } else { '' }
}

function New-SlotButton {
    param([string] $SlotName, [string] $Caption, [int] $Width = 118)

    $text = New-Object Windows.Controls.TextBlock
    $text.TextAlignment = 'Center'
    $text.TextWrapping = 'Wrap'

    $button = New-Object Windows.Controls.Button
    $button.Content = $text
    $button.Tag = $SlotName
    $button.Width = $Width
    $button.Height = 58
    $button.Margin = '4'
    $button.BorderThickness = '2'
    $button.Add_Click({ Select-Slot -SlotName $this.Tag })
    $button | Add-Member -NotePropertyName Caption -NotePropertyValue $Caption
    $ui.SlotButtons[$SlotName] = $button
    $button
}

function Update-SlotButton {
    param([string] $SlotName)

    $button = $ui.SlotButtons[$SlotName]
    $value = [string]$ui.Model[$ui.Layer][$SlotName]
    $shown = if ([string]::IsNullOrWhiteSpace($value)) { '-' } else { $value }

    $text = $button.Content
    $text.Inlines.Clear()
    $head = New-Object Windows.Documents.Run $button.Caption
    $head.Foreground = [Windows.Media.Brushes]::Gray
    $head.FontSize = 10
    $text.Inlines.Add($head)
    $text.Inlines.Add((New-Object Windows.Documents.LineBreak))
    $body = New-Object Windows.Documents.Run $shown
    $body.FontFamily = New-Object Windows.Media.FontFamily 'Consolas'
    $body.FontSize = 12
    $text.Inlines.Add($body)

    $check = Test-SlotBinding -Text $value
    if (-not $check.Ok) {
        $button.BorderBrush = [Windows.Media.Brushes]::Firebrick
    } elseif ($SlotName -eq $ui.Slot) {
        $button.BorderBrush = [Windows.Media.Brushes]::SteelBlue
    } else {
        $button.BorderBrush = [Windows.Media.Brushes]::Transparent
    }
}

function Update-AllSlots {
    foreach ($name in $script:SlotOrder) { Update-SlotButton -SlotName $name }
    Update-ApplyState | Out-Null
}

function Update-ApplyState {
    # Apply must stay blocked while anything anywhere is invalid, not just the
    # slot on screen -- a bad binding on layer 3 is just as fatal.
    $bad = 0
    foreach ($layerSlots in $ui.Model) {
        foreach ($name in $script:SlotOrder) {
            if (-not (Test-SlotBinding -Text ([string]$layerSlots[$name])).Ok) { $bad++ }
        }
    }
    $ui.BtnApply.IsEnabled = ($bad -eq 0)
    if ($bad -gt 0) {
        Set-Status "$bad slot(s) need attention before this can be applied." '#FFAA2200'
    }
    $bad
}

function Select-Slot {
    param([string] $SlotName)

    $previous = $ui.Slot
    $ui.Slot = $SlotName
    $ui.LblSelected.Text = $SlotName

    $ui.Suppress = $true
    $ui.TxtBinding.Text = [string]$ui.Model[$ui.Layer][$SlotName]
    $ui.CmbMedia.SelectedIndex = -1
    $ui.CmbMouse.SelectedIndex = -1
    $ui.Suppress = $false

    Update-Validation
    Update-SlotButton -SlotName $previous
    Update-SlotButton -SlotName $SlotName
}

function Update-Validation {
    $check = Test-SlotBinding -Text $ui.TxtBinding.Text
    $ui.LblValidation.Text = $check.Message
    $ui.LblValidation.Foreground = if ($check.Ok) {
        [Windows.Media.Brushes]::DarkGreen
    } else {
        [Windows.Media.Brushes]::Firebrick
    }
}

function Set-CurrentBinding {
    param([string] $Text)
    $ui.Suppress = $true
    $ui.TxtBinding.Text = $Text
    $ui.Suppress = $false
    $ui.Model[$ui.Layer][$ui.Slot] = $Text
    Set-Dirty $true
    Update-Validation
    Update-SlotButton -SlotName $ui.Slot
    Update-ApplyState | Out-Null
}

function Switch-Layer {
    param([int] $Index)
    $ui.Layer = $Index
    Select-Slot -SlotName $ui.Slot
    Update-AllSlots
}

function Confirm-Discard {
    if (-not $ui.Dirty) { return $true }
    $answer = [Windows.MessageBox]::Show(
        'Discard unsaved changes?', 'Macro Pad Configurator',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
    $answer -eq [Windows.MessageBoxResult]::Yes
}

# --- Build the slot grid ---------------------------------------------------

for ($i = 1; $i -le 12; $i++) {
    $ui.KeyGrid.Children.Add((New-SlotButton -SlotName "key$i" -Caption "key$i")) | Out-Null
}
foreach ($k in 1, 2) {
    $panel = $ui["Knob$k`Panel"]
    foreach ($action in 'ccw', 'press', 'cw') {
        $label = switch ($action) { 'ccw' { 'turn left' } 'press' { 'press' } 'cw' { 'turn right' } }
        $panel.Children.Add((New-SlotButton -SlotName "knob$k.$action" -Caption $label -Width 128)) | Out-Null
    }
}

$names = Get-PadKeyNames
foreach ($m in $names.Media) { $ui.CmbMedia.Items.Add($m) | Out-Null }
foreach ($m in $script:MouseChoices) { $ui.CmbMouse.Items.Add($m) | Out-Null }

# --- Events ----------------------------------------------------------------

$ui.RbLayer1.Add_Checked({ Switch-Layer 0 })
$ui.RbLayer2.Add_Checked({ Switch-Layer 1 })
$ui.RbLayer3.Add_Checked({ Switch-Layer 2 })

$ui.TxtBinding.Add_TextChanged({
    if ($ui.Suppress) { return }
    $ui.Model[$ui.Layer][$ui.Slot] = $ui.TxtBinding.Text
    Set-Dirty $true
    Update-Validation
    Update-SlotButton -SlotName $ui.Slot
    Update-ApplyState | Out-Null
})

$ui.BtnClear.Add_Click({ Set-CurrentBinding '' })

$ui.CmbMedia.Add_SelectionChanged({
    if ($ui.Suppress -or $ui.CmbMedia.SelectedIndex -lt 0) { return }
    Set-CurrentBinding ([string]$ui.CmbMedia.SelectedItem)
})
$ui.CmbMouse.Add_SelectionChanged({
    if ($ui.Suppress -or $ui.CmbMouse.SelectedIndex -lt 0) { return }
    Set-CurrentBinding ([string]$ui.CmbMouse.SelectedItem)
})

$ui.BtnCapture.Add_Checked({
    $ui.Capturing = $true
    Set-Status 'Capture armed - press a combination. Esc leaves capture mode.' '#FF0055AA'
})
$ui.BtnCapture.Add_Unchecked({
    $ui.Capturing = $false
    Set-Status 'Capture off.'
})

$window.Add_PreviewKeyDown({
    param($sender, $e)
    if (-not $ui.Capturing) { return }

    # Escape leaves capture mode rather than binding itself; binding Escape is
    # still possible by typing "esc" into the box.
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        $ui.BtnCapture.IsChecked = $false
        $e.Handled = $true
        return
    }

    $binding = ConvertFrom-WpfKeystroke -Key $e.Key
    $e.Handled = $true
    if ($null -eq $binding) { return }   # modifiers alone: keep waiting

    Set-CurrentBinding $binding
    $ui.BtnCapture.IsChecked = $false
    Set-Status "Captured: $binding"
})

$ui.BtnOpen.Add_Click({
    if (-not (Confirm-Discard)) { return }
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Config files (*.json)|*.json|All files (*.*)|*.*'
    $dialog.InitialDirectory = $PSScriptRoot
    if ($dialog.ShowDialog() -ne $true) { return }
    try {
        $ui.Model = Import-ModelFromFile -Path $dialog.FileName
        $ui.Path = $dialog.FileName
        $ui.LblFile.Text = Split-Path -Leaf $dialog.FileName
        Set-Dirty $false
        Select-Slot -SlotName $ui.Slot
        Update-AllSlots
        Set-Status "Loaded $($dialog.FileName)"
    } catch {
        Set-Status "Could not load: $($_.Exception.Message)" '#FFAA2200'
    }
})

function Save-ModelTo {
    param([string] $Path)
    ConvertTo-ConfigObject -Model $ui.Model |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $Path -Encoding UTF8
    $ui.Path = $Path
    $ui.LblFile.Text = Split-Path -Leaf $Path
    Set-Dirty $false
    Set-Status "Saved $Path"
}

$ui.BtnSave.Add_Click({
    if ($null -eq $ui.Path) { $ui.BtnSaveAs.RaiseEvent(
        (New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); return }
    try { Save-ModelTo -Path $ui.Path }
    catch { Set-Status "Could not save: $($_.Exception.Message)" '#FFAA2200' }
})

$ui.BtnSaveAs.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Config files (*.json)|*.json'
    $dialog.InitialDirectory = $PSScriptRoot
    $dialog.FileName = 'config.json'
    if ($dialog.ShowDialog() -ne $true) { return }
    try { Save-ModelTo -Path $dialog.FileName }
    catch { Set-Status "Could not save: $($_.Exception.Message)" '#FFAA2200' }
})

$ui.BtnRead.Add_Click({
    if (-not (Confirm-Discard)) { return }
    Set-Status 'Reading device...'
    Update-UiNow
    $pad = $null
    try {
        $pad = Connect-Pad
        $model = New-EmptyModel
        $unreadable = 0
        foreach ($entry in (Read-PadBindings -Pad $pad -Layers 3)) {
            $index = $entry.Layer - 1
            if ($index -lt 0 -or $index -gt 2) { continue }
            if ($script:SlotOrder -notcontains $entry.Button) { continue }   # spare slots
            if ($entry.Type -eq 'mouse') {
                $model[$index][$entry.Button] = $script:UnreadableMarker
                $unreadable++
            } else {
                $model[$index][$entry.Button] = $entry.Binding
            }
        }
        $ui.Model = $model
        $ui.Path = $null
        $ui.LblFile.Text = '(from device)'
        Set-Dirty $false
        Select-Slot -SlotName $ui.Slot
        Update-AllSlots
        if ($unreadable -gt 0) {
            Set-Status ("Read OK. $unreadable mouse slot(s) cannot be read back from this firmware " +
                        "and are marked '$script:UnreadableMarker' - set or clear them before applying.") '#FFAA5500'
        } else {
            Set-Status 'Read OK.'
        }
    } catch {
        Set-Status "Read failed: $($_.Exception.Message)" '#FFAA2200'
    } finally {
        if ($pad) { $pad.Dispose() }
    }
})

$ui.BtnApply.Add_Click({
    if ((Update-ApplyState) -gt 0) { return }

    $answer = [Windows.MessageBox]::Show(
        "Write all three layers to the pad?`n`nThe current on-device configuration will be backed up to backups\ first.",
        'Apply to Pad', [Windows.MessageBoxButton]::OKCancel, [Windows.MessageBoxImage]::Question)
    if ($answer -ne [Windows.MessageBoxResult]::OK) { return }

    $temp = Join-Path $env:TEMP ("macropad-gui-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $pad = $null
    try {
        ConvertTo-ConfigObject -Model $ui.Model | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $temp -Encoding UTF8

        # Reuse the CLI's parser so the GUI cannot interpret a binding differently.
        $config = Read-PadConfigFile -Path $temp

        $window.IsEnabled = $false
        Set-Status 'Connecting...'
        Update-UiNow

        $pad = Connect-Pad

        $backupDir = Join-Path $PSScriptRoot 'backups'
        if (-not (Test-Path -LiteralPath $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $backup = Join-Path $backupDir ("{0}.json" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        Set-Status 'Backing up current configuration...'
        Update-UiNow
        Export-PadConfig -Pad $pad -Layers 3 -Note 'pre-apply from GUI' |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $backup -Encoding UTF8

        Write-PadConfig -Pad $pad -Config $config -OnProgress {
            param($done, $total, $label)
            Set-Status "Programming $done/$total - $label"
            Update-UiNow
        }

        Set-Status "Done. Written to flash. Backup saved to $backup" '#FF117700'
    } catch {
        Set-Status "Apply failed: $($_.Exception.Message)" '#FFAA2200'
    } finally {
        if ($pad) { $pad.Dispose() }
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
        $window.IsEnabled = $true
    }
})

$ui.BtnRestore.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Backup files (*.json)|*.json'
    $dialog.InitialDirectory = Join-Path $PSScriptRoot 'backups'
    if ($dialog.ShowDialog() -ne $true) { return }

    $answer = [Windows.MessageBox]::Show(
        "Replay $($dialog.FileName) onto the pad?", 'Restore',
        [Windows.MessageBoxButton]::OKCancel, [Windows.MessageBoxImage]::Warning)
    if ($answer -ne [Windows.MessageBoxResult]::OK) { return }

    $pad = $null
    try {
        $window.IsEnabled = $false
        Set-Status 'Restoring...'
        Update-UiNow
        $pad = Connect-Pad
        $count = Restore-PadConfig -Pad $pad -Path $dialog.FileName
        Set-Status "Restored $count reports and saved to flash." '#FF117700'
    } catch {
        Set-Status "Restore failed: $($_.Exception.Message)" '#FFAA2200'
    } finally {
        if ($pad) { $pad.Dispose() }
        $window.IsEnabled = $true
    }
})

$window.Add_Closing({
    param($sender, $e)
    if (-not (Confirm-Discard)) { $e.Cancel = $true }
})

# --- Startup ---------------------------------------------------------------

if (-not $Config) {
    $default = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $default) { $Config = $default }
}
if ($Config -and (Test-Path -LiteralPath $Config)) {
    try {
        $ui.Model = Import-ModelFromFile -Path $Config
        $ui.Path = (Resolve-Path -LiteralPath $Config).Path
        $ui.LblFile.Text = Split-Path -Leaf $ui.Path
    } catch {
        Set-Status "Could not load $Config : $($_.Exception.Message)" '#FFAA2200'
    }
}

Select-Slot -SlotName 'key1'
Update-AllSlots
Set-Dirty $false

if ($SelfTest) {
    $problems = Update-ApplyState
    Write-Host "Self-test:" -ForegroundColor Cyan
    Write-Host "  window built        : $($window.Title)"
    Write-Host "  slot buttons created: $($ui.SlotButtons.Count) (expected 18)"
    Write-Host "  media choices       : $($ui.CmbMedia.Items.Count)"
    Write-Host "  mouse choices       : $($ui.CmbMouse.Items.Count)"
    Write-Host "  config loaded       : $($ui.LblFile.Text)"
    Write-Host "  invalid slots       : $problems"

    # Key capture: a letter, a function key, a digit, and a modifier-only press
    # (which must yield nothing so the chord keeps waiting).
    $capture = @(
        'C -> ' + (ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::C))
        'F13 -> ' + (ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::F13))
        'D7 -> ' + (ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::D7))
        'OemComma -> ' + (ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::OemComma))
        'LeftCtrl -> ' + $(if ($null -eq (ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::LeftCtrl))) { '(null, correct)' } else { 'WRONG' })
    )
    Write-Host "  key capture         : $($capture -join ' | ')"

    # The apply path: model -> JSON -> the CLI's own parser. This is what the
    # Apply button does, so exercise it here rather than discovering it on hardware.
    $roundTripOk = $false
    $temp = Join-Path $env:TEMP ("macropad-selftest-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        ConvertTo-ConfigObject -Model $ui.Model | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $temp -Encoding UTF8
        $parsed = Read-PadConfigFile -Path $temp
        $slots = 0
        foreach ($layer in $parsed.Layers) { $slots += $layer.Buttons.Count + $layer.Knobs.Count }
        Write-Host "  apply round trip    : $($parsed.Layers.Count) layers, $slots slots parsed"
        $roundTripOk = ($parsed.Layers.Count -eq 3 -and $slots -eq 54)
    } catch {
        Write-Host "  apply round trip    : FAILED - $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }

    # The unreadable-mouse marker must fail validation, or Read-then-Apply
    # would silently wipe mouse bindings.
    $markerBlocked = -not (Test-SlotBinding -Text $script:UnreadableMarker).Ok
    Write-Host "  mouse marker blocks : $markerBlocked"

    if ($ui.SlotButtons.Count -ne 18 -or $problems -ne 0 -or -not $roundTripOk -or -not $markerBlocked) {
        Write-Host "FAILED" -ForegroundColor Red
        exit 1
    }
    Write-Host "PASSED" -ForegroundColor Green
    exit 0
}

$window.ShowDialog() | Out-Null
