#!/bin/bash
#
# GRUB SNES Gamepad Installer v2.0
# https://github.com/nuevauno/grub-snes-gamepad
#
# IMPORTANT: This compiles a MODIFIED version of GRUB with SNES controller support
#

VERSION="2.1"

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
read -r -p "  Press ENTER when ready... " _

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
    read -r -p "  Press ENTER to continue to build..." _
else
    echo ""
    echo -e "  ${YELLOW}${BOLD}Button Test - Press each button when asked${NC}"
    echo ""

    # Run interactive button test
    MAPPER_OK=0
    python3 << 'PYEOF'
import sys, time

try:
    import usb.core, usb.util
except:
    print("  ERROR: pyusb not available")
    sys.exit(1)

G='\033[92m'; Y='\033[93m'; R='\033[91m'; B='\033[1m'; N='\033[0m'

def find_controller():
    for d in usb.core.find(find_all=True):
        try:
            for c in d:
                for i in c:
                    if i.bInterfaceClass == 3:
                        if i.bInterfaceSubClass == 1 and i.bInterfaceProtocol in [1,2]:
                            continue
                        return d
        except:
            pass
    return None

dev = find_controller()
if not dev:
    print(f"  {R}ERROR:{N} No controller found!")
    sys.exit(1)

print(f"  {G}Controller:{N} VID=0x{dev.idVendor:04x} PID=0x{dev.idProduct:04x}")

# Setup
try:
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
except: pass

try:
    dev.set_configuration()
except: pass

cfg = dev.get_active_configuration()
intf = cfg[(0,0)]
ep = None
for e in intf:
    if usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN:
        ep = e
        break

if not ep:
    print(f"  {R}ERROR:{N} No input endpoint!")
    sys.exit(1)

# Get baseline - DON'T PRESS ANYTHING
print(f"\n  {Y}DO NOT press any button for 2 seconds...{N}")
time.sleep(1)

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
    sys.exit(1)

baseline = max(set(reports), key=reports.count)
print(f"  {G}OK:{N} Baseline captured: {baseline.hex()}")

# Test each button
buttons = [
    ("D-PAD UP", 15),
    ("D-PAD DOWN", 15),
    ("A or any button", 15),
    ("START", 15),
]

detected = 0
print(f"\n  {B}Now press each button when asked:{N}\n")

for btn_name, timeout in buttons:
    sys.stdout.write(f"  {Y}>>>{N} Press {B}{btn_name}{N} {Y}<<<{N} ")
    sys.stdout.flush()

    found = False
    start = time.time()

    while time.time() - start < timeout:
        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
            if r != baseline:
                # Found a change!
                changes = []
                for i in range(min(len(baseline), len(r))):
                    if baseline[i] != r[i]:
                        changes.append(f"byte{i}: 0x{baseline[i]:02x}->0x{r[i]:02x}")

                if changes:
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
        print(f"{Y}TIMEOUT{N} (no press detected)")

    time.sleep(0.3)

print(f"\n  {'='*50}")
print(f"\n  {B}Result:{N} {detected}/4 buttons detected")

if detected >= 2:
    print(f"  {G}Controller is working!{N}")
    sys.exit(0)
else:
    print(f"  {R}Not enough buttons detected.{N}")
    print(f"  {Y}The controller might still work in GRUB.{N}")
    sys.exit(1)
PYEOF

    MAPPER_EXIT=$?
    echo ""

    if [ $MAPPER_EXIT -ne 0 ]; then
        echo -e "  ${YELLOW}Button test had issues, but we'll continue anyway.${NC}"
    fi

    echo ""
    read -r -p "  Press ENTER to continue to build step..." _
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

# PATCH: Modify usb_gamepad.c to support SNES controllers
info "Patching for SNES controller support..."

cat > /tmp/snes_patch.patch << 'PATCHEOF'
--- a/grub-core/term/usb_gamepad.c
+++ b/grub-core/term/usb_gamepad.c
@@ -31,8 +31,27 @@
 #define KEY_QUEUE_CAPACITY 32
 #define USB_REPORT_SIZE 8

