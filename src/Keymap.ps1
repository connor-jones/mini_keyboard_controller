# Lookup tables for the CH57x/CH552 macro pad. Data only -- no logic lives here.
#
# Key codes are USB HID Keyboard/Keypad page (0x07) usage IDs. These identify a
# physical key position, not the character it produces: on a non-US layout,
# binding "a" gives you whatever that key types.

Set-StrictMode -Version Latest

# --- Device identity -------------------------------------------------------

$script:PadVid = 0x1189
$script:PadPid = 0x8840

# --- Physical layout: button IDs used on the wire --------------------------
#
# The firmware exposes a fixed 24-slot table shared across every model in the
# family, confirmed by reading this device back:
#
#   0x01..0x0F   15 key slots   (this pad populates 12; 0x0D-0x0F are spare)
#   0x10..0x18    3 knobs x 3   (this pad populates 2; 0x16-0x18 are spare)
#
# Each knob runs ccw, press, cw in ascending order. Some upstream tools claim
# the second knob's rotation IDs are reversed -- they are not on this firmware.
# Verified against the factory mapping, which reads:
#   0x10 prev / 0x11 play / 0x12 next     and     0x13 voldown / 0x14 mute / 0x15 volup
# Reversing 0x13/0x15 would invert the volume knob.

$script:ButtonIds = @{
    'key1'  = 0x01; 'key2'  = 0x02; 'key3'  = 0x03; 'key4'  = 0x04
    'key5'  = 0x05; 'key6'  = 0x06; 'key7'  = 0x07; 'key8'  = 0x08
    'key9'  = 0x09; 'key10' = 0x0A; 'key11' = 0x0B; 'key12' = 0x0C

    'knob1.ccw' = 0x10; 'knob1.press' = 0x11; 'knob1.cw' = 0x12
    'knob2.ccw' = 0x13; 'knob2.press' = 0x14; 'knob2.cw' = 0x15
}

$script:KeyCount  = 12
$script:KnobCount = 2
$script:LayerCount = 3
$script:MaxMacroKeys = 5

# --- Modifiers -------------------------------------------------------------

$script:Modifiers = @{
    'ctrl'   = 0x01; 'control' = 0x01
    'shift'  = 0x02
    'alt'    = 0x04; 'opt'     = 0x04; 'option' = 0x04
    'win'    = 0x08; 'meta'    = 0x08; 'cmd'    = 0x08; 'super' = 0x08
    'rctrl'  = 0x10
    'rshift' = 0x20
    'ralt'   = 0x40; 'altgr'   = 0x40
    'rwin'   = 0x80; 'rmeta'   = 0x80; 'rcmd'  = 0x80
}

# --- Keyboard usage IDs (HID page 0x07) ------------------------------------

