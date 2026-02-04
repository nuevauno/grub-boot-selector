# GRUB Boot Selector

Selector de arranque para GRUB controlado con gamepad y teclado, ideal para dual-boot.

## Que hace

- Muestra un menu simple en TTY1 antes de iniciar sesion.
- Puedes elegir Windows/Ubuntu con D-pad o flechas.
- Si no tocas nada, arranca solo en unos segundos.
- Si no hay gamepad, funciona con teclado.

## Instalacion rapida

```bash
curl -sSL https://github.com/nuevauno/grub-boot-selector/releases/latest/download/install.sh | sudo bash
```

## Controles

- D-pad / Flechas: navegar
- A / Start / Enter: seleccionar

## Requisitos

- Linux con systemd y GRUB.
- Gamepad USB (opcional).
- En Debian/Ubuntu instala dependencias automaticamente (python3, python3-evdev, joystick, kbd).

## Comandos utiles

```bash
sudo /opt/boot-selector/test.sh
sudo /opt/boot-selector/uninstall.sh
```

## Log

```bash
cat /var/log/boot-selector.log
```

## Desarrollo

El instalador principal vive en `boot-selector/install.sh`.
