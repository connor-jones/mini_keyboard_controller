# mini_keyboard_controller

Configure a cheap CH57x/CH552 macro pad (USB **1189:8840**, 12 keys + 2 knobs) from Windows —
**no vendor software, no driver replacement, no admin rights.**

The usual open-source tools for this hardware talk to it over libusb, which on Windows means
installing the **USBDK** kernel driver or swapping the device to WinUSB with Zadig. None of that is
necessary. The pad's configuration channel is an ordinary vendor-defined HID collection served by
Windows' in-box `HidUsb` driver, so the standard HID API reaches it directly.

Pure PowerShell 5.1 plus a small inline C# P/Invoke layer. Nothing to install.

## Quick start

Double-click **`MacroPad-GUI.cmd`**, or from a prompt:

```powershell
.\macropad-gui.ps1
```

Click a key, press the combination you want, hit **Apply to Pad**. Or use the CLI:

```powershell
.\macropad.ps1 -Probe                      # find the pad, confirm the config channel
.\macropad.ps1 -Dump                       # read current bindings into backups\
.\macropad.ps1 -Dump -AsConfig config.json # ...and write them out as an editable config
.\macropad.ps1 -Apply config.json -WhatIf  # preview the exact reports
.\macropad.ps1 -Apply config.json          # back up, program, save to flash
.\macropad.ps1 -ListKeys                   # every supported key / media / mouse action
.\macropad.ps1 -Restore backups\factory.json

.\macropad.ps1 -Apply config.json -Verify  # write, then read back and confirm it took
.\macropad.ps1 -Apply config.json -Layer 1 # one layer only, ~5s instead of ~15s
.\macropad.ps1 -Compare config.json        # diff the device against a config, writing nothing
.\macropad.ps1 -Profiles                   # list saved profiles
.\macropad.ps1 -Apply gaming               # -Apply takes a profile name or a file path

.\macropad.ps1 -PowerStatus                # what is still allowed to suspend the pad
.\macropad.ps1 -FixSleep                   # stop it dying after sleep (admin, once)
.\macropad.ps1 -Reset                      # soft replug, no reaching for the cable (admin)
```

`-Verify` and `-Compare` exit non-zero if the device does not match, so they work in a script.

