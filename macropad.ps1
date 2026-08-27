<#
.SYNOPSIS
    Configure a CH57x/CH552 mini macro pad (USB 1189:8840) from Windows, with
    no vendor software, no driver replacement, and no elevation.

.DESCRIPTION
    The pad's configuration channel is an ordinary vendor-defined HID collection
    (usage page 0xFF00) served by Windows' in-box HidUsb driver, so everything
    here runs through the standard HID API.

.EXAMPLE
    .\macropad.ps1 -Probe
    Show every HID collection the pad exposes and confirm the config channel.

.EXAMPLE
    .\macropad.ps1 -Dump
    Read the current on-device bindings into backups\.

.EXAMPLE
    .\macropad.ps1 -Apply config.json -WhatIf
    Print the exact reports that would be sent, without touching the device.

.EXAMPLE
    .\macropad.ps1 -Apply config.json
    Back up the current config, then program the pad and save to flash.

.EXAMPLE
    .\macropad.ps1 -Restore backups\factory.json
    Replay a captured backup byte-for-byte.
#>
[CmdletBinding(DefaultParameterSetName = 'Probe')]
param(
    # Enumerate the pad's HID collections and report the config channel.
    [Parameter(ParameterSetName = 'Probe')]
    [switch] $Probe,

    # Read current bindings off the device into a backup file.
    [Parameter(ParameterSetName = 'Dump')]
    [switch] $Dump,

    # Parse and encode a config without opening the device.
    [Parameter(ParameterSetName = 'Validate', Mandatory = $true)]
    [string] $Validate,

    # Program the pad from a config file, or a profile name from profiles\.
    [Parameter(ParameterSetName = 'Apply', Mandatory = $true)]
    [string] $Apply,

    # Write only these layers. Omit for all three.
    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(1, 3)]
    [int[]] $Layer,

    # After writing, read back and confirm the pad matches.
    [Parameter(ParameterSetName = 'Apply')]
    [switch] $Verify,

    # Compare a config against the device without writing anything.
    [Parameter(ParameterSetName = 'Compare', Mandatory = $true)]
    [string] $Compare,

    # List the saved profiles in profiles\.
    [Parameter(ParameterSetName = 'Profiles')]
    [switch] $Profiles,

    # Replay a backup captured by -Dump.
    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [string] $Restore,

    # Print every supported key, modifier, media and mouse action.
    [Parameter(ParameterSetName = 'ListKeys')]
    [switch] $ListKeys,

    # Show the reports that would be sent instead of sending them.
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Restore')]
    [Alias('DryRun')]
    [switch] $WhatIf,

    # Skip the automatic pre-flight backup (not recommended).
    [Parameter(ParameterSetName = 'Apply')]
    [switch] $NoBackup,

    # Where to write the backup file.
    [Parameter(ParameterSetName = 'Dump')]
    [Parameter(ParameterSetName = 'Apply')]
    [string] $BackupPath,

    # Also write what is on the pad out as an editable config file.
    [Parameter(ParameterSetName = 'Dump')]
    [string] $AsConfig,

    # Firmware revisions disagree on the bind opcode; override if needed.
    [ValidateSet('FD', 'FE')]
    [string] $BindOpcode,

    # Some firmware indexes layers from 0 on the wire.
    [ValidateRange(-1, 1)]
    [int] $LayerOffset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\MacroPad.psm1') -Force -DisableNameChecking

# Pure logic (model, profiles); no WPF, so it loads fine outside the GUI.
. (Join-Path $PSScriptRoot 'src\GuiModel.ps1')

function Resolve-ConfigPath {
    <#
    .SYNOPSIS
        Accept either a path or a profile name, so -Apply gaming works as well
        as -Apply .\config.json.
    #>
    param([string] $Value)

    if (Test-Path -LiteralPath $Value) { return (Resolve-Path -LiteralPath $Value).Path }
    try {
        return Resolve-PadProfile -Root $PSScriptRoot -Name $Value
    } catch {
        throw "'$Value' is neither a file nor a saved profile. $($_.Exception.Message)"
    }
}

