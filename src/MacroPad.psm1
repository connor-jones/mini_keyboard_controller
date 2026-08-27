# Protocol encoding and orchestration for the CH57x/CH552 macro pad (1189:8840).
#
# Wire format: every report is exactly 65 bytes -- report ID 0x03 followed by
# 64 payload bytes, zero-padded.
#
#   Program button   03 FD <btn> <layer> <type> 00 00 00 00 00 <count> [<mod> <code>]...
#   Commit           03 FD FE FF                     (after EVERY button, then 200 ms)
#   Layer LED        03 FE B0 <layer> 08 ... byte[12] = (color << 4) | effect
#   Macro delay      03 FD 00 <layer> 05 <lo> <hi>   (16-bit LE milliseconds)
#   Save to flash    03 EF 03                        (once, at the very end)
#   Read bindings    03 FA 0F 03 <layer> 05          (expects 24 input reports)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Keymap.ps1')

if (-not ('MiniKeyboard.HidTransport' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'HidTransport.cs')
}

$script:ReportLength = 65
$script:CommitDelayMs = 200

# Opcode for binding a button. The two upstream tools disagree here -- the
# 8840-specific one uses 0xFD, ch57x's k884x backend uses 0xFE -- so it stays
# overridable rather than hard-coded.
$script:BindOpcode = 0xFD

# Some firmware indexes layers from 0 on the wire while the UI counts from 1.
$script:LayerOffset = 0

function Set-PadProtocolVariant {
    <#
    .SYNOPSIS
        Override the two protocol details that vary between firmware revisions.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('FD', 'FE')] [string] $BindOpcode,
        [ValidateRange(-1, 1)]    [int]    $LayerOffset
    )
    if ($PSBoundParameters.ContainsKey('BindOpcode')) {
        $script:BindOpcode = [byte]("0x$BindOpcode")
    }
    if ($PSBoundParameters.ContainsKey('LayerOffset')) {
        $script:LayerOffset = $LayerOffset
    }
}

function Get-PadProtocolVariant {
    [pscustomobject]@{
        BindOpcode  = '0x{0:X2}' -f $script:BindOpcode
        LayerOffset = $script:LayerOffset
    }
}

# --- Device access ---------------------------------------------------------

function Get-PadInterface {
    <#
    .SYNOPSIS
        List every HID collection the pad exposes, config channel included.
    #>
    [CmdletBinding()]
    param()
    [MiniKeyboard.HidTransport]::Enumerate($true)
}

function Connect-Pad {
    <#
    .SYNOPSIS
        Open the vendor configuration collection (usage page 0xFF00).
    #>
    [CmdletBinding()]
    param()
    [MiniKeyboard.HidTransport]::OpenConfigInterface()
}

# --- Report construction ---------------------------------------------------

function New-PadReport {
    <#
    .SYNOPSIS
        Build a zero-padded 65-byte report from its leading bytes.
    #>
    [CmdletBinding()]
    param([byte[]] $Bytes)

    if ($Bytes.Length -gt $script:ReportLength) {
        throw "Report payload is $($Bytes.Length) bytes; the maximum is $script:ReportLength."
    }
    $report = New-Object byte[] $script:ReportLength
    [Array]::Copy($Bytes, $report, $Bytes.Length)
    $report
}

function Format-PadReport {
    <#
    .SYNOPSIS
        Render a report as hex for -WhatIf output. Trailing zero padding is
        collapsed so the meaningful bytes stay readable.
    #>
    [CmdletBinding()]
    param([byte[]] $Report)

    $last = $Report.Length - 1
    while ($last -gt 0 -and $Report[$last] -eq 0) { $last-- }
    $shown = $Report[0..$last] | ForEach-Object { '{0:X2}' -f $_ }
    $text = $shown -join ' '
    if ($last -lt $Report.Length - 1) {
        $text += "  (+$($Report.Length - 1 - $last) zero bytes)"
    }
    $text
}

# --- Binding parsing -------------------------------------------------------

