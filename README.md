# UGREEN NASsync Fan & LED Control for Proxmox VE / Linux Host

A lightweight, native hardware control suite for UGREEN NASsync hardware running Proxmox VE or Debian Linux hosts. It provides automatic fan speed management, front-panel LED initialization, and an event-driven disk activity LED daemon (see Features below for details).

> **Hardware Compatibility Notice**: This project was built and tested specifically on the **UGREEN NASsync DXP4800**. While it may work on other hardware models in the DXP series (such as the DXP2800, DXP6800, or DXP8800), hardware verification has only been performed on the DXP4800.

---

## What makes this project different

Most existing UGREEN LED/fan scripts for third-party OSes are either static (LEDs just turn on and stay on) or rely on plain periodic polling of `/sys/block/*/stat`, which is a trade-off between responsiveness and CPU usage and can't tell an interesting disk write apart from a housekeeping SMART/temperature probe.

This repo takes a different approach for the disk activity LEDs:

* **True event-driven blinking, not polling.** The HDD/NVMe LED daemon attaches to the kernel's `block:block_rq_complete` tracepoint via `bpftrace`. Each LED pulses the instant a real read/write completes — no polling interval to wait on, and effectively zero CPU cost while a disk is idle (the instrumented kernel path is a no-op until a real request completes).
* **Noise filtering at the source.** The tracepoint predicate filters out non-data requests (SMART/temperature-probe passthrough commands, cache flushes) using the kernel's own `rwbs` request-flags, so periodic sensor polling (e.g. from the bundled fan control daemon) never falsely lights up a disk LED.
* **Reliable, stable disk-to-LED mapping.** SATA/SAS bays are mapped via SCSI **HCTL** (`lsblk -S -x hctl`), which is stable across reboots — unlike the ATA-port-number-from-`by-path` approach used by many other scripts, which can silently map to the wrong bay depending on controller/kernel version.
* **Shared LED, priority-aware color arbitration.** UGREEN NAS hardware with combined SATA+NVMe bays has no dedicated NVMe indicator — NVMe activity shares an LED with a SATA bay. Each NVMe device (there can be several) is automatically distributed across the available bay LEDs, and a priority system decides which drive's activity "wins" the shared LED at any instant (degraded/faulted drives always win, for a visible red alert).
* **Graceful degradation.** If `bpftrace` isn't available (or fails to attach), the daemon automatically falls back to poll-driven flashing instead of going dark.
* **Idempotent, update-safe deployment.** `setup.sh` supports an `update` mode that skips the (slow) dependency/DKMS build steps and just redeploys scripts/services, merging any new configuration variables into your existing `/etc/ugreen/*.env` files without touching values you've already customized.
* **Correct PWM control from the start.** The fan daemon explicitly switches the ITE Super I/O PWM channel into manual mode (`pwmN_enable=1`) before writing to it — a step most similar scripts miss, which otherwise causes silent `EBUSY` write failures.

---

## Why a Dedicated Python Script for Fan Control ?

Native Linux PWM management tools (such as standard `fancontrol` from `lm-sensors`) do not work properly out of the box on the UGREEN DXP4800 motherboard. The hardware requires explicit handling of the Super I/O interface and non-standard sysfs mapping, so this repository uses a dedicated Python daemon (`ugreen-fan-control.py`) that parses `/sys/class/hwmon` directly instead of relying on `fancontrol` — see Features below for what it does.

---

## Features

### Fan Control
* **Dual Independent Fan Curves**: Dynamically interpolates target PWM values for CPU and storage drives (NVMe & SATA), applying the higher fan speed demand between the two.
* **Selectable Curve Presets (`FAN_MODE`)**: Choose between `silent` (quietest, tolerates higher temps before spinning up), `normal` (balanced default), or `powerful` (spins up earlier/harder for maximum cooling) — each with its own independent CPU/disk curve pair.
* **Native Host Sensor Parsing**: Reads temperatures directly from host `/sys/class/hwmon` using `coretemp`, `nvme`, and the Linux kernel `drivetemp` module for SATA drives.
* **HDD Standby Protection**: Checks drive power states before querying via `smartctl` fallback to avoid waking up spun-down disks.
* **Automatic Hardware Detection**: Auto-detects the active ITE Super I/O PWM control interface (`pwm3`, `pwm2`, or `pwm1`) and switches it into manual mode.
* **Failsafe Mechanism**: Reverts to a safe configurable PWM speed if sensor readings fail or exceptions occur.

### LED Control
* **Automatic front-panel LED initialization** (power/network/disk) at boot via `ugreen-led-setup`.
* **Event-driven disk activity LEDs** via `bpftrace` tracepoints — real-time blink on actual I/O, not a polling guess.
* **HCTL-based SATA bay mapping** for a stable, reboot-safe disk-to-LED assignment.
* **Automatic NVMe-to-bay distribution** for boards with more NVMe slots than dedicated LEDs, sharing bay LEDs with priority-based color arbitration.
* **Degraded-drive alert**: a ZFS pool member reported as `FAULTED`/`DEGRADED`/`UNAVAIL`/`REMOVED` immediately takes over its LED with a continuously blinking alert color.
* **Poll-driven fallback** if `bpftrace` is unavailable, so the daemon never goes silent.
* **Network activity LED** bound to the kernel's native `netdev` trigger for the configured interface, using the same `BRIGHTNESS_ACTIVE` level as the disk LEDs.

---

## Repository Structure

