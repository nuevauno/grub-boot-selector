/*
 * GRUB USB SNES Gamepad Module
 *
 * Minimal implementation for USB SNES/NES gamepad support in GRUB bootloader.
 * Based on GRUB's usb_keyboard.c initialization sequence and tsoding's gamepad module.
 *
 * This module:
 * 1. Accepts ANY USB HID device (gamepad mode) or specific VID/PIDs
 * 2. Properly initializes the USB device using HID protocol commands
 * 3. Parses standard 8-byte HID gamepad reports
 * 4. Registers as a terminal input device
 *
 * HID Report Format (Generic SNES):
 *   Byte 0: X-axis (0x00=Left, 0x7F=Center, 0xFF=Right)
 *   Byte 1: Y-axis (0x00=Up, 0x7F=Center, 0xFF=Down)
 *   Byte 2-3: Unused (typically 0x7F)
 *   Byte 4: Buttons (bit0=X, bit1=A, bit2=B, bit3=Y, bit4=L, bit5=R, bit6=Select, bit7=Start)
 *   Byte 5-7: Padding
 *
 * License: GPLv3+
 */

#include <grub/dl.h>
#include <grub/term.h>
#include <grub/usb.h>
#include <grub/misc.h>
#include <grub/time.h>

GRUB_MOD_LICENSE ("GPLv3+");

/*
 * USB HID Class Request Values
 * From USB HID Specification 1.11, Section 7.2
 */
#define USB_HID_GET_REPORT      0x01
#define USB_HID_GET_IDLE        0x02
#define USB_HID_GET_PROTOCOL    0x03
#define USB_HID_SET_REPORT      0x09
#define USB_HID_SET_IDLE        0x0A
#define USB_HID_SET_PROTOCOL    0x0B

/*
 * USB HID Subclass and Protocol values
 * Boot protocol is simpler and more compatible
 */
#define USB_HID_BOOT_SUBCLASS   0x01
#define USB_HID_GAMEPAD_PROTOCOL 0x00  /* Gamepads use protocol 0 */

/*
 * Module configuration
 */
#define GAMEPADS_CAPACITY       8
#define KEY_QUEUE_CAPACITY      32
#define USB_REPORT_SIZE         8

/*
 * D-pad axis processing
 */
#define AXIS_CENTER             0x7F
#define AXIS_THRESHOLD          0x40

/*
 * SNES Button bit masks (in report byte 4)
 */
#define BTN_X           (1 << 0)
#define BTN_A           (1 << 1)
#define BTN_B           (1 << 2)
#define BTN_Y           (1 << 3)
#define BTN_L           (1 << 4)
#define BTN_R           (1 << 5)
#define BTN_SELECT      (1 << 6)
#define BTN_START       (1 << 7)

/*
 * Supported SNES controller VID/PIDs
 * Set ACCEPT_ANY_HID to 1 to accept any HID gamepad device
 */
#define ACCEPT_ANY_HID  1

struct snes_device_id {
    grub_uint16_t vid;
    grub_uint16_t pid;
    const char *name;
};

static const struct snes_device_id known_devices[] = {
    { 0x0810, 0xe501, "Generic SNES (0810:e501)" },
    { 0x0079, 0x0011, "DragonRise (0079:0011)" },
    { 0x0583, 0x2060, "iBuffalo SNES (0583:2060)" },
    { 0x2dc8, 0x9018, "8BitDo SN30 (2dc8:9018)" },
    { 0x12bd, 0xd015, "Generic 2-pack (12bd:d015)" },
    { 0x1a34, 0x0802, "USB Gamepad (1a34:0802)" },
    { 0x0810, 0x0001, "Generic Gamepad (0810:0001)" },
    { 0x0079, 0x0006, "DragonRise (0079:0006)" },
    { 0x0000, 0x0000, NULL }  /* End marker */
};

/*
 * Key mappings - GRUB navigation keys
 */
static int key_up     = GRUB_TERM_KEY_UP;
static int key_down   = GRUB_TERM_KEY_DOWN;
static int key_left   = GRUB_TERM_KEY_LEFT;
static int key_right  = GRUB_TERM_KEY_RIGHT;
static int key_a      = '\r';                   /* Enter - select */
static int key_b      = GRUB_TERM_ESC;          /* Escape - back */
static int key_start  = '\r';                   /* Enter - select */
static int key_select = 'e';                    /* Edit entry */
static int key_x      = 'c';                    /* Command line */
static int key_y      = GRUB_TERM_ESC;          /* Escape - back */
static int key_l      = GRUB_TERM_KEY_PPAGE;    /* Page up */
static int key_r      = GRUB_TERM_KEY_NPAGE;    /* Page down */

/*
 * Per-device state structure
 */