function ConvertTo-PadBinding {
    <#
    .SYNOPSIS
        Parse one config entry into a normalized binding descriptor.
    .DESCRIPTION
        Accepts:
          $null / '' / 'none'      -> unbound
          'a', 'f13', '<0x04>'     -> single key
          'ctrl+c', 'ctrl+shift+z' -> modified key ('-' also accepted as separator)
          @('h','e','l','l','o')   -> macro, up to 5 keypresses
          'volumeup', 'play'       -> consumer/media key
          'click', 'click(right)'  -> mouse click
          'wheel(1)', 'wheel(-1)'  -> mouse wheel
          'move(10,0)'             -> relative mouse move
          'drag(left,10,0)'        -> mouse drag
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Value,
        [string] $Context = 'binding'
    )

    if ($null -eq $Value) {
        return [pscustomobject]@{ Type = 'none'; Source = ''; Keys = @() }
    }

    # An array is always a keyboard macro.
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return [pscustomobject]@{ Type = 'none'; Source = ''; Keys = @() }
        }
        if ($items.Count -gt $script:MaxMacroKeys) {
            throw "$Context : macro has $($items.Count) keypresses; the firmware allows at most $script:MaxMacroKeys."
        }
        $keys = @()
        foreach ($item in $items) {
            $keys += (Resolve-PadKeyStroke -Text ([string]$item) -Context $Context)
        }
        return [pscustomobject]@{
            Type   = 'keyboard'
            Source = ($items -join ',')
            Keys   = $keys
        }
    }

    $text = ([string]$Value).Trim()
    if ($text -eq '' -or $text -eq 'none') {
        return [pscustomobject]@{ Type = 'none'; Source = $text; Keys = @() }
    }

    $lower = $text.ToLowerInvariant()

    # Mouse syntax is checked first: 'click' is both a mouse action and a
    # MouseButtons alias, and 'wheel(1)' must not be parsed as a key name.
    $mouse = Resolve-PadMouseAction -Text $lower -Context $Context
    if ($null -ne $mouse) {
        return [pscustomobject]@{ Type = 'mouse'; Source = $text; Mouse = $mouse; Keys = @() }
    }

    if ($script:MediaKeys.ContainsKey($lower)) {
        return [pscustomobject]@{
            Type   = 'media'
            Source = $text
            Code   = $script:MediaKeys[$lower]
            Keys   = @()
        }
    }

    # A comma-separated string is a macro too, so 'h,e,l,l,o' works inline.
    if ($lower.Contains(',')) {
        $parts = @($lower.Split(',') | Where-Object { $_.Trim() -ne '' })
        if ($parts.Count -gt $script:MaxMacroKeys) {
            throw "$Context : macro has $($parts.Count) keypresses; the firmware allows at most $script:MaxMacroKeys."
        }
        $keys = @()
        foreach ($part in $parts) {
            $keys += (Resolve-PadKeyStroke -Text $part.Trim() -Context $Context)
        }
        return [pscustomobject]@{ Type = 'keyboard'; Source = $text; Keys = $keys }
    }

    [pscustomobject]@{
        Type   = 'keyboard'
        Source = $text
        Keys   = @(Resolve-PadKeyStroke -Text $lower -Context $Context)
    }
}

function Resolve-PadKeyStroke {
    <#
    .SYNOPSIS
        Turn 'ctrl+shift+z' into a modifier byte plus a HID usage code.
    #>
    [CmdletBinding()]
    param([string] $Text, [string] $Context = 'binding')

    $text = $Text.Trim().ToLowerInvariant()
    if ($text -eq '') { throw "$Context : empty keystroke." }

    # Split on '+' or '-', but never on a literal '-'/'+' that IS the key.
    # The @() wrapper matters: -split yields a bare string for a single element,
    # and StrictMode rejects .Count on that.
    $parts = @()
    if ($text -eq '-' -or $text -eq '+') {
        $parts = @($text)
    } else {
        $parts = @($text -split '[+\-]' | Where-Object { $_ -ne '' })
        # '-' as the final key survives the split as an empty tail.
        if ($text.EndsWith('-')) { $parts += '-' }
    }

    $modifier = 0
    $keyName = $null
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = $parts[$i]
        if ($i -lt $parts.Count - 1 -and $script:Modifiers.ContainsKey($part)) {
            $modifier = $modifier -bor $script:Modifiers[$part]
        } else {
            $keyName = $part
        }
    }

    if ($null -eq $keyName) {
        # Modifier-only binding, e.g. 'alt-shift'.
        return [pscustomobject]@{ Modifier = [byte]$modifier; Code = [byte]0; Name = $text }
    }

    $code = $null
    if ($keyName -match '^<\s*(0x[0-9a-f]+|\d+)\s*>$') {
        $code = [int]($matches[1])
    } elseif ($script:Keys.ContainsKey($keyName)) {
        $code = $script:Keys[$keyName]
    } else {
        throw "$Context : unknown key '$keyName'. Run 'macropad.ps1 -ListKeys' to see what is available."
    }

    if ($code -lt 0 -or $code -gt 255) {
        throw "$Context : key code $code is out of range (0-255)."
    }

    [pscustomobject]@{ Modifier = [byte]$modifier; Code = [byte]$code; Name = $text }
}

