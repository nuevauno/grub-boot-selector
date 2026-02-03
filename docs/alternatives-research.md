# Alternative Boot OS Selection Methods (Without GRUB Keyboard Interaction)

Research into methods for selecting boot OS when Bluetooth keyboard doesn't work at boot time.

## The Problem

Bluetooth keyboards are not initialized during BIOS/UEFI POST or bootloader stage. This leaves users with dual-boot systems unable to select their operating system if they only have Bluetooth input devices.

---

## Solution Categories

### 1. GRUB Alternatives (Other Boot Managers)

#### rEFInd Boot Manager
- **Mouse support**: Enabled via `enable_mouse` in refind.conf
- **Touch support**: Enabled via `enable_touch` in refind.conf (mutually exclusive with mouse)
- **Gamepad support**: LIMITED - requires firmware support for HID devices
- **Pros**: Theme support, auto-detects Windows/Linux, more user-friendly
- **Cons**: Tricky with Secure Boot, mouse/touch depend on firmware support
- **Installation**: `sudo apt install refind` or download from [rodsbooks.com](https://rodsbooks.com/refind/)

**Sources:**
- [rEFInd Features](https://rodsbooks.com/refind/features.html)
- [rEFInd Configuration](https://rodsbooks.com/refind/configfile.html)

#### systemd-boot (gummiboot)
- **Default behavior**: If timeout is 0 (default), boots default entry immediately
- **No keyboard needed**: Set `timeout 0` and it boots the default without interaction
- **Access menu**: Hold Space key before systemd-boot launches
- **Pros**: Simple config, fast, minimal
- **Cons**: UEFI-only, limited customization

**Sources:**
- [systemd-boot ArchWiki](https://wiki.archlinux.org/title/Systemd-boot)
- [systemd-boot freedesktop](https://www.freedesktop.org/wiki/Software/systemd/systemd-boot/)

#### EFISTUB (Direct Kernel Boot)
- Boot Linux kernel directly from UEFI without bootloader
- Use `efibootmgr` to configure boot entries
- **No boot menu** - relies on UEFI boot order or one-time boot

---

### 2. One-Time Boot Commands (From Each OS)

**Best solution for keyboard-less boot selection!**

#### From Linux: `grub-reboot` Command
```bash
# List GRUB entries
grep -E "^menuentry|^submenu" /boot/grub/grub.cfg

# Set one-time boot to Windows
sudo grub-reboot "Windows Boot Manager"
sudo reboot
```

Requirements:
1. Edit `/etc/default/grub`: change `GRUB_DEFAULT=0` to `GRUB_DEFAULT=saved`
2. Run `sudo update-grub`

**Create Desktop Shortcut:**
```bash
#!/bin/bash
sudo grub-reboot "Windows Boot Manager" && sudo reboot
```

**Sources:**
- [Creating a "Reboot into Windows" Button](https://rastating.github.io/creating-a-reboot-into-windows-button-in-ubuntu/)
- [grub-reboot-picker GitHub](https://github.com/mendhak/grub-reboot-picker)
- [grub-reboot-windows GitHub](https://github.com/jamezrin/grub-reboot-windows)

#### From Linux: `efibootmgr` (UEFI Boot Next)
```bash
# List boot entries
sudo efibootmgr

# Set one-time boot to Windows (replace 0001 with your Windows boot number)
sudo efibootmgr -n 0001
sudo reboot
```

This sets the UEFI `BootNext` variable, which is cleared after one boot.

#### From Windows: `bcdedit` Commands
```cmd
# List boot entries (run as Administrator)
bcdedit /enum

# Set one-time boot to Linux (replace {identifier} with GRUB entry)
bcdedit /bootsequence {identifier}
shutdown /r /t 0
```

**Sources:**
- [BCDEdit /timeout - Microsoft Learn](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--timeout)
- [Change boot menu timeout Windows](https://pureinfotech.com/change-boot-menu-timeout-windows-11-10/)

#### For rEFInd: EFI Variable Method
Scripts modify the `PreviousBoot` EFI variable with rEFInd's GUID to pre-select the next boot entry.

**Source:** [rEFInd Reboot Scripts](https://gist.github.com/Darkhogg/82a651f40f835196df3b1bd1362f5b8c)

---

### 3. UEFI/BIOS Boot Menu (F11/F12 Method)

Most systems allow pressing a key during POST to access the boot menu:
- **F11** or **F12**: Boot menu (varies by manufacturer)
- **F2** or **Del**: BIOS setup
- **Esc**: Sometimes shows boot options

**Problem**: Still requires a working keyboard at boot time.

**Gaming Motherboard Controller Support**: Most UEFI implementations do NOT support gamepads natively. UEFI uses basic USB HID protocols that typically only cover keyboards and mice.

---

### 4. Remote Boot Selection

#### Wake-on-LAN + ESP8266 HTTP Boot Config
Innovative solution combining WOL with a microcontroller serving GRUB config:
- ESP8266 runs HTTP server serving GRUB config file
- GRUB modified to fetch config over HTTP
- Can remotely change boot OS before waking PC

**Source:** [Hackaday - Wake, Boot, Repeat](https://hackaday.com/2025/03/03/wake-boot-repeat-remote-os-selection-with-grub-and-esp/)

#### Phone Apps for Wake-on-LAN
- **iOS**: RemoteBoot WOL (supports Siri Shortcuts)
- **Android**: Various WOL apps in Play Store

Note: These only wake the PC; they don't select the boot OS unless combined with the HTTP config method above.

---

### 5. Hardware Boot Drive Switch

Physical switches to select which drive boots:

#### SATA Drive Power Switch
- DPDT toggle switch controls power to one of two drives
- Mount switch on front panel or rear PCI slot
- LED indicator shows which drive is powered
- **Products**: Kingwin KF-1000-BK (SATA hot swap), Oreco

**Cons**: Only works with SATA, not M.2 NVMe drives

#### Microcontroller-Based Solutions
- **RP2040/STM32/Pico**: Acts as USB mass storage serving boot config
- **Simple hack**: Wire a switch into a USB thumb drive's data line; GRUB detects presence/absence and boots accordingly

**Sources:**
- [Hardware Boot Selection Switch - Hackaday.io](https://hackaday.io/project/179539-hardware-boot-selection-switch)
- [Simple Hardware Switch for OS Dualbooting - Hackaday](https://hackaday.com/2022/05/02/simple-hardware-switch-for-os-dualbooting-thanks-to-rp2040/)

---

### 6. Hardware Controller-to-Keyboard Adapters

Convert gamepad input to USB keyboard HID at hardware level:

#### HID Remapper
- Configurable USB dongle
- Maps gamepad buttons to keyboard keys
- Works in hardware, no software needed on PC
- Configured via WebHID in Chrome browser
- **GitHub**: [jfedor2/hid-remapper](https://github.com/jfedor2/hid-remapper)

#### DIY Solutions
- **Raspberry Pi Pico**: $4, native USB HID support, reads SNES controller protocol via GPIO
- **STM32 Blue Pill**: $2-4, ARM processor, USB HID capable
- **Arduino Micro/Leonardo**: ATmega32U4 with native USB
- **Teensy 2.0**: Similar capabilities

These devices read gamepad input and present as a USB keyboard to the PC, working at BIOS/UEFI/bootloader level.

**Sources:**
- [PS2 Controller to USB HID Keyboard - Instructables](https://www.instructables.com/Ps2-Controller-to-Usb-Hid-Keyboard-Emulator/)
- [Pico Game Controller - GitHub](https://github.com/speedypotato/Pico-Game-Controller)

---

### 7. Steam Deck / Handheld Gaming PCs

These devices have special "Lizard Mode" where the gamepad acts as keyboard/mouse when no driver is loaded.

**Steam Deck**: Built-in controller works in BIOS and bootloader
**ROG Ally**: Does NOT have this feature - controller doesn't work until OS loads

For Bazzite/SteamOS dual boot:
```bash
ujust setup-boot-windows-steam
```
Then use "Boot Windows" option from Steam's interface.

**Source:** [Bazzite Dual Boot Guide](https://docs.bazzite.gg/General/Installation_Guide/dual_boot_setup_guide/)

---

### 8. Scheduled/Automatic Boot Switching

#### Default Boot + Timeout
Configure GRUB/systemd-boot/rEFInd to:
1. Set very short timeout (3-5 seconds)
2. Default to your most-used OS
3. When you need the other OS, use one-time boot commands

```bash
# /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
```

#### Time-Based Boot (Advanced)
Theoretically possible with custom GRUB scripts or boot manager configs to boot different OSes based on time of day.

---

## Recommended Solutions (Ranked by Practicality)

### For Your Situation (Bluetooth keyboard, no wired keyboard):

1. **Best: One-Time Boot Commands**
   - Set up `grub-reboot` on Linux and `bcdedit` on Windows
   - Create desktop shortcuts/scripts
   - Select next boot OS before rebooting
   - No hardware needed, works today

2. **Second Best: Hardware HID Remapper**
   - Buy or build a device that converts gamepad to keyboard
   - Plug gamepad into adapter, adapter into PC
   - Works with any bootloader
   - Cost: ~$15-30 commercial, ~$4 DIY

3. **Third: rEFInd with Mouse/Touch**
   - Replace GRUB with rEFInd
   - Enable mouse support if your UEFI supports it
   - Try USB mouse at boot (not Bluetooth)

4. **Long-Term: Keep a Cheap Wired USB Keyboard**
   - $10 USB keyboard kept near PC
   - Only needed for occasional boot selection
   - Most reliable solution

---

## Quick Setup: One-Time Boot Commands

### Linux Setup (5 minutes)
```bash
# 1. Configure GRUB for saved default
sudo sed -i 's/GRUB_DEFAULT=0/GRUB_DEFAULT=saved/' /etc/default/grub
sudo update-grub

# 2. Create reboot-to-windows script
cat << 'EOF' | sudo tee /usr/local/bin/reboot-windows
#!/bin/bash
grub-reboot "Windows Boot Manager"
reboot
EOF
sudo chmod +x /usr/local/bin/reboot-windows

# 3. Add sudoers entry for passwordless execution
echo "$USER ALL=(ALL) NOPASSWD: /usr/local/bin/reboot-windows" | sudo tee /etc/sudoers.d/reboot-windows
```

### Windows Setup (5 minutes)
```cmd
REM Run as Administrator
REM Create shortcut on Desktop pointing to:
REM   cmd /c "bcdedit /bootsequence {YOUR_LINUX_ID} && shutdown /r /t 0"
```

---

## References

- [GRUB Alternatives - Slant](https://www.slant.co/options/8093/alternatives/~grub2-alternatives)
- [GNU GRUB Alternatives - AlternativeTo](https://alternativeto.net/software/grub/)
- [Dual boot with Windows - ArchWiki](https://wiki.archlinux.org/title/Dual_boot_with_Windows)
- [systemd-boot - ArchWiki](https://wiki.archlinux.org/title/Systemd-boot)
- [rEFInd Boot Manager](https://rodsbooks.com/refind/)
