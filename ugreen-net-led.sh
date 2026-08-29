#!/usr/bin/env bash
# UGREEN Network LED Setup (Kernel-Triggered with Centralized Color Parsing)
set -e

COMMON_LIB="/usr/local/lib/ugreen-led-common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
else
    echo "Error: Central library $COMMON_LIB not found." >&2
    exit 1
fi

NET_INTERFACE="${NET_INTERFACE:-vmbr0}"
NET_COLOR="${NET_COLOR:-white}"
BRIGHTNESS_ACTIVE="${BRIGHTNESS_ACTIVE:-20}"

# 1. Ensure kernel netdev trigger module is loaded
lsmod | grep -q ledtrig_netdev || modprobe ledtrig-netdev 2>/dev/null || true

# 2. Locate netdev LED sysfs node
LED_DIR="/sys/class/leds/netdev"
if [ ! -d "$LED_DIR" ]; then
    LED_DIR=$(ls -d /sys/class/leds/netdev* 2>/dev/null | head -n1)
fi

if [ -z "$LED_DIR" ] || [ ! -d "$LED_DIR" ]; then
    echo "Error: No network LED found under /sys/class/leds/netdev*." >&2
    exit 1
fi

# 3. Activate kernel netdev trigger mode
echo netdev > "${LED_DIR}/trigger" 2>/dev/null || true
sleep 0.1

# 4. Bind target interface and enable activity indicators
[ -w "${LED_DIR}/device_name" ] && echo "$NET_INTERFACE" > "${LED_DIR}/device_name" 2>/dev/null || true
[ -w "${LED_DIR}/link" ]        && echo 1 > "${LED_DIR}/link" 2>/dev/null || true
[ -w "${LED_DIR}/rx" ]          && echo 1 > "${LED_DIR}/rx" 2>/dev/null || true
[ -w "${LED_DIR}/tx" ]          && echo 1 > "${LED_DIR}/tx" 2>/dev/null || true

# 5. Apply normalized RGB color from central parser
if [ -w "${LED_DIR}/color" ]; then
    RGB_VAL=$(parse_color "$NET_COLOR")
    echo "$RGB_VAL" > "${LED_DIR}/color" 2>/dev/null || true
fi

[ -w "${LED_DIR}/brightness" ] && echo "$BRIGHTNESS_ACTIVE" > "${LED_DIR}/brightness" 2>/dev/null || true

echo "Network LED bound to interface '${NET_INTERFACE}' with color '${NET_COLOR}' (${RGB_VAL})."