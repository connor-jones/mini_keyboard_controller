# Power management and re-enumeration for the macro pad.
#
# Why this exists: the pad stops responding after the machine sleeps and has to
# be physically unplugged. Nothing is logged, because from Windows' point of
# view nothing failed -- the device was suspended, resumed, and reported no
# error. The CH552 firmware simply does not restart its HID reporting after a
# resume. Only a USB re-enumeration brings it back.
#
# Two independent things are done here:
#
#   1. Stop Windows suspending the pad in the first place (per-device, so the
#      rest of the machine keeps its power saving).
#   2. Re-enumerate the device from software when it does wedge -- a "soft
#      replug" that saves reaching for the cable, and which can be run
#      automatically on resume.
#
# Everything here needs elevation: it writes HKLM and restarts a device node.
# Nothing else in this project does, which is why it is a separate file the
# other entry points can load without paying that cost.

Set-StrictMode -Version Latest

$script:PadHardwareFilter = 'USB\VID_1189&PID_8840*'
$script:ResumeTaskName    = 'MiniKeyboard-ResumeFix'

# Microsoft-Windows-Power-Troubleshooter/1 fires once the machine is properly
# back from sleep, later and far more reliably than Kernel-Power 107.
$script:ResumeSubscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>
'@

function Test-Elevated {
    <#
    .SYNOPSIS
        True when the current process can write HKLM and restart devices.
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevated {
    param([string] $Action = 'This')

    if (-not (Test-Elevated)) {
        throw "$Action needs an elevated PowerShell. Right-click PowerShell and pick 'Run as administrator', then try again."
    }
}

function Get-PadDeviceNode {
    <#
    .SYNOPSIS
        The pad's USB device nodes: the composite parent and its two interfaces.

    .DESCRIPTION
        Returned instance IDs are the *USB* nodes, not the HID children. The
        composite parent is the one to restart -- restarting a single interface
        leaves the other half of the device in its old state.
    #>
    # The filter starts "USB\", so the HID\ children are excluded already.
    $usb = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId -like $script:PadHardwareFilter })

    if ($usb.Count -eq 0) { throw 'No macro pad found on the USB bus. Is it plugged in?' }

    # The composite parent has no &MI_ interface qualifier; the children do.
    $composite = @($usb | Where-Object { $_.InstanceId -notlike '*&MI_*' })
    $interfaces = @($usb | Where-Object { $_.InstanceId -like '*&MI_*' })

    if ($composite.Count -ne 1) {
        throw "Expected exactly one macro pad, found $($composite.Count). Unplug the spare ones."
    }

    [pscustomobject]@{
        Composite       = $composite[0].InstanceId
        CompositeStatus = $composite[0].Status
        Interfaces      = @($interfaces | ForEach-Object { $_.InstanceId })
    }
}

