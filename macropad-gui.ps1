<#
.SYNOPSIS
    Visual configurator for the CH57x/CH552 macro pad (USB 1189:8840).

.DESCRIPTION
    A WPF front end over src\MacroPad.psm1. It adds no protocol code of its own:
    every write goes through the same Read-PadConfigFile / Write-PadConfig path
    the CLI uses, so the two tools cannot disagree about what a binding means.

.PARAMETER Config
    Config file to open on startup. Defaults to config.json beside this script.

.PARAMETER Profile
    Name of a profile in profiles\ to open instead.

.PARAMETER Light
    Start in the light theme. The window opens dark otherwise, and whichever
    theme you last used is remembered.

.PARAMETER SelfTest
    Build everything and exercise the logic without displaying a window, then
    exit. Catches XAML, theming and wiring errors without needing a human.

.EXAMPLE
    .\macropad-gui.ps1
#>
[CmdletBinding()]
param(
    [string] $Config,
    [string] $Profile,
    [switch] $Light,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Import-Module (Join-Path $PSScriptRoot 'src\MacroPad.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'src\WpfKeyMap.ps1')
. (Join-Path $PSScriptRoot 'src\Theme.ps1')
. (Join-Path $PSScriptRoot 'src\GuiModel.ps1')

if (-not ('MiniKeyboard.RawInput' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'src\RawInput.cs')
}

$script:PadDeviceFilter = 'VID_1189&PID_8840'

# ---------------------------------------------------------------------------
# Shared control styles.
#
# WPF's stock chrome ignores a dark palette -- a default Button stays light
# grey whatever Background says -- so each control gets a compact template
# bound to the theme brushes. ComboBox is deliberately absent: its popup keeps
# system chrome unless fully templated, so the key picker popup is used for
# every list instead. One control, one style, consistent window.
# ---------------------------------------------------------------------------

$script:StyleXaml = @'
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PanelBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource SlotBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PanelBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource Hover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource Pressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource Disabled}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToggleButton">
      <Setter Property="Background" Value="{DynamicResource SlotBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PanelBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource Hover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background" Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PanelBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Chrome" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource Hover}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Macro Pad Configurator" Width="1040" Height="720"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}">
  <Window.Resources>