struct grub_usb_snes_data
{
    grub_usb_device_t usbdev;
    int configno;
    int interfno;
    struct grub_usb_desc_endp *endp;
    grub_usb_transfer_t transfer;
    grub_uint8_t report[USB_REPORT_SIZE];
    grub_uint8_t prev_report[USB_REPORT_SIZE];
    int key_queue[KEY_QUEUE_CAPACITY];
    int key_queue_begin;
    int key_queue_size;
};

/*
 * Terminal input devices array
 */
static struct grub_term_input gamepads[GAMEPADS_CAPACITY];

/*
 * Initial/baseline report for SNES controllers (centered, no buttons)
 */
static const grub_uint8_t baseline_report[USB_REPORT_SIZE] = {
    0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00, 0x00, 0x00
};

/*
 * Key queue operations
 */
static void
key_queue_push (struct grub_usb_snes_data *data, int key)
{
    if (key == GRUB_TERM_NO_KEY)
        return;

    int pos = (data->key_queue_begin + data->key_queue_size) % KEY_QUEUE_CAPACITY;
    data->key_queue[pos] = key;

    if (data->key_queue_size < KEY_QUEUE_CAPACITY)
    {
        data->key_queue_size++;
    }
    else
    {
        /* Queue full, drop oldest */
        data->key_queue_begin = (data->key_queue_begin + 1) % KEY_QUEUE_CAPACITY;
    }
}

static int
key_queue_pop (struct grub_usb_snes_data *data)
{
    if (data->key_queue_size <= 0)
        return GRUB_TERM_NO_KEY;

    int key = data->key_queue[data->key_queue_begin];
    data->key_queue_begin = (data->key_queue_begin + 1) % KEY_QUEUE_CAPACITY;
    data->key_queue_size--;
    return key;
}

/*
 * Check if this is a known SNES controller
 */
static const char *
get_device_name (grub_uint16_t vid, grub_uint16_t pid)
{
    int i;
    for (i = 0; known_devices[i].name != NULL; i++)
    {
        if (known_devices[i].vid == vid && known_devices[i].pid == pid)
            return known_devices[i].name;
    }
    return NULL;
}

/*
 * Process HID report and generate key events
 */
static void
process_report (struct grub_usb_snes_data *data)
{
    grub_uint8_t *prev = data->prev_report;
    grub_uint8_t *curr = data->report;

    /* D-pad from X-axis (byte 0) */
    int prev_left  = (prev[0] < AXIS_CENTER - AXIS_THRESHOLD);
    int prev_right = (prev[0] > AXIS_CENTER + AXIS_THRESHOLD);
    int curr_left  = (curr[0] < AXIS_CENTER - AXIS_THRESHOLD);
    int curr_right = (curr[0] > AXIS_CENTER + AXIS_THRESHOLD);

    /* D-pad from Y-axis (byte 1) */
    int prev_up   = (prev[1] < AXIS_CENTER - AXIS_THRESHOLD);
    int prev_down = (prev[1] > AXIS_CENTER + AXIS_THRESHOLD);
    int curr_up   = (curr[1] < AXIS_CENTER - AXIS_THRESHOLD);
    int curr_down = (curr[1] > AXIS_CENTER + AXIS_THRESHOLD);

    /* Generate key events on press (not release) */
    if (!prev_up && curr_up)
        key_queue_push (data, key_up);
    if (!prev_down && curr_down)
        key_queue_push (data, key_down);
    if (!prev_left && curr_left)
        key_queue_push (data, key_left);
    if (!prev_right && curr_right)
        key_queue_push (data, key_right);

    /* Buttons from byte 4 */
    grub_uint8_t prev_btns = prev[4];
    grub_uint8_t curr_btns = curr[4];

#define BTN_PRESSED(p, c, m) (!(p & m) && (c & m))

    if (BTN_PRESSED (prev_btns, curr_btns, BTN_A))
        key_queue_push (data, key_a);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_B))
        key_queue_push (data, key_b);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_X))
        key_queue_push (data, key_x);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_Y))
        key_queue_push (data, key_y);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_START))
        key_queue_push (data, key_start);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_SELECT))
        key_queue_push (data, key_select);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_L))
        key_queue_push (data, key_l);
    if (BTN_PRESSED (prev_btns, curr_btns, BTN_R))
        key_queue_push (data, key_r);

#undef BTN_PRESSED
}

/*
 * Terminal input: getkey
 * Called repeatedly by GRUB to poll for input
 */
