#!/bin/bash
#
# GRUB SNES Gamepad Installer v0.9
# https://github.com/nuevauno/grub-snes-gamepad
#
# Builds and installs a custom GRUB module for USB gamepad support
# Based on https://github.com/tsoding/grub (grub-gamepad branch)
#

VERSION="0.9"

set -Eeuo pipefail

# Trap errors for better debugging
trap 'echo "Error at line $LINENO. Exit code: $?" >&2' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Global variables
GRUB_DIR=""
GRUB_MOD_DIR=""
GRUB_PLATFORM=""
DISTRO=""
CONTROLLER_VID=""
CONTROLLER_PID=""
BUTTONS_DETECTED=0
BUILD_DIR="/tmp/grub-snes-build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Spinner function - runs in background (ASCII only: |/-\)
spinner_pid=""

start_spinner() {
    local msg="$1"
    (
        chars='|/-\'
        while true; do
            for (( i=0; i<${#chars}; i++ )); do
                printf "\r  [%s] %s" "${chars:$i:1}" "$msg"
                sleep 0.2
            done
        done
    ) &
    spinner_pid=$!
}

stop_spinner() {
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        spinner_pid=""
        printf "\r                                                              \r"
    fi
}

# Cleanup on exit
cleanup() {
    stop_spinner
    # Only cleanup build dir if we created it and something went wrong
    if [ -d "$BUILD_DIR" ] && [ "${KEEP_BUILD:-0}" != "1" ]; then
        rm -rf "$BUILD_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}=======================================================${NC}"
    echo -e "${CYAN}${BOLD}       GRUB SNES Gamepad Installer v${VERSION}                ${NC}"
    echo -e "${CYAN}${BOLD}       Control your bootloader with a game controller  ${NC}"
    echo -e "${CYAN}${BOLD}=======================================================${NC}"
    echo ""
    echo -e "  ${DIM}Version: ${VERSION} | github.com/nuevauno/grub-snes-gamepad${NC}"
    echo ""
}

print_step() {
    echo ""
    echo ""
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BLUE}  STEP ${1}/${2}: ${BOLD}${3}${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo ""
}

ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

# Run command with spinner
run_with_spinner() {
    local msg="$1"
    local logfile="$2"
    shift 2

    start_spinner "$msg"
    if "$@" > "$logfile" 2>&1; then
        stop_spinner
        return 0
    else
        stop_spinner
        return 1
    fi
}

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Run as root${NC}"
    echo "Usage: sudo bash install.sh"
    exit 1
fi

print_header

#######################################
# STEP 1: Check system
#######################################
print_step 1 6 "Checking system"

# Detect distro
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="$ID"
else
    DISTRO="unknown"
fi
ok "Distro: $DISTRO"

# Check GRUB
if [ -d "/boot/grub" ]; then
    GRUB_DIR="/boot/grub"
    ok "GRUB found: $GRUB_DIR"
elif [ -d "/boot/grub2" ]; then
    GRUB_DIR="/boot/grub2"
    ok "GRUB2 found: $GRUB_DIR"
else
    err "GRUB not found!"
    exit 1
fi

# Determine module dir
if [ -d "$GRUB_DIR/x86_64-efi" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/x86_64-efi"
    GRUB_PLATFORM="x86_64-efi"
elif [ -d "$GRUB_DIR/i386-pc" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/i386-pc"
    GRUB_PLATFORM="i386-pc"
else
    err "Could not determine GRUB platform"
    exit 1
fi
ok "Platform: $GRUB_PLATFORM"

# Check for Python3 (needed for controller mapping)
if ! command -v python3 > /dev/null 2>&1; then
    err "Python3 is required but not installed"
    info "Install with: apt install python3 python3-pip"
    exit 1
fi
ok "Python3 found: $(python3 --version 2>&1)"

#######################################
# STEP 2: Detect controller
#######################################
print_step 2 6 "Detecting USB controller"

echo -e "  ${YELLOW}${BOLD}Please connect your SNES USB controller now${NC}"
echo ""
read -r -p "  Press ENTER when connected... " _DUMMY
echo ""

# Find controllers
CONTROLLER_LINE=$(lsusb | grep -iE "(0810|0079|0583|2dc8|12bd|1a34|game|pad|joystick|snes)" | head -1 || true)

if [ -z "$CONTROLLER_LINE" ]; then
    err "No game controller detected!"
    echo ""
    info "All USB devices:"
    lsusb | sed 's/^/    /'
    echo ""
    err "Connect your SNES controller and run again"
    exit 1
fi

# Extract ID using sed (more portable than grep -P)
CONTROLLER_ID=$(echo "$CONTROLLER_LINE" | sed -n 's/.*ID \([0-9a-f]*:[0-9a-f]*\).*/\1/p')
CONTROLLER_VID="0x$(echo "$CONTROLLER_ID" | cut -d: -f1)"
CONTROLLER_PID="0x$(echo "$CONTROLLER_ID" | cut -d: -f2)"

ok "Found: $CONTROLLER_LINE"
ok "VID: $CONTROLLER_VID  PID: $CONTROLLER_PID"

#######################################
# STEP 3: Map controller buttons (MANDATORY - BEFORE installing deps)
#######################################
print_step 3 6 "Mapping controller buttons (MANDATORY)"

echo -e "  ${RED}${BOLD}*********************************************${NC}"
echo -e "  ${RED}${BOLD}*  BUTTON MAPPING - MUST COMPLETE TO CONTINUE  *${NC}"
echo -e "  ${RED}${BOLD}*********************************************${NC}"
echo ""
echo -e "  ${YELLOW}You will be asked to press 4 buttons.${NC}"
echo -e "  ${YELLOW}At least 2 must be detected to continue.${NC}"
echo ""

# Install only pyusb for mapping (minimal dependency)
info "Installing Python USB library for controller mapping..."
if pip3 install --quiet pyusb 2>/dev/null; then
    ok "pyusb installed via pip3"
elif pip install --quiet pyusb 2>/dev/null; then
    ok "pyusb installed via pip"
elif pip3 install --quiet --break-system-packages pyusb 2>/dev/null; then
    ok "pyusb installed (break-system-packages)"
else
    err "Could not install pyusb"
    err "Try manually: pip3 install pyusb"
    exit 1
fi

# Verify pyusb is actually importable
if ! python3 -c "import usb.core" 2>/dev/null; then
    err "pyusb installed but cannot be imported"
    err "This usually means a missing dependency (libusb)"
    info "Try: apt install libusb-1.0-0-dev"
    exit 1
fi
ok "Python USB library verified"

echo ""
echo -e "  ${CYAN}Get ready to press buttons on your controller!${NC}"
echo ""
sleep 2

# Create Python script for button mapping (avoiding heredoc for Python code)
PYSCRIPT=$(mktemp /tmp/mapper_XXXXXX.py)

# Write Python script line by line to avoid heredoc issues
printf '%s\n' '#!/usr/bin/env python3' > "$PYSCRIPT"
printf '%s\n' '"""Controller Button Mapper - Tests controller and maps buttons."""' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'import os, sys, time, json' >> "$PYSCRIPT"
printf '%s\n' 'import usb.core, usb.util' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' '# ANSI colors (ASCII only)' >> "$PYSCRIPT"
printf '%s\n' "GREEN = '\\033[92m'" >> "$PYSCRIPT"
printf '%s\n' "YELLOW = '\\033[93m'" >> "$PYSCRIPT"
printf '%s\n' "RED = '\\033[91m'" >> "$PYSCRIPT"
printf '%s\n' "CYAN = '\\033[96m'" >> "$PYSCRIPT"
printf '%s\n' "BOLD = '\\033[1m'" >> "$PYSCRIPT"
printf '%s\n' "DIM = '\\033[2m'" >> "$PYSCRIPT"
printf '%s\n' "NC = '\\033[0m'" >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'def ok(t): print("  " + GREEN + "[OK]" + NC + " " + t)' >> "$PYSCRIPT"
printf '%s\n' 'def err(t): print("  " + RED + "[ERROR]" + NC + " " + t)' >> "$PYSCRIPT"
printf '%s\n' 'def warn(t): print("  " + YELLOW + "[WARN]" + NC + " " + t)' >> "$PYSCRIPT"
printf '%s\n' 'def info(t): print("  " + CYAN + "[INFO]" + NC + " " + t)' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'KNOWN_CONTROLLERS = {' >> "$PYSCRIPT"
printf '%s\n' '    (0x0810, 0xe501): "Generic SNES",' >> "$PYSCRIPT"
printf '%s\n' '    (0x0079, 0x0011): "DragonRise",' >> "$PYSCRIPT"
printf '%s\n' '    (0x0583, 0x2060): "iBuffalo",' >> "$PYSCRIPT"
printf '%s\n' '    (0x2dc8, 0x9018): "8BitDo",' >> "$PYSCRIPT"
printf '%s\n' '    (0x12bd, 0xd015): "Generic 2-pack",' >> "$PYSCRIPT"
printf '%s\n' '    (0x1a34, 0x0802): "USB Gamepad",' >> "$PYSCRIPT"
printf '%s\n' '    (0x0810, 0x0001): "Generic USB Gamepad",' >> "$PYSCRIPT"
printf '%s\n' '    (0x0079, 0x0006): "DragonRise Gamepad",' >> "$PYSCRIPT"
printf '%s\n' '}' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'def find_controller():' >> "$PYSCRIPT"
printf '%s\n' '    """Find the first game controller"""' >> "$PYSCRIPT"
printf '%s\n' '    for dev in usb.core.find(find_all=True):' >> "$PYSCRIPT"
printf '%s\n' '        key = (dev.idVendor, dev.idProduct)' >> "$PYSCRIPT"
printf '%s\n' '        if key in KNOWN_CONTROLLERS:' >> "$PYSCRIPT"
printf '%s\n' '            return dev, KNOWN_CONTROLLERS[key]' >> "$PYSCRIPT"
printf '%s\n' '        try:' >> "$PYSCRIPT"
printf '%s\n' '            for cfg in dev:' >> "$PYSCRIPT"
printf '%s\n' '                for intf in cfg:' >> "$PYSCRIPT"
printf '%s\n' '                    if intf.bInterfaceClass == 3:' >> "$PYSCRIPT"
printf '%s\n' '                        if intf.bInterfaceSubClass == 1 and intf.bInterfaceProtocol in [1, 2]:' >> "$PYSCRIPT"
printf '%s\n' '                            continue' >> "$PYSCRIPT"
printf '%s\n' '                        return dev, "USB Controller"' >> "$PYSCRIPT"
printf '%s\n' '        except: pass' >> "$PYSCRIPT"
printf '%s\n' '    return None, None' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'def setup_device(dev):' >> "$PYSCRIPT"
printf '%s\n' '    """Setup USB device for reading"""' >> "$PYSCRIPT"
printf '%s\n' '    try:' >> "$PYSCRIPT"
printf '%s\n' '        if dev.is_kernel_driver_active(0):' >> "$PYSCRIPT"
printf '%s\n' '            dev.detach_kernel_driver(0)' >> "$PYSCRIPT"
printf '%s\n' '    except: pass' >> "$PYSCRIPT"
printf '%s\n' '    try: dev.set_configuration()' >> "$PYSCRIPT"
printf '%s\n' '    except: pass' >> "$PYSCRIPT"
printf '%s\n' '    cfg = dev.get_active_configuration()' >> "$PYSCRIPT"
printf '%s\n' '    intf = cfg[(0, 0)]' >> "$PYSCRIPT"
printf '%s\n' '    for endpoint in intf:' >> "$PYSCRIPT"
printf '%s\n' '        if usb.util.endpoint_direction(endpoint.bEndpointAddress) == usb.util.ENDPOINT_IN:' >> "$PYSCRIPT"
printf '%s\n' '            return endpoint' >> "$PYSCRIPT"
printf '%s\n' '    return None' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'def get_baseline(dev, ep):' >> "$PYSCRIPT"
printf '%s\n' '    """Get baseline report (no buttons pressed)"""' >> "$PYSCRIPT"
printf '%s\n' '    print("")' >> "$PYSCRIPT"
printf '%s\n' '    info("Reading baseline (do NOT press any buttons)...")' >> "$PYSCRIPT"
printf '%s\n' '    time.sleep(0.5)' >> "$PYSCRIPT"
printf '%s\n' '    reports = []' >> "$PYSCRIPT"
printf '%s\n' '    for _ in range(15):' >> "$PYSCRIPT"
printf '%s\n' '        try:' >> "$PYSCRIPT"
printf '%s\n' '            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))' >> "$PYSCRIPT"
printf '%s\n' '            reports.append(r)' >> "$PYSCRIPT"
printf '%s\n' '        except: pass' >> "$PYSCRIPT"
printf '%s\n' '        time.sleep(0.05)' >> "$PYSCRIPT"
printf '%s\n' '    if not reports: return None' >> "$PYSCRIPT"
printf '%s\n' '    return max(set(reports), key=reports.count)' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'def wait_for_button(dev, ep, baseline, button_name, timeout=15):' >> "$PYSCRIPT"
printf '%s\n' '    """Wait for a button press and detect the change"""' >> "$PYSCRIPT"
printf '%s\n' '    sys.stdout.write("  " + YELLOW + ">>> Press " + BOLD + button_name + NC + YELLOW + " <<<" + NC)' >> "$PYSCRIPT"
printf '%s\n' '    sys.stdout.flush()' >> "$PYSCRIPT"
printf '%s\n' '    start = time.time()' >> "$PYSCRIPT"
printf '%s\n' '    while time.time() - start < timeout:' >> "$PYSCRIPT"
printf '%s\n' '        try:' >> "$PYSCRIPT"
printf '%s\n' '            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))' >> "$PYSCRIPT"
printf '%s\n' '            if r != baseline:' >> "$PYSCRIPT"
printf '%s\n' '                changes = []' >> "$PYSCRIPT"
printf '%s\n' '                for i in range(min(len(baseline), len(r))):' >> "$PYSCRIPT"
printf '%s\n' '                    if baseline[i] != r[i]:' >> "$PYSCRIPT"
printf '%s\n' '                        changes.append((i, baseline[i], r[i]))' >> "$PYSCRIPT"
printf '%s\n' '                if changes:' >> "$PYSCRIPT"
printf '%s\n' '                    i, a, b = changes[0]' >> "$PYSCRIPT"
printf '%s\n' '                    result = "  " + GREEN + "[OK]" + NC + " " + button_name + ": Byte " + str(i) + " = 0x" + format(a, "02x") + " -> 0x" + format(b, "02x")' >> "$PYSCRIPT"
printf '%s\n' '                    print("\\r" + result + "                    ")' >> "$PYSCRIPT"
printf '%s\n' '                    release_start = time.time()' >> "$PYSCRIPT"
printf '%s\n' '                    while time.time() - release_start < 2:' >> "$PYSCRIPT"
printf '%s\n' '                        try:' >> "$PYSCRIPT"
printf '%s\n' '                            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))' >> "$PYSCRIPT"
printf '%s\n' '                            if r == baseline: break' >> "$PYSCRIPT"
printf '%s\n' '                        except: break' >> "$PYSCRIPT"
printf '%s\n' '                        time.sleep(0.01)' >> "$PYSCRIPT"
printf '%s\n' '                    return changes' >> "$PYSCRIPT"
printf '%s\n' '        except usb.core.USBTimeoutError: pass' >> "$PYSCRIPT"
printf '%s\n' '        except: pass' >> "$PYSCRIPT"
printf '%s\n' '        time.sleep(0.01)' >> "$PYSCRIPT"
printf '%s\n' '    print("\\r  " + YELLOW + "[TIMEOUT]" + NC + " " + button_name + ": No press detected                    ")' >> "$PYSCRIPT"
printf '%s\n' '    return None' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'def main():' >> "$PYSCRIPT"
printf '%s\n' '    dev, name = find_controller()' >> "$PYSCRIPT"
printf '%s\n' '    if not dev:' >> "$PYSCRIPT"
printf '%s\n' '        err("No controller found!")' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(1)' >> "$PYSCRIPT"
printf '%s\n' '    ok("Controller: " + name + " (VID: 0x" + format(dev.idVendor, "04x") + " PID: 0x" + format(dev.idProduct, "04x") + ")")' >> "$PYSCRIPT"
printf '%s\n' '    ep = setup_device(dev)' >> "$PYSCRIPT"
printf '%s\n' '    if not ep:' >> "$PYSCRIPT"
printf '%s\n' '        err("Could not find USB endpoint!")' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(1)' >> "$PYSCRIPT"
printf '%s\n' '    ok("USB endpoint ready: 0x" + format(ep.bEndpointAddress, "02x"))' >> "$PYSCRIPT"
printf '%s\n' '    baseline = get_baseline(dev, ep)' >> "$PYSCRIPT"
printf '%s\n' '    if not baseline:' >> "$PYSCRIPT"
printf '%s\n' '        err("Cannot read from controller!")' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(1)' >> "$PYSCRIPT"
printf '%s\n' '    ok("Baseline: " + baseline.hex())' >> "$PYSCRIPT"
printf '%s\n' '    print("")' >> "$PYSCRIPT"
printf '%s\n' '    print("  " + BOLD + "Press each button when prompted (15 sec timeout each):" + NC)' >> "$PYSCRIPT"
printf '%s\n' '    print("")' >> "$PYSCRIPT"
printf '%s\n' '    buttons_to_test = [' >> "$PYSCRIPT"
printf '%s\n' '        ("D-PAD UP", "up"),' >> "$PYSCRIPT"
printf '%s\n' '        ("D-PAD DOWN", "down"),' >> "$PYSCRIPT"
printf '%s\n' '        ("A BUTTON (or any face button)", "a"),' >> "$PYSCRIPT"
printf '%s\n' '        ("START (or any other button)", "start"),' >> "$PYSCRIPT"
printf '%s\n' '    ]' >> "$PYSCRIPT"
printf '%s\n' '    mapping = {}' >> "$PYSCRIPT"
printf '%s\n' '    buttons_detected = 0' >> "$PYSCRIPT"
printf '%s\n' '    for display_name, key in buttons_to_test:' >> "$PYSCRIPT"
printf '%s\n' '        result = wait_for_button(dev, ep, baseline, display_name)' >> "$PYSCRIPT"
printf '%s\n' '        if result:' >> "$PYSCRIPT"
printf '%s\n' '            mapping[key] = result' >> "$PYSCRIPT"
printf '%s\n' '            buttons_detected += 1' >> "$PYSCRIPT"
printf '%s\n' '        time.sleep(0.3)' >> "$PYSCRIPT"
printf '%s\n' '    print("")' >> "$PYSCRIPT"
printf '%s\n' '    print("  " + "-" * 50)' >> "$PYSCRIPT"
printf '%s\n' '    print("")' >> "$PYSCRIPT"
printf '%s\n' '    if buttons_detected >= 2:' >> "$PYSCRIPT"
printf '%s\n' '        ok("Controller test PASSED: " + str(buttons_detected) + "/4 buttons detected")' >> "$PYSCRIPT"
printf '%s\n' '        print("")' >> "$PYSCRIPT"
printf '%s\n' '        config_dir = "/usr/local/share/grub-snes-gamepad"' >> "$PYSCRIPT"
printf '%s\n' '        try:' >> "$PYSCRIPT"
printf '%s\n' '            os.makedirs(config_dir, exist_ok=True)' >> "$PYSCRIPT"
printf '%s\n' '            config_data = {' >> "$PYSCRIPT"
printf '%s\n' '                "vid": "0x" + format(dev.idVendor, "04x"),' >> "$PYSCRIPT"
printf '%s\n' '                "pid": "0x" + format(dev.idProduct, "04x"),' >> "$PYSCRIPT"
printf '%s\n' '                "name": name,' >> "$PYSCRIPT"
printf '%s\n' '                "baseline": baseline.hex(),' >> "$PYSCRIPT"
printf '%s\n' '                "mapping": {}' >> "$PYSCRIPT"
printf '%s\n' '            }' >> "$PYSCRIPT"
printf '%s\n' '            for k, v in mapping.items():' >> "$PYSCRIPT"
printf '%s\n' '                config_data["mapping"][k] = [[i, "0x" + format(a, "02x"), "0x" + format(b, "02x")] for i, a, b in v]' >> "$PYSCRIPT"
printf '%s\n' '            with open(config_dir + "/controller.json", "w") as f:' >> "$PYSCRIPT"
printf '%s\n' '                json.dump(config_data, f, indent=2)' >> "$PYSCRIPT"
printf '%s\n' '            ok("Config saved: " + config_dir + "/controller.json")' >> "$PYSCRIPT"
printf '%s\n' '        except Exception as e:' >> "$PYSCRIPT"
printf '%s\n' '            warn("Could not save config: " + str(e))' >> "$PYSCRIPT"
printf '%s\n' '        print("BUTTONS_DETECTED=" + str(buttons_detected))' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(0)' >> "$PYSCRIPT"
printf '%s\n' '    else:' >> "$PYSCRIPT"
printf '%s\n' '        err("Controller test FAILED: Only " + str(buttons_detected) + "/4 buttons detected")' >> "$PYSCRIPT"
printf '%s\n' '        err("You must successfully detect at least 2 buttons to continue.")' >> "$PYSCRIPT"
printf '%s\n' '        print("")' >> "$PYSCRIPT"
printf '%s\n' '        info("Troubleshooting:")' >> "$PYSCRIPT"
printf '%s\n' '        info("  1. Make sure you are pressing the buttons firmly")' >> "$PYSCRIPT"
printf '%s\n' '        info("  2. Try a different USB port")' >> "$PYSCRIPT"
printf '%s\n' '        info("  3. Try unplugging and replugging the controller")' >> "$PYSCRIPT"
printf '%s\n' '        info("  4. Some controllers may not be compatible")' >> "$PYSCRIPT"
printf '%s\n' '        print("")' >> "$PYSCRIPT"
printf '%s\n' '        print("BUTTONS_DETECTED=" + str(buttons_detected))' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(1)' >> "$PYSCRIPT"
printf '%s\n' '' >> "$PYSCRIPT"
printf '%s\n' 'if __name__ == "__main__":' >> "$PYSCRIPT"
printf '%s\n' '    try:' >> "$PYSCRIPT"
printf '%s\n' '        main()' >> "$PYSCRIPT"
printf '%s\n' '    except KeyboardInterrupt:' >> "$PYSCRIPT"
printf '%s\n' '        print("\\n\\nCancelled by user")' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(130)' >> "$PYSCRIPT"
printf '%s\n' '    except Exception as e:' >> "$PYSCRIPT"
printf '%s\n' '        print("  \\033[91m[ERROR]\\033[0m Unexpected error: " + str(e))' >> "$PYSCRIPT"
printf '%s\n' '        import traceback' >> "$PYSCRIPT"
printf '%s\n' '        traceback.print_exc()' >> "$PYSCRIPT"
printf '%s\n' '        sys.exit(1)' >> "$PYSCRIPT"

# Run the Python mapper and capture output
MAPPER_OUTPUT=$(python3 "$PYSCRIPT" 2>&1) || MAPPER_EXIT=$?
MAPPER_EXIT=${MAPPER_EXIT:-0}

# Display the output
echo "$MAPPER_OUTPUT"

# Extract buttons detected count
BUTTONS_DETECTED=$(echo "$MAPPER_OUTPUT" | grep "BUTTONS_DETECTED=" | cut -d= -f2 || echo "0")

# Cleanup
rm -f "$PYSCRIPT"

# Check if mapping was successful
if [ "$MAPPER_EXIT" -ne 0 ] || [ "${BUTTONS_DETECTED:-0}" -lt 2 ]; then
    echo ""
    err "Controller mapping failed or insufficient buttons detected."
    err "Cannot continue with GRUB build without a working controller."
    echo ""
    info "Please fix the controller issue and run install.sh again."
    exit 1
fi

ok "Controller verified and ready!"

#######################################
# STEP 4: Install build dependencies
#######################################
print_step 4 6 "Installing build dependencies"

echo -e "  ${YELLOW}${BOLD}Your controller is working!${NC}"
echo ""
info "Now installing packages needed to compile GRUB..."
echo ""

# Timeout for apt commands (5 minutes max per command)
APT_TIMEOUT=300

install_deps_debian() {
    start_spinner "Updating package lists..."
    if ! timeout "$APT_TIMEOUT" apt-get update -qq 2>/dev/null; then
        stop_spinner
        warn "Package list update timed out or failed, continuing anyway..."
    else
        stop_spinner
        ok "Package lists updated"
    fi

    # Full list of packages required for GRUB compilation from git source
    local GRUB_BUILD_DEPS="git build-essential autoconf automake autopoint autogen gettext bison flex"
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS python-is-python3"
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS libusb-1.0-0-dev pkg-config fonts-unifont libfreetype-dev"
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS help2man texinfo liblzma-dev xorriso"
    # Optional but helpful
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS libopts25 libopts25-dev libdevmapper-dev libfuse-dev"

    start_spinner "Installing build tools (this takes ~2 min)..."
    # shellcheck disable=SC2086
    if ! timeout "$APT_TIMEOUT" apt-get install -y -qq $GRUB_BUILD_DEPS 2>/dev/null; then
        stop_spinner
        warn "Some optional packages failed, trying essential packages only..."
        start_spinner "Installing essential packages..."
        timeout "$APT_TIMEOUT" apt-get install -y -qq git build-essential autoconf automake autopoint \
            gettext bison flex libusb-1.0-0-dev pkg-config \
            fonts-unifont help2man texinfo 2>/dev/null || true
        stop_spinner
    else
        stop_spinner
    fi
    ok "APT packages installed"
}

install_deps_fedora() {
    start_spinner "Installing packages with dnf..."
    timeout "$APT_TIMEOUT" dnf install -y -q git gcc make autoconf automake autogen gettext bison flex \
        python3 libusb1-devel texinfo help2man xz-devel \
        device-mapper-devel 2>/dev/null || true
    stop_spinner
    ok "DNF packages installed"
}

install_deps_arch() {
    start_spinner "Installing packages with pacman..."
    timeout "$APT_TIMEOUT" pacman -Sy --noconfirm git base-devel autoconf automake autogen gettext bison \
        flex python libusb texinfo help2man xz device-mapper 2>/dev/null || true
    stop_spinner
    ok "Pacman packages installed"
}

case "$DISTRO" in
    ubuntu|debian|linuxmint|pop)
        install_deps_debian
        ;;
    fedora)
        install_deps_fedora
        ;;
    arch|manjaro)
        install_deps_arch
        ;;
    *)
        warn "Unknown distro '$DISTRO', trying Debian-based install..."
        install_deps_debian
        ;;
esac

#######################################
# STEP 5: Build GRUB module
#######################################
print_step 5 6 "Building GRUB module"

warn "The next step compiles a custom GRUB module from source."
warn "This process takes 5-15 minutes and requires ~1GB of disk space."
echo ""
read -r -p "  Continue with GRUB build? [Y/n] " BUILD_CONFIRM
echo ""

if [ "$BUILD_CONFIRM" = "n" ] || [ "$BUILD_CONFIRM" = "N" ]; then
    info "Skipped build. Your controller config has been saved."
    info "Run install.sh again when you're ready to build."
    exit 0
fi

# Setup build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || { err "Cannot create build directory"; exit 1; }

# Clone GRUB with gamepad support
echo ""
info "Downloading GRUB source (this may take 1-2 minutes)..."
echo ""

# Use full clone because bootstrap checks git history
start_spinner "Cloning GRUB repository..."
if git clone --quiet -b grub-gamepad https://github.com/tsoding/grub.git grub > clone.log 2>&1; then
    stop_spinner
    ok "GRUB source downloaded"
else
    stop_spinner
    err "Failed to clone GRUB repository"
    echo ""
    echo "Clone log:"
    tail -20 clone.log 2>/dev/null || true
    echo ""
    info "Check your internet connection and try again"
    exit 1
fi

cd grub || { err "Cannot enter grub directory"; exit 1; }

# Set PYTHON env var to ensure python3 is used
export PYTHON=python3

#
# Bootstrap phase - this is where most failures occur
#
info "Running bootstrap (this is the longest step, 3-8 minutes)..."
info "Bootstrap downloads gnulib from git.savannah.gnu.org"
echo ""

# Progress indicator for bootstrap (ASCII spinner)
(
    count=0
    chars='|/-\'
    while true; do
        count=$((count + 1))
        char_idx=$((count % 4))
        printf "\r  [%s] Bootstrap in progress... (elapsed: %ds)" "${chars:$char_idx:1}" "$count"
        sleep 1
    done
) &
BOOTSTRAP_PROGRESS_PID=$!

# Try bootstrap - this can fail for various reasons
BOOTSTRAP_SUCCESS=0

if ./bootstrap > ../bootstrap.log 2>&1; then
    BOOTSTRAP_SUCCESS=1
else
    # Bootstrap failed - try recovery
    kill $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
    wait $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
    printf "\r                                                              \r"

    warn "Bootstrap failed, attempting recovery..."

    # Check if gnulib was the problem
    if grep -q "gnulib" ../bootstrap.log 2>/dev/null; then
        info "Gnulib download failed. Trying manual clone..."

        # Try cloning gnulib manually from multiple sources
        GNULIB_URLS=(
            "https://git.savannah.gnu.org/git/gnulib.git"
            "https://github.com/coreutils/gnulib.git"
        )

        for url in "${GNULIB_URLS[@]}"; do
            info "Trying: $url"
            if git clone --depth 1 "$url" gnulib > ../gnulib-clone.log 2>&1; then
                ok "Gnulib cloned from $url"

                # Retry bootstrap with local gnulib
                (
                    count=0
                    chars='|/-\'
                    while true; do
                        count=$((count + 1))
                        char_idx=$((count % 4))
                        printf "\r  [%s] Retrying bootstrap with local gnulib... (%ds)" "${chars:$char_idx:1}" "$count"
                        sleep 1
                    done
                ) &
                BOOTSTRAP_PROGRESS_PID=$!

                if ./bootstrap --gnulib-srcdir=gnulib > ../bootstrap2.log 2>&1; then
                    BOOTSTRAP_SUCCESS=1
                    break
                fi
                break
            fi
        done
    fi
fi

# Stop progress indicator
kill $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
wait $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
printf "\r                                                              \r"

if [ "$BOOTSTRAP_SUCCESS" -ne 1 ]; then
    err "Bootstrap failed after recovery attempts"
    echo ""
    echo "Last 30 lines of bootstrap log:"
    tail -30 ../bootstrap.log 2>/dev/null || tail -30 ../bootstrap2.log 2>/dev/null || true
    echo ""
    info "Common causes:"
    info "  - Network issues (gnulib server may be slow or down)"
    info "  - Missing build dependencies"
    info "  - Disk space issues"
    echo ""
    info "Build logs saved in: $BUILD_DIR"
    KEEP_BUILD=1
    exit 1
fi

ok "Bootstrap complete"

# Verify critical file was generated
if [ ! -f "Makefile.util.am" ]; then
    err "Makefile.util.am not generated - bootstrap incomplete"

    # Try running autogen.sh directly if gnulib exists
    if [ -d "grub-core/lib/gnulib" ]; then
        info "Attempting to run autogen.sh directly..."
        if FROM_BOOTSTRAP=1 ./autogen.sh > ../autogen.log 2>&1; then
            ok "autogen.sh succeeded"
        else
            err "autogen.sh also failed"
            tail -20 ../autogen.log
            exit 1
        fi
    else
        exit 1
    fi
fi

#
# Configure phase
#
info "Running configure (2-3 minutes)..."
echo ""

# Determine configure options based on platform
CONFIGURE_OPTS="--with-platform=${GRUB_PLATFORM##*-}"
if [ "$GRUB_PLATFORM" = "x86_64-efi" ]; then
    CONFIGURE_OPTS="$CONFIGURE_OPTS --target=x86_64"
elif [ "$GRUB_PLATFORM" = "i386-pc" ]; then
    CONFIGURE_OPTS="$CONFIGURE_OPTS --target=i386"
fi
CONFIGURE_OPTS="$CONFIGURE_OPTS --disable-werror"

start_spinner "Running configure..."
# shellcheck disable=SC2086
if ./configure $CONFIGURE_OPTS > ../configure.log 2>&1; then
    stop_spinner
    ok "Configure complete"
else
    stop_spinner
    err "Configure failed"
    echo ""
    echo "Last 30 lines of configure.log:"
    tail -30 ../configure.log
    echo ""

    # Check for common errors
    if grep -q "cannot run C compiled programs" ../configure.log 2>/dev/null; then
        info "This might be a cross-compilation issue"
    elif grep -q "C compiler cannot create executables" ../configure.log 2>/dev/null; then
        info "GCC/build-essential may not be properly installed"
    fi

    info "Build logs saved in: $BUILD_DIR"
    KEEP_BUILD=1
    exit 1
fi

#
# Compile phase
#
info "Compiling GRUB (3-5 minutes)..."
echo ""

CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

# Progress indicator for make (ASCII spinner)
(
    count=0
    chars='|/-\'
    while true; do
        count=$((count + 1))
        char_idx=$((count % 4))
        printf "\r  [%s] Compiling... (%d seconds)" "${chars:$char_idx:1}" "$count"
        sleep 1
    done
) &
MAKE_PROGRESS_PID=$!

if make -j"$CORES" > ../make.log 2>&1; then
    kill $MAKE_PROGRESS_PID 2>/dev/null || true
    wait $MAKE_PROGRESS_PID 2>/dev/null || true
    printf "\r                                                                    \r"
    ok "Compilation complete"
else
    kill $MAKE_PROGRESS_PID 2>/dev/null || true
    wait $MAKE_PROGRESS_PID 2>/dev/null || true
    printf "\r                                                                    \r"
    err "Compilation failed"
    echo ""
    echo "Last 30 lines of make.log:"
    tail -30 ../make.log
    echo ""
    info "Build logs saved in: $BUILD_DIR"
    KEEP_BUILD=1
    exit 1
fi

# Find the module
MODULE=$(find . -name "usb_gamepad.mod" 2>/dev/null | head -1)

if [ -z "$MODULE" ]; then
    err "Module usb_gamepad.mod not found after build!"
    echo ""
    info "Looking for any .mod files..."
    find . -name "*.mod" 2>/dev/null | head -10
    echo ""
    info "Build logs saved in: $BUILD_DIR"
    KEEP_BUILD=1
    exit 1
fi

# Copy module to GRUB directory
cp "$MODULE" "$GRUB_MOD_DIR/usb_gamepad.mod"
ok "Module installed: $GRUB_MOD_DIR/usb_gamepad.mod"

#######################################
# STEP 6: Configure GRUB
#######################################
print_step 6 6 "Configuring GRUB"

GRUB_CUSTOM="/etc/grub.d/40_custom"

# Backup original config
if [ ! -f "${GRUB_CUSTOM}.backup-snes" ]; then
    cp "$GRUB_CUSTOM" "${GRUB_CUSTOM}.backup-snes"
    ok "Backed up: ${GRUB_CUSTOM}.backup-snes"
fi

# Add gamepad config if not present
if ! grep -q "usb_gamepad" "$GRUB_CUSTOM" 2>/dev/null; then
    {
        echo ""
        echo "# SNES Gamepad Support - added by grub-snes-gamepad"
        echo "insmod usb_gamepad"
        echo "terminal_input --append usb_gamepad"
    } >> "$GRUB_CUSTOM"
    ok "Added gamepad to GRUB config"
else
    info "GRUB already configured for gamepad"
fi

# Update GRUB
start_spinner "Regenerating GRUB configuration..."
if command -v update-grub > /dev/null 2>&1; then
    update-grub > /dev/null 2>&1 || true
    stop_spinner
    ok "GRUB updated with update-grub"
elif command -v grub2-mkconfig > /dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg > /dev/null 2>&1 || true
    stop_spinner
    ok "GRUB updated with grub2-mkconfig"
elif command -v grub-mkconfig > /dev/null 2>&1; then
    grub-mkconfig -o "$GRUB_DIR/grub.cfg" > /dev/null 2>&1 || true
    stop_spinner
    ok "GRUB updated with grub-mkconfig"
else
    stop_spinner
    warn "Could not find grub update command"
    warn "Please run 'update-grub' or equivalent manually"
fi

# Cleanup build directory
cd /
rm -rf "$BUILD_DIR"
ok "Cleaned up build files"

# Create uninstaller script
mkdir -p /usr/local/share/grub-snes-gamepad

# Write uninstaller using printf to avoid heredoc
UNINSTALL_PATH="/usr/local/share/grub-snes-gamepad/uninstall.sh"
printf '%s\n' '#!/bin/bash' > "$UNINSTALL_PATH"
printf '%s\n' 'echo "Uninstalling GRUB SNES Gamepad..."' >> "$UNINSTALL_PATH"
printf '%s\n' '' >> "$UNINSTALL_PATH"
printf '%s\n' '# Remove modules' >> "$UNINSTALL_PATH"
printf '%s\n' 'rm -f /boot/grub/x86_64-efi/usb_gamepad.mod 2>/dev/null' >> "$UNINSTALL_PATH"
printf '%s\n' 'rm -f /boot/grub/i386-pc/usb_gamepad.mod 2>/dev/null' >> "$UNINSTALL_PATH"
printf '%s\n' 'rm -f /boot/grub2/x86_64-efi/usb_gamepad.mod 2>/dev/null' >> "$UNINSTALL_PATH"
printf '%s\n' 'rm -f /boot/grub2/i386-pc/usb_gamepad.mod 2>/dev/null' >> "$UNINSTALL_PATH"
printf '%s\n' '' >> "$UNINSTALL_PATH"
printf '%s\n' '# Restore GRUB config' >> "$UNINSTALL_PATH"
printf '%s\n' 'if [ -f /etc/grub.d/40_custom.backup-snes ]; then' >> "$UNINSTALL_PATH"
printf '%s\n' '    cp /etc/grub.d/40_custom.backup-snes /etc/grub.d/40_custom' >> "$UNINSTALL_PATH"
printf '%s\n' '    echo "Restored GRUB config from backup"' >> "$UNINSTALL_PATH"
printf '%s\n' 'fi' >> "$UNINSTALL_PATH"
printf '%s\n' '' >> "$UNINSTALL_PATH"
printf '%s\n' '# Update GRUB' >> "$UNINSTALL_PATH"
printf '%s\n' 'if command -v update-grub > /dev/null 2>&1; then' >> "$UNINSTALL_PATH"
printf '%s\n' '    update-grub 2>/dev/null' >> "$UNINSTALL_PATH"
printf '%s\n' 'elif command -v grub2-mkconfig > /dev/null 2>&1; then' >> "$UNINSTALL_PATH"
printf '%s\n' '    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null' >> "$UNINSTALL_PATH"
printf '%s\n' 'fi' >> "$UNINSTALL_PATH"
printf '%s\n' '' >> "$UNINSTALL_PATH"
printf '%s\n' '# Remove our files' >> "$UNINSTALL_PATH"
printf '%s\n' 'rm -rf /usr/local/share/grub-snes-gamepad' >> "$UNINSTALL_PATH"
printf '%s\n' '' >> "$UNINSTALL_PATH"
printf '%s\n' 'echo "Done! GRUB SNES Gamepad has been uninstalled."' >> "$UNINSTALL_PATH"

chmod +x "$UNINSTALL_PATH"

#######################################
# DONE!
#######################################
echo ""
echo -e "${GREEN}${BOLD}=======================================================${NC}"
echo -e "${GREEN}${BOLD}              Installation Complete!                    ${NC}"
echo -e "${GREEN}${BOLD}=======================================================${NC}"
echo ""
echo -e "  ${BOLD}Controller:${NC} VID=$CONTROLLER_VID PID=$CONTROLLER_PID"
echo -e "  ${BOLD}Buttons detected:${NC} $BUTTONS_DETECTED"
echo ""
echo -e "  ${BOLD}Button Mapping:${NC}"
echo "    D-pad Up/Down  ->  Navigate menu"
echo "    A or Start     ->  Select entry"
echo "    B              ->  Cancel/Back"
echo ""
echo -e "  ${BOLD}Next step:${NC}"
echo -e "    ${CYAN}Reboot your computer and test in GRUB menu!${NC}"
echo ""
echo -e "  ${DIM}To uninstall: sudo /usr/local/share/grub-snes-gamepad/uninstall.sh${NC}"
echo ""
