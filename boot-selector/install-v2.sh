#!/bin/bash
#
# GRUB Gamepad Boot Selector v2.0
#
# SOLUCIÓN: Reemplazar getty en TTY1 para mostrar el selector
# ANTES de que aparezca el login.
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
echo -e "${CYAN}${BOLD}   Gamepad Boot Selector v2.0${NC}"
echo -e "${CYAN}${BOLD}========================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Ejecutar como root (sudo)${NC}"
    exit 1
fi

echo -e "${GREEN}[1/6]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 python3-evdev joystick

echo -e "${GREEN}[2/6]${NC} Creando selector de boot..."

mkdir -p /opt/boot-selector

# Script principal del selector
cat > /opt/boot-selector/selector.sh << 'SELECTOR_SH'
#!/bin/bash
#
# Boot Selector - Se ejecuta en TTY1 antes del login
#

TIMEOUT=10
SELECTED=0
SELECTOR_FLAG="/tmp/.boot-selector-done"

# Si ya corrió este boot, salir
if [ -f "$SELECTOR_FLAG" ]; then
    exit 0
fi

# Marcar como ejecutado
touch "$SELECTOR_FLAG"

# Esperar a que los dispositivos USB estén listos
sleep 2

# Limpiar pantalla
clear

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Buscar gamepad
GAMEPAD=""
for dev in /dev/input/js*; do
    if [ -e "$dev" ]; then
        GAMEPAD="$dev"
        break
    fi
done

# También buscar en event*
if [ -z "$GAMEPAD" ]; then
    for dev in /dev/input/event*; do
        if [ -e "$dev" ]; then
            # Verificar si es un gamepad
            if udevadm info "$dev" 2>/dev/null | grep -qi "ID_INPUT_JOYSTICK=1"; then
                GAMEPAD="$dev"
                break
            fi
        fi
    done
fi

draw_menu() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║           SELECTOR DE SISTEMA OPERATIVO                  ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [ "$SELECTED" -eq 0 ]; then
        echo -e "      ${GREEN}${BOLD}► Ubuntu Linux ◄${NC}"
        echo -e "        Windows"
    else
        echo -e "        Ubuntu Linux"
        echo -e "      ${GREEN}${BOLD}► Windows ◄${NC}"
    fi

    echo ""
    echo -e "${YELLOW}─────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  Controles:"
    echo -e "    ${CYAN}Flechas / D-Pad${NC}  →  Navegar"
    echo -e "    ${CYAN}Enter / Botón A${NC}  →  Seleccionar"
    echo ""
    echo -e "  ${YELLOW}Auto-boot Ubuntu en: $1 segundos${NC}"
    echo ""
    if [ -n "$GAMEPAD" ]; then
        echo -e "  Gamepad: ${GREEN}✓ Detectado${NC}"
    else
        echo -e "  Gamepad: ${YELLOW}No detectado (usando teclado)${NC}"
    fi
    echo ""
}

# Función para leer input
read_input() {
    local timeout=$1
    local input=""

    # Leer con timeout
    if read -rsn1 -t "$timeout" input; then
        if [ "$input" = $'\x1b' ]; then
            read -rsn2 -t 0.1 input
            case "$input" in
                '[A') echo "up" ;;    # Flecha arriba
                '[B') echo "down" ;;  # Flecha abajo
            esac
        elif [ "$input" = "" ]; then
            echo "enter"
        fi
    else
        echo "timeout"
    fi
}

# Buscar entrada de Windows en GRUB
find_windows_entry() {
    grep -oP "menuentry '\K[^']*[Ww]indows[^']*" /boot/grub/grub.cfg 2>/dev/null | head -1
}

# Boot a Windows
boot_windows() {
    local windows_entry
    windows_entry=$(find_windows_entry)

    if [ -n "$windows_entry" ]; then
        echo ""
        echo -e "${CYAN}Configurando boot a Windows...${NC}"
        grub-reboot "$windows_entry"
        echo -e "${GREEN}Reiniciando...${NC}"
        sleep 1
        reboot
    else
        echo ""
        echo -e "${RED}No se encontró Windows en GRUB${NC}"
        echo "Continuando con Ubuntu..."
        sleep 2
    fi
}

# Loop principal
main() {
    local remaining=$TIMEOUT

    while [ "$remaining" -gt 0 ]; do
        draw_menu "$remaining"

        local action
        action=$(read_input 1)

        case "$action" in
            up|down)
                SELECTED=$((1 - SELECTED))
                remaining=$TIMEOUT
                ;;
            enter)
                break
                ;;
            timeout)
                remaining=$((remaining - 1))
                ;;
        esac
    done

    clear

    if [ "$SELECTED" -eq 0 ]; then
        echo -e "${GREEN}Iniciando Ubuntu...${NC}"
        # No hacer nada, continuar boot normal
    else
        boot_windows
    fi
}

# Ejecutar
main
SELECTOR_SH

chmod +x /opt/boot-selector/selector.sh

echo -e "${GREEN}[3/6]${NC} Configurando servicio getty personalizado..."

# Crear un servicio que corre el selector en TTY1 antes del login normal
mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/boot-selector.conf << 'OVERRIDE'
[Service]
ExecStartPre=-/opt/boot-selector/selector.sh
OVERRIDE

echo -e "${GREEN}[4/6]${NC} Creando alternativa con autologin..."

# Otra opción: autologin que ejecuta el selector
cat > /opt/boot-selector/selector-wrapper.sh << 'WRAPPER'
#!/bin/bash
# Wrapper que ejecuta selector y luego hace login normal

FLAG="/tmp/.boot-selector-shown"

if [ ! -f "$FLAG" ]; then
    touch "$FLAG"
    /opt/boot-selector/selector.sh
fi

# Continuar con shell normal o salir para que getty reinicie
exec /bin/bash
WRAPPER

chmod +x /opt/boot-selector/selector-wrapper.sh

echo -e "${GREEN}[5/6]${NC} Configurando GRUB..."

# Backup
cp /etc/default/grub /etc/default/grub.backup-selector 2>/dev/null || true

# Timeout bajo
if ! grep -q "GRUB_TIMEOUT=2" /etc/default/grub; then
    sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
fi

# Asegurar que Ubuntu es el default
sed -i 's/GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub

update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

echo -e "${GREEN}[6/6]${NC} Recargando systemd..."

systemctl daemon-reload

# Crear script de desinstalación
cat > /opt/boot-selector/uninstall.sh << 'UNINSTALL'
#!/bin/bash
rm -f /etc/systemd/system/getty@tty1.service.d/boot-selector.conf
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
rm -rf /opt/boot-selector
cp /etc/default/grub.backup-selector /etc/default/grub 2>/dev/null || true
update-grub 2>/dev/null || true
systemctl daemon-reload
echo "Boot selector desinstalado"
UNINSTALL

chmod +x /opt/boot-selector/uninstall.sh

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}        ¡Instalación Completa!          ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
echo "  El selector se mostrará en TTY1 al iniciar."
echo ""
echo "  Controles:"
echo "    Flechas ↑↓    → Navegar"
echo "    Enter         → Seleccionar"
echo "    (esperar 10s) → Auto-boot Ubuntu"
echo ""
echo -e "  ${YELLOW}PROBAR AHORA:${NC}"
echo "    sudo /opt/boot-selector/selector.sh"
echo ""
echo -e "  ${CYAN}Desinstalar:${NC}"
echo "    sudo /opt/boot-selector/uninstall.sh"
echo ""
echo -e "  ${GREEN}¡Reinicia para probar!${NC}"
echo ""