static int
grub_usb_snes_getkey (struct grub_term_input *term)
{
    struct grub_usb_snes_data *data = term->data;
    grub_size_t actual;
    grub_usb_err_t err;

    /* Check if USB transfer completed */
    err = grub_usb_check_transfer (data->transfer, &actual);

    if (err != GRUB_USB_ERR_WAIT)
    {
        /* Transfer completed (success or error) */
        if (err == GRUB_USB_ERR_NONE && actual == USB_REPORT_SIZE)
        {
            /* Valid report received - process it */
            process_report (data);
        }

        /* Save current report as previous */
        grub_memcpy (data->prev_report, data->report, USB_REPORT_SIZE);

        /* Start new background read */
        data->transfer = grub_usb_bulk_read_background (
            data->usbdev,
            data->endp,
            sizeof (data->report),
            (char *) data->report);

        if (!data->transfer)
        {
            grub_dprintf ("usb_snes", "Failed to restart USB transfer\n");
            grub_print_error ();
        }
    }

    return key_queue_pop (data);
}

/*
 * Terminal input: getkeystatus
 * Returns modifier key status (we have none)
 */
static int
grub_usb_snes_getkeystatus (struct grub_term_input *term __attribute__ ((unused)))
{
    return 0;
}

/*
 * USB device detach callback
 */
static void
grub_usb_snes_detach (grub_usb_device_t usbdev,
                      int config __attribute__ ((unused)),
                      int interface __attribute__ ((unused)))
{
    unsigned i;

    grub_dprintf ("usb_snes", "Device detaching...\n");

    for (i = 0; i < ARRAY_SIZE (gamepads); i++)
    {
        struct grub_usb_snes_data *data = gamepads[i].data;

        if (!data)
            continue;

        if (data->usbdev != usbdev)
            continue;

        /* Cancel pending transfer */
        if (data->transfer)
            grub_usb_cancel_transfer (data->transfer);

        /* Unregister terminal */
        grub_term_unregister_input (&gamepads[i]);

        /* Free resources */
        grub_free ((char *) gamepads[i].name);
        gamepads[i].name = NULL;
        grub_free (data);
        gamepads[i].data = NULL;

        grub_dprintf ("usb_snes", "Device %d detached\n", i);
    }
}

/*
 * USB device attach callback
 * This is called when a USB HID device is detected
 */