__STYLES__
  </Window.Resources>
  <DockPanel Margin="12">

    <Border DockPanel.Dock="Top" Padding="10,8" Margin="0,0,0,10"
            Background="{DynamicResource Panel}" BorderBrush="{DynamicResource PanelBorder}"
            BorderThickness="1" CornerRadius="4">
      <DockPanel>
        <ToggleButton x:Name="BtnTheme" DockPanel.Dock="Right" Content="Light" Padding="10,4"
                      ToolTip="Switch between dark and light. Remembered between sessions."/>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Layer" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <ToggleButton x:Name="BtnLayer1" Content="1" Width="38" Margin="0,0,4,0" IsChecked="True"/>
          <ToggleButton x:Name="BtnLayer2" Content="2" Width="38" Margin="0,0,4,0"/>
          <ToggleButton x:Name="BtnLayer3" Content="3" Width="38" Margin="0,0,16,0"/>
          <TextBlock x:Name="LblFile" Text="(new)" Foreground="{DynamicResource TextDim}" VerticalAlignment="Center"/>
          <TextBlock x:Name="LblDirty" Text="" Foreground="{DynamicResource Warn}" FontWeight="Bold"
                     Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border DockPanel.Dock="Bottom" Padding="10,8" Margin="0,10,0,0"
            Background="{DynamicResource Panel}" BorderBrush="{DynamicResource PanelBorder}"
            BorderThickness="1" CornerRadius="4">
      <StackPanel>
        <WrapPanel Margin="0,0,0,6">
          <Button x:Name="BtnRead"       Content="Read Device"   Margin="0,0,6,6"/>
          <Button x:Name="BtnOpen"       Content="Open..."       Margin="0,0,6,6"/>
          <Button x:Name="BtnOpenBackup" Content="Open Backup..." Margin="0,0,6,6"/>
          <Button x:Name="BtnProfiles"   Content="Profiles..."   Margin="0,0,6,6"/>
          <Button x:Name="BtnSave"       Content="Save"          Margin="0,0,6,6"/>
          <Button x:Name="BtnSaveAs"     Content="Save As..."    Margin="0,0,6,6"/>
        </WrapPanel>
        <WrapPanel Margin="0,0,0,8">
          <Button x:Name="BtnApply"      Content="Apply All Layers" FontWeight="Bold" Margin="0,0,6,6"/>
          <Button x:Name="BtnApplyLayer" Content="Apply Layer 1"    Margin="0,0,6,6"/>
          <Button x:Name="BtnVerify"     Content="Verify"           Margin="0,0,6,6"/>
          <Button x:Name="BtnRestore"    Content="Restore..."       Margin="0,0,6,6"/>
          <Button x:Name="BtnTester"     Content="Key Tester"       Margin="0,0,6,6"/>
          <Button x:Name="BtnReset"      Content="Reset Device"     Margin="0,0,6,6"
                  ToolTip="Re-enumerate the pad without unplugging it. Needs admin."/>
        </WrapPanel>
        <TextBlock x:Name="LblStatus" Text="Ready." Foreground="{DynamicResource TextDim}" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="340"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Padding="12" Background="{DynamicResource Panel}"
              BorderBrush="{DynamicResource PanelBorder}" BorderThickness="1" CornerRadius="4">
        <StackPanel>
          <UniformGrid x:Name="KeyGrid" Rows="3" Columns="4"/>
          <TextBlock Text="Knob 1" FontWeight="Bold" Margin="4,16,0,4"/>
          <StackPanel x:Name="Knob1Panel" Orientation="Horizontal"/>
          <TextBlock Text="Knob 2" FontWeight="Bold" Margin="4,14,0,4"/>
          <StackPanel x:Name="Knob2Panel" Orientation="Horizontal"/>
          <TextBlock Margin="4,18,0,0" FontSize="11" TextWrapping="Wrap"
                     Foreground="{DynamicResource TextDim}"
                     Text="Ctrl+Z undo, Ctrl+Y redo, Ctrl+Shift+C copy slot, Ctrl+Shift+V paste slot."/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" Margin="10,0,0,0" Padding="12" Background="{DynamicResource Panel}"
              BorderBrush="{DynamicResource PanelBorder}" BorderThickness="1" CornerRadius="4">
        <StackPanel>
          <TextBlock Text="Selected slot" Foreground="{DynamicResource TextDim}"/>
          <TextBlock x:Name="LblSelected" Text="key1" FontSize="18" FontWeight="Bold" Margin="0,2,0,12"/>

          <TextBlock Text="Binding" Foreground="{DynamicResource TextDim}"/>
          <TextBox x:Name="TxtBinding" Margin="0,2,0,6" FontFamily="Consolas" FontSize="13"/>

          <WrapPanel Margin="0,0,0,10">
            <ToggleButton x:Name="BtnCapture" Content="Press keys..." Margin="0,0,6,6"
                          ToolTip="Click, then press a combination. Windows intercepts some chords (alt+tab, win+l, ctrl+alt+del) so they cannot be captured - use Pick... or type them instead."/>
            <Button x:Name="BtnPick"  Content="Pick..." Margin="0,0,6,6"
                    ToolTip="Browse every supported key, media action and mouse action."/>
            <Button x:Name="BtnClear" Content="Clear"   Margin="0,0,6,6"/>
          </WrapPanel>

          <Border Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource PanelBorder}"
                  BorderThickness="1" CornerRadius="3" Padding="8" Margin="0,0,0,14">
            <TextBlock x:Name="LblValidation" Text="" TextWrapping="Wrap" FontSize="12"/>
          </Border>

          <TextBlock Text="Slot actions" Foreground="{DynamicResource TextDim}" Margin="0,0,0,4"/>
          <WrapPanel Margin="0,0,0,10">
            <Button x:Name="BtnCopy"      Content="Copy"   Margin="0,0,6,6"/>
            <Button x:Name="BtnPaste"     Content="Paste"  Margin="0,0,6,6"/>
            <Button x:Name="BtnUndo"      Content="Undo"   Margin="0,0,6,6"/>
            <Button x:Name="BtnRedo"      Content="Redo"   Margin="0,0,6,6"/>
          </WrapPanel>
          <Button x:Name="BtnDupLayer" Content="Duplicate this layer to..." HorizontalAlignment="Stretch"/>

          <TextBlock Margin="0,14,0,0" FontSize="11" TextWrapping="Wrap"
                     Foreground="{DynamicResource TextDim}"
                     Text="Macros: comma-separate up to 5 keys, e.g. h,e,l,l,o - Media keys cannot take modifiers."/>
        </StackPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@

function New-ThemedWindow {
    param([string] $Xaml)
    $withStyles = $Xaml -replace '__STYLES__', $script:StyleXaml
    [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$withStyles)))
}

$window = New-ThemedWindow -Xaml $mainXaml

$ui = @{
    Model      = New-EmptyModel
    Layer      = 0
    Slot       = 'key1'
    SlotButtons = @{}
    Path       = $null
    Dirty      = $false
    Capturing  = $false
    Suppress   = $false
    Clipboard  = $null
    Undo       = New-UndoStack
    Theme      = 'dark'
    Tester     = $null
    Window     = $window
}

foreach ($name in 'BtnTheme', 'BtnLayer1', 'BtnLayer2', 'BtnLayer3', 'LblFile', 'LblDirty',
                  'BtnRead', 'BtnOpen', 'BtnOpenBackup', 'BtnProfiles', 'BtnSave', 'BtnSaveAs',
                  'BtnApply', 'BtnApplyLayer', 'BtnVerify', 'BtnRestore', 'BtnTester', 'BtnReset',
                  'LblStatus', 'KeyGrid', 'Knob1Panel', 'Knob2Panel',
                  'LblSelected', 'TxtBinding', 'BtnCapture', 'BtnPick', 'BtnClear',
                  'LblValidation', 'BtnCopy', 'BtnPaste', 'BtnUndo', 'BtnRedo', 'BtnDupLayer') {
    $ui[$name] = $window.FindName($name)
}

# --- UI helpers ------------------------------------------------------------

function Set-Status {
    param([string] $Text, [string] $Brush = 'TextDim')
    $ui.LblStatus.Text = $Text
    $ui.LblStatus.Foreground = Get-ThemeBrush -Theme $ui.Theme -Key $Brush
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
    $ui.LblDirty.Text = $(if ($Value) { 'unsaved changes' } else { '' })
}

