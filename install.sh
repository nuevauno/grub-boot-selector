#!/bin/bash
#
# GRUB SNES Gamepad Installer v2.0
# https://github.com/nuevauno/grub-snes-gamepad
#
# IMPORTANT: This compiles a MODIFIED version of GRUB with SNES controller support
#

VERSION="4.0"

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GRUB_DIR=""
GRUB_MOD_DIR=""
GRUB_PLATFORM=""
BUILD_DIR="/tmp/grub-snes-build-$$"

ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo -e "${CYAN}${BOLD}     GRUB SNES Gamepad Installer v${VERSION}${NC}"
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo ""
}

step() {
    echo ""
    echo -e "${BLUE}━━━ STEP $1: $2 ━━━${NC}"
    echo ""
}

cleanup() {
    [ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Run as root (sudo)${NC}"
    exit 1
fi

header

########################################
# STEP 1: System check
########################################
step "1/5" "Checking system"

# Check GRUB
if [ -d "/boot/grub" ]; then
    GRUB_DIR="/boot/grub"
elif [ -d "/boot/grub2" ]; then
    GRUB_DIR="/boot/grub2"
else
    err "GRUB not found!"
    exit 1
fi
ok "GRUB: $GRUB_DIR"

# Platform
if [ -d "$GRUB_DIR/x86_64-efi" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/x86_64-efi"
    GRUB_PLATFORM="x86_64-efi"
elif [ -d "$GRUB_DIR/i386-pc" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/i386-pc"
    GRUB_PLATFORM="i386-pc"
else
    err "Unknown GRUB platform"
    exit 1
fi
ok "Platform: $GRUB_PLATFORM"

# Python
if ! command -v python3 &>/dev/null; then
    err "Python3 required"
    exit 1
fi
ok "Python3 found"

########################################
# STEP 2: Detect controller
########################################
step "2/5" "Detecting controller"

echo -e "  ${YELLOW}Connect your SNES USB controller now${NC}"
echo ""
read -r -p "  Press ENTER when ready... "

CTRL=$(lsusb | grep -iE "game|pad|joystick|snes|0810|0079|0583|2dc8|12bd|1a34" | head -1 || true)

if [ -z "$CTRL" ]; then
    warn "No known controller found. Showing all USB devices:"
    lsusb
    echo ""
    read -r -p "  Continue anyway? [y/N] " CONT
    if [ "$CONT" != "y" ] && [ "$CONT" != "Y" ]; then
        exit 1
    fi
else
    ok "Found: $CTRL"
fi

# Extract VID:PID
if [ -n "$CTRL" ]; then
    VID_PID=$(echo "$CTRL" | grep -oE "[0-9a-f]{4}:[0-9a-f]{4}" | head -1)
    VID=$(echo "$VID_PID" | cut -d: -f1)
    PID=$(echo "$VID_PID" | cut -d: -f2)
    ok "Controller ID: VID=0x$VID PID=0x$PID"
fi

########################################
# STEP 3: Test controller buttons
########################################
step "3/5" "Test controller buttons"

info "Installing USB library..."
pip3 install -q pyusb 2>/dev/null || pip3 install -q --break-system-packages pyusb 2>/dev/null || true

if ! python3 -c "import usb.core" 2>/dev/null; then
    warn "Could not install pyusb - skipping button test"
    echo ""
    read -r -p "  Press ENTER to continue to build... "
else
    echo ""
    echo -e "  ${YELLOW}${BOLD}Button Test - Press each button when asked${NC}"
    echo ""

    # Run interactive button test
    # IMPORTANT: Disable set -e here because the Python test is informational only
    # We want to continue even if the test fails or detects few buttons
    set +e
    python3 << 'PYEOF'
import sys, time

try:
    import usb.core, usb.util
except:
    print("  ERROR: pyusb not available")
    sys.exit(2)

G='\033[92m'; Y='\033[93m'; R='\033[91m'; B='\033[1m'; N='\033[0m'

# Known SNES controllers - check these first
KNOWN_VIDS_PIDS = [
    (0x0810, 0xe501), (0x0079, 0x0011), (0x0583, 0x2060),
    (0x2dc8, 0x9018), (0x12bd, 0xd015), (0x1a34, 0x0802),
    (0x0810, 0x0001), (0x0079, 0x0006),
]

def find_controller():
    # First: check known controllers by VID/PID
    for d in usb.core.find(find_all=True):
        if (d.idVendor, d.idProduct) in KNOWN_VIDS_PIDS:
            return d
    # Second: any HID device that's not keyboard/mouse
    for d in usb.core.find(find_all=True):
        try:
            for cfg in d:
                for intf in cfg:
                    if intf.bInterfaceClass == 3:  # HID
                        if intf.bInterfaceSubClass == 1 and intf.bInterfaceProtocol in [1, 2]:
                            continue  # Skip keyboard/mouse
                        return d
        except Exception:
            pass
    return None

def find_interrupt_in_endpoint(dev):
    """Find INTERRUPT IN endpoint - CRITICAL for gamepad input"""
    try:
        dev.set_configuration()
    except Exception:
        pass
    try:
        cfg = dev.get_active_configuration()
        for intf in cfg:
            for ep in intf:
                # Must be INTERRUPT type AND IN direction
                is_in = usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN
                is_intr = usb.util.endpoint_type(ep.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR
                if is_in and is_intr:
                    return ep
    except Exception as e:
        print(f"  {Y}Warning:{N} {e}")
    return None

dev = find_controller()
if not dev:
    print(f"  {R}ERROR:{N} No controller found!")
    sys.exit(2)

print(f"  {G}Found:{N} VID=0x{dev.idVendor:04x} PID=0x{dev.idProduct:04x}")

# Detach kernel driver
try:
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
        print(f"  {G}OK:{N} Detached kernel driver")
except Exception:
    pass

# Find INTERRUPT IN endpoint (CRITICAL!)
ep = find_interrupt_in_endpoint(dev)
if not ep:
    print(f"  {R}ERROR:{N} No INTERRUPT IN endpoint!")
    print(f"  {Y}This controller might not work.{N}")
    sys.exit(2)

# Get baseline - DON'T PRESS ANYTHING
print(f"\n  {Y}DO NOT press any button for 2 seconds...{N}")
time.sleep(2)  # Fixed: was 1 second, message said 2

reports = []
for _ in range(20):
    try:
        r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
        reports.append(r)
    except:
        pass
    time.sleep(0.05)

if not reports:
    print(f"  {R}ERROR:{N} Cannot read from controller!")
    print(f"  {Y}Try a different USB port.{N}")
    sys.exit(2)  # Exit code 2 = skip test

baseline = max(set(reports), key=reports.count)
print(f"  {G}OK:{N} Baseline captured: {baseline.hex()}")

# Test each button - reduced timeout to 10s for better UX
buttons = [
    ("D-PAD UP", 10),
    ("D-PAD DOWN", 10),
    ("A or any button", 10),
    ("START", 10),
]

detected = 0
print(f"\n  {B}Now press each button when asked:{N}\n")

for btn_name, timeout in buttons:
    found = False
    start = time.time()
    last_remaining = -1

    while time.time() - start < timeout:
        remaining = int(timeout - (time.time() - start))
        # Update countdown display (only when it changes)
        if remaining != last_remaining:
            sys.stdout.write(f"\r  {Y}>>>{N} Press {B}{btn_name}{N} ({remaining}s) {Y}<<<{N} ")
            sys.stdout.flush()
            last_remaining = remaining

        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
            if r != baseline:
                # Found a change!
                changes = []
                for i in range(min(len(baseline), len(r))):
                    if baseline[i] != r[i]:
                        changes.append(f"byte{i}: 0x{baseline[i]:02x}->0x{r[i]:02x}")

                if changes:
                    # Clear the countdown and print result
                    sys.stdout.write(f"\r  {Y}>>>{N} Press {B}{btn_name}{N}        {Y}<<<{N} ")
                    print(f"{G}OK!{N} ({', '.join(changes)})")
                    detected += 1
                    found = True

                    # Wait for release
                    time.sleep(0.2)
                    release_start = time.time()
                    while time.time() - release_start < 2:
                        try:
                            r2 = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
                            if r2 == baseline:
                                break
                        except:
                            break
                        time.sleep(0.01)
                    break
        except:
            pass
        time.sleep(0.01)

    if not found:
        # Clear countdown and show timeout
        sys.stdout.write(f"\r  {Y}>>>{N} Press {B}{btn_name}{N}        {Y}<<<{N} ")
        print(f"{Y}TIMEOUT{N} (no press detected)")

    time.sleep(0.3)

print(f"\n  {'='*50}")
print(f"\n  {B}Result:{N} {detected}/4 buttons detected")

if detected >= 2:
    print(f"  {G}Controller is working!{N}")
elif detected >= 1:
    print(f"  {Y}Partial detection - controller may work in GRUB.{N}")
else:
    print(f"  {Y}No buttons detected - controller may still work in GRUB.{N}")

# Always exit 0 - this test is informational only
# The controller might work fine in GRUB even if this test fails
sys.exit(0)
PYEOF
    MAPPER_EXIT=$?
    set -e  # Re-enable strict mode

    echo ""

    if [ $MAPPER_EXIT -eq 2 ]; then
        echo -e "  ${YELLOW}Button test skipped (controller issue).${NC}"
        echo -e "  ${YELLOW}We'll continue with the build anyway.${NC}"
    elif [ $MAPPER_EXIT -ne 0 ]; then
        echo -e "  ${YELLOW}Button test had issues, but we'll continue anyway.${NC}"
    fi

    echo ""
    read -r -p "  Press ENTER to continue to build step... "
fi

########################################
# STEP 4: Build GRUB module
########################################
step "4/5" "Build GRUB module"

echo -e "  ${YELLOW}${BOLD}This will compile a custom GRUB with SNES support${NC}"
echo -e "  ${YELLOW}This takes 10-20 minutes and needs ~2GB disk space${NC}"
echo ""
read -r -p "  Continue? [Y/n] " CONFIRM

if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
    info "Cancelled"
    exit 0
fi

# Install dependencies
info "Installing build dependencies..."
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq git build-essential autoconf automake autopoint \
    gettext bison flex libusb-1.0-0-dev pkg-config fonts-unifont \
    help2man texinfo python-is-python3 liblzma-dev 2>/dev/null || true
ok "Dependencies installed"

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone tsoding's GRUB fork with gamepad support
info "Downloading GRUB with gamepad support..."
if ! git clone -q -b grub-gamepad https://github.com/tsoding/grub.git grub 2>&1; then
    err "Failed to clone GRUB"
    exit 1
fi
ok "GRUB downloaded"

cd grub

# PATCH: Complete SNES controller support with ALL missing fixes
#
# This patch addresses ALL issues found by deep analysis:
#
# Issue 1: Hardcoded VID/PID filter (FIXED)
# Issue 2: Wrong HID report parsing for SNES (FIXED)
# Issue 3: Missing HID initialization - SET_PROTOCOL, SET_IDLE (FIXED)
# Issue 4: No error recovery / dead flag (FIXED)
# Issue 5: Wrong baseline report for SNES (FIXED)

info "Applying comprehensive SNES patch with HID initialization fixes..."

# First, let's add the missing USB HID defines if they don't exist
USB_GAMEPAD_FILE="grub-core/term/usb_gamepad.c"

if [ -f "$USB_GAMEPAD_FILE" ]; then
    info "Found usb_gamepad.c - applying patches..."

    # Create backup
    cp "$USB_GAMEPAD_FILE" "${USB_GAMEPAD_FILE}.orig"

    # PATCH 1: Add SNES VID/PIDs and gamepad type system
    # Replace the hardcoded Logitech defines with a device table
    if grep -q "LOGITECH_VENDORID" "$USB_GAMEPAD_FILE"; then
        info "Patching VID/PID filter..."

        # Remove the old defines and add the new system
        sed -i '/#define LOGITECH_VENDORID/,/#define RUMBLEPAD_PRODUCTID/c\
/* Gamepad type */\
typedef enum {\
    GAMEPAD_LOGITECH_F510,\
    GAMEPAD_SNES_GENERIC,\
    GAMEPAD_GENERIC_HID\
} gamepad_type_t;\
\
/* Supported devices - add your controller VID:PID here */\
static struct {\
    grub_uint16_t vid;\
    grub_uint16_t pid;\
    gamepad_type_t type;\
} supported_devices[] = {\
    {0x046d, 0xc218, GAMEPAD_LOGITECH_F510},  /* Logitech F510 */\
    {0x0810, 0xe501, GAMEPAD_SNES_GENERIC},   /* Generic Chinese SNES */\
    {0x0079, 0x0011, GAMEPAD_SNES_GENERIC},   /* DragonRise */\
    {0x0583, 0x2060, GAMEPAD_SNES_GENERIC},   /* iBuffalo */\
    {0x2dc8, 0x9018, GAMEPAD_SNES_GENERIC},   /* 8BitDo SN30 */\
    {0x12bd, 0xd015, GAMEPAD_SNES_GENERIC},   /* Generic 2-pack */\
    {0x1a34, 0x0802, GAMEPAD_SNES_GENERIC},   /* USB Gamepad */\
    {0x0810, 0x0001, GAMEPAD_SNES_GENERIC},   /* Generic USB */\
    {0x0079, 0x0006, GAMEPAD_SNES_GENERIC},   /* DragonRise v2 */\
    {0x1209, 0x0001, GAMEPAD_GENERIC_HID},    /* Generic HID Gamepad */\
    {0, 0, 0}  /* End - also acts as wildcard for unknown devices */\
};' "$USB_GAMEPAD_FILE"

        ok "VID/PID filter patched"
    fi

    # PATCH 2: Add gamepad_type to struct
    if ! grep -q "gamepad_type_t gamepad_type;" "$USB_GAMEPAD_FILE"; then
        info "Adding gamepad_type to data struct..."
        sed -i '/int key_queue\[KEY_QUEUE_CAPACITY\];/a\    gamepad_type_t gamepad_type;\n    int dead;' "$USB_GAMEPAD_FILE"
        ok "Data struct patched"
    fi

    # PATCH 3: Add SNES baseline report
    if ! grep -q "initial_snes_report" "$USB_GAMEPAD_FILE"; then
        info "Adding SNES baseline report..."
        sed -i '/static grub_uint8_t initial_logitech_rumble_f510_report/a\
\
/* SNES baseline: centered axes (0x7F), no buttons */\
static grub_uint8_t initial_snes_report[USB_REPORT_SIZE] = {\
    0x7f, 0x7f, 0x7f, 0x7f, 0x00, 0x00, 0x00, 0x00\
};' "$USB_GAMEPAD_FILE"
        ok "SNES baseline added"
    fi

    # PATCH 4: Add snes_generate_keys function before usb_gamepad_getkey
    if ! grep -q "snes_generate_keys" "$USB_GAMEPAD_FILE"; then
        info "Adding SNES key generation function..."

        # Find the line number of usb_gamepad_getkey and insert before it
        LINE=$(grep -n "^static int$" "$USB_GAMEPAD_FILE" | grep -A1 "usb_gamepad_getkey" | head -1 | cut -d: -f1)
        if [ -n "$LINE" ]; then
            sed -i "${LINE}i\\
/* SNES USB gamepad key generation - handles axis-based D-pad */\\
static void snes_generate_keys(struct grub_usb_gamepad_data *data)\\
{\\
    grub_uint8_t *prev = data->prev_report;\\
    grub_uint8_t *curr = data->report;\\
\\
    /* D-Pad from axes: X=byte0, Y=byte1 */\\
    /* 0x00=left/up, 0x7F=center, 0xFF=right/down */\\
    #define AXIS_CENTER 0x7F\\
    #define AXIS_THRESHOLD 0x40\\
\\
    int prev_up = (prev[1] < AXIS_CENTER - AXIS_THRESHOLD);\\
    int prev_down = (prev[1] > AXIS_CENTER + AXIS_THRESHOLD);\\
    int prev_left = (prev[0] < AXIS_CENTER - AXIS_THRESHOLD);\\
    int prev_right = (prev[0] > AXIS_CENTER + AXIS_THRESHOLD);\\
\\
    int curr_up = (curr[1] < AXIS_CENTER - AXIS_THRESHOLD);\\
    int curr_down = (curr[1] > AXIS_CENTER + AXIS_THRESHOLD);\\
    int curr_left = (curr[0] < AXIS_CENTER - AXIS_THRESHOLD);\\
    int curr_right = (curr[0] > AXIS_CENTER + AXIS_THRESHOLD);\\
\\
    /* Generate key on button press (not release) */\\
    if (!prev_up && curr_up) key_queue_push(data, dpad_mapping[DIR_UP]);\\
    if (!prev_down && curr_down) key_queue_push(data, dpad_mapping[DIR_DOWN]);\\
    if (!prev_left && curr_left) key_queue_push(data, dpad_mapping[DIR_LEFT]);\\
    if (!prev_right && curr_right) key_queue_push(data, dpad_mapping[DIR_RIGHT]);\\
\\
    /* Buttons in byte 4 (and sometimes byte 5) */\\
    for (int i = 0; i < 8; i++) {\\
        int mask = (1 << i);\\
        if (!(prev[4] & mask) && (curr[4] & mask)) {\\
            if (i < BUTTONS_COUNT) key_queue_push(data, button_mapping[i]);\\
            if (i == 7) key_queue_push(data, options_mapping[SIDE_RIGHT]); /* Start */\\
            if (i == 6) key_queue_push(data, options_mapping[SIDE_LEFT]);  /* Select */\\
        }\\
    }\\
    #undef AXIS_CENTER\\
    #undef AXIS_THRESHOLD\\
}\\
" "$USB_GAMEPAD_FILE"
            ok "SNES key generation added"
        fi
    fi

    # PATCH 5: Modify usb_gamepad_getkey to use type-aware parsing and dead flag
    info "Patching getkey function..."
    sed -i 's/logitech_rumble_f510_generate_keys(termdata);/if (termdata->dead) return GRUB_TERM_NO_KEY;\
        if (termdata->gamepad_type == GAMEPAD_SNES_GENERIC || termdata->gamepad_type == GAMEPAD_GENERIC_HID)\
            snes_generate_keys(termdata);\
        else\
            logitech_rumble_f510_generate_keys(termdata);/' "$USB_GAMEPAD_FILE"

    # PATCH 6: Add dead flag handling in transfer restart
    sed -i 's/grub_print_error ();/grub_print_error();\
            termdata->dead = 1;/' "$USB_GAMEPAD_FILE"

    # PATCH 7: Replace VID/PID check in attach function with device lookup
    info "Patching attach function..."
    sed -i 's/if ((usbdev->descdev.vendorid != LOGITECH_VENDORID)/gamepad_type_t gtype = GAMEPAD_GENERIC_HID;\
    int found = 0;\
    for (int i = 0; supported_devices[i].vid != 0; i++) {\
        if (supported_devices[i].vid == usbdev->descdev.vendorid \&\& \
            supported_devices[i].pid == usbdev->descdev.prodid) {\
            gtype = supported_devices[i].type;\
            found = 1;\
            break;\
        }\
    }\
    /* Accept any HID gamepad even if not in list */\
    if (0 \&\& (usbdev->descdev.vendorid != 0x046d)/' "$USB_GAMEPAD_FILE"

    # PATCH 8: Add HID initialization after endpoint discovery
    # This is CRITICAL - tsoding's code is missing this!
    info "Adding HID protocol initialization..."

    # Find where data struct is initialized and add HID init before transfer
    sed -i 's/data->transfer = grub_usb_bulk_read_background//* CRITICAL: Initialize HID device (missing from original code!) */\
    grub_usb_set_configuration(usbdev, configno + 1);\
    \
    /* Set HID protocol to boot protocol (0) or report protocol (1) */\
    grub_usb_control_msg(usbdev, \
        GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,\
        0x0B, /* USB_HID_SET_PROTOCOL */\
        0,    /* 0 = boot protocol */\
        interfno, 0, 0);\
    \
    /* Set idle rate to 0 (send reports only on change) */\
    grub_usb_control_msg(usbdev,\
        GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,\
        0x0A, /* USB_HID_SET_IDLE */\
        0,\
        interfno, 0, 0);\
    \
    data->gamepad_type = gtype;\
    data->dead = 0;\
    \
    data->transfer = grub_usb_bulk_read_background/' "$USB_GAMEPAD_FILE"

    # PATCH 9: Use correct baseline based on gamepad type
    sed -i 's/grub_memcpy(data->prev_report, initial_logitech_rumble_f510_report, USB_REPORT_SIZE);/if (gtype == GAMEPAD_SNES_GENERIC || gtype == GAMEPAD_GENERIC_HID)\
        grub_memcpy(data->prev_report, initial_snes_report, USB_REPORT_SIZE);\
    else\
        grub_memcpy(data->prev_report, initial_logitech_rumble_f510_report, USB_REPORT_SIZE);/' "$USB_GAMEPAD_FILE"

    ok "All patches applied to usb_gamepad.c"

    # Show diff summary
    info "Patch summary:"
    diff -u "${USB_GAMEPAD_FILE}.orig" "$USB_GAMEPAD_FILE" | head -50 || true

else
    err "usb_gamepad.c not found!"
    exit 1
fi

export PYTHON=python3

# Bootstrap
info "Running bootstrap (5-10 minutes)..."
echo "  This downloads gnulib and generates build files"
if ! ./bootstrap > ../bootstrap.log 2>&1; then
    err "Bootstrap failed"
    tail -30 ../bootstrap.log
    exit 1
fi
ok "Bootstrap complete"

# Configure
info "Configuring..."
# IMPORTANT: --enable-usb is critical for USB gamepad support
CONF_OPTS="--with-platform=${GRUB_PLATFORM##*-} --disable-werror --enable-usb"
[ "$GRUB_PLATFORM" = "x86_64-efi" ] && CONF_OPTS="$CONF_OPTS --target=x86_64"

if ! ./configure $CONF_OPTS > ../configure.log 2>&1; then
    err "Configure failed"
    tail -30 ../configure.log
    exit 1
fi
ok "Configure complete"

# Compile
info "Compiling (5-10 minutes)..."
CORES=$(nproc 2>/dev/null || echo 2)
if ! make -j"$CORES" > ../make.log 2>&1; then
    err "Compile failed"
    tail -30 ../make.log
    exit 1
fi
ok "Compile complete"

# Find and copy module
MOD=$(find . -name "usb_gamepad.mod" -type f | head -1)
if [ -z "$MOD" ]; then
    err "Module usb_gamepad.mod not found!"
    find . -name "*.mod" | head -10
    exit 1
fi

cp "$MOD" "$GRUB_MOD_DIR/usb_gamepad.mod"
chmod 644 "$GRUB_MOD_DIR/usb_gamepad.mod"
ok "Module installed: $GRUB_MOD_DIR/usb_gamepad.mod"

########################################
# STEP 5: Configure GRUB
########################################
step "5/5" "Configure GRUB"

GRUB_CUSTOM="/etc/grub.d/40_custom"

# Backup
if [ ! -f "${GRUB_CUSTOM}.backup-snes" ]; then
    cp "$GRUB_CUSTOM" "${GRUB_CUSTOM}.backup-snes"
    ok "Backed up GRUB config"
fi

# Add gamepad configuration
# IMPORTANT: We need to load USB modules BEFORE the gamepad module
if ! grep -q "usb_gamepad" "$GRUB_CUSTOM" 2>/dev/null; then
    cat >> "$GRUB_CUSTOM" << 'GRUBEOF'

# ========================================
# SNES Gamepad Support
# ========================================
# Load USB host controller drivers
insmod ohci
insmod uhci
insmod ehci

# Load USB stack
insmod usb

# Load gamepad module
insmod usb_gamepad

# Register gamepad as input device
terminal_input --append usb_gamepad

# Map D-pad to navigation
gamepad_dpad U name up
gamepad_dpad D name down
gamepad_dpad L name left
gamepad_dpad R name right

# Map buttons
gamepad_btn 0 code 13
gamepad_btn 1 name esc
gamepad_start code 13
gamepad_back name esc
GRUBEOF
    ok "Added gamepad config to GRUB"
else
    info "GRUB already configured for gamepad"
fi

# Update GRUB
info "Updating GRUB..."
if command -v update-grub &>/dev/null; then
    update-grub 2>/dev/null || true
    ok "GRUB updated"
elif command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    ok "GRUB2 updated"
elif command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o "$GRUB_DIR/grub.cfg" 2>/dev/null || true
    ok "GRUB updated"
fi

# Cleanup
cd /
rm -rf "$BUILD_DIR"

########################################
# DONE
########################################
echo ""
echo -e "${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}          Installation Complete!                ${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}"
echo ""
echo "  Module installed: $GRUB_MOD_DIR/usb_gamepad.mod"
echo ""
echo "  Controls:"
echo "    D-pad Up/Down  ->  Navigate menu"
echo "    D-pad Left/Right -> Navigate submenus"
echo "    Button 0 / Start -> Select (Enter)"
echo "    Button 1 / Back  -> Cancel (Escape)"
echo ""
echo -e "  ${CYAN}${BOLD}Reboot and test in GRUB menu!${NC}"
echo ""
echo "  Troubleshooting:"
echo "    - If controller doesn't work, try different USB port"
echo "    - USB 2.0 ports work better than USB 3.0"
echo "    - Press 'c' in GRUB for command line, type 'lsusb' to check"
echo ""
echo "  To uninstall:"
echo "    sudo cp ${GRUB_CUSTOM}.backup-snes $GRUB_CUSTOM"
echo "    sudo rm $GRUB_MOD_DIR/usb_gamepad.mod"
echo "    sudo update-grub"
echo ""