function Show-VerifyResult {
    param($Results)

    $results = @($Results)
    $bad = @($results | Where-Object { $_.Status -eq 'Mismatch' })
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })
    $matched = @($results | Where-Object { $_.Status -eq 'Match' })

    Write-Host ""
    Write-Host "Verify: $($matched.Count) matched, $($bad.Count) mismatched, $($skipped.Count) skipped." -ForegroundColor Cyan
    if ($skipped.Count -gt 0) {
        Write-Host "  Skipped slots are mouse bindings, which this firmware does not read back." -ForegroundColor DarkGray
    }
    foreach ($entry in $bad) {
        Write-Host ("  L{0} {1,-12} want '{2}'  device has '{3}'" -f `
            $entry.Layer, $entry.Slot, $entry.Expected, $entry.Actual) -ForegroundColor Red
    }
    $bad.Count
}

if ($PSBoundParameters.ContainsKey('BindOpcode')) {
    Set-PadProtocolVariant -BindOpcode $BindOpcode
}
if ($PSBoundParameters.ContainsKey('LayerOffset')) {
    Set-PadProtocolVariant -LayerOffset $LayerOffset
}

function Get-BackupFilePath {
    param([string] $Explicit)

    if ($Explicit) {
        $path = $Explicit
    } else {
        $path = Join-Path (Join-Path $PSScriptRoot 'backups') `
            ("{0}.json" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }

    # Ensure the parent directory exists for explicit paths too, not just the default.
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path
}

function Save-Backup {
    param([MiniKeyboard.HidTransport] $Pad, [string] $Path, [string] $Note)

    # Note: avoid naming locals after script parameters -- PowerShell variable
    # names are case-insensitive, so $dump would rebind the -Dump switch.
    $snapshot = Export-PadConfig -Pad $Pad -Layers 3 -Note $Note
    $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    $captured = ($snapshot.layers | Measure-Object -Property reportCount -Sum).Sum
    if ($captured -gt 0) {
        Write-Host "  Backed up $captured reports to $Path" -ForegroundColor DarkGray
    } else {
        Write-Warning "Device returned no data for read-back; $Path is an empty backup."
        Write-Warning "Restore will not be available. Continue only if you're comfortable with that."
    }
    $snapshot
}

switch ($PSCmdlet.ParameterSetName) {

    'ListKeys' {
        $names = Get-PadKeyNames
        Write-Host "`nModifiers" -ForegroundColor Cyan
        Write-Host ('  ' + ($names.Modifiers -join ', '))
        Write-Host "`nKeys" -ForegroundColor Cyan
        Write-Host ('  ' + ($names.Keys -join ', '))
        Write-Host "`nMedia / consumer" -ForegroundColor Cyan
        Write-Host ('  ' + ($names.Media -join ', '))
        Write-Host "`nMouse" -ForegroundColor Cyan
        Write-Host ('  ' + ($names.Mouse -join ', '))
        Write-Host "`nLED colors" -ForegroundColor Cyan
        Write-Host ('  ' + ($names.LedColors -join ', '))
        Write-Host "`nLED effects" -ForegroundColor Cyan
        Write-Host ('  ' + ($names.LedEffects -join ', '))
        Write-Host "`nRaw usage codes: <0x04> or <4>`n" -ForegroundColor DarkGray
    }

    'Probe' {
        Write-Host "`nScanning for macro pad (VID 0x1189 / PID 0x8840)...`n" -ForegroundColor Cyan
        $interfaces = Get-PadInterface
        if ($interfaces.Count -eq 0) {
            Write-Host "No macro pad found. Is it plugged in?" -ForegroundColor Red
            exit 1
        }

        $interfaces |
            Sort-Object UsagePage, Usage |
            ForEach-Object {
                $isConfig = ($_.UsagePage -eq 0xFF00 -and $_.Usage -eq 0x0001)
                [pscustomobject]@{
                    Role      = if ($isConfig) { '*** CONFIG ***' } else { 'emulated input' }
                    UsagePage = '0x{0:X4}' -f $_.UsagePage
                    Usage     = '0x{0:X4}' -f $_.Usage
                    In        = $_.InputReportByteLength
                    Out       = $_.OutputReportByteLength
                    Feature   = $_.FeatureReportByteLength
                }
            } | Format-Table -AutoSize

        $config = $interfaces | Where-Object { $_.UsagePage -eq 0xFF00 -and $_.Usage -eq 0x0001 }
        if (-not $config) {
            Write-Host "Config channel NOT found -- cannot program this device." -ForegroundColor Red
            exit 1
        }

        Write-Host "Config channel: $($config.Path)" -ForegroundColor DarkGray
        Write-Host ("Firmware rev:   0x{0:X4}" -f $config.VersionNumber) -ForegroundColor DarkGray

        $pad = $null
        try {
            $pad = Connect-Pad
            $access = if ($pad.CanRead) { 'read + write' } else { 'write only' }
            Write-Host "Opened OK ($access)." -ForegroundColor Green
        } catch {
            Write-Host "Could not open the config channel: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        } finally {
            if ($pad) { $pad.Dispose() }
        }

        $variant = Get-PadProtocolVariant
        Write-Host "Protocol: bind opcode $($variant.BindOpcode), layer offset $($variant.LayerOffset)`n" -ForegroundColor DarkGray
    }

    'Dump' {
        $path = Get-BackupFilePath -Explicit $BackupPath
        $pad = Connect-Pad
        try {
            Write-Host "Reading current configuration..." -ForegroundColor Cyan
            $snapshot = Save-Backup -Pad $pad -Path $path -Note 'manual dump'
            foreach ($layer in $snapshot.layers) {
                Write-Host ("`n  Layer {0}  ({1} slots)" -f $layer.layer, $layer.reportCount) -ForegroundColor Cyan
                foreach ($line in @($layer.decoded)) {
                    Write-Host ("    " + $line)
                }
            }
            Write-Host ''

            if ($AsConfig) {
                $bindings = @(Read-PadBindings -Pad $pad -Layers 3)
                $lost = ConvertTo-PadConfigFile -Bindings $bindings -Path $AsConfig
                Write-Host "Wrote editable config to $AsConfig" -ForegroundColor Green
                if ($lost -gt 0) {
                    Write-Warning "$lost mouse binding(s) could not be recovered and are blank in that file."
                }
            }
        } finally {
            $pad.Dispose()
        }
    }

    'Validate' {
        $config = Read-PadConfigFile -Path $Validate
        Write-Host "`n$($config.Path)" -ForegroundColor Cyan
        foreach ($layer in $config.Layers) {
            $led = if ($null -ne $layer.LedColor) { "$($layer.LedColor)/$($layer.LedEffect)" } else { '(unchanged)' }
            Write-Host "`n  Layer $($layer.Number)  LED: $led" -ForegroundColor Cyan
            foreach ($entry in (@($layer.Buttons) + @($layer.Knobs))) {
                '{0,-14} 0x{1:X2}  {2,-9} {3}' -f $entry.Name, $entry.ButtonId, $entry.Binding.Type, $entry.Binding.Source
            }
        }
        Write-Host "`nConfig is valid.`n" -ForegroundColor Green
    }

    'Apply' {
        $config = Read-PadConfigFile -Path (Resolve-ConfigPath -Value $Apply)
        $scope = if ($Layer) { "layer $($Layer -join ', ')" } else { "$($config.Layers.Count) layer(s)" }
        Write-Host "Config validated: $scope." -ForegroundColor Green

        if ($WhatIf) {
            Write-Host "`n--- Dry run: reports that WOULD be sent ---`n" -ForegroundColor Yellow
            Write-PadConfig -Pad $null -Config $config -Layer $Layer -DryRun
            Write-Host "`n--- Nothing was sent to the device. ---`n" -ForegroundColor Yellow
            break
        }

        $pad = Connect-Pad
        try {
            if (-not $NoBackup) {
                $backup = Get-BackupFilePath -Explicit $BackupPath
                Write-Host "Backing up current configuration..." -ForegroundColor Cyan
                Save-Backup -Pad $pad -Path $backup -Note "pre-apply of $($config.Path)" | Out-Null
            }

            $estimate = if ($Layer) { '~5s per layer' } else { '~15s' }
            Write-Host "Programming pad ($estimate -- a 200ms settle is required per key)..." -ForegroundColor Cyan
            Write-PadConfig -Pad $pad -Config $config -Layer $Layer
            Write-Host "Done. Configuration saved to flash." -ForegroundColor Green

            if ($Verify) {
                Write-Host "Reading back to verify..." -ForegroundColor Cyan
                $failures = Show-VerifyResult -Results (Test-PadWritten -Pad $pad -Config $config -Layer $Layer)
                if ($failures -gt 0) { exit 1 }
            }
        } finally {
            $pad.Dispose()
        }
    }

    'Compare' {
        $config = Read-PadConfigFile -Path (Resolve-ConfigPath -Value $Compare)
        $pad = Connect-Pad
        try {
            Write-Host "Comparing device against $($config.Path)..." -ForegroundColor Cyan
            $failures = Show-VerifyResult -Results (Test-PadWritten -Pad $pad -Config $config)
            if ($failures -gt 0) { exit 1 }
        } finally {
            $pad.Dispose()
        }
    }

    'Profiles' {
        $found = @(Get-PadProfile -Root $PSScriptRoot)
        if ($found.Count -eq 0) {
            Write-Host "`nNo profiles saved. Create one from the GUI (Profiles...) or drop a config into profiles\.`n"
            break
        }
        Write-Host "`nSaved profiles:" -ForegroundColor Cyan
        foreach ($entry in $found) { Write-Host ("  {0,-20} {1}" -f $entry.Name, $entry.Path) }
        Write-Host "`nApply one with:  .\macropad.ps1 -Apply <name>`n"
    }

    'Restore' {
        if ($WhatIf) {
            Write-Host "`n--- Dry run: reports that WOULD be replayed ---`n" -ForegroundColor Yellow
            Restore-PadConfig -Pad $null -Path $Restore -DryRun | Out-Null
            Write-Host "`n--- Nothing was sent to the device. ---`n" -ForegroundColor Yellow
            break
        }

        $pad = Connect-Pad
        try {
            Write-Host "Replaying $Restore..." -ForegroundColor Cyan
            $count = Restore-PadConfig -Pad $pad -Path $Restore
            Write-Host "Replayed $count reports and saved to flash." -ForegroundColor Green
        } finally {
            $pad.Dispose()
        }
    }
}
