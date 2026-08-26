#!/usr/bin/env bash
# Central shared library & color parser for UGREEN LED controllers
# Sourced by ugreen-hdd-led.sh, ugreen-net-led.sh, and setup scripts

ENV_FILE="/etc/ugreen/ugreen-leds.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Normalizes human-readable color names or custom RGB strings to space-separated "R G B" format
parse_color() {
    local input="${1:-white}"

    case "${input,,}" in
        white)          echo "255 255 255" ;;
        amber|orange)    echo "255 60 0" ;;
        red)            echo "255 0 0" ;;
        green)          echo "0 255 0" ;;
        blue)           echo "0 0 255" ;;
        cyan)           echo "0 255 255" ;;
        purple|magenta) echo "255 0 255" ;;
        yellow)         echo "255 255 0" ;;
        off|none)       echo "0 0 0" ;;
        *)
            # Allow pass-through if custom RGB sequence (e.g., "100 200 50") was provided
            if [[ "$input" =~ ^[0-9]{1,3}\ [0-9]{1,3}\ [0-9]{1,3}$ ]]; then
                echo "$input"
            else
                echo "255 255 255"
            fi
            ;;
    esac
}