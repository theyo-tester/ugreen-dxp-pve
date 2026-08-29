#!/usr/bin/env bash
# UGREEN Multi-Bay HDD & NVMe LED Controller (Hardware Agnostic Auto-Scaling)
# GitHub-ready standalone daemon for UGREEN NAS hardware running Linux / Proxmox VE

COMMON_LIB="/usr/local/lib/ugreen-led-common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
else
    echo "Error: Central library $COMMON_LIB not found." >&2
    exit 1
fi

BRIGHTNESS_SLEEP="${BRIGHTNESS_SLEEP:-5}"
BRIGHTNESS_ACTIVE="${BRIGHTNESS_ACTIVE:-20}"
BRIGHTNESS_FULL="${BRIGHTNESS_FULL:-255}"
IDLE_MINUTES="${IDLE_MINUTES:-15}"
HDD_COLOR="${HDD_COLOR:-white}"
SSD_COLOR="${SSD_COLOR:-blue}"
DEGRADED_COLOR="${DEGRADED_COLOR:-red}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
# SCSI host number -> LED slot offset for HCTL-based mapping (host 0 => disk1 by default; see UGREEN's "Disk Mapping" docs, layout is model-dependent).
HCTL_SLOT_OFFSET="${HCTL_SLOT_OFFSET:-1}"
# Set to 1 to print per-device IO deltas and computed slot/priority each poll, useful for diagnosing activity detection.
HDD_LED_DEBUG="${HDD_LED_DEBUG:-0}"
# On/off durations (ms) for the hardware blink mode used while a slot is actively transferring data.
BLINK_ON_MS="${BLINK_ON_MS:-150}"
BLINK_OFF_MS="${BLINK_OFF_MS:-150}"
# Duration of a single activity flash, in seconds (one on+off blink cycle).
FLASH_DURATION_SEC=$(awk -v on="$BLINK_ON_MS" -v off="$BLINK_OFF_MS" 'BEGIN { printf "%.3f", (on + off) / 1000 }')
# Set to 0 to always use poll-driven flashing, even if bpftrace is installed.
BPFTRACE_ENABLED="${BPFTRACE_ENABLED:-1}"
BPFTRACE_SCRIPT="/run/ugreen-disk-activity.bt"

MAX_IDLE_LOOPS=$(( (IDLE_MINUTES * 60) / POLL_INTERVAL ))

# 1. Standalone I2C & Module Probe Engine
auto_probe_hardware() {
    # Ensure required kernel modules are active
    lsmod | grep -q i2c_dev || modprobe i2c-dev 2>/dev/null || true
    lsmod | grep -q led_ugreen || modprobe led-ugreen 2>/dev/null || true

    # Skip probing if LEDs are already registered in sysfs
    if [ -d "/sys/class/leds/disk1" ]; then
        return 0
    fi

    # Locate the exact I2C bus number corresponding to the Intel SMBus Controller
    local bus_num=""
    for adapter in /sys/class/i2c-adapter/i2c-*; do
        [ -e "$adapter/name" ] || continue
        if grep -q "SMBus I801 adapter" "$adapter/name" 2>/dev/null; then
            bus_num=$(basename "$adapter" | sed 's/i2c-//')
            break
        fi
    done

    # Fallback to i2cdetect parsing if sysfs adapter lookup returned empty
    if [ -z "$bus_num" ] && command -v i2cdetect >/dev/null 2>&1; then
        bus_num=$(i2cdetect -l 2>/dev/null | grep "SMBus I801 adapter" | grep -Po "i2c-\K\d+" | head -n1)
    fi

    # Fallback to bus 0 if detection fails
    bus_num="${bus_num:-0}"

    local dev_path="/sys/bus/i2c/devices/i2c-${bus_num}/${bus_num}-003a"
    local new_dev_file="/sys/bus/i2c/devices/i2c-${bus_num}/new_device"

    if [ ! -d "$dev_path" ] && [ -w "$new_dev_file" ]; then
        echo "led-ugreen 0x3a" > "$new_dev_file" 2>/dev/null || true
        sleep 1
    fi
}