function Resolve-PadMouseAction {
    <#
    .SYNOPSIS
        Parse mouse syntax, or return $null if the text is not a mouse action.
    #>
    [CmdletBinding()]
    param([string] $Text, [string] $Context = 'binding')

    # Peel off leading modifiers: 'ctrl-click', 'shift+wheel(1)'.
    $modifier = 0
    $body = $Text
    while ($body -match '^(ctrl|control|shift|alt|opt|option)[+\-](.+)$') {
        $modifier = $modifier -bor $script:Modifiers[$matches[1]]
        $body = $matches[2]
    }

    switch -Regex ($body) {
        '^(click|lclick|rclick|mclick)$' {
            $button = $script:MouseButtons[$matches[1]]
            return [pscustomobject]@{
                Action = $script:MouseActionClick; Modifier = [byte]$modifier
                Buttons = [byte]$button; Dx = 0; Dy = 0; Delta = 0
            }
        }
        '^click\(\s*(left|right|middle)\s*\)$' {
            return [pscustomobject]@{
                Action = $script:MouseActionClick; Modifier = [byte]$modifier
                Buttons = [byte]$script:MouseButtons[$matches[1]]; Dx = 0; Dy = 0; Delta = 0
            }
        }
        '^wheel\(\s*(-?\d+)\s*\)$' {
            return [pscustomobject]@{
                Action = $script:MouseActionWheel; Modifier = [byte]$modifier
                Buttons = [byte]0; Dx = 0; Dy = 0
                Delta = (ConvertTo-PadSignedByte -Value ([int]$matches[1]) -Context $Context -Field 'wheel delta')
            }
        }
        '^wheelup$' {
            return [pscustomobject]@{
                Action = $script:MouseActionWheel; Modifier = [byte]$modifier
                Buttons = [byte]0; Dx = 0; Dy = 0; Delta = [byte]1
            }
        }
        '^wheeldown$' {
            return [pscustomobject]@{
                Action = $script:MouseActionWheel; Modifier = [byte]$modifier
                Buttons = [byte]0; Dx = 0; Dy = 0; Delta = [byte]0xFF
            }
        }
        '^move\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)$' {
            return [pscustomobject]@{
                Action = $script:MouseActionMove; Modifier = [byte]$modifier; Buttons = [byte]0
                Dx = (ConvertTo-PadSignedByte -Value ([int]$matches[1]) -Context $Context -Field 'move dx')
                Dy = (ConvertTo-PadSignedByte -Value ([int]$matches[2]) -Context $Context -Field 'move dy')
                Delta = [byte]0
            }
        }
        '^drag\(\s*(left|right|middle)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)$' {
            return [pscustomobject]@{
                Action = $script:MouseActionMove; Modifier = [byte]$modifier
                Buttons = [byte]$script:MouseButtons[$matches[1]]
                Dx = (ConvertTo-PadSignedByte -Value ([int]$matches[2]) -Context $Context -Field 'drag dx')
                Dy = (ConvertTo-PadSignedByte -Value ([int]$matches[3]) -Context $Context -Field 'drag dy')
                Delta = [byte]0
            }
        }
    }
    $null
}

function ConvertTo-PadSignedByte {
    [CmdletBinding()]
    param([int] $Value, [string] $Context = 'binding', [string] $Field = 'value')

    if ($Value -lt -128 -or $Value -gt 127) {
        throw "$Context : $Field is $Value; the firmware range is -128 to 127."
    }
    if ($Value -lt 0) { return [byte](256 + $Value) }
    [byte]$Value
}

# --- Bind report encoding --------------------------------------------------