function Get-PadPowerState {
    <#
    .SYNOPSIS
        Everything that decides whether Windows is allowed to suspend the pad.

    .DESCRIPTION
        Three separate switches have to be off for the pad to be left alone, and
        they live in three different places. This gathers all of them plus the
        machine-wide plan setting, so the report shows exactly what is still on.
    #>
    $node = Get-PadDeviceNode

    # The "Allow the computer to turn off this device to save power" checkbox in
    # Device Manager is this WMI property, nothing in the registry. Instance
    # names here are lower-cased and carry a trailing _0, so match on a prefix.
    $checkbox = @{}
    foreach ($entry in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceName -like '*VID_1189&PID_8840*' })) {
        $checkbox[($entry.InstanceName -replace '_0$', '').ToLowerInvariant()] = [bool]$entry.Enable
    }

    $perInterface = foreach ($id in $node.Interfaces) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters"
        $values = $null
        if (Test-Path -LiteralPath $key) {
            $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        }

        # SelectiveSuspendEnabled is REG_BINARY here, not a DWORD, so it comes
        # back as a byte array; treat a missing value as "on" (the USB stack's
        # default) rather than assuming off.
        $selective = $true
        if ($values -and $values.PSObject.Properties.Name -contains 'SelectiveSuspendEnabled') {
            $raw = $values.SelectiveSuspendEnabled
            $selective = [bool](@($raw)[0])
        }

        $enhanced = $true
        if ($values -and $values.PSObject.Properties.Name -contains 'EnhancedPowerManagementEnabled') {
            $enhanced = [bool]$values.EnhancedPowerManagementEnabled
        }

        $idleD3 = $true
        if ($values -and $values.PSObject.Properties.Name -contains 'AllowIdleIrpInD3') {
            $idleD3 = [bool]$values.AllowIdleIrpInD3
        }

        $key = $id.ToLowerInvariant()
        $canPowerOff = $null
        if ($checkbox.ContainsKey($key)) { $canPowerOff = $checkbox[$key] }

        [pscustomobject]@{
            InstanceId       = $id
            SelectiveSuspend = $selective
            EnhancedPower    = $enhanced
            AllowIdleInD3    = $idleD3
            CanPowerOff      = $canPowerOff
        }
    }

    $plan = $null
    try {
        $query = powercfg /q SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>$null
        $ac = $query | Select-String 'Current AC Power Setting Index:\s*(0x[0-9a-f]+)'
        if ($ac) { $plan = [Convert]::ToInt32($ac.Matches[0].Groups[1].Value, 16) -ne 0 }
    } catch { $plan = $null }

    [pscustomobject]@{
        Composite            = $node.Composite
        Interfaces           = @($perInterface)
        PlanSelectiveSuspend = $plan
        ResumeFixInstalled   = (Test-PadResumeFix)
        Elevated             = (Test-Elevated)
    }
}

function Disable-PadPowerSaving {
    <#
    .SYNOPSIS
        Stop Windows suspending the pad, without touching the rest of the machine.

    .DESCRIPTION
        Clears all three per-device switches on both USB interfaces. The
        machine-wide "USB selective suspend" power plan setting is deliberately
        left alone -- turning that off would stop every USB device on the system
        idling down to save a problem with one of them.

        The registry values are only read when the device starts, so the caller
        must re-enumerate afterwards for them to take effect.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Elevated -Action 'Changing device power settings'
    $node = Get-PadDeviceNode
    $changed = New-Object System.Collections.Generic.List[string]

    foreach ($id in $node.Interfaces) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters"
        if (-not (Test-Path -LiteralPath $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        if ($PSCmdlet.ShouldProcess($id, 'Disable USB power saving')) {
            # SelectiveSuspendEnabled is REG_BINARY; the other two are DWORDs.
            # Writing the wrong type here is silently ignored by the USB stack.
            New-ItemProperty -LiteralPath $key -Name 'SelectiveSuspendEnabled' `
                -Value ([byte[]](0)) -PropertyType Binary -Force | Out-Null
            New-ItemProperty -LiteralPath $key -Name 'EnhancedPowerManagementEnabled' `
                -Value 0 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -LiteralPath $key -Name 'AllowIdleIrpInD3' `
                -Value 0 -PropertyType DWord -Force | Out-Null
            $changed.Add($id)
        }
    }

    # And the Device Manager checkbox, which is stored separately from all that.
    $power = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceName -like '*VID_1189&PID_8840*' })
    foreach ($entry in $power) {
        if ($PSCmdlet.ShouldProcess($entry.InstanceName, 'Uncheck "allow the computer to turn off this device"')) {
            try {
                Set-CimInstance -InputObject $entry -Property @{ Enable = $false } -ErrorAction Stop
            } catch {
                Write-Warning "Could not clear the power-off checkbox for $($entry.InstanceName): $($_.Exception.Message)"
            }
        }
    }

    $changed
}

function Reset-PadDevice {
    <#
    .SYNOPSIS
        Re-enumerate the pad from software -- the equivalent of unplugging it.

    .DESCRIPTION
        Tears down and rebuilds the whole composite USB device stack, which is
        what clears a wedged firmware; poking the individual HID children is not
        enough.

        Uses `pnputil /restart-device`, and deliberately never calls
        Disable-PnpDevice. This pad reports capabilities 0x94 -- Removable and
        SurpriseRemovalOK, but *not* HardwareDisabled -- so Disable-PnpDevice
        fails on it with a bare "Not supported"... after having already written
        the disabled flag. The device then comes back in problem state 22 on the
        next restart and stays there across reboots, which is a much worse fault
        than the one being fixed. Enable-PnpDevice, by contrast, works fine, so
        the only recovery action here is one that cannot leave things worse.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # How long to wait for the config channel to come back before giving up.
        [int] $TimeoutSeconds = 15
    )

    Assert-Elevated -Action 'Resetting the device'
    $node = Get-PadDeviceNode

    if (-not $PSCmdlet.ShouldProcess($node.Composite, 'Restart device (soft replug)')) {
        return $false
    }

    $output = & pnputil.exe /restart-device $node.Composite 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restart the pad: $($output -join ' ')"
    }

    # Wait for the config channel to reappear rather than a fixed sleep -- USB
    # re-enumeration takes anywhere from a few hundred ms to several seconds.
    # If the node comes back in a problem state, clear it and keep waiting;
    # pnputil reports success either way, so its exit code cannot be trusted
    # on its own.
    $recovered = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250

        try {
            $found = @(Get-PadInterface | Where-Object { $_.UsagePage -eq 0xFF00 -and $_.Usage -eq 0x0001 })
            if ($found.Count -gt 0) { return $true }
        } catch { }

        if (-not $recovered) {
            $problem = $null
            try {
                $problem = (Get-PnpDeviceProperty -InstanceId $node.Composite `
                    -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop).Data
            } catch { }
            if ($problem) {
                Write-Verbose "Device came back with problem code $problem; enabling."
                try {
                    Enable-PnpDevice -InstanceId $node.Composite -Confirm:$false -ErrorAction Stop
                } catch {
                    Write-Warning "Could not clear problem code ${problem}: $($_.Exception.Message)"
                }
                $recovered = $true
            }
        }
    }
    $false
}