auto_probe_hardware

# 2. Verify sysfs hardware node existence
MAX_BAYS=$(ls -d /sys/class/leds/disk[0-9]* 2>/dev/null | wc -l)
if [ "$MAX_BAYS" -eq 0 ]; then
    echo "Error: No UGREEN disk LEDs found under /sys/class/leds/disk*. Is led-ugreen module loaded?" >&2
    exit 1
fi

# Manual color/brightness writes only take effect if no kernel trigger is
# fighting for control of the LED, so force every disk LED's trigger to "none".
for s in $(seq 1 "$MAX_BAYS"); do
    trig_file="/sys/class/leds/disk${s}/trigger"
    [ -w "$trig_file" ] && echo none > "$trig_file" 2>/dev/null || true
done

set_physical_slot_led() {
    local slot="$1"
    local color_name="$2"
    local brightness="$3"
    local blink_mode="$4"

    local led_dir="/sys/class/leds/disk${slot}"
    if [ -d "$led_dir" ]; then
        local RGB_VAL
        RGB_VAL=$(parse_color "$color_name")
        echo "$RGB_VAL" > "${led_dir}/color" 2>/dev/null || true
        echo "$brightness" > "${led_dir}/brightness" 2>/dev/null || true
        if [ -w "${led_dir}/blink_type" ]; then
            if [ "$blink_mode" -eq 2 ]; then
                # ongoing alert (e.g. degraded drive): blink continuously
                echo "blink ${BLINK_ON_MS} ${BLINK_OFF_MS}" > "${led_dir}/blink_type" 2>/dev/null || true
            else
                echo "none" > "${led_dir}/blink_type" 2>/dev/null || true
            fi
        fi
    fi
}

# Fires exactly one blink cycle so a brief IO burst detected during this poll
# is shown as a single pulse, instead of blinking for the whole poll interval.
# rgb (optional) overrides the slot's color for the pulse, e.g. when bpftrace
# already knows which device (HDD vs NVMe) triggered it.
flash_slot_led() {
    local slot="$1"
    local rgb="$2"
    local led_dir="/sys/class/leds/disk${slot}"
    [ -d "$led_dir" ] || return 0
    if [ -n "$rgb" ]; then
        echo "$rgb" > "${led_dir}/color" 2>/dev/null || true
        echo "$BRIGHTNESS_ACTIVE" > "${led_dir}/brightness" 2>/dev/null || true
    fi
    [ -w "${led_dir}/blink_type" ] || return 0
    echo "blink ${BLINK_ON_MS} ${BLINK_OFF_MS}" > "${led_dir}/blink_type" 2>/dev/null || return 0
    sleep "$FLASH_DURATION_SEC"
    echo "none" > "${led_dir}/blink_type" 2>/dev/null || true
}

# Builds a persistent dev-name -> LED-slot map once at startup. SATA/SAS disks
# are mapped via HCTL (scsi host number), which is stable across reboots,
# unlike the ATA port number previously parsed from /dev/disk/by-path. There's
# no dedicated NVMe LED, so each NVMe (there can be several) shares the LED of
# one HDD bay, in PCI-address order, wrapping back to slot 1 if oversubscribed.
declare -A DEV_SLOT_MAP

build_slot_map() {
    DEV_SLOT_MAP=()

    while read -r name hctl; do
        [ -z "$name" ] && continue
        local host="${hctl%%:*}"
        [[ "$host" =~ ^[0-9]+$ ]] || continue
        local slot=$((host + HCTL_SLOT_OFFSET))
        if [ "$slot" -ge 1 ] && [ "$slot" -le "$MAX_BAYS" ]; then
            DEV_SLOT_MAP[$name]="$slot"
        fi
    done < <(lsblk -S -x hctl -o name,hctl -n 2>/dev/null)

    local nvme_index=0
    for dev_path in $(ls -d /sys/block/nvme*n1 2>/dev/null | sort -V); do
        [ -e "$dev_path" ] || continue
        nvme_index=$((nvme_index + 1))
        local slot=$(( ((nvme_index - 1) % MAX_BAYS) + 1 ))
        DEV_SLOT_MAP[$(basename "$dev_path")]="$slot"
    done
}