`-Apply` always dumps the current on-device config to `backups\` first, unless you pass `-NoBackup`.

## The GUI

Opens **dark by default**. The toggle in the top right switches to light and the choice is
remembered in `%APPDATA%\mini_keyboard_controller\settings.json`; `-Light` forces light for one run.


`macropad-gui.ps1` is a WPF window over the same module — it contains no protocol code of its own,
and applying goes through the identical `Read-PadConfigFile` → `Write-PadConfig` path the CLI uses,
so the two cannot drift.

- **Read Device** pulls the pad's current configuration into the grid.
- Select a slot, then either click **Press keys…** and type the combination, click **Pick…** to
  browse every supported key / media / mouse action, or type a binding directly.
- **Apply All Layers** backs up to `backups\` first, writes, then reads back and verifies.
  **Apply Layer N** does one layer in about a third of the time.
- **Verify** compares the pad against what is on screen without writing anything.
- **Open Backup…** loads any `backups\*.json` as *editable* bindings rather than replaying it blind.
- **Profiles…** saves and loads named configs from `profiles\`.

Shortcuts: `Ctrl+Z` / `Ctrl+Y` undo and redo, `Ctrl+Shift+C` / `Ctrl+Shift+V` copy and paste a
binding between slots. **Duplicate this layer to…** copies a whole layer in one step.

### Key tester

**Key Tester** opens a window listing what the pad actually sends as you press it. It uses the Raw
Input API and filters on the device name, so input from your main keyboard is excluded — anything
appearing in that list genuinely came from the pad. Useful for confirming a binding took without
switching to Notepad, and for working out whether layers 2 and 3 are reachable on a pad with no
layer-switch button.

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

### LEDs — this unit has none fitted

**Settled by inspection and testing: this board has no LEDs soldered anywhere.** The L1/L2/L3
indicator pads are unpopulated, and the key switches are not backlit. There is also no layer-switch
button on the board.

Eight backlight command variants were swept across all three layers with nothing visible:

```
03 FE B0 <layer> 08 00 00 00 00 00 01 00 <code>    code = 11, 71, 01, 12, 14, 05, 81
03 FE B0 <layer> 08 00 00 00 00 00 01 11 00        (code moved to byte 11)
```

So the `led` config keys are a **no-op on this hardware** and `config.json` ships without them. The
support remains for backlit models in this family: colors `off, red, orange, yellow, green, cyan,
blue, purple`, effects `off, static, ripple, wave, reactive, white`, packed as
`(color << 4) | effect` at byte 12. Treat that layout as **unverified** — it could not be confirmed
here, because there was nothing to observe.

Do not spend time re-investigating this. It is a populated-components question, not a protocol one.

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

## Dying after sleep

The pad stops responding to keys and knobs after the machine has been asleep, and only a physical
unplug brings it back. Nothing is logged in Event Viewer, because from Windows' point of view
nothing failed: the device suspended, resumed, and reported no error. **The CH552 firmware just
does not restart its HID reporting after a resume.** Only a USB re-enumeration fixes it.

`-FixSleep` is a one-off, elevated, and does two independent things:

1. **Stops Windows suspending the pad at all.** Three separate switches control this and they live
   in three different places — `SelectiveSuspendEnabled` (REG_BINARY, not a DWORD),
   `EnhancedPowerManagementEnabled` and `AllowIdleIrpInD3` under the interface's `Device Parameters`
   key, plus the Device Manager *"allow the computer to turn off this device"* checkbox, which is
   not in the registry at all but is the `MSPower_DeviceEnable` WMI class. All four are cleared, on
   both USB interfaces. The **machine-wide** USB selective suspend power-plan setting is deliberately
   left alone: turning that off would stop every USB device on the system idling down to work around
   one misbehaving pad.
2. **Re-enumerates the pad automatically after every resume**, via a scheduled task running as
   SYSTEM so it neither prompts for UAC nor flashes up a console. That covers system sleep, where
   the device is dropped to D2 regardless of any of the settings above.

Step 1 alone fixes idle; step 2 is what covers actual sleep. `-PowerStatus` shows the current state
of all of it, and `-UndoFixSleep` removes the task.

The GUI checks this on startup and offers to apply it if anything is outstanding, so the fix reaches
people who hit the problem rather than only those who read this file. *Cancel* on that prompt means
never ask again (`skipSleepCheck` in the settings file).

**The task is given an explicit security descriptor** so standard users can read it. A task
registered to run as SYSTEM gets a default ACL granting Users nothing, and an unelevated
`Get-ScheduledTask` then returns *nothing* — indistinguishable from the task not existing. Since the
GUI runs unelevated and asks "is the fix installed?" on every start, without this it would nag about
a fix that was already in place. Users get read and execute only; write access to a task running as
SYSTEM would be a privilege escalation, not a convenience.

`-Reset` does the re-enumeration on demand — the software equivalent of unplugging, about 2.5
seconds, bindings untouched. It is also the **Reset Device** button in the GUI, which shells out to
an elevated copy of the CLI rather than running the whole window as administrator.

### Do not use Disable-PnpDevice on this pad

Worth knowing if you extend this. The reset uses `pnputil /restart-device`, **not**
`Disable-PnpDevice` / `Enable-PnpDevice`.

The pad reports device capabilities `0x94` — `Removable` and `SurpriseRemovalOK`, but *not*
`HardwareDisabled`. `Disable-PnpDevice` therefore fails on it with a bare **"Not supported"** — but
only *after* having already written the disabled flag. Nothing looks wrong at that point. The next
restart then brings the device up in **problem code 22 (CM_PROB_DISABLED)**, where it stays across
reboots, and unplugging does not clear it. `Enable-PnpDevice` is what recovers it.

So the reset never disables anything. It restarts, then polls for the config channel, and if the
node comes back in a problem state it clears that with `Enable-PnpDevice` — the one recovery action
that cannot leave the device worse off than it found it. `pnputil` prints "Device restarted
successfully" and exits 0 even when the node ends up disabled, so its exit code is not trusted on
its own.

## PowerShell traps worth knowing

Three bugs in this codebase came from the same class of problem and cost real time. If you extend
it, watch for these:

**Variable names are case-insensitive**, so a `foreach ($layer in …)` loop *rebinds* an `[int[]] $Layer`
parameter, and a local `$dump` rebinds a `-Dump` switch. Both produce baffling type-conversion errors
on the second iteration. Loop variables here are named `$layerConfig` and `$snapshot` for that reason.

**`$dict[$key] = $brush` on a `ResourceDictionary` silently coerces a `SolidColorBrush` down to a
`Color`.** Every element binding that key to a Brush property then throws
`'#FF17171B' is not a valid value for property 'Background'` — which reads like a string problem but
is `Color.ToString()`. Assign through `([System.Collections.IDictionary]$dict).Item($key) = $brush`
instead; see `Set-WindowTheme` in `src/Theme.ps1`.

**Passing a here-string containing double quotes to a native command** (e.g. `git commit -m`) gets
re-tokenised by PowerShell and splits the argument. Write the text to a file and use `-F`, and use
`[IO.File]::WriteAllText` with a no-BOM encoding — `Set-Content -Encoding UTF8` prepends a BOM that
ends up in the commit subject.

## Files

| Path | Role |
|---|---|
| `macropad-gui.ps1` | WPF configurator |
| `MacroPad-GUI.cmd` | Double-click launcher for the GUI |
| `src/Theme.ps1` | Dark and light palettes |
| `src/GuiModel.ps1` | Model, undo history, profiles, settings (no WPF — used by the CLI too) |
| `src/WpfKeyMap.ps1` | WPF key enum → binding names, for key capture |
| `src/RawInput.cs` | Raw Input P/Invoke, so the key tester can attribute input to the pad |
| `src/DevicePower.ps1` | Suspend settings, soft replug, after-sleep reset task (the only elevated code) |
| `profiles/` | Saved named configs |
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

**The pad stops responding after the machine sleeps** — run `.\macropad.ps1 -FixSleep` once, from
an elevated prompt. See below for what it does and why.

**Recovering a bad config** — `-Restore backups\factory.json`. The config channel is a separate USB
interface whose enumeration does not depend on what is in flash, so a bad binding write can never
cost you the ability to write again. This pad is not practically brickable.
