#!/usr/bin/env python3
"""
UGREEN NASsync Automatic Fan Control Daemon for Proxmox VE / Host Linux.

Features:
- Dual independent fan curves (CPU vs. Storage Disks/NVMe).
- Native host sysfs sensor parsing (CPU, NVMe, and SATA via drivetemp/smartctl).
- Dynamic PWM calculation using piecewise linear interpolation.
- Failsafe fallback PWM when sensor readings fail.
- Auto-detection of UGREEN ITE hwmon PWM interfaces.
"""

import os
import sys
import glob
import time
import json
import logging
import subprocess

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)

def parse_curve(curve_str):
    points = []
    try:
        for pair in curve_str.split(","):
            if ":" in pair:
                temp, pwm = pair.split(":")
                points.append((float(temp.strip()), float(pwm.strip())))
        points.sort(key=lambda x: x[0])
    except Exception as e:
        logging.error(f"Failed to parse fan curve string '{curve_str}': {e}")
    return points

def interpolate_curve(temp, curve):
    if not curve:
        return 0.0

    if temp <= curve[0][0]:
        return curve[0][1]

    if temp >= curve[-1][0]:
        return curve[-1][1]

    for i in range(len(curve) - 1):
        t1, p1 = curve[i]
        t2, p2 = curve[i + 1]
        if t1 <= temp <= t2:
            ratio = (temp - t1) / (t2 - t1)
            return p1 + ratio * (p2 - p1)

    return curve[-1][1]

def auto_detect_pwm_path():
    for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
        name_file = os.path.join(hwmon, "name")
        if os.path.exists(name_file):
            try:
                with open(name_file, "r") as f:
                    name = f.read().strip()
                if "it8" in name or "it87" in name or "it86" in name:
                    for pwm in ["pwm3", "pwm2", "pwm1"]:
                        pwm_path = os.path.join(hwmon, pwm)
                        if os.path.exists(pwm_path):
                            logging.info(f"Auto-detected UGREEN PWM path: {pwm_path} (driver: {name})")
                            return pwm_path
            except Exception:
                continue
    return None

def enable_manual_pwm(pwm_path):
    # it87/hwmon PWM channels reject direct writes until switched out of
    # automatic/BIOS mode via the matching pwmN_enable attribute.
    enable_path = f"{pwm_path}_enable"
    if not os.path.exists(enable_path):
        return
    try:
        with open(enable_path, "r") as f:
            if f.read().strip() == "1":
                return
        with open(enable_path, "w") as f:
            f.write("1")
        logging.info(f"Set {enable_path} to manual mode (1)")
    except Exception as e:
        logging.warning(f"Failed to set {enable_path} to manual mode: {e}")

def read_cpu_temp(override_path=""):
    if override_path and os.path.exists(override_path):
        try:
            with open(override_path, "r") as f:
                return float(f.read().strip()) / 1000.0
        except Exception as e:
            logging.warning(f"Failed reading CPU temp from override path '{override_path}': {e}")

    cpu_temps = []
    for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
        name_file = os.path.join(hwmon, "name")
        if os.path.exists(name_file):
            try:
                with open(name_file, "r") as f:
                    name = f.read().strip()
                if name in ["coretemp", "k10temp", "acpitz", "cpu_thermal"]:
                    for temp_input in glob.glob(os.path.join(hwmon, "temp*_input")):
                        with open(temp_input, "r") as f:
                            val = float(f.read().strip()) / 1000.0
                            if 0 < val < 120:
                                cpu_temps.append(val)
            except Exception:
                continue

    return max(cpu_temps) if cpu_temps else None

