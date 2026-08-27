# Maps WPF's System.Windows.Input.Key enum onto the key names in Keymap.ps1,
# so the GUI can turn a real keystroke into a binding string.
#
# This is a UI concern only -- nothing here touches the device protocol. The
# names produced are exactly the ones config.json accepts.

Set-StrictMode -Version Latest

# Key enum name -> our binding name. Anything absent is not bindable by capture
# and must be picked from a dropdown instead.
$script:WpfKeyNames = @{
    # Letters and digits are handled by pattern below; these are the specials.
    'Return'        = 'enter'
    'Enter'         = 'enter'
    'Escape'        = 'esc'
    'Back'          = 'backspace'
    'Tab'           = 'tab'
    'Space'         = 'space'
    'CapsLock'      = 'capslock'

    'Left'          = 'left'
    'Right'         = 'right'
    'Up'            = 'up'
    'Down'          = 'down'

    'Home'          = 'home'
    'End'           = 'end'
    'PageUp'        = 'pageup'
    'PageDown'      = 'pagedown'
    'Prior'         = 'pageup'      # WPF's older aliases for PageUp/PageDown
    'Next'          = 'pagedown'
    'Insert'        = 'insert'
    'Delete'        = 'delete'

    'PrintScreen'   = 'printscreen'
    'Snapshot'      = 'printscreen'
    'Scroll'        = 'scrolllock'
    'Pause'         = 'pause'
    'NumLock'       = 'numlock'
    'Apps'          = 'menu'

    # Punctuation. WPF reports these positionally as Oem*, which matches how the
    # device thinks about keys -- a position, not the character it produces.
    'OemMinus'         = 'minus'
    'OemPlus'          = 'equal'
    'OemOpenBrackets'  = 'leftbracket'
    'OemCloseBrackets' = 'rightbracket'
    'Oem6'             = 'rightbracket'
    'OemPipe'          = 'backslash'
    'Oem5'             = 'backslash'
    'OemSemicolon'     = 'semicolon'
    'Oem1'             = 'semicolon'
    'OemQuotes'        = 'quote'
    'Oem7'             = 'quote'
    'OemTilde'         = 'grave'
    'Oem3'             = 'grave'
    'OemComma'         = 'comma'
    'OemPeriod'        = 'period'
    'OemQuestion'      = 'slash'
    'Oem2'             = 'slash'

    # Numpad
    'NumPad0' = 'kp0'; 'NumPad1' = 'kp1'; 'NumPad2' = 'kp2'; 'NumPad3' = 'kp3'
    'NumPad4' = 'kp4'; 'NumPad5' = 'kp5'; 'NumPad6' = 'kp6'; 'NumPad7' = 'kp7'
    'NumPad8' = 'kp8'; 'NumPad9' = 'kp9'
    'Divide'   = 'kpslash'
    'Multiply' = 'kpstar'
    'Subtract' = 'kpminus'
    'Add'      = 'kpplus'
    'Decimal'  = 'kpdot'
}

# Keys that are only ever modifiers -- pressing one alone is not a binding.
$script:WpfModifierKeys = @(
    'LeftCtrl', 'RightCtrl', 'LeftShift', 'RightShift',
    'LeftAlt', 'RightAlt', 'LWin', 'RWin', 'System', 'None'
)

function ConvertFrom-WpfKey {
    <#
    .SYNOPSIS
        Turn a System.Windows.Input.Key into one of our key names, or $null.
    #>
    [CmdletBinding()]
    param($Key)

    $name = [string]$Key

    if ($script:WpfModifierKeys -contains $name) { return $null }
    if ($script:WpfKeyNames.ContainsKey($name)) { return $script:WpfKeyNames[$name] }

    # A-Z arrive as their own letter.
    if ($name -match '^[A-Z]$') { return $name.ToLowerInvariant() }
    # Top-row digits arrive as D0-D9.
    if ($name -match '^D([0-9])$') { return $matches[1] }
    # F1-F24 map straight through.
    if ($name -match '^F([1-9]|1[0-9]|2[0-4])$') { return $name.ToLowerInvariant() }

    $null
}

function ConvertFrom-WpfKeystroke {
    <#
    .SYNOPSIS
        Compose a binding string from a key press plus the live modifier state.
    .DESCRIPTION
        Returns $null when only modifiers are held, so the caller can keep
        waiting rather than recording a half-formed chord.

        The Windows key is deliberately read from the keyboard directly:
        [Keyboard]::Modifiers does NOT report it, so win+... could never be
        captured otherwise.
    #>
    [CmdletBinding()]
    param($Key)

    $keyName = ConvertFrom-WpfKey -Key $Key
    if ($null -eq $keyName) { return $null }

    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $parts = @()
    if ($mods -band [System.Windows.Input.ModifierKeys]::Control) { $parts += 'ctrl' }
    if ($mods -band [System.Windows.Input.ModifierKeys]::Shift)   { $parts += 'shift' }
    if ($mods -band [System.Windows.Input.ModifierKeys]::Alt)     { $parts += 'alt' }

    if ([System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::LWin) -or
        [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::RWin)) {
        $parts += 'win'
    }

    $parts += $keyName
    $parts -join '+'
}
