# mini_keyboard_controller

Configure a cheap CH57x/CH552 macro pad (USB **1189:8840**, 12 keys + 2 knobs) from Windows —
**no vendor software, no driver replacement, no admin rights.**

The usual open-source tools for this hardware talk to it over libusb, which on Windows means
installing the **USBDK** kernel driver or swapping the device to WinUSB with Zadig. None of that is
necessary. The pad's configuration channel is an ordinary vendor-defined HID collection served by
Windows' in-box `HidUsb` driver, so the standard HID API reaches it directly.

Pure PowerShell 5.1 plus a small inline C# P/Invoke layer. Nothing to install.

## Quick start

Double-click **`MacroPad GUI.cmd`**, or from a prompt:

```powershell
.\macropad-gui.ps1
```

Click a key, press the combination you want, hit **Apply to Pad**. Or use the CLI:

```powershell
.\macropad.ps1 -Probe                      # find the pad, confirm the config channel
.\macropad.ps1 -Dump                       # read current bindings into backups\
.\macropad.ps1 -Apply config.json -WhatIf  # preview the exact reports
.\macropad.ps1 -Apply config.json          # back up, program, save to flash
.\macropad.ps1 -ListKeys                   # every supported key / media / mouse action
.\macropad.ps1 -Restore backups\factory.json
```

`-Apply` always dumps the current on-device config to `backups\` first, unless you pass `-NoBackup`.

## The GUI

`macropad-gui.ps1` is a WPF window over the same module — it contains no protocol code of its own,
and applying goes through the identical `Read-PadConfigFile` → `Write-PadConfig` path the CLI uses,
so the two cannot drift.

- **Read Device** pulls the pad's current configuration into the grid.
- Select a slot, then either click **Press keys…** and type the combination, or pick from the
  **Media** / **Mouse** dropdowns, or type a binding directly.
- **Apply to Pad** backs up the current on-device config to `backups\` first, then writes.

Two behaviours worth knowing:

- **Apply is disabled while any slot anywhere is invalid**, not just the one on screen — a bad
  binding on layer 3 blocks the whole write.
- **Mouse slots cannot be read back** from this firmware. After *Read Device* they show
  `(not readable)` and deliberately fail validation, so you must set or clear each one. Without
  that, *Read Device* followed by *Apply* would silently wipe your mouse bindings.

Some chords can't be captured because Windows consumes them first — `alt+tab`, `win+l`,
`ctrl+alt+del`. Type those into the binding box instead.

Run `.\macropad-gui.ps1 -SelfTest` to verify the window builds, key capture maps correctly, and the
model round-trips through the config parser — no device or human needed.

## Layout

```
    key1   key2   key3   key4          (knob1)
    key5   key6   key7   key8
    key9   key10  key11  key12         (knob2)
