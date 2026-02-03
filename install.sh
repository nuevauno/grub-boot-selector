#!/bin/bash
#
# GRUB SNES Gamepad Installer v0.8
# https://github.com/nuevauno/grub-snes-gamepad
#
# Builds and installs a custom GRUB module for USB gamepad support
# Based on https://github.com/tsoding/grub (grub-gamepad branch)
#

VERSION="0.8"

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

# Spinner function - runs in background
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

#######################################
# STEP 2: Install ALL dependencies
#######################################
print_step 2 6 "Installing dependencies"

install_deps_debian() {
    start_spinner "Updating package lists..."
    apt-get update -qq 2>/dev/null || true
    stop_spinner
    ok "Package lists updated"

    # Full list of packages required for GRUB compilation from git source
    # See: https://www.gnu.org/software/grub/manual/grub/html_node/Obtaining-and-Building-GRUB.html
    local GRUB_BUILD_DEPS="git build-essential autoconf automake autopoint autogen gettext bison flex"
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS python3 python3-pip python-is-python3"
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS libusb-1.0-0-dev pkg-config fonts-unifont libfreetype-dev"
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS help2man texinfo liblzma-dev xorriso"
    # Optional but helpful
    GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS libopts25 libopts25-dev libdevmapper-dev libfuse-dev"

    start_spinner "Installing build tools (this takes ~2 min)..."
    # shellcheck disable=SC2086
    if ! apt-get install -y -qq $GRUB_BUILD_DEPS 2>/dev/null; then
        stop_spinner
        warn "Some optional packages failed, trying essential packages only..."
        start_spinner "Installing essential packages..."
        apt-get install -y -qq git build-essential autoconf automake autopoint \
            gettext bison flex python3 python3-pip libusb-1.0-0-dev pkg-config \
            fonts-unifont help2man texinfo 2>/dev/null || true
        stop_spinner
    fi
    ok "APT packages installed"
}

install_deps_fedora() {
    start_spinner "Installing packages with dnf..."
    dnf install -y -q git gcc make autoconf automake autogen gettext bison flex \
        python3 python3-pip libusb1-devel texinfo help2man xz-devel \
        device-mapper-devel 2>/dev/null || true
    stop_spinner
    ok "DNF packages installed"
}

install_deps_arch() {
    start_spinner "Installing packages with pacman..."
    pacman -Sy --noconfirm git base-devel autoconf automake autogen gettext bison \
        flex python python-pip libusb texinfo help2man xz device-mapper 2>/dev/null || true
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

# Install pyusb - CRITICAL for controller detection
info "Installing Python USB library..."
if pip3 install --quiet pyusb 2>/dev/null; then
    ok "pyusb installed via pip3"
elif pip install --quiet pyusb 2>/dev/null; then
    ok "pyusb installed via pip"
else
    # Try with --break-system-packages for newer Debian/Ubuntu
    if pip3 install --quiet --break-system-packages pyusb 2>/dev/null; then
        ok "pyusb installed (break-system-packages)"
    else
        err "Could not install pyusb"
        err "Try manually: pip3 install pyusb"
        exit 1
    fi
fi

# Verify pyusb is actually importable
if ! python3 -c "import usb.core" 2>/dev/null; then
    err "pyusb installed but cannot be imported"
    err "This usually means a missing dependency (libusb)"
    exit 1
fi
ok "Python USB library verified"

#######################################
# STEP 3: Detect controller
#######################################
print_step 3 6 "Detecting USB controller"

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
# STEP 4: Map controller buttons (MANDATORY)
#######################################
print_step 4 6 "Mapping controller buttons (MANDATORY)"

echo -e "  ${RED}${BOLD}*********************************************${NC}"
echo -e "  ${RED}${BOLD}*  BUTTON MAPPING - MUST COMPLETE TO CONTINUE  *${NC}"
echo -e "  ${RED}${BOLD}*********************************************${NC}"
echo ""
echo -e "  ${YELLOW}You will be asked to press 4 buttons.${NC}"
echo -e "  ${YELLOW}At least 2 must be detected to continue.${NC}"
echo ""
echo -e "  ${CYAN}Get ready to press buttons on your controller!${NC}"
echo ""
sleep 2

# Create Python script for button mapping
PYSCRIPT=$(mktemp /tmp/mapper_XXXXXX.py)

cat > "$PYSCRIPT" << 'ENDPYTHON'
#!/usr/bin/env python3
"""
Controller Button Mapper - Embedded in install.sh
Tests that the controller works and maps buttons interactively.
"""

import os
import sys
import time
import json

# pyusb should already be installed by the shell script
import usb.core
import usb.util

# ANSI colors
GREEN = '\033[92m'
YELLOW = '\033[93m'
RED = '\033[91m'
CYAN = '\033[96m'
BOLD = '\033[1m'
DIM = '\033[2m'
NC = '\033[0m'

def ok(t):
    print("  " + GREEN + "[OK]" + NC + " " + t)

def err(t):
    print("  " + RED + "[ERROR]" + NC + " " + t)

def warn(t):
    print("  " + YELLOW + "[WARN]" + NC + " " + t)

def info(t):
    print("  " + CYAN + "[INFO]" + NC + " " + t)

KNOWN_CONTROLLERS = {
    (0x0810, 0xe501): "Generic SNES",
    (0x0079, 0x0011): "DragonRise",
    (0x0583, 0x2060): "iBuffalo",
    (0x2dc8, 0x9018): "8BitDo",
    (0x12bd, 0xd015): "Generic 2-pack",
    (0x1a34, 0x0802): "USB Gamepad",
    (0x0810, 0x0001): "Generic USB Gamepad",
    (0x0079, 0x0006): "DragonRise Gamepad",
}

def find_controller():
    """Find the first game controller"""
    for dev in usb.core.find(find_all=True):
        key = (dev.idVendor, dev.idProduct)
        if key in KNOWN_CONTROLLERS:
            return dev, KNOWN_CONTROLLERS[key]

        # Check if it's HID class
        try:
            for cfg in dev:
                for intf in cfg:
                    if intf.bInterfaceClass == 3:  # HID
                        # Skip keyboards and mice
                        if intf.bInterfaceSubClass == 1 and intf.bInterfaceProtocol in [1, 2]:
                            continue
                        return dev, "USB Controller"
        except Exception:
            pass

    return None, None

def setup_device(dev):
    """Setup USB device for reading"""
    # Detach kernel driver if active
    try:
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
    except Exception:
        pass

    # Set configuration
    try:
        dev.set_configuration()
    except Exception:
        pass

    # Find interrupt IN endpoint
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]

    ep = None
    for endpoint in intf:
        if usb.util.endpoint_direction(endpoint.bEndpointAddress) == usb.util.ENDPOINT_IN:
            ep = endpoint
            break

    return ep