function New-SlotButton {
    param([string] $SlotName, [string] $Caption, [int] $Width = 124)

    $text = New-Object Windows.Controls.TextBlock
    $text.TextAlignment = 'Center'
    $text.TextWrapping = 'Wrap'

    $button = New-Object Windows.Controls.Button
    $button.Content = $text
    $button.Tag = $SlotName
    $button.Width = $Width
    $button.Height = 60
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
    $shown = $(if ([string]::IsNullOrWhiteSpace($value)) { '-' } else { $value })

    $text = $button.Content
    $text.Inlines.Clear()
    $head = New-Object Windows.Documents.Run $button.Caption
    $head.Foreground = Get-ThemeBrush -Theme $ui.Theme -Key 'TextDim'
    $head.FontSize = 10
    $text.Inlines.Add($head)
    $text.Inlines.Add((New-Object Windows.Documents.LineBreak))
    $body = New-Object Windows.Documents.Run $shown
    $body.FontFamily = New-Object Windows.Media.FontFamily 'Consolas'
    $body.FontSize = 12
    $body.Foreground = Get-ThemeBrush -Theme $ui.Theme -Key 'Text'
    $text.Inlines.Add($body)

    $button.Background = Get-ThemeBrush -Theme $ui.Theme -Key 'SlotBg'
    $check = Test-SlotBinding -Text $value
    $button.BorderBrush = if (-not $check.Ok) {
        Get-ThemeBrush -Theme $ui.Theme -Key 'Danger'
    } elseif ($SlotName -eq $ui.Slot) {
        Get-ThemeBrush -Theme $ui.Theme -Key 'SlotSelected'
    } else {
        Get-ThemeBrush -Theme $ui.Theme -Key 'SlotBorder'
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
    $ui.BtnApplyLayer.IsEnabled = ($bad -eq 0)
    $ui.BtnUndo.IsEnabled = ($ui.Undo.Past.Count -gt 0)
    $ui.BtnRedo.IsEnabled = ($ui.Undo.Future.Count -gt 0)
    if ($bad -gt 0) {
        Set-Status "$bad slot(s) need attention before this can be applied." 'Danger'
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
    $ui.Suppress = $false

    Update-Validation
    Update-SlotButton -SlotName $previous
    Update-SlotButton -SlotName $SlotName
}

function Update-Validation {
    $check = Test-SlotBinding -Text $ui.TxtBinding.Text
    $ui.LblValidation.Text = $check.Message
    $ui.LblValidation.Foreground = Get-ThemeBrush -Theme $ui.Theme -Key $(if ($check.Ok) { 'Ok' } else { 'Danger' })
}

function Set-CurrentBinding {
    param([string] $Text, [switch] $NoUndo)

    $old = [string]$ui.Model[$ui.Layer][$ui.Slot]
    if (-not $NoUndo) { Push-UndoSlot -Stack $ui.Undo -Layer $ui.Layer -Slot $ui.Slot -Old $old -New $Text }

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
    $ui.BtnLayer1.IsChecked = ($Index -eq 0)
    $ui.BtnLayer2.IsChecked = ($Index -eq 1)
    $ui.BtnLayer3.IsChecked = ($Index -eq 2)
    $ui.BtnApplyLayer.Content = "Apply Layer $($Index + 1)"
    Select-Slot -SlotName $ui.Slot
    Update-AllSlots
}

function Set-Theme {
    param([string] $Name)

    $ui.Theme = Set-WindowTheme -Window $window -Name $Name
    $ui.BtnTheme.Content = $(if ($ui.Theme -eq 'dark') { 'Light' } else { 'Dark' })
    $ui.Suppress = $true
    $ui.BtnTheme.IsChecked = ($ui.Theme -eq 'light')
    $ui.Suppress = $false

    $settings = Get-AppSettings
    $settings.theme = $ui.Theme
    Save-AppSettings -Settings $settings

    if ($ui.SlotButtons.Count -gt 0) { Update-AllSlots; Update-Validation }
}

function Confirm-Discard {
    if (-not $ui.Dirty) { return $true }
    $answer = [Windows.MessageBox]::Show(
        'Discard unsaved changes?', 'Macro Pad Configurator',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
    $answer -eq [Windows.MessageBoxResult]::Yes
}

function Set-Model {
    <#
    .SYNOPSIS
        Adopt a new model as one undoable operation.
    #>
    param($NewModel, [string] $Label, [string] $FileLabel, $Path)

    Push-UndoSnapshot -Stack $ui.Undo -Before (Copy-Model $ui.Model) -After (Copy-Model $NewModel) -Label $Label
    $ui.Model = $NewModel
    $ui.Path = $Path
    $ui.LblFile.Text = $FileLabel
    Select-Slot -SlotName $ui.Slot
    Update-AllSlots
}

# --- Pick-from-list popup --------------------------------------------------

$pickerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pick" Width="420" Height="520" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource Bg}" ShowInTaskbar="False">
  <Window.Resources>
__STYLES__
  </Window.Resources>
  <DockPanel Margin="12">
    <TextBox x:Name="TxtSearch" DockPanel.Dock="Top" Margin="0,0,0,8" FontSize="13"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="BtnOk" Content="Choose" Margin="0,0,6,0" IsDefault="True"/>
      <Button x:Name="BtnCancel" Content="Cancel" IsCancel="True"/>
    </StackPanel>
    <ListBox x:Name="LstItems"/>
  </DockPanel>
</Window>
'@

function Show-PickList {
    <#
    .SYNOPSIS
        Filterable list popup. Returns the chosen string, or $null.
    #>
    param([string] $Title, [string[]] $Items, $Owner)

    $dialog = New-ThemedWindow -Xaml $pickerXaml
    $dialog.Title = $Title
    if ($Owner) { $dialog.Owner = $Owner }
    Set-WindowTheme -Window $dialog -Name $ui.Theme | Out-Null

    $search = $dialog.FindName('TxtSearch')
    $list = $dialog.FindName('LstItems')
    $ok = $dialog.FindName('BtnOk')

    $all = @($Items)
    foreach ($item in $all) { $list.Items.Add($item) | Out-Null }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

    $search.Add_TextChanged({
        $filter = $search.Text.Trim()
        $list.Items.Clear()
        foreach ($item in $all) {
            if ($filter -eq '' -or $item -like "*$filter*") { $list.Items.Add($item) | Out-Null }
        }
        if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    }.GetNewClosure())

    $list.Add_MouseDoubleClick({ $dialog.DialogResult = $true }.GetNewClosure())
    $ok.Add_Click({ $dialog.DialogResult = $true }.GetNewClosure())

    # Down-arrow from the search box moves into the list without losing the filter.
    $search.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Down -and $list.Items.Count -gt 0) {
            $list.Focus() | Out-Null
            $e.Handled = $true
        }
    }.GetNewClosure())

    $search.Focus() | Out-Null
    if ($dialog.ShowDialog() -ne $true) { return $null }
    if ($null -eq $list.SelectedItem) { return $null }

    # Strip the "category:  " prefix used for grouping.
    ([string]$list.SelectedItem) -replace '^\S+:\s+', ''
}

