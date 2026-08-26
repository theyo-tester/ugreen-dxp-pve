#!/bin/sh
# SPDX-License-Identifier: MIT
# Standalone UGREEN LED Hardware Initialization & I2C Bus Binding Utility
set -eu

MODULE_NAME="led-ugreen"
I2C_ADDR="0x3a"
I2C_ADDR_DIR="003a"
CONFIG_FILE="/etc/ugreen/ugreen-leds.env"
ACTION="${1:-bind}"

# Load optional configuration overrides
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

# Ensure kernel modules are available
modprobe i2c-dev 2>/dev/null || true
modprobe "$MODULE_NAME" 2>/dev/null || true

find_i2c_dev() {
    if [ -n "${I2C_BUS:-}" ]; then
        printf 'i2c-%s\n' "$I2C_BUS"
        return 0
    fi

    if command -v i2cdetect >/dev/null 2>&1; then
        i2cdetect -l | awk '/SMBus I801 adapter/ { print $1; exit }'
        return 0
    fi

    for adapter in /sys/class/i2c-adapter/i2c-*; do
        [ -d "$adapter" ] || continue
        if grep -q "SMBus I801 adapter" "$adapter/name" 2>/dev/null; then
            basename "$adapter"
            return 0
        fi
    done
}

set_i2c_paths() {
    i2c_dev="$1"
    bus="${i2c_dev#i2c-}"
    adapter="/sys/bus/i2c/devices/${i2c_dev}"
    device="${adapter}/${bus}-${I2C_ADDR_DIR}"

    if [ ! -d "$adapter" ]; then
        echo "I2C adapter ${i2c_dev} does not exist" >&2
        return 1
    fi
}

bind_i2c_dev() {
    set_i2c_paths "$1" || return 1

    if [ -d "$device" ]; then
        name="$(cat "$device/name")"
        if [ "$name" = "$MODULE_NAME" ]; then
            return 0
        fi
        echo "ERROR: ${bus}-${I2C_ADDR_DIR} is already registered as ${name}" >&2
        return 1
    fi

    echo "${MODULE_NAME} ${I2C_ADDR}" > "${adapter}/new_device"
    echo "Bound ${MODULE_NAME} at ${I2C_ADDR} on ${i2c_dev}"
}

unbind_i2c_dev() {
    set_i2c_paths "$1" || return 1

    if [ ! -d "$device" ]; then
        echo "${MODULE_NAME} is not registered on ${i2c_dev}"
        return 0
    fi

    name="$(cat "$device/name")"
    if [ "$name" != "$MODULE_NAME" ]; then
        echo "ERROR: ${bus}-${I2C_ADDR_DIR} is registered as ${name}, not ${MODULE_NAME}" >&2
        return 1
    fi

    echo "$I2C_ADDR" > "${adapter}/delete_device"
    echo "Unbound ${MODULE_NAME} at ${I2C_ADDR} from ${i2c_dev}"
}

i2c_dev="$(find_i2c_dev)"

if [ -z "$i2c_dev" ]; then
    echo "I2C device not found!" >&2
    echo "Set I2C_BUS=<bus-number> in ${CONFIG_FILE} to force a bus." >&2
    exit 1
fi

case "$ACTION" in
    bind)
        bind_i2c_dev "$i2c_dev"
        ;;
    unbind)
        unbind_i2c_dev "$i2c_dev"
        ;;
    *)
        echo "Usage: $0 [bind|unbind]" >&2
        exit 2
        ;;
esac