get_physical_slot() {
    local dev="$1"
    echo "${DEV_SLOT_MAP[$dev]:-0}"
}

# Prints "MAJOR MINOR" (decimal) for a tracked device, used to key the bpftrace slot map.
resolve_major_minor() {
    local dev="$1"
    local mm maj_hex min_hex
    mm=$(stat -c '%t:%T' "/dev/${dev}" 2>/dev/null) || return 1
    maj_hex="${mm%%:*}"
    min_hex="${mm##*:}"
    printf '%d %d' "$((16#$maj_hex))" "$((16#$min_hex))"
}

# Generates a bpftrace script that maps each tracked device's dev_t to its LED
# slot and resting color once (in BEGIN), then emits "slot R G B" on real data
# IO completion (SMART/temperature-probe passthrough requests are excluded via
# rwbs), debounced per-slot so a shared LED can't be double-fired by two devices.
generate_bpftrace_script() {
    local bt_file="$1"
    local debounce_ns=$(( (BLINK_ON_MS + BLINK_OFF_MS) * 1000000 ))
    local dev mm maj min slot color

    {
        echo "BEGIN"
        echo "{"
        for dev in "${!DEV_SLOT_MAP[@]}"; do
            slot="${DEV_SLOT_MAP[$dev]}"
            mm=$(resolve_major_minor "$dev") || continue
            maj="${mm% *}"
            min="${mm#* }"
            if [[ "$dev" =~ ^nvme ]]; then
                color=$(parse_color "$SSD_COLOR")
            else
                color=$(parse_color "$HDD_COLOR")
            fi
            echo "    @slot[$maj, $min] = $slot;"
            echo "    @color[$maj, $min] = \"$color\";"
        done
        echo "    @debounce_ns = ${debounce_ns};"
        echo "}"
        cat <<'BPF_EOF'

tracepoint:block:block_rq_complete
/str(args->rwbs) == "R" || str(args->rwbs) == "W" || str(args->rwbs) == "WS"/
{
    $maj = args->dev >> 20;
    $min = args->dev & 0xfffff;
    $slot = @slot[$maj, $min];
    if ($slot != 0 && (nsecs - @last[$slot]) > @debounce_ns) {
        @last[$slot] = nsecs;
        printf("%d %s\n", $slot, @color[$maj, $min]);
    }
}
BPF_EOF
    } > "$bt_file"
}

# Starts a bpftrace coprocess that fires flash_slot_led() the instant a real
# IO completes on a tracked device, instead of waiting for the next poll.
start_bpftrace_monitor() {
    BPFTRACE_AVAILABLE=0
    [ "$BPFTRACE_ENABLED" -eq 1 ] || return 0

    local bpftrace_bin
    bpftrace_bin=$(command -v bpftrace 2>/dev/null) || {
        echo "bpftrace not found, falling back to poll-driven flashing" >&2
        return 0
    }

    generate_bpftrace_script "$BPFTRACE_SCRIPT"

    coproc BPFTRACE_CO { exec "$bpftrace_bin" "$BPFTRACE_SCRIPT" 2>/dev/null; }
    BPFTRACE_PID="$BPFTRACE_CO_PID"

    # coproc's own fd slot isn't reliably inherited by a backgrounded subshell, so dup it to a stable fd first.
    exec {BPFTRACE_FD}<&"${BPFTRACE_CO[0]}"

    while read -r -u "$BPFTRACE_FD" bpf_slot bpf_r bpf_g bpf_b; do
        [[ "$bpf_slot" =~ ^[0-9]+$ ]] && flash_slot_led "$bpf_slot" "$bpf_r $bpf_g $bpf_b" &
    done &
    BPFTRACE_READER_PID=$!

    BPFTRACE_AVAILABLE=1
    echo "Event-driven blinking active via bpftrace (pid ${BPFTRACE_PID})."
}