function Get-PickerItems {
    <#
    .SYNOPSIS
        Every bindable thing, prefixed by category so one list can hold all
        three and still be searchable ("media: volumeup").
    #>
    $names = Get-PadKeyNames
    $items = @()
    foreach ($k in $names.Keys)  { $items += "key:    $k" }
    foreach ($m in $names.Media) { $items += "media:  $m" }
    foreach ($m in @('click', 'click(left)', 'click(right)', 'click(middle)',
                     'wheelup', 'wheeldown', 'wheel(1)', 'wheel(-1)',
                     'move(10,0)', 'move(0,10)', 'drag(left,10,0)')) {
        $items += "mouse:  $m"
    }
    $items
}

# --- Build the slot grid ---------------------------------------------------

for ($i = 1; $i -le 12; $i++) {
    $ui.KeyGrid.Children.Add((New-SlotButton -SlotName "key$i" -Caption "key$i")) | Out-Null
}
foreach ($k in 1, 2) {
    $panel = $ui["Knob$k`Panel"]
    foreach ($action in 'ccw', 'press', 'cw') {
        $label = switch ($action) { 'ccw' { 'turn left' } 'press' { 'press' } 'cw' { 'turn right' } }
        $panel.Children.Add((New-SlotButton -SlotName "knob$k.$action" -Caption $label -Width 134)) | Out-Null
    }
}

# --- Events ----------------------------------------------------------------

$ui.BtnLayer1.Add_Click({ Switch-Layer 0 })
$ui.BtnLayer2.Add_Click({ Switch-Layer 1 })
$ui.BtnLayer3.Add_Click({ Switch-Layer 2 })

$ui.BtnTheme.Add_Click({
    if ($ui.Suppress) { return }
    Set-Theme -Name $(if ($ui.Theme -eq 'dark') { 'light' } else { 'dark' })
})

$ui.TxtBinding.Add_TextChanged({
    if ($ui.Suppress) { return }
    $old = [string]$ui.Model[$ui.Layer][$ui.Slot]
    Push-UndoSlot -Stack $ui.Undo -Layer $ui.Layer -Slot $ui.Slot -Old $old -New $ui.TxtBinding.Text
    $ui.Model[$ui.Layer][$ui.Slot] = $ui.TxtBinding.Text
    Set-Dirty $true
    Update-Validation
    Update-SlotButton -SlotName $ui.Slot
    Update-ApplyState | Out-Null
})

$ui.BtnClear.Add_Click({ Set-CurrentBinding '' })

$ui.BtnPick.Add_Click({
    $choice = Show-PickList -Title 'Pick a binding' -Items (Get-PickerItems) -Owner $window
    if ($choice) { Set-CurrentBinding $choice }
})

$ui.BtnCapture.Add_Checked({
    $ui.Capturing = $true
    Set-Status 'Capture armed - press a combination. Esc leaves capture mode.' 'Accent'
})
$ui.BtnCapture.Add_Unchecked({
    $ui.Capturing = $false
    Set-Status 'Capture off.'
})

$ui.BtnCopy.Add_Click({
    $ui.Clipboard = [string]$ui.Model[$ui.Layer][$ui.Slot]
    Set-Status "Copied '$($ui.Clipboard)' from $($ui.Slot)."
})
$ui.BtnPaste.Add_Click({
    if ($null -eq $ui.Clipboard) { Set-Status 'Nothing copied yet.' 'Warn'; return }
    Set-CurrentBinding $ui.Clipboard
    Set-Status "Pasted into $($ui.Slot)."
})