function New-PadBindReport {
    <#
    .SYNOPSIS
        Encode one button binding as a 65-byte report.
    #>
    [CmdletBinding()]
    param(
        [byte] $ButtonId,
        [int]  $Layer,
        [psobject] $Binding
    )

    $wireLayer = [byte]($Layer + $script:LayerOffset)
    $head = @([byte]0x03, [byte]$script:BindOpcode, [byte]$ButtonId, $wireLayer)

    switch ($Binding.Type) {
        'none' {
            # Type byte still says "keyboard"; a count of zero clears the key.
            $bytes = $head + @([byte]$script:MacroTypeKeyboard, 0, 0, 0, 0, 0, [byte]0)
        }
        'keyboard' {
            $payload = @()
            foreach ($stroke in $Binding.Keys) {
                $payload += @([byte]$stroke.Modifier, [byte]$stroke.Code)
            }
            $bytes = $head + @([byte]$script:MacroTypeKeyboard, 0, 0, 0, 0, 0, [byte]$Binding.Keys.Count) + $payload
        }
        'media' {
            # Offset 10 is a count of 1, then the 16-bit consumer usage little-endian.
            # Confirmed by read-back: "03 FA 13 01 02 00 00 00 00 00 01 EA 00" = volume down.
            $lo = [byte]($Binding.Code -band 0xFF)
            $hi = [byte](($Binding.Code -shr 8) -band 0xFF)
            $bytes = $head + @([byte]$script:MacroTypeMedia, 0, 0, 0, 0, 0, [byte]1, $lo, $hi)
        }
        'mouse' {
            $m = $Binding.Mouse
            $payload = switch ($m.Action) {
                $script:MouseActionClick { @([byte]$m.Action, [byte]$m.Modifier, [byte]$m.Buttons) }
                $script:MouseActionMove  { @([byte]$m.Action, [byte]$m.Modifier, [byte]$m.Buttons, [byte]$m.Dx, [byte]$m.Dy) }
                $script:MouseActionWheel { @([byte]$m.Action, [byte]$m.Modifier, [byte]0, [byte]0, [byte]0, [byte]$m.Delta) }
                default { throw "Unhandled mouse action $($m.Action)." }
            }
            $bytes = $head + @([byte]$script:MacroTypeMouse, 0, 0, 0, 0, 0) + $payload
        }
        default { throw "Unhandled binding type '$($Binding.Type)'." }
    }

    New-PadReport -Bytes ([byte[]]$bytes)
}

function New-PadLedReport {
    [CmdletBinding()]
    param([int] $Layer, [string] $Color, [string] $Effect)

    $colorName = $Color.ToLowerInvariant()
    $effectName = $Effect.ToLowerInvariant()
    if (-not $script:LedColors.ContainsKey($colorName)) {
        throw "Unknown LED color '$Color'. Valid: $(($script:LedColors.Keys | Sort-Object) -join ', ')."
    }
    if (-not $script:LedEffects.ContainsKey($effectName)) {
        throw "Unknown LED effect '$Effect'. Valid: $(($script:LedEffects.Keys | Sort-Object) -join ', ')."
    }

    $code = [byte](($script:LedColors[$colorName] -shl 4) -bor $script:LedEffects[$effectName])
    $wireLayer = [byte]($Layer + $script:LayerOffset)

    # byte[12] carries the packed colour/effect code.
    New-PadReport -Bytes ([byte[]]@(
        0x03, 0xFE, 0xB0, $wireLayer, 0x08, 0, 0, 0, 0, 0, 0x01, 0x00, $code
    ))
}

function New-PadDelayReport {
    [CmdletBinding()]
    param([int] $Layer, [int] $DelayMs)

    if ($DelayMs -lt 0 -or $DelayMs -gt 65535) {
        throw "Macro delay is $DelayMs ms; the valid range is 0-65535."
    }
    $wireLayer = [byte]($Layer + $script:LayerOffset)
    New-PadReport -Bytes ([byte[]]@(
        0x03, [byte]$script:BindOpcode, 0x00, $wireLayer, 0x05,
        [byte]($DelayMs -band 0xFF), [byte](($DelayMs -shr 8) -band 0xFF)
    ))
}

function New-PadCommitReport {
    New-PadReport -Bytes ([byte[]]@(0x03, [byte]$script:BindOpcode, 0xFE, 0xFF))
}

function New-PadSaveReport {
    New-PadReport -Bytes ([byte[]]@(0x03, 0xEF, 0x03))
}

function New-PadReadReport {
    [CmdletBinding()]
    param([int] $Layer)
    $wireLayer = [byte]($Layer + $script:LayerOffset)
    New-PadReport -Bytes ([byte[]]@(0x03, 0xFA, 0x0F, 0x03, $wireLayer, 0x05))
}

# --- Read-back -------------------------------------------------------------

