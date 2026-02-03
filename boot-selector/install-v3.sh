#!/bin/bash
#
# GRUB Gamepad Boot Selector v3.0
#
# Enfoque SIMPLE: Usar rc.local para mostrar el selector
# ANTES de que el sistema esté completamente arriba.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   Gamepad Boot Selector v3.0           ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Ejecutar como root (sudo)${NC}"
    exit 1
fi

echo -e "${GREEN}[1/5]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 evtest joystick 2>/dev/null || true

echo -e "${GREEN}[2/5]${NC} Creando selector..."

mkdir -p /opt/boot-selector

# Script del selector - versión simple con bash
cat > /opt/boot-selector/menu.sh << 'MENUSCRIPT'
#!/bin/bash

# Flag para no correr dos veces
FLAG_FILE="/run/boot-selector-done"
[ -f "$FLAG_FILE" ] && exit 0

# Configuración
TIMEOUT=15
DEFAULT=0  # 0=Ubuntu, 1=Windows

# Esperar que carguen los módulos USB
sleep 3

# Limpiar y configurar terminal
exec < /dev/tty1 > /dev/tty1 2>&1
clear

# Colores
G='\033[1;32m'  # Verde
Y='\033[1;33m'  # Amarillo
C='\033[1;36m'  # Cyan
W='\033[1;37m'  # Blanco
N='\033[0m'     # Reset

selected=$DEFAULT

# Función para dibujar menú
draw() {
    clear
    echo ""
    echo -e "${C}╔══════════════════════════════════════════╗${N}"
    echo -e "${C}║     SELECCIONAR SISTEMA OPERATIVO        ║${N}"
    echo -e "${C}╚══════════════════════════════════════════╝${N}"
    echo ""

    if [ $selected -eq 0 ]; then
        echo -e "       ${G}▶ Ubuntu Linux ◀${N}"
        echo -e "         Windows"
    else
        echo -e "         Ubuntu Linux"
        echo -e "       ${G}▶ Windows ◀${N}"
    fi

    echo ""
    echo -e "${Y}──────────────────────────────────────────${N}"
    echo ""
    echo -e "  ${W}Flechas ↑↓${N} = Navegar"
    echo -e "  ${W}Enter${N}      = Seleccionar"
    echo ""
    echo -e "  ${Y}Auto-boot en: $1 segundos${N}"
    echo ""

    # Detectar gamepad
    if ls /dev/input/js* 1>/dev/null 2>&1; then
        echo -e "  Gamepad: ${G}✓ Detectado${N}"
    else
        echo -e "  Gamepad: ${Y}Usando teclado${N}"
    fi
}

# Buscar Windows en GRUB
get_windows() {
    grep -m1 -oP "menuentry '[^']*[Ww]indows[^']*" /boot/grub/grub.cfg 2>/dev/null | sed "s/menuentry '//" | head -1
}

# Loop principal
remaining=$TIMEOUT
while [ $remaining -gt 0 ]; do
    draw $remaining

    # Leer una tecla con timeout de 1 segundo
    if read -rsn1 -t1 key; then
        case "$key" in
            $'\x1b')  # Escape sequence (flechas)
                read -rsn2 -t0.1 seq
                case "$seq" in
                    '[A') selected=0 ;;  # Arriba
                    '[B') selected=1 ;;  # Abajo
                esac
                remaining=$TIMEOUT
                ;;
            '')  # Enter
                break
                ;;
        esac
    else
        remaining=$((remaining - 1))
    fi
done

# Marcar como completado
touch "$FLAG_FILE"

clear

if [ $selected -eq 1 ]; then
    win=$(get_windows)
    if [ -n "$win" ]; then
        echo -e "${C}Reiniciando a Windows...${N}"
        grub-reboot "$win" 2>/dev/null || grub-reboot "Windows Boot Manager" 2>/dev/null
        sleep 1
        reboot
        exit 0
    else
        echo -e "${Y}Windows no encontrado, iniciando Ubuntu...${N}"
        sleep 2
    fi
fi

echo -e "${G}Iniciando Ubuntu...${N}"
sleep 1
MENUSCRIPT

chmod +x /opt/boot-selector/menu.sh

echo -e "${GREEN}[3/5]${NC} Configurando inicio automático..."

# MÉTODO 1: Servicio systemd que corre antes de display-manager
cat > /etc/systemd/system/boot-selector.service << 'SVCFILE'
[Unit]
Description=Boot OS Selector
After=systemd-user-sessions.service
Before=display-manager.service gdm.service lightdm.service sddm.service
ConditionPathExists=!/run/boot-selector-done

[Service]
Type=oneshot
ExecStart=/opt/boot-selector/menu.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload
systemctl enable boot-selector.service

# MÉTODO 2: También agregarlo a rc.local como backup
if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/bash' > /etc/rc.local
    echo 'exit 0' >> /etc/rc.local
    chmod +x /etc/rc.local
fi

# Agregar al inicio de rc.local (después del shebang)
if ! grep -q "boot-selector" /etc/rc.local; then
    sed -i '2i /opt/boot-selector/menu.sh &' /etc/rc.local
fi

echo -e "${GREEN}[4/5]${NC} Configurando GRUB..."

cp /etc/default/grub /etc/default/grub.bak-selector 2>/dev/null || true
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

echo -e "${GREEN}[5/5]${NC} Creando desinstalador..."

cat > /opt/boot-selector/uninstall.sh << 'UNINST'
#!/bin/bash
systemctl disable boot-selector.service 2>/dev/null
rm -f /etc/systemd/system/boot-selector.service
sed -i '/boot-selector/d' /etc/rc.local 2>/dev/null
rm -rf /opt/boot-selector
rm -f /run/boot-selector-done
cp /etc/default/grub.bak-selector /etc/default/grub 2>/dev/null
update-grub 2>/dev/null || true
systemctl daemon-reload
echo "Desinstalado correctamente"
UNINST
chmod +x /opt/boot-selector/uninstall.sh

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}       ¡INSTALACIÓN COMPLETA!           ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
echo "  El menú aparecerá al iniciar antes del login."
echo ""
echo -e "  ${W}PROBAR AHORA (sin reiniciar):${NC}"
echo "    sudo rm -f /run/boot-selector-done"
echo "    sudo /opt/boot-selector/menu.sh"
echo ""
echo -e "  ${W}REINICIAR:${NC}"
echo "    sudo reboot"
echo ""
echo -e "  ${W}DESINSTALAR:${NC}"
echo "    sudo /opt/boot-selector/uninstall.sh"
echo ""