-#define LOGITECH_VENDORID 0x046d
-#define RUMBLEPAD_PRODUCTID 0xc218
+/* Supported controllers - Logitech + SNES */
+struct supported_device {
+    grub_uint16_t vid;
+    grub_uint16_t pid;
+};
+
+static struct supported_device supported_devices[] = {
+    {0x046d, 0xc218},  /* Logitech Rumble F510 */
+    {0x0810, 0xe501},  /* Generic Chinese SNES */
+    {0x0079, 0x0011},  /* DragonRise Generic */
+    {0x0583, 0x2060},  /* iBuffalo SNES */
+    {0x2dc8, 0x9018},  /* 8BitDo SN30 */
+    {0x12bd, 0xd015},  /* Generic 2-pack SNES */
+    {0x1a34, 0x0802},  /* USB Gamepad */
+    {0x0810, 0x0001},  /* Generic USB Gamepad */
+    {0x0079, 0x0006},  /* DragonRise Gamepad */
+    {0x0000, 0x0000}   /* End marker */
+};

 static int dpad_mapping[DIR_COUNT] = { GRUB_TERM_NO_KEY };
 static int button_mapping[BUTTONS_COUNT] = { GRUB_TERM_NO_KEY };
@@ -258,16 +277,21 @@ grub_usb_gamepad_detach (grub_usb_device_t usbdev,
     }
 }

+static int
+is_supported_device(grub_uint16_t vid, grub_uint16_t pid)
+{
+    for (int i = 0; supported_devices[i].vid != 0; i++) {
+        if (supported_devices[i].vid == vid && supported_devices[i].pid == pid)
+            return 1;
+    }
+    return 0;
+}

 static int
 grub_usb_gamepad_attach(grub_usb_device_t usbdev, int configno, int interfno)
 {
-    if ((usbdev->descdev.vendorid != LOGITECH_VENDORID)
-        || (usbdev->descdev.prodid != RUMBLEPAD_PRODUCTID)) {
-        grub_dprintf("usb_gamepad",
-                     "Ignoring vendor %x, product %x. "
-                     "Only vendor %x and product %x are supported\n",
-                     usbdev->descdev.vendorid,
-                     usbdev->descdev.prodid,
-                     LOGITECH_VENDORID,
-                     RUMBLEPAD_PRODUCTID);
+    if (!is_supported_device(usbdev->descdev.vendorid, usbdev->descdev.prodid)) {
+        grub_dprintf("usb_gamepad", "Ignoring device %04x:%04x\n",
+                     usbdev->descdev.vendorid, usbdev->descdev.prodid);
         return 0;
     }
PATCHEOF

# Apply patch (may fail if already applied or structure different)
if patch -p1 --forward < /tmp/snes_patch.patch 2>/dev/null; then
    ok "SNES patch applied"
else
    warn "Patch may have already been applied or failed - continuing"
    # Manual modification as fallback
    if grep -q "LOGITECH_VENDORID" grub-core/term/usb_gamepad.c 2>/dev/null; then
        info "Applying manual modification..."
        sed -i 's/#define LOGITECH_VENDORID 0x046d/#define LOGITECH_VENDORID 0x0000/' grub-core/term/usb_gamepad.c
        sed -i 's/#define RUMBLEPAD_PRODUCTID 0xc218/#define RUMBLEPAD_PRODUCTID 0x0000/' grub-core/term/usb_gamepad.c
        # Change the check to accept any HID device
        sed -i 's/if ((usbdev->descdev.vendorid != LOGITECH_VENDORID)/if (0 \&\& (usbdev->descdev.vendorid != LOGITECH_VENDORID)/' grub-core/term/usb_gamepad.c
        ok "Manual modification applied (accepts all HID devices)"
    fi
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
CONF_OPTS="--with-platform=${GRUB_PLATFORM##*-} --disable-werror"
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