```

If your two knobs turn out to be swapped relative to this, swap the two entries in the `knobs`
array — nothing else changes.

## Binding syntax

| Form | Example |
|---|---|
| Single key | `"a"`, `"f13"`, `"enter"` |
| Modified key | `"ctrl+c"`, `"ctrl+shift+t"`, `"shift+win+s"` |
| Macro (≤5 keypresses) | `["h","e","l","l","o"]` or `"h,e,l,l,o"` |
| Media key | `"volumeup"`, `"playpause"`, `"browserback"` |
| Mouse click | `"click"`, `"click(right)"`, `"ctrl+click"` |
| Mouse wheel | `"wheelup"`, `"wheel(-1)"` |
| Mouse move / drag | `"move(10,0)"`, `"drag(left,10,0)"` |
| Raw HID usage | `"<0x04>"` |
| Unbound | `""` |

Modifiers are `ctrl`, `shift`, `alt`, `win` (plus `rctrl`/`rshift`/`ralt`/`rwin`). Media keys are a
separate macro type in firmware and **cannot** take modifiers or appear inside a macro.

Bindings name a **key position**, not a character. On a non-US layout, `"a"` produces whatever that
physical key types.

### LEDs

**This pad has no RGB backlight.** It has three discrete indicator LEDs (L1/L2/L3) that the
firmware drives itself to show the active layer. There is nothing for software to colour, so
`config.json` ships without any `led` keys.

The `led` support is still implemented for the backlit models in this family, which accept
`03 FE B0 <layer> 08 …`. Colors are `off, red, orange, yellow, green, cyan, blue, purple`; effects
are `off, static, ripple, wave, reactive, white`. On this device the command is accepted and does
nothing visible — treat the exact byte layout as **unverified**, since it could not be tested here.

### Layer 2 is F13–F24 on purpose

Windows binds nothing to F13–F24, so no application will ever collide with them. Bind them here,
then have AutoHotkey or PowerToys listen for them to trigger arbitrary PC actions.

## Protocol notes

Everything below was **verified against this device** by reading its factory configuration back,
not taken on faith from upstream tools. Two of those tools disagree with what the hardware
actually does — see the corrections at the end.

All reports are 65 bytes: report ID `0x03` plus 64 payload bytes, zero-padded.

| Operation | Bytes |
|---|---|
| Program button | `03 FD <btn> <layer> <type> 00 00 00 00 00 <count> [<mod> <code>]…` |
| Commit | `03 FD FE FF` — required after **every** button, then a 200 ms settle |
| Layer LED | `03 FE B0 <layer> 08 …` with byte `[12] = (color << 4) \| effect` |
| Macro delay | `03 FD 00 <layer> 05 <lo> <hi>` (16-bit LE ms) |
| Save to flash | `03 EF 03` — once, at the end |
| Read bindings | `03 FA 0F 03 <layer> 05` → 24 input reports |

Field offsets: `[2]` button id, `[3]` layer (**1-based, sent as-is**), `[4]` macro type
(`01` keyboard, `02` media, `03` mouse), `[10]` count, `[11…]` payload.

Read-back responses use the same layout with `0xFA` at `[1]`, which is why `-Restore` rewrites that
one byte to turn a captured report back into a write.

### Slot map

The firmware exposes a fixed 24-slot table shared across every model in this family:

```
0x01..0x0F   15 key slots    (this pad uses 12; 0x0D-0x0F are spare)
0x10..0x18    3 knobs x 3    (this pad uses 2;  0x16-0x18 are spare)
```

Each knob is `ccw, press, cw` in ascending order.

### Corrections to upstream tools

Confirmed by reading the factory config off this device:

1. **Media bindings put a count of `01` at offset 10**, with the 16-bit consumer usage at 11/12.
   Encoding a `00` there produces a dead key.
2. **The second knob's rotation IDs are *not* reversed.** Factory mapping reads
   `0x13` volumedown / `0x14` mute / `0x15` volumeup — plain ascending `ccw, press, cw`, same as the
   first knob. Applying the reversal that `ch57x-keyboard-tool` documents inverts your volume knob.
3. Byte `[6]` is `0x05` on some factory layer-1 keys and `0x00` elsewhere; purpose unknown. `0x00`
   works everywhere, including on keys the factory shipped with `0x05`.
4. The LED command's byte layout could not be confirmed on this device, which has no backlight to
   observe. Do not trust it without testing on backlit hardware.

## Files

| Path | Role |
|---|---|
| `macropad-gui.ps1` | WPF configurator |
| `MacroPad GUI.cmd` | Double-click launcher for the GUI |
| `src/WpfKeyMap.ps1` | WPF key enum → binding names, for key capture |
| `macropad.ps1` | CLI entry point |
| `src/HidTransport.cs` | P/Invoke HID layer: enumerate, open, write, read |
| `src/MacroPad.psm1` | Protocol encoding, config parsing, orchestration |
| `src/Keymap.ps1` | HID usage tables and slot map |
| `config.json` | Your bindings |
| `backups/factory.json` | The pad's original configuration — keep this |

## Troubleshooting

**"No macro pad found"** — check `-Probe`. The pad must show a collection with usage page `0xFF00`.

**Keys do nothing after applying** — the bind opcode differs across firmware revisions. Try
`-BindOpcode FE`. If layers land one off, try `-LayerOffset 1`. Then `-Dump` to see what actually
stuck.

**Recovering a bad config** — `-Restore backups\factory.json`. The config channel is a separate USB
interface whose enumeration does not depend on what is in flash, so a bad binding write can never
cost you the ability to write again. This pad is not practically brickable.