function Read-PadLayer {
    <#
    .SYNOPSIS
        Ask the pad for one layer's bindings and collect the raw input reports.
    .DESCRIPTION
        The response encoding is the least-documented part of this protocol, so
        reports are captured verbatim as hex. That is enough for a byte-exact
        restore even where the decode is imperfect.
    #>
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [int] $Layer,
        [int] $ExpectedReports = 24,
        [int] $TimeoutMs = 1000
    )

    if (-not $Pad.CanRead) {
        Write-Warning "Device opened write-only; cannot read layer $Layer."
        return @()
    }

    $Pad.FlushInput()
    $Pad.Write((New-PadReadReport -Layer $Layer))

    $reports = @()
    for ($i = 0; $i -lt $ExpectedReports; $i++) {
        $data = $Pad.Read($TimeoutMs)
        if ($null -eq $data) { break }
        $reports += , ([byte[]]$data)
    }
    $reports
}

# Reverse lookups, built once, for decoding reports back into names.
$script:ReverseKeys = @{}
foreach ($name in $script:Keys.Keys) {
    $code = $script:Keys[$name]
    # Prefer the longest spelling so 'escape' wins over 'esc'.
    if (-not $script:ReverseKeys.ContainsKey($code) -or $name.Length -gt $script:ReverseKeys[$code].Length) {
        $script:ReverseKeys[$code] = $name
    }
}
$script:ReverseMedia = @{}
foreach ($name in $script:MediaKeys.Keys) {
    $code = $script:MediaKeys[$name]
    if (-not $script:ReverseMedia.ContainsKey($code) -or $name.Length -gt $script:ReverseMedia[$code].Length) {
        $script:ReverseMedia[$code] = $name
    }
}
$script:ReverseButtons = @{}
foreach ($name in $script:ButtonIds.Keys) {
    $script:ReverseButtons[$script:ButtonIds[$name]] = $name
}

function ConvertFrom-PadModifier {
    [CmdletBinding()]
    param([byte] $Value)

    if ($Value -eq 0) { return @() }
    $order = @('ctrl', 'shift', 'alt', 'win', 'rctrl', 'rshift', 'ralt', 'rwin')
    $names = @()
    for ($bit = 0; $bit -lt 8; $bit++) {
        if ($Value -band (1 -shl $bit)) { $names += $order[$bit] }
    }
    $names
}

function ConvertFrom-PadReport {
    <#
    .SYNOPSIS
        Decode one captured report into a human-readable binding.
    .DESCRIPTION
        Layout, confirmed by reading this device back:
          [2] button id   [3] layer   [4] macro type
          [10] count      [11..] payload
    #>
    [CmdletBinding()]
    param([byte[]] $Report)

    if ($Report.Length -lt 13) {
        return [pscustomobject]@{ Button = '?'; Layer = 0; Type = 'short'; Binding = '' }
    }

    $buttonId = $Report[2]
    $name = if ($script:ReverseButtons.ContainsKey([int]$buttonId)) {
        $script:ReverseButtons[[int]$buttonId]
    } else {
        'slot 0x{0:X2}' -f $buttonId
    }

    $type = $Report[4]
    $count = $Report[10]
    $binding = ''
    $typeName = 'unknown'

    switch ($type) {
        $script:MacroTypeKeyboard {
            $typeName = 'keyboard'
            $strokes = @()
            for ($i = 0; $i -lt $count; $i++) {
                $offset = 11 + ($i * 2)
                if ($offset + 1 -ge $Report.Length) { break }
                $mod = $Report[$offset]
                $code = [int]$Report[$offset + 1]
                $parts = @(ConvertFrom-PadModifier -Value $mod)
                if ($code -ne 0) {
                    if ($script:ReverseKeys.ContainsKey($code)) {
                        $parts += $script:ReverseKeys[$code]
                    } else {
                        $parts += ('<0x{0:X2}>' -f $code)
                    }
                }
                if ($parts.Count -gt 0) { $strokes += ($parts -join '+') }
            }
            $binding = if ($strokes.Count -gt 0) { $strokes -join ',' } else { '(unbound)' }
        }
        $script:MacroTypeMedia {
            $typeName = 'media'
            $code = [int]$Report[11] -bor ([int]$Report[12] -shl 8)
            $binding = if ($script:ReverseMedia.ContainsKey($code)) {
                $script:ReverseMedia[$code]
            } else {
                '<consumer 0x{0:X4}>' -f $code
            }
        }
        $script:MacroTypeMouse {
            $typeName = 'mouse'
            $binding = 'action 0x{0:X2} mod 0x{1:X2} buttons 0x{2:X2}' -f $Report[10], $Report[11], $Report[12]
        }
        default {
            $binding = '(type 0x{0:X2})' -f $type
        }
    }

    [pscustomobject]@{
        Button  = $name
        Layer   = [int]$Report[3]
        Type    = $typeName
        Binding = $binding
    }
}