$ui.BtnUndo.Add_Click({
    $result = Invoke-Undo -Stack $ui.Undo -Model $ui.Model
    if ($null -eq $result) { Set-Status 'Nothing to undo.' 'Warn'; return }
    $ui.Model = $result
    Set-Dirty $true
    Select-Slot -SlotName $ui.Slot
    Update-AllSlots
    Set-Status 'Undone.'
})
$ui.BtnRedo.Add_Click({
    $result = Invoke-Redo -Stack $ui.Undo -Model $ui.Model
    if ($null -eq $result) { Set-Status 'Nothing to redo.' 'Warn'; return }
    $ui.Model = $result
    Set-Dirty $true
    Select-Slot -SlotName $ui.Slot
    Update-AllSlots
    Set-Status 'Redone.'
})

$ui.BtnDupLayer.Add_Click({
    $targets = @()
    for ($i = 0; $i -lt 3; $i++) { if ($i -ne $ui.Layer) { $targets += "Layer $($i + 1)" } }
    $choice = Show-PickList -Title 'Copy this layer to' -Items $targets -Owner $window
    if (-not $choice) { return }

    $target = [int]($choice -replace '\D', '') - 1
    $before = Copy-Model $ui.Model
    foreach ($name in $script:SlotOrder) {
        $ui.Model[$target][$name] = [string]$ui.Model[$ui.Layer][$name]
    }
    Push-UndoSnapshot -Stack $ui.Undo -Before $before -After (Copy-Model $ui.Model) -Label 'duplicate layer'
    Set-Dirty $true
    Update-AllSlots
    Set-Status "Copied layer $($ui.Layer + 1) onto layer $($target + 1)."
})

$window.Add_PreviewKeyDown({
    param($sender, $e)

    if ($ui.Capturing) {
        # Escape leaves capture mode rather than binding itself; binding Escape
        # is still possible by typing "esc" or using Pick.
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
        return
    }

    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    $shift = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
    if (-not $ctrl) { return }

    switch ($e.Key) {
        ([System.Windows.Input.Key]::Z) { $ui.BtnUndo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true }
        ([System.Windows.Input.Key]::Y) { $ui.BtnRedo.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true }
        ([System.Windows.Input.Key]::C) { if ($shift) { $ui.BtnCopy.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true } }
        ([System.Windows.Input.Key]::V) { if ($shift) { $ui.BtnPaste.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true } }
    }
})

# --- File and profile actions ----------------------------------------------

$ui.BtnOpen.Add_Click({
    if (-not (Confirm-Discard)) { return }
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Config files (*.json)|*.json|All files (*.*)|*.*'
    $dialog.InitialDirectory = $PSScriptRoot
    if ($dialog.ShowDialog() -ne $true) { return }
    try {
        Set-Model -NewModel (Import-ModelFromFile -Path $dialog.FileName) -Label 'open config' `
            -FileLabel (Split-Path -Leaf $dialog.FileName) -Path $dialog.FileName
        Set-Dirty $false
        Set-Status "Loaded $($dialog.FileName)"
    } catch {
        Set-Status "Could not load: $($_.Exception.Message)" 'Danger'
    }
})

$ui.BtnOpenBackup.Add_Click({
    if (-not (Confirm-Discard)) { return }
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Backup files (*.json)|*.json'
    $dialog.InitialDirectory = Join-Path $PSScriptRoot 'backups'
    if ($dialog.ShowDialog() -ne $true) { return }
    try {
        Set-Model -NewModel (Import-ModelFromBackup -Path $dialog.FileName) -Label 'open backup' `
            -FileLabel ("backup: " + (Split-Path -Leaf $dialog.FileName)) -Path $null
        Set-Dirty $true
        Set-Status "Loaded backup $($dialog.FileName) as editable bindings. Save As to keep it."
    } catch {
        Set-Status "Could not load backup: $($_.Exception.Message)" 'Danger'
    }
})

