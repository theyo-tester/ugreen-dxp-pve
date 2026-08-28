#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root!${NC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/ugreen-setup"

echo -e "${CYAN}=== Starting UGREEN NASsync Deployment ===${NC}"
echo -e "${YELLOW}Working Directory: ${WORK_DIR}${NC}"
echo -e "${YELLOW}Target Config Directory: /etc/ugreen${NC}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p /etc/ugreen

echo -e "${CYAN}=== 1. Installing System Dependencies ===${NC}"
apt update
apt install -y proxmox-default-headers dkms build-essential i2c-tools git cmake lm-sensors smartmontools nvme-cli python3 sysstat hdparm iproute2 bpftrace

if ! grep -q "^drivetemp" /etc/modules; then
    echo "drivetemp" >> /etc/modules
fi
modprobe drivetemp || true

echo -e "${CYAN}=== 2. Compiling ITE Sensor Driver (it87 via DKMS) ===${NC}"
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

echo -e "${CYAN}=== 3. Compiling UGREEN LED Kernel Module (led-ugreen via DKMS) ===${NC}"
cd "$WORK_DIR"
git clone https://github.com/miskcoo/ugreen_leds_controller.git
cd ugreen_leds_controller
cp -r kmod /usr/src/led-ugreen-0.1
dkms remove -m led-ugreen -v 0.1 --all 2>/dev/null || true
dkms add -m led-ugreen -v 0.1
dkms build -m led-ugreen -v 0.1
dkms install -m led-ugreen -v 0.1

cat > /etc/modules-load.d/ugreen-led.conf << EOF
i2c-dev
led-ugreen
ledtrig-netdev
EOF
modprobe i2c-dev led-ugreen ledtrig-netdev || true

echo -e "${CYAN}=== 4. Deploying Local Executables ===${NC}"
cp "${SCRIPT_DIR}/ugreen-fan-control.py" /usr/local/bin/ugreen-fan-control.py

cp "${SCRIPT_DIR}/ugreen-led-common.sh" /usr/local/lib/ugreen-led-common.sh
cp "${SCRIPT_DIR}/ugreen-led-setup.sh" /usr/local/bin/ugreen-led-setup.sh
cp "${SCRIPT_DIR}/ugreen-net-led.sh" /usr/local/bin/ugreen-net-led.sh
cp "${SCRIPT_DIR}/ugreen-hdd-led.sh" /usr/local/bin/ugreen-hdd-led.sh
chmod +x /usr/local/lib/ugreen-led-common.sh /usr/local/bin/ugreen-led-setup.sh /usr/local/bin/ugreen-fan-control.py /usr/local/bin/ugreen-net-led.sh /usr/local/bin/ugreen-hdd-led.sh 

echo -e "${CYAN}=== 5. Deploying Environment Configurations & Services ===${NC}"
if [ ! -f /etc/ugreen/ugreen-fan-control.env ]; then
    cp "${SCRIPT_DIR}/ugreen-fan-control.env" /etc/ugreen/ugreen-fan-control.env
    echo -e "${GREEN}Created /etc/ugreen/ugreen-fan-control.env${NC}"
fi

if [ ! -f /etc/ugreen/ugreen-leds.env ]; then
    cp "${SCRIPT_DIR}/ugreen-leds.env" /etc/ugreen/ugreen-leds.env
    echo -e "${GREEN}Created /etc/ugreen/ugreen-leds.env${NC}"
fi


cp "${SCRIPT_DIR}/ugreen-led-setup.service" /etc/systemd/system/ugreen-led-setup.service
cp "${SCRIPT_DIR}/ugreen-fan-control.service" /etc/systemd/system/ugreen-fan-control.service
cp "${SCRIPT_DIR}/ugreen-hdd-led.service" /etc/systemd/system/ugreen-hdd-led.service
cp "${SCRIPT_DIR}/ugreen-net-led.service" /etc/systemd/system/ugreen-net-led.service

echo -e "${CYAN}=== 6. Enabling Systemd Services ===${NC}"
systemctl disable --now fancontrol 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now ugreen-led-setup.service
systemctl enable --now ugreen-fan-control.service
systemctl enable --now ugreen-hdd-led.service
systemctl enable --now ugreen-net-led.service

rm -rf "$WORK_DIR"
echo -e "${GREEN}=== Deployment Completed Successfully! ===${NC}"

rm -rf "$WORK_DIR"
echo -e "${GREEN}=== Installation completed successfully! ===${NC}"