function Export-PadConfig {
    <#
    .SYNOPSIS
        Dump every layer off the device into a restorable backup object.
    #>
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [int] $Layers = 3,
        [string] $Note = ''
    )

    $dump = @()
    for ($layer = 1; $layer -le $Layers; $layer++) {
        Write-Verbose "Reading layer $layer..."
        # The device returns slots in an arbitrary order, so sort by button id
        # to keep dumps stable and diffable between captures.
        $reports = @(Read-PadLayer -Pad $Pad -Layer $layer |
            Sort-Object { if ($_.Length -gt 2) { [int]$_[2] } else { 999 } })

        $hex = @()
        $decoded = @()
        foreach ($r in $reports) {
            $hex += (($r | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
            $d = ConvertFrom-PadReport -Report $r
            $decoded += ('{0,-12} {1,-9} {2}' -f $d.Button, $d.Type, $d.Binding)
        }
        $dump += [pscustomobject]@{
            layer       = $layer
            reportCount = $reports.Count
            decoded     = $decoded
            reports     = $hex
        }
    }

    [pscustomobject]@{
        device    = '1189:8840'
        capturedAt = (Get-Date).ToString('o')
        note      = $Note
        protocol  = (Get-PadProtocolVariant)
        layers    = $dump
    }
}

# --- Write path ------------------------------------------------------------

function Send-PadReport {
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [byte[]] $Report,
        [switch] $DryRun,
        [string] $Label = ''
    )

    if ($DryRun) {
        if ($Label -ne '') {
            '{0,-22} {1}' -f $Label, (Format-PadReport -Report $Report)
        } else {
            Format-PadReport -Report $Report
        }
        return
    }
    $Pad.Write($Report)
}

function Set-PadButton {
    <#
    .SYNOPSIS
        Write one binding and commit it. The 200 ms settle is required -- the
        firmware drops writes that arrive during a commit.
    #>
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [byte] $ButtonId,
        [int]  $Layer,
        [psobject] $Binding,
        [switch] $DryRun,
        [string] $Label = ''
    )

    $report = New-PadBindReport -ButtonId $ButtonId -Layer $Layer -Binding $Binding
    Send-PadReport -Pad $Pad -Report $report -DryRun:$DryRun -Label $Label
    Send-PadReport -Pad $Pad -Report (New-PadCommitReport) -DryRun:$DryRun -Label 'commit'
    if (-not $DryRun) { Start-Sleep -Milliseconds $script:CommitDelayMs }
}

function Set-PadLayerLed {
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [int] $Layer,
        [string] $Color,
        [string] $Effect,
        [switch] $DryRun
    )

    $report = New-PadLedReport -Layer $Layer -Color $Color -Effect $Effect
    Send-PadReport -Pad $Pad -Report $report -DryRun:$DryRun -Label "layer $Layer led"
    Send-PadReport -Pad $Pad -Report (New-PadCommitReport) -DryRun:$DryRun -Label 'commit'
    if (-not $DryRun) { Start-Sleep -Milliseconds $script:CommitDelayMs }
}

function Save-PadFlash {
    [CmdletBinding()]
    param([MiniKeyboard.HidTransport] $Pad, [switch] $DryRun)

    Send-PadReport -Pad $Pad -Report (New-PadSaveReport) -DryRun:$DryRun -Label 'save to flash'
    if (-not $DryRun) { Start-Sleep -Milliseconds $script:CommitDelayMs }
}

# --- Config file handling --------------------------------------------------