$ui.BtnProfiles.Add_Click({
    $profiles = @(Get-PadProfile -Root $PSScriptRoot)
    $items = @('[ Save current as new profile ]')
    foreach ($p in $profiles) { $items += $p.Name }

    $choice = Show-PickList -Title 'Profiles' -Items $items -Owner $window
    if (-not $choice) { return }

    if ($choice -like '*Save current*') {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Profile name:', 'Save profile', 'my-profile')
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        try {
            $path = Save-PadProfile -Root $PSScriptRoot -Name $name.Trim() -Model $ui.Model
            Set-Status "Saved profile to $path" 'Ok'
        } catch {
            Set-Status "Could not save profile: $($_.Exception.Message)" 'Danger'
        }
        return
    }

    if (-not (Confirm-Discard)) { return }
    try {
        $path = Resolve-PadProfile -Root $PSScriptRoot -Name $choice
        Set-Model -NewModel (Import-ModelFromFile -Path $path) -Label 'load profile' `
            -FileLabel "profile: $choice" -Path $path
        Set-Dirty $false
        $settings = Get-AppSettings
        $settings.lastProfile = $choice
        Save-AppSettings -Settings $settings
        Set-Status "Loaded profile '$choice'."
    } catch {
        Set-Status "Could not load profile: $($_.Exception.Message)" 'Danger'
    }
})

function Save-ModelTo {
    param([string] $Path)
    ConvertTo-ConfigObject -Model $ui.Model | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $Path -Encoding UTF8
    $ui.Path = $Path
    $ui.LblFile.Text = Split-Path -Leaf $Path
    Set-Dirty $false
    Set-Status "Saved $Path" 'Ok'
}

$ui.BtnSave.Add_Click({
    if ($null -eq $ui.Path) {
        $ui.BtnSaveAs.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        return
    }
    try { Save-ModelTo -Path $ui.Path }
    catch { Set-Status "Could not save: $($_.Exception.Message)" 'Danger' }
})

$ui.BtnSaveAs.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Config files (*.json)|*.json'
    $dialog.InitialDirectory = $PSScriptRoot
    $dialog.FileName = 'config.json'
    if ($dialog.ShowDialog() -ne $true) { return }
    try { Save-ModelTo -Path $dialog.FileName }
    catch { Set-Status "Could not save: $($_.Exception.Message)" 'Danger' }
})

# --- Device actions --------------------------------------------------------

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
        Set-Model -NewModel $model -Label 'read device' -FileLabel '(from device)' -Path $null
        Set-Dirty $false
        if ($unreadable -gt 0) {
            Set-Status ("Read OK. $unreadable mouse slot(s) cannot be read back from this firmware " +
                        "and are marked '$script:UnreadableMarker' - set or clear them before applying.") 'Warn'
        } else {
            Set-Status 'Read OK.' 'Ok'
        }
    } catch {
        Set-Status "Read failed: $($_.Exception.Message)" 'Danger'
    } finally {
        if ($pad) { $pad.Dispose() }
    }
})

function Invoke-Apply {
    param([int[]] $Layers)

    if ((Update-ApplyState) -gt 0) { return }

    $scope = $(if ($Layers) { "layer $($Layers -join ', ')" } else { 'all three layers' })
    $answer = [Windows.MessageBox]::Show(
        "Write $scope to the pad?`n`nThe current on-device configuration will be backed up to backups\ first.",
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

        Write-PadConfig -Pad $pad -Config $config -Layer $Layers -OnProgress {
            param($done, $total, $label)
            Set-Status "Programming $done/$total - $label"
            Update-UiNow
        }

        Set-Status 'Verifying...'
        Update-UiNow
        $results = @(Test-PadWritten -Pad $pad -Config $config -Layer $Layers)
        $bad = @($results | Where-Object { $_.Status -eq 'Mismatch' })
        $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })

        if ($bad.Count -gt 0) {
            $first = $bad[0]
            Set-Status ("Written, but VERIFY FAILED on $($bad.Count) slot(s). " +
                        "First: layer $($first.Layer) $($first.Slot) expected '$($first.Expected)' got '$($first.Actual)'.") 'Danger'
        } else {
            $note = $(if ($skipped.Count -gt 0) { " ($($skipped.Count) mouse slot(s) skipped - they do not read back)" } else { '' })
            Set-Status "Done. $($results.Count - $skipped.Count) slot(s) verified$note. Backup: $backup" 'Ok'
        }
    } catch {
        Set-Status "Apply failed: $($_.Exception.Message)" 'Danger'
    } finally {
        if ($pad) { $pad.Dispose() }
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
        $window.IsEnabled = $true
    }
}

$ui.BtnApply.Add_Click({ Invoke-Apply -Layers $null })
$ui.BtnApplyLayer.Add_Click({ Invoke-Apply -Layers @($ui.Layer + 1) })

$ui.BtnVerify.Add_Click({
    $temp = Join-Path $env:TEMP ("macropad-verify-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $pad = $null
    try {
        ConvertTo-ConfigObject -Model $ui.Model | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $temp -Encoding UTF8
        $config = Read-PadConfigFile -Path $temp

        $window.IsEnabled = $false
        Set-Status 'Reading device to compare...'
        Update-UiNow
        $pad = Connect-Pad
        $results = @(Test-PadWritten -Pad $pad -Config $config)
        $bad = @($results | Where-Object { $_.Status -eq 'Mismatch' })
        $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })

        if ($bad.Count -eq 0) {
            $note = $(if ($skipped.Count -gt 0) { " ($($skipped.Count) mouse slot(s) skipped)" } else { '' })
            Set-Status "Device matches this config$note." 'Ok'
        } else {
            $lines = $bad | Select-Object -First 6 | ForEach-Object {
                "L$($_.Layer) $($_.Slot): want '$($_.Expected)', device has '$($_.Actual)'"
            }
            Set-Status ("$($bad.Count) difference(s): " + ($lines -join '; ')) 'Warn'
        }
    } catch {
        Set-Status "Verify failed: $($_.Exception.Message)" 'Danger'
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
        Set-Status "Restored $count reports and saved to flash." 'Ok'
    } catch {
        Set-Status "Restore failed: $($_.Exception.Message)" 'Danger'
    } finally {
        if ($pad) { $pad.Dispose() }
        $window.IsEnabled = $true
    }
})

# --- Key tester ------------------------------------------------------------

$testerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Key Tester" Width="560" Height="480" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource Bg}">
  <Window.Resources>
__STYLES__
  </Window.Resources>
  <DockPanel Margin="12">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8"
               Foreground="{DynamicResource TextDim}"
               Text="Press keys and turn the knobs on the pad. Only input from this pad is listed - typing on your main keyboard is filtered out, so anything appearing here really came from the device."/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="BtnClearLog" Content="Clear" Margin="0,0,6,0"/>
      <TextBlock x:Name="LblCount" Text="0 events" VerticalAlignment="Center"
                 Foreground="{DynamicResource TextDim}" Margin="6,0,0,0"/>
    </StackPanel>
    <ListBox x:Name="LstEvents" FontFamily="Consolas" FontSize="12"/>
  </DockPanel>
</Window>
'@

function Show-KeyTester {
    $tester = New-ThemedWindow -Xaml $testerXaml
    $tester.Owner = $window
    Set-WindowTheme -Window $tester -Name $ui.Theme | Out-Null

    $list = $tester.FindName('LstEvents')
    $count = $tester.FindName('LblCount')
    $tester.FindName('BtnClearLog').Add_Click({ $list.Items.Clear(); $count.Text = '0 events' }.GetNewClosure())

    $state = @{ Source = $null; Hook = $null; Events = 0 }

    $addEvent = {
        param([string] $Text)
        $state.Events++
        $list.Items.Insert(0, ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Text)) | Out-Null
        while ($list.Items.Count -gt 300) { $list.Items.RemoveAt($list.Items.Count - 1) }
        $count.Text = "$($state.Events) events"
    }.GetNewClosure()

    $hook = [Windows.Interop.HwndSourceHook]{
        param($hwnd, $msg, $wParam, $lParam, $handled)

        if ($msg -ne [MiniKeyboard.RawInput]::WM_INPUT) { return [IntPtr]::Zero }
        try {
            $evt = [MiniKeyboard.RawInput]::Process($lParam, $script:PadDeviceFilter)
            if ($null -eq $evt) { return [IntPtr]::Zero }

            switch ($evt.Kind) {
                'keyboard' {
                    if ($evt.KeyUp) { return [IntPtr]::Zero }   # one line per press
                    $key = [System.Windows.Input.KeyInterop]::KeyFromVirtualKey($evt.VirtualKey)
                    $name = ConvertFrom-WpfKey -Key $key
                    if ($null -eq $name) { $name = "vk 0x{0:X2}" -f $evt.VirtualKey }
                    & $addEvent "keyboard   $name"
                }
                'hid' {
                    $bytes = $evt.HidData
                    if ($bytes.Length -ge 2) {
                        $code = [int]$bytes[0] -bor ([int]$bytes[1] -shl 8)
                        if ($code -ne 0) {
                            & $addEvent ("media      " + (Get-PadMediaName -Code $code))
                        }
                    }
                }
                'mouse' {
                    if ($evt.VirtualKey -ne 0) {
                        & $addEvent ("mouse      buttons 0x{0:X4}" -f $evt.VirtualKey)
                    }
                }
            }
        } catch {
            # A tester must never take the window down.
        }
        [IntPtr]::Zero
    }.GetNewClosure()

    $tester.Add_SourceInitialized({
        $source = [Windows.Interop.HwndSource]::FromHwnd(
            (New-Object Windows.Interop.WindowInteropHelper $tester).Handle)
        $state.Source = $source
        $state.Hook = $hook
        $source.AddHook($hook)
        if (-not [MiniKeyboard.RawInput]::Register($source.Handle)) {
            & $addEvent 'FAILED to register for raw input - device attribution unavailable.'
        }
    }.GetNewClosure())

    $tester.Add_Closed({
        # Stop sinking global input the moment the window goes away.
        try { [MiniKeyboard.RawInput]::Unregister() | Out-Null } catch { }
        try { if ($state.Source) { $state.Source.RemoveHook($state.Hook) } } catch { }
    }.GetNewClosure())

    $tester.Show()
}

$ui.BtnTester.Add_Click({ Show-KeyTester })

$ui.BtnReset.Add_Click({
    # A soft replug, for when the pad has stopped responding after sleep.
    #
    # This needs elevation and the GUI deliberately does not run elevated, so
    # shell out to a UAC-prompted copy of the CLI rather than making the user
    # restart the whole window as administrator.
    $answer = [Windows.MessageBox]::Show(
        "Re-enumerate the pad? This is the software equivalent of unplugging and " +
        "replugging it, and takes a couple of seconds.`n`nYour bindings are not affected.`n`n" +
        "Windows will ask for administrator permission.",
        'Reset Device', 'OKCancel', 'Question')
    if ($answer -ne 'OK') { return }

    Set-Status 'Resetting the pad...' 'Warn'
    Update-UiNow
    try {
        $resetScript = Join-Path $PSScriptRoot 'macropad.ps1'
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                          '-File', "`"$resetScript`"", '-Reset', '-Quiet'
        if ($proc.ExitCode -eq 0) {
            Set-Status 'Pad re-enumerated. It should respond again now.' 'Ok'
        } else {
            Set-Status 'Reset failed. Unplug and replug the pad.' 'Danger'
        }
    } catch {
        # Cancelling the UAC prompt lands here; not worth an alarming message.
        Set-Status "Reset cancelled or failed: $($_.Exception.Message)" 'Danger'
    }
})