static int
grub_usb_snes_attach (grub_usb_device_t usbdev, int configno, int interfno)
{
    unsigned curnum;
    struct grub_usb_snes_data *data;
    struct grub_usb_desc_endp *endp = NULL;
    const char *device_name;
    int j;

    grub_dprintf ("usb_snes", "Attach: VID=%04x PID=%04x config=%d interf=%d\n",
                  usbdev->descdev.vendorid, usbdev->descdev.prodid,
                  configno, interfno);

    /*
     * Check if this is a device we want to handle
     */
    device_name = get_device_name (usbdev->descdev.vendorid, usbdev->descdev.prodid);

#if ACCEPT_ANY_HID
    /*
     * Accept any HID device that is NOT a keyboard (protocol != 1)
     * USB HID keyboards use protocol 1 (USB_HID_KBD_PROTOCOL)
     * We skip keyboards to avoid conflicts with usb_keyboard module
     */
    if (usbdev->config[configno].interf[interfno].descif->protocol == 0x01)
    {
        grub_dprintf ("usb_snes", "Skipping keyboard device (protocol=1)\n");
        return 0;
    }

    if (!device_name)
        device_name = "Generic HID Gamepad";
#else
    if (!device_name)
    {
        grub_dprintf ("usb_snes", "Unknown device, skipping\n");
        return 0;
    }
#endif

    /* Find an available slot */
    for (curnum = 0; curnum < ARRAY_SIZE (gamepads); curnum++)
        if (!gamepads[curnum].data)
            break;

    if (curnum >= ARRAY_SIZE (gamepads))
    {
        grub_dprintf ("usb_snes", "No free slots (max %d)\n", GAMEPADS_CAPACITY);
        return 0;
    }

    /* Find an interrupt IN endpoint */
    for (j = 0; j < usbdev->config[configno].interf[interfno].descif->endpointcnt; j++)
    {
        endp = &usbdev->config[configno].interf[interfno].descendp[j];

        /* Check for interrupt IN endpoint (bit 7 = direction IN) */
        if ((endp->endp_addr & 0x80) &&
            grub_usb_get_ep_type (endp) == GRUB_USB_EP_INTERRUPT)
            break;
    }

    if (j == usbdev->config[configno].interf[interfno].descif->endpointcnt)
    {
        grub_dprintf ("usb_snes", "No interrupt IN endpoint found\n");
        return 0;
    }

    grub_dprintf ("usb_snes", "Found interrupt endpoint %d, addr=0x%02x\n",
                  j, endp->endp_addr);

    /* Allocate device data structure */
    data = grub_malloc (sizeof (*data));
    if (!data)
    {
        grub_print_error ();
        return 0;
    }

    /* Initialize data structure */
    data->usbdev = usbdev;
    data->configno = configno;
    data->interfno = interfno;
    data->endp = endp;
    data->key_queue_begin = 0;
    data->key_queue_size = 0;
    grub_memcpy (data->prev_report, baseline_report, USB_REPORT_SIZE);
    grub_memset (data->report, 0, USB_REPORT_SIZE);

    /*
     * USB Device Initialization Sequence
     * Following the pattern from usb_keyboard.c
     */

    /* Step 1: Set USB configuration */
    grub_dprintf ("usb_snes", "Setting configuration %d\n", configno + 1);
    grub_usb_set_configuration (usbdev, configno + 1);

    /*
     * Step 2: Set HID protocol to Boot Protocol (0)
     * Request type: 0x21 = Host-to-device, Class, Interface
     * Request: USB_HID_SET_PROTOCOL (0x0B)
     * Value: 0 = Boot Protocol, 1 = Report Protocol
     * Index: Interface number
     * Some devices may not support this, but it shouldn't hurt to try
     */
    grub_dprintf ("usb_snes", "Setting boot protocol on interface %d\n", interfno);
    grub_usb_control_msg (usbdev,
                          GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,
                          USB_HID_SET_PROTOCOL,
                          0,        /* Boot protocol */
                          interfno,
                          0,
                          NULL);

    /*
     * Step 3: Set idle rate to 0 (report only on changes)
     * Request type: 0x21 = Host-to-device, Class, Interface
     * Request: USB_HID_SET_IDLE (0x0A)
     * Value: Duration (0 = indefinite) | Report ID (0)
     * Index: Interface number
     */
    grub_dprintf ("usb_snes", "Setting idle rate\n");
    grub_usb_control_msg (usbdev,
                          GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,
                          USB_HID_SET_IDLE,
                          0 << 8,   /* Duration 0 = report on event only */
                          interfno,
                          0,
                          NULL);

    /* Clear any USB errors from optional commands */
    grub_errno = GRUB_ERR_NONE;

    /* Setup terminal input structure */
    gamepads[curnum].name = grub_xasprintf ("snes_gamepad%d", curnum);
    if (!gamepads[curnum].name)
    {
        grub_free (data);
        grub_print_error ();
        return 0;
    }
    gamepads[curnum].getkey = grub_usb_snes_getkey;
    gamepads[curnum].getkeystatus = grub_usb_snes_getkeystatus;
    gamepads[curnum].data = data;
    gamepads[curnum].next = 0;

    /* Set detach hook */
    usbdev->config[configno].interf[interfno].detach_hook = grub_usb_snes_detach;

    /* Start background USB transfer */
    grub_dprintf ("usb_snes", "Starting background read\n");
    data->transfer = grub_usb_bulk_read_background (
        usbdev,
        data->endp,
        sizeof (data->report),
        (char *) data->report);

    if (!data->transfer)
    {
        grub_dprintf ("usb_snes", "Failed to start USB transfer\n");
        grub_print_error ();
        grub_free ((char *) gamepads[curnum].name);
        gamepads[curnum].name = NULL;
        grub_free (data);
        return 0;
    }

    /* Register as active terminal input */
    grub_term_register_input_active ("snes_gamepad", &gamepads[curnum]);

    grub_printf ("SNES Gamepad connected: %s (slot %d)\n", device_name, curnum);

    return 1;
}

/*
 * USB attach hook registration
 */
static struct grub_usb_attach_desc attach_hook = {
    .class = GRUB_USB_CLASS_HID,
    .hook = grub_usb_snes_attach
};

/*
 * Module initialization
 */
GRUB_MOD_INIT (usb_snes_gamepad)
{
    grub_dprintf ("usb_snes", "SNES Gamepad module loading...\n");
    grub_usb_register_attach_hook_class (&attach_hook);
    grub_dprintf ("usb_snes", "SNES Gamepad module loaded\n");
}

/*
 * Module cleanup
 */
GRUB_MOD_FINI (usb_snes_gamepad)
{
    unsigned i;

    grub_dprintf ("usb_snes", "SNES Gamepad module unloading...\n");

    /* Cleanup all attached gamepads */
    for (i = 0; i < ARRAY_SIZE (gamepads); i++)
    {
        struct grub_usb_snes_data *data = gamepads[i].data;

        if (!data)
            continue;

        if (data->transfer)
            grub_usb_cancel_transfer (data->transfer);

        grub_term_unregister_input (&gamepads[i]);
        grub_free ((char *) gamepads[i].name);
        gamepads[i].name = NULL;
        grub_free (data);
        gamepads[i].data = NULL;
    }

    grub_usb_unregister_attach_hook_class (&attach_hook);
    grub_dprintf ("usb_snes", "SNES Gamepad module unloaded\n");
}