function Read-PadConfigFile {
    <#
    .SYNOPSIS
        Load and fully validate a config file, resolving every binding.
    .DESCRIPTION
        Validation is complete before any device I/O happens, so a typo in
        layer 3 cannot leave the pad half-programmed.
    #>
    [CmdletBinding()]
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    # Tolerate // comments so the shipped config can document itself.
    $stripped = [regex]::Replace($raw, '(?m)^\s*//.*$', '')

    try {
        $json = $stripped | ConvertFrom-Json
    } catch {
        throw "Could not parse $Path as JSON: $($_.Exception.Message)"
    }

    if ($null -eq $json.PSObject.Properties['layers']) {
        throw "Config must have a top-level 'layers' array."
    }

    $layers = @()
    $layerIndex = 0
    foreach ($layerNode in @($json.layers)) {
        $layerIndex++
        if ($layerIndex -gt $script:LayerCount) {
            throw "Config defines more than $script:LayerCount layers."
        }
        $ctx = "layer $layerIndex"

        $buttons = @()
        if ($null -ne $layerNode.PSObject.Properties['buttons']) {
            $entries = @($layerNode.buttons)
            if ($entries.Count -gt $script:KeyCount) {
                throw "$ctx : $($entries.Count) buttons defined; the pad has $script:KeyCount."
            }
            for ($i = 0; $i -lt $entries.Count; $i++) {
                $buttons += [pscustomobject]@{
                    Name     = "key$($i + 1)"
                    ButtonId = [byte]$script:ButtonIds["key$($i + 1)"]
                    Binding  = (ConvertTo-PadBinding -Value $entries[$i] -Context "$ctx key$($i + 1)")
                }
            }
        }

        $knobs = @()
        if ($null -ne $layerNode.PSObject.Properties['knobs']) {
            $knobNodes = @($layerNode.knobs)
            if ($knobNodes.Count -gt $script:KnobCount) {
                throw "$ctx : $($knobNodes.Count) knobs defined; the pad has $script:KnobCount."
            }
            for ($k = 0; $k -lt $knobNodes.Count; $k++) {
                $knobNumber = $k + 1
                foreach ($action in @('ccw', 'press', 'cw')) {
                    $node = $knobNodes[$k]
                    $value = $null
                    if ($null -ne $node.PSObject.Properties[$action]) {
                        $value = $node.$action
                    }
                    $name = "knob$knobNumber.$action"
                    $knobs += [pscustomobject]@{
                        Name     = $name
                        ButtonId = [byte]$script:ButtonIds[$name]
                        Binding  = (ConvertTo-PadBinding -Value $value -Context "$ctx $name")
                    }
                }
            }
        }

        $ledColor = $null
        $ledEffect = 'static'
        if ($null -ne $layerNode.PSObject.Properties['led']) {
            $led = $layerNode.led
            if ($led -is [string]) {
                $ledColor = [string]$led
            } else {
                if ($null -ne $led.PSObject.Properties['color'])  { $ledColor  = [string]$led.color }
                if ($null -ne $led.PSObject.Properties['effect']) { $ledEffect = [string]$led.effect }
            }
            if ($null -ne $ledColor -and -not $script:LedColors.ContainsKey($ledColor.ToLowerInvariant())) {
                throw "$ctx : unknown LED color '$ledColor'."
            }
            if (-not $script:LedEffects.ContainsKey($ledEffect.ToLowerInvariant())) {
                throw "$ctx : unknown LED effect '$ledEffect'."
            }
        }

        $delay = $null
        if ($null -ne $layerNode.PSObject.Properties['macroDelayMs']) {
            $delay = [int]$layerNode.macroDelayMs
            if ($delay -lt 0 -or $delay -gt 65535) {
                throw "$ctx : macroDelayMs is $delay; the valid range is 0-65535."
            }
        }

        $layers += [pscustomobject]@{
            Number       = $layerIndex
            Buttons      = $buttons
            Knobs        = $knobs
            LedColor     = $ledColor
            LedEffect    = $ledEffect
            MacroDelayMs = $delay
        }
    }

    if ($layers.Count -eq 0) {
        throw "Config defines no layers."
    }

    [pscustomobject]@{
        Path   = (Resolve-Path -LiteralPath $Path).Path
        Layers = $layers
    }
}