def get_baseline(dev, ep):
    """Get baseline report (no buttons pressed)"""
    print("")
    info("Reading baseline (do NOT press any buttons)...")
    time.sleep(0.5)

    reports = []
    for _ in range(15):
        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
            reports.append(r)
        except Exception:
            pass
        time.sleep(0.05)

    if not reports:
        return None

    # Use the most common report as baseline
    baseline = max(set(reports), key=reports.count)
    return baseline

def wait_for_button(dev, ep, baseline, button_name, timeout=15):
    """Wait for a button press and detect the change"""
    sys.stdout.write("  " + YELLOW + ">>> Press " + BOLD + button_name + NC + YELLOW + " <<<" + NC)
    sys.stdout.flush()

    start = time.time()

    while time.time() - start < timeout:
        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
            if r != baseline:
                # Found a change - button pressed
                changes = []
                for i in range(min(len(baseline), len(r))):
                    if baseline[i] != r[i]:
                        changes.append((i, baseline[i], r[i]))

                if changes:
                    i, a, b = changes[0]
                    result = "  " + GREEN + "[OK]" + NC + " " + button_name + ": Byte " + str(i) + " = 0x" + format(a, '02x') + " -> 0x" + format(b, '02x')
                    print("\r" + result + "                    ")

                    # Wait for button release
                    release_start = time.time()
                    while time.time() - release_start < 2:
                        try:
                            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
                            if r == baseline:
                                break
                        except Exception:
                            break
                        time.sleep(0.01)

                    return changes
        except usb.core.USBTimeoutError:
            pass
        except Exception:
            pass
        time.sleep(0.01)

    print("\r  " + YELLOW + "[TIMEOUT]" + NC + " " + button_name + ": No press detected                    ")
    return None