$window.Add_Closing({
    param($sender, $e)
    if (-not (Confirm-Discard)) { $e.Cancel = $true }
})

# --- Startup ---------------------------------------------------------------

$settings = Get-AppSettings
$startTheme = $settings.theme
if ($Light) { $startTheme = 'light' }
if (-not (Test-ThemeName -Name $startTheme)) { $startTheme = 'dark' }
Set-Theme -Name $startTheme

if ($Profile) {
    try { $Config = Resolve-PadProfile -Root $PSScriptRoot -Name $Profile }
    catch { Write-Warning $_.Exception.Message }
}
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
        Set-Status "Could not load $Config : $($_.Exception.Message)" 'Danger'
    }
}

Switch-Layer 0
Select-Slot -SlotName 'key1'
Update-AllSlots
Set-Dirty $false
$ui.Undo.Past.Clear()
$ui.Undo.Future.Clear()
Update-ApplyState | Out-Null

if ($SelfTest) {
    $failures = @()

    Write-Host "Self-test:" -ForegroundColor Cyan
    Write-Host "  window built        : $($window.Title)"
    Write-Host "  slot buttons        : $($ui.SlotButtons.Count) (expected 18)"
    if ($ui.SlotButtons.Count -ne 18) { $failures += 'slot button count' }

    # Every named brush must resolve in BOTH themes, or a control silently
    # keeps light chrome in dark mode.
    $brushKeys = @('Bg','Panel','PanelBorder','Text','TextDim','Accent','AccentText',
                   'Danger','Ok','Warn','SlotBg','SlotBorder','SlotSelected',
                   'InputBg','Hover','Pressed','Disabled')
    foreach ($theme in @('dark', 'light')) {
        Set-WindowTheme -Window $window -Name $theme | Out-Null
        $missing = @($brushKeys | Where-Object { $null -eq $window.Resources[$_] })
        Write-Host ("  theme '{0,-5}'      : {1}/{2} brushes" -f $theme, ($brushKeys.Count - $missing.Count), $brushKeys.Count)
        if ($missing.Count -gt 0) { $failures += "theme $theme missing: $($missing -join ',')" }
    }
    Set-WindowTheme -Window $window -Name $ui.Theme | Out-Null

    $picker = @(Get-PickerItems)
    $keys = @($picker | Where-Object { $_ -like 'key:*' }).Count
    $media = @($picker | Where-Object { $_ -like 'media:*' }).Count
    $mouse = @($picker | Where-Object { $_ -like 'mouse:*' }).Count
    Write-Host "  picker items        : $keys keys, $media media, $mouse mouse"
    if ($keys -lt 50 -or $media -lt 10 -or $mouse -lt 5) { $failures += 'picker categories' }

    # Undo must restore the previous value, including across a bulk change.
    $ui.Model[0]['key1'] = 'ctrl+c'
    Push-UndoSlot -Stack $ui.Undo -Layer 0 -Slot 'key1' -Old 'ctrl+c' -New 'ctrl+v'
    $ui.Model[0]['key1'] = 'ctrl+v'
    $undone = Invoke-Undo -Stack $ui.Undo -Model $ui.Model
    $undoOk = ($null -ne $undone -and $undone[0]['key1'] -eq 'ctrl+c')
    $redone = Invoke-Redo -Stack $ui.Undo -Model $ui.Model
    $redoOk = ($null -ne $redone -and $redone[0]['key1'] -eq 'ctrl+v')
    Write-Host "  undo / redo         : undo=$undoOk redo=$redoOk"
    if (-not $undoOk -or -not $redoOk) { $failures += 'undo/redo' }

    Write-Host "  profiles found      : $(@(Get-PadProfile -Root $PSScriptRoot).Count)"

    Write-Host "  key capture         : C -> $(ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::C)) | F13 -> $(ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::F13)) | LeftCtrl -> $(if ($null -eq (ConvertFrom-WpfKey -Key ([System.Windows.Input.Key]::LeftCtrl))) { 'null (correct)' } else { 'WRONG' })"

    Write-Host "  raw input type      : $(if ('MiniKeyboard.RawInput' -as [type]) { 'loaded' } else { 'MISSING' })"
    if (-not ('MiniKeyboard.RawInput' -as [type])) { $failures += 'RawInput' }

    # The apply path: model -> JSON -> the CLI's own parser.
    $temp = Join-Path $env:TEMP ("macropad-selftest-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        ConvertTo-ConfigObject -Model (Import-ModelFromFile -Path (Join-Path $PSScriptRoot 'config.json')) |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
        $parsed = Read-PadConfigFile -Path $temp
        $slots = 0
        foreach ($layer in $parsed.Layers) { $slots += $layer.Buttons.Count + $layer.Knobs.Count }
        Write-Host "  apply round trip    : $($parsed.Layers.Count) layers, $slots slots"
        if ($parsed.Layers.Count -ne 3 -or $slots -ne 54) { $failures += 'round trip' }
    } catch {
        Write-Host "  apply round trip    : FAILED - $($_.Exception.Message)" -ForegroundColor Red
        $failures += 'round trip'
    } finally {
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }

    $markerBlocked = -not (Test-SlotBinding -Text $script:UnreadableMarker).Ok
    Write-Host "  mouse marker blocks : $markerBlocked"
    if (-not $markerBlocked) { $failures += 'mouse marker' }

    if ($failures.Count -gt 0) {
        Write-Host "FAILED: $($failures -join '; ')" -ForegroundColor Red
        exit 1
    }
    Write-Host "PASSED" -ForegroundColor Green
    exit 0
}

$window.ShowDialog() | Out-Null
