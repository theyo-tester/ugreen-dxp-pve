# UGREEN NASsync Fan & LED Control for Proxmox VE / Linux Host

A lightweight, native hardware control suite designed for UGREEN NASsync hardware running Proxmox VE or Debian Linux hosts. It provides automatic, dual-curve fan speed management based on real-time CPU and storage temperatures, as well as automatic LED initialization on system boot.

> **Hardware Compatibility Notice**: This project was built and tested specifically on the **UGREEN NASsync DXP4800**. While it may work on other hardware models in the DXP series (such as the DXP2800, DXP6800, or DXP8800), hardware verification has only been performed on the DXP4800.

---

## Why a Dedicated Python Script?

Native Linux PWM management tools (such as standard `fancontrol` from `lm-sensors`) do not work properly out of the box on the UGREEN DXP4800 motherboard. The hardware requires explicit handling of the Super I/O interface and non-standard sysfs mapping.

To solve this, this repository uses a dedicated Python daemon (`ugreen-fan-control.py`). The daemon:
* Bypasses standard `fancontrol` limitations by directly parsing `/sys/class/hwmon` sysfs structures.
* Evaluates two separate fan curves in real time (one for CPU core temperatures and one for NVMe/SATA storage drives).
* Continuously writes the dynamically calculated maximum PWM demand to the active ITE Super I/O PWM register while enforcing a safe fallback speed if temperature readings fail.

---

## Features

* **Dual Independent Fan Curves**: Dynamically interpolates target PWM values for CPU and storage drives (NVMe & SATA), applying the higher fan speed demand between the two.
* **Native Host Sensor Parsing**: Reads temperatures directly from host `/sys/class/hwmon` using `coretemp`, `nvme`, and the Linux kernel `drivetemp` module for SATA drives.
* **HDD Standby Protection**: Checks drive power states before querying via `smartctl` fallback to avoid waking up spun-down disks.
* **Automatic Hardware Detection**: Auto-detects the active ITE Super I/O PWM control interface (`pwm3`, `pwm2`, or `pwm1`).
* **Failsafe Mechanism**: Reverts to a safe configurable PWM speed if sensor readings fail or exceptions occur.
* **LED Control Integration**: Automatically configures and enables front panel LED indicators upon boot.

---

## Repository Structure

```text
├── setup.sh                   # Automated setup & driver installation script
├── ugreen-fan-control.py      # Main Python fan control daemon
├── ugreen-fan-control.env     # Configuration file (fan curves & thresholds)
├── ugreen-fan-control.service # Systemd service unit for fan control
└── ugreen-leds.service        # Systemd service unit for LED control
```

---

## Upstream Projects & Acknowledgments

This suite compiles, installs, and integrates components from the following projects:

* **[frankcrawford/it87](https://github.com/frankcrawford/it87)**: Linux kernel driver for ITE IT87xx Super I/O chips (compiled via DKMS to expose hardware monitoring and PWM control).
* **[miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller)**: User-space C utility to configure UGREEN NAS LED controllers.
* **[lpaolini/ugreen-dxp-pve](https://github.com/lpaolini/ugreen-dxp-pve)**: Conceptual foundation for host-based dual fan curve management on UGREEN NAS hardware.

---

## Installation

1. Clone this repository to your Proxmox/Debian host:
   ```bash
   git clone [https://github.com/your-username/ugreen-dxp-pve.git](https://github.com/your-username/ugreen-dxp-pve.git)
   cd ugreen-dxp-pve
   ```

2. Make `setup.sh` executable and run it as `root`:
   ```bash
   chmod +x setup.sh
   sudo ./setup.sh
   ```

The setup script will install required package dependencies, build the DKMS driver, compile the LED binary, copy all configuration and Python files to `/usr/local/bin` and `/etc`, and start the systemd services.

---

## Configuration

Customize polling intervals, safety limits, and fan curves by editing `/etc/ugreen-fan-control.env`:

```ini
POLL_INTERVAL=10
FAILSAFE_PWM=200
MIN_PWM=50
MAX_PWM=255

# Fan curves format: "temperature:pwm_value,temperature:pwm_value"
CPU_FAN_CURVE=35:50,50:100,65:180,75:255
DISK_FAN_CURVE=35:60,45:110,55:180,60:255
```

Apply changes by restarting the service:
```bash
sudo systemctl restart ugreen-fan-control.service
```

---

## Monitoring Logs

To monitor the fan daemon activity and temperature readings in real time:

```bash
sudo journalctl -u ugreen-fan-control.service -f
```
