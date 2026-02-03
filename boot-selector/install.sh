#!/bin/bash
#
# GRUB Gamepad Boot Selector v1.0
#
# Este script instala un selector de boot que funciona con gamepad USB.
# Carga Ubuntu en modo mínimo, muestra un menú, y permite elegir el SO.
#
# Funciona porque Linux SÍ tiene drivers para gamepads USB.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}========================================${NC}"
echo -e "${CYAN}${BOLD}   Gamepad Boot Selector Installer${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Ejecutar como root (sudo)${NC}"
    exit 1
fi

# Check we're on Ubuntu/Debian
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}Error: Sistema no soportado${NC}"
    exit 1
fi

echo -e "${GREEN}[1/5]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 python3-evdev dialog kexec-tools

echo -e "${GREEN}[2/5]${NC} Creando selector de boot..."

# Create the boot selector directory
mkdir -p /opt/boot-selector

# Create the gamepad menu script
cat > /opt/boot-selector/selector.py << 'SELECTOR'
#!/usr/bin/env python3
"""
Boot Selector con soporte de Gamepad USB
Lee input del gamepad y permite elegir entre Ubuntu y Windows
"""

import os
import sys
import time
import subprocess
import glob

# Intentar importar evdev (para gamepad)
try:
    import evdev
    from evdev import ecodes
    HAS_EVDEV = True
except ImportError:
    HAS_EVDEV = False

# Colores ANSI
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    END = '\033[0m'

# Configuración
TIMEOUT = 10  # Segundos para auto-boot
DEFAULT_OS = "ubuntu"  # ubuntu o windows
WINDOWS_ENTRY = "Windows Boot Manager"  # Nombre en GRUB

def clear_screen():
    os.system('clear')

def find_gamepad():
    """Busca un gamepad conectado"""
    if not HAS_EVDEV:
        return None

    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
    for device in devices:
        caps = device.capabilities()
        # Buscar dispositivos con ejes absolutos (joysticks/gamepads)
        if ecodes.EV_ABS in caps:
            abs_caps = caps[ecodes.EV_ABS]
            # Verificar que tenga al menos X e Y axis
            abs_codes = [code for code, _ in abs_caps] if abs_caps else []
            if ecodes.ABS_X in abs_codes or ecodes.ABS_HAT0X in abs_codes:
                return device
    return None

def get_grub_entries():
    """Obtiene las entradas de GRUB"""
    entries = []
    try:
        result = subprocess.run(['grep', '-E', '^menuentry|^submenu', '/boot/grub/grub.cfg'],
                                capture_output=True, text=True)
        for line in result.stdout.split('\n'):
            if 'menuentry' in line:
                # Extraer nombre entre comillas
                start = line.find("'")
                if start == -1:
                    start = line.find('"')
                if start != -1:
                    end = line.find("'", start + 1)
                    if end == -1:
                        end = line.find('"', start + 1)
                    if end != -1:
                        name = line[start+1:end]
                        entries.append(name)
    except:
        pass
    return entries

def find_windows_entry():
    """Busca la entrada de Windows en GRUB"""
    entries = get_grub_entries()
    for entry in entries:
        if 'windows' in entry.lower():
            return entry
    return None

def boot_windows():
    """Configura GRUB para bootear Windows y reinicia"""
    windows_entry = find_windows_entry()
    if windows_entry:
        print(f"\n{Colors.CYAN}Reiniciando a Windows...{Colors.END}")
        subprocess.run(['grub-reboot', windows_entry], check=False)
        time.sleep(1)
        subprocess.run(['systemctl', 'reboot'], check=False)
    else:
        print(f"\n{Colors.RED}No se encontró Windows en GRUB{Colors.END}")
        time.sleep(3)
        boot_ubuntu()

def boot_ubuntu():
    """Continúa el boot normal de Ubuntu"""
    print(f"\n{Colors.GREEN}Iniciando Ubuntu...{Colors.END}")
    time.sleep(1)
    # Salir con código 0 para continuar boot normal
    sys.exit(0)

def draw_menu(selected, timeout_remaining, gamepad_status):
    """Dibuja el menú de selección"""
    clear_screen()

    print(f"""
{Colors.CYAN}{Colors.BOLD}╔══════════════════════════════════════════════════════════╗
║             SELECTOR DE SISTEMA OPERATIVO                 ║
╚══════════════════════════════════════════════════════════╝{Colors.END}
""")

    options = ["Ubuntu Linux", "Windows"]

    for i, opt in enumerate(options):
        if i == selected:
            print(f"  {Colors.GREEN}{Colors.BOLD}  ► {opt} ◄  {Colors.END}")
        else:
            print(f"      {opt}")

    print(f"""
{Colors.YELLOW}─────────────────────────────────────────────────────────────{Colors.END}

  Controles:
    {Colors.CYAN}D-Pad / Flechas{Colors.END}  →  Navegar
    {Colors.CYAN}A / Start / Enter{Colors.END}  →  Seleccionar

  {Colors.YELLOW}Auto-boot en: {timeout_remaining}s{Colors.END}

  Gamepad: {gamepad_status}
""")