function Write-PadConfig {
    <#
    .SYNOPSIS
        Apply a validated config to the device.
    #>
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [psobject] $Config,
        [switch] $DryRun
    )

    $total = 0
    foreach ($layer in $Config.Layers) {
        $total += $layer.Buttons.Count + $layer.Knobs.Count
        if ($null -ne $layer.LedColor) { $total++ }
        if ($null -ne $layer.MacroDelayMs) { $total++ }
    }

    $done = 0
    foreach ($layer in $Config.Layers) {
        if ($null -ne $layer.MacroDelayMs) {
            $report = New-PadDelayReport -Layer $layer.Number -DelayMs $layer.MacroDelayMs
            Send-PadReport -Pad $Pad -Report $report -DryRun:$DryRun -Label "layer $($layer.Number) delay"
            Send-PadReport -Pad $Pad -Report (New-PadCommitReport) -DryRun:$DryRun -Label 'commit'
            if (-not $DryRun) { Start-Sleep -Milliseconds $script:CommitDelayMs }
            $done++
        }

        foreach ($entry in (@($layer.Buttons) + @($layer.Knobs))) {
            $done++
            if (-not $DryRun) {
                Write-Progress -Activity 'Programming macro pad' `
                    -Status "Layer $($layer.Number): $($entry.Name) -> $($entry.Binding.Source)" `
                    -PercentComplete ([int](100 * $done / [Math]::Max($total, 1)))
            }
            Set-PadButton -Pad $Pad -ButtonId $entry.ButtonId -Layer $layer.Number `
                -Binding $entry.Binding -DryRun:$DryRun `
                -Label "L$($layer.Number) $($entry.Name)"
        }

        if ($null -ne $layer.LedColor) {
            $done++
            Set-PadLayerLed -Pad $Pad -Layer $layer.Number -Color $layer.LedColor `
                -Effect $layer.LedEffect -DryRun:$DryRun
        }
    }

    Save-PadFlash -Pad $Pad -DryRun:$DryRun
    if (-not $DryRun) {
        Write-Progress -Activity 'Programming macro pad' -Completed
    }
}

function Restore-PadConfig {
    <#
    .SYNOPSIS
        Replay a backup's captured reports back onto the device byte-for-byte.
    #>
    [CmdletBinding()]
    param(
        [MiniKeyboard.HidTransport] $Pad,
        [string] $Path,
        [switch] $DryRun
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Backup file not found: $Path"
    }
    $backup = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    $replayed = 0
    foreach ($layer in @($backup.layers)) {
        foreach ($hex in @($layer.reports)) {
            $bytes = [byte[]]($hex -split '\s+' | Where-Object { $_ -ne '' } | ForEach-Object { [Convert]::ToByte($_, 16) })
            if ($bytes.Length -ne $script:ReportLength) {
                Write-Warning "Skipping malformed report in layer $($layer.layer): $($bytes.Length) bytes."
                continue
            }
            # Captured reports arrive with the READ opcode (0xFA) at offset 1.
            # Swapping in the bind opcode turns each one back into a write; the
            # rest of the layout (button, layer, type, count, payload) already
            # matches a bind report byte-for-byte.
            $bytes[0] = 0x03
            $bytes[1] = [byte]$script:BindOpcode
            Send-PadReport -Pad $Pad -Report $bytes -DryRun:$DryRun -Label "L$($layer.layer) replay"
            Send-PadReport -Pad $Pad -Report (New-PadCommitReport) -DryRun:$DryRun -Label 'commit'
            if (-not $DryRun) { Start-Sleep -Milliseconds $script:CommitDelayMs }
            $replayed++
        }
    }

    Save-PadFlash -Pad $Pad -DryRun:$DryRun
    $replayed
}

# --- Introspection ---------------------------------------------------------

function Get-PadKeyNames {
    [pscustomobject]@{
        Keys      = ($script:Keys.Keys      | Sort-Object)
        Modifiers = ($script:Modifiers.Keys | Sort-Object)
        Media     = ($script:MediaKeys.Keys | Sort-Object)
        Mouse     = @('click', 'click(left|right|middle)', 'wheelup', 'wheeldown',
                      'wheel(N)', 'move(dx,dy)', 'drag(left|right|middle,dx,dy)')
        LedColors = ($script:LedColors.Keys  | Sort-Object)
        LedEffects = ($script:LedEffects.Keys | Sort-Object)
        Buttons   = ($script:ButtonIds.Keys  | Sort-Object)
    }
}

Export-ModuleMember -Function @(
    'Get-PadInterface', 'Connect-Pad',
    'Set-PadProtocolVariant', 'Get-PadProtocolVariant',
    'ConvertTo-PadBinding', 'Resolve-PadKeyStroke', 'Resolve-PadMouseAction',
    'New-PadBindReport', 'New-PadLedReport', 'New-PadDelayReport',
    'New-PadCommitReport', 'New-PadSaveReport', 'New-PadReadReport', 'New-PadReport',
    'Format-PadReport',
    'Read-PadLayer', 'Export-PadConfig', 'ConvertFrom-PadReport', 'ConvertFrom-PadModifier',
    'Set-PadButton', 'Set-PadLayerLed', 'Save-PadFlash',
    'Read-PadConfigFile', 'Write-PadConfig', 'Restore-PadConfig',
    'Get-PadKeyNames'
)