$script:Keys = @{
    'a' = 0x04; 'b' = 0x05; 'c' = 0x06; 'd' = 0x07; 'e' = 0x08; 'f' = 0x09
    'g' = 0x0A; 'h' = 0x0B; 'i' = 0x0C; 'j' = 0x0D; 'k' = 0x0E; 'l' = 0x0F
    'm' = 0x10; 'n' = 0x11; 'o' = 0x12; 'p' = 0x13; 'q' = 0x14; 'r' = 0x15
    's' = 0x16; 't' = 0x17; 'u' = 0x18; 'v' = 0x19; 'w' = 0x1A; 'x' = 0x1B
    'y' = 0x1C; 'z' = 0x1D

    '1' = 0x1E; '2' = 0x1F; '3' = 0x20; '4' = 0x21; '5' = 0x22
    '6' = 0x23; '7' = 0x24; '8' = 0x25; '9' = 0x26; '0' = 0x27

    'enter' = 0x28; 'return' = 0x28
    'esc'   = 0x29; 'escape' = 0x29
    'backspace' = 0x2A; 'bksp' = 0x2A
    'tab'   = 0x2B
    'space' = 0x2C; 'spacebar' = 0x2C

    'minus' = 0x2D; '-' = 0x2D
    'equal' = 0x2E; '=' = 0x2E
    'leftbracket' = 0x2F; '[' = 0x2F
    'rightbracket' = 0x30; ']' = 0x30
    'backslash' = 0x31; '\' = 0x31
    'semicolon' = 0x33; ';' = 0x33
    'quote' = 0x34; "'" = 0x34
    'grave' = 0x35; '`' = 0x35
    'comma' = 0x36; ',' = 0x36
    'period' = 0x37; '.' = 0x37
    'slash' = 0x38; '/' = 0x38
    'capslock' = 0x39

    'f1' = 0x3A; 'f2' = 0x3B; 'f3'  = 0x3C; 'f4'  = 0x3D
    'f5' = 0x3E; 'f6' = 0x3F; 'f7'  = 0x40; 'f8'  = 0x41
    'f9' = 0x42; 'f10' = 0x43; 'f11' = 0x44; 'f12' = 0x45

    'printscreen' = 0x46; 'prtsc' = 0x46
    'scrolllock' = 0x47
    'pause' = 0x48
    'insert' = 0x49; 'ins' = 0x49
    'home' = 0x4A
    'pageup' = 0x4B; 'pgup' = 0x4B
    'delete' = 0x4C; 'del' = 0x4C
    'end' = 0x4D
    'pagedown' = 0x4E; 'pgdn' = 0x4E

    'right' = 0x4F; 'left' = 0x50; 'down' = 0x51; 'up' = 0x52

    'numlock' = 0x53
    'kpslash' = 0x54; 'kpstar' = 0x55; 'kpminus' = 0x56; 'kpplus' = 0x57
    'kpenter' = 0x58
    'kp1' = 0x59; 'kp2' = 0x5A; 'kp3' = 0x5B; 'kp4' = 0x5C; 'kp5' = 0x5D
    'kp6' = 0x5E; 'kp7' = 0x5F; 'kp8' = 0x60; 'kp9' = 0x61; 'kp0' = 0x62
    'kpdot' = 0x63

    'menu' = 0x65; 'application' = 0x65

    # F13-F24 are unbound on stock Windows, which makes them ideal targets for
    # a host-side listener: nothing else on the system will fire on them.
    'f13' = 0x68; 'f14' = 0x69; 'f15' = 0x6A; 'f16' = 0x6B
    'f17' = 0x6C; 'f18' = 0x6D; 'f19' = 0x6E; 'f20' = 0x6F
    'f21' = 0x70; 'f22' = 0x71; 'f23' = 0x72; 'f24' = 0x73
}

# --- Consumer/media usages (HID page 0x0C), sent as 16-bit little-endian ----
#
# These cannot be combined with modifiers or mixed into a keyboard macro; the
# firmware treats a media binding as its own macro type.

$script:MediaKeys = @{
    'play'        = 0x00CD; 'playpause' = 0x00CD
    'next'        = 0x00B5; 'nexttrack' = 0x00B5
    'prev'        = 0x00B6; 'previoustrack' = 0x00B6
    'stop'        = 0x00B7
    'mute'        = 0x00E2
    'volumeup'    = 0x00E9; 'volup'   = 0x00E9
    'volumedown'  = 0x00EA; 'voldown' = 0x00EA
    'brightnessup'   = 0x006F
    'brightnessdown' = 0x0070
    'mediaplayer' = 0x0183
    'email'       = 0x018A
    'calculator'  = 0x0192; 'calc' = 0x0192
    'explorer'    = 0x0194; 'mycomputer' = 0x0194
    'lock'        = 0x019E; 'screenlock' = 0x019E
    'browsersearch'  = 0x0221
    'browserhome'    = 0x0223
    'browserback'    = 0x0224
    'browserforward' = 0x0225
    'browserrefresh' = 0x0227
}

# --- Mouse -----------------------------------------------------------------

$script:MouseButtons = @{
    'left'   = 0x01; 'lclick' = 0x01; 'click' = 0x01
    'right'  = 0x02; 'rclick' = 0x02
    'middle' = 0x04; 'mclick' = 0x04
}

# Macro-type discriminators, written at offset 4 of a bind report.
$script:MacroTypeKeyboard = 0x01
$script:MacroTypeMedia    = 0x02
$script:MacroTypeMouse    = 0x03

# Mouse action discriminators.
$script:MouseActionClick = 0x01
$script:MouseActionWheel = 0x03
$script:MouseActionMove  = 0x05

# --- LEDs ------------------------------------------------------------------
#
# One byte encodes both: (color << 4) | effect

$script:LedColors = @{
    'off' = 0; 'red' = 1; 'orange' = 2; 'yellow' = 3
    'green' = 4; 'cyan' = 5; 'blue' = 6; 'purple' = 7
}

$script:LedEffects = @{
    'off' = 0; 'static' = 1; 'ripple' = 2
    'wave' = 3; 'reactive' = 4; 'white' = 5
}