def read_gamepad_input(gamepad, timeout=0.1):
    """Lee input del gamepad de forma no bloqueante"""
    if not gamepad:
        return None

    try:
        # Leer eventos con timeout
        import select
        r, _, _ = select.select([gamepad.fd], [], [], timeout)
        if r:
            for event in gamepad.read():
                if event.type == ecodes.EV_ABS:
                    # D-pad como ejes
                    if event.code == ecodes.ABS_Y or event.code == ecodes.ABS_HAT0Y:
                        if event.value < 100:  # Arriba
                            return 'up'
                        elif event.value > 150:  # Abajo
                            return 'down'
                    elif event.code == ecodes.ABS_X or event.code == ecodes.ABS_HAT0X:
                        if event.value < 100:  # Izquierda
                            return 'left'
                        elif event.value > 150:  # Derecha
                            return 'right'
                elif event.type == ecodes.EV_KEY:
                    # Botones
                    if event.value == 1:  # Presionado
                        # Botones comunes: BTN_A, BTN_B, BTN_START, etc.
                        if event.code in [ecodes.BTN_A, ecodes.BTN_SOUTH,
                                         ecodes.BTN_START, ecodes.BTN_SELECT,
                                         304, 305, 307, 308]:  # Códigos comunes SNES
                            return 'select'
    except Exception as e:
        pass
    return None

def read_keyboard_input(timeout=0.1):
    """Lee input del teclado de forma no bloqueante"""
    import select
    import termios
    import tty

    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setraw(sys.stdin.fileno())
        rlist, _, _ = select.select([sys.stdin], [], [], timeout)
        if rlist:
            key = sys.stdin.read(1)
            if key == '\x1b':  # Escape sequence
                extra = sys.stdin.read(2)
                if extra == '[A':
                    return 'up'
                elif extra == '[B':
                    return 'down'
            elif key == '\r' or key == '\n':
                return 'select'
    except:
        pass
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
    return None

def main():
    selected = 0  # 0 = Ubuntu, 1 = Windows
    timeout_remaining = TIMEOUT
    last_time = time.time()

    # Buscar gamepad
    gamepad = find_gamepad()
    if gamepad:
        gamepad_status = f"{Colors.GREEN}✓ Detectado: {gamepad.name}{Colors.END}"
        try:
            gamepad.grab()  # Capturar exclusivamente
        except:
            pass
    else:
        gamepad_status = f"{Colors.YELLOW}No detectado (usando teclado){Colors.END}"

    try:
        while timeout_remaining > 0:
            draw_menu(selected, int(timeout_remaining), gamepad_status)

            # Leer input de gamepad
            action = None
            if gamepad:
                action = read_gamepad_input(gamepad, 0.05)

            # Leer input de teclado también
            if not action:
                action = read_keyboard_input(0.05)

            if action == 'up' or action == 'left':
                selected = (selected - 1) % 2
                timeout_remaining = TIMEOUT  # Reset timeout on input
            elif action == 'down' or action == 'right':
                selected = (selected + 1) % 2
                timeout_remaining = TIMEOUT
            elif action == 'select':
                break

            # Actualizar countdown
            current_time = time.time()
            timeout_remaining -= (current_time - last_time)
            last_time = current_time

    finally:
        if gamepad:
            try:
                gamepad.ungrab()
            except:
                pass

    # Ejecutar selección
    clear_screen()
    if selected == 0:
        boot_ubuntu()
    else:
        boot_windows()

if __name__ == "__main__":
    # Si se pasa --skip, continuar boot normal
    if len(sys.argv) > 1 and sys.argv[1] == '--skip':
        sys.exit(0)

    main()
SELECTOR

chmod +x /opt/boot-selector/selector.py

echo -e "${GREEN}[3/5]${NC} Creando servicio systemd..."

# Create systemd service that runs early in boot
cat > /etc/systemd/system/boot-selector.service << 'SERVICE'
[Unit]
Description=Gamepad Boot Selector
DefaultDependencies=no
After=systemd-udevd.service
Before=basic.target
Wants=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/opt/boot-selector/selector.py
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=sysinit.target
SERVICE

echo -e "${GREEN}[4/5]${NC} Configurando GRUB..."

# Backup GRUB config
cp /etc/default/grub /etc/default/grub.backup-selector 2>/dev/null || true

# Reducir timeout de GRUB a 0 (el selector es el nuevo menú)
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub

# Actualizar GRUB
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

echo -e "${GREEN}[5/5]${NC} Habilitando servicio..."

systemctl daemon-reload
systemctl enable boot-selector.service

# Create uninstall script
cat > /opt/boot-selector/uninstall.sh << 'UNINSTALL'
#!/bin/bash
systemctl disable boot-selector.service
rm -f /etc/systemd/system/boot-selector.service
rm -rf /opt/boot-selector
cp /etc/default/grub.backup-selector /etc/default/grub 2>/dev/null || true
update-grub 2>/dev/null || true
echo "Boot selector desinstalado"
UNINSTALL
chmod +x /opt/boot-selector/uninstall.sh

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}        ¡Instalación Completa!          ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
echo "  El selector de boot está instalado."
echo ""
echo "  Al reiniciar verás un menú donde puedes"
echo "  elegir Ubuntu o Windows con tu gamepad."
echo ""
echo "  Controles:"
echo "    D-Pad Arriba/Abajo → Navegar"
echo "    Botón A/Start      → Seleccionar"
echo ""
echo "  Auto-boot: Ubuntu en 10 segundos"
echo ""
echo -e "  ${YELLOW}Para probar: sudo /opt/boot-selector/selector.py${NC}"
echo ""
echo -e "  ${CYAN}Desinstalar: sudo /opt/boot-selector/uninstall.sh${NC}"
echo ""
echo -e "  ${GREEN}¡Reinicia para probar!${NC}"
echo ""