def main():
    # Find controller
    dev, name = find_controller()

    if not dev:
        err("No controller found!")
        sys.exit(1)

    ok("Controller: " + name + " (VID: 0x" + format(dev.idVendor, '04x') + " PID: 0x" + format(dev.idProduct, '04x') + ")")

    # Setup device
    ep = setup_device(dev)
    if not ep:
        err("Could not find USB endpoint!")
        sys.exit(1)

    ok("USB endpoint ready: 0x" + format(ep.bEndpointAddress, '02x'))

    # Get baseline
    baseline = get_baseline(dev, ep)
    if not baseline:
        err("Cannot read from controller!")
        err("This may be a permissions issue or the controller is not responding.")
        sys.exit(1)

    ok("Baseline: " + baseline.hex())

    # Map required buttons
    print("")
    print("  " + BOLD + "Press each button when prompted (15 sec timeout each):" + NC)
    print("")

    buttons_to_test = [
        ("D-PAD UP", "up"),
        ("D-PAD DOWN", "down"),
        ("A BUTTON (or any face button)", "a"),
        ("START (or any other button)", "start"),
    ]

    mapping = {}
    buttons_detected = 0

    for display_name, key in buttons_to_test:
        result = wait_for_button(dev, ep, baseline, display_name)
        if result:
            mapping[key] = result
            buttons_detected += 1
        time.sleep(0.3)  # Brief pause between buttons

    print("")
    print("  " + "-" * 50)
    print("")

    # Report results
    if buttons_detected >= 2:
        ok("Controller test PASSED: " + str(buttons_detected) + "/4 buttons detected")
        print("")

        # Save config
        config_dir = "/usr/local/share/grub-snes-gamepad"
        try:
            os.makedirs(config_dir, exist_ok=True)
            config_data = {
                'vid': "0x" + format(dev.idVendor, '04x'),
                'pid': "0x" + format(dev.idProduct, '04x'),
                'name': name,
                'baseline': baseline.hex(),
                'mapping': {}
            }
            for k, v in mapping.items():
                config_data['mapping'][k] = [[i, "0x" + format(a, '02x'), "0x" + format(b, '02x')] for i, a, b in v]

            with open(config_dir + "/controller.json", 'w') as f:
                json.dump(config_data, f, indent=2)
            ok("Config saved: " + config_dir + "/controller.json")
        except Exception as e:
            warn("Could not save config: " + str(e))

        # Print exit code for bash to read
        print("BUTTONS_DETECTED=" + str(buttons_detected))
        sys.exit(0)
    else:
        err("Controller test FAILED: Only " + str(buttons_detected) + "/4 buttons detected")
        err("You must successfully detect at least 2 buttons to continue.")
        print("")
        info("Troubleshooting:")
        info("  1. Make sure you're pressing the buttons firmly")
        info("  2. Try a different USB port")
        info("  3. Try unplugging and replugging the controller")
        info("  4. Some controllers may not be compatible")
        print("")
        print("BUTTONS_DETECTED=" + str(buttons_detected))
        sys.exit(1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nCancelled by user")
        sys.exit(130)
    except Exception as e:
        err("Unexpected error: " + str(e))
        import traceback
        traceback.print_exc()
        sys.exit(1)
ENDPYTHON

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
# STEP 5: Build GRUB module
#######################################
print_step 5 6 "Building GRUB module"

echo -e "  ${YELLOW}${BOLD}Your controller is working!${NC}"
echo ""
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

# Progress indicator for bootstrap
(
    count=0
    while true; do
        count=$((count + 1))
        dots=$(printf '%*s' $((count % 4)) '' | tr ' ' '.')
        printf "\r  [*] Bootstrap in progress%-4s (elapsed: %ds)" "$dots" "$count"
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
                    while true; do
                        count=$((count + 1))
                        printf "\r  [*] Retrying bootstrap with local gnulib... (%ds)" "$count"
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

# Progress indicator for make
(
    count=0
    while true; do
        count=$((count + 1))
        bar=""
        pct=$((count % 100))
        filled=$((pct / 5))
        for i in $(seq 1 20); do
            if [ "$i" -le "$filled" ]; then
                bar="${bar}#"
            else
                bar="${bar}-"
            fi
        done
        printf "\r  [%s] Compiling... (%d files processed)" "$bar" "$count"
        sleep 0.5
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

cat > /usr/local/share/grub-snes-gamepad/uninstall.sh << 'ENDUNINSTALL'
#!/bin/bash
echo "Uninstalling GRUB SNES Gamepad..."

# Remove modules
rm -f /boot/grub/x86_64-efi/usb_gamepad.mod 2>/dev/null
rm -f /boot/grub/i386-pc/usb_gamepad.mod 2>/dev/null
rm -f /boot/grub2/x86_64-efi/usb_gamepad.mod 2>/dev/null
rm -f /boot/grub2/i386-pc/usb_gamepad.mod 2>/dev/null

# Restore GRUB config
if [ -f /etc/grub.d/40_custom.backup-snes ]; then
    cp /etc/grub.d/40_custom.backup-snes /etc/grub.d/40_custom
    echo "Restored GRUB config from backup"
fi

# Update GRUB
if command -v update-grub > /dev/null 2>&1; then
    update-grub 2>/dev/null
elif command -v grub2-mkconfig > /dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
fi

# Remove our files
rm -rf /usr/local/share/grub-snes-gamepad

echo "Done! GRUB SNES Gamepad has been uninstalled."
ENDUNINSTALL

chmod +x /usr/local/share/grub-snes-gamepad/uninstall.sh

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