```text
├── setup.sh                    # Automated setup & driver installation script (install/update modes)
├── ugreen-fan-control.py       # Fan control daemon (dual CPU/disk curves)
├── ugreen-fan-control.env      # Fan control configuration
├── ugreen-fan-control.service  # Systemd service unit for fan control
├── ugreen-hdd-led.sh           # Multi-bay HDD/NVMe activity LED daemon (bpftrace event-driven)
├── ugreen-hdd-led.service      # Systemd service unit for the disk activity LED daemon
├── ugreen-net-led.sh           # Network activity LED (kernel netdev trigger)
├── ugreen-net-led.service      # Systemd service unit for the network LED
├── ugreen-led-setup.sh         # One-shot I2C/LED hardware bind helper
├── ugreen-led-setup.service    # Systemd service unit for the LED hardware bind step
├── ugreen-led-common.sh        # Shared color-parsing library sourced by the LED scripts
└── ugreen-leds.env             # LED daemon configuration (colors, brightness, mapping, bpftrace)
```

---

## Installation

1. Clone this repository to your Proxmox/Debian host:
   ```bash
   git clone https://github.com/theyo-tester/ugreen-dxp-pve.git
   cd ugreen-dxp-pve
   ```

2. Make `setup.sh` executable and run it as `root`:
   ```bash
   chmod +x setup.sh
   sudo ./setup.sh
   ```

The setup script installs required package dependencies (including `bpftrace`), builds the `it87` and `led-ugreen` DKMS drivers, copies all scripts/configuration files to `/usr/local/bin`, `/usr/local/lib` and `/etc/ugreen`, and enables/starts the systemd services.

### Updating an existing install

After pulling new changes, re-run `setup.sh` in **update mode** to skip the dependency/DKMS build steps and just redeploy the scripts and service files. New configuration variables introduced by an update are merged into your existing `/etc/ugreen/*.env` files (existing values you've customized are left untouched); the services are restarted automatically so the new code takes effect:

```bash
git pull
sudo ./setup.sh update
```

---

## Configuration

### Fan control — `/etc/ugreen/ugreen-fan-control.env`

```ini
POLL_INTERVAL=10
FAILSAFE_PWM=200
MIN_PWM=50
MAX_PWM=255

# Which curve preset to use: silent, normal, or powerful.
FAN_MODE=normal

# Fan curves format: "temperature:pwm_value,temperature:pwm_value"
# Balanced default curves (used when FAN_MODE=normal)
CPU_FAN_CURVE=35:50,50:100,65:180,75:255
DISK_FAN_CURVE=35:60,45:110,55:180,60:255

# Quietest curves (FAN_MODE=silent). MIN_PWM above still applies as a floor,
# so lower it too if you want the fan to idle at/near 0 below the first point.
SILENT_CPU_FAN_CURVE=40:0,55:40,65:80,75:150
SILENT_DISK_FAN_CURVE=38:0,45:40,55:80,62:150

# Spins up earlier/harder for maximum cooling (FAN_MODE=powerful).
POWERFUL_CPU_FAN_CURVE=30:120,45:180,55:220,65:255
POWERFUL_DISK_FAN_CURVE=30:120,40:180,50:220,55:255
```

Apply changes:
```bash
sudo systemctl restart ugreen-fan-control.service
```

### Disk/network LEDs — `/etc/ugreen/ugreen-leds.env`

```ini
# Disk LED colors
HDD_COLOR="white"
SSD_COLOR="blue"
DEGRADED_COLOR="red"

# Network LED
NET_INTERFACE="vmbr0"
NET_COLOR="white"

# Brightness levels
BRIGHTNESS_SLEEP=5      # idle baseline
BRIGHTNESS_ACTIVE=20    # peak brightness during an activity pulse
BRIGHTNESS_FULL=255     # degraded/alert brightness

POLL_INTERVAL=5         # slow-loop cadence for baseline/degraded state (not blink timing)

# SATA bay mapping: SCSI host number -> LED slot offset (host 0 => disk1 by
# default). Verify with: lsblk -S -x hctl -o name,hctl,serial
HCTL_SLOT_OFFSET=1

# Hardware blink pulse timing (ms)
BLINK_ON_MS=150
BLINK_OFF_MS=150

# Event-driven blinking via bpftrace tracepoints (falls back to poll-driven
# flashing automatically if bpftrace isn't installed or fails to attach).
BPFTRACE_ENABLED=1

# Diagnostics: log per-device IO deltas and computed slot/priority every poll.
HDD_LED_DEBUG=0
```

Apply changes:
```bash
sudo systemctl restart ugreen-hdd-led.service
sudo systemctl restart ugreen-net-led.service
```

---

## Monitoring Logs

Fan control:
```bash
sudo journalctl -u ugreen-fan-control.service -f
```

Disk activity LEDs (also shows the resolved device→LED mapping at startup, and confirms whether `bpftrace` attached successfully):
```bash
sudo journalctl -u ugreen-hdd-led.service -f
```

---

## Upstream Projects & Acknowledgments

This suite compiles, installs, and integrates components from the following projects:

* **[frankcrawford/it87](https://github.com/frankcrawford/it87)**: Actively maintained Linux kernel driver for ITE IT87xx Super I/O chips (compiled via DKMS to expose hardware monitoring and PWM control). Several other repos ship their own forked/patched driver copies for DXP boards, but that's hard to keep maintained — the plain upstream driver works fine (at least on the DXP4800).
* **[miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller)**: Provides the `led-ugreen` kernel module (compiled via DKMS) that exposes the front-panel LEDs as standard Linux `leds` class devices, and documents the I2C protocol and disk-mapping considerations this project's HCTL-based mapping and shared-LED design build on.

