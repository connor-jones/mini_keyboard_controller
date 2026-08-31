# Model and state for the configurator: the binding grid, undo history,
# profiles, and persisted settings.
#
# The model is deliberately just binding strings in config.json syntax. That is
# what lets the GUI reuse Read-PadConfigFile / Write-PadConfig unchanged instead
# of growing a second interpretation of what a binding means.
#
# Pure logic only -- nothing here touches WPF, so -SelfTest covers all of it.

Set-StrictMode -Version Latest

# Slot order, matching the physical layout and the config.json field order.
$script:SlotOrder = @(
    'key1', 'key2', 'key3', 'key4',
    'key5', 'key6', 'key7', 'key8',
    'key9', 'key10', 'key11', 'key12',
    'knob1.ccw', 'knob1.press', 'knob1.cw',
    'knob2.ccw', 'knob2.press', 'knob2.cw'
)

# Mouse slots do not survive a read from the device. They come back marked with
# this rather than blank, so that Read Device followed by Apply cannot quietly
# wipe whatever mouse bindings were on the pad.
$script:UnreadableMarker = '(not readable)'

$script:SettingsDir  = Join-Path $env:APPDATA 'mini_keyboard_controller'
$script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'

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

function Copy-Model {
    param($Model)
    $copy = @()
    foreach ($slots in $Model) {
        $new = [ordered]@{}
        foreach ($name in $script:SlotOrder) { $new[$name] = [string]$slots[$name] }
        $copy += , $new
    }
    $copy
}

function ConvertTo-BindingText {
    # A macro arrives from JSON as an array; the editor shows it comma-separated.
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        return (@($Value) -join ',')
    }
    [string]$Value
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

function Import-ModelFromBackup {
    <#
    .SYNOPSIS
        Decode a backups\*.json capture into an editable model.
    .DESCRIPTION
        Lets a backup be opened and edited rather than only replayed blind.
        Uses the same ConvertFrom-PadReport decoder the dump display uses.
    #>
    param([string] $Path)

    $backup = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $model = New-EmptyModel

    foreach ($layer in @($backup.layers)) {
        $index = [int]$layer.layer - 1
        if ($index -lt 0 -or $index -gt 2) { continue }

        foreach ($hex in @($layer.reports)) {
            $bytes = [byte[]]($hex -split '\s+' | Where-Object { $_ -ne '' } |
                ForEach-Object { [Convert]::ToByte($_, 16) })
            if ($bytes.Length -lt 13) { continue }

            $decoded = ConvertFrom-PadReport -Report $bytes
            if ($script:SlotOrder -notcontains $decoded.Button) { continue }   # spare slots

            $model[$index][$decoded.Button] = if ($decoded.Type -eq 'mouse') {
                $script:UnreadableMarker
            } elseif ($decoded.Binding -eq '(unbound)') {
                ''
            } else {
                $decoded.Binding
            }
        }
    }
    $model
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

# --- Undo history ----------------------------------------------------------
#
# Records single-slot edits. Bulk operations (paste layer, load) push a whole
# model snapshot instead, so one Ctrl+Z undoes the whole operation rather than
# leaving the grid half-reverted.

function New-UndoStack {
    [pscustomobject]@{ Past = New-Object System.Collections.ArrayList
                       Future = New-Object System.Collections.ArrayList }
}

function Push-UndoSlot {
    param($Stack, [int] $Layer, [string] $Slot, [string] $Old, [string] $New)

    if ($Old -eq $New) { return }
    $Stack.Past.Add([pscustomobject]@{
        Kind = 'slot'; Layer = $Layer; Slot = $Slot; Old = $Old; New = $New }) | Out-Null
    $Stack.Future.Clear()
}

function Push-UndoSnapshot {
    param($Stack, $Before, $After, [string] $Label = 'bulk change')

    $Stack.Past.Add([pscustomobject]@{
        Kind = 'snapshot'; Before = $Before; After = $After; Label = $Label }) | Out-Null
    $Stack.Future.Clear()
}

function Invoke-Undo {
    <#
    .OUTPUTS
        The model to adopt, or $null when there is nothing to undo.
    #>
    param($Stack, $Model)

    if ($Stack.Past.Count -eq 0) { return $null }
    $entry = $Stack.Past[$Stack.Past.Count - 1]
    $Stack.Past.RemoveAt($Stack.Past.Count - 1)
    $Stack.Future.Add($entry) | Out-Null

    if ($entry.Kind -eq 'snapshot') { return (Copy-Model $entry.Before) }
    $Model[$entry.Layer][$entry.Slot] = $entry.Old
    $Model
}

function Invoke-Redo {
    param($Stack, $Model)

    if ($Stack.Future.Count -eq 0) { return $null }
    $entry = $Stack.Future[$Stack.Future.Count - 1]
    $Stack.Future.RemoveAt($Stack.Future.Count - 1)
    $Stack.Past.Add($entry) | Out-Null

    if ($entry.Kind -eq 'snapshot') { return (Copy-Model $entry.After) }
    $Model[$entry.Layer][$entry.Slot] = $entry.New
    $Model
}

# --- Profiles --------------------------------------------------------------

function Get-ProfileDirectory {
    param([string] $Root)
    Join-Path $Root 'profiles'
}

function Get-PadProfile {
    <#
    .SYNOPSIS
        List saved profiles (profiles\*.json) by name.
    #>
    param([string] $Root)

    $dir = Get-ProfileDirectory -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($_.Name); Path = $_.FullName }
        }
}

function Resolve-PadProfile {
    param([string] $Root, [string] $Name)

    $match = Get-PadProfile -Root $Root | Where-Object { $_.Name -eq $Name }
    if (-not $match) {
        $available = (Get-PadProfile -Root $Root | ForEach-Object { $_.Name }) -join ', '
        if (-not $available) { $available = '(none saved)' }
        throw "No profile named '$Name'. Available: $available"
    }
    $match.Path
}

function Save-PadProfile {
    param([string] $Root, [string] $Name, $Model)

    if ($Name -notmatch '^[A-Za-z0-9 _-]+$') {
        throw "Profile name '$Name' contains characters that are not safe in a filename."
    }
    $dir = Get-ProfileDirectory -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Join-Path $dir "$Name.json"
    ConvertTo-ConfigObject -Model $Model | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

# --- Settings --------------------------------------------------------------

function Get-AppSettings {
    # skipSleepCheck is 'yes' once the user has told the startup check to stop
    # offering the sleep fix. Stored as a string so the loader below, which
    # coerces every value with [string], round-trips it unchanged.
    $defaults = @{ theme = 'dark'; lastProfile = ''; lastConfig = ''; skipSleepCheck = '' }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $defaults }
    try {
        $loaded = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($defaults.Keys)) {
            if ($null -ne $loaded.PSObject.Properties[$key]) { $defaults[$key] = [string]$loaded.$key }
        }
    } catch {
        # A corrupt settings file must never stop the app starting.
    }
    $defaults
}

function Save-AppSettings {
    param($Settings)

    try {
        if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
            New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null
        }
        [pscustomobject]$Settings | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {
        # Persisting preferences is a convenience, never a reason to fail.
    }
}