function Test-PadResumeFix {
    <#
    .SYNOPSIS
        True when the scheduled task that resets the pad on resume is installed.
    #>
    $null -ne (Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction SilentlyContinue)
}

function Install-PadResumeFix {
    <#
    .SYNOPSIS
        Reset the pad automatically whenever the machine wakes from sleep.

    .DESCRIPTION
        Registers a scheduled task triggered by the resume event, running as
        SYSTEM so it neither prompts for elevation nor flashes up a console.

        The reset is unconditional rather than conditional on the pad being
        wedged. There is no reliable way to ask the firmware whether it is still
        reporting -- the config channel answers even when the key matrix has
        stopped -- and a reset costs about two seconds, so testing first would
        add complexity and a failure mode in exchange for nothing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Seconds to wait after resume before resetting; the USB stack needs to
        # settle first or the disable lands while the port is still coming up.
        [int] $DelaySeconds = 10
    )

    Assert-Elevated -Action 'Installing the resume fix'

    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'macropad.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Cannot find macropad.ps1 next to $PSScriptRoot."
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Reset -Quiet' -f $script)

    # New-ScheduledTaskTrigger has no event trigger, so build one via CIM.
    $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
    $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
    $trigger.Subscription = $script:ResumeSubscription
    $trigger.Enabled = $true
    $trigger.Delay = "PT${DelaySeconds}S"

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    if ($PSCmdlet.ShouldProcess($script:ResumeTaskName, 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $script:ResumeTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description 'Re-enumerates the CH57x macro pad after the system resumes, because its firmware does not restart HID reporting on its own.' | Out-Null
    }
    $script:ResumeTaskName
}

function Uninstall-PadResumeFix {
    <#
    .SYNOPSIS
        Remove the resume scheduled task.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Assert-Elevated -Action 'Removing the resume fix'
    if (-not (Test-PadResumeFix)) { return $false }
    if ($PSCmdlet.ShouldProcess($script:ResumeTaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false
        return $true
    }
    $false
}