def read_disk_temps():
    disk_temps = []

    for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
        name_file = os.path.join(hwmon, "name")
        if os.path.exists(name_file):
            try:
                with open(name_file, "r") as f:
                    name = f.read().strip()
                if name in ["nvme", "drivetemp"]:
                    for temp_input in glob.glob(os.path.join(hwmon, "temp*_input")):
                        with open(temp_input, "r") as f:
                            val = float(f.read().strip()) / 1000.0
                            if 0 < val < 120:
                                disk_temps.append(val)
            except Exception:
                continue

    if not any("drivetemp" in os.path.join(h, "name") for h in glob.glob("/sys/class/hwmon/hwmon*")):
        for dev in glob.glob("/dev/sd[a-z]"):
            try:
                state_check = subprocess.run(
                    ["smartctl", "-n", "standby", "-j", dev],
                    capture_output=True, text=True
                )
                data = json.loads(state_check.stdout)
                if data.get("exit_status", 0) & 2:
                    continue

                temp = data.get("temperature", {}).get("current")
                if temp and 0 < temp < 120:
                    disk_temps.append(float(temp))
            except Exception:
                continue

    return disk_temps

def main():
    poll_interval = int(os.getenv("POLL_INTERVAL", "10"))
    failsafe_pwm = int(os.getenv("FAILSAFE_PWM", "200"))
    min_pwm = int(os.getenv("MIN_PWM", "50"))
    max_pwm = int(os.getenv("MAX_PWM", "255"))

    cpu_curve_str = os.getenv("CPU_FAN_CURVE", "35:50,50:100,65:180,75:255")
    disk_curve_str = os.getenv("DISK_FAN_CURVE", "35:60,45:110,55:180,60:255")

    cpu_curve = parse_curve(cpu_curve_str)
    disk_curve = parse_curve(disk_curve_str)

    pwm_path = os.getenv("FAN_PWM_PATH", "")
    if not pwm_path:
        pwm_path = auto_detect_pwm_path()

    if not pwm_path:
        logging.error("Could not detect UGREEN PWM sysfs path. Exiting.")
        sys.exit(1)

    cpu_override_path = os.getenv("CPU_TEMP_PATH", "")

    enable_manual_pwm(pwm_path)

    logging.info(f"Starting UGREEN Fan Control Daemon (Interval: {poll_interval}s)")
    logging.info(f"Target PWM Path: {pwm_path}")
    logging.info(f"CPU Fan Curve: {cpu_curve}")
    logging.info(f"Disk Fan Curve: {disk_curve}")

    current_applied_pwm = None

    while True:
        try:
            cpu_temp = read_cpu_temp(cpu_override_path)
            disk_temps = read_disk_temps()

            if cpu_temp is None and not disk_temps:
                logging.warning("Failed to read both CPU and Disk temperatures! Applying failsafe PWM.")
                target_pwm = failsafe_pwm
            else:
                cpu_pwm = interpolate_curve(cpu_temp, cpu_curve) if cpu_temp is not None else 0.0
                max_disk_temp = max(disk_temps) if disk_temps else 0.0
                disk_pwm = interpolate_curve(max_disk_temp, disk_curve) if disk_temps else 0.0

                target_pwm = max(cpu_pwm, disk_pwm)
                target_pwm = max(min_pwm, min(max_pwm, int(round(target_pwm))))

                logging.debug(
                    f"CPU: {cpu_temp:.1f}°C (PWM: {int(cpu_pwm)}), "
                    f"Max Disk: {max_disk_temp:.1f}°C (PWM: {int(disk_pwm)}) -> Target PWM: {target_pwm}"
                )

            if target_pwm != current_applied_pwm:
                with open(pwm_path, "w") as f:
                    f.write(str(target_pwm))
                current_applied_pwm = target_pwm
                logging.info(f"Applied PWM: {target_pwm} (CPU: {cpu_temp}°C, Max Disk: {max(disk_temps) if disk_temps else 'N/A'}°C)")

        except Exception as e:
            logging.error(f"Unexpected error in main loop: {e}. Applying failsafe PWM.")
            try:
                enable_manual_pwm(pwm_path)
                with open(pwm_path, "w") as f:
                    f.write(str(failsafe_pwm))
                current_applied_pwm = failsafe_pwm
            except Exception:
                pass

        time.sleep(poll_interval)

if __name__ == "__main__":
    main()
