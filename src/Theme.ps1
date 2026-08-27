# Colour palettes for the configurator.
#
# The XAML references every colour as a DynamicResource, so switching theme is
# just swapping the brush objects in Window.Resources -- no rebuild, no reload.
#
# WPF's stock control chrome does NOT follow a dark background: a Button left
# to its default template stays light grey whatever you set Background to. The
# window therefore defines explicit ControlTemplates that bind to these names.

Set-StrictMode -Version Latest

$script:ThemePalettes = @{
    dark = @{
        Bg           = '#FF1E1E22'
        Panel        = '#FF26262C'
        PanelBorder  = '#FF3A3A44'
        Text         = '#FFE6E6EC'
        TextDim      = '#FF9A9AA8'
        Accent       = '#FF4C8DFF'
        AccentText   = '#FFFFFFFF'
        Danger       = '#FFFF6B6B'
        Ok           = '#FF4ADE80'
        Warn         = '#FFFFB454'
        SlotBg       = '#FF2E2E36'
        SlotBorder   = '#FF3A3A44'
        SlotSelected = '#FF4C8DFF'
        InputBg      = '#FF17171B'
        Hover        = '#FF35353F'
        Pressed      = '#FF43434F'
        Disabled     = '#FF55555F'
    }
    light = @{
        Bg           = '#FFF4F4F6'
        Panel        = '#FFFFFFFF'
        PanelBorder  = '#FFD8D8DE'
        Text         = '#FF1E1E22'
        TextDim      = '#FF666677'
        Accent       = '#FF2563EB'
        AccentText   = '#FFFFFFFF'
        Danger       = '#FFC62828'
        Ok           = '#FF117700'
        Warn         = '#FFB25000'
        SlotBg       = '#FFFFFFFF'
        SlotBorder   = '#FFD8D8DE'
        SlotSelected = '#FF2563EB'
        InputBg      = '#FFFFFFFF'
        Hover        = '#FFECECF2'
        Pressed      = '#FFDEDEE6'
        Disabled     = '#FFAAAAB4'
    }
}

function Get-ThemeNames { $script:ThemePalettes.Keys | Sort-Object }

function Test-ThemeName {
    param([string] $Name)
    $script:ThemePalettes.ContainsKey(([string]$Name).ToLowerInvariant())
}

function Get-ThemeBrush {
    <#
    .SYNOPSIS
        One brush from a palette, for code that colours things imperatively.
    #>
    param([string] $Theme, [string] $Key)

    $palette = $script:ThemePalettes[([string]$Theme).ToLowerInvariant()]
    if ($null -eq $palette -or -not $palette.ContainsKey($Key)) {
        throw "No brush '$Key' in theme '$Theme'."
    }
    $brush = New-Object Windows.Media.SolidColorBrush (
        [Windows.Media.ColorConverter]::ConvertFromString($palette[$Key]))
    $brush.Freeze()
    $brush
}

function Set-WindowTheme {
    <#
    .SYNOPSIS
        Apply a palette by replacing the named brushes in Window.Resources.
    #>
    param($Window, [string] $Name)

    $key = ([string]$Name).ToLowerInvariant()
    if (-not $script:ThemePalettes.ContainsKey($key)) {
        throw "Unknown theme '$Name'. Available: $((Get-ThemeNames) -join ', ')."
    }

    # Assign through IDictionary, NOT $Window.Resources[$name] = $brush.
    #
    # PowerShell's parameterised-property setter coerces a SolidColorBrush down
    # to a Color on the way into a ResourceDictionary. Any element binding the
    # key to a Brush property then fails with "'#FF17171B' is not a valid value
    # for property 'Background'" -- which reads like a string problem but is
    # really Color.ToString(). The explicit IDictionary indexer stores the brush
    # unchanged, and handles replacement, so themes can be swapped repeatedly.
    $resources = [System.Collections.IDictionary]$Window.Resources

    foreach ($brushName in $script:ThemePalettes[$key].Keys) {
        $brush = New-Object Windows.Media.SolidColorBrush (
            [Windows.Media.ColorConverter]::ConvertFromString($script:ThemePalettes[$key][$brushName]))
        $brush.Freeze()
        $resources.Item($brushName) = $brush
    }
    $key
}
