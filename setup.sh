#!/usr/bin/env bash
set -euo pipefail

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root!${NC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}=== 1. Installing system dependencies and enabling drivetemp module ===${NC}"
apt update
apt install -y proxmox-default-headers dkms build-essential git cmake lm-sensors smartmontools nvme-cli python3

if ! grep -q "^drivetemp" /etc/modules; then
    echo "drivetemp" >> /etc/modules
fi
modprobe drivetemp || true

WORK_DIR="/tmp/ugreen-setup"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo -e "${CYAN}=== 2. Compiling and installing ITE sensor driver (it87 via DKMS) ===${NC}"
cd "$WORK_DIR"
git clone https://github.com/frankcrawford/it87.git
cd it87

IT87_VER=$(grep -E "^PACKAGE_VERSION=" dkms.conf | cut -d'"' -f2 || echo "1.0")
IT87_DIR="/usr/src/it87-${IT87_VER}"

cd ..
rm -rf "$IT87_DIR"
cp -r it87 "$IT87_DIR"

dkms remove -m it87 -v "$IT87_VER" --all 2>/dev/null || true
dkms add -m it87 -v "$IT87_VER"
dkms build -m it87 -v "$IT87_VER"
dkms install -m it87 -v "$IT87_VER"

echo "options it87 ignore_resource_conflict=1" > /etc/modprobe.d/it87.conf
modprobe it87 ignore_resource_conflict=1 || true

echo -e "${CYAN}=== 3. Deploying UGREEN Fan Control components ===${NC}"
cp "${SCRIPT_DIR}/ugreen-fan-control.py" /usr/local/bin/ugreen-fan-control.py
chmod +x /usr/local/bin/ugreen-fan-control.py

if [ ! -f /etc/ugreen-fan-control.env ]; then
    cp "${SCRIPT_DIR}/ugreen-fan-control.env" /etc/ugreen-fan-control.env
    echo -e "${GREEN}Default configuration created at /etc/ugreen-fan-control.env${NC}"
else
    echo -e "${YELLOW}File /etc/ugreen-fan-control.env already exists, skipping overwrite.${NC}"
fi

cp "${SCRIPT_DIR}/ugreen-fan-control.service" /etc/systemd/system/ugreen-fan-control.service

echo -e "${CYAN}=== 4. Compiling and installing UGREEN LED Controller ===${NC}"
cd "$WORK_DIR"
git clone https://github.com/miskcoo/ugreen_leds_controller.git
cd ugreen_leds_controller
make
cp ugreen_leds /usr/local/bin/ugreen_leds
chmod +x /usr/local/bin/ugreen_leds

cp "${SCRIPT_DIR}/ugreen-leds.service" /etc/systemd/system/ugreen-leds.service

echo -e "${CYAN}=== 5. Enabling and starting Systemd services ===${NC}"
systemctl disable --now fancontrol 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now ugreen-fan-control.service
systemctl enable --now ugreen-leds.service

rm -rf "$WORK_DIR"
echo -e "${GREEN}=== Installation completed successfully! ===${NC}"