stop_bpftrace_monitor() {
    [ -n "${BPFTRACE_READER_PID:-}" ] && kill "$BPFTRACE_READER_PID" 2>/dev/null || true
    [ -n "${BPFTRACE_PID:-}" ] && kill "$BPFTRACE_PID" 2>/dev/null || true
    [ -n "${BPFTRACE_FD:-}" ] && exec {BPFTRACE_FD}<&- 2>/dev/null || true
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

build_slot_map
start_bpftrace_monitor
trap stop_bpftrace_monitor EXIT

echo "Starting UGREEN Disk LED Daemon (Detected ${MAX_BAYS} Physical Bays)..."
for dev in "${!DEV_SLOT_MAP[@]}"; do
    echo "  Mapped /dev/${dev} -> disk${DEV_SLOT_MAP[$dev]}"
done

while true; do
    DEGRADED_DRIVES=$(get_degraded_drives)

    declare -A SLOT_COLOR
    declare -A SLOT_BRIGHTNESS
    declare -A SLOT_PRIORITY
    declare -A SLOT_BLINK_MODE

    for s in $(seq 1 "$MAX_BAYS"); do
        SLOT_COLOR[$s]="$HDD_COLOR"
        SLOT_BRIGHTNESS[$s]="$BRIGHTNESS_SLEEP"
        SLOT_PRIORITY[$s]=0
        SLOT_BLINK_MODE[$s]=0
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

        cand_priority=0
        cand_color="$HDD_COLOR"
        cand_brightness="$BRIGHTNESS_SLEEP"
        cand_blink_mode=0

        if [[ " $DEGRADED_DRIVES " == *" $dev "* ]]; then
            cand_priority=5
            cand_color="$DEGRADED_COLOR"
            cand_brightness="$BRIGHTNESS_FULL"
            cand_blink_mode=2
        elif [[ "$dev" =~ ^nvme ]]; then
            if [ "$BPFTRACE_AVAILABLE" -eq 0 ] && [ "$is_active" -eq 1 ]; then
                cand_priority=4
                cand_color="$SSD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
                cand_blink_mode=1
            fi
        else
            if [ "$BPFTRACE_AVAILABLE" -eq 0 ] && [ "$is_active" -eq 1 ]; then
                cand_priority=3
                cand_color="$HDD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
                cand_blink_mode=1
            elif [ "$idle_cnt" -lt "$MAX_IDLE_LOOPS" ]; then
                cand_priority=1
                cand_color="$HDD_COLOR"
                cand_brightness="$BRIGHTNESS_ACTIVE"
            fi
        fi

        if [ "$cand_priority" -gt "${SLOT_PRIORITY[$slot]}" ]; then
            SLOT_PRIORITY[$slot]="$cand_priority"
            SLOT_COLOR[$slot]="$cand_color"
            SLOT_BRIGHTNESS[$slot]="$cand_brightness"
            SLOT_BLINK_MODE[$slot]="$cand_blink_mode"
        fi

        if [ "$HDD_LED_DEBUG" -eq 1 ]; then
            echo "[debug] dev=$dev slot=$slot prev_io=$prev_io curr_io=$curr_io is_active=$is_active idle_cnt=$idle_cnt cand_priority=$cand_priority" >&2
        fi
    done

    for slot in $(seq 1 "$MAX_BAYS"); do
        set_physical_slot_led "$slot" "${SLOT_COLOR[$slot]}" "${SLOT_BRIGHTNESS[$slot]}" "${SLOT_BLINK_MODE[$slot]}"
    done

    for slot in $(seq 1 "$MAX_BAYS"); do
        [ "${SLOT_BLINK_MODE[$slot]}" -eq 1 ] && flash_slot_led "$slot" &
    done
    wait

    sleep "$POLL_INTERVAL"
done