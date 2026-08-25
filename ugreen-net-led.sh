#!/usr/bin/env bash
# UGREEN Network LED Daemon with Multi-NIC Support

ENV_FILE="/etc/ugreen/ugreen-leds.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

NET_INTERFACES="${NET_INTERFACES:-auto}"

# Detect physical NICs by checking for the hardware 'device' symlink in sysfs
if [ "$NET_INTERFACES" = "auto" ]; then
    INTERFACES=""
    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        if [ -e "${iface_path}/device" ]; then
            INTERFACES="${INTERFACES} ${iface}"
        fi
    done
    INTERFACES=$(echo "$INTERFACES" | xargs)
else
    INTERFACES="$NET_INTERFACES"
fi

NET_LEDS=$(ls -d /sys/class/leds/ugreen:*:net* 2>/dev/null || true)

if [ -z "$NET_LEDS" ]; then
    echo "No UGREEN network LEDs found in sysfs."
    exit 0
fi

for LED in $NET_LEDS; do
    echo netdev > "${LED}/trigger" 2>/dev/null || true
    echo 1 > "${LED}/rx" 2>/dev/null || true
    echo 1 > "${LED}/tx" 2>/dev/null || true
    echo 1 > "${LED}/link" 2>/dev/null || true

    for IFACE in $INTERFACES; do
        echo "$IFACE" > "${LED}/device_name" 2>/dev/null || true
    done
done

echo "Network LEDs configured for physical interfaces: $INTERFACES"
