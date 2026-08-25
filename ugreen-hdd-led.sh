#!/usr/bin/env bash
# UGREEN Multi-Bay HDD & NVMe LED Controller (Hardware Agnostic Auto-Scaling)

ENV_FILE="/etc/ugreen/ugreen-leds.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

BRIGHTNESS_SLEEP="${BRIGHTNESS_SLEEP:-5}"
BRIGHTNESS_ACTIVE="${BRIGHTNESS_ACTIVE:-20}"
BRIGHTNESS_FULL="${BRIGHTNESS_FULL:-255}"
IDLE_MINUTES="${IDLE_MINUTES:-15}"
HDD_COLOR="${HDD_COLOR:-white}"
SSD_COLOR="${SSD_COLOR:-amber}"
DEGRADED_COLOR="${DEGRADED_COLOR:-red}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

MAX_IDLE_LOOPS=$(( (IDLE_MINUTES * 60) / POLL_INTERVAL ))

# 1. Exit immediately if kernel module/sysfs entries are missing
MAX_BAYS=$(ls -d /sys/class/leds/ugreen:white:disk* 2>/dev/null | wc -l)
if [ "$MAX_BAYS" -eq 0 ]; then
    echo "Error: No UGREEN disk LEDs found in /sys/class/leds/. Is the driver loaded? Exiting." >&2
    exit 1
fi

set_physical_slot_led() {
    local slot="$1"
    local color="$2"
    local brightness="$3"

    for c in white amber red; do
        local led_file="/sys/class/leds/ugreen:${c}:disk${slot}/brightness"
        if [ -f "$led_file" ]; then
            if [ "$c" = "$color" ]; then
                echo "$brightness" > "$led_file" 2>/dev/null || true
            else
                echo 0 > "$led_file" 2>/dev/null || true
            fi
        fi
    done
}

get_physical_slot() {
    local dev="$1"
    local by_path
    by_path=$(find -L /dev/disk/by-path/ -samefile "/dev/${dev}" 2>/dev/null | head -n1)

    if [ -z "$by_path" ]; then
        echo 0
        return
    fi

    if [[ "$by_path" =~ -ata-([0-9]+) ]]; then
        local port="${BASH_REMATCH[1]}"
        if [ "$port" -le "$MAX_BAYS" ]; then
            echo "$port"
        else
            echo 0
        fi
    elif [[ "$by_path" =~ nvme-1 ]]; then
        local pci_addr
        pci_addr=$(echo "$by_path" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]')

        local nvme_index=0
        for addr in $(ls -l /dev/disk/by-path/*nvme-1 2>/dev/null | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | sort -u); do
            nvme_index=$((nvme_index + 1))
            if [ "$addr" = "$pci_addr" ]; then
                break
            fi
        done
        
        if [ "$nvme_index" -le "$MAX_BAYS" ]; then
            echo "$nvme_index"
        else
            echo 0
        fi
    else
        echo 0
    fi
}

get_degraded_drives() {
    local degraded_list=""
    if command -v zpool >/dev/null 2>&1; then
        while read -r target status; do
            [ -z "$target" ] && continue
            local resolved_dev
            resolved_dev=$(readlink -f "/dev/$target" 2>/dev/null || readlink -f "$target" 2>/dev/null || echo "$target")
            local base_dev
            base_dev=$(basename "$resolved_dev" | sed -E 's/p?[0-9]+$//')
            degraded_list="${degraded_list} ${base_dev}"
        done < <(zpool status -P 2>/dev/null | awk '/FAULTED|DEGRADED|UNAVAIL|REMOVED/ {print $1, $2}')
    fi
    echo "$degraded_list"
}

declare -A PREV_IO
declare -A IDLE_COUNTERS

echo "Starting UGREEN Disk LED Daemon (Detected ${MAX_BAYS} Physical Bays)..."

while true; do
    DEGRADED_DRIVES=$(get_degraded_drives)

    declare -A SLOT_COLOR
    declare -A SLOT_BRIGHTNESS
    declare -A SLOT_PRIORITY

    # Reset physical slots to baseline idle state
    for s in $(seq 1 "$MAX_BAYS"); do
        SLOT_COLOR[$s]="$HDD_COLOR"
        SLOT_BRIGHTNESS[$s]="$BRIGHTNESS_SLEEP"
        SLOT_PRIORITY[$s]=0
    done

    for dev_path in /sys/block/sd* /sys/block/nvme*n1; do
        [ -e "$dev_path" ] || continue
        dev=$(basename "$dev_path")

        slot=$(get_physical_slot "$dev")
        [ "$slot" -eq 0 ] && continue

        r_sec=$(awk '{print $3}' "${dev_path}/stat" 2>/dev/null || echo 0)
        w_sec=$(awk '{print $7}' "${dev_path}/stat" 2>/dev/null || echo 0)
        curr_io=$((r_sec + w_sec))

        prev_io="${PREV_IO[$dev]:-0}"
        idle_cnt="${IDLE_COUNTERS[$dev]:-0}"

        is_active=0
        if [ "$curr_io" -gt "$prev_io" ] && [ "$prev_io" -ne 0 ]; then
            IDLE_COUNTERS[$dev]=0
            is_active=1
        else
            idle_cnt=$((idle_cnt + 1))
            IDLE_COUNTERS[$dev]="$idle_cnt"
        fi
        PREV_IO[$dev]="$curr_io"

        # Determine candidate drive state and priority
        cand_priority=0
        cand_color="$HDD_COLOR"
        cand_brightness="$BRIGHTNESS_SLEEP"

        if [[ " $DEGRADED_DRIVES " == *" $dev "* ]]; then
            cand_priority=5
            cand_color="$DEGRADED_COLOR"
            cand_brightness="$BRIGHTNESS_FULL"
        elif [[ "$dev" =~ ^nvme ]]; then
            if [ "$is_active" -eq 1 ]; then
                cand_priority=4
                cand_color="$SSD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
            elif [ "$idle_cnt" -lt "$MAX_IDLE_LOOPS" ]; then
                cand_priority=2
                cand_color="$SSD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
            fi
        else
            if [ "$is_active" -eq 1 ]; then
                cand_priority=3
                cand_color="$HDD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
            elif [ "$idle_cnt" -lt "$MAX_IDLE_LOOPS" ]; then
                cand_priority=1
                cand_color="$HDD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
            fi
        fi

        # 2. Directly evaluate candidate priority against current slot priority
        if [ "$cand_priority" -gt "${SLOT_PRIORITY[$slot]}" ]; then
            SLOT_PRIORITY[$slot]="$cand_priority"
            SLOT_COLOR[$slot]="$cand_color"
            SLOT_BRIGHTNESS[$slot]="$cand_brightness"
        fi
    done

    # Apply highest-priority visual state to each slot
    for slot in $(seq 1 "$MAX_BAYS"); do
        set_physical_slot_led "$slot" "${SLOT_COLOR[$slot]}" "${SLOT_BRIGHTNESS[$slot]}"
    done

    sleep "$POLL_INTERVAL"
done